//! One ordered terminal-to-multiplexer handoff, without native protocol parsing.
use crate::{api::*, dispatch, wire};
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet, VecDeque},
    rc::Rc,
};

pub(crate) type SharedRoutes = Rc<RefCell<Routes>>;
pub(crate) type Delivery = (usize, Id, Control);
#[derive(Default)]
pub(crate) struct Routes {
    serial: u64,
    entries: BTreeMap<Id, Entry>,
    pub ready: VecDeque<Delivery>,
}
struct Entry {
    serial: u64,
    producer: Option<(usize, Id)>,
    events: VecDeque<Control>,
    bytes: usize,
    ended: bool,
}
fn unavailable() -> Error {
    Error {
        code: "terminal_unavailable",
        message: "The control stream is no longer available.".into(),
    }
}
impl Routes {
    pub fn begin(&mut self, terminal: Id) -> Result<u64, Error> {
        if self.entries.contains_key(&terminal) {
            return Err(Error {
                code: "busy",
                message: "The control stream is already active.".into(),
            });
        }
        self.serial += 1;
        self.entries.insert(
            terminal,
            Entry {
                serial: self.serial,
                producer: None,
                events: VecDeque::new(),
                bytes: 0,
                ended: false,
            },
        );
        Ok(self.serial)
    }
    pub fn current(&self, terminal: Id, serial: u64) -> bool {
        self.entries
            .get(&terminal)
            .is_some_and(|entry| entry.serial == serial)
    }
    pub fn push(&mut self, terminal: Id, event: Control) -> Result<Option<Delivery>, Error> {
        let entry = self.entries.get_mut(&terminal).ok_or_else(unavailable)?;
        if entry.ended {
            return Err(unavailable());
        }
        let end = matches!(event, Control::End | Control::Exit(_));
        if let Some((module, id)) = entry.producer {
            if end {
                self.entries.remove(&terminal);
            }
            return Ok(Some((module, id, event)));
        }
        let bytes = std::mem::size_of::<Control>()
            + match &event {
                Control::Data(bytes) => bytes.len(),
                _ => 0,
            };
        if bytes > (4 * wire::LIMIT as usize).saturating_sub(entry.bytes) {
            self.entries.remove(&terminal);
            return Err(Error {
                code: "limit",
                message: "The pending control stream exceeds its buffer limit.".into(),
            });
        }
        entry.bytes += bytes;
        entry.ended = end;
        entry.events.push_back(event);
        Ok(None)
    }
    pub fn accept(
        &mut self,
        terminal: Id,
        serial: u64,
        module: usize,
        id: Id,
    ) -> Result<Vec<Delivery>, Error> {
        if !self.current(terminal, serial) {
            return Err(unavailable());
        }
        let entry = self.entries.get_mut(&terminal).unwrap();
        entry.producer = Some((module, id));
        entry.bytes = 0;
        let events: Vec<_> = entry
            .events
            .drain(..)
            .map(|event| (module, id, event))
            .collect();
        if events
            .iter()
            .any(|(_, _, event)| matches!(event, Control::End | Control::Exit(_)))
        {
            self.entries.remove(&terminal);
        }
        Ok(events)
    }
    pub fn close(&mut self, terminal: Id, status: Option<i32>) {
        if let Some(entry) = self.entries.remove(&terminal)
            && let Some((module, id)) = entry.producer
        {
            self.ready.push_back((module, id, Control::Exit(status)));
        }
    }
    pub fn retain(&mut self, module: usize, nodes: &dispatch::Nodes) {
        let removed: Vec<_> = self
            .entries
            .keys()
            .copied()
            .filter(|id| (*id >> 48) as usize == module && !nodes.borrow().contains_key(id))
            .collect();
        for terminal in removed {
            self.close(terminal, None);
        }
    }
}

pub(crate) struct Claim {
    pub mux: u64,
    pub key: String,
    pub backend: Id,
}
impl crate::encode::Encode for Claim {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(
            out,
            &[
                ("mux", &self.mux),
                ("key", &self.key),
                ("backend", &self.backend),
            ],
        );
    }
}
struct Attempt {
    terminal: Id,
    serial: u64,
    source: usize,
    index: usize,
    process: Process,
    write: ControlWrite,
    parts: Vec<Shared<dyn Multiplexer>>,
    skip: BTreeSet<usize>,
    routes: SharedRoutes,
    done: Done<Option<Claim>>,
}
impl Attempt {
    fn next(mut self, io: &mut dyn Io) {
        if !self.routes.borrow().current(self.terminal, self.serial) {
            deferred(self.done)(io, Err(unavailable()));
            return;
        }
        self.index = (self.index..self.parts.len())
            .find(|index| *index != self.source && !self.skip.contains(index))
            .unwrap_or(self.parts.len());
        let Some(part) = self.parts.get(self.index).cloned() else {
            self.routes.borrow_mut().entries.remove(&self.terminal);
            deferred(self.done)(io, Ok(None));
            return;
        };
        let process = self.process.clone();
        let write = self.write.clone();
        part.borrow_mut().claim(
            io,
            &process,
            write,
            deferred(Box::new(move |io, result| match result {
                Ok(None) => {
                    self.index += 1;
                    self.next(io);
                }
                Ok(Some(target)) => {
                    let events = self.routes.borrow_mut().accept(
                        self.terminal,
                        self.serial,
                        self.index,
                        target.id,
                    );
                    match events {
                        Ok(events) => {
                            for (module, id, event) in events {
                                // A refused queued event ends the route; the claim itself stands.
                                if self.parts[module]
                                    .borrow_mut()
                                    .stream(io, id, event)
                                    .is_err()
                                {
                                    self.routes.borrow_mut().entries.remove(&self.terminal);
                                }
                            }
                            deferred(self.done)(
                                io,
                                Ok(Some(Claim {
                                    mux: self.index as u64,
                                    key: target.key,
                                    backend: dispatch::reference(self.index, target.id),
                                })),
                            );
                        }
                        Err(error) => deferred(self.done)(io, Err(error)),
                    }
                }
                Err(error) => {
                    if self.routes.borrow().current(self.terminal, self.serial) {
                        self.routes.borrow_mut().entries.remove(&self.terminal);
                    }
                    deferred(self.done)(io, Err(error));
                }
            })),
        );
    }
}

impl dispatch::Request<'_> {
    /// Protocol result: ControlTarget when claimed; null on data/end
    /// Protocol producers: Multiplexer.control, Multiplexer.claim, Multiplexer.stream
    pub(super) fn control(&mut self, p: crate::json::Value<'_>) -> Result<(), Error> {
        let terminal = dispatch::number(p, "terminal")?;
        if !self.helper.nodes.borrow().contains_key(&terminal) {
            return Err(unavailable());
        }
        let event = match p.get("event").and_then(|v| v.string()) {
            Some("start") => Control::Start,
            Some("data") => Control::Data(dispatch::bytes(p)?),
            Some("end") => Control::End,
            _ => return Err(dispatch::invalid("event")),
        };
        let routes = self.helper.controls.clone();
        if event != Control::Start {
            let delivery = routes.borrow_mut().push(terminal, event)?;
            if let Some((module, id, event)) = delivery
                && self.helper.multiplexers[module]
                    .borrow_mut()
                    .stream(self.io, id, event)
                    .is_err()
            {
                // The producer refused this event: the route ends and the app re-scans it.
                routes.borrow_mut().entries.remove(&terminal);
                return Err(unavailable());
            }
            self.done(None)(self.io, Ok(()));
            return Ok(());
        }
        let source = self
            .helper
            .nodes
            .borrow()
            .get(&terminal)
            .map(|(module, _)| *module)
            .ok_or_else(unavailable)?;
        let mux = self
            .helper
            .multiplexers
            .get(source)
            .cloned()
            .ok_or_else(unavailable)?;
        let serial = routes.borrow_mut().begin(terminal)?;
        routes.borrow_mut().push(terminal, Control::Start)?;
        let parts = self.helper.multiplexers.clone();
        let skip = self.helper.unclaimed.clone();
        let done = self.done(None);
        let writer = mux.clone();
        mux.borrow_mut().control(
            self.io,
            dispatch::local(terminal),
            deferred(Box::new(move |io, result| match result {
                Ok(process) => {
                    let current = process.clone();
                    let active = routes.clone();
                    let write: ControlWrite = Rc::new(move |io, bytes, done| {
                        if !active.borrow().current(terminal, serial) {
                            deferred(done)(io, Err(unavailable()));
                            return;
                        }
                        writer.borrow_mut().keys(
                            io,
                            dispatch::local(terminal),
                            &current,
                            &[Input::Raw(bytes.to_vec())],
                            deferred(done),
                        );
                    });
                    Attempt {
                        terminal,
                        serial,
                        source,
                        index: 0,
                        process,
                        write,
                        parts,
                        skip,
                        routes,
                        done,
                    }
                    .next(io);
                }
                Err(error) => {
                    if routes.borrow().current(terminal, serial) {
                        routes.borrow_mut().entries.remove(&terminal);
                    }
                    deferred(done)(io, Err(error));
                }
            })),
        );
        Ok(())
    }
}
