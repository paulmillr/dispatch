#[path = "command.rs"]
pub mod command;
#[path = "control.rs"]
mod control;
#[path = "events.rs"]
mod events;

use crate::{
    approvals::{Approvals, Owner},
    channel::{Channels, failure, os},
    hooks,
    jobs::{Jobs, scan},
    questions, queue,
};
use dispatch_helper_core::{
    api::*,
    json::{Data, Value},
};
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet},
    path::Path,
    process::Command,
    rc::Rc,
};

#[derive(Default)]
pub struct Codex {
    jobs: Jobs,
    /// Model catalog servers, one per way of running Codex (control.rs catalog).
    catalogs: Channels,
    headers: crate::jobs::Headers,
    screens: BTreeMap<(u32, [u64; 2]), String>,
    models: Rc<RefCell<BTreeMap<(u32, [u64; 2]), Vec<Choice>>>>,
    sides: Channels,
    parents: Rc<RefCell<BTreeMap<String, Process>>>,
    main: crate::attach::Main,
    launch: crate::launch::Launch,
    archives: crate::paging::Archives,
    bindings: BTreeMap<String, Binding>,
    states: Rc<RefCell<BTreeMap<String, State>>>,
    forms: Rc<RefCell<BTreeMap<String, questions::Pending>>>,
    live: Rc<RefCell<BTreeMap<String, crate::live::Live>>>,
    rows: Rc<RefCell<BTreeMap<String, Vec<queue::Row>>>>,
    revision: Rc<RefCell<BTreeMap<String, u64>>>,
    /// Native queue change counter: a list started before the latest change is discarded; c1654cc CodexPatchConnection.swift:579-601.
    changes: Rc<RefCell<BTreeMap<String, u64>>>,
    refreshing: Rc<RefCell<BTreeSet<String>>>,
    /// A failed queue refresh lists again at its time; c1654cc CodexPatchConnection.swift:612-625.
    retries: Rc<RefCell<BTreeMap<String, (std::time::Instant, Binding)>>>,
    /// UI updates produced by IO completions, published from the next Harness::event.
    updates: Rc<RefCell<Vec<Update>>>,
    commands: Rc<RefCell<command::Commands>>,
    /// Main-thread PermissionRequest hook cards.
    approvals: Approvals,
    /// Bound rollouts followed while no native channel streams them.
    follows: crate::follow::Follows,
    /// Executables identified as Codex for provisional bindings (jobs::provisional).
    versions: Rc<RefCell<crate::jobs::Versions>>,
    /// Provisional TUIs (pid, start) whose /status was sent through the chat, and the session
    /// their /status screen showed (core P2; c1654cc ChatCommands.swift:418-436).
    pub(crate) statuses: Rc<RefCell<BTreeMap<(u32, [u64; 2]), Option<String>>>>,
    /// Side agents' private directories, removed when the agent exits.
    exits: crate::owned::Exits,
    /// Followed rollouts to read again (follow::Sink::reloads).
    reloads: Rc<RefCell<Vec<Binding>>>,
    /// Per menu-walking TUI (pid, start): the selected lines when its last keys went out; the
    /// next key waits for their effect.
    keyed: BTreeMap<(u32, [u64; 2]), Vec<String>>,
    reading: BTreeMap<(u32, [u64; 2]), command::Reading>,
    walks: Rc<RefCell<BTreeMap<(u32, [u64; 2]), crate::menu::Walk>>>,
    /// Context lines earlier pages already found (paging::Known).
    known: crate::paging::Known,
}

impl Codex {

    fn archive(&mut self, io: &mut dyn Io, source: &Transcript, pages: usize, done: Done<Archive>) {
        let archives = self.archives.clone();
        let source = source.clone();
        let mut saved = source.clone();
        // Single-page tests bypass the archive's replacement/publication state.
        if pages == 1 {
            saved.earlier = None;
        }
        crate::paging::Reader::read(
            self.jobs.clone(),
            io,
            source,
            (self.known.clone(), pages),
            Box::new(move |io, result| {
                deferred(done)(
                    io,
                    result.map(|value| crate::paging::archive(&archives, &saved, value, false)),
                );
            }),
        );
    }

}

fn input(text: &str) -> Data<'_> {
    Data::Array(vec![Data::Object(vec![
        ("type", Data::String("text")),
        ("text", Data::String(text)),
        ("text_elements", Data::Array(Vec::new())),
    ])])
}

fn sent(result: Result<Json, Error>) -> Result<Sent, Error> {
    result.map(|_| Sent::Native {
        written: true,
        may_have_sent: false,
        reason: None,
    })
}

impl Harness for Codex {
    fn name(&self) -> &str {
        "Codex"
    }

    fn key(&self) -> &str {
        "codex"
    }

    fn exited(&mut self, io: &mut dyn Io, process: &Process, _status: Option<i32>) {
        self.models.borrow_mut().remove(&(process.pid, process.start));
        self.screens.remove(&(process.pid, process.start));
        self.reading.remove(&(process.pid, process.start));
        self.walks
            .borrow_mut()
            .remove(&(process.pid, process.start));
        self.versions
            .borrow_mut()
            .processes
            .remove(&(process.pid, process.start));
        self.launch.exited(&self.jobs, io, process);
        for binding in self.follows.bindings() {
            if binding.process.pid == process.pid && binding.process.start == process.start {
                self.follows.stop(io, &binding.session);
            }
        }
        self.exited_commands(io, process);
        if let Some(watch) = self
            .main
            .watches
            .borrow_mut()
            .remove(&crate::attach::key(process))
        {
            let _ = watch
                .borrow_mut()
                .close(io, failure("closed", "Codex exited"));
        }
        let mut channels = self.main.channels.borrow_mut();
        let sessions = channels
            .iter()
            .filter(|(_, channel)| {
                let channel = channel.borrow();
                channel.binding.process.pid == process.pid
                    && channel.binding.process.start == process.start
            })
            .map(|(session, _)| session.clone())
            .collect::<Vec<_>>();
        for session in sessions {
            if let Some(channel) = channels.remove(&session) {
                let _ = channel
                    .borrow_mut()
                    .close(io, failure("closed", "Codex exited"));
            }
            self.forms.borrow_mut().remove(&session);
            self.live.borrow_mut().remove(&session);
            self.states.borrow_mut().remove(&session);
            self.bindings.remove(&session);
        }
        let mut parents = self.parents.borrow_mut();
        let sessions = parents
            .iter()
            .filter(|(_, parent)| parent.pid == process.pid && parent.start == process.start)
            .map(|(session, _)| session.clone())
            .collect::<Vec<_>>();
        for session in sessions {
            parents.remove(&session);
            if let Some(channel) = self.sides.borrow_mut().remove(&session) {
                let _ = channel
                    .borrow_mut()
                    .close(io, failure("closed", "Codex exited"));
            }
            self.forms.borrow_mut().remove(&session);
            self.live.borrow_mut().remove(&session);
            self.states.borrow_mut().remove(&session);
        }
    }

    fn matches(&self, process: &Process) -> bool {
        let services = [
            "exec",
            "e",
            "review",
            "app-server",
            "mcp-server",
            "login",
            "logout",
            "debug",
            "sandbox",
            "completion",
            "--version",
            "-V",
            "--help",
            "-h",
        ];
        process
            .executable
            .file_name()
            .is_some_and(|name| name == "codex")
            && !process.arguments.is_empty()
            && !process
                .arguments
                .iter()
                .skip(1)
                .any(|argument| services.contains(&argument.as_str()))
    }

    fn launch(&mut self, io: &mut dyn Io, cwd: &Path, arguments: &[String], done: Done<Command>) {
        Codex::invoke(self, io, cwd, arguments, done);
    }
    fn configures(&self, arguments: &[String]) -> bool {
        crate::launch::Invocation::parse(arguments).is_some()
    }
    fn command(&mut self, io: &mut dyn Io, binding: &Binding, text: &str, done: Done<Outcome>) {
        Codex::command(self, io, binding, text, done);
    }

    fn identify(
        &mut self,
        io: &mut dyn Io,
        process: &Process,
        hook: Option<&Hook>,
        done: Done<Option<Binding>>,
    ) {
        if !self.matches(process) {
            deferred(done)(io, Ok(None));
            return;
        }
        if let Some(binding) = self.main.current(process) {
            let channel = self.main.channels.borrow().get(&binding.session).cloned().unwrap();
            // Identity can precede the private main's rollout and native subscription.
            if channel.borrow().track_main {
                return crate::attach::locate(self.jobs.clone(), self.main.snapshots.clone(), io, channel, done);
            }
            return deferred(done)(io, Ok(Some(binding)));
        }
        let key = crate::attach::key(process);
        let mut replacements = self.main.replacements.borrow_mut();
        let replacement = replacements.get(&key).filter(|binding| {
            binding.transcript.as_ref().is_some_and(|path| process.files.iter().any(|file| &file.path == path))
        }).map(|binding| binding.session.clone());
        if replacement.is_none() && let Some(binding) = replacements.remove(&key) {
            eprintln!("dispatch-helper: Codex replacement no longer owned pid={} start={:?} session={}",
                process.pid, process.start, binding.session);
        }
        drop(replacements);
        let confirmed = self.statuses.borrow().get(&(process.pid, process.start)).cloned().flatten();
        let session = confirmed.or(replacement).or_else(|| hook
            .filter(|hook| hook.pid == Some(process.pid))
            .and_then(|hook| hook.session.clone()));
        let mut files: Vec<_> = process
            .files
            .iter()
            .filter(|file| file.path.extension().is_some_and(|value| value == "jsonl"))
            .cloned()
            .collect();
        files.sort_by(|a, b| a.path.cmp(&b.path));
        files.dedup();
        // Until its rollout opens, a TUI is known by the session its /status showed.
        let (statuses, key) = (self.statuses.clone(), (process.pid, process.start));
        let (jobs, versions, headers, scanned) = (self.jobs.clone(), self.versions.clone(), self.headers.clone(), process.clone());
        let replacements = self.main.replacements.clone();
        let selected = session.clone();
        let owner = crate::attach::key(process);
        let fallback: crate::attach::Fallback = Box::new(move |io, done| {
            let done: Done<Option<Binding>> = Box::new(move |io, result| {
                let mut statuses = statuses.borrow_mut();
                let current = statuses.get(&key).cloned().flatten()
                    .or_else(|| replacements.borrow().get(&owner).map(|binding| binding.session.clone()));
                if current.is_some() && current != selected {
                    drop(statuses);
                    eprintln!("dispatch-helper: Codex identity changed during scan pid={} start={:?} selected={:?} current={:?}", key.0, key.1, selected, current);
                    return done(io, Err(failure("identity", "Codex session changed during identification.")));
                }
                let result = result.map(|binding| {
                    binding.map(|mut binding| {
                        match statuses.get(&key) {
                            Some(Some(session)) if binding.session == *session && binding.transcript.is_some() => {
                                replacements.borrow_mut().insert(crate::attach::key(&binding.process), binding.clone());
                                statuses.remove(&key);
                            }
                            Some(Some(session)) if binding.session.is_empty() => {
                                binding.session = session.clone()
                            }
                            _ if !binding.session.is_empty() => _ = statuses.remove(&key),
                            _ => {}
                        }
                        binding
                    })
                });
                drop(statuses);
                done(io, result)
            });
            scan(
                jobs,
                io,
                scanned,
                files,
                session,
                Vec::new(),
                versions,
                headers,
                done,
            );
        });
        self.main.discover(
            self.jobs.clone(),
            self.launch.servers.clone(),
            io,
            process.clone(),
            done,
            fallback,
        );
    }

    fn hook(&mut self, message: &Json) -> Result<Hook, Error> {
        hooks::read(message)
    }

    fn history(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        earlier: Option<&str>,
        done: Done<Page>,
    ) {
        self.bindings
            .insert(binding.session.clone(), binding.clone());
        let Some(path) = binding.transcript.clone() else {
            // A provisional binding (session "", core P1) has no history until its session is
            // known; a live channel's history is its live records.
            if binding.session.is_empty()
                || self.channel(binding).is_ok()
                || self.main.bound(binding)
                || self.statuses.borrow().get(&(binding.process.pid, binding.process.start))
                    .and_then(Option::as_deref) == Some(binding.session.as_str())
            {
                let records = self
                    .live
                    .borrow()
                    .get(&binding.session)
                    .map(|live| live.records.clone())
                    .unwrap_or_default();
                if earlier.is_none() {
                    let forms = &self.forms;
                    opened(
                        io,
                        forms,
                        &self.updates,
                        binding,
                        questions::Pending::default(),
                    );
                }
                deferred(done)(
                    io,
                    Ok(Page {
                        records,
                        earlier: None,
                    }),
                );
                return;
            }
            deferred(done)(
                io,
                Err(failure("history", "No Codex rollout is available.")),
            );
            return;
        };
        let states = self.states.clone();
        let forms = self.forms.clone();
        let updates = self.updates.clone();
        let live = self.channel(binding).is_ok();
        let initial = earlier.is_none();
        let session = binding.session.clone();
        let owner = binding.clone();
        let follows = self.follows.clone();
        let versions = self.versions.clone();
        crate::paging::Reader::read(
            self.jobs.clone(),
            io,
            Transcript {
                later: None,
                path,
                session: session.clone(),
                earlier: earlier.map(str::to_owned),
            },
            (self.known.clone(), 3),
            Box::new(move |io, result| {
                let result = result.map(|(page, mut state, (metadata, version), recovered, at)| {
                    let before = states.borrow().get(&session).cloned();
                    if let Some(version) = &version {
                        versions
                            .borrow_mut()
                            .processes
                            .insert((owner.process.pid, owner.process.start), version.clone());
                    }
                    if initial {
                        follows.start(io, &owner, metadata, at);
                        follows.limit(&owner.session, live);
                    }
                    // c1654cc ChatCoordinator.swift:1090-1091: only the recent page restores questions.
                    if initial {
                        opened(io, &forms, &updates, &owner, recovered);
                    }
                    if initial
                        && (!live
                            || !states
                                .borrow()
                                .get(&session)
                                .is_some_and(|state| state.model.is_some()))
                    {
                        let mut states = states.borrow_mut();
                        // Rollouts carry no thread name; only native metadata or a verified
                        // terminal status can replace the name already known for this session.
                        state.title = states.get(&session).and_then(|state| state.title.clone());
                        state.version = states.get(&session).and_then(|state| state.version.clone());
                        state.mode = states.get(&session).and_then(|state| state.mode.clone());
                        states.insert(session.clone(), state);
                    }
                    if let Some(version) = version {
                        states.borrow_mut().entry(session.clone()).or_default().version = Some(version);
                    }
                    // The initial page can complete a turn after chat.open already published
                    // its cached state. Publish every changed field, even with the same version.
                    if let Some(state) = states.borrow().get(&session).filter(|state| before.as_ref() != Some(state)) {
                        updates.borrow_mut().push(Update::State { binding: owner, state: state.clone() });
                        let now = io.now();
                        io.timer(now);
                    }
                    page
                });
                deferred(done)(io, result);
            }),
        );
    }

    fn read(&mut self, io: &mut dyn Io, source: &Transcript, done: Done<Archive>) {
        let archives = self.archives.clone();
        if let Some(cursor) = &source.later {
            let (jobs, source) = (self.jobs.clone(), source.clone());
            return crate::paging::later(jobs, io, archives, source.clone(), cursor, done);
        }
        self.archive(io, source, 3, done);
    }

    fn state(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<State>) {
        let versions = self.versions.clone();
        let key = (binding.process.pid, binding.process.start);
        let done: Done<State> = Box::new(move |io, result| {
            deferred(done)(
                io,
                result.map(|mut state| {
                    if state.version.is_none() {
                        state.version = versions.borrow().processes.get(&key).cloned();
                    }
                    state
                }),
            );
        });
        if self.channel(binding).is_err() && !self.main.bound(binding) {
            self.main
                .open(self.jobs.clone(), io, binding.clone(), Box::new(|_, _| {}));
        }
        if (self.channel(binding).is_ok() || self.main.bound(binding))
            && (binding.transcript.is_none()
                || self
                    .states
                    .borrow()
                    .get(&binding.session)
                    .is_some_and(|state| state.model.is_some()))
        {
            let state = self
                .states
                .borrow()
                .get(&binding.session)
                .cloned()
                .unwrap_or_default();
            deferred(done)(io, Ok(state));
            return;
        }
        let states = self.states.clone();
        let session = binding.session.clone();
        self.history(
            io,
            binding,
            None,
            Box::new(move |io, result| {
                deferred(done)(
                    io,
                    result.map(|_| states.borrow().get(&session).cloned().unwrap_or_default()),
                );
            }),
        );
    }

    fn commands(&self, _binding: &Binding) -> Vec<String> {
        [
            "/btw",
            "/side",
            "/fast",
            "/compact",
            "/rename",
            "/init",
            "/review",
            "/stop",
            "/copy",
            "/model",
            "/plan",
            "/goal",
            "/clear",
            "/new",
            "/status",
            "/terminal",
            "/hooks",
            "/permissions",
            "/resume",
            "/exit",
            "/quit",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect()
    }

    fn send(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        text: &str,
        mode: Mode,
        command: bool,
        done: Done<Sent>,
    ) {
        self.submit(io, binding, text, mode, command, false, done);
    }

    fn stop(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<Sent>) {
        let turn = self
            .states
            .borrow()
            .get(&binding.session)
            .and_then(|state| state.activity.clone());
        if let Some(turn) = turn.filter(|_| self.channel(binding).is_ok()) {
            self.request(
                io,
                binding,
                "turn/interrupt",
                Data::Object(vec![
                    ("threadId", Data::String(&binding.session)),
                    ("turnId", Data::String(&turn)),
                ]),
                Box::new(move |io, result| deferred(done)(io, sent(result))),
            );
        } else {
            deferred(done)(io, Ok(Sent::Keys(vec![Input::Key(Key::Escape)])));
        }
    }

    fn models(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<Menu>) {
        let current = self
            .states
            .borrow()
            .get(&binding.session)
            .and_then(|state| state.model.clone());
        self.catalog(
            io,
            binding,
            Box::new(move |io, result| {
                deferred(done)(
                    io,
                    result.map(|catalog| Menu {
                        default: catalog.models.iter().find(|model| model.default && !model.hidden)
                            .map(|model| model.choice.id.clone()),
                        result: None,
                        choices: catalog
                            .models
                            .into_iter()
                            .filter(|model| !model.hidden)
                            .map(|model| model.choice)
                            .collect(),
                        current,
                    }),
                );
            }),
        );
    }

    fn efforts(&mut self, io: &mut dyn Io, binding: &Binding, model: &str, done: Done<Menu>) {
        let model = model.to_owned();
        let current = self
            .states
            .borrow()
            .get(&binding.session)
            .and_then(|state| state.effort.clone());
        self.catalog(
            io,
            binding,
            Box::new(move |io, result| {
                let result = result.and_then(|catalog| {
                    catalog
                        .models
                        .into_iter()
                        .find(|value| value.choice.id == model || value.native == model)
                        .ok_or_else(|| failure("models", "The selected model is unavailable."))
                });
                deferred(done)(
                    io,
                    result.map(|model| Menu {
                        default: Some(model.effort),
                        result: None,
                        choices: model
                            .efforts
                            .into_iter()
                            .map(|effort| effort.choice)
                            .collect(),
                        current,
                    }),
                );
            }),
        );
    }

    fn select(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        model: &str,
        effort: Option<&str>,
        done: Done<Sent>,
    ) {
        self.selection(io, binding, model, effort, done);
    }

    fn menu(&mut self, io: &mut dyn Io, binding: &Binding, goal: &Goal, screen: &Screen, settled: bool) -> Step {
        let key = (binding.process.pid, binding.process.start);
        if matches!(goal, Goal::Send { command: true, .. })
            && let Some(reading) = self.reading.get_mut(&key)
        {
            let current = self.states.borrow().get(&binding.session).and_then(|state| state.goal.clone());
            let active = self.main.current(&binding.process);
            let session = active.as_ref().map(|current| current.session.as_str())
                .or_else(|| self.main.bound(binding).then_some(binding.session.as_str()));
            let step = reading.step(binding, screen, current.as_deref(), session);
            if matches!(step, Step::Done(_)) && reading.replaces()
                && let Some(session) = crate::menu::status(&screen.text).map(|status| status.session)
                    .or_else(|| self.main.current(&binding.process).map(|current| current.session))
                && session != binding.session
            {
                self.statuses.borrow_mut().insert(key, Some(session));
                self.updates.borrow_mut().push(Update::Identity(binding.process.clone()));
                let now = io.now();
                io.timer(now);
            }
            // Clearing has no rollout event; only the newly printed native result proves it.
            if matches!(step, Step::Done(_))
                && matches!(goal, Goal::Send { text, .. } if text.trim() == "/goal clear")
            {
                let mut states = self.states.borrow_mut();
                let state = states.entry(binding.session.clone()).or_default();
                if state.goal.take().is_some() {
                    self.updates.borrow_mut().push(Update::State {
                        binding: binding.clone(),
                        state: state.clone(),
                    });
                    let now = io.now();
                    io.timer(now);
                }
            }
            if matches!(step, Step::Done(_))
                && let Some(status) = crate::menu::status(&screen.text)
                && status.session == binding.session
            {
                let mut states = self.states.borrow_mut();
                let state = states.entry(binding.session.clone()).or_default();
                if state.title != status.name || state.mode != status.mode {
                    state.title = status.name;
                    state.mode = status.mode;
                    self.updates.borrow_mut().push(Update::State {
                        binding: binding.clone(),
                        state: state.clone(),
                    });
                    let now = io.now();
                    io.timer(now);
                }
            }
            if matches!(step, Step::Done(_) | Step::Fail(_)) {
                self.reading.remove(&key);
            }
            return step;
        }
        if let Goal::Send { text, command: true, .. } = goal
            && let Some(title) = crate::menu::command(text.trim())
        {
            let key = (binding.process.pid, binding.process.start);
            let Some(before) = self.screens.get(&key) else {
                self.screens.insert(key, screen.text.clone());
                return Step::Keys(vec![Input::Paste(text.clone()), Input::Key(Key::Enter)]);
            };
            let result = (screen.text != *before).then(|| match text.trim() {
                "/goal" => crate::menu::goal(&screen.text).map(|(text, _)| text),
                "/goal edit" => crate::menu::editor(&screen.text),
                "/status" => crate::menu::status(&screen.text).map(|status| status.text),
                "/fork" => crate::menu::forked(before, &screen.text).then(|| crate::menu::FORK.to_owned()),
                command => crate::menu::report(command, before, &screen.text),
            }).flatten();
            return match result {
                Some(text) => {
                    self.screens.remove(&key);
                    Step::Done(Menu { result: Some((title.into(), text)), choices: Vec::new(), current: None, default: None })
                }
                None => Step::Wait,
            };
        }
        // The selected (›) lines: what a key changes on every Codex menu and prompt.
        let selected = |text: &str| -> Vec<String> {
            let lines = text.lines().map(str::trim);
            lines
                .filter(|line| line.starts_with('›'))
                .map(str::to_owned)
                .collect()
        };
        // A key's effect is a changed selection; until then a redraw waits, and core's settled
        // sample (nothing changed for the settle bound) ends the wait.
        let key = (binding.process.pid, binding.process.start);
        if let Some(before) = self.keyed.remove(&key)
            && selected(&screen.text) == before
            && !settled
        {
            self.keyed.insert(key, before);
            return Step::Wait;
        }
        let model = match goal {
            Goal::Select { model, .. } | Goal::Efforts { model } => Some(model),
            _ => None,
        };
        let choosing = screen.text.lines().rev()
            .map(str::trim).find(|line| line.starts_with("Select "))
            .is_some_and(|line| line.starts_with("Select Model"));
        let translated = choosing.then(|| {
            let models = self.models.borrow();
            let choice = models.get(&key)?.iter().find(|choice| Some(&choice.id) == model)?;
            Some(match goal {
                Goal::Select { effort, .. } => Goal::Select { model: choice.label.clone(), effort: effort.clone() },
                Goal::Efforts { .. } => Goal::Efforts { model: choice.label.clone() },
                _ => return None,
            })
        }).flatten();
        let mut walks = self.walks.borrow_mut();
        let walk = walks.entry(key).or_default();
        let starts = matches!(goal, Goal::Choose { title, choice: Some(choice) }
            if title == "Select a review preset" || (*choice == 0 && title.contains("Implement this plan?")));
        if starts && walk.turn.is_none() {
            walk.turn = Some(self.follows.turn(binding));
        }
        let mut step = crate::menu::step(binding, translated.as_ref().unwrap_or(goal), screen, walk);
        // A menu can close before the turn starts. A fast completed turn counts too.
        if starts && matches!(step, Step::Done(_))
            && crate::menu::prompt(&screen.text).is_none()
            && walk.turn == Some(self.follows.turn(binding))
        {
            step = Step::Wait;
        }
        if matches!(step, Step::Done(_) | Step::Fail(_)) {
            walks.remove(&key);
        }
        if matches!(step, Step::Keys(_)) {
            self.keyed.insert(key, selected(&screen.text));
        }
        step
    }

    fn prompt(&mut self, binding: &Binding, screen: &Screen) -> Option<Interaction> {
        let key = (binding.process.pid, binding.process.start);
        let mut statuses = self.statuses.borrow_mut();
        if binding.session.is_empty()
            && let Some(learned @ None) = statuses.get_mut(&key)
        {
            *learned = crate::menu::status(&screen.text).map(|status| status.session);
        }
        drop(statuses);
        crate::menu::interaction(screen)
    }

    fn answer(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        interaction: &str,
        answers: Vec<(String, Answer)>,
        done: Done<Sent>,
    ) {
        if interaction == format!("command:{}", binding.session) {
            let result = self
                .reading
                .get_mut(&(binding.process.pid, binding.process.start))
                .ok_or_else(|| failure("question", "The command changed."))
                .and_then(|reading| reading.answer(&answers));
            deferred(done)(io, result);
            return;
        }
        if interaction == format!("menu:{}", binding.session) {
            let result = self
                .walks
                .borrow_mut()
                .get_mut(&(binding.process.pid, binding.process.start))
                .ok_or_else(|| failure("question", "The model confirmation changed."))
                .and_then(|walk| walk.answer(interaction, &answers));
            deferred(done)(io, result);
            return;
        }
        if let Some((result, closed)) = self.approvals.answer(io, binding, interaction, &answers) {
            self.updates.borrow_mut().extend(closed);
            let now = io.now();
            io.timer(now);
            deferred(done)(io, result);
            return;
        }
        let pending = self
            .forms
            .borrow()
            .get(&binding.session)
            .and_then(|pending| pending.forms.get(interaction))
            .cloned();
        let Some((form, request)) = pending else {
            deferred(done)(
                io,
                Err(failure("question", "This question is no longer pending.")),
            );
            return;
        };
        let forms = self.forms.clone();
        let updates = self.updates.clone();
        let owner = binding.clone();
        let id = interaction.to_owned();
        let finish: Done<Sent> = Box::new(move |io, result| {
            // An answered form closes for the UI, like Claude's harness and c1654cc ChatCoordinator.swift:419-420.
            if matches!(&result, Ok(Sent::Native { written: true, .. }))
                && let Some(pending) = forms.borrow_mut().get_mut(&owner.session)
                && let Some((form, _)) = pending.forms.remove(&id)
            {
                let mut interaction = form.interaction;
                interaction.questions.clear();
                updates.borrow_mut().push(Update::Interaction {
                    binding: owner,
                    interaction,
                });
                let now = io.now();
                io.timer(now);
            }
            deferred(done)(io, result);
        });
        if let Some(request) = request {
            let bytes = self
                .forms
                .borrow()
                .get(&binding.session)
                .and_then(|pending| pending.reply(&request, &answers))
                .ok_or_else(|| failure("question", "Invalid question answers."));
            match bytes.and_then(|bytes| self.channel(binding).map(|channel| (channel, bytes))) {
                Ok((channel, bytes)) => channel.borrow_mut().deliver(io, bytes, finish),
                Err(error) => deferred(finish)(io, Err(error)),
            }
        } else {
            let text = questions::answer(&form, &answers);
            match text {
                Some(text) => {
                    self.submit(io, binding, &text, Mode::Prompt, false, true, finish);
                }
                None => deferred(finish)(io, Err(failure("question", "Invalid question answers."))),
            }
        }
    }

    fn tool(&mut self, io: &mut dyn Io, binding: &Binding, record: &str, done: Done<Record>) {
        let id = record.to_owned();
        self.history(
            io,
            binding,
            None,
            Box::new(move |io, result| {
                deferred(done)(
                    io,
                    result.and_then(|page| {
                        page.records
                            .into_iter()
                            .find(|record| record.id == id && record.kind == RecordKind::Tool)
                            .ok_or_else(|| {
                                failure("tool", "The tool record is outside this history page.")
                            })
                    }),
                );
            }),
        );
    }

    fn native_queue(&self) -> bool {
        true
    }

    fn revoke(&mut self, io: &mut dyn Io, binding: &Binding, retire: bool, done: Done<()>) {
        self.updates.borrow_mut().extend(self.approvals.revoke(io, binding.process.pid));
        let now = io.now();
        io.timer(now);
        if !retire { return deferred(done)(io, Ok(())); }
        let Ok(channel) = self.channel(binding) else {
            return deferred(done)(io, Ok(()));
        };
        let next = channel.clone();
        queue::list(channel, io, queue::Pages::default(), None, Box::new(move |io, result| {
            let rows = match result {
                Ok(rows) => rows,
                Err(error) => return deferred(done)(io, Err(error)),
            };
            queue::clear(next, io, rows.into_iter().map(|row| row.id).collect(), done);
        }));
    }

    fn queue(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<Vec<Queued>>) {
        self.listing(io, binding, done);
    }

    fn queue_add(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        text: &str,
        mode: Mode,
        done: Done<Queued>,
    ) {
        let mut nonce = [0; 16];
        if let Err(error) = io.random(&mut nonce) {
            deferred(done)(io, Err(os(error)));
            return;
        }
        nonce[6] = (nonce[6] & 15) | 64;
        nonce[8] = (nonce[8] & 63) | 128;
        let mut client = String::new();
        for (index, byte) in nonce.into_iter().enumerate() {
            if [4, 6, 8, 10].contains(&index) {
                client.push('-');
            }
            client.push_str(&format!("{byte:02x}"));
        }
        let revisions = self.revision.clone();
        let session = binding.session.clone();
        self.change(
            io,
            binding,
            "add",
            vec![
                ("clientUserMessageId", Data::String(&client)),
                ("input", input(text)),
            ],
            Box::new(move |io, result| {
                let result =
                    result.and_then(|value| {
                        queue::row(value.root().get("queuedSubmission").ok_or_else(|| {
                            failure("queue", "No queued submission was returned.")
                        })?)
                    });
                deferred(done)(
                    io,
                    result.map(|row| {
                        let mut revisions = revisions.borrow_mut();
                        let revision = revisions.entry(session).or_default();
                        *revision += 1;
                        row.queued(mode, *revision)
                    }),
                );
            }),
        );
    }

    fn queue_edit(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        item: &str,
        revision: u64,
        text: Option<&str>,
        done: Done<()>,
    ) {
        if let Err(error) = self.check(binding, item, revision) {
            deferred(done)(io, Err(error));
            return;
        }
        if text.is_some()
            && self
                .rows
                .borrow()
                .get(&binding.session)
                .and_then(|rows| rows.iter().find(|row| row.id == item))
                .is_some_and(|row| !row.editable)
        {
            deferred(done)(
                io,
                Err(failure(
                    "queue",
                    "This message contains attachments or mentions and cannot be edited as plain text.",
                )),
            );
            return;
        }
        let mut fields = vec![("queuedSubmissionId", Data::String(item))];
        if let Some(text) = text {
            fields.push(("input", input(text)));
        }
        self.change(
            io,
            binding,
            if text.is_some() { "update" } else { "delete" },
            fields,
            Box::new(move |io, result| deferred(done)(io, result.map(|_| ()))),
        );
    }

    fn queue_send(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        item: &str,
        revision: u64,
        mode: Mode,
        done: Done<Sent>,
    ) {
        if let Err(error) = self.check(binding, item, revision) {
            deferred(done)(io, Err(error));
            return;
        }
        let row = self
            .rows
            .borrow()
            .get(&binding.session)
            .and_then(|rows| {
                rows.iter()
                    .find(|row| row.id == item)
                    .map(|row| (row.editable, row.client.clone(), row.input.clone()))
            })
            .unwrap();
        if mode != Mode::Steer {
            self.change(
                io,
                binding,
                "start",
                vec![("queuedSubmissionId", Data::String(item))],
                Box::new(move |io, result| deferred(done)(io, sent(result))),
            );
            return;
        }
        if !row.0 {
            deferred(done)(
                io,
                Err(failure(
                    "queue",
                    "Send this message with attachments or mentions from Terminal.",
                )),
            );
            return;
        }
        let turn = self
            .states
            .borrow()
            .get(&binding.session)
            .and_then(|state| state.activity.clone());
        let Some(turn) = turn else {
            deferred(done)(io, Err(failure("turn", "No active Codex turn.")));
            return;
        };
        let channel = match self.channel(binding) {
            Ok(channel) => channel,
            Err(error) => {
                deferred(done)(io, Err(error));
                return;
            }
        };
        let session = binding.session.clone();
        self.change(
            io,
            binding,
            "delete",
            vec![("queuedSubmissionId", Data::String(item))],
            Box::new(move |io, result| {
                let result = result.and_then(|value| {
                    if value.root().get("deleted").and_then(Value::boolean) == Some(true) {
                        Json::parse(&row.2).map(Some)
                    } else {
                        Ok(None)
                    }
                });
                match result {
                    Ok(Some(input)) => {
                        let params = Data::Object(vec![
                            ("threadId", Data::String(&session)),
                            ("expectedTurnId", Data::String(&turn)),
                            ("clientUserMessageId", Data::String(&row.1)),
                            ("input", Data::Value(input.root())),
                        ]);
                        channel.borrow_mut().request(
                            io,
                            "turn/steer",
                            params,
                            Box::new(move |io, result| {
                                let result = sent(result).map_err(|error| {
                                    let message = format!(
                                        "The queued message was removed, but sending could not be confirmed. Check Terminal before retrying. {}",
                                        error.message
                                    );
                                    failure("removed", message)
                                });
                                deferred(done)(io, result);
                            }),
                        );
                    }
                    Ok(None) => deferred(done)(
                        io,
                        Ok(Sent::Native {
                            written: false,
                            may_have_sent: false,
                            reason: Some("Another client already took the queued message.".into()),
                        }),
                    ),
                    Err(error) => deferred(done)(io, Err(error)),
                }
            }),
        );
    }

    fn queue_order(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        items: &[String],
        done: Done<()>,
    ) {
        self.change(
            io,
            binding,
            "reorder",
            vec![(
                "queuedSubmissionIds",
                Data::Array(items.iter().map(|id| Data::String(id)).collect()),
            )],
            Box::new(move |io, result| deferred(done)(io, result.map(|_| ()))),
        );
    }

    fn side(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        question: &str,
        read_only: bool,
        done: Done<Binding>,
    ) {
        let parents = self.parents.clone();
        let process = binding.process.clone();
        crate::owned::open(
            self.jobs.clone(),
            self.sides.clone(),
            self.exits.clone(),
            io,
            binding.clone(),
            question,
            read_only,
            Box::new(move |io, result| {
                if let Ok(side) = &result {
                    parents.borrow_mut().insert(side.session.clone(), process);
                }
                deferred(done)(io, result);
            }),
        );
    }

    fn side_close(&mut self, io: &mut dyn Io, side: &Binding, done: Done<()>) {
        if let Some(channel) = self.sides.borrow_mut().remove(&side.session) {
            self.parents.borrow_mut().remove(&side.session);
            self.forms.borrow_mut().remove(&side.session);
            self.live.borrow_mut().remove(&side.session);
            self.states.borrow_mut().remove(&side.session);
            let result = channel
                .borrow_mut()
                .close(io, failure("closed", "The side conversation closed."));
            deferred(done)(io, result);
        } else {
            deferred(done)(io, Ok(()));
        }
    }

    /// The helper's own hook command in Codex hooks.json; `route` reaches hooks through
    /// DISPATCH_HELPER_ENDPOINT instead (arch.md Install).
    fn install(
        &mut self,
        io: &mut dyn Io,
        _route: &Path,
        enabled: Option<bool>,
        agent: Option<&Binding>,
        done: Done<Install>,
    ) {
        crate::install::run(&self.jobs, io, enabled, agent.cloned(), deferred(done));
    }

    fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) {
        let (bindings, servers) = (&self.bindings, &self.launch.servers);
        // The bound TUI and the private server serving it (arch.md Main-thread hooks).
        let owners = |session: &str| -> Vec<Owner> {
            let servers = servers.borrow();
            let bound = bindings
                .values()
                .filter(|binding| binding.session == session);
            bound
                .flat_map(|binding| {
                    let served = servers
                        .values()
                        .filter(|server| server.process.as_ref() == Some(&binding.process));
                    let pids = served.map(|server| (server.pid, None));
                    pids.chain([(binding.process.pid, Some(binding.process.start))])
                        .map(|(pid, start)| Owner {
                            pid,
                            start,
                            binding: binding.clone(),
                        })
                        .collect::<Vec<_>>()
                })
                .collect()
        };
        if self.approvals.event(io, ui, &event, &owners, &self.states) {
            return;
        }
        // The follow is limited exactly while a native channel serves its conversation.
        for binding in self.follows.bindings() {
            let live = self.channel(&binding).is_ok();
            self.follows.limit(&binding.session, live);
        }
        let sink = crate::follow::Sink {
            updates: self.updates.clone(),
            states: self.states.clone(),
            forms: self.forms.clone(),
            reloads: self.reloads.clone(),
        };
        self.follows.event(&self.jobs, io, &event, &sink);
        self.launch.event(io, &event);
        if let Event::Exit { pid, .. } = event
            && let Some(path) = self.exits.borrow_mut().remove(&pid)
        {
            let _ = io.submit(Job::Remove {
                path,
                expected: Expected::Any,
            });
        }
        if let Event::Timer { at } = event {
            let due: Vec<Binding> = {
                let mut retries = self.retries.borrow_mut();
                let sessions: Vec<String> = retries
                    .iter()
                    .filter(|(_, (time, _))| *time <= at)
                    .map(|(session, _)| session.clone())
                    .collect();
                let due = sessions.iter().map(|session| retries.remove(session));
                due.flatten().map(|(_, binding)| binding).collect()
            };
            for binding in due {
                self.refresh(io, binding);
            }
            // The chat's history again (Update::History replaces it), or why it cannot be read.
            let reloads = std::mem::take(&mut *self.reloads.borrow_mut());
            for binding in reloads {
                let (updates, states) = (self.updates.clone(), self.states.clone());
                let owner = binding.clone();
                let done: Done<Page> = Box::new(move |io, result| {
                    let update = match result {
                        Ok(page) => Update::History {
                            binding: owner,
                            page,
                        },
                        Err(error) => {
                            let mut states = states.borrow_mut();
                            let state = states.entry(owner.session.clone()).or_default();
                            state.attention = Some(error.message);
                            Update::State {
                                binding: owner,
                                state: state.clone(),
                            }
                        }
                    };
                    updates.borrow_mut().push(update);
                    let now = io.now();
                    io.timer(now);
                });
                self.history(io, &binding, None, done);
            }
        }
        if let Event::Done { work, result } = event {
            if let Some(done) = self.jobs.borrow_mut().remove(&work) {
                done(io, result.map_err(os));
            }
            return;
        }
        let mut messages = Vec::new();
        let channels: Vec<_> = self
            .catalogs
            .borrow()
            .values()
            .chain(self.sides.borrow().values())
            .chain(self.main.channels.borrow().values())
            .chain(self.main.watches.borrow().values())
            .cloned()
            .collect();
        for channel in channels {
            let received = channel.borrow_mut().event(io, &event);
            messages.extend(
                received
                    .into_iter()
                    .map(|message| (channel.clone(), message)),
            );
        }
        for (channel, message) in messages {
            let process = channel.borrow().binding.process.clone();
            let replacing = self.reading.get(&(process.pid, process.start)).is_some_and(command::Reading::replaces);
            self.main.notice(&channel, message.root(), replacing);
            self.main.resumed(io, &channel, message.root(), self.updates.clone());
            let binding = channel.borrow().binding.clone();
            self.publish(io, ui, binding, message.root());
        }
        for update in std::mem::take(&mut *self.updates.borrow_mut()) {
            ui.update(update);
        }
        self.retire(io);
        let snapshots = std::mem::take(&mut *self.main.snapshots.borrow_mut());
        for (binding, snapshot) in snapshots {
            self.resumed(io, ui, binding, snapshot.root());
        }
    }
}

/// A chat of `binding` opens: its open questions, with those `recovered` from its recent page.
fn opened(
    io: &mut dyn Io,
    forms: &RefCell<BTreeMap<String, questions::Pending>>,
    updates: &RefCell<Vec<Update>>,
    binding: &Binding,
    recovered: questions::Pending,
) {
    let mut forms = forms.borrow_mut();
    let opened = forms
        .entry(binding.session.clone())
        .or_default()
        .adopt(recovered);
    if !opened.is_empty() {
        updates
            .borrow_mut()
            .extend(opened.into_iter().map(|interaction| Update::Interaction {
                binding: binding.clone(),
                interaction,
            }));
        let now = io.now();
        io.timer(now);
    }
}
