//! `dispatch-helper capture`: the tool for capture files (system/capture/trace.rs), only in helpers built with the
//! `capture` feature. Its replays run this same executable, so the tool never checks another helper than itself.
//! capture replay DIR [--output DIR] [--timeout SECONDS] [--completion required]
//! capture inspect FILE [--from N] [--limit N]   (one line per record, one per wire frame; our frames decoded; other bytes as text when UTF-8, otherwise as hex)
//! capture value FILE                 (one encoded value, e.g. a replay's mismatch.value)
//! capture grep NEEDLE PATH... | grep PATH... [--needles FILE] [--values SHAPE]...   [--limit N] [--jobs N]   (needles, literal, in every text/bytes value as a reader sees it (cut across records, wrapped), keys included, and in herdr's base64 and tmux's send-keys hex; warns of other text that looks encoded; --values: every distinct line of the values at places holding SHAPE, digits as #)
//! capture replace DIR OUT [--needles FILE] [--uuids] [--ips] [--jobs N]   (scrub: docs/capture_scrub.md)
//! capture key PATH...   (each capture's content key: its records without the bookkeeping clock)
//! capture check PATH...   (one case's app journals and helper captures: the bytes each side
//!                          sent are the bytes the other side read; every capture linked)
//! capture store STAGE REPLAYS --tests DIR [--failed]   (a run's passed tests into the corpus; --failed: its failed ones too, unchecked)
//! capture prune REPLAYS [--dry-run]   (drop corpus helper captures that no longer replay)
//! Options go anywhere after the command.
use dispatch_helper_core::{
    hash::Sha256,
    json::{Data, Json},
    system::{capture::{screen::Screen, trace, views::View}, replay::batch},
    wire::{self, body},
};
use std::{
    cell::RefCell,
    collections::{BTreeMap, HashMap, HashSet},
    fmt::Write,
    fs::File,
    io,
    ops::Range,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    rc::Rc,
    time::Duration,
};

/// A value for reading: the display only, never stored.
fn show(value: &Data<'_>, out: &mut String) {
    match value {
        Data::Null => out.push_str("null"),
        Data::Bool(v) => write!(out, "{v}").unwrap(),
        Data::Unsigned(v) => write!(out, "{v}").unwrap(),
        Data::Signed(v) => write!(out, "{v}").unwrap(),
        Data::Real(v) => write!(out, "{v}").unwrap(),
        Data::String(v) => write!(out, "{v:?}").unwrap(),
        // Frames first: a cancel or chunk frame can be all ASCII. Then text, then one of our plain values (a hook
        // question's body).
        Data::Bytes(v) => match (frames(v), std::str::from_utf8(v), body::decode_plain(v)) {
            (Some(frames), _, _) => write!(out, "frames[{}]", frames.join(", ")).unwrap(),
            (_, Ok(text), _) => write!(out, "b{text:?}").unwrap(),
            (_, _, Ok(value)) if !matches!(value, Data::Bytes(_)) => show(&value, out),
            _ => {
                out.push_str("hex(");
                for byte in v.iter() {
                    write!(out, "{byte:02x}").unwrap();
                }
                out.push(')');
            }
        },
        Data::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push_str(", ");
                }
                show(item, out);
            }
            out.push(']');
        }
        Data::Object(fields) => {
            out.push('{');
            for (index, (key, item)) in fields.iter().enumerate() {
                if index > 0 {
                    out.push_str(", ");
                }
                write!(out, "{key}: ").unwrap();
                show(item, out);
            }
            out.push('}');
        }
        Data::Value(_) => out.push_str("<json>"),
    }
}

/// A field of an object value.
fn field<'v, 'a>(value: &'v Data<'a>, name: &str) -> Option<&'v Data<'a>> {
    match value {
        Data::Object(fields) => fields.iter().find(|(key, _)| *key == name).map(|(_, item)| item),
        _ => None,
    }
}

/// A message body for reading: the method and its params (a request or notification), else the whole value.
fn message(value: &Data<'_>, text: &mut String) {
    match (field(value, "method"), field(value, "params")) {
        (Some(Data::String(method)), Some(params)) => {
            write!(text, " {method} ").unwrap();
            show(params, text);
        }
        _ => {
            text.push(' ');
            show(value, text);
        }
    }
}

/// One side of a connection as frames of our protocol, decoded across its reads: a frame split over several completes
/// with its last read, an unfinished one says how far it got; a streamed message (wire/stream.rs: its chunks, then the
/// frame announcing them) completes with that last frame. `fed` counts the stream's bytes: a body knows where each of
/// its bytes was in the stream.
struct Wire {
    decoder: wire::Decoder,
    open: Option<(wire::Header, Body)>,
    chunks: HashMap<u64, Body>,
    wire: bool,
    fed: u64,
}

/// Bytes gathered from a stream, and where each piece of them was in it: (offset here, offset in the stream).
#[derive(Default)]
struct Body {
    bytes: Vec<u8>,
    at: Vec<(usize, u64)>,
}

impl Body {
    fn push(&mut self, bytes: &[u8], at: u64) {
        self.at.push((self.bytes.len(), at));
        self.bytes.extend_from_slice(bytes);
    }

    /// Each piece: its range here, and where it began in the stream.
    fn pieces(&self) -> impl Iterator<Item = (Range<usize>, u64)> + '_ {
        let ends = self.at.iter().skip(1).map(|(here, _)| *here).chain([self.bytes.len()]);
        self.at.iter().zip(ends).map(|(&(start, at), end)| (start..end, at))
    }

    /// Where `range` of these bytes was in the stream: one range per piece it spans.
    fn stream(&self, range: Range<usize>) -> Vec<Range<u64>> {
        self.pieces().filter(|(piece, _)| piece.start < range.end && range.start < piece.end).map(|(piece, at)| {
            at + (range.start.max(piece.start) - piece.start) as u64..at + (range.end.min(piece.end) - piece.start) as u64
        }).collect()
    }
}

/// A whole frame: a chunk (its sequence and bytes), a cancel (its raw bytes), or a message: its value (decoded from
/// `body`), a stream's bytes beside it, or `streamed` when the value itself came in chunks.
#[derive(Clone, Copy)]
enum Content<'a> {
    Chunk(u64, &'a [u8]),
    Cancel(&'a [u8]),
    Message { value: &'a Data<'a>, body: &'a Body, bytes: Option<&'a Body>, streamed: bool },
}

impl Wire {
    fn new() -> Self {
        Self { decoder: wire::Decoder::new(wire::LIMIT), open: None, chunks: Default::default(), wire: false, fed: 0 }
    }

    /// What `each` makes of every frame `bytes` complete, and how far an unfinished one got; None when they are not our
    /// frames (the stream starts over: its bytes are something else, or the descriptor was reused).
    fn feed<T>(&mut self, bytes: &[u8], each: &mut dyn FnMut(&wire::Header, Content<'_>) -> T) -> Option<(Vec<T>, Option<String>)> {
        let (open, mut whole, at) = (&mut self.open, Vec::new(), self.fed);
        let fed = self.decoder.feed(bytes, |event| match event {
            wire::Event::Begin(header) => *open = Some((header, Body::default())),
            wire::Event::Data(data) => {
                open.as_mut().unwrap().1.push(data, at + (data.as_ptr() as usize - bytes.as_ptr() as usize) as u64)
            }
            wire::Event::End => whole.push(open.take().unwrap()),
        });
        self.fed += bytes.len() as u64;
        let any = !whole.is_empty();
        let out: Option<Vec<T>> = whole.into_iter().map(|(header, body)| self.frame(&header, body, each)).collect();
        // Bytes are our frames once one whole frame decoded (raw bytes, an OS struct, can begin like a header).
        let Some(out) = out.filter(|_| fed.is_ok() && (self.wire || any)) else {
            *self = Self { fed: self.fed, ..Self::new() };
            return None;
        };
        self.wire = true;
        let unfinished = match &self.open {
            Some((header, body)) => Some(format!("{} {} continues ({} of {} bytes)",
                format!("{:?}", header.kind).to_lowercase(), header.id, body.bytes.len(), header.len)),
            None if self.decoder.finish().is_err() => Some("frame header continues".into()),
            None => None,
        };
        Some((out, unfinished))
    }

    /// One whole frame for `each`; None when it is not one of ours.
    fn frame<T>(&mut self, header: &wire::Header, body: Body, each: &mut dyn FnMut(&wire::Header, Content<'_>) -> T) -> Option<T> {
        if header.kind == wire::Kind::Chunk {
            let (sequence, bytes) = body.bytes.split_first_chunk::<8>()?;
            let chunks = self.chunks.entry(header.id).or_default();
            for (piece, at) in body.pieces().filter(|(piece, _)| piece.end > 8) {
                let start = piece.start.max(8);
                chunks.push(&body.bytes[start..piece.end], at + (start - piece.start) as u64);
            }
            return Some(each(header, Content::Chunk(u64::from_le_bytes(*sequence), bytes)));
        }
        if header.kind == wire::Kind::Cancel {
            return Some(each(header, Content::Cancel(&body.bytes)));
        }
        // The app's frames carry the schema first; hook frames are plain values.
        let value = body::decode(&body.bytes).or_else(|_| body::decode_plain(&body.bytes)).ok()?;
        let streamed = self.chunks.remove(&header.id);
        // A value's chunks are its body; binary ones are bytes beside the announcing frame's result.
        Some(match (field(&value, "stream").and_then(|stream| field(stream, "encoding")), &streamed) {
            (Some(Data::String(encoding)), Some(chunks)) if *encoding == "value" => {
                let value = body::decode(&chunks.bytes).ok()?;
                each(header, Content::Message { value: &value, body: chunks, bytes: None, streamed: true })
            }
            (Some(_), Some(chunks)) => each(header, Content::Message { value: &value, body: &body, bytes: Some(chunks), streamed: false }),
            _ => each(header, Content::Message { value: &value, body: &body, bytes: None, streamed: false }),
        })
    }
}

/// One frame for reading: kind, id, then its message; a chunk only counts its bytes (its message prints at its end), a
/// cancel shows its raw bytes.
fn line(header: &wire::Header, content: Content<'_>) -> String {
    let mut text = format!("{} {}", format!("{:?}", header.kind).to_lowercase(), header.id);
    match content {
        Content::Chunk(sequence, bytes) => write!(text, " #{sequence} ({} bytes)", bytes.len()).unwrap(),
        Content::Cancel(bytes) if !bytes.is_empty() => {
            text.push(' ');
            show(&Data::Bytes(bytes), &mut text);
        }
        Content::Cancel(_) => {}
        Content::Message { value, bytes, streamed, .. } => {
            message(value, &mut text);
            if streamed {
                text.push_str(" (streamed)");
            }
            if let Some(bytes) = bytes {
                text.push_str(" bytes ");
                show(&Data::Bytes(&bytes.bytes), &mut text);
            }
        }
    }
    text
}

/// Bytes that are whole frames of our own protocol, one entry per frame. Only bytes nothing knows the structure of
/// print as hex.
fn frames(bytes: &[u8]) -> Option<Vec<String>> {
    Wire::new().feed(bytes, &mut line).filter(|(_, unfinished)| unfinished.is_none()).map(|(frames, _)| frames)
}

/// A record value for reading: one entry per wire frame (decoded on from where `stream` stopped), none for null.
fn parts(bytes: &[u8], stream: &mut Wire) -> Vec<String> {
    let value = match body::decode_plain(bytes) {
        Ok(Data::Null) => return Vec::new(),
        Ok(Data::Bytes(v)) => match stream.feed(v, &mut line) {
            Some((mut frames, unfinished)) => {
                frames.extend(unfinished);
                return frames;
            }
            None => Data::Bytes(v),
        },
        Ok(value) => value,
        Err(_) => return vec!["<invalid value>".into()],
    };
    let mut out = String::new();
    show(&value, &mut out);
    vec![out]
}

/// The stream a record's bytes belong to, one per side of a connection: its descriptor when the record names one (a
/// helper capture's read/write), else its section (an app journal's lifetime); per op (and record part).
fn stream(record: &trace::Record) -> String {
    let fd = match body::decode_plain(&record.args) {
        Ok(Data::Object(fields)) => fields.iter().find_map(|(key, value)| match value {
            Data::Unsigned(fd) if *key == "fd" => Some(*fd),
            _ => None,
        }),
        _ => None,
    };
    format!("{} {}", fd.map_or(record.section.clone(), |fd| format!("fd {fd}")), record.op)
}

fn text(bytes: &[u8]) -> String {
    let mut out = String::new();
    match body::decode_plain(bytes) {
        Ok(value) => show(&value, &mut out),
        Err(_) => out.push_str("<invalid value>"),
    }
    out
}

/// Every capture under `path` (or the file itself), sorted.
fn captures(path: &Path) -> io::Result<Vec<PathBuf>> {
    if path.is_file() {
        return Ok(vec![path.into()]);
    }
    let mut out = Vec::new();
    for entry in std::fs::read_dir(path)? {
        let path = entry?.path();
        if path.is_dir() {
            out.extend(captures(&path)?);
        } else if path.to_string_lossy().ends_with(".rpl.bz2") && !path.to_string_lossy().contains(".mismatch-") {
            out.push(path);
        }
    }
    out.sort();
    Ok(out)
}

fn take(bytes: &[u8], at: &mut usize, count: usize) -> io::Result<usize> {
    let start = *at;
    *at = start
        .checked_add(count)
        .filter(|end| *end <= bytes.len())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid capture value"))?;
    Ok(start)
}

fn count(bytes: &[u8], at: &mut usize) -> io::Result<usize> {
    let start = take(bytes, at, 4)?;
    Ok(u32::from_le_bytes(bytes[start..start + 4].try_into().unwrap()) as usize)
}

/// The text and bytes inside one encoded plain value, map keys included: (field, start, end).
/// Everything a capture holds as text or bytes is one of these, so a literal search here is
/// complete for our own formats (no escaping or encoding layer can hide a value).
fn leaves(bytes: &[u8], at: &mut usize, path: &str, out: &mut Vec<(String, usize, usize)>) -> io::Result<()> {
    match bytes[take(bytes, at, 1)?] {
        0..=2 => {}
        3..=5 => {
            take(bytes, at, 8)?;
        }
        6 | 11 => {
            let length = count(bytes, at)?;
            let start = take(bytes, at, length)?;
            out.push((path.into(), start, start + length));
        }
        7 => {
            for index in 0..count(bytes, at)? {
                leaves(bytes, at, &format!("{path}[{index}]"), out)?;
            }
        }
        8 => {
            for _ in 0..count(bytes, at)? {
                // Encoded values carry no generated names: every key is its own text.
                let name = take(bytes, at, 2)?;
                if bytes[name..name + 2] != [255, 255] {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "named key in a plain value"));
                }
                let length = count(bytes, at)?;
                let start = take(bytes, at, length)?;
                let key = String::from_utf8_lossy(&bytes[start..start + length]).into_owned();
                out.push((format!("{path}.{key} (key)"), start, start + length));
                leaves(bytes, at, &format!("{path}.{key}"), out)?;
            }
        }
        _ => return Err(io::Error::new(io::ErrorKind::InvalidData, "unknown capture value tag")),
    }
    Ok(())
}

/// Every (field, start, end) of a record's args and output.
fn spans(record: &trace::Record) -> io::Result<[Vec<(String, usize, usize)>; 2]> {
    let mut out = [Vec::new(), Vec::new()];
    for ((part, bytes), out) in [("args", &record.args), ("output", &record.output)].into_iter().zip(&mut out) {
        let mut at = 0;
        leaves(bytes, &mut at, part, out)?;
        if at != bytes.len() {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "trailing capture value bytes"));
        }
    }
    Ok(out)
}

/// The needles file (docs/capture_scrub.md): one needle per line, `needle<TAB>value` for a value of its own; empty
/// lines and lines starting with `#` hold none.
fn needles(path: &str) -> io::Result<Vec<(Vec<u8>, Option<Vec<u8>>)>> {
    let mut out: Vec<(Vec<u8>, Option<Vec<u8>>)> = Vec::new();
    for (number, line) in std::fs::read(path)?.split(|byte| *byte == b'\n').enumerate() {
        if line.is_empty() || line[0] == b'#' {
            continue;
        }
        let refuse = |why: &str| io::Error::other(format!("{path}:{}: {why}", number + 1));
        let (needle, value) = match line.iter().position(|byte| *byte == b'\t') {
            Some(at) => (&line[..at], Some(line[at + 1..].to_vec())),
            None => (line, None),
        };
        if needle.is_empty() || out.iter().any(|(other, _)| other == needle) {
            return Err(refuse("an empty or repeated needle"));
        }
        // Lengths around a value are recorded too (wire frames, sizes, terminal columns).
        if value.as_ref().is_some_and(|value| value.len() != needle.len()) {
            return Err(refuse("a value needs its needle's byte length"));
        }
        out.push((needle.to_vec(), value));
    }
    Ok(out)
}

/// Needles by their first byte, longest first: the needle found at a position is the longest one there.
struct Matcher {
    needles: Vec<Vec<u8>>,
    first: Vec<Vec<usize>>,
    longest: usize,
}

impl Matcher {
    fn new(needles: Vec<Vec<u8>>) -> Self {
        let mut first = vec![Vec::new(); 256];
        for (index, needle) in needles.iter().enumerate() {
            first[needle[0] as usize].push(index);
        }
        for list in &mut first {
            list.sort_by_key(|&index| std::cmp::Reverse(needles[index].len()));
        }
        let longest = needles.iter().map(Vec::len).max().unwrap_or(0);
        Self { needles, first, longest }
    }

    fn at(&self, bytes: &[u8], at: usize) -> Option<usize> {
        self.first[bytes[at] as usize].iter().copied().find(|&index| bytes[at..].starts_with(&self.needles[index]))
    }
}

/// What a scan matched: a needle (its place among the needles), or a UUID or IPv4 address.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Hit {
    Needle(usize),
    Uuid,
    Ipv4,
}

/// Nothing continues the value on either side: no letter or digit next to it, and no `join` byte with a digit beyond.
fn alone(bytes: &[u8], at: usize, length: usize, join: Option<u8>) -> bool {
    let byte = |index: Option<usize>| index.and_then(|index| bytes.get(index)).copied();
    let continues = |next: Option<usize>, beyond: Option<usize>| byte(next).is_some_and(|next| {
        next.is_ascii_alphanumeric() || Some(next) == join && byte(beyond).is_some_and(|beyond| beyond.is_ascii_digit())
    });
    !continues(at.checked_sub(1), at.checked_sub(2)) && !continues(Some(at + length), Some(at + length + 1))
}

/// The length of a UUID (8-4-4-4-12 hex digits) at `at`.
fn uuid(bytes: &[u8], at: usize) -> Option<usize> {
    let text = bytes.get(at..at + 36)?;
    let shape = text.iter().enumerate().all(|(index, byte)| match index {
        8 | 13 | 18 | 23 => *byte == b'-',
        _ => byte.is_ascii_hexdigit(),
    });
    (shape && alone(bytes, at, 36, None)).then_some(36)
}

/// The length of a machine's IPv4 address at `at`: four decimal octets up to 255 without leading zeros, not inside a
/// longer dotted number (a version such as 1.2.3.4.5 or 2.1.283.4a4). 0.x, 127.x (loopback) and 224 and up name no
/// machine.
fn ipv4(bytes: &[u8], at: usize) -> Option<usize> {
    let (mut end, mut first) = (at, 0);
    for index in 0..4 {
        if index > 0 {
            (bytes.get(end) == Some(&b'.')).then_some(())?;
            end += 1;
        }
        let digits = bytes[end..].iter().take(4).take_while(|byte| byte.is_ascii_digit()).count();
        let text = &bytes[end..end + digits];
        let octet = text.iter().fold(0, |octet, byte| octet * 10 + u32::from(byte - b'0'));
        if digits == 0 || digits > 3 || digits > 1 && text[0] == b'0' || octet > 255 {
            return None;
        }
        first = if index == 0 { octet } else { first };
        end += digits;
    }
    (!matches!(first, 0 | 127 | 224..) && alone(bytes, at, end - at, Some(b'.'))).then_some(end - at)
}

/// The length of a `kind` (UUID or IPv4 address) at `at`.
fn pattern(bytes: &[u8], at: usize, kind: Hit) -> Option<usize> {
    if kind == Hit::Uuid { uuid(bytes, at) } else { ipv4(bytes, at) }
}

/// Every match in `bytes` from left to right: at a position the longest needle, else one of `patterns`. `hit` sees each
/// (and may rewrite its bytes); scanning goes on after it, so a replacement never feeds another match.
fn scan(bytes: &mut [u8], matcher: &Matcher, patterns: &[Hit], hit: &mut dyn FnMut(Hit, &mut [u8], Range<usize>)) {
    let mut at = 0;
    for _ in 0..bytes.len() {
        if at >= bytes.len() {
            break;
        }
        let found = match matcher.at(bytes, at) {
            Some(index) => Some((Hit::Needle(index), matcher.needles[index].len())),
            None => patterns.iter().find_map(|&kind| Some((kind, pattern(bytes, at, kind)?))),
        };
        let Some((kind, length)) = found else {
            at += 1;
            continue;
        };
        hit(kind, bytes, at..at + length);
        at += length;
    }
}

/// Where a byte was recorded: (record, part: 0 args or 1 output, offset in it).
type Spot = (usize, usize, usize);

/// A match on a view: what it matched, where its first and last bytes were recorded, and how it lies there: across
/// pieces ("cut"), around bytes the view hides ("wrapped"), else as one run ("").
struct Match {
    hit: Hit,
    first: Spot,
    last: Spot,
    how: &'static str,
}

/// What one capture's views match: the needles and patterns, and the first byte of every match found so far (a screen
/// shows again what a byte view found: it is not a second match).
struct Find<'a> {
    matcher: &'a Matcher,
    patterns: &'a [Hit],
    seen: HashSet<Spot>,
}

/// A stream's views (docs/capture_scrub.md): needles on its unwrapped text, patterns (UUIDs, IPv4 addresses) on its
/// bytes as recorded, and needles on the screen it draws. Joined, each keeps what a match can start in (a needle's or a
/// UUID's bytes less one) and the screen; else every piece is matched alone.
struct Views {
    needles: View<Spot>,
    patterns: View<Spot>,
    screen: Option<Screen<Spot>>,
}

impl Views {
    fn new(matcher: &Matcher, joined: bool) -> Self {
        let keep = |length: usize| if joined { length.saturating_sub(1) } else { 0 };
        Self { needles: View::new(true, keep(matcher.longest)), patterns: View::new(false, keep(36)), screen: joined.then(Screen::new) }
    }

    /// The next piece (its bytes recorded at `at`): its matches (`cross`: only those also holding an earlier piece's
    /// byte) for `hit` to rewrite, then the needles its screen shows that no byte view found, and every byte that
    /// changed, where it was recorded.
    fn feed(&mut self, bytes: &mut [u8], at: &dyn Fn(usize) -> Spot, find: &mut Find, cross: bool,
            hit: &mut dyn FnMut(Hit, &mut [u8], Range<usize>)) -> (Vec<(Spot, u8)>, Vec<Match>) {
        let (matcher, patterns) = (find.matcher, find.patterns);
        let mut matches = Vec::new();
        let mut each = |view: &mut View<Spot>, kinds: &[Hit], bytes: &mut [u8]| view.feed(bytes, at, &mut |text, from, place| {
            scan(text, matcher, kinds, &mut |kind, text, range| {
                // A needle in the patterns' view is the needles' view's.
                if range.end <= from || cross && range.start >= from || !kinds.is_empty() && matches!(kind, Hit::Needle(_)) {
                    return;
                }
                let (first, last) = (place(range.start), place(range.end - 1));
                let run = (first.0, first.1) == (last.0, last.1) && last.2 - first.2 == range.len() - 1;
                matches.push(Match { hit: kind, first, last, how: if range.start < from { "cut" } else if run { "" } else { "wrapped" } });
                hit(kind, text, range);
            })
        });
        let mut changes = each(&mut self.needles, &[], bytes);
        if !patterns.is_empty() {
            changes.extend(each(&mut self.patterns, patterns, bytes));
        }
        find.seen.extend(matches.iter().map(|found| found.first));
        if let Some(screen) = &mut self.screen {
            let mut write = |spot: &Spot, byte: u8| changes.push((*spot, byte));
            for (hit, first, last) in drawn(screen, bytes, at, matcher, &mut find.seen, &|spot| *spot, hit, &mut write) {
                matches.push(Match { hit, first, last, how: "screen" });
            }
        }
        (changes, matches)
    }
}

/// The needles `screen` shows after the piece `bytes` (written at `at`) that no view found yet (`seen`, by a cell's
/// writer `key`): each replaced by `hit` on the row, every cell's new byte given to `write` with the cell's writer.
/// Returns each: what it matched, its first and last cell's writer.
#[allow(clippy::too_many_arguments)]
fn drawn<P: Clone>(screen: &mut Screen<P>, bytes: &[u8], at: &dyn Fn(usize) -> P, matcher: &Matcher, seen: &mut HashSet<Spot>,
                   key: &dyn Fn(&P) -> Spot, hit: &mut dyn FnMut(Hit, &mut [u8], Range<usize>),
                   write: &mut dyn FnMut(&P, u8)) -> Vec<(Hit, P, P)> {
    let mut out = Vec::new();
    for line in screen.feed(bytes, at) {
        let (mut text, mut found) = (line.text.clone(), Vec::new());
        scan(&mut text, matcher, &[], &mut |kind, text, range| {
            let mut writers = line.cells[range.clone()].iter().flatten();
            let (Some(first), Some(last)) = (writers.next().cloned(), line.cells[range.clone()].iter().flatten().last().cloned()) else { return };
            if seen.insert(key(&first)) {
                found.push((kind, range.clone(), first, last));
                hit(kind, text, range);
            }
        });
        for (kind, range, first, last) in found {
            for column in range.filter(|&column| text[column] != line.text[column]) {
                if let Some(writer) = &line.cells[column] {
                    write(writer, text[column]);
                }
                if let Some(row) = line.row {
                    screen.set(row, column, text[column]);
                }
            }
            out.push((kind, first, last));
        }
    }
    out
}

/// One unit of a protocol line's encoded field (base64: 3 bytes as 4 characters; hex pairs: 1 as 2): where each of
/// its characters was recorded, the characters as they are now, its bytes.
struct Unit {
    spots: Vec<Spot>,
    chars: Vec<u8>,
    bytes: Vec<u8>,
    base64: bool,
}

/// A decoded byte drawn on a screen: its unit and its place in it.
#[derive(Clone)]
struct Coded {
    unit: Rc<RefCell<Unit>>,
    index: usize,
}

impl Coded {
    /// A character this byte is written in (its writer for `Find::seen`).
    fn key(&self) -> Spot {
        let unit = self.unit.borrow();
        unit.spots[self.index.min(unit.spots.len() - 1)]
    }

    /// The byte is `byte` from now on: its unit encoded again, each character that changed where it was recorded.
    fn write(&self, byte: u8, out: &mut Vec<(Spot, u8)>) {
        let mut unit = self.unit.borrow_mut();
        unit.bytes[self.index] = byte;
        let chars = encode(unit.base64, &unit.bytes, &unit.chars);
        out.extend(unit.spots.iter().zip(&chars).zip(&unit.chars).filter(|((_, new), old)| new != old).map(|((spot, new), _)| (*spot, *new)));
        unit.chars = chars;
    }
}

/// One side of a connection as `replace` and `grep` read it: its views, its frames of ours, and where each of its
/// reads began (stream offset, where it was recorded).
struct Side {
    views: Views,
    wire: Wire,
    reads: Vec<(u64, Spot)>,
}

/// What one read or write held: every byte changed, the matches (one in a frame's leaf names the leaf), the places of
/// the frames it completed and their texts and bytes (by path).
type Fed = (Vec<(Spot, u8)>, Vec<(Option<String>, Match)>, Places, Vec<(String, Vec<u8>)>);

impl Side {
    fn new(matcher: &Matcher) -> Self {
        Self { views: Views::new(matcher, true), wire: Wire::new(), reads: Vec::new() }
    }

    /// Where stream offset `at` was recorded.
    fn place(&self, at: u64) -> Spot {
        let (start, (record, part, offset)) = self.reads[self.reads.partition_point(|read| read.0 <= at) - 1];
        (record, part, offset + (at - start) as usize)
    }

    /// The stream offset of the byte recorded at `spot`.
    fn offset(&self, (record, part, offset): Spot) -> u64 {
        let (start, (.., first)) = self.reads.iter().rev().find(|(_, read)| (read.0, read.1) == (record, part) && read.2 <= offset).unwrap();
        start + (offset - first) as u64
    }

    /// One read or write (recorded at `spot`): its matches, then every text and bytes of the frames it completes as a
    /// piece of its own view in `leaves` (by `name` and the leaf's path), matched across those pieces only; with `placed`
    /// the frames' places too (`grep` names where a finding is).
    fn feed(&mut self, name: &str, bytes: &mut [u8], spot: Spot, leaves: &mut HashMap<String, Views>, find: &mut Find,
            placed: bool, hit: &mut dyn FnMut(Hit, &mut [u8], Range<usize>)) -> Fed {
        self.reads.push((self.wire.fed, spot));
        let (mut changes, matches) = self.views.feed(bytes, &|at| (spot.0, spot.1, spot.2 + at), find, false, hit);
        let mut matches: Vec<_> = matches.into_iter().map(|found| (None, found)).collect();
        let frames = self.wire.feed(bytes, &mut |header, content| (if placed { paths(header, content) } else { Vec::new() }, texts(header, content)));
        let (mut places, mut values) = (Vec::new(), Vec::new());
        for (frame, texts) in frames.map_or_else(Vec::new, |(frames, _)| frames) {
            places.extend(frame);
            for (path, mut piece, ranges) in texts {
                let views = leaves.entry(format!("{name} {path}")).or_insert_with(|| Views::new(find.matcher, true));
                let (mine, found) = views.feed(&mut piece, &|index| self.place(position(&ranges, index)), find, true, hit);
                changes.extend(mine);
                matches.extend(found.into_iter().map(|found| (Some(path.clone()), found)));
                values.push((path, piece));
            }
        }
        (changes, matches, places, values)
    }
}

/// The stream offset of byte `index` of a value whose bytes lie at `ranges` of the stream.
fn position(ranges: &[Range<u64>], index: usize) -> u64 {
    let mut index = index as u64;
    for range in ranges {
        if index < range.end - range.start {
            return range.start + index;
        }
        index -= range.end - range.start;
    }
    unreachable!("a byte past its value")
}

/// Runs of text that look like bytes another program wrote as text, 16 bytes and longer, by their shape alone (never
/// decoded): hex digits between other letters and digits with a letter (all digits is a number), hex byte pairs between
/// spaces (tmux send-keys -H), base64 with its padding mixing upper and lower case letters and digits. A base64 run
/// holding a word (a path's segment of 4 and more letters, 8 and more lower case letters) is text glued to the numbers
/// of escape sequences, unless it is long and whole quads: random base64 holds such a word by chance.
fn encoded(bytes: &[u8]) -> Vec<(Range<usize>, &'static str)> {
    let runs = |inside: &dyn Fn(usize) -> bool, width: usize| {
        let mut out: Vec<Range<usize>> = Vec::new();
        for at in (0..bytes.len()).filter(|at| inside(*at)) {
            match out.last_mut() {
                Some(run) if run.end == at => run.end = at + width,
                _ => out.push(at..at + width),
            }
        }
        out
    };
    let hex = runs(&|at| bytes[at].is_ascii_alphanumeric(), 1).into_iter().filter(|run| bytes[run.clone()].iter().all(u8::is_ascii_hexdigit));
    let pairs = runs(&|at| bytes[at..].len() >= 2 && bytes[at..at + 2].iter().all(u8::is_ascii_hexdigit)
        && (at == 0 || bytes[at - 1] == b' ') && bytes.get(at + 2).is_none_or(|byte| *byte == b' '), 3);
    let base64 = runs(&|at| bytes[at].is_ascii_alphanumeric() || matches!(bytes[at], b'+' | b'/'), 1).into_iter()
        .map(|run| run.start..run.end + bytes[run.end..].iter().take(2).take_while(|byte| **byte == b'=').count());
    let pairs = pairs.into_iter().map(|run| run.start..run.end - 1);
    let looks = |text: &[u8], kind: &str| {
        let has = |class: fn(&u8) -> bool| text.iter().any(class);
        let word = text.split(|byte| *byte == b'/').skip(1).any(|part| part.len() >= 4 && part.iter().all(u8::is_ascii_alphabetic))
            || text.split(|byte| !byte.is_ascii_lowercase()).any(|part| part.len() >= 8);
        match kind {
            "hex" => has(u8::is_ascii_alphabetic),
            "pairs" => true,
            _ => has(u8::is_ascii_uppercase) && has(u8::is_ascii_lowercase) && has(u8::is_ascii_digit)
                && !text.iter().all(u8::is_ascii_hexdigit) && (!word || text.len() >= 64 && text.len() % 4 == 0),
        }
    };
    hex.map(|run| (run, "hex")).chain(pairs.map(|run| (run, "pairs"))).chain(base64.map(|run| (run, "base64")))
        .filter(|(run, kind)| run.len() >= 16 && looks(&bytes[run.clone()], kind)).collect()
}

/// A field path with its array indexes left out: `output.env[14][1]` groups as `output.env[][]`.
fn shape(field: &str) -> String {
    let mut inside = false;
    field.chars().filter(|letter| {
        inside = (inside || *letter == '[') && *letter != ']';
        !(inside && letter.is_ascii_digit())
    }).collect()
}

/// Runs `work` on every file, `jobs` at once; the results in the files' order.
fn parallel<T: Send>(files: &[PathBuf], jobs: usize, work: impl Fn(&Path) -> T + Sync) -> Vec<T> {
    let next = std::sync::atomic::AtomicUsize::new(0);
    let mut out: Vec<(usize, T)> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..jobs.clamp(1, files.len().max(1))).map(|_| scope.spawn(|| {
            let mut done = Vec::new();
            for _ in 0.. {
                let index = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let Some(file) = files.get(index) else { break };
                done.push((index, work(file)));
            }
            done
        })).collect();
        workers.into_iter().flat_map(|worker| worker.join().unwrap()).collect()
    });
    out.sort_by_key(|(index, _)| *index);
    out.into_iter().map(|(_, value)| value).collect()
}

/// A match for reading: the file, record and up to 80 bytes either side, escaped.
fn around(file: &Path, record: usize, bytes: &[u8], range: Range<usize>) -> String {
    let text = String::from_utf8_lossy(&bytes[range.start.saturating_sub(80)..bytes.len().min(range.end + 80)]);
    format!("{}:{record} {text:?}", file.display())
}

/// One side of a connection as lines of the protocols the helper speaks there in text, gathered across reads: herdr's
/// messages (one JSON object per line, multiplexers/herdr transport.rs) and tmux control-mode commands (a batch per line,
/// multiplexers/tmux client.rs). `reads`: where each read began (stream offset; record, part, offset in it), back to the
/// open line.
#[derive(Default)]
struct Lines {
    line: Body,
    skip: bool,
    fed: u64,
    reads: Vec<(u64, usize, usize, usize)>,
}

impl Lines {
    /// The lines one read (of `record`'s `part`, from `start`) completes. Any other line (not a JSON object, not a tmux
    /// `send-keys`, past herdr's 16 MiB) is dropped as it comes.
    fn feed(&mut self, bytes: &[u8], record: usize, part: usize, start: usize) -> Vec<Body> {
        let open = self.line.at.first().map_or(self.fed, |(_, at)| *at);
        self.reads.drain(..self.reads.partition_point(|read| read.0 <= open).saturating_sub(1));
        self.reads.push((self.fed, record, part, start));
        let mut out = Vec::new();
        for piece in bytes.split_inclusive(|byte| *byte == b'\n') {
            let (at, end) = (self.fed, piece.ends_with(b"\n"));
            self.fed += piece.len() as u64;
            if !self.skip {
                self.line.push(&piece[..piece.len() - usize::from(end)], at);
                let line = &self.line.bytes;
                let ours = line.starts_with(b"{") || line.starts_with(b"send-keys ") || b"send-keys ".starts_with(line);
                if !ours || line.len() > 16 << 20 {
                    (self.line, self.skip) = (Body::default(), true);
                }
            }
            if end {
                out.extend((!self.line.bytes.is_empty()).then(|| std::mem::take(&mut self.line)));
                self.skip = false;
            }
        }
        out
    }

    /// Where stream offset `at` was read: (record, part, offset in it).
    fn place(&self, at: u64) -> (usize, usize, usize) {
        let (start, record, part, offset) = self.reads[self.reads.partition_point(|read| read.0 <= at) - 1];
        (record, part, offset + (at - start) as usize)
    }

    /// After `record`, when it closes the descriptor of `name` ("fd N ..."): its number can come back for another
    /// connection, so an open line ends there (the stream's offsets go on).
    fn close(&mut self, name: &str, record: &trace::Record) {
        let fd = matches!(record.op.as_str(), "close" | "hangup").then(|| body::decode_plain(&record.args).ok()?.signed()).flatten();
        if fd.is_some_and(|fd| name.starts_with(&format!("fd {fd} "))) {
            (self.line, self.skip) = (Body::default(), false);
        }
    }
}

/// A value a protocol line carries as text: its place, its bytes (or why they are not decoded), and where each unit of
/// it is in the line: base64 (3 bytes in 4 characters) or hex pairs (a byte in 2).
struct Field {
    path: String,
    base64: bool,
    at: Vec<usize>,
    bytes: Result<Vec<u8>, String>,
}

impl Field {
    /// Bytes per unit, characters per unit.
    fn unit(&self) -> (usize, usize) {
        if self.base64 { (3, 4) } else { (1, 2) }
    }

    /// Its ranges in the line: runs of units, a space apart in hex pairs (the whole line when it is not decoded).
    fn spans(&self, line: usize) -> Vec<Range<usize>> {
        let (Ok(_), chars) = (&self.bytes, self.unit().1) else { return vec![0..line] };
        let mut out: Vec<Range<usize>> = Vec::new();
        for &at in &self.at {
            match out.last_mut() {
                Some(run) if at == run.end + usize::from(!self.base64) => run.end = at + chars,
                _ => out.push(at..at + chars),
            }
        }
        out
    }

    /// Each unit where it was recorded (`place`: a line offset's record, part and offset) and as it is in `bytes`
    /// (decoded, changed where a needle was), for writing changed units back and for a screen.
    fn units(&self, line: &Body, bytes: &[u8], place: &dyn Fn(u64) -> Spot) -> Vec<Rc<RefCell<Unit>>> {
        let (width, chars) = self.unit();
        bytes.chunks(width).enumerate().map(|(unit, now)| {
            let at = self.at[unit];
            let spots = (at..at + chars).map(|offset| place(line.stream(offset..offset + 1)[0].start)).collect();
            let old = &line.bytes[at..at + chars];
            let decoded = self.bytes.as_ref().ok().map(|bytes| &bytes[unit * width..(unit * width + width).min(bytes.len())]);
            let chars = if decoded == Some(now) { old.to_vec() } else { encode(self.base64, now, old) };
            Rc::new(RefCell::new(Unit { spots, chars, bytes: now.to_vec(), base64: self.base64 }))
        }).collect()
    }
}

/// One unit of `bytes` as text again (base64, or a hex pair in the case `old` was written in).
fn encode(base64: bool, bytes: &[u8], old: &[u8]) -> Vec<u8> {
    if base64 {
        return dispatch_helper_herdr::native::encode(bytes).into_bytes();
    }
    let text = format!("{:02x}", bytes[0]);
    if old.iter().any(u8::is_ascii_uppercase) { text.to_uppercase().into_bytes() } else { text.into_bytes() }
}

/// The values a protocol line carries as text. Herdr (multiplexers/herdr): base64 in `bytes` of the `terminal.frame` it
/// sends (native.rs) and of the `terminal.input` it is sent (controller.rs). Tmux (multiplexers/tmux commands.rs
/// `input`): `send-keys -H -t %N` and a byte per space and two hex digits, 256 bytes a command, a batch joined by " ; "
/// (client.rs); one value per pane and line.
fn fields(line: &[u8]) -> Vec<Field> {
    if line.starts_with(b"{") {
        let Ok(json) = Json::parse(line) else { return Vec::new() };
        let (Some(kind), Some(text)) = (json.root().get("type").and_then(|v| v.string()), json.root().get("bytes").and_then(|v| v.string())) else {
            return Vec::new();
        };
        if text.is_empty() || kind != "terminal.frame" && kind != "terminal.input" {
            return Vec::new();
        }
        let path = format!("herdr {kind} bytes (base64)");
        // Base64 needs no JSON escape: the field is its own bytes between quotes, else it is not decoded (and says so).
        let at = line.windows(text.len()).position(|window| window == text.as_bytes())
            .filter(|at| *at > 0 && line[at - 1] == b'"' && line.get(at + text.len()) == Some(&b'"'));
        return vec![match at {
            Some(at) => Field { path, base64: true, at: (at..at + text.len()).step_by(4).collect(),
                bytes: dispatch_helper_herdr::native::decode(text).map_err(|error| error.message) },
            None => Field { path, base64: true, at: Vec::new(), bytes: Err("escaped in its JSON".into()) },
        }];
    }
    // Commands are separated by " ; " outside double quotes (a literal's `\"` stays inside).
    let (mut commands, mut start, mut quoted, mut escaped) = (Vec::new(), 0, false, false);
    for (at, byte) in line.iter().enumerate() {
        match byte {
            _ if escaped => escaped = false,
            b'\\' if quoted => escaped = true,
            b'"' => quoted = !quoted,
            b';' if !quoted && at > 0 && line[at - 1] == b' ' && line.get(at + 1) == Some(&b' ') => {
                commands.push(start..at - 1);
                start = at + 2;
            }
            _ => {}
        }
    }
    commands.push(start..line.len());
    let mut out: Vec<(&[u8], Field)> = Vec::new();
    for command in commands {
        let Some(rest) = line[command.clone()].strip_prefix(b"send-keys -H -t %") else { continue };
        let pane = &rest[..rest.iter().take_while(|byte| byte.is_ascii_digit()).count()];
        if !out.iter().any(|(other, _)| *other == pane) {
            let path = "tmux send-keys -H (hex pairs)".into();
            out.push((pane, Field { path, base64: false, at: Vec::new(), bytes: Ok(Vec::new()) }));
        }
        let field = &mut out.iter_mut().find(|(other, _)| *other == pane).unwrap().1;
        for at in (command.end - rest.len() + pane.len()..command.end).step_by(3) {
            let pair = line.get(at + 1..at + 3).filter(|_| line[at] == b' ' && at + 3 <= command.end);
            match (pair.and_then(|pair| u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok()), &mut field.bytes) {
                (Some(byte), Ok(bytes)) => {
                    bytes.push(byte);
                    field.at.push(at + 1);
                }
                (None, bytes) => *bytes = Err("not hex pairs".into()),
                _ => {}
            }
        }
    }
    out.into_iter().map(|(_, field)| field).collect()
}

/// Places of our own structure, by offset: (range, whether it is a whole frame, path). Sorted by start, outer first, they
/// nest or are apart.
type Places = Vec<(Range<u64>, bool, String)>;

fn sort(places: &mut Places) {
    places.sort_by_key(|(range, top, path)| (range.start, std::cmp::Reverse(range.end), !*top, path.len()));
}

/// The texts and bytes of a decoded value of ours that are bytes of `source` (names the schema supplies are not), by
/// offset there, with their path ("params.records[].id", a key as "(key)"); bytes are looked into in turn.
fn walk(value: &Data<'_>, source: &[u8], path: &str, out: &mut Vec<(Range<usize>, String)>) {
    let span = |bytes: &[u8]| within(source, bytes);
    let here = if path.is_empty() { "value" } else { path };
    match value {
        Data::String(text) => out.extend(span(text.as_bytes()).map(|range| (range, here.to_string()))),
        Data::Bytes(bytes) => {
            let Some(range) = span(bytes) else { return };
            for (inner, _, deeper) in structure(bytes) {
                out.push((range.start + inner.start as usize..range.start + inner.end as usize, format!("{here} -> {deeper}")));
            }
            out.push((range, here.to_string()));
        }
        Data::Array(items) => {
            for item in items {
                walk(item, source, &format!("{path}[]"), out);
            }
        }
        Data::Object(fields) => {
            for (key, item) in fields {
                let path = if path.is_empty() { key.to_string() } else { format!("{path}.{key}") };
                out.extend(span(key.as_bytes()).map(|range| (range, format!("{path} (key)"))));
                walk(item, source, &path, out);
            }
        }
        _ => {}
    }
}

/// Where `bytes` (borrowed from `source`) are in it; None for none or other bytes.
fn within(source: &[u8], bytes: &[u8]) -> Option<Range<usize>> {
    let start = (bytes.as_ptr() as usize).wrapping_sub(source.as_ptr() as usize);
    (!bytes.is_empty() && start < source.len() && bytes.len() <= source.len() - start).then_some(start..start + bytes.len())
}

/// The texts and bytes of a decoded value of ours that are bytes of `source`, by offset there, with their path; an
/// object's `terminal` names the terminal its texts belong to (one view per terminal).
fn leaves_of(value: &Data<'_>, source: &[u8], path: &str, out: &mut Vec<(Range<usize>, String)>) {
    match value {
        Data::String(text) => out.extend(within(source, text.as_bytes()).map(|range| (range, path.to_string()))),
        Data::Bytes(bytes) => out.extend(within(source, bytes).map(|range| (range, path.to_string()))),
        Data::Array(items) => {
            for item in items {
                leaves_of(item, source, &format!("{path}[]"), out);
            }
        }
        Data::Object(fields) => {
            let terminal = fields.iter().find_map(|(key, value)| match value {
                Data::Unsigned(id) if *key == "terminal" => Some(*id),
                _ => None,
            });
            for (key, item) in fields {
                let path = terminal.map_or_else(|| format!("{path}.{key}"), |id| format!("{path}.{key} (terminal {id})"));
                leaves_of(item, source, &path, out);
            }
        }
        _ => {}
    }
}

/// The texts and bytes one whole frame's message holds (a stream's bytes beside it too), each named by the frame's kind
/// and method and its path, with its bytes and where they were in the stream.
fn texts(header: &wire::Header, content: Content<'_>) -> Vec<(String, Vec<u8>, Vec<Range<u64>>)> {
    let Content::Message { value, body, bytes, .. } = content else { return Vec::new() };
    let mut name = format!("{:?}", header.kind).to_lowercase();
    if let Some(Data::String(method)) = field(value, "method") {
        write!(name, " {method}").unwrap();
    }
    let mut found = Vec::new();
    leaves_of(value, &body.bytes, &name, &mut found);
    let mut out: Vec<_> = found.into_iter().map(|(range, path)| (path, body.bytes[range.clone()].to_vec(), body.stream(range))).collect();
    out.extend(bytes.map(|bytes| (format!("{name} stream"), bytes.bytes.clone(), bytes.stream(0..bytes.bytes.len()))));
    out
}

/// The places in one whole frame of a stream, by stream position: the frame itself, and the texts and bytes its message
/// holds ("notify chat.records params.records[].id").
fn paths(header: &wire::Header, content: Content<'_>) -> Places {
    let Content::Message { value, body, bytes, streamed } = content else { return Vec::new() };
    let mut name = format!("{:?}", header.kind).to_lowercase();
    if let Some(Data::String(method)) = field(value, "method") {
        write!(name, " {method}").unwrap();
    }
    if streamed {
        name.push_str(" (streamed)");
    }
    let mut out: Places = body.stream(0..body.bytes.len()).into_iter().map(|range| (range, true, name.clone())).collect();
    if let Some(bytes) = bytes {
        out.extend(bytes.stream(0..bytes.bytes.len()).into_iter().map(|range| (range, true, format!("{name} stream"))));
    }
    let mut inner = Vec::new();
    walk(value, &body.bytes, "", &mut inner);
    for (range, path) in inner {
        out.extend(body.stream(range).into_iter().map(|range| (range, false, format!("{name} {path}"))));
    }
    out
}

/// The places of our own structure in `bytes`, as `show` reads them: whole frames of ours, else one of our plain values
/// (a hook question's body).
fn structure(bytes: &[u8]) -> Places {
    let mut out = match Wire::new().feed(bytes, &mut paths) {
        Some((frames, None)) => frames.concat(),
        _ => {
            let mut inner = Vec::new();
            if let Some(value) = body::decode_plain(bytes).ok().filter(|value| !matches!(value, Data::Bytes(_))) {
                walk(&value, bytes, "", &mut inner);
            }
            inner.into_iter().map(|(range, path)| (range.start as u64..range.end as u64, false, path)).collect()
        }
    };
    sort(&mut out);
    out
}

/// `place`, with the deepest place of `places` holding `range` (its first byte, else its last).
fn deeper(place: &str, places: &[(Range<u64>, bool, String)], range: Range<u64>) -> String {
    let inner = [range.start, range.end - 1].into_iter().find_map(|at| {
        // The innermost holds it with the latest start; past a whole frame not holding it, nothing earlier does.
        for (span, top, path) in places[..places.partition_point(|(span, ..)| span.start <= at)].iter().rev() {
            if span.end > at {
                return Some(path);
            }
            if *top {
                return None;
            }
        }
        None
    });
    inner.map_or_else(|| place.to_string(), |path| format!("{place} -> {path}"))
}

/// What grep finds: a needle (`how` it lies: whole, "cut" across records or "wrapped" by a terminal), or a text that looks
/// encoded; with the first such for reading.
enum Finding {
    Needle { needle: usize, how: &'static str, first: String },
    Encoded { kind: &'static str, text: Vec<u8>, first: String },
}

/// The texts in one value that look encoded; `record` tells where a position of it was recorded.
fn seek(bytes: &[u8], file: &Path, record: &dyn Fn(usize) -> usize) -> Vec<(Range<usize>, Finding)> {
    encoded(bytes).into_iter().map(|(run, kind)| {
        let first = format!("{}:{}", file.display(), record(run.start));
        (run.clone(), Finding::Encoded { kind, text: bytes[run].to_vec(), first })
    }).collect()
}

/// A needle `found` for reading: up to 80 bytes either side of its part in `bytes` (record `index`'s `part`), else its
/// record.
fn needle(found: &Match, file: &Path, index: usize, part: usize, bytes: &[u8]) -> Option<Finding> {
    let Hit::Needle(needle) = found.hit else { return None };
    let first = if (found.last.0, found.last.1) == (index, part) {
        let start = if (found.first.0, found.first.1) == (index, part) { found.first.2 } else { 0 };
        around(file, index, bytes, start..found.last.2 + 1)
    } else {
        format!("{}:{}", file.display(), found.last.0)
    };
    Some(Finding::Needle { needle, how: found.how, first })
}

/// What grep found in one capture: per (needle, place) the matches and the first one; per (place, text that looks
/// encoded) its kind, count and first record; per (place, line) of the values listed its count and first record; where
/// the file is cut.
#[derive(Default)]
struct Found {
    places: BTreeMap<(usize, String), (usize, String)>,
    encoded: BTreeMap<(String, Vec<u8>), (&'static str, usize, String)>,
    values: BTreeMap<(String, String), (usize, String)>,
    cut: Option<String>,
}

impl Found {
    /// The lines of a value at `place`, when it holds one of `shapes` (`--values`; a key is a name, not a value): digit
    /// runs as `#`, so a process list's pids and counters do not make each line its own.
    fn list(&mut self, shapes: &[String], place: &str, bytes: &[u8], first: &dyn Fn() -> String) {
        if place.ends_with(" (key)") || !shapes.iter().any(|shape| place.contains(shape.as_str())) {
            return;
        }
        for line in bytes.split(|byte| *byte == b'\n') {
            let (mut text, mut digits) = (String::new(), false);
            for char in String::from_utf8_lossy(line).trim().chars() {
                if !char.is_ascii_digit() {
                    text.push(char);
                } else if !digits {
                    text.push('#');
                }
                digits = char.is_ascii_digit();
            }
            if !text.is_empty() {
                self.values.entry((place.to_string(), text)).or_insert_with(|| (0, first())).0 += 1;
            }
        }
    }

    fn add(&mut self, place: String, finding: Finding) {
        match finding {
            Finding::Needle { needle, how, first } => {
                let place = if how.is_empty() { place } else { format!("{place} ({how})") };
                self.places.entry((needle, place)).or_insert((0, first)).0 += 1;
            }
            Finding::Encoded { kind, text, first } => self.encoded.entry((place, text)).or_insert((kind, 0, first)).1 += 1,
        }
    }
}

/// Every value of `file` searched as `replace` reads it (views: a stream across its records, our frames' texts across
/// frames, terminal wraps inside), and the values protocol lines carry as text decoded (`fields`); each finding placed
/// as deep as the structure goes (the record's section, op and field, then inside our frames and plain values: kind,
/// method, field; inside herdr's messages and tmux's commands: the field).
fn search(file: &Path, matcher: &Matcher, shapes: &[String]) -> io::Result<Found> {
    let mut found = Found::default();
    // A cut file (its process ended mid-write) is searched up to the cut.
    let (mut reader, _) = match trace::Reader::new(File::open(file)?, usize::MAX) {
        Ok(reader) => reader,
        Err(error) => {
            found.cut = Some(format!("cut before its header: {error}"));
            return Ok(found);
        }
    };
    // Per side (one side of a connection): its views and frames, where findings are (first and last byte, in order)
    // and the places holding them; what was found on sides is placed once the file is read (a frame completes with a
    // later read).
    let (mut sides, mut leaves, mut held, mut later): (HashMap<String, (Side, Vec<u64>)>, HashMap<String, Views>, HashMap<String, Places>, Vec<_>) = Default::default();
    let mut texts: HashMap<String, Lines> = HashMap::new();
    let (mut find, mut screens) = (Find { matcher, patterns: &[], seen: HashSet::new() }, HashMap::<String, Screen<Coded>>::new());
    let none = &mut |_: Hit, _: &mut [u8], _: Range<usize>| {};
    for index in 0.. {
        let mut record = match reader.next() {
            Ok(Some(record)) => record,
            Ok(None) => break,
            Err(error) => {
                found.cut = Some(format!("cut after record {index}: {error}"));
                break;
            }
        };
        for (name, lines) in &mut texts {
            lines.close(name, &record);
        }
        let spans = spans(&record)?;
        let section = record.section.split('/').next().unwrap_or_default().to_string();
        let key = stream(&record);
        for (part, spans) in spans.iter().enumerate() {
            let name = ["args", "output"][part];
            for (field, start, end) in spans {
                let (start, end) = (*start, *end);
                let place = format!("{section} {} {}", record.op, shape(field));
                let bytes = if part == 0 { &mut record.args } else { &mut record.output };
                // The whole value is bytes (tag 11): what was read or written on a stream.
                let whole = field == name && bytes[0] == 11;
                let encoded = seek(&bytes[start..end], file, &|_| index);
                if whole && section == "mux" {
                    let name = format!("{key} {name}");
                    let lines = texts.entry(name.clone()).or_default();
                    for line in lines.feed(&bytes[start..end], index, 0, 0) {
                        for field in fields(&line.bytes) {
                            let (path, width) = match &field.bytes {
                                Ok(_) => (field.path.clone(), field.unit().0),
                                Err(why) => (format!("{} not decoded: {why}", field.path), 0),
                            };
                            for span in field.spans(line.bytes.len()) {
                                held.entry(name.clone()).or_default().extend(line.stream(span).into_iter().map(|range| (range, true, path.clone())));
                            }
                            let Ok(mut decoded) = field.bytes.clone() else { continue };
                            // A decoded byte's record: where its unit was read.
                            let record = |at: usize| lines.place(line.stream(field.at[at / width]..field.at[at / width] + 1)[0].start).0;
                            for (_, finding) in seek(&decoded, file, &record) {
                                found.add(format!("{place} -> {path}"), finding);
                            }
                            let units = field.units(&line, &decoded, &|at| lines.place(at));
                            let (_, matches) = Views::new(matcher, false).feed(&mut decoded, &|at| units[at / width].borrow().spots[0], &mut find, false, none);
                            let screen = screens.entry(format!("{name} {path}")).or_insert_with(Screen::new);
                            let coded = |at: usize| Coded { unit: units[at / width].clone(), index: at % width };
                            let shown = drawn(screen, &decoded, &coded, matcher, &mut find.seen, &|cell| cell.key(), none, &mut |_, _| {});
                            let shown = shown.into_iter().map(|(hit, first, last)| Match { hit, first: first.key(), last: last.key(), how: "screen" });
                            for m in matches.into_iter().chain(shown) {
                                let Hit::Needle(needle) = m.hit else { continue };
                                let first = format!("{}:{}", file.display(), m.last.0);
                                found.add(format!("{place} -> {path}"), Finding::Needle { needle, how: m.how, first });
                            }
                        }
                    }
                }
                if whole {
                    let name = format!("{key} {name}");
                    let (side, points) = sides.entry(name.clone()).or_insert_with(|| (Side::new(matcher), Vec::new()));
                    let at = side.wire.fed;
                    let (_, matches, places, values) = side.feed(&name, &mut bytes[start..end], (index, part, start), &mut leaves, &mut find, true, none);
                    for (path, value) in values {
                        found.list(shapes, &format!("{place} -> {path}"), &value, &|| format!("{}:{index}", file.display()));
                    }
                    let mut mine: Vec<u64> = encoded.iter().flat_map(|(range, _)| [at + range.start as u64, at + range.end as u64 - 1]).collect();
                    mine.extend(matches.iter().filter(|(leaf, _)| leaf.is_none()).flat_map(|(_, m)| [side.offset(m.first), side.offset(m.last)]));
                    mine.sort();
                    points.extend(mine);
                    // Everything found in a frame is known when it completes: only places holding a finding stay.
                    let holding = |range: &Range<u64>| points.get(points.partition_point(|at| *at < range.start)).is_some_and(|at| *at < range.end);
                    held.entry(name.clone()).or_default().extend(places.into_iter().filter(|(range, ..)| holding(range)));
                    for (range, finding) in encoded {
                        later.push((name.clone(), at + range.start as u64..at + range.end as u64, place.clone(), finding));
                    }
                    for (leaf, m) in matches {
                        let Some(finding) = needle(&m, file, index, part, bytes) else { continue };
                        match leaf {
                            Some(path) => found.add(format!("{place} -> {path}"), finding),
                            None => later.push((name.clone(), side.offset(m.first)..side.offset(m.last) + 1, place.clone(), finding)),
                        }
                    }
                } else {
                    // A value of its own: a terminal can wrap a needle inside it.
                    found.list(shapes, &place, &bytes[start..end], &|| format!("{}:{index}", file.display()));
                    let (_, matches) = Views::new(matcher, false).feed(&mut bytes[start..end], &|at| (index, part, start + at), &mut find, false, none);
                    let inner = structure(&bytes[start..end]);
                    for (range, finding) in encoded {
                        found.add(deeper(&place, &inner, range.start as u64..range.end as u64), finding);
                    }
                    for m in matches {
                        let range = (m.first.2 - start) as u64..(m.last.2 + 1 - start) as u64;
                        if let Some(finding) = needle(&m, file, index, part, bytes) {
                            found.add(deeper(&place, &inner, range), finding);
                        }
                    }
                }
            }
        }
    }
    for places in held.values_mut() {
        sort(places);
    }
    for (name, range, place, finding) in later {
        let place = deeper(&place, held.get(&name).map_or(&[], Vec::as_slice), range);
        // Herdr's base64 and tmux's hex pairs are understood (decoded, searched above): their text is no warning.
        if !(matches!(finding, Finding::Encoded { .. }) && (place.ends_with("(base64)") || place.ends_with("(hex pairs)"))) {
            found.add(place, finding);
        }
    }
    Ok(found)
}

/// Every text that looks encoded in the captures under `paths`, as it is (never decoded: needles are not searched inside
/// it), and every needle, literal, as `replace` reads values (views: also cut across records or wrapped); both by place
/// (section, op, field, and inside our own frames their kind, method and field).
fn grep(paths: &[String], needles: Vec<Vec<u8>>, shapes: &[String], limit: usize, jobs: usize) -> io::Result<()> {
    let matcher = Matcher::new(needles);
    let mut files = Vec::new();
    for path in paths {
        files.extend(captures(Path::new(path))?);
    }
    // (needle, place) -> count, files, first; (place, encoded text) -> kind, count, files, first; place -> files.
    let mut places: BTreeMap<(usize, String), (usize, usize, String)> = BTreeMap::new();
    let mut encoded: BTreeMap<(String, Vec<u8>), (&str, usize, usize, String)> = BTreeMap::new();
    let mut spread: BTreeMap<String, usize> = BTreeMap::new();
    let mut cut = 0;
    // (place, line) -> count, files, first: the values `--values` lists.
    let mut values: BTreeMap<(String, String), (usize, usize, String)> = BTreeMap::new();
    for (file, found) in files.iter().zip(parallel(&files, jobs, |file| search(file, &matcher, shapes))) {
        let found = found?;
        if let Some(why) = found.cut {
            println!("{}: {why}", file.display());
            cut += 1;
        }
        for (key, (count, first)) in found.places {
            let place = places.entry(key).or_insert((0, 0, first));
            (place.0, place.1) = (place.0 + count, place.1 + 1);
        }
        let mut mine: Vec<&String> = found.encoded.keys().map(|(place, _)| place).collect();
        mine.dedup();
        for place in mine {
            *spread.entry(place.clone()).or_default() += 1;
        }
        for (key, (kind, count, first)) in found.encoded {
            let entry = encoded.entry(key).or_insert((kind, 0, 0, first));
            (entry.1, entry.2) = (entry.1 + count, entry.2 + 1);
        }
        for (key, (count, first)) in found.values {
            let entry = values.entry(key).or_insert((0, 0, first));
            (entry.0, entry.1) = (entry.0 + count, entry.1 + 1);
        }
    }
    // The values listed, per place: every distinct line, the most frequent first. Judge each: private ones are needles.
    let mut listed: BTreeMap<&str, Vec<(&String, &(usize, usize, String))>> = BTreeMap::new();
    for ((place, line), entry) in &values {
        listed.entry(place).or_default().push((line, entry));
    }
    for shape in shapes {
        let places: Vec<_> = listed.iter().filter(|(place, _)| place.contains(shape.as_str())).collect();
        println!("values at places holding {shape:?}: {} distinct in {} places (digits as #)",
            places.iter().map(|(_, lines)| lines.len()).sum::<usize>(), places.len());
        for (place, lines) in places {
            let mut lines = lines.clone();
            lines.sort_by_key(|(line, (count, ..))| (std::cmp::Reverse(*count), *line));
            println!("  {place}: {} distinct", lines.len());
            for (line, (count, files, first)) in lines.iter().take(limit) {
                println!("    {count} times in {files} files, first {first}: {}", line.chars().take(200).collect::<String>());
            }
            if lines.len() > limit {
                println!("    ... {} more: raise --limit", lines.len() - limit);
            }
        }
    }
    // Up to 200 bytes of a text: `inspect` shows the whole record.
    let short = |bytes: &[u8]| format!("{:?}{}", String::from_utf8_lossy(&bytes[..bytes.len().min(200)]),
        if bytes.len() > 200 { format!(" ... ({} bytes)", bytes.len()) } else { String::new() });
    // Per place its texts, the most frequent first; the places holding most first.
    let mut groups: BTreeMap<&str, Vec<_>> = BTreeMap::new();
    for ((place, text), entry) in &encoded {
        groups.entry(place).or_default().push((text, entry));
    }
    let mut groups: Vec<_> = groups.into_iter().map(|(place, mut texts)| {
        texts.sort_by_key(|(_, entry)| std::cmp::Reverse(entry.1));
        (place, texts.iter().map(|(_, entry)| entry.1).sum::<usize>(), texts)
    }).collect();
    groups.sort_by_key(|(_, count, _)| std::cmp::Reverse(*count));
    println!("warning: {} texts look encoded (hex, hex pairs, base64) in {} places; needles are not searched inside them. \
        Judge each: other programs' output free of private data is fine, private data inside it or our own encoding is a finding",
        encoded.len(), groups.len());
    for (place, count, texts) in groups.iter().take(limit) {
        println!("  {place}: {} texts, {count} times in {} files", texts.len(), spread[*place]);
        for (text, (kind, count, files, first)) in texts.iter().take(limit) {
            println!("    {kind} {count} times in {files} files, first {first}\n      {}", short(text));
        }
        if texts.len() > limit {
            println!("    ... {} more texts: raise --limit", texts.len() - limit);
        }
    }
    if groups.len() > limit {
        println!("  ... {} more places: raise --limit", groups.len() - limit);
    }
    // The needles last: what a scrub must bring to 0 ends the output.
    for (index, needle) in matcher.needles.iter().enumerate() {
        let mut mine: Vec<_> = places.range((index, String::new())..(index + 1, String::new())).collect();
        let total: usize = mine.iter().map(|(_, (count, ..))| count).sum();
        println!("needle {} {:?}: {total} matches", index + 1, String::from_utf8_lossy(needle));
        mine.sort_by_key(|(_, (count, ..))| std::cmp::Reverse(*count));
        for ((_, place), (count, files, first)) in mine.iter().take(limit) {
            println!("  {count} in {files} files: {place}\n    first: {first}");
        }
        if mine.len() > limit {
            println!("  ... {} more places: raise --limit", mine.len() - limit);
        }
    }
    println!("{} captures searched{}", files.len(), if cut > 0 { format!("; {cut} cut") } else { String::new() });
    Ok(())
}

const KINDS: [&[u8]; 5] = [b"0123456789", b"abcdef", b"ghijklmnopqrstuvwxyz", b"ABCDEF", b"GHIJKLMNOPQRSTUVWXYZ"];

/// A replacement for `value` from the SplitMix64 stream of `seed`, drawn again until `taken` does not hold it. A
/// needle's letters and digits stay in their class (digits, a-f, g-z, A-F, G-Z) and other bytes stay: paths stay
/// paths, hex ids hex. A UUID gets new hex digits in its case (version and variant stay); an IPv4 address new octets
/// of the same digit count (a machine's address again: not 0, 127 or 224 and up first).
fn draw(value: &[u8], hit: Hit, seed: u64, taken: &HashSet<Vec<u8>>) -> Vec<u8> {
    let mut state = seed;
    let mut next = || {
        state = state.wrapping_add(0x9e3779b97f4a7c15);
        let mut draw = (state ^ (state >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        draw = (draw ^ (draw >> 27)).wrapping_mul(0x94d049bb133111eb);
        draw ^ (draw >> 31)
    };
    let hex: &[u8] = if value.iter().any(u8::is_ascii_uppercase) { b"0123456789ABCDEF" } else { b"0123456789abcdef" };
    for _ in 0.. {
        let replacement: Vec<u8> = match hit {
            Hit::Needle(_) => value.iter().map(|byte| {
                KINDS.iter().find(|kind| kind.contains(byte)).map_or(*byte, |kind| kind[(next() % kind.len() as u64) as usize])
            }).collect(),
            Hit::Uuid => value.iter().enumerate().map(|(index, byte)| match index {
                8 | 13 | 14 | 18 | 19 | 23 => *byte,
                _ => hex[(next() % 16) as usize],
            }).collect(),
            Hit::Ipv4 => value.split(|byte| *byte == b'.').enumerate().map(|(index, octet)| {
                let (low, high) = [(0, 9), (10, 99), (100, 255)][octet.len() - 1];
                let mut number = low + next() % (high - low + 1);
                for _ in 0.. {
                    if index > 0 || !matches!(number, 0 | 127 | 224..) {
                        break;
                    }
                    number = low + next() % (high - low + 1);
                }
                number.to_string()
            }).collect::<Vec<_>>().join(".").into_bytes(),
        };
        if !taken.contains(&replacement) {
            return replacement;
        }
    }
    unreachable!()
}

/// What `rewrite` made of one capture: whether it is an app journal, the matches per needle or pattern, the values
/// `found` lacked, the values it could not decode, and per whole value it changed the SHA-256 (hex) before and after.
type Rewritten = (bool, BTreeMap<Hit, usize>, Vec<(Hit, Vec<u8>)>, Vec<String>, Vec<(Vec<u8>, Vec<u8>)>);

/// One capture with its matches rewritten (docs/capture_scrub.md): needles by `replacements`, values of `patterns` by
/// `found` (a value it lacks stays and is listed, in the order met), as views read them (a stream across its records,
/// our frames' texts across frames, terminal wraps), and in the values protocol lines carry as text (`fields`: decoded,
/// encoded again in the same length), written to `output` when given. A match that reaches back into records already
/// written is written again in a second pass over the file.
fn rewrite(file: &Path, matcher: &Matcher, patterns: &[Hit], replacements: &[Vec<u8>], found: &HashMap<Vec<u8>, Vec<u8>>,
           output: Option<&Path>) -> io::Result<Rewritten> {
    let (rewritten, again) = pass(file, matcher, patterns, replacements, found, output, &BTreeMap::new())?;
    let Some(output) = output.filter(|_| !again.is_empty()) else { return Ok(rewritten) };
    std::fs::remove_file(output)?;
    let (_, still) = pass(file, matcher, patterns, replacements, found, Some(output), &again.into_iter().collect())?;
    if !still.is_empty() {
        return Err(io::Error::other(format!("{}: a match still reaches into written records after the second pass", file.display())));
    }
    Ok(rewritten)
}

/// One pass of `rewrite`, with `patches` (bytes of earlier matches) applied as records are read; returns what it made
/// and the bytes of matches that reached into records it had written.
fn pass(file: &Path, matcher: &Matcher, patterns: &[Hit], replacements: &[Vec<u8>], found: &HashMap<Vec<u8>, Vec<u8>>,
        output: Option<&Path>, patches: &BTreeMap<Spot, u8>) -> io::Result<(Rewritten, Vec<(Spot, u8)>)> {
    let (mut reader, header) = trace::Reader::new(File::open(file)?, usize::MAX)?;
    let mut writer = match output {
        Some(output) => {
            std::fs::DirBuilder::new().recursive(true).mode(0o700).create(output.parent().unwrap())?;
            Some(trace::Writer::new(File::options().write(true).create_new(true).mode(0o600).open(output)?, &header)?)
        }
        None => None,
    };
    let (mut counts, mut lacked, mut seen, mut undecoded, mut hashes) = (BTreeMap::new(), Vec::new(), HashSet::new(), Vec::new(), Vec::new());
    let mut hit = |hit: Hit, bytes: &mut [u8], range: Range<usize>| {
        *counts.entry(hit).or_default() += 1;
        let replacement = match hit {
            Hit::Needle(index) => Some(&replacements[index]),
            _ => found.get(&bytes[range.clone()]),
        };
        match replacement {
            Some(replacement) => bytes[range].copy_from_slice(replacement),
            None if seen.insert(bytes[range.clone()].to_vec()) => lacked.push((hit, bytes[range].to_vec())),
            None => {}
        }
    };
    // Records wait while a protocol line is open in one of them: a value in it can span reads.
    let (mut pending, mut texts): (std::collections::VecDeque<trace::Record>, HashMap<String, Lines>) = Default::default();
    let (mut sides, mut leaves, mut again): (HashMap<String, Side>, HashMap<String, Views>, Vec<(Spot, u8)>) = Default::default();
    let (mut find, mut screens) = (Find { matcher, patterns, seen: HashSet::new() }, HashMap::<String, Screen<Coded>>::new());
    for index in 0.. {
        let Some(mut record) = reader.next()? else { break };
        for (&(_, part, offset), &byte) in patches.range((index, 0, 0)..(index + 1, 0, 0)) {
            [&mut record.args, &mut record.output][part][offset] = byte;
        }
        for (name, lines) in &mut texts {
            lines.close(name, &record);
        }
        // Sections and ops are names the helper and the app chose, not values: a match there is refused.
        let mut named = false;
        for name in [&record.section, &record.op] {
            scan(&mut name.as_bytes().to_vec(), matcher, patterns, &mut |_, _, _| named = true);
        }
        if named {
            return Err(io::Error::other(format!("{}: a record's section or op holds a needle or pattern", file.display())));
        }
        let spans = spans(&record)?;
        let (mux, key, mut lines, mut changes) = (record.section.split('/').next() == Some("mux"), stream(&record), Vec::new(), Vec::new());
        for (part, spans) in spans.iter().enumerate() {
            let name = ["args", "output"][part];
            for (field, start, end) in spans {
                let (start, end) = (*start, *end);
                let bytes = if part == 0 { &mut record.args } else { &mut record.output };
                // The whole value is bytes (tag 11): what was read or written on a stream.
                if field == name && bytes[0] == 11 {
                    let name = format!("{key} {name}");
                    if mux {
                        let text = texts.entry(name.clone()).or_default();
                        lines.extend(text.feed(&bytes[start..end], index, part, start).into_iter().map(|line| (name.clone(), line)));
                    }
                    let side = sides.entry(name.clone()).or_insert_with(|| Side::new(matcher));
                    changes.push(side.feed(&name, &mut bytes[start..end], (index, part, start), &mut leaves, &mut find, false, &mut hit).0);
                } else {
                    // A value of its own (a terminal can wrap a needle inside it); a hash of it follows it.
                    let before = bytes[start..end].to_vec();
                    Views::new(matcher, false).feed(&mut bytes[start..end], &|at| (index, part, start + at), &mut find, false, &mut hit);
                    if bytes[start..end] != before[..] {
                        hashes.push((hex(&before), hex(&bytes[start..end])));
                    }
                }
            }
        }
        pending.push_back(record);
        for (name, line) in lines {
            for field in fields(&line.bytes) {
                let Ok(before) = &field.bytes else {
                    undecoded.push(format!("{}:{index} {}: {}", file.display(), field.path, field.bytes.as_ref().unwrap_err()));
                    continue;
                };
                let (mut bytes, width, place) = (before.clone(), field.unit().0, |at: u64| texts[&name].place(at));
                let recorded = field.units(&line, before, &place);
                Views::new(matcher, false).feed(&mut bytes, &|at| recorded[at / width].borrow().spots[0], &mut find, false, &mut hit);
                // Units of changed bytes are written again, encoded; the rest stays as recorded.
                let units = field.units(&line, &bytes, &place);
                changes.push(recorded.iter().zip(&units).flat_map(|(old, new)| {
                    let (old, new) = (old.borrow(), new.borrow());
                    old.spots.iter().zip(&old.chars).zip(&new.chars).filter(|((_, old), new)| old != new).map(|((spot, _), new)| (*spot, *new)).collect::<Vec<_>>()
                }).collect());
                // Needles the pane's screen shows: their units encoded again where they were recorded.
                let screen = screens.entry(format!("{name} {}", field.path)).or_insert_with(Screen::new);
                let mut set = Vec::new();
                drawn(screen, &bytes, &|at| Coded { unit: units[at / width].clone(), index: at % width }, matcher, &mut find.seen,
                      &|cell| cell.key(), &mut hit, &mut |cell, byte| cell.write(byte, &mut set));
                changes.push(set);
            }
        }
        // A match's bytes where they were recorded; one reaching into records already written goes, whole, to the
        // second pass.
        let first = index + 1 - pending.len();
        for set in changes {
            if set.iter().any(|((record, ..), _)| *record < first) {
                again.extend(set);
                continue;
            }
            for ((at, part, offset), byte) in set {
                let target = &mut pending[at - first];
                [&mut target.args, &mut target.output][part][offset] = byte;
            }
        }
        if texts.values().all(|text| text.line.bytes.is_empty()) {
            for record in pending.drain(..) {
                if let Some(writer) = &mut writer {
                    writer.push(&record)?;
                }
            }
        }
    }
    for record in pending {
        if let Some(writer) = &mut writer {
            writer.push(&record)?;
        }
    }
    if let Some(writer) = writer {
        writer.finish()?;
    }
    Ok(((header.layer == trace::Layer::App, counts, lacked, undecoded, hashes), again))
}

/// The SHA-256 of `bytes` in lowercase hex, as our code writes hashes of text (an SSH configuration's fingerprint).
fn hex(bytes: &[u8]) -> Vec<u8> {
    let mut hash = Sha256::new();
    hash.update(bytes);
    hash.finish().iter().flat_map(|byte| format!("{byte:02x}").into_bytes()).collect()
}

/// The helper replays of every helper capture under `directory`, written to `output`.
fn replays(directory: &str, output: &str) -> io::Result<Vec<batch::Replayed>> {
    let directory = std::fs::canonicalize(directory)?;
    batch::replay(&directory, &batch::helpers(&directory)?, Path::new(output), Duration::from_secs(20), true)
}

/// Scrub (docs/capture_scrub.md): every needle, and with `patterns` every UUID or IPv4 address, becomes a replacement
/// of the same byte length in every text/bytes value of every capture under DIR, literally (text another program
/// encoded stays as it is: `grep` lists it), written under OUT with the same layout. Equal length keeps every length prefix and wire frame intact. One run
/// gives a value the same replacement in every file: an app journal and its helper captures stay linked. Every helper
/// capture replays before and after; one the scrub broke prints why. App journals: their app replay tests.
fn replace(directory: &str, out: &str, list: Vec<(Vec<u8>, Option<Vec<u8>>)>, patterns: &[Hit], jobs: usize) -> io::Result<()> {
    let (root, target) = (Path::new(directory), Path::new(out));
    if target.exists() {
        return Err(io::Error::other("OUT must be a new directory"));
    }
    // A replacement is never a needle or another replacement; a needle given itself as its value is kept (a version
    // --ips would take for an address).
    let mut taken: HashSet<Vec<u8>> = list.iter().map(|(needle, _)| needle.clone()).collect();
    for (index, (needle, value)) in list.iter().enumerate().filter_map(|(index, (needle, value))| Some((index, (needle, value.as_ref()?)))) {
        if value != needle && !taken.insert(value.clone()) {
            return Err(io::Error::other(format!("needle {}: its value is a needle or another value", index + 1)));
        }
    }
    // Replacements come from a stream seeded by their place (a needle's among the needles, then pattern values in the
    // order met), never from the value: a replacement shows only the value's length and kinds, and a guess cannot be
    // checked against it. A needle with fewer possible replacements than there are needles could never get one.
    let mut replacements = Vec::new();
    for (index, (needle, value)) in list.iter().enumerate() {
        let space = needle.iter().filter_map(|byte| KINDS.iter().find(|kind| kind.contains(byte)))
            .fold(1u128, |space, kind| space.saturating_mul(kind.len() as u128));
        if value.is_none() && space <= 2 * list.len() as u128 {
            return Err(io::Error::other(format!("needle {} is too short for a distinct replacement: choose a longer one", index + 1)));
        }
        // A needle that is a UUID or IPv4 address is replaced by one (an address stays an address).
        let kind = [Hit::Uuid, Hit::Ipv4].into_iter().find(|&kind| pattern(needle, 0, kind) == Some(needle.len())).unwrap_or(Hit::Needle(index));
        let replacement = value.clone().unwrap_or_else(|| draw(needle, kind, index as u64, &taken));
        taken.insert(replacement.clone());
        replacements.push(replacement);
    }
    let matcher = Matcher::new(list.iter().map(|(needle, _)| needle.clone()).collect());
    let files = captures(root)?;
    let original = replays(directory, &format!("{out}.replay-original"))?;
    // The pattern values in the order met (file by file), then their replacements.
    let (mut found, mut order) = (HashMap::new(), Vec::new());
    if !patterns.is_empty() {
        for result in parallel(&files, jobs, |file| rewrite(file, &matcher, patterns, &replacements, &found, None)) {
            order.extend(result?.2);
        }
        let mut seen = HashSet::new();
        order.retain(|(_, value)| seen.insert(value.clone()));
        taken.extend(seen);
        for (index, (hit, value)) in order.iter().enumerate() {
            let replacement = draw(value, *hit, (list.len() + index) as u64, &taken);
            taken.insert(replacement.clone());
            found.insert(value.clone(), replacement);
        }
    }
    let (mut counts, mut journals) = (BTreeMap::new(), 0);
    let written = parallel(&files, jobs, |file| {
        rewrite(file, &matcher, patterns, &replacements, &found, Some(&target.join(file.strip_prefix(root).unwrap_or(file))))
    });
    let (mut undecoded, mut hashes) = (Vec::new(), BTreeMap::new());
    for result in written {
        let (app, mine, lacked, failed, changed) = result?;
        undecoded.extend(failed);
        if !lacked.is_empty() {
            return Err(io::Error::other("a pattern value appeared only on the second pass"));
        }
        journals += usize::from(app);
        for (hit, count) in mine {
            *counts.entry(hit).or_default() += count;
        }
        hashes.extend(changed);
    }
    // Our own hash of a changed value (an SSH configuration's fingerprint) becomes the hash of what it became: what the
    // app computes from the replaced text in replay, and the original's hash is gone.
    let (old, new): (Vec<Vec<u8>>, Vec<Vec<u8>>) = hashes.into_iter().unzip();
    let followed = Matcher::new(old);
    let outputs = if followed.needles.is_empty() { Vec::new() } else { captures(target)? };
    let mut occurrences = 0;
    for (file, result) in outputs.iter().zip(parallel(&outputs, jobs, |file| rewrite(file, &followed, &[], &new, &HashMap::new(), None))) {
        let count: usize = result?.1.values().sum();
        if count == 0 {
            continue;
        }
        occurrences += count;
        let partial = file.with_extension("hashes.partial");
        rewrite(file, &followed, &[], &new, &HashMap::new(), Some(&partial))?;
        std::fs::rename(&partial, file)?;
    }
    println!("hashes followed: {} changed values' SHA-256, {occurrences} occurrences", followed.needles.len());
    for (index, (needle, replacement)) in list.iter().map(|(needle, _)| needle).zip(&replacements).enumerate() {
        let count = counts.get(&Hit::Needle(index)).unwrap_or(&0);
        println!("needle {} ({} bytes) -> {}: {count} occurrences", index + 1, needle.len(), String::from_utf8_lossy(replacement));
    }
    // The values patterns found, to review (a version can look like an address: keep it with a needle `value<TAB>value`).
    for (hit, value) in &order {
        println!("{hit:?} {} -> {}", String::from_utf8_lossy(value), String::from_utf8_lossy(&found[value]));
    }
    for hit in patterns {
        let values = order.iter().filter(|(kind, _)| kind == hit).count();
        println!("{hit:?}: {values} values -> random ones, {} occurrences", counts.get(hit).unwrap_or(&0));
    }
    println!("{} captures written to {out} ({journals} app journals: their app replay tests check them)", files.len());
    // Never silently: a herdr value not decoded was not searched (`grep` shows its text).
    for entry in &undecoded {
        println!("NOT DECODED {entry}");
    }
    let candidate = replays(out, &format!("{out}.replay-candidate"))?;
    let before: HashMap<&Path, &str> = original.iter().map(|row| (row.capture.as_path(), row.status)).collect();
    let (mut broken, mut unchecked) = (0, 0);
    for row in &candidate {
        let was = before.get(row.capture.as_path()).copied().unwrap_or("missing");
        if was != "pass" {
            println!("NOT CHECKED {}: {was} before the scrub too", row.capture.display());
            unchecked += 1;
        } else if row.status != "pass" {
            // Why and where: the replay names the record and op it stopped at (inspect the original there).
            println!("BROKEN BY THE SCRUB {}: {}\n  {}", row.capture.display(), row.status, row.diagnostic.trim_end().replace('\n', "\n  "));
            broken += 1;
        }
    }
    println!("helper replay: {} of {} captures replay before and after the scrub; {broken} broken by it; {unchecked} not replaying before it",
        candidate.len() - broken - unchecked, candidate.len());
    if broken > 0 || unchecked > 0 {
        return Err(io::Error::other("not every helper capture replays before and after the scrub"));
    }
    Ok(())
}

/// One end of a connection, what it sent and what it read as one stream each. An app lifetime, a
/// helper's spawned child or a socket it connected is the parent end; a helper's stdio or a socket
/// it accepted is the child end. A hook server records what its senders sent as messages and what it
/// answered as replies (`bodies`), keyed by the sender's pid (`peer`) when the socket reports it; a
/// sender's connections to one socket are one end (`framed`: wire frames).
struct Stream {
    file: PathBuf,
    name: String,
    parent: bool,
    pid: Option<u64>,
    peer: Option<u64>,
    framed: bool,
    bodies: bool,
    /// Its capture is a hook sender's.
    sender: bool,
    sent: Vec<u8>,
    read: Vec<u8>,
}

/// A capture's connection ends: app lifetimes (out.wire / in.read, pid from in.started); a
/// helper's stdio (its pid fact), its spawned children (their pid) and its sockets (connect,
/// accept, datagram), from the read/write records on their descriptors until those close; its hook
/// server's messages and replies.
fn streams(file: &Path) -> io::Result<Vec<Stream>> {
    let (header, records) = trace::read(File::open(file)?, usize::MAX)?;
    let mut streams: Vec<Stream> = Vec::new();
    let mut lifetimes = std::collections::BTreeMap::new();
    // (descriptor, written) -> stream
    let mut ends = std::collections::BTreeMap::new();
    // hook sender pid or reply token -> stream
    let (mut peers, mut replies) = (std::collections::BTreeMap::new(), std::collections::BTreeMap::new());
    let mut own = None;
    let sender = records.iter().any(|record| record.section == "hook.sender");
    for record in &records {
        let args = body::decode_plain(&record.args).map_err(|_| io::Error::other("invalid args"))?;
        let output = body::decode_plain(&record.output).map_err(|_| io::Error::other("invalid output"))?;
        let mut open = |name: String, parent, pid, peer, bodies| {
            let name = format!("{} {name}", file.display()).trim_end().to_string();
            let framed = name.contains(" connect ");
            if let Some(index) = streams.iter().position(|stream| framed && stream.name == name) {
                return index;
            }
            streams.push(Stream { file: file.into(), name, parent, pid, peer, framed, bodies, sender, sent: Vec::new(), read: Vec::new() });
            streams.len() - 1
        };
        let fd = |value: &Data<'_>, name| value.get(name).and_then(Data::signed);
        let bytes = || output.bytes().unwrap_or_default().to_vec();
        match (header.layer, record.op.as_str()) {
            (trace::Layer::App, op @ ("out.wire" | "in.read" | "in.started")) => {
                let index = *lifetimes
                    .entry(record.section.clone())
                    .or_insert_with(|| open(record.section.clone(), true, None, None, false));
                match op {
                    "out.wire" => streams[index].sent.extend(args.bytes().unwrap_or_default()),
                    "in.read" => streams[index].read.extend(bytes()),
                    _ => streams[index].pid = output.unsigned(),
                }
            }
            (trace::Layer::Native, "pid") if record.section == "startup" => own = output.unsigned(),
            (trace::Layer::Native, op @ ("stdio" | "spawn" | "connect" | "accept")) if record.error.is_none() => {
                let (name, parent, pid, peer, input, output) = match op {
                    "stdio" => (String::new(), false, own, None, fd(&output, "read"), fd(&output, "write")),
                    "spawn" => {
                        let pid = output.get("pid").and_then(Data::unsigned);
                        (format!("spawn {}", pid.unwrap_or(0)), true, pid, None, fd(&output, "output"), fd(&output, "input"))
                    }
                    "connect" => (format!("connect {}", text(&record.args)), true, None, own, output.signed(), output.signed()),
                    _ => ("accept".into(), false, None, None, output.signed(), output.signed()),
                };
                let index = open(name, parent, pid, peer, false);
                ends.extend([((input, false), index), ((output, true), index)]);
            }
            (trace::Layer::Native, "datagram") if record.error.is_none() => {
                let index = open(format!("datagram {}", text(&record.args)), true, None, own, false);
                streams[index].sent.extend(args.get("bytes").and_then(Data::bytes).unwrap_or_default());
            }
            (trace::Layer::Native, "event") if output.get("kind").and_then(Data::string) == Some("hook") => {
                let peer = output.get("peer").and_then(Data::unsigned);
                let index = match peer {
                    Some(pid) => *peers.entry(pid).or_insert_with(|| open(format!("hook server, sender {pid}"), false, None, peer, true)),
                    None => open("hook server, datagram".into(), false, None, None, true),
                };
                streams[index].read.extend(output.get("message").and_then(Data::bytes).unwrap_or_default());
                if let Some(token) = output.get("reply").and_then(Data::unsigned) {
                    replies.insert(token, index);
                }
            }
            (trace::Layer::Native, "reply") => {
                if let Some(&index) = args.get("reply").and_then(Data::unsigned).and_then(|token| replies.get(&token)) {
                    streams[index].sent.extend(args.get("bytes").and_then(Data::bytes).unwrap_or_default());
                }
            }
            (trace::Layer::Native, op @ ("read" | "write")) if record.error.is_none() => {
                if let Some(&index) = ends.get(&(fd(&args, "fd"), op == "write")) {
                    let stream: &mut Stream = &mut streams[index];
                    if op == "write" { stream.sent.extend(bytes()) } else { stream.read.extend(bytes()) }
                }
            }
            // A closed descriptor's number can come back for another file.
            (trace::Layer::Native, "close" | "hangup") => {
                ends.retain(|(fd, _), _| *fd != args.signed());
            }
            _ => {}
        }
    }
    Ok(streams.into_iter().filter(|stream| !stream.sent.is_empty() || !stream.read.is_empty()).collect())
}

/// What a framed end carried as a hook server records it: the frame bodies (the server's empty acknowledgements,
/// which it keeps no record of, add nothing).
fn bodies(bytes: &[u8]) -> Vec<u8> {
    let (mut decoder, mut out) = (dispatch_helper_core::wire::Decoder::new(u32::MAX), Vec::new());
    let _ = decoder.feed(bytes, |event| {
        if let dispatch_helper_core::wire::Event::Data(data) = event {
            out.extend_from_slice(data)
        }
    });
    out
}

/// How a receiver's stream relates to what the sender sent: equal, a prefix (the receiver
/// stopped reading), or different from a byte on.
fn compare(sent: &[u8], read: &[u8]) -> (bool, String) {
    let same = sent.iter().zip(read).take_while(|(a, b)| a == b).count();
    if same == sent.len() && same == read.len() {
        (true, format!("equal ({same} bytes)"))
    } else if same == read.len() {
        (true, format!("read {same} of {} bytes sent (stopped reading)", sent.len()))
    } else {
        (false, format!("DIFFERENT from byte {same} (sent {}, read {})", sent.len(), read.len()))
    }
}

/// One case's verdict: some connection's ends differ; captures no paired end links to an app journal.
struct Checked {
    different: bool,
    unlinked: Vec<PathBuf>,
}

fn check(paths: &[PathBuf], out: &mut dyn io::Write) -> io::Result<Checked> {
    let mut all = Vec::new();
    for path in paths {
        for file in captures(path)? {
            all.extend(streams(&file)?);
        }
    }
    let (parents, children): (Vec<_>, Vec<_>) = all.into_iter().partition(|stream| stream.parent);
    // What each end of a pair sent and read, in the form both recorded: a hook server's side has
    // bodies, so the framed end is compared by its bodies.
    let view = |parent: &Stream, child: &Stream| {
        if !parent.framed || !child.bodies {
            return (parent.sent.clone(), parent.read.clone());
        }
        (bodies(&parent.sent), bodies(&parent.read))
    };
    // Pairs, best first: a local child is the parent's own child (same pid), a hook sender is the
    // server's peer (same pid). Over SSH the parent talks to ssh, so the remote helper is the one
    // whose streams agree with it.
    let common = |a: &[u8], b: &[u8]| a.iter().zip(b).take_while(|(a, b)| a == b).count();
    let mut pairs = Vec::new();
    for (left, parent) in parents.iter().enumerate() {
        for (right, child) in children.iter().enumerate().filter(|(_, child)| child.file != parent.file) {
            let (sent, read) = view(parent, child);
            let agree = compare(&sent, &child.read).0 && compare(&child.sent, &read).0;
            // A sender asks every candidate helper (question 1) and talks to one: same pid, the agreeing end.
            let same = parent.pid.is_some() && child.pid == parent.pid || parent.peer.is_some() && child.peer == parent.peer;
            let score = if same {
                if agree { usize::MAX } else { usize::MAX / 2 }
            } else if agree {
                common(&sent, &child.read) + common(&child.sent, &read)
            } else {
                0
            };
            pairs.push((score, left, right));
        }
    }
    pairs.sort_by(|a, b| b.cmp(a));
    let (mut used, mut matched) = (vec![false; children.len()], vec![None; parents.len()]);
    for (score, left, right) in pairs {
        if score > 0 && matched[left].is_none() && !used[right] {
            (matched[left], used[right]) = (Some(right), true);
        }
    }
    let mut failed = false;
    let mut links: Vec<(&Path, &Path)> = Vec::new();
    for (parent, paired) in parents.iter().zip(&matched) {
        let Some(index) = *paired else {
            // Most spawned children and sockets are not helpers (shells, tmux, agents): only app ends report.
            if !parent.name.contains(" spawn ") && !parent.name.contains(" connect ") {
                writeln!(out, "{}: no capture read what it sent ({} bytes)", parent.name, parent.sent.len())?;
            }
            continue;
        };
        let child = &children[index];
        let (sent, read) = view(parent, child);
        let (up, upward) = compare(&sent, &child.read);
        let (down, downward) = compare(&child.sent, &read);
        failed |= !up || !down;
        links.push((&parent.file, &child.file));
        writeln!(out, "{}\n  <-> {}\n  parent -> helper: {upward}\n  helper -> parent: {downward}", parent.name, child.name)?;
    }
    for (child, used) in children.iter().zip(used) {
        if !used {
            writeln!(out, "{}: no parent end in this group ({} bytes in, {} out)", child.name, child.read.len(), child.sent.len())?;
        }
    }
    // Every capture of the case is reached from its app journals through paired ends.
    let mut files: Vec<&Path> = parents.iter().chain(&children).map(|stream| stream.file.as_path()).collect();
    files.sort();
    files.dedup();
    let mut reached: Vec<&Path> = files.iter().copied().filter(|file| app(file)).collect();
    for _ in 0..files.len() {
        let next: Vec<&Path> = links.iter().filter_map(|&(a, b)| match (reached.contains(&a), reached.contains(&b)) {
            (true, false) => Some(b),
            (false, true) => Some(a),
            _ => None,
        }).collect();
        if next.is_empty() { break }
        reached.extend(next);
        reached.sort();
        reached.dedup();
    }
    // A hook sender that connected to no helper (a late hook: its route was gone) has nothing to pair.
    let alone = |file: &Path| parents.iter().chain(&children).filter(|stream| stream.file == file).all(|stream| stream.sender && !stream.parent);
    for file in files.iter().filter(|file| !reached.contains(file) && alone(file)) {
        writeln!(out, "hook sender that reached no helper: {}", file.display())?;
    }
    let unlinked: Vec<PathBuf> = if reached.is_empty() { Vec::new() } else {
        files.iter().filter(|file| !reached.contains(file) && !alone(file)).map(|file| file.to_path_buf()).collect()
    };
    if !reached.is_empty() {
        writeln!(out, "linked to the app journal: {} of {} captures", files.len() - unlinked.len(), files.len())?;
        for file in &unlinked {
            writeln!(out, "NOT LINKED {}", file.display())?;
        }
    }
    Ok(Checked { different: failed, unlinked })
}

/// An app journal (its header's layer).
fn app(file: &Path) -> bool {
    File::open(file).and_then(|file| trace::Reader::new(file, usize::MAX)).is_ok_and(|(_, header)| header.layer == trace::Layer::App)
}

/// The Swift file declaring each XCTest class (its superclass chain reaches XCTestCase), by class name.
fn classes(tests: &Path) -> io::Result<std::collections::BTreeMap<String, String>> {
    let mut declared = std::collections::BTreeMap::new();
    let mut directories = vec![tests.to_owned()];
    for index in 0.. {
        let Some(directory) = directories.get(index).cloned() else { break };
        for entry in std::fs::read_dir(&directory)? {
            let path = entry?.path();
            if path.is_dir() {
                directories.push(path);
                continue;
            }
            let (Some("swift"), Some(stem)) = (path.extension().and_then(|v| v.to_str()), path.file_stem().and_then(|v| v.to_str())) else { continue };
            for line in std::fs::read_to_string(&path)?.lines() {
                let Some(at) = line.find("class ").filter(|&at| at == 0 || line[..at].ends_with(' ')) else { continue };
                let rest = &line[at + 6..];
                let name: String = rest.chars().take_while(|c| c.is_alphanumeric() || *c == '_').collect();
                let Some(parent) = rest[name.len()..].trim_start().strip_prefix(':') else { continue };
                let parent: String = parent.trim_start().chars().take_while(|c| c.is_alphanumeric() || *c == '_').collect();
                declared.insert(name, (parent, stem.to_string()));
            }
        }
    }
    let test = |class: &String| {
        let mut name = class;
        for _ in 0..declared.len() {
            match declared.get(name) {
                Some((parent, _)) if parent == "XCTestCase" => return true,
                Some((parent, _)) => name = parent,
                None => return false,
            }
        }
        false
    };
    Ok(declared.iter().filter(|(name, _)| test(name)).map(|(name, (_, file))| (name.clone(), file.clone())).collect())
}

/// Stores a run's passed tests (STAGE/raw/cases.jsonl) in the corpus: REPLAYS/<TestFile>/<test>/<key>.rpl.bz2,
/// the app journal and every helper capture of the test, once each of its helper captures replays on
/// this helper and its files agree (`check`). Failed tests stay in the staging run only; `failed` places them
/// too, as recorded and unchecked (a run's own replay: they reproduce their failure). False: a passed
/// test was not stored.
fn store(stage: &Path, replays: &Path, tests: &Path, failed: bool) -> io::Result<bool> {
    let stage = std::fs::canonicalize(stage)?;
    let classes = classes(tests)?;
    let mut outcomes: std::collections::BTreeMap<String, Vec<bool>> = std::collections::BTreeMap::new();
    for line in std::fs::read_to_string(stage.join("raw/cases.jsonl"))?.lines() {
        let event = Json::parse(line.as_bytes()).map_err(|_| io::Error::other("invalid cases.jsonl line"))?;
        let event = event.root();
        if event.get("event").and_then(|v| v.string()) != Some("end") { continue }
        if let (Some(case), Some(outcome)) = (event.get("case").and_then(|v| v.string()), event.get("outcome").and_then(|v| v.string())) {
            outcomes.entry(case.to_string()).or_default().push(outcome == "passed");
        }
    }
    let results = stage.join(format!("store-{}", std::process::id()));
    std::fs::create_dir(&results)?;
    let (mut complete, mut placed, mut present) = (true, 0, 0);
    for (case, passes) in outcomes.iter() {
        let passed = passes.iter().all(|passed| *passed);
        if !passed && !failed {
            continue;
        }
        let mut parts = case.rsplit('/');
        let (Some(test), Some(class)) = (parts.next(), parts.next()) else { continue };
        let Some(file) = classes.get(class) else {
            println!("{case}: not stored, no test file declares {class}");
            complete = false;
            continue;
        };
        let target = replays.join(file).join(test);
        // One journal per test until variants can be told apart (a capture's content names its run's pids and
        // seeds): a test already in the corpus replays from it, so a later live run of it is not stored.
        if captures(&target).unwrap_or_default().iter().any(|file| app(file)) {
            println!("{case}: already in the corpus");
            continue;
        }
        let name = format!("{class}.{test}");
        let mut files = captures(&stage.join("app").join(&name)).unwrap_or_default();
        for entry in std::fs::read_dir(stage.join("raw"))? {
            let path = entry?.path();
            if path.file_name().and_then(|v| v.to_str()).is_some_and(|v| v.starts_with(&format!("{name}-")) && v.ends_with(".rpl.bz2")) {
                files.push(path);
            }
        }
        files.extend(captures(&stage.join("raw/remote").join(&name)).unwrap_or_default());
        // An empty capture: its helper ended before recording anything.
        files.retain(|file| file.metadata().is_ok_and(|meta| meta.len() > 0));
        let helpers: Vec<PathBuf> = files.iter().filter(|file| !app(file)).map(|file| file.strip_prefix(&stage).unwrap().to_owned()).collect();
        // A file that cannot be read (cut: its process still wrote it) keeps its test out, not the run.
        let verdict = (|| -> io::Result<(usize, Checked, Vec<String>)> {
            let keys = files.iter().map(|file| key(file)).collect::<io::Result<_>>()?;
            if !passed {
                return Ok((0, Checked { different: false, unlinked: Vec::new() }, keys));
            }
            let rows = batch::replay(&stage, &helpers, &results.join(&name), Duration::from_secs(20), true)?;
            let failed = rows.iter().filter(|row| row.status != "pass").count();
            Ok((failed, check(&files, &mut io::sink())?, keys))
        })();
        let (failed, checked, keys) = match verdict {
            Ok(verdict) => verdict,
            Err(error) => {
                println!("{case}: not stored ({error})");
                complete = false;
                continue;
            }
        };
        if failed > 0 || checked.different || !checked.unlinked.is_empty() {
            println!("{case}: not stored ({failed} helper replays failed, ends differ: {}, not linked: {})", checked.different, checked.unlinked.len());
            complete = false;
            continue;
        }
        std::fs::create_dir_all(&target)?;
        for (file, key) in files.iter().zip(&keys) {
            let destination = target.join(format!("{key}.rpl.bz2"));
            if destination.exists() {
                present += 1;
                continue;
            }
            let partial = target.join(format!(".{}.partial", std::process::id()));
            std::fs::copy(file, &partial)?;
            std::fs::rename(&partial, &destination)?;
            placed += 1;
        }
    }
    println!("stored {placed} new captures, {present} already present; replay results: {}", results.display());
    Ok(complete)
}

/// Replays every helper capture in the corpus on this helper; one that does not replay is dropped (listed;
/// --dry-run only lists). App journals are the app replay's to judge, except one of another protocol
/// version (the app reads only its own): dropped too.
fn prune(replays: &Path, dry: bool) -> io::Result<()> {
    let replays = std::fs::canonicalize(replays)?;
    for file in captures(&replays)? {
        let (_, header) = trace::Reader::new(File::open(&file)?, usize::MAX)?;
        if header.layer == trace::Layer::App && header.wire != dispatch_helper_core::wire::VERSION {
            println!("{} {}: app journal of protocol {} (now {})", if dry { "would drop" } else { "drop" }, file.display(), header.wire, dispatch_helper_core::wire::VERSION);
            if !dry {
                std::fs::remove_file(&file)?;
            }
        }
    }
    let output = replays.join(format!(".prune-{}", std::process::id()));
    let paths = batch::helpers(&replays)?;
    let rows = batch::replay(&replays, &paths, &output, Duration::from_secs(20), true)?;
    let dropped: Vec<_> = rows.iter().filter(|row| row.status != "pass").collect();
    for row in &dropped {
        println!("{} {}: {} {}", if dry { "would drop" } else { "drop" }, row.capture.display(), row.status, row.diagnostic.lines().next().unwrap_or(""));
        if !dry {
            std::fs::remove_file(replays.join(&row.capture))?;
        }
    }
    std::fs::remove_dir_all(&output)?;
    println!("{} of {} helper captures replay on {}", rows.len() - dropped.len(), rows.len(), std::env::current_exe()?.display());
    Ok(())
}

/// A capture's content key: what replay sees (layer; per record section, op, args, sequence, output,
/// error), not the bookkeeping clock and not the wire version (the same records from another build
/// are the same capture).
fn key(file: &Path) -> io::Result<String> {
    let (mut reader, header) = trace::Reader::new(File::open(file)?, usize::MAX)?;
    let mut hash = dispatch_helper_core::hash::Sha256::new();
    hash.update(format!("{:?}", header.layer).as_bytes());
    let mut field = |bytes: &[u8]| {
        hash.update(&(bytes.len() as u64).to_le_bytes());
        hash.update(bytes);
    };
    for _ in 0.. {
        let Some(record) = reader.next()? else { break };
        field(record.section.as_bytes());
        field(record.op.as_bytes());
        field(&record.args);
        field(&record.sequence.to_le_bytes());
        field(&record.output);
        field(&record.error.map_or(Vec::new(), |error| error.to_le_bytes().to_vec()));
    }
    Ok(hash.finish().iter().map(|byte| format!("{byte:02x}")).collect())
}

/// Takes `name VALUE` out of the arguments wherever it stands: what stays are the positional arguments.
fn option(args: &mut Vec<String>, name: &str) -> io::Result<Option<String>> {
    let Some(at) = args.iter().position(|arg| arg == name) else { return Ok(None) };
    args.remove(at);
    if at == args.len() {
        return Err(io::Error::other(format!("{name} needs a value")));
    }
    Ok(Some(args.remove(at)))
}

/// Takes a bare `name` out of the arguments wherever it stands: whether it was there.
fn flag(args: &mut Vec<String>, name: &str) -> bool {
    let count = args.len();
    args.retain(|arg| arg != name);
    args.len() < count
}

/// `--jobs N`: how many captures at once; every core by default.
fn jobs(args: &mut Vec<String>) -> io::Result<usize> {
    let jobs = option(args, "--jobs")?.map(|value| value.parse().map_err(|_| io::Error::other("--jobs N"))).transpose()?;
    Ok(jobs.unwrap_or_else(|| std::thread::available_parallelism().map_or(1, usize::from)))
}

/// Replays every helper capture under DIR on this helper; false if one did not pass or none ran.
fn replay(directory: &str, output: Option<String>, timeout: Duration, completion: bool) -> io::Result<bool> {
    let directory = std::fs::canonicalize(directory)?;
    let output = output.map_or_else(|| directory.join(format!("replay-results-{}", std::process::id())), PathBuf::from);
    let rows = batch::replay(&directory, &batch::helpers(&directory)?, &output, timeout, completion)?;
    let count = |status: &str| rows.iter().filter(|row| row.status == status).count();
    let (passed, failed, timeouts) = (count("pass"), count("fail"), count("timeout"));
    println!(
        "{passed} passed; {failed} failed; {timeouts} timed out; {} skipped; report: {}",
        rows.len() - passed - failed - timeouts,
        output.join("report.jsonl").display()
    );
    Ok(passed > 0 && passed == rows.len())
}

/// `dispatch-helper capture COMMAND ...`: `arguments` start with the command.
pub fn run(arguments: &[std::ffi::OsString]) -> io::Result<()> {
    // Piped into `head`: end quietly when the reader goes away, as other command line tools do (Rust ignores SIGPIPE,
    // so printing would panic). SIGPIPE is 13 and SIG_DFL 0 on Linux and macOS.
    unsafe extern "C" {
        fn signal(signal: i32, handler: usize) -> usize;
    }
    unsafe { signal(13, 0) };
    let mut args: Vec<String> = arguments.iter().map(|arg| arg.to_str().map(str::to_owned)).collect::<Option<_>>()
        .ok_or_else(|| io::Error::other("non-UTF-8 argument"))?;
    let usage = || io::Error::other(USAGE);
    let number = |name: &str, value: Option<String>| -> io::Result<Option<u64>> {
        value.map(|value| value.parse().map_err(|_| io::Error::other(format!("{name} N")))).transpose()
    };
    let command = if args.is_empty() { String::new() } else { args.remove(0) };
    match command.as_str() {
        "replay" => {
            let output = option(&mut args, "--output")?;
            let timeout = number("--timeout", option(&mut args, "--timeout")?)?.unwrap_or(20);
            let completion = match option(&mut args, "--completion")? {
                Some(value) if value == "required" => true,
                Some(_) => return Err(usage()),
                None => false,
            };
            let [directory] = &args[..] else { return Err(usage()) };
            if timeout == 0 {
                return Err(io::Error::other("--timeout must be positive"));
            }
            if !replay(directory, output, Duration::from_secs(timeout), completion)? {
                return Err(io::Error::other("batch replay failed; see report"));
            }
            Ok(())
        }
        "inspect" => {
            let limit = number("--limit", option(&mut args, "--limit")?)?.unwrap_or(u64::MAX);
            let from = number("--from", option(&mut args, "--from")?)?.unwrap_or(0);
            let [file] = &args[..] else { return Err(usage()) };
            let (mut reader, header) = trace::Reader::new(File::open(file)?, usize::MAX)?;
            println!("{:?} wire {}", header.layer, header.wire);
            let mut streams = HashMap::new();
            for index in 0.. {
                let Some(record) = reader.next()? else {
                    println!("complete");
                    return Ok(());
                };
                let key = stream(&record);
                let (asked, back) = (parts(&record.args, streams.entry(key.clone() + " args").or_insert_with(Wire::new)),
                    parts(&record.output, streams.entry(key + " output").or_insert_with(Wire::new)));
                if index < from {
                    continue;
                }
                if index - from >= limit {
                    println!("... more records: raise --limit or --from");
                    return Ok(());
                }
                // Record number (replay messages name the same), milliseconds, section, op; then what was asked and
                // `->` what came back. A record of several wire frames prints one line per frame: grep finds a method
                // with its record. Null values, sequence 0 and no error print nothing.
                let prefix = format!("{index} {}.{:03} {} {}", record.clock / 1_000_000, record.clock / 1_000 % 1_000, record.section, record.op);
                let suffix = format!("{}{}", if record.sequence > 0 { format!(" seq={}", record.sequence) } else { String::new() },
                    record.error.map_or(String::new(), |error| format!(" error={error}")));
                let items: Vec<String> = asked.iter().map(|item| format!(" {item}")).chain(back.iter().map(|item| format!(" -> {item}"))).collect();
                if asked.len() <= 1 && back.len() <= 1 {
                    println!("{prefix}{}{suffix}", items.concat());
                } else {
                    for item in items {
                        println!("{prefix}{item}{suffix}");
                    }
                }
            }
            Ok(())
        }
        "value" => {
            let [file] = &args[..] else { return Err(usage()) };
            println!("{}", text(&std::fs::read(file)?));
            Ok(())
        }
        "grep" => {
            let limit = number("--limit", option(&mut args, "--limit")?)?.unwrap_or(200);
            let jobs = jobs(&mut args)?;
            // Values listed at places holding a shape (each --values once), with or without needles.
            let mut shapes = Vec::new();
            for _ in 0..args.len() {
                let Some(shape) = option(&mut args, "--values")? else { break };
                shapes.push(shape);
            }
            // One needle before the paths, or a needles file.
            let list = match option(&mut args, "--needles")? {
                Some(path) => needles(&path)?.into_iter().map(|(needle, _)| needle).collect(),
                None if shapes.is_empty() && args.len() >= 2 && !args[0].is_empty() => vec![args.remove(0).into_bytes()],
                None if !shapes.is_empty() => Vec::new(),
                None => return Err(usage()),
            };
            if args.is_empty() {
                return Err(usage());
            }
            grep(&args, list, &shapes, limit as usize, jobs)
        }
        "check" if !args.is_empty() => {
            let checked = check(&args.iter().map(PathBuf::from).collect::<Vec<_>>(), &mut io::stdout())?;
            if checked.different {
                return Err(io::Error::other("connection ends differ"));
            }
            if !checked.unlinked.is_empty() {
                return Err(io::Error::other("captures not linked to the app journal"));
            }
            Ok(())
        }
        "store" => {
            let tests = option(&mut args, "--tests")?.ok_or_else(usage)?;
            let failed = flag(&mut args, "--failed");
            let [stage, replays] = &args[..] else { return Err(usage()) };
            if !store(Path::new(stage), Path::new(replays), Path::new(&tests), failed)? {
                return Err(io::Error::other("some passed tests were not stored"));
            }
            Ok(())
        }
        "prune" => {
            let dry = flag(&mut args, "--dry-run");
            let [replays] = &args[..] else { return Err(usage()) };
            prune(Path::new(replays), dry)
        }
        "key" if !args.is_empty() => {
            for path in &args {
                for file in captures(Path::new(path))? {
                    match key(&file) {
                        Ok(key) => println!("{key}\t{}", file.display()),
                        Err(error) => println!("error\t{}\t{error}", file.display()),
                    }
                }
            }
            Ok(())
        }
        "replace" => {
            let list = option(&mut args, "--needles")?.map(|path| needles(&path)).transpose()?.unwrap_or_default();
            let jobs = jobs(&mut args)?;
            let patterns: Vec<Hit> = [(flag(&mut args, "--uuids"), Hit::Uuid), (flag(&mut args, "--ips"), Hit::Ipv4)]
                .into_iter().filter_map(|(asked, hit)| asked.then_some(hit)).collect();
            let [directory, out] = &args[..] else { return Err(usage()) };
            if list.is_empty() && patterns.is_empty() {
                return Err(io::Error::other("nothing to replace: --needles FILE, --uuids or --ips"));
            }
            replace(directory, out, list, &patterns, jobs)
        }
        _ => Err(usage()),
    }
}

const USAGE: &str = "usage: dispatch-helper capture replay DIR [--output DIR] [--timeout SECONDS] [--completion required] | inspect FILE [--from N] [--limit N] | value FILE | grep NEEDLE PATH... [--limit N] [--jobs N] | grep PATH... [--needles FILE] [--values SHAPE]... [--limit N] [--jobs N] | replace DIR OUT [--needles FILE] [--uuids] [--ips] [--jobs N] | key PATH... | check PATH... | store STAGE REPLAYS --tests DIR [--failed] | prune REPLAYS [--dry-run]   (options go anywhere after the command)";
