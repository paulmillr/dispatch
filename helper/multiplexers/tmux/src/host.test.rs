use super::*;

fn lines(rows: &[&str]) -> control::Lines {
    rows.iter().collect()
}

fn capture(screen: &[&str], row: &str, state: &str) -> Result<Screen, Error> {
    parse(&[lines(screen), lines(&[row]), lines(&[state])], 3)
}

#[test]
fn one_batch_reads_screen_cursor_row_and_cursor() {
    assert_eq!(
        commands(3),
        [
            "capture-pane -p -J -N -C -t %3",
            "capture-pane -p -e -N -C -t %3 -S \"#{cursor_y}\" -E \"#{cursor_y}\"",
            "display-message -p -t %3 \"#{pane_id} #{pane_width} #{cursor_x} #{cursor_y}\"",
        ]
    );
}

/// Claude's empty composer as tmux 3.7 captures it: the placeholder's first character inverse under the cursor,
/// the rest dim; blank rows at the bottom are not text.
#[test]
fn claudes_placeholder_is_a_faint_tail() {
    let screen = capture(
        &["", "\u{2500}\u{2500}\u{2500}", "\u{276f} Try \"fix lint errors\"", "\u{2500}\u{2500}\u{2500}", "  ? for shortcuts", "", ""],
        "\u{276f} \\033[7mT\\033[0m\\033[2mry \"fix lint errors\"\\033[0m          ",
        "%3 40 2 2",
    )
    .unwrap();
    assert_eq!(
        screen,
        Screen {
            text: "\n\u{2500}\u{2500}\u{2500}\n\u{276f} Try \"fix lint errors\"\n\u{2500}\u{2500}\u{2500}\n  ? for shortcuts".into(),
            cursor: (2, 2),
            faint_tail: true,
        }
    );
}

#[test]
fn typed_text_after_the_cursor_is_not_a_faint_tail() {
    let typed = capture(&["\u{276f} hello"], "\u{276f} hello", "%3 40 7 0").unwrap();
    assert!(!typed.faint_tail);
    let mixed = capture(&["\u{276f} a hint"], "\u{276f} a\\033[2m hint", "%3 40 1 0").unwrap();
    assert!(!mixed.faint_tail);
    // Dim with an extended color of 2 is still dim; a color of 2 alone is not.
    let colored = capture(&["> hint"], "> \\033[38;2;2;2;2mhint", "%3 40 1 0").unwrap();
    assert!(!colored.faint_tail);
    let dim = capture(&["> hint"], "> \\033[2;38;2;2;2;2mhint", "%3 40 1 0").unwrap();
    assert!(dim.faint_tail);
}

#[test]
fn wide_characters_keep_the_cursor_column() {
    // The cursor sits after two wide characters (four columns); the dim text starts after it.
    let screen = capture(&["日本 hint"], "日本 \\033[2mhint\\033[0m", "%3 20 4 0").unwrap();
    assert_eq!(screen.cursor, (4, 0));
    assert!(screen.faint_tail);
    let before = capture(&["日本 hint"], "日本 \\033[2mhint\\033[0m", "%3 20 6 0").unwrap();
    assert!(before.faint_tail, "the cell under the cursor never counts");
}

#[test]
fn trailing_blanks_and_escapes() {
    // Spaces tmux keeps (-N) stay, as written spaces do in the renderer; escaped bytes come back.
    let screen = capture(&["a\\\\b  ", "", "c\\011d", "", ""], "a\\\\b  ", "%3 10 0 0").unwrap();
    assert_eq!(screen.text, "a\\b  \n\nc\td");
}

#[test]
fn the_cursor_stays_on_the_last_column() {
    let screen = capture(&["abcd"], "abcd", "%3 4 4 0").unwrap();
    assert_eq!(screen.cursor, (3, 0));
}

#[test]
fn another_pane_or_a_short_reply_is_refused() {
    assert!(capture(&["x"], "x", "%4 10 0 0").is_err());
    assert!(capture(&["x"], "x", "%3 10 0").is_err());
    assert!(parse(&[lines(&["x"]), lines(&["x"])], 3).is_err());
}

#[test]
fn an_empty_screen() {
    assert_eq!(
        capture(&["", "", ""], "", "%3 80 0 0").unwrap(),
        Screen { text: String::new(), cursor: (0, 0), faint_tail: false }
    );
}

/// When captures start (ms) for output at `outputs` (ms) while a reader always waits: each capture takes 5 ms; the
/// clock moves 1 ms at a time, as Timer events and %output would wake the mux.
fn paced(outputs: &[u64], end: u64) -> Vec<u64> {
    let start = Instant::now();
    let mut host = Host::default();
    let (mut captures, mut done) = (Vec::new(), None);
    for ms in 0..=end {
        let now = start + Duration::from_millis(ms);
        if done == Some(ms) {
            host.capturing = false;
            done = None;
        }
        if outputs.contains(&ms) {
            host.output(now);
        }
        if !host.capturing && host.due(now).is_some_and(|due| due <= now) {
            host.started();
            captures.push(ms);
            done = Some(ms + 5);
        }
    }
    captures
}

#[test]
fn continuous_output_is_captured_at_most_twice_a_second() {
    // A spinner repainting every 50 ms for three seconds: a capture 500 ms after the first output since the last
    // one (which read the output of its own millisecond), then one a settle after the spinner stopped.
    let outputs: Vec<u64> = (0..3000).step_by(50).collect();
    let captures = paced(&outputs, 4000);
    assert_eq!(captures, [500, 1050, 1600, 2150, 2700, 3050]);
    for second in 0..3 {
        assert!(captures.iter().filter(|ms| (second * 1000..(second + 1) * 1000).contains(*ms)).count() <= 2);
    }
}

#[test]
fn output_that_settles_is_captured_once_a_settle_later() {
    assert_eq!(paced(&[10], 1000), [110]);
    // A burst ending at 240 ms: one capture at 340 ms.
    assert_eq!(paced(&[200, 220, 240], 1000), [340]);
    assert_eq!(SETTLE, Duration::from_millis(100));
    assert_eq!(FLOOR, Duration::from_millis(500));
}

#[test]
fn a_stale_screen_is_captured_at_once() {
    let now = Instant::now();
    let mut host = Host::default();
    assert_eq!(host.due(now), None);
    host.output(now);
    host.stale = true;
    assert_eq!(host.due(now), Some(now));
    host.started();
    assert_eq!(host.due(now), None);
}

/// A clock the test moves, and what was asked of it: timers, and callbacks for later (Io::after).
#[derive(Default)]
struct Clock {
    now: Option<Instant>,
    later: Vec<Instant>,
}
#[rustfmt::skip]
impl Io for Clock {
    fn now(&self) -> Instant { self.now.unwrap() }
    fn timer(&mut self, _: Instant) {}
    fn after(&mut self, at: Instant, _: Box<dyn FnOnce(&mut dyn Io)>) -> std::io::Result<()> { self.later.push(at); Ok(()) }
    fn defer(&mut self, callback: Box<dyn FnOnce(&mut dyn Io)>) { callback(self) }
    fn interest(&mut self, _: std::os::fd::RawFd, _: bool, _: bool) -> std::io::Result<()> { unreachable!() }
    fn read(&mut self, _: std::os::fd::RawFd, _: &mut [u8]) -> std::io::Result<usize> { unreachable!() }
    fn write(&mut self, _: std::os::fd::RawFd, _: &[u8]) -> std::io::Result<usize> { unreachable!() }
    fn close(&mut self, _: std::os::fd::RawFd) { unreachable!() }
    fn accept(&mut self, _: std::os::fd::RawFd) -> std::io::Result<std::os::fd::RawFd> { unreachable!() }
    fn child(&mut self, _: u32) -> std::io::Result<()> { unreachable!() }
    fn submit(&mut self, _: Job) -> std::io::Result<Work> { unreachable!() }
    fn cancel(&mut self, _: Work) -> bool { unreachable!() }
    fn watch(&mut self, _: &std::path::Path, _: bool) -> std::io::Result<u64> { unreachable!() }
    fn unwatch(&mut self, _: u64) { unreachable!() }
    fn spawn(&mut self, _: std::process::Command, _: Option<Grid>) -> std::io::Result<Spawned> { unreachable!() }
    fn resize(&mut self, _: std::os::fd::RawFd, _: Grid) -> std::io::Result<()> { unreachable!() }
    fn hangup(&mut self, _: std::os::fd::RawFd) -> std::io::Result<()> { unreachable!() }
    fn connect(&mut self, _: &Address) -> std::io::Result<std::os::fd::RawFd> { unreachable!() }
    fn route(&mut self) -> std::io::Result<(u64, std::path::PathBuf)> { unreachable!() }
    fn reply(&mut self, _: u64, _: &[u8]) -> std::io::Result<()> { unreachable!() }
}

#[test]
fn a_screens_host_attach_hosts_until_a_client_publishes_and_again_once_it_left() {
    let mut io = Clock { now: Some(Instant::now()), ..Clock::default() };
    let mut tmux = Tmux::default();
    tmux.terminals.insert(7, Default::default());
    // A client helper (no host_screens) reads only published screens.
    assert!(!tmux.hosted(7));
    Multiplexer::screen_clients(&mut tmux, &mut io, 7, true, false);
    assert!(tmux.hosted(7));
    let screen = Screen { text: "published".into(), cursor: (0, 0), faint_tail: false };
    Multiplexer::publish(&mut tmux, &mut io, 7, screen.clone());
    assert!(!tmux.hosted(7), "a publication wins");
    assert_eq!(tmux.terminals[&7].screen, Some(screen));
    // Output while published is not followed.
    tmux.output_screen(&mut io, 7);
    assert!(tmux.terminals[&7].host.output.is_none());
    // The publisher's attach ended: host reads resume from a stale screen, captured at the next read.
    Multiplexer::screen_clients(&mut tmux, &mut io, 7, true, false);
    assert!(tmux.hosted(7));
    assert!(tmux.terminals[&7].host.stale);
    // The screens.host client left as well.
    Multiplexer::screen_clients(&mut tmux, &mut io, 7, false, false);
    assert!(!tmux.hosted(7));
    // The drainer's global switch reads every terminal nobody publishes for.
    Multiplexer::host_screens(&mut tmux, true);
    assert!(tmux.hosted(7));
    Multiplexer::screen_clients(&mut tmux, &mut io, 7, false, true);
    assert!(!tmux.hosted(7));
    assert!(io.later.is_empty());
}

#[test]
fn output_while_read_waits_for_the_settle() {
    let start = Instant::now();
    let mut io = Clock { now: Some(start), ..Clock::default() };
    let mut tmux = Tmux::default();
    tmux.terminals.insert(7, Default::default());
    Multiplexer::screen_clients(&mut tmux, &mut io, 7, true, false);
    // A screen is shown and read recently: output asks for a capture a settle later, not at once.
    let state = tmux.terminals.get_mut(&7).unwrap();
    state.screen = Some(Screen { text: "x".into(), cursor: (0, 0), faint_tail: false });
    state.host.until = Some(start + Duration::from_secs(2));
    state.host.stale = false;
    tmux.output_screen(&mut io, 7);
    assert_eq!(io.later, [start + SETTLE]);
    // More output 50 ms later keeps the timer already asked (it asks again when it fires).
    io.now = Some(start + Duration::from_millis(50));
    tmux.output_screen(&mut io, 7);
    assert_eq!(io.later, [start + SETTLE]);
    assert_eq!(tmux.terminals[&7].host.due(start), Some(start + Duration::from_millis(150)));
}

#[test]
fn a_read_with_nothing_shown_captures_at_once() {
    let start = Instant::now();
    let mut io = Clock { now: Some(start), ..Clock::default() };
    let mut tmux = Tmux::default();
    tmux.terminals.insert(7, Default::default());
    Multiplexer::screen_clients(&mut tmux, &mut io, 7, true, false);
    tmux.terminals.get_mut(&7).unwrap().host.output(start);
    tmux.read_screen(&mut io, 7);
    // Not paced: no timer (the capture itself needs a pane, which this test has none of).
    assert!(io.later.is_empty());
    assert_eq!(tmux.terminals[&7].host.due(start), Some(start));
}

/// A hosted terminal showing "a" (captured, read recently), and what its reads got.
fn shown(io: &Clock) -> (Tmux, Rc<std::cell::RefCell<Vec<String>>>) {
    let mut tmux = Tmux::default();
    let mut state = crate::ops::Terminal::default();
    state.hosting = true;
    state.screen = Some(Screen { text: "a".into(), cursor: (1, 0), faint_tail: false });
    state.host.until = Some(io.now() + Duration::from_secs(2));
    tmux.terminals.insert(7, state);
    (tmux, Default::default())
}
fn read(tmux: &mut Tmux, io: &mut Clock, got: &Rc<std::cell::RefCell<Vec<String>>>) {
    let got = got.clone();
    tmux.read(io, 7, false, Box::new(move |_, screen| got.borrow_mut().push(screen.unwrap().text)));
}
/// The capture tmux would answer for pane %3 showing `text`.
fn captured(text: &str) -> Result<crate::client::Batch, Error> {
    Ok(vec![lines(&[text]), lines(&[text]), lines(&["%3 10 1 0"])])
}

#[test]
fn a_read_of_the_screen_now_after_output_captures_at_once_and_gets_it_unchanged() {
    let mut io = Clock { now: Some(Instant::now()), ..Clock::default() };
    let (mut tmux, got) = shown(&io);
    tmux.output_screen(&mut io, 7);
    // The output alone waits a settle.
    assert_eq!(io.later, [io.now() + SETTLE]);
    read(&mut tmux, &mut io, &got);
    // Not from the shown capture, and not paced: the capture starts at once, no other timer.
    assert!(got.borrow().is_empty());
    assert_eq!(io.later.len(), 1);
    assert_eq!(tmux.terminals[&7].host.due(io.now()), Some(io.now()));
    tmux.terminals.get_mut(&7).unwrap().host.started();
    tmux.captured_screen(&mut io, 7, 3, captured("a"));
    assert_eq!(*got.borrow(), ["a"], "answered although the screen did not change");
    assert_eq!(tmux.terminals[&7].host.due(io.now()), None, "one capture");
}

#[test]
fn a_read_of_the_screen_now_without_output_since_the_capture_is_answered_from_it() {
    let mut io = Clock { now: Some(Instant::now()), ..Clock::default() };
    let (mut tmux, got) = shown(&io);
    read(&mut tmux, &mut io, &got);
    assert_eq!(*got.borrow(), ["a"]);
    assert_eq!(tmux.terminals[&7].host.due(io.now()), None, "no capture");
    assert!(io.later.is_empty());
}

#[test]
fn a_read_of_the_screen_now_during_a_capture_takes_its_result_or_the_next() {
    let mut io = Clock { now: Some(Instant::now()), ..Clock::default() };
    // Nothing came out since the capture in flight started: it answers.
    let (mut tmux, got) = shown(&io);
    tmux.terminals.get_mut(&7).unwrap().host.started();
    read(&mut tmux, &mut io, &got);
    assert!(got.borrow().is_empty());
    tmux.captured_screen(&mut io, 7, 3, captured("b"));
    assert_eq!(*got.borrow(), ["b"]);
    assert_eq!(tmux.terminals[&7].host.due(io.now()), None);
    // Output after it started: that capture is too old, the next one (at once) answers.
    let (mut tmux, got) = shown(&io);
    tmux.terminals.get_mut(&7).unwrap().host.started();
    tmux.output_screen(&mut io, 7);
    read(&mut tmux, &mut io, &got);
    tmux.captured_screen(&mut io, 7, 3, captured("b"));
    assert!(got.borrow().is_empty());
    assert_eq!(tmux.terminals[&7].host.due(io.now()), Some(io.now()));
    tmux.terminals.get_mut(&7).unwrap().host.started();
    tmux.captured_screen(&mut io, 7, 3, captured("b"));
    assert_eq!(*got.borrow(), ["b"], "answered by the second capture, unchanged");
}

#[test]
fn a_read_of_the_screen_now_waiting_on_tmux_gets_a_publication() {
    let mut io = Clock { now: Some(Instant::now()), ..Clock::default() };
    let (mut tmux, got) = shown(&io);
    tmux.output_screen(&mut io, 7);
    read(&mut tmux, &mut io, &got);
    let published = Screen { text: "p".into(), cursor: (1, 0), faint_tail: false };
    Multiplexer::publish(&mut tmux, &mut io, 7, published);
    assert_eq!(*got.borrow(), ["p"]);
    // A changed read (the prompt watcher) keeps the paced path: it waits for a change.
    io.later.clear();
    let (mut tmux, got) = shown(&io);
    tmux.output_screen(&mut io, 7);
    let into = got.clone();
    tmux.read(&mut io, 7, true, Box::new(move |_, screen| into.borrow_mut().push(screen.unwrap().text)));
    assert!(got.borrow().is_empty());
    assert_eq!(io.later, [io.now() + SETTLE]);
}
