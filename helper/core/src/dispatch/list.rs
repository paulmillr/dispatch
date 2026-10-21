//! `chat.list` (feature `chat.list`): every agent-bound terminal of this helper with what a
//! conversation list row shows, in one call: binding, label, busy/attention, the last
//! assistant text and its time. Built from the same harness calls as chat.state and chat.page.
use super::*;

/// Characters of the last assistant text a row keeps.
const PREVIEW: usize = 280;

/// One row; encoded field by field (no wire record, no schema change).
struct Row {
    terminal: Id,
    binding: Binding,
    key: String,
    label: String,
    name: String,
    cwd: Option<std::path::PathBuf>,
    state: Option<State>,
    state_error: Option<Error>,
    preview: Option<String>,
    time_ms: Option<i64>,
    history_error: Option<Error>,
    /// An approval or blocking question of this conversation is open: the agent waits for the
    /// user (a list row's "needs you" without opening the chat).
    waiting: bool,
}

impl crate::encode::Encode for Row {
    fn encode(&self, out: &mut Vec<u8>) {
        let busy = self.state.as_ref().map(|state| state.busy);
        let attention = self.state.as_ref().and_then(|state| state.attention.clone());
        let activity = self.state.as_ref().and_then(|state| state.activity.clone());
        let title = self.state.as_ref().and_then(|state| state.title.clone());
        crate::encode::object(
            out,
            &[
                ("terminal", &self.terminal),
                ("session", &self.binding.session),
                ("binding", &self.binding),
                ("key", &self.key),
                ("label", &self.label),
                ("name", &self.name),
                ("cwd", &self.cwd),
                ("busy", &busy),
                ("attention", &attention),
                ("activity", &activity),
                ("title", &title),
                ("state_error", &self.state_error),
                ("preview", &self.preview),
                ("time_ms", &self.time_ms),
                ("history_error", &self.history_error),
                ("waiting", &self.waiting),
            ],
        );
    }
}

/// The newest assistant text and the newest timestamp of a page.
pub(crate) fn last(records: &[Record]) -> (Option<String>, Option<i64>) {
    let preview = records
        .iter()
        .rev()
        .find(|record| record.kind == RecordKind::Assistant && !record.text.trim().is_empty())
        .map(|record| {
            let text = record.text.trim();
            match text.char_indices().nth(PREVIEW) {
                Some((end, _)) => format!("{}…", &text[..end]),
                None => text.to_owned(),
            }
        });
    let time = records.iter().rev().find_map(|record| record.time_ms);
    (preview, time)
}

impl Request<'_> {
    /// Protocol result: Vec of rows (terminal, session, binding, key, label, name, cwd, busy,
    /// attention, activity, title, state_error, preview, time_ms, history_error, waiting), by
    /// terminal.
    pub(super) fn chat_list(&mut self, p: &Data<'_>) -> Result<(), Error> {
        if p.object().is_some_and(|mut fields| fields.next().is_some()) {
            return Err(invalid("params"));
        }
        let rows: Vec<_> = self
            .helper
            .nodes
            .borrow()
            .iter()
            .filter_map(|(&terminal, (_, node))| {
                let (harness, binding) = node.agent.clone()?;
                Some((terminal, harness, binding, node.name.clone(), node.cwd.clone()))
            })
            .collect();
        let interactions = self.helper.interactions.borrow();
        let waiting = |terminal: Id, session: &str| {
            interactions.iter().any(|((id, conversation, _), (questions, holds))| {
                *id == terminal && conversation == session && *holds && !questions.is_empty()
            })
        };
        let rows: Vec<_> = rows
            .into_iter()
            .map(|(terminal, harness, binding, name, cwd)| {
                let open = waiting(terminal, &binding.session);
                (terminal, harness, binding, name, cwd, open)
            })
            .collect();
        drop(interactions);
        let done = self.done::<Vec<Row>>(None);
        let collected: Rc<RefCell<Vec<Row>>> = Rc::new(RefCell::new(Vec::new()));
        let remaining = Rc::new(Cell::new(rows.len()));
        let done = Rc::new(RefCell::new(Some(done)));
        if rows.is_empty() {
            let done = done.borrow_mut().take().unwrap();
            deferred(done)(self.io, Ok(Vec::new()));
            return Ok(());
        }
        for (terminal, index, binding, name, cwd, waiting) in rows {
            let Some(harness) = self.helper.harnesses.get(index).cloned() else {
                remaining.set(remaining.get() - 1);
                continue;
            };
            let (key, label) = {
                let harness = harness.borrow();
                (harness.key().to_owned(), harness.name().to_owned())
            };
            let row = Rc::new(RefCell::new(Some(Row {
                terminal,
                binding: binding.clone(),
                key,
                label,
                name,
                cwd,
                state: None,
                state_error: None,
                preview: None,
                time_ms: None,
                history_error: None,
                waiting,
            })));
            let (next, history_binding) = (harness.clone(), binding.clone());
            let (collected, remaining, done) = (collected.clone(), remaining.clone(), done.clone());
            harness.borrow_mut().state(
                self.io,
                &binding,
                deferred(Box::new(move |io, result| {
                    if let Some(row) = row.borrow_mut().as_mut() {
                        match result {
                            Ok(state) => row.state = Some(state),
                            Err(error) => row.state_error = Some(error),
                        }
                    }
                    next.borrow_mut().history(
                        io,
                        &history_binding,
                        None,
                        deferred(Box::new(move |io, result| {
                            let Some(mut row) = row.borrow_mut().take() else { return };
                            match result {
                                Ok(page) => (row.preview, row.time_ms) = last(&page.records),
                                Err(error) => row.history_error = Some(error),
                            }
                            collected.borrow_mut().push(row);
                            remaining.set(remaining.get() - 1);
                            if remaining.get() == 0
                                && let Some(done) = done.borrow_mut().take()
                            {
                                let mut rows = std::mem::take(&mut *collected.borrow_mut());
                                rows.sort_by_key(|row| row.terminal);
                                done(io, Ok(rows));
                            }
                        })),
                    );
                })),
            );
        }
        if remaining.get() == 0
            && let Some(done) = done.borrow_mut().take()
        {
            deferred(done)(self.io, Ok(Vec::new()));
        }
        Ok(())
    }
}


impl Request<'_> {
    /// Protocol result: Vec of {path, time_ms, agents, exists}, newest first (feature
    /// projects.recent): folders the agents' own session stores name, for a New space sheet.
    pub(super) fn projects_recent(&mut self, p: &Data<'_>) -> Result<(), Error> {
        if p.object().is_some_and(|mut fields| fields.any(|(key, _)| key != "limit")) {
            return Err(invalid("params"));
        }
        let limit = match p.get("limit") {
            None => 30,
            Some(value) => value.unsigned().filter(|n| (1..=200).contains(n)).ok_or_else(|| invalid("limit"))?,
        };
        let home = std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .or_else(|| crate::system::System::account().ok().map(|(_, home)| home))
            .ok_or_else(|| invalid("home"))?;
        let root = |variable: &str, default: &str| {
            std::env::var_os(variable)
                .filter(|value| !value.is_empty())
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| home.join(default))
        };
        let (claude, codex, pi) =
            (root("CLAUDE_CONFIG_DIR", ".claude"), root("CODEX_HOME", ".codex"), root("PI_CODING_AGENT_DIR", ".pi/agent"));
        let value = crate::wire::body::encode_plain(&Data::Object(vec![
            ("claude", Data::from(claude.as_path())),
            ("codex", Data::from(codex.as_path())),
            ("pi", Data::from(pi.as_path())),
            ("limit", Data::Unsigned(limit)),
        ]))?;
        let work = self
            .io
            .submit(Job::Native { name: "projects.recent", value })
            .map_err(|error| Error { code: "io_failure", message: error.to_string() })?;
        let done = self.done::<Encoded>(None);
        self.io.then(
            work,
            Box::new(move |io, result| {
                let result = match result {
                    Ok(Output::Value(bytes)) => Encoded::plain(&bytes),
                    Ok(_) => Err(Error { code: "io_failure", message: "projects.recent".into() }),
                    Err(error) => Err(Error { code: "io_failure", message: error.to_string() }),
                };
                done(io, result);
            }),
        );
        Ok(())
    }
}

/// A `terminals.activity` row; encoded field by field (no wire record, no schema change).
#[derive(Debug, PartialEq)]
pub(crate) struct Seen {
    node: Id,
    key: String,
    kind: Kind,
    time_ms: u64,
}

impl crate::encode::Encode for Seen {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(
            out,
            &[("node", &self.node), ("key", &self.key), ("kind", &self.kind), ("time_ms", &self.time_ms)],
        );
    }
}

/// Multiplexer `mux`'s (local node, Unix ms) times as rows of the nodes core published, by node.
/// A node core no longer knows (closed meanwhile) or holds detached has no row.
pub(crate) fn seen(mux: usize, times: Vec<(Id, u64)>, nodes: &BTreeMap<Id, (usize, Node)>) -> Vec<Seen> {
    let mut rows: Vec<Seen> = times
        .into_iter()
        .filter_map(|(local, time_ms)| {
            let node = super::reference(mux, local);
            let (_, published) = nodes.get(&node).filter(|(module, published)| *module == mux && !published.detached)?;
            Some(Seen { node, key: published.key.clone(), kind: published.kind, time_ms })
        })
        .collect();
    rows.sort_by_key(|row| row.node);
    rows.dedup_by_key(|row| row.node);
    rows
}

impl Request<'_> {
    /// Protocol result: Vec of {node, key, kind, time_ms} (feature terminals.activity): when the
    /// server last saw activity in each published node whose multiplexer reports one (tmux: its
    /// windows), by node.
    pub(super) fn terminals_activity(&mut self, p: &Data<'_>) -> Result<(), Error> {
        if p.object().is_some_and(|mut fields| fields.next().is_some()) {
            return Err(invalid("params"));
        }
        let multiplexers = self.helper.multiplexers.clone();
        let done = Rc::new(RefCell::new(Some(self.done::<Vec<Seen>>(None))));
        let collected: Rc<RefCell<Vec<Seen>>> = Rc::default();
        let remaining = Rc::new(Cell::new(multiplexers.len()));
        if multiplexers.is_empty() {
            let done = done.borrow_mut().take().unwrap();
            deferred(done)(self.io, Ok(Vec::new()));
            return Ok(());
        }
        for (index, mux) in multiplexers.into_iter().enumerate() {
            let (nodes, collected, remaining, done) =
                (self.helper.nodes.clone(), collected.clone(), remaining.clone(), done.clone());
            mux.borrow_mut().activity(
                self.io,
                deferred(Box::new(move |io, result| {
                    // A multiplexer that cannot tell (its server is gone) gives no times.
                    if let Ok(times) = result {
                        collected.borrow_mut().extend(seen(index, times, &nodes.borrow()));
                    }
                    remaining.set(remaining.get() - 1);
                    if remaining.get() == 0
                        && let Some(done) = done.borrow_mut().take()
                    {
                        let mut rows = std::mem::take(&mut *collected.borrow_mut());
                        rows.sort_by_key(|row| row.node);
                        done(io, Ok(rows));
                    }
                })),
            );
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "list.test.rs"]
mod tests;
