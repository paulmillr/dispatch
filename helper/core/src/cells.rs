//! A screen a helper reads on the host, for `Multiplexer::screen` when no client renders the terminal (the queue
//! drainer; `Multiplexer::host_screens`): a small cell grid fed a multiplexer's own screen dump (herdr's terminal
//! frames, a tmux `capture-pane -e` row), and the `Screen` a client would publish from it.
//!
//! Clients publish what their renderer shows (Dispatch/Terminal/TerminalBackend.swift publishScreen): the active
//! area as Ghostty's plain formatter writes it (`readText(.active)`, Vendor/Term Selection.swift `format`: rows end
//! in newlines and blank cells become spaces, both only when text follows; a written space is text) and
//! `cursorFaintTail` (Vendor/Term Surface.swift): the cursor cell, and whether every non-blank cell after it on its
//! row is faint (SGR 2), with at least one. The grid keeps exactly what those read: each cell's text, whether it is
//! faint, and the cursor. Autowrap is off, as in the app's herdr renderer (`ESC[?7l` before herdr's frames): text
//! past the last column overwrites it. Sequences a screen dump does not use (scroll regions, insert and delete)
//! fail the feed, so a caller reads a fresh full screen instead of guessing.
use crate::api::Screen;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Cell {
    /// The character cluster drawn here; empty for a blank (never written or erased) cell and for the right half
    /// of a wide character.
    text: String,
    faint: bool,
    /// The right half of a wide character.
    tail: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Ground,
    Esc,
    /// ESC followed by intermediates (a charset designation): its final byte ends it.
    Intermediate,
    Csi,
    /// OSC, DCS, APC, PM, SOS until BEL (OSC only) or ST.
    String,
    StringEsc,
}

#[derive(Clone, Debug)]
pub struct Cells {
    columns: usize,
    rows: Vec<Vec<Cell>>,
    x: usize,
    y: usize,
    saved: (usize, usize),
    faint: bool,
    state: State,
    /// The parameters and intermediates of the CSI being read.
    params: Vec<u8>,
    /// Bytes of a UTF-8 character cut by the end of a feed.
    partial: Vec<u8>,
    /// The cell the last character went to (combining marks join it).
    last: Option<(usize, usize)>,
}

impl Cells {
    pub fn new(columns: usize, rows: usize) -> Self {
        let columns = columns.max(1);
        Self {
            columns,
            rows: vec![vec![Cell::default(); columns]; rows.max(1)],
            x: 0,
            y: 0,
            saved: (0, 0),
            faint: false,
            state: State::Ground,
            params: Vec::new(),
            partial: Vec::new(),
            last: None,
        }
    }

    pub fn size(&self) -> (usize, usize) {
        (self.columns, self.rows.len())
    }

    /// The cursor as (column, row).
    pub fn cursor(&self) -> (usize, usize) {
        (self.x, self.y)
    }

    /// Draw `bytes`. A sequence outside a screen dump's vocabulary fails with its name; what was drawn before it
    /// stays, so the caller drops the grid and starts again from a full screen.
    pub fn feed(&mut self, bytes: &[u8]) -> Result<(), String> {
        for &byte in bytes {
            self.byte(byte)?;
        }
        Ok(())
    }

    /// What a client renderer publishes for this grid.
    pub fn screen(&self) -> Screen {
        Screen {
            text: self.text(),
            cursor: (self.x as u32, self.y as u32),
            faint_tail: self.faint_after(self.x, self.y),
        }
    }

    /// Ghostty's plain formatter over the whole grid (no row wraps: autowrap is off).
    pub fn text(&self) -> String {
        let mut out = String::new();
        let mut blank_rows = 0;
        for row in &self.rows {
            if row.iter().all(|cell| cell.text.is_empty()) {
                blank_rows += 1;
                continue;
            }
            out.extend(std::iter::repeat_n('\n', blank_rows));
            blank_rows = 1;
            let mut blanks = 0;
            for cell in row {
                if cell.tail {
                    continue;
                }
                if cell.text.is_empty() {
                    blanks += 1;
                    continue;
                }
                out.extend(std::iter::repeat_n(' ', blanks));
                blanks = 0;
                out.push_str(&cell.text);
            }
        }
        out
    }

    /// `cursorFaintTail` for a cursor at (column, row): every cell after it on its row that is neither blank nor a
    /// space is faint, and there is at least one.
    pub fn faint_after(&self, column: usize, row: usize) -> bool {
        let Some(cells) = self.rows.get(row) else {
            return false;
        };
        let mut found = false;
        for cell in cells.iter().skip(column + 1) {
            if cell.text.is_empty() || cell.text.starts_with(' ') {
                continue;
            }
            if !cell.faint {
                return false;
            }
            found = true;
        }
        found
    }

    fn byte(&mut self, byte: u8) -> Result<(), String> {
        match self.state {
            State::Ground => self.ground(byte),
            State::Esc => self.escape(byte),
            State::Intermediate => {
                if (0x30..=0x7e).contains(&byte) {
                    self.state = State::Ground;
                }
                Ok(())
            }
            State::Csi => {
                if (0x40..=0x7e).contains(&byte) {
                    self.state = State::Ground;
                    let params = std::mem::take(&mut self.params);
                    self.csi(&params, byte)
                } else if (0x20..=0x3f).contains(&byte) {
                    if self.params.len() >= 256 {
                        return Err("an oversized control sequence".into());
                    }
                    self.params.push(byte);
                    Ok(())
                } else if byte == 0x1b {
                    self.params.clear();
                    self.state = State::Esc;
                    Ok(())
                } else {
                    // C0 controls inside a CSI act as usual (VT500); CAN and SUB cancel it.
                    if byte == 0x18 || byte == 0x1a {
                        self.params.clear();
                        self.state = State::Ground;
                        return Ok(());
                    }
                    self.control(byte)
                }
            }
            State::String => {
                match byte {
                    0x07 => self.state = State::Ground,
                    0x1b => self.state = State::StringEsc,
                    _ => {}
                }
                Ok(())
            }
            State::StringEsc => {
                self.state = if byte == b'\\' { State::Ground } else { State::String };
                Ok(())
            }
        }
    }

    fn ground(&mut self, byte: u8) -> Result<(), String> {
        let continuation = (0x80..=0xbf).contains(&byte);
        if !self.partial.is_empty() {
            if continuation {
                self.partial.push(byte);
                let length = match self.partial[0] {
                    0xc0..=0xdf => 2,
                    0xe0..=0xef => 3,
                    _ => 4,
                };
                if self.partial.len() == length {
                    let character = std::mem::take(&mut self.partial);
                    self.print(&String::from_utf8_lossy(&character));
                }
                return Ok(());
            }
            // A character cut short draws a replacement, as a terminal does.
            self.partial.clear();
            self.print("\u{fffd}");
        }
        if continuation || byte >= 0xf8 {
            self.print("\u{fffd}");
            return Ok(());
        }
        if byte >= 0xc0 {
            self.partial.push(byte);
            return Ok(());
        }
        match byte {
            0x1b => {
                self.state = State::Esc;
                Ok(())
            }
            0x20..=0x7e => {
                self.print(std::str::from_utf8(&[byte]).unwrap());
                Ok(())
            }
            0x7f => Ok(()),
            _ => self.control(byte),
        }
    }

    fn control(&mut self, byte: u8) -> Result<(), String> {
        match byte {
            b'\r' => self.x = 0,
            b'\n' | 0x0b | 0x0c => {
                if self.y + 1 >= self.rows.len() {
                    return Err("a scroll".into());
                }
                self.y += 1;
            }
            0x08 => self.x = self.x.saturating_sub(1),
            b'\t' => self.x = ((self.x / 8 + 1) * 8).min(self.columns - 1),
            _ => {}
        }
        self.last = None;
        Ok(())
    }

    fn escape(&mut self, byte: u8) -> Result<(), String> {
        self.state = State::Ground;
        match byte {
            b'[' => {
                self.params.clear();
                self.state = State::Csi;
            }
            b']' | b'P' | b'_' | b'^' | b'X' => self.state = State::String,
            0x20..=0x2f => self.state = State::Intermediate,
            b'7' => self.saved = (self.x, self.y),
            b'8' => (self.x, self.y) = self.saved,
            b'\\' | b'=' | b'>' => {}
            b'c' => *self = Self::new(self.columns, self.rows.len()),
            0x1b => self.state = State::Esc,
            other => return Err(format!("ESC {}", other as char)),
        }
        self.last = None;
        Ok(())
    }

    fn csi(&mut self, params: &[u8], last: u8) -> Result<(), String> {
        self.last = None;
        let private = params.first().is_some_and(|b| matches!(b, b'?' | b'>' | b'<' | b'='));
        let intermediate = params.iter().any(|b| (0x20..=0x2f).contains(b));
        if private || intermediate {
            // Modes, cursor style, queries: nothing a screen dump draws with.
            return match last {
                b'h' | b'l' | b'q' | b'p' | b'c' | b'n' | b'm' | b's' | b'u' | b't' => Ok(()),
                _ => Err(format!("CSI {} {}", String::from_utf8_lossy(params), last as char)),
            };
        }
        let text = std::str::from_utf8(params).map_err(|_| "an invalid control sequence".to_string())?;
        if last == b'm' {
            self.sgr(text);
            return Ok(());
        }
        if last == b'h' || last == b'l' {
            // ANSI modes: only insert mode (4) changes how text draws.
            return if text.split(';').any(|mode| mode == "4") {
                Err("insert mode".into())
            } else {
                Ok(())
            };
        }
        let values: Vec<usize> = text
            .split(';')
            .map(|p| p.split(':').next().unwrap_or("").parse().unwrap_or(0))
            .collect();
        let at = |index: usize| values.get(index).copied().unwrap_or(0);
        let count = at(0).max(1);
        let (columns, rows) = (self.columns, self.rows.len());
        match last {
            b'H' | b'f' => {
                self.y = (at(0).max(1) - 1).min(rows - 1);
                self.x = (at(1).max(1) - 1).min(columns - 1);
            }
            b'A' => self.y = self.y.saturating_sub(count),
            b'B' | b'e' => self.y = (self.y + count).min(rows - 1),
            b'C' | b'a' => self.x = (self.x + count).min(columns - 1),
            b'D' => self.x = self.x.saturating_sub(count),
            b'E' => (self.x, self.y) = (0, (self.y + count).min(rows - 1)),
            b'F' => (self.x, self.y) = (0, self.y.saturating_sub(count)),
            b'G' | b'`' => self.x = (count - 1).min(columns - 1),
            b'd' => self.y = (count - 1).min(rows - 1),
            b'J' => match at(0) {
                0 => {
                    self.erase(self.y, self.x, columns);
                    for row in self.y + 1..rows {
                        self.erase(row, 0, columns);
                    }
                }
                1 => {
                    for row in 0..self.y {
                        self.erase(row, 0, columns);
                    }
                    self.erase(self.y, 0, self.x + 1);
                }
                2 | 3 => {
                    for row in 0..rows {
                        self.erase(row, 0, columns);
                    }
                }
                _ => {}
            },
            b'K' => match at(0) {
                0 => self.erase(self.y, self.x, columns),
                1 => self.erase(self.y, 0, self.x + 1),
                2 => self.erase(self.y, 0, columns),
                _ => {}
            },
            b'X' => self.erase(self.y, self.x, (self.x + count).min(columns)),
            b's' => self.saved = (self.x, self.y),
            b'u' => (self.x, self.y) = self.saved,
            // Status reports and window operations draw nothing.
            b'n' | b'c' | b't' => {}
            other => {
                return Err(format!("CSI {text} {}", other as char));
            }
        }
        Ok(())
    }

    /// Only faint matters: SGR 2 sets it, 0 (or an empty list) and 22 clear it; extended colors (38, 48, 58)
    /// carry their arguments in the parameters after them, or in colon subparameters.
    fn sgr(&mut self, text: &str) {
        let params: Vec<&str> = text.split(';').collect();
        let mut index = 0;
        while index < params.len() {
            let param = params[index];
            index += 1;
            if param.contains(':') {
                continue;
            }
            match param.parse::<u32>().unwrap_or(0) {
                0 => self.faint = false,
                2 => self.faint = true,
                22 => self.faint = false,
                38 | 48 | 58 => match params.get(index).and_then(|p| p.parse::<u32>().ok()) {
                    Some(5) => index += 2,
                    Some(2) => index += 4,
                    _ => {}
                },
                _ => {}
            }
        }
    }

    /// Blank `start..end` of `row`; a wide character cut in two loses both halves.
    fn erase(&mut self, row: usize, start: usize, end: usize) {
        let cells = &mut self.rows[row];
        let end = end.min(cells.len());
        if start >= end {
            return;
        }
        if cells[start].tail && start > 0 {
            cells[start - 1] = Cell::default();
        }
        if end < cells.len() && cells[end].tail {
            cells[end] = Cell::default();
        }
        for cell in &mut cells[start..end] {
            *cell = Cell::default();
        }
    }

    fn print(&mut self, text: &str) {
        let point = text.chars().next().map_or(0, u32::from);
        let width = crate::system::capture::screen::columns(point);
        if width == 0 {
            if let Some((y, x)) = self.last {
                self.rows[y][x].text.push_str(text);
            }
            return;
        }
        let (x, y) = (self.x, self.y);
        let wide = width == 2 && x + 1 < self.columns;
        self.erase(y, x, if wide { x + 2 } else { x + 1 });
        self.rows[y][x] = Cell { text: text.into(), faint: self.faint, tail: false };
        if wide {
            self.rows[y][x + 1] = Cell { text: String::new(), faint: self.faint, tail: true };
        }
        self.last = Some((y, x));
        // Without autowrap the cursor stops at the last column; the next character overwrites it.
        self.x = (x + if wide { 2 } else { 1 }).min(self.columns - 1);
    }
}

#[cfg(test)]
#[path = "cells.test.rs"]
mod tests;
