//! Main-thread approvals from the Codex PermissionRequest hook: the card of c1654cc
//! ChatCoordinator.swift:784-795 with the shared PendingApproval (ChatModels.swift:103-138), and
//! the PreCompact/PostCompact compacting status (:795-796).
use crate::{channel::failure, tools::printable};
use dispatch_helper_core::{
    api::*,
    json::{self, Data, Json, Value},
};
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet},
    path::Path,
    time::{Duration, Instant},
};

/// PendingApproval.expires (ChatModels.swift:123).
const EXPIRY: Duration = Duration::from_secs(45);

/// A process that may own a hook: the bound TUI, or the private server the harness spawned for
/// it (hooks run where the turn runs). The server is an unreaped child, so its pid is unique.
#[derive(Clone, Debug)]
pub struct Owner {
    pub pid: u32,
    pub start: Option<[u64; 2]>,
    pub binding: Binding,
}

/// The hook sender's ancestry walk towards exactly one owner.
struct Check {
    pid: u32,
    seen: BTreeSet<u32>,
    owners: Vec<Owner>,
    interaction: Interaction,
    reply: u64,
    until: Instant,
}

struct Pending {
    binding: Binding,
    interaction: Interaction,
    reply: u64,
    until: Instant,
}

#[derive(Default)]
pub struct Approvals {
    checks: BTreeMap<Work, Check>,
    pending: BTreeMap<String, Pending>,
}

/// No decision: Codex continues with its own approval UI (old empty reply).
fn fallback(io: &mut dyn Io, reply: u64) {
    let _ = io.reply(reply, crate::hooks::UNDECIDED);
}

/// The old card: `tool + "\n" + printable(tool_input)` as shell code; None resolves at once
/// (ChatCoordinator.swift:785).
fn card(root: Value<'_>, reply: u64) -> Option<Interaction> {
    let tool = root.get("tool_name")?.string()?;
    let operation = format!("{tool}\n{}", printable(root.get("tool_input")?));
    let options = ["Allow", "Deny", "Terminal"].map(|label| Choice {
        id: label.into(),
        label: label.into(),
        detail: None,
    });
    // c1654cc ChatCoordinator.swift:784-793: the hook's turn and, when it names one, its tool call.
    let text = |name| root.get(name).and_then(Value::string);
    Some(Interaction {
        key: Some(format!("{}:{}:{}", text("session_id").unwrap_or(""),
            text("turn_id").unwrap_or(""), text("tool_use_id").unwrap_or(&operation))),
        turn: text("turn_id").map(str::to_owned),
        record: text("tool_use_id").map(crate::tools::record),
        id: format!("hook-{reply}"),
        approval: true,
        blocking: true,
        questions: vec![Question {
            id: "approval".into(),
            header: tool.into(),
            blocks: vec![Block::Code {
                language: "shell".into(),
                text: operation.clone(),
            }],
            text: operation,
            secret: false,
            options: options.to_vec(),
            multiple: false,
            custom: false,
        }],
    })
}

impl Approvals {
    pub fn revoke(&mut self, io: &mut dyn Io, pid: u32) -> Vec<Update> {
        let checks: Vec<_> = self.checks.iter()
            .filter(|(_, check)| check.owners.iter().any(|owner| owner.binding.process.pid == pid))
            .map(|(work, _)| *work).collect();
        for work in checks {
            io.cancel(work);
            fallback(io, self.checks.remove(&work).unwrap().reply);
        }
        let ids: Vec<_> = self.pending.iter().filter(|(_, pending)| pending.binding.process.pid == pid)
            .map(|(id, _)| id.clone()).collect();
        ids.into_iter().map(|id| {
            let mut pending = self.pending.remove(&id).unwrap();
            fallback(io, pending.reply);
            pending.interaction.questions.clear();
            Update::Interaction { binding: pending.binding, interaction: pending.interaction }
        }).collect()
    }

    fn walk(&mut self, io: &mut dyn Io, check: Check) {
        let input = json::write(&Data::Object(vec![(
            "pid",
            Data::Unsigned(check.pid.into()),
        )]));
        let job = input.map(|input| Job::Native {
            name: "process",
            input,
        });
        match job.map(|job| io.submit(job)) {
            Ok(Ok(work)) => {
                self.checks.insert(work, check);
            }
            _ => fallback(io, check.reply),
        }
    }

    /// One ancestry step: the owner, the next parent, or None when the sender is unrelated.
    fn step(check: &mut Check, result: &Result<Output, std::io::Error>) -> Option<Option<Binding>> {
        let Ok(Output::Bytes(bytes)) = result else {
            return None;
        };
        let document = Json::parse(bytes).ok()?;
        let root = document.root();
        let pid = root.get("pid").and_then(Value::unsigned)?;
        if pid != u64::from(check.pid) || !check.seen.insert(check.pid) {
            return None;
        }
        let start: Vec<u64> = root
            .get("start")?
            .array()?
            .filter_map(Value::unsigned)
            .collect();
        if let Some(owner) = check.owners.iter().find(|owner| {
            owner.pid == check.pid && owner.start.is_none_or(|owned| owned[..] == start[..])
        }) {
            return Some(Some(owner.binding.clone()));
        }
        // Never pass a different Codex process to reach an older ancestor.
        let executable = root.get("executable").and_then(Value::string).unwrap_or("");
        if Path::new(executable)
            .file_name()
            .is_some_and(|name| name == "codex")
        {
            return None;
        }
        check.pid = root
            .get("parent")
            .and_then(Value::unsigned)
            .and_then(|parent| u32::try_from(parent).ok())
            .filter(|parent| *parent != 0)?;
        Some(None)
    }

    /// Closes a card for the UI; `empty` also answers its hook with no decision.
    fn retire(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, id: &str, empty: bool) {
        if let Some(pending) = self.pending.remove(id) {
            if empty {
                fallback(io, pending.reply);
            }
            let mut interaction = pending.interaction;
            interaction.questions.clear();
            ui.update(Update::Interaction {
                binding: pending.binding,
                interaction,
            });
        }
    }

    /// Hook, ancestry and expiry events; true when the event was an approval's own. `owners`
    /// lists the candidate owners of one native session.
    pub fn event(
        &mut self,
        io: &mut dyn Io,
        ui: &mut dyn Ui,
        event: &Event,
        owners: &dyn Fn(&str) -> Vec<Owner>,
        states: &RefCell<BTreeMap<String, State>>,
    ) -> bool {
        // Core C-COMPACT (c1654cc ChatCoordinator.swift:795-796): PreCompact/PostCompact set the
        // bound session's compacting status. They are lifecycle datagrams on the private 0600
        // route (no reply, no peer: core system/hooks.rs), so the session id selects the chat.
        if let Event::Hook { message, reply, .. } = event
            && let Ok(document) = Json::parse(message)
            && let root = document.root()
            && let Some(on) = match root.get("hook_event_name").and_then(Value::string) {
                Some("PreCompact") => Some(true),
                Some("PostCompact") => Some(false),
                _ => None,
            }
        {
            if let Some(reply) = reply {
                fallback(io, *reply);
            }
            let session = root.get("session_id").and_then(Value::string).unwrap_or("");
            if let Some(owner) = owners(session).into_iter().next() {
                let mut states = states.borrow_mut();
                let state = states.entry(owner.binding.session.clone()).or_default();
                state.compacting = on;
                let state = state.clone();
                ui.update(Update::State {
                    binding: owner.binding,
                    state,
                });
            }
            return true;
        }
        match event {
            Event::Hook {
                peer,
                message,
                reply: Some(reply),
                ..
            } => {
                let check = (|| {
                    let document = Json::parse(message).ok()?;
                    let root = document.root();
                    if root.get("hook_event_name")?.string()? != "PermissionRequest" {
                        return None;
                    }
                    let session = root.get("session_id")?.string()?;
                    let interaction = card(root, *reply)?;
                    // ChatCoordinator.swift:785: only a shown chat takes the decision.
                    let owners: Vec<Owner> = owners(session)
                        .into_iter()
                        .filter(|owner| {
                            ui.watching(&owner.binding) && ui.terminal(&owner.binding).is_some()
                        })
                        .collect();
                    Some(Check {
                        pid: (*peer)?,
                        seen: BTreeSet::new(),
                        owners: (!owners.is_empty()).then_some(owners)?,
                        interaction,
                        reply: *reply,
                        until: io.now() + EXPIRY,
                    })
                })();
                match check {
                    Some(check) => self.walk(io, check),
                    None => fallback(io, *reply),
                }
                true
            }
            Event::Done { work, result } if self.checks.contains_key(work) => {
                let mut check = self.checks.remove(work).unwrap();
                match Self::step(&mut check, result) {
                    Some(None) => self.walk(io, check),
                    Some(Some(binding)) if io.now() < check.until => {
                        ui.update(Update::Interaction {
                            binding: binding.clone(),
                            interaction: check.interaction.clone(),
                        });
                        io.timer(check.until);
                        self.pending.insert(
                            check.interaction.id.clone(),
                            Pending {
                                binding,
                                interaction: check.interaction,
                                reply: check.reply,
                                until: check.until,
                            },
                        );
                    }
                    _ => fallback(io, check.reply),
                }
                true
            }
            Event::Timer { at } => {
                let expired: Vec<String> = self
                    .pending
                    .iter()
                    .filter(|(_, pending)| {
                        pending.until <= *at
                            || !ui.watching(&pending.binding)
                            || ui.terminal(&pending.binding).is_none()
                    })
                    .map(|(id, _)| id.clone())
                    .collect();
                for id in expired {
                    self.retire(io, ui, &id, true);
                }
                false
            }
            // The sender is gone (HookReceiver.swift:138): its card retires without a reply.
            Event::Closed { reply } => {
                let works: Vec<Work> = self
                    .checks
                    .iter()
                    .filter(|(_, check)| check.reply == *reply)
                    .map(|(work, _)| *work)
                    .collect();
                for work in &works {
                    io.cancel(*work);
                    self.checks.remove(work);
                }
                let ids: Vec<String> = self
                    .pending
                    .iter()
                    .filter(|(_, pending)| pending.reply == *reply)
                    .map(|(id, _)| id.clone())
                    .collect();
                for id in &ids {
                    self.retire(io, ui, id, false);
                }
                !works.is_empty() || !ids.is_empty()
            }
            Event::Exit { pid, .. } => {
                for update in self.revoke(io, *pid) { ui.update(update); }
                false
            }
            _ => false,
        }
    }

    /// Allow (0), Deny (1) or Terminal (2); Terminal and Skip leave the decision to Codex.
    /// None when `id` is not a hook approval. PendingApproval.resolve (ChatModels.swift:126-138).
    pub fn answer(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        id: &str,
        answers: &[(String, Answer)],
    ) -> Option<(Result<Sent, Error>, Option<Update>)> {
        let pending = self.pending.get(id)?;
        let behavior = match answers {
            [(question, Answer::Options(choices))] if question == "approval" => match choices[..] {
                [0] => Ok(Some("allow")),
                [1] => Ok(Some("deny")),
                [2] => Ok(None),
                _ => Err(failure("question", "Choose Allow, Deny or Terminal.")),
            },
            [(question, Answer::Skip)] if question == "approval" => Ok(None),
            _ => Err(failure("question", "Choose Allow, Deny or Terminal.")),
        };
        let behavior = match behavior {
            Ok(_) if pending.binding != *binding || io.now() >= pending.until => {
                Err(failure("stale", "The approval expired."))
            }
            behavior => behavior,
        };
        let behavior = match behavior {
            Ok(behavior) => behavior,
            Err(error) => return Some((Err(error), None)),
        };
        let pending = self.pending.remove(id).unwrap();
        let bytes = match behavior {
            Some(behavior) => json::write(&Data::Object(vec![(
                "hookSpecificOutput",
                Data::Object(vec![
                    ("hookEventName", Data::String("PermissionRequest")),
                    (
                        "decision",
                        Data::Object(vec![("behavior", Data::String(behavior))]),
                    ),
                ]),
            )]))
            .unwrap_or_default(),
            None => b"{}".to_vec(),
        };
        let result = io
            .reply(pending.reply, &bytes)
            .map(|()| Sent::Native {
                written: true,
                may_have_sent: true,
                reason: None,
            })
            .map_err(crate::channel::os);
        let mut interaction = pending.interaction;
        interaction.questions.clear();
        let closed = Update::Interaction {
            binding: pending.binding,
            interaction,
        };
        Some((result, Some(closed)))
    }
}
