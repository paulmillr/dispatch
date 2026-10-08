//! Nano owns its native control channel; the multiplexer owns every terminal.
pub mod control;
mod discovery;
mod history;
pub mod journal;
pub mod records;
mod side;
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Value},
    rpc,
};
use std::{
    collections::BTreeMap,
    os::fd::RawFd,
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};

type Callback<T> = Box<dyn FnOnce(&mut Nano, &mut dyn Io, Result<T, Error>)>;
pub struct Nano {
    uid: u32,
    home: PathBuf,
    remote: bool,
    serial: u64,
    jobs: BTreeMap<Work, Callback<Output>>,
    channels: BTreeMap<u32, control::Channel>,
    connecting: BTreeMap<RawFd, (Instant, discovery::Find)>,
    saved: BTreeMap<String, history::Saved>,
}
impl Nano {
    pub fn new(uid: u32, home: PathBuf, remote: bool) -> Self {
        Self {
            uid,
            home,
            remote,
            serial: 0,
            jobs: BTreeMap::new(),
            channels: BTreeMap::new(),
            connecting: BTreeMap::new(),
            saved: BTreeMap::new(),
        }
    }
    /// Typed Nano invocations keep their native arguments unchanged.
    pub fn invoke(
        &mut self,
        io: &mut dyn Io,
        cwd: &Path,
        arguments: &[String],
        done: Done<Command>,
    ) {
        let mut command = Command::new("nanocodex");
        command.args(arguments).current_dir(cwd);
        deferred(done)(io, Ok(command));
    }
    /// Native command acceptance uses the same old-Dispatch send outcome.
    pub fn command(&mut self, io: &mut dyn Io, binding: &Binding, text: &str, done: Done<Outcome>) {
        if let Err(error) = arguments(text) {
            deferred(done)(io, Err(error));
            return;
        }
        if !self
            .channel(binding)
            .ok()
            .and_then(|channel| channel.snapshot.as_ref())
            .is_some_and(|snapshot| flag(snapshot.root(), "capabilities.commands"))
        {
            deferred(done)(io, Err(error("unsupported", "")));
            return;
        }
        Harness::send(
            self,
            io,
            binding,
            text,
            Mode::Prompt,
            true,
            Box::new(move |io, result| done(io, result.map(Outcome::Sent))),
        );
    }
    fn job(&mut self, io: &mut dyn Io, job: Job, done: Callback<Output>) {
        match io.submit(job) {
            Ok(id) => {
                self.jobs.insert(id, done);
            }
            Err(e) => done(self, io, Err(error("io", e.to_string()))),
        }
    }
    fn channel(&self, binding: &Binding) -> Result<&control::Channel, Error> {
        self.channels
            .get(&binding.process.pid)
            .filter(|c| {
                c.binding.process.start == binding.process.start
                    && c.binding.process.executable == binding.process.executable
                    && c.conversations.contains_key(&binding.session)
            })
            .ok_or_else(|| error("not_sent", "Nanocodex’s control connection is unavailable."))
    }
    fn mutate(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        method: &str,
        text: Option<&str>,
        setting: Option<(&str, &str)>,
        done: Callback<Json>,
    ) {
        let params =
            (|| {
                let c = self.channel(binding)?;
                let s = c
                .snapshot
                .as_ref()
                .ok_or_else(|| {
                    error(
                        "not_sent",
                        "Nanocodex’s control connection is not ready yet. Your draft is preserved.",
                    )
                })?
                .root();
                let mut fields = vec![
                    ("expected_instance_id", Data::String(&c.instance)),
                    ("expected_session_id", Data::String(&binding.session)),
                    (
                        "expected_active_generation",
                        Data::String(string(s, "active_generation")),
                    ),
                ];
                if matches!(method, "steer" | "cancel") {
                    let turn = c.conversations[&binding.session].turns.first().ok_or_else(|| {
                    error(
                        "not_sent",
                        if method == "steer" {
                            "Nanocodex has no active turn to steer. Your message is preserved."
                        } else {
                            "Nanocodex has no active turn."
                        },
                    )
                })?;
                    fields.push(("expected_turn_id", Data::String(turn)));
                }
                if method == "settings.set" {
                    fields.push((
                        "expected_settings_revision",
                        Data::String(
                            value(s, "state.settings_revision")
                                .and_then(Value::string)
                                .ok_or_else(|| {
                                    error("not_sent", "Nanocodex settings are unavailable.")
                                })?,
                        ),
                    ));
                }
                if method == "command" && !flag(s, "capabilities.commands") {
                    return Err(error(
                        "not_sent",
                        "This Nanocodex version cannot run commands from Chat.",
                    ));
                }
                if string(s, "active_session_id") != binding.session {
                    return Err(error("not_sent", rejection("session_changed", "")));
                }
                if string(s, "state.connection") != "ready" {
                    return Err(error("not_sent", rejection("session_loading", "")));
                }
                if flag(s, "state.ui_blocked") {
                    return Err(error("not_sent", rejection("ui_blocked", "")));
                }
                if let Some(text) = text {
                    fields.push(("input", Data::Object(vec![("text", Data::String(text))])));
                }
                if let Some((key, value)) = setting {
                    fields.push(("settings", Data::Object(vec![(key, Data::String(value))])));
                }
                document(Data::Object(fields))
            })();
        let pid = binding.process.pid;
        match params {
            Ok(params) => self.request(io, pid, method, params.root(), true, done),
            Err(e) => done(self, io, Err(e)),
        }
    }
    fn catalog(
        &mut self,
        io: &mut dyn Io,
        binding: Binding,
        model: Option<String>,
        done: Done<Menu>,
    ) {
        let pid = binding.process.pid;
        self.request(
            io,
            pid,
            "models.list",
            empty().root(),
            false,
            Box::new(move |this, io, result| {
                let models = match result {
                    Ok(v) => v,
                    Err(e) => {
                        done(io, Err(e));
                        return;
                    }
                };
                this.refresh(
                    io,
                    pid,
                    Box::new(move |this, io, result| {
                        let result = result.and_then(|_| {
                            let s = this.channel(&binding)?.snapshot.as_ref().unwrap().root();
                            if string(s, "active_session_id") != binding.session {
                                return Err(error("changed", rejection("session_changed", "")));
                            }
                            if !flag(s, "state.settings.mutable") {
                                return Err(error(
                                    "unavailable",
                                    "Settings can only change in Nanocodex’s main conversation.",
                                ));
                            }
                            let mut choices = vec![];
                            for (id, efforts) in records::Projection::models(models.root())
                                .map_err(|detail| error("protocol", detail))?
                            {
                                if !flag(s, "state.settings.model_mutable")
                                    && id != string(s, "state.settings.model")
                                {
                                    continue;
                                }
                                let ids = if let Some(model) = &model {
                                    if id != *model {
                                        continue;
                                    }
                                    efforts
                                } else {
                                    vec![id]
                                };
                                choices.extend(ids.into_iter().map(|id| Choice {
                                    label: id.clone(),
                                    id,
                                    detail: None,
                                }));
                            }
                            Ok(Menu {
                                default: None,
                                result: None,
                                choices,
                                current: value(
                                    s,
                                    if model.is_some() {
                                        "state.settings.effort"
                                    } else {
                                        "state.settings.model"
                                    },
                                )
                                .and_then(Value::string)
                                .map(str::to_owned),
                            })
                        });
                        done(io, result);
                    }),
                );
            }),
        );
    }
    fn configure(
        &mut self,
        io: &mut dyn Io,
        binding: Binding,
        mut fields: std::vec::IntoIter<(&'static str, String)>,
        done: Done<Sent>,
    ) {
        let Some((key, val)) = fields.next() else {
            done(io, Ok(sent()));
            return;
        };
        if self
            .channel(&binding)
            .ok()
            .and_then(|c| c.snapshot.as_ref())
            .is_some_and(|s| string(s.root(), &format!("state.settings.{key}")) == val)
        {
            self.configure(io, binding, fields, done);
            return;
        }
        let pid = binding.process.pid;
        self.mutate(
            io,
            &binding.clone(),
            "settings.set",
            None,
            Some((key, &val)),
            Box::new(move |this, io, result| {
                if let Err(e) = result {
                    done(io, Err(e));
                    return;
                }
                this.refresh(
                    io,
                    pid,
                    Box::new(move |this, io, result| match result {
                        Ok(_) => this.configure(io, binding, fields, done),
                        Err(e) => done(io, Err(e)),
                    }),
                );
            }),
        );
    }
}

macro_rules! absent {
    ($($name:ident($($arg:ty),*) -> $result:ty;)*) => {
        $(
            fn $name(&mut self, io: &mut dyn Io, $(_: $arg,)* done: Done<$result>) {
                let result = Err(error(
                    "unsupported",
                    "Nanocodex has no native API for this operation.",
                ));
                deferred(done)(io, result);
            }
        )*
    };
}
impl Harness for Nano {
    fn name(&self) -> &str {
        "Nanocodex"
    }
    fn key(&self) -> &str {
        "nanocodex"
    }
    fn matches(&self, p: &Process) -> bool {
        let service = p.arguments.get(1).is_some_and(|s| {
            s.starts_with("__")
                || [
                    "install",
                    "setup",
                    "tui",
                    "computer",
                    "hand",
                    "account",
                    "auth",
                    "login",
                    "connect",
                    "status",
                    "logout",
                    "cookies",
                    "credits",
                    "eval",
                    "vm-run-config",
                    "run",
                    "managed-server",
                    "update",
                    "attach",
                    "host",
                    "new",
                    "settings",
                    "cron",
                    "list",
                    "state",
                    "turn",
                    "delete",
                    "--version",
                    "-V",
                    "--help",
                    "-h",
                ]
                .contains(&s.as_str())
        });
        matches!(
            p.executable.file_name().and_then(|s| s.to_str()),
            Some("nanocodex" | "nanocodex2")
        ) && !service
    }
    fn launch(&mut self, io: &mut dyn Io, cwd: &Path, arguments: &[String], done: Done<Command>) {
        Nano::invoke(self, io, cwd, arguments, done);
    }
    fn command(&mut self, io: &mut dyn Io, binding: &Binding, text: &str, done: Done<Outcome>) {
        Nano::command(self, io, binding, text, done);
    }
    fn identify(
        &mut self,
        io: &mut dyn Io,
        process: &Process,
        _: Option<&Hook>,
        done: Done<Option<Binding>>,
    ) {
        self.identify(io, process.clone(), deferred(done));
    }
    fn hook(&mut self, _: &Json) -> Result<Hook, Error> {
        Err(error(
            "unsupported",
            "Nanocodex uses its native registration.",
        ))
    }
    fn history(&mut self, io: &mut dyn Io, b: &Binding, earlier: Option<&str>, done: Done<Page>) {
        let done = deferred(done);
        self.page(
            io,
            b.clone(),
            earlier.map(str::to_owned),
            Box::new(move |_, io, r| done(io, r)),
        );
    }
    fn read(&mut self, io: &mut dyn Io, source: &Transcript, done: Done<Archive>) {
        let done = deferred(done);
        self.archive(io, source, Box::new(move |_, io, result| done(io, result)));
    }
    fn state(&mut self, io: &mut dyn Io, b: &Binding, done: Done<State>) {
        let done = deferred(done);
        let b = b.clone();
        let pid = b.process.pid;
        self.refresh(
            io,
            pid,
            Box::new(move |this, io, result| {
                done(
                    io,
                    result.and_then(|_| {
                        this.channel(&b).map(|c| {
                            control::observed(
                                c.snapshot.as_ref().unwrap().root(),
                                &c.conversations[&b.session],
                            )
                        })
                    }),
                )
            }),
        );
    }
    fn commands(&self, _: &Binding) -> Vec<String> {
        [
            "/terminal",
            "/model",
            "/effort",
            "/fast",
            "/btw",
            "/simplify",
            "/split",
            "/close",
            "/collapse",
            "/cancel",
            "/mcp",
            "/voice",
            "/trace",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect()
    }
    fn send(
        &mut self,
        io: &mut dyn Io,
        b: &Binding,
        text: &str,
        mode: Mode,
        command: bool,
        done: Done<Sent>,
    ) {
        let done = deferred(done);
        if command {
            if let Err(error) = arguments(text) {
                done(io, Err(error));
                return;
            }
        }
        if b.session.is_empty() {
            let result = self
                .channels
                .get(&b.process.pid)
                .filter(|channel| {
                    channel.binding.process.start == b.process.start
                        && channel.binding.process.executable == b.process.executable
                })
                .map(|_| Sent::Keys(vec![Input::Paste(text.into()), Input::Key(Key::Enter)]))
                .ok_or_else(|| error("not_sent", "Nanocodex’s control connection is unavailable."));
            done(io, result);
            return;
        }
        if command
            && self
                .channel(b)
                .ok()
                .and_then(|c| c.snapshot.as_ref())
                .is_some_and(|s| !flag(s.root(), "capabilities.commands"))
        {
            let b = b.clone();
            let text = text.to_owned();
            self.refresh(
                io,
                b.process.pid,
                Box::new(move |this, io, result| {
                    let result = result.and_then(|_| {
                        let c = this.channel(&b)?;
                        let s = c.snapshot.as_ref().unwrap().root();
                        if string(s, "active_session_id") != b.session
                            || string(s, "state.connection") != "ready"
                            || string(s, "state.execution") == "running"
                            || !c.conversations[&b.session].turns.is_empty()
                            || flag(s, "state.ui_blocked")
                            || value(s, "state.menu").and_then(Value::string).is_some()
                            || !c.empty
                        {
                            return Err(error(
                                "not_sent",
                                "Nanocodex is busy or has input in Terminal. Your Chat draft is preserved.",
                            ));
                        }
                        Ok(Sent::Keys(vec![
                            Input::Paste(text),
                            Input::Key(Key::Enter),
                        ]))
                    });
                    done(io, result);
                }),
            );
            return;
        }
        self.mutate(
            io,
            b,
            if command {
                "command"
            } else if mode == Mode::Steer {
                "steer"
            } else {
                "prompt"
            },
            Some(text),
            None,
            Box::new(move |_, io, r| done(io, r.map(|_| sent()))),
        );
    }
    fn stop(&mut self, io: &mut dyn Io, b: &Binding, done: Done<Sent>) {
        let done = deferred(done);
        let b = b.clone();
        let pid = b.process.pid;
        self.mutate(
            io,
            &b.clone(),
            "cancel",
            None,
            None,
            Box::new(move |this, io, result| {
                if let Err(e) = result {
                    done(io, Err(e));
                    return;
                }
                if let Some(c) = this.channels.get_mut(&pid) {
                    let at = io.now() + Duration::from_secs(10);
                    io.timer(at);
                    let session = b.session.clone();
                    c.waits.push(side::Wait {
                        at,
                        transition: false,
                        probe: Box::new(move |c| {
                            c.conversations
                                .get(&session)
                                .filter(|v| v.turns.is_empty())
                                .map(|v| Ok(v.binding.clone()))
                        }),
                        done: Box::new(move |_, io, result| done(io, result.map(|_| sent()))),
                    });
                } else {
                    done(
                        io,
                        Err(error(
                            "unknown",
                            "Could not confirm Stop. Check Terminal before trying again.",
                        )),
                    );
                }
            }),
        );
    }
    fn models(&mut self, io: &mut dyn Io, b: &Binding, done: Done<Menu>) {
        self.catalog(io, b.clone(), None, deferred(done));
    }
    fn efforts(&mut self, io: &mut dyn Io, b: &Binding, model: &str, done: Done<Menu>) {
        self.catalog(io, b.clone(), Some(model.to_owned()), deferred(done));
    }
    fn select(
        &mut self,
        io: &mut dyn Io,
        b: &Binding,
        model: &str,
        effort: Option<&str>,
        done: Done<Sent>,
    ) {
        let fields = std::iter::once(("model", model.to_owned()))
            .chain(effort.map(|s| ("effort", s.to_owned())))
            .collect::<Vec<_>>();
        let b = b.clone();
        self.configure(io, b, fields.into_iter(), deferred(done));
    }
    fn menu(&mut self, _io: &mut dyn Io, _: &Binding, _: &Goal, _: &Screen, _: bool) -> Step {
        Step::Fail(error("unsupported", "Nanocodex uses native settings."))
    }
    fn answer(
        &mut self,
        io: &mut dyn Io,
        _: &Binding,
        _: &str,
        _: Vec<(String, Answer)>,
        done: Done<Sent>,
    ) {
        deferred(done)(io, Err(error("terminal", rejection("ui_blocked", ""))));
    }
    fn tool(&mut self, io: &mut dyn Io, b: &Binding, id: &str, done: Done<Record>) {
        let done = deferred(done);
        self.lookup(
            io,
            b.clone(),
            id.to_owned(),
            None,
            None,
            Box::new(move |_, io, result| done(io, result)),
        );
    }
    fn queue(&mut self, io: &mut dyn Io, _: &Binding, done: Done<Vec<Queued>>) {
        deferred(done)(io, Ok(vec![]));
    }
    absent! {
        queue_add(&Binding, &str, Mode) -> Queued;
        queue_edit(&Binding, &str, u64, Option<&str>) -> ();
        queue_send(&Binding, &str, u64, Mode) -> Sent;
        queue_order(&Binding, &[String]) -> ();
    }
    fn side(
        &mut self,
        io: &mut dyn Io,
        b: &Binding,
        text: &str,
        read_only: bool,
        done: Done<Binding>,
    ) {
        let done = deferred(done);
        if read_only {
            done(
                io,
                Err(error(
                    "unsupported",
                    "Nanocodex cannot enforce a read-only side question.",
                )),
            );
            return;
        }
        self.fork(io, b.clone(), text.to_owned(), done);
    }
    fn side_close(&mut self, io: &mut dyn Io, b: &Binding, done: Done<()>) {
        self.finish(io, b.clone(), deferred(done));
    }
    fn install(
        &mut self,
        io: &mut dyn Io,
        _: &Path,
        _: Option<bool>,
        _: Option<&Binding>,
        done: Done<Install>,
    ) {
        deferred(done)(io, Ok(Install::default()));
    }
    fn exited(&mut self, io: &mut dyn Io, process: &Process, _: Option<i32>) {
        if self
            .channels
            .get(&process.pid)
            .is_some_and(|channel| channel.binding.process.start == process.start)
        {
            self.closed(io, process.pid, "Nanocodex exited.".into());
        }
    }
    fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) {
        self.handle(io, ui, event);
    }
}

fn arguments(text: &str) -> Result<(), Error> {
    let mut words = text.split_whitespace();
    if matches!(
        words.next(),
        Some("/close" | "/collapse" | "/split" | "/cancel" | "/trace")
    ) && words.next().is_some()
    {
        return Err(error(
            "command_arguments",
            "This command does not accept those arguments. Use its listed form.",
        ));
    }
    Ok(())
}

fn error(code: &'static str, message: impl Into<String>) -> Error {
    Error {
        code,
        message: message.into(),
    }
}
fn value<'a>(v: Value<'a>, path: &str) -> Option<Value<'a>> {
    path.split('.').try_fold(v, |v, key| v.get(key))
}
fn string<'a>(v: Value<'a>, path: &str) -> &'a str {
    value(v, path).and_then(Value::string).unwrap_or("")
}
fn flag(v: Value<'_>, path: &str) -> bool {
    value(v, path).and_then(Value::boolean).unwrap_or(false)
}
fn document(v: Data<'_>) -> Result<Json, Error> {
    Json::parse(&json::write(&v)?)
}
fn empty() -> Json {
    document(Data::Object(vec![])).expect("core writes JSON")
}
fn native(name: &'static str, fields: Vec<(&str, Data<'_>)>) -> Result<Job, Error> {
    Ok(Job::Native {
        name,
        input: json::write(&Data::Object(fields))?,
    })
}
fn digest(bytes: &[u8]) -> String {
    let mut hash = dispatch_helper4_core::hash::Sha256::new();
    hash.update(bytes);
    hash.finish().iter().map(|b| format!("{b:02x}")).collect()
}
// The exact time adapter is still pending.
pub fn printable(v: Option<Value<'_>>) -> String {
    v.map(|v| {
        v.string().map(str::to_owned).unwrap_or_else(|| {
            String::from_utf8(v.write_with(json::Format::PrettySorted).unwrap_or_default())
                .unwrap_or_default()
        })
    })
    .unwrap_or_default()
}
fn sent() -> Sent {
    Sent::Native {
        written: true,
        may_have_sent: true,
        reason: None,
    }
}
const REJECTIONS: &[(&str, &str)] = &[
    (
        "busy command_pending",
        "Nanocodex is already working. Your message is preserved.",
    ),
    (
        "session_changed instance_changed",
        "The Nanocodex conversation changed. Review Terminal before sending again.",
    ),
    (
        "session_loading",
        "Nanocodex is switching conversations. Try again in a moment.",
    ),
    (
        "ui_blocked",
        "Nanocodex has a dialog open in Terminal. Close it before sending.",
    ),
    ("turn_not_active", "That Nanocodex turn already finished."),
    (
        "settings_changed",
        "Nanocodex settings changed in Terminal. Reopen the picker.",
    ),
    (
        "settings_require_main_conversation",
        "Settings can only change in Nanocodex’s main conversation.",
    ),
    (
        "interactive_command",
        "That command opens a menu in Nanocodex’s terminal. Use Terminal, or /model and /effort in Chat.",
    ),
];
fn rejection(code: &str, detail: &str) -> String {
    if let Some((_, text)) = REJECTIONS
        .iter()
        .find(|(codes, _)| codes.split_whitespace().any(|c| c == code))
    {
        return (*text).into();
    }
    if matches!(
        code,
        "not_a_command" | "invalid_command" | "invalid_settings"
    ) {
        let what = if code == "invalid_settings" {
            "setting"
        } else {
            "command"
        };
        if !detail.is_empty() {
            return format!(
                "Nanocodex rejected the {what}: {}",
                detail.chars().take(512).collect::<String>()
            );
        }
        return if what == "setting" {
            "Nanocodex rejected the setting."
        } else {
            "Nanocodex does not recognize that command."
        }
        .into();
    }
    format!(
        "Nanocodex rejected the request{}. Your message is preserved.",
        if code.is_empty() {
            String::new()
        } else {
            format!(" ({code})")
        }
    )
}
