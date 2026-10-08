use super::*;
use dispatch_helper4_core::system::queue::Queue;
use std::os::fd::RawFd;

struct Side {
    fd: RawFd,
    queue: Queue,
    eof: bool,
    ended: bool,
}
impl Side {
    fn new(fd: RawFd) -> Self {
        Self {
            fd,
            queue: Queue::new(transport::LIMIT),
            eof: false,
            ended: false,
        }
    }
    fn flush(&mut self, io: &mut dyn Io) -> Result<(), Error> {
        if let Some(bytes) = self.queue.front() {
            match io.write(self.fd, bytes) {
                Ok(0) => return Err(error("Herdr relay connection closed.")),
                Ok(count) => self
                    .queue
                    .consume(count)
                    .map_err(|reason| error(format!("{reason:?}")))?,
                Err(reason)
                    if matches!(
                        reason.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) => {}
                Err(reason) => return Err(error(reason.to_string())),
            }
        }
        Ok(())
    }
}
pub(super) struct Relay {
    listener: Option<RawFd>,
    path: PathBuf,
    server: Side,
    client: Option<Side>,
    candidate: Option<RawFd>,
    owner: Option<auth::Endpoint>,
    rejected: u8,
    verifying: bool,
    pub(super) deadline: Instant,
}
impl Relay {
    pub(super) fn new(io: &mut dyn Io, owner: &auth::Endpoint) -> Result<Self, Error> {
        let stem = owner
            .path
            .file_stem()
            .and_then(|name| name.to_str())
            .ok_or_else(|| error("Invalid herdr socket path."))?;
        let binary = owner.path.with_file_name(format!("{stem}-client.sock"));
        let server = io
            .connect(&Address::Unix(binary))
            .map_err(|reason| error(reason.to_string()))?;
        let opened = (|| {
            let mut bytes = [0; 8];
            io.random(&mut bytes)
                .map_err(|reason| error(reason.to_string()))?;
            let token = bytes
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>();
            let path = io
                .directory()
                .map_err(|reason| error(reason.to_string()))?
                .join(token);
            let listener = io
                .listen(&path)
                .map_err(|reason| error(reason.to_string()))?;
            Ok::<_, Error>((path, listener))
        })();
        let (path, listener) = match opened {
            Ok(value) => value,
            Err(reason) => {
                io.close(server);
                return Err(reason);
            }
        };
        Ok(Self {
            listener: Some(listener),
            path,
            server: Side::new(server),
            client: None,
            candidate: None,
            owner: None,
            rejected: 0,
            verifying: false,
            deadline: io.now() + Duration::from_secs(3),
        })
    }
    pub(super) fn path(&self) -> &std::path::Path {
        &self.path
    }
    pub(super) fn owns(&self, fd: RawFd) -> bool {
        self.listener == Some(fd)
            || self.server.fd == fd
            || self.client.as_ref().is_some_and(|side| side.fd == fd)
    }
    pub(super) fn expired(&self, at: Instant) -> bool {
        (self.client.is_none() || self.owner.is_none()) && self.deadline <= at
    }
    pub(super) fn close(self, io: &mut dyn Io) {
        for fd in [
            self.listener,
            Some(self.server.fd),
            self.client.map(|side| side.fd),
            self.candidate,
        ]
        .into_iter()
        .flatten()
        {
            io.close(fd);
        }
        let _ = io.submit(Job::Remove {
            path: self.path,
            expected: Expected::Any,
        });
    }
    fn interest(&mut self, io: &mut dyn Io) -> Result<(), Error> {
        if let Some(listener) = self.listener {
            io.interest(listener, self.candidate.is_none(), false)
                .map_err(|reason| error(reason.to_string()))?;
        }
        let ready = self.owner.is_some();
        if let Some(client) = &mut self.client {
            if self.server.eof && client.queue.front().is_none() && !client.ended {
                match io.shutdown(client.fd) {
                    Err(reason) if reason.kind() != io::ErrorKind::NotConnected => {
                        return Err(error(reason.to_string()));
                    }
                    _ => client.ended = true,
                }
            }
            if client.eof && self.server.queue.front().is_none() && !self.server.ended {
                match io.shutdown(self.server.fd) {
                    Err(reason) if reason.kind() != io::ErrorKind::NotConnected => {
                        return Err(error(reason.to_string()));
                    }
                    _ => self.server.ended = true,
                }
            }
            io.interest(
                client.fd,
                ready && !client.eof && self.server.queue.space() > 0,
                ready && client.queue.front().is_some(),
            )
            .map_err(|reason| error(reason.to_string()))?;
        }
        io.interest(
            self.server.fd,
            ready
                && !self.server.eof
                && self
                    .client
                    .as_ref()
                    .is_some_and(|side| side.queue.space() > 0),
            ready && !self.verifying && self.server.queue.front().is_some(),
        )
        .map_err(|reason| error(reason.to_string()))
    }
    fn read(&mut self, io: &mut dyn Io, fd: RawFd) -> Result<(), Error> {
        let Some(client) = &mut self.client else {
            return Ok(());
        };
        let (source, target) = if fd == client.fd {
            (client, &mut self.server)
        } else {
            (&mut self.server, client)
        };
        if source.eof || target.queue.space() == 0 || self.owner.is_none() {
            return Ok(());
        }
        let mut bytes = [0; 65536];
        let limit = bytes.len().min(target.queue.space());
        match io.read(fd, &mut bytes[..limit]) {
            Ok(0) => source.eof = true,
            Ok(count) => target
                .queue
                .push(bytes[..count].to_vec())
                .map_err(|reason| error(format!("{reason:?}")))?,
            Err(reason)
                if matches!(
                    reason.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) => {}
            Err(reason) => return Err(error(reason.to_string())),
        }
        Ok(())
    }
}

impl Herdr {
    pub(super) fn relay_setup(&mut self, io: &mut dyn Io, id: Id, json: auth::Endpoint) {
        let relay = self.controllers[&id].relay.as_ref().unwrap();
        let fd = relay.server.fd;
        let path = relay.path.clone();
        let stem = json.path.file_stem().unwrap().to_string_lossy();
        let binary = json.path.with_file_name(format!("{stem}-client.sock"));
        let scope = auth::Scope::native(binary, json.server.executable.clone(), self.config.uid);
        self.verify(
            io,
            Some(fd),
            scope,
            Box::new(move |mux, io, result| {
                if !mux
                    .controllers
                    .get(&id)
                    .and_then(|controller| controller.relay.as_ref())
                    .is_some_and(|relay| relay.server.fd == fd && relay.path == path)
                {
                    return;
                }
                let result = result.and_then(|(binary, _)| {
                    if !process::same(&binary.server, &json.server) {
                        return Err(error("Herdr binary socket belongs to another server."));
                    }
                    Ok(binary)
                });
                let binary = match result {
                    Ok(value) => value,
                    Err(reason) => {
                        mux.interrupt(io, id, reason);
                        return;
                    }
                };
                let scope = auth::Scope::endpoint(&json, mux.config.uid);
                mux.verify(
                    io,
                    None,
                    scope,
                    Box::new(move |mux, io, result| {
                        let Some(relay) = mux
                            .controllers
                            .get_mut(&id)
                            .and_then(|controller| controller.relay.as_mut())
                            .filter(|relay| relay.server.fd == fd && relay.path == path)
                        else {
                            return;
                        };
                        let result = result.and_then(|_| {
                            relay.owner = Some(binary);
                            relay.interest(io)
                        });
                        if let Err(reason) = result {
                            mux.interrupt(io, id, reason);
                        }
                    }),
                );
            }),
        );
    }
    pub(super) fn relay_event(
        &mut self,
        io: &mut dyn Io,
        fd: RawFd,
        read: bool,
        write: bool,
    ) -> bool {
        let Some(id) = self
            .controllers
            .iter()
            .find(|(_, controller)| {
                controller
                    .relay
                    .as_ref()
                    .is_some_and(|relay| relay.owns(fd))
            })
            .map(|(id, _)| *id)
        else {
            return false;
        };
        let relay = self
            .controllers
            .get_mut(&id)
            .unwrap()
            .relay
            .as_mut()
            .unwrap();
        if relay.listener == Some(fd) {
            match io.accept(fd) {
                Ok(candidate) => {
                    relay.candidate = Some(candidate);
                    let _ = io.interest(candidate, false, false);
                    let _ = relay.interest(io);
                    self.relay_peer(io, id, candidate);
                }
                Err(reason)
                    if matches!(
                        reason.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) => {}
                Err(reason) => self.interrupt(io, id, error(reason.to_string())),
            }
            return true;
        }
        let result = (|| {
            if read {
                relay.read(io, fd)?;
            }
            if write && let Some(client) = relay.client.as_mut().filter(|client| client.fd == fd) {
                client.flush(io)?;
            }
            relay.interest(io)
        })();
        if let Err(reason) = result {
            self.interrupt(io, id, reason);
            return true;
        }
        let relay = self
            .controllers
            .get_mut(&id)
            .unwrap()
            .relay
            .as_mut()
            .unwrap();
        if relay.server.queue.front().is_some()
            && !relay.verifying
            && let Some(owner) = relay.owner.clone()
        {
            relay.verifying = true;
            let fd = relay.server.fd;
            let path = relay.path.clone();
            let scope = auth::Scope::endpoint(&owner, self.config.uid);
            let _ = relay.interest(io);
            self.verify(
                io,
                Some(fd),
                scope,
                Box::new(move |mux, io, result| {
                    let Some(relay) = mux
                        .controllers
                        .get_mut(&id)
                        .and_then(|controller| controller.relay.as_mut())
                        .filter(|relay| relay.server.fd == fd && relay.path == path)
                    else {
                        return;
                    };
                    relay.verifying = false;
                    let result = result.and_then(|_| {
                        relay.server.flush(io)?;
                        relay.interest(io)
                    });
                    if let Err(reason) = result {
                        mux.interrupt(io, id, reason);
                    }
                }),
            );
        }
        true
    }
    fn relay_peer(&mut self, io: &mut dyn Io, id: Id, fd: RawFd) {
        let pid = self.controllers[&id].pid.unwrap();
        let path = self.controllers[&id].relay.as_ref().unwrap().path.clone();
        let uid = self.config.uid;
        let executable = self.owner.as_ref().unwrap().server.executable.clone();
        let input = json::write(&D::Object(vec![("fd", D::Signed(fd.into()))])).unwrap();
        self.job(
            io,
            Job::Native {
                name: "peer",
                input,
            },
            Box::new(move |mux, io, result| {
                let permitted = auth::document(result).is_ok_and(|json| {
                    json.root().get("uid").and_then(Value::unsigned) == Some(uid.into())
                        && json.root().get("pid").and_then(Value::unsigned) == Some(pid.into())
                });
                if !permitted {
                    mux.relay_client(io, id, fd, &path, false);
                    return;
                }
                let input =
                    json::write(&D::Object(vec![("pid", D::Unsigned(pid.into()))])).unwrap();
                mux.job(
                    io,
                    Job::Native {
                        name: "process",
                        input,
                    },
                    Box::new(move |mux, io, result| {
                        let permitted = auth::document(result)
                            .and_then(|json| process::read(json.root()))
                            .is_ok_and(|process| {
                                process.pid == pid && process.executable == executable
                            });
                        mux.relay_client(io, id, fd, &path, permitted);
                    }),
                );
            }),
        );
    }
    fn relay_client(
        &mut self,
        io: &mut dyn Io,
        id: Id,
        fd: RawFd,
        path: &std::path::Path,
        permitted: bool,
    ) {
        let Some(relay) = self
            .controllers
            .get_mut(&id)
            .and_then(|controller| controller.relay.as_mut())
            .filter(|relay| relay.candidate == Some(fd) && relay.path == path)
        else {
            // The retired relay already closed its candidate; this fd may be reused.
            return;
        };
        relay.candidate = None;
        if permitted {
            if let Some(listener) = relay.listener.take() {
                io.close(listener);
            }
            relay.client = Some(Side::new(fd));
        } else {
            io.close(fd);
            relay.rejected += 1;
            if relay.rejected >= 16 {
                self.interrupt(io, id, error("Herdr controller peer was rejected."));
                return;
            }
        }
        if let Err(reason) = relay.interest(io) {
            self.interrupt(io, id, reason);
        }
    }
}
