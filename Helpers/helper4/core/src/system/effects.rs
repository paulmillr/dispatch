//! System effects, including exact test-only replay outcomes.
use super::*;
use crate::json::Data;

impl Io for System {
    fn observe(&mut self, pid: u32) -> io::Result<u64> {
        let args = pid.to_string();
        if let Some(result) = self.replay("process.observe", &args) {
            return result.and_then(|v| {
                v.try_into()
                    .map(u64::from_le_bytes)
                    .map_err(|_| file::invalid())
            });
        }
        let id = self
            .serial
            .checked_add(1)
            .ok_or(io::ErrorKind::OutOfMemory)?;
        let result = (|| {
            if self.processes.is_none() {
                self.processes = Some(observe::Observer::new(&self.reactor, self.capacity)?);
            }
            match self.processes.as_mut().unwrap().set(id, pid, &self.section) {
                Err(error) if error.raw_os_error() == Some(3) => {
                    // Exit may precede registration. Report that invalidation once
                    // instead of losing it between inspection and observation.
                    self.ready
                        .push_back((self.section.clone(), Event::Process { watch: id, pid }));
                    Ok(())
                }
                result => result,
            }
        })();
        self.record("process.observe", &args, &result, &id.to_le_bytes())?;
        result?;
        self.serial = id;
        Ok(id)
    }
    fn unobserve(&mut self, id: u64) {
        if self.ignored("process.unobserve", &id.to_string()) {
            return;
        }
        if let Some(processes) = &mut self.processes {
            processes.remove(id);
        }
        self.ready
            .retain(|(_, event)| !matches!(event, Event::Process { watch, .. } if *watch == id));
        if let Err(error) = self.record("process.unobserve", &id.to_string(), &Ok(()), &[]) {
            self.failure.borrow_mut().get_or_insert(error);
        }
    }
    fn datagram(&mut self, path: &Path, bytes: &[u8]) -> io::Result<()> {
        let args = if self.capture.tracing() {
            format!("{} {}", path.display(), capture::hex(bytes))
        } else {
            String::new()
        };
        if let Some(result) = self.replay("datagram", &args) {
            return result.map(|_| ());
        }
        let result = (|| {
            let socket = std::os::unix::net::UnixDatagram::unbound()?;
            socket.set_nonblocking(true)?;
            socket.connect(path)?;
            if socket.send(bytes)? != bytes.len() {
                return Err(io::ErrorKind::WriteZero.into());
            }
            Ok(())
        })();
        self.record("datagram", &args, &result, &[])?;
        result
    }
    fn random(&mut self, bytes: &mut [u8]) -> io::Result<()> {
        if let Some(result) = self.replay("random", &bytes.len().to_string()) {
            let data = result?;
            if data.len() != bytes.len() {
                return Err(file::invalid());
            }
            bytes.copy_from_slice(&data);
            return Ok(());
        }
        let result = random(bytes);
        self.record("random", &bytes.len().to_string(), &result, bytes)?;
        result
    }
    fn section(&mut self, name: &str) -> String {
        std::mem::replace(&mut self.section, name.into())
    }
    fn defer(&mut self, callback: Box<dyn FnOnce(&mut dyn Io)>) {
        self.callbacks.push_back((self.section.clone(), callback));
    }
    fn after(&mut self, at: Instant, callback: Box<dyn FnOnce(&mut dyn Io)>) -> io::Result<()> {
        self.later.push((at, self.section.clone(), callback));
        let owner = Io::section(self, "after");
        self.timer(at);
        Io::section(self, &owner);
        Ok(())
    }
    fn read(&mut self, fd: RawFd, bytes: &mut [u8]) -> io::Result<usize> {
        self.consumed(fd);
        let args = format!("{fd} {}", bytes.len());
        if let Some(replay) = &self.capture.replay {
            let result = replay.stream(&self.section, "read", fd, bytes);
            if let Err(error) = &result {
                self.failure
                    .borrow_mut()
                    .get_or_insert_with(|| io::Error::new(error.kind(), error.to_string()));
            }
            return result?;
        }
        let result = if let Some(signals) = self.signals.get(&fd) {
            if bytes.len() < 4 {
                Err(io::ErrorKind::InvalidInput.into())
            } else {
                signals.take().map(|flags| {
                    bytes[..4].copy_from_slice(&flags.to_le_bytes());
                    4
                })
            }
        } else {
            self.descriptors
                .get_mut(&fd)
                .ok_or_else(|| io::ErrorKind::NotFound.into())
                .and_then(|file| file.read(bytes))
        };
        let data = result.as_ref().map_or(&[][..], |&count| &bytes[..count]);
        self.record("read", &args, &result, data)?;
        if matches!(&result, Ok(0))
            || result
                .as_ref()
                .err()
                .is_some_and(|e| e.raw_os_error() == Some(5))
        {
            self.reactor.interest(self.source(fd), false, false)?;
        }
        result
    }
    fn write(&mut self, fd: RawFd, bytes: &[u8]) -> io::Result<usize> {
        self.consumed(fd);
        let args = if self.capture.tracing() {
            format!("{fd} len={}", bytes.len())
        } else {
            String::new()
        };
        if let Some(replay) = self.capture.replay.as_ref() {
            let result = replay.write(&self.section, fd, bytes);
            if let Err(error) = &result {
                self.failure
                    .borrow_mut()
                    .get_or_insert_with(|| io::Error::new(error.kind(), error.to_string()));
            }
            return result.and_then(|done| done.result).and_then(|output| {
                let Output::Bytes(bytes) = output else {
                    return Err(file::invalid());
                };
                bytes
                    .try_into()
                    .map(u64::from_le_bytes)
                    .map_err(|_| file::invalid())?
                    .try_into()
                    .map_err(|_| file::invalid())
            });
        }
        let result = self
            .descriptors
            .get_mut(&fd)
            .ok_or_else(|| io::ErrorKind::NotFound.into())
            .and_then(|file| file.write(bytes));
        let data = result.as_ref().map_or(&[][..], |&count| &bytes[..count]);
        self.record("write", &args, &result, data)?;
        result
    }
    fn accept(&mut self, fd: RawFd) -> io::Result<RawFd> {
        self.consumed(fd);
        if let Some(result) = self.replay("accept", &fd.to_string()) {
            return result.and_then(|v| {
                v.try_into()
                    .map(i32::from_le_bytes)
                    .map_err(|_| file::invalid())
            });
        }
        let result = self
            .listeners
            .get(&fd)
            .ok_or_else(|| io::ErrorKind::NotFound.into())
            .and_then(|listener| listener.listener.accept())
            .and_then(|(stream, _)| self.adopt(stream.into_raw_fd()));
        let data = result
            .as_ref()
            .map(|fd| fd.to_le_bytes().to_vec())
            .unwrap_or_default();
        self.record("accept", &fd.to_string(), &result, &data)?;
        result
    }
    fn close(&mut self, fd: RawFd) {
        self.consumed(fd);
        if self.ignored("close", &fd.to_string()) {
            return;
        }
        let result = self.dispose(fd);
        if let Err(error) = self.record("close", &fd.to_string(), &result, &[]) {
            self.failure.borrow_mut().get_or_insert(error);
        }
        if let Err(error) = result {
            self.failure.borrow_mut().get_or_insert(error);
        }
    }
    fn interest(&mut self, fd: RawFd, read: bool, write: bool) -> io::Result<()> {
        self.consumed(fd);
        let args = format!("{fd} {read} {write}");
        if let Some(result) = self.replay("interest", &args) {
            return result.map(|_| ());
        }
        self.sections
            .entry(fd)
            .or_insert_with(|| self.section.clone());
        let result = self.reactor.interest(self.source(fd), read, write);
        self.record("interest", &args, &result, &[])?;
        result
    }
    fn child(&mut self, pid: u32) -> io::Result<()> {
        if let Some(result) = self.replay("child", &pid.to_string()) {
            return result.map(|_| ());
        }
        let result = if self.children.contains_key(&pid) {
            Ok(())
        } else {
            Err(io::ErrorKind::NotFound.into())
        };
        self.record("child", &pid.to_string(), &result, &[])?;
        result
    }
    fn terminate(&mut self, pid: u32) -> io::Result<()> {
        if let Some(result) = self.replay("terminate", &pid.to_string()) {
            return result.map(|_| ());
        }
        let result = (|| {
            let child = self.children.get(&pid).ok_or(io::ErrorKind::NotFound)?;
            if child.section != self.section {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            // A status means the child was already reaped; its PID may be reused.
            if child.status.is_some() {
                return Ok(());
            }
            native::end(pid)
        })();
        self.record("terminate", &pid.to_string(), &result, &[])?;
        result
    }

    fn signal(&mut self, pid: u32, signal: i32) -> io::Result<()> {
        let args = format!("{pid} {signal}");
        if let Some(result) = self.replay("signal", &args) {
            return result.map(|_| ());
        }
        let result = (|| {
            let child = self.children.get(&pid).ok_or(io::ErrorKind::NotFound)?;
            if !child.pty || child.status.is_some() {
                return Err(io::ErrorKind::NotFound.into());
            }
            let fd = child.channels[0].ok_or(io::ErrorKind::NotFound)?;
            native::interrupt(self.source(fd), signal)
        })();
        self.record("signal", &args, &result, &[])?;
        result
    }

    fn timer(&mut self, at: Instant) {
        let result = (|| {
            if let Some(replay) = &self.capture.replay {
                // Old traces omitted expiry. Keep immediate wakeups, never invent a future action.
                if !replay.timed {
                    return Ok((at <= self.now()).then_some(at));
                }
                let Output::Bytes(bytes) = replay.call(&self.section, "timer", "")?.result? else {
                    return Err(file::invalid());
                };
                let offset = u64::from_le_bytes(bytes.try_into().map_err(|_| file::invalid())?);
                return replay
                    .origin
                    .checked_add(Duration::from_nanos(offset))
                    .map(Some)
                    .ok_or_else(file::invalid);
            }
            let bytes = self.capture.offset(at)?.to_le_bytes().to_vec();
            self.capture
                .result(&self.section, "timer", "", &Ok(Output::Bytes(bytes)))?;
            Ok(Some(at))
        })();
        match result {
            Ok(Some(at)) => {
                self.timers.insert((at, self.section.clone()));
            }
            Ok(None) => {}
            Err(error) => {
                self.failure.borrow_mut().get_or_insert(error);
            }
        }
    }
    fn pid(&self) -> u32 {
        self.pid
    }
    fn now(&self) -> Instant {
        if let Some(replay) = &self.capture.replay
            && replay.timed
        {
            let result = (|| {
                let Output::Bytes(bytes) = replay.call(&self.section, "now", "")?.result? else {
                    return Err(file::invalid());
                };
                let offset = u64::from_le_bytes(bytes.try_into().map_err(|_| file::invalid())?);
                replay
                    .origin
                    .checked_add(Duration::from_nanos(offset))
                    .ok_or_else(file::invalid)
            })();
            return match result {
                Ok(at) => at,
                Err(error) => {
                    self.failure.borrow_mut().get_or_insert(error);
                    replay.clock.get()
                }
            };
        }
        let at = Instant::now();
        if self.capture.enabled()
            && let Ok(offset) = self.capture.offset(at)
        {
            // Capture's writer marks overflow invalid; the native clock itself cannot fail.
            let _ = self.capture.result(
                &self.section,
                "now",
                "",
                &Ok(Output::Bytes(offset.to_le_bytes().to_vec())),
            );
        }
        at
    }
    fn submit(&mut self, mut job: Job) -> io::Result<Work> {
        let id = self
            .serial
            .checked_add(1)
            .ok_or(io::ErrorKind::OutOfMemory)?;
        let order = self.files.order(&self.section);
        let args = if !self.capture.tracing() {
            String::new()
        } else {
            match &job {
                Job::MakeDir { path, mode } => format!("mkdir {path:?} {mode}"),
                Job::Remove {
                    path,
                    expected: Expected::Any,
                } => format!("remove {path:?}"),
                Job::Remove { path, expected } => format!("remove {path:?} {expected:?}"),
                Job::List { path } => format!("list {path:?}"),
                Job::Read {
                    path,
                    offset,
                    length,
                } => format!("read {path:?} {offset} {length}"),
                Job::Stat { path, follow } => format!("stat {path:?} {follow}"),
                // Unchecked jobs keep their old argument text, so older traces still replay.
                Job::Write {
                    path,
                    bytes,
                    mode,
                    expected: Expected::Any,
                } => format!("write {path:?} {mode} {}", capture::hex(bytes)),
                Job::Write {
                    path,
                    bytes,
                    mode,
                    expected,
                } => format!("write {path:?} {mode} {expected:?} {}", capture::hex(bytes)),
                Job::Native { name, input } => format!("native {name} {}", capture::hex(input)),
                Job::Isolated { name, input, .. } => {
                    format!("isolated {name} {}", capture::hex(input))
                }
                Job::Process { pid } => format!("process {pid}"),
                Job::Lock { path, .. } => format!("lock {path:?}"),
                Job::Run { command, input, .. } => {
                    format!("run {command:?} input={}", capture::hex(input))
                }
            }
        };
        if let Some(replay) = &self.capture.replay {
            let work = match replay.call(&self.section, "submit", &args) {
                Ok(completion) => {
                    let Output::Bytes(bytes) = completion.result? else {
                        return Err(file::invalid());
                    };
                    u64::from_le_bytes(bytes.try_into().map_err(|_| file::invalid())?)
                }
                Err(error) => {
                    self.failure.borrow_mut().get_or_insert(error);
                    id
                }
            };
            self.serial = self.serial.max(work);
            self.files.admit(&self.section);
            self.jobs
                .insert(work, (self.section.clone(), Some((order, args))));
            return Ok(work);
        }
        let result = (|| {
            // Pin a borrowed peer socket before a worker can observe a reused fd number.
            // Capture args above retain the caller's fd, not the private duplicate.
            let pin = if let Job::Native {
                name: "peer",
                input,
            } = &mut job
            {
                use crate::json::{Data, Json};
                let document = Json::parse(input).map_err(|_| io::ErrorKind::InvalidInput)?;
                let fd = document
                    .root()
                    .get("fd")
                    .and_then(|v| v.signed())
                    .and_then(|v| i32::try_from(v).ok())
                    .filter(|fd| *fd >= 0)
                    .ok_or(io::ErrorKind::InvalidInput)?;
                // SAFETY: no intervening callback can close this descriptor on the reactor thread.
                let pin = unsafe { BorrowedFd::borrow_raw(fd) }.try_clone_to_owned()?;
                *input = crate::json::write(&Data::Object(vec![(
                    "fd",
                    Data::Signed(pin.as_raw_fd().into()),
                )]))
                .map_err(|_| io::ErrorKind::InvalidInput)?;
                Some(pin)
            } else {
                None
            };
            self.workers
                .submit(id, move || {
                    let _pin = pin;
                    match job {
                        Job::Lock { path, deadline } => {
                            match super::native::advisory(&path, deadline) {
                                Ok(file) => file::Completion {
                                    sequence: None,
                                    result: Ok(Output::Locked),
                                    held: Some(file),
                                },
                                Err(error) => file::Completion {
                                    sequence: None,
                                    result: Err(error),
                                    held: None,
                                },
                            }
                        }
                        job => file::Completion {
                            sequence: None,
                            result: execute(job),
                            held: None,
                        },
                    }
                })
                .map_err(|error| {
                    io::Error::new(
                        match error {
                            work::Rejected::Full => io::ErrorKind::WouldBlock,
                            work::Rejected::Duplicate => io::ErrorKind::AlreadyExists,
                            work::Rejected::Closed => io::ErrorKind::BrokenPipe,
                        },
                        format!("worker rejected job {id}: {error:?}"),
                    )
                })
        })();
        self.record("submit", &args, &result, &id.to_le_bytes())?;
        result?;
        self.serial = id;
        self.files.admit(&self.section);
        self.jobs
            .insert(id, (self.section.clone(), Some((order, args))));
        Ok(id)
    }
    fn then(&mut self, work: Work, callback: Box<dyn FnOnce(&mut dyn Io, io::Result<Output>)>) {
        self.continued
            .insert(work, (self.section.clone(), callback));
    }
    fn cancel(&mut self, work: Work) -> bool {
        let cancelled = if let Some(result) = self.replay("cancel", &work.to_string()) {
            match result {
                Ok(bytes) if bytes.len() == 1 => bytes[0] != 0,
                Ok(_) => {
                    self.failure.borrow_mut().get_or_insert_with(file::invalid);
                    false
                }
                Err(error) => {
                    self.failure.borrow_mut().get_or_insert(error);
                    false
                }
            }
        } else {
            let released = self.locks.remove(&work).is_some();
            if released {
                for (_, event) in &mut self.ready {
                    if let Event::Done { work: id, result } = event
                        && *id == work
                    {
                        *result = Err(io::ErrorKind::Interrupted.into());
                    }
                }
            }
            let cancelled = released || self.workers.cancel(work);
            if let Err(error) =
                self.record("cancel", &work.to_string(), &Ok(()), &[u8::from(cancelled)])
            {
                self.failure.borrow_mut().get_or_insert(error);
            }
            cancelled
        };
        // A dropped job never completes, so its continuation never runs.
        if cancelled {
            self.continued.remove(&work);
        }
        cancelled
    }
    fn watch(&mut self, path: &Path, directory: bool) -> io::Result<u64> {
        let args = format!("{} {directory}", path.display());
        if let Some(result) = self.replay("watch", &args) {
            return result.and_then(|v| {
                v.try_into()
                    .map(u64::from_le_bytes)
                    .map_err(|_| file::invalid())
            });
        }
        let id = self
            .serial
            .checked_add(1)
            .ok_or(io::ErrorKind::OutOfMemory)?;
        if self.watches.is_none() {
            self.watches = Some(watch::Watcher::new(&self.reactor, self.capacity)?);
        }
        let result = self.watches.as_mut().unwrap().set(id, path, directory);
        self.record("watch", &args, &result, &id.to_le_bytes())?;
        let appeared = result?;
        self.serial = id;
        self.watched.insert(id, self.section.clone());
        if appeared {
            // A folder level appeared while arming; its creation was not reported.
            self.ready.push_back((
                self.section.clone(),
                Event::Changed {
                    watch: id,
                    reset: true,
                },
            ));
        }
        Ok(id)
    }
    fn unwatch(&mut self, watch: u64) {
        if self.ignored("unwatch", &watch.to_string()) {
            return;
        }
        self.watched.remove(&watch);
        let result = match &mut self.watches {
            Some(watches) => watches.remove(watch),
            None => Err(io::ErrorKind::NotFound.into()),
        };
        if let Err(error) = self.record("unwatch", &watch.to_string(), &result, &[]) {
            self.failure.borrow_mut().get_or_insert(error);
        }
        if let Err(error) = result {
            self.failure.borrow_mut().get_or_insert(error);
        }
    }
    fn spawn(&mut self, command: Command, pty: Option<Grid>) -> io::Result<Spawned> {
        self.launch(command, pty, true, Some(0))
    }
    fn daemon(&mut self, command: Command) -> io::Result<Spawned> {
        self.launch(command, None, false, Some(0))
    }

    fn resize(&mut self, master: RawFd, grid: Grid) -> io::Result<()> {
        if let Some(result) = self.replay("resize", &format!("{master} {grid:?}")) {
            return result.map(|_| ());
        }
        let result = if !self.descriptors.contains_key(&master) {
            Err(io::ErrorKind::NotFound.into())
        } else {
            native::resize(master, grid)
        };
        self.record("resize", &format!("{master} {grid:?}"), &result, &[])?;
        result
    }
    fn hangup(&mut self, master: RawFd) -> io::Result<()> {
        if let Some(result) = self.replay("hangup", &master.to_string()) {
            return result.map(|_| ());
        }
        let source = self.source(master);
        if let Some(child) = self
            .children
            .values_mut()
            .find(|child| child.pty && child.channels.contains(&Some(master)))
        {
            if child.status.is_none() {
                if let Some(status) = child.process.try_wait()? {
                    child.status = Some((
                        status.code().unwrap_or(128 + status.signal().unwrap_or(0)),
                        Instant::now(),
                    ));
                    child.exit.take();
                } else {
                    native::hangup(source, child.process.id());
                }
            }
        }
        if let Err(error) = self.dispose(master) {
            self.failure.borrow_mut().get_or_insert(error);
        }
        let result = Ok(());
        self.record("hangup", &master.to_string(), &result, &[])?;
        result
    }
    fn connect(&mut self, address: &Address) -> io::Result<RawFd> {
        let args = match address {
            Address::Unix(path) => format!("unix {path:?}"),
            Address::Tcp(address) => format!("tcp {address}"),
        };
        if let Some(result) = self.replay("connect", &args) {
            return result.and_then(|v| {
                v.try_into()
                    .map(i32::from_le_bytes)
                    .map_err(|_| file::invalid())
            });
        }
        let result = socket::start(address);
        let data = result
            .as_ref()
            .map(|file| file.as_raw_fd().to_le_bytes().to_vec())
            .unwrap_or_default();
        self.record("connect", &args, &result, &data)?;
        let file = result?;
        let fd = file.as_raw_fd();
        self.descriptors.insert(fd, file);
        self.sections.insert(fd, self.section.clone());
        Ok(fd)
    }
    fn verify_socket(&mut self, fd: RawFd, path: &Path, identity: crate::api::FileIdentity, peer: (u32, u32)) -> io::Result<()> {
        use std::os::unix::fs::FileTypeExt;
        self.consumed(fd);
        let args = format!("{fd} {path:?} {} {} {} {}", identity.device, identity.inode, peer.0, peer.1);
        if let Some(result) = self.replay("verify_socket", &args) { return result.map(|_| ()); }
        let result = (|| {
            if !self.descriptors.contains_key(&fd) { return Err(io::ErrorKind::NotFound.into()); }
            socket::complete(fd).map_err(|error| {
                if error.kind() == io::ErrorKind::NotConnected { io::ErrorKind::WouldBlock.into() } else { error }
            })?;
            let metadata = std::fs::symlink_metadata(path)?;
            if !metadata.file_type().is_socket() || metadata.uid() != peer.0
                || metadata.dev() != identity.device || metadata.ino() != identity.inode
                || native::peer(fd)? != peer {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            Ok(())
        })();
        self.record("verify_socket", &args, &result, &[])?;
        result
    }
    fn connected(&mut self, fd: RawFd) -> io::Result<()> {
        self.consumed(fd);
        if let Some(result) = self.replay("connected", &fd.to_string()) {
            return result.map(|_| ());
        }
        let result = self
            .descriptors
            .get(&fd)
            .ok_or_else(|| io::ErrorKind::NotFound.into())
            .and_then(|_| socket::complete(fd));
        self.record("connected", &fd.to_string(), &result, &[])?;
        result
    }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> {
        if let Some(path) = self.routes.get(&self.section) {
            let token = path
                .file_name()
                .and_then(|s| s.to_str())
                .and_then(|s| s.parse().ok())
                .ok_or_else(file::invalid)?;
            return Ok((token, path.clone()));
        }
        let (id, path) = self.open("route")?;
        self.routes.insert(self.section.clone(), path.clone());
        Ok((id, path))
    }
    fn open_route(&mut self) -> io::Result<(u64, PathBuf)> {
        self.open("open_route")
    }
    fn close_route(&mut self, route: u64) {
        let args = route.to_string();
        if self.ignored("close_route", &args) {
            return;
        }
        let pending: Vec<_> = self
            .ready
            .iter()
            .filter_map(|(_, e)| match e {
                Event::Hook {
                    route: r, reply, ..
                } if *r == route => *reply,
                _ => None,
            })
            .collect();
        self.ready
            .retain(|(_, e)| !matches!(e,Event::Hook{route:r,..} if *r==route));
        let result =
            self.hooks
                .as_mut()
                .unwrap()
                .close(route, &mut self.reactor)
                .map(|events| {
                    self.ready.extend(events.into_iter().filter(
                        |(_, e)| !matches!(e,Event::Closed{reply} if pending.contains(reply)),
                    ));
                });
        self.routes.retain(|_, path| {
            path.file_name()
                .and_then(|v| v.to_str())
                .and_then(|v| v.parse::<u64>().ok())
                != Some(route)
        });
        if let Err(error) = self.record("close_route", &args, &result, &[]).and(result) {
            self.failure.borrow_mut().get_or_insert(error);
        }
    }
    fn listen(&mut self, path: &Path) -> io::Result<RawFd> {
        System::listen(self, path)
    }
    fn shutdown(&mut self, fd: RawFd) -> io::Result<()> {
        self.consumed(fd);
        let args = fd.to_string();
        if let Some(result) = self.replay("shutdown", &args) {
            return result.map(|_| ());
        }
        let source = self.source(fd);
        let result = (|| {
            let file = self
                .descriptors
                .get(&source)
                .or_else(|| self.descriptors.get(&fd))
                .ok_or(io::ErrorKind::NotFound)?;
            use std::os::unix::fs::FileTypeExt;
            if file.metadata()?.file_type().is_fifo() {
                unsafe extern "C" {
                    fn fcntl(fd: i32, command: i32, ...) -> i32;
                }
                // SAFETY: owned pipe fd, F_GETFL; only a write endpoint can be half-closed.
                let flags = unsafe { fcntl(source, 3) };
                if flags < 0 {
                    return Err(io::Error::last_os_error());
                }
                if flags & 3 != 1 {
                    return Err(io::ErrorKind::InvalidInput.into());
                }
                self.dispose(fd)
            } else {
                unsafe extern "C" {
                    fn shutdown(fd: i32, how: i32) -> i32;
                }
                // SAFETY: owned fd; SHUT_WR preserves this socket's incoming direction.
                if unsafe { shutdown(source, 1) } == 0 {
                    Ok(())
                } else {
                    Err(io::Error::last_os_error())
                }
            }
        })();
        self.record("shutdown", &args, &result, &[])?;
        result
    }
    fn unlock(&mut self, work: Work) {
        if self.ignored("unlock", &work.to_string()) {
            return;
        }
        self.locks.remove(&work);
        if let Err(error) = self.record("unlock", &work.to_string(), &Ok(()), &[]) {
            self.failure.borrow_mut().get_or_insert(error);
        }
    }
    fn executable(&mut self) -> io::Result<PathBuf> {
        use std::os::unix::ffi::{OsStrExt, OsStringExt};
        if let Some(result) = self.replay("executable", "") {
            return Ok(std::ffi::OsString::from_vec(result?).into());
        }
        let result = file::stable();
        let bytes = result
            .as_ref()
            .map(|p| p.as_os_str().as_bytes().to_vec())
            .unwrap_or_default();
        self.record("executable", "", &result, &bytes)?;
        result
    }
    fn storage(&mut self) -> io::Result<PathBuf> {
        use std::os::unix::ffi::{OsStrExt, OsStringExt};
        if let Some(result) = self.replay("storage", "") {
            return Ok(std::ffi::OsString::from_vec(result?).into());
        }
        let result = super::hooks::base()
            .map(|base| base.join("state"))
            .and_then(|path| {
                use std::os::unix::fs::DirBuilderExt;
                match std::fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(&path)
                {
                    Err(e) if e.kind() != io::ErrorKind::AlreadyExists => Err(e),
                    _ => Ok(path),
                }
            });
        let bytes = result
            .as_ref()
            .map(|p| p.as_os_str().as_bytes().to_vec())
            .unwrap_or_default();
        self.record("storage", "", &result, &bytes)?;
        result
    }
    fn directory(&mut self) -> io::Result<PathBuf> {
        use std::os::unix::ffi::{OsStrExt, OsStringExt};
        if let Some(result) = self.replay("directory", "") {
            return Ok(std::ffi::OsString::from_vec(result?).into());
        }
        let result = self
            .hooks
            .as_ref()
            .map(|hooks| hooks.directory().to_owned())
            .ok_or_else(|| io::ErrorKind::Unsupported.into());
        let bytes = result
            .as_ref()
            .map(|p| p.as_os_str().as_bytes().to_vec())
            .unwrap_or_default();
        self.record("directory", "", &result, &bytes)?;
        result
    }
    fn reply(&mut self, reply: u64, bytes: &[u8]) -> io::Result<()> {
        let args = if self.capture.tracing() {
            format!("{reply} {}", capture::hex(bytes))
        } else {
            String::new()
        };
        if let Some(result) = self.replay("reply", &args) {
            return result.map(|_| ());
        }
        let result = self
            .hooks
            .as_mut()
            .unwrap()
            .reply(reply, bytes, &mut self.reactor);
        self.record("reply", &args, &result, &[])?;
        result
    }
    fn hold(&mut self, reply: u64, until: Instant) -> io::Result<()> {
        let args = reply.to_string();
        if let Some(result) = self.replay("hold", &args) {
            return result.map(|_| ());
        }
        let result = self.hooks.as_mut().unwrap().hold(reply, until);
        self.record("hold", &args, &result, &[])?;
        result
    }
}

impl System {
    /// spawn and daemon: an owned child ends with the helper (System::drop, and on Linux when
    /// the helper dies); a daemon outlives it.
    pub(super) fn launch(
        &mut self,
        mut command: Command,
        pty: Option<Grid>,
        owned: bool,
        group: Option<i32>,
    ) -> io::Result<Spawned> {
        if let Some(path) = self
            .hooks
            .as_ref()
            .and_then(|hooks| hooks.path(&self.section))
            .or_else(|| self.routes.get(&self.section).map(PathBuf::as_path))
        {
            command.env("DISPATCH_HELPER4_ENDPOINT", path);
        }
        let mut args = format!("{command:?} pty={pty:?}");
        // Existing captures use private groups. A foreground launch changes the
        // native effect and must not replay as though its policy were unchanged.
        if group != Some(0) {
            args.push_str(&format!(" group={group:?}"));
        }
        if let Some(result) = self.replay("spawn", &args) {
            let bytes = result?;
            // Traces from before the tty fact hold only the four descriptors.
            let (descriptors, tty) = bytes.split_at_checked(16).ok_or_else(file::invalid)?;
            let tty = match tty.len() {
                0 => None,
                8 => Some(u64::from_le_bytes(tty.try_into().unwrap())),
                _ => return Err(file::invalid()),
            };
            let values: Vec<_> = descriptors
                .as_chunks::<4>()
                .0
                .iter()
                .map(|v| i32::from_le_bytes(*v))
                .collect();
            return Ok(Spawned {
                pid: values[0] as u32,
                input: (values[1] >= 0).then_some(values[1]),
                output: (values[2] >= 0).then_some(values[2]),
                stderr: (values[3] >= 0).then_some(values[3]),
                tty,
            });
        }
        let result = (|| {
            #[cfg(target_os = "macos")]
            let mut held = None;
            let mut tty = None;
            let master = if let Some(grid) = pty {
                let (master, slave) = native::pty(
                    grid,
                    if std::mem::take(&mut self.inherited) {
                        self.modes.as_ref()
                    } else {
                        None
                    },
                )?;
                tty = Some(native::tty(std::os::unix::fs::MetadataExt::rdev(
                    &slave.metadata()?,
                )));
                // Darwin flushes unread master output on last slave close. Pin the slave
                // while the reactor drains; a session leader waits for that drain at exit.
                #[cfg(target_os = "macos")]
                {
                    held = Some(slave.try_clone()?);
                }
                command
                    .stdin(slave.try_clone()?)
                    .stdout(slave.try_clone()?)
                    .stderr(slave);
                // SAFETY: only async-signal-safe native session/signal syscalls after fork.
                unsafe {
                    command.pre_exec(native::session);
                }
                Some(master)
            } else {
                // Private controllers survive origin group signals; foreground launchers
                // inherit the shell's group so their children can read its terminal.
                if let Some(group) = group {
                    command.process_group(group);
                }
                // An owned child also ends when the helper dies without unwinding.
                #[cfg(target_os = "linux")]
                if owned {
                    // SAFETY: prctl is async-signal-safe after fork.
                    unsafe {
                        command.pre_exec(native::orphaned);
                    }
                }
                None
            };
            let mut child = command.spawn()?;
            let pid = child.id();
            let exit = match self.reactor.child(pid) {
                Ok(exit) => exit,
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.try_wait();
                    return Err(error);
                }
            };
            let channels = (|| {
                if let Some(master) = master {
                    let fd = self.adopt(master.into_raw_fd())?;
                    Ok([Some(fd), Some(fd), None])
                } else {
                    use std::os::fd::OwnedFd;
                    // Own all pipes before adopting any, so failed setup closes each one.
                    let pipes = [
                        child.stdin.take().map(OwnedFd::from),
                        child.stdout.take().map(OwnedFd::from),
                        child.stderr.take().map(OwnedFd::from),
                    ];
                    let mut channels = [None; 3];
                    for (i, pipe) in pipes.into_iter().enumerate() {
                        if let Some(pipe) = pipe {
                            match self.adopt(pipe.into_raw_fd()) {
                                Ok(fd) => channels[i] = Some(fd),
                                Err(error) => {
                                    for fd in channels.into_iter().flatten() {
                                        self.close(fd);
                                    }
                                    return Err(error);
                                }
                            }
                        }
                    }
                    Ok(channels)
                }
            })();
            let [input, output, stderr] = match channels {
                Ok(channels) => channels,
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.try_wait();
                    return Err(error);
                }
            };
            self.children.insert(
                pid,
                ChildState {
                    pty: pty.is_some(),
                    owned,
                    process: child,
                    exit: Some(exit),
                    section: self.section.clone(),
                    channels: [input, output.filter(|fd| Some(*fd) != input), stderr],
                    #[cfg(target_os = "macos")]
                    slave: held,
                    status: None,
                },
            );
            Ok(Spawned {
                pid,
                input,
                output,
                stderr,
                tty,
            })
        })();
        let data = result
            .as_ref()
            .map(|s| {
                [
                    s.pid as i32,
                    s.input.unwrap_or(-1),
                    s.output.unwrap_or(-1),
                    s.stderr.unwrap_or(-1),
                ]
                .iter()
                .flat_map(|v| v.to_le_bytes())
                .chain(s.tty.iter().flat_map(|v| v.to_le_bytes()))
                .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        self.record("spawn", &args, &result, &data)?;
        result
    }
}

impl file::Replay {
    pub(in crate::system) fn stream(
        &self,
        section: &str,
        op: &str,
        fd: RawFd,
        bytes: &mut [u8],
    ) -> io::Result<io::Result<usize>> {
        let key = (section.into(), fd, op.into());
        let mut streams = self.streams.borrow_mut();
        let pending = streams.entry(key).or_default();
        if pending.is_empty() {
            let row = self.take(section)?;
            let mut args = row.args.split_whitespace();
            if row.op != op
                || args.next().and_then(|value| value.parse::<RawFd>().ok()) != Some(fd)
                || args
                    .next()
                    .and_then(|value| {
                        value
                            .strip_prefix("len=")
                            .unwrap_or(value)
                            .parse::<usize>()
                            .ok()
                    })
                    .is_none()
            {
                return Err(file::invalid());
            }
            let data = match file::decode(&row.data)?.result {
                Ok(Output::Bytes(data)) => data,
                Ok(_) => return Err(file::invalid()),
                Err(error) => return Ok(Err(error)),
            };
            pending.extend(data);
        }
        let count = bytes.len().min(pending.len());
        if op == "write" {
            if let Some(matched) = bytes.iter().zip(pending.iter()).take(count)
                .position(|(actual, expected)| actual != expected)
            {
                let offset = matched / crate::wire::CHUNK * crate::wire::CHUNK;
                let end = offset + crate::wire::CHUNK;
                let expected = capture::hex(&pending.iter().skip(offset).take(crate::wire::CHUNK).copied().collect::<Vec<_>>());
                let actual = capture::hex(&bytes[offset..bytes.len().min(end)]);
                self.mismatch(Data::Object(vec![
                    ("section", Data::String(section)), ("op", Data::String(op)),
                    ("fd", Data::Signed(fd.into())), ("compared", Data::Unsigned(count as u64)),
                    ("matched", Data::Unsigned(matched as u64)), ("offset", Data::Unsigned(offset as u64)),
                    ("expected", Data::Object(vec![("length", Data::Unsigned(pending.len() as u64)), ("bytes", Data::String(&expected))])),
                    ("actual", Data::Object(vec![("length", Data::Unsigned(bytes.len() as u64)), ("bytes", Data::String(&actual))])),
                ]));
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    if section == "ui" {
                        "produced app message differs: whole recorded reply differs"
                    } else {
                        "invalid file capture: recorded outside write differs"
                    },
                ));
            }
        }
        for (actual, expected) in bytes.iter_mut().zip(pending.iter()).take(count) {
            *actual = *expected;
        }
        pending.drain(..count);
        Ok(Ok(count))
    }
    pub(in crate::system) fn write(
        &self,
        section: &str,
        fd: RawFd,
        bytes: &[u8],
    ) -> io::Result<file::Completion> {
        let count = self.stream(section, "write", fd, &mut bytes.to_vec())?;
        if let (Some(root), Ok(count)) = (&self.output, &count) {
            std::fs::create_dir_all(root)?;
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(root.join(format!("{}.bin", capture::hex(section.as_bytes()))))?
                .write_all(&bytes[..*count])?;
        }
        Ok(file::Completion {
            sequence: Some(0),
            held: None,
            result: count.map(|count| Output::Bytes((count as u64).to_le_bytes().to_vec())),
        })
    }
}
