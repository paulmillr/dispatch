//! Single-pass reader: yyjson flags 0 by default, or Foundation transcript compatibility.
//! Strict errors preserve yyjson's code, position and truncated-input rule.
use super::{Json, KEY, Kind, NOESC, Node, Policy, Select, Value, number, simd::Lanes};

/// Zero bytes after the input copy: the widest chunk load at any byte up to the end stays in
/// bounds, and the first zero ends every token (it is a control byte, not whitespace).
pub(super) const PAD: usize = 64;
/// yyjson error codes (yyjson.h YYJSON_READ_ERROR_*).
const PARAMETER: u32 = 1;
const EMPTY: u32 = 3;
const CONTENT: u32 = 4;
const END: u32 = 5;
const CHARACTER: u32 = 6;
const STRUCTURE: u32 = 7;
const STRING: u32 = 10;
const LITERAL: u32 = 11;
/// Parent link of the root container.
const ROOT: u64 = u64::MAX;
/// yyjson's estimate of input bytes per value for compact JSON; only sizes the first allocation.
const RATIO: usize = 6;

/// Byte `i` of the padded input copy, without a bounds check. Every index the reader forms
/// is at most the input length plus one token's lookahead (12 bytes, a surrogate escape),
/// inside the PAD zero bytes, because the first zero ends every token.
#[inline(always)]
pub(super) fn byte(text: &[u8], i: usize) -> u8 {
    debug_assert!(i < text.len());
    // SAFETY: see above; text.len() == input length + PAD.
    unsafe { *text.get_unchecked(i) }
}

#[inline(always)]
fn space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r')
}
#[inline(always)]
fn skip<L: Lanes>(text: &[u8], mut at: usize) -> usize {
    if !space(byte(text, at)) {
        return at;
    }
    at += 1;
    loop {
        // SAFETY: at <= input length, so the chunk ends inside the padding.
        let v = unsafe { L::load(text.as_ptr().add(at)) };
        let ws = L::or(
            L::or(L::eq(v, b' '), L::eq(v, b'\n')),
            L::or(L::eq(v, b'\r'), L::eq(v, b'\t')),
        );
        let n = L::first(L::not(ws));
        if n < L::WIDTH {
            return at + n;
        }
        at += L::WIDTH;
    }
}

super::simd::dispatch! {
    pub(super) fn read<L>(input: &[u8], policy: Policy) -> Result<Json, (u32, usize)> {
        parse::<L, false>(input, policy)
    }
}

#[inline(always)]
fn parse<L: Lanes, const RAW: bool>(input: &[u8], policy: Policy) -> Result<Json, (u32, usize)> {
    if input.is_empty() {
        return Err((PARAMETER, 0));
    }
    let mut text = Vec::with_capacity(input.len() + PAD);
    text.extend_from_slice(input);
    text.resize(input.len() + PAD, 0);
    let mut text = text.into_boxed_slice();
    let mut nodes = Vec::with_capacity(input.len() / RATIO + 4);
    match document::<L, RAW>(&mut text, input.len(), &mut nodes, policy) {
        Ok(()) => Ok(Json { nodes, text }),
        Err((code, at)) => Err(truncated(code, at, input)),
    }
}

// RAW documents retain scalar spans privately. Projection decodes selected keys/scalars
// into a normal tape; nothing undecodable can escape through the public Value methods.
super::simd::dispatch! {
    pub(super) fn decode<L>(input: &[u8], select: &Select<'_>) -> Result<Json, (u32, usize)> {
    let mut raw = parse::<L, true>(input, Policy::Foundation)?;
    let mut select = *select;
    struct Frame<'a> {
        select: Select<'a>,
        next: usize,
        end: usize,
        out: usize,
        count: u64,
        seen: Vec<bool>,
    }
    let mut frames: Vec<Frame<'_>> = Vec::new();
    let mut nodes = Vec::new();
    let mut at = 0;
    'value: loop {
        let input = raw.nodes[at];
        let kind = Value { node: &input }.kind();
        let out = nodes.len();
        nodes.push(Node { tag: Kind::Null as u64, data: 0 });
        match (select, kind) {
            (Select::Scalar, Kind::String | Kind::Number) => {
                let start = if kind == Kind::String {
                    (input.data - raw.text.as_ptr() as u64) as usize - 1
                } else {
                    input.data as usize
                };
                let end = start + (input.tag >> 8) as usize + if kind == Kind::String { 2 } else { 0 };
                let c = byte(&raw.text, start);
                if let Ok((node, next)) = scalar::<L, false>(&mut raw.text, start, c)
                    && next == end
                {
                    nodes[out] = node;
                }
            }
            (Select::Scalar, Kind::Null | Kind::Bool) => nodes[out] = input,
            (Select::Object(_), Kind::Object) | (Select::Array(_), Kind::Array) => {
                nodes[out].tag = kind as u64;
                frames.push(Frame {
                    select,
                    next: at + 1,
                    end: at + input.data as usize,
                    out,
                    count: 0,
                    seen: match select {
                        Select::Object(fields) => vec![false; fields.len()],
                        _ => Vec::new(),
                    },
                });
            }
            _ => {}
        }
        loop {
            let Some(frame) = frames.last_mut() else {
                return Ok(Json { nodes, text: raw.text });
            };
            if frame.next == frame.end {
                let size = (nodes.len() - frame.out) as u64;
                let node = &mut nodes[frame.out];
                node.data = size;
                node.tag |= frame.count << 8;
                frames.pop();
                continue;
            }
            match frame.select {
                Select::Array(child) => {
                    at = frame.next;
                    frame.next += Value { node: &raw.nodes[at] }.subtree().len();
                    frame.count += 1;
                    select = *child;
                    continue 'value;
                }
                Select::Object(fields) => {
                    let key = raw.nodes[frame.next];
                    at = frame.next + 1;
                    frame.next = at + Value { node: &raw.nodes[at] }.subtree().len();
                    let start = (key.data - raw.text.as_ptr() as u64) as usize - 1;
                    let (key, _) = string::<L>(&mut raw.text, start)?;
                    let name = Value { node: &key }.string().unwrap();
                    if let Some(index) = fields.iter().position(|(field, _)| *field == name)
                        && !frame.seen[index]
                    {
                        frame.seen[index] = true;
                        nodes.push(Node { tag: key.tag | KEY, data: key.data });
                        frame.count += 1;
                        select = fields[index].1;
                        continue 'value;
                    }
                }
                Select::Scalar => unreachable!(),
            }
        }
    }
    }
}

/// Reads the whole document. Structure is straight-line code per position, like yyjson's
/// labels: open a container, then loop over its members (object) or elements (array), and
/// after each value either continue at ',' or close at the bracket. No state variable.
#[inline(always)]
fn document<L: Lanes, const RAW: bool>(
    text: &mut [u8],
    len: usize,
    nodes: &mut Vec<Node>,
    policy: Policy,
) -> Result<(), (u32, usize)> {
    let mut at = skip::<L>(text, 0);
    if at >= len {
        return Err((EMPTY, 0));
    }
    let mut c = byte(text, at);
    if c != b'[' && c != b'{' {
        let (node, end) = scalar::<L, RAW>(text, at, c)?;
        nodes.push(node);
        return finish::<L>(text, len, end);
    }
    // Open container (index, ROOT above the root), its member or element count so far, and
    // whether it is an object. The parent's count waits in its tag while a child is open.
    let (mut parent, mut count, mut object) = (ROOT, 0u64, false);
    let mut depth = 0;
    'open: loop {
        // `c` is '[' or '{' at `at`.
        if policy == Policy::Foundation && depth == 512 {
            return Err((STRUCTURE, at));
        }
        depth += 1;
        if parent != ROOT {
            nodes[parent as usize].tag |= (count + !object as u64) << 8;
        }
        object = c == b'{';
        let kind = if object { Kind::Object } else { Kind::Array };
        nodes.push(Node {
            tag: kind as u64,
            data: parent,
        });
        parent = (nodes.len() - 1) as u64;
        count = 0;
        at = skip::<L>(text, at + 1);
        // An empty container closes right away; otherwise its first member or element.
        let empty = byte(text, at) == if object { b'}' } else { b']' };
        'items: loop {
            // Only an empty container's first pass has no value to read (count stays 0
            // there; every other pass has counted at least one member or element).
            if !empty || count != 0 {
                if object {
                    if byte(text, at) != b'"' {
                        return Err((CHARACTER, at));
                    }
                    let (key, end) = quoted::<L, RAW>(text, at)?;
                    nodes.push(Node {
                        tag: key.tag | KEY,
                        data: key.data,
                    });
                    count += 1;
                    at = skip::<L>(text, end);
                    if byte(text, at) != b':' {
                        return Err((CHARACTER, at));
                    }
                    at = skip::<L>(text, at + 1);
                }
                c = byte(text, at);
                if c == b'[' || c == b'{' {
                    continue 'open;
                }
                let (node, end) = scalar::<L, RAW>(text, at, c)?;
                nodes.push(node);
                count += !object as u64;
                at = end;
            }
            // After a value (or at an empty container's bracket).
            loop {
                c = byte(text, at);
                if c == b',' {
                    let comma = at;
                    at = skip::<L>(text, at + 1);
                    if byte(text, at) == if object { b'}' } else { b']' } {
                        if policy == Policy::Foundation {
                            continue;
                        }
                        // yyjson scans back for ',' starting one byte after the bracket, so
                        // a comma right after the bracket is the one reported.
                        let next = at + 1;
                        return Err((
                            STRUCTURE,
                            if byte(text, next) == b',' {
                                next
                            } else {
                                comma
                            },
                        ));
                    }
                    // Arrays of numbers: the next element is read right here.
                    let first = byte(text, at);
                    if !RAW && !object && (first.is_ascii_digit() || first == b'-') {
                        let (subtype, data, end) = number::read(text, at)?;
                        let tag = Kind::Number as u64 | subtype << 3;
                        nodes.push(Node { tag, data });
                        count += 1;
                        at = end;
                        continue;
                    }
                    continue 'items;
                }
                if c == if object { b'}' } else { b']' } {
                    depth -= 1;
                    at += 1;
                    let index = parent as usize;
                    let size = (nodes.len() - index) as u64;
                    let node = &mut nodes[index];
                    parent = node.data;
                    node.data = size;
                    node.tag |= count << 8;
                    if parent == ROOT {
                        return finish::<L>(text, len, at);
                    }
                    let up = &mut nodes[parent as usize];
                    count = up.tag >> 8;
                    up.tag &= 0xFF;
                    object = up.tag == Kind::Object as u64;
                    continue;
                }
                if space(c) {
                    at = skip::<L>(text, at);
                    continue;
                }
                return Err((CHARACTER, at));
            }
        }
    }
}

/// Only whitespace may follow the root value.
#[inline(always)]
fn finish<L: Lanes>(text: &[u8], len: usize, at: usize) -> Result<(), (u32, usize)> {
    let at = skip::<L>(text, at);
    if at < len { Err((CONTENT, at)) } else { Ok(()) }
}

#[inline(always)]
fn scalar<L: Lanes, const RAW: bool>(
    text: &mut [u8],
    at: usize,
    c: u8,
) -> Result<(Node, usize), (u32, usize)> {
    let (word, kind, data): (&[u8], Kind, u64) = match c {
        // yyjson starts a number at any of [.-+0-9]; '.' and '+' fail inside it.
        b'0'..=b'9' | b'-' | b'+' | b'.' => {
            if RAW {
                if c == b'+' || c == b'.' {
                    return Err((CHARACTER, at));
                }
                let mut end = at + 1;
                for b in text[end..].iter() {
                    if !matches!(b, b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E') {
                        break;
                    }
                    end += 1;
                }
                return Ok((
                    Node {
                        tag: Kind::Number as u64 | ((end - at) as u64) << 8,
                        data: at as u64,
                    },
                    end,
                ));
            }
            let (subtype, data, end) = number::read(text, at)?;
            let tag = Kind::Number as u64 | subtype << 3;
            return Ok((Node { tag, data }, end));
        }
        b'"' => return quoted::<L, RAW>(text, at),
        b't' => (b"true", Kind::Bool, 1),
        b'f' => (b"false", Kind::Bool, 0),
        b'n' => (b"null", Kind::Null, 0),
        _ => return Err((CHARACTER, at)),
    };
    if text[at..at + word.len()] != *word {
        return Err((LITERAL, at));
    }
    Ok((
        Node {
            tag: kind as u64,
            data,
        },
        at + word.len(),
    ))
}

/// JSONDecoder records string boundaries before it decodes any bytes/escapes. Unknown
/// values can contain invalid scalar data, but an unterminated string is still structural.
#[inline(always)]
fn quoted<L: Lanes, const RAW: bool>(
    text: &mut [u8],
    at: usize,
) -> Result<(Node, usize), (u32, usize)> {
    if !RAW {
        return string::<L>(text, at);
    }
    let mut end = at + 1;
    let len = text.len() - PAD;
    for _ in 0..len {
        if end >= len {
            break;
        }
        // SAFETY: end is within the input and each wide load ends inside its padding.
        let v = unsafe { L::load(text.as_ptr().add(end)) };
        end += L::first(L::or(L::eq(v, b'"'), L::eq(v, b'\\')));
        if end >= len {
            break;
        }
        if byte(text, end) == b'"' {
            return Ok((
                Node {
                    tag: Kind::String as u64 | ((end - at - 1) as u64) << 8,
                    data: text.as_ptr() as u64 + at as u64 + 1,
                },
                end + 1,
            ));
        }
        if byte(text, end) == b'\\' {
            end += 2;
        }
    }
    Err((END, len))
}

/// All-zero chunk.
#[inline(always)]
fn zero<L: Lanes>() -> L::V {
    // SAFETY: a local array of 64 >= WIDTH zero bytes.
    unsafe { L::load([0u8; 64].as_ptr()) }
}

/// Bytes that end a plain run inside a string.
#[inline(always)]
fn special<L: Lanes>(v: L::V) -> L::V {
    L::or(
        L::or(L::eq(v, b'"'), L::eq(v, b'\\')),
        L::or(L::below(v, 0x20), L::high(v)),
    )
}

/// String whose opening quote is at `at`; unescaped in place. Returns its node and the index
/// after the closing quote.
#[inline(always)]
fn string<L: Lanes>(text: &mut [u8], at: usize) -> Result<(Node, usize), (u32, usize)> {
    let start = at + 1;
    let base = text.as_ptr() as u64;
    let node = |len: usize| Node {
        tag: Kind::String as u64 | (len as u64) << 8,
        data: base + start as u64,
    };
    let mut src = start;
    loop {
        // SAFETY: src <= input length (the padding zero stops every run).
        let n = L::first(special::<L>(unsafe { L::load(text.as_ptr().add(src)) }));
        if n == L::WIDTH {
            // Constant step, so the next load does not wait on this compare.
            src += L::WIDTH;
            continue;
        }
        src += n;
        match byte(text, src) {
            b'"' => {
                let node = node(src - start);
                return Ok((
                    Node {
                        tag: node.tag | NOESC,
                        data: node.data,
                    },
                    src + 1,
                ));
            }
            b'\\' => break,
            0x80.. => src = unicode::<L>(text, src)?,
            _ => return Err((STRING, src)),
        }
    }
    let mut dst = src;
    loop {
        match byte(text, src) {
            b'"' => return Ok((node(dst - start), src + 1)),
            b'\\' => {
                // Two-character escapes inline; \u and invalid ones out of line.
                let simple = SIMPLE[byte(text, src + 1) as usize];
                if simple != 0 {
                    text[dst] = simple;
                    (src, dst) = (src + 2, dst + 1);
                } else {
                    (src, dst) = escape(text, src, dst)?;
                }
            }
            0x80.. => {
                let end = unicode::<L>(text, src)?;
                text.copy_within(src..end, dst);
                dst += end - src;
                src = end;
            }
            _ => return Err((STRING, src)),
        }
        // Move plain runs down a chunk at a time.
        loop {
            // SAFETY: src <= input length; the chunk ends inside the padding.
            let v = unsafe { L::load(text.as_ptr().add(src)) };
            let n = L::first(special::<L>(v));
            // A whole-chunk store is safe when it ends before the unread bytes (src + n);
            // otherwise only the run is moved. (Merging with the bytes at dst would reload
            // what the previous store just wrote: a store-forwarding stall per run.)
            if dst + L::WIDTH <= src + n {
                // SAFETY: dst < src, the chunk ends inside the padding and before src + n.
                unsafe { L::store(text.as_mut_ptr().add(dst), v) };
            } else if n > 0 {
                text.copy_within(src..src + n, dst);
            }
            src += n;
            dst += n;
            if n < L::WIDTH {
                break;
            }
        }
    }
}

/// Decoded byte of each two-character escape `\x`, 0 for the rest (`\u` or invalid).
const SIMPLE: [u8; 256] = {
    let mut table = [0; 256];
    table[b'"' as usize] = b'"';
    table[b'\\' as usize] = b'\\';
    table[b'/' as usize] = b'/';
    table[b'b' as usize] = 0x08;
    table[b'f' as usize] = 0x0C;
    table[b'n' as usize] = b'\n';
    table[b'r' as usize] = b'\r';
    table[b't' as usize] = b'\t';
    table
};

/// Hex digit values, 0xFF for other bytes.
const HEX: [u8; 256] = {
    let mut table = [0xFF; 256];
    let mut i = 0;
    loop {
        if i == 256 {
            break table;
        }
        table[i] = match i as u8 {
            b'0'..=b'9' => i as u8 - b'0',
            b'a'..=b'f' => i as u8 - b'a' + 10,
            b'A'..=b'F' => i as u8 - b'A' + 10,
            _ => 0xFF,
        };
        i += 1;
    }
};

/// The four hex digits at `at`.
#[inline(always)]
fn hex4(text: &[u8], at: usize) -> Option<u32> {
    let d = [0, 1, 2, 3].map(|i| HEX[byte(text, at + i) as usize] as u32);
    (d[0] | d[1] | d[2] | d[3] < 16).then_some(d[0] << 12 | d[1] << 8 | d[2] << 4 | d[3])
}

/// Escape at `src` (a backslash) that is not a two-character one: `\uXXXX` (or a
/// surrogate pair), decoded to UTF-8 at `dst`. Errors point at the backslash.
fn escape(text: &mut [u8], src: usize, dst: usize) -> Result<(usize, usize), (u32, usize)> {
    let fail = Err((STRING, src));
    if byte(text, src + 1) != b'u' {
        return fail;
    }
    let Some(hi) = hex4(text, src + 2) else {
        return fail;
    };
    let (code, used) = if hi & 0xF800 != 0xD800 {
        (hi, 6)
    } else {
        if hi & 0xFC00 != 0xD800 || byte(text, src + 6) != b'\\' || byte(text, src + 7) != b'u' {
            return fail;
        }
        let Some(lo) = hex4(text, src + 8).filter(|lo| lo & 0xFC00 == 0xDC00) else {
            return fail;
        };
        (0x10000 + ((hi - 0xD800) << 10 | (lo - 0xDC00)), 12)
    };
    let c = char::from_u32(code).unwrap();
    let n = c.encode_utf8(&mut text[dst..dst + 4]).len();
    Ok((src + used, dst + n))
}

/// Valid UTF-8 starting at `src` (a byte >= 0x80): returns the index of the next ASCII byte
/// not yet checked, or the error at the start of the first invalid sequence.
#[inline(always)]
fn unicode<L: Lanes>(text: &[u8], mut src: usize) -> Result<usize, (u32, usize)> {
    loop {
        if L::UTF8 {
            // SAFETY: src <= input length.
            let v = unsafe { L::load(text.as_ptr().add(src)) };
            let ends = L::or(L::or(L::eq(v, b'"'), L::eq(v, b'\\')), L::below(v, 0x20));
            let n = L::first(ends);
            // Validate the bytes before the first quote, backslash or control byte; zeroed
            // lanes after them make a sequence cut by that byte invalid, as it is.
            if L::utf8(L::merge(v, zero::<L>(), n)) {
                if n < L::WIDTH {
                    return Ok(src + n);
                }
                // Back up over a sequence cut by the chunk end; it starts the next chunk.
                let end = src + L::WIDTH;
                src = end
                    - [(1, 0xC0), (2, 0xE0), (3, 0xF0)]
                        .iter()
                        .find(|(back, lead)| text[end - back] >= *lead)
                        .map_or(0, |(back, _)| *back);
                continue;
            }
        }
        // No wide validator, or an invalid chunk: one sequence at a time finds the exact error.
        if byte(text, src) < 0x80 {
            return Ok(src);
        }
        src += sequence(text, src).ok_or((STRING, src))?;
    }
}

/// Length of the valid multi-byte UTF-8 sequence at `at` (RFC 3629 table).
fn sequence(text: &[u8], at: usize) -> Option<usize> {
    let cont = |i: usize| text[at + i] & 0xC0 == 0x80;
    let second = |range: std::ops::RangeInclusive<u8>| range.contains(&text[at + 1]);
    let ok = match text[at] {
        0xC2..=0xDF => cont(1),
        0xE0 => second(0xA0..=0xBF) && cont(2),
        0xE1..=0xEC | 0xEE..=0xEF => cont(1) && cont(2),
        0xED => second(0x80..=0x9F) && cont(2),
        0xF0 => second(0x90..=0xBF) && cont(2) && cont(3),
        0xF1..=0xF3 => cont(1) && cont(2) && cont(3),
        0xF4 => second(0x80..=0x8F) && cont(2) && cont(3),
        _ => return None,
    };
    ok.then_some(match text[at] {
        ..0xE0 => 2,
        ..0xF0 => 3,
        _ => 4,
    })
}

/// yyjson is_truncated_end for flags 0: an error explained by the input ending early is
/// reported as UNEXPECTED_END at the end of input.
fn truncated(code: u32, at: usize, input: &[u8]) -> (u32, usize) {
    let rest = input.get(at..).unwrap_or_default();
    let end = (END, input.len());
    let prefix = |word: &[u8]| rest.len() < word.len() && word.starts_with(rest);
    if rest.is_empty()
        || (code == LITERAL && (prefix(b"true") || prefix(b"false") || prefix(b"null")))
    {
        return end;
    }
    if code != STRING {
        return (code, at);
    }
    let hex = |b: &[u8]| b.iter().all(u8::is_ascii_hexdigit);
    let cut = if rest[0] == b'\\' {
        match rest.len() {
            1 => true,
            ..=5 => rest[1] == b'u' && hex(&rest[2..]),
            ..=11 => {
                // An unfinished surrogate pair: \uD800-\uDFFF then a prefix of \u[dD][c-fC-F]x.
                let high = rest[1] == b'u'
                    && hex(&rest[2..6])
                    && rest[2..6]
                        .iter()
                        .fold(0, |v, &b| v << 4 | (b as char).to_digit(16).unwrap())
                        & 0xF800
                        == 0xD800;
                high && rest[6..].iter().enumerate().all(|(i, &b)| match i {
                    0 => b == b'\\',
                    1 => b == b'u',
                    2 => b | 0x20 == b'd',
                    3 => (b'c'..=b'f').contains(&(b | 0x20)),
                    _ => b.is_ascii_hexdigit(),
                })
            }
            _ => false,
        }
    } else {
        utf8(rest)
    };
    if cut { end } else { (code, at) }
}

/// yyjson is_truncated_utf8: `rest` (under 4 bytes) is the start of a valid but unfinished
/// multi-byte sequence.
fn utf8(rest: &[u8]) -> bool {
    let byte = |i: usize| rest.get(i).copied().unwrap_or(0);
    let (c0, c1, c2) = (byte(0), byte(1), byte(2));
    if rest.len() >= 4 || c0 < 0x80 {
        return false;
    }
    let cont = |c: u8| c & 0xC0 == 0x80;
    match rest.len() {
        1 => {
            (c0 & 0xE0 == 0xC0 && c0 & 0x1E != 0)
                || c0 & 0xF0 == 0xE0
                || (c0 & 0xF8 == 0xF0 && c0 & 0x07 <= 0x04)
        }
        2 if c0 & 0xF0 == 0xE0 && cont(c1) => {
            let t = (c0 & 0x0F) << 1 | (c1 & 0x20) >> 5;
            t >= 0x01 && t != 0x1B
        }
        2 | 3 if c0 & 0xF8 == 0xF0 && cont(c1) && (rest.len() == 2 || cont(c2)) => {
            let t = (c0 & 0x07) << 2 | (c1 & 0x30) >> 4;
            (0x01..=0x10).contains(&t)
        }
        _ => false,
    }
}
