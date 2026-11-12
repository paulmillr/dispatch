//! `chat.list` (feature `chat.list`): every agent-bound terminal of this helper with what a
//! conversation list row shows, in one call: binding, label, busy/attention, the last
//! assistant text and its time. Built from the harness's list read (`Harness::overview`: Claude
//! and Codex read only their transcript's end and leave open chats alone) and chat.state.
use super::*;

/// Characters of the last assistant text a row keeps.
#[cfg(test)]
const PREVIEW: usize = Overview::PREVIEW;

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
    listing: Overview,
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
        // The agent's own name for the conversation first (Claude's registry, Codex's thread
        // name, a title the harness read before), else the one the list read found.
        let title = self.state.as_ref().and_then(|state| state.title.clone()).or_else(|| self.listing.title.clone());
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
                ("preview", &self.listing.preview),
                ("time_ms", &self.listing.time_ms),
                ("history_error", &self.history_error),
                ("waiting", &self.waiting),
                ("reply_ms", &self.listing.reply_ms),
            ],
        );
    }
}

/// The newest assistant text and the newest timestamp of a page.
#[cfg(test)]
pub(crate) fn last(records: &[Record]) -> (Option<String>, Option<i64>) {
    let listing = Overview::of(records);
    (listing.preview, listing.time_ms)
}

/// Whether an approval or blocking question of `session` in `terminal` is open (published and
/// not yet answered or closed).
pub(crate) fn waiting(interactions: &Interactions, terminal: Id, session: &str) -> bool {
    interactions.borrow().iter().any(|((id, conversation, _), (questions, holds))| {
        *id == terminal && conversation == session && *holds && !questions.is_empty()
    })
}

impl Request<'_> {
    /// Protocol result: Vec of rows (terminal, session, binding, key, label, name, cwd, busy,
    /// attention, activity, title, state_error, preview, time_ms, history_error, waiting,
    /// reply_ms), by terminal.
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
        let done = self.done::<Vec<Row>>(None);
        let collected: Rc<RefCell<Vec<Row>>> = Rc::new(RefCell::new(Vec::new()));
        let remaining = Rc::new(Cell::new(rows.len()));
        let done = Rc::new(RefCell::new(Some(done)));
        if rows.is_empty() {
            let done = done.borrow_mut().take().unwrap();
            deferred(done)(self.io, Ok(Vec::new()));
            return Ok(());
        }
        for (terminal, index, binding, name, cwd) in rows {
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
                listing: Overview::default(),
                history_error: None,
                waiting: false,
            })));
            let (next, state_binding) = (harness.clone(), binding.clone());
            let (collected, remaining, done) = (collected.clone(), remaining.clone(), done.clone());
            let interactions = self.helper.interactions.clone();
            // The list read first, as the page came first before it (the harness default is
            // that page): reading the transcript is what names the conversation (Claude's
            // title records) on a helper whose chats have not read it.
            harness.borrow_mut().overview(
                self.io,
                &binding,
                deferred(Box::new(move |io, result| {
                    if let Some(row) = row.borrow_mut().as_mut() {
                        match result {
                            Ok(listing) => row.listing = listing,
                            Err(error) => row.history_error = Some(error),
                        }
                    }
                    next.borrow_mut().state(
                        io,
                        &state_binding,
                        deferred(Box::new(move |io, result| {
                            let Some(mut row) = row.borrow_mut().take() else { return };
                            match result {
                                Ok(state) => row.state = Some(state),
                                Err(error) => row.state_error = Some(error),
                            }
                            // After the harness calls, which may have published or closed the
                            // conversation's approvals and questions (Pi's state does).
                            row.waiting = waiting(&interactions, row.terminal, &row.binding.session);
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

impl crate::encode::Encode for LimitWindow {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(out, &[("name", &self.0), ("used", &self.1), ("resets_at", &self.2)]);
    }
}

impl crate::encode::Encode for LimitRow {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(out, &[("label", &self.0), ("detail", &self.1), ("value", &self.2), ("used", &self.3)]);
    }
}

impl crate::encode::Encode for LimitRows {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(out, &[("source", &self.0), ("rows", &self.1)]);
    }
}

impl Request<'_> {
    /// Protocol result: {source, rows} (feature chat.limits.rows): the extension reporting limits for this session, and
    /// with `read` naming it, its rows.
    pub(super) fn chat_limit_rows(&mut self, p: &Data<'_>) -> Result<(), Error> {
        let (_, _, harness, binding) = self.agent(p)?;
        let read = p.get("read").and_then(Data::string);
        let done = self.done::<LimitRows>(None);
        harness.borrow_mut().limit_rows(self.io, &binding, read, done);
        Ok(())
    }

    /// Protocol result: Vec of {name, used, resets_at} (feature chat.limits): the usage windows the agent reports,
    /// read now; empty when it reports none.
    pub(super) fn chat_limits(&mut self, p: &Data<'_>) -> Result<(), Error> {
        let (_, _, harness, binding) = self.agent(p)?;
        let done = self.done::<Vec<LimitWindow>>(None);
        harness.borrow_mut().limits(self.io, &binding, done);
        Ok(())
    }

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
