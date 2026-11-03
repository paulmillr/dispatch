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
