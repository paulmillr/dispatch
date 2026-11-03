//! Answering an open question: the app addresses the conversation by its binding, whose process facts (open files)
//! are a snapshot that each identify takes again.
use super::*;
use std::{cell::RefCell, collections::VecDeque, io, os::fd::RawFd, path::Path, process::Command, rc::Rc};

const SESSION: &str = "4dd13d79-9d1a-4cab-8bbd-29cf0e7ec160";

/// Deferred completions run when the test settles; submitted jobs are only counted.
struct Queue {
    now: Instant,
    deferred: VecDeque<Box<dyn FnOnce(&mut dyn Io)>>,
    submitted: usize,
}
impl Queue {
    fn new() -> Self {
        Self { now: Instant::now(), deferred: VecDeque::new(), submitted: 0 }
    }
    fn settle(&mut self) {
        while let Some(work) = self.deferred.pop_front() {
            work(self);
        }
    }
}
#[rustfmt::skip]
impl Io for Queue {
    fn now(&self) -> Instant { self.now }
    fn timer(&mut self, _: Instant) {}
    fn defer(&mut self, work: Box<dyn FnOnce(&mut dyn Io)>) { self.deferred.push_back(work); }
    fn interest(&mut self, _: RawFd, _: bool, _: bool) -> io::Result<()> { unreachable!() }
    fn read(&mut self, _: RawFd, _: &mut [u8]) -> io::Result<usize> { unreachable!() }
    fn write(&mut self, _: RawFd, _: &[u8]) -> io::Result<usize> { unreachable!() }
    fn close(&mut self, _: RawFd) { unreachable!() }
    fn accept(&mut self, _: RawFd) -> io::Result<RawFd> { unreachable!() }
    fn child(&mut self, _: u32) -> io::Result<()> { unreachable!() }
    fn submit(&mut self, _: Job) -> io::Result<Work> { self.submitted += 1; Ok(self.submitted as Work) }
    fn cancel(&mut self, _: Work) -> bool { true }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> { unreachable!() }
    fn unwatch(&mut self, _: u64) { unreachable!() }
    fn spawn(&mut self, _: Command, _: Option<Grid>) -> io::Result<Spawned> { unreachable!() }
    fn resize(&mut self, _: RawFd, _: Grid) -> io::Result<()> { unreachable!() }
    fn hangup(&mut self, _: RawFd) -> io::Result<()> { unreachable!() }
    fn connect(&mut self, _: &Address) -> io::Result<RawFd> { unreachable!() }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> { unreachable!() }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> { Ok(()) }
}

fn question() -> Request {
    let text = format!(
        r#"{{"session_id":"{SESSION}","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_1",
            "tool_input":{{"questions":[{{"question":"Which language should the example use?","header":"Language",
            "options":[{{"label":"Swift"}},{{"label":"Python"}}]}}]}}}}"#
    );
    Request::new(Json::parse(text.as_bytes()).unwrap()).unwrap()
}

/// Claude's binding with the transcript open at this probe or not.
fn binding(open: bool) -> Binding {
    let transcript = PathBuf::from(format!("/tmp/sam-example/.claude/projects/-tmp-sam-example-work/{SESSION}.jsonl"));
    Binding {
        session: SESSION.into(),
        transcript: Some(transcript.clone()),
        process: Process {
            pid: 4242,
            parent: 4200,
            group: 4242,
            foreground: 4242,
            tty: 7,
            start: [1_700_000_000, 0],
            executable: "/tmp/sam-example/bin/claude".into(),
            arguments: vec!["claude".into()],
            files: if open {
                vec![OpenFile { path: transcript, identity: FileIdentity { device: 16, inode: 4096 } }]
            } else {
                Vec::new()
            },
        },
    }
}

/// Interactions with the question open for `opened`; its interaction id.
fn opened(io: &Queue, opened: Binding) -> (Interactions, String) {
    let request = question();
    let id = request.interaction.id.clone();
    let mut interactions = Interactions::default();
    interactions.pending.insert(id.clone(), Pending {
        binding: opened,
        request,
        reply: 1,
        until: io.now() + Duration::from_secs(180),
        answering: false,
    });
    (interactions, id)
}

fn answer(interactions: &mut Interactions, io: &mut Queue, through: &Binding, id: &str) -> Rc<RefCell<Option<Result<Sent, Error>>>> {
    let result = Rc::new(RefCell::new(None));
    let sink = result.clone();
    let answers = vec![("Which language should the example use?".into(), Answer::Text("Python λ with examples".into()))];
    interactions.answer(io, through, id, answers, Box::new(move |_, r| *sink.borrow_mut() = Some(r)), None, false);
    io.settle();
    result
}

#[test]
fn a_question_answers_through_a_binding_whose_open_files_changed() {
    let mut io = Queue::new();
    // The hook's probe saw Claude with its transcript open; the topology the app answers through, without it.
    let (mut interactions, id) = opened(&io, binding(true));
    assert_eq!(interactions.cards(&binding(false)).len(), 1, "a chat that opens gets the open question");
    let result = answer(&mut interactions, &mut io, &binding(false), &id);
    assert!(result.borrow().is_none(), "the answer goes on to verify Claude: {:?}", result.borrow());
    assert_eq!(io.submitted, 1);
    assert!(interactions.pending[&id].answering);
}

#[test]
fn a_question_refuses_an_answer_for_another_conversation_or_process() {
    let mut other_session = binding(true);
    other_session.session = "0d8d4f4c-1f0b-4f4e-9c55-6b8f0c0a1e2d".into();
    let mut restarted = binding(true);
    restarted.process.start = [1_700_000_100, 0];
    let mut reused_pid = binding(true);
    reused_pid.process.pid = 4343;
    for through in [other_session, restarted, reused_pid] {
        let mut io = Queue::new();
        let (mut interactions, id) = opened(&io, binding(true));
        assert!(interactions.cards(&through).is_empty());
        let result = answer(&mut interactions, &mut io, &through, &id);
        let code = result.borrow().as_ref().map(|r| r.as_ref().err().map(|e| e.code));
        assert_eq!(code, Some(Some("changed")));
        assert_eq!(io.submitted, 0);
        assert!(!interactions.pending[&id].answering);
    }
}
