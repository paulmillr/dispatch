use super::*;
use crate::{backend::Backend, client::Client};
use std::{
    cell::RefCell,
    collections::BTreeMap,
    io,
    os::fd::RawFd,
    path::{Path, PathBuf},
    process::Command,
    rc::Rc,
    time::{Duration, Instant},
};

/// A clock the test moves, and the timers asked; nothing else is asked of an Io here.
struct Clock {
    now: Instant,
    timers: Vec<Instant>,
}
#[rustfmt::skip]
impl Io for Clock {
    fn now(&self) -> Instant { self.now }
    fn timer(&mut self, at: Instant) { self.timers.push(at) }
    fn defer(&mut self, _: Box<dyn FnOnce(&mut dyn Io)>) { unreachable!() }
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
struct Quiet;
impl Ui for Quiet {
    fn update(&mut self, _: Update) {}
}

/// What one server is asked: a kill or a creation (`ordered`), a creation in flight settling, or a Timer event this many
/// milliseconds after the start.
enum Step {
    Kill,
    Create,
    Settle,
    At(u64),
}

/// The steps on one server with one client: the steps whose work ran, and when (ms); the timers asked (ms). A kill is
/// done as soon as it runs; a creation is in flight from when it runs until a Settle.
fn run(steps: &[Step]) -> (Vec<(usize, u64)>, Vec<u64>) {
    let start = Instant::now();
    let ms = move |at: Instant| (at - start).as_millis() as u64;
    let (mut io, mut tmux, ran) = (Clock { now: start, timers: Vec::new() }, Tmux::default(), Rc::new(RefCell::new(Vec::new())));
    tmux.backends.insert(1, Backend {
        key: "s1".into(),
        endpoint: None,
        clients: vec![Client::default()],
        ids: BTreeMap::new(),
        done: Vec::new(),
        opening: 0,
        views: BTreeMap::new(),
        selection: Default::default(),
        remote: false,
        identity: None,
        pending: BTreeMap::new(),
        order: Order::default(),
    });
    for (index, step) in steps.iter().enumerate() {
        let ran = ran.clone();
        match step {
            Step::Kill => tmux.ordered(&mut io, Some(1), true, Box::new(move |mux, io, ()| {
                ran.borrow_mut().push((index, ms(io.now())));
                mux.backends.get_mut(&1).unwrap().order.killing -= 1;
                mux.proceed(io, 1);
            })),
            Step::Create => tmux.ordered(&mut io, Some(1), false, Box::new(move |mux, io, ()| {
                ran.borrow_mut().push((index, ms(io.now())));
                mux.backends.get_mut(&1).unwrap().clients[0].creating += 1;
            })),
            Step::Settle => tmux.settle(&mut io, Location { backend: 1, client: 0, pane: 0 }, None),
            Step::At(at) => {
                io.now = start + Duration::from_millis(*at);
                let at = io.now;
                tmux.event(&mut io, &mut Quiet, Event::Timer { at });
            }
        }
    }
    let timers = io.timers.iter().map(|at| ms(*at)).collect();
    (ran.take(), timers)
}

#[test]
fn a_kill_waits_for_the_creations_in_flight_at_most_thirty_seconds() {
    use Step::*;
    // A creation that never settles holds the kill until its deadline, then no later kill; a creation after that does.
    assert_eq!(run(&[Create, Kill, At(29_999), At(30_000), Kill, Create, Kill]), (
        vec![(0, 0), (1, 30_000), (4, 30_000), (5, 30_000)],
        vec![30_000, 60_000],
    ));
    // One that settles in time (12 s) keeps the order: the kill runs then, the creation asked after it next; the kill
    // asked next waits for that creation, past the first deadline.
    assert_eq!(run(&[Create, Kill, Create, At(12_000), Settle, Kill, At(30_000)]), (
        vec![(0, 0), (1, 12_000), (2, 12_000)],
        vec![30_000, 42_000],
    ));
}
