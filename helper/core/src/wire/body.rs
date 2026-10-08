//! Generated-name binary value codec; no JSON bytes occur on the UI wire.
//! All lengths and numbers are little endian. Native JSON remains a provider detail.
use crate::{
    api::Error,
    json::{self, Data, Json, Kind, Value},
};

include!(concat!(env!("OUT_DIR"), "/wire-schema.rs"));

/// Shared binary wire client for native helper tests.
pub const TEST_CLIENT: &str = include_str!(concat!(env!("OUT_DIR"), "/HelperTestClient.py"));

// This is a transport nesting bound, not a provider transcript-parsing bound.
pub const DEPTH: usize = 512;

fn error() -> Error {
    Error {
        code: "protocol",
        message: "Invalid binary message body".into(),
    }
}

fn length(out: &mut Vec<u8>, count: usize) -> Result<(), Error> {
    out.extend_from_slice(&u32::try_from(count).map_err(|_| error())?.to_le_bytes());
    Ok(())
}

fn text(out: &mut Vec<u8>, value: &str) -> Result<(), Error> {
    length(out, value.len())?;
    out.extend_from_slice(value.as_bytes());
    Ok(())
}

fn key(out: &mut Vec<u8>, name: &str) -> Result<(), Error> {
    match SYMBOLS.binary_search(&name) {
        Ok(index) => out.extend_from_slice(&(index as u16).to_le_bytes()),
        Err(_) => {
            out.extend_from_slice(&u16::MAX.to_le_bytes());
            text(out, name)?;
        }
    }
    Ok(())
}

fn value(out: &mut Vec<u8>, item: &Data<'_>, depth: usize) -> Result<(), Error> {
    if depth == 0 {
        return Err(error());
    }
    match item {
        Data::Null => out.push(0),
        Data::Bool(false) => out.push(1),
        Data::Bool(true) => out.push(2),
        Data::Unsigned(v) => {
            out.push(3);
            out.extend_from_slice(&v.to_le_bytes());
        }
        Data::Signed(v) => {
            out.push(4);
            out.extend_from_slice(&v.to_le_bytes());
        }
        Data::Real(v) if v.is_finite() => {
            out.push(5);
            out.extend_from_slice(&v.to_le_bytes());
        }
        Data::Real(_) => return Err(error()),
        Data::String(v) => {
            if let Ok(index) = SYMBOLS.binary_search(v) {
                out.push(9);
                out.extend_from_slice(&(index as u16).to_le_bytes());
            } else {
                out.push(6);
                text(out, v)?;
            }
        }
        Data::Array(items) => {
            out.push(7);
            length(out, items.len())?;
            for item in items {
                value(out, item, depth - 1)?;
            }
        }
        Data::Object(items) => {
            if let Some(index) = RECORDS
                .iter()
                .position(|fields| fields.iter().copied().eq(items.iter().map(|(key, _)| *key)))
            {
                out.push(10);
                out.extend_from_slice(&(index as u16).to_le_bytes());
                for (_, item) in items {
                    value(out, item, depth - 1)?;
                }
                return Ok(());
            }
            out.push(8);
            length(out, items.len())?;
            for (name, item) in items {
                key(out, name)?;
                value(out, item, depth - 1)?;
            }
        }
        Data::Value(item) => native(out, *item, depth)?,
    }
    Ok(())
}

fn native(out: &mut Vec<u8>, item: Value<'_>, depth: usize) -> Result<(), Error> {
    match item.kind() {
        Kind::Null => value(out, &Data::Null, depth),
        Kind::Bool => value(out, &Data::Bool(item.boolean().unwrap()), depth),
        Kind::String => value(out, &Data::String(item.string().unwrap()), depth),
        Kind::Number => {
            let data = if let Some(v) = item.unsigned() {
                Data::Unsigned(v)
            } else if let Some(v) = item.signed() {
                Data::Signed(v)
            } else {
                Data::Real(item.number().unwrap())
            };
            value(out, &data, depth)
        }
        Kind::Array => {
            if depth == 0 {
                return Err(error());
            }
            out.push(7);
            length(out, item.array().unwrap().count())?;
            for item in item.array().unwrap() {
                native(out, item, depth - 1)?;
            }
            Ok(())
        }
        Kind::Object => {
            if depth == 0 {
                return Err(error());
            }
            if let Some(index) = RECORDS.iter().position(|fields| {
                fields
                    .iter()
                    .copied()
                    .eq(item.object().unwrap().map(|(key, _)| key))
            }) {
                out.push(10);
                out.extend_from_slice(&(index as u16).to_le_bytes());
                for (_, item) in item.object().unwrap() {
                    native(out, item, depth - 1)?;
                }
                return Ok(());
            }
            out.push(8);
            length(out, item.object().unwrap().count())?;
            for (name, item) in item.object().unwrap() {
                key(out, name)?;
                native(out, item, depth - 1)?;
            }
            Ok(())
        }
    }
}

/// Write an API value tree directly to binary, including its generated schema ID.
pub fn encode(item: &Data<'_>) -> Result<Vec<u8>, Error> {
    let mut out = SCHEMA.to_vec();
    value(&mut out, item, DEPTH)?;
    Ok(out)
}

/// Native JSON is accepted only in memory, never as a body on the wire.
pub fn from_json(bytes: &[u8]) -> Result<Vec<u8>, Error> {
    encode(&Data::Value(Json::parse(bytes)?.root()))
}

pub struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}
impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], Error> {
        let end = self.at.checked_add(count).ok_or_else(error)?;
        let slice = self.bytes.get(self.at..end).ok_or_else(error)?;
        self.at = end;
        Ok(slice)
    }
    fn count(&mut self) -> Result<usize, Error> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()) as usize)
    }
    fn text(&mut self) -> Result<&'a str, Error> {
        let count = self.count()?;
        std::str::from_utf8(self.take(count)?).map_err(|_| error())
    }
    fn symbol(&mut self) -> Result<u16, Error> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn key(&mut self) -> Result<&'a str, Error> {
        let index = self.symbol()?;
        if index == u16::MAX {
            self.text()
        } else {
            SYMBOLS.get(index as usize).copied().ok_or_else(error)
        }
    }
    fn value(
        &mut self,
        depth: usize,
        key: Option<&'a str>,
        visit: &mut impl FnMut(Option<&'a str>, std::ops::Range<usize>, &Data<'a>) -> Result<(), Error>,
    ) -> Result<Data<'a>, Error> {
        if depth == 0 {
            return Err(error());
        }
        let start = self.at;
        let tag = self.take(1)?[0];
        let data = match tag {
            0 => Data::Null,
            1 => Data::Bool(false),
            2 => Data::Bool(true),
            3 => Data::Unsigned(u64::from_le_bytes(self.take(8)?.try_into().unwrap())),
            4 => Data::Signed(i64::from_le_bytes(self.take(8)?.try_into().unwrap())),
            5 => {
                let number = f64::from_le_bytes(self.take(8)?.try_into().unwrap());
                if !number.is_finite() {
                    return Err(error());
                }
                Data::Real(number)
            }
            6 => Data::String(self.text()?),
            9 => Data::String(
                SYMBOLS
                    .get(self.symbol()? as usize)
                    .copied()
                    .ok_or_else(error)?,
            ),
            10 => {
                let fields = RECORDS
                    .get(self.symbol()? as usize)
                    .copied()
                    .ok_or_else(error)?;
                if fields.len() > self.bytes.len() - self.at {
                    return Err(error());
                }
                Data::Object(
                    fields
                        .iter()
                        .map(|field| Ok((*field, self.value(depth - 1, Some(*field), visit)?)))
                        .collect::<Result<_, Error>>()?,
                )
            }
            tag @ (7 | 8) => {
                let count = self.count()?;
                let width = if tag == 7 { 1 } else { 3 };
                if count > (self.bytes.len() - self.at) / width {
                    return Err(error());
                }
                if tag == 7 {
                    Data::Array(
                        (0..count)
                            .map(|_| self.value(depth - 1, key, visit))
                            .collect::<Result<_, _>>()?,
                    )
                } else {
                    let mut fields = Vec::with_capacity(count);
                    let mut keys = std::collections::BTreeSet::new();
                    for _ in 0..count {
                        let key = self.key()?;
                        if !keys.insert(key) {
                            return Err(crate::dispatch::invalid("request"));
                        }
                        fields.push((key, self.value(depth - 1, Some(key), visit)?));
                    }
                    Data::Object(fields)
                }
            }
            _ => return Err(error()),
        };
        if !matches!(tag, 7 | 8 | 10) {
            visit(key, start..self.at, &data)?;
        }
        Ok(data)
    }
}

/// Preserve the existing provider-independent dispatch API; JSON stays in memory.
pub fn decode(bytes: &[u8]) -> Result<Json, Error> {
    let mut reader = Reader { bytes, at: 0 };
    if reader.take(SCHEMA.len())? != SCHEMA {
        return Err(Error {
            code: "outdated",
            message: "Helper protocol differs; reinstall the helper".into(),
        });
    }
    let data = reader.value(DEPTH, None, &mut |_, _, _| Ok(()))?;
    if reader.at != bytes.len() {
        return Err(error());
    }
    Json::parse(&json::write(&data)?)
}

/// Rewrite decoded scalar values without canonicalizing the recorded representation.
/// Callback JSON must keep each leaf's encoded width/type; keys and structural bytes stay intact.
pub fn rewrite(
    bytes: &[u8],
    mut visit: impl FnMut(Option<&str>, &Data<'_>) -> Result<Vec<u8>, Error>,
) -> Result<Vec<u8>, Error> {
    let mut reader = Reader { bytes, at: 0 };
    if reader.take(SCHEMA.len())? != SCHEMA {
        return Err(error());
    }
    let mut output = bytes.to_vec();
    reader.value(DEPTH, None, &mut |key, range, data| {
        let changed = visit(key, data)?;
        if changed == json::write(data)? {
            return Ok(());
        }
        let document = Json::parse(&changed)?;
        let value = document.root();
        let original = &bytes[range.clone()];
        let mut alias = vec![original[0]];
        match original[0] {
            0..=2 => {
                if json::write(data)? != changed {
                    return Err(error());
                }
            }
            3 => alias.extend_from_slice(&value.unsigned().ok_or_else(error)?.to_le_bytes()),
            4 => alias.extend_from_slice(&value.signed().ok_or_else(error)?.to_le_bytes()),
            5 => alias.extend_from_slice(&value.number().ok_or_else(error)?.to_le_bytes()),
            6 => text(&mut alias, value.string().ok_or_else(error)?)?,
            9 => alias.extend_from_slice(
                &(SYMBOLS
                    .binary_search(&value.string().ok_or_else(error)?)
                    .map_err(|_| error())? as u16)
                    .to_le_bytes(),
            ),
            _ => return Err(error()),
        }
        if alias.len() != original.len() {
            return Err(error());
        }
        output[range].copy_from_slice(&alias);
        Ok(())
    })?;
    if reader.at != bytes.len() {
        return Err(error());
    }
    Ok(output)
}
