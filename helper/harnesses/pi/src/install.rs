//! The existing Pi marker/digest policy preserves files edited by the user.
use crate::bridge::{self, Shared};
use crate::digest;
use crate::records::text;
use dispatch_helper_core::{
    api::*,
    json::{self, Data, Json, Value},
};
use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
    rc::Rc,
};

const SCRIPT: &[u8] = include_bytes!("../resources/bridge.js");
const MARKER: &[u8] = b"// Dispatch's opt-in bridge for an existing interactive Pi session.\n";
const OWNER: &str = "Dispatch Pi chat extension";
struct Setup {
    uid: u64,
    paths: Vec<PathBuf>,
    /// The extension's path as Pi names it (through any linked folder): what the receipt records, so following a
    /// link, or a folder replaced by one, keeps the receipt's.
    named: PathBuf,
    /// Pi's agent folder as Pi names it, before any link is followed: the folders `secure` checks start from it.
    origin: PathBuf,
    /// Every folder on the way passed `secure` (an install checks once, before it creates or writes anything).
    secured: bool,
    missing: bool,
    files: Vec<Option<Vec<u8>>>,
    /// The extension's and the receipt's mode, device and inode as read (None: absent), for `repair`.
    modes: Vec<Option<(u64, u64, u64)>>,
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
                    .and_then(Data::unsigned)
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
                fields.push(("executable", Data::from(process.executable.as_path())));
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
                    let home = match bridge::home(&next, &root.root()) {
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
                    let named = paths[3].clone();
                    let setup = Rc::new(std::cell::RefCell::new(Setup {
                        uid,
                        paths,
                        named,
                        origin: home,
                        secured: false,
                        missing: false,
                        files: Vec::new(),
                        modes: Vec::new(),
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
/// A linked Pi folder Dispatch won't follow; `why` finishes the sentence that starts with the link.
fn linked(link: &std::path::Path, why: String) -> Error {
    bridge::fail(
        "install",
        format!("{} {why} Nothing was changed.", link.display()),
    )
}
/// A path as the shell takes it, for the command a message suggests.
fn quoted(path: &std::path::Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
}
/// The permission bits as `ls -l` counts them.
fn bits(mode: u64) -> String {
    format!("{:03o}", mode & 0o777)
}
/// Why a folder on the way to Pi's extension would let another account change what Pi loads, or None. Pi loads every
/// file in its `extensions` folder, so each folder from `/` down to it (and to the receipt's) must be this account's
/// or root's and not writable by group or others, as OpenSSH's StrictModes asks of `~/.ssh`. A root-owned sticky
/// folder (`/tmp`) passes: there others cannot rename or remove what is not theirs. A link on the way must be this
/// account's or root's; where it leads is checked as a folder of its own.
pub(crate) fn folder(path: &Path, uid: u64, kind: &str, owner: u64, mode: u64) -> Option<String> {
    if owner != uid && owner != 0 {
        return Some("belongs to another account, which could change what Pi loads.".into());
    }
    match kind {
        "symlink" => None,
        "directory" if mode & 0o022 == 0 || (owner == 0 && mode & 0o1000 != 0) => None,
        "directory" => Some(format!(
            "is writable by its group or others (mode {}), so other accounts could change what Pi loads. Run chmod \
             go-w {} and install again.",
            bits(mode),
            quoted(path)
        )),
        _ => Some("is not a folder.".into()),
    }
}
fn refuse(io: &mut dyn Io, setup: &SharedSetup, error: Error) {
    let done = setup.borrow_mut().done.take().unwrap();
    done(io, Err(error));
}
/// A file's revision as the checked write pins it, from native metadata.
fn guard(value: &Data<'_>) -> Option<Guard> {
    Some(Guard::from(Metadata {
        kind: FileKind::File,
        size: value.get("size")?.unsigned()?,
        device: value.get("device")?.unsigned()?,
        inode: value.get("inode")?.unsigned()?,
        modified_ns: value.get("mtime_ns")?.signed()?.into(),
        changed_ns: value.get("ctime_ns")?.signed()?.into(),
    }))
}
/// Before an install creates or writes anything: every folder on the way to the extension's and the receipt's
/// folders, as Pi names them (so a link's own folder counts) and as they resolve (so the folders behind a link
/// count), passes `folder`. Missing ones are skipped: Dispatch makes them, 0700.
fn secure(runtime: &Shared, io: &mut dyn Io, setup: SharedSetup) {
    let targets: BTreeSet<PathBuf> = {
        let state = setup.borrow();
        [state.origin.join("extensions"), state.origin.join("dispatch"), state.paths[1].clone(), state.paths[2].clone()]
            .into_iter()
            .collect()
    };
    let folders = targets.iter().flat_map(|path| path.ancestors().map(Path::to_path_buf)).collect();
    resolve(runtime, io, setup, targets.into_iter().collect(), folders);
}
/// Adds the folders of each pending path's deepest existing part, links resolved, then checks them all.
fn resolve(runtime: &Shared, io: &mut dyn Io, setup: SharedSetup, mut pending: Vec<PathBuf>, mut folders: BTreeSet<PathBuf>) {
    let Some(path) = pending.pop() else {
        return check(runtime, io, setup, folders.into_iter().collect(), 0);
    };
    let next = runtime.clone();
    let asked = path.clone();
    bridge::native(
        runtime,
        io,
        "file.realpath",
        Data::Object(vec![("path", Data::from(asked.as_path()))]),
        Box::new(move |io, result| {
            match result.ok().and_then(|value| value.root().get("path").and_then(Data::path).map(PathBuf::from)) {
                Some(real) => folders.extend(real.ancestors().map(Path::to_path_buf)),
                None => pending.extend(path.parent().filter(|parent| !parent.as_os_str().is_empty()).map(Path::to_path_buf)),
            }
            resolve(&next, io, setup, pending, folders);
        }),
    );
}
/// `folders` in order (a folder before those inside it), each by `folder`; the first that fails ends the install.
fn check(runtime: &Shared, io: &mut dyn Io, setup: SharedSetup, folders: Vec<PathBuf>, index: usize) {
    let Some(path) = folders.get(index).cloned() else {
        setup.borrow_mut().secured = true;
        return apply(runtime, io, setup);
    };
    let next = runtime.clone();
    let asked = path.clone();
    bridge::native(
        runtime,
        io,
        "file.lstat",
        Data::Object(vec![("path", Data::from(asked.as_path()))]),
        Box::new(move |io, result| {
            let uid = setup.borrow().uid;
            let why = match &result {
                Err(error) if error.code == "not_found" => None,
                Err(_) => Some("cannot be checked, so Dispatch cannot tell whether others could change what Pi loads.".into()),
                Ok(value) => {
                    let value = value.root();
                    let number = |name| value.get(name).and_then(Data::unsigned).unwrap_or(u64::MAX);
                    folder(&path, uid, value.get("kind").and_then(Data::string).unwrap_or(""), number("uid"), number("mode"))
                }
            };
            match why {
                Some(why) => refuse(io, &setup, bridge::fail("install", format!("{} {why} Nothing was changed.", path.display()))),
                None => check(&next, io, setup, folders, index + 1),
            }
        }),
    );
}
/// The extension and its receipt, verified as Dispatch's but writable by group or others, get a safe mode back before
/// anything is written (a checked write keeps a file's mode): group and others lose write and everyone execute, reads
/// stay (0664 becomes 0644; `file.mode`, so no umask applies). A file being removed is left as it is.
fn repair(runtime: &Shared, io: &mut dyn Io, setup: SharedSetup, result: Rc<Install>, index: usize) {
    if index == 2 {
        return write(runtime, io, setup, result, 0);
    }
    let loose = setup.borrow().modes[index].filter(|(mode, ..)| mode & 0o022 != 0);
    let (Some((mode, device, inode)), Some(_)) = (loose, &result.edits[index].after) else {
        return repair(runtime, io, setup, result, index + 1);
    };
    let path = result.edits[index].path.clone();
    let asked = path.clone();
    let next = runtime.clone();
    bridge::native(
        runtime,
        io,
        "file.mode",
        Data::Object(vec![
            ("path", Data::from(asked.as_path())),
            ("mode", Data::Unsigned(mode & 0o644)),
            ("device", Data::Unsigned(device)),
            ("inode", Data::Unsigned(inode)),
        ]),
        Box::new(move |io, outcome| match outcome.ok().and_then(|value| guard(&value.root())) {
            // The write that may follow pins the file as it is now (its ctime moved).
            Some(revision) => {
                {
                    let mut state = setup.borrow_mut();
                    state.expected[index] = Expected::Same(revision);
                    state.changed = true;
                }
                repair(&next, io, setup, result, index + 1)
            }
            None => {
                let error = bridge::fail("install", format!("Dispatch could not take group and others' write access from {}.", path.display()));
                refuse(io, &setup, error)
            }
        }),
    );
}
/// A Pi folder (`index` < 3: the agent folder, `extensions`, `dispatch`) that is a symlink, as dotfiles make them,
/// is followed when the link is this account's and the folder it resolves to is this account's; every later step
/// (the checks, the writes, the receipt's path) uses the resolved folder. Anything else is refused and left as it is.
/// Whether others could change the folders on either side is `secure`'s, before an install writes.
fn follow(runtime: &Shared, io: &mut dyn Io, setup: SharedSetup, index: usize, link: PathBuf) {
    let next = runtime.clone();
    let asked = link.clone();
    bridge::native(
        runtime,
        io,
        "file.realpath",
        Data::Object(vec![("path", Data::from(asked.as_path()))]),
        Box::new(move |io, result| {
            let resolved = result.ok().and_then(|value| value.root().get("path").and_then(Data::path).map(PathBuf::from));
            let Some(resolved) = resolved else {
                return refuse(io, &setup, linked(&link, "links to a folder that doesn't exist.".into()));
            };
            let again = next.clone();
            let target = resolved.clone();
            bridge::native(
                &next,
                io,
                "file.lstat",
                Data::Object(vec![("path", Data::from(target.as_path()))]),
                Box::new(move |io, result| {
                    let uid = setup.borrow().uid;
                    let target = resolved.display();
                    let why = match &result {
                        Err(_) => Some(format!("links to {target}, which Dispatch cannot read.")),
                        Ok(value) => {
                            let value = value.root();
                            if value.get("kind").and_then(Data::string) != Some("directory") {
                                Some(format!("links to {target}, which is not a folder."))
                            } else if value.get("uid").and_then(Data::unsigned) != Some(uid) {
                                Some(format!("links to {target}, which belongs to another account."))
                            } else {
                                None
                            }
                        }
                    };
                    if let Some(why) = why {
                        return refuse(io, &setup, linked(&link, why));
                    }
                    {
                        let mut state = setup.borrow_mut();
                        match index {
                            0 => {
                                state.paths = vec![
                                    resolved.clone(),
                                    resolved.join("extensions"),
                                    resolved.join("dispatch"),
                                    resolved.join("extensions/dispatch-chat.js"),
                                    resolved.join("dispatch/pi-chat-installation.json"),
                                ];
                            }
                            1 => {
                                state.paths[3] = resolved.join("dispatch-chat.js");
                                state.paths[1] = resolved;
                            }
                            _ => {
                                state.paths[4] = resolved.join("pi-chat-installation.json");
                                state.paths[2] = resolved;
                            }
                        }
                    }
                    inspect(&again, io, setup, index + 1);
                }),
            );
        }),
    );
}
fn inspect(runtime: &Shared, io: &mut dyn Io, setup: SharedSetup, index: usize) {
    if index == 5 {
        let path = {
            let state = setup.borrow();
            state.files[1]
                .as_deref()
                .and_then(|bytes| Json::parse(bytes).ok())
                .map(|value| text(value.root(), "path"))
                .filter(|path| !path.is_empty() && *path != state.paths[3].to_string_lossy()
                    && *path != state.named.to_string_lossy())
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
    let path = setup.borrow().paths[index].clone();
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
            vec![("path", Data::from(path.as_path()))]
        } else {
            vec![
                ("path", Data::from(path.as_path())),
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
                        state.modes.push(None);
                        state.expected.push(Expected::Absent);
                    }
                }
                Ok(v) => {
                    let v = v.root();
                    if index < 3 && v.get("kind").and_then(Data::string) == Some("symlink") {
                        let link = state.paths[index].clone();
                        let owned = v.get("uid").and_then(Data::unsigned) == Some(state.uid);
                        drop(state);
                        if owned {
                            follow(&next, io, setup, index, link);
                        } else {
                            refuse(io, &setup, linked(&link, "is a link that belongs to another account.".into()));
                        }
                        return;
                    }
                    let metadata = if index < 3 { Some(&v) } else { v.get("before") };
                    // The extension and its receipt may be writable by others: once they verify as Dispatch's,
                    // `repair` takes that away (content that does not verify is preserved, as any other).
                    let valid = metadata.is_some_and(|v| {
                        v.get("uid").and_then(Data::unsigned) == Some(state.uid)
                            && (index >= 3 || v.get("kind").and_then(Data::string) == Some("directory"))
                            && (index < 3 || v.get("links").and_then(Data::unsigned) == Some(1))
                    });
                    if !valid {
                        let error = preserved(&state.paths[index]);
                        let done = state.done.take().unwrap();
                        drop(state);
                        done(io, Err(error));
                        return;
                    }
                    if index >= 3 {
                        let before = v.get("before").and_then(|v| guard(&v));
                        let after = v.get("after").and_then(|v| guard(&v));
                        let number = |name| v.get("before").and_then(|v| v.get(name)).and_then(Data::unsigned);
                        state.modes.push(Some((number("mode").unwrap_or(0), number("device").unwrap_or(0), number("inode").unwrap_or(0))));
                        if before.is_none() || before != after {
                            let error = preserved(&state.paths[index]);
                            let done = state.done.take().unwrap();
                            drop(state);
                            done(io, Err(error));
                            return;
                        }
                        state.expected.push(Expected::Same(before.unwrap()));
                        state.files.push(Some(v.get("data").and_then(Data::bytes).unwrap_or_default().to_vec()));
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
                    || (text(value, "path") != script.to_string_lossy()
                        && text(value, "path") != state.named.to_string_lossy()
                        && !state.alias)
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
                ("path", Data::String(&state.named.to_string_lossy())),
                ("sha256", Data::String(&hash)),
            ]))?)
        };
        // An audit's `restart` says an install would change the files: new bytes (Pi then needs /reload), or a mode
        // `repair` fixes. The app reinstalls such an extension at launch (ChatCoordinator.loadLaunches).
        let loose = !disabled && state.modes.iter().flatten().any(|(mode, ..)| mode & 0o022 != 0);
        Ok(Install {
            trust: None,
            installed: state.files[0].is_some(),
            optional: true,
            reload: Some("/reload".into()),
            restart: state.files[0] != after || (state.enabled.is_none() && loose),
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
    let secured = state.secured;
    drop(state);
    let result = match result {
        Ok(result) => result,
        Err(e) => {
            setup.borrow_mut().done.take().unwrap()(io, Err(e));
            return;
        }
    };
    match enabled {
        None => setup.borrow_mut().done.take().unwrap()(io, Ok(result)),
        // Installing: the folders first (`secure`, which comes back here), then any missing ones made, the files'
        // modes repaired, and the files written. Removing needs neither check nor repair.
        Some(true) if !secured => secure(runtime, io, setup),
        Some(true) if missing => create(runtime, io, setup, 0),
        Some(true) => repair(runtime, io, setup, Rc::new(result), 0),
        Some(false) => write(runtime, io, setup, Rc::new(result), 0),
    }
}
fn create(runtime: &Shared, io: &mut dyn Io, setup: SharedSetup, index: usize) {
    if index == 3 {
        {
            let mut setup = setup.borrow_mut();
            setup.missing = false;
            setup.files.clear();
            setup.modes.clear();
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
            parent: None,
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

/// `script` is Dispatch's extension as installed (its receipt's hash, or without a receipt the
/// bundled or old bundled build), not a file the user edited: `dispatch-helper uninstall` removes
/// only such an extension.
pub fn installed(script: &[u8], receipt: Option<&[u8]>) -> bool {
    if !script.starts_with(MARKER) {
        return false;
    }
    match receipt.map(Json::parse) {
        None => script == SCRIPT || digest(script) == OLD,
        Some(Ok(receipt)) => {
            let root = receipt.root();
            text(root, "owner") == OWNER && digest(script) == text(root, "sha256")
        }
        Some(Err(_)) => false,
    }
}
#[cfg(test)]
#[path = "install.test.rs"]
mod tests;
