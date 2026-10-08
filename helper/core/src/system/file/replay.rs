//! Each IO section consumes its own recorded sequence, including UI IO.
use super::*;
use std::cell::{Cell, RefCell};
pub(crate) struct Replay {
    reader: RefCell<io::BufReader<File>>,
    pub(crate) rows: RefCell<BTreeMap<String, VecDeque<(u64, String)>>>,
    pub(crate) streams: RefCell<BTreeMap<(String, RawFd, String), VecDeque<u8>>>,
    pub(crate) origin: Instant,
    pub(crate) clock: Cell<Instant>,
    pub(crate) timed: bool,
    pub(crate) output: Option<PathBuf>,
    pub(crate) diagnostics: Option<PathBuf>,
}
impl Replay {
    pub(crate) fn new(path: PathBuf, _capacity: usize) -> io::Result<Self> {
        let mut reader = io::BufReader::new(open(&path)?);
        let mut rows: BTreeMap<String, VecDeque<(u64, String)>> = BTreeMap::new();
        let mut timed = false;
        loop {
            let offset = reader.stream_position()?;
            let Some(json) = line(&mut reader)? else {
                break;
            };
            let row = json.root();
            rows.entry(field(row, "section", Value::string)?.into())
                .or_default()
                .push_back((offset, field(row, "op", Value::string)?.into()));
            timed |= row.get("clock").is_some();
        }
        let origin = Instant::now();
        Ok(Self {
            reader: RefCell::new(reader),
            rows: RefCell::new(rows),
            streams: RefCell::new(BTreeMap::new()),
            origin,
            clock: Cell::new(origin),
            timed,
            output: std::env::var_os("DISPATCH_REPLAY_OUTPUT").map(PathBuf::from),
            diagnostics: std::env::var_os("DISPATCH_REPLAY_DIAGNOSTICS").map(PathBuf::from),
        })
    }
    pub(crate) fn take(&self, section: &str) -> io::Result<Row> {
        let (offset, op) = self
            .rows
            .borrow_mut()
            .get_mut(section)
            .and_then(VecDeque::pop_front)
            .ok_or_else(|| {
                eprintln!("replay exhausted section: {section}");
                invalid()
            })?;
        let mut reader = self.reader.borrow_mut();
        reader.seek(SeekFrom::Start(offset))?;
        let document = line(&mut reader)?.ok_or_else(invalid)?;
        let value = document.root();
        if let Some(clock) = value.get("clock").and_then(Value::unsigned) {
            let at = self
                .origin
                .checked_add(Duration::from_nanos(clock))
                .ok_or_else(invalid)?;
            self.clock.set(self.clock.get().max(at));
        }
        Ok(Row {
            op,
            args: field(value, "args", Value::string)?.into(),
            data: capture::unhex(field(value, "data", Value::string)?)?,
        })
    }
    pub(crate) fn call(&self, section: &str, op: &str, args: &str) -> io::Result<Completion> {
        let offset = self.rows.borrow().get(section).and_then(|rows| rows.front()).map(|row| row.0);
        let row = self.take(section)?;
        if row.op != op || row.args != args {
            self.mismatch(Data::Object(vec![
                ("section", Data::String(section)),
                ("offset", offset.map_or(Data::Null, Data::Unsigned)),
                ("expected", Data::Object(vec![("op", Data::String(&row.op)), ("args", Data::String(&row.args))])),
                ("actual", Data::Object(vec![("op", Data::String(op)), ("args", Data::String(args))])),
            ]));
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "invalid file capture: capture {section}: expected {}, got {op}; arguments match: {}",
                    row.op,
                    row.args == args
                ),
            ));
        }
        decode(&row.data)
    }
    pub(crate) fn mismatch(&self, value: Data<'_>) {
        let Some(root) = self.diagnostics.as_ref().or(self.output.as_ref()) else { return };
        let saved = (|| -> io::Result<()> {
            use std::os::unix::fs::DirBuilderExt;
            let data = json::write(&value).map_err(|_| invalid())?;
            std::fs::DirBuilder::new().recursive(true).mode(0o700).create(root)?;
            File::options().write(true).create_new(true).mode(0o600)
                .open(root.join("mismatch.json"))?.write_all(&data)
        })();
        if let Err(error) = saved {
            if error.kind() != io::ErrorKind::AlreadyExists {
                eprintln!("replay mismatch evidence could not be saved: {:?}", error.kind());
            }
        }
    }
    pub(crate) fn next(&self) -> io::Result<Option<(String, Row)>> {
        let section = self
            .rows
            .borrow()
            .iter()
            .filter_map(|(section, rows)| {
                rows.front()
                    .filter(|(_, op)| matches!(op.as_str(), "event" | "file.done" | "next.error"))
                    .map(|(offset, _)| (*offset, section.clone()))
            })
            .min()
            .map(|(_, section)| section);
        section
            .map(|section| self.take(&section).map(|row| (section, row)))
            .transpose()
    }
    pub(crate) fn finish(&self) -> io::Result<()> {
        for (section, rows) in self.rows.borrow().iter() {
            if let Some((offset, op)) = rows.front() {
                let remaining = rows.len() as u64;
                self.mismatch(Data::Object(vec![
                    ("section", Data::String(section)), ("op", Data::String(op)),
                    ("offset", Data::Unsigned(*offset)), ("remaining", Data::Unsigned(remaining)),
                ]));
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("unconsumed: {section} {op} offset={offset} remaining={remaining}"),
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
