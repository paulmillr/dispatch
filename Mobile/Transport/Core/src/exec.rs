use crate::error::{Code, Failure};
use crate::session::Session;
use russh::client;
use russh::{ChannelMsg, ChannelReadHalf, ChannelWriteHalf};
use std::os::fd::{FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::sync::Arc;
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::sync::Notify;

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
/// socket. Closing the socket entirely also closes the channel once the remote writes again (then `exited` reports
/// what arrived before, usually `Lost`).
pub async fn exec(session: &Session, command: &str, events: Arc<dyn ExecEvents>) -> Result<RawFd, Failure> {
    let channel = session.open_session().await?;
    channel.exec(true, command).await.map_err(Failure::from)?;
    let (mut read, write) = channel.split();
    let mut early = Vec::new();
    confirm(&mut read, &mut early, "the server refused the exec request", "the channel closed before the command started").await?;
    pump(read, Arc::new(write), early, events, InputEnd::Eof)
}

/// What the engine sends when the caller's end of the socket stops giving input (`shutdown(SHUT_WR)` or `close`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum InputEnd {
    /// EOF on the channel: the command reads end of file and may still answer (exec).
    Eof,
    /// Close the channel: a PTY has no end of file (^D is data), so the end of input is the end of the session.
    Close,
}

/// Waits for the reply to a request sent with `want_reply`, keeping what arrives before it (a fast command's
/// output can come first) for the pump.
pub(crate) async fn confirm(read: &mut ChannelReadHalf, early: &mut Vec<ChannelMsg>, refused: &str, closed: &str) -> Result<(), Failure> {
    loop {
        match read.wait().await {
            Some(ChannelMsg::Success) => return Ok(()),
            Some(ChannelMsg::Failure) => return Err(Failure::new(Code::Refused, refused)),
            Some(other) => early.push(other),
            None => return Err(Failure::new(Code::Closed, closed)),
        }
    }
}

/// Connects a started channel to a new socketpair and returns the caller's end. Two tasks pump it: the uplink
/// copies the socket into the channel (as fast as the SSH window allows), the downlink copies channel data into
/// the socket (as fast as the caller reads), reports stderr, and calls `events.exited` once the channel closed.
pub(crate) fn pump(
    mut read: ChannelReadHalf,
    write: Arc<ChannelWriteHalf<client::Msg>>,
    early: Vec<ChannelMsg>,
    events: Arc<dyn ExecEvents>,
    input_end: InputEnd,
) -> Result<RawFd, Failure> {
    // Both ends stay owned until the caller gets theirs: an error below closes them.
    let (ours, theirs) = socketpair()?;
    let ours = {
        let stream = std::os::unix::net::UnixStream::from(ours);
        stream.set_nonblocking(true).map_err(|e| Failure::new(Code::Network, e.to_string()))?;
        tokio::net::UnixStream::from_std(stream).map_err(|e| Failure::new(Code::Network, e.to_string()))?
    };
    let (rd, mut wr) = ours.into_split();
    // russh forgets a channel once it sent its own close and drops the server's reply, so the channel never
    // reports Close to us: whoever closes it here also ends the downlink.
    let closed = Arc::new(Notify::new());
    let uplink = {
        let write = write.clone();
        let closed = closed.clone();
        tokio::spawn(async move {
            let mut source = BufReader::with_capacity(256 * 1024, rd);
            let mut sink = write.make_writer();
            let copied = tokio::io::copy_buf(&mut source, &mut sink).await.is_ok();
            match input_end {
                InputEnd::Eof if copied => {
                    let _ = sink.flush().await;
                    let _ = write.eof().await;
                }
                InputEnd::Eof => {}
                InputEnd::Close => {
                    if copied {
                        let _ = sink.flush().await;
                    }
                    let _ = write.close().await;
                    closed.notify_one();
                }
            }
        })
    };
    tokio::spawn(async move {
        let mut status = None;
        let mut signal = None;
        let mut messages = early.into_iter();
        loop {
            let message = match messages.next() {
                Some(message) => Some(message),
                // What already arrived (an exit status racing our close) goes first.
                None => tokio::select! {
                    biased;
                    message = read.wait() => message,
                    _ = closed.notified() => break,
                },
            };
            match message {
                Some(ChannelMsg::Data { data }) => {
                    if wr.write_all(&data).await.is_err() {
                        // The caller closed its end: nobody will read the rest.
                        let _ = write.close().await;
                        break;
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
