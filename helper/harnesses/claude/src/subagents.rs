//! Running subagents (`State.agents`): SubagentStart until SubagentStop, each with its task, its
//! tokens and when it started. Claude Code keeps a subagent's files beside its parent's transcript
//! (`<config>/projects/<project>/<session>.jsonl`): `<session>/subagents/agent-<id>.meta.json`,
//! whose "description" is the task the parent gave it, and `agent-<id>.jsonl`, its own records,
//! whose assistant records carry `message.usage` (one model call can span several records with one
//! `message.id`). Each running agent's transcript is watched and read on from where the last read
//! stopped; token changes reach watching chats at most once a second, the rest at once.
use super::*;
use dispatch_helper_core::{json::Json, rpc::Lines};
use std::time::{Duration, Instant};

/// Longest transcript line parsed; longer ones (Claude's request logs) are skipped whole.
const LINE: usize = 8 << 20;
/// One read of a transcript; a full one is followed by the next at once.
const CHUNK: u64 = 1 << 20;
/// How often token changes are published at most.
const PUBLISH: Duration = Duration::from_secs(1);
/// Longest task name kept, in characters.
const NAME: usize = 200;
/// Meta reads that found no name before the agent goes without one (a Claude that writes none).
const MISSES: u8 = 3;

pub(super) struct Subagent {
    id: String,
    kind: String,
    name: Option<String>,
    /// Meta reads that found no name; at MISSES the meta file is not asked for again.
    misses: u8,
    started_ms: Option<u64>,
    /// Tokens per model call (`message.id`): the most any of its records reported.
    calls: BTreeMap<String, u64>,
    /// The transcript was read at least once (its tokens are known, maybe none yet).
    read: bool,
    lines: Lines,
    /// (device, inode) of the transcript read so far: another file starts the count again.
    identity: Option<(u64, u64)>,
    watch: Option<u64>,
    /// A meta or transcript read is in flight; `again` when the file changed meanwhile.
    reading: bool,
    again: bool,
}

impl Subagent {
    fn new(id: &str, kind: &str) -> Self {
        Self {
            id: id.to_owned(),
            kind: kind.to_owned(),
            name: None,
            misses: 0,
            started_ms: None,
            calls: BTreeMap::new(),
            read: false,
            lines: Lines::recover(LINE),
            identity: None,
            watch: None,
            reading: false,
            again: false,
        }
    }
    pub(super) fn agent(&self) -> Agent {
        Agent {
            id: self.id.clone(),
            kind: self.kind.clone(),
            name: self.name.clone(),
            tokens: self.read.then(|| self.calls.values().sum()),
            started_ms: self.started_ms,
        }
    }
    /// Counts one transcript line: an assistant record's input, output and cache-creation tokens
    /// under its message id (cache reads re-count the same context on every call).
    fn count(&mut self, line: &[u8]) {
        if !line.windows(11).any(|w| w == b"\"assistant\"") {
            return;
        }
        let Ok(document) = Json::parse(line) else { return };
        let root = document.root();
        if text(root, "type") != Some("assistant") {
            return;
        }
        let Some(message) = root.get("message") else { return };
        let (Some(id), Some(usage)) = (text(message, "id"), message.get("usage")) else { return };
        let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
            .iter()
            .filter_map(|key| usage.get(key).and_then(|v| v.unsigned()))
            .fold(0u64, u64::saturating_add);
        let call = self.calls.entry(id.to_owned()).or_insert(0);
        *call = (*call).max(tokens);
    }
    fn tokens(&self) -> Option<u64> {
        self.agent().tokens
    }
}

/// The task in a meta file: its "description", trimmed and at most NAME characters.
fn name(bytes: &[u8]) -> Option<String> {
    let document = Json::parse(bytes).ok()?;
    let description = text(document.root(), "description")?.trim();
    (!description.is_empty()).then(|| description.chars().take(NAME).collect())
}

/// An agent id Claude could name a file with: nothing that leaves the subagents folder.
fn safe(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

enum Step {
    Clock,
    Meta,
    /// A transcript read from this offset.
    Transcript(u64),
}

#[derive(Default)]
pub(super) struct Subagents {
    /// Per session id, oldest first.
    running: BTreeMap<String, Vec<Subagent>>,
    work: BTreeMap<Work, (String, String, Step)>,
    watches: BTreeMap<u64, (String, String)>,
    /// Sessions whose token changes wait for the publish timer (`due`).
    pending: BTreeSet<String>,
    due: Option<Instant>,
}

impl Subagents {
    pub(super) fn agents(&self, session: &str) -> Vec<Agent> {
        self.running.get(session).map(|agents| agents.iter().map(Subagent::agent).collect()).unwrap_or_default()
    }
    fn agent(&mut self, session: &str, id: &str) -> Option<&mut Subagent> {
        self.running.get_mut(session)?.iter_mut().find(|a| a.id == id)
    }
}

impl Claude {
    /// SubagentStart/SubagentStop lifecycle datagrams (no reply) update the running agents; a new
    /// or ended session forgets its agents. True when the event was one of them.
    pub(super) fn subagent(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: &Event) -> bool {
        let Event::Hook { message, reply: None, .. } = event else {
            return false;
        };
        let Ok(document) = Json::parse(message) else {
            return false;
        };
        let root = document.root();
        let event = text(root, "hook_event_name").unwrap_or("");
        let Some(session) = text(root, "session_id").filter(|s| uuid(s)) else {
            return false;
        };
        let agent = text(root, "agent_id").unwrap_or("");
        let changed = match event {
            "SubagentStart" if !agent.is_empty() => {
                let agents = self.subagents.running.entry(session.to_owned()).or_default();
                let kind = text(root, "agent_type").filter(|s| !s.trim().is_empty()).unwrap_or("agent");
                !agents.iter().any(|a| a.id == agent) && {
                    agents.push(Subagent::new(agent, kind));
                    self.clock(io, session, agent);
                    self.follow(io, session, agent);
                    true
                }
            }
            "SubagentStop" => self.stop(io, session, Some(agent)),
            // Lifecycle events Claude also delivers for the parent session; only a session
            // boundary clears its agents.
            "SessionStart" | "SessionEnd" => self.stop(io, session, None),
            _ => return false,
        };
        if changed {
            self.publish(ui, session);
        }
        // SessionStart/SessionEnd are not ours alone: let other handlers see them.
        matches!(event, "SubagentStart" | "SubagentStop")
    }

    /// Ends `agent` (every agent of the session when None): its watch and reads stop. True when
    /// one was running.
    pub(super) fn stop(&mut self, io: &mut dyn Io, session: &str, agent: Option<&str>) -> bool {
        let Some(agents) = self.subagents.running.get_mut(session) else { return false };
        let (ended, kept): (Vec<_>, Vec<_>) = std::mem::take(agents).into_iter().partition(|a| agent.is_none_or(|id| a.id == id));
        *agents = kept;
        if agents.is_empty() {
            self.subagents.running.remove(session);
        }
        for agent in &ended {
            if let Some(watch) = agent.watch {
                io.unwatch(watch);
                self.subagents.watches.remove(&watch);
            }
        }
        let works = self
            .subagents
            .work
            .iter()
            .filter(|(_, (s, id, _))| s == session && ended.iter().any(|a| a.id == *id))
            .map(|(work, _)| *work)
            .collect::<Vec<_>>();
        for work in works {
            io.cancel(work);
            self.subagents.work.remove(&work);
        }
        !ended.is_empty()
    }

    /// Every agent of a session that just registered starts following its files.
    pub(super) fn follow_all(&mut self, io: &mut dyn Io, session: &str) {
        let ids = self.subagents.running.get(session).map(|a| a.iter().map(|a| a.id.clone()).collect::<Vec<_>>()).unwrap_or_default();
        for id in ids {
            self.follow(io, session, &id);
        }
    }

    /// The SubagentStart time: the host's wall clock, once.
    fn clock(&mut self, io: &mut dyn Io, session: &str, agent: &str) {
        let Ok(value) = dispatch_helper_core::wire::body::encode_plain(&Data::Object(Vec::new())) else { return };
        if let Ok(work) = io.submit(Job::Native { name: "clock", value }) {
            self.subagents.work.insert(work, (session.to_owned(), agent.to_owned(), Step::Clock));
        }
    }

    /// The folder holding a session's subagent files, from its verified transcript path.
    fn folder(&self, session: &str) -> Option<std::path::PathBuf> {
        self.sessions
            .values()
            .find(|s| s.binding.session == session)
            .and_then(|s| s.binding.transcript.as_ref())
            .map(|transcript| transcript.with_extension("").join("subagents"))
    }

    /// Watches the agent's transcript and reads it, once its session's folder is known.
    fn follow(&mut self, io: &mut dyn Io, session: &str, id: &str) {
        let Some(folder) = self.folder(session).filter(|_| safe(id)) else { return };
        let Some(agent) = self.subagents.agent(session, id).filter(|a| a.watch.is_none()) else { return };
        if let Ok(watch) = io.watch(&folder.join(format!("agent-{id}.jsonl")), false) {
            agent.watch = Some(watch);
            self.subagents.watches.insert(watch, (session.to_owned(), id.to_owned()));
        }
        self.read(io, session, id);
    }

    /// Reads on: the meta file while the agent has no name, then its transcript from where the
    /// last read stopped. One read at a time; a change meanwhile reads again after it.
    fn read(&mut self, io: &mut dyn Io, session: &str, id: &str) {
        let Some(folder) = self.folder(session) else { return };
        let Some(agent) = self.subagents.agent(session, id) else { return };
        if agent.reading {
            agent.again = true;
            return;
        }
        let (step, job) = if agent.name.is_none() && agent.misses < MISSES {
            (Step::Meta, Job::Read { path: folder.join(format!("agent-{id}.meta.json")), offset: 0, length: 65_536 })
        } else {
            let offset = agent.lines.position();
            (Step::Transcript(offset), Job::Read { path: folder.join(format!("agent-{id}.jsonl")), offset, length: CHUNK })
        };
        if let Ok(work) = io.submit(job) {
            agent.reading = true;
            self.subagents.work.insert(work, (session.to_owned(), id.to_owned(), step));
        }
    }

    fn transcript(&mut self, io: &mut dyn Io, session: &str, id: &str, offset: u64) {
        let Some(folder) = self.folder(session) else { return };
        let job = Job::Read { path: folder.join(format!("agent-{id}.jsonl")), offset, length: CHUNK };
        if let Ok(work) = io.submit(job) {
            self.subagents.work.insert(work, (session.to_owned(), id.to_owned(), Step::Transcript(offset)));
        } else if let Some(agent) = self.subagents.agent(session, id) {
            agent.reading = false;
        }
    }

    /// The agents' jobs, watches and publish timer; any other event comes back.
    pub(super) fn subagent_event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) -> Option<Event> {
        match event {
            Event::Done { work, result } if self.subagents.work.contains_key(&work) => {
                let (session, id, step) = self.subagents.work.remove(&work)?;
                self.loaded_agent(io, ui, &session, &id, step, result);
                None
            }
            Event::Changed { watch, .. } if self.subagents.watches.contains_key(&watch) => {
                let (session, id) = self.subagents.watches[&watch].clone();
                self.read(io, &session, &id);
                None
            }
            Event::Timer { at } => {
                if self.subagents.due.is_some_and(|due| due <= at) {
                    self.subagents.due = None;
                    for session in std::mem::take(&mut self.subagents.pending) {
                        self.publish(ui, &session);
                    }
                }
                Some(Event::Timer { at })
            }
            event => Some(event),
        }
    }

    fn loaded_agent(
        &mut self,
        io: &mut dyn Io,
        ui: &mut dyn Ui,
        session: &str,
        id: &str,
        step: Step,
        result: std::io::Result<Output>,
    ) {
        let Some(agent) = self.subagents.agent(session, id) else { return };
        match step {
            Step::Clock => {
                let ms = match result {
                    Ok(Output::Value(bytes)) => dispatch_helper_core::wire::body::decode_plain(&bytes)
                        .ok()
                        .and_then(|value| value.get("ms").and_then(Data::signed))
                        .and_then(|ms| u64::try_from(ms).ok()),
                    _ => None,
                };
                if ms.is_some() {
                    agent.started_ms = ms;
                    self.publish(ui, session);
                }
            }
            Step::Meta => {
                // Not written yet: the transcript's next change asks again.
                let named = match result {
                    Ok(Output::Read { bytes, .. }) => name(&bytes),
                    _ => None,
                };
                let changed = named.is_some();
                if named.is_none() {
                    agent.misses += 1;
                }
                agent.name = named;
                let offset = agent.lines.position();
                self.transcript(io, session, id, offset);
                if changed {
                    self.publish(ui, session);
                }
            }
            Step::Transcript(offset) => {
                let before = agent.tokens();
                let more = match result {
                    Ok(Output::Read { after, bytes, .. }) => {
                        let identity = (after.device, after.inode);
                        if agent.identity.is_some_and(|known| known != identity) || after.size < agent.lines.position() {
                            // Replaced or cut short: count the new file from its start.
                            agent.identity = None;
                            agent.calls.clear();
                            agent.lines.seek(0);
                            Some(0)
                        } else if offset != agent.lines.position() {
                            Some(agent.lines.position())
                        } else {
                            agent.identity = Some(identity);
                            agent.read = true;
                            let mut lines = std::mem::replace(&mut agent.lines, Lines::recover(LINE));
                            let _ = lines.feed(&bytes, |line| {
                                agent.count(line);
                                Ok(())
                            });
                            agent.lines = lines;
                            (bytes.len() as u64 >= CHUNK).then(|| agent.lines.position())
                        }
                    }
                    _ => None,
                };
                let changed = agent.tokens() != before;
                if let Some(offset) = more {
                    self.transcript(io, session, id, offset);
                } else {
                    agent.reading = false;
                    if std::mem::take(&mut agent.again) {
                        self.read(io, session, id);
                    }
                }
                if changed {
                    self.later(io, session);
                }
            }
        }
    }

    /// Publishes token changes with the next timer, at most once a second.
    fn later(&mut self, io: &mut dyn Io, session: &str) {
        self.subagents.pending.insert(session.to_owned());
        if self.subagents.due.is_none() {
            let at = io.now() + PUBLISH;
            io.timer(at);
            self.subagents.due = Some(at);
        }
    }

    /// The session's state to every chat with a terminal on it.
    fn publish(&mut self, ui: &mut dyn Ui, session: &str) {
        self.subagents.pending.remove(session);
        let bindings = self.sessions.values().map(|s| s.binding.clone()).filter(|b| b.session == session).collect::<Vec<_>>();
        for binding in bindings {
            if ui.terminal(&binding).is_some()
                && let Ok(state) = self.current(&binding)
            {
                ui.update(Update::State { binding, state });
            }
        }
    }
}

#[cfg(test)]
#[path = "subagents.test.rs"]
mod tests;
