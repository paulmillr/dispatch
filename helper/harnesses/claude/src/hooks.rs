//! Native hook and private stdio requests. User decisions are supplied by the app.
use crate::history::{error, text, uuid};
use dispatch_helper_core::{
    api::*,
    grapheme,
    json::{self, Data, Format, Json, Kind, Value},
};
use std::collections::BTreeMap;

pub struct Request {
    pub interaction: Interaction,
    pub session: Option<String>,
    doc: Json,
    side: bool,
}
fn object<'a>(v: Value<'a>, key: &str) -> Result<Value<'a>, Error> {
    v.get(key)
        .filter(|v| v.kind() == Kind::Object)
        .ok_or_else(|| error("shape", key))
}
fn string(v: Value<'_>, key: &str, limit: usize, empty: bool) -> Result<String, Error> {
    text(v, key)
        .filter(|s| s.len() <= limit && !s.contains('\0') && (empty || !s.trim().is_empty()))
        .map(str::to_owned)
        .ok_or_else(|| error("shape", key))
}
fn printable(value: Value<'_>) -> Result<String, Error> {
    String::from_utf8(value.write_with(Format::PrettySorted)?).map_err(|issue| error("json", issue))
}
impl Request {
    pub fn new(doc: Json) -> Result<Self, Error> {
        let root = doc.root();
        let side = text(root, "type") == Some("control_request");
        let (request, input, id, session) = if side {
            let request = object(root, "request")?;
            if text(request, "subtype") != Some("can_use_tool") {
                return Err(error("unsupported", "Claude control request"));
            }
            (
                request,
                object(request, "input")?,
                string(root, "request_id", 4096, false)?,
                None,
            )
        } else {
            let session = string(root, "session_id", 36, false)?;
            if !uuid(&session)
                || root.get("agent_id").is_some()
                || root.get("agent_type").is_some()
                || !["PermissionRequest", "PreToolUse"]
                    .contains(&text(root, "hook_event_name").unwrap_or(""))
            {
                return Err(error("shape", "Claude permission hook"));
            }
            let input = object(root, "tool_input")?;
            let id = match text(root, "tool_use_id") {
                Some(call) => call.to_owned(),
                None => format!(
                    "{}\n{}",
                    string(root, "tool_name", 4096, false)?,
                    printable(input)?
                ),
            };
            (root, input, format!("{session}:{id}"), Some(session))
        };
        let tool = string(request, "tool_name", 4096, false)?;
        let questions = tool == "AskUserQuestion"
            && (side || text(root, "hook_event_name") == Some("PreToolUse"));
        let mut rows = Vec::new();
        if questions {
            if input.write()?.len() > 65_536
                || input
                    .object()
                    .unwrap()
                    .any(|(k, _)| !["questions", "answers", "annotations", "metadata"].contains(&k))
            {
                return Err(error("shape", "Question input"));
            }
            for key in ["answers", "annotations"] {
                if let Some(v) = input.get(key) {
                    if !v.object().is_some_and(|mut v| v.next().is_none()) {
                        return Err(error("shape", key));
                    }
                }
            }
            if let Some(v) = input.get("metadata") {
                if !v.object().is_some_and(|mut v| {
                    v.all(|(k, v)| k == "source" && v.string().is_some_and(|s| s.len() <= 1024))
                }) {
                    return Err(error("shape", "metadata"));
                }
            }
            for q in input
                .get("questions")
                .and_then(|v| v.array())
                .ok_or_else(|| error("shape", "questions"))?
            {
                let title = string(q, "question", 4096, false)?;
                let header = string(q, "header", 128, false)?;
                let mut options = Vec::new();
                for o in q
                    .get("options")
                    .and_then(|v| v.array())
                    .ok_or_else(|| error("shape", "options"))?
                {
                    let label = string(o, "label", 512, false)?;
                    let description = if o.get("description").is_some() {
                        Some(string(o, "description", 4096, true)?)
                    } else {
                        None
                    };
                    let preview = if o.get("preview").is_some() {
                        Some(string(o, "preview", 16384, true)?)
                    } else {
                        None
                    };
                    if options.iter().any(|o: &Choice| o.label == label) {
                        return Err(error("shape", "Duplicate option"));
                    }
                    options.push(Choice {
                        id: label.clone(),
                        label,
                        detail: match (description, preview) {
                            (Some(a), Some(b)) => Some(a + "\n\n" + &b),
                            (a, b) => a.or(b),
                        },
                    });
                }
                if !(2..=4).contains(&options.len())
                    || rows.iter().any(|q: &Question| q.id == title)
                {
                    return Err(error("shape", "Question choices"));
                }
                let multiple = q
                    .get("multiSelect")
                    .map(|v| v.boolean().ok_or_else(|| error("shape", "multiSelect")))
                    .transpose()?
                    .unwrap_or(false);
                rows.push(Question {
                    blocks: Vec::new(),
                    id: title.clone(),
                    header,
                    text: title,
                    secret: false,
                    options,
                    multiple,
                    custom: true,
                });
            }
            if !(1..=4).contains(&rows.len()) {
                return Err(error("shape", "Question count"));
            }
        } else {
            if !side && text(root, "hook_event_name") != Some("PermissionRequest") {
                return Err(error("shape", "Unrecognized permission hook"));
            }
            let display = printable(if side { request } else { input })?;
            // e076fd7 ChatSideConversation.swift:79-84: the side card shows the whole request or
            // the side denies it (at most 32 768 Characters).
            if side && (display.is_empty() || grapheme::count(&display) > 32_768) {
                return Err(error(
                    "limit",
                    "Side permission request is too large to display",
                ));
            }
            let operation = if side {
                display
            } else {
                format!("{tool}\n{display}")
            };
            rows.push(Question {
                blocks: vec![Block::Code {
                    language: "json".into(),
                    text: operation.clone(),
                }],
                id: "approval".into(),
                header: tool.clone(),
                text: operation,
                secret: false,
                options: ["Allow", "Deny", "Terminal"]
                    .map(|s| Choice {
                        id: s.into(),
                        label: s.into(),
                        detail: None,
                    })
                    .to_vec(),
                multiple: false,
                custom: false,
            });
        }
        Ok(Self {
            interaction: Interaction {
                key: None,
                turn: None,
                record: text(request, "tool_use_id").map(|call| format!("tool-{call}")),
                id,
                approval: !questions,
                blocking: true,
                questions: rows,
            },
            session,
            doc,
            side,
        })
    }
    pub fn answer(&self, answers: Vec<(String, Answer)>) -> Result<Vec<u8>, Error> {
        let root = self.doc.root();
        let input = if self.side {
            object(object(root, "request")?, "input")?
        } else {
            object(root, "tool_input")?
        };
        let denied = answers.iter().any(|(_, a)| *a == Answer::Skip);
        let mut values = BTreeMap::new();
        for (id, answer) in &answers {
            let q = self
                .interaction
                .questions
                .iter()
                .find(|q| q.id == *id)
                .ok_or_else(|| error("invalid", "Question id"))?;
            let value = match answer {
                Answer::Text(v) => v.clone(),
                Answer::Options(v) => {
                    if v.iter().any(|i| *i >= q.options.len()) || !q.multiple && v.len() != 1 {
                        return Err(error("invalid", "Answer choices"));
                    }
                    q.options
                        .iter()
                        .enumerate()
                        .filter(|(i, _)| v.contains(i))
                        .map(|(_, o)| o.label.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                }
                Answer::Skip => String::new(),
            };
            if !denied && (value.trim().is_empty() || value.len() > 8192 || value.contains('\0'))
                || values.insert(id.clone(), value).is_some()
            {
                return Err(error("invalid", "Answer"));
            }
        }
        if values.len() != self.interaction.questions.len() && !denied {
            return Err(error("invalid", "Answer every question"));
        }
        let approval = self.interaction.approval;
        let action = if approval {
            match values.get("approval").map(String::as_str) {
                Some("Allow") => "allow",
                Some("Deny") => "deny",
                Some("Terminal") => "terminal",
                _ if denied => "terminal",
                _ => return Err(error("invalid", "Approval")),
            }
        } else if denied {
            "deny"
        } else {
            "allow"
        };
        if action == "terminal" && !self.side {
            return json::write(&Data::Object(Vec::new()));
        }
        let fields = values
            .iter()
            .map(|(k, v)| (k.as_str(), Data::String(v)))
            .collect();
        let mut updated = input
            .object()
            .unwrap()
            .filter(|(k, _)| *k != "answers")
            .map(|(k, v)| (k, Data::Value(v)))
            .collect::<Vec<_>>();
        if !approval {
            updated.push(("answers", Data::Object(fields)))
        }
        let reason = if approval {
            "Permission denied."
        } else {
            "The user skipped these questions."
        };
        let decision = if self.side {
            let mut v = vec![(
                "behavior",
                Data::String(if action == "allow" { "allow" } else { "deny" }),
            )];
            v.push(if action == "allow" {
                ("updatedInput", Data::Object(updated))
            } else {
                ("message", Data::String(reason))
            });
            Data::Object(v)
        } else if approval {
            Data::Object(vec![("behavior", Data::String(action))])
        } else {
            Data::Object(vec![
                ("hookEventName", Data::String("PreToolUse")),
                ("permissionDecision", Data::String(action)),
                if denied {
                    ("permissionDecisionReason", Data::String(reason))
                } else {
                    ("updatedInput", Data::Object(updated))
                },
            ])
        };
        if self.side {
            return control(text(root, "request_id").unwrap(), decision);
        }
        let reply = if approval {
            Data::Object(vec![(
                "hookSpecificOutput",
                Data::Object(vec![
                    ("hookEventName", Data::String("PermissionRequest")),
                    ("decision", decision),
                ]),
            )])
        } else {
            Data::Object(vec![("hookSpecificOutput", decision)])
        };
        json::write(&reply)
    }
}

/// One stdio control reply for an owned side; c1654cc ChatSideConversation.swift:415-421.
pub(crate) fn control(id: &str, decision: Data<'_>) -> Result<Vec<u8>, Error> {
    json::write(&Data::Object(vec![
        ("type", Data::String("control_response")),
        (
            "response",
            Data::Object(vec![
                ("subtype", Data::String("success")),
                ("request_id", Data::String(id)),
                ("response", decision),
            ]),
        ),
    ]))
}
