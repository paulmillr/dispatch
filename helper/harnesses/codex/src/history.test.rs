use super::*;

fn rollout(lines: &[&str]) -> Vec<u8> {
    lines.iter().flat_map(|line| line.bytes().chain(std::iter::once(b'\n'))).collect()
}

const META: &str = r#"{"timestamp":"2026-11-14T01:00:00.000Z","type":"session_meta","payload":{"id":"thread-fixture"}}"#;
const STARTED: &str = r#"{"timestamp":"2026-11-14T01:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","started_at":1794619505}}"#;

/// A turn that failed says why in the transcript, as a notice before its end, with one id live and reloaded;
/// a turn that ended well adds none.
#[test]
fn a_failed_turn_says_why_in_a_notice_before_its_end() {
    let failed = r#"{"timestamp":"2026-11-14T01:05:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","completed_at":1794619804,"last_agent_message":null,"error":{"message":"This response cannot be shown: the session was not authenticated with a hardware key.","codex_error_info":"cyber_policy"}}}"#;
    let bytes = rollout(&[META, STARTED, failed]);
    let (failed_page, state, _, _) = page(lines(&bytes, 0), "thread-fixture", None).unwrap();
    let kinds: Vec<_> = failed_page.records.iter().map(|record| record.kind).collect();
    assert_eq!(kinds, [RecordKind::TurnStarted, RecordKind::Notice, RecordKind::TurnEnded]);
    let notice = &failed_page.records[1];
    assert_eq!(notice.id, "turn-error:turn-1");
    assert_eq!(notice.turn.as_deref(), Some("turn-1"));
    assert!(notice.text.contains("hardware key"));
    assert_eq!(notice.time_ms, Some(1794619804000));
    assert!(!state.busy);
    assert_eq!(state.attention, None, "a failed turn asks nothing of the terminal");

    // Followed live (appended lines), the same notice with the same id.
    let mut live = State::default();
    let (records, _, _, _) = appended(&bytes, 0, "thread-fixture", None, &mut live).unwrap();
    assert!(records.iter().any(|record| record.kind == RecordKind::Notice && record.id == "turn-error:turn-1"));

    let ended = r#"{"timestamp":"2026-11-14T01:05:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","completed_at":1794619804,"last_agent_message":"Done."}}"#;
    let bytes = rollout(&[META, STARTED, ended]);
    let (ended_page, _, _, _) = page(lines(&bytes, 0), "thread-fixture", None).unwrap();
    assert!(ended_page.records.iter().all(|record| record.kind != RecordKind::Notice));
}
