use super::*;
use dispatch_helper_core::json::Json;

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn parent_overrides_reach_the_side_server_in_order_and_profiles_are_named() {
    let parsed = |argv: &[&str]| overrides(&strings(argv));
    // What the managed launch runs (the TUI against the private server) and a no-daemon TUI.
    let managed = parsed(&[
        "/opt/codex", "--remote", "unix:///tmp/dispatch-codex-1/control.sock", "--cd", "/work",
        "-m", "-c", "-c", "model=\"m\"", "--config=model_provider=\"p\"", "--enable", "a_feature",
        "--disable=b_feature", "-cmodel_reasoning_effort=\"high\"", "-s", "read-only", "resume",
    ]);
    assert_eq!(managed, Overrides {
        arguments: strings(&[
            "-c", "model=\"m\"", "-c", "model_provider=\"p\"", "--enable", "a_feature",
            "--disable=b_feature", "-c", "model_reasoning_effort=\"high\"",
        ]),
        profile: false,
    });
    // `-c=` is the option's value after the `=`.
    assert_eq!(parsed(&["codex", "-c=model=\"m\""]).arguments, strings(&["-c", "model=\"m\""]));
    // `-c profile=…` selects a profile too.
    assert!(parsed(&["codex", "-c", "profile=\"work\""]).profile);
    // Option values are never options; `--` ends them; -i takes several values.
    assert_eq!(parsed(&["codex", "--add-dir", "--enable", "-i", "a.png", "b.png", "-c", "x=1", "--", "-c", "y=2"]).arguments,
               strings(&["-c", "x=1"]));
    for argv in [&["codex", "-p", "work"][..], &["codex", "--profile", "work"], &["codex", "--profile=work"], &["codex", "-pwork"]] {
        assert!(parsed(argv).profile, "{argv:?}");
    }
    assert!(!parsed(&["codex", "--", "-p", "work"]).profile);
    assert!(!parsed(&["codex", "-m", "-p"]).profile);
    // The program itself is not an option.
    assert_eq!(parsed(&["-cx=1"]), Overrides::default());
}

#[test]
fn the_side_runs_on_the_model_and_provider_codex_reports_for_the_parent() {
    let read = Json::parse(br#"{"thread":{"id":"t","model":"custom-model","modelProvider":"custom","reasoningEffort":"high"}}"#).unwrap();
    assert_eq!(pinned(read.root()).unwrap(), Pinned {
        model: "custom-model".into(),
        provider: "custom".into(),
        effort: Some("high".into()),
    });
    let without = Json::parse(br#"{"thread":{"id":"t","model":"m","modelProvider":"p","reasoningEffort":null}}"#).unwrap();
    assert_eq!(pinned(without.root()).unwrap().effort, None);
    // An older or partial reply never falls back to the configuration's defaults.
    for reply in [&br#"{"thread":{"id":"t","model":"m"}}"#[..], br#"{"thread":{"modelProvider":"p","model":""}}"#, b"{}"] {
        assert!(pinned(Json::parse(reply).unwrap().root()).is_err());
    }
}

#[test]
fn the_fork_names_the_pinned_model_provider_and_effort() {
    let configuration = Json::parse(br#"{"mcp_servers":{"docs":{"command":"docs"}}}"#).unwrap();
    let pinned = Pinned { model: "custom-model".into(), provider: "custom".into(), effort: Some("high".into()) };
    for read_only in [true, false] {
        let request = Json::parse(&fork("parent", configuration.root(), read_only, &pinned).unwrap()).unwrap();
        let root = request.root();
        let text = |value: Option<Value<'_>>| value.and_then(Value::string).map(str::to_owned);
        assert_eq!(text(root.get("model")).as_deref(), Some("custom-model"));
        assert_eq!(text(root.get("modelProvider")).as_deref(), Some("custom"));
        let config = root.get("config").unwrap();
        assert_eq!(text(config.get("model_reasoning_effort")).as_deref(), Some("high"));
        assert_eq!(text(root.get("sandbox")).as_deref(), read_only.then_some("read-only"));
        assert_eq!(config.get("mcp_servers").and_then(|servers| servers.get("docs")).is_some(), read_only);
        let reply = Json::parse(br#"{"model":"custom-model","modelProvider":"custom"}"#).unwrap();
        assert!(confirmed(reply.root(), &pinned).is_ok());
        let other = Json::parse(br#"{"model":"custom-model","modelProvider":"dispatch_fixture"}"#).unwrap();
        assert!(confirmed(other.root(), &pinned).is_err());
    }
    let plain = Pinned { effort: None, ..pinned };
    let request = Json::parse(&fork("parent", configuration.root(), false, &plain).unwrap()).unwrap();
    assert!(request.root().get("config").is_none());
}

#[test]
fn credentials_come_from_what_the_effective_configuration_names() {
    let configuration = Json::parse(br#"{
        "model_providers": {
            "custom": {"env_key": "SAM_PROVIDER_KEY", "env_http_headers": {"X-Org": "SAM_PROVIDER_ORG"}, "aws": null},
            "other": {"env_key": "OTHER_PROVIDER_KEY"},
            "gateway": {"env_key": null, "aws": {"profile": "sam"}}
        },
        "mcp_servers": {
            "docs": {"command": "docs", "env_vars": ["SAM_DOCS_TOKEN", {"name": "SAM_DOCS_URL"}], "enabled": true},
            "web": {"url": "http://127.0.0.1:1/mcp", "bearer_token_env_var": "SAM_WEB_TOKEN", "env_http_headers": {"X-Key": "SAM_WEB_KEY"}},
            "off": {"command": "off", "env_vars": ["SAM_OFF_TOKEN"], "enabled": false}
        }
    }"#).unwrap();
    let root = configuration.root();
    // A read-only side runs no MCP server: only the provider's names, then the declared ones.
    assert_eq!(referenced(root, "custom", true, &strings(&["SAM_DECLARED", "SAM_PROVIDER_KEY"])),
               strings(&["SAM_PROVIDER_KEY", "SAM_PROVIDER_ORG", "SAM_DECLARED"]));
    assert_eq!(referenced(root, "custom", false, &[]), strings(&[
        "SAM_PROVIDER_KEY", "SAM_PROVIDER_ORG", "SAM_DOCS_TOKEN", "SAM_DOCS_URL", "SAM_WEB_TOKEN", "SAM_WEB_KEY",
    ]));
    assert_eq!(referenced(root, "gateway", true, &[]), strings(&AWS));
    assert_eq!(referenced(root, "openai", true, &[]), strings(&OPENAI));
    assert_eq!(referenced(root, "ollama", true, &[]), strings(&OSS));
    assert_eq!(referenced(root, "amazon-bedrock", true, &[]), strings(&AWS));
    assert!(referenced(root, "unknown", true, &[]).is_empty());
    // Names that could change how the side agent loads, or Dispatch's own, are never forwarded.
    let hostile = Json::parse(br#"{"model_providers":{"x":{"env_key":"DYLD_INSERT_LIBRARIES","env_http_headers":{"a":"LD_PRELOAD","b":"DISPATCH_HELPER_ENDPOINT","c":"NOT=VALID","d":"","e":"1ABC"}}}}"#).unwrap();
    assert!(referenced(hostile.root(), "x", false, &[]).is_empty());
}

#[test]
fn the_declared_list_takes_portable_names_once() {
    assert_eq!(declared(b"SAM_A, SAM_B:SAM_C\tSAM_A  DISPATCH_X LD_PRELOAD 9X bad-name"),
               strings(&["SAM_A", "SAM_B", "SAM_C"]));
    assert!(declared(b"").is_empty());
    assert_eq!(declared(&b"N ".repeat(100)).len(), 1);
}

#[test]
fn permission_overrides_never_reach_a_side() {
    // What a /side may do without asking stays its configuration's and Dispatch's, as for -a/-s.
    let parsed = overrides(&strings(&[
        "codex", "-c", "approval_policy=\"never\"", "-c", "sandbox_mode=\"danger-full-access\"",
        "--config=sandbox_workspace_write.network_access=true", "-capprovals_reviewer=\"auto\"",
        "-c", "\"sandbox_permissions\"=[\"disk-full-read-access\"]", "-c", "default_permissions=\"full\"",
        "-c", "permissions.network=true", "-c", " projects.\"/work\".trust_level=\"trusted\"",
        "-a", "never", "-s", "danger-full-access", "-c", "model=\"kept\"",
    ]));
    assert_eq!(parsed, Overrides { arguments: strings(&["-c", "model=\"kept\""]), profile: false });
    // A key that only starts like one is kept.
    assert_eq!(overrides(&strings(&["codex", "-c", "sandbox_mode_note=1"])).arguments, strings(&["-c", "sandbox_mode_note=1"]));
}
