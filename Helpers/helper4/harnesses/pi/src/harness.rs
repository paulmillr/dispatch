//! Pi control methods; terminal input is returned to the multiplexer.
use crate::{
    bridge::{self, Shared},
    history,
    records::text,
};
use dispatch_helper4_core::{
    api::*,
    json::{Data, Json, Value},
};
use std::{
    path::{Path, PathBuf},
    process::Command,
    rc::Rc,
};

pub struct Pi {
    pub runtime: Shared,
}
impl Pi {
    pub fn new(home: PathBuf) -> Self {
        let runtime = Shared::default();
        runtime.borrow_mut().home = home;
        Self { runtime }
    }
    pub fn invoke(
        &mut self,
        io: &mut dyn Io,
        cwd: &Path,
        arguments: &[String],
        done: Done<Command>,
    ) {
        let mut command = Command::new("pi");
        command.args(arguments).current_dir(cwd);
        deferred(done)(io, Ok(command));
    }
    pub fn command(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        value: &str,
        done: Done<Outcome>,
    ) {
        let result = arguments(value).and_then(|_| {
            // These commands replace the binding or leave Pi; completion follows discovery.
            if matches!(
                value.split_whitespace().next(),
                Some("/new" | "/reload" | "/quit")
            ) {
                Err(bridge::fail("unsupported", "Run this command in Terminal."))
            } else {
                self.runtime
                    .borrow_mut()
                    .menus
                    .insert(binding.session.clone(), crate::screen::Command::default());
                Err(bridge::fail("menu", ""))
            }
        });
        deferred(done)(io, result);
    }
    /// Pi's composer commands use a literal paste followed by Enter.
    pub fn input(value: &str) -> Vec<Input> {
        vec![Input::Paste(value.to_owned()), Input::Key(Key::Enter)]
    }
    fn verify(&self, io: &mut dyn Io, process: &Process, done: Done<bool>) {
        if prefix(process).is_none() {
            return deferred(done)(io, Ok(false));
        }
        let script = (prefix(process) == Some(2)).then(|| process.arguments.get(1))
            .flatten().filter(|value| !value.is_empty()).cloned();
        if let Some(script) = script {
            let path = script.clone();
            bridge::native(&self.runtime, io, "file.realpath",
                Data::Object(vec![("path", Data::String(&path))]),
                Box::new(move |io, result| done(io, Ok(result.is_ok_and(|value| {
                    value.root().get("path").and_then(Value::string)
                        .is_some_and(|path| script_path(&script, path))
                })))));
        } else {
            deferred(done)(io, Ok(true));
        }
    }
}
impl Harness for Pi {
    fn name(&self) -> &str {
        "Pi"
    }
    fn key(&self) -> &str {
        "pi"
    }
    fn matches(&self, process: &Process) -> bool {
        recognizes(&self.runtime, process)
    }
    fn candidate(&mut self, io: &mut dyn Io, process: &Process, done: Done<Option<Error>>) {
        // An overwritten Node title needs its live registration to identify the program.
        if !recognizes(&self.runtime, process) || title(process) {
            return deferred(done)(io, Ok(None));
        }
        self.verify(io, process, Box::new(move |io, verified| {
            done(io, Ok(verified.unwrap_or(false).then(|| bridge::fail("setup",
                "Pi has not published a live Chat session. Enable the Pi Chat extension, then run /reload in Terminal."))));
        }));
    }
    fn launch(&mut self, io: &mut dyn Io, cwd: &Path, arguments: &[String], done: Done<Command>) {
        Pi::invoke(self, io, cwd, arguments, done);
    }
    fn command(&mut self, io: &mut dyn Io, binding: &Binding, text: &str, done: Done<Outcome>) {
        Pi::command(self, io, binding, text, done);
    }
    fn exited(&mut self, io: &mut dyn Io, process: &Process, status: Option<i32>) {
        crate::transcript::stop(&self.runtime, io, process.pid);
        bridge::event(
            &self.runtime,
            io,
            Event::Exit {
                pid: process.pid,
                status,
            },
        );
    }
    fn identify(
        &mut self,
        io: &mut dyn Io,
        process: &Process,
        _hook: Option<&Hook>,
        done: Done<Option<Binding>>,
    ) {
        if prefix(process).is_none() {
            deferred(done)(io, Ok(None));
            return;
        }
        let process = process.clone();
        let saved = self.runtime.clone();
        let candidate = process.clone();
        let identify: Done<bool> = Box::new(move |io, valid| {
            if !valid.unwrap_or(false) {
                done(io, Ok(None));
                return;
            }
            bridge::registration(
                &saved.clone(),
                io,
                &process.clone(),
                Box::new(move |io, result| match result {
                    Ok(record) => {
                        let binding = Binding {
                            session: record.session.clone(),
                            transcript: record.path.clone(),
                            process,
                        };
                        saved
                            .borrow_mut()
                            .registrations
                            .insert(binding.process.pid, record);
                        let matched = recognizes(&saved, &binding.process);
                        if !matched {
                            done(io, Ok(None));
                            return;
                        }
                        bridge::call(
                            &saved,
                            io,
                            &binding.clone(),
                            "probe",
                            Vec::new(),
                            Box::new(move |io, result| done(io, Ok(result.ok().map(|_| binding)))),
                        );
                    }
                    Err(_) => done(io, Ok(None)),
                }),
            );
        });
        self.verify(io, &candidate, identify);
    }

    fn hook(&mut self, message: &Json) -> Result<Hook, Error> {
        let root = message.root();
        Ok(Hook {
            fallback: Vec::new(),
            interactive: false,
            event: root
                .get("event")
                .and_then(Value::string)
                .unwrap_or(&text(root, "type"))
                .into(),
            session: root
                .get("sessionId")
                .and_then(Value::string)
                .map(str::to_owned),
            cwd: root.get("cwd").and_then(Value::string).map(Into::into),
            pid: root
                .get("pid")
                .and_then(Value::unsigned)
                .and_then(|v| v.try_into().ok()),
            payload: Json::parse(&root.write()?)?,
        })
    }
    fn history(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        earlier: Option<&str>,
        done: Done<Page>,
    ) {
        history::read(&self.runtime, io, binding, earlier, done);
    }
    fn tool(&mut self, io: &mut dyn Io, binding: &Binding, record: &str, done: Done<Record>) {
        history::tool(&self.runtime, io, binding, record, done);
    }
    fn read(&mut self, io: &mut dyn Io, source: &Transcript, done: Done<Archive>) {
        history::archive(&self.runtime, io, source, done);
    }
    fn state(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<State>) {
        let saved = self.runtime.clone();
        let session = binding.session.clone();
        let binding = binding.clone();
        bridge::call(
            &self.runtime,
            io,
            &binding.clone(),
            "state",
            Vec::new(),
            Box::new(move |io, result| {
                let mut result = result.and_then(|document| {
                    let value = document
                        .root()
                        .get("state")
                        .ok_or_else(|| bridge::fail("state", "Pi returned no session state."))?;
                    let state = state(value)?;
                    let interactive = saved
                        .borrow()
                        .registrations
                        .get(&binding.process.pid)
                        .is_some_and(|record| record.version == "extension-v2");
                    if interactive {
                        for interaction in crate::events::interactions(value) {
                            saved.borrow_mut().pages.push(Update::Interaction {
                                binding: binding.clone(),
                                interaction,
                            });
                        }
                        io.timer(io.now());
                    }
                    saved.borrow_mut().states.insert(session, Rc::new(document));
                    Ok(state)
                });
                let events = saved
                    .borrow()
                    .registrations
                    .get(&binding.process.pid)
                    .is_some_and(|r| r.version == "extension-v2");
                if result.is_ok() && events {
                    saved.borrow_mut().legacy.remove(&binding.session);
                    if let Err(error) = bridge::subscribe(&saved, io, &binding, false) {
                        result = Err(error);
                    }
                } else if result.is_ok() {
                    crate::legacy::start(&saved, io, &binding);
                }
                done(io, result);
            }),
        );
    }
    fn commands(&self, binding: &Binding) -> Vec<String> {
        let runtime = self.runtime.borrow();
        let value = runtime.states.get(&binding.session).and_then(|document| {
            let root = document.root();
            root.get("state").or_else(|| root.get("value"))
        });
        commands(value)
    }
    fn send(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        value: &str,
        mode: Mode,
        command: bool,
        done: Done<Sent>,
    ) {
        if value.trim().is_empty()
            || value.len() > 1_000_000
            || value
                .chars()
                .any(|c| c.is_ascii_control() && c != '\n' && c != '\t')
        {
            deferred(done)(io, Err(bridge::fail("not_sent", "Invalid Pi input")));
            return;
        }
        if command {
            if let Err(error) = arguments(value) {
                deferred(done)(io, Err(error));
                return;
            }
            let value = value.to_owned();
            bridge::call(
                &self.runtime,
                io,
                binding,
                "state",
                Vec::new(),
                Box::new(move |io, result| {
                    let result = result.and_then(|document| {
                        let state = document.root().get("state").ok_or_else(|| {
                            bridge::fail("not_sent", "Pi returned no session state.")
                        })?;
                        if state.get("busy").and_then(Value::boolean) != Some(false)
                            || !text(state, "editor").is_empty() {
                            return Err(bridge::fail(
                                "not_sent",
                                "Pi is busy or has input in Terminal. Your Chat draft is preserved.",
                            ));
                        }
                        Ok(Sent::Keys(Pi::input(&value)))
                    });
                    deferred(done)(io, result);
                }),
            );
        } else {
            bridge::call(
                &self.runtime,
                io,
                binding,
                match mode {
                    Mode::Prompt => "prompt",
                    Mode::Steer => "steer",
                    Mode::FollowUp => "follow_up",
                },
                vec![("text", Data::String(value))],
                Box::new(move |io, result| done(io, Ok(sent(result)))),
            );
        }
    }
    fn stop(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<Sent>) {
        bridge::call(
            &self.runtime,
            io,
            binding,
            "abort",
            Vec::new(),
            Box::new(move |io, result| done(io, Ok(sent(result)))),
        );
    }
    fn models(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<Menu>) {
        bridge::call(
            &self.runtime,
            io,
            binding,
            "models",
            Vec::new(),
            Box::new(move |io, result| {
                done(
                    io,
                    result.and_then(|document| {
                        let root = document.root();
                        let models =
                            root.get("models").and_then(Value::array).ok_or_else(|| {
                                bridge::fail("models", "Pi returned no model choices.")
                            })?;
                        let choices = models
                            .map(|value| Choice {
                                id: model(value),
                                label: text(value, "name"),
                                detail: Some(text(value, "provider")),
                            })
                            .collect();
                        let current = root.get("state").and_then(|v| v.get("model")).map(model);
                        Ok(Menu {
                            default: None,
                            choices,
                            current,
                            result: None,
                        })
                    }),
                );
            }),
        );
    }
    fn efforts(&mut self, io: &mut dyn Io, binding: &Binding, selected: &str, done: Done<Menu>) {
        let selected = selected.to_owned();
        bridge::call(
            &self.runtime,
            io,
            binding,
            "models",
            Vec::new(),
            Box::new(move |io, result| {
                done(
                    io,
                    result.and_then(|document| {
                        let root = document.root();
                        let choice = choice(root, &selected)?;
                        let choices = levels(choice)
                            .into_iter()
                            .map(|level| Choice {
                                id: level.clone(),
                                label: level,
                                detail: None,
                            })
                            .collect();
                        let current = root
                            .get("state")
                            .and_then(|v| v.get("effort"))
                            .and_then(Value::string)
                            .map(str::to_owned);
                        Ok(Menu {
                            default: None,
                            choices,
                            current,
                            result: None,
                        })
                    }),
                );
            }),
        );
    }
    fn select(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        selected: &str,
        effort: Option<&str>,
        done: Done<Sent>,
    ) {
        let selected = selected.to_owned();
        let effort = effort.map(str::to_owned);
        let binding = binding.clone();
        let saved = self.runtime.clone();
        bridge::call(
            &self.runtime,
            io,
            &binding.clone(),
            "models",
            Vec::new(),
            Box::new(move |io, result| {
                let document = match result {
                    Ok(v) => v,
                    Err(e) => {
                        done(io, Err(e));
                        return;
                    }
                };
                let root = document.root();
                let choice = match choice(root, &selected) {
                    Ok(choice) => choice,
                    Err(error) => {
                        done(io, Err(error));
                        return;
                    }
                };
                let choices = levels(choice);
                let current = root
                    .get("state")
                    .and_then(|v| v.get("effort"))
                    .and_then(Value::string);
                let effort = effort
                    .or_else(|| {
                        current
                            .filter(|value| choices.iter().any(|choice| choice == value))
                            .map(str::to_owned)
                    })
                    .or_else(|| choices.first().cloned())
                    .unwrap_or_else(|| "off".into());
                bridge::call(
                    &saved,
                    io,
                    &binding,
                    "configure",
                    vec![
                        ("provider", Data::String(&text(choice, "provider"))),
                        ("model", Data::String(&text(choice, "id"))),
                        ("effort", Data::String(&effort)),
                    ],
                    Box::new(move |io, result| done(io, Ok(sent(result)))),
                );
            }),
        );
    }
    fn menu(&mut self, _io: &mut dyn Io, binding: &Binding, goal: &Goal, screen: &Screen, settled: bool) -> Step {
        if let Goal::Send {
            text,
            command: true,
            ..
        } = goal
        {
            let mut runtime = self.runtime.borrow_mut();
            if let Some(command) = runtime.menus.get_mut(&binding.session) {
                let step = command.step(text, screen, settled);
                if matches!(step, Step::Done(_) | Step::Fail(_)) {
                    runtime.menus.remove(&binding.session);
                }
                return step;
            }
        }
        Step::Fail(bridge::fail(
            "native",
            "Pi Chat uses the managed extension. Enable it, then run /reload in Terminal.",
        ))
    }
    fn answer(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        interaction: &str,
        answers: Vec<(String, Answer)>,
        done: Done<Sent>,
    ) {
        let values = answers
            .iter()
            .map(|(id, answer)| {
                Data::Object(vec![
                    ("id", Data::String(id)),
                    (
                        "value",
                        match answer {
                            Answer::Options(values) => Data::Array(
                                values
                                    .iter()
                                    .map(|value| Data::Unsigned(*value as u64))
                                    .collect(),
                            ),
                            Answer::Text(value) => Data::String(value),
                            Answer::Skip => Data::Null,
                        },
                    ),
                ])
            })
            .collect();
        bridge::call(
            &self.runtime,
            io,
            binding,
            "answer",
            vec![
                ("interaction", Data::String(interaction)),
                ("answers", Data::Array(values)),
            ],
            Box::new(move |io, result| done(io, Ok(sent(result)))),
        );
    }
    fn queue(&mut self, io: &mut dyn Io, _binding: &Binding, done: Done<Vec<Queued>>) {
        deferred(done)(io, Ok(Vec::new()));
    }
    fn queue_add(
        &mut self,
        io: &mut dyn Io,
        _binding: &Binding,
        _text: &str,
        _mode: Mode,
        done: Done<Queued>,
    ) {
        unavailable(io, done);
    }
    fn queue_edit(
        &mut self,
        io: &mut dyn Io,
        _binding: &Binding,
        _item: &str,
        _revision: u64,
        _text: Option<&str>,
        done: Done<()>,
    ) {
        unavailable(io, done);
    }
    fn queue_send(
        &mut self,
        io: &mut dyn Io,
        _binding: &Binding,
        _item: &str,
        _revision: u64,
        _mode: Mode,
        done: Done<Sent>,
    ) {
        unavailable(io, done);
    }
    fn queue_order(
        &mut self,
        io: &mut dyn Io,
        _binding: &Binding,
        _items: &[String],
        done: Done<()>,
    ) {
        unavailable(io, done);
    }
    fn side(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        question: &str,
        read_only: bool,
        done: Done<Binding>,
    ) {
        crate::side::start(&self.runtime, io, binding, question, read_only, done);
    }
    fn side_close(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<()>) {
        crate::side::close(&self.runtime, io, binding, done);
    }
    fn install(
        &mut self,
        io: &mut dyn Io,
        _route: &Path,
        enabled: Option<bool>,
        agent: Option<&Binding>,
        done: Done<Install>,
    ) {
        crate::install::run(&self.runtime, io, enabled, agent, done);
    }
    fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) {
        crate::legacy::tick(&self.runtime, io, ui);
        crate::transcript::event(&self.runtime, io, ui, &event);
        crate::side::event(&self.runtime, io, &event);
        bridge::event(&self.runtime, io, event);
        let updates = std::mem::take(&mut self.runtime.borrow_mut().updates);
        for (binding, document) in updates {
            crate::events::publish(&self.runtime, io, ui, &binding, document);
        }
        let pages = std::mem::take(&mut self.runtime.borrow_mut().pages);
        for page in pages {
            ui.update(page);
        }
    }
}
pub fn script_path(invoked: &str, resolved: &str) -> bool {
    Path::new(invoked)
        .file_name()
        .is_some_and(|name| name == "pi")
        || resolved.ends_with("/pi-coding-agent/dist/cli.js")
        || resolved.ends_with("/pi-coding-agent/dist/bundle/cli.js")
}

pub(crate) fn prefix(process: &Process) -> Option<usize> {
    match process.executable.file_name().and_then(|s| s.to_str()) {
        Some("pi" | "pi.exe") => Some(1),
        Some("node" | "node.exe" | "bun" | "bun.exe") => Some(2),
        _ => None,
    }
}
pub fn title(process: &Process) -> bool {
    prefix(process) == Some(2)
        && process
            .arguments
            .first()
            .is_some_and(|argument| argument == "pi")
        && process.arguments[1..].iter().all(String::is_empty)
}
fn recognizes(runtime: &Shared, process: &Process) -> bool {
    if runtime.borrow().sides.contains_key(&process.pid) || process.arguments.is_empty() {
        return false;
    }
    let options = if prefix(process) == Some(1) {
        &process.arguments[1..]
    } else if prefix(process) == Some(2) {
        if title(process) {
            return true;
        }
        if !process
            .arguments
            .get(1)
            .is_some_and(|script| script_path(script, script))
        {
            return false;
        }
        &process.arguments[2..]
    } else {
        return false;
    };
    if options.first().is_some_and(|s| {
        [
            "install", "remove", "update", "list", "config", "auth", "login", "logout", "server",
            "client",
        ]
        .contains(&s.as_str())
    }) {
        return false;
    }
    let mut skip = false;
    for (index, argument) in options.iter().enumerate() {
        if skip {
            skip = false;
            continue;
        }
        if argument == "--" {
            break;
        }
        if [
            "--print",
            "-p",
            "--help",
            "-h",
            "--version",
            "-v",
            "--export",
            "--list-models",
        ]
        .contains(&argument.as_str())
            || ["--print=", "--mode=rpc", "--mode=json"]
                .iter()
                .any(|prefix| argument.starts_with(prefix))
        {
            return false;
        }
        if argument == "--mode" {
            if options
                .get(index + 1)
                .is_some_and(|mode| ["rpc", "json"].contains(&mode.as_str()))
            {
                return false;
            }
            skip = options.get(index + 1).is_some();
            continue;
        }
        skip = [
            "--provider",
            "--model",
            "--api-key",
            "--system-prompt",
            "--append-system-prompt",
            "--name",
            "-n",
            "--session",
            "--session-id",
            "--fork",
            "--session-dir",
            "--models",
            "--tools",
            "-t",
            "--exclude-tools",
            "-xt",
            "--thinking",
            "--extension",
            "-e",
            "--skill",
            "--prompt-template",
            "--theme",
            "--use-theme",
            "--tui-mode",
        ]
        .contains(&argument.as_str());
    }
    true
}
fn arguments(value: &str) -> Result<(), Error> {
    let mut words = value.split_whitespace();
    if matches!(
        words.next(),
        Some("/settings" | "/new" | "/resume" | "/tree" | "/fork" | "/reload" | "/quit")
    ) && words.next().is_some()
    {
        return Err(bridge::fail(
            "command_arguments",
            "This command does not accept those arguments. Use its listed form.",
        ));
    }
    Ok(())
}
fn unavailable<T: 'static>(io: &mut dyn Io, done: Done<T>) {
    deferred(done)(
        io,
        Err(bridge::fail(
            "unsupported",
            "Pi's extension API does not expose native queue item IDs or editing. Use the existing editable Chat queue.",
        )),
    );
}
fn choice<'a>(value: Value<'a>, selected: &str) -> Result<Value<'a>, Error> {
    value
        .get("models")
        .and_then(Value::array)
        .and_then(|mut values| values.find(|value| model(*value) == selected))
        .ok_or_else(|| bridge::fail("models", "This model is not available in the Pi session"))
}
fn sent(result: Result<Json, Error>) -> Sent {
    match result {
        Ok(_) => Sent::Native {
            written: true,
            may_have_sent: false,
            reason: None,
        },
        Err(error) => Sent::Native {
            written: false,
            may_have_sent: error.code == "may_have_sent",
            reason: Some(error.message),
        },
    }
}
fn model(value: Value<'_>) -> String {
    format!("{}/{}", text(value, "provider"), text(value, "id"))
}
fn levels(value: Value<'_>) -> Vec<String> {
    value
        .get("thinkingLevels")
        .and_then(Value::array)
        .into_iter()
        .flatten()
        .filter_map(Value::string)
        .map(str::to_owned)
        .collect()
}
pub fn prompt(value: Value<'_>) -> Result<Option<Value<'_>>, Error> {
    let Some(prompt) = value.get("uiPrompt") else {
        return Ok(None);
    };
    if prompt.kind() == dispatch_helper4_core::json::Kind::Null {
        return Ok(None);
    }
    let supported = prompt
        .get("kind")
        .and_then(Value::string)
        .is_some_and(|kind| ["select", "confirm", "input", "editor", "custom"].contains(&kind));
    let title = prompt.get("title").is_none_or(|value| {
        value.kind() == dispatch_helper4_core::json::Kind::Null || value.string().is_some()
    });
    if !supported || !title {
        return Err(bridge::fail(
            "state",
            "Pi returned an invalid Chat response.",
        ));
    }
    Ok(Some(prompt))
}

pub fn state(value: Value<'_>) -> Result<State, Error> {
    if !value.get("leafId").is_some_and(|leaf| {
        leaf.kind() == dispatch_helper4_core::json::Kind::Null || leaf.string().is_some()
    }) || value.get("editor").and_then(Value::string).is_none()
    {
        return Err(bridge::fail(
            "state",
            "Pi returned an invalid Chat response.",
        ));
    }
    let busy = value
        .get("busy")
        .and_then(Value::boolean)
        .ok_or_else(|| bridge::fail("state", "Pi returned an invalid Chat response."))?;
    let prompt = prompt(value)?;
    Ok(State {
        title: value.get("name").and_then(Value::string).map(str::to_owned),
        pending: value
            .get("pending")
            .and_then(Value::boolean)
            .unwrap_or(false),
        busy: busy || prompt.is_some(),
        activity: Some(
            if prompt.is_some() {
                "waiting"
            } else if busy {
                "working"
            } else {
                "idle"
            }
            .into(),
        ),
        model: value
            .get("model")
            .filter(|v| v.kind() == dispatch_helper4_core::json::Kind::Object)
            .map(model),
        model_label: value
            .get("model")
            .and_then(|model| model.get("name"))
            .and_then(Value::string)
            .map(str::to_owned),
        effort: value
            .get("effort")
            .and_then(Value::string)
            .map(str::to_owned),
        draft: value
            .get("editor")
            .and_then(Value::string)
            .map(str::to_owned),
        attention: prompt
            .map(|_| "Pi needs an answer in Terminal. Your Chat draft is preserved.".into()),
        leaf: value
            .get("leafId")
            .and_then(Value::string)
            .map(str::to_owned),
        dialog: prompt
            .and_then(|value| value.get("kind"))
            .and_then(Value::string)
            .map(str::to_owned),
        usage: usage(value.get("usage")),
        ..State::default()
    })
}

pub fn commands(value: Option<Value<'_>>) -> Vec<String> {
    let mut names = [
        "/terminal",
        "/model",
        "/settings",
        "/new",
        "/compact",
        "/resume",
        "/tree",
        "/fork",
        "/reload",
        "/help",
        "/quit",
    ]
    .map(str::to_owned)
    .to_vec();
    for value in value
        .and_then(|value| value.get("commands"))
        .and_then(Value::array)
        .into_iter()
        .flatten()
    {
        if let Some(name) = value.get("name").and_then(Value::string) {
            let name = format!("/{name}");
            if !names.contains(&name) {
                names.push(name);
            }
        }
    }
    names
}

pub fn usage(value: Option<Value<'_>>) -> Option<String> {
    let value = value.filter(|value| value.kind() == dispatch_helper4_core::json::Kind::Object)?;
    let mut fields = Vec::new();
    if let Some(tokens) = value.get("tokens") {
        fields.push((
            "last_token_usage",
            Data::Object(vec![("total_tokens", Data::Value(tokens))]),
        ));
    }
    if let Some(window) = value.get("contextWindow") {
        fields.push(("model_context_window", Data::Value(window)));
    }
    if fields.is_empty() {
        return None;
    }
    let bytes =
        dispatch_helper4_core::json::write(&Data::Object(vec![("info", Data::Object(fields))]))
            .ok()?;
    String::from_utf8(bytes).ok()
}
