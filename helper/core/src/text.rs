//! Text predicates shared by parts that must match Foundation's character sets.

/// Foundation `CharacterSet.controlCharacters`: Unicode Cc plus Cf. Rust `is_control` is
/// only Cc. The verified category source is plugins/stats/tests/fixtures/process-names;
/// used by the old SpaceBranch.swift:107-126 branch check and the stats name policy.
pub fn control(c: char) -> bool {
    c.is_control()
        || matches!(
            c,
            '\u{ad}'
                | '\u{600}'..='\u{605}'
                | '\u{61c}'
                | '\u{6dd}'
                | '\u{70f}'
                | '\u{890}'..='\u{891}'
                | '\u{8e2}'
                | '\u{180e}'
                | '\u{200b}'..='\u{200f}'
                | '\u{202a}'..='\u{202e}'
                | '\u{2060}'..='\u{2064}'
                | '\u{2066}'..='\u{206f}'
                | '\u{feff}'
                | '\u{fff9}'..='\u{fffb}'
                | '\u{110bd}'
                | '\u{110cd}'
                | '\u{13430}'..='\u{1343f}'
                | '\u{1bca0}'..='\u{1bca3}'
                | '\u{1d173}'..='\u{1d17a}'
                | '\u{e0001}'
                | '\u{e0020}'..='\u{e007f}'
        )
}

/// The variables a shell command expands, in order: `$NAME` and `${NAME…}` (not `$1`, `$$`).
pub fn expansions(command: &str) -> Vec<String> {
    let bytes = command.as_bytes();
    let mut names = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'$' {
            index += 1;
            continue;
        }
        let start = index + 1 + usize::from(bytes.get(index + 1) == Some(&b'{'));
        let mut end = start;
        while end < bytes.len() && (bytes[end] == b'_' || bytes[end].is_ascii_alphanumeric()) {
            end += 1;
        }
        if end > start && !bytes[start].is_ascii_digit() {
            names.push(command[start..end].to_owned());
        }
        index = end.max(index + 1);
    }
    names
}
