//! Native effects and completion routing. Reactor and workers are ported from helper2.
mod capture;
mod effects;
mod file;

mod hooks;
mod inspect;
pub mod launch;
pub mod login;
mod native;
mod observe;
mod process;
pub mod queue;
pub mod reactor;
pub mod redact;
pub mod renderer;
pub mod replay;
pub mod sender;
mod socket;
pub mod startup;
mod stats;
mod watch;
mod work;

use crate::api::{
    Address, Event, Expected, FileKind, Grid, Io, Job, Metadata, Output, Spawned, Work,
};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    fs::File,
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, BorrowedFd, FromRawFd, IntoRawFd, RawFd},
        unix::{
            fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
            net::UnixListener,
            process::{CommandExt, ExitStatusExt},
        },
    },
    path::{Path, PathBuf},
    process::{Child, Command},
    time::{Duration, Instant},
};

struct ChildState {
    pty: bool,
    /// Ends with the helper (everything but daemons).
    owned: bool,
    process: Child,
    exit: Option<reactor::Exit>,
    section: String,
    channels: [Option<RawFd>; 3],
    #[cfg(target_os = "macos")]
    slave: Option<File>,
    status: Option<(i32, Instant)>,
}

/// Back-to-back readiness of one fd with no operation on it that counts as a spin; far beyond
/// any legitimate burst, reached within microseconds by a real spin.
const SPIN: u32 = 64;

fn context_control(name: &std::ffi::OsStr) -> bool {
    let name = name.as_encoded_bytes();
    name.starts_with(b"DISPATCH_REPLAY") || name.starts_with(b"DISPATCH_CAPTURE")
}

/// Answers a hook sender's ownership question (B4) from its process chain, nearest first:
/// None when this helper does not own it, else whether the agent is bound here.
pub type Owner = Box<dyn Fn(&[(u32, u64)]) -> Option<bool>>;

pub struct System {
    /// The fd whose readiness the last live events all were, how often, with no read, write,
    /// accept, close or interest change on it since.
    unconsumed: Option<(RawFd, u32)>,
    /// The app that started a stdio helper; its exit ends the helper, whoever still holds
    /// the stdin pipe (runs 135/136 orphans).
    parent: Option<(u32, reactor::Exit, Option<String>)>,
    reactor: reactor::Reactor,
    workers: work::Executor<file::Completion>,
    descriptors: BTreeMap<RawFd, File>,
    locks: BTreeMap<Work, File>,
    listeners: BTreeMap<RawFd, socket::Listener>,
    signals: BTreeMap<RawFd, renderer::Signals>,
    termination: Option<RawFd>,
    children: BTreeMap<u32, ChildState>,
    modes: Option<renderer::native::Termios>,
    inherited: bool,
    sections: BTreeMap<RawFd, String>,
    jobs: BTreeMap<Work, (String, Option<(u64, String)>)>,
    files: file::Book,
    timers: BTreeSet<(Instant, String)>,
    ready: VecDeque<(String, Event)>,
    callbacks: VecDeque<(String, Box<dyn FnOnce(&mut dyn Io)>)>,
    /// Own pid, a startup fact (see `own`).
    pid: u32,
    /// `Io::after` callbacks with their deadline and owner section.
    later: Vec<(Instant, String, Box<dyn FnOnce(&mut dyn Io)>)>,
    /// Io::then continuations by work id, with the registering section.
    continued: BTreeMap<Work, (String, Box<dyn FnOnce(&mut dyn Io, io::Result<Output>)>)>,
    serial: u64,
    section: String,
    capture: capture::Capture,
    failure: std::cell::RefCell<Option<io::Error>>,
    completed: std::cell::Cell<bool>,
    /// Created on the first watch: inotify instances are a scarce per-user kernel resource.
    watches: Option<watch::Watcher>,
    processes: Option<observe::Observer>,
    capacity: usize,
    watched: BTreeMap<u64, String>,
    hooks: Option<hooks::Hooks>,
    owner: Option<Owner>,
    routes: BTreeMap<String, PathBuf>,
    paused: Option<Instant>,
}

impl Drop for System {
    fn drop(&mut self) {
        // Private servers, clients and side agents end with their helper; daemons stay.
        for child in self.children.values() {
            if child.owned && !child.pty && child.status.is_none() {
                let _ = native::end(child.process.id());
            }
        }
        for child in self
            .children
            .values_mut()
            .filter(|child| child.pty && child.status.is_none())
        {
            if let Some(fd) = child.channels[0].and_then(|fd| self.descriptors.get(&fd)) {
                native::hangup(fd.as_raw_fd(), child.process.id());
            }
        }
        self.descriptors.clear();
        for mut child in std::mem::take(&mut self.children)
            .into_values()
            .filter(|child| (child.owned || child.pty) && child.status.is_none())
        {
            #[cfg(target_os = "macos")]
            child.slave.take();
            // At helper retirement there is no reactor left to reap later. End remaining
            // private children before waiting; a detached reaper dies with the helper.
            let _ = child.process.kill();
            let _ = child.process.wait();
        }
    }
}

impl System {
    /// The helper's working directory, distinct from replay control-file locations.
    pub fn cwd() -> io::Result<PathBuf> {
        use crate::json::{Json, Value};
        use std::os::unix::ffi::OsStringExt;
        if let Some(bytes) = Self::startup("context")? {
            let context = Json::parse(&bytes).map_err(|_| file::invalid())?;
            let path = file::field(context.root(), "cwd", Value::string)?;
            let path = PathBuf::from(std::ffi::OsString::from_vec(capture::unhex(path)?));
            if !path.is_absolute() { return Err(file::invalid()); }
            return Ok(path);
        }
        std::env::current_dir()
    }

    fn context() -> io::Result<Vec<u8>> {
        use crate::json::{self, Data};
        let cwd = capture::hex(Self::cwd()?.as_os_str().as_encoded_bytes());
        let argv: Vec<_> = std::env::args_os()
            .map(|value| capture::hex(value.as_encoded_bytes()))
            .collect();
        let env: Vec<_> = std::env::vars_os()
            .filter(|(name, _)| !context_control(name))
            .collect::<BTreeMap<_, _>>()
            .into_iter()
            .map(|(name, value)| {
                [
                    capture::hex(name.as_encoded_bytes()),
                    capture::hex(value.as_encoded_bytes()),
                ]
            })
            .collect();
        json::write(&Data::Object(vec![
            ("cwd", Data::String(&cwd)),
            (
                "argv",
                Data::Array(argv.iter().map(|value| Data::String(value)).collect()),
            ),
            (
                "env",
                Data::Array(
                    env.iter()
                        .map(|pair| {
                            Data::Array(pair.iter().map(|value| Data::String(value)).collect())
                        })
                        .collect(),
                ),
            ),
        ]))
        .map_err(|_| file::invalid())
    }

    fn startup(name: &str) -> io::Result<Option<Vec<u8>>> {
        use crate::json::{Json, Value};
        use std::io::BufRead;
        let Some(path) = Self::recording() else {
            return Ok(None);
        };
        // Startup facts precede native effects; do not index the whole capture.
        for line in io::BufReader::new(file::open(&path)?).lines() {
            let line = line?;
            let document = Json::parse(line.as_bytes()).map_err(|_| file::invalid())?;
            let row = document.root();
            if row.get("section").and_then(Value::string) != Some("startup") {
                break;
            }
            let op = row.get("op").and_then(Value::string);
            if op == Some(name) {
                let data = capture::unhex(file::field(row, "data", Value::string)?)?;
                let Output::Bytes(bytes) = file::decode(&data)?.result? else {
                    return Err(file::invalid());
                };
                return Ok(Some(bytes));
            }
            if !matches!(op, Some("account" | "pid" | "image" | "context" | "image.sha256")) {
                break;
            }
        }
        Ok(None)
    }

    /// Running image, distinct from Io::executable's installed stable copy.
    pub fn image() -> io::Result<PathBuf> {
        use std::os::unix::ffi::OsStringExt;
        if let Some(bytes) = Self::startup("image")? {
            return Ok(std::ffi::OsString::from_vec(bytes).into());
        }
        if Self::recording().is_some() {
            if let Some(path) = std::env::var_os("DISPATCH_REPLAY_IMAGE") {
                let path = PathBuf::from(path);
                if !path.is_absolute() {
                    return Err(io::Error::other("legacy replay image must be absolute"));
                }
                return Ok(path);
            }
            eprintln!("replay: legacy capture has no running image; effects using it require the original executable path");
        }
        std::env::current_exe()
    }

    /// Reexec before startup consumers without mutating the calling process's environment.
    /// Legacy captures keep caller-supplied context; capture/replay controls always stay local.
    pub fn restore() -> io::Result<Option<Command>> {
        use crate::json::{Json, Value};
        use std::{ffi::OsString, os::unix::ffi::OsStringExt};
        let Some(bytes) = Self::startup("context")? else {
            return Ok(None);
        };
        let cwd = Self::cwd()?;
        let exists = cwd.try_exists()?;
        if bytes == Self::context()? && (!exists || cwd == std::env::current_dir()?) {
            return Ok(None);
        }
        if std::env::var_os("DISPATCH_REPLAY_RESTORED").is_some() {
            return Err(io::Error::other("restored launch context differs; replay cannot restore this environment, cwd or argv"));
        }
        let document = Json::parse(&bytes).map_err(|_| file::invalid())?;
        let root = document.root();
        let decode = |value: Value<'_>| -> io::Result<OsString> {
            Ok(OsString::from_vec(capture::unhex(
                value.string().ok_or_else(file::invalid)?,
            )?))
        };
        let mut arguments = root
            .get("argv")
            .and_then(Value::array)
            .ok_or_else(file::invalid)?;
        let mut command = Command::new(std::env::current_exe()?);
        command.arg0(decode(arguments.next().ok_or_else(file::invalid)?)?);
        for argument in arguments {
            command.arg(decode(argument)?);
        }
        // Native effects replay through System; their logical cwd does not require the
        // original fixture directory to survive cleanup. Keep physical restoration when possible.
        if exists { command.current_dir(&cwd); }
        command.env_clear();
        for pair in root
            .get("env")
            .and_then(Value::array)
            .ok_or_else(file::invalid)?
        {
            let mut pair = pair.array().ok_or_else(file::invalid)?;
            let name = decode(pair.next().ok_or_else(file::invalid)?)?;
            let value = decode(pair.next().ok_or_else(file::invalid)?)?;
            if pair.next().is_some() || context_control(&name) {
                return Err(file::invalid());
            }
            command.env(name, value);
        }
        let cwd = std::env::current_dir()?;
        for (name, value) in std::env::vars_os().filter(|(name, _)| context_control(name)) {
            let value = if matches!(
                name.to_str(),
                Some("DISPATCH_REPLAY" | "DISPATCH_REPLAY_OUTPUT" | "DISPATCH_REPLAY_COMPLETE" | "DISPATCH_CAPTURE")
            ) {
                cwd.join(value).into_os_string()
            } else {
                value
            };
            command.env(name, value);
        }
        command.env("DISPATCH_REPLAY_RESTORED", "1");
        Ok(Some(command))
    }

    /// Startup-only old engine execution policy; c1654cc TermApple/Launch.swift:248-259.
    /// Always quiet: the renderer's own login already printed (or hushed) the banner in this
    /// terminal, so a command's login must not print "Last login" a second time.
    pub(crate) fn command() -> Vec<std::ffi::OsString> {
        #[cfg(target_os = "macos")]
        {
            use std::ffi::OsString;
            if let Ok(account) = native::account() {
                let mut args = vec![OsString::from("/usr/bin/login"), OsString::from("-q")];
                args.extend([OsString::from("-flp"), account.name]);
                if let Some(home) = std::env::var_os("HOME") {
                    let mut value = OsString::from("HOME=");
                    value.push(home);
                    args.extend([OsString::from("/usr/bin/env"), value]);
                }
                args.extend(["/bin/bash", "--noprofile", "--norc", "-c"].map(OsString::from));
                return args;
            }
        }
        vec!["/bin/sh".into(), "-c".into()]
    }
    pub(crate) fn stdio(&mut self) -> io::Result<(RawFd, RawFd)> {
        let ids = if let Some(result) = self.replay("stdio", "") {
            let bytes = result?;
            let (parts, tail) = bytes.as_chunks::<4>();
            let fds: Vec<_> = parts.iter().map(|v| i32::from_le_bytes(*v)).collect();
            if fds.len() == 2 && fds[0] != fds[1] && tail.is_empty() {
                Some([fds[0], fds[1]])
            } else {
                return Err(file::invalid());
            }
        } else {
            None
        };
        if let Some(ids) = ids {
            for fd in ids {
                self.sections.insert(fd, self.section.clone());
            }
            return Ok((ids[0], ids[1]));
        }
        unsafe extern "C" {
            fn dup(fd: i32) -> i32;
        }
        let result = (|| {
            let mut fds = Vec::new();
            for source in [0, 1] {
                // SAFETY: duplicate inherited pipes; System owns and closes only the copies.
                let fd = unsafe { dup(source) };
                if fd < 0 {
                    return Err(io::Error::last_os_error());
                }
                fds.push(Self::descriptor(fd)?);
            }
            let ids = [fds[0].as_raw_fd(), fds[1].as_raw_fd()];
            for (id, file) in ids.into_iter().zip(fds) {
                self.descriptors.insert(id, file);
                self.sections.insert(id, self.section.clone());
            }
            unsafe extern "C" {
                fn getppid() -> i32;
            }
            // SAFETY: getppid has no arguments and cannot fail.
            let parent = unsafe { getppid() };
            if parent > 1 {
                self.parent = Some((parent as u32, self.reactor.child(parent as u32)?, None));
            }
            Ok((ids[0], ids[1]))
        })();
        let bytes = result
            .as_ref()
            .map(|&(read, write)| [read.to_le_bytes(), write.to_le_bytes()].concat())
            .unwrap_or_default();
        self.record("stdio", "", &result, &bytes)?;
        result
    }
    /// A login has other bus consumers: deliver its frontend exit to the owning section.
    /// Ordinary stdio helpers keep the default fatal parent-loss policy.
    pub(crate) fn parent(&mut self, section: &str) -> io::Result<u32> {
        if let Some(result) = self.replay("parent.route", section) {
            return result.and_then(|bytes| bytes.try_into().map(u32::from_le_bytes).map_err(|_| file::invalid()));
        }
        let result = self.parent.as_mut().ok_or_else(|| io::Error::other("login frontend exited before startup"))
            .map(|(pid, _, route)| { *route = Some(section.into()); *pid });
        let bytes = result.as_ref().map(|pid| pid.to_le_bytes().to_vec()).unwrap_or_default();
        self.record("parent.route", section, &result, &bytes)?;
        result
    }
    /// Recorded IO source; startup routing uses this instead of the live stdin state.
    pub fn recording() -> Option<PathBuf> {
        capture::control("DISPATCH_REPLAY").map(PathBuf::from)
    }
    /// Startup account lookup; replay uses the recorded account, never the replay host's passwd.
    /// Captures made before the startup fact was recorded need to be captured again.
    pub fn account() -> io::Result<(u32, PathBuf)> {
        use std::os::unix::ffi::OsStringExt;
        let Some(path) = Self::recording() else {
            return native::account().map(|account| (account.uid, account.home));
        };
        let replay = file::Replay::new(path.into(), 1)?;
        let Output::Bytes(bytes) = replay.call("startup", "account", "")?.result? else {
            return Err(file::invalid());
        };
        let (uid, home) = bytes.split_at_checked(4).ok_or_else(file::invalid)?;
        Ok((
            u32::from_le_bytes(uid.try_into().unwrap()),
            std::ffi::OsString::from_vec(home.to_vec()).into(),
        ))
    }
    /// The helper's own pid, a startup fact after the account: replay returns the captured
    /// one. Unlike the account, a trace recorded before this fact replays with the live pid;
    /// only traces whose effects carry the pid (e.g. a native process job) must be re-captured.
    fn own() -> io::Result<u32> {
        let Some(path) = Self::recording() else {
            return Ok(std::process::id());
        };
        let replay = file::Replay::new(path.into(), 1)?;
        // Skip the account fact that precedes it; traces may hold neither.
        let _ = replay.call("startup", "account", "");
        Ok(match replay.call("startup", "pid", "").map(|c| c.result) {
            Ok(Ok(Output::Bytes(bytes))) => {
                u32::from_le_bytes(bytes.try_into().map_err(|_| file::invalid())?)
            }
            _ => std::process::id(),
        })
    }
    pub fn new(workers: usize, capacity: usize) -> io::Result<Self> {
        // Incident 2026-10-03: a direct `cargo test` with the real HOME overwrote, then deleted,
        // the user's agent settings. Anything cargo started (tests and the helpers they spawn)
        // must run in a scratch home, whatever the runner.
        if std::env::var_os("CARGO_MANIFEST_DIR").is_some() {
            let home = native::account()?.home;
            let same = |path: &Path| {
                path == home
                    || std::fs::canonicalize(path).ok() == std::fs::canonicalize(&home).ok()
            };
            if std::env::var_os("HOME").is_none_or(|current| same(Path::new(&current))) {
                return Err(io::Error::other(format!(
                    "refusing to run under cargo with the real home {}: point HOME at a scratch directory",
                    home.display()
                )));
            }
        }
        let capture = capture::Capture::new(capacity)?;
        if capture.enabled() {
            use std::os::unix::ffi::OsStrExt;
            let account = Self::account().map(|(uid, home)| {
                Output::Bytes([uid.to_le_bytes().as_slice(), home.as_os_str().as_bytes()].concat())
            });
            capture.result("startup", "account", "", &account)?;
            let pid = Output::Bytes(std::process::id().to_le_bytes().to_vec());
            capture.result("startup", "pid", "", &Ok(pid))?;
            capture.result("startup", "image", "", &Self::image().map(|path| {
                Output::Bytes(path.as_os_str().as_bytes().to_vec())
            }))?;
            capture.result(
                "startup",
                "context",
                "",
                &Self::context().map(Output::Bytes),
            )?;
            let digest = (|| -> io::Result<Output> {
                let mut image = inspect::executable(std::process::id(), &std::env::current_exe()?)?;
                let facts = |file: &File| -> io::Result<_> {
                    let m = file.metadata()?;
                    Ok((m.dev(), m.ino(), m.len(), m.mtime(), m.mtime_nsec(), m.ctime(), m.ctime_nsec()))
                };
                let before = facts(&image)?;
                let mut hash = crate::hash::Sha256::new();
                let mut bytes = [0; 65_536];
                for _ in 0.. {
                    let count = image.read(&mut bytes)?;
                    if count == 0 { break; }
                    hash.update(&bytes[..count]);
                }
                if before != facts(&image)? {
                    return Err(io::Error::other("executing image changed during capture"));
                }
                Ok(Output::Bytes(hash.finish().to_vec()))
            })();
            capture.result("startup", "image.sha256", "", &digest)?;
        }
        let mut bytes = [0; 16];
        if let Some(replay) = &capture.replay {
            for op in ["account", "pid", "image", "context", "image.sha256"] {
                if replay
                    .rows
                    .borrow()
                    .get("startup")
                    .and_then(|rows| rows.front())
                    .is_some_and(|(_, name)| name == op)
                {
                    // Recording stores annotation failures without aborting startup. Their
                    // consumers validate required values; draining metadata must do the same.
                    let _ = replay.call("startup", op, "")?;
                }
            }
            let Output::Bytes(data) = replay.call("ui", "random", "16")?.result? else {
                return Err(file::invalid());
            };
            bytes.copy_from_slice(&<[u8; 16]>::try_from(data).map_err(|_| file::invalid())?);
        } else {
            let result = random(&mut bytes).map(|_| Output::Bytes(bytes.to_vec()));
            capture.result("ui", "random", "16", &result)?;
            result?;
        }
        let mut reactor = reactor::Reactor::new()?;
        // Replay returns virtual routes/watches: never create external endpoints.
        let hooks = if capture.replay.is_some() {
            None
        } else {
            Some(hooks::Hooks::new(&bytes)?)
        };
        let workers = work::Executor::new(workers, capacity)?;
        reactor.interest(workers.as_raw_fd(), true, false)?;
        Ok(Self {
            reactor,
            workers,
            descriptors: BTreeMap::new(),
            locks: BTreeMap::new(),
            listeners: BTreeMap::new(),
            signals: BTreeMap::new(),
            termination: None,
            children: BTreeMap::new(),
            modes: if capture.replay.is_none() {
                renderer::native::modes(0)?
            } else {
                None
            },
            inherited: false,
            sections: BTreeMap::new(),
            jobs: BTreeMap::new(),
            files: file::Book::default(),
            timers: BTreeSet::new(),
            ready: VecDeque::new(),
            callbacks: VecDeque::new(),
            pid: Self::own()?,
            later: Vec::new(),
            continued: BTreeMap::new(),
            serial: 0,
            section: "ui".into(),
            capture,
            failure: std::cell::RefCell::new(None),
            completed: std::cell::Cell::new(false),
            watches: None,
            processes: None,
            capacity,
            watched: BTreeMap::new(),
            hooks,
            owner: None,
            routes: BTreeMap::new(),
            paused: None,
            unconsumed: None,
            parent: None,
        })
    }

    /// Capture login's outer terminal once; replay never changes the live test terminal.
    pub(crate) fn terminal(&mut self) -> io::Result<(Option<renderer::native::Raw>, Grid)> {
        if let Some(result) = self.replay("tty.start", "") {
            return result
                .and_then(|bytes| Self::dimensions(&bytes))
                .map(|grid| (None, grid));
        }
        let result = renderer::native::Raw::new()
            .and_then(|raw| renderer::native::grid().map(|grid| (Some(raw), grid)));
        let bytes = result
            .as_ref()
            .map(|(_, grid)| [grid.columns.to_le_bytes(), grid.rows.to_le_bytes()].concat())
            .unwrap_or_default();
        self.record("tty.start", "", &result, &bytes)?;
        result
    }

    pub(crate) fn grid(&mut self) -> io::Result<Grid> {
        if let Some(result) = self.replay("tty.grid", "") {
            return result.and_then(|bytes| Self::dimensions(&bytes));
        }
        let result = renderer::native::grid();
        let bytes = result
            .as_ref()
            .map(|grid| [grid.columns.to_le_bytes(), grid.rows.to_le_bytes()].concat())
            .unwrap_or_default();
        self.record("tty.grid", "", &result, &bytes)?;
        result
    }

    fn dimensions(bytes: &[u8]) -> io::Result<Grid> {
        let bytes: [u8; 4] = bytes.try_into().map_err(|_| file::invalid())?;
        Ok(Grid {
            columns: u16::from_le_bytes([bytes[0], bytes[1]]),
            rows: u16::from_le_bytes([bytes[2], bytes[3]]),
            pixels: None,
        })
    }

    /// Pass the startup outer-tty modes to the next PTY, even after stdin became raw.
    /// Login calls this once; ordinary tabs retain openpty defaults (old relay.rs:167).
    pub fn inherit(&mut self) -> io::Result<()> {
        if let Some(result) = self.replay("pty.inherit", "") {
            return result.map(|_| ());
        }
        self.inherited = true;
        self.record("pty.inherit", "", &Ok(()), &[])
    }

    pub fn section(&mut self, section: &str) {
        self.section = section.into();
    }

    pub(crate) fn replay_done(&self) -> bool {
        self.capture
            .replay
            .as_ref()
            .is_some_and(|replay| replay.finish().is_ok())
    }

    pub(crate) fn finish_replay(&self) -> io::Result<()> {
        self.completion(&[])
    }

    fn completion(&self, boundary: &[u8]) -> io::Result<()> {
        if let Some(error) = self.failure.borrow().as_ref() {
            return Err(io::Error::new(error.kind(), error.to_string()));
        }
        if let Some(replay) = &self.capture.replay {
            replay.finish()?;
            if !self.completed.get() {
                if let Some(path) = std::env::var_os("DISPATCH_REPLAY_COMPLETE") {
                    File::options().write(true).create_new(true).mode(0o600).open(path)?.write_all(boundary)?;
                    self.completed.set(true);
                }
            }
        }
        Ok(())
    }

    /// Complete one CLI invocation, including setup and native launcher cleanup.
    pub fn finish(mut self, status: i32) -> io::Result<i32> {
        self.section("lifecycle");
        let args = status.to_string();
        if let Some(result) = self.replay("return", &args) { result?; }
        else { self.record("return", &args, &Ok(()), &[])?; }
        if self.capture.replay.is_some() {
            self.capture.finish()?;
            self.completion(format!("{{\"kind\":\"return\",\"status\":{status}}}").as_bytes())?;
        } else if let Err(error) = self.capture.finish() {
            eprintln!("capture invalid: {error}; live IO continues");
        }
        Ok(status)
    }

    /// Replace this process natively; replay stops at the validated handoff request.
    /// Handoff is not evidence that the replacement program ran or exited successfully.
    pub(crate) fn replace(&mut self, mut command: Command) -> io::Result<()> {
        self.section("lifecycle");
        let args = format!("{command:?}");
        if let Some(result) = self.replay("handoff", &args) {
            result?;
            let failed = self.capture.replay.as_ref().unwrap().rows.borrow()
                .get("lifecycle").and_then(|rows| rows.front()).is_some_and(|(_, op)| op == "exec.error");
            if failed {
                return self.replay("exec.error", &args).unwrap().map(|_| ());
            }
            self.completion(b"{\"kind\":\"handoff\"}")?;
            std::process::exit(0);
        }
        self.record("handoff", &args, &Ok(()), &[])?;
        if let Err(error) = self.capture.flush() {
            eprintln!("capture invalid: {error}; live IO continues");
        }
        let error = command.exec();
        let recorded = error.raw_os_error().map(io::Error::from_raw_os_error)
            .unwrap_or_else(|| io::Error::new(error.kind(), error.to_string()));
        self.record::<()>("exec.error", &args, &Err(recorded), &[])?;
        Err(error)
    }

    /// Who answers hook senders' ownership questions; without one this helper owns nothing.
    pub fn owner(&mut self, owner: Owner) {
        self.owner = Some(owner);
    }

    /// App output backpressure leaves native bytes unread and UI/worker readiness live.
    pub(crate) fn pressure(&mut self, paused: bool) -> io::Result<()> {
        let now = Instant::now();
        match (self.paused, paused) {
            (None, true) => self.paused = Some(now),
            (Some(at), false) => {
                for child in self.children.values_mut() {
                    if let Some((_, deadline)) = &mut child.status {
                        let start = *deadline - Duration::from_secs(2);
                        *deadline += now.saturating_duration_since(at.max(start));
                    }
                }
                self.paused = None;
            }
            _ => {}
        }
        for (&fd, section) in &self.sections {
            if section != "ui" {
                self.reactor.pause(self.source(fd), paused)?;
            }
        }
        Ok(())
    }

    /// Reactor boundary only: no part borrow may be held while callbacks run.
    pub fn callbacks(&mut self) {
        self.flush();
    }

    pub(crate) fn flush(&mut self) -> bool {
        let pending = !self.callbacks.is_empty();
        let section = self.section.clone();
        loop {
            let Some((owner, callback)) = self.callbacks.pop_front() else {
                break;
            };
            self.section = owner;
            callback(self);
        }
        self.section = section;
        pending
    }

    fn record<T>(
        &self,
        op: &str,
        args: &str,
        result: &io::Result<T>,
        bytes: &[u8],
    ) -> io::Result<()> {
        if !self.capture.enabled() {
            return Ok(());
        }
        self.capture
            .bytes(&self.section, op, args, result.as_ref().err(), bytes)
    }

    fn replay(&mut self, op: &str, args: &str) -> Option<io::Result<Vec<u8>>> {
        let result = self
            .capture
            .replay
            .as_ref()
            .map(|replay| replay.call(&self.section, op, args));
        if let Some(Err(error)) = &result {
            self.failure
                .borrow_mut()
                .get_or_insert_with(|| io::Error::new(error.kind(), error.to_string()));
        }
        result.map(|completion| match completion?.result? {
            Output::Bytes(bytes) => Ok(bytes),
            _ => Err(file::invalid()),
        })
    }

    // Void effects report native failures later through next.error; validation failures
    // fail immediately at the next event boundary, without inventing an outcome.
    fn ignored(&mut self, op: &str, args: &str) -> bool {
        let Some(replay) = &self.capture.replay else {
            return false;
        };
        if let Err(error) = replay.call(&self.section, op, args) {
            self.failure.borrow_mut().get_or_insert(error);
        }
        true
    }

    fn dispose(&mut self, fd: RawFd) -> io::Result<()> {
        let result = self.reactor.interest(self.source(fd), false, false);
        self.sections.remove(&fd);
        self.descriptors.remove(&fd);
        self.listeners.remove(&fd);
        for child in self.children.values_mut() {
            for channel in &mut child.channels {
                if *channel == Some(fd) {
                    #[cfg(target_os = "macos")]
                    child.slave.take();
                    *channel = None;
                }
            }
        }
        result
    }

    /// Any operation on `fd` consumes its pending readiness.
    fn consumed(&mut self, fd: RawFd) {
        if self
            .unconsumed
            .as_ref()
            .is_some_and(|(pending, _)| *pending == fd)
        {
            self.unconsumed = None;
        }
    }

    fn source(&self, fd: RawFd) -> RawFd {
        self.descriptors.get(&fd).map_or(fd, AsRawFd::as_raw_fd)
    }

    fn adopt(&mut self, fd: RawFd) -> io::Result<RawFd> {
        let file = Self::descriptor(fd)?;
        self.descriptors.insert(fd, file);
        self.sections.insert(fd, self.section.clone());
        if self.paused.is_some() && self.section != "ui" {
            self.reactor.pause(fd, true)?;
        }
        Ok(fd)
    }

    fn descriptor(fd: RawFd) -> io::Result<File> {
        // SAFETY: the caller transfers one newly owned fd; it is closed if setup fails.
        let file = unsafe { File::from_raw_fd(fd) };
        native::cloexec(fd)?;
        reactor::nonblocking(fd)?;
        Ok(file)
    }

    /// A continued job's Done (Io::then) comes back in section "then", which no part owns,
    /// like `after` timers: the caller's loop runs callbacks next, so the continuation runs
    /// without waiting for an unrelated event.
    pub fn next(&mut self) -> io::Result<(String, Event)> {
        let (section, event) = self.event()?;
        if let Event::Ready { fd, .. } = event
            && self.termination == Some(fd)
        {
            self.section(&section);
            let mut bytes = [0; 4];
            if self.read(fd, &mut bytes)? != bytes.len() { return Err(file::invalid()); }
            let flags = u32::from_le_bytes(bytes);
            let number = (1..32).find(|n| flags & (1 << n) != 0).ok_or_else(file::invalid)?;
            let replay = self.capture.replay.is_some();
            let result = (|| {
                self.section("lifecycle");
                if let Some(result) = self.replay("signal", &number.to_string()) { result?; }
                else { self.record("signal", &number.to_string(), &Ok(()), &[])?; }
                self.capture.finish()?;
                if replay { self.completion(format!("{{\"kind\":\"signal\",\"signal\":{number}}}").as_bytes())?; }
                Ok::<_, io::Error>(())
            })();
            if replay {
                result?;
                std::process::exit(128 + number);
            }
            if let Err(error) = result { eprintln!("capture invalid: {error}; preserving signal termination"); }
            // Flush on the reactor thread, never in a signal handler. Preserve native death
            // rather than turning a hangup into a successful or ordinary error return.
            unsafe extern "C" { fn signal(number: i32, handler: usize) -> usize; fn raise(number: i32) -> i32; }
            unsafe { signal(number, 0); raise(number); }
            std::process::abort();
        }
        // Level-triggered readiness that nobody consumes comes back on every turn: a busy loop
        // with no handler (codex e9a8e830, 52k wakeups in 50 ms). Parts that drain an fd
        // themselves (signal pipes) get it back at most once or twice in a row; a leak, always.
        if let Event::Ready { fd, .. } = event
            && self.capture.replay.is_none()
        {
            let repeats = match self.unconsumed {
                Some((pending, repeats)) if pending == fd => repeats + 1,
                _ => 1,
            };
            if repeats == SPIN {
                return Err(io::Error::other(format!(
                    "section {section} ignored readiness of fd {fd}: consume it or drop the interest"
                )));
            }
            self.unconsumed = Some((fd, repeats));
        } else {
            self.unconsumed = None;
        }
        let Event::Done { work, result } = event else {
            return Ok((section, event));
        };
        let Some((owner, callback)) = self.continued.remove(&work) else {
            return Ok((section, Event::Done { work, result }));
        };
        // io::Error is not Clone: keep the OS code when there is one, else kind and text.
        let copy = match &result {
            Ok(output) => Ok(output.clone()),
            Err(error) => Err(error.raw_os_error().map_or_else(
                || io::Error::new(error.kind(), error.to_string()),
                io::Error::from_raw_os_error,
            )),
        };
        self.callbacks
            .push_back((owner, Box::new(move |io: &mut dyn Io| callback(io, result))));
        Ok(("then".into(), Event::Done { work, result: copy }))
    }

    fn event(&mut self) -> io::Result<(String, Event)> {
        let result = self.poll();
        match &result {
            Ok((section, Event::Done { work, result })) if self.capture.replay.is_none() => {
                let (_, invocation) = self.jobs.remove(work).ok_or_else(file::invalid)?;
                let (order, args) = invocation.ok_or_else(file::invalid)?;
                self.capture
                    .file(section, order, &args, self.files.sequence(section), result)?;
            }
            Ok((section, event)) => self.capture.event(section, event)?,
            Err(_) => self.record("next.error", "", &result, &[])?,
        }
        if let Ok((section, Event::Timer { at })) = &result
            && section == "after"
        {
            let (due, later) = std::mem::take(&mut self.later)
                .into_iter()
                .partition(|(deadline, _, _)| deadline <= at);
            self.later = later;
            self.callbacks.extend(
                due.into_iter()
                    .map(|(_, owner, callback)| (owner, callback)),
            );
        }
        result
    }

    fn poll(&mut self) -> io::Result<(String, Event)> {
        loop {
            if let Some(hooks) = &mut self.hooks {
                let expired = hooks.expire(&mut self.reactor)?;
                self.ready.extend(expired);
            }
            if let Some(error) = self.failure.borrow_mut().take() {
                return Err(error);
            }
            if let Some(mut event) = self.ready.pop_front() {
                if self.paused.is_some()
                    && event.0 != "ui"
                    && let Event::Ready { read, write, .. } = &mut event.1
                {
                    *read = false;
                    if !*write {
                        continue;
                    }
                }
                return Ok(event);
            }
            if let Some(replay) = &self.capture.replay {
                if !replay.timed
                    && let Some((at, section)) = self.timers.first().cloned()
                    && at <= Instant::now()
                {
                    self.timers.remove(&(at, section.clone()));
                    return Ok((section, Event::Timer { at }));
                }
                if let Some((section, row)) = replay.next()? {
                    let completion = file::decode(&row.data)?;
                    let event = if row.op == "file.done" {
                        let (order, args) = row.args.split_once(' ').ok_or_else(file::invalid)?;
                        let order = order.parse::<u64>().map_err(|_| file::invalid())?;
                        let work = self
                            .jobs
                            .iter()
                            .find_map(|(work, (s, call))| {
                                (s == &section
                                    && call.as_ref().is_some_and(|(n, a)| *n == order && a == args))
                                .then_some(*work)
                            })
                            .ok_or_else(file::invalid)?;
                        if completion.sequence != Some(self.files.sequence(&section)) {
                            return Err(file::invalid());
                        }
                        self.jobs.remove(&work);
                        Event::Done {
                            work,
                            result: completion.result,
                        }
                    } else {
                        let Output::Bytes(bytes) = completion.result? else {
                            return Err(file::invalid());
                        };
                        if row.op == "next.error" {
                            return Err(file::invalid());
                        }
                        capture::event(&bytes, replay.origin)?
                    };
                    if let Event::Timer { at } = event {
                        self.timers
                            .retain(|(time, owner)| owner != &section || *time > at);
                    }
                    return Ok((section, event));
                }
                if self.replay_done() {
                    return Err(io::ErrorKind::UnexpectedEof.into());
                }
                replay.finish()?;
                return Err(io::Error::other("replay has no pending event"));
            }
            let finished = self.children.iter().find_map(|(&pid, child)| {
                child.status.and_then(|(_, deadline)| {
                    ((self.paused.is_none() && Instant::now() >= deadline)
                        || !child
                            .channels
                            .iter()
                            .flatten()
                            .any(|fd| self.reactor.reading(*fd)))
                    .then_some(pid)
                })
            });
            if let Some(pid) = finished {
                let child = self.children.remove(&pid).unwrap();
                let (status, _) = child.status.unwrap();
                let previous = std::mem::replace(&mut self.section, child.section.clone());
                for fd in child.channels.into_iter().flatten() {
                    self.dispose(fd)?;
                }
                self.section = previous;
                let event = Event::Exit {
                    pid,
                    status: Some(status),
                };
                return Ok((child.section, event));
            }
            if let Some((at, section)) = self.timers.first().cloned() {
                if at <= Instant::now() {
                    self.timers.remove(&(at, section.clone()));
                    return Ok((section, Event::Timer { at }));
                }
            }
            let deadline = self
                .timers
                .first()
                .map(|(at, _)| *at)
                .into_iter()
                .chain(self.children.values().filter_map(|child| {
                    self.paused
                        .is_none()
                        .then_some(child.status)
                        .flatten()
                        .map(|(_, at)| at)
                }))
                .chain(self.hooks.as_ref().and_then(hooks::Hooks::deadline))
                .min();
            let ready = match deadline {
                Some(at) => self.reactor.until(at)?,
                None => Some(self.reactor.wait()?),
            };
            let Some(ready) = ready else {
                continue;
            };
            if let Some(hooks) = &mut self.hooks {
                self.ready
                    .extend(hooks.ready(ready, &mut self.reactor, self.owner.as_ref())?);
            }
            let mut changes = Vec::new();
            if let Some(watches) = &mut self.watches {
                watches.changed(ready, |change| changes.push(change))?;
            }
            for change in changes {
                let appeared = self.watches.as_mut().unwrap().refresh(change.token)?;
                if let Some(section) = self.watched.get(&change.token) {
                    self.ready.push_back((
                        section.clone(),
                        Event::Changed {
                            watch: change.token,
                            reset: change.reset || appeared,
                        },
                    ));
                }
            }
            if let Some(processes) = &mut self.processes {
                let events = &mut self.ready;
                processes.changed(ready, |owner, watch, pid| {
                    events.push_back((owner, Event::Process { watch, pid }));
                })?;
            }
            if !self.ready.is_empty() {
                continue;
            }
            if ready.fd == self.workers.as_raw_fd() {
                let (jobs, events, locks) = (&self.jobs, &mut self.ready, &mut self.locks);
                self.workers.drain(|completion| {
                    let work = completion.id;
                    let (section, _) = jobs.get(&work).unwrap();
                    let mut completion = completion.value.unwrap_or_else(|| file::Completion {
                        sequence: None,
                        held: None,
                        result: Err(io::ErrorKind::Interrupted.into()),
                    });
                    if let Some(file) = completion.held.take() {
                        locks.insert(work, file);
                    }
                    events.push_back((
                        section.clone(),
                        Event::Done {
                            work,
                            result: completion.result,
                        },
                    ));
                })?;
                continue;
            }
            if self
                .parent
                .as_ref()
                .is_some_and(|(_, parent, _)| parent.exited(ready))
            {
                let (pid, _, section) = self.parent.take().unwrap();
                if let Some(section) = section {
                    return Ok((section, Event::Exit { pid, status: None }));
                }
                return Err(io::Error::other("the app that started this helper exited"));
            }
            let exited = self.children.iter().find_map(|(&pid, child)| {
                child
                    .exit
                    .as_ref()
                    .is_some_and(|exit| exit.exited(ready))
                    .then_some(pid)
            });
            if let Some(pid) = exited {
                let child = self.children.get_mut(&pid).unwrap();
                // Darwin NOTE_EXIT can precede the child's waitable zombie state.
                // Reap this confirmed exiting child instead of turning WNOHANG into a helper error.
                let status = child.process.wait()?;
                let status = status.code().unwrap_or(128 + status.signal().unwrap_or(0));
                child.exit.take();
                #[cfg(target_os = "macos")]
                child.slave.take();
                // c1654cc relay.rs:288-296: drain subscribed final bytes before Exit.
                child.status = Some((status, Instant::now() + Duration::from_secs(2)));
                continue;
            }
            if let Some(section) = self.sections.get(&ready.fd).cloned() {
                let read =
                    (ready.read || ready.closed) && (self.paused.is_none() || section == "ui");
                if !read && !ready.write {
                    continue;
                }
                let event = Event::Ready {
                    fd: ready.fd,
                    read,
                    write: ready.write,
                };
                return Ok((section, event));
            }
        }
    }
}

impl System {
    pub fn listen(&mut self, path: &Path) -> io::Result<RawFd> {
        if let Some(result) = self.replay("listen", &path.to_string_lossy()) {
            return result.and_then(|v| {
                v.try_into()
                    .map(i32::from_le_bytes)
                    .map_err(|_| file::invalid())
            });
        }
        let result = (|| {
            let parent = path
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or(Path::new("."));
            let mut metadata = std::fs::symlink_metadata(parent)?;
            #[cfg(target_os = "linux")]
            if metadata.file_type().is_symlink()
                && parent
                    .file_name()
                    .and_then(|v| v.to_str())
                    .is_some_and(|v| v.parse::<RawFd>().is_ok_and(|fd| fd >= 0))
                && parent.parent().is_some_and(|p| {
                    p == Path::new("/proc/self/fd")
                        || p == Path::new(&format!("/proc/{}/fd", std::process::id()))
                })
            {
                // Kernel-owned fd aliases are core's existing short-path Unix socket route.
                metadata = File::open(parent)?.metadata()?;
            }
            unsafe extern "C" {
                fn getuid() -> u32;
            }
            // SAFETY: getuid has no arguments or side effects.
            if !metadata.is_dir()
                || metadata.uid() != unsafe { getuid() }
                || metadata.mode() & 0o077 != 0
            {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            let listener = UnixListener::bind(path)?;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
            listener.set_nonblocking(true)?;
            let fd = listener.as_raw_fd();
            self.listeners
                .insert(fd, socket::Listener::new(listener, path)?);
            self.sections.insert(fd, self.section.clone());
            Ok(fd)
        })();
        let data = result
            .as_ref()
            .map(|v| v.to_le_bytes().to_vec())
            .unwrap_or_default();
        self.record("listen", &path.to_string_lossy(), &result, &data)?;
        result
    }
}

fn random(bytes: &mut [u8]) -> io::Result<()> {
    File::open("/dev/urandom")?.read_exact(bytes)
}

/// The worker side of Job::Isolated: when this process was started as `<exe> native <name>`,
/// run that one native job (JSON on stdin, result on stdout) and return the exit code (0, or
/// the error's errno). Every binary that submits Job::Isolated calls this first in main.
pub fn isolated() -> Option<i32> {
    use std::io::{Read, Write};
    let mut args = std::env::args().skip(1);
    if args.next().as_deref() != Some("native") {
        return None;
    }
    let name = args.next().unwrap_or_default();
    let mut input = Vec::new();
    let result = std::io::stdin()
        .read_to_end(&mut input)
        .and_then(|_| native(&name, &input))
        .and_then(|output| std::io::stdout().write_all(&output));
    Some(
        result
            .err()
            .map_or(0, |error| error.raw_os_error().unwrap_or(5)),
    )
}

/// One native job in this process.
pub fn native(name: &str, input: &[u8]) -> io::Result<Vec<u8>> {
    if name == "hook.endpoint" {
        hooks::endpoint(input)
    } else {
        inspect::native(name, input)
    }
}

fn execute(job: Job) -> io::Result<Output> {
    match job {
        Job::Read {
            path,
            offset,
            length,
        } => file::read(&path, offset, length),
        Job::Stat { path, follow } => Ok(Output::Metadata(metadata(if follow {
            std::fs::metadata(path)?
        } else {
            std::fs::symlink_metadata(path)?
        }))),
        Job::Write {
            path,
            bytes,
            mode,
            expected,
        } => {
            use std::os::unix::fs::PermissionsExt;
            use std::sync::atomic::{AtomicU64, Ordering};
            static SERIAL: AtomicU64 = AtomicU64::new(0);
            let parent = path.parent().ok_or(io::ErrorKind::InvalidInput)?;
            std::fs::create_dir_all(parent)?;
            let parent = native::directory(parent, expected)?;
            let name = path.file_name().ok_or(io::ErrorKind::InvalidInput)?;
            let original = checked(&parent, name, expected)?;
            let temporary = std::ffi::OsString::from(format!(
                ".dispatch-{}-{}.tmp",
                std::process::id(),
                SERIAL.fetch_add(1, Ordering::Relaxed)
            ));
            let result = (|| {
                let mut file = native::open(&parent, &temporary, Some(mode))?;
                if let Some(original) = &original {
                    file.set_permissions(std::fs::Permissions::from_mode(
                        original.mode() & 0o7777,
                    ))?;
                    std::os::unix::fs::fchown(&file, None, Some(original.gid()))?;
                }
                file.write_all(&bytes)?;
                file.sync_all()?;
                // The original may have changed while writing; publish only if it did not.
                checked(&parent, name, expected)?;
                native::publish(&parent, &temporary, name, expected != Expected::Absent)?;
                Ok(Output::Written)
            })();
            if result.is_err() {
                let _ = native::remove(&parent, &temporary);
            }
            result
        }
        Job::MakeDir { path, mode } => {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(mode)
                .create(path)?;
            Ok(Output::Written)
        }
        Job::Remove { path, expected } => {
            let parent = path.parent().ok_or(io::ErrorKind::InvalidInput)?;
            let parent = native::directory(parent, expected)?;
            let name = path.file_name().ok_or(io::ErrorKind::InvalidInput)?;
            checked(&parent, name, expected)?;
            native::remove(&parent, name)?;
            Ok(Output::Written)
        }
        Job::List { path } => {
            let mut entries = Vec::new();
            for entry in std::fs::read_dir(path)? {
                let entry = entry?;
                let name = entry
                    .file_name()
                    .into_string()
                    .map_err(|_| io::ErrorKind::InvalidData)?;
                entries.push((name, metadata(entry.metadata()?).kind));
            }
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            Ok(Output::List(entries))
        }
        Job::Process { pid } => inspect::process(pid).map(Output::Process),
        Job::Native { name, input } => native(name, &input).map(Output::Bytes),
        Job::Isolated {
            name,
            input,
            deadline,
        } => {
            let mut command = Command::new(std::env::current_exe()?);
            command.args(["native", name]);
            let (status, stdout) =
                process::run(command, input, Some(deadline), crate::wire::LIMIT as usize)?;
            // The worker exits with the native error's errno; 0 is success.
            match status.code() {
                Some(0) => Ok(stdout),
                Some(code) => Err(io::Error::from_raw_os_error(code)),
                None => Err(io::ErrorKind::Interrupted.into()),
            }
            .map(Output::Bytes)
        }
        // The worker closure in System::submit runs Job::Lock and keeps the locked fd under the
        // work id (effects.rs); execute never sees a lock job.
        Job::Lock { .. } => unreachable!("Job::Lock runs in System::submit's worker closure"),
        Job::Run {
            command,
            input,
            deadline,
        } => {
            let (status, stdout) =
                process::run(command, input, Some(deadline), crate::wire::LIMIT as usize)?;
            Ok(Output::Exit {
                status: status.code(),
                stdout,
            })
        }
    }
}

/// The metadata now at `path` if it meets `expected` (Any: unchecked, None); see Expected.
fn checked(
    parent: &File,
    name: &std::ffi::OsStr,
    expected: Expected,
) -> io::Result<Option<std::fs::Metadata>> {
    if expected == Expected::Any {
        return Ok(None);
    }
    let current = match native::open(parent, name, None).and_then(|file| file.metadata()) {
        Ok(m) => Some(m),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error),
    };
    match (expected, current) {
        (Expected::Absent, None) => Ok(None),
        (Expected::Absent, Some(_)) => Err(io::Error::from_raw_os_error(native::EEXIST)),
        (Expected::Same(guard), Some(m)) if m.is_file() && guard.matches(&metadata(m.clone())) => {
            Ok(Some(m))
        }
        _ => Err(io::Error::from_raw_os_error(native::ESTALE)),
    }
}

fn metadata(value: std::fs::Metadata) -> Metadata {
    let kind = if value.is_file() {
        FileKind::File
    } else if value.is_dir() {
        FileKind::Directory
    } else if value.file_type().is_symlink() {
        FileKind::Symlink
    } else {
        FileKind::Other
    };
    Metadata {
        kind,
        size: value.len(),
        device: value.dev(),
        inode: value.ino(),
        modified_ns: i128::from(value.mtime()) * 1_000_000_000 + i128::from(value.mtime_nsec()),
        changed_ns: i128::from(value.ctime()) * 1_000_000_000 + i128::from(value.ctime_nsec()),
    }
}

impl System {
    fn open(&mut self, op: &str) -> io::Result<(u64, PathBuf)> {
        if let Some(result) = self.replay(op, "") {
            let bytes = result?;
            let text = std::str::from_utf8(&bytes).map_err(|_| file::invalid())?;
            let (id, path) = text.split_once(' ').ok_or_else(file::invalid)?;
            let path: PathBuf = path.into();
            return Ok((id.parse().map_err(|_| file::invalid())?, path));
        }
        let result = self
            .hooks
            .as_mut()
            .unwrap()
            .route(&self.section, &mut self.reactor);
        let bytes = result
            .as_ref()
            .map(|(id, path)| format!("{id} {}", path.display()))
            .unwrap_or_default();
        self.record(op, "", &result, bytes.as_bytes())?;
        let (id, path) = result?;
        Ok((id, path))
    }
}
