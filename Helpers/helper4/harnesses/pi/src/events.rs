//! Native Pi changes retain the same visible IDs as the saved transcript.
use crate::{
    bridge::Shared,
    records::{self, text},
};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json, Value},
};
use std::rc::Rc;

pub fn interactions(value: Value<'_>) -> Vec<Interaction> {
    match value.get("uiPrompts").and_then(Value::array) {
        Some(prompts) => prompts.filter_map(interaction).collect(),
        None => value
            .get("uiPrompt")
            .and_then(interaction)
            .into_iter()
            .collect(),
    }
}

pub fn publish(
    runtime: &Shared,
    io: &mut dyn Io,
    ui: &mut dyn Ui,
    binding: &Binding,
    document: Json,
) {
    let document = Rc::new(document);
    let root = document.root();
    if text(root, "sessionId") != binding.session {
        return;
    }
    if runtime.borrow().subscribing.contains(&binding.session) {
        return;
    }
    let value = root.get("value").unwrap_or(root);
    match text(root, "event").as_str() {
        "state" => {
            let state = match crate::harness::state(value) {
                Ok(state) => state,
                Err(_) => {
                    invalid(ui, binding);
                    return;
                }
            };
            runtime
                .borrow_mut()
                .states
                .insert(binding.session.clone(), document.clone());
            ui.update(Update::State {
                binding: binding.clone(),
                state,
            });
            let interactive = runtime
                .borrow()
                .registrations
                .get(&binding.process.pid)
                .is_some_and(|record| record.version == "extension-v2");
            if interactive {
                for interaction in interactions(value) {
                    ui.update(Update::Interaction {
                        binding: binding.clone(),
                        interaction,
                    });
                }
            }
            if let Some(partial) = value.get("partial") {
                snapshot(runtime, ui, binding, partial, false);
            }
        }
        "resync" => {
            let _ = crate::bridge::subscribe(runtime, io, binding, true);
        }
        "session_tree" => {
            runtime.borrow_mut().live.remove(&binding.session);
            let saved = runtime.clone();
            let binding = binding.clone();
            crate::history::read(
                runtime,
                io,
                &binding.clone(),
                None,
                Box::new(move |_, result| {
                    if let Ok(page) = result {
                        saved
                            .borrow_mut()
                            .pages
                            .push(Update::History { binding, page });
                    }
                }),
            );
        }
        "message_start" | "message_end" => {
            if let Some(entry) = value.get("entry") {
                let mut turn = value
                    .get("turnId")
                    .and_then(Value::string)
                    .unwrap_or("history")
                    .to_owned();
                let rows = records::project(entry, &mut turn, true);
                if !rows.is_empty() {
                    ui.update(Update::Records {
                        binding: binding.clone(),
                        records: rows,
                    });
                }
            }
        }
        "message_update" => {
            if let Some(block) = value.get("block") {
                let bytes = json::write(&Data::Object(vec![
                    ("type", Data::String("message")),
                    ("id", Data::String(&text(value, "id"))),
                    (
                        "message",
                        Data::Object(vec![
                            ("role", Data::String("assistant")),
                            (
                                "timestamp",
                                value
                                    .get("timestamp")
                                    .map(Data::Value)
                                    .unwrap_or(Data::Null),
                            ),
                            ("content", Data::Array(vec![Data::Value(block)])),
                        ]),
                    ),
                ]));
                if let Ok(bytes) = bytes
                    && let Ok(document) = Json::parse(&bytes)
                {
                    let mut turn = text(value, "turnId");
                    let records = records::project(document.root(), &mut turn, false);
                    {
                        let mut runtime = runtime.borrow_mut();
                        let rows = runtime.live.entry(binding.session.clone()).or_default();
                        for record in &records {
                            if let Some(index) = rows.iter().position(|row| row.id == record.id) {
                                rows[index] = record.clone();
                            } else {
                                rows.push(record.clone());
                            }
                        }
                    }
                    if !records.is_empty() {
                        ui.update(Update::Records {
                            binding: binding.clone(),
                            records,
                        });
                    }
                } else {
                    invalid(ui, binding);
                }
                return;
            }
            let Some(change) = value.get("change") else {
                return;
            };
            let kind = text(change, "type");
            let (kind, field) = match kind.as_str() {
                "text_delta" => (RecordKind::Assistant, "text"),
                "thinking_delta" => (RecordKind::Reasoning, "thinking"),
                _ => return,
            };
            let Some(index) = change.get("contentIndex").and_then(Value::unsigned) else {
                return;
            };
            let id = format!("{}-{index}", text(value, "id"));
            let turn = text(value, "turnId");
            let delta = text(change, "delta");
            let row = {
                let mut runtime = runtime.borrow_mut();
                let rows = runtime.live.entry(binding.session.clone()).or_default();
                let index = rows.iter().position(|row| row.id == id).unwrap_or_else(|| {
                    rows.push(Record {
                        id,
                        turn: Some(turn),
                        kind,
                        text: String::new(),
                        title: if field == "thinking" {
                            "Thinking".into()
                        } else {
                            String::new()
                        },
                        time_ms: value.get("timestamp").and_then(Value::signed).or(Some(0)),
                        ..Record::default()
                    });
                    rows.len() - 1
                });
                rows[index].text.push_str(&delta);
                rows[index].clone()
            };
            ui.update(Update::Records {
                binding: binding.clone(),
                records: vec![row],
            });
        }
        "tool_execution_update" => {
            let Some(result) = value.get("partialResult") else {
                return;
            };
            let id = format!("tool-{}", text(value, "toolCallId"));
            let row = runtime
                .borrow()
                .live
                .get(&binding.session)
                .and_then(|rows| rows.iter().find(|row| row.id == id))
                .cloned();
            if let Some(mut row) = row {
                row.output = records::content(result.get("content"));
                ui.update(Update::Records {
                    binding: binding.clone(),
                    records: vec![row],
                });
            }
        }
        _ => {}
    }
}
fn snapshot(
    runtime: &Shared,
    ui: &mut dyn Ui,
    binding: &Binding,
    partial: Value<'_>,
    complete: bool,
) {
    if partial.kind() == json::Kind::Null {
        return;
    }
    let Some(message) = partial
        .get("message")
        .filter(|message| message.kind() == json::Kind::Object)
    else {
        invalid(ui, binding);
        return;
    };
    let id = text(partial, "id");
    let mut turn = text(partial, "turnId");
    let Ok(bytes) = json::write(&Data::Object(vec![
        ("type", Data::String("message")),
        ("id", Data::String(&id)),
        ("message", Data::Value(message)),
    ])) else {
        invalid(ui, binding);
        return;
    };
    let Ok(document) = Json::parse(&bytes) else {
        invalid(ui, binding);
        return;
    };
    let rows = records::project(document.root(), &mut turn, complete);
    runtime
        .borrow_mut()
        .live
        .insert(binding.session.clone(), rows.clone());
    let mut records = partial
        .get("user")
        .map(|user| records::project(user, &mut turn, true))
        .unwrap_or_default();
    records.extend(rows.into_iter().filter(|row| {
        complete || !matches!(row.kind, RecordKind::TurnEnded | RecordKind::TurnStarted)
    }));
    if !records.is_empty() {
        ui.update(Update::Records {
            binding: binding.clone(),
            records,
        });
    }
}
fn invalid(ui: &mut dyn Ui, binding: &Binding) {
    ui.update(Update::Records {
        binding: binding.clone(),
        records: vec![Record {
            id: "pi-invalid-event".into(),
            kind: RecordKind::Notice,
            title: "Pi Chat".into(),
            text: "Pi returned an invalid Chat response.".into(),
            ..Record::default()
        }],
    });
}
pub fn interaction(prompt: Value<'_>) -> Option<Interaction> {
    let kind = text(prompt, "kind");
    if !["select", "confirm", "input"].contains(&kind.as_str()) {
        return None;
    }
    let id = text(prompt, "id");
    if id.is_empty() {
        return None;
    }
    let values = if kind == "confirm" {
        vec!["Yes".into(), "No".into()]
    } else {
        prompt
            .get("options")
            .and_then(Value::array)
            .into_iter()
            .flatten()
            .filter_map(Value::string)
            .map(str::to_owned)
            .collect()
    };
    let options = values
        .into_iter()
        .enumerate()
        .map(|(index, label)| Choice {
            id: index.to_string(),
            label,
            detail: None,
        })
        .collect();
    Some(Interaction {
        key: None,
        turn: prompt
            .get("turnId")
            .and_then(Value::string)
            .filter(|id| !id.is_empty())
            .map(str::to_owned),
        record: prompt
            .get("toolCallId")
            .and_then(Value::string)
            .filter(|id| !id.is_empty())
            .map(|id| format!("tool-{id}")),
        id: id.clone(),
        approval: kind == "confirm",
        blocking: true,
        questions: vec![Question {
            blocks: Vec::new(),
            id,
            header: text(prompt, "title"),
            text: text(prompt, "message"),
            secret: false,
            options,
            multiple: false,
            custom: kind == "input",
        }],
    })
}
