//! Screens read from tmux itself for terminals no client renders (`Multiplexer::host_screens`, the queue drainer):
//! the pane's visible screen, its cursor row with attributes and its cursor, captured together, published to the
//! terminal's readers as a client's screen would be.
//!
//! What a client publishes (Dispatch/Terminal/TerminalBackend.swift publishScreen): Ghostty's plain text of the
//! active area (rows joined where they soft-wrapped, blank rows kept only before more text), the cursor cell and
//! whether everything after the cursor on its row is faint (Claude's placeholder). `capture-pane -J` joins wrapped
//! rows the same way; its empty rows at the bottom are dropped; the cursor row is captured again with its
//! attributes (`-e`) for the faint tail (dispatch_helper_core::cells). Clients publish on output, at most 30 times
//! a second; so does this: output since the last capture (`%output`) marks the screen stale, and while someone
//! reads the terminal each output captures again, no sooner than 33 ms after the last capture.
use crate::{
    commands, control,
    mux::{Continue, Tmux, error, finish},
};
use dispatch_helper_core::{api::*, cells::Cells};
use std::{
    cell::Cell,
    rc::Rc,
    time::{Duration, Instant},
};

/// The app's publication interval (TerminalBackend.swift ScreenPublication.interval, TerminalPresence
/// publishInterval).
const INTERVAL: Duration = Duration::from_millis(33);
/// Output keeps a terminal's screen current this long after its last read with no reader waiting.
const HOLD: Duration = Duration::from_secs(2);

#[derive(Default)]
pub(crate) struct Host {
    /// Output arrived since the last capture started.
    dirty: bool,
    capturing: bool,
    /// A capture waits for the interval since the last one.
    scheduled: bool,
    last: Option<Instant>,
    /// Reads keep output capturing until then.
    until: Option<Instant>,
}

/// One batch: the visible screen with wrapped rows joined, the cursor row with its attributes, the cursor.
pub(crate) fn commands(pane: u32) -> Vec<String> {
    let target = format!("%{pane}");
    vec![
        format!("capture-pane -p -J -N -C -t {target}"),
        format!("capture-pane -p -e -N -C -t {target} -S \"#{{cursor_y}}\" -E \"#{{cursor_y}}\""),
        format!(
            "display-message -p -t {target} {}",
            commands::quote("#{pane_id} #{pane_width} #{cursor_x} #{cursor_y}")
        ),
    ]
}

/// The screen a client renderer would publish from `commands`' replies.
pub(crate) fn parse(rows: &[control::Lines], pane: u32) -> Result<Screen, Error> {
    let [screen, row, state] = rows else {
        return Err(error("Invalid tmux screen capture"));
    };
    let state = String::from_utf8_lossy(state.text());
    let fields: Vec<&str> = state.split(' ').collect();
    let [id, width, x, y] = fields[..] else {
        return Err(error("Invalid tmux pane state"));
    };
    if id != format!("%{pane}") {
        return Err(error("Tmux pane changed during capture"));
    }
    let number = |value: &str| value.parse::<u32>().map_err(|_| error("Invalid tmux pane state"));
    let (width, x, y) = (number(width)?.max(1), number(x)?, number(y)?);
    let mut lines = screen
        .iter()
        .map(|line| control::decode(line, true).map(|line| line.into_owned()))
        .collect::<Result<Vec<_>, _>>()?;
    while lines.last().is_some_and(|line| line.is_empty()) {
        lines.pop();
    }
    // tmux leaves the cursor past the last column after writing it; the renderer keeps it on that column.
    let x = x.min(width - 1);
    let mut cells = Cells::new(width as usize, 1);
    let drawn = control::decode(row.iter().next().unwrap_or_default(), true)
        .map_err(|e| e.message)
        .and_then(|row| cells.feed(&row));
    Ok(Screen {
        text: String::from_utf8_lossy(&lines.join(&b'\n')).into_owned(),
        cursor: (x, y),
        // A row the grid cannot draw shows no placeholder rather than a guessed one.
        faint_tail: drawn.is_ok() && cells.faint_after(x as usize, 0),
    })
}

impl Tmux {
    /// Whether `screen` reads `node` from tmux: host screens are on and no client renders it.
    fn hosted(&self, node: Id) -> bool {
        self.host_screens && self.terminals.get(&node).is_some_and(|state| !state.client)
    }
    /// A screen read: keep output capturing for a while, and capture now if nothing current is shown.
    pub(crate) fn read_screen(&mut self, io: &mut dyn Io, node: Id) {
        if !self.hosted(node) {
            return;
        }
        let now = io.now();
        let state = self.terminals.get_mut(&node).unwrap();
        // Output was not followed while nobody read: the screen shown may be old.
        if state.host.until.is_none_or(|until| until <= now) {
            state.host.dirty = true;
        }
        state.host.until = Some(now + HOLD);
        self.capture_screen(io, node);
    }
    /// Output in a pane: its screen is stale; capture again while it is read.
    pub(crate) fn output_screen(&mut self, io: &mut dyn Io, node: Id) {
        if !self.hosted(node) {
            return;
        }
        let now = io.now();
        let state = self.terminals.get_mut(&node).unwrap();
        state.host.dirty = true;
        if !state.readers.is_empty() || state.host.until.is_some_and(|until| until > now) {
            self.capture_screen(io, node);
        }
    }
    fn capture_screen(&mut self, io: &mut dyn Io, node: Id) {
        if !self.hosted(node) {
            return;
        }
        let now = io.now();
        let state = &self.terminals[&node];
        if state.host.capturing
            || state.host.scheduled
            || state.screen.is_some() && !state.host.dirty
        {
            return;
        }
        if let Some(at) = state.host.last.map(|last| last + INTERVAL).filter(|at| *at > now) {
            // Io::after wakes this mux; its next Timer event resumes the capture (as typed() does).
            let next: Continue<bool> = Box::new(move |mux, io, _| {
                if let Some(state) = mux.terminals.get_mut(&node) {
                    state.host.scheduled = false;
                }
                mux.capture_screen(io, node);
            });
            let slot = Rc::new(Cell::new(Some(next)));
            let (later, resumes) = (slot.clone(), self.resumes.clone());
            let wake = Box::new(move |io: &mut dyn Io| {
                resumes.borrow_mut().extend(later.take());
                io.timer(io.now());
            });
            if io.after(at, wake).is_ok() {
                self.terminals.get_mut(&node).unwrap().host.scheduled = true;
                return;
            }
        }
        let Ok(loc) = self.location(node) else {
            return;
        };
        let state = self.terminals.get_mut(&node).unwrap();
        state.host.capturing = true;
        state.host.dirty = false;
        state.host.last = Some(now);
        let complete: Continue<Result<crate::client::Batch, Error>> =
            Box::new(move |mux, io, result| mux.captured_screen(io, node, loc.pane, result));
        self.request(
            io,
            loc,
            commands(loc.pane),
            Box::new(move |mux, io, result| mux.checked(io, loc, node, result, complete)),
        );
    }
    fn captured_screen(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        pane: u32,
        result: Result<crate::client::Batch, Error>,
    ) {
        let Some(state) = self.terminals.get_mut(&node) else {
            return;
        };
        state.host.capturing = false;
        if state.client {
            return;
        }
        // A failed capture is tried again on the next output, or the next read while no screen was shown; a closed
        // pane fails its readers (retire).
        if let Ok(screen) = result.and_then(|rows| parse(&rows, pane)) {
            self.show(io, node, screen);
        }
        let state = self.terminals.get_mut(&node).unwrap();
        if state.host.dirty
            && (!state.readers.is_empty() || state.host.until.is_some_and(|until| until > io.now()))
        {
            self.capture_screen(io, node);
        }
    }
    /// A new screen for `node`'s readers, from its client or from tmux: a reader waiting gets it, else the next
    /// read that asks for a change does.
    pub(crate) fn show(&mut self, io: &mut dyn Io, node: Id, screen: Screen) {
        if let Some(state) = self.terminals.get_mut(&node)
            && state.screen.as_ref() != Some(&screen)
        {
            state.screen = Some(screen.clone());
            state.changed = state.readers.is_empty();
            for done in std::mem::take(&mut state.readers) {
                finish(io, done, Ok(screen.clone()));
            }
        }
    }
}

#[cfg(test)]
#[path = "host.test.rs"]
mod tests;
