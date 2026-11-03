use super::*;

const COMMAND: &str = "'/home/sam/.dispatch/bin/dispatch-helper' hook codex";

#[test]
fn a_fresh_install_contains_only_the_supported_hooks() {
    let (after, installed) = plan(None, COMMAND).unwrap();
    assert!(!installed);
    let bytes = after.unwrap();
    let document = Json::parse(&bytes).unwrap();
    let hooks = document.root().get("hooks").unwrap();
    let events: Vec<_> = hooks.object().unwrap().map(|(event, _)| event).collect();
    assert_eq!(events, ["PermissionRequest", "SubagentStart", "SubagentStop"]);
    for (event, groups) in hooks.object().unwrap() {
        let group = groups.array().unwrap().next().unwrap();
        let handler = group.get("hooks").unwrap().array().unwrap().next().unwrap();
        assert_eq!(handler.get("command").and_then(Value::string), Some(COMMAND));
        let message = Json::parse(format!(r#"{{"hook_event_name":"{event}","session_id":"019a0000-0000-7000-8000-000000000001"}}"#).as_bytes()).unwrap();
        let hook = crate::hooks::read(&message).unwrap();
        assert_eq!(hook.interactive, event == "PermissionRequest");
    }
    assert_eq!(plan(Some(&bytes), COMMAND).unwrap(), (None, true));
}

#[test]
fn installing_preserves_other_handlers_and_settings() {
    let before = br#"{"description":"Sam's hooks","hooks":{"Stop":[{"hooks":[{"type":"command","command":"notify","timeout":7}]}],"PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"review"}]}]}}"#;
    let (after, _) = plan(Some(before), COMMAND).unwrap();
    let bytes = after.unwrap();
    let document = Json::parse(&bytes).unwrap();
    assert_eq!(document.root().get("description").and_then(Value::string), Some("Sam's hooks"));
    let hooks = document.root().get("hooks").unwrap();
    let stop: Vec<_> = hooks.get("Stop").unwrap().array().unwrap().collect();
    assert_eq!(stop.len(), 1);
    let handlers: Vec<_> = stop[0].get("hooks").unwrap().array().unwrap().collect();
    assert_eq!(handlers.len(), 1);
    assert_eq!(handlers[0].get("command").and_then(Value::string), Some("notify"));
    assert_eq!(handlers[0].get("type").and_then(Value::string), Some("command"));
    assert_eq!(handlers[0].get("timeout").and_then(Value::unsigned), Some(7));
    let groups: Vec<_> = hooks.get("PermissionRequest").unwrap().array().unwrap().collect();
    assert_eq!(groups.len(), 2);
    assert_eq!(groups[0].get("matcher").and_then(Value::string), Some("Bash"));
    assert_eq!(plan(Some(&bytes), COMMAND).unwrap(), (None, true));
}
