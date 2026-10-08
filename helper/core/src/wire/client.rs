//! Blocking test/capture client using the same reader and codec as the helper.
use super::{Header, Kind, Reader, body, packet};
use crate::json::{Data, Json};
use std::{
    collections::{BTreeMap, VecDeque},
    io::{self, Read, Write},
};
pub struct Client<R, W> {
    input: R,
    output: W,
    reader: Reader,
    next: u64,
    pending: VecDeque<(Header, Json)>,
    replies: BTreeMap<u64, Json>,
    pub messages: Vec<(Header, Json)>,
}
impl<R: Read, W: Write> Client<R, W> {
    pub fn new(input: R, output: W) -> Self {
        Self {
            input,
            output,
            reader: Reader::default(),
            next: 0,
            pending: VecDeque::new(),
            replies: BTreeMap::new(),
            messages: Vec::new(),
        }
    }
    pub fn into_parts(self) -> (R, W) {
        (self.input, self.output)
    }
    pub fn request(&mut self, method: &str, params: Data<'_>) -> io::Result<u64> {
        self.next += 1;
        let body = body::encode(&Data::Object(vec![
            ("method", Data::String(method)),
            ("params", params),
        ]))
        .map_err(|error| io::Error::other(error.message))?;
        self.output.write_all(
            &packet(Kind::Request, self.next, &body)
                .map_err(|error| io::Error::other(format!("{error:?}")))?,
        )?;
        self.output.flush()?;
        Ok(self.next)
    }
    pub fn read(&mut self) -> io::Result<Option<(Header, Json)>> {
        loop {
            if let Some((header, value)) = self.pending.pop_front() {
                let copied = Json::parse(
                    &value
                        .root()
                        .write()
                        .map_err(|error| io::Error::other(error.message))?,
                )
                .map_err(|error| io::Error::other(error.message))?;
                self.messages.push((header, copied));
                return Ok(Some((header, value)));
            }
            let mut bytes = [0; 4096];
            let count = self.input.read(&mut bytes)?;
            if count == 0 {
                self.reader.finish()?;
                return Ok(None);
            }
            self.pending.extend(self.reader.push(&bytes[..count])?);
        }
    }
    pub fn response(&mut self, id: u64) -> io::Result<Json> {
        loop {
            if let Some(value) = self.replies.remove(&id) {
                return Ok(value);
            }
            let (header, value) = self
                .read()?
                .ok_or_else(|| io::Error::from(io::ErrorKind::UnexpectedEof))?;
            if header.kind == Kind::Response && self.replies.insert(header.id, value).is_some() {
                return Err(io::Error::other("duplicate unconsumed response"));
            }
        }
    }
}
