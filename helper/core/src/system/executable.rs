//! Stable hook commands point to immutable builds. Publishing another build never unlinks
//! an executable that a launcher, hook, or older connected helper is still running.
use super::{hooks, inspect, native};
use std::{
    fs,
    io::{self, Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, symlink},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

type Stamp = (u64, u64, u64, u32, i64, i64, i64, i64);
fn stamp(m: fs::Metadata) -> Stamp {
    (
        m.dev(),
        m.ino(),
        m.len(),
        m.mode(),
        m.mtime(),
        m.mtime_nsec(),
        m.ctime(),
        m.ctime_nsec(),
    )
}
fn identity(path: &Path) -> io::Result<(Stamp, Stamp)> {
    Ok((
        stamp(fs::symlink_metadata(path)?),
        stamp(fs::metadata(path)?),
    ))
}

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

pub(super) fn stable() -> io::Result<PathBuf> {
    let base = hooks::base()?;
    directory(&base)?;
    let bin = base.join("bin");
    directory(&bin)?;
    let path = bin.join("dispatch-helper");
    // Both the link and its target must remain unchanged. Serialize this process's callers
    // too: a second System must not cache a different process's publication as our build.
    static VERIFIED: std::sync::Mutex<Option<(PathBuf, (Stamp, Stamp))>> =
        std::sync::Mutex::new(None);
    let mut verified = VERIFIED.lock().unwrap_or_else(|e| e.into_inner());
    if let Ok(id) = identity(&path)
        && verified
            .as_ref()
            .is_some_and(|(known, was)| *known == path && *was == id)
    {
        return Ok(path);
    }
    // Linux current_exe() can end in " (deleted)" after an old stable copy was replaced.
    // Open the running image through the OS, never read a replacement at its former path.
    let mut image = inspect::executable(std::process::id(), &std::env::current_exe()?)?;
    let mut bytes = Vec::new();
    image.read_to_end(&mut bytes)?;
    let _lock = native::advisory(&bin.join(".lock"), Instant::now() + Duration::from_secs(30))?;
    publish(&bin, &bytes)?;
    *verified = Some((path.clone(), identity(&path)?));
    Ok(path)
}

/// Caller holds bin/.lock. The shared storage lock excludes collection until the new link
/// protects its target; active processes separately hold their version's lifetime lock.
fn publish(bin: &Path, bytes: &[u8]) -> io::Result<()> {
    let base = bin.parent().ok_or(io::ErrorKind::InvalidInput)?;
    let _storage = native::advisory(&base.join("lock"), Instant::now() + Duration::from_secs(30))?;
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
    let relative = PathBuf::from("launchers")
        .join(&digest)
        .join("dispatch-helper");
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
    symlink(&relative, &staged)?;
    let result = fs::rename(&staged, &path);
    if result.is_err() {
        let _ = fs::remove_file(&staged);
    }
    result
}

#[cfg(test)]
#[path = "executable.test.rs"]
mod tests;
