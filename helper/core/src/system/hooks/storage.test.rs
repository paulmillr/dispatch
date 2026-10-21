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
