//! One writer for parsed values and caller-built trees: yyjson's compact bytes and escapes,
//! and the Foundation pretty layout core has always produced, indented at most INDENT levels.
//! Everything is written from a node sequence in document order: a parsed value in compact
//! form is its own subtree (no copy); caller trees and pretty (key-sorted) output are first
//! laid out as nodes. Both steps are iterative, so any depth writes without stack growth.
use super::{Data, Error, Format, KEY, Kind, NOESC, Node, Value, failure, number, simd::Lanes};
use std::marker::PhantomData;

#[derive(Clone, Copy)]
pub(super) enum Item<'a, 'b> {
    Data(&'b Data<'a>),
    Value(Value<'a>),
}

/// Tag bit for string bytes that are not inside a padded document (caller strings).
const UNPADDED: u64 = 1 << 5;
/// Output bytes reserved per node up front; a sizing guess only, the buffer grows as needed.
const BYTES_PER_NODE: usize = 16;

pub(super) fn write(root: Item<'_, '_>, format: Format) -> Result<Vec<u8>, Error> {
    match (root, format) {
        (Item::Value(value), Format::Compact) => emit(value.subtree(), format),
        // A scalar is its own one-node layout (the most common write: one string or number).
        (Item::Data(Data::Value(value)), _) => write(Item::Value(*value), format),
        (Item::Data(Data::Array(_) | Data::Object(_)), _) | (Item::Value(_), _) => {
            emit(&layout(root, format != Format::Compact), format)
        }
        (Item::Data(_), _) => emit(&[scalar(root)], format),
    }
}

fn string(text: &str, padded: bool) -> Node {
    Node {
        tag: Kind::String as u64 | (text.len() as u64) << 8 | if padded { 0 } else { UNPADDED },
        data: text.as_ptr() as u64,
    }
}

fn key(text: &str, padded: bool) -> Node {
    let node = string(text, padded);
    Node {
        tag: node.tag | KEY,
        data: node.data,
    }
}

/// Children still to lay out in one open container.
enum Children<'a, 'b> {
    Items(std::slice::Iter<'b, Data<'a>>),
    Members(std::slice::Iter<'b, (&'a str, Data<'a>)>),
    /// Array elements of a parsed value (pretty layout descends into them).
    Values {
        next: Value<'a>,
        left: usize,
    },
    /// Object members sorted by key bytes (pretty layout).
    Sorted(std::vec::IntoIter<(Node, Item<'a, 'b>)>),
}
impl<'a, 'b> Iterator for Children<'a, 'b> {
    type Item = (Option<Node>, Item<'a, 'b>);
    fn next(&mut self) -> Option<Self::Item> {
        match self {
            Children::Items(items) => items.next().map(|v| (None, Item::Data(v))),
            Children::Members(members) => members
                .next()
                .map(|(k, v)| (Some(key(k, false)), Item::Data(v))),
            Children::Values { left: 0, .. } => None,
            Children::Values { next, left } => {
                let value = *next;
                *left -= 1;
                if *left > 0 {
                    *next = value.next();
                }
                Some((None, Item::Value(value)))
            }
            Children::Sorted(members) => members.next().map(|(k, v)| (Some(k), v)),
        }
    }
}

/// Members sorted by key bytes, stable for duplicate keys.
fn sorted<'a, 'b>(members: impl Iterator<Item = (Node, Item<'a, 'b>)>) -> Children<'a, 'b> {
    let mut members: Vec<_> = members.collect();
    members.sort_by(|(a, _), (b, _)| Value { node: a }.bytes().cmp(Value { node: b }.bytes()));
    Children::Sorted(members.into_iter())
}

/// Nodes for `root` in output order, object members sorted by key bytes (stable) when `sort`.
fn layout(root: Item<'_, '_>, sort: bool) -> Vec<Node> {
    let mut nodes = Vec::new();
    let mut open: Vec<(usize, Children)> = Vec::new();
    let mut item = root;
    loop {
        let children = match item {
            Item::Data(Data::Value(value)) => {
                item = Item::Value(*value);
                continue;
            }
            // A parsed value keeps its order unless sorting: its nodes are copied as is.
            Item::Value(value) if !sort => {
                nodes.extend_from_slice(value.subtree());
                None
            }
            Item::Data(Data::Array(items)) => {
                Some((Kind::Array, items.len(), Children::Items(items.iter())))
            }
            Item::Data(Data::Object(members)) if !sort => Some((
                Kind::Object,
                members.len(),
                Children::Members(members.iter()),
            )),
            Item::Data(Data::Object(members)) => Some((
                Kind::Object,
                members.len(),
                sorted(members.iter().map(|(k, v)| (key(k, false), Item::Data(v)))),
            )),
            Item::Value(value) if value.kind() == Kind::Array => {
                let next = if value.len() > 0 {
                    value.next_child()
                } else {
                    value
                };
                Some((
                    Kind::Array,
                    value.len(),
                    Children::Values {
                        next,
                        left: value.len(),
                    },
                ))
            }
            Item::Value(value) if value.kind() == Kind::Object => Some((
                Kind::Object,
                value.len(),
                sorted(
                    value
                        .object()
                        .unwrap()
                        .map(|(k, v)| (key(k, true), Item::Value(v))),
                ),
            )),
            _ => {
                nodes.push(scalar(item));
                None
            }
        };
        if let Some((kind, len, children)) = children {
            nodes.push(Node {
                tag: kind as u64 | (len as u64) << 8,
                data: 0,
            });
            open.push((nodes.len() - 1, children));
        }
        loop {
            let Some((at, children)) = open.last_mut() else {
                return nodes;
            };
            if let Some((key, child)) = children.next() {
                nodes.extend(key);
                item = child;
                break;
            }
            let at = *at;
            nodes[at].data = (nodes.len() - at) as u64;
            open.pop();
        }
    }
}

fn scalar(item: Item<'_, '_>) -> Node {
    let number = |subtype: u64, data: u64| Node {
        tag: Kind::Number as u64 | subtype << 3,
        data,
    };
    match item {
        Item::Value(value) => Node {
            tag: value.node.tag,
            data: value.node.data,
        },
        Item::Data(Data::Null) => Node {
            tag: Kind::Null as u64,
            data: 0,
        },
        Item::Data(Data::Bool(v)) => Node {
            tag: Kind::Bool as u64,
            data: *v as u64,
        },
        Item::Data(Data::Unsigned(v)) => number(number::UNSIGNED, *v),
        Item::Data(Data::Signed(v)) => number(number::SIGNED, *v as u64),
        Item::Data(Data::Real(v)) => number(number::REAL, v.to_bits()),
        Item::Data(Data::String(v)) => string(v, false),
        Item::Data(Data::Array(_) | Data::Object(_) | Data::Value(_)) => {
            unreachable!("handled by layout")
        }
    }
}

super::simd::dispatch! {
    fn emit<L>(nodes: &[Node], format: Format) -> Result<Vec<u8>, Error> {
        // One specialized writer per format: the per-node path has no layout branches.
        match format {
            Format::Compact => nodes_to::<L, false, false>(nodes),
            Format::PrettySorted => nodes_to::<L, true, true>(nodes),
            Format::PrettySortedUnescaped => nodes_to::<L, true, false>(nodes),
        }
    }
}

#[inline(always)]
fn nodes_to<L: Lanes, const PRETTY: bool, const SLASH: bool>(
    nodes: &[Node],
) -> Result<Vec<u8>, Error> {
    let (pretty, slash) = (PRETTY, SLASH);
    // Strings are copied mostly as is: their bytes plus a per-node allowance.
    let strings: usize = nodes
        .iter()
        .filter(|n| n.tag & 7 == KIND_STRING)
        .map(|n| (n.tag >> 8) as usize)
        .sum();
    let mut buf = Vec::with_capacity(strings + nodes.len() * BYTES_PER_NODE);
    let mut out = Out::new(&mut buf);
    // Every value is followed by ',' (keys by ':'); closing a container replaces the
    // last ',' with the bracket. `open`: node index where each container ends, its bracket.
    // `end` caches the innermost container's end so most nodes skip the stack.
    let mut open: Vec<(usize, u8)> = Vec::new();
    let mut end = usize::MAX;
    let mut key = false;
    for (i, node) in nodes.iter().enumerate() {
        if i == end {
            close(&mut out, &mut open, i, pretty);
            end = open.last().map_or(usize::MAX, |top| top.0);
        }
        // One capacity check per node; the length field (string bytes, or a container's
        // count, harmless extra) covers a string copied whole.
        out.room(NODE + indented(open.len()) + (node.tag >> 8) as usize);
        if pretty && !key && !open.is_empty() {
            indent(&mut out, open.len());
        }
        let data = node.data;
        let kind = node.tag & 7;
        // Most frequent kinds first; a compare chain predicts better than a jump table here.
        if kind == KIND_STRING {
            if node.tag & NOESC != 0 && !slash {
                copy::<L>(&mut out, Value { node }.bytes());
            } else {
                text::<L>(
                    &mut out,
                    Value { node }.bytes(),
                    slash,
                    node.tag & UNPADDED == 0,
                );
            }
        } else if kind == KIND_NUMBER {
            match node.tag >> 3 & 3 {
                // SAFETY: NODE bytes of room cover any integer.
                number::UNSIGNED => {
                    out.len += unsafe { number::unsigned(data, out.ptr.add(out.len)) }
                }
                number::SIGNED => {
                    out.len += unsafe { number::signed(data as i64, out.ptr.add(out.len)) }
                }
                // Pretty formats stand for the old Foundation writer (C-JSON-NUMBER).
                _ => numeral(
                    &mut out,
                    if pretty {
                        number::foundation(f64::from_bits(data))
                    } else {
                        number::real(f64::from_bits(data))
                    }
                    .ok_or_else(failure)?,
                ),
            }
        } else if kind == KIND_NULL {
            out.put(b"null");
        } else if kind == KIND_BOOL {
            out.put(if data != 0 { b"true" } else { b"false" });
        } else {
            let bracket = if kind == KIND_OBJECT { *b"{}" } else { *b"[]" };
            out.put(&bracket[..1]);
            if data == 1 {
                if pretty {
                    // Its closing line is a second indent beyond the node's room.
                    out.room(3 + indented(open.len()));
                    out.put(b"\n");
                    indent(&mut out, open.len());
                }
                out.put(&bracket[1..]);
            } else {
                end = i + data as usize;
                open.push((end, bracket[1]));
                key = false;
                continue;
            }
        }
        key = node.tag & KEY != 0;
        match (key, pretty) {
            (true, true) => out.put(b" : "),
            (true, false) => out.put(b":"),
            _ => out.put(b","),
        }
    }
    close(&mut out, &mut open, nodes.len(), pretty);
    // Drop the ',' after the root value.
    out.len -= 1;
    drop(out);
    Ok(buf)
}

const KIND_NULL: u64 = Kind::Null as u64;
const KIND_BOOL: u64 = Kind::Bool as u64;
const KIND_NUMBER: u64 = Kind::Number as u64;
const KIND_STRING: u64 = Kind::String as u64;
const KIND_OBJECT: u64 = Kind::Object as u64;

/// Bytes any single node needs besides its indent and string bytes: a number's 40-byte
/// text, separators, an empty container's newlines, or a string's quotes plus the chunk a
/// whole-chunk copy may write past its end.
const NODE: usize = 64;

/// Output cursor for the writer's hot loop: pointer, length and capacity are plain fields,
/// so they stay in registers; only growing touches the Vec, out of line. Dropping it sets
/// the Vec's length.
struct Out<'a> {
    vec: *mut Vec<u8>,
    ptr: *mut u8,
    len: usize,
    cap: usize,
    borrow: PhantomData<&'a mut Vec<u8>>,
}

impl<'a> Out<'a> {
    fn new(vec: &'a mut Vec<u8>) -> Self {
        Out {
            ptr: vec.as_mut_ptr(),
            len: vec.len(),
            cap: vec.capacity(),
            vec,
            borrow: PhantomData,
        }
    }
    /// Make room for `n` more items; the only capacity check.
    #[inline(always)]
    fn room(&mut self, n: usize) {
        if self.cap - self.len < n {
            // SAFETY: the Vec is borrowed by this cursor for its whole life.
            (self.ptr, self.cap) = Self::grow(unsafe { &mut *self.vec }, self.len, n);
        }
    }
    #[cold]
    #[inline(never)]
    fn grow(vec: &mut Vec<u8>, len: usize, n: usize) -> (*mut u8, usize) {
        // SAFETY: the first `len` items are written.
        unsafe { vec.set_len(len) };
        vec.reserve(n);
        (vec.as_mut_ptr(), vec.capacity())
    }
    /// Append after `room`.
    #[inline(always)]
    fn put(&mut self, items: &[u8]) {
        debug_assert!(self.cap - self.len >= items.len());
        // SAFETY: room was made by the caller.
        unsafe {
            self.ptr
                .add(self.len)
                .copy_from_nonoverlapping(items.as_ptr(), items.len())
        };
        self.len += items.len();
    }
}

impl Drop for Out<'_> {
    fn drop(&mut self) {
        // SAFETY: the first `len` bytes are written; the Vec is still borrowed by us.
        unsafe { (*self.vec).set_len(self.len) };
    }
}

/// A number's text; its whole fixed buffer is copied, only `len` bytes are kept.
#[inline(always)]
fn numeral(out: &mut Out<'_>, text: number::Text) {
    out.room(text.bytes.len());
    out.put(&text.bytes);
    out.len -= text.bytes.len() - text.len;
}

/// Pretty layout indents at most this many levels; deeper lines stay at that column. Uncapped,
/// a value nested d deep prints O(d²) bytes: a 16 KB `[[[…]]]` in an agent's tool input or
/// hook body would print as 128 MB. Capped, output stays linear in the input.
const INDENT: usize = 16;

/// Bytes `indent` writes at `depth`.
fn indented(depth: usize) -> usize {
    1 + 2 * depth.min(INDENT)
}

/// Newline and two spaces per level, up to INDENT levels; room made by the caller.
fn indent(out: &mut Out<'_>, depth: usize) {
    let width = indented(depth) - 1;
    out.put(b"\n");
    // SAFETY: room made by the caller.
    unsafe { out.ptr.add(out.len).write_bytes(b' ', width) };
    out.len += width;
}

/// Close every open container that ends at node `at`: its last ',' becomes the bracket
/// (on its own line when pretty), followed by ',' as for any value.
#[inline(always)]
fn close(out: &mut Out<'_>, open: &mut Vec<(usize, u8)>, at: usize, pretty: bool) {
    loop {
        match open.last() {
            Some(&(end, bracket)) if end == at => {
                open.pop();
                out.len -= 1;
                out.room(2 + indented(open.len()));
                if pretty {
                    indent(out, open.len());
                }
                out.put(&[bracket, b',']);
            }
            _ => return,
        }
    }
}

/// Quoted string that needs no escaping, from a padded document: whole chunks are copied
/// (the last one may run past the end; only `s.len()` bytes are kept).
#[inline(always)]
fn copy<L: Lanes>(out: &mut Out<'_>, s: &[u8]) {
    // Room: the caller's per-node check covers the string, one chunk and the quotes.
    out.put(b"\"");
    let mut at = 0;
    loop {
        // SAFETY: room for the whole string plus one chunk; the source is padded (NOESC
        // strings come from parsed documents).
        unsafe {
            let word = s.as_ptr().add(at).cast::<u128>().read_unaligned();
            out.ptr
                .add(out.len + at)
                .cast::<u128>()
                .write_unaligned(word);
        }
        at += 16;
        if at >= s.len() {
            break;
        }
    }
    out.len += s.len();
    out.put(b"\"");
}

/// Quoted string, escaping '"', '\\', bytes < 0x20 and, when asked, '/'; everything else raw.
/// `padded`: the bytes sit in a parsed document, readable a chunk past their end.
#[inline(always)]
fn text<L: Lanes>(out: &mut Out<'_>, s: &[u8], slash: bool, padded: bool) {
    out.put(b"\"");
    let mut at = 0;
    loop {
        // One check per chunk: the chunk, one escape (6) and the closing quote.
        out.room(L::WIDTH + 7);
        let v = if padded || at + L::WIDTH <= s.len() {
            // SAFETY: WIDTH bytes of `s` from `at`, or of the document padding after it.
            unsafe { L::load(s.as_ptr().add(at)) }
        } else {
            // The last partial chunk of a caller string is read from a zeroed copy.
            let mut tail = [0u8; 64];
            tail[..s.len() - at].copy_from_slice(&s[at..]);
            // SAFETY: tail holds 64 >= WIDTH bytes.
            unsafe { L::load(tail.as_ptr()) }
        };
        // SAFETY: room for WIDTH bytes; only plain bytes inside `s` are kept.
        unsafe { L::store(out.ptr.add(out.len), v) };
        let mut hits = L::or(L::or(L::eq(v, b'"'), L::eq(v, b'\\')), L::below(v, 0x20));
        if slash {
            hits = L::or(hits, L::eq(v, b'/'));
        }
        let n = L::first(hits);
        if n == L::WIDTH && at + L::WIDTH <= s.len() {
            // Clean chunk: a constant step, so the next load does not wait on this compare.
            out.len += L::WIDTH;
            at += L::WIDTH;
            continue;
        }
        let n = n.min(s.len() - at);
        out.len += n;
        at += n;
        if at == s.len() {
            break;
        }
        let c = s[at];
        at += 1;
        let short = match c {
            b'"' => b'"',
            b'\\' => b'\\',
            b'/' => b'/',
            0x08 => b'b',
            0x0C => b'f',
            b'\n' => b'n',
            b'\r' => b'r',
            b'\t' => b't',
            _ => {
                const HEX: &[u8; 16] = b"0123456789ABCDEF";
                out.put(&[
                    b'\\',
                    b'u',
                    b'0',
                    b'0',
                    HEX[(c >> 4) as usize],
                    HEX[(c & 15) as usize],
                ]);
                continue;
            }
        };
        out.put(&[b'\\', short]);
    }
    out.put(b"\"");
}
