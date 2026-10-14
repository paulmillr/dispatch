//! Each IO section consumes its own recorded sequence, including UI IO. The capture is read
//! once into memory (capture/trace.rs); each section queues indices into its records.
use super::*;
use crate::system::capture::trace::{self, Record};
use std::cell::{Cell, RefCell};
pub(crate) struct Replay {
    records: Vec<Record>,
    pub(crate) rows: RefCell<BTreeMap<String, VecDeque<usize>>>,
    pub(crate) streams: RefCell<BTreeMap<(String, RawFd, String), VecDeque<u8>>>,
    pub(crate) origin: Instant,
    pub(crate) clock: Cell<Instant>,
    pub(crate) output: Option<PathBuf>,
    pub(crate) diagnostics: Option<PathBuf>,
}
impl Replay {
    pub(crate) fn new(path: PathBuf, _capacity: usize) -> io::Result<Self> {
        // The expanded capture is bounded like the file that recorded it (capture.rs).
        let (_, records) = trace::read(open(&path)?, 4 * 1024 * 1024 * 1024)?;
        let mut rows: BTreeMap<String, VecDeque<usize>> = BTreeMap::new();
        for (index, record) in records.iter().enumerate() {
            rows.entry(record.section.clone()).or_default().push_back(index);
        }
        let origin = Instant::now();
        Ok(Self {
            records,
            rows: RefCell::new(rows),
            streams: RefCell::new(BTreeMap::new()),
            origin,
            clock: Cell::new(origin),
            output: std::env::var_os("DISPATCH_REPLAY_OUTPUT").map(PathBuf::from),
            diagnostics: std::env::var_os("DISPATCH_REPLAY_DIAGNOSTICS").map(PathBuf::from),
        })
    }
    /// The operation `section` replays next, without taking it.
    pub(crate) fn peek(&self, section: &str) -> Option<&str> {
        let rows = self.rows.borrow();
        rows.get(section)
            .and_then(|rows| rows.front())
            .map(|&index| self.records[index].op.as_str())
    }
    pub(crate) fn take(&self, section: &str) -> io::Result<&Record> {
        let index = self
            .rows
            .borrow_mut()
            .get_mut(section)
            .and_then(VecDeque::pop_front)
            .ok_or_else(|| {
                eprintln!("replay exhausted section: {section}");
                invalid()
            })?;
        let record = &self.records[index];
        let at = self
            .origin
            .checked_add(Duration::from_nanos(record.clock))
            .ok_or_else(invalid)?;
        self.clock.set(self.clock.get().max(at));
        Ok(record)
    }
    /// The recorded output value of the next `op` of `section`, whose args must equal `args`.
    pub(crate) fn value(&self, section: &str, op: &str, args: &Data<'_>) -> io::Result<&Record> {
        let index = self.rows.borrow().get(section).and_then(|rows| rows.front()).copied();
        let args = capture::value(args)?;
        let record = self.take(section)?;
        if record.op != op || record.args != args {
            let expected = crate::wire::body::decode_plain(&record.args).map_err(|_| invalid())?;
            let actual = crate::wire::body::decode_plain(&args).map_err(|_| invalid())?;
            self.mismatch(Data::Object(vec![
                ("section", Data::String(section)),
                ("record", index.map_or(Data::Null, |i| Data::Unsigned(i as u64))),
                ("expected", Data::Object(vec![("op", Data::String(&record.op)), ("args", expected)])),
                ("actual", Data::Object(vec![("op", Data::String(op)), ("args", actual)])),
            ]));
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "invalid file capture: capture {section}: expected {}, got {op}; arguments match: {}",
                    record.op,
                    record.args == args
                ),
            ));
        }
        Ok(record)
    }
    /// Diagnostics beside the replay (a binary capture value cannot be shown as JSON: its
    /// args are rendered as the inspect tool shows them).
    pub(crate) fn mismatch(&self, value: Data<'_>) {
        let Some(root) = self.diagnostics.as_ref().or(self.output.as_ref()) else { return };
        let saved = (|| -> io::Result<()> {
            use std::os::unix::fs::DirBuilderExt;
            let data = capture::value(&value)?;
            std::fs::DirBuilder::new().recursive(true).mode(0o700).create(root)?;
            File::options().write(true).create_new(true).mode(0o600)
                .open(root.join("mismatch.value"))?.write_all(&data)
        })();
        if let Err(error) = saved {
            if error.kind() != io::ErrorKind::AlreadyExists {
                eprintln!("replay mismatch evidence could not be saved: {:?}", error.kind());
            }
        }
    }
    /// The earliest asynchronous record (event, job completion, next error) heading a section.
    pub(crate) fn next(&self) -> io::Result<Option<(String, &Record)>> {
        let section = self
            .rows
            .borrow()
            .iter()
            .filter_map(|(section, rows)| {
                rows.front()
                    .filter(|&&index| {
                        matches!(self.records[index].op.as_str(), "event" | "file.done" | "next.error")
                    })
                    .map(|&index| (index, section.clone()))
            })
            .min()
            .map(|(_, section)| section);
        section
            .map(|section| self.take(&section).map(|row| (section, row)))
            .transpose()
    }
    pub(crate) fn finish(&self) -> io::Result<()> {
        for (section, rows) in self.rows.borrow().iter() {
            if let Some(&index) = rows.front() {
                let remaining = rows.len() as u64;
                let op = &self.records[index].op;
                self.mismatch(Data::Object(vec![
                    ("section", Data::String(section)), ("op", Data::String(op)),
                    ("record", Data::Unsigned(index as u64)), ("remaining", Data::Unsigned(remaining)),
                ]));
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("unconsumed: {section} {op} record={index} remaining={remaining}"),
                ));
            }
        }
        for ((section, fd, op), pending) in self.streams.borrow().iter() {
            if !pending.is_empty() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!(
                        "unconsumed stream: {section} {op} fd={fd} bytes={}",
                        pending.len()
                    ),
                ));
            }
        }
        Ok(())
    }
}
