use super::*;

#[test]
fn outdated_extensions_can_be_discovered_but_cannot_control_chat() {
    for version in ["extension-v1", "unknown", "extension-v3"] {
        assert!(require_events(version, "probe").is_ok());
        for method in ["state", "prompt", "configure", "abort", "subscribe", "answer"] {
            let error = require_events(version, method).unwrap_err();
            assert_eq!(error.code, "unavailable");
            assert!(error.message.contains("/reload"));
        }
    }
    for method in ["probe", "state", "prompt", "configure", "abort", "subscribe", "answer"] {
        assert!(require_events("extension-v2", method).is_ok());
    }
    assert!(std::str::from_utf8(include_bytes!("../resources/bridge.js")).unwrap().contains("version: \"extension-v2\""));
}

#[test]
fn an_environment_value_that_is_not_utf8_is_refused_not_replaced_by_the_default() {
    // The account's home (Runtime::home) is used only without HOME.
    let runtime = Rc::new(RefCell::new(Runtime { home: PathBuf::from("/home/u2"), ..Runtime::default() }));
    let directory = |variables: Vec<(&'static str, &'static [u8])>| {
        home(&runtime, &Data::Object(variables.into_iter().map(|(name, value)| (name, Data::Bytes(value))).collect()))
    };
    let refused = Err(fail("not_sent", "Pi configuration directory is unavailable"));
    assert_eq!(vec![
        directory(vec![("HOME", b"/home/u1")]),
        directory(vec![]),
        directory(vec![("HOME", b"/home/u\xff")]),
        directory(vec![("HOME", b"/home/u1"), ("PI_CODING_AGENT_DIR", b"~/agents")]),
        directory(vec![("HOME", b"/home/u1"), ("PI_CODING_AGENT_DIR", b"/srv/p\xff")]),
    ], vec![
        Ok("/home/u1/.pi/agent".into()),
        Ok("/home/u2/.pi/agent".into()),
        refused.clone(),
        Ok("/home/u1/agents".into()),
        refused,
    ]);
}

#[test]
fn session_totals_reach_chat_usage_beside_the_context_and_bad_counters_stay_unknown() {
    let state = Json::parse(br#"{"usage":{"tokens":5400,"contextWindow":200000},
        "totals":{"input":1234,"output":567.0,"cacheRead":90000,"cacheWrite":800,"cost":0.0421,"subscription":true}}"#).unwrap();
    let encoded = crate::harness::usage(state.root().get("usage"), state.root().get("totals")).unwrap();
    let root = encoded.root();
    let info = root.get("info").unwrap();
    let total = info.get("total_token_usage").unwrap();
    assert_eq!((total.get("input_tokens").and_then(Data::signed), total.get("output_tokens").and_then(Data::signed)), (Some(1234), Some(567)));
    assert_eq!(info.get("last_token_usage").and_then(|last| last.get("total_tokens")).and_then(Data::unsigned), Some(5400));
    assert_eq!(info.get("model_context_window").and_then(Data::unsigned), Some(200_000));
    assert_eq!(info.get("total_cost_usd").and_then(Data::number), Some(0.0421));
    assert_eq!(info.get("subscription").and_then(Data::boolean), Some(true));

    // An older bridge sends no totals; a negative or missing counter is left out, not zero.
    let old = Json::parse(br#"{"usage":{"tokens":10,"contextWindow":100},"totals":{"input":-1,"cost":-2}}"#).unwrap();
    let encoded = crate::harness::usage(old.root().get("usage"), old.root().get("totals")).unwrap();
    let root = encoded.root();
    let info = root.get("info").unwrap();
    assert!(info.get("total_token_usage").is_none() && info.get("total_cost_usd").is_none() && info.get("subscription").is_none());
    assert!(crate::harness::usage(None, None).is_none());
}
