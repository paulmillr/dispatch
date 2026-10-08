//! Pi's native message identities are shared by streamed and saved records.
use dispatch_helper_core::{
    api::{Record, RecordKind},
    json::{Format, Json, Kind, Value},
    rpc::Lines,
};

pub const LIMIT: usize = 4_194_304; // c1654cc TranscriptJSONLFramer.maximumLineBytes.

pub struct Reader {
    session: String,
    turn: String,
    lines: Lines,
    header: bool,
    pub compatible: bool,
    pub model: Option<String>,
    pub effort: Option<String>,
}

pub fn text(value: Value<'_>, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::string)
        .unwrap_or_default()
        .into()
}

/// Transcript display retains Dispatch's pretty, sorted JSON presentation.
pub fn printable(value: Value<'_>) -> String {
    value.string().map(str::to_owned).unwrap_or_else(|| {
        String::from_utf8(value.write_with(Format::PrettySorted).unwrap_or_default())
            .unwrap_or_default()
    })
}

pub fn entry(value: Value<'_>) -> Option<(&str, Option<&str>)> {
    if value.get("type").and_then(Value::string) == Some("session") {
        return None;
    }
    let id = value.get("id")?.string().filter(|id| !id.is_empty())?;
    let parent = value.get("parentId")?;
    if parent.kind() == Kind::Null {
        return Some((id, None));
    }
    Some((
        id,
        Some(
            parent
                .string()
                .filter(|parent| !parent.is_empty() && *parent != id)?,
        ),
    ))
}

impl Reader {
    pub fn begin(&mut self, turn: Option<&str>) {
        self.turn = turn.unwrap_or("history").into();
    }
    pub fn new(session: &str) -> Self {
        Self {
            session: session.into(),
            turn: "history".into(),
            lines: Lines::recover(LIMIT),
            header: false,
            compatible: false,
            model: None,
            effort: Some("off".into()),
        }
    }

    /// Only complete bounded native records are exposed, including across file reads.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<Record> {
        self.feed_at(bytes)
            .into_iter()
            .map(|(_, record)| record)
            .collect()
    }

    pub fn feed_at(&mut self, bytes: &[u8]) -> Vec<(u64, Record)> {
        let mut lines = std::mem::replace(&mut self.lines, Lines::recover(LIMIT));
        let mut result = Vec::new();
        lines
            .feed_at(bytes, |offset, bytes| {
                if let Ok(document) = Json::parse(bytes) {
                    result.extend(
                        self.parse(document.root())
                            .into_iter()
                            .map(|record| (offset, record)),
                    );
                }
                Ok(())
            })
            .expect("native transcript offset fits u64");
        self.lines = lines;
        result
    }

    pub fn session_id(&self) -> Option<&str> {
        self.compatible.then_some(self.session.as_str())
    }

    pub fn parse(&mut self, root: Value<'_>) -> Vec<Record> {
        let kind = text(root, "type");
        if kind == "session" {
            self.compatible = !self.header
                && text(root, "id") == self.session
                && matches!(root.get("version").and_then(Value::unsigned), Some(2 | 3));
            self.header = true;
            return Vec::new();
        }
        if self.session_id().is_none() || entry(root).is_none() {
            return Vec::new();
        }
        if kind == "thinking_level_change" {
            self.effort = root
                .get("thinkingLevel")
                .and_then(Value::string)
                .map(str::to_owned);
        }
        let message = root.get("message");
        let configuration = if kind == "model_change" {
            Some((text(root, "provider"), text(root, "modelId")))
        } else {
            message
                .filter(|v| text(*v, "role") == "assistant")
                .map(|v| (text(v, "provider"), text(v, "model")))
        };
        if let Some((provider, model)) = configuration
            && !model.is_empty()
        {
            self.model = Some(if provider.is_empty() {
                model
            } else {
                format!("{provider}/{model}")
            });
        }
        project(root, &mut self.turn, true)
    }
}

/// Native content text; Pi uses the same image placeholder in history and live views.
pub(crate) fn content(value: Option<Value<'_>>) -> String {
    let Some(value) = value else {
        return String::new();
    };
    if let Some(text) = value.string() {
        return text.into();
    }
    value
        .array()
        .into_iter()
        .flatten()
        .filter_map(|block| match text(block, "type").as_str() {
            "text" => block.get("text").and_then(Value::string).map(str::to_owned),
            "image" => Some("[Image]".into()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Projection matches PiTranscriptParser on selected native entries. Tool bodies stay
/// in the caller's bounded line and are copied only for the requested native record.
pub fn project(root: Value<'_>, turn: &mut String, complete: bool) -> Vec<Record> {
    let id = text(root, "id");
    let kind = text(root, "type");
    let message = root.get("message");
    let time = root
        .get("timestamp")
        .and_then(Value::string)
        .and_then(timestamp)
        .or_else(|| {
            message
                .and_then(|v| v.get("timestamp"))
                .and_then(Value::signed)
        })
        .or(Some(0));
    let mut records = Vec::new();
    let mut add =
        |id: String, kind, value: String, title: String, output: String, completed, exit_code| {
            records.push(Record {
                id,
                turn: Some(turn.clone()),
                kind,
                text: value,
                title,
                output,
                completed,
                exit_code,
                time_ms: time,
                ..Record::default()
            });
        };
    if kind == "branch_summary" && !text(root, "summary").is_empty() {
        add(
            format!("pi-{id}"),
            RecordKind::Notice,
            text(root, "summary"),
            "Branch summary".into(),
            String::new(),
            false,
            None,
        );
    } else if kind == "custom_message" && root.get("display").and_then(Value::boolean) == Some(true)
    {
        add(
            format!("pi-{id}"),
            RecordKind::Notice,
            content(root.get("content")),
            root.get("customType")
                .and_then(Value::string)
                .unwrap_or("Pi extension")
                .into(),
            String::new(),
            false,
            None,
        );
    }
    if kind != "message" {
        return records;
    }
    let Some(message) = message else {
        return records;
    };
    let role = text(message, "role");
    if role == "user" {
        *turn = id.clone();
        let mut start = Record {
            id: format!("{id}:started"),
            turn: Some(id.clone()),
            kind: RecordKind::TurnStarted,
            time_ms: time,
            ..Record::default()
        };
        records.push(start.clone());
        let value = content(message.get("content"));
        if !value.is_empty() {
            start.id = format!("user-{id}");
            start.kind = RecordKind::User;
            start.text = value;
            records.push(start);
        }
        return records;
    }
    match role.as_str() {
        "assistant" => {
            let assistant = message
                .get("timestamp")
                .and_then(Value::signed)
                .map(|time| format!("pi-live-{time}"))
                .unwrap_or_else(|| format!("pi-{id}"));
            for (index, block) in message
                .get("content")
                .and_then(Value::array)
                .into_iter()
                .flatten()
                .enumerate()
            {
                let kind = text(block, "type");
                let value = text(
                    block,
                    if kind == "thinking" {
                        "thinking"
                    } else {
                        "text"
                    },
                );
                match kind.as_str() {
                    "text" if !value.is_empty() => add(
                        format!("{assistant}-{index}"),
                        RecordKind::Assistant,
                        value,
                        String::new(),
                        String::new(),
                        complete,
                        None,
                    ),
                    "thinking"
                        if !value.is_empty()
                            && block.get("redacted").and_then(Value::boolean) != Some(true) =>
                    {
                        add(
                            format!("{assistant}-{index}"),
                            RecordKind::Reasoning,
                            value,
                            "Thinking".into(),
                            String::new(),
                            complete,
                            None,
                        )
                    }
                    "toolCall" => {
                        let arguments = block.get("arguments").map(printable).unwrap_or_default();
                        add(
                            format!("tool-{}", text(block, "id")),
                            RecordKind::Tool,
                            arguments,
                            text(block, "name"),
                            String::new(),
                            false,
                            None,
                        );
                    }
                    _ => {}
                }
            }
            let stop = text(message, "stopReason");
            if ["error", "aborted"].contains(&stop.as_str()) {
                let aborted = stop == "aborted";
                add(
                    format!("pi-{id}-error"),
                    RecordKind::Notice,
                    message
                        .get("errorMessage")
                        .and_then(Value::string)
                        .unwrap_or(if aborted {
                            "Response interrupted."
                        } else {
                            "Pi could not complete this response."
                        })
                        .into(),
                    if aborted { "Interrupted" } else { "Pi error" }.into(),
                    String::new(),
                    false,
                    None,
                );
            }
            if ["stop", "length", "error", "aborted"].contains(&stop.as_str()) {
                add(
                    format!("{turn}:ended"),
                    RecordKind::TurnEnded,
                    String::new(),
                    String::new(),
                    String::new(),
                    false,
                    None,
                );
            }
        }
        "toolResult" | "bashExecution" => {
            let bash = role == "bashExecution";
            let code = if bash {
                message.get("exitCode")
            } else {
                message.get("details").and_then(|v| v.get("exitCode"))
            }
            .and_then(Value::signed)
            .and_then(|v| v.try_into().ok())
            .or_else(|| {
                (message
                    .get(if bash { "cancelled" } else { "isError" })
                    .and_then(Value::boolean)
                    == Some(true))
                .then_some(1)
            });
            add(
                if bash {
                    format!("pi-bash-{id}")
                } else {
                    format!("tool-{}", text(message, "toolCallId"))
                },
                RecordKind::Tool,
                if bash {
                    text(message, "command")
                } else {
                    String::new()
                },
                if bash {
                    "bash".into()
                } else {
                    text(message, "toolName")
                },
                if bash {
                    text(message, "output")
                } else {
                    content(message.get("content"))
                },
                true,
                code,
            );
        }
        "custom" | "hookMessage"
            if message.get("display").and_then(Value::boolean) == Some(true) =>
        {
            add(
                format!("pi-{id}"),
                RecordKind::Notice,
                content(message.get("content")),
                message
                    .get("customType")
                    .and_then(Value::string)
                    .unwrap_or("Pi extension")
                    .into(),
                String::new(),
                false,
                None,
            )
        }
        _ => {}
    }
    for row in &mut records {
        crate::presentation::apply(row);
    }
    records
}

fn timestamp(value: &str) -> Option<i64> {
    let values = value
        .trim_end_matches('Z')
        .split(['-', 'T', ':', '.'])
        .map(str::parse::<i64>)
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    let [year, month, day, hour, minute, second, millis] = values.as_slice() else {
        return None;
    };
    let year = year - i64::from(*month <= 2);
    let era = year.div_euclid(400);
    let y = year - era * 400;
    let month = month + if *month > 2 { -3 } else { 9 };
    let days = era * 146097 + y * 365 + y / 4 - y / 100 + (153 * month + 2) / 5 + day - 1 - 719468;
    Some((((days * 24 + hour) * 60 + minute) * 60 + second) * 1000 + millis)
}
