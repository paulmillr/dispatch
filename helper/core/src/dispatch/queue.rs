//! One queue API for every harness: a verified native queue, or a queue held by the host and
//! drained when the agent is idle; c1654cc ChatCoordinator.swift:1604-1738, ChatModels.swift:655-662.
//!
//! A held queue lives in the host's queue store (`store.rs`): a private file per conversation
//! that every helper of the account shares, so what the host accepted survives this helper and is
//! sent by whichever helper is bound to the agent when it is idle. A conversation without a
//! session yet (a provisional binding) has no file and is held in this helper's memory only.
use super::{
    store::{self, Answer, Awaiting, Bound, Op, Outcome, Owner, Record},
    *,
};
use std::{collections::VecDeque, io, os::fd::RawFd, time::{Duration, Instant}};

/// Old queueRetryAfter: a send that typed nothing is retried after one second.
const RETRY: Duration = Duration::from_secs(1);
/// How often a queue held by another helper's mark asks whether that helper still runs.
const PROBE: Duration = Duration::from_secs(30);
/// Checked writes lost to other helpers before an operation gives up.
const ATTEMPTS: u8 = 8;
/// The store's own section: its jobs, watch and timers replay in their own order.
pub(crate) const STORE: &str = "queue.store";
/// Marks of a line held only in memory (never shared, never probed), and marks made before this
/// helper knew its identity (replaced when the operation is applied).
const MEMORY: Owner = store::UNSET;

type Then = Box<dyn FnOnce(&mut dyn Io, Result<Answer, Error>)>;

struct Pending {
    op: Op,
    done: Option<Then>,
    attempts: u8,
}

/// Where a line's record is kept: its file, or memory for a provisional session.
#[derive(Clone, PartialEq)]
struct Target {
    harness: String,
    mux: String,
    terminal: String,
    path: Option<PathBuf>,
}

/// One chat's held queue, as this helper last read it. `waiting` holds the next send until the
/// agent acknowledges the previous one (busy state or new records), like the old
/// awaitingPromptAck.
#[derive(Default)]
pub(crate) struct Line {
    record: Option<Record>,
    target: Option<Target>,
    binding: Option<Binding>,
    pending: VecDeque<Pending>,
    running: bool,
    pub(super) sending: bool,
    checking: bool,
    waiting: bool,
    /// Permission withdrawn here: nothing is sent from this helper even before the store says so.
    revoked: bool,
    retry: bool,
    dirty: bool,
    /// The awaited send the agent acknowledged (busy or records) as this helper saw it then.
    acknowledged: Option<Awaiting>,
    probed: Option<Instant>,
    /// Items a client of this helper is editing, by client.
    edits: BTreeMap<String, RawFd>,
    /// The client of this helper holding the queue.
    holder: Option<RawFd>,
}

impl Line {
    pub(crate) fn snapshot(&self) -> Vec<Queued> {
        self.record.as_ref().map(Record::snapshot).unwrap_or_default()
    }
    fn stored(&self) -> bool {
        self.target.as_ref().is_some_and(|target| target.path.is_some())
    }
}

#[derive(Default)]
enum Ready {
    #[default]
    Idle,
    Preparing(Vec<Box<dyn FnOnce(&mut dyn Io, Result<(), Error>)>>),
    Done,
}

/// This helper's held queues by (terminal, session), and its access to the store.
#[derive(Default)]
pub(crate) struct Queues {
    lines: BTreeMap<(Id, String), Line>,
    ready: Ready,
    owner: Option<Owner>,
    directory: Option<PathBuf>,
    watch: Option<u64>,
    /// `Io::storage`, asked once.
    storage: Option<PathBuf>,
}

impl Queues {
    pub(crate) fn get(&self, key: &(Id, String)) -> Option<&Line> {
        self.lines.get(key)
    }
}

/// Held queues and the update stream their snapshots go to.
#[derive(Clone)]
pub(crate) struct Held {
    queues: Rc<RefCell<Queues>>,
    updates: Rc<RefCell<VecDeque<Update>>>,
}

impl Held {
    pub(crate) fn new(updates: Rc<RefCell<VecDeque<Update>>>) -> Self {
        Self { queues: Default::default(), updates }
    }
    pub(crate) fn borrow(&self) -> std::cell::Ref<'_, Queues> {
        self.queues.borrow()
    }
    fn publish(&self, key: &(Id, String)) {
        let queues = self.queues.borrow();
        if let Some(line) = queues.lines.get(key)
            && let Some(binding) = &line.binding
        {
            self.updates.borrow_mut().push_back(Update::queue(binding.clone(), Ok(line.snapshot())));
        }
    }
    fn line<T>(&self, key: &(Id, String), call: impl FnOnce(&mut Line) -> T) -> Option<T> {
        self.queues.borrow_mut().lines.get_mut(key).map(call)
    }
}

fn storage(error: impl std::fmt::Display) -> Error {
    Error { code: "storage", message: format!("The queue could not be saved on the host: {error}") }
}

/// Submit `job` in the store's section; its callback runs in the caller's.
fn stored(io: &mut dyn Io, job: Job, then: Box<dyn FnOnce(&mut dyn Io, io::Result<Output>)>) -> io::Result<()> {
    let caller = io.section(STORE);
    let work = io.submit(job);
    if let Ok(work) = work {
        let back = caller.clone();
        io.then(work, Box::new(move |io, result| {
            let inner = io.section(&back);
            then(io, result);
            io.section(&inner);
        }));
    }
    io.section(&caller);
    work.map(|_| ())
}

type Prepared = Box<dyn FnOnce(&mut dyn Io, Result<(), Error>)>;

fn prepared(io: &mut dyn Io, held: &Held, result: Result<(), Error>) {
    let waiting = {
        let mut queues = held.queues.borrow_mut();
        let ready = if result.is_ok() { Ready::Done } else { Ready::Idle };
        match std::mem::replace(&mut queues.ready, ready) {
            Ready::Preparing(waiting) => waiting,
            _ => Vec::new(),
        }
    };
    for then in waiting {
        then(io, result.clone());
    }
}

/// Once per helper: the store directory, this run's owner identity and the directory watch.
fn prepare(io: &mut dyn Io, held: &Held, then: Prepared) {
    {
        let mut queues = held.queues.borrow_mut();
        match &mut queues.ready {
            Ready::Done => {
                drop(queues);
                return then(io, Ok(()));
            }
            Ready::Preparing(waiting) => return waiting.push(then),
            Ready::Idle => queues.ready = Ready::Preparing(vec![then]),
        }
    }
    let directory = match io.storage() {
        Ok(path) => path.join(store::DIRECTORY),
        Err(error) => return prepared(io, held, Err(storage(error))),
    };
    let me = io.pid();
    let state = held.clone();
    let made = stored(io, Job::MakeDir { path: directory.clone(), mode: 0o700 }, Box::new(move |io, result| {
        if let Err(error) = result {
            return prepared(io, &state, Err(storage(error)));
        }
        let later = state.clone();
        let started = stored(io, Job::Process { pid: me }, Box::new(move |io, result| {
            let process = match result {
                Ok(Output::Process(process)) => process,
                Ok(_) => return prepared(io, &later, Err(storage("no process identity"))),
                Err(error) => return prepared(io, &later, Err(storage(error))),
            };
            let mut token = [0; 8];
            if let Err(error) = io.random(&mut token) {
                return prepared(io, &later, Err(storage(error)));
            }
            let caller = io.section(STORE);
            let watch = io.watch(&directory, true);
            io.section(&caller);
            {
                let mut queues = later.queues.borrow_mut();
                queues.owner = Some(Owner { pid: me, start: process.start, token: u64::from_le_bytes(token) });
                queues.watch = watch.ok();
                queues.directory = Some(directory);
            }
            prepared(io, &later, Ok(()));
        }));
        if let Err(error) = started {
            prepared(io, &state, Err(storage(error)));
        }
    }));
    if let Err(error) = made {
        prepared(io, held, Err(storage(error)));
    }
}

/// Queue `op` on a line; operations of one line run one after another.
fn change(io: &mut dyn Io, held: &Held, key: &(Id, String), op: Op, done: Option<Then>) {
    {
        let mut queues = held.queues.borrow_mut();
        let line = queues.lines.entry(key.clone()).or_default();
        line.pending.push_back(Pending { op, done, attempts: 0 });
    }
    pump(io, held, key.clone());
}

fn pump(io: &mut dyn Io, held: &Held, key: (Id, String)) {
    let target = {
        let mut queues = held.queues.borrow_mut();
        let Some(line) = queues.lines.get_mut(&key) else { return };
        if line.running || line.pending.is_empty() {
            return;
        }
        line.running = true;
        line.target.clone()
    };
    let Some(target) = target else {
        let error = Error { code: "unavailable", message: "This conversation has no queue yet".into() };
        return settle(io, held, &key, Err(error), None);
    };
    let Some(path) = target.path.clone() else {
        // A provisional conversation: memory only, as before the store.
        let current = held.queues.borrow().lines.get(&key).and_then(|line| line.record.clone());
        let mut next = current.unwrap_or_else(|| Record::new(&target.harness, "", &target.mux, &target.terminal));
        let answer = apply(held, &key, &mut next);
        let record = answer.is_ok().then(|| (!next.empty()).then_some(next));
        return settle(io, held, &key, answer, record);
    };
    let (state, again) = (held.clone(), key.clone());
    prepare(io, held, Box::new(move |io, result| match result {
        Ok(()) => read(io, &state, again, target, path),
        Err(error) => settle(io, &state, &again, Err(error), None),
    }));
}

/// The running operation's answer on `record`; the record changes only on success.
fn apply(held: &Held, key: &(Id, String), record: &mut Record) -> Result<Answer, Error> {
    let queues = held.queues.borrow();
    let line = &queues.lines[key];
    let me = queues.owner.filter(|_| line.stored()).unwrap_or(MEMORY);
    let op = line.pending.front().expect("a running operation").op.resolved(me);
    let mut next = record.clone();
    let answer = next.apply(&op)?;
    *record = next;
    Ok(answer)
}

fn read(io: &mut dyn Io, held: &Held, key: (Id, String), target: Target, path: PathBuf) {
    let value = wire::body::encode_plain(&Data::Object(vec![
        ("path", Data::from(path.as_path())),
        ("limit", Data::Unsigned(store::LIMIT)),
    ]))
    .expect("a plain request");
    let (state, again) = (held.clone(), key.clone());
    let submitted = stored(io, Job::Native { name: "file.private", value }, Box::new(move |io, result| {
        let current = match opened(result, &target, &again.1) {
            Ok(current) => current,
            Err(error) => return settle(io, &state, &again, Err(error), None),
        };
        let mut next = current
            .as_ref()
            .map(|(record, _)| record.clone())
            .unwrap_or_else(|| Record::new(&target.harness, &again.1, &target.mux, &target.terminal));
        let answer = match apply(&state, &again, &mut next) {
            Ok(answer) => answer,
            // Refused on what is there now: the line still learns the current record.
            Err(error) => return settle(io, &state, &again, Err(error), Some(current.map(|(record, _)| record))),
        };
        let unchanged = match &current {
            Some((record, _)) => *record == next,
            None => next.empty(),
        };
        if unchanged {
            return settle(io, &state, &again, Ok(answer), Some(current.map(|(record, _)| record)));
        }
        let guard = current.as_ref().map(|(_, guard)| *guard);
        let job = match (next.empty(), guard) {
            (true, Some(guard)) => Job::Remove { path: path.clone(), expected: Expected::Same(guard) },
            _ => match next.encode() {
                Ok(bytes) => Job::Write {
                    path: path.clone(),
                    bytes,
                    mode: 0o600,
                    expected: guard.map_or(Expected::Absent, Expected::Same),
                    parent: None,
                },
                Err(error) => return settle(io, &state, &again, Err(error), None),
            },
        };
        let (written, key) = (state.clone(), again.clone());
        let submitted = stored(io, job, Box::new(move |io, result| match result {
            Ok(_) => {
                let record = (!next.empty()).then_some(next);
                settle(io, &written, &key, Ok(answer), Some(record))
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::StaleNetworkFileHandle | io::ErrorKind::AlreadyExists | io::ErrorKind::NotFound
                ) =>
            {
                // Another helper wrote first: apply this operation again to what it wrote.
                let retry = written
                    .line(&key, |line| {
                        let pending = line.pending.front_mut().expect("a running operation");
                        pending.attempts += 1;
                        pending.attempts < ATTEMPTS
                    })
                    .unwrap_or(false);
                if retry {
                    read(io, &written, key, target, path);
                } else {
                    settle(io, &written, &key, Err(storage("other helpers kept changing it")), None);
                }
            }
            Err(error) => settle(io, &written, &key, Err(storage(error)), None),
        }));
        if let Err(error) = submitted {
            settle(io, &state, &again, Err(storage(error)), None);
        }
    }));
    if let Err(error) = submitted {
        settle(io, held, &key, Err(storage(error)), None);
    }
}

/// A read file's record and the guard a checked write needs; None when there is no file.
fn opened(
    result: io::Result<Output>,
    target: &Target,
    session: &str,
) -> Result<Option<(Record, Guard)>, Error> {
    let bytes = match result {
        Ok(Output::Value(bytes)) => bytes,
        Ok(_) => return Err(storage("unexpected answer")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(storage(error)),
    };
    let file = wire::body::decode_plain(&bytes)?;
    let private = || storage("the stored queue is not private");
    let (before, after) = (file.get("before").ok_or_else(private)?, file.get("after").ok_or_else(private)?);
    let data = file.get("data").and_then(Data::bytes).ok_or_else(private)?;
    let uid = crate::system::System::account().map_err(storage)?.0;
    if wire::body::encode_plain(before)? != wire::body::encode_plain(after)?
        || before.get("uid").and_then(Data::unsigned) != Some(uid.into())
        || before.get("mode").and_then(Data::unsigned).is_none_or(|mode| mode & 0o077 != 0)
        || before.get("links").and_then(Data::unsigned) != Some(1)
        || before.get("kind").and_then(Data::string) != Some("file")
        || before.get("size").and_then(Data::unsigned) != Some(data.len() as u64)
    {
        return Err(private());
    }
    let number = |key: &str| -> Result<i128, Error> {
        let value = before.get(key).ok_or_else(private)?;
        value.signed().map(i128::from).or_else(|| value.unsigned().map(i128::from)).ok_or_else(private)
    };
    let guard = Guard {
        kind: Some(FileKind::File),
        size: Some(data.len() as u64),
        device: Some(before.get("device").and_then(Data::unsigned).ok_or_else(private)?),
        inode: Some(before.get("inode").and_then(Data::unsigned).ok_or_else(private)?),
        modified_ns: Some(number("mtime_ns")?),
        changed_ns: Some(number("ctime_ns")?),
    };
    let record = Record::decode(data)?;
    if record.harness != target.harness || record.session != session {
        return Err(storage("the stored queue belongs to another conversation"));
    }
    Ok(Some((record, guard)))
}

/// End the running operation: remember the record it saw (`Some`), publish a changed snapshot,
/// answer, and start the next operation.
fn settle(io: &mut dyn Io, held: &Held, key: &(Id, String), answer: Result<Answer, Error>, record: Option<Option<Record>>) {
    let (done, publish) = {
        let mut queues = held.queues.borrow_mut();
        let Some(line) = queues.lines.get_mut(key) else { return };
        line.running = false;
        let pending = line.pending.pop_front();
        let before = line.snapshot();
        if let Some(record) = record {
            line.record = record;
        }
        line.dirty = true;
        // What a client changed is announced as before the store; anything else when it changed.
        let request = pending.as_ref().is_some_and(|pending| pending.done.is_some() && pending.op != Op::Read);
        let publish = before != line.snapshot() || request && answer.is_ok();
        (pending.and_then(|pending| pending.done), publish)
    };
    if publish {
        held.publish(key);
    }
    if let Some(done) = done {
        done(io, answer);
    }
    pump(io, held, key.clone());
}

/// State and record updates: busy or new records acknowledge a send; idle drains again.
pub(crate) fn observe(held: &Held, terminal: Id, update: &Update) {
    let (binding, busy) = match update {
        Update::State { binding, state } => (binding, Some(state.busy)),
        Update::Records { binding, records } if !records.is_empty() => (binding, None),
        _ => return,
    };
    held.line(&(terminal, binding.session.clone()), |line| {
        if busy != Some(false) {
            line.waiting = false;
            // Only a send already awaited when the agent reacted: a later one waits for its own.
            if let Some(awaiting) = line.record.as_ref().and_then(|record| record.awaiting.clone()) {
                line.acknowledged = Some(awaiting);
            }
        }
        line.dirty = true;
    });
}

/// Own input until completion; only sends await a turn, which can arrive before their callback.
pub(super) fn sending(held: Held, key: (Id, String), awaiting: bool, done: Done<Sent>) -> Done<Sent> {
    {
        let mut queues = held.queues.borrow_mut();
        let line = queues.lines.entry(key.clone()).or_default();
        line.sending = true;
        line.waiting = awaiting;
    }
    Box::new(move |io, result| {
        held.line(&key, |line| {
            line.sending = false;
            line.dirty = true;
            if !matches!(
                &result,
                Ok(Sent::Native { written: true, .. }
                    | Sent::Native {
                        may_have_sent: true,
                        ..
                    })
            ) {
                line.waiting = false;
            }
        });
        done(io, result);
    })
}

fn invalid_text(text: &str, command: bool) -> Option<Error> {
    let fail = |code: &'static str| {
        Some(Error {
            code,
            message: String::new(),
        })
    };
    if command && text.trim_start().starts_with('!') {
        return fail("shell_command");
    }
    if text.trim().is_empty()
        || text.len() > store::TEXT
        || text
            .chars()
            .any(|c| (c as u32) < 32 && c != '\n' && c != '\t')
    {
        return fail("invalid_input");
    }
    None
}

/// The marks this helper writes on a line: its run identity, or MEMORY for a line in memory.
fn owner(held: &Held, key: &(Id, String)) -> Owner {
    let queues = held.queues.borrow();
    match queues.lines.get(key) {
        Some(line) if line.stored() => queues.owner.unwrap_or(MEMORY),
        _ => MEMORY,
    }
}

/// Another helper's claim on this conversation: it is typing a queued item into the terminal.
pub(crate) fn claimed_elsewhere(held: &Held, key: &(Id, String)) -> bool {
    let me = owner(held, key);
    let queues = held.borrow();
    let record = queues.get(key).and_then(|line| line.record.as_ref());
    record.is_some_and(|record| record.items.iter().any(|item| item.claim.is_some_and(|claim| claim != me)))
}

/// What the drain does next on one line.
enum Next {
    Send(String),
    Moved(String),
    Probe(Vec<Owner>),
    Acknowledge(Awaiting),
    Lost,
}

/// Send the first held item of every dirty, idle queue (old drainQueue).
pub(crate) fn drain(helper: &DispatchHelper, io: &mut dyn Io) {
    let held = helper.held.clone();
    let keys: Vec<_> = held
        .queues
        .borrow_mut()
        .lines
        .iter_mut()
        .filter(|(_, line)| {
            line.dirty && !line.running && line.pending.is_empty() && !line.revoked && !line.sending
                && !line.checking && !line.retry
        })
        .map(|(key, line)| {
            line.dirty = false;
            key.clone()
        })
        .collect();
    for key in keys {
        let Ok((index, binding)) = helper.binding(key.0, Some(&key.1)) else {
            continue;
        };
        let Some(module) = helper.nodes.borrow().get(&key.0).map(|(module, _)| *module) else {
            continue;
        };
        let me = owner(&held, &key);
        let next = {
            let mut queues = held.queues.borrow_mut();
            let line = queues.lines.get_mut(&key).unwrap();
            let Some(record) = &line.record else { continue };
            if record.awaiting.is_none() {
                // Nothing to acknowledge: an older acknowledgement must not clear a later send's.
                line.acknowledged = None;
            }
            let mine = |owner: &Owner| me != MEMORY && *owner == me;
            if let Some(seen) = line.acknowledged.clone().filter(|seen| record.awaiting.as_ref() == Some(seen)) {
                Next::Acknowledge(seen)
            } else if line.waiting {
                continue;
            } else if record.items.iter().any(|item| item.claim.as_ref().is_some_and(mine))
                || record.awaiting.as_ref().is_some_and(|awaiting| mine(&awaiting.owner))
            {
                // This helper's claim or awaiting without a send in flight: its result was lost.
                Next::Lost
            } else {
                let Some(first) = record.items.first() else { continue };
                if record.claimed() || first.editing.is_some() || record.awaiting.is_some() || record.hold.is_some() {
                    let foreign = record.foreign(&me);
                    let now = io.now();
                    if foreign.is_empty() || line.probed.is_some_and(|at| now < at + PROBE) {
                        continue;
                    }
                    line.probed = Some(now);
                    Next::Probe(foreign)
                } else if first.pause.is_some() {
                    continue;
                } else if !first.binding.matches(&binding) {
                    Next::Moved(first.id.clone())
                } else {
                    line.checking = true;
                    Next::Send(first.id.clone())
                }
            }
        };
        match next {
            Next::Acknowledge(seen) => {
                held.line(&key, |line| line.acknowledged = None);
                change(io, &held, &key, Op::Acknowledge(seen), None);
            }
            Next::Lost => change(io, &held, &key, Op::Lost(me), None),
            Next::Moved(id) => change(io, &held, &key, Op::Moved { id }, None),
            Next::Probe(owners) => probe(io, &held, &key, owners),
            Next::Send(id) => {
                let (harness, mux) = (helper.harnesses[index].clone(), helper.multiplexers[module].clone());
                let (state, current, owner) = (held.clone(), binding.clone(), harness.clone());
                owner.borrow_mut().state(
                    io,
                    &binding,
                    deferred(Box::new(move |io, result| {
                        let idle = result.is_ok_and(|s| !s.busy && s.attention.is_none() && s.dialog.is_none());
                        let go = state
                            .line(&key, |line| {
                                line.checking = false;
                                let go = idle && !line.revoked && !line.sending && !line.waiting && !line.retry;
                                if go {
                                    line.sending = true;
                                    line.acknowledged = None;
                                }
                                go
                            })
                            .unwrap_or(false);
                        if !go {
                            return;
                        }
                        let claimed = state.clone();
                        let route = key.clone();
                        let claim = Op::Claim { id, owner: me, binding: Bound::of(&current) };
                        change(io, &state, &key, claim, Some(Box::new(move |io, answer| {
                            let Ok(Answer::Claimed(item)) = answer else {
                                // Someone else sends it, or it changed: look again.
                                claimed.line(&route, |line| line.sending = false);
                                return;
                            };
                            send(io, claimed, route, mux, harness, current, item, me);
                        })));
                    })),
                );
            }
        }
    }
}

/// Ask whether the helpers behind these marks still run; release those that are gone.
fn probe(io: &mut dyn Io, held: &Held, key: &(Id, String), owners: Vec<Owner>) {
    let tally: Rc<RefCell<(usize, Vec<Owner>)>> = Rc::new(RefCell::new((owners.len(), Vec::new())));
    let ended = {
        let (held, key, tally) = (held.clone(), key.clone(), tally.clone());
        Rc::new(move |io: &mut dyn Io, owner: Owner, alive: bool| {
            let release = {
                let mut tally = tally.borrow_mut();
                tally.0 -= 1;
                if !alive {
                    tally.1.push(owner);
                }
                (tally.0 == 0).then(|| std::mem::take(&mut tally.1))
            };
            match release {
                Some(owners) if !owners.is_empty() => change(io, &held, &key, Op::Release(owners), None),
                Some(_) => {
                    // All still run: look again after PROBE (or sooner, when the store changes).
                    let (later, key) = (held.clone(), key.clone());
                    let caller = io.section(STORE);
                    let at = io.now() + PROBE;
                    let _ = io.after(at, Box::new(move |_| {
                        later.line(&key, |line| line.dirty = true);
                    }));
                    io.section(&caller);
                }
                None => {}
            }
        })
    };
    for owner in owners {
        let answer = ended.clone();
        let submitted = stored(io, Job::Process { pid: owner.pid }, Box::new(move |io, result| {
            let alive = match result {
                Ok(Output::Process(process)) => process.start == owner.start,
                // Gone, or the pid now belongs to another account: never this account's helper.
                Err(error) if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied) => false,
                // Unknown: keep the mark (never resend on a guess).
                _ => true,
            };
            answer(io, owner, alive);
        }));
        if submitted.is_err() {
            ended(io, owner, true);
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn send(
    io: &mut dyn Io,
    held: Held,
    key: (Id, String),
    mux: Shared<dyn Multiplexer>,
    harness: Shared<dyn Harness>,
    binding: Binding,
    item: store::Item,
    me: Owner,
) {
    let terminal = local(key.0);
    held.line(&key, |line| line.waiting = true);
    let id = item.id.clone();
    let finish: Done<Sent> = Box::new(move |io, result| {
        let outcome = match &result {
            Ok(Sent::Native { written: true, .. }) => Outcome::Written,
            Ok(Sent::Native { may_have_sent: true, .. }) => Outcome::Uncertain,
            Err(error) if error.code == "attention" => Outcome::NeedsEdit,
            _ => Outcome::Retry,
        };
        held.line(&key, |line| {
            if outcome != Outcome::Written {
                line.waiting = false;
            }
            if outcome == Outcome::Retry {
                line.retry = true;
            }
        });
        if outcome == Outcome::Retry {
            let (later, again) = (held.clone(), key.clone());
            let _ = io.after(
                io.now() + RETRY,
                Box::new(move |_| {
                    later.line(&again, |line| {
                        line.retry = false;
                        line.dirty = true;
                    });
                }),
            );
        }
        // The send ends once its result is in the store: until then the claim is this helper's.
        let (ended, route) = (held.clone(), key.clone());
        change(io, &held, &key, Op::Finish { id, owner: me, outcome }, Some(Box::new(move |_, _| {
            ended.line(&route, |line| {
                line.sending = false;
                line.dirty = true;
            });
        })));
    });
    // A drain has no user to ask; a menu that needs a decision pauses the item.
    let ask: Ask = Rc::new(|io, _, done| {
        deferred(done)(
            io,
            Err(Error {
                code: "attention",
                message: String::new(),
            }),
        )
    });
    let goal = Goal::Send {
        text: item.text.clone(),
        mode: item.mode,
        command: item.command,
    };
    let done = walk(
        None,
        mux.clone(),
        harness.clone(),
        terminal,
        binding.clone(),
        goal,
        ask,
        typed(None, mux, harness.clone(), terminal, binding.clone(), finish),
        |_| Sent::Native {
            written: true,
            may_have_sent: true,
            reason: None,
        },
    );
    harness
        .borrow_mut()
        .send(io, &binding, &item.text, item.mode, item.command, done);
}

/// Permission withdrawn for these terminals: their queues stop here at once and in the store.
pub(crate) fn revoke(io: &mut dyn Io, held: &Held, terminals: &std::collections::BTreeSet<Id>) {
    let keys: Vec<_> = held
        .queues
        .borrow_mut()
        .lines
        .iter_mut()
        .filter(|((terminal, _), _)| terminals.contains(terminal))
        .map(|(key, line)| {
            line.revoked = true;
            key.clone()
        })
        .collect();
    for key in keys {
        change(io, held, &key, Op::Revoke, None);
        // Its own marks would hold the queue for the helpers that may still send.
        let me = owner(held, &key);
        if me != MEMORY {
            change(io, held, &key, Op::Lost(me), None);
        }
    }
}

/// The store directory changed: read again the conversations this helper holds.
pub(crate) fn changed(io: &mut dyn Io, held: &Held, event: &Event) -> bool {
    let &Event::Changed { watch, reset } = event else { return false };
    if held.queues.borrow().watch != Some(watch) {
        return false;
    }
    if reset {
        let directory = held.queues.borrow().directory.clone();
        io.unwatch(watch);
        let caller = io.section(STORE);
        let again = directory.and_then(|directory| io.watch(&directory, true).ok());
        io.section(&caller);
        held.queues.borrow_mut().watch = again;
    }
    let keys: Vec<_> = held
        .queues
        .borrow()
        .lines
        .iter()
        // One pending refresh is enough for any number of changes.
        .filter(|(_, line)| line.stored() && !line.pending.iter().any(|pending| pending.op == Op::Read && pending.done.is_none()))
        .map(|(key, _)| key.clone())
        .collect();
    for key in keys {
        change(io, held, &key, Op::Read, None);
    }
    true
}

/// A chat opened on a conversation with a stored queue: read it, and announce it when it holds
/// anything (an empty queue says nothing, as before the store).
pub(crate) fn reopen(io: &mut dyn Io, held: &Held, key: (Id, String)) {
    let (state, route) = (held.clone(), key.clone());
    change(io, held, &key, Op::Read, Some(Box::new(move |_, _| {
        let empty = state.borrow().get(&route).is_none_or(|line| line.snapshot().is_empty());
        if !empty {
            state.publish(&route);
        }
    })));
}

/// Whether this helper holds stored queues that a helper without clients could still send:
/// their agents run in a multiplexer that outlives this helper (not its own native terminals).
pub(crate) fn unsent(held: &Held) -> bool {
    held.queues.borrow().lines.values().any(|line| {
        line.stored()
            && line.target.as_ref().is_some_and(|target| target.mux != "native")
            && line.record.as_ref().is_some_and(Record::sendable)
    })
}

/// A client left: the edits this helper made for it end, here and in the store.
pub(crate) fn left(io: &mut dyn Io, held: &Held, fd: RawFd) {
    let ended: Vec<_> = held
        .queues
        .borrow_mut()
        .lines
        .iter_mut()
        .filter_map(|(key, line)| {
            let ids: Vec<_> = line.edits.iter().filter(|(_, peer)| **peer == fd).map(|(id, _)| id.clone()).collect();
            line.edits.retain(|_, peer| *peer != fd);
            let hold = line.holder == Some(fd);
            if hold {
                line.holder = None;
            }
            (!ids.is_empty() || hold).then(|| (key.clone(), ids, hold))
        })
        .collect();
    for (key, ids, hold) in ended {
        let owner = owner(held, &key);
        change(io, held, &key, Op::Left { owner, ids, hold }, None);
    }
}

impl Request<'_> {
    /// Point a line at its conversation's record (the store for a known session).
    pub(super) fn line(&mut self, terminal: Id, harness: &Shared<dyn Harness>, binding: &Binding) -> (Id, String) {
        let key = (terminal, binding.session.clone());
        let (mux, node) = self
            .helper
            .nodes
            .borrow()
            .get(&terminal)
            .map(|(module, node)| (self.helper.multiplexers[*module].borrow().name().to_owned(), node.key.clone()))
            .unwrap_or_default();
        let harness = harness.borrow().key().to_owned();
        let storage = match binding.session.is_empty() {
            true => None,
            false => {
                let known = self.helper.held.queues.borrow().storage.clone();
                known.or_else(|| {
                    let storage = self.io.storage().ok()?;
                    self.helper.held.queues.borrow_mut().storage = Some(storage.clone());
                    Some(storage)
                })
            }
        };
        let path = storage.map(|storage| store::path(&storage, &harness, &binding.session));
        let mut queues = self.helper.held.queues.borrow_mut();
        let line = queues.lines.entry(key.clone()).or_default();
        line.binding = Some(binding.clone());
        let target = Target { harness, mux, terminal: node, path };
        if line.target.as_ref() != Some(&target) {
            line.target = Some(target);
        }
        key
    }

    /// Protocol result: list Vec<Queued>; add Queued; start Sent; others null
    /// Protocol producers: Harness.queue, Harness.queue_add, Harness.queue_edit, Harness.queue_send, Harness.queue_order
    pub(super) fn queue(&mut self, p: &Data<'_>, op: &str) -> Result<(), Error> {
        let (_, _, harness, binding) = self.agent(p)?;
        if op == "reorder" && strings(p, "items")?.is_empty() {
            return Err(invalid("items"));
        }
        if harness.borrow().native_queue() {
            if matches!(op, "add" | "update") {
                if let Some(body) = p.get("text").and_then(Data::string) {
                    if let Some(error) = invalid_text(body, flag(p, "command")) {
                        return Err(error);
                    }
                }
            }
            return self.native(p, op, harness, binding);
        }
        let terminal = number(p, "terminal")?;
        let key = self.line(terminal, &harness, &binding);
        let me = owner(&self.helper.held, &key);
        let bound = Bound::of(&binding);
        let change_op = match op {
            "list" => Op::Read,
            "add" => {
                let (body, command) = (text(p, "text")?, flag(p, "command"));
                if let Some(error) = invalid_text(body, command) {
                    return Err(error);
                }
                let mut random = [0; 8];
                self.io.random(&mut random).map_err(storage)?;
                Op::Add {
                    id: format!("q-{:016x}", u64::from_le_bytes(random)),
                    text: body.into(),
                    mode: mode(p)?,
                    command,
                    binding: bound,
                }
            }
            "update" => {
                let (id, revision) = (text(p, "item")?, number(p, "revision")?);
                let body = p.get("text").and_then(Data::string);
                let command = p.get("command").and_then(Data::boolean);
                if let Some(body) = body {
                    // An edit is reclassified from the app's current draft;
                    // c1654cc ChatCoordinator.swift:1624,1630.
                    let checked = command.unwrap_or_else(|| cached(&self.helper.held, &key, id, revision).is_some_and(|item| item.command));
                    if let Some(error) = invalid_text(body, checked) {
                        return Err(error);
                    }
                }
                Op::Update { id: id.into(), revision, text: body.map(str::to_owned), command, binding: bound }
            }
            "remove" => Op::Remove { id: text(p, "item")?.into(), revision: number(p, "revision")? },
            "reorder" => Op::Reorder(strings(p, "items")?),
            "restore" => Op::Restore,
            "hold" => {
                let (held, fd) = (flag(p, "held"), self.fd);
                self.helper.held.line(&key, |line| line.holder = held.then_some(fd));
                Op::Hold { held, owner: me }
            }
            "edit" => {
                let (id, editing) = (text(p, "item")?, flag(p, "editing"));
                let fd = self.fd;
                self.helper.held.line(&key, |line| {
                    if editing {
                        line.edits.insert(id.into(), fd);
                    } else {
                        line.edits.remove(id);
                    }
                });
                Op::Edit { id: id.into(), revision: number(p, "revision")?, editing, owner: me }
            }
            "start" => Op::Take { id: text(p, "item")?.into(), revision: number(p, "revision")?, binding: bound },
            _ => return Err(invalid("method")),
        };
        if op == "restore" {
            self.helper.held.line(&key, |line| line.revoked = false);
        }
        if let Op::Take { id, revision, .. } = &change_op {
            // Send now. The revision names the text: what this helper read at that revision is
            // what the take removes, so the checked send is prepared before the store answers.
            let item = cached(&self.helper.held, &key, id, *revision)
                .filter(|item| item.pause.is_none() && item.binding == Bound::of(&binding))
                .ok_or_else(|| invalid("item"))?;
            let mode = mode(p)?;
            let goal = Goal::Send { text: item.text.clone(), mode, command: item.command };
            let done = self.sent(p, Some(goal))?;
            change(self.io, &self.helper.held, &key, change_op, Some(Box::new(move |io, answer| match answer {
                Ok(Answer::Taken(item)) => harness.borrow_mut().send(io, &binding, &item.text, mode, item.command, done),
                Ok(_) => done(io, Err(invalid("item"))),
                Err(error) => done(io, Err(error)),
            })));
            return Ok(());
        }
        let (held, route) = (self.helper.held.clone(), key.clone());
        let reply: Box<dyn FnOnce(&mut dyn Io, Result<Answer, Error>)> = match op {
            "list" => {
                let done: Done<Vec<Queued>> = self.done(None);
                Box::new(move |io, answer| {
                    let items = held.borrow().get(&route).map(Line::snapshot).unwrap_or_default();
                    done(io, answer.map(|_| items))
                })
            }
            "add" => {
                let done: Done<Queued> = self.done(None);
                Box::new(move |io, answer| match answer {
                    Ok(Answer::Added(queued)) => done(io, Ok(queued)),
                    Ok(_) => done(io, Err(storage("the item was not added"))),
                    Err(error) => done(io, Err(error)),
                })
            }
            _ => {
                let done: Done<()> = self.done(None);
                Box::new(move |io, answer| done(io, answer.map(|_| ())))
            }
        };
        change(self.io, &self.helper.held, &key, change_op, Some(reply));
        Ok(())
    }

    /// Old stopQueue: Stop pauses every held item that is not already paused.
    /// Protocol result: Sent
    pub(super) fn stop(&mut self, p: &Data<'_>) -> Result<(), Error> {
        let (_, _, harness, binding) = self.agent(p)?;
        let terminal = number(p, "terminal")?;
        let key = (terminal, binding.session.clone());
        // After every change already asked for: an add still being written is stopped too.
        let held = self.helper.held.borrow().get(&key).is_some_and(|line| line.record.is_some() || line.running || !line.pending.is_empty());
        if held {
            change(self.io, &self.helper.held, &key, Op::Stop, None);
        }
        let done = self.sent(p, Some(Goal::Stop))?;
        harness.borrow_mut().stop(self.io, &binding, done);
        Ok(())
    }

    fn native(
        &mut self,
        p: &Data<'_>,
        op: &str,
        harness: Shared<dyn Harness>,
        binding: Binding,
    ) -> Result<(), Error> {
        if op == "list" {
            return self.snapshot(harness, binding);
        }
        let mut native = harness.borrow_mut();
        let (item, revision) = (
            p.get("item").and_then(Data::string).unwrap_or_default(),
            p.get("revision")
                .and_then(Data::unsigned)
                .unwrap_or_default(),
        );
        match op {
            "add" => {
                let done = self.queue_done(p, self.done(None))?;
                native.queue_add(self.io, &binding, text(p, "text")?, mode(p)?, done)
            }
            "update" | "remove" => {
                let done = self.queue_done(p, self.done(None))?;
                let body = (op == "update").then(|| p.get("text").and_then(Data::string));
                native.queue_edit(self.io, &binding, item, revision, body.flatten(), done)
            }
            "start" => {
                let done = self.queue_done(p, self.sent(p, None)?)?;
                native.queue_send(self.io, &binding, item, revision, mode(p)?, done)
            }
            "reorder" => {
                let done = self.queue_done(p, self.done(None))?;
                native.queue_order(self.io, &binding, &strings(p, "items")?, done)
            }
            _ => {
                return Err(Error {
                    code: "unsupported",
                    message: String::new(),
                });
            }
        }
        Ok(())
    }

    fn snapshot(&mut self, harness: Shared<dyn Harness>, binding: Binding) -> Result<(), Error> {
        let updates = self.helper.updates.clone();
        let done = self.done(None);
        let current = binding.clone();
        harness.borrow_mut().queue(
            self.io,
            &binding,
            deferred(Box::new(move |io, result| {
                updates
                    .borrow_mut()
                    .push_back(Update::queue(current, result.clone()));
                done(io, result);
            })),
        );
        Ok(())
    }

    pub(super) fn queue_done<T: 'static>(
        &self,
        p: &Data<'_>,
        done: Done<T>,
    ) -> Result<Done<T>, Error> {
        let (_, _, harness, binding) = self.agent(p)?;
        let updates = self.helper.updates.clone();
        Ok(deferred(Box::new(move |io, result| {
            let refresh = result.is_ok() && harness.borrow().native_queue();
            done(io, result);
            if refresh {
                let current = binding.clone();
                harness.borrow_mut().queue(
                    io,
                    &binding,
                    deferred(Box::new(move |_, result| {
                        updates
                            .borrow_mut()
                            .push_back(Update::queue(current, result));
                    })),
                );
            }
        })))
    }
}

/// The item at this revision as this helper last read it.
fn cached(held: &Held, key: &(Id, String), id: &str, revision: u64) -> Option<store::Item> {
    let queues = held.borrow();
    let record = queues.get(key)?.record.as_ref()?;
    record.items.iter().find(|item| item.id == id && item.revision == revision).cloned()
}

#[cfg(test)]
#[path = "queue.test.rs"]
mod tests;
