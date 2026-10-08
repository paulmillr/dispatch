//! The original SSH login terminal and the auxiliary bus share one reactor and PTY owner.
use super::*;
use crate::system::{queue::Queue, renderer};
use std::process::Command;

pub(crate) type SharedLogin = Rc<RefCell<Login>>;

impl DispatchHelper {
    pub(crate) fn allowed(&self, method: &str) -> bool {
        permits(&self.permissions, required(method))
    }
}

pub(crate) fn permits(grants: &Rc<RefCell<Option<BTreeSet<String>>>>, capability: &str) -> bool {
    capability.is_empty()
        || grants
            .borrow()
            .as_ref()
            .is_none_or(|grants| grants.contains(capability))
}

pub(crate) fn required(method: &str) -> &'static str {
    let capability = match method {
        "hello" | "echo" | "permissions.reduce" => "",
        "plugins.reset" => "stats.sample",
        "files.text" | "files.read" => "file.text",
        "installation.install" | "installation.audit" => "hooks.configure",
        // Public agent keys need submission authority; internal process-checked keys also
        // carry an admitted multiplexer controller's protocol, independently of Chat.
        "terminals.keys" => "agent.submit",
        "chat.open" | "chat.state" | "chat.page" | "chat.models" | "chat.settings"
        | "chat.tools" | "queue.list" | "launches.list" => "agent.inspect",
        method if method.starts_with("stats.") => "stats.sample",
        method
            if method.starts_with("chat.")
                || method.starts_with("queue.")
                || method.starts_with("interactions.") =>
        {
            "agent.submit"
        }
        _ => "backend.register",
    };
    capability
}

pub(crate) struct Login {
    pub terminal: Option<Id>,
    pub process: Option<Process>,
    pending: u32,
    pub started: bool,
    pub identity_job: Work,
    read: RawFd,
    write: RawFd,
    signals: RawFd,
    _raw: Option<renderer::native::Raw>,
    output: Queue,
    input: bool,
    pub(super) closing: bool,
    closed: bool,
    detached: bool,
    parent: u32,
    lost: bool,
    status: Option<i32>,
    pub(crate) failure: Option<Error>,
    grid: Grid,
    control: Option<(Shared<dyn Multiplexer>, Id, usize)>,
    checking: bool,
    retry: bool,
}

impl Login {
    pub fn new(system: &mut System) -> io::Result<SharedLogin> {
        let (raw, grid) = system.terminal()?;
        // SIGHUP/SIGTERM close; SIGINT/SIGQUIT go to the PTY foreground; SIGWINCH resizes.
        let signals = system.signals(&[1, 2, 3, 15, 28], false)?;
        let (read, write) = system.stdio()?;
        let parent = system.parent("login")?;
        system.interest(signals, true, false)?;
        let identity_job = system.submit(Job::Native {
            name: "host.identity",
            input: b"{}".to_vec(),
        })?;
        Ok(Rc::new(RefCell::new(Self {
            terminal: None,
            process: None,
            pending: 0,
            started: false,
            identity_job,
            read,
            write,
            signals,
            _raw: raw,
            output: Queue::new(1_048_576),
            input: false,
            closing: false,
            closed: false,
            detached: false,
            parent,
            lost: false,
            status: None,
            failure: None,
            grid,
            control: None,
            checking: false,
            retry: false,
        })))
    }

    pub fn start(
        owner: &SharedLogin,
        io: &mut dyn Io,
        mux: Shared<dyn Multiplexer>,
        index: usize,
        key: String,
        command: Option<Command>,
    ) {
        let owner = owner.clone();
        let next = mux.clone();
        mux.borrow_mut().open(
            io,
            &key,
            deferred(Box::new(move |io, result| {
                let parent = match result {
                    Ok(parent) => parent,
                    Err(error) => {
                        owner.borrow_mut().failure = Some(error);
                        return;
                    }
                };
                let mux = next.clone();
                next.borrow_mut().create(
                    io,
                    parent,
                    None,
                    command,
                    None,
                    deferred(Box::new(move |io, result| {
                        let terminal = match result {
                            Ok(terminal) => terminal,
                            Err(error) => {
                                owner.borrow_mut().failure = Some(error);
                                return;
                            }
                        };
                        owner.borrow_mut().terminal =
                            Some(crate::dispatch::reference(index, terminal));
                        let size = owner.borrow().grid;
                        {
                            let mut state = owner.borrow_mut();
                            state.control = Some((mux.clone(), terminal, index));
                            state.retry = true;
                        }
                        Self::check(&owner, io);
                        mux.borrow_mut().attach(
                            io,
                            terminal,
                            size,
                            false,
                            deferred(Box::new(move |_, result| {
                                if let Err(error) = result {
                                    owner.borrow_mut().failure = Some(error);
                                }
                            })),
                        );
                    })),
                );
            })),
        );
    }

    pub fn check(owner: &SharedLogin, io: &mut dyn Io) {
        let request = {
            let mut state = owner.borrow_mut();
            if state.checking || !state.retry {
                return;
            }
            state.retry = false;
            let Some(request) = state.control.clone() else {
                return;
            };
            state.checking = true;
            request
        };
        let owner = owner.clone();
        let previous = io.section(&format!("mux/{}", request.2));
        request.0.borrow_mut().control(
            io,
            request.1,
            deferred(Box::new(move |io, result| {
                let mut state = owner.borrow_mut();
                state.checking = false;
                match result {
                    Ok(value) => {
                        state.process = Some(value);
                        state.started = true;
                        state.control = None;
                        state.interrupt(io);
                    }
                    Err(error) if error.code == "control_process_unavailable" => {}
                    // Startup observation may finish after a short-lived shell exits.
                    // Only an actual pending control action needs this lookup to succeed.
                    Err(_) if state.pending == 0 => {}
                    Err(error) => state.failure = Some(error),
                }
            })),
        );
        io.section(&previous);
    }

    fn interrupt(&mut self, io: &mut dyn Io) {
        let Some(process) = &self.process else {
            return;
        };
        for signal in [2, 3] {
            if self.pending & 1 << signal != 0 {
                // Old os::signal_foreground was best effort, including an exited group.
                let _ = io.signal(process.pid, signal);
            }
        }
        self.pending = 0;
    }

    pub fn update(&mut self, terminal: Option<Id>, update: &Update) {
        if terminal != self.terminal || terminal.is_none() {
            return;
        }
        match update {
            Update::Output { bytes, .. } if self.status.is_none() && !self.lost => {
                self.retry |= !self.started && !bytes.is_empty();
                if self.output.push(bytes.clone()).is_err() {
                    self.failure = Some(Error {
                        code: "too_large",
                        message: "Login output exceeded its admitted buffer".into(),
                    });
                }
            }
            Update::Exit { status, .. } => self.status = Some(status.unwrap_or(255)),
            _ => {}
        }
    }

    pub fn ready(&self, io: &mut dyn Io) -> io::Result<Option<i32>> {
        if self.detached { return Ok(None); }
        if let Some(error) = &self.failure {
            return Err(io::Error::other(error.message.clone()));
        }
        if self.status.is_some() && (self.lost || self.output.front().is_none()) {
            return Ok(self.status);
        }
        io.interest(
            self.read,
            self.terminal.is_some() && self.status.is_none() && !self.input && !self.closing,
            false,
        )?;
        io.interest(self.write, false, !self.lost && self.output.front().is_some())?;
        Ok(None)
    }

    pub fn detach(&mut self, io: &mut System) -> io::Result<()> {
        self._raw.take();
        for fd in [self.read, self.write, self.signals] { io.close(fd); }
        io.detach()?;
        self.detached = true;
        Ok(())
    }

    pub fn paused(&self) -> bool {
        !self.lost && self.output.space() < 65_536
    }

    pub fn event(
        owner: &SharedLogin,
        io: &mut System,
        event: &Event,
        parts: &[Shared<dyn Multiplexer>],
    ) -> io::Result<bool> {
        let mut state = owner.borrow_mut();
        if state.detached { return Ok(false); }
        let parent = matches!(event, Event::Exit { pid, .. } if *pid == state.parent);
        let (fd, read, write) = match *event {
            Event::Ready { fd, read, write } => (fd, read, write),
            _ if parent => (state.read, false, false),
            _ => return Ok(false),
        };
        let Some(terminal) = state.terminal else {
            return Ok(false);
        };
        let mux = &parts[(terminal >> 48) as usize];
        let id = crate::dispatch::local(terminal);
        let lost = |error: &io::Error| error.raw_os_error() == Some(5)
            || matches!(error.kind(), io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset);
        if parent {
            state.lost = true;
            state.closing = true;
        } else if state.lost && (fd == state.read || fd == state.write) {
            io.interest(fd, false, false)?;
        } else if fd == state.signals {
            let mut bytes = [0; 4];
            let count = io.read(state.signals, &mut bytes)?;
            if count != bytes.len() {
                return Err(io::ErrorKind::InvalidData.into());
            }
            let flags = u32::from_le_bytes(bytes);
            if flags & (1 << 1 | 1 << 15) != 0 {
                state.closing = true;
                state.lost = true;
            }
            // Output may arrive before control's process observation completes.
            state.pending |= flags & (1 << 2 | 1 << 3);
            state.retry |= state.process.is_none() && state.pending != 0;
            state.interrupt(io);
            if flags & 1 << 28 != 0 {
                let size = io.grid()?;
                let owner = owner.clone();
                mux.borrow_mut().resize(
                    io,
                    id,
                    size,
                    deferred(Box::new(move |_, result| {
                        if let Err(error) = result {
                            owner.borrow_mut().failure = Some(error);
                        }
                    })),
                );
            }
        } else if fd == state.read && read {
            let mut bytes = [0; 65_536];
            match io.read(fd, &mut bytes) {
                Ok(0) => { state.closing = true; state.lost = true; }
                Ok(count) => {
                    state.input = true;
                    let owner = owner.clone();
                    mux.borrow_mut().input(
                        io,
                        id,
                        &bytes[..count],
                        deferred(Box::new(move |_, result| {
                            let mut state = owner.borrow_mut();
                            state.input = false;
                            if let Err(error) = result
                                && !(state.closing && error.code == "expired")
                            {
                                state.failure = Some(error);
                            }
                        })),
                    );
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) => {}
                Err(error) if lost(&error) => { state.closing = true; state.lost = true; }
                Err(error) => return Err(error),
            }
        } else if fd == state.write && write {
            if let Some(bytes) = state.output.front() {
                match io.write(fd, bytes) {
                    Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                    Ok(count) => state
                        .output
                        .consume(count)
                        .map_err(|_| io::ErrorKind::InvalidData)?,
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                        ) => {}
                    Err(error) if lost(&error) => { state.closing = true; state.lost = true; }
                    Err(error) => return Err(error),
                }
            }
        } else {
            return Ok(false);
        }
        if state.closing && !state.closed && state.status.is_none() {
            state.closed = true;
            state.input = true;
            let owner = owner.clone();
            mux.borrow_mut().close(
                io,
                id,
                Close::Terminate,
                deferred(Box::new(move |_, result| {
                    if let Err(error) = result {
                        owner.borrow_mut().failure = Some(error);
                    }
                })),
            );
        }
        Ok(true)
    }
}

/// SSH grant corresponding to a registered multiplexer.
pub(crate) fn mux(name: &str) -> &'static str {
    match name { "tmux" => "tmux.pane", "herdr" => "herdr.rpc", _ => "" }
}
