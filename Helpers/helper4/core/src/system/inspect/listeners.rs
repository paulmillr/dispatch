//! Verified Unix listeners: unchanged c1654cc process.rs native producers.
#[cfg(target_os = "macos")]
use super::darwin::unix_listeners;
use super::*;
#[cfg(target_os = "linux")]
fn unix_listeners(pid: i32) -> io::Result<Vec<std::path::PathBuf>> {
    use std::io::Read;
    use std::os::unix::ffi::OsStringExt;
    let mut inodes = std::collections::BTreeSet::new();
    for (index, descriptor) in std::fs::read_dir(format!("/proc/{pid}/fd"))?.enumerate() {
        if index >= 8192 {
            return Err(invalid());
        }
        let Ok(path) = std::fs::read_link(descriptor?.path()) else {
            continue;
        };
        if let Some(inode) = path
            .to_str()
            .and_then(|v| v.strip_prefix("socket:["))
            .and_then(|v| v.strip_suffix(']'))
            .and_then(|v| v.parse::<u64>().ok())
        {
            inodes.insert(inode);
        }
    }
    let mut bytes = Vec::new();
    std::fs::File::open(format!("/proc/{pid}/net/unix"))?
        .take(2_097_153)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 2_097_152 {
        return Err(invalid());
    }
    let mut paths = std::collections::BTreeSet::new();
    for line in bytes.split(|b| *b == b'\n').skip(1) {
        let mut offset = 0;
        let mut fields = Vec::new();
        for _ in 0..7 {
            offset += line[offset..]
                .iter()
                .position(|b| !b.is_ascii_whitespace())
                .unwrap_or(line.len() - offset);
            let start = offset;
            offset += line[offset..]
                .iter()
                .position(u8::is_ascii_whitespace)
                .unwrap_or(line.len() - offset);
            fields.push(&line[start..offset]);
        }
        offset += line[offset..]
            .iter()
            .position(|b| !b.is_ascii_whitespace())
            .unwrap_or(line.len() - offset);
        let inode = std::str::from_utf8(fields[6])
            .ok()
            .and_then(|v| v.parse::<u64>().ok());
        let flags = std::str::from_utf8(fields[3])
            .ok()
            .and_then(|v| u32::from_str_radix(v, 16).ok());
        if !inode.is_some_and(|inode| inodes.contains(&inode))
            || fields[4] != b"0001"
            || !flags.is_some_and(|flags| flags & 0x10000 != 0)
        {
            continue;
        }
        let path = &line[offset..];
        if path.is_empty() || path.starts_with(b"@") || path.len() > 4096 || path.contains(&0) {
            continue;
        }
        paths.insert(std::path::PathBuf::from(std::ffi::OsString::from_vec(
            path.to_vec(),
        )));
        if paths.len() > 128 {
            return Err(invalid());
        }
    }
    Ok(paths.into_iter().collect())
}
pub(super) fn collect(input: crate::json::Value<'_>) -> io::Result<Vec<u8>> {
    let pid = input
        .get("pid")
        .and_then(|v| v.unsigned())
        .and_then(|p| u32::try_from(p).ok())
        .ok_or_else(invalid)?;
    let start = input
        .get("start")
        .and_then(|v| v.array())
        .ok_or_else(invalid)?
        .map(|v| v.unsigned().ok_or_else(invalid))
        .collect::<io::Result<Vec<_>>>()?;
    let before = snapshot(pid)?;
    if start != before.start {
        return Err(io::Error::other(
            "Remote process exited or changed identity",
        ));
    }
    let mut paths = unix_listeners(pid as i32)?;
    if paths.iter().any(|p| !p.is_absolute()) {
        let cwd = super::cwd(pid)?;
        for path in &mut paths {
            if !path.is_absolute() {
                *path = cwd.join(&*path);
            }
        }
    }
    if before.start != snapshot(pid)?.start {
        return Err(io::Error::other(
            "Remote process exited or changed identity",
        ));
    }
    let paths = paths
        .iter()
        .map(|p| p.to_str().ok_or_else(invalid))
        .collect::<io::Result<Vec<_>>>()?;
    json::write(&Data::Array(paths.into_iter().map(Data::String).collect())).map_err(|_| invalid())
}
