//! Screens read from herdr itself for terminals no client renders (`Multiplexer::host_screens`, the queue drainer).
//!
//! A client renders herdr's terminal frames and publishes its screen (TerminalBackend.swift publishScreen). herdr's
//! socket API reads a pane's text (`pane.read`) but not its cursor, which the faint tail needs (Claude's
//! placeholder starts at the cursor). So the helper observes the terminal as a client would see it: `herdr terminal
//! session observe <terminal>` (read-only, at the pane's own size, never resizing it) streams the same frames a
//! controller gets, a full frame first and then changes, each ending with the cursor. They are drawn into a cell
//! grid (dispatch_helper_core::cells, which renders text and the faint tail as the app's renderer does) and every
//! frame publishes the screen to the terminal's readers, as a client's publication does. The observer runs while
//! the terminal is read (a reader waiting, or a read within `HOLD`), and ends when a client attaches or publishes.
//! Its client socket connection goes through a verified relay, as a controller's does (relay.rs).
use super::*;
use dispatch_helper_core::cells::Cells;
use relay::Holder;
use std::os::fd::RawFd;

/// An observer stays this long after the last read of its terminal with no reader waiting.
const HOLD: Duration = Duration::from_secs(2);
/// After an observer failed, reads wait this long before starting another, twice as long after each failure in a
/// row (up to `LONGEST`) until one draws a change.
const RETRY: Duration = Duration::from_secs(1);
/// A frame the grid cannot draw restarts the observer (its first frame is a full one) sooner.
const REDRAW: Duration = Duration::from_millis(200);
const LONGEST: Duration = Duration::from_secs(30);

pub(super) struct Observer {
    pub(super) relay: Option<relay::Relay>,
    pub(super) pid: Option<u32>,
    pub(super) stream: Option<Stream>,
    pub(super) stderr: Option<RawFd>,
    /// The grid drawn so far and the last frame's sequence number.
    grid: Option<(Cells, u64)>,
    /// Reads keep the observer running until then.
    until: Instant,
    /// The latest timer this observer asked for.
    armed: Instant,
    /// A frame after the full one drew: the observer works.
    changed: bool,
}

impl Observer {
    fn new(until: Instant) -> Self {
        Self { relay: None, pid: None, stream: None, stderr: None, grid: None, until, armed: until, changed: false }
    }
    /// One line of the observed stream; the screen when it drew one. Frames out of order or from before a
    /// resize are skipped; a change without the full frame it applies to fails, so the observer starts again.
    pub(super) fn line(&mut self, line: &[u8]) -> Result<Option<Screen>, Error> {
        let json = Json::parse(line)?;
        let v = json.root();
        match text(v, "type")?.as_str() {
            "terminal.frame" => {}
            "terminal.reset" => {
                self.grid = None;
                return Ok(None);
            }
            "terminal.closed" => {
                return Err(expired(
                    optional(v, "reason")?.unwrap_or_else(|| "Herdr terminal closed.".into()),
                ));
            }
            _ => return Ok(None),
        }
        let number = |key: &str| {
            field(v, key)?
                .unsigned()
                .ok_or_else(|| error("Invalid herdr terminal frame."))
        };
        let (seq, width, height) = (number("seq")?, number("width")?, number("height")?);
        let full = v.get("full").and_then(Value::boolean) == Some(true);
        if text(v, "encoding")? != "ansi" || !(1..=10_000).contains(&width) || !(1..=10_000).contains(&height) {
            return Err(error("Invalid herdr terminal frame."));
        }
        let size = (width as usize, height as usize);
        if self.grid.as_ref().is_some_and(|(_, last)| seq <= *last) {
            return Ok(None);
        }
        if full {
            self.grid = Some((Cells::new(size.0, size.1), seq));
        }
        let Some((cells, last)) = self.grid.as_mut().filter(|(cells, _)| cells.size() == size) else {
            return Err(error("Herdr sent a change without its full frame."));
        };
        *last = seq;
        let bytes = native::decode(&text(v, "bytes")?)?;
        cells
            .feed(&bytes)
            .map_err(|sequence| error(format!("Herdr frame not drawn: {sequence}.")))?;
        self.changed |= !full;
        Ok(Some(cells.screen()))
    }
    /// Close its process, streams and relay; what it learned stays.
    fn close(mut self, io: &mut dyn Io) -> Self {
        if let Some(relay) = self.relay.take() {
            relay.close(io);
        }
        if let Some(stream) = self.stream.take() {
            stream.close(io);
        }
        if let Some(fd) = self.stderr.take() {
            io.close(fd);
        }
        if let Some(pid) = self.pid.take() {
            let _ = io.terminate(pid);
        }
        self
    }
}

fn optional(v: Value<'_>, key: &str) -> Result<Option<String>, Error> {
    match v.get(key) {
        None => Ok(None),
        Some(value) => value
            .string()
            .map(|s| Some(s.to_owned()))
            .ok_or_else(|| error("Invalid herdr terminal frame.")),
    }
}

impl Herdr {
    /// `screen` reads `terminal` from herdr: host screens are on and no client renders it.
    pub(super) fn hosted(&self, terminal: Id) -> bool {
        self.host_screens && !self.controllers.contains_key(&terminal) && !self.clients.contains(&terminal)
    }
    /// Turned off, running observers end at their next timer.
    pub(super) fn set_host_screens(&mut self, enabled: bool) {
        self.host_screens = enabled;
        for endpoint in self.endpoints.values_mut() {
            endpoint.set_host_screens(enabled);
        }
    }
    /// A read of `terminal`: keep its observer, or start one.
    pub(super) fn observe_screen(&mut self, io: &mut dyn Io, terminal: Id) {
        if !self.hosted(terminal) {
            return;
        }
        let now = io.now();
        let until = now + HOLD;
        if let Some(observer) = self.observers.get_mut(&terminal) {
            observer.until = until;
            return;
        }
        if let Some((retry, _)) = self.unobserved.get(&terminal).filter(|(retry, _)| *retry > now) {
            // The reader waits for the retry (observe_timer).
            io.timer(*retry);
            return;
        }
        match self.session(io, terminal, &["observe"]) {
            Ok(controller::Session { owner, relay, pid, input, output, stderr }) => {
                let deadline = relay.deadline;
                let mut observer = Observer::new(until);
                observer.relay = Some(relay);
                observer.pid = Some(pid);
                observer.stream = Some(Stream::new(input, output));
                observer.stderr = stderr;
                self.observers.insert(terminal, observer);
                self.relay_setup(io, Holder::Observer(terminal), owner);
                io.timer(deadline);
                io.timer(until);
            }
            Err(_) => self.retry(io, terminal, RETRY),
        }
    }
    /// End `terminal`'s observer; its last screen goes (a later read waits for a current one), its waiting readers
    /// stay. A failure delays the next observer; a closed terminal fails its readers.
    pub(super) fn unobserve(&mut self, io: &mut dyn Io, terminal: Id, failure: Option<Error>) {
        let Some(observer) = self.observers.remove(&terminal) else {
            return;
        };
        let observer = observer.close(io);
        self.screens.forget(terminal);
        if observer.changed {
            self.unobserved.remove(&terminal);
        }
        if let Some(failure) = failure {
            let redraw = failure.message.starts_with("Herdr frame not drawn")
                || failure.message.starts_with("Herdr sent a change");
            self.retry(io, terminal, if redraw { REDRAW } else { RETRY });
        }
        if self.locate(terminal).is_err() {
            self.screens
                .close(io, terminal, expired("This herdr terminal is no longer available."));
        }
    }
    /// Timers: a relay that never connected fails its observer; an observer nobody read within `HOLD` (and no
    /// reader waits on) ends; a reader waiting on a failed observer starts the next one.
    pub(super) fn observe_timer(&mut self, io: &mut dyn Io, at: Instant) {
        let ids: Vec<Id> = self.observers.keys().copied().collect();
        for id in ids {
            let observer = &self.observers[&id];
            if observer.relay.as_ref().is_some_and(|relay| relay.expired(at)) {
                self.unobserve(io, id, Some(error("Timed out waiting for the herdr observer.")));
                continue;
            }
            let waiting = self.screens.waiting(id);
            if !self.hosted(id) {
                self.unobserve(io, id, None);
                continue;
            }
            let observer = self.observers.get_mut(&id).unwrap();
            if observer.until <= at && !waiting {
                self.unobserve(io, id, None);
                continue;
            }
            if observer.until <= at {
                observer.until = at + HOLD;
            }
            if observer.armed < observer.until {
                observer.armed = observer.until;
                io.timer(observer.until);
            }
        }
        let retries: Vec<Id> = self
            .unobserved
            .iter()
            .filter(|(id, (retry, _))| *retry <= at && self.screens.waiting(**id))
            .map(|(id, _)| *id)
            .collect();
        for id in retries {
            self.observe_screen(io, id);
        }
    }
    /// No observer for `terminal` before `delay` (doubled for each failure since one last worked) has passed; a
    /// reader waiting then starts the next.
    fn retry(&mut self, io: &mut dyn Io, terminal: Id, delay: Duration) {
        let failures = self.unobserved.get(&terminal).map_or(0, |(_, failures)| *failures);
        let delay = delay.saturating_mul(1 << failures.min(8)).min(LONGEST);
        let at = io.now() + delay;
        self.unobserved.insert(terminal, (at, failures + 1));
        if self.screens.waiting(terminal) {
            io.timer(at);
        }
    }
    /// The observer that owns `fd` (its stream or its stderr).
    pub(super) fn observer_of(&self, fd: RawFd) -> Option<Id> {
        self.observers
            .iter()
            .find(|(_, observer)| {
                observer.stderr == Some(fd)
                    || observer.stream.as_ref().is_some_and(|s| s.input == fd || s.output == fd)
            })
            .map(|(id, _)| *id)
    }
    pub(super) fn observer_ready(&mut self, io: &mut dyn Io, id: Id, fd: RawFd, read: bool) {
        let observer = self.observers.get_mut(&id).unwrap();
        if observer.stderr == Some(fd) {
            // Diagnostics are not kept: a failed observer only delays the next one.
            let mut bytes = [0; 4096];
            match io.read(fd, &mut bytes) {
                Ok(0) => {
                    io.close(fd);
                    observer.stderr = None;
                }
                Err(e) if !matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted) => {
                    io.close(fd);
                    observer.stderr = None;
                }
                _ => {}
            }
            return;
        }
        if !read || observer.stream.as_ref().is_none_or(|stream| stream.output != fd) {
            return;
        }
        let (lines, eof) = match observer.stream.as_mut().unwrap().read(io) {
            Ok(read) => read,
            Err(e) => return self.unobserve(io, id, Some(e)),
        };
        let mut drawn = None;
        for line in lines {
            match self.observers.get_mut(&id).unwrap().line(&line) {
                Ok(Some(screen)) => drawn = Some(screen),
                Ok(None) => {}
                Err(e) => {
                    if let Some(screen) = drawn.take() {
                        self.observed(io, id, screen);
                    }
                    return self.unobserve(io, id, Some(e));
                }
            }
        }
        // A read holding several frames publishes the last: a client publishes what it shows after drawing them.
        if let Some(screen) = drawn {
            self.observed(io, id, screen);
        }
        if eof {
            self.unobserve(io, id, Some(error("Herdr observer ended.")));
        }
    }
    fn observed(&mut self, io: &mut dyn Io, id: Id, screen: Screen) {
        if self.hosted(id) {
            self.screens.publish(io, id, screen);
        }
    }
    /// An observer process exited: read what it wrote last, then end it.
    pub(super) fn observer_exit(&mut self, io: &mut dyn Io, pid: u32) {
        let Some(id) = self
            .observers
            .iter()
            .find(|(_, observer)| observer.pid == Some(pid))
            .map(|(id, _)| *id)
        else {
            return;
        };
        // Its exit is delivered; nothing to terminate.
        self.observers.get_mut(&id).unwrap().pid = None;
        if let Some(fd) = self.observers[&id].stream.as_ref().map(|stream| stream.output) {
            self.observer_ready(io, id, fd, true);
        }
        self.unobserve(io, id, Some(error("Herdr observer exited.")));
    }
}

#[cfg(test)]
#[path = "observe.test.rs"]
mod tests;
