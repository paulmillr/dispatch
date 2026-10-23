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
