//! Proposed Harness operation (core review, arch.md): run one composer command natively and
//! resolve with the result the old app showed; c1654cc Dispatch/Chat/ChatCommands.swift.
use super::Codex;
use crate::channel::failure;
use dispatch_helper_core::{
    api::*,
    json::{Data, Value},
};

/// The one command a conversation may have in flight; ChatCommands.swift:302.
pub(crate) struct Pending {
    binding: Binding,
    /// Shell command awaiting its user-shell execution; None while /stop is in flight.
    shell: Option<String>,
    /// The native request was acknowledged, so a missing channel now means the conversation is lost.
    sent: bool,
    done: Done<Outcome>,
}

pub(crate) type Commands = Vec<Pending>;

#[derive(Clone)]
enum Editor { Ask, Open(String), End(String), Clear(String), Type(String), Confirm(String) }

/// A terminal report belongs to this send, never to an older copy on screen.
pub(crate) struct Reading {
    text: String,
    title: &'static str,
    before: Option<String>,
    connected: Option<bool>,
    status: bool,
    editor: Option<Editor>,
    original: Option<String>,
}

impl Reading {
    pub(crate) fn new(text: &str) -> Option<Self> {
        let text = text.trim();
        let title = match text {
            "/status" => "Session status",
            "/fork" => "Conversation forked",
            "/clear" | "/new" => "New conversation",
            "/plan" => "Plan mode",
            "/fast" => "Fast mode",
            "/pwd" => "Working directory",
            "/ps" => "Background terminals",
            "/mcp" => "MCP tools",
            "/goal" | "/goal edit" | "/goal clear" => "Goal",
            "/recap" => "Recap",
            "/rename" => "Conversation renamed",
            text if text.starts_with("/rename ") => "Conversation renamed",
            _ => return None,
        };
        Some(Self {
            text: text.into(),
            title,
            before: None,
            connected: None,
            status: false,
            editor: (text == "/goal edit").then_some(Editor::Ask),
            original: None,
        })
    }

    pub(crate) fn replaces(&self) -> bool { matches!(self.text.as_str(), "/fork" | "/clear" | "/new") && self.before.is_some() }

    pub(crate) fn answer(&mut self, answers: &[(String, Answer)]) -> Result<Sent, Error> {
        let [(key, Answer::Text(text))] = answers else {
            return Err(failure("question", "Enter a conversation name."));
        };
        let text = text.trim();
        if self.text == "/goal edit" && matches!(self.editor, Some(Editor::Ask)) {
            if key != "goal" || text.is_empty() || text.chars().count() > 4000 || text.chars().any(char::is_control) {
                return Err(failure("question", "Enter a single-line goal objective."));
            }
            self.editor = Some(Editor::Open(text.to_owned()));
            return Ok(Sent::Keys(Vec::new()));
        }
        if self.text != "/rename"
            || key != "rename"
            || text.is_empty()
            || text.chars().count() > 4000
            || text.chars().any(char::is_control)
        {
            return Err(failure("question", "Enter a valid conversation name."));
        }
        self.text = format!("/rename {text}");
        Ok(Sent::Keys(Vec::new()))
    }

    pub(crate) fn step(&mut self, binding: &Binding, screen: &Screen, goal: Option<&str>, session: Option<&str>) -> Step {
        // A native replacement moves the channel before its rendered result arrives.
        let connected = *self.connected.get_or_insert(session.is_some());
        if let Some(editor) = self.editor.clone() {
            let objective = goal.and_then(|text| dispatch_helper_core::json::Json::parse(text.as_bytes()).ok())
                .and_then(|document| document.root().get("objective").and_then(Value::string).map(str::to_owned));
            return match editor {
                Editor::Ask => {
                    let Some(objective) = objective else { return Step::Fail(failure("goal", "No goal to edit.")); };
                    self.original = Some(objective);
                    Step::Ask(Interaction {
                        key: None, id: format!("command:{}", binding.session), turn: None, record: None,
                        approval: false, blocking: true,
                        questions: vec![Question { id: "goal".into(), header: "Edit goal".into(),
                            text: "Goal objective".into(), custom: true, secret: false, multiple: false,
                            options: Vec::new(), blocks: Vec::new() }],
                    })
                }
                Editor::Open(value) => {
                    self.editor = Some(Editor::End(value));
                    Step::Keys(vec![Input::Paste("/goal edit".into()), Input::Key(Key::Enter)])
                }
                Editor::End(value) | Editor::Clear(value) => {
                    let Some(current) = crate::menu::editor(&screen.text) else { return Step::Wait; };
                    if Some(&current) != self.original.as_ref() {
                        return Step::Fail(failure("goal", "The goal editor changed. Continue in Terminal."));
                    }
                    let end = matches!(self.editor, Some(Editor::End(_)));
                    self.editor = Some(if end { Editor::Clear(value) } else { Editor::Type(value) });
                    Step::Keys(vec![Input::Raw(if end { b"\x1b[F".to_vec() } else { vec![0x15] })])
                }
                Editor::Type(value) => {
                    if crate::menu::editor(&screen.text).as_deref() != Some("") { return Step::Wait; }
                    self.editor = Some(Editor::Confirm(value.clone()));
                    Step::Keys(vec![Input::Paste(value), Input::Key(Key::Enter)])
                }
                Editor::Confirm(value) if objective.as_deref() == Some(value.as_str()) => Step::Done(Menu {
                    result: Some((self.title.into(), value)), ..Menu::default()
                }),
                Editor::Confirm(_) => Step::Wait,
            };
        }
        if self.text == "/rename" {
            return Step::Ask(Interaction {
                key: None,
                id: format!("command:{}", binding.session),
                turn: None,
                record: None,
                approval: false,
                blocking: true,
                questions: vec![Question {
                    id: "rename".into(),
                    header: "Rename conversation".into(),
                    text: "Conversation name".into(),
                    custom: true,
                    secret: false,
                    multiple: false,
                    options: Vec::new(),
                    blocks: Vec::new(),
                }],
            });
        }
        let Some(before) = &self.before else {
            self.before = Some(screen.text.clone());
            return Step::Keys(vec![
                Input::Paste(self.text.clone()),
                Input::Key(Key::Enter),
            ]);
        };
        if screen.text == *before {
            return Step::Wait;
        }
        if (self.text.starts_with("/rename ") || self.text == "/plan") && !self.status {
            self.status = true;
            return Step::Keys(vec![Input::Paste("/status".into()), Input::Key(Key::Enter)]);
        }
        if self.replaces() && !connected && !self.status {
            let ready = if self.text == "/fork" { crate::menu::forked(before, &screen.text) }
                else { screen.text.lines().rev().map(str::trim).find_map(|line| line.strip_prefix('›'))
                    .is_some_and(|text| !text.trim().starts_with('/')) };
            if !ready { return Step::Wait; }
            self.status = true;
            return Step::Keys(vec![Input::Paste("/status".into()), Input::Key(Key::Enter)]);
        }
        let result = if self.replaces() {
            let confirmed = if connected {
                session.is_some_and(|session| session != binding.session)
                    && if self.text == "/fork" { crate::menu::forked(before, &screen.text) }
                    else { screen.text.lines().rev().map(str::trim).find_map(|line| line.strip_prefix('›'))
                        .is_some_and(|text| !text.trim().starts_with('/')) }
            } else { crate::menu::status(&screen.text).is_some_and(|status| status.session != binding.session) };
            confirmed.then(|| if self.text == "/fork" {
                "Chat now follows the fork. Earlier messages stay in the original conversation.".into()
            } else { "Ready for a new message.".into() })
        } else { match self.text.as_str() {
            "/plan" => crate::menu::status(&screen.text)
                .filter(|status| status.session == binding.session && status.mode.as_deref() == Some("plan"))
                .map(|_| "Plan mode is on.".into()),
            "/status" => crate::menu::status(&screen.text)
                .filter(|status| binding.session.is_empty() || status.session == binding.session)
                .map(|status| status.text),
            text if text.starts_with("/rename ") => crate::menu::status(&screen.text)
                .filter(|status| {
                    (binding.session.is_empty() || status.session == binding.session)
                        && status.name.as_deref() == text.strip_prefix("/rename ")
                })
                .and_then(|status| status.name),
            "/fast" => screen.text.lines().rev().find_map(|line| {
                let line = line.trim();
                let previous = before
                    .lines()
                    .rev()
                    .map(str::trim)
                    .find(|line| line.starts_with("• Service tier set to "));
                if previous == Some(line)
                    && screen.text.matches(line).count() <= before.matches(line).count()
                {
                    return None;
                }
                match line.strip_prefix("• Service tier set to ")? {
                    "priority" => Some("Fast mode is on.".into()),
                    "default" => Some("Fast mode is off.".into()),
                    _ => None,
                }
            }),
            text => crate::menu::report(text, before, &screen.text),
        }};
        match result {
            Some(text) => Step::Done(Menu {
                result: Some((self.title.into(), text)),
                ..Menu::default()
            }),
            None => Step::Wait,
        }
    }
}

/// The command a native execution ran; c1654cc ChatCommands.swift:233-238. Codex 0.159.2
/// reports user-shell commands as one quoted login-shell string (`/bin/bash -lc "..."`), so a
/// string is split into shell words before the same `-c`/`-lc` rule applies.
fn shell(value: Value<'_>) -> Option<String> {
    let arguments = match value.string() {
        Some(command) => words(command).unwrap_or_else(|| vec![command.to_owned()]),
        None => value
            .array()?
            .map(|argument| argument.string().map(str::to_owned))
            .collect::<Option<Vec<_>>>()?,
    };
    match &arguments[..] {
        [] => None,
        [.., flag, command] if arguments.len() >= 3 && matches!(flag.as_str(), "-c" | "-lc") => {
            Some(command.clone())
        }
        _ if value.string().is_some() => value.string().map(str::to_owned),
        _ => Some(arguments.join(" ")),
    }
}

/// POSIX shell words: whitespace separates, single quotes are literal, and a backslash escapes
/// the next character (inside double quotes only before backslash, quote, dollar, backtick or
/// newline). None while a quote is still open.
pub(crate) fn words(text: &str) -> Option<Vec<String>> {
    let (mut words, mut word, mut quoted) = (Vec::new(), None::<String>, None::<char>);
    let mut characters = text.chars();
    for _ in 0..=text.len() {
        let Some(character) = characters.next() else {
            break;
        };
        match (quoted, character) {
            (Some('\''), '\'') | (Some('"'), '"') => quoted = None,
            (Some('\''), _) => word.get_or_insert_default().push(character),
            (Some(_), '\\') | (None, '\\') => {
                let next = characters.next()?;
                let word = word.get_or_insert_default();
                if quoted.is_some() && !matches!(next, '\\' | '"' | '$' | '`' | '\n') {
                    word.push('\\');
                }
                word.push(next);
            }
            (Some(_), _) => word.get_or_insert_default().push(character),
            (None, '\'' | '"') => {
                quoted = Some(character);
                word.get_or_insert_default();
            }
            (None, _) if character.is_whitespace() => words.extend(word.take()),
            (None, _) => word.get_or_insert_default().push(character),
        }
    }
    quoted
        .is_none()
        .then(|| words.into_iter().chain(word).collect())
}

impl Codex {

    /// `!command` runs through thread/shellCommand and finishes with its user-shell execution;
    /// `/stop` asks Codex to stop background terminals. One command per conversation; other
    /// commands keep the terminal path. c1654cc ChatCommands.swift:10-15, 292-372, 505-507.
    pub fn command(&mut self, io: &mut dyn Io, binding: &Binding, text: &str, done: Done<Outcome>) {
        let text = text.trim();
        // A known command given arguments it does not take never becomes a prompt; c1654cc
        // ChatCommands.swift:5-34, ChatCoordinator.swift:1802-1806.
        if text
            .split_once(char::is_whitespace)
            .is_some_and(|(name, _)| {
                [
                    "/fast", "/compact", "/init", "/stop", "/copy", "/model", "/status",
                ]
                .contains(&name)
            })
        {
            let message = "This command does not accept those arguments. Use its listed form.";
            deferred(done)(io, Err(failure("command_arguments", message)));
            return;
        }
        // A provisional chat learns its session from the /status screen it asked for (core P2).
        if binding.session.is_empty() && text == "/status" {
            let key = (binding.process.pid, binding.process.start);
            self.statuses.borrow_mut().entry(key).or_default();
        }
        if crate::menu::command(text).is_some() {
            let key = (binding.process.pid, binding.process.start);
            self.screens.remove(&key);
            if let Some(reading) = Reading::new(text) { self.reading.insert(key, reading); }
            deferred(done)(io, Err(failure("menu", "")));
            return;
        }
        let shell = text
            .strip_prefix('!')
            .filter(|rest| !rest.is_empty() && !rest.starts_with('!'))
            .map(|command| command.trim().to_owned());
        let (method, params) = match &shell {
            Some(command) => (
                "thread/shellCommand",
                Data::Object(vec![
                    ("threadId", Data::String(&binding.session)),
                    ("command", Data::String(command)),
                ]),
            ),
            None if text == "/stop" => (
                "thread/backgroundTerminals/clean",
                Data::Object(vec![("threadId", Data::String(&binding.session))]),
            ),
            None => {
                deferred(done)(
                    io,
                    Err(failure("unsupported", "Run this command in the terminal.")),
                );
                return;
            }
        };
        if self
            .commands
            .borrow()
            .iter()
            .any(|pending| pending.binding.session == binding.session)
        {
            deferred(done)(
                io,
                Err(failure("busy", "Another command is still running.")),
            );
            return;
        }
        let stop = shell.is_none();
        self.commands.borrow_mut().push(Pending {
            binding: binding.clone(),
            shell: shell.clone(),
            sent: false,
            done,
        });
        let commands = self.commands.clone();
        let session = binding.session.clone();
        self.request(
            io,
            binding,
            method,
            params,
            Box::new(move |io, result| {
                let mut commands = commands.borrow_mut();
                let Some(index) = commands
                    .iter()
                    .position(|pending| pending.binding.session == session)
                else {
                    return;
                };
                match result {
                    Err(error) => deferred(commands.remove(index).done)(io, Err(error)),
                    Ok(_) if stop => {
                        deferred(commands.remove(index).done)(io, Ok(Outcome::Stopping))
                    }
                    Ok(_) => commands[index].sent = true,
                }
            }),
        );
    }

    /// Pending commands of conversations that are gone finish as changed; ChatCommands.swift:362-368.
    pub(super) fn lost(&self, io: &mut dyn Io, gone: impl Fn(&Pending) -> bool) {
        let mut commands = self.commands.borrow_mut();
        let (lost, kept): (Vec<_>, Vec<_>) = commands.drain(..).partition(|pending| gone(pending));
        *commands = kept;
        for pending in lost {
            deferred(pending.done)(
                io,
                Err(failure("changed", "The agent conversation changed.")),
            );
        }
    }

    /// After a native event: an acknowledged command whose conversation lost its channel is lost.
    pub(super) fn retire(&self, io: &mut dyn Io) {
        let gone = |pending: &Pending| {
            pending.sent
                && self.channel(&pending.binding).is_err()
                && !self.main.bound(&pending.binding)
        };
        self.lost(io, gone);
    }

    /// The conversation's process exited.
    pub(super) fn exited_commands(&self, io: &mut dyn Io, process: &Process) {
        self.lost(io, |pending| {
            pending.binding.process.pid == process.pid
                && pending.binding.process.start == process.start
        });
    }

    /// A completed native user-shell execution finishes the pending command it ran.
    pub(super) fn executed(&self, io: &mut dyn Io, session: &str, item: Value<'_>) {
        let source = item.get("source").and_then(Value::string).unwrap_or("");
        if item.get("status").and_then(Value::string) == Some("inProgress")
            || source.to_lowercase().replace('_', "") != "usershell"
        {
            return;
        }
        let (Some(command), Some(record)) = (
            item.get("command").and_then(shell),
            crate::tools::item(item, false),
        ) else {
            return;
        };
        let mut commands = self.commands.borrow_mut();
        let Some(index) = commands.iter().position(|pending| {
            pending.binding.session == session && pending.shell.as_deref() == Some(command.as_str())
        }) else {
            return;
        };
        deferred(commands.remove(index).done)(
            io,
            Ok(Outcome::Shell {
                command,
                output: record.output,
                exit_code: record.exit_code,
            }),
        );
    }
}
