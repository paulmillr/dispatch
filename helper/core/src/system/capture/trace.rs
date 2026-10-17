//! The capture file: bzip2 (live captures) or zstd (the replay corpus, capture/zstd.rs) around length-prefixed frames. A header names the layer (helper or
//! app) and the helper wire version; each record is one I/O row; a footer counts the records.
//! bzip2's checksums refuse a damaged file and the footer a cut one: a file is whole only when it
//! ends with a footer that counts every record before it. A checkpoint (before exec) writes a
//! footer and ends the bzip2 member (zstd frame); later records continue in a new one. A reader tells the two by
//! their magic bytes.
//! Args and output are wire values without the schema's names (wire::body::encode_plain):
//! nothing inside is JSON, hex or base64.
use super::bzip2;
#[cfg(dispatch_zstd)]
use super::zstd;
use std::io::{self, Read, Write};

const MAGIC: &[u8; 8] = b"DCAPTURE";
const VERSION: u32 = 1;
const RECORD: u8 = 0;
const INVALID: u8 = 254;
const FOOTER: u8 = 255;
/// A zstd frame's first bytes (0xFD2FB528, little-endian); a bzip2 stream starts "BZh".
const ZSTD: [u8; 4] = [0x28, 0xb5, 0x2f, 0xfd];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layer {
    Native,
    App,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Header {
    pub layer: Layer,
    /// The helper wire version (wire::VERSION) its wire records were written with.
    pub wire: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    /// The stream the record belongs to (a helper section, an app lifetime).
    pub section: String,
    /// Nanoseconds since the capture started.
    pub clock: u64,
    pub op: String,
    /// What was asked: an encode_plain value.
    pub args: Vec<u8>,
    pub sequence: u64,
    /// What came back: an encode_plain value.
    pub output: Vec<u8>,
    pub error: Option<i32>,
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn blob(out: &mut Vec<u8>, bytes: &[u8]) -> io::Result<()> {
    let count = u32::try_from(bytes.len()).map_err(|_| invalid("capture field too large"))?;
    out.extend_from_slice(&count.to_le_bytes());
    out.extend_from_slice(bytes);
    Ok(())
}

enum Encoder<W: Write> {
    Bzip2(bzip2::Encoder<W>),
    #[cfg(dispatch_zstd)]
    Zstd(zstd::Encoder<W>),
}
impl<W: Write> Encoder<W> {
    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
        match self {
            Self::Bzip2(encoder) => encoder.write_all(bytes),
            #[cfg(dispatch_zstd)]
            Self::Zstd(encoder) => encoder.write_all(bytes),
        }
    }
    fn checkpoint(&mut self) -> io::Result<()> {
        match self {
            Self::Bzip2(encoder) => encoder.checkpoint(),
            #[cfg(dispatch_zstd)]
            Self::Zstd(encoder) => encoder.checkpoint(),
        }
    }
    fn finish(self) -> io::Result<W> {
        match self {
            Self::Bzip2(encoder) => encoder.finish(),
            #[cfg(dispatch_zstd)]
            Self::Zstd(encoder) => encoder.finish(),
        }
    }
}

pub struct Writer<W: Write> {
    output: Encoder<W>,
    rows: u64,
}
impl<W: Write> Writer<W> {
    /// A live capture: bzip2, which every helper can write.
    pub fn new(output: W, header: &Header) -> io::Result<Self> {
        Self::start(Encoder::Bzip2(bzip2::Encoder::new(output, 9)?), header)
    }
    /// A replay corpus file: zstd, which only a macOS helper with the capture tool has (helper/core/build.rs).
    pub fn zstd(output: W, header: &Header) -> io::Result<Self> {
        #[cfg(dispatch_zstd)]
        return Self::start(Encoder::Zstd(zstd::Encoder::new(output)?), header);
        #[cfg(not(dispatch_zstd))]
        {
            let _ = (output, header);
            Err(io::Error::new(io::ErrorKind::Unsupported, "zstd captures need a macOS helper with the capture tool"))
        }
    }
    fn start(output: Encoder<W>, header: &Header) -> io::Result<Self> {
        let mut writer = Self { output, rows: 0 };
        let mut frame = MAGIC.to_vec();
        frame.extend_from_slice(&VERSION.to_le_bytes());
        frame.push(header.layer as u8);
        frame.extend_from_slice(&header.wire.to_le_bytes());
        writer.frame(&frame)?;
        Ok(writer)
    }
    fn frame(&mut self, bytes: &[u8]) -> io::Result<()> {
        let mut frame = Vec::with_capacity(4 + bytes.len());
        blob(&mut frame, bytes)?;
        self.output.write_all(&frame)
    }
    pub fn push(&mut self, record: &Record) -> io::Result<()> {
        let mut bytes = vec![RECORD];
        blob(&mut bytes, record.section.as_bytes())?;
        bytes.extend_from_slice(&record.clock.to_le_bytes());
        blob(&mut bytes, record.op.as_bytes())?;
        blob(&mut bytes, &record.args)?;
        bytes.extend_from_slice(&record.sequence.to_le_bytes());
        blob(&mut bytes, &record.output)?;
        match record.error {
            Some(error) => {
                bytes.push(1);
                bytes.extend_from_slice(&error.to_le_bytes());
            }
            None => bytes.push(0),
        }
        self.frame(&bytes)?;
        self.rows += 1;
        Ok(())
    }
    /// Everything written so far becomes a complete capture: a footer, then the end of the member.
    pub fn checkpoint(&mut self) -> io::Result<()> {
        let mut footer = vec![FOOTER];
        footer.extend_from_slice(&self.rows.to_le_bytes());
        self.frame(&footer)?;
        self.output.checkpoint()
    }
    pub fn finish(mut self) -> io::Result<W> {
        self.checkpoint()?;
        self.output.finish()
    }
    /// The recording failed (queue overflow, size budget): no footer can certify it any more,
    /// including one written by an earlier checkpoint.
    pub fn invalid(mut self, reason: &str) -> io::Result<W> {
        let mut frame = vec![INVALID];
        frame.extend_from_slice(reason.as_bytes());
        self.frame(&frame)?;
        self.output.finish()
    }
}

/// The compressed input with its first bytes, read to tell its format, put back in front.
type Peeked<R> = io::Chain<io::Cursor<Vec<u8>>, R>;

enum Decoder<R: Read> {
    Bzip2(bzip2::Decoder<Peeked<R>>),
    #[cfg(dispatch_zstd)]
    Zstd(zstd::Decoder<Peeked<R>>),
}
impl<R: Read> Decoder<R> {
    fn new(mut input: R, limit: usize) -> io::Result<Self> {
        let mut magic = Vec::new();
        (&mut input).take(4).read_to_end(&mut magic)?;
        let zstd = magic == ZSTD;
        let input = io::Cursor::new(magic).chain(input);
        #[cfg(dispatch_zstd)]
        if zstd {
            return Ok(Self::Zstd(zstd::Decoder::new(input, limit)?));
        }
        if zstd {
            return Err(invalid("a zstd capture (the replay corpus): only a macOS helper with the capture tool reads it"));
        }
        Ok(Self::Bzip2(bzip2::Decoder::new(input, limit)?))
    }
}
impl<R: Read> Read for Decoder<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Bzip2(decoder) => decoder.read(out),
            #[cfg(dispatch_zstd)]
            Self::Zstd(decoder) => decoder.read(out),
        }
    }
}

pub struct Reader<R: Read> {
    input: Decoder<R>,
    rows: u64,
    complete: bool,
}
impl<R: Read> Reader<R> {
    /// `limit` bounds the expanded capture; the header is checked before any record.
    pub fn new(input: R, limit: usize) -> io::Result<(Self, Header)> {
        let mut reader = Self {
            input: Decoder::new(input, limit)?,
            rows: 0,
            complete: false,
        };
        let frame = reader.frame()?.ok_or_else(|| invalid("empty capture"))?;
        let mut at = Cursor(&frame);
        if at.take(MAGIC.len())? != MAGIC || at.u32()? != VERSION {
            return Err(invalid("not a capture of this version"));
        }
        let layer = match at.take(1)?[0] {
            0 => Layer::Native,
            1 => Layer::App,
            _ => return Err(invalid("unknown capture layer")),
        };
        let header = Header {
            layer,
            wire: at.u64()?,
        };
        at.end()?;
        Ok((reader, header))
    }
    /// The next frame, or None at a clean end of the input.
    fn frame(&mut self) -> io::Result<Option<Vec<u8>>> {
        let mut count = [0; 4];
        let mut read = 0;
        for _ in 0..count.len() {
            match self.input.read(&mut count[read..])? {
                0 if read == 0 => return Ok(None),
                0 => return Err(invalid("capture frame cut")),
                n => read += n,
            }
            if read == count.len() {
                break;
            }
        }
        let count = u32::from_le_bytes(count) as usize;
        // A record is never larger than the capture queue that carried it.
        if count > super::QUEUE {
            return Err(invalid("capture frame exceeds the queue bound"));
        }
        // Grown as the bytes arrive: a declared size alone (a cut or crafted capture) allocates nothing.
        let mut bytes = Vec::new();
        if (&mut self.input).take(count as u64).read_to_end(&mut bytes)? != count {
            return Err(invalid("capture frame cut"));
        }
        Ok(Some(bytes))
    }
    /// The next record; None only after a footer that covers every record before it.
    pub fn next(&mut self) -> io::Result<Option<Record>> {
        for _ in 0.. {
            let Some(frame) = self.frame()? else {
                return if self.complete {
                    Ok(None)
                } else {
                    Err(invalid("capture has no footer: cut"))
                };
            };
            let mut at = Cursor(&frame);
            match at.take(1)?[0] {
                FOOTER => {
                    let rows = at.u64()?;
                    at.end()?;
                    if rows != self.rows {
                        return Err(invalid("capture footer does not match its records"));
                    }
                    self.complete = true;
                }
                RECORD => {
                    let record = Record {
                        section: at.text()?,
                        clock: at.u64()?,
                        op: at.text()?,
                        args: at.blob()?.to_vec(),
                        sequence: at.u64()?,
                        output: at.blob()?.to_vec(),
                        error: match at.take(1)?[0] {
                            0 => None,
                            1 => Some(at.u32()? as i32),
                            _ => return Err(invalid("invalid capture error")),
                        },
                    };
                    at.end()?;
                    self.rows += 1;
                    self.complete = false;
                    return Ok(Some(record));
                }
                INVALID => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("capture invalid: {}", String::from_utf8_lossy(at.0)),
                    ));
                }
                _ => return Err(invalid("unknown capture frame")),
            }
        }
        unreachable!()
    }
}

/// Every record of a complete capture.
pub fn read(input: impl Read, limit: usize) -> io::Result<(Header, Vec<Record>)> {
    let (mut reader, header) = Reader::new(input, limit)?;
    let mut records = Vec::new();
    for _ in 0.. {
        match reader.next()? {
            Some(record) => records.push(record),
            None => break,
        }
    }
    Ok((header, records))
}

struct Cursor<'a>(&'a [u8]);
impl<'a> Cursor<'a> {
    fn take(&mut self, count: usize) -> io::Result<&'a [u8]> {
        if count > self.0.len() {
            return Err(invalid("capture frame too short"));
        }
        let (head, tail) = self.0.split_at(count);
        self.0 = tail;
        Ok(head)
    }
    fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> io::Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn blob(&mut self) -> io::Result<&'a [u8]> {
        let count = self.u32()? as usize;
        self.take(count)
    }
    fn text(&mut self) -> io::Result<String> {
        String::from_utf8(self.blob()?.to_vec()).map_err(|_| invalid("capture text is not UTF-8"))
    }
    fn end(&self) -> io::Result<()> {
        if self.0.is_empty() {
            Ok(())
        } else {
            Err(invalid("trailing capture frame bytes"))
        }
    }
}

#[cfg(test)]
#[path = "trace.test.rs"]
mod tests;
