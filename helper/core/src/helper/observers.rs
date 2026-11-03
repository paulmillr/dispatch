//! The helper's subscriptions: backend, terminal and chat opens that stay pending until their
//! request ends (helper/PROTOCOL.md, Limits). Kept in arrival order, the order every fan-out has
//! always delivered in, and indexed by target: identical subscriptions (one target, any number of
//! requests, from one client or several) share one index entry, so an update looks up its own
//! targets instead of scanning every subscription, and each request still gets its own copy.
use super::*;
use std::ops::Bound::{self, Excluded, Included};

pub(crate) type Observer = (RawFd, u64, Scope);
type Range = (Bound<Scope>, Bound<Scope>);

#[derive(Clone, Default)]
pub(crate) struct Observers {
    /// By arrival.
    list: BTreeMap<u64, Observer>,
    /// Each (client, request)'s arrival.
    requests: BTreeMap<(RawFd, u64), u64>,
    /// The arrivals subscribed to each target.
    targets: BTreeMap<Scope, BTreeSet<u64>>,
    /// Subscriptions by client.
    clients: BTreeMap<RawFd, usize>,
    next: u64,
}

impl Observers {
    pub fn len(&self) -> usize {
        self.list.len()
    }

    /// Client `fd`'s subscriptions.
    pub fn count(&self, fd: RawFd) -> usize {
        self.clients.get(&fd).copied().unwrap_or(0)
    }

    /// Every subscription, by arrival.
    pub fn iter(&self) -> impl Iterator<Item = &Observer> {
        self.list.values()
    }

    pub fn get(&self, fd: RawFd, id: u64) -> Option<&Scope> {
        self.requests.get(&(fd, id)).map(|seq| &self.list[seq].2)
    }

    /// A request id names one subscription of its client: a second with the same id replaces it.
    pub fn push(&mut self, observer: Observer) {
        self.remove(observer.0, observer.1);
        let seq = self.next;
        self.next += 1;
        self.requests.insert((observer.0, observer.1), seq);
        self.targets.entry(observer.2.clone()).or_default().insert(seq);
        *self.clients.entry(observer.0).or_default() += 1;
        self.list.insert(seq, observer);
    }

    pub fn remove(&mut self, fd: RawFd, id: u64) -> bool {
        let Some(seq) = self.requests.remove(&(fd, id)) else {
            return false;
        };
        let (_, _, scope) = self.list.remove(&seq).expect("indexed subscription");
        self.unindex(&scope, seq);
        if let Some(count) = self.clients.get_mut(&fd) {
            *count -= 1;
            if *count == 0 {
                self.clients.remove(&fd);
            }
        }
        true
    }

    /// Every subscription of client `fd` ends.
    pub fn remove_client(&mut self, fd: RawFd) {
        if self.clients.contains_key(&fd) {
            self.retain(|(peer, _, _)| *peer != fd);
        }
    }

    pub fn retain(&mut self, mut keep: impl FnMut(&Observer) -> bool) {
        let ended: Vec<_> = self
            .list
            .values()
            .filter(|observer| !keep(observer))
            .map(|(fd, id, _)| (*fd, *id))
            .collect();
        for (fd, id) in ended {
            self.remove(fd, id);
        }
    }

    /// terminals.create with a size: its subscription becomes the created terminal's attach, in
    /// the place it arrived; None ends it.
    pub fn adopt(&mut self, fd: RawFd, id: u64, terminal: Option<Id>) {
        if !matches!(self.get(fd, id), Some(Scope::Created)) {
            return;
        }
        let Some(terminal) = terminal else {
            self.remove(fd, id);
            return;
        };
        let seq = self.requests[&(fd, id)];
        self.unindex(&Scope::Created, seq);
        self.targets.entry(Scope::Terminal(terminal)).or_default().insert(seq);
        self.list.get_mut(&seq).unwrap().2 = Scope::Terminal(terminal);
    }

    /// Whether any chat of `terminal` is open.
    pub fn chats(&self, terminal: Id) -> bool {
        self.targets.range(chats(terminal)).next().is_some()
    }

    /// The subscriptions of these targets, by arrival.
    pub fn select(&self, ranges: impl IntoIterator<Item = Range>) -> impl Iterator<Item = &Observer> {
        let mut seqs: Vec<u64> = ranges
            .into_iter()
            .flat_map(|range| self.targets.range(range).flat_map(|(_, seqs)| seqs.iter().copied()))
            .collect();
        seqs.sort_unstable();
        seqs.dedup();
        seqs.into_iter().map(|seq| &self.list[&seq])
    }

    /// Attach subscriptions (Scope::Terminal), in no particular order.
    pub fn attached(&self) -> impl Iterator<Item = &Observer> {
        self.targets
            .range((Included(Scope::Terminal(0)), Excluded(Scope::Events(0))))
            .flat_map(|(_, seqs)| seqs.iter().map(|seq| &self.list[seq]))
    }

    /// Distinct targets subscribed to.
    #[cfg(test)]
    pub fn targets(&self) -> usize {
        self.targets.len()
    }

    fn unindex(&mut self, scope: &Scope, seq: u64) {
        if let Some(seqs) = self.targets.get_mut(scope) {
            seqs.remove(&seq);
            if seqs.is_empty() {
                self.targets.remove(scope);
            }
        }
    }
}

pub(super) fn exact(scope: Scope) -> Range {
    (Included(scope.clone()), Included(scope))
}

/// Every chat of `terminal`, whatever its session.
pub(super) fn chats(terminal: Id) -> Range {
    let end = match terminal.checked_add(1) {
        Some(next) => Scope::Chat(next, String::new()),
        None => Scope::Archive,
    };
    (Included(Scope::Chat(terminal, String::new())), Excluded(end))
}

/// A terminal's watchers: its backend's opens, its attaches and observes (agent claims and launches).
pub(super) fn watchers(terminal: Id) -> Vec<Range> {
    vec![
        exact(Scope::Backend((terminal >> 48) as usize)),
        exact(Scope::Terminal(terminal)),
        exact(Scope::Events(terminal)),
    ]
}

/// The targets whose subscriptions `update` may reach (Updates::update keeps its own match on top).
pub(super) fn targets(update: &Update, terminal: Option<Id>, module: usize) -> Vec<Range> {
    let backend = exact(Scope::Backend(module));
    let Some(id) = terminal else {
        return match update {
            Update::Topology { .. } | Update::Agent { .. } | Update::Clipboard { .. } => vec![backend],
            _ => Vec::new(),
        };
    };
    match update {
        Update::Topology { .. } | Update::Clipboard { .. } => vec![backend],
        Update::Agent { .. } => vec![backend, exact(Scope::Events(id))],
        Update::Output { .. } | Update::Stderr { .. } | Update::Restore { .. } | Update::Scroll { .. } => {
            vec![exact(Scope::Terminal(id))]
        }
        Update::Records { binding, .. }
        | Update::History { binding, .. }
        | Update::State { binding, .. }
        | Update::Queue { binding, .. }
        | Update::Interaction { binding, .. } => vec![exact(Scope::Chat(id, binding.session.clone()))],
        Update::Exit { .. } => vec![exact(Scope::Terminal(id)), exact(Scope::Events(id)), chats(id)],
        _ => Vec::new(),
    }
}
