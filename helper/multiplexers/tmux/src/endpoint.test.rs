use super::*;

/// One step's facts (`root`: its native job's answer) in a fresh check of `key`, then the endpoint's key: what a reopen
/// stores.
fn checked(step: Step, key: &str, root: Vec<(&str, Data<'_>)>) -> Result<String, io::ErrorKind> {
    let mut check = Check {
        key: key.into(),
        expected: None,
        server: None,
        directory: None,
        socket: None,
        endpoint: Endpoint {
            path: PathBuf::from("."),
            private: false,
            uid: 0,
            directory: [0; 2],
            socket: [0; 2],
            pid: 0,
            start: [0; 2],
            executable: PathBuf::new(),
        },
        steps: VecDeque::new(),
        step: Some(step),
        fd: None,
        work: None,
        at: Instant::now(),
        done: Box::new(|_, _, _| {}),
    };
    check.facts(Output::Value(body::encode_plain(&Data::Object(root)).unwrap())).map_err(|error| error.kind())?;
    Ok(check.endpoint.key("k"))
}

/// The key of a fresh check's endpoint with these facts.
fn key(path: &str, start: [u64; 2], executable: &str) -> String {
    format!(
        r#"tmux-reopen:{{"key":"k","path":"{path}","private":false,"uid":0,"directory":[0,0],"socket":[0,0],"pid":0,"start":[{},{}],"executable":"{executable}"}}"#,
        start[0], start[1]
    )
}

#[test]
fn a_path_that_is_not_utf8_is_refused_by_the_step_that_reads_it() {
    // The key holds paths as text: an absent TMUX_TMPDIR means /tmp, one that is not UTF-8 is refused, never replaced.
    let server = |executable: &'static [u8]| vec![
        ("pid", Data::Unsigned(0)),
        ("uid", Data::Unsigned(0)),
        ("executable", Data::Bytes(executable)),
        ("start", Data::Array(vec![Data::Unsigned(1), Data::Unsigned(2)])),
    ];
    let actual = vec![
        checked(Step::Account, "s1", vec![("uid", Data::Unsigned(0)), ("cwd", Data::Bytes(b"/home/u1"))]),
        checked(Step::Account, "s1", vec![("uid", Data::Unsigned(0)), ("cwd", Data::Bytes(b"/home/u\xff"))]),
        checked(Step::Environment, "tmux", vec![("TMUX_TMPDIR", Data::Bytes(b"/var/t1"))]),
        checked(Step::Environment, "tmux", vec![]),
        checked(Step::Environment, "tmux", vec![("TMUX_TMPDIR", Data::Bytes(b"/var/t\xff"))]),
        checked(Step::Server, "s1", server(b"/opt/t1/tmux")),
        checked(Step::Server, "s1", server(b"/opt/t\xff/tmux")),
    ];
    assert_eq!(actual, vec![
        Ok(key("/home/u1/s1", [0, 0], "")),
        Err(io::ErrorKind::InvalidData),
        Ok(key("/var/t1/tmux-0/default", [0, 0], "")),
        Ok(key("/tmp/tmux-0/default", [0, 0], "")),
        Err(io::ErrorKind::InvalidInput),
        Ok(key(".", [1, 2], "/opt/t1/tmux")),
        Err(io::ErrorKind::InvalidData),
    ]);
}
