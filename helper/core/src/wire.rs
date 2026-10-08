//! Binary UI framing: LE length, kind, connection-local u64 id and generated binary body.
use crate::{
    api,
    json::{self, Data},
};
pub mod body;
mod client;
mod reader;
mod stream;
pub use client::Client;
pub use reader::Reader;
pub use stream::{CHUNK, Collector, Message, Progress, Received};

/// Any generated schema change produces a different protocol version.
pub const VERSION: u64 = u64::from_le_bytes(body::SCHEMA);
/// c1654cc ToolDocument.swift:154-163: complete source text is bounded at 2 MB.
pub const TEXT_LIMIT: u32 = 2_000_000;
/// A JSON string byte can become a six-byte escape; include the result envelope.
pub const LIMIT: u32 = TEXT_LIMIT * 6 + b"{\"result\":\"\"}".len() as u32;

/// c1654cc SSHHelperConnection.swift:289-302,378-390: exact initial window and checked renewal.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Window {
    available: u32,
    opened: bool,
    closed: bool,
}
impl Window {
    pub const CAPACITY: u32 = 1_048_576;
    pub fn grant(&mut self, bytes: u32) -> Result<(), Error> {
        if self.closed
            || (!self.opened && bytes != Self::CAPACITY)
            || bytes > Self::CAPACITY - self.available
        {
            return Err(Error::Limit);
        }
        self.opened = true;
        self.closed = bytes == 0;
        self.available = if self.closed {
            0
        } else {
            self.available + bytes
        };
        Ok(())
    }
    pub fn active(&self) -> bool {
        self.opened && !self.closed
    }
    pub fn take(&mut self, bytes: u32) -> Result<(), Error> {
        if !self.opened || self.closed || bytes > self.available {
            return Err(Error::Limit);
        }
        self.available -= bytes;
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    Request = 1,
    Response = 2,
    Notify = 3,
    Cancel = 4,
    Chunk = 5,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Length,
    Kind,
    Limit,
    Truncated,
    Failed,
    Sequence,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    pub kind: Kind,
    pub id: u64,
    pub len: u32,
}

impl Header {
    pub fn encode(self, limit: u32) -> Result<[u8; 13], Error> {
        let length = self.len.checked_add(9).ok_or(Error::Length)?;
        if self.len > limit {
            return Err(Error::Limit);
        }
        let mut bytes = [0; 13];
        bytes[..4].copy_from_slice(&length.to_le_bytes());
        bytes[4] = self.kind as u8;
        bytes[5..].copy_from_slice(&self.id.to_le_bytes());
        Ok(bytes)
    }

    pub fn decode(bytes: &[u8; 13], limit: u32) -> Result<Self, Error> {
        let len = u32::from_le_bytes(bytes[..4].try_into().unwrap())
            .checked_sub(9)
            .ok_or(Error::Length)?;
        let kind = match bytes[4] {
            1 => Kind::Request,
            2 => Kind::Response,
            3 => Kind::Notify,
            4 => Kind::Cancel,
            5 => Kind::Chunk,
            _ => return Err(Error::Kind),
        };
        if len > limit {
            return Err(Error::Limit);
        }
        Ok(Self {
            kind,
            id: u64::from_le_bytes(bytes[5..].try_into().unwrap()),
            len,
        })
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Event<'a> {
    Begin(Header),
    Data(&'a [u8]),
    End,
}

pub struct Decoder {
    header: [u8; 13],
    used: usize,
    remaining: u32,
    limit: u32,
    failed: bool,
}

impl Decoder {
    pub fn new(limit: u32) -> Self {
        Self {
            header: [0; 13],
            used: 0,
            remaining: 0,
            limit,
            failed: false,
        }
    }

    pub fn feed<'a>(
        &mut self,
        mut bytes: &'a [u8],
        mut emit: impl FnMut(Event<'a>),
    ) -> Result<(), Error> {
        if self.failed {
            return Err(Error::Failed);
        }
        while !bytes.is_empty() {
            let consumed = self.next(bytes, &mut emit)?;
            bytes = &bytes[consumed..];
        }
        Ok(())
    }

    /// Consume at most one frame, allowing the caller to reserve response capacity
    /// before publishing its request. Unconsumed bytes remain owned by the caller.
    pub fn next<'a>(
        &mut self,
        mut bytes: &'a [u8],
        mut emit: impl FnMut(Event<'a>),
    ) -> Result<usize, Error> {
        if self.failed {
            return Err(Error::Failed);
        }
        let length = bytes.len();
        while !bytes.is_empty() {
            if self.remaining != 0 {
                let count = bytes.len().min(self.remaining as usize);
                emit(Event::Data(&bytes[..count]));
                self.remaining -= count as u32;
                bytes = &bytes[count..];
                if self.remaining == 0 {
                    emit(Event::End);
                    break;
                }
                continue;
            }
            let count = bytes.len().min(self.header.len() - self.used);
            self.header[self.used..self.used + count].copy_from_slice(&bytes[..count]);
            self.used += count;
            bytes = &bytes[count..];
            if self.used == self.header.len() {
                let header = match Header::decode(&self.header, self.limit) {
                    Ok(header) => header,
                    Err(error) => {
                        self.failed = true;
                        return Err(error);
                    }
                };
                self.used = 0;
                self.remaining = header.len;
                emit(Event::Begin(header));
                if self.remaining == 0 {
                    emit(Event::End);
                    break;
                }
            }
        }
        Ok(length - bytes.len())
    }

    pub fn finish(&self) -> Result<(), Error> {
        if self.failed {
            Err(Error::Failed)
        } else if self.used != 0 || self.remaining != 0 {
            Err(Error::Truncated)
        } else {
            Ok(())
        }
    }
}

pub fn string(output: &mut Vec<u8>, text: &str) {
    output.extend_from_slice(&json::write(&Data::String(text)).unwrap());
}

/// Construct a frame from an in-memory native projection. JSON is never sent.
pub fn frame(kind: Kind, id: u64, value: &[u8]) -> Result<Vec<u8>, Error> {
    if matches!(kind, Kind::Chunk | Kind::Cancel) {
        return packet(kind, id, value);
    }
    if value.len() > LIMIT as usize {
        return Err(Error::Limit);
    }
    let body = body::from_json(value).map_err(|_| Error::Kind)?;
    packet(kind, id, &body)
}

/// Shared byte framing for native protocols and the generated UI body codec.
pub fn packet(kind: Kind, id: u64, body: &[u8]) -> Result<Vec<u8>, Error> {
    let mut bytes = Header {
        kind,
        id,
        len: u32::try_from(body.len()).map_err(|_| Error::Length)?,
    }
    .encode(LIMIT)?
    .to_vec();
    bytes.extend_from_slice(body);
    Ok(bytes)
}

/// Server output always has a response, including a result larger than the source bound.
pub fn reply(kind: Kind, id: u64, body: &[u8]) -> (Kind, Vec<u8>) {
    match frame(kind, id, body) {
        Ok(bytes) => (kind, bytes),
        Err(_) => (
            Kind::Response,
            frame(
                Kind::Response,
                id,
                br#"{"error":{"code":"too_large","message":"Response exceeds frame limit"}}"#,
            )
            .unwrap(),
        ),
    }
}

pub(crate) fn problem(error: &api::Error) -> Vec<u8> {
    let mut body = b"{\"error\":{\"code\":".to_vec();
    string(&mut body, error.code);
    body.extend_from_slice(b",\"message\":");
    string(&mut body, &error.message);
    body.extend_from_slice(b"}}");
    body
}

pub fn error(id: u64, error: &api::Error) -> Vec<u8> {
    reply(Kind::Response, id, &problem(error)).1
}

pub fn result(id: u64, body: &[u8]) -> Result<Vec<u8>, Error> {
    let mut value = b"{\"result\":".to_vec();
    value.extend_from_slice(body);
    value.push(b'}');
    frame(Kind::Response, id, &value)
}

pub fn topology(
    backend: u64,
    nodes: &[api::Node],
    layouts: &[api::Layout],
    key: Option<&str>,
    focus: Option<u64>,
) -> Vec<u8> {
    let nodes = nodes.to_vec();
    let layouts = layouts.to_vec();
    let mut fields: Vec<(&str, &dyn crate::encode::Encode)> = vec![
        ("backend", &backend),
        ("nodes", &nodes),
        ("layouts", &layouts),
        ("focus", &focus),
    ];
    if let Some(ref key) = key {
        fields.push(("key", key));
    }
    crate::encode::notify("topology", &fields)
}
