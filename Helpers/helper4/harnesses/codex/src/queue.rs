//! Keep every native input member for delete-before-steer; edit only plain text.
use crate::channel::{Channel, failure};
use dispatch_helper4_core::{
    api::{Done, Error, Io, Mode, Preview, Queued, deferred},
    json::{Data, Kind, Value},
};
use std::{cell::RefCell, collections::BTreeSet, rc::Rc};

#[derive(Debug, PartialEq, Eq)]
pub struct Row {
    pub id: String,
    pub client: String,
    pub input: Vec<u8>,
    pub preview: Vec<Preview>,
    pub editable: bool,
}

impl Row {
    pub fn queued(&self, mode: Mode, revision: u64) -> Queued {
        Queued {
            id: self.id.clone(),
            mode,
            revision,
            preview: self.preview.clone(),
            editable: self.editable,
            editing: false,
            paused: None,
            error: None,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct Page {
    pub rows: Vec<Row>,
    pub cursor: Option<String>,
}

#[derive(Default)]
pub struct Pages {
    pub rows: Vec<Row>,
    cursors: BTreeSet<String>,
}

impl Pages {
    pub fn feed(&mut self, value: Value<'_>) -> Result<Option<String>, Error> {
        let page = page(value)?;
        if self.rows.len() + page.rows.len() > 1000
            || page
                .cursor
                .as_ref()
                .is_some_and(|cursor| !self.cursors.insert(cursor.clone()))
        {
            return Err(failure("queue", "Invalid native queue page."));
        }
        self.rows.extend(page.rows);
        Ok(page.cursor)
    }
}

pub(crate) fn list(
    channel: Rc<RefCell<Channel>>,
    io: &mut dyn Io,
    mut pages: Pages,
    cursor: Option<String>,
    done: Done<Vec<Row>>,
) {
    let session = channel.borrow().binding.session.clone();
    let mut fields = vec![
        ("threadId", Data::String(&session)),
        ("limit", Data::Unsigned(100)),
    ];
    if let Some(cursor) = &cursor {
        fields.push(("cursor", Data::String(cursor)));
    }
    let next = channel.clone();
    channel.borrow_mut().request(
        io,
        "thread/queue/list",
        Data::Object(fields),
        Box::new(
            move |io, result| match result.and_then(|value| pages.feed(value.root())) {
                Ok(Some(cursor)) => list(next, io, pages, Some(cursor), done),
                Ok(None) => deferred(done)(io, Ok(pages.rows)),
                Err(error) => deferred(done)(io, Err(error)),
            },
        ),
    );
}

pub(crate) fn clear(channel: Rc<RefCell<Channel>>, io: &mut dyn Io, mut ids: Vec<String>, done: Done<()>) {
    let Some(id) = ids.pop() else { return deferred(done)(io, Ok(())); };
    let session = channel.borrow().binding.session.clone();
    let next = channel.clone();
    channel.borrow_mut().request(io, "thread/queue/delete", Data::Object(vec![
        ("threadId", Data::String(&session)),
        ("queuedSubmissionId", Data::String(&id)),
    ]), Box::new(move |io, result| match result {
        Ok(_) => clear(next, io, ids, done),
        Err(error) => deferred(done)(io, Err(error)),
    }));
}

pub fn row(value: Value<'_>) -> Result<Row, Error> {
    let read = || {
        let id = value.get("id")?.string()?;
        let client = value.get("clientUserMessageId")?.string()?;
        let input = value.get("input")?;
        let values: Vec<_> = input.array()?.collect();
        if id.is_empty() || values.is_empty() || values.iter().any(|v| v.kind() != Kind::Object) {
            return None;
        }
        let editable = values.iter().all(|v| {
            v.get("type").and_then(Value::string) == Some("text")
                && v.get("text").and_then(Value::string).is_some()
                && v.get("text_elements")
                    .and_then(Value::array)
                    .is_none_or(|mut a| a.next().is_none())
        });
        let preview = values
            .iter()
            .map(|v| {
                v.get("text")
                    .and_then(Value::string)
                    .map(|text| Preview::Text(text.into()))
                    .unwrap_or_else(|| {
                        Preview::Attachment(
                            v.get("type")
                                .and_then(Value::string)
                                .unwrap_or("attachment")
                                .into(),
                        )
                    })
            })
            .collect();
        Some(Row {
            id: id.into(),
            client: client.into(),
            input: input.write().ok()?,
            preview,
            editable,
        })
    };
    read().ok_or_else(|| Error {
        code: "queue",
        message: "The agent returned an invalid queued message.".into(),
    })
}

pub fn page(value: Value<'_>) -> Result<Page, Error> {
    let values = value
        .get("data")
        .and_then(Value::array)
        .ok_or_else(|| Error {
            code: "queue",
            message: "The agent returned an invalid queue page.".into(),
        })?;
    let rows = values.take(1001).map(row).collect::<Result<Vec<_>, _>>()?;
    if rows.len() > 1000 {
        return Err(Error {
            code: "queue",
            message: "Too many native queued messages.".into(),
        });
    }
    Ok(Page {
        rows,
        cursor: value
            .get("nextCursor")
            .and_then(Value::string)
            .map(str::to_owned),
    })
}
