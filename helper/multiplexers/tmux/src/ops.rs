use crate::{
    commands, control,
    mux::{Continue, Tmux, error, finish, gone},
    terminal,
};
use dispatch_helper_core::{
    api::*,
    json::{self, Data},
};
use std::{cell::Cell, rc::Rc};
#[derive(Clone, Copy)]
pub(crate) struct Location {
    pub backend: Id,
    pub client: usize,
    pub pane: u32,
}
pub(crate) struct Terminal {
    ready: bool,
    capturing: bool,
    history: bool,
    filter: terminal::Filter,
    pending: Vec<u8>,
    pub(crate) writers: Vec<Done<()>>,
    captures: Vec<Done<()>>,
    pub screen: Option<Screen>,
    pub changed: bool,
    pub(crate) readers: Vec<Done<Screen>>,
    /// Repeated captures with the same disagreement; changed dimensions make progress.
    unsettled: u32,
    dimensions: Option<([String; 2], [u32; 2])>,
    /// The last restore failed: no restore is coming until the app attaches again.
    failed: bool,
}
impl Default for Terminal {
    fn default() -> Self {
        Self {
            ready: false,
            capturing: false,
            history: false,
            filter: terminal::Filter::new(control::MAXIMUM),
            pending: Vec::new(),
            writers: Vec::new(),
            captures: Vec::new(),
            screen: None,
            changed: false,
            readers: Vec::new(),
            unsettled: 0,
            dimensions: None,
            failed: false,
        }
    }
}
impl Tmux {
    pub(crate) fn terminal(&self, loc: Location) -> Option<Id> {
        let back = self.backends.get(&loc.backend)?;
        let session = back.clients.get(loc.client)?.snapshot.as_ref()?.session;
        back.ids.get(&format!("${session}:%{}", loc.pane)).copied()
    }
    pub(crate) fn target(&self, node: Id) -> Result<(Location, String), Error> {
        if let Some((backend, session, _)) = self.groups.roots.get(&node)
            && let Some(client) = self.backends.get(backend).and_then(|back| {
                back.clients.iter().position(|client| {
                    client.live()
                        && client
                            .snapshot
                            .as_ref()
                            .is_some_and(|state| state.session == *session)
                })
            })
        {
            return Ok((
                Location {
                    backend: *backend,
                    client,
                    pane: 0,
                },
                format!("${session}"),
            ));
        }
        for (&backend, back) in &self.backends {
            let Some(key) = back
                .ids
                .iter()
                .find_map(|(key, id)| (*id == node).then_some(key))
            else {
                continue;
            };
            let (session, target) = key.split_once(':').unwrap_or((key, ""));
            if let Some(client) = back.clients.iter().position(|c| {
                c.live()
                    && c.snapshot
                        .as_ref()
                        .is_some_and(|s| session == format!("${}", s.session))
            }) && !target.contains(':')
            {
                return Ok((
                    Location {
                        backend,
                        client,
                        pane: 0,
                    },
                    if target.is_empty() {
                        session.into()
                    } else {
                        target.into()
                    },
                ));
            }
        }
        // A relayed backend waiting for its re-claim keeps its nodes (C11): not ended.
        let waiting = self
            .backends
            .values()
            .any(|b| b.suspended() && b.ids.values().any(|id| *id == node));
        Err(if waiting {
            error("Tmux node is no longer available")
        } else {
            gone("Tmux node is no longer available")
        })
    }
    pub(crate) fn location(&self, node: Id) -> Result<Location, Error> {
        let (loc, target) = self.target(node)?;
        let pane = crate::snapshot::id(&target, '%')? as u32;
        let client = &self.backends[&loc.backend].clients[loc.client];
        if client.dismissed.contains(&pane)
            || !client.snapshot.as_ref().unwrap().panes.contains_key(&pane)
            || client.snapshot.as_ref().unwrap().windows.iter().any(|window| {
                client.closed.contains(&window.id) && window.layout.pane(pane).is_some()
            })
        {
            return Err(gone("Tmux pane closed"));
        }
        Ok(Location { pane, ..loc })
    }
    fn on<T: 'static>(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        done: Done<T>,
        action: impl FnOnce(&mut Self, &mut dyn Io, Location, Done<T>),
    ) {
        match self.location(node) {
            Ok(loc) => action(self, io, loc, done),
            Err(e) => finish(io, done, Err(e)),
        }
    }
    pub(crate) fn unit(
        &mut self,
        io: &mut dyn Io,
        loc: Location,
        commands: Vec<String>,
        done: Done<()>,
    ) {
        self.request(
            io,
            loc,
            commands,
            Box::new(move |_, io, result| finish(io, done, result.map(|_| ()))),
        );
    }
    pub(crate) fn input(&mut self, io: &mut dyn Io, node: Id, bytes: &[u8], done: Done<()>) {
        self.on(io, node, done, |mux, io, loc, done| {
            if bytes.is_empty() {
                finish(io, done, Ok(()));
                return;
            }
            let state = mux.terminals.entry(node).or_default();
            if state.ready {
                mux.unit(io, loc, commands::input(bytes, u64::from(loc.pane)), done);
            } else if state.failed && !state.capturing {
                // Held input waits for a restore (c1654cc bufferedInput); after a failed one
                // none is coming until the app attaches again.
                finish(
                    io,
                    done,
                    Err(error("The tmux pane was not restored; attach it again.")),
                );
            } else if bytes.len() > 1_048_576usize.saturating_sub(state.pending.len()) {
                finish(
                    io,
                    done,
                    Err(error(
                        "Input is waiting for the tmux pane to finish restoring.",
                    )),
                );
            } else {
                state.pending.extend_from_slice(bytes);
                state.writers.push(done);
            }
        });
    }
    fn grid(&mut self, node: Id, loc: Location, size: Grid) -> Result<Vec<String>, Error> {
        if size.columns == 0 || size.rows == 0 || size.columns > 10000 || size.rows > 10000 {
            return Err(error("Invalid tmux terminal grid"));
        }
        self.sizes.insert(node, size);
        let snapshot = self.backends[&loc.backend].clients[loc.client]
            .snapshot
            .as_ref()
            .unwrap();
        let window = snapshot
            .windows
            .iter()
            .find(|w| w.layout.pane(loc.pane).is_some())
            .ok_or_else(|| gone("Tmux window closed"))?;
        fn measure(
            mux: &Tmux,
            loc: Location,
            cell: &crate::topology::Layout,
        ) -> Option<(u32, u32)> {
            use crate::topology::Content;
            match &cell.content {
                Content::Pane(pane) => {
                    let grid = mux
                        .sizes
                        .get(&mux.terminal(Location { pane: *pane, ..loc })?)?;
                    let native = &mux.backends[&loc.backend].clients[loc.client]
                        .snapshot
                        .as_ref()?
                        .panes[pane];
                    Some((
                        u32::from(grid.columns) + cell.width.saturating_sub(native.width),
                        u32::from(grid.rows) + cell.height.saturating_sub(native.height),
                    ))
                }
                Content::Split(axis, children) => {
                    let sizes = children
                        .iter()
                        .map(|c| measure(mux, loc, c))
                        .collect::<Option<Vec<_>>>()?;
                    let borders = sizes.len().saturating_sub(1) as u32;
                    Some(if *axis == Axis::Columns {
                        (
                            sizes.iter().map(|s| s.0).sum::<u32>() + borders,
                            sizes.iter().map(|s| s.1).max()?,
                        )
                    } else {
                        (
                            sizes.iter().map(|s| s.0).max()?,
                            sizes.iter().map(|s| s.1).sum::<u32>() + borders,
                        )
                    })
                }
            }
        }
        let size = measure(self, loc, &window.visible)
            .filter(|s| s.0 <= 10000 && s.1 <= 10000);
        let current = (window.layout.width, window.layout.height);
        let window = window.id;
        let client = &mut self.backends.get_mut(&loc.backend).unwrap().clients[loc.client];
        Ok(size
            .filter(|s| client.available.get(&window).copied().unwrap_or(current) != *s)
            .map(|(x, y)| {
                client.available.insert(window, (x, y));
                vec![format!("refresh-client -C @{window}:{x}x{y}")]
            })
            .unwrap_or_default())
    }
    pub(crate) fn resize(&mut self, io: &mut dyn Io, node: Id, size: Grid, done: Done<()>) {
        self.on(io, node, done, |mux, io, loc, done| {
            match mux.grid(node, loc, size) {
                Ok(commands) if !commands.is_empty() => {
                    let count = commands.len();
                    mux.mutate(io, loc, commands, count, done)
                }
                result => finish(io, done, result.map(|_| ())),
            }
        });
    }
    pub(crate) fn attach(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        size: Grid,
        takeover: bool,
        done: Done<()>,
    ) {
        let preserve = !takeover && self.terminals.get(&node).is_some_and(|s| s.history);
        self.capture(io, node, Some(size), preserve, done);
    }
    fn checked(
        &mut self,
        io: &mut dyn Io,
        loc: Location,
        node: Id,
        result: Result<crate::client::Batch, Error>,
        done: Continue<Result<crate::client::Batch, Error>>,
    ) {
        if result.is_err() && self.location(node).is_ok() {
            // A pane can exit before its topology notification starts a refresh. Classify the
            // failed read against a fresh snapshot, never against that older cached pane set.
            let complete: Continue<Result<(), Error>> = Box::new(move |mux, io, fresh| {
                let result = match (fresh, mux.location(node)) {
                    (Ok(()), Err(error)) if error.code == "expired" => Err(error),
                    _ => result,
                };
                done(mux, io, result);
            });
            let client = &mut self.backends.get_mut(&loc.backend).unwrap().clients[loc.client];
            if client.refreshing {
                if client.again {
                    client.later.push(complete);
                } else {
                    client.waiters.push(complete);
                }
            } else {
                self.refresh(io, loc, Some(complete));
            }
        } else {
            done(self, io, result);
        }
    }
    fn capture(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        size: Option<Grid>,
        preserve: bool,
        done: Done<()>,
    ) {
        self.on(io, node, done, |mux, io, loc, done| {
            let mut commands =
                match size.map_or_else(|| Ok(Vec::new()), |size| mux.grid(node, loc, size)) {
                    Ok(c) => c,
                    Err(e) => {
                        finish(io, done, Err(e));
                        return;
                    }
                };
            let state = mux.terminals.entry(node).or_default();
            if state.capturing {
                let complete: Continue<Result<crate::client::Batch, Error>> =
                    Box::new(move |mux, io, result| {
                        if let Err(error) = result {
                            finish(io, done, Err(error));
                        } else if let Some(state) =
                            mux.terminals.get_mut(&node).filter(|state| state.capturing)
                        {
                            state.captures.push(done);
                        } else {
                            mux.capture(io, node, None, preserve, done);
                        }
                    });
                if commands.is_empty() {
                    complete(mux, io, Ok(Vec::new()));
                } else {
                    mux.request(
                        io,
                        loc,
                        commands,
                        Box::new(move |mux, io, result| {
                            mux.checked(io, loc, node, result, complete);
                        }),
                    );
                }
                return;
            }
            state.ready = false;
            state.capturing = true;
            commands.extend(include_str!("capture.tmux").lines().map(|s| {
                s.replace("PANE", &format!("%{}", loc.pane))
                    .replace("HISTORY", if preserve { "0" } else { "-" })
            }));
            let complete: Continue<Result<crate::client::Batch, Error>> =
                Box::new(move |mux, io, result| {
                    if !mux.terminals.contains_key(&node) {
                        finish(io, done, Err(gone("Tmux pane detached during capture")));
                        return;
                    }
                    let mut dimensions = None;
                    let outcome = (|| -> Result<(), Error> {
                        if let Err(error) = mux.location(node)
                            && error.code == "expired"
                        {
                            return Err(error);
                        }
                        let rows = result?;
                        let rows = &rows[rows.len() - 5..];
                        let text = String::from_utf8_lossy(rows[3].text()).into_owned();
                        let state = text
                            .split('|')
                            .map(|s| {
                                s.split_once('=')
                                    .map(|(k, v)| (k.into(), v.into()))
                                    .ok_or_else(|| error("Invalid pane state"))
                            })
                            .collect::<Result<std::collections::BTreeMap<String, String>, _>>()?;
                        let native = mux.backends[&loc.backend].clients[loc.client]
                            .snapshot
                            .as_ref()
                            .and_then(|s| s.panes.get(&loc.pane))
                            .ok_or_else(|| gone("Tmux pane closed during capture"))?;
                        if state.get("pane_id") != Some(&format!("%{}", loc.pane)) {
                            return Err(error("Tmux pane changed during capture"));
                        }
                        let actual = ["pane_width", "pane_height"]
                            .map(|key| state.get(key).cloned().unwrap_or_default());
                        let expected = [native.width, native.height];
                        if actual != expected.map(|value| value.to_string()) {
                            dimensions = Some((actual, expected));
                            return Err(Error {
                                code: "stale",
                                message: "Tmux capture needs refreshed dimensions".into(),
                            });
                        }
                        let decode = |rows: &control::Lines| {
                            rows.iter()
                                .map(|r| control::decode(r, true).map(Cow::into_owned))
                                .collect::<Result<Vec<_>, _>>()
                        };
                        let capture = terminal::Snapshot {
                            screen: decode(&rows[0])?,
                            saved: decode(&rows[1])?,
                            cursor: control::decode(
                                rows[2].iter().next().unwrap_or_default(),
                                true,
                            )?
                            .into_owned(),
                            state,
                            preserve,
                        };
                        let mut bytes = capture.bytes(control::MAXIMUM)?;
                        let pending = control::decode(rows[4].text(), false)?.into_owned();
                        let state = mux.terminals.get_mut(&node).unwrap();
                        state.filter = terminal::Filter::new(control::MAXIMUM);
                        bytes.extend_from_slice(&state.filter.feed(&pending)?);
                        mux.updates.push(Update::Output {
                            terminal: node,
                            bytes,
                        });
                        Ok(())
                    })();
                    let state = mux.terminals.get_mut(&node).unwrap();
                    state.capturing = false;
                    state.ready = outcome.is_ok();
                    state.history |= outcome.is_ok();
                    let stale = outcome.as_ref().is_err_and(|e| e.code == "stale");
                    state.unsettled = if stale {
                        if state.dimensions == dimensions {
                            state.unsettled + 1
                        } else {
                            1
                        }
                    } else {
                        0
                    };
                    state.dimensions = dimensions;
                    // A resize racing the capture settles after one relist (c1654cc
                    // TmuxSession "relist first"); sizes that still disagree after three
                    // unchanged relists never will, and the old endless retry hid that.
                    let outcome = if state.unsettled == 3 {
                        state.unsettled = 0;
                        Err(error("Tmux pane size kept changing during capture"))
                    } else {
                        outcome
                    };
                    // A stale capture is retried below; any other error ends this restore.
                    state.failed = outcome.as_ref().is_err_and(|e| e.code != "stale");
                    if outcome.as_ref().is_err_and(|e| e.code == "stale") {
                        mux.refresh(
                            io,
                            loc,
                            Some(Box::new(move |mux, io, result| match result {
                                // The initial size was applied already; a newer resize may
                                // have arrived while this capture was in flight.
                                Ok(()) => mux.capture(io, node, None, preserve, done),
                                Err(e) => mux.captured(io, node, done, Err(e)),
                            })),
                        );
                        return;
                    }
                    let bytes = std::mem::take(&mut state.pending);
                    let writers = std::mem::take(&mut state.writers);
                    mux.captured(io, node, done, outcome.clone());
                    if outcome.is_ok() && !bytes.is_empty() {
                        mux.input(
                            io,
                            node,
                            &bytes,
                            Box::new(move |io, result| {
                                for done in writers {
                                    finish(io, done, result.clone());
                                }
                            }),
                        );
                    } else {
                        for done in writers {
                            finish(io, done, outcome.clone());
                        }
                    }
                });
            mux.request(
                io,
                loc,
                commands,
                Box::new(move |mux, io, result| {
                    mux.checked(io, loc, node, result, complete);
                }),
            );
        });
    }
    fn captured(&mut self, io: &mut dyn Io, node: Id, done: Done<()>, result: Result<(), Error>) {
        let captures = self
            .terminals
            .get_mut(&node)
            .map(|state| std::mem::take(&mut state.captures))
            .unwrap_or_default();
        finish(io, done, result.clone());
        for done in captures {
            finish(io, done, result.clone());
        }
    }
    pub(crate) fn screen(&mut self, io: &mut dyn Io, node: Id, changed: bool, done: Done<Screen>) {
        self.on(io, node, done, |mux, io, _, done| {
            let state = mux.terminals.entry(node).or_default();
            if let Some(screen) = state.screen.clone().filter(|_| !changed || state.changed) {
                state.changed = false;
                finish(io, done, Ok(screen));
            } else {
                state.readers.push(done);
            }
        });
    }
    pub(crate) fn output(&mut self, io: &mut dyn Io, loc: Location, bytes: &[u8]) {
        let Some(node) = self.terminal(loc) else {
            return;
        };
        // A live process can change conversations without changing pane topology. Output
        // rescans are paced (discover): agents redraw continuously.
        self.discovery.output = true;
        if let Some(state) = self.terminals.get_mut(&node).filter(|s| s.ready) {
            match state.filter.feed(bytes) {
                Ok(b) if !b.is_empty() => self.updates.push(Update::Output {
                    terminal: node,
                    bytes: b.into_owned(),
                }),
                // Past the sequence limit the renderer state is unknown: restore the screen
                // from a fresh capture (old code asked the user to reattach).
                Err(_) => {
                    state.ready = false;
                    self.capture(io, node, None, false, Box::new(|_, _| {}));
                }
                _ => {}
            }
        }
    }
    pub(crate) fn notification(&mut self, io: &mut dyn Io, loc: Location, line: &str) {
        if let Some(pane) = line
            .strip_prefix("%pause ")
            .and_then(|value| crate::snapshot::id(value, '%').ok())
            .and_then(|pane| u32::try_from(pane).ok())
        {
            let loc = Location { pane, ..loc };
            self.unit(
                io,
                loc,
                vec![format!(
                    "refresh-client -A {}",
                    commands::quote(&format!("%{pane}:continue"))
                )],
                Box::new(|_, _| {}),
            );
            if let Some(node) = self.terminal(loc)
                && self
                    .terminals
                    .get(&node)
                    .is_some_and(|state| !state.capturing)
            {
                self.capture(io, node, None, false, Box::new(|_, _| {}));
            }
        }
        if let Some(name) = line.strip_prefix("%paste-buffer-changed ") {
            let name = name.to_owned();
            self.request(
                io,
                loc,
                vec![format!(
                    "list-buffers -F {}",
                    commands::quote("#{buffer_size} #{buffer_name}")
                )],
                Box::new(move |mux, io, result| {
                    let size = result.ok().and_then(|r| {
                        r[0].iter().find_map(|row| {
                            let (n, v) = std::str::from_utf8(row).ok()?.split_once(' ')?;
                            (v == name).then(|| n.parse::<usize>().ok()).flatten()
                        })
                    });
                    if size.is_some_and(|n| n <= 8 * 1024 * 1024) {
                        mux.request(
                            io,
                            loc,
                            vec![format!("show-buffer -b {}", commands::quote(&name))],
                            Box::new(|mux, _, result| {
                                if let Ok(rows) = result {
                                    mux.updates.push(Update::Clipboard {
                                        bytes: rows[0].text().to_vec(),
                                    });
                                }
                            }),
                        );
                    }
                }),
            );
        }
    }
    pub(crate) fn retire(&mut self, io: &mut dyn Io) {
        for node in self
            .terminals
            .keys()
            .copied()
            .filter(|id| {
                self.location(*id).is_err()
                    && !self
                        .backends
                        .values()
                        .any(|b| b.suspended() && b.ids.values().any(|node| node == id))
            })
            .collect::<Vec<_>>()
        {
            let state = self.terminals.remove(&node).unwrap();
            for done in state.readers {
                finish(io, done, Err(gone("Tmux pane closed")));
            }
            for done in state.writers {
                finish(io, done, Err(gone("Tmux pane closed")));
            }
            for done in state.captures {
                finish(io, done, Err(gone("Tmux pane closed")));
            }
            self.updates.push(Update::Exit {
                terminal: node,
                status: None,
            });
        }
    }
    pub fn check(&mut self, io: &mut dyn Io, node: Id, process: &Process, done: Done<()>) {
        self.ownership(
            io,
            node,
            process.clone(),
            Box::new(move |_, io, result| {
                finish(io, done, result.map(|_| ()));
            }),
        );
    }
    /// Harness typing. Each native write gets its own fresh pane check, pinned to the shell
    /// the first check saw (c51466a tmux_submit.rs:87-152, 250-255); a Paste settles before
    /// the next element, 100 ms for a Codex /exit or /quit, else 300 ms (:58-66). A refusal
    /// before the first write is not sent; any failure after one is `uncertain` and is never
    /// retried (:153-213, 321-334).
    pub fn keys(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        process: &Process,
        inputs: &[Input],
        done: Done<()>,
    ) {
        let loc = match self.location(node) {
            Ok(loc) => loc,
            Err(e) => return finish(io, done, Err(e)),
        };
        let kind = self.agents.get(&node).and_then(|(index, binding)| {
            (binding.process.pid == process.pid && binding.process.start == process.start)
                .then_some(*index)
        });
        let mut steps = std::collections::VecDeque::new();
        for input in inputs {
            steps.extend(
                commands::keys(std::slice::from_ref(input), u64::from(loc.pane))
                    .into_iter()
                    .map(Ok),
            );
            if let Input::Paste(text) = input {
                let quick = kind
                    .is_some_and(|index| self.harnesses[index].borrow().key() == "codex")
                    && ["/exit", "/quit"].contains(&text.as_str());
                steps.push_back(Err(std::time::Duration::from_millis(if quick {
                    100
                } else {
                    300
                })));
            }
        }
        self.typed(io, node, process.clone(), kind, steps, None, done);
    }
    /// One step of keys: Ok = checked native write, Err = settle. `shell` is the pinned shell
    /// once something was written.
    #[allow(clippy::too_many_arguments)]
    fn typed(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        expected: Process,
        kind: Option<usize>,
        mut steps: std::collections::VecDeque<Result<String, std::time::Duration>>,
        shell: Option<Process>,
        done: Done<()>,
    ) {
        let uncertain = |message: &str| Error {
            code: "uncertain",
            message: message.into(),
        };
        let command = match steps.pop_front() {
            None => return finish(io, done, Ok(())),
            Some(Ok(command)) => command,
            Some(Err(delay)) => {
                // Io::after records the requested deadline; its callback wakes this mux, whose
                // next Timer event resumes the remaining steps.
                let next: Continue<bool> = Box::new(move |mux, io, settled| {
                    if settled {
                        mux.typed(io, node, expected, kind, steps, shell, done);
                    } else {
                        let failed = uncertain("Tmux input did not finish; it was not retried");
                        finish(io, done, Err(failed));
                    }
                });
                let slot = Rc::new(Cell::new(Some(next)));
                let (later, resumes) = (slot.clone(), self.resumes.clone());
                let wake = Box::new(move |io: &mut dyn Io| {
                    resumes.borrow_mut().extend(later.take());
                    io.timer(io.now());
                });
                if io.after(io.now() + delay, wake).is_err() {
                    slot.take().unwrap()(self, io, false);
                }
                return;
            }
        };
        self.ownership(
            io,
            node,
            expected.clone(),
            Box::new(move |mux, io, result| {
                // Old tmux.rs:613-651: every failed ownership or mode check is UnsafeInput.
                let unsafe_input = || error("Tmux agent ownership or input mode is unavailable");
                // Native ownership and input modes govern harness typing. Renderer
                // recapture during resize does not revoke that independent ownership.
                let admitted = result.map_err(|_| unsafe_input()).and_then(|(loc, mode, current)| {
                    if shell.as_ref().is_some_and(|s| (s.pid, s.start) != (current.pid, current.start))
                        || mode[..4].iter().any(|v| v != "0")
                        || mode[4] == "0"
                    {
                        return Err(unsafe_input());
                    }
                    if mode[4].is_empty() && kind.is_none() {
                        return Err(error(
                            "This tmux server cannot report bracketed-paste state. Use the terminal to send input.",
                        ));
                    }
                    Ok((loc, current))
                });
                match admitted {
                    Err(e) if shell.is_none() => finish(io, done, Err(e)),
                    Err(_) => finish(
                        io,
                        done,
                        Err(uncertain("Tmux input failed or ownership changed; it was not retried")),
                    ),
                    Ok((loc, current)) => mux.request(
                        io,
                        loc,
                        vec![command],
                        Box::new(move |mux, io, result| match result {
                            Ok(_) => mux.typed(io, node, expected, kind, steps, Some(current), done),
                            Err(_) => finish(
                                io,
                                done,
                                Err(uncertain("Tmux input did not finish; it was not retried")),
                            ),
                        }),
                    ),
                }
            }),
        );
    }
    pub(crate) fn ownership(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        expected: Process,
        done: Continue<Result<(Location, [String; 5], Process), Error>>,
    ) {
        let loc = match self.location(node) {
            Ok(loc) if self.backends[&loc.backend].remote => {
                done(
                    self,
                    io,
                    Err(error("A relayed tmux pane has no local process facts")),
                );
                return;
            }
            Ok(value) => value,
            Err(e) => {
                done(self, io, Err(e));
                return;
            }
        };
        let format = commands::quote(concat!(
            "#{pid}|#{pane_pid}|#{pane_tty}|#{pane_id}|",
            "#{pane_in_mode}|#{pane_input_off}|#{pane_dead}|",
            "#{pane_synchronized}|#{bracket_paste_flag}",
        ));
        let query = format!("display-message -p -t %{} {format}", loc.pane);
        self.request(
            io,
            loc,
            vec![query],
            Box::new(move |mux, io, result| {
                let guard = (|| {
                    let rows = result?;
                    let [rows] = rows.as_slice() else {
                        return Err(error("Invalid tmux pane state"));
                    };
                    if rows.len() != 1 {
                        return Err(error("Invalid tmux pane state"));
                    }
                    let bytes = rows.text();
                    if bytes.len() >= 8192 {
                        return Err(error("Invalid tmux pane state"));
                    }
                    let server = mux.backends[&loc.backend].clients[loc.client]
                        .snapshot
                        .as_ref()
                        .ok_or_else(|| error("Tmux topology is unavailable"))?
                        .server;
                    let pane = crate::control::Pane::parse(&bytes, loc.pane, server as u32)?;
                    Ok((
                        pane.shell,
                        server as u32,
                        pane.tty.to_owned(),
                        pane.modes.map(|mode| match mode {
                            None => String::new(),
                            Some(false) => "0".into(),
                            Some(true) => "1".into(),
                        }),
                    ))
                })();
                let (shell, server, tty, mode): (_, _, _, [String; 5]) = match guard {
                    Ok(value) => value,
                    Err(e) => {
                        done(mux, io, Err(e));
                        return;
                    }
                };
                mux.job(
                    io,
                    Job::Process { pid: expected.pid },
                    Box::new(move |mux, io, result| {
                        let current = match result {
                            Ok(Output::Process(p))
                                if p.pid == expected.pid
                                    && p.start == expected.start
                                    && p.tty == expected.tty
                                    && p.executable == expected.executable
                                    && p.tty != 0 =>
                            {
                                p
                            }
                            _ => {
                                done(mux, io, Err(error("Tmux process changed")));
                                return;
                            }
                        };
                        mux.job(
                            io,
                            Job::Process { pid: shell },
                            Box::new(move |mux, io, result| {
                                let shell = match result {
                                    Ok(Output::Process(p))
                                        if p.parent == server
                                            && p.tty == current.tty
                                            && p.foreground == current.group
                                            && current.group > 1 =>
                                    {
                                        p
                                    }
                                    _ => {
                                        done(
                                            mux,
                                            io,
                                            Err(error("Tmux foreground process changed")),
                                        );
                                        return;
                                    }
                                };
                                let input = match json::write(&Data::Object(vec![(
                                    "path",
                                    Data::String(&tty),
                                )])) {
                                    Ok(v) => v,
                                    Err(e) => {
                                        done(mux, io, Err(e));
                                        return;
                                    }
                                };
                                mux.job(
                                    io,
                                    Job::Native {
                                        name: "file.lstat",
                                        input,
                                    },
                                    Box::new(move |mux, io, result| {
                                        let valid = matches!(result, Ok(Output::Bytes(ref bytes))
                                            if crate::discovery::tty(bytes, shell.tty));
                                        if !valid {
                                            done(mux, io, Err(error("Tmux pane tty changed")));
                                            return;
                                        }
                                        let input = match json::write(&Data::Object(vec![(
                                            "tty",
                                            Data::Unsigned(shell.tty),
                                        )])) {
                                            Ok(v) => v,
                                            Err(e) => {
                                                done(mux, io, Err(e));
                                                return;
                                            }
                                        };
                                        mux.job(
                                            io,
                                            Job::Native {
                                                name: "foreground",
                                                input,
                                            },
                                            Box::new(move |mux, io, result| {
                                                let valid = (|| {
                                                    let Output::Bytes(data) = result.ok()? else {
                                                        return None;
                                                    };
                                                    let members = crate::discovery::foreground(
                                                        &data, &shell,
                                                    )?;
                                                    let agents: Vec<_> = members
                                                        .iter()
                                                        .filter(|p| {
                                                            mux.harnesses
                                                                .iter()
                                                                .any(|h| h.borrow().matches(p))
                                                        })
                                                        .collect();
                                                    (agents.len() == 1
                                                        && agents[0].pid == current.pid
                                                        && agents[0].start == current.start
                                                        && agents[0].executable
                                                            == current.executable
                                                        && agents[0].tty == shell.tty
                                                        && agents[0].group == shell.foreground)
                                                        .then_some(())
                                                })(
                                                )
                                                .is_some();
                                                done(
                                                    mux,
                                                    io,
                                                    if valid && mux.location(node).is_ok() {
                                                        Ok((loc, mode, shell))
                                                    } else {
                                                        Err(error(
                                                            "Tmux foreground ownership changed",
                                                        ))
                                                    },
                                                );
                                            }),
                                        );
                                    }),
                                );
                            }),
                        );
                    }),
                );
            }),
        );
    }
}
use std::borrow::Cow;
