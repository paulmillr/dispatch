//! Reverse parent-link paging, retaining one page and one bounded native line.
use crate::{
    bridge::{self, Shared},
    digest,
    records::{self, LIMIT, Reader, text},
};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json, Value},
    rpc::Reverse,
};
use std::{cell::RefCell, rc::Rc};

#[derive(Clone)]
struct Saved {
    metadata: Metadata,
    header: String,
    leaf: Option<String>,
    generation: String,
    earlier: Option<String>,
    state: State,
    turn: String,
}

struct Read {
    page: Page,
    state: State,
    metadata: Metadata,
    header: String,
    leaf: Option<String>,
    incremental: bool,
    turn: String,
    version: Option<String>,
}

struct Scan {
    session: String,
    leaf: Option<String>,
    expected: Option<String>,
    metadata: Metadata,
    header: Vec<u8>,
    reverse: Reverse,
    rows: Vec<Vec<u8>>,
    retained: usize,
    cursor: Option<(u64, Option<String>)>,
    turn: Option<String>,
    discover: bool,
    previous: Option<Saved>,
    incremental: bool,
    state: State,
    activity: bool,
    archive: bool,
    done: Option<Done<Read>>,
}

pub fn read(
    runtime: &Shared,
    io: &mut dyn Io,
    binding: &Binding,
    earlier: Option<&str>,
    done: Done<Page>,
) {
    let earlier = earlier.map(str::to_owned);
    let binding = binding.clone();
    let saved = runtime.clone();
    bridge::registration(
        runtime,
        io,
        &binding.process.clone(),
        Box::new(move |io, registration| {
            let record = match registration {
                Ok(v) if v.session == binding.session => v,
                Ok(_) => {
                    done(
                        io,
                        Err(bridge::fail("changed", "The Pi conversation changed.")),
                    );
                    return;
                }
                Err(error) => {
                    done(io, Err(error));
                    return;
                }
            };
            let Some(path) = record.path else {
                done(
                    io,
                    Err(bridge::fail(
                        "not_found",
                        "This Pi session has no saved transcript. Start Pi with session storage to use Chat.",
                    )),
                );
                return;
            };
            let leaf = saved
                .borrow()
                .states
                .get(&binding.session)
                .and_then(|document| {
                    let value = document
                        .root()
                        .get("state")
                        .or_else(|| document.root().get("value"))?;
                    if text(value, "sessionId") != binding.session
                        || value.get("transcriptPath").and_then(Value::string) != path.to_str()
                    {
                        return None;
                    }
                    value
                        .get("leafId")
                        .map(|leaf| leaf.string().map(str::to_owned))
                })
                .unwrap_or(record.leaf);
            let observed = saved.clone();
            file(
                &observed,
                io,
                Transcript {
                    later: None,
                    path,
                    session: binding.session.clone(),
                    earlier: earlier.clone(),
                },
                Some(leaf),
                None,
                Box::new(move |io, result| {
                    let key = (
                        binding.process.pid,
                        binding.process.start,
                        binding.session.clone(),
                    );
                    let page = match result {
                        Ok(read) => {
                            saved.borrow_mut().persisted.insert(key);
                            Ok(read.page)
                        }
                        Err(error)
                            if error.code == "not_found"
                                && earlier.is_none()
                                && !saved.borrow().persisted.contains(&key) =>
                        {
                            Ok(Page::default())
                        }
                        Err(error) => Err(error),
                    };
                    done(io, page);
                }),
            );
        }),
    );
}

pub fn archive(runtime: &Shared, io: &mut dyn Io, source: &Transcript, done: Done<Archive>) {
    let key = (source.path.clone(), source.session.clone());
    let previous = match source
        .later
        .as_deref()
        .filter(|cursor| !cursor.is_empty())
        .map(|cursor| {
            let document = Json::parse(cursor.as_bytes())?;
            let value = document.root();
            let optional = |name| value.get(name).and_then(Value::string).map(str::to_owned);
            let key = digest(format!("{:?}", (&source.path, &source.session)).as_bytes());
            let decoded = (|| {
                Some(Saved {
                    metadata: Metadata {
                        kind: FileKind::File,
                        size: value.get("size")?.unsigned()?,
                        device: value.get("device")?.unsigned()?,
                        inode: value.get("inode")?.unsigned()?,
                        modified_ns: value.get("modified")?.string()?.parse().ok()?,
                        changed_ns: value.get("changed")?.string()?.parse().ok()?,
                    },
                    header: value.get("header")?.string()?.into(),
                    leaf: optional("leaf"),
                    generation: value.get("generation")?.string()?.into(),
                    earlier: optional("earlier"),
                    state: State {
                        model: optional("model"),
                        effort: optional("effort"),
                        busy: value.get("busy")?.boolean()?,
                        ..State::default()
                    },
                    turn: value.get("turn")?.string()?.into(),
                })
            })();
            decoded
                .filter(|_| text(value, "key") == key)
                .ok_or_else(|| bridge::fail("history", "Invalid Pi transcript cursor."))
        })
        .transpose()
    {
        Ok(previous) => previous,
        Err(error) => {
            done(io, Err(error));
            return;
        }
    };
    let earlier = source.earlier.is_some();
    file(
        runtime,
        io,
        source.clone(),
        None,
        previous.clone().filter(|_| !earlier),
        Box::new(move |io, result| {
            let read = match result {
                Ok(read) => read,
                Err(error) if error.code == "not_found" && previous.is_none() && !earlier => {
                    done(
                        io,
                        Ok(Archive {
                            page: Page::default(),
                            state: State::default(),
                            snapshot: Snapshot {
                                later: String::new(),
                                session: None,
                                version: None,
                                generation: String::new(),
                                initial: true,
                                caught_up: false,
                                invalidated: false,
                                awaiting_creation: true,
                                file: None,
                            },
                        }),
                    );
                    return;
                }
                Err(error) => {
                    done(io, Err(error));
                    return;
                }
            };
            let initial = !earlier && !read.incremental;
            let generation = if initial || previous.is_none() {
                let hash = digest(
                    format!(
                        "{:?}{:?}{:?}{}",
                        key,
                        read.metadata,
                        read.leaf,
                        previous
                            .as_ref()
                            .map_or("", |saved| saved.generation.as_str())
                    )
                    .as_bytes(),
                );
                format!(
                    "{}-{}-{}-{}-{}",
                    &hash[..8],
                    &hash[8..12],
                    &hash[12..16],
                    &hash[16..20],
                    &hash[20..32]
                )
            } else {
                previous.as_ref().unwrap().generation.clone()
            };
            let mut page = read.page;
            if read.incremental {
                page.earlier = previous.as_ref().and_then(|saved| saved.earlier.clone());
            }
            let saved = Saved {
                metadata: read.metadata,
                header: read.header,
                leaf: read.leaf,
                generation: generation.clone(),
                earlier: page.earlier.clone(),
                state: read.state.clone(),
                turn: read.turn,
            };
            let later = {
                let key = digest(format!("{:?}", (&key.0, &key.1)).as_bytes());
                let modified = saved.metadata.modified_ns.to_string();
                let changed = saved.metadata.changed_ns.to_string();
                let mut fields = vec![
                    ("key", Data::String(&key)),
                    ("size", Data::Unsigned(saved.metadata.size)),
                    ("device", Data::Unsigned(saved.metadata.device)),
                    ("inode", Data::Unsigned(saved.metadata.inode)),
                    ("modified", Data::String(&modified)),
                    ("changed", Data::String(&changed)),
                    ("header", Data::String(&saved.header)),
                    ("generation", Data::String(&saved.generation)),
                    ("turn", Data::String(&saved.turn)),
                    ("busy", Data::Bool(saved.state.busy)),
                ];
                for (name, value) in [
                    ("leaf", saved.leaf.as_deref()),
                    ("earlier", saved.earlier.as_deref()),
                    ("model", saved.state.model.as_deref()),
                    ("effort", saved.state.effort.as_deref()),
                ] {
                    fields.push((name, value.map(Data::String).unwrap_or(Data::Null)));
                }
                String::from_utf8(json::write(&Data::Object(fields)).expect("Pi cursor encoding"))
                    .expect("JSON is UTF-8")
            };
            done(
                io,
                Ok(Archive {
                    page,
                    state: read.state,
                    snapshot: Snapshot {
                        later,
                        session: Some(key.1.clone()),
                        version: read.version,
                        generation,
                        initial,
                        caught_up: true,
                        invalidated: false,
                        awaiting_creation: false,
                        file: Some(FileIdentity {
                            device: read.metadata.device,
                            inode: read.metadata.inode,
                        }),
                    },
                }),
            );
        }),
    );
}

fn file(
    runtime: &Shared,
    io: &mut dyn Io,
    source: Transcript,
    leaf: Option<Option<String>>,
    previous: Option<Saved>,
    done: Done<Read>,
) {
    let next = runtime.clone();
    bridge::job(
        runtime,
        io,
        Job::Stat {
            path: source.path.clone(),
            follow: true,
        },
        Box::new(move |io, result| {
            let metadata = match result {
                Ok(Output::Metadata(metadata))
                    if metadata.kind == FileKind::File && metadata.size > 0 =>
                {
                    metadata
                }
                Ok(Output::Metadata(metadata)) if metadata.kind == FileKind::File => {
                    done(
                        io,
                        Err(bridge::fail("not_found", "Waiting for a Pi transcript.")),
                    );
                    return;
                }
                Ok(_) => {
                    done(
                        io,
                        Err(bridge::fail("history", "Cannot read the Pi transcript.")),
                    );
                    return;
                }
                Err(error) => {
                    done(io, Err(error));
                    return;
                }
            };
            let after = next.clone();
            bridge::job(
                &next,
                io,
                Job::Read {
                    path: source.path.clone(),
                    offset: 0,
                    length: metadata.size.min(65536),
                },
                Box::new(move |io, result| {
                    let bytes = match result {
                        Ok(Output::Read {
                            bytes,
                            before,
                            after,
                        }) if same(metadata, before, after) => bytes,
                        Ok(_) => {
                            done(
                                io,
                                Err(bridge::fail("changed", "The Pi transcript changed.")),
                            );
                            return;
                        }
                        Err(error) => {
                            done(io, Err(error));
                            return;
                        }
                    };
                    let Some(end) = bytes.iter().position(|byte| *byte == b'\n') else {
                        done(
                            io,
                            Err(bridge::fail(
                                "history",
                                "Waiting for a compatible Pi session transcript.",
                            )),
                        );
                        return;
                    };
                    let header = bytes[..=end].to_vec();
                    let mut reader = Reader::new(&source.session);
                    reader.feed(&header);
                    if !reader.compatible {
                        done(
                            io,
                            Err(bridge::fail(
                                "history",
                                "Waiting for a compatible Pi session transcript.",
                            )),
                        );
                        return;
                    }
                    let hash = digest(&header);
                    let previous = previous.filter(|saved| {
                        saved.metadata.device == metadata.device
                            && saved.metadata.inode == metadata.inode
                            && saved.metadata.size <= metadata.size
                            && (saved.metadata.size != metadata.size || saved.metadata == metadata)
                            && saved.header == hash
                    });
                    let mut position = metadata.size;
                    let mut discover = leaf.is_none();
                    let archive = discover;
                    let mut leaf = leaf;
                    let mut expected = leaf.clone().flatten();
                    if let Some(cursor) = &source.earlier {
                        let cursor = match Json::parse(cursor.as_bytes()) {
                            Ok(cursor) => cursor,
                            Err(error) => {
                                done(io, Err(error));
                                return;
                            }
                        };
                        let value = cursor.root();
                        let selected = value.get("leaf").and_then(Value::string).map(str::to_owned);
                        if text(value, "session") != source.session
                            || value.get("device").and_then(Value::unsigned)
                                != Some(metadata.device)
                            || value.get("inode").and_then(Value::unsigned) != Some(metadata.inode)
                            || leaf.as_ref().is_some_and(|leaf| *leaf != selected)
                            || text(value, "header") != hash
                        {
                            done(
                                io,
                                Err(bridge::fail(
                                    "changed",
                                    "The selected Pi branch changed. Reopen Chat.",
                                )),
                            );
                            return;
                        }
                        leaf = Some(selected);
                        discover = false;
                        expected = value
                            .get("parent")
                            .and_then(Value::string)
                            .map(str::to_owned);
                        position = value.get("before").and_then(Value::unsigned).unwrap_or(0);
                        if position > metadata.size {
                            done(
                                io,
                                Err(bridge::fail("changed", "The Pi transcript changed.")),
                            );
                            return;
                        }
                    }
                    let scan = Rc::new(RefCell::new(Scan {
                        reverse: Reverse::new(source.path, (end + 1) as u64, position, LIMIT),
                        session: source.session,
                        leaf: leaf.flatten(),
                        expected,
                        metadata,
                        header,
                        rows: Vec::new(),
                        retained: 0,
                        cursor: None,
                        turn: None,
                        discover,
                        previous,
                        incremental: false,
                        state: State::default(),
                        activity: false,
                        archive,
                        done: Some(done),
                    }));
                    block(&after, io, scan);
                }),
            );
        }),
    );
}
fn same(original: Metadata, before: Metadata, after: Metadata) -> bool {
    original.device == before.device
        && original.inode == before.inode
        && before.device == after.device
        && before.inode == after.inode
        && before.size >= original.size
        && after.size >= original.size
        && before.modified_ns == after.modified_ns
        && before.changed_ns == after.changed_ns
}
fn block(runtime: &Shared, io: &mut dyn Io, scan: Rc<RefCell<Scan>>) {
    let job = scan.borrow().reverse.job();
    if job.is_none() || scan.borrow().finished() {
        finish(io, scan, None);
        return;
    }
    let next = runtime.clone();
    bridge::job(
        runtime,
        io,
        job.unwrap(),
        Box::new(move |io, result| {
            let lines = match result.and_then(|output| {
                if matches!(&output, Output::Read { before, after, .. }
                    if !same(scan.borrow().metadata, *before, *after))
                {
                    return Err(bridge::fail("changed", "The Pi transcript changed."));
                }
                scan.borrow_mut().reverse.feed(output)
            }) {
                Ok(lines) => lines,
                Err(error) => {
                    finish(io, scan, Some(error));
                    return;
                }
            };
            {
                let mut state = scan.borrow_mut();
                for line in lines.into_iter().filter(|line| line.complete) {
                    state.line(line.start, line.bytes);
                    if state.finished() {
                        break;
                    }
                }
            }
            block(&next, io, scan);
        }),
    );
}
impl Scan {
    fn finished(&self) -> bool {
        !self.archive && !self.discover && (self.expected.is_none() || self.turn.is_some())
    }
    fn line(&mut self, offset: u64, bytes: Vec<u8>) {
        let Ok(document) = Json::parse(&bytes) else {
            return;
        };
        let root = document.root();
        if self.archive && text(root, "type") == "session" {
            // A later header terminates the original transcript. Reverse scanning
            // discards its suffix and continues toward the first saved header.
            self.rows.clear();
            self.retained = 0;
            self.cursor = None;
            self.turn = None;
            self.leaf = None;
            self.expected = None;
            self.discover = true;
            self.previous = None;
            self.incremental = false;
            self.state = State::default();
            self.activity = false;
            return;
        }
        let Some((id, parent)) = records::entry(root) else {
            return;
        };
        if self.discover {
            self.leaf = Some(id.into());
            self.expected = self.leaf.clone();
            self.discover = false;
        }
        if self.expected.as_deref() != Some(id) {
            return;
        }
        if let Some(saved) = &self.previous
            && saved.leaf.as_deref() == Some(id)
            && self.cursor.is_none()
        {
            self.incremental = true;
            self.expected = None;
            self.turn = Some(saved.turn.clone());
            self.state.model = self
                .state
                .model
                .take()
                .or_else(|| saved.state.model.clone());
            self.state.effort = self
                .state
                .effort
                .take()
                .or_else(|| saved.state.effort.clone());
            if !self.activity {
                self.state.busy = saved.state.busy;
            }
            return;
        }
        self.expected = parent.map(str::to_owned);
        let kind = text(root, "type");
        let message = root.get("message");
        if self.state.effort.is_none() && kind == "thinking_level_change" {
            self.state.effort = root
                .get("thinkingLevel")
                .and_then(Value::string)
                .map(str::to_owned);
        }
        if self.state.model.is_none() {
            let configuration = if kind == "model_change" {
                Some((text(root, "provider"), text(root, "modelId")))
            } else {
                message
                    .filter(|value| text(*value, "role") == "assistant")
                    .map(|value| (text(value, "provider"), text(value, "model")))
            };
            if let Some((provider, model)) = configuration
                && !model.is_empty()
            {
                self.state.model = Some(if provider.is_empty() {
                    model
                } else {
                    format!("{provider}/{model}")
                });
            }
        }
        if let Some(message) = message
            && !self.activity
        {
            self.activity = true;
            self.state.busy = text(message, "role") != "assistant"
                || !["stop", "length", "error", "aborted"]
                    .contains(&text(message, "stopReason").as_str());
        }
        if self.cursor.is_some() {
            if self.turn.is_none()
                && root
                    .get("message")
                    .is_some_and(|value| text(value, "role") == "user")
            {
                self.turn = Some(id.into());
            }
        } else {
            self.retained += bytes.len();
            self.rows.push(bytes);
            if self.previous.is_none()
                && (self.rows.len() >= 200 || self.retained >= 2 * 1024 * 1024)
            {
                self.cursor = Some((offset, self.expected.clone()));
            }
        }
    }
}
fn finish(io: &mut dyn Io, scan: Rc<RefCell<Scan>>, error: Option<Error>) {
    let mut scan = scan.borrow_mut();
    let Some(done) = scan.done.take() else {
        return;
    };
    if let Some(error) = error {
        done(io, Err(error));
        return;
    }
    if scan.expected.is_some() && scan.turn.is_none() {
        done(
            io,
            Err(bridge::fail(
                "history",
                "Cannot read the selected Pi conversation branch. Open the terminal for the full conversation.",
            )),
        );
        return;
    }
    let mut reader = Reader::new(&scan.session);
    reader.feed(&scan.header);
    reader.begin(scan.turn.as_deref());
    let records: Vec<Record> = scan
        .rows
        .iter()
        .rev()
        .flat_map(|row| {
            let document = Json::parse(row).expect("selected native entry was parsed");
            reader.parse(document.root())
        })
        .collect();
    let earlier = scan
        .cursor
        .as_ref()
        .filter(|(_, parent)| parent.is_some())
        .map(|(before, parent)| {
            let hash = digest(&scan.header);
            String::from_utf8(
                json::write(&Data::Object(vec![
                    ("session", Data::String(&scan.session)),
                    (
                        "leaf",
                        scan.leaf.as_deref().map(Data::String).unwrap_or(Data::Null),
                    ),
                    (
                        "parent",
                        parent.as_deref().map(Data::String).unwrap_or(Data::Null),
                    ),
                    ("before", Data::Unsigned(*before)),
                    ("device", Data::Unsigned(scan.metadata.device)),
                    ("inode", Data::Unsigned(scan.metadata.inode)),
                    ("header", Data::String(&hash)),
                ]))
                .expect("cursor encoding"),
            )
            .expect("JSON is UTF-8")
        });
    if scan
        .previous
        .as_ref()
        .is_some_and(|saved| saved.leaf.is_none())
    {
        scan.incremental = true;
    }
    let turn = records
        .iter()
        .rev()
        .find_map(|row: &Record| row.turn.clone())
        .unwrap_or_else(|| scan.turn.clone().unwrap_or_else(|| "history".into()));
    scan.state.effort = scan.state.effort.take().or_else(|| Some("off".into()));
    scan.state.leaf = scan.leaf.clone();
    done(
        io,
        Ok(Read {
            page: Page { records, earlier },
            state: scan.state.clone(),
            metadata: scan.metadata,
            header: digest(&scan.header),
            leaf: scan.leaf.clone(),
            incremental: scan.incremental,
            turn,
            version: Json::parse(&scan.header)
                .ok()
                .and_then(|header| header.root().get("version").and_then(Value::unsigned))
                .map(|version| version.to_string()),
        }),
    );
}

pub fn tool(runtime: &Shared, io: &mut dyn Io, binding: &Binding, id: &str, done: Done<Record>) {
    details(
        runtime,
        io,
        binding.clone(),
        id.to_owned(),
        None,
        None,
        done,
    );
}
fn details(
    runtime: &Shared,
    io: &mut dyn Io,
    binding: Binding,
    id: String,
    earlier: Option<String>,
    found: Option<Record>,
    done: Done<Record>,
) {
    let saved = runtime.clone();
    read(
        runtime,
        io,
        &binding.clone(),
        earlier.as_deref(),
        Box::new(move |io, result| {
            let page = match result {
                Ok(page) => page,
                Err(error) => {
                    done(io, Err(error));
                    return;
                }
            };
            let mut found = found;
            let mut call = false;
            for record in page.records.into_iter().filter(|record| record.id == id) {
                call |= !record.completed;
                if let Some(value) = &mut found {
                    if !record.text.is_empty() {
                        value.text = record.text;
                    }
                    if !record.title.is_empty() {
                        value.title = record.title;
                    }
                    if record.completed && !value.completed {
                        value.output = record.output;
                        value.completed = true;
                        value.exit_code = record.exit_code;
                    }
                } else {
                    found = Some(record);
                }
            }
            if !call && page.earlier.is_some() {
                details(&saved, io, binding, id, page.earlier, found, done);
            } else {
                if let Some(row) = &mut found {
                    crate::presentation::apply(row);
                }
                done(
                    io,
                    found.ok_or_else(|| {
                        bridge::fail(
                            "not_found",
                            "This tool is no longer in the selected Pi branch.",
                        )
                    }),
                );
            }
        }),
    );
}
