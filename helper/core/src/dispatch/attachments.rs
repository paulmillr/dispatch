//! Chat attachments (feature chat.attachments; api/attachment.rs). `attachments.put` stores a
//! private copy of what the app read from the user's file, `attachments.read` reads one back
//! (thumbnails on another device), and chat.send / queue.add name stored copies. A delivered
//! send's images are remembered per conversation (`Index`): Claude's transcript keeps only the
//! image data, so history names the copy from there. History shows attachments (`view`) only to
//! clients of chat.attachments; every other client gets the records as they always were.
use super::{
    queue::{self, Held},
    store::{Answer, Bound, Op},
    *,
};
use crate::{api::attachment, encode::Bytes, hash::Sha256};
use std::{
    collections::{BTreeSet, VecDeque},
    io,
};

/// The index's own section: its jobs replay in their own order.
const SECTION: &str = "attachments.index";
/// Harnesses whose transcripts keep images without their paths: the index names them.
const UNNAMED: &[&str] = &["claude"];
/// Index entries kept per conversation, newest last.
const ENTRIES: usize = 200;
/// The index file's format: entries carry the send's time.
const FORMAT: u64 = 2;
/// How long after a send started its record may be written (the walk pastes, waits and types).
const HORIZON: i64 = 600_000;
/// The largest index file a reader accepts.
const INDEX: u64 = 4 << 20;
/// Bytes a send reads to tell an image (the longest signature is WebP's 12).
const HEAD: u64 = 16;
/// Checked index writes lost to other helpers before the entry stays in memory only.
const ATTEMPTS: u8 = 4;

/// attachments.put's answer (the app's StoredAttachment).
struct Stored {
    path: String,
    name: String,
    image: bool,
    size: u64,
}
impl Encode for Stored {
    fn encode(&self, out: &mut Vec<u8>) {
        let kind = if self.image { "image" } else { "file" };
        crate::encode::object(
            out,
            &[("path", &self.path), ("name", &self.name), ("kind", &kind), ("size", &self.size)],
        );
    }
}

/// attachments.read's answer.
struct Content {
    bytes: Vec<u8>,
    size: u64,
}
impl Encode for Content {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(out, &[("bytes", &Bytes(&self.bytes)), ("size", &self.size)]);
    }
}

fn failed(error: impl std::fmt::Display) -> Error {
    Error { code: "io_failure", message: format!("The attachment could not be stored on the host: {error}") }
}
fn refused(message: impl Into<String>) -> Error {
    Error { code: "invalid_input", message: message.into() }
}
fn unavailable(path: &str) -> Error {
    let name = path.rsplit('/').next().unwrap_or(path);
    refused(format!("The attachment {name} is not available on the host"))
}

/// The attachments root of this account.
fn root(io: &mut dyn Io) -> Result<PathBuf, Error> {
    io.storage().map(|storage| attachment::root(&storage)).map_err(failed)
}

/// A native attachment job's request (system/attachment.rs).
fn native(root: &Path, folder: &str, name: &str, field: (&'static str, Data<'_>)) -> Vec<u8> {
    wire::body::encode_plain(&Data::Object(vec![
        ("root", Data::from(root)),
        ("folder", Data::String(folder)),
        ("name", Data::String(name)),
        field,
    ]))
    .expect("a plain request")
}

/// An `attachment.read` answer: the file's size and its first bytes.
fn content(result: io::Result<Output>) -> io::Result<(u64, Vec<u8>)> {
    let Output::Value(bytes) = result? else { return Err(io::ErrorKind::InvalidData.into()) };
    let value = wire::body::decode_plain(&bytes).map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
    let size = value.get("size").and_then(Data::unsigned);
    let data = value.get("data").and_then(Data::bytes);
    size.zip(data).map(|(size, data)| (size, data.to_vec())).ok_or_else(|| io::ErrorKind::InvalidData.into())
}

/// A chat.send or queue.add that names attachments (an empty list names none). Only a client of
/// chat.attachments may name the field at all.
pub(crate) fn named(method: &str, p: &Data<'_>, enabled: bool) -> Result<bool, Error> {
    if !matches!(method, "chat.send" | "queue.add") || p.get("attachments").is_none() {
        return Ok(false);
    }
    if !enabled {
        return Err(refused("Attachments need the chat.attachments feature"));
    }
    Ok(p.get("attachments").and_then(Data::array).is_some_and(|mut list| list.next().is_some()))
}

type Checked = Box<dyn FnOnce(&mut dyn Io, Result<Vec<Attachment>, Error>)>;

/// Each path as `attachments.put` made it, still there; an image by its first bytes.
fn check(io: &mut dyn Io, root: Rc<PathBuf>, mut paths: VecDeque<String>, mut found: Vec<Attachment>, done: Checked) {
    let Some(path) = paths.pop_front() else {
        return deferred(done)(io, Ok(found));
    };
    let Some((folder, name)) = attachment::stored(&root, &path) else {
        return deferred(done)(io, Err(unavailable(&path)));
    };
    let value = native(&root, folder, name, ("limit", Data::Unsigned(HEAD)));
    let name = name.to_owned();
    match io.submit(Job::Native { name: "attachment.read", value }) {
        Ok(work) => io.then(
            work,
            Box::new(move |io, result| match content(result) {
                Ok((_, head)) => {
                    found.push(Attachment { image: attachment::image(&name, &head), path });
                    check(io, root, paths, found, done);
                }
                Err(_) => done(io, Err(unavailable(&path))),
            }),
        ),
        Err(_) => deferred(done)(io, Err(unavailable(&path))),
    }
}

impl Request<'_> {
    /// attachments.put {name, bytes}: a private copy under a new folder.
    /// Protocol result: StoredAttachment {path, name, kind, size}
    pub(super) fn attachments_put(&mut self, p: &Data<'_>) -> Result<(), Error> {
        params::validate(p, params::Rule::Object(&[("name", params::Rule::Text), ("bytes", params::Rule::Bytes)]), "params")?;
        let raw = text(p, "name")?;
        let bytes = p.get("bytes").and_then(Data::bytes).ok_or_else(|| invalid("bytes"))?;
        if bytes.is_empty() {
            return Err(refused("The attachment is empty"));
        }
        if bytes.len() as u64 > attachment::LIMIT {
            return Err(refused("The attachment is larger than 8 MB"));
        }
        let name = attachment::clean(raw);
        let shown = attachment::shown(raw, &name);
        let image = attachment::image(&name, bytes);
        let root = root(self.io)?;
        self.helper.held.delivered.borrow_mut().root.get_or_insert_with(|| root.clone());
        let mut random = [0; 16];
        self.io.random(&mut random).map_err(failed)?;
        let folder: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        let value = native(&root, &folder, &name, ("data", Data::Bytes(bytes)));
        let size = bytes.len() as u64;
        let path = format!("{}/{folder}/{name}", root.to_str().ok_or_else(|| failed("the path is not UTF-8"))?);
        let done = self.done::<Stored>(None);
        let work = self.io.submit(Job::Native { name: "attachment.put", value }).map_err(failed)?;
        self.io.then(
            work,
            Box::new(move |io, result| {
                let result = match result {
                    Ok(_) => Ok(Stored { path, name: shown, image, size }),
                    Err(error) => Err(failed(error)),
                };
                done(io, result);
            }),
        );
        Ok(())
    }

    /// attachments.read {path}: a stored copy's bytes.
    /// Protocol result: {bytes, size}
    pub(super) fn attachments_read(&mut self, p: &Data<'_>) -> Result<(), Error> {
        params::validate(p, params::Rule::Object(&[("path", params::Rule::Text)]), "params")?;
        let path = text(p, "path")?;
        let root = root(self.io)?;
        let shape = || Error { code: "invalid_request", message: "Not a stored attachment".into() };
        let (folder, name) = attachment::stored(&root, path).ok_or_else(shape)?;
        let value = native(&root, folder, name, ("limit", Data::Unsigned(attachment::LIMIT)));
        let done = self.done::<Content>(None);
        let work = self.io.submit(Job::Native { name: "attachment.read", value }).map_err(failed)?;
        self.io.then(
            work,
            Box::new(move |io, result| {
                let result = match content(result) {
                    Ok((size, bytes)) if bytes.len() as u64 == size => Ok(Content { bytes, size }),
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {
                        Err(Error { code: "not_found", message: "The attachment is gone".into() })
                    }
                    _ => Err(shape()),
                };
                done(io, result);
            }),
        );
        Ok(())
    }

    /// chat.send or queue.add with attachments: checked on the host first, then delivered (or
    /// queued) like the message without them, the attachments with it.
    pub(crate) fn attachments_send(&mut self, method: &str, p: &Data<'_>) -> Result<(), Error> {
        let paths = strings(p, "attachments")?;
        if paths.len() > attachment::COUNT {
            return Err(refused(format!("A message takes at most {} attachments", attachment::COUNT)));
        }
        if flag(p, "command") {
            return Err(refused("A command takes no attachments"));
        }
        let (_, mux, harness, binding) = self.agent(p)?;
        let terminal = number(p, "terminal")?;
        let (_, parent) = self.helper.binding(terminal, None)?;
        if !same(&parent, &binding) {
            return Err(refused("A side conversation takes no attachments"));
        }
        let body = text(p, "text")?.to_owned();
        // The text may be empty: the attachments are the message.
        if body.len() > store::TEXT || body.chars().any(|c| (c as u32) < 32 && c != '\n' && c != '\t') {
            return Err(invalid("text"));
        }
        let mode = mode(p)?;
        let root = Rc::new(root(self.io)?);
        self.helper.held.delivered.borrow_mut().root.get_or_insert_with(|| root.as_ref().clone());
        if let Some(path) = paths.iter().find(|path| attachment::stored(&root, path).is_none()) {
            return Err(unavailable(path));
        }
        let held = self.helper.held.clone();
        let key = harness.borrow().key().to_owned();
        let then: Checked = if method == "chat.send" {
            let build = self.sending(p, true, true)?;
            Box::new(move |io, result| {
                let attachments = match result {
                    Ok(attachments) => attachments,
                    Err(error) => return build(None, None)(io, Err(error)),
                };
                let then = remembering(io, &held, &key, &binding.session, &body, &attachments);
                let goal = Goal::Send { text: body.clone(), mode, command: false, attachments: attachments.clone() };
                let done = build(Some(goal), then);
                let process = binding.process.clone();
                let call = checked(done, move |io, done| {
                    harness.borrow_mut().send_attached(io, &binding, &body, mode, &attachments, done)
                });
                mux.borrow_mut().check(io, local(terminal), &process, call);
            })
        } else if harness.borrow().native_queue() {
            let done = self.queue_done(p, self.done(None))?;
            Box::new(move |io, result| match result {
                Ok(attachments) => {
                    harness.borrow_mut().queue_add_attached(io, &binding, &body, mode, &attachments, done)
                }
                Err(error) => done(io, Err(error)),
            })
        } else {
            let line = self.line(terminal, &harness, &binding);
            let mut random = [0; 8];
            self.io.random(&mut random).map_err(failed)?;
            let id = format!("q-{:016x}", u64::from_le_bytes(random));
            let reply: Done<Queued> = self.done(None);
            Box::new(move |io, result| {
                let attachments = match result {
                    Ok(attachments) => attachments,
                    Err(error) => return reply(io, Err(error)),
                };
                let op = Op::Add { id, text: body, mode, command: false, binding: Bound::of(&binding), attachments };
                let answered: Box<dyn FnOnce(&mut dyn Io, Result<Answer, Error>)> =
                    Box::new(move |io, answer| match answer {
                        Ok(Answer::Added(queued)) => reply(io, Ok(queued)),
                        Ok(_) => reply(io, Err(failed("the item was not added"))),
                        Err(error) => reply(io, Err(error)),
                    });
                queue::change(io, &held, &line, op, Some(answered));
            })
        };
        check(self.io, root, paths.into(), Vec::new(), then);
        Ok(())
    }
}

/// The images each send of this helper delivered, by conversation: the digest of the message's
/// text, the images' paths in order, and when the send started. Kept in memory and in a private
/// file per conversation (`<storage>/attachments/<hash>.idx`), read back when a client of
/// chat.attachments pages a history that needs it. Also this account's attachments root once a
/// client of chat.attachments said hello (history strips path lines under it only).
#[derive(Default)]
pub(crate) struct Index {
    entries: BTreeMap<String, Vec<Entry>>,
    loaded: BTreeSet<String>,
    pub(crate) root: Option<PathBuf>,
    /// The last send's number (Entry::serial).
    serial: u64,
}

#[derive(Clone, Debug)]
struct Entry {
    digest: [u8; 32],
    paths: Vec<String>,
    /// Unix milliseconds when the send started; None until the clock answered (or when it
    /// could not be read).
    time: Option<i64>,
    /// This helper's send it is, while in memory; 0 for one read from the file.
    serial: u64,
}

impl PartialEq for Entry {
    fn eq(&self, other: &Self) -> bool {
        (self.digest, &self.paths, self.time) == (other.digest, &other.paths, other.time)
    }
}

fn digest(text: &str) -> [u8; 32] {
    let mut hash = Sha256::new();
    hash.update(text.trim().as_bytes());
    hash.finish()
}

/// A conversation's index file: harness and session decide, like the queue store's.
fn path(storage: &Path, harness: &str, session: &str) -> PathBuf {
    let file = store::path(storage, harness, session);
    let name = file.file_stem().and_then(|name| name.to_str()).unwrap_or_default();
    storage.join(attachment::DIRECTORY).join(format!("{name}.idx"))
}

fn merge(into: &mut Vec<Entry>, entries: impl IntoIterator<Item = Entry>) {
    for entry in entries {
        // The same send again (read back from the file); two sends of this helper stay two.
        into.retain(|known| !(*known == entry && (known.serial == entry.serial || known.serial == 0 || entry.serial == 0)));
        into.push(entry);
    }
    let excess = into.len().saturating_sub(ENTRIES);
    into.drain(..excess);
}

fn encode(harness: &str, session: &str, entries: &[Entry]) -> Result<Vec<u8>, Error> {
    let entries = entries
        .iter()
        .map(|entry| {
            Data::Object(vec![
                ("text", Data::Bytes(&entry.digest)),
                ("paths", Data::Array(entry.paths.iter().map(|path| Data::String(path)).collect())),
                ("time", entry.time.map_or(Data::Null, Data::Signed)),
            ])
        })
        .collect();
    wire::body::encode_plain(&Data::Object(vec![
        ("format", Data::Unsigned(FORMAT)),
        ("harness", Data::String(harness)),
        ("session", Data::String(session)),
        ("entries", Data::Array(entries)),
    ]))
}

fn decode(bytes: &[u8], harness: &str, session: &str) -> Option<Vec<Entry>> {
    let value = wire::body::decode_plain(bytes).ok()?;
    let mine = value.get("format").and_then(Data::unsigned) == Some(FORMAT)
        && value.get("harness").and_then(Data::string) == Some(harness)
        && value.get("session").and_then(Data::string) == Some(session);
    if !mine {
        return None;
    }
    value
        .get("entries")?
        .array()?
        .map(|entry| {
            let digest = <[u8; 32]>::try_from(entry.get("text")?.bytes()?).ok()?;
            let paths = entry.get("paths")?.array()?.map(|path| path.string().map(str::to_owned)).collect::<Option<_>>()?;
            let time = entry.get("time").and_then(Data::signed);
            Some(Entry { digest, paths, time, serial: 0 })
        })
        .collect()
}

/// Whether a send's result means the message may have reached the agent: written, or uncertain
/// (some of it typed). A refusal or a failure before anything was typed is not.
fn reached(result: &Result<Sent, Error>) -> bool {
    match result {
        Ok(Sent::Native { written, may_have_sent, .. }) => *written || *may_have_sent,
        Ok(Sent::Keys(_)) => true,
        Err(error) => error.code == "uncertain",
    }
}

/// What wraps a send's reply so its images are remembered; None where nothing is remembered
/// (no image, no session, a harness whose history names its images). Called when the send
/// starts: the entry is in memory at once (a live record names its images from it, without a
/// time until the clock answers), stays once the send may have reached the agent (and goes to
/// the conversation's index file then), and is dropped for a refusal.
pub(crate) fn remembering(
    io: &mut dyn Io,
    held: &Held,
    harness: &str,
    session: &str,
    text: &str,
    attachments: &[Attachment],
) -> Option<Box<dyn FnOnce(Done<Sent>) -> Done<Sent>>> {
    let paths: Vec<String> = attachments.iter().filter(|a| a.image).map(|a| a.path.clone()).collect();
    // Only Claude Code's transcript keeps an image without its path; Codex keeps its local images'
    // paths and the text fallback (Pi, Nanocodex) keeps the path lines.
    if paths.is_empty() || session.is_empty() || !UNNAMED.contains(&harness) {
        return None;
    }
    let serial = {
        let mut index = held.delivered.borrow_mut();
        index.serial += 1;
        let serial = index.serial;
        let entry = Entry { digest: digest(text), paths, time: None, serial };
        merge(index.entries.entry(session.to_owned()).or_default(), [entry]);
        serial
    };
    let delivery = Rc::new(RefCell::new(Delivery {
        held: held.clone(),
        harness: harness.to_owned(),
        session: session.to_owned(),
        serial,
        timed: false,
        reached: None,
    }));
    let clocked = delivery.clone();
    let value = wire::body::encode_plain(&Data::Object(Vec::new())).expect("a plain request");
    let submitted = queue::within(io, SECTION, Job::Native { name: "attachment.clock", value }, Box::new(move |io, result| {
        let time = clock(result);
        clocked.borrow_mut().timed = true;
        let delivery = clocked.borrow();
        if let Some(entry) = delivery.entry(&mut delivery.held.delivered.borrow_mut()) {
            entry.time = time;
        }
        drop(delivery);
        finish(io, &clocked);
    }));
    if submitted.is_err() {
        delivery.borrow_mut().timed = true;
    }
    Some(Box::new(move |done: Done<Sent>| -> Done<Sent> {
        Box::new(move |io, result| {
            delivery.borrow_mut().reached = Some(reached(&result));
            finish(io, &delivery);
            done(io, result)
        })
    }))
}

/// One send's entry until it is kept or dropped (`remembering`).
struct Delivery {
    held: Held,
    harness: String,
    session: String,
    serial: u64,
    /// The clock answered (or could not be asked).
    timed: bool,
    /// The send's outcome: whether it may have reached the agent.
    reached: Option<bool>,
}

impl Delivery {
    fn entry<'a>(&self, index: &'a mut Index) -> Option<&'a mut Entry> {
        index.entries.get_mut(&self.session)?.iter_mut().find(|entry| entry.serial == self.serial)
    }
}

/// Drop a refused send's entry; write a delivered one's once its time is known.
fn finish(io: &mut dyn Io, delivery: &Rc<RefCell<Delivery>>) {
    let delivery = delivery.borrow();
    match (delivery.reached, delivery.timed) {
        (Some(false), _) => {
            if let Some(entries) = delivery.held.delivered.borrow_mut().entries.get_mut(&delivery.session) {
                entries.retain(|entry| entry.serial != delivery.serial);
            }
        }
        (Some(true), true) => {
            let entry = delivery.entry(&mut delivery.held.delivered.borrow_mut()).cloned();
            if let Some(entry) = entry {
                persist(io, &delivery.harness, &delivery.session, entry);
            }
        }
        _ => {}
    }
}

/// A `attachment.clock` answer: Unix milliseconds.
fn clock(result: io::Result<Output>) -> Option<i64> {
    let Ok(Output::Value(bytes)) = result else { return None };
    wire::body::decode_plain(&bytes).ok()?.get("ms").and_then(Data::signed)
}

/// Add a delivered send's entry to the conversation's index file (best effort: a lost write
/// leaves it in this helper's memory only).
fn persist(io: &mut dyn Io, harness: &str, session: &str, entry: Entry) {
    let Ok(storage) = io.storage() else { return };
    let file = path(&storage, harness, session);
    let directory = storage.join(attachment::DIRECTORY);
    let (harness, session) = (harness.to_owned(), session.to_owned());
    let _ = queue::within(io, SECTION, Job::MakeDir { path: directory, mode: 0o700 }, Box::new(move |io, result| {
        if result.is_ok() {
            write(io, file, harness, session, entry, 0);
        }
    }));
}

/// Read, add, write back with a checked write; again on a newer file.
fn write(io: &mut dyn Io, file: PathBuf, harness: String, session: String, entry: Entry, attempt: u8) {
    let value = wire::body::encode_plain(&Data::Object(vec![
        ("path", Data::from(file.as_path())),
        ("limit", Data::Unsigned(INDEX)),
    ]))
    .expect("a plain request");
    let _ = queue::within(io, SECTION, Job::Native { name: "file.private", value }, Box::new(move |io, result| {
        let Ok(current) = queue::private(result) else { return };
        let mut entries = current.as_ref().and_then(|(bytes, _)| decode(bytes, &harness, &session)).unwrap_or_default();
        merge(&mut entries, [entry.clone()]);
        let Ok(bytes) = encode(&harness, &session, &entries) else { return };
        let expected = current.map_or(Expected::Absent, |(_, guard)| Expected::Same(guard));
        let job = Job::Write { path: file.clone(), bytes, mode: 0o600, expected, parent: None };
        let _ = queue::within(io, SECTION, job, Box::new(move |io, result| {
            let lost = result.as_ref().is_err_and(|error| {
                matches!(
                    error.kind(),
                    io::ErrorKind::StaleNetworkFileHandle | io::ErrorKind::AlreadyExists | io::ErrorKind::NotFound
                )
            });
            if lost && attempt + 1 < ATTEMPTS {
                write(io, file, harness, session, entry, attempt + 1);
            }
        }));
    }));
}

/// Read a conversation's index file once, then `then`.
fn load(io: &mut dyn Io, held: &Held, harness: &str, session: &str, then: Box<dyn FnOnce(&mut dyn Io)>) {
    if session.is_empty() || !held.delivered.borrow_mut().loaded.insert(session.to_owned()) {
        return then(io);
    }
    let Ok(storage) = io.storage() else { return then(io) };
    let value = wire::body::encode_plain(&Data::Object(vec![
        ("path", Data::from(path(&storage, harness, session).as_path())),
        ("limit", Data::Unsigned(INDEX)),
    ]))
    .expect("a plain request");
    let (state, harness, session) = (held.clone(), harness.to_owned(), session.to_owned());
    let then = Rc::new(RefCell::new(Some(then)));
    let fallback = then.clone();
    let submitted = queue::within(io, SECTION, Job::Native { name: "file.private", value }, Box::new(move |io, result| {
        let stored = queue::private(result).ok().flatten().and_then(|(bytes, _)| decode(&bytes, &harness, &session));
        if let Some(stored) = stored {
            let mut index = state.delivered.borrow_mut();
            let entries = index.entries.entry(session).or_default();
            let known = std::mem::take(entries);
            merge(entries, stored.into_iter().chain(known));
        }
        if let Some(then) = then.borrow_mut().take() {
            then(io);
        }
    }));
    if submitted.is_err()
        && let Some(then) = fallback.borrow_mut().take()
    {
        then(io);
    }
}

/// Whether a record has an image block without its path.
fn unnamed(records: &[Record]) -> bool {
    records.iter().any(|record| {
        record.kind == RecordKind::User
            && record.blocks.iter().any(|block| matches!(block, Block::File(attachment::Shown { image: true, path: None, .. })))
    })
}

/// The send a record is: sends of a conversation follow one another, so its record was written
/// after it started and before the next one did: the latest send that started before the record
/// (within `HORIZON`). A send whose time is not known yet (the clock has not answered), or a
/// record without a time, takes the newest such entry.
fn closest<'a>(candidates: impl Iterator<Item = (&'a Entry, Vec<&'a String>)>, time: Option<i64>) -> Option<Vec<&'a String>> {
    let candidates: Vec<_> = candidates.collect();
    if let Some(time) = time
        && let Some((_, paths)) = candidates
            .iter()
            .filter(|(entry, _)| entry.time.is_some_and(|start| start <= time && time - start <= HORIZON))
            .max_by_key(|(entry, _)| entry.time)
    {
        return Some(paths.clone());
    }
    candidates.into_iter().rev().find(|(entry, _)| time.is_none() || entry.time.is_none()).map(|(_, paths)| paths)
}

/// Name the images of user records from the index: an entry for the record's text whose paths
/// (less those the record names already) are as many as its unnamed images, the one sent when
/// the record was written (`closest`). Records of the same text (an image alone has none) each
/// get their own send, whichever page they come in.
pub(crate) fn fill(held: &Held, session: &str, records: &mut [Record]) {
    if !unnamed(records) {
        return;
    }
    let index = held.delivered.borrow();
    let Some(entries) = index.entries.get(session) else { return };
    for record in records.iter_mut().filter(|record| record.kind == RecordKind::User) {
        let unnamed = record.blocks.iter().filter(|b| matches!(b, Block::File(attachment::Shown { image: true, path: None, .. }))).count();
        if unnamed == 0 {
            continue;
        }
        let named: Vec<String> = record
            .blocks
            .iter()
            .filter_map(|block| match block {
                Block::File(attachment::Shown { path: Some(path), .. }) => Some(path.clone()),
                _ => None,
            })
            .collect();
        let wanted = digest(&record.text);
        let candidates = entries.iter().filter(|entry| entry.digest == wanted).filter_map(|entry| {
            let left: Vec<&String> = entry.paths.iter().filter(|path| !named.contains(path)).collect();
            (left.len() == unnamed).then_some((entry, left))
        });
        let Some(paths) = closest(candidates, record.time_ms) else { continue };
        let mut paths = paths.into_iter();
        for block in &mut record.blocks {
            if let Block::File(attachment::Shown { image: true, path: path @ None, name }) = block
                && let Some(next) = paths.next()
            {
                *path = Some(next.clone());
                if name.is_none() {
                    *name = next.rsplit('/').next().map(str::to_owned);
                }
            }
        }
    }
}

/// The chat.attachments view of records: a user record's typed text and its attachment blocks
/// (api::attachment::typed, path lines under `root` only), from what its harness noted
/// (`Record::attached`). Whether any record changed.
pub(crate) fn view(root: Option<&Path>, records: &mut [Record]) -> bool {
    let mut changed = false;
    for record in records.iter_mut() {
        if let Some(attached) = record.attached.take() {
            let (text, blocks) = attachment::typed(root, attached.text.as_deref().unwrap_or(&record.text), &attached.images);
            record.text = text;
            record.blocks.extend(blocks);
            changed = true;
        }
    }
    changed
}

/// Whether records hold anything only chat.attachments clients see.
pub(crate) fn attached(records: &[Record]) -> bool {
    records.iter().any(|record| record.attached.is_some())
}

/// Records as a client of chat.attachments gets them in an update: `view`, then the images
/// named from memory (no index file is read for an update).
pub(crate) fn shown(held: &Held, session: &str, records: &mut [Record]) {
    let root = held.delivered.borrow().root.clone();
    view(root.as_deref(), records);
    fill(held, session, records);
}

/// Read a conversation's index (once) and the attachments root ahead of reads that use them from
/// memory (a followed archive of a chat.attachments client).
pub(crate) fn warm(io: &mut dyn Io, held: &Held, harness: &str, session: &str) {
    cache(io, held);
    load(io, held, harness, session, Box::new(|_| {}));
}

/// This account's attachments root, read once (only for a client of chat.attachments: other
/// clients cause no storage lookup).
pub(crate) fn cache(io: &mut dyn Io, held: &Held) -> Option<PathBuf> {
    if let Some(root) = held.delivered.borrow().root.clone() {
        return Some(root);
    }
    let root = io.storage().ok().map(|storage| attachment::root(&storage))?;
    held.delivered.borrow_mut().root = Some(root.clone());
    Some(root)
}

impl Request<'_> {
    /// History answers of this conversation as this client gets them (`named_page`).
    pub(super) fn named(&self, harness: &Shared<dyn Harness>, binding: &Binding) -> impl FnOnce(Done<Page>) -> Done<Page> + 'static {
        let enabled = features::enabled(&self.helper.features, self.fd, features::ATTACHMENTS);
        let (held, key, session) = (self.helper.held.clone(), harness.borrow().key().to_owned(), binding.session.clone());
        move |done| named_page(&held, enabled, &key, &session, done)
    }
    /// An archive answer as this client gets it: for chat.attachments, `view` and the images
    /// named like a live history's.
    pub(super) fn named_archive(&self, harness: &Shared<dyn Harness>, session: &str) -> impl FnOnce(Done<Archive>) -> Done<Archive> + 'static {
        let enabled = features::enabled(&self.helper.features, self.fd, features::ATTACHMENTS);
        let (held, key, session) = (self.helper.held.clone(), harness.borrow().key().to_owned(), session.to_owned());
        move |done: Done<Archive>| -> Done<Archive> {
            if !enabled {
                return done;
            }
            Box::new(move |io, result| {
                let Ok(mut archive) = result else { return done(io, result) };
                let page = std::mem::take(&mut archive.page);
                let named: Done<Page> = Box::new(move |io, page| {
                    done(io, page.map(|page| Archive { page, ..archive }))
                });
                named_page(&held, true, &key, &session, named)(io, Ok(page));
            })
        }
    }
}

/// A history answer as a client gets it: as the harness made it for a client without
/// chat.attachments; for one with it, `view` and the images named, from memory after reading the
/// conversation's index once (no other client causes the read).
pub(crate) fn named_page(held: &Held, enabled: bool, harness: &str, session: &str, done: Done<Page>) -> Done<Page> {
    let (held, harness, session) = (held.clone(), harness.to_owned(), session.to_owned());
    Box::new(move |io, result| {
        let Ok(mut page) = result else { return done(io, result) };
        if !enabled || !attached(&page.records) {
            return done(io, Ok(page));
        }
        let root = cache(io, &held);
        view(root.as_deref(), &mut page.records);
        if !unnamed(&page.records) {
            return done(io, Ok(page));
        }
        let state = held.clone();
        load(io, &held, &harness, &session.clone(), Box::new(move |io| {
            fill(&state, &session, &mut page.records);
            done(io, Ok(page));
        }));
    })
}

// Tests: dispatch/queue.test.rs (`attachments`), with the queue store's fake disk.
