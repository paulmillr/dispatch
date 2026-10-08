//! helper2 native JSON-RPC envelope, LF framing and original request-id correlation.
use crate::json::{Kind, Value};
use std::collections::BTreeMap;

mod client;
mod reverse;
pub mod transport;
pub mod websocket;
pub use crate::system::queue::{Error as QueueError, Queue};
pub use client::{Call, Client, Incoming, Received, Request};
pub use reverse::{Grown, Line, Reverse};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Shape,
    Limit,
    Incomplete,
    Duplicate,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Id {
    Integer(i64),
    String(String),
}

pub enum Message<'a> {
    Request {
        id: Id,
        method: &'a str,
        params: Option<Value<'a>>,
    },
    Notification {
        method: &'a str,
        params: Option<Value<'a>>,
    },
    Response {
        id: Id,
        result: Result<Value<'a>, Value<'a>>,
    },
}

impl<'a> Message<'a> {
    pub fn read(value: Value<'a>) -> Result<Self, Error> {
        // helper2 json::read::members: unique decoded keys throughout the native
        // envelope, at most16384 keys and64 container levels. Transcript projection
        // intentionally keeps yyjson last-wins; only native RPC validation is strict.
        fn visit(value: Value<'_>, depth: usize, keys: &mut usize) -> Result<(), Error> {
            if !matches!(value.kind(), Kind::Object | Kind::Array) {
                return Ok(());
            }
            if depth > 64 {
                return Err(Error::Limit);
            }
            if let Some(object) = value.object() {
                let mut names = std::collections::BTreeSet::new();
                for (name, child) in object {
                    if *keys == 16384 {
                        return Err(Error::Limit);
                    }
                    *keys += 1;
                    if !names.insert(name) {
                        return Err(Error::Duplicate);
                    }
                    visit(child, depth + 1, keys)?;
                }
            } else if let Some(array) = value.array() {
                for child in array {
                    visit(child, depth + 1, keys)?;
                }
            }
            Ok(())
        }
        visit(value, 1, &mut 0)?;
        if value.kind() != Kind::Object
            || value
                .get("jsonrpc")
                .is_some_and(|v| v.string() != Some("2.0"))
        {
            return Err(Error::Shape);
        }
        let id = value
            .get("id")
            .map(|v| match v.string() {
                Some(s) => Ok(Id::String(s.to_string())),
                None => v.signed().map(Id::Integer).ok_or(Error::Shape),
            })
            .transpose()?;
        if let Some(method) = value.get("method") {
            let method = method.string().ok_or(Error::Shape)?;
            if value.get("result").is_some()
                || value.get("error").is_some()
                || method.trim().is_empty()
                || method.len() > 4096
                || method.chars().any(char::is_control)
            {
                return Err(Error::Shape);
            }
            let params = value.get("params");
            return Ok(match id {
                Some(id) => Self::Request { id, method, params },
                None => Self::Notification { method, params },
            });
        }
        let id = id.ok_or(Error::Shape)?;
        if value.get("params").is_some() {
            return Err(Error::Shape);
        }
        let result = match (value.get("result"), value.get("error")) {
            (Some(result), None) => Ok(result),
            (None, Some(error))
                if error.get("code").and_then(Value::signed).is_some()
                    && error.get("message").and_then(Value::string).is_some() =>
            {
                Err(error)
            }
            _ => return Err(Error::Shape),
        };
        Ok(Self::Response { id, result })
    }
}

/// Correlation only: the native owner sends/receives bytes, and closes on a mismatched id.
/// Removing an item never claims that a request or reply reached the peer.
pub struct Pending<T> {
    items: BTreeMap<Id, T>,
    capacity: usize,
    limit: usize,
    bytes: usize,
}
impl<T> Pending<T> {
    pub fn new(capacity: usize, limit: usize) -> Self {
        Self {
            items: BTreeMap::new(),
            capacity,
            limit,
            bytes: 0,
        }
    }
    pub fn insert(&mut self, id: Id, value: T) -> Result<(), Error> {
        self.try_insert(id, value).map_err(|(error, _)| error)
    }
    /// Return the context on admission failure; native owners must settle it themselves.
    pub fn try_insert(&mut self, id: Id, value: T) -> Result<(), (Error, T)> {
        if self.items.contains_key(&id) {
            return Err((Error::Duplicate, value));
        }
        let bytes = match &id {
            Id::String(s) => s.len(),
            Id::Integer(_) => 0,
        };
        if self.items.len() >= self.capacity || bytes > self.limit.saturating_sub(self.bytes) {
            return Err((Error::Limit, value));
        }
        self.bytes += bytes;
        self.items.insert(id, value);
        Ok(())
    }
    pub fn take(&mut self, id: &Id) -> Result<T, Error> {
        let item = self.items.remove(id).ok_or(Error::Shape)?;
        if let Id::String(s) = id {
            self.bytes -= s.len();
        }
        Ok(item)
    }
    pub fn len(&self) -> usize {
        self.items.len()
    }
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
    pub fn iter(&self) -> impl Iterator<Item = (&Id, &T)> {
        self.items.iter()
    }
    pub fn iter_mut(&mut self) -> impl Iterator<Item = (&Id, &mut T)> {
        self.items.iter_mut()
    }
    pub fn drain(&mut self) -> impl Iterator<Item = (Id, T)> {
        self.bytes = 0;
        std::mem::take(&mut self.items).into_iter()
    }
}

/// Bounded growing native line splitter. LF is removed; CR remains native whitespace.
#[derive(Clone)]
pub struct Lines {
    bytes: Vec<u8>,
    limit: usize,
    error: Option<Error>,
    recover: bool,
    buffer: bool,
    dropping: bool,
    offset: u64,
    position: u64,
}
impl Lines {
    pub fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::new(),
            limit,
            error: None,
            recover: false,
            buffer: false,
            dropping: false,
            offset: 0,
            position: 0,
        }
    }
    /// Native append policy (old HerdrLineBuffer.swift:16-24): bound retained bytes
    /// plus the entire incoming read, including LF. A rejected append changes nothing.
    pub fn buffer(limit: usize) -> Self {
        Self {
            buffer: true,
            ..Self::new(limit)
        }
    }
    /// Transcript policy: discard oversized lines through LF and retain subsequent offsets;
    /// c1654cc TranscriptJSONLFramer.swift:35-53. Strict controls use new() instead.
    pub fn recover(limit: usize) -> Self {
        Self {
            recover: true,
            ..Self::new(limit)
        }
    }
    pub fn position(&self) -> u64 {
        self.position
    }
    pub fn seek(&mut self, offset: u64) {
        self.bytes.clear();
        self.error = None;
        self.dropping = false;
        self.offset = offset;
        self.position = offset;
    }
    /// Encode one raw LF-delimited payload; JSON validation belongs to its producer.
    pub fn encode(mut bytes: Vec<u8>, limit: usize) -> Result<Vec<u8>, Error> {
        if bytes.len() > limit {
            return Err(Error::Limit);
        }
        if bytes.contains(&b'\n') {
            return Err(Error::Shape);
        }
        bytes.push(b'\n');
        Ok(bytes)
    }
    pub fn feed(
        &mut self,
        bytes: &[u8],
        mut emit: impl FnMut(&[u8]) -> Result<(), Error>,
    ) -> Result<(), Error> {
        self.feed_at(bytes, |_, bytes| emit(bytes))
    }
    /// Every complete line, including empty/non-JSON lines; offsets are absolute after seek().
    pub fn feed_at(
        &mut self,
        bytes: &[u8],
        mut emit: impl FnMut(u64, &[u8]) -> Result<(), Error>,
    ) -> Result<(), Error> {
        if let Some(error) = self.error {
            return Err(error);
        }
        if self.buffer && bytes.len() > self.limit.saturating_sub(self.bytes.len()) {
            return Err(Error::Limit);
        }
        for part in bytes.split_inclusive(|byte| *byte == b'\n') {
            let complete = part.last() == Some(&b'\n');
            let part = &part[..part.len() - usize::from(complete)];
            self.position = self
                .position
                .checked_add(part.len() as u64 + u64::from(complete))
                .ok_or(Error::Limit)?;
            if !self.dropping {
                if part.len() > self.limit.saturating_sub(self.bytes.len()) {
                    self.bytes.clear();
                    if !self.recover {
                        self.error = Some(Error::Limit);
                        return Err(Error::Limit);
                    }
                    self.dropping = true;
                } else {
                    self.bytes.extend_from_slice(part);
                }
            }
            if !complete {
                continue;
            }
            if !self.dropping
                && let Err(error) = emit(self.offset, &self.bytes)
            {
                self.error = Some(error);
                return Err(error);
            }
            self.offset = self.position;
            self.dropping = false;
            self.bytes.clear();
        }
        Ok(())
    }
    pub fn finish(&self) -> Result<(), Error> {
        if let Some(error) = self.error {
            return Err(error);
        }
        if self.bytes.is_empty() && !self.dropping {
            Ok(())
        } else {
            Err(Error::Incomplete)
        }
    }
}
