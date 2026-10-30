mod actions;
mod auth;
mod availability;
mod base64;
mod bindings;
mod client;
mod close;
mod control;
mod controller;
mod endpoints;
mod events;
mod hooks;
pub mod input;
mod launch;
pub mod native;
mod observe;
mod ops;
mod prefix;
mod process;
mod readiness;
mod recovery;
mod relay;
mod rpc;
mod screens;
mod startup;
mod transport;

use dispatch_helper_core::{
    api::*,
    json::{self, Data as D, Value},
    wire::body::{self, Encoded},
};
use native::{Decoder, Graph, Snapshot, error, expired, field, text};
use std::{
    collections::{BTreeMap, VecDeque},
    io,
    path::PathBuf,
    process::{Command, Stdio},
    time::{Duration, Instant},
};
use transport::Stream;

/// Resolved local endpoint and the account/environment supplied by its owner.
pub struct Config {
    pub executable: PathBuf,
    pub socket: PathBuf,
    pub session: String,
    pub directory: PathBuf,
    pub environment: BTreeMap<String, String>,
    pub uid: u32,
}
type Action<T = Json> = Box<dyn FnOnce(&mut Herdr, &mut dyn Io, Result<T, Error>)>;
type Deferred = Box<dyn FnOnce(&mut Herdr, &mut dyn Io)>;
type Completion = Box<dyn FnOnce(&mut Herdr, &mut dyn Io, io::Result<Output>)>;
type Bound = (Id, usize, Process, Process, Result<Option<Binding>, Error>);
#[derive(Clone, Copy, PartialEq, Eq)]
enum Order {
    First,
    Normal,
    Background,
}
struct Call {
    background: bool,
    method: String,
    params: Vec<u8>,
    done: Action,
    guard: Option<control::Permit>,
    proof: bool,
    deadline: Option<Instant>,
}
struct Request {
    attempted: bool,
    id: String,
    call: Call,
    stream: Stream,
    deadline: Instant,
    verified: bool,
    connecting: Option<auth::Endpoint>,
}
struct Controller {
    relay: Option<relay::Relay>,
    pid: Option<u32>,
    stream: Option<Stream>,
    stderr: Option<std::os::fd::RawFd>,
    diagnostic: Vec<u8>,
    decoder: Decoder,
    initial: bool,
    pending: Vec<u8>,
    waiters: Vec<Done<()>>,
    retry: Option<Instant>,
    /// Repaints asked for one observer each (terminals.follow, `Herdr::follow_restore`): the next full frame serves
    /// them, a reconnect's first one too.
    restores: Vec<(u64, Done<()>)>,
}
struct Launch {
    workspace: String,
    beside: Option<(String, String)>,
    close: Option<String>,
    command: Command,
    done: Done<Id>,
}

pub struct Herdr {
    integration: BTreeMap<String, String>,
    config: Config,
    shim: Option<PathBuf>,
    backend: Id,
    graph: Graph,
    endpoints: BTreeMap<String, Box<Herdr>>,
    registrations: usize,
    admissions: Vec<recovery::Admission>,
    snapshot: Snapshot,
    origins: BTreeMap<String, actions::Origin>,
    placements: usize,
    harnesses: Vec<Shared<dyn Harness>>,
    agents: BTreeMap<Id, (usize, Binding)>,
    ttys: BTreeMap<Id, u64>,
    hooks: BTreeMap<u64, Option<usize>>,
    hookevents: VecDeque<(usize, Event)>,
    probes: std::collections::BTreeSet<Id>,
    rescans: std::collections::BTreeSet<Id>,
    bindings: Shared<VecDeque<Bound>>,
    calls: VecDeque<Call>,
    request: Option<Request>,
    parked: Option<Request>,
    preparing: bool,
    subscription: Option<Stream>,
    controllers: BTreeMap<Id, Controller>,
    /// `screen` reads every terminal no client publishes for from herdr (observe.rs): the queue drainer; off in a client
    /// helper, whose screens.host clients turn it on per terminal instead.
    host_screens: bool,
    /// Host screen observers by terminal, and when a failed one may start again.
    observers: BTreeMap<Id, observe::Observer>,
    unobserved: BTreeMap<Id, (Instant, u32)>,
    /// Terminals a screens.host client attached: `screen` reads them from herdr (observe.rs) unless published.
    hosting: std::collections::BTreeSet<Id>,
    /// Terminals a client published screens for and keeps attached: only its screens are read
    /// (Multiplexer::screen_clients).
    published: std::collections::BTreeSet<Id>,
    detached: std::collections::BTreeSet<Id>,
    waiting: BTreeMap<Id, readiness::Waiting>,
    changes: u64,
    screens: screens::Screens,
    deferred: VecDeque<Deferred>,
    work: BTreeMap<Work, Completion>,
    notifications: VecDeque<Update>,
    serial: u64,
    owner: Option<auth::Endpoint>,
    pinned: bool,
    generation: u64,
    checking: bool,
    continuation: bool,
    observing: bool,
    refreshing: bool,
    invalidated: bool,
    modern: bool,
    fallback: bool,
    watched: Option<(bool, Vec<String>)>,
    retry: Option<Instant>,
    safety: Option<Instant>,
    boot: Option<(u32, Instant, Done<Id>)>,
    starts: Shared<Vec<Done<Id>>>,
}
impl Herdr {
    pub fn new(mut config: Config) -> Self {
        let integration = client::capability(&config.environment);
        let shim = config
            .environment
            .get("DISPATCH_HERDR_DIRECTORY")
            .map(|directory| PathBuf::from(directory).join("bin").join("herdr"));
        client::clean(&mut config.environment);
        Self {
            integration,
            config,
            shim,
            backend: 1,
            graph: Graph {
                next: std::rc::Rc::new(std::cell::RefCell::new(1)),
                ..Graph::default()
            },
            endpoints: BTreeMap::new(),
            registrations: 0,
            admissions: Vec::new(),
            snapshot: Snapshot::default(),
            origins: BTreeMap::new(),
            placements: 0,
            harnesses: Vec::new(),
            agents: BTreeMap::new(),
            ttys: BTreeMap::new(),
            hooks: BTreeMap::new(),
            hookevents: VecDeque::new(),
            probes: Default::default(),
            rescans: Default::default(),
            bindings: Default::default(),
            calls: VecDeque::new(),
            request: None,
            parked: None,
            preparing: false,
            subscription: None,
            controllers: BTreeMap::new(),
            host_screens: false,
            observers: BTreeMap::new(),
            unobserved: BTreeMap::new(),
            hosting: Default::default(),
            published: Default::default(),
            detached: Default::default(),
            waiting: BTreeMap::new(),
            changes: 0,
            screens: screens::Screens::default(),
            deferred: VecDeque::new(),
            work: BTreeMap::new(),
            notifications: VecDeque::new(),
            serial: 0,
            owner: None,
            pinned: false,
            generation: 0,
            checking: false,
            continuation: false,
            observing: false,
            refreshing: false,
            invalidated: false,
            modern: false,
            fallback: false,
            watched: None,
            retry: None,
            safety: None,
            boot: None,
            starts: Default::default(),
        }
    }
}
