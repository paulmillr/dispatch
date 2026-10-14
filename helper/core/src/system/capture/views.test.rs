use super::*;

/// Scan as capture.rs's: every `needle` ending in this piece becomes `mask`; `found` gets where each match began and
/// ended (its first and last byte).
fn masking<'a>(needle: &'a [u8], mask: &'a [u8], found: &'a mut Vec<(usize, usize)>) -> impl FnMut(&mut [u8], usize, &dyn Fn(usize) -> usize) + 'a {
    move |text, from, at| {
        for start in 0..(text.len() + 1).saturating_sub(needle.len()) {
            let end = start + needle.len();
            if end > from && text[start..end] == *needle {
                found.push((at(start), at(end - 1)));
                text[start..end].copy_from_slice(mask);
            }
        }
    }
}

/// Each piece fed at its own offset (piece N's byte i is at 100 * N + i): the changes and matches of each. A piece's
/// own changes are written into it.
fn feed(view: &mut View<usize>, pieces: &[&[u8]]) -> Vec<(Vec<(usize, u8)>, Vec<(usize, usize)>)> {
    pieces.iter().enumerate().map(|(index, piece)| {
        let (mut found, mut bytes) = (Vec::new(), piece.to_vec());
        let changes = view.feed(&mut bytes, &|at| 100 * index + at, &mut masking(b"secret7", b"MASKED!", &mut found));
        let written: Vec<(usize, u8)> = (0..bytes.len()).filter(|&at| bytes[at] != piece[at]).map(|at| (100 * index + at, bytes[at])).collect();
        assert_eq!(written, changes.iter().copied().filter(|(at, _)| at / 100 == index).collect::<Vec<_>>());
        (changes, found)
    }).collect()
}

fn changes(at: &[usize]) -> Vec<(usize, u8)> {
    at.iter().copied().zip(b"MASKED!".iter().copied()).collect()
}

#[test]
fn a_needle_cut_by_pieces_is_found_once_with_every_byte_where_it_was_recorded() {
    // The match spans three pieces (the middle one shorter than the needle); later pieces find nothing again.
    assert_eq!(feed(&mut View::new(false, 6), &[b"ssh secr", b"et", b"7@host", b"secre", b""]), vec![
        (vec![], vec![]),
        (vec![], vec![]),
        (changes(&[4, 5, 6, 7, 100, 101, 200]), vec![(4, 200)]),
        (vec![], vec![]),
        (vec![], vec![]),
    ]);
}

#[test]
fn line_breaks_and_csi_sequences_are_not_part_of_an_unwrapped_view() {
    let piece: &[u8] = b"secr\r\net7 and secr\x1b[3;1Het7 and \x1b[1msecret7\x1b[0m";
    assert_eq!((feed(&mut View::new(true, 6), &[piece]), feed(&mut View::new(false, 6), &[piece])), (
        vec![(changes(&[0, 1, 2, 3, 6, 7, 8]).into_iter().chain(changes(&[14, 15, 16, 17, 24, 25, 26]))
            .chain(changes(&[36, 37, 38, 39, 40, 41, 42])).collect(), vec![(0, 8), (14, 26), (36, 42)])],
        vec![(changes(&[36, 37, 38, 39, 40, 41, 42]), vec![(36, 42)])],
    ));
}

#[test]
fn a_csi_sequence_cut_by_pieces_stays_hidden() {
    assert_eq!(feed(&mut View::new(true, 6), &[b"secr\x1b[3", b";1Het7"]), vec![
        (vec![], vec![]),
        (changes(&[0, 1, 2, 3, 103, 104, 105]), vec![(0, 105)]),
    ]);
}

#[test]
fn only_the_last_bytes_a_match_can_start_in_are_kept() {
    // Kept: 6 bytes; a needle starting earlier than that is not joined (it cannot end in a later piece).
    let mut view = View::new(false, 6);
    feed(&mut view, &[b"secret"]);
    assert_eq!((view.tail.clone(), view.at.clone()), (b"secret".to_vec(), vec![0, 1, 2, 3, 4, 5]));
    assert_eq!(feed(&mut View::new(false, 6), &[b"xsecret", b"7"])[1], (changes(&[1, 2, 3, 4, 5, 6, 100]), vec![(1, 100)]));
}
