//! Live native hooks. System owns the stream; only a current observed chat can answer.
use crate::{
    history::{error, text},
    hooks::Request,
    identity::Probe,
};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json, Value},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    time::{Duration, Instant},
};

struct Pending {
    binding: Binding,
    request: Request,
    reply: u64,
    until: Instant,
    answering: bool,
}
enum Stage {
    Parents {
        pid: u32,
        seen: BTreeSet<u32>,
        bindings: Vec<Binding>,
    },
    Verify {
        probe: Probe,
        binding: Binding,
    },
}
enum Decision {
    Open(Request),
    Answer {
        id: String,
        bytes: Vec<u8>,
        done: Done<Sent>,
    },
}
struct Check {
    stage: Stage,
    decision: Decision,
    reply: u64,
    until: Instant,
}
#[derive(Default)]
pub(crate) struct Interactions {
    checks: BTreeMap<Work, Check>,
    pending: BTreeMap<String, Pending>,
    revoked: bool,
}

fn fallback(io: &mut dyn Io, reply: u64) {
    let _ = io.reply(reply, b"");
}
fn process(pid: u32) -> Result<Job, Error> {
    Ok(Job::Native {
        name: "process",
        input: json::write(&Data::Object(vec![("pid", Data::Unsigned(pid.into()))]))?,
    })
}
impl Check {
    fn job(&self) -> Result<Job, Error> {
        match &self.stage {
            Stage::Parents { pid, .. } => process(*pid),
            Stage::Verify { probe, .. } => probe.job(),
        }
    }
}
impl Interactions {
    /// Disabled hooks fall back to the native UI for new and still-unverified requests.
    /// Published interactions stay until the app answers or dismisses them (core decision G3).
    pub fn configure(&mut self, io: &mut dyn Io, enabled: bool) {
        self.revoked = !enabled;
        if enabled {
            return;
        }
        let opening = self
            .checks
            .iter()
            .filter_map(|(work, check)| {
                matches!(check.decision, Decision::Open(_)).then_some(*work)
            })
            .collect::<Vec<_>>();
        for work in opening {
            io.cancel(work);
            fallback(io, self.checks.remove(&work).unwrap().reply);
        }
    }
    /// Still-open approvals and questions of `binding`, for a chat that opens.
    pub fn cards(&self, binding: &Binding) -> Vec<Interaction> {
        self.pending
            .values()
            .filter(|p| p.binding == *binding)
            .map(|p| p.request.interaction.clone())
            .collect()
    }
    pub fn revoked(&self) -> bool {
        self.revoked
    }
    pub fn exit(&mut self, io: &mut dyn Io, pid: u32) {
        let ids = self
            .pending
            .iter()
            .filter_map(|(id, p)| (p.binding.process.pid == pid).then_some(id.clone()))
            .collect::<Vec<_>>();
        for id in ids {
            let pending = self.pending.remove(&id).unwrap();
            fallback(io, pending.reply);
        }
        let works = self
            .checks
            .iter()
            .filter_map(|(work, check)| {
                let owned = match &check.stage {
                    Stage::Parents { bindings, .. } => {
                        bindings.iter().any(|b| b.process.pid == pid)
                    }
                    Stage::Verify { binding, .. } => binding.process.pid == pid,
                };
                owned.then_some(*work)
            })
            .collect::<Vec<_>>();
        for work in works {
            io.cancel(work);
            let check = self.checks.remove(&work).unwrap();
            self.reject(io, check, error("exited", "Claude exited"));
        }
    }
    fn submit(&mut self, io: &mut dyn Io, check: Check, job: Result<Job, Error>) {
        match job.and_then(|job| io.submit(job).map_err(|e| error("io", e))) {
            Ok(work) => {
                self.checks.insert(work, check);
            }
            Err(issue) => self.reject(io, check, issue),
        }
    }
    fn reject(&mut self, io: &mut dyn Io, check: Check, issue: Error) {
        fallback(io, check.reply);
        if let Decision::Answer { id, done, .. } = check.decision {
            // Retire through the next event, where the UI is available.
            if let Some(pending) = self.pending.get_mut(&id) {
                pending.until = io.now();
                io.timer(pending.until);
            }
            deferred(done)(io, Err(issue));
        }
    }
    fn retire(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, id: &str, empty: bool) {
        if let Some(pending) = self.pending.remove(id) {
            if empty {
                fallback(io, pending.reply);
            }
            if ui.terminal(&pending.binding).is_some() {
                let mut interaction = pending.request.interaction;
                interaction.questions.clear();
                ui.update(Update::Interaction {
                    binding: pending.binding,
                    interaction,
                });
            }
        }
    }
    pub fn answer(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        id: &str,
        answers: Vec<(String, Answer)>,
        done: Done<Sent>,
        home: Option<PathBuf>,
        remote: bool,
    ) {
        let result = (|| {
            let pending = self
                .pending
                .get(id)
                .ok_or_else(|| error("expired", "Claude approval expired"))?;
            if pending.binding != *binding || pending.answering || io.now() >= pending.until {
                return Err(error("changed", "Claude approval changed"));
            }
            // Once hooks are disabled, the app's dismiss (Skip for every question) is the old
            // revocation: empty bytes hand the prompt back to Claude (c1654cc ChatModels.swift:136-140).
            // While enabled, Skip is the card's own skip reply.
            let revocation = self.revoked && answers.iter().all(|(_, a)| matches!(a, Answer::Skip));
            Ok((
                if revocation {
                    Vec::new()
                } else {
                    pending.request.answer(answers)?
                },
                pending.reply,
                pending.until,
            ))
        })();
        match result {
            Ok((bytes, reply, until)) => {
                self.pending.get_mut(id).unwrap().answering = true;
                let probe = Probe::new(
                    binding.process.clone(),
                    Some(binding.session.clone()),
                    home,
                    remote,
                );
                let check = Check {
                    stage: Stage::Verify {
                        probe,
                        binding: binding.clone(),
                    },
                    decision: Decision::Answer {
                        id: id.into(),
                        bytes,
                        done,
                    },
                    reply,
                    until,
                };
                let job = check.job();
                self.submit(io, check, job);
            }
            Err(issue) => deferred(done)(io, Err(issue)),
        }
    }
    pub fn event(
        &mut self,
        io: &mut dyn Io,
        ui: &mut dyn Ui,
        event: &Event,
        bindings: Vec<Binding>,
        home: Option<PathBuf>,
        remote: bool,
        turn: &dyn Fn(&Binding, &str) -> Option<String>,
    ) -> bool {
        match event {
            Event::Closed { reply } => {
                let works = self
                    .checks
                    .iter()
                    .filter_map(|(work, check)| (check.reply == *reply).then_some(*work))
                    .collect::<Vec<_>>();
                for work in works {
                    io.cancel(work);
                    let check = self.checks.remove(&work).unwrap();
                    if let Decision::Answer { done, .. } = check.decision {
                        deferred(done)(io, Err(error("expired", "Claude approval expired")));
                    }
                }
                let ids = self
                    .pending
                    .iter()
                    .filter_map(|(id, pending)| (pending.reply == *reply).then_some(id.clone()))
                    .collect::<Vec<_>>();
                for id in ids {
                    self.retire(io, ui, &id, false);
                }
                true
            }
            Event::Hook {
                peer,
                message,
                reply: Some(reply),
                ..
            } => {
                if self.revoked {
                    fallback(io, *reply);
                    return true;
                }
                let request = Json::parse(message).and_then(Request::new);
                let (Some(pid), Ok(request)) = (peer, request) else {
                    fallback(io, *reply);
                    return true;
                };
                let bindings = bindings
                    .into_iter()
                    .filter(|b| request.session.as_ref() == Some(&b.session))
                    .collect::<Vec<_>>();
                if bindings.is_empty() {
                    fallback(io, *reply);
                    return true;
                }
                let seconds = if request.interaction.approval {
                    45
                } else {
                    180
                };
                let until = io.now() + Duration::from_secs(seconds);
                if !request.interaction.approval && io.hold(*reply, until).is_err() {
                    fallback(io, *reply);
                    return true;
                }
                io.timer(until);
                let check = Check {
                    stage: Stage::Parents {
                        pid: *pid,
                        seen: BTreeSet::new(),
                        bindings,
                    },
                    decision: Decision::Open(request),
                    reply: *reply,
                    until,
                };
                let job = check.job();
                self.submit(io, check, job);
                true
            }
            Event::Done { work, result } if self.checks.contains_key(work) => {
                let mut check = self.checks.remove(work).unwrap();
                let step = (|| {
                    let output = match result {
                        Ok(Output::Bytes(bytes)) => Output::Bytes(bytes.clone()),
                        Ok(Output::Process(p)) => Output::Process(p.clone()),
                        Err(issue) => return Err(error("io", issue)),
                        _ => return Err(error("identity", "Missing Claude sender facts")),
                    };
                    if io.now() >= check.until {
                        return Err(error("expired", "Claude approval expired"));
                    }
                    match &mut check.stage {
                        Stage::Parents {
                            pid,
                            seen,
                            bindings,
                        } => {
                            let Output::Bytes(bytes) = output else {
                                return Err(error("identity", "Missing Claude sender"));
                            };
                            let doc = Json::parse(&bytes)?;
                            let root = doc.root();
                            if root.get("pid").and_then(Value::unsigned) != Some((*pid).into())
                                || !seen.insert(*pid)
                            {
                                return Err(error("identity", "Invalid Claude sender"));
                            }
                            if let Some(binding) = bindings.iter().find(|b| b.process.pid == *pid) {
                                let binding = binding.clone();
                                let probe = Probe::new(
                                    binding.process.clone(),
                                    Some(binding.session.clone()),
                                    home,
                                    remote,
                                );
                                let job = probe.job()?;
                                check.stage = Stage::Verify { probe, binding };
                                return Ok(Some(job));
                            }
                            // Never pass a different interactive Claude owner to reach an older ancestor.
                            if text(root, "executable").is_some_and(|s| {
                                PathBuf::from(s)
                                    .file_name()
                                    .is_some_and(|n| n == "claude" || n == "claude.exe")
                            }) {
                                return Err(error("changed", "Claude sender has another owner"));
                            }
                            *pid = root
                                .get("parent")
                                .and_then(Value::unsigned)
                                .and_then(|p| u32::try_from(p).ok())
                                .filter(|p| *p != 0)
                                .ok_or_else(|| error("identity", "Claude sender is unrelated"))?;
                            Ok(Some(process(*pid)?))
                        }
                        Stage::Verify { probe, binding } => {
                            let job = probe.complete(output)?;
                            if job.is_none()
                                && probe.session.as_ref().is_none_or(|s| s.binding != *binding)
                            {
                                return Err(error("changed", "Claude conversation changed"));
                            }
                            Ok(job)
                        }
                    }
                })();
                match step {
                    Ok(Some(job)) => self.submit(io, check, Ok(job)),
                    Err(issue) => self.reject(io, check, issue),
                    Ok(None) => {
                        let Stage::Verify { binding, .. } = &check.stage else {
                            unreachable!()
                        };
                        if !ui.watching(binding) || ui.terminal(binding).is_none() {
                            self.reject(io, check, error("changed", "Claude chat is closed"));
                            return true;
                        }
                        let binding = binding.clone();
                        match check.decision {
                            Decision::Open(mut request) => {
                                let id = request.interaction.id.clone();
                                request.interaction.turn = (request.interaction.record.as_deref())
                                    .and_then(|record| turn(&binding, record));
                                if self.pending.contains_key(&id) {
                                    fallback(io, check.reply);
                                    return true;
                                }
                                ui.update(Update::Interaction {
                                    binding: binding.clone(),
                                    interaction: request.interaction.clone(),
                                });
                                self.pending.insert(
                                    id,
                                    Pending {
                                        binding,
                                        request,
                                        reply: check.reply,
                                        until: check.until,
                                        answering: false,
                                    },
                                );
                            }
                            Decision::Answer { id, bytes, done } => {
                                let result = io
                                    .reply(check.reply, &bytes)
                                    .map(|()| Sent::Native {
                                        written: true,
                                        may_have_sent: true,
                                        reason: None,
                                    })
                                    .map_err(|e| error("io", e));
                                self.retire(io, ui, &id, false);
                                deferred(done)(io, result);
                            }
                        }
                    }
                }
                true
            }
            Event::Timer { at } => {
                let works = self
                    .checks
                    .iter()
                    .filter_map(|(work, c)| (c.until <= *at).then_some(*work))
                    .collect::<Vec<_>>();
                for work in works {
                    io.cancel(work);
                    let check = self.checks.remove(&work).unwrap();
                    self.reject(io, check, error("expired", "Claude approval expired"));
                }
                let ids = self
                    .pending
                    .iter()
                    .filter_map(|(id, p)| {
                        (p.until <= *at
                            || !ui.watching(&p.binding)
                            || ui.terminal(&p.binding).is_none())
                        .then_some(id.clone())
                    })
                    .collect::<Vec<_>>();
                for id in ids {
                    self.retire(io, ui, &id, true);
                }
                false
            }
            _ => false,
        }
    }
}
