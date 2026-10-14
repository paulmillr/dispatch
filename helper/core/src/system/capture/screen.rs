//! A terminal screen fed a stream's bytes (docs/capture_scrub.md): a program that redraws only the cells that changed
//! jumps the cursor over cells already showing the right byte, so a needle it draws is whole on the screen and in no
//! run of bytes. Cursor addressing (CUP/HVP, CHA, VPA, CUF/CUB/CUU/CUD, CNL/CPL), erase (EL, ED), CR, LF, BS, TAB,
//! save/restore and scrolling at the bottom; escape sequences cut by pieces keep their meaning.
use std::collections::VecDeque;

/// A fixed large screen: no stream's size is known everywhere, and no autowrap (line wraps are the unwrapped view's).
pub const ROWS: usize = 256;
pub const COLS: usize = 1024;

/// A row as drawn: its text (a blank is a space) and each cell's writer; `row` is None for a row the piece scrolled out.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line<P> {
    pub row: Option<usize>,
    pub text: Vec<u8>,
    pub cells: Vec<Option<P>>,
}

/// Where the parser is between bytes: in text, an escape, a CSI (its parameters in `params`), a string (OSC, DCS) or
/// its terminating ESC, a charset designation's last byte, or the continuation bytes of a UTF-8 character.
#[derive(Clone, Copy)]
enum State {
    Ground,
    Esc,
    Intermediate,
    Csi,
    String { bell: bool },
    StringEsc { bell: bool },
    Designate,
    Utf8(u8),
}

pub struct Screen<P> {
    rows: VecDeque<Vec<(u8, Option<P>)>>,
    touched: VecDeque<bool>,
    r: usize,
    c: usize,
    saved: (usize, usize),
    state: State,
    params: Vec<u8>,
}

impl<P: Clone> Default for Screen<P> {
    fn default() -> Self {
        Self::new()
    }
}

impl<P: Clone> Screen<P> {
    pub fn new() -> Self {
        Self {
            rows: (0..ROWS).map(|_| Vec::new()).collect(),
            touched: (0..ROWS).map(|_| false).collect(),
            r: 0,
            c: 0,
            saved: (0, 0),
            state: State::Ground,
            params: Vec::new(),
        }
    }

    /// The next piece (byte `index` written by `at(index)`): the rows it drew on, those it scrolled out first.
    pub fn feed(&mut self, bytes: &[u8], at: &dyn Fn(usize) -> P) -> Vec<Line<P>> {
        let mut out = Vec::new();
        for (index, &byte) in bytes.iter().enumerate() {
            self.step(byte, &|| at(index), &mut out);
        }
        for row in 0..ROWS {
            if std::mem::take(&mut self.touched[row]) {
                out.push(self.line(row));
            }
        }
        out
    }

    /// Every row that shows something.
    pub fn lines(&self) -> Vec<Line<P>> {
        (0..ROWS).filter(|&row| self.rows[row].iter().any(|(_, cell)| cell.is_some())).map(|row| self.line(row)).collect()
    }

    /// A cell shows `byte` from now on (a match replaced it where it was written).
    pub fn set(&mut self, row: usize, column: usize, byte: u8) {
        if let Some(cell) = self.rows.get_mut(row).and_then(|row| row.get_mut(column)) {
            cell.0 = byte;
        }
    }

    fn line(&self, row: usize) -> Line<P> {
        Line { row: Some(row), text: self.rows[row].iter().map(|(byte, _)| *byte).collect(), cells: self.rows[row].iter().map(|(_, cell)| cell.clone()).collect() }
    }

    fn step(&mut self, byte: u8, writer: &dyn Fn() -> P, out: &mut Vec<Line<P>>) {
        self.state = match (self.state, byte) {
            (State::Utf8(left), 0x80..=0xbf) => if left > 1 { State::Utf8(left - 1) } else { State::Ground },
            (State::Utf8(_), _) => {
                self.state = State::Ground;
                return self.step(byte, writer, out);
            }
            (State::Ground, 0x1b) => State::Esc,
            (State::Ground, b'\r') => { self.c = 0; State::Ground }
            (State::Ground, b'\n') => { self.feed_line(out); State::Ground }
            (State::Ground, 0x08) => { self.c = self.c.saturating_sub(1); State::Ground }
            (State::Ground, b'\t') => { self.c = (self.c / 8 + 1) * 8; State::Ground }
            (State::Ground, 0..=0x1f | 0x7f) => State::Ground,
            // One cell for a character of several bytes: needles are matched on single-byte text.
            (State::Ground, 0xc0..=0xff) => { self.put(b'?', writer); State::Utf8(if byte < 0xe0 { 1 } else if byte < 0xf0 { 2 } else { 3 }) }
            (State::Ground, _) => { self.put(byte, writer); State::Ground }
            (State::Esc, b'[') => { self.params.clear(); State::Csi }
            (State::Esc, b']') => State::String { bell: true },
            (State::Esc, b'P' | b'_' | b'^' | b'X') => State::String { bell: false },
            (State::Esc, b'7') => { self.saved = (self.r, self.c); State::Ground }
            (State::Esc, b'8') => { (self.r, self.c) = self.saved; State::Ground }
            (State::Esc, b'(' | b')' | b'*' | b'+') => State::Designate,
            (State::Esc | State::Intermediate, 0x20..=0x2f) => State::Intermediate,
            (State::Esc | State::Intermediate | State::Designate, _) => State::Ground,
            (State::Csi, 0x20..=0x3f) => { self.params.push(byte); State::Csi }
            (State::Csi, 0x40..=0x7e) => { self.csi(byte); State::Ground }
            (State::Csi, 0x1b) => State::Esc,
            (State::Csi, _) => State::Ground,
            (State::String { bell: true }, 0x07) => State::Ground,
            (State::String { bell }, 0x1b) => State::StringEsc { bell },
            (State::String { bell }, _) => State::String { bell },
            (State::StringEsc { .. }, b'\\') => State::Ground,
            (State::StringEsc { bell }, _) => State::String { bell },
        };
    }

    fn put(&mut self, byte: u8, writer: &dyn Fn() -> P) {
        if self.c < COLS {
            let row = &mut self.rows[self.r];
            if row.len() <= self.c {
                row.resize(self.c + 1, (b' ', None));
            }
            row[self.c] = (byte, Some(writer()));
            self.touched[self.r] = true;
        }
        self.c += 1;
    }

    fn feed_line(&mut self, out: &mut Vec<Line<P>>) {
        if self.r + 1 < ROWS {
            self.r += 1;
            return;
        }
        if self.touched[0] {
            out.push(Line { row: None, ..self.line(0) });
        }
        self.rows.pop_front();
        self.touched.pop_front();
        self.rows.push_back(Vec::new());
        self.touched.push_back(false);
    }

    fn csi(&mut self, last: u8) {
        // Private modes (?, >, <, =) set no position and draw nothing.
        if matches!(self.params.first(), Some(b'?' | b'>' | b'<' | b'=')) {
            return;
        }
        let numbers: Vec<usize> = self.params.split(|byte| *byte == b';')
            .map(|part| std::str::from_utf8(part).ok().and_then(|text| text.parse().ok()).unwrap_or(0)).collect();
        let at = |index: usize| numbers.get(index).copied().filter(|number| *number > 0).unwrap_or(1);
        let (n, row) = (at(0), |number: usize| (number - 1).min(ROWS - 1));
        match last {
            b'H' | b'f' => (self.r, self.c) = (row(at(0)), at(1) - 1),
            b'G' | b'`' => self.c = n - 1,
            b'd' => self.r = row(n),
            b'C' => self.c += n,
            b'D' => self.c = self.c.saturating_sub(n),
            b'A' => self.r = self.r.saturating_sub(n),
            b'B' => self.r = (self.r + n).min(ROWS - 1),
            b'E' => (self.r, self.c) = ((self.r + n).min(ROWS - 1), 0),
            b'F' => (self.r, self.c) = (self.r.saturating_sub(n), 0),
            b'K' => self.erase(self.r, numbers.first().copied().unwrap_or(0)),
            b'J' => {
                let mode = numbers.first().copied().unwrap_or(0);
                let rows = match mode { 0 => self.r + 1..ROWS, 1 => 0..self.r, _ => 0..ROWS };
                for row in rows {
                    self.rows[row].clear();
                    self.touched[row] = true;
                }
                if mode < 2 {
                    self.erase(self.r, mode);
                }
            }
            b's' => self.saved = (self.r, self.c),
            b'u' => (self.r, self.c) = self.saved,
            _ => {}
        }
    }

    /// EL on `row`: from the cursor on (0), up to it (1), the whole row (2).
    fn erase(&mut self, row: usize, mode: usize) {
        let (cells, c) = (&mut self.rows[row], self.c);
        match mode {
            0 => cells.truncate(c),
            1 => cells.iter_mut().take(c + 1).for_each(|cell| *cell = (b' ', None)),
            _ => cells.clear(),
        }
        self.touched[row] = true;
    }
}

#[cfg(test)]
#[path = "screen.test.rs"]
mod tests;
