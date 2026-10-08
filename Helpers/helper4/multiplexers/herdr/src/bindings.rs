use super::*;

impl Ui for Herdr {
    fn update(&mut self, update: Update) {
        self.notifications.push_back(update);
    }
    fn terminal(&self, binding: &Binding) -> Option<Id> {
        if let Some(id) = self
            .endpoints
            .values()
            .find_map(|endpoint| endpoint.terminal(binding))
        {
            return Some(id);
        }
        self.agents
            .iter()
            .find(|(id, (_, current))| {
                current.session == binding.session
                    && current.process.pid == binding.process.pid
                    && current.process.start == binding.process.start
                    && self
                        .snapshot
                        .panes
                        .iter()
                        .any(|pane| self.graph.ids.get(&pane.terminal) == Some(id))
            })
            .map(|(id, _)| *id)
    }
}

impl Herdr {
    pub(super) fn candidate(&self, processes: &[Process]) -> Option<(usize, Process)> {
        crate::process::select(processes, |process| {
            self.harnesses
                .iter()
                .position(|harness| harness.borrow().matches(process))
        })
        .map(|(index, process)| (index, process.clone()))
    }
    fn forget(&mut self, id: Id) {
        self.notifications.push_back(Update::Candidate { terminal: id, process: None });
        self.probes.remove(&id);
        if self.agents.remove(&id).is_some() {
            self.topology();
            self.notifications.push_back(Update::Agent {
                terminal: id,
                summary: Summary::default(),
            });
        }
    }
    pub(super) fn recheck(&mut self, io: &mut dyn Io, id: Id) {
        let Some((_, binding)) = self.agents.get(&id) else {
            self.probes.remove(&id);
            return;
        };
        let expected = binding.process.clone();
        self.probes.insert(id);
        self.job(
            io,
            Job::Process { pid: expected.pid },
            Box::new(move |mux, _, result| {
                mux.probes.remove(&id);
                if !mux
                    .agents
                    .get(&id)
                    .is_some_and(|(_, binding)| crate::process::same(&binding.process, &expected))
                {
                    return;
                }
                let gone = match result {
                    Ok(Output::Process(process)) => !crate::process::same(&process, &expected),
                    Err(reason) => reason.kind() == io::ErrorKind::NotFound,
                    _ => false,
                };
                if gone {
                    mux.forget(id);
                }
            }),
        );
    }
    pub(super) fn discover(&mut self, io: &mut dyn Io) {
        let panes: Vec<_> = self
            .snapshot
            .panes
            .iter()
            .map(|p| (self.graph.ids[&p.terminal], p.key.clone()))
            .collect();
        for (id, pane) in panes {
            self.identify(io, id, pane);
        }
    }
    pub(super) fn rediscover(&mut self, io: &mut dyn Io, id: Id) {
        // Conversation replacement can keep the same foreground process and pane.
        let pane = self
            .snapshot
            .panes
            .iter()
            .find(|pane| self.graph.ids.get(&pane.terminal) == Some(&id))
            .map(|pane| pane.key.clone());
        if let Some(pane) = pane {
            self.identify(io, id, pane);
        }
    }
    fn identify(&mut self, io: &mut dyn Io, id: Id, pane: String) {
        if !self.probes.insert(id) {
            return;
        }
        self.call(
            io,
            "pane.process_info",
            D::Object(vec![("pane_id", D::String(&pane))]),
            Order::Background,
            Box::new(move |mux, io, result| {
                let pid = result
                    .ok()
                    .and_then(|j| {
                        j.root()
                            .get("process_info")
                            .and_then(|v| v.get("shell_pid"))
                            .and_then(Value::unsigned)
                    })
                    .and_then(|pid| u32::try_from(pid).ok());
                let Some(pid) = pid else {
                    mux.recheck(io, id);
                    return;
                };
                mux.job(
                    io,
                    Job::Process { pid },
                    Box::new(move |mux, io, result| {
                        let Ok(Output::Process(shell)) = result else {
                            mux.recheck(io, id);
                            return;
                        };
                        if !mux
                            .snapshot
                            .panes
                            .iter()
                            .any(|pane| mux.graph.ids.get(&pane.terminal) == Some(&id))
                        {
                            mux.forget(id);
                            return;
                        }
                        mux.shell(id, &shell);
                        if shell.tty == 0 || shell.foreground <= 1 {
                            mux.recheck(io, id);
                            return;
                        }
                        let input =
                            match json::write(&D::Object(vec![("tty", D::Unsigned(shell.tty))])) {
                                Ok(v) => v,
                                Err(_) => {
                                    mux.probes.remove(&id);
                                    return;
                                }
                            };
                        mux.job(
                            io,
                            Job::Native {
                                name: "foreground",
                                input,
                            },
                            Box::new(move |mux, io, result| {
                                let processes = match crate::process::foreground(result, &shell) {
                                    Ok(processes) => processes,
                                    Err(_) => {
                                        mux.recheck(io, id);
                                        return;
                                    }
                                };
                                let candidate = mux.candidate(&processes);
                                mux.notifications.push_back(Update::Candidate {
                                    terminal: id, process: candidate.as_ref().map(|(_, process)| process.clone()),
                                });
                                let Some((index, process)) = candidate else {
                                    mux.recheck(io, id);
                                    return;
                                };
                                mux.probes.insert(id);
                                let queue = mux.bindings.clone();
                                let expected = process.clone();
                                let owner = io.section("");
                                io.section(&owner);
                                mux.harnesses[index].borrow_mut().identify(
                                    io,
                                    &process,
                                    None,
                                    deferred(Box::new(move |io, result| {
                                        queue
                                            .borrow_mut()
                                            .push_back((id, index, shell, expected, result));
                                        let previous = io.section(&owner);
                                        io.timer(io.now());
                                        io.section(&previous);
                                    })),
                                );
                            }),
                        );
                    }),
                );
            }),
        );
    }
    pub(super) fn bound(&mut self, io: &mut dyn Io) {
        let results = std::mem::take(&mut *self.bindings.borrow_mut());
        let mut changed = std::collections::BTreeSet::new();
        for (id, index, shell, expected, result) in results {
            self.probes.remove(&id);
            if let Ok(Some(binding)) = result
                && crate::process::owns(&shell, &binding.process, &expected)
                && self
                    .snapshot
                    .panes
                    .iter()
                    .any(|pane| self.graph.ids.get(&pane.terminal) == Some(&id))
            {
                if self.agents.get(&id) != Some(&(index, binding.clone())) {
                    changed.insert(id);
                }
                self.agents.insert(id, (index, binding));
            } else {
                self.recheck(io, id);
            }
        }
        let ready: Vec<_> = self.rescans.iter().copied()
            .filter(|id| !self.probes.contains(id)).collect();
        for id in ready {
            self.rescans.remove(&id);
            self.rediscover(io, id);
        }
        if !changed.is_empty() {
            self.topology();
            self.notifications
                .extend(changed.into_iter().map(|terminal| Update::Agent {
                    terminal,
                    summary: Summary::default(),
                }));
        }
    }
    pub(super) fn shell(&mut self, id: Id, shell: &Process) {
        if shell.tty != 0 && self.ttys.insert(id, shell.tty) != Some(shell.tty) {
            self.topology();
        }
    }
    pub(super) fn topology(&mut self) {
        if self.placements != 0 {
            return;
        }
        if let Ok((mut nodes, layouts)) = self.graph.topology(self.backend, &self.snapshot) {
            for node in &mut nodes {
                node.agent = self.agents.get(&node.id).cloned();
                node.tty = self.ttys.get(&node.id).copied();
                if let Some(grid) = self.controllers.get(&node.id).and_then(|c| c.decoder.grid) {
                    node.size = Some(grid);
                }
            }
            self.retained(&mut nodes);
            self.notifications.push_back(Update::Topology {
                key: None,
                focus: self.graph.focus(&self.snapshot),
                backend: self.backend,
                nodes,
                layouts,
            });
        }
    }
}
