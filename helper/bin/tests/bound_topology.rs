//! A client of feature topology.bound gets a first topology that already names the agent running in a pane (the
//! multiplexer's discovery has looked at it), where a client without it gets the pane first and its agent in a later
//! topology, as recorded clients expect. Real Claude Code against the loopback fixture (scripts/claude_fixture.py) in a
//! private tmux server, and the shipped helper.
//!
//! Needs python3, tmux and Claude Code (build/test-tools/bin, or DISPATCH_TEST_CLAUDE):
//! cargo test -p dispatch-helper --test bound_topology -- --ignored
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
    /// Each topology's terminals as they came: (key, agent session).
    topologies: Vec<Vec<(String, Option<String>)>>,
}

impl Client {
    fn start(root: &Path, path: &str) -> Client {
        let mut child = Command::new(env!("CARGO_BIN_EXE_dispatch-helper"))
            .arg("--stdio")
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
        Client { child, input, output, serial: 0, collectors: BTreeMap::new(), topologies: Vec::new() }
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
                let root = value.root();
                if root.get("method").and_then(Data::string) == Some("topology") {
                    let terminals = root
                        .get("params")
                        .unwrap()
                        .get("nodes")
                        .unwrap()
                        .array()
                        .unwrap()
                        .filter(|node| node.get("kind").and_then(Data::string) == Some("terminal"))
                        .map(|node| {
                            let session = node.get("agent").and_then(|a| a.get("session")).and_then(Data::string);
                            (node.get("key").unwrap().string().unwrap().to_owned(), session.map(str::to_owned))
                        })
                        .collect();
                    self.topologies.push(terminals);
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

    /// hello with `features`, then every tmux server opened, as the apps connect.
    fn connect(&mut self, features: &[&str]) {
        let named = Data::Array(features.iter().map(|feature| Data::String(feature)).collect());
        self.call("hello", Data::Object(vec![("features", named)]));
        let listed = self.call("multiplexers.list", Data::Object(Vec::new()));
        let mux = listed
            .root()
            .get("result")
            .unwrap()
            .array()
            .unwrap()
            .find(|row| row.get("name").and_then(Data::string) == Some("tmux"))
            .and_then(|row| row.get("mux").and_then(Data::unsigned))
            .expect("tmux multiplexer");
        let listed = self.call("backends.list", Data::Object(vec![("mux", Data::Unsigned(mux))]));
        let keys: Vec<String> =
            listed.root().get("result").unwrap().array().unwrap().map(|key| key.string().unwrap().to_owned()).collect();
        assert!(!keys.is_empty(), "no tmux server found");
        for key in &keys {
            // Answered by `backend.opened` on its subscription (or a result).
            let id = self.send("backends.open", Data::Object(vec![("mux", Data::Unsigned(mux)), ("key", Data::String(key))]));
            loop {
                let (_, from, value) = self.next();
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
    }

    /// Read until `ready` holds, or fail after `limit`.
    fn until(&mut self, limit: Duration, what: &str, ready: impl Fn(&Self) -> bool) {
        let deadline = Instant::now() + limit;
        while !ready(self) {
            assert!(Instant::now() < deadline, "timed out waiting for {what}; topologies {:?}", self.topologies);
            // A ping keeps frames coming, so the wait is bounded by the deadline.
            self.call("echo", Data::Object(Vec::new()));
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    fn end(mut self) {
        drop(self.input.take());
        let status = self.child.wait().unwrap();
        assert!(status.success(), "{status:?}");
    }
}

fn bound(topology: &[(String, Option<String>)]) -> bool {
    topology.iter().any(|(_, session)| session.is_some())
}

#[test]
#[ignore]
fn a_topology_bound_client_gets_the_running_agent_in_its_first_topology() {
    let (Some(tmux), Some(claude)) = (tool("tmux"), std::env::var_os("DISPATCH_TEST_CLAUDE").map(PathBuf::from).or_else(|| tool("claude"))) else {
        eprintln!("skipped: needs build/test-tools/bin/{{tmux,claude}}");
        return;
    };
    let root = PathBuf::from(format!("/tmp/db-{}", std::process::id()));
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
    // Claude in the second window, a shell in the first: the shell's discovery ends early, Claude's binds.
    for arguments in [&["new-session", "-d", "-s", "bound", "-x", "160", "-y", "48"][..], &["new-window", "-d", "-t", "bound", &launch][..]] {
        let started = Command::new(&tmux).arg("-S").arg(&socket).args(arguments).env_remove("TMUX").env("PATH", &path).status().unwrap();
        assert!(started.success());
    }

    // Claude is up and bound: a client sees it after its first topology.
    let mut first = Client::start(&root, &path);
    first.connect(&[]);
    first.until(Duration::from_secs(60), "Claude bound in tmux", |client| client.topologies.last().is_some_and(|t| bound(t)));
    first.end();

    // A client that names no feature: the running agent comes in a later topology, as recorded clients expect.
    let mut plain = Client::start(&root, &path);
    plain.connect(&[]);
    plain.until(Duration::from_secs(10), "the binding", |client| client.topologies.last().is_some_and(|t| bound(t)));
    let opened = plain.topologies.iter().position(|t| !t.is_empty()).unwrap();
    assert!(!bound(&plain.topologies[opened]), "first topology: {:?}", plain.topologies);
    plain.end();

    // topology.bound: the first topology with terminals names Claude already.
    let mut phone = Client::start(&root, &path);
    let started = Instant::now();
    phone.connect(&["topology.bound"]);
    let opened = phone.topologies.iter().position(|t| !t.is_empty()).expect("a topology before backends.open answered");
    assert!(bound(&phone.topologies[opened]), "first topology: {:?}", phone.topologies);
    assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
    phone.end();
    drop(scene);
}

unsafe extern "C" {
    #[link_name = "getuid"]
    fn libc_getuid() -> u32;
}
