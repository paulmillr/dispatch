//! Encode decoded capture rows with this build's codec; retain recorded stream boundaries.
use crate::{
    json::{self, Data, Json},
    wire::{self, Kind},
};
use std::{collections::BTreeMap, io};
fn error(message: impl ToString) -> io::Error {
    io::Error::other(message.to_string())
}
fn encode(frames: crate::json::Value<'_>) -> io::Result<Vec<Vec<u8>>> {
    let frames: Vec<_> = frames
        .array()
        .ok_or_else(|| error("captured frames must be an array"))?
        .collect();
    let mut streams = BTreeMap::new();
    for frame in &frames {
        if let Some(value) = frame.get("stream_value") {
            streams.insert(
                frame.get("id").unwrap().unsigned().unwrap(),
                wire::body::encode(&Data::Value(value)).map_err(|e| error(e.message))?,
            );
        }
    }
    frames
        .iter()
        .map(|frame| {
            let id = frame.get("id").unwrap().unsigned().unwrap();
            let kind = match frame.get("kind").unwrap().unsigned().unwrap() {
                1 => Kind::Request,
                2 => Kind::Response,
                3 => Kind::Notify,
                4 => Kind::Cancel,
                5 => Kind::Chunk,
                _ => return Err(error("captured frame kind")),
            };
            let body = if kind == Kind::Chunk {
                if let Some(sequence) = frame.get("sequence").and_then(|v| v.unsigned()) {
                    let payload = &streams[&id];
                    let start = sequence as usize * wire::CHUNK;
                    let end = (start + wire::CHUNK).min(payload.len());
                    if start >= end {
                        return Err(error("codec changed the captured chunk count"));
                    }
                    let mut body = sequence.to_le_bytes().to_vec();
                    body.extend_from_slice(&payload[start..end]);
                    body
                } else {
                    super::super::capture::unhex(frame.get("data").unwrap().string().unwrap())?
                }
            } else if kind == Kind::Cancel {
                Vec::new()
            } else {
                let value = frame.get("value").unwrap();
                if let Some(payload) = streams.get(&id) {
                    let stream = value.get("stream").unwrap();
                    if stream.get("chunks").unwrap().unsigned().unwrap()
                        != payload.len().div_ceil(wire::CHUNK) as u64
                    {
                        return Err(error("codec changed the captured chunk count"));
                    }
                    let revised = json::write(&Data::Object(
                        stream
                            .object()
                            .unwrap()
                            .map(|(key, value)| {
                                (
                                    key,
                                    if key == "bytes" {
                                        Data::Unsigned(payload.len() as u64)
                                    } else {
                                        Data::Value(value)
                                    },
                                )
                            })
                            .collect(),
                    ))
                    .map_err(|e| error(e.message))?;
                    let revised = Json::parse(&revised).map_err(|e| error(e.message))?;
                    wire::body::encode(&Data::Object(
                        value
                            .object()
                            .unwrap()
                            .map(|(key, value)| {
                                (
                                    key,
                                    if key == "stream" {
                                        Data::Value(revised.root())
                                    } else {
                                        Data::Value(value)
                                    },
                                )
                            })
                            .collect(),
                    ))
                    .map_err(|e| error(e.message))?
                } else {
                    wire::body::encode(&Data::Value(value)).map_err(|e| error(e.message))?
                }
            };
            wire::packet(kind, id, &body).map_err(|e| error(format!("{e:?}")))
        })
        .collect()
}
pub fn read(source: &str) -> io::Result<Vec<u8>> {
    let rows: Vec<_> = source
        .lines()
        .map(|line| Json::parse(line.as_bytes()).map_err(|e| error(e.message)))
        .collect::<Result<_, _>>()?;
    let mut streams: BTreeMap<(String, String), Vec<usize>> = BTreeMap::new();
    for (index, row) in rows.iter().enumerate() {
        let value = row.root();
        if value.get("wire_end").is_some() {
            let op = value.get("op").unwrap().string().unwrap();
            let fd = value
                .get("args")
                .unwrap()
                .string()
                .unwrap()
                .split_once(' ')
                .unwrap()
                .0;
            streams
                .entry((op.to_owned(), fd.to_owned()))
                .or_default()
                .push(index);
        }
    }
    let mut replacements = BTreeMap::new();
    for ((op, fd), indices) in streams {
        let frames = rows[indices[0]].root().get("wire").unwrap();
        let lengths: Vec<_> = frames
            .array()
            .unwrap()
            .map(|frame| frame.get("length").unwrap().unsigned().unwrap() as usize)
            .collect();
        let packets = encode(frames)?;
        let bytes: Vec<_> = packets.iter().flatten().copied().collect();
        let mut offset = 0;
        for index in indices {
            let row = rows[index].root();
            let boundary = row.get("wire_end").unwrap().unsigned().unwrap() as usize;
            let mut old = 0;
            let mut end = 0;
            for (length, packet) in lengths.iter().zip(&packets) {
                if boundary <= old + length {
                    end += (boundary - old) * packet.len() / length;
                    break;
                }
                old += length;
                end += packet.len();
            }
            if offset > end || end > bytes.len() {
                return Err(error("invalid captured wire boundary"));
            }
            let completion = Json::parse(&super::super::capture::unhex(
                row.get("data").unwrap().string().unwrap(),
            )?)
            .map_err(|e| error(e.message))?;
            let hex = super::super::capture::hex(&bytes[offset..end]);
            let output = completion.root().get("output").unwrap();
            let revised = Json::parse(
                &json::write(&Data::Object(
                    output
                        .object()
                        .unwrap()
                        .map(|(key, value)| {
                            (
                                key,
                                if key == "bytes" {
                                    Data::String(&hex)
                                } else {
                                    Data::Value(value)
                                },
                            )
                        })
                        .collect(),
                ))
                .map_err(|e| error(e.message))?,
            )
            .map_err(|e| error(e.message))?;
            let data = super::super::capture::hex(
                &json::write(&Data::Object(
                    completion
                        .root()
                        .object()
                        .unwrap()
                        .map(|(key, value)| {
                            (
                                key,
                                if key == "output" {
                                    Data::Value(revised.root())
                                } else {
                                    Data::Value(value)
                                },
                            )
                        })
                        .collect(),
                ))
                .map_err(|e| error(e.message))?,
            );
            let args = if op == "write" {
                let attempted: usize = row
                    .get("args")
                    .unwrap()
                    .string()
                    .unwrap()
                    .split_once("len=")
                    .unwrap()
                    .1
                    .parse()
                    .map_err(error)?;
                format!("{fd} len={}", attempted.max(end - offset))
            } else {
                row.get("args").unwrap().string().unwrap().to_owned()
            };
            replacements.insert(index, (data, args));
            offset = end;
        }
        if offset != bytes.len() {
            return Err(error("captured stream was not fully consumed"));
        }
    }
    let mut output = Vec::new();
    for (index, row) in rows.iter().enumerate() {
        let fields = row
            .root()
            .object()
            .unwrap()
            .filter(|(key, _)| !matches!(*key, "wire" | "wire_end"))
            .map(|(key, value)| {
                (
                    key,
                    match replacements.get(&index) {
                        Some((data, _)) if key == "data" => Data::String(data),
                        Some((_, args)) if key == "args" => Data::String(args),
                        _ => Data::Value(value),
                    },
                )
            })
            .collect();
        output.extend(json::write(&Data::Object(fields)).map_err(|e| error(e.message))?);
        output.push(b'\n');
    }
    Ok(output)
}
