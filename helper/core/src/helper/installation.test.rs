use super::*;
use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    io,
    os::fd::RawFd,
    path::{Path, PathBuf},
    process::Command,
    time::Instant,
};
#[derive(Default)]
struct Queue(VecDeque<Box<dyn FnOnce(&mut dyn Io)>>);
#[rustfmt::skip]
impl Io for Queue {
    fn now(&self) -> Instant { Instant::now() }
    fn timer(&mut self, at: Instant) { let _ = at; unreachable!() }
    fn defer(&mut self, work: Box<dyn FnOnce(&mut dyn Io)>) { self.0.push_back(work); }
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

fn exercise(errors: &[&'static str], revoke: bool) -> (usize, Result<Install, Error>) {
    let calls = Rc::new(Cell::new(0));
    let allowed = Rc::new(Cell::new(true));
    let result = Rc::new(RefCell::new(None));
    let mut io = Queue::default();
    let (n, permit, output) = (calls.clone(), allowed.clone(), result.clone());
    let errors = errors.to_vec();
    run(
        &mut io,
        Rc::new(move || permit.get()),
        Rc::new(move |io, done| {
            let index = n.get();
            n.set(index + 1);
            if revoke {
                allowed.set(false);
            }
            done(
                io,
                errors.get(index).map_or(Ok(Install::default()), |code| {
                    Err(Error {
                        code,
                        message: "test failure".into(),
                    })
                }),
            );
        }),
        Box::new(move |_, value| *output.borrow_mut() = Some(value)),
    );
    while let Some(work) = io.0.pop_front() {
        work(&mut io);
    }
    let value = result.borrow_mut().take().unwrap();
    (calls.get(), value)
}

#[test]
fn setup_replans_conflicts_but_bounds_contention() {
    let (calls, result) = exercise(&["changed", "changed"], false);
    assert_eq!(calls, 3);
    assert!(result.is_ok());
    let (calls, result) = exercise(&["changed"; 8], false);
    assert_eq!(calls, 3);
    assert_eq!(result.unwrap_err().code, "changed");
}

#[test]
fn setup_never_retries_process_failures_partial_writes_or_revoked_permission() {
    for code in ["process", "uncertain", "io", "settings"] {
        let (calls, result) = exercise(&[code], false);
        assert_eq!(calls, 1);
        assert_eq!(result.unwrap_err().code, code);
    }
    let (calls, result) = exercise(&["changed"], true);
    assert_eq!(calls, 1);
    assert!(result.is_err());
}
