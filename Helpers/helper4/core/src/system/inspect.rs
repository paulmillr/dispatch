//! c1654cc process.rs and helper2 system::process, on the fixed workers only.
use crate::{
    api::{FileIdentity, OpenFile, Process},
    json::{self, Data, Json},
};
use std::{
    collections::BTreeSet,
    fs,
    io::{self, Read},
    os::unix::fs::{FileTypeExt, MetadataExt},
    path::Path,
};

#[cfg(target_os = "linux")]
use std::path::PathBuf;

use super::native::{self as os, getuid};
#[cfg(target_os = "macos")]
mod darwin;
mod identity;
mod image;
mod listeners;
#[cfg(target_os = "macos")]
use darwin::{arguments, environment, files, pids, snapshot};

pub(super) fn executable(pid: u32, path: &Path) -> io::Result<fs::File> {
    #[cfg(target_os = "linux")]
    {
        let _ = path;
        fs::File::open(format!("/proc/{pid}/exe"))
    }
    #[cfg(target_os = "macos")]
    darwin::image(pid, path)
}

fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
#[cfg(target_os = "linux")]
pub(super) fn bytes(path: &Path, limit: usize) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(invalid());
    }
    Ok(bytes)
}

fn metadata(m: &fs::Metadata) -> Data<'_> {
    let kind = m.file_type();
    let kind = if kind.is_file() {
        "file"
    } else if kind.is_dir() {
        "directory"
    } else if kind.is_symlink() {
        "symlink"
    } else if kind.is_socket() {
        "socket"
    } else if kind.is_char_device() {
        "character"
    } else {
        "other"
    };
    let mut fields = vec![
        ("uid", Data::Unsigned(m.uid().into())),
        ("mode", Data::Unsigned(m.mode().into())),
        ("links", Data::Unsigned(m.nlink())),
        ("kind", Data::String(kind)),
        ("size", Data::Unsigned(m.len())),
        ("device", Data::Unsigned(m.dev())),
        ("inode", Data::Unsigned(m.ino())),
        (
            "mtime_ns",
            Data::Signed(
                m.mtime()
                    .saturating_mul(1_000_000_000)
                    .saturating_add(m.mtime_nsec()),
            ),
        ),
        (
            "ctime_ns",
            Data::Signed(
                m.ctime()
                    .saturating_mul(1_000_000_000)
                    .saturating_add(m.ctime_nsec()),
            ),
        ),
    ];
    if kind == "character" {
        fields.push(("tty", Data::Unsigned(os::tty(m.rdev()))));
    }
    Data::Object(fields)
}

/// Largest raw environment a native job reads; old ssh-helper pi.rs:50.
const ENVIRONMENT: usize = 262_144;

#[cfg(target_os = "linux")]
fn environment(pid: u32) -> io::Result<Vec<u8>> {
    let source = bytes(Path::new(&format!("/proc/{pid}/environ")), ENVIRONMENT)?;
    if !source.is_empty() && source.last() != Some(&0) {
        return Err(invalid());
    }
    Ok(source)
}

pub fn process(pid: u32) -> io::Result<Process> {
    if pid <= 1 || pid > i32::MAX as u32 {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    // ESRCH means the process disappeared; expose the same absent fact as /proc ENOENT.
    let snapshot = |pid| {
        snapshot(pid).map_err(|error| {
            if error.raw_os_error() == Some(3) {
                io::Error::new(io::ErrorKind::NotFound, error)
            } else {
                error
            }
        })
    };
    let mut before = snapshot(pid)?;
    before.arguments = arguments(pid).unwrap_or_default();
    before.files = files(pid).unwrap_or_default();
    let mut after = snapshot(pid)?;
    after.arguments = before.arguments.clone();
    after.files = before.files.clone();
    if before != after {
        return Err(changed(&before, &after));
    }
    Ok(before)
}

fn changed(before: &Process, after: &Process) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, format!(
        "Process {} changed during inspection: start {:?}->{:?}, parent {}->{}, group {}->{}, foreground {}->{}, tty {}->{}, executable_changed={}",
        before.pid, before.start, after.start, before.parent, after.parent,
        before.group, after.group, before.foreground, after.foreground,
        before.tty, after.tty, before.executable != after.executable,
    ))
}

#[cfg(target_os = "linux")]
fn snapshot(pid: u32) -> io::Result<Process> {
    use std::os::unix::fs::MetadataExt;
    let path = PathBuf::from(format!("/proc/{pid}"));
    // SAFETY: getuid takes no arguments; same-account check precedes private observations.
    if fs::metadata(&path)?.uid() != unsafe { getuid() } {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let source = bytes(&path.join("stat"), 8192)?;
    let text = std::str::from_utf8(&source).map_err(|_| invalid())?;
    let (_, fields) = text.rsplit_once(") ").ok_or_else(invalid)?;
    let fields: Vec<_> = fields.split_whitespace().take(20).collect();
    if fields.len() != 20 {
        return Err(invalid());
    }
    let number = |i: usize| fields[i].parse::<i32>().map_err(|_| invalid());
    let executable = fs::read_link(path.join("exe"))?;
    if !executable.is_absolute() || executable.as_os_str().len() >= 4096 {
        return Err(invalid());
    }
    Ok(Process {
        pid,
        parent: fields[1].parse().map_err(|_| invalid())?,
        group: number(2)?,
        foreground: number(5)?.max(0),
        tty: number(4)? as u32 as u64,
        start: [fields[19].parse().map_err(|_| invalid())?, 0],
        executable,
        arguments: vec![],
        files: vec![],
    })
}

#[cfg(target_os = "linux")]
fn arguments(pid: u32) -> io::Result<Vec<String>> {
    let data = bytes(Path::new(&format!("/proc/{pid}/cmdline")), 262_144)?;
    let source = data
        .strip_suffix(&[0])
        .filter(|v| !v.is_empty())
        .ok_or_else(invalid)?;
    let arguments: Vec<_> = source
        .split(|b| *b == 0)
        .map(|v| String::from_utf8_lossy(v).into_owned())
        .collect();
    if arguments.len() > 8192 {
        return Err(invalid());
    }
    Ok(arguments)
}

#[cfg(target_os = "linux")]
fn files(pid: u32) -> io::Result<Vec<OpenFile>> {
    let mut paths = BTreeSet::new();
    for (i, entry) in fs::read_dir(format!("/proc/{pid}/fd"))?.enumerate() {
        if i >= 131_072 {
            return Err(invalid());
        }
        let entry = entry?;
        let Ok(meta) = fs::metadata(entry.path()) else {
            continue;
        };
        let Ok(path) = fs::read_link(entry.path()) else {
            continue;
        };
        if meta.is_file() && path.extension().is_some_and(|s| s == "jsonl") {
            paths.insert((path, meta.dev(), meta.ino()));
            if paths.len() > 128 {
                return Err(invalid());
            }
        }
    }
    Ok(paths
        .into_iter()
        .map(|(path, device, inode)| OpenFile {
            path,
            identity: FileIdentity { device, inode },
        })
        .collect())
}

#[cfg(target_os = "linux")]
fn pids() -> io::Result<Vec<u32>> {
    let mut pids = Vec::new();
    for (i, entry) in fs::read_dir("/proc")?.enumerate() {
        if i >= 262_144 {
            return Err(invalid());
        }
        if let Some(pid) = entry?.file_name().to_str().and_then(|s| s.parse().ok()) {
            pids.push(pid);
        }
    }
    Ok(pids)
}

fn present<T>(result: io::Result<T>) -> io::Result<Option<T>> {
    match result {
        Ok(value) => Ok(Some(value)),
        Err(error)
            if error.kind() == io::ErrorKind::NotFound || error.raw_os_error() == Some(3) =>
        {
            Ok(None)
        }
        Err(error) => Err(error),
    }
}

pub(super) fn foreground(tty: u64) -> io::Result<(i32, Vec<Process>)> {
    if tty == 0 {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let mut group = None;
    let mut members = Vec::new();
    for pid in pids()? {
        let Ok(p) = snapshot(pid) else { continue };
        if p.tty != tty || p.foreground <= 0 {
            continue;
        }
        if group.is_some_and(|g| g != p.foreground) {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!(
                "Terminal {tty} foreground changed during enumeration: {:?}->{}, process {}",
                group, p.foreground, p.pid,
            )));
        }
        group = Some(p.foreground);
        if p.group == p.foreground {
            if let Some(process) = present(process(pid))? {
                members.push(process);
            }
            if members.len() > 128 {
                return Err(invalid());
            }
        }
    }
    let group = group.ok_or(io::ErrorKind::NotFound)?;
    // Read the input facts before the final identity recheck, as in c51466a process.rs.
    let nested: BTreeSet<_> = members
        .iter()
        .filter(|p| p.executable.file_name().is_some_and(|n| n == "ssh") && !piped(p.pid))
        .map(|p| p.pid)
        .collect();
    let mut verified = Vec::with_capacity(members.len());
    for p in members {
        let Some(current) = present(snapshot(p.pid))? else {
            continue;
        };
        if current.start != p.start
            || current.tty != tty
            || current.group != group
            || current.foreground != group
        {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!(
                "Foreground recheck expected tty {tty}, group {group}: {}", changed(&p, &current),
            )));
        }
        verified.push(p);
    }
    // An exited ssh must not hide surviving foreground members.
    if verified.iter().any(|p| nested.contains(&p.pid)) {
        verified.retain(|p| nested.contains(&p.pid));
    }
    Ok((group, verified))
}

/// The old helper only knew pipes on Linux; macOS answers false (any ssh counts as nested).
fn piped(pid: u32) -> bool {
    cfg!(target_os = "linux")
        && fs::metadata(format!("/proc/{pid}/fd/0")).is_ok_and(|m| m.file_type().is_fifo())
}

/// c1654cc process.rs:639-654: foreground-only checks miss background/stopped TTY work.
fn idle(shell: &Process) -> io::Result<bool> {
    let name = shell.executable.file_name().and_then(|v| v.to_str());
    if !matches!(
        name,
        Some("sh" | "bash" | "zsh" | "fish" | "dash" | "ksh" | "tcsh" | "csh")
    ) || shell.foreground <= 1
        || shell.foreground != shell.group
        || shell.tty == 0
        || shell.tty == u32::MAX as u64
        || shell.arguments.is_empty()
        || !shell.arguments.iter().skip(1).all(|arg| {
            matches!(arg.as_str(), "--login" | "--interactive")
                || (name == Some("bash") && arg == "--posix")
                || arg
                    .strip_prefix('-')
                    .is_some_and(|v| !v.is_empty() && v.bytes().all(|c| matches!(c, b'i' | b'l')))
        })
    {
        return Ok(false);
    }
    #[cfg(target_os = "linux")]
    let jobs = jobs(shell)?;
    #[cfg(target_os = "macos")]
    let jobs = darwin::jobs(shell)?;
    if jobs {
        return Ok(false);
    }
    let current = snapshot(shell.pid)?;
    Ok(current.start == shell.start
        && current.executable == shell.executable
        && current.foreground == shell.foreground
        && current.group == shell.group)
}

#[cfg(target_os = "linux")]
fn jobs(shell: &Process) -> io::Result<bool> {
    let data = bytes(Path::new(&format!("/proc/{}/stat", shell.pid)), 8192)?;
    let text = std::str::from_utf8(&data).map_err(|_| invalid())?;
    if text
        .rsplit_once(") ")
        .and_then(|(_, fields)| fields.split_whitespace().next())
        != Some("S")
    {
        return Ok(true);
    }
    for pid in pids()? {
        if pid == shell.pid {
            continue;
        }
        let data = match bytes(Path::new(&format!("/proc/{pid}/stat")), 8192) {
            Ok(data) => data,
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e),
        };
        let text = std::str::from_utf8(&data).map_err(|_| invalid())?;
        let (_, fields) = text.rsplit_once(") ").ok_or_else(invalid)?;
        let fields: Vec<_> = fields.split_whitespace().take(6).collect();
        if fields.len() != 6 {
            return Err(invalid());
        }
        let parent = fields[1].parse::<u32>().map_err(|_| invalid())?;
        let tty = fields[4].parse::<i32>().map_err(|_| invalid())? as u32 as u64;
        if parent == shell.pid || tty == shell.tty {
            return Ok(true);
        }
    }
    Ok(false)
}

fn value(p: &Process) -> Data<'_> {
    Data::Object(vec![
        ("pid", Data::Unsigned(p.pid.into())),
        ("parent", Data::Unsigned(p.parent.into())),
        ("group", Data::Signed(p.group.into())),
        ("foreground", Data::Signed(p.foreground.into())),
        ("tty", Data::Unsigned(p.tty)),
        (
            "start",
            Data::Array(p.start.iter().map(|v| Data::Unsigned(*v)).collect()),
        ),
        (
            "executable",
            Data::String(p.executable.to_str().unwrap_or("")),
        ),
        (
            "arguments",
            Data::Array(p.arguments.iter().map(|v| Data::String(v)).collect()),
        ),
        (
            "files",
            Data::Array(
                p.files
                    .iter()
                    .map(|v| {
                        Data::Object(vec![
                            ("path", Data::String(v.path.to_str().unwrap_or(""))),
                            ("device", Data::Unsigned(v.identity.device)),
                            ("inode", Data::Unsigned(v.identity.inode)),
                        ])
                    })
                    .collect(),
            ),
        ),
    ])
}

pub fn native(name: &str, input: &[u8]) -> io::Result<Vec<u8>> {
    let json = Json::parse(input).map_err(|_| invalid())?;
    let root = json.root();
    match name {
        // Run as an Isolated job: the caller bounds graceful client shutdown.
        "process.terminate" => {
            let pid = root.get("pid").and_then(|v| v.unsigned())
                .and_then(|v| u32::try_from(v).ok()).ok_or_else(invalid)?;
            let captured = process(pid)?;
            let start = root.get("start").and_then(|v| v.array()).ok_or_else(invalid)?
                .map(|v| v.unsigned().ok_or_else(invalid)).collect::<io::Result<Vec<_>>>()?;
            if start != captured.start
                || root.get("executable").and_then(|v| v.string()) != captured.executable.to_str()
                || root.get("tty").and_then(|v| v.unsigned()) != Some(captured.tty)
                || root.get("foreground").and_then(|v| v.signed()) != Some(captured.foreground.into())
                || captured.tty == 0 || captured.group <= 1 || captured.group != captured.foreground
            {
                return Ok(b"false".to_vec());
            }
            unsafe extern "C" { fn kill(pid: i32, signal: i32) -> i32; }
            // Same-account process identity and foreground ownership were just checked.
            // Signal only this client, never its shell, server, or process group.
            if unsafe { kill(pid as i32, 15) } < 0 { return Err(io::Error::last_os_error()); }
            for _ in std::iter::repeat(()) {
                match process(pid) {
                    Ok(current) if current.start == captured.start => {}
                    Ok(_) => return Ok(b"true".to_vec()),
                    Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(b"true".to_vec()),
                    Err(error) => return Err(error),
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            unreachable!()
        }
        // Same native domain/precision as Process.start, not reactor Instant.
        // c1654cc os.rs:727-735; Darwin proc_bsdinfo pbi_start_tv{sec,usec}.
        "process.clock" => {
            #[cfg(target_os = "linux")]
            let value = os::clock(7)?; // CLOCK_BOOTTIME includes suspended time.
            #[cfg(target_os = "macos")]
            let value = os::clock(0)?; // CLOCK_REALTIME, like pbi_start_tvsec.
            let seconds = u64::try_from(value.sec).map_err(|_| invalid())?;
            let nanos = u64::try_from(value.nanos).map_err(|_| invalid())?;
            if nanos >= 1_000_000_000 {
                return Err(invalid());
            }
            #[cfg(target_os = "linux")]
            let start = {
                let rate = u64::try_from(os::ticks()).map_err(|_| invalid())?;
                if rate == 0 {
                    return Err(invalid());
                }
                let ticks = (u128::from(seconds) * 1_000_000_000 + u128::from(nanos))
                    * u128::from(rate)
                    / 1_000_000_000;
                [u64::try_from(ticks).map_err(|_| invalid())?, 0]
            };
            #[cfg(target_os = "macos")]
            let start = [seconds, nanos / 1000];
            json::write(&Data::Object(vec![(
                "start",
                Data::Array(start.into_iter().map(Data::Unsigned).collect()),
            )]))
            .map_err(|_| invalid())
        }
        "host.identity" => identity::collect(),
        "process.listeners" => listeners::collect(root),
        "process.same_image" => {
            json::write(&Data::Bool(image::compare(root)?)).map_err(|_| invalid())
        }
        "stats.host" | "stats.processes" | "stats.disks" => {
            let local = root
                .get("local")
                .and_then(|v| v.boolean())
                .ok_or_else(invalid)?;
            super::stats::native(name, local)
        }
        "environment" | "process.environment" => {
            let pid = root
                .get("pid")
                .and_then(|v| v.unsigned())
                .and_then(|v| v.try_into().ok())
                .ok_or_else(invalid)?;
            let before = snapshot(pid)?;
            // Optional caller identity (c51466a process.rs:480-491): a reused pid is refused.
            if let Some(start) = root.get("start") {
                let start = start
                    .array()
                    .ok_or_else(invalid)?
                    .map(|n| n.unsigned().ok_or_else(invalid))
                    .collect::<io::Result<Vec<u64>>>()?;
                if start != before.start {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
            }
            if let Some(executable) = root.get("executable") {
                if Path::new(executable.string().ok_or_else(invalid)?) != before.executable {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
            }
            let mut names = BTreeSet::new();
            for name in root
                .get("names")
                .and_then(|v| v.array())
                .ok_or_else(invalid)?
            {
                let name = name.string().ok_or_else(invalid)?;
                if name.is_empty()
                    || name.as_bytes().iter().any(|b| matches!(b, 0 | b'='))
                    || !names.insert(name)
                {
                    return Err(io::ErrorKind::InvalidInput.into());
                }
            }
            let source = environment(pid)?;
            if source.len() > ENVIRONMENT {
                return Err(invalid());
            }
            let mut selected = std::collections::BTreeMap::new();
            for field in source.split(|b| *b == 0) {
                let Some((key, value)) = field
                    .iter()
                    .position(|b| *b == b'=')
                    .map(|i| (&field[..i], &field[i + 1..]))
                else {
                    continue;
                };
                let Ok(key) = std::str::from_utf8(key) else {
                    continue;
                };
                if name == "process.environment" || names.contains(key) {
                    let value = std::str::from_utf8(value).map_err(|_| invalid())?;
                    if selected.insert(key, Data::String(value)).is_some() {
                        return Err(invalid());
                    }
                }
            }
            if before != snapshot(pid)? {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            json::write(&Data::Object(selected.into_iter().collect())).map_err(|_| invalid())
        }
        "file.program" => {
            let program = root.get("program").and_then(|v| v.string()).ok_or_else(invalid)?;
            if program.is_empty() || program.contains('/') { return Err(invalid()); }
            let cwd = Path::new(root.get("cwd").and_then(|v| v.string()).ok_or_else(invalid)?);
            if !cwd.is_absolute() { return Err(invalid()); }
            let path = root.get("path").and_then(|v| v.string()).ok_or_else(invalid)?;
            let skip = fs::metadata(root.get("skip").and_then(|v| v.string()).ok_or_else(invalid)?)?;
            for directory in path.split(':') {
                let candidate = cwd.join(directory).join(program);
                let Ok(metadata) = fs::metadata(&candidate) else { continue; };
                if !metadata.is_file() || metadata.mode() & 0o111 == 0
                    || (metadata.dev(), metadata.ino()) == (skip.dev(), skip.ino()) { continue; }
                unsafe extern "C" { fn access(path: *const std::ffi::c_char, mode: i32) -> i32; }
                let path = std::ffi::CString::new(candidate.as_os_str().as_encoded_bytes()).map_err(|_| invalid())?;
                // POSIX X_OK checks this account's execution rights, not another mode class.
                if unsafe { access(path.as_ptr(), 1) } != 0 { continue; }
                let mut prefix = Vec::new();
                if let Ok(file) = fs::File::open(&candidate) {
                    file.take(1024).read_to_end(&mut prefix)?;
                    let prefix = String::from_utf8_lossy(&prefix);
                    if prefix.contains(&format!("launch {program}")) || prefix.contains(&format!("'launch' '{program}'")) || prefix.contains(&format!("--{program}-launch")) { continue; }
                }
                return json::write(&Data::Object(vec![("path", Data::String(candidate.to_str().ok_or_else(invalid)?))]))
                    .map_err(|_| invalid());
            }
            Err(io::ErrorKind::NotFound.into())
        }
        "file.realpath" => {
            let path = root
                .get("path")
                .and_then(|v| v.string())
                .ok_or_else(invalid)?;
            let path = fs::canonicalize(path)?;
            let path = path.to_str().ok_or_else(invalid)?;
            json::write(&Data::Object(vec![("path", Data::String(path))])).map_err(|_| invalid())
        }
        "file.lstat" => {
            let path = root
                .get("path")
                .and_then(|v| v.string())
                .ok_or_else(invalid)?;
            json::write(&metadata(&fs::symlink_metadata(path)?)).map_err(|_| invalid())
        }
        "file.private" => {
            let path = root
                .get("path")
                .and_then(|v| v.string())
                .ok_or_else(invalid)?;
            let limit = root
                .get("limit")
                .and_then(|v| v.unsigned())
                .ok_or_else(invalid)?;
            let file = os::private(Path::new(path))?;
            let before = file.metadata()?;
            if !before.is_file() {
                return Err(io::ErrorKind::InvalidInput.into());
            }
            let mut source = Vec::new();
            (&file)
                .take(limit.checked_add(1).ok_or_else(invalid)?)
                .read_to_end(&mut source)?;
            if source.len() as u64 > limit {
                return Err(invalid());
            }
            let after = file.metadata()?;
            let text = std::str::from_utf8(&source).map_err(|_| invalid())?;
            json::write(&Data::Object(vec![
                ("before", metadata(&before)),
                ("after", metadata(&after)),
                ("data", Data::String(text)),
            ]))
            .map_err(|_| invalid())
        }
        "peer" => {
            let fd = root
                .get("fd")
                .and_then(|v| v.signed())
                .and_then(|v| v.try_into().ok())
                .ok_or_else(invalid)?;
            let (uid, pid) = os::peer(fd)?;
            json::write(&Data::Object(vec![
                ("uid", Data::Unsigned(uid.into())),
                ("pid", Data::Unsigned(pid.into())),
            ]))
            .map_err(|_| invalid())
        }
        "process" => {
            let pid = root
                .get("pid")
                .and_then(|v| v.unsigned())
                .and_then(|v| v.try_into().ok())
                .ok_or_else(invalid)?;
            let p = process(pid)?;
            let cwd = cwd(pid).ok();
            #[cfg(target_os = "linux")]
            let (domain, label) = {
                let machine = match bytes(Path::new("/etc/machine-id"), 128) {
                    Ok(bytes) => String::from_utf8(bytes).map_err(|_| invalid())?,
                    Err(error) if error.kind() == io::ErrorKind::NotFound => String::new(),
                    Err(error) => return Err(error),
                };
                let machine = machine.trim();
                let namespace = fs::read_link("/proc/self/ns/pid")?;
                let namespace = namespace.to_str().ok_or_else(invalid)?;
                let number = namespace
                    .strip_prefix("pid:[")
                    .and_then(|s| s.strip_suffix(']'))
                    .ok_or_else(invalid)?;
                if (!machine.is_empty()
                    && (machine.len() != 32 || !machine.bytes().all(|b| b.is_ascii_hexdigit())))
                    || number.is_empty()
                    || number.len() > 20
                    || !number.bytes().all(|b| b.is_ascii_digit())
                {
                    return Err(invalid());
                }
                (
                    format!("linux:{machine}:{namespace}"),
                    p.start[0].to_string(),
                )
            };
            #[cfg(target_os = "macos")]
            let (domain, label) = ("darwin".to_string(), darwin::label(p.start[0])?);
            #[cfg(target_os = "linux")]
            let epoch = {
                let data = bytes(Path::new("/proc/stat"), 1_048_576)?;
                let text = std::str::from_utf8(&data).map_err(|_| invalid())?;
                let boot = text
                    .lines()
                    .find_map(|v| v.strip_prefix("btime "))
                    .ok_or_else(invalid)?
                    .parse::<u64>()
                    .map_err(|_| invalid())?;
                let hz = os::ticks();
                if hz <= 0 {
                    return Err(invalid());
                }
                boot as f64 + p.start[0] as f64 / hz as f64
            };
            #[cfg(target_os = "macos")]
            let epoch = p.start[0] as f64 + p.start[1] as f64 / 1_000_000.0;
            let current = snapshot(pid)?;
            if current.start != p.start || current.executable != p.executable {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            let Data::Object(mut fields) = value(&p) else {
                unreachable!()
            };
            // SAFETY: process() has already verified ownership against this account.
            fields.extend([
                ("uid", Data::Unsigned(unsafe { getuid() }.into())),
                ("started_at", Data::Real(epoch)),
                (
                    "cwd",
                    cwd.as_ref()
                        .and_then(|path| path.to_str())
                        .map_or(Data::Null, Data::String),
                ),
                ("pid_domain", Data::String(&domain)),
                ("proc_start", Data::String(&label)),
            ]);
            json::write(&Data::Object(fields)).map_err(|_| invalid())
        }
        // {pid,start:[u64;2]} -> {idle:bool}; unchanged close policy, bound to exact birth.
        "idle" => {
            let pid = root
                .get("pid")
                .and_then(|v| v.unsigned())
                .and_then(|v| u32::try_from(v).ok())
                .filter(|v| *v > 1 && *v <= i32::MAX as u32)
                .ok_or_else(invalid)?;
            let start: Vec<_> = root
                .get("start")
                .and_then(|v| v.array())
                .ok_or_else(invalid)?
                .map(|v| v.unsigned().ok_or_else(invalid))
                .collect::<io::Result<_>>()?;
            let mut shell = snapshot(pid)?;
            if start.as_slice() != shell.start {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            shell.arguments = arguments(pid).unwrap_or_default();
            let idle = idle(&shell).unwrap_or(false);
            let current = snapshot(pid)?;
            if current.start != shell.start
                || current.executable != shell.executable
                || current.foreground != shell.foreground
                || current.parent != shell.parent
            {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            json::write(&Data::Object(vec![("idle", Data::Bool(idle))])).map_err(|_| invalid())
        }
        "foreground" => {
            let tty = root
                .get("tty")
                .and_then(|v| v.unsigned())
                .filter(|v| *v != 0)
                .ok_or_else(invalid)?;
            let (group, members) = foreground(tty)?;
            let data = Data::Object(vec![
                ("group", Data::Signed(group.into())),
                (
                    "processes",
                    Data::Array(members.iter().map(value).collect()),
                ),
            ]);
            json::write(&data).map_err(|_| invalid())
        }
        _ => Err(io::ErrorKind::Unsupported.into()),
    }
}

fn cwd(pid: u32) -> io::Result<std::path::PathBuf> {
    #[cfg(target_os = "linux")]
    let cwd = fs::read_link(format!("/proc/{pid}/cwd"))?;
    #[cfg(target_os = "macos")]
    let cwd = darwin::cwd(pid)?;
    if !cwd.is_absolute() {
        return Err(invalid());
    }
    Ok(cwd)
}
