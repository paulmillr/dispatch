//! What clients may hold in a helper at once (helper/PROTOCOL.md, Limits): connections, open
//! requests, subscriptions and the input of large frames still arriving. Each bound sits far
//! above what the Mac and iPhone apps hold on a connection, so only a runaway or hostile client
//! meets one. Past a bound a request is answered `busy` without running and a new connection is
//! refused with a `busy` frame; what was admitted keeps being served. A connection below its share
//! is admitted whatever the others hold, so one flooding client cannot starve a healthy one, and
//! under pressure a connection that holds a place without using it is closed.
use super::*;

pub(super) struct Limits {
    /// Bus clients a listening helper serves at once (a stdio helper has its one).
    pub connections: usize,
    /// Requests a connection has open (answered once their last frame is admitted), subscriptions included.
    pub pending: usize,
    /// Open requests of all connections; past it only connections below `share` get more.
    pub pending_total: usize,
    /// Subscriptions (backends.open, terminals.attach, terminals.observe, chat.open, a sized terminals.create) a
    /// connection has open.
    pub subscriptions: usize,
    /// Subscriptions of all connections; past it only connections below `share` open more.
    pub subscriptions_total: usize,
    /// Open requests and subscriptions a connection is always admitted, whatever the others hold.
    pub share: usize,
    /// Announced bytes of frames larger than `small` that are still arriving, all connections together. Past it a
    /// large frame is still admitted within its connection's fair share (`input` divided among the connections
    /// holding one, itself included); else it is read and dropped, and a request answered `busy`.
    pub input: u64,
    /// Frames this large or smaller are always read whole (their buffer is small next to `input`).
    pub small: u32,
    /// Under pressure (more than half of `connections`, or more than half of `input` announced), an unsettled
    /// connection (`Unsettled`) is closed after this long without traffic either way.
    pub idle: Duration,
    /// ... and, unsettled by a frame, by never completing one or by closing, after `idle` plus its frame's
    /// announced length at this many bytes a second in all, however it trickles.
    pub rate: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            connections: 64,
            pending: 16_384,
            pending_total: 65_536,
            subscriptions: 8_192,
            subscriptions_total: 32_768,
            share: 2_048,
            input: 64 << 20,
            small: wire::CHUNK as u32,
            idle: Duration::from_secs(60),
            rate: 16 << 10,
        }
    }
}

/// Wakes the loop to close connections whose time is up.
pub(super) const PARTIAL: &str = "ui.partial";

fn busy(message: String) -> Error {
    Error { code: "busy", message }
}

/// Why a connection holds a place without being sure to use it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Unsettled {
    /// A frame begun and not finished (its announced length, 0 before the header is whole).
    Frame(u32),
    /// Connected and never completed a frame.
    Fresh,
    /// Its read side ended; replies or output are still owed to it.
    Closing,
    /// Holds no open request: no subscription, no reply owed. Only silence counts.
    Empty,
}

impl Limits {
    /// A request arriving on a connection with `open` requests open, while the others have `others`.
    pub fn request(&self, open: usize, others: usize) -> Result<(), Error> {
        if open >= self.pending {
            return Err(busy(format!("{} requests are open on this connection; this one did not run", open)));
        }
        if open >= self.share && open + others >= self.pending_total {
            return Err(busy(format!("{} requests are open in this helper; this one did not run", open + others)));
        }
        Ok(())
    }

    /// A subscription opening on connection `fd`.
    pub fn subscribe(&self, observers: &Observers, fd: RawFd) -> Result<(), Error> {
        let open = observers.count(fd);
        if open >= self.subscriptions {
            return Err(busy(format!("{open} subscriptions are open on this connection; this one did not open")));
        }
        if open >= self.share && observers.len() >= self.subscriptions_total {
            return Err(busy(format!(
                "{} subscriptions are open in this helper; this one did not open",
                observers.len()
            )));
        }
        Ok(())
    }

    /// A frame of `len` bytes beginning while `holders` other connections' large frames announce `others`: within
    /// the budget, or within this connection's fair share of it.
    pub fn admits(&self, len: u32, others: u64, holders: usize) -> bool {
        let len = u64::from(len);
        len <= u64::from(self.small) || others + len <= self.input || len <= self.input / (holders as u64 + 1)
    }

    /// A request whose frame `admits` refused.
    pub fn refused(&self) -> Error {
        busy("The helper is receiving too many large requests at once; this one did not run".into())
    }

    /// The frame a connection past `connections` gets before it is closed: a response to request 0, which no
    /// client sends, carrying the error.
    pub fn refusal(&self) -> Vec<u8> {
        let error = busy(format!("The helper already serves {} connections; try again once one closes", self.connections));
        wire::packet(wire::Kind::Response, 0, &[&wire::body::SCHEMA[..], &wire::problem(&error)].concat())
            .expect("small frame")
    }

    /// Whether connections are timed: many of them, or much large input announced.
    pub fn pressure(&self, clients: &BTreeMap<RawFd, Client>) -> bool {
        clients.len() > self.connections / 2
            || clients.values().map(|client| u64::from(client.reserved)).sum::<u64>() > self.input / 2
    }

    pub fn unsettled(&self, client: &Client) -> Option<Unsettled> {
        if client.partial() && !client.eof {
            Some(Unsettled::Frame(client.announced()))
        } else if client.eof {
            Some(Unsettled::Closing)
        } else if client.frames == 0 {
            Some(Unsettled::Fresh)
        } else if client.pending.is_empty() {
            Some(Unsettled::Empty)
        } else {
            None
        }
    }

    /// How long a connection may stay unsettled in all, traffic or not (None: as long as it has traffic).
    fn allowance(&self, unsettled: Unsettled) -> Option<Duration> {
        let bytes = match unsettled {
            Unsettled::Frame(len) => u64::from(len),
            Unsettled::Fresh => 0,
            Unsettled::Closing => u64::from(wire::LIMIT),
            Unsettled::Empty => return None,
        };
        Some(self.idle + Duration::from_millis(bytes.saturating_mul(1000) / self.rate.max(1)))
    }

    /// Under pressure, time every unsettled connection, whatever the helper does with it (read or not, its output
    /// backed up or not): from its last traffic (`idle`), and from when it became unsettled (`allowance`). Returns
    /// the first due time. Without pressure nothing is timed and `now` is never called: the clock is a recorded
    /// operation, so recorded sessions (a few clients) replay unchanged.
    pub fn track(&self, clients: &mut BTreeMap<RawFd, Client>, mut now: impl FnMut() -> Instant) -> Option<Instant> {
        let pressure = self.pressure(clients);
        let mut clock = None;
        let mut first: Option<Instant> = None;
        for client in clients.values_mut() {
            let Some(unsettled) = self.unsettled(client).filter(|_| pressure) else {
                (client.stamp, client.began, client.due) = (None, None, None);
                continue;
            };
            let at = *clock.get_or_insert_with(&mut now);
            let stamp = *client.stamp.get_or_insert(at);
            // A frame completed in between starts the allowance again.
            if client.began.is_none_or(|(_, frames)| frames != client.frames) {
                client.began = Some((at, client.frames));
            }
            let (began, _) = client.began.unwrap();
            let mut due = stamp + self.idle;
            if let Some(allowance) = self.allowance(unsettled) {
                due = due.min(began + allowance);
            }
            client.due = Some(due);
            first = Some(first.map_or(due, |first| first.min(due)));
        }
        first
    }

    /// `track`, with a wake-up for the first due time unless one is set.
    pub fn watch(&self, system: &mut System, clients: &mut BTreeMap<RawFd, Client>, armed: &mut bool) {
        let first = self.track(clients, || system.now());
        if let Some(first) = first
            && !*armed
        {
            *armed = true;
            let section = Io::section(system, PARTIAL);
            system.timer(first);
            Io::section(system, &section);
        }
    }

    /// The connections due by `now`, with why.
    pub fn expired(&self, clients: &BTreeMap<RawFd, Client>, now: Instant) -> Vec<(RawFd, Unsettled)> {
        clients
            .iter()
            .filter(|(_, client)| client.due.is_some_and(|due| now >= due))
            .filter_map(|(fd, client)| Some((*fd, self.unsettled(client)?)))
            .collect()
    }
}

#[cfg(test)]
#[path = "limits.test.rs"]
mod tests;
