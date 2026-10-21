use super::*;

fn arguments(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}

#[test]
fn plain_interactive_shells_and_the_helpers_own_bash_startup_count_as_idle_shells() {
    assert!(interactive(Some("zsh"), &arguments(&["-zsh"])));
    assert!(interactive(Some("zsh"), &arguments(&["zsh", "-l"])));
    assert!(interactive(Some("bash"), &arguments(&["bash", "--posix", "-il"])));
    // macOS /bin/bash 3.2 under the helper's startup (BASH_LAUNCH): `exec -a sh bash --noprofile -il`.
    assert!(interactive(Some("bash"), &arguments(&["sh", "--noprofile", "-il"])));
}

#[test]
fn shells_running_a_command_or_other_options_are_not_idle_shells() {
    assert!(!interactive(Some("bash"), &[]));
    assert!(!interactive(Some("bash"), &arguments(&["bash", "-c", "sleep 9"])));
    assert!(!interactive(Some("bash"), &arguments(&["bash", "script.sh"])));
    assert!(!interactive(Some("zsh"), &arguments(&["zsh", "--noprofile", "-il"])));
    assert!(!interactive(Some("bash"), &arguments(&["bash", "--rcfile", "x", "-i"])));
}

/// A shell made the session leader of a fresh pty: the tty-scoped listing names the same
/// foreground members as the full process walk did, and the shell is among them.
#[cfg(target_os = "macos")]
#[test]
fn foreground_lists_a_ptys_shell_from_its_own_tty_only() {
    use std::os::unix::{fs::MetadataExt, process::CommandExt};
    let (master, slave) = os::pty(
        crate::api::Grid { columns: 80, rows: 24, pixels: None },
        None,
    )
    .unwrap();
    let tty = slave.metadata().unwrap().rdev();
    let mut command = std::process::Command::new("/bin/sh");
    command
        .args(["-c", "sleep 30; exit 0"])
        .stdin(slave.try_clone().unwrap())
        .stdout(slave.try_clone().unwrap())
        .stderr(slave.try_clone().unwrap());
    // SAFETY: setsid + TIOCSCTTY on fd 0, async-signal-safe, like a helper-spawned shell.
    unsafe { command.pre_exec(os::session) };
    let mut child = command.spawn().unwrap();
    drop(slave);
    let pid = child.id();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let (group, members) = loop {
        match foreground(tty) {
            Ok(found) if found.1.iter().any(|p| p.pid == pid) => break found,
            Ok(_) | Err(_) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            Ok(found) => panic!("shell {pid} missing from foreground members {found:?}"),
            Err(error) => panic!("foreground: {error}"),
        }
    };
    assert_eq!(group, pid as i32, "the session leader's group is the foreground group");
    assert!(members.iter().all(|p| p.tty == tty && p.group == group));
    // The tty-scoped candidates agree with the full walk on which pids sit on this tty.
    let scoped: std::collections::BTreeSet<u32> = candidates(tty)
        .unwrap()
        .into_iter()
        .filter(|&p| snapshot(p).is_ok_and(|s| s.tty == tty))
        .collect();
    let full: std::collections::BTreeSet<u32> = darwin::every_pid()
        .unwrap()
        .into_iter()
        .filter(|&p| snapshot(p).is_ok_and(|s| s.tty == tty))
        .collect();
    assert_eq!(scoped, full);
    assert!(scoped.contains(&pid));
    let _ = child.kill();
    let _ = child.wait();
    drop(master);
}
