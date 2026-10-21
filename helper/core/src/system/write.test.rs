use super::*;
use crate::api::Guard;
use std::fs;

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        use std::sync::atomic::{AtomicU64, Ordering};
        static SERIAL: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "dispatch-write-{}-{}",
            std::process::id(),
            SERIAL.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn revision(path: &Path) -> Expected {
    Expected::Same(Guard::from(metadata(fs::metadata(path).unwrap())))
}

fn write(path: &Path, expected: Expected) -> io::Result<Output> {
    execute(Job::Write {
        path: path.into(),
        bytes: b"{\"hooks\":{}}\n".to_vec(),
        mode: 0o600,
        expected,
        parent: None,
    })
}

#[test]
fn checked_write_updates_existing_agent_settings_and_preserves_permissions() {
    let scratch = Scratch::new();
    for name in ["hooks.json", "settings.json"] {
        let path = scratch.0.join(name);
        fs::write(&path, b"{}\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        let gid = fs::metadata(&path).unwrap().gid();
        for _ in 0..2 {
            assert!(matches!(
                write(&path, revision(&path)).unwrap(),
                Output::Written
            ));
            assert_eq!(fs::read(&path).unwrap(), b"{\"hooks\":{}}\n");
            let current = fs::metadata(&path).unwrap();
            assert_eq!(current.mode() & 0o777, 0o640);
            assert_eq!(current.gid(), gid);
        }
    }
    assert_eq!(fs::read_dir(&scratch.0).unwrap().count(), 2);
}

#[test]
fn checked_write_creates_absent_settings_and_refuses_an_existing_file() {
    let scratch = Scratch::new();
    let path = scratch.0.join("hooks.json");
    write(&path, Expected::Absent).unwrap();
    assert_eq!(
        write(&path, Expected::Absent).unwrap_err().kind(),
        io::ErrorKind::AlreadyExists
    );
    assert_eq!(fs::read_dir(&scratch.0).unwrap().count(), 1);
}

#[test]
fn checked_write_accepts_a_partial_revision() {
    let scratch = Scratch::new();
    let path = scratch.0.join("settings.json");
    fs::write(&path, b"{}\n").unwrap();
    let expected = Expected::Same(Guard {
        inode: Some(fs::metadata(&path).unwrap().ino()),
        ..Guard::default()
    });
    write(&path, expected).unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"{\"hooks\":{}}\n");
}

#[test]
fn checked_write_refuses_a_symlink_replacement() {
    let scratch = Scratch::new();
    let path = scratch.0.join("settings.json");
    let target = scratch.0.join("target.json");
    fs::write(&path, b"{}\n").unwrap();
    fs::write(&target, b"{\"other\":true}\n").unwrap();
    let expected = revision(&path);
    fs::remove_file(&path).unwrap();
    std::os::unix::fs::symlink(&target, &path).unwrap();
    assert!(write(&path, expected).is_err());
    assert!(
        fs::symlink_metadata(&path)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(fs::read(&target).unwrap(), b"{\"other\":true}\n");
    assert_eq!(fs::read_dir(&scratch.0).unwrap().count(), 2);
}

#[test]
fn checked_write_rejects_changes_including_ctime_only_changes() {
    let scratch = Scratch::new();
    let path = scratch.0.join("settings.json");
    for change in ["content", "permissions", "replacement"] {
        fs::write(&path, b"{}\n").unwrap();
        let expected = revision(&path);
        match change {
            "content" => fs::write(&path, b"{\"other\":true}\n").unwrap(),
            "permissions" => {
                let before = fs::metadata(&path).unwrap();
                fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
                let after = fs::metadata(&path).unwrap();
                assert_eq!(before.mtime(), after.mtime());
                assert_eq!(before.mtime_nsec(), after.mtime_nsec());
                assert_ne!(metadata(before).changed_ns, metadata(after).changed_ns);
            }
            _ => {
                fs::rename(&path, scratch.0.join("original")).unwrap();
                fs::write(&path, b"{}\n").unwrap();
            }
        }
        let bytes = fs::read(&path).unwrap();
        assert_eq!(
            write(&path, expected).unwrap_err().kind(),
            io::ErrorKind::StaleNetworkFileHandle,
            "{change}"
        );
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
}
