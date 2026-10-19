//! The files plugin's archive layout: POSIX ustar headers with pax extended headers, written and read by hand
//! (the helper has no third-party crates). Only what files.pack writes is read back: regular files (`0`),
//! directories (`5`) and symbolic links (`2`), each optionally preceded by one pax `x` header carrying `path`,
//! `linkpath`, `size`, `mtime` (with nanoseconds), `uid` or `gid` when the ustar field cannot hold the value.
//! Anything else (hard links, devices, fifos, GNU long names, pax global headers) is refused as InvalidData:
//! the reader feeds extraction, so an entry it cannot describe exactly must not be guessed at.
use std::io::{self, Read, Write};

pub(crate) const BLOCK: usize = 512;
/// Largest value of an 11-digit octal field (size, mtime): 8 GiB - 1.
const OCTAL11: u64 = 0o77777777777;
/// Largest value of a 7-digit octal field (uid, gid).
const OCTAL7: u64 = 0o7777777;
/// A pax header larger than this is not one files.pack wrote (a path and a link target of PATH_MAX each fit).
const PAX_LIMIT: u64 = 64 << 10;
/// Linux's PATH_MAX and NAME_MAX, the larger of the two systems': no entry name, link target or name component
/// a file system here could hold is longer, so a longer one is refused before it is kept.
pub(crate) const PATH_MAX: usize = 4096;
pub(crate) const NAME_MAX: usize = 255;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    File,
    Directory,
    Symlink,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Header {
    /// Relative, '/'-separated, without a directory's trailing slash.
    pub name: Vec<u8>,
    pub kind: Kind,
    /// Permission bits (07777).
    pub mode: u32,
    pub uid: u64,
    pub gid: u64,
    /// Content length; 0 for directories and links.
    pub size: u64,
    /// Seconds since the epoch (negative before it) and nanoseconds 0..1e9.
    pub modified: (i64, u32),
    /// A symbolic link's target, stored as given.
    pub link: Vec<u8>,
}

fn refused(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("archive: {message}"))
}

/// `value` as zero-padded octal filling `field` but its last byte, which stays NUL.
fn octal(field: &mut [u8], value: u64) {
    let digits = field.len() - 1;
    let text = format!("{value:0digits$o}");
    field[..digits].copy_from_slice(text.as_bytes());
    field[digits] = 0;
}

/// One pax record, "<length> <key>=<value>\n", whose length counts its own digits.
fn record(records: &mut Vec<u8>, key: &str, value: &[u8]) {
    let body = key.len() + value.len() + 3;
    let mut length = body + 1;
    while body + length.to_string().len() != length {
        length = body + length.to_string().len();
    }
    records.extend_from_slice(length.to_string().as_bytes());
    records.push(b' ');
    records.extend_from_slice(key.as_bytes());
    records.push(b'=');
    records.extend_from_slice(value);
    records.push(b'\n');
}

/// Splits a name that does not fit the 100-byte name field into ustar's 155-byte prefix and the name.
fn split(name: &[u8]) -> Option<(&[u8], &[u8])> {
    name.iter().enumerate().filter(|(_, b)| **b == b'/').find_map(|(at, _)| {
        let (prefix, rest) = (&name[..at], &name[at + 1..]);
        (rest.len() <= 100 && !rest.is_empty() && !prefix.is_empty()).then_some((prefix, rest))
    }).filter(|(prefix, _)| prefix.len() <= 155)
}

/// One 512-byte ustar header block; its checksum is filled in last.
fn block(name: &[u8], prefix: &[u8], flag: u8, h: &Header, size: u64, link: &[u8]) -> [u8; BLOCK] {
    let mut b = [0u8; BLOCK];
    b[..name.len().min(100)].copy_from_slice(&name[..name.len().min(100)]);
    octal(&mut b[100..108], u64::from(h.mode & 0o7777));
    octal(&mut b[108..116], if h.uid > OCTAL7 { 0 } else { h.uid });
    octal(&mut b[116..124], if h.gid > OCTAL7 { 0 } else { h.gid });
    octal(&mut b[124..136], if size > OCTAL11 { 0 } else { size });
    octal(&mut b[136..148], u64::try_from(h.modified.0).unwrap_or(0).min(OCTAL11));
    b[156] = flag;
    b[157..157 + link.len().min(100)].copy_from_slice(&link[..link.len().min(100)]);
    b[257..263].copy_from_slice(b"ustar\0");
    b[263..265].copy_from_slice(b"00");
    b[345..345 + prefix.len()].copy_from_slice(prefix);
    b[148..156].fill(b' ');
    let sum: u64 = b.iter().map(|&v| u64::from(v)).sum();
    octal(&mut b[148..155], sum);
    b[155] = b' ';
    b
}

/// A pax mtime value: decimal seconds, with up to nine fraction digits when not whole.
fn time(seconds: i64, nanos: u32) -> String {
    let total = i128::from(seconds) * 1_000_000_000 + i128::from(nanos);
    let sign = if total < 0 { "-" } else { "" };
    let (whole, fraction) = (total.unsigned_abs() / 1_000_000_000, total.unsigned_abs() % 1_000_000_000);
    if fraction == 0 {
        return format!("{sign}{whole}");
    }
    let digits = format!("{fraction:09}");
    format!("{sign}{whole}.{}", digits.trim_end_matches('0'))
}

pub(crate) struct Writer<W: Write> {
    output: W,
    /// Content bytes still owed by the current file entry.
    owed: u64,
    /// The current file's length, for its padding.
    size: u64,
}

impl<W: Write> Writer<W> {
    pub fn new(output: W) -> Self {
        Self { output, owed: 0, size: 0 }
    }

    /// Starts an entry: its pax header when a value does not fit ustar, then its ustar header. A file's `size`
    /// content bytes follow through `write`.
    pub fn entry(&mut self, h: &Header) -> io::Result<()> {
        if self.owed != 0 {
            return Err(io::Error::other("archive entry started before the previous one's content ended"));
        }
        let mut name = h.name.clone();
        if h.kind == Kind::Directory {
            name.push(b'/');
        }
        let size = if h.kind == Kind::File { h.size } else { 0 };
        let mut records = Vec::new();
        let (field, prefix): (&[u8], &[u8]) = if name.len() <= 100 {
            (&name, &[])
        } else if let Some((prefix, rest)) = split(&name) {
            (rest, prefix)
        } else {
            record(&mut records, "path", &name);
            (&name, &[])
        };
        if h.link.len() > 100 {
            record(&mut records, "linkpath", &h.link);
        }
        if size > OCTAL11 {
            record(&mut records, "size", size.to_string().as_bytes());
        }
        if h.modified.1 != 0 || h.modified.0 < 0 || h.modified.0 as u64 > OCTAL11 {
            record(&mut records, "mtime", time(h.modified.0, h.modified.1).as_bytes());
        }
        if h.uid > OCTAL7 {
            record(&mut records, "uid", h.uid.to_string().as_bytes());
        }
        if h.gid > OCTAL7 {
            record(&mut records, "gid", h.gid.to_string().as_bytes());
        }
        let flag = match h.kind {
            Kind::File => b'0',
            Kind::Directory => b'5',
            Kind::Symlink => b'2',
        };
        if !records.is_empty() {
            // The pax header's own name only labels it for tools that list it; readers take `path`.
            let base = h.name.rsplit(|&b| b == b'/').next().unwrap_or(&h.name);
            let mut label = b"PaxHeaders/".to_vec();
            label.extend_from_slice(&base[..base.len().min(100 - label.len())]);
            let pax = Header { mode: 0o644, link: Vec::new(), ..h.clone() };
            self.output.write_all(&block(&label, &[], b'x', &pax, records.len() as u64, &[]))?;
            self.output.write_all(&records)?;
            self.pad(records.len() as u64)?;
        }
        let link: &[u8] = if h.kind == Kind::Symlink { &h.link } else { &[] };
        self.output.write_all(&block(field, prefix, flag, h, size, link))?;
        self.owed = size;
        self.size = size;
        Ok(())
    }

    fn pad(&mut self, length: u64) -> io::Result<()> {
        let rest = (BLOCK as u64 - length % BLOCK as u64) % BLOCK as u64;
        self.output.write_all(&[0; BLOCK][..rest as usize])
    }

    /// Two zero blocks end the archive; the output comes back for its own finish.
    pub fn finish(mut self) -> io::Result<W> {
        if self.owed != 0 {
            return Err(io::Error::other("archive ended inside a file's content"));
        }
        self.output.write_all(&[0; 2 * BLOCK])?;
        Ok(self.output)
    }
}

impl<W: Write> Write for Writer<W> {
    /// The current file's content; more than its header's size is refused.
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() as u64 > self.owed {
            return Err(io::Error::other("archive content longer than its header's size"));
        }
        self.output.write_all(bytes)?;
        self.owed -= bytes.len() as u64;
        if self.owed == 0 && self.size != 0 {
            let size = std::mem::take(&mut self.size);
            self.pad(size)?;
        }
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        self.output.flush()
    }
}

/// A numeric ustar field: octal digits (leading spaces or zeros, ending at NUL or space), or base-256 when its
/// first byte has the high bit (positive values only).
fn number(field: &[u8]) -> io::Result<u64> {
    if field.first().is_some_and(|b| b & 0x80 != 0) {
        if field[0] & 0x40 != 0 {
            return Err(refused("negative numeric field"));
        }
        let mut value: u64 = u64::from(field[0] & 0x3f);
        for &b in &field[1..] {
            value = value.checked_mul(256).and_then(|v| v.checked_add(u64::from(b))).ok_or_else(|| refused("numeric field overflows"))?;
        }
        return Ok(value);
    }
    let text = field.iter().skip_while(|&&b| b == b' ').take_while(|&&b| b != 0 && b != b' ');
    let mut value: u64 = 0;
    for &b in text {
        if !(b'0'..=b'7').contains(&b) {
            return Err(refused("numeric field is not octal"));
        }
        value = value.checked_mul(8).and_then(|v| v.checked_add(u64::from(b - b'0'))).ok_or_else(|| refused("numeric field overflows"))?;
    }
    Ok(value)
}

fn decimal(value: &[u8]) -> io::Result<u64> {
    std::str::from_utf8(value).ok().filter(|v| !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit())).and_then(|v| v.parse().ok()).ok_or_else(|| refused("pax number"))
}

/// A pax mtime: optional sign, decimal seconds, optional fraction (beyond nanoseconds truncated).
fn moment(value: &[u8]) -> io::Result<(i64, u32)> {
    let (negative, value) = match value.strip_prefix(b"-") {
        Some(rest) => (true, rest),
        None => (false, value),
    };
    let (whole, fraction) = match value.iter().position(|&b| b == b'.') {
        Some(at) => (&value[..at], &value[at + 1..]),
        None => (value, &b""[..]),
    };
    if !fraction.iter().all(u8::is_ascii_digit) {
        return Err(refused("pax mtime"));
    }
    let seconds = i64::try_from(decimal(whole)?).map_err(|_| refused("pax mtime"))?;
    let mut nanos: u32 = 0;
    for i in 0..9 {
        nanos = nanos * 10 + fraction.get(i).map_or(0, |b| u32::from(b - b'0'));
    }
    Ok(match (negative, nanos) {
        (false, _) => (seconds, nanos),
        (true, 0) => (-seconds, 0),
        (true, _) => (-seconds - 1, 1_000_000_000 - nanos),
    })
}

#[derive(Default)]
struct Pax {
    path: Option<Vec<u8>>,
    link: Option<Vec<u8>>,
    size: Option<u64>,
    modified: Option<(i64, u32)>,
    uid: Option<u64>,
    gid: Option<u64>,
}

fn pax(mut data: &[u8]) -> io::Result<Pax> {
    let mut pax = Pax::default();
    while !data.is_empty() {
        let space = data.iter().position(|&b| b == b' ').ok_or_else(|| refused("pax record"))?;
        let length = usize::try_from(decimal(&data[..space])?).map_err(|_| refused("pax record"))?;
        if length <= space + 1 || length > data.len() || data[length - 1] != b'\n' {
            return Err(refused("pax record length"));
        }
        let body = &data[space + 1..length - 1];
        let equals = body.iter().position(|&b| b == b'=').ok_or_else(|| refused("pax record"))?;
        let (key, value) = (&body[..equals], &body[equals + 1..]);
        if value.contains(&0) {
            return Err(refused("NUL in a pax value"));
        }
        match key {
            b"path" => pax.path = Some(value.to_vec()),
            b"linkpath" => pax.link = Some(value.to_vec()),
            b"size" => pax.size = Some(decimal(value)?),
            b"mtime" => pax.modified = Some(moment(value)?),
            b"uid" => pax.uid = Some(decimal(value)?),
            b"gid" => pax.gid = Some(decimal(value)?),
            // Times files.pack does not restore, comments, charsets, vendor keys.
            _ => {}
        }
        data = &data[length..];
    }
    Ok(pax)
}

/// A C string field: its bytes up to the first NUL.
fn text(field: &[u8]) -> &[u8] {
    &field[..field.iter().position(|&b| b == 0).unwrap_or(field.len())]
}

pub(crate) struct Reader<R: Read> {
    input: R,
    /// Content bytes of the current entry not yet read, then its padding.
    remaining: u64,
    padding: u64,
    ended: bool,
}

impl<R: Read> Reader<R> {
    pub fn new(input: R) -> Self {
        Self { input, remaining: 0, padding: 0, ended: false }
    }

    /// A whole block, or None at a clean end of input before its first byte.
    fn block(&mut self) -> io::Result<Option<[u8; BLOCK]>> {
        let mut b = [0u8; BLOCK];
        let mut filled = 0;
        while filled < BLOCK {
            match self.input.read(&mut b[filled..]) {
                Ok(0) if filled == 0 => return Ok(None),
                Ok(0) => return Err(refused("cut inside a header")),
                Ok(n) => filled += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
        Ok(Some(b))
    }

    fn skip(&mut self, mut length: u64) -> io::Result<()> {
        let mut buffer = [0u8; 8192];
        while length > 0 {
            let n = self.input.read(&mut buffer[..length.min(8192) as usize])?;
            if n == 0 {
                return Err(refused("cut inside an entry"));
            }
            length -= n as u64;
        }
        Ok(())
    }

    /// The next entry's header, skipping what was left unread of the previous entry's content; None after the
    /// end-of-archive blocks. The input must hold them: an archive that just stops is cut.
    pub fn next(&mut self) -> io::Result<Option<Header>> {
        if self.ended {
            return Ok(None);
        }
        let rest = self.remaining.checked_add(self.padding).ok_or_else(|| refused("entry size overflows"))?;
        self.skip(rest)?;
        (self.remaining, self.padding) = (0, 0);
        let mut extended: Option<Pax> = None;
        loop {
            let b = self.block()?.ok_or_else(|| refused("cut before its end blocks"))?;
            if b.iter().all(|&v| v == 0) {
                if extended.is_some() {
                    return Err(refused("pax header without its entry"));
                }
                // The second zero block; tolerate an input that ends after the first.
                if let Some(second) = self.block()?
                    && second.iter().any(|&v| v != 0)
                {
                    return Err(refused("data after one zero block"));
                }
                self.ended = true;
                return Ok(None);
            }
            let expected = number(&b[148..156])?;
            let unsigned: u64 = b.iter().enumerate().map(|(i, &v)| if (148..156).contains(&i) { 32 } else { u64::from(v) }).sum();
            let signed: i64 = b.iter().enumerate().map(|(i, &v)| if (148..156).contains(&i) { 32 } else { i64::from(v as i8) }).sum();
            if expected != unsigned && i64::try_from(expected).ok() != Some(signed) {
                return Err(refused("header checksum mismatch"));
            }
            // POSIX ustar only: GNU's "ustar  " headers keep other fields where ustar has its name prefix.
            if &b[257..263] != b"ustar\0" {
                return Err(refused("not a ustar header"));
            }
            let flag = b[156];
            let mut size = number(&b[124..136])?;
            if flag == b'x' {
                if extended.is_some() {
                    return Err(refused("two pax headers for one entry"));
                }
                if size > PAX_LIMIT {
                    return Err(refused("pax header too large"));
                }
                let mut data = vec![0u8; size as usize];
                self.input.read_exact(&mut data).map_err(|_| refused("cut inside a pax header"))?;
                self.skip((BLOCK as u64 - size % BLOCK as u64) % BLOCK as u64)?;
                extended = Some(pax(&data)?);
                continue;
            }
            let kind = match flag {
                b'0' | 0 => Kind::File,
                b'5' => Kind::Directory,
                b'2' => Kind::Symlink,
                b'1' => return Err(refused("hard links are not extracted")),
                b'3' | b'4' => return Err(refused("devices are not extracted")),
                b'6' => return Err(refused("fifos are not extracted")),
                _ => return Err(refused("unsupported entry type")),
            };
            let pax = extended.take().unwrap_or_default();
            let mut name = match pax.path {
                Some(path) => path,
                None => {
                    let (name, prefix) = (text(&b[0..100]), text(&b[345..500]));
                    if prefix.is_empty() {
                        name.to_vec()
                    } else {
                        [prefix, b"/", name].concat()
                    }
                }
            };
            if kind == Kind::Directory {
                while name.last() == Some(&b'/') {
                    name.pop();
                }
            } else if name.last() == Some(&b'/') {
                return Err(refused("a file name ends with a slash"));
            }
            if name.len() > PATH_MAX {
                return Err(refused("a name longer than PATH_MAX"));
            }
            if name.split(|&b| b == b'/').any(|part| part.len() > NAME_MAX) {
                return Err(refused("a name component longer than NAME_MAX"));
            }
            if let Some(value) = pax.size {
                size = value;
            }
            if kind != Kind::File && size != 0 {
                return Err(refused("a directory or link with content"));
            }
            let modified = match pax.modified {
                Some(value) => value,
                None => (i64::try_from(number(&b[136..148])?).map_err(|_| refused("mtime"))?, 0),
            };
            let link = if kind == Kind::Symlink { pax.link.unwrap_or_else(|| text(&b[157..257]).to_vec()) } else { Vec::new() };
            if link.len() > PATH_MAX {
                return Err(refused("a link target longer than PATH_MAX"));
            }
            let header = Header {
                name,
                kind,
                mode: u32::try_from(number(&b[100..108])? & 0o7777).unwrap_or(0),
                uid: pax.uid.map_or_else(|| number(&b[108..116]), Ok)?,
                gid: pax.gid.map_or_else(|| number(&b[116..124]), Ok)?,
                size,
                modified,
                link,
            };
            self.remaining = size;
            self.padding = (BLOCK as u64 - size % BLOCK as u64) % BLOCK as u64;
            return Ok(Some(header));
        }
    }

    /// The input after the end blocks (the decoder, to check its stream to its end).
    pub fn into_inner(self) -> R {
        self.input
    }
}

impl<R: Read> Read for Reader<R> {
    /// The current entry's content; 0 at its end. A cut archive is an error, never a short file.
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if self.remaining == 0 || out.is_empty() {
            return Ok(0);
        }
        let length = out.len().min(usize::try_from(self.remaining).unwrap_or(usize::MAX));
        let n = self.input.read(&mut out[..length])?;
        if n == 0 {
            return Err(refused("cut inside a file's content"));
        }
        self.remaining -= n as u64;
        Ok(n)
    }
}

#[cfg(test)]
#[path = "tar.test.rs"]
mod tests;
