use super::*;
use crate::control::Lines;

#[test]
fn window_activity_lines_become_tab_keys_with_milliseconds() {
    let lines: Lines = ["$1|@2|1792410353", "$1|@5|1792410400", "$12|@2|1"].into_iter().collect();
    assert_eq!(
        parse(&lines),
        vec![("$1:@2".into(), 1_792_410_353_000), ("$1:@5".into(), 1_792_410_400_000), ("$12:@2".into(), 1000)]
    );
}

#[test]
fn lines_without_a_time_are_skipped() {
    // An older tmux prints an unknown format as nothing; garbage and zero say no time either.
    let lines: Lines = ["$1|@2|", "$1|@3|0", "$1|@4|soon", "1|@5|10", "$1|6|10", "$1|@7", "$1|@8|10"].into_iter().collect();
    assert_eq!(parse(&lines), vec![("$1:@8".into(), 10_000)]);
}

#[test]
fn the_command_reads_every_session_of_the_server() {
    assert!(COMMAND.starts_with("list-windows -a -F "));
    assert!(!COMMAND.contains(['\r', '\n']));
}
