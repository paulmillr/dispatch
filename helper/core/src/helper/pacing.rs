//! Feature `notify.pace` (helper/PROTOCOL.md, Features): a client that turns pacing on (`notify.pace {ms}`) gets its
//! lazy notifications held and released together, in order, with the next message it gets anyway (a reply, terminal
//! output, an urgent notification), on its next frame, or `ms` after the first one was held, whichever comes first.
//! A phone's radio then wakes for a batch instead of for every change of an agent's activity.
//!
//! Lazy: `agent.changed` whose `summary.waiting` and `summary.busy` are as this subscription was last told of the
//! terminal (activity text, new answer, title: the client reads chat.list again anyway); `topology` that differs from
//! the subscription's previous one only in terminal names (pane titles); `chat.records` and `chat.state` of a
//! subscription the client marked background (`chat.background`). Everything else is urgent and goes at once, after
//! everything held: the client receives its notifications in the order the helper produced them, less held snapshots a
//! later one of the same thing superseded (an `agent.changed` of the same terminal, a `topology` or `chat.state` of the
//! same subscription). Records are never dropped. Nothing of this runs for a client that never names the feature.
//! What a subscription was told is kept only while pacing is on: its first topology since then goes at once, and a
//! terminal's first summary is compared with idle and not waiting.
use super::*;

/// Wakes the loop when a paced client's held notifications are due.
pub(crate) const SECTION: &str = "ui.pace";
/// The longest `notify.pace` interval (ms); more is invalid_input.
pub(crate) const MAX: u64 = 600_000;
/// Held bytes past which everything held goes at once (records of a busy background chat are never collapsed).
pub(crate) const LIMIT: usize = 1 << 20;

/// A pacing request of a client, applied to its queue before the replies of the same loop pass.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Pace {
    /// `notify.pace {ms}`: 0 turns pacing off and releases what is held.
    Interval(u64),
    /// `chat.background {subscription, background}`.
    Background(u64, bool),
}

/// What a held notification supersedes: an earlier one with the same key is dropped when it comes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Key {
    /// agent.changed of (subscription, terminal).
    Agent(u64, u64),
    /// topology of a subscription (one backend each).
    Topology(u64),
    /// chat.state of a subscription (one conversation each).
    State(u64),
}

/// How a message to a paced client goes.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Class {
    /// At once, after everything held (less what it supersedes).
    Now(Option<Key>),
    /// Held until the next release.
    Later(Option<Key>),
}

struct Held {
    id: u64,
    body: Vec<u8>,
    key: Option<Key>,
}

/// One client's pacing: off until `notify.pace` with a non-zero interval.
#[derive(Default)]
pub(super) struct Pacing {
    interval: Option<Duration>,
    held: VecDeque<Held>,
    bytes: usize,
    /// When the first notification now held was held (set by the loop, which reads the clock).
    pub since: Option<Instant>,
    /// A timer is set for this time.
    pub armed: Option<Instant>,
    /// Subscriptions marked background: their chat.records and chat.state are lazy. Kept while pacing is off.
    background: BTreeSet<u64>,
    /// What each subscription was last given of a terminal's summary: (waiting, busy).
    agents: BTreeMap<(u64, u64), (Option<String>, bool)>,
    /// Each subscription's last topology without terminal names.
    shapes: BTreeMap<u64, Vec<u8>>,
}

impl Pacing {
    /// Pacing is on.
    pub fn on(&self) -> bool {
        self.interval.is_some()
    }
    /// Something is held.
    pub fn holding(&self) -> bool {
        !self.held.is_empty()
    }
    /// When what is held is due; None while nothing is held or the loop has not stamped it yet.
    pub fn due(&self) -> Option<Instant> {
        Some(self.since? + self.interval?)
    }
    /// `notify.pace {ms}`; true when what is held must go now (pacing turned off).
    pub fn set(&mut self, ms: u64) -> bool {
        if ms == 0 {
            self.interval = None;
            self.agents.clear();
            self.shapes.clear();
            return true;
        }
        self.interval = Some(Duration::from_millis(ms));
        // A shorter interval: the timer set for the old one may be late.
        self.armed = None;
        false
    }
    /// `chat.background`: only a subscription the client has open (`open`) is marked.
    pub fn background(&mut self, id: u64, background: bool, open: bool) {
        if background && open {
            self.background.insert(id);
        } else {
            self.background.remove(&id);
        }
    }
    /// Subscription `id` ended (answered, cancelled): its held notifications and what was told on it go.
    pub fn end(&mut self, id: u64) {
        self.background.remove(&id);
        self.shapes.remove(&id);
        self.agents.retain(|(stream, _), _| *stream != id);
        self.drop(|held| held.id == id);
    }

    /// How `body` (a queued message of `kind` on stream `id`) goes; records what it tells the client.
    pub fn classify(&mut self, kind: wire::Kind, id: u64, body: &[u8]) -> Class {
        if kind != wire::Kind::Notify {
            return Class::Now(None);
        }
        match wire::body::method(body) {
            Some("agent.changed") => {
                let Some((terminal, told)) = summary(body) else {
                    return Class::Now(None);
                };
                let key = Some(Key::Agent(id, terminal));
                let before = self.agents.insert((id, terminal), told.clone()).unwrap_or_default();
                if before == told { Class::Later(key) } else { Class::Now(key) }
            }
            Some("topology") => {
                let key = Some(Key::Topology(id));
                let Some(shape) = shape(body) else {
                    self.shapes.remove(&id);
                    return Class::Now(key);
                };
                if self.shapes.insert(id, shape.clone()).is_some_and(|before| before == shape) {
                    Class::Later(key)
                } else {
                    Class::Now(key)
                }
            }
            Some("chat.state") if self.background.contains(&id) => Class::Later(Some(Key::State(id))),
            Some("chat.state") => Class::Now(Some(Key::State(id))),
            Some("chat.records") if self.background.contains(&id) => Class::Later(None),
            _ => Class::Now(None),
        }
    }
    /// Drop held notifications `key` supersedes.
    pub fn supersede(&mut self, key: Option<Key>) {
        if let Some(key) = key {
            self.drop(|held| held.key == Some(key));
        }
    }
    /// Hold `body`, after dropping what it supersedes; true when the held bytes passed LIMIT.
    pub fn hold(&mut self, id: u64, body: Vec<u8>, key: Option<Key>) -> bool {
        self.supersede(key);
        self.bytes += body.len();
        self.held.push_back(Held { id, body, key });
        self.bytes >= LIMIT
    }
    /// Everything held, oldest first, as (stream, notification body).
    pub fn take(&mut self) -> Vec<(u64, Vec<u8>)> {
        self.since = None;
        self.bytes = 0;
        self.held.drain(..).map(|held| (held.id, held.body)).collect()
    }
    fn drop(&mut self, gone: impl Fn(&Held) -> bool) {
        let mut bytes = 0;
        self.held.retain(|held| {
            let keep = !gone(held);
            if keep {
                bytes += held.body.len();
            }
            keep
        });
        self.bytes = bytes;
        if self.held.is_empty() {
            self.since = None;
        }
    }
}

/// An agent.changed body's terminal and what decides its urgency: (summary.waiting, summary.busy).
fn summary(body: &[u8]) -> Option<(u64, (Option<String>, bool))> {
    let framed = [&wire::body::SCHEMA[..], body].concat();
    let value = wire::body::decode(&framed).ok()?;
    let params = value.get("params")?;
    let terminal = params.get("terminal")?.unsigned()?;
    let summary = params.get("summary")?;
    let waiting = summary.get("waiting").and_then(crate::json::Data::string).map(str::to_owned);
    let busy = summary.get("busy").and_then(crate::json::Data::boolean).unwrap_or(false);
    Some((terminal, (waiting, busy)))
}

/// A topology body with every terminal node's name left out: equal shapes differ in pane titles alone.
fn shape(body: &[u8]) -> Option<Vec<u8>> {
    use crate::json::Data;
    let framed = [&wire::body::SCHEMA[..], body].concat();
    let mut value = wire::body::decode(&framed).ok()?;
    let Data::Object(fields) = &mut value else { return None };
    let (_, Data::Object(params)) = fields.iter_mut().find(|(key, _)| *key == "params")? else { return None };
    let (_, Data::Array(nodes)) = params.iter_mut().find(|(key, _)| *key == "nodes")? else { return None };
    for node in nodes {
        let Data::Object(fields) = node else { return None };
        if fields.iter().any(|(key, value)| *key == "kind" && value.string() == Some("terminal")) {
            for (key, value) in fields.iter_mut() {
                if *key == "name" {
                    *value = Data::Null;
                }
            }
        }
    }
    wire::body::encode(&value).ok()
}

#[cfg(test)]
#[path = "pacing.test.rs"]
mod tests;
