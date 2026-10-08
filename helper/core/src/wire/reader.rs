//! Shared message reader for capture tools and Rust test clients.
use super::{self as wire, Collector, Header, Kind, Received};
use crate::json::{self, Data, Json};
use std::{collections::BTreeMap, io};
#[derive(Default)]
pub struct Reader {
    bytes: Vec<u8>,
    collectors: BTreeMap<u64, Collector>,
}
impl Reader {
    pub fn push(&mut self, bytes: &[u8]) -> io::Result<Vec<(Header, Json)>> {
        self.bytes.extend_from_slice(bytes);
        if self.bytes.len() > wire::LIMIT as usize * 8 {
            return Err(io::Error::other("capture stream exceeds decode budget"));
        }
        let mut messages = Vec::new();
        let mut at = 0;
        for _ in 0..self.bytes.len() {
            if self.bytes.len() - at < 13 {
                break;
            }
            let header = Header::decode(self.bytes[at..at + 13].try_into().unwrap(), wire::LIMIT)
                .map_err(|_| io::Error::other("invalid captured frame"))?;
            let end = at + 13 + header.len as usize;
            if end > self.bytes.len() {
                break;
            }
            let body = &self.bytes[at + 13..end];
            let decoded = match header.kind {
                Kind::Request => Some(
                    wire::body::decode(body).map_err(|error| io::Error::other(error.message))?,
                ),
                Kind::Cancel if body.is_empty() => {
                    Some(Json::parse(b"null").map_err(|error| io::Error::other(error.message))?)
                }
                Kind::Cancel => return Err(io::Error::other("invalid captured frame")),
                Kind::Response | Kind::Notify | Kind::Chunk => {
                    let collector = self
                        .collectors
                        .entry(header.id)
                        .or_insert_with(|| Collector::new(header.id, wire::LIMIT as usize * 8));
                    let result = collector
                        .push(header, body)
                        .map_err(|e| io::Error::other(format!("invalid capture stream: {e:?}")))?;
                    match result {
                        Some(Received::Json(bytes)) => {
                            self.collectors.remove(&header.id);
                            Some(
                                Json::parse(&bytes)
                                    .map_err(|error| io::Error::other(error.message))?,
                            )
                        }
                        Some(Received::Binary { bytes, metadata }) => {
                            self.collectors.remove(&header.id);
                            let text = crate::base64::encode(&bytes);
                            Some(
                                Json::parse(
                                    &json::write(&Data::Object(vec![
                                        ("result", Data::Value(metadata.root())),
                                        ("bytes", Data::String(&text)),
                                    ]))
                                    .map_err(|error| io::Error::other(error.message))?,
                                )
                                .map_err(|error| io::Error::other(error.message))?,
                            )
                        }
                        None => None,
                    }
                }
            };
            if let Some(decoded) = decoded {
                messages.push((header, decoded));
            }
            at = end;
        }
        self.bytes.drain(..at);
        Ok(messages)
    }
    pub fn finish(&self) -> io::Result<()> {
        if !self.bytes.is_empty() || !self.collectors.is_empty() {
            return Err(io::Error::other("incomplete captured UI message"));
        }
        Ok(())
    }
}
