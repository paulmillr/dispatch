use super::*;
use rpc::{Grown, Line, Reverse};
#[path = "cursor.rs"]
mod cursor;

#[derive(Clone)]
pub(super) struct Saved {
    path: PathBuf,
    grown: Grown,
    generation: String,
    offset: u64,
    turn: Option<String>,
    model: Option<String>,
    effort: Option<String>,
}
enum Stage {
    Header,
    OldTail,
    Tail,
    Page,
    Context,
    Append,
}
struct Read {
    session: String,
    version: Option<String>,
    path: PathBuf,
    before: Option<u64>,
    old: Option<Saved>,
    incremental: bool,
    pending: Option<u64>,
    append: Option<rpc::Lines>,
    offset: u64,
    projection: records::Projection,
    rows: Vec<Record>,
    metadata: Option<Metadata>,
    prefix: Vec<u8>,
    tail: Vec<u8>,
    lower: u64,
    start: u64,
    stage: Stage,
    reverse: Option<Reverse>,
    lines: Vec<Line>,
    bytes: u64,
    turn: Option<String>,
    done: Callback<Archive>,
}
impl Read {
    fn project(&mut self, bytes: &[u8]) {
        if let Ok(doc) = Json::parse(bytes) {
            if let Some((id, _)) = records::context(doc.root()) {
                self.turn = Some(id.to_owned());
            }
            self.rows.extend(
                self.projection.saved(
                    doc.root(),
                    &digest(bytes),
                    doc.root()
                        .get("timestamp")
                        .and_then(Value::string)
                        .and_then(dispatch_helper_core::date::parse),
                    &digest,
                    &printable,
                ),
            );
        }
    }
}

impl Nano {
    pub(super) fn lookup(
        &mut self,
        io: &mut dyn Io,
        binding: Binding,
        id: String,
        cursor: Option<String>,
        mut found: Option<Record>,
        done: Callback<Record>,
    ) {
        self.page(
            io,
            binding.clone(),
            cursor,
            Box::new(move |this, io, result| {
                let page = match result {
                    Ok(page) => page,
                    Err(error) => {
                        done(this, io, Err(error));
                        return;
                    }
                };
                for mut row in page.records.into_iter().rev().filter(|row| row.id == id) {
                    if found.as_ref().is_some_and(|newer| newer.turn != row.turn) {
                        continue;
                    }
                    if !row.text.is_empty() {
                        if let Some(newer) = found {
                            row.output = newer.output;
                            row.blocks = newer.blocks;
                            row.completed = newer.completed;
                            row.exit_code = newer.exit_code;
                        }
                        done(this, io, Ok(row));
                        return;
                    }
                    found.get_or_insert(row);
                }
                if let Some(cursor) = page.earlier {
                    this.lookup(io, binding, id, Some(cursor), found, done);
                } else {
                    done(
                        this,
                        io,
                        found.ok_or_else(|| error("not_found", "Tool output is unavailable.")),
                    );
                }
            }),
        );
    }

    pub(super) fn page(
        &mut self,
        io: &mut dyn Io,
        binding: Binding,
        cursor: Option<String>,
        done: Callback<Page>,
    ) {
        let Some(path) = binding.transcript.clone() else {
            self.journal(io, binding, cursor, done);
            return;
        };
        self.archive(
            io,
            &Transcript {
                later: None,
                path,
                session: binding.session,
                earlier: cursor,
            },
            Box::new(move |this, io, result| done(this, io, result.map(|archive| archive.page))),
        );
    }

    pub(super) fn archive(
        &mut self,
        io: &mut dyn Io,
        source: &Transcript,
        done: Callback<Archive>,
    ) {
        let cursor = &source.earlier;
        let before = cursor.as_ref().and_then(|v| v.parse().ok());
        let old = if source.later.is_some() {
            match Saved::resume(source) {
                Ok(old) => old,
                Err(failure) => {
                    done(self, io, Err(failure));
                    return;
                }
            }
        } else {
            self.saved.get(&source.session).cloned()
        };
        if cursor.is_some() && (before.is_none() || old.is_none()) {
            done(
                self,
                io,
                Err(error("changed", "Transcript changed. Reopen Chat.")),
            );
            return;
        }
        let turn = source
            .later
            .as_ref()
            .and_then(|_| old.as_ref().and_then(|old| old.turn.clone()));
        let mut projection = records::Projection::default();
        projection.session = Some(source.session.clone());
        projection.begin(turn.as_deref());
        if source.later.is_some() {
            projection.model = old.as_ref().and_then(|old| old.model.clone());
            projection.effort = old.as_ref().and_then(|old| old.effort.clone());
        }
        self.load(
            io,
            Read {
                session: source.session.clone(),
                version: None,
                path: source.path.clone(),
                before,
                incremental: source.later.is_some() && old.is_some(),
                old,
                pending: None,
                append: None,
                offset: 0,
                projection,
                rows: vec![],
                metadata: None,
                prefix: vec![],
                tail: vec![],
                lower: 0,
                start: 0,
                stage: Stage::Header,
                reverse: None,
                lines: vec![],
                bytes: 0,
                turn,
                done,
            },
        );
    }

    fn load(&mut self, io: &mut dyn Io, mut read: Read) {
        let job = match read.stage {
            Stage::Header => Some(Job::Read {
                path: read.path.clone(),
                offset: 0,
                length: 65_536,
            }),
            Stage::OldTail => Some(read.old.as_ref().unwrap().grown.tail_job(&read.path)),
            Stage::Tail => {
                let size = read.metadata.unwrap().size;
                Some(Job::Read {
                    path: read.path.clone(),
                    offset: size.saturating_sub(256),
                    length: size.min(256),
                })
            }
            Stage::Append => {
                let offset = read.append.as_ref().unwrap().position();
                let size = read.metadata.unwrap().size;
                (offset < size).then(|| Job::Read {
                    path: read.path.clone(),
                    offset,
                    length: (size - offset).min(65_536),
                })
            }
            Stage::Page | Stage::Context => read.reverse.as_ref().unwrap().job(),
        };
        let Some(job) = job else {
            self.present(io, read);
            return;
        };
        self.job(
            io,
            job,
            Box::new(move |this, io, output| {
                let output = match output {
                    Ok(output) => output,
                    Err(e) => {
                        if matches!(read.stage, Stage::Header)
                            && (e.code == "not_found"
                                || e.message == "ENOENT"
                                || e.message.ends_with("(os error 2)"))
                        {
                            this.awaiting(io, read);
                            return;
                        }
                        (read.done)(this, io, Err(e));
                        return;
                    }
                };
                let result: Result<(), Error> = (|| {
                    let Output::Read {
                        before,
                        after,
                        bytes,
                    } = &output
                    else {
                        return Err(error("io", "Cannot read the agent transcript."));
                    };
                    if before != after || read.metadata.is_some_and(|v| v != *before) {
                        return Err(error("changed", "Transcript changed. Try again."));
                    }
                    if matches!(read.stage, Stage::Header) && bytes.is_empty() {
                        read.metadata = Some(*after);
                        return Ok(());
                    }
                    match read.stage {
                        Stage::Header => {
                            let end = bytes.iter().position(|b| *b == b'\n').ok_or_else(|| {
                                error("history", "Waiting for transcript metadata.")
                            })?;
                            let doc = Json::parse(&bytes[..end])?;
                            if string(doc.root(), "type") != "session_meta"
                                || string(doc.root(), "payload.id") != read.session
                            {
                                return Err(error(
                                    "history",
                                    "Transcript belongs to a different session.",
                                ));
                            }
                            read.version = value(doc.root(), "payload.cli_version")
                                .and_then(Value::string)
                                .map(str::to_owned);
                            if let Some(old) = &read.old {
                                if old.path != read.path
                                    || !old.grown.same_file(after, bytes)
                                    || read
                                        .before
                                        .is_some_and(|before| before > old.grown.metadata.size)
                                {
                                    if read.before.is_some() {
                                        return Err(error(
                                            "changed",
                                            "Transcript changed. Reopen Chat.",
                                        ));
                                    }
                                    read.old = None;
                                    read.incremental = false;
                                }
                            }
                            read.prefix = bytes.iter().take(256).copied().collect();
                            read.lower = end as u64 + 1;
                            read.metadata = Some(*after);
                            read.stage = if read.old.is_some() {
                                Stage::OldTail
                            } else {
                                Stage::Tail
                            };
                        }
                        Stage::OldTail => {
                            if !read.old.as_ref().unwrap().grown.check(after, &output) {
                                if read.before.is_some() {
                                    return Err(error(
                                        "changed",
                                        "Transcript changed. Reopen Chat.",
                                    ));
                                }
                                read.old = None;
                                read.incremental = false;
                            }
                            read.stage = Stage::Tail;
                        }
                        Stage::Tail => {
                            read.tail = bytes.clone();
                            if read.incremental {
                                read.offset = read.old.as_ref().unwrap().offset;
                                let mut lines = rpc::Lines::recover(4_194_304);
                                lines.seek(read.offset);
                                read.append = Some(lines);
                                read.stage = Stage::Append;
                            } else {
                                read.reverse = Some(Reverse::new(
                                    read.path.clone(),
                                    read.lower,
                                    read.before.unwrap_or(after.size),
                                    4_194_304,
                                ));
                                read.stage = Stage::Page;
                            }
                        }
                        Stage::Append => {
                            let mut lines = read.append.take().unwrap();
                            let position = lines.position();
                            if bytes.is_empty() || bytes.len() as u64 > after.size - position {
                                return Err(error("io", "Incomplete transcript read"));
                            }
                            lines
                                .feed(bytes, |line| {
                                    read.project(line);
                                    Ok(())
                                })
                                .map_err(|_| {
                                    error("history", "Cannot frame the agent transcript")
                                })?;
                            if let Some(end) = bytes.iter().rposition(|byte| *byte == b'\n') {
                                read.offset = position + end as u64 + 1;
                            }
                            read.pending = (read.offset < after.size).then_some(read.offset);
                            read.append = Some(lines);
                        }
                        Stage::Page => {
                            let limit = if read.before.is_some() {
                                (200, 2 * 1024 * 1024)
                            } else {
                                (400, 4 * 1024 * 1024)
                            };
                            for line in read.reverse.as_mut().unwrap().feed(output)? {
                                if read.lines.len() >= limit.0 || read.bytes >= limit.1 {
                                    break;
                                }
                                read.bytes += line.end - line.start;
                                if !line.complete {
                                    read.pending = Some(line.start);
                                }
                                read.lines.push(line);
                            }
                            if read.lines.len() >= limit.0
                                || read.bytes >= limit.1
                                || read.reverse.as_ref().unwrap().job().is_none()
                            {
                                read.lines.reverse();
                                if read.lines.len() >= 40 {
                                    let boundary = read.lines.iter().take(40).position(|line| {
                                        Json::parse(&line.bytes).ok().is_some_and(|d| {
                                            records::context(d.root())
                                                .is_some_and(|(_, start)| start)
                                        })
                                    });
                                    if let Some(boundary) = boundary {
                                        read.lines.drain(..boundary);
                                    }
                                }
                                read.start =
                                    read.lines.first().map_or(read.lower, |line| line.start);
                                let context = read.lines.iter().find_map(|line| {
                                    Json::parse(&line.bytes).ok().and_then(|d| {
                                        records::context(d.root())
                                            .map(|(id, start)| (id.to_owned(), start))
                                    })
                                });
                                if let Some((turn, false)) = context {
                                    read.turn = Some(turn);
                                    read.reverse = None;
                                } else if read.lines.first().is_some_and(|line| {
                                    Json::parse(&line.bytes).ok().is_some_and(|d| {
                                        records::context(d.root()).is_some_and(|(_, start)| start)
                                    })
                                }) {
                                    read.reverse = None;
                                } else {
                                    read.reverse = Some(Reverse::new(
                                        read.path.clone(),
                                        read.lower,
                                        read.start,
                                        4_194_304,
                                    ));
                                    read.stage = Stage::Context;
                                }
                            }
                        }
                        Stage::Context => {
                            for line in read.reverse.as_mut().unwrap().feed(output)? {
                                if let Ok(doc) = Json::parse(&line.bytes)
                                    && let Some((turn, _)) = records::context(doc.root())
                                {
                                    read.turn = Some(turn.to_owned());
                                    read.reverse = None;
                                    break;
                                }
                            }
                        }
                    }
                    Ok(())
                })();
                match result {
                    Err(e) => (read.done)(this, io, Err(e)),
                    Ok(()) if matches!(read.stage, Stage::Header) => this.awaiting(io, read),
                    Ok(())
                        if read.reverse.is_none()
                            && matches!(read.stage, Stage::Page | Stage::Context) =>
                    {
                        this.present(io, read)
                    }
                    Ok(()) => this.load(io, read),
                }
            }),
        );
    }

    fn awaiting(&mut self, io: &mut dyn Io, read: Read) {
        (read.done)(
            self,
            io,
            Ok(Archive {
                page: Page::default(),
                snapshot: Snapshot {
                    generation: String::new(),
                    session: Some(read.session),
                    version: None,
                    initial: true,
                    caught_up: false,
                    invalidated: false,
                    awaiting_creation: true,
                    file: read.metadata.map(|metadata| FileIdentity {
                        device: metadata.device,
                        inode: metadata.inode,
                    }),
                    later: String::new(),
                },
                state: State::default(),
            }),
        );
    }

    fn present(&mut self, io: &mut dyn Io, mut read: Read) {
        read.projection.begin(read.turn.as_deref());
        let lines = std::mem::take(&mut read.lines);
        for line in lines.into_iter().filter(|line| line.complete) {
            read.project(&line.bytes[..line.bytes.len().saturating_sub(1)]);
        }
        let initial = !read.incremental && read.before.is_none();
        let generation = if let Some(old) = &read.old {
            old.generation.clone()
        } else {
            let mut bytes = [0; 16];
            if let Err(failure) = io.random(&mut bytes) {
                (read.done)(self, io, Err(error("io", failure.to_string())));
                return;
            }
            let hex = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
            format!(
                "{}-{}-{}-{}-{}",
                &hex[..8],
                &hex[8..12],
                &hex[12..16],
                &hex[16..20],
                &hex[20..]
            )
        };
        let metadata = read.metadata.unwrap();
        let saved = Saved {
            path: read.path,
            generation: generation.clone(),
            offset: read.pending.unwrap_or(metadata.size),
            turn: read.turn.clone(),
            model: read.projection.model.clone(),
            effort: read.projection.effort.clone(),
            grown: Grown {
                metadata,
                prefix: read.prefix,
                tail: read.tail,
            },
        };
        let later = match saved.cursor(&read.session) {
            Ok(cursor) => cursor,
            Err(failure) => {
                (read.done)(self, io, Err(failure));
                return;
            }
        };
        self.saved.insert(read.session.clone(), saved);
        (read.done)(
            self,
            io,
            Ok(Archive {
                page: Page {
                    records: read.rows,
                    earlier: (!read.incremental && read.start > read.lower)
                        .then(|| read.start.to_string()),
                },
                snapshot: Snapshot {
                    later,
                    session: Some(read.session),
                    version: read.version,
                    generation,
                    initial,
                    caught_up: true,
                    invalidated: false,
                    awaiting_creation: false,
                    file: Some(FileIdentity {
                        device: metadata.device,
                        inode: metadata.inode,
                    }),
                },
                state: State {
                    model: read.projection.model,
                    effort: read.projection.effort,
                    ..State::default()
                },
            }),
        );
    }
}
