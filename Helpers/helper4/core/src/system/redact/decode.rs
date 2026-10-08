//! Read System capture facts and UI messages with this build's production codec.
use super::{capture, file};
use crate::{
    json::{self, Data, Json},
    wire::{self, Header, Reader},
};
use std::{
    collections::BTreeMap,
    io::{self, BufRead, Write},
};

/// JSONL output has seconds since System capture start; messages are assembled across IO chunks.
/// The binary schema is checked by wire::body, never read from an external table or VERSION file.
pub fn read(input: impl BufRead, output: &mut impl Write) -> io::Result<usize> {
    let mut streams: BTreeMap<(String, String), Reader> = BTreeMap::new();
    let mut messages = 0;
    for (index, line) in input.lines().enumerate() {
        let line = line?;
        if line.len() > wire::LIMIT as usize * 8 {
            return Err(io::Error::other("capture row exceeds decode budget"));
        }
        let record =
            Json::parse(line.as_bytes()).map_err(|error| io::Error::other(error.message))?;
        let row = record.root();
        if row.get("invalid").is_some() {
            return Err(io::Error::other("invalid System capture"));
        }
        let text = |name| {
            row.get(name)
                .and_then(|v| v.string())
                .ok_or_else(file::invalid)
        };
        let section = text("section")?;
        let op = text("op")?;
        let args = text("args")?;
        let seconds = row
            .get("clock")
            .and_then(|v| v.number())
            .ok_or_else(file::invalid)?
            / 1_000_000_000.0;
        let bytes = capture::unhex(text("data")?)?;
        let result = Json::parse(&bytes).map_err(|error| io::Error::other(error.message))?;
        let mut emit = |header: Option<Header>, value: &Json| -> io::Result<()> {
            let mut fields = vec![
                ("line", Data::Unsigned(index as u64 + 1)),
                ("seconds", Data::Real(seconds)),
                ("section", Data::String(section)),
                ("op", Data::String(op)),
                ("args", Data::String(args)),
                ("value", Data::Value(value.root())),
            ];
            if let Some(header) = header {
                fields.extend([
                    ("kind", Data::Unsigned(header.kind as u64)),
                    ("id", Data::Unsigned(header.id)),
                ]);
            }
            output.write_all(
                &json::write(&Data::Object(fields))
                    .map_err(|error| io::Error::other(error.message))?,
            )?;
            output.write_all(b"\n")
        };
        if section == "ui"
            && matches!(op, "read" | "write")
            && row
                .get("error")
                .is_none_or(|v| v.kind() == json::Kind::Null)
        {
            let Some(data) = result
                .root()
                .get("output")
                .and_then(|v| v.get("bytes"))
                .and_then(|v| v.string())
            else {
                emit(None, &result)?;
                continue;
            };
            let fd = args.split_whitespace().next().ok_or_else(file::invalid)?;
            let stream = streams.entry((op.to_owned(), fd.to_owned())).or_default();
            for (header, value) in stream.push(&capture::unhex(&data)?)? {
                emit(Some(header), &value)?;
                messages += 1;
            }
        } else {
            emit(None, &result)?;
        }
    }
    for stream in streams.values() {
        stream.finish()?;
    }
    output.flush()?;
    Ok(messages)
}
