//! helper3 shared API: what the object given to `add_harness`, `add_multiplexer` or `add_plugin`
//! must provide, and the IO the helper gives every part.
//!
//! Parts call each other's methods directly. Multiplexers own terminals; harnesses never hold
//! one. All calls run on the helper's reactor thread and must not block: work that needs IO is
//! submitted through `Io`, its result arrives later in `event`, then the stored `Done` runs.
//! "c1654cc" lines are Dispatch commit c1654cc; "helper2" lines are Helpers/helper2/src.

use std::{
    cell::RefCell,
    io,
    os::fd::RawFd,
    path::{Path, PathBuf},
    process::Command,
    rc::Rc,
    time::Instant,
};

pub type Id = u64;
pub type Shared<T> = Rc<RefCell<T>>;
/// Called exactly once after the part method returns. Use deferred(done) or Io::defer:
/// a timer's event handler still holds the part borrow and is not a safe callback boundary.
pub type Done<T> = Box<dyn FnOnce(&mut dyn Io, Result<T, Error>)>;

/// Wrap a completion once at the caller boundary; part completion only queues its result.
pub fn deferred<T: 'static>(done: Done<T>) -> Done<T> {
    Box::new(move |io, result| io.defer(Box::new(move |io| done(io, result))))
}

/// The app maps `code` to its own text; c1654cc Dispatch/Views/CodeDocumentView.swift:233.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
}

/// A native JSON value; wraps the vendored yyjson document (user decision). Opaque here.
pub use crate::json::Json;

mod control;
pub use control::{Control, ControlTarget, ControlWrite};

// ---- IO the helper gives every part (helper2 shapes) ----
// Every `Io` call and every `Job` goes through system.rs capture/replay.

/// One submitted blocking job; its result comes back as `Event::Done`.
pub type Work = u64;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Process {
    pub pid: u32,
    pub parent: u32,
    pub group: i32,
    pub foreground: i32,
    pub tty: u64,
    pub start: [u64; 2],
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub files: Vec<OpenFile>,
}

/// Identity from the process's open descriptor, never from its pathname (c1654cc
/// process.rs:1030-1051/1580-1637; ChatDiscoveryTests:314-325).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OpenFile {
    pub path: PathBuf,
    pub identity: FileIdentity,
}
impl OpenFile {
    /// Native process/foreground files use the old producer's path/device/inode shape.
    pub fn parse(value: crate::json::Value<'_>) -> Option<Self> {
        Some(Self {
            path: value.get("path")?.string()?.into(),
            identity: FileIdentity {
                device: value.get("device")?.unsigned()?,
                inode: value.get("inode")?.unsigned()?,
            },
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileKind {
    File,
    Directory,
    Symlink,
    Other,
}

/// helper2 system.rs:18-38.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Metadata {
    pub kind: FileKind,
    pub size: u64,
    pub device: u64,
    pub inode: u64,
    pub modified_ns: i128,
    pub changed_ns: i128,
}

/// What a Write/Remove requires at its path when it commits; old ssh-helper hook_file.rs:
/// 95-232 (locked recheck of the original, no links, keep mode and group). Except for Any,
/// the job holds an exclusive lock on the parent directory, refuses a symlink at the path
/// (ELOOP), and rechecks right before publishing: a mismatch fails with EEXIST (Absent) or
/// ESTALE (Same) and nothing changes. A replaced file keeps the original's mode and group.
/// Read, plan, then write with Same(what you read): a concurrent change fails instead of
/// being overwritten. Pass the whole Guard::from(metadata): inode numbers are reused and
/// timestamps are coarse, so a partial guard can match a different file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Expected {
    /// Unchecked (plain atomic replace / remove).
    Any,
    /// Only if nothing exists at the path.
    Absent,
    /// Only if the regular file there still matches.
    Same(Guard),
}

pub enum Job {
    /// Directory names and no-follow kinds; helper2 system.rs:320-343.
    List {
        path: PathBuf,
    },
    /// Follow-aware stat; c1654cc Dispatch/Chat/ToolDocument.swift:154-155.
    Stat {
        path: PathBuf,
        follow: bool,
    },
    /// Bounded read with metadata before/after from the same open file; c1654cc Helpers/ssh-helper/src/files.rs:101-113.
    Read {
        path: PathBuf,
        offset: u64,
        length: u64,
    },
    /// Atomic private file replace (temp + rename); c1654cc Dispatch/Chat/PiChatSetup.swift:84-104.
    /// With `expected` other than Any it is a checked transaction (see Expected).
    Write {
        path: PathBuf,
        bytes: Vec<u8>,
        mode: u32,
        expected: Expected,
    },
    /// Create missing directory components using mode; existing directories are unchanged.
    /// c1654cc Dispatch/Chat/PiChatSetup.swift:90-91.
    MakeDir {
        path: PathBuf,
        mode: u32,
    },
    /// Remove a file, symlink or EMPTY directory; missing paths return NotFound, a non-empty
    /// directory DirectoryNotEmpty. c1654cc Dispatch/Chat/PiChatSetup.swift:102-103,
    /// CodexLauncher.swift:97 (private root).
    Remove {
        path: PathBuf,
        expected: Expected,
    },
    Process {
        pid: u32,
    },
    /// `input` goes to stdin, then stdin closes (EOF); stdout is collected until EOF and exit,
    /// killed with its process group at `deadline` (TimedOut).
    Run {
        command: Command,
        input: Vec<u8>,
        deadline: Instant,
    },
    /// Native input/output are UTF-8 JSON; success returns Output::Bytes. All calls run on
    /// the fixed workers and are captured/replayed. Names below are reserved; an unavailable
    /// platform operation returns Unsupported, never invented facts.
    /// - "file.private": {path,limit} -> {before,after,data:string}; no-follow regular file,
    ///   pinned fd, metadata includes uid/mode/links/kind/size/device/inode/mtime_ns/ctime_ns.
    /// - "file.lstat": {path} -> same metadata (also socket/character-device kinds, tty).
    /// - "file.realpath": {path} -> {path}; canonical absolute path, symlinks resolved.
    /// - "peer": {fd} -> {uid,pid?:u32}; native Unix peer credentials.
    /// - "environment": {pid,names:[string],start?:[u64;2],executable?} -> {name:value}; only
    ///   requested native values; a given start/executable must still be the pid's.
    /// - "foreground": {tty:u64} -> {group:i32,processes:[Process]}; terminal foreground group.
    /// - "process": {pid:u32} -> {pid,uid,parent,group,foreground,tty,start:[u64;2],
    ///   started_at:f64,executable,arguments,files}; started_at is Unix epoch seconds,
    ///   start is the platform's exact process identity (Darwin sec/usec, Linux ticks).
    /// - "process.terminate": {pid,start,executable,tty,foreground} -> bool; false if the
    ///   foreground identity changed, true after its graceful SIGTERM exit. Use Isolated
    ///   to bound the wait; only the named process is signalled, never its group.
    /// - "stats.host": {local:bool} -> {boot,monotonic,cpu?,network?,memoryTotal?,memoryUsed?,
    ///   swapTotal?,swapUsed?,load?,uptime?}; cpu entries {name,busy,total,ticks?:[u32;4]},
    ///   network entries {name,received,sent}. Local ticks preserve native Mach wrap behavior.
    /// - "stats.processes": {local:bool} -> {boot,monotonic,truncated,ps:string} locally;
    ///   remote {boot,monotonic,truncated,processes:[{pid,start,name,cpuNanos,rss}]}.
    /// - "stats.disks": {local:bool} -> {disks:[{identity:string,paths:[string],total,free}]};
    ///   identity is the native signed fsid pair, "word:word". No fabricated identity.
    Native {
        name: &'static str,
        input: Vec<u8>,
    },
    /// A Native job run in its own helper process (`dispatch-helper4 native <name>`), killed
    /// with its process group at `deadline` (TimedOut). For calls that can block in the
    /// kernel (statfs on a hung mount): the reactor and workers stay free. Old ssh-helper
    /// broker.rs:66-82 ran collectors as worker processes with 1 s / 5 s (disks) limits.
    Isolated {
        name: &'static str,
        input: Vec<u8>,
        deadline: Instant,
    },
    /// Exclusive advisory lock on `path` (file created 0600 when missing), retried until
    /// `deadline` (TimedOut). Success is Output::Locked; the System holds the locked fd under
    /// this work id until Io::unlock or helper exit. Old ssh-helper herdr_start.rs:87-107
    /// serialized starters with try_exclusive_lock until a 4 s deadline.
    Lock {
        path: PathBuf,
        deadline: Instant,
    },
}

#[derive(Clone, Debug)]
pub enum Output {
    List(Vec<(String, FileKind)>),
    Metadata(Metadata),
    Read {
        before: Metadata,
        after: Metadata,
        bytes: Vec<u8>,
    },
    /// Successful completion of the entire Write, MakeDir or Remove job, never a partial write.
    Written,
    Process(Process),
    Exit {
        status: Option<i32>,
        stdout: Vec<u8>,
    },
    Bytes(Vec<u8>),
    /// Job::Lock holds its lock; release with Io::unlock(work).
    Locked,
}

pub struct Spawned {
    pub pid: u32,
    /// PTY master, or the child's stdin/stdout when no PTY was asked for.
    pub input: Option<RawFd>,
    pub output: Option<RawFd>,
    /// Separate stderr pipe without a PTY; PTY stderr shares output and returns None.
    pub stderr: Option<RawFd>,
    /// The PTY's terminal device, encoded like Process.tty; None without a PTY.
    pub tty: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Grid {
    pub columns: u16,
    pub rows: u16,
    /// Cell size in pixels when the renderer knows it (PTY ws_xpixel/ypixel, herdr
    /// cell_width_px/cell_height_px; old ssh-helper herdr_terminal.rs:8-94).
    pub pixels: Option<(u16, u16)>,
}

/// One scroll gesture; c1654cc HerdrScroll.swift:4-13,21-24 keeps it apart from pasted bytes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Scroll {
    /// Positive = toward older output.
    pub lines: i64,
    /// Page keys instead of wheel steps.
    pub page: bool,
    /// Pointer cell (column, row) for wheel events.
    pub at: Option<(u16, u16)>,
    /// Modifier bits as the renderer reports them (shift 1, alt 2, control 4).
    pub modifiers: u8,
}

pub enum Address {
    Unix(PathBuf),
    Tcp(std::net::SocketAddr),
}

#[derive(Debug)]
pub enum Event {
    Ready {
        fd: RawFd,
        read: bool,
        write: bool,
    },
    Exit {
        pid: u32,
        status: Option<i32>,
    },
    Timer {
        at: Instant,
    },
    Done {
        work: Work,
        result: io::Result<Output>,
    },
    Changed {
        watch: u64,
        reset: bool,
    },
    Hook {
        /// Native sender PID from socket credentials; None when the transport cannot observe it.
        /// Never inferred from the payload; c1654cc HookReceiver.swift:85-89,124-127.
        peer: Option<u32>,
        route: u64,
        message: Vec<u8>,
        reply: Option<u64>,
    },
    /// The sender of an unanswered interactive hook closed or expired; its `reply` is gone.
    /// c1654cc Dispatch/Chat/HookReceiver.swift:138.
    Closed {
        reply: u64,
    },
    /// An observed process exec'd, forked or exited (`Io::observe`); the mux rescans what it
    /// shows. c1654cc HostProcessWatcher.swift:65-97, helper.md:33.
    Process {
        watch: u64,
        pid: u32,
    },
}

pub trait Io {
    /// Native entropy only; capture/replay preserves the returned bytes.
    fn random(&mut self, _bytes: &mut [u8]) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// Set the capture/event destination, returning the caller's destination. Registered
    /// trait adapters restore it after calls, including mux calls resumed by a harness.
    fn section(&mut self, _name: &str) -> String {
        String::new()
    }
    /// Queue a callback for the reactor to run after the current part method returns.
    fn defer(&mut self, callback: Box<dyn FnOnce(&mut dyn Io)>);
    /// Readiness callbacks for a nonblocking fd; helper2 system.rs:971.
    fn interest(&mut self, fd: RawFd, read: bool, write: bool) -> io::Result<()>;
    /// Nonblocking read from a socket/pipe/PTY; c1654cc Helpers/ssh-helper/src/pi.rs:345-375, Dispatch/Tmux/TmuxSession.swift:108.
    fn read(&mut self, fd: RawFd, bytes: &mut [u8]) -> io::Result<usize>;
    /// Nonblocking write; returns the count actually written; c1654cc Dispatch/Tmux/TmuxSession.swift:174.
    fn write(&mut self, fd: RawFd, bytes: &[u8]) -> io::Result<usize>;
    /// Close an fd this part opened; c1654cc Helpers/ssh-helper/src/pi.rs:345-375.
    fn close(&mut self, fd: RawFd);
    /// Accept one connection on a listener; helper2 system.rs:129.
    fn accept(&mut self, listener: RawFd) -> io::Result<RawFd>;
    /// Private Unix stream listener at `path` (socket 0600); connections via `accept`.
    /// helper2 rpc/transport.rs stream ownership.
    fn listen(&mut self, _path: &Path) -> io::Result<RawFd> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// Half-close the write side of a stream socket; reading continues until the peer's EOF.
    fn shutdown(&mut self, _fd: RawFd) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// Exit callback for a child; helper2 system.rs:1010.
    fn child(&mut self, pid: u32) -> io::Result<()>;
    /// SIGTERM to this part's owned child, without waiting. Exit still arrives once.
    /// c1654cc Dispatch/Chat/ChatSideConnection.swift:180-183.
    fn terminate(&mut self, _pid: u32) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// Forward SIGINT/SIGQUIT to an owned PTY child's current foreground group without
    /// ending the login (c1654cc relay.rs:269-275). An exited child is never signalled.
    fn signal(&mut self, _pid: u32, _signal: i32) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// One `Event::Timer` at the deadline; helper2 system.rs:1008.
    fn timer(&mut self, at: Instant);
    /// Run a callback at the deadline like `defer`, owned by the caller's section, without
    /// delivering a Timer to any part.
    fn after(&mut self, _at: Instant, _callback: Box<dyn FnOnce(&mut dyn Io)>) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// Monotonic now; helper2 system.rs:1671.
    fn now(&self) -> Instant;
    /// This helper's own process id; a replay returns the captured one.
    fn pid(&self) -> u32 {
        std::process::id()
    }
    /// Run a blocking job on the fixed worker pool; helper2 system.rs:1786.
    fn submit(&mut self, job: Job) -> io::Result<Work>;
    /// Drop a job that has not finished; helper2 system.rs:1812.
    fn cancel(&mut self, work: Work) -> bool;
    /// Run `callback` with the job's result instead of delivering its `Event::Done`, owned by
    /// the caller's section like `after`; chains jobs without a private work map. Failures,
    /// including an Io without this capability, reach the callback, so it always runs once
    /// (unless the job is cancelled).
    fn then(&mut self, _work: Work, callback: Box<dyn FnOnce(&mut dyn Io, io::Result<Output>)>) {
        self.defer(Box::new(move |io| {
            callback(io, Err(io::ErrorKind::Unsupported.into()))
        }));
    }
    /// Release a lock held by a finished Job::Lock; best effort like `close`.
    fn unlock(&mut self, _work: Work) {}
    /// Watch a file or directory, `Event::Changed` on change; helper2 watch.rs:45.
    fn watch(&mut self, path: &Path, directory: bool) -> io::Result<u64>;
    /// Stop a watch; helper2 watch.rs:100.
    fn unwatch(&mut self, watch: u64);
    /// Spawn a process, with a PTY when `pty` is set; c1654cc Helpers/ssh-helper/src/pty.rs:15.
    /// It ends with the helper (private servers, clients, side agents).
    fn spawn(&mut self, command: Command, pty: Option<Grid>) -> io::Result<Spawned>;
    /// Spawn a process that outlives the helper: a server users keep (herdr's).
    fn daemon(&mut self, command: Command) -> io::Result<Spawned> {
        self.spawn(command, None)
    }
    /// Resize a PTY master; c1654cc Helpers/ssh-helper/src/pty.rs:39.
    fn resize(&mut self, master: RawFd, grid: Grid) -> io::Result<()>;
    /// Hang up a PTY: close the master so the child gets SIGHUP; c1654cc Helpers/ssh-helper/src/pty.rs:53, 73.
    fn hangup(&mut self, master: RawFd) -> io::Result<()>;
    /// Nonblocking connect; helper2 system.rs:1652.
    fn connect(&mut self, address: &Address) -> io::Result<RawFd>;
    /// Verify an established Unix socket against its preflight file identity and
    /// (uid, pid) peer. WouldBlock means connection readiness is still pending.
    fn verify_socket(&mut self, _fd: RawFd, _path: &Path, _identity: FileIdentity, _peer: (u32, u32)) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// After socket readiness, check SO_ERROR and getpeername before sending bytes;
    /// helper2 system.rs:1564-1582. A returned fd alone does not prove establishment.
    fn connected(&mut self, _fd: RawFd) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// Send one complete nonblocking datagram; no retry or partial-message delivery.
    /// Lifecycle hook transport; helper2 client.rs:68-91. Captured/replayed by System.
    fn datagram(&mut self, _path: &Path, _bytes: &[u8]) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// Private hook endpoint (dir 0700, sockets 0600), `Event::Hook` per message; helper2 runtime.rs:109.
    fn route(&mut self) -> io::Result<(u64, PathBuf)>;
    /// A fresh private hook route for one caller (same 0700/0600 rules, `Event::Hook` to this
    /// section), independent of `route`; c1654cc ChatSideConnection.swift:85-100 owned one IPC
    /// per side connection.
    fn open_route(&mut self) -> io::Result<(u64, PathBuf)> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// End a route from `open_route`: no further hooks, pending replies fail; best effort like
    /// `close`. c1654cc ChatSideConnection.swift:174-185.
    fn close_route(&mut self, _route: u64) {}
    /// The launcher passes the bundled helper's hook command and this private route
    /// to the launched harness, as helper2 runtime.rs:110-124 does. The route ends
    /// with this helper connection; hooks fall back to the native UI when absent.
    /// Answer an interactive hook once; helper2 routes.rs:129.
    fn reply(&mut self, reply: u64, bytes: &[u8]) -> io::Result<()>;
    /// Keep an unanswered interactive hook open until `until` instead of the shared 45s; the
    /// producer chooses its native wait limit; c1654cc HookReceiver.swift:32-34,132-134.
    fn hold(&mut self, _reply: u64, _until: Instant) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// This helper's private 0700 run directory. Files written there (e.g. shell startup
    /// wrappers) live as long as the helper and are removed with it; old ssh-helper
    /// startup.rs:20-70 Storage. Replay returns the captured path.
    fn directory(&mut self) -> io::Result<PathBuf> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// Watch one process for exec/fork/exit (Darwin kqueue; Linux pidfd: exit only) and
    /// deliver `Event::Process` with the returned id; old HostProcessWatcher.swift:65-97.
    /// A stable path to this helper's executable for commands written into agent configs
    /// (hooks): `<home>/.dispatch/h4/bin/dispatch-helper4`, refreshed from the running
    /// executable, so installed hooks survive helper updates (old ssh-helper
    /// hook_file.rs:346-395). Replay returns the captured path.
    fn executable(&mut self) -> io::Result<PathBuf> {
        Err(io::ErrorKind::Unsupported.into())
    }
    /// The account's persistent private directory (`<home>/.dispatch/h4/state`, 0700):
    /// survives helper restarts, unlike `directory()`. For recovery registrations written with
    /// checked writes (old herdr_rpc.rs:297-331, tmux remember/reattach). Replay returns the
    /// captured path.
    fn storage(&mut self) -> io::Result<PathBuf> {
        Err(io::ErrorKind::Unsupported.into())
    }
    fn observe(&mut self, _pid: u32) -> io::Result<u64> {
        Err(io::ErrorKind::Unsupported.into())
    }
    fn unobserve(&mut self, _watch: u64) {}
}

// ---- What parts report to the UI (the helper turns these into wire notifications) ----

/// A terminal subscription's input allowance; replenishment follows committed native writes.
pub struct InputWindow {
    pub terminal: Id,
    pub credit: u32,
}

pub enum Update {
    /// A native command confirmed a conversation change in this process generation.
    /// Internal discovery invalidation; never encoded as a UI notification.
    Identity(Process),
    /// Reevaluate a watched native prompt after provider state changes, without new screen IO.
    Prompt(Binding),
    Topology {
        backend: Id,
        /// Opaque verified backend identity for reopening after this helper exits.
        key: Option<String>,
        nodes: Vec<Node>,
        layouts: Vec<Layout>,
        /// Deepest focused node; its parents give the focused tab and workspace.
        focus: Option<Id>,
    },
    Output {
        terminal: Id,
        bytes: Vec<u8>,
    },
    /// Native controller diagnostics, distinct from terminal VT bytes (SSHProtocolV2Tests.swift:529-539).
    Stderr {
        terminal: Id,
        bytes: Vec<u8>,
    },
    /// Sent once when the terminal's process exits; no output follows; c1654cc Dispatch/SSH/SSHHelperConnection.swift:417-422.
    Exit {
        terminal: Id,
        status: Option<i32>,
    },
    Agent {
        terminal: Id,
        summary: Summary,
    },
    /// Verified foreground client, independent of a harness binding. Registered multiplexers
    /// probe their own native invocation; c1654cc HerdrLaunch.swift:188-257.
    Client {
        terminal: Id,
        process: Process,
    },
    /// Foreground discovery for setup display only; never authorizes chat input.
    Candidate {
        terminal: Id,
        process: Option<Process>,
    },
    Records {
        binding: Binding,
        records: Vec<Record>,
    },
    /// Replace the selected branch, preserving its earlier-page cursor. Records only appends.
    /// c1654cc ChatCoordinator.swift:872-883; the producer observes native branch changes.
    History {
        binding: Binding,
        page: Page,
    },
    State {
        binding: Binding,
        state: State,
    },
    Queue {
        binding: Binding,
        items: Vec<Queued>,
        /// Unsupported selects the held-queue fallback; other errors stay visible to the UI.
        error: Option<Error>,
    },
    Interaction {
        binding: Binding,
        interaction: Interaction,
    },
    Clipboard {
        bytes: Vec<u8>,
    },
    /// Server-side scrollback in rows, offset from the bottom, from a multiplexer that owns it;
    /// c1654cc Dispatch/Herdr/HerdrScrollbar.swift:7-16,87-110.
    Scroll {
        terminal: Id,
        offset: u64,
        max: u64,
        viewport: u32,
    },
}

impl Update {
    /// Publish the full native queue outcome without turning an error into an empty queue.
    pub fn queue(binding: Binding, result: Result<Vec<Queued>, Error>) -> Self {
        let (items, error) = match result {
            Ok(items) => (items, None),
            Err(error) => (Vec::new(), Some(error)),
        };
        Self::Queue {
            binding,
            items,
            error,
        }
    }
}

pub trait Ui {
    fn update(&mut self, update: Update);
    /// Whether a chat observer is open for this exact current binding.
    fn watching(&self, _binding: &Binding) -> bool {
        false
    }
    /// The mux supplies its current binding->terminal mapping for asynchronous harness
    /// updates. Match session plus the exact process pid/start; return None once the terminal
    /// is removed or its process exits. Views may detach while this mapping remains live.
    /// Chat updates carry their Binding; core stamps terminal and session on the wire.
    /// This lookup also recognizes side bindings while their parent remains current.
    fn terminal(&self, _binding: &Binding) -> Option<Id> {
        None
    }
}

// ---- Harness: the object in `h.add_harness(claude)` ----

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    /// Native session id. Empty = provisional: a verified agent TUI before its first turn
    /// has no session yet (old AgentDiscovery.swift:151-156); typed sends still work (the
    /// recheck accepts the same process with its now-known session) and history is empty.
    /// The mux re-identifies a provisional node on its terminal output (one identify in
    /// flight per node) and publishes the known binding in Topology, as the old discovery
    /// moved .provisional to .known.
    pub session: String,
    pub transcript: Option<PathBuf>,
    pub process: Process,
}

pub struct Hook {
    /// The producer chooses whether the shared sender waits for one native reply.
    pub interactive: bool,
    pub event: String,
    pub session: Option<String>,
    pub cwd: Option<PathBuf>,
    pub pid: Option<u32>,
    pub payload: Json,
    /// The native reply when Dispatch takes no decision (hooks off, no app, no binding); empty
    /// makes the sender fail so the agent asks natively. Codex: b"{}".
    pub fallback: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum RecordKind {
    TurnStarted,
    TurnEnded,
    User,
    Assistant,
    Reasoning,
    Tool,
    #[default]
    Notice,
    /// Native command output (`text`), e.g. "Kept model as ...": the app appends it to the
    /// pending typed command's result, not as a chat row (claude K6; old ClaudeTranscript.swift:
    /// 186-273, ChatCoordinator.swift:1066-1071).
    Output,
}

/// Tool file changes already decoded by the harness; no tool JSON parsing in Swift.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Document {
    pub path: String,
    pub kind: Option<DocumentKind>,
    pub diff: String,
    pub workdir: Option<PathBuf>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DocumentKind {
    Add,
    Delete,
    Update,
}

/// c1654cc Dispatch/Chat/ToolOutput.swift:6-10.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Block {
    Code { language: String, text: String },
    Markdown(String),
    Attachment(String),
}

/// Existing normalized row fields; c1654cc Dispatch/Chat/ChatModels.swift:23-37, Dispatch/Chat/PiTranscript.swift:163-188.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Record {
    pub id: String,
    pub turn: Option<String>,
    pub kind: RecordKind,
    pub text: String,
    pub title: String,
    pub output: String,
    pub blocks: Vec<Block>,
    pub completed: bool,
    pub exit_code: Option<i32>,
    pub patch: Option<String>,
    pub documents: Vec<Document>,
    pub tool: Option<Tool>,
    /// Producer-defined presentation; never inferred from an ID prefix by the app.
    pub inline_reasoning: bool,
    pub time_ms: Option<i64>,
    /// Transcript source position; prompt acknowledgement compares this independently of clocks.
    pub position: Option<FilePosition>,
}

mod tool;
pub use tool::{ReadSelection, Tool, ToolRead, ToolSearch, ToolShell};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Page {
    pub records: Vec<Record>,
    pub earlier: Option<String>,
}

mod transcript;
pub use transcript::{Archive, FileIdentity, FilePosition, Snapshot, Transcript};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct State {
    pub busy: bool,
    pub activity: Option<String>,
    pub model: Option<String>,
    /// Display label for `model` from the producer's verified catalog or menu; None shows
    /// the model id. c1654cc ChatModelPicker.swift:74-115.
    pub model_label: Option<String>,
    pub effort: Option<String>,
    /// c1654cc ChatUsage JSON: {info:{total_token_usage:{input_tokens,output_tokens},last_token_usage:{total_tokens},model_context_window,total_cost_usd}}; missing counters remain absent.
    pub usage: Option<String>,
    pub goal: Option<String>,
    pub draft: Option<String>,
    pub attention: Option<String>,
    /// Selected native transcript entry; c1654cc ChatCoordinator.swift:846.
    pub leaf: Option<String>,
    /// Native dialog kind when Terminal is waiting; c1654cc PiBridge.swift:49-60.
    pub dialog: Option<String>,
    /// Native session title; c1654cc ChatCoordinator.swift:888 (session.title = state.name).
    pub title: Option<String>,
    /// Running agent's native version (Claude registry, Codex CLI); the app keeps it per
    /// session, c1654cc ChatCoordinator.swift:1106,1234; old claude.rs:207.
    pub version: Option<String>,
    /// The native side holds accepted input it has not consumed yet (steer/follow-up).
    pub pending: bool,
    /// Native context compaction is running (Claude PreCompact until PostCompact); the app
    /// keeps its own caption. c1654cc ChatCoordinator.swift:795-796.
    pub compacting: bool,
    /// Native service tier (Codex /fast); c1654cc ChatCommands.swift:418-458 (serviceTier).
    pub service_tier: Option<String>,
    /// Native collaboration mode, including the acknowledged /plan setting.
    pub mode: Option<String>,
}

/// A backend's prefix key table (Multiplexer::prefix): raw native key and command strings.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Prefix {
    pub key: Option<String>,
    pub repeat_ms: Option<u64>,
    pub bindings: Vec<PrefixBinding>,
}

/// One prefix binding; `repeat` (tmux -r) repeats without the prefix within repeat_ms.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrefixBinding {
    pub key: String,
    pub command: String,
    pub repeat: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Choice {
    pub id: String,
    pub label: String,
    pub detail: Option<String>,
}

/// c1654cc Dispatch/Chat/ChatSideQuestion.swift:13-21.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Question {
    pub id: String,
    pub header: String,
    pub text: String,
    pub secret: bool,
    pub options: Vec<Choice>,
    pub multiple: bool,
    pub custom: bool,
    /// Complete presentation, e.g. an approval operation as Block::Code with language json;
    /// c1654cc ChatSideConversation.swift:79-85.
    pub blocks: Vec<Block>,
}

/// One approval or a group of questions; `blocking: false` is a Codex async question;
/// c1654cc Dispatch/Chat/ChatSideQuestion.swift:22-27, Dispatch/Chat/ChatCoordinator.swift:395.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Interaction {
    pub id: String,
    /// Stable approval metadata identity when separate requests need distinct decision ids.
    /// Absent when id already identifies both the metadata and the decision.
    pub key: Option<String>,
    /// For approval interactions, normalized option0 allows and option1 denies.
    /// Additional choices and ordinary question indices keep their producer meanings.
    pub approval: bool,
    pub blocking: bool,
    pub questions: Vec<Question>,
    /// The turn and tool record this interaction belongs to (the ids of Record.turn and
    /// Record.id); None when the producer cannot tell. Old app: approval turnID and tool item.
    pub turn: Option<String>,
    pub record: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Answer {
    Options(Vec<usize>),
    Text(String),
    Skip,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Prompt,
    Steer,
    FollowUp,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Sent {
    /// Sent over the harness's own channel.
    Native {
        written: bool,
        may_have_sent: bool,
        reason: Option<String>,
    },
    /// Input for the multiplexer to type after its pane check (`Multiplexer::keys`).
    Keys(Vec<Input>),
}

/// Native result of one composer command (`Harness::command`); app captions stay in the app.
/// `Sent` = delivered on the terminal path without a native result (old command fallback);
/// c1654cc Dispatch/Chat/ChatCommands.swift:292-298,505-507.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    Sent(Sent),
    /// A completed user shell command with its complete output.
    Shell {
        command: String,
        output: String,
        exit_code: Option<i32>,
    },
    /// Stop of all background work was requested (not confirmed finished).
    Stopping,
    /// A native command's result for the user (the old commandResult, e.g. /status 'Session
    /// status' with the session id); c1654cc ChatCommands.swift:418-458.
    Result {
        title: String,
        text: String,
    },
}

/// Terminal input intent; each multiplexer encodes it natively.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Input {
    /// Typed literally, e.g. a slash command.
    Text(String),
    /// Bracketed paste.
    Paste(String),
    Key(Key),
    /// Bytes a renderer or the app produced, typed verbatim (app keys, control streams).
    Raw(Vec<u8>),
}

/// Exactly the keys producers send; c1654cc Dispatch/Herdr/HerdrChat.swift:32-40,92-106.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Enter,
    Escape,
    Up,
    Down,
    Left,
    Right,
}

impl Input {
    /// The terminal bytes producers type today: literal text, bracketed paste, VT keys.
    /// Byte multiplexers write these; others encode Input natively.
    pub fn bytes(inputs: &[Input]) -> Vec<u8> {
        let mut out = Vec::new();
        for input in inputs {
            match input {
                Input::Text(text) => out.extend(text.as_bytes()),
                Input::Raw(bytes) => out.extend(bytes),
                Input::Paste(text) => {
                    out.extend(b"\x1b[200~");
                    out.extend(text.as_bytes());
                    out.extend(b"\x1b[201~");
                }
                Input::Key(key) => out.extend(match key {
                    Key::Enter => b"\r".as_slice(),
                    Key::Escape => b"\x1b",
                    Key::Up => b"\x1b[A",
                    Key::Down => b"\x1b[B",
                    Key::Right => b"\x1b[C",
                    Key::Left => b"\x1b[D",
                }),
            }
        }
        out
    }
}

mod queue;
pub use queue::{Pause, Preview, Queued};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Edit {
    pub path: PathBuf,
    pub before: Option<Vec<u8>>,
    pub after: Option<Vec<u8>>,
    pub backup: Option<PathBuf>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Install {
    pub edits: Vec<Edit>,
    pub restart: bool,
    /// Hooks/extension are currently installed; c1654cc ChatCoordinator.swift:218-220.
    pub installed: bool,
    /// Installation is optional and removable; c1654cc SettingsView.swift:417,429-431.
    pub optional: bool,
    /// Native command that applies an installation without restart; c1654cc SettingsView.swift:415.
    pub reload: Option<String>,
    /// Native command to trust the installation after restart; c1654cc SettingsView.swift:414.
    pub trust: Option<String>,
}

/// What a terminal-menu walk is for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Goal {
    Send {
        text: String,
        mode: Mode,
        command: bool,
    },
    Stop,
    Models,
    Efforts {
        model: String,
    },
    Select {
        model: String,
        effort: Option<String>,
    },
    /// Answer the native prompt `Harness::prompt` reported under `title`: option `choice`, or
    /// dismiss it (None); c1654cc Dispatch/Chat/ChatCommands.swift:578-628 (Up/Down, Enter,
    /// Escape, screen rechecked each step).
    Choose {
        title: String,
        choice: Option<u32>,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Menu {
    pub choices: Vec<Choice>,
    pub current: Option<String>,
    /// The native catalog's default choice, distinct from the current selection.
    pub default: Option<String>,
    /// A typed command's result read from the screen (old /status box, /fast confirmation;
    /// c1654cc ChatCommands.swift:418-458); chat.command answers it as Outcome::Result.
    pub result: Option<(String, String)>,
}

/// Active screen text plus the cursor cell and whether the text after it is faint (Claude's
/// placeholder); c1654cc Dispatch/Terminal/TerminalView+Input.swift:14-18, Dispatch/Terminal/GhosttyTerminal.swift:201-204.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Screen {
    pub text: String,
    pub cursor: (u32, u32),
    pub faint_tail: bool,
}

/// One step of a terminal-menu walk, decided from the current screen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Step {
    Keys(Vec<Input>),
    /// Final input: finish after checked delivery, without another screen observation.
    Submit(Vec<Input>),
    Wait,
    Done(Menu),
    Fail(Error),
    /// Pause for a user decision (e.g. Claude's model-scope confirmation); never auto-approved;
    /// c1654cc Dispatch/Chat/ChatModelPicker.swift:611-615, 620-636.
    Ask(Interaction),
}

pub trait Harness {
    /// Display label; c1654cc Dispatch/Chat/ChatCoordinator.swift:92-125.
    fn name(&self) -> &str;
    /// Stable producer key for persisted drafts and preferences, separate from the label.
    /// c1654cc ChatModels.swift:656-660. Native IDs and labels are never normalized.
    fn key(&self) -> &str {
        self.name()
    }
    /// Pure process-name/argv prefilter; identity is still verified by identify().
    fn matches(&self, _process: &Process) -> bool {
        false
    }
    /// Verified foreground setup metadata, without a conversation or permission to send.
    /// Kept separate from identify so missing/invalid session credentials stay unbound.
    fn candidate(&mut self, io: &mut dyn Io, _process: &Process, done: Done<Option<Error>>) {
        deferred(done)(io, Ok(None));
    }
    /// Prepare a new harness command through Io before the multiplexer spawns it, with the
    /// user's original arguments for a typed launch (UI launches pass none). Completion is
    /// deferred; c1654cc Dispatch/Chat/CodexLauncher.swift:16-62,69-112,144-163.
    fn launch(&mut self, io: &mut dyn Io, cwd: &Path, arguments: &[String], done: Done<Command>);
    /// Typed passthrough commands retain their configuration; managed launches may install hooks.
    fn configures(&self, _arguments: &[String]) -> bool { true }
    /// Run one composer command natively; "unsupported" makes core send it as typed input,
    /// the old terminal path; c1654cc Dispatch/Chat/ChatCommands.swift:292-298,505-507.
    fn command(&mut self, io: &mut dyn Io, binding: &Binding, text: &str, done: Done<Outcome>);
    /// This bound process exited; stop owned launch helpers, without owning a terminal.
    /// c1654cc Dispatch/Chat/CodexLauncher.swift:97,131-138.
    fn exited(&mut self, _io: &mut dyn Io, _process: &Process, _status: Option<i32>) {}
    /// Stop work accepted by the native agent before the helper retires this binding.
    /// The terminal and the agent process stay alive.
    fn revoke(&mut self, io: &mut dyn Io, _binding: &Binding, _retire: bool, done: Done<()>) {
        deferred(done)(io, Ok(()));
    }
    /// Is this process this harness, and which session (open rollout, registration, hook); c1654cc Dispatch/Chat/AgentDiscovery.swift:126-158.
    fn identify(
        &mut self,
        io: &mut dyn Io,
        process: &Process,
        hook: Option<&Hook>,
        done: Done<Option<Binding>>,
    );
    /// Decode one hook message and select interactive transport; the shared sender applies
    /// no payload policy. Lifecycle messages use datagrams; interactive hooks get one stream
    /// reply, then fall back to the native UI on failure. helper2 client.rs:63-91.
    fn hook(&mut self, message: &Json) -> Result<Hook, Error>;
    /// Recent or earlier history; c1654cc Dispatch/Chat/TranscriptReader.swift:274, 363.
    fn history(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        earlier: Option<&str>,
        done: Done<Page>,
    );
    /// Archived transcripts use the same native reader without manufacturing a Binding.
    /// c1654cc TranscriptReader.read(path:sessionID:) and ChatCommands history.
    fn read(&mut self, io: &mut dyn Io, _source: &Transcript, done: Done<Archive>) {
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        );
    }
    /// Current busy/model/usage/goal state; c1654cc Dispatch/Chat/PiBridge.swift:49-60.
    fn state(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<State>);
    /// Slash command names for composer completion; c1654cc Dispatch/Chat/ChatCommands.swift:34.
    fn commands(&self, binding: &Binding) -> Vec<String>;
    /// Send typed input; `command` marks a slash command; c1654cc Dispatch/Chat/AgentDiscovery.swift:6-17, Dispatch/Chat/ChatCoordinator.swift:1750, Dispatch/SSH/SSHAgentService.swift:273-278.
    fn send(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        text: &str,
        mode: Mode,
        command: bool,
        done: Done<Sent>,
    );
    /// Interrupt the current turn; c1654cc Dispatch/Chat/ChatCoordinator.swift:2205.
    fn stop(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<Sent>);
    /// Models through a native API; a terminal-menu harness fails with code "menu" and the core runs `drive(Goal::Models)`; c1654cc Dispatch/Chat/ChatModelPicker.swift:72.
    fn models(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<Menu>);
    /// Efforts for one model, same "menu" rule; c1654cc Dispatch/Chat/ChatModelPicker.swift:190.
    fn efforts(&mut self, io: &mut dyn Io, binding: &Binding, model: &str, done: Done<Menu>);
    /// Apply model and effort, same "menu" rule; c1654cc Dispatch/Chat/ChatModelPicker.swift:132, 217.
    fn select(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        model: &str,
        effort: Option<&str>,
        done: Done<Sent>,
    );
    /// Next menu step from the screen text; c1654cc Dispatch/Chat/ChatModelPicker.swift:231-248.
    /// Screens come as they change and as 40 ms samples (the old picker's sampling, lines
    /// 489-496); `settled` marks the one sample after the 1 s settle bound with no key since,
    /// the old clamped-list end. Wait on a settled screen fails the walk.
    fn menu(&mut self, io: &mut dyn Io, binding: &Binding, goal: &Goal, screen: &Screen, settled: bool) -> Step;
    /// The native prompt on this chat screen, if any (arch.md "Native prompts"): one
    /// interaction with id `prompt:<title>` and the visible choices as one question's options.
    /// Asked on every screen change while a chat is open; answers come back as Goal::Choose.
    /// c1654cc Dispatch/Chat/ChatCommands.swift:104-145, 569-576.
    fn prompt(&mut self, _binding: &Binding, _screen: &Screen) -> Option<Interaction> {
        None
    }
    /// The new state when this chat screen changed it, else None; asked with `prompt`. Claude
    /// names its model only on screen (startup banner, effort footer) until its first reply.
    fn screen_state(&mut self, _binding: &Binding, _screen: &Screen) -> Option<State> {
        None
    }
    /// Answer an approval or question group, keyed by question id; c1654cc Dispatch/Chat/ChatSideQuestion.swift:50-64, 85-95.
    /// Dismissal passes Answer::Skip for every question; the producer applies its native skip.
    fn answer(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        interaction: &str,
        answers: Vec<(String, Answer)>,
        done: Done<Sent>,
    );
    /// Full record of one tool row; c1654cc Dispatch/Chat/ToolOutput.swift:24, Dispatch/Chat/ToolPresentation.swift:4-20.
    fn tool(&mut self, io: &mut dyn Io, binding: &Binding, record: &str, done: Done<Record>);
    /// True only when a verified native producer supports queue operations.
    /// Once enabled, failures never fall back to terminal or the held queue.
    fn native_queue(&self) -> bool {
        false
    }
    /// Native snapshot including producer-issued revisions; c1654cc CodexPatchConnection.swift:587.
    fn queue(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<Vec<Queued>>);
    /// Add to the native queue; c1654cc Dispatch/Chat/CodexPatchConnection.swift:632-641.
    fn queue_add(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        text: &str,
        mode: Mode,
        done: Done<Queued>,
    );
    /// Change one native queue item at its revision (None text = remove); c1654cc Dispatch/Chat/CodexPatchConnection.swift:632.
    fn queue_edit(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        item: &str,
        revision: u64,
        text: Option<&str>,
        done: Done<()>,
    );
    /// Send one queued item now; steer deletes it from the native queue first; c1654cc Dispatch/Chat/CodexPatchConnection.swift:658-681, Helpers/ssh-helper/src/agent_events.rs:70-75.
    fn queue_send(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        item: &str,
        revision: u64,
        mode: Mode,
        done: Done<Sent>,
    );
    /// Reorder the native queue; c1654cc Dispatch/Chat/CodexPatchConnection.swift:644.
    fn queue_order(&mut self, io: &mut dyn Io, binding: &Binding, items: &[String], done: Done<()>);
    /// Ask a side question, read-only or normal; c1654cc Dispatch/Chat/ChatSideConversation.swift:127-146.
    fn side(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        question: &str,
        read_only: bool,
        done: Done<Binding>,
    );
    /// End a side conversation; c1654cc Dispatch/Chat/ChatSideConversation.swift:428-437.
    fn side_close(&mut self, io: &mut dyn Io, side: &Binding, done: Done<()>);
    /// Hook/config edits: None = audit, Some(on) = install or remove; c1654cc Dispatch/Chat/PiChatSetup.swift:84-104, Dispatch/Chat/CodexHookSetup.swift:45.
    /// With `agent`, the target is that running agent's own config root (its environment,
    /// e.g. CODEX_HOME) instead of the helper's account default; c51466a
    /// hook_transport.rs:1055-1077.
    fn install(
        &mut self,
        io: &mut dyn Io,
        route: &Path,
        enabled: Option<bool>,
        agent: Option<&Binding>,
        done: Done<Install>,
    );
    /// Completion of IO this harness submitted.
    fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event);
}

// ---- Multiplexer: the object in `h.add_multiplexer(tmux)` ----

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Workspace,
    Tab,
    Terminal,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Node {
    pub id: Id,
    pub key: String,
    pub parent: Option<Id>,
    pub kind: Kind,
    pub name: String,
    /// Whether the native container name was explicitly assigned.
    pub renamed: Option<bool>,
    pub cwd: Option<PathBuf>,
    pub size: Option<Grid>,
    /// Harness index and session bound to this terminal.
    pub agent: Option<(usize, Binding)>,
    /// The terminal's PTY device (encoded like Process.tty) for app-side attribution of
    /// processes started in it, e.g. ssh launches (c1654cc HostCoordinator.accept).
    pub tty: Option<u64>,
    /// A dismissed node the mux keeps addressable; memberships.place/move restores it.
    pub detached: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Axis {
    Rows,
    Columns,
}

/// Split tree with integer weights; c1654cc Dispatch/Tmux/TmuxLayout.swift:3-12.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Split {
    Leaf(Id),
    Branch {
        id: Id,
        axis: Axis,
        children: Vec<(u32, Split)>,
    },
}

/// Full and visible (zoomed) layout plus focus per container; c1654cc Dispatch/Tmux/TmuxSession.swift:8-11, 301-306, Dispatch/Tmux/TmuxCoordinator.swift:785.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layout {
    pub container: Id,
    pub full: Split,
    pub visible: Split,
    pub focus: Option<Id>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Summary {
    pub waiting: Option<String>,
    pub busy: bool,
    pub activity: Option<String>,
    pub revision: u64,
}

/// Destination of a moved existing node; never a new shell.
/// c1654cc Dispatch/PaneSpace.swift:4-16, Dispatch/Hosts/HerdrHostMoves.swift:189-215.
#[derive(Clone, Debug, PartialEq)]
pub enum Place {
    Restore,
    Extract(String),
    Before { parent: Id, before: Option<Id> },
    Workspace { label: String },
    Tab { workspace: Id, label: String },
    Split { target: Id, axis: Axis, ratio: f64 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Close {
    Prompt,
    Detach,
    Terminate,
}

/// Multiplexer methods never run their `Done` before returning (`drive` relies on it).
/// A mutation's error code `uncertain` means it may have happened (a write was attempted);
/// core never retries it. Any other error means nothing changed.
/// Terminal output is drained from spawn and while detached: unattached output is kept in order
/// (up to 1 MiB, c1654cc ssh-helper relay.rs:8) and delivered on attach; only beyond that does
/// reading pause. An undrained PTY blocks its writers (login, shells, jobs in background tabs).
/// A mutation's `Done` completes only after the topology that reflects it went to `ui.update`;
/// updates are never held past the event that produced them (the app applies a mutation's reply
/// against the topology it already has; integration2 HerdrTests OptimisticCreation, run 33).
pub trait Multiplexer {
    /// Recheck a matching bound process after its native conversation changed.
    fn invalidate(&mut self, _io: &mut dyn Io, _process: &Process) {}
    /// The mux kind shown to the user ("native", "tmux", "herdr"); c1654cc
    /// Dispatch/Views/NewSpaceButton.swift:14-21 ("New tmux space").
    fn name(&self) -> &str;
    /// On disable, forget retained logical workspaces and stop their observers before
    /// acknowledging; leave native servers/panes/processes alive. Publish no retained
    /// topology again until enabled. Core clears cached topology before the public reply.
    fn enable(&mut self, io: &mut dyn Io, _enabled: bool, done: Done<()>) {
        deferred(done)(io, Ok(()));
    }
    /// Recognize this verified client and register an opaque backend key for open().
    /// Core owns no native argv/environment grammar. Defaults decline without IO.
    fn probe(&mut self, io: &mut dyn Io, _process: &Process, done: Done<Option<String>>) {
        deferred(done)(io, Ok(None));
    }
    /// Prepare a typed local client from the owner's verified foreground process. Unsupported
    /// invocations decline; success names the same opaque backend key as passive discovery.
    fn launch(&mut self, io: &mut dyn Io, _process: &Process, done: Done<Option<String>>) {
        deferred(done)(io, Ok(None));
    }
    /// The app keeps a terminal as a shell: this mux's client that the probe found there
    /// (terminal.backend) leaves without ending its backend, so the shell returns (the old
    /// herdr shim's 'shell' answer). Defaults decline.
    fn release(&mut self, io: &mut dyn Io, _client: &Process, done: Done<()>) {
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        );
    }
    /// Verify the foreground process when the renderer reports control Start.
    /// No native grammar is parsed here; the registered claimant owns that decision.
    fn control(&mut self, io: &mut dyn Io, _terminal: Id, done: Done<Process>) {
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        );
    }
    /// Claim a verified terminal stream and expose its ordinary backend route.
    /// Defaults decline. Completion is deferred; write rechecks the source process.
    fn claim(
        &mut self,
        io: &mut dyn Io,
        _process: &Process,
        _write: ControlWrite,
        done: Done<Option<ControlTarget>>,
    ) {
        deferred(done)(io, Ok(None));
    }
    /// Ordered renderer callbacks for the producer's claimed backend. End/Exit
    /// closes that observation; the source mux retains the actual PTY/process.
    /// Err refuses the event: the bytes are no longer this producer's protocol (e.g. after a
    /// transport loss). Core then ends the route and answers that terminals.control event
    /// terminal_unavailable, so the app re-scans the bytes and a new `start` claims afresh
    /// (decisions-1002 "tmux C11").
    fn stream(&mut self, _io: &mut dyn Io, _id: Id, _event: Control) -> Result<(), Error> {
        Ok(())
    }
    /// Harnesses this multiplexer binds terminals to; spec helper.md:119.
    fn harnesses(&mut self, list: Vec<Shared<dyn Harness>>);
    /// Backends installed on this host; c1654cc Dispatch/Views/NewSpaceButton.swift:32.
    fn backends(&mut self, io: &mut dyn Io, done: Done<Vec<String>>);
    /// Attach or start a backend, then report topology via `Update::Topology`; c1654cc Dispatch/Tmux/TmuxCoordinator.swift:471.
    fn open(&mut self, io: &mut dyn Io, key: &str, done: Done<Id>);
    /// New terminal beside another; c1654cc Dispatch/Herdr/HerdrCoordinator.swift:122.
    /// `size`, when the app knows it, is the PTY size before exec (old ssh-helper pty.rs:15-31).
    fn create(
        &mut self,
        io: &mut dyn Io,
        parent: Id,
        beside: Option<Id>,
        command: Option<Command>,
        size: Option<Grid>,
        done: Done<Id>,
    );
    /// Rename a workspace/tab/terminal; c1654cc Dispatch/AppDelegate.swift:406.
    fn rename(&mut self, io: &mut dyn Io, node: Id, name: &str, done: Done<()>);
    /// Focus a node; c1654cc Dispatch/Herdr/HerdrCoordinator.swift:152.
    fn focus(&mut self, io: &mut dyn Io, node: Id, done: Done<()>);
    /// Move a node under another parent; c1654cc Dispatch/Hosts/HerdrHostMoves.swift:186.
    fn r#move(&mut self, io: &mut dyn Io, node: Id, parent: Id, before: Option<Id>, done: Done<()>);
    /// Resize a split; c1654cc Dispatch/Herdr/HerdrLayouts.swift:24, Dispatch/Tmux/TmuxCoordinator.swift:1409.
    fn split(&mut self, io: &mut dyn Io, node: Id, ratio: f64, done: Done<()>);
    /// Zoom one terminal; c1654cc Dispatch/Tmux/TmuxSession.swift:195.
    fn zoom(&mut self, io: &mut dyn Io, terminal: Id, zoomed: bool, done: Done<()>);
    /// Close or detach; c1654cc Dispatch/Hosts/NativeTabClose.swift:6-33.
    fn close(&mut self, io: &mut dyn Io, node: Id, how: Close, done: Done<()>);
    /// Check whether Prompt would close this node without closing, detaching or
    /// changing topology. Unknown inspection is busy; unsupported producers decline.
    /// Used by close.request with check:true for app close/quit confirmation.
    fn idle(&mut self, io: &mut dyn Io, _node: Id, done: Done<bool>) {
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: "Idle check unavailable".into(),
            }),
        );
    }
    /// Start output as VT bytes via `Update::Output`; c1654cc Dispatch/Herdr/HerdrTerminal.swift:18-59, Dispatch/Tmux/TmuxSession.swift:343.
    fn attach(&mut self, io: &mut dyn Io, terminal: Id, size: Grid, takeover: bool, done: Done<()>);
    /// User typing; c1654cc Dispatch/Chat/ChatCoordinator.swift:2016.
    /// Complete only after all bytes reach native stdin; queued or discarded bytes must not renew credit.
    fn input(&mut self, io: &mut dyn Io, terminal: Id, bytes: &[u8], done: Done<()>);
    /// Verify the bound foreground process and tty without sending keys; same pane check
    /// as keys. c1654cc Dispatch/Tmux/TmuxCoordinator.swift:674-680.
    fn check(&mut self, io: &mut dyn Io, terminal: Id, process: &Process, done: Done<()>) {
        let _ = (terminal, process);
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: "Foreground preflight is unavailable".into(),
            }),
        );
    }
    /// Type harness keys only if `process` is still the pane's foreground process on the same tty; c1654cc Helpers/ssh-helper/src/process.rs:416-424, Helpers/ssh-helper/src/tmux.rs:266.
    /// Each mux encodes `input` natively (byte muxes: `Input::bytes`). An error with code
    /// `uncertain` means input may have reached the pane; any other error means nothing was
    /// typed. Core never retries `uncertain`.
    fn keys(
        &mut self,
        io: &mut dyn Io,
        terminal: Id,
        process: &Process,
        input: &[Input],
        done: Done<()>,
    );
    /// Terminal size; c1654cc Dispatch/Tmux/TmuxSession.swift:343.
    fn resize(&mut self, io: &mut dyn Io, terminal: Id, size: Grid, done: Done<()>);
    /// Scroll server-side history; c1654cc Dispatch/Herdr/HerdrScrollbar.swift:105.
    fn scroll(&mut self, io: &mut dyn Io, terminal: Id, scroll: &Scroll, done: Done<()>);
    /// Jump to `offset` rows above the live bottom (scrollbar drag); c1654cc
    /// Dispatch/Herdr/HerdrScrollbar.swift. Producers without server-side history decline.
    fn seek(&mut self, io: &mut dyn Io, _terminal: Id, _offset: u64, done: Done<()>) {
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: "Seek unavailable".into(),
            }),
        );
    }
    /// Move a node to a new workspace, tab or split; c1654cc Dispatch/Hosts/HerdrHostMoves.swift:189-215.
    fn place(&mut self, io: &mut dyn Io, _node: Id, _place: &Place, done: Done<()>) {
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: "Place unavailable".into(),
            }),
        );
    }
    /// Opens sessions/clients that already exist as spaces (tmux, herdr); reported as
    /// `Backend.external`, c1654cc Dispatch/Views/NewSpaceButton.swift:32.
    /// Required (T-EXTERNAL): every mux states it, none inherits a silent false.
    fn external(&self) -> bool;
    /// The backend's own prefix key table, raw native strings (tmux `list-keys -T prefix`, prefix,
    /// repeat-time; herdr config [keys] over its defaults); the app keeps its action mapping.
    /// `node` is any node of the backend. Upstream df8e2fe; old TmuxSession prefix table read.
    fn prefix(&mut self, io: &mut dyn Io, _node: Id, done: Done<Prefix>) {
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: "No native prefix table".into(),
            }),
        );
    }
    /// Run one native command as this backend's client (the app's `.tmux(command)`); the mux
    /// enforces its own allowlist (tmux: single commands with one control reply).
    fn command(&mut self, io: &mut dyn Io, _node: Id, _command: &str, done: Done<()>) {
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: "No native commands".into(),
            }),
        );
    }
    /// Shell command a new terminal runs to start a new session this mux then claims
    /// ("New <name> space"); None when the app cannot start one this way.
    /// c1654cc Dispatch/Views/NewSpaceButton.swift:24-29 (`tmux -CC new-session`, `herdr`).
    fn program(&self) -> Option<String> {
        None
    }
    /// Active screen text now, or after its next change when `changed`; c1654cc Dispatch/Chat/ChatModelPicker.swift:72, 231-248.
    fn screen(&mut self, io: &mut dyn Io, terminal: Id, changed: bool, done: Done<Screen>);
    /// Screen text the app publishes for a terminal it renders itself; c1654cc Dispatch/Chat/ChatCoordinator.swift:2098-2100.
    fn publish(&mut self, io: &mut dyn Io, terminal: Id, screen: Screen);
    /// Completion of IO this multiplexer submitted; also reports `Update::Clipboard`, c1654cc Dispatch/Tmux/TmuxSession.swift:178-191.
    fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event);
}

/// Shows an `Interaction` to the user; the `Done` gets `Harness::answer`'s result.
pub type Ask = Rc<dyn Fn(&mut dyn Io, Interaction, Done<Sent>)>;

pub use crate::menu::drive;

// ---- Plugin: the object in `h.add_plugin(files)` ----

/// None = unavailable; c1654cc Dispatch/Stats/HostMetrics.swift:23-39, 83-111, 147-159.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Sample {
    /// Native boot identity; visible CPU fallback is retained only within this boot.
    pub boot: String,
    /// Native counters were present, even when no interval delta exists.
    pub cpu_present: bool,
    pub cpu: Option<f64>,
    pub cores: Vec<f64>,
    pub load: Vec<f64>,
    pub memory: Option<(u64, u64)>,
    pub swap: Option<(u64, u64)>,
    pub received_per_second: Option<f64>,
    pub sent_per_second: Option<f64>,
    pub uptime: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub pid: u32,
    pub start: Option<String>,
    pub name: String,
    pub cpu: Option<f64>,
    pub rss: Option<u64>,
}

/// One filesystem, all its paths (root and home both shown); c1654cc Helpers/ssh-helper/src/stats.rs:199-202, Dispatch/Stats/SSHStatistics.swift:20-24.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Disk {
    pub identity: u64,
    pub paths: Vec<PathBuf>,
    pub total: u64,
    pub available: u64,
}

mod plugin;
pub use plugin::{Chunk, Guard, Plugin, Read};
