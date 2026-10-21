//! A queue the host accepted reaches the agent after its client is gone: real Claude Code against
//! the loopback fixture (scripts/claude_fixture.py) in a private tmux server, the shipped helper,
//! and the queue drainer it starts when its client leaves.
//!
//! Needs python3, tmux and Claude Code (build/test-tools/bin, or DISPATCH_TEST_CLAUDE):
//! cargo test -p dispatch-helper --test queue_drain -- --ignored
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

fn checkout() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap()
}

fn tool(name: &str) -> Option<PathBuf> {
    let path = checkout().join("build/test-tools/bin").join(name);
    path.exists().then_some(path)
}

/// Everything this test starts, ended in order whatever happens.
struct Scene {
    root: PathBuf,
    socket: PathBuf,
    tmux: PathBuf,
    fixture: Option<Child>,
}

impl Drop for Scene {
    fn drop(&mut self) {
        // DISPATCH_TEST_KEEP=1 leaves a failed run's tmux server, fixture and store for a look.
        if std::thread::panicking() && std::env::var_os("DISPATCH_TEST_KEEP").is_some() {
            eprintln!("kept: {} (tmux -S {})", self.root.display(), self.socket.display());
            std::mem::forget(self.fixture.take());
            return;
        }
        // Only this test's own server: its socket is named explicitly, never the default.
        let _ = Command::new(&self.tmux).arg("-S").arg(&self.socket).arg("kill-server").status();
        if let Some(mut fixture) = self.fixture.take() {
            let _ = fixture.kill();
            let _ = fixture.wait();
        }
        // Claude and tmux write their last files while they exit.
        std::thread::sleep(Duration::from_secs(2));
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

struct Client {
    child: Child,
    input: Option<ChildStdin>,
    output: ChildStdout,
    serial: u64,
    collectors: BTreeMap<u64, Collector>,
    /// Topology so far: node id -> (key, agent session).
    nodes: BTreeMap<u64, (String, Option<String>)>,
    busy: Option<bool>,
}

impl Client {
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
                let root = value.root();
                match root.get("method").and_then(Data::string) {
                    Some("topology") => {
                        for node in root.get("params").unwrap().get("nodes").unwrap().array().unwrap() {
                            let id = node.get("id").unwrap().unsigned().unwrap();
                            let key = node.get("key").unwrap().string().unwrap().to_owned();
                            let session = node.get("agent").and_then(|a| a.get("session")).and_then(Data::string);
                            self.nodes.insert(id, (key, session.map(str::to_owned)));
                        }
                    }
                    // chat.open's readiness carries the state; later changes come as chat.state.
                    Some("chat.state" | "chat.history") => {
                        let state = root.get("params").and_then(|p| p.get("state"));
                        self.busy = state.and_then(|s| s.get("busy")).and_then(Data::boolean).or(self.busy);
                    }
                    _ => {}
                }
                return (header.kind, header.id, value);
            }
        }
    }

    fn call(&mut self, method: &str, params: Data<'_>) -> Encoded {
        let id = self.send(method, params);
        loop {
            let (kind, from, value) = self.next();
            if from == id && kind == Kind::Response {
                let error = value.root().get("error").and_then(|e| e.get("message")).and_then(Data::string).map(str::to_owned);
                assert!(error.is_none(), "{method}: {error:?}");
                return value;
            }
        }
    }

    /// Read until `ready` holds, or fail after `limit`.
    fn until(&mut self, limit: Duration, what: &str, ready: impl Fn(&Self) -> bool) {
        let deadline = Instant::now() + limit;
        while !ready(self) {
            assert!(Instant::now() < deadline, "timed out waiting for {what}; nodes {:?}, busy {:?}", self.nodes, self.busy);
            // A ping keeps frames coming, so the wait is bounded by the deadline.
            self.call("echo", Data::Object(Vec::new()));
            std::thread::sleep(Duration::from_millis(200));
        }
    }
}

/// What the TUI submitted, in order: the newest user message of each request the fixture received.
fn prompts(state: &Path) -> Vec<String> {
    let script = r#"
import json, sys
for line in open(sys.argv[1]):
    try:
        body = json.loads(line)['body']
    except (ValueError, KeyError):
        continue
    users = [m for m in body.get('messages', []) if m.get('role') == 'user']
    if not users:
        continue
    content = users[-1].get('content')
    parts = [content] if isinstance(content, str) else [p.get('text', '') for p in content if isinstance(p, dict)]
    # Title and summary requests quote the session; reminders ride along as their own parts.
    typed = [part for part in parts if part and not part.startswith('<')]
    if typed:
        print(json.dumps(typed[-1]))
"#;
    let log = state.join("requests.jsonl");
    if !log.exists() {
        return Vec::new();
    }
    let output = Command::new("/usr/bin/python3").args(["-c", script]).arg(&log).output().unwrap();
    let mut submitted: Vec<String> = Vec::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let text = line.trim().trim_matches('"').to_owned();
        // A title or summary request repeats the last prompt: one submission per new message.
        if submitted.last() != Some(&text) {
            submitted.push(text);
        }
    }
    submitted.into_iter().filter(|text| text.contains("queued message")).collect()
}

#[test]
#[ignore]
fn a_queue_outlives_its_client_and_the_drainer_sends_it() {
    let (Some(tmux), Some(claude)) = (tool("tmux"), std::env::var_os("DISPATCH_TEST_CLAUDE").map(PathBuf::from).or_else(|| tool("claude"))) else {
        eprintln!("skipped: needs build/test-tools/bin/{{tmux,claude}}");
        return;
    };
    let root = PathBuf::from(format!("/tmp/dq-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    for directory in ["home", "tmux", "state"] {
        std::fs::create_dir_all(root.join(directory)).unwrap();
    }
    let uid = unsafe { libc_getuid() };
    let socket = root.join(format!("tmux/tmux-{uid}/default"));
    // Private, as tmux makes it: the helper refuses a socket in a folder others can enter.
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    std::fs::set_permissions(socket.parent().unwrap(), std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    let mut scene = Scene { root: root.clone(), socket: socket.clone(), tmux: tmux.clone(), fixture: None };
    let scripts = checkout().join("scripts");
    let state = root.join("state");
    let path = format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", tmux.parent().unwrap().display());
    // The fixture streams slowly enough that the first reply is still running while the queue fills.
    scene.fixture = Some(
        Command::new("/usr/bin/python3")
            .arg(scripts.join("claude_fixture.py"))
            .args(["serve", "--state"])
            .arg(&state)
            .args(["--delay", "0.25"])
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
        .args(["new-session", "-d", "-s", "queue", "-x", "160", "-y", "48", &launch])
        .env_remove("TMUX")
        .env("PATH", &path)
        .status()
        .unwrap();
    assert!(started.success());

    let helper = env!("CARGO_BIN_EXE_dispatch-helper");
    let mut child = Command::new(helper)
        .arg("--stdio")
        .env_remove("TMUX")
        .env_remove("TMUX_PANE")
        .env_remove("DISPATCH_CAPTURE")
        .env("DISPATCH_TEST_ROOT", root.join("home"))
        .env("TMUX_TMPDIR", root.join("tmux"))
        .env("PATH", &path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let (input, output) = (child.stdin.take(), child.stdout.take().unwrap());
    let mut client = Client { child, input, output, serial: 0, collectors: BTreeMap::new(), nodes: BTreeMap::new(), busy: None };
    client.call("hello", Data::Object(Vec::new()));
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
    assert!(!keys.is_empty(), "no tmux server found");
    for key in &keys {
        let id = client.send("backends.open", Data::Object(vec![("mux", Data::Unsigned(mux)), ("key", Data::String(key))]));
        loop {
            let (_, from, value) = client.next();
            if from != id {
                continue;
            }
            let root = value.root();
            assert!(root.get("error").is_none(), "backends.open {key}: {:?}", root.get("error").and_then(|e| e.get("message")).and_then(Data::string));
            if root.get("method").and_then(Data::string) == Some("backend.opened") || root.get("result").is_some() {
                break;
            }
        }
    }
    client.until(Duration::from_secs(60), "Claude bound in tmux", |client| client.nodes.values().any(|(_, session)| session.is_some()));
    let (terminal, session) = client
        .nodes
        .iter()
        .find_map(|(id, (_, session))| session.clone().map(|session| (*id, session)))
        .unwrap();
    client.send("chat.open", Data::Object(vec![("terminal", Data::Unsigned(terminal)), ("session", Data::String(&session))]));
    client.until(Duration::from_secs(30), "an idle agent", |client| client.busy == Some(false));
    // A long reply keeps the agent busy while two messages are queued behind it. Typed into the pane
    // directly: this client renders nothing, so its helper has no screen to check a send against.
    for keys in [&["-l", "long reply please"][..], &["Enter"][..]] {
        let typed = Command::new(&tmux).arg("-S").arg(&socket).args(["send-keys", "-t", "queue"]).args(keys).env_remove("TMUX").status().unwrap();
        assert!(typed.success());
        std::thread::sleep(Duration::from_millis(300));
    }
    client.until(Duration::from_secs(30), "a busy agent", |client| client.busy == Some(true));
    for text in ["queued message one", "queued message two"] {
        client.call(
            "queue.add",
            Data::Object(vec![
                ("terminal", Data::Unsigned(terminal)),
                ("session", Data::String(&session)),
                ("text", Data::String(text)),
                ("mode", Data::String("prompt")),
                ("command", Data::Bool(false)),
            ]),
        );
    }
    let store = root.join("home/.dispatch/state/queue");
    assert_eq!(std::fs::read_dir(&store).unwrap().filter(|e| e.as_ref().unwrap().path().extension().is_some_and(|x| x == "q")).count(), 1);
    // The client goes away (a Mac shut down): its helper ends while the agent is still busy.
    drop(client.input.take());
    let status = client.child.wait().unwrap();
    assert!(status.success(), "{status:?}");
    assert!(prompts(&state).is_empty(), "sent before the agent was idle: {:?}", prompts(&state));
    // The drainer it started sends both, in order, once each.
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let sent = prompts(&state);
        if sent.iter().any(|p| p.ends_with("two")) {
            break;
        }
        assert!(Instant::now() < deadline, "the drainer did not send the queue: {sent:?}");
        std::thread::sleep(Duration::from_millis(500));
    }
    std::thread::sleep(Duration::from_secs(3));
    let sent = prompts(&state);
    assert_eq!(sent, ["queued message one", "queued message two"], "in order, once each");
    let deadline = Instant::now() + Duration::from_secs(30);
    while std::fs::read_dir(&store).unwrap().any(|e| e.unwrap().path().extension().is_some_and(|x| x == "q")) {
        assert!(Instant::now() < deadline, "the stored queue was not emptied");
        std::thread::sleep(Duration::from_millis(250));
    }
    // Nothing left to send: the drainer ends by itself and lets go of the account's lock.
    let lock = std::fs::OpenOptions::new().read(true).write(true).open(store.join("drain.lock")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    while unsafe { flock(std::os::fd::AsRawFd::as_raw_fd(&lock), 2 | 4) } != 0 {
        assert!(Instant::now() < deadline, "the drainer did not end");
        std::thread::sleep(Duration::from_millis(250));
    }
    drop(scene);
}

unsafe extern "C" {
    #[link_name = "getuid"]
    fn libc_getuid() -> u32;
    fn flock(fd: i32, operation: i32) -> i32;
}
