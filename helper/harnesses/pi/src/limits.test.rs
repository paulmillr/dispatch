//! What gets through from a Pi limits extension.
use super::*;
use dispatch_helper_core::json::Json;

fn rows(json: &str) -> LimitRows {
    parsed(Json::parse(json.as_bytes()).unwrap().root())
}

#[test]
fn rows_keep_their_text_and_a_bar_only_with_a_percent() {
    assert_eq!(
        rows(r#"{"source":"sam-limits","rows":[{"label":"Weekly","detail":"resets Mon","value":"61%","used":60.6},{"label":"Today","value":"$1.20"}]}"#),
        LimitRows(Some("sam-limits".into()), vec![
            LimitRow("Weekly".into(), "resets Mon".into(), "61%".into(), Some(61)),
            LimitRow("Today".into(), String::new(), "$1.20".into(), None),
        ])
    );
}

#[test]
fn no_source_means_no_extension() {
    assert_eq!(rows(r#"{"source":null,"rows":[]}"#), LimitRows(None, Vec::new()));
}

#[test]
fn an_unusable_name_counts_as_none() {
    for name in ["", "Has Spaces", "dots/slash", r"\u202eevil"] {
        let json = format!(r#"{{"source":"{name}","rows":[{{"label":"a","value":"b"}}]}}"#);
        assert_eq!(rows(&json), LimitRows(None, Vec::new()), "{name}");
    }
    let long = format!(r#"{{"source":"{}","rows":[]}}"#, "a".repeat(65));
    assert_eq!(rows(&long), LimitRows(None, Vec::new()));
}

#[test]
fn text_is_stripped_and_cut() {
    let long = "x".repeat(200);
    let got = rows(&format!(r#"{{"source":"s","rows":[{{"label":"a\u202eb\nc","value":"{long}"}}]}}"#));
    assert_eq!(got.1[0].0, "abc");
    assert_eq!(got.1[0].2.chars().count(), 48);
}

#[test]
fn a_bad_row_is_dropped_and_a_bad_percent_loses_its_bar() {
    let got = rows(
        r#"{"source":"s","rows":[{"label":"","value":"x"},{"label":"no value"},{"label":"a","value":"b","used":400},{"label":7,"value":"x"}]}"#,
    );
    assert_eq!(got.1, [LimitRow("a".into(), String::new(), "b".into(), None)]);
}

#[test]
fn at_most_six_rows() {
    let many = (0..20).map(|n| format!(r#"{{"label":"r{n}","value":"v"}}"#)).collect::<Vec<_>>().join(",");
    assert_eq!(rows(&format!(r#"{{"source":"s","rows":[{many}]}}"#)).1.len(), 6);
}
