//! The native prompt watch over a screen the helper reads itself: an open prompt is sampled, so it closes as soon as
//! the terminal stops showing it, not when the paced read of the next change comes.
use super::*;
use std::{
    io,
    os::fd::RawFd,
    path::{Path, PathBuf},
    process::Command,
    time::Instant,
};

/// Deferred work and Io::after callbacks, run when the test says; a clock the test moves.
struct Clock {
    now: Instant,
    deferred: VecDeque<Box<dyn FnOnce(&mut dyn Io)>>,
    later: Vec<(Instant, Box<dyn FnOnce(&mut dyn Io)>)>,
}
impl Clock {
    fn settle(&mut self) {
        while let Some(work) = self.deferred.pop_front() {
            work(self);
        }
    }
    /// Move to `ms` after `start`, run the callbacks due by then.
    fn at(&mut self, start: Instant, ms: u64) {
        self.now = start + Duration::from_millis(ms);
        let now = self.now;
        let (due, later): (Vec<_>, Vec<_>) = std::mem::take(&mut self.later).into_iter().partition(|(at, _)| *at <= now);
        self.later = later;
        for (_, work) in due {
            work(self);
        }
        self.settle();
    }
}
#[rustfmt::skip]
impl Io for Clock {
    fn now(&self) -> Instant { self.now }
    fn timer(&mut self, _: Instant) {}
    fn defer(&mut self, work: Box<dyn FnOnce(&mut dyn Io)>) { self.deferred.push_back(work); }
    fn after(&mut self, at: Instant, work: Box<dyn FnOnce(&mut dyn Io)>) -> io::Result<()> { self.later.push((at, work)); Ok(()) }
    fn interest(&mut self, _: RawFd, _: bool, _: bool) -> io::Result<()> { unreachable!() }
    fn read(&mut self, _: RawFd, _: &mut [u8]) -> io::Result<usize> { unreachable!() }
    fn write(&mut self, _: RawFd, _: &[u8]) -> io::Result<usize> { unreachable!() }
    fn close(&mut self, _: RawFd) { unreachable!() }
    fn accept(&mut self, _: RawFd) -> io::Result<RawFd> { unreachable!() }
    fn child(&mut self, _: u32) -> io::Result<()> { unreachable!() }
    fn submit(&mut self, _: Job) -> io::Result<Work> { unreachable!() }
    fn cancel(&mut self, _: Work) -> bool { unreachable!() }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> { unreachable!() }
    fn unwatch(&mut self, _: u64) { unreachable!() }
    fn spawn(&mut self, _: Command, _: Option<Grid>) -> io::Result<Spawned> { unreachable!() }
    fn resize(&mut self, _: RawFd, _: Grid) -> io::Result<()> { unreachable!() }
    fn hangup(&mut self, _: RawFd) -> io::Result<()> { unreachable!() }
    fn connect(&mut self, _: &Address) -> io::Result<RawFd> { unreachable!() }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> { unreachable!() }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> { unreachable!() }
}

/// A pane whose screen is `now`; reads of a change wait until the test answers them (a paced host read).
struct Pane {
    now: Rc<RefCell<String>>,
    hosted: bool,
    reads: Rc<RefCell<Vec<bool>>>,
}
fn screen(text: &str) -> Screen {
    Screen { text: text.into(), cursor: (0, 0), faint_tail: false }
}
#[rustfmt::skip]
impl Multiplexer for Pane {
    fn name(&self) -> &str { "pane" }
    fn external(&self) -> bool { true }
    fn harnesses(&mut self, _: Vec<Shared<dyn Harness>>) {}
    fn backends(&mut self, _: &mut dyn Io, _: Done<Vec<String>>) { unreachable!() }
    fn open(&mut self, _: &mut dyn Io, _: &str, _: Done<Id>) { unreachable!() }
    fn rename(&mut self, _: &mut dyn Io, _: Id, _: &str, _: Done<()>) { unreachable!() }
    fn focus(&mut self, _: &mut dyn Io, _: Id, _: Done<()>) { unreachable!() }
    fn r#move(&mut self, _: &mut dyn Io, _: Id, _: Id, _: Option<Id>, _: Done<()>) { unreachable!() }
    fn split(&mut self, _: &mut dyn Io, _: Id, _: f64, _: Done<()>) { unreachable!() }
    fn zoom(&mut self, _: &mut dyn Io, _: Id, _: bool, _: Done<()>) { unreachable!() }
    fn close(&mut self, _: &mut dyn Io, _: Id, _: Close, _: Done<()>) { unreachable!() }
    fn attach(&mut self, _: &mut dyn Io, _: Id, _: Grid, _: bool, _: bool, _: Done<()>) { unreachable!() }
    fn create(&mut self, _: &mut dyn Io, _: Id, _: Option<Id>, _: Option<Command>, _: Option<Grid>, _: Done<Id>) { unreachable!() }
    fn input(&mut self, _: &mut dyn Io, _: Id, _: &[u8], _: Done<()>) { unreachable!() }
    fn keys(&mut self, _: &mut dyn Io, _: Id, _: &Process, _: &[Input], _: Done<()>) { unreachable!() }
    fn resize(&mut self, _: &mut dyn Io, _: Id, _: Grid, _: Done<()>) { unreachable!() }
    fn scroll(&mut self, _: &mut dyn Io, _: Id, _: &Scroll, _: Done<()>) { unreachable!() }
    fn screen(&mut self, io: &mut dyn Io, _: Id, changed: bool, done: Done<Screen>) {
        self.reads.borrow_mut().push(changed);
        // The first read gets the screen; later changed reads never come back here (the paced capture is late).
        if !changed || self.reads.borrow().len() == 1 {
            deferred(done)(io, Ok(screen(&self.now.borrow())));
        }
    }
    fn publish(&mut self, _: &mut dyn Io, _: Id, _: Screen) { unreachable!() }
    fn event(&mut self, _: &mut dyn Io, _: &mut dyn Ui, _: Event) { unreachable!() }
    fn hosted(&self, _: Id) -> bool { self.hosted }
}

/// A harness whose prompt is any screen that says "Question".
struct Asking;
#[rustfmt::skip]
impl Harness for Asking {
    fn name(&self) -> &str { "asking" }
    fn launch(&mut self, _: &mut dyn Io, _: &Path, _: &[String], _: Done<Command>) { unreachable!() }
    fn command(&mut self, _: &mut dyn Io, _: &Binding, _: &str, _: Done<Outcome>) { unreachable!() }
    fn hook(&mut self, _: &Json) -> Result<Hook, Error> { unreachable!() }
    fn state(&mut self, _: &mut dyn Io, _: &Binding, _: Done<State>) { unreachable!() }
    fn commands(&self, _: &Binding) -> Vec<String> { unreachable!() }
    fn stop(&mut self, _: &mut dyn Io, _: &Binding, _: Done<Sent>) { unreachable!() }
    fn models(&mut self, _: &mut dyn Io, _: &Binding, _: Done<Menu>) { unreachable!() }
    fn efforts(&mut self, _: &mut dyn Io, _: &Binding, _: &str, _: Done<Menu>) { unreachable!() }
    fn menu(&mut self, _: &mut dyn Io, _: &Binding, _: &Goal, _: &Screen, _: bool) -> Step { unreachable!() }
    fn tool(&mut self, _: &mut dyn Io, _: &Binding, _: &str, _: Done<Record>) { unreachable!() }
    fn queue(&mut self, _: &mut dyn Io, _: &Binding, _: Done<Vec<Queued>>) { unreachable!() }
    fn queue_order(&mut self, _: &mut dyn Io, _: &Binding, _: &[String], _: Done<()>) { unreachable!() }
    fn side_close(&mut self, _: &mut dyn Io, _: &Binding, _: Done<()>) { unreachable!() }
    fn event(&mut self, _: &mut dyn Io, _: &mut dyn Ui, _: Event) { unreachable!() }
    fn identify(&mut self, _: &mut dyn Io, _: &Process, _: Option<&Hook>, _: Done<Option<Binding>>) { unreachable!() }
    fn history(&mut self, _: &mut dyn Io, _: &Binding, _: Option<&str>, _: Done<Page>) { unreachable!() }
    fn send(&mut self, _: &mut dyn Io, _: &Binding, _: &str, _: Mode, _: bool, _: Done<Sent>) { unreachable!() }
    fn select(&mut self, _: &mut dyn Io, _: &Binding, _: &str, _: Option<&str>, _: Done<Sent>) { unreachable!() }
    fn answer(&mut self, _: &mut dyn Io, _: &Binding, _: &str, _: Vec<(String, Answer)>, _: Done<Sent>) { unreachable!() }
    fn queue_add(&mut self, _: &mut dyn Io, _: &Binding, _: &str, _: Mode, _: Done<Queued>) { unreachable!() }
    fn queue_edit(&mut self, _: &mut dyn Io, _: &Binding, _: &str, _: u64, _: Option<&str>, _: Done<()>) { unreachable!() }
    fn queue_send(&mut self, _: &mut dyn Io, _: &Binding, _: &str, _: u64, _: Mode, _: Done<Sent>) { unreachable!() }
    fn side(&mut self, _: &mut dyn Io, _: &Binding, _: &str, _: bool, _: Done<Binding>) { unreachable!() }
    fn install(&mut self, _: &mut dyn Io, _: &Path, _: Option<bool>, _: Option<&Binding>, _: Done<Install>) { unreachable!() }
    fn prompt(&mut self, _: &Binding, screen: &Screen) -> Option<Interaction> {
        screen.text.contains("Question").then(|| Interaction {
            id: "prompt:Question".into(), key: None, approval: false, blocking: true,
            questions: Vec::new(), turn: None, record: None,
        })
    }
}

/// Whether the prompt is open at 10, 33, 50, 70 and 100 ms for a pane that showed it and then, from the start, its
/// answered screen; and the reads asked (whether each asked for a change).
fn watched(hosted: bool) -> (Vec<bool>, Vec<bool>) {
    let t0 = Instant::now();
    let mut io = Clock { now: t0, deferred: VecDeque::new(), later: Vec::new() };
    let (now, reads) = (Rc::new(RefCell::new("Question 1/2".to_owned())), Rc::new(RefCell::new(Vec::new())));
    let mux: Shared<dyn Multiplexer> = Rc::new(RefCell::new(Pane { now: now.clone(), hosted, reads: reads.clone() }));
    let (prompts, updates): (Prompts, _) = Default::default();
    let binding = Binding {
        session: "s1".into(),
        transcript: None,
        process: Process {
            pid: 42, parent: 1, group: 42, foreground: 42, tty: 1, start: [1, 0],
            executable: "/bin/agent".into(), arguments: Vec::new(), files: Vec::new(),
        },
    };
    let harness: Shared<dyn Harness> = Rc::new(RefCell::new(Asking));
    start(&mut io, &prompts, &updates, mux, harness, 7, 7, binding);
    io.settle();
    // The pane shows the answer; tmux would read it once it settled.
    *now.borrow_mut() = "Answered".into();
    let mut open = Vec::new();
    for ms in [10, 33, 50, 70, 100] {
        io.at(t0, ms);
        open.push(prompts.borrow()[&7].2.is_some());
    }
    let reads = reads.borrow().clone();
    (open, reads)
}

#[test]
fn an_open_prompt_on_a_host_read_screen_closes_at_the_next_sample() {
    let (open, reads) = watched(true);
    // Opened by the first read; the sample at 33 ms reads the answered screen and closes it.
    assert_eq!(open, [true, false, false, false, false]);
    // The watch's own read of the next change still waits; one sample, and none once the prompt closed.
    assert_eq!(reads, [false, true, false]);
}

#[test]
fn a_published_screen_is_not_sampled() {
    // The client publishes every change itself (and nothing new is asked of the multiplexer for it).
    let (open, reads) = watched(false);
    assert_eq!(open, [true; 5]);
    assert_eq!(reads, [false, true]);
}
