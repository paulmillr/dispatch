//! Native payloads stay intact; decoding never establishes process ownership.
use dispatch_helper_core::{
    api::{Error, Hook},
    json::{Json, Value},
};

pub const EVENTS: &[&str] = &[
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "PreCompact",
    "PostCompact",
    "Stop",
    "Interrupt",
    "SubagentStart",
    "SubagentStop",
];

pub fn uuid(text: &str) -> bool {
    let pattern = b"00000000-0000-0000-0000-000000000000";
    text.len() == pattern.len()
        && text.bytes().zip(pattern).all(|(byte, &part)| {
            if part == b'-' {
                byte == part
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

/// No decision: Codex continues with its own UI (the old empty reply).
pub const UNDECIDED: &[u8] = b"{}";

pub fn read(message: &Json) -> Result<Hook, Error> {
    let value = message.root();
    let event = value.get("hook_event_name").and_then(Value::string);
    let session = value.get("session_id").and_then(Value::string);
    match (event, session) {
        (Some(event), Some(session)) if EVENTS.contains(&event) && uuid(session) => {
            let interactive = event == "PermissionRequest"
                || event == "PreToolUse"
                    && value.get("tool_name").and_then(Value::string) == Some("AskUserQuestion");
            Ok(Hook {
                fallback: match interactive {
                    true => UNDECIDED.to_vec(),
                    false => Vec::new(),
                },
                interactive,
                event: event.into(),
                session: Some(session.into()),
                cwd: value.get("cwd").and_then(Value::string).map(Into::into),
                pid: value
                    .get("pid")
                    .and_then(Value::unsigned)
                    .and_then(|pid| pid.try_into().ok()),
                payload: Json::parse(&value.write()?)?,
            })
        }
        _ => Err(Error {
            code: "hook",
            message: "Invalid Codex hook event or session.".into(),
        }),
    }
}
