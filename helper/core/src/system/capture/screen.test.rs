use super::*;
use crate::json::{Json, Value};

/// A line as its row, text and each cell's writer.
type Shown = (Option<usize>, Vec<u8>, Vec<Option<usize>>);

/// The lines a piece returns, feeding each piece in turn (piece N's byte i is at 100 * N + i); blanks are spaces
/// without a writer.
fn feed(screen: &mut Screen<usize>, pieces: &[&[u8]]) -> Vec<Vec<Shown>> {
    pieces.iter().enumerate().map(|(index, piece)| {
        let mut lines = Vec::new();
        let drawn = screen.feed(piece, &|at| 100 * index + at, &mut |line| lines.push(line));
        lines.into_iter().chain(drawn).map(|line| (line.row, line.text, line.cells)).collect()
    }).collect()
}

fn line(row: Option<usize>, text: &str, cells: &[Option<usize>]) -> Shown {
    (row, text.as_bytes().to_vec(), cells.to_vec())
}

fn written(range: std::ops::Range<usize>) -> Vec<Option<usize>> {
    range.map(Some).collect()
}

/// Every case of screen.fixtures/herdr.json (what Ghostty showed, through herdr) played into a screen of its size:
/// the screen and the whole input (a cell's writer is its byte's place in it).
fn cases() -> Vec<(String, Screen<usize>, Vec<u8>, Value<'static>)> {
    let json: &'static Json = Box::leak(Box::new(Json::parse(include_bytes!("screen.fixtures/herdr.json")).unwrap()));
    let number = |value: Option<Value<'_>>, index: usize| value.unwrap().array().unwrap().nth(index).unwrap().unsigned().unwrap() as usize;
    json.root().get("cases").unwrap().array().unwrap().map(|case| {
        let mut screen = Screen::sized(number(case.get("size"), 1), number(case.get("size"), 0));
        let mut input = Vec::new();
        for step in case.get("steps").unwrap().array().unwrap() {
            if step.get("resize").is_some() {
                screen.resize(number(step.get("resize"), 1), number(step.get("resize"), 0));
            } else {
                let (bytes, start) = (step.get("bytes").unwrap().string().unwrap().as_bytes(), input.len());
                input.extend_from_slice(bytes);
                screen.feed(bytes, &|at| start + at, &mut |_| {});
            }
        }
        (case.get("name").unwrap().string().unwrap().to_string(), screen, input, case)
    }).collect()
}

#[test]
fn every_case_shows_what_ghostty_showed() {
    let text = |rows: Vec<Vec<u8>>| rows.into_iter().map(|row| String::from_utf8(row).unwrap()).collect::<Vec<_>>();
    let (mut got, mut want) = (Vec::new(), Vec::new());
    for (name, screen, _, case) in cases() {
        let cursor: Vec<usize> = case.get("cursor").unwrap().array().unwrap().map(|n| n.unsigned().unwrap() as usize).collect();
        let rows = case.get("screen").unwrap().array().unwrap().map(|row| row.string().unwrap().as_bytes().to_vec()).collect();
        got.push((name.clone(), text(screen.text()), screen.cursor()));
        want.push((name, text(rows), (cursor[0], cursor[1])));
    }
    assert_eq!(got, want);
}

#[test]
fn every_cell_shows_the_byte_that_wrote_it() {
    // A cell's writer is the input byte it shows (a character of several bytes: its first byte, shown as '?'); a
    // blank has none. Holds after scrolling, inserting, deleting, erasing, the alternate screen and resizes.
    let mut wrong = Vec::new();
    for (name, screen, input, _) in cases() {
        for line in screen.lines() {
            for (index, (byte, cell)) in line.text.iter().zip(&line.cells).enumerate() {
                let shows = match cell {
                    Some(at) if *byte == b'?' => input[*at] == b'?' || input[*at] >= 0xc0,
                    Some(at) => input[*at] == *byte,
                    None => *byte == b' ',
                };
                if !shows {
                    wrong.push((name.clone(), line.row, index));
                }
            }
        }
    }
    assert_eq!(wrong, Vec::new());
}

#[test]
fn a_redraw_around_an_unchanged_cell_shows_the_whole_word_with_each_cells_writer() {
    // Frame 1 draws the word; frame 2 draws it again but jumps over its 5th and 6th cells (CUP to row 1, column 7).
    assert_eq!(feed(&mut Screen::sized(3, 20), &[b"secret7", b"\r\x1b[1;1Hsecr\x1b[1;7H7"]), vec![
        vec![line(Some(0), "secret7", &written(0..7))],
        vec![line(Some(0), "secret7", &[Some(107), Some(108), Some(109), Some(110), Some(4), Some(5), Some(117)])],
    ]);
}

#[test]
fn escape_sequences_cut_by_pieces_keep_their_meaning() {
    // ESC [ 2 ; 3 H split over three pieces, an OSC title in between: the text lands at row 2, column 3.
    assert_eq!(feed(&mut Screen::sized(3, 10), &[b"\x1b[2", b";3H\x1b]0;ti", b"tle\x07ab"]), vec![
        vec![],
        vec![],
        vec![line(Some(1), "  ab", &[None, None, Some(204), Some(205)])],
    ]);
}

#[test]
fn a_wrapped_line_is_one_line_and_a_match_on_it_sets_the_right_cell() {
    let mut screen = Screen::sized(4, 10);
    assert_eq!(feed(&mut screen, &[b"abcdefghijkl"]), vec![vec![line(Some(0), "abcdefghijkl", &written(0..12))]]);
    screen.set(0, 11, b'X');
    assert_eq!(screen.text(), vec![b"abcdefghij".to_vec(), b"kX".to_vec(), Vec::new(), Vec::new()]);
}

#[test]
fn rows_a_piece_draws_and_loses_are_returned_before_they_go() {
    // Scrolled out by the same piece: returned once (no row), then the rows on the screen.
    assert_eq!(feed(&mut Screen::sized(2, 10), &[b"one\r\ntwo\r\nthree"]), vec![vec![
        line(None, "one", &written(0..3)),
        line(Some(0), "two", &written(5..8)),
        line(Some(1), "three", &written(10..15)),
    ]]);
    // Cleared by the same piece, and deleted by the same piece.
    assert_eq!(feed(&mut Screen::sized(3, 10), &[b"secret\x1b[2J"]), vec![vec![line(None, "secret", &written(0..6))]]);
    assert_eq!(feed(&mut Screen::sized(3, 10), &[b"\x1b[2;1Hsecret\x1b[M"]), vec![vec![line(None, "secret", &written(6..12))]]);
    // A row an earlier piece drew goes without being returned again: it was matched then.
    assert_eq!(feed(&mut Screen::sized(2, 10), &[b"abc", b"\r\n\r\n\r\n"]), vec![vec![line(Some(0), "abc", &written(0..3))], vec![]]);
}

#[test]
fn a_cell_knows_the_bytes_written_beside_it_in_one_run() {
    // "ab", a cursor move to the last column, "cd" (the terminal wraps it: one line), a line break, "e": runs end at
    // escapes and control bytes, and go on across a wrap.
    let mut screen = Screen::sized(3, 4);
    screen.feed(b"ab\x1b[1;4Hcd\r\ne", &|at| at, &mut |_| {});
    let links: Vec<_> = screen.lines().into_iter().map(|line| (line.text, line.links)).collect();
    assert_eq!(links, vec![
        (b"ab cd".to_vec(), vec![(None, Some(b'b')), (Some(b'a'), None), (None, None), (None, Some(b'd')), (Some(b'c'), None)]),
        (b"e".to_vec(), vec![(None, None)]),
    ]);
}

#[test]
fn a_screen_without_a_size_neither_wraps_nor_scrolls_before_its_last_row() {
    let mut screen = Screen::new();
    assert_eq!(screen.size(), None);
    screen.feed(&[b"x".repeat(2000).as_slice(), b"\r\n".repeat(200).as_slice(), b"y"].concat(), &|at| at, &mut |_| {});
    assert_eq!(screen.text().first().map(Vec::len), Some(COLS));
    assert_eq!(screen.cursor(), (1, 200));
}
