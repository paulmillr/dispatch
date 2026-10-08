//! Native assistant deltas and snapshots share the existing side append policy.
use crate::{channel::failure, history};
use dispatch_helper4_core::{
    api::{Error, Record, RecordKind},
    json::{self, Data, Json, Value},
};

/// The record kinds this stream sends; a followed rollout supplies the others (c1654cc read every
/// text record, reasoning summaries included, from the rollout).
pub const KINDS: [RecordKind; 5] = [
    RecordKind::TurnStarted,
    RecordKind::TurnEnded,
    RecordKind::User,
    RecordKind::Assistant,
    RecordKind::Tool,
];

#[derive(Default)]
pub struct Live {
    pub records: Vec<Record>,
    pub active: Option<bool>,
}

impl Live {
    pub fn read(&mut self, method: &str, params: Value<'_>) -> Result<Vec<Record>, Error> {
        if method == "thread/status/changed" {
            match params.get("status").and_then(|status| status.get("type")).and_then(Value::string) {
                Some("active") => self.active = Some(true),
                Some("idle") => self.active = Some(false),
                _ => {}
            }
        }
        if matches!(method, "turn/started" | "turn/completed") {
            let turn = params.get("turn");
            let Some(id) = turn.and_then(|turn| turn.get("id")).and_then(Value::string) else {
                return Ok(Vec::new());
            };
            let started = method == "turn/started";
            // The turn's own native times (Unix seconds): a resumed snapshot replays an earlier
            // turn, which must not start or end when it arrives.
            let at = turn
                .and_then(|turn| turn.get(if started { "startedAt" } else { "completedAt" }))
                .and_then(Value::signed)
                .map(|seconds| seconds * 1000);
            let row = Record {
                id: format!("{method}:{id}"),
                turn: Some(id.into()),
                kind: if started {
                    RecordKind::TurnStarted
                } else {
                    RecordKind::TurnEnded
                },
                time_ms: at,
                ..Record::default()
            };
            if !self.records.iter().any(|previous| previous.id == row.id) {
                self.records.push(row.clone());
            }
            return Ok(vec![row]);
        }
        let turn = params
            .get("turnId")
            .and_then(Value::string)
            .map(str::to_owned);
        let row = if matches!(method, "item/started" | "item/completed") {
            params
                .get("item")
                .and_then(|item| crate::tools::item(item, method == "item/started"))
        } else if method == "item/fileChange/patchUpdated" {
            params.get("itemId").and_then(Value::string).and_then(|id| {
                params
                    .get("changes")
                    .and_then(|changes| crate::tools::change(id, changes, "generating".into()))
            })
        } else {
            None
        };
        if let Some(mut row) = row {
            row.turn = turn;
            if let Some(previous) = self
                .records
                .iter_mut()
                .find(|previous| previous.id == row.id)
            {
                // A late resume snapshot never reopens an item this stream already completed.
                if previous.completed && !row.completed {
                    return Ok(Vec::new());
                }
                *previous = row.clone();
            } else {
                self.records.push(row.clone());
            }
            return Ok(vec![row]);
        }
        if matches!(method, "item/started" | "item/completed")
            && let Some(item) = params.get("item")
            && item.get("type").and_then(Value::string) == Some("userMessage")
            && let Some(content) = item.get("content").and_then(Value::array)
        {
            let text = content
                .filter_map(|part| part.get("text").and_then(Value::string))
                .collect::<Vec<_>>()
                .join("\n");
            let row = Record {
                id: "user-".to_owned() + &history::key(text.as_bytes()),
                turn,
                kind: RecordKind::User,
                text,
                ..Record::default()
            };
            if !self.records.iter().any(|previous| previous.id == row.id) {
                self.records.push(row.clone());
            }
            return Ok(vec![row]);
        }
        let (id, text, replace) = if method == "item/agentMessage/delta" {
            let Some(id) = params.get("itemId").and_then(Value::string) else {
                return Ok(Vec::new());
            };
            let Some(text) = params.get("delta").and_then(Value::string) else {
                return Ok(Vec::new());
            };
            (id, text, false)
        } else if method == "item/completed"
            && let Some(item) = params.get("item")
            && item.get("type").and_then(Value::string) == Some("agentMessage")
            && let Some(id) = item.get("id").and_then(Value::string)
            && let Some(text) = item.get("text").and_then(Value::string)
        {
            (id, text, true)
        } else {
            return Ok(Vec::new());
        };
        if text.len() > 1_048_576 {
            return Err(failure(
                "capacity",
                "Side reply exceeded the display limit.",
            ));
        }
        if let Some(row) = self.records.iter_mut().find(|row| row.id == id) {
            if replace {
                row.text = text.into();
                row.completed = true;
            } else if row.text.len() + text.len() <= 1_048_576 {
                row.text.push_str(text);
            }
            return Ok(vec![row.clone()]);
        }
        let row = Record {
            id: id.into(),
            turn,
            kind: RecordKind::Assistant,
            text: text.into(),
            completed: replace,
            ..Record::default()
        };
        self.records.push(row.clone());
        Ok(vec![row])
    }

    /// The turn this stream shows running: started and not yet ended, whatever order the frames
    /// arrived in (a resume snapshot can be applied after newer notifications).
    pub fn running(&self) -> Option<String> {
        if self.active == Some(false) {
            return None;
        }
        let ended = |turn: &Option<String>| {
            self.records
                .iter()
                .any(|record| record.kind == RecordKind::TurnEnded && record.turn == *turn)
        };
        let started = self.records.iter().rev();
        let mut started = started.filter(|record| record.kind == RecordKind::TurnStarted);
        started.find(|record| !ended(&record.turn))?.turn.clone()
    }

    /// The thread/resume `initialTurnsPage.data` as the notifications it stands for, in order:
    /// turn/started, each item started (inProgress) or completed, turn/completed unless running.
    pub fn snapshot(&self, session: &str, turns: Value<'_>) -> Vec<Json> {
        let mut documents = Vec::new();
        for turn in turns.array().into_iter().flatten() {
            let Some(id) = turn.get("id").and_then(Value::string) else {
                continue;
            };
            let mut updates = vec![("turn/started", vec![("turn", Data::Value(turn))])];
            for item in turn
                .get("items")
                .and_then(Value::array)
                .into_iter()
                .flatten()
            {
                let started = item.get("status").and_then(Value::string) == Some("inProgress");
                updates.push((
                    if started {
                        "item/started"
                    } else {
                        "item/completed"
                    },
                    vec![("item", Data::Value(item)), ("turnId", Data::String(id))],
                ));
            }
            if turn.get("status").and_then(Value::string) != Some("inProgress") {
                updates.push(("turn/completed", vec![("turn", Data::Value(turn))]));
            }
            for (method, mut fields) in updates {
                fields.push(("threadId", Data::String(session)));
                let envelope = Data::Object(vec![
                    ("method", Data::String(method)),
                    ("params", Data::Object(fields)),
                ]);
                if let Ok(document) = json::write(&envelope).and_then(|bytes| Json::parse(&bytes)) {
                    documents.push(document);
                }
            }
        }
        documents
    }
}
