//! Native effects and completion routing. Reactor and workers are ported from helper2.
pub mod capture;
mod effects;
mod file;
pub(crate) use file::{copy, errno};

pub(crate) mod hooks;
mod inspect;
mod listing;
pub mod launch;
pub mod login;
mod native;
mod observe;
mod process;
pub mod search;
pub mod queue;
pub mod reactor;
pub mod renderer;
pub mod replay;
pub mod sender;
mod socket;
pub mod startup;
mod stats;
mod watch;
mod work;
pub(crate) mod zstd;
// The files plugin's transfer jobs and their archive layout.
mod archive;
mod tar;

use crate::api::{
    Address, Event, Expected, FileKind, Grid, Io, Job, Metadata, Output, Spawned, Work,
};
use crate::json::Data;
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
    /// Leads its own process group (spawned children): ending it ends the group.
    leader: bool,
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


pub struct System {
    /// The fd whose readiness the last live events all were, how often, with no read, write,
    /// accept, close or interest change on it since.
    unconsumed: Option<(RawFd, u32)>,
    /// The app that started a stdio helper; its exit ends the helper, whoever still holds
    /// the stdin pipe (runs 135/136 orphans).
    parent: Option<(u32, reactor::Exit, Option<String>)>,
    reactor: reactor::Reactor,
    workers: work::Executor<file::Completion>,
    /// Job::Collect's own workers, made for the first collect: a command such as `git status` on a large tree
    /// takes seconds, and two of them on the shared workers would hold every file job behind them.
    collects: Option<work::Executor<file::Completion>>,
    descriptors: BTreeMap<RawFd, File>,
    locks: BTreeMap<Work, File>,
    listeners: BTreeMap<RawFd, socket::Listener>,
    signals: BTreeMap<RawFd, renderer::Signals>,
    termination: Option<RawFd>,
    children: BTreeMap<u32, ChildState>,
    modes: Option<renderer::native::Termios>,
    inherited: bool,
    sections: BTreeMap<RawFd, String>,
    /// A submitted job's section and, while traced, its order and encoded args (capture.rs).
    jobs: BTreeMap<Work, (String, Option<(u64, Vec<u8>)>)>,
    files: file::Book,
    timers: BTreeSet<(Instant, String)>,
    ready: VecDeque<(String, Event)>,
    callbacks: VecDeque<(String, Box<dyn FnOnce(&mut dyn Io)>)>,
    /// Own pid, a startup fact (see `own`).
    pid: u32,
    /// Io::os/arch: the startup facts' when replaying.
    platform: (String, String, Vec<std::ffi::OsString>),
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
    routes: BTreeMap<String, PathBuf>,
    paused: Option<Instant>,
}

impl Drop for System {
    fn drop(&mut self) {
        // Private servers, clients and side agents end with their helper; daemons stay.
        for child in self.children.values() {
            if child.owned && !child.pty && child.status.is_none() {
                let _ = native::end(child.process.id(), child.leader);
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
        use std::os::unix::ffi::OsStringExt;
        if let Some(bytes) = Self::startup("context")? {
            let context = crate::wire::body::decode_plain(&bytes).map_err(|_| file::invalid())?;
            let path = file::field(&context, "cwd", Data::bytes)?;
            let path = PathBuf::from(std::ffi::OsString::from_vec(path.to_vec()));
            if !path.is_absolute() { return Err(file::invalid()); }
            return Ok(path);
        }
        std::env::current_dir()
    }

    /// The launch context (cwd, argv, environment) as the startup fact records it.
    fn context() -> io::Result<Vec<u8>> {
        let cwd = Self::cwd()?;
        let argv: Vec<_> = std::env::args_os().collect();
        let env: BTreeMap<_, _> = std::env::vars_os()
            .filter(|(name, _)| !context_control(name))
            .collect();
        capture::value(&Data::Object(vec![
            ("cwd", Data::Bytes(cwd.as_os_str().as_encoded_bytes())),
            (
                "argv",
                Data::Array(argv.iter().map(|value| Data::Bytes(value.as_encoded_bytes())).collect()),
            ),
            (
                "env",
                Data::Array(
                    env.iter()
                        .map(|(name, value)| {
                            Data::Array(vec![
                                Data::Bytes(name.as_encoded_bytes()),
                                Data::Bytes(value.as_encoded_bytes()),
                            ])
                        })
                        .collect(),
                ),
            ),
        ]))
    }

    /// A startup fact's recorded value: the capture's first records, read before anything else.
    fn startup(name: &str) -> io::Result<Option<Vec<u8>>> {
        let Some(path) = Self::recording() else {
            return Ok(None);
        };
        let (mut reader, _) = capture::trace::Reader::new(file::open(&path)?, file::LIMIT as usize)?;
        for _ in 0.. {
            let Some(record) = reader.next()? else { break };
            if record.section != "startup" {
                break;
            }
            if record.op == name {
                return Ok(Some(record.output));
            }
        }
        Ok(None)
    }

    /// Running image, distinct from Io::executable's installed stable copy.
    pub fn image() -> io::Result<PathBuf> {
        use std::os::unix::ffi::OsStringExt;
        if let Some(bytes) = Self::startup("image")? {
            let image = crate::wire::body::decode_plain(&bytes).map_err(|_| file::invalid())?;
            let path = image.bytes().ok_or_else(file::invalid)?;
            return Ok(std::ffi::OsString::from_vec(path.to_vec()).into());
        }
        std::env::current_exe()
    }

    /// Reexec before startup consumers without mutating the calling process's environment.
    /// Legacy captures keep caller-supplied context; capture/replay controls always stay local.
    pub fn restore() -> io::Result<Option<Command>> {
        use std::{ffi::OsString, os::unix::ffi::OsStringExt};
        let Some(bytes) = Self::startup("context")? else {
            return Ok(None);
        };
        if bytes == Self::context()? {
            return Ok(None);
        }
        if std::env::var_os("DISPATCH_REPLAY_RESTORED").is_some() {
            return Err(io::Error::other("restored launch context differs; replay cannot restore this environment, cwd or argv"));
        }
        let root = crate::wire::body::decode_plain(&bytes).map_err(|_| file::invalid())?;
        let root = &root;
        let decode = |value: &Data<'_>| -> io::Result<OsString> {
            Ok(OsString::from_vec(value.bytes().ok_or_else(file::invalid)?.to_vec()))
        };
        let mut arguments = file::field(root, "argv", Data::array)?;
        let mut command = Command::new(std::env::current_exe()?);
        command.arg0(decode(arguments.next().ok_or_else(file::invalid)?)?);
        for argument in arguments {
            command.arg(decode(argument)?);
        }
        // The recorded cwd is a recorded fact (System::cwd): effects replay through System, so the
        // replay never enters that directory, which may be gone, private, or on another machine.
        command.env_clear();
        for pair in file::field(root, "env", Data::array)? {
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

    /// This host's execution prefix (Io::execution); c1654cc TermApple/Launch.swift:248-259.
    /// Always quiet: the renderer's own login already printed (or hushed) the banner in this
    /// terminal, so a command's login must not print "Last login" a second time.
    pub(crate) fn prefix() -> Vec<std::ffi::OsString> {
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
        let ids = match self.replay("stdio", Data::Null, |v| {
            let fd = |name| v.get(name)?.signed()?.try_into().ok();
            Some([fd("read")?, fd("write")?]).filter(|fds| fds[0] != fds[1])
        }) {
            Some(result) => Some(result?),
            None => None,
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
        let output = result.as_ref().map_or(Data::Null, |&(read, write)| {
            Data::Object(vec![("read", Data::Signed(read.into())), ("write", Data::Signed(write.into()))])
        });
        self.record("stdio", Data::Null, &result, output)?;
        result
    }
    /// A login has other bus consumers: deliver its frontend exit to the owning section.
    /// Ordinary stdio helpers keep the default fatal parent-loss policy.
    pub(crate) fn parent(&mut self, section: &str) -> io::Result<u32> {
        if let Some(result) = self.replay("parent.route", section, |v| v.unsigned()?.try_into().ok()) {
            return result;
        }
        let result = self.parent.as_mut().ok_or_else(|| io::Error::other("login frontend exited before startup"))
            .map(|(pid, _, route)| { *route = Some(section.into()); *pid });
        let output = result.as_ref().map_or(Data::Null, |&pid| Data::Unsigned(pid.into()));
        self.record("parent.route", section, &result, output)?;
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
        if Self::recording().is_none() {
            return native::account().map(|account| (account.uid, account.home));
        }
        let bytes = Self::startup("account")?.ok_or_else(file::invalid)?;
        let account = crate::wire::body::decode_plain(&bytes).map_err(|_| file::invalid())?;
        let account = &account;
        Ok((
            file::field(account, "uid", Data::unsigned)?.try_into().map_err(|_| file::invalid())?,
            std::ffi::OsString::from_vec(file::field(account, "home", Data::bytes)?.to_vec()).into(),
        ))
    }
    /// The helper's own pid, a startup fact after the account: replay returns the captured
    /// one. Unlike the account, a trace recorded before this fact replays with the live pid;
    /// only traces whose effects carry the pid (e.g. a native process job) must be re-captured.
    fn own() -> io::Result<u32> {
        if Self::recording().is_none() {
            return Ok(std::process::id());
        }
        let bytes = Self::startup("pid")?.ok_or_else(file::invalid)?;
        let pid = crate::wire::body::decode_plain(&bytes).map_err(|_| file::invalid())?;
        pid.unsigned().and_then(|pid| u32::try_from(pid).ok()).ok_or_else(file::invalid)
    }
    /// The recorded platform (os, arch, execution prefix) when replaying, else this one.
    fn platform() -> io::Result<(String, String, Vec<std::ffi::OsString>)> {
        use std::os::unix::ffi::OsStringExt;
        if Self::recording().is_none() {
            return Ok((std::env::consts::OS.into(), std::env::consts::ARCH.into(), Self::prefix()));
        }
        let fact = |name| -> io::Result<Vec<u8>> { Self::startup(name)?.ok_or_else(file::invalid) };
        let text = |name| -> io::Result<String> {
            let bytes = fact(name)?;
            let value = crate::wire::body::decode_plain(&bytes).map_err(|_| file::invalid())?;
            value.string().map(str::to_owned).ok_or_else(file::invalid)
        };
        let bytes = fact("execution")?;
        let prefix = crate::wire::body::decode_plain(&bytes).map_err(|_| file::invalid())?;
        let prefix = prefix.array().ok_or_else(file::invalid)?
            .map(|part| part.bytes().map(|part| std::ffi::OsString::from_vec(part.to_vec())).ok_or_else(file::invalid))
            .collect::<io::Result<_>>()?;
        Ok((text("os")?, text("arch")?, prefix))
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
            let account = Self::account();
            capture.fact(
                "account",
                &account.as_ref().map(|(uid, home)| {
                    Data::Object(vec![
                        ("uid", Data::Unsigned((*uid).into())),
                        ("home", Data::Bytes(home.as_os_str().as_bytes())),
                    ])
                }).map_err(|e| io::Error::new(e.kind(), e.to_string())),
            )?;
            capture.fact("pid", &Ok(Data::Unsigned(std::process::id().into())))?;
            let image = Self::image();
            capture.fact(
                "image",
                &image.as_ref().map(|path| Data::Bytes(path.as_os_str().as_bytes()))
                    .map_err(|e| io::Error::new(e.kind(), e.to_string())),
            )?;
            match Self::context() {
                Ok(context) => capture.record("startup", "context", &Data::Null, None, 0, context)?,
                Err(error) => capture.fact("context", &Err(error))?,
            }
            capture.fact("os", &Ok(Data::String(std::env::consts::OS)))?;
            capture.fact("arch", &Ok(Data::String(std::env::consts::ARCH)))?;
            let prefix = Self::prefix();
            capture.fact("execution", &Ok(Data::Array(prefix.iter().map(|part| Data::Bytes(part.as_bytes())).collect())))?;
            let digest = (|| -> io::Result<[u8; 32]> {
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
                Ok(hash.finish())
            })();
            capture.fact("image.sha256", &digest.as_ref().map(|digest| Data::Bytes(digest)).map_err(|e| io::Error::new(e.kind(), e.to_string())))?;
            // A whole prefix at once: a snapshot of a running helper's capture already names its image.
            if let Err(error) = capture.flush() {
                eprintln!("capture invalid: {error}; live IO continues");
            }
        }
        let mut bytes = [0; 16];
        if let Some(replay) = &capture.replay {
            for op in ["account", "pid", "image", "context", "os", "arch", "execution", "image.sha256"] {
                if replay.peek("startup") == Some(op) {
                    // Recording stores annotation failures without aborting startup. Their
                    // consumers validate required values; draining metadata must do the same.
                    let _ = replay.value("startup", op, &Data::Null)?;
                }
            }
            let record = replay.value("ui", "random", &Data::Unsigned(16))?;
            let value = crate::wire::body::decode_plain(&record.output).map_err(|_| file::invalid())?;
            if record.error.is_some() {
                return Err(file::failure(&value, &Self::platform()?.0)?);
            }
            bytes.copy_from_slice(value.bytes().filter(|data| data.len() == 16).ok_or_else(file::invalid)?);
        } else {
            match random(&mut bytes) {
                Ok(()) => capture.record("ui", "random", &Data::Unsigned(16), None, 0, capture::value(&Data::Bytes(&bytes))?)?,
                Err(error) => {
                    capture.failure("ui", "random", &Data::Unsigned(16), &error)?;
                    return Err(error);
                }
            }
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
            collects: None,
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
            platform: Self::platform()?,
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
            routes: BTreeMap::new(),
            paused: None,
            unconsumed: None,
            parent: None,
        })
    }

    /// Capture login's outer terminal once; replay never changes the live test terminal.
    pub(crate) fn terminal(&mut self) -> io::Result<(Option<renderer::native::Raw>, Grid)> {
        if let Some(result) = self.replay("tty.start", Data::Null, capture::read::grid) {
            return result.map(|grid| (None, grid));
        }
        let result = renderer::native::Raw::new()
            .and_then(|raw| renderer::native::grid().map(|grid| (Some(raw), grid)));
        let output = result.as_ref().map_or(Data::Null, |(_, grid)| capture::grid(grid));
        self.record("tty.start", Data::Null, &result, output)?;
        result
    }

    pub(crate) fn grid(&mut self) -> io::Result<Grid> {
        if let Some(result) = self.replay("tty.grid", Data::Null, capture::read::grid) {
            return result;
        }
        let result = renderer::native::grid();
        let output = result.as_ref().map_or(Data::Null, capture::grid);
        self.record("tty.grid", Data::Null, &result, output)?;
        result
    }

    /// Pass the startup outer-tty modes to the next PTY, even after stdin became raw.
    /// Login calls this once; ordinary tabs retain openpty defaults (old relay.rs:167).
    pub fn inherit(&mut self) -> io::Result<()> {
        if let Some(result) = self.replay("pty.inherit", Data::Null, |_| Some(())) {
            return result;
        }
        self.inherited = true;
        self.record("pty.inherit", Data::Null, &Ok(()), Data::Null)
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
        self.completion(None)
    }

    /// Replay consumed the whole recording: write the receipt (DISPATCH_REPLAY_COMPLETE). It names
    /// how this process ends ({kind, status}: the exit the replay must end with); the end of a
    /// recording that just stops is an empty receipt (status 0).
    fn completion(&self, end: Option<(&str, i32)>) -> io::Result<()> {
        let boundary = match end {
            Some((kind, status)) => capture::value(&Data::Object(vec![("kind", Data::String(kind)), ("status", Data::Signed(status.into()))]))?,
            None => Vec::new(),
        };
        if let Some(error) = self.failure.borrow().as_ref() {
            return Err(io::Error::new(error.kind(), error.to_string()));
        }
        if let Some(replay) = &self.capture.replay {
            replay.finish()?;
            if !self.completed.get() {
                if let Some(path) = std::env::var_os("DISPATCH_REPLAY_COMPLETE") {
                    File::options().write(true).create_new(true).mode(0o600).open(path)?.write_all(&boundary)?;
                    self.completed.set(true);
                }
            }
        }
        Ok(())
    }

    /// Complete one CLI invocation, including setup and native launcher cleanup.
    pub fn finish(mut self, status: i32) -> io::Result<i32> {
        self.section("lifecycle");
        if let Some(result) = self.replay("return", Data::Signed(status.into()), |_| Some(())) { result?; }
        else { self.record("return", Data::Signed(status.into()), &Ok(()), Data::Null)?; }
        if self.capture.replay.is_some() {
            self.capture.finish()?;
            self.completion(Some(("return", status)))?;
        } else if let Err(error) = self.capture.finish() {
            eprintln!("capture invalid: {error}; live IO continues");
        }
        Ok(status)
    }

    /// Replace this process natively; replay stops at the validated handoff request.
    /// Handoff is not evidence that the replacement program ran or exited successfully.
    pub(crate) fn replace(&mut self, mut command: Command) -> io::Result<()> {
        self.section("lifecycle");
        let encoded = capture::value(&capture::command(&command))?;
        let args = || crate::wire::body::decode_plain(&encoded).expect("encoded above");
        if let Some(result) = self.replay("handoff", args(), |_| Some(())) {
            result?;
            let failed = self.capture.replay.as_ref().unwrap().peek("lifecycle") == Some("exec.error");
            if failed {
                return self.replay("exec.error", args(), |_| Some(())).unwrap();
            }
            self.completion(Some(("handoff", 0)))?;
            std::process::exit(0);
        }
        self.record("handoff", args(), &Ok(()), Data::Null)?;
        if let Err(error) = self.capture.flush() {
            eprintln!("capture invalid: {error}; live IO continues");
        }
        let error = command.exec();
        self.record::<()>("exec.error", args(), &Err(file::copy(&error)), Data::Null)?;
        Err(error)
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

    /// One effect: what was asked and what came back, as values; a failed effect records
    /// its error instead of `output`.
    fn record<'a, T>(
        &self,
        op: &str,
        args: impl Into<Data<'a>>,
        result: &io::Result<T>,
        output: Data<'_>,
    ) -> io::Result<()> {
        if !self.capture.enabled() {
            return Ok(());
        }
        match result {
            Ok(_) => self.capture.record(&self.section, op, &args.into(), None, 0, capture::value(&output)?),
            Err(error) => self.capture.failure(&self.section, op, &args.into(), error),
        }
    }

    /// The recorded outcome of `op` with `args`: its output as `read` takes it, or its error.
    /// A record that differs, or an output `read` refuses, fails the replay.
    fn replay<'a, T>(
        &mut self,
        op: &str,
        args: impl Into<Data<'a>>,
        read: impl FnOnce(&Data<'_>) -> Option<T>,
    ) -> Option<io::Result<T>> {
        let replay = self.capture.replay.as_ref()?;
        let outcome = replay.value(&self.section, op, &args.into()).and_then(|record| {
            let value = crate::wire::body::decode_plain(&record.output).map_err(|_| file::invalid())?;
            Ok(match record.error {
                Some(_) => Err(file::failure(&value, &self.platform.0)?),
                None => Ok(read(&value).ok_or_else(file::invalid)?),
            })
        });
        Some(outcome.unwrap_or_else(|error| {
            self.failure.borrow_mut().get_or_insert_with(|| io::Error::new(error.kind(), error.to_string()));
            Err(error)
        }))
    }

    // Void effects report native failures later through next.error; validation failures
    // fail immediately at the next event boundary, without inventing an outcome.
    fn ignored<'a>(&mut self, op: &str, args: impl Into<Data<'a>>) -> bool {
        self.replay(op, args, |_| Some(())).is_some()
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
                if let Some(result) = self.replay("signal", Data::Signed(number.into()), |_| Some(())) { result?; }
                else { self.record("signal", Data::Signed(number.into()), &Ok(()), Data::Null)?; }
                self.capture.finish()?;
                if replay { self.completion(Some(("signal", 128 + number as i32)))?; }
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
            Err(_) => self.record("next.error", Data::Null, &result, Data::Null)?,
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
                if let Some((section, row)) = replay.next()? {
                    let event = if row.op == "file.done" {
                        let completion = file::decode(row.sequence, &row.output, &self.platform.0)?;
                        let done = crate::wire::body::decode_plain(&row.args).map_err(|_| file::invalid())?;
                        let [order, job] = done.array().ok_or_else(file::invalid)?.collect::<Vec<_>>()[..]
                        else {
                            return Err(file::invalid());
                        };
                        let order = order.unsigned().ok_or_else(file::invalid)?;
                        let args = capture::value(job)?;
                        let work = self
                            .jobs
                            .iter()
                            .find_map(|(work, (s, call))| {
                                (s == &section
                                    && call.as_ref().is_some_and(|(n, a)| *n == order && *a == args))
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
                    } else if row.op == "next.error" {
                        // The recorded failure of the next event, replayed as that failure.
                        file::decode(row.sequence, &row.output, &self.platform.0)?.result?;
                        return Err(file::invalid());
                    } else {
                        capture::event(&row.output, replay.origin)?
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
                    .extend(hooks.ready(ready, &mut self.reactor)?);
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
            let collects = self.collects.as_mut().filter(|collects| ready.fd == collects.as_raw_fd());
            if ready.fd == self.workers.as_raw_fd() || collects.is_some() {
                let (jobs, events, locks) = (&self.jobs, &mut self.ready, &mut self.locks);
                let executor = match collects {
                    Some(collects) => collects,
                    None => &mut self.workers,
                };
                executor.drain(|completion| {
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
        if let Some(result) = self.replay("listen", Data::from(path), |v| v.signed()?.try_into().ok()) {
            return result;
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
        let output = result.as_ref().map_or(Data::Null, |&fd| Data::Signed(fd.into()));
        self.record("listen", Data::from(path), &result, output)?;
        result
    }
}

fn random(bytes: &mut [u8]) -> io::Result<()> {
    File::open("/dev/urandom")?.read_exact(bytes)
}

/// The worker side of Job::Isolated: when this process was started as `<exe> native <name>`,
/// run that one native job (its encoded value on stdin, the answer on stdout) and return the exit code (0, or
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
        Job::Pack(job) => archive::pack(&job.base, &job.paths, &job.archive, job.limit, &job.stop).map(Output::Packed),
        Job::Append(path, bytes) => archive::append(&path, &bytes).map(Output::Appended),
        Job::Unpack(job) => {
            archive::unpack(&job).map(Output::Unpacked)
        }
        Job::RemoveTree(path) => archive::remove_tree(&path).map(|()| Output::Removed),
        Job::Stage(path) => archive::stage(&path).map(|folder| Output::Metadata(metadata(folder))),
        Job::Discard(staging) => archive::discard(&staging).map(|()| Output::Removed),
        Job::Sweep(prefix, age) => {
            archive::sweep(&prefix, age).map(|(directory, removed)| Output::Swept(directory, removed))
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
        Job::Entries(job) => listing::entries(&job.path, job.hidden, job.limit),
        Job::Summary(job) => listing::summary(&job.path, job.limit),
        Job::Process { pid } => inspect::process(pid).map(Output::Process),
        Job::Native { name, value } => native(name, &value).map(Output::Value),
        Job::Isolated {
            name,
            value,
            deadline,
        } => {
            let mut command = Command::new(std::env::current_exe()?);
            command.args(["native", name]);
            let (status, stdout) =
                process::run(command, value, Some(deadline), crate::wire::LIMIT as usize)?;
            // The worker exits with the native error's errno; 0 is success.
            match status.code() {
                Some(0) => Ok(stdout),
                Some(code) => Err(io::Error::from_raw_os_error(code)),
                None => Err(io::ErrorKind::Interrupted.into()),
            }
            .map(Output::Value)
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
        Job::Collect(job) => {
            let ran = process::collect(job.command, Instant::now() + job.timeout, job.stdout, job.stderr)?;
            Ok(Output::Collected(crate::api::Collected {
                status: ran.status.code(),
                stdout: ran.stdout,
                stderr: ran.stderr,
                truncated: ran.truncated,
            }))
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
    // Anything there, whatever it is, is not absent: opening it would fail on a symlink or socket instead.
    if expected == Expected::Absent {
        return match native::exists(parent, name)? {
            true => Err(io::Error::from_raw_os_error(native::EEXIST)),
            false => Ok(None),
        };
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
        if let Some(result) = self.replay(op, Data::Null, |v| Some((v.get("route")?.unsigned()?, v.get("path")?.path()?.to_path_buf()))) {
            return result;
        }
        let result = self
            .hooks
            .as_mut()
            .unwrap()
            .route(&self.section, &mut self.reactor);
        let output = result.as_ref().map_or(Data::Null, |(route, path)| {
            Data::Object(vec![("route", Data::Unsigned(*route)), ("path", Data::from(path.as_path()))])
        });
        self.record(op, Data::Null, &result, output)?;
        let (id, path) = result?;
        Ok((id, path))
    }
}
