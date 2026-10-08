use crate::{
    channel::{failure, os},
    history,
};
use dispatch_helper_core::api::*;
use dispatch_helper_core::json::{self, Data, Value};
use std::{
    cell::RefCell,
    collections::BTreeMap,
    path::PathBuf,
    process::{Command, Stdio},
    rc::Rc,
    time::Duration,
};

pub type Jobs = Rc<RefCell<BTreeMap<Work, Done<Output>>>>;

pub fn submit(jobs: &Jobs, io: &mut dyn Io, job: Job, done: Done<Output>) {
    let done = deferred(done);
    match io.submit(job) {
        Ok(work) => {
            jobs.borrow_mut().insert(work, done);
        }
        Err(error) => done(io, Err(os(error))),
    }
}

pub fn native(jobs: &Jobs, io: &mut dyn Io, name: &'static str, input: Data<'_>, done: Done<Json>) {
    let input = match json::write(&input) {
        Ok(input) => input,
        Err(error) => {
            deferred(done)(io, Err(error));
            return;
        }
    };
    submit(
        jobs,
        io,
        Job::Native { name, input },
        Box::new(move |io, result| {
            let result = result.and_then(|output| match output {
                Output::Bytes(bytes) => Json::parse(&bytes),
                _ => Err(failure("native", "Invalid native result")),
            });
            deferred(done)(io, result);
        }),
    );
}

/// A random version 4 UUID as text, like Foundation's UUID().uuidString.
pub fn uuid(io: &mut dyn Io) -> std::io::Result<String> {
    let mut id = [0; 16];
    io.random(&mut id)?;
    id[6] = id[6] & 0x0f | 0x40;
    id[8] = id[8] & 0x3f | 0x80;
    let hex: String = id.iter().map(|byte| format!("{byte:02X}")).collect();
    let parts = [
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..],
    ];
    Ok(parts.join("-"))
}

/// Codex executables already asked for `--version`: (path, device, inode, mtime) -> identified.
/// c1654cc CodexVersionCache: never spawn --version again for the same file while rechecking.
pub type Headers = Rc<RefCell<BTreeMap<(PathBuf, u64, u64), u64>>>;
#[derive(Default)]
pub struct Versions {
    files: BTreeMap<(PathBuf, u64, u64, i128), Option<String>>,
    pub processes: BTreeMap<(u32, [u64; 2]), String>,
}

#[allow(clippy::too_many_arguments)]
pub fn scan(
    jobs: Jobs,
    io: &mut dyn Io,
    process: Process,
    mut files: Vec<OpenFile>,
    session: Option<String>,
    mut found: Vec<Binding>,
    versions: Rc<RefCell<Versions>>,
    headers: Headers,
    done: Done<Option<Binding>>,
) {
    let Some(OpenFile { path, identity }) = files.pop() else {
        match found.len() {
            0 => provisional(jobs, io, process, versions, done),
            1 => deferred(done)(io, Ok(found.pop())),
            _ => deferred(done)(
                io,
                Err(failure(
                    "identity",
                    "Multiple Codex session files are open. Continue in terminal until the session is unambiguous.",
                )),
            ),
        }
        return;
    };
    let key = (path.clone(), identity.device, identity.inode);
    let length = headers.borrow().get(&key).copied().unwrap_or(65_536);
    let next = jobs.clone();
    submit(
        &jobs,
        io,
        Job::Read {
            path: path.clone(),
            offset: 0,
            length,
        },
        Box::new(move |io, result| {
            // The path must still name the file the process holds open (old: read through its
            // descriptor), so a replaced rollout cannot change the discovered session.
            let open = |metadata: &Metadata| {
                (metadata.device, metadata.inode) == (identity.device, identity.inode)
            };
            let result = match result {
                Err(error) => {
                    let observed = process.clone();
                    return native(&next, io, "process", Data::Object(vec![("pid", Data::Unsigned(process.pid.into()))]), Box::new(move |io, result| {
                        let gone = match result {
                            Err(failure) => failure.code == "not_found",
                            Ok(document) => self::process(document.root()).is_ok_and(|current| current.pid != observed.pid || current.start != observed.start),
                        };
                        deferred(done)(io, if gone { Ok(None) } else { Err(error) });
                    }));
                }
                value => value,
            };
            if let Ok(Output::Read { bytes, before, after }) = result {
                if !open(&before) || !open(&after) {
                    headers.borrow_mut().remove(&key);
                    return scan(next, io, process, files, session, found, versions, headers, Box::new(move |io, result| {
                        let result = match result {
                            Ok(Some(binding)) if binding.transcript.is_some() => Ok(Some(binding)),
                            Err(error) => Err(error),
                            _ => Err(failure("identity", "The Codex rollout identity changed.")),
                        };
                        done(io, result);
                    }));
                }
                let header = history::identity(&bytes);
                if header.is_none() && length < 65_536 && bytes.len() as u64 == length {
                    headers.borrow_mut().remove(&key);
                    files.push(OpenFile { path, identity });
                    return scan(next, io, process, files, session, found, versions, headers, done);
                }
                if let Some((id, _, subagent)) = header {
                    let end = bytes.split_inclusive(|byte| *byte == b'\n')
                        .scan(0, |end, line| { *end += line.len(); Some((line, *end)) })
                        .find_map(|(line, end)| history::identity(line).map(|_| end)).unwrap();
                    headers.borrow_mut().insert(key, end as u64);
                    if !subagent && crate::hooks::uuid(&id) && session.as_ref().is_none_or(|session| *session == id) {
                        found.push(Binding { session: id, transcript: Some(path), process: process.clone() });
                    }
                }
            }
            scan(next, io, process, files, session, found, versions, headers, done);
        }),
    );
}

pub fn process(value: Value<'_>) -> Result<Process, Error> {
    let read = || {
        let mut start = value.get("start")?.array()?;
        let start = [start.next()?.unsigned()?, start.next()?.unsigned()?];
        Some(Process {
            pid: value.get("pid")?.unsigned()?.try_into().ok()?,
            parent: value.get("parent")?.unsigned()?.try_into().ok()?,
            group: value.get("group")?.signed()?.try_into().ok()?,
            foreground: value.get("foreground")?.signed()?.try_into().ok()?,
            tty: value.get("tty")?.unsigned()?,
            start,
            executable: value.get("executable")?.string()?.into(),
            arguments: value
                .get("arguments")?
                .array()?
                .map(|value| Some(value.string()?.into()))
                .collect::<Option<Vec<_>>>()?,
            files: value
                .get("files")?
                .array()?
                .map(OpenFile::parse)
                .collect::<Option<Vec<_>>>()?,
        })
    };
    read().ok_or_else(|| failure("process", "Invalid parent process"))
}

/// c1654cc AgentDiscovery.swift:151-156: Codex creates its rollout only with the first turn, so a
/// TUI without one stays associated without a session (core P1: session "") once its executable
/// identifies as `codex-cli <version>`; otherwise the old "cannot identify" refusal.
fn provisional(
    jobs: Jobs,
    io: &mut dyn Io,
    process: Process,
    versions: Rc<RefCell<Versions>>,
    done: Done<Option<Binding>>,
) {
    let path = PathBuf::from(&process.executable);
    let stat = Job::Stat {
        path: path.clone(),
        follow: true,
    };
    let next = jobs.clone();
    submit(
        &jobs,
        io,
        stat,
        Box::new(move |io, result| {
            let known = versions.clone();
            let finish = move |io: &mut dyn Io, version: Option<String>| {
                let identified = version.is_some();
                if let Some(version) = version {
                    known
                        .borrow_mut()
                        .processes
                        .insert((process.pid, process.start), version);
                }
                let binding = Binding {
                    session: String::new(),
                    transcript: None,
                    process,
                };
                let refused = || {
                    let message = "Cannot identify this Codex executable. Continue in terminal.";
                    failure("identity", message)
                };
                done(io, identified.then_some(Some(binding)).ok_or_else(refused))
            };
            let Ok(Output::Metadata(metadata)) = result else {
                return finish(io, None);
            };
            let key = (
                path.clone(),
                metadata.device,
                metadata.inode,
                metadata.modified_ns,
            );
            let cached = versions.borrow().files.get(&key).cloned();
            if let Some(version) = cached {
                return finish(io, version);
            }
            let mut command = Command::new(&path);
            command
                .arg("--version")
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::null());
            let run = Job::Run {
                command,
                input: Vec::new(),
                deadline: io.now() + Duration::from_secs(2),
            };
            submit(
                &next,
                io,
                run,
                Box::new(move |io, result| {
                    let version = match result {
                        Ok(Output::Exit { stdout, .. }) => {
                            String::from_utf8(stdout).ok().and_then(|text| {
                                let version = text.trim().strip_prefix("codex-cli ")?.trim();
                                (!version.is_empty()).then(|| version.to_owned())
                            })
                        }
                        _ => None,
                    };
                    versions.borrow_mut().files.insert(key, version.clone());
                    finish(io, version);
                }),
            );
        }),
    );
}
