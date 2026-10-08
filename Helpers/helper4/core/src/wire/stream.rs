//! A response cursor produces bounded frames only when the UI writer has room.
use super::{Error, Header, Kind, body, packet};
use crate::json::Json;

pub const CHUNK: usize = 65_536;

pub struct Message {
    pub kind: Kind,
    pub id: u64,
    bulk: bool,
    bytes: Vec<u8>,
    offset: usize,
    sequence: u64,
    metadata: Option<Vec<u8>>,
    streamed: bool,
    finished: bool,
}

impl Message {
    pub fn select(messages: &std::collections::VecDeque<Self>) -> usize {
        let mut seen = std::collections::BTreeSet::new();
        messages
            .iter()
            .take_while(|message| message.bulk || message.kind == Kind::Response)
            .position(|message| seen.insert(message.id) && message.kind == Kind::Response)
            .unwrap_or(0)
    }

    pub fn json(kind: Kind, id: u64, bytes: Vec<u8>) -> Self {
        let bulk = kind == Kind::Chunk || (kind == Kind::Notify
            && Json::parse(&bytes).ok().is_some_and(|json| matches!(
                json.root().get("method").and_then(|value| value.string()),
                Some("terminal.output" | "terminal.stderr")
            )));
        let bytes = if kind == Kind::Chunk {
            bytes
        } else {
            body::from_json(&bytes).unwrap_or_else(|error| {
                body::from_json(&super::problem(&error)).expect("bounded protocol error")
            })
        };
        let mut message = Self::new(kind, id, bytes, None);
        message.bulk = bulk;
        message
    }

    fn new(kind: Kind, id: u64, bytes: Vec<u8>, metadata: Option<Vec<u8>>) -> Self {
        let streamed = kind != Kind::Chunk && bytes.len() > CHUNK;
        Self {
            kind,
            id,
            bulk: kind == Kind::Chunk,
            bytes,
            offset: 0,
            sequence: 0,
            streamed: streamed || metadata.is_some(),
            metadata,
            finished: false,
        }
    }

    pub fn binary(kind: Kind, id: u64, bytes: Vec<u8>, metadata: Vec<u8>) -> Result<Self, Error> {
        Json::parse(&metadata).map_err(|_| Error::Kind)?;
        let message = Self::new(kind, id, bytes, Some(metadata));
        if message.end().len() > CHUNK {
            return Err(Error::Limit);
        }
        Ok(message)
    }

    /// Includes the header; callers reserve this much before advancing the cursor.
    pub fn size(&self) -> usize {
        if self.finished {
            0
        } else if !self.streamed {
            13 + self.bytes.len()
        } else if self.offset < self.bytes.len() {
            21 + (self.bytes.len() - self.offset).min(CHUNK)
        } else {
            13 + self.end().len()
        }
    }

    fn end(&self) -> Vec<u8> {
        let encoding = if self.metadata.is_some() {
            "binary"
        } else {
            "value"
        };
        let value = Progress {
            chunks: self.bytes.len().div_ceil(CHUNK) as u64,
            bytes: self.bytes.len() as u64,
        }
        .finish(encoding, Ok(self.metadata.as_deref()));
        body::from_json(&value).expect("bounded stream metadata")
    }
}

impl Iterator for Message {
    type Item = Vec<u8>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.finished {
            return None;
        }
        let (kind, bytes) = if !self.streamed {
            self.finished = true;
            (self.kind, std::mem::take(&mut self.bytes))
        } else if self.offset < self.bytes.len() {
            let end = self.offset + (self.bytes.len() - self.offset).min(CHUNK);
            let mut bytes = self.sequence.to_le_bytes().to_vec();
            bytes.extend_from_slice(&self.bytes[self.offset..end]);
            self.offset = end;
            self.sequence += 1;
            (Kind::Chunk, bytes)
        } else {
            self.finished = true;
            (self.kind, self.end())
        };
        Some(packet(kind, self.id, &bytes).expect("bounded server frame"))
    }
}

/// Plain counters for an incremental response, using the same frames as Message.
#[derive(Clone, Copy, Default)]
pub struct Progress {
    pub chunks: u64,
    pub bytes: u64,
}
impl Progress {
    pub fn chunk(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Error> {
        if bytes.is_empty() || bytes.len() > CHUNK {
            return Err(Error::Length);
        }
        let total = self
            .bytes
            .checked_add(bytes.len() as u64)
            .ok_or(Error::Length)?;
        let count = self.chunks.checked_add(1).ok_or(Error::Length)?;
        let mut body = self.chunks.to_le_bytes().to_vec();
        body.extend_from_slice(bytes);
        self.bytes = total;
        self.chunks = count;
        Ok(body)
    }
    pub fn finish(
        &self,
        encoding: &str,
        result: Result<Option<&[u8]>, &crate::api::Error>,
    ) -> Vec<u8> {
        use crate::encode::Encode;
        let mut body = b"{\"stream\":".to_vec();
        crate::encode::object(
            &mut body,
            &[
                ("chunks", &self.chunks),
                ("bytes", &self.bytes),
                ("encoding", &encoding),
            ],
        );
        match result {
            Ok(Some(metadata)) => {
                body.extend_from_slice(b",\"result\":");
                body.extend_from_slice(metadata);
            }
            Err(error) => {
                body.extend_from_slice(b",\"error\":");
                error.encode(&mut body);
            }
            Ok(None) => {}
        }
        body.push(b'}');
        body
    }
}

pub enum Received {
    Json(Vec<u8>),
    Binary { bytes: Vec<u8>, metadata: Json },
}

/// One request's collector. The caller supplies its admitted result-byte budget.
pub struct Collector {
    id: u64,
    limit: usize,
    sequence: u64,
    bytes: Vec<u8>,
}

impl Collector {
    pub fn new(id: u64, limit: usize) -> Self {
        Self {
            id,
            limit,
            sequence: 0,
            bytes: Vec::new(),
        }
    }

    pub fn push(&mut self, header: Header, body: &[u8]) -> Result<Option<Received>, Error> {
        if header.id != self.id || header.len as usize != body.len() {
            return Err(Error::Length);
        }
        if header.kind == Kind::Chunk {
            if !(8..=CHUNK + 8).contains(&body.len()) {
                return Err(Error::Length);
            }
            let sequence = u64::from_le_bytes(body[..8].try_into().unwrap());
            if sequence != self.sequence {
                return Err(Error::Sequence);
            }
            if body.len() - 8 > self.limit - self.bytes.len() {
                return Err(Error::Limit);
            }
            self.bytes.extend_from_slice(&body[8..]);
            self.sequence += 1;
            return Ok(None);
        }
        if !matches!(header.kind, Kind::Response | Kind::Notify) {
            return Err(Error::Kind);
        }
        let document = body::decode(body).map_err(|_| Error::Kind)?;
        let Some(stream) = document.root().get("stream") else {
            if self.sequence != 0 {
                return Err(Error::Truncated);
            }
            if body.len() > self.limit {
                return Err(Error::Limit);
            }
            return Ok(Some(Received::Json(
                document.root().write().map_err(|_| Error::Kind)?,
            )));
        };
        if stream.get("chunks").and_then(|v| v.unsigned()) != Some(self.sequence) {
            return Err(Error::Sequence);
        }
        if stream.get("bytes").and_then(|v| v.unsigned()) != Some(self.bytes.len() as u64) {
            return Err(Error::Length);
        }
        if document.root().get("error").is_some() {
            self.sequence = 0;
            self.bytes.clear();
            return Ok(Some(Received::Json(
                document.root().write().map_err(|_| Error::Kind)?,
            )));
        }
        let received = match stream.get("encoding").and_then(|v| v.string()) {
            Some("value") => Received::Json(
                body::decode(&std::mem::take(&mut self.bytes))
                    .map_err(|_| Error::Kind)?
                    .root()
                    .write()
                    .map_err(|_| Error::Kind)?,
            ),
            Some("binary") => {
                let metadata = document.root().get("result").ok_or(Error::Kind)?;
                Received::Binary {
                    bytes: std::mem::take(&mut self.bytes),
                    metadata: Json::parse(&metadata.write().map_err(|_| Error::Kind)?)
                        .map_err(|_| Error::Kind)?,
                }
            }
            _ => return Err(Error::Kind),
        };
        self.sequence = 0;
        Ok(Some(received))
    }

    pub fn finish(&self) -> Result<(), Error> {
        if self.sequence == 0 {
            Ok(())
        } else {
            Err(Error::Truncated)
        }
    }
}
