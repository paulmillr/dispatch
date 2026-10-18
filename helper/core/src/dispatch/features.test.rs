use super::*;

fn hello<'a>(params: Data<'a>) -> Data<'a> {
    Data::Object(vec![("method", Data::String("hello")), ("params", params)])
}

#[test]
fn a_hello_without_features_is_left_alone() {
    assert_eq!(requested(&hello(Data::Object(Vec::new()))).unwrap(), None);
    let other = Data::Object(vec![
        ("method", Data::String("echo")),
        ("params", Data::Object(vec![("features", Data::Array(vec![Data::String(CHAT_LIST)]))])),
    ]);
    assert_eq!(requested(&other).unwrap(), None, "only hello negotiates");
}

#[test]
fn known_features_are_accepted_and_unknown_ones_dropped() {

    let root = hello(Data::Object(vec![(
        "features",
        Data::Array(vec![
            Data::String(TERMINALS_COALESCE),
            Data::String("future.thing"),
            Data::String(CHAT_LIST),
        ]),
    )]));
    let accepted = requested(&root).unwrap().unwrap();
    let expected: Vec<_> = [CHAT_LIST, TERMINALS_COALESCE].into_iter().filter(|f| KNOWN.contains(f)).collect();
    assert_eq!(accepted.into_iter().collect::<Vec<_>>(), expected);
    // The ordinary request check then sees a hello without params.
    let stripped = without(&root).unwrap();
    assert_eq!(stripped.get("params").and_then(Data::object).map(|f| f.count()), Some(0));
    let extra = hello(Data::Object(vec![("features", Data::Array(Vec::new())), ("other", Data::Null)]));
    assert!(without(&extra).is_err(), "hello still refuses unknown params");
}

#[test]
fn malformed_features_are_refused() {
    for bad in [
        Data::String(CHAT_LIST),
        Data::Array(vec![Data::Unsigned(1)]),
        Data::Array((0..65).map(|_| Data::String(CHAT_LIST)).collect()),
    ] {
        assert!(requested(&hello(Data::Object(vec![("features", bad)]))).is_err());
    }
}

#[test]
fn clients_without_interaction_options_see_the_interaction_as_before() {
    let choice = |id: &str| Choice { id: id.into(), label: id.into(), detail: None };
    let question = |ids: &[&str]| crate::api::Question {
        id: "approval".into(),
        header: "Bash".into(),
        text: "Bash\n{}".into(),
        secret: false,
        options: ids.iter().map(|id| choice(id)).collect(),
        multiple: false,
        custom: false,
        blocks: Vec::new(),
    };
    let interaction = |ids: &[&str]| Interaction {
        id: "x".into(),
        key: None,
        approval: true,
        blocking: true,
        questions: vec![question(ids)],
        turn: None,
        record: None,
    };
    assert!(legacy(&interaction(&["Allow", "Deny", "Terminal"])).is_none(), "nothing to hide: the same bytes");
    let extended = interaction(&["Allow", "Deny", "Terminal", "Session"]);
    let shown = legacy(&extended).unwrap();
    assert_eq!(shown.questions[0].options.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), ["Allow", "Deny", "Terminal"]);
    let mut encoded = Vec::new();
    crate::encode::Encode::encode(&shown, &mut encoded);
    let mut original = Vec::new();
    crate::encode::Encode::encode(&interaction(&["Allow", "Deny", "Terminal"]), &mut original);
    assert_eq!(encoded, original);
}

/// Clients answer by option index. An agent's own question names its choices by their labels, so one may be called
/// "Session": hiding it from a client without interaction.options would shift the indices that client answers with
/// onto other choices. Only an approval's trailing extension choices are hidden.
#[test]
fn only_an_approvals_trailing_extension_choices_are_hidden() {
    let choice = |id: &str| Choice { id: id.into(), label: id.into(), detail: None };
    let interaction = |approval: bool, ids: &[&str]| Interaction {
        id: "x".into(),
        key: None,
        approval,
        blocking: true,
        questions: vec![crate::api::Question {
            id: "scope".into(),
            header: "Scope".into(),
            text: "Where should this setting live?".into(),
            secret: false,
            options: ids.iter().map(|id| choice(id)).collect(),
            multiple: false,
            custom: false,
            blocks: Vec::new(),
        }],
        turn: None,
        record: None,
    };
    assert!(legacy(&interaction(false, &["Project", "Session", "Global"])).is_none(), "an agent's question is shown whole");
    assert!(legacy(&interaction(false, &["Project", "Session"])).is_none());
    assert!(legacy(&interaction(true, &["Allow", "Session", "Deny"])).is_none(), "only trailing choices can go");
    let shown = legacy(&interaction(true, &["Allow", "Deny", "Terminal", "Session"])).unwrap();
    assert_eq!(shown.questions[0].options.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), ["Allow", "Deny", "Terminal"]);
}

#[test]
fn versions_come_from_the_first_line_and_tmux_reports_paste_state_from_3_7() {
    assert_eq!(version(b"tmux 3.7c\n").as_deref(), Some("3.7c"));
    assert_eq!(version(b"herdr 0.9.3\nextra").as_deref(), Some("0.9.3"));
    assert_eq!(version(b"usage: nothing"), None);
    assert_eq!(version(b""), None);
    assert_eq!(paste_state("3.6"), Some(false));
    assert_eq!(paste_state("3.6a"), Some(false));
    assert_eq!(paste_state("3.7"), Some(true));
    assert_eq!(paste_state("3.7c"), Some(true));
    assert_eq!(paste_state("next-3.8"), Some(true));
    assert_eq!(paste_state("4.0"), Some(true));
    assert_eq!(paste_state("master"), None);
}

/// The native multiplexer starts a launch's program itself: the name goes, the rest of the
/// environment stays, and a command without it is left as it was (the Mac never sets it).
#[test]
fn a_program_the_multiplexer_starts_never_sees_the_launch_name() {
    use std::ffi::OsStr;
    let mut plain = std::process::Command::new("/usr/bin/env");
    strip_launch_name(&mut plain);
    assert_eq!(plain.get_envs().count(), 0, "untouched without the name");

    let mut command = std::process::Command::new("/usr/bin/env");
    command.env(LAUNCH_NAME, "claude").env("DISPATCH_KEEP", "1");
    strip_launch_name(&mut command);
    assert_eq!(launch_name(&command), None);
    let envs: Vec<_> = command.get_envs().collect();
    assert!(envs.contains(&(OsStr::new("DISPATCH_KEEP"), Some(OsStr::new("1")))));
    let output = String::from_utf8(command.output().unwrap().stdout).unwrap();
    assert!(output.contains("DISPATCH_KEEP=1"));
    assert!(!output.contains(LAUNCH_NAME), "{output}");
}

#[test]
fn a_launch_names_its_window_only_with_a_short_printable_name() {
    let mut command = std::process::Command::new("dispatch-helper");
    assert_eq!(launch_name(&command), None, "the Mac's launches carry no name");
    command.env(LAUNCH_NAME, "claude");
    assert_eq!(launch_name(&command), Some("claude"));
    command.env(LAUNCH_NAME, "bad\nname");
    assert_eq!(launch_name(&command), None);
    command.env(LAUNCH_NAME, "x".repeat(65));
    assert_eq!(launch_name(&command), None);
}

#[test]
fn the_liveness_limit_defaults_to_three_missed_pings_and_is_bounded() {
    use std::{ffi::OsStr, time::Duration};
    assert_eq!(liveness(None), Duration::from_secs(45));
    assert_eq!(liveness(Some(OsStr::new("3"))), Duration::from_secs(3));
    assert_eq!(liveness(Some(OsStr::new("1"))), Duration::from_secs(45), "too short");
    assert_eq!(liveness(Some(OsStr::new("601"))), Duration::from_secs(45), "too long");
    assert_eq!(liveness(Some(OsStr::new("soon"))), Duration::from_secs(45));
}

#[test]
fn login_home_is_reported_only_when_it_differs_from_the_passwd_home() {
    use std::path::Path;
    assert_eq!(login_home("/home/u", Some(Path::new("/data/u"))).as_deref(), Some("/data/u"));
    assert_eq!(login_home("/home/u", Some(Path::new("/home/u"))), None);
    assert_eq!(login_home("/home/u", Some(Path::new("/home/u/"))), None);
    assert_eq!(login_home("/home/u", Some(Path::new("relative"))), None);
    assert_eq!(login_home("/home/u", Some(Path::new("/"))), None);
    assert_eq!(login_home("/home/u", None), None);
}
