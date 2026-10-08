//! c1654cc TranscriptPaging.swift:102-150: backwards bounded LF records, not JSON policy.
use crate::api::{Error, Job, Metadata, Output};
use crate::hash::Sha256;
use std::path::{Path, PathBuf};

/// Includes LF when complete. Oversized records keep their span and empty body (plus LF),
/// because they still count toward the caller's page bounds; incomplete EOF stays explicit.
#[derive(Debug, PartialEq, Eq)]
pub struct Line {
    pub start: u64,
    pub end: u64,
    pub bytes: Vec<u8>,
    pub complete: bool,
}

pub struct Reverse {
    path: PathBuf,
    lower: u64,
    position: u64,
    end: u64,
    limit: usize,
    part: Vec<u8>,
    dropped: bool,
    complete: Option<bool>,
    metadata: Option<Metadata>,
    anchor: Option<(u64, usize, [u8; 32])>,
    pending: Option<Output>,
}
impl Reverse {
    pub fn new(path: PathBuf, lower: u64, end: u64, limit: usize) -> Self {
        Self {
            path,
            lower,
            position: end,
            end,
            limit,
            part: Vec::new(),
            dropped: false,
            complete: None,
            metadata: None,
            anchor: None,
            pending: None,
        }
    }
    pub fn position(&self) -> u64 {
        self.position
    }
    pub fn metadata(&self) -> Option<Metadata> {
        self.metadata
    }
    /// Caller submits one job and feeds its completion before requesting another.
    pub fn job(&self) -> Option<Job> {
        if self.pending.is_some() {
            let (offset, length, _) = self.anchor.unwrap();
            return Some(Job::Read {
                path: self.path.clone(),
                offset,
                length: length as u64,
            });
        }
        (self.position > self.lower).then(|| {
            let offset = self.position.saturating_sub(65_536).max(self.lower);
            Job::Read {
                path: self.path.clone(),
                offset,
                length: self.position - offset,
            }
        })
    }
    /// Each admitted block yields newest-first lines. Callers keep their own record/byte
    /// budgets and may restart at a returned Line.start to continue a page exactly there.
    pub fn feed(&mut self, output: Output) -> Result<Vec<Line>, Error> {
        let Output::Read {
            before,
            after,
            mut bytes,
        } = output
        else {
            return Err(Error {
                code: "io",
                message: "Expected transcript read".into(),
            });
        };
        let follows = |old: Metadata, new: Metadata| {
            old.kind == new.kind
                && old.device == new.device
                && old.inode == new.inode
                && new.size >= old.size
                && (new.size != old.size || new == old)
        };
        if !follows(before, after)
            || self.metadata.is_some_and(|old| !follows(old, before))
            || before.size < self.end
        {
            return Err(Error {
                code: "changed",
                message: "Transcript changed during read".into(),
            });
        }
        let offset = self.position.saturating_sub(65_536).max(self.lower);
        if let Some(Output::Read { bytes: block, .. }) = self.pending.take() {
            let (_, length, expected) = self.anchor.unwrap();
            let mut hash = Sha256::new();
            hash.update(&bytes);
            if bytes.len() != length || hash.finish() != expected {
                return Err(Error {
                    code: "changed",
                    message: "Transcript content changed during read".into(),
                });
            }
            bytes = block;
        } else if self.anchor.is_some() && self.metadata.is_some_and(|old| old != after) {
            if bytes.len() as u64 != self.position - offset {
                return Err(Error {
                    code: "io",
                    message: "Incomplete transcript read".into(),
                });
            }
            self.pending = Some(Output::Read {
                before,
                after,
                bytes,
            });
            return Ok(Vec::new());
        }
        if self.position <= self.lower || bytes.len() as u64 != self.position - offset {
            return Err(Error {
                code: "io",
                message: "Incomplete transcript read".into(),
            });
        }
        self.metadata = Some(after);
        let mut hash = Sha256::new();
        hash.update(&bytes);
        self.anchor = Some((offset, bytes.len(), hash.finish()));
        let mut end = bytes.len();
        if self.complete.is_none() {
            let complete = bytes.last() == Some(&b'\n');
            self.complete = Some(complete);
            end -= usize::from(complete);
        }
        let mut lines = Vec::new();
        let mut remaining = &bytes[..end];
        for start in std::iter::from_fn(|| {
            let i = rfind(remaining, b'\n')?;
            remaining = &remaining[..i];
            Some(i + 1)
        })
        .chain(std::iter::once(0))
        {
            let piece = &bytes[start..end];
            if !self.dropped {
                if piece.len() <= self.limit.saturating_sub(self.part.len()) {
                    self.part.extend(piece.iter().rev());
                } else {
                    self.part.clear();
                    self.dropped = true;
                }
            }
            self.position = offset + start as u64;
            if start > 0 || offset == self.lower {
                let mut body = std::mem::take(&mut self.part);
                body.reverse();
                let complete = self.complete.unwrap();
                if complete {
                    body.push(b'\n');
                }
                lines.push(Line {
                    start: self.position,
                    end: self.end,
                    bytes: body,
                    complete,
                });
                self.end = self.position;
                self.complete = Some(true);
                self.dropped = false;
            }
            end = start.saturating_sub(1);
        }
        Ok(lines)
    }
}

/// A snapshot's old prefix and tail. Trust native appends between reads; verify the old
/// bytes on access as c1654cc TranscriptReader.swift:290-296 and :372-378.
#[derive(Clone)]
pub struct Grown {
    pub metadata: Metadata,
    pub prefix: Vec<u8>,
    pub tail: Vec<u8>,
}
impl Grown {
    pub fn same_file(&self, now: &Metadata, prefix: &[u8]) -> bool {
        now.device == self.metadata.device
            && now.inode == self.metadata.inode
            && now.size >= self.metadata.size
            && prefix.starts_with(&self.prefix)
            && (now.size != self.metadata.size || *now == self.metadata)
    }
    /// The tail belongs to metadata.size; callers retain at most the old bounded tail.
    pub fn tail_job(&self, path: &Path) -> Job {
        Job::Read {
            path: path.to_owned(),
            offset: self.metadata.size - self.tail.len() as u64,
            length: self.tail.len() as u64,
        }
    }
    /// Verify the old tail against the newly opened snapshot, not a later revision.
    pub fn check(&self, now: &Metadata, output: &Output) -> bool {
        matches!(output, Output::Read { before, after, bytes }
            if before == now && after == now && bytes == &self.tail)
    }
}

/// Exact byte-equality masks, without subtraction borrows between lanes.
fn rfind(bytes: &[u8], byte: u8) -> Option<usize> {
    const ONES: u64 = u64::MAX / 255;
    const HIGH: u64 = ONES * 0x80;
    let mut end = bytes.len();
    for chunk in bytes.rchunks_exact(8) {
        end -= 8;
        let value = u64::from_le_bytes(chunk.try_into().unwrap()) ^ (ONES * u64::from(byte));
        let mask = !(((value & !HIGH) + ONES * 0x7f) | value) & HIGH;
        if mask != 0 {
            return Some(end + 7 - mask.leading_zeros() as usize / 8);
        }
    }
    bytes[..end].iter().rposition(|value| *value == byte)
}
