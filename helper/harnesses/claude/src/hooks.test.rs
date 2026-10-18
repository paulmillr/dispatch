use super::*;

const SESSION_ID: &str = "4dd13d79-9d1a-4cab-8bbd-29cf0e7ec160";

fn permission(suggestions: &str) -> Request {
    let text = format!(
        r#"{{"session_id":"{SESSION_ID}","hook_event_name":"PermissionRequest","tool_name":"Bash",
            "tool_input":{{"command":"npm test","description":"Run tests"}}{suggestions}}}"#
    );
    Request::new(Json::parse(text.as_bytes()).unwrap()).unwrap()
}

fn decision(request: &Request, choice: usize) -> String {
    let reply = request
        .answer(vec![("approval".into(), Answer::Options(vec![choice]))])
        .unwrap();
    String::from_utf8(reply).unwrap()
}

#[test]
fn without_suggestions_the_approval_keeps_its_three_choices() {
    let request = permission("");
    let labels: Vec<_> = request.interaction.questions[0].options.iter().map(|c| c.label.as_str()).collect();
    assert_eq!(labels, ["Allow", "Deny", "Terminal"]);
    assert!(decision(&request, 0).contains(r#""behavior":"allow""#));
}

#[test]
fn claudes_allow_rule_suggestions_offer_this_session_after_the_ordinary_choices() {
    let request = permission(
        r#","permission_suggestions":[
            {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"},
            {"type":"setMode","mode":"acceptEdits","destination":"session"}]"#,
    );
    let options = &request.interaction.questions[0].options;
    assert_eq!(options.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), ["Allow", "Deny", "Terminal", SESSION]);
    assert_eq!(options[3].label, "This session");
    assert_eq!(options[3].detail.as_deref(), Some("Allow Bash(npm test:*) until Claude exits"));
    let reply = decision(&request, 3);
    let json = Json::parse(reply.as_bytes()).unwrap();
    let decision = json.root().get("hookSpecificOutput").unwrap().get("decision").unwrap();
    assert_eq!(text(decision, "behavior"), Some("allow"));
    let permissions: Vec<_> = decision.get("updatedPermissions").unwrap().array().unwrap().collect();
    assert_eq!(permissions.len(), 1, "only the allow rules, not the mode change");
    assert_eq!(text(permissions[0], "destination"), Some("session"));
    assert_eq!(text(permissions[0], "type"), Some("addRules"));
    let rule = permissions[0].get("rules").unwrap().array().unwrap().next().unwrap();
    assert_eq!(text(rule, "ruleContent"), Some("npm test:*"));
    // The ordinary choices keep their meaning and indices.
    assert!(decision_text(&request, 1).contains(r#""behavior":"deny""#));
}

fn decision_text(request: &Request, choice: usize) -> String {
    decision(request, choice)
}

#[test]
fn malformed_suggestions_offer_nothing_more() {
    for suggestions in [
        r#","permission_suggestions":[{"type":"addRules","rules":[],"behavior":"allow"}]"#,
        r#","permission_suggestions":[{"type":"addRules","rules":[{"ruleContent":"x"}],"behavior":"allow"}]"#,
        r#","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash"}],"behavior":"deny"}]"#,
        r#","permission_suggestions":"no""#,
    ] {
        assert_eq!(permission(suggestions).interaction.questions[0].options.len(), 3, "{suggestions}");
    }
}
