//! Capture writes use one bounded disk queue; they never block the reactor.
use crate::{
    api::{Event, Output},
    json::{self, Data, Json, Value},
};
use std::{
    fs::File,
    io::{self, Write},
    os::unix::fs::OpenOptionsExt,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

/// A capture/replay control (DISPATCH_CAPTURE*, DISPATCH_REPLAY*). Tracing is a test instrument:
/// a helper built without the `capture` feature (Release) ignores the controls, so its
/// environment can never make it write its unredacted IO to disk or run a recorded trace.
pub(crate) fn control(name: &str) -> Option<std::ffi::OsString> {
    if cfg!(feature = "capture") { std::env::var_os(name) } else { None }
}

// Native protocol records can be 32 MiB; the byte bound includes queued owned strings.
const QUEUE: usize = 128 * 1024 * 1024;
struct Record {
    section: String,
    clock: u128,
    op: String,
    args: String,
    error: Option<i32>,
    payload: io::Result<Vec<u8>>,
    encoded: bool,
    cost: usize,
}
enum Message {
    Record(Record),
    Flush(mpsc::SyncSender<io::Result<()>>),
}
pub struct Capture {
    send: Option<mpsc::Sender<Message>>,
    queued: Arc<AtomicUsize>,
    limit: usize,
    pub(super) replay: Option<super::file::Replay>,
    invalid: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<io::Result<()>>>,
    origin: Instant,
}

impl Drop for Capture {
    fn drop(&mut self) {
        if let Err(error) = self.finish() {
            eprintln!("capture invalid: {error}");
        }
    }
}

impl Capture {
    fn write(
        mut file: File,
        receive: mpsc::Receiver<Message>,
        failed: Arc<AtomicBool>,
        queued: Arc<AtomicUsize>,
        limit: u64,
    ) -> io::Result<()> {
        let mut written = 0u64;
        for message in receive {
            let row = match message {
                Message::Record(row) => row,
                Message::Flush(reply) => {
                    let result = file.flush();
                    let failed = result.is_err();
                    let _ = reply.send(result);
                    if failed { return Err(io::Error::other("capture flush failed")); }
                    continue;
                }
            };
            if failed.load(Ordering::Acquire) {
                file.write_all(b"{\"invalid\":\"capture queue overflow\"}\n")?;
                file.flush()?;
                return Ok(());
            }
            let data = if row.encoded {
                row.payload
            } else {
                super::file::encode(&row.payload.map(Output::Bytes), 0)
            };
            let result = data.and_then(|data| {
                let mut output = b"{\"section\":".to_vec();
                crate::wire::string(&mut output, &row.section);
                write!(output, ",\"clock\":{}", row.clock).unwrap();
                for (key, value) in [("op", &row.op), ("args", &row.args), ("data", &hex(&data))] {
                    write!(output, ",\"{key}\":").unwrap();
                    crate::wire::string(&mut output, value);
                }
                output.extend_from_slice(b",\"error\":");
                if let Some(error) = row.error {
                    write!(output, "{error}").unwrap();
                } else {
                    output.extend_from_slice(b"null");
                }
                output.extend_from_slice(b"}\n");
                let next = written
                    .checked_add(output.len() as u64)
                    .ok_or_else(super::file::invalid)?;
                if next > limit {
                    failed.store(true, Ordering::Release);
                    eprintln!("capture invalid: file size limit {limit} bytes; live IO continues");
                    file.write_all(b"{\"invalid\":\"capture file size limit\"}\n")?;
                } else {
                    file.write_all(&output)?;
                    written = next;
                }
                Ok(())
            });
            queued.fetch_sub(row.cost, Ordering::AcqRel);
            if result.is_ok() && failed.load(Ordering::Acquire) {
                return file.flush();
            }
            if let Err(error) = result {
                failed.store(true, Ordering::Release);
                eprintln!("capture invalid: {error}");
                return Err(error);
            }
        }
        if failed.load(Ordering::Acquire) {
            file.write_all(b"{\"invalid\":\"capture queue overflow\"}\n")?;
        }
        file.flush()
    }
    pub(super) fn enabled(&self) -> bool {
        self.send.is_some()
    }
    pub(super) fn tracing(&self) -> bool {
        self.enabled() || self.replay.is_some()
    }
    pub(super) fn offset(&self, at: Instant) -> io::Result<u64> {
        at.saturating_duration_since(self.origin)
            .as_nanos()
            .try_into()
            .map_err(|_| super::file::invalid())
    }
    pub(super) fn event(&self, section: &str, event: &Event) -> io::Result<()> {
        if !self.enabled() {
            return Ok(());
        }
        let fields = match event {
            Event::Ready { fd, read, write } => vec![
                ("kind", Data::String("ready")),
                ("fd", Data::Signed((*fd).into())),
                ("read", Data::Bool(*read)),
                ("write", Data::Bool(*write)),
            ],
            Event::Exit { pid, status } => vec![
                ("kind", Data::String("exit")),
                ("pid", Data::Unsigned((*pid).into())),
                (
                    "status",
                    status.map_or(Data::Null, |v| Data::Signed(v.into())),
                ),
            ],
            Event::Changed { watch, reset } => vec![
                ("kind", Data::String("changed")),
                ("watch", Data::Unsigned(*watch)),
                ("reset", Data::Bool(*reset)),
            ],
            Event::Hook {
                route,
                message,
                reply,
                peer,
            } => {
                let message = hex(message);
                let data = json::write(&Data::Object(vec![
                    ("kind", Data::String("hook")),
                    ("route", Data::Unsigned(*route)),
                    ("message", Data::String(&message)),
                    ("reply", reply.map_or(Data::Null, Data::Unsigned)),
                    (
                        "peer",
                        peer.map_or(Data::Null, |v| Data::Unsigned(v.into())),
                    ),
                ]))
                .map_err(|_| super::file::invalid())?;
                return self.result(section, "event", "", &Ok(Output::Bytes(data)));
            }
            Event::Timer { at } => vec![
                ("kind", Data::String("timer")),
                ("at", Data::Unsigned(self.offset(*at)?)),
            ],
            Event::Closed { reply } => vec![
                ("kind", Data::String("closed")),
                ("reply", Data::Unsigned(*reply)),
            ],
            Event::Process { watch, pid } => vec![
                ("kind", Data::String("process")),
                ("watch", Data::Unsigned(*watch)),
                ("pid", Data::Unsigned((*pid).into())),
            ],
            Event::Done { .. } => return Ok(()),
        };
        let data = json::write(&Data::Object(fields)).map_err(|_| super::file::invalid())?;
        self.result(section, "event", "", &Ok(Output::Bytes(data)))
    }
    pub(super) fn result(
        &self,
        section: &str,
        op: &str,
        args: &str,
        result: &io::Result<Output>,
    ) -> io::Result<()> {
        if self.send.is_none() {
            return Ok(());
        }
        match result {
            Ok(Output::Bytes(bytes)) => self.bytes(section, op, args, None, bytes),
            Err(error) => self.bytes(section, op, args, Some(error), &[]),
            _ => self.record(section, op, args, None, &super::file::encode(result, 0)?),
        }
    }
    pub fn new(capacity: usize) -> io::Result<Self> {
        let replay = control("DISPATCH_REPLAY")
            .map(|path| super::file::Replay::new(path.into(), capacity))
            .transpose()?;
        if replay.is_some() && control("DISPATCH_CAPTURE").is_some() {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let invalid = Arc::new(AtomicBool::new(false));
        let queued = Arc::new(AtomicUsize::new(0));
        let (send, worker) = if let Some(path) = control("DISPATCH_CAPTURE") {
            // A larger trace needs an explicit per-case disk budget. Never rotate or silently truncate.
            let limit =
                std::env::var("DISPATCH_CAPTURE_LIMIT").map_or(Ok(4 * 1024 * 1024 * 1024), |v| {
                    v.parse::<u64>()
                        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
                })?;
            // Descendant helpers inherit the capture setting; each process needs its own file.
            let path = match path.into_string() {
                Ok(text) => {
                    let at = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_nanos();
                    text.replace("%p", &format!("{}-{at}", std::process::id()))
                        .into()
                }
                Err(raw) => raw,
            };
            let file = File::options()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path)
                .inspect_err(|error| eprintln!("capture unavailable: {error}; live IO continues"))
                .ok();
            if let Some(file) = file {
                let (send, receive) = mpsc::channel::<Message>();
                let failed = invalid.clone();
                let pending = queued.clone();
                let worker = thread::Builder::new()
                    .name("dispatch-capture".into())
                    .spawn(move || Self::write(file, receive, failed, pending, limit))?;
                (Some(send), Some(worker))
            } else {
                (None, None)
            }
        } else {
            (None, None)
        };
        Ok(Self {
            send,
            queued,
            limit: QUEUE,
            replay,
            invalid,
            worker,
            origin: Instant::now(),
        })
    }
    pub(super) fn file(
        &self,
        section: &str,
        order: u64,
        args: &str,
        sequence: u64,
        result: &io::Result<super::Output>,
    ) -> io::Result<()> {
        if self.send.is_none() {
            return Ok(());
        }
        self.record(
            section,
            "file.done",
            &format!("{order} {args}"),
            None,
            &super::file::encode(result, sequence)?,
        )
    }
    pub(super) fn flush(&self) -> io::Result<()> {
        if let Some(send) = &self.send {
            let (reply, receive) = mpsc::sync_channel(1);
            send.send(Message::Flush(reply)).map_err(|_| io::Error::other("capture writer ended"))?;
            receive.recv().map_err(|_| io::Error::other("capture writer ended"))??;
        }
        Ok(())
    }
    pub(super) fn finish(&mut self) -> io::Result<()> {
        if let Some(replay) = &self.replay {
            replay.finish()?;
        }
        self.send.take();
        if let Some(worker) = self.worker.take() {
            worker
                .join()
                .map_err(|_| io::Error::other("capture worker panicked"))??;
        }
        Ok(())
    }
    /// Raw successful IO bytes (or its error); encoding happens on the writer thread.
    pub(super) fn bytes(
        &self,
        section: &str,
        op: &str,
        args: &str,
        error: Option<&io::Error>,
        bytes: &[u8],
    ) -> io::Result<()> {
        self.enqueue(section, op, args, error, bytes, false)
    }
    pub fn record(
        &self,
        section: &str,
        op: &str,
        args: &str,
        error: Option<&io::Error>,
        bytes: &[u8],
    ) -> io::Result<()> {
        self.enqueue(section, op, args, error, bytes, true)
    }
    #[allow(deprecated)] // fetch_update is the spelling supported by the pinned Mac compiler.
    fn enqueue(
        &self,
        section: &str,
        op: &str,
        args: &str,
        error: Option<&io::Error>,
        bytes: &[u8],
        encoded: bool,
    ) -> io::Result<()> {
        let Some(send) = &self.send else {
            return Ok(());
        };
        if self.invalid.load(Ordering::Acquire) {
            return Ok(());
        }
        let cost = std::mem::size_of::<Record>()
            + section.len()
            + op.len()
            + args.len()
            + bytes.len()
            + error.map_or(0, |e| e.to_string().len());
        if self
            .queued
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |size| {
                size.checked_add(cost).filter(|size| *size <= self.limit)
            })
            .is_err()
        {
            self.invalid.store(true, Ordering::Release);
            eprintln!("capture invalid: queued bytes exceed128MiB; live IO continues");
            return Ok(());
        }
        let row = Record {
            section: section.into(),
            clock: self.origin.elapsed().as_nanos(),
            op: op.into(),
            args: args.into(),
            error: error.map(|e| e.raw_os_error().unwrap_or(-1)),
            payload: if encoded || error.is_none() {
                Ok(bytes.to_vec())
            } else {
                let e = error.unwrap();
                Err(e
                    .raw_os_error()
                    .map(io::Error::from_raw_os_error)
                    .unwrap_or_else(|| io::Error::new(e.kind(), e.to_string())))
            },
            encoded,
            cost,
        };
        if send.send(Message::Record(row)).is_err() {
            self.queued.fetch_sub(cost, Ordering::AcqRel);
            self.invalid.store(true, Ordering::Release);
            eprintln!("capture invalid: writer closed or queue full; live IO continues");
        }
        Ok(())
    }
}

pub(super) fn event(bytes: &[u8], origin: Instant) -> io::Result<Event> {
    use super::file::{field, invalid};
    let json = Json::parse(bytes).map_err(|_| invalid())?;
    let v = json.root();
    Ok(match field(v, "kind", Value::string)? {
        "ready" => Event::Ready {
            fd: field(v, "fd", Value::signed)?
                .try_into()
                .map_err(|_| invalid())?,
            read: field(v, "read", Value::boolean)?,
            write: field(v, "write", Value::boolean)?,
        },
        "exit" => Event::Exit {
            pid: field(v, "pid", Value::unsigned)?
                .try_into()
                .map_err(|_| invalid())?,
            status: v
                .get("status")
                .and_then(Value::signed)
                .map(i32::try_from)
                .transpose()
                .map_err(|_| invalid())?,
        },
        "changed" => Event::Changed {
            watch: field(v, "watch", Value::unsigned)?,
            reset: field(v, "reset", Value::boolean)?,
        },
        "timer" => Event::Timer {
            at: origin
                .checked_add(Duration::from_nanos(field(v, "at", Value::unsigned)?))
                .ok_or_else(invalid)?,
        },
        "hook" => Event::Hook {
            route: field(v, "route", Value::unsigned)?,
            message: unhex(field(v, "message", Value::string)?)?,
            reply: v.get("reply").and_then(Value::unsigned),
            peer: v
                .get("peer")
                .and_then(Value::unsigned)
                .map(u32::try_from)
                .transpose()
                .map_err(|_| super::file::invalid())?,
        },
        "closed" => Event::Closed {
            reply: field(v, "reply", Value::unsigned)?,
        },
        "process" => Event::Process {
            watch: field(v, "watch", Value::unsigned)?,
            pid: field(v, "pid", Value::unsigned)?
                .try_into()
                .map_err(|_| invalid())?,
        },
        _ => return Err(invalid()),
    })
}

pub(super) fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        output.push(DIGITS[usize::from(byte >> 4)] as char);
        output.push(DIGITS[usize::from(byte & 15)] as char);
    }
    output
}

pub(super) fn unhex(text: &str) -> io::Result<Vec<u8>> {
    let (pairs, tail) = text.as_bytes().as_chunks::<2>();
    if !tail.is_empty() {
        return Err(io::ErrorKind::InvalidData.into());
    }
    pairs
        .iter()
        .map(|pair| {
            let mut value = 0;
            for &byte in pair {
                let digit = char::from(byte)
                    .to_digit(16)
                    .ok_or(io::ErrorKind::InvalidData)?;
                value = value * 16 + digit as u8;
            }
            Ok(value)
        })
        .collect()
}
