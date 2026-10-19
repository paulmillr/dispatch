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
/// Operations that exist only for a client that named their feature.
pub(crate) const OPERATIONS: &[&str] = &[CHAT_LIST, PROJECTS_RECENT, TERMINALS_ACTIVITY];

/// The features each client connection asked for and got.
pub(crate) type Features = Rc<RefCell<BTreeMap<RawFd, BTreeSet<&'static str>>>>;

pub(crate) fn enabled(features: &Features, fd: RawFd, feature: &str) -> bool {
    features.borrow().get(&fd).is_some_and(|set| set.contains(feature))
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
        Err(Error {
            code: "unsupported",
            message: format!("Unknown operation {method}"),
        })
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
}

#[cfg(test)]
#[path = "features.test.rs"]
mod tests;
