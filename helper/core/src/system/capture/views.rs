//! Views (docs/capture_scrub.md): the text a reader of one stream sees, in record order, so a needle is found where a
//! record boundary cuts it or a terminal wraps it.

/// One stream's text so far: the last `keep` bytes a match can start in, each with where it was recorded (`P`: a record's
/// part and offset for `replace`, a stream offset for `grep`). `unwrap`: line breaks and CSI sequences (ESC [, parameters
/// and intermediates, a final byte) are not part of the text; `csi` is how far into one the last piece ended.
pub struct View<P> {
    unwrap: bool,
    keep: usize,
    csi: u8,
    tail: Vec<u8>,
    at: Vec<P>,
}

impl<P: Copy> View<P> {
    pub fn new(unwrap: bool, keep: usize) -> Self {
        Self { unwrap, keep, csi: 0, tail: Vec::new(), at: Vec::new() }
    }

    /// The next piece of the stream: `scan` gets the text (what was kept, then this piece's), where this piece begins in
    /// it and where each of its bytes was recorded; it rewrites the matches ending in this piece. What it changed in this
    /// piece is written into `bytes`; returns every byte it changed (earlier pieces' first), where it was recorded.
    pub fn feed(&mut self, bytes: &mut [u8], at: &dyn Fn(usize) -> P, scan: &mut dyn FnMut(&mut [u8], usize, &dyn Fn(usize) -> P)) -> Vec<(P, u8)> {
        let (from, mut text, mut here) = (self.tail.len(), std::mem::take(&mut self.tail), Vec::new());
        for (index, &byte) in bytes.iter().enumerate() {
            if !self.hidden(byte) {
                text.push(byte);
                here.push(index);
            }
        }
        let (before, kept) = (text.clone(), std::mem::take(&mut self.at));
        let place = |index: usize| if index < from { kept[index] } else { at(here[index - from]) };
        scan(&mut text, from, &place);
        let changed = (0..text.len()).filter(|&index| text[index] != before[index]).map(|index| {
            if index >= from {
                bytes[here[index - from]] = text[index];
            }
            (place(index), text[index])
        }).collect();
        let cut = text.len().saturating_sub(self.keep);
        self.at = (cut..text.len()).map(place).collect();
        text.drain(..cut);
        self.tail = text;
        changed
    }

    /// Whether `byte` is not part of the text (and where a CSI sequence it is in got to).
    fn hidden(&mut self, byte: u8) -> bool {
        if !self.unwrap {
            return false;
        }
        let (csi, hidden) = match (self.csi, byte) {
            (_, 0x1b) => (1, true),
            (1, b'[') => (2, true),
            (2, 0x20..=0x3f) => (2, true),
            (2, 0x40..=0x7e) | (_, b'\r' | b'\n') => (0, true),
            _ => (0, false),
        };
        self.csi = csi;
        hidden
    }
}

#[cfg(test)]
#[path = "views.test.rs"]
mod tests;
