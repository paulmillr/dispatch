//! The program search path of a helper started on a plain SSH exec channel (the iPhone app:
//! `dispatch-helper --remote --capabilities … --stdio`, no `login` wrapper, no login shell).
//! sshd gives such a command only its compiled-in PATH (macOS `/usr/bin:/bin:/usr/sbin:/sbin`),
//! so tmux, herdr and the agents installed by Homebrew, `~/.local/bin` or Nix are not found,
//! neither by the helper nor by the tmux/herdr servers and launches it starts. The Mac app's
//! helper inherits a login shell's PATH from the shell it wraps; this asks the user's login
//! shell once instead, as herdr's own lookup does (multiplexers/herdr/src/availability.rs).
use std::{
    ffi::{OsStr, OsString},
    io::Read,
    os::unix::{ffi::OsStrExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

/// How long the login shell may take; a slow profile only costs the well-known directories.
pub const DEADLINE: Duration = Duration::from_secs(3);

/// Directories package managers install user programs into, appended when they exist and the
/// login shell did not name them (it timed out, failed, or the profile does not add them).
pub fn known(home: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = ["/opt/homebrew/bin", "/usr/local/bin"].map(PathBuf::from).into();
    paths.extend([".local/bin", ".cargo/bin", "bin", ".nix-profile/bin"].map(|part| home.join(part)));
    paths.extend(
        [
            "/home/linuxbrew/.linuxbrew/bin",
            "/nix/var/nix/profiles/default/bin",
            "/run/current-system/sw/bin",
            "/snap/bin",
        ]
        .map(PathBuf::from),
    );
    paths
}

/// The login shell's PATH: `shell -lc` with no input, in `home`, bounded by `deadline`. None
/// when it fails, times out or prints no PATH. Its process group is killed on timeout.
pub fn login(shell: &OsStr, home: &Path, deadline: Duration) -> Option<OsString> {
    environment(shell, home, deadline).map(|(path, _)| path)
}

/// The login shell's PATH and HOME (None when empty), as `login` runs it.
pub fn environment(shell: &OsStr, home: &Path, deadline: Duration) -> Option<(OsString, Option<OsString>)> {
    let mut child = Command::new(shell)
        .args(["-lc", "printf '\\036%s\\037%s\\037' \"$PATH\" \"$HOME\""])
        .current_dir(home)
        // The channel's stdin carries helper frames: a profile that reads must never take them.
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    // A reader thread, so a profile printing more than a pipe buffer cannot stall the wait.
    // It only reads its pipe; it never touches the environment.
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stdout.by_ref().take(1 << 20).read_to_end(&mut bytes);
        bytes
    });
    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if start.elapsed() < deadline => std::thread::sleep(Duration::from_millis(5)),
            _ => break None,
        }
    };
    let Some(status) = status.filter(|status| status.success()) else {
        unsafe extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
        }
        // SAFETY: signals the child's own process group (process_group(0) above).
        unsafe { kill(-(child.id() as i32), 9) };
        let _ = child.wait();
        return None;
    };
    let _ = status;
    // A background job of the profile may keep the pipe open; the PATH was printed already.
    let deadline = start + deadline;
    while !reader.is_finished() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    if !reader.is_finished() {
        return None;
    }
    let bytes = reader.join().ok()?;
    let start = bytes.iter().rposition(|byte| *byte == 0x1e)? + 1;
    let end = start + bytes[start..].iter().position(|byte| *byte == 0x1f)?;
    let path = &bytes[start..end];
    let rest = &bytes[end + 1..];
    let home = rest
        .iter()
        .position(|byte| *byte == 0x1f)
        .map(|stop| &rest[..stop])
        .filter(|home| home.starts_with(b"/"))
        .map(|home| OsStr::from_bytes(home).to_owned());
    (!path.is_empty()).then(|| (OsStr::from_bytes(path).to_owned(), home))
}

/// `login` entries first (the user's order), then `current` entries it lacks, then the `known`
/// directories that exist and are still missing. Empty and relative entries are dropped: a
/// relative entry would search the helper's working directory.
pub fn merge(login: Option<&OsStr>, current: Option<&OsStr>, known: &[PathBuf], exists: &dyn Fn(&Path) -> bool) -> OsString {
    let mut entries: Vec<PathBuf> = Vec::new();
    for path in [login, current].into_iter().flatten() {
        for entry in std::env::split_paths(path) {
            if entry.is_absolute() && !entries.contains(&entry) {
                entries.push(entry);
            }
        }
    }
    for entry in known {
        if !entries.contains(entry) && exists(entry) {
            entries.push(entry.clone());
        }
    }
    std::env::join_paths(entries).unwrap_or_default()
}

/// The PATH this helper and everything it starts should use (`merge` of the login shell's PATH,
/// the current one and the known directories), and the login shell's HOME when it said one.
pub fn resolve(shell: &OsStr, home: &Path, deadline: Duration) -> (OsString, Option<OsString>) {
    let (login, login_home) = environment(shell, home, deadline).unzip();
    let path = merge(login.as_deref(), std::env::var_os("PATH").as_deref(), &known(home), &|path| path.is_dir());
    (path, login_home.flatten())
}

#[cfg(test)]
#[path = "search.test.rs"]
mod tests;
