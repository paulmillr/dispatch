use super::*;

fn drawn(columns: usize, rows: usize, bytes: &[u8]) -> Cells {
    let mut cells = Cells::new(columns, rows);
    cells.feed(bytes).unwrap();
    cells
}

#[test]
fn rows_end_in_newlines_only_before_more_text() {
    // Blank rows above text keep the cursor's row index; blank rows below it are dropped.
    let cells = drawn(10, 6, b"\x1b[2;1Hone\x1b[4;3Htwo\x1b[4;6H");
    assert_eq!(
        cells.screen(),
        Screen { text: "\none\n\n  two".into(), cursor: (5, 3), faint_tail: false }
    );
}

#[test]
fn written_spaces_are_text_and_erased_cells_are_not() {
    // Ghostty's formatter keeps a space a program wrote (herdr's renderer pads every row) and drops blank cells
    // at a row's end.
    assert_eq!(drawn(8, 2, b"ab   ").text(), "ab   ");
    assert_eq!(drawn(8, 2, b"ab   \x1b[1;3H\x1b[K").text(), "ab");
    assert_eq!(drawn(8, 2, b"\x1b[2;1H    ").text(), "\n    ");
    assert_eq!(drawn(8, 2, b"a\x1b[1;5Hb").text(), "a   b");
}

#[test]
fn a_faint_suggestion_after_the_cursor_is_a_faint_tail() {
    // Claude's empty composer: the cursor on the placeholder's first character (drawn inverse, so not faint),
    // the rest faint.
    let mut cells = drawn(30, 3, b"\x1b[2;1H\xe2\x9d\xaf \x1b[7mT\x1b[0m\x1b[2mry \"fix it\"\x1b[0m");
    cells.feed(b"\x1b[2;3H").unwrap();
    assert_eq!(
        cells.screen(),
        Screen { text: "\n❯ Try \"fix it\"".into(), cursor: (2, 1), faint_tail: true }
    );
}

#[test]
fn a_tail_is_faint_only_when_every_character_after_the_cursor_is() {
    assert!(!drawn(20, 1, b"> \x1b[2mhint\x1b[0m x\x1b[1;2H").faint_after(1, 0));
    assert!(drawn(20, 1, b"> \x1b[2mhint\x1b[0m   \x1b[1;2H").faint_after(1, 0));
    // Nothing after the cursor: not a faint tail.
    assert!(!drawn(20, 1, b"> typed").screen().faint_tail);
    // The cell under the cursor does not count either way.
    assert!(drawn(20, 1, b"> x\x1b[2mhint\x1b[1;3H").faint_after(2, 0));
    assert!(!drawn(20, 1, b"> \x1b[2mx\x1b[1;3H").faint_after(2, 0));
}

#[test]
fn sgr_tracks_faint_through_resets_and_extended_colors() {
    let faint = |sgr: &str| drawn(4, 1, format!("\x1b[{sgr}mx").as_bytes()).rows[0][0].faint;
    assert!(faint("2"));
    assert!(faint("0;2;39;49"));
    assert!(faint("1;2"));
    assert!(!faint("2;22"));
    assert!(!faint("2;0"));
    assert!(!faint("2;"));
    // A color component of 2 is not faint.
    assert!(!faint("38;2;2;2;2"));
    assert!(!faint("48;5;2"));
    assert!(!faint("38:2::2:2:2"));
    assert!(faint("38;5;12;2"));
    assert!(faint("38;2;0;0;0;48;2;255;255;255;2"));
}

#[test]
fn wide_characters_take_two_cells_and_print_once() {
    let cells = drawn(12, 1, "日本 \x1b[2mok\x1b[0m\x1b[1;5H".as_bytes());
    assert_eq!(cells.text(), "日本 ok");
    assert_eq!(cells.cursor(), (4, 0));
    assert!(cells.faint_after(4, 0));
    // The right half after the cursor is blank, not a non-faint character.
    assert!(drawn(12, 1, "a\x1b[2m日\x1b[1;1H".as_bytes()).faint_after(0, 0));
    // Overwriting half of a wide character blanks the other half.
    assert_eq!(drawn(12, 1, "日本\x1b[1;2Hx".as_bytes()).text(), " x本");
    // herdr moves past the right half itself.
    assert_eq!(drawn(12, 1, "日\x1b[1;3H本".as_bytes()).text(), "日本");
}

#[test]
fn combining_marks_join_their_character() {
    assert_eq!(drawn(6, 1, "e\u{301}x".as_bytes()).text(), "e\u{301}x");
    assert_eq!(drawn(6, 1, "e\u{301}x".as_bytes()).cursor(), (2, 0));
}

#[test]
fn text_past_the_last_column_overwrites_it() {
    let cells = drawn(4, 2, b"abcdef");
    assert_eq!(cells.text(), "abcf");
    assert_eq!(cells.cursor(), (3, 0));
}

#[test]
fn characters_and_sequences_cut_between_feeds_continue() {
    let mut cells = Cells::new(10, 1);
    let bytes = "\x1b[2m日\x1b[0m".as_bytes();
    for byte in bytes {
        cells.feed(std::slice::from_ref(byte)).unwrap();
    }
    assert_eq!(cells.text(), "日");
    assert!(cells.rows[0][0].faint && cells.rows[0][1].tail);
    assert!(!cells.faint);
}

#[test]
fn strings_and_modes_draw_nothing() {
    let cells = drawn(
        12,
        1,
        b"\x1b[?2026h\x1b[?25l\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x07\x1b(B\x1b[4 q\x1b[?2026l",
    );
    assert_eq!(cells.text(), "link");
}

#[test]
fn sequences_outside_a_screen_dump_fail() {
    assert!(Cells::new(4, 4).feed(b"\x1b[1;2r").is_err());
    assert!(Cells::new(4, 4).feed(b"\x1b[2L").is_err());
    assert!(Cells::new(4, 4).feed(b"\x1b[4h").is_err());
    assert!(Cells::new(4, 1).feed(b"a\n").is_err());
    assert!(Cells::new(4, 2).feed(b"a\r\nb").is_ok());
}

#[test]
fn erasing_clears_text_and_faint() {
    let mut cells = drawn(8, 3, b"\x1b[2mabc\x1b[2;1Hdef\x1b[3;1Hghi");
    cells.feed(b"\x1b[0m\x1b[2;2H\x1b[J").unwrap();
    assert_eq!(cells.text(), "abc\nd");
    cells.feed(b"\x1b[1;2H\x1b[1K").unwrap();
    assert_eq!(cells.text(), "  c\nd");
    cells.feed(b"\x1b[2J").unwrap();
    assert_eq!(cells.text(), "");
    cells.feed(b"\x1b[1;1Habcdef\x1b[1;2H\x1b[2X").unwrap();
    assert_eq!(cells.text(), "a  def");
}

/// A full frame from herdr 0.9.5's `terminal session observe` (a 40x6 pane): every row padded with spaces, the
/// cursor placed last.
#[test]
fn a_herdr_full_frame() {
    let frame = b"\x1b[?2026h\x1b[?25l\x1b]8;;\x1b\\\x1b[2J\x1b[1;1H\x1b[0;39;49mhello \x1b[0;2;39;49mfaint tail\x1b[0;39;49m                        \x1b[2;1H                                        \x1b[3;1H                                        \x1b[4;1H                                        \x1b[5;1H                                        \x1b[6;1H                                        \x1b[0m\x1b[1;3H\x1b[?25h\x1b[?2026l\x1b[1;3H\x1b[?25h";
    let cells = drawn(40, 6, frame);
    let padded = " ".repeat(40);
    assert_eq!(
        cells.screen(),
        Screen {
            text: format!("hello faint tail{}\n{padded}\n{padded}\n{padded}\n{padded}\n{padded}", " ".repeat(24)),
            cursor: (2, 0),
            faint_tail: false,
        }
    );
    // A diff frame on top: the cursor after "hello ", only faint text follows.
    let mut cells = cells;
    cells.feed(b"\x1b[?2026h\x1b[?25l\x1b[1;7H\x1b[?25h\x1b[?2026l\x1b[1;6H\x1b[?25h").unwrap();
    assert_eq!(cells.cursor(), (5, 0));
    assert!(cells.screen().faint_tail);
}
