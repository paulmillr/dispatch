//! The existing Pi marker/digest policy preserves files edited by the user.
use crate::bridge::{self, Shared};
use crate::digest;
use crate::records::text;
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json, Value},
};
use std::{path::PathBuf, rc::Rc};

const SCRIPT: &[u8] = include_bytes!("../resources/bridge.js");
const MARKER: &[u8] = b"// Dispatch's opt-in bridge for an existing interactive Pi session.\n";
const OWNER: &str = "Dispatch Pi chat extension";
struct Setup {
    uid: u64,
    paths: Vec<PathBuf>,
    missing: bool,
    files: Vec<Option<Vec<u8>>>,
    expected: Vec<Expected>,
    alias: bool,
    changed: bool,
    enabled: Option<bool>,
    done: Option<Done<Install>>,
}
type SharedSetup = Rc<std::cell::RefCell<Setup>>;
pub fn run(
    runtime: &Shared,
    io: &mut dyn Io,
    enabled: Option<bool>,
    agent: Option<&Binding>,
    done: Done<Install>,
) {
    let process = agent.map(|agent| agent.process.clone());
    let pid = process
        .as_ref()
        .map_or_else(|| io.pid(), |process| process.pid);
    let saved = runtime.clone();
    bridge::native(
        runtime,
        io,
        "process",
        Data::Object(vec![("pid", Data::Unsigned(pid.into()))]),
        Box::new(move |io, result| {
            let uid = match result.and_then(|v| {
                v.root()
                    .get("uid")
                    .and_then(Value::unsigned)
                    .ok_or_else(|| bridge::fail("install", "The executing account is unavailable."))
            }) {
                Ok(uid) => uid,
                Err(e) => {
                    done(io, Err(e));
                    return;
                }
            };
            let next = saved.clone();
            let mut fields = vec![
                ("pid", Data::Unsigned(pid.into())),
                (
                    "names",
                    Data::Array(vec![
                        Data::String("HOME"),
                        Data::String("PI_CODING_AGENT_DIR"),
                    ]),
                ),
            ];
            if let Some(process) = &process {
                fields.push((
                    "start",
                    Data::Array(process.start.iter().copied().map(Data::Unsigned).collect()),
                ));
                fields.push((
                    "executable",
                    Data::String(process.executable.to_str().unwrap_or("")),
                ));
            }
            bridge::native(
                &saved,
                io,
                "environment",
                Data::Object(fields),
                Box::new(move |io, result| {
                    let root = match result {
                        Ok(v) => v,
                        Err(e) => {
                            done(io, Err(e));
                            return;
                        }
                    };
                    let home = match bridge::home(&next, root.root()) {
                        Ok(home) => PathBuf::from(home),
                        Err(error) => {
                            done(io, Err(error));
                            return;
                        }
                    };
                    let paths = vec![
                        home.clone(),
                        home.join("extensions"),
                        home.join("dispatch"),
                        home.join("extensions/dispatch-chat.js"),
                        home.join("dispatch/pi-chat-installation.json"),
                    ];
                    let setup = Rc::new(std::cell::RefCell::new(Setup {
                        uid,
                        paths,
                        missing: false,
                        files: Vec::new(),
                        expected: Vec::new(),
                        alias: false,
                        changed: false,
                        enabled,
                        done: Some(done),
                    }));
                    inspect(&next, io, setup, 0);
                }),
            );
        }),
    );
}
fn preserved(path: &std::path::Path) -> Error {
    bridge::fail(
        "install",
        format!(
            "A different or modified file exists at {}. It was preserved.",
            path.display()
        ),
    )
}
fn inspect(runtime: &Shared, io: &mut dyn Io, setup: SharedSetup, index: usize) {
    if index == 5 {
        let path = {
            let state = setup.borrow();
            state.files[1]
                .as_deref()
                .and_then(|bytes| Json::parse(bytes).ok())
                .map(|value| text(value.root(), "path"))
                .filter(|path| !path.is_empty() && *path != state.paths[3].to_string_lossy())
        };
        if let Some(path) = path {
            let next = runtime.clone();
            bridge::job(
                runtime,
                io,
                Job::Stat {
                    path: PathBuf::from(path),
                    follow: false,
                },
                Box::new(move |io, result| {
                    if let Ok(Output::Metadata(metadata)) = result {
                        let mut state = setup.borrow_mut();
                        state.alias = state.expected[0] == Expected::Same(Guard::from(metadata));
                    }
                    apply(&next, io, setup);
                }),
            );
            return;
        }
        apply(runtime, io, setup);
        return;
    }
    let path = setup.borrow().paths[index].to_string_lossy().into_owned();
    let next = runtime.clone();
    bridge::native(
        runtime,
        io,
        if index < 3 {
            "file.lstat"
        } else {
            "file.private"
        },
        Data::Object(if index < 3 {
            vec![("path", Data::String(&path))]
        } else {
            vec![
                ("path", Data::String(&path)),
                ("limit", Data::Unsigned(1_048_576)),
            ]
        }),
        Box::new(move |io, result| {
            let mut state = setup.borrow_mut();
            match result {
                Err(e) if e.code == "not_found" => {
                    if index < 3 {
                        state.missing = true;
                    } else {
                        state.files.push(None);
                        state.expected.push(Expected::Absent);
                    }
                }
                Ok(v) => {
                    let metadata = if index < 3 {
                        Some(v.root())
                    } else {
                        v.root().get("before")
                    };
                    let valid = metadata.is_some_and(|v| {
                        v.get("uid").and_then(Value::unsigned) == Some(state.uid)
                            && (index >= 3 || text(v, "kind") == "directory")
                            && (index < 3 || v.get("links").and_then(Value::unsigned) == Some(1))
                            && (index != 3
                                || v.get("mode")
                                    .and_then(Value::unsigned)
                                    .is_some_and(|mode| mode & 0o022 == 0))
                            && (index != 4
                                || v.get("mode")
                                    .and_then(Value::unsigned)
                                    .is_some_and(|v| v & 0o077 == 0))
                    });
                    if !valid {
                        let error = preserved(&state.paths[index]);
                        let done = state.done.take().unwrap();
                        drop(state);
                        done(io, Err(error));
                        return;
                    }
                    if index >= 3 {
                        let guard = |value: Value<'_>| {
                            Some(Guard::from(Metadata {
                                kind: FileKind::File,
                                size: value.get("size")?.unsigned()?,
                                device: value.get("device")?.unsigned()?,
                                inode: value.get("inode")?.unsigned()?,
                                modified_ns: value.get("mtime_ns")?.signed()?.into(),
                                changed_ns: value.get("ctime_ns")?.signed()?.into(),
                            }))
                        };
                        let before = v.root().get("before").and_then(guard);
                        let after = v.root().get("after").and_then(guard);
                        if before.is_none() || before != after {
                            let error = preserved(&state.paths[index]);
                            let done = state.done.take().unwrap();
                            drop(state);
                            done(io, Err(error));
                            return;
                        }
                        state.expected.push(Expected::Same(before.unwrap()));
                        state.files.push(Some(text(v.root(), "data").into_bytes()));
                    }
                }
                Err(_) => {
                    let error = preserved(&state.paths[index]);
                    let done = state.done.take().unwrap();
                    drop(state);
                    done(io, Err(error));
                    return;
                }
            }
            drop(state);
            inspect(&next, io, setup, index + 1);
        }),
    );
}
fn apply(runtime: &Shared, io: &mut dyn Io, setup: SharedSetup) {
    let state = setup.borrow();
    let result = (|| {
        let script = &state.paths[3];
        let receipt = &state.paths[4];
        let saved = state.files[1]
            .as_deref()
            .map(Json::parse)
            .transpose()
            .map_err(|_| preserved(receipt))?;
        let hash = saved
            .as_ref()
            .map(|v| {
                let value = v.root();
                let hash = text(value, "sha256");
                if value.get("schema").and_then(Value::unsigned) != Some(1)
                    || text(value, "owner") != OWNER
                    || (text(value, "path") != script.to_string_lossy() && !state.alias)
                    || hash.len() != 64
                    || !hash.bytes().all(|v| v.is_ascii_hexdigit())
                {
                    return Err(preserved(receipt));
                }
                Ok(hash)
            })
            .transpose()?;
        if let Some(bytes) = &state.files[0] {
            // Exact old bundled hash also permits the existing receipt-less installation.
            if !bytes.starts_with(MARKER)
                || hash.as_ref().map_or_else(
                    || bytes != SCRIPT && digest(bytes) != OLD,
                    |hash| digest(bytes) != *hash,
                )
            {
                return Err(preserved(script));
            }
        }
        let disabled = state.enabled == Some(false);
        let after = if disabled {
            None
        } else {
            Some(SCRIPT.to_vec())
        };
        let receipt = if disabled {
            None
        } else {
            let hash = digest(SCRIPT);
            Some(json::write(&Data::Object(vec![
                ("schema", Data::Unsigned(1)),
                ("owner", Data::String(OWNER)),
                ("path", Data::String(&script.to_string_lossy())),
                ("sha256", Data::String(&hash)),
            ]))?)
        };
        Ok(Install {
            trust: None,
            installed: state.files[0].is_some(),
            optional: true,
            reload: Some("/reload".into()),
            restart: state.files[0] != after,
            edits: vec![
                Edit {
                    path: script.clone(),
                    before: state.files[0].clone(),
                    after,
                    backup: None,
                },
                Edit {
                    path: state.paths[4].clone(),
                    before: state.files[1].clone(),
                    after: receipt,
                    backup: None,
                },
            ],
        })
    })();
    let missing = state.missing;
    let enabled = state.enabled;
    drop(state);
    let result = match result {
        Ok(result) => result,
        Err(e) => {
            setup.borrow_mut().done.take().unwrap()(io, Err(e));
            return;
        }
    };
    if enabled.is_none() {
        setup.borrow_mut().done.take().unwrap()(io, Ok(result));
    } else if missing && enabled == Some(true) {
        create(runtime, io, setup, 0);
    } else {
        write(runtime, io, setup, Rc::new(result), 0);
    }
}
fn create(runtime: &Shared, io: &mut dyn Io, setup: SharedSetup, index: usize) {
    if index == 3 {
        {
            let mut setup = setup.borrow_mut();
            setup.missing = false;
            setup.files.clear();
            setup.expected.clear();
        }
        inspect(runtime, io, setup, 0);
        return;
    }
    let path = setup.borrow().paths[index].clone();
    let next = runtime.clone();
    bridge::job(
        runtime,
        io,
        Job::MakeDir { path, mode: 0o700 },
        Box::new(move |io, result| match result {
            Ok(Output::Written) => create(&next, io, setup, index + 1),
            Ok(_) => setup.borrow_mut().done.take().unwrap()(
                io,
                Err(bridge::fail("install", "Unexpected filesystem result")),
            ),
            Err(error) => setup.borrow_mut().done.take().unwrap()(io, Err(error)),
        }),
    );
}
fn write(runtime: &Shared, io: &mut dyn Io, setup: SharedSetup, result: Rc<Install>, index: usize) {
    if index == result.edits.len() {
        setup.borrow_mut().done.take().unwrap()(io, Ok((*result).clone()));
        return;
    }
    let edit = &result.edits[index];
    if edit.before == edit.after {
        write(runtime, io, setup, result, index + 1);
        return;
    }
    let job = match &edit.after {
        Some(bytes) => Job::Write {
            expected: setup.borrow().expected[index],
            path: edit.path.clone(),
            bytes: bytes.clone(),
            mode: 0o600,
        },
        None if edit.before.is_some() => Job::Remove {
            expected: setup.borrow().expected[index],
            path: edit.path.clone(),
        },
        None => {
            write(runtime, io, setup, result, index + 1);
            return;
        }
    };
    let next = runtime.clone();
    bridge::job(
        runtime,
        io,
        job,
        Box::new(move |io, written| match written {
            Ok(Output::Written) => {
                setup.borrow_mut().changed = true;
                write(&next, io, setup, result, index + 1);
            }
            Ok(_) => setup.borrow_mut().done.take().unwrap()(
                io,
                Err(bridge::fail(
                    "install",
                    "Pi installation returned an unexpected filesystem result.",
                )),
            ),
            Err(mut error) => {
                if setup.borrow().changed {
                    error.code = "uncertain";
                }
                setup.borrow_mut().done.take().unwrap()(io, Err(error));
            }
        }),
    );
}
const OLD: &str = "b8ddc01d467b01e101ff76356819268dd1e5317dd01b8e3df494341f180d9761";
