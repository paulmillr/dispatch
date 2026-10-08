use super::*;
use std::cell::Cell;

pub(super) enum Observation {
    Scan {
        terminal: Id,
        bindings: Vec<(usize, Binding)>,
    },
    Identified {
        terminal: Id,
        harness: usize,
        result: Result<Option<Binding>, Error>,
        event: Option<(Event, Vec<u8>)>,
    },
    Checked {
        terminal: Id,
        harness: usize,
        binding: Binding,
        result: Result<(), Error>,
        event: Option<(Event, Vec<u8>)>,
    },
}

impl Native {
    pub(super) fn observe(&mut self, id: Id, process: &Process) -> bool {
        let Ok(t) = self.terminal(id) else {
            return false;
        };
        if t.closed || t.exited || t.child.pid != process.pid {
            return false;
        }
        let observed = t.observed.get_or_insert_with(|| process.clone());
        owns(observed, process)
    }

    pub(super) fn discover(&mut self, io: &mut dyn Io, id: Id) {
        if let Ok(t) = self.terminal(id)
            && !t.closed
            && !t.exited
        {
            if t.discovering {
                self.rescans.insert(id);
                return;
            }
            t.discovering = true;
            t.refresh = false;
            // c1654cc ChatCoordinator.swift:138: output-driven discovery ran every 0.35s.
            // Process watches and hooks retain their immediate paths.
            t.scan = Some(io.now() + std::time::Duration::from_millis(350));
            let pid = t.child.pid;
            let agent = t.node.agent.as_ref().map(|(_, b)| b.process.clone());
            if let Some(process) = agent {
                self.submit(
                    io,
                    Job::Process { pid: process.pid },
                    Pending::Alive {
                        terminal: id,
                        process,
                        reply: None,
                    },
                );
            }
            self.submit(
                io,
                Job::Process { pid },
                Pending::Discover {
                    terminal: id,
                    shell: None,
                },
            );
        }
    }

    pub(super) fn discovered(
        &mut self,
        io: &mut dyn Io,
        id: Id,
        shell: Option<Process>,
        result: io::Result<Output>,
        directory: bool,
    ) {
        let alive = self.terminal(id).is_ok_and(|t| !t.closed && !t.exited);
        if alive {
            match (shell, result) {
                (None, Ok(Output::Process(shell))) => {
                    if self.observe(id, &shell) {
                        if !directory
                            && shell.foreground == shell.group
                            && self.terminal(id).is_ok_and(|t| t.node.agent.is_none())
                            && let Ok(input) = json::write(&Data::Object(vec![(
                                "pid",
                                Data::Unsigned(shell.pid.into()),
                            )]))
                        {
                            self.submit(
                                io,
                                Job::Native {
                                    name: "process",
                                    input,
                                },
                                Pending::Directory {
                                    terminal: id,
                                    shell: shell.clone(),
                                },
                            );
                            return;
                        }
                        let cached = self
                            .terminal(id)
                            .ok()
                            .filter(|t| t.node.agent.is_some() && t.group == Some(shell.foreground))
                            .map(|t| t.members.clone());
                        if let Some(members) = cached {
                            if members.is_empty() {
                                if let Ok(t) = self.terminal(id) {
                                    t.group = None;
                                }
                            } else {
                                let remaining = Rc::new(Cell::new(members.len()));
                                let refreshed = Rc::new(RefCell::new(Vec::new()));
                                for process in members {
                                    self.submit(
                                        io,
                                        Job::Process { pid: process.pid },
                                        Pending::Member {
                                            terminal: id,
                                            shell: shell.clone(),
                                            process,
                                            remaining: remaining.clone(),
                                            members: refreshed.clone(),
                                        },
                                    );
                                }
                                return;
                            }
                        }
                        let input =
                            json::write(&Data::Object(vec![("tty", Data::Unsigned(shell.tty))]));
                        if let Ok(input) = input {
                            self.submit(
                                io,
                                Job::Native {
                                    name: "foreground",
                                    input,
                                },
                                Pending::Discover {
                                    terminal: id,
                                    shell: Some(shell),
                                },
                            );
                            return;
                        }
                    }
                }
                (Some(shell), Ok(Output::Bytes(bytes))) => {
                    if let Ok(members) = foreground(&bytes, &shell) {
                        if let Ok(t) = self.terminal(id) {
                            t.group = Some(shell.foreground);
                            t.members = members.clone();
                        }
                        if self.identify(io, id, shell, members) {
                            return;
                        }
                    }
                }
                _ => {}
            }
        }
        if let Ok(t) = self.terminal(id) {
            t.discovering = false;
        }
    }

    pub(super) fn identify(
        &mut self,
        io: &mut dyn Io,
        id: Id,
        shell: Process,
        members: Vec<Process>,
    ) -> bool {
        if !self.observe(id, &shell) {
            return false;
        }
        let mut candidates: Vec<_> = members
            .iter()
            .filter(|process| {
                self.harnesses
                    .iter()
                    .any(|harness| harness.borrow().matches(process))
            })
            .cloned()
            .collect();
        candidates.sort_by_key(|process| process.pid);
        self.candidates.push((id, match candidates.as_slice() {
            [process] => Some(process.clone()),
            _ => None,
        }));
        if let Ok(terminal) = self.terminal(id)
            && (terminal.candidates.len() != candidates.len()
                || !terminal
                    .candidates
                    .iter()
                    .zip(&candidates)
                    .all(|(old, new)| same(old, new)))
        {
            terminal.candidates = candidates;
            let bound = terminal.node.agent.as_ref().is_some_and(|(_, binding)| {
                terminal
                    .candidates
                    .iter()
                    .any(|process| same(process, &binding.process))
            });
            terminal.retry = if terminal.candidates.is_empty() || bound {
                None
            } else {
                let delay = std::time::Duration::from_millis(350);
                let deadline = io.now() + delay;
                io.timer(deadline);
                Some((deadline, 3, delay))
            };
        }
        if let [process] = members.as_slice() {
            if self
                .terminal(id)
                .is_ok_and(|t| t.client.as_ref() != Some(process))
            {
                self.submit(
                    io,
                    Job::Process { pid: shell.pid },
                    Pending::Client {
                        terminal: id,
                        process: process.clone(),
                    },
                );
            }
        } else if let Ok(t) = self.terminal(id) {
            t.client = None;
        }
        let remaining = Rc::new(Cell::new(members.len() * self.harnesses.len()));
        let bindings = Rc::new(RefCell::new(Vec::new()));
        if remaining.get() != 0 {
            for process in members {
                for (index, harness) in self.harnesses.iter().enumerate() {
                    let remaining = remaining.clone();
                    let bindings = bindings.clone();
                    let observed = self.observed.clone();
                    // All providers inspect native process facts; no provider name or PID hint chooses one.
                    harness.borrow_mut().identify(
                        io,
                        &process,
                        None,
                        deferred(Box::new(move |io, result| {
                            if let Ok(Some(binding)) = result {
                                bindings.borrow_mut().push((index, binding));
                            }
                            remaining.set(remaining.get() - 1);
                            if remaining.get() == 0 {
                                observed.borrow_mut().push_back(Observation::Scan {
                                    terminal: id,
                                    bindings: std::mem::take(&mut *bindings.borrow_mut()),
                                });
                                io.timer(io.now());
                            }
                        })),
                    );
                }
            }
            return true;
        }
        false
    }

    pub(super) fn observations(&mut self, io: &mut dyn Io) -> Vec<(usize, Event)> {
        let pending: Vec<_> = self.observed.borrow_mut().drain(..).collect();
        let mut hooks = Vec::new();
        for observation in pending {
            let (terminal, harness, result, event) = match observation {
                Observation::Scan {
                    terminal,
                    mut bindings,
                } => {
                    if let Ok(t) = self.terminal(terminal) {
                        t.discovering = false;
                    }
                    if bindings.len() != 1 {
                        continue;
                    }
                    let (harness, binding) = bindings.pop().unwrap();
                    (terminal, harness, Ok(Some(binding)), None)
                }
                Observation::Identified {
                    terminal,
                    harness,
                    result,
                    event,
                } => (terminal, harness, result, event),
                Observation::Checked {
                    terminal,
                    harness,
                    binding,
                    result,
                    event,
                } => {
                    if result.is_ok()
                        && let Ok(t) = self.terminal(terminal)
                        && !t.closed
                        && !t.exited
                    {
                        let changed = t.node.agent.as_ref().is_none_or(|(old, previous)| {
                            *old != harness
                                || previous.session != binding.session
                                || previous.transcript != binding.transcript
                                || !same(&previous.process, &binding.process)
                        });
                        t.node.agent = Some((harness, binding));
                        self.dirty |= changed;
                        if changed {
                            self.agents.push(terminal);
                        }
                        if let Some((event, _)) = event {
                            hooks.push((harness, event));
                        }
                    } else if let Some((
                        Event::Hook {
                            reply: Some(reply), ..
                        },
                        fallback,
                    )) = event
                    {
                        let _ = io.reply(reply, &fallback);
                    }
                    continue;
                }
            };
            match result {
                Ok(Some(binding)) => {
                    let process = binding.process.clone();
                    let observed = self.observed.clone();
                    self.check(
                        io,
                        terminal,
                        &process,
                        Box::new(move |io, result| {
                            observed.borrow_mut().push_back(Observation::Checked {
                                terminal,
                                harness,
                                binding,
                                result,
                                event,
                            });
                            io.timer(io.now());
                        }),
                    );
                }
                _ => {
                    if let Some((
                        Event::Hook {
                            reply: Some(reply), ..
                        },
                        fallback,
                    )) = event
                    {
                        let _ = io.reply(reply, &fallback);
                    }
                }
            }
        }
        hooks
    }
}
