//! The server's prefix table as the node's own session sees it (T4 of the 2026-10-31 audit).
use super::*;
use crate::control::Lines;

fn rows(prefix: &str, prefix2: &str, repeat: &str, keys: &[&str]) -> Vec<Lines> {
    vec![
        [prefix].into_iter().collect(),
        [prefix2].into_iter().collect(),
        [repeat].into_iter().collect(),
        keys.iter().collect(),
    ]
}

#[test]
fn the_options_are_read_for_the_nodes_own_session() {
    let commands = queries("$3");
    assert_eq!(
        commands,
        [
            "display-message -p -t $3 \"#{prefix}\"",
            "display-message -p -t $3 \"#{prefix2}\"",
            "display-message -p -t $3 \"#{repeat-time}\"",
            "list-keys -T prefix",
        ]
    );
    assert!(commands.iter().all(|command| !command.contains("show-options -g")));
    assert_eq!(queries("%7")[0], "display-message -p -t %7 \"#{prefix}\"");
}

#[test]
fn each_session_reports_its_own_values_and_none_is_no_prefix2() {
    let keys = [
        "bind-key    -T prefix c       split-window -h",
        "bind-key -r -T prefix Up      select-pane -U",
        "bind-key    -T copy-mode-vi v send-keys -X begin-selection",
    ];
    let audit = table(&rows("C-a", "F12", "1234", &keys));
    assert_eq!(audit.key.as_deref(), Some("C-a"));
    assert_eq!(audit.prefix2.as_deref(), Some("F12"));
    assert_eq!(audit.repeat_ms, Some(1234));
    assert_eq!(
        audit.bindings,
        [
            PrefixBinding { key: "c".into(), command: "split-window -h".into(), repeat: false },
            PrefixBinding { key: "Up".into(), command: "select-pane -U".into(), repeat: true },
        ]
    );
    let other = table(&rows("C-b", "None", "500", &[]));
    assert_eq!((other.key.as_deref(), other.prefix2, other.repeat_ms), (Some("C-b"), None, Some(500)));
    let none = table(&rows("None", "", "x", &[]));
    assert_eq!((none.key.as_deref(), none.prefix2, none.repeat_ms), (Some("None"), None, None), "the app reads None as no prefix");
}
