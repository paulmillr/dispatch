use super::*;

impl Multiplexer for Herdr {
    /// herdr opens sessions that already exist as spaces, like tmux (c1654cc
    /// NewSpaceButton.swift:24-36: tmux and herdr are the external space backends).
    fn external(&self) -> bool {
        true
    }
    fn prefix(&mut self, io: &mut dyn Io, node: Id, done: Done<Prefix>) {
        Herdr::prefix(self, io, node, done);
    }
    fn name(&self) -> &str {
        "herdr"
    }
    fn launch(&mut self, io: &mut dyn Io, process: &Process, done: Done<Option<String>>) {
        self.context(io, process, true, done);
    }
    fn probe(&mut self, io: &mut dyn Io, process: &Process, done: Done<Option<String>>) {
        Herdr::probe(self, io, process, done);
    }
    fn release(&mut self, io: &mut dyn Io, client: &Process, done: Done<()>) {
        if !client::matches(client) {
            self.defer(io, done, Err(expired("The Herdr launcher changed.")));
            return;
        }
        let input = json::write(&D::Object(vec![
            ("pid", D::Unsigned(client.pid.into())),
            ("start", D::Array(client.start.into_iter().map(D::Unsigned).collect())),
            ("executable", D::String(&client.executable.to_string_lossy())),
            ("tty", D::Unsigned(client.tty)),
            ("foreground", D::Signed(client.foreground.into())),
        ]));
        let input = match input {
            Ok(input) => input,
            Err(reason) => { self.defer(io, done, Err(reason)); return; }
        };
        let deadline = io.now() + Duration::from_secs(3);
        self.job(io, Job::Isolated {
            name: "process.terminate", input, deadline,
        }, Box::new(move |mux, io, result| {
            let result = match result {
                Ok(Output::Bytes(bytes)) if bytes == b"true" => Ok(()),
                Ok(Output::Bytes(bytes)) if bytes == b"false" => Err(expired("The Herdr launcher changed.")),
                _ => Err(Error { code: "uncertain", message: "Herdr launcher release was not confirmed.".into() }),
            };
            mux.defer(io, done, result);
        }));
    }
    fn invalidate(&mut self, io: &mut dyn Io, process: &Process) {
        for endpoint in self.endpoints.values_mut() { endpoint.invalidate(io, process); }
        let mut changed = false;
        for (&id, (_, binding)) in &self.agents {
            if binding.process.pid == process.pid && binding.process.start == process.start {
                changed |= self.rescans.insert(id);
            }
        }
        if changed { io.timer(io.now()); }
    }
    fn harnesses(&mut self, list: Vec<Shared<dyn Harness>>) {
        for endpoint in self.endpoints.values_mut() {
            endpoint.harnesses(list.clone());
        }
        self.harnesses = list;
    }
    fn backends(&mut self, io: &mut dyn Io, done: Done<Vec<String>>) {
        self.available(io, done, true);
    }

    fn open(&mut self, io: &mut dyn Io, key: &str, done: Done<Id>) {
        self.opening(io, key, None, false, done);
    }
    fn create(
        &mut self,
        io: &mut dyn Io,
        parent: Id,
        beside: Option<Id>,
        command: Option<Command>,
        size: Option<Grid>,
        done: Done<Id>,
    ) {
        if let Some(endpoint) = self.endpoint(parent) {
            endpoint.create(io, parent, beside, command, size, done);
            return;
        }
        let environment = match self.environment(io, self.config.environment.clone()) {
            Ok(environment) => environment,
            Err(reason) => {
                self.defer(io, done, Err(reason));
                return;
            }
        };
        if let Some(command) = command {
            if parent == self.backend && beside.is_none() {
                let cwd = command
                    .get_current_dir()
                    .unwrap_or(&self.config.directory)
                    .to_string_lossy()
                    .into_owned();
                self.mutation(
                    io,
                    "workspace.create",
                    D::Object(vec![
                        ("cwd", D::String(&cwd)),
                        ("focus", D::Bool(true)),
                        (
                            "env",
                            D::Object(
                                environment
                                    .iter()
                                    .map(|(k, v)| (k.as_str(), D::String(v)))
                                    .collect(),
                            ),
                        ),
                    ]),
                    Box::new(move |mux, io, result| {
                        let created = result.and_then(|json| {
                            Ok((
                                text(field(json.root(), "workspace")?, "workspace_id")?,
                                text(field(json.root(), "root_pane")?, "pane_id")?,
                            ))
                        });
                        match created {
                            Ok((workspace, pane)) => mux.launch(
                                io,
                                Launch {
                                    workspace,
                                    beside: None,
                                    close: Some(pane),
                                    command,
                                    done,
                                },
                            ),
                            Err(e) => mux.defer(io, done, Err(e)),
                        }
                    }),
                );
                return;
            }
            let target = self
                .locate(beside.unwrap_or(parent))
                .and_then(|(kind, key)| {
                    if kind == Kind::Workspace {
                        return Ok((key, None));
                    }
                    let pane = self
                        .snapshot
                        .panes
                        .iter()
                        .find(|p| {
                            if kind == Kind::Terminal {
                                p.key == key
                            } else {
                                p.parent == key
                                    && self
                                        .snapshot
                                        .layouts
                                        .iter()
                                        .any(|l| l.key == key && l.focus == p.key)
                            }
                        })
                        .ok_or_else(|| {
                            expired("The herdr creation target is no longer available.")
                        })?;
                    let workspace = self
                        .snapshot
                        .tabs
                        .iter()
                        .find(|t| t.key == pane.parent)
                        .ok_or_else(|| {
                            expired("The herdr creation target is no longer available.")
                        })?
                        .parent
                        .clone();
                    Ok((workspace, Some((pane.parent.clone(), pane.key.clone()))))
                });
            match target {
                Ok((workspace, beside)) => self.launch(
                    io,
                    Launch {
                        workspace,
                        beside,
                        close: None,
                        command,
                        done,
                    },
                ),
                Err(e) => self.defer(io, done, Err(e)),
            }
            return;
        }
        let location = beside
            .map(|id| self.locate(id))
            .transpose()
            .and_then(|beside| {
                if let Some((Kind::Terminal, key)) = beside {
                    Ok(("pane.split", "target_pane_id", key))
                } else if parent == self.backend {
                    Ok(("workspace.create", "", String::new()))
                } else {
                    self.locate(parent).and_then(|(kind, key)| {
                        if kind == Kind::Workspace {
                            Ok(("tab.create", "workspace_id", key))
                        } else if kind == Kind::Tab {
                            self.snapshot
                                .layouts
                                .iter()
                                .find(|layout| layout.key == key)
                                .map(|layout| {
                                    ("pane.split", "target_pane_id", layout.focus.clone())
                                })
                                .ok_or_else(|| {
                                    expired("The herdr creation target is no longer available.")
                                })
                        } else {
                            Ok(("pane.split", "target_pane_id", key))
                        }
                    })
                }
            });
        let (method, field, key) = match location {
            Ok(v) => v,
            Err(e) => {
                self.defer(io, done, Err(e));
                return;
            }
        };
        let cwd = self.config.directory.to_string_lossy().into_owned();
        let source = self.snapshot.focus[0].clone();
        let mut params = vec![("focus", D::Bool(true))];
        if method == "workspace.create" {
            if let Some(source) = &source {
                params.push(("source_workspace_id", D::String(source)));
            } else if self.snapshot.workspaces.is_empty() {
                params.push(("cwd", D::String(&cwd)));
            }
        }
        if !field.is_empty() {
            params.push((field, D::String(&key)));
        }
        if method == "pane.split" {
            params.extend([("direction", D::String("right")), ("ratio", D::Real(0.5))]);
        }
        let env: Vec<_> = environment
            .iter()
            .map(|(k, v)| (k.as_str(), D::String(v)))
            .collect();
        params.push(("env", D::Object(env)));
        self.mutation(
            io,
            method,
            D::Object(params),
            Box::new(move |mux, io, result| {
                let result = result.and_then(|json| mux.created(json.root()));
                mux.defer(io, done, result.map(|(id, _)| id));
            }),
        );
    }
    fn rename(&mut self, io: &mut dyn Io, node: Id, name: &str, done: Done<()>) {
        if let Some(endpoint) = self.endpoint(node) {
            endpoint.rename(io, node, name, done);
            return;
        }
        if !native::label(name) {
            self.defer(io, done, Err(error("Invalid herdr label.")));
            return;
        }
        self.node(io, node, "rename", vec![("label", D::String(name))], done);
    }
    fn focus(&mut self, io: &mut dyn Io, node: Id, done: Done<()>) {
        if let Some(endpoint) = self.endpoint(node) {
            endpoint.focus(io, node, done);
            return;
        }
        self.node(io, node, "focus", Vec::new(), done);
    }
    fn r#move(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        parent: Id,
        before: Option<Id>,
        done: Done<()>,
    ) {
        if let Some(endpoint) = self.endpoint(node) {
            endpoint.r#move(io, node, parent, before, done);
            return;
        }
        let source = self.locate(node);
        let target = self.locate(parent);
        let before = before.and_then(|id| self.locate(id).ok());
        if matches!(source, Ok((Kind::Workspace, _))) && parent == self.backend {
            let index = before
                .as_ref()
                .and_then(|(_, key)| self.snapshot.workspaces.iter().position(|w| &w.key == key))
                .unwrap_or(self.snapshot.workspaces.len().saturating_sub(1));
            self.node(
                io,
                node,
                "move",
                vec![("insert_index", D::Unsigned(index as u64))],
                done,
            );
            return;
        }
        match (source, target) {
            (Ok((kind, key)), Ok((target, parent))) => {
                if kind == Kind::Terminal {
                    let original = self
                        .snapshot
                        .panes
                        .iter()
                        .find(|pane| pane.key == key)
                        .unwrap()
                        .clone();
                    let mut destination = vec![(
                        "type",
                        if target == Kind::Workspace {
                            "new_tab"
                        } else {
                            "tab"
                        }
                        .to_owned(),
                    )];
                    destination.push((
                        if target == Kind::Workspace {
                            "workspace_id"
                        } else {
                            "tab_id"
                        },
                        parent,
                    ));
                    if target != Kind::Workspace {
                        destination.push(("split", "right".to_owned()));
                        if let Some((Kind::Terminal, pane)) = &before {
                            destination.push(("target_pane_id", pane.clone()));
                        }
                    }
                    self.call(
                        io,
                        "session.snapshot",
                        D::Object(Vec::new()),
                        Order::Normal,
                        Box::new(move |mux, io, result| {
                            let pane = result.and_then(|json| {
                                let state = Snapshot::read(field(json.root(), "snapshot")?)?;
                                state.panes.into_iter().find(|pane| {
                                    pane.terminal == original.terminal && pane.parent == original.parent
                                }).ok_or_else(|| error("The herdr terminal moved or exited before it could move."))
                            });
                            let finish: Action = Box::new(move |mux, io, result| {
                                if result.is_ok() {
                                    mux.reveal(node);
                                    mux.topology();
                                }
                                mux.defer(io, done, result.map(|_| ()))
                            });
                            match pane {
                                Ok(pane) => mux.mutation(
                                    io,
                                    "pane.move",
                                    D::Object(vec![
                                        ("pane_id", D::String(&pane.key)),
                                        ("destination", D::Object(destination.iter().map(|(key, value)| {
                                            (*key, D::String(value))
                                        }).collect())),
                                        ("focus", D::Bool(false)),
                                    ]),
                                    finish,
                                ),
                                Err(error) => mux.reconcile(io, Err(error), finish),
                            }
                        }),
                    );
                } else {
                    let keys: Vec<_> = if kind == Kind::Workspace {
                        self.snapshot.workspaces.iter().map(|w| &w.key).collect()
                    } else {
                        self.snapshot
                            .tabs
                            .iter()
                            .filter(|t| t.parent == parent)
                            .map(|t| &t.key)
                            .collect()
                    };
                    let index = before
                        .as_ref()
                        .and_then(|(_, key)| keys.iter().position(|k| *k == key))
                        .unwrap_or(keys.len().saturating_sub(1));
                    self.node(
                        io,
                        node,
                        "move",
                        vec![("insert_index", D::Unsigned(index as u64))],
                        done,
                    );
                }
            }
            _ => self.defer(
                io,
                done,
                Err(expired("The herdr move target is no longer available.")),
            ),
        }
    }
    fn split(&mut self, io: &mut dyn Io, node: Id, ratio: f64, done: Done<()>) {
        if let Some(endpoint) = self.endpoint(node) {
            endpoint.split(io, node, ratio, done);
            return;
        }
        if !ratio.is_finite() {
            self.defer(io, done, Ok(()));
            return;
        }
        let selected = self.snapshot.layouts.iter().find_map(|l| {
            l.splits
                .as_ref()?
                .iter()
                .find(|d| self.graph.ids.get(&format!("{}/{}", l.key, d.key)) == Some(&node))
                .map(|d| (l.clone(), d.key.clone()))
        });
        let Some((layout, split)) = selected else {
            self.defer(
                io,
                done,
                Err(expired("The herdr divider is no longer available.")),
            );
            return;
        };
        self.call(
            io,
            "session.snapshot",
            D::Object(Vec::new()),
            Order::Normal,
            Box::new(move |mux, io, result| {
                let current =
                    result.and_then(|json| Snapshot::read(field(json.root(), "snapshot")?));
                let valid = current
                    .as_ref()
                    .ok()
                    .and_then(|s| s.layouts.iter().find(|l| l.key == layout.key))
                    .is_some_and(|l| {
                        l.zoomed != Some(true)
                            && l.splits == layout.splits
                            && l.panes
                                .iter()
                                .map(|p| &p.0)
                                .eq(layout.panes.iter().map(|p| &p.0))
                    });
                if !valid {
                    mux.reconcile(
                        io,
                        Err(error(
                            "The layout changed during the drag. Try resizing again.",
                        )),
                        Box::new(move |mux, io, result| {
                            mux.defer(io, done, result.map(|_| ()));
                        }),
                    );
                    return;
                }
                let route = native::path(&split).unwrap();
                mux.mutation(
                    io,
                    "layout.set_split_ratio",
                    D::Object(vec![
                        ("tab_id", D::String(&layout.key)),
                        ("path", D::Array(route.into_iter().map(D::Bool).collect())),
                        ("ratio", D::Real(ratio.clamp(0.1, 0.9))),
                    ]),
                    Box::new(move |mux, io, r| mux.defer(io, done, r.map(|_| ()))),
                );
            }),
        );
    }
    fn zoom(&mut self, io: &mut dyn Io, terminal: Id, zoomed: bool, done: Done<()>) {
        if let Some(endpoint) = self.endpoint(terminal) {
            endpoint.zoom(io, terminal, zoomed, done);
            return;
        }
        self.node(
            io,
            terminal,
            "zoom",
            vec![("mode", D::String(if zoomed { "on" } else { "off" }))],
            done,
        );
    }
    fn idle(&mut self, io: &mut dyn Io, node: Id, done: Done<bool>) {
        if let Some(endpoint) = self.endpoint(node) {
            endpoint.idle(io, node, done);
            return;
        }
        self.inspect(
            io,
            node,
            Box::new(move |mux, io, result| mux.defer(io, done, result)),
        );
    }
    fn close(&mut self, io: &mut dyn Io, node: Id, how: Close, done: Done<()>) {
        if let Some(endpoint) = self.endpoint(node) {
            endpoint.close(io, node, how, done);
            return;
        }
        if how == Close::Prompt {
            self.prompt(io, node, done);
            return;
        }
        if how == Close::Detach {
            let descendants: Vec<_> = self
                .descendants(node)
                .into_iter()
                .filter_map(|p| self.graph.ids.get(&p.terminal).copied())
                .collect();
            for id in descendants {
                if let Some(mut controller) = self.controllers.remove(&id) {
                    controller.close(io, error("Herdr terminal detached."));
                }
            }
            self.detached.insert(node);
            self.topology();
            io.timer(io.now());
            self.defer(io, done, Ok(()));
        } else {
            self.node(io, node, "close", Vec::new(), done);
        }
    }
    fn attach(
        &mut self,
        io: &mut dyn Io,
        terminal: Id,
        size: Grid,
        takeover: bool,
        done: Done<()>,
    ) {
        if let Some(endpoint) = self.endpoint(terminal) {
            endpoint.attach(io, terminal, size, takeover, done);
            return;
        }
        if !native::size(size) {
            self.defer(io, done, Err(error("Invalid herdr terminal size.")));
            return;
        }
        self.reveal(terminal);
        self.topology();
        if let Some(c) = self.controllers.get_mut(&terminal)
            && (c.stream.is_some() || (c.initial && c.retry.is_none()))
        {
            let result = c.resize(io, size);
            if result.is_ok() && c.decoder.sequence.is_none() {
                c.waiters.push(done);
            } else {
                self.defer(io, done, result);
            }
            return;
        }
        if let Some(mut c) = self.controllers.remove(&terminal) {
            c.close(io, error("Herdr attachment replaced."));
        }
        self.notifications.push_back(Update::Output {
            terminal,
            bytes: b"\x1b[?1049h\x1b[?7l".to_vec(),
        });
        // Admit input immediately; starting the controller remains deferred.
        let mut controller = Controller::new(size, true);
        controller.waiters.push(done);
        self.controllers.insert(terminal, controller);
        self.deferred.push_back(Box::new(move |mux, io| {
            let Some(controller) = mux.controllers.get(&terminal) else {
                return;
            };
            if controller.stream.is_some() || !controller.initial {
                return;
            }
            let grid = controller.decoder.grid.unwrap();
            if let Err(reason) = mux.controller(io, terminal, grid, true, takeover, None)
                && let Some(mut controller) = mux.controllers.remove(&terminal)
            {
                controller.close(io, reason);
            }
        }));
        io.timer(io.now());
    }
    fn input(&mut self, io: &mut dyn Io, terminal: Id, bytes: &[u8], done: Done<()>) {
        if let Some(endpoint) = self.endpoint(terminal) {
            endpoint.input(io, terminal, bytes, done);
            return;
        }
        let result = if let Some(c) = self.controllers.get_mut(&terminal) {
            if c.decoder.sequence.is_none() {
                if !c.initial {
                    Err(error("Herdr terminal is disconnected."))
                } else if c.pending.len() + bytes.len() > 65536 {
                    Err(error("Too much input while waiting for herdr to attach."))
                } else {
                    c.pending.extend_from_slice(bytes);
                    Ok(())
                }
            } else {
                self.stream(io, terminal, bytes)
            }
        } else {
            self.locate(terminal)
                .and(Err(error("Herdr terminal is not attached.")))
        };
        self.defer(io, done, result);
    }
    fn check(&mut self, io: &mut dyn Io, terminal: Id, process: &Process, done: Done<()>) {
        if let Some(endpoint) = self.endpoint(terminal) {
            endpoint.check(io, terminal, process, done);
            return;
        }
        self.control(io, terminal, process, None, done);
    }
    fn keys(
        &mut self,
        io: &mut dyn Io,
        terminal: Id,
        process: &Process,
        input: &[Input],
        done: Done<()>,
    ) {
        if let Some(endpoint) = self.endpoint(terminal) {
            endpoint.keys(io, terminal, process, input, done);
            return;
        }
        self.type_input(io, terminal, process, input, done);
    }
    fn seek(&mut self, io: &mut dyn Io, terminal: Id, offset: u64, done: Done<()>) {
        Herdr::seek(self, io, terminal, offset, done);
    }
    fn place(&mut self, io: &mut dyn Io, node: Id, to: &Place, done: Done<()>) {
        Herdr::place(self, io, node, to, done);
    }
    fn program(&self) -> Option<String> {
        Some("herdr".into())
    }
    fn resize(&mut self, io: &mut dyn Io, terminal: Id, size: Grid, done: Done<()>) {
        if let Some(endpoint) = self.endpoint(terminal) {
            endpoint.resize(io, terminal, size, done);
            return;
        }
        let result = if let Some(c) = self.controllers.get_mut(&terminal) {
            // Topology publishes cell counts; pixel geometry is controller input only.
            let changed = c.decoder.grid.map(|grid| (grid.columns, grid.rows))
                != Some((size.columns, size.rows));
            let result = c.resize(io, size);
            // The renderer must adopt the requested grid before any matching full frame.
            if result.is_ok() && changed { self.topology(); }
            result
        } else {
            self.locate(terminal)
                .and(Err(error("Herdr terminal is not attached.")))
        };
        self.defer(io, done, result);
    }
    fn scroll(&mut self, io: &mut dyn Io, terminal: Id, scroll: &Scroll, done: Done<()>) {
        if let Some(endpoint) = self.endpoint(terminal) {
            endpoint.scroll(io, terminal, scroll, done);
            return;
        }
        if scroll
            .at
            .is_some_and(|(column, row)| column > 4096 || row > 4096)
            || scroll.modifiers > 7
        {
            self.defer(io, done, Err(error("Invalid herdr scroll control.")));
            return;
        }
        let lines = scroll.lines;
        let (column, row) = scroll.at.unwrap_or_default();
        let result = if let Some(c) = self.controllers.get_mut(&terminal) {
            if c.decoder.sequence.is_none() || lines == 0 {
                Ok(())
            } else {
                json::write(&D::Object(vec![
                    ("type", D::String("terminal.scroll")),
                    (
                        "direction",
                        D::String(if lines > 0 { "up" } else { "down" }),
                    ),
                    (
                        "lines",
                        D::Unsigned(lines.unsigned_abs().min(u16::MAX.into())),
                    ),
                    (
                        "source",
                        D::String(if scroll.page { "page_key" } else { "wheel" }),
                    ),
                    ("column", D::Unsigned(column.into())),
                    ("row", D::Unsigned(row.into())),
                    ("modifiers", D::Unsigned(scroll.modifiers.into())),
                ]))
                .and_then(|bytes| {
                    c.stream
                        .as_mut()
                        .ok_or_else(|| error("Herdr terminal is disconnected."))?
                        .send(io, bytes)
                })
            }
        } else {
            self.locate(terminal)
                .and(Err(error("Herdr terminal is not attached.")))
        };
        self.defer(io, done, result);
    }
    fn screen(&mut self, io: &mut dyn Io, terminal: Id, changed: bool, done: Done<Screen>) {
        if let Some(endpoint) = self.endpoint(terminal) {
            endpoint.screen(io, terminal, changed, done);
            return;
        }
        if self.locate(terminal).is_err() {
            self.defer(
                io,
                done,
                Err(expired("This herdr terminal is no longer available.")),
            );
        } else {
            self.screens.read(io, terminal, changed, done);
        }
    }
    fn publish(&mut self, io: &mut dyn Io, terminal: Id, screen: Screen) {
        if let Some(endpoint) = self.endpoint(terminal) {
            endpoint.publish(io, terminal, screen);
            return;
        }
        self.screens.publish(io, terminal, screen);
    }
    fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) {
        self.route(io, ui, event);
    }
}
