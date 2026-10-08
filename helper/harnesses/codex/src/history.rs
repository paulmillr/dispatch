//! File-backed common rollout records and exact native row identities.
use crate::questions;
use dispatch_helper_core::{
    api::{Error, Page, Record, RecordKind, State},
    hash::Sha256,
    json::{Json, Kind, Policy, Select, Value},
};

/// The rollout header's session id (`id`, else `session_id`), CLI version and whether a subagent
/// wrote it, from the first complete session_meta line; c1654cc TranscriptReader.swift:87-92 and AgentDiscovery.swift:128-135.
pub fn identity(bytes: &[u8]) -> Option<(String, Option<String>, bool)> {
    bytes.split_inclusive(|byte| *byte == b'\n').find_map(|line| {
        let line = line.strip_suffix(b"\n")?;
        let document = Json::parse_with(line, Policy::Foundation).ok()?;
        let root = document.root();
        if root.get("type")?.string()? != "session_meta" {
            return None;
        }
        let payload = root.get("payload")?;
        let session = payload
            .get("id")
            .and_then(Value::string)
            .or_else(|| payload.get("session_id").and_then(Value::string))?;
        let source = payload.get("source");
        let subagent = source.and_then(Value::string) == Some("subagent")
            || source.and_then(|value| value.get("subagent")).is_some();
        let version = payload.get("cli_version").and_then(Value::string);
        Some((session.into(), version.map(str::to_owned), subagent))
    })
}

/// Text content: a string, or the `text` strings of an array of objects; c1654cc
/// TranscriptParser.content (TranscriptReader.swift:197-200).
pub fn content(value: Option<Value<'_>>) -> String {
    let Some(value) = value else {
        return String::new();
    };
    if let Some(text) = value.string() {
        return text.into();
    }
    let Some(values) = value.array() else {
        return String::new();
    };
    let mut pieces = Vec::new();
    for value in values {
        if value.kind() != Kind::Object {
            return String::new();
        }
        if let Some(text) = value.get("text").and_then(Value::string) {
            pieces.push(text);
        }
    }
    pieces.join("\n")
}

/// Lowercase SHA-256 hex of a line or text; c1654cc ChatRecord.contentKey (TranscriptReader.swift:17-25).
pub fn key(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut hash = Sha256::new();
    hash.update(bytes);
    let digest = hash.finish();
    let mut text = String::with_capacity(digest.len() * 2);
    for byte in digest {
        text.push(DIGITS[usize::from(byte >> 4)] as char);
        text.push(DIGITS[usize::from(byte & 15)] as char);
    }
    text
}

/// The turn a rollout payload names: the first of these fields that is a string; c1654cc
/// CodexTranscriptRecord.swift:37-38, TranscriptReader.swift:157.
pub fn turn<'a>(payload: Value<'a>) -> Option<&'a str> {
    let nested = payload.get("internal_chat_message_metadata_passthrough");
    [
        payload.get("root_turn_id"),
        payload.get("turn_id"),
        nested.and_then(|metadata| metadata.get("turn_id")),
    ]
    .into_iter()
    .flatten()
    .find_map(Value::string)
}

/// The first of duplicate keys, as JSONDecoder reads them (CodexLineMetadata).
fn first<'a>(value: Option<Value<'a>>, key: &str) -> Option<Value<'a>> {
    value?
        .object()?
        .find(|(name, _)| *name == key)
        .map(|(_, value)| value)
}

/// Original CodexLineMetadata projection, shared by routing and activity/configuration probes.
fn metadata(bytes: &[u8]) -> Result<Json, Error> {
    use Select::{Object, Scalar};
    Json::decode(bytes.strip_suffix(b"\n").unwrap_or(bytes), &Object(&[
        ("type", Scalar),
        ("payload", Object(&[
            ("type", Scalar),
            ("root_turn_id", Scalar),
            ("turn_id", Scalar),
            ("internal_chat_message_metadata_passthrough", Object(&[("turn_id", Scalar)])),
        ])),
    ]))
}

/// TranscriptParser.isConfigurationRecord (TranscriptPaging.swift:69-75): a turn_context or a
/// thread_settings_applied line, whether or not it names a model.
pub fn configurable(bytes: &[u8]) -> bool {
    let Ok(document) = metadata(bytes) else {
        return false;
    };
    let root = Some(document.root());
    let text = |value, key| first(value, key).and_then(Value::string);
    match text(root, "type") {
        Some("turn_context") => true,
        Some("event_msg") => {
            text(first(root, "payload"), "type") == Some("thread_settings_applied")
        }
        _ => false,
    }
}

/// TranscriptParser.isActivityRecord (TranscriptPaging.swift:76-82): a turn marker line, and
/// whether it starts the turn.
pub fn activity(bytes: &[u8]) -> Option<bool> {
    let document = metadata(bytes).ok()?;
    let root = Some(document.root());
    let text = |value, key| first(value, key).and_then(Value::string);
    if text(root, "type") != Some("event_msg") {
        return None;
    }
    match text(first(root, "payload"), "type")? {
        "task_started" => Some(true),
        "task_complete" | "turn_aborted" => Some(false),
        _ => None,
    }
}

/// The model, effort and service tier a configuration line sets (TranscriptReader.swift:97-99,108-111): a
/// turn_context needs a non-empty model and sets the `effort` beside it; applied settings need
/// this thread and a model, and prefer `reasoning_effort` (ChatAgentSettings,
/// ChatCommands.swift:51-53). Other lines change nothing.
pub fn configure(root: Value<'_>, session: &str, state: &mut State) {
    fn text<'a>(value: Option<Value<'a>>, key: &str) -> Option<&'a str> {
        value?.get(key).and_then(Value::string)
    }
    let payload = root.get("payload");
    let applied = match root.get("type").and_then(Value::string) {
        Some("turn_context") => text(payload, "model")
            .filter(|model| !model.is_empty())
            .map(|model| (model, text(payload, "effort"), None, payload)),
        Some("event_msg")
            if text(payload, "type") == Some("thread_settings_applied")
                && text(payload, "thread_id") == Some(session) =>
        {
            let settings = payload.and_then(|payload| payload.get("thread_settings"));
            let effort = text(settings, "reasoning_effort").or(text(settings, "effort"));
            let tier = Some(text(settings, "service_tier"));
            text(settings, "model").map(|model| (model, effort, tier, settings))
        }
        _ => None,
    };
    if let Some((model, effort, tier, settings)) = applied {
        state.model = Some(model.into());
        state.effort = effort.map(str::to_owned);
        if let Some(mode) = text(settings.and_then(|value| value.get("collaboration_mode")), "mode") {
            state.mode = Some(mode.into());
        }
        // Applied settings carry the service tier (ChatAgentSettings.serviceTier); a turn_context
        // leaves it.
        if let Some(tier) = tier {
            state.service_tier = tier.map(str::to_owned);
        }
    }
}

/// An explicit event changes this conversation's goal; other lines preserve it.
fn goal(root: Value<'_>, session: &str, state: &mut State) {
    if root.get("type").and_then(Value::string) == Some("event_msg")
        && let Some(payload) = root.get("payload")
        && payload.get("type").and_then(Value::string) == Some("thread_goal_updated")
        && payload.get("threadId").and_then(Value::string) == Some(session)
        && let Some(value) = payload.get("goal")
    {
        if value.kind() == Kind::Null {
            state.goal = None;
        } else if let Some(goal) = crate::native::goal(value) {
            state.goal = Some(goal);
        }
    }
}

/// A line's turn context: its turn id and whether it starts that turn (task_started);
/// c1654cc TranscriptPaging.swift:45-66,83-90. CodexLineMetadata decodes with JSONDecoder, which
/// keeps the first of duplicate keys (records keep the last, JSONSerialization).
pub fn context(bytes: &[u8]) -> Option<(String, bool)> {
    let document = metadata(bytes).ok()?;
    let payload = first(Some(document.root()), "payload");
    let nested = first(payload, "internal_chat_message_metadata_passthrough");
    let turn = [
        first(payload, "root_turn_id"),
        first(payload, "turn_id"),
        first(nested, "turn_id"),
    ]
    .into_iter()
    .flatten()
    .find_map(Value::string)?;
    let starts = first(payload, "type").and_then(Value::string) == Some("task_started");
    Some((turn.into(), starts))
}

/// Page records, state, the async questions this recent window still leaves open, and its raw
/// count of user/assistant/reasoning records (the old readEarlier's visible items). `context` is
/// the turn the page begins in (TranscriptPage.read's beginPage), else "history".
pub fn page<'a>(
    lines: impl IntoIterator<Item = (u64, &'a [u8])>,
    session: &str,
    context: Option<&str>,
) -> Result<(Page, State, questions::Pending, usize), Error> {
    let mut page = Page::default();
    // Execution process ids link long-running Code Mode requests (orchestration.rs).
    let mut process = std::collections::BTreeMap::new();
    let mut questions = questions::Pending::default();
    let mut state = State::default();
    let mut visible = 0;
    let mut compatible = true;
    let mut turn = context.unwrap_or("history").to_owned();
    // A review keeps its records on the turn that entered it; c1654cc TranscriptReader.swift:59,144-150.
    let mut review: Option<String> = None;
    // Prompts repeat as event_msg and item_completed: their content key is computed once.
    let mut prompt: Option<(String, String)> = None;
    let mut user = |text: &str| match &prompt {
        Some((last, id)) if last == text => id.clone(),
        _ => {
            let id = "user-".to_owned() + &key(text.as_bytes());
            prompt = Some((text.to_owned(), id.clone()));
            id
        }
    };
    let mut each = |start: u64, bytes: &[u8]| -> Result<(), Error> {
        {
            let Ok(document) = Json::parse_with(bytes, Policy::Foundation) else {
                return Ok(());
            };
            let root = document.root();
            if root.get("type").and_then(Value::string) == Some("session_meta") {
                compatible = root.get("payload").and_then(|payload|
                    payload.get("id").and_then(Value::string)
                        .or_else(|| payload.get("session_id").and_then(Value::string)))
                    .is_some_and(|id| !id.trim().is_empty());
                return Ok(());
            }
            if !compatible {
                return Ok(());
            }
            questions.rollout(root, session);
            if root.get("type").and_then(Value::string) == Some("event_msg")
                && let Some(payload) = root.get("payload")
                && payload.get("type").and_then(Value::string) == Some("token_count")
                && let Some(usage) = crate::native::usage(payload)
            {
                state.usage = Some(usage);
            }
            configure(root, session, &mut state);
            goal(root, session, &mut state);
            let payload = root.get("payload");
            if let Some(value) = payload.and_then(self::turn) {
                turn = value.into();
            }
            if let Some(review) = &review {
                turn = review.clone();
            }
            // The line key is computed only for kept records without a native id
            // (TranscriptReader.swift:66-67 hashes after dropping ignored lines).
            // The line's time: a turn read from history keeps when it really started and ended.
            let mut record = Record {
                turn: Some(turn.clone()),
                kind: RecordKind::Notice,
                time_ms: root
                    .get("timestamp")
                    .and_then(Value::string)
                    .and_then(dispatch_helper_core::date::parse),
                ..Record::default()
            };
            // c1654cc TranscriptReader.swift:90-195 (TranscriptParser's JSONSerialization path; its
            // selective decoder returns the same records, YYJSONTranscriptTests): a record needs
            // a string type and an object payload.
            fn string<'a>(value: Value<'a>, key: &str) -> Option<&'a str> {
                value.get(key).and_then(Value::string)
            }
            let Some(payload) = payload.filter(|payload| payload.kind() == Kind::Object) else {
                return Ok(());
            };
            let tag = string(payload, "type").unwrap_or("");
            match root.get("type").and_then(Value::string) {
                Some("event_msg") => match tag {
                    // The turn's native times (Unix seconds), as live.rs reports turn/started and
                    // turn/completed: the line's millisecond timestamp would sort a reloaded turn
                    // after a later live turn that started within the same second.
                    "task_started" => {
                        state.busy = true;
                        record.kind = RecordKind::TurnStarted;
                        if let Some(seconds) = payload.get("started_at").and_then(Value::signed) {
                            record.time_ms = Some(seconds * 1000);
                        }
                    }
                    "task_complete" | "turn_aborted" => {
                        state.busy = false;
                        record.kind = RecordKind::TurnEnded;
                        if let Some(seconds) = payload.get("completed_at").and_then(Value::signed) {
                            record.time_ms = Some(seconds * 1000);
                        }
                    }
                    "user_message" | "agent_message" => {
                        record.text = string(payload, "message").unwrap_or("").into();
                        if tag == "user_message" {
                            record.kind = RecordKind::User;
                            record.id = user(&record.text);
                        } else {
                            record.kind = RecordKind::Assistant;
                        }
                    }
                    "agent_reasoning" => {
                        let Some(text) = string(payload, "text").filter(|text| !text.is_empty())
                        else {
                            return Ok(());
                        };
                        record.kind = RecordKind::Reasoning;
                        record.text = text.into();
                        record.title = "Reasoning summary".into();
                    }
                    "item_completed" => {
                        let Some(item) = payload.get("item") else {
                            return Ok(());
                        };
                        match item.get("type").and_then(Value::string) {
                            Some("EnteredReviewMode") => {
                                review = Some(turn.clone());
                                state.busy = true;
                                record.kind = RecordKind::TurnStarted;
                            }
                            Some("ExitedReviewMode") => {
                                review = None;
                                state.busy = false;
                                record.kind = RecordKind::TurnEnded;
                            }
                            Some(kind @ ("UserMessage" | "AgentMessage")) => {
                                record.text = content(item.get("content"));
                                if kind == "UserMessage" {
                                    record.kind = RecordKind::User;
                                    record.id = user(&record.text);
                                } else {
                                    record.kind = RecordKind::Assistant;
                                    if let Some(id) = item.get("id").and_then(Value::string) {
                                        record.id = id.into();
                                    }
                                }
                            }
                            Some("Reasoning") => {
                                record.text = item
                                    .get("summary_text")
                                    .and_then(Value::array)
                                    .map(|parts| {
                                        parts
                                            .filter_map(Value::string)
                                            .collect::<Vec<_>>()
                                            .join("\n")
                                    })
                                    .unwrap_or_default();
                                if record.text.is_empty() {
                                    return Ok(());
                                }
                                record.kind = RecordKind::Reasoning;
                                record.title = "Reasoning summary".into();
                                if let Some(id) = item.get("id").and_then(Value::string) {
                                    record.id = id.into();
                                }
                            }
                            _ => {
                                let Some(value) = crate::tools::item(item, false) else {
                                    return Ok(());
                                };
                                record = value;
                                record.turn = Some(turn.clone());
                                if let Some(id) = item.get("process_id").and_then(Value::string) {
                                    process.insert(record.id.clone(), id.to_owned());
                                }
                            }
                        }
                    }
                    "patch_apply_begin" | "patch_apply_end" => {
                        let Some(id) = payload.get("call_id").and_then(Value::string) else {
                            return Ok(());
                        };
                        let Some(documents) =
                            payload.get("changes").and_then(crate::tools::changes)
                        else {
                            return Ok(());
                        };
                        record.id = crate::tools::record(id);
                        record.kind = RecordKind::Tool;
                        record.title = "apply_patch".into();
                        record.documents = documents;
                        let status = payload.get("status").and_then(Value::string).unwrap_or(
                            if payload.get("success").and_then(Value::boolean) == Some(false) {
                                "failed"
                            } else {
                                "completed"
                            },
                        );
                        record.completed = tag == "patch_apply_end"
                            && matches!(status, "completed" | "failed" | "declined");
                        record.exit_code = (tag == "patch_apply_end"
                            && matches!(status, "failed" | "declined"))
                        .then_some(1);
                        record.patch = Some(if tag == "patch_apply_begin" {
                            "applying".into()
                        } else {
                            crate::tools::status(status, false)
                        });
                        record.output = ["stdout", "stderr"]
                            .into_iter()
                            .filter_map(|key| payload.get(key).and_then(Value::string))
                            .collect::<Vec<_>>()
                            .join("\n");
                    }
                    _ => return Ok(()),
                },
                Some("response_item") => {
                    let id = string(payload, "id");
                    match tag {
                        "message" => {
                            if string(payload, "role") != Some("assistant")
                                || string(payload, "channel") == Some("analysis")
                            {
                                return Ok(());
                            }
                            record.kind = RecordKind::Assistant;
                            record.id = id.unwrap_or_default().into();
                            record.text = content(payload.get("content"));
                        }
                        "reasoning" => {
                            record.text = content(payload.get("summary"));
                            if record.text.is_empty() {
                                return Ok(());
                            }
                            record.kind = RecordKind::Reasoning;
                            record.id = id.unwrap_or_default().into();
                            record.title = "Reasoning summary".into();
                        }
                        "function_call"
                        | "custom_tool_call"
                        | "function_call_output"
                        | "custom_tool_call_output" => {
                            let id = string(payload, "call_id").or(id);
                            record.id =
                                crate::tools::record(&id.map_or_else(|| key(bytes), str::to_owned));
                            record.kind = RecordKind::Tool;
                            let printable = |value: Option<Value<'_>>| {
                                value.map(crate::tools::printable).unwrap_or_default()
                            };
                            record.completed = tag.ends_with("_output");
                            if record.completed {
                                record.output = printable(payload.get("output"));
                            } else {
                                record.text = printable(
                                    payload.get("arguments").or_else(|| payload.get("input")),
                                );
                                record.title = string(payload, "name").unwrap_or("Tool").into();
                            }
                        }
                        _ => return Ok(()),
                    }
                }
                // c1654cc ChatCoordinator.swift:1131-1132: the line key names this notice.
                Some("compacted") => record.text = "Conversation compacted".into(),
                _ => return Ok(()),
            }
            if record.kind == RecordKind::TurnEnded {
                for item in &mut page.records {
                    if item.turn == record.turn && item.patch.is_some() && !item.completed {
                        item.patch = Some("interrupted".into());
                        item.completed = true;
                        crate::tools::decorate(item);
                    }
                }
            }
            if record.id.is_empty() {
                record.id = key(bytes);
            }
            if matches!(
                record.kind,
                RecordKind::User | RecordKind::Assistant | RecordKind::Reasoning
            ) {
                visible += 1;
            }
            // One native item can be written twice (response_item and item_completed); keep
            // its first position like the old app's merge by id, within its turn.
            if let Some(index) = page.records.iter().position(|previous| {
                previous.kind == record.kind
                    && previous.id == record.id
                    && previous.turn == record.turn
            }) {
                let previous = &page.records[index];
                if record.text.is_empty() {
                    record.text = previous.text.clone();
                }
                if record.title.is_empty() {
                    record.title = previous.title.clone();
                }
                if record.output.is_empty() {
                    record.output = previous.output.clone();
                }
                record.completed |= previous.completed;
                let preview = matches!(record.patch.as_deref(), Some("generating" | "applying"));
                if record.patch.is_none()
                    || preview
                        && (previous.completed
                            || previous.patch.as_deref() == Some("applying")
                                && record.patch.as_deref() == Some("generating"))
                {
                    record.patch = previous.patch.clone();
                    if previous.patch.is_some() {
                        record.documents = previous.documents.clone();
                    } else if preview && previous.completed {
                        record.patch = Some(
                            if previous.exit_code.is_none_or(|code| code == 0) {
                                "completed"
                            } else {
                                "failed"
                            }
                            .into(),
                        );
                    }
                }
                if previous.patch.is_some() {
                    record.title = "apply_patch".into();
                }
                if record.documents.is_empty() {
                    record.documents = previous.documents.clone();
                }
                if record.exit_code.is_none() {
                    record.exit_code = previous.exit_code;
                }
                record.time_ms = previous.time_ms.or(record.time_ms);
                crate::tools::decorate(&mut record);
                page.records[index] = record;
                return Ok(());
            }
            crate::tools::decorate(&mut record);
            if page.records.len() == 400 {
                page.records.remove(0);
                page.earlier = Some(start.to_string());
            }
            page.records.push(record);
            Ok(())
        }
    };
    for (start, bytes) in lines {
        each(start, bytes)?;
    }
    // c1654cc ChatModels.swift:418: each turn shows its coalesced Code Mode wrappers.
    page.records = crate::orchestration::coalesce(page.records, &process);
    Ok((page, state, questions, visible))
}

/// Complete lines appended at `offset` while turn `turn` runs, applied to `state` the way the old
/// TranscriptReader.read followed a chat (TranscriptReader.swift:323-334): their records; busy from
/// the last turn marker; each configuration replaces model and effort, a missing effort included
/// (old applyConfiguration, ChatModels.swift:861-865); usage from the lines. Returns the records,
/// the bytes consumed and the turn after them.
pub fn appended(
    bytes: &[u8],
    offset: u64,
    session: &str,
    turn: Option<String>,
    state: &mut State,
) -> Result<(Vec<Record>, u64, Option<String>, questions::Pending), Error> {
    let complete = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |index| index + 1);
    // An unfinished line of LINE bytes or more is skipped, as core's reverse reader drops it; the
    // rest of it then reads as one unreadable line.
    if complete == 0 && bytes.len() as u64 >= LINE {
        return Ok((
            Vec::new(),
            bytes.len() as u64,
            turn,
            questions::Pending::default(),
        ));
    }
    let chunk = &bytes[..complete];
    let (page, read, recovered, _) = page(lines(chunk, offset), session, turn.as_deref())?;
    if let Some(marker) = page
        .records
        .iter()
        .rev()
        .find(|record| matches!(record.kind, RecordKind::TurnStarted | RecordKind::TurnEnded))
    {
        state.busy = marker.kind == RecordKind::TurnStarted;
    }
    for (_, line) in lines(chunk, offset) {
        if let Ok(document) = Json::parse_with(line, Policy::Foundation) {
            goal(document.root(), session, state);
            if configurable(line) {
                configure(document.root(), session, state);
            }
        }
    }
    state.usage = read.usage.or(state.usage.take());
    let after = chunk
        .split_inclusive(|byte| *byte == b'\n')
        .rev()
        .find_map(context)
        .map(|(turn, _)| turn)
        .or(turn);
    Ok((page.records, complete as u64, after, recovered))
}

/// The longest rollout line read (core rpc::Reverse limit of the history pages); longer ones are
/// skipped.
pub const LINE: u64 = 4_194_304;

/// The complete lines of a chunk that starts at `offset`, each with its file offset.
pub fn lines(bytes: &[u8], offset: u64) -> impl Iterator<Item = (u64, &[u8])> {
    let complete = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |end| end + 1);
    let mut start = offset;
    bytes[..complete]
        .split_inclusive(|byte| *byte == b'\n')
        .map(move |line| {
            let at = start;
            start += line.len() as u64;
            (at, &line[..line.len() - 1])
        })
}
