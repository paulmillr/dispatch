//! Retirement (System::drop) gives hung-up terminal shells a moment to exit on their own.
use super::*;
use crate::api::{Grid, Io};

fn scratch(name: &str) -> PathBuf {
    let mut nonce = [0; 8];
    super::random(&mut nonce).unwrap();
    std::env::temp_dir().join(format!("dispatch-retire-{name}-{:x}", u64::from_ne_bytes(nonce)))
}

fn alive(pid: u32) -> bool {
    unsafe extern "C" {
        fn kill(pid: i32, signal: i32) -> i32;
    }
    // SAFETY: signal 0 probes existence only.
    unsafe { kill(pid as i32, 0) == 0 }
}

fn spawn(system: &mut System, script: &str) -> u32 {
    let mut command = Command::new("/bin/sh");
    command.args(["-c", script]);
    let grid = Grid {
        columns: 80,
        rows: 24,
        pixels: None,
    };
    system.spawn(command, Some(grid)).unwrap().pid
}

#[test]
fn retirement_lets_a_hung_up_shell_finish_its_exit_work() {
    let marker = scratch("marker");
    let mut system = System::new(1, 16).unwrap();
    let pid = spawn(
        &mut system,
        &format!("trap 'sleep 0.3; : > {}; exit 0' HUP; while :; do sleep 1; done", marker.display()),
    );
    // The trap must be installed before the hangup arrives.
    std::thread::sleep(Duration::from_millis(300));
    let started = Instant::now();
    drop(system);
    let elapsed = started.elapsed();
    assert!(marker.exists(), "shell was killed before its hangup work finished ({elapsed:?})");
    assert!(!alive(pid), "shell {pid} outlived retirement");
    assert!(elapsed < RETIREMENT_GRACE + Duration::from_millis(300), "{elapsed:?}");
    let _ = std::fs::remove_file(&marker);
}

#[test]
fn retirement_still_ends_a_shell_that_ignores_hangup_within_its_grace() {
    let mut system = System::new(1, 16).unwrap();
    let pid = spawn(&mut system, "trap '' HUP; while :; do sleep 1; done");
    std::thread::sleep(Duration::from_millis(300));
    let started = Instant::now();
    drop(system);
    let elapsed = started.elapsed();
    assert!(!alive(pid), "shell {pid} outlived retirement");
    assert!(elapsed >= RETIREMENT_GRACE, "{elapsed:?}");
    assert!(elapsed < Duration::from_secs(1), "{elapsed:?}");
}
