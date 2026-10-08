//! Initial chat data uses the same route and Binding as every later chat update.
use super::*;

struct Observed {
    binding: Binding,
    state: State,
}

impl Encode for Observed {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(out, &[("binding", &self.binding), ("state", &self.state)]);
    }
}

impl Encode for Archive {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(
            out,
            &[
                ("records", &self.page.records),
                ("earlier", &self.page.earlier),
                ("snapshot", &self.snapshot),
                ("state", &self.state),
            ],
        );
    }
}

#[derive(Clone)]
struct Chat {
    terminal: Id,
    binding: Binding,
    label: String,
    key: String,
    commands: Vec<String>,
    native_queue: bool,
    state: Option<State>,
    state_error: Option<Error>,
    snapshot: bool,
    page: Page,
    history_error: Option<Error>,
    pending: bool,
}

impl Encode for Chat {
    fn encode(&self, out: &mut Vec<u8>) {
        let mut capabilities = Vec::new();
        if self.state.is_some() {
            capabilities.push("state");
        }
        if !self.pending && self.history_error.is_none() {
            capabilities.push("history");
        }
        if !self.commands.is_empty() {
            capabilities.push("commands");
        }
        let state = if self.snapshot { &self.state } else { &None };
        let state_error = if self.snapshot { &self.state_error } else { &None };
        crate::encode::object(
            out,
            &[
                ("terminal", &self.terminal),
                ("binding", &self.binding),
                ("session", &self.binding.session),
                ("label", &self.label),
                ("key", &self.key),
                ("commands", &self.commands),
                ("native_queue", &self.native_queue),
                ("state", state),
                ("state_error", state_error),
                ("records", &self.page.records),
                ("earlier", &self.page.earlier),
                ("history_error", &self.history_error),
                ("history_pending", &self.pending),
                ("capabilities", &capabilities),
            ],
        );
    }
}

impl Request<'_> {
    /// Protocol result: Observed
    pub(super) fn state(&mut self, p: Value<'_>) -> Result<(), Error> {
        let (_, mux, harness, binding) = self.agent(p)?;
        let terminal = number(p, "terminal")?;
        let (_, parent) = self.helper.binding(terminal, None)?;
        let foreground = same(&parent, &binding);
        let process = binding.process.clone();
        let current = binding.clone();
        let done = self.done(None);
        let call: Done<()> = deferred(Box::new(move |io, result| {
            if let Err(error) = result {
                return done(io, Err(Error { code: "unavailable", message: error.message }));
            }
            harness.borrow_mut().state(io, &binding, deferred(Box::new(move |io, result| {
                done(
                    io,
                    result.map(|state| Observed {
                        binding: current,
                        state,
                    }),
                );
            })));
        }));
        if foreground { mux.borrow_mut().check(self.io, local(terminal), &process, call); }
        else { call(self.io, Ok(())); }
        Ok(())
    }

    /// Protocol result: Page for {terminal, session?, earlier?} (a live binding); Archive for {transcript} alone (with terminal: invalid_input)
    pub(super) fn page(&mut self, p: Value<'_>) -> Result<(), Error> {
        if let Some((harness, source)) = self.transcript(p)? {
            let done = self.done(None);
            harness.borrow_mut().read(self.io, &source, done);
        } else {
            let (_, _, harness, binding) = self.agent(p)?;
            let done = self.done(None);
            harness.borrow_mut().history(
                self.io,
                &binding,
                p.get("earlier").and_then(Value::string),
                done,
            );
        }
        Ok(())
    }
    /// Protocol result: null
    /// Protocol producers: Harness.identify, Multiplexer.keys
    pub(super) fn keys(&mut self, p: Value<'_>) -> Result<(), Error> {
        let captured = p.get("binding").ok_or_else(|| invalid("binding"))?;
        let session = text(captured, "session")?;
        let terminal = number(p, "terminal")?;
        let (index, binding) = self.helper.binding(terminal, Some(session))?;
        let start = captured
            .get("start")
            .and_then(Value::array)
            .ok_or_else(|| invalid("binding.start"))?
            .map(|v| v.unsigned().ok_or_else(|| invalid("binding.start")))
            .collect::<Result<Vec<_>, _>>()?;
        if number(captured, "pid")? != u64::from(binding.process.pid)
            || start.as_slice() != binding.process.start
        {
            return Err(Error {
                code: "destination_changed",
                message: String::new(),
            });
        }
        let module = self
            .helper
            .nodes
            .borrow()
            .get(&terminal)
            .map(|(module, _)| *module)
            .ok_or_else(|| invalid("terminal"))?;
        let harness = self
            .helper
            .harnesses
            .get(index)
            .cloned()
            .ok_or_else(|| invalid("harness"))?;
        let mux = self.helper.multiplexers[module].clone();
        let input = vec![Input::Raw(data(
            p.get("keys").ok_or_else(|| invalid("keys"))?,
        )?)];
        let done = self.done(None);
        let active = self.active();
        crate::menu::keys(
            self.io,
            active,
            mux,
            harness,
            local(terminal),
            Rc::new(binding),
            input,
            done,
        );
        Ok(())
    }
    /// Protocol result: Chat, published as chat.history
    /// A {transcript} selection: file-only, it grants no send, menu, identity or terminal
    /// authority.
    fn transcript(&self, p: Value<'_>) -> Result<Option<(Shared<dyn Harness>, Transcript)>, Error> {
        let Some(source) = p.get("transcript") else {
            return Ok(None);
        };
        if p.get("terminal").is_some() {
            return Err(invalid("transcript"));
        }
        let key = text(source, "key")?;
        let harness = self
            .helper
            .harnesses
            .iter()
            .find(|h| h.borrow().key() == key)
            .cloned()
            .ok_or_else(|| invalid("transcript.key"))?;
        let source = Transcript {
            later: None,
            path: text(source, "path")?.into(),
            session: text(source, "session")?.into(),
            earlier: source
                .get("earlier")
                .and_then(Value::string)
                .map(str::to_owned),
        };
        Ok(Some((harness, source)))
    }

    /// Protocol result: Chat for {terminal, session?}; for {transcript}, chat.archive
    /// notifications (the first read, then each later one with records or a new State).
    pub(super) fn chat(&mut self, p: Value<'_>) -> Result<(), Error> {
        if let Some((harness, source)) = self.transcript(p)? {
            let watch = self.io.watch(&source.path, false).map_err(|e| Error {
                code: "io",
                message: e.to_string(),
            })?;
            self.helper.archives.borrow_mut().insert(
                (self.fd, self.id),
                Followed {
                    harness,
                    source,
                    watch,
                    reading: false,
                    again: false,
                    state: None,
                },
            );
            follow(
                self.io,
                &self.helper.archives,
                &self.replies,
                (self.fd, self.id),
            );
            return Ok(());
        }
        let terminal = number(p, "terminal")?;
        if p.get("session").is_none() && let Some((index, binding, error)) = self.helper.candidate(terminal) {
            let harness = self.helper.harnesses[index].borrow();
            let chat = Chat {
                terminal, binding, label: harness.name().into(), key: harness.key().into(),
                commands: Vec::new(), native_queue: false, state: None,
                state_error: Some(error.clone()), snapshot: true, page: Page::default(),
                history_error: Some(error), pending: false,
            };
            self.done(Some("chat.history"))(self.io, Ok(chat));
            return Ok(());
        }
        let (_, mux, harness, binding) = self.agent(p)?;
        // An open chat shows the native prompt on its terminal (arch.md "Native prompts").
        crate::prompt::start(
            self.io,
            &self.helper.prompts,
            &self.helper.updates,
            mux,
            harness.clone(),
            terminal,
            local(terminal),
            binding.clone(),
        );
        let label = harness.borrow().name().to_owned();
        let key = harness.borrow().key().to_owned();
        let native_queue = harness.borrow().native_queue();
        let updates = self.helper.updates.clone();
        let ready = self.done(Some("chat.history"));
        let done = self.done(Some("chat.history"));
        let history = harness.clone();
        let current = binding.clone();
        harness.borrow_mut().state(
            self.io,
            &binding,
            deferred(Box::new(move |io, result| {
                let (state, state_error) = match result {
                    Ok(state) => (Some(state), None),
                    Err(error) => (None, Some(error)),
                };
                // Live command catalogs are sampled after the native state they depend on.
                let commands = history.borrow().commands(&current);
                let mut chat = Chat {
                    terminal,
                    binding: current,
                    label,
                    key,
                    commands,
                    native_queue,
                    state,
                    state_error,
                    snapshot: true,
                    page: Page::default(),
                    history_error: None,
                    pending: true,
                };
                // Publish readiness before paging. Unsupported history must not end
                // this chat subscription or hide a successful State observation.
                ready(io, Ok(chat.clone()));
                if native_queue {
                    let current = chat.binding.clone();
                    history.borrow_mut().queue(
                        io,
                        &chat.binding,
                        deferred(Box::new(move |_, result| {
                            updates
                                .borrow_mut()
                                .push_back(Update::queue(current, result));
                        })),
                    );
                }
                let binding = chat.binding.clone();
                history.borrow_mut().history(
                    io,
                    &binding,
                    None,
                    deferred(Box::new(move |io, result| {
                        chat.pending = false;
                        // State notifications may have advanced while history was loading.
                        // Keep the announced capabilities, without repeating the older snapshot.
                        chat.snapshot = false;
                        match result {
                            Ok(page) => chat.page = page,
                            Err(error) => chat.history_error = Some(error),
                        }
                        done(io, Ok(chat));
                    })),
                );
            })),
        );
        Ok(())
    }
}

/// Read a followed archive from its cursor: the first and each later read with records or a
/// changed State are chat.archive notifications; an error ends the request. Changes during a read cause one more.
pub(crate) fn follow(io: &mut dyn Io, archives: &Archives, replies: &Replies, key: (i32, u64)) {
    let (harness, source) = {
        let mut archives = archives.borrow_mut();
        let Some(followed) = archives.get_mut(&key) else {
            return;
        };
        if followed.reading {
            followed.again = true;
            return;
        }
        followed.reading = true;
        (followed.harness.clone(), followed.source.clone())
    };
    let first = source.later.is_none();
    let (archives, replies) = (archives.clone(), replies.clone());
    // Every read is a notification while the watch lives; only an error responds (ends it).
    let reply = super::reply(replies.clone(), key.0, key.1, Some("chat.archive"));
    harness.borrow_mut().read(
        io,
        &source,
        Box::new(move |io, result: Result<Archive, Error>| {
            let mut changed = false;
            let again = {
                let mut all = archives.borrow_mut();
                let Some(followed) = all.get_mut(&key) else {
                    return;
                };
                followed.reading = false;
                match &result {
                    Ok(archive) => {
                        followed.source.later = Some(archive.snapshot.later.clone());
                        changed = followed.state.as_ref() != Some(&archive.state);
                        followed.state = Some(archive.state.clone());
                    }
                    // A failed read ends the request (e.g. a foreign session).
                    Err(_) => {
                        io.unwatch(followed.watch);
                        all.remove(&key);
                    }
                }
                all.get_mut(&key)
                    .is_some_and(|followed| std::mem::take(&mut followed.again))
            };
            if first
                || changed
                || result
                    .as_ref()
                    .map_or(true, |a| !a.page.records.is_empty() || a.snapshot.initial)
            {
                reply(io, result);
            }
            if again {
                follow(io, &archives, &replies, key);
            }
        }),
    );
}
