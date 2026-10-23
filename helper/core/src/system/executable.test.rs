use super::*;
use std::os::unix::{fs::PermissionsExt, process::CommandExt};

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        let mut nonce = [0; 16];
        super::super::random(&mut nonce).unwrap();
        let path = std::env::temp_dir().join(format!(
            "dispatch-executable-{:x}",
            u128::from_ne_bytes(nonce)
        ));
        directory(&path).unwrap();
        directory(&path.join("bin")).unwrap();
        Self(path)
    }
    fn publish(&self, bytes: &[u8]) -> PathBuf {
        let bin = self.0.join("bin");
        let _lock =
            native::advisory(&bin.join(".lock"), Instant::now() + Duration::from_secs(30)).unwrap();
        publish(&bin, bytes).unwrap();
        bin.join("dispatch-helper")
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn upgrades_and_downgrades_keep_immutable_builds_and_stable_command() {
    let scratch = Scratch::new();
    let stable = scratch.publish(b"first");
    let first = stable.canonicalize().unwrap();
    let inode = fs::metadata(&first).unwrap().ino();
    assert!(fs::read_link(&stable).unwrap().is_relative());
    assert_eq!(fs::metadata(&first).unwrap().mode() & 0o777, 0o700);
    scratch.publish(b"second");
    let second = stable.canonicalize().unwrap();
    assert_ne!(first, second);
    assert_eq!(fs::read(&first).unwrap(), b"first");
    scratch.publish(b"first");
    assert_eq!(stable.canonicalize().unwrap(), first);
    assert_eq!(fs::metadata(&first).unwrap().ino(), inode);
    assert_eq!(fs::read(second).unwrap(), b"second");
    assert_eq!(fs::read_dir(scratch.0.join("bin")).unwrap().count(), 3);
}

#[test]
fn migration_replaces_legacy_file_and_refuses_corrupt_immutable_build() {
    let scratch = Scratch::new();
    let stable = scratch.0.join("bin/dispatch-helper");
    fs::write(&stable, b"legacy").unwrap();
    scratch.publish(b"new");
    let target = stable.canonicalize().unwrap();
    fs::write(&target, b"corrupt").unwrap();
    assert_eq!(
        publish(&scratch.0.join("bin"), b"new").unwrap_err().kind(),
        io::ErrorKind::InvalidData
    );
    assert_eq!(fs::read(&stable).unwrap(), b"corrupt");
    fs::remove_file(&target).unwrap();
    let victim = scratch.0.join("victim");
    fs::write(&victim, b"keep").unwrap();
    symlink(&victim, &target).unwrap();
    assert!(publish(&scratch.0.join("bin"), b"new").is_err());
    assert_eq!(fs::read(victim).unwrap(), b"keep");
}

#[test]
fn unsafe_build_permissions_are_not_silently_repaired() {
    let scratch = Scratch::new();
    let stable = scratch.publish(b"build");
    fs::set_permissions(&stable, fs::Permissions::from_mode(0o777)).unwrap();
    assert_eq!(
        publish(&scratch.0.join("bin"), b"build")
            .unwrap_err()
            .kind(),
        io::ErrorKind::PermissionDenied
    );
}

#[test]
fn concurrent_publishers_leave_all_builds_intact() {
    let scratch = Scratch::new();
    std::thread::scope(|scope| {
        for build in [b"first".as_slice(), b"second".as_slice()] {
            let scratch = &scratch;
            scope.spawn(move || {
                for _ in 0..8 {
                    scratch.publish(build);
                }
            });
        }
    });
    let stable = scratch.0.join("bin/dispatch-helper");
    assert!(
        [b"first".as_slice(), b"second".as_slice()].contains(&fs::read(stable).unwrap().as_slice())
    );
    assert_eq!(
        fs::read_dir(scratch.0.join("bin/launchers"))
            .unwrap()
            .count(),
        2
    );
}

#[test]
fn publishing_does_not_change_a_running_launchers_identity() {
    let scratch = Scratch::new();
    let stable = scratch.publish(&fs::read("/bin/sh").unwrap());
    let mut child = std::process::Command::new(&stable)
        .arg0("sh")
        .args(["-c", "read value"])
        .stdin(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let result = || {
        let before = inspect::process(child.id()).unwrap();
        scratch.publish(b"next build");
        let after = inspect::process(child.id()).unwrap();
        assert_eq!(before.executable, after.executable);
        assert_eq!(before.start, after.start);
        assert!(after.executable.exists());
    };
    // Always reap even when the assertion fails.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(result));
    let _ = child.kill();
    let _ = child.wait();
    result.unwrap();
}

#[test]
#[cfg(target_os = "linux")]
fn a_replaced_legacy_path_still_reads_the_running_image() {
    let scratch = Scratch::new();
    let stable = scratch.0.join("bin/dispatch-helper");
    let bytes = fs::read("/bin/sh").unwrap();
    fs::write(&stable, &bytes).unwrap();
    fs::set_permissions(&stable, fs::Permissions::from_mode(0o700)).unwrap();
    let mut child = std::process::Command::new(&stable)
        .arg0("sh")
        .args(["-c", "read value"])
        .stdin(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        scratch.publish(b"replacement");
        let process = inspect::process(child.id()).unwrap();
        assert!(process.executable.to_string_lossy().ends_with(" (deleted)"));
        let mut image = inspect::executable(child.id(), &process.executable).unwrap();
        let mut read = Vec::new();
        image.read_to_end(&mut read).unwrap();
        assert_eq!(read, bytes);
    }));
    let _ = child.kill();
    let _ = child.wait();
    result.unwrap();
}

/// A build's image, counting how often resolve asked for it.
struct Image(std::cell::Cell<usize>, Vec<u8>);
impl Image {
    fn read(&self) -> io::Result<Vec<u8>> {
        self.0.set(self.0.get() + 1);
        Ok(self.1.clone())
    }
}

#[test]
fn a_known_build_relinks_without_reading_hashing_or_rewriting_its_image() {
    let scratch = Scratch::new();
    let bin = scratch.0.join("bin");
    let image = Image(std::cell::Cell::new(0), b"mine".to_vec());
    let mut memo = None;
    let stable = resolve(&bin, &mut memo, &|| image.read()).unwrap();
    assert_eq!(stable, bin.join("dispatch-helper"));
    assert_eq!(image.0.get(), 1);
    let target = stable.canonicalize().unwrap();
    let before = fs::metadata(&target).unwrap();
    assert_eq!(fs::read(&stable).unwrap(), b"mine");
    // Already linked: nothing but a link read.
    assert_eq!(resolve(&bin, &mut memo, &|| image.read()).unwrap(), stable);
    assert_eq!(image.0.get(), 1);
    // Another process published its build: ours relinks and reads nothing.
    scratch.publish(b"theirs");
    assert_eq!(fs::read(&stable).unwrap(), b"theirs");
    assert_eq!(resolve(&bin, &mut memo, &|| image.read()).unwrap(), stable);
    assert_eq!(image.0.get(), 1);
    assert_eq!(fs::read(&stable).unwrap(), b"mine");
    assert_eq!(stable.canonicalize().unwrap(), target);
    let after = fs::metadata(&target).unwrap();
    assert_eq!((before.ino(), before.mtime(), before.mtime_nsec()), (after.ino(), after.mtime(), after.mtime_nsec()));
    assert_eq!(fs::read_dir(bin.join("launchers")).unwrap().count(), 2);
}

#[test]
fn a_collected_build_is_published_again() {
    let scratch = Scratch::new();
    let bin = scratch.0.join("bin");
    let image = Image(std::cell::Cell::new(0), b"mine".to_vec());
    let mut memo = None;
    let stable = resolve(&bin, &mut memo, &|| image.read()).unwrap();
    let target = stable.canonicalize().unwrap();
    fs::remove_dir_all(target.parent().unwrap()).unwrap();
    assert_eq!(resolve(&bin, &mut memo, &|| image.read()).unwrap(), stable);
    assert_eq!(image.0.get(), 2);
    assert_eq!(fs::read(&stable).unwrap(), b"mine");
}

#[test]
fn a_held_link_lock_yields_the_immutable_path_promptly() {
    let scratch = Scratch::new();
    let bin = scratch.0.join("bin");
    let image = Image(std::cell::Cell::new(0), b"mine".to_vec());
    let mut memo = None;
    let stable = resolve(&bin, &mut memo, &|| image.read()).unwrap();
    let mine = stable.canonicalize().unwrap();
    scratch.publish(b"theirs");
    let held = native::advisory(&bin.join(".lock"), Instant::now() + Duration::from_secs(30)).unwrap();
    let started = Instant::now();
    let path = resolve(&bin, &mut memo, &|| image.read()).unwrap();
    let elapsed = started.elapsed();
    assert!(elapsed >= Duration::from_millis(1900) && elapsed < Duration::from_secs(10), "{elapsed:?}");
    assert_eq!(path.canonicalize().unwrap(), mine);
    assert_eq!(fs::read(&path).unwrap(), b"mine");
    assert_eq!(fs::read(&stable).unwrap(), b"theirs");
    assert_eq!(image.0.get(), 1);
    drop(held);
    assert_eq!(resolve(&bin, &mut memo, &|| image.read()).unwrap(), stable);
    assert_eq!(fs::read(&stable).unwrap(), b"mine");
}
