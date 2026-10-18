use super::*;

fn record(kind: RecordKind, text: &str, time: Option<i64>) -> Record {
    Record { kind, text: text.into(), time_ms: time, ..Default::default() }
}

#[test]
fn a_row_shows_the_newest_assistant_text_and_the_newest_time() {
    let records = [
        record(RecordKind::User, "hello", Some(1)),
        record(RecordKind::Assistant, "first answer", Some(2)),
        record(RecordKind::Assistant, "  ", Some(3)),
        record(RecordKind::Tool, "ls", Some(4)),
    ];
    assert_eq!(last(&records), (Some("first answer".into()), Some(4)));
    assert_eq!(last(&[]), (None, None));
}

#[test]
fn a_long_answer_is_cut_at_a_character_boundary() {
    let text = "é".repeat(PREVIEW + 10);
    let (preview, _) = last(&[record(RecordKind::Assistant, &text, None)]);
    let preview = preview.unwrap();
    assert_eq!(preview.chars().count(), PREVIEW + 1);
    assert!(preview.ends_with('…'));
}
