use crate::error::{Code, Failure};
use crate::exec::{ExecEvents, InputEnd, confirm, pump};
use crate::session::Session;
use russh::ChannelWriteHalf;
use russh::client;
use std::os::fd::RawFd;
use std::sync::Arc;
use tokio::sync::watch;

/// A running interactive shell's control side: the socketpair carries its terminal, this resizes it.
#[derive(Clone)]
pub struct Shell {
    write: Arc<ChannelWriteHalf<client::Msg>>,
}

impl Shell {
    /// Sends `window-change` (no pixel size). The server answers nothing; a closed channel fails.
    pub async fn resize(&self, cols: u32, rows: u32) -> Result<(), Failure> {
        self.write.window_change(cols, rows, 0, 0).await.map_err(Failure::from)
    }
}

/// A shell's window changes in order: one task sends them, the latest size wins (sizes superseded while one is in
/// flight are skipped), and sizes set before the shell started are sent once it has. Separate tasks per change could
/// reach the server out of order and leave the PTY at a stale size.
#[derive(Clone)]
pub struct Resizer {
    sizes: watch::Sender<(u32, u32)>,
    opened: (u32, u32),
}

impl Resizer {
    /// For a shell opened at `cols` x `rows`.
    pub fn new(cols: u32, rows: u32) -> Resizer {
        Resizer { sizes: watch::channel((cols, rows)).0, opened: (cols, rows) }
    }

    /// Asks for `cols` x `rows`; returns at once.
    pub fn resize(&self, cols: u32, rows: u32) {
        self.sizes.send_if_modified(|size| {
            let changed = *size != (cols, rows);
            *size = (cols, rows);
            changed
        });
    }

    /// Starts the one task that sends sizes to `shell`, until its channel closes or every `Resizer` is dropped.
    pub fn attach(&self, shell: Shell) {
        let mut changes = self.sizes.subscribe();
        let mut sent = self.opened;
        crate::runtime().spawn(async move {
            loop {
                let size = *changes.borrow_and_update();
                if size != sent {
                    if shell.resize(size.0, size.1).await.is_err() {
                        return;
                    }
                    sent = size;
                }
                if changes.changed().await.is_err() {
                    return;
                }
            }
        });
    }
}

/// Opens a session channel with a PTY (`term`, `cols` x `rows`, no pixel size, no terminal modes: the server's
/// defaults) and starts the user's login shell on it, then pumps it through a socketpair as `exec` does. The PTY
/// merges stdout and stderr, so `events.stderr` is never called. Unlike exec, the end of the caller's input
/// (`shutdown(SHUT_WR)` or `close`) closes the channel: a terminal has no end of file.
pub async fn shell(session: &Session, term: &str, cols: u32, rows: u32, events: Arc<dyn ExecEvents>) -> Result<(RawFd, Shell), Failure> {
    let channel = session.open_session().await?;
    let (mut read, write) = channel.split();
    let mut early = Vec::new();
    let opened = async {
        write.request_pty(true, term, cols, rows, 0, 0, &[]).await.map_err(Failure::from)?;
        confirm(&mut read, &mut early, "the server refused the terminal (pty-req)", "the channel closed before the terminal opened").await?;
        write.request_shell(true).await.map_err(Failure::from)?;
        confirm(&mut read, &mut early, "the server refused the shell request", "the channel closed before the shell started").await
    };
    if let Err(failure) = opened.await {
        // A refused request leaves the channel open on the server: close it rather than leak it.
        if failure.code == Code::Refused {
            let _ = write.close().await;
        }
        return Err(failure);
    }
    let write = Arc::new(write);
    let fd = pump(read, write.clone(), early, events, InputEnd::Close)?;
    Ok((fd, Shell { write }))
}
