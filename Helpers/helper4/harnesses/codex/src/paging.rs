//! Bounded page policy over the shared reverse transcript reader.
use crate::{
    history,
    jobs::{Jobs, submit},
    questions,
};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json, Kind},
    rpc::{Line, Reverse},
};
use std::{cell::RefCell, collections::BTreeMap, path::PathBuf, rc::Rc};

pub type Archives = Rc<RefCell<BTreeMap<(PathBuf, String), (Metadata, Snapshot)>>>;

pub(crate) fn extends(before: &Metadata, after: &Metadata) -> bool {
    before.device == after.device && before.inode == after.inode
        && (after.size > before.size || after == before)
}

pub struct Reader {
    jobs: Jobs,
    path: PathBuf,
    reverse: Reverse,
    session: String,
    metadata: Metadata,
    version: Option<String>,
    /// The page being read, newest line first, and its bytes.
    lines: Vec<Line>,
    bytes: u64,
    limit: usize,
    budget: u64,
    lower: u64,
    /// An earlier batch reads up to three pages until 12 visible items or 2 MiB
    /// (c1654cc TranscriptReader.swift:378-399, ChatCoordinator.swift:1009).
    earlier: bool,
    /// The batch's pages, oldest line first.
    batch: Vec<Line>,
    read: u64,
    visible: usize,
    pages: usize,
    maximum: usize,
    /// A backward search after the page: the turn the oldest page begins in
    /// (TranscriptPaging.swift:207-228), or the latest configuration and turn marker before a
    /// recent page that has none (TranscriptReader.latestConfiguration/latestActivity,
    /// ChatCoordinator.swift:917-918,955-1000).
    search: Search,
    /// The page's turn context while the latest search runs, what it still wants
    /// (configuration, activity), and what it found.
    context: Option<String>,
    wanted: Option<(bool, bool)>,
    configuration: Option<Vec<u8>>,
    activity: Option<bool>,
    /// The verified interval with no intervening context (old TranscriptContextRange).
    known: Option<(u64, u64, Option<String>)>,
    cache: Known,
    done: Option<Done<Read>>,
}

/// One context interval per file; unchanged versions or appends may reuse it.
pub type Known = Rc<RefCell<BTreeMap<PathBuf, (Metadata, u64, u64, Option<String>)>>>;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Search {
    None,
    Context,
    Latest,
}

/// One page with its state, file metadata, header version, recovered questions and where a
/// follower continues: the end of its last complete line and the turn context there.
pub type Read = (
    Page,
    State,
    (Metadata, Option<String>),
    questions::Pending,
    (u64, Option<String>),
);

impl Reader {
    pub fn read(
        jobs: Jobs,
        io: &mut dyn Io,
        source: Transcript,
        cache: (Known, usize),
        done: Done<Read>,
    ) {
        let cursor = match source.earlier.as_deref().map(|value| {
            value.rsplit(':').next().unwrap().parse::<u64>()
        }).transpose() {
            Ok(cursor) => cursor,
            Err(_) => {
                deferred(done)(
                    io,
                    Err(crate::channel::failure(
                        "history",
                        "Invalid history cursor.",
                    )),
                );
                return;
            }
        };
        let next = jobs.clone();
        submit(
            &jobs,
            io,
            Job::Read {
                path: source.path.clone(),
                offset: 0,
                length: 65_536,
            },
            Box::new(move |io, result| {
                let result = match result {
                    Ok(Output::Read {
                        before,
                        after,
                        bytes,
                    }) if before.device == after.device && before.inode == after.inode => {
                        // TranscriptReader: an empty rollout is awaiting its header (Codex creates
                        // the file first), not a changed identity.
                        if bytes.is_empty() {
                            Ok(((after, None), 0))
                        } else if let Some((_, version, _)) = history::identity(&bytes)
                            .filter(|(session, ..)| *session == source.session)
                        {
                            Ok((
                                (after, version),
                                bytes.split_inclusive(|byte| *byte == b'\n')
                                    .scan(0, |end, line| {
                                        *end += line.len() as u64;
                                        Some((line, *end))
                                    })
                                    .find_map(|(line, end)| history::identity(line).map(|_| end))
                                    .unwrap(),
                            ))
                        } else {
                            Err(crate::channel::failure(
                                "history",
                                "The Codex rollout identity changed.",
                            ))
                        }
                    }
                    Err(error) => Err(error),
                    _ => Err(crate::channel::failure(
                        "changed",
                        "The Codex rollout changed during reading.",
                    )),
                };
                match result {
                    Ok((metadata, lower)) => {
                        Self::start(next, io, source, metadata, lower, (cursor, cache), done)
                    }
                    Err(error) => deferred(done)(io, Err(error)),
                }
            }),
        );
    }

    fn start(
        jobs: Jobs,
        io: &mut dyn Io,
        source: Transcript,
        (metadata, version): (Metadata, Option<String>),
        lower: u64,
        (cursor, (cache, maximum)): (Option<u64>, (Known, usize)),
        done: Done<Read>,
    ) {
        let end = cursor.unwrap_or(metadata.size).min(metadata.size);
        let known =
            cache
                .borrow_mut()
                .remove(&source.path)
                .and_then(|(before, lower, upper, turn)| {
                    extends(&before, &metadata)
                        .then_some((lower, upper, turn))
                });
        let reader = Rc::new(RefCell::new(Self {
            jobs,
            reverse: Reverse::new(source.path.clone(), lower, end, history::LINE as usize),
            path: source.path,
            session: source.session,
            metadata,
            version,
            lines: Vec::new(),
            bytes: 0,
            limit: if cursor.is_some() { 200 } else { 400 },
            budget: if cursor.is_some() {
                2_097_152
            } else {
                4_194_304
            },
            lower,
            earlier: cursor.is_some(),
            batch: Vec::new(),
            read: 0,
            visible: 0,
            pages: 0,
            maximum,
            search: Search::None,
            context: None,
            wanted: None,
            configuration: None,
            activity: None,
            known,
            cache,
            done: Some(deferred(done)),
        }));
        Self::next(reader, io);
    }

    fn next(reader: Rc<RefCell<Self>>, io: &mut dyn Io) {
        let mut current = reader.borrow_mut();
        let full = current.lines.len() >= current.limit || current.bytes >= current.budget;
        let searching = current.search != Search::None;
        let Some(job) = current.reverse.job().filter(|_| searching || !full) else {
            let context = current.context.take();
            let search = current.search;
            drop(current);
            match search {
                Search::None => Self::paged(reader, io),
                // Nothing found: the page keeps its own context and state.
                Search::Context => {
                    let mut current = reader.borrow_mut();
                    let upper = current
                        .batch
                        .first()
                        .map_or(current.lower, |line| line.start);
                    current.known = Some((current.lower, upper, None));
                    drop(current);
                    Self::conclude(reader, io, None, None)
                }
                Search::Latest => Self::conclude(reader, io, context, None),
            }
            return;
        };
        let next = reader.clone();
        submit(
            &current.jobs,
            io,
            job,
            Box::new(move |io, result| {
                let mut current = next.borrow_mut();
                let snapshot = current.metadata;
                let lines = match result.and_then(|output| match output {
                    // Every block still reads the file the header came from, grown by appends
                    // only; an overwrite does not join a second version (the old TranscriptFile
                    // snapshot, SSHFileConsistencyTests.swift:33-48).
                    Output::Read { before, .. }
                        if before.device != snapshot.device
                            || before.inode != snapshot.inode
                            || before.size < snapshot.size
                            || before.size == snapshot.size && before != snapshot =>
                    {
                        Err(crate::channel::failure(
                            "changed",
                            "Transcript changed during read",
                        ))
                    }
                    output => current.reverse.feed(output),
                }) {
                    Ok(lines) => lines,
                    Err(error) => {
                        if let Some(done) = current.done.take() {
                            done(io, Err(error));
                        }
                        return;
                    }
                };
                for line in lines {
                    if current.search == Search::Context {
                        current.read += line.end - line.start;
                        if let Some((turn, _)) = history::context(&line.bytes) {
                            let upper = current
                                .batch
                                .first()
                                .map_or(current.lower, |line| line.start);
                            current.known = Some((line.end, upper, Some(turn.clone())));
                            drop(current);
                            return Self::conclude(next, io, Some(turn), None);
                        }
                        if let Some((lower, upper, turn)) = current.known.clone()
                            && lower <= line.start
                            && line.start <= upper
                        {
                            let upper = current
                                .batch
                                .first()
                                .map_or(current.lower, |line| line.start);
                            current.known = Some((lower, upper, turn.clone()));
                            drop(current);
                            return Self::conclude(next, io, turn, None);
                        }
                    } else if current.search == Search::Latest {
                        let Some((configuration, activity)) = current.wanted else {
                            continue;
                        };
                        if !line.complete {
                            continue;
                        }
                        if configuration && history::configurable(&line.bytes) {
                            current.configuration = Some(line.bytes.clone());
                        }
                        if activity && current.activity.is_none() {
                            current.activity = history::activity(&line.bytes);
                        }
                        let wanted = (
                            configuration && current.configuration.is_none(),
                            activity && current.activity.is_none(),
                        );
                        current.wanted = Some(wanted);
                        if wanted == (false, false) {
                            let context = current.context.take();
                            drop(current);
                            return Self::conclude(next, io, context, None);
                        }
                    } else if current.lines.len() < current.limit && current.bytes < current.budget
                    {
                        current.bytes += line.end - line.start;
                        current.lines.push(line);
                    }
                }
                drop(current);
                Self::next(next, io);
            }),
        );
    }

    /// One page is read (TranscriptPage.read): prefer a turn boundary near its beginning, then
    /// read another page of the batch or resolve the turn the oldest page begins in.
    fn paged(reader: Rc<RefCell<Self>>, io: &mut dyn Io) {
        let mut current = reader.borrow_mut();
        let mut lines = std::mem::take(&mut current.lines);
        lines.reverse();
        // TranscriptPaging.swift:180-185: the excluded prefix stays behind the cursor.
        if lines.len() >= 40
            && let Some(boundary) = lines[..40]
                .iter()
                .position(|line| history::context(&line.bytes).is_some_and(|(_, starts)| starts))
        {
            lines.drain(..boundary);
        }
        let start = lines.first().map_or(current.lower, |line| line.start);
        current.read += std::mem::take(&mut current.bytes);
        current.pages += 1;
        // TranscriptPaging.swift:186-201: the first explicit context, unless the page starts a
        // turn; otherwise (None) the nearest context before the page, found by a probe.
        let mut contexts = lines.iter().map(|line| history::context(&line.bytes));
        let head = contexts.next().flatten();
        let opens = head.as_ref().is_some_and(|(_, starts)| *starts);
        let context = match head.or_else(|| contexts.flatten().next()) {
            Some((turn, false)) => Some(Some(turn)),
            _ if opens => Some(None),
            _ => None,
        };
        // Visible items decide only whether another page joins the batch; count them only then.
        // The page parsed in its context is also the result while it stays the batch's only page.
        let room = current.earlier
            && start > current.lower
            && current.read < 2_097_152
            && current.pages < current.maximum;
        let parsed = room.then(|| {
            let turn = context.clone().flatten();
            history::page(Self::complete(&lines), &current.session, turn.as_deref())
        });
        current.visible += parsed
            .as_ref()
            .map_or(0, |page| page.as_ref().map_or(0, |page| page.3));
        let single = current.batch.is_empty();
        lines.append(&mut current.batch);
        current.batch = lines;
        if room && current.visible < 12 {
            current.reverse = Reverse::new(
                current.path.clone(),
                current.lower,
                start,
                history::LINE as usize,
            );
            drop(current);
            return Self::next(reader, io);
        }
        match context {
            Some(context) => {
                drop(current);
                Self::conclude(reader, io, context, parsed.filter(|_| single));
            }
            // The context line the previous page found lies before this one: no search again.
            None if let Some((_, _, turn)) = current
                .known
                .clone()
                .filter(|(lower, upper, _)| *lower <= start && start <= *upper) =>
            {
                drop(current);
                Self::conclude(reader, io, turn, None);
            }
            None => {
                current.search = Search::Context;
                current.reverse = Reverse::new(
                    current.path.clone(),
                    current.lower,
                    start,
                    history::LINE as usize,
                );
                drop(current);
                Self::next(reader, io);
            }
        }
    }

    /// Finish the batch, after looking up the latest configuration line and turn marker before
    /// a recent page that holds none (old: the latest such line of the file, which is the page's
    /// own when it has one).
    fn conclude(
        reader: Rc<RefCell<Self>>,
        io: &mut dyn Io,
        context: Option<String>,
        parsed: Option<Result<(Page, State, questions::Pending, usize), Error>>,
    ) {
        let mut current = reader.borrow_mut();
        let has = |test: fn(&[u8]) -> bool| current.batch.iter().any(|line| test(&line.bytes));
        let wanted = (
            !has(history::configurable),
            !has(|bytes| history::activity(bytes).is_some()),
        );
        if current.earlier || current.wanted.is_some() || wanted == (false, false) {
            return current.finish(io, context, parsed);
        }
        let start = current
            .batch
            .first()
            .map_or(current.lower, |line| line.start);
        current.wanted = Some(wanted);
        current.context = context;
        current.search = Search::Latest;
        current.reverse = Reverse::new(
            current.path.clone(),
            current.lower,
            start,
            history::LINE as usize,
        );
        drop(current);
        Self::next(reader, io);
    }

    /// Complete lines without their newline, each with its file offset.
    fn complete(lines: &[Line]) -> impl Iterator<Item = (u64, &[u8])> {
        let complete = lines.iter().filter(|line| line.complete);
        complete.map(|line| (line.start, &line.bytes[..line.bytes.len() - 1]))
    }

    fn finish(
        &mut self,
        io: &mut dyn Io,
        context: Option<String>,
        parsed: Option<Result<(Page, State, questions::Pending, usize), Error>>,
    ) {
        let Some(done) = self.done.take() else {
            return;
        };
        let offset = self.batch.first().map_or(self.lower, |line| line.start);
        let complete = self.batch.iter().filter(|line| line.complete);
        let end = complete.last().map_or(offset, |line| line.end);
        let turn = self
            .batch
            .iter()
            .rev()
            .find_map(|line| history::context(&line.bytes));
        let turn = turn.map(|(turn, _)| turn).or(context.clone());
        let parsed = parsed.unwrap_or_else(|| {
            history::page(
                Self::complete(&self.batch),
                &self.session,
                context.as_deref(),
            )
        });
        let configuration = self.configuration.take();
        let result = parsed.map(|(mut page, mut state, questions, _)| {
            if let Some(document) = configuration.and_then(|line| Json::parse(&line).ok()) {
                history::configure(document.root(), &self.session, &mut state);
            }
            state.busy = self.activity.unwrap_or(state.busy);
            if let Some((lower, upper, turn)) = self.known.clone() {
                self.cache
                    .borrow_mut()
                    .insert(self.path.clone(), (self.metadata, lower, upper, turn));
            }
            page.earlier = (offset > self.lower).then(|| offset.to_string());
            let header = (self.metadata, self.version.take());
            (page, state, header, questions, (end, turn))
        });
        done(io, result);
    }
}

/// The recent page (or the earlier page `source.earlier`) of an archived transcript; `reset` treats
/// the file as new (a watch found it replaced or shortened).
pub fn archive(archives: &Archives, source: &Transcript, value: Read, reset: bool) -> Archive {
    let (mut page, state, (metadata, version), _, (end, turn)) = value;
    let mut archives = archives.borrow_mut();
    let key = (source.path.clone(), source.session.clone());
    let previous = archives.get(&key);
    let reset = reset
        || previous.is_none_or(|(before, _)| !extends(before, &metadata));
    let generation = if reset {
        let hash =
            history::key(format!("{:?}:{}:{metadata:?}", source.path, source.session).as_bytes());
        format!(
            "{}-{}-{}-{}-{}",
            &hash[..8],
            &hash[8..12],
            &hash[12..16],
            &hash[16..20],
            &hash[20..32]
        )
    } else {
        previous.unwrap().1.generation.clone()
    };
    let cursor = Cursor {
        session: source.session.clone(),
        generation: generation.clone(),
        version: version.clone(),
        file: (metadata.device, metadata.inode),
        offset: end,
        turn,
        state: state.clone(),
    };
    let invalidated = source.earlier.as_deref().is_some_and(|value| {
        reset || value.split_once(':').is_none_or(|(expected, _)| expected != generation)
    });
    page.earlier = page.earlier.map(|offset| format!("{generation}:{offset}"));
    let snapshot = Snapshot {
        later: cursor.write(),
        session: Some(source.session.clone()),
        version,
        generation,
        // Core's archive watch: every recent read starts the chat over.
        initial: source.earlier.is_none(),
        caught_up: true,
        invalidated,
        awaiting_creation: metadata.size == 0,
        file: Some(FileIdentity {
            device: metadata.device,
            inode: metadata.inode,
        }),
    };
    // TranscriptReader.readEarlier: a page request of a replaced file carries no records and
    // leaves the reader as it was, so the next recent read starts the new file (initial).
    let page = if snapshot.invalidated {
        Page::default()
    } else {
        archives.insert(key, (metadata, snapshot.clone()));
        page
    };
    Archive {
        page,
        state,
        snapshot,
    }
}

/// Where a watched archive continues (Snapshot.later, opaque to core): the file, the end of its
/// last complete line, the turn there and the conversation state up to it.
struct Cursor {
    session: String,
    generation: String,
    version: Option<String>,
    file: (u64, u64),
    offset: u64,
    turn: Option<String>,
    state: State,
}

impl Cursor {
    fn write(&self) -> String {
        fn text(value: &Option<String>) -> Data<'_> {
            value.as_deref().map_or(Data::Null, Data::String)
        }
        let state = &self.state;
        let fields = vec![
            ("session", Data::String(&self.session)),
            ("generation", Data::String(&self.generation)),
            ("version", text(&self.version)),
            ("device", Data::Unsigned(self.file.0)),
            ("inode", Data::Unsigned(self.file.1)),
            ("offset", Data::Unsigned(self.offset)),
            ("turn", text(&self.turn)),
            ("busy", Data::Bool(state.busy)),
            ("model", text(&state.model)),
            ("effort", text(&state.effort)),
            ("usage", text(&state.usage)),
            ("goal", text(&state.goal)),
        ];
        String::from_utf8(json::write(&Data::Object(fields)).unwrap_or_default())
            .unwrap_or_default()
    }

    fn read(text: &str) -> Option<Self> {
        let document = Json::parse(text.as_bytes()).ok()?;
        let root = document.root();
        let number = |name| root.get(name)?.unsigned();
        let text = |name| match root.get(name)? {
            value if value.kind() == Kind::Null => Some(None),
            value => Some(Some(value.string()?.to_owned())),
        };
        Some(Self {
            session: text("session")??,
            generation: text("generation")??,
            version: text("version")?,
            file: (number("device")?, number("inode")?),
            offset: number("offset")?,
            turn: text("turn")?,
            state: State {
                busy: root.get("busy")?.boolean()?,
                model: text("model")?,
                effort: text("effort")?,
                usage: text("usage")?,
                goal: text("goal")?,
                ..State::default()
            },
        })
    }
}

/// A watched archive read from its cursor (core "Archive watch"): only the complete records
/// appended since, the rest held until complete. A replaced or shortened file is read again from
/// the start as new; a missing or empty one is awaited.
pub fn later(
    jobs: Jobs,
    io: &mut dyn Io,
    archives: Archives,
    source: Transcript,
    cursor: &str,
    done: Done<Archive>,
) {
    let Some(cursor) = Cursor::read(cursor) else {
        let error = crate::channel::failure("history", "Invalid history cursor.");
        return deferred(done)(io, Err(error));
    };
    if cursor.session != source.session {
        let error = crate::channel::failure("history", "The Codex rollout identity changed.");
        return deferred(done)(io, Err(error));
    }
    appended(
        jobs,
        io,
        archives,
        source,
        cursor,
        crate::follow::CHUNK,
        done,
    );
}

/// One read of the archive from `cursor`, `length` long; a read that one unfinished line fills is
/// read again twice as long, up to history::LINE (the line arrives whole, the cursor moves).
fn appended(
    jobs: Jobs,
    io: &mut dyn Io,
    archives: Archives,
    source: Transcript,
    mut cursor: Cursor,
    length: u64,
    done: Done<Archive>,
) {
    let job = Job::Read {
        path: source.path.clone(),
        offset: cursor.offset,
        length,
    };
    let next = jobs.clone();
    submit(
        &jobs,
        io,
        job,
        Box::new(move |io, result| {
            // Nothing to read yet: the next read of a created file starts it as new.
            let awaited = |mut cursor: Cursor| {
                (cursor.file, cursor.offset) = ((0, 0), 0);
                let snapshot = Snapshot {
                    later: cursor.write(),
                    session: Some(cursor.session),
                    version: cursor.version,
                    generation: cursor.generation,
                    initial: false,
                    caught_up: true,
                    invalidated: false,
                    awaiting_creation: true,
                    file: None,
                };
                Archive {
                    page: Page::default(),
                    state: cursor.state,
                    snapshot,
                }
            };
            let (before, after, bytes) = match result {
                Ok(Output::Read {
                    before,
                    after,
                    bytes,
                }) => (before, after, bytes),
                Err(error) if error.code == "not_found" => return done(io, Ok(awaited(cursor))),
                Err(error) => return done(io, Err(error)),
                _ => {
                    let error = crate::channel::failure("history", "Invalid history read.");
                    return done(io, Err(error));
                }
            };
            if after.size == 0 {
                return done(io, Ok(awaited(cursor)));
            }
            let same = |metadata: &Metadata| (metadata.device, metadata.inode) == cursor.file;
            let changed = archives.borrow().get(&(source.path.clone(), source.session.clone()))
                .is_some_and(|(metadata, _)| !extends(metadata, &before));
            if changed || !same(&before) || !same(&after) || before.size < cursor.offset {
                let saved = source.clone();
                let fresh = Transcript {
                    later: None,
                    ..source
                };
                return Reader::read(
                    next,
                    io,
                    fresh,
                    (Known::default(), 3),
                    Box::new(move |io, result| {
                        let archive = |value| archive(&archives, &saved, value, true);
                        done(io, result.map(archive));
                    }),
                );
            }
            let mut state = cursor.state.clone();
            let turn = cursor.turn.clone();
            let appended =
                history::appended(&bytes, cursor.offset, &source.session, turn, &mut state);
            let (records, consumed, turn, _) = match appended {
                Ok(value) => value,
                Err(error) => return done(io, Err(error)),
            };
            if consumed == 0 && bytes.len() as u64 == length {
                let longer = (length * 2).min(history::LINE);
                return self::appended(next, io, archives, source, cursor, longer, done);
            }
            let caught_up = cursor.offset + (bytes.len() as u64) >= before.size;
            cursor.offset += consumed;
            cursor.turn = turn;
            cursor.state = state.clone();
            let snapshot = Snapshot {
                later: cursor.write(),
                session: Some(cursor.session),
                version: cursor.version,
                generation: cursor.generation,
                initial: false,
                caught_up,
                invalidated: false,
                awaiting_creation: false,
                file: Some(FileIdentity {
                    device: after.device,
                    inode: after.inode,
                }),
            };
            let page = Page {
                records,
                earlier: None,
            };
            archives.borrow_mut().insert((source.path, source.session), (after, snapshot.clone()));
            done(
                io,
                Ok(Archive {
                    page,
                    state,
                    snapshot,
                }),
            );
        }),
    );
}
