use super::*;

/// A failure recorded with `number` on `os`, replayed here: its number on this system, its text, its kind.
fn replayed(number: i32, os: &str) -> (Option<i32>, String, io::ErrorKind) {
    let error = failure(&Data::Object(vec![("errno", Data::Signed(number.into()))]), os).unwrap();
    (errno(&error), error.to_string(), error.kind())
}

#[test]
fn a_failure_recorded_on_the_other_system_means_the_same_error_and_reads_as_recorded() {
    // (macOS number, Linux number, macOS text, Linux text): the number differs, the text differs, both, neither.
    let cases = [
        (61, 111, "Connection refused", "Connection refused"),
        (6, 6, "Device not configured", "No such device or address"),
        (60, 110, "Operation timed out", "Connection timed out"),
        (2, 2, "No such file or directory", "No such file or directory"),
    ];
    let (macos, other) = (cfg!(target_os = "macos"), if cfg!(target_os = "macos") { "linux" } else { "macos" });
    let expected: Vec<_> = cases.iter().map(|&(mac, linux, mac_text, linux_text)| {
        let (here, there, text) = if macos { (mac, linux, linux_text) } else { (linux, mac, mac_text) };
        (Some(here), format!("{text} (os error {there})"), io::Error::from_raw_os_error(here).kind())
    }).collect();
    let actual: Vec<_> = cases.iter().map(|&(mac, linux, ..)| replayed(if macos { linux } else { mac }, other)).collect();
    assert_eq!(actual, expected);
    // Recorded on this system: the system's own error, as recorded.
    let own = io::Error::from_raw_os_error(61);
    assert_eq!(replayed(61, std::env::consts::OS), (Some(61), own.to_string(), own.kind()));
}

#[test]
fn a_collected_run_reads_back_as_recorded() {
    for (status, truncated) in [(Some(0), false), (Some(128), false), (None, true)] {
        let collected = crate::api::Collected {
            status,
            stdout: b"a\0b\xff".to_vec(),
            stderr: b"fatal: not a git repository\n".to_vec(),
            truncated,
        };
        let bytes = encode(&Ok(Output::Collected(collected.clone()))).unwrap();
        match decode(7, &bytes, std::env::consts::OS).unwrap().result {
            Ok(Output::Collected(read)) => assert_eq!(read, collected),
            other => panic!("{other:?}"),
        }
    }
}

#[test]
fn a_folder_read_says_it_is_one_and_replays_so() {
    let root = std::env::temp_dir().join(format!("dispatch-file-folder-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let folder = read(&root, 0, 16).unwrap_err();
    assert_eq!(folder.kind(), io::ErrorKind::IsADirectory);
    // Recorded and replayed: the same kind, so the files plugin answers `is_directory` either way.
    let bytes = encode(&Err(folder)).unwrap();
    let replayed = decode(3, &bytes, std::env::consts::OS).unwrap().result.unwrap_err();
    assert_eq!(replayed.kind(), io::ErrorKind::IsADirectory);
    // A file still reads; a path that is neither stays refused as before.
    std::fs::write(root.join("a.txt"), b"hello").unwrap();
    match read(&root.join("a.txt"), 0, 16).unwrap() {
        Output::Read { bytes, .. } => assert_eq!(bytes, b"hello"),
        other => panic!("{other:?}"),
    }
    assert_eq!(read(&root.join("missing"), 0, 16).unwrap_err().kind(), io::ErrorKind::NotFound);
    std::fs::remove_dir_all(&root).unwrap();
}
