use super::*;

pub(super) struct Waiting {
    terminal: Id,
    native: String,
    process: Process,
    kind: String,
    input: Input,
    done: Done<()>,
    deadline: Instant,
    retry: Instant,
    seen: u64,
}

pub(super) fn accepts(reply: Value<'_>, terminal: &str, kind: &str) -> Result<bool, Error> {
    let entries = field(reply, "agents")?
        .array()
        .ok_or_else(|| error("Invalid herdr agent list."))?;
    Ok(entries.into_iter().any(|entry| {
        entry.get("terminal_id").and_then(Value::string) == Some(terminal)
            && entry.get("agent").and_then(Value::string) == Some(kind)
            && entry.get("agent_status").and_then(Value::string) != Some("blocked")
            && entry.get("launch_pending").and_then(Value::boolean) != Some(true)
    }))
}

impl Herdr {
    pub(super) fn type_input(
        &mut self,
        io: &mut dyn Io,
        terminal: Id,
        process: &Process,
        inputs: &[Input],
        done: Done<()>,
    ) {
        let [Input::Paste(_)] = inputs else {
            self.type_checked(io, terminal, process, inputs, done);
            return;
        };
        let kind = self
            .harnesses
            .iter()
            .find(|harness| harness.borrow().matches(process))
            .map(|harness| harness.borrow().key().to_owned());
        let Some(kind) = kind else {
            self.defer(
                io,
                done,
                Err(expired("The agent no longer owns this terminal.")),
            );
            return;
        };
        if ["pi", "nanocodex"].contains(&kind.as_str()) {
            self.type_checked(io, terminal, process, inputs, done);
            return;
        }
        let native = self
            .snapshot
            .panes
            .iter()
            .find(|pane| self.graph.ids.get(&pane.terminal) == Some(&terminal))
            .map(|pane| pane.terminal.clone());
        let Some(native) = native else {
            self.defer(
                io,
                done,
                Err(expired("This herdr terminal is no longer available.")),
            );
            return;
        };
        if self.waiting.contains_key(&terminal) {
            self.defer(
                io,
                done,
                Err(error("Herdr input is already waiting for startup.")),
            );
            return;
        }
        let deadline = io.now() + Duration::from_secs(3);
        io.timer(deadline);
        let retry = io.now();
        self.readiness(
            io,
            Waiting {
                terminal,
                native,
                process: process.clone(),
                kind,
                input: inputs[0].clone(),
                done,
                deadline,
                retry,
                seen: self.changes,
            },
        );
    }
    fn readiness(&mut self, io: &mut dyn Io, mut pending: Waiting) {
        if io.now() >= pending.deadline {
            self.defer(
                io,
                pending.done,
                Err(error(
                    "Herdr agent is still starting or requires interactive input.",
                )),
            );
            return;
        }
        pending.seen = self.changes;
        self.job(
            io,
            Job::Process {
                pid: pending.process.pid,
            },
            Box::new(move |mux, io, result| {
                let valid = matches!(result, Ok(Output::Process(ref process))
                if crate::process::same(process, &pending.process));
                if !valid {
                    mux.defer(
                        io,
                        pending.done,
                        Err(expired("The agent no longer owns this terminal.")),
                    );
                    return;
                }
                let deadline = pending.deadline;
                mux.call(
                    io,
                    "agent.list",
                    D::Object(vec![]),
                    Order::First,
                    Box::new(move |mux, io, result| {
                        let result = result.and_then(|json| {
                            if io.now() >= pending.deadline {
                                return Err(error(
                                    "Herdr agent is still starting or requires interactive input.",
                                ));
                            }
                            accepts(json.root(), &pending.native, &pending.kind)
                        });
                        match result {
                            Ok(true) => mux.type_checked(
                                io,
                                pending.terminal,
                                &pending.process,
                                &[pending.input],
                                pending.done,
                            ),
                            Ok(false) => {
                                pending.retry = if pending.seen != mux.changes {
                                    io.now()
                                } else if !mux.modern || mux.fallback || mux.subscription.is_none()
                                {
                                    pending.deadline.min(io.now() + Duration::from_millis(100))
                                } else {
                                    pending.deadline
                                };
                                io.timer(pending.retry);
                                mux.waiting.insert(pending.terminal, pending);
                            }
                            Err(reason) => mux.defer(io, pending.done, Err(reason)),
                        }
                    }),
                );
                if let Some(call) = mux.calls.front_mut() {
                    if call.method == "agent.list" {
                        call.deadline = Some(deadline);
                    }
                }
            }),
        );
    }
    pub(super) fn ready(&mut self, io: &mut dyn Io, at: Instant, changed: bool) {
        let pending: Vec<_> = self
            .waiting
            .iter()
            .filter(|(_, pending)| changed || pending.retry <= at)
            .map(|(id, _)| *id)
            .collect();
        for id in pending {
            if let Some(pending) = self.waiting.remove(&id) {
                self.readiness(io, pending);
            }
        }
    }
}
