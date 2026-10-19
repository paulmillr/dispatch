use super::*;
use std::os::unix::fs::PermissionsExt;

fn shell(name: &str, body: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!("search-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let path = directory.join("shell");
    // Called as `shell -lc COMMAND`, like a login shell.
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    path
}

#[test]
fn the_login_shells_path_comes_first_and_the_channel_path_is_kept() {
    let merged = merge(
        Some(OsStr::new("/opt/homebrew/bin:/usr/bin:relative::/bin")),
        Some(OsStr::new("/usr/bin:/bin:/usr/sbin:/sbin")),
        &[PathBuf::from("/opt/homebrew/bin"), PathBuf::from("/home/u/.local/bin"), PathBuf::from("/missing")],
        &|path| path != Path::new("/missing"),
    );
    assert_eq!(merged, "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/home/u/.local/bin");
}

#[test]
fn without_a_login_path_the_known_directories_that_exist_are_appended() {
    let merged = merge(None, Some(OsStr::new("/usr/bin:/bin")), &known(Path::new("/home/u")), &|path| {
        path == Path::new("/home/u/.local/bin") || path == Path::new("/opt/homebrew/bin")
    });
    assert_eq!(merged, "/usr/bin:/bin:/opt/homebrew/bin:/home/u/.local/bin");
}

#[test]
fn a_login_shell_prints_its_path_between_markers_despite_profile_output() {
    // A chatty profile (more than a pipe buffer) and output after the marker.
    let path = shell("chatty", "head -c 200000 /dev/zero | tr '\\0' x; PATH=/tool/bin:/usr/bin; eval \"$2\"; echo done");
    let home = std::env::temp_dir();
    assert_eq!(login(path.as_os_str(), &home, Duration::from_secs(5)).as_deref(), Some(OsStr::new("/tool/bin:/usr/bin")));
}

#[test]
fn a_profile_cannot_read_the_helpers_stdin() {
    let path = shell("reader", "read line; PATH=\"/read/$line\"; eval \"$2\"");
    let path = login(path.as_os_str(), &std::env::temp_dir(), Duration::from_secs(5));
    assert_eq!(path.as_deref(), Some(OsStr::new("/read/")));
}

#[test]
fn a_slow_or_failing_login_shell_gives_no_path_within_the_deadline() {
    let slow = shell("slow", "sleep 30");
    let start = Instant::now();
    assert_eq!(login(slow.as_os_str(), &std::env::temp_dir(), Duration::from_millis(300)), None);
    assert!(start.elapsed() < Duration::from_secs(3), "{:?}", start.elapsed());
    let failing = shell("failing", "PATH=/x; eval \"$2\"; exit 3");
    assert_eq!(login(failing.as_os_str(), &std::env::temp_dir(), Duration::from_secs(5)), None);
    assert_eq!(login(OsStr::new("/nonexistent/shell"), &std::env::temp_dir(), Duration::from_secs(1)), None);
}

#[test]
fn the_login_shell_also_says_its_home() {
    let path = shell("home", "PATH=/tool/bin; HOME=/login/home; eval \"$2\"");
    let (path, home) = environment(path.as_os_str(), &std::env::temp_dir(), Duration::from_secs(5)).unwrap();
    assert_eq!(path, "/tool/bin");
    assert_eq!(home.as_deref(), Some(OsStr::new("/login/home")));
    let relative = shell("relative", "PATH=/tool/bin; HOME=relative; eval \"$2\"");
    let (_, home) = environment(relative.as_os_str(), &std::env::temp_dir(), Duration::from_secs(5)).unwrap();
    assert_eq!(home, None, "only an absolute HOME");
}
