use super::*;
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    path::PathBuf,
};

const SESSION: &str = "0123456789abcdef01234567";
const HELPER: &str = ".dispatch/bin/versions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/dispatch-helper";

/// A private home folder of this account, removed afterwards.
struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        use std::sync::atomic::{AtomicU64, Ordering};
        static SERIAL: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "dispatch-release-{}-{}",
            std::process::id(),
            SERIAL.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Self(path)
    }
    fn release(&self, path: &str) -> Result<(), String> {
        release(Some(&self.0), owner(), SESSION, path, 4242)
    }
    fn folder(&self) -> PathBuf {
        self.0.join(".dispatch/sessions").join(SESSION)
    }
    fn private(&self, relative: &str) -> PathBuf {
        let path = self.0.join(relative);
        fs::create_dir_all(&path).unwrap();
        let mut walked = self.0.clone();
        for part in Path::new(relative) {
            walked.push(part);
            fs::set_permissions(&walked, fs::Permissions::from_mode(0o700)).unwrap();
        }
        path
    }
}
impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn owner() -> u32 {
    unsafe { native::getuid() }
}

#[test]
fn a_release_writes_the_ready_file_the_login_reads() {
    let home = Home::new();
    home.release(HELPER).unwrap();
    let ready = home.folder().join("ready");
    assert_eq!(fs::read_to_string(&ready).unwrap(), format!("{HELPER}\n"));
    let metadata = fs::symlink_metadata(&ready).unwrap();
    // What the login's safe_file accepts: a plain file of the account, one link, mode 0600.
    assert!(metadata.is_file());
    assert_eq!((metadata.uid(), metadata.nlink(), metadata.mode() & 0o7777), (owner(), 1, 0o600));
    for folder in [".dispatch", ".dispatch/sessions", &format!(".dispatch/sessions/{SESSION}")] {
        assert_eq!(fs::metadata(home.0.join(folder)).unwrap().mode() & 0o777, 0o700, "{folder}");
    }
    let names: Vec<_> = fs::read_dir(home.folder()).unwrap().map(|entry| entry.unwrap().file_name()).collect();
    assert_eq!(names, ["ready"], "no pending file left");
    // The runtime folder's path is released the same way.
    let runtime = Home::new();
    runtime.release("dispatch/bin/versions/0000000000000000000000000000000000000000000000000000000000000000/dispatch-helper").unwrap();
}

#[test]
fn folders_another_login_made_first_are_used() {
    let home = Home::new();
    home.private(&format!(".dispatch/sessions/{SESSION}"));
    home.release(HELPER).unwrap();
    assert!(home.folder().join("ready").is_file());
}

#[test]
fn a_session_is_released_once() {
    let home = Home::new();
    home.release(HELPER).unwrap();
    assert_eq!(home.release(HELPER).unwrap_err(), "session already released");
    // A link counts too, dangling or not: the login refuses it, and nothing is written over it.
    let other = Home::new();
    let folder = other.private(&format!(".dispatch/sessions/{SESSION}"));
    symlink("/nonexistent", folder.join("ready")).unwrap();
    assert_eq!(other.release(HELPER).unwrap_err(), "session already released");
    assert_eq!(fs::read_link(folder.join("ready")).unwrap(), Path::new("/nonexistent"));
    assert_eq!(fs::read_dir(&folder).unwrap().count(), 1);
}

#[test]
fn an_unsafe_home_or_folder_is_refused_with_the_scripts_reason() {
    let home = Home::new();
    fs::set_permissions(&home.0, fs::Permissions::from_mode(0o777)).unwrap();
    assert_eq!(home.release(HELPER).unwrap_err(), "home folder writable by others");
    fs::set_permissions(&home.0, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(release(Some(&home.0), owner() + 1, SESSION, HELPER, 1).unwrap_err(), "home folder writable by others");
    assert_eq!(release(None, owner(), SESSION, HELPER, 1).unwrap_err(), "no home folder");
    assert_eq!(release(Some(Path::new("relative")), owner(), SESSION, HELPER, 1).unwrap_err(), "no home folder");
    assert_eq!(release(Some(&home.0.join("missing")), owner(), SESSION, HELPER, 1).unwrap_err(), "no home folder");

    // A linked .dispatch, even to a private folder of the account, is never entered.
    let elsewhere = home.private("elsewhere");
    symlink(&elsewhere, home.0.join(".dispatch")).unwrap();
    assert_eq!(home.release(HELPER).unwrap_err(), "unsafe folder .dispatch");
    assert_eq!(fs::read_dir(&elsewhere).unwrap().count(), 0);
    fs::remove_file(home.0.join(".dispatch")).unwrap();

    let sessions = home.private(".dispatch/sessions");
    fs::set_permissions(&sessions, fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(home.release(HELPER).unwrap_err(), "unsafe folder sessions");
    fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();

    fs::write(sessions.join(SESSION), b"").unwrap();
    assert_eq!(home.release(HELPER).unwrap_err(), format!("unsafe folder {SESSION}"));
    fs::remove_file(sessions.join(SESSION)).unwrap();

    // A folder that is not private is not entered to make the next one (the script's private_directory first).
    fs::set_permissions(&sessions, fs::Permissions::from_mode(0o500)).unwrap();
    let refused = home.release(HELPER);
    fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(refused.unwrap_err(), "unsafe folder sessions");
    home.release(HELPER).unwrap();
}

#[test]
fn a_pending_file_in_the_way_is_never_written_through() {
    let home = Home::new();
    let folder = home.private(&format!(".dispatch/sessions/{SESSION}"));
    symlink("/nonexistent", folder.join("ready.4242")).unwrap();
    assert_eq!(home.release(HELPER).unwrap_err(), "cannot write the ready file");
    assert!(!folder.join("ready").exists());
    assert!(fs::symlink_metadata(folder.join("ready.4242")).unwrap().file_type().is_symlink(), "not this release's to remove");
}

#[test]
fn only_app_sessions_and_cached_helper_paths_are_accepted() {
    assert!(session(SESSION));
    for bad in ["", "0123456789ABCDEF01234567", "0123456789abcdef0123456", "0123456789abcdef012345678", "../../../../../../../../"] {
        assert!(!session(bad), "{bad}");
    }
    let digest = "a".repeat(64);
    assert!(published(HELPER));
    assert!(published(&format!("dispatch/bin/versions/{digest}/dispatch-helper")));
    for bad in [
        format!("/.dispatch/bin/versions/{digest}/dispatch-helper"),
        format!(".dispatch/bin/versions/{}/dispatch-helper", "A".repeat(64)),
        format!(".dispatch/bin/versions/{}/dispatch-helper", "a".repeat(63)),
        format!(".dispatch/bin/versions/{digest}/../dispatch-helper"),
        format!(".dispatch/bin/versions/{digest}/dispatch-helper\n"),
        "unavailable: setup did not finish".into(),
    ] {
        assert!(!published(&bad), "{bad}");
    }
    // The job refuses what the operation refuses, before touching anything.
    let input = |session: &str, path: &str| {
        crate::wire::body::encode_plain(&Data::Object(vec![("session", Data::String(session)), ("path", Data::String(path))]))
            .unwrap()
    };
    assert_eq!(job(&input("x", HELPER)).unwrap_err().kind(), io::ErrorKind::InvalidInput);
    assert_eq!(job(&input(SESSION, "x")).unwrap_err().kind(), io::ErrorKind::InvalidInput);
}
