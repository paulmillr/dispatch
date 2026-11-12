use super::*;

fn line(text: &str) -> Line {
    classify("019a0000-0000-7000-8000-000000000001")(text.as_bytes())
}
fn at(stamp: &str) -> Option<i64> {
    dispatch_helper_core::date::parse(stamp)
}

#[test]
fn rollout_lines_give_a_row_what_the_page_would() {
    let stamp = "2026-10-20T12:00:01.000Z";
    let started = line(r#"{"timestamp":"2026-10-20T12:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1","started_at":1792411200}}"#);
    assert_eq!((started.time_ms, started.started), (Some(1_792_411_200_000), Some(1_792_411_200_000)));

    let answer = line(&format!(r#"{{"timestamp":"{stamp}","type":"event_msg","payload":{{"type":"agent_message","message":"The tests pass."}}}}"#));
    assert_eq!(answer.answer, Some(("The tests pass.".into(), at(stamp))));
    assert_eq!(answer.time_ms, at(stamp));

    let item = line(&format!(
        r#"{{"timestamp":"{stamp}","type":"response_item","payload":{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"Done."}}]}}}}"#
    ));
    assert_eq!(item.answer, Some(("Done.".into(), at(stamp))));

    // Analysis-channel messages and token counts are no records.
    let analysis = line(&format!(
        r#"{{"timestamp":"{stamp}","type":"response_item","payload":{{"type":"message","role":"assistant","channel":"analysis","content":[{{"type":"output_text","text":"Thinking."}}]}}}}"#
    ));
    assert_eq!(analysis, Line::default());
    let tokens = line(&format!(r#"{{"timestamp":"{stamp}","type":"event_msg","payload":{{"type":"token_count","info":null}}}}"#));
    assert_eq!(tokens, Line::default());

    // A tool call is a record (the newest time), not an answer.
    let call = line(&format!(
        r#"{{"timestamp":"{stamp}","type":"response_item","payload":{{"type":"function_call","name":"shell","arguments":"{{}}","call_id":"c1"}}}}"#
    ));
    assert_eq!((call.time_ms, call.answer), (at(stamp), None));

    let ended = line(r#"{"timestamp":"2026-10-20T12:00:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","completed_at":1792411205}}"#);
    assert_eq!((ended.time_ms, ended.ended), (Some(1_792_411_205_000), Some(1_792_411_205_000)));
    let aborted = line(r#"{"timestamp":"2026-10-20T12:00:06.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t2"}}"#);
    assert_eq!(aborted.ended, at("2026-10-20T12:00:06.000Z"));

    assert_eq!(line("not json"), Line::default());
}
