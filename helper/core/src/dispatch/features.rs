//! Opt-in protocol features. A client names the ones it understands in `hello`
//! (`params.features: [String]`); everything here stays off for a client that names none, so a
//! client recorded before a feature existed (the Mac app's replay corpus) sees the same bytes.
//!
//! None of this touches the generated wire schema (helper/core/build/schema.rs): the names
//! below are not literals of dispatch/table.rs and the values are built field by field.
use super::*;
use std::{collections::BTreeSet, os::fd::RawFd};

/// interaction.opened advertises every choice the producer offers, e.g. "This session" for a
/// session-scoped allow; interactions.answer accepts them.
pub(crate) const INTERACTION_OPTIONS: &str = "interaction.options";
/// The `chat.list` operation.
pub(crate) const CHAT_LIST: &str = "chat.list";
/// The `projects.recent` operation.
pub(crate) const PROJECTS_RECENT: &str = "projects.recent";
/// multiplexers.list reports installed, version and paste readiness per multiplexer.
pub(crate) const MULTIPLEXER_VERSIONS: &str = "multiplexers.versions";
/// terminals.create with `launch` names the new tmux window or herdr tab after the agent.
pub(crate) const LAUNCH_NAMES: &str = "launch.names";
/// A `--remote --stdio` helper ends when this client has sent nothing for `liveness::limit()`:
/// its connection is gone even if the close never arrived (NAT, port forwards).
pub(crate) const STDIO_LIVENESS: &str = "stdio.liveness";
/// terminal.output notifications of one stream are coalesced for a few milliseconds.
pub(crate) const TERMINALS_COALESCE: &str = "terminals.coalesce";
/// The `terminals.activity` operation: when the server last saw activity in each node.
pub(crate) const TERMINALS_ACTIVITY: &str = "terminals.activity";
/// memberships.move without `before` puts a herdr tab after its workspace's last tab; without it the helper keeps
/// herdr's old index (before the last tab), which the Mac's recorded moves expect.
pub(crate) const MEMBERSHIPS_APPEND: &str = "memberships.append";

/// The client does not publish screens of tmux and herdr terminals: the helper reads them from the multiplexer
/// (`Multiplexer::host_screens`) for the terminals it attaches, until some other client publishes one.
pub(crate) const SCREENS_HOST: &str = "screens.host";
/// The `terminals.follow` operation: hold a hidden terminal's output for one attach subscription, and repaint it for
/// that subscription alone when it follows again (dispatch/following.rs).
pub(crate) const TERMINALS_FOLLOW: &str = "terminals.follow";

/// The helper keeps reading and answering this client's requests while its output is backed up
/// (helper/client.rs BACKLOG); without it a full output queue stops reading the client, as
/// recorded clients expect. A stdio.liveness client (the iPhone) and a terminals.window client get
/// it too.
pub(crate) const REQUESTS_BACKLOG: &str = "requests.backlog";
/// At most `OUTPUT_WINDOW` bytes of terminal.output unacknowledged per client, acknowledged with
/// the `terminals.ack` operation; past it output waits and the multiplexers are paused. Implies
/// requests.backlog, or the acks that reopen the window would wait behind that pause.
pub(crate) const TERMINALS_WINDOW: &str = "terminals.window";
pub(crate) const TERMINALS_ACK: &str = "terminals.ack";

/// The `attachments.put` and `attachments.read` operations, and `attachments` on chat.send and
/// queue.add (dispatch/attachments.rs).
pub(crate) const ATTACHMENTS: &str = "chat.attachments";
pub(crate) const ATTACHMENTS_PUT: &str = "attachments.put";
pub(crate) const ATTACHMENTS_READ: &str = "attachments.read";

/// The `login.release` operation (dispatch/release.rs): the Mac's greeting probe releases the SSH login waiting for it.
/// Accepted only by a `--remote --stdio` helper without the login wrapper (helper.rs), so no other helper's hello
/// changes.
pub(crate) const LOGIN_RELEASE: &str = "login.release";

/// The features this helper offers.
pub(crate) const KNOWN: &[&str] = &[
    INTERACTION_OPTIONS,
    CHAT_LIST,
    PROJECTS_RECENT,
    MULTIPLEXER_VERSIONS,
    TERMINALS_COALESCE,
    LAUNCH_NAMES,
    STDIO_LIVENESS,
    TERMINALS_ACTIVITY,
    ATTACHMENTS,
    MEMBERSHIPS_APPEND,
    SCREENS_HOST,
    TERMINALS_FOLLOW,
    REQUESTS_BACKLOG,
    TERMINALS_WINDOW,
    LOGIN_RELEASE,
];

/// Choice ids only interaction.options clients see, appended after a producer's ordinary
/// choices so the ordinary indices stay what they were (Claude's session-scoped allow).
pub(crate) const EXTENSION_CHOICES: &[&str] = &["Session"];

/// The interaction as a client without interaction.options sees it; None when it is the same.
/// Only an approval's trailing extension choices go: clients answer by option index against the
/// producer's list, and an agent's own question names its choices by their labels (one may well
/// be "Session"), so hiding any other choice would move the indices a client answers with onto
/// different choices.
pub(crate) fn legacy(interaction: &Interaction) -> Option<Interaction> {
    if !interaction.approval {
        return None;
    }
    let trailing = |question: &crate::api::Question| {
        question.options.iter().rev().take_while(|choice| EXTENSION_CHOICES.contains(&choice.id.as_str())).count()
    };
    let extended = interaction.questions.iter().any(|question| trailing(question) > 0);
    extended.then(|| {
        let mut legacy = interaction.clone();
        for question in &mut legacy.questions {
            let kept = question.options.len() - trailing(question);
            question.options.truncate(kept);
        }
        legacy
    })
}
/// Operations that exist only for a client that named their feature, with that feature.
pub(crate) const OPERATIONS: &[(&str, &str)] = &[
    (CHAT_LIST, CHAT_LIST),
    (PROJECTS_RECENT, PROJECTS_RECENT),
    (TERMINALS_ACTIVITY, TERMINALS_ACTIVITY),
    (ATTACHMENTS_PUT, ATTACHMENTS),
    (ATTACHMENTS_READ, ATTACHMENTS),
    (TERMINALS_FOLLOW, TERMINALS_FOLLOW),
    (TERMINALS_ACK, TERMINALS_WINDOW),
    (LOGIN_RELEASE, LOGIN_RELEASE),
];

/// The feature operations a hello reply adds to `ops`: those of the `accepted` features that the client's grant
/// `allows`, in OPERATIONS order. The app sends only what `ops` lists (HelperConnection), so an operation missing here
/// is never called.
pub(crate) fn offered(accepted: &[String], allows: impl Fn(&str) -> bool) -> Vec<String> {
    OPERATIONS
        .iter()
        .filter(|(op, feature)| accepted.iter().any(|f| f == feature) && allows(op))
        .map(|(op, _)| op.to_string())
        .collect()
}

/// The feature `method` is an operation of, if it is one of OPERATIONS.
pub(crate) fn operation(method: &str) -> Option<&'static str> {
    OPERATIONS.iter().find(|(name, _)| *name == method).map(|(_, feature)| *feature)
}

/// The features each client connection asked for and got.
pub(crate) type Features = Rc<RefCell<BTreeMap<RawFd, BTreeSet<&'static str>>>>;

pub(crate) fn enabled(features: &Features, fd: RawFd, feature: &str) -> bool {
    features.borrow().get(&fd).is_some_and(|set| set.contains(feature))
}

/// Whether client `fd` publishes the screens of the terminals it attaches (it does not name screens.host).
pub(crate) fn publishes(features: &Features, fd: RawFd) -> bool {
    !enabled(features, fd, SCREENS_HOST)
}

/// The features a `hello` names (None: it names none, the field is absent). Unknown names are
/// dropped, not refused: a newer client may ask for more than this helper has.
pub(crate) fn requested(root: &Data<'_>) -> Result<Option<BTreeSet<&'static str>>, Error> {
    if root.get("method").and_then(Data::string) != Some("hello") {
        return Ok(None);
    }
    let Some(list) = root.get("params").and_then(|params| params.get("features")) else {
        return Ok(None);
    };
    let items = list.array().ok_or_else(|| invalid("features"))?;
    let mut accepted = BTreeSet::new();
    for (count, item) in items.enumerate() {
        let name = item.string().ok_or_else(|| invalid("features"))?;
        if count >= 64 || name.len() > 128 {
            return Err(invalid("features"));
        }
        if let Some(known) = KNOWN.iter().find(|known| **known == name) {
            accepted.insert(*known);
        }
    }
    Ok(Some(accepted))
}

/// `root` without `params.features`, for the ordinary request checks: hello takes no other
/// params, and any other field is refused as before.
pub(crate) fn without<'a>(root: &Data<'a>) -> Result<Data<'a>, Error> {
    let others = root
        .get("params")
        .and_then(Data::object)
        .is_some_and(|mut fields| fields.any(|(key, _)| key != "features"));
    if others {
        return Err(invalid("params"));
    }
    Ok(Data::Object(vec![
        ("method", Data::String("hello")),
        ("params", Data::Object(Vec::new())),
    ]))
}

/// Whether this hello asked for features: its reply then lists the accepted ones.
pub(crate) fn asked(document: &Encoded) -> bool {
    document
        .root()
        .get("params")
        .and_then(|params| params.get("features"))
        .is_some()
}

impl Request<'_> {
    /// An operation only a client that named its feature can call (checked by the caller).
    pub(crate) fn extension(&mut self, method: &str, params: &Data<'_>) -> Result<(), Error> {
        if method == CHAT_LIST {
            return self.chat_list(params);
        }
        if method == PROJECTS_RECENT {
            return self.projects_recent(params);
        }
        if method == TERMINALS_ACTIVITY {
            return self.terminals_activity(params);
        }
        if method == ATTACHMENTS_PUT {
            return self.attachments_put(params);
        }
        if method == ATTACHMENTS_READ {
            return self.attachments_read(params);
        }
        if method == TERMINALS_FOLLOW {
            return self.terminals_follow(params);
        }
        if method == TERMINALS_ACK {
            return self.terminals_ack(params);
        }
        if method == LOGIN_RELEASE {
            return self.login_release(params);
        }
        Err(Error {
            code: "unsupported",
            message: format!("Unknown operation {method}"),
        })
    }
}

impl Request<'_> {
    /// terminals.ack {terminal, bytes, subscription?}: the client handed `bytes` more
    /// terminal.output payload bytes of its attach subscription of `terminal` (found as
    /// terminals.follow finds it) to its renderer. Applied before the helper next admits output
    /// (DispatchHelper::start); more than is outstanding counts as all of it. A subscription that
    /// ended meanwhile (its own outstanding output went with it) makes it a no-op.
    pub(crate) fn terminals_ack(&mut self, params: &Data<'_>) -> Result<(), Error> {
        let known = params
            .object()
            .ok_or_else(|| invalid("params"))?
            .all(|(key, _)| matches!(key, "terminal" | "bytes" | "subscription"));
        if !known {
            return Err(invalid("params"));
        }
        let bytes = params.get("bytes").and_then(Data::unsigned).ok_or_else(|| invalid("bytes"))?;
        let (index, _) = self.mux(params)?;
        let terminal = reference(index, local(number(params, "terminal")?));
        // The client's attach subscriptions of `terminal`, as terminals.follow finds them.
        let streams: Vec<u64> = self
            .helper
            .windows
            .borrow()
            .iter()
            .filter(|((fd, _), (id, _))| *fd == self.fd && *id == terminal)
            .filter_map(|((_, stream), _)| *stream)
            .collect();
        let subscription = match optional(params, "subscription") {
            Some(stream) => streams.contains(&stream).then_some(stream),
            None if streams.len() > 1 => return Err(invalid("subscription")),
            None => streams.first().copied(),
        };
        // None: it ended (its outstanding output went with it), nothing to acknowledge.
        if let Some(subscription) = subscription {
            self.helper.acks.push((self.fd, subscription, bytes));
        }
        let done = self.done::<()>(None);
        deferred(done)(self.io, Ok(()));
        Ok(())
    }
}

/// A multiplexer kind with what its program says about itself (multiplexers.versions).
pub(super) struct Versioned {
    kind: Mux,
    installed: Option<bool>,
    version: Option<String>,
    paste_state: Option<bool>,
    running: Option<bool>,
}
impl Encode for Versioned {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(
            out,
            &[
                ("mux", &self.kind.mux),
                ("name", &self.kind.name),
                ("external", &self.kind.external),
                ("claimed", &self.kind.claimed),
                ("program", &self.kind.program),
                ("installed", &self.installed),
                ("version", &self.version),
                ("paste_state", &self.paste_state),
                ("running", &self.running),
            ],
        );
    }
}

/// "3.7c" from "tmux 3.7c", "0.9.3" from "herdr 0.9.3": the first line's last word.
pub(crate) fn version(stdout: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(stdout);
    let word = text.lines().next()?.split_whitespace().last()?;
    (word.len() <= 64 && word.chars().any(|c| c.is_ascii_digit())).then(|| word.to_owned())
}

/// tmux reports bracketed-paste state (`#{bracket_paste_flag}`) from 3.7 on; "next-3.8" and
/// "3.7c" count by their numbers.
pub(crate) fn paste_state(version: &str) -> Option<bool> {
    let digits = version.trim_start_matches(|c: char| !c.is_ascii_digit());
    let mut parts = digits.split(|c: char| !c.is_ascii_digit()).filter(|part| !part.is_empty());
    let major: u32 = parts.next()?.parse().ok()?;
    let minor: u32 = parts.next().and_then(|part| part.parse().ok()).unwrap_or(0);
    Some((major, minor) >= (3, 7))
}

impl Request<'_> {
    /// multiplexers.list with each program's version (feature multiplexers.versions).
    pub(super) fn versions(&mut self, kinds: Vec<Mux>) -> Result<(), Error> {
        let done = Rc::new(RefCell::new(Some(self.done::<Vec<Versioned>>(None))));
        let rows: Rc<RefCell<Vec<Option<Versioned>>>> = Rc::new(RefCell::new(Vec::new()));
        let remaining = Rc::new(Cell::new(kinds.len()));
        let finish = {
            let (done, rows, remaining) = (done.clone(), rows.clone(), remaining.clone());
            Rc::new(move |io: &mut dyn Io| {
                remaining.set(remaining.get() - 1);
                if remaining.get() == 0
                    && let Some(done) = done.borrow_mut().take()
                {
                    let rows = std::mem::take(&mut *rows.borrow_mut()).into_iter().flatten().collect();
                    done(io, Ok(rows));
                }
            })
        };
        for (slot, kind) in kinds.into_iter().enumerate() {
            let (command, probe) = {
                let mux = self.helper.multiplexers[kind.mux as usize].borrow();
                (mux.version(), mux.server_probe())
            };
            rows.borrow_mut().push(None);
            let Some(command) = command else {
                rows.borrow_mut()[slot] =
                    Some(Versioned { kind, installed: None, version: None, paste_state: None, running: None });
                finish(self.io);
                continue;
            };
            let mux = self.helper.multiplexers[kind.mux as usize].clone();
            let (rows, finish) = (rows.clone(), finish.clone());
            // Then whether its server runs: a probe that never starts one.
            let record = move |io: &mut dyn Io, result: std::io::Result<Output>| {
                let (installed, version) = match result {
                    Ok(Output::Exit { status: Some(0), stdout }) => (true, version(&stdout)),
                    Ok(_) => (true, None),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => (false, None),
                    Err(_) => (true, None),
                };
                let paste = (kind.name == "tmux").then(|| version.as_deref().and_then(paste_state)).flatten();
                let mut row = Versioned { kind, installed: Some(installed), version, paste_state: paste, running: None };
                let probe = probe.filter(|_| installed);
                let Some(probe) = probe else {
                    // Not installed: no server of it runs; no probe: unknown.
                    row.running = (!installed).then_some(false);
                    rows.borrow_mut()[slot] = Some(row);
                    return finish(io);
                };
                let deadline = io.now() + std::time::Duration::from_secs(3);
                let answer = move |io: &mut dyn Io, result: std::io::Result<Output>| {
                    row.running = Some(match result {
                        Ok(Output::Exit { status, stdout }) => mux.borrow().running(status, &stdout),
                        _ => false,
                    });
                    rows.borrow_mut()[slot] = Some(row);
                    finish(io);
                };
                match io.submit(Job::Run { command: probe, input: Vec::new(), deadline }) {
                    Ok(work) => io.then(work, Box::new(answer)),
                    Err(error) => answer(io, Err(error)),
                }
            };
            let deadline = self.io.now() + std::time::Duration::from_secs(3);
            match self.io.submit(Job::Run { command, input: Vec::new(), deadline }) {
                Ok(work) => self.io.then(work, Box::new(record)),
                Err(error) => record(self.io, Err(error)),
            }
        }
        Ok(())
    }
}

/// The silence after which a stdio.liveness client counts as gone: 45 s by default, so a phone
/// that pings (`echo`, the Mac's stats.ping) every 15 s may miss two pings.
/// DISPATCH_STDIO_LIVENESS_SECONDS (2 to 600) overrides it, for tests.
pub(crate) fn liveness(variable: Option<&std::ffi::OsStr>) -> std::time::Duration {
    let seconds = variable
        .and_then(|value| value.to_str())
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|seconds| (2..=600).contains(seconds))
        .unwrap_or(45);
    std::time::Duration::from_secs(seconds)
}

/// HOME as the login environment sees it, for hello.account.login_home: only an absolute UTF-8
/// path that is not the passwd home (`passwd`), else none.
pub(crate) fn login_home(passwd: &str, login: Option<&std::path::Path>) -> Option<String> {
    let login = login?.to_str()?;
    let trim = |path: &str| path.trim_end_matches('/').to_owned();
    (login.starts_with('/') && !login.contains('\0') && trim(login) != trim(passwd) && trim(login) != "")
        .then(|| login.to_owned())
}

/// A stdio.liveness client's last traffic and silence limit; `armed`: a timer is set.
pub(crate) struct Liveness {
    pub fd: RawFd,
    pub last: std::time::Instant,
    pub limit: std::time::Duration,
    pub armed: bool,
    /// Since when the helper has had read interest off on this client (its output backed up,
    /// too many replies waiting): silence the helper did not listen to is not the client's, so
    /// `last` moves on by that time when reading resumes, and no deadline runs meanwhile.
    pub unread: Option<std::time::Instant>,
}

impl Liveness {
    /// Follow whether the helper reads the client now (`Client::listening`); the clock is read
    /// only when that changes.
    pub(crate) fn listening(&mut self, listening: bool, now: impl FnOnce() -> std::time::Instant) {
        match (listening, self.unread) {
            (false, None) => self.unread = Some(now()),
            (true, Some(since)) => {
                self.last += now().saturating_duration_since(since);
                self.unread = None;
                // The deadline moved: arm again for the new one.
                self.armed = false;
            }
            _ => {}
        }
    }

    /// Whether the silence limit has passed at `now` (never while the helper is not reading).
    pub(crate) fn expired(&self, now: std::time::Instant) -> bool {
        self.unread.is_none() && now >= self.last + self.limit
    }
}

#[cfg(test)]
#[path = "features.test.rs"]
mod tests;
