use super::Codex;
use crate::{
    channel::{Channel, failure, initialize},
    native,
};
use dispatch_helper4_core::{
    api::*,
    json::{Data, Value},
};
use std::{cell::RefCell, collections::BTreeMap, path::Path, process::Command, rc::Rc};

type Rows = Rc<RefCell<BTreeMap<String, Vec<crate::queue::Row>>>>;
type Counters = Rc<RefCell<BTreeMap<String, u64>>>;

impl Codex {
    /// Deliver input: owned sides natively, the main TUI typed into its terminal (c1654cc
    /// ChatCoordinator.swift:1810-1880) except an async question's answer, which old Dispatch
    /// sent natively when connected (CodexPatchConnection.swift:555-569).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn submit(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        text: &str,
        mode: Mode,
        command: bool,
        answer: bool,
        done: Done<Sent>,
    ) {
        if text
            .chars()
            .any(|value| value < ' ' && value != '\n' && value != '\t')
        {
            deferred(done)(
                io,
                Err(failure(
                    "input",
                    "The agent input contains control characters.",
                )),
            );
            return;
        }
        let main = self.main.channels.borrow().contains_key(&binding.session);
        if self.channel(binding).is_ok() && !command && (answer || !main) {
            let mut params = vec![
                ("threadId", Data::String(&binding.session)),
                ("input", super::input(text)),
            ];
            if self
                .channel(binding)
                .is_ok_and(|channel| channel.borrow().read_only)
            {
                params.extend(crate::side::permissions());
            }
            let turn = self
                .states
                .borrow()
                .get(&binding.session)
                .and_then(|state| state.activity.clone());
            let method = if mode == Mode::Steer {
                let Some(turn) = turn.as_deref() else {
                    deferred(done)(io, Err(failure("turn", "No active Codex turn.")));
                    return;
                };
                params.push(("expectedTurnId", Data::String(turn)));
                "turn/steer"
            } else {
                "turn/start"
            };
            self.request(
                io,
                binding,
                method,
                Data::Object(params),
                Box::new(move |io, result| deferred(done)(io, super::sent(result))),
            );
        } else {
            if command && let Some(reading) = super::command::Reading::new(text) {
                self.reading
                    .insert((binding.process.pid, binding.process.start), reading);
                deferred(done)(
                    io,
                    Err(failure("menu", "Read the command's terminal result.")),
                );
                return;
            }
            let mut value = text.to_owned();
            if !command && matches!(text.trim_start().chars().next(), Some('/' | '!')) {
                let longest = ['`', '~'].map(|character| {
                    text.split(|value| value != character)
                        .map(str::len)
                        .max()
                        .unwrap_or(0)
                });
                let index = usize::from(longest[0] > longest[1]);
                let fence = ['`', '~'][index]
                    .to_string()
                    .repeat(3.max(longest[index] + 1));
                value = format!(
                    "{fence}\n{text}{}{fence}",
                    if text.ends_with('\n') { "" } else { "\n" }
                );
            }
            deferred(done)(
                io,
                Ok(Sent::Keys(vec![
                    Input::Paste(value),
                    Input::Key(Key::Enter),
                ])),
            );
        }
    }

    pub fn new() -> Self {
        Self::default()
    }

    /// Launch with the original `codex` arguments, which decide the private server and its flags
    /// before preparation; `resume <id>` is one such invocation. Core decision C1/C2: becomes
    /// Harness::launch(io, cwd, arguments, done). c1654cc CodexLauncher.swift:10-112.
    pub fn invoke(
        &mut self,
        io: &mut dyn Io,
        cwd: &Path,
        arguments: &[String],
        done: Done<Command>,
    ) {
        self.launch
            .invoke(self.jobs.clone(), io, cwd, arguments, done);
    }

    pub(super) fn selection(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        model: &str,
        effort: Option<&str>,
        done: Done<Sent>,
    ) {
        // A TUI owns scope decisions; its structured setter silently bypasses those menus.
        // Side agents have no terminal menu and keep their native setter.
        let channel = self
            .sides
            .borrow()
            .contains_key(&binding.session)
            .then(|| self.channel(binding))
            .transpose();
        let channel = match channel {
            Ok(channel) => channel,
            Err(error) => return deferred(done)(io, Err(error)),
        };
        let walks = self.walks.clone();
        let key = (binding.process.pid, binding.process.start);
        let session = binding.session.clone();
        let model = model.to_owned();
        let effort = effort.map(str::to_owned);
        self.catalog(
            io,
            binding,
            Box::new(move |io, result| {
                let result = result.and_then(|catalog| {
                    let model = catalog
                        .models
                        .into_iter()
                        .find(|entry| entry.choice.id == model || entry.native == model)
                        .ok_or_else(|| failure("models", "The selected model is unavailable."))?;
                    let effort = effort.unwrap_or(model.effort);
                    if !model.efforts.iter().any(|entry| entry.choice.id == effort) {
                        return Err(failure(
                            "models",
                            "The selected reasoning effort is unavailable.",
                        ));
                    }
                    let labels =
                        std::iter::once((model.native.clone(), model.choice.label.clone()))
                            .chain(std::iter::once((
                                model.choice.id.clone(),
                                model.choice.label,
                            )))
                            .chain(
                                model
                                    .efforts
                                    .into_iter()
                                    .map(|entry| (entry.choice.id, entry.choice.label)),
                            )
                            .collect();
                    Ok((model.native, effort, labels))
                });
                let (model, effort, labels) = match result {
                    Ok(value) => value,
                    Err(error) => {
                        deferred(done)(io, Err(error));
                        return;
                    }
                };
                let Some(channel) = channel else {
                    let mut walk = crate::menu::Walk::default();
                    walk.labels = labels;
                    walk.opening = true;
                    walks.borrow_mut().insert(key, walk);
                    deferred(done)(
                        io,
                        Err(failure(
                            "menu",
                            "Select the Codex model in the terminal menu.",
                        )),
                    );
                    return;
                };
                channel.borrow_mut().request(
                    io,
                    "thread/settings/update",
                    Data::Object(vec![
                        ("threadId", Data::String(&session)),
                        ("model", Data::String(&model)),
                        ("effort", Data::String(&effort)),
                    ]),
                    Box::new(move |io, result| {
                        let result = result.map_err(|error| {
                            if error
                                .message
                                .contains("unknown variant `thread/settings/update`")
                                || error.message == "Method not found"
                            {
                                failure("menu", "Select the Codex model in the terminal menu.")
                            } else {
                                error
                            }
                        });
                        deferred(done)(io, super::sent(result));
                    }),
                );
            }),
        );
    }

    pub(super) fn channel(&self, binding: &Binding) -> Result<Rc<RefCell<Channel>>, Error> {
        self.sides
            .borrow()
            .get(&binding.session)
            .cloned()
            .or_else(|| self.main.channels.borrow().get(&binding.session).cloned())
            .filter(|channel| {
                let channel = channel.borrow();
                channel.ready && channel.binding.process == binding.process
            })
            .ok_or_else(|| {
                failure(
                    "unsupported",
                    "The live Codex WebSocket channel is not available yet.",
                )
            })
    }

    pub(super) fn request(
        &self,
        io: &mut dyn Io,
        binding: &Binding,
        method: &str,
        params: Data<'_>,
        done: Done<Json>,
    ) {
        if let Ok(channel) = self.channel(binding) {
            channel.borrow_mut().request(io, method, params, done);
            return;
        }
        let params = match dispatch_helper4_core::json::write(&params)
            .and_then(|bytes| Json::parse(&bytes))
        {
            Ok(params) => params,
            Err(error) => {
                deferred(done)(io, Err(error));
                return;
            }
        };
        let method = method.to_owned();
        self.connection(
            io,
            binding,
            Box::new(move |io, result| match result {
                Ok(channel) => {
                    channel
                        .borrow_mut()
                        .request(io, &method, Data::Value(params.root()), done)
                }
                Err(error) => deferred(done)(io, Err(error)),
            }),
        );
    }

    fn connection(&self, io: &mut dyn Io, binding: &Binding, done: Done<Rc<RefCell<Channel>>>) {
        match self.channel(binding) {
            Ok(channel) => deferred(done)(io, Ok(channel)),
            Err(_) => self.main.open(self.jobs.clone(), io, binding.clone(), done),
        }
    }

    pub(super) fn listing(&self, io: &mut dyn Io, binding: &Binding, done: Done<Vec<Queued>>) {
        let queue = self.queue_state();
        let session = binding.session.clone();
        self.connection(
            io,
            binding,
            Box::new(move |io, result| match result {
                Ok(channel) => Self::snapshot(channel, io, queue, session, done),
                Err(error) => deferred(done)(io, Err(error)),
            }),
        );
    }

    /// Revision-safe native list: restart while changes arrive; issue a new revision only when rows differ.
    fn snapshot(
        channel: Rc<RefCell<Channel>>,
        io: &mut dyn Io,
        queue: (Rows, Counters, Counters),
        session: String,
        done: Done<Vec<Queued>>,
    ) {
        let change = queue.2.borrow().get(&session).copied().unwrap_or(0);
        let next = channel.clone();
        crate::queue::list(
            channel,
            io,
            crate::queue::Pages::default(),
            None,
            Box::new(move |io, result| {
                let (rows, revisions, changes) = &queue;
                if changes.borrow().get(&session).copied().unwrap_or(0) != change {
                    Self::snapshot(next, io, queue, session, done);
                    return;
                }
                let result = result.map(|list| {
                    let mut revisions = revisions.borrow_mut();
                    let revision = revisions.entry(session.clone()).or_default();
                    let mut rows = rows.borrow_mut();
                    if rows.get(&session).map_or(&[][..], Vec::as_slice) != list.as_slice() {
                        *revision += 1;
                    }
                    let queued = list
                        .iter()
                        .map(|row| row.queued(Mode::FollowUp, *revision))
                        .collect();
                    rows.insert(session, list);
                    queued
                });
                deferred(done)(io, result);
            }),
        );
    }

    /// c1654cc CodexPatchConnection.swift:361-364,579-629: a native change notice re-lists and publishes once at a time.
    pub(super) fn refresh(&self, io: &mut dyn Io, binding: Binding) {
        *self
            .changes
            .borrow_mut()
            .entry(binding.session.clone())
            .or_default() += 1;
        let Ok(channel) = self.channel(&binding) else {
            return;
        };
        if !self.refreshing.borrow_mut().insert(binding.session.clone()) {
            return;
        }
        let refreshing = self.refreshing.clone();
        let updates = self.updates.clone();
        let retries = self.retries.clone();
        let (rows, revisions) = (self.rows.clone(), self.revision.clone());
        let session = binding.session.clone();
        Self::snapshot(
            channel,
            io,
            self.queue_state(),
            session,
            Box::new(move |io, result| {
                refreshing.borrow_mut().remove(&binding.session);
                // c1654cc CodexPatchConnection.swift:612-625 (core C-QUEUE-ERR): a snapshot clears the
                // error; a definite unsupported reply publishes no rows with code `unsupported` (held
                // queue fallback) and stops; any other failure keeps the rows, shows the error and
                // lists again 2 s later.
                let unsupported = |error: &Error| {
                    error.code == "unsupported"
                        || [
                            "queue backend",
                            "queue persistence",
                            "user message queue is unavailable",
                        ]
                        .iter()
                        .any(|text| error.message.contains(text))
                };
                let (items, error) = match result {
                    Ok(items) => (items, None),
                    Err(error) if unsupported(&error) => {
                        let error = failure("unsupported", error.message);
                        (Vec::new(), Some(error))
                    }
                    Err(error) => {
                        let at = io.now() + std::time::Duration::from_secs(2);
                        retries
                            .borrow_mut()
                            .insert(binding.session.clone(), (at, binding.clone()));
                        io.timer(at);
                        let revision = revisions
                            .borrow()
                            .get(&binding.session)
                            .copied()
                            .unwrap_or(0);
                        let rows = rows.borrow();
                        let rows = rows.get(&binding.session).map_or(&[][..], Vec::as_slice);
                        let rows = rows.iter().map(|row| row.queued(Mode::FollowUp, revision));
                        (rows.collect(), Some(error))
                    }
                };
                updates.borrow_mut().push(Update::Queue {
                    binding,
                    items,
                    error,
                });
                let now = io.now();
                io.timer(now);
            }),
        );
    }

    fn queue_state(&self) -> (Rows, Counters, Counters) {
        (
            self.rows.clone(),
            self.revision.clone(),
            self.changes.clone(),
        )
    }

    /// The catalog of the Codex this agent runs: a server started as the agent runs (its home and
    /// configuration, e.g. model_catalog_json; owned::command), shared by agents that run Codex the
    /// same way.
    pub(super) fn catalog(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        done: Done<native::Catalog>,
    ) {
        let models = self.models.clone();
        let key = (binding.process.pid, binding.process.start);
        models.borrow_mut().remove(&key);
        let done: Done<native::Catalog> = Box::new(move |io, result| {
            if let Ok(catalog) = &result {
                models.borrow_mut().insert(key, catalog.models.iter().map(|model| model.choice.clone()).collect());
            }
            deferred(done)(io, result);
        });
        let (catalogs, exits, parent) =
            (self.catalogs.clone(), self.exits.clone(), binding.clone());
        crate::owned::command(
            self.jobs.clone(),
            io,
            binding.clone(),
            Box::new(move |io, result| {
                let (command, _, scratch) = match result {
                    Ok(value) => value,
                    Err(error) => return deferred(done)(io, Err(error)),
                };
                let envs: Vec<_> = command.get_envs().collect();
                let key = format!(
                    "{}:{:?}:{envs:?}",
                    parent.process.executable.display(),
                    command.get_current_dir()
                );
                let existing = catalogs.borrow().get(&key).cloned();
                if let Some(channel) = existing {
                    crate::owned::remove(io, scratch);
                    if !channel.borrow().ready {
                        let error = failure("busy", "The Codex model catalog is opening.");
                        return deferred(done)(io, Err(error));
                    }
                    return crate::catalog::list(channel, io, Vec::new(), None, done);
                }
                let channel = match Channel::spawn(io, parent, command) {
                    Ok(channel) => Rc::new(RefCell::new(channel)),
                    Err(error) => {
                        crate::owned::remove(io, scratch);
                        return deferred(done)(io, Err(error));
                    }
                };
                if let Some(path) = scratch {
                    exits.borrow_mut().insert(channel.borrow().pid, path);
                }
                catalogs.borrow_mut().insert(key, channel.clone());
                let next = channel.clone();
                initialize(
                    channel,
                    io,
                    "dispatch",
                    Box::new(move |io, result| {
                        if let Err(error) = result {
                            deferred(done)(io, Err(error));
                            return;
                        }
                        next.borrow_mut().ready = true;
                        crate::catalog::list(next, io, Vec::new(), None, done);
                    }),
                );
            }),
        );
    }

    pub(super) fn change(
        &self,
        io: &mut dyn Io,
        binding: &Binding,
        operation: &str,
        fields: Vec<(&str, Data<'_>)>,
        done: Done<Json>,
    ) {
        *self
            .changes
            .borrow_mut()
            .entry(binding.session.clone())
            .or_default() += 1;
        let ids: Vec<String> = fields
            .iter()
            .flat_map(|(key, value)| match (*key, value) {
                ("queuedSubmissionId", Data::String(id)) => vec![(*id).to_owned()],
                ("queuedSubmissionIds", Data::Array(ids)) => ids
                    .iter()
                    .filter_map(|id| match id {
                        Data::String(id) => Some((*id).to_owned()),
                        _ => None,
                    })
                    .collect(),
                _ => Vec::new(),
            })
            .collect();
        let rows = self.rows.clone();
        let session = binding.session.clone();
        let reorder = operation == "reorder";
        let mut params = vec![("threadId", Data::String(&binding.session))];
        params.extend(fields);
        self.request(
            io,
            binding,
            &format!("thread/queue/{operation}"),
            Data::Object(params),
            Box::new(move |io, result| {
                // Apply the native result locally so a later identical list keeps the issued revision.
                if let Ok(value) = &result {
                    let root = value.root();
                    let mut rows = rows.borrow_mut();
                    let rows = rows.entry(session).or_default();
                    if let Some(row) = root
                        .get("queuedSubmission")
                        .and_then(|row| crate::queue::row(row).ok())
                    {
                        match rows.iter_mut().find(|previous| previous.id == row.id) {
                            Some(previous) => *previous = row,
                            None => rows.push(row),
                        }
                    } else if reorder {
                        rows.sort_by_key(|row| {
                            ids.iter()
                                .position(|id| *id == row.id)
                                .unwrap_or(usize::MAX)
                        });
                    } else if root.get("deleted").and_then(Value::boolean) != Some(false) {
                        rows.retain(|row| !ids.contains(&row.id));
                    }
                }
                done(io, result)
            }),
        );
    }

    pub(super) fn check(&self, binding: &Binding, item: &str, revision: u64) -> Result<(), Error> {
        if self.revision.borrow().get(&binding.session).copied() != Some(revision)
            || !self
                .rows
                .borrow()
                .get(&binding.session)
                .is_some_and(|rows| rows.iter().any(|row| row.id == item))
        {
            return Err(failure(
                "stale",
                "The queued message changed. Refresh the queue.",
            ));
        }
        Ok(())
    }
}
