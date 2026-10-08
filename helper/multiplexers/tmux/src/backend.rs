use crate::ops::Location;
use crate::{
    client::Client,
    mux::{Continue, Tmux, allocate, error},
};
use dispatch_helper_core::api::*;
use std::{collections::BTreeMap, path::PathBuf, process::Command};

pub(crate) struct Backend {
    pub key: String,
    pub endpoint: Option<crate::endpoint::Endpoint>,
    pub clients: Vec<Client>,
    pub ids: BTreeMap<String, Id>,
    pub done: Vec<Continue<Result<Id, Error>>>,
    pub opening: usize,
    pub views: BTreeMap<Id, crate::retained::View>,
    pub selection: crate::retained::Selection,
    /// A borrowed stream not from a verified local tmux client (e.g. through ssh): its server's
    /// pids/paths are never local facts (c1654cc TmuxCoordinator.swift:661-668 localServer).
    pub remote: bool,
    /// A relayed server's identity as its own stream reports it: pid, start time, socket,
    /// session (core decision 'tmux C11'; old reattach-tmux verified the same server/session).
    pub identity: Option<String>,
    /// Creation intent survives transport loss and dismissal of its logical parent.
    pub pending: BTreeMap<String, crate::create::Pending>,
}
impl Backend {
    pub(crate) fn namespace(&self) -> String {
        self.endpoint.as_ref().map(crate::endpoint::Endpoint::identity)
            .or_else(|| self.identity.clone()).unwrap_or_else(|| self.key.clone())
    }

    /// A relayed stream that ended after its first model keeps its surfaces until the same
    /// server/session is claimed again (c1654cc TmuxCoordinator.swift:455-475).
    pub(crate) fn suspended(&self) -> bool {
        (self.remote || !self.pending.is_empty())
            && self.clients.iter().all(|client| client.ended)
            && self
                .clients
                .iter()
                .any(|client| client.snapshot.is_some() && (self.remote || !client.exited))
    }
}
impl Tmux {
    pub(crate) fn enable(&mut self, io: &mut dyn Io, enabled: bool, done: Done<()>) {
        if !enabled {
            let failure = crate::mux::gone("Tmux integration was disabled");
            let jobs = std::mem::take(&mut self.jobs);
            for (work, callback) in jobs {
                io.cancel(work);
                callback(self, io, Err(std::io::ErrorKind::NotConnected.into()));
            }
            for (_, mut window) in std::mem::take(&mut self.windows) {
                for fd in [window.child.input, window.child.output, window.child.stderr]
                    .into_iter()
                    .flatten()
                {
                    io.close(fd);
                }
                if let Some(callback) = window.done.take() {
                    callback(self, io, Err(failure.clone()));
                }
            }
            let mut replies = Vec::new();
            for backend in self.backends.values_mut() {
                for client in &mut backend.clients {
                    client.finish(io);
                    for notice in std::mem::take(&mut client.notices) {
                        if let crate::client::Notice::Reply(callback, result) = notice {
                            replies.push((callback, result));
                        }
                    }
                }
                for pending in backend.pending.values_mut() {
                    if let Some(callback) = pending.done.take() {
                        crate::mux::finish(io, callback, Err(failure.clone()));
                    }
                }
            }
            for (callback, result) in replies {
                callback(self, io, result);
            }
            for state in self.terminals.values_mut() {
                for callback in std::mem::take(&mut state.readers) {
                    crate::mux::finish(io, callback, Err(failure.clone()));
                }
                for callback in std::mem::take(&mut state.writers) {
                    crate::mux::finish(io, callback, Err(failure.clone()));
                }
            }
            for callback in std::mem::take(&mut self.published) {
                crate::mux::finish(io, callback, Err(failure.clone()));
            }
            let executable = self.executable.clone();
            let harnesses = std::mem::take(&mut self.harnesses);
            let next = self.next;
            *self = Self::new(executable);
            self.harnesses = harnesses;
            self.next = next;
        }
        crate::mux::finish(io, done, Ok(()));
    }
    pub(crate) fn adopt(
        &mut self,
        process: &Process,
        write: ControlWrite,
        remote: bool,
    ) -> ControlTarget {
        let key = format!("control:{}:{:?}", process.pid, process.start);
        let id = allocate(&mut self.next);
        self.backends.insert(
            id,
            Backend {
                key: key.clone(),
                endpoint: None,
                clients: vec![Client::adopt(write)],
                ids: BTreeMap::new(),
                done: Vec::new(),
                opening: 0,
                views: BTreeMap::new(),
                selection: crate::retained::Selection::default(),
                remote,
                identity: None,
                pending: BTreeMap::new(),
            },
        );
        ControlTarget { key, id }
    }
    pub(crate) fn native(&self, key: &str) -> Command {
        if let Some(endpoint) = self
            .backends
            .values()
            .find(|backend| backend.key == key)
            .and_then(|backend| backend.endpoint.as_ref())
        {
            let mut command = Command::new(&endpoint.executable);
            command
                .args(["-u", "-N", "-S"])
                .arg(&endpoint.path)
                .env_clear()
                .env("LC_ALL", "C");
            return command;
        }
        let mut command = Command::new(&self.executable);
        command.args(["-u", "-N"]).env_remove("TMUX");
        if key != "tmux" {
            command.args(["-S", key]);
        }
        command
    }
    pub(crate) fn controls(&self, process: &Process) -> bool {
        if process.executable != self.executable
            && process.executable.file_name() != Some(std::ffi::OsStr::new("tmux"))
        {
            return false;
        }
        let mut count = 0;
        let mut skip = false;
        for arg in process.arguments.iter().skip(1) {
            if skip {
                skip = false;
                continue;
            }
            if arg == "--" || !arg.starts_with('-') || arg == "-" {
                break;
            }
            let mut flags = arg[1..].chars().peekable();
            for flag in flags.by_ref() {
                if flag == 'C' {
                    count += 1;
                } else if "cfLST".contains(flag) {
                    skip = flags.peek().is_none();
                    break;
                } else if !"2DdhlNquUvV".contains(flag) {
                    return false;
                }
            }
        }
        count >= 2 && process.tty != 0 && process.group > 1 && process.foreground == process.group
    }
}

impl Tmux {
    /// The first model of a borrowed stream uses its verified endpoint identity, or the
    /// server start time for a pure relay. Continue an ended matching backend with this
    /// client (same node ids, dismissed panes, views). Otherwise this is a new backend.
    pub(crate) fn identify(
        &mut self,
        io: &mut dyn Io,
        location: Location,
        snapshot: crate::snapshot::Snapshot,
        cwd: BTreeMap<u32, PathBuf>,
        complete: Continue<Result<(crate::snapshot::Snapshot, BTreeMap<u32, PathBuf>), Error>>,
    ) {
        let server = snapshot.server;
        let socket = snapshot.socket.clone();
        let session = snapshot.session;
        let endpoint = self.backends[&location.backend].endpoint.clone();
        let local = endpoint.map(|endpoint| format!("{}|{}", endpoint.identity(), snapshot.session));
        let complete: Continue<Result<String, Error>> = Box::new(move |mux, io, identity| {
            let identity = match identity {
                Ok(identity) => identity,
                Err(error) => return complete(mux, io, Err(error)),
            };
            let earlier = mux
                .backends
                .iter()
                .find(|(id, backend)| {
                    **id != location.backend
                        && backend.clients.iter().all(|client| client.ended)
                        && backend
                            .clients
                            .iter()
                            .any(|client| client.snapshot.is_some())
                        && backend.remote == mux.backends[&location.backend].remote
                        && backend.identity.as_deref() == Some(identity.as_str())
                })
                .map(|(id, _)| *id);
            let Some(earlier) = earlier else {
                mux.backends.get_mut(&location.backend).unwrap().identity = Some(identity);
                return complete(mux, io, Ok((snapshot, cwd)));
            };
            let mut adopted = mux.backends.remove(&location.backend).unwrap();
            let mut client = adopted.clients.remove(location.client);
            let backend = mux.backends.get_mut(&earlier).unwrap();
            let slot = backend
                .clients
                .iter()
                .position(|old| {
                    old.snapshot
                        .as_ref()
                        .is_some_and(|old| old.session == snapshot.session)
                })
                .unwrap();
            client.dismissed = std::mem::take(&mut backend.clients[slot].dismissed);
            // The new client's refresh state belongs to the read that just completed.
            client.refreshing = false;
            backend.clients[slot] = client;
            backend.done.append(&mut adopted.done);
            for alias in mux
                .aliases
                .values_mut()
                .filter(|(id, _)| *id == location.backend)
            {
                alias.0 = earlier;
            }
            mux.aliases.insert(location.backend, (earlier, adopted.key));
            let location = Location {
                backend: earlier,
                client: slot,
                pane: 0,
            };
            // That read was for the removed backend; the continued one reads again,
            // then answers the creations the loss held.
            drop(complete);
            mux.refresh(
                io,
                location,
                Some(Box::new(move |mux, io, result| {
                    if result.is_ok() {
                        mux.resolve_held(io, location);
                    }
                })),
            );
        });
        if let Some(identity) = local {
            complete(self, io, Ok(identity));
        } else {
            // A relay has no process/socket authority. Its initial start time must be
            // saved before loss; a reconnect-only query cannot detect PID reuse.
            self.request(
                io,
                location,
                vec!["display-message -p '#{start_time}'".into()],
                Box::new(move |mux, io, result| {
                    let identity = result.and_then(|rows| {
                        let line = rows[0].text();
                        if line.is_empty() || !line.iter().all(u8::is_ascii_digit) {
                            return Err(error("Invalid tmux server start time"));
                        }
                        Ok(format!(
                            "{}|{}|{}|{}",
                            server,
                            String::from_utf8_lossy(line),
                            socket,
                            session
                        ))
                    });
                    complete(mux, io, identity);
                }),
            );
        }
    }
}
