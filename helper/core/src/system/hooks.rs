//! Private lifecycle datagrams and one-shot interactive streams, from helper2 runtime/routes.
mod storage;
use super::{
    native,
    queue::Queue,
    reactor::{Reactor, Ready},
};
use crate::{
    api::Event,
    json::{self, Data, Json},
    wire,
};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, RawFd},
        unix::{
            fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
            net::{UnixDatagram, UnixListener, UnixStream},
        },
    },
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

/// Native hook bodies keep helper2 service::LIMIT; UI Source limits are unrelated.
pub(super) const LIMIT: u32 = 1_048_576;

pub(super) fn endpoint(input: &[u8]) -> io::Result<Vec<u8>> {
    let doc = Json::parse(input).map_err(|_| io::ErrorKind::InvalidInput)?;
    let path = doc
        .root()
        .get("path")
        .and_then(|v| v.string())
        .ok_or(io::ErrorKind::InvalidInput)?;
    let path = Path::new(path);
    if !path.is_absolute() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let name = path
        .file_name()
        .and_then(|v| v.to_str())
        .ok_or(io::ErrorKind::InvalidInput)?;
    if !name.parse::<u64>().is_ok_and(|n| n.to_string() == name) {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    // Core may issue a /proc/PID/fd directory alias when sun_path is too short.
    // Resolve the directory then pin it; final socket components never follow links.
    let directory = fs::canonicalize(path.parent().ok_or(io::ErrorKind::InvalidInput)?)?;
    let flags = native::O_DIRECTORY | native::O_NOFOLLOW | native::O_CLOEXEC;
    let file = File::options()
        .read(true)
        .custom_flags(flags)
        .open(&directory)?;
    let uid = unsafe { super::native::getuid() };
    let metadata = file.metadata()?;
    let mut stamp = Vec::new();
    for (value, socket) in [
        (metadata, false),
        (
            fs::symlink_metadata(directory.join(format!("{name}.d")))?,
            true,
        ),
        (
            fs::symlink_metadata(directory.join(format!("{name}.s")))?,
            true,
        ),
    ] {
        if value.uid() != uid
            || value.mode() & 0o077 != 0
            || if socket {
                !value.file_type().is_socket()
            } else {
                !value.is_dir()
            }
        {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        stamp.extend([
            Data::Unsigned(value.dev()),
            Data::Unsigned(value.ino()),
            Data::Unsigned(value.mode().into()),
        ]);
    }
    json::write(&Data::Object(vec![
        ("uid", Data::Unsigned(uid.into())),
        ("stamp", Data::Array(stamp)),
    ]))
    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.message))
}

struct Route {
    section: String,
    path: PathBuf,
    datagram: UnixDatagram,
    listener: UnixListener,
}
struct Peer {
    pid: Option<u32>,
    route: u64,
    token: u64,
    socket: UnixStream,
    decoder: wire::Decoder,
    header: Option<wire::Header>,
    input: Vec<u8>,
    output: Queue,
    delivered: bool,
    answered: bool,
    deadline: Option<Instant>,
}
pub(super) struct Hooks {
    directory: PathBuf,
    anchor: File,
    _lock: File,
    _version: Option<File>,
    routes: BTreeMap<u64, Route>,
    peers: BTreeMap<i32, Peer>,
    serial: u64,
    uid: u32,
}

/// Every Dispatch file in an account lives under `<home>/.dispatch` (all folders 0700):
/// - `bin/dispatch-helper`: the stable helper copy that hook entries and startup files run;
/// - `bin/versions/<sha256>/dispatch-helper`: builds the SSH bootstrap uploaded;
/// - `sessions/<id>/`: an SSH login's `ready` hand-off, `bus` socket and `exit` status;
/// - `run/<random>/`: one per helper: hook sockets and shell startup folders;
/// - `routes/<section>/<random>`: which helpers serve each hook section;
/// - `state/`: herdr recovery records.
///
/// Running helpers hold `lock` in their run, session and build folders; `collect` removes the
/// folders nobody holds.
pub(super) const ROOT: &str = ".dispatch";

/// The account's Dispatch directory under `home`.
pub(super) fn base_in(home: &Path) -> PathBuf {
    home.join(ROOT)
}

/// The account's Dispatch directory.
pub(super) fn base() -> io::Result<PathBuf> {
    let home = std::env::var_os("DISPATCH_TEST_ROOT")
        .or_else(|| std::env::var_os("HOME"))
        .ok_or(io::ErrorKind::NotFound)?;
    Ok(base_in(Path::new(&home)))
}

/// The folder where every live helper publishes its route for `section`, one entry per helper
/// named by its run directory, so hook senders can ask each of them (A14; old
/// hook_transport.rs:937-1021).
pub(super) fn registry(section: &str) -> io::Result<PathBuf> {
    Ok(base()?.join("routes").join(section.replace('/', "-")))
}

/// Hold the lock at `path` (created 0600) until the returned file closes; fails at once when
/// another process holds it.
pub(super) fn hold(path: &Path, uid: u32) -> io::Result<File> {
    storage::lock(path, true, false, uid)
}

/// Atomically point this helper's registry entry for `section` at `route` (0600 files in 0700
/// folders).
fn publish(section: &str, run: &Path, route: &Path) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let directory = registry(section)?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&directory)?;
    let name = run.file_name().ok_or(io::ErrorKind::InvalidInput)?;
    let entry = directory.join(name);
    let staged = directory.join(format!(".{}", name.to_string_lossy()));
    let written = File::options()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&staged)
        .and_then(|mut file| file.write_all(route.as_os_str().as_bytes()))
        .and_then(|()| fs::rename(&staged, &entry));
    if written.is_err() {
        let _ = fs::remove_file(&staged);
    }
    written
}

impl Hooks {
    pub fn new(random: &[u8]) -> io::Result<Self> {
        unsafe extern "C" {
            fn getuid() -> u32;
        }
        // SAFETY: getuid observes the executing account without pointers.
        let uid = unsafe { getuid() };
        let parent = base()?;
        match fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&parent)
        {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
        let runs = parent.join("run");
        match fs::DirBuilder::new().mode(0o700).create(&runs) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
        // ROOT is shared with the SSH bootstrap, which keeps it 0700 too.
        for path in [parent.as_path(), runs.as_path()] {
            let m = fs::symlink_metadata(path)?;
            if !m.is_dir() || m.uid() != uid || m.mode() & 0o077 != 0 {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
        }
        // Claimed before collecting, so this helper's own build is never removed.
        let version = storage::version(&parent, uid);
        let _parent = storage::collect(&parent, uid)?;
        // Registry entries (and staged ones) of helpers whose run directory is gone.
        for entry in fs::read_dir(parent.join("routes"))
            .into_iter()
            .flatten()
            .flatten()
            .flat_map(|section| fs::read_dir(section.path()).into_iter().flatten().flatten())
        {
            let name = entry.file_name();
            let run = name.to_string_lossy();
            if !runs.join(run.trim_start_matches('.')).exists() {
                let _ = fs::remove_file(entry.path());
            }
        }
        // The full nonce already identifies this run; a PID only consumes socket path space.
        let directory = runs.join(super::capture::hex(random));
        fs::DirBuilder::new().mode(0o700).create(&directory)?;
        let flags = native::O_DIRECTORY | native::O_NOFOLLOW | native::O_CLOEXEC;
        let anchor = File::options()
            .read(true)
            .custom_flags(flags)
            .open(&directory)?;
        let owner = storage::lock(&directory.join("lock"), true, false, uid)?;
        Ok(Self {
            directory,
            anchor,
            _lock: owner,
            _version: version,
            routes: BTreeMap::new(),
            peers: BTreeMap::new(),
            serial: 0,
            uid,
        })
    }
    pub fn directory(&self) -> &Path {
        &self.directory
    }
    pub fn route(&mut self, section: &str, reactor: &mut Reactor) -> io::Result<(u64, PathBuf)> {
        if self.routes.len() == 128 {
            return Err(io::ErrorKind::OutOfMemory.into());
        }
        self.serial = self
            .serial
            .checked_add(1)
            .ok_or(io::ErrorKind::OutOfMemory)?;
        let token = self.serial;
        let path = self.directory.join(token.to_string());
        // Linux sun_path holds 108 bytes. Longer run directories bind through the anchor
        // descriptor; native servers that reject a symlinked parent (Codex 0.153/0.154) need
        // the real directory, so it is used whenever it fits.
        #[cfg(target_os = "linux")]
        let path = if path.with_extension("s").as_os_str().len() < 108 {
            path
        } else {
            PathBuf::from(format!(
                "/proc/{}/fd/{}",
                std::process::id(),
                self.anchor.as_raw_fd()
            ))
            .join(token.to_string())
        };
        let mut created = [false; 2];
        let opened = (|| {
            let datagram = UnixDatagram::bind(path.with_extension("d"))?;
            created[0] = true;
            fs::set_permissions(path.with_extension("d"), fs::Permissions::from_mode(0o600))?;
            let listener = UnixListener::bind(path.with_extension("s"))?;
            created[1] = true;
            fs::set_permissions(path.with_extension("s"), fs::Permissions::from_mode(0o600))?;
            datagram.set_nonblocking(true)?;
            listener.set_nonblocking(true)?;
            if let Err(error) = reactor
                .interest(datagram.as_raw_fd(), true, false)
                .and_then(|()| reactor.interest(listener.as_raw_fd(), true, false))
            {
                let _ = reactor.interest(datagram.as_raw_fd(), false, false);
                let _ = reactor.interest(listener.as_raw_fd(), false, false);
                return Err(error);
            }
            Ok((datagram, listener))
        })();
        let (datagram, listener) = match opened {
            Ok(pair) => pair,
            Err(error) => {
                for (suffix, owned) in ["d", "s"].into_iter().zip(created) {
                    if !owned {
                        continue;
                    }
                    let _ = storage::remove(&self.anchor, &format!("{token}.{suffix}"));
                }
                return Err(error);
            }
        };
        self.routes.insert(
            token,
            Route {
                section: section.into(),
                path: path.clone(),
                datagram,
                listener,
            },
        );
        // Best effort: without it, this helper is not asked for hooks.
        let _ = publish(section, &self.directory, &path);
        Ok((token, path))
    }
    pub fn close(&mut self, token: u64, reactor: &mut Reactor) -> io::Result<Vec<(String, Event)>> {
        let mut events = Vec::new();
        let peers: Vec<_> = self
            .peers
            .iter()
            .filter(|(_, peer)| peer.route == token)
            .map(|(&fd, _)| fd)
            .collect();
        for fd in peers {
            reactor.interest(fd, false, false)?;
            events.extend(self.remove(fd));
        }
        if let Some(route) = self.routes.remove(&token) {
            reactor.interest(route.datagram.as_raw_fd(), false, false)?;
            reactor.interest(route.listener.as_raw_fd(), false, false)?;
            for suffix in ["d", "s"] {
                storage::remove(&self.anchor, &format!("{token}.{suffix}"))?;
            }
        }
        Ok(events)
    }
    pub fn path(&self, section: &str) -> Option<&Path> {
        self.routes
            .values()
            .rev()
            .find(|r| r.section == section)
            .map(|r| r.path.as_path())
    }
    pub fn deadline(&self) -> Option<Instant> {
        self.peers.values().filter_map(|p| p.deadline).min()
    }
    pub fn expire(&mut self, reactor: &mut Reactor) -> io::Result<Vec<(String, Event)>> {
        let expired: Vec<_> = self
            .peers
            .iter()
            .filter(|(_, p)| p.deadline.is_some_and(|at| at <= Instant::now()))
            .map(|(&fd, _)| fd)
            .collect();
        let mut events = Vec::new();
        for fd in expired {
            reactor.interest(fd, false, false)?;
            events.extend(self.remove(fd));
        }
        Ok(events)
    }
    /// Drop a peer; a delivered request without an answer tells its harness the reply is gone.
    fn remove(&mut self, fd: RawFd) -> Option<(String, Event)> {
        let peer = self.peers.remove(&fd)?;
        (peer.delivered && !peer.answered).then(|| {
            (
                if peer.header.is_some_and(|header| header.id == 3) { "launch".into() } else { self.routes[&peer.route].section.clone() },
                Event::Closed { reply: peer.token },
            )
        })
    }
    pub fn hold(&mut self, token: u64, until: Instant) -> io::Result<()> {
        let peer = self
            .peers
            .values_mut()
            .find(|p| p.token == token && p.delivered && !p.answered)
            .ok_or(io::ErrorKind::NotFound)?;
        peer.deadline = Some(until);
        Ok(())
    }
    pub fn reply(&mut self, token: u64, bytes: &[u8], reactor: &mut Reactor) -> io::Result<()> {
        let (&fd, peer) = self
            .peers
            .iter_mut()
            .find(|(_, p)| p.token == token && p.delivered && !p.answered)
            .ok_or(io::ErrorKind::NotFound)?;
        if !bytes.is_empty() {
            Json::parse(bytes).map_err(|_| io::ErrorKind::InvalidInput)?;
        }
        let frame = wire::packet(
            wire::Kind::Response,
            peer.header.map_or(0, |header| header.id),
            bytes,
        )
        .map_err(|_| io::ErrorKind::InvalidInput)?;
        peer.output
            .push(frame)
            .map_err(|_| io::ErrorKind::OutOfMemory)?;
        peer.answered = true;
        reactor.interest(fd, true, true)
    }
    pub fn ready(
        &mut self,
        ready: Ready,
        reactor: &mut Reactor,
        owner: Option<&super::Owner>,
    ) -> io::Result<Vec<(String, Event)>> {
        let mut events = Vec::new();
        for (&token, route) in &self.routes {
            if ready.fd == route.datagram.as_raw_fd() {
                let mut bytes = vec![0; LIMIT as usize + 1];
                match route.datagram.recv(&mut bytes) {
                    Ok(count) if count <= LIMIT as usize => {
                        bytes.truncate(count);
                        if Json::parse(&bytes).is_ok() {
                            events.push((
                                route.section.clone(),
                                Event::Hook {
                                    peer: None,
                                    route: token,
                                    message: bytes,
                                    reply: None,
                                },
                            ));
                        }
                    }
                    Ok(_) => {}
                    Err(e)
                        if matches!(
                            e.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                        ) => {}
                    Err(e) => return Err(e),
                }
                return Ok(events);
            }
            if ready.fd == route.listener.as_raw_fd() {
                match route.listener.accept() {
                    Ok((socket, _)) if self.peers.len() < 128 => {
                        if let Ok((uid, pid)) = super::native::peer(socket.as_raw_fd())
                            && uid == self.uid
                        {
                            socket.set_nonblocking(true)?;
                            reactor.interest(socket.as_raw_fd(), true, false)?;
                            self.serial += 1;
                            self.peers.insert(
                                socket.as_raw_fd(),
                                Peer {
                                    pid: (pid != 0).then_some(pid),
                                    route: token,
                                    token: self.serial,
                                    socket,
                                    decoder: wire::Decoder::new(LIMIT),
                                    header: None,
                                    input: Vec::new(),
                                    output: Queue::new(LIMIT as usize + 13),
                                    delivered: false,
                                    answered: false,
                                    deadline: Some(Instant::now() + Duration::from_secs(2)),
                                },
                            );
                        }
                    }
                    Ok(_) => {}
                    Err(e)
                        if matches!(
                            e.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                        ) => {}
                    Err(e) => return Err(e),
                }
                return Ok(events);
            }
        }
        let Some(peer) = self.peers.get_mut(&ready.fd) else {
            return Ok(events);
        };
        let result = (|| -> io::Result<bool> {
            if ready.read {
                let mut bytes = [0; 65536];
                match peer.socket.read(&mut bytes) {
                    Ok(0) => return Ok(true),
                    Ok(count) => {
                        if peer.delivered {
                            return Ok(true);
                        }
                        let mut ended = false;
                        let consumed = peer
                            .decoder
                            .next(&bytes[..count], |event| match event {
                                wire::Event::Begin(header) => peer.header = Some(header),
                                wire::Event::Data(bytes) => peer.input.extend_from_slice(bytes),
                                wire::Event::End => ended = true,
                            })
                            .map_err(|_| io::ErrorKind::InvalidData)?;
                        if consumed != count {
                            return Ok(true);
                        }
                        if ended {
                            let header = peer.header.ok_or(io::ErrorKind::InvalidData)?;
                            // Question 1 (B4): does this helper own the asking process
                            // (`chain`: its pid/tty and its ancestors')? Answered here.
                            if header.id == 1 && header.kind == wire::Kind::Request {
                                let input = Json::parse(&peer.input)
                                    .map_err(|_| io::ErrorKind::InvalidData)?;
                                let chain = input
                                    .root()
                                    .get("chain")
                                    .and_then(|chain| chain.array())
                                    .ok_or(io::ErrorKind::InvalidData)?
                                    .map(|link| {
                                        let mut link = link.array()?;
                                        let pid = u32::try_from(link.next()?.unsigned()?).ok()?;
                                        Some((pid, link.next()?.unsigned()?))
                                    })
                                    .collect::<Option<Vec<_>>>()
                                    .ok_or(io::ErrorKind::InvalidData)?;
                                let bound = owner.and_then(|owner| owner(&chain));
                                let answer = json::write(&Data::Object(vec![
                                    ("owned", Data::Bool(bound.is_some())),
                                    ("bound", Data::Bool(bound == Some(true))),
                                ]))
                                .map_err(|_| io::ErrorKind::InvalidData)?;
                                peer.output
                                    .push(wire::packet(wire::Kind::Response, 1, &answer).unwrap())
                                    .unwrap();
                                (peer.delivered, peer.answered) = (true, true);
                                reactor.interest(ready.fd, true, true)?;
                                return Ok(false);
                            }
                            let setup = header.id == 2 && header.kind == wire::Kind::Request;
                            let launch = header.id == 3 && header.kind == wire::Kind::Request;
                            if (header.id != 0 && !setup && !launch)
                                || !matches!(header.kind, wire::Kind::Request | wire::Kind::Notify)
                            {
                                return Ok(true);
                            }
                            // A hook message is one JSON document.
                            let message =
                                Json::parse(&peer.input).map_err(|_| io::ErrorKind::InvalidData)?;
                            if header.kind == wire::Kind::Notify
                                && message.root().get("event").and_then(|v| v.string())
                                    == Some("request.closed")
                            {
                                return Ok(true);
                            }
                            // Shared 45 s; a producer extends its own waits with Io::hold.
                            peer.deadline = (!launch).then(|| Instant::now() + Duration::from_secs(45));
                            peer.delivered = true;
                            let section = if launch {
                                "launch".into()
                            } else if setup {
                                let section = message
                                    .root()
                                    .get("section")
                                    .and_then(|v| v.string())
                                    .filter(|s| {
                                        s.strip_prefix("harness/")
                                            .is_some_and(|n| n.parse::<usize>().is_ok())
                                    })
                                    .ok_or(io::ErrorKind::InvalidData)?;
                                format!("setup/{section}")
                            } else {
                                self.routes[&peer.route].section.clone()
                            };
                            events.push((
                                section,
                                Event::Hook {
                                    peer: peer.pid,
                                    route: peer.route,
                                    message: std::mem::take(&mut peer.input),
                                    reply: (header.kind == wire::Kind::Request)
                                        .then_some(peer.token),
                                },
                            ));
                            if header.kind == wire::Kind::Notify {
                                peer.output
                                    .push(wire::packet(wire::Kind::Response, 0, b"{}").unwrap())
                                    .unwrap();
                                peer.answered = true;
                                reactor.interest(ready.fd, true, true)?;
                            }
                        }
                    }
                    Err(e)
                        if matches!(
                            e.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                        ) => {}
                    Err(e) => return Err(e),
                }
            }
            if ready.write {
                if let Some(bytes) = peer.output.front() {
                    match peer.socket.write(bytes) {
                        Ok(0) => return Ok(true),
                        Ok(count) => peer.output.consume(count).unwrap(),
                        Err(e)
                            if matches!(
                                e.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                            ) => {}
                        Err(e) => return Err(e),
                    }
                    if peer.output.front().is_none() {
                        return Ok(true);
                    }
                }
            }
            Ok(false)
        })();
        if !matches!(result, Ok(false)) {
            reactor.interest(ready.fd, false, false)?;
            events.extend(self.remove(ready.fd));
        }
        Ok(events)
    }
}
impl Drop for Hooks {
    fn drop(&mut self) {
        for (token, route) in &self.routes {
            for suffix in ["d", "s"] {
                let _ = storage::remove(&self.anchor, &format!("{token}.{suffix}"));
            }
            if let (Ok(registry), Some(name)) =
                (registry(&route.section), self.directory.file_name())
            {
                let _ = fs::remove_file(registry.join(name));
            }
        }
        let _ = storage::remove(&self.anchor, "lock");
        if storage::same(&self.directory, &self.anchor) {
            // Also removes what the helper wrote there (Io::directory, e.g. startup wrappers).
            let _ = fs::remove_dir_all(&self.directory);
        }
    }
}

use std::os::unix::fs::DirBuilderExt;
