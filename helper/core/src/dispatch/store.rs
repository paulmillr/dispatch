//! The host's queue store: one private file per conversation under `<storage>/queue/`, shared by
//! every helper of this account on the host. A message the host accepted stays here until it is
//! sent, removed, or paused for review; any helper bound to the agent may send it, and the file
//! decides which one does (a claim written with a checked replace, `Expected::Same`).
//!
//! This module is the record and its operations only, no I/O; `queue.rs` reads, applies and
//! writes. Every operation must give the same result when it is applied again to a newer file
//! (a lost checked write is retried on a fresh read).
use crate::{
    api::{Error, Mode, Pause, Preview, Queued},
    json::Data,
    wire::body,
};
use std::path::{Path, PathBuf};

/// Directory under `Io::storage`.
pub(crate) const DIRECTORY: &str = "queue";
/// The file format this helper writes; a file of another format is left alone.
const FORMAT: u64 = 1;
/// Old queue limits: 50 items, 1 MiB of text each (ChatCoordinator.swift:1617-1618).
pub(crate) const ITEMS: usize = 50;
pub(crate) const TEXT: usize = 1 << 20;
/// The largest file a reader accepts: every item at its limit, with room for the fields.
pub(crate) const LIMIT: u64 = (ITEMS * (TEXT + 4096) + 65_536) as u64;

/// A helper run: its process identity and a random token, so a reused pid is someone else.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Owner {
    pub pid: u32,
    pub start: [u64; 2],
    pub token: u64,
}

/// A mark made before this helper knew its run identity; replaced before it is written.
pub(crate) const UNSET: Owner = Owner { pid: 0, start: [0, 0], token: 0 };

/// One typed send the agent has not acknowledged yet: who typed which item.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Awaiting {
    pub owner: Owner,
    pub item: String,
}

/// The agent process and conversation an item was queued for (`dispatch::same`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Bound {
    pub session: String,
    pub pid: u32,
    pub start: [u64; 2],
}

impl Bound {
    pub(crate) fn of(binding: &crate::api::Binding) -> Self {
        Self {
            session: binding.session.clone(),
            pid: binding.process.pid,
            start: binding.process.start,
        }
    }
    pub(crate) fn matches(&self, binding: &crate::api::Binding) -> bool {
        *self == Self::of(binding)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Item {
    pub id: String,
    pub revision: u64,
    pub text: String,
    pub mode: Mode,
    pub command: bool,
    pub binding: Bound,
    pub pause: Option<Pause>,
    /// A helper is sending this item now.
    pub claim: Option<Owner>,
    /// A client of this helper is editing the item in its composer; sends wait.
    pub editing: Option<Owner>,
}

/// One conversation's queue as stored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Record {
    pub harness: String,
    pub session: String,
    /// The terminal's multiplexer (`Multiplexer::name`) and topology key (`Node::key`), stable
    /// across helpers: where a helper without clients finds the agent again.
    pub mux: String,
    pub terminal: String,
    pub serial: u64,
    /// A client filling the queue holds it (the phone's multi-item mirror), through its helper:
    /// released when that client or helper goes.
    pub hold: Option<Owner>,
    /// The last send typed its input and the agent has not acknowledged it yet (busy or new
    /// records): nobody sends the next item meanwhile.
    pub awaiting: Option<Awaiting>,
    pub items: Vec<Item>,
}

/// Where a conversation's file lives: the harness and session decide, never a helper-local id.
pub(crate) fn path(storage: &Path, harness: &str, session: &str) -> PathBuf {
    let mut hash = crate::hash::Sha256::new();
    hash.update(harness.as_bytes());
    hash.update(&[0]);
    hash.update(session.as_bytes());
    let digest = hash.finish();
    let name: String = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect();
    storage.join(DIRECTORY).join(format!("{name}.q"))
}

/// How a send ended, as the sender writes it back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// The input was typed and submitted: the item is gone, the agent's acknowledgement awaited.
    Written,
    /// It may have been submitted: never sent again automatically.
    Uncertain,
    /// The agent asked something only the user can answer.
    NeedsEdit,
    /// Nothing was typed; another attempt may follow.
    Retry,
}

/// A change to one conversation's queue. Ids are chosen before the first attempt, so a retry
/// of the same operation adds the same item.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Op {
    /// Read only (list, open, refresh).
    Read,
    Add { id: String, text: String, mode: Mode, command: bool, binding: Bound },
    /// `text: None` removes; `command: None` keeps the item's classification.
    Update { id: String, revision: u64, text: Option<String>, command: Option<bool>, binding: Bound },
    Remove { id: String, revision: u64 },
    Reorder(Vec<String>),
    /// Resume: clears Stopped only.
    Restore,
    Hold { held: bool, owner: Owner },
    Edit { id: String, revision: u64, editing: bool, owner: Owner },
    /// Send now (`queue.start`): takes the item out for an immediate send.
    Take { id: String, revision: u64, binding: Bound },
    /// Stop pauses every item not already paused.
    Stop,
    /// Permission withdrawn: stop every item (Resume, once allowed again, releases them).
    Revoke,
    /// The head item's binding no longer matches the agent on its terminal.
    Moved { id: String },
    /// Start sending the head, still bound to `binding`; nothing else may be in flight.
    Claim { id: String, owner: Owner, binding: Bound },
    Finish { id: String, owner: Owner, outcome: Outcome },
    /// The agent acknowledged this send (only this one: a later send awaits its own).
    Acknowledge(Awaiting),
    /// These owners' processes are gone: their sends become uncertain, their marks go.
    Release(Vec<Owner>),
    /// This helper lost track of its own send (its result never reached the file): uncertain,
    /// and its awaiting goes; its clients' edits and holds stay.
    Lost(Owner),
    /// A client left: the edits (and the hold) this helper made for it end.
    Left { owner: Owner, ids: Vec<String>, hold: bool },
}

impl Op {
    /// The operation with this helper's identity in place of marks made before it was known.
    pub(crate) fn resolved(&self, me: Owner) -> Self {
        let mut op = self.clone();
        let owner = match &mut op {
            Op::Hold { owner, .. } | Op::Edit { owner, .. } | Op::Claim { owner, .. } | Op::Finish { owner, .. }
            | Op::Lost(owner) | Op::Left { owner, .. } => Some(owner),
            _ => None,
        };
        if let Some(owner) = owner.filter(|owner| **owner == UNSET) {
            *owner = me;
        }
        op
    }
}

/// What an operation answers besides the new record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Answer {
    None,
    Added(Queued),
    Taken(Item),
    Claimed(Item),
}

fn expired() -> Error {
    Error { code: "expired", message: "The queued message changed".into() }
}
fn invalid(field: &str) -> Error {
    crate::dispatch::invalid(field)
}
fn busy() -> Error {
    Error { code: "busy", message: "The queued message is being sent".into() }
}

impl Record {
    pub(crate) fn new(harness: &str, session: &str, mux: &str, terminal: &str) -> Self {
        Self {
            harness: harness.into(),
            session: session.into(),
            mux: mux.into(),
            terminal: terminal.into(),
            serial: 0,
            hold: None,
            awaiting: None,
            items: Vec::new(),
        }
    }

    /// A helper would still send by itself: not held, and the head (sent first, always) unpaused.
    pub(crate) fn sendable(&self) -> bool {
        self.hold.is_none() && self.items.first().is_some_and(|item| item.pause.is_none())
    }

    /// A record with nothing worth keeping: its file is removed. An unacknowledged send keeps
    /// it, so the next item added through any helper still waits for the agent.
    pub(crate) fn empty(&self) -> bool {
        self.items.is_empty() && self.hold.is_none() && self.awaiting.is_none()
    }

    /// A send is in flight: nothing else is typed into this terminal meanwhile.
    pub(crate) fn claimed(&self) -> bool {
        self.items.iter().any(|item| item.claim.is_some())
    }

    pub(crate) fn snapshot(&self) -> Vec<Queued> {
        self.items.iter().map(queued).collect()
    }

    fn find(&self, id: &str, revision: u64) -> Result<usize, Error> {
        self.items
            .iter()
            .position(|item| item.id == id && item.revision == revision)
            .ok_or_else(expired)
    }

    fn next(&mut self) -> u64 {
        self.serial += 1;
        self.serial
    }

    pub(crate) fn apply(&mut self, op: &Op) -> Result<Answer, Error> {
        match op {
            Op::Read => {}
            Op::Add { id, text, mode, command, binding } => {
                if let Some(item) = self.items.iter().find(|item| item.id == *id) {
                    // A retry after a write this helper could not confirm: already added.
                    return Ok(Answer::Added(queued(item)));
                }
                if self.items.len() >= ITEMS {
                    return Err(invalid("text"));
                }
                let revision = self.next();
                let item = Item {
                    id: id.clone(),
                    revision,
                    text: text.clone(),
                    mode: *mode,
                    command: *command,
                    binding: binding.clone(),
                    pause: None,
                    claim: None,
                    editing: None,
                };
                let answer = queued(&item);
                self.items.push(item);
                return Ok(Answer::Added(answer));
            }
            Op::Update { id, revision, text, command, binding } => {
                let index = self.find(id, *revision)?;
                if self.items[index].claim.is_some() {
                    return Err(busy());
                }
                match text {
                    None => {
                        self.items.remove(index);
                    }
                    Some(text) => {
                        let serial = self.next();
                        let item = &mut self.items[index];
                        item.text = text.clone();
                        item.revision = serial;
                        item.pause = None;
                        item.command = command.unwrap_or(item.command);
                        item.editing = None;
                        item.binding = binding.clone();
                    }
                }
            }
            Op::Remove { id, revision } => {
                let index = self.find(id, *revision)?;
                if self.items[index].claim.is_some() {
                    return Err(busy());
                }
                self.items.remove(index);
            }
            Op::Reorder(order) => {
                let mut current: Vec<_> = self.items.iter().map(|item| item.id.as_str()).collect();
                let mut wanted: Vec<_> = order.iter().map(String::as_str).collect();
                current.sort_unstable();
                wanted.sort_unstable();
                if current != wanted {
                    return Err(invalid("items"));
                }
                self.items.sort_by_key(|item| order.iter().position(|id| *id == item.id));
            }
            Op::Restore => {
                for item in &mut self.items {
                    if item.pause == Some(Pause::Stopped) {
                        item.pause = None;
                    }
                }
            }
            Op::Hold { held, owner } => self.hold = held.then_some(*owner),
            Op::Edit { id, revision, editing, owner } => {
                let index = self.find(id, *revision)?;
                self.items[index].editing = editing.then_some(*owner);
            }
            Op::Take { id, revision, binding } => {
                let index = self.find(id, *revision)?;
                let item = &self.items[index];
                if item.pause.is_some() || !item.binding.eq(binding) {
                    return Err(invalid("item"));
                }
                // Another item being typed would interleave with this one in the terminal.
                if self.claimed() {
                    return Err(busy());
                }
                return Ok(Answer::Taken(self.items.remove(index)));
            }
            Op::Stop => {
                for item in &mut self.items {
                    item.pause.get_or_insert(Pause::Stopped);
                }
            }
            Op::Revoke => {
                for item in &mut self.items {
                    item.pause = Some(Pause::Stopped);
                }
            }
            Op::Moved { id } => {
                if let Some(item) = self.items.first_mut().filter(|item| item.id == *id && item.claim.is_none()) {
                    item.pause.get_or_insert(Pause::DestinationChanged);
                }
            }
            Op::Claim { id, owner, binding } => {
                let head = self.items.first();
                let free = head.is_some_and(|item| {
                    item.id == *id && item.pause.is_none() && item.editing.is_none() && item.binding == *binding
                });
                // A claimed item a reorder moved off the head is still being typed.
                if !free || self.claimed() || self.hold.is_some() || self.awaiting.is_some() {
                    return Err(busy());
                }
                let item = &mut self.items[0];
                item.claim = Some(*owner);
                return Ok(Answer::Claimed(item.clone()));
            }
            Op::Finish { id, owner, outcome } => {
                let Some(index) = self
                    .items
                    .iter()
                    .position(|item| item.id == *id && item.claim == Some(*owner))
                else {
                    // Released meanwhile (this helper was taken for gone): leave it as it is.
                    return Ok(Answer::None);
                };
                match outcome {
                    Outcome::Written => {
                        self.items.remove(index);
                        self.awaiting = Some(Awaiting { owner: *owner, item: id.clone() });
                    }
                    Outcome::Uncertain => {
                        let item = &mut self.items[index];
                        item.claim = None;
                        item.pause = Some(Pause::Uncertain);
                    }
                    Outcome::NeedsEdit => {
                        let item = &mut self.items[index];
                        item.claim = None;
                        item.pause = Some(Pause::NeedsEdit);
                    }
                    Outcome::Retry => self.items[index].claim = None,
                }
            }
            Op::Acknowledge(seen) => {
                if self.awaiting.as_ref() == Some(seen) {
                    self.awaiting = None;
                }
            }
            Op::Lost(owner) => {
                for item in &mut self.items {
                    if item.claim == Some(*owner) {
                        item.claim = None;
                        item.pause = Some(Pause::Uncertain);
                    }
                }
                if self.awaiting.as_ref().is_some_and(|awaiting| awaiting.owner == *owner) {
                    self.awaiting = None;
                }
            }
            Op::Release(owners) => {
                for item in &mut self.items {
                    if item.claim.is_some_and(|claim| owners.contains(&claim)) {
                        item.claim = None;
                        item.pause = Some(Pause::Uncertain);
                    }
                    if item.editing.is_some_and(|editing| owners.contains(&editing)) {
                        item.editing = None;
                    }
                }
                if self.awaiting.as_ref().is_some_and(|awaiting| owners.contains(&awaiting.owner)) {
                    self.awaiting = None;
                }
                if self.hold.is_some_and(|hold| owners.contains(&hold)) {
                    self.hold = None;
                }
            }
            Op::Left { owner, ids, hold } => {
                for item in &mut self.items {
                    if item.editing == Some(*owner) && ids.contains(&item.id) {
                        item.editing = None;
                    }
                }
                if *hold && self.hold == Some(*owner) {
                    self.hold = None;
                }
            }
        }
        Ok(Answer::None)
    }

    /// Owners other than `me` whose marks hold this queue: the drain checks they still run.
    pub(crate) fn foreign(&self, me: &Owner) -> Vec<Owner> {
        let mut owners: Vec<Owner> = self
            .items
            .iter()
            .flat_map(|item| [item.claim, item.editing])
            .chain([self.awaiting.as_ref().map(|awaiting| awaiting.owner), self.hold])
            .flatten()
            .filter(|owner| owner != me)
            .collect();
        owners.sort_by_key(|owner| (owner.pid, owner.start, owner.token));
        owners.dedup();
        owners
    }

    pub(crate) fn encode(&self) -> Result<Vec<u8>, Error> {
        fn start(start: &[u64; 2]) -> Data<'static> {
            Data::Array(start.iter().map(|value| Data::Unsigned(*value)).collect())
        }
        fn optional(owner: &Option<Owner>) -> Data<'static> {
            owner.as_ref().map_or(Data::Null, |owner| {
                Data::Object(vec![
                    ("pid", Data::Unsigned(owner.pid.into())),
                    ("start", start(&owner.start)),
                    ("token", Data::Unsigned(owner.token)),
                ])
            })
        }
        let items = self
            .items
            .iter()
            .map(|item| {
                Data::Object(vec![
                    ("id", Data::String(&item.id)),
                    ("revision", Data::Unsigned(item.revision)),
                    ("text", Data::String(&item.text)),
                    ("mode", Data::String(mode_name(item.mode))),
                    ("command", Data::Bool(item.command)),
                    (
                        "binding",
                        Data::Object(vec![
                            ("session", Data::String(&item.binding.session)),
                            ("pid", Data::Unsigned(item.binding.pid.into())),
                            ("start", start(&item.binding.start)),
                        ]),
                    ),
                    ("pause", item.pause.map_or(Data::Null, |pause| Data::String(pause_name(pause)))),
                    ("claim", optional(&item.claim)),
                    ("editing", optional(&item.editing)),
                ])
            })
            .collect();
        body::encode_plain(&Data::Object(vec![
            ("format", Data::Unsigned(FORMAT)),
            ("harness", Data::String(&self.harness)),
            ("session", Data::String(&self.session)),
            ("mux", Data::String(&self.mux)),
            ("terminal", Data::String(&self.terminal)),
            ("serial", Data::Unsigned(self.serial)),
            ("hold", optional(&self.hold)),
            (
                "awaiting",
                self.awaiting.as_ref().map_or(Data::Null, |awaiting| {
                    Data::Object(vec![("owner", optional(&Some(awaiting.owner))), ("item", Data::String(&awaiting.item))])
                }),
            ),
            ("items", Data::Array(items)),
        ]))
    }

    pub(crate) fn decode(bytes: &[u8]) -> Result<Self, Error> {
        let corrupt = || Error { code: "storage", message: "The stored queue is unreadable".into() };
        let value = body::decode_plain(bytes)?;
        if value.get("format").and_then(Data::unsigned) != Some(FORMAT) {
            return Err(Error { code: "storage", message: "The stored queue has another format".into() });
        }
        let string = |value: &Data<'_>, key: &str| value.get(key).and_then(Data::string).map(str::to_owned).ok_or_else(corrupt);
        let start = |value: Option<&Data<'_>>| -> Result<[u64; 2], Error> {
            let values: Vec<u64> = value
                .and_then(Data::array)
                .ok_or_else(corrupt)?
                .map(|value| value.unsigned().ok_or_else(corrupt))
                .collect::<Result<_, _>>()?;
            <[u64; 2]>::try_from(values).map_err(|_| corrupt())
        };
        let pid = |value: &Data<'_>| {
            value.get("pid").and_then(Data::unsigned).and_then(|pid| u32::try_from(pid).ok()).ok_or_else(corrupt)
        };
        let owner = |value: Option<&Data<'_>>| -> Result<Option<Owner>, Error> {
            match value {
                None | Some(Data::Null) => Ok(None),
                Some(value) => Ok(Some(Owner {
                    pid: pid(value)?,
                    start: start(value.get("start"))?,
                    token: value.get("token").and_then(Data::unsigned).ok_or_else(corrupt)?,
                })),
            }
        };
        let items = value
            .get("items")
            .and_then(Data::array)
            .ok_or_else(corrupt)?
            .map(|item| {
                let binding = item.get("binding").ok_or_else(corrupt)?;
                Ok(Item {
                    id: string(item, "id")?,
                    revision: item.get("revision").and_then(Data::unsigned).ok_or_else(corrupt)?,
                    text: string(item, "text")?,
                    mode: item.get("mode").and_then(Data::string).and_then(mode_of).ok_or_else(corrupt)?,
                    command: item.get("command").and_then(Data::boolean).ok_or_else(corrupt)?,
                    binding: Bound {
                        session: string(binding, "session")?,
                        pid: pid(binding)?,
                        start: start(binding.get("start"))?,
                    },
                    pause: match item.get("pause") {
                        None | Some(Data::Null) => None,
                        Some(pause) => Some(pause.string().and_then(pause_of).ok_or_else(corrupt)?),
                    },
                    claim: owner(item.get("claim"))?,
                    editing: owner(item.get("editing"))?,
                })
            })
            .collect::<Result<Vec<_>, Error>>()?;
        Ok(Self {
            harness: string(&value, "harness")?,
            session: string(&value, "session")?,
            mux: string(&value, "mux")?,
            terminal: string(&value, "terminal")?,
            serial: value.get("serial").and_then(Data::unsigned).ok_or_else(corrupt)?,
            hold: owner(value.get("hold"))?,
            awaiting: match value.get("awaiting") {
                None | Some(Data::Null) => None,
                Some(awaiting) => Some(Awaiting {
                    owner: owner(awaiting.get("owner"))?.ok_or_else(corrupt)?,
                    item: string(awaiting, "item")?,
                }),
            },
            items,
        })
    }
}

pub(crate) fn queued(item: &Item) -> Queued {
    Queued {
        id: item.id.clone(),
        mode: item.mode,
        revision: item.revision,
        preview: vec![Preview::Text(item.text.clone())],
        editable: true,
        editing: item.editing.is_some(),
        paused: item.pause,
        error: None,
    }
}

fn mode_name(mode: Mode) -> &'static str {
    match mode {
        Mode::Prompt => "prompt",
        Mode::Steer => "steer",
        Mode::FollowUp => "follow_up",
    }
}
fn mode_of(name: &str) -> Option<Mode> {
    match name {
        "prompt" => Some(Mode::Prompt),
        "steer" => Some(Mode::Steer),
        "follow_up" => Some(Mode::FollowUp),
        _ => None,
    }
}
fn pause_name(pause: Pause) -> &'static str {
    match pause {
        Pause::Stopped => "stopped",
        Pause::Uncertain => "uncertain",
        Pause::DestinationChanged => "destination_changed",
        Pause::NeedsEdit => "needs_edit",
    }
}
fn pause_of(name: &str) -> Option<Pause> {
    match name {
        "stopped" => Some(Pause::Stopped),
        "uncertain" => Some(Pause::Uncertain),
        "destination_changed" => Some(Pause::DestinationChanged),
        "needs_edit" => Some(Pause::NeedsEdit),
        _ => None,
    }
}

#[cfg(test)]
#[path = "store.test.rs"]
mod tests;
