//! Stable hook commands point to immutable builds. Publishing another build never unlinks
//! an executable that a launcher, hook, or older connected helper is still running.
//!
//! Every app that sets up a host (the Mac app, the iPhone app, on any number of devices) publishes
//! its own helper build there, and the stable link goes to the newest Dispatch version among them:
//! a build stamped with an older version than the linked one's (`launchers/<sha256>/release`)
//! leaves the link alone, so hooks, shell startup files, the queue drainer and `uninstall` always
//! run the newest helper, which understands what older helpers wrote. Builds of the same version
//! relink as they always did (the last one wins), and a build without a stamp, from an older app or
//! built outside scripts/build-ssh-helper.py, counts as older than every stamped one.
use super::{hooks, inspect, native};
use std::{
    fs,
    io::{self, Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, symlink},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

fn directory(path: &Path) -> io::Result<()> {
    match fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let m = fs::symlink_metadata(path)?;
    if !m.is_dir() || m.uid() != unsafe { native::getuid() } || m.mode() & 0o077 != 0 {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(())
}

/// A build published by this process: the bin directory it went to and its digest. Every later
/// call needs the link alone, never the image again (reading, hashing and comparing a helper
/// binary inline on the reactor stalls every tab while two builds relink past each other).
static BUILD: std::sync::Mutex<Option<(PathBuf, String)>> = std::sync::Mutex::new(None);

/// A first publication waits for collectors and other publishers; a relink of a known build
/// only briefly, since an immutable path serves the caller meanwhile.
const FULL: Duration = Duration::from_secs(30);
const SHORT: Duration = Duration::from_secs(2);

/// This build's Dispatch version, `MARKETING_VERSION` in project.yml, which every app shares
/// (scripts/build-ssh-helper.py sets it).
const RELEASE: Option<&str> = option_env!("DISPATCH_HELPER_RELEASE");

/// A version's numeric components, as the Mac updater reads them (Dispatch/Updates/UpdateRelease.swift):
/// one to four dot-separated runs of at most nine digits.
fn components(version: &str) -> Option<Vec<u64>> {
    let parts: Vec<&str> = version.split('.').collect();
    if !(1..=4).contains(&parts.len())
        || !parts.iter().all(|part| !part.is_empty() && part.len() <= 9 && part.bytes().all(|b| b.is_ascii_digit()))
    {
        return None;
    }
    parts.iter().map(|part| part.parse().ok()).collect()
}

/// Whether a build stamped `theirs` is newer than one stamped `ours`. Missing or unreadable
/// stamps are older than any readable one; components missing at the end count as zeros.
fn newer(theirs: Option<&str>, ours: Option<&str>) -> bool {
    match (theirs.and_then(components), ours.and_then(components)) {
        (Some(mut theirs), Some(mut ours)) => {
            let length = theirs.len().max(ours.len());
            theirs.resize(length, 0);
            ours.resize(length, 0);
            theirs > ours
        }
        (theirs, ours) => theirs.is_some() && ours.is_none(),
    }
}

/// The stamp next to the build `bin/dispatch-helper` links to; `Err` when the link names no
/// published build (missing, a legacy copy, a foreign target), which any build may replace.
fn linked(bin: &Path) -> Result<Option<String>, ()> {
    let target = fs::read_link(bin.join("dispatch-helper")).map_err(drop)?;
    let mut parts = target.components().map(|part| part.as_os_str().to_str());
    let digest = match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some(Some("launchers")), Some(Some(digest)), Some(Some("dispatch-helper")), None) => digest,
        _ => return Err(()),
    };
    if digest.len() != 64 || !digest.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
        return Err(());
    }
    let folder = bin.join("launchers").join(digest);
    if !fs::symlink_metadata(folder.join("dispatch-helper")).is_ok_and(|m| m.is_file()) {
        return Err(());
    }
    Ok(read_stamp(&folder))
}

fn read_stamp(folder: &Path) -> Option<String> {
    let file = fs::File::open(folder.join("release")).ok()?;
    let mut text = String::new();
    file.take(64).read_to_string(&mut text).ok()?;
    Some(text.trim_end_matches('\n').to_owned())
}

/// Whether the link already names a build newer than `release`, which this build leaves linked.
fn yields(bin: &Path, release: Option<&str>) -> bool {
    linked(bin).is_ok_and(|theirs| newer(theirs.as_deref(), release))
}

fn bins() -> io::Result<PathBuf> {
    let base = hooks::base()?;
    directory(&base)?;
    let bin = base.join("bin");
    directory(&bin)?;
    Ok(bin)
}

fn image() -> io::Result<Vec<u8>> {
    // Linux current_exe() can end in " (deleted)" after an old stable copy was replaced.
    // Open the running image through the OS, never read a replacement at its former path.
    let mut image = inspect::executable(std::process::id(), &std::env::current_exe()?)?;
    let mut bytes = Vec::new();
    image.read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn relative(digest: &str) -> PathBuf {
    PathBuf::from("launchers").join(digest).join("dispatch-helper")
}

/// The stable hook command path, pointing at this build.
pub(super) fn stable() -> io::Result<PathBuf> {
    let bin = bins()?;
    let mut build = BUILD.lock().unwrap_or_else(|e| e.into_inner());
    resolve(&bin, &mut build, &image, RELEASE)
}

/// Publishes this process's image once (`memo` remembers it), then keeps `bin/dispatch-helper`
/// pointing at it, unless it points at a newer version's build, with at most a link and a stamp
/// read per call. Returns the stable path, or the immutable one while another process holds the
/// link lock.
fn resolve(
    bin: &Path,
    memo: &mut Option<(PathBuf, String)>,
    image: &dyn Fn() -> io::Result<Vec<u8>>,
    release: Option<&str>,
) -> io::Result<PathBuf> {
    let path = bin.join("dispatch-helper");
    // A collector may remove an unlinked build after a day; then it is published again.
    let known = memo
        .as_ref()
        .filter(|(known, _)| known == bin)
        .map(|(_, digest)| digest.clone())
        .filter(|digest| fs::symlink_metadata(bin.join(relative(digest))).is_ok_and(|m| m.is_file()));
    let digest = match known {
        Some(digest) => digest,
        None => {
            let bytes = image()?;
            let _lock = native::advisory(&bin.join(".lock"), Instant::now() + FULL)?;
            let digest = publish(bin, &bytes, release)?;
            *memo = Some((bin.to_path_buf(), digest));
            return Ok(path);
        }
    };
    let relative = relative(&digest);
    if fs::read_link(&path).is_ok_and(|current| current == relative) || yields(bin, release) {
        return Ok(path);
    }
    match native::advisory(&bin.join(".lock"), Instant::now() + SHORT) {
        Ok(_lock) => {
            if !yields(bin, release) {
                link(bin, &relative)?;
            }
            Ok(path)
        }
        Err(error) if error.kind() == io::ErrorKind::TimedOut => {
            // Whoever holds the lock may have relinked to this build, or a newer one, meanwhile.
            if fs::read_link(&path).is_ok_and(|current| current == relative) || yields(bin, release) {
                Ok(path)
            } else {
                Ok(bin.join(relative))
            }
        }
        Err(error) => Err(error),
    }
}

/// Caller holds bin/.lock. The shared storage lock excludes collection until the new link
/// protects its target; active processes separately hold their version's lifetime lock.
/// Stores the build and its `release` stamp, then links it unless a newer version's build is
/// linked. Returns the build's digest.
fn publish(bin: &Path, bytes: &[u8], release: Option<&str>) -> io::Result<String> {
    let base = bin.parent().ok_or(io::ErrorKind::InvalidInput)?;
    let _storage = native::advisory(&base.join("lock"), Instant::now() + FULL)?;
    let mut digest = crate::hash::Sha256::new();
    digest.update(bytes);
    let digest: String = digest.finish().iter().map(|b| format!("{b:02x}")).collect();
    // SSH bootstrap can repair/replace entries in its upload cache. Keep hook/launcher
    // builds in a separate immutable store so those repairs cannot unlink live images.
    let versions = bin.join("launchers");
    directory(&versions)?;
    let version = versions.join(&digest);
    directory(&version)?;
    let target = version.join("dispatch-helper");
    let valid = || -> io::Result<()> {
        let file = native::private(&target)?;
        let m = file.metadata()?;
        if !m.is_file() || m.uid() != unsafe { native::getuid() } || m.mode() & 0o777 != 0o700 {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        let mut saved = Vec::new();
        file.take(bytes.len() as u64 + 1).read_to_end(&mut saved)?;
        if saved != bytes {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Stored helper build does not match its digest",
            ));
        }
        Ok(())
    };
    match valid() {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            // Publish complete bytes without replacing an existing build.
            let mut nonce = [0u8; 16];
            super::random(&mut nonce)?;
            let name = format!(
                ".dispatch-{}.tmp",
                nonce.iter().map(|b| format!("{b:02x}")).collect::<String>()
            );
            let parent = native::directory(&version, crate::api::Expected::Any)?;
            let mut file = native::open(&parent, name.as_ref(), Some(0o700))?;
            let result = (|| {
                file.write_all(bytes)?;
                file.sync_all()?;
                match native::publish(&parent, name.as_ref(), "dispatch-helper".as_ref(), false) {
                    Ok(()) => Ok(()),
                    Err(error) if error.kind() == io::ErrorKind::AlreadyExists => valid(),
                    Err(error) => Err(error),
                }
            })();
            let _ = native::remove(&parent, name.as_ref());
            result?;
        }
        Err(error) => return Err(error),
    }
    if let Some(release) = release {
        stamp(&version, release)?;
    }
    if !yields(bin, release) {
        link(bin, &relative(&digest))?;
    }
    Ok(digest)
}

/// Writes `folder/release` before this build is first linked, unless it has one: a build's bytes
/// fix its version, so a stamp already there stands.
fn stamp(folder: &Path, release: &str) -> io::Result<()> {
    if fs::symlink_metadata(folder.join("release")).is_ok() {
        return Ok(());
    }
    let mut nonce = [0u8; 16];
    super::random(&mut nonce)?;
    let name = format!(".dispatch-{}.tmp", nonce.iter().map(|b| format!("{b:02x}")).collect::<String>());
    let parent = native::directory(folder, crate::api::Expected::Any)?;
    let mut file = native::open(&parent, name.as_ref(), Some(0o600))?;
    let result = (|| {
        file.write_all(release.as_bytes())?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        match native::publish(&parent, name.as_ref(), "release".as_ref(), false) {
            Err(error) if error.kind() != io::ErrorKind::AlreadyExists => Err(error),
            _ => Ok(()),
        }
    })();
    let _ = native::remove(&parent, name.as_ref());
    result
}

/// Caller holds bin/.lock. Points `bin/dispatch-helper` at `relative` unless it already does,
/// through a staged link and one rename, so the stable path never goes missing.
fn link(bin: &Path, relative: &Path) -> io::Result<()> {
    let path = bin.join("dispatch-helper");
    if fs::read_link(&path).is_ok_and(|current| current == relative) {
        return Ok(());
    }
    let mut nonce = [0u8; 16];
    super::random(&mut nonce)?;
    let staged = bin.join(format!(
        ".dispatch-{}.tmp",
        nonce.iter().map(|b| format!("{b:02x}")).collect::<String>()
    ));
    symlink(relative, &staged)?;
    let result = fs::rename(&staged, &path);
    if result.is_err() {
        let _ = fs::remove_file(&staged);
    }
    result
}

#[cfg(test)]
#[path = "executable.test.rs"]
mod tests;
