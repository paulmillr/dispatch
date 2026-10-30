use super::*;

impl Controller {
    pub(super) fn new(grid: Grid, initial: bool) -> Self {
        let mut decoder = Decoder::default();
        decoder.resize(grid);
        Self {
            relay: None,
            pid: None,
            stream: None,
            stderr: None,
            diagnostic: Vec::new(),
            decoder,
            initial,
            pending: Vec::new(),
            waiters: Vec::new(),
            retry: None,
            restores: Vec::new(),
        }
    }
    pub(super) fn close(&mut self, io: &mut dyn Io, reason: Error) {
        if let Some(relay) = self.relay.take() {
            relay.close(io);
        }
        if let Some(stream) = self.stream.take() {
            stream.close(io);
        }
        if let Some(fd) = self.stderr.take() {
            io.close(fd);
        }
        if let Some(pid) = self.pid.take() {
            let _ = io.terminate(pid);
        }
        for done in self.waiters.drain(..) {
            let reason = reason.clone();
            io.defer(Box::new(move |io| done(io, Err(reason))));
        }
        for (_, done) in self.restores.drain(..) {
            let reason = reason.clone();
            io.defer(Box::new(move |io| done(io, Err(reason))));
        }
    }
    pub(super) fn resize(&mut self, io: &mut dyn Io, size: Grid) -> Result<(), Error> {
        if !native::size(size) {
            return Err(error("Invalid herdr terminal size."));
        }
        self.decoder.resize(size);
        if let Some(stream) = &mut self.stream {
            let mut fields = vec![
                ("type", D::String("terminal.resize")),
                ("cols", D::Unsigned(size.columns.into())),
                ("rows", D::Unsigned(size.rows.into())),
            ];
            if let Some((width, height)) = size.pixels {
                fields.push(("cell_width_px", D::Unsigned(width.into())));
                fields.push(("cell_height_px", D::Unsigned(height.into())));
            }
            json::write(&D::Object(fields)).and_then(|bytes| stream.send(io, bytes))
        } else {
            Ok(())
        }
    }
}

/// A started `herdr terminal session` process (Herdr::session).
pub(super) struct Session {
    pub(super) owner: auth::Endpoint,
    pub(super) relay: relay::Relay,
    pub(super) pid: u32,
    pub(super) input: std::os::fd::RawFd,
    pub(super) output: std::os::fd::RawFd,
    pub(super) stderr: Option<std::os::fd::RawFd>,
}

impl Herdr {
    pub(super) fn controller(
        &mut self,
        io: &mut dyn Io,
        id: Id,
        grid: Grid,
        initial: bool,
        takeover: bool,
        done: Option<Done<()>>,
    ) -> Result<(), Error> {
        if !native::size(grid) {
            return Err(error("Invalid herdr terminal size."));
        }
        let columns = grid.columns.max(1).to_string();
        let rows = grid.rows.max(1).to_string();
        let mut arguments = vec!["control", "--cols", &columns, "--rows", &rows];
        if takeover {
            arguments.push("--takeover");
        }
        let Session { owner, relay, pid, input, output, stderr } = self.session(io, id, &arguments)?;
        let deadline = relay.deadline;
        let mut controller = self
            .controllers
            .remove(&id)
            .unwrap_or_else(|| Controller::new(grid, initial));
        controller.pid = Some(pid);
        controller.stream = Some(Stream::new(input, output));
        controller.stderr = stderr;
        controller.relay = Some(relay);
        if grid.pixels.is_some() {
            if let Err(reason) = controller.resize(io, grid) {
                controller.close(io, reason.clone());
                return Err(reason);
            }
        }
        controller.waiters.extend(done);
        self.controllers.insert(id, controller);
        self.relay_setup(io, relay::Holder::Controller(id), owner);
        io.timer(deadline);
        Ok(())
    }
    /// `herdr terminal session <mode> <terminal key> <arguments>` with its stdio piped and its client socket
    /// connection relayed through a verified relay (relay.rs); the caller sets the relay up once it holds it.
    pub(super) fn session(&mut self, io: &mut dyn Io, id: Id, arguments: &[&str]) -> Result<Session, Error> {
        let mut terminals = self
            .snapshot
            .panes
            .iter()
            .filter(|p| self.graph.ids.get(&p.terminal) == Some(&id));
        let key = terminals
            .next()
            .map(|p| p.terminal.clone())
            .ok_or_else(|| expired("This herdr terminal is no longer available."))?;
        if terminals.next().is_some() {
            return Err(error("Herdr terminal identity is ambiguous."));
        }
        let owner = self
            .owner
            .as_ref()
            .ok_or_else(|| error("Herdr server identity is unavailable."))?
            .clone();
        let relay = relay::Relay::new(io, &owner)?;
        let executable = &owner.server.executable;
        let mut command = Command::new(executable);
        command.args(["terminal", "session", arguments[0], &key]);
        command.args(&arguments[1..]);
        command
            .env_clear()
            .envs(client::environment(&self.config.environment, false))
            .env("HERDR_CLIENT_SOCKET_PATH", relay.path())
            .env_remove("HERDR_ENV")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let child = match io.spawn(command, None) {
            Ok(child) => child,
            Err(reason) => {
                relay.close(io);
                return Err(error(reason.to_string()));
            }
        };
        let (input, output) = match (child.input, child.output) {
            (Some(input), Some(output)) => (input, output),
            _ => {
                for fd in [child.input, child.output, child.stderr]
                    .into_iter()
                    .flatten()
                {
                    io.close(fd);
                }
                let _ = io.terminate(child.pid);
                relay.close(io);
                return Err(error("Herdr controller pipes are unavailable."));
            }
        };
        if let Err(e) = io
            .child(child.pid)
            .and_then(|_| io.interest(output, true, false))
            .and_then(|_| {
                child
                    .stderr
                    .map_or(Ok(()), |fd| io.interest(fd, true, false))
            })
        {
            io.close(input);
            io.close(output);
            if let Some(fd) = child.stderr {
                io.close(fd);
            }
            let _ = io.terminate(child.pid);
            relay.close(io);
            return Err(error(e.to_string()));
        }
        Ok(Session { owner, relay, pid: child.pid, input, output, stderr: child.stderr })
    }
    pub(super) fn finish(&mut self, io: &mut dyn Io, id: Id, status: Option<i32>) {
        self.agents.remove(&id);
        if let Some(mut controller) = self.controllers.remove(&id) {
            controller.close(io, expired("Herdr terminal closed."));
            self.notifications.push_back(Update::Output {
                terminal: id,
                bytes: b"\x1b[?7h\x1b[?1049l".to_vec(),
            });
            self.notifications.push_back(Update::Exit {
                terminal: id,
                status,
            });
        }
        self.screens
            .close(io, id, expired("Herdr terminal closed."));
    }
    pub(super) fn interrupt(&mut self, io: &mut dyn Io, id: Id, reason: Error) {
        if reason.code == "closed" {
            self.finish(io, id, Some(0));
            self.refresh(io);
            return;
        }
        let Some(c) = self.controllers.get_mut(&id) else {
            return;
        };
        // Reconnecting retires the transport, not the pending attachment or repaints: the new session's first frame
        // is a full one.
        let waiters = std::mem::take(&mut c.waiters);
        let restores = std::mem::take(&mut c.restores);
        c.close(io, reason.clone());
        c.waiters = waiters;
        c.restores = restores;
        c.initial = false;
        c.decoder.sequence = None;
        let safe: String = reason.message.chars().filter(|c| !c.is_control()).collect();
        self.notifications.push_back(Update::Output {
            terminal: id,
            bytes: format!(
                "\x1b[0m\x1b[?25h\x1b[H\x1b[2JHerdr disconnected: {safe}\r\nReconnecting…"
            )
            .into_bytes(),
        });
        let at = io.now() + Duration::from_secs(1);
        c.retry = Some(at);
        io.timer(at);
    }
    /// One observer's repaint (terminals.follow): herdr answers every `terminal.resize`, to the size it has too, with a
    /// full frame (a reattach relies on it), so the controller asks for its own size again; a controller still starting
    /// or reconnecting starts with a full frame anyway. Every observer gets that frame (a full frame is how herdr sends
    /// that change, and repaints what they show alike); the asking one gets it as `Update::Restore`, after which the
    /// frames that follow apply.
    pub(super) fn follow_restore(&mut self, io: &mut dyn Io, id: Id, token: u64, done: Done<()>) {
        let Some(c) = self.controllers.get_mut(&id) else {
            let result = self.locate(id).and(Err(error("Herdr terminal is not attached.")));
            self.defer(io, done, result);
            return;
        };
        let result = match (c.stream.is_some(), c.decoder.grid) {
            (true, Some(grid)) => c.resize(io, grid),
            _ => Ok(()),
        };
        match result {
            Ok(()) => c.restores.push((token, done)),
            Err(reason) => self.defer(io, done, Err(reason)),
        }
    }
    pub(super) fn stream(&mut self, io: &mut dyn Io, id: Id, value: &[u8]) -> Result<(), Error> {
        if value.len() > 262_144 {
            return Err(error("Herdr terminal input exceeded the size limit."));
        }
        if !self.controllers.contains_key(&id) {
            return self
                .locate(id)
                .and(Err(error("Herdr terminal is not attached.")));
        }
        let c = self.controllers.get_mut(&id).unwrap();
        c.stream
            .as_mut()
            .ok_or_else(|| error("Herdr terminal is disconnected."))?
            .send(
                io,
                json::write(&D::Object(vec![
                    ("type", D::String("terminal.input")),
                    ("bytes", D::String(&native::encode(value))),
                ]))?,
            )
    }
}

#[cfg(test)]
#[path = "controller.test.rs"]
mod tests;
