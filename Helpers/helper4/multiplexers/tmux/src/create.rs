use crate::{
    commands,
    mux::{Tmux, allocate, error, finish, gone},
    ops::Location,
};
use dispatch_helper4_core::api::*;
use std::process::Command;

pub(crate) struct Pending {
    pub parent: Id,
    pub hidden: bool,
    pub view: Option<Id>,
    pub done: Option<Done<Id>>,
}
impl Tmux {
    pub(crate) fn create(
        &mut self,
        io: &mut dyn Io,
        parent: Id,
        beside: Option<Id>,
        command: Option<Command>,
        done: Done<Id>,
    ) {
        let prepared = (|| {
            let new_group = self.backends.contains_key(&parent);
            let (loc, target) = if new_group {
                let back = &self.backends[&parent];
                let sessions: Vec<_> = back
                    .clients
                    .iter()
                    .enumerate()
                    .filter(|(_, client)| client.live() && client.snapshot.is_some())
                    .collect();
                if sessions.len() != 1 {
                    return Err(error("Tmux creation needs an unambiguous session"));
                }
                let (client, state) = sessions[0];
                (
                    Location {
                        backend: parent,
                        client,
                        pane: 0,
                    },
                    format!("${}", state.snapshot.as_ref().unwrap().session),
                )
            } else {
                self.target(parent)?
            };
            let snapshot = self.backends[&loc.backend].clients[loc.client]
                .snapshot
                .as_ref()
                .unwrap();
            let split = beside.is_some() || !target.starts_with('$');
            let pane = if let Some(beside) = beside {
                let other = self.location(beside)?;
                if other.backend != loc.backend || other.client != loc.client {
                    return Err(error("Tmux creation target changed"));
                }
                other.pane
            } else if target.starts_with('%') {
                crate::snapshot::id(&target, '%')? as u32
            } else {
                snapshot
                    .windows
                    .iter()
                    .find(|w| {
                        if target.starts_with('@') {
                            target == format!("@{}", w.id)
                        } else {
                            self.selected(loc, parent).map_or(w.active, |id| w.id == id)
                        }
                    })
                    .ok_or_else(|| gone("Tmux window closed"))?
                    .pane
            };
            let window = snapshot
                .windows
                .iter()
                .find(|w| w.layout.pane(pane).is_some())
                .ok_or_else(|| gone("Tmux pane closed"))?;
            if target.starts_with('@') && target != format!("@{}", window.id) {
                return Err(error("Tmux creation target changed"));
            }
            let creation = crate::affinity::uuid(io)?;
            let mut affinity = None;
            if !split {
                let mut value = if new_group {
                    crate::affinity::Affinity {
                        group: crate::affinity::uuid(io)?,
                        name: snapshot.name.clone(),
                        order: 0,
                        directory: Some(true),
                        creation: None,
                    }
                } else {
                    let group = &self.affinity(loc, window.id).group;
                    let members = self.members(loc, group);
                    let mut value = self.affinity(loc, members[0]).clone();
                    value.name = self.name(loc, members[0]);
                    value.directory = Some(value.directory.unwrap_or(false));
                    value.order = members
                        .iter()
                        .map(|window| self.affinity(loc, *window).order)
                        .max()
                        .unwrap()
                        + 1;
                    value
                };
                value.creation = Some(creation.clone());
                affinity = Some(value.encode()?);
            }
            Ok((
                Location { pane, ..loc },
                window.id,
                split,
                creation,
                affinity,
            ))
        })();
        let (loc, window, split, creation, affinity) = match prepared {
            Ok(value) => value,
            Err(e) => {
                finish(io, done, Err(e));
                return;
            }
        };
        self.backends.get_mut(&loc.backend).unwrap().clients[loc.client].creating += 1;
        self.backends.get_mut(&loc.backend).unwrap().pending.insert(
            creation.clone(),
            Pending {
                parent,
                hidden: false,
                view: None,
                done: None,
            },
        );
        let query = format!(
            "display-message -p -t %{} \"#{{pane_current_path}}\"",
            loc.pane
        );
        self.request(
            io,
            loc,
            vec![query],
            Box::new(move |mux, io, result| {
                let request = (|| {
                    let rows = result?;
                    let current = String::from_utf8(rows[0].text().to_vec()).map_err(error)?;
                    let cwd = command
                        .as_ref()
                        .and_then(|c| c.get_current_dir())
                        .map(|p| {
                            p.to_str()
                                .ok_or_else(|| error("Invalid tmux launch directory"))
                        })
                        .transpose()?
                        .unwrap_or(&current);
                    let mut request: Vec<(String, bool)> = if split {
                        vec![
                            ("split-window".into(), false),
                            ("-h".into(), false),
                            ("-t".into(), false),
                            (format!("%{}", loc.pane), false),
                        ]
                    } else {
                        vec![
                            ("new-window".into(), false),
                            ("-a".into(), false),
                            ("-t".into(), false),
                            (format!("@{window}"), false),
                        ]
                    };
                    request.extend([
                        ("-P".into(), false),
                        ("-F".into(), false),
                        ("#{pane_id}".into(), true),
                    ]);
                    if !cwd.is_empty() {
                        request.extend([("-c".into(), false), (cwd.replace('#', "##"), true)]);
                    }
                    request.extend([
                        ("-e".into(), false),
                        (format!("DISPATCH_TMUX_CREATION={creation}"), true),
                    ]);
                    if let Some(command) = &command {
                        for (name, value) in command.get_envs() {
                            if let Some(value) = value {
                                let name = name
                                    .to_str()
                                    .ok_or_else(|| error("Invalid tmux launch environment"))?;
                                let value = value
                                    .to_str()
                                    .ok_or_else(|| error("Invalid tmux launch environment"))?;
                                request.extend([
                                    ("-e".into(), false),
                                    (format!("{name}={value}"), true),
                                ]);
                            }
                        }
                        request.extend([("--".into(), false), ("env".into(), false)]);
                        for (name, value) in command.get_envs() {
                            if value.is_none() {
                                request.extend([
                                    ("-u".into(), false),
                                    (
                                        name.to_str()
                                            .ok_or_else(|| {
                                                error("Invalid tmux launch environment")
                                            })?
                                            .into(),
                                        true,
                                    ),
                                ]);
                            }
                        }
                        for arg in std::iter::once(command.get_program()).chain(command.get_args())
                        {
                            request.push((
                                arg.to_str()
                                    .ok_or_else(|| error("Invalid tmux launch argument"))?
                                    .into(),
                                true,
                            ));
                        }
                    }
                    Ok(request)
                })();
                let request = match request {
                    Ok(value) => value,
                    Err(e) => {
                        mux.settle(io, loc, None);
                        mux.backends
                            .get_mut(&loc.backend)
                            .unwrap()
                            .pending
                            .remove(&creation);
                        finish(io, done, Err(e));
                        return;
                    }
                };
                let held = creation.clone();
                let mut commands = vec![
                    request
                        .iter()
                        .map(|(arg, literal)| {
                            if *literal {
                                commands::quote(arg)
                            } else {
                                arg.clone()
                            }
                        })
                        .collect::<Vec<_>>()
                        .join(" "),
                    format!(
                        "set-option -p @dispatch-creation {}",
                        commands::quote(&creation)
                    ),
                ];
                if let Some(affinity) = &affinity {
                    commands.push(format!(
                        "set-option -w @dispatch-window {}",
                        commands::quote(&affinity)
                    ));
                }
                mux.window(
                    io,
                    loc,
                    commands,
                    request.into_iter().map(|(arg, _)| arg).collect(),
                    creation.clone(),
                    affinity,
                    Box::new(move |mux, io, result| {
                        let pane = result.and_then(|rows| {
                            let text = std::str::from_utf8(
                                rows[0]
                                    .iter()
                                    .next()
                                    .ok_or_else(|| error("Missing created tmux pane"))?,
                            )
                            .map_err(error)?;
                            crate::snapshot::id(text, '%').map(|p| p as u32)
                        });
                        let pane = match pane {
                            Ok(pane) => pane,
                            Err(e) => {
                                mux.settle(io, loc, None);
                                mux.hold(io, loc, held, done, e);
                                return;
                            }
                        };
                        mux.refresh(
                            io,
                            loc,
                            Some(Box::new(move |mux, io, result| {
                                let result = result.and_then(|_| {
                                    let backend = mux.backends.get_mut(&loc.backend).unwrap();
                                    let snapshot =
                                        backend.clients[loc.client].snapshot.as_ref().unwrap();
                                    if !snapshot.panes.contains_key(&pane) {
                                        return Err(error("Created tmux pane is unavailable"));
                                    }
                                    Ok(mux.created(loc, &held, pane))
                                });
                                mux.settle(io, loc, result.is_ok().then_some(pane));
                                match result {
                                    Ok(id) => finish(io, done, Ok(id)),
                                    Err(e) => mux.hold(io, loc, held, done, e),
                                }
                            })),
                        );
                    }),
                );
            }),
        );
    }
    /// A creation whose answer a relayed transport lost waits for the same server's
    /// re-claim (decision D1); any other failure answers now.
    fn hold(&mut self, io: &mut dyn Io, loc: Location, creation: String, done: Done<Id>, e: Error) {
        let backend = self.backends.get_mut(&loc.backend).unwrap();
        let client = &backend.clients[loc.client];
        if client.ended && !client.exited {
            backend.pending.get_mut(&creation).unwrap().done = Some(done);
        } else {
            backend.pending.remove(&creation);
            finish(io, done, Err(e));
        }
    }
    /// Both normal completion and re-claim apply the same remembered/forgotten intent.
    fn created(&mut self, loc: Location, creation: &str, pane: u32) -> Id {
        let backend = self.backends.get_mut(&loc.backend).unwrap();
        let pending = backend.pending.remove(creation).unwrap();
        let client = &mut backend.clients[loc.client];
        let session = client.snapshot.as_ref().unwrap().session;
        let id = *backend
            .ids
            .entry(format!("${session}:%{pane}"))
            .or_insert_with(|| allocate(&mut self.next));
        if pending.hidden {
            client.dismissed.insert(pane);
            if let Some(view) = pending.view.and_then(|id| backend.views.get_mut(&id)) {
                view.panes.insert(pane);
            }
            self.changed = true;
        }
        id
    }
    /// The re-claim's first model: each held creation is the pane carrying its
    /// @dispatch-creation (it survives the window option's removal), or it never happened.
    pub(crate) fn resolve_held(&mut self, io: &mut dyn Io, loc: Location) {
        let held: Vec<_> = self
            .backends
            .get_mut(&loc.backend)
            .unwrap()
            .pending
            .iter_mut()
            .filter_map(|(creation, pending)| {
                pending.done.take().map(|done| (creation.clone(), done))
            })
            .collect();
        if held.is_empty() {
            return;
        }
        let query = if self.backends[&loc.backend].remote {
            "list-panes -a -F \"#{pane_id}|#{session_id}|#{@dispatch-creation}\""
        } else {
            "list-panes -a -F \"#{pane_id}|#{session_id}|#{@dispatch-creation}|#{pane_pid}\""
        };
        self.request(
            io,
            loc,
            vec![query.into()],
            Box::new(move |mux, io, result| {
                let Ok(rows) = result else {
                    // Not read: they keep waiting for the next model.
                    for (creation, done) in held {
                        mux.backends
                            .get_mut(&loc.backend)
                            .unwrap()
                            .pending
                            .get_mut(&creation)
                            .unwrap()
                            .done = Some(done);
                    }
                    return;
                };
                let panes: Vec<(String, String, String, u32)> = rows[0]
                    .iter()
                    .filter_map(|row| {
                        let text = String::from_utf8_lossy(row);
                        let mut fields = text.splitn(4, '|');
                        Some((
                            fields.next()?.to_owned(),
                            fields.next()?.to_owned(),
                            fields.next()?.to_owned(),
                            fields.next().and_then(|pid| pid.parse().ok()).unwrap_or(0),
                        ))
                    })
                    .collect();
                mux.creations(io, loc, panes, held, 0);
            }),
        );
    }

    fn creations(
        &mut self,
        io: &mut dyn Io,
        loc: Location,
        mut panes: Vec<(String, String, String, u32)>,
        held: Vec<(String, Done<Id>)>,
        offset: usize,
    ) {
        if !self.backends[&loc.backend].remote && offset < panes.len() {
            if panes[offset].2.is_empty() {
                let input = dispatch_helper4_core::json::write(
                    &dispatch_helper4_core::json::Data::Object(vec![
                        (
                            "pid",
                            dispatch_helper4_core::json::Data::Unsigned(panes[offset].3.into()),
                        ),
                        (
                            "names",
                            dispatch_helper4_core::json::Data::Array(vec![
                                dispatch_helper4_core::json::Data::String("DISPATCH_TMUX_CREATION"),
                            ]),
                        ),
                    ]),
                )
                .unwrap();
                self.job(
                    io,
                    Job::Native {
                        name: "environment",
                        input,
                    },
                    Box::new(move |mux, io, result| {
                        if let Ok(Output::Bytes(bytes)) = result {
                            if let Ok(value) = dispatch_helper4_core::json::Json::parse(&bytes) {
                                if let Some(id) = value
                                    .root()
                                    .get("DISPATCH_TMUX_CREATION")
                                    .and_then(|value| value.string())
                                {
                                    panes[offset].2 = id.to_owned();
                                }
                            }
                        }
                        mux.creations(io, loc, panes, held, offset + 1);
                    }),
                );
                return;
            }
            self.creations(io, loc, panes, held, offset + 1);
            return;
        }
        for (creation, done) in held {
            let Some((pane, session, _, _)) = panes.iter().find(|(_, _, c, _)| *c == creation)
            else {
                self.backends
                    .get_mut(&loc.backend)
                    .unwrap()
                    .pending
                    .remove(&creation);
                let error = if self.backends[&loc.backend].remote {
                    Error {
                        code: "uncertain",
                        message: "Tmux creation could not be identified".into(),
                    }
                } else {
                    error("Tmux window was not created")
                };
                finish(io, done, Err(error));
                continue;
            };
            let parsed = crate::snapshot::id(pane, '%').and_then(|pane| {
                let client = &self.backends[&loc.backend].clients[loc.client];
                let snapshot = client.snapshot.as_ref().unwrap();
                if session != &format!("${}", snapshot.session)
                    || !snapshot.panes.contains_key(&(pane as u32))
                {
                    return Err(error("Created tmux pane is unavailable"));
                }
                Ok(pane as u32)
            });
            let pane = match parsed {
                Ok(pane) => pane,
                Err(error) => {
                    self.backends
                        .get_mut(&loc.backend)
                        .unwrap()
                        .pending
                        .remove(&creation);
                    finish(io, done, Err(error));
                    continue;
                }
            };
            let id = self.created(loc, &creation, pane);
            // Answered once the topology listing it went to the app.
            self.changed = true;
            self.published
                .push(Box::new(move |io, _| finish(io, done, Ok(id))));
        }
    }
}

/// A normal native creation client yields its pane line while user hooks still run.
/// Keep draining its pipes after completion, just as the old worker did.
pub(crate) struct Window {
    pub(crate) child: Spawned,
    bytes: Vec<u8>,
    pub(crate) done: Option<crate::mux::NativeDone>,
}
impl Tmux {
    fn window(
        &mut self,
        io: &mut dyn Io,
        loc: Location,
        commands: Vec<String>,
        arguments: Vec<String>,
        marker: String,
        affinity: Option<String>,
        done: crate::mux::NativeDone,
    ) {
        if self.backends[&loc.backend].remote {
            self.request(io, loc, commands, done);
            return;
        }
        self.verify(
            io,
            loc,
            Box::new(move |mux, io, result| {
                if let Err(e) = result {
                    done(mux, io, Err(e));
                    return;
                }
                if !mux.backends[&loc.backend].clients[loc.client].live() {
                    done(mux, io, Err(gone("Tmux control connection closed")));
                    return;
                }
                mux.window_native(io, loc, arguments, marker, affinity, done);
            }),
        );
    }
    fn verify(
        &mut self,
        io: &mut dyn Io,
        loc: Location,
        done: crate::mux::Continue<Result<(), Error>>,
    ) {
        let Some(endpoint) = self.backends[&loc.backend].endpoint.clone() else {
            done(self, io, Err(error("Local tmux endpoint is unavailable")));
            return;
        };
        self.endpoint(
            io,
            endpoint.path.to_string_lossy().into_owned(),
            Some(endpoint),
            None,
            Box::new(move |mux, io, result| done(mux, io, result.map(|_| ()))),
        );
    }
    fn window_native(
        &mut self,
        io: &mut dyn Io,
        loc: Location,
        arguments: Vec<String>,
        marker: String,
        affinity: Option<String>,
        done: crate::mux::NativeDone,
    ) {
        let mut command = self.native(&self.backends[&loc.backend].key);
        command
            .args(arguments)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        let spawned = (|| {
            let mut child = io.spawn(command, None).map_err(error)?;
            if let Some(fd) = child.input.take() {
                io.close(fd);
            }
            for fd in [child.output, child.stderr].into_iter().flatten() {
                if let Err(e) = io.interest(fd, true, false) {
                    for fd in [child.output, child.stderr].into_iter().flatten() {
                        io.close(fd);
                    }
                    return Err(error(e));
                }
            }
            Ok(child)
        })();
        let child = match spawned {
            Ok(child) => child,
            Err(e) => {
                done(self, io, Err(e));
                return;
            }
        };
        let complete = Box::new(
            move |mux: &mut Tmux, io: &mut dyn Io, result: Result<crate::client::Batch, Error>| {
                let rows = match result {
                    Ok(rows) => rows,
                    Err(e) => {
                        done(mux, io, Err(e));
                        return;
                    }
                };
                let pane = String::from_utf8_lossy(rows[0].iter().next().unwrap()).into_owned();
                if crate::snapshot::id(&pane, '%').is_err() {
                    done(
                        mux,
                        io,
                        Err(Error {
                            code: "uncertain",
                            message: "Invalid created tmux pane".into(),
                        }),
                    );
                    return;
                }
                mux.verify(
                    io,
                    loc,
                    Box::new(move |mux, io, result| {
                        if let Err(e) = result {
                            done(
                                mux,
                                io,
                                Err(Error {
                                    code: "uncertain",
                                    message: e.message,
                                }),
                            );
                            return;
                        }
                        let mut command = mux.native(&mux.backends[&loc.backend].key);
                        command.args([
                            "set-option",
                            "-p",
                            "-t",
                            &pane,
                            "@dispatch-creation",
                            &marker,
                        ]);
                        if let Some(affinity) = affinity {
                            command.args([
                                ";",
                                "set-option",
                                "-w",
                                "-t",
                                &pane,
                                "@dispatch-window",
                                &affinity,
                            ]);
                        }
                        mux.run(
                            io,
                            command,
                            Box::new(move |mux, io, result| {
                                if matches!(
                                    result,
                                    Ok(Output::Exit {
                                        status: Some(0),
                                        ..
                                    })
                                ) {
                                    done(mux, io, Ok(rows));
                                } else {
                                    done(
                                        mux,
                                        io,
                                        Err(Error {
                                            code: "uncertain",
                                            message: "Tmux creation metadata could not be saved"
                                                .into(),
                                        }),
                                    );
                                }
                            }),
                        );
                    }),
                );
            },
        );
        self.windows.insert(
            child.pid,
            Window {
                child,
                bytes: Vec::new(),
                done: Some(complete),
            },
        );
    }
    pub(crate) fn windows(&mut self, io: &mut dyn Io, event: Option<&Event>) {
        let Some(Event::Ready { fd, read: true, .. }) = event else {
            return;
        };
        let mut replies = Vec::new();
        for window in self
            .windows
            .values_mut()
            .filter(|window| [window.child.output, window.child.stderr].contains(&Some(*fd)))
        {
            let mut bytes = [0; 65536];
            let count = match io.read(*fd, &mut bytes) {
                Ok(count) => count,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
                Err(_) => 0,
            };
            if count == 0 {
                io.close(*fd);
                if window.child.output == Some(*fd) {
                    window.child.output = None;
                    if let Some(done) = window.done.take() {
                        replies.push((
                            done,
                            Err(Error {
                                code: "uncertain",
                                message: "Tmux creation reply was lost".into(),
                            }),
                        ));
                    }
                } else {
                    window.child.stderr = None;
                }
            } else if window.child.output == Some(*fd) && window.done.is_some() {
                window.bytes.extend_from_slice(&bytes[..count]);
                if let Some(end) = window.bytes.iter().position(|byte| *byte == b'\n') {
                    let line = window.bytes[..end].to_vec();
                    replies.push((
                        window.done.take().unwrap(),
                        Ok(vec![[line].into_iter().collect()]),
                    ));
                    window.bytes.clear();
                } else if window.bytes.len() > crate::control::MAXIMUM {
                    replies.push((
                        window.done.take().unwrap(),
                        Err(Error {
                            code: "uncertain",
                            message: "Tmux creation reply exceeds its byte limit".into(),
                        }),
                    ));
                    window.bytes.clear();
                }
            }
        }
        self.windows
            .retain(|_, window| window.child.output.is_some() || window.child.stderr.is_some());
        for (done, result) in replies {
            done(self, io, result);
        }
    }
}
