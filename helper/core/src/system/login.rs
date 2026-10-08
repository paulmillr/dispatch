//! Authenticated SSH auxiliaries forward the common bus of the original login shell.
use super::{System, native, queue::Queue};
use crate::{
    api::{Address, Event, Io, Job, Output},
    json::{self, Data, Json},
};
use std::{
    fs, io,
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt},
    path::{Path, PathBuf},
    time::Duration,
};

pub(crate) enum Supervision {
    Frontend(i32),
    Worker(std::os::unix::net::UnixStream),
    Replay,
}

/// The SSH command owns the frontend lifetime; the exec'd worker owns the shared bus.
/// Only exec-safe descriptor setup runs between fork and exec, even if callers have threads.
pub(crate) fn supervise() -> io::Result<Supervision> {
    use std::os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            net::UnixStream,
            process::{CommandExt, ExitStatusExt},
        },
    };
    unsafe extern "C" {
        fn fcntl(fd: i32, command: i32, ...) -> i32;
        fn signal(number: i32, handler: usize) -> usize;
    }
    if System::recording().is_some() {
        return Ok(Supervision::Replay);
    }
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() >= 2 && args[args.len() - 2] == "--login-worker" {
        let fd: i32 = args
            .last()
            .and_then(|v| v.to_str())
            .and_then(|v| v.parse().ok())
            .filter(|fd| *fd > 2)
            .ok_or(io::ErrorKind::InvalidInput)?;
        // SAFETY: validate the inherited descriptor before taking its sole worker ownership.
        if unsafe { fcntl(fd, 1) } < 0 || unsafe { fcntl(fd, 2, 1) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let stream = unsafe { UnixStream::from_raw_fd(fd) };
        stream.peer_addr()?;
        return Ok(Supervision::Worker(stream));
    }
    let (mut frontend, worker) = UnixStream::pair()?;
    let fd = worker.as_raw_fd();
    let mut command = std::process::Command::new(std::env::current_exe()?);
    command.args(args).arg("--login-worker").arg(fd.to_string());
    // Both processes stay in SSH's foreground group until the shell finishes. The worker
    // installs its own signal handlers; the waiting frontend must not consume Ctrl-C/quit.
    let previous = unsafe { [signal(2, 1), signal(3, 1)] };
    unsafe {
        command.pre_exec(move || {
            if fcntl(fd, 2, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let result = (|| {
        let mut child = command.spawn()?;
        drop(worker);
        let mut status = [0; 4];
        match frontend.read_exact(&mut status) {
            Ok(()) => Ok(Supervision::Frontend(i32::from_le_bytes(status))),
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                let status = child.wait()?;
                Ok(Supervision::Frontend(
                    status
                        .code()
                        .unwrap_or_else(|| 128 + status.signal().unwrap_or(1)),
                ))
            }
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                Err(error)
            }
        }
    })();
    unsafe {
        signal(2, previous[0]);
        signal(3, previous[1]);
    }
    result
}

impl System {
    /// Release the completed login's transport while retaining the reactor and its clients.
    pub(crate) fn detach(&mut self) -> io::Result<()> {
        use std::os::fd::AsRawFd;
        if let Some(result) = self.replay("stdio.detach", "") {
            return result.map(|_| ());
        }
        let result = (|| {
            unsafe extern "C" {
                fn setsid() -> i32;
                fn dup2(source: i32, target: i32) -> i32;
            }
            // This worker was exec-spawned without a process-group change, so is not its
            // group's leader. Separate it before the SSH frontend returns and sshd hangs up.
            if unsafe { setsid() } < 0 {
                return Err(io::Error::last_os_error());
            }
            let null = fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open("/dev/null")?;
            for fd in [0, 1, 2] {
                if unsafe { dup2(null.as_raw_fd(), fd) } < 0 {
                    return Err(io::Error::last_os_error());
                }
            }
            self.parent = None;
            self.signals.clear();
            Ok(())
        })();
        self.record("stdio.detach", "", &result, &[])?;
        result
    }
}

/// A receipt is published only after the login shell itself exits, never on transport loss.
pub fn record(socket: &Path, status: i32) -> io::Result<()> {
    let parent = native::directory(&socket.with_file_name("."), crate::api::Expected::Any)?;
    let mut file = native::open(&parent, "exit.pending".as_ref(), Some(0o600))?;
    file.write_all(status.to_string().as_bytes())?;
    native::publish(&parent, "exit.pending".as_ref(), "exit".as_ref(), false)
}

/// Consume the private receipt so a later transport loss cannot reuse an earlier exit.
pub fn status(socket: &Path) -> io::Result<i32> {
    let parent = native::directory(&socket.with_file_name("."), crate::api::Expected::Any)?;
    let mut file = native::open(&parent, "exit".as_ref(), None)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != System::account()?.0
        || metadata.mode() & 0o077 != 0
        || metadata.nlink() != 1
        || metadata.len() > 16
    {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let mut text = String::new();
    Read::by_ref(&mut file).take(17).read_to_string(&mut text)?;
    let status = text.parse::<u8>().map_err(|_| io::ErrorKind::InvalidData)?;
    native::remove(&parent, "exit".as_ref())?;
    Ok(status.into())
}

pub fn endpoint(session: &str) -> io::Result<PathBuf> {
    if session.len() != 24
        || !session
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let (uid, home) = System::account()?;
    if System::recording().is_some() {
        return Ok(home.join(super::hooks::ROOT).join("sessions").join(session).join("bus"));
    }
    let mut path = home;
    for part in [super::hooks::ROOT, "sessions", session] {
        path.push(part);
        match fs::DirBuilder::new().mode(0o700).create(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        let metadata = fs::symlink_metadata(&path)?;
        if !metadata.is_dir() || metadata.uid() != uid || metadata.mode() & 0o777 != 0o700 {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
    }
    Ok(path.join("bus"))
}

/// The login worker holds `lock` beside its bus while it serves, so cleanup keeps the session
/// directory (and the exit status it records there) until a day after the worker is gone.
pub fn claim(socket: &Path) -> io::Result<fs::File> {
    let (uid, _) = System::account()?;
    super::hooks::hold(&socket.with_file_name("lock"), uid)
}

/// EOF on this auxiliary channel never terminates the independently owned login PTY.
pub fn connect(path: &Path) -> io::Result<()> {
    let (uid, _) = System::account()?;
    let mut io = System::new(1, 8)?;
    io.section("login.bridge");
    let deadline = io.now() + Duration::from_secs(5);
    io.timer(deadline);
    let absolute = if path.is_absolute() {
        path.to_owned()
    } else {
        System::cwd()?.join(path)
    };
    let watch = io.watch(&absolute, false)?;
    let input = json::write(&Data::Object(vec![(
        "path",
        Data::String(absolute.to_str().ok_or(io::ErrorKind::InvalidInput)?),
    )]))
    .map_err(|error| io::Error::other(error.message))?;
    let mut pending = None;
    let mut changed = true;
    let mut denied = false;
    loop {
        if changed && pending.is_none() {
            pending = Some(io.submit(Job::Native {
                name: "file.lstat",
                input: input.clone(),
            })?);
            changed = false;
        }
        let (_, event) = io.next()?;
        if io.now() >= deadline {
            return Err(if denied {
                io::ErrorKind::PermissionDenied
            } else {
                io::ErrorKind::TimedOut
            }
            .into());
        }
        match event {
            Event::Changed { watch: token, .. } if token == watch => changed = true,
            Event::Done { work, result } if Some(work) == pending => {
                pending = None;
                match result {
                    Err(error) if error.kind() == io::ErrorKind::NotFound => denied = false,
                    Err(error) => return Err(error),
                    Ok(Output::Bytes(bytes)) => {
                        let document =
                            Json::parse(&bytes).map_err(|error| io::Error::other(error.message))?;
                        let metadata = document.root();
                        if metadata.get("kind").and_then(|v| v.string()) != Some("socket")
                            || metadata.get("uid").and_then(|v| v.unsigned()) != Some(uid.into())
                        {
                            return Err(io::ErrorKind::PermissionDenied.into());
                        }
                        let mode = metadata
                            .get("mode")
                            .and_then(|v| v.unsigned())
                            .ok_or(io::ErrorKind::PermissionDenied)?;
                        // bind creates the inode before the publisher's chmod.
                        // Its watch must report private permissions before connecting.
                        denied = mode & 0o077 != 0;
                        if denied {
                            continue;
                        }
                        break;
                    }
                    _ => return Err(io::ErrorKind::InvalidData.into()),
                }
            }
            _ => {}
        }
    }
    io.unwatch(watch);
    let (input, output) = io.stdio()?;
    let socket = io.connect(&Address::Unix(path.to_owned()))?;
    let mut connected = false;
    let mut eof = [false; 2];
    let mut queues = [Queue::new(1_048_576), Queue::new(1_048_576)];
    loop {
        if (eof[1] && queues[1].front().is_none())
            || (eof[0] && queues[0].front().is_none())
        {
            return io.finish_replay();
        }
        io.interest(
            input,
            connected && !eof[0] && queues[0].space() >= 65_536,
            false,
        )?;
        io.interest(output, false, queues[1].front().is_some())?;
        io.interest(
            socket,
            connected && !eof[1] && queues[1].space() >= 65_536,
            !connected || queues[0].front().is_some(),
        )?;
        let (_, event) = io.next()?;
        if !connected && io.now() >= deadline {
            return Err(io::ErrorKind::TimedOut.into());
        }
        let Event::Ready { fd, read, write } = event else {
            continue;
        };
        if fd == socket && !connected && (read || write) {
            io.connected(socket)?;
            connected = true;
        }
        for (index, source, target) in [(0, input, socket), (1, socket, output)] {
            if fd == source && read && connected && !eof[index] {
                let mut bytes = [0; 65_536];
                match io.read(source, &mut bytes) {
                    Ok(0) => eof[index] = true,
                    Ok(count) => queues[index]
                        .push(bytes[..count].to_vec())
                        .map_err(|_| io::ErrorKind::InvalidData)?,
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                        ) => {}
                    Err(error) => return Err(error),
                }
            }
            if fd == target && write && connected {
                if let Some(bytes) = queues[index].front() {
                    match io.write(target, bytes) {
                        Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                        Ok(count) => queues[index]
                            .consume(count)
                            .map_err(|_| io::ErrorKind::InvalidData)?,
                        Err(error)
                            if matches!(
                                error.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                            ) => {}
                        Err(error) => return Err(error),
                    }
                }
            }
        }
    }
}
