use super::*;

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

#[test]
fn host_screens_are_off_until_enabled_and_never_for_a_client_terminal() {
    let mut herdr = Herdr::new(Config {
        executable: "/opt/herdr".into(),
        socket: "/tmp/hs/hd.sock".into(),
        session: "main".into(),
        directory: "/tmp".into(),
        environment: BTreeMap::new(),
        uid: 501,
    });
    assert!(!herdr.hosted(7));
    Multiplexer::host_screens(&mut herdr, true);
    assert!(herdr.hosted(7));
    herdr.clients.insert(7);
    assert!(!herdr.hosted(7));
    assert!(herdr.hosted(8));
}
