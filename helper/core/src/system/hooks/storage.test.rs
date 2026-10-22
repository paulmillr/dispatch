use super::*;
use std::{
    os::unix::fs::DirBuilderExt,
    time::{Duration, SystemTime},
};

#[test]
fn collection_keeps_published_build_after_a_day_without_a_running_helper() {
    let mut nonce = [0; 16];
    super::super::super::random(&mut nonce).unwrap();
    let root =
        std::env::temp_dir().join(format!("dispatch-collect-{:x}", u128::from_ne_bytes(nonce)));
    let versions = root.join("bin/launchers");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&versions)
        .unwrap();
    let published = versions.join("a".repeat(64));
    let unused = versions.join("b".repeat(64));
    let active = versions.join("c".repeat(64));
    for version in [&published, &unused, &active] {
        fs::DirBuilder::new().mode(0o700).create(version).unwrap();
        fs::write(version.join("dispatch-helper"), b"build").unwrap();
    }
    let uid = unsafe { super::super::super::native::getuid() };
    let held = lock(&active.join("lock"), true, false, uid).unwrap();
    let old = SystemTime::now() - Duration::from_secs(2 * 24 * 60 * 60);
    for version in [&published, &unused, &active] {
        for entry in fs::read_dir(version).unwrap() {
            File::open(entry.unwrap().path())
                .unwrap()
                .set_modified(old)
                .unwrap();
        }
        File::open(version).unwrap().set_modified(old).unwrap();
    }
    std::os::unix::fs::symlink(
        published.join("dispatch-helper"),
        root.join("bin/dispatch-helper"),
    )
    .unwrap();
    let guard = collect(&root, uid).unwrap();
    assert!(published.exists());
    assert!(active.exists());
    assert!(!unused.exists());
    drop((guard, held));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn collection_removes_attachments_older_than_a_week_only() {
    let mut nonce = [0; 16];
    super::super::super::random(&mut nonce).unwrap();
    let root = std::env::temp_dir().join(format!("dispatch-attachments-{:x}", u128::from_ne_bytes(nonce)));
    let attachments = root.join("attachments");
    fs::DirBuilder::new().recursive(true).mode(0o700).create(&attachments).unwrap();
    let (old, recent, touched, shared, other) = (
        attachments.join("a".repeat(32)),
        attachments.join("b".repeat(32)),
        attachments.join("c".repeat(32)),
        attachments.join("d".repeat(32)),
        attachments.join("not-a-folder-of-ours"),
    );
    for folder in [&old, &recent, &touched, &shared, &other] {
        fs::DirBuilder::new().mode(0o700).create(folder).unwrap();
        fs::write(folder.join("diagram.png"), b"\x89PNG\r\n\x1a\n").unwrap();
    }
    // A folder another account could read is not ours to judge: kept.
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&shared, fs::Permissions::from_mode(0o755)).unwrap();
    let week = SystemTime::now() - Duration::from_secs(8 * 24 * 60 * 60);
    let days = SystemTime::now() - Duration::from_secs(3 * 24 * 60 * 60);
    for (folder, file, at) in [(&old, week, week), (&recent, days, days), (&touched, week, days), (&shared, week, week), (&other, week, week)] {
        File::open(folder.join("diagram.png")).unwrap().set_modified(file).unwrap();
        File::open(folder).unwrap().set_modified(at).unwrap();
    }
    let uid = unsafe { super::super::super::native::getuid() };
    let guard = collect(&root, uid).unwrap();
    assert!(!old.exists());
    assert!(recent.exists());
    assert!(touched.exists(), "the newest time in the folder counts");
    assert!(shared.exists());
    assert!(other.exists());
    drop(guard);
    fs::remove_dir_all(root).unwrap();
}
