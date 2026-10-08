//! Process-validated native registration. Files and process observations stay in System.
use crate::{
    history::{error, text, uuid},
    process,
};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json, Kind, Value},
};
use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
};

#[derive(Clone)]
pub struct Session {
    pub binding: Binding,
    pub status: String,
    /// Native reason while `status` is "waiting" (e.g. "permission prompt", "input needed").
    pub waiting: Option<String>,
    pub name: Option<String>,
    pub version: Option<String>,
    /// Registered working directory; side forks start there.
    pub directory: PathBuf,
    pub registry: PathBuf,
}

pub(crate) enum Consumer {
    Binding(Done<Option<Binding>>),
    State {
        binding: Binding,
        done: Option<Done<State>>,
    },
}
impl Consumer {
    pub fn complete(self, io: &mut dyn Io, binding: Option<Binding>, state: Result<State, Error>) {
        match self {
            Self::Binding(done) => deferred(done)(io, Ok(binding)),
            Self::State {
                binding: expected,
                done: Some(done),
            } => {
                let result = if binding.as_ref() == Some(&expected) {
                    state
                } else {
                    Err(error("changed", "Claude conversation changed"))
                };
                deferred(done)(io, result);
            }
            Self::State { done: None, .. } => {}
        }
    }
}
pub(crate) struct Observation {
    /// Start order per process; the newest one owns the shared registration state.
    pub serial: u64,
    pub probe: Probe,
    pub consumer: Consumer,
}

pub(crate) struct Probe {
    pub process: Process,
    pub session: Option<Session>,
    pub home: Option<PathBuf>,
    pub remote: bool,
    pub hook: Option<String>,
    stage: u8,
    facts: Option<Json>,
}

/// Claude's configuration directory for a process environment: e076fd7 ClaudeAgent.swift:129-131
/// `CLAUDE_CONFIG_DIR ?? (HOME ?? app home) + "/.claude"`; the account home is only the fallback.
pub(crate) fn home(environment: Value<'_>, account: Option<PathBuf>) -> Option<PathBuf> {
    text(environment, "CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(|| text(environment, "HOME").map(|s| PathBuf::from(s).join(".claude")))
        .or_else(|| account.map(|s| s.join(".claude")))
}
pub(crate) fn same(left: &Process, right: &Process) -> bool {
    left.pid == right.pid
        && left.start == right.start
        && left.executable == right.executable
        && left.tty == right.tty
        && left.group == right.group
}

fn native(name: &'static str, fields: Vec<(&str, Data<'_>)>) -> Result<Job, Error> {
    Ok(Job::Native {
        name,
        input: json::write(&Data::Object(fields))?,
    })
}

impl Probe {
    pub fn new(
        process: Process,
        hook: Option<String>,
        home: Option<PathBuf>,
        remote: bool,
    ) -> Self {
        Self {
            process,
            hook,
            home,
            remote,
            session: None,
            stage: 0,
            facts: None,
        }
    }
    pub fn job(&self) -> Result<Job, Error> {
        native(
            "process",
            vec![("pid", Data::Unsigned(self.process.pid.into()))],
        )
    }
    pub fn complete(&mut self, output: Output) -> Result<Option<Job>, Error> {
        if self.stage == 3 {
            let Output::Process(current) = output else {
                return Err(error("identity", "Missing Claude process"));
            };
            if !same(&self.process, &current) || !process::matches(&current) {
                return Err(error("changed", "Claude process changed"));
            }
            return Ok(None);
        }
        let Output::Bytes(bytes) = output else {
            return Err(error("identity", "Missing Claude identity facts"));
        };
        let doc = Json::parse(&bytes)?;
        let root = doc.root();
        let job = match self.stage {
            0 => {
                let start = root
                    .get("start")
                    .and_then(Value::array)
                    .map(|v| v.map(Value::unsigned).collect::<Option<Vec<_>>>())
                    .flatten();
                if root.get("pid").and_then(Value::unsigned) != Some(self.process.pid.into())
                    || start.as_deref() != Some(self.process.start.as_slice())
                    || text(root, "executable").map(Path::new)
                        != Some(self.process.executable.as_path())
                {
                    return Err(error("changed", "Claude process changed"));
                }
                self.facts = Some(doc);
                native(
                    "environment",
                    vec![
                        ("pid", Data::Unsigned(self.process.pid.into())),
                        (
                            "names",
                            Data::Array(vec![
                                Data::String("HOME"),
                                Data::String("CLAUDE_CONFIG_DIR"),
                            ]),
                        ),
                    ],
                )?
            }
            1 => {
                self.home = home(root, self.home.take());
                let home = self
                    .home
                    .as_ref()
                    .ok_or_else(|| error("identity", "Claude home unavailable"))?;
                if !home.is_absolute() || home.as_os_str().len() > 4096 {
                    return Err(error("identity", "Invalid Claude home"));
                }
                let path = home
                    .join("sessions")
                    .join(format!("{}.json", self.process.pid));
                native(
                    "file.private",
                    vec![
                        (
                            "path",
                            Data::String(
                                path.to_str()
                                    .ok_or_else(|| error("identity", "Invalid Claude path"))?,
                            ),
                        ),
                        ("limit", Data::Unsigned(65_536)),
                    ],
                )?
            }
            2 => {
                let facts = self.facts.as_ref().unwrap().root();
                let before = root
                    .get("before")
                    .ok_or_else(|| error("identity", "Missing registration metadata"))?;
                let after = root
                    .get("after")
                    .ok_or_else(|| error("identity", "Missing registration metadata"))?;
                let data =
                    text(root, "data").ok_or_else(|| error("identity", "Missing registration"))?;
                if before.write()? != after.write()?
                    || text(before, "kind") != Some("file")
                    || before.get("uid").and_then(Value::unsigned)
                        != facts.get("uid").and_then(Value::unsigned)
                    || before.get("size").and_then(Value::unsigned) != Some(data.len() as u64)
                {
                    return Err(error("identity", "Claude registration changed"));
                }
                let session = decode(
                    data.as_bytes(),
                    facts,
                    &self.process,
                    self.home.as_ref().unwrap(),
                    self.remote,
                )?;
                if self
                    .hook
                    .as_ref()
                    .is_some_and(|id| *id != session.binding.session)
                {
                    return Err(error("changed", "Claude conversation changed"));
                }
                self.session = Some(session);
                Job::Process {
                    pid: self.process.pid,
                }
            }
            _ => unreachable!(),
        };
        self.stage += 1;
        Ok(Some(job))
    }
}

pub fn decode(
    bytes: &[u8],
    facts: Value<'_>,
    process: &Process,
    home: &Path,
    remote: bool,
) -> Result<Session, Error> {
    let invalid = || error("identity", "Claude live session unavailable");
    if bytes.len() > 65_536 {
        return Err(invalid());
    }
    let doc = Json::parse(bytes)?;
    let root = doc.root();
    let domain = text(facts, "pid_domain").ok_or_else(invalid)?;
    let local = !remote && domain == "darwin";
    if !local {
        let known = [
            "pid",
            "kind",
            "pidDomain",
            "procStart",
            "sessionId",
            "cwd",
            "startedAt",
            "version",
            "status",
            "name",
            "nameSource",
        ];
        let mut keys = BTreeSet::new();
        for (key, value) in root.object().ok_or_else(invalid)? {
            if known.contains(&key) && !keys.insert(key) {
                return Err(invalid());
            }
            if ["version", "status", "name", "nameSource"].contains(&key)
                && !matches!(value.kind(), Kind::String | Kind::Null)
            {
                return Err(invalid());
            }
        }
    }
    let pid = root.get("pid").and_then(|v| {
        if local {
            v.number()
                .or_else(|| v.boolean().map(|b| u8::from(b) as f64))
                .filter(|n| n.fract() == 0.0)
                .map(|n| n as i64)
        } else {
            v.signed()
        }
    });
    let id = text(root, "sessionId")
        .filter(|s| uuid(s))
        .ok_or_else(invalid)?;
    let cwd = text(root, "cwd")
        .filter(|s| s.starts_with('/') && (local || s.len() <= 4096))
        .ok_or_else(invalid)?;
    let label = text(facts, "proc_start").ok_or_else(invalid)?;
    let started = root
        .get("startedAt")
        .and_then(Value::number)
        .ok_or_else(invalid)?
        / 1000.0;
    let birth = if local {
        process.start[0] as f64
    } else {
        facts
            .get("started_at")
            .and_then(Value::number)
            .ok_or_else(invalid)?
    };
    let tolerance = if domain.starts_with("linux:") {
        1.0
    } else {
        0.0
    };
    if pid != Some(process.pid.into())
        || text(root, "kind") != Some("interactive")
        || text(root, "pidDomain") != Some(domain)
        || text(root, "procStart").is_none_or(|s| s.split_whitespace().ne(label.split_whitespace()))
        || !started.is_finite()
        || started < 0.0
        || started < birth - tolerance
        || started >= birth + 30.0
    {
        return Err(invalid());
    }
    let project = project(cwd);
    Ok(Session {
        directory: cwd.into(),
        binding: Binding {
            session: id.into(),
            process: process.clone(),
            transcript: Some(
                home.join("projects")
                    .join(project)
                    .join(format!("{id}.jsonl")),
            ),
        },
        // Claude 2.1.290 reports an idle prompt with a running background shell task as "shell";
        // its prompt takes input like "idle".
        status: match text(root, "status").unwrap_or("unknown") {
            "shell" => "idle",
            status => status,
        }
        .into(),
        waiting: text(root, "waitingFor")
            .filter(|_| text(root, "status") == Some("waiting"))
            .map(str::to_owned),
        name: if text(root, "nameSource") == Some("derived") {
            None
        } else {
            text(root, "name").map(str::to_owned)
        },
        registry: home.join("sessions").join(format!("{}.json", process.pid)),
        version: text(root, "version").map(str::to_owned),
    })
}

/// Claude's folder name under `<config>/projects` for a session's cwd: Claude 2.1.284 AR() on
/// every platform. Each UTF-16 unit that is not an ASCII letter or digit becomes "-"; a name past
/// 200 characters keeps the first 200 plus "-" and the cwd's 32-bit `h * 31 + unit` hash over
/// UTF-16 units, absolute, in base 36.
pub fn project(cwd: &str) -> String {
    let name = cwd
        .encode_utf16()
        .map(|c| {
            if c < 128 && (c as u8).is_ascii_alphanumeric() {
                char::from(c as u8)
            } else {
                '-'
            }
        })
        .collect::<String>();
    if name.len() <= 200 {
        return name;
    }
    let hash = cwd
        .encode_utf16()
        .fold(0i32, |h, c| h.wrapping_mul(31).wrapping_add(c.into()));
    let digits = std::iter::successors(Some(i64::from(hash).unsigned_abs()), |n| {
        (*n >= 36).then_some(n / 36)
    })
    .map(|n| char::from(b"0123456789abcdefghijklmnopqrstuvwxyz"[(n % 36) as usize]))
    .collect::<String>();
    format!(
        "{}-{}",
        &name[..200],
        digits.chars().rev().collect::<String>()
    )
}
