//! Async and RPC questions share validation; the original transport chooses the answer.
use dispatch_helper4_core::{
    api::{Answer, Block, Choice, Interaction, Question},
    json::{self, Data, Json, Kind, Value},
    rpc::{Id, Message},
};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Form {
    pub thread: String,
    pub turn: String,
    pub interaction: Interaction,
}

fn form(params: Value<'_>, key: String, limit: usize) -> Option<Form> {
    let bytes = params.write().ok()?;
    if bytes.len() + bytes.iter().filter(|&&byte| byte == b'/').count() > 131_072 {
        return None;
    }
    let thread = params.get("threadId")?.string()?;
    let turn = params.get("turnId")?.string()?;
    if thread.is_empty() || turn.is_empty() || params.get("itemId")?.string()?.is_empty() {
        return None;
    }
    let mut seen = BTreeSet::new();
    let questions = params
        .get("questions")?
        .array()?
        .take(limit + 1)
        .map(|value| {
            let id = value.get("id")?.string()?;
            let text = value.get("question")?.string()?;
            if id.is_empty() || !seen.insert(id) || text.is_empty() || text.len() > 16_384 {
                return None;
            }
            let mut labels = BTreeSet::new();
            let options = match value.get("options").filter(|v| v.kind() != Kind::Null) {
                None => Vec::new(),
                Some(options) => options
                    .array()?
                    .take(21)
                    .map(|v| {
                        let label = v.get("label")?.string()?;
                        if label.is_empty() || !labels.insert(label) {
                            return None;
                        }
                        Some(Choice {
                            id: label.into(),
                            label: label.into(),
                            detail: Some(v.get("description")?.string()?.into()),
                        })
                    })
                    .collect::<Option<Vec<_>>>()?,
            };
            if options.len() > 20 {
                return None;
            }
            Some(Question {
                blocks: Vec::new(),
                id: id.into(),
                header: value.get("header")?.string()?.into(),
                text: text.into(),
                secret: value.get("isSecret")?.boolean()?,
                multiple: false,
                custom: value.get("isOther")?.boolean()? || options.is_empty(),
                options,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    if questions.is_empty() || questions.len() > limit {
        return None;
    }
    let blocking = match params.get("isBlocking").filter(|v| v.kind() != Kind::Null) {
        Some(value) => value.boolean()?,
        None => true,
    };
    Some(Form {
        thread: thread.into(),
        turn: turn.into(),
        interaction: Interaction {
            key: None,
            turn: Some(turn.into()),
            record: params
                .get("itemId")
                .and_then(Value::string)
                .map(crate::tools::record),
            id: key,
            approval: false,
            blocking,
            questions,
        },
    })
}

pub fn read(params: Value<'_>) -> Option<Form> {
    let item = params.get("item")?;
    if item.get("type")?.string()? != "agentMessage" {
        return None;
    }
    let id = item.get("id")?.string()?;
    if id.is_empty() {
        return None;
    }
    let rows: Vec<_> = item.get("questions")?.array()?.take(21).collect();
    if rows.is_empty() || rows.len() > 20 {
        return None;
    }
    let names: Vec<_> = (0..rows.len())
        .map(|i| (i.to_string(), format!("Question {}", i + 1)))
        .collect();
    let questions = rows
        .iter()
        .zip(&names)
        .map(|(row, (key, header))| {
            let title = row.get("title")?.string()?;
            if title.trim().is_empty() {
                return None;
            }
            let mut fields = vec![
                ("id", Data::String(key)),
                ("header", Data::String(header)),
                ("question", Data::String(title)),
                ("isOther", Data::Bool(true)),
                ("isSecret", Data::Bool(false)),
            ];
            if let Some(options) = row.get("options").filter(|v| v.kind() != Kind::Null) {
                let options = options
                    .array()?
                    .take(21)
                    .map(|option| {
                        Some(Data::Object(vec![
                            ("label", Data::String(option.string()?)),
                            ("description", Data::String("")),
                        ]))
                    })
                    .collect::<Option<Vec<_>>>()?;
                fields.push(("options", Data::Array(options)));
            }
            Some(Data::Object(fields))
        })
        .collect::<Option<Vec<_>>>()?;
    let bytes = json::write(&Data::Object(vec![
        ("threadId", Data::Value(params.get("threadId")?)),
        ("turnId", Data::Value(params.get("turnId")?)),
        ("itemId", Data::String(id)),
        ("isBlocking", Data::Bool(false)),
        ("questions", Data::Array(questions)),
    ]))
    .ok()?;
    let normalized = Json::parse(&bytes).ok()?;
    form(normalized.root(), id.into(), 20)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub wire: Id,
    pub item: String,
    pub form: Form,
}

/// Positional ids that restored app-server items can carry; c1654cc ChatAsyncQuestion.swift:11-13.
fn snapshot(id: &str) -> bool {
    id.strip_prefix("item-").is_some_and(|number| {
        !number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit())
    })
}

fn key(id: &Id) -> String {
    match id {
        Id::Integer(id) => format!("n:{id}"),
        Id::String(id) => format!("s:{id}"),
    }
}

pub fn rpc(message: Value<'_>) -> Option<Request> {
    let Message::Request {
        id,
        method: "item/tool/requestUserInput",
        params: Some(params),
    } = Message::read(message).ok()?
    else {
        return None;
    };
    let key = key(&id);
    Some(Request {
        item: params.get("itemId")?.string()?.into(),
        form: form(params, key, 3)?,
        wire: id,
    })
}

/// One session's outstanding requests; async questions survive their producing turn.
#[derive(Default)]
pub struct Pending {
    pub forms: BTreeMap<String, (Form, Option<Request>)>,
    seen: BTreeSet<(String, String)>,
    /// An owned side conversation answers its own approvals; the main TUI answers its own.
    pub side: bool,
    /// Replies to write now (declined approvals); the owner drains them to the channel.
    pub outbox: Vec<Vec<u8>>,
    /// Why Dispatch answered a side request itself; the owner shows it (old side `failure`).
    pub notice: Option<String>,
    /// The side's running turn; approvals belong only to it.
    turn: Option<String>,
    /// Latest file changes per fileChange item, for file approvals (cleared per turn).
    changes: BTreeMap<String, Vec<u8>>,
}

/// Native approval reply: accept or decline; c1654cc ChatSideConversation.swift:414-421.
fn decision(wire: &Id, allow: bool) -> Vec<u8> {
    let id = match wire {
        Id::Integer(id) => Data::Signed(*id),
        Id::String(id) => Data::String(id),
    };
    json::write(&Data::Object(vec![
        ("id", id),
        (
            "result",
            Data::Object(vec![(
                "decision",
                Data::String(if allow { "accept" } else { "decline" }),
            )]),
        ),
    ]))
    .unwrap_or_default()
}

impl Pending {
    pub fn read(&mut self, root: Value<'_>) -> Vec<Interaction> {
        let Some(params) = root.get("params") else {
            return Vec::new();
        };
        let method = root.get("method").and_then(Value::string).unwrap_or("");
        if self.side
            && let Some(opened) = self.approval(root, params, method)
        {
            return opened;
        }
        let request = rpc(root);
        let form = request
            .as_ref()
            .map(|request| request.form.clone())
            .or_else(|| {
                matches!(method, "item/started" | "item/completed")
                    .then(|| read(params))
                    .flatten()
            });
        if let Some(form) = form {
            let id = form.interaction.id.clone();
            if !self.seen.insert((form.turn.clone(), id.clone())) {
                return Vec::new();
            }
            // One async question under a live id and a positional snapshot id stays one form,
            // keeping the first-seen id (arch.md: async question aliases; ChatCoordinator.swift:357-381).
            if request.is_none()
                && self.forms.iter().any(|(other, (existing, request))| {
                    request.is_none()
                        && existing.turn == form.turn
                        && existing.interaction.questions == form.interaction.questions
                        && (snapshot(other) || snapshot(&id))
                })
            {
                return Vec::new();
            }
            let interaction = form.interaction.clone();
            self.forms.insert(id, (form, request));
            return vec![interaction];
        }
        // A side request no form answers gets the old error reply and its reason shown
        // (ChatSideConversation.swift:244-247,270-271); the main TUI answers its own.
        if self.side
            && let Ok(Message::Request { id, .. }) = Message::read(root)
        {
            let (code, message, notice) = match method {
                "item/tool/requestUserInput" => (
                    -32602,
                    "Unsupported side question format.",
                    "Codex sent a question this version cannot display.",
                ),
                _ => (
                    -32601,
                    "This side conversation cannot answer interactive tool requests.",
                    "The side agent needs an interactive permission or answer.",
                ),
            };
            let id = match &id {
                Id::Integer(id) => Data::Signed(*id),
                Id::String(id) => Data::String(id),
            };
            let error = Data::Object(vec![
                ("code", Data::Signed(code)),
                ("message", Data::String(message)),
            ]);
            if let Ok(reply) = json::write(&Data::Object(vec![("id", id), ("error", error)])) {
                self.outbox.push(reply);
            }
            self.notice = Some(notice.into());
            return Vec::new();
        }
        let resolved = if method == "serverRequest/resolved" {
            params.get("requestId").and_then(|id| {
                id.signed()
                    .map(Id::Integer)
                    .or_else(|| id.string().map(|id| Id::String(id.into())))
                    .map(|id| key(&id))
            })
        } else {
            None
        };
        let turn = if method == "turn/completed" {
            params
                .get("turn")
                .and_then(|turn| turn.get("id"))
                .and_then(Value::string)
        } else {
            None
        };
        let ids = self
            .forms
            .iter()
            .filter(|(id, (form, request))| {
                resolved.as_ref() == Some(id) || (request.is_some() && turn == Some(&form.turn))
            })
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        self.clear(ids)
    }

    fn clear(&mut self, ids: Vec<String>) -> Vec<Interaction> {
        ids.into_iter()
            .map(|id| {
                let mut interaction = self.forms.remove(&id).unwrap().0.interaction;
                interaction.questions.clear();
                interaction
            })
            .collect()
    }

    /// Side approvals: remember file changes per item and the running turn, show one approval of
    /// that turn at a time, decline anything else; c1654cc ChatSideConversation.swift:41-85,252-310.
    /// None lets ordinary processing continue.
    fn approval(
        &mut self,
        root: Value<'_>,
        params: Value<'_>,
        method: &str,
    ) -> Option<Vec<Interaction>> {
        let item = params.get("item");
        match method {
            "turn/started" => {
                self.turn = params
                    .get("turn")
                    .and_then(|turn| turn.get("id"))
                    .and_then(Value::string)
                    .map(str::to_owned);
                return None;
            }
            "turn/completed" => {
                self.turn = None;
                self.changes.clear();
                return None;
            }
            "item/started" | "item/completed" | "item/fileChange/patchUpdated" => {
                let (id, changes) = match item {
                    Some(item)
                        if item.get("type").and_then(Value::string) == Some("fileChange") =>
                    {
                        (item.get("id"), item.get("changes"))
                    }
                    _ => (params.get("itemId"), params.get("changes")),
                };
                if (method == "item/fileChange/patchUpdated" || item.is_some())
                    && let (Some(id), Some(changes)) = (
                        id.and_then(Value::string),
                        changes.filter(|value| value.array().is_some()),
                    )
                    && let Ok(bytes) = changes.write()
                {
                    self.changes.insert(id.into(), bytes);
                }
                return None;
            }
            "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {}
            _ => return None,
        }
        let Ok(Message::Request { id: wire, .. }) = Message::read(root) else {
            return None;
        };
        // c1654cc ChatSideConversation.swift:255-265: declined, and the reason shown.
        let decline = |pending: &mut Self, notice: &str| {
            pending.outbox.push(decision(&wire, false));
            pending.notice = Some(notice.into());
            Some(Vec::new())
        };
        let unsafe_ = "The side agent requested an operation Dispatch could not display safely, so it was denied.";
        let turn = params.get("turnId").and_then(Value::string);
        if self
            .forms
            .values()
            .any(|(form, _)| form.interaction.approval)
        {
            return decline(
                self,
                "A second side permission request was denied while another is pending.",
            );
        }
        if turn.is_none() || turn != self.turn.as_deref() {
            return decline(self, unsafe_);
        }
        let item = params.get("itemId").and_then(Value::string).unwrap_or("");
        let changes = self
            .changes
            .get(item)
            .and_then(|bytes| Json::parse(bytes).ok());
        let (title, operation) = if method == "item/commandExecution/requestApproval" {
            let command = params.get("command").and_then(Value::string).unwrap_or("");
            if command.trim().is_empty() {
                return decline(self, unsafe_);
            }
            ("Allow command?", Data::Value(params))
        } else {
            let Some(changes) = changes.as_ref().filter(|changes| {
                changes
                    .root()
                    .array()
                    .is_some_and(|mut items| items.next().is_some())
            }) else {
                return decline(self, unsafe_);
            };
            (
                "Allow file changes?",
                Data::Object(vec![
                    ("changes", Data::Value(changes.root())),
                    ("request", Data::Value(params)),
                ]),
            )
        };
        // The complete operation is shown or the request is declined (old bound 32768 Characters;
        // Unicode scalars never undercount it, so this only errs toward declining).
        let operation = json::write_with(&operation, json::Format::PrettySorted)
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .filter(|text| !text.is_empty() && text.chars().count() <= 32_768);
        let Some(operation) = operation else {
            return decline(self, unsafe_);
        };
        let thread = params
            .get("threadId")
            .and_then(Value::string)
            .unwrap_or("")
            .to_owned();
        let text = |name| params.get(name).and_then(Value::string);
        let interaction = Interaction {
            key: None,
            turn: text("turnId").map(str::to_owned),
            record: text("itemId").map(crate::tools::record),
            id: key(&wire),
            approval: true,
            blocking: true,
            questions: vec![Question {
                id: "approval".into(),
                header: title.into(),
                // ChatSideConversation.swift:79-85: the complete operation as JSON code.
                blocks: vec![Block::Code {
                    language: "json".into(),
                    text: operation.clone(),
                }],
                text: operation,
                secret: false,
                options: ["Allow", "Deny"]
                    .map(|label| Choice {
                        id: label.into(),
                        label: label.into(),
                        detail: None,
                    })
                    .to_vec(),
                multiple: false,
                custom: false,
            }],
        };
        let form = Form {
            thread,
            turn: turn.unwrap_or("").to_owned(),
            interaction: interaction.clone(),
        };
        if !self
            .seen
            .insert((form.turn.clone(), interaction.id.clone()))
        {
            return Some(Vec::new());
        }
        self.forms.insert(
            interaction.id.clone(),
            (
                form.clone(),
                Some(Request {
                    wire,
                    item: item.into(),
                    form,
                }),
            ),
        );
        Some(vec![interaction])
    }

    /// Reply to a pending request: an approval accepts only choice 0 (Allow) while its turn is
    /// still running (ChatSideConversation.swift:407-412); questions keep their native answers.
    pub fn reply(&self, request: &Request, answers: &[(String, Answer)]) -> Option<Vec<u8>> {
        if !request.form.interaction.approval {
            return reply(request, answers);
        }
        let allow = answers
            .iter()
            .any(|(id, answer)| id == "approval" && *answer == Answer::Options(vec![0]))
            && self.turn.as_deref() == Some(request.form.turn.as_str());
        Some(decision(&request.wire, allow))
    }

    /// Resume snapshot turns: questions not followed by user input in their turn open once;
    /// c1654cc CodexPatchConnection.swift:466-475.
    pub fn resumed(&mut self, turns: Value<'_>, session: &str) -> Vec<Interaction> {
        let mut opened = Vec::new();
        for turn in turns.array().into_iter().flatten() {
            let (Some(id), Some(items)) = (
                turn.get("id").and_then(Value::string),
                turn.get("items").and_then(Value::array),
            ) else {
                continue;
            };
            let items: Vec<_> = items.collect();
            for (index, item) in items.iter().enumerate() {
                let Some(item_id) = item
                    .get("id")
                    .and_then(Value::string)
                    .filter(|_| item.get("type").and_then(Value::string) == Some("agentMessage"))
                    .filter(|_| {
                        item.get("questions")
                            .and_then(Value::array)
                            .is_some_and(|mut questions| questions.next().is_some())
                    })
                else {
                    continue;
                };
                if items[index + 1..]
                    .iter()
                    .any(|later| later.get("type").and_then(Value::string) == Some("userMessage"))
                {
                    self.seen.insert((id.to_owned(), item_id.to_owned()));
                    continue;
                }
                let envelope = Data::Object(vec![
                    ("method", Data::String("item/completed")),
                    (
                        "params",
                        Data::Object(vec![
                            ("threadId", Data::String(session)),
                            ("turnId", Data::String(id)),
                            ("item", Data::Value(*item)),
                        ]),
                    ),
                ]);
                if let Ok(document) = json::write(&envelope).and_then(|bytes| Json::parse(&bytes)) {
                    opened.extend(self.read(document.root()));
                }
            }
        }
        opened
    }

    /// A chat opens: every open form, with forms recovered from its recent page opened once and
    /// forms that page closed closed. The chat may not have observed forms opened before it
    /// (run 138b slice 29268: the question came before the chat of the newly bound session).
    /// A chat opening: the recovered forms merge, and every open form is delivered again.
    pub fn adopt(&mut self, recovered: Pending) -> Vec<Interaction> {
        let mut changed = self.merge(recovered);
        for (id, (form, _)) in &self.forms {
            if !changed.iter().any(|interaction| &interaction.id == id) {
                changed.push(form.interaction.clone());
            }
        }
        changed
    }

    /// Forms recovered from rollout lines: new ones open, ones answered there close.
    pub fn merge(&mut self, recovered: Pending) -> Vec<Interaction> {
        let mut changed = Vec::new();
        let mut closed = Vec::new();
        for key in recovered.seen {
            let id = key.1.clone();
            let new = self.seen.insert(key);
            match recovered.forms.get(&id) {
                Some((form, _)) if new => {
                    changed.push(form.interaction.clone());
                    self.forms.insert(id, (form.clone(), None));
                }
                Some(_) => {}
                None if self
                    .forms
                    .get(&id)
                    .is_some_and(|(_, request)| request.is_none()) =>
                {
                    closed.push(id)
                }
                None => {}
            }
        }
        changed.extend(self.clear(closed));
        changed
    }

    /// A recent user message answers async forms that it quotes; c1654cc ChatCoordinator.swift:1134-1144.
    pub fn answered(&mut self, text: &str) -> Vec<Interaction> {
        let ids = self
            .forms
            .iter()
            .filter(|(_, (form, request))| {
                let questions = &form.interaction.questions;
                request.is_none()
                    && (questions
                        .iter()
                        .all(|question| text.contains(&format!("> {}", question.text)))
                        || text.starts_with("Answers to your questions:\n")
                            && questions
                                .iter()
                                .all(|question| text.contains(&question.text)))
            })
            .map(|(id, _)| id.clone())
            .collect();
        self.clear(ids)
    }

    /// One recent-page rollout line: completed async questions open, user messages answer them;
    /// c1654cc TranscriptReader.swift:151-160, ChatCoordinator.swift:1090-1091.
    pub fn rollout(&mut self, root: Value<'_>, session: &str) -> Vec<Interaction> {
        let Some(payload) = root
            .get("payload")
            .filter(|_| root.get("type").and_then(Value::string) == Some("event_msg"))
        else {
            return Vec::new();
        };
        // Every user message record answers, whichever line carries it (the old app applied
        // its user items, CodexMainThreadTests.swift:107-143).
        if payload.get("type").and_then(Value::string) == Some("user_message") {
            let text = payload.get("message").and_then(Value::string);
            return self.answered(text.unwrap_or(""));
        }
        let Some(item) = payload
            .get("item")
            .filter(|_| payload.get("type").and_then(Value::string) == Some("item_completed"))
        else {
            return Vec::new();
        };
        match item.get("type").and_then(Value::string) {
            Some("UserMessage") => {
                let text = crate::history::content(item.get("content"));
                self.answered(&text)
            }
            Some("AgentMessage")
                if payload.get("thread_id").and_then(Value::string) == Some(session) =>
            {
                let turn = crate::history::turn(payload).unwrap_or("history");
                let (Some(id), Some(questions)) = (
                    item.get("id").and_then(Value::string),
                    item.get("questions")
                        .filter(|value| value.kind() == Kind::Array),
                ) else {
                    return Vec::new();
                };
                let envelope = Data::Object(vec![
                    ("method", Data::String("item/completed")),
                    (
                        "params",
                        Data::Object(vec![
                            ("threadId", Data::String(session)),
                            ("turnId", Data::String(turn)),
                            (
                                "item",
                                Data::Object(vec![
                                    ("type", Data::String("agentMessage")),
                                    ("id", Data::String(id)),
                                    ("questions", Data::Value(questions)),
                                ]),
                            ),
                        ]),
                    ),
                ]);
                json::write(&envelope)
                    .and_then(|bytes| Json::parse(&bytes))
                    .map(|document| self.read(document.root()))
                    .unwrap_or_default()
            }
            _ => Vec::new(),
        }
    }
}

fn selected<'a>(question: &'a Question, value: &'a Answer) -> Option<&'a str> {
    match value {
        Answer::Skip => Some("Skipped"),
        Answer::Text(text)
            if question.custom && !text.trim().is_empty() && text.len() <= 16_384 =>
        {
            Some(text)
        }
        Answer::Options(indices) if indices.len() == 1 => {
            Some(&question.options.get(indices[0])?.label)
        }
        _ => None,
    }
}

pub fn answer(form: &Form, answers: &[(String, Answer)]) -> Option<String> {
    let rows = form
        .interaction
        .questions
        .iter()
        .map(|question| {
            let value = &answers.iter().find(|(id, _)| *id == question.id)?.1;
            Some(format!("{}\n{}", question.text, selected(question, value)?))
        })
        .collect::<Option<Vec<_>>>()?;
    Some("Answers to your questions:\n\n".to_owned() + &rows.join("\n\n"))
}

pub fn reply(request: &Request, answers: &[(String, Answer)]) -> Option<Vec<u8>> {
    let rows = request
        .form
        .interaction
        .questions
        .iter()
        .map(|question| {
            let answer = &answers.iter().find(|(id, _)| *id == question.id)?.1;
            let values = if matches!(answer, Answer::Skip) {
                Vec::new()
            } else {
                vec![Data::String(selected(question, answer)?)]
            };
            Some((
                question.id.as_str(),
                Data::Object(vec![("answers", Data::Array(values))]),
            ))
        })
        .collect::<Option<Vec<_>>>()?;
    let id = match &request.wire {
        Id::Integer(id) => Data::Signed(*id),
        Id::String(id) => Data::String(id),
    };
    json::write(&Data::Object(vec![
        ("id", id),
        (
            "result",
            Data::Object(vec![("answers", Data::Object(rows))]),
        ),
    ]))
    .ok()
}
