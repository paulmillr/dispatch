//! Offline fixture promotion. Explicit aliases never enter diagnostics or live System IO.
use super::{capture, file};
pub mod decode;
pub mod materialize;
mod policy;
use crate::json::{Json, Value};
use std::{
    collections::BTreeMap,
    fs::File,
    io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write},
    os::unix::fs::OpenOptionsExt,
    path::Path,
};

/// Private originals and public aliases. Binary rules also match decoded hex tokens.
pub struct Rule<'a> {
    pub from: &'a str,
    pub to: &'a str,
    pub binary: bool,
}

pub struct Redactor {
    patterns: Vec<(Vec<u8>, Vec<u8>)>,
    width: usize,
    retained: usize,
    binary: Vec<Vec<u8>>,
}

#[derive(Debug, Default)]
pub struct Report {
    pub rows: u64,
    pub matches: u64,
}

#[derive(Clone, Copy)]
struct Site {
    at: u64,
    depth: usize,
}

#[derive(Clone)]
struct Span {
    start: usize,
    len: usize,
    site: Site,
}

#[derive(Default)]
struct Tail {
    bytes: Vec<u8>,
    sites: Vec<Span>,
    end: u64,
}

impl Tail {
    fn discard(&mut self, count: usize) {
        self.bytes.drain(..count);
        self.sites.retain_mut(|span| {
            let end = span.start + span.len;
            if end <= count {
                return false;
            }
            let first = span.start.max(count);
            span.site.at += ((first - span.start) << span.site.depth) as u64;
            span.start = first - count;
            span.len = end - first;
            true
        });
    }
}

fn failure(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn escaped(text: &str) -> Vec<u8> {
    let mut bytes = Vec::new();
    crate::wire::string(&mut bytes, text);
    bytes[1..bytes.len() - 1].to_vec()
}

fn encoded(mut bytes: Vec<u8>, depth: usize) -> Vec<u8> {
    for _ in 0..depth {
        bytes = capture::hex(&bytes).into_bytes();
    }
    bytes
}

impl Redactor {
    /// Alias widths must preserve text escaping and every native frame/IO byte count.
    /// Use key-qualified text for numeric identifiers; never globally replace a UID's digits.
    pub fn new(rules: &[Rule<'_>], retained: usize) -> io::Result<Self> {
        let mut patterns = BTreeMap::new();
        let mut binary = Vec::new();
        for rule in rules {
            let debug = (format!("{:?}", rule.from), format!("{:?}", rule.to));
            let mut forms = vec![
                (rule.from.as_bytes().to_vec(), rule.to.as_bytes().to_vec()),
                (escaped(rule.from), escaped(rule.to)),
                (
                    debug.0[1..debug.0.len() - 1].as_bytes().to_vec(),
                    debug.1[1..debug.1.len() - 1].as_bytes().to_vec(),
                ),
            ];
            if rule.binary {
                binary.push(capture::unhex(rule.from)?);
                forms.push((capture::unhex(rule.from)?, capture::unhex(rule.to)?));
            }
            for (from, to) in forms.clone() {
                if let (Ok(mut from), Ok(mut to)) = (String::from_utf8(from), String::from_utf8(to))
                {
                    for _ in 0..3 {
                        let pair = (escaped(&from), escaped(&to));
                        from = String::from_utf8(pair.0.clone()).unwrap();
                        to = String::from_utf8(pair.1.clone()).unwrap();
                        forms.push(pair);
                    }
                }
            }
            for (from, to) in forms {
                if from.is_empty() || from.len() != to.len() || from == to {
                    return Err(failure(
                        "redaction aliases must differ and preserve encoded width",
                    ));
                }
                for depth in 0..=3 {
                    let from = encoded(from.clone(), depth);
                    let to = encoded(to.clone(), depth);
                    if from.len() > retained {
                        return Err(failure("redaction pattern exceeds retention budget"));
                    }
                    if let Some(previous) = patterns.insert(from, to.clone()) {
                        if previous != to {
                            return Err(failure("conflicting redaction aliases"));
                        }
                    }
                }
            }
        }
        // An alias containing another original would leak it or change on a second pass.
        for to in patterns.values() {
            if patterns
                .keys()
                .any(|from| to.windows(from.len()).any(|part| part == from))
            {
                return Err(failure("redaction alias contains an original"));
            }
        }
        let width = patterns.keys().map(Vec::len).max().unwrap_or(1);
        let used: usize = patterns
            .iter()
            .map(|(from, to)| from.len() + to.len())
            .sum();
        if used >= retained {
            return Err(failure("redaction aliases exceed retention budget"));
        }
        Ok(Self {
            patterns: patterns.into_iter().collect(),
            width,
            retained: retained - used,
            binary,
        })
    }

    fn matches(
        &self,
        bytes: &[u8],
        mut visit: impl FnMut(usize, &[u8]) -> io::Result<()>,
    ) -> io::Result<u64> {
        let mut count = 0;
        for (from, to) in &self.patterns {
            for (offset, part) in bytes.windows(from.len()).enumerate() {
                if part == from {
                    visit(offset, to)?;
                    count += 1;
                }
            }
        }
        Ok(count)
    }

    fn replace(&self, bytes: &[u8]) -> io::Result<(Vec<u8>, u64)> {
        let mut output = bytes.to_vec();
        let mut changed = vec![false; bytes.len()];
        let count = self.matches(bytes, |offset, alias| {
            for (index, &byte) in alias.iter().enumerate() {
                let at = offset + index;
                if changed[at] && output[at] != byte {
                    return Err(failure("overlapping redaction aliases conflict"));
                }
                output[at] = byte;
                changed[at] = true;
            }
            Ok(())
        })?;
        Ok((output, count))
    }

    /// Whether discovery found values requiring aliases (no original values are exposed).
    pub fn private(&self) -> bool {
        !self.patterns.is_empty()
    }

    /// Apply the identical policy to companion requests, outputs, and source snapshots.
    pub fn bytes(&self, bytes: &[u8]) -> io::Result<Vec<u8>> {
        self.walk(bytes, 0)
    }

    fn walk(&self, bytes: &[u8], depth: usize) -> io::Result<Vec<u8>> {
        if depth > crate::wire::body::DEPTH || bytes.len() > self.retained {
            return Err(failure("scrub nesting or byte budget exceeded"));
        }
        if bytes
            .get(..13)
            .and_then(|b| crate::wire::Header::decode(b.try_into().ok()?, crate::wire::LIMIT).ok())
            .is_some_and(|header| {
                13 + header.len as usize <= bytes.len()
                    || bytes.get(13..21) == Some(crate::wire::body::SCHEMA.as_slice())
            })
        {
            return self.frames(bytes, depth);
        }
        if let Ok(document) = Json::parse(bytes) {
            let mut leaves = Vec::new();
            scalars(document.root(), None, &mut |key, value| {
                leaves.push((key, value));
                Ok(())
            })?;
            let mut output = bytes.to_vec();
            let mut at = 0;
            let mut index = 0;
            for _ in 0..bytes.len() {
                if at == bytes.len() {
                    break;
                }
                if bytes[at].is_ascii_whitespace() || b"{}[],:".contains(&bytes[at]) {
                    at += 1;
                    continue;
                }
                let start = at;
                if bytes[at] == b'"' {
                    at += 1;
                    for _ in at..bytes.len() {
                        if bytes[at] == b'\\' {
                            at += 2;
                        } else if bytes[at] == b'"' {
                            at += 1;
                            break;
                        } else {
                            at += 1;
                        }
                    }
                    let next = bytes[at..]
                        .iter()
                        .copied()
                        .find(|b| !b.is_ascii_whitespace());
                    if next == Some(b':') {
                        continue;
                    }
                } else {
                    for _ in at..bytes.len() {
                        if at == bytes.len()
                            || bytes[at].is_ascii_whitespace()
                            || b",]}".contains(&bytes[at])
                        {
                            break;
                        }
                        at += 1;
                    }
                }
                let (key, value) = *leaves.get(index).ok_or_else(file::invalid)?;
                let original = value.write().map_err(|_| file::invalid())?;
                let mut alias = Vec::new();
                self.value_at(value, key, &mut alias, depth + 1)?;
                if alias != original {
                    if alias.len() != at - start {
                        return Err(failure("scrub changes native JSON token width"));
                    }
                    output[start..at].copy_from_slice(&alias);
                }
                index += 1;
            }
            if index != leaves.len() {
                return Err(file::invalid());
            }
            return Ok(output);
        }
        if bytes.contains(&b'\n') {
            let mut output = Vec::with_capacity(bytes.len());
            for line in bytes.split_inclusive(|b| *b == b'\n') {
                if Json::parse(line).is_ok() {
                    output.extend(self.walk(line, depth + 1)?);
                } else {
                    output.extend(self.replace(line)?.0);
                }
            }
            return Ok(output);
        }
        let literal = self.replace(bytes)?.0;
        if std::str::from_utf8(bytes).is_err()
            && literal != bytes
            && !self.binary.iter().any(|from| from == bytes)
        {
            return Err(failure(
                "cannot safely mask private data in an opaque binary value",
            ));
        }
        if let Ok(text) = std::str::from_utf8(bytes) {
            if bytes.len() >= 2 && bytes.len() % 2 == 0 && bytes.iter().all(u8::is_ascii_hexdigit) {
                let decoded = capture::unhex(text)?;
                let alias = self.walk(&decoded, depth + 1)?;
                if alias != decoded {
                    let mut encoded = capture::hex(&alias).into_bytes();
                    for (b, old) in encoded.iter_mut().zip(bytes) {
                        if old.is_ascii_uppercase() {
                            b.make_ascii_uppercase();
                        }
                    }
                    return Ok(encoded);
                }
            }
            let string = crate::json::write(&crate::json::Data::String(text))
                .map_err(|_| file::invalid())?;
            let document = Json::parse(&string).map_err(|_| file::invalid())?;
            if let Ok(decoded) = crate::base64::decode(document.root()) {
                if !decoded.is_empty() && crate::base64::encode(&decoded) == text {
                    let alias = self.walk(&decoded, depth + 1)?;
                    if alias != decoded {
                        return Ok(crate::base64::encode(&alias).into_bytes());
                    }
                }
            }
        }
        Ok(literal)
    }

    fn body(&self, bytes: &[u8], depth: usize) -> io::Result<Vec<u8>> {
        crate::wire::body::rewrite(bytes, |key, data| {
            let bytes = crate::json::write(data)?;
            let document = Json::parse(&bytes)?;
            let mut output = Vec::new();
            self.value_at(document.root(), key, &mut output, depth + 1)
                .map_err(|error| crate::api::Error {
                    code: "scrub",
                    message: error.to_string(),
                })?;
            Ok(output)
        })
        .map_err(|_| {
            failure("cannot scrub captured binary leaf without changing its representation")
        })
    }

    fn frames(&self, bytes: &[u8], depth: usize) -> io::Result<Vec<u8>> {
        if bytes
            .get(..13)
            .and_then(|bytes| {
                crate::wire::Header::decode(bytes.try_into().ok()?, crate::wire::LIMIT).ok()
            })
            .is_none()
        {
            return self.replace(bytes).map(|(bytes, _)| bytes);
        }
        let mut output = bytes.to_vec();
        let mut chunks: BTreeMap<u64, (crate::wire::Collector, Vec<(usize, usize)>)> =
            BTreeMap::new();
        let mut at = 0;
        for _ in 0..bytes.len() {
            if at == bytes.len() {
                break;
            }
            let header = crate::wire::Header::decode(
                bytes
                    .get(at..at + 13)
                    .ok_or_else(file::invalid)?
                    .try_into()
                    .map_err(|_| file::invalid())?,
                crate::wire::LIMIT,
            )
            .map_err(|_| failure("invalid captured binary header"))?;
            let end = at + 13 + header.len as usize;
            let body = bytes.get(at + 13..end).ok_or_else(file::invalid)?;
            if header.kind == crate::wire::Kind::Chunk || chunks.contains_key(&header.id) {
                let (collector, ranges) = chunks.entry(header.id).or_insert_with(|| {
                    (
                        crate::wire::Collector::new(header.id, self.retained),
                        Vec::new(),
                    )
                });
                let received = collector
                    .push(header, body)
                    .map_err(|_| failure("invalid captured chunk sequence"))?;
                if header.kind == crate::wire::Kind::Chunk {
                    ranges.push((at + 21, body.len() - 8));
                }
                if let Some(received) = received {
                    let alias = match received {
                        crate::wire::Received::Json(value) => {
                            let _ = value; // Collector validates the original chunk sequence.
                            let original: Vec<u8> = ranges
                                .iter()
                                .flat_map(|&(start, len)| bytes[start..start + len].iter().copied())
                                .collect();
                            self.body(&original, depth + 1)?
                        }
                        crate::wire::Received::Binary { bytes, .. } => {
                            self.walk(&bytes, depth + 1)?
                        }
                    };
                    if alias.len() != ranges.iter().map(|(_, len)| len).sum::<usize>() {
                        return Err(failure("scrub changes chunk content width"));
                    }
                    let mut offset = 0;
                    for &(start, len) in ranges.iter() {
                        output[start..start + len].copy_from_slice(&alias[offset..offset + len]);
                        offset += len;
                    }
                    chunks.remove(&header.id);
                }
                if header.kind == crate::wire::Kind::Chunk {
                    at = end;
                    continue;
                }
            }
            let frame = if header.kind == crate::wire::Kind::Cancel {
                crate::wire::packet(header.kind, header.id, body)
            } else {
                let value = self.body(body, depth + 1)?;
                crate::wire::packet(header.kind, header.id, &value)
            }
            .map_err(|_| failure("cannot encode scrubbed binary body"))?;
            if frame.len() != end - at {
                return Err(failure("scrub changes frame width"));
            }
            output[at..end].copy_from_slice(&frame);
            at = end;
        }
        if !chunks.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "incomplete captured chunk sequence",
            ));
        }

        Ok(output)
    }

    fn value(&self, value: Value<'_>, key: Option<&str>, output: &mut Vec<u8>) -> io::Result<()> {
        self.value_at(value, key, output, 0)
    }

    fn value_at(
        &self,
        value: Value<'_>,
        key: Option<&str>,
        output: &mut Vec<u8>,
        depth: usize,
    ) -> io::Result<()> {
        if let Some(items) = value.object() {
            output.push(b'{');
            for (index, (key, value)) in items.enumerate() {
                if index != 0 {
                    output.push(b',');
                }
                crate::wire::string(output, key);
                output.push(b':');
                self.value_at(value, Some(key), output, depth + 1)?;
            }
            output.push(b'}');
        } else if let Some(items) = value.array() {
            output.push(b'[');
            for (index, value) in items.enumerate() {
                if index != 0 {
                    output.push(b',');
                }
                self.value_at(value, None, output, depth + 1)?;
            }
            output.push(b']');
        } else {
            let mut bytes = Vec::new();
            if let Some(key) = key {
                crate::wire::string(&mut bytes, key);
                bytes.push(b':');
            }
            let prefix = bytes.len();
            if let Some(text) = value.string() {
                let alias = self.walk(text.as_bytes(), depth + 1)?;
                crate::wire::string(
                    &mut bytes,
                    std::str::from_utf8(&alias).map_err(|_| file::invalid())?,
                );
            } else {
                bytes.extend(
                    value
                        .write()
                        .map_err(|_| failure("cannot write captured value"))?,
                );
            }
            let (bytes, _) = self.replace(&bytes)?;
            output.extend_from_slice(&bytes[prefix..]);
        }
        Ok(())
    }

    /// New private output only. A failure leaves an incomplete private file, never a fixture.
    /// Validation proves the trace is readable; promotion additionally requires native replay.
    pub fn trace(&self, source: &Path, destination: &Path) -> io::Result<Report> {
        let mut input = BufReader::new(file::open(source)?);
        let mut output = File::options()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(destination)?;
        let result = (|| {
            let mut streams: BTreeMap<(String, String), Tail> = BTreeMap::new();
            let mut report = Report::default();
            loop {
                let mut line = Vec::new();
                (&mut input)
                    .take(file::LIMIT + 1)
                    .read_until(b'\n', &mut line)?;
                if line.is_empty() {
                    break;
                }
                if line.len() as u64 > file::LIMIT || line.last() != Some(&b'\n') {
                    return Err(failure(
                        "redaction row exceeds capture bound or is incomplete",
                    ));
                }
                let json =
                    Json::parse(&line).map_err(|_| failure("invalid redaction capture JSON"))?;
                let row = json.root();
                let section = file::field(row, "section", Value::string)?;
                let op = file::field(row, "op", Value::string)?;
                let args = file::field(row, "args", Value::string)?;
                let data = file::field(row, "data", Value::string)?;
                // Canonical outer JSON lets byte locations refer to the shared writer's spelling.
                let mut line = row
                    .write()
                    .map_err(|_| failure("redaction JSON writing failed"))?;
                line.push(b'\n');
                let start = output.seek(SeekFrom::End(0))?;
                let (redacted, count) = if section == "ui" && matches!(op, "read" | "write")
                    || section == "startup" && op == "account"
                {
                    (line.clone(), 0)
                } else {
                    let changed = self.walk(&line, 0)?;
                    let count = line.iter().zip(&changed).filter(|(a, b)| a != b).count() as u64;
                    (changed, count)
                };
                output.write_all(&redacted)?;
                report.matches += count;
                report.rows += 1;
                let completion = capture::unhex(data)?;
                let json =
                    Json::parse(&completion).map_err(|_| failure("invalid capture completion"))?;
                let value = json.root().get("output");
                let payload = value.and_then(|v| v.get("bytes")).and_then(Value::string);
                if op == "close" {
                    streams.remove(&(section.to_owned(), format!("read {args}")));
                    streams.remove(&(section.to_owned(), format!("write {args}")));
                }
                let Some(payload) = payload else {
                    continue;
                };
                let bytes = capture::unhex(payload)?;
                if section == "startup" && op == "account" {
                    let uid = u32::from_le_bytes(
                        bytes
                            .get(..4)
                            .ok_or_else(file::invalid)?
                            .try_into()
                            .map_err(|_| file::invalid())?,
                    );
                    let document = Json::parse(format!("{{\"uid\":{uid}}}").as_bytes())
                        .map_err(|_| file::invalid())?;
                    let mut value = Vec::new();
                    self.value(document.root(), None, &mut value)?;
                    let document = Json::parse(&value).map_err(|_| file::invalid())?;
                    let uid = document
                        .root()
                        .get("uid")
                        .and_then(Value::unsigned)
                        .and_then(|uid| u32::try_from(uid).ok())
                        .ok_or_else(file::invalid)?;
                    let at = start
                        + locate(&line, "data", data)? as u64
                        + 2 * locate(&completion, "bytes", payload)? as u64;
                    let mut alias = uid.to_le_bytes().to_vec();
                    alias.extend(self.walk(&bytes[4..], 0)?);
                    let sites = [Span {
                        start: 0,
                        len: bytes.len(),
                        site: Site { at, depth: 2 },
                    }];
                    report.matches += self.patch(&mut output, &bytes, &alias, &sites)?;
                    continue;
                }
                let mut offset = None;
                let (key, site, consumed) = match op {
                    "read" => {
                        let fd = args.split_once(' ').ok_or_else(file::invalid)?.0;
                        let inner = locate(&completion, "bytes", payload)?;
                        let outer = locate(&line, "data", data)?;
                        (
                            format!("read {fd}"),
                            Site {
                                at: start + outer as u64 + 2 * inner as u64,
                                depth: 2,
                            },
                            bytes.len(),
                        )
                    }
                    "write" => {
                        let (fd, submitted) = args.split_once(' ').ok_or_else(file::invalid)?;
                        if let Some(length) = submitted.strip_prefix("len=") {
                            let length = length.parse::<usize>().map_err(|_| file::invalid())?;
                            if bytes.len() > length {
                                return Err(file::invalid());
                            }
                            let outer = locate(&line, "data", data)?;
                            let inner = locate(&completion, "bytes", payload)?;
                            let site = Site {
                                at: start + outer as u64 + 2 * inner as u64,
                                depth: 2,
                            };
                            let tail = streams
                                .entry((section.to_owned(), format!("write {fd}")))
                                .or_default();
                            report.matches += self.content(
                                &mut output,
                                tail,
                                &bytes,
                                site,
                                bytes.len(),
                                section == "ui",
                            )?;
                            self.budget(&streams)?;
                            continue;
                        }
                        let submitted = capture::unhex(submitted)?;
                        let consumed =
                            u64::from_le_bytes(bytes.try_into().map_err(|_| file::invalid())?);
                        let consumed = usize::try_from(consumed).map_err(|_| file::invalid())?;
                        if consumed > submitted.len() {
                            return Err(file::invalid());
                        }
                        let site = Site {
                            at: start + locate(&line, "args", args)? as u64 + fd.len() as u64 + 1,
                            depth: 1,
                        };
                        let tail = streams
                            .entry((section.to_owned(), format!("write {fd}")))
                            .or_default();
                        report.matches += self.content(
                            &mut output,
                            tail,
                            &submitted,
                            site,
                            consumed,
                            section == "ui",
                        )?;
                        self.budget(&streams)?;
                        continue;
                    }
                    "file.done"
                        if value.and_then(|v| v.get("kind")).and_then(Value::string)
                            == Some("read") =>
                    {
                        let (_, args) = args.split_once(' ').ok_or_else(file::invalid)?;
                        let args = args.strip_prefix("read ").ok_or_else(file::invalid)?;
                        let (args, _) = args.rsplit_once(' ').ok_or_else(file::invalid)?;
                        let (path, at) = args.rsplit_once(' ').ok_or_else(file::invalid)?;
                        offset = Some(at.parse::<u64>().map_err(|_| file::invalid())?);
                        let outer = locate(&line, "data", data)?;
                        let inner = locate(&completion, "bytes", payload)?;
                        (
                            format!("file {path}"),
                            Site {
                                at: start + outer as u64 + 2 * inner as u64,
                                depth: 2,
                            },
                            bytes.len(),
                        )
                    }
                    _ => continue,
                };
                let tail = streams.entry((section.to_owned(), key)).or_default();
                if let Some(at) = offset {
                    // Paging seeks and repeated ranges are valid; bytes across a gap are
                    // separate content, never a single string for redaction matching.
                    if at == 0 || at != tail.end {
                        *tail = Tail {
                            end: at,
                            ..Tail::default()
                        };
                    }
                }
                report.matches +=
                    self.content(&mut output, tail, &bytes, site, consumed, section == "ui")?;
                self.budget(&streams)?;
            }
            if streams
                .iter()
                .any(|((section, _), tail)| section == "ui" && !tail.bytes.is_empty())
            {
                return Err(failure("incomplete captured UI frame"));
            }
            output.flush()?;
            Ok(report)
        })();
        drop(output);
        if result.is_err() {
            std::fs::remove_file(destination)?;
        }
        result
    }

    fn patch(
        &self,
        output: &mut File,
        original: &[u8],
        alias: &[u8],
        sites: &[Span],
    ) -> io::Result<u64> {
        if original.len() != alias.len() {
            return Err(failure("scrub changes captured stream width"));
        }
        let mut count = 0;
        for span in sites {
            let end = (span.start + span.len).min(original.len());
            for index in span.start..end {
                if original[index] != alias[index] {
                    output.seek(SeekFrom::Start(
                        span.site.at + ((index - span.start) << span.site.depth) as u64,
                    ))?;
                    output.write_all(&encoded(vec![alias[index]], span.site.depth))?;
                    count += 1;
                }
            }
        }
        Ok(count)
    }

    fn content(
        &self,
        output: &mut File,
        tail: &mut Tail,
        bytes: &[u8],
        site: Site,
        consumed: usize,
        framed: bool,
    ) -> io::Result<u64> {
        if !framed {
            return self.stream(output, tail, bytes, site, consumed);
        }
        tail.sites.push(Span {
            start: tail.bytes.len(),
            len: consumed,
            site,
        });
        tail.bytes.extend_from_slice(&bytes[..consumed]);
        let mut at = 0;
        for _ in 0..tail.bytes.len() {
            let Some(bytes) = tail.bytes.get(at..at + 13) else {
                break;
            };
            let header = crate::wire::Header::decode(
                bytes.try_into().map_err(|_| file::invalid())?,
                crate::wire::LIMIT,
            )
            .map_err(|_| failure("invalid captured UI header"))?;
            let end = at + 13 + header.len as usize;
            if end > tail.bytes.len() {
                break;
            }
            at = end;
        }
        let aliases = match self.bytes(&tail.bytes[..at]) {
            Ok(aliases) => aliases,
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(0),
            Err(error) => return Err(error),
        };
        let count = self.patch(output, &tail.bytes[..at], &aliases, &tail.sites)?;
        tail.discard(at);
        Ok(count)
    }

    fn budget(&self, streams: &BTreeMap<(String, String), Tail>) -> io::Result<()> {
        let size: usize = streams
            .iter()
            .map(|((section, key), tail)| {
                section.len()
                    + key.len()
                    + tail.bytes.len()
                    + tail.sites.len() * std::mem::size_of::<Span>()
            })
            .sum();
        if size > self.retained {
            return Err(failure("redaction stream retention budget exceeded"));
        }
        Ok(())
    }

    fn stream(
        &self,
        output: &mut File,
        tail: &mut Tail,
        bytes: &[u8],
        site: Site,
        consumed: usize,
    ) -> io::Result<u64> {
        tail.sites.push(Span {
            start: tail.bytes.len(),
            len: consumed,
            site,
        });
        tail.bytes.extend_from_slice(&bytes[..consumed]);
        let json = tail
            .bytes
            .iter()
            .copied()
            .find(|b| !b.is_ascii_whitespace())
            .is_some_and(|b| matches!(b, b'{' | b'['));
        let complete = if Json::parse(&tail.bytes).is_ok() {
            tail.bytes.len()
        } else {
            tail.bytes
                .iter()
                .rposition(|b| *b == b'\n')
                .map_or(0, |at| at + 1)
        };
        let (alias, _) = self.replace(&tail.bytes)?;
        let mut count = self.patch(output, &tail.bytes, &alias, &tail.sites)?;
        if json {
            if complete != 0 {
                let alias = self.walk(&tail.bytes[..complete], 0)?;
                count += self.patch(output, &tail.bytes[..complete], &alias, &tail.sites)?;
                tail.discard(complete);
            }
        } else {
            tail.discard(tail.bytes.len().saturating_sub(self.width - 1));
        }
        tail.end = tail
            .end
            .checked_add(consumed as u64)
            .ok_or_else(file::invalid)?;
        Ok(count)
    }
}

fn locate(bytes: &[u8], name: &str, value: &str) -> io::Result<usize> {
    let prefix = format!("\"{name}\":\"");
    let positions: Vec<_> = bytes
        .windows(prefix.len())
        .enumerate()
        .filter(|(_, part)| *part == prefix.as_bytes())
        .map(|(i, _)| i + prefix.len())
        .collect();
    if positions.len() != 1 {
        return Err(failure("ambiguous capture field spelling"));
    }
    let at = positions[0];
    let value = escaped(value);
    if bytes.get(at..at + value.len()) != Some(value.as_slice()) {
        return Err(failure("unsupported capture field spelling"));
    }
    Ok(at)
}

fn scalars<'a>(
    value: Value<'a>,
    key: Option<&'a str>,
    visit: &mut impl FnMut(Option<&'a str>, Value<'a>) -> io::Result<()>,
) -> io::Result<()> {
    if let Some(items) = value.object() {
        for (key, value) in items {
            scalars(value, Some(key), visit)?;
        }
    } else if let Some(items) = value.array() {
        for value in items {
            scalars(value, key, visit)?;
        }
    } else {
        visit(key, value)?;
    }
    Ok(())
}
