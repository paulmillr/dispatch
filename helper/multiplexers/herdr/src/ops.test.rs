use super::*;

fn herdr(socket: &str) -> Herdr {
    Herdr::new(Config {
        executable: "/opt/herdr".into(),
        socket: socket.into(),
        session: "main".into(),
        directory: "/tmp".into(),
        environment: BTreeMap::from([("PATH".to_owned(), "/usr/bin".to_owned())]),
        uid: 501,
    })
}

#[test]
fn the_server_probe_asks_status_and_never_starts_a_server() {
    let probe = herdr("/tmp/hs/hd.sock").server_probe().unwrap();
    assert_eq!(probe.get_program(), "/opt/herdr");
    assert_eq!(probe.get_args().collect::<Vec<_>>(), ["status", "server"]);
    assert!(probe.get_envs().any(|(k, v)| k == "HERDR_SOCKET_PATH" && v == Some("/tmp/hs/hd.sock".as_ref())));
    let default = herdr("").server_probe().unwrap();
    assert!(!default.get_envs().any(|(k, _)| k == "HERDR_SOCKET_PATH"), "the environment's socket");
    assert_eq!(herdr("").version().unwrap().get_args().collect::<Vec<_>>(), ["--version"]);
}

#[test]
fn only_status_running_counts_as_running() {
    let mux = herdr("");
    assert!(mux.running(Some(0), b"status: running\nversion: 0.9.3\nsocket: /x\n"));
    assert!(!mux.running(Some(0), b"status: not running\nsocket: /x\n"));
    assert!(!mux.running(Some(1), b"status: running\n"));
    assert!(!mux.running(None, b""));
}
