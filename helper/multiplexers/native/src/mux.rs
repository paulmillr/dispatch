use crate::{
    process::{foreground, owns, same},
    terminal::{Terminal, error},
};
use dispatch_helper_core::{
    api::*,
    json::{self, Data, Value},
};
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet, VecDeque},
    io,
    path::PathBuf,
    process::Command,
    rc::Rc,
};

type Observed = Rc<RefCell<VecDeque<discovery::Observation>>>;
type Probe = Option<(Process, Done<()>)>;

mod closing;
mod control;
mod discovery;
mod jobs;
mod navigation;

enum Pending {
    Directory {
        terminal: Id,
        shell: Process,
    },
    Client {
        terminal: Id,
        process: Process,
    },
    Control {
        terminal: Id,
        step: control::Step,
        done: Done<Process>,
    },
    Close(closing::Check),
    Alive {
        terminal: Id,
        process: Process,
        reply: Option<(Done<()>, Error)>,
    },
    Discover {
        terminal: Id,
        shell: Option<Process>,
    },
    Member {
        terminal: Id,
        shell: Process,
        process: Process,
        remaining: Rc<std::cell::Cell<usize>>,
        members: Rc<RefCell<Vec<Process>>>,
    },
    Child(Id),
    Keys {
        terminal: Id,
        probe: Probe,
    },
    Foreground {
        terminal: Id,
        shell: Process,
        probe: Probe,
    },
    Hook {
        terminal: Option<Id>,
        harness: usize,
        hook: Hook,
        depth: usize,
        agent: Option<Process>,
        event: Event,
    },
}

/// Local terminal processes; layout and rendering stay in the app.
pub struct Native {
    root: Node,
    shell: PathBuf,
    grid: Grid,
    serial: Id,
    terminals: Vec<Terminal>,
    harnesses: Vec<Shared<dyn Harness>>,
    jobs: BTreeMap<Work, Pending>,
    observed: Observed,
    agents: Vec<Id>,
    clients: Vec<(Id, Process)>,
    candidates: Vec<(Id, Option<Process>)>,
    dirty: bool,
    focus: Option<Id>,
    replies: BTreeMap<u64, Option<usize>>,
    watches: BTreeMap<u64, Id>,
    rescans: BTreeSet<Id>,
    mutations: Vec<Box<dyn FnOnce(&mut dyn Io)>>,
}

impl Native {
    pub fn new(shell: PathBuf, directory: PathBuf, grid: Grid) -> Self {
        Self {
            root: Node {
                detached: false, renamed: None,
                tty: None,
                id: 1,
                key: "native".into(),
                parent: None,
                kind: Kind::Workspace,
                name: "Native".into(),
                cwd: Some(directory),
                size: None,
                agent: None,
            },
            shell,
            grid,
            serial: 1,
            terminals: Vec::new(),
            harnesses: Vec::new(),
            jobs: BTreeMap::new(),
            observed: Rc::new(RefCell::new(VecDeque::new())),
            agents: Vec::new(),
            clients: Vec::new(),
            candidates: Vec::new(),
            dirty: false,
            focus: None,
            replies: BTreeMap::new(),
            watches: BTreeMap::new(),
            rescans: BTreeSet::new(),
            mutations: Vec::new(),
        }
    }

    fn terminal(&mut self, id: Id) -> Result<&mut Terminal, Error> {
        self.terminals
            .iter_mut()
            .find(|terminal| terminal.node.id == id && !terminal.closed && !terminal.exited)
            .ok_or_else(|| error("expired", ""))
    }

    fn changed(&mut self, io: &mut dyn Io) {
        self.dirty = true;
        io.timer(io.now());
    }

    fn finish<T: 'static>(&mut self, io: &mut dyn Io, done: Done<T>, result: Result<T, Error>) {
        if self.dirty {
            self.mutations.push(Box::new(move |io| done(io, result)));
            io.timer(io.now());
        } else {
            deferred(done)(io, result);
        }
    }

    fn submit(&mut self, io: &mut dyn Io, job: Job, pending: Pending) {
        match io.submit(job) {
            Ok(work) => {
                self.jobs.insert(work, pending);
            }
            Err(failure) => match pending {
                Pending::Directory { terminal, shell } => {
                    self.discovered(io, terminal, None, Ok(Output::Process(shell)), true);
                }
                Pending::Control { done, .. } => {
                    deferred(done)(io, Err(error("io_failure", failure)))
                }
                Pending::Keys { terminal, probe }
                | Pending::Foreground {
                    terminal, probe, ..
                } => {
                    self.verified(io, terminal, probe, Err(error("io_failure", failure)));
                }
                Pending::Close(check) => deferred(check.done)(io, Err(error("busy", ""))),
                pending @ (Pending::Member { .. } | Pending::Alive { .. }) => {
                    self.complete(io, pending, Err(failure))
                }
                Pending::Discover { terminal, .. } => {
                    if let Ok(t) = self.terminal(terminal) {
                        t.discovering = false;
                    }
                }
                _ => {}
            },
        }
    }

    fn inspect(&mut self, io: &mut dyn Io, id: Id) {
        if let Ok(terminal) = self.terminal(id)
            && !terminal.checking
        {
            terminal.checking = true;
            let pid = terminal.child.pid;
            if let Err(failure) = terminal.interest(io) {
                self.checked(io, id, Err(error("io_failure", failure)));
            } else {
                self.submit(
                    io,
                    Job::Process { pid },
                    Pending::Keys {
                        terminal: id,
                        probe: None,
                    },
                );
            }
        }
    }

    fn verified(&mut self, io: &mut dyn Io, id: Id, probe: Probe, result: Result<(), Error>) {
        if let Some((process, done)) = probe {
            match result {
                Ok(()) => deferred(done)(io, Ok(())),
                Err(failure) => self.submit(
                    io,
                    Job::Process { pid: process.pid },
                    Pending::Alive {
                        terminal: id,
                        process,
                        reply: Some((done, failure)),
                    },
                ),
            }
        } else {
            self.checked(io, id, result);
        }
    }

    fn checked(&mut self, io: &mut dyn Io, id: Id, result: Result<(), Error>) {
        if let Ok(terminal) = self.terminal(id)
            && terminal.checking
        {
            terminal.checking = false;
            let mut finished = match result {
                Ok(()) => terminal.write(io),
                Err(failure) if !terminal.input.is_empty() => vec![terminal.finish(Err(failure))],
                Err(_) => Vec::new(),
            };
            if let Err(failure) = terminal.interest(io) {
                finished.extend(terminal.fail(error("io_failure", failure)));
            }
            for (done, result) in finished {
                deferred(done)(io, result);
            }
        }
    }
}

impl Multiplexer for Native {
    fn invalidate(&mut self, io: &mut dyn Io, process: &Process) {
        for terminal in &self.terminals {
            if !terminal.closed && !terminal.exited
                && terminal.node.agent.as_ref().is_some_and(|(_, binding)| {
                    binding.process.pid == process.pid && binding.process.start == process.start
                })
            {
                self.rescans.insert(terminal.node.id);
                io.timer(io.now());
            }
        }
    }
    fn name(&self) -> &str {
        "native"
    }
    fn control(&mut self, io: &mut dyn Io, terminal: Id, done: Done<Process>) {
        match self.terminal(terminal) {
            Ok(owner) if !owner.closed && !owner.exited => {
                let pid = owner.child.pid;
                self.submit(
                    io,
                    Job::Process { pid },
                    Pending::Control {
                        terminal,
                        step: control::Step::Root,
                        done,
                    },
                );
            }
            _ => deferred(done)(io, Err(error("expired", ""))),
        }
    }

    fn harnesses(&mut self, list: Vec<Shared<dyn Harness>>) {
        self.harnesses = list;
    }

    fn backends(&mut self, io: &mut dyn Io, done: Done<Vec<String>>) {
        deferred(done)(io, Ok(vec![self.root.key.clone()]));
    }

    fn open(&mut self, io: &mut dyn Io, key: &str, done: Done<Id>) {
        let result = if key == self.root.key {
            self.changed(io);
            Ok(self.root.id)
        } else {
            Err(error("backend_unavailable", ""))
        };
        self.finish(io, done, result);
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
        // The requested size is the PTY's before exec (old ssh-helper pty.rs:15-31).
        let grid = size.unwrap_or(self.grid);
        if parent != self.root.id {
            self.finish(io, done, Err(error("destination_unavailable", "")));
            return;
        }
        if let Some(id) = beside
            && let Err(failure) = self.terminal(id)
        {
            self.finish(io, done, Err(failure));
            return;
        }
        let command = command.unwrap_or_else(|| {
            let mut command = Command::new(&self.shell);
            command
                .arg("-l")
                .current_dir(self.root.cwd.as_ref().unwrap());
            command
        });
        let title = command.get_program().to_string_lossy().into_owned();
        let cwd = command
            .get_current_dir()
            .map(PathBuf::from)
            .or_else(|| self.root.cwd.clone());
        let child = match io.spawn(command, Some(grid)) {
            Ok(child) => child,
            Err(failure) => {
                self.finish(io, done, Err(error("io_failure", failure)));
                return;
            }
        };
        self.serial += 1;
        let id = self.serial;
        let pid = child.pid;
        let mut terminal = Terminal {
            node: Node {
                detached: false, renamed: None,
                // The app attributes processes started in this terminal by its PTY device
                // (ssh launches, c1654cc HostCoordinator.accept); integration todo 15.
                tty: child.tty,
                id,
                key: format!("native/{id}"),
                parent: Some(parent),
                kind: Kind::Terminal,
                name: title.clone(),
                cwd,
                size: Some(grid),
                agent: None,
            },
            title,
            reader: child
                .output
                .expect("a PTY spawn provides its output channel"),
            writer: child.input.expect("a PTY spawn provides its input channel"),
            child,
            observed: None,
            control: None,
            client: None,
            screen: None,
            output: Vec::new(),
            group: None,
            members: Vec::new(),
            candidates: Vec::new(),
            retry: None,
            changed: false,
            waiters: Vec::new(),
            input: VecDeque::new(),
            retained: 0,
            checking: false,
            discovering: false,
            scan: None,
            refresh: false,
            attached: false,
            eof: false,
            closed: false,
            exited: false,
        };
        let result = io.child(pid).and_then(|_| terminal.interest(io));
        if let Err(failure) = result {
            let _ = terminal.close(io);
            self.finish(io, done, Err(error("io_failure", failure)));
            return;
        }
        let index = beside
            .and_then(|id| self.terminals.iter().position(|t| t.node.id == id))
            .map_or(self.terminals.len(), |index| index + 1);
        self.terminals.insert(index, terminal);
        if let Ok(watch) = io.observe(pid) {
            self.watches.insert(watch, id);
        }
        self.focus = Some(id);
        self.submit(io, Job::Process { pid }, Pending::Child(id));
        self.changed(io);
        self.finish(io, done, Ok(id));
    }

    fn rename(&mut self, io: &mut dyn Io, node: Id, name: &str, done: Done<()>) {
        let result = if node == self.root.id {
            self.root.name = name.into();
            Ok(())
        } else {
            self.terminal(node).map(|terminal| {
                terminal.node.name = if name.is_empty() {
                    terminal.title.clone()
                } else {
                    name.into()
                };
            })
        };
        if result.is_ok() {
            self.changed(io);
        }
        self.finish(io, done, result);
    }

    fn focus(&mut self, io: &mut dyn Io, node: Id, done: Done<()>) {
        let result = if node == self.root.id || self.terminal(node).is_ok() {
            self.focus = Some(node);
            self.changed(io);
            Ok(())
        } else {
            Err(error("expired", ""))
        };
        self.finish(io, done, result);
    }

    fn r#move(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        parent: Id,
        before: Option<Id>,
        done: Done<()>,
    ) {
        let result = if parent != self.root.id {
            Err(error("destination_unavailable", ""))
        } else if let Some(failure) = before.and_then(|id| self.terminal(id).err()) {
            Err(failure)
        } else if let Some(index) = self
            .terminals
            .iter()
            .position(|t| t.node.id == node && !t.closed && !t.exited)
        {
            let mut terminal = self.terminals.remove(index);
            terminal.node.parent = Some(parent);
            let index = before
                .and_then(|id| self.terminals.iter().position(|t| t.node.id == id))
                .unwrap_or(self.terminals.len());
            self.terminals.insert(index, terminal);
            self.changed(io);
            Ok(())
        } else {
            Err(error("expired", ""))
        };
        self.finish(io, done, result);
    }

    fn split(&mut self, io: &mut dyn Io, _node: Id, _ratio: f64, done: Done<()>) {
        deferred(done)(io, Err(error("layout_app_owned", "")));
    }
    fn zoom(&mut self, io: &mut dyn Io, _terminal: Id, _zoomed: bool, done: Done<()>) {
        deferred(done)(io, Err(error("layout_app_owned", "")));
    }

    fn close(&mut self, io: &mut dyn Io, node: Id, how: Close, done: Done<()>) {
        if how == Close::Prompt {
            self.prompt(io, node, false, done);
            return;
        }
        let mut found = node == self.root.id;
        let mut result = Ok(());
        let mut finished = Vec::new();
        let mut waiters = Vec::new();
        for terminal in self
            .terminals
            .iter_mut()
            .filter(|t| (node == self.root.id || t.node.id == node) && !t.closed && !t.exited)
        {
            found = true;
            if how == Close::Detach {
                terminal.attached = false;
                if let Err(failure) = terminal.interest(io)
                    && result.is_ok()
                {
                    result = Err(error("io_failure", failure));
                }
            } else if let Err(failure) = terminal.close(io) {
                if result.is_ok() {
                    result = Err(error("io_failure", failure));
                }
            } else {
                terminal.screen = None;
                finished.extend(terminal.fail(error("expired", "")));
                waiters.extend(std::mem::take(&mut terminal.waiters));
            }
        }
        for (done, result) in finished {
            self.finish(io, done, result);
        }
        for done in waiters {
            self.finish(io, done, Err(error("expired", "")));
        }
        if found {
            self.changed(io);
        } else {
            result = Err(error("expired", ""));
        }
        self.finish(io, done, result);
    }
    fn idle(&mut self, io: &mut dyn Io, node: Id, done: Done<bool>) {
        self.prompt(
            io,
            node,
            true,
            Box::new(move |io, result| {
                let result = match result {
                    Ok(()) => Ok(true),
                    Err(error) if error.code == "busy" => Ok(false),
                    Err(error) => Err(error),
                };
                done(io, result);
            }),
        );
    }

    fn attach(
        &mut self,
        io: &mut dyn Io,
        terminal: Id,
        size: Grid,
        takeover: bool,
        done: Done<()>,
    ) {
        let mut mutated = false;
        let result = self.terminal(terminal).and_then(|terminal| {
            if terminal.closed || terminal.exited {
                return Err(error("expired", ""));
            }
            if !terminal.attached || takeover {
                io.resize(terminal.writer, size)
                    .map_err(|e| error("io_failure", e))?;
                terminal.node.size = Some(size);
            }
            terminal.attached = true;
            mutated = true;
            terminal.interest(io).map_err(|e| error("io_failure", e))
        });
        if mutated {
            self.changed(io);
        }
        self.finish(io, done, result);
    }

    fn input(&mut self, io: &mut dyn Io, terminal: Id, bytes: &[u8], done: Done<()>) {
        match self.terminal(terminal) {
            Ok(terminal) => match terminal.queue(bytes, None, done) {
                Ok(()) => {
                    if let Err(failure) = terminal.interest(io) {
                        let finished = terminal.fail(error("io_failure", failure));
                        for (done, result) in finished {
                            deferred(done)(io, result);
                        }
                    }
                }
                Err(done) => deferred(done)(io, Err(error("input_unavailable", ""))),
            },
            Err(failure) => deferred(done)(io, Err(failure)),
        }
    }

    fn keys(
        &mut self,
        io: &mut dyn Io,
        terminal: Id,
        process: &Process,
        input: &[Input],
        done: Done<()>,
    ) {
        match self.terminal(terminal) {
            // Typing waits behind queued user input (e.g. a focus report), never behind another typist.
            Ok(owner) if !owner.exited && !owner.closed && owner.input.iter().all(|queued| queued.process.is_none()) => {
                let mut bytes = Vec::new();
                let mut ends = VecDeque::new();
                for part in input {
                    let encoded = Input::bytes(std::slice::from_ref(part));
                    if !encoded.is_empty() {
                        bytes.extend_from_slice(&encoded);
                        ends.push_back(bytes.len());
                    }
                }
                match owner.queue(&bytes, Some(process.clone()), done) {
                    Ok(()) => {
                        // Keep the intents distinct, like Ghostty paste followed by Return.
                        owner.input.back_mut().unwrap().ends = ends;
                        // Behind other input, the writer verifies this entry once it reaches the front.
                        if owner.input.len() == 1 {
                            self.inspect(io, terminal);
                        }
                    }
                    Err(done) => deferred(done)(io, Err(error("input_unavailable", ""))),
                }
            }
            Ok(_) => deferred(done)(io, Err(error("agent_changed", ""))),
            Err(failure) => deferred(done)(io, Err(failure)),
        }
    }

    fn check(&mut self, io: &mut dyn Io, terminal: Id, process: &Process, done: Done<()>) {
        let root = self.terminal(terminal).and_then(|owner| {
            if owner.closed || owner.exited {
                Err(error("expired", ""))
            } else {
                Ok(owner.child.pid)
            }
        });
        match root {
            Ok(pid) => self.submit(
                io,
                Job::Process { pid },
                Pending::Keys {
                    terminal,
                    probe: Some((process.clone(), done)),
                },
            ),
            Err(failure) => deferred(done)(io, Err(failure)),
        }
    }

    fn resize(&mut self, io: &mut dyn Io, terminal: Id, size: Grid, done: Done<()>) {
        let result = self.terminal(terminal).and_then(|terminal| {
            if terminal.closed || terminal.exited {
                return Err(error("expired", ""));
            }
            io.resize(terminal.writer, size)
                .map_err(|e| error("io_failure", e))?;
            terminal.node.size = Some(size);
            Ok(())
        });
        if result.is_ok() {
            self.changed(io);
        }
        self.finish(io, done, result);
    }

    fn external(&self) -> bool {
        Native::external(self)
    }
    fn seek(&mut self, io: &mut dyn Io, terminal: Id, offset: u64, done: Done<()>) {
        Native::seek(self, io, terminal, offset, done);
    }
    fn place(&mut self, io: &mut dyn Io, node: Id, place: &Place, done: Done<()>) {
        Native::place(self, io, node, place, done);
    }
    fn scroll(&mut self, io: &mut dyn Io, _terminal: Id, _scroll: &Scroll, done: Done<()>) {
        deferred(done)(io, Err(error("scrollback_app_owned", "")));
    }

    fn screen(&mut self, io: &mut dyn Io, terminal: Id, changed: bool, done: Done<Screen>) {
        match self.terminal(terminal) {
            Ok(terminal) if !terminal.exited && !terminal.closed => {
                if let Some(screen) = terminal
                    .screen
                    .as_ref()
                    .filter(|_| !changed || terminal.changed)
                {
                    let screen = screen.clone();
                    terminal.changed = false;
                    deferred(done)(io, Ok(screen));
                } else {
                    terminal.waiters.push(done);
                }
            }
            _ => deferred(done)(io, Err(error("expired", ""))),
        }
    }

    fn publish(&mut self, io: &mut dyn Io, terminal: Id, screen: Screen) {
        if let Ok(terminal) = self.terminal(terminal)
            && !terminal.closed
            && !terminal.exited
            && terminal.screen.as_ref() != Some(&screen)
        {
            terminal.screen = Some(screen);
            terminal.changed = true;
            io.timer(io.now());
        }
    }

    fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) {
        match event {
            Event::Process { watch, .. } => {
                if let Some(&id) = self.watches.get(&watch) {
                    if let Ok(terminal) = self.terminal(id) {
                        terminal.group = None;
                        terminal.members.clear();
                    }
                    self.discover(io, id);
                }
            }
            Event::Timer { at } => {
                let mut ready = Vec::new();
                for terminal in &mut self.terminals {
                    let bound = terminal.node.agent.as_ref().is_some_and(|(_, binding)| {
                        terminal
                            .candidates
                            .iter()
                            .any(|process| same(process, &binding.process))
                    });
                    if terminal.closed || terminal.exited || bound {
                        terminal.retry = None;
                        continue;
                    }
                    if let Some((deadline, remaining, delay)) = terminal.retry
                        && deadline <= at
                    {
                        ready.push(terminal.node.id);
                        terminal.retry = if remaining > 1 {
                            let delay = delay * 2;
                            let next = io.now() + delay;
                            io.timer(next);
                            Some((next, remaining - 1, delay))
                        } else {
                            None
                        };
                    }
                }
                for id in ready {
                    self.discover(io, id);
                }
            }
            Event::Done { work, result } => {
                if let Some(pending) = self.jobs.remove(&work) {
                    self.complete(io, pending, result);
                }
            }
            Event::Ready { fd, read, write } => {
                if let Some(index) = self
                    .terminals
                    .iter()
                    .position(|t| !t.closed && !t.exited && (t.reader == fd || t.writer == fd))
                {
                    let terminal = &mut self.terminals[index];
                    if read && fd == terminal.reader && !terminal.eof {
                        if terminal.read(io, ui) && !terminal.refresh {
                            terminal.refresh = true;
                            io.timer(terminal.scan.unwrap_or_else(|| io.now()));
                        }
                    }
                    if write && fd == terminal.writer {
                        if !terminal.checking
                            && terminal
                                .input
                                .front()
                                .is_some_and(|input| input.process.is_some())
                        {
                            let id = terminal.node.id;
                            self.inspect(io, id);
                        } else if !terminal.checking {
                            let finished = terminal.write(io);
                            for (done, result) in finished {
                                deferred(done)(io, result);
                            }
                        }
                    }
                }
            }
            Event::Exit { pid, status } => {
                if let Some(index) = self
                    .terminals
                    .iter()
                    .position(|t| t.child.pid == pid && !t.exited)
                {
                    let mut terminal = self.terminals.remove(index);
                    if let Some((&watch, _)) =
                        self.watches.iter().find(|(_, id)| **id == terminal.node.id)
                    {
                        self.watches.remove(&watch);
                        io.unobserve(watch);
                    }
                    self.rescans.remove(&terminal.node.id);
                    terminal.flush(ui);
                    terminal.exited = true;
                    if self.focus == Some(terminal.node.id) {
                        self.focus = self
                            .terminals
                            .iter()
                            .find(|t| !t.closed && !t.exited)
                            .map(|t| t.node.id);
                    }
                    let _ = terminal.close(io);
                    terminal.node.agent = None;
                    let id = terminal.node.id;
                    let finished = terminal.fail(error("expired", ""));
                    let waiters = std::mem::take(&mut terminal.waiters);
                    ui.update(Update::Exit {
                        terminal: id,
                        status,
                    });
                    for (done, result) in finished {
                        deferred(done)(io, result);
                    }
                    for done in waiters {
                        deferred(done)(io, Err(error("expired", "")));
                    }
                    self.changed(io);
                }
            }
            Event::Hook {
                peer,
                route,
                message,
                reply,
            } => {
                if let Some(reply) = reply {
                    self.replies.entry(reply).or_insert(None);
                }
                if let Ok(doc) = Json::parse(&message) {
                    for harness in 0..self.harnesses.len() {
                        let hook = self.harnesses[harness].borrow_mut().hook(&doc);
                        if let Ok(hook) = hook
                            && (!hook.interactive || reply.is_some())
                            && let Some(pid) = peer.or(hook.pid)
                        {
                            self.submit(
                                io,
                                Job::Process { pid },
                                Pending::Hook {
                                    terminal: None,
                                    harness,
                                    hook,
                                    depth: 0,
                                    agent: None,
                                    event: Event::Hook {
                                        peer,
                                        route,
                                        message: message.clone(),
                                        reply,
                                    },
                                },
                            );
                        }
                    }
                }
            }
            Event::Closed { reply } => {
                if let Some(Some(harness)) = self.replies.remove(&reply) {
                    self.harnesses[harness]
                        .borrow_mut()
                        .event(io, ui, Event::Closed { reply });
                }
            }
            Event::Changed { .. } => {}
        }
        let hooks = self.observations(io);
        let mut screens = Vec::new();
        for terminal in &mut self.terminals {
            if terminal.changed
                && let Some(screen) = &terminal.screen
                && !terminal.waiters.is_empty()
            {
                for done in std::mem::take(&mut terminal.waiters) {
                    screens.push((done, screen.clone()));
                }
                terminal.changed = false;
            }
        }
        for (done, screen) in screens {
            deferred(done)(io, Ok(screen));
        }
        if std::mem::take(&mut self.dirty) {
            let mut nodes = vec![self.root.clone()];
            nodes.extend(
                self.terminals
                    .iter()
                    .filter(|t| !t.closed)
                    .map(|t| t.node.clone()),
            );
            ui.update(Update::Topology {
                key: None,
                focus: self.focus,
                backend: self.root.id,
                nodes,
                layouts: Vec::new(),
            });
        }
        // Every mutation reply runs after this event published the matching topology.
        for callback in std::mem::take(&mut self.mutations) {
            io.defer(callback);
        }
        for terminal in std::mem::take(&mut self.agents) {
            if self
                .terminal(terminal)
                .is_ok_and(|t| !t.closed && !t.exited)
            {
                ui.update(Update::Agent {
                    terminal,
                    summary: Summary::default(),
                });
            }
        }
        for (terminal, process) in std::mem::take(&mut self.candidates) {
            ui.update(Update::Candidate { terminal, process });
        }
        for (terminal, process) in std::mem::take(&mut self.clients) {
            if self
                .terminal(terminal)
                .is_ok_and(|t| !t.closed && !t.exited)
            {
                ui.update(Update::Client { terminal, process });
            }
        }
        let ready: Vec<_> = self
            .rescans
            .iter()
            .copied()
            .filter(|id| {
                self.terminals
                    .iter()
                    .any(|terminal| terminal.node.id == *id && !terminal.discovering)
            })
            .collect();
        for id in ready {
            self.rescans.remove(&id);
            if let Ok(terminal) = self.terminal(id) {
                terminal.group = None;
                terminal.members.clear();
            }
            self.discover(io, id);
        }
        let ready: Vec<_> = self
            .terminals
            .iter()
            .filter(|terminal| {
                terminal.refresh
                    && !terminal.discovering
                    && !terminal.closed
                    && !terminal.exited
                    && terminal.scan.is_none_or(|deadline| deadline <= io.now())
            })
            .map(|terminal| terminal.node.id)
            .collect();
        for id in ready {
            self.discover(io, id);
        }
        for terminal in &mut self.terminals {
            terminal.flush(ui);
        }
        for (harness, event) in hooks {
            if let Event::Hook {
                reply: Some(reply), ..
            } = &event
            {
                let Some(destination) = self.replies.get_mut(reply) else {
                    // The stream closed while process identification was pending.
                    continue;
                };
                *destination = Some(harness);
            }
            self.harnesses[harness].borrow_mut().event(io, ui, event);
        }
    }
}
