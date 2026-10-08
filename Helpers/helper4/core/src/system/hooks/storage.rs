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
/// Hold the parent lock through new-run creation; active/unknown/unsafe storage is retained.
pub(super) fn collect(parent: &Path, uid: u32) -> io::Result<File> {
    let guard = lock(&parent.join("lock"), true, true, uid)?;
    for (index, entry) in fs::read_dir(parent)?.enumerate() {
        if index == 1024 {
            return Err(io::ErrorKind::InvalidData.into());
        }
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let valid = name
            .strip_prefix("run-")
            .and_then(|s| match s.split_once('-') {
                Some((pid, random)) => pid.parse::<u32>().is_ok_and(|p| p.to_string() == pid).then_some(random),
                None => Some(s),
            })
            .is_some_and(|random| {
                random.len() == 32 && random.bytes().all(|c| c.is_ascii_hexdigit())
            });
        if !valid {
            continue;
        }
        let path = entry.path();
        let _ = (|| -> io::Result<()> {
            let anchor = File::options()
                .read(true)
                .custom_flags(FLAGS | DIRECTORY)
                .open(&path)?;
            let m = anchor.metadata()?;
            if !m.is_dir() || m.uid() != uid || m.mode() & 0o077 != 0 {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            let owner = match lock(&path.join("lock"), false, false, uid) {
                Ok(owner) => owner,
                Err(e)
                    if e.kind() == io::ErrorKind::NotFound
                        && fs::read_dir(&path)?.next().is_none() =>
                {
                    if same(&path, &anchor) {
                        fs::remove_dir(&path)?;
                    }
                    return Ok(());
                }
                Err(e) => return Err(e),
            };
            let mut names = Vec::new();
            for entry in fs::read_dir(&path)? {
                let entry = entry?;
                let name = entry.file_name();
                let name = name.to_str().ok_or(io::ErrorKind::InvalidData)?;
                if name == "lock" {
                    continue;
                }
                let valid = name.rsplit_once('.').is_some_and(|(id, kind)| {
                    matches!(kind, "d" | "s")
                        && id.parse::<u64>().is_ok_and(|n| n.to_string() == id)
                });
                let m = entry.path().symlink_metadata()?;
                if !valid
                    || !m.file_type().is_socket()
                    || m.uid() != uid
                    || m.mode() & 0o077 != 0
                    || names.len() == 256
                {
                    return Err(io::ErrorKind::InvalidData.into());
                }
                names.push(name.to_owned());
            }
            // Validate the whole directory first. Never remove unknown entries or a live run.
            if !same(&path, &anchor) {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            for name in names {
                remove(&anchor, &name)?;
            }
            remove(&anchor, "lock")?;
            if same(&path, &anchor) {
                fs::remove_dir(&path)?;
            }
            drop(owner);
            Ok(())
        })();
    }
    Ok(guard)
}
