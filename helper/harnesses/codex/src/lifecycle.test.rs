//! Hook-independent session cleanup and native compaction through the real harness/channel.
use super::*;
use crate::channel::Channel;
use std::{collections::VecDeque, io, os::fd::RawFd, path::PathBuf, time::Instant};

const FIRST: &str = "019a0000-0000-7000-8000-000000000001";
const SECOND: &str = "019a0000-0000-7000-8000-000000000002";

#[derive(Default)]
struct Fake {
    deferred: VecDeque<Box<dyn FnOnce(&mut dyn Io)>>,
    incoming: VecDeque<Vec<u8>>,
    written: Vec<u8>,
}
#[rustfmt::skip]
impl Io for Fake {
    fn now(&self) -> Instant { Instant::now() }
    fn timer(&mut self, _: Instant) {}
    fn defer(&mut self, work: Box<dyn FnOnce(&mut dyn Io)>) { self.deferred.push_back(work); }
    fn interest(&mut self, _: RawFd, _: bool, _: bool) -> io::Result<()> { Ok(()) }
    fn read(&mut self, _: RawFd, bytes: &mut [u8]) -> io::Result<usize> {
        let Some(chunk) = self.incoming.pop_front() else { return Err(io::ErrorKind::WouldBlock.into()); };
        bytes[..chunk.len()].copy_from_slice(&chunk);
        Ok(chunk.len())
    }
    fn write(&mut self, _: RawFd, bytes: &[u8]) -> io::Result<usize> { self.written.extend(bytes); Ok(bytes.len()) }
    fn close(&mut self, _: RawFd) {}
    fn accept(&mut self, _: RawFd) -> io::Result<RawFd> { unreachable!() }
    fn child(&mut self, _: u32) -> io::Result<()> { Ok(()) }
    fn terminate(&mut self, _: u32) -> io::Result<()> { Ok(()) }
    fn submit(&mut self, _: Job) -> io::Result<Work> { unreachable!() }
    fn cancel(&mut self, _: Work) -> bool { true }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> { unreachable!() }
    fn unwatch(&mut self, _: u64) {}
    fn spawn(&mut self, _: Command, _: Option<Grid>) -> io::Result<Spawned> {
        Ok(Spawned { pid: 700, input: Some(10), output: Some(11), stderr: None, tty: None })
    }
    fn resize(&mut self, _: RawFd, _: Grid) -> io::Result<()> { unreachable!() }
    fn hangup(&mut self, _: RawFd) -> io::Result<()> { unreachable!() }
    fn connect(&mut self, _: &Address) -> io::Result<RawFd> { unreachable!() }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> { unreachable!() }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> { unreachable!() }
}

#[derive(Default)]
struct View(Vec<Update>);
impl Ui for View {
    fn update(&mut self, update: Update) { self.0.push(update); }
}

fn binding(session: &str) -> Binding {
    Binding {
        session: session.into(), transcript: None,
        process: Process { pid: 42, parent: 1, group: 42, foreground: 42, tty: 7, start: [5, 6],
            executable: "/opt/codex/bin/codex".into(), arguments: vec![], files: vec![] },
    }
}

#[derive(Default)]
struct World { codex: Codex, io: Fake, ui: View }
impl World {
    fn new(native: bool) -> Self {
        let mut world = Self::default();
        let binding = binding(FIRST);
        if native {
            let mut channel = Channel::spawn(&mut world.io, binding.clone(), Command::new("codex")).unwrap();
            channel.identified = true;
            channel.track_main = true;
            channel.ready = true;
            world.codex.main.channels.borrow_mut().insert(FIRST.into(), Rc::new(RefCell::new(channel)));
        }
        world.observe(&binding);
        world
    }
    fn observe(&mut self, binding: &Binding) {
        // A verified binding reaches the harness through chat/history, with or without native IO.
        self.codex.statuses.borrow_mut().insert((binding.process.pid, binding.process.start), Some(binding.session.clone()));
        self.codex.history(&mut self.io, binding, None, Box::new(|_, page| { page.unwrap(); }));
        self.drain();
    }
    fn drain(&mut self) {
        while let Some(work) = self.io.deferred.pop_front() { work(&mut self.io); }
    }
    fn hook(&mut self, session: &str, event: &str, agent: &str) {
        let message = format!(r#"{{"session_id":"{session}","hook_event_name":"{event}","agent_id":"{agent}","agent_type":"Explore"}}"#).into_bytes();
        self.codex.event(&mut self.io, &mut self.ui, Event::Hook { peer: None, route: 1, message, reply: None });
        self.drain();
    }
    fn native(&mut self, message: &str) {
        self.io.incoming.push_back(format!("{message}\n").into_bytes());
        self.codex.event(&mut self.io, &mut self.ui, Event::Ready { fd: 11, read: true, write: true });
        self.codex.event(&mut self.io, &mut self.ui, Event::Ready { fd: 10, read: false, write: true });
        self.drain();
        let at = self.io.now();
        self.codex.event(&mut self.io, &mut self.ui, Event::Timer { at });
        self.drain();
    }
    fn state(&self, session: &str) -> State {
        self.codex.states.borrow().get(session).cloned().unwrap_or_default()
    }
}

#[test]
fn background_agents_survive_turn_end_and_repeated_observation() {
    let mut world = World::new(true);
    world.hook(FIRST, "SubagentStart", "agent-a");
    world.hook(FIRST, "SubagentStart", "agent-a");
    world.native(&format!(r#"{{"method":"turn/completed","params":{{"threadId":"{FIRST}","turn":{{"id":"turn-a","status":"completed"}}}}}}"#));
    let mut refreshed = binding(FIRST);
    refreshed.process.arguments = vec!["codex".into(), "resume".into(), FIRST.into()];
    world.observe(&refreshed);
    assert_eq!(world.state(FIRST).agents.iter().map(|agent| agent.id.as_str()).collect::<Vec<_>>(), ["agent-a"]);
    world.hook(FIRST, "SubagentStop", "agent-a");
    assert!(world.state(FIRST).agents.is_empty());
}

#[test]
fn new_and_resume_clear_the_previous_roster_without_session_hooks() {
    let mut world = World::new(true);
    world.hook(FIRST, "SubagentStart", "agent-a");
    world.native(&format!(r#"{{"method":"thread/started","params":{{"thread":{{"id":"{SECOND}","source":"cli","ephemeral":false}}}}}}"#));
    assert!(world.state(FIRST).agents.is_empty());
    assert!(!world.codex.bindings.contains_key(FIRST));
    world.hook(FIRST, "SubagentStart", "late-agent");
    world.hook(SECOND, "SubagentStart", "agent-b");
    assert_eq!(world.state(SECOND).agents.len(), 1);
    // /resume is a status notification followed by a verified thread/read response.
    world.native(&format!(r#"{{"method":"thread/status/changed","params":{{"threadId":"{FIRST}","status":{{"type":"idle"}}}}}}"#));
    let requests: Vec<_> = world.io.written.split(|byte| *byte == b'\n').filter(|line| !line.is_empty())
        .map(|line| Json::parse(line).unwrap()).collect();
    let request = requests.iter().find(|doc| doc.root().get("method").and_then(Value::string) == Some("thread/read")).unwrap();
    let id = request.root().get("id").unwrap().signed().unwrap();
    world.native(&format!(r#"{{"id":{id},"result":{{"thread":{{"id":"{FIRST}","source":"cli","ephemeral":false}}}}}}"#));
    assert!(world.codex.bindings.contains_key(FIRST));
    assert!(world.state(SECOND).agents.is_empty());
    world.hook(FIRST, "SubagentStart", "agent-c");
    assert_eq!(world.state(FIRST).agents.iter().map(|agent| agent.id.as_str()).collect::<Vec<_>>(), ["agent-c"]);
}

#[test]
fn process_replacement_and_exit_clear_activity_without_a_native_channel() {
    let mut world = World::new(false);
    world.hook(FIRST, "SubagentStart", "agent-a");
    let mut resumed = binding(FIRST);
    resumed.process.start = [8, 9]; // Same PID and conversation, a different process.
    world.observe(&resumed);
    assert!(world.state(FIRST).agents.is_empty());
    world.hook(FIRST, "SubagentStart", "agent-b");
    assert_eq!(world.state(FIRST).agents.len(), 1);
    world.codex.exited(&mut world.io, &binding(FIRST).process, None);
    assert_eq!(world.state(FIRST).agents.len(), 1, "An old process's exit cannot clear its replacement");
    world.codex.exited(&mut world.io, &resumed.process, None);
    assert!(world.state(FIRST).agents.is_empty());
    assert!(!world.codex.bindings.contains_key(FIRST));
    world.observe(&resumed);
    world.hook(FIRST, "SubagentStart", "agent-c");
    assert_eq!(world.state(FIRST).agents.len(), 1, "The previous process's roster was forgotten");
}

#[test]
fn native_compaction_and_thread_closure_need_no_lifecycle_hooks() {
    let mut world = World::new(true);
    world.hook(FIRST, "SubagentStart", "agent-a");
    let compact = |method| format!(r#"{{"method":"{method}","params":{{"threadId":"{FIRST}","item":{{"id":"compact-a","type":"contextCompaction"}}}}}}"#);
    world.native(&compact("item/started"));
    assert!(world.state(FIRST).compacting);
    world.native(&compact("item/completed"));
    assert!(!world.state(FIRST).compacting);
    assert_eq!(world.state(FIRST).agents.len(), 1);
    world.native(&compact("item/started"));
    world.native(&format!(r#"{{"method":"thread/closed","params":{{"threadId":"{FIRST}"}}}}"#));
    assert!(!world.state(FIRST).compacting);
    assert!(world.state(FIRST).agents.is_empty());
    assert!(matches!(world.ui.0.last(), Some(Update::State { state, .. }) if !state.compacting && state.agents.is_empty()));
    world.hook(FIRST, "SubagentStart", "agent-b");
    assert_eq!(world.state(FIRST).agents.len(), 1);
}

#[test]
fn closing_a_side_or_its_parent_forgets_the_sides_agents() {
    for close_parent in [false, true] {
        let mut world = World::new(true);
        let channel = world.codex.main.channels.borrow_mut().remove(FIRST).unwrap();
        world.codex.sides.borrow_mut().insert(FIRST.into(), channel);
        let mut parent = binding(SECOND).process;
        parent.pid = 43;
        world.codex.parents.borrow_mut().insert(FIRST.into(), parent.clone());
        world.hook(FIRST, "SubagentStart", "agent-a");
        assert_eq!(world.state(FIRST).agents.len(), 1);
        if close_parent {
            world.codex.exited(&mut world.io, &parent, None);
        } else {
            world.codex.side_close(&mut world.io, &binding(FIRST), Box::new(|_, result| result.unwrap()));
            world.drain();
        }
        assert!(world.state(FIRST).agents.is_empty());
        assert!(!world.codex.bindings.contains_key(FIRST));
        world.hook(FIRST, "SubagentStart", "late-agent");
        world.observe(&binding(FIRST));
        world.hook(FIRST, "SubagentStart", "agent-b");
        assert_eq!(world.state(FIRST).agents.len(), 1);
    }
}
