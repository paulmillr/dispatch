//! JSON reader/writer with yyjson 0.12 behaviour (strict reading, compact and Foundation-style
//! pretty writing), in Rust with SIMD. The parsed document owns a copy of its input.
mod number;
mod read;
mod simd;
mod write;
use crate::api::Error;

/// A parsed document: nodes in document order, strings inside the padded input copy.
pub struct Json {
    nodes: Vec<Node>,
    text: Box<[u8]>,
}

/// tag: kind (bits 0..3), number subtype (bits 3..5), KEY (bit 6), NOESC (bit 7), length (bits 8..: string bytes, array
/// items, object members). data: number bits, string address in `text`, or for containers
/// the node count up to the next sibling.
/// Tag bit of object keys, so writers know the separator from the node alone.
const KEY: u64 = 1 << 6;
/// Tag bit of parsed strings that had no escapes: valid JSON cannot hold '"', '\\' or
/// control bytes raw, so writers copy these without looking for bytes to escape.
const NOESC: u64 = 1 << 7;

#[derive(Clone, Copy, Debug)]
struct Node {
    tag: u64,
    data: u64,
}

#[derive(Clone, Copy, Debug)]
pub struct Value<'a> {
    node: &'a Node,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Null,
    Bool,
    Number,
    String,
    Array,
    Object,
}

/// Reading rules at the caller's native JSON boundary.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Policy {
    Strict,
    /// JSONSerialization accepts trailing commas and at most 512 nested containers.
    Foundation,
}

/// Optional fields decoded by Foundation's keyed/array decoder. Unselected values are
/// structurally scanned; undecodable selected scalars and shape mismatches become null.
#[derive(Clone, Copy)]
pub enum Select<'a> {
    Scalar,
    Object(&'a [(&'a str, Select<'a>)]),
    Array(&'a Select<'a>),
}

/// Compact matches yyjson's output; pretty modes match the old Foundation writer, except that
/// lines nested deeper than 16 levels keep the 16th level's indentation (linear output size).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Format {
    #[default]
    Compact,
    /// Transcript display escapes slashes (c1654cc TranscriptReader.swift:203-207).
    PrettySorted,
    /// Hook configuration keeps slashes (c1654cc CodexHookSetup.swift:106-111).
    PrettySortedUnescaped,
}

/// A typed tree for writing, or a parsed value written as is.
pub enum Data<'a> {
    Null,
    Bool(bool),
    Unsigned(u64),
    Signed(i64),
    Real(f64),
    String(&'a str),
    Array(Vec<Data<'a>>),
    Object(Vec<(&'a str, Data<'a>)>),
    Value(Value<'a>),
}

impl Json {
    /// Strict UTF-8 JSON; LF-delimited callers pass one complete native line.
    pub fn parse(bytes: &[u8]) -> Result<Self, Error> {
        Self::parse_with(bytes, Policy::Strict)
    }
    /// Parse using the validation policy of the caller's native JSON boundary.
    pub fn parse_with(bytes: &[u8], policy: Policy) -> Result<Self, Error> {
        read::read(bytes, policy).map_err(error)
    }
    /// Foundation JSONDecoder projection; keyed objects keep the first decoded duplicate.
    pub fn decode(bytes: &[u8], select: &Select<'_>) -> Result<Self, Error> {
        read::decode(bytes, select).map_err(error)
    }
    pub fn root(&self) -> Value<'_> {
        Value {
            node: &self.nodes[0],
        }
    }
}

impl<'a> Value<'a> {
    pub fn kind(self) -> Kind {
        [
            Kind::Null,
            Kind::Bool,
            Kind::Number,
            Kind::String,
            Kind::Array,
            Kind::Object,
        ][(self.node.tag & 7) as usize]
    }
    fn subtype(self) -> Option<u64> {
        (self.kind() == Kind::Number).then_some(self.node.tag >> 3 & 3)
    }
    fn len(self) -> usize {
        (self.node.tag >> 8) as usize
    }
    fn bytes(self) -> &'a [u8] {
        // SAFETY: string nodes hold the address and length of bytes inside the document's
        // text, which lives (and never moves) as long as the node.
        unsafe { std::slice::from_raw_parts(self.node.data as *const u8, self.len()) }
    }
    /// The node after this value's subtree: next sibling, or end of the parent.
    fn next(self) -> Value<'a> {
        // SAFETY: only called on values followed by a sibling in the same document.
        Value {
            node: unsafe { &*(self.node as *const Node).add(self.subtree().len()) },
        }
    }
    /// This value's nodes: itself and, for containers, everything inside.
    fn subtree(self) -> &'a [Node] {
        let size = if self.node.tag & 7 >= Kind::Array as u64 {
            self.node.data as usize
        } else {
            1
        };
        // SAFETY: a value's subtree is `size` consecutive nodes of its document.
        unsafe { std::slice::from_raw_parts(self.node, size) }
    }
    /// First child of a non-empty container.
    fn next_child(self) -> Value<'a> {
        // SAFETY: only called on containers with children, which follow immediately.
        Value {
            node: unsafe { &*(self.node as *const Node).add(1) },
        }
    }
    pub fn string(self) -> Option<&'a str> {
        // SAFETY: the reader accepted only valid UTF-8 strings.
        (self.kind() == Kind::String)
            .then(|| unsafe { std::str::from_utf8_unchecked(self.bytes()) })
    }
    pub fn boolean(self) -> Option<bool> {
        (self.kind() == Kind::Bool).then_some(self.node.data != 0)
    }
    pub fn unsigned(self) -> Option<u64> {
        let data = self.node.data;
        match self.subtype()? {
            number::UNSIGNED => Some(data),
            number::SIGNED => (data as i64 >= 0).then_some(data),
            _ => None,
        }
    }
    pub fn signed(self) -> Option<i64> {
        let data = self.node.data;
        match self.subtype()? {
            number::SIGNED => Some(data as i64),
            number::UNSIGNED => (data <= i64::MAX as u64).then_some(data as i64),
            _ => None,
        }
    }
    pub fn number(self) -> Option<f64> {
        let data = self.node.data;
        Some(match self.subtype()? {
            number::UNSIGNED => data as f64,
            number::SIGNED => data as i64 as f64,
            _ => f64::from_bits(data),
        })
    }
    pub fn array(self) -> Option<impl Iterator<Item = Value<'a>>> {
        (self.kind() == Kind::Array).then(|| self.values(self.len()))
    }
    pub fn object(self) -> Option<impl Iterator<Item = (&'a str, Value<'a>)>> {
        (self.kind() == Kind::Object).then(|| {
            let mut pairs = self.values(self.len() * 2);
            std::iter::from_fn(move || Some((pairs.next()?.string().unwrap(), pairs.next()?)))
        })
    }
    /// Last decoded match, preserving Foundation's native projection policy.
    /// Config/hook policy can reject duplicates through object() instead.
    pub fn get(self, name: &str) -> Option<Value<'a>> {
        self.object()?
            .filter(|(key, _)| *key == name)
            .map(|(_, value)| value)
            .last()
    }
    fn values(self, count: usize) -> impl Iterator<Item = Value<'a>> {
        let mut next = self;
        (0..count).map(move |i| {
            next = if i == 0 {
                next.next_child()
            } else {
                next.next()
            };
            next
        })
    }
    pub fn write(self) -> Result<Vec<u8>, Error> {
        self.write_with(Format::Compact)
    }
    pub fn write_with(self, format: Format) -> Result<Vec<u8>, Error> {
        write::write(write::Item::Value(self), format)
    }
}

fn error((code, at): (u32, usize)) -> Error {
    Error {
        code: "json",
        message: format!("JSON error {code} at byte {at}"),
    }
}

fn failure() -> Error {
    Error {
        code: "json",
        message: "JSON allocation or writing failed".into(),
    }
}

pub fn write(value: &Data<'_>) -> Result<Vec<u8>, Error> {
    write_with(value, Format::Compact)
}

pub fn write_with(value: &Data<'_>, format: Format) -> Result<Vec<u8>, Error> {
    write::write(write::Item::Data(value), format)
}
