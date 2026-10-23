use super::*;
use dispatch_helper_core::wire::body;

fn process() -> Process {
    Process {
        pid: 42,
        parent: 1,
        group: 42,
        foreground: 42,
        tty: 7,
        start: [10, 0],
        executable: "/bin/dispatch-helper".into(),
        arguments: vec![],
        files: vec![],
    }
}
fn setup() -> Setup {
    Setup::new(
        Some("/account".into()),
        Some(true),
        true,
        "helper hook claude".into(),
        Some(process()),
        Box::new(|_, _| unreachable!()),
    )
}
#[test]
fn setup_rejects_a_reused_pid_or_replaced_process_before_reading_environment() {
    for change in 0..3 {
        let mut current = process();
        match change {
            0 => current.pid += 1,
            1 => current.start[0] += 1,
            _ => current.executable = "/other".into(),
        }
        let Err(error) = setup().complete(Ok(Output::Process(current))) else {
            panic!("accepted different process")
        };
        assert_eq!(error.code, "process");
    }
}
#[test]
fn setup_pins_environment_to_the_captured_process_and_honors_its_home() {
    let mut setup = setup();
    let Next::Job(Job::Native { name, value }) =
        setup.complete(Ok(Output::Process(process()))).unwrap()
    else {
        panic!("expected environment job")
    };
    assert_eq!(name, "environment");
    let input = body::decode_plain(&value).unwrap();
    assert_eq!(
        input.get("start").unwrap().array().unwrap().next().unwrap().unsigned(),
        Some(10)
    );
    assert_eq!(
        input.get("executable").and_then(Data::path),
        Some(std::path::Path::new("/bin/dispatch-helper"))
    );
    let environment = Data::Object(vec![
        ("HOME", Data::from(std::path::Path::new("/peer"))),
        ("CLAUDE_CONFIG_DIR", Data::from(std::path::Path::new(""))),
    ]);
    let output = Output::Value(body::encode_plain(&environment).unwrap());
    let Next::Job(Job::Stat { path, .. }) = setup.complete(Ok(output)).unwrap() else {
        panic!("expected settings read")
    };
    assert_eq!(path, PathBuf::from("/peer/.claude/settings.json"));
}
