//! One ordered native control stream; transport effects go through Io.

use crate::{
    control,
    mux::{NativeDone, error, gone},
    snapshot::Snapshot,
};
use dispatch_helper_core::api::*;
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet, VecDeque},
    io,
    path::PathBuf,
    process::{Command, Stdio},
    rc::Rc,
    time::{Duration, Instant},
};
pub(crate) type Batch = Vec<control::Lines>;
pub(crate) enum Notice {
    Attached,
    Refresh,
    Reply(NativeDone, Result<Batch, Error>),
    Output(u32, Vec<u8>),
    Notification(String),
}
struct Group {
    /// Offset of this group's command line in everything ever queued.
    start: u64,
    left: usize,
    replies: Batch,
    done: Option<NativeDone>,
    /// Each command's name (its first word), for stream errors.
    names: Vec<String>,
}
impl Group {
    fn consume(
        queue: &mut VecDeque<Self>,
        replied: &mut Option<String>,
        number: u64,
        lines: control::Lines,
        failed: bool,
    ) -> Result<Option<Notice>, Error> {
        let Some(group) = queue.front_mut() else {
            return Err(control::unexpected(
                &format!(
                    "reply {number} with no command waiting (the last reply was for {})",
                    replied.as_deref().unwrap_or("no command")
                ),
                None,
                None,
            ));
        };
        let index = group.replies.len().min(group.names.len() - 1);
        *replied = Some(group.names[index].clone());
        group.left -= 1;
        group.replies.push(lines);
        if !failed && group.left != 0 {
            return Ok(None);
        }
        let group = queue.pop_front().unwrap();
        let result = if failed {
            Err(error(String::from_utf8_lossy(
                group.replies.last().unwrap().text(),
            )))
        } else {
            Ok(group.replies)
        };
        Ok(group.done.map(|done| Notice::Reply(done, result)))
    }
}
#[derive(Default)]
pub(crate) struct Client {
    child: Option<Spawned>,
    writer: Option<ControlWrite>,
    writing: Option<usize>,
    written: Rc<RefCell<Option<Result<(), Error>>>>,
    parser: control::Decoder,
    /// The command whose reply came last (c1654cc TmuxSession lastReplied).
    replied: Option<String>,
    bytes: Vec<u8>,
    head: usize,
    /// Bytes ever queued; `bytes` holds the unsent tail of them.
    queued: u64,
    pending: VecDeque<Group>,
    at: Option<Instant>,
    attached: bool,
    pub snapshot: Option<Snapshot>,
    pub expected: Option<(u64, i32, String)>,
    pub cwd: BTreeMap<u32, PathBuf>,
    pub available: BTreeMap<u64, (u32, u32)>,
    pub closed: BTreeSet<u64>,
    pub dismissed: BTreeSet<u32>,
    pub ended: bool,
    pub notices: Vec<Notice>,
    pub refreshing: bool,
    pub again: bool,
    pub waiters: Vec<crate::mux::Continue<Result<(), Error>>>,
    /// Waiters registered while a read was in flight; the next read completes them.
    pub later: Vec<crate::mux::Continue<Result<(), Error>>>,
    /// Creations in flight; a detach waits for them like c1654cc pendingDetach
    /// (TmuxCoordinator.swift:1219-1223) and then includes their panes.
    pub creating: usize,
    pub detaching: bool,
    /// detach-client was sent; until tmux's %exit ends it, no new work may use this client.
    pub leaving: bool,
    /// tmux itself ended this client (%exit: session gone, server exit, detach): its targets
    /// are gone, unlike a transport that failed under it.
    pub exited: bool,
    /// The transport refused a write; see `refuse`.
    refused: bool,
}
impl Client {
    pub fn new(io: &mut dyn Io, mut command: Command) -> io::Result<Self> {
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let child = io.spawn(command, None)?;
        for fd in [child.output, child.stderr].into_iter().flatten() {
            if let Err(error) = io.interest(fd, true, false) {
                for fd in [child.input, child.output, child.stderr]
                    .into_iter()
                    .flatten()
                {
                    io.close(fd);
                }
                return Err(error);
            }
        }
        Ok(Self {
            child: Some(child),
            ..Self::default()
        })
    }
    pub fn adopt(writer: ControlWrite) -> Self {
        Self {
            writer: Some(writer),
            ..Self::default()
        }
    }
    fn write(&mut self, io: &mut dyn Io) -> io::Result<()> {
        if self.refused {
            return Ok(());
        }
        let result = self.written.borrow_mut().take();
        if let Some(result) = result {
            // A refused write never reached tmux (and a cut line never runs).
            let end = self.writing.take().unwrap();
            if result.is_err() {
                self.refuse();
                return Ok(());
            }
            self.head = end;
        }
        if let Some(writer) = &self.writer {
            if self.writing.is_some() {
                return Ok(());
            }
            if self.head == self.bytes.len() {
                self.bytes.clear();
                self.head = 0;
            }
            if !self.bytes.is_empty() {
                let written = self.written.clone();
                self.writing = Some(self.bytes.len());
                writer(
                    io,
                    &self.bytes[self.head..],
                    Box::new(move |io, result| {
                        *written.borrow_mut() = Some(result);
                        io.timer(io.now());
                    }),
                );
            }
            return Ok(());
        }
        let child = self.child.as_ref().unwrap();
        if self.head < self.bytes.len() {
            match io.write(child.input.unwrap(), &self.bytes[self.head..]) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(n) => self.head += n,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(e),
            }
        }
        if self.head == self.bytes.len() {
            self.bytes.clear();
            self.head = 0;
        }
        io.interest(child.input.unwrap(), false, !self.bytes.is_empty())
    }
    pub fn commands(
        &mut self,
        io: &mut dyn Io,
        commands: &[String],
        replies: usize,
        done: &mut Option<NativeDone>,
    ) -> io::Result<()> {
        if self.refused {
            return Err(io::Error::other("Tmux node is no longer available"));
        }
        if self.ended
            || commands.is_empty()
            || replies == 0
            || commands.iter().any(|s| s.contains(['\r', '\n']))
        {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let bytes = commands.join(" ; ") + "\n";
        if bytes.len() > control::MAXIMUM.saturating_sub(self.bytes.len()) {
            return Err(io::ErrorKind::OutOfMemory.into());
        }
        self.pending.push_back(Group {
            start: self.queued,
            left: replies,
            replies: Vec::new(),
            done: done.take(),
            names: commands
                .iter()
                .map(|c| c.split(' ').next().unwrap_or_default().to_owned())
                .collect(),
        });
        self.bytes.extend_from_slice(bytes.as_bytes());
        self.queued += bytes.len() as u64;
        let result = self.write(io);
        if result.is_err() {
            *done = self.pending.back_mut().unwrap().done.take();
        }
        result
    }
    pub fn schedule(&mut self, io: &mut dyn Io) {
        if self.at.is_none() {
            let at = io.now() + Duration::from_millis(20);
            self.at = Some(at);
            io.timer(at);
        }
    }
    pub fn finish(&mut self, io: &mut dyn Io) {
        if self.ended {
            return;
        }
        self.ended = true;
        // Written (or being written) bytes reached the transport: their command may have run.
        let sent = self.queued - self.bytes.len() as u64 + self.writing.unwrap_or(self.head) as u64;
        self.bytes.clear();
        self.at = None;
        for group in self.pending.drain(..) {
            if let Some(done) = group.done {
                // Never written, or the session ended: the target is gone (nothing changed by
                // this request). Written into a transport that failed: it may have run.
                let closed = if self.exited {
                    gone("Tmux node is no longer available")
                } else if group.start >= sent {
                    error("Tmux node is no longer available")
                } else {
                    Error {
                        code: "uncertain",
                        message: "Tmux control connection closed".into(),
                    }
                };
                self.notices.push(Notice::Reply(done, Err(closed)));
            }
        }
        self.writer = None;
        if let Some(mut child) = self.child.take() {
            for fd in [child.input.take(), child.output.take(), child.stderr.take()]
                .into_iter()
                .flatten()
            {
                io.close(fd);
            }
        }
    }
    /// Fed by a claimed stream (Multiplexer::stream), not a process of its own.
    pub fn adopted(&self) -> bool {
        self.writer.is_some()
    }
    /// Usable for new work: not ended, not leaving, its transport still takes writes.
    pub fn live(&self) -> bool {
        !self.ended && !self.leaving && !self.refused
    }
    /// The transport refused a write (the control client is gone): nothing more is sent, and
    /// every request waits for the stream's own verdict so its answer follows the topology
    /// that verdict publishes (%exit: gone; its end or a refused stream: closed), C11.
    fn refuse(&mut self) {
        self.refused = true;
    }
    pub fn detach(&mut self, io: &mut dyn Io) {
        self.leaving = true;
        if self.writer.is_some() {
            if self
                .commands(io, &["detach-client".into()], 1, &mut None)
                .is_err()
            {
                self.finish(io);
            }
        } else {
            self.finish(io);
        }
    }
    pub fn event(&mut self, io: &mut dyn Io, event: &Event) -> io::Result<()> {
        if self.ended {
            return Ok(());
        }
        if self.writer.is_some() && matches!(event, Event::Timer { .. }) {
            self.write(io)?;
        }
        match event {
            Event::Exit { pid, .. } if self.child.as_ref().is_some_and(|c| *pid == c.pid) => {
                self.finish(io);
                return Ok(());
            }
            Event::Timer { at } if self.at.is_some_and(|deadline| *at >= deadline) => {
                self.at = None;
                self.notices.push(Notice::Refresh);
            }
            Event::Ready {
                fd, write: true, ..
            } if self.child.as_ref().is_some_and(|c| Some(*fd) == c.input) => self.write(io)?,
            _ => {}
        }
        let Event::Ready { fd, read: true, .. } = event else {
            return Ok(());
        };
        let Some(child) = &mut self.child else {
            return Ok(());
        };
        if Some(*fd) != child.output && Some(*fd) != child.stderr {
            return Ok(());
        }
        let mut input = [0; 65_536];
        let count = match io.read(*fd, &mut input) {
            Ok(0) if Some(*fd) == child.stderr => {
                io.close(*fd);
                child.stderr = None;
                return Ok(());
            }
            Ok(0) => {
                self.finish(io);
                return Ok(());
            }
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(()),
            Err(e) => return Err(e),
        };
        if Some(*fd) == child.stderr {
            return Ok(());
        }
        self.receive(io, &input[..count])
    }
    /// A broken stream ends this client, like c1654cc TmuxSession.receive.
    pub fn receive(&mut self, io: &mut dyn Io, input: &[u8]) -> io::Result<()> {
        if self.ended {
            return Ok(());
        }
        let result = self.events(io, input);
        if result.is_err() {
            self.finish(io);
        }
        result.map_err(|e| io::Error::other(format!("Invalid tmux control stream: {}", e.message)))
    }
    fn events(&mut self, io: &mut dyn Io, input: &[u8]) -> Result<(), Error> {
        for event in self.parser.feed(input)? {
            if self.ended {
                break;
            }
            match event {
                control::Event::Reply {
                    flags: 0, failed, ..
                } if !self.attached => {
                    if failed {
                        return Err(error("Could not attach tmux control client"));
                    }
                    self.attached = true;
                    self.notices.push(Notice::Attached);
                }
                // After the last window closes, queued commands can fail before %exit
                // arrives; the control client is already gone (TmuxSession.swift:122-128).
                control::Event::Reply {
                    flags,
                    ref lines,
                    failed: true,
                    ..
                } if flags & 1 == 1
                    && [b"no current client".as_slice(), b"no current target"]
                        .contains(&lines.text()) =>
                {
                    self.exited = true;
                    self.finish(io);
                }
                control::Event::Reply {
                    number,
                    flags,
                    lines,
                    failed,
                } if flags & 1 == 1 => {
                    if failed {
                        self.available.clear();
                    }
                    let notice = Group::consume(
                        &mut self.pending,
                        &mut self.replied,
                        number,
                        lines,
                        failed,
                    )?;
                    self.notices.extend(notice);
                }
                control::Event::Output { pane, bytes } => self
                    .notices
                    .push(Notice::Output(u32::try_from(pane).map_err(error)?, bytes)),
                control::Event::Notification(line) if line.starts_with("%exit") => {
                    self.exited = true;
                    self.finish(io);
                }
                control::Event::Notification(line) => {
                    if let Some((event, id)) = line.split_once(' ')
                        && let Ok(window) = crate::snapshot::id(id, '@')
                    {
                        match event {
                            "%unlinked-window-close" => {
                                self.closed.insert(window);
                                self.available.remove(&window);
                            }
                            // window-close is an unlink that leaves this window linked here.
                            "%window-close" | "%window-add" => {
                                self.closed.remove(&window);
                            }
                            _ => {}
                        }
                    }
                    if [
                        "%window",
                        "%unlinked-window",
                        "%layout-change",
                        "%session",
                        "%pane-mode-changed",
                        "%subscription-changed",
                    ]
                    .iter()
                    .any(|p| line.starts_with(p))
                    {
                        self.schedule(io);
                    }
                    self.notices.push(Notice::Notification(line));
                }
                _ => {}
            }
        }
        Ok(())
    }
}
