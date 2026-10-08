//! Registered client discovery uses normal backend open, with a fresh source check.
use crate::{api::*, dispatch, helper::Replies, wire};
use std::{cell::RefCell, collections::BTreeMap, rc::Rc};

pub(crate) type Observed = Rc<RefCell<BTreeMap<Id, (Process, bool)>>>;

pub(crate) struct Launch {
    pub mux: usize,
    pub process: Process,
    pub reply: u64,
    pub ready: bool,
}
impl Launch {
    pub fn current(&self, current: &Process) -> bool {
        let before = &self.process;
        before.pid == current.pid && before.start == current.start && before.tty == current.tty
            && before.group == current.group && current.group == current.foreground
            && before.executable == current.executable && before.arguments == current.arguments
    }
    pub fn accept(&self, mux: usize, current: &Process) -> Result<u64, Error> {
        if self.ready && self.mux == mux && self.current(current) {
            Ok(self.reply)
        } else {
            Err(Error { code: "destination_changed", message: "The launching terminal changed.".into() })
        }
    }
}

pub(crate) fn answer(io: &mut dyn Io, reply: u64, result: Result<bool, Error>) -> std::io::Result<()> {
    use crate::json::{self, Data};
    let value = match &result {
        Ok(enabled) => Data::Object(vec![("enabled", Data::Bool(*enabled))]),
        Err(error) => Data::Object(vec![("error", Data::String(&error.message))]),
    };
    io.reply(reply, &json::write(&value).map_err(|error| std::io::Error::other(error.message))?)
}

pub(crate) struct Attempt {
    pub terminal: Id,
    pub process: Process,
    pub index: usize,
    pub parts: Vec<Shared<dyn Multiplexer>>,
    /// Muxes that do not claim (backends.claim enabled:false); the source mux never does.
    pub skip: std::collections::BTreeSet<usize>,
    pub observed: Observed,
    pub done: Done<(usize, String, Id)>,
}
impl Attempt {
    fn current(&self) -> bool {
        self.observed
            .borrow()
            .get(&self.terminal)
            .is_some_and(|(process, _)| process == &self.process)
    }
    pub fn next(mut self, io: &mut dyn Io) {
        if !self.current() {
            return;
        }
        let source = (self.terminal >> 48) as usize;
        self.index = (self.index..)
            .find(|index| *index != source && !self.skip.contains(index))
            .unwrap();
        let Some(part) = self.parts.get(self.index).cloned() else {
            return;
        };
        let process = self.process.clone();
        part.borrow_mut().probe(
            io,
            &process,
            deferred(Box::new(move |io, result| {
                if !self.current() {
                    return;
                }
                match result {
                    Ok(None) => {
                        self.index += 1;
                        self.next(io);
                    }
                    Err(error) => (self.done)(io, Err(error)),
                    Ok(Some(key)) => {
                        let source = self.parts[(self.terminal >> 48) as usize].clone();
                        source.borrow_mut().control(
                            io,
                            dispatch::local(self.terminal),
                            deferred(Box::new(move |io, checked| {
                                if !self.current() {
                                    return;
                                }
                                match checked {
                                    Ok(current)
                                        if current.pid == self.process.pid
                                            && current.start == self.process.start
                                            && current.tty == self.process.tty =>
                                    {
                                        let target = self.parts[self.index].clone();
                                        target.borrow_mut().open(
                                            io,
                                            &key.clone(),
                                            deferred(Box::new(move |io, result| {
                                                if self.current() {
                                                    (self.done)(
                                                        io,
                                                        result.map(|id| {
                                                            (
                                                                self.index,
                                                                key,
                                                                dispatch::reference(self.index, id),
                                                            )
                                                        }),
                                                    );
                                                }
                                            })),
                                        );
                                    }
                                    Err(error) => (self.done)(io, Err(error)),
                                    _ => (self.done)(
                                        io,
                                        Err(Error {
                                            code: "destination_changed",
                                            message: String::new(),
                                        }),
                                    ),
                                }
                            })),
                        );
                    }
                }
            })),
        );
    }
}

pub(crate) fn completion(
    terminal: Id,
    recipients: Vec<(i32, u64)>,
    replies: Replies,
    mux: Option<usize>,
) -> Done<(usize, String, Id)> {
    Box::new(move |_, result| {
        let body = match result {
            Ok((mux, key, backend)) => crate::encode::notify(
                "terminal.backend",
                &[
                    ("terminal", &terminal),
                    ("mux", &(mux as u64)),
                    ("key", &key),
                    ("backend", &backend),
                ],
            ),
            Err(error) => {
                let mux = mux.map(|value| value as u64);
                let mut fields: Vec<(&str, &dyn crate::encode::Encode)> = vec![("terminal", &terminal)];
                if let Some(mux) = &mux { fields.push(("mux", mux)); }
                fields.push(("error", &error));
                crate::encode::notify("terminal.backend", &fields)
            }
        };
        for (fd, id) in recipients {
            replies
                .borrow_mut()
                .push_back((fd, wire::Kind::Notify, id, body.clone()));
        }
    })
}
