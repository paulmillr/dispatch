//! Capture writes use one bounded disk queue; they never block the reactor. The file is the
//! binary capture format (capture/trace.rs): typed values in zstd, certified by its footer.
#[cfg(feature = "capture")]
mod zstd;
#[cfg(not(feature = "capture"))]
#[path = "capture/without_zstd.rs"]
mod zstd;
pub mod trace;
pub mod screen;
pub mod views;

use crate::{
    api::Event,
    json::Data,
    wire::body,
};
use std::{
    fs::File,
    io::{self, Write},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
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
/// environment can never make it write its unredacted IO to disk or run a recorded trace (the
/// helper binary refuses to start with DISPATCH_REPLAY then: ignored, it would run live).
pub(crate) fn control(name: &str) -> Option<std::ffi::OsString> {
    if cfg!(feature = "capture") { std::env::var_os(name) } else { None }
}

// Native protocol records can be 32 MiB; the byte bound includes queued owned strings. The writer compresses on one
// thread while a terminal flood is recorded several times over (pty reads, wire frames): with bzip2 (~10 MB/s, before
// zstd) a 23 MB flood queued past 128 MiB. Memory, not disk, bounds it.
pub(super) const QUEUE: usize = 1024 * 1024 * 1024;

/// What came back: an encoded value, or an error (encoded on the writer thread).
enum Payload {
    Value(Vec<u8>),
    Error(io::Error),
}
struct Row {
    section: String,
    clock: u64,
    op: String,
    args: Vec<u8>,
    sequence: u64,
    payload: Payload,
    error: Option<i32>,
    cost: usize,
}
enum Message {
    Row(Row),
    Checkpoint(mpsc::SyncSender<io::Result<()>>),
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

/// A capture file's byte budget: past it, writes fail and the recording becomes invalid.
struct Budget {
    file: File,
    written: u64,
    limit: u64,
}
impl Write for Budget {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let next = self.written.saturating_add(bytes.len() as u64);
        if next > self.limit {
            return Err(io::Error::other("capture file size limit"));
        }
        let count = self.file.write(bytes)?;
        self.written += count as u64;
        Ok(count)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

impl Capture {
    fn write(
        file: File,
        receive: mpsc::Receiver<Message>,
        failed: Arc<AtomicBool>,
        queued: Arc<AtomicUsize>,
        limit: u64,
    ) -> io::Result<()> {
        let header = trace::Header {
            layer: trace::Layer::Native,
            wire: crate::wire::VERSION,
        };
        let mut writer = trace::Writer::new(
            Budget {
                file,
                written: 0,
                limit,
            },
            &header,
        )?;
        let result = (|| {
            for message in receive {
                let row = match message {
                    Message::Row(row) => row,
                    Message::Checkpoint(reply) => {
                        let result = writer.checkpoint();
                        let error = result.as_ref().err().map(|e| io::Error::new(e.kind(), e.to_string()));
                        let _ = reply.send(result);
                        if let Some(error) = error {
                            return Err(error);
                        }
                        continue;
                    }
                };
                queued.fetch_sub(row.cost, Ordering::AcqRel);
                if failed.load(Ordering::Acquire) {
                    return Err(io::Error::other("capture queue overflow"));
                }
                let output = match row.payload {
                    Payload::Error(error) => super::file::encode(&Err(error))?,
                    Payload::Value(value) => value,
                };
                writer.push(&trace::Record {
                    section: row.section,
                    clock: row.clock,
                    op: row.op,
                    args: row.args,
                    sequence: row.sequence,
                    output,
                    error: row.error,
                })?;
            }
            if failed.load(Ordering::Acquire) {
                return Err(io::Error::other("capture queue overflow"));
            }
            Ok(())
        })();
        match result {
            Ok(()) => writer.finish().map(|_| ()),
            Err(error) => {
                failed.store(true, Ordering::Release);
                eprintln!("capture invalid: {error}; live IO continues");
                let _ = writer.invalid(&error.to_string());
                Ok(())
            }
        }
    }
    pub(super) fn enabled(&self) -> bool {
        self.send.is_some()
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
            } => vec![
                ("kind", Data::String("hook")),
                ("route", Data::Unsigned(*route)),
                ("message", Data::Bytes(message)),
                ("reply", reply.map_or(Data::Null, Data::Unsigned)),
                (
                    "peer",
                    peer.map_or(Data::Null, |v| Data::Unsigned(v.into())),
                ),
            ],
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
        self.record(section, "event", &Data::Null, None, 0, value(&Data::Object(fields))?)
    }
    /// A startup fact (account, pid, image, ...): its typed value, read back by System.
    pub(super) fn fact(&self, op: &str, fact: &io::Result<Data<'_>>) -> io::Result<()> {
        match fact {
            Ok(fact) => self.record("startup", op, &Data::Null, None, 0, value(fact)?),
            Err(error) => self.failure("startup", op, &Data::Null, error),
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
                // Locked until the file is whole (the writer closes it after the footer, or the process ends): a
                // collector waits for it instead of copying a running helper's cut snapshot.
                // SAFETY: this new file's own descriptor; LOCK_EX | LOCK_NB never blocks.
                unsafe { super::native::flock(file.as_raw_fd(), 2 | 4) };
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
    /// A job's completion; `args` are the encoded args its submit recorded.
    pub(super) fn file(
        &self,
        section: &str,
        order: u64,
        args: &[u8],
        sequence: u64,
        result: &io::Result<super::Output>,
    ) -> io::Result<()> {
        if self.send.is_none() {
            return Ok(());
        }
        let job = body::decode_plain(args).map_err(|_| super::file::invalid())?;
        let output = super::file::encode(result)?;
        self.record(section, "file.done", &Data::Array(vec![Data::Unsigned(order), job]), None, sequence, output)
    }
    /// Everything recorded so far becomes a complete capture (after the startup facts, before exec).
    pub(super) fn flush(&self) -> io::Result<()> {
        if let Some(send) = &self.send {
            let (reply, receive) = mpsc::sync_channel(1);
            send.send(Message::Checkpoint(reply)).map_err(|_| io::Error::other("capture writer ended"))?;
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
    /// A failed effect: its error object (file::encode) is written by the writer thread.
    pub(super) fn failure(&self, section: &str, op: &str, args: &Data<'_>, error: &io::Error) -> io::Result<()> {
        self.enqueue(section, op, args, Some(error), 0, Payload::Error(super::copy(error)))
    }
    /// An encoded output value (file::encode, a fact, an event).
    pub fn record(
        &self,
        section: &str,
        op: &str,
        args: &Data<'_>,
        error: Option<&io::Error>,
        sequence: u64,
        output: Vec<u8>,
    ) -> io::Result<()> {
        self.enqueue(section, op, args, error, sequence, Payload::Value(output))
    }
    #[allow(deprecated)] // fetch_update is the spelling supported by the pinned Mac compiler.
    fn enqueue(
        &self,
        section: &str,
        op: &str,
        args: &Data<'_>,
        error: Option<&io::Error>,
        sequence: u64,
        payload: Payload,
    ) -> io::Result<()> {
        let Some(send) = &self.send else {
            return Ok(());
        };
        if self.invalid.load(Ordering::Acquire) {
            return Ok(());
        }
        let args = value(args)?;
        let cost = std::mem::size_of::<Row>()
            + section.len()
            + op.len()
            + args.len()
            + match &payload {
                Payload::Value(bytes) => bytes.len(),
                Payload::Error(error) => error.to_string().len(),
            };
        if self
            .queued
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |size| {
                size.checked_add(cost).filter(|size| *size <= self.limit)
            })
            .is_err()
        {
            self.invalid.store(true, Ordering::Release);
            eprintln!("capture invalid: queued bytes exceed {} MiB; live IO continues", QUEUE >> 20);
            return Ok(());
        }
        let row = Row {
            section: section.into(),
            clock: self.origin.elapsed().as_nanos() as u64,
            op: op.into(),
            args,
            sequence,
            payload,
            error: error.map(|e| e.raw_os_error().unwrap_or(-1)),
            cost,
        };
        if send.send(Message::Row(row)).is_err() {
            self.queued.fetch_sub(cost, Ordering::AcqRel);
            self.invalid.store(true, Ordering::Release);
            eprintln!("capture invalid: writer closed or queue full; live IO continues");
        }
        Ok(())
    }
}

/// A value as the capture stores it: the wire grammar without the schema's names.
pub(super) fn value(data: &Data<'_>) -> io::Result<Vec<u8>> {
    body::encode_plain(data).map_err(|error| io::Error::other(error.message))
}

pub(super) fn grid(grid: &crate::api::Grid) -> Data<'static> {
    let pixels = |(width, height): (u16, u16)| Data::Array(vec![Data::Unsigned(width.into()), Data::Unsigned(height.into())]);
    Data::Object(vec![
        ("columns", Data::Unsigned(grid.columns.into())),
        ("rows", Data::Unsigned(grid.rows.into())),
        ("pixels", grid.pixels.map_or(Data::Null, pixels)),
    ])
}

/// A command in a record: program, arguments, directory and environment changes (a removed
/// variable is null). Stable Rust cannot read env_clear, so a command's cleared environment
/// is not part of it.
pub(super) fn command(command: &std::process::Command) -> Data<'_> {
    use std::os::unix::ffi::OsStrExt;
    fn bytes(value: &std::ffi::OsStr) -> Data<'_> {
        Data::Bytes(value.as_bytes())
    }
    Data::Object(vec![
        ("program", bytes(command.get_program())),
        ("args", Data::Array(command.get_args().map(bytes).collect())),
        ("cwd", command.get_current_dir().map_or(Data::Null, Data::from)),
        (
            "env",
            Data::Array(
                command.get_envs().map(|(name, value)| Data::Array(vec![bytes(name), value.map_or(Data::Null, bytes)])).collect(),
            ),
        ),
    ])
}

/// A checked file transaction's expectation (Job::Write, Job::Remove).
pub(super) fn expected(expected: &crate::api::Expected) -> io::Result<Data<'static>> {
    use crate::api::Expected;
    let Expected::Same(guard) = expected else {
        return Ok(Data::String(if matches!(expected, Expected::Any) { "any" } else { "absent" }));
    };
    let time = |ns: Option<i128>| ns.map_or(Ok(Data::Null), |ns| i64::try_from(ns).map(Data::Signed).map_err(|_| super::file::invalid()));
    Ok(Data::Object(vec![
        ("kind", guard.kind.map_or(Data::Null, |kind| Data::String(super::file::kind(kind)))),
        ("size", guard.size.map_or(Data::Null, Data::Unsigned)),
        ("device", guard.device.map_or(Data::Null, Data::Unsigned)),
        ("inode", guard.inode.map_or(Data::Null, Data::Unsigned)),
        ("modified_ns", time(guard.modified_ns)?),
        ("changed_ns", time(guard.changed_ns)?),
    ]))
}

/// Recorded values back as the effects' own types.
pub(super) mod read {
    use crate::json::Data;
    pub(in crate::system) fn grid(value: &Data<'_>) -> Option<crate::api::Grid> {
        Some(crate::api::Grid {
            columns: value.get("columns")?.unsigned()?.try_into().ok()?,
            rows: value.get("rows")?.unsigned()?.try_into().ok()?,
            pixels: match value.get("pixels")? {
                Data::Null => None,
                pixels => {
                    let mut pair = pixels.array()?;
                    let mut next = || pair.next()?.unsigned()?.try_into().ok();
                    Some((next()?, next()?))
                }
            },
        })
    }
}

/// A recorded event (Capture::event).
pub(super) fn event(output: &[u8], origin: Instant) -> io::Result<Event> {
    use super::file::{field, invalid};
    let v = body::decode_plain(output).map_err(|_| invalid())?;
    let v = &v;
    Ok(match field(v, "kind", Data::string)? {
        "ready" => Event::Ready {
            fd: field(v, "fd", Data::signed)?
                .try_into()
                .map_err(|_| invalid())?,
            read: field(v, "read", Data::boolean)?,
            write: field(v, "write", Data::boolean)?,
        },
        "exit" => Event::Exit {
            pid: field(v, "pid", Data::unsigned)?
                .try_into()
                .map_err(|_| invalid())?,
            status: v
                .get("status")
                .and_then(Data::signed)
                .map(i32::try_from)
                .transpose()
                .map_err(|_| invalid())?,
        },
        "changed" => Event::Changed {
            watch: field(v, "watch", Data::unsigned)?,
            reset: field(v, "reset", Data::boolean)?,
        },
        "timer" => Event::Timer {
            at: origin
                .checked_add(Duration::from_nanos(field(v, "at", Data::unsigned)?))
                .ok_or_else(invalid)?,
        },
        "hook" => Event::Hook {
            route: field(v, "route", Data::unsigned)?,
            message: field(v, "message", Data::bytes)?.to_vec(),
            reply: v.get("reply").and_then(Data::unsigned),
            peer: v
                .get("peer")
                .and_then(Data::unsigned)
                .map(u32::try_from)
                .transpose()
                .map_err(|_| invalid())?,
        },
        "closed" => Event::Closed {
            reply: field(v, "reply", Data::unsigned)?,
        },
        "process" => Event::Process {
            watch: field(v, "watch", Data::unsigned)?,
            pid: field(v, "pid", Data::unsigned)?
                .try_into()
                .map_err(|_| invalid())?,
        },
        _ => return Err(invalid()),
    })
}
