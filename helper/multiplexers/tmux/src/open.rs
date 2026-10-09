//! Reopen retained views without creating work or accepting a replacement server.
use crate::{
    client::Client,
    mux::{Backend, Continue, Tmux, allocate, error, finish},
    ops::Location,
};
use dispatch_helper_core::api::*;
use std::{
    collections::{BTreeMap, BTreeSet},
    io,
};

impl Backend {
    fn request(&mut self, selected: Option<(u64, BTreeSet<u32>)>) {
        if self.done.is_empty() {
            self.selection = crate::retained::Selection::default();
        }
        if let Some((session, panes)) = selected {
            if let Some(hidden) = self.selection.hidden.get_mut(&session) {
                hidden.retain(|pane| !panes.contains(pane));
            }
            self.selection
                .panes
                .entry(session)
                .or_default()
                .extend(panes);
        } else {
            self.selection.all = true;
            self.selection.hidden.clear();
        }
    }
    /// Applies an open's restore intent; it must happen before that open reports success, or a
    /// later dismiss is undone by the stale intent.
    pub(crate) fn select(&mut self) {
        self.apply();
        self.selection = crate::retained::Selection::default();
    }
    fn apply(&mut self) {
        for client in self.clients.iter_mut().filter(|client| client.live()) {
            if self.selection.all {
                client.dismissed.clear();
            } else if let Some(snapshot) = &client.snapshot
                && let Some(panes) = self.selection.panes.get(&snapshot.session)
            {
                client.dismissed.retain(|pane| !panes.contains(pane));
            }
            if let Some(snapshot) = &client.snapshot
                && let Some(panes) = self.selection.hidden.get(&snapshot.session)
            {
                client.dismissed.extend(panes);
            }
        }
    }
    fn retained(&self) -> Vec<usize> {
        let mut sessions = BTreeMap::new();
        for (index, client) in self.clients.iter().enumerate() {
            if let Some(snapshot) = &client.snapshot {
                sessions.insert((snapshot.socket.clone(), snapshot.session), index);
            }
        }
        sessions
            .into_values()
            .filter(|index| {
                let client = &self.clients[*index];
                client.ended || !client.dismissed.is_empty()
            })
            .collect()
    }
}

impl Tmux {
    pub(crate) fn failed(&mut self, io: &mut dyn Io, id: Id, error: Error) {
        let backend = self.backends.get_mut(&id).unwrap();
        for client in &mut backend.clients {
            if client.expected.is_some() || client.snapshot.is_none() {
                client.finish(io);
            }
        }
        let completions = std::mem::take(&mut backend.done);
        self.changed = true;
        for done in completions {
            done(self, io, Err(error.clone()));
        }
    }

    pub(crate) fn open(&mut self, io: &mut dyn Io, key: &str, done: Done<Id>) {
        self.observe(
            io,
            key,
            None,
            Box::new(move |_, io, result| finish(io, done, result)),
        );
    }
    pub(crate) fn observe(
        &mut self,
        io: &mut dyn Io,
        key: &str,
        selected: Option<(u64, BTreeSet<u32>)>,
        done: Continue<Result<Id, Error>>,
    ) {
        match crate::endpoint::Endpoint::parse(key) {
            Ok(Some((key, expected))) => {
                self.endpoint(
                    io,
                    expected.path.to_string_lossy().into_owned(),
                    Some(expected),
                    None,
                    Box::new(move |mux, io, result| match result {
                        Ok(endpoint) => mux.verified(io, &key, endpoint, selected, done),
                        Err(error) => done(mux, io, Err(error)),
                    }),
                );
                return;
            }
            Err(failure) => {
                done(self, io, Err(error(failure)));
                return;
            }
            Ok(None) => {}
        }
        if let Some(id) = self
            .aliases
            .values()
            .find_map(|(id, alias)| (alias == key).then_some(*id))
            && let Some(backend) = self.backends.get_mut(&id)
        {
            let key = backend.key.clone();
            self.observe(io, &key, selected, done);
            return;
        }
        if let Some((_, backend)) = self.backends.iter_mut().find(|(_, backend)| {
            backend.key == key
                && backend
                    .clients
                    .iter()
                    .any(|client| !client.ended && client.snapshot.is_none())
        }) {
            backend.request(selected);
            backend.done.push(done);
            self.changed = true;
            return;
        }
        if selected.is_none()
            && let Some((&id, backend)) =
                self.backends.iter().find(|(_, backend)| backend.key == key)
            && backend.opening == 0
            && backend.done.is_empty()
            && backend.retained().is_empty()
            && backend.clients.iter().any(|client| client.live())
        {
            done(self, io, Ok(id));
            return;
        }
        if let Some((&id, backend)) = self
            .backends
            .iter()
            .find(|(_, backend)| backend.key == key && backend.remote)
        {
            // A relayed server has no local endpoint: only its own live stream can show
            // retained work again.
            if backend.clients.iter().any(|client| client.live()) {
                self.select(io, id, selected, done);
            } else {
                done(
                    self,
                    io,
                    Err(error("A relayed tmux stream cannot be reopened locally")),
                );
            }
            return;
        }
        let previous = self
            .backends
            .iter()
            .find(|(_, backend)| backend.key == key)
            .map(|(id, backend)| {
                (
                    *id,
                    backend.endpoint.clone(),
                    backend.clients.iter().find_map(|client| {
                        client
                            .snapshot
                            .as_ref()
                            .map(|snapshot| (snapshot.socket.clone(), snapshot.server as u32))
                    }),
                )
            });
        let (path, expected, server) = match &previous {
            Some((_, expected, snapshot)) => (
                expected
                    .as_ref()
                    .map(|endpoint| endpoint.path.to_string_lossy().into_owned())
                    .or_else(|| snapshot.as_ref().map(|(path, _)| path.clone()))
                    .unwrap_or_else(|| key.into()),
                expected.clone(),
                snapshot.as_ref().map(|(_, server)| *server),
            ),
            None => (key.into(), None, None),
        };
        let key = key.to_owned();
        self.endpoint(
            io,
            path,
            expected,
            server,
            Box::new(move |mux, io, result| match result {
                Ok(endpoint) => {
                    if let Some((id, _, _)) = previous {
                        mux.backends.get_mut(&id).unwrap().endpoint = Some(endpoint.clone());
                    }
                    mux.verified(io, &key, endpoint, selected, done);
                }
                Err(error) => done(mux, io, Err(error)),
            }),
        );
    }
    /// Show retained work again on an existing backend: refresh its live clients, reopen the
    /// ended ones (verified identity first), coalescing concurrent requests.
    pub(crate) fn select(
        &mut self,
        io: &mut dyn Io,
        id: Id,
        selected: Option<(u64, BTreeSet<u32>)>,
        done: Continue<Result<Id, Error>>,
    ) {
        let backend = self.backends.get_mut(&id).unwrap();
        backend.request(selected);
        if !backend.done.is_empty() {
            self.backends.get_mut(&id).unwrap().done.push(done);
            return;
        }
        if backend.opening != 0 {
            done(self, io, Err(error("Tmux backend is still opening")));
            return;
        }
        backend.done.push(done);
        self.reopen(io, id);
    }
    /// The pending restore of `id`: refresh its retained live clients, reopen the ended ones.
    pub(crate) fn reopen(&mut self, io: &mut dyn Io, id: Id) {
        let backend = self.backends.get_mut(&id).unwrap();
        let retained: Vec<_> = backend
            .retained()
            .into_iter()
            .filter(|index| {
                backend.selection.all
                    || backend
                        .selection
                        .panes
                        .contains_key(&backend.clients[*index].snapshot.as_ref().unwrap().session)
            })
            .collect();
        if retained.is_empty() {
            let backend = self.backends.get_mut(&id).unwrap();
            backend.select();
            self.changed = true;
            let result = if backend.clients.iter().any(|client| client.live()) {
                Ok(id)
            } else {
                Err(error("Tmux backend is unavailable"))
            };
            for done in std::mem::take(&mut backend.done) {
                done(self, io, result.clone());
            }
            return;
        }
        let backend = self.backends.get_mut(&id).unwrap();
        // An older detach refresh can finish during this refresh. Apply the restore intent
        // first, so that callback does not close the client whose work we are restoring.
        // Keep the intent until reopened clients have received their snapshots as well.
        backend.apply();
        backend.opening = retained
            .iter()
            .filter(|index| !backend.clients[**index].live())
            .count();
        for index in retained {
            let client = &self.backends[&id].clients[index];
            let snapshot = client.snapshot.as_ref().unwrap();
            let expected = (snapshot.session, snapshot.server, snapshot.socket.clone());
            if client.live() {
                self.backends.get_mut(&id).unwrap().clients[index].expected = Some(expected);
                self.refresh(
                    io,
                    Location {
                        backend: id,
                        client: index,
                        pane: 0,
                    },
                    None,
                );
                continue;
            }
            let dismissed = client.dismissed.clone();
            let mut command = self.native(&self.backends[&id].key);
            command.args([
                "display-message",
                "-p",
                "-t",
                &format!("${}", expected.0),
                "#{session_id}|#{pid}|#{socket_path}",
            ]);
            self.run(
                io,
                command,
                Box::new(move |mux, io, result| {
                    let backend = mux.backends.get_mut(&id).unwrap();
                    backend.opening -= 1;
                    if backend.done.is_empty() {
                        return;
                    }
                    let identity = format!("${}|{}|{}\n", expected.0, expected.1, expected.2);
                    let valid = matches!(result, Ok(Output::Exit {status:Some(0),ref stdout})
                        if stdout == identity.as_bytes());
                    if !valid {
                        mux.failed(
                            io,
                            id,
                            error("The original tmux server is no longer available"),
                        );
                        return;
                    }
                    let mut command = mux.native(&mux.backends[&id].key);
                    command.args(["-C", "attach-session", "-t", &format!("${}", expected.0)]);
                    match Client::new(io, command) {
                        Ok(mut client) => {
                            client.expected = Some(expected);
                            client.dismissed = dismissed;
                            mux.backends.get_mut(&id).unwrap().clients.push(client);
                            mux.changed = true;
                        }
                        Err(e) => mux.failed(io, id, error(e)),
                    }
                }),
            );
        }
    }
    fn verified(
        &mut self,
        io: &mut dyn Io,
        key: &str,
        endpoint: crate::endpoint::Endpoint,
        selected: Option<(u64, BTreeSet<u32>)>,
        done: Continue<Result<Id, Error>>,
    ) {
        if let Some(id) = self
            .backends
            .iter()
            .find(|(_, b)| b.key == key)
            .map(|(id, _)| *id)
        {
            self.select(io, id, selected, done);
            return;
        }
        let id = allocate(&mut self.next);
        self.backends.insert(
            id,
            Backend {
                key: key.into(),
                endpoint: Some(endpoint),
                clients: Vec::new(),
                ids: BTreeMap::new(),
                done: vec![done],
                opening: 1,
                views: BTreeMap::new(),
                selection: crate::retained::Selection::default(),
                remote: false,
                identity: None,
                pending: BTreeMap::new(),
            },
        );
        let mut command = self.native(key);
        command.args(["list-sessions", "-F", "#{session_id}"]);
        self.run(
            io,
            command,
            Box::new(move |mux, io, result| {
                mux.backends.get_mut(&id).unwrap().opening = 0;
                let outcome = (|| -> io::Result<()> {
                    let Output::Exit {
                        status: Some(0),
                        stdout,
                    } = result?
                    else {
                        return Err(io::Error::other("Could not list tmux sessions"));
                    };
                    let key = mux.backends[&id].key.clone();
                    for session in std::str::from_utf8(&stdout)
                        .map_err(io::Error::other)?
                        .lines()
                    {
                        crate::snapshot::id(session, '$')
                            .map_err(|e| io::Error::other(e.message))?;
                        let mut command = mux.native(&key);
                        command.args(["-C", "attach-session", "-t", session]);
                        mux.backends
                            .get_mut(&id)
                            .unwrap()
                            .clients
                            .push(Client::new(io, command)?);
                    }
                    if mux.backends[&id].clients.is_empty() {
                        return Err(io::Error::other("No tmux session exists"));
                    }
                    Ok(())
                })();
                if let Err(e) = outcome {
                    mux.failed(io, id, error(e));
                }
            }),
        );
    }
}
