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

#[test]
fn a_tab_moves_before_its_neighbour_or_to_the_end() {
    let keys: Vec<String> = ["a", "b", "c"].iter().map(|k| k.to_string()).collect();
    let refs: Vec<&String> = keys.iter().collect();
    // Before c: herdr inserts before the tab at c's index, wherever the moved tab is.
    assert_eq!(tab_insert_index(&refs, Some(&keys[2]), true), 2);
    assert_eq!(tab_insert_index(&refs, Some(&keys[0]), true), 0);
    // The end (memberships.append): one past the last tab, not before it.
    assert_eq!(tab_insert_index(&refs, None, true), 3);
}

#[test]
fn without_memberships_append_a_tab_without_before_keeps_the_last_tabs_index() {
    let keys: Vec<String> = ["a", "b", "c"].iter().map(|k| k.to_string()).collect();
    let refs: Vec<&String> = keys.iter().collect();
    // The index the Mac's recorded moves send: herdr puts the tab before the last one.
    assert_eq!(tab_insert_index(&refs, None, false), 2);
    assert_eq!(tab_insert_index(&refs[..1], None, false), 0);
    assert_eq!(tab_insert_index(&[], None, false), 0);
    // A move before a tab is the same for every client.
    assert_eq!(tab_insert_index(&refs, Some(&keys[1]), false), 1);
}
