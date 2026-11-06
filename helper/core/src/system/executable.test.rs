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
        self.release(bytes, None)
    }
    /// Publishes a build stamped with `release`, as an app of that version does.
    fn release(&self, bytes: &[u8], release: Option<&str>) -> PathBuf {
        let bin = self.0.join("bin");
        let _lock =
            native::advisory(&bin.join(".lock"), Instant::now() + Duration::from_secs(30)).unwrap();
        publish(&bin, bytes, release).unwrap();
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
        publish(&scratch.0.join("bin"), b"new", None).unwrap_err().kind(),
        io::ErrorKind::InvalidData
    );
    assert_eq!(fs::read(&stable).unwrap(), b"corrupt");
    fs::remove_file(&target).unwrap();
    let victim = scratch.0.join("victim");
    fs::write(&victim, b"keep").unwrap();
    symlink(&victim, &target).unwrap();
    assert!(publish(&scratch.0.join("bin"), b"new", None).is_err());
    assert_eq!(fs::read(victim).unwrap(), b"keep");
}

#[test]
fn unsafe_build_permissions_are_not_silently_repaired() {
    let scratch = Scratch::new();
    let stable = scratch.publish(b"build");
    fs::set_permissions(&stable, fs::Permissions::from_mode(0o777)).unwrap();
    assert_eq!(
        publish(&scratch.0.join("bin"), b"build", None)
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
    let stable = resolve(&bin, &mut memo, &|| image.read(), None).unwrap();
    assert_eq!(stable, bin.join("dispatch-helper"));
    assert_eq!(image.0.get(), 1);
    let target = stable.canonicalize().unwrap();
    let before = fs::metadata(&target).unwrap();
    assert_eq!(fs::read(&stable).unwrap(), b"mine");
    // Already linked: nothing but a link read.
    assert_eq!(resolve(&bin, &mut memo, &|| image.read(), None).unwrap(), stable);
    assert_eq!(image.0.get(), 1);
    // Another process published its build: ours relinks and reads nothing.
    scratch.publish(b"theirs");
    assert_eq!(fs::read(&stable).unwrap(), b"theirs");
    assert_eq!(resolve(&bin, &mut memo, &|| image.read(), None).unwrap(), stable);
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
    let stable = resolve(&bin, &mut memo, &|| image.read(), None).unwrap();
    let target = stable.canonicalize().unwrap();
    fs::remove_dir_all(target.parent().unwrap()).unwrap();
    assert_eq!(resolve(&bin, &mut memo, &|| image.read(), None).unwrap(), stable);
    assert_eq!(image.0.get(), 2);
    assert_eq!(fs::read(&stable).unwrap(), b"mine");
}

#[test]
fn a_held_link_lock_yields_the_immutable_path_promptly() {
    let scratch = Scratch::new();
    let bin = scratch.0.join("bin");
    let image = Image(std::cell::Cell::new(0), b"mine".to_vec());
    let mut memo = None;
    let stable = resolve(&bin, &mut memo, &|| image.read(), None).unwrap();
    let mine = stable.canonicalize().unwrap();
    scratch.publish(b"theirs");
    let held = native::advisory(&bin.join(".lock"), Instant::now() + Duration::from_secs(30)).unwrap();
    let started = Instant::now();
    let path = resolve(&bin, &mut memo, &|| image.read(), None).unwrap();
    let elapsed = started.elapsed();
    assert!(elapsed >= Duration::from_millis(1900) && elapsed < Duration::from_secs(10), "{elapsed:?}");
    assert_eq!(path.canonicalize().unwrap(), mine);
    assert_eq!(fs::read(&path).unwrap(), b"mine");
    assert_eq!(fs::read(&stable).unwrap(), b"theirs");
    assert_eq!(image.0.get(), 1);
    drop(held);
    assert_eq!(resolve(&bin, &mut memo, &|| image.read(), None).unwrap(), stable);
    assert_eq!(fs::read(&stable).unwrap(), b"mine");
}

#[test]
fn versions_compare_numerically_and_unstamped_builds_are_oldest() {
    assert!(newer(Some("0.1.10"), Some("0.1.9")));
    assert!(newer(Some("1.0"), Some("0.99.99")));
    assert!(!newer(Some("0.1.6"), Some("0.1.6.0")));
    assert!(!newer(Some("0.1.5"), Some("0.1.6")));
    assert!(newer(Some("0.1.5"), None));
    assert!(!newer(None, Some("0.1.5")));
    assert!(!newer(None, None));
    // An unreadable stamp is no stamp: never newer, and anything readable beats it.
    assert!(!newer(Some("1.0-beta"), Some("0.1.5")));
    assert!(newer(Some("0.0.1"), Some("x")));
    assert!(!newer(Some("1.2.3.4.5"), None));
}

#[test]
fn an_older_version_never_takes_the_link_from_a_newer_one() {
    // Another device's newer app published first; an older app connecting later stores its build
    // (its running helper and anything it launched directly still use it) but leaves the link.
    let scratch = Scratch::new();
    let stable = scratch.release(b"new", Some("0.1.7"));
    let newest = stable.canonicalize().unwrap();
    assert_eq!(fs::read_to_string(newest.with_file_name("release")).unwrap(), "0.1.7\n");
    scratch.release(b"old", Some("0.1.6"));
    assert_eq!(stable.canonicalize().unwrap(), newest);
    // An unstamped build (an app from before stamps) yields too.
    scratch.publish(b"legacy");
    assert_eq!(stable.canonicalize().unwrap(), newest);
    assert_eq!(fs::read_dir(scratch.0.join("bin/launchers")).unwrap().count(), 3);
    // A newer one still takes over, and the same version relinks as before: the last one wins.
    scratch.release(b"newer", Some("0.2"));
    assert_eq!(fs::read(&stable).unwrap(), b"newer");
    scratch.release(b"rebuilt", Some("0.2.0"));
    assert_eq!(fs::read(&stable).unwrap(), b"rebuilt");
    scratch.release(b"newer", Some("0.2"));
    assert_eq!(fs::read(&stable).unwrap(), b"newer");
}

#[test]
fn a_stamped_build_replaces_an_unstamped_link() {
    let scratch = Scratch::new();
    let stable = scratch.publish(b"legacy");
    assert!(!stable.canonicalize().unwrap().with_file_name("release").exists());
    scratch.release(b"stamped", Some("0.1.6"));
    assert_eq!(fs::read(&stable).unwrap(), b"stamped");
    // A link that names no published build (a legacy copy, a foreign target) is always replaced.
    let foreign = scratch.0.join("foreign");
    fs::write(&foreign, b"foreign").unwrap();
    let bin = scratch.0.join("bin");
    fs::remove_file(bin.join("dispatch-helper")).unwrap();
    symlink(&foreign, bin.join("dispatch-helper")).unwrap();
    scratch.release(b"old", Some("0.0.1"));
    assert_eq!(fs::read(&stable).unwrap(), b"old");
}

#[test]
fn a_known_older_build_keeps_the_newer_link_and_still_returns_the_stable_path() {
    let scratch = Scratch::new();
    let bin = scratch.0.join("bin");
    let image = Image(std::cell::Cell::new(0), b"old".to_vec());
    let mut memo = None;
    let stable = resolve(&bin, &mut memo, &|| image.read(), Some("0.1.6")).unwrap();
    assert_eq!(fs::read(&stable).unwrap(), b"old");
    scratch.release(b"new", Some("0.1.7"));
    // The stable path, which runs the newer build, without relinking or reading the image again.
    assert_eq!(resolve(&bin, &mut memo, &|| image.read(), Some("0.1.6")).unwrap(), stable);
    assert_eq!(fs::read(&stable).unwrap(), b"new");
    assert_eq!(image.0.get(), 1);
    // Once the newer build's link is gone (say, removed by hand), the older one links again.
    fs::remove_file(&stable).unwrap();
    assert_eq!(resolve(&bin, &mut memo, &|| image.read(), Some("0.1.6")).unwrap(), stable);
    assert_eq!(fs::read(&stable).unwrap(), b"old");
}
