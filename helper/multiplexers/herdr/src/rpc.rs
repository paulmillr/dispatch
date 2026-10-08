use super::*;

impl Herdr {
    pub(super) fn fail(&mut self, io: &mut dyn Io, reason: Error) {
        self.checking = false;
        let request = self.request.take().unwrap();
        request.stream.close(io);
        let reason = native::delivery(reason, request.attempted);
        (request.call.done)(self, io, Err(reason));
    }
    pub(super) fn defer<T: 'static>(
        &mut self,
        io: &mut dyn Io,
        done: Done<T>,
        result: Result<T, Error>,
    ) {
        self.deferred.push_back(Box::new(move |_, io| {
            io.defer(Box::new(move |io| done(io, result)));
        }));
        io.timer(io.now());
    }
    pub(super) fn call(
        &mut self,
        io: &mut dyn Io,
        method: &str,
        params: D<'_>,
        order: Order,
        done: Action,
    ) {
        match json::write(&params) {
            Ok(params) => {
                let call = Call {
                    background: order == Order::Background,
                    method: method.into(),
                    params,
                    done,
                    guard: None,
                    proof: false,
                    deadline: None,
                };
                if order == Order::First {
                    self.calls.push_front(call);
                } else {
                    self.calls.push_back(call);
                }
            }
            Err(e) => self
                .deferred
                .push_back(Box::new(move |mux, io| done(mux, io, Err(e)))),
        };
        io.timer(io.now());
    }
    pub(super) fn pump(&mut self, io: &mut dyn Io) {
        if self.request.is_some() || self.checking {
            return;
        }
        let eligible = |call: &Call| (self.parked.is_none() && !self.preparing) || call.proof;
        let index = self
            .calls
            .iter()
            .position(|call| eligible(call) && !call.background)
            .or_else(|| self.calls.iter().position(eligible));
        let Some(index) = index else {
            return;
        };
        let call = self.calls.remove(index).unwrap();
        if self.owner.is_some() {
            self.checking = true;
            self.authenticate(
                io,
                None,
                Box::new(move |mux, io, result| {
                    mux.checking = false;
                    if let Err(reason) = result {
                        (call.done)(mux, io, Err(reason));
                        return;
                    }
                    let owner = mux.owner.as_ref().unwrap().clone();
                    if let Some(guard) = call.guard.clone() {
                        // Proof RPCs must finish before opening the mutation socket:
                        // an accepted empty socket stalls the native server's accept loop.
                        mux.preparing = true;
                        mux.permit(
                            io,
                            guard.terminal,
                            guard.agent.clone(),
                            Box::new(move |mux, io, result| {
                                mux.preparing = false;
                                match result {
                                    Ok(current) if current.same(&guard) => {
                                        mux.connect(io, call, Some(owner))
                                    }
                                    Ok(_) => (call.done)(
                                        mux,
                                        io,
                                        Err(expired("The agent no longer owns this terminal.")),
                                    ),
                                    Err(reason) => (call.done)(mux, io, Err(reason)),
                                }
                                io.timer(io.now());
                            }),
                        );
                    } else {
                        mux.connect(io, call, Some(owner));
                    }
                }),
            );
            return;
        }
        let input = json::write(&D::Object(vec![(
            "path",
            D::String(&self.config.socket.to_string_lossy()),
        )]))
        .unwrap();
        self.checking = true;
        self.job(
            io,
            Job::Native {
                name: "file.lstat",
                input,
            },
            Box::new(move |mux, io, result| {
                mux.checking = false;
                let result = auth::document(result)
                    .and_then(|json| auth::socket(json.root(), mux.config.uid));
                match result {
                    Ok(socket)
                        if !mux
                            .owner
                            .as_ref()
                            .is_some_and(|owner| !owner.matches(socket)) => {}
                    Ok(_) => {
                        let owner = mux.owner.as_ref().unwrap().clone();
                        mux.retire(io, &owner);
                        (call.done)(mux, io, Err(error("Herdr socket changed.")));
                        return;
                    }
                    Err(reason) => {
                        (call.done)(mux, io, Err(reason));
                        return;
                    }
                }
                mux.connect(io, call, None);
            }),
        );
    }
    fn connect(&mut self, io: &mut dyn Io, call: Call, owner: Option<auth::Endpoint>) {
        if call.deadline.is_some_and(|deadline| deadline <= io.now()) {
            (call.done)(
                self,
                io,
                Err(error("Herdr connection closed or timed out.")),
            );
            return;
        }
        if owner.as_ref().is_some_and(|owner| {
            !self
                .owner
                .as_ref()
                .is_some_and(|current| current.same(owner))
        }) {
            (call.done)(self, io, Err(error("Herdr server changed.")));
            return;
        }
        let fd = match io.connect(&Address::Unix(self.config.socket.clone())) {
            Ok(fd) => fd,
            Err(e) => {
                let mut reason = error(format!(
                    "Could not connect to herdr at {}: {e}",
                    self.config.socket.display()
                ));
                reason.code = match e.kind() {
                    io::ErrorKind::NotFound => "not_found",
                    io::ErrorKind::ConnectionRefused => "connection_refused",
                    _ => "connect",
                };
                (call.done)(self, io, Err(reason));
                io.timer(io.now());
                return;
            }
        };
        self.serial += 1;
        let id = self.serial.to_string();
        let mut deadline = io.now() + Duration::from_secs(3);
        if let Some(limit) = call.deadline {
            deadline = deadline.min(limit);
        }
        if let Some(original) = &self.parked {
            deadline = deadline.min(original.deadline);
        }
        self.request = Some(Request {
            attempted: false,
            id: id.clone(),
            call,
            stream: Stream::new(fd, fd),
            deadline,
            verified: false,
            connecting: owner.clone(),
        });
        self.request.as_mut().unwrap().stream.lines =
            dispatch_helper_core::rpc::Lines::buffer(transport::LIMIT);
        if owner.is_some() {
            self.connected(io);
        } else {
            self.authorize(io, true);
        }
        io.timer(deadline);
    }
    pub(super) fn connected(&mut self, io: &mut dyn Io) {
        let request = self.request.as_ref().unwrap();
        let owner = request.connecting.as_ref().unwrap();
        match io.verify_socket(request.stream.input, &owner.path,
            FileIdentity { device: owner.device, inode: owner.inode },
            (self.config.uid, owner.server.pid)) {
            Ok(()) => {
                self.request.as_mut().unwrap().connecting = None;
                self.authorized(io, true);
            }
            Err(reason) if reason.kind() == io::ErrorKind::WouldBlock => {
                if let Err(reason) = io.interest(request.stream.input, false, true) {
                    self.fail(io, error(reason.to_string()));
                }
            }
            Err(reason) => self.fail(io, error(reason.to_string())),
        }
    }
    pub(super) fn authorize(&mut self, io: &mut dyn Io, initial: bool) {
        let request = self.request.as_mut().unwrap();
        let id = request.id.clone();
        let fd = request.stream.input;
        request.verified = false;
        if let Err(reason) = io.interest(fd, false, false) {
            self.fail(io, error(reason.to_string()));
            return;
        }
        self.checking = true;
        self.authenticate(
            io,
            Some(fd),
            Box::new(move |mux, io, result| {
                if !mux.request.as_ref().is_some_and(|request| request.id == id) {
                    return;
                }
                mux.checking = false;
                if let Err(reason) = result {
                    mux.fail(io, reason);
                    return;
                }
                if let Some(guard) = mux.request.as_ref().unwrap().call.guard.clone() {
                    mux.parked = mux.request.take();
                    mux.permit(
                        io,
                        guard.terminal,
                        guard.agent.clone(),
                        Box::new(move |mux, io, result| {
                            let Some(request) = mux.parked.take() else {
                                return;
                            };
                            mux.request = Some(request);
                            let result = result.and_then(|current| {
                                if mux.request.as_ref().unwrap().deadline <= io.now() {
                                    return Err(error("Herdr connection closed or timed out."));
                                }
                                if current.same(&guard) {
                                    Ok(())
                                } else {
                                    Err(expired("The agent no longer owns this terminal."))
                                }
                            });
                            match result {
                                Ok(()) => mux.authorized(io, initial),
                                Err(reason) => mux.fail(io, reason),
                            }
                        }),
                    );
                } else {
                    mux.authorized(io, initial);
                }
            }),
        );
    }
    fn authorized(&mut self, io: &mut dyn Io, initial: bool) {
        let request = self.request.as_mut().unwrap();
        request.verified = true;
        if !initial {
            if let Err(reason) = io.interest(request.stream.input, true, true) {
                self.fail(io, error(reason.to_string()));
            }
            return;
        }
        let result = native::request(&request.id, &request.call.method, &request.call.params)
            .and_then(|bytes| request.stream.send(io, bytes))
            .and_then(|_| {
                request.attempted |= native::mutation(&request.call.method);
                request.stream.flush(io)
            });
        if let Err(reason) = result {
            self.fail(io, reason);
        } else if self
            .request
            .as_ref()
            .is_some_and(|request| request.stream.queue.front().is_some())
        {
            self.authorize(io, false);
        }
    }

    pub(super) fn reply(&mut self, io: &mut dyn Io, line: &[u8], tail: Vec<Vec<u8>>, eof: bool) {
        let Some(mut request) = self.request.take() else {
            return;
        };
        let paused = io.interest(request.stream.output, false, false);
        let result = Json::parse(line).and_then(|json| {
            let value = json.root();
            native::response(value, &request.id, "Herdr").map_err(|mut reason| {
                if request.call.method == "events.subscribe"
                    && value
                        .get("error")
                        .and_then(|error| error.get("code"))
                        .and_then(Value::string)
                        == Some("invalid_request")
                {
                    reason.code = "schema";
                }
                reason
            })
        });
        let result = if request.call.method != "events.subscribe"
            && (!tail.is_empty() || request.stream.lines.finish().is_err())
        {
            Err(error("Herdr returned multiple replies for one request."))
        } else {
            result
        };
        let result = paused
            .map_err(|reason| error(reason.to_string()))
            .and(result);
        self.checking = true;
        self.authenticate(
            io,
            None,
            Box::new(move |mux, io, owner| {
                mux.checking = false;
                let result = owner
                    .and(result)
                    .map_err(|reason| native::delivery(reason, request.attempted));
                if request.call.method == "events.subscribe" && result.is_ok() {
                    if let Some(old) = mux.subscription.take() {
                        old.close(io);
                    }
                    let _ = io.interest(request.stream.input, true, false);
                    request.stream.queue =
                        dispatch_helper_core::system::queue::Queue::new(transport::LIMIT);
                    mux.subscription = Some(request.stream);
                } else {
                    request.stream.close(io);
                }
                mux.continuation = true;
                (request.call.done)(mux, io, result);
                mux.continuation = false;
                if mux.subscription.is_some() && (!tail.is_empty() || eof) {
                    mux.received(io, tail, eof);
                }
                io.timer(io.now());
            }),
        );
    }
    pub(super) fn apply(&mut self, io: &mut dyn Io, json: &Json) -> Result<(), Error> {
        let value = field(json.root(), "snapshot")?;
        // Events may arrive after an independent, newer snapshot reply. Publish events
        // immediately, but never carry their cached selection over this native snapshot.
        let snapshot = Snapshot::read(value)?;
        let (mut nodes, layouts) = self.graph.topology(self.backend, &snapshot)?;
        for node in &mut nodes {
            if let Some(grid) = self.controllers.get(&node.id).and_then(|c| c.decoder.grid) {
                node.size = Some(grid);
            }
        }
        let gone: Vec<_> = self
            .controllers
            .keys()
            .filter(|id| !nodes.iter().any(|n| n.id == **id))
            .copied()
            .collect();
        for id in gone {
            self.finish(io, id, Some(0));
        }
        self.ttys
            .retain(|id, _| nodes.iter().any(|node| node.id == *id));
        self.snapshot = snapshot;
        let modern = matches!(
            value.get("version").and_then(Value::string),
            Some("0.9.2" | "0.9.3")
        );
        if self.modern != modern {
            self.modern = modern;
            self.fallback = false;
        }
        // All supported servers expose cwd through snapshots without a change event.
        if self.safety.is_none() {
            let at = io.now() + Duration::from_secs(2);
            self.safety = Some(at);
            io.timer(at);
        }
        self.agents
            .retain(|id, _| nodes.iter().any(|node| node.id == *id));
        for node in &mut nodes {
            node.agent = self.agents.get(&node.id).cloned();
            node.tty = self.ttys.get(&node.id).copied();
        }
        self.retained(&mut nodes);
        if self.placements == 0 {
            self.notifications.push_back(Update::Topology {
                key: None,
                focus: self.graph.focus(&self.snapshot),
                backend: self.backend,
                nodes,
                layouts,
            });
        }
        for pane in field(value, "panes")?.array().into_iter().flatten() {
            let terminal = text(pane, "terminal_id")?;
            let Some(id) = self.graph.ids.get(&terminal).copied() else {
                continue;
            };
            let scroll = pane
                .get("scroll")
                .filter(|value| value.kind() != json::Kind::Null);
            let metrics = match scroll {
                None => Some((0, 0, 0)),
                Some(scroll) => scroll
                    .get("offset_from_bottom")
                    .and_then(Value::unsigned)
                    .zip(
                        scroll
                            .get("max_offset_from_bottom")
                            .and_then(Value::unsigned),
                    )
                    .zip(
                        scroll
                            .get("viewport_rows")
                            .and_then(Value::unsigned)
                            .and_then(|value| u32::try_from(value).ok()),
                    )
                    .map(|((offset, max), viewport)| (offset, max, viewport)),
            };
            if let Some((offset, max, viewport)) = metrics {
                self.notifications.push_back(Update::Scroll {
                    terminal: id,
                    offset,
                    max,
                    viewport,
                });
            }
        }
        self.deferred
            .push_back(Box::new(|mux, io| mux.discover(io)));
        io.timer(io.now());
        if self.subscription.is_some() && self.watched.as_ref() != Some(&self.watch()) {
            self.observe(io);
        }
        Ok(())
    }
    pub(super) fn refresh(&mut self, io: &mut dyn Io) {
        if self.refreshing {
            self.invalidated = true;
            return;
        }
        self.refreshing = true;
        self.call(
            io,
            "session.snapshot",
            D::Object(Vec::new()),
            Order::Normal,
            Box::new(|mux, io, result| {
                mux.refreshing = false;
                if let Ok(json) = result {
                    let _ = mux.apply(io, &json);
                } else {
                    let agents: Vec<_> = mux.agents.keys().copied()
                        .filter(|id| !mux.probes.contains(id)).collect();
                    for id in agents { mux.recheck(io, id); }
                }
                if std::mem::take(&mut mux.invalidated) {
                    mux.refresh(io);
                }
            }),
        );
    }
    pub(super) fn observe(&mut self, io: &mut dyn Io) {
        if self.observing {
            return;
        }
        self.observing = true;
        let watch = self.watch();
        let mut names = vec![
            "workspace.created",
            "workspace.updated",
            "workspace.renamed",
            "workspace.closed",
            "workspace.moved",
            "workspace.reordered",
            "workspace.focused",
            "tab.created",
            "tab.renamed",
            "tab.closed",
            "tab.moved",
            "tab.focused",
            "pane.created",
            "pane.closed",
            "pane.moved",
            "pane.focused",
            "layout.updated",
        ];
        if watch.0 {
            names.insert(2, "workspace.metadata_updated");
            let end = names.len() - 1;
            names.splice(
                end..end,
                ["pane.updated", "pane.exited", "pane.agent_detected"],
            );
        }
        let mut subscriptions: Vec<_> = names
            .into_iter()
            .map(|n| D::Object(vec![("type", D::String(n))]))
            .collect();
        let panes = watch.1.clone();
        for pane in &panes {
            for name in ["pane.agent_status_changed", "pane.scroll_changed"] {
                subscriptions.push(D::Object(vec![
                    ("type", D::String(name)),
                    ("pane_id", D::String(pane)),
                ]));
            }
        }
        self.call(
            io,
            "events.subscribe",
            D::Object(vec![("subscriptions", D::Array(subscriptions))]),
            Order::Normal,
            Box::new(move |mux, io, result| {
                mux.observing = false;
                if result.is_ok() {
                    mux.watched = Some(watch);
                    mux.retry = None;
                    mux.refresh(io);
                    if mux.watched.as_ref() != Some(&mux.watch()) {
                        mux.observe(io);
                    }
                } else if watch.0 && result.as_ref().err().is_some_and(|e| e.code == "schema") {
                    mux.fallback = true;
                    mux.observe(io);
                    mux.refresh(io);
                } else {
                    let at = io.now() + Duration::from_secs(1);
                    mux.retry = Some(at);
                    io.timer(at);
                    mux.refresh(io);
                }
            }),
        );
    }
    fn watch(&self) -> (bool, Vec<String>) {
        let modern = self.modern && !self.fallback;
        let panes = if modern {
            self.snapshot.panes.iter().map(|p| p.key.clone()).collect()
        } else {
            Vec::new()
        };
        (modern, panes)
    }
    pub(super) fn received(&mut self, io: &mut dyn Io, lines: Vec<Vec<u8>>, eof: bool) {
        let mut focused = false;
        for line in &lines {
            let Ok(json) = Json::parse(line) else {
                continue;
            };
            let event = json.root();
            let Some(level) = native::focus(event) else {
                continue;
            };
            let Some(data) = event.get("data") else {
                continue;
            };
            let mut selection = self.selection.clone();
            for (index, key) in ["workspace_id", "tab_id", "pane_id"].iter().enumerate() {
                if let Some(value) = data.get(key).and_then(Value::string) {
                    selection[index] = Some(value.to_owned());
                } else if index >= level {
                    selection[index] = None;
                }
            }
            if level == 2
                && let Some(pane) = self
                    .snapshot
                    .panes
                    .iter()
                    .find(|pane| selection[2].as_ref() == Some(&pane.key))
            {
                selection[1] = Some(pane.parent.clone());
            }
            if level >= 1
                && let Some(tab) = self
                    .snapshot
                    .tabs
                    .iter()
                    .find(|tab| selection[1].as_ref() == Some(&tab.key))
            {
                selection[0] = Some(tab.parent.clone());
            }
            self.selection = selection;
            focused = true;
        }
        if focused {
            self.snapshot.select(&self.selection);
            self.topology();
        }
        let lost = lines.iter().any(|line| {
            Json::parse(line).ok().is_some_and(|json| {
                json.root()
                    .get("error")
                    .and_then(|e| e.get("code"))
                    .and_then(Value::string)
                    == Some("events_lost")
            })
        });
        if lost || eof {
            if let Some(stream) = self.subscription.take() {
                stream.close(io);
            }
            if lost {
                self.observe(io);
            } else {
                let at = io.now() + Duration::from_secs(1);
                self.retry = Some(at);
                io.timer(at);
            }
        }
        if !lines.is_empty() || eof {
            self.changes = self.changes.wrapping_add(1);
            let now = io.now();
            self.ready(io, now, true);
            self.refresh(io);
        }
    }
    pub(super) fn mutation(&mut self, io: &mut dyn Io, method: &str, params: D<'_>, done: Action) {
        self.call(
            io,
            method,
            params,
            if self.continuation {
                Order::First
            } else {
                Order::Normal
            },
            Box::new(move |mux, io, result| {
                mux.reconcile(io, result, done);
            }),
        );
    }
    pub(super) fn reconcile(&mut self, io: &mut dyn Io, result: Result<Json, Error>, done: Action) {
        self.call(
            io,
            "session.snapshot",
            D::Object(Vec::new()),
            Order::First,
            Box::new(move |mux, io, state| {
                let state = state.and_then(|json| mux.apply(io, &json));
                let result = result.and_then(|json| {
                    state
                        .map(|_| json)
                        .map_err(|reason| native::delivery(reason, true))
                });
                done(mux, io, result);
            }),
        );
    }
    pub(super) fn locate(&self, id: Id) -> Result<(Kind, String), Error> {
        for w in &self.snapshot.workspaces {
            if self.graph.ids.get(&w.key) == Some(&id) {
                return Ok((Kind::Workspace, w.key.clone()));
            }
        }
        for t in &self.snapshot.tabs {
            if self.graph.ids.get(&t.key) == Some(&id) {
                return Ok((Kind::Tab, t.key.clone()));
            }
        }
        for p in &self.snapshot.panes {
            if self.graph.ids.get(&p.terminal) == Some(&id) {
                return Ok((Kind::Terminal, p.key.clone()));
            }
        }
        Err(expired("This herdr terminal is no longer available."))
    }
    pub(super) fn node(
        &mut self,
        io: &mut dyn Io,
        id: Id,
        op: &str,
        extra: Vec<(&str, D<'_>)>,
        done: Done<()>,
    ) {
        match self.locate(id) {
            Ok((kind, key)) => {
                let kind = match kind {
                    Kind::Workspace => "workspace",
                    Kind::Tab => "tab",
                    Kind::Terminal => "pane",
                };
                let mut params = vec![(
                    match kind {
                        "workspace" => "workspace_id",
                        "tab" => "tab_id",
                        _ => "pane_id",
                    },
                    D::String(&key),
                )];
                params.extend(extra);
                let restore = op == "move";
                let ending = op == "close";
                self.mutation(
                    io,
                    &format!("{kind}.{op}"),
                    D::Object(params),
                    Box::new(move |mux, io, r| {
                        let r = if ending { r } else { mux.locate(id).and(r) };
                        if restore && r.is_ok() {
                            mux.reveal(id);
                            mux.topology();
                        }
                        mux.defer(io, done, r.map(|_| ()));
                    }),
                );
            }
            Err(e) => self.defer(io, done, Err(e)),
        }
    }
    pub(super) fn job(&mut self, io: &mut dyn Io, job: Job, done: Completion) {
        match io.submit(job) {
            Ok(id) => {
                self.work.insert(id, done);
            }
            Err(e) => {
                self.deferred
                    .push_back(Box::new(move |mux, io| done(mux, io, Err(e))));
                io.timer(io.now());
            }
        }
    }
}
