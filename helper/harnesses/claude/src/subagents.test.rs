//! Running subagents against real files: what a chat is told of each from SubagentStart to
//! SubagentStop as Claude writes its meta file and transcript.
use super::*;
use crate::identity::Session;
use std::{collections::VecDeque, io, io::Write, os::unix::fs::MetadataExt, path::PathBuf};

#[derive(Default)]
struct Fake {
    next: u64,
    jobs: VecDeque<(Work, Job)>,
    deferred: VecDeque<Box<dyn FnOnce(&mut dyn Io)>>,
    watches: Vec<(u64, PathBuf)>,
    unwatched: Vec<u64>,
    timers: Vec<Instant>,
}
fn unsupported<T>() -> io::Result<T> {
    Err(io::ErrorKind::Unsupported.into())
}
impl Io for Fake {
    fn defer(&mut self, callback: Box<dyn FnOnce(&mut dyn Io)>) {
        self.deferred.push_back(callback)
    }
    fn interest(&mut self, _: i32, _: bool, _: bool) -> io::Result<()> {
        Ok(())
    }
    fn read(&mut self, _: i32, _: &mut [u8]) -> io::Result<usize> {
        unsupported()
    }
    fn write(&mut self, _: i32, _: &[u8]) -> io::Result<usize> {
        unsupported()
    }
    fn close(&mut self, _: i32) {}
    fn accept(&mut self, _: i32) -> io::Result<i32> {
        unsupported()
    }
    fn child(&mut self, _: u32) -> io::Result<()> {
        Ok(())
    }
    fn timer(&mut self, at: Instant) {
        self.timers.push(at);
    }
    fn now(&self) -> Instant {
        Instant::now()
    }
    fn submit(&mut self, job: Job) -> io::Result<Work> {
        self.next += 1;
        self.jobs.push_back((self.next, job));
        Ok(self.next)
    }
    fn cancel(&mut self, work: Work) -> bool {
        let count = self.jobs.len();
        self.jobs.retain(|(w, _)| *w != work);
        count != self.jobs.len()
    }
    fn watch(&mut self, path: &std::path::Path, _: bool) -> io::Result<u64> {
        self.next += 1;
        self.watches.push((self.next, path.to_owned()));
        Ok(self.next)
    }
    fn unwatch(&mut self, watch: u64) {
        self.unwatched.push(watch);
    }
    fn spawn(&mut self, _: std::process::Command, _: Option<Grid>) -> io::Result<Spawned> {
        unsupported()
    }
    fn resize(&mut self, _: i32, _: Grid) -> io::Result<()> {
        unsupported()
    }
    fn hangup(&mut self, _: i32) -> io::Result<()> {
        unsupported()
    }
    fn connect(&mut self, _: &Address) -> io::Result<i32> {
        unsupported()
    }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> {
        unsupported()
    }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> {
        unsupported()
    }
}

/// The states chats are given.
#[derive(Default)]
struct Shown(Vec<State>);
impl Ui for Shown {
    fn update(&mut self, update: Update) {
        if let Update::State { state, .. } = update {
            self.0.push(state);
        }
    }
    fn watching(&self, _: &Binding) -> bool {
        true
    }
    fn terminal(&self, _: &Binding) -> Option<Id> {
        Some(1)
    }
}

const SESSION: &str = "0b9f6c1e-3a52-4d7e-9c41-5e2f8a7b6c10";
const STARTED: u64 = 1_800_000_000_000;

fn run(job: &Job) -> io::Result<Output> {
    use std::io::{Read, Seek, SeekFrom};
    match job {
        Job::Native { name: "clock", .. } => {
            let value = Data::Object(vec![("ms", Data::Signed(STARTED as i64))]);
            Ok(Output::Value(dispatch_helper_core::wire::body::encode_plain(&value).unwrap()))
        }
        Job::Read { path, offset, length } => {
            let mut file = std::fs::File::open(path)?;
            let m = file.metadata()?;
            let metadata = Metadata {
                kind: FileKind::File,
                size: m.size(),
                device: m.dev(),
                inode: m.ino(),
                modified_ns: 0,
                changed_ns: 0,
            };
            file.seek(SeekFrom::Start(*offset))?;
            let mut bytes = Vec::new();
            (&mut file).take(*length).read_to_end(&mut bytes)?;
            Ok(Output::Read { before: metadata.clone(), after: metadata, bytes })
        }
        _ => panic!("unexpected job"),
    }
}

/// One model call of `id` as Claude logs it: a record per content block, each with the call's usage.
fn call(id: &str, records: usize, input: u64, output: u64, written: u64, read: u64) -> String {
    (0..records)
        .map(|n| {
            format!(
                concat!(
                    r#"{{"isSidechain":true,"agentId":"a1","type":"assistant","uuid":"{id}-{n}","message":{{"id":"{id}","role":"assistant","#,
                    r#""model":"claude-example","content":[{{"type":"text","text":"part {n}"}}],"usage":{{"input_tokens":{input},"#,
                    r#""output_tokens":{output},"cache_creation_input_tokens":{written},"cache_read_input_tokens":{read}}}}}}}"#,
                    "\n"
                ),
                id = id, n = n, input = input, output = output, written = written, read = read
            )
        })
        .collect()
}
fn user(n: usize) -> String {
    format!("{{\"isSidechain\":true,\"type\":\"user\",\"uuid\":\"u{n}\",\"message\":{{\"role\":\"user\",\"content\":\"find the timer\"}}}}\n")
}
fn hook(event: &str, agent: &str) -> Event {
    let message = format!(
        r#"{{"session_id":"{SESSION}","hook_event_name":"{event}","agent_id":"{agent}","agent_type":"Explore","transcript_path":"/elsewhere/x.jsonl"}}"#
    );
    Event::Hook { peer: None, route: 1, message: message.into_bytes(), reply: None }
}

struct World {
    claude: Claude,
    io: Fake,
    shown: Shown,
    binding: Binding,
    folder: PathBuf,
    dir: PathBuf,
}
impl World {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("dispatch-claude-subagents-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let folder = dir.join(SESSION).join("subagents");
        std::fs::create_dir_all(&folder).unwrap();
        let binding = Binding {
            session: SESSION.into(),
            transcript: Some(dir.join(format!("{SESSION}.jsonl"))),
            process: Process {
                pid: 4242, parent: 1, group: 4242, foreground: 4242, tty: 7, start: [1_800_000_000, 0],
                executable: "/opt/example/claude".into(), arguments: vec!["claude".into()], files: vec![],
            },
        };
        let mut claude = Claude::new(dir.clone(), false);
        claude.sessions.insert(
            key(&binding),
            Session {
                binding: binding.clone(),
                status: "busy".into(),
                waiting: None,
                name: None,
                version: Some("2.1.302".into()),
                directory: dir.clone(),
                registry: dir.join("sessions/4242.json"),
            },
        );
        Self { claude, io: Fake::default(), shown: Shown::default(), binding, folder, dir }
    }
    fn send(&mut self, event: Event) {
        self.claude.event(&mut self.io, &mut self.shown, event);
        self.pump();
    }
    /// Deferred callbacks, then every job, in order.
    fn pump(&mut self) {
        loop {
            while let Some(callback) = self.io.deferred.pop_front() {
                callback(&mut self.io);
            }
            let Some((work, job)) = self.io.jobs.pop_front() else { break };
            let result = run(&job);
            self.claude.event(&mut self.io, &mut self.shown, Event::Done { work, result });
        }
    }
    fn write(&self, file: &str, text: &str) {
        std::fs::OpenOptions::new().create(true).append(true).open(self.folder.join(file)).unwrap().write_all(text.as_bytes()).unwrap();
    }
    fn changed(&mut self, agent: &str) {
        let watch = self.io.watches.iter().find(|(_, p)| p.ends_with(format!("agent-{agent}.jsonl"))).unwrap().0;
        self.send(Event::Changed { watch, reset: false });
    }
    /// The publish timer fires.
    fn tick(&mut self) {
        let at = *self.io.timers.last().expect("a publish is due");
        self.send(Event::Timer { at });
    }
    fn agents(&self) -> Vec<Agent> {
        self.claude.subagents.agents(&self.binding.session)
    }
}
impl Drop for World {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn counts_each_model_call_once_without_cache_reads() {
    let mut agent = Subagent::new("a1", "Explore");
    let text = call("m1", 3, 3, 120, 2_000, 50_000) + &user(1) + &call("m2", 1, 1, 40, 300, 52_000);
    let mut lines = Lines::recover(LINE);
    lines.feed(text.as_bytes(), |line| {
        agent.count(line);
        Ok(())
    }).unwrap();
    agent.read = true;
    assert_eq!(agent.tokens(), Some(3 + 120 + 2_000 + 1 + 40 + 300), "three records of m1 count once; cache reads not at all");
    // A later record of a call that reports more (a streamed call's last block) raises it, never twice.
    lines.feed(call("m2", 1, 1, 90, 300, 52_000).as_bytes(), |line| {
        agent.count(line);
        Ok(())
    }).unwrap();
    assert_eq!(agent.tokens(), Some(2_123 + 391));
}

#[test]
fn names_and_ids() {
    assert_eq!(name(br#"{"agentType":"Explore","description":"  Find the timer  "}"#).as_deref(), Some("Find the timer"));
    assert_eq!(name(br#"{"description":"   "}"#), None);
    assert_eq!(name(b"{"), None);
    assert_eq!(name(format!(r#"{{"description":"{}"}}"#, "é".repeat(300)).as_bytes()).map(|n| n.chars().count()), Some(NAME));
    assert!(safe("a55ebb4cd68459002"));
    for id in ["", "../a", "a/b", "a.b", &"a".repeat(129)] {
        assert!(!safe(id), "{id}");
    }
}

#[test]
fn reports_name_tokens_and_start_from_start_to_stop() {
    let mut world = World::new("lifecycle");
    world.write("agent-a1.meta.json", r#"{"agentType":"Explore","description":"Find the timer"}"#);
    world.write("agent-a1.jsonl", &(user(0) + &call("m1", 2, 3, 100, 1_000, 9_000)));
    world.send(hook("SubagentStart", "a1"));
    assert_eq!(
        world.agents(),
        vec![Agent { id: "a1".into(), kind: "Explore".into(), name: Some("Find the timer".into()), tokens: Some(1_103), started_ms: Some(STARTED) }]
    );
    let told = world.shown.0.last().unwrap().agents[0].clone();
    assert_eq!((told.name.as_deref(), told.started_ms, told.tokens), (Some("Find the timer"), Some(STARTED), None),
               "the start, its clock and name are told at once; tokens with the next timer");
    world.tick();
    assert_eq!(world.shown.0.last().unwrap().agents, world.agents());
    // The watch is on the agent's own transcript beside the verified one, not the hook's path.
    assert_eq!(world.io.watches[0].1, world.folder.join("agent-a1.jsonl"));

    // Claude writes on: the new bytes are read, and the chat hears of it with the next timer.
    let told = world.shown.0.len();
    world.write("agent-a1.jsonl", &call("m2", 1, 1, 50, 200, 10_000));
    world.changed("a1");
    assert_eq!(world.agents()[0].tokens, Some(1_354));
    assert_eq!(world.shown.0.len(), told, "token changes wait for the timer");
    world.tick();
    assert_eq!(world.shown.0.last().unwrap().agents[0].tokens, Some(1_354));

    // A replaced transcript is counted from its start.
    std::fs::remove_file(world.folder.join("agent-a1.jsonl")).unwrap();
    world.write("agent-a1.jsonl", &call("m9", 1, 2, 3, 4, 5));
    world.changed("a1");
    assert_eq!(world.agents()[0].tokens, Some(9));

    world.send(hook("SubagentStop", "a1"));
    assert!(world.agents().is_empty());
    assert_eq!(world.io.unwatched, vec![world.io.watches[0].0]);
    assert!(world.shown.0.last().unwrap().agents.is_empty());
}

#[test]
fn files_written_after_the_start_are_picked_up() {
    let mut world = World::new("late");
    world.send(hook("SubagentStart", "a2"));
    assert_eq!(
        world.agents(),
        vec![Agent { id: "a2".into(), kind: "Explore".into(), name: None, tokens: None, started_ms: Some(STARTED) }],
        "nothing written yet: no name and no tokens"
    );
    world.write("agent-a2.meta.json", r#"{"description":"Read the docs"}"#);
    world.write("agent-a2.jsonl", &call("m1", 1, 1, 2, 3, 4));
    world.changed("a2");
    let agent = &world.agents()[0];
    assert_eq!((agent.name.as_deref(), agent.tokens), (Some("Read the docs"), Some(6)));
    // A session boundary ends every agent.
    world.send(hook("SessionStart", "a2"));
    assert!(world.agents().is_empty());
}

#[test]
fn unsafe_ids_run_without_files() {
    let mut world = World::new("unsafe");
    world.send(hook("SubagentStart", "../../etc"));
    assert_eq!(world.agents().len(), 1);
    assert!(world.io.watches.is_empty(), "no path is made from an id that leaves the folder");
    assert_eq!(world.agents()[0].tokens, None);
}
