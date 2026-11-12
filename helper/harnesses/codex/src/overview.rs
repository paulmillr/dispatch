//! chat.list's read of a Codex rollout (`Harness::overview`) and the list pushes
//! (`Harness::listen`): only the rollout's end (core tail.rs), with the records history.rs makes
//! of each line, and none of what a chat's first page does (no follow started, no questions
//! published, no state).
use crate::history::content;
use dispatch_helper_core::{
    json::{Json, Kind, Policy, Value},
    tail::{Classify, Line},
};

fn string<'a>(value: Value<'a>, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::string)
}

/// A rollout line as a list row sees it: whether history.rs makes a record of it and when, its
/// assistant text, and whether it starts or ends a turn.
pub(crate) fn classify(_session: &str) -> Classify {
    Box::new(|line: &[u8]| {
        let mut out = Line::default();
        let Ok(document) = Json::parse_with(line, Policy::Foundation) else { return out };
        let root = document.root();
        let Some(payload) = root.get("payload").filter(|payload| payload.kind() == Kind::Object) else {
            return out;
        };
        let stamp = string(root, "timestamp").and_then(dispatch_helper_core::date::parse);
        let seconds = |key: &str| payload.get(key).and_then(Value::signed).map(|seconds| seconds * 1000).or(stamp);
        let tag = string(payload, "type").unwrap_or("");
        let mut time = Some(stamp);
        match string(root, "type") {
            Some("event_msg") => match tag {
                "task_started" => {
                    time = Some(seconds("started_at"));
                    out.started = seconds("started_at");
                }
                "task_complete" | "turn_aborted" => {
                    time = Some(seconds("completed_at"));
                    out.ended = seconds("completed_at");
                }
                "user_message" => {}
                "agent_message" => out.answer = Some((string(payload, "message").unwrap_or("").into(), stamp)),
                "agent_reasoning" if string(payload, "text").is_some_and(|text| !text.is_empty()) => {}
                "item_completed" => {
                    let Some(item) = payload.get("item") else { return out };
                    match string(item, "type") {
                        Some("EnteredReviewMode") => out.started = stamp,
                        Some("ExitedReviewMode") => out.ended = stamp,
                        Some("UserMessage") => {}
                        Some("AgentMessage") => out.answer = Some((content(item.get("content")), stamp)),
                        Some("Reasoning") => {
                            let empty = item
                                .get("summary_text")
                                .and_then(Value::array)
                                .is_none_or(|mut parts| parts.all(|part| part.string().is_none_or(str::is_empty)));
                            if empty {
                                time = None;
                            }
                        }
                        _ if crate::tools::item(item, false).is_none() => time = None,
                        _ => {}
                    }
                }
                "patch_apply_begin" | "patch_apply_end"
                    if string(payload, "call_id").is_some()
                        && payload.get("changes").and_then(crate::tools::changes).is_some() => {}
                _ => time = None,
            },
            Some("response_item") => match tag {
                "message" if string(payload, "role") == Some("assistant") && string(payload, "channel") != Some("analysis") => {
                    out.answer = Some((content(payload.get("content")), stamp));
                }
                "reasoning" if !content(payload.get("summary")).is_empty() => {}
                "function_call" | "custom_tool_call" | "function_call_output" | "custom_tool_call_output" => {}
                _ => time = None,
            },
            Some("compacted") => {}
            _ => time = None,
        }
        out.time_ms = time.flatten();
        out
    })
}

#[cfg(test)]
#[path = "overview.test.rs"]
mod tests;
