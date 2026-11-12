//! Feature `agents.activity`: `agent.changed` on a client's `backends.open` whenever what a
//! conversation list row shows of a bound agent changes (busy, its activity, an open approval or
//! question, its last answer), with a real summary, so the client asks `chat.list` again instead
//! of polling it. At most one notification per terminal per `WINDOW`.
//!
//! Sources: `Update::State` (Claude's registry status, Codex's and Pi's own state), the
//! interactions core holds, and `Update::Overview` from harnesses told which bindings are listed
//! (`Harness::listen`: those of backends a client of the feature opened). Nothing of this runs,
//! reads the clock or reaches a harness while no client of the feature is connected.
use super::*;
use crate::dispatch::features::{AGENTS_ACTIVITY, enabled};

/// Wakes the loop when a held notification is due.
pub(crate) const SECTION: &str = "ui.activity";
/// The shortest time between two notifications of one terminal.
pub(crate) const WINDOW: Duration = Duration::from_millis(500);
/// `summary.waiting` while an approval or blocking question of the conversation is open.
pub(crate) const INTERACTION: &str = "interaction";

/// What a list client is told of one terminal's agent (`agent.changed` `summary`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Told {
    /// "interaction" while an approval or blocking question is open, else the agent's own
    /// dialog kind (`State.dialog`, Claude's "permission prompt"), else none.
    pub waiting: Option<String>,
    pub busy: bool,
    pub activity: Option<String>,
    pub time_ms: Option<i64>,
    pub reply_ms: Option<i64>,
}

/// The wire summary: Summary's fields (waiting, busy, activity, revision) and the row's times.
struct Wire<'a>(&'a Told, u64);
impl crate::encode::Encode for Wire<'_> {
    fn encode(&self, out: &mut Vec<u8>) {
        let Wire(told, revision) = self;
        crate::encode::object(
            out,
            &[
                ("waiting", &told.waiting),
                ("busy", &told.busy),
                ("activity", &told.activity),
                ("revision", revision),
                ("time_ms", &told.time_ms),
                ("reply_ms", &told.reply_ms),
            ],
        );
    }
}

/// The `agent.changed` a list client gets for `terminal`.
pub(crate) fn body(terminal: Id, told: &Told, revision: u64) -> Vec<u8> {
    crate::encode::notify("agent.changed", &[("terminal", &terminal), ("summary", &Wire(told, revision))])
}

struct Row {
    /// The terminal's conversation; another one starts the row again.
    binding: Binding,
    now: Told,
    dialog: Option<String>,
    told: Option<Told>,
    at: Option<Instant>,
    revision: u64,
}

#[derive(Default)]
pub(crate) struct Activity {
    rows: BTreeMap<Id, Row>,
    /// What each harness was last told it lists (`Harness::listen`).
    listed: BTreeMap<usize, Vec<Binding>>,
    /// A timer is set for this time.
    pub armed: Option<Instant>,
}
pub(crate) type Shared = Rc<RefCell<Activity>>;

impl Activity {
    fn row(&mut self, terminal: Id, binding: &Binding) -> &mut Row {
        let fresh = || Row { binding: binding.clone(), now: Told::default(), dialog: None, told: None, at: None, revision: 0 };
        let row = self.rows.entry(terminal).or_insert_with(fresh);
        if !crate::dispatch::same(&row.binding, binding) {
            *row = fresh();
        }
        row
    }
    /// The conversation's state as its harness published it.
    pub(crate) fn state(&mut self, terminal: Id, binding: &Binding, state: &State) {
        let row = self.row(terminal, binding);
        row.now.busy = state.busy;
        row.now.activity = state.activity.clone();
        row.dialog = state.dialog.clone();
    }
    /// What the harness's list read found.
    pub(crate) fn overview(&mut self, terminal: Id, binding: &Binding, overview: &Overview) {
        let row = self.row(terminal, binding);
        row.now.time_ms = overview.time_ms;
        row.now.reply_ms = overview.reply_ms;
    }
    /// An interaction of the conversation opened or closed.
    pub(crate) fn touch(&mut self, terminal: Id, binding: &Binding) {
        self.row(terminal, binding);
    }
    /// The told summary of `terminal`, for the multiplexers' own agent.changed.
    pub(crate) fn told(&self, terminal: Id) -> Option<(Told, u64)> {
        self.rows.get(&terminal).and_then(|row| row.told.clone().map(|told| (told, row.revision)))
    }
    /// Keep the rows of current conversations (`current`), with `waiting` as it is now.
    pub(crate) fn refresh(&mut self, current: impl Fn(Id, &Binding) -> bool, waiting: impl Fn(Id, &Binding) -> bool) {
        self.rows.retain(|terminal, row| current(*terminal, &row.binding));
        for (terminal, row) in &mut self.rows {
            row.now.waiting = if waiting(*terminal, &row.binding) { Some(INTERACTION.into()) } else { row.dialog.clone() };
        }
    }
    /// Whether some row changed since it was last told.
    pub(crate) fn pending(&self) -> bool {
        self.rows.values().any(|row| row.told.as_ref() != Some(&row.now))
    }
    /// The notifications due at `now` for terminals whose backend `heard` (a list client opened
    /// it), and when the next held one is due. A change nobody hears is taken as told.
    pub(crate) fn due(&mut self, now: Instant, heard: impl Fn(Id) -> bool) -> (Vec<(Id, Vec<u8>)>, Option<Instant>) {
        let (mut bodies, mut next) = (Vec::new(), None::<Instant>);
        for (terminal, row) in &mut self.rows {
            if row.told.as_ref() == Some(&row.now) {
                continue;
            }
            if !heard(*terminal) {
                row.told = Some(row.now.clone());
                continue;
            }
            if let Some(at) = row.at
                && now < at + WINDOW
            {
                let due = at + WINDOW;
                next = Some(next.map_or(due, |next| next.min(due)));
                continue;
            }
            row.revision += 1;
            row.told = Some(row.now.clone());
            row.at = Some(now);
            bodies.push((*terminal, body(*terminal, &row.now, row.revision)));
        }
        (bodies, next)
    }
    /// The harnesses whose listed bindings changed, with their new ones.
    pub(crate) fn listen(&mut self, listed: BTreeMap<usize, Vec<Binding>>) -> Vec<(usize, Vec<Binding>)> {
        let mut changed: Vec<(usize, Vec<Binding>)> = self
            .listed
            .keys()
            .filter(|index| !listed.contains_key(index))
            .map(|index| (*index, Vec::new()))
            .collect();
        for (index, bindings) in &listed {
            if self.listed.get(index) != Some(bindings) {
                changed.push((*index, bindings.clone()));
            }
        }
        self.listed = listed;
        changed
    }
    pub(crate) fn idle(&self) -> bool {
        self.rows.is_empty() && self.listed.is_empty()
    }
    pub(crate) fn clear(&mut self) {
        self.rows.clear();
    }
}

/// Whether any client named the feature.
pub(crate) fn wanted(features: &crate::dispatch::features::Features) -> bool {
    features.borrow().values().any(|set| set.contains(AGENTS_ACTIVITY))
}

impl DispatchHelper {
    /// Tell harnesses what is listed, and list clients what changed (once per loop).
    pub(super) fn activity(&self, io: &mut dyn Io, replies: &Replies, observers: &Observers) {
        let wanted = wanted(&self.features);
        if !wanted && self.activity.borrow().idle() {
            return;
        }
        // The multiplexers a list client opened a backend of.
        let backends = (
            std::ops::Bound::Included(Scope::Backend(0)),
            std::ops::Bound::Excluded(Scope::Terminal(0)),
        );
        let heard: BTreeSet<usize> = observers
            .select([backends])
            .filter(|(fd, _, _)| wanted && enabled(&self.features, *fd, AGENTS_ACTIVITY))
            .filter_map(|(_, _, scope)| match scope {
                Scope::Backend(module) => Some(*module),
                _ => None,
            })
            .collect();
        // The bindings listed now, compared in place (this runs once per loop): copied only when
        // they changed.
        let changed = {
            let nodes = self.nodes.borrow();
            let mut listed: BTreeMap<usize, Vec<&Binding>> = BTreeMap::new();
            for (module, node) in nodes.values() {
                if let Some((harness, binding)) = &node.agent
                    && heard.contains(module)
                    && !binding.session.is_empty()
                {
                    listed.entry(*harness).or_default().push(binding);
                }
            }
            let same = {
                let activity = self.activity.borrow();
                activity.listed.len() == listed.len()
                    && listed.iter().all(|(index, now)| {
                        activity.listed.get(index).is_some_and(|before| before.len() == now.len() && before.iter().zip(now).all(|(a, b)| a == *b))
                    })
            };
            if same {
                Vec::new()
            } else {
                let owned = listed.into_iter().map(|(index, bindings)| (index, bindings.into_iter().cloned().collect())).collect();
                self.activity.borrow_mut().listen(owned)
            }
        };
        for (index, bindings) in changed {
            if let Some(harness) = self.harnesses.get(index) {
                harness.borrow_mut().listen(io, &bindings);
            }
        }
        if !wanted {
            self.activity.borrow_mut().clear();
            return;
        }
        {
            let nodes = self.nodes.borrow();
            let current = |terminal: Id, binding: &Binding| {
                nodes
                    .get(&terminal)
                    .and_then(|(_, node)| node.agent.as_ref())
                    .is_some_and(|(_, bound)| crate::dispatch::same(bound, binding))
            };
            let waiting =
                |terminal: Id, binding: &Binding| crate::dispatch::list::waiting(&self.interactions, terminal, &binding.session);
            self.activity.borrow_mut().refresh(current, waiting);
        }
        if !self.activity.borrow().pending() {
            return;
        }
        // The clock is read only for a change a list client is to hear of.
        let now = io.now();
        let (bodies, next) = self.activity.borrow_mut().due(now, |terminal| heard.contains(&((terminal >> 48) as usize)));
        for (terminal, body) in bodies {
            let module = (terminal >> 48) as usize;
            for (fd, request, _) in observers.select([observers::exact(Scope::Backend(module))]) {
                if enabled(&self.features, *fd, AGENTS_ACTIVITY) {
                    replies.borrow_mut().push_back((*fd, wire::Kind::Notify, *request, body.clone()));
                }
            }
        }
        let mut activity = self.activity.borrow_mut();
        if let Some(at) = next
            && activity.armed.is_none_or(|armed| armed > at)
        {
            activity.armed = Some(at);
            let section = Io::section(io, SECTION);
            io.timer(at);
            Io::section(io, &section);
        }
    }
}

#[cfg(test)]
#[path = "activity.test.rs"]
mod tests;
