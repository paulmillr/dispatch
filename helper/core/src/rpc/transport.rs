//! helper2 rpc/transport.rs readiness and queue loop, using the shared Io effects.
//! Native owners open/verify channels and supply encoding (LF or WebSocket); this stream
//! never retries an operation, interprets a JSON response, or claims native execution.
use super::{Error, Lines, Queue};
use crate::api::{Address, Event, Io};
use std::{cell::Cell, collections::VecDeque, io, os::fd::RawFd, rc::Rc, time::Instant};

pub trait Codec {
    fn feed(
        &mut self,
        bytes: &[u8],
        emit: &mut dyn FnMut(&[u8]) -> Result<(), Error>,
    ) -> Result<(), Error>;
    fn finish(&self) -> Result<(), Error>;
}

/// Raw reads for PTYs, stderr or a caller's WebSocket decoder.
pub struct Raw;
impl Codec for Raw {
    fn feed(
        &mut self,
        bytes: &[u8],
        emit: &mut dyn FnMut(&[u8]) -> Result<(), Error>,
    ) -> Result<(), Error> {
        emit(bytes)
    }
    fn finish(&self) -> Result<(), Error> {
        Ok(())
    }
}
impl Codec for Lines {
    fn feed(
        &mut self,
        bytes: &[u8],
        emit: &mut dyn FnMut(&[u8]) -> Result<(), Error>,
    ) -> Result<(), Error> {
        self.feed(bytes, emit)
    }
    fn finish(&self) -> Result<(), Error> {
        self.finish()
    }
}

/// Exact encoded-byte outcome. A response still has to be correlated separately in Pending.
#[derive(Debug)]
pub struct Written {
    pub length: usize,
    pub count: usize,
    pub error: Option<io::Error>,
}
pub type Finish = Box<dyn FnOnce(&mut dyn Io, Written)>;
/// Actual encoded-byte progress, observable before deferred callbacks run.
#[derive(Clone, Debug, Default)]
pub struct Progress(Rc<Cell<usize>>);
impl Progress {
    pub fn written(&self) -> usize {
        self.0.get()
    }
}
struct Write {
    length: usize,
    count: usize,
    deadline: Option<Instant>,
    done: Option<Finish>,
    progress: Option<Progress>,
}
impl Write {
    fn finish(self, io: &mut dyn Io, error: Option<io::Error>) {
        if let Some(done) = self.done {
            let written = Written {
                length: self.length,
                count: self.count,
                error,
            };
            io.defer(Box::new(move |io| done(io, written)));
        }
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Received {
    pub data: Vec<Vec<u8>>,
    pub eof: bool,
}

/// One bounded socket or split-pipe stream; callers keep native response IDs/deadlines.
pub struct Stream<C> {
    pub input: RawFd,
    pub output: RawFd,
    codec: C,
    queue: Queue,
    writes: VecDeque<Write>,
    closed: bool,
    finishing: bool,
    connecting: Option<Instant>,
}

impl<C: Codec> Stream<C> {
    pub fn new(input: RawFd, output: RawFd, codec: C, limit: usize) -> Self {
        Self {
            input,
            output,
            codec,
            queue: Queue::new(limit),
            writes: VecDeque::new(),
            closed: false,
            finishing: false,
            connecting: None,
        }
    }
    /// Start through System, then prove establishment on readiness before any queued bytes.
    /// Loopback-only TCP follows helper2 rpc/transport.rs:36; Unix policy belongs to the owner.
    pub fn connect(
        io: &mut dyn Io,
        address: &Address,
        codec: C,
        limit: usize,
        deadline: Instant,
    ) -> io::Result<Self> {
        if deadline <= io.now() {
            return Err(io::ErrorKind::TimedOut.into());
        }
        if matches!(address, Address::Tcp(address) if !address.ip().is_loopback()) {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        let fd = io.connect(address)?;
        let mut stream = Self::new(fd, fd, codec, limit);
        stream.connecting = Some(deadline);
        io.timer(deadline);
        stream.attach(io)?;
        Ok(stream)
    }
    pub fn ready(&self) -> bool {
        !self.closed && self.connecting.is_none()
    }
    pub fn attach(&mut self, io: &mut dyn Io) -> io::Result<()> {
        let result = self.refresh(io);
        if let Err(error) = &result {
            self.fail(io, error);
        }
        result
    }
    /// Already encoded native frame. Rejection and every accepted completion are deferred
    /// exactly once; return value tells the producer whether it was queued, not delivered.
    pub fn send(
        &mut self,
        io: &mut dyn Io,
        bytes: Vec<u8>,
        deadline: Option<Instant>,
        done: Option<Finish>,
    ) -> io::Result<()> {
        self.enqueue(io, bytes, deadline, done, None)
    }
    pub fn send_tracked(
        &mut self,
        io: &mut dyn Io,
        bytes: Vec<u8>,
        deadline: Option<Instant>,
        done: Option<Finish>,
        progress: Progress,
    ) -> io::Result<()> {
        self.enqueue(io, bytes, deadline, done, Some(progress))
    }
    fn enqueue(
        &mut self,
        io: &mut dyn Io,
        bytes: Vec<u8>,
        deadline: Option<Instant>,
        done: Option<Finish>,
        progress: Option<Progress>,
    ) -> io::Result<()> {
        let write = Write {
            length: bytes.len(),
            count: 0,
            deadline,
            done,
            progress,
        };
        let result = if self.closed || self.finishing {
            Err(io::ErrorKind::NotConnected.into())
        } else {
            self.queue
                .push(bytes)
                .map_err(|_| io::ErrorKind::WouldBlock.into())
        };
        if let Err(error) = result {
            write.finish(io, Some(copy(&error)));
            return Err(error);
        }
        if write.length == 0 {
            write.finish(io, None);
            return Ok(());
        }
        if let Some(at) = deadline {
            io.timer(at);
        }
        self.writes.push_back(write);
        self.attach(io)
    }
    pub fn written(&self) -> usize {
        self.writes.front().map_or(0, |w| w.count)
    }
    pub fn retained(&self) -> usize {
        self.queue.remaining() + self.written()
    }
    pub fn closed(&self) -> bool {
        self.closed
    }

    /// Flush then close the outgoing direction, preserving final incoming bytes.
    /// System owns pipe closure/socket SHUT_WR and the exact captured outcome.
    pub fn finish(&mut self, io: &mut dyn Io) -> io::Result<()> {
        self.finishing = true;
        self.attach(io)
    }
    pub fn event(&mut self, io: &mut dyn Io, event: &Event) -> io::Result<Received> {
        if self.closed {
            return Ok(Received::default());
        }
        let result = (|| {
            if self.connecting.is_some_and(|at| at <= io.now())
                || self
                    .writes
                    .iter()
                    .any(|w| w.deadline.is_some_and(|at| at <= io.now()))
            {
                return Err(io::ErrorKind::TimedOut.into());
            }
            if matches!(event, Event::Timer { .. }) {
                return Ok(Received::default());
            }
            let Event::Ready { fd, read, write } = *event else {
                return Ok(Received::default());
            };
            if self.connecting.is_some() && fd == self.input {
                io.connected(fd)?;
                self.connecting = None;
            }
            if write
                && fd == self.input
                && let Some(bytes) = self.queue.front()
            {
                match io.write(fd, &bytes[..bytes.len().min(65536)]) {
                    Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                    Ok(count) => {
                        self.queue
                            .consume(count)
                            .map_err(|_| io::ErrorKind::InvalidData)?;
                        let front = self.writes.front_mut().unwrap();
                        front.count += count;
                        if let Some(progress) = &front.progress {
                            progress.0.set(front.count);
                        }
                        if front.count == front.length {
                            self.writes.pop_front().unwrap().finish(io, None);
                        }
                    }
                    Err(e)
                        if matches!(
                            e.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                        ) => {}
                    Err(error) => return Err(error),
                }
            }
            let mut received = Received::default();
            if read && fd == self.output {
                let mut bytes = [0; 65536];
                match io.read(fd, &mut bytes) {
                    Ok(0) => {
                        self.codec.finish().map_err(invalid)?;
                        received.eof = true;
                        self.fail(io, &io::ErrorKind::UnexpectedEof.into());
                    }
                    Ok(count) => self
                        .codec
                        .feed(&bytes[..count], &mut |bytes| {
                            received.data.push(bytes.to_vec());
                            Ok(())
                        })
                        .map_err(invalid)?,
                    Err(e)
                        if matches!(
                            e.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                        ) => {}
                    Err(error) => return Err(error),
                }
            }
            self.refresh(io)?;
            Ok(received)
        })();
        if let Err(error) = &result {
            self.fail(io, error);
        }
        result
    }
    fn refresh(&mut self, io: &mut dyn Io) -> io::Result<()> {
        if self.closed {
            return Ok(());
        }
        if self.finishing && self.writes.is_empty() && self.input >= 0 {
            io.shutdown(self.input)?;
            self.input = -1;
        }
        if self.input >= 0 {
            io.interest(
                self.input,
                self.input == self.output,
                self.connecting.is_some() || !self.writes.is_empty(),
            )?;
        }
        if self.output != self.input {
            io.interest(self.output, true, false)?;
        }
        Ok(())
    }
    /// Full close; no resending pending bytes and no completions after an earlier completion.
    pub fn close(&mut self, io: &mut dyn Io) {
        self.fail(io, &io::ErrorKind::Interrupted.into());
    }
    fn fail(&mut self, io: &mut dyn Io, error: &io::Error) {
        if self.closed {
            return;
        }
        self.closed = true;
        if self.input >= 0 {
            io.close(self.input);
        }
        if self.output != self.input {
            io.close(self.output);
        }
        for write in self.writes.drain(..) {
            write.finish(io, Some(copy(error)));
        }
        self.queue = Queue::new(0);
    }
}
fn invalid(error: Error) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("native framing: {error:?}"),
    )
}
fn copy(error: &io::Error) -> io::Error {
    error
        .raw_os_error()
        .map(io::Error::from_raw_os_error)
        .unwrap_or_else(|| io::Error::new(error.kind(), error.to_string()))
}
