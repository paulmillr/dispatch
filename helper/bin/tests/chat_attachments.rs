//! Chat attachments end to end (feature chat.attachments): the shipped helper stores what a client
//! uploads, reads it back, and delivers a message with an image and a file to real Claude Code
//! against the loopback fixture (scripts/claude_fixture.py) in a private tmux server. The image
//! goes as a pasted path Claude Code attaches (`[Image #n]`), the file as a path line; Pi gets the
//! image's path as a line too (its read tool opens images).
//!
//! Needs python3, tmux, Claude Code and Pi (build/test-tools/bin, or DISPATCH_TEST_CLAUDE):
//! cargo test -p dispatch-helper --test chat_attachments -- --ignored
use dispatch_helper_core::{
    json::Data,
    wire::{self, Collector, Header, Kind, Received, body::{self, Encoded}},
};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    time::{Duration, Instant},
};

/// A 4x4 red PNG (fictional test data).
const PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x04, 0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09, 0x29, 0x00, 0x00, 0x00, 0x10, 0x49,
    0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0x00, 0x47, 0x0c, 0xc4, 0x71, 0x00, 0xae, 0x93, 0x0f, 0xf1,
    0xd0, 0x5f, 0x23, 0x9e, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];

fn checkout() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap()
}

fn tool(name: &str) -> Option<PathBuf> {
    let path = checkout().join("build/test-tools/bin").join(name);
    path.exists().then_some(path)
}

/// Everything a test starts, ended whatever happens.
struct Scene {
    root: PathBuf,
    socket: Option<(PathBuf, PathBuf)>,
    fixture: Option<Child>,
}

impl Drop for Scene {
    fn drop(&mut self) {
        if std::thread::panicking() && std::env::var_os("DISPATCH_TEST_KEEP").is_some() {
            eprintln!("kept: {}", self.root.display());
            std::mem::forget(self.fixture.take());
            return;
        }
        // Only this test's own server: its socket is named explicitly, never the default.
        if let Some((tmux, socket)) = &self.socket {
            let _ = Command::new(tmux).arg("-S").arg(socket).arg("kill-server").status();
        }
        if let Some(mut fixture) = self.fixture.take() {
            let _ = fixture.kill();
            let _ = fixture.wait();
        }
        std::thread::sleep(Duration::from_secs(1));
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

struct Client {
    child: Child,
    input: Option<ChildStdin>,
    output: ChildStdout,
    serial: u64,
    collectors: BTreeMap<u64, Collector>,
    nodes: BTreeMap<u64, Option<String>>,
    busy: Option<bool>,
    /// chat.records and chat.history user records: (text, blocks as (kind, path, name)).
    users: Vec<(String, Vec<(String, Option<String>, Option<String>)>)>,
}

impl Client {
    fn start(root: &Path, path: &str) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_dispatch-helper"))
            // A drainer's helper: no app renders its terminals, tmux reports their screens itself.
            .args(["--stdio", "--drain"])
            .env_remove("TMUX")
            .env_remove("TMUX_PANE")
            .env_remove("DISPATCH_CAPTURE")
            .env("DISPATCH_TEST_ROOT", root.join("home"))
            .env("TMUX_TMPDIR", root.join("tmux"))
            .env("PATH", path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let (input, output) = (child.stdin.take(), child.stdout.take().unwrap());
        Self { child, input, output, serial: 0, collectors: BTreeMap::new(), nodes: BTreeMap::new(), busy: None, users: Vec::new() }
    }

    fn send(&mut self, method: &str, params: Data<'_>) -> u64 {
        self.serial += 1;
        let body = body::encode(&Data::Object(vec![("method", Data::String(method)), ("params", params)])).unwrap();
        let frame = wire::packet(Kind::Request, self.serial, &body).unwrap();
        self.input.as_mut().unwrap().write_all(&frame).unwrap();
        self.serial
    }

    fn next(&mut self) -> (Kind, u64, Encoded) {
        loop {
            let mut head = [0; 13];
            self.output.read_exact(&mut head).unwrap();
            let header = Header::decode(&head, wire::LIMIT).unwrap();
            let mut bytes = vec![0; header.len as usize];
            self.output.read_exact(&mut bytes).unwrap();
            let collector =
                self.collectors.entry(header.id).or_insert_with(|| Collector::new(header.id, wire::LIMIT as usize));
            if let Some(Received::Value(value)) = collector.push(header, &bytes).unwrap() {
                self.collectors.remove(&header.id);
                self.observe(&value);
                return (header.kind, header.id, value);
            }
        }
    }

    fn observe(&mut self, value: &Encoded) {
        let root = value.root();
        let params = root.get("params");
        match root.get("method").and_then(Data::string) {
            Some("topology") => {
                for node in params.unwrap().get("nodes").unwrap().array().unwrap() {
                    let id = node.get("id").unwrap().unsigned().unwrap();
                    let session = node.get("agent").and_then(|a| a.get("session")).and_then(Data::string);
                    self.nodes.insert(id, session.map(str::to_owned));
                }
            }
            Some(method @ ("chat.state" | "chat.history" | "chat.records")) => {
                let state = params.and_then(|p| p.get("state"));
                self.busy = state.and_then(|s| s.get("busy")).and_then(Data::boolean).or(self.busy);
                let records = match method {
                    "chat.records" => params.and_then(|p| p.get("records")),
                    _ => params.and_then(|p| p.get("page")).and_then(|p| p.get("records")),
                };
                for record in records.and_then(Data::array).into_iter().flatten() {
                    if record.get("kind").and_then(Data::string) != Some("user") {
                        continue;
                    }
                    let text = record.get("text").and_then(Data::string).unwrap_or_default().to_owned();
                    let field = |block: &Data<'_>, key| block.get(key).and_then(Data::string).map(str::to_owned);
                    let blocks = record
                        .get("blocks")
                        .and_then(Data::array)
                        .into_iter()
                        .flatten()
                        .map(|block| (field(&block, "kind").unwrap_or_default(), field(&block, "path"), field(&block, "text")))
                        .collect();
                    self.users.push((text, blocks));
                }
            }
            _ => {}
        }
    }

    /// The response to a request; Err with the error's code.
    fn ask(&mut self, method: &str, params: Data<'_>) -> Result<Encoded, String> {
        let id = self.send(method, params);
        loop {
            let (kind, from, value) = self.next();
            if from == id && kind == Kind::Response {
                if let Some(error) = value.root().get("error") {
                    return Err(error.get("code").and_then(Data::string).unwrap_or_default().to_owned());
                }
                return Ok(value);
            }
        }
    }

    fn call(&mut self, method: &str, params: Data<'_>) -> Encoded {
        self.ask(method, params).unwrap_or_else(|code| panic!("{method}: {code}"))
    }

    fn until(&mut self, limit: Duration, what: &str, ready: impl Fn(&Self) -> bool) {
        let deadline = Instant::now() + limit;
        while !ready(self) {
            assert!(Instant::now() < deadline, "timed out waiting for {what}; busy {:?}, users {:?}", self.busy, self.users);
            self.call("echo", Data::Object(Vec::new()));
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    fn hello(&mut self) -> Encoded {
        self.call("hello", Data::Object(vec![("features", Data::Array(vec![Data::String("chat.attachments")]))]))
    }

    fn put(&mut self, name: &str, bytes: &[u8]) -> (String, String) {
        let stored = self.call("attachments.put", Data::Object(vec![("name", Data::String(name)), ("bytes", Data::Bytes(bytes))]));
        let root = stored.root();
        let result = root.get("result").unwrap();
        assert_eq!(result.get("size").and_then(Data::unsigned), Some(bytes.len() as u64));
        let text = |key| result.get(key).and_then(Data::string).unwrap().to_owned();
        (text("path"), text("kind"))
    }
}

fn scene(name: &str) -> (Scene, PathBuf) {
    let root = PathBuf::from(format!("/tmp/{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    for directory in ["home", "tmux", "state"] {
        std::fs::create_dir_all(root.join(directory)).unwrap();
    }
    (Scene { root: root.clone(), socket: None, fixture: None }, root)
}

#[test]
#[ignore]
fn stored_copies_are_private_and_read_back_only_for_their_feature() {
    let (_scene, root) = scene("da");
    let mut client = Client::start(&root, "/usr/bin:/bin:/usr/sbin:/sbin");
    // Without the feature the operations do not exist.
    client.call("hello", Data::Object(Vec::new()));
    let put = Data::Object(vec![("name", Data::String("a.png")), ("bytes", Data::Bytes(PNG))]);
    assert_eq!(client.ask("attachments.put", put).unwrap_err(), "unsupported");
    drop(client.input.take());
    client.child.wait().unwrap();

    let mut client = Client::start(&root, "/usr/bin:/bin:/usr/sbin:/sbin");
    let hello = client.hello();
    let ops: Vec<String> =
        hello.root().get("result").unwrap().get("ops").unwrap().array().unwrap().map(|op| op.string().unwrap().into()).collect();
    assert!(ops.iter().any(|op| op == "attachments.put") && ops.iter().any(|op| op == "attachments.read"));
    // The stored name keeps plain characters only; the reply names the file as the user had it.
    let stored = client.call(
        "attachments.put",
        Data::Object(vec![("name", Data::String("../../Screen Shot $(id)\u{202e}.png")), ("bytes", Data::Bytes(PNG))]),
    );
    let result = stored.root();
    let result = result.get("result").unwrap();
    assert_eq!(result.get("name").and_then(Data::string), Some("Screen Shot $(id).png"));
    let image = result.get("path").and_then(Data::string).unwrap().to_owned();
    assert_eq!(result.get("kind").and_then(Data::string), Some("image"));
    assert!(image.ends_with("/Screen_Shot_id_.png"), "{image}");
    let attachments = root.join("home/.dispatch/attachments");
    assert!(image.starts_with(attachments.to_str().unwrap()));
    let (text, kind) = client.put("notes.png", b"not really a png");
    assert_eq!(kind, "file", "an image name without image bytes");
    use std::os::unix::fs::PermissionsExt;
    let mode = |path: &Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
    assert_eq!((mode(&attachments), mode(Path::new(&image).parent().unwrap()), mode(Path::new(&image))), (0o700, 0o700, 0o600));
    let read = client.call("attachments.read", Data::Object(vec![("path", Data::String(&image))]));
    assert_eq!(read.root().get("result").unwrap().get("bytes").and_then(Data::bytes), Some(PNG));
    let empty = Data::Object(vec![("name", Data::String("a.txt")), ("bytes", Data::Bytes(b""))]);
    assert_eq!(client.ask("attachments.put", empty).unwrap_err(), "invalid_input");
    let large = vec![1u8; 8 << 20 | 1];
    let large = Data::Object(vec![("name", Data::String("a.bin")), ("bytes", Data::Bytes(&large))]);
    assert_eq!(client.ask("attachments.put", large).unwrap_err(), "invalid_input");
    let other = format!("{}/x.txt", root.display());
    for path in [other.as_str(), "relative.txt", &format!("{}/../{}", Path::new(&text).parent().unwrap().display(), "a")] {
        assert_eq!(client.ask("attachments.read", Data::Object(vec![("path", Data::String(path))])).unwrap_err(), "invalid_request", "{path}");
    }
    std::fs::remove_file(&text).unwrap();
    assert_eq!(client.ask("attachments.read", Data::Object(vec![("path", Data::String(&text))])).unwrap_err(), "not_found");
    drop(client.input.take());
    assert!(client.child.wait().unwrap().success());
}

#[test]
#[ignore]
fn claude_code_gets_the_image_attached_and_the_file_as_a_path_line() {
    let (Some(tmux), Some(claude)) = (tool("tmux"), std::env::var_os("DISPATCH_TEST_CLAUDE").map(PathBuf::from).or_else(|| tool("claude"))) else {
        eprintln!("skipped: needs build/test-tools/bin/{{tmux,claude}}");
        return;
    };
    let (mut scene, root) = scene("dc");
    let uid = unsafe { getuid() };
    let socket = root.join(format!("tmux/tmux-{uid}/default"));
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    std::fs::set_permissions(socket.parent().unwrap(), std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    scene.socket = Some((tmux.clone(), socket.clone()));
    let scripts = checkout().join("scripts");
    let state = root.join("state");
    let path = format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", tmux.parent().unwrap().display());
    scene.fixture = Some(
        Command::new("/usr/bin/python3")
            .arg(scripts.join("claude_fixture.py"))
            .args(["serve", "--state"])
            .arg(&state)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    while !std::fs::read_to_string(state.join("endpoint.json")).is_ok_and(|text| !text.contains("\"port\": 0")) {
        assert!(Instant::now() < deadline, "fixture did not start");
        std::thread::sleep(Duration::from_millis(100));
    }
    let launch = format!(
        "/usr/bin/python3 {} launch --state {} --integration --claude {}",
        scripts.join("claude_fixture.py").display(),
        state.display(),
        claude.display()
    );
    let started = Command::new(&tmux)
        .arg("-S")
        .arg(&socket)
        .args(["new-session", "-d", "-s", "attach", "-x", "160", "-y", "48", &launch])
        .env_remove("TMUX")
        .env("PATH", &path)
        .status()
        .unwrap();
    assert!(started.success());

    let mut client = Client::start(&root, &path);
    client.hello();
    let (image, _) = client.put("diagram.png", PNG);
    let (file, kind) = client.put("notes.txt", b"Sam Example's notes\n");
    assert_eq!(kind, "file");
    let listed = client.call("multiplexers.list", Data::Object(Vec::new()));
    let mux = listed
        .root()
        .get("result")
        .unwrap()
        .array()
        .unwrap()
        .find(|row| row.get("name").and_then(Data::string) == Some("tmux"))
        .and_then(|row| row.get("mux").and_then(Data::unsigned))
        .expect("tmux multiplexer");
    let listed = client.call("backends.list", Data::Object(vec![("mux", Data::Unsigned(mux))]));
    let keys: Vec<String> =
        listed.root().get("result").unwrap().array().unwrap().map(|key| key.string().unwrap().to_owned()).collect();
    for key in &keys {
        let id = client.send("backends.open", Data::Object(vec![("mux", Data::Unsigned(mux)), ("key", Data::String(key))]));
        loop {
            let (_, from, value) = client.next();
            let root = value.root();
            if from == id && (root.get("method").and_then(Data::string) == Some("backend.opened") || root.get("result").is_some()) {
                break;
            }
        }
    }
    client.until(Duration::from_secs(60), "Claude bound in tmux", |client| client.nodes.values().any(Option::is_some));
    let (terminal, session) = client.nodes.iter().find_map(|(id, session)| session.clone().map(|s| (*id, s))).unwrap();
    client.send("chat.open", Data::Object(vec![("terminal", Data::Unsigned(terminal)), ("session", Data::String(&session))]));
    client.until(Duration::from_secs(30), "an idle agent", |client| client.busy == Some(false));
    // A command takes none; an unknown path is refused before anything is typed.
    let unknown = format!("{}/x.png", root.display());
    for (text, path, command) in [("/compact", image.as_str(), true), ("x", unknown.as_str(), false)] {
        let refused = client.ask(
            "chat.send",
            Data::Object(vec![
                ("terminal", Data::Unsigned(terminal)),
                ("session", Data::String(&session)),
                ("text", Data::String(text)),
                ("command", Data::Bool(command)),
                ("attachments", Data::Array(vec![Data::String(path)])),
            ]),
        );
        assert_eq!(refused.unwrap_err(), "invalid_input");
    }
    client.call(
        "chat.send",
        Data::Object(vec![
            ("terminal", Data::Unsigned(terminal)),
            ("session", Data::String(&session)),
            ("text", Data::String("Describe these")),
            ("mode", Data::String("prompt")),
            ("attachments", Data::Array(vec![Data::String(&image), Data::String(&file)])),
        ]),
    );
    // The transcript's user record: the typed text, the image named from what was delivered, the file.
    client.until(Duration::from_secs(60), "the user record", |client| client.users.iter().any(|(text, _)| text == "Describe these"));
    let (_, blocks) = client.users.iter().rev().find(|(text, _)| text == "Describe these").unwrap();
    assert_eq!(
        blocks,
        &[
            ("image".to_owned(), Some(image.clone()), Some("diagram.png".to_owned())),
            ("file".to_owned(), Some(file.clone()), Some("notes.txt".to_owned())),
        ]
    );
    // What the model received: the image itself, and the file's path.
    let requests = std::fs::read_to_string(state.join("requests.jsonl")).unwrap();
    assert!(requests.contains("\"type\": \"image\"") || requests.contains("\"type\":\"image\""), "no image block sent");
    assert!(requests.contains(&file), "the file's path line");
    assert!(requests.contains("[Image #1]"), "pasted as an image, not as a path line");
    assert!(!requests.contains(&format!("{image}\\n")) && !requests.contains(&format!("{image}\"")), "no image path line");
    // Queued on the host (store format 2), then sent by this helper's own drain once Claude is idle.
    client.until(Duration::from_secs(30), "an idle agent", |client| client.busy == Some(false));
    let queued = client.call(
        "queue.add",
        Data::Object(vec![
            ("terminal", Data::Unsigned(terminal)),
            ("session", Data::String(&session)),
            ("text", Data::String("")),
            ("mode", Data::String("prompt")),
            ("attachments", Data::Array(vec![Data::String(&image)])),
        ]),
    );
    let item = queued.root();
    let item = item.get("result").unwrap();
    assert_eq!(item.get("editable").and_then(Data::boolean), Some(false));
    let preview = item.get("preview").unwrap().array().unwrap().map(|p| p.get("type").and_then(Data::string).map(str::to_owned));
    assert_eq!(preview.collect::<Vec<_>>(), [Some("image".to_owned())]);
    client.until(Duration::from_secs(60), "the queued image", |client| {
        client.users.iter().any(|(text, blocks)| text.is_empty() && blocks.len() == 1)
    });
    let (_, blocks) = client.users.iter().rev().find(|(text, _)| text.is_empty()).unwrap();
    assert_eq!(blocks, &[("image".to_owned(), Some(image.clone()), Some("diagram.png".to_owned()))]);
    // A file alone: its path line, unfenced (Claude takes `/a/b` as a message, not a command).
    client.until(Duration::from_secs(30), "an idle agent", |client| client.busy == Some(false));
    client.call(
        "chat.send",
        Data::Object(vec![
            ("terminal", Data::Unsigned(terminal)),
            ("session", Data::String(&session)),
            ("text", Data::String("")),
            ("mode", Data::String("prompt")),
            ("attachments", Data::Array(vec![Data::String(&file)])),
        ]),
    );
    let only = ("file".to_owned(), Some(file.clone()), Some("notes.txt".to_owned()));
    client.until(Duration::from_secs(60), "the file alone", |client| {
        client.users.iter().any(|(text, blocks)| text.is_empty() && blocks == std::slice::from_ref(&only))
    });
    let requests = std::fs::read_to_string(state.join("requests.jsonl")).unwrap();
    assert!(!requests.contains(&format!("```\\n{file}")), "a path alone is not fenced");
    drop(client.input.take());
    let _ = client.child.wait();
    drop(scene);
}

/// Pi against the same fixture with the Dispatch bridge loaded from this checkout, its model
/// taking images (the fixture's own model is text-only), as a read of the image would need.
const PI: &str = r#"
import json, os, sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
from pi_fixture import configure, environment, command
state, home, pi, bridge = Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5]
port = json.loads((state / 'endpoint.json').read_text())['port']
configure(state, port, home)
models = json.loads((home / 'models.json').read_text())
for provider in models['providers'].values():
    for model in provider['models']:
        model['input'] = ['text', 'image']
(home / 'models.json').write_text(json.dumps(models))
os.chdir(state / 'work')
os.execvpe(pi, command(pi, '--extension', bridge), environment(state, port, home))
"#;

#[test]
#[ignore]
fn pi_gets_the_image_as_a_path_line() {
    let (Some(tmux), Some(pi)) = (tool("tmux"), tool("pi")) else {
        eprintln!("skipped: needs build/test-tools/bin/{{tmux,pi}}");
        return;
    };
    let (mut scene, root) = scene("dp");
    let uid = unsafe { getuid() };
    let socket = root.join(format!("tmux/tmux-{uid}/default"));
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    std::fs::set_permissions(socket.parent().unwrap(), std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    scene.socket = Some((tmux.clone(), socket.clone()));
    let scripts = checkout().join("scripts");
    let state = root.join("state");
    let path = format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", tmux.parent().unwrap().display());
    scene.fixture = Some(
        Command::new("/usr/bin/python3")
            .arg(scripts.join("claude_fixture.py"))
            .args(["serve", "--state"])
            .arg(&state)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    while !std::fs::read_to_string(state.join("endpoint.json")).is_ok_and(|text| !text.contains("\"port\": 0")) {
        assert!(Instant::now() < deadline, "fixture did not start");
        std::thread::sleep(Duration::from_millis(100));
    }
    std::fs::write(root.join("pi.py"), PI).unwrap();
    let bridge = Path::new(env!("CARGO_MANIFEST_DIR")).join("../harnesses/pi/resources/bridge.js").canonicalize().unwrap();
    let launch = format!(
        "/usr/bin/python3 {} {} {} {} {} {}",
        root.join("pi.py").display(),
        scripts.display(),
        state.display(),
        root.join("pi-home").display(),
        pi.display(),
        bridge.display()
    );
    let started = Command::new(&tmux)
        .arg("-S")
        .arg(&socket)
        .args(["new-session", "-d", "-s", "pi", "-x", "160", "-y", "48", &launch])
        .env_remove("TMUX")
        .env("PATH", &path)
        .status()
        .unwrap();
    assert!(started.success());

    let mut client = Client::start(&root, &path);
    client.hello();
    let (image, _) = client.put("diagram.png", PNG);
    let listed = client.call("multiplexers.list", Data::Object(Vec::new()));
    let mux = listed
        .root()
        .get("result")
        .unwrap()
        .array()
        .unwrap()
        .find(|row| row.get("name").and_then(Data::string) == Some("tmux"))
        .and_then(|row| row.get("mux").and_then(Data::unsigned))
        .expect("tmux multiplexer");
    let listed = client.call("backends.list", Data::Object(vec![("mux", Data::Unsigned(mux))]));
    let keys: Vec<String> =
        listed.root().get("result").unwrap().array().unwrap().map(|key| key.string().unwrap().to_owned()).collect();
    for key in &keys {
        let id = client.send("backends.open", Data::Object(vec![("mux", Data::Unsigned(mux)), ("key", Data::String(key))]));
        loop {
            let (_, from, value) = client.next();
            let root = value.root();
            if from == id && (root.get("method").and_then(Data::string) == Some("backend.opened") || root.get("result").is_some()) {
                break;
            }
        }
    }
    client.until(Duration::from_secs(60), "Pi bound in tmux", |client| client.nodes.values().any(Option::is_some));
    let (terminal, session) = client.nodes.iter().find_map(|(id, session)| session.clone().map(|s| (*id, s))).unwrap();
    client.send("chat.open", Data::Object(vec![("terminal", Data::Unsigned(terminal)), ("session", Data::String(&session))]));
    client.until(Duration::from_secs(30), "an idle agent", |client| client.busy == Some(false));
    client.call(
        "chat.send",
        Data::Object(vec![
            ("terminal", Data::Unsigned(terminal)),
            ("session", Data::String(&session)),
            ("text", Data::String("What is in this picture?")),
            ("mode", Data::String("prompt")),
            ("attachments", Data::Array(vec![Data::String(&image)])),
        ]),
    );
    client.until(Duration::from_secs(60), "the user record", |client| {
        client.users.iter().any(|(text, _)| text == "What is in this picture?")
    });
    let (_, blocks) = client.users.iter().rev().find(|(text, _)| text == "What is in this picture?").unwrap();
    assert_eq!(blocks, &[("image".to_owned(), Some(image.clone()), Some("diagram.png".to_owned()))]);
    // The model got the typed text with the copy's path on its own line (the text fallback).
    let requests = std::fs::read_to_string(state.join("requests.jsonl")).unwrap();
    assert!(requests.contains(&format!("What is in this picture?\\n\\n{image}")), "no path line sent");
    drop(client.input.take());
    let _ = client.child.wait();
    drop(scene);
}

unsafe extern "C" {
    fn getuid() -> u32;
}
