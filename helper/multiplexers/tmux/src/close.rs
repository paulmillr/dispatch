//! Close verified idle shells; dismiss busy views without killing native jobs.
use crate::{
    mux::{Continue, Tmux, error, finish, gone},
    ops::Location,
};
use dispatch_helper_core::{
    api::*,
    json::{self, Data},
};

impl Tmux {
    /// A creation finished (its pane, if any, is in the latest snapshot); the last one
    /// performs a detach that waited for it, dismissing the new pane with the rest.
    pub(crate) fn settle(&mut self, io: &mut dyn Io, loc: Location, pane: Option<u32>) {
        let Some(client) = self
            .backends
            .get_mut(&loc.backend)
            .and_then(|backend| backend.clients.get_mut(loc.client))
        else {
            return;
        };
        client.creating -= 1;
        if client.creating == 0 && std::mem::take(&mut client.detaching) {
            client.dismissed.extend(pane);
            if client.snapshot.as_ref().is_some_and(|snapshot| {
                snapshot
                    .panes
                    .keys()
                    .all(|pane| client.dismissed.contains(pane))
            }) {
                client.detach(io);
            }
            self.changed = true;
        }
    }
    fn scope(
        &self,
        node: Id,
        loc: Location,
        target: &str,
    ) -> Result<Vec<(u32, i32, String)>, Error> {
        let client = &self.backends[&loc.backend].clients[loc.client];
        let snapshot = client
            .snapshot
            .as_ref()
            .ok_or_else(|| error("Tmux topology is unavailable"))?;
        let panes = match target.as_bytes()[0] {
            b'%' => vec![crate::snapshot::id(target, '%')? as u32],
            b'@' => snapshot
                .windows
                .iter()
                .find(|window| target == format!("@{}", window.id))
                .ok_or_else(|| gone("Tmux window closed"))?
                .layout
                .ids(),
            _ => {
                let group = &self
                    .groups
                    .roots
                    .get(&node)
                    .ok_or_else(|| gone("Tmux group closed"))?
                    .2;
                self.members(loc, group)
                    .iter()
                    .flat_map(|id| {
                        snapshot
                            .windows
                            .iter()
                            .find(|window| window.id == *id)
                            .unwrap()
                            .layout
                            .ids()
                    })
                    .collect()
            }
        };
        panes
            .into_iter()
            .map(|pane| {
                let state = snapshot
                    .panes
                    .get(&pane)
                    .ok_or_else(|| gone("Tmux pane closed"))?;
                Ok((pane, state.pid, state.tty.clone()))
            })
            .collect()
    }

    pub(crate) fn close(&mut self, io: &mut dyn Io, node: Id, how: Close, done: Done<()>) {
        if self
            .backends
            .values()
            .any(|backend| backend.views.contains_key(&node))
        {
            if how == Close::Detach {
                let backend = self
                    .backends
                    .values_mut()
                    .find(|backend| backend.views.contains_key(&node))
                    .unwrap();
                let view = &backend.views[&node];
                backend
                    .selection
                    .hidden
                    .entry(view.session)
                    .or_default()
                    .extend(&view.panes);
                for client in &mut backend.clients {
                    if client
                        .snapshot
                        .as_ref()
                        .is_some_and(|snapshot| snapshot.session == view.session)
                    {
                        client.dismissed.extend(&view.panes);
                    }
                }
                self.changed = true;
                io.timer(io.now());
                self.published.push(done);
            } else if how == Close::Terminate {
                // forget wakes the mux; Done follows the topology without the view.
                self.forget(io, node);
                self.published.push(done);
            } else {
                finish(
                    io,
                    done,
                    Err(error("Detached work requires an explicit forget request")),
                );
            }
            return;
        }
        let (loc, target) = match self.target(node) {
            Ok(value) => value,
            Err(error) => {
                finish(io, done, Err(error));
                return;
            }
        };
        if how == Close::Detach || (how == Close::Prompt && target.starts_with('$')) {
            self.dismiss(io, node, loc, target, done);
            return;
        }
        let commands = if target.starts_with('$') {
            self.members(loc, &self.groups.roots[&node].2)
                .iter()
                .map(|window| format!("kill-window -t @{window}"))
                .collect()
        } else {
            vec![format!(
                "{} -t {target}",
                match target.as_bytes()[0] {
                    b'@' => "kill-window",
                    _ => "kill-pane",
                }
            )]
        };
        if how == Close::Terminate {
            self.kill(io, loc, commands, done);
            return;
        }
        self.probe(
            io,
            node,
            loc,
            target.clone(),
            Box::new(move |mux, io, idle| {
                if idle {
                    mux.kill(io, loc, commands, done);
                } else {
                    mux.dismiss(io, node, loc, target, done);
                }
            }),
        );
    }

    pub(crate) fn idle(&mut self, io: &mut dyn Io, node: Id, done: Done<bool>) {
        let (loc, target) = match self.target(node) {
            Ok(value) => value,
            Err(error) => {
                finish(io, done, Err(error));
                return;
            }
        };
        self.probe(
            io,
            node,
            loc,
            target,
            Box::new(move |_, io, idle| finish(io, done, Ok(idle))),
        );
    }

    fn probe(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        loc: Location,
        target: String,
        done: Continue<bool>,
    ) {
        if self.backends[&loc.backend].remote {
            done(self, io, false);
            return;
        }
        self.refresh(
            io,
            loc,
            Some(Box::new(move |mux, io, result| {
                if result.is_err() {
                    done(mux, io, false);
                    return;
                }
                let panes = match mux.scope(node, loc, &target) {
                    Ok(panes)
                        if !panes.is_empty()
                            && panes.iter().all(|(pane, _, _)| {
                                !mux.backends[&loc.backend].clients[loc.client]
                                    .dismissed
                                    .contains(pane)
                            }) =>
                    {
                        panes
                    }
                    _ => {
                        done(mux, io, false);
                        return;
                    }
                };
                let snapshot = mux.backends[&loc.backend].clients[loc.client]
                    .snapshot
                    .as_ref()
                    .unwrap();
                let identity = (snapshot.session, snapshot.server, snapshot.socket.clone());
                let expected = panes.clone();
                mux.scan(
                    io,
                    loc,
                    panes,
                    Box::new(move |mux, io, idle| {
                        if !idle {
                            done(mux, io, false);
                            return;
                        }
                        mux.refresh(
                            io,
                            loc,
                            Some(Box::new(move |mux, io, result| {
                                let client = &mux.backends[&loc.backend].clients[loc.client];
                                let valid = result.is_ok()
                                    && !client.ended
                                    && client.snapshot.as_ref().is_some_and(|snapshot| {
                                        (snapshot.session, snapshot.server, snapshot.socket.clone())
                                            == identity
                                            && mux
                                                .scope(node, loc, &target)
                                                .is_ok_and(|panes| panes == expected)
                                            && expected.iter().all(|(pane, _, _)| {
                                                !client.dismissed.contains(pane)
                                            })
                                    });
                                done(mux, io, valid);
                            })),
                        );
                    }),
                );
            })),
        );
    }

    fn scan(
        &mut self,
        io: &mut dyn Io,
        loc: Location,
        mut panes: Vec<(u32, i32, String)>,
        done: Continue<bool>,
    ) {
        let Some((_, pid, tty)) = panes.pop() else {
            done(self, io, true);
            return;
        };
        let server = self.backends[&loc.backend].clients[loc.client]
            .snapshot
            .as_ref()
            .unwrap()
            .server;
        if pid <= 1 || server <= 1 {
            done(self, io, false);
            return;
        }
        self.job(
            io,
            Job::Process { pid: pid as u32 },
            Box::new(move |mux, io, result| {
                let shell = match result {
                    Ok(Output::Process(process))
                        if process.pid == pid as u32
                            && process.parent == server as u32
                            && process.tty != 0 =>
                    {
                        process
                    }
                    _ => {
                        done(mux, io, false);
                        return;
                    }
                };
                let input = json::write(&Data::Object(vec![("path", Data::String(&tty))])).unwrap();
                mux.job(
                    io,
                    Job::Native {
                        name: "file.lstat",
                        input,
                    },
                    Box::new(move |mux, io, result| {
                        let matches = match result {
                            Ok(Output::Bytes(bytes)) => {
                                Json::parse(&bytes).ok().is_some_and(|json| {
                                    json.root().get("kind").and_then(|v| v.string())
                                        == Some("character")
                                        && json.root().get("tty").and_then(|v| v.unsigned())
                                            == Some(shell.tty)
                                })
                            }
                            _ => false,
                        };
                        if !matches {
                            done(mux, io, false);
                            return;
                        }
                        let input = json::write(&Data::Object(vec![
                            ("pid", Data::Unsigned(shell.pid.into())),
                            (
                                "start",
                                Data::Array(
                                    shell.start.iter().map(|v| Data::Unsigned(*v)).collect(),
                                ),
                            ),
                        ]))
                        .unwrap();
                        mux.job(
                            io,
                            Job::Native {
                                name: "idle",
                                input,
                            },
                            Box::new(move |mux, io, result| {
                                let idle = match result {
                                    Ok(Output::Bytes(bytes)) => {
                                        Json::parse(&bytes).ok().is_some_and(|json| {
                                            json.root().get("idle").and_then(|v| v.boolean())
                                                == Some(true)
                                        })
                                    }
                                    _ => false,
                                };
                                if idle {
                                    mux.scan(io, loc, panes, done);
                                } else {
                                    done(mux, io, false);
                                }
                            }),
                        );
                    }),
                );
            }),
        );
    }

    /// Kills its targets like mutate; tmux ending the client meanwhile (%exit: the last window
    /// went with them) means they are gone, which is what was asked (old app: a clean end).
    fn kill(&mut self, io: &mut dyn Io, loc: Location, commands: Vec<String>, done: Done<()>) {
        let count = commands.len();
        self.request_count(
            io,
            loc,
            count,
            commands,
            Box::new(move |mux, io, result| {
                let gone = mux
                    .backends
                    .get(&loc.backend)
                    .and_then(|b| b.clients.get(loc.client))
                    .is_some_and(|c| c.exited);
                match result {
                    Err(error) if !gone => finish(io, done, Err(error)),
                    _ => mux.refresh(
                        io,
                        loc,
                        Some(Box::new(move |_, io, _| finish(io, done, Ok(())))),
                    ),
                }
            }),
        );
    }
    fn dismiss(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        loc: Location,
        target: String,
        done: Done<()>,
    ) {
        let panes = match self.scope(node, loc, &target) {
            Ok(panes) => panes,
            Err(_) => {
                finish(io, done, Ok(()));
                return;
            }
        };
        let view = self.remember(loc, node, panes.iter().map(|(pane, _, _)| *pane).collect());
        for pending in self
            .backends
            .get_mut(&loc.backend)
            .unwrap()
            .pending
            .values_mut()
        {
            let mut parent = Some(pending.parent);
            for _ in 0..=self.nodes.len() {
                let Some(id) = parent else {
                    break;
                };
                if id == node {
                    if !pending.hidden {
                        pending.hidden = true;
                        pending.view = view;
                    }
                    break;
                }
                parent = self
                    .nodes
                    .iter()
                    .find(|node| node.id == id)
                    .and_then(|node| node.parent);
            }
        }
        let client = &mut self.backends.get_mut(&loc.backend).unwrap().clients[loc.client];
        client
            .dismissed
            .extend(panes.iter().map(|(pane, _, _)| *pane));
        self.changed = true;
        let snapshot = client.snapshot.as_ref().unwrap();
        let active = snapshot.windows.iter().find(|window| window.active);
        let replacement = active.and_then(|window| {
            let panes: Vec<_> = window
                .layout
                .ids()
                .into_iter()
                .filter(|pane| !client.dismissed.contains(pane))
                .collect();
            if !panes.is_empty() {
                return client
                    .dismissed
                    .contains(&window.pane)
                    .then(|| format!("select-pane -t %{}", panes[0]));
            }
            let windows: Vec<_> = snapshot
                .windows
                .iter()
                .filter(|window| {
                    window
                        .layout
                        .ids()
                        .iter()
                        .any(|pane| !client.dismissed.contains(pane))
                })
                .collect();
            windows
                .iter()
                .find(|candidate| candidate.id > window.id)
                .or_else(|| windows.last())
                .map(|window| format!("select-window -t @{}", window.id))
        });
        let refresh: Continue<_> =
            Box::new(move |mux, io, _: Result<crate::client::Batch, Error>| {
                mux.refresh(
                    io,
                    loc,
                    Some(Box::new(move |mux, io, _| {
                        let client =
                            &mut mux.backends.get_mut(&loc.backend).unwrap().clients[loc.client];
                        if client.snapshot.as_ref().is_some_and(|snapshot| {
                            snapshot
                                .panes
                                .keys()
                                .all(|pane| client.dismissed.contains(pane))
                        }) {
                            if client.creating > 0 {
                                client.detaching = true;
                            } else {
                                client.detach(io);
                            }
                        }
                        mux.changed = true;
                        finish(io, done, Ok(()));
                    })),
                );
            });
        if let Some(command) = replacement {
            self.request(io, loc, vec![command], refresh);
        } else {
            refresh(self, io, Ok(Vec::new()));
        }
    }
}
