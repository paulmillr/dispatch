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
}

/// One stream's terminal output collected for at most `WINDOW` and `LIMIT` bytes, so a client
/// that asked for it gets fewer, larger frames (tmux control mode yields one per line).
pub(super) struct Coalesced {
    pub id: u64,
    pub terminal: u64,
    pub bytes: Vec<u8>,
    pub since: Instant,
    /// A timer for `since + WINDOW` is set.
    pub armed: bool,
}
/// How long output may wait, and how much one frame carries (inline: under wire::CHUNK).
pub(super) const WINDOW: std::time::Duration = std::time::Duration::from_millis(4);
pub(super) const LIMIT: usize = 60_000;

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
        }
    }

    /// Queue `body` for stream `id`; with `coalesce` (the current time) terminal.output joins
    /// held output of the same stream and terminal. Anything else first releases held output,
    /// keeping the order.
    pub fn queue(&mut self, kind: wire::Kind, id: u64, body: Vec<u8>, coalesce: Option<Instant>) {
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
                    self.coalesced = Some(Coalesced { id, terminal, bytes, since: now, armed: false });
                }
            }
            if self.coalesced.as_ref().is_some_and(|held| held.bytes.len() >= LIMIT) {
                self.release();
            }
            return;
        }
        self.release();
        self.messages.push_back(wire::Message::value(kind, id, body));
    }

    /// Send held output now.
    pub fn release(&mut self) {
        if let Some(held) = self.coalesced.take() {
            let body = crate::encode::notify(
                "terminal.output",
                &[("terminal", &held.terminal), ("bytes", &crate::encode::Bytes(&held.bytes))],
            );
            self.messages.push_back(wire::Message::value(wire::Kind::Notify, held.id, body));
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
