//! What a Codex limits read keeps from the App Server's answer and from a rollout.
use super::*;

fn from_api(json: &str) -> Vec<LimitWindow> {
    answered(Json::parse(json.as_bytes()).unwrap().root())
}

fn weekly(used: u64) -> LimitWindow {
    LimitWindow("seven_day".into(), used, 1794530402)
}

#[test]
fn a_window_is_named_by_its_length_not_its_slot() {
    assert_eq!(
        from_api(r#"{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":1794530402},"secondary":null}}"#),
        [weekly(1)]
    );
}

#[test]
fn windows_come_shortest_first_and_an_unknown_length_keeps_its_minutes() {
    assert_eq!(
        from_api(
            r#"{"rateLimits":{"primary":{"usedPercent":9,"windowDurationMins":10080,"resetsAt":1794530402},
                "secondary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":5}}}"#
        ),
        [LimitWindow("five_hour".into(), 40, 5), weekly(9)]
    );
    assert_eq!(
        from_api(r#"{"rateLimits":{"primary":{"usedPercent":3,"windowDurationMins":1440,"resetsAt":5}}}"#),
        [LimitWindow("window_1440".into(), 3, 5)]
    );
}

#[test]
fn a_window_without_its_length_or_reset_is_dropped() {
    assert!(from_api(r#"{"rateLimits":{"primary":{"usedPercent":3,"windowDurationMins":null,"resetsAt":5}}}"#).is_empty());
    assert!(from_api(r#"{"rateLimits":{"primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":null}}}"#).is_empty());
    assert!(from_api(r#"{"rateLimits":{"primary":null,"secondary":null}}"#).is_empty());
}

fn token_count(limits: &str) -> String {
    format!(r#"{{"type":"event_msg","payload":{{"type":"token_count","info":null,"rate_limits":{limits}}}}}"#)
}

const RECORDED: &str = r#"{"primary":{"used_percent":PCT,"window_minutes":10080,"resets_at":1794530402},"secondary":null}"#;

#[test]
fn a_rollout_gives_its_newest_recorded_windows() {
    let older = token_count(&RECORDED.replace("PCT", "1.0"));
    let newer = token_count(&RECORDED.replace("PCT", "2.4"));
    let tail = format!("{older}\n{newer}\n");
    assert_eq!(recorded(tail.as_bytes()).unwrap(), [weekly(2)]);
}

#[test]
fn a_newer_record_without_limits_does_not_hide_an_older_one() {
    let older = token_count(&RECORDED.replace("PCT", "1.0"));
    let tail = format!("{older}\n{}\n", token_count("null"));
    assert_eq!(recorded(tail.as_bytes()).unwrap(), [weekly(1)]);
}

#[test]
fn only_token_counts_count_and_a_cut_first_line_is_skipped() {
    let other = format!(r#"{{"type":"response_item","payload":{{"type":"message","rate_limits":{}}}}}"#, RECORDED.replace("PCT", "9"));
    assert!(recorded(other.as_bytes()).is_none());
    assert!(recorded(br#"t","rate_limits":{"primary":{"#).is_none());
    assert!(recorded(b"").is_none());
}

#[test]
fn an_account_without_chatgpt_sign_in_is_no_failure() {
    let error = Error { code: "native", message: "codex account authentication required to read rate limits".into() };
    assert!(signed_out(&error));
    assert!(!signed_out(&Error { code: "native", message: "upstream timed out".into() }));
}
