//! Authenticated one-request Pi channels; all effects go through core IO.
use crate::records::{LIMIT, text};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json, Value},
    rpc,
};
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet},
    io,
    os::fd::RawFd,
    path::PathBuf,
    rc::Rc,
    time::{Duration, Instant},
};

pub type Shared = Rc<RefCell<Runtime>>;
pub struct Runtime {
    pub home: PathBuf,
    pub menus: BTreeMap<String, crate::screen::Command>,
    pub jobs: rpc::Pending<Done<Output>>,
    channels: BTreeMap<RawFd, Channel>,
    serial: u64,
    pub registrations: BTreeMap<u32, Registration>,
    pub states: BTreeMap<String, Rc<Json>>,
    pub sides: BTreeMap<u32, crate::side::Side>,
    pub updates: Vec<(Binding, Json)>,
    pub live: BTreeMap<String, Vec<Record>>,
    pub subscribing: BTreeSet<String>,
    pub pages: Vec<Update>,
    pub persisted: BTreeSet<(u32, [u64; 2], String)>,
    pub legacy: BTreeMap<String, crate::legacy::Poll>,
    watches: BTreeMap<u64, Binding>,
    pub transcripts: BTreeMap<u64, Binding>,
    pub refreshing: BTreeMap<String, bool>,
}
pub struct Channel {
    process: Process,
    session: String,
    id: String,
    input: Vec<u8>,
    offset: usize,
    lines: rpc::Lines,
    deadline: Instant,
    verified: bool,
    done: Option<Done<Json>>,
    binding: Binding,
    subscribe: bool,
    pending: Vec<Json>,
}
#[derive(Clone)]
pub struct Registration {
    pub session: String,
    pub path: Option<PathBuf>,
    pub leaf: Option<String>,
    pub socket: PathBuf,
    pub token: String,
    pub version: String,
    pub uid: u64,
    pub home: PathBuf,
    pub cli: Option<String>,
    pub start: [u64; 2],
}
impl Default for Runtime {
    fn default() -> Self {
        Self {
            home: PathBuf::new(),
            menus: BTreeMap::new(),
            jobs: rpc::Pending::new(usize::MAX, 0),
            channels: BTreeMap::new(),
            serial: 0,
            registrations: BTreeMap::new(),
            states: BTreeMap::new(),
            sides: BTreeMap::new(),
            updates: Vec::new(),
            live: BTreeMap::new(),
            subscribing: BTreeSet::new(),
            pages: Vec::new(),
            persisted: BTreeSet::new(),
            legacy: BTreeMap::new(),
            watches: BTreeMap::new(),
            transcripts: BTreeMap::new(),
            refreshing: BTreeMap::new(),
        }
    }
}
pub fn fail(code: &'static str, message: impl Into<String>) -> Error {
    Error {
        code,
        message: message.into(),
    }
}
pub fn home(runtime: &Shared, value: Value<'_>) -> Result<String, Error> {
    let home = match value.get("HOME").and_then(Value::string) {
        Some(home) => home.to_owned(),
        None => runtime
            .borrow()
            .home
            .to_str()
            .ok_or_else(|| fail("not_sent", "Pi account home is unavailable"))?
            .to_owned(),
    };
    let configured = text(value, "PI_CODING_AGENT_DIR");
    let directory = if configured.is_empty() {
        format!("{home}/.pi/agent")
    } else if configured == "~" {
        home
    } else if let Some(rest) = configured.strip_prefix("~/") {
        format!("{home}/{rest}")
    } else {
        configured
    };
    if !directory.starts_with('/') || directory.len() >= 4096 || directory.contains('\0') {
        return Err(fail(
            "not_sent",
            "Pi configuration directory is unavailable",
        ));
    }
    Ok(directory)
}
pub fn job(runtime: &Shared, io: &mut dyn Io, value: Job, done: Done<Output>) {
    match io.submit(value) {
        Ok(id) => {
            runtime
                .borrow_mut()
                .jobs
                .insert(rpc::Id::Integer(id as i64), done)
                .expect("core issues unique work ids");
        }
        Err(error) => deferred(done)(io, Err(fail("io", error.to_string()))),
    }
}
pub fn native(
    runtime: &Shared,
    io: &mut dyn Io,
    name: &'static str,
    value: Data<'_>,
    done: Done<Json>,
) {
    match json::write(&value) {
        Err(error) => deferred(done)(io, Err(error)),
        Ok(input) => job(
            runtime,
            io,
            Job::Native { name, input },
            Box::new(move |io, result| {
                done(
                    io,
                    result.and_then(|out| match out {
                        Output::Bytes(bytes) => Json::parse(&bytes),
                        _ => Err(fail("io", "Unexpected native result")),
                    }),
                );
            }),
        ),
    }
}
pub fn current(value: Value<'_>, process: &Process) -> bool {
    value.get("pid").and_then(Value::unsigned) == Some(process.pid.into())
        && value
            .get("start")
            .and_then(Value::array)
            .map(|a| a.filter_map(Value::unsigned).collect::<Vec<_>>())
            == Some(process.start.to_vec())
        && value.get("executable").and_then(Value::string) == process.executable.to_str()
}
pub fn response(value: Value<'_>, id: &str, session: &str) -> Result<(), Error> {
    let invalid = || fail("may_have_sent", "Pi returned an invalid Chat response.");
    if text(value, "id") != id {
        return Err(invalid());
    }
    if value.get("ok").and_then(Value::boolean) == Some(false) {
        return Err(fail("may_have_sent", text(value, "error")));
    }
    if value.get("ok").and_then(Value::boolean) != Some(true) || text(value, "sessionId") != session
    {
        return Err(invalid());
    }
    if let Some(models) = value.get("models") {
        let mut identities = std::collections::BTreeSet::new();
        for model in models.array().ok_or_else(invalid)? {
            let provider = model
                .get("provider")
                .and_then(Value::string)
                .ok_or_else(invalid)?;
            let id = model
                .get("id")
                .and_then(Value::string)
                .ok_or_else(invalid)?;
            if !identities.insert((provider, id)) {
                return Err(invalid());
            }
        }
    }
    if let Some(state) = value.get("state") {
        if text(state, "sessionId") != session {
            return Err(invalid());
        }
        crate::harness::state(state).map_err(|_| invalid())?;
    }
    Ok(())
}
pub fn closed(written: usize) -> Error {
    fail(
        if written == 0 {
            "not_sent"
        } else {
            "may_have_sent"
        },
        "Pi’s Chat connection closed before confirming the request. Review Terminal before trying again.",
    )
}
pub use crate::registration::registration;

pub fn call(
    runtime: &Shared,
    io: &mut dyn Io,
    binding: &Binding,
    method: &str,
    fields: Vec<(&str, Data<'_>)>,
    done: Done<Json>,
) {
    let encoded = match json::write(&Data::Object(fields)) {
        Ok(v) => v,
        Err(e) => {
            deferred(done)(io, Err(e));
            return;
        }
    };
    let method = method.to_owned();
    let binding = binding.clone();
    let saved = runtime.clone();
    registration(
        runtime,
        io,
        &binding.process.clone(),
        Box::new(move |io, result| {
            let record = match result {
                Ok(record) if record.session == binding.session => record,
                Ok(_) => {
                    done(
                        io,
                        Err(fail(
                            "not_sent",
                            "The Pi conversation changed or its Chat extension is unavailable. Review Terminal before trying again.",
                        )),
                    );
                    return;
                }
                Err(error) => {
                    done(io, Err(error));
                    return;
                }
            };
            let next = saved.clone();
            let path = record.socket.to_string_lossy().into_owned();
            native(
                &saved,
                io,
                "file.lstat",
                Data::Object(vec![("path", Data::String(&path))]),
                Box::new(move |io, result| {
                    let valid = result.as_ref().is_ok_and(|v| {
                        text(v.root(), "kind") == "socket"
                            && v.root().get("uid").and_then(Value::unsigned) == Some(record.uid)
                            && v.root()
                                .get("mode")
                                .and_then(Value::unsigned)
                                .is_some_and(|mode| mode & 0o077 == 0)
                    });
                    if !valid {
                        done(
                            io,
                            Err(fail(
                                "not_sent",
                                "Pi’s Chat connection is unavailable. Run /reload in Terminal.",
                            )),
                        );
                        return;
                    }
                    let id = {
                        let mut runtime = next.borrow_mut();
                        runtime.serial += 1;
                        runtime.serial.to_string()
                    };
                    let document = Json::parse(&encoded).expect("core wrote native fields");
                    let mut fields = document
                        .root()
                        .object()
                        .unwrap()
                        .map(|(key, value)| (key, Data::Value(value)))
                        .collect::<Vec<_>>();
                    fields.extend([
                        ("id", Data::String(&id)),
                        ("sessionId", Data::String(&record.session)),
                        ("token", Data::String(&record.token)),
                        ("method", Data::String(&method)),
                    ]);
                    let mut input = match json::write(&Data::Object(fields)) {
                        Ok(v) => v,
                        Err(e) => {
                            done(io, Err(e));
                            return;
                        }
                    };
                    if input.len() > LIMIT {
                        done(
                            io,
                            Err(fail("not_sent", "This message is too large for Pi Chat.")),
                        );
                        return;
                    }
                    input.push(b'\n');
                    if method == "probe" {
                        input.clear();
                    }
                    let fd = match io.connect(&Address::Unix(record.socket.clone())) {
                        Ok(fd) => fd,
                        Err(error) => {
                            done(io, Err(fail("not_sent", error.to_string())));
                            return;
                        }
                    };
                    let deadline =
                        io.now() + Duration::from_secs(if method == "probe" { 1 } else { 4 });
                    next.borrow_mut()
                        .registrations
                        .insert(binding.process.pid, record);
                    next.borrow_mut().channels.insert(
                        fd,
                        Channel {
                            process: binding.process.clone(),
                            session: binding.session.clone(),
                            id,
                            input,
                            offset: 0,
                            lines: rpc::Lines::new(LIMIT),
                            deadline,
                            verified: false,
                            done: Some(done),
                            binding,
                            subscribe: method == "subscribe",
                            pending: Vec::new(),
                        },
                    );
                    io.timer(deadline);
                    if let Err(error) = io.interest(fd, false, true) {
                        finish(&next, io, fd, Err(fail("not_sent", error.to_string())));
                    }
                }),
            );
        }),
    );
}
fn finish(runtime: &Shared, io: &mut dyn Io, fd: RawFd, result: Result<Json, Error>) {
    let subscribe = runtime
        .borrow()
        .channels
        .get(&fd)
        .is_some_and(|c| c.subscribe && c.done.is_some());
    let result = match (result, subscribe) {
        (Ok(document), true) => {
            let (binding, done, pending) = {
                let mut runtime = runtime.borrow_mut();
                let channel = runtime.channels.get_mut(&fd).unwrap();
                (
                    channel.binding.clone(),
                    channel.done.take().unwrap(),
                    std::mem::take(&mut channel.pending),
                )
            };
            if let Some(state) = document.root().get("state")
                && let Ok(bytes) = json::write(&Data::Object(vec![
                    ("event", Data::String("state")),
                    ("sessionId", Data::String(&binding.session)),
                    ("value", Data::Value(state)),
                ]))
                && let Ok(event) = Json::parse(&bytes)
            {
                runtime.borrow_mut().updates.push((binding.clone(), event));
            }
            runtime.borrow_mut().updates.extend(
                pending
                    .into_iter()
                    .map(|document| (binding.clone(), document)),
            );
            let _ = io.interest(fd, true, false);
            done(io, Ok(document));
            return;
        }
        (result, _) => result,
    };
    let channel = runtime.borrow_mut().channels.remove(&fd);
    if let Some(channel) = channel {
        io.close(fd);
        let recover = channel.subscribe && channel.done.is_none();
        if let Some(done) = channel.done {
            done(io, result);
        }
        if recover {
            reconnect(runtime, io, &channel.binding);
        }
    }
}
pub fn subscribe(
    runtime: &Shared,
    io: &mut dyn Io,
    binding: &Binding,
    reset: bool,
) -> Result<(), Error> {
    let previous = runtime
        .borrow()
        .watches
        .iter()
        .filter(|(_, observed)| observed.process.pid == binding.process.pid && *observed != binding)
        .map(|(&id, observed)| (id, observed.session.clone()))
        .collect::<Vec<_>>();
    for (id, session) in previous {
        io.unwatch(id);
        let mut state = runtime.borrow_mut();
        state.watches.remove(&id);
        state.states.remove(&session);
        state.live.remove(&session);
    }
    if !runtime
        .borrow()
        .watches
        .values()
        .any(|observed| observed == binding)
    {
        let home = runtime
            .borrow()
            .registrations
            .get(&binding.process.pid)
            .ok_or_else(|| fail("changed", "The Pi conversation changed."))?
            .home
            .clone();
        let path = home.join(format!("dispatch/sessions/{}.json", binding.process.pid));
        let watch = io
            .watch(&path, false)
            .map_err(|error| fail("io", error.to_string()))?;
        runtime.borrow_mut().watches.insert(watch, binding.clone());
    }
    crate::transcript::start(runtime, io, binding)?;
    let subscribed = runtime
        .borrow()
        .channels
        .values()
        .any(|channel| channel.subscribe && channel.binding == *binding);
    if (!reset && subscribed)
        || !runtime
            .borrow_mut()
            .subscribing
            .insert(binding.session.clone())
    {
        return Ok(());
    }
    if reset {
        let fds = runtime
            .borrow()
            .channels
            .iter()
            .filter_map(|(&fd, channel)| {
                (channel.subscribe && channel.binding == *binding).then_some(fd)
            })
            .collect::<Vec<_>>();
        for fd in fds {
            finish(runtime, io, fd, Err(fail("changed", "Refreshing Pi Chat.")));
        }
    }
    let saved = runtime.clone();
    let binding = binding.clone();
    call(
        runtime,
        io,
        &binding.clone(),
        "subscribe",
        Vec::new(),
        Box::new(move |io, result| {
            saved.borrow_mut().subscribing.remove(&binding.session);
            if reset && result.is_ok() {
                let next = saved.clone();
                crate::history::read(
                    &saved,
                    io,
                    &binding.clone(),
                    None,
                    Box::new(move |_, result| {
                        if let Ok(page) = result {
                            next.borrow_mut().pages.push(Update::Records {
                                binding,
                                records: page.records,
                            });
                        }
                    }),
                );
            }
        }),
    );
    Ok(())
}
fn reconnect(runtime: &Shared, io: &mut dyn Io, binding: &Binding) {
    let subscribed = runtime
        .borrow()
        .channels
        .values()
        .any(|channel| channel.subscribe && channel.binding == *binding);
    let watched = runtime
        .borrow()
        .watches
        .values()
        .any(|observed| observed == binding);
    if watched && !subscribed {
        let _ = subscribe(runtime, io, binding, true);
    }
}
pub fn event(runtime: &Shared, io: &mut dyn Io, event: Event) {
    match event {
        Event::Changed { watch, .. } => {
            let binding = runtime.borrow().watches.get(&watch).cloned();
            if let Some(binding) = binding {
                reconnect(runtime, io, &binding);
            }
        }
        Event::Done { work, result } => {
            let done = runtime
                .borrow_mut()
                .jobs
                .take(&rpc::Id::Integer(work as i64))
                .ok();
            if let Some(done) = done {
                done(
                    io,
                    result.map_err(|error| {
                        fail(
                            if error.kind() == io::ErrorKind::NotFound {
                                "not_found"
                            } else {
                                "io"
                            },
                            error.to_string(),
                        )
                    }),
                );
            }
        }
        Event::Timer { .. } => {
            let expired = runtime
                .borrow()
                .channels
                .iter()
                .filter_map(|(&fd, c)| {
                    (c.done.is_some() && c.deadline <= io.now()).then_some((fd, c.offset))
                })
                .collect::<Vec<_>>();
            for (fd, sent) in expired {
                finish(
                    runtime,
                    io,
                    fd,
                    Err(fail(
                        if sent == 0 {
                            "not_sent"
                        } else {
                            "may_have_sent"
                        },
                        "Pi did not confirm the request in time. Review Terminal before trying again.",
                    )),
                );
            }
        }
        Event::Ready { fd, read, write } => {
            let connecting = runtime
                .borrow()
                .channels
                .get(&fd)
                .is_some_and(|c| !c.verified);
            if connecting && write {
                let saved = runtime.clone();
                native(
                    runtime,
                    io,
                    "peer",
                    Data::Object(vec![("fd", Data::Signed(fd.into()))]),
                    Box::new(move |io, result| {
                        let valid = saved.borrow().channels.get(&fd).is_some_and(|channel| {
                            result.as_ref().is_ok_and(|peer| {
                                peer.root().get("pid").and_then(Value::unsigned)
                                    == Some(channel.process.pid.into())
                                    && peer.root().get("uid").and_then(Value::unsigned)
                                        == saved
                                            .borrow()
                                            .registrations
                                            .get(&channel.process.pid)
                                            .map(|r| r.uid)
                            })
                        });
                        if !valid {
                            finish(
                                &saved,
                                io,
                                fd,
                                Err(fail(
                                    "not_sent",
                                    "The Pi Chat socket belongs to a different process. Run /reload in Terminal.",
                                )),
                            );
                            return;
                        }
                        let process = saved
                            .borrow()
                            .channels
                            .get(&fd)
                            .map(|channel| channel.process.clone());
                        let Some(process) = process else {
                            return;
                        };
                        let next = saved.clone();
                        let peer = result.expect("verified peer result");
                        registration(
                            &saved,
                            io,
                            &process.clone(),
                            Box::new(move |io, result| {
                                if !result.as_ref().is_ok_and(|record| {
                                    crate::registration::same(&next, &process, record)
                                }) {
                                    finish(
                                        &next,
                                        io,
                                        fd,
                                        Err(fail(
                                            "not_sent",
                                            "The Pi process exited before the request completed.",
                                        )),
                                    );
                                    return;
                                }
                                if let Some(channel) = next.borrow_mut().channels.get_mut(&fd) {
                                    channel.verified = true;
                                    let _ = io.interest(fd, true, true);
                                }
                                let probe = next
                                    .borrow()
                                    .channels
                                    .get(&fd)
                                    .is_some_and(|channel| channel.input.is_empty());
                                if probe {
                                    finish(&next, io, fd, Ok(peer));
                                }
                            }),
                        );
                    }),
                );
                let _ = io.interest(fd, false, false);
                return;
            }
            let mut result = None;
            let mut updates = Vec::new();
            {
                let mut shared = runtime.borrow_mut();
                let Some(channel) = shared.channels.get_mut(&fd) else {
                    return;
                };
                if !channel.verified {
                    return;
                }
                if write && channel.offset < channel.input.len() {
                    match io.write(fd, &channel.input[channel.offset..]) {
                        Ok(0) => {
                            result = Some(Err(fail(
                                "may_have_sent",
                                "Pi’s Chat connection closed. Review Terminal before trying again.",
                            )))
                        }
                        Ok(count) => channel.offset += count,
                        Err(error)
                            if matches!(
                                error.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                            ) => {}
                        Err(error) => {
                            result = Some(Err(fail(
                                if channel.offset == 0 {
                                    "not_sent"
                                } else {
                                    "may_have_sent"
                                },
                                error.to_string(),
                            )))
                        }
                    }
                }
                if read && result.is_none() {
                    let mut bytes = [0; 65536];
                    match io.read(fd, &mut bytes) {
                        Ok(0) => result = Some(Err(closed(channel.offset))),
                        Ok(count) => {
                            let decoded = channel.lines.feed(&bytes[..count], |line| {
                                let document = Json::parse(line).map_err(|_| rpc::Error::Shape)?;
                                let root = document.root();
                                if channel.subscribe
                                    && root.get("event").and_then(Value::string).is_some()
                                    && text(root, "sessionId") == channel.session
                                {
                                    if channel.done.is_some() {
                                        channel.pending.push(document);
                                    } else {
                                        updates.push((channel.binding.clone(), document));
                                    }
                                    return Ok(());
                                }
                                result = Some(
                                    response(root, &channel.id, &channel.session).map(|_| document),
                                );
                                Ok(())
                            });
                            if decoded.is_err() {
                                result = Some(Err(fail(
                                    "may_have_sent",
                                    "Pi returned an invalid Chat response.",
                                )));
                            }
                        }
                        Err(error)
                            if matches!(
                                error.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                            ) => {}
                        Err(error) => result = Some(Err(fail("may_have_sent", error.to_string()))),
                    }
                }
                if result.is_none() {
                    let _ = io.interest(fd, true, channel.offset < channel.input.len());
                }
            }
            runtime.borrow_mut().updates.extend(updates);
            if let Some(result) = result {
                if result.is_ok() {
                    let process = runtime
                        .borrow()
                        .channels
                        .get(&fd)
                        .map(|channel| channel.process.clone());
                    let Some(process) = process else {
                        return;
                    };
                    let saved = runtime.clone();
                    let _ = io.interest(fd, false, false);
                    registration(
                        runtime,
                        io,
                        &process.clone(),
                        Box::new(move |io, facts| {
                            if facts.as_ref().is_ok_and(|record| {
                                crate::registration::same(&saved, &process, record)
                            }) {
                                finish(&saved, io, fd, result);
                            } else {
                                finish(
                                    &saved,
                                    io,
                                    fd,
                                    Err(fail(
                                        "may_have_sent",
                                        "The Pi process exited before confirming the request.",
                                    )),
                                );
                            }
                        }),
                    );
                } else {
                    finish(runtime, io, fd, result);
                }
            }
        }
        Event::Exit { pid, .. } => {
            let watches = runtime
                .borrow()
                .watches
                .iter()
                .filter_map(|(&watch, binding)| (binding.process.pid == pid).then_some(watch))
                .collect::<Vec<_>>();
            for watch in watches {
                runtime.borrow_mut().watches.remove(&watch);
                io.unwatch(watch);
            }
            let fds = runtime
                .borrow()
                .channels
                .iter()
                .filter_map(|(&fd, c)| (c.process.pid == pid).then_some(fd))
                .collect::<Vec<_>>();
            for fd in fds {
                finish(
                    runtime,
                    io,
                    fd,
                    Err(fail(
                        "may_have_sent",
                        "The Pi process exited before confirming the request.",
                    )),
                );
            }
            runtime
                .borrow_mut()
                .persisted
                .retain(|(process, _, _)| *process != pid);
            let record = runtime.borrow_mut().registrations.remove(&pid);
            runtime
                .borrow_mut()
                .legacy
                .retain(|_, poll| poll.binding.process.pid != pid);
            if let Some(record) = record {
                let mut runtime = runtime.borrow_mut();
                runtime.live.remove(&record.session);
                runtime.states.remove(&record.session);
                runtime.subscribing.remove(&record.session);
            }
        }
        _ => {}
    }
}
