//! Screens read from tmux itself for terminals no client publishes for: every one with `Multiplexer::host_screens`
//! (the queue drainer), and those a screens.host client attaches (the Mac; `Terminal::hosting`). The pane's visible
//! screen, its cursor row with attributes and its cursor, captured together, published to the terminal's readers as
//! a client's screen would be. A client's publication (the iPhone) wins while it keeps the terminal attached
//! (`Terminal::published`).
//!
//! What a client publishes (Dispatch/Terminal/TerminalBackend.swift publishScreen): Ghostty's plain text of the
//! active area (rows joined where they soft-wrapped, blank rows kept only before more text), the cursor cell and
//! whether everything after the cursor on its row is faint (Claude's placeholder). `capture-pane -J` joins wrapped
//! rows the same way; its empty rows at the bottom are dropped; the cursor row is captured again with its
//! attributes (`-e`) for the faint tail (dispatch_helper_core::cells). Output since the last capture (`%output`)
//! marks the screen stale; while someone reads the terminal it is captured once the pane has been quiet for
//! `SETTLE`, or `FLOOR` after the first output of a run that never pauses (a spinner): a busy agent costs a few
//! `capture-pane` batches a second instead of one per repaint, and a prompt (the spinner stops) is read within
//! about `SETTLE`. A read while no current screen is shown captures at once, and a read of the screen now
//! (`changed: false`: sends, input checks, menu samples) waits for a capture whenever output came since the last one
//! started: it gets the pane as it is, as the app's publication right before such a call gave it.
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

/// A pane this long without output has settled: its screen is captured.
pub(crate) const SETTLE: Duration = Duration::from_millis(100);
/// Output that never settles is captured this long after it started, so a screen is at most this old.
pub(crate) const FLOOR: Duration = Duration::from_millis(500);
/// Output keeps a terminal's screen current this long after its last read with no reader waiting.
const HOLD: Duration = Duration::from_secs(2);

#[derive(Default)]
pub(crate) struct Host {
    /// The first and the latest output since the last capture started.
    output: Option<(Instant, Instant)>,
    /// The screen shown may be old (output was not followed, or none was shown): the next capture starts at once.
    stale: bool,
    capturing: bool,
    /// The capture timer asked for (one at a time; a later one wins).
    scheduled: Option<Instant>,
    /// Reads keep output capturing until then.
    until: Option<Instant>,
    /// Reads of the screen now (`changed: false`: sends, input checks, menu samples) that wait for a capture
    /// starting after they asked (`fresh`), and those the capture in flight answers, changed or not (`taken`).
    fresh: Vec<Done<Screen>>,
    taken: Vec<Done<Screen>>,
}

impl Host {
    /// Output at `now`.
    pub(crate) fn output(&mut self, now: Instant) {
        let first = self.output.map_or(now, |(first, _)| first);
        self.output = Some((first, now));
    }
    /// When the next capture starts: at once for a stale screen, else when the output settled or at the floor;
    /// None while nothing changed.
    pub(crate) fn due(&self, now: Instant) -> Option<Instant> {
        if self.stale {
            return Some(now);
        }
        self.output.map(|(first, last)| (last + SETTLE).min(first + FLOOR))
    }
    /// A capture starts: what it reads is current, for the reads of the screen now waiting too.
    pub(crate) fn started(&mut self) {
        self.output = None;
        self.stale = false;
        self.capturing = true;
        self.taken.append(&mut self.fresh);
    }
    /// The screen shown is the pane's now: one was captured, nothing came out since that capture started and
    /// none is in flight.
    pub(crate) fn current(&self, shown: bool) -> bool {
        shown && self.output.is_none() && !self.capturing && !self.stale
    }
    /// A read of the screen now that `current` refused: the capture in flight answers it when nothing came out
    /// since it started, else the next one, which starts at once.
    pub(crate) fn wait(&mut self, done: Done<Screen>) {
        if self.capturing && self.output.is_none() {
            self.taken.push(done);
        } else {
            self.fresh.push(done);
            self.stale = true;
        }
    }
    /// Every read of the screen now still waiting (a closed pane fails them).
    pub(crate) fn readers(&mut self) -> Vec<Done<Screen>> {
        let mut readers = std::mem::take(&mut self.taken);
        readers.append(&mut self.fresh);
        readers
    }

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
    /// Whether `screen` reads `node` from tmux: host screens are on (for every terminal, or a screens.host client
    /// attached it) and no client publishes for it.
    pub(crate) fn hosted(&self, node: Id) -> bool {
        self.terminals
            .get(&node)
            .is_some_and(|state| (self.host_screens || state.hosting) && !state.published)
    }
    /// Who supplies `node`'s screens (Multiplexer::screen_clients). Host reads that resume start from a stale
    /// screen: what was shown is the publisher's, or nothing.
    pub(crate) fn screen_clients(&mut self, io: &mut dyn Io, node: Id, hosting: bool, published: bool) {
        let was = self.hosted(node);
        let Some(state) = self.terminals.get_mut(&node) else {
            return;
        };
        state.hosting = hosting;
        state.published = published;
        if was && !self.hosted(node) {
            self.answer_now(io, node);
        }
        if !was && self.hosted(node) {
            let state = self.terminals.get_mut(&node).unwrap();
            state.host.stale = true;
            if self.wanted(io, node) {
                self.capture_screen(io, node);
            }
        }
    }
    /// Someone reads `node`: a reader waits, or a read was recent.
    fn wanted(&self, io: &dyn Io, node: Id) -> bool {
        self.terminals.get(&node).is_some_and(|state| {
            !state.readers.is_empty()
                || !state.host.fresh.is_empty()
                || !state.host.taken.is_empty()
                || state.host.until.is_some_and(|until| until > io.now())
        })
    }
    /// `screen`: the screen shown, or the next. A read of the screen now (`changed: false`) of a hosted terminal
    /// gets the pane as it is: the shown capture only while it is current, else the next capture's, even when it
    /// reads the same (a send checks the composer right after typing into it; the app published before each).
    pub(crate) fn read(&mut self, io: &mut dyn Io, node: Id, changed: bool, done: Done<Screen>) {
        let now = !changed && self.hosted(node);
        let state = self.terminals.entry(node).or_default();
        if now && !state.host.current(state.screen.is_some()) {
            state.host.wait(done);
        } else if let Some(screen) = state.screen.clone().filter(|_| !changed || state.changed) {
            state.changed = false;
            finish(io, done, Ok(screen));
        } else {
            state.readers.push(done);
        }
        self.read_screen(io, node);
    }
    /// Reads of the screen now that tmux will not answer (a client publishes, host reads stopped, the capture
    /// failed): the screen shown, else the next one shown.
    pub(crate) fn answer_now(&mut self, io: &mut dyn Io, node: Id) {
        let Some(state) = self.terminals.get_mut(&node) else {
            return;
        };
        let readers = state.host.readers();
        match state.screen.clone() {
            Some(screen) => readers.into_iter().for_each(|done| finish(io, done, Ok(screen.clone()))),
            None => state.readers.extend(readers),
        }
    }
    /// A screen read: keep output capturing for a while, and capture now if nothing current is shown.
    pub(crate) fn read_screen(&mut self, io: &mut dyn Io, node: Id) {
        if !self.hosted(node) {
            return;
        }
        let now = io.now();
        let state = self.terminals.get_mut(&node).unwrap();
        // Output was not followed while nobody read: the screen shown may be old.
        if state.screen.is_none() || state.host.until.is_none_or(|until| until <= now) {
            state.host.stale = true;
        }
        state.host.until = Some(now + HOLD);
        self.capture_screen(io, node);
    }
    /// Output in a pane: its screen is stale; capture again (paced) while it is read.
    pub(crate) fn output_screen(&mut self, io: &mut dyn Io, node: Id) {
        if !self.hosted(node) {
            return;
        }
        let now = io.now();
        self.terminals.get_mut(&node).unwrap().host.output(now);
        if self.wanted(io, node) {
            self.capture_screen(io, node);
        }
    }
    fn capture_screen(&mut self, io: &mut dyn Io, node: Id) {
        if !self.hosted(node) {
            return;
        }
        let now = io.now();
        let state = &self.terminals[&node];
        if state.host.capturing {
            return;
        }
        let Some(due) = state.host.due(now) else {
            return;
        };
        if due > now {
            // The timer asked earlier comes first and asks again; Io::after wakes this mux, its next Timer event
            // resumes the capture (as typed() does).
            if state.host.scheduled.is_some_and(|at| at <= due) {
                return;
            }
            let next: Continue<bool> = Box::new(move |mux, io, _| {
                let Some(state) = mux.terminals.get_mut(&node).filter(|state| state.host.scheduled == Some(due)) else {
                    return;
                };
                state.host.scheduled = None;
                if mux.wanted(io, node) {
                    mux.capture_screen(io, node);
                }
            });
            let slot = Rc::new(Cell::new(Some(next)));
            let (later, resumes) = (slot.clone(), self.resumes.clone());
            let wake = Box::new(move |io: &mut dyn Io| {
                resumes.borrow_mut().extend(later.take());
                io.timer(io.now());
            });
            if io.after(due, wake).is_ok() {
                self.terminals.get_mut(&node).unwrap().host.scheduled = Some(due);
                return;
            }
        }
        let Ok(loc) = self.location(node) else {
            return;
        };
        self.terminals.get_mut(&node).unwrap().host.started();
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
        // A client published meanwhile: its screen stays.
        if !self.hosted(node) {
            return self.answer_now(io, node);
        }
        // A failed capture is tried again on the next output, or the next read while no screen was shown; a closed
        // pane fails its readers (retire). The reads of the screen now it took get what it read, changed or not.
        let taken = std::mem::take(&mut self.terminals.get_mut(&node).unwrap().host.taken);
        match result.and_then(|rows| parse(&rows, pane)) {
            Ok(screen) => {
                self.show(io, node, screen.clone());
                for done in taken {
                    finish(io, done, Ok(screen.clone()));
                }
            }
            Err(_) => {
                let state = self.terminals.get_mut(&node).unwrap();
                state.host.taken = taken;
                self.answer_now(io, node);
            }
        }
        if self.wanted(io, node) {
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
