use super::*;
use control::{Channel, Conversation};

pub(super) struct Wait {
    pub at: Instant,
    pub transition: bool,
    pub probe: Box<dyn Fn(&Channel) -> Option<Result<Binding, Error>>>,
    pub done: Callback<Binding>,
}

impl Nano {
    pub(super) fn fork(
        &mut self,
        io: &mut dyn Io,
        parent: Binding,
        text: String,
        done: Done<Binding>,
    ) {
        let pid = parent.process.pid;
        self.refresh(
            io,
            pid,
            Box::new(move |this, io, result| {
                let previous = result.and_then(|_| {
                    let c = this.channel(&parent)?;
                    if c.waits.iter().any(|w| w.transition) {
                        return Err(error("busy", "Nanocodex is switching conversations."));
                    }
                    Ok(c.snapshot
                        .as_ref()
                        .unwrap()
                        .root()
                        .get("conversations")
                        .and_then(Value::object)
                        .map(|v| v.map(|(key, _)| key.to_owned()).collect::<Vec<_>>())
                        .unwrap_or_default())
                });
                let previous = match previous {
                    Ok(v) => v,
                    Err(e) => {
                        done(io, Err(e));
                        return;
                    }
                };
                this.mutate(
                    io,
                    &parent.clone(),
                    "command",
                    Some("/btw"),
                    None,
                    Box::new(move |this, io, result| {
                        if let Err(e) = result {
                            done(io, Err(e));
                            return;
                        }
                        let original = parent.clone();
                        this.wait(
                            io,
                            pid,
                            Box::new(move |c| {
                                let s = c.snapshot.as_ref()?.root();
                                let active = string(s, "active_session_id");
                                let v = s.get("conversations")?.get(active)?;
                                if previous.iter().any(|id| id == active) || active.is_empty() {
                                    return None;
                                }
                                if string(v, "parent_session_id") != original.session
                                    || string(v, "role") != "side_conversation"
                                {
                                    return Some(Err(error(
                                        "changed",
                                        rejection("session_changed", ""),
                                    )));
                                }
                                Some(Ok(Binding {
                                    session: active.into(),
                                    transcript: None,
                                    process: original.process.clone(),
                                }))
                            }),
                            Box::new(move |this, io, result| {
                                let child = match result {
                                    Ok(v) => v,
                                    Err(e) => {
                                        done(io, Err(e));
                                        return;
                                    }
                                };
                                this.channels.get_mut(&pid).unwrap().conversations.insert(
                                    child.session.clone(),
                                    Conversation::new(child.clone(), true),
                                );
                                this.mutate(
                                    io,
                                    &child.clone(),
                                    "prompt",
                                    Some(&text),
                                    None,
                                    Box::new(move |_, io, result| done(io, result.map(|_| child))),
                                );
                            }),
                        );
                        this.refresh(io, pid, Box::new(|_, _, _| {}));
                    }),
                );
            }),
        );
    }

    pub(super) fn finish(&mut self, io: &mut dyn Io, child: Binding, done: Done<()>) {
        let pid = child.process.pid;
        self.refresh(
            io,
            pid,
            Box::new(move |this, io, result| {
                let parent = result.and_then(|_| {
                    let c = this.channel(&child)?;
                    let s = c.snapshot.as_ref().unwrap().root();
                    let v = s
                        .get("conversations")
                        .and_then(|v| v.get(&child.session))
                        .ok_or_else(|| error("changed", rejection("session_changed", "")))?;
                    if string(v, "role") != "side_conversation" {
                        return Err(error(
                            "unsupported",
                            "This is not a Nanocodex side conversation.",
                        ));
                    }
                    c.conversations
                        .get(string(v, "parent_session_id"))
                        .map(|v| v.binding.clone())
                        .ok_or_else(|| error("changed", rejection("session_changed", "")))
                });
                let parent = match parent {
                    Ok(v) => v,
                    Err(e) => {
                        done(io, Err(e));
                        return;
                    }
                };
                if !this.channels[&pid].conversations[&child.session]
                    .turns
                    .is_empty()
                {
                    this.mutate(
                        io,
                        &child.clone(),
                        "cancel",
                        None,
                        None,
                        Box::new(move |this, io, result| {
                            if let Err(e) = result {
                                done(io, Err(e));
                                return;
                            }
                            let session = child.session.clone();
                            this.wait(
                                io,
                                pid,
                                Box::new(move |c| {
                                    c.conversations
                                        .get(&session)
                                        .filter(|v| v.turns.is_empty())
                                        .map(|v| Ok(v.binding.clone()))
                                }),
                                Box::new(move |this, io, result| match result {
                                    Ok(_) => this.finish(io, child, done),
                                    Err(e) => done(io, Err(e)),
                                }),
                            );
                        }),
                    );
                    return;
                }
                this.mutate(
                    io,
                    &child,
                    "command",
                    Some("/close"),
                    None,
                    Box::new(move |this, io, result| {
                        if let Err(e) = result {
                            done(io, Err(e));
                            return;
                        }
                        this.wait(
                            io,
                            pid,
                            Box::new(move |c| {
                                let s = c.snapshot.as_ref()?.root();
                                (string(s, "active_session_id") == parent.session)
                                    .then(|| Ok(parent.clone()))
                            }),
                            Box::new(move |_, io, result| done(io, result.map(|_| ()))),
                        );
                        this.refresh(io, pid, Box::new(|_, _, _| {}));
                    }),
                );
            }),
        );
    }

    fn wait(
        &mut self,
        io: &mut dyn Io,
        pid: u32,
        probe: Box<dyn Fn(&Channel) -> Option<Result<Binding, Error>>>,
        done: Callback<Binding>,
    ) {
        let at = io.now() + Duration::from_secs(40);
        io.timer(at);
        if let Some(c) = self.channels.get_mut(&pid) {
            c.waits.push(Wait {
                at,
                transition: true,
                probe,
                done,
            });
        } else {
            done(
                self,
                io,
                Err(error("closed", "Nanocodex closed its control connection.")),
            );
        }
    }

    pub(super) fn journal(
        &mut self,
        io: &mut dyn Io,
        binding: Binding,
        cursor: Option<String>,
        done: Callback<Page>,
    ) {
        if let Err(e) = self.channel(&binding) {
            done(self, io, Err(e));
            return;
        }
        let params = match cursor {
            Some(v) => Json::parse(v.as_bytes()),
            None => document(Data::Object(vec![
                ("order", Data::String("oldest")),
                ("limit", Data::Unsigned(16)),
            ])),
        };
        match params {
            Ok(params) => self.journal_page(
                io,
                binding,
                params,
                records::Projection::new(true),
                vec![],
                done,
            ),
            Err(e) => done(self, io, Err(e)),
        }
    }

    fn journal_page(
        &mut self,
        io: &mut dyn Io,
        binding: Binding,
        params: Json,
        mut projection: records::Projection,
        mut rows: Vec<Record>,
        done: Callback<Page>,
    ) {
        self.pending(
            io,
            binding.process.pid,
            params,
            Box::new(move |this, io, result| {
                let (doc, records) = match result {
                    Ok(v) => v,
                    Err(e) => {
                        done(this, io, Err(e));
                        return;
                    }
                };
                for record in records {
                    if let Some(data) = record
                        .root()
                        .get("data")
                        .filter(|v| string(*v, "request_id") == binding.session)
                    {
                        rows.extend(projection.live(data, false, None, &digest, &printable));
                    }
                }
                if flag(doc.root(), "has_more") {
                    let params = document(Data::Object(vec![
                        ("boundary", Data::String(string(doc.root(), "boundary"))),
                        ("cursor", Data::String(string(doc.root(), "next_cursor"))),
                        ("order", Data::String("oldest")),
                        ("limit", Data::Unsigned(16)),
                    ]));
                    match params {
                        Ok(params) => {
                            this.journal_page(io, binding, params, projection, rows, done)
                        }
                        Err(e) => done(this, io, Err(e)),
                    }
                } else {
                    let mut indices = BTreeMap::new();
                    let mut compact: Vec<Record> = vec![];
                    for row in rows {
                        if let Some(index) = indices.get(&row.id).copied() {
                            compact[index] = row;
                        } else {
                            indices.insert(row.id.clone(), compact.len());
                            compact.push(row);
                        }
                    }
                    done(
                        this,
                        io,
                        Ok(Page {
                            records: compact,
                            earlier: None,
                        }),
                    );
                }
            }),
        );
    }
}
