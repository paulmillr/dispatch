//! One observer's repaint (terminals.follow, `Tmux::follow_restore`) next to the shared output stream.
use super::*;
use crate::{backend::Backend, client::Client, snapshot::{Pane, Snapshot}};
use std::{
    cell::RefCell,
    collections::{BTreeMap, VecDeque},
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
    fn timer(&mut self, _: Instant) {}
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

/// Pane %3 of session $1 (4 columns, 2 rows) is terminal 7, attached and streaming.
fn streaming() -> (Tmux, Location) {
    let mut tmux = Tmux::default();
    let pane = Pane { width: 4, height: 2, title: String::new(), pid: 0, tty: String::new() };
    let snapshot = Snapshot {
        windows: Vec::new(),
        panes: BTreeMap::from([(3, pane)]),
        session: 1,
        client: 0,
        server: 0,
        socket: String::new(),
        name: String::new(),
    };
    let mut client = Client::default();
    client.snapshot = Some(snapshot);
    tmux.backends.insert(1, Backend {
        key: "s1".into(),
        endpoint: None,
        clients: vec![client],
        ids: BTreeMap::from([("$1:%3".to_owned(), 7)]),
        done: Vec::new(),
        opening: 0,
        views: BTreeMap::new(),
        selection: Default::default(),
        remote: false,
        identity: None,
        pending: BTreeMap::new(),
        order: Default::default(),
    });
    tmux.terminals.insert(7, Terminal { ready: true, history: true, ..Terminal::default() });
    (tmux, Location { backend: 1, client: 0, pane: 3 })
}

/// capture.tmux's five replies for a pane showing `rows`.
fn batch(rows: &[&str], width: u32) -> crate::client::Batch {
    let lines = |rows: &[&str]| rows.iter().collect::<control::Lines>();
    vec![
        lines(rows),
        lines(&[]),
        lines(&[rows[rows.len() - 1]]),
        lines(&[&format!("pane_id=%3|pane_width={width}|pane_height=2|cursor_x=1|cursor_y=1")]),
        lines(&[""]),
    ]
}

#[test]
fn a_repaint_reaches_one_observer_and_leaves_the_shared_stream_alone() {
    let (mut tmux, loc) = streaming();
    let mut io = Queue::default();
    // A sequence the pane has not finished yet: the shared filter holds its start.
    tmux.output(&mut io, loc, b"ab\x1b[3");
    assert!(tmux.updates.iter().all(|update| matches!(update, Update::Output { bytes, .. } if bytes == b"ab")));
    tmux.updates.clear();
    let answered = Rc::new(Cell::new(None));
    let seen = answered.clone();
    tmux.repainted(&mut io, loc, 7, 9, 0, Ok(batch(&["hist", "x"], 4)), Box::new(move |_, result| seen.set(Some(result.is_ok()))));
    while let Some(work) = io.0.pop_front() {
        work(&mut io);
    }
    assert_eq!(answered.get(), Some(true));
    let [Update::Restore { terminal: 7, token: 9, bytes }] = &tmux.updates[..] else {
        panic!("one repaint and no output for the other observers")
    };
    // The whole history again, as the restore after %pause: that observer's scrollback is complete.
    assert!(bytes.starts_with(b"\x1bc"));
    assert!(String::from_utf8_lossy(bytes).contains("hist"));
    tmux.updates.clear();
    // The stream goes on where it was for everyone: no gap, the unfinished sequence arrives whole.
    let state = &tmux.terminals[&7];
    assert!(state.ready && !state.capturing);
    tmux.output(&mut io, loc, b"1mz");
    let [Update::Output { bytes, .. }] = &tmux.updates[..] else { panic!("the output after the repaint") };
    assert_eq!(bytes, b"\x1b[31mz");
}

#[test]
fn a_repaint_of_a_pane_gone_or_sized_otherwise_fails() {
    let (mut tmux, loc) = streaming();
    let mut io = Queue::default();
    let answered = Rc::new(RefCell::new(Vec::new()));
    for (attempts, width) in [(2, 5), (0, 4)] {
        let seen = answered.clone();
        if width == 4 {
            tmux.terminals.remove(&7);
        }
        tmux.repainted(&mut io, loc, 7, 9, attempts, Ok(batch(&["x"], width)), Box::new(move |_, result: Result<(), Error>| {
            seen.borrow_mut().push(result.unwrap_err().message)
        }));
    }
    while let Some(work) = io.0.pop_front() {
        work(&mut io);
    }
    assert_eq!(*answered.borrow(), ["Tmux pane size kept changing during capture", "Tmux pane detached during capture"]);
    assert!(tmux.updates.is_empty());
}
