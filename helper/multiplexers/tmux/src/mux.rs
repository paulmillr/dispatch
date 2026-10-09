pub(crate) use crate::backend::Backend;
use crate::{
    client::{Batch, Notice},
    ops::{Location, Terminal},
    topology::Content,
};
use dispatch_helper_core::api::*;
use std::{
    cell::RefCell, collections::BTreeMap, io, path::PathBuf, process::Command, rc::Rc,
    time::Duration,
};
pub(crate) type Continue<T> = Box<dyn FnOnce(&mut Tmux, &mut dyn Io, T)>;
pub(crate) type NativeDone = Continue<Result<Batch, Error>>;
type JobDone = Continue<io::Result<Output>>;
#[derive(Default)]
pub struct Tmux {
    pub(crate) executable: PathBuf,
    pub(crate) harnesses: Vec<Shared<dyn Harness>>,
    pub(crate) next: Id,
    pub(crate) jobs: BTreeMap<Work, JobDone>,
    pub(crate) windows: BTreeMap<u32, crate::create::Window>,
    pub(crate) checks: BTreeMap<Id, crate::endpoint::Check>,
    pub(crate) backends: BTreeMap<Id, Backend>,
    pub(crate) terminals: BTreeMap<Id, Terminal>,
    pub(crate) sizes: BTreeMap<Id, Grid>,
    pub(crate) updates: Vec<Update>,
    pub(crate) changed: bool,
    pub(crate) dividers: BTreeMap<Id, crate::actions::Divider>,
    pub(crate) changes: BTreeMap<Id, crate::actions::Change>,
    pub(crate) nodes: Vec<Node>,
    pub(crate) groups: crate::affinity::Groups,
    pub(crate) agents: BTreeMap<Id, (usize, Binding)>,
    pub(crate) discovery: crate::discovery::Discovery,
    /// Keys continuations whose settle elapsed (ops.rs typed); run on the next Timer.
    pub(crate) resumes: Rc<RefCell<Vec<Continue<bool>>>>,
    /// A relayed re-claim continues an earlier backend: claimed id -> that backend.
    pub(crate) aliases: BTreeMap<Id, (Id, String)>,
    /// Completions of local-only changes: they run once the next topology went to the UI.
    pub(crate) published: Vec<Done<()>>,
    /// Each backend's last published layouts and focus: a backend that cannot read its
    /// server (suspended, opening) republishes them with its current retained views.
    shown: BTreeMap<Id, (Vec<Layout>, Option<Id>)>,
}
/// The target ended (its session, window, pane or view is gone): core's `expired`, which the
/// app does not show as a failure (orchestrator 2026-10-03, every mux).
pub(crate) fn gone(message: &str) -> Error {
    Error {
        code: "expired",
        message: message.into(),
    }
}
pub(crate) fn error(e: impl std::fmt::Display) -> Error {
    Error {
        code: "tmux",
        message: e.to_string(),
    }
}
pub(crate) fn allocate(next: &mut Id) -> Id {
    let id = *next;
    *next += 1;
    id
}
pub(crate) fn finish<T: 'static>(io: &mut dyn Io, done: Done<T>, result: Result<T, Error>) {
    io.defer(Box::new(move |io| done(io, result)));
}
impl Tmux {
    /// Scrollback belongs to the renderer in c1654cc TerminalScrollbar.swift68-73.
    pub fn seek(&mut self, io: &mut dyn Io, _terminal: Id, _offset: u64, done: Done<()>) {
        finish(
            io,
            done,
            Err(Error {
                code: "unsupported",
                message: "Renderer owns scrollback".into(),
            }),
        );
    }
    pub fn new(executable: PathBuf) -> Self {
        Self {
            executable,
            next: 1,
            ..Self::default()
        }
    }
    pub(crate) fn job(&mut self, io: &mut dyn Io, job: Job, done: JobDone) {
        match io.submit(job) {
            Ok(work) => {
                self.jobs.insert(work, done);
            }
            Err(error) => done(self, io, Err(error)),
        }
    }
    pub(crate) fn run(&mut self, io: &mut dyn Io, command: Command, done: JobDone) {
        let job = Job::Run {
            command,
            input: Vec::new(),
            deadline: io.now() + Duration::from_secs(5),
        };
        self.job(io, job, done);
    }
    pub(crate) fn request(
        &mut self,
        io: &mut dyn Io,
        location: Location,
        commands: Vec<String>,
        done: NativeDone,
    ) {
        self.request_count(io, location, commands.len(), commands, done);
    }
    pub(crate) fn request_count(
        &mut self,
        io: &mut dyn Io,
        location: Location,
        count: usize,
        commands: Vec<String>,
        done: NativeDone,
    ) {
        let mut done = Some(done);
        if let Err(e) = self.backends.get_mut(&location.backend).unwrap().clients[location.client]
            .commands(io, &commands, count, &mut done)
            && let Some(done) = done
        {
            done(self, io, Err(error(e)));
        }
    }
    pub(crate) fn refresh(
        &mut self,
        io: &mut dyn Io,
        location: Location,
        done: Option<Continue<Result<(), Error>>>,
    ) {
        let client =
            &mut self.backends.get_mut(&location.backend).unwrap().clients[location.client];
        // A leaving client (detach-client sent) answers no new reads; a reopen reads instead.
        if client.leaving && !client.refreshing {
            let mut waiters = std::mem::take(&mut client.waiters);
            waiters.append(&mut client.later);
            waiters.extend(done);
            client.again = false;
            for done in waiters {
                done(self, io, Err(error("Tmux control connection closed")));
            }
            return;
        }
        // A read already in flight may predate the caller's change: wait for the next one
        // (c1654cc TmuxSession refresh serial).
        if client.refreshing {
            client.later.extend(done);
            client.again = true;
            return;
        }
        client.waiters.extend(done);
        // Only a read started after the restore request may release its freshness barrier.
        let expected = client.expected.is_some();
        client.refreshing = true;
        let commands = include_str!("query.tmux")
            .trim()
            .split(" ; ")
            .map(str::to_owned)
            .collect();
        self.request(
            io,
            location,
            commands,
            Box::new(move |mux, io, result| {
                let client =
                    &mut mux.backends.get_mut(&location.backend).unwrap().clients[location.client];
                let parsed = result.and_then(|rows| {
                    let snapshot = crate::snapshot::Snapshot::parse(&rows[0], &rows[1], &rows[2])?;
                    if client.expected.as_ref().is_some_and(|expected| {
                        (snapshot.session, snapshot.server, snapshot.socket.clone()) != *expected
                    }) {
                        return Err(error("The original tmux server is no longer available"));
                    }
                    let mut cwd = BTreeMap::new();
                    for row in rows[3].iter() {
                        let s = String::from_utf8_lossy(row);
                        let [pane, path] = crate::snapshot::fields(&s)?;
                        cwd.insert(crate::snapshot::id(pane, '%')? as u32, PathBuf::from(path));
                    }
                    Ok((snapshot, cwd))
                });
                let complete: Continue<
                    Result<(crate::snapshot::Snapshot, BTreeMap<u32, PathBuf>), Error>,
                > = Box::new(move |mux, io, parsed| {
                    let client = &mut mux.backends.get_mut(&location.backend).unwrap().clients
                        [location.client];
                    let first = client.snapshot.is_none();
                    let mut previous = None;
                    let mut result = parsed.and_then(|(snapshot, cwd)| {
                        if client.ended {
                            return Err(error("Tmux control connection closed"));
                        }
                        if expected { client.expected = None; }
                        client
                            .closed
                            .retain(|id| snapshot.windows.iter().any(|window| window.id == *id));
                        client
                            .available
                            .retain(|id, _| snapshot.windows.iter().any(|window| window.id == *id));
                        previous = Some(client.snapshot.replace(snapshot));
                        client.cwd = cwd;
                        mux.changed = true;
                        mux.discovery.dirty = true;
                        Ok(())
                    });
                    client.refreshing = false;
                    let mut waiters = std::mem::take(&mut client.waiters);
                    if client.again {
                        client.again = false;
                        if client.ended {
                            // No later read will happen: they share this read's closed result.
                            waiters.append(&mut client.later);
                        } else {
                            client.waiters = std::mem::take(&mut client.later);
                            client.schedule(io);
                        }
                    }
                    let expected = client.expected.is_some();
                    if result.is_ok() {
                        result = mux.resolve(io, location);
                        // Topology needs every published window's group: an unresolved
                        // model is not published (the earlier one stays).
                        if result.is_err() {
                            mux.backends.get_mut(&location.backend).unwrap().clients
                                [location.client]
                                .snapshot = previous.flatten();
                        }
                    }
                    let backend = &mux.backends[&location.backend];
                    // A restore's control client lost meanwhile: its server reopens like any ended client.
                    if expected
                        && result.is_err()
                        && backend.clients[location.client].ended
                        && !backend.remote
                        && backend.opening == 0
                        && !backend.done.is_empty()
                    {
                        mux.backends.get_mut(&location.backend).unwrap().clients[location.client]
                            .expected = None;
                        mux.reopen(io, location.backend);
                    } else if (first || expected)
                        && let Err(error) = &result
                    {
                        mux.failed(io, location.backend, error.clone());
                    }
                    for done in waiters {
                        done(mux, io, result.clone());
                    }
                });
                match parsed {
                    Err(error) => complete(mux, io, Err(error)),
                    Ok((snapshot, cwd)) => {
                        let backend = &mux.backends[&location.backend];
                        if backend.remote && backend.identity.is_none() {
                            mux.identify(io, location, snapshot, cwd, complete);
                        } else if backend.remote {
                            complete(mux, io, Ok((snapshot, cwd)));
                        } else if let Some(endpoint) = &backend.endpoint {
                            if endpoint.pid as i32 == snapshot.server {
                                if backend.identity.is_none()
                                    && backend.clients[location.client].adopted()
                                {
                                    mux.identify(io, location, snapshot, cwd, complete);
                                } else {
                                    complete(mux, io, Ok((snapshot, cwd)));
                                }
                            } else {
                                complete(
                                    mux,
                                    io,
                                    Err(error("The original tmux server is no longer available")),
                                );
                            }
                        } else {
                            mux.endpoint(
                                io,
                                snapshot.socket.clone(),
                                None,
                                Some(snapshot.server as u32),
                                Box::new(move |mux, io, result| {
                                    let parsed = result.map(|endpoint| {
                                        mux.backends.get_mut(&location.backend).unwrap().endpoint =
                                            Some(endpoint);
                                        (snapshot, cwd)
                                    });
                                    match parsed {
                                        Ok((snapshot, cwd))
                                            if mux.backends[&location.backend].clients
                                                [location.client]
                                                .adopted() =>
                                        {
                                            mux.identify(io, location, snapshot, cwd, complete)
                                        }
                                        Ok(result) => complete(mux, io, Ok(result)),
                                        Err(error) => complete(mux, io, Err(error)),
                                    }
                                }),
                            );
                        }
                    }
                }
            }),
        );
    }
    fn topology(&mut self, io: &mut dyn Io, ui: &mut dyn Ui) {
        if !self.changed {
            return;
        }
        self.changed = false;
        // A restore's control client lost before its fresh read: its server reopens like any ended client.
        let mut lost = Vec::new();
        for (&id, backend) in &mut self.backends {
            if backend.remote || backend.opening != 0 || backend.done.is_empty() {
                continue;
            }
            let mut ended = false;
            for client in backend.clients.iter_mut().filter(|c| c.ended && c.snapshot.is_some()) {
                ended |= client.expected.take().is_some();
            }
            if ended {
                lost.push(id);
            }
        }
        for id in lost {
            self.reopen(io, id);
        }
        let previous = std::mem::take(&mut self.nodes);
        let dividers = std::mem::take(&mut self.dividers);
        let mut drafts = Vec::new();
        let mut finished = Vec::new();
        for (&id, backend) in &mut self.backends {
            if backend.suspended()
                || backend.opening != 0
                || backend
                    .clients
                    .iter()
                    .any(|c| !c.ended && (c.snapshot.is_none() || c.expected.is_some()))
            {
                let kept: Vec<Node> = previous
                    .iter()
                    .filter(|node| !node.detached && backend.ids.values().any(|id| *id == node.id))
                    .cloned()
                    .collect();
                self.dividers.extend(
                    dividers
                        .iter()
                        .filter(|(_, divider)| divider.loc.backend == id)
                        .map(|(id, divider)| (*id, *divider)),
                );
                // Local changes (a forgotten view) still reach the app.
                if let Some((layouts, focus)) = self.shown.get(&id) {
                    drafts.push((id, kept, layouts.clone(), *focus));
                } else {
                    self.nodes.extend(kept);
                }
                continue;
            }
            let mut nodes = Vec::new();
            let mut layouts = Vec::new();
            let mut focused = None;
            let mut candidates = 0;
            backend.select();
            for view in backend.views.values_mut() {
                for client in backend.clients.iter().filter(|client| !client.ended) {
                    if let Some(snapshot) = &client.snapshot
                        && snapshot.session == view.session
                    {
                        let visible: std::collections::BTreeSet<_> = snapshot
                            .windows
                            .iter()
                            .flat_map(|window| window.layout.ids())
                            .filter(|pane| !client.dismissed.contains(pane))
                            .collect();
                        view.panes.retain(|pane| !visible.contains(pane));
                    }
                }
            }
            backend.views.retain(|_, view| !view.panes.is_empty());
            for (index, client) in backend.clients.iter().enumerate().filter(|(_, c)| !c.ended) {
                let location = Location {
                    backend: id,
                    client: index,
                    pane: 0,
                };
                let Some(snapshot) = &client.snapshot else {
                    continue;
                };
                if snapshot
                    .windows
                    .iter()
                    .all(|window| window.layout.excluding(&client.dismissed).is_none())
                {
                    continue;
                }
                let namespace = backend.namespace();
                let mut node = |key: String, data: Option<(_, _, _, _, _, _)>| {
                    let id = *backend
                        .ids
                        .entry(key.clone())
                        .or_insert_with(|| allocate(&mut self.next));
                    if let Some((parent, kind, name, cwd, size, renamed)) = data {
                        nodes.push(Node {
                            detached: false, renamed,
                            tty: self.discovery.ttys.get(&id).copied(),
                            id,
                            key: format!("tmux:{namespace}:{key}"),
                            parent,
                            kind,
                            name,
                            cwd,
                            size,
                            agent: self.agents.get(&id).cloned(),
                        });
                    }
                    id
                };
                let mut groups = Vec::new();
                for window in &snapshot.windows {
                    let group = &self.groups.windows[&(id, snapshot.session, window.id)].group;
                    if window.layout.excluding(&client.dismissed).is_some()
                        && !groups.contains(group)
                    {
                        groups.push(group.clone());
                    }
                }
                for group in groups {
                    let mut windows: Vec<_> = snapshot
                        .windows
                        .iter()
                        .filter(|window| {
                            self.groups.windows[&(id, snapshot.session, window.id)].group == group
                                && window.layout.excluding(&client.dismissed).is_some()
                        })
                        .collect();
                    windows.sort_by_key(|window| {
                        (
                            self.groups.windows[&(id, snapshot.session, window.id)].order,
                            window.id,
                        )
                    });
                    let pane = windows[0].layout.ids()[0];
                    let name = crate::affinity::display(
                        &self.groups.windows[&(id, snapshot.session, windows[0].id)],
                        client.cwd.get(&pane).map(|path| path.as_path()),
                    );
                    let key = if let Some((&root, _)) =
                        self.groups.roots.iter().find(|(_, value)| {
                            value.0 == id && value.1 == snapshot.session && value.2 == group
                        }) {
                        self.groups.keys[&root].clone()
                    } else if !self
                        .groups
                        .roots
                        .values()
                        .any(|value| value.0 == id && value.1 == snapshot.session)
                    {
                        format!("${}", snapshot.session)
                    } else {
                        format!("${}:group:{group}", snapshot.session)
                    };
                    let root = node(key.clone(), Some((None, Kind::Workspace, name, None, None, None)));
                    self.groups.keys.insert(root, key);
                    self.groups
                        .roots
                        .insert(root, (id, snapshot.session, group.clone()));
                    let key = (id, snapshot.session, group);
                    let selected = windows
                        .iter()
                        .find(|window| window.active)
                        .map(|window| window.id)
                        .or_else(|| {
                            self.groups.selected.get(&key).copied().filter(|selected| {
                                windows.iter().any(|window| window.id == *selected)
                            })
                        })
                        .unwrap_or(windows[0].id);
                    self.groups.selected.insert(key, selected);
                    let mut active = None;
                    for window in windows {
                        let Some(layout) = window.layout.excluding(&client.dismissed) else {
                            continue;
                        };
                        let visible = window
                            .visible
                            .excluding(&client.dismissed)
                            .unwrap_or_else(|| layout.clone());
                        let tab = node(
                            format!("${}:@{}", snapshot.session, window.id),
                            Some((
                                Some(root),
                                Kind::Tab,
                                crate::affinity::label(&window.name),
                                None,
                                None,
                                window.renamed,
                            )),
                        );
                        let mut panes = BTreeMap::new();
                        let full =
                            layout.split(
                                &mut Vec::new(),
                                &mut |content, path, offset| match content {
                                    Content::Split(_, _) => node(
                                        format!(
                                            "${}:@{}:split:{path:?}:{offset}",
                                            snapshot.session, window.id
                                        ),
                                        None,
                                    ),
                                    Content::Pane(pane) => {
                                        let state = &snapshot.panes[pane];
                                        let id = node(
                                            format!("${}:%{pane}", snapshot.session),
                                            Some((
                                                Some(tab),
                                                Kind::Terminal,
                                                state.title.clone(),
                                                client.cwd.get(pane).cloned(),
                                                Some(Grid {
                                                    pixels: None,
                                                    columns: state.width as u16,
                                                    rows: state.height as u16,
                                                }),
                                                None,
                                            )),
                                        );
                                        panes.insert(*pane, id);
                                        id
                                    }
                                },
                            );
                        let focus = panes
                            .get(&window.pane)
                            .copied()
                            .or_else(|| panes.get(&visible.ids()[0]).copied());
                        if window.active && focus.is_some() {
                            focused = focus;
                            candidates += 1;
                        }
                        let visible =
                            visible.split(&mut Vec::new(), &mut |content, path, offset| {
                                match content {
                                    Content::Pane(pane) => panes[pane],
                                    Content::Split(axis, children) => {
                                        let id = node(
                                            format!(
                                                "${}:@{}:split:{path:?}:{offset}",
                                                snapshot.session, window.id
                                            ),
                                            None,
                                        );
                                        let first = children[offset].bounds(*axis);
                                        let (mut low, mut high) = (first.low, first.high);
                                        for child in &children[offset + 1..] {
                                            let bounds = child.bounds(*axis);
                                            low = low.min(bounds.low);
                                            high = high.max(bounds.high);
                                        }
                                        self.dividers.insert(
                                            id,
                                            crate::actions::Divider {
                                                loc: Location {
                                                    pane: first.pane,
                                                    ..location
                                                },
                                                axis: *axis,
                                                first,
                                                low,
                                                high,
                                            },
                                        );
                                        id
                                    }
                                }
                            });
                        layouts.push(Layout {
                            container: tab,
                            full,
                            visible,
                            focus,
                        });
                        if window.id == selected {
                            active = Some(tab);
                        }
                    }
                    if let Some(tab) = active {
                        layouts.push(Layout {
                            container: root,
                            full: Split::Leaf(tab),
                            visible: Split::Leaf(tab),
                            focus: Some(tab),
                        });
                    }
                }
            }
            drafts.push((
                id,
                nodes,
                layouts,
                if candidates == 1 { focused } else { None },
            ));
            for done in std::mem::take(&mut backend.done) {
                finished.push((done, id));
            }
        }
        let retained = self.retained();
        for (backend, mut nodes, layouts, focus) in drafts {
            nodes.extend(
                retained
                    .iter()
                    .filter(|(id, _, _)| *id == backend)
                    .map(|(_, node, _)| node.clone()),
            );
            self.nodes.extend(nodes.iter().cloned());
            self.shown.insert(backend, (layouts.clone(), focus));
            ui.update(Update::Topology {
                key: self.backends[&backend]
                    .endpoint
                    .as_ref()
                    .map(|endpoint| endpoint.key(&self.backends[&backend].key)),
                backend,
                nodes,
                layouts,
                focus,
            });
        }
        for (done, id) in finished {
            done(self, io, Ok(id));
        }
    }
}
macro_rules! operations {
    ($($name:ident($($arg:ident:$ty:ty),*) -> $out:ty;)*) => {
        $(
            fn $name(&mut self, io: &mut dyn Io, $($arg:$ty,)* done: Done<$out>) {
                self.$name(io, $($arg,)* deferred(done));
            }
        )*
    };
}
impl Multiplexer for Tmux {
    fn external(&self) -> bool {
        true
    }
    fn name(&self) -> &str {
        "tmux"
    }
    /// "New tmux space" runs this in a new terminal; the control start is then claimed
    /// (c1654cc NewSpaceButton.swift:27).
    fn prefix(&mut self, io: &mut dyn Io, node: Id, done: Done<Prefix>) {
        Tmux::prefix(self, io, node, done);
    }
    fn command(&mut self, io: &mut dyn Io, node: Id, command: &str, done: Done<()>) {
        Tmux::command(self, io, node, command, done);
    }
    fn program(&self) -> Option<String> {
        Some("tmux -CC new-session".into())
    }
    fn invalidate(&mut self, io: &mut dyn Io, process: &Process) {
        let mut changed = false;
        for (&id, (_, binding)) in &self.agents {
            if binding.process.pid == process.pid && binding.process.start == process.start {
                changed |= self.discovery.rescans.insert(id);
            }
        }
        if changed { io.timer(io.now()); }
    }
    fn harnesses(&mut self, list: Vec<Shared<dyn Harness>>) {
        self.harnesses = list;
    }
    fn claim(
        &mut self,
        io: &mut dyn Io,
        process: &Process,
        write: ControlWrite,
        done: Done<Option<ControlTarget>>,
    ) {
        if !self.controls(process) {
            // c1654cc TmuxCoordinator.swift:356-381 begins on any control start.
            let target = self.adopt(process, write, true);
            finish(io, done, Ok(Some(target)));
            return;
        }
        let expected = process.clone();
        self.job(
            io,
            Job::Process { pid: process.pid },
            Box::new(move |mux, io, result| {
                let process = match result {
                    Ok(Output::Process(process))
                        if mux.controls(&process)
                            && process.pid == expected.pid
                            && process.start == expected.start
                            && process.tty == expected.tty
                            && process.group == expected.group
                            && process.executable == expected.executable
                            && process.arguments == expected.arguments =>
                    {
                        process
                    }
                    _ => {
                        finish(io, done, Err(error("Tmux control process changed")));
                        return;
                    }
                };
                let target = mux.adopt(&process, write, false);
                finish(io, done, Ok(Some(target)));
            }),
        );
    }
    /// A claimed stream's event. Data that is not this control stream any more (a re-typed
    /// attach after transport loss) is refused: the client ends and core ends the route.
    fn stream(&mut self, io: &mut dyn Io, id: Id, event: Control) -> Result<(), Error> {
        let id = self.aliases.get(&id).map(|(id, _)| *id).unwrap_or(id);
        // The claimed stream's own client: a backend reopened after it left has spawned
        // clients that this stream's end must not touch.
        let Some(client) = self
            .backends
            .get_mut(&id)
            .and_then(|b| b.clients.iter_mut().find(|c| c.adopted() && !c.ended))
        else {
            // Only data claims to be this stream; an end for an ended stream is no news.
            return match event {
                Control::Data(_) => Err(error("Tmux control stream ended")),
                _ => Ok(()),
            };
        };
        let result = match event {
            Control::Data(bytes) => client.receive(io, &bytes).map_err(error),
            Control::End | Control::Exit(_) => Ok(client.finish(io)),
            Control::Start => Ok(()),
        };
        self.changed |= client.ended;
        io.timer(io.now());
        result
    }
    fn backends(&mut self, io: &mut dyn Io, done: Done<Vec<String>>) {
        let mut command = Command::new(&self.executable);
        command.arg("-V");
        self.run(
            io,
            command,
            Box::new(move |_, io, result| {
                let value = match result {
                    Ok(Output::Exit {
                        status: Some(0),
                        stdout,
                    }) if stdout.starts_with(b"tmux ") => Ok(vec!["tmux".into()]),
                    Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
                    Ok(_) => Ok(Vec::new()),
                    Err(e) => Err(error(e)),
                };
                finish(io, done, value);
            }),
        );
    }
    fn open(&mut self, io: &mut dyn Io, key: &str, done: Done<Id>) {
        self.open(io, key, done);
    }
    fn keys(
        &mut self,
        io: &mut dyn Io,
        terminal: Id,
        process: &Process,
        input: &[Input],
        done: Done<()>,
    ) {
        Tmux::keys(self, io, terminal, process, input, done);
    }
    // Mechanical (core, A2): tmux sizes panes itself; the requested PTY size is not used yet.
    fn create(
        &mut self,
        io: &mut dyn Io,
        parent: Id,
        beside: Option<Id>,
        command: Option<Command>,
        _size: Option<Grid>,
        done: Done<Id>,
    ) {
        Tmux::create(self, io, parent, beside, command, deferred(done));
    }
    // The renderer keeps the captured history (see seek). tmux copy-mode would be invisible to a
    // control client and would swallow every later keystroke, so the app scrolls locally instead.
    fn scroll(&mut self, io: &mut dyn Io, _terminal: Id, _scroll: &Scroll, done: Done<()>) {
        deferred(done)(
            io,
            Err(Error {
                code: "scrollback_app_owned",
                message: String::new(),
            }),
        );
    }
    operations! {
        attach(terminal: Id, size: Grid, takeover: bool) -> ();
        input(terminal: Id, bytes: &[u8]) -> ();
        check(terminal: Id, process: &Process) -> ();
        resize(terminal: Id, size: Grid) -> ();
        screen(terminal: Id, changed: bool) -> Screen;
        close(node: Id, how: Close) -> ();
        idle(node: Id) -> bool;
        focus(node: Id) -> ();
        enable(enabled: bool) -> ();
        rename(node: Id, name: &str) -> ();
        zoom(terminal: Id, zoomed: bool) -> ();
        split(node: Id, ratio: f64) -> ();
    }
    fn r#move(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        parent: Id,
        before: Option<Id>,
        done: Done<()>,
    ) {
        if self
            .backends
            .values()
            .any(|backend| backend.views.contains_key(&node))
        {
            self.placement(io, node, &Place::Before { parent, before }, done);
        } else {
            Tmux::r#move(self, io, node, parent, before, deferred(done));
        }
    }
    fn place(&mut self, io: &mut dyn Io, node: Id, place: &Place, done: Done<()>) {
        if self
            .backends
            .values()
            .any(|backend| backend.views.contains_key(&node))
        {
            self.placement(io, node, place, done);
        } else {
            Tmux::place(self, io, node, place, deferred(done));
        }
    }
    fn publish(&mut self, io: &mut dyn Io, terminal: Id, screen: Screen) {
        if let Some(state) = self.terminals.get_mut(&terminal)
            && state.screen.as_ref() != Some(&screen)
        {
            state.screen = Some(screen.clone());
            state.changed = state.readers.is_empty();
            for done in std::mem::take(&mut state.readers) {
                finish(io, done, Ok(screen.clone()));
            }
        }
    }
    fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) {
        let event = self.endpoints(io, event);
        if let Some(Event::Timer { at }) = &event {
            let resumed = std::mem::take(&mut *self.resumes.borrow_mut());
            for next in resumed {
                next(self, io, true);
            }
            let due: Vec<_> = self
                .changes
                .iter()
                .filter_map(|(id, change)| (change.at <= *at).then_some(*id))
                .collect();
            for id in due {
                let change = self.changes.remove(&id).unwrap();
                let done: Done<()> = Box::new(move |io, result| {
                    for done in change.done {
                        finish(io, done, result.clone());
                    }
                });
                let Some(divider) = self.dividers.get(&id) else {
                    finish(io, done, Err(gone("Tmux divider is no longer available")));
                    continue;
                };
                let change = (f64::from(divider.high - divider.low - 1) * change.ratio).round()
                    as i64
                    - i64::from(divider.first.high - divider.low);
                let size = (i64::from(divider.first.size) + change).max(1);
                let flag = if divider.axis == Axis::Columns {
                    "-x"
                } else {
                    "-y"
                };
                let command = format!("resize-pane -t %{} {flag} {size}", divider.first.pane);
                self.mutate(io, divider.loc, vec![command], 1, done);
            }
        }
        self.windows(io, event.as_ref());
        if let Some(Event::Done { work, result }) = event {
            if let Some(done) = self.jobs.remove(&work) {
                done(self, io, result);
            }
        } else if let Some(event) = event {
            let mut notices = Vec::new();
            let mut failures = Vec::new();
            for (&id, back) in &mut self.backends {
                for (index, client) in back.clients.iter_mut().enumerate() {
                    let ended = client.ended;
                    if let Err(e) = client.event(io, &event) {
                        client.finish(io);
                        // A leaving client's transport failing says nothing about an open
                        // (or reopen) in progress on the same backend.
                        if !client.leaving {
                            let error = error(e);
                            for done in std::mem::take(&mut back.done) {
                                failures.push((done, error.clone()));
                            }
                        }
                    }
                    self.changed |= !ended && client.ended;
                    notices.extend(std::mem::take(&mut client.notices).into_iter().map(|n| {
                        (
                            Location {
                                backend: id,
                                client: index,
                                pane: 0,
                            },
                            n,
                        )
                    }));
                }
            }
            for (done, error) in failures {
                done(self, io, Err(error));
            }
            for (location, notice) in notices {
                match notice {
                    Notice::Attached => {
                        let client = &mut self.backends.get_mut(&location.backend).unwrap().clients
                            [location.client];
                        for command in include_str!("profile.tmux").lines() {
                            if client
                                .commands(io, &[command.into()], 1, &mut None)
                                .is_err()
                            {
                                client.finish(io);
                                break;
                            }
                        }
                        self.refresh(io, location, None);
                    }
                    Notice::Refresh => {
                        let backend = &mut self.backends.get_mut(&location.backend).unwrap();
                        if backend.remote
                            || backend.clients[location.client].creating == 0
                            || !backend.clients[location.client].waiters.is_empty()
                        {
                            self.refresh(io, location, None);
                        } else {
                            backend.clients[location.client].again = true;
                        }
                    }
                    Notice::Reply(done, result) => done(self, io, result),
                    Notice::Output(pane, bytes) => {
                        self.output(io, Location { pane, ..location }, &bytes)
                    }
                    Notice::Notification(line) => self.notification(io, location, &line),
                }
            }
        }
        // Refresh waiters of a client that ended with no read in flight would wait forever.
        let stranded: Vec<_> = self
            .backends
            .values_mut()
            .flat_map(|backend| backend.clients.iter_mut())
            .filter(|client| client.ended && !client.refreshing)
            .flat_map(|client| {
                client.again = false;
                let mut waiters = std::mem::take(&mut client.waiters);
                waiters.append(&mut client.later);
                waiters
            })
            .collect();
        for done in stranded {
            done(self, io, Err(error("Tmux control connection closed")));
        }
        self.observations(io);
        self.discovery.dirty |= self.changed;
        self.topology(io, ui);
        self.retire(io);
        self.discover(io);
        for update in std::mem::take(&mut self.updates) {
            ui.update(update);
        }
        for done in std::mem::take(&mut self.published) {
            finish(io, done, Ok(()));
        }
    }
}
