use super::*;
use crate::system::queue::Queue;

pub(super) struct Client {
    decoder: wire::Decoder,
    header: Option<wire::Header>,
    body: Vec<u8>,
    pub pending: BTreeSet<u64>,
    pub output: Queue,
    pub messages: VecDeque<wire::Message>,
    pub write: RawFd,
    pub eof: bool,
    pub failed: bool,
    pub drains: BTreeMap<u64, Done<()>>,
    /// terminal.output held back for coalescing (feature terminals.coalesce).
    pub coalesced: Option<Coalesced>,
    /// terminal.output payload bytes admitted to `output` and not yet acknowledged with
    /// terminals.ack (feature terminals.window), in all and by subscription; always 0 for other
    /// clients. A subscription that ends takes its own with it: what was in flight for it is
    /// dropped by the client, never acknowledged.
    pub unacked: u64,
    credits: BTreeMap<u64, u64>,
    /// The read interest this loop last set on the client's read side.
    pub listening: bool,
}

/// Feature requests.backlog: the helper keeps reading a client's requests while its output is
/// backed up, until this many replies and other non-output messages wait unadmitted, or these
/// many of their bytes; then it stops reading that client until they drop below. A client
/// flooding requests (each reply small, an echo) cannot grow `messages` without limit, and one
/// large reply (a file read) is let through whole, as before. Terminal output does not count:
/// a full queue already pauses the multiplexers that produce it (DispatchHelper::start).
pub(super) const BACKLOG: usize = 256;
pub(super) const BACKLOG_BYTES: usize = 1 << 20;
/// Feature terminals.window: the terminal.output payload bytes a client may have unacknowledged.
/// Output past it waits here (replies pass it) and the multiplexers are paused, as for a full
/// queue, until terminals.ack brings the count below (helper/PROTOCOL.md, Features).
pub(crate) const OUTPUT_WINDOW: u64 = 256 * 1024;

/// One stream's terminal output collected for at most `WINDOW` and `LIMIT` bytes, so a client
/// that asked for it gets fewer, larger frames (tmux control mode yields one per line).
pub(super) struct Coalesced {
    pub id: u64,
    pub terminal: u64,
    pub bytes: Vec<u8>,
    pub since: Instant,
    /// A timer for `since + WINDOW` is set.
    pub armed: bool,
    /// The client has an output window: the joined output carries its size as credit.
    pub counted: bool,
}
/// How long output may wait, and how much one frame carries (inline: under wire::CHUNK).
pub(super) const WINDOW: std::time::Duration = std::time::Duration::from_millis(4);
pub(super) const LIMIT: usize = 60_000;

/// The payload size of an encoded terminal.output notification (terminals.window credit).
pub(super) fn output_size(body: &[u8]) -> Option<u64> {
    if wire::body::method(body) != Some("terminal.output") {
        return None;
    }
    let framed = [&wire::body::SCHEMA[..], body].concat();
    let value = wire::body::decode(&framed).ok()?;
    match value.get("params")?.get("bytes")? {
        crate::json::Data::Bytes(bytes) => Some(bytes.len() as u64),
        _ => None,
    }
}

/// The terminal and bytes of an encoded terminal.output notification.
pub(super) fn output(body: &[u8]) -> Option<(u64, Vec<u8>)> {
    if wire::body::method(body) != Some("terminal.output") {
        return None;
    }
    // Queued bodies carry no schema prefix (wire::Message::value adds it).
    let framed = [&wire::body::SCHEMA[..], body].concat();
    let value = wire::body::decode(&framed).ok()?;
    let params = value.get("params")?;
    let terminal = params.get("terminal")?.unsigned()?;
    let bytes = match params.get("bytes")? {
        crate::json::Data::Bytes(bytes) => bytes.to_vec(),
        _ => return None,
    };
    Some((terminal, bytes))
}

impl Client {
    pub fn new(write: RawFd) -> Self {
        Self {
            decoder: wire::Decoder::new(wire::LIMIT),
            header: None,
            body: Vec::new(),
            pending: BTreeSet::new(),
            output: Queue::new(OUTPUT),
            messages: VecDeque::new(),
            write,
            eof: false,
            failed: false,
            drains: BTreeMap::new(),
            coalesced: None,
            unacked: 0,
            credits: BTreeMap::new(),
            listening: true,
        }
    }

    /// Whether the helper reads this client's requests now. Without requests.backlog (`backlog`
    /// false) only while its output queue has room for a frame, as recorded clients expect;
    /// with it until its unadmitted replies pass BACKLOG or BACKLOG_BYTES.
    pub fn reading(&self, backlog: bool) -> bool {
        if self.eof {
            return false;
        }
        if !backlog {
            return self.output.space() >= FRAME;
        }
        let (mut count, mut bytes) = (0, 0);
        for message in self.messages.iter().filter(|message| !message.bulk()) {
            count += 1;
            bytes += message.remaining();
            if count >= BACKLOG || bytes >= BACKLOG_BYTES {
                return false;
            }
        }
        true
    }

    /// Whether output may be admitted now: a window client's output waits while it has
    /// OUTPUT_WINDOW bytes unacknowledged.
    pub fn window_open(&self, message: &wire::Message) -> bool {
        message.credit == 0 || self.unacked < OUTPUT_WINDOW
    }

    /// Move frames of queued messages into `output` while it has room, in `wire::Message::select`
    /// order: replies may pass unrelated bulk bytes, but not semantic notifications (a mutation's
    /// topology/state reaches the UI before its completion), and a window client's output waits
    /// for acknowledgements while replies pass it. Returns the responses fully admitted: their
    /// requests are answered.
    pub fn admit(&mut self) -> std::io::Result<Vec<u64>> {
        let mut answered = Vec::new();
        loop {
            let index = wire::Message::select(&self.messages);
            let Some(message) = self.messages.get(index) else {
                break;
            };
            if message.size() > self.output.space() || !self.window_open(message) {
                break;
            }
            let message = &mut self.messages[index];
            let frame = message.next().expect("pending response frame");
            // A message's output counts once its last frame is admitted; a cancel before then drops
            // it whole, and the client discards a cancelled stream's partial data.
            let credit = if message.size() == 0 { message.credit } else { 0 };
            self.output
                .record(Some(message.id), frame)
                .map_err(|_| std::io::Error::other("UI frame admission changed"))?;
            if credit > 0 {
                *self.credits.entry(message.id).or_default() += credit;
                self.unacked += credit;
            }
            if message.size() == 0 {
                let message = self.messages.remove(index).unwrap();
                if message.kind == wire::Kind::Response {
                    self.pending.remove(&message.id);
                    self.forget(message.id);
                    answered.push(message.id);
                }
            }
        }
        Ok(answered)
    }

    /// terminals.ack of `bytes` on subscription `id`: more than it has outstanding counts as all
    /// of it; an ended subscription's late acknowledgement changes nothing.
    pub fn acknowledge(&mut self, id: u64, bytes: u64) {
        if let Some(credit) = self.credits.get_mut(&id) {
            let taken = bytes.min(*credit);
            *credit -= taken;
            self.unacked -= taken;
            if *credit == 0 {
                self.credits.remove(&id);
            }
        }
    }

    /// A subscription ended: its outstanding output no longer counts.
    fn forget(&mut self, id: u64) {
        if let Some(credit) = self.credits.remove(&id) {
            self.unacked -= credit;
        }
    }

    /// Queue `body` for stream `id`; with `coalesce` (the current time) terminal.output joins
    /// held output of the same stream and terminal. Anything else first releases held output,
    /// keeping the order. `counted`: the client has an output window (terminals.window), so
    /// terminal.output carries its payload size as credit.
    pub fn queue(&mut self, kind: wire::Kind, id: u64, body: Vec<u8>, coalesce: Option<Instant>, counted: bool) {
        if let Some(now) = coalesce
            && kind == wire::Kind::Notify
            && let Some((terminal, bytes)) = output(&body)
        {
            match &mut self.coalesced {
                Some(held) if held.id == id && held.terminal == terminal && held.bytes.len() + bytes.len() <= LIMIT => {
                    held.bytes.extend_from_slice(&bytes);
                }
                _ => {
                    self.release();
                    self.coalesced = Some(Coalesced { id, terminal, bytes, since: now, armed: false, counted });
                }
            }
            if self.coalesced.as_ref().is_some_and(|held| held.bytes.len() >= LIMIT) {
                self.release();
            }
            return;
        }
        self.release();
        let credit = if counted && kind == wire::Kind::Notify { output_size(&body).unwrap_or(0) } else { 0 };
        let mut message = wire::Message::value(kind, id, body);
        message.credit = credit;
        self.messages.push_back(message);
    }

    /// Send held output now.
    pub fn release(&mut self) {
        if let Some(held) = self.coalesced.take() {
            let body = crate::encode::notify(
                "terminal.output",
                &[("terminal", &held.terminal), ("bytes", &crate::encode::Bytes(&held.bytes))],
            );
            let mut message = wire::Message::value(wire::Kind::Notify, held.id, body);
            message.credit = if held.counted { held.bytes.len() as u64 } else { 0 };
            self.messages.push_back(message);
        }
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Result<Vec<(wire::Header, Vec<u8>)>, wire::Error> {
        let mut messages = Vec::new();
        let (header, body) = (&mut self.header, &mut self.body);
        self.decoder.feed(bytes, |event| match event {
            wire::Event::Begin(value) => {
                *header = Some(value);
                body.clear();
            }
            wire::Event::Data(bytes) => body.extend_from_slice(bytes),
            wire::Event::End => messages.push((header.take().unwrap(), std::mem::take(body))),
        })?;
        Ok(messages)
    }

    pub fn cancel(&mut self, io: &mut dyn Io, id: u64) {
        self.abort(io, Some(id));
        self.pending.remove(&id);
        self.messages.retain(|message| message.id != id);
        self.output.cancel(id);
        self.forget(id);
    }

    pub fn abort(&mut self, io: &mut dyn Io, request: Option<u64>) {
        let ids: Vec<_> = self
            .drains
            .keys()
            .copied()
            .filter(|id| request.is_none_or(|request| request == *id))
            .collect();
        for id in ids {
            deferred(self.drains.remove(&id).unwrap())(io, Err(cancelled()));
        }
    }
}

pub(super) fn cancelled() -> Error {
    Error {
        code: "cancelled",
        message: String::new(),
    }
}

#[cfg(test)]
#[path = "client.test.rs"]
mod tests;
