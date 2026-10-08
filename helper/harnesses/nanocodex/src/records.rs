//! Live events and committed Nano rows share one projection table.
use super::{document, error, flag, rejection, string, value};
use dispatch_helper_core::{
    api::{Error, Record, RecordKind as Kind, State, Tool},
    json::{Data, Json, Value},
    tool,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

#[derive(Default)]
pub struct Projection {
    pub side: bool,
    pub session: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    turn: String,
    /// Turns the transcript itself named. A message's echoed provider turn routes it only to one of these.
    started: BTreeSet<String>,
    texts: BTreeMap<String, String>,
    tools: BTreeMap<String, Record>,
}
/// Terminal run counters are per-turn; the journal covers this process's session.
#[derive(Default)]
pub struct Usage {
    turns: BTreeMap<String, (Option<u64>, Option<u64>, Option<f64>)>,
    context: Option<u64>,
}
impl Usage {
    pub fn observe(&mut self, event: Value<'_>) {
        let Some(payload) = event.get("payload") else {
            return;
        };
        let kind = text(event, "type");
        if kind == "model.call.completed" {
            self.context = payload
                .get("usage")
                .and_then(|v| v.get("total_tokens"))
                .and_then(Value::unsigned);
        }
        if matches!(kind.as_str(), "run.completed" | "run.failed") {
            let turn = text(payload, "turn_id");
            if turn.is_empty() {
                return;
            }
            let usage = payload
                .get("usage")
                .filter(|v| text(*v, "cost_status") != "usage_not_reported");
            let input = usage
                .and_then(|v| v.get("input_tokens"))
                .and_then(Value::unsigned);
            let output = usage
                .and_then(|v| v.get("output_tokens"))
                .and_then(Value::unsigned);
            let cost = payload.get("cost_usd").and_then(Value::number);
            self.turns.insert(turn, (input, output, cost));
        }
    }
    pub fn payload(&self) -> Option<String> {
        if self.turns.is_empty() && self.context.is_none() {
            return None;
        }
        let mut total = Vec::new();
        for (key, index) in [("input_tokens", 0), ("output_tokens", 1)] {
            if !self.turns.is_empty()
                && let Some(count) = self.turns.values().try_fold(0u64, |sum, item| {
                    sum.checked_add(if index == 0 { item.0? } else { item.1? })
                })
            {
                total.push((key, Data::Unsigned(count)));
            }
        }
        let mut info = vec![("total_token_usage", Data::Object(total))];
        if let Some(context) = self.context {
            info.push((
                "last_token_usage",
                Data::Object(vec![("total_tokens", Data::Unsigned(context))]),
            ));
        }
        if !self.turns.is_empty()
            && let Some(cost) = self
                .turns
                .values()
                .try_fold(0.0, |sum, item| Some(sum + item.2?))
        {
            info.push(("total_cost_usd", Data::Real(cost)));
        }
        document(Data::Object(vec![("info", Data::Object(info))]))
            .ok()
            .map(|doc| super::printable(Some(doc.root())))
    }
}
pub fn text(v: Value<'_>, key: &str) -> String {
    v.get(key).and_then(Value::string).unwrap_or("").to_owned()
}
pub fn content(v: Option<Value<'_>>) -> String {
    v.map(|v| {
        v.string().map(str::to_owned).unwrap_or_else(|| {
            v.array()
                .map(|a| {
                    a.filter_map(|v| v.get("text").and_then(Value::string))
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .unwrap_or_default()
        })
    })
    .unwrap_or_default()
}
/// The turn a record names itself, and whether it starts that turn.
pub fn context(v: Value<'_>) -> Option<(&str, bool)> {
    let p = v.get("payload")?;
    let id = p.get("root_turn_id").or_else(|| p.get("turn_id"))?.string()?;
    Some((
        id,
        text(p, "type") == "task_started" || text(v, "type") == "run.started",
    ))
}
/// A message's echoed provider turn (`internal_chat_message_metadata_passthrough`). Nanocodex echoes a
/// provider-scoped ID (`<session>:<n>`) that names no rollout turn, so it is never a turn boundary.
pub fn echoed(v: Value<'_>) -> Option<&str> {
    v.get("payload")?
        .get("internal_chat_message_metadata_passthrough")?
        .get("turn_id")?
        .string()
}
// Fixed native and legacy tags; empty output is a valid tool result.
const ROWS: &[(&str, Kind, &str)] = &[
    ("input.accepted", Kind::User, "input"),
    ("input_accepted", Kind::User, "input"),
    ("user_message", Kind::User, "message"),
    ("assistant.delta", Kind::Assistant, "text"),
    ("assistant.message", Kind::Assistant, "text"),
    ("agent_message", Kind::Assistant, "message"),
    ("message", Kind::Assistant, "content"),
    ("reasoning.summary.delta", Kind::Reasoning, "text"),
    ("reasoning", Kind::Reasoning, "summary"),
    ("tool.call", Kind::Tool, "arguments"),
    ("function_call", Kind::Tool, "arguments"),
    ("custom_tool_call", Kind::Tool, "input"),
    ("tool.result", Kind::Tool, "result"),
    ("function_call_output", Kind::Tool, "output"),
    ("custom_tool_call_output", Kind::Tool, "output"),
    ("run.started", Kind::TurnStarted, ""),
    ("task_started", Kind::TurnStarted, ""),
    ("run.completed", Kind::TurnEnded, ""),
    ("run.failed", Kind::TurnEnded, ""),
    ("task_complete", Kind::TurnEnded, ""),
    ("turn_aborted", Kind::TurnEnded, ""),
];
impl Projection {
    pub fn receipt(doc: Json) -> Result<Json, Error> {
        match string(doc.root(), "status") {
            "pending" => Ok(doc),
            "accepted" => document(
                doc.root()
                    .get("result")
                    .map(Data::Value)
                    .unwrap_or(Data::Object(vec![])),
            ),
            "rejected" => Err(error(
                "not_sent",
                rejection(string(doc.root(), "code"), string(doc.root(), "message")),
            )),
            _ => Err(error(
                "unknown",
                "Nanocodex could not confirm this request. Check Terminal before trying again.",
            )),
        }
    }
    pub fn state(snapshot: Value<'_>, session: &str, turns: &[String]) -> State {
        let focused = string(snapshot, "active_session_id") == session;
        let running =
            !turns.is_empty() || focused && string(snapshot, "state.execution") == "running";
        State {
            busy: running,
            activity: Some(if running { "working" } else { "idle" }.into()),
            model: value(snapshot, "state.settings.model")
                .and_then(Value::string)
                .map(str::to_owned),
            effort: value(snapshot, "state.settings.effort")
                .and_then(Value::string)
                .map(str::to_owned),
            draft: focused
                .then(|| value(snapshot, "state.composer.text"))
                .flatten()
                .and_then(Value::string)
                .map(str::to_owned),
            attention: (focused && flag(snapshot, "state.ui_blocked")).then(|| {
                "Nanocodex has a dialog open in Terminal. Your Chat draft is preserved.".into()
            }),
            ..State::default()
        }
    }
    pub fn models(result: Value<'_>) -> Result<Vec<(String, Vec<String>)>, &'static str> {
        let models = result
            .get("models")
            .and_then(Value::array)
            .ok_or("Nanocodex returned no model choices.")?;
        let mut choices = Vec::new();
        for model in models {
            let id = string(model, "id");
            if id.is_empty() {
                return Err("Nanocodex returned invalid model choices.");
            }
            let efforts = model
                .get("efforts")
                .and_then(Value::array)
                .map(|a| a.filter_map(Value::string).map(str::to_owned).collect())
                .unwrap_or_default();
            choices.push((id.to_owned(), efforts));
        }
        if choices.is_empty() {
            return Err("Nanocodex returned invalid model choices.");
        }
        Ok(choices)
    }
    pub fn begin(&mut self, turn: Option<&str>) {
        if let Some(turn) = turn {
            self.turn = turn.to_owned();
            self.started.insert(turn.to_owned());
        }
    }
    pub fn new(side: bool) -> Self {
        Self {
            side,
            ..Self::default()
        }
    }
    pub fn live(
        &mut self,
        v: Value<'_>,
        accumulated: bool,
        time: Option<i64>,
        hash: &dyn Fn(&[u8]) -> String,
        printable: &dyn Fn(Option<Value<'_>>) -> String,
    ) -> Vec<Record> {
        self.project(v, None, accumulated, time, hash, printable)
    }
    pub fn saved(
        &mut self,
        v: Value<'_>,
        key: &str,
        time: Option<i64>,
        hash: &dyn Fn(&[u8]) -> String,
        printable: &dyn Fn(Option<Value<'_>>) -> String,
    ) -> Vec<Record> {
        self.project(v, Some(key), true, time, hash, printable)
    }
    fn project(
        &mut self,
        v: Value<'_>,
        key: Option<&str>,
        accumulated: bool,
        time: Option<i64>,
        hash: &dyn Fn(&[u8]) -> String,
        printable: &dyn Fn(Option<Value<'_>>) -> String,
    ) -> Vec<Record> {
        let Some(p) = v.get("payload") else {
            return vec![];
        };
        let outer = text(v, "type");
        if key.is_some() {
            if outer == "session_meta" {
                self.session = Some(text(p, "id"));
                return vec![];
            }
            if self.session.as_deref().is_none_or(str::is_empty) {
                return vec![];
            }
            if outer == "turn_context" {
                self.model = Some(text(p, "model"));
                self.effort = Some(text(p, "effort"));
                return vec![];
            }
        }
        let tag = if key.is_none() {
            outer
        } else {
            text(p, "type")
        };
        let Some((_, kind, field)) = ROWS.iter().find(|(t, _, _)| *t == tag) else {
            return vec![];
        };
        let turn = context(v).map(|(id, _)| id);
        let echoed = echoed(v);
        if key.is_none() && turn.or(echoed).is_none_or(str::is_empty) {
            return vec![];
        }
        self.begin(turn);
        if turn.is_none()
            && let Some(echoed) = echoed
            && self.started.contains(echoed)
        {
            self.turn = echoed.to_owned();
        }
        if self.turn.is_empty() {
            self.turn = "history".into();
        }
        if tag == "message" && (text(p, "role") != "assistant" || text(p, "channel") == "analysis")
        {
            return vec![];
        }
        let mut row = Record {
            id: key.unwrap_or_default().into(),
            turn: Some(self.turn.clone()),
            kind: *kind,
            time_ms: time,
            ..Record::default()
        };
        match kind {
            Kind::User => {
                row.text = content(p.get(field));
                if self.side {
                    // Native755b23cc tui/mod.rs:79-85,456; captured side input keeps this instruction.
                    let boundary = "You are answering an ephemeral BTW side question.\n\
Treat inherited conversation history only as reference context. Do not resume or complete an\n\
earlier task. Answer only the question after this boundary. Do not modify the workspace unless\n\
that side question explicitly requests a mutation.\n\nBTW question:\n";
                    if let Some(question) = row.text.strip_prefix(boundary) {
                        row.text = question.to_owned();
                    }
                }
                row.id = "user-".to_owned() + &hash(row.text.as_bytes());
                if row.text.is_empty() && tag != "user_message" {
                    return vec![];
                }
            }
            Kind::Assistant | Kind::Reasoning => {
                if *kind == Kind::Reasoning {
                    row.title = "Reasoning summary".into();
                }
                row.id = if let Some(key) = key {
                    p.get("id").and_then(Value::string).unwrap_or(key).into()
                } else {
                    p.get("item_id")
                        .and_then(Value::string)
                        .map(str::to_owned)
                        .unwrap_or_else(|| {
                            format!(
                                "{}-{}-{}",
                                if *kind == Kind::Reasoning {
                                    "nanocodex-reasoning"
                                } else {
                                    "nanocodex"
                                },
                                self.turn,
                                p.get("model_call_index")
                                    .and_then(Value::unsigned)
                                    .unwrap_or(0)
                            )
                        })
                };
                row.text = content(p.get(field));
                if tag.ends_with(".delta") && !accumulated {
                    row.text = self.texts.get(&row.id).cloned().unwrap_or_default() + &row.text;
                }
                if key.is_none() {
                    self.texts.insert(row.id.clone(), row.text.clone());
                    if row.text.is_empty() {
                        return vec![];
                    }
                }
            }
            Kind::Tool => {
                let call = p
                    .get("call_id")
                    .or_else(|| p.get("id"))
                    .and_then(Value::string)
                    .unwrap_or(key.unwrap_or_default());
                if key.is_none() && (call.is_empty() || call.contains('/')) {
                    return vec![];
                }
                row.id = "tool-".to_owned() + call;
                if tag == "tool.result" || tag.ends_with("_output") {
                    row = self.tools.remove(&row.id).unwrap_or(row);
                    row.completed = true;
                    row.output = printable(p.get(field));
                } else {
                    row.text = printable(p.get(field));
                    row.title = p
                        .get(if key.is_none() { "tool" } else { "name" })
                        .and_then(Value::string)
                        .unwrap_or("Tool")
                        .into();
                    let arguments = Json::parse(row.text.as_bytes()).ok();
                    let arguments = arguments.as_ref().map(Json::root);
                    let directory = arguments
                        .and_then(|v| v.get("workdir").or_else(|| v.get("cwd")))
                        .and_then(Value::string);
                    let command = arguments
                        .and_then(|v| v.get("cmd").or_else(|| v.get("command")))
                        .and_then(Value::string);
                    let input = arguments
                        .and_then(|v| {
                            v.get("patch")
                                .or_else(|| v.get("input"))
                                .or_else(|| v.get("cmd"))
                                .or_else(|| v.get("command"))
                        })
                        .and_then(Value::string)
                        .unwrap_or(&row.text);
                    let workdir = arguments
                        .and_then(|v| v.get("workdir"))
                        .and_then(Value::string)
                        .map(Path::new);
                    row.documents = tool::patch(input, workdir);
                    let name = row.title.rsplit('.').next().unwrap_or("").to_lowercase();
                    let mut presentation = if ["shell", "exec_command", "shell_command", "bash"]
                        .contains(&name.as_str())
                    {
                        tool::shell(command.unwrap_or(input), Path::new(directory.unwrap_or("")))
                    } else if !row.documents.is_empty() {
                        let patch = ["apply_patch", "patch"].contains(&name.as_str());
                        let diff = row.documents.iter().any(|d| !d.diff.is_empty());
                        Tool {
                            kind: if patch { "patch" } else { "read" }.into(),
                            title: if patch {
                                "Patch"
                            } else if diff {
                                "Review changes"
                            } else {
                                "Read"
                            }
                            .into(),
                            symbol: if patch {
                                "pencil.line"
                            } else if diff {
                                "doc.text.magnifyingglass"
                            } else {
                                "doc.text"
                            }
                            .into(),
                            summary: row
                                .documents
                                .iter()
                                .map(|d| d.path.as_str())
                                .collect::<Vec<_>>()
                                .join(", "),
                            input: command.unwrap_or("").into(),
                            language: "shell".into(),
                            patch,
                            additions: row
                                .documents
                                .iter()
                                .map(|d| {
                                    d.diff.lines().filter(|s| s.starts_with('+')).count() as u64
                                })
                                .sum(),
                            deletions: row
                                .documents
                                .iter()
                                .map(|d| {
                                    d.diff.lines().filter(|s| s.starts_with('-')).count() as u64
                                })
                                .sum(),
                            ..Tool::default()
                        }
                    } else {
                        Tool {
                            kind: "tool".into(),
                            title: row.title.clone(),
                            symbol: "wrench.and.screwdriver".into(),
                            summary: arguments
                                .and_then(|v| v.get("description").or_else(|| v.get("query")))
                                .and_then(Value::string)
                                .unwrap_or("")
                                .into(),
                            input: row.text.clone(),
                            language: if arguments.is_some() { "json" } else { "text" }.into(),
                            ..Tool::default()
                        }
                    };
                    presentation.directory = directory.map(Into::into);
                    row.tool = Some(presentation);
                    self.tools.insert(row.id.clone(), row.clone());
                }
            }
            Kind::TurnStarted | Kind::TurnEnded => {
                if key.is_none() {
                    row.id = "nanocodex:".to_owned()
                        + &hash(
                            format!(
                                "{}\0{}",
                                self.turn,
                                if *kind == Kind::TurnStarted {
                                    "started"
                                } else {
                                    "ended"
                                }
                            )
                            .as_bytes(),
                        );
                }
            }
            _ => return vec![],
        }
        vec![row]
    }
}
