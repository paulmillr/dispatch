use super::*;

impl Native {
    pub(super) fn complete(
        &mut self,
        io: &mut dyn Io,
        pending: Pending,
        result: io::Result<Output>,
    ) {
        match pending {
            Pending::Directory { terminal, shell } => {
                if let Ok(Output::Bytes(bytes)) = result
                    && let Ok(document) = Json::parse(&bytes)
                    && let Ok(current) = crate::process::process(document.root())
                    && same(&shell, &current)
                    && self.observe(terminal, &current)
                    && let Some(cwd) = document.root().get("cwd").and_then(Value::string)
                    && let Ok(t) = self.terminal(terminal)
                {
                    let cwd = PathBuf::from(cwd);
                    if t.node.cwd.as_ref() != Some(&cwd) {
                        t.node.cwd = Some(cwd);
                        self.changed(io);
                    }
                }
                self.discovered(io, terminal, None, Ok(Output::Process(shell)), true);
            }
            Pending::Member {
                terminal,
                shell,
                process,
                remaining,
                members,
            } => {
                match result {
                    Ok(Output::Process(current))
                        if owns(&process, &current)
                            && current.tty == shell.tty
                            && current.group == shell.foreground
                            && current.foreground == shell.foreground =>
                    {
                        members.borrow_mut().push(current)
                    }
                    _ => {
                        if let Ok(t) = self.terminal(terminal) {
                            t.group = None;
                        }
                    }
                }
                remaining.set(remaining.get() - 1);
                if remaining.get() == 0 {
                    let members = std::mem::take(&mut *members.borrow_mut());
                    if !self.identify(io, terminal, shell, members) {
                        if let Ok(t) = self.terminal(terminal) {
                            t.discovering = false;
                        }
                    }
                }
            }
            Pending::Client { terminal, process } => {
                if let Ok(Output::Process(shell)) = result
                    && self.observe(terminal, &shell)
                    && process.tty == shell.tty
                    && process.group == shell.foreground
                    && process.foreground == shell.foreground
                    && let Ok(t) = self.terminal(terminal)
                    && t.client.as_ref() != Some(&process)
                {
                    t.client = Some(process.clone());
                    self.clients.push((terminal, process));
                }
            }
            Pending::Control {
                terminal,
                step,
                done,
            } => self.controlled(io, terminal, step, done, result),
            Pending::Alive {
                terminal,
                process,
                reply,
            } => {
                let ended = match result {
                    Ok(Output::Process(current)) => !same(&process, &current),
                    Err(error) => {
                        error.kind() == io::ErrorKind::NotFound
                            && self
                                .terminal(terminal)
                                .is_ok_and(|t| t.child.pid != process.pid)
                    }
                    _ => false,
                };
                if ended
                    && let Ok(t) = self.terminal(terminal)
                    && t.node
                        .agent
                        .as_ref()
                        .is_some_and(|(_, b)| same(&process, &b.process))
                {
                    t.node.agent = None;
                    self.agents.push(terminal);
                    self.changed(io);
                }
                if let Some((done, failure)) = reply {
                    // Foreground refusal is not proof of death. Publish only the
                    // independent identity observation before returning that refusal.
                    self.finish(io, done, Err(failure));
                }
            }
            Pending::Close(check) => self.closing(io, check, result),
            Pending::Discover { terminal, shell } => {
                self.discovered(io, terminal, shell, result, false)
            }
            Pending::Child(id) => {
                if let Ok(Output::Process(process)) = result
                    && self.observe(id, &process)
                {
                    self.discover(io, id);
                }
            }
            Pending::Keys { terminal, probe } => {
                let result = result
                    .map_err(|e| error("io_failure", e))
                    .and_then(|output| {
                        let Output::Process(shell) = output else {
                            return Err(error("process_missing", ""));
                        };
                        let owner = self.terminal(terminal)?;
                        if owner.exited
                            || owner.closed
                            || owner.observed.as_ref().is_none_or(|p| !owns(p, &shell))
                        {
                            return Err(error("agent_changed", ""));
                        }
                        Ok(shell)
                    });
                match result {
                    Ok(shell) => {
                        match json::write(&Data::Object(vec![("tty", Data::Unsigned(shell.tty))])) {
                            Ok(input) => self.submit(
                                io,
                                Job::Native {
                                    name: "foreground",
                                    input,
                                },
                                Pending::Foreground {
                                    terminal,
                                    shell,
                                    probe,
                                },
                            ),
                            Err(failure) => self.verified(io, terminal, probe, Err(failure)),
                        }
                    }
                    Err(failure) => self.verified(io, terminal, probe, Err(failure)),
                }
            }
            Pending::Foreground {
                terminal,
                shell,
                probe,
            } => {
                let checked = result
                    .map_err(|e| error("io_failure", e))
                    .and_then(|output| {
                        let owner = self.terminal(terminal)?;
                        if owner.exited
                            || owner.closed
                            || owner.observed.as_ref().is_none_or(|p| !owns(p, &shell))
                        {
                            return Err(error("agent_changed", ""));
                        }
                        let expected = probe
                            .as_ref()
                            .map(|(process, _)| process)
                            .or_else(|| {
                                owner.input.front().and_then(|input| input.process.as_ref())
                            })
                            .ok_or_else(|| error("agent_changed", ""))?
                            .clone();
                        let control = owner.control.clone();
                        let Output::Bytes(bytes) = output else {
                            return Err(error("foreground_missing", ""));
                        };
                        let members = foreground(&bytes, &shell)?;
                        let mut matching: Vec<_> = members
                            .iter()
                            .flat_map(|p| {
                                self.harnesses
                                    .iter()
                                    .filter(|h| h.borrow().matches(p))
                                    .map(move |_| p)
                            })
                            .collect();
                        if let Some(control) = control.as_ref()
                            && let Some(current) = members.iter().find(|p| same(control, p))
                            && !matching.iter().any(|p| same(p, current))
                        {
                            matching.push(current);
                        }
                        // Verifying an owner's identity does not claim exclusive input.
                        // Actual typing still requires exactly one harness/control target.
                        if !matching.iter().any(|current| same(current, &expected))
                            || (probe.is_none() && matching.len() != 1)
                        {
                            return Err(error("agent_changed", ""));
                        }
                        Ok(())
                    });
                self.verified(io, terminal, probe, checked);
            }
            Pending::Hook {
                terminal,
                harness,
                hook,
                depth,
                mut agent,
                event,
            } => {
                if let Ok(Output::Process(process)) = result {
                    if let Some(terminal) = terminal {
                        if self
                            .terminal(terminal)
                            .is_ok_and(|t| !t.exited && !t.closed)
                            && agent.as_ref().is_some_and(|p| same(p, &process))
                            && self.harnesses[harness].borrow().matches(&process)
                        {
                            let observed = self.observed.clone();
                            let fallback = hook.fallback.clone();
                            self.harnesses[harness].borrow_mut().identify(
                                io,
                                &process,
                                Some(&hook),
                                deferred(Box::new(move |io, result| {
                                    observed.borrow_mut().push_back(
                                        discovery::Observation::Identified {
                                            terminal,
                                            harness,
                                            result,
                                            event: Some((event, fallback)),
                                        },
                                    );
                                    io.timer(io.now());
                                })),
                            );
                        }
                    } else {
                        if agent.is_none() && self.harnesses[harness].borrow().matches(&process) {
                            agent = Some(process.clone());
                        }
                        let owner = self.terminals.iter().find(|t| {
                            !t.exited
                                && !t.closed
                                && t.child.pid == process.pid
                                && t.observed.as_ref().is_some_and(|p| owns(p, &process))
                        });
                        if let Some(owner) = owner {
                            let terminal = Some(owner.node.id);
                            if let Some(candidate) = &agent {
                                self.submit(
                                    io,
                                    Job::Process { pid: candidate.pid },
                                    Pending::Hook {
                                        terminal,
                                        harness,
                                        hook,
                                        depth,
                                        agent,
                                        event,
                                    },
                                );
                            }
                        } else if depth < 32 && process.parent > 1 && process.parent != process.pid
                        {
                            self.submit(
                                io,
                                Job::Process {
                                    pid: process.parent,
                                },
                                Pending::Hook {
                                    terminal: None,
                                    harness,
                                    hook,
                                    depth: depth + 1,
                                    agent,
                                    event,
                                },
                            );
                        }
                    }
                }
            }
        }
    }
}
