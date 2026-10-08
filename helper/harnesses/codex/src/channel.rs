//! Owned app-server stdio; shared Stream handles all readiness and partial writes.
use dispatch_helper_core::{
    api::{Address, Binding, Done, Error, Event, Io, Sent, deferred},
    json::{self, Data, Json},
    rpc::{
        Client as Rpc, Id, Lines, Message, Request,
        transport::{Codec, Raw, Stream},
        websocket::{self, Client, Notice},
    },
};
use std::{
    cell::RefCell,
    collections::BTreeMap,
    io,
    process::{Command, Stdio},
    rc::Rc,
    time::{Duration, Instant},
};

pub type Channels = Rc<RefCell<BTreeMap<String, Rc<RefCell<Channel>>>>>;

enum Wire {
    Lines(Lines),
    Socket(Client),
}
impl Codec for Wire {
    fn feed(
        &mut self,
        bytes: &[u8],
        emit: &mut dyn FnMut(&[u8]) -> Result<(), dispatch_helper_core::rpc::Error>,
    ) -> Result<(), dispatch_helper_core::rpc::Error> {
        match self {
            Self::Lines(lines) => lines.feed(bytes, emit),
            Self::Socket(socket) => socket.feed(bytes, emit),
        }
    }
    fn finish(&self) -> Result<(), dispatch_helper_core::rpc::Error> {
        match self {
            Self::Lines(lines) => lines.finish(),
            Self::Socket(socket) => socket.finish(),
        }
    }
}

pub struct Channel {
    pub binding: Binding,
    pub ready: bool,
    pub pid: u32,
    pub read_only: bool,
    pub track_main: bool,
    pub identified: bool,
    rpc: Rpc<Wire, Done<Json>>,
    socket: Option<Client>,
    upgrade: Option<(Instant, Done<()>)>,
    /// One deadline bounds a connected channel's whole attach until it is ready;
    /// c1654cc CodexPatchConnection.swift:222-223,458.
    pub(crate) attach: Option<Instant>,
    owned: bool,
    stderr: Option<Stream<Raw>>,
    sequence: i64,
    pub(super) closed: bool,
}

pub fn failure(code: &'static str, message: impl Into<String>) -> Error {
    Error {
        code,
        message: message.into(),
    }
}

/// An OS failure; a missing file stays distinguishable (`not_found`, as Pi reports it).
pub fn os(error: std::io::Error) -> Error {
    match error.kind() {
        std::io::ErrorKind::NotFound => failure("not_found", error.to_string()),
        // A checked write or removal found the file changed (core B1: ESTALE/EEXIST).
        std::io::ErrorKind::AlreadyExists | std::io::ErrorKind::StaleNetworkFileHandle => {
            failure("changed", error.to_string())
        }
        _ => failure("io", error.to_string()),
    }
}

impl Channel {
    pub fn spawn(io: &mut dyn Io, binding: Binding, mut command: Command) -> Result<Self, Error> {
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let spawned = io.spawn(command, None).map_err(os)?;
        let (Some(input), Some(output)) = (spawned.input, spawned.output) else {
            for fd in [spawned.input, spawned.output, spawned.stderr]
                .into_iter()
                .flatten()
            {
                io.close(fd);
            }
            let _ = io.terminate(spawned.pid);
            return Err(failure("channel", "Codex pipes unavailable"));
        };
        let mut stream = Stream::new(input, output, Wire::Lines(Lines::new(4_194_304)), 8_388_608);
        let mut stderr = spawned.stderr.map(|fd| Stream::new(fd, fd, Raw, 0));
        let result = io
            .child(spawned.pid)
            .and_then(|_| stream.attach(io))
            .and_then(|_| stderr.as_mut().map_or(Ok(()), |stream| stream.attach(io)));
        if let Err(error) = result {
            stream.close(io);
            if let Some(stderr) = &mut stderr {
                stderr.close(io);
            }
            let _ = io.terminate(spawned.pid);
            return Err(os(error));
        }
        Ok(Self {
            binding,
            ready: false,
            pid: spawned.pid,
            read_only: false,
            track_main: false,
            identified: false,
            rpc: Rpc::new(stream, 256, 1_048_576),
            socket: None,
            upgrade: None,
            attach: None,
            owned: true,
            stderr,
            sequence: 0,
            closed: false,
        })
    }

    pub fn connect(
        io: &mut dyn Io,
        binding: Binding,
        address: &Address,
        host: &str,
        target: &str,
        done: Done<()>,
    ) -> Result<Self, Error> {
        let mut nonce = [0; 16];
        io.random(&mut nonce).map_err(os)?;
        let socket = Client::new(nonce, 4_194_304);
        let handshake = socket
            .handshake(host, target)
            .map_err(|_| failure("socket", "Invalid Codex endpoint"))?;
        let deadline = io.now() + Duration::from_secs(8);
        let mut stream = Stream::connect(
            io,
            address,
            Wire::Socket(socket.clone()),
            8_388_608,
            deadline,
        )
        .map_err(os)?;
        stream
            .send(io, handshake, Some(deadline), None)
            .map_err(os)?;
        Ok(Self {
            pid: binding.process.pid,
            binding,
            ready: false,
            read_only: false,
            track_main: false,
            identified: false,
            rpc: Rpc::new(stream, 256, 1_048_576),
            socket: Some(socket),
            upgrade: Some((deadline, deferred(done))),
            attach: Some(deadline),
            owned: false,
            stderr: None,
            sequence: 0,
            closed: false,
        })
    }

    pub fn fd(&self) -> i32 {
        self.rpc.stream.output
    }

    fn frame(&mut self, io: &mut dyn Io, opcode: u8, bytes: &[u8]) -> Result<(), Error> {
        let mut mask = [0; 4];
        io.random(&mut mask).map_err(os)?;
        let bytes = websocket::frame(opcode, bytes, mask, 4_194_304)
            .map_err(|_| failure("capacity", "The native request is too large."))?;
        self.rpc.stream.send(io, bytes, None, None).map_err(os)
    }

    pub fn write(&mut self, io: &mut dyn Io, bytes: Vec<u8>) -> Result<(), Error> {
        if self.closed {
            return Err(failure("channel", "The side agent is unavailable."));
        }
        let bytes = Self::encode(io, bytes, self.socket.is_some()).map_err(os)?;
        self.rpc.stream.send(io, bytes, None, None).map_err(os)
    }

    pub fn deliver(&mut self, io: &mut dyn Io, bytes: Vec<u8>, done: Done<Sent>) {
        let result = (|| {
            if self.closed {
                return Err(failure("channel", "The side agent is unavailable."));
            }
            Self::encode(io, bytes, self.socket.is_some()).map_err(os)
        })();
        let bytes = match result {
            Ok(bytes) => bytes,
            Err(error) => {
                deferred(done)(io, Err(error));
                return;
            }
        };
        let _ = self.rpc.stream.send(
            io,
            bytes,
            None,
            Some(Box::new(move |io, written| {
                let complete = written.count == written.length && written.error.is_none();
                let result = Sent::Native {
                    written: complete,
                    may_have_sent: written.count > 0 && !complete,
                    reason: written.error.map(|error| error.to_string()),
                };
                deferred(done)(io, Ok(result));
            })),
        );
    }

    pub fn request(&mut self, io: &mut dyn Io, method: &str, params: Data<'_>, done: Done<Json>) {
        let done = deferred(done);
        if self.closed {
            done(
                io,
                Err(failure("channel", "The side agent is unavailable.")),
            );
            return;
        }
        if self.sequence == i64::MAX {
            done(
                io,
                Err(failure("capacity", "Too many pending side requests.")),
            );
            return;
        }
        self.sequence += 1;
        let deadline = (self.attach.filter(|_| !self.ready))
            .unwrap_or_else(|| io.now() + Duration::from_secs(20));
        let socket = self.socket.is_some();
        let request = Request {
            id: Id::Integer(self.sequence),
            method,
            params,
            deadline,
            value: done,
        };
        if let Err((done, error)) = self.rpc.request(io, request, move |io, bytes| {
            Self::encode(io, bytes, socket)
        }) {
            let error = if error.kind() == io::ErrorKind::InvalidInput {
                failure("capacity", "Too many pending side requests.")
            } else {
                os(error)
            };
            done(io, Err(error));
        }
    }

    fn encode(io: &mut dyn Io, bytes: Vec<u8>, socket: bool) -> io::Result<Vec<u8>> {
        if socket {
            let mut mask = [0; 4];
            io.random(&mut mask)?;
            websocket::frame(1, &bytes, mask, 4_194_304)
        } else {
            Lines::encode(bytes, 4_194_304)
        }
        .map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "The native request is too large.",
            )
        })
    }

    pub fn close(&mut self, io: &mut dyn Io, error: Error) -> Result<(), Error> {
        if self.closed {
            return Ok(());
        }
        self.closed = true;
        self.ready = false;
        if let Some(mut stderr) = self.stderr.take() {
            stderr.close(io);
        }
        for (_, call) in self.rpc.close(io) {
            (call.value)(io, Err(error.clone()));
        }
        if let Some((_, done)) = self.upgrade.take() {
            done(io, Err(error));
        }
        if self.owned {
            io.terminate(self.pid).map_err(os)
        } else {
            Ok(())
        }
    }

    pub fn event(&mut self, io: &mut dyn Io, event: &Event) -> Vec<Json> {
        if self.closed {
            return Vec::new();
        }
        if matches!(*event, Event::Exit { pid, .. } if pid == self.pid) {
            let _ = self.close(io, failure("channel", "The side agent disconnected."));
            return Vec::new();
        }
        let received = match self.rpc.event(io, event) {
            Ok(received) => received,
            Err(error) => {
                let _ = self.close(io, os(error));
                return Vec::new();
            }
        };
        if let Some(socket) = &self.socket {
            for notice in socket.take() {
                match notice {
                    Notice::Ready => {
                        if let Some((_, done)) = self.upgrade.take() {
                            done(io, Ok(()));
                        }
                    }
                    Notice::Ping(bytes) => {
                        if let Err(error) = self.frame(io, 10, &bytes) {
                            let _ = self.close(io, error);
                            return Vec::new();
                        }
                    }
                    Notice::Close(_) => {
                        let _ = self.close(io, failure("channel", "Codex disconnected"));
                        return Vec::new();
                    }
                    Notice::Pong(_) => {}
                }
            }
        }
        if let Some(stderr) = &mut self.stderr {
            match stderr.event(io, event) {
                Ok(received) if received.eof => self.stderr = None,
                Ok(_) => {}
                Err(error) => {
                    let _ = self.close(io, os(error));
                    return Vec::new();
                }
            }
        }
        if received.eof {
            let _ = self.close(io, failure("channel", "The side agent disconnected."));
        }
        if matches!(*event, Event::Timer { .. }) {
            if self.upgrade.as_ref().is_some_and(|(at, _)| *at <= io.now()) {
                let _ = self.close(io, failure("timeout", "Codex did not connect in time"));
                return Vec::new();
            }
            for (_, call) in self.rpc.expired(io.now()) {
                (call.value)(
                    io,
                    Err(failure(
                        "timeout",
                        "The side agent did not respond in time.",
                    )),
                );
            }
        }
        let mut notifications = Vec::new();
        for incoming in received.data {
            let value = incoming.document;
            match Message::read(value.root()) {
                Ok(Message::Response { result, .. }) => {
                    if let Some((_, call)) = incoming.call {
                        let result = match result {
                            Ok(value) => value.write().and_then(|bytes| Json::parse(&bytes)),
                            // JSON-RPC -32601: the method does not exist in this Codex.
                            Err(value) => Err(failure(
                                match value.get("code").and_then(|code| code.signed()) {
                                    Some(-32601) => "unsupported",
                                    _ => "native",
                                },
                                value
                                    .get("message")
                                    .and_then(|value| value.string())
                                    .unwrap_or("The side request failed."),
                            )),
                        };
                        (call.value)(io, result);
                    }
                }
                Ok(Message::Request { method, params, .. })
                    if self.read_only
                        && matches!(
                            method,
                            "item/commandExecution/requestApproval"
                                | "item/fileChange/requestApproval"
                        )
                        && params
                            .and_then(|params| params.get("threadId"))
                            .and_then(|thread| thread.string())
                            == Some(&self.binding.session) =>
                {
                    let response = Data::Object(vec![
                        ("id", Data::Value(value.root().get("id").unwrap())),
                        (
                            "result",
                            Data::Object(vec![("decision", Data::String("decline"))]),
                        ),
                    ]);
                    let _ = json::write(&response).and_then(|bytes| self.write(io, bytes));
                }
                Ok(_) => notifications.push(value),
                Err(_) => {}
            }
        }
        notifications
    }
}

pub fn initialize(
    channel: Rc<RefCell<Channel>>,
    io: &mut dyn Io,
    name: &'static str,
    done: Done<()>,
) {
    let next = channel.clone();
    channel.borrow_mut().request(
        io,
        "initialize",
        Data::Object(vec![
            (
                "clientInfo",
                Data::Object(vec![
                    ("name", Data::String(name)),
                    ("version", Data::String("1")),
                ]),
            ),
            (
                "capabilities",
                Data::Object(vec![("experimentalApi", Data::Bool(true))]),
            ),
        ]),
        Box::new(move |io, result| {
            let result = result.and_then(|_| {
                let bytes =
                    json::write(&Data::Object(vec![("method", Data::String("initialized"))]))?;
                next.borrow_mut().write(io, bytes)
            });
            deferred(done)(io, result);
        }),
    );
}
