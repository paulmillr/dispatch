//! Bounded one-shot commands. Persistent native connections use the host reactor.
use super::reactor::{self, Reactor};
use std::{
    io::{self, Read, Write},
    os::{fd::AsRawFd, unix::process::CommandExt},
    process::{Child, Command, ExitStatus, Stdio},
    time::{Duration, Instant},
};

struct Owned {
    child: Child,
    group: bool,
    reaped: bool,
}
impl Owned {
    fn cancel(&mut self, exited: bool) -> io::Result<()> {
        if !self.group {
            return Ok(());
        }
        unsafe extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
        }
        // The leader is still our unreaped child, so its process-group ID cannot be reused.
        // SAFETY: SIGKILL targets only the group explicitly created for this child.
        let result = unsafe { kill(-(self.child.id() as i32), 9) };
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(1) && (if exited {
                // NOTE_EXIT can precede WNOHANG readiness on Darwin. The exit is
                // already confirmed, so reap before accepting the empty group's EPERM.
                self.child.wait()?;
                true
            } else { self.child.try_wait()?.is_some() }) {
                self.reaped = true;
            } else if error.raw_os_error() != Some(3) {
                return Err(error);
            } // ESRCH: already empty.
        }
        self.group = false;
        Ok(())
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        // Failure/panic fallback never blocks the reactor. The ordinary path below
        // waits for the independent exit event and reaps before returning.
        let _ = self.cancel(false);
        if !self.reaped {
            let _ = self.child.try_wait();
        }
    }
}

/// Writes all of `input`, closes stdin (EOF for readers like `read_to_end`) and collects at most
/// `limit` bytes of stdout until EOF and exit. A child that exits without reading (EPIPE) is not
/// an error: its status says what happened.
pub fn run(
    mut command: Command,
    input: Vec<u8>,
    deadline: Option<Instant>,
    limit: usize,
) -> io::Result<(ExitStatus, Vec<u8>)> {
    if deadline.is_some_and(|at| at <= Instant::now()) {
        return Err(io::ErrorKind::TimedOut.into());
    }
    let mut reactor = Reactor::new()?;
    drop(reactor.child(std::process::id())?); // Capability failure before creating a process.
    let child = command
        .process_group(0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut owned = Owned {
        child,
        group: true,
        reaped: false,
    };
    let mut exit = match reactor.child(owned.child.id()) {
        Ok(exit) => Some(exit),
        Err(error) => {
            owned.cancel(false)?;
            owned.reaped = owned.child.try_wait()?.is_some();
            return Err(if owned.reaped {
                error
            } else {
                io::Error::new(
                    error.kind(),
                    format!(
                        "child {} termination is unconfirmed after exit-monitor failure: {error}",
                        owned.child.id()
                    ),
                )
            });
        }
    };
    let mut stdin = owned.child.stdin.take();
    let mut output = owned.child.stdout.take().unwrap();
    let mut status = None;
    let mut observed = false;
    let mut stdout = Vec::new();
    let result = (|| {
        reactor::nonblocking(stdin.as_ref().unwrap().as_raw_fd())?;
        reactor::nonblocking(output.as_raw_fd())?;
        let mut written = 0;
        let mut closed = false;
        let mut buffer = [0; 65_536];
        loop {
            if deadline.is_some_and(|at| at <= Instant::now()) {
                return Err(io::ErrorKind::TimedOut.into());
            }
            if let Some(pipe) = &mut stdin {
                match pipe.write(&input[written..]) {
                    Ok(count) => written += count,
                    Err(error) if error.kind() == io::ErrorKind::BrokenPipe => {
                        written = input.len()
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                        ) => {}
                    Err(error) => return Err(error),
                }
                if written == input.len() {
                    reactor.interest(pipe.as_raw_fd(), false, false)?;
                    stdin = None;
                }
            }
            if !closed {
                match output.read(&mut buffer) {
                    Ok(count) => {
                        if count > limit - stdout.len() {
                            return Err(io::ErrorKind::InvalidData.into());
                        }
                        stdout.extend_from_slice(&buffer[..count]);
                        closed = count == 0;
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                        ) => {}
                    Err(error) => return Err(error),
                }
            }
            if status.is_some() && closed {
                return Ok(());
            }
            if let Some(pipe) = &stdin {
                reactor.interest(pipe.as_raw_fd(), false, true)?;
            }
            reactor.interest(output.as_raw_fd(), !closed, false)?;
            let ready = match deadline {
                Some(at) => reactor.until(at)?.ok_or(io::ErrorKind::TimedOut)?,
                None => reactor.wait()?,
            };
            if exit.as_ref().is_some_and(|exit| exit.exited(ready)) {
                observed = true;
                owned.cancel(observed)?;
                // NOTE_EXIT may arrive before WNOHANG can reap on Darwin.
                status = Some(owned.child.wait()?);
                owned.reaped = true;
                exit.take();
            }
        }
    })();
    if let Some(pipe) = &stdin {
        let _ = reactor.interest(pipe.as_raw_fd(), false, false);
    }
    let _ = reactor.interest(output.as_raw_fd(), false, false);
    drop((stdin, output));
    let cleanup = (|| -> io::Result<()> {
        owned.cancel(observed)?;
        if status.is_none() {
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                let ready = reactor.until(deadline)?.ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::TimedOut,
                        format!("child {} termination is unconfirmed", owned.child.id()),
                    )
                })?;
                if exit.as_ref().is_some_and(|exit| exit.exited(ready)) {
                    observed = true;
                    // NOTE_EXIT may arrive before WNOHANG can reap on Darwin.
                    status = Some(owned.child.wait()?);
                    owned.reaped = true;
                    break;
                }
            }
        }
        Ok(())
    })();
    if let Err(error) = cleanup {
        return Err(io::Error::new(
            error.kind(),
            format!(
                "child {} cleanup failed: {error}; operation: {}; exit observed: {observed}; reaped: {}",
                owned.child.id(),
                result
                    .as_ref()
                    .err()
                    .map(ToString::to_string)
                    .unwrap_or_else(|| "completed".into()),
                owned.reaped,
            ),
        ));
    }
    result?;
    Ok((status.unwrap(), stdout))
}
