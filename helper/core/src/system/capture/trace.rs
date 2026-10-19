//! The capture file: zstd (system/zstd.rs) around length-prefixed frames. A header names the layer (helper or app)
//! and the helper wire version; each record is one I/O row; a footer counts the records.
//! zstd's checksums refuse a damaged file and the footer a cut one: a file is whole only when it
//! ends with a footer that counts every record before it. A checkpoint (before exec) writes a
//! footer and ends the zstd frame; later records continue in a new one.
//! Args and output are wire values without the schema's names (wire::body::encode_plain):
//! nothing inside is JSON, hex or base64.
use crate::system::zstd;
use std::io::{self, Read, Write};

const MAGIC: &[u8; 8] = b"DCAPTURE";
const VERSION: u32 = 1;
const RECORD: u8 = 0;
const INVALID: u8 = 254;
const FOOTER: u8 = 255;
/// A zstd frame's first bytes (0xFD2FB528, little-endian).
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

pub struct Writer<W: Write> {
    output: zstd::Encoder<W>,
    rows: u64,
}
impl<W: Write> Writer<W> {
    /// A live capture.
    pub fn new(output: W, header: &Header) -> io::Result<Self> {
        Self::start(zstd::Encoder::live(output)?, header)
    }
    /// A replay corpus file.
    pub fn corpus(output: W, header: &Header) -> io::Result<Self> {
        Self::start(zstd::Encoder::corpus(output)?, header)
    }
    fn start(output: zstd::Encoder<W>, header: &Header) -> io::Result<Self> {
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
    /// Everything written so far becomes a complete capture: a footer, then the end of the frame.
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

/// The compressed input with its first bytes, read to check its format, put back in front.
type Peeked<R> = io::Chain<io::Cursor<Vec<u8>>, R>;

fn decoder<R: Read>(mut input: R, limit: usize) -> io::Result<zstd::Decoder<Peeked<R>>> {
    let mut magic = Vec::new();
    (&mut input).take(4).read_to_end(&mut magic)?;
    if magic != ZSTD {
        return Err(invalid("not a capture: no zstd frame"));
    }
    zstd::Decoder::new(io::Cursor::new(magic).chain(input), limit)
}

pub struct Reader<R: Read> {
    input: zstd::Decoder<Peeked<R>>,
    rows: u64,
    complete: bool,
}
impl<R: Read> Reader<R> {
    /// `limit` bounds the expanded capture; the header is checked before any record.
    pub fn new(input: R, limit: usize) -> io::Result<(Self, Header)> {
        let mut reader = Self {
            input: decoder(input, limit)?,
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
