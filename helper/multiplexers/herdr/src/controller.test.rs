//! One observer's repaint (terminals.follow, `Herdr::follow_restore`): the controller asks herdr for a full frame.
use super::*;
use std::{cell::RefCell, os::fd::RawFd, path::Path, rc::Rc};

/// The controller's pipes: what herdr sends next (`incoming`) and what the helper wrote.
#[derive(Default)]
struct Pipes {
    incoming: VecDeque<Vec<u8>>,
    written: Vec<u8>,
    deferred: VecDeque<Box<dyn FnOnce(&mut dyn Io)>>,
}
#[rustfmt::skip]
impl Io for Pipes {
    fn now(&self) -> Instant { Instant::now() }
    fn timer(&mut self, _: Instant) {}
    fn defer(&mut self, callback: Box<dyn FnOnce(&mut dyn Io)>) { self.deferred.push_back(callback) }
    fn interest(&mut self, _: RawFd, _: bool, _: bool) -> io::Result<()> { Ok(()) }
    fn read(&mut self, _: RawFd, bytes: &mut [u8]) -> io::Result<usize> {
        let line = self.incoming.pop_front().ok_or(io::ErrorKind::WouldBlock)?;
        bytes[..line.len()].copy_from_slice(&line);
        Ok(line.len())
    }
    fn write(&mut self, _: RawFd, bytes: &[u8]) -> io::Result<usize> { self.written.extend_from_slice(bytes); Ok(bytes.len()) }
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

/// Output and repaints as `O:bytes` and `R<token>:bytes`.
#[derive(Default)]
struct Shown(Vec<String>);
impl Ui for Shown {
    fn update(&mut self, update: Update) {
        match update {
            Update::Output { bytes, .. } => self.0.push(format!("O:{}", String::from_utf8_lossy(&bytes))),
            Update::Restore { token, bytes, .. } => self.0.push(format!("R{token}:{}", String::from_utf8_lossy(&bytes))),
            _ => {}
        }
    }
}

fn frame(seq: u64, full: bool, bytes: &[u8]) -> Vec<u8> {
    let mut line = json::write(&D::Object(vec![
        ("bytes", D::String(&native::encode(bytes))),
        ("encoding", D::String("ansi")),
        ("full", D::Bool(full)),
        ("height", D::Unsigned(3)),
        ("seq", D::Unsigned(seq)),
        ("type", D::String("terminal.frame")),
        ("width", D::Unsigned(20)),
    ]))
    .unwrap();
    line.push(b'\n');
    line
}

/// Terminal 7's controller, streaming (its first full frame drew), on pipes 10 and 11.
fn streaming() -> Herdr {
    let mut herdr = Herdr::new(Config {
        executable: "/opt/herdr".into(),
        socket: "/tmp/hs/hd.sock".into(),
        session: "main".into(),
        directory: "/tmp".into(),
        environment: BTreeMap::new(),
        uid: 501,
    });
    let mut controller = Controller::new(Grid { rows: 3, columns: 20, pixels: None }, false);
    controller.stream = Some(Stream::new(10, 11));
    controller.decoder.sequence = Some(1);
    controller.decoder.full = false;
    herdr.controllers.insert(7, controller);
    herdr
}

fn receive(herdr: &mut Herdr, io: &mut Pipes, line: Vec<u8>) -> Vec<String> {
    io.incoming.push_back(line);
    let mut shown = Shown::default();
    Multiplexer::event(herdr, io, &mut shown, Event::Ready { fd: 11, read: true, write: false });
    while let Some(callback) = io.deferred.pop_front() {
        callback(io);
    }
    shown.0
}

#[test]
fn a_repaint_is_the_next_full_frame_for_the_observer_that_asked() {
    let (mut herdr, mut io) = (streaming(), Pipes::default());
    assert_eq!(receive(&mut herdr, &mut io, frame(2, false, b"a")), ["O:a"]);
    let answered = Rc::new(RefCell::new(None));
    let into = answered.clone();
    Multiplexer::restore(&mut herdr, &mut io, 7, 9, Box::new(move |_, result| *into.borrow_mut() = Some(result.is_ok())));
    // herdr answers a resize, to the size it has too, with a full frame.
    let stream = herdr.controllers[&7].stream.as_ref().unwrap();
    assert_eq!(stream.queue.front().unwrap(), b"{\"type\":\"terminal.resize\",\"cols\":20,\"rows\":3}\n");
    // Changes before it apply to a screen the full frame replaces: nobody gets them.
    assert!(receive(&mut herdr, &mut io, frame(3, false, b"b")).is_empty());
    assert_eq!(*answered.borrow(), None);
    // Everyone else gets the full frame as output; the observer that asked, as its repaint in herdr's render mode.
    assert_eq!(receive(&mut herdr, &mut io, frame(4, true, b"FULL")), ["O:FULL", "R9:\x1b[?1049h\x1b[?7lFULL"]);
    assert_eq!(*answered.borrow(), Some(true));
    assert_eq!(receive(&mut herdr, &mut io, frame(5, true, b"again")), ["O:again"], "one repaint per ask");
    assert_eq!(receive(&mut herdr, &mut io, frame(6, false, b"c")), ["O:c"]);
}

#[test]
fn a_closed_terminal_fails_its_repaints() {
    let (mut herdr, mut io) = (streaming(), Pipes::default());
    let answered = Rc::new(RefCell::new(None));
    let into = answered.clone();
    Multiplexer::restore(&mut herdr, &mut io, 7, 9, Box::new(move |_, result| *into.borrow_mut() = Some(result.map_err(|e| e.code))));
    let mut controller = herdr.controllers.remove(&7).unwrap();
    controller.stream = None;
    controller.close(&mut io, expired("Herdr terminal closed."));
    while let Some(callback) = io.deferred.pop_front() {
        callback(&mut io);
    }
    assert_eq!(*answered.borrow(), Some(Err("expired")));
}
