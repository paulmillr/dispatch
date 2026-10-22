//! Claude's native JSONL projection, including invisible parent links.
use dispatch_helper_core::{
    api::*,
    json::{Data, Format, Json, Value},
    rpc::Lines,
};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

pub(crate) fn text<'a>(v: Value<'a>, key: &str) -> Option<&'a str> {
    v.get(key)?.string()
}
/// Injected context and transcript-only compact summaries are never user turns
/// (upstream e076fd7 ClaudeTranscript.swift isUserTurn).
fn hidden(root: Value<'_>) -> bool {
    ["isMeta", "isCompactSummary"]
        .iter()
        .any(|key| root.get(key).and_then(|v| v.boolean()) == Some(true))
}
pub(crate) fn content(v: Option<Value<'_>>) -> String {
    let Some(v) = v else { return String::new() };
    if let Some(s) = v.string() {
        return s.into();
    }
    v.array()
        .into_iter()
        .flatten()
        .filter_map(|b| match text(b, "type") {
            Some("text") => text(b, "text"),
            Some("image") => Some("[Image]"),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}
/// A user message's attachments beyond `shown` (its `content` text) for chat.attachments
/// clients (api::attachment::Attached): Claude records a pasted image path as an `[Image #n]`
/// placeholder in the text and the image's data as a block after it (`content` shows an
/// `[Image]` line); the text without those lines, an image per image block.
pub(crate) fn attached(v: Option<Value<'_>>, shown: &str) -> Option<Box<attachment::Attached>> {
    let blocks: Vec<_> = v?.array().into_iter().flatten().collect();
    let images: Vec<_> = blocks.iter().filter(|b| text(**b, "type") == Some("image")).map(|_| None).collect();
    if images.is_empty() {
        return attachment::attached(shown, None, images);
    }
    let body = blocks.iter().filter(|b| text(**b, "type") == Some("text")).filter_map(|b| text(*b, "text"));
    attachment::attached(shown, Some(body.collect::<Vec<_>>().join("\n")), images)
}
pub(crate) fn error(code: &'static str, message: impl ToString) -> Error {
    Error {
        code,
        message: message.to_string(),
    }
}
pub(crate) fn uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

#[derive(Clone)]
pub struct Parser {
    session: String,
    lines: Lines,
    /// Bytes of an unfinished last line held by `lines` (an archive cursor ends before them).
    held: u64,
    turn: String,
    parents: BTreeMap<String, String>,
    order: VecDeque<String>,
    pending: VecDeque<(String, String, Vec<Record>, usize)>,
    bytes: usize,
    pub state: State,
    pub observed: Option<String>,
    /// Line uuid of the newest record behind `state.model`: a model call or a native /model switch.
    pub configured: Option<String>,
    /// Line uuid of the newest record that set the model or effort (`configured` or a native
    /// /effort switch); a picker choice (`Claude.chosen`) holds until it changes.
    pub changed: Option<String>,
    pub version: Option<String>,
    page: Option<(BTreeSet<String>, Option<String>)>,
}
impl Parser {
    pub fn new(session: String) -> Self {
        Self {
            session,
            lines: Lines::recover(4_194_304),
            held: 0,
            turn: "history".into(),
            parents: BTreeMap::new(),
            order: VecDeque::new(),
            pending: VecDeque::new(),
            bytes: 0,
            state: State::default(),
            observed: None,
            configured: None,
            changed: None,
            version: None,
            page: None,
        }
    }
    /// c1654cc ClaudeTranscript.swift:174-178: a title record (Some), with its title if it has one.
    fn title(root: Value<'_>) -> Option<Option<String>> {
        let field = match text(root, "type") {
            Some("ai-title") => "aiTitle",
            Some("custom-title") => "customTitle",
            _ => return None,
        };
        Some(text(root, field).map(str::to_owned))
    }
    /// A model call: model, effort and the context of the call.
    fn configure(&mut self, root: Value<'_>, message: Value<'_>, id: &str) {
        if let Some(model) = text(message, "model").filter(|m| *m != "<synthetic>") {
            self.state.model = Some(model.into());
            self.state.effort = text(root, "effort").map(str::to_owned);
            self.configured = Some(id.into());
            self.changed = Some(id.into());
            // Context of the last model call; like pi no totals (a page sees part of the file).
            if let Some(usage) = message.get("usage") {
                let tokens = [
                    "input_tokens",
                    "cache_creation_input_tokens",
                    "cache_read_input_tokens",
                    "output_tokens",
                ]
                .iter()
                .filter_map(|key| usage.get(key).and_then(|v| v.unsigned()))
                .sum::<u64>();
                let last = Data::Object(vec![("total_tokens", Data::Unsigned(tokens))]);
                self.state.usage = dispatch_helper_core::wire::body::Encoded::value(&Data::Object(vec![(
                    "info",
                    Data::Object(vec![("last_token_usage", last)]),
                )]))
                .ok();
            }
        }
    }
    /// A line before an initial page (c1654cc TranscriptReader.swift:420-460, newest first): its
    /// title or model call fills what the page left unset. True once neither is missing.
    pub(crate) fn earlier(&mut self, line: &[u8]) -> bool {
        if let Ok(doc) = Json::parse(line)
            && let root = doc.root()
            && text(root, "sessionId") == Some(&self.session)
            && root.get("isSidechain").and_then(|v| v.boolean()) != Some(true)
        {
            if self.state.title.is_none() {
                self.state.title = Self::title(root).flatten();
            }
            if self.configured.is_none()
                && text(root, "type") == Some("assistant")
                && let (Some(message), Some(id)) = (root.get("message"), text(root, "uuid"))
                && text(message, "role") == Some("assistant")
            {
                self.configure(root, message, id);
            } else if self.configured.is_none()
                && let Some(id) = text(root, "uuid")
                && let Some(output) = Self::native_output(root)
                && let Some((model, effort)) = switched_model(&output)
            {
                self.state.model = Some(model);
                self.state.effort = effort;
                self.configured = Some(id.into());
            }
        }
        self.state.title.is_some() && self.configured.is_some()
    }
    pub(crate) fn context(&self, line: &[u8]) -> Option<(String, bool)> {
        let doc = Json::parse(line).ok()?;
        let root = doc.root();
        if text(root, "sessionId") != Some(&self.session)
            || root.get("isSidechain").and_then(|v| v.boolean()) == Some(true)
        {
            return None;
        }
        let own = Self::user(root);
        let result = text(root, "type") == Some("user")
            && root
                .get("message")
                .and_then(|v| v.get("content"))
                .and_then(|v| v.array())
                .is_some_and(|mut a| a.any(|v| text(v, "type") == Some("tool_result")));
        if own {
            Some((
                text(root, "promptId")
                    .or_else(|| text(root, "uuid"))?
                    .into(),
                true,
            ))
        } else if result {
            Some((text(root, "promptId")?.into(), false))
        } else {
            None
        }
    }
    pub fn page(&mut self, lines: &[Vec<u8>], context: Option<String>) {
        self.lines = Lines::recover(4_194_304);
        self.held = 0;
        self.pending.clear();
        self.bytes = 0;
        self.turn = context.clone().unwrap_or_else(|| "history".into());
        let ids = lines
            .iter()
            .filter_map(|b| Json::parse(b).ok())
            .filter_map(|v| text(v.root(), "uuid").map(str::to_owned))
            .collect();
        self.page = Some((ids, context));
    }
    pub fn held(&self) -> u64 {
        self.held
    }
    pub fn finish(&mut self) {
        self.page = None
    }
    pub fn feed(&mut self, bytes: &[u8]) -> Result<Vec<Record>, Error> {
        let mut out = Vec::new();
        let mut lines = Vec::new();
        self.lines
            .feed(bytes, |line| {
                lines.push(line.to_vec());
                Ok(())
            })
            .map_err(|failure| {
                error(
                    "transcript",
                    format!("Transcript framing failed: {failure:?}"),
                )
            })?;
        self.held = match bytes.iter().rposition(|b| *b == b'\n') {
            Some(end) => (bytes.len() - end - 1) as u64,
            None => self.held + bytes.len() as u64,
        };
        for line in lines {
            let Ok(doc) = Json::parse(&line) else {
                continue;
            };
            let root = doc.root();
            if root.get("isSidechain").and_then(|v| v.boolean()) == Some(true) {
                continue;
            }
            let Some(session) = text(root, "sessionId") else {
                continue;
            };
            if !uuid(session) || text(root, "type").is_none() {
                continue;
            }
            if session != self.session {
                self.pending.clear();
                self.bytes = 0;
                return Err(error(
                    "session",
                    "Transcript belongs to another Claude session",
                ));
            }
            // e076fd7 ClaudeTranscript.swift parse(): the first typed record binds the session; the
            // version comes from the first record carrying one (titles excluded).
            if self.observed.is_none() {
                self.observed = Some(session.into());
                self.version = text(root, "version").map(str::to_owned);
            }
            // c1654cc ClaudeTranscript.swift:174-178 + ChatCoordinator.swift:1089: title records
            // carry no uuid; the latest one names the session.
            if let Some(title) = Self::title(root) {
                self.state.title = title.or(self.state.title.take());
                continue;
            }
            if self.version.is_none() {
                self.version = text(root, "version").map(str::to_owned);
            }
            let Some(id) = text(root, "uuid") else {
                continue;
            };
            let parent = text(root, "parentUuid");
            let records = self.parse(root, id);
            let turn = if Self::user(root) {
                Some(text(root, "promptId").unwrap_or(id).to_owned())
            } else {
                parent
                    .and_then(|p| self.parents.get(p).cloned())
                    .or_else(|| parent.is_none().then(|| self.turn.clone()))
                    .or_else(|| {
                        self.page.as_ref().and_then(|(ids, context)| {
                            parent.filter(|p| !ids.contains(*p)).and(context.clone())
                        })
                    })
            };
            if let Some(turn) = turn {
                self.route(id, &turn, records, &mut out)
            } else if let Some(parent) = parent {
                if self.pending.len() == 400 || line.len() > 4_194_304 - self.bytes {
                    return Err(error(
                        "limit",
                        "Claude parent chain exceeds its native bound",
                    ));
                }
                self.bytes += line.len();
                self.pending
                    .push_back((id.into(), parent.into(), records, line.len()));
            }
            for _ in 0..self.pending.len() {
                let Some(index) = self
                    .pending
                    .iter()
                    .position(|(_, parent, _, _)| self.parents.contains_key(parent))
                else {
                    break;
                };
                let (id, parent, records, size) = self.pending.remove(index).unwrap();
                self.bytes -= size;
                let turn = self.parents[&parent].clone();
                self.route(&id, &turn, records, &mut out);
            }
        }
        Ok(out)
    }
    fn route(&mut self, id: &str, turn: &str, records: Vec<Record>, out: &mut Vec<Record>) {
        if !self.parents.contains_key(id) {
            self.order.push_back(id.into())
        }
        self.parents.insert(id.into(), turn.into());
        if self.order.len() > 8192 {
            for _ in 0..4096 {
                self.parents.remove(&self.order.pop_front().unwrap());
            }
        }
        for record in records {
            // Tool records also map to their turn (ids "tool-<call>" never equal a line uuid),
            // so a live hook can name the turn of its tool card (Interaction.turn).
            if record.kind == RecordKind::Tool && !self.parents.contains_key(&record.id) {
                self.order.push_back(record.id.clone());
                self.parents.insert(record.id.clone(), turn.into());
            }
            out.push(Record {
                turn: Some(turn.into()),
                ..record
            });
        }
    }
    /// The turn a routed tool record belongs to.
    pub fn turn_of(&self, record: &str) -> Option<String> {
        self.parents.get(record).cloned()
    }
    fn user(root: Value<'_>) -> bool {
        let Some(message) = root.get("message") else {
            return false;
        };
        let body = content(message.get("content"));
        text(root, "type") == Some("user")
            && text(message, "role") == Some("user")
            && !hidden(root)
            && !message
                .get("content")
                .and_then(|v| v.array())
                .into_iter()
                .flatten()
                .any(|b| text(b, "type") == Some("tool_result"))
            && !body.is_empty()
            && !Self::command(root, &body)
            && !Self::interrupted(&body)
    }
    fn command(root: Value<'_>, s: &str) -> bool {
        root.get("promptSource").is_none()
            && root.get("origin").is_none()
            && (s.starts_with("<command-name>")
                && s.contains("</command-name>")
                && s.contains("<command-message>")
                || s.starts_with("<local-command-stdout>")
                    && s.ends_with("</local-command-stdout>")
                // Claude 2.1.285 also records /compact itself as bare text (upstream e076fd7).
                || s == "/compact"
                || s.starts_with("/compact "))
    }
    /// What a native command printed, without terminal styling (e076fd7 ClaudeTranscript.swift
    /// commandOutput: the first `<local-command-stdout>` element, `ESC[…letter` removed, trimmed).
    fn output(id: &str, s: &str, record: Record) -> Option<Record> {
        let (_, tail) = s.split_once("<local-command-stdout>")?;
        let (raw, _) = tail.split_once("</local-command-stdout>")?;
        let mut text = String::new();
        let mut rest = raw;
        for _ in 0..raw.len() {
            let Some(at) = rest.find("\u{1b}[") else {
                break;
            };
            let after = &rest[at + 2..];
            let params = after
                .find(|c: char| !c.is_ascii_digit() && c != ';' && c != '?')
                .unwrap_or(after.len());
            let styled = after[params..].starts_with(|c: char| c.is_ascii_alphabetic());
            let end = if styled { at + 2 + params + 1 } else { at + 2 };
            text.push_str(&rest[..if styled { at } else { end }]);
            rest = &rest[end..];
        }
        text.push_str(rest);
        Some(Record {
            id: format!("{id}:output"),
            kind: RecordKind::Output,
            text: text.trim().into(),
            ..record
        })
    }
    /// A model-turn command (e.g. /init) typed by a human records its markup with no typed
    /// source; show it as entered. Upstream e076fd7 ClaudeTranscript.swift commandInput.
    fn input(root: Value<'_>, s: &str) -> Option<String> {
        if root.get("promptSource").is_some()
            || root.get("origin").and_then(|v| text(v, "kind")) != Some("human")
        {
            return None;
        }
        let mut fields = BTreeMap::new();
        let mut rest = s;
        loop {
            let trimmed = rest.trim_start();
            if trimmed.is_empty() {
                break;
            }
            let tag = ["command-name", "command-message", "command-args"]
                .into_iter()
                .find(|tag| trimmed.starts_with(&format!("<{tag}>")))?;
            let close = format!("</{tag}>");
            let end = trimmed.find(&close)?;
            if fields.insert(tag, &trimmed[tag.len() + 2..end]).is_some() {
                return None;
            }
            rest = &trimmed[end + close.len()..];
        }
        let name = fields.get("command-name").filter(|n| n.starts_with('/'))?;
        fields.get("command-message")?;
        let arguments = fields.get("command-args").map_or("", |a| a.trim());
        Some(if arguments.is_empty() {
            (*name).to_owned()
        } else {
            format!("{name} {arguments}")
        })
    }
    /// A native /model or /effort switch. Claude records it only as command output, and the next
    /// model call (the reply) may be far off, so without this a switch in Terminal, or one in a
    /// fresh session, never reached the chat.
    fn switch(&mut self, output: &str, id: &str) {
        if let Some((model, effort)) = switched_model(output) {
            self.state.model = Some(model);
            self.state.effort = effort;
            self.configured = Some(id.into());
            self.changed = Some(id.into());
        } else if let Some(effort) = switched_effort(output) {
            self.state.effort = Some(effort);
            self.changed = Some(id.into());
        }
    }
    /// The plain output of a native command record (either of Claude's two record shapes).
    fn native_output(root: Value<'_>) -> Option<String> {
        let body = match text(root, "type") {
            Some("system") if text(root, "subtype") == Some("local_command") => {
                text(root, "content")?.to_owned()
            }
            Some("user") => content(root.get("message")?.get("content")),
            _ => return None,
        };
        Self::command(root, &body).then_some(())?;
        Self::output("", &body, Record::default()).map(|r| r.text)
    }
    fn interrupted(s: &str) -> bool {
        [
            "[Request interrupted by user]",
            "[Request interrupted by user for tool use]",
        ]
        .contains(&s)
    }
    fn parse(&mut self, root: Value<'_>, id: &str) -> Vec<Record> {
        let mut out = Vec::new();
        let record = Record {
            time_ms: Some(time(text(root, "timestamp").unwrap_or(""))),
            ..Record::default()
        };
        let ended = || Record {
            id: format!("{id}:ended"),
            kind: RecordKind::TurnEnded,
            ..record.clone()
        };
        let kind = text(root, "type");
        // c1654cc ClaudeTranscript.swift:183-185; ChatCoordinator.swift:1131-1132 names the notice.
        if kind == Some("system") {
            match text(root, "subtype") {
                Some("turn_duration") => {
                    self.state.busy = false;
                    out.push(ended());
                }
                Some("compact_boundary") => out.push(Record {
                    id: format!("{id}:compacted"),
                    kind: RecordKind::Notice,
                    text: "Conversation compacted".into(),
                    ..record
                }),
                Some("local_command") => {
                    let output = Self::output(id, text(root, "content").unwrap_or(""), record);
                    if let Some(output) = &output {
                        self.switch(&output.text, id);
                    }
                    out.extend(output)
                }
                _ => {}
            }
            return out;
        }
        // A message the user sent while Claude worked: Claude absorbs it into the running turn
        // and records only this attachment, never a user line. Task notifications and subagent
        // hand-backs are queued the same way but aren't the user's.
        if kind == Some("attachment") {
            if let Some(queued) = root.get("attachment")
                && text(queued, "type") == Some("queued_command")
                && text(queued, "commandMode") == Some("prompt")
                && queued.get("origin").and_then(|v| text(v, "kind")) == Some("human")
                && let body = content(queued.get("prompt"))
                && !body.trim().is_empty()
            {
                out.push(Record {
                    id: format!("user-{id}"),
                    kind: RecordKind::User,
                    attached: attached(queued.get("prompt"), &body),
                    text: body,
                    ..record
                });
            }
            return out;
        }
        let Some(message) = root.get("message") else {
            return out;
        };
        let blocks = message
            .get("content")
            .and_then(|v| v.array())
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
        if kind == Some("user") && text(message, "role") == Some("user") {
            let results = blocks
                .iter()
                .filter(|b| text(**b, "type") == Some("tool_result"))
                .collect::<Vec<_>>();
            for block in &results {
                if let Some(call) = text(**block, "tool_use_id") {
                    let exit = root
                        .get("toolUseResult")
                        .and_then(|v| v.get("exitCode"))
                        .and_then(|v| v.signed())
                        .map(|v| v as i32)
                        .or_else(|| {
                            (block.get("is_error").and_then(|v| v.boolean()) == Some(true))
                                .then_some(1)
                        });
                    out.push(Record {
                        id: format!("tool-{call}"),
                        kind: RecordKind::Tool,
                        output: content(block.get("content")),
                        completed: true,
                        exit_code: exit,
                        ..record.clone()
                    });
                }
            }
            let body = content(message.get("content"));
            if !results.is_empty() || hidden(root) || body.is_empty() {
                return out;
            }
            if Self::command(root, &body) {
                let output = Self::output(id, &body, record);
                if let Some(output) = &output {
                    self.switch(&output.text, id);
                }
                out.extend(output);
                return out;
            }
            if Self::interrupted(&body) {
                self.state.busy = false;
                out.push(Record {
                    id: format!("{id}:interrupted"),
                    ..ended()
                });
                return out;
            }
            self.turn = text(root, "promptId").unwrap_or(id).into();
            self.state.busy = true;
            out.push(Record {
                id: format!("{id}:started"),
                kind: RecordKind::TurnStarted,
                ..record.clone()
            });
            let notice = text(root, "promptSource") == Some("system")
                || root.get("origin").and_then(|v| text(v, "kind")) == Some("task-notification");
            let input = (!notice).then(|| Self::input(root, &body)).flatten();
            let attached = if notice || input.is_some() { None } else { attached(message.get("content"), &body) };
            out.push(Record {
                id: format!("{}-{id}", if notice { "notice" } else { "user" }),
                kind: if notice {
                    RecordKind::Notice
                } else {
                    RecordKind::User
                },
                text: if notice {
                    notice_text(&body)
                } else {
                    input.unwrap_or(body)
                },
                attached,
                ..record.clone()
            });
        } else if kind == Some("assistant") && text(message, "role") == Some("assistant") {
            self.configure(root, message, id);
            for (i, b) in blocks.iter().enumerate() {
                match text(*b, "type") {
                    Some("text" | "thinking") => {
                        let thinking = text(*b, "type") == Some("thinking");
                        if let Some(s) = text(*b, if thinking { "thinking" } else { "text" })
                            .filter(|s| !s.is_empty())
                        {
                            out.push(Record {
                                id: format!("claude-{id}-{i}"),
                                kind: if thinking {
                                    RecordKind::Reasoning
                                } else {
                                    RecordKind::Assistant
                                },
                                text: s.into(),
                                title: if thinking {
                                    "Thinking".into()
                                } else {
                                    String::new()
                                },
                                inline_reasoning: thinking,
                                ..record.clone()
                            });
                        }
                    }
                    Some("tool_use") => {
                        if let (Some(call), Some(name)) = (text(*b, "id"), text(*b, "name")) {
                            let body = b
                                .get("input")
                                .and_then(|v| v.write_with(Format::PrettySorted).ok())
                                .and_then(|v| String::from_utf8(v).ok())
                                .unwrap_or_default();
                            let (tool, documents) = b
                                .get("input")
                                .map(|input| crate::tools::project(name, input, text(root, "cwd")))
                                .map(|(tool, documents)| (Some(tool), documents))
                                .unwrap_or_default();
                            out.push(Record {
                                id: format!("tool-{call}"),
                                kind: RecordKind::Tool,
                                text: body,
                                title: name.into(),
                                tool,
                                documents,
                                ..record.clone()
                            });
                        }
                    }
                    _ => {}
                }
            }
            if ["end_turn", "max_tokens", "stop_sequence", "refusal"]
                .contains(&text(message, "stop_reason").unwrap_or(""))
                && blocks.iter().any(|b| text(*b, "type") == Some("text"))
            {
                self.state.busy = false;
                out.push(ended())
            }
        }
        out
    }
}
/// Claude 2.1.302's /model output: "Set model to `Sonnet 5.5` for this session only", "… `Opus 5.5
/// (default)` and saved as your default for new sessions", "… with `low` effort" when the menu
/// changed the effort too. Without that suffix the effort is the new model's default.
pub(crate) fn switched_model(s: &str) -> Option<(String, Option<String>)> {
    let (name, tail) = s.strip_prefix("Set model to `")?.split_once('`')?;
    let name = name.split_once(" (").map_or(name, |(name, _)| name).trim();
    if name.is_empty() {
        return None;
    }
    let model = crate::menu::model(name).unwrap_or_else(|| name.to_owned());
    let effort = tail
        .lines()
        .next()
        .and_then(|line| line.rsplit_once(" with `"))
        .and_then(|(_, level)| level.strip_suffix("` effort"))
        .filter(|level| !level.is_empty() && level.bytes().all(|b| b.is_ascii_lowercase()));
    Some((model, effort.map(str::to_owned)))
}
/// /effort's output: "Set effort level to high (this session only): …", "… xhigh (saved as your
/// default for new sessions): …".
pub(crate) fn switched_effort(s: &str) -> Option<String> {
    let rest = s.strip_prefix("Set effort level to ")?;
    let (level, after) = rest.split_at(rest.find(|c: char| !c.is_ascii_lowercase()).unwrap_or(rest.len()));
    (!level.is_empty() && (after.is_empty() || after.starts_with([' ', ':', '\n']))).then(|| level.to_owned())
}
fn notice_text(s: &str) -> String {
    if !s.starts_with("<task-notification>") {
        return s.into();
    }
    let field = |name: &str| {
        s.split_once(&format!("<{name}>"))?
            .1
            .split_once(&format!("</{name}>"))
            .map(|(s, _)| s.trim())
            .filter(|s| !s.is_empty())
    };
    field("summary")
        .map(str::to_owned)
        .or_else(|| field("status").map(|s| format!("Background task {s}")))
        .unwrap_or_else(|| "Background task finished".into())
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&amp;", "&")
}
fn time(s: &str) -> i64 {
    // ISO8601 timestamps emitted by Claude, measured in UTC milliseconds.
    let n = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let Some((y, m, d, h, min, sec)) = n(0..4)
        .zip(n(5..7))
        .zip(n(8..10))
        .zip(n(11..13))
        .zip(n(14..16))
        .zip(n(17..19))
        .map(|(((((y, m), d), h), min), sec)| (y, m, d, h, min, sec))
    else {
        return 0;
    };
    let y = y - i64::from(m <= 2);
    let era = y.div_euclid(400);
    let year = y - era * 400;
    let days = era * 146097 + year * 365 + year / 4 - year / 100
        + (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5
        + d
        - 1
        - 719468;
    let fraction = s
        .get(19..)
        .and_then(|s| s.strip_prefix('.'))
        .map(|s| {
            s.bytes()
                .take_while(u8::is_ascii_digit)
                .take(3)
                .fold((0, 0), |(v, n), b| (v * 10 + i64::from(b - b'0'), n + 1))
        })
        .unwrap_or((0, 3));
    (days * 86400 + h * 3600 + min * 60 + sec) * 1000 + fraction.0 * 10i64.pow(3 - fraction.1)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SESSION: &str = "6f3a01d7-99c2-420c-81b7-ddec079513d8";

    /// Claude 2.1.302 records a native command's output as a user line.
    fn output(uuid: &str, text: &str) -> String {
        format!(
            r#"{{"parentUuid":null,"isSidechain":false,"type":"user","message":{{"role":"user","content":"<local-command-stdout>{text}</local-command-stdout>"}},"uuid":"{uuid}","timestamp":"2026-10-20T12:29:47.561Z","sessionId":"{SESSION}","version":"2.1.302"}}"#
        ) + "\n"
    }

    fn assistant(uuid: &str, model: &str) -> String {
        format!(
            r#"{{"parentUuid":null,"isSidechain":false,"type":"assistant","message":{{"role":"assistant","model":"{model}","content":[{{"type":"text","text":"hi"}}],"stop_reason":"end_turn"}},"uuid":"{uuid}","timestamp":"2026-10-20T12:30:00.000Z","sessionId":"{SESSION}"}}"#
        ) + "\n"
    }

    #[test]
    fn a_terminal_model_switch_sets_the_model_before_any_reply() {
        let mut parser = Parser::new(SESSION.into());
        let records = parser
            .feed(output("u1", "Set model to `Sonnet 5.5` for this session only").as_bytes())
            .unwrap();
        assert!(records.iter().all(|r| r.kind == RecordKind::Output));
        assert_eq!(parser.state.model.as_deref(), Some("claude-sonnet-5-5"));
        assert_eq!(parser.state.effort, None);
        assert_eq!(parser.configured.as_deref(), Some("u1"));
        assert_eq!(parser.changed.as_deref(), Some("u1"));
    }

    #[test]
    fn a_switch_after_a_reply_replaces_its_model_and_effort() {
        let mut parser = Parser::new(SESSION.into());
        parser.feed(assistant("a1", "claude-opus-5-5").as_bytes()).unwrap();
        parser
            .feed(output("u1", "Set model to `Fable 5.1` for this session only with `xhigh` effort").as_bytes())
            .unwrap();
        assert_eq!(parser.state.model.as_deref(), Some("claude-fable-5-1"));
        assert_eq!(parser.state.effort.as_deref(), Some("xhigh"));
        parser
            .feed(output("u2", "Set model to `Opus 5.5 (default)` and saved as your default for new sessions").as_bytes())
            .unwrap();
        assert_eq!(parser.state.model.as_deref(), Some("claude-opus-5-5"));
        assert_eq!(parser.state.effort, None);
    }

    #[test]
    fn an_effort_switch_keeps_the_model() {
        let mut parser = Parser::new(SESSION.into());
        parser.feed(assistant("a1", "claude-opus-5-5").as_bytes()).unwrap();
        parser
            .feed(
                output(
                    "u1",
                    "Set effort level to high (this session only): Comprehensive implementation with extensive testing and documentation",
                )
                .as_bytes(),
            )
            .unwrap();
        assert_eq!(parser.state.model.as_deref(), Some("claude-opus-5-5"));
        assert_eq!(parser.state.effort.as_deref(), Some("high"));
        assert_eq!(parser.configured.as_deref(), Some("a1"));
        assert_eq!(parser.changed.as_deref(), Some("u1"));
    }

    #[test]
    fn older_system_command_records_switch_too_and_kept_models_do_not() {
        let mut parser = Parser::new(SESSION.into());
        let system = |uuid: &str, text: &str| {
            format!(
                r#"{{"parentUuid":null,"isSidechain":false,"type":"system","subtype":"local_command","content":"<local-command-stdout>{text}</local-command-stdout>","uuid":"{uuid}","timestamp":"2026-10-04T13:49:03.452Z","sessionId":"{SESSION}","version":"2.1.287"}}"#
            ) + "\n"
        };
        parser
            .feed(system("s1", "Set model to `Opus 5.5` for this session only with `medium` effort").as_bytes())
            .unwrap();
        parser.feed(system("s2", "Kept model as `Fable 5.1`").as_bytes()).unwrap();
        assert_eq!(parser.state.model.as_deref(), Some("claude-opus-5-5"));
        assert_eq!(parser.state.effort.as_deref(), Some("medium"));
        assert_eq!(parser.changed.as_deref(), Some("s1"));
    }

    #[test]
    fn an_initial_page_reads_an_earlier_switch_back() {
        let mut parser = Parser::new(SESSION.into());
        assert!(!parser.earlier(output("u1", "Set model to `Haiku 5.5` for this session only with `low` effort").trim_end().as_bytes()));
        assert_eq!(parser.state.model.as_deref(), Some("claude-haiku-5-5"));
        assert_eq!(parser.state.effort.as_deref(), Some("low"));
        // An older model call no longer applies.
        parser.earlier(assistant("a0", "claude-opus-5-5").trim_end().as_bytes());
        assert_eq!(parser.state.model.as_deref(), Some("claude-haiku-5-5"));
    }

    #[test]
    fn switch_outputs() {
        assert_eq!(switched_model("Set model to `my-gateway-model` for this session only"), Some(("my-gateway-model".into(), None)));
        assert_eq!(switched_model("Set model to `Opus 5.5 (1M context)` for this session only"), Some(("claude-opus-5-5".into(), None)));
        // Claude 2.1.28x's styled form names no single model.
        assert_eq!(switched_model("Set model to Default (Opus 5.5 · Best for everyday, complex tasks)"), None);
        assert_eq!(switched_effort("Set effort level to xhigh (saved as your default for new sessions): Deeper"), Some("xhigh".into()));
        assert_eq!(switched_effort("Set effort level to max"), Some("max".into()));
        assert_eq!(switched_effort("Set effort level to "), None);
        assert_eq!(switched_effort("Set effort level to High"), None);
    }

    /// Claude 2.1.302's user line for pasted image paths and text (verified against the loopback
    /// fixture): the text with `[Image #n]` placeholders, then the images' data.
    fn pasted(uuid: &str, text: &str, images: usize) -> String {
        let image = r#"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}"#;
        let quoted = text.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n");
        let mut content = vec![format!(r#"{{"type":"text","text":"{quoted}"}}"#)];
        content.extend(std::iter::repeat_n(image.to_owned(), images));
        format!(
            r#"{{"type":"user","message":{{"role":"user","content":[{}]}},"imagePasteIds":[1,2],"origin":{{"kind":"human"}},"promptSource":"typed","uuid":"{uuid}","timestamp":"2026-10-22T10:00:00.000Z","sessionId":"{SESSION}"}}"#,
            content.join(",")
        ) + "\n"
    }

    /// A user record as a chat.attachments client sees it (core attachments::view).
    fn shown(record: &Record) -> (String, Vec<Block>) {
        let root = std::path::Path::new("/home/sam/.dispatch/attachments");
        match &record.attached {
            Some(attached) => attachment::typed(Some(root), attached.text.as_deref().unwrap_or(&record.text), &attached.images),
            None => (record.text.clone(), record.blocks.clone()),
        }
    }

    #[test]
    fn pasted_images_become_blocks_and_leave_the_typed_text_for_attachment_clients() {
        let file = "/home/sam/.dispatch/attachments/0123456789abcdef0123456789abcdef/notes.txt";
        let mut parser = Parser::new(SESSION.into());
        let typed = format!("[Image #1] [Image #2]Describe these\n\n{file}");
        let records = parser.feed(pasted("u1", &typed, 2).as_bytes()).unwrap();
        let user = records.iter().find(|record| record.kind == RecordKind::User).unwrap();
        // Every other client: the record as before the feature.
        assert_eq!((user.text.clone(), user.blocks.len()), (format!("{typed}\n[Image]\n[Image]"), 0));
        let (text, blocks) = shown(user);
        assert_eq!(text, "Describe these");
        assert_eq!(
            blocks,
            [
                attachment::block(None, None, true),
                attachment::block(None, None, true),
                attachment::block(Some(file), Some("notes.txt"), false),
            ]
        );
        let records = Parser::new(SESSION.into()).feed(pasted("u2", "[Image #3]", 1).as_bytes()).unwrap();
        let user = records.iter().find(|record| record.kind == RecordKind::User).unwrap();
        assert_eq!(user.text, "[Image #3]\n[Image]");
        let (text, blocks) = shown(user);
        assert_eq!((text.as_str(), blocks.len()), ("", 1));
        // A message without attachments is as before, with nothing on the side.
        let records = Parser::new(SESSION.into()).feed(pasted("u3", "hello", 0).as_bytes()).unwrap();
        let user = records.iter().find(|record| record.kind == RecordKind::User).unwrap();
        assert_eq!((user.text.as_str(), user.blocks.len(), user.attached.is_none()), ("hello", 0, true));
    }
}
