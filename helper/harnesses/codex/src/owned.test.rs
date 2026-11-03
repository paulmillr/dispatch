//! A Codex side as owned::open starts it, against a fake system and app-server: which variables
//! and options each side agent gets, when it is started again with the parent's credentials, and
//! what ends an open (docs/security.md, Side conversations).
use super::*;
use dispatch_helper_core::{
    api::{Address, Event, Grid, Output, Spawned, Work},
    wire::body,
};
use std::{collections::VecDeque, io, os::fd::RawFd, path::Path, time::Instant};

const PARENT: &str = "019a0000-0000-7000-8000-000000000001";
const CODEX: &str = "/opt/codex/bin/codex";

#[derive(Default)]
struct Fake {
    next: u64,
    jobs: VecDeque<(Work, Job)>,
    deferred: VecDeque<Box<dyn FnOnce(&mut dyn Io)>>,
    /// What each spawned side agent was started with: (pid, command).
    spawned: Vec<(u32, Command)>,
    terminated: Vec<u32>,
    written: BTreeMap<RawFd, Vec<u8>>,
    readable: BTreeMap<RawFd, VecDeque<Vec<u8>>>,
}
#[rustfmt::skip]
impl Io for Fake {
    fn now(&self) -> Instant { Instant::now() }
    fn timer(&mut self, _: Instant) {}
    fn defer(&mut self, work: Box<dyn FnOnce(&mut dyn Io)>) { self.deferred.push_back(work); }
    fn interest(&mut self, _: RawFd, _: bool, _: bool) -> io::Result<()> { Ok(()) }
    fn read(&mut self, fd: RawFd, bytes: &mut [u8]) -> io::Result<usize> {
        let Some(chunk) = self.readable.get_mut(&fd).and_then(VecDeque::pop_front) else { return Err(io::ErrorKind::WouldBlock.into()) };
        bytes[..chunk.len()].copy_from_slice(&chunk);
        Ok(chunk.len())
    }
    fn write(&mut self, fd: RawFd, bytes: &[u8]) -> io::Result<usize> {
        self.written.entry(fd).or_default().extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn close(&mut self, _: RawFd) {}
    fn accept(&mut self, _: RawFd) -> io::Result<RawFd> { unreachable!() }
    fn child(&mut self, _: u32) -> io::Result<()> { Ok(()) }
    fn terminate(&mut self, pid: u32) -> io::Result<()> { self.terminated.push(pid); Ok(()) }
    fn random(&mut self, bytes: &mut [u8]) -> io::Result<()> { bytes.fill(7); Ok(()) }
    fn submit(&mut self, job: Job) -> io::Result<Work> { self.next += 1; self.jobs.push_back((self.next, job)); Ok(self.next) }
    fn cancel(&mut self, _: Work) -> bool { true }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> { unreachable!() }
    fn unwatch(&mut self, _: u64) {}
    fn spawn(&mut self, command: Command, _: Option<Grid>) -> io::Result<Spawned> {
        let pid = 500 + self.spawned.len() as u32;
        self.spawned.push((pid, command));
        // Fds per side agent: its stdin, then its stdout.
        let input = 2 * pid as RawFd;
        Ok(Spawned { pid, input: Some(input), output: Some(input + 1), stderr: None, tty: None })
    }
    fn resize(&mut self, _: RawFd, _: Grid) -> io::Result<()> { unreachable!() }
    fn hangup(&mut self, _: RawFd) -> io::Result<()> { unreachable!() }
    fn connect(&mut self, _: &Address) -> io::Result<RawFd> { unreachable!() }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> { unreachable!() }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> { unreachable!() }
}

fn process(pid: u32, arguments: &[&str]) -> Process {
    Process {
        pid,
        parent: 1,
        group: pid as i32,
        foreground: pid as i32,
        tty: 0,
        start: [1_800_000_000, 5],
        executable: CODEX.into(),
        arguments: arguments.iter().map(|a| (*a).to_owned()).collect(),
        files: Vec::new(),
    }
}

/// A side of the parent `argv`, whose environment holds `variables`; Codex answers `config` for
/// config/read and `reply` (model, provider) for the fork.
struct Run {
    io: Fake,
    /// Names each environment request asked for, and whether it was bound to the parent's start.
    asked: Vec<(Vec<String>, bool)>,
    /// Every request each side agent got: (pid, method, params).
    requests: Vec<(u32, String, String)>,
    result: Option<Result<Binding, Error>>,
}

fn run(argv: &[&str], variables: &[(&str, &str)], config: &str, reply: (&str, &str), read_only: bool) -> Run {
    let parent = Binding { session: PARENT.into(), transcript: None, process: process(4242, argv) };
    let (jobs, channels, exits): (Jobs, Channels, Exits) = Default::default();
    let result = Rc::new(RefCell::new(None));
    let saved = result.clone();
    let mut io = Fake::default();
    open(jobs.clone(), channels.clone(), exits, &mut io, parent.clone(), "a side note", read_only,
        Box::new(move |_, value| *saved.borrow_mut() = Some(value)));
    let (mut asked, mut requests) = (Vec::new(), Vec::new());
    for _ in 0..200 {
        while let Some(callback) = io.deferred.pop_front() {
            callback(&mut io);
        }
        if let Some((work, job)) = io.jobs.pop_front() {
            let Job::Native { name, value } = job else { panic!("unexpected job") };
            let input = body::decode_plain(&value).unwrap();
            let pid = input.get("pid").and_then(|v| v.unsigned()).unwrap() as u32;
            let answer = match name {
                "process" => {
                    let observed = if pid == 4242 { parent.process.clone() } else { process(pid, &[]) };
                    let Data::Object(mut fields) = observed.value() else { unreachable!() };
                    fields.push(("cwd", Data::from(Path::new("/work/project"))));
                    body::encode_plain(&Data::Object(fields)).unwrap()
                }
                "environment" => {
                    let names: Vec<String> = input.get("names").unwrap().array().unwrap().map(|n| n.string().unwrap().to_owned()).collect();
                    let bound = input.get("start").and_then(|v| v.array()).map(|s| s.map(|n| n.unsigned().unwrap()).collect::<Vec<_>>())
                        == Some(parent.process.start.to_vec())
                        && input.get("executable").and_then(|v| v.path()) == Some(Path::new(CODEX));
                    let fields = variables.iter().filter(|(name, _)| names.iter().any(|n| n == name))
                        .map(|(name, value)| (*name, Data::Bytes(value.as_bytes()))).collect();
                    asked.push((names, bound));
                    body::encode_plain(&Data::Object(fields)).unwrap()
                }
                other => panic!("unexpected native job {other}"),
            };
            let done = jobs.borrow_mut().remove(&work).unwrap();
            done(&mut io, Ok(Output::Value(answer)));
            continue;
        }
        let open: Vec<_> = channels.borrow().values().cloned().collect();
        let mut progressed = false;
        for channel in open {
            let (pid, output) = (channel.borrow().pid, channel.borrow().fd());
            channel.borrow_mut().event(&mut io, &Event::Ready { fd: output - 1, read: false, write: true });
            let sent = io.written.remove(&(output - 1)).unwrap_or_default();
            for line in sent.split(|b| *b == b'\n').filter(|line| !line.is_empty()) {
                let request = Json::parse(line).unwrap();
                let root = request.root();
                let Some(id) = root.get("id").and_then(Value::signed) else { continue };
                let method = root.get("method").and_then(Value::string).unwrap().to_owned();
                let params = root.get("params").map(|p| String::from_utf8(p.write().unwrap()).unwrap()).unwrap_or_default();
                let result = match method.as_str() {
                    "config/read" => format!(r#"{{"config":{config}}}"#),
                    "thread/read" => format!(r#"{{"thread":{{"id":"{PARENT}","model":"custom-model","modelProvider":"custom","reasoningEffort":"high"}}}}"#),
                    "thread/fork" => format!(
                        r#"{{"thread":{{"id":"side-thread","ephemeral":true}},"model":"{}","modelProvider":"{}","sandbox":{{"type":"readOnly"}},"approvalPolicy":"never"}}"#,
                        reply.0, reply.1),
                    _ => "{}".to_owned(),
                };
                requests.push((pid, method, params));
                io.readable.entry(output).or_default().push_back(format!(r#"{{"id":{id},"result":{result}}}"#).into_bytes().into_iter().chain([b'\n']).collect());
                progressed = true;
            }
            if progressed {
                channel.borrow_mut().event(&mut io, &Event::Ready { fd: output, read: true, write: false });
            }
        }
        if !progressed && io.deferred.is_empty() && io.jobs.is_empty() && result.borrow().is_some() {
            break;
        }
    }
    let result = result.borrow_mut().take();
    Run { io, asked, requests, result }
}

fn envs(command: &Command) -> Vec<(String, String)> {
    let mut envs: Vec<_> = command.get_envs()
        .filter_map(|(name, value)| Some((name.to_string_lossy().into_owned(), value?.to_string_lossy().into_owned())))
        .collect();
    envs.sort();
    envs
}
fn args(command: &Command) -> Vec<String> {
    command.get_args().map(|arg| arg.to_string_lossy().into_owned()).collect()
}

const CONFIG: &str = r#"{"model_provider":"custom","model_providers":{"custom":{"env_key":"SAM_PROVIDER_KEY"}},"mcp_servers":{"docs":{"command":"docs","env_vars":["SAM_DOCS_TOKEN"]}}}"#;
const PARENT_ENV: [(&str, &str); 4] = [
    ("HOME", "/home/sam"),
    ("SAM_PROVIDER_KEY", "synthetic-provider-key"),
    ("SAM_DOCS_TOKEN", "synthetic-docs-token"),
    ("SAM_UNRELATED", "never-forwarded"),
];
const ARGV: [&str; 9] = [
    "codex", "--remote", "unix:///tmp/dispatch-codex-1/control.sock", "-c", "model_provider=\"custom\"",
    "-c", "approval_policy=\"never\"", "-c", "sandbox_mode=\"danger-full-access\"",
];

#[test]
fn a_side_is_started_again_with_the_credentials_its_configuration_names() {
    for read_only in [true, false] {
        let run = run(&ARGV, &PARENT_ENV, CONFIG, ("custom-model", "custom"), read_only);
        let binding = run.result.expect("the open finished").expect("the side opened");
        assert_eq!(binding.session, "side-thread");
        // The first agent only read the configuration and the parent thread; its replacement forks.
        assert_eq!(run.io.spawned.len(), 2);
        let (first, second) = (run.io.spawned[0].0, run.io.spawned[1].0);
        assert_eq!(run.io.terminated, [first]);
        let methods = |pid| run.requests.iter().filter(|(p, ..)| *p == pid).map(|(_, m, _)| m.as_str()).collect::<Vec<_>>();
        assert_eq!(methods(first), ["initialize", "config/read", "thread/read"]);
        assert_eq!(methods(second), ["initialize", "thread/fork", "turn/start"]);
        // Every environment request is bound to the parent's exact process.
        assert!(run.asked.iter().all(|(_, bound)| *bound));
        let further = &run.asked.last().unwrap().0;
        assert!(further.contains(&"SAM_PROVIDER_KEY".to_owned()));
        assert_eq!(further.contains(&"SAM_DOCS_TOKEN".to_owned()), !read_only, "MCP credentials for /side only");
        let command = &run.io.spawned[1].1;
        let mut expected = vec![("HOME".to_owned(), "/home/sam".to_owned()), ("SAM_PROVIDER_KEY".to_owned(), "synthetic-provider-key".to_owned())];
        if !read_only {
            expected.push(("SAM_DOCS_TOKEN".to_owned(), "synthetic-docs-token".to_owned()));
            expected.sort();
        }
        assert_eq!(envs(command), expected);
        // The parent's overrides, without what decides what the side may do without asking.
        let arguments = args(command);
        assert_eq!(&arguments[..4], ["app-server", "--stdio", "-c", "model_provider=\"custom\""]);
        assert!(!arguments.iter().any(|a| a.contains("approval_policy") || a.contains("sandbox_mode")));
        assert_eq!(arguments.iter().any(|a| a == "--disable"), read_only);
        // The fork runs on the parent's provider and model, with Dispatch's own permissions.
        let fork = &run.requests.iter().find(|(_, m, _)| m == "thread/fork").unwrap().2;
        let fork = Json::parse(fork.as_bytes()).unwrap();
        let fork = fork.root();
        assert_eq!(fork.get("model").and_then(Value::string), Some("custom-model"));
        assert_eq!(fork.get("modelProvider").and_then(Value::string), Some("custom"));
        assert_eq!(fork.get("approvalPolicy").and_then(Value::string), read_only.then_some("never"));
        assert_eq!(fork.get("sandbox").and_then(Value::string), read_only.then_some("read-only"));
    }
}

#[test]
fn a_side_keeps_its_agent_when_the_parent_has_none_of_the_named_variables() {
    let run = run(&ARGV, &[("HOME", "/home/sam")], CONFIG, ("custom-model", "custom"), true);
    assert!(run.result.unwrap().is_ok());
    assert_eq!(run.io.spawned.len(), 1);
    assert!(run.io.terminated.is_empty());
    assert_eq!(run.asked.len(), 2, "the named variables were asked for once");
    assert_eq!(envs(&run.io.spawned[0].1), [("HOME".to_owned(), "/home/sam".to_owned())]);
}

#[test]
fn a_fork_on_another_provider_ends_the_open() {
    let run = run(&ARGV, &[("HOME", "/home/sam")], CONFIG, ("custom-model", "dispatch_fixture"), true);
    let error = run.result.unwrap().unwrap_err();
    assert!(error.message.contains("could not run on the parent conversation's model and provider"), "{}", error.message);
    // No question was sent, and the side agent was ended.
    assert!(!run.requests.iter().any(|(_, m, _)| m == "turn/start"));
    assert_eq!(run.io.terminated, [run.io.spawned[0].0]);
}

#[test]
fn a_parent_with_a_profile_gets_no_side() {
    for argv in [&["codex", "--profile", "work"][..], &["codex", "-c", "profile=\"work\""]] {
        let run = run(argv, &[("HOME", "/home/sam")], CONFIG, ("custom-model", "custom"), false);
        let error = run.result.unwrap().unwrap_err();
        assert_eq!(error.code, "profile");
        assert!(run.io.spawned.is_empty());
    }
}
