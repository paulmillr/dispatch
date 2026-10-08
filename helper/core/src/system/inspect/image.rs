//! helper2 system.rs:561-646: compare pinned live images on a fixed IO worker.
use super::{invalid, snapshot};
use crate::json::Value;
use std::{
    fs,
    io::{self, Read},
    os::unix::fs::MetadataExt,
    path::PathBuf,
    time::{Duration, Instant},
};

pub(super) fn compare(root: Value<'_>) -> io::Result<bool> {
    let limit = root
        .get("timeout_ms")
        .and_then(Value::unsigned)
        .ok_or_else(invalid)?;
    let deadline = Instant::now()
        .checked_add(Duration::from_millis(limit))
        .ok_or_else(invalid)?;
    let parse = |value: Value<'_>| -> io::Result<_> {
        let pid = value
            .get("pid")
            .and_then(Value::unsigned)
            .and_then(|v| u32::try_from(v).ok())
            .ok_or_else(invalid)?;
        let start: Vec<_> = value
            .get("start")
            .and_then(Value::array)
            .ok_or_else(invalid)?
            .map(|v| v.unsigned().ok_or_else(invalid))
            .collect::<io::Result<_>>()?;
        let start: [u64; 2] = start.try_into().map_err(|_| invalid())?;
        let path = PathBuf::from(
            value
                .get("executable")
                .and_then(Value::string)
                .ok_or_else(invalid)?,
        );
        Ok((pid, start, path))
    };
    let identities = [
        parse(root.get("first").ok_or_else(invalid)?)?,
        parse(root.get("second").ok_or_else(invalid)?)?,
    ];
    let check = || -> io::Result<()> {
        if Instant::now() >= deadline {
            return Err(io::ErrorKind::TimedOut.into());
        }
        for (pid, start, path) in &identities {
            let current = snapshot(*pid)?;
            if current.start != *start || current.executable != *path {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
        }
        Ok(())
    };
    check()?;
    let mut files = Vec::with_capacity(2);
    for (pid, _, path) in &identities {
        let file = super::executable(*pid, path)?;
        files.push(file);
    }
    let facts = |file: &fs::File| -> io::Result<_> {
        let m = file.metadata()?;
        if !m.is_file() || m.mode() & 0o111 == 0 {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        Ok((
            m.dev(),
            m.ino(),
            m.uid(),
            m.gid(),
            m.mode(),
            m.nlink(),
            m.len(),
            m.mtime(),
            m.mtime_nsec(),
            m.ctime(),
            m.ctime_nsec(),
        ))
    };
    let before = [facts(&files[0])?, facts(&files[1])?];
    let mut equal = before[0].6 == before[1].6;
    let mut remaining = before[0].6;
    let (mut a, mut b) = ([0; 65_536], [0; 65_536]);
    for _ in 0..remaining.div_ceil(a.len() as u64) {
        if !equal {
            break;
        }
        if Instant::now() >= deadline {
            return Err(io::ErrorKind::TimedOut.into());
        }
        let count = remaining.min(a.len() as u64) as usize;
        files[0].read_exact(&mut a[..count])?;
        files[1].read_exact(&mut b[..count])?;
        equal = a[..count] == b[..count];
        remaining -= count as u64;
    }
    check()?;
    if before != [facts(&files[0])?, facts(&files[1])?] {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(equal)
}
