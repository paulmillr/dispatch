//! System effects, including exact test-only replay outcomes.
use super::*;
use crate::json::Data;

/// Job::Collect's workers: two slow commands run at once and the rest wait their turn on these, never on the
/// shared workers.
const COLLECTS: usize = 2;
/// Collects submitted and not yet answered, running or waiting; past it a collect is refused (WouldBlock).
const COLLECTS_QUEUED: usize = 16;

impl Io for System {
    fn observe(&mut self, pid: u32) -> io::Result<u64> {
        if let Some(result) = self.replay("process.observe", Data::Unsigned(pid.into()), |v| v.unsigned()) {
            return result;
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
        self.record("process.observe", Data::Unsigned(pid.into()), &result, Data::Unsigned(id))?;
        result?;
        self.serial = id;
        Ok(id)
    }
    fn unobserve(&mut self, id: u64) {
        if self.ignored("process.unobserve", Data::Unsigned(id)) {
            return;
        }
        if let Some(processes) = &mut self.processes {
            processes.remove(id);
        }
        self.ready
            .retain(|(_, event)| !matches!(event, Event::Process { watch, .. } if *watch == id));
        if let Err(error) = self.record("process.unobserve", Data::Unsigned(id), &Ok(()), Data::Null) {
            self.failure.borrow_mut().get_or_insert(error);
        }
    }
    fn datagram(&mut self, path: &Path, bytes: &[u8]) -> io::Result<()> {
        let args = || Data::Object(vec![("path", Data::from(path)), ("bytes", Data::Bytes(bytes))]);
        if let Some(result) = self.replay("datagram", args(), |_| Some(())) {
            return result;
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
        self.record("datagram", args(), &result, Data::Null)?;
        result
    }
    fn random(&mut self, bytes: &mut [u8]) -> io::Result<()> {
        let length = Data::Unsigned(bytes.len() as u64);
        if let Some(result) = self.replay("random", length, |v| v.bytes().map(<[u8]>::to_vec)) {
            let data = result?;
            if data.len() != bytes.len() {
                return Err(file::invalid());
            }
            bytes.copy_from_slice(&data);
            return Ok(());
        }
        let result = random(bytes);
        self.record("random", Data::Unsigned(bytes.len() as u64), &result, Data::Bytes(bytes))?;
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
        let args = Data::Object(vec![("fd", Data::Signed(fd.into())), ("length", Data::Unsigned(bytes.len() as u64))]);
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
        self.record("read", args, &result, Data::Bytes(data))?;
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
        let args = Data::Object(vec![("fd", Data::Signed(fd.into())), ("length", Data::Unsigned(bytes.len() as u64))]);
        if let Some(replay) = self.capture.replay.as_ref() {
            let result = replay.write(&self.section, fd, bytes);
            if let Err(error) = &result {
                self.failure
                    .borrow_mut()
                    .get_or_insert_with(|| io::Error::new(error.kind(), error.to_string()));
            }
            return result?;
        }
        let result = self
            .descriptors
            .get_mut(&fd)
            .ok_or_else(|| io::ErrorKind::NotFound.into())
            .and_then(|file| file.write(bytes));
        let data = result.as_ref().map_or(&[][..], |&count| &bytes[..count]);
        self.record("write", args, &result, Data::Bytes(data))?;
        result
    }
    fn accept(&mut self, fd: RawFd) -> io::Result<RawFd> {
        self.consumed(fd);
        if let Some(result) = self.replay("accept", Data::Signed(fd.into()), |v| v.signed().and_then(|v| v.try_into().ok())) {
            return result;
        }
        let result = self
            .listeners
            .get(&fd)
            .ok_or_else(|| io::ErrorKind::NotFound.into())
            .and_then(|listener| listener.listener.accept())
            .and_then(|(stream, _)| self.adopt(stream.into_raw_fd()));
        let output = result.as_ref().map_or(Data::Null, |&fd| Data::Signed(fd.into()));
        self.record("accept", Data::Signed(fd.into()), &result, output)?;
        result
    }
    fn close(&mut self, fd: RawFd) {
        self.consumed(fd);
        if self.ignored("close", Data::Signed(fd.into())) {
            return;
        }
        let result = self.dispose(fd);
        if let Err(error) = self.record("close", Data::Signed(fd.into()), &result, Data::Null) {
            self.failure.borrow_mut().get_or_insert(error);
        }
        if let Err(error) = result {
            self.failure.borrow_mut().get_or_insert(error);
        }
    }
    fn interest(&mut self, fd: RawFd, read: bool, write: bool) -> io::Result<()> {
        self.consumed(fd);
        let args = || {
            Data::Object(vec![("fd", Data::Signed(fd.into())), ("read", Data::Bool(read)), ("write", Data::Bool(write))])
        };
        if let Some(result) = self.replay("interest", args(), |_| Some(())) {
            return result;
        }
        self.sections
            .entry(fd)
            .or_insert_with(|| self.section.clone());
        let result = self.reactor.interest(self.source(fd), read, write);
        self.record("interest", args(), &result, Data::Null)?;
        result
    }
    fn child(&mut self, pid: u32) -> io::Result<()> {
        if let Some(result) = self.replay("child", Data::Unsigned(pid.into()), |_| Some(())) {
            return result;
        }
        let result = if self.children.contains_key(&pid) {
            Ok(())
        } else {
            Err(io::ErrorKind::NotFound.into())
        };
        self.record("child", Data::Unsigned(pid.into()), &result, Data::Null)?;
        result
    }
    fn terminate(&mut self, pid: u32) -> io::Result<()> {
        if let Some(result) = self.replay("terminate", Data::Unsigned(pid.into()), |_| Some(())) {
            return result;
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
            native::end(pid, child.leader)
        })();
        self.record("terminate", Data::Unsigned(pid.into()), &result, Data::Null)?;
        result
    }

    fn signal(&mut self, pid: u32, signal: i32) -> io::Result<()> {
        let args = || Data::Object(vec![("pid", Data::Unsigned(pid.into())), ("signal", Data::Signed(signal.into()))]);
        if let Some(result) = self.replay("signal", args(), |_| Some(())) {
            return result;
        }
        let result = (|| {
            let child = self.children.get(&pid).ok_or(io::ErrorKind::NotFound)?;
            if !child.pty || child.status.is_some() {
                return Err(io::ErrorKind::NotFound.into());
            }
            let fd = child.channels[0].ok_or(io::ErrorKind::NotFound)?;
            native::interrupt(self.source(fd), signal)
        })();
        self.record("signal", args(), &result, Data::Null)?;
        result
    }

    fn timer(&mut self, at: Instant) {
        let result = (|| {
            if let Some(replay) = &self.capture.replay {
                let record = replay.value(&self.section, "timer", &Data::Null)?;
                let offset = crate::wire::body::decode_plain(&record.output)
                    .ok()
                    .and_then(|value| value.unsigned())
                    .ok_or_else(file::invalid)?;
                return replay
                    .origin
                    .checked_add(Duration::from_nanos(offset))
                    .map(Some)
                    .ok_or_else(file::invalid);
            }
            let offset = capture::value(&Data::Unsigned(self.capture.offset(at)?))?;
            self.capture
                .record(&self.section, "timer", &Data::Null, None, 0, offset)?;
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
    fn os(&self) -> &str {
        &self.platform.0
    }
    fn arch(&self) -> &str {
        &self.platform.1
    }
    fn execution(&self) -> Vec<std::ffi::OsString> {
        self.platform.2.clone()
    }
    fn pid(&self) -> u32 {
        self.pid
    }
    fn now(&self) -> Instant {
        if let Some(replay) = &self.capture.replay {
            let result = (|| {
                let record = replay.value(&self.section, "now", &Data::Null)?;
                let offset = crate::wire::body::decode_plain(&record.output)
                    .ok()
                    .and_then(|value| value.unsigned())
                    .ok_or_else(file::invalid)?;
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
            if let Ok(offset) = capture::value(&Data::Unsigned(offset)) {
                let _ = self.capture.record(&self.section, "now", &Data::Null, None, 0, offset);
            }
        }
        at
    }
    fn submit(&mut self, mut job: Job) -> io::Result<Work> {
        let id = self
            .serial
            .checked_add(1)
            .ok_or(io::ErrorKind::OutOfMemory)?;
        let order = self.files.order(&self.section);
        // A job's args: what it asks for, as values (a native job's JSON input as its value
        // tree). Encoded now, and only for a capture or replay: the job itself moves to its worker.
        let encoded = if !self.capture.enabled() && self.capture.replay.is_none() {
            Vec::new()
        } else {
                        fn object<'a>(name: &'static str, fields: Vec<(&'static str, Data<'a>)>) -> Data<'a> {
                Data::Object([("job", Data::String(name))].into_iter().chain(fields).collect())
            }
            let args = match &job {
                Job::MakeDir { path: at, mode } => {
                    object("mkdir", vec![("path", Data::from(at.as_path())), ("mode", Data::Unsigned((*mode).into()))])
                }
                Job::Remove { path: at, expected } => {
                    object("remove", vec![("path", Data::from(at.as_path())), ("expected", capture::expected(expected)?)])
                }
                Job::Pack(crate::api::PackJob { base, paths, archive, limit, stop: _ }) => object(
                    "pack",
                    vec![
                        ("base", Data::from(base.as_path())),
                        ("paths", Data::Array(paths.iter().map(|p| Data::from(p.as_path())).collect())),
                        ("archive", Data::from(archive.as_path())),
                        ("limit", Data::Unsigned(*limit)),
                    ],
                ),
                Job::Append(staging, bytes) => {
                    object("append", vec![("path", Data::from(staging.path.as_path())), ("bytes", Data::Bytes(bytes))])
                }
                Job::Unpack(crate::api::UnpackJob { archive, staging, policy, names, replacements, stop: _ }) => object(
                    "unpack",
                    vec![
                        ("archive", Data::from(archive.as_path())),
                        ("staging", capture::staging(staging)),
                        ("policy", Data::String(capture::policy(*policy))),
                        ("names", Data::Array(names.iter().map(|name| Data::Bytes(name)).collect())),
                        ("replacements", Data::Array(replacements.iter().map(|(name, identity)| Data::Array(vec![Data::Bytes(name), Data::Unsigned(identity.device), Data::Unsigned(identity.inode)])).collect())),
                    ],
                ),
                Job::Stage(at, parent) => object("stage", vec![("path", Data::from(at.as_path())), ("parent_device", Data::Unsigned(parent.device)), ("parent_inode", Data::Unsigned(parent.inode))]),
                Job::Discard(staging) => object("discard", vec![("staging", capture::staging(staging))]),
                Job::RemoveTree(at) => object("remove_tree", vec![("path", Data::from(at.as_path()))]),
                Job::Sweep(prefix, age) => object(
                    "sweep",
                    vec![("prefix", Data::String(prefix)), ("age", Data::Unsigned(age.as_secs()))],
                ),
                Job::List { path: at } => object("list", vec![("path", Data::from(at.as_path()))]),
                Job::Read { path: at, offset, length } => object(
                    "read",
                    vec![("path", Data::from(at.as_path())), ("offset", Data::Unsigned(*offset)), ("length", Data::Unsigned(*length))],
                ),
                Job::Stat { path: at, follow } => object("stat", vec![("path", Data::from(at.as_path())), ("follow", Data::Bool(*follow))]),
                Job::Entries(at) => object(
                    "entries",
                    vec![("path", Data::from(at.path.as_path())), ("hidden", Data::Bool(at.hidden)), ("limit", Data::Unsigned(at.limit))],
                ),
                Job::Summary(at) => {
                    object("summary", vec![("path", Data::from(at.path.as_path())), ("limit", Data::Unsigned(at.limit))])
                }
                Job::Write { path: at, bytes, mode, expected, parent } => object(
                    "write",
                    vec![
                        ("path", Data::from(at.as_path())),
                        ("bytes", Data::Bytes(bytes)),
                        ("mode", Data::Unsigned((*mode).into())),
                        ("expected", capture::expected(expected)?),
                        ("parent_device", parent.map_or(Data::Null, |value| Data::Unsigned(value.device))),
                        ("parent_inode", parent.map_or(Data::Null, |value| Data::Unsigned(value.inode))),
                    ],
                ),
                Job::Native { name, value } | Job::Isolated { name, value, .. } => {
                    let kind = if matches!(job, Job::Native { .. }) { "native" } else { "isolated" };
                    let value = crate::wire::body::decode_plain(value).map_err(|_| io::ErrorKind::InvalidInput)?;
                    object(kind, vec![("name", Data::String(name)), ("value", value)])
                }
                Job::Process { pid } => object("process", vec![("pid", Data::Unsigned((*pid).into()))]),
                Job::Lock { path: at, .. } => object("lock", vec![("path", Data::from(at.as_path()))]),
                Job::Run { command, input, .. } => {
                    object("run", vec![("command", capture::command(command)), ("input", Data::Bytes(input))])
                }
                // The timeout is never recorded (like Run's deadline); the bounds decide the answer.
                Job::Collect(at) => object(
                    "collect",
                    vec![
                        ("command", capture::command(&at.command)),
                        ("stdout", Data::Unsigned(at.stdout as u64)),
                        ("stderr", Data::Unsigned(at.stderr as u64)),
                    ],
                ),
            };
            capture::value(&args)?
        };
        let args = || crate::wire::body::decode_plain(&encoded).expect("encoded above");
        if let Some(replay) = &self.capture.replay {
            let work = match replay.value(&self.section, "submit", &args()) {
                Ok(record) => {
                    let value = crate::wire::body::decode_plain(&record.output).map_err(|_| file::invalid())?;
                    if record.error.is_some() {
                        return Err(file::failure(&value, &self.platform.0)?);
                    }
                    value.unsigned().ok_or_else(file::invalid)?
                }
                Err(error) => {
                    self.failure.borrow_mut().get_or_insert(error);
                    id
                }
            };
            self.serial = self.serial.max(work);
            self.files.admit(&self.section);
            self.jobs
                .insert(work, (self.section.clone(), Some((order, encoded))));
            return Ok(work);
        }
        let result = (|| {
            // Pin a borrowed peer socket before a worker can observe a reused fd number.
            // Capture args above retain the caller's fd, not the private duplicate.
            let pin = if let Job::Native {
                name: "peer",
                value,
            } = &mut job
            {
                let fd = crate::wire::body::decode_plain(value)
                    .ok()
                    .and_then(|value| value.get("fd").and_then(Data::signed))
                    .and_then(|v| i32::try_from(v).ok())
                    .filter(|fd| *fd >= 0)
                    .ok_or(io::ErrorKind::InvalidInput)?;
                // SAFETY: no intervening callback can close this descriptor on the reactor thread.
                let pin = unsafe { BorrowedFd::borrow_raw(fd) }.try_clone_to_owned()?;
                *value = crate::wire::body::encode_plain(&Data::Object(vec![(
                    "fd",
                    Data::Signed(pin.as_raw_fd().into()),
                )]))
                .map_err(|_| io::ErrorKind::InvalidInput)?;
                Some(pin)
            } else {
                None
            };
            let executor = if matches!(job, Job::Collect(_)) {
                match &mut self.collects {
                    Some(collects) => collects,
                    None => {
                        let collects = work::Executor::new(COLLECTS, COLLECTS_QUEUED)?;
                        self.reactor.interest(collects.as_raw_fd(), true, false)?;
                        self.collects.insert(collects)
                    }
                }
            } else {
                &mut self.workers
            };
            executor
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
        if self.capture.enabled() {
            self.record("submit", args(), &result, Data::Unsigned(id))?;
        }
        result?;
        self.serial = id;
        self.files.admit(&self.section);
        self.jobs
            .insert(id, (self.section.clone(), Some((order, encoded))));
        Ok(id)
    }
    fn then(&mut self, work: Work, callback: Box<dyn FnOnce(&mut dyn Io, io::Result<Output>)>) {
        self.continued
            .insert(work, (self.section.clone(), callback));
    }
    fn cancel(&mut self, work: Work) -> bool {
        let cancelled = if let Some(result) = self.replay("cancel", Data::Unsigned(work), |v| v.boolean()) {
            match result {
                Ok(cancelled) => cancelled,
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
            let cancelled = released
                || self.workers.cancel(work)
                || self.collects.as_mut().is_some_and(|collects| collects.cancel(work));
            if let Err(error) =
                self.record("cancel", Data::Unsigned(work), &Ok(()), Data::Bool(cancelled))
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
        let args = || Data::Object(vec![("path", Data::from(path)), ("directory", Data::Bool(directory))]);
        if let Some(result) = self.replay("watch", args(), |v| v.unsigned()) {
            return result;
        }
        let id = self
            .serial
            .checked_add(1)
            .ok_or(io::ErrorKind::OutOfMemory)?;
        // Every live outcome is recorded, a watcher that cannot be made too (e.g. EMFILE).
        let result = (|| {
            if self.watches.is_none() {
                self.watches = Some(watch::Watcher::new(&self.reactor, self.capacity)?);
            }
            self.watches.as_mut().unwrap().set(id, path, directory)
        })();
        self.record("watch", args(), &result, Data::Unsigned(id))?;
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
        if self.ignored("unwatch", Data::Unsigned(watch)) {
            return;
        }
        self.watched.remove(&watch);
        let result = match &mut self.watches {
            Some(watches) => watches.remove(watch),
            None => Err(io::ErrorKind::NotFound.into()),
        };
        if let Err(error) = self.record("unwatch", Data::Unsigned(watch), &result, Data::Null) {
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
        let args = || Data::Object(vec![("fd", Data::Signed(master.into())), ("grid", capture::grid(&grid))]);
        if let Some(result) = self.replay("resize", args(), |_| Some(())) {
            return result;
        }
        let result = if !self.descriptors.contains_key(&master) {
            Err(io::ErrorKind::NotFound.into())
        } else {
            native::resize(master, grid)
        };
        self.record("resize", args(), &result, Data::Null)?;
        result
    }
    fn hangup(&mut self, master: RawFd) -> io::Result<()> {
        if let Some(result) = self.replay("hangup", Data::Signed(master.into()), |_| Some(())) {
            return result;
        }
        let source = self.source(master);
        let result = (|| {
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
            Ok(())
        })();
        if let Err(error) = self.dispose(master) {
            self.failure.borrow_mut().get_or_insert(error);
        }
        self.record("hangup", Data::Signed(master.into()), &result, Data::Null)?;
        result
    }
    fn connect(&mut self, address: &Address) -> io::Result<RawFd> {
        let tcp = match address {
            Address::Tcp(address) => address.to_string(),
            Address::Unix(_) => String::new(),
        };
        let args = || Data::Object(vec![match address {
            Address::Unix(path) => ("unix", Data::from(path.as_path())),
            Address::Tcp(_) => ("tcp", Data::String(&tcp)),
        }]);
        if let Some(result) = self.replay("connect", args(), |v| v.signed().and_then(|v| v.try_into().ok())) {
            return result;
        }
        let result = socket::start(address);
        let output = result.as_ref().map_or(Data::Null, |file| Data::Signed(file.as_raw_fd().into()));
        self.record("connect", args(), &result, output)?;
        let file = result?;
        let fd = file.as_raw_fd();
        self.descriptors.insert(fd, file);
        self.sections.insert(fd, self.section.clone());
        Ok(fd)
    }
    fn verify_socket(&mut self, fd: RawFd, path: &Path, identity: crate::api::FileIdentity, peer: (u32, u32)) -> io::Result<()> {
        use std::os::unix::fs::FileTypeExt;
        self.consumed(fd);
        let args = || Data::Object(vec![
            ("fd", Data::Signed(fd.into())), ("path", Data::from(path)),
            ("device", Data::Unsigned(identity.device)), ("inode", Data::Unsigned(identity.inode)),
            ("peer", Data::Array(vec![Data::Unsigned(peer.0.into()), Data::Unsigned(peer.1.into())])),
        ]);
        if let Some(result) = self.replay("verify_socket", args(), |_| Some(())) { return result; }
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
        self.record("verify_socket", args(), &result, Data::Null)?;
        result
    }
    fn connected(&mut self, fd: RawFd) -> io::Result<()> {
        self.consumed(fd);
        if let Some(result) = self.replay("connected", Data::Signed(fd.into()), |_| Some(())) {
            return result;
        }
        let result = self
            .descriptors
            .get(&fd)
            .ok_or_else(|| io::ErrorKind::NotFound.into())
            .and_then(|_| socket::complete(fd));
        self.record("connected", Data::Signed(fd.into()), &result, Data::Null)?;
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
        if self.ignored("close_route", Data::Unsigned(route)) {
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
        if let Err(error) = self.record("close_route", Data::Unsigned(route), &result, Data::Null).and(result) {
            self.failure.borrow_mut().get_or_insert(error);
        }
    }
    fn listen(&mut self, path: &Path) -> io::Result<RawFd> {
        System::listen(self, path)
    }
    fn shutdown(&mut self, fd: RawFd) -> io::Result<()> {
        self.consumed(fd);
        if let Some(result) = self.replay("shutdown", Data::Signed(fd.into()), |_| Some(())) {
            return result;
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
        self.record("shutdown", Data::Signed(fd.into()), &result, Data::Null)?;
        result
    }
    fn unlock(&mut self, work: Work) {
        if self.ignored("unlock", Data::Unsigned(work)) {
            return;
        }
        self.locks.remove(&work);
        if let Err(error) = self.record("unlock", Data::Unsigned(work), &Ok(()), Data::Null) {
            self.failure.borrow_mut().get_or_insert(error);
        }
    }
    fn executable(&mut self) -> io::Result<PathBuf> {
        if let Some(result) = self.replay("executable", Data::Null, |v: &Data<'_>| v.path().map(PathBuf::from)) {
            return result;
        }
        let result = executable::stable();
        let output = result.as_ref().map_or(Data::Null, |p| Data::from(p.as_path()));
        self.record("executable", Data::Null, &result, output)?;
        result
    }
    fn storage(&mut self) -> io::Result<PathBuf> {
        if let Some(result) = self.replay("storage", Data::Null, |v: &Data<'_>| v.path().map(PathBuf::from)) {
            return result;
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
        let output = result.as_ref().map_or(Data::Null, |p| Data::from(p.as_path()));
        self.record("storage", Data::Null, &result, output)?;
        result
    }
    fn directory(&mut self) -> io::Result<PathBuf> {
        if let Some(result) = self.replay("directory", Data::Null, |v: &Data<'_>| v.path().map(PathBuf::from)) {
            return result;
        }
        let result = self
            .hooks
            .as_ref()
            .map(|hooks| hooks.directory().to_owned())
            .ok_or_else(|| io::ErrorKind::Unsupported.into());
        let output = result.as_ref().map_or(Data::Null, |p| Data::from(p.as_path()));
        self.record("directory", Data::Null, &result, output)?;
        result
    }
    fn reply(&mut self, reply: u64, bytes: &[u8]) -> io::Result<()> {
        let args = || Data::Object(vec![("reply", Data::Unsigned(reply)), ("bytes", Data::Bytes(bytes))]);
        if let Some(result) = self.replay("reply", args(), |_| Some(())) {
            return result;
        }
        let result = self
            .hooks
            .as_mut()
            .unwrap()
            .reply(reply, bytes, &mut self.reactor);
        self.record("reply", args(), &result, Data::Null)?;
        result
    }
    fn hold(&mut self, reply: u64, until: Instant) -> io::Result<()> {
        if let Some(result) = self.replay("hold", Data::Unsigned(reply), |_| Some(())) {
            return result;
        }
        let result = self.hooks.as_mut().unwrap().hold(reply, until);
        self.record("hold", Data::Unsigned(reply), &result, Data::Null)?;
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
            command.env("DISPATCH_HELPER_ENDPOINT", path);
        }
        // A foreground launch (group) changes the native effect: part of what was asked.
        let encoded = capture::value(&Data::Object(vec![
            ("command", capture::command(&command)),
            ("pty", pty.as_ref().map_or(Data::Null, capture::grid)),
            ("group", group.map_or(Data::Null, |group| Data::Signed(group.into()))),
        ]))?;
        let args = || crate::wire::body::decode_plain(&encoded).expect("encoded above");
        if let Some(result) = self.replay("spawn", args(), |v| {
            // An absent channel is null; Some(None) keeps it apart from an invalid value.
            let fd = |name| match v.get(name)? {
                Data::Null => Some(None),
                fd => fd.signed()?.try_into().ok().map(Some),
            };
            Some(Spawned {
                pid: v.get("pid")?.unsigned()?.try_into().ok()?,
                input: fd("input")?,
                output: fd("output")?,
                stderr: fd("stderr")?,
                tty: match v.get("tty")? { Data::Null => None, tty => Some(tty.unsigned()?) },
            })
        }) {
            return result;
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
                    leader: pty.is_some() || group == Some(0),
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
        let fd = |fd: Option<RawFd>| fd.map_or(Data::Null, |fd| Data::Signed(fd.into()));
        let output = result.as_ref().map_or(Data::Null, |s| Data::Object(vec![
            ("pid", Data::Unsigned(s.pid.into())),
            ("input", fd(s.input)),
            ("output", fd(s.output)),
            ("stderr", fd(s.stderr)),
            ("tty", s.tty.map_or(Data::Null, Data::Unsigned)),
        ]));
        self.record("spawn", args(), &result, output)?;
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
            let args = crate::wire::body::decode_plain(&row.args).map_err(|_| file::invalid())?;
            if row.op != op || args.get("fd").and_then(|v| v.signed()) != Some(fd.into()) {
                return Err(file::invalid());
            }
            let output = crate::wire::body::decode_plain(&row.output).map_err(|_| file::invalid())?;
            if row.error.is_some() {
                return Ok(Err(file::failure(&output, &super::System::platform()?.0)?));
            }
            pending.extend(output.bytes().ok_or_else(file::invalid)?);
        }
        let count = bytes.len().min(pending.len());
        if op == "write" {
            if let Some(matched) = bytes.iter().zip(pending.iter()).take(count)
                .position(|(actual, expected)| actual != expected)
            {
                let offset = matched / crate::wire::CHUNK * crate::wire::CHUNK;
                let end = offset + crate::wire::CHUNK;
                let expected: Vec<u8> = pending.iter().skip(offset).take(crate::wire::CHUNK).copied().collect();
                let actual = &bytes[offset..bytes.len().min(end)];
                self.mismatch(Data::Object(vec![
                    ("section", Data::String(section)), ("op", Data::String(op)),
                    ("fd", Data::Signed(fd.into())), ("compared", Data::Unsigned(count as u64)),
                    ("matched", Data::Unsigned(matched as u64)), ("offset", Data::Unsigned(offset as u64)),
                    ("expected", Data::Object(vec![("length", Data::Unsigned(pending.len() as u64)), ("bytes", Data::Bytes(&expected))])),
                    ("actual", Data::Object(vec![("length", Data::Unsigned(bytes.len() as u64)), ("bytes", Data::Bytes(actual))])),
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
    ) -> io::Result<io::Result<usize>> {
        let count = self.stream(section, "write", fd, &mut bytes.to_vec())?;
        if let (Some(root), Ok(count)) = (&self.output, &count) {
            std::fs::create_dir_all(root)?;
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(root.join(section.bytes().map(|byte| format!("{byte:02x}")).collect::<String>() + ".bin"))?
                .write_all(&bytes[..*count])?;
        }
        Ok(count)
    }
}
