use super::*;

/// The rows a piece shows after it, as text with each cell's writer (piece N's byte i is at 100 * N + i), feeding each
/// piece in turn; blanks are spaces without a writer.
fn feed(pieces: &[&[u8]]) -> Vec<Vec<Line<usize>>> {
    let mut screen = Screen::new();
    pieces.iter().enumerate().map(|(index, piece)| screen.feed(piece, &|at| 100 * index + at)).collect()
}

fn line(row: Option<usize>, text: &str, cells: &[Option<usize>]) -> Line<usize> {
    Line { row, text: text.as_bytes().to_vec(), cells: cells.to_vec() }
}

#[test]
fn a_redraw_around_an_unchanged_cell_shows_the_whole_word_with_each_cells_writer() {
    // Frame 1 draws the word; frame 2 draws it again but jumps over its 6th cell (CUP to row 1, column 7).
    assert_eq!(feed(&[b"secret7", b"\r\x1b[1;1Hsecr\x1b[1;7H7"]), vec![
        vec![line(Some(0), "secret7", &[Some(0), Some(1), Some(2), Some(3), Some(4), Some(5), Some(6)])],
        vec![line(Some(0), "secret7", &[Some(107), Some(108), Some(109), Some(110), Some(4), Some(5), Some(117)])],
    ]);
}

#[test]
fn escape_sequences_cut_by_pieces_keep_their_meaning() {
    // ESC [ 2 ; 3 H split over three pieces, an OSC title in between: the text lands at row 2, column 3.
    assert_eq!(feed(&[b"\x1b[2", b";3H\x1b]0;ti", b"tle\x07ab"]), vec![
        vec![],
        vec![],
        vec![line(Some(1), "  ab", &[None, None, Some(204), Some(205)])],
    ]);
}

#[test]
fn erasing_scrolling_and_saved_positions_follow_the_terminal() {
    let mut screen = Screen::new();
    let at = |at: usize| at;
    screen.feed(b"abcdef\x1b[1;3H\x1b[K", &at);
    assert_eq!(screen.lines(), vec![line(Some(0), "ab", &[Some(0), Some(1)])]);
    // Save, draw elsewhere, restore and draw on: the cursor comes back to row 1, column 3.
    screen.feed(b"\x1b7\x1b[5;1Hx\x1b8Z", &at);
    assert_eq!(screen.lines(), vec![line(Some(0), "abZ", &[Some(0), Some(1), Some(11)]), line(Some(4), "x", &[Some(8)])]);
    // A line feed on the last row scrolls: the first row leaves, still reported once by the piece that scrolled it out.
    let mut screen = Screen::new();
    let out = screen.feed(&[b"top\r\n".as_slice(), &b"\r\n".repeat(ROWS - 1), b"end"].concat(), &at);
    assert_eq!(out.first(), Some(&line(None, "top", &[Some(0), Some(1), Some(2)])));
    assert_eq!(screen.lines().last().map(|line| (line.row, line.text.clone())), Some((Some(ROWS - 1), b"end".to_vec())));
}

#[test]
fn a_cell_set_by_a_match_shows_its_new_byte() {
    let mut screen = Screen::new();
    screen.feed(b"secret7", &|at| at);
    screen.set(0, 4, b'X');
    assert_eq!(screen.lines(), vec![line(Some(0), "secrXt7", &[Some(0), Some(1), Some(2), Some(3), Some(4), Some(5), Some(6)])]);
}
