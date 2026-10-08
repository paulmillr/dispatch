//! Follows a bound rollout like `tail -f`: c1654cc ChatCoordinator.refresh -> TranscriptReader.read
//! (TranscriptReader.swift:323-334) appended new complete lines, parsed in the current turn, to the
//! open chat. While a native channel streams the conversation, only the records it never sends
//! are taken from the rollout: kinds outside `live::KINDS` (reasoning summaries) and an
//! interaction's tool item (Codex sends no item for request_user_input, the old app read its card
//! and answer from the rollout).
use crate::{
    history,
    jobs::{Jobs, submit},
    live,
};
use dispatch_helper_core::api::*;
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet},
    rc::Rc,
};

struct Follow {
    binding: Binding,
    watch: u64,
    /// The followed revision; a replacement, truncation or same-size rewrite ends following.
    file: Metadata,
    offset: u64,
    turn: Option<String>,
    reading: bool,
    again: bool,
    /// The next read's length: CHUNK, doubled up to history::LINE while one line fills it.
    length: u64,
    /// A native channel streams this session: of `live::KINDS`, only wanted records are taken.
    limited: bool,
}

/// One read of appended lines; more is read right after a full chunk, a longer one when a single
/// line fills it (a rollout line longer than a read must not stall or spin the follow).
pub const CHUNK: u64 = 524_288;

/// The follows by session, and per session the `live::KINDS` record ids wanted from the rollout:
/// an interaction can ask for its record before the chat's history starts the follow (run 138b
/// slice 29241: the binding learned its rollout with the first turn).
#[derive(Clone, Default)]
pub struct Follows(
    Rc<RefCell<BTreeMap<String, Follow>>>,
    Rc<RefCell<BTreeMap<String, BTreeSet<String>>>>,
);

/// Where published records and state go: the harness's update queue and its session states.
#[derive(Clone)]
pub struct Sink {
    pub updates: Rc<RefCell<Vec<Update>>>,
    pub states: Rc<RefCell<BTreeMap<String, State>>>,
    pub forms: Rc<RefCell<BTreeMap<String, crate::questions::Pending>>>,
    /// Bindings whose follow ended on a replaced, shortened or unreadable rollout: read again.
    pub reloads: Rc<RefCell<Vec<Binding>>>,
}

impl Follows {
    pub(crate) fn turn(&self, binding: &Binding) -> Option<String> {
        self.0.borrow().values().find(|follow| {
            follow.binding.session == binding.session
                || (binding.session.is_empty()
                    && follow.binding.process.pid == binding.process.pid
                    && follow.binding.process.start == binding.process.start)
        }).and_then(|follow| follow.turn.clone())
    }

    /// Follow from the end of the recent page (its last complete line and turn).
    pub fn start(
        &self,
        io: &mut dyn Io,
        binding: &Binding,
        file: Metadata,
        at: (u64, Option<String>),
    ) {
        let Some(path) = &binding.transcript else {
            return;
        };
        if self.0.borrow().contains_key(&binding.session) {
            return;
        }
        let Ok(watch) = io.watch(path, false) else {
            return;
        };
        let (offset, turn) = at;
        let binding = binding.clone();
        let follow = Follow {
            binding,
            watch,
            file,
            offset,
            turn,
            reading: false,
            again: false,
            length: CHUNK,
            limited: false,
        };
        self.0
            .borrow_mut()
            .insert(follow.binding.session.clone(), follow);
    }

    /// Whether a native channel streams `session`: then follow only the records it never sends,
    /// else everything again.
    pub fn limit(&self, session: &str, limited: bool) {
        if let Some(follow) = self.0.borrow_mut().get_mut(session) {
            follow.limited = limited;
        }
    }

    /// The rollout's record `id` is wanted while the native channel streams `session`.
    pub fn want(&self, session: &str, id: &str) {
        let mut wants = self.1.borrow_mut();
        wants
            .entry(session.to_owned())
            .or_default()
            .insert(id.to_owned());
    }

    pub fn stop(&self, io: &mut dyn Io, session: &str) {
        self.1.borrow_mut().remove(session);
        if let Some(follow) = self.0.borrow_mut().remove(session) {
            io.unwatch(follow.watch);
        }
    }

    pub fn bindings(&self) -> Vec<Binding> {
        let follows = self.0.borrow();
        follows
            .values()
            .map(|follow| follow.binding.clone())
            .collect()
    }

    /// A followed rollout changed: read what was appended.
    pub fn event(&self, jobs: &Jobs, io: &mut dyn Io, event: &Event, sink: &Sink) {
        let Event::Changed { watch, .. } = event else {
            return;
        };
        let session = self
            .0
            .borrow()
            .values()
            .find(|follow| follow.watch == *watch)
            .map(|follow| follow.binding.session.clone());
        if let Some(session) = session {
            self.read(jobs, io, session, sink.clone());
        }
    }

    fn read(&self, jobs: &Jobs, io: &mut dyn Io, session: String, sink: Sink) {
        let job = {
            let mut follows = self.0.borrow_mut();
            let Some(follow) = follows.get_mut(&session) else {
                return;
            };
            if std::mem::replace(&mut follow.reading, true) {
                follow.again = true;
                return;
            }
            let path = follow.binding.transcript.clone().unwrap();
            Job::Read {
                path,
                offset: follow.offset,
                length: follow.length,
            }
        };
        let (follows, next) = (self.clone(), jobs.clone());
        submit(
            jobs,
            io,
            job,
            Box::new(move |io, result| {
                let more = follows.appended(io, &session, result, &sink);
                if more {
                    follows.read(&next, io, session, sink);
                }
            }),
        );
    }

    /// Publish the appended complete lines; whether to read again.
    fn appended(
        &self,
        io: &mut dyn Io,
        session: &str,
        result: Result<Output, Error>,
        sink: &Sink,
    ) -> bool {
        let mut follows = self.0.borrow_mut();
        let Some(follow) = follows.get_mut(session) else {
            return false;
        };
        follow.reading = false;
        let bytes = match result {
            Ok(Output::Read {
                before,
                after,
                bytes,
            }) if crate::paging::extends(&follow.file, &before)
                && crate::paging::extends(&before, &after)
                && before.size >= follow.offset =>
            {
                follow.file = after;
                bytes
            }
            _ => {
                // TranscriptReader.swift:296-299 starts over on a replaced or shortened file (its
                // next poll read the file again): the harness reads the recent page again.
                let follow = follows.remove(session).unwrap();
                io.unwatch(follow.watch);
                sink.reloads.borrow_mut().push(follow.binding);
                let now = io.now();
                io.timer(now);
                return false;
            }
        };
        let mut states = sink.states.borrow_mut();
        // The channel owns turn state; the TUI journals goal updates separately.
        let mut scratch = states.get(session).cloned().unwrap_or_default();
        let current = match follow.limited {
            true => &mut scratch,
            false => states.entry(session.to_owned()).or_default(),
        };
        let turn = follow.turn.take();
        let complete =
            match history::appended(&bytes, follow.offset, session, turn.clone(), current) {
                Ok((mut records, consumed, after, recovered)) => {
                    follow.turn = after;
                    let (binding, mut state) = (follow.binding.clone(), current.clone());
                    let changed = if follow.limited {
                        let live = states.entry(session.to_owned()).or_default();
                        let changed = live.goal != state.goal;
                        live.goal = state.goal.take();
                        state = live.clone();
                        changed
                    } else {
                        false
                    };
                    // Like the recent page (the old reader fed appended lines to the same
                    // question logic): prompts answer open async forms, then new ones open. A
                    // native channel owns them while it streams.
                    let mut opened = Vec::new();
                    if !follow.limited {
                        let mut forms = sink.forms.borrow_mut();
                        let pending = forms.entry(session.to_owned()).or_default();
                        for record in records
                            .iter()
                            .filter(|record| record.kind == RecordKind::User)
                        {
                            opened.extend(pending.answered(&record.text));
                        }
                        opened.extend(pending.merge(recovered));
                    }
                    if follow.limited {
                        let mut wants = self.1.borrow_mut();
                        let wanted = wants.entry(session.to_owned()).or_default();
                        records.retain(|record| {
                            !live::KINDS.contains(&record.kind) || wanted.contains(&record.id)
                        });
                        for record in records.iter().filter(|record| record.completed) {
                            wanted.remove(&record.id);
                        }
                    }
                    let mut updates = sink.updates.borrow_mut();
                    updates.extend(opened.into_iter().map(|interaction| Update::Interaction {
                        binding: binding.clone(),
                        interaction,
                    }));
                    if !records.is_empty() {
                        updates.push(Update::Records {
                            binding: binding.clone(),
                            records,
                        });
                    }
                    if !follow.limited || changed {
                        updates.push(Update::State { binding, state });
                    }
                    let now = io.now();
                    io.timer(now);
                    consumed
                }
                // Unreadable lines are skipped like before (the old reader moved past them).
                Err(_) => {
                    follow.turn = turn;
                    bytes
                        .iter()
                        .rposition(|byte| *byte == b'\n')
                        .map_or(0, |end| end + 1) as u64
                }
            };
        follow.offset += complete;
        // A full read without a complete line holds one longer line: read it whole.
        let full = bytes.len() as u64 == follow.length;
        follow.length = match full && complete == 0 {
            true => (follow.length * 2).min(history::LINE),
            false => CHUNK,
        };
        full || std::mem::take(&mut follow.again)
    }
}
