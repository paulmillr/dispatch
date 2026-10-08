//! helper2 runtime.rs private endpoint collection; only System touches storage.
use std::{
    ffi::CString,
    fs::{self, File},
    io,
    os::{
        fd::AsRawFd,
        unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt},
    },
    path::Path,
};

use super::super::native::{O_CLOEXEC, O_DIRECTORY, O_NOFOLLOW, O_NONBLOCK};

const FLAGS: i32 = O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
const DIRECTORY: i32 = O_DIRECTORY;
unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
    fn unlinkat(fd: i32, path: *const std::ffi::c_char, flags: i32) -> i32;
}

pub(super) fn lock(path: &Path, create: bool, wait: bool, uid: u32) -> io::Result<File> {
    let file = super::super::native::lock(path, create, uid)?;
    loop {
        // SAFETY: exclusively held file; LOCK_EX plus LOCK_NB when collecting stale runs.
        if unsafe { flock(file.as_raw_fd(), 2 | if wait { 0 } else { 4 }) } == 0 {
            return Ok(file);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}
pub(super) fn same(path: &Path, anchor: &File) -> bool {
    fs::symlink_metadata(path)
        .and_then(|path| {
            anchor
                .metadata()
                .map(|anchor| path.dev() == anchor.dev() && path.ino() == anchor.ino())
        })
        .unwrap_or(false)
}
pub(super) fn remove(anchor: &File, name: &str) -> io::Result<()> {
    let name = CString::new(name).map_err(|_| io::ErrorKind::InvalidInput)?;
    // SAFETY: callers supply one known single component beneath their pinned private run.
    if unsafe { unlinkat(anchor.as_raw_fd(), name.as_ptr(), 0) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::NotFound {
        Ok(())
    } else {
        Err(error)
    }
}
/// A day: sessions and builds used more recently than this are kept even when unlocked, so a
/// login waiting for its hand-off, an unread exit status, or a build about to be reused stays.
const RECENT: std::time::Duration = std::time::Duration::from_secs(24 * 60 * 60);

/// Up to 1024 entries of `directory` whose names are `length` lowercase hex digits.
fn entries(directory: &Path, length: usize) -> Vec<std::path::PathBuf> {
    fs::read_dir(directory)
        .into_iter()
        .flatten()
        .take(1024)
        .flatten()
        .filter(|entry| {
            entry.file_name().to_str().is_some_and(|name| {
                name.len() == length && name.bytes().all(|c| matches!(c, b'0'..=b'9' | b'a'..=b'f'))
            })
        })
        .map(|entry| entry.path())
        .collect()
}

/// Hold `parent/lock` through new-run creation and remove what no running helper holds: run
/// directories, SSH session directories, and uploaded builds. Active, recent, unknown or unsafe
/// storage is retained.
pub(super) fn collect(parent: &Path, uid: u32) -> io::Result<File> {
    let guard = lock(&parent.join("lock"), true, true, uid)?;
    for path in entries(&parent.join("run"), 32) {
        let _ = run(&path, uid);
    }
    for path in entries(&parent.join("sessions"), 24)
        .into_iter()
        .chain(entries(&parent.join("bin").join("versions"), 64))
    {
        let _ = unused(&path, uid);
    }
    Ok(guard)
}

/// A run directory whose helper is gone: its sockets, shell startup folders, and lock.
fn run(path: &Path, uid: u32) -> io::Result<()> {
    let anchor = File::options()
        .read(true)
        .custom_flags(FLAGS | DIRECTORY)
        .open(path)?;
    let m = anchor.metadata()?;
    if !m.is_dir() || m.uid() != uid || m.mode() & 0o077 != 0 {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let owner = match lock(&path.join("lock"), false, false, uid) {
        Ok(owner) => owner,
        Err(e) if e.kind() == io::ErrorKind::NotFound && fs::read_dir(path)?.next().is_none() => {
            if same(path, &anchor) {
                fs::remove_dir(path)?;
            }
            return Ok(());
        }
        Err(e) => return Err(e),
    };
    let (mut sockets, mut startups) = (Vec::new(), Vec::new());
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_str().ok_or(io::ErrorKind::InvalidData)?;
        if name == "lock" {
            continue;
        }
        let m = entry.path().symlink_metadata()?;
        let number = |id: &str| id.parse::<u64>().is_ok_and(|n| n.to_string() == id);
        let socket = name
            .rsplit_once('.')
            .is_some_and(|(id, kind)| matches!(kind, "d" | "s") && number(id))
            && m.file_type().is_socket();
        let startup = name.strip_prefix("startup-").is_some_and(number) && m.is_dir();
        if !(socket || startup)
            || m.uid() != uid
            || m.mode() & 0o077 != 0
            || sockets.len() + startups.len() == 512
        {
            return Err(io::ErrorKind::InvalidData.into());
        }
        if socket { &mut sockets } else { &mut startups }.push(name.to_owned());
    }
    // Validate the whole directory first. Never remove unknown entries or a live run.
    if !same(path, &anchor) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    for name in sockets {
        remove(&anchor, &name)?;
    }
    // Startup folders hold only the generated shell files; removal never follows links.
    for name in startups {
        fs::remove_dir_all(path.join(name))?;
    }
    remove(&anchor, "lock")?;
    if same(path, &anchor) {
        fs::remove_dir(path)?;
    }
    drop(owner);
    Ok(())
}

/// A session or build directory that nothing changed for RECENT and no running helper locks.
fn unused(path: &Path, uid: u32) -> io::Result<()> {
    let anchor = File::options()
        .read(true)
        .custom_flags(FLAGS | DIRECTORY)
        .open(path)?;
    let m = anchor.metadata()?;
    if !m.is_dir() || m.uid() != uid || m.mode() & 0o077 != 0 {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let mut newest = m.modified()?;
    for entry in fs::read_dir(path)? {
        newest = newest.max(entry?.path().symlink_metadata()?.modified()?);
    }
    if newest.elapsed().map_or(true, |age| age < RECENT) {
        return Ok(());
    }
    let owner = match lock(&path.join("lock"), false, false, uid) {
        Ok(owner) => Some(owner),
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(e),
    };
    if !same(path, &anchor) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    // Never follows links; the folder holds only what Dispatch put there.
    fs::remove_dir_all(path)?;
    drop(owner);
    Ok(())
}

/// When this executable is an uploaded build (`bin/versions/<sha256>/dispatch-helper`), hold a
/// shared lock on its `lock` for the helper's lifetime and date it, so `collect` keeps it.
pub(super) fn version(parent: &Path, uid: u32) -> Option<File> {
    let executable = std::env::current_exe().ok()?.canonicalize().ok()?;
    let directory = executable.parent()?;
    let versions = parent.join("bin").join("versions").canonicalize().ok()?;
    let digest = directory.file_name()?.to_str()?;
    if executable.file_name()? != "dispatch-helper"
        || directory.parent()? != versions
        || digest.len() != 64
        || !digest.bytes().all(|c| matches!(c, b'0'..=b'9' | b'a'..=b'f'))
    {
        return None;
    }
    let file = super::super::native::lock(&directory.join("lock"), true, uid).ok()?;
    // SAFETY: owned descriptor; LOCK_SH | LOCK_NB. A collector holding it is deleting this
    // folder, which the running executable survives.
    if unsafe { flock(file.as_raw_fd(), 1 | 4) } != 0 {
        return None;
    }
    let _ = file.set_modified(std::time::SystemTime::now());
    Some(file)
}
