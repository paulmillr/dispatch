use crate::error::{Code, Failure};
use crate::session::Session;
use russh::ChannelMsg;
use std::os::fd::{FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::sync::Arc;
use tokio::io::{AsyncWriteExt, BufReader};

/// How a remote command ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Exit {
    Status(u32),
    Signal(String),
    /// The channel or connection went away without a status.
    Lost,
}

pub trait ExecEvents: Send + Sync + 'static {
    /// The command's stderr, as it arrives (kept apart from the stdout stream).
    fn stderr(&self, bytes: &[u8]);
    /// Called exactly once, after the channel closed, as the last call.
    fn exited(&self, exit: Exit);
}

/// Unix socket buffers: macOS defaults to 8 KiB, which caps throughput.
const SOCKET_BUFFER: libc::c_int = 1 << 20;

/// Runs `command` on a new session channel and returns the caller's end of a socketpair carrying the
/// command's stdin (writes) and stdout (reads). The engine pumps both directions with backpressure: it reads
/// the socket only as fast as the SSH window allows, and reads the channel only as fast as the socket drains.
/// Half-closing the socket (`shutdown(SHUT_WR)`) or closing it sends EOF; the remote's EOF half-closes the
/// socket. Closing the socket entirely also closes the channel once the remote writes again.
pub async fn exec(session: &Session, command: &str, events: Arc<dyn ExecEvents>) -> Result<RawFd, Failure> {
    let channel = session.open_session().await?;
    channel.exec(true, command).await.map_err(Failure::from)?;
    let (mut read, write) = channel.split();
    let mut early = Vec::new();
    loop {
        match read.wait().await {
            Some(ChannelMsg::Success) => break,
            Some(ChannelMsg::Failure) => return Err(Failure::new(Code::Refused, "the server refused the exec request")),
            Some(other) => early.push(other),
            None => return Err(Failure::new(Code::Closed, "the channel closed before the command started")),
        }
    }
    // Both ends stay owned until the caller gets theirs: an error below closes them.
    let (ours, theirs) = socketpair()?;
    let ours = {
        let stream = std::os::unix::net::UnixStream::from(ours);
        stream.set_nonblocking(true).map_err(|e| Failure::new(Code::Network, e.to_string()))?;
        tokio::net::UnixStream::from_std(stream).map_err(|e| Failure::new(Code::Network, e.to_string()))?
    };
    let (rd, mut wr) = ours.into_split();
    let write = Arc::new(write);
    let uplink = {
        let write = write.clone();
        tokio::spawn(async move {
            let mut source = BufReader::with_capacity(256 * 1024, rd);
            let mut sink = write.make_writer();
            if tokio::io::copy_buf(&mut source, &mut sink).await.is_ok() {
                let _ = sink.flush().await;
                let _ = write.eof().await;
            }
        })
    };
    tokio::spawn(async move {
        let mut status = None;
        let mut signal = None;
        let mut forwarding = true;
        let mut messages = early.into_iter();
        loop {
            let message = match messages.next() {
                Some(message) => Some(message),
                None => read.wait().await,
            };
            match message {
                Some(ChannelMsg::Data { data }) => {
                    if forwarding && wr.write_all(&data).await.is_err() {
                        // The caller closed its end: nobody will read the rest.
                        forwarding = false;
                        let _ = write.close().await;
                    }
                }
                Some(ChannelMsg::ExtendedData { data, ext: 1 }) => events.stderr(&data),
                Some(ChannelMsg::Eof) => {
                    let _ = wr.shutdown().await;
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => status = Some(exit_status),
                Some(ChannelMsg::ExitSignal { signal_name, .. }) => signal = Some(format!("{signal_name:?}")),
                Some(ChannelMsg::Close) | None => break,
                Some(_) => {}
            }
        }
        uplink.abort();
        drop(wr);
        events.exited(match (status, signal) {
            (Some(status), _) => Exit::Status(status),
            (None, Some(signal)) => Exit::Signal(signal),
            (None, None) => Exit::Lost,
        });
    });
    Ok(theirs.into_raw_fd())
}

fn socketpair() -> Result<(OwnedFd, OwnedFd), Failure> {
    let mut fds = [0 as libc::c_int; 2];
    if unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, fds.as_mut_ptr()) } != 0 {
        return Err(Failure::new(Code::Network, std::io::Error::last_os_error().to_string()));
    }
    // SAFETY: socketpair succeeded, so both are open descriptors nothing else owns.
    let owned = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    for fd in fds {
        unsafe {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            let one: libc::c_int = 1;
            #[cfg(target_vendor = "apple")]
            libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_NOSIGPIPE, (&one as *const libc::c_int).cast(), size_of::<libc::c_int>() as u32);
            for option in [libc::SO_SNDBUF, libc::SO_RCVBUF] {
                libc::setsockopt(fd, libc::SOL_SOCKET, option, (&SOCKET_BUFFER as *const libc::c_int).cast(), size_of::<libc::c_int>() as u32);
            }
        }
    }
    Ok(owned)
}
