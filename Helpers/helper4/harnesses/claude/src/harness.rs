use crate::{
    history::{Parser, error, text, uuid},
    identity::{Consumer, Observation, Probe, Session},
    menu::{Startup, Walk, startup},
    paging::Reader,
};
use dispatch_helper4_core::api::*;
use dispatch_helper4_core::rpc::Grown;
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
    process::Command,
};

type Key = (u32, [u64; 2], String);
#[path = "archive.rs"]
mod archive;
#[path = "live.rs"]
mod live;
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
enum Source {
    Live(Key),
    File(std::path::PathBuf, String),
}
impl Source {
    fn session(&self) -> String {
        match self {
            Source::Live((_, _, session)) | Source::File(_, session) => session.clone(),
        }
    }
}
struct Cache {
    grown: Grown,
    offset: u64,
    parser: Parser,
    empty: bool,
    generation: String,
    earlier: Option<String>,
}
struct Read {
    binding: Option<Binding>,
    source: Source,
    path: std::path::PathBuf,
    reader: Reader,
    done: Done<Archive>,
    earlier: bool,
    checking: bool,
    selected: bool,
    notify: bool,
    /// An archive cursor whose parse context this read rebuilds (page ending at its offset).
    resume: Option<archive::Cursor>,
}

#[derive(Default)]
pub struct Claude {
    sides: std::rc::Rc<std::cell::RefCell<crate::side::Sides>>,
    walks: BTreeMap<Key, Walk>,
    cache: BTreeMap<Source, Cache>,
    reads: BTreeMap<Work, Read>,
    startup: BTreeMap<Key, Startup>,
    labels: BTreeMap<Key, BTreeMap<String, String>>,
    /// The last verified model choice (Goal::Select) with the model call it followed
    /// (`Parser.configured`); state reports it until the transcript has a newer model call.
    chosen: BTreeMap<Key, (Option<String>, String, Option<String>)>,
    probes: BTreeMap<Work, Observation>,
    /// Serial of the newest probe started per process (`Observation.serial`).
    newest: BTreeMap<u32, u64>,
    sessions: BTreeMap<Key, Session>,
    interactions: crate::interactions::Interactions,
    watches: BTreeMap<u64, (Binding, std::path::PathBuf)>,
    registrations: BTreeMap<u64, Binding>,
    live: BTreeSet<Key>,
    dirty: BTreeSet<Key>,
    installs: BTreeMap<Work, crate::install::Setup>,
    home: Option<std::path::PathBuf>,
    remote: bool,
    /// Native prompts waiting for the user: Some(guard deadline) until the old 3 s hook guard
    /// passes, then None (Terminal attention); `due` holds keys whose guard just passed.
    waits: BTreeMap<Key, Option<std::time::Instant>>,
    due: BTreeSet<Key>,
    /// Updates for the next event: a chat opening re-delivers its open interactions (history has no Ui).
    queued: Vec<Update>,
}

fn finish<T: 'static>(io: &mut dyn Io, done: Done<T>, result: Result<T, Error>) {
    deferred(done)(io, result)
}
fn unsupported<T: 'static>(io: &mut dyn Io, done: Done<T>) {
    finish(
        io,
        done,
        Err(error("unsupported", "Claude producer is not wired yet")),
    )
}
fn key(binding: &Binding) -> Key {
    (
        binding.process.pid,
        binding.process.start,
        binding.session.clone(),
    )
}

impl Claude {
    /// Claude has no captured native composer RPC; core owns the terminal fallback.
    pub fn command(&mut self, io: &mut dyn Io, _: &Binding, _: &str, done: Done<Outcome>) {
        finish(io, done, Err(error("unsupported", "Unsupported")));
    }
    pub fn invoke(
        &mut self,
        io: &mut dyn Io,
        cwd: &Path,
        arguments: &[String],
        done: Done<Command>,
    ) {
        let mut command = Command::new("claude");
        command.current_dir(cwd).args(arguments);
        finish(io, done, Ok(command));
    }

    fn installation(&mut self, io: &mut dyn Io, setup: crate::install::Setup, job: Job) {
        match io.submit(job) {
            Ok(work) => {
                self.installs.insert(work, setup);
            }
            Err(e) => finish(io, setup.done, Err(error("io", e))),
        }
    }
    pub fn new(home: std::path::PathBuf, remote: bool) -> Self {
        Self {
            home: Some(home),
            remote,
            ..Self::default()
        }
    }
    fn submit(&mut self, io: &mut dyn Io, request: Read, job: Job) {
        match io.submit(job) {
            Ok(work) => {
                self.reads.insert(work, request);
            }
            Err(e) => finish(io, request.done, Err(error("io", e))),
        }
    }
    fn page(
        &mut self,
        io: &mut dyn Io,
        source: Source,
        binding: Option<Binding>,
        transcript: &Transcript,
        done: Done<Archive>,
    ) {
        // Archive watch (core decisions-1002): a File read is a function of (file, later cursor);
        // the cache only speeds up the cursor it was left at.
        let mut resume = None;
        if matches!(source, Source::File(..)) && transcript.earlier.is_none() {
            match transcript.later.as_deref().filter(|c| !c.is_empty()) {
                None => {
                    self.cache.remove(&source);
                }
                Some(text) => match archive::Cursor::read(text) {
                    None => {
                        return finish(io, done, Err(error("changed", "Invalid Claude cursor")));
                    }
                    Some(cursor) => {
                        if !self.cache.get(&source).is_some_and(|c| cursor.continues(c)) {
                            self.cache.remove(&source);
                            resume = Some(cursor);
                        }
                    }
                },
            }
        }
        let result = (|| {
            if let Some(cursor) = &resume {
                return Ok(Reader::new(
                    transcript.path.clone(),
                    Parser::new(transcript.session.clone()),
                    Some(cursor.offset),
                ));
            }
            let cache = self.cache.get(&source);
            let before = transcript
                .earlier
                .as_deref()
                .map(|s| {
                    let (stamp, position) = s
                        .split_once(':')
                        .ok_or_else(|| error("changed", "Invalid Claude history cursor"))?;
                    let cache = cache.ok_or_else(|| error("changed", "Claude history changed"))?;
                    if stamp != cache.generation {
                        return Err(error("changed", "Claude history changed"));
                    }
                    position.parse().map_err(|e| error("changed", e))
                })
                .transpose()?;
            if before.is_none()
                && let Some(cache) = cache
            {
                return Ok(Reader::live(
                    transcript.path.clone(),
                    cache.parser.clone(),
                    cache.offset,
                ));
            }
            Ok(Reader::new(
                transcript.path.clone(),
                cache
                    .map(|c| c.parser.clone())
                    .unwrap_or_else(|| Parser::new(transcript.session.clone())),
                before,
            ))
        })();
        match result {
            Ok(reader) => {
                let job = reader.job();
                self.submit(
                    io,
                    Read {
                        source,
                        binding,
                        path: transcript.path.clone(),
                        reader,
                        done,
                        earlier: transcript.earlier.is_some(),
                        checking: false,
                        selected: false,
                        notify: false,
                        resume,
                    },
                    job,
                );
            }
            Err(e) => finish(io, done, Err(e)),
        }
    }
    fn control(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<Sent>) {
        self.walks.remove(&key(binding));
        let expected = binding.clone();
        self.identify(
            io,
            &binding.process,
            None,
            Box::new(move |io, result| {
                let result = match result {
                    Ok(Some(current)) if current == expected => {
                        Err(error("menu", "Use Claude's current prompt"))
                    }
                    Err(error) => Err(error),
                    _ => Err(error("changed", "Claude conversation changed")),
                };
                finish(io, done, result);
            }),
        );
    }
    fn watch(&mut self, io: &mut dyn Io, binding: &Binding, path: &Path) {
        if let Some(session) = self.sessions.get(&key(binding)).cloned() {
            self.registry(io, &session);
        }
        if self
            .watches
            .values()
            .any(|(b, p)| b == binding && p == path)
        {
            return;
        }
        let old = self
            .watches
            .iter()
            .filter_map(|(watch, (b, _))| (b == binding).then_some(*watch))
            .collect::<Vec<_>>();
        for watch in old {
            io.unwatch(watch);
            self.watches.remove(&watch);
        }
        for (index, candidate) in path.ancestors().enumerate() {
            if let Ok(watch) = io.watch(candidate, index != 0) {
                self.watches
                    .insert(watch, (binding.clone(), path.to_owned()));
                break;
            }
        }
    }
    fn refresh(&mut self, io: &mut dyn Io, binding: Binding, path: std::path::PathBuf) {
        let source = Source::Live(key(&binding));
        if let Some(read) = self
            .reads
            .values_mut()
            .find(|r| r.source == source && !r.selected)
        {
            read.notify = true;
            self.dirty.insert(key(&binding));
            return;
        }
        self.page(
            io,
            source.clone(),
            Some(binding.clone()),
            &Transcript {
                later: None,
                path,
                session: binding.session,
                earlier: None,
            },
            Box::new(|_, _| {}),
        );
        if let Some(read) = self.reads.values_mut().find(|r| r.source == source) {
            read.notify = true;
        }
    }
    fn pending(
        &mut self,
        io: &mut dyn Io,
        ui: &dyn Ui,
        binding: Option<Binding>,
        path: std::path::PathBuf,
    ) {
        if let Some(binding) = binding
            && self.dirty.remove(&key(&binding))
            && ui.watching(&binding)
        {
            self.refresh(io, binding, path);
        }
    }
    fn release(&mut self, io: &mut dyn Io, pid: u32) {
        self.interactions.exit(io, pid);
        self.walks.retain(|(owner, _, _), _| *owner != pid);
        self.cache
            .retain(|source, _| !matches!(source, Source::Live((owner, _, _)) if *owner == pid));
        self.startup.retain(|(owner, _, _), _| *owner != pid);
        self.labels.retain(|(owner, _, _), _| *owner != pid);
        self.chosen.retain(|(owner, _, _), _| *owner != pid);
        self.sessions.retain(|(owner, _, _), _| *owner != pid);
        self.newest.remove(&pid);
        self.live.retain(|(owner, _, _)| *owner != pid);
        self.dirty.retain(|(owner, _, _)| *owner != pid);
        self.waits.retain(|(owner, _, _), _| *owner != pid);
        self.due.retain(|(owner, _, _)| *owner != pid);
        let watches = self
            .watches
            .iter()
            .filter_map(|(watch, (binding, _))| (binding.process.pid == pid).then_some(*watch))
            .collect::<Vec<_>>();
        for watch in watches {
            io.unwatch(watch);
            self.watches.remove(&watch);
        }
        let registrations = self
            .registrations
            .iter()
            .filter_map(|(watch, binding)| (binding.process.pid == pid).then_some(*watch))
            .collect::<Vec<_>>();
        for watch in registrations {
            io.unwatch(watch);
            self.registrations.remove(&watch);
        }
        let probes = self
            .probes
            .iter()
            .filter_map(|(work, observation)| {
                (observation.probe.process.pid == pid).then_some(*work)
            })
            .collect::<Vec<_>>();
        for work in probes {
            io.cancel(work);
            self.probes.remove(&work).unwrap().consumer.complete(
                io,
                None,
                Err(error("exited", "Claude exited")),
            );
        }
        let reads = self
            .reads
            .iter()
            .filter_map(|(work, r)| {
                r.binding
                    .as_ref()
                    .is_some_and(|b| b.process.pid == pid)
                    .then_some(*work)
            })
            .collect::<Vec<_>>();
        for work in reads {
            io.cancel(work);
            finish(
                io,
                self.reads.remove(&work).unwrap().done,
                Err(error("exited", "Claude exited")),
            );
        }
    }
    fn stalled(&mut self, io: &mut dyn Io, ui: &dyn Ui, request: Read, missing: bool) {
        if missing && matches!(request.source, Source::File(..)) {
            self.cache.remove(&request.source);
        }
        let cache = self.cache.get(&request.source);
        let archive = Archive {
            page: Page {
                records: Vec::new(),
                earlier: cache.and_then(|c| c.earlier.clone()),
            },
            state: cache.map(|c| c.parser.state.clone()).unwrap_or_default(),
            snapshot: Snapshot {
                later: String::new(),
                session: cache.and_then(|c| c.parser.observed.clone()),
                version: cache.and_then(|c| c.parser.version.clone()),
                generation: cache.map(|c| c.generation.clone()).unwrap_or_default(),
                initial: false,
                caught_up: missing,
                invalidated: !missing,
                awaiting_creation: missing && cache.is_none(),
                file: cache.filter(|_| !missing).map(|c| FileIdentity {
                    device: c.grown.metadata.device,
                    inode: c.grown.metadata.inode,
                }),
            },
        };
        if let Some(binding) = &request.binding
            && ui.watching(binding)
            && ui.terminal(binding).is_some()
        {
            self.watch(io, binding, &request.path);
        }
        finish(io, request.done, Ok(archive));
        self.pending(io, ui, request.binding, request.path);
    }
}

impl Harness for Claude {
    fn name(&self) -> &str {
        "Claude Code"
    }
    fn key(&self) -> &str {
        "claude"
    }
    fn matches(&self, process: &Process) -> bool {
        crate::process::matches(process)
    }
    fn command(&mut self, io: &mut dyn Io, _: &Binding, _: &str, done: Done<Outcome>) {
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        );
    }
    fn launch(&mut self, io: &mut dyn Io, cwd: &Path, arguments: &[String], done: Done<Command>) {
        self.invoke(io, cwd, arguments, done);
    }
    fn exited(&mut self, io: &mut dyn Io, process: &Process, _: Option<i32>) {
        self.release(io, process.pid);
    }
    fn identify(
        &mut self,
        io: &mut dyn Io,
        process: &Process,
        hook: Option<&Hook>,
        done: Done<Option<Binding>>,
    ) {
        if !self.matches(process) {
            finish(io, done, Ok(None));
            return;
        }
        let probe = Probe::new(
            process.clone(),
            hook.and_then(|h| h.session.clone()),
            self.home.clone(),
            self.remote,
        );
        self.start(io, probe, Consumer::Binding(done));
    }
    fn hook(&mut self, message: &Json) -> Result<Hook, Error> {
        let root = message.root();
        let event = text(root, "hook_event_name")
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| error("hook", "Missing Claude hook event"))?
            .to_owned();
        let session = text(root, "session_id").map(str::to_owned);
        if session.as_ref().is_some_and(|s| !uuid(s)) {
            return Err(error("hook", "Invalid Claude session"));
        }
        Ok(Hook {
            fallback: Vec::new(),
            interactive: event == "PermissionRequest"
                || (event == "PreToolUse" && text(root, "tool_name") == Some("AskUserQuestion")),
            event,
            session,
            cwd: text(root, "cwd").map(Into::into),
            pid: None,
            payload: Json::parse(&root.write()?)?,
        })
    }
    fn history(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        earlier: Option<&str>,
        done: Done<Page>,
    ) {
        // Core contract: an opening chat gets every still-open interaction again (same id).
        if earlier.is_none() {
            let cards = [
                self.interactions.cards(binding),
                self.sides.borrow().cards(binding),
            ]
            .concat();
            if !cards.is_empty() {
                self.queued
                    .extend(cards.into_iter().map(|interaction| Update::Interaction {
                        binding: binding.clone(),
                        interaction,
                    }));
                io.timer(io.now());
            }
        }
        if self.sides.borrow().contains(binding) {
            finish(io, done, Ok(self.sides.borrow().page(binding)));
            return;
        }
        let Some(path) = binding.transcript.clone() else {
            finish(
                io,
                done,
                Err(error("transcript", "Claude has no transcript path")),
            );
            return;
        };
        self.watch(io, binding, &path);
        // A chat opening gets the recent page, like an archive read without a cursor; the live
        // cache only continues watch refreshes (it would hand a second opening just the appends).
        if earlier.is_none() {
            self.cache.remove(&Source::Live(key(binding)));
        }
        self.page(
            io,
            Source::Live(key(binding)),
            Some(binding.clone()),
            &Transcript {
                later: None,
                path,
                session: binding.session.clone(),
                earlier: earlier.map(str::to_owned),
            },
            Box::new(move |io, result| finish(io, done, result.map(|archive| archive.page))),
        );
    }
    fn read(&mut self, io: &mut dyn Io, source: &Transcript, done: Done<Archive>) {
        self.page(
            io,
            Source::File(source.path.clone(), source.session.clone()),
            None,
            source,
            done,
        );
    }
    fn state(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<State>) {
        if self.sides.borrow().contains(binding) {
            finish(io, done, Ok(self.sides.borrow().state(binding)));
            return;
        }
        if self.live.contains(&key(binding)) {
            self.observe(io, binding, Some(done));
        } else {
            finish(io, done, self.current(binding));
        }
    }
    fn commands(&self, _: &Binding) -> Vec<String> {
        [
            "/btw",
            "/side",
            "/terminal",
            "/model",
            "/effort",
            "/init",
            "/clear",
            "/compact",
            "/resume",
            "/help",
            "/exit",
            "/quit",
        ]
        .map(str::to_owned)
        .to_vec()
    }
    fn send(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        text: &str,
        _: Mode,
        _: bool,
        done: Done<Sent>,
    ) {
        if self.sides.borrow().contains(binding) {
            self.sides.borrow_mut().send(io, binding, text, done);
            return;
        }
        self.control(io, binding, done)
    }
    fn stop(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<Sent>) {
        self.control(io, binding, done)
    }
    fn models(&mut self, io: &mut dyn Io, _: &Binding, done: Done<Menu>) {
        finish(io, done, Err(error("menu", "Read Claude's model menu")))
    }
    fn efforts(&mut self, io: &mut dyn Io, _: &Binding, _: &str, done: Done<Menu>) {
        finish(io, done, Err(error("menu", "Read Claude's effort menu")))
    }
    fn select(&mut self, io: &mut dyn Io, _: &Binding, _: &str, _: Option<&str>, done: Done<Sent>) {
        finish(io, done, Err(error("menu", "Use Claude's model menu")))
    }
    fn menu(&mut self, _io: &mut dyn Io, binding: &Binding, goal: &Goal, screen: &Screen, settled: bool) -> Step {
        if matches!(goal, Goal::Models)
            && let Some(view) = crate::menu::read(&screen.text)
            && let Some(current) = view.choices.iter().find(|row| row.current)
            && let Some(model) = self.current(binding).ok().and_then(|state| state.model)
        {
            self.labels
                .entry(key(binding))
                .or_default()
                .insert(model, current.name.clone());
        }
        if let Some(startup) = startup(&screen.text) {
            self.startup.insert(key(binding), startup);
        }
        let key = key(binding);
        let session = self.sessions.get(&key);
        let status = session.map_or("unknown", |session| session.status.as_str());
        let name = session.and_then(|session| session.name.clone());
        let walk = self.walks.entry(key.clone()).or_default();
        walk.settled = Some(settled);
        let step = walk.next(&binding.session, status, name.as_deref(), goal, screen);
        if let (Step::Done(menu), Goal::Select { model, effort }) = (&step, goal)
            && !walk.cancelled
        {
            let after = self
                .cache
                .get(&Source::Live(key.clone()))
                .and_then(|c| c.parser.configured.clone());
            self.chosen.insert(
                key,
                (after, menu.current.clone().unwrap_or_else(|| model.clone()), effort.clone()),
            );
        }
        step
    }
    /// Let the existing hook-arrival guard resolve authority before offering native fallback.
    fn prompt(&mut self, binding: &Binding, screen: &Screen) -> Option<Interaction> {
        if !self.interactions.cards(binding).is_empty()
            || !self.interactions.revoked() && self.waits.get(&key(binding)) != Some(&None)
        {
            return None;
        }
        crate::menu::prompt(screen)
    }
    /// A fresh session's model is on screen before any transcript has one; `menu` reads the
    /// same banner during a walk.
    fn screen_state(&mut self, binding: &Binding, screen: &Screen) -> Option<State> {
        let startup = startup(&screen.text)?;
        let key = key(binding);
        if self.startup.get(&key) == Some(&startup) {
            return None;
        }
        let before = self.current(binding).ok();
        self.startup.insert(key, startup);
        self.current(binding).ok().filter(|state| before.as_ref() != Some(state))
    }
    fn answer(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        interaction: &str,
        answers: Vec<(String, Answer)>,
        done: Done<Sent>,
    ) {
        if self.sides.borrow().contains(binding) {
            self.sides
                .borrow_mut()
                .answer(io, binding, interaction, answers, done);
            return;
        }
        if interaction != format!("menu:{}", binding.session) {
            self.interactions.answer(
                io,
                binding,
                interaction,
                answers,
                done,
                self.home.clone(),
                self.remote,
            );
            return;
        }
        let result = self
            .walks
            .get_mut(&key(binding))
            .ok_or_else(|| error("expired", "Claude's confirmation expired"))
            .and_then(|walk| walk.answer(answers));
        finish(io, done, result)
    }
    fn tool(&mut self, io: &mut dyn Io, binding: &Binding, id: &str, done: Done<Record>) {
        let Some(path) = binding.transcript.clone() else {
            finish(
                io,
                done,
                Err(error("transcript", "Claude has no transcript path")),
            );
            return;
        };
        let selected = id.to_owned();
        let reader = Reader::selected(
            path.clone(),
            Parser::new(binding.session.clone()),
            selected.clone(),
        );
        let job = reader.job();
        self.submit(
            io,
            Read {
                binding: Some(binding.clone()),
                source: Source::Live(key(binding)),
                path,
                reader,
                earlier: false,
                checking: false,
                selected: true,
                notify: false,
                resume: None,
                done: Box::new(move |io, result| {
                    let result = result.and_then(|archive| {
                        let mut rows = archive
                            .page
                            .records
                            .into_iter()
                            .filter(|row| row.id == selected);
                        let mut record = rows
                            .next()
                            .ok_or_else(|| error("missing", "Claude tool is unavailable"))?;
                        for update in rows {
                            if !update.output.is_empty() {
                                record.output = update.output;
                            }
                            record.completed |= update.completed;
                            record.exit_code = update.exit_code.or(record.exit_code);
                            record.time_ms = update.time_ms.or(record.time_ms);
                        }
                        Ok(record)
                    });
                    finish(io, done, result);
                }),
            },
            job,
        );
    }
    fn queue(&mut self, io: &mut dyn Io, _: &Binding, done: Done<Vec<Queued>>) {
        finish(io, done, Ok(Vec::new()))
    }
    fn queue_add(&mut self, io: &mut dyn Io, _: &Binding, _: &str, _: Mode, done: Done<Queued>) {
        unsupported(io, done)
    }
    fn queue_edit(
        &mut self,
        io: &mut dyn Io,
        _: &Binding,
        _: &str,
        _: u64,
        _: Option<&str>,
        done: Done<()>,
    ) {
        unsupported(io, done)
    }
    fn queue_send(
        &mut self,
        io: &mut dyn Io,
        _: &Binding,
        _: &str,
        _: u64,
        _: Mode,
        done: Done<Sent>,
    ) {
        unsupported(io, done)
    }
    fn queue_order(&mut self, io: &mut dyn Io, _: &Binding, _: &[String], done: Done<()>) {
        unsupported(io, done)
    }
    fn side(
        &mut self,
        io: &mut dyn Io,
        parent: &Binding,
        question: &str,
        read_only: bool,
        done: Done<Binding>,
    ) {
        let question = question.trim();
        if question.is_empty() || question.len() > 1_048_576 {
            finish(io, done, Err(error("limit", "Invalid side question")));
            return;
        }
        let Some(session) = self.sessions.get(&key(parent)) else {
            finish(
                io,
                done,
                Err(error("changed", "Claude conversation changed")),
            );
            return;
        };
        let directory = session.directory.clone();
        let (parent, question, sides) = (parent.clone(), question.to_owned(), self.sides.clone());
        // A fresh verified observation supplies the parent's current model; c1654cc
        // ChatSideConversation.swift:37-45 starts the fork on the parent's model.
        self.observe(
            io,
            &parent.clone(),
            Some(Box::new(move |io, result| match result {
                Ok(state) => sides.borrow_mut().open(
                    io,
                    crate::side::Launch {
                        parent,
                        directory,
                        question,
                        model: state.model,
                        read_only,
                        done,
                    },
                ),
                Err(e) => finish(io, done, Err(e)),
            })),
        );
    }
    fn side_close(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<()>) {
        if self.sides.borrow().contains(binding) {
            self.sides
                .borrow_mut()
                .close(io, binding.process.pid, "Side closed".into());
            finish(io, done, Ok(()));
        } else {
            finish(io, done, Err(error("changed", "Side conversation changed")));
        }
    }
    fn revoke(&mut self, io: &mut dyn Io, binding: &Binding, _: bool, done: Done<()>) {
        for mut interaction in self.interactions.cards(binding) {
            interaction.questions.clear();
            self.queued.push(Update::Interaction { binding: binding.clone(), interaction });
        }
        self.interactions.exit(io, binding.process.pid);
        let now = io.now();
        io.timer(now);
        finish(io, done, Ok(()));
    }

    fn install(
        &mut self,
        io: &mut dyn Io,
        _: &Path,
        enabled: Option<bool>,
        binding: Option<&Binding>,
        done: Done<Install>,
    ) {
        if enabled == Some(false) {
            self.interactions.configure(io, false);
        }
        let executable = match io.executable() {
            Ok(path) => path,
            Err(e) => return finish(io, done, Err(error("io", e))),
        };
        let Some(executable) = executable.to_str() else {
            return finish(
                io,
                done,
                Err(error("settings", "Helper executable path is not UTF-8")),
            );
        };
        let command = format!("'{}' hook claude", executable.replace('\'', "'\\''"));
        let setup =
            crate::install::Setup::new(self.home.clone(), enabled, self.remote, command, done);
        let job = Job::Process { pid: binding.map_or_else(|| io.pid(), |binding| binding.process.pid) };
        self.installation(io, setup, job);
    }
    fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) {
        for update in std::mem::take(&mut self.queued) {
            ui.update(update);
        }
        let Some(event) = self.sides.borrow_mut().event(io, ui, event) else {
            return;
        };
        let cache = &self.cache;
        if self.interactions.event(
            io,
            ui,
            &event,
            self.sessions.values().map(|s| s.binding.clone()).collect(),
            self.home.clone(),
            self.remote,
            &|binding, record| {
                cache
                    .get(&Source::Live(key(binding)))
                    .and_then(|c| c.parser.turn_of(record))
            },
        ) {
            for binding in self.sessions.values().map(|s| s.binding.clone()).collect::<Vec<_>>() {
                self.wait(io, &binding);
            }
            return;
        }
        if let Event::Changed { watch, .. } = &event
            && let Some(binding) = self.registrations.get(watch).cloned()
        {
            if ui.watching(&binding) && ui.terminal(&binding).is_some() {
                self.observe(io, &binding, None);
            } else {
                io.unwatch(*watch);
                self.registrations.remove(watch);
            }
            return;
        }
        if let Event::Changed { watch, .. } = event
            && let Some((binding, path)) = self.watches.get(&watch).cloned()
        {
            if ui.watching(&binding) && ui.terminal(&binding).is_some() {
                self.refresh(io, binding, path);
            } else {
                io.unwatch(watch);
                self.watches.remove(&watch);
            }
            return;
        }
        if let Event::Timer { at } = event {
            self.guard(io, at);
            return;
        }
        if let Event::Done { work, result } = event {
            if let Some(mut setup) = self.installs.remove(&work) {
                match setup.complete(result) {
                    Ok(crate::install::Next::Job(job)) => self.installation(io, setup, job),
                    Ok(crate::install::Next::Done(report)) => {
                        if setup.enabled == Some(true) {
                            self.interactions.configure(io, true);
                        }
                        finish(io, setup.done, Ok(report));
                    }
                    Err(error) => finish(io, setup.done, Err(error)),
                }
                return;
            }
            if let Some(mut observation) = self.probes.remove(&work) {
                match result
                    .map_err(|e| error("io", e))
                    .and_then(|output| observation.probe.complete(output))
                {
                    Ok(Some(job)) => self.probe(io, observation, job),
                    result => {
                        let probe = observation.probe;
                        // Probes finish out of order on the System workers; only the newest
                        // started one read the registration last, so only it updates the
                        // shared state. An older one still answers its own consumer.
                        let newest =
                            self.newest.get(&probe.process.pid) == Some(&observation.serial);
                        let previous = probe
                            .session
                            .as_ref()
                            .and_then(|session| self.current(&session.binding).ok());
                        if newest {
                            self.sessions
                                .retain(|(pid, _, _), _| *pid != probe.process.pid);
                        }
                        let binding = if result.is_ok() {
                            probe.session.map(|session| {
                                let binding = session.binding.clone();
                                if newest {
                                    self.registry(io, &session);
                                    self.live.insert(key(&binding));
                                    self.sessions.insert(key(&binding), session);
                                    self.wait(io, &binding);
                                }
                                binding
                            })
                        } else {
                            None
                        };
                        if newest
                            && let Some(binding) = &binding
                            && ui.terminal(binding).is_some()
                            && let Ok(state) = self.current(binding)
                            && previous.as_ref() != Some(&state)
                        {
                            ui.update(Update::State {
                                binding: binding.clone(),
                                state,
                            });
                        }
                        let state = binding
                            .as_ref()
                            .map(|binding| self.current(binding))
                            .unwrap_or_else(|| {
                                Err(error("changed", "Claude conversation changed"))
                            });
                        observation.consumer.complete(io, binding, state);
                    }
                }
                return;
            }
            if let Some(request) = self.reads.remove(&work) {
                self.loaded(io, ui, request, result);
            }
        }
    }
}
