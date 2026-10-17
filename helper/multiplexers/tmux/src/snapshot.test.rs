use super::*;
use crate::control::Lines;

/// A one-pane window layout, with tmux's checksum.
fn layout(pane: u32) -> String {
    let body = format!("80x24,0,0,{pane}");
    let sum = body.bytes().fold(0u16, |v, b| v.rotate_right(1).wrapping_add(b.into()));
    format!("{sum:04x},{body}")
}

/// Windows @1 (pane %1) and @2 (pane %2) read with these affinity lines: each window's value.
fn affinities(lines: &[&str]) -> Vec<(u64, String)> {
    let windows: Lines = [1, 2].map(|n| format!("1|@{n}|{}|{}|{}|%{n}|w{n}", layout(n), layout(n), u32::from(n == 1))).into_iter().collect();
    let panes: Lines = [1, 2].map(|n| format!("%{n}|80|24|10{n}|/dev/pts/{n}|t{n}")).into_iter().collect();
    let focus: Lines = ["@1|%1|$1|200|300|/run/tmux-test/default|main"].into_iter().collect();
    let snapshot = Snapshot::parse(&windows, &panes, &focus, &lines.iter().collect()).unwrap();
    snapshot.windows.into_iter().map(|window| (window.id, window.affinity)).collect()
}

#[test]
fn a_raw_affinity_line_gives_no_other_window_a_value_and_fails_no_snapshot() {
    assert_eq!(affinities(&[r#"@1|{"v":1}"#, "@2|"]), vec![(1, r#"{"v":1}"#.into()), (2, String::new())]);
    // @1's value carried a line break and a line for @2: @2 is named with two values and gets none.
    assert_eq!(affinities(&["@1|a", "@2|forged", "@2|own"]), vec![(1, "a".into()), (2, String::new())]);
    // Lines that are not `@id|value` (the rest of a value) are skipped; the same value twice stays.
    assert_eq!(affinities(&["@1|a", "b|c", "tail", "@x|d", "@2|own", "@2|own"]), vec![(1, "a".into()), (2, "own".into())]);
}
