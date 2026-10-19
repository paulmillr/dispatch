//! `dispatch-helper uninstall [--dry-run]` removes Dispatch from this account, on this Mac or an
//! SSH host: every Dispatch hook handler, Pi's Dispatch extension when unmodified, older helpers'
//! `.dispatch-hooks.lock` files in the agents' folders, and `~/.dispatch` itself. It refuses while
//! a helper runs here (it holds its run folder's lock and would write them again).
//! `uninstall-hooks` removes only the hook handlers.
//!
//! A handler is Dispatch's when its command runs a dispatch-helper* executable as `hook <agent>`,
//! from any path, so stale entries of older helpers go too. Other handlers and settings stay;
//! matcher groups and events left empty by the removal are dropped.
use dispatch_helper_core::json::{self, Data, Format, Json, Kind, Value};
use std::{
    io::Write,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
};

/// `everything`: `uninstall`; else `uninstall-hooks`.
pub fn run(arguments: &[std::ffi::OsString], everything: bool) -> std::io::Result<i32> {
    let dry = match arguments {
        [] => false,
        [flag] if flag == "--dry-run" => true,
        _ => {
            let name = if everything { "uninstall" } else { "uninstall-hooks" };
            eprintln!("usage: dispatch-helper {name} [--dry-run]");
            return Ok(2);
        }
    };
    let verb = if dry { "would remove" } else { "removed" };
    let home = std::env::var_os("HOME").filter(|home| !home.is_empty()).map(PathBuf::from);
    let directory = |variable: &str, default: &str| {
        let mut paths: Vec<PathBuf> = std::env::var_os(variable)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .into_iter()
            .chain(home.as_ref().map(|home| home.join(default)))
            .collect();
        paths.dedup();
        paths
    };
    let (claude, codex) = (directory("CLAUDE_CONFIG_DIR", ".claude"), directory("CODEX_HOME", ".codex"));
    // The helpers' folder, as theirs (core hooks::base): the test root, else the home.
    let root = std::env::var_os("DISPATCH_TEST_ROOT")
        .filter(|root| !root.is_empty())
        .map(PathBuf::from)
        .or_else(|| home.clone())
        .map(|home| home.join(".dispatch"));
    if everything && let Some(root) = &root {
        let running = running(root);
        if running > 0 {
            let helpers = match running {
                1 => "A Dispatch helper is".to_owned(),
                count => format!("{count} Dispatch helpers are"),
            };
            let advice = "Quit Dispatch, or close its SSH sessions to this host, then run this again.";
            if !dry {
                eprintln!("{helpers} still running here. {advice}");
                return Ok(3);
            }
            println!("note: {helpers} still running here; uninstall refuses until they stop. {advice}");
        }
    }
    // The app writes Claude settings pretty and sorted, Codex hooks.json compact.
    let files = claude
        .iter()
        .map(|directory| (directory.join("settings.json"), Format::PrettySortedUnescaped))
        .chain(codex.iter().map(|directory| (directory.join("hooks.json"), Format::Compact)));
    let mut failed = false;
    for (path, format) in files {
        match clean(&path, format, dry) {
            Ok(None) => {}
            Ok(Some(0)) => println!("{}: no Dispatch hooks", path.display()),
            Ok(Some(count)) => println!(
                "{}: {verb} {count} Dispatch hook{}",
                path.display(),
                if count == 1 { "" } else { "s" }
            ),
            Err(error) => {
                eprintln!("{}: {error}", path.display());
                failed = true;
            }
        }
    }
    if !everything {
        return Ok(if failed { 1 } else { 0 });
    }
    let hooks = failed;
    if let Some(home) = &home {
        let pi = match std::env::var("PI_CODING_AGENT_DIR").unwrap_or_default().as_str() {
            "" => home.join(".pi/agent"),
            "~" => home.clone(),
            configured => configured.strip_prefix("~/").map_or_else(|| PathBuf::from(configured), |rest| home.join(rest)),
        };
        if let Err(error) = extension(&pi, dry, verb) {
            eprintln!("{}: {error}", pi.display());
            failed = true;
        }
    }
    for lock in claude.iter().chain(&codex).map(|directory| directory.join(".dispatch-hooks.lock")) {
        if std::fs::symlink_metadata(&lock).is_ok_and(|m| m.is_file() && m.len() == 0) {
            if !dry && let Err(error) = std::fs::remove_file(&lock) {
                eprintln!("{}: {error}", lock.display());
                failed = true;
                continue;
            }
            println!("{}: {verb}", lock.display());
        }
    }
    // Hooks that could not be removed still run the stable helper copy: keep it, so they do
    // nothing quietly until the file is fixed and this runs again.
    if hooks {
        eprintln!("Kept ~/.dispatch: fix the hook settings above, then run this again.");
        return Ok(1);
    }
    if let Some(root) = root {
        match std::fs::symlink_metadata(&root) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                eprintln!("{}: {error}", root.display());
                return Ok(1);
            }
            Ok(metadata) => {
                // A link is removed itself, never its target; a folder only when it is ours.
                let removal = if dry {
                    Ok(())
                } else if metadata.is_dir() && metadata.uid() == uid() {
                    std::fs::remove_dir_all(&root)
                } else if metadata.is_symlink() {
                    std::fs::remove_file(&root)
                } else {
                    Err(std::io::Error::other("not a folder owned by you; it was kept"))
                };
                match removal {
                    Ok(()) => println!("{}: {verb}", root.display()),
                    Err(error) => {
                        eprintln!("{}: {error}", root.display());
                        return Ok(1);
                    }
                }
            }
        }
    }
    Ok(if failed { 1 } else { 0 })
}

fn uid() -> u32 {
    unsafe extern "C" {
        fn getuid() -> u32;
    }
    // SAFETY: getuid observes the executing account without pointers.
    unsafe { getuid() }
}

/// Helpers running under `root`: each holds the flock on its `run/<id>/lock` (core hooks.rs).
fn running(root: &Path) -> usize {
    use std::os::fd::AsRawFd;
    unsafe extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }
    let Ok(entries) = std::fs::read_dir(root.join("run")) else {
        return 0;
    };
    entries
        .flatten()
        .filter(|entry| {
            let Ok(file) = std::fs::File::open(entry.path().join("lock")) else {
                return false;
            };
            // SAFETY: an open descriptor; LOCK_EX | LOCK_NB, released when the file closes.
            unsafe { flock(file.as_raw_fd(), 2 | 4) != 0 }
        })
        .count()
}

/// Pi's Dispatch extension and its `dispatch/` folder (receipt, session records), only when the
/// extension is Dispatch's own: an edited one is kept, with its folder.
fn extension(pi: &Path, dry: bool, verb: &str) -> Result<(), String> {
    let script = pi.join("extensions/dispatch-chat.js");
    let folder = pi.join("dispatch");
    let read = |path: &Path| match std::fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    };
    if std::fs::symlink_metadata(&script).is_ok_and(|m| !m.is_file()) {
        return Err(format!("{} is not a plain file; it was kept", script.display()));
    }
    if let Some(bytes) = read(&script)? {
        let receipt = read(&folder.join("pi-chat-installation.json"))?;
        if !dispatch_helper_pi::install::installed(&bytes, receipt.as_deref()) {
            return Err(format!("{} was modified; it was kept", script.display()));
        }
        if !dry {
            std::fs::remove_file(&script).map_err(|error| error.to_string())?;
        }
        println!("{}: {verb}", script.display());
    }
    match std::fs::symlink_metadata(&folder) {
        Ok(metadata) if metadata.is_dir() => {
            if !dry {
                std::fs::remove_dir_all(&folder).map_err(|error| error.to_string())?;
            }
            println!("{}: {verb}", folder.display());
        }
        _ => {}
    }
    Ok(())
}

/// None = no such file; Some(count) = handlers removed (or that would be).
fn clean(path: &Path, format: Format, dry: bool) -> Result<Option<usize>, String> {
    // A symlinked settings file (dotfiles) is edited at its target and stays a link.
    let target = match std::fs::canonicalize(path) {
        Ok(target) => target,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.to_string()),
    };
    let before = std::fs::read(&target).map_err(|error| error.to_string())?;
    let Some((after, count)) = strip(&before, format)? else {
        return Ok(Some(0));
    };
    if dry {
        return Ok(Some(count));
    }
    let mode = std::fs::metadata(&target)
        .map_err(|error| error.to_string())?
        .permissions()
        .mode()
        & 0o777;
    let name = target.file_name().unwrap_or_default().to_string_lossy();
    let temporary = target.with_file_name(format!(".{name}.dispatch-{}", std::process::id()));
    let write = || -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.set_permissions(std::fs::Permissions::from_mode(mode))?;
        file.write_all(&after)?;
        file.sync_all()?;
        // An agent or Dispatch that rewrote the file meanwhile wins; nothing is replaced.
        if std::fs::read(&target)? != before {
            return Err(std::io::Error::other("the file changed meanwhile; nothing was changed, try again"));
        }
        std::fs::rename(&temporary, &target)
    };
    write().map_err(|error| {
        let _ = std::fs::remove_file(&temporary);
        error.to_string()
    })?;
    Ok(Some(count))
}

/// The settings without Dispatch's handlers, and how many went; None = nothing to remove.
pub fn strip(bytes: &[u8], format: Format) -> Result<Option<(Vec<u8>, usize)>, String> {
    let invalid = || "not valid hook settings JSON; nothing was changed".to_owned();
    let document = Json::parse(bytes).map_err(|_| invalid())?;
    let root = document.root();
    let fields = root.object().ok_or_else(invalid)?;
    let Some(hooks) = root.get("hooks") else {
        return Ok(None);
    };
    let mut count = 0;
    let mut events = Vec::new();
    for (event, groups) in hooks.object().ok_or_else(invalid)? {
        let mut kept = Vec::new();
        let mut touched = false;
        for group in groups.array().ok_or_else(invalid)? {
            let Some(handlers) = group.get("hooks").and_then(Value::array) else {
                kept.push(Data::Value(group));
                continue;
            };
            let (ours, theirs): (Vec<_>, Vec<_>) = handlers.partition(|handler| dispatch(*handler));
            if ours.is_empty() {
                kept.push(Data::Value(group));
                continue;
            }
            count += ours.len();
            touched = true;
            if !theirs.is_empty() {
                let fields = group
                    .object()
                    .ok_or_else(invalid)?
                    .map(|(key, value)| match key {
                        "hooks" => (key, Data::Array(theirs.iter().copied().map(Data::Value).collect())),
                        _ => (key, Data::Value(value)),
                    })
                    .collect();
                kept.push(Data::Object(fields));
            }
        }
        if !(touched && kept.is_empty()) {
            events.push((event, Data::Array(kept)));
        }
    }
    if count == 0 {
        return Ok(None);
    }
    let fields = fields
        .map(|(key, value)| match key {
            "hooks" => (key, Data::Object(std::mem::take(&mut events))),
            _ => (key, Data::Value(value)),
        })
        .collect();
    let mut bytes = json::write_with(&Data::Object(fields), format).map_err(|error| error.message)?;
    if bytes.last() != Some(&b'\n') {
        bytes.push(b'\n');
    }
    Ok(Some((bytes, count)))
}

/// A command handler running `'<…/dispatch-helper*>' hook <agent>` (the quoting the app and
/// harnesses write), or the same unquoted.
fn dispatch(handler: Value<'_>) -> bool {
    if handler.kind() != Kind::Object
        || handler.get("type").and_then(Value::string) != Some("command")
    {
        return false;
    }
    let Some(command) = handler.get("command").and_then(Value::string) else {
        return false;
    };
    let Some((executable, rest)) = word(command.trim_start()) else {
        return false;
    };
    let name = Path::new(&executable)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    let mut arguments = rest.split_whitespace();
    name.starts_with("dispatch-helper")
        && arguments.next() == Some("hook")
        && arguments
            .next()
            .is_some_and(|agent| agent.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
        && arguments.next().is_none()
}

/// The first shell word, with single quotes and backslash escapes undone, and the rest.
fn word(text: &str) -> Option<(String, &str)> {
    let mut word = String::new();
    let mut characters = text.char_indices();
    while let Some((index, character)) = characters.next() {
        match character {
            '\'' => loop {
                match characters.next()? {
                    (_, '\'') => break,
                    (_, character) => word.push(character),
                }
            },
            '\\' => word.push(characters.next()?.1),
            '"' | '$' | '`' | ';' | '|' | '&' | '<' | '>' => return None,
            character if character.is_whitespace() => return Some((word, &text[index..])),
            character => word.push(character),
        }
    }
    Some((word, ""))
}
