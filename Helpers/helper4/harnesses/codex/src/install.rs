//! Codex hook installation: the c51466a ssh-helper append-only planner (hooks.rs) on the Codex
//! hooks.json that c1654cc AgentHookSetup located (CodexHookSetup.swift).
//! The helper binary is the hook; it reads its endpoint from DISPATCH_HELPER4_ENDPOINT.
use crate::{
    channel::{failure, os},
    jobs::{self, Jobs},
};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json, Kind, Value},
    wire::LIMIT,
};
use std::{collections::BTreeMap, path::PathBuf};

/// AgentHookSetup.events (CodexHookSetup.swift:4).
const EVENTS: [&str; 10] = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "PreCompact",
    "PostCompact",
    "Stop",
    "Interrupt",
];

/// No key twice in any object (c51466a hooks.rs:194-196 UniqueValue: rewriting such a file could
/// delete an unrelated handler or setting).
fn unique(value: Value<'_>) -> bool {
    match value.kind() {
        Kind::Object => {
            let mut keys: Vec<&str> = value.object().unwrap().map(|(key, _)| key).collect();
            let count = keys.len();
            keys.sort_unstable();
            keys.dedup();
            keys.len() == count && value.object().unwrap().all(|(_, value)| unique(value))
        }
        Kind::Array => value.array().unwrap().all(unique),
        _ => true,
    }
}

/// c51466a hooks.rs:155-182: matcher null or text; handlers are objects with a type, a command
/// text for command handlers, a positive integer or null timeout and a boolean async.
fn valid(group: Value<'_>) -> bool {
    let matcher = group.get("matcher");
    let handlers = group.get("hooks").and_then(Value::array);
    group.kind() == Kind::Object
        && matcher.is_none_or(|value| value.kind() == Kind::Null || value.string().is_some())
        && handlers.is_some_and(|mut handlers| {
            handlers.all(|handler| {
                let kind = handler.get("type").and_then(Value::string);
                let timeout = handler.get("timeout");
                handler.kind() == Kind::Object
                    && kind.is_some_and(|kind| !kind.is_empty())
                    && (kind != Some("command")
                        || handler.get("command").and_then(Value::string).is_some())
                    && timeout.is_none_or(|value| {
                        value.kind() == Kind::Null
                            || value.unsigned().is_some_and(|value| value > 0)
                    })
                    && handler
                        .get("async")
                        .is_none_or(|value| value.boolean().is_some())
            })
        })
}

/// A native value with every object's keys in byte order (serde_json's map without
/// preserve_order, as the old planner wrote it).
fn sorted(value: Value<'_>) -> Data<'_> {
    match value.kind() {
        Kind::Object => {
            let mut fields: Vec<_> = value
                .object()
                .unwrap()
                .map(|(key, value)| (key, sorted(value)))
                .collect();
            fields.sort_by(|a, b| a.0.cmp(b.0));
            Data::Object(fields)
        }
        Kind::Array => Data::Array(value.array().unwrap().map(sorted).collect()),
        _ => Data::Value(value),
    }
}

/// c51466a ssh-helper hooks.rs:78-150, the user's choice (2026-10-03) over AgentHookSetup's
/// remove+append: Codex trust keys include event/group/handler indices, so existing groups are
/// never removed, reordered or edited. Each event without an unfiltered synchronous group running
/// our command gets one appended (timeout 60 for PermissionRequest, else 3). None = nothing to
/// change: no write, no trust change. Output: compact, sorted keys, final newline.
fn plan(before: Option<&[u8]>, command: &str) -> Result<Option<Vec<u8>>, Error> {
    let invalid = || failure("hook", "Invalid agent hook configuration");
    if command.is_empty() || command.len() > 4096 || command.chars().any(char::is_control) {
        return Err(invalid());
    }
    let document = match before {
        Some(bytes) if bytes.len() <= 1_048_576 => Some(Json::parse(bytes).map_err(|_| invalid())?),
        Some(_) => return Err(invalid()),
        None => None,
    };
    let root = document.as_ref().map(Json::root);
    if root.is_some_and(|root| root.kind() != Kind::Object || !unique(root)) {
        return Err(invalid());
    }
    let hooks = root.and_then(|root| root.get("hooks"));
    let mut events: Vec<(&str, Vec<Data<'_>>)> = Vec::new();
    for (event, groups) in hooks
        .map(|hooks| hooks.object().ok_or_else(invalid))
        .transpose()?
        .into_iter()
        .flatten()
    {
        let groups: Vec<_> = groups.array().ok_or_else(invalid)?.collect();
        if !groups.iter().all(|group| valid(*group)) {
            return Err(invalid());
        }
        events.push((event, groups.into_iter().map(sorted).collect()));
    }
    let ours = |handler: Value<'_>| {
        handler.get("type").and_then(Value::string) == Some("command")
            && handler.get("command").and_then(Value::string) == Some(command)
            && handler
                .get("async")
                .is_none_or(|value| value.boolean() == Some(false))
    };
    let installed = |event: &str| {
        hooks
            .and_then(|hooks| hooks.get(event))
            .and_then(Value::array)
            .is_some_and(|mut groups| {
                groups.any(|group| {
                    group
                        .get("matcher")
                        .is_none_or(|value| value.kind() == Kind::Null)
                        && group
                            .get("hooks")
                            .and_then(Value::array)
                            .is_some_and(|mut handlers| handlers.any(ours))
                })
            })
    };
    let missing: Vec<&str> = EVENTS
        .into_iter()
        .filter(|event| !installed(event))
        .collect();
    if missing.is_empty() {
        return Ok(None);
    }
    for event in missing {
        let timeout = if event == "PermissionRequest" { 60 } else { 3 };
        let group = Data::Object(vec![(
            "hooks",
            Data::Array(vec![Data::Object(vec![
                ("command", Data::String(command)),
                ("timeout", Data::Unsigned(timeout)),
                ("type", Data::String("command")),
            ])]),
        )]);
        match events.iter_mut().find(|(name, _)| *name == event) {
            Some((_, groups)) => groups.push(group),
            None => events.push((event, vec![group])),
        }
    }
    events.sort_by(|a, b| a.0.cmp(b.0));
    let hooks = Data::Object(
        events
            .into_iter()
            .map(|(event, groups)| (event, Data::Array(groups)))
            .collect(),
    );
    let mut fields: Vec<_> = root
        .and_then(Value::object)
        .into_iter()
        .flatten()
        .filter(|(key, _)| *key != "hooks")
        .map(|(key, value)| (key, sorted(value)))
        .chain([("hooks", hooks)])
        .collect();
    fields.sort_by(|a, b| a.0.cmp(b.0));
    let mut bytes = json::write(&Data::Object(fields))?;
    bytes.push(b'\n');
    Ok(Some(bytes))
}

/// One installation: the helper hook command, the Codex config directory and the request.
struct Setup {
    jobs: Jobs,
    command: String,
    directory: PathBuf,
    enabled: Option<bool>,
    done: Done<Install>,
}

/// Audit (None) reports the current state and the edit an install would make; Some(true) installs,
/// Some(false) leaves the file as it is and reports the state. For a running `agent` the target is
/// that process's CODEX_HOME, else the account's ~/.codex (c51466a hook_transport.rs:1059-1072);
/// without one the helper's own $CODEX_HOME, else ~/.codex (CodexHookSetup.swift:11-13).
pub fn run(
    jobs: &Jobs,
    io: &mut dyn Io,
    enabled: Option<bool>,
    agent: Option<Binding>,
    done: Done<Install>,
) {
    // The stable helper path (core A14; old ssh-helper hook_file.rs:346-395): the hook command,
    // and Codex's trust in it, survive helper updates. One single-quoted path
    // (CodexHookSetup.swift:24).
    let executable = match io.executable() {
        Ok(executable) => executable,
        Err(error) => return deferred(done)(io, Err(os(error))),
    };
    let executable = executable.to_string_lossy().replace('\'', "'\\''");
    let command = format!("'{executable}' hook codex");
    let (next, pid) = (jobs.clone(), io.pid());
    variables(jobs, io, pid, &["CODEX_HOME", "HOME"], move |io, own| {
        let jobs = next.clone();
        let finish =
            move |io: &mut dyn Io, directory: Result<Option<PathBuf>, Error>| match directory {
                Ok(Some(directory)) => inspect(
                    io,
                    Setup {
                        jobs,
                        command,
                        directory,
                        enabled,
                        done,
                    },
                ),
                Ok(None) => done(
                    io,
                    Err(failure(
                        "environment",
                        "Neither CODEX_HOME nor HOME is set.",
                    )),
                ),
                Err(error) => done(io, Err(error)),
            };
        let own = match own {
            Ok(own) => own,
            Err(error) => return finish(io, Err(error)),
        };
        let account = own.get("HOME").map(|home| home.join(".codex"));
        let Some(agent) = agent else {
            return finish(io, Ok(own.get("CODEX_HOME").cloned().or(account)));
        };
        running(&next.clone(), io, agent, move |io, theirs| {
            finish(io, theirs.map(|theirs| theirs.or(account)))
        });
    });
}

/// The running agent's CODEX_HOME, read while it is still the same process (the old helper's
/// same_process check after capturing it).
fn running(
    jobs: &Jobs,
    io: &mut dyn Io,
    agent: Binding,
    then: impl FnOnce(&mut dyn Io, Result<Option<PathBuf>, Error>) + 'static,
) {
    let (next, pid) = (jobs.clone(), agent.process.pid);
    variables(jobs, io, pid, &["CODEX_HOME"], move |io, theirs| {
        let theirs = match theirs {
            Ok(theirs) => theirs,
            Err(error) => return then(io, Err(error)),
        };
        let input = Data::Object(vec![("pid", Data::Unsigned(pid.into()))]);
        let check = Box::new(move |io: &mut dyn Io, result: Result<Json, Error>| {
            let current = result.and_then(|value| jobs::process(value.root()));
            then(
                io,
                current.and_then(|process| {
                    let same = process.start == agent.process.start
                        && process.executable == agent.process.executable;
                    match same {
                        true => Ok(theirs.get("CODEX_HOME").cloned()),
                        false => Err(failure("process", "The agent exited.")),
                    }
                }),
            )
        });
        jobs::native(&next, io, "process", input, check);
    });
}

/// The non-empty `names` of process `pid`'s environment, as paths.
fn variables(
    jobs: &Jobs,
    io: &mut dyn Io,
    pid: u32,
    names: &[&'static str],
    then: impl FnOnce(&mut dyn Io, Result<BTreeMap<String, PathBuf>, Error>) + 'static,
) {
    let names = Data::Array(names.iter().copied().map(Data::String).collect());
    let input = Data::Object(vec![("pid", Data::Unsigned(pid.into())), ("names", names)]);
    let read = Box::new(move |io: &mut dyn Io, result: Result<Json, Error>| {
        let values = result.map(|value| {
            let values = value.root().object().into_iter().flatten();
            values
                .filter_map(|(name, value)| {
                    let text = value.string().filter(|text| !text.is_empty())?;
                    Some((name.to_owned(), PathBuf::from(text)))
                })
                .collect()
        });
        then(io, values)
    });
    jobs::native(jobs, io, "environment", input, read);
}

/// Reads hooks.json (no-follow private read); an install with something to append commits,
/// every other request reports.
fn inspect(io: &mut dyn Io, setup: Setup) {
    let path = setup.directory.join("hooks.json");
    let text = path.to_string_lossy().into_owned();
    let input = Data::Object(vec![
        ("path", Data::String(&text)),
        ("limit", Data::Unsigned(LIMIT.into())),
    ]);
    let jobs = setup.jobs.clone();
    jobs::native(
        &jobs,
        io,
        "file.private",
        input,
        Box::new(move |io, result| {
            // The bytes, mode and the guard a write must still match (core B1); a file that
            // changed while it was read is refused like the old helper's original recheck.
            let file = match result {
                Err(error) if error.code == "not_found" => Ok(None),
                result => result.and_then(|value| {
                    let root = value.root();
                    let metadata = |value: Value<'_>| {
                        Some(Guard::from(Metadata {
                            kind: FileKind::File,
                            size: value.get("size")?.unsigned()?,
                            device: value.get("device")?.unsigned()?,
                            inode: value.get("inode")?.unsigned()?,
                            modified_ns: value.get("mtime_ns")?.signed()?.into(),
                            changed_ns: value.get("ctime_ns")?.signed()?.into(),
                        }))
                    };
                    let before = root.get("before");
                    let guard = before
                        .and_then(metadata)
                        .filter(|guard| root.get("after").and_then(metadata) == Some(*guard));
                    let mode = before
                        .and_then(|before| before.get("mode"))
                        .and_then(Value::unsigned);
                    match (root.get("data").and_then(Value::string), mode, guard) {
                        (Some(data), Some(mode), Some(guard)) => {
                            Ok(Some((data.as_bytes().to_vec(), mode as u32 & 0o777, guard)))
                        }
                        _ => Err(failure(
                            "changed",
                            "Agent settings changed during setup. Try again.",
                        )),
                    }
                }),
            };
            let (before, mode, expected) = match file {
                Ok(Some((bytes, mode, guard))) => (Some(bytes), mode, Expected::Same(guard)),
                Ok(None) => (None, 0o600, Expected::Absent),
                Err(error) => return (setup.done)(io, Err(error)),
            };
            let plan = plan(before.as_deref(), &setup.command);
            let edit = |after| Edit {
                path,
                before: before.clone(),
                after: Some(after),
                backup: None,
            };
            match (setup.enabled, plan) {
                // Installed = nothing left to append (hooks.rs:150).
                (Some(true), Ok(Some(after))) => commit(io, setup, edit(after), mode, expected),
                (Some(true), Ok(None)) => (setup.done)(io, Ok(facts(Vec::new(), true))),
                (Some(true), Err(error)) => (setup.done)(io, Err(error)),
                // An audit shows the edit an install would make; disabling never edits the file
                // (the old helper turned hooks off in its router, backend.rs:126-137).
                (_, plan) => {
                    let installed = matches!(plan, Ok(None));
                    let edits = plan.ok().flatten().map(edit).into_iter().collect();
                    let edits = if setup.enabled.is_none() {
                        edits
                    } else {
                        Vec::new()
                    };
                    (setup.done)(io, Ok(facts(edits, installed)))
                }
            }
        }),
    );
}

/// Writes one edit only if hooks.json is still what was read (core B1 checked write: locked
/// recheck, no links, mode and group kept; old hook_file.rs:95-232). A concurrent change fails
/// with ESTALE/EEXIST and nothing changes.
fn commit(io: &mut dyn Io, setup: Setup, edit: Edit, mode: u32, expected: Expected) {
    let Setup {
        jobs,
        directory,
        done,
        ..
    } = setup;
    let next = jobs.clone();
    let create = Job::MakeDir {
        path: directory,
        mode: 0o700,
    };
    jobs::submit(
        &jobs,
        io,
        create,
        Box::new(move |io, result| {
            if let Err(error) = result {
                return done(io, Err(error));
            }
            let (path, bytes) = (edit.path.clone(), edit.after.clone().unwrap());
            let write = Job::Write {
                path,
                bytes,
                mode,
                expected,
            };
            jobs::submit(
                &next,
                io,
                write,
                Box::new(move |io, result| {
                    let result = result.map_err(|error| match error.code {
                        "changed" => {
                            failure("changed", "Agent settings changed during setup. Try again.")
                        }
                        _ => error,
                    });
                    done(io, result.map(|_| facts(vec![edit], true)))
                }),
            );
        }),
    );
}

/// The Install facts core derives the old status from (core decision I1; SettingsView.swift:414).
fn facts(edits: Vec<Edit>, installed: bool) -> Install {
    Install {
        restart: edits.iter().any(|edit| edit.before != edit.after),
        edits,
        installed,
        optional: false,
        reload: None,
        trust: Some("/hooks".into()),
    }
}
