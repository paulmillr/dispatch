//! A terminal screen fed a stream's bytes (docs/replay.md, Scrub captures): a program that redraws only the cells that changed
//! jumps the cursor over cells already showing the right byte, so a needle it draws is whole on the screen and in no
//! run of bytes. It draws what the terminal that showed the stream drew (Ghostty, the app's and herdr's: its tests
//! compare with it, screen.fixtures): the stream's size, autowrap, scroll regions, insert and delete, the alternate
//! screen, origin mode, tab stops, wide characters, and the rewrap a resize does; escape sequences cut by pieces keep
//! their meaning. Each cell keeps the byte it shows and where that byte was written.
use std::collections::VecDeque;

mod width;

/// A screen whose stream names no size: large, no autowrap, scrolling at its last row only.
pub const ROWS: usize = 256;
pub const COLS: usize = 1024;
/// Rows a sized screen keeps above itself: a resize that adds rows brings them back, as the terminal does (a resize
/// adds at most this many).
const HISTORY: usize = ROWS;

/// A line as drawn (a row and the rows it wraps into): its text (a blank is a space), each cell's writer and the bytes
/// written just before and after that writer in one run of text (no control or escape between: what text the cell's
/// byte belongs to); `row` is its first row, None for a line the piece took off the screen (scrolled out, deleted,
/// cleared).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line<P> {
    pub row: Option<usize>,
    pub text: Vec<u8>,
    pub cells: Vec<Option<P>>,
    pub links: Vec<(Option<u8>, Option<u8>)>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Wide {
    No,
    Head,
    Tail,
    /// The last cell of a row a wide character did not fit in: no character, dropped by a rewrap.
    Spacer,
}

#[derive(Clone)]
struct Cell<P> {
    byte: u8,
    writer: Option<P>,
    wide: Wide,
    links: (Option<u8>, Option<u8>),
}

impl<P> Cell<P> {
    fn blank() -> Self {
        Self { byte: b' ', writer: None, wide: Wide::No, links: (None, None) }
    }
}

/// A row: its cells (blanks past the end), whether it wraps into the next row, whether a piece drew on it since it
/// was last returned.
#[derive(Clone)]
struct Row<P> {
    cells: Vec<Cell<P>>,
    wrapped: bool,
    drawn: bool,
}

impl<P> Row<P> {
    fn blank() -> Self {
        Self { cells: Vec::new(), wrapped: false, drawn: false }
    }
}

/// The cursor; `pending`: the last column was written and the next character wraps first.
#[derive(Clone, Copy, Default)]
struct Cursor {
    r: usize,
    c: usize,
    pending: bool,
    origin: bool,
}

/// Where the parser is between bytes: in text, an escape, its intermediates, a CSI (its bytes in `params`), a string
/// (OSC, DCS, ...) or its terminating ESC, a charset designation's last byte, or a UTF-8 character's later bytes.
#[derive(Clone, Copy)]
enum State {
    Ground,
    Esc,
    Intermediate,
    Csi,
    String { bell: bool },
    StringEsc { bell: bool },
    Designate,
    Utf8,
}

pub struct Screen<P> {
    /// The normal and the alternate buffer; `history`: rows scrolled off the normal one.
    buffers: [VecDeque<Row<P>>; 2],
    history: VecDeque<Row<P>>,
    alternate: bool,
    size: Option<(usize, usize)>,
    rows: usize,
    cols: usize,
    cursor: Cursor,
    /// Cursors saved by DECSC (per buffer) and by entering the alternate buffer with 1049.
    saved: [Cursor; 2],
    top: usize,
    bottom: usize,
    autowrap: bool,
    insert: bool,
    /// Tab stops a program set or cleared (HTS, TBC); None: every 8th column.
    tabs: Option<Vec<bool>>,
    /// The last character drawn (for REP): its byte, writer and width.
    last: Option<(u8, Option<P>, usize)>,
    /// The cell of the last character drawn while text runs on (no control or escape since).
    run: Option<(usize, usize)>,
    state: State,
    params: Vec<u8>,
    /// A UTF-8 character being read: its bytes so far and its first byte's writer.
    utf8: (Vec<u8>, Option<P>),
    /// Lines the current piece took off the screen.
    gone: Vec<Line<P>>,
}

impl<P: Clone> Default for Screen<P> {
    fn default() -> Self {
        Self::new()
    }
}

impl<P: Clone> Screen<P> {
    /// A screen of a stream whose size is not known (yet).
    pub fn new() -> Self {
        let mut screen = Self {
            buffers: [VecDeque::new(), VecDeque::new()],
            history: VecDeque::new(),
            alternate: false,
            size: None,
            rows: ROWS,
            cols: COLS,
            cursor: Cursor::default(),
            saved: [Cursor::default(); 2],
            top: 0,
            bottom: ROWS - 1,
            autowrap: true,
            insert: false,
            tabs: None,
            last: None,
            run: None,
            state: State::Ground,
            params: Vec::new(),
            utf8: (Vec::new(), None),
            gone: Vec::new(),
        };
        screen.reset();
        screen
    }

    pub fn sized(rows: usize, columns: usize) -> Self {
        let mut screen = Self::new();
        screen.resize(rows, columns);
        screen
    }

    /// (rows, columns), once the stream named its size.
    pub fn size(&self) -> Option<(usize, usize)> {
        self.size
    }

    /// The terminal's new size: the normal buffer rewraps its lines (wrapped rows join, rows past the width wrap) and
    /// keeps the cursor's row on the screen (blank rows below it go first, then rows above it, into the history; rows
    /// added come back from the history), the alternate buffer is cut; the scroll region becomes the whole screen.
    pub fn resize(&mut self, rows: usize, columns: usize) {
        let (rows, columns) = (rows.max(1), columns.max(1));
        self.run = None;
        let main = if self.alternate { self.saved[1] } else { self.cursor };
        let (history, _) = rewrap(self.history.drain(..).collect(), None, self.cols, columns);
        let (mut screen, main) = rewrap(self.buffers[0].drain(..).collect(), Some(main), self.cols, columns);
        let (mut history, mut main): (VecDeque<Row<P>>, Cursor) = (history.into(), main.unwrap_or_default());
        fit(&mut screen, &mut main, rows, Some(&mut history));
        while history.len() > HISTORY {
            history.pop_front();
        }
        (self.history, self.buffers[0]) = (history, screen.into());
        let mut alternate: Vec<Row<P>> = self.buffers[1].drain(..).collect();
        let used = !alternate.is_empty();
        for row in alternate.iter_mut() {
            cut(&mut row.cells, columns);
            row.wrapped = false;
        }
        let mut other = if self.alternate { self.cursor } else { self.saved[1] };
        fit(&mut alternate, &mut other, rows, None);
        if used {
            self.buffers[1] = alternate.into();
        }
        if self.alternate {
            self.cursor = other;
        }
        (self.size, self.rows, self.cols, self.top, self.bottom) = (Some((rows, columns)), rows, columns, 0, rows - 1);
        self.tabs = None;
        let clamp = |cursor: Cursor| Cursor { r: cursor.r.min(rows - 1), c: cursor.c.min(columns - 1), pending: false, ..cursor };
        if self.alternate {
            (self.saved[1], self.cursor) = (clamp(main), clamp(self.cursor));
        } else {
            self.cursor = clamp(main);
        }
        self.saved[0] = clamp(self.saved[0]);
    }

    /// Feeds a piece (its byte i written at `at(i)`): each line it takes off the screen goes to `gone` as it goes (a
    /// piece can be megabytes); returns the lines it drew on.
    pub fn feed(&mut self, bytes: &[u8], at: &dyn Fn(usize) -> P, gone: &mut dyn FnMut(Line<P>)) -> Vec<Line<P>> {
        for (index, byte) in bytes.iter().enumerate() {
            self.step(*byte, &|| at(index));
            self.gone.drain(..).for_each(&mut *gone);
        }
        let mut out = Vec::new();
        let starts: Vec<usize> = (0..self.rows).filter(|row| self.rows()[*row].drawn).map(|row| self.start(row)).collect();
        for row in starts.iter().copied().collect::<std::collections::BTreeSet<_>>() {
            out.push(self.line(row));
        }
        for row in self.rows_mut() {
            row.drawn = false;
        }
        out
    }

    /// Every line of the shown buffer holding a written cell (tests).
    pub fn lines(&self) -> Vec<Line<P>> {
        (0..self.rows).filter(|row| *row == self.start(*row)).map(|row| self.line(row))
            .filter(|line| line.cells.iter().any(Option::is_some)).collect()
    }

    /// The `index`-th cell of the line starting at `row` shows `byte` now.
    pub fn set(&mut self, row: usize, index: usize, byte: u8) {
        let (row, column) = (row + index / self.cols, index % self.cols);
        if let Some(cell) = self.rows_mut().get_mut(row).and_then(|row| row.cells.get_mut(column)) {
            cell.byte = byte;
        }
    }

    fn rows(&self) -> &VecDeque<Row<P>> {
        &self.buffers[usize::from(self.alternate)]
    }

    fn rows_mut(&mut self) -> &mut VecDeque<Row<P>> {
        &mut self.buffers[usize::from(self.alternate)]
    }

    /// The first row of the line holding `row`.
    fn start(&self, mut row: usize) -> usize {
        while row > 0 && self.rows()[row - 1].wrapped {
            row -= 1;
        }
        row
    }

    fn line(&self, row: usize) -> Line<P> {
        joined(self.rows().iter().skip(row), self.cols, Some(row))
    }

    fn step(&mut self, byte: u8, writer: &dyn Fn() -> P) {
        self.state = match (self.state, byte) {
            (State::Utf8, 0x80..=0xbf) => {
                self.utf8.0.push(byte);
                if self.utf8.0.len() < utf8_length(self.utf8.0[0]) {
                    return;
                }
                self.character();
                State::Ground
            }
            (State::Utf8, _) => {
                self.character();
                self.state = State::Ground;
                return self.step(byte, writer);
            }
            (State::Ground | State::Csi, 0x1b) => {
                self.run = None;
                State::Esc
            }
            (State::Ground | State::Csi, 0..=0x1f) => {
                self.control(byte);
                self.state
            }
            (State::Ground, 0x7f) => State::Ground,
            (State::Ground, 0xc0..=0xff) => {
                self.utf8 = (vec![byte], Some(writer()));
                State::Utf8
            }
            // A byte that starts no character (a lone continuation) shows as one cell.
            (State::Ground, 0x80..=0xbf) => {
                self.print(b'?', Some(writer()), 1);
                State::Ground
            }
            (State::Ground, _) => {
                self.print(byte, Some(writer()), 1);
                State::Ground
            }
            (State::Esc, b'[') => {
                self.params.clear();
                State::Csi
            }
            (State::Esc, b']') => State::String { bell: true },
            (State::Esc, b'P' | b'_' | b'^' | b'X') => State::String { bell: false },
            (State::Esc, b'(' | b')' | b'*' | b'+') => State::Designate,
            (State::Esc | State::Intermediate, 0x20..=0x2f) => State::Intermediate,
            (State::Esc, _) => {
                self.escape(byte);
                State::Ground
            }
            (State::Intermediate | State::Designate, _) => State::Ground,
            (State::Csi, 0x20..=0x3f) => {
                self.params.push(byte);
                State::Csi
            }
            (State::Csi, 0x40..=0x7e) => {
                self.csi(byte);
                State::Ground
            }
            (State::Csi, _) => State::Ground,
            (State::String { bell: true }, 0x07) => State::Ground,
            (State::String { bell }, 0x1b) => State::StringEsc { bell },
            (State::String { bell }, _) => State::String { bell },
            (State::StringEsc { .. }, b'\\') => State::Ground,
            (State::StringEsc { bell }, _) => State::String { bell },
        };
    }

    /// The UTF-8 character read so far, drawn as '?' in as many cells as the terminal gives it.
    fn character(&mut self) {
        let (bytes, writer) = std::mem::take(&mut self.utf8);
        let width = std::str::from_utf8(&bytes).ok().and_then(|text| text.chars().next()).map_or(1, |char| columns(char as u32));
        self.print(b'?', writer, width);
    }

    fn control(&mut self, byte: u8) {
        self.run = None;
        match byte {
            b'\r' => self.cursor = Cursor { c: 0, pending: false, ..self.cursor },
            b'\n' | 0x0b | 0x0c => self.index(),
            0x08 => self.cursor = Cursor { c: self.cursor.c.saturating_sub(1), pending: false, ..self.cursor },
            b'\t' => self.tab(1),
            _ => {}
        }
    }

    fn escape(&mut self, byte: u8) {
        match byte {
            b'7' => self.saved[usize::from(self.alternate)] = self.cursor,
            b'8' => self.cursor = self.saved[usize::from(self.alternate)],
            b'D' => self.index(),
            b'E' => {
                self.cursor.c = 0;
                self.index();
            }
            b'M' => self.reverse(),
            b'H' if self.cursor.c < self.cols => {
                let column = self.cursor.c;
                self.stops()[column] = true;
            }
            b'c' => {
                for buffer in 0..2 {
                    for row in 0..self.buffers[buffer].len() {
                        self.leave(buffer, row);
                    }
                }
                self.reset();
            }
            _ => {}
        }
    }

    fn csi(&mut self, last: u8) {
        let params = std::mem::take(&mut self.params);
        // Private sequences other than modes, and any with intermediates (DECSTR, DECSCUSR, ...), draw nothing.
        let private = params.first() == Some(&b'?');
        if params.iter().any(|byte| (0x20..=0x2f).contains(byte)) || matches!(params.first(), Some(b'>' | b'<' | b'=')) {
            return;
        }
        let numbers: Vec<usize> = params[usize::from(private)..].split(|byte| *byte == b';')
            .map(|part| std::str::from_utf8(part).ok().and_then(|text| text.parse().ok()).unwrap_or(0)).collect();
        let at = |index: usize| numbers.get(index).copied().filter(|number| *number > 0).unwrap_or(1);
        if private {
            if matches!(last, b'h' | b'l') {
                for mode in &numbers {
                    self.mode(*mode, last == b'h');
                }
            }
            return;
        }
        let (n, cursor) = (at(0), self.cursor);
        let (rows, cols) = (self.rows, self.cols);
        let (top, bottom) = if (self.top..=self.bottom).contains(&cursor.r) { (self.top, self.bottom) } else { (0, rows - 1) };
        let r#move = |r: usize, c: usize| Cursor { r, c: c.min(cols - 1), pending: false, ..cursor };
        match last {
            b'@' => self.shift(cursor.c, n, true),
            b'A' => self.cursor = r#move(cursor.r.saturating_sub(n).max(top), cursor.c),
            b'B' | b'e' => self.cursor = r#move((cursor.r + n).min(bottom), cursor.c),
            b'C' | b'a' => self.cursor = r#move(cursor.r, cursor.c + n),
            b'D' => self.cursor = r#move(cursor.r, cursor.c.saturating_sub(n)),
            b'E' => self.cursor = r#move((cursor.r + n).min(bottom), 0),
            b'F' => self.cursor = r#move(cursor.r.saturating_sub(n).max(top), 0),
            b'G' | b'`' => self.cursor = r#move(cursor.r, n - 1),
            b'H' | b'f' => self.cursor = r#move(self.row(at(0)), at(1) - 1),
            b'd' => self.cursor = r#move(self.row(n), cursor.c),
            b'I' => self.tab(n),
            b'Z' => self.tab_back(n),
            b'J' => self.erase_display(numbers.first().copied().unwrap_or(0)),
            b'K' => self.erase_line(numbers.first().copied().unwrap_or(0)),
            b'L' | b'M' if (self.top..=self.bottom).contains(&cursor.r) => {
                for _ in 0..n.min(self.bottom + 1 - cursor.r) {
                    self.scroll(cursor.r, self.bottom, last == b'M', false);
                }
                self.cursor = r#move(cursor.r, 0);
            }
            b'P' => self.shift(cursor.c, n, false),
            b'S' => (0..n).for_each(|_| self.scroll(self.top, self.bottom, true, false)),
            b'T' if numbers.len() <= 1 => (0..n).for_each(|_| self.scroll(self.top, self.bottom, false, false)),
            b'X' => {
                self.cursor.pending = false;
                let end = (cursor.c + n).min(cols);
                let cells = &mut self.rows_mut()[cursor.r].cells;
                unsplit(cells, cursor.c, end);
                for column in cursor.c..end.min(cells.len()) {
                    cells[column] = Cell::blank();
                }
            }
            b'b' => {
                if let Some((byte, writer, width)) = self.last.clone() {
                    (0..n).for_each(|_| self.print(byte, writer.clone(), width));
                }
            }
            b'g' => match numbers.first().copied().unwrap_or(0) {
                0 if cursor.c < cols => self.stops()[cursor.c] = false,
                3 => self.stops().iter_mut().for_each(|stop| *stop = false),
                _ => {}
            },
            b'h' | b'l' if numbers.contains(&4) => self.insert = last == b'h',
            b'r' => {
                let (first, last) = (at(0) - 1, numbers.get(1).copied().filter(|n| *n > 0).unwrap_or(rows).min(rows) - 1);
                if first < last {
                    (self.top, self.bottom) = (first, last);
                    self.cursor = Cursor { r: if cursor.origin { first } else { 0 }, c: 0, pending: false, ..cursor };
                }
            }
            b's' => self.saved[usize::from(self.alternate)] = cursor,
            b'u' => self.cursor = self.saved[usize::from(self.alternate)],
            _ => {}
        }
    }

    /// The screen row of a CUP/VPA row (1-based): inside the scroll region in origin mode.
    fn row(&self, number: usize) -> usize {
        if self.cursor.origin {
            (self.top + number - 1).min(self.bottom)
        } else {
            (number - 1).min(self.rows - 1)
        }
    }

    fn mode(&mut self, mode: usize, on: bool) {
        match mode {
            6 => {
                self.cursor.origin = on;
                self.cursor = Cursor { r: if on { self.top } else { 0 }, c: 0, pending: false, ..self.cursor };
            }
            7 => self.autowrap = on,
            47 | 1047 | 1049 if on != self.alternate => {
                if mode == 1049 && on {
                    self.saved[1] = self.cursor;
                }
                let rows = self.rows;
                self.buffers[1].resize_with(rows, Row::blank);
                for row in 0..self.rows {
                    self.leave(usize::from(self.alternate), row);
                }
                if on && mode == 1049 || !on && mode == 1047 {
                    for row in 0..self.rows {
                        self.clear(1, row);
                    }
                }
                (self.alternate, self.run) = (on, None);
                if mode == 1049 && !on {
                    self.cursor = self.saved[1];
                }
            }
            1048 if on => self.saved[usize::from(self.alternate)] = self.cursor,
            1048 => self.cursor = self.saved[usize::from(self.alternate)],
            _ => {}
        }
    }

    /// Draws a character of `width` cells at the cursor (wrapping first when a row is full and autowrap is on). A screen
    /// of no size has no right edge: past its columns nothing is kept (a stream of long lines that is no terminal).
    fn print(&mut self, byte: u8, writer: Option<P>, width: usize) {
        if width == 0 {
            return;
        }
        if self.size.is_none() && self.cursor.c + width > self.cols {
            self.cursor.c += width;
            return;
        }
        let wraps = self.autowrap && self.size.is_some();
        if self.cursor.pending && wraps || width == 2 && self.cursor.c + 1 == self.cols && wraps {
            let (r, cols) = (self.cursor.r, self.cols);
            if !self.cursor.pending {
                let cells = &mut self.rows_mut()[r].cells;
                cells.resize_with(cols, Cell::blank);
                cells[cols - 1] = Cell { wide: Wide::Spacer, ..Cell::blank() };
            }
            self.rows_mut()[r].wrapped = true;
            self.cursor.c = 0;
            self.index();
        }
        if width == 2 && self.cursor.c + 1 == self.cols {
            return;
        }
        let (r, c) = (self.cursor.r, self.cursor.c);
        if self.insert {
            self.shift(c, width, true);
        }
        let before = self.run.and_then(|(row, column)| {
            let cell = self.rows_mut().get_mut(row)?.cells.get_mut(column)?;
            cell.links.1 = Some(byte);
            Some(cell.byte)
        });
        let cells = &mut self.rows_mut()[r].cells;
        unsplit(cells, c, c + width);
        if cells.len() < c + width {
            cells.resize_with(c + width, Cell::blank);
        }
        let links = (before, None);
        cells[c] = Cell { byte, writer: writer.clone(), wide: if width == 2 { Wide::Head } else { Wide::No }, links };
        if width == 2 {
            cells[c + 1] = Cell { byte, writer: writer.clone(), wide: Wide::Tail, links };
        }
        self.run = Some((r, c));
        self.rows_mut()[r].drawn = true;
        self.last = Some((byte, writer, width));
        self.cursor.pending = c + width >= self.cols && wraps;
        self.cursor.c = if self.size.is_some() { (c + width).min(self.cols - 1) } else { c + width };
    }

    /// Line feed: down a row, scrolling the region at its bottom.
    fn index(&mut self) {
        self.cursor.pending = false;
        if self.cursor.r == self.bottom {
            self.scroll(self.top, self.bottom, true, true);
        } else if self.cursor.r + 1 < self.rows {
            self.cursor.r += 1;
        }
    }

    fn reverse(&mut self) {
        self.cursor.pending = false;
        if self.cursor.r == self.top {
            self.scroll(self.top, self.bottom, false, false);
        } else {
            self.cursor.r = self.cursor.r.saturating_sub(1);
        }
    }

    /// Rows `top..=bottom` move up (a blank row comes in at `bottom`) or down (at `top`); the row pushed out leaves.
    /// A line feed (`keep`) that scrolls the normal screen's whole-screen region puts its top row in the history.
    fn scroll(&mut self, top: usize, bottom: usize, up: bool, keep: bool) {
        let buffer = usize::from(self.alternate);
        self.run = self.run.and_then(|(row, column)| match (up, row) {
            (_, row) if row < top || row > bottom => Some((row, column)),
            (true, row) if row > top => Some((row - 1, column)),
            (false, row) if row < bottom => Some((row + 1, column)),
            _ => None,
        });
        let out = if up { top } else { bottom };
        self.leave(buffer, out);
        let row = self.buffers[buffer].remove(out).unwrap_or_else(Row::blank);
        if keep && buffer == 0 && top == 0 && bottom + 1 == self.rows && self.size.is_some() {
            self.history.push_back(Row { drawn: false, ..row });
            if self.history.len() > HISTORY {
                self.history.pop_front();
            }
        }
        self.buffers[buffer].insert(if up { bottom } else { top }, Row::blank());
    }

    /// Inserts (`insert`) or deletes `n` cells at `column` of the cursor's row; the row keeps its width.
    fn shift(&mut self, column: usize, n: usize, insert: bool) {
        self.cursor.pending = false;
        let (r, cols) = (self.cursor.r, self.cols);
        let cells = &mut self.rows_mut()[r].cells;
        if column >= cells.len() {
            return;
        }
        unsplit(cells, column, column);
        if insert {
            let n = n.min(cols - column);
            cells.splice(column..column, (0..n).map(|_| Cell::blank()));
            cut(cells, cols);
        } else {
            let end = (column + n).min(cells.len());
            unsplit(cells, end, end);
            cells.drain(column..end);
        }
    }

    /// Forward `n` tab stops; at the last column the cursor stays and a pending wrap with it.
    fn tab(&mut self, n: usize) {
        for _ in 0..n {
            let next = (self.cursor.c + 1..self.cols).find(|column| self.stop(*column)).unwrap_or(self.cols - 1);
            if next != self.cursor.c {
                self.cursor = Cursor { c: next, pending: false, ..self.cursor };
            }
        }
    }

    fn tab_back(&mut self, n: usize) {
        for _ in 0..n {
            let previous = (0..self.cursor.c).rev().find(|column| self.stop(*column)).unwrap_or(0);
            self.cursor = Cursor { c: previous, pending: false, ..self.cursor };
        }
    }

    fn erase_display(&mut self, mode: usize) {
        let row = self.cursor.r;
        match mode {
            0 => {
                self.erase_line(0);
                (row + 1..self.rows).for_each(|row| self.clear(usize::from(self.alternate), row));
            }
            1 => {
                self.erase_line(1);
                (0..row).for_each(|row| self.clear(usize::from(self.alternate), row));
            }
            2 => (0..self.rows).for_each(|row| self.clear(usize::from(self.alternate), row)),
            3 if !self.alternate => self.history.clear(),
            _ => {}
        }
    }

    fn erase_line(&mut self, mode: usize) {
        self.cursor.pending = false;
        let (r, column) = (self.cursor.r, self.cursor.c);
        let row = &mut self.rows_mut()[r];
        match mode {
            0 => {
                unsplit(&mut row.cells, column, column);
                row.cells.truncate(column);
                row.wrapped = false;
            }
            1 => {
                unsplit(&mut row.cells, column + 1, column + 1);
                row.cells.iter_mut().take(column + 1).for_each(|cell| *cell = Cell::blank());
            }
            _ => {
                row.cells.clear();
                row.wrapped = false;
            }
        }
    }

    /// A row's content leaves the screen (returned if drawn since it was last returned) and the row is blank.
    fn clear(&mut self, buffer: usize, row: usize) {
        self.leave(buffer, row);
        self.buffers[buffer][row] = Row::blank();
    }

    fn leave(&mut self, buffer: usize, row: usize) {
        let rows = &self.buffers[buffer];
        if rows[row].drawn {
            let line = joined(rows.iter().skip(row), self.cols, None);
            if line.cells.iter().any(Option::is_some) {
                self.gone.push(line);
            }
            self.buffers[buffer][row].drawn = false;
        }
    }

    /// Both buffers blank, no history, the whole screen the scroll region, default modes and tab stops, the cursor home.
    fn reset(&mut self) {
        self.run = None;
        // The alternate buffer is made when a program first shows it: most streams never do.
        self.buffers = [(0..self.rows).map(|_| Row::blank()).collect(), VecDeque::new()];
        self.history.clear();
        (self.alternate, self.top, self.bottom, self.autowrap, self.insert) = (false, 0, self.rows - 1, true, false);
        (self.cursor, self.saved) = (Cursor::default(), [Cursor::default(); 2]);
        self.tabs = None;
    }

    fn stop(&self, column: usize) -> bool {
        self.tabs.as_ref().map_or(column > 0 && column % 8 == 0, |tabs| tabs[column])
    }

    fn stops(&mut self) -> &mut Vec<bool> {
        let cols = self.cols;
        self.tabs.get_or_insert_with(|| (0..cols).map(|column| column > 0 && column % 8 == 0).collect())
    }
}

fn utf8_length(lead: u8) -> usize {
    match lead {
        0xc0..=0xdf => 2,
        0xe0..=0xef => 3,
        _ => 4,
    }
}

/// The cells a code point takes: 0 (combining, format), 2 (East Asian wide or full width) or 1.
pub fn columns(point: u32) -> usize {
    let inside = |table: &[(u32, u32)]| table.binary_search_by(|(first, last)| {
        if *last < point { std::cmp::Ordering::Less } else if *first > point { std::cmp::Ordering::Greater } else { std::cmp::Ordering::Equal }
    }).is_ok();
    if inside(width::ZERO) { 0 } else if inside(width::WIDE) { 2 } else { 1 }
}

/// A wide character the cells `start..end` cut in two is blank on both sides.
fn unsplit<P>(cells: &mut [Cell<P>], start: usize, end: usize) {
    if cells.get(start).is_some_and(|cell| cell.wide == Wide::Tail) {
        cells[start - 1] = Cell::blank();
        cells[start] = Cell::blank();
    }
    if end > 0 && cells.get(end - 1).is_some_and(|cell| cell.wide == Wide::Head) && end <= cells.len() {
        cells[end - 1] = Cell::blank();
        if let Some(tail) = cells.get_mut(end) {
            *tail = Cell::blank();
        }
    }
}

/// A row cut to `columns` cells (a wide character cut in two goes).
fn cut<P>(cells: &mut Vec<Cell<P>>, columns: usize) {
    if cells.len() > columns {
        unsplit(cells, columns, columns);
        cells.truncate(columns);
    }
}

/// The line starting at the first of `rows` (it and the rows it wraps into): wrapped rows give `cols` cells each.
fn joined<'a, P: Clone + 'a>(rows: impl Iterator<Item = &'a Row<P>>, cols: usize, row: Option<usize>) -> Line<P> {
    let (mut text, mut cells, mut links) = (Vec::new(), Vec::new(), Vec::new());
    for each in rows {
        let width = if each.wrapped { cols } else { each.cells.len() };
        for column in 0..width {
            let cell = each.cells.get(column).cloned().unwrap_or_else(Cell::blank);
            text.push(cell.byte);
            cells.push(cell.writer);
            links.push(cell.links);
        }
        if !each.wrapped {
            break;
        }
    }
    while text.last() == Some(&b' ') && cells.last().is_some_and(Option::is_none) {
        text.pop();
        cells.pop();
        links.pop();
    }
    Line { row, text, cells, links }
}

/// `screen` made `rows` rows: fewer go blank rows below the cursor first, then rows above it (into `history` if any);
/// more come back from `history`, then blank rows at the bottom. The cursor stays on its row.
fn fit<P>(screen: &mut Vec<Row<P>>, cursor: &mut Cursor, rows: usize, mut history: Option<&mut VecDeque<Row<P>>>) {
    while screen.len() > rows && screen.len() > cursor.r + 1 && screen.last().is_some_and(|row| row.cells.iter().all(|cell| cell.writer.is_none())) {
        screen.pop();
    }
    while screen.len() > rows {
        let row = screen.remove(0);
        if let Some(history) = history.as_deref_mut() {
            history.push_back(row);
        }
        cursor.r = cursor.r.saturating_sub(1);
    }
    while screen.len() < rows {
        match history.as_deref_mut().and_then(VecDeque::pop_back) {
            Some(row) => {
                screen.insert(0, row);
                cursor.r += 1;
            }
            None => screen.push(Row::blank()),
        }
    }
}

/// `rows` (`old` cells wide) rewrapped to `new` cells: wrapped rows join into a line and every line is cut again (a
/// wide character never split; spacers dropped, trailing blanks too); the cursor (its row an index into `rows`) keeps
/// its place in its line.
fn rewrap<P: Clone>(rows: Vec<Row<P>>, cursor: Option<Cursor>, old: usize, new: usize) -> (Vec<Row<P>>, Option<Cursor>) {
    let (mut out, mut place, mut index) = (Vec::new(), None, 0);
    while index < rows.len() {
        let (mut line, mut offset): (Vec<Cell<P>>, Option<usize>) = (Vec::new(), None);
        loop {
            let row = &rows[index];
            if let Some(cursor) = cursor.filter(|cursor| cursor.r == index) {
                offset = Some(line.len() + cursor.c);
            }
            let width = if row.wrapped { old } else { row.cells.len() };
            line.extend((0..width).map(|column| row.cells.get(column).cloned().unwrap_or_else(Cell::blank)).filter(|cell| cell.wide != Wide::Spacer));
            index += 1;
            if !row.wrapped || index == rows.len() {
                break;
            }
        }
        while line.last().is_some_and(|cell| cell.writer.is_none()) && offset.is_none_or(|offset| line.len() > offset) {
            line.pop();
        }
        let (first, mut current, mut cells) = (out.len(), Row::blank(), line.into_iter());
        while let Some(cell) = cells.next() {
            let need = if cell.wide == Wide::Head { 2 } else { 1 };
            if current.cells.len() + need > new {
                if need == 2 && current.cells.len() + 1 == new {
                    current.cells.push(Cell { wide: Wide::Spacer, ..Cell::blank() });
                }
                current.wrapped = true;
                out.push(std::mem::replace(&mut current, Row::blank()));
            }
            current.cells.push(cell);
            if need == 2 {
                current.cells.extend(cells.next());
            }
        }
        out.push(current);
        if let (Some(offset), Some(cursor)) = (offset, cursor) {
            let r = first + offset / new;
            out.resize_with(out.len().max(r + 1), Row::blank);
            place = Some(Cursor { r, c: offset % new, pending: false, ..cursor });
        }
    }
    (out, place)
}

#[cfg(test)]
impl<P: Clone> Screen<P> {
    /// Every row shown, its bytes up to the last cell that is not blank.
    fn text(&self) -> Vec<Vec<u8>> {
        self.rows().iter().map(|row| {
            let mut bytes: Vec<u8> = row.cells.iter().map(|cell| cell.byte).collect();
            while bytes.last() == Some(&b' ') {
                bytes.pop();
            }
            bytes
        }).collect()
    }

    /// (column, row).
    fn cursor(&self) -> (usize, usize) {
        (self.cursor.c, self.cursor.r)
    }
}

#[cfg(test)]
#[path = "screen.test.rs"]
mod tests;
