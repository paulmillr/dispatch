//! Ephemeral Claude print forks over owned stdio. The helper assigns the fork's session id
//! (--session-id with --fork-session), so identity never comes from output or hooks.
use crate::{
    history::{error, text},
    hooks::Request,
};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json, Value},
    rpc::{Lines, Queue},
};
use std::{
    collections::{BTreeMap, VecDeque},
    io,
    os::fd::RawFd,
    path::PathBuf,
    process::{Command, Stdio},
};

pub fn arguments(parent: &str, read_only: bool) -> Vec<String> {
    let mut args = vec![
        "--print",
        "--verbose",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--permission-prompt-tool",
        "stdio",
        "--resume",
        parent,
        "--fork-session",
        "--no-session-persistence",
        "--append-system-prompt",
        "You are in a separate side conversation. The inherited thread is reference context only. Do not continue its task or goal. Answer only new messages in this side conversation. Do not interact with the main thread or its agents.",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect::<Vec<_>>();
    if read_only {
        args.extend(
            [
                "--tools",
                "Read,Grep,Glob,AskUserQuestion",
                "--strict-mcp-config",
                "--mcp-config",
                "{\"mcpServers\":{}}",
                "--permission-mode",
                "manual",
                "--settings",
                "{\"disableAllHooks\":true}",
            ]
            .map(str::to_owned),
        );
    }
    args
}

pub struct Stream {
    pub records: Vec<Record>,
    pub busy: bool,
    pub failure: Option<String>,
    pub closed: bool,
}
impl Default for Stream {
    fn default() -> Self {
        Self::new()
    }
}
impl Stream {
    pub fn new() -> Self {
        Self {
            records: Vec::new(),
            busy: true,
            failure: None,
            closed: false,
        }
    }
    pub fn receive(&mut self, message: &Json, fallback: &str) -> Result<(), Error> {
        let root = message.root();
        match text(root, "type") {
            Some("assistant") => {
                if let Some(message) = root.get("message")
                    && let Some(content) = message.get("content").and_then(Value::array)
                {
                    let body = content
                        .filter(|v| text(*v, "type") == Some("text"))
                        .filter_map(|v| text(v, "text"))
                        .collect::<Vec<_>>()
                        .join("\n");
                    if body.is_empty() {
                        return Ok(());
                    }
                    if body.len() > 1_048_576 {
                        self.failure = Some("Side reply exceeded the display limit.".into());
                        self.closed = true;
                        return Err(error("limit", "Side reply exceeded the display limit."));
                    }
                    let id = text(message, "id").unwrap_or(fallback);
                    if let Some(record) = self.records.iter_mut().find(|record| record.id == id) {
                        record.text = body;
                    } else {
                        self.records.push(Record {
                            id: id.into(),
                            kind: RecordKind::Assistant,
                            text: body,
                            ..Record::default()
                        });
                    }
                }
            }
            Some("result") => {
                self.busy = false;
                if root.get("is_error").and_then(Value::boolean) == Some(true) {
                    self.failure = Some(
                        root.get("errors")
                            .and_then(Value::array)
                            .and_then(|values| {
                                values.map(Value::string).collect::<Option<Vec<_>>>()
                            })
                            .map(|values| values.join("\n"))
                            .unwrap_or_else(|| "The side question failed.".into()),
                    );
                }
            }
            _ => {}
        }
        Ok(())
    }
}

pub struct Launch {
    pub parent: Binding,
    pub directory: PathBuf,
    pub question: String,
    pub model: Option<String>,
    pub read_only: bool,
    pub done: Done<Binding>,
}
struct Fork {
    parent: Binding,
    read_only: bool,
    process: Option<Process>,
    session: Option<String>,
    binding: Option<Binding>,
    done: Option<Done<Binding>>,
    input: RawFd,
    output: RawFd,
    lines: Lines,
    queue: Queue,
    writes: VecDeque<Option<Done<Sent>>>,
    partial: bool,
    stream: Stream,
    requests: BTreeMap<String, Request>,
    /// Answered requests, retired from the UI at the next event (answer has no UI).
    answered: Vec<String>,
}
#[derive(Default)]
pub struct Sides {
    /// Process verification job -> fork pid.
    jobs: BTreeMap<Work, u32>,
    /// Parent environment job -> the launch waiting for it.
    launches: BTreeMap<Work, Launch>,
    forks: BTreeMap<u32, Fork>,
}

fn sent(written: bool, partial: bool, reason: Option<String>) -> Sent {
    Sent::Native {
        written,
        may_have_sent: partial,
        reason,
    }
}
fn random(io: &mut dyn Io) -> Result<String, Error> {
    let mut bytes = [0; 16];
    io.random(&mut bytes).map_err(|e| error("io", e))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
impl Fork {
    fn write(
        &mut self,
        io: &mut dyn Io,
        bytes: Vec<u8>,
        done: Option<Done<Sent>>,
    ) -> Result<(), Error> {
        let result = Lines::encode(bytes, 4_194_304)
            .map_err(|e| error("limit", format!("{e:?}")))
            .and_then(|bytes| {
                self.queue
                    .push(bytes)
                    .map_err(|e| error("limit", format!("{e:?}")))
            });
        if let Err(e) = result {
            if let Some(done) = done {
                deferred(done)(io, Ok(sent(false, false, Some(e.message))));
            }
            return Ok(());
        }
        self.writes.push_back(done);
        self.flush(io)
    }
    fn flush(&mut self, io: &mut dyn Io) -> Result<(), Error> {
        if let Some(bytes) = self.queue.front() {
            let size = bytes.len();
            match io.write(self.input, bytes) {
                Ok(0) => return Err(error("io", "Side connection closed")),
                Ok(count) => {
                    self.partial = true;
                    self.queue
                        .consume(count)
                        .map_err(|e| error("io", format!("{e:?}")))?;
                    if count == size {
                        self.partial = false;
                        if let Some(Some(done)) = self.writes.pop_front() {
                            deferred(done)(io, Ok(sent(true, false, None)));
                        }
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(error("io", e)),
            }
        }
        io.interest(self.input, false, self.queue.front().is_some())
            .map_err(|e| error("io", e))
    }
    fn send(
        &mut self,
        io: &mut dyn Io,
        question: &str,
        done: Option<Done<Sent>>,
    ) -> Result<(), Error> {
        let question = question.trim();
        if question.is_empty() || question.len() > 1_048_576 {
            if let Some(done) = done {
                deferred(done)(
                    io,
                    Ok(sent(false, false, Some("Invalid side question".into()))),
                );
            }
            return Ok(());
        }
        let bytes = json::write(&Data::Object(vec![
            ("type", Data::String("user")),
            (
                "message",
                Data::Object(vec![
                    ("role", Data::String("user")),
                    ("content", Data::String(question)),
                ]),
            ),
            ("session_id", Data::String(&self.parent.session)),
            ("parent_tool_use_id", Data::Null),
        ]))?;
        self.stream.busy = true;
        self.stream.failure = None;
        self.write(io, bytes, done)
    }
    fn publish(&self, ui: &mut dyn Ui) {
        if let Some(binding) = self.binding.as_ref().filter(|b| ui.terminal(b).is_some()) {
            ui.update(Update::Records {
                binding: binding.clone(),
                records: self.stream.records.clone(),
            });
            ui.update(Update::State {
                binding: binding.clone(),
                state: State {
                    busy: self.stream.busy,
                    ..State::default()
                },
            });
        }
    }
    fn retire(&mut self, ui: &mut dyn Ui, id: &str) {
        if let Some(request) = self.requests.remove(id)
            && let Some(binding) = self.binding.as_ref().filter(|b| ui.terminal(b).is_some())
        {
            let mut interaction = request.interaction;
            interaction.questions.clear();
            ui.update(Update::Interaction {
                binding: binding.clone(),
                interaction,
            });
        }
    }
    fn receive(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, doc: Json) -> Result<(), Error> {
        let root = doc.root();
        match text(root, "type") {
            Some("control_request") => {
                // c1654cc ChatSideConversation.swift:316-335: questions always reach the user;
                // read-only sides deny every permission, and an undisplayable one is denied.
                let request = match Request::new(Json::parse(&root.write()?)?) {
                    Ok(request) if !(self.read_only && request.interaction.approval) => request,
                    result => {
                        if result.is_err() {
                            self.stream.failure = Some("The side agent requested an operation Dispatch could not display safely, so it was denied.".into());
                        }
                        let id = text(root, "request_id")
                            .ok_or_else(|| error("side", "Missing side request id"))?;
                        // Old sendPermissionDecision(allow: false).
                        let denied = crate::hooks::control(
                            id,
                            Data::Object(vec![
                                ("behavior", Data::String("deny")),
                                ("message", Data::String("Permission denied.")),
                            ]),
                        )?;
                        self.write(io, denied, None)?;
                        self.publish(ui);
                        return Ok(());
                    }
                };
                let id = request.interaction.id.clone();
                if self.requests.contains_key(&id) {
                    return Ok(());
                }
                if request.interaction.approval
                    && self.requests.values().any(|r| r.interaction.approval)
                {
                    let answers = request
                        .interaction
                        .questions
                        .iter()
                        .map(|q| (q.id.clone(), Answer::Options(vec![1])))
                        .collect();
                    self.write(io, request.answer(answers)?, None)?;
                    self.stream.failure = Some(
                        "A second side permission request was denied while another is pending."
                            .into(),
                    );
                } else {
                    if !request.interaction.approval {
                        let ids = self
                            .requests
                            .iter()
                            .filter(|(_, r)| !r.interaction.approval)
                            .map(|(id, _)| id.clone())
                            .collect::<Vec<_>>();
                        for id in ids {
                            self.retire(ui, &id);
                        }
                    }
                    if let Some(binding) =
                        self.binding.as_ref().filter(|b| ui.terminal(b).is_some())
                    {
                        ui.update(Update::Interaction {
                            binding: binding.clone(),
                            interaction: request.interaction.clone(),
                        });
                    }
                    self.requests.insert(id, request);
                }
            }
            Some("control_cancel_request") => {
                if let Some(id) = text(root, "request_id") {
                    self.retire(ui, id);
                }
            }
            Some("result") => {
                for id in self.requests.keys().cloned().collect::<Vec<_>>() {
                    self.retire(ui, &id);
                }
                self.stream.receive(&doc, "")?;
            }
            Some("assistant") => {
                let fallback = if root.get("message").and_then(|v| text(v, "id")).is_none() {
                    random(io)?
                } else {
                    String::new()
                };
                self.stream.receive(&doc, &fallback)?;
            }
            _ => {}
        }
        self.publish(ui);
        Ok(())
    }
}

impl Sides {
    pub fn contains(&self, binding: &Binding) -> bool {
        self.forks
            .get(&binding.process.pid)
            .and_then(|fork| fork.binding.as_ref())
            == Some(binding)
    }
    pub fn open(&mut self, io: &mut dyn Io, launch: Launch) {
        // e076fd7 CodexProcess.sideEnvironment: the side runs with the parent's own values of
        // these names only (API endpoint/key, config dir), read from the parent process.
        let names = [
            "HOME",
            "CLAUDE_CONFIG_DIR",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
            "DISABLE_AUTOUPDATER",
            "DISABLE_TELEMETRY",
            "DISABLE_ERROR_REPORTING",
        ]
        .into_iter()
        .map(Data::String)
        .collect();
        let input = json::write(&Data::Object(vec![
            ("pid", Data::Unsigned(launch.parent.process.pid.into())),
            ("names", Data::Array(names)),
        ]));
        let job = input.map(|input| Job::Native {
            name: "environment",
            input,
        });
        match job
            .map_err(|e| error("json", format!("{e:?}")))
            .and_then(|job| io.submit(job).map_err(|e| error("io", e)))
        {
            Ok(work) => {
                self.launches.insert(work, launch);
            }
            Err(e) => deferred(launch.done)(io, Err(e)),
        }
    }
    fn spawn(&mut self, io: &mut dyn Io, launch: Launch, environment: &[u8]) -> Result<(), Error> {
        let mut id = [0u8; 16];
        io.random(&mut id).map_err(|e| error("io", e))?;
        id[6] = id[6] & 0x0f | 0x40;
        id[8] = id[8] & 0x3f | 0x80;
        let hex = id.iter().map(|b| format!("{b:02x}")).collect::<String>();
        let session = format!(
            "{}-{}-{}-{}-{}",
            &hex[..8],
            &hex[8..12],
            &hex[12..16],
            &hex[16..20],
            &hex[20..]
        );
        let mut command = Command::new(&launch.parent.process.executable);
        command
            .current_dir(&launch.directory)
            .args(arguments(&launch.parent.session, launch.read_only))
            .args(["--session-id", &session]);
        if let Some(model) = &launch.model {
            command.args(["--model", model]);
        }
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .env_clear();
        let environment = Json::parse(environment)?;
        for (name, value) in environment.root().object().into_iter().flatten() {
            if let Some(value) = value.string() {
                command.env(name, value);
            }
        }
        let child = io.spawn(command, None).map_err(|e| error("io", e))?;
        let (Some(input), Some(output)) = (child.input, child.output) else {
            if let Some(fd) = child.input {
                io.close(fd);
            }
            if let Some(fd) = child.output {
                io.close(fd);
            }
            let _ = io.terminate(child.pid);
            return Err(error("io", "Missing side pipes"));
        };
        let mut fork = Fork {
            parent: launch.parent,
            read_only: launch.read_only,
            process: None,
            session: Some(session),
            binding: None,
            done: Some(launch.done),
            input,
            output,
            lines: Lines::new(4_194_304),
            queue: Queue::new(8_388_608),
            writes: VecDeque::new(),
            partial: false,
            stream: Stream::new(),
            requests: BTreeMap::new(),
            answered: Vec::new(),
        };
        let result = io
            .child(child.pid)
            .and_then(|_| io.interest(output, true, false))
            .map_err(|e| error("io", e))
            .and_then(|_| fork.send(io, &launch.question, None));
        self.forks.insert(child.pid, fork);
        if let Err(e) = result {
            self.close(io, child.pid, e.message);
            return Ok(());
        }
        match io.submit(Job::Process { pid: child.pid }) {
            Ok(work) => {
                self.jobs.insert(work, child.pid);
            }
            Err(e) => self.close(io, child.pid, e.to_string()),
        }
        Ok(())
    }
    fn ready(&mut self, io: &mut dyn Io, pid: u32) {
        if let Some(fork) = self.forks.get_mut(&pid)
            && let (Some(process), Some(session), Some(done)) =
                (&fork.process, &fork.session, fork.done.as_ref())
        {
            let _ = done;
            let binding = Binding {
                process: process.clone(),
                session: session.clone(),
                transcript: None,
            };
            fork.binding = Some(binding.clone());
            deferred(fork.done.take().unwrap())(io, Ok(binding));
        }
    }
    pub fn page(&self, binding: &Binding) -> Page {
        Page {
            records: self.forks[&binding.process.pid].stream.records.clone(),
            earlier: None,
        }
    }
    /// Still-open (unanswered) side requests of `binding`, for a chat that opens.
    pub fn cards(&self, binding: &Binding) -> Vec<Interaction> {
        self.forks
            .get(&binding.process.pid)
            .map(|fork| {
                fork.requests
                    .iter()
                    .filter(|(id, _)| !fork.answered.contains(id))
                    .map(|(_, request)| request.interaction.clone())
                    .collect()
            })
            .unwrap_or_default()
    }
    pub fn state(&self, binding: &Binding) -> State {
        State {
            busy: self.forks[&binding.process.pid].stream.busy,
            ..State::default()
        }
    }
    pub fn send(&mut self, io: &mut dyn Io, binding: &Binding, text: &str, done: Done<Sent>) {
        if let Err(e) = self
            .forks
            .get_mut(&binding.process.pid)
            .unwrap()
            .send(io, text, Some(done))
        {
            self.close(io, binding.process.pid, e.message);
        }
    }
    pub fn answer(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        id: &str,
        answers: Vec<(String, Answer)>,
        done: Done<Sent>,
    ) {
        let fork = self.forks.get_mut(&binding.process.pid).unwrap();
        let bytes = fork
            .requests
            .get(id)
            .filter(|_| !fork.answered.iter().any(|a| a == id))
            .ok_or_else(|| error("expired", "Side question expired"))
            .and_then(|r| r.answer(answers));
        match bytes {
            Ok(bytes) => {
                fork.answered.push(id.into());
                io.timer(io.now());
                if let Err(e) = fork.write(io, bytes, Some(done)) {
                    self.close(io, binding.process.pid, e.message);
                }
            }
            Err(e) => deferred(done)(io, Err(e)),
        }
    }
    pub fn close(&mut self, io: &mut dyn Io, pid: u32, reason: String) {
        if let Some(mut fork) = self.forks.remove(&pid) {
            io.close(fork.input);
            io.close(fork.output);
            let _ = io.terminate(pid);
            if let Some(done) = fork.done.take() {
                deferred(done)(io, Err(error("side", &reason)));
            }
            for done in fork.writes.into_iter().flatten() {
                deferred(done)(io, Ok(sent(false, fork.partial, Some(reason.clone()))));
            }
        }
        let works = self
            .jobs
            .iter()
            .filter_map(|(work, child)| (*child == pid).then_some(*work))
            .collect::<Vec<_>>();
        for work in works {
            self.jobs.remove(&work);
            io.cancel(work);
        }
    }
    pub fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) -> Option<Event> {
        for fork in self.forks.values_mut() {
            for id in std::mem::take(&mut fork.answered) {
                fork.retire(ui, &id);
            }
        }
        match event {
            Event::Done { work, result } if self.launches.contains_key(&work) => {
                let launch = self.launches.remove(&work).unwrap();
                let done = launch.done;
                let completion = std::rc::Rc::new(std::cell::RefCell::new(Some(done)));
                let captured = completion.clone();
                let launch = Launch {
                    done: Box::new(move |io, result| {
                        if let Some(done) = captured.borrow_mut().take() {
                            done(io, result);
                        }
                    }),
                    ..launch
                };
                let result = match result {
                    Ok(Output::Bytes(bytes)) => self.spawn(io, launch, &bytes),
                    Ok(_) => Err(error("side", "Unexpected parent environment")),
                    Err(e) => Err(error("io", e)),
                };
                if let Err(e) = result
                    && let Some(done) = completion.borrow_mut().take()
                {
                    deferred(done)(io, Err(e));
                }
            }
            Event::Done { work, result } if self.jobs.contains_key(&work) => {
                let pid = self.jobs.remove(&work).unwrap();
                if let Ok(Output::Process(process)) = result
                    && process.pid == pid
                    && let Some(fork) = self.forks.get_mut(&pid)
                    && process.executable == fork.parent.process.executable
                {
                    fork.process = Some(process);
                    self.ready(io, pid);
                } else {
                    self.close(io, pid, "Side process changed".into());
                }
            }
            Event::Ready { fd, read, write }
                if self.forks.values().any(|f| f.input == fd || f.output == fd) =>
            {
                let pid = *self
                    .forks
                    .iter()
                    .find(|(_, f)| f.input == fd || f.output == fd)
                    .unwrap()
                    .0;
                let result = (|| {
                    let fork = self.forks.get_mut(&pid).unwrap();
                    if write && fd == fork.input {
                        fork.flush(io)?;
                    }
                    if read && fd == fork.output {
                        let mut buffer = [0; 65_536];
                        match io.read(fd, &mut buffer) {
                            Ok(0) => return Err(error("side", "Side connection closed")),
                            Ok(count) => {
                                let mut docs = Vec::new();
                                fork.lines
                                    .feed(&buffer[..count], |line| {
                                        if let Ok(doc) = Json::parse(line) {
                                            docs.push(doc);
                                        }
                                        Ok(())
                                    })
                                    .map_err(|e| error("limit", format!("{e:?}")))?;
                                for doc in docs {
                                    fork.receive(io, ui, doc)?;
                                }
                            }
                            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                            Err(e) => return Err(error("io", e)),
                        }
                    }
                    Ok(())
                })();
                if let Err(e) = result {
                    self.close(io, pid, e.message);
                }
            }
            Event::Exit { pid, .. } if self.forks.contains_key(&pid) => {
                self.close(io, pid, "Side process exited".into());
            }
            event => return Some(event),
        }
        None
    }
}
