//! One queue API for every harness: a verified native queue, or a queue held by core and
//! drained when the agent is idle; c1654cc ChatCoordinator.swift:1604-1738, ChatModels.swift:655-662.
use super::*;
use std::{collections::VecDeque, time::Duration};

/// Old queueRetryAfter: a send that typed nothing is retried after one second.
const RETRY: Duration = Duration::from_secs(1);
/// Old queue limits: 50 items, 1 MiB of text (ChatCoordinator.swift:1617-1618).
const ITEMS: usize = 50;
const TEXT: usize = 1 << 20;

struct Item {
    id: String,
    text: String,
    mode: Mode,
    command: bool,
    revision: u64,
    binding: Binding,
    pause: Option<Pause>,
    /// The user is editing this item in the composer; drain waits (old editingQueuedID).
    editing: bool,
}

/// One chat's held queue. `waiting` holds the next send until the agent acknowledges the
/// previous one (busy state or new records), like the old awaitingPromptAck.
#[derive(Default)]
pub(crate) struct Line {
    items: Vec<Item>,
    serial: u64,
    pub(super) sending: bool,
    checking: bool,
    waiting: bool,
    hold: bool,
    retry: bool,
    dirty: bool,
}
/// Held queues by (terminal, session).
pub(crate) type Held = Rc<RefCell<BTreeMap<(Id, String), Line>>>;

impl Line {
    pub(crate) fn revoke(&mut self) {
        self.hold = true;
        self.dirty = false;
        for item in &mut self.items {
            item.pause = Some(Pause::Stopped);
        }
    }
    pub(crate) fn snapshot(&self) -> Vec<Queued> {
        self.items
            .iter()
            .map(|item| Queued {
                id: item.id.clone(),
                mode: item.mode,
                revision: item.revision,
                preview: vec![Preview::Text(item.text.clone())],
                editable: true,
                editing: item.editing,
                paused: item.pause,
                error: None,
            })
            .collect()
    }
    fn next(&mut self) -> u64 {
        self.serial += 1;
        self.serial
    }
    fn find(&mut self, id: &str, revision: u64) -> Result<usize, Error> {
        self.items
            .iter()
            .position(|item| item.id == id && item.revision == revision)
            .ok_or(Error {
                code: "expired",
                message: "The queued message changed".into(),
            })
    }
}

/// State and record updates: busy or new records acknowledge a send; idle drains again.
pub(crate) fn observe(held: &Held, terminal: Id, update: &Update) {
    let (binding, busy) = match update {
        Update::State { binding, state } => (binding, Some(state.busy)),
        Update::Records { binding, records } if !records.is_empty() => (binding, None),
        _ => return,
    };
    if let Some(line) = held
        .borrow_mut()
        .get_mut(&(terminal, binding.session.clone()))
    {
        match busy {
            Some(false) => line.dirty = true,
            _ => line.waiting = false,
        }
    }
}

fn publish(updates: &Rc<RefCell<VecDeque<Update>>>, binding: &Binding, line: &Line) {
    updates
        .borrow_mut()
        .push_back(Update::queue(binding.clone(), Ok(line.snapshot())));
}

/// Own input until completion; only sends await a turn, which can arrive before their callback.
pub(super) fn sending(held: Held, key: (Id, String), awaiting: bool, done: Done<Sent>) -> Done<Sent> {
    {
        let mut lines = held.borrow_mut();
        let line = lines.entry(key.clone()).or_default();
        line.sending = true;
        line.waiting = awaiting;
    }
    Box::new(move |io, result| {
        if let Some(line) = held.borrow_mut().get_mut(&key) {
            line.sending = false;
            line.dirty = true;
            if !matches!(
                &result,
                Ok(Sent::Native { written: true, .. }
                    | Sent::Native {
                        may_have_sent: true,
                        ..
                    })
            ) {
                line.waiting = false;
            }
        }
        done(io, result);
    })
}

fn invalid_text(text: &str, command: bool) -> Option<Error> {
    let fail = |code: &'static str| {
        Some(Error {
            code,
            message: String::new(),
        })
    };
    if command && text.trim_start().starts_with('!') {
        return fail("shell_command");
    }
    if text.trim().is_empty()
        || text.len() > TEXT
        || text
            .chars()
            .any(|c| (c as u32) < 32 && c != '\n' && c != '\t')
    {
        return fail("invalid_input");
    }
    None
}

/// Send the first held item of every dirty, idle queue (old drainQueue).
pub(crate) fn drain(helper: &DispatchHelper, io: &mut dyn Io) {
    let keys: Vec<_> = helper
        .held
        .borrow_mut()
        .iter_mut()
        .filter(|(_, line)| {
            line.dirty && !line.hold && !line.sending && !line.checking && !line.waiting && !line.retry
        })
        .map(|(key, line)| {
            line.dirty = false;
            key.clone()
        })
        .collect();
    for (terminal, session) in keys {
        let Ok((index, binding)) = helper.binding(terminal, Some(&session)) else {
            continue;
        };
        let Some(module) = helper
            .nodes
            .borrow()
            .get(&terminal)
            .map(|(module, _)| *module)
        else {
            continue;
        };
        let key = (terminal, session);
        {
            let mut held = helper.held.borrow_mut();
            let line = held.get_mut(&key).unwrap();
            let Some(first) = line.items.first_mut() else {
                continue;
            };
            if first.pause.is_some() || first.editing {
                continue;
            }
            if !same(&first.binding, &binding) {
                first.pause = Some(Pause::DestinationChanged);
                publish(&helper.updates, &binding, line);
                continue;
            }
            line.checking = true;
        }
        let (harness, mux) = (
            helper.harnesses[index].clone(),
            helper.multiplexers[module].clone(),
        );
        let (held, updates) = (helper.held.clone(), helper.updates.clone());
        let current = binding.clone();
        let owner = harness.clone();
        owner.borrow_mut().state(
            io,
            &binding,
            deferred(Box::new(move |io, state| {
                let idle =
                    state.is_ok_and(|s| !s.busy && s.attention.is_none() && s.dialog.is_none());
                let item = {
                    let mut lines = held.borrow_mut();
                    let Some(line) = lines.get_mut(&key) else { return; };
                    line.checking = false;
                    if !idle || line.hold || line.sending || line.waiting || line.retry { return; }
                    let Some(item) = line.items.first().filter(|item| item.pause.is_none() && !item.editing) else { return; };
                    let item = (item.id.clone(), item.text.clone(), item.mode, item.command);
                    line.sending = true;
                    item
                };
                send(io, held, updates, key, mux, harness, current, item);
            })),
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn send(
    io: &mut dyn Io,
    held: Held,
    updates: Rc<RefCell<VecDeque<Update>>>,
    key: (Id, String),
    mux: Shared<dyn Multiplexer>,
    harness: Shared<dyn Harness>,
    binding: Binding,
    (id, text, mode, command): (String, String, Mode, bool),
) {
    let terminal = local(key.0);
    let current = binding.clone();
    let pending = held.clone();
    let route = key.clone();
    let finish: Done<Sent> = Box::new(move |io, result| {
        let mut lines = held.borrow_mut();
        let Some(line) = lines.get_mut(&key) else {
            return;
        };
        let index = line.items.iter().position(|item| item.id == id);
        match (result, index) {
            (_, None) => {}
            (Ok(Sent::Native { written: true, .. }), Some(index)) => {
                line.items.remove(index);
            }
            (
                Ok(Sent::Native {
                    may_have_sent: true,
                    ..
                }),
                Some(index),
            ) => {
                line.items[index].pause = Some(Pause::Uncertain);
            }
            (Err(error), Some(index)) if error.code == "attention" => {
                line.items[index].pause = Some(Pause::NeedsEdit);
            }
            _ => {
                line.retry = true;
                let held = held.clone();
                let _ = io.after(
                    io.now() + RETRY,
                    Box::new(move |_| {
                        if let Some(line) = held.borrow_mut().get_mut(&key) {
                            line.retry = false;
                            line.dirty = true;
                        }
                    }),
                );
            }
        }
        publish(&updates, &current, line);
    });
    let finish = sending(pending, route, true, finish);
    // A drain has no user to ask; a menu that needs a decision pauses the item.
    let ask: Ask = Rc::new(|io, _, done| {
        deferred(done)(
            io,
            Err(Error {
                code: "attention",
                message: String::new(),
            }),
        )
    });
    let goal = Goal::Send {
        text: text.clone(),
        mode,
        command,
    };
    let done = walk(
        None,
        mux.clone(),
        harness.clone(),
        terminal,
        binding.clone(),
        goal,
        ask,
        typed(None, mux, harness.clone(), terminal, binding.clone(), finish),
        |_| Sent::Native {
            written: true,
            may_have_sent: true,
            reason: None,
        },
    );
    harness
        .borrow_mut()
        .send(io, &binding, &text, mode, command, done);
}

impl Request<'_> {
    /// Protocol result: list Vec<Queued>; add Queued; start Sent; others null
    /// Protocol producers: Harness.queue, Harness.queue_add, Harness.queue_edit, Harness.queue_send, Harness.queue_order
    pub(super) fn queue(&mut self, p: Value<'_>, op: &str) -> Result<(), Error> {
        let (_, _, harness, binding) = self.agent(p)?;
        if op == "reorder" && strings(p, "items")?.is_empty() {
            return Err(invalid("items"));
        }
        if harness.borrow().native_queue() {
            if matches!(op, "add" | "update") {
                if let Some(body) = p.get("text").and_then(Value::string) {
                    if let Some(error) = invalid_text(body, flag(p, "command")) {
                        return Err(error);
                    }
                }
            }
            return self.native(p, op, harness, binding);
        }
        let terminal = number(p, "terminal")?;
        let key = (terminal, binding.session.clone());
        if op == "start" {
            let item = text(p, "item")?;
            let revision = number(p, "revision")?;
            let mode = mode(p)?;
            let mut lines = self.helper.held.borrow_mut();
            let line = lines.entry(key).or_default();
            let index = line.find(item, revision)?;
            if line.items[index].pause.is_some() || !same(&line.items[index].binding, &binding) {
                return Err(invalid("item"));
            }
            let item = line.items.remove(index);
            publish(&self.helper.updates, &binding, line);
            drop(lines);
            let goal = Goal::Send {
                text: item.text.clone(),
                mode,
                command: item.command,
            };
            let done = self.sent(p, Some(goal))?;
            harness
                .borrow_mut()
                .send(self.io, &binding, &item.text, mode, item.command, done);
            return Ok(());
        }
        let mut lines = self.helper.held.borrow_mut();
        let line = lines.entry(key).or_default();
        let reply: Result<Option<Queued>, Error> = (|| {
            match op {
                "list" => {}
                "add" => {
                    let (body, command) = (text(p, "text")?, flag(p, "command"));
                    if let Some(error) = invalid_text(body, command) {
                        return Err(error);
                    }
                    if line.items.len() >= ITEMS {
                        return Err(invalid("text"));
                    }
                    let serial = line.next();
                    line.items.push(Item {
                        id: format!("held-{serial}"),
                        text: body.into(),
                        mode: mode(p)?,
                        command,
                        revision: serial,
                        binding: binding.clone(),
                        pause: None,
                        editing: false,
                    });
                    return Ok(line.snapshot().pop());
                }
                "update" => {
                    let index = line.find(text(p, "item")?, number(p, "revision")?)?;
                    match p.get("text").and_then(Value::string) {
                        None => {
                            line.items.remove(index);
                        }
                        Some(body) => {
                            // An edit is reclassified from the app's current draft;
                            // c1654cc ChatCoordinator.swift:1624,1630.
                            let command = p
                                .get("command")
                                .and_then(Value::boolean)
                                .unwrap_or(line.items[index].command);
                            if let Some(error) = invalid_text(body, command) {
                                return Err(error);
                            }
                            let serial = line.next();
                            let item = &mut line.items[index];
                            (item.text, item.revision, item.pause) = (body.into(), serial, None);
                            item.command = command;
                            item.editing = false;
                            item.binding = binding.clone();
                        }
                    }
                }
                "remove" => {
                    let index = line.find(text(p, "item")?, number(p, "revision")?)?;
                    line.items.remove(index);
                }
                "reorder" => {
                    let order = strings(p, "items")?;
                    let mut sorted: Vec<_> = line.items.iter().map(|i| i.id.clone()).collect();
                    let mut wanted = order.clone();
                    sorted.sort();
                    wanted.sort();
                    if sorted != wanted {
                        return Err(invalid("items"));
                    }
                    line.items
                        .sort_by_key(|item| order.iter().position(|id| *id == item.id));
                }
                "restore" => {
                    for item in &mut line.items {
                        if item.pause == Some(Pause::Stopped) {
                            item.pause = None;
                        }
                    }
                }
                "hold" => line.hold = flag(p, "held"),
                "edit" => {
                    let index = line.find(text(p, "item")?, number(p, "revision")?)?;
                    line.items[index].editing = flag(p, "editing");
                }
                _ => return Err(invalid("method")),
            }
            Ok(None)
        })();
        let reply = reply?;
        line.dirty = true;
        if op != "list" {
            publish(&self.helper.updates, &binding, line);
        }
        let items = line.snapshot();
        drop(lines);
        match (op, reply) {
            ("list", _) => self.done(None)(self.io, Ok(items)),
            (_, Some(queued)) => self.done(None)(self.io, Ok(queued)),
            _ => self.done(None)(self.io, Ok(())),
        }
        Ok(())
    }

    /// Old stopQueue: Stop pauses every held item that is not already paused.
    /// Protocol result: Sent
    pub(super) fn stop(&mut self, p: Value<'_>) -> Result<(), Error> {
        let (_, _, harness, binding) = self.agent(p)?;
        let terminal = number(p, "terminal")?;
        if let Some(line) = self
            .helper
            .held
            .borrow_mut()
            .get_mut(&(terminal, binding.session.clone()))
        {
            for item in &mut line.items {
                item.pause.get_or_insert(Pause::Stopped);
            }
            publish(&self.helper.updates, &binding, line);
        }
        let done = self.sent(p, Some(Goal::Stop))?;
        harness.borrow_mut().stop(self.io, &binding, done);
        Ok(())
    }

    fn native(
        &mut self,
        p: Value<'_>,
        op: &str,
        harness: Shared<dyn Harness>,
        binding: Binding,
    ) -> Result<(), Error> {
        if op == "list" {
            return self.snapshot(harness, binding);
        }
        let mut native = harness.borrow_mut();
        let (item, revision) = (
            p.get("item").and_then(Value::string).unwrap_or_default(),
            p.get("revision")
                .and_then(Value::unsigned)
                .unwrap_or_default(),
        );
        match op {
            "add" => {
                let done = self.queue_done(p, self.done(None))?;
                native.queue_add(self.io, &binding, text(p, "text")?, mode(p)?, done)
            }
            "update" | "remove" => {
                let done = self.queue_done(p, self.done(None))?;
                let body = (op == "update").then(|| p.get("text").and_then(Value::string));
                native.queue_edit(self.io, &binding, item, revision, body.flatten(), done)
            }
            "start" => {
                let done = self.queue_done(p, self.sent(p, None)?)?;
                native.queue_send(self.io, &binding, item, revision, mode(p)?, done)
            }
            "reorder" => {
                let done = self.queue_done(p, self.done(None))?;
                native.queue_order(self.io, &binding, &strings(p, "items")?, done)
            }
            _ => {
                return Err(Error {
                    code: "unsupported",
                    message: String::new(),
                });
            }
        }
        Ok(())
    }

    fn snapshot(&mut self, harness: Shared<dyn Harness>, binding: Binding) -> Result<(), Error> {
        let updates = self.helper.updates.clone();
        let done = self.done(None);
        let current = binding.clone();
        harness.borrow_mut().queue(
            self.io,
            &binding,
            deferred(Box::new(move |io, result| {
                updates
                    .borrow_mut()
                    .push_back(Update::queue(current, result.clone()));
                done(io, result);
            })),
        );
        Ok(())
    }

    pub(super) fn queue_done<T: 'static>(
        &self,
        p: Value<'_>,
        done: Done<T>,
    ) -> Result<Done<T>, Error> {
        let (_, _, harness, binding) = self.agent(p)?;
        let updates = self.helper.updates.clone();
        Ok(deferred(Box::new(move |io, result| {
            let refresh = result.is_ok() && harness.borrow().native_queue();
            done(io, result);
            if refresh {
                let current = binding.clone();
                harness.borrow_mut().queue(
                    io,
                    &binding,
                    deferred(Box::new(move |_, result| {
                        updates
                            .borrow_mut()
                            .push_back(Update::queue(current, result));
                    })),
                );
            }
        })))
    }
}
