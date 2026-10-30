use super::*;
use std::{cell::RefCell, path::Path, rc::Rc};

fn frame(seq: u64, width: u64, height: u64, full: bool, bytes: &[u8]) -> Vec<u8> {
    json::write(&D::Object(vec![
        ("bytes", D::String(&native::encode(bytes))),
        ("encoding", D::String("ansi")),
        ("full", D::Bool(full)),
        ("height", D::Unsigned(height)),
        ("seq", D::Unsigned(seq)),
        ("type", D::String("terminal.frame")),
        ("width", D::Unsigned(width)),
    ]))
    .unwrap()
}

fn observer() -> Observer {
    Observer::new(Instant::now())
}

/// What herdr 0.9.5's observer sends for a 20x3 pane (rows padded, styles reset per run, the cursor last).
const FULL: &[u8] = b"\x1b[?2026h\x1b[?25l\x1b]8;;\x1b\\\x1b[2J\x1b[1;1H\x1b[0;39;49m\xe2\x9d\xaf \x1b[0;38;2;0;0;0;48;2;255;255;255mT\x1b[0;2;39;49mry it\x1b[0;39;49m           \x1b[2;1H                    \x1b[3;1H                    \x1b[0m\x1b[1;3H\x1b[?25h\x1b[?2026l\x1b[1;3H\x1b[?25h";

#[test]
fn a_full_frame_then_changes_draw_the_screen_a_client_renders() {
    let mut observer = observer();
    let first = observer.line(&frame(1, 20, 3, true, FULL)).unwrap().unwrap();
    let blank = " ".repeat(20);
    assert_eq!(
        first,
        Screen {
            text: format!("❯ Try it{}\n{blank}\n{blank}", " ".repeat(11)),
            cursor: (2, 0),
            faint_tail: true,
        }
    );
    // Typing replaces the placeholder; the cursor follows the text.
    let typed = observer
        .line(&frame(2, 20, 3, false, b"\x1b[?2026h\x1b[?25l\x1b[1;3H\x1b[0;39;49mhi    \x1b[0m\x1b[1;5H\x1b[?25h\x1b[?2026l"))
        .unwrap()
        .unwrap();
    assert_eq!(typed.cursor, (4, 0));
    assert!(typed.text.starts_with("❯ hi "));
    assert!(!typed.faint_tail);
}

#[test]
fn old_frames_and_other_messages_draw_nothing() {
    let mut observer = observer();
    observer.line(&frame(5, 20, 3, true, FULL)).unwrap().unwrap();
    assert_eq!(observer.line(&frame(5, 20, 3, false, b"x")).unwrap(), None);
    assert_eq!(observer.line(&frame(4, 20, 3, true, b"x")).unwrap(), None);
    assert_eq!(observer.line(br#"{"type":"terminal.title","title":"x"}"#).unwrap(), None);
}

#[test]
fn a_change_needs_the_full_frame_it_applies_to() {
    // The first frame, a reset or a resize waits for a full frame; a change instead restarts the observer.
    assert!(observer().line(&frame(1, 20, 3, false, b"x")).is_err());
    let mut reset = observer();
    reset.line(&frame(1, 20, 3, true, FULL)).unwrap();
    assert_eq!(reset.line(br#"{"type":"terminal.reset"}"#).unwrap(), None);
    assert!(reset.line(&frame(2, 20, 3, false, b"x")).is_err());
    let mut resized = observer();
    resized.line(&frame(1, 20, 3, true, FULL)).unwrap();
    assert!(resized.line(&frame(2, 30, 3, false, b"x")).is_err());
    let screen = resized.line(&frame(3, 30, 4, true, b"\x1b[2J\x1b[4;1Hlast\x1b[4;5H")).unwrap().unwrap();
    assert_eq!(screen, Screen { text: "\n\n\nlast".into(), cursor: (4, 3), faint_tail: false });
}

#[test]
fn a_frame_the_grid_cannot_draw_fails() {
    let mut observer = observer();
    observer.line(&frame(1, 20, 3, true, FULL)).unwrap();
    let error = observer.line(&frame(2, 20, 3, false, b"\x1b[1;2r")).unwrap_err();
    assert!(error.message.starts_with("Herdr frame not drawn"), "{}", error.message);
    assert!(observer.line(br#"{"type":"terminal.frame","seq":1}"#).is_err());
    assert!(observer.line(&frame(9, 0, 3, true, b"")).is_err());
}

#[test]
fn a_closed_terminal_expires() {
    let error = observer()
        .line(br#"{"type":"terminal.closed","reason":"terminal term_1 exited"}"#)
        .unwrap_err();
    assert_eq!((error.code, error.message.as_str()), ("expired", "terminal term_1 exited"));
}

fn herdr() -> Herdr {
    Herdr::new(Config {
        executable: "/opt/herdr".into(),
        socket: "/tmp/hs/hd.sock".into(),
        session: "main".into(),
        directory: "/tmp".into(),
        environment: BTreeMap::new(),
        uid: 501,
    })
}

/// A clock and the timers asked; nothing else is asked of an Io here.
struct Clock(Instant, Vec<Instant>);
#[rustfmt::skip]
impl Io for Clock {
    fn now(&self) -> Instant { self.0 }
    fn timer(&mut self, at: Instant) { self.1.push(at) }
    fn defer(&mut self, callback: Box<dyn FnOnce(&mut dyn Io)>) { callback(self) }
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

#[test]
fn host_screens_are_off_until_enabled_and_never_for_a_published_terminal() {
    let mut herdr = herdr();
    assert!(!herdr.hosted(7));
    Multiplexer::host_screens(&mut herdr, true);
    assert!(herdr.hosted(7));
    herdr.published.insert(7);
    assert!(!herdr.hosted(7));
    assert!(herdr.hosted(8));
    // A client's attachment (a controller) does not stop host reads; only a publication does.
    herdr.controllers.insert(8, Controller::new(Grid { rows: 3, columns: 20, pixels: None }, true));
    assert!(herdr.hosted(8));
}

#[test]
fn a_screens_host_attach_hosts_until_a_client_publishes_and_again_once_it_left() {
    let mut io = Clock(Instant::now(), Vec::new());
    let mut herdr = herdr();
    // A client helper reads only published screens.
    assert!(!herdr.hosted(7));
    Multiplexer::screen_clients(&mut herdr, &mut io, 7, true, false);
    assert!(herdr.hosted(7));
    assert!(!herdr.hosted(8), "only the terminal attached");
    let screen = Screen { text: "published".into(), cursor: (0, 0), faint_tail: false };
    Multiplexer::publish(&mut herdr, &mut io, 7, screen);
    assert!(!herdr.hosted(7), "a publication wins");
    // The publisher's attach ended (core tells it): host reads resume.
    Multiplexer::screen_clients(&mut herdr, &mut io, 7, true, false);
    assert!(herdr.hosted(7));
    Multiplexer::screen_clients(&mut herdr, &mut io, 7, false, false);
    assert!(!herdr.hosted(7));
}

fn screen(text: &str) -> Screen {
    Screen { text: text.into(), cursor: (0, 0), faint_tail: false }
}

/// When drawn screens reach the readers (ms) for frames at `frames` (ms), with Timer events where asked; the first
/// frame finds nothing shown.
fn settled(frames: &[u64], end: u64) -> Vec<u64> {
    let start = Instant::now();
    let mut observer = Observer::new(start);
    let (mut shown, mut published) = (false, Vec::new());
    for ms in 0..=end {
        let now = start + Duration::from_millis(ms);
        if frames.contains(&ms) && observer.drawn(now, screen(&ms.to_string()), shown).is_some() {
            published.push(ms);
            shown = true;
        }
        if observer.due().is_some_and(|due| due <= now) && observer.flush().is_some() {
            published.push(ms);
        }
    }
    published
}

#[test]
fn frames_reach_the_readers_once_settled_or_at_the_floor() {
    // The first frame at once; then frames every 50 ms for three seconds: one every 500 ms; then one a settle later.
    let frames: Vec<u64> = (0..3000).step_by(50).collect();
    let published = settled(&frames, 4000);
    assert_eq!(published, [0, 550, 1100, 1650, 2200, 2750, 3050]);
    for second in 0..3 {
        assert!(published.iter().filter(|ms| (second * 1000..(second + 1) * 1000).contains(*ms)).count() <= 3);
    }
    // A frame then quiet: once, a settle later.
    assert_eq!(settled(&[0, 300], 1000), [0, 400]);
}

#[test]
fn a_read_of_the_screen_now_takes_the_frame_drawn_last() {
    let mut io = Clock(Instant::now(), Vec::new());
    let mut herdr = herdr();
    Multiplexer::host_screens(&mut herdr, true);
    let mut observer = Observer::new(io.0 + Duration::from_secs(2));
    assert_eq!(observer.drawn(io.0, screen("first"), false), Some(screen("first")));
    assert_eq!(observer.drawn(io.0, screen("second"), true), None);
    assert_eq!(observer.due(), Some(io.0 + SETTLE));
    herdr.observers.insert(7, observer);
    herdr.flush_screen(&mut io, 7);
    assert_eq!(herdr.observers[&7].due(), None);
    let read = Rc::new(RefCell::new(None));
    let into = read.clone();
    herdr.screens.read(&mut io, 7, false, Box::new(move |_, screen| *into.borrow_mut() = Some(screen.unwrap())));
    assert_eq!(*read.borrow(), Some(screen("second")));
}
