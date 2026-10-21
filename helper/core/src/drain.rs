//! `dispatch-helper queue-drain`: sends what the host's queue store holds once no client is
//! connected. A helper that ends with stored, sendable queues starts it (`Io::daemon`); one runs
//! per account (a lock in the store directory).
//!
//! It is a client, not a helper: it runs an ordinary helper (`--stdio --drain`), opens the
//! backends the stored conversations name, and keeps a chat open on each conversation whose
//! agent it finds. That helper's own queue drain sends, exactly as for a connected app; the
//! agent's screen comes from its multiplexer (no app renders it). It ends once nothing stored is
//! sendable to an agent it can reach.
use crate::{
    dispatch::store::{self, Record},
    json::Data,
    wire::{self, Collector, Header, Kind, Received, body},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::{self, Read, Write},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::{Path, PathBuf},
    process::{ChildStdin, Command, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};

/// How often the store is read again.
const SCAN: Duration = Duration::from_secs(5);
/// Scans in a row with nothing to send before the drainer ends (agents need a moment to be
/// discovered after their backend opens).
const QUIET: u32 = 3;
/// Longest a drainer runs.
const LIFETIME: Duration = Duration::from_secs(24 * 60 * 60);
/// Longest wait for one answer from the helper.
const ANSWER: Duration = Duration::from_secs(30);

/// The store directory: `<account>/.dispatch/state/queue`.
pub fn directory() -> io::Result<PathBuf> {
    Ok(crate::system::storage_root()?.join(store::DIRECTORY))
}

/// Stored conversations that still have something to send, with when each file last changed.
fn sendable(directory: &Path) -> Vec<(Record, std::time::SystemTime)> {
    let Ok(entries) = fs::read_dir(directory) else { return Vec::new() };
    let uid = crate::system::System::account().map(|(uid, _)| uid).ok();
    let mut records: Vec<(Record, std::time::SystemTime)> = entries
        .flatten()
        .filter(|entry| entry.file_name().to_str().is_some_and(|name| name.ends_with(".q")))
        .filter_map(|entry| {
            use std::os::unix::fs::MetadataExt;
            let file = fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc_nofollow())
                .open(entry.path())
                .ok()?;
            let metadata = file.metadata().ok()?;
            if !metadata.is_file()
                || Some(metadata.uid()) != uid
                || metadata.mode() & 0o077 != 0
                || metadata.nlink() != 1
                || metadata.len() > store::LIMIT
            {
                return None;
            }
            let mut bytes = Vec::new();
            (&file).take(store::LIMIT).read_to_end(&mut bytes).ok()?;
            Some((Record::decode(&bytes).ok()?, metadata.modified().ok()?))
        })
        .filter(|(record, _)| record.sendable() && record.mux != "native")
        .collect();
    records.sort_by(|(a, _), (b, _)| (&a.mux, &a.terminal, &a.session).cmp(&(&b.mux, &b.terminal, &b.session)));
    records
}

#[cfg(target_os = "macos")]
fn libc_nofollow() -> i32 {
    0x0100
}
#[cfg(not(target_os = "macos"))]
fn libc_nofollow() -> i32 {
    0o400000
}

unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
    fn setsid() -> i32;
}
const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;
const LOCK_UN: i32 = 8;

/// The account's one drainer: held while it runs, never waited for.
struct Lock(fs::File);

impl Lock {
    fn take(directory: &Path) -> io::Result<Option<Self>> {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new().recursive(true).mode(0o700).create(directory)?;
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc_nofollow())
            .open(directory.join("drain.lock"))?;
        Ok(Self::again(file))
    }
    fn again(file: fs::File) -> Option<Self> {
        // SAFETY: flock on a descriptor this function owns.
        (unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } == 0).then_some(Self(file))
    }
    fn release(self) -> fs::File {
        // SAFETY: as above.
        unsafe { flock(self.0.as_raw_fd(), LOCK_UN) };
        self.0
    }
}

/// A message from the helper: (kind, request id, body).
type Frame = (Kind, u64, body::Encoded);

struct Helper {
    child: std::process::Child,
    input: ChildStdin,
    frames: mpsc::Receiver<Frame>,
    serial: u64,
    /// The helper's output ended (it exited, or sent what this client cannot read).
    closed: bool,
    /// Nodes by topology key: (node id, agent session if one is bound).
    nodes: BTreeMap<String, (u64, Option<String>)>,
}

impl Helper {
    fn start(program: &Path, arguments: &[std::ffi::OsString]) -> io::Result<Self> {
        let mut child = Command::new(program)
            .args(["--stdio", "--drain"])
            .args(arguments)
            // Its helper is no test's: nothing it does belongs to a recording.
            .env_remove("DISPATCH_CAPTURE")
            .env_remove("DISPATCH_REPLAY")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let (input, mut output) = (child.stdin.take().unwrap(), child.stdout.take().unwrap());
        let (sender, frames) = mpsc::channel();
        std::thread::spawn(move || {
            let mut collectors: BTreeMap<u64, Collector> = BTreeMap::new();
            loop {
                let mut head = [0; 13];
                if output.read_exact(&mut head).is_err() {
                    return;
                }
                let Ok(header) = Header::decode(&head, wire::LIMIT) else { return };
                let mut bytes = vec![0; header.len as usize];
                if output.read_exact(&mut bytes).is_err() {
                    return;
                }
                let collector = collectors
                    .entry(header.id)
                    .or_insert_with(|| Collector::new(header.id, wire::LIMIT as usize));
                match collector.push(header, &bytes) {
                    Ok(Some(Received::Value(value))) => {
                        collectors.remove(&header.id);
                        if sender.send((header.kind, header.id, value)).is_err() {
                            return;
                        }
                    }
                    Ok(Some(Received::Binary { .. })) => {
                        collectors.remove(&header.id);
                    }
                    Ok(None) => {}
                    Err(_) => return,
                }
            }
        });
        Ok(Self { child, input, frames, serial: 0, closed: false, nodes: BTreeMap::new() })
    }

    fn send(&mut self, method: &str, params: Data<'_>) -> io::Result<u64> {
        self.serial += 1;
        let body = body::encode(&Data::Object(vec![("method", Data::String(method)), ("params", params)]))
            .map_err(|error| io::Error::other(error.message))?;
        let frame = wire::packet(Kind::Request, self.serial, &body).map_err(|_| io::Error::other("frame"))?;
        self.input.write_all(&frame)?;
        Ok(self.serial)
    }

    /// Note what a frame says about the topology.
    fn file(&mut self, value: &body::Encoded) {
        let root = value.root();
        if root.get("method").and_then(Data::string) != Some("topology") {
            return;
        }
        let Some(nodes) = root.get("params").and_then(|params| params.get("nodes")).and_then(Data::array) else {
            return;
        };
        for node in nodes {
            let (Some(id), Some(key)) = (node.get("id").and_then(Data::unsigned), node.get("key").and_then(Data::string)) else {
                continue;
            };
            let session = node.get("agent").and_then(|agent| agent.get("session")).and_then(Data::string).map(str::to_owned);
            self.nodes.insert(key.to_owned(), (id, session));
        }
    }

    /// Messages until `deadline`, filing topology; the frame answering `id` (or its named notice).
    fn wait(&mut self, id: Option<u64>, notice: Option<&str>, deadline: Instant) -> Option<body::Encoded> {
        loop {
            let left = deadline.checked_duration_since(Instant::now())?;
            let (kind, from, value) = match self.frames.recv_timeout(left) {
                Ok(frame) => frame,
                Err(mpsc::RecvTimeoutError::Timeout) => return None,
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    self.closed = true;
                    return None;
                }
            };
            self.file(&value);
            if Some(from) != id {
                continue;
            }
            let named = value.root().get("method").and_then(Data::string).map(str::to_owned);
            if kind == Kind::Response || (notice.is_some() && named.as_deref() == notice) {
                return Some(value);
            }
        }
    }

    fn call(&mut self, method: &str, params: Data<'_>) -> Option<body::Encoded> {
        let id = self.send(method, params).ok()?;
        self.wait(Some(id), None, Instant::now() + ANSWER)
    }

    /// Open every backend of the multiplexers the stored conversations name, when they run.
    fn open(&mut self, wanted: &BTreeSet<String>, opened: &mut BTreeSet<(u64, String)>) {
        let Some(listed) = self.call("multiplexers.list", Data::Object(Vec::new())) else { return };
        let multiplexers: Vec<(u64, String, bool)> = listed
            .root()
            .get("result")
            .and_then(Data::array)
            .into_iter()
            .flatten()
            .filter_map(|row| {
                let mux = row.get("mux").and_then(Data::unsigned)?;
                let name = row.get("name").and_then(Data::string)?.to_owned();
                // Never start a server: only one that runs (herdr's open would start one).
                let running = row.get("running").and_then(Data::boolean).unwrap_or(false);
                Some((mux, name, running))
            })
            .collect();
        for (mux, name, running) in multiplexers {
            if !wanted.contains(&name) || !running {
                continue;
            }
            let Some(keys) = self.call("backends.list", Data::Object(vec![("mux", Data::Unsigned(mux))])) else { continue };
            let keys: Vec<String> = keys
                .root()
                .get("result")
                .and_then(Data::array)
                .into_iter()
                .flatten()
                .filter_map(|key| key.string().map(str::to_owned))
                .collect();
            for key in keys {
                if !opened.insert((mux, key.clone())) {
                    continue;
                }
                let params = Data::Object(vec![("mux", Data::Unsigned(mux)), ("key", Data::String(&key))]);
                if let Ok(id) = self.send("backends.open", params) {
                    self.wait(Some(id), Some("backend.opened"), Instant::now() + ANSWER);
                }
            }
        }
    }
}

/// Run the drainer; `arguments` are the helper's multiplexer options.
pub fn run(program: &Path, arguments: &[std::ffi::OsString]) -> io::Result<i32> {
    // SAFETY: setsid in a process that is not a group leader detaches it from the session whose
    // hangup ended the helper that started it.
    unsafe { setsid() };
    let directory = directory()?;
    let Some(mut lock) = Lock::take(&directory)? else { return Ok(0) };
    let started = Instant::now();
    let mut helper = Helper::start(program, arguments)?;
    let hello = Data::Object(vec![("features", Data::Array(vec![Data::String("multiplexers.versions")]))]);
    if helper.call("hello", hello).is_none() {
        return Err(io::Error::other("the helper did not answer"));
    }
    let mut opened = BTreeSet::new();
    let mut chats: BTreeSet<(u64, String)> = BTreeSet::new();
    let mut quiet = 0;
    // When the current run of quiet scans began: a file changed since then is news.
    let mut since = std::time::SystemTime::now();
    loop {
        if helper.closed || helper.child.try_wait()?.is_some() {
            break;
        }
        let records = sendable(&directory);
        let found = |helper: &Helper, record: &Record| {
            helper.nodes.get(&record.terminal).is_some_and(|(_, session)| session.as_deref() == Some(record.session.as_str()))
        };
        // Backends are listed again only while a stored conversation is not found (a new tmux session).
        if records.iter().any(|(record, _)| !found(&helper, record)) {
            let wanted: BTreeSet<String> = records.iter().map(|(record, _)| record.mux.clone()).collect();
            helper.open(&wanted, &mut opened);
        }
        let mut reachable = 0;
        for (record, _) in &records {
            let Some((node, Some(session))) = helper.nodes.get(&record.terminal).cloned() else { continue };
            if session != record.session {
                continue;
            }
            reachable += 1;
            if !chats.contains(&(node, session.clone())) {
                // Kept open only once the helper opened it: a refused open is tried on the next scan.
                let params = Data::Object(vec![("terminal", Data::Unsigned(node)), ("session", Data::String(&session))]);
                if let Ok(id) = helper.send("chat.open", params)
                    && helper
                        .wait(Some(id), Some("chat.history"), Instant::now() + ANSWER)
                        .is_some_and(|answer| answer.root().get("error").is_none())
                {
                    chats.insert((node, session));
                }
            }
        }
        if reachable == 0 {
            if quiet == 0 {
                since = std::time::SystemTime::now();
            }
            quiet += 1;
        } else {
            quiet = 0;
        }
        if quiet >= QUIET || started.elapsed() >= LIFETIME {
            // Let go of the lock, then look once more: a helper that ended meanwhile found it held
            // and left its queue to this drainer (its file changed during the quiet scans).
            let file = lock.release();
            let again = sendable(&directory)
                .iter()
                .any(|(record, modified)| *modified >= since || found(&helper, record));
            match (again && started.elapsed() < LIFETIME).then(|| Lock::again(file)).flatten() {
                Some(taken) => {
                    lock = taken;
                    quiet = 0;
                }
                None => break,
            }
        }
        // Answers and notifications meanwhile (state, records, topology).
        helper.wait(None, None, Instant::now() + SCAN);
    }
    drop(helper.input);
    let status = helper.child.wait()?;
    Ok(status.code().unwrap_or(0))
}
