//! Generated-name binary value codec; no JSON bytes occur on the UI wire.
//! All lengths and numbers are little endian. Native JSON remains a provider detail.
use crate::{
    api::Error,
    json::{Data, Kind, Value},
};

include!(concat!(env!("OUT_DIR"), "/wire-schema.rs"));

// This is a transport nesting bound, not a provider transcript-parsing bound.
pub const DEPTH: usize = 512;
/// Values one wire body may hold. The frame limit is sized for TEXT_LIMIT bytes of text as JSON (six-byte escapes),
/// but a binary null is one byte: a peer's frame would otherwise be millions of values, each a Data in memory. Plain
/// values (captures, job output, values made here) are not counted.
const VALUES: usize = super::TEXT_LIMIT as usize;

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

/// Names the wire abbreviates (the generated schema); captures use none, so they do not depend on it.
#[derive(Clone, Copy)]
struct Dictionary {
    symbols: &'static [&'static str],
    records: &'static [&'static [&'static str]],
}
const WIRE: Dictionary = Dictionary {
    symbols: SYMBOLS,
    records: RECORDS,
};
const PLAIN: Dictionary = Dictionary {
    symbols: &[],
    records: &[],
};

fn key(out: &mut Vec<u8>, name: &str, names: Dictionary) -> Result<(), Error> {
    match names.symbols.binary_search(&name) {
        Ok(index) => out.extend_from_slice(&(index as u16).to_le_bytes()),
        Err(_) => {
            out.extend_from_slice(&u16::MAX.to_le_bytes());
            text(out, name)?;
        }
    }
    Ok(())
}

fn value(out: &mut Vec<u8>, item: &Data<'_>, depth: usize, names: Dictionary) -> Result<(), Error> {
    if depth == 0 {
        return Err(error());
    }
    match item {
        Data::Null => out.push(0),
        Data::Bool(false) => out.push(1),
        Data::Bool(true) => out.push(2),
        // One form per integer, as the JSON projection always had: non-negative is unsigned.
        Data::Unsigned(v) => {
            out.push(3);
            out.extend_from_slice(&v.to_le_bytes());
        }
        Data::Signed(v) if *v >= 0 => value(out, &Data::Unsigned(*v as u64), depth, names)?,
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
            if let Ok(index) = names.symbols.binary_search(v) {
                out.push(9);
                out.extend_from_slice(&(index as u16).to_le_bytes());
            } else {
                out.push(6);
                text(out, v)?;
            }
        }
        Data::Bytes(v) => {
            out.push(11);
            length(out, v.len())?;
            out.extend_from_slice(v);
        }
        Data::Array(items) => {
            out.push(7);
            length(out, items.len())?;
            for item in items {
                value(out, item, depth - 1, names)?;
            }
        }
        Data::Object(items) => {
            if let Some(index) = names
                .records
                .iter()
                .position(|fields| fields.iter().copied().eq(items.iter().map(|(key, _)| *key)))
            {
                out.push(10);
                out.extend_from_slice(&(index as u16).to_le_bytes());
                for (_, item) in items {
                    value(out, item, depth - 1, names)?;
                }
                return Ok(());
            }
            out.push(8);
            length(out, items.len())?;
            for (name, item) in items {
                key(out, name, names)?;
                value(out, item, depth - 1, names)?;
            }
        }
        Data::Value(item) => native(out, *item, depth, names)?,
    }
    Ok(())
}

fn native(out: &mut Vec<u8>, item: Value<'_>, depth: usize, names: Dictionary) -> Result<(), Error> {
    match item.kind() {
        Kind::Null => value(out, &Data::Null, depth, names),
        Kind::Bool => value(out, &Data::Bool(item.boolean().unwrap()), depth, names),
        Kind::String => value(out, &Data::String(item.string().unwrap()), depth, names),
        Kind::Number => {
            let data = if let Some(v) = item.unsigned() {
                Data::Unsigned(v)
            } else if let Some(v) = item.signed() {
                Data::Signed(v)
            } else {
                Data::Real(item.number().unwrap())
            };
            value(out, &data, depth, names)
        }
        Kind::Array => {
            if depth == 0 {
                return Err(error());
            }
            out.push(7);
            length(out, item.array().unwrap().count())?;
            for item in item.array().unwrap() {
                native(out, item, depth - 1, names)?;
            }
            Ok(())
        }
        Kind::Object => {
            if depth == 0 {
                return Err(error());
            }
            if let Some(index) = names.records.iter().position(|fields| {
                fields
                    .iter()
                    .copied()
                    .eq(item.object().unwrap().map(|(key, _)| key))
            }) {
                out.push(10);
                out.extend_from_slice(&(index as u16).to_le_bytes());
                for (_, item) in item.object().unwrap() {
                    native(out, item, depth - 1, names)?;
                }
                return Ok(());
            }
            out.push(8);
            length(out, item.object().unwrap().count())?;
            for (name, item) in item.object().unwrap() {
                key(out, name, names)?;
                native(out, item, depth - 1, names)?;
            }
            Ok(())
        }
    }
}

/// One value in the wire grammar without the schema prefix (core's typed encoder, encode.rs).
pub(crate) fn put(out: &mut Vec<u8>, item: &Data<'_>) -> Result<(), Error> {
    value(out, item, DEPTH, WIRE)
}

/// An array header; the caller appends `count` values.
pub(crate) fn array(out: &mut Vec<u8>, count: usize) {
    out.push(7);
    length(out, count).expect("bounded array");
}

/// An object header for these keys: a schema record (only values follow; false) or a keyed
/// object (true: the caller writes each key with `name` before its value).
pub(crate) fn object<'a>(out: &mut Vec<u8>, keys: impl Iterator<Item = &'a str> + Clone, count: usize) -> bool {
    if let Some(index) = RECORDS.iter().position(|fields| fields.iter().copied().eq(keys.clone())) {
        out.push(10);
        out.extend_from_slice(&(index as u16).to_le_bytes());
        return false;
    }
    out.push(8);
    length(out, count).expect("bounded object");
    true
}

pub(crate) fn name(out: &mut Vec<u8>, name: &str) {
    key(out, name, WIRE).expect("bounded key");
}

/// The method of an encoded `{method, params}` body (notifications), without decoding the rest.
pub(crate) fn method(bytes: &[u8]) -> Option<&str> {
    let mut reader = Reader {
        bytes,
        at: 0,
        names: WIRE,
        values: VALUES,
    };
    let named = match reader.take(1).ok()?[0] {
        10 => *RECORDS.get(reader.symbol().ok()? as usize)?.first()? != "method",
        8 => reader.count().ok()? == 0 || reader.key().ok()? != "method",
        _ => true,
    };
    if named {
        return None;
    }
    match reader.value(DEPTH).ok()? {
        Data::String(method) => Some(method),
        _ => None,
    }
}

/// Write an API value tree directly to binary, including its generated schema ID.
pub fn encode(item: &Data<'_>) -> Result<Vec<u8>, Error> {
    let mut out = SCHEMA.to_vec();
    value(&mut out, item, DEPTH, WIRE)?;
    Ok(out)
}

/// The same grammar without the schema's names (captures): readable by any helper version.
pub fn encode_plain(item: &Data<'_>) -> Result<Vec<u8>, Error> {
    let mut out = Vec::new();
    value(&mut out, item, DEPTH, PLAIN)?;
    Ok(out)
}

/// Checked binary value bytes, owned: a plain value or a wire body (with the schema's names). A
/// request whose handler finishes later keeps the frame it came in and reads it again through `root`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Encoded {
    bytes: Vec<u8>,
    wire: bool,
}
impl Encoded {
    /// A value tree made here (e.g. what the helper derived from an agent's JSON), checked as `plain` is: agent JSON
    /// can repeat a key, which the reader refuses.
    pub fn value(data: &Data<'_>) -> Result<Self, Error> {
        Self::plain(&encode_plain(data)?)
    }
    pub fn plain(bytes: &[u8]) -> Result<Self, Error> {
        decode_plain(bytes)?;
        Ok(Self { bytes: bytes.to_vec(), wire: false })
    }
    pub fn wire(bytes: Vec<u8>) -> Result<Self, Error> {
        decode(&bytes)?;
        Ok(Self { bytes, wire: true })
    }
    pub fn root(&self) -> Data<'_> {
        if self.wire { decode(&self.bytes) } else { decode_plain(&self.bytes) }.expect("checked when made")
    }
}

/// A value written by encode_plain; borrows its strings and bytes.
pub fn decode_plain(bytes: &[u8]) -> Result<Data<'_>, Error> {
    let mut reader = Reader {
        bytes,
        at: 0,
        names: PLAIN,
        values: usize::MAX,
    };
    let data = reader.value(DEPTH)?;
    if reader.at != bytes.len() {
        return Err(error());
    }
    Ok(data)
}

pub struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
    names: Dictionary,
    /// Values this body may still hold (VALUES).
    values: usize,
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
            self.names.symbols.get(index as usize).copied().ok_or_else(error)
        }
    }
    fn value(&mut self, depth: usize) -> Result<Data<'a>, Error> {
        if depth == 0 || self.values == 0 {
            return Err(error());
        }
        self.values -= 1;
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
            11 => {
                let count = self.count()?;
                Data::Bytes(self.take(count)?)
            }
            9 => Data::String(
                self.names
                    .symbols
                    .get(self.symbol()? as usize)
                    .copied()
                    .ok_or_else(error)?,
            ),
            10 => {
                let fields = self
                    .names
                    .records
                    .get(self.symbol()? as usize)
                    .copied()
                    .ok_or_else(error)?;
                if fields.len() > self.bytes.len() - self.at {
                    return Err(error());
                }
                Data::Object(
                    fields
                        .iter()
                        .map(|field| Ok((*field, self.value(depth - 1)?)))
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
                            .map(|_| self.value(depth - 1))
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
                        fields.push((key, self.value(depth - 1)?));
                    }
                    Data::Object(fields)
                }
            }
            _ => return Err(error()),
        };
        Ok(data)
    }
}

/// A wire body (schema-checked); borrows its strings and bytes.
pub fn decode(bytes: &[u8]) -> Result<Data<'_>, Error> {
    let mut reader = Reader {
        bytes,
        at: 0,
        names: WIRE,
        values: VALUES,
    };
    if reader.take(SCHEMA.len())? != SCHEMA {
        return Err(Error {
            code: "outdated",
            message: "Helper protocol differs; reinstall the helper".into(),
        });
    }
    let data = reader.value(DEPTH)?;
    if reader.at != bytes.len() {
        return Err(error());
    }
    Ok(data)
}

/// Another schema's names (an older helper's, from the corpus's dictionaries): what its wire bodies abbreviate.
pub struct Names {
    pub schema: [u8; 8],
    pub symbols: &'static [&'static str],
    pub records: &'static [&'static [&'static str]],
}

/// A wire body of the schema `names` describes (capture convert); borrows its strings and bytes.
pub fn decode_as<'a>(bytes: &'a [u8], names: &Names) -> Result<Data<'a>, Error> {
    let mut reader = Reader {
        bytes,
        at: 0,
        names: Dictionary {
            symbols: names.symbols,
            records: names.records,
        },
        values: VALUES,
    };
    if reader.take(names.schema.len())? != names.schema {
        return Err(error());
    }
    let data = reader.value(DEPTH)?;
    if reader.at != bytes.len() {
        return Err(error());
    }
    Ok(data)
}

#[cfg(test)]
#[path = "body.test.rs"]
mod tests;
