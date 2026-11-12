//! chat.list's read of a transcript: only its end, only what a list row shows (`Overview`), and
//! nothing a chat reads or holds (no page, cursor, cache generation or state). A harness projects
//! each line (`Line`); this reads the bytes, newest line first, and keeps one summary per file.
//!
//! - A transcript whose (device, inode, size, modification time) are unchanged costs one stat.
//! - One that grew is read from the end of the last complete line read before (with the 64 bytes
//!   before it, which must be as they were: else it was written again and is read as new).
//! - Otherwise its last `TAIL` bytes are read, then more before them (each read as long as all
//!   before it) until an assistant text and a title are found, or `TITLED` bytes once the text
//!   is, or `CAP` bytes in all, or the start of the file.
//! - A read takes the size the stat found: lines appended meanwhile wait for the next read, and
//!   an unfinished last line is left for it too. A file replaced or shortened between the stat and
//!   the read is stat'ed again (twice at most).
//!
//! Reads run as jobs (`Io::then`) in the caller's section; calls for a file being read wait for
//! that read, or, when they came after it started, for one more read after it.
use crate::api::*;
use std::{
    cell::RefCell,
    collections::BTreeMap,
    io,
    path::{Path, PathBuf},
    rc::Rc,
};

/// Bytes the first read of a transcript takes from its end.
pub const TAIL: u64 = 256 * 1024;
/// Most bytes read back from the end while no assistant text is found.
pub const CAP: u64 = 4 * 1024 * 1024;
/// Once the assistant text is found, most bytes read back (in all) for a title.
pub const TITLED: u64 = 1024 * 1024;
/// Summaries kept; the oldest go first.
const ENTRIES: usize = 256;

/// What one transcript line gives a list row: the harness's projection of the line.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Line {
    /// The line yields a record with this time.
    pub time_ms: Option<i64>,
    /// Its newest non-empty assistant text, and that record's time.
    pub answer: Option<(String, Option<i64>)>,
    /// It ends a turn at this time.
    pub ended: Option<i64>,
    /// It starts a turn at this time.
    pub started: Option<i64>,
    /// It names the conversation.
    pub title: Option<String>,
}

/// A harness's projection of lines, newest first; one per read.
pub type Classify = Box<dyn FnMut(&[u8]) -> Line>;

/// What a file's lines gave so far, the newest of each kind.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Found {
    time_ms: Option<i64>,
    answer: Option<(String, Option<i64>)>,
    ended: Option<i64>,
    started: Option<i64>,
    title: Option<String>,
}

impl Found {
    /// Lines in file order, folded newest first.
    fn scan(&mut self, lines: &[u8], classify: &mut Classify) {
        for line in lines.split(|byte| *byte == b'\n').rev() {
            if line.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            let line = classify(line);
            if self.time_ms.is_none() {
                self.time_ms = line.time_ms;
            }
            // A turn end older than the answer changes nothing a row shows.
            if self.ended.is_none() && self.answer.is_none() {
                self.ended = line.ended;
            }
            if self.answer.is_none() {
                self.answer = line.answer.and_then(|(text, time)| Overview::cut(&text).map(|text| (text, time)));
            }
            self.started = self.started.or(line.started);
            if self.title.is_none() {
                self.title = line.title;
            }
        }
    }
    /// `newer` (lines after these) over these.
    fn under(self, newer: Found) -> Found {
        Found {
            time_ms: newer.time_ms.or(self.time_ms),
            ended: newer.ended.or(self.ended),
            answer: newer.answer.or(self.answer),
            started: newer.started.or(self.started),
            title: newer.title.or(self.title),
        }
    }
    fn listing(&self) -> Overview {
        Overview {
            preview: self.answer.as_ref().map(|(text, _)| text.clone()),
            time_ms: self.time_ms,
            reply_ms: Overview::reply(self.answer.as_ref().and_then(|(_, time)| *time), self.ended),
            started_ms: self.started,
            title: self.title.clone(),
        }
    }
}

/// One file's summary: the revision it was read at, where its last complete line ended and the
/// bytes before that end.
#[derive(Clone, Debug)]
struct Entry {
    session: String,
    device: u64,
    inode: u64,
    size: u64,
    modified_ns: i128,
    complete: u64,
    anchor: Vec<u8>,
    found: Found,
    used: u64,
}

type Waiters = Vec<Done<Overview>>;

/// Summaries by path, and the reads under way.
#[derive(Default)]
pub struct Tails {
    entries: BTreeMap<PathBuf, Entry>,
    /// Calls waiting for the read under way, and those that came after it started.
    reading: BTreeMap<PathBuf, (Waiters, Waiters)>,
    clock: u64,
}

pub type Shared = Rc<RefCell<Tails>>;

impl Tails {
    /// Forget a file's summary (its conversation ended).
    pub fn forget(&mut self, path: &Path) {
        self.entries.remove(path);
    }
}

/// The list row of the transcript at `path` (conversation `session`, whose lines `classify`
/// projects; `titled`: its lines can name it), as described above. A missing file gives an
/// empty row, as an empty page did.
pub fn listing(
    tails: &Shared,
    io: &mut dyn Io,
    path: &Path,
    session: &str,
    titled: bool,
    classify: fn(&str) -> Classify,
    done: Done<Overview>,
) {
    {
        let mut shared = tails.borrow_mut();
        if let Some((_, later)) = shared.reading.get_mut(path) {
            later.push(done);
            return;
        }
        shared.reading.insert(path.to_owned(), (vec![done], Vec::new()));
    }
    let read = Read { tails: tails.clone(), path: path.to_owned(), session: session.to_owned(), titled, classify, attempts: 0 };
    read.stat(io);
}

struct Read {
    tails: Shared,
    path: PathBuf,
    session: String,
    titled: bool,
    classify: fn(&str) -> Classify,
    attempts: u8,
}

/// A backward search under way.
struct Search {
    classify: Classify,
    metadata: Metadata,
    found: Found,
    /// The lowest offset read so far.
    start: u64,
    /// Bytes from `start` through its first newline: the end of a line that began before.
    head: Vec<u8>,
    /// End of the file's last complete line, once a newline was read, and the bytes before it.
    complete: Option<u64>,
    anchor: Vec<u8>,
}

fn failure(error: io::Error) -> Error {
    Error { code: "io", message: error.to_string() }
}

/// Bytes kept from before a summary's end, to tell an append from a file written again.
const ANCHOR: usize = 64;
fn anchor(read: &[u8]) -> Vec<u8> {
    read[read.len().saturating_sub(ANCHOR)..].to_vec()
}

impl Read {
    fn submit(self, io: &mut dyn Io, job: Job, next: impl FnOnce(Self, &mut dyn Io, io::Result<Output>) + 'static) {
        match io.submit(job) {
            Ok(work) => io.then(work, Box::new(move |io, result| next(self, io, result))),
            Err(error) => self.finish(io, Err(failure(error))),
        }
    }

    fn stat(self, io: &mut dyn Io) {
        let job = Job::Stat { path: self.path.clone(), follow: true };
        self.submit(io, job, |read, io, result| match result {
            Ok(Output::Metadata(metadata)) if metadata.kind == FileKind::File => read.stated(io, metadata),
            Ok(Output::Metadata(_)) => read.finish(io, Err(Error { code: "transcript", message: "The transcript is not a file".into() })),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                read.tails.borrow_mut().entries.remove(&read.path);
                read.finish(io, Ok(Overview::default()))
            }
            Err(error) => read.finish(io, Err(failure(error))),
            Ok(_) => read.finish(io, Err(Error { code: "io", message: "Expected transcript metadata".into() })),
        });
    }

    fn stated(self, io: &mut dyn Io, metadata: Metadata) {
        let entry = self.tails.borrow().entries.get(&self.path).cloned().filter(|entry| {
            entry.session == self.session && entry.device == metadata.device && entry.inode == metadata.inode
        });
        match entry {
            Some(entry) if entry.size == metadata.size && entry.modified_ns == metadata.modified_ns => {
                let listing = entry.found.listing();
                self.store(entry);
                self.finish(io, Ok(listing));
            }
            Some(entry) if metadata.size > entry.size && metadata.size - entry.complete <= CAP => {
                self.append(io, entry, metadata)
            }
            _ => self.fresh(io, metadata),
        }
    }

    /// Read the file's end as if it was never read.
    fn fresh(self, io: &mut dyn Io, metadata: Metadata) {
        let search = Search {
            classify: (self.classify)(&self.session),
            metadata,
            found: Found::default(),
            start: metadata.size,
            head: Vec::new(),
            complete: None,
            anchor: Vec::new(),
        };
        self.further(io, search);
    }

    /// A read's `length` bytes of the file the stat found (`metadata`; appended to since is the
    /// same file), else the file is stat'ed again (twice at most) and None.
    fn checked(self, io: &mut dyn Io, result: io::Result<Output>, metadata: Metadata, length: u64) -> Option<(Self, Vec<u8>)> {
        match result {
            Ok(Output::Read { before, bytes, .. })
                if before.device == metadata.device
                    && before.inode == metadata.inode
                    && before.size >= metadata.size
                    && bytes.len() as u64 == length =>
            {
                Some((self, bytes))
            }
            Ok(Output::Read { .. }) if self.attempts < 2 => {
                let mut again = self;
                again.attempts += 1;
                again.stat(io);
                None
            }
            Ok(Output::Read { .. }) => {
                self.finish(io, Err(Error { code: "changed", message: "The transcript was replaced while it was read".into() }));
                None
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound && self.attempts < 2 => {
                let mut again = self;
                again.attempts += 1;
                again.stat(io);
                None
            }
            Err(error) => {
                self.finish(io, Err(failure(error)));
                None
            }
            Ok(_) => {
                self.finish(io, Err(Error { code: "io", message: "Expected transcript read".into() }));
                None
            }
        }
    }

    /// Read what was appended, with the bytes before it (`anchor`): a file written again in place
    /// that grew has other bytes there and is read as a new one.
    fn append(self, io: &mut dyn Io, entry: Entry, metadata: Metadata) {
        let offset = entry.complete.saturating_sub(entry.anchor.len() as u64);
        let length = metadata.size - offset;
        let job = Job::Read { path: self.path.clone(), offset, length };
        self.submit(io, job, move |read, io, result| {
            let Some((read, bytes)) = read.checked(io, result, metadata, length) else { return };
            if !bytes.starts_with(&entry.anchor) {
                return read.fresh(io, metadata);
            }
            let kept = entry.anchor.len();
            let Some(end) = bytes[kept..].iter().rposition(|byte| *byte == b'\n') else {
                // Only an unfinished line: the row is as it was.
                let listing = entry.found.listing();
                read.store(Entry { size: metadata.size, modified_ns: metadata.modified_ns, ..entry });
                return read.finish(io, Ok(listing));
            };
            let mut classify = (read.classify)(&read.session);
            let mut newer = Found::default();
            newer.scan(&bytes[kept..kept + end], &mut classify);
            let found = entry.found.clone().under(newer);
            let listing = found.listing();
            read.store(Entry {
                size: metadata.size,
                modified_ns: metadata.modified_ns,
                complete: entry.complete + end as u64 + 1,
                anchor: anchor(&bytes[..kept + end + 1]),
                found,
                ..entry
            });
            read.finish(io, Ok(listing));
        });
    }

    fn back(self, io: &mut dyn Io, search: Search) {
        let read_so_far = search.metadata.size - search.start;
        let length = read_so_far.max(TAIL).min(CAP - read_so_far.min(CAP)).min(search.start);
        let offset = search.start - length;
        let job = Job::Read { path: self.path.clone(), offset, length };
        self.submit(io, job, move |read, io, result| {
            // Its bytes end where the last read began.
            let Some((read, bytes)) = read.checked(io, result, search.metadata, length) else { return };
            let mut search = search;
            let mut region = bytes;
            region.extend_from_slice(&std::mem::take(&mut search.head));
            if search.complete.is_none() {
                match region.iter().rposition(|byte| *byte == b'\n') {
                    Some(end) => {
                        search.complete = Some(offset + end as u64 + 1);
                        region.truncate(end + 1);
                        search.anchor = anchor(&region);
                    }
                    None => {
                        // No line ends in what was read yet: it all belongs to one line.
                        search.head = region;
                        search.start = offset;
                        return read.further(io, search);
                    }
                }
            }
            let lines = if offset > 0 {
                // The first line began before this read: kept for the next.
                let first = region.iter().position(|byte| *byte == b'\n').map_or(region.len(), |at| at + 1);
                let lines = region.split_off(first);
                search.head = region;
                lines
            } else {
                region
            };
            search.start = offset;
            search.found.scan(&lines, &mut search.classify);
            read.further(io, search);
        });
    }

    /// Read back more, or keep what was found.
    fn further(self, io: &mut dyn Io, search: Search) {
        let read_so_far = search.metadata.size - search.start;
        let answered = search.found.answer.is_some();
        let done = search.start == 0
            || read_so_far >= CAP
            || answered && (!self.titled || search.found.title.is_some() || read_so_far >= TITLED);
        if !done {
            return self.back(io, search);
        }
        let metadata = search.metadata;
        let listing = search.found.listing();
        self.store(Entry {
            session: self.session.clone(),
            device: metadata.device,
            inode: metadata.inode,
            size: metadata.size,
            modified_ns: metadata.modified_ns,
            // A file without a newline in what was read: the next read starts at its end.
            complete: search.complete.unwrap_or(if search.start == 0 { 0 } else { metadata.size }),
            anchor: search.anchor,
            found: search.found,
            used: 0,
        });
        self.finish(io, Ok(listing));
    }

    fn store(&self, mut entry: Entry) {
        let mut tails = self.tails.borrow_mut();
        tails.clock += 1;
        entry.used = tails.clock;
        tails.entries.insert(self.path.clone(), entry);
        if tails.entries.len() > ENTRIES
            && let Some(oldest) = tails.entries.iter().min_by_key(|(_, entry)| entry.used).map(|(path, _)| path.clone())
        {
            tails.entries.remove(&oldest);
        }
    }

    /// Answer the calls this read served; calls that came during it get one more read.
    fn finish(self, io: &mut dyn Io, result: Result<Overview, Error>) {
        let waiting = self.tails.borrow_mut().reading.remove(&self.path);
        let Some((now, later)) = waiting else { return };
        for done in now {
            deferred(done)(io, result.clone());
        }
        if !later.is_empty() {
            self.tails.borrow_mut().reading.insert(self.path.clone(), (later, Vec::new()));
            Read { attempts: 0, ..self }.stat(io);
        }
    }
}

#[cfg(test)]
#[path = "tail.test.rs"]
mod tests;
