use crate::{api::*, json::Json, system::System, wire};
use std::{
    cell::{Cell, RefCell},
    collections::{BTreeMap, BTreeSet, VecDeque},
    io,
    os::fd::RawFd,
    path::Path,
    rc::Rc,
    time::{Duration, Instant},
};

pub(crate) type Replies = Rc<RefCell<VecDeque<(RawFd, wire::Kind, u64, Vec<u8>)>>>;
pub(crate) type Drains = Rc<RefCell<VecDeque<(RawFd, u64, Done<()>)>>>;
mod client;
pub(crate) mod candidate;
pub(crate) mod login;
use client::Client;
/// The largest frame: a chunk (21-byte header + CHUNK) or an inline message (<= CHUNK + 13).
const FRAME: usize = wire::CHUNK + 21;
/// Per-client admitted output: a few frames keep the pipe busy, while a reply waits behind at
/// most these bytes, not behind tens of MB of terminal output (arch.md Benchmarks).
const OUTPUT: usize = 4 * FRAME;
/// A login whose shell exited while bus clients remained detaches and keeps serving them, but
/// only while they talk: after this long without client traffic it exits, so a stray client
/// cannot hold a sessionless helper open indefinitely.
const DETACHED_IDLE: Duration = Duration::from_secs(24 * 60 * 60);
/// Timer section of the detached login's idle deadline.
const DETACHED: &str = "login.detached";

#[derive(Clone)]
enum Scope {
    Backend(usize),
    Terminal(Id),
    /// terminals.observe: claims, agent changes and exit of one terminal, never its output.
    Events(Id),
    Chat(Id, String),
    /// chat.open {transcript}: its own followed archive (DispatchHelper::archives).
    Archive,
    /// terminals.create with a size, until the created terminal is adopted.
    Created,
}
type Observer = (RawFd, u64, Scope);

pub struct DispatchHelper {
    /// Existing SSH feature selections; None is the local helper.
    pub permissions: Rc<RefCell<Option<BTreeSet<String>>>>,
    pub(crate) admitted: BTreeMap<(RawFd, u64), (Vec<&'static str>, Rc<Cell<bool>>)>,
    /// Bound startup shell, also used when a terminal request supplies only cwd.
    pub shell: std::path::PathBuf,
    pub(crate) execution: Vec<std::ffi::OsString>,
    pub(crate) default: Option<(usize, String)>,
    pub(crate) harnesses: Vec<Shared<dyn Harness>>,
    pub(crate) multiplexers: Vec<Shared<dyn Multiplexer>>,
    pub(crate) plugins: Vec<Shared<dyn Plugin>>,
    pub(crate) nodes: crate::dispatch::Nodes,
    scopes: Rc<RefCell<BTreeMap<(usize, Id), BTreeSet<Id>>>>,
    /// Live terminals whose verified conversation ended; cleared by rebinding/removal.
    pub(crate) retired: Rc<RefCell<BTreeSet<Id>>>,
    pub(crate) unavailable: Vec<String>,
    pub(crate) questions: crate::dispatch::Questions,
    pub(crate) interactions: crate::dispatch::Interactions,
    pub(crate) adoptions: crate::dispatch::Adoptions,
    pub(crate) held: crate::dispatch::Held,
    pub(crate) commands: crate::dispatch::Commands,
    pub(crate) creations: crate::dispatch::Creations,
    pub(crate) backends: Rc<RefCell<BTreeSet<(usize, Id)>>>,
    pub(crate) resets: Rc<RefCell<VecDeque<(usize, bool, Done<()>)>>>,
    /// Typed-launch programs by harness index (`typed`).
    pub(crate) typed: BTreeMap<usize, String>,
    /// host.identity facts of the machine this helper runs on (local Mac or a server the app
    /// reached over ssh), collected once; hello requests wait for them.
    pub(crate) identity: Option<Json>,
    pub(crate) identity_job: Option<Work>,
    /// Shell integration for default shells, where hooks are allowed (see `startup`).
    pub(crate) integration: Option<crate::system::startup::Integration>,
    /// Startup directories prepared so far; names them under Io::directory.
    pub(crate) startups: u64,
    pub(crate) hellos: Vec<(RawFd, u64, Rc<Json>)>,
    pub(crate) installs: crate::dispatch::Installs,
    pub(crate) archives: crate::dispatch::Archives,
    pub(crate) sides: crate::dispatch::Sides,
    pub(crate) controls: crate::control::SharedRoutes,
    pub(crate) updates: Rc<RefCell<VecDeque<Update>>>,
    /// Chat terminals whose screens are watched for native prompts (prompt.rs).
    pub(crate) prompts: crate::prompt::Prompts,
    pub(crate) probes: crate::probe::Observed,
    pub(crate) launching: Rc<RefCell<BTreeMap<Id, crate::probe::Launch>>>,
    pub(crate) receipts: Rc<RefCell<BTreeSet<u64>>>,
    pub(crate) candidates: candidate::Shared,
    /// Muxes whose clients are not claimed from terminals (backends.claim enabled:false).
    pub(crate) unclaimed: std::collections::BTreeSet<usize>,
    pub(crate) drains: Drains,
    pub(crate) login: Option<login::SharedLogin>,
    pub(crate) windows: crate::dispatch::Windows,
}

struct Updates<'a> {
    pending: Rc<RefCell<VecDeque<Update>>>,
    exits: Vec<(usize, Process, Option<i32>)>,
    replies: Replies,
    observers: &'a [Observer],
    module: usize,
    nodes: crate::dispatch::Nodes,
    scopes: Rc<RefCell<BTreeMap<(usize, Id), BTreeSet<Id>>>>,
    retired: Rc<RefCell<BTreeSet<Id>>>,
    questions: crate::dispatch::Questions,
    interactions: crate::dispatch::Interactions,
    held: crate::dispatch::Held,
    sides: crate::dispatch::Sides,
    controls: crate::control::SharedRoutes,
    probes: crate::probe::Observed,
    candidates: candidate::Shared,
    login: Option<login::SharedLogin>,
}
impl Updates<'_> {
    /// A terminal's agent conversation is over: its questions expire and its interactions and
    /// sides are forgotten (terminal exit and ended bindings alike).
    fn retire(&self, terminal: Id) {
        let keys: Vec<_> = self
            .questions
            .borrow()
            .keys()
            .filter(|(_, id, _, _)| *id == terminal)
            .cloned()
            .collect();
        for key in keys {
            if let Some(question) = self.questions.borrow_mut().remove(&key) {
                failure(
                    &self.replies,
                    key.0,
                    question.request,
                    Error {
                        code: "expired",
                        message: "The confirmation process exited".into(),
                    },
                );
            }
        }
        self.interactions
            .borrow_mut()
            .retain(|(id, _, _), _| *id != terminal);
        self.sides.borrow_mut().retain(|(id, _), _| *id != terminal);
    }
}
impl Ui for Updates<'_> {
    fn update(&mut self, update: Update) {
        if matches!(&update, Update::Identity(_) | Update::Prompt(_)) {
            self.pending.borrow_mut().push_back(update);
            return;
        }
        if let Update::State { binding, .. } | Update::Interaction { binding, .. } = &update {
            self.pending.borrow_mut().push_back(Update::Prompt(binding.clone()));
        }
        if let Update::Candidate { terminal, process } = update {
            let terminal = crate::dispatch::reference(self.module, terminal);
            let mut candidates = self.candidates.borrow_mut();
            if candidates.observed.get(&terminal) != process.as_ref() {
                candidates.observed.remove(&terminal);
                if let Some(process) = process { candidates.observed.insert(terminal, process); }
                candidates.dirty.insert(terminal);
            }
            return;
        }
        if let Update::Client { terminal, process } = update {
            let terminal = crate::dispatch::reference(self.module, terminal);
            if self.nodes.borrow().contains_key(&terminal) {
                let mut probes = self.probes.borrow_mut();
                if !probes
                    .get(&terminal)
                    .is_some_and(|(current, _)| current == &process)
                {
                    probes.insert(terminal, (process, true));
                }
            }
            return;
        }
        let terminal = match &update {
            Update::Output { terminal, .. }
            | Update::Stderr { terminal, .. }
            | Update::Exit { terminal, .. }
            | Update::Scroll { terminal, .. }
            | Update::Agent { terminal, .. } => {
                Some(crate::dispatch::reference(self.module, *terminal))
            }
            Update::Records { binding, .. }
            | Update::History { binding, .. }
            | Update::State { binding, .. }
            | Update::Queue { binding, .. }
            | Update::Interaction { binding, .. } => self.terminal(binding),
            _ => None,
        };
        if let Update::Topology { nodes, .. } = &update {
            let current = self.nodes.borrow();
            self.candidates.borrow_mut().dirty.extend(nodes.iter().filter_map(|node| {
                let id = crate::dispatch::reference(self.module, node.id);
                (node.agent.is_none() && current.get(&id).is_some_and(|(_, old)| old.agent.is_some()))
                    .then_some(id)
            }));
        }
        if let Some(login) = &self.login {
            login.borrow_mut().update(terminal, &update);
        }
        if let Some(id) = terminal {
            crate::dispatch::queue::observe(&self.held, id, &update);
        }
        if let (
            Update::Interaction {
                binding,
                interaction,
            },
            Some(id),
        ) = (&update, terminal)
        {
            self.interactions.borrow_mut().insert(
                (id, binding.session.clone(), interaction.id.clone()),
                interaction.questions.iter().map(|q| q.id.clone()).collect(),
            );
        }
        let recipients: Vec<_> = self
            .observers
            .iter()
            .filter(|(_, _, scope)| match (&update, scope) {
                (Update::Topology { .. } | Update::Agent { .. }, Scope::Backend(index)) => {
                    *index == self.module
                }
                (
                    Update::Output { .. } | Update::Stderr { .. } | Update::Scroll { .. },
                    Scope::Terminal(id),
                ) => Some(*id) == terminal,
                (
                    Update::Records { binding, .. }
                    | Update::History { binding, .. }
                    | Update::State { binding, .. }
                    | Update::Queue { binding, .. }
                    | Update::Interaction { binding, .. },
                    Scope::Chat(id, session),
                ) => Some(*id) == terminal && *session == binding.session,
                (
                    Update::Exit { .. },
                    Scope::Terminal(id) | Scope::Events(id) | Scope::Chat(id, _),
                ) => Some(*id) == terminal,
                (Update::Agent { .. }, Scope::Events(id)) => Some(*id) == terminal,
                (Update::Clipboard { .. }, Scope::Backend(index)) => *index == self.module,
                _ => false,
            })
            .map(|(fd, id, _)| (*fd, *id))
            .collect();
        if let Update::Exit { terminal, status } = &update {
            self.controls
                .borrow_mut()
                .close(crate::dispatch::reference(self.module, *terminal), *status);
            let terminal = crate::dispatch::reference(self.module, *terminal);
            if let Some((_, node)) = self.nodes.borrow().get(&terminal)
                && let Some((harness, binding)) = &node.agent
            {
                self.exits
                    .push((*harness, binding.process.clone(), *status));
            }
            self.retire(terminal);
            self.nodes.borrow_mut().remove(&terminal);
            self.scopes.borrow_mut().retain(|_, nodes| {
                nodes.remove(&terminal);
                !nodes.is_empty()
            });
            self.retired.borrow_mut().remove(&terminal);
            self.probes.borrow_mut().remove(&terminal);
        }
        if let Update::Topology { backend, nodes, .. } = &update {
            let old = self
                .scopes
                .borrow_mut()
                .remove(&(self.module, *backend))
                .unwrap_or_default();
            if !nodes.is_empty() {
                self.scopes.borrow_mut().insert(
                    (self.module, *backend),
                    nodes
                        .iter()
                        .map(|node| crate::dispatch::reference(self.module, node.id))
                        .collect(),
                );
            }
            let mut map = self.nodes.borrow_mut();
            // P1 (b): an app that saw the provisional binding (session "") keeps addressing it
            // with "" after the same process gets its session; resolve that like a side.
            for node in nodes {
                let id = crate::dispatch::reference(self.module, node.id);
                if let (Some((_, old)), Some((_, new))) = (
                    map.get(&id).and_then(|(_, old)| old.agent.as_ref()),
                    node.agent.as_ref(),
                ) && old.session.is_empty()
                    && !new.session.is_empty()
                    && old.process.pid == new.process.pid
                    && old.process.start == new.process.start
                {
                    self.sides
                        .borrow_mut()
                        .insert((id, String::new()), (new.clone(), new.clone()));
                }
            }
            // A binding that ends without its terminal's Exit (the agent left its shell, the
            // backend was killed) still reaches harness.exited, so its harness lets go.
            let mut ended = Vec::new();
            for (id, (_, old)) in map.iter().filter(|(id, _)| old.contains(id)) {
                let Some((harness, binding)) = &old.agent else {
                    continue;
                };
                let same = nodes
                    .iter()
                    .find(|node| crate::dispatch::reference(self.module, node.id) == *id)
                    .and_then(|node| node.agent.as_ref())
                    .is_some_and(|(_, current)| {
                        current.process.pid == binding.process.pid
                            && current.process.start == binding.process.start
                    });
                if !same {
                    self.exits.push((*harness, binding.process.clone(), None));
                    if !binding.session.is_empty()
                        && nodes.iter().any(|node| {
                            crate::dispatch::reference(self.module, node.id) == *id
                                && node.agent.is_none()
                        })
                    {
                        self.retired.borrow_mut().insert(*id);
                    }
                    ended.push(*id);
                }
            }
            for terminal in ended {
                // The conversation ended while its terminal lives: its chat requests end too,
                // so the app drops their approvals and questions (claude, 77b501a5).
                for (fd, request, scope) in self.observers {
                    if matches!(scope, Scope::Chat(id, _) if *id == terminal) {
                        failure(
                            &self.replies,
                            *fd,
                            *request,
                            Error {
                                code: "agent_exited",
                                message: "The agent conversation ended".into(),
                            },
                        );
                    }
                }
                self.retire(terminal);
            }
            map.retain(|id, _| !old.contains(id));
            for node in nodes {
                let id = crate::dispatch::reference(self.module, node.id);
                if node.agent.is_some() {
                    self.retired.borrow_mut().remove(&id);
                }
                map.insert(
                    crate::dispatch::reference(self.module, node.id),
                    (self.module, node.clone()),
                );
            }
            self.retired.borrow_mut().retain(|id| map.contains_key(id));
            drop(map);
            self.probes
                .borrow_mut()
                .retain(|id, _| self.nodes.borrow().contains_key(id));
            self.controls.borrow_mut().retain(self.module, &self.nodes);
        }
        let output = if matches!(&update, Update::Stderr { .. }) {
            "terminal.stderr"
        } else {
            "terminal.output"
        };
        let body = match update {
            Update::Identity(_) | Update::Prompt(_) | Update::Client { .. } | Update::Candidate { .. } => {
                unreachable!("client observations are scheduled before encoding")
            }
            Update::Topology {
                backend,
                key,
                mut nodes,
                mut layouts,
                focus,
            } => {
                for node in &mut nodes {
                    node.id = crate::dispatch::reference(self.module, node.id);
                    node.parent = node
                        .parent
                        .map(|id| crate::dispatch::reference(self.module, id));
                }
                for layout in &mut layouts {
                    layout.container = crate::dispatch::reference(self.module, layout.container);
                    layout.focus = layout
                        .focus
                        .map(|id| crate::dispatch::reference(self.module, id));
                    for split in [&mut layout.full, &mut layout.visible] {
                        remap(split, self.module);
                    }
                }
                wire::topology(
                    crate::dispatch::reference(self.module, backend),
                    &nodes,
                    &layouts,
                    key.as_deref(),
                    focus.map(|id| crate::dispatch::reference(self.module, id)),
                )
            }
            Update::Output { terminal, bytes } | Update::Stderr { terminal, bytes } => {
                crate::encode::notify(
                    output,
                    &[
                        (
                            "terminal",
                            &crate::dispatch::reference(self.module, terminal),
                        ),
                        ("bytes", &crate::encode::base64(&bytes)),
                    ],
                )
            }
            Update::Exit { terminal, status } => crate::encode::notify(
                "terminal.exit",
                &[
                    (
                        "terminal",
                        &crate::dispatch::reference(self.module, terminal),
                    ),
                    ("status", &status),
                ],
            ),
            Update::Agent { terminal, summary } => crate::encode::notify(
                "agent.changed",
                &[
                    (
                        "terminal",
                        &crate::dispatch::reference(self.module, terminal),
                    ),
                    ("summary", &summary),
                ],
            ),
            Update::Records { binding, records } => crate::encode::notify(
                "chat.records",
                &[
                    ("terminal", &terminal),
                    ("session", &binding.session),
                    ("records", &records),
                ],
            ),
            Update::History { binding, page } => crate::encode::notify(
                "chat.records",
                &[
                    ("terminal", &terminal),
                    ("session", &binding.session),
                    ("records", &page.records),
                    ("replace", &true),
                    ("earlier", &page.earlier),
                ],
            ),
            Update::State { binding, state } => crate::encode::notify(
                "chat.state",
                &[
                    ("terminal", &terminal),
                    ("session", &binding.session),
                    ("state", &state),
                ],
            ),
            Update::Queue {
                binding,
                items,
                error,
            } => {
                let mut fields: Vec<(&str, &dyn crate::encode::Encode)> = vec![
                    ("terminal", &terminal),
                    ("session", &binding.session),
                    ("items", &items),
                ];
                if error.is_some() {
                    fields.push(("error", &error));
                }
                crate::encode::notify("chat.queue", &fields)
            }
            Update::Interaction {
                binding,
                interaction,
            } => crate::encode::notify(
                "interaction.opened",
                &[
                    ("terminal", &terminal),
                    ("session", &binding.session),
                    ("interaction", &interaction),
                ],
            ),
            Update::Clipboard { bytes } => {
                crate::encode::notify("clipboard", &[("bytes", &crate::encode::base64(&bytes))])
            }
            Update::Scroll {
                terminal,
                offset,
                max,
                viewport,
            } => crate::encode::notify(
                "terminal.scroll",
                &[
                    (
                        "terminal",
                        &crate::dispatch::reference(self.module, terminal),
                    ),
                    ("offset", &offset),
                    ("max", &max),
                    ("viewport", &viewport),
                ],
            ),
        };
        for (fd, id) in recipients {
            self.replies
                .borrow_mut()
                .push_back((fd, wire::Kind::Notify, id, body.clone()));
        }
    }
    fn watching(&self, binding: &Binding) -> bool {
        self.terminal(binding).is_some_and(|terminal| {
            self.observers.iter().any(|(_, _, scope)| {
                matches!(scope, Scope::Chat(id, session) if *id == terminal && *session == binding.session)
            })
        })
    }
    fn terminal(&self, binding: &Binding) -> Option<Id> {
        self.nodes.borrow().iter().find_map(|(&id, (_, node))| {
            let (_, parent) = node.agent.as_ref()?;
            if crate::dispatch::same(parent, binding) {
                return Some(id);
            }
            self.sides
                .borrow()
                .get(&(id, binding.session.clone()))
                .filter(|(original, side)| {
                    crate::dispatch::same(parent, original) && crate::dispatch::same(side, binding)
                })
                .map(|_| id)
        })
    }
}

fn remap(split: &mut Split, module: usize) {
    match split {
        Split::Leaf(id) => *id = crate::dispatch::reference(module, *id),
        Split::Branch { id, children, .. } => {
            *id = crate::dispatch::reference(module, *id);
            for (_, child) in children {
                remap(child, module);
            }
        }
    }
}

impl Default for DispatchHelper {
    fn default() -> Self {
        Self::new()
    }
}
impl DispatchHelper {
    pub(crate) fn binding(
        &self,
        terminal: Id,
        session: Option<&str>,
    ) -> Result<(usize, Binding), Error> {
        let nodes = self.nodes.borrow();
        let (harness, parent) = nodes
            .get(&terminal)
            .and_then(|(_, node)| node.agent.as_ref())
            .ok_or_else(|| match session {
                Some(_) if self.retired.borrow().contains(&terminal) => Error {
                    code: "expired",
                    message: "The agent no longer owns this terminal.".into(),
                },
                _ => Error {
                    code: "unavailable",
                    message: "No verified harness is bound to this terminal".into(),
                },
            })?;
        let side = session.filter(|session| *session != parent.session);
        let binding = match side {
            None => parent.clone(),
            Some(session) => self
                .sides
                .borrow()
                .get(&(terminal, session.to_owned()))
                .filter(|(original, _)| crate::dispatch::same(parent, original))
                .map(|(_, side)| side.clone())
                .ok_or_else(|| Error {
                    code: "destination_changed",
                    message: "The agent conversation changed.".into(),
                })?,
        };
        Ok((*harness, binding))
    }
    pub fn new() -> Self {
        Self {
            permissions: Rc::new(RefCell::new(None)),
            admitted: BTreeMap::new(),
            windows: Default::default(),
            shell: std::env::var_os("SHELL").unwrap_or("/bin/sh".into()).into(),
            execution: System::command(),
            default: None,
            harnesses: Vec::new(),
            multiplexers: Vec::new(),
            plugins: Vec::new(),
            nodes: Rc::new(RefCell::new(BTreeMap::new())),
            scopes: Default::default(),
            retired: Rc::new(RefCell::new(BTreeSet::new())),
            unavailable: Vec::new(),
            questions: Rc::new(RefCell::new(BTreeMap::new())),
            interactions: Rc::new(RefCell::new(BTreeMap::new())),
            adoptions: Rc::new(RefCell::new(Vec::new())),
            held: Rc::new(RefCell::new(BTreeMap::new())),
            commands: Rc::new(RefCell::new(Default::default())),
            creations: Default::default(),
            backends: Default::default(),
            resets: Default::default(),
            typed: BTreeMap::new(),
            identity: None,
            identity_job: None,
            integration: None,
            startups: 0,
            hellos: Vec::new(),
            installs: Rc::new(RefCell::new(BTreeMap::new())),
            archives: Rc::new(RefCell::new(BTreeMap::new())),
            sides: Rc::new(RefCell::new(BTreeMap::new())),
            controls: Rc::new(RefCell::new(crate::control::Routes::default())),
            updates: Rc::new(RefCell::new(VecDeque::new())),
            prompts: Default::default(),
            probes: Rc::new(RefCell::new(BTreeMap::new())),
            launching: Default::default(),
            receipts: Default::default(),
            candidates: Default::default(),
            unclaimed: Default::default(),
            drains: Rc::new(RefCell::new(VecDeque::new())),
            login: None,
        }
    }
    fn cancel_creations(&mut self, io: &mut dyn Io, fd: i32, request: Option<u64>) {
        let keys: Vec<_> = self
            .creations
            .borrow()
            .keys()
            .copied()
            .filter(|(peer, _, id)| *peer == fd && request.is_none_or(|request| *id == request))
            .collect();
        for key in keys {
            let Some(state) = self.creations.borrow_mut().remove(&key) else {
                continue;
            };
            let error = client::cancelled();
            state.borrow_mut().result = Some(Err(error.clone()));
            for done in std::mem::take(&mut state.borrow_mut().waiting) {
                deferred(done)(io, Err(error.clone()));
            }
        }
    }
    fn reset(&mut self, io: &mut dyn Io, replies: Replies, observers: &[Observer]) {
        let resets: Vec<_> = self.resets.borrow_mut().drain(..).collect();
        for (module, enabled, done) in resets {
            if enabled {
                self.unclaimed.remove(&module);
                done(io, Ok(()));
                continue;
            }
            self.unclaimed.insert(module);
            let mut ui = Updates {
                exits: Vec::new(),
                replies: replies.clone(),
                observers,
                module,
                nodes: self.nodes.clone(),
                scopes: self.scopes.clone(),
                retired: self.retired.clone(),
                questions: self.questions.clone(),
                interactions: self.interactions.clone(),
                held: self.held.clone(),
                sides: self.sides.clone(),
                controls: self.controls.clone(),
                probes: self.probes.clone(),
                candidates: self.candidates.clone(),
                pending: self.updates.clone(),
                login: self.login.clone(),
            };
            let backends: BTreeSet<_> = self
                .backends
                .borrow()
                .iter()
                .filter_map(|(index, id)| (*index == module).then_some(*id))
                .chain(
                    self.scopes
                        .borrow()
                        .keys()
                        .filter_map(|(index, id)| (*index == module).then_some(*id)),
                )
                .collect();
            self.backends
                .borrow_mut()
                .retain(|(index, _)| *index != module);
            for backend in if backends.is_empty() {
                vec![0]
            } else {
                backends.into_iter().collect()
            } {
                ui.update(Update::Topology {
                    backend,
                    key: None,
                    nodes: Vec::new(),
                    layouts: Vec::new(),
                    focus: None,
                });
            }
            for (index, process, status) in ui.exits {
                let harness = self.harnesses[index].clone();
                io.defer(Box::new(move |io| {
                    harness.borrow_mut().exited(io, &process, status)
                }));
            }
            done(io, Ok(()));
        }
    }
    pub fn add_harness<T: Harness + 'static>(&mut self, harness: T) -> Shared<dyn Harness> {
        let (index, installs) = (self.harnesses.len(), self.installs.clone());
        let enabled = installs.clone();
        let grants = self.permissions.clone();
        let hooks = grants.clone();
        let harness: Shared<dyn Harness> = Rc::new(RefCell::new(crate::registered::Registered {
            part: harness,
            section: format!("harness/{index}"),
            muted: Some(Box::new(move || {
                !login::permits(&hooks, "hooks.configure")
                    || matches!(
                        installs.borrow().get(&index),
                        Some(crate::dispatch::Installed::Off | crate::dispatch::Installed::Disabled)
                    )
            })),
            permitted: Rc::new(move |method| {
                if !matches!(method, "install" | "revoke" | "launch" | "read" | "candidate")
                    && matches!(enabled.borrow().get(&index), Some(crate::dispatch::Installed::Disabled)) {
                    return false;
                }
                let capability = match method {
                    "revoke" => return true,
                    "install" => "hooks.configure",
                    "launch" | "send" | "command" | "stop" | "select" | "answer" | "queue_add"
                    | "queue_edit" | "queue_send" | "queue_order" | "side" | "side_close" => {
                        "agent.submit"
                    }
                    "identify" if login::permits(&grants, "hooks.configure") => return true,
                    _ => "agent.inspect",
                };
                login::permits(&grants, capability)
            }),
        }));
        self.harnesses.push(harness.clone());
        for mux in &mut self.multiplexers {
            mux.borrow_mut().harnesses(self.harnesses.clone());
        }
        harness
    }
    /// Register `program` (what users type, e.g. "codex") as the typed launch of `harness`:
    /// launches.list reports it and the app wraps it into `dispatch-helper launch <key>`,
    /// like c1654cc ShellCommandWrapper.swift:5-12.
    pub fn typed(&mut self, harness: &Shared<dyn Harness>, program: &str) {
        if let Some(index) = self.harnesses.iter().position(|h| Rc::ptr_eq(h, harness)) {
            self.typed.insert(index, program.into());
        }
    }
    pub fn add_multiplexer<T: Multiplexer + 'static>(
        &mut self,
        mut mux: T,
    ) -> Shared<dyn Multiplexer> {
        mux.harnesses(self.harnesses.clone());
        let grants = self.permissions.clone();
        let capability = login::mux(mux.name());
        let mux: Shared<dyn Multiplexer> = Rc::new(RefCell::new(crate::registered::Registered {
            part: mux,
            section: format!("mux/{}", self.multiplexers.len()),
            muted: None,
            permitted: Rc::new(move |method| {
                method == "enable"
                    || login::permits(&grants, capability)
            }),
        }));
        self.multiplexers.push(mux.clone());
        mux
    }
    /// The bin chooses the plain-shell backend; clients need no provider-specific rule.
    pub fn default_backend(&mut self, mux: &Shared<dyn Multiplexer>, key: &str) {
        let index = self.multiplexers.iter().position(|m| Rc::ptr_eq(m, mux));
        self.default = index.map(|index| (index, key.to_owned()));
    }

    pub(crate) fn route(&self, params: crate::json::Value<'_>) -> usize {
        params
            .get("mux")
            .and_then(|v| v.unsigned())
            .or_else(|| {
                ["terminal", "node", "parent"].into_iter().find_map(|name| {
                    params
                        .get(name)
                        .and_then(|v| v.unsigned())
                        .map(|id| id >> 48)
                })
            })
            .unwrap_or_else(|| self.default.as_ref().map_or(0, |(index, _)| *index as u64))
            as usize
    }

    pub fn add_plugin<T: Plugin + 'static>(&mut self, plugin: T) -> Shared<dyn Plugin> {
        let grants = self.permissions.clone();
        let plugin: Shared<dyn Plugin> = Rc::new(RefCell::new(crate::registered::Registered {
            part: plugin,
            section: format!("plugin/{}", self.plugins.len()),
            muted: None,
            permitted: Rc::new(move |method| {
                login::permits(
                    &grants,
                    match method {
                        "text" | "read" | "branch" => "file.text",
                        _ => "stats.sample",
                    },
                )
            }),
        }));
        self.plugins.push(plugin.clone());
        plugin
    }
    /// hello can answer: the host identity is known and a login shell (if any) has started.
    pub(crate) fn answerable(&self) -> bool {
        self.identity.is_some()
            && self.login.as_ref().is_none_or(|login| {
                let login = login.borrow();
                login.started || login.failure.is_some()
            })
    }
    /// Shell integration for default shells (core prepares them, N-SHELL), only where hooks
    /// are allowed: the local helper, or a login whose permissions grant hooks.configure
    /// (old herdr_rpc.rs:393-410).
    pub fn startup(&mut self, integration: crate::system::startup::Integration) {
        if self
            .permissions
            .borrow()
            .as_ref()
            .is_some_and(|p| !p.contains("hooks.configure"))
        {
            return;
        }
        self.integration = Some(integration);
    }
    pub fn unavailable_harness(&mut self, name: &str) {
        self.unavailable.push(name.into());
    }

    /// A typed launcher waits here before the agent reads its configuration. Only the
    /// socket peer's live process can choose an SSH config root; local setup stays
    /// in the app's account configuration (CodexHookSetup.swift:10-13).
    fn setup(&self, io: &mut dyn Io, index: usize, peer: u32, done: Done<bool>) {
        use crate::dispatch::Installed;
        let (permissions, installs, nodes) = (
            self.permissions.clone(), self.installs.clone(), self.nodes.clone(),
        );
        let enabled = Rc::new(move || login::permits(&permissions, "hooks.configure")
            && !matches!(installs.borrow().get(&index), Some(Installed::Off | Installed::Disabled)));
        if !enabled() { return done(io, Ok(false)); }
        let Some(harness) = self.harnesses.get(index).cloned() else {
            return done(io, Err(Error { code: "setup", message: "Unknown launch integration".into() }));
        };
        let previous = io.section(&format!("harness/{index}"));
        let route = io.route();
        io.section(&previous);
        let route = match route {
            Ok((_, route)) => route,
            Err(error) => return done(io, Err(Error { code: "setup", message: error.to_string() })),
        };
        let work = match io.submit(Job::Process { pid: peer }) {
            Ok(work) => work,
            Err(error) => return done(io, Err(Error { code: "setup", message: error.to_string() })),
        };
        let (parent, installs, remote) = (io.pid(), self.installs.clone(), self.login.is_some());
        io.then(work, Box::new(move |io, result| {
            let process = match result {
                Ok(Output::Process(process)) if process.pid == peer &&
                    (process.parent == parent || process.tty != 0 && nodes.borrow().values()
                        .any(|(_, node)| node.tty == Some(process.tty))) => process,
                _ => return done(io, Err(Error { code: "setup", message: "Launch process is no longer owned by this helper".into() })),
            };
            if !enabled() { return done(io, Ok(false)); }
            let binding = remote.then_some(Binding { session: String::new(), transcript: None, process });
            let next = harness.clone();
            let target = route.clone();
            harness.borrow_mut().install(io, &route, None, binding.clone().as_ref(), Box::new(move |io, result| {
                let audit = match result { Ok(audit) => audit, Err(error) => return done(io, Err(error)) };
                // Optional integrations require an explicit enabled state on this helper,
                // even when the launcher's custom HOME has never seen their files.
                if !enabled() || audit.optional && !installs.borrow().contains_key(&index) {
                    return done(io, Ok(false));
                }
                io.defer(Box::new(move |io| {
                    if !enabled() { return done(io, Ok(false)); }
                    next.borrow_mut().install(io, &target, Some(true), binding.as_ref(), Box::new(move |io, result| {
                        done(io, result.map(|_| enabled()));
                    }));
                }));
            }));
        }));
    }

    fn launch(&self, io: &mut dyn Io, program: &str, peer: u32, reply: u64, replies: Replies, observers: &[Observer]) {
        let index = self.multiplexers.iter().position(|mux| mux.borrow().program().as_deref() == Some(program));
        let Some(index) = index.filter(|index| !self.unclaimed.contains(index)) else {
            let _ = crate::probe::answer(io, reply, Ok(false));
            return;
        };
        if !login::permits(&self.permissions, login::mux(self.multiplexers[index].borrow().name())) {
            let _ = crate::probe::answer(io, reply, Ok(false));
            return;
        }
        let receipts = self.receipts.clone();
        receipts.borrow_mut().insert(reply);
        let (nodes, pending, probes, parts) = (self.nodes.clone(), self.launching.clone(), self.probes.clone(), self.multiplexers.clone());
        let observers = observers.to_vec();
        let work = match io.submit(Job::Process { pid: peer }) {
            Ok(work) => work,
            Err(error) => { receipts.borrow_mut().remove(&reply); let _ = crate::probe::answer(io, reply, Err(Error { code: "launch", message: error.to_string() })); return; }
        };
        io.then(work, Box::new(move |io, result| {
            if !receipts.borrow().contains(&reply) { return; }
            let process = match result {
                Ok(Output::Process(process)) if process.pid == peer && process.tty != 0 && process.group == process.foreground => process,
                _ => { receipts.borrow_mut().remove(&reply); let _ = crate::probe::answer(io, reply, Err(client::cancelled())); return; }
            };
            let terminal = nodes.borrow().iter().find_map(|(id, (_, node))| (node.tty == Some(process.tty)).then_some(*id));
            let Some(terminal) = terminal else { receipts.borrow_mut().remove(&reply); let _ = crate::probe::answer(io, reply, Err(client::cancelled())); return; };
            let source = parts[(terminal >> 48) as usize].clone();
            source.borrow_mut().control(io, crate::dispatch::local(terminal), deferred(Box::new(move |io, current| {
                if !receipts.borrow().contains(&reply) { return; }
                // A backend without control interception leaves typed commands to the native CLI.
                if current.as_ref().is_err_and(|error| error.code == "unsupported") {
                    receipts.borrow_mut().remove(&reply);
                    let _ = crate::probe::answer(io, reply, Ok(false));
                    return;
                }
                let launch = crate::probe::Launch { mux: index, process: process.clone(), reply, ready: true };
                if current.as_ref().ok().is_none_or(|current| launch.accept(index, current).is_err()) || pending.borrow().contains_key(&terminal) {
                    receipts.borrow_mut().remove(&reply); let _ = crate::probe::answer(io, reply, Err(client::cancelled())); return;
                }
                pending.borrow_mut().insert(terminal, crate::probe::Launch { ready: false, ..launch });
                probes.borrow_mut().insert(terminal, (process.clone(), false));
                let recipients = observers.iter().filter(|(_, _, scope)| match scope {
                    Scope::Backend(module) => *module == (terminal >> 48) as usize,
                    Scope::Terminal(id) | Scope::Events(id) => *id == terminal,
                    _ => false,
                }).map(|(fd, id, _)| (*fd, *id)).collect();
                let completion = crate::probe::completion(terminal, recipients, replies, Some(index));
                let target = parts[index].clone();
                let target2 = target.clone();
                target.borrow_mut().launch(io, &process, deferred(Box::new(move |io, result| {
                    if !receipts.borrow().contains(&reply) || pending.borrow().get(&terminal).is_none_or(|value| value.reply != reply) { return; }
                    let key = match result {
                        Ok(Some(key)) => key,
                        result => {
                            pending.borrow_mut().remove(&terminal);
                            receipts.borrow_mut().remove(&reply);
                            if let Err(error) = &result { completion(io, Err(error.clone())); }
                            let _ = crate::probe::answer(io, reply, result.map(|_| false));
                            return;
                        }
                    };
                    target2.borrow_mut().open(io, &key.clone(), deferred(Box::new(move |io, result| {
                        if !receipts.borrow().contains(&reply) || pending.borrow().get(&terminal).is_none_or(|value| value.reply != reply) { return; }
                        match result {
                            Ok(backend) => {
                                pending.borrow_mut().get_mut(&terminal).unwrap().ready = true;
                                completion(io, Ok((index, key, crate::dispatch::reference(index, backend))));
                            }
                            Err(error) => {
                                pending.borrow_mut().remove(&terminal);
                                receipts.borrow_mut().remove(&reply);
                                let _ = crate::probe::answer(io, reply, Err(error.clone()));
                                completion(io, Err(error));
                            }
                        }
                    })));
                })));
            })));
        }));
    }

    pub fn run(self, socket: &Path) -> io::Result<()> {
        self.start(Some(socket), None, &mut None).map(|_| ())
    }
    pub fn run_stdio(self) -> io::Result<()> {
        self.start(None, None, &mut None).map(|_| ())
    }
    /// The original login's VT channel and every auxiliary bus client share the same PTY.
    pub fn run_login(
        self,
        socket: &Path,
        command: Option<std::process::Command>,
    ) -> io::Result<i32> {
        use crate::system::login::{Supervision, supervise};
        use std::io::Write;
        let mut completion = match supervise()? {
            Supervision::Frontend(status) => return Ok(status),
            Supervision::Worker(stream) => Some(stream),
            Supervision::Replay => None,
        };
        let (status, _) = self.start(Some(socket), Some(command), &mut completion)?;
        if let Some(mut stream) = completion {
            stream.write_all(&status.to_le_bytes())?;
        }
        Ok(status)
    }
    fn start(
        mut self,
        socket: Option<&Path>,
        login: Option<Option<std::process::Command>>,
        completion: &mut Option<std::os::unix::net::UnixStream>,
    ) -> io::Result<(i32, bool)> {
        let mut system = System::new(2, 128)?;
        // B4: a hook comes from this helper's agent when this helper started one of its
        // processes, or when the nearest tty among them is one of this helper's terminals; its
        // binding here ranks this helper first among owners.
        let (nodes, me) = (self.nodes.clone(), system.pid());
        system.owner(Box::new(move |chain| {
            let nodes = nodes.borrow();
            let bound = chain.iter().any(|&(pid, _)| {
                nodes.values().any(|(_, node)| {
                    node.agent
                        .as_ref()
                        .is_some_and(|(_, b)| b.process.pid == pid)
                })
            });
            let nearest = chain.iter().find(|&&(pid, tty)| pid == me || tty != 0);
            let owned = bound
                || nearest.is_some_and(|&(pid, tty)| {
                    pid == me || nodes.values().any(|(_, node)| node.tty == Some(tty))
                });
            owned.then_some(bound)
        }));
        // Typed startup setup must be discoverable before Chat observes an agent.
        for index in 0..self.harnesses.len() {
            system.section(&format!("harness/{index}"));
            system.route()?;
        }
        system.section("startup");
        let listener = socket.map(|path| system.listen(path)).transpose()?;
        // Best effort: without it, a session directory is only kept for a day.
        let _session = socket
            .filter(|_| login.is_some() && System::recording().is_none())
            .and_then(|path| crate::system::login::claim(path).ok());
        if let Some(command) = login {
            let (index, key) = self
                .default
                .clone()
                .ok_or_else(|| io::Error::other("Login backend is unavailable"))?;
            // The login PTY starts with the ssh session's terminal modes (c1654cc relay.rs:167).
            system.inherit()?;
            let owner = login::Login::new(&mut system)?;
            self.identity_job = Some(owner.borrow().identity_job);
            let mux = self.multiplexers[index].clone();
            if let Some(integration) = self.integration.as_ref()
                && command.as_ref().is_none_or(|c| {
                    let mut args = c.get_args();
                    c.get_program() == self.shell.as_os_str()
                        && match args.next().and_then(|a| a.to_str()) {
                            Some("-l") => args.next().is_none(),
                            Some("-c") => {
                                args.next().and_then(|a| a.to_str()).is_some()
                                    && args.next().is_none()
                            }
                            _ => false,
                        }
                })
            {
                self.startups += 1;
                let directory = system
                    .directory()?
                    .join(format!("startup-{}", self.startups));
                let (_, home) = System::account()?;
                let executable = system.executable()?;
                let script = command.as_ref().and_then(|c| {
                    let mut args = c.get_args();
                    (args.next() == Some(std::ffi::OsStr::new("-c")))
                        .then(|| args.next().and_then(|a| a.to_str()))
                        .flatten()
                });
                let (mut prepared, files) = crate::system::startup::prepare(
                    &self.shell,
                    &home,
                    &directory,
                    &executable,
                    script,
                    Some(integration),
                    &|name| std::env::var_os(name),
                );
                if let Some(cwd) = command.as_ref().and_then(|c| c.get_current_dir()) {
                    prepared.current_dir(cwd);
                }
                if let Some(command) = &command {
                    for (name, value) in command.get_envs() {
                        // Generated shell startup owns its environment, including removals.
                        if prepared.get_envs().any(|(key, _)| key == name) {
                            continue;
                        }
                        match value {
                            Some(value) => {
                                prepared.env(name, value);
                            }
                            None => {
                                prepared.env_remove(name);
                            }
                        }
                    }
                }
                let work = system.submit(Job::MakeDir {
                    path: directory.clone(),
                    mode: 0o700,
                })?;
                let saved = owner.clone();
                system.then(
                    work,
                    crate::dispatch::write(
                        directory,
                        files.into(),
                        prepared,
                        Box::new(move |io, result| match result {
                            Ok(command) => {
                                login::Login::start(&saved, io, mux, index, key, command)
                            }
                            Err(error) => saved.borrow_mut().failure = Some(error),
                        }),
                    ),
                );
            } else {
                login::Login::start(&owner, &mut system, mux, index, key, command);
            }
            self.login = Some(owner);
        }
        let mut clients: BTreeMap<RawFd, Client> = BTreeMap::new();
        if let Some(fd) = listener {
            system.interest(fd, self.login.is_none(), false)?;
        } else {
            let (read, write) = system.stdio()?;
            clients.insert(read, Client::new(write));
            system.interest(read, true, false)?;
        }
        let mut observers = Vec::new();
        let replies: Replies = Rc::new(RefCell::new(VecDeque::new()));
        let mut paused = false;
        let mut exited = None;
        // Last client traffic of a detached login; None until it detaches.
        let mut traffic: Option<Instant> = None;
        loop {
            let revoked: Vec<_> = self
                .admitted
                .iter()
                .filter(|(_, (grants, _))| {
                    grants
                        .iter()
                        .any(|capability| !login::permits(&self.permissions, capability))
                })
                .map(|(key, _)| *key)
                .collect();
            for (fd, id) in revoked {
                if let Some((_, active)) = self.admitted.remove(&(fd, id)) {
                    active.set(false);
                }
                observers.retain(|(peer, request, _)| *peer != fd || *request != id);
                self.cancel_creations(&mut system, fd, Some(id));
                replies
                    .borrow_mut()
                    .retain(|(peer, _, request, _)| *peer != fd || *request != id);
                if let Some(client) = clients.get_mut(&fd) {
                    client.cancel(&mut system, id);
                    client.pending.insert(id);
                    failure(
                        &replies,
                        fd,
                        id,
                        Error {
                            code: "permission_denied",
                            message: "This SSH feature is disabled".into(),
                        },
                    );
                }
            }
            self.admitted.retain(|(fd, id), (_, active)| {
                let keep = clients
                    .get(fd)
                    .is_some_and(|client| client.pending.contains(id));
                if !keep {
                    active.set(false);
                }
                keep
            });
            system.callbacks();
            self.reset(&mut system, replies.clone(), &observers);
            self.launching.borrow_mut().retain(|terminal, launch| {
                let current = self.nodes.borrow().contains_key(terminal)
                    && self.probes.borrow().get(terminal).is_some_and(|(process, _)| launch.current(process))
                    && !self.unclaimed.contains(&launch.mux)
                    && login::permits(&self.permissions, login::mux(self.multiplexers[launch.mux].borrow().name()));
                if !current {
                    self.receipts.borrow_mut().remove(&launch.reply);
                    let _ = crate::probe::answer(&mut system, launch.reply, Err(client::cancelled()));
                }
                current
            });
            // Hellos wait for the identity and, in login mode, for the login shell's process
            // (bin/tests/login.py reads hello.process right after login).
            if !self.hellos.is_empty() && self.answerable() {
                for (fd, id, document) in std::mem::take(&mut self.hellos) {
                    system.section("ui");
                    let result = crate::dispatch::Request {
                        helper: &mut self,
                        io: &mut system,
                        replies: replies.clone(),
                        document: document.clone(),
                        fd,
                        id,
                    }
                    .dispatch(
                        "hello",
                        document.root().get("params").unwrap_or(document.root()),
                    );
                    if let Err(error) = result {
                        failure(&replies, fd, id, error);
                    }
                }
            }
            let deliveries: Vec<_> = self.controls.borrow_mut().ready.drain(..).collect();
            // Only Exit is delivered here; its route is already closed.
            for (module, id, event) in deliveries {
                let _ = self.multiplexers[module]
                    .borrow_mut()
                    .stream(&mut system, id, event);
            }
            system.callbacks();
            // Created terminals become observed before the next poll can deliver their IO.
            for (fd, request, terminal) in self.adoptions.borrow_mut().drain(..) {
                let index = observers.iter().position(|(peer, id, scope)| {
                    *peer == fd && *id == request && matches!(scope, Scope::Created)
                });
                match (index, terminal) {
                    (Some(index), Some(terminal)) => observers[index].2 = Scope::Terminal(terminal),
                    (Some(index), None) => {
                        observers.remove(index);
                    }
                    _ => {}
                }
            }
            // Prompt watches end with their terminal's last chat observer.
            self.prompts.borrow_mut().retain(|terminal, _| {
                observers
                    .iter()
                    .any(|(_, _, scope)| matches!(scope, Scope::Chat(id, _) if id == terminal))
            });
            loop {
                let update = self.updates.borrow_mut().pop_front();
                let Some(update) = update else { break };
                if let Update::Prompt(binding) = update {
                    crate::prompt::refresh(&self.prompts, &self.updates, &binding);
                    continue;
                }
                if let Update::Identity(process) = update {
                    for mux in &self.multiplexers {
                        mux.borrow_mut().invalidate(&mut system, &process);
                    }
                    continue;
                }
                Updates {
                    exits: Vec::new(),
                    replies: replies.clone(),
                    observers: &observers,
                    module: usize::MAX,
                    nodes: self.nodes.clone(),
                    scopes: self.scopes.clone(),
                    retired: self.retired.clone(),
                    questions: self.questions.clone(),
                    interactions: self.interactions.clone(),
                    held: self.held.clone(),
                    sides: self.sides.clone(),
                    controls: self.controls.clone(),
                    probes: self.probes.clone(),
                    candidates: self.candidates.clone(),
                    pending: self.updates.clone(),
                    login: self.login.clone(),
                }
                .update(update);
            }
            crate::dispatch::queue::drain(&self, &mut system);
            self.candidates(&mut system, &replies, &observers);
            let pending: Vec<_> = self
                .probes
                .borrow_mut()
                .iter_mut()
                .filter_map(|(&terminal, (process, pending))| {
                    if !*pending {
                        return None;
                    }
                    *pending = false;
                    Some((terminal, process.clone()))
                })
                .collect();
            for (terminal, process) in pending {
                let recipients = observers
                    .iter()
                    .filter(|(_, _, scope)| match scope {
                        Scope::Backend(module) => *module == (terminal >> 48) as usize,
                        Scope::Terminal(id) | Scope::Events(id) => *id == terminal,
                        _ => false,
                    })
                    .map(|(fd, id, _)| (*fd, *id))
                    .collect();
                crate::probe::Attempt {
                    terminal,
                    process,
                    index: 0,
                    parts: self.multiplexers.clone(),
                    skip: self.unclaimed.clone(),
                    observed: self.probes.clone(),
                    done: crate::probe::completion(terminal, recipients, replies.clone(), None),
                }
                .next(&mut system);
            }
            system.callbacks();
            let count = replies.borrow().len();
            for _ in 0..count {
                let (fd, kind, id, body) = replies.borrow_mut().pop_front().unwrap();
                if let Some(client) = clients.get_mut(&fd)
                    && client.pending.contains(&id)
                {
                    client
                        .messages
                        .push_back(wire::Message::json(kind, id, body));
                }
            }
            for (fd, id, done) in self.drains.borrow_mut().drain(..) {
                match clients.get_mut(&fd) {
                    Some(client)
                        if client.pending.contains(&id) && !client.drains.contains_key(&id) =>
                    {
                        client.drains.insert(id, done);
                    }
                    _ => deferred(done)(&mut system, Err(client::cancelled())),
                }
            }
            for (&fd, client) in &mut clients {
                loop {
                    // Replies may pass unrelated bulk bytes, but not semantic notifications:
                    // a mutation's topology/state must reach the UI before its completion.
                    let index = wire::Message::select(&client.messages);
                    let Some(message) = client.messages.get_mut(index) else {
                        break;
                    };
                    if message.size() > client.output.space() {
                        break;
                    }
                    let frame = message.next().expect("pending response frame");
                    client
                        .output
                        .record(Some(message.id), frame)
                        .map_err(|_| io::Error::other("UI frame admission changed"))?;
                    if message.size() == 0 {
                        let message = client.messages.remove(index).unwrap();
                        if message.kind == wire::Kind::Response {
                            client.pending.remove(&message.id);
                            observers
                                .retain(|(peer, request, _)| *peer != fd || *request != message.id);
                        }
                    }
                }
                let mut space = client.output.space();
                let ready: Vec<_> = client
                    .drains
                    .keys()
                    .copied()
                    .filter(|id| {
                        if client.messages.iter().any(|message| message.id == *id)
                            || space < wire::CHUNK + 21
                        {
                            return false;
                        }
                        space -= wire::CHUNK + 21;
                        true
                    })
                    .collect();
                for id in ready {
                    let result = if client.pending.contains(&id) {
                        Ok(())
                    } else {
                        Err(client::cancelled())
                    };
                    deferred(client.drains.remove(&id).unwrap())(&mut system, result);
                }
                if client.output.front().is_some() {
                    system.interest(
                        client.write,
                        client.write == fd && !client.eof && client.output.space() >= FRAME,
                        true,
                    )?;
                }
            }
            let reserve = if paused { 2 * FRAME } else { FRAME };
            paused = !replies.borrow().is_empty()
                || clients
                    .values()
                    .any(|client| !client.messages.is_empty() || client.output.space() < reserve)
                || self
                    .login
                    .as_ref()
                    .is_some_and(|login| login.borrow().paused());
            if let Some(login) = &self.login {
                system.section("ui");
                login::Login::check(login, &mut system);
                let status = login.borrow().ready(&mut system)?;
                if let Some(status) = status {
                    let natural = !login.borrow().closing;
                    if natural && System::recording().is_none() {
                        if let Err(error) = crate::system::login::record(socket.unwrap(), status) {
                            eprintln!("dispatch-helper: could not record login exit: {error}");
                        }
                    }
                    exited = Some((status, natural));
                    if !clients.is_empty() {
                        login.borrow_mut().detach(&mut system)?;
                        let now = system.now();
                        traffic = Some(now);
                        detached(&mut system, now + DETACHED_IDLE);
                        if let Some(mut stream) = completion.take() {
                            use std::io::Write;
                            if let Err(error) = stream.write_all(&status.to_le_bytes()) {
                                // The origin may be closed as soon as its close RPC answers.
                                // Its private frontend is gone; the other consumers still own us.
                                if !matches!(error.kind(), io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset) {
                                    return Err(error);
                                }
                            }
                        }
                    }
                }
                if let Some(status) = exited.filter(|_| clients.is_empty()) {
                    system.finish_replay()?;
                    return Ok(status);
                }
                system.interest(
                    listener.unwrap(),
                    login.borrow().started && self.identity.is_some(),
                    false,
                )?;
            }
            system.pressure(paused)?;
            // Probes and delivery completions above can defer more work. Publish its effects
            // before waiting for unrelated IO to wake the dispatcher.
            if system.flush() {
                continue;
            }
            let (section, event) = match system.next() {
                Err(error)
                    if error.kind() == io::ErrorKind::UnexpectedEof && system.replay_done() =>
                {
                    system.finish_replay()?;
                    return Ok((0, false));
                }
                result => result?,
            };
            system.section(&section);
            if section == DETACHED {
                if let (Event::Timer { .. }, Some(last), Some(status)) = (&event, traffic, exited) {
                    if system.now() >= last + DETACHED_IDLE {
                        system.finish_replay()?;
                        return Ok(status);
                    }
                    detached(&mut system, last + DETACHED_IDLE);
                }
                system.section("ui");
                continue;
            }
            if section == "launch" {
                match event {
                    Event::Hook { peer: Some(peer), message, reply: Some(reply), .. } => {
                        let program = Json::parse(&message).ok().and_then(|doc| doc.root().get("program").and_then(|v| v.string()).map(str::to_owned));
                        if let Some(program) = program {
                            self.launch(&mut system, &program, peer, reply, replies.clone(), &observers);
                        } else {
                            let _ = crate::probe::answer(&mut system, reply, Err(client::cancelled()));
                        }
                    }
                    Event::Hook { reply: Some(reply), .. } => { let _ = crate::probe::answer(&mut system, reply, Err(client::cancelled())); }
                    Event::Closed { reply } => {
                        self.receipts.borrow_mut().remove(&reply);
                        self.launching.borrow_mut().retain(|_, value| value.reply != reply);
                    }
                    _ => {},
                }
                continue;
            }
            if let Some(index) = section.strip_prefix("setup/harness/").and_then(|n| n.parse::<usize>().ok()) {
                if let Event::Hook { peer, reply: Some(reply), .. } = event {
                    let done: Done<bool> = Box::new(move |io, result| {
                        use crate::json::{self, Data};
                        let body = match &result {
                            Ok(enabled) => Data::Object(vec![("enabled", Data::Bool(*enabled))]),
                            Err(error) => Data::Object(vec![("error", Data::String(&error.message))]),
                        };
                        if let Ok(bytes) = json::write(&body) { let _ = io.reply(reply, &bytes); }
                    });
                    match peer {
                        Some(peer) => self.setup(&mut system, index, peer, done),
                        None => done(&mut system, Err(Error { code: "setup", message: "Cannot verify launch socket peer".into() })),
                    }
                }
                continue;
            }
            if let Some(index) = section
                .strip_prefix("mux/")
                .and_then(|n| n.parse::<usize>().ok())
            {
                let mut ui = Updates {
                    exits: Vec::new(),
                    replies: replies.clone(),
                    observers: &observers,
                    module: index,
                    nodes: self.nodes.clone(),
                    scopes: self.scopes.clone(),
                    retired: self.retired.clone(),
                    questions: self.questions.clone(),
                    interactions: self.interactions.clone(),
                    held: self.held.clone(),
                    sides: self.sides.clone(),
                    controls: self.controls.clone(),
                    probes: self.probes.clone(),
                    candidates: self.candidates.clone(),
                    pending: self.updates.clone(),
                    login: self.login.clone(),
                };
                self.multiplexers[index]
                    .borrow_mut()
                    .event(&mut system, &mut ui, event);
                for (index, process, status) in ui.exits {
                    let harness = self.harnesses[index].clone();
                    system.defer(Box::new(move |io| {
                        harness.borrow_mut().exited(io, &process, status)
                    }));
                }
                continue;
            }
            if let Some(index) = section
                .strip_prefix("harness/")
                .and_then(|n| n.parse::<usize>().ok())
            {
                let mut ui = Updates {
                    exits: Vec::new(),
                    replies: replies.clone(),
                    observers: &observers,
                    module: usize::MAX,
                    nodes: self.nodes.clone(),
                    scopes: self.scopes.clone(),
                    retired: self.retired.clone(),
                    questions: self.questions.clone(),
                    interactions: self.interactions.clone(),
                    held: self.held.clone(),
                    sides: self.sides.clone(),
                    controls: self.controls.clone(),
                    probes: self.probes.clone(),
                    candidates: self.candidates.clone(),
                    pending: self.updates.clone(),
                    login: self.login.clone(),
                };
                self.harnesses[index]
                    .borrow_mut()
                    .event(&mut system, &mut ui, event);
                continue;
            }
            if let Some(index) = section
                .strip_prefix("plugin/")
                .and_then(|n| n.parse::<usize>().ok())
            {
                let mut ui = Updates {
                    exits: Vec::new(),
                    replies: replies.clone(),
                    observers: &observers,
                    module: usize::MAX,
                    nodes: self.nodes.clone(),
                    scopes: self.scopes.clone(),
                    retired: self.retired.clone(),
                    questions: self.questions.clone(),
                    interactions: self.interactions.clone(),
                    held: self.held.clone(),
                    sides: self.sides.clone(),
                    controls: self.controls.clone(),
                    probes: self.probes.clone(),
                    candidates: self.candidates.clone(),
                    pending: self.updates.clone(),
                    login: self.login.clone(),
                };
                self.plugins[index]
                    .borrow_mut()
                    .event(&mut system, &mut ui, event);
                continue;
            }
            if let Event::Done { work, result } = &event
                && Some(*work) == self.identity_job
            {
                self.identity = Some(match result {
                    Ok(Output::Bytes(bytes)) => {
                        Json::parse(bytes).map_err(|error| io::Error::other(error.message))?
                    }
                    Err(error) => return Err(io::Error::new(error.kind(), error.to_string())),
                    _ => return Err(io::ErrorKind::InvalidData.into()),
                });
                continue;
            }
            if self.archive(&mut system, &event, &replies, &observers) {
                continue;
            }
            if let Some(login) = &self.login {
                if login::Login::event(login, &mut system, &event, &self.multiplexers)? {
                    continue;
                }
            }
            let Event::Ready { fd, read, write } = event else {
                continue;
            };
            if Some(fd) == listener {
                match system.accept(fd) {
                    Ok(fd) => {
                        clients.insert(fd, Client::new(fd));
                        system.interest(fd, true, false)?;
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(error) => return Err(error),
                }
                continue;
            }
            let fd = if clients.contains_key(&fd) {
                fd
            } else {
                clients
                    .iter()
                    .find_map(|(&key, c)| (c.write == fd).then_some(key))
                    .unwrap_or(fd)
            };
            let Some(client) = clients.get_mut(&fd) else {
                continue;
            };
            let mut closed = client.failed;
            if read && !closed && !client.eof {
                let mut bytes = [0; 65_536];
                match system.read(fd, &mut bytes) {
                    Ok(0) => {
                        self.cancel_creations(&mut system, fd, None);
                        client.eof = true;
                        let ids: BTreeSet<_> = observers
                            .iter()
                            .filter(|(peer, _, _)| *peer == fd)
                            .map(|(_, id, _)| *id)
                            .chain(
                                self.questions
                                    .borrow()
                                    .iter()
                                    .filter(|((peer, _, _, _), _)| *peer == fd)
                                    .map(|(_, question)| question.request),
                            )
                            .collect();
                        self.windows.borrow_mut().retain(|(peer, _), _| *peer != fd);
                        observers.retain(|(peer, _, _)| *peer != fd);
                        self.questions
                            .borrow_mut()
                            .retain(|(peer, _, _, _), _| *peer != fd);
                        for id in ids {
                            client.cancel(&mut system, id);
                        }
                        closed = true;
                    }
                    Ok(count) => {
                        if traffic.is_some() {
                            traffic = Some(system.now());
                        }
                        let requests = match client.feed(&bytes[..count]) {
                            Ok(requests) => requests,
                            Err(_) => {
                                client.failed = true;
                                Vec::new()
                            }
                        };
                        for (header, body) in requests {
                            if header.kind == wire::Kind::Cancel {
                                self.windows.borrow_mut().retain(|(peer, request), _| {
                                    *peer != fd || *request != Some(header.id)
                                });
                                self.cancel_creations(&mut system, fd, Some(header.id));
                                client.cancel(&mut system, header.id);
                                self.questions
                                    .borrow_mut()
                                    .retain(|(peer, _, _, _), question| {
                                        *peer != fd || question.request != header.id
                                    });
                                observers.retain(|(peer, id, _)| *peer != fd || *id != header.id);
                                continue;
                            }
                            if header.kind != wire::Kind::Request
                                || !client.pending.insert(header.id)
                            {
                                client.failed = true;
                                break;
                            }
                            match wire::body::decode(&body).and_then(|value| value.root().write()) {
                                Ok(body) => self.request(
                                    &mut system,
                                    fd,
                                    header.id,
                                    &body,
                                    &replies,
                                    &mut observers,
                                ),
                                Err(error) => failure(&replies, fd, header.id, error),
                            }
                        }
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                        ) => {}
                    Err(_) => {
                        client.failed = true;
                        closed = true;
                    }
                }
            }
            closed |= client.failed;
            if write && !closed {
                if let Some(bytes) = client.output.front() {
                    match system.write(client.write, bytes) {
                        Ok(0) => {
                            client.failed = true;
                            closed = true;
                        }
                        Ok(count) => {
                            if traffic.is_some() {
                                traffic = Some(system.now());
                            }
                            client
                                .output
                                .consume(count)
                                .map_err(|_| io::ErrorKind::InvalidData)?;
                        }
                        Err(error)
                            if matches!(
                                error.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                            ) => {}
                        Err(_) => {
                            client.failed = true;
                            closed = true;
                        }
                    }
                }
            }
            if client.eof
                && !client.failed
                && (!client.pending.is_empty()
                    || !client.messages.is_empty()
                    || client.output.front().is_some())
            {
                closed = false;
            }
            if client.eof
                && client.pending.is_empty()
                && client.messages.is_empty()
                && client.output.front().is_none()
            {
                closed = true;
            }
            if closed {
                client.abort(&mut system, None);
                let write = client.write;
                clients.remove(&fd);
                self.questions
                    .borrow_mut()
                    .retain(|(peer, _, _, _), _| *peer != fd);
                observers.retain(|(peer, _, _)| *peer != fd);
                system.close(fd);
                if write != fd {
                    system.close(write);
                }
                if listener.is_none() {
                    system.finish_replay()?;
                    return Ok((0, false));
                }
            } else {
                system.section("ui");
                system.interest(
                    fd,
                    !client.eof && client.output.space() >= FRAME,
                    client.write == fd && client.output.front().is_some(),
                )?;
                if client.write != fd {
                    system.interest(client.write, false, client.output.front().is_some())?;
                }
            }
        }
    }

    /// Followed archives end with their request; a change of one starts its next read. True
    /// when `event` was such a change.
    fn archive(
        &self,
        system: &mut System,
        event: &Event,
        replies: &Replies,
        observers: &[Observer],
    ) -> bool {
        self.archives.borrow_mut().retain(|&(fd, id), followed| {
            let open = observers.iter().any(|(peer, request, scope)| {
                (*peer, *request) == (fd, id) && matches!(scope, Scope::Archive)
            });
            if !open {
                system.unwatch(followed.watch);
            }
            open
        });
        let &Event::Changed { watch, reset } = event else {
            return false;
        };
        let key = self
            .archives
            .borrow()
            .iter()
            .find_map(|(key, followed)| (followed.watch == watch).then_some(*key));
        let Some(key) = key else {
            return false;
        };
        if reset {
            // A replaced file has a new inode: watch the path again.
            let mut archives = self.archives.borrow_mut();
            let followed = archives.get_mut(&key).unwrap();
            system.unwatch(followed.watch);
            if let Ok(watch) = system.watch(&followed.source.path, false) {
                followed.watch = watch;
            }
        }
        crate::dispatch::follow(system, &self.archives, replies, key);
        true
    }

    fn request(
        &mut self,
        system: &mut System,
        fd: RawFd,
        id: u64,
        body: &[u8],
        replies: &Replies,
        observers: &mut Vec<Observer>,
    ) {
        let result = (|| {
            let document = Rc::new(Json::parse(body)?);
            let root = document.root();
            let (method, params) =
                crate::dispatch::parameters(root, |method| self.allowed(method))?;
            let mut grants = vec![login::required(method)];
            if ["mux", "terminal", "node", "parent"]
                .iter()
                .any(|key| params.get(key).is_some())
            {
                if let Some(mux) = self.multiplexers.get(self.route(params)) {
                    match mux.borrow().name() {
                        "tmux" => grants.push("tmux.pane"),
                        "herdr" => grants.extend(["herdr.rpc", "herdr.terminal"]),
                        _ => {}
                    }
                }
            }
            if grants
                .iter()
                .any(|capability| !login::permits(&self.permissions, capability))
            {
                return Err(Error {
                    code: "permission_denied",
                    message: "This SSH feature is disabled".into(),
                });
            }
            self.admitted
                .insert((fd, id), (grants, Rc::new(Cell::new(true))));
            let observed = params.get("size").is_some() || params.get("rows").is_some();
            if matches!(
                method,
                "backends.open" | "terminals.attach" | "terminals.observe" | "chat.open"
            ) || (method == "terminals.create" && observed)
            {
                let index = self.route(params);
                let scope = match method {
                    "backends.open" => Scope::Backend(index),
                    "terminals.create" => Scope::Created,
                    "terminals.attach" => {
                        Scope::Terminal(crate::dispatch::number(params, "terminal")?)
                    }
                    "terminals.observe" => {
                        Scope::Events(crate::dispatch::number(params, "terminal")?)
                    }
                    _ if params.get("transcript").is_some() => Scope::Archive,
                    _ => {
                        let terminal = crate::dispatch::number(params, "terminal")?;
                        let session = params.get("session").and_then(|v| v.string());
                        let binding = self.binding(terminal, session).map(|(_, binding)| binding)
                            .or_else(|error| if session.is_none() {
                                self.candidate(terminal).map(|(_, binding, _)| binding).ok_or(error)
                            } else { Err(error) })?;
                        Scope::Chat(terminal, binding.session)
                    }
                };
                observers.push((fd, id, scope));
            }
            crate::dispatch::Request {
                helper: self,
                io: system,
                replies: replies.clone(),
                document: document.clone(),
                fd,
                id,
            }
            .dispatch(method, params)
        })();
        if let Err(error) = result {
            observers.retain(|(peer, request, _)| *peer != fd || *request != id);
            failure(replies, fd, id, error);
        }
    }
}

pub(crate) fn failure(replies: &Replies, fd: RawFd, id: u64, error: Error) {
    replies
        .borrow_mut()
        .push_back((fd, wire::Kind::Response, id, wire::problem(&error)));
}

/// Wake the detached login at `at`, when its idle window may end.
fn detached(system: &mut System, at: Instant) {
    let section = Io::section(system, DETACHED);
    system.timer(at);
    Io::section(system, &section);
}
