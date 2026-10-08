//! Attach to the existing native conversation without changing its configuration.
use crate::{
    channel::{Channel, Channels, failure, initialize},
    jobs::{self, Jobs},
};
use dispatch_helper_core::{
    api::{Address, Binding, Done, Error, Io, Process, Update, deferred},
    json::{Data, Json, Kind, Value},
};
use std::{cell::RefCell, collections::BTreeMap, net::SocketAddr, path::PathBuf, rc::Rc};

type Ready = Done<Rc<RefCell<Channel>>>;
pub type Fallback = Box<dyn FnOnce(&mut dyn Io, Done<Option<Binding>>)>;

/// The private server discovery may attach to: one this helper started (its pid), or one the
/// typed launch `pid` started; that server becomes known here once verified.
enum Discovery {
    Server(u32),
    Launcher {
        pid: u32,
        servers: crate::launch::Servers,
        foreign: Foreign,
        endpoint: String,
    },
}

/// Endpoints of typed launches' TUIs whose server the launch did not start (the user's own).
type Foreign = Rc<RefCell<std::collections::BTreeSet<String>>>;
type Waiters = Rc<RefCell<BTreeMap<String, Vec<Ready>>>>;

#[derive(Clone, Default)]
pub struct Main {
    pub channels: Channels,
    /// Per TUI (`key`): the discovery connection to a private server that shows no main thread
    /// yet, kept open (c1654cc CodexPatchConnection tracksMainThread): its thread/started binds,
    /// and the next identify lists again over it (a resumed thread starts no thread).
    pub watches: Channels,
    pub snapshots: Rc<RefCell<Vec<(Binding, Json)>>>,
    /// Explicit native replacements, owned by a live identified channel or an open rollout.
    pub replacements: Rc<RefCell<BTreeMap<String, Binding>>>,
    waiters: Waiters,
    foreign: Foreign,
    /// Threads `resumed` read and found to be no main conversation, or is reading now.
    checked: Rc<RefCell<std::collections::BTreeSet<String>>>,
    /// Each thread's latest status as every client hears it (`resumed`).
    statuses: Rc<RefCell<BTreeMap<String, String>>>,
}

/// One TUI process: its pid and start time.
pub fn key(process: &Process) -> String {
    format!("{}:{}:{}", process.pid, process.start[0], process.start[1])
}
impl Main {
    /// The identified private server's main thread, or an explicitly owned native fork,
    /// remains current for the same TUI process regardless of its open rollout files.
    pub(crate) fn current(&self, process: &Process) -> Option<Binding> {
        if let Some(binding) = self.channels.borrow().values().find_map(|channel| {
            let channel = channel.borrow();
            (channel.track_main && channel.identified && !channel.closed
                && channel.binding.process == *process).then(|| channel.binding.clone())
        }) { return Some(binding); }
        let mut replacements = self.replacements.borrow_mut();
        let binding = replacements.get_mut(&key(process))?;
        if binding.process.executable != process.executable
            || binding.process.arguments != process.arguments
            || !self.bound(binding)
        {
            return None;
        }
        binding.process = process.clone();
        self.channels.borrow().get(&binding.session)?.borrow_mut().binding.process = process.clone();
        Some(binding.clone())
    }

    pub fn bound(&self, binding: &Binding) -> bool {
        self.channels
            .borrow()
            .get(&binding.session)
            .is_some_and(|channel| {
                let channel = channel.borrow();
                channel.identified && !channel.closed && channel.binding.process == binding.process
            })
    }
    pub fn notice(&self, channel: &Rc<RefCell<Channel>>, root: Value<'_>, replacing: bool) {
        if root.get("method").and_then(Value::string) != Some("thread/started")
            || !channel.borrow().identified
        {
            return;
        }
        let previous = channel.borrow().binding.clone();
        let thread = root.get("params").and_then(|params| params.get("thread"));
        let replacing = replacing
            && self.channels.borrow().get(&previous.session).is_some_and(|main| Rc::ptr_eq(main, channel))
            && thread.and_then(|thread| thread.get("forkedFromId")).and_then(Value::string) == Some(previous.session.as_str());
        if !channel.borrow().track_main && !replacing { return; }
        let Some(mut binding) = root
            .get("params")
            .and_then(|params| params.get("thread"))
            .and_then(|thread| location(thread, &previous.process))
        else {
            return;
        };
        if previous.session == binding.session {
            return;
        }
        if replacing {
            eprintln!("dispatch-helper: Codex fork pid={} start={:?} parent={} current={}",
                binding.process.pid, binding.process.start, previous.session, binding.session);
            self.replacements.borrow_mut().insert(key(&binding.process), binding.clone());
        } else { binding.transcript = None; }
        self.rebind(channel, &previous.session, binding);
    }
    /// The TUI resumed another conversation (/resume): Codex starts no thread for it, but every
    /// client hears each thread's status, where a load reports idle without a turn's active
    /// first, and the goal snapshot a resume sends (cleared: no goal). A main conversation other
    /// than the bound one heard either way becomes the TUI's, as a started one does in `notice`.
    /// A turn of a conversation the TUI left reports active first: it never takes the TUI back.
    pub fn resumed(&self, io: &mut dyn Io, channel: &Rc<RefCell<Channel>>, root: Value<'_>, updates: Rc<RefCell<Vec<Update>>>) {
        let (Some(method), Some(params)) = (root.get("method").and_then(Value::string), root.get("params")) else {
            return;
        };
        let Some(thread) = params.get("threadId").and_then(Value::string).map(str::to_owned) else {
            return;
        };
        let previous = channel.borrow().binding.clone();
        if !channel.borrow().track_main || !channel.borrow().identified || channel.borrow().closed
            || !self.channels.borrow().get(&previous.session).is_some_and(|main| Rc::ptr_eq(main, channel))
        {
            return;
        }
        let resumed = match method {
            "thread/status/changed" => {
                let status = params.get("status").and_then(|status| status.get("type")).and_then(Value::string);
                let mut statuses = self.statuses.borrow_mut();
                if statuses.len() >= 4096 { statuses.clear(); }
                let before = statuses.insert(thread.clone(), status.unwrap_or_default().to_owned());
                status == Some("idle") && before.is_none_or(|before| before == "notLoaded")
            }
            "thread/closed" => {
                self.statuses.borrow_mut().remove(&thread);
                false
            }
            "thread/goal/cleared" => self.statuses.borrow().get(&thread).is_none_or(|status| status != "active"),
            _ => false,
        };
        // Read once: a thread that is no main conversation never becomes one.
        if !resumed || previous.session == thread || !self.checked.borrow_mut().insert(thread.clone()) {
            return;
        }
        let (main, next, id) = (self.clone(), channel.clone(), thread.clone());
        let params = Data::Object(vec![
            ("threadId", Data::String(&id)),
            ("includeTurns", Data::Bool(false)),
        ]);
        channel.borrow_mut().request(io, "thread/read", params, Box::new(move |io, result| {
            let Ok(document) = result else {
                main.checked.borrow_mut().remove(&thread);
                return;
            };
            let Some(mut binding) = document.root().get("thread")
                .and_then(|value| location(value, &previous.process))
                .filter(|binding| binding.session == thread)
            else {
                return;
            };
            main.checked.borrow_mut().remove(&thread);
            // Only while this channel still serves the conversation the TUI resumed from.
            let current = next.borrow().binding.session.clone();
            if next.borrow().closed || current != previous.session
                || !main.channels.borrow().get(&current).is_some_and(|channel| Rc::ptr_eq(channel, &next))
            {
                return;
            }
            eprintln!("dispatch-helper: Codex resumed pid={} start={:?} previous={} current={}",
                binding.process.pid, binding.process.start, previous.session, binding.session);
            binding.transcript = None;
            let process = binding.process.clone();
            main.rebind(&next, &previous.session, binding);
            updates.borrow_mut().push(Update::Identity(process));
            let now = io.now();
            io.timer(now);
        }));
    }
    /// The TUI's main conversation is now `binding`, served by the same channel.
    fn rebind(&self, channel: &Rc<RefCell<Channel>>, previous: &str, binding: Binding) {
        channel.borrow_mut().binding = binding.clone();
        channel.borrow_mut().ready = false;
        self.watches
            .borrow_mut()
            .retain(|_, watch| !Rc::ptr_eq(watch, channel));
        self.channels.borrow_mut().remove(previous);
        self.channels
            .borrow_mut()
            .insert(binding.session, channel.clone());
    }
    /// Binds a TUI of a private server through the server's main thread: a server this helper
    /// started, or one a typed launch started (`<helper> launch codex` is its own process, core
    /// system/launch.rs; c1654cc CodexLauncherCommand.owns). Any other TUI, and one whose server
    /// shows no main thread yet, is identified by `fallback`.
    pub fn discover(
        &self,
        jobs: Jobs,
        servers: crate::launch::Servers,
        io: &mut dyn Io,
        process: Process,
        done: Done<Option<Binding>>,
        fallback: Fallback,
    ) {
        let Some(endpoint) = argument(&process, "--remote").map(str::to_owned) else {
            return fallback(io, done);
        };
        let known = servers.borrow_mut().get_mut(&endpoint).map(|server| {
            server.process = Some(process.clone());
            server.pid
        });
        let cached = self
            .channels
            .borrow()
            .values()
            .find(|channel| {
                let channel = channel.borrow();
                channel.identified
                    && !channel.closed
                    && channel.binding.process.pid == process.pid
                    && channel.binding.process.start == process.start
            })
            .cloned();
        if let (Some(_), Some(channel)) = (known, cached) {
            return locate(jobs, self.snapshots.clone(), io, channel, done);
        }
        // A server that showed no main thread yet is asked again over the connection kept for it.
        let mut watches = self.watches.borrow_mut();
        watches.retain(|_, watch| !watch.borrow().closed);
        let watch = watches.get(&key(&process)).cloned();
        drop(watches);
        let binding = Binding {
            session: format!("discover:{}", key(&process)),
            transcript: None,
            process: process.clone(),
        };
        let finish: Ready = Box::new(move |io, result| match result {
            Ok(channel) => deferred(done)(io, Ok(Some(channel.borrow().binding.clone()))),
            Err(error) if error.code == "identity" => fallback(io, done),
            Err(error) => deferred(done)(io, Err(error)),
        });
        if let Some(pid) = known {
            let discovery = Some(Discovery::Server(pid));
            return self.begin(jobs, io, binding, discovery, watch, finish);
        }
        if self.foreign.borrow().contains(&endpoint) {
            return finish(io, Err(failure("identity", "Not a private Codex server")));
        }
        let main = self.clone();
        let next = jobs.clone();
        ancestor(
            &jobs,
            io,
            process,
            "--remote",
            endpoint.clone(),
            Rc::new(launch),
            Box::new(move |io, found| match found {
                Some(launcher) => {
                    let discovery = Discovery::Launcher {
                        pid: launcher.pid,
                        servers,
                        foreign: main.foreign.clone(),
                        endpoint,
                    };
                    main.begin(next, io, binding, Some(discovery), None, finish);
                }
                None => finish(io, Err(failure("identity", "Not a private Codex server"))),
            }),
        );
    }

    pub fn open(&self, jobs: Jobs, io: &mut dyn Io, binding: Binding, done: Ready) {
        // A provisional binding (session "", core P1) has no thread to attach to: like the old
        // app without a session, its native requests stay unsupported until the session is known.
        if binding.session.is_empty() {
            let error = failure("unsupported", "Codex has no conversation yet.");
            return deferred(done)(io, Err(error));
        }
        if self.current(&binding.process).is_some_and(|current| current.session != binding.session) {
            eprintln!("dispatch-helper: Codex rejected retired conversation pid={} session={}",
                binding.process.pid, binding.session);
            return deferred(done)(io, Err(failure("closed", "Codex session changed")));
        }
        // The TUI's identified channel serves requests even before it is subscribed (a fresh
        // thread has no rollout to resume yet; identify subscribes once it has): reopening it
        // would tear down the chat's history while it opens (run 135 slice 24608).
        if let Some(channel) = self.channels.borrow().get(&binding.session)
            && (channel.borrow().ready || channel.borrow().identified)
            && !channel.borrow().closed
            && channel.borrow().binding.process == binding.process
        {
            deferred(done)(io, Ok(channel.clone()));
            return;
        }
        // Joining the TUI's discovery in flight gives its channel: it must be this session's.
        let session = binding.session.clone();
        let done: Ready = Box::new(move |io, result| {
            let result =
                result.and_then(
                    |channel| match channel.borrow().binding.session == session {
                        true => Ok(channel.clone()),
                        false => Err(failure("closed", "Codex session changed")),
                    },
                );
            done(io, result)
        });
        self.begin(jobs, io, binding, None, None, done);
    }

    fn begin(
        &self,
        jobs: Jobs,
        io: &mut dyn Io,
        binding: Binding,
        discovery: Option<Discovery>,
        watch: Option<Rc<RefCell<Channel>>>,
        done: Ready,
    ) {
        // One opening per TUI: a chat's request (open) and identify (discovery) of the same
        // process share it, so no second connection replaces the first (run 135 slice 19840).
        let wait = key(&binding.process);
        let mut waiters = self.waiters.borrow_mut();
        let callbacks = waiters.entry(wait.clone()).or_default();
        callbacks.push(deferred(done));
        if callbacks.len() > 1 {
            return;
        }
        drop(waiters);
        if let Some(channel) = self.channels.borrow_mut().remove(&binding.session) {
            let _ = channel
                .borrow_mut()
                .close(io, failure("closed", "Codex session changed"));
        }
        let open = Rc::new(RefCell::new(Open {
            jobs,
            channels: self.channels.clone(),
            watches: self.watches.clone(),
            watch: false,
            waiters: self.waiters.clone(),
            snapshots: self.snapshots.clone(),
            subscribed: false,
            wait,
            key: binding.session.clone(),
            binding,
            discovery,
            sessions: Vec::new(),
            candidates: Vec::new(),
            uid: None,
            resolved: false,
            address: None,
            host: String::new(),
            target: String::new(),
            channel: watch.clone(),
            stage: Stage::Process,
        }));
        if watch.is_some() {
            return open.borrow_mut().list(&open, io);
        }
        let pid = open.borrow().binding.process.pid;
        open.borrow_mut().native(
            &open,
            io,
            Stage::Process,
            "process",
            Data::Object(vec![("pid", Data::Unsigned(pid.into()))]),
        );
    }
}

#[derive(Clone, Copy)]
enum Stage {
    Process,
    Environment,
    Socket,
    /// The socket's directories and the socket itself, through their real paths.
    Directory,
    Private,
    Resolved,
    Peer,
    Server,
    Initialize,
    Loaded,
    Candidate,
    Location,
    Read,
    Resume,
}
struct Open {
    jobs: Jobs,
    channels: Channels,
    watches: Channels,
    /// The server shows no main thread yet: on failure the connection stays as the TUI's watch.
    watch: bool,
    waiters: Waiters,
    snapshots: Rc<RefCell<Vec<(Binding, Json)>>>,
    subscribed: bool,
    /// The TUI's waiter key (Main::begin).
    wait: String,
    binding: Binding,
    key: String,
    discovery: Option<Discovery>,
    sessions: Vec<String>,
    candidates: Vec<Binding>,
    uid: Option<u64>,
    address: Option<Address>,
    /// The socket's real path is known (`address` holds it).
    resolved: bool,
    host: String,
    target: String,
    channel: Option<Rc<RefCell<Channel>>>,
    stage: Stage,
}

impl Open {
    fn native(
        &mut self,
        open: &Rc<RefCell<Self>>,
        io: &mut dyn Io,
        stage: Stage,
        name: &'static str,
        params: Data<'_>,
    ) {
        self.stage = stage;
        let open = open.clone();
        jobs::native(
            &self.jobs,
            io,
            name,
            params,
            Box::new(move |io, result| Self::advance(open, io, result)),
        );
    }

    fn rpc(
        &mut self,
        open: &Rc<RefCell<Self>>,
        io: &mut dyn Io,
        stage: Stage,
        name: &str,
        fields: Vec<(&str, Data<'_>)>,
    ) {
        self.stage = stage;
        let mut params = vec![("threadId", Data::String(&self.binding.session))];
        params.extend(fields);
        let open = open.clone();
        self.channel.as_ref().unwrap().borrow_mut().request(
            io,
            name,
            Data::Object(params),
            Box::new(move |io, result| Self::advance(open, io, result)),
        );
    }

    fn finish(&mut self, io: &mut dyn Io, result: Result<(), Error>) {
        let Some(waiters) = self.waiters.borrow_mut().remove(&self.wait) else {
            return;
        };
        // Only this opening's own channel leaves its key; a channel this one replaces is closed,
        // never left registered without a route (it would wake the helper forever).
        let own = |channels: &mut BTreeMap<String, Rc<RefCell<Channel>>>,
                   key: &str,
                   mine: Option<&Rc<RefCell<Channel>>>| {
            let same =
                |channel: &Rc<RefCell<Channel>>| mine.is_some_and(|m| Rc::ptr_eq(m, channel));
            if channels.get(key).is_some_and(same) {
                channels.remove(key);
            }
        };
        match &result {
            Ok(()) => {
                let channel = self.channel.as_ref().unwrap();
                let mine = |watch: &Rc<RefCell<Channel>>| Rc::ptr_eq(watch, channel);
                self.watches.borrow_mut().retain(|_, watch| !mine(watch));
                channel.borrow_mut().ready = self.subscribed;
                channel.borrow_mut().identified = true;
                channel.borrow_mut().binding = self.binding.clone();
                let mut channels = self.channels.borrow_mut();
                own(&mut channels, &self.key, Some(channel));
                let replaced = channels.insert(self.binding.session.clone(), channel.clone());
                drop(channels);
                if let Some(replaced) = replaced.filter(|replaced| !Rc::ptr_eq(replaced, channel)) {
                    let _ = replaced
                        .borrow_mut()
                        .close(io, failure("closed", "Codex session changed"));
                }
            }
            Err(error) => {
                own(
                    &mut self.channels.borrow_mut(),
                    &self.key,
                    self.channel.as_ref(),
                );
                if let Some(channel) = &self.channel {
                    if self.watch {
                        let mut watch = channel.borrow_mut();
                        watch.identified = true;
                        watch.binding.session = String::new();
                        drop(watch);
                        let previous = self
                            .watches
                            .borrow_mut()
                            .insert(self.wait.clone(), channel.clone());
                        if let Some(previous) = previous.filter(|p| !Rc::ptr_eq(p, channel)) {
                            let _ = previous.borrow_mut().close(io, error.clone());
                        }
                    } else {
                        let _ = channel.borrow_mut().close(io, error.clone());
                    }
                }
            }
        }
        for done in waiters {
            done(
                io,
                result
                    .clone()
                    .map(|_| self.channel.as_ref().unwrap().clone()),
            );
        }
    }

    fn advance(open: Rc<RefCell<Self>>, io: &mut dyn Io, result: Result<Json, Error>) {
        let mut current = open.borrow_mut();
        // No socket: this Codex runs without an app-server (`--no-daemon`, or its server ended).
        // The old app had no native connection then and kept the queue in the app.
        let checking = matches!(
            current.stage,
            Stage::Directory | Stage::Resolved | Stage::Private | Stage::Socket
        );
        let result = result.map_err(|error| match error.code {
            "not_found" if checking => failure("unsupported", "Codex runs without an app-server."),
            _ => error,
        });
        if result.is_err() {
            match current.stage {
                Stage::Candidate => {
                    if let Err(error) = current.candidate(&open, io) {
                        current.finish(io, Err(error));
                    }
                    return;
                }
                Stage::Location => {
                    current.binding.transcript = None;
                    current.subscribe(&open, io);
                    return;
                }
                Stage::Resume
                    if result.as_ref().err().is_some_and(|error| {
                        error.message.starts_with("no rollout found for thread id ")
                    }) =>
                {
                    current.finish(io, Ok(()));
                    return;
                }
                _ => {}
            }
        }
        let result = result.and_then(|value| current.step(&open, io, value));
        if let Err(error) = result {
            current.finish(io, Err(error));
        }
    }

    fn candidate(&mut self, open: &Rc<RefCell<Self>>, io: &mut dyn Io) -> Result<(), Error> {
        if let Some(session) = self.sessions.pop() {
            self.binding.session = session;
            self.rpc(
                open,
                io,
                Stage::Candidate,
                "thread/read",
                vec![("includeTurns", Data::Bool(false))],
            );
        } else {
            if self.candidates.len() != 1 {
                self.watch = self.candidates.is_empty();
                return Err(failure(
                    "identity",
                    "Codex has no unambiguous main conversation",
                ));
            }
            self.binding = self.candidates.pop().unwrap();
            if let Some(path) = self
                .binding
                .transcript
                .as_ref()
                .and_then(|path| path.to_str())
                .map(str::to_owned)
            {
                self.native(
                    open,
                    io,
                    Stage::Location,
                    "file.lstat",
                    Data::Object(vec![("path", Data::String(&path))]),
                );
            } else {
                self.finish(io, Ok(()));
            }
        }
        Ok(())
    }

    /// The server's loaded threads, to find the TUI's main one.
    fn list(&mut self, open: &Rc<RefCell<Self>>, io: &mut dyn Io) {
        self.stage = Stage::Loaded;
        let next = open.clone();
        self.channel.as_ref().unwrap().borrow_mut().request(
            io,
            "thread/loaded/list",
            Data::Object(vec![("limit", Data::Unsigned(100))]),
            Box::new(move |io, result| Self::advance(next, io, result)),
        );
    }

    fn subscribe(&mut self, open: &Rc<RefCell<Self>>, io: &mut dyn Io) {
        self.rpc(
            open,
            io,
            Stage::Resume,
            "thread/resume",
            vec![
                ("excludeTurns", Data::Bool(true)),
                (
                    "initialTurnsPage",
                    Data::Object(vec![
                        ("limit", Data::Unsigned(1)),
                        ("itemsView", Data::String("full")),
                    ]),
                ),
            ],
        );
    }

    fn endpoint(&mut self, value: &str) -> Result<(), Error> {
        if let Some(path) = value.strip_prefix("unix://") {
            if !path.starts_with('/') || path.as_bytes().contains(&0) {
                return Err(failure("endpoint", "Invalid Codex socket"));
            }
            self.address = Some(Address::Unix(PathBuf::from(path)));
            self.host = "localhost".into();
            self.target = "/".into();
            return Ok(());
        }
        let value = value
            .strip_prefix("ws://")
            .ok_or_else(|| failure("endpoint", "Codex endpoint unavailable"))?;
        if value.contains(['@', '#']) {
            return Err(failure("endpoint", "Invalid Codex endpoint"));
        }
        let split = value.find(['/', '?']).unwrap_or(value.len());
        let authority = &value[..split];
        let authority = authority
            .strip_prefix("localhost:")
            .map_or_else(|| authority.to_owned(), |port| format!("127.0.0.1:{port}"));
        let address: SocketAddr = authority
            .parse()
            .map_err(|_| failure("endpoint", "Invalid Codex endpoint"))?;
        if !address.ip().is_loopback() {
            return Err(failure("endpoint", "Codex endpoint is not local"));
        }
        self.address = Some(Address::Tcp(address));
        self.host = value[..split].into();
        self.target = match &value[split..] {
            "" => "/".into(),
            target if target.starts_with('?') => format!("/{target}"),
            target => target.into(),
        };
        Ok(())
    }

    fn connect(&mut self, open: &Rc<RefCell<Self>>, io: &mut dyn Io) -> Result<(), Error> {
        let next = open.clone();
        let channel = Channel::connect(
            io,
            self.binding.clone(),
            self.address.as_ref().unwrap(),
            &self.host,
            &self.target,
            Box::new(move |io, result| {
                let mut open = next.borrow_mut();
                if let Err(error) = result {
                    open.finish(io, Err(error));
                } else if matches!(open.address, Some(Address::Unix(_))) {
                    let fd = open.channel.as_ref().unwrap().borrow().fd();
                    open.native(
                        &next,
                        io,
                        Stage::Peer,
                        "peer",
                        Data::Object(vec![("fd", Data::Signed(fd.into()))]),
                    );
                } else {
                    open.initialize(&next, io);
                }
            }),
        )?;
        let channel = Rc::new(RefCell::new(channel));
        channel.borrow_mut().track_main = self.discovery.is_some();
        self.channels
            .borrow_mut()
            .insert(self.key.clone(), channel.clone());
        self.channel = Some(channel);
        Ok(())
    }

    fn initialize(&mut self, open: &Rc<RefCell<Self>>, io: &mut dyn Io) {
        self.stage = Stage::Initialize;
        let next = open.clone();
        initialize(
            self.channel.as_ref().unwrap().clone(),
            io,
            "dispatch-diff-view",
            Box::new(move |io, result| {
                Self::advance(next, io, result.and_then(|_| Json::parse(b"{}")));
            }),
        );
    }

    /// c51466a agent_events.rs:200-207,264-277: the socket's real directory and the directory
    /// of its real path are ours and not group/other-writable, the real path is our socket, and
    /// the connection goes to that real path.
    fn socket(&mut self, open: &Rc<RefCell<Self>>, io: &mut dyn Io) -> Result<(), Error> {
        let Some(Address::Unix(path)) = &self.address else {
            return self.connect(open, io);
        };
        let parent = path
            .parent()
            .and_then(|parent| parent.to_str())
            .unwrap()
            .to_owned();
        self.path(open, io, Stage::Directory, "file.realpath", &parent);
        Ok(())
    }

    fn path(
        &mut self,
        open: &Rc<RefCell<Self>>,
        io: &mut dyn Io,
        stage: Stage,
        name: &'static str,
        path: &str,
    ) {
        let params = Data::Object(vec![("path", Data::String(path))]);
        self.native(open, io, stage, name, params);
    }

    fn step(
        &mut self,
        open: &Rc<RefCell<Self>>,
        io: &mut dyn Io,
        document: Json,
    ) -> Result<(), Error> {
        let root = document.root();
        match self.stage {
            Stage::Process => {
                let process = jobs::process(root)?;
                if process.pid != self.binding.process.pid
                    || process.start != self.binding.process.start
                    || process.executable != self.binding.process.executable
                    || process.arguments != self.binding.process.arguments
                {
                    return Err(failure("process", "The Codex process changed"));
                }
                self.uid = root.get("uid").and_then(Value::unsigned);
                if self.uid.is_none() {
                    return Err(failure("process", "Codex account unavailable"));
                }
                if process
                    .arguments
                    .iter()
                    .any(|argument| argument.starts_with("--remote-auth-token-env"))
                {
                    return Err(failure(
                        "endpoint",
                        "Authenticated Codex endpoint unavailable",
                    ));
                }
                let endpoint = argument(&process, "--remote").map(str::to_owned);
                if let Some(endpoint) = endpoint {
                    self.endpoint(&endpoint)?;
                    self.socket(open, io)?;
                } else if let Some(home) = self
                    .binding
                    .transcript
                    .as_ref()
                    .and_then(|path| path.to_str())
                    .and_then(|path| {
                        ["/sessions/", "/archived_sessions/"]
                            .into_iter()
                            .find_map(|marker| {
                                path.rsplit_once(marker).map(|(home, _)| home.to_owned())
                            })
                    })
                {
                    self.endpoint(&format!(
                        "unix://{home}/app-server-control/app-server-control.sock"
                    ))?;
                    self.socket(open, io)?;
                } else {
                    self.native(
                        open,
                        io,
                        Stage::Environment,
                        "environment",
                        Data::Object(vec![
                            ("pid", Data::Unsigned(process.pid.into())),
                            (
                                "names",
                                Data::Array(vec![Data::String("CODEX_HOME"), Data::String("HOME")]),
                            ),
                        ]),
                    );
                }
            }
            Stage::Environment => {
                let home = root
                    .get("CODEX_HOME")
                    .and_then(Value::string)
                    .map(str::to_owned)
                    .or_else(|| {
                        root.get("HOME")
                            .and_then(Value::string)
                            .map(|home| format!("{home}/.codex"))
                    })
                    .ok_or_else(|| failure("endpoint", "Codex home unavailable"))?;
                self.endpoint(&format!(
                    "unix://{home}/app-server-control/app-server-control.sock"
                ))?;
                self.socket(open, io)?;
            }
            Stage::Directory | Stage::Resolved => {
                let real = root
                    .get("path")
                    .and_then(Value::string)
                    .map(PathBuf::from)
                    .ok_or_else(|| failure("endpoint", "Codex socket path unavailable"))?;
                let Some(Address::Unix(path)) = &self.address else {
                    unreachable!()
                };
                // The socket in the real directory, then the real socket path.
                let next = if matches!(self.stage, Stage::Directory) {
                    real.join(path.file_name().unwrap())
                } else {
                    self.resolved = true;
                    real.clone()
                };
                self.address = Some(Address::Unix(next));
                let directory = if self.resolved {
                    real.parent().unwrap()
                } else {
                    &real
                };
                self.path(
                    open,
                    io,
                    Stage::Private,
                    "file.lstat",
                    directory.to_str().unwrap(),
                );
            }
            Stage::Private => {
                let mode = root.get("mode").and_then(Value::unsigned).unwrap_or(0o777);
                if root.get("uid").and_then(Value::unsigned) != self.uid
                    || root.get("kind").and_then(Value::string) != Some("directory")
                    || mode & 0o022 != 0
                {
                    return Err(failure("endpoint", "Codex socket directory is not private"));
                }
                let Some(Address::Unix(path)) = &self.address else {
                    unreachable!()
                };
                let path = path.to_str().unwrap().to_owned();
                let (stage, name) = if self.resolved {
                    (Stage::Socket, "file.lstat")
                } else {
                    (Stage::Resolved, "file.realpath")
                };
                self.path(open, io, stage, name, &path);
            }
            Stage::Socket => {
                if root.get("uid").and_then(Value::unsigned) != self.uid
                    || root.get("kind").and_then(Value::string) != Some("socket")
                {
                    return Err(failure("endpoint", "Codex socket owner changed"));
                }
                self.connect(open, io)?;
            }
            Stage::Peer => {
                if root.get("uid").and_then(Value::unsigned) != self.uid {
                    return Err(failure("endpoint", "Codex socket owner changed"));
                }
                let pid = root
                    .get("pid")
                    .and_then(Value::unsigned)
                    .ok_or_else(|| failure("endpoint", "Codex peer unavailable"))?;
                self.native(
                    open,
                    io,
                    Stage::Server,
                    "process",
                    Data::Object(vec![("pid", Data::Unsigned(pid))]),
                );
            }
            Stage::Server => {
                let process = jobs::process(root)?;
                // A typed launch's TUI on some other server is simply not this launch's: plain
                // discovery identifies it.
                let changed = match self.discovery {
                    Some(Discovery::Launcher { .. }) => {
                        failure("identity", "Not the launch's server")
                    }
                    _ => failure("endpoint", "Codex server changed"),
                };
                if process.executable != self.binding.process.executable
                    || process.pid != self.binding.process.pid
                        && !process
                            .arguments
                            .iter()
                            .skip(1)
                            .any(|argument| argument == "app-server")
                {
                    return Err(changed);
                }
                // The server this helper started, or the native server its package wrapper runs.
                if let Some(Discovery::Server(pid)) = self.discovery
                    && pid != process.pid
                {
                    let endpoint = argument(&process, "--listen")
                        .unwrap_or_default()
                        .to_owned();
                    let next = open.clone();
                    let started = Rc::new(move |parent: &Process| parent.pid == pid);
                    ancestor(
                        &self.jobs,
                        io,
                        process,
                        "--listen",
                        endpoint,
                        started,
                        Box::new(move |io, found| {
                            let mut open = next.borrow_mut();
                            match found {
                                Some(_) => open.initialize(&next, io),
                                None => open.finish(io, Err(changed)),
                            }
                        }),
                    );
                    return Ok(());
                }
                let Some(Discovery::Launcher {
                    pid,
                    servers,
                    foreign,
                    endpoint,
                }) = &self.discovery
                else {
                    self.initialize(open, io);
                    return Ok(());
                };
                // The typed launch's own server: started by the same launcher as the TUI.
                let (pid, servers, endpoint) = (*pid, servers.clone(), endpoint.clone());
                let foreign = foreign.clone();
                let (next, server, tui) = (open.clone(), process.pid, self.binding.process.clone());
                let listen = endpoint.clone();
                ancestor(
                    &self.jobs,
                    io,
                    process,
                    "--listen",
                    listen,
                    Rc::new(launch),
                    Box::new(move |io, found| {
                        let mut open = next.borrow_mut();
                        if found.is_some_and(|launcher| launcher.pid == pid) {
                            let process = Some(tui);
                            let known = crate::launch::Server {
                                pid: server,
                                process,
                                owned: false,
                            };
                            servers.borrow_mut().insert(endpoint, known);
                            open.initialize(&next, io);
                        } else {
                            foreign.borrow_mut().insert(endpoint);
                            open.finish(io, Err(changed));
                        }
                    }),
                );
            }
            Stage::Initialize => {
                if self.discovery.is_some() {
                    // c1654cc CodexPatchConnection.swift:427-429: a main-thread connection's attach
                    // timer ends once initialized; it may wait for its thread indefinitely.
                    self.channel.as_ref().unwrap().borrow_mut().attach = None;
                    self.list(open, io);
                    return Ok(());
                }
                self.rpc(
                    open,
                    io,
                    Stage::Read,
                    "thread/read",
                    vec![("includeTurns", Data::Bool(false))],
                );
            }
            Stage::Loaded => {
                if root
                    .get("nextCursor")
                    .is_some_and(|value| value.kind() != Kind::Null)
                {
                    return Err(failure(
                        "identity",
                        "Codex loaded conversations are ambiguous",
                    ));
                }
                self.sessions = root
                    .get("data")
                    .and_then(Value::array)
                    .ok_or_else(|| failure("identity", "Codex loaded conversations unavailable"))?
                    .map(|value| value.string().map(str::to_owned))
                    .collect::<Option<Vec<_>>>()
                    .filter(|ids| ids.len() <= 100)
                    .ok_or_else(|| failure("identity", "Codex loaded conversations unavailable"))?;
                self.candidate(open, io)?;
            }
            Stage::Candidate => {
                if let Some(thread) = root.get("thread")
                    && let Some(binding) = location(thread, &self.binding.process)
                {
                    self.candidates.push(binding);
                }
                self.candidate(open, io)?;
            }
            Stage::Location => {
                if root.get("kind").and_then(Value::string) != Some("file") {
                    self.binding.transcript = None;
                }
                self.subscribe(open, io);
            }
            Stage::Read => {
                let thread = root
                    .get("thread")
                    .ok_or_else(|| failure("thread", "Codex thread unavailable"))?;
                if thread.get("id").and_then(Value::string) != Some(&self.binding.session)
                    || !matches!(
                        thread
                            .get("status")
                            .and_then(|status| status.get("type"))
                            .and_then(Value::string),
                        Some("idle" | "active" | "systemError")
                    )
                {
                    return Err(failure("thread", "Codex thread is not loaded"));
                }
                self.subscribe(open, io);
            }
            Stage::Resume => {
                if root
                    .get("thread")
                    .and_then(|thread| thread.get("id"))
                    .and_then(Value::string)
                    != Some(&self.binding.session)
                {
                    return Err(failure("thread", "Codex thread changed"));
                }
                self.subscribed = true;
                self.snapshots
                    .borrow_mut()
                    .push((self.binding.clone(), document));
                self.finish(io, Ok(()));
            }
        }
        Ok(())
    }
}

/// The value of `flag` (`flag value` or `flag=value`) before any `--`.
fn argument<'a>(process: &'a Process, flag: &str) -> Option<&'a str> {
    for (index, argument) in process.arguments.iter().enumerate().skip(1) {
        if argument == "--" {
            break;
        }
        if argument == flag {
            return process.arguments.get(index + 1).map(String::as_str);
        }
        if let Some(value) = argument
            .strip_prefix(flag)
            .and_then(|rest| rest.strip_prefix('='))
        {
            return Some(value);
        }
    }
    None
}

/// The ancestor of `process` that `owns` it, reached through wrappers in its process group that
/// pass the same `flag endpoint` on (npm's codex.js spawns the native binary instead of replacing
/// itself), at most eight levels up; c1654cc CodexLauncherCommand.launcher. Any other ancestry
/// is None.
fn ancestor(
    jobs: &Jobs,
    io: &mut dyn Io,
    process: Process,
    flag: &'static str,
    endpoint: String,
    owns: Rc<dyn Fn(&Process) -> bool>,
    done: Box<dyn FnOnce(&mut dyn Io, Option<Process>)>,
) {
    walk(jobs, io, process, flag, endpoint, owns, 8, done);
}

#[allow(clippy::too_many_arguments)]
fn walk(
    jobs: &Jobs,
    io: &mut dyn Io,
    process: Process,
    flag: &'static str,
    endpoint: String,
    owns: Rc<dyn Fn(&Process) -> bool>,
    levels: usize,
    done: Box<dyn FnOnce(&mut dyn Io, Option<Process>)>,
) {
    if levels == 0 {
        return done(io, None);
    }
    let next = jobs.clone();
    let pid = Data::Object(vec![("pid", Data::Unsigned(process.parent.into()))]);
    jobs::native(
        jobs,
        io,
        "process",
        pid,
        Box::new(move |io, result| {
            let Ok(parent) = result.and_then(|value| jobs::process(value.root())) else {
                return done(io, None);
            };
            if owns(&parent) {
                return done(io, Some(parent));
            }
            if parent.group != process.group || argument(&parent, flag) != Some(&endpoint) {
                return done(io, None);
            }
            walk(&next, io, parent, flag, endpoint, owns, levels - 1, done);
        }),
    );
}

/// A typed launch: `<helper> launch codex` (core system/launch.rs).
fn launch(process: &Process) -> bool {
    process.arguments.get(1..3) == Some(&["launch".to_owned(), "codex".to_owned()])
}

/// The TUI's main conversation a native thread object stands for, if any (user thread, not
/// ephemeral, no parent); c1654cc CodexPatchConnection.swift:499-507 mainLocation.
pub fn location(thread: Value<'_>, process: &Process) -> Option<Binding> {
    let id = thread.get("id")?.string()?;
    let source = thread.get("source")?.string()?;
    let user = thread.get("threadSource").and_then(Value::string) == Some("user")
        || source == "cli"
            && thread
                .get("threadSource")
                .is_none_or(|value| value.kind() == Kind::Null);
    if !crate::hooks::uuid(id)
        || !["cli", "vscode", "exec"].contains(&source)
        || thread.get("ephemeral").and_then(Value::boolean) != Some(false)
        || !user
        || thread
            .get("parentThreadId")
            .is_some_and(|value| value.kind() != Kind::Null)
    {
        return None;
    }
    Some(Binding {
        session: id.to_owned(),
        transcript: thread
            .get("path")
            .and_then(Value::string)
            .filter(|path| path.starts_with('/') && path.ends_with(".jsonl"))
            .map(PathBuf::from),
        process: process.clone(),
    })
}

pub(super) fn locate(
    jobs: Jobs,
    snapshots: Rc<RefCell<Vec<(Binding, Json)>>>,
    io: &mut dyn Io,
    channel: Rc<RefCell<Channel>>,
    done: Done<Option<Binding>>,
) {
    let binding = channel.borrow().binding.clone();
    if binding.transcript.is_some() && channel.borrow().ready {
        deferred(done)(io, Ok(Some(binding)));
        return;
    }
    let session = binding.session.clone();
    let next = channel.clone();
    let params = Data::Object(vec![
        ("threadId", Data::String(&session)),
        ("includeTurns", Data::Bool(false)),
    ]);
    channel.borrow_mut().request(
        io,
        "thread/read",
        params,
        Box::new(move |io, result| {
            let updated = result
                .ok()
                .and_then(|document| {
                    document
                        .root()
                        .get("thread")
                        .and_then(|thread| location(thread, &binding.process))
                })
                .filter(|next| next.session == binding.session);
            let Some(updated) = updated.filter(|binding| binding.transcript.is_some()) else {
                deferred(done)(io, Ok(Some(binding)));
                return;
            };
            let path = updated.transcript.clone().unwrap();
            jobs::submit(
                &jobs,
                io,
                dispatch_helper_core::api::Job::Stat { path, follow: true },
                Box::new(move |io, result| {
                    let readable = matches!(result, Ok(dispatch_helper_core::api::Output::Metadata(metadata))
                        if metadata.kind == dispatch_helper_core::api::FileKind::File);
                    if !readable {
                        deferred(done)(io, Ok(Some(binding)));
                        return;
                    }
                    let session = updated.session.clone();
                    let channel = next.clone();
                    let params = Data::Object(vec![
                        ("threadId", Data::String(&session)),
                        ("excludeTurns", Data::Bool(true)),
                        (
                            "initialTurnsPage",
                            Data::Object(vec![
                                ("limit", Data::Unsigned(1)),
                                ("itemsView", Data::String("full")),
                            ]),
                        ),
                    ]);
                    next.borrow_mut().request(
                        io,
                        "thread/resume",
                        params,
                        Box::new(move |io, result| {
                            match result {
                                Ok(document)
                                    if document
                                        .root()
                                        .get("thread")
                                        .and_then(|thread| thread.get("id"))
                                        .and_then(Value::string)
                                        == Some(&updated.session) =>
                                {
                                    channel.borrow_mut().binding = updated.clone();
                                    channel.borrow_mut().ready = true;
                                    snapshots.borrow_mut().push((updated.clone(), document));
                                    deferred(done)(io, Ok(Some(updated)));
                                }
                                _ => deferred(done)(io, Ok(Some(binding))),
                            }
                        }),
                    );
                }),
            );
        }),
    );
}
