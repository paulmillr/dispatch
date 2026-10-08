use super::*;

impl Herdr {
    pub(super) fn dispatch(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) {
        self.bound(io);
        self.admission(io, &event);
        match event {
            event @ Event::Hook { .. } => self.hook(io, event),
            Event::Closed { reply } => {
                if let Some(Some(index)) = self.hooks.remove(&reply) {
                    let harness = self.harnesses[index].clone();
                    harness
                        .borrow_mut()
                        .event(io, self, Event::Closed { reply });
                }
            }

            Event::Timer { at } => {
                let expired: Vec<_> = self
                    .controllers
                    .iter()
                    .filter(|(_, controller)| {
                        controller
                            .relay
                            .as_ref()
                            .is_some_and(|relay| relay.expired(at))
                    })
                    .map(|(id, _)| *id)
                    .collect();
                for id in expired {
                    self.interrupt(io, id, error("Timed out waiting for the herdr controller."));
                }
                self.ready(io, at, false);
                if self.request.as_ref().is_some_and(|r| r.deadline <= at) {
                    self.fail(io, error("Herdr connection closed or timed out."));
                }
                if self.retry.is_some_and(|t| t <= at) {
                    self.retry = None;
                    self.observe(io);
                }
                if self.safety.is_some_and(|t| t <= at) {
                    self.refresh(io);
                    let at = io.now() + Duration::from_secs(2);
                    self.safety = Some(at);
                    io.timer(at);
                }
                let recovering: Vec<_> = self
                    .controllers
                    .iter()
                    .filter(|(_, c)| c.retry.is_some_and(|t| t <= at))
                    .map(|(id, c)| (*id, c.decoder.grid.unwrap()))
                    .collect();
                for (id, grid) in recovering {
                    let previous = self.controllers.remove(&id).unwrap();
                    if let Err(e) = self.controller(io, id, grid, false, false, None) {
                        let retry = io.now() + Duration::from_secs(1);
                        let mut controller = Controller::new(grid, false);
                        controller.retry = Some(retry);
                        self.controllers.insert(id, controller);
                        io.timer(retry);
                        let _ = e;
                    }
                    let controller = self.controllers.get_mut(&id).unwrap();
                    controller.pending = previous.pending;
                    controller.waiters = previous.waiters;
                }
                if let Some((pid, deadline, done)) = self.boot.take() {
                    match io.connect(&Address::Unix(self.config.socket.clone())) {
                        Ok(fd) => {
                            io.close(fd);
                            self.opening(io, "", Some(deadline), false, done);
                        }
                        Err(_) if io.now() < deadline => {
                            self.boot = Some((pid, deadline, done));
                            io.timer(io.now() + Duration::from_millis(50));
                        }
                        Err(_) => self.defer(
                            io,
                            done,
                            Err(error("Timed out waiting for the herdr server.")),
                        ),
                    }
                }
                self.pump(io);
            }
            Event::Done { work, result } => {
                if let Some(done) = self.work.remove(&work) {
                    done(self, io, result);
                }
            }
            Event::Ready { fd, read, write } if !self.relay_event(io, fd, read, write) => {
                if let Some(id) = self
                    .controllers
                    .iter()
                    .find(|(_, c)| c.stderr == Some(fd))
                    .map(|(id, _)| *id)
                {
                    let c = self.controllers.get_mut(&id).unwrap();
                    let mut bytes = [0; 4096];
                    if read {
                        match io.read(fd, &mut bytes) {
                            Ok(0) => {
                                io.close(fd);
                                c.stderr = None;
                            }
                            Ok(n) => {
                                if c.diagnostic.len() < 16384 {
                                    c.diagnostic.extend_from_slice(&bytes[..n]);
                                }
                            }
                            Err(e)
                                if matches!(
                                    e.kind(),
                                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                                ) => {}
                            Err(_) => {
                                io.close(fd);
                                c.stderr = None;
                            }
                        }
                    }
                } else if self.request.as_ref().is_some_and(|r| r.stream.output == fd && r.connecting.is_some()) {
                    self.connected(io);
                } else if self
                    .request
                    .as_ref()
                    .is_some_and(|r| r.stream.output == fd && r.verified)
                {
                    let result = {
                        let r = self.request.as_mut().unwrap();
                        if write && r.stream.queue.front().is_some() {
                            r.attempted |= native::mutation(&r.call.method);
                        }
                        if write { r.stream.flush(io) } else { Ok(()) }.and_then(|_| {
                            if read {
                                r.stream.read(io)
                            } else {
                                Ok((Vec::new(), false))
                            }
                        })
                    };
                    match result {
                        Ok((lines, eof)) => {
                            if let Some(line) = lines.first() {
                                let line = line.clone();
                                self.reply(io, &line, lines.into_iter().skip(1).collect(), eof);
                            } else if eof {
                                self.fail(io, error("Herdr connection closed or timed out."));
                            } else if self
                                .request
                                .as_ref()
                                .is_some_and(|request| request.stream.queue.front().is_some())
                            {
                                self.authorize(io, false);
                            }
                        }
                        Err(e) => {
                            self.fail(io, e);
                        }
                    }
                } else if self.subscription.as_ref().is_some_and(|s| s.output == fd) && read {
                    match self.subscription.as_mut().unwrap().read(io) {
                        Ok((lines, eof)) => self.received(io, lines, eof),
                        Err(_) => self.received(io, Vec::new(), true),
                    }
                } else if let Some(id) = self
                    .controllers
                    .iter()
                    .find(|(_, c)| {
                        c.stream
                            .as_ref()
                            .is_some_and(|s| s.input == fd || s.output == fd)
                    })
                    .map(|(id, _)| *id)
                {
                    let result = {
                        let stream = self
                            .controllers
                            .get_mut(&id)
                            .unwrap()
                            .stream
                            .as_mut()
                            .unwrap();
                        if write && stream.input == fd {
                            stream.flush(io)
                        } else {
                            Ok(())
                        }
                        .and_then(|_| {
                            if read && stream.output == fd {
                                stream.read(io)
                            } else {
                                Ok((Vec::new(), false))
                            }
                        })
                    };
                    match result {
                        Ok((lines, eof)) => {
                            for line in lines {
                                let result = Json::parse(&line).and_then(|json| {
                                    self.controllers
                                        .get_mut(&id)
                                        .unwrap()
                                        .decoder
                                        .frame(json.root())
                                });
                                match result {
                                    Ok(Some(bytes)) => {
                                        self.rediscover(io, id);
                                        self.notifications.push_back(Update::Output {
                                            terminal: id,
                                            bytes,
                                        });
                                        let c = self.controllers.get_mut(&id).unwrap();
                                        let waiters = std::mem::take(&mut c.waiters);
                                        let pending = std::mem::take(&mut c.pending);
                                        for done in waiters {
                                            self.defer(io, done, Ok(()));
                                        }
                                        if !pending.is_empty() {
                                            let _ = self.stream(io, id, &pending);
                                        }
                                    }
                                    Ok(None) => {}
                                    Err(e) => {
                                        self.interrupt(io, id, e);
                                        break;
                                    }
                                }
                            }
                            if eof && self.controllers.get(&id).is_some_and(|c| c.retry.is_none()) {
                                if let Some(fd) = self.controllers[&id].stderr {
                                    self.event(
                                        io,
                                        ui,
                                        Event::Ready {
                                            fd,
                                            read: true,
                                            write: false,
                                        },
                                    );
                                }
                                let reason = std::str::from_utf8(&self.controllers[&id].diagnostic)
                                    .unwrap_or("Connection ended.")
                                    .to_owned();
                                self.interrupt(io, id, error(reason));
                            }
                        }
                        Err(e) => self.interrupt(io, id, e),
                    }
                }
            }
            Event::Exit { pid, status } => {
                self.agents
                    .retain(|_, (_, binding)| binding.process.pid != pid);
                if self.boot.as_ref().is_some_and(|(p, _, _)| *p == pid) {
                    let (_, _, done) = self.boot.take().unwrap();
                    self.defer(
                        io,
                        done,
                        Err(error(format!(
                            "Herdr server could not start (exit {}).",
                            status.unwrap_or(-1)
                        ))),
                    );
                }
                if let Some(id) = self
                    .controllers
                    .iter()
                    .find(|(_, c)| c.pid == Some(pid) && c.retry.is_none())
                    .map(|(id, _)| *id)
                {
                    // Drain stdout before classifying the controller exit; a native closed frame owns that decision.
                    if let Some(fd) = self.controllers[&id].stream.as_ref().map(|s| s.output) {
                        self.event(
                            io,
                            ui,
                            Event::Ready {
                                fd,
                                read: true,
                                write: false,
                            },
                        );
                    }
                }
            }
            _ => {}
        }
        self.settle(io, ui);
        if self
            .calls
            .iter()
            .any(|call| (self.parked.is_none() && !self.preparing) || call.proof)
            && self.request.is_none()
            && !self.checking
        {
            io.timer(io.now());
        }
    }
    pub(super) fn settle(&mut self, io: &mut dyn Io, ui: &mut dyn Ui) {
        self.bound(io);
        for (index, event) in std::mem::take(&mut self.hookevents) {
            if let Event::Hook {
                reply: Some(reply), ..
            } = &event
                && !self.hooks.contains_key(reply)
            {
                continue;
            }
            self.harnesses[index].borrow_mut().event(io, ui, event);
        }
        self.flush(ui);
        for _ in 0.. {
            let Some(callback) = self.deferred.pop_front() else {
                break;
            };
            callback(self, io);
            self.bound(io);
            self.flush(ui);
        }
    }
    fn flush(&mut self, ui: &mut dyn Ui) {
        for update in self.notifications.drain(..) {
            ui.update(update);
        }
    }
}
