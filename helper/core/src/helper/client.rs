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
