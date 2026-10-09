//! `dispatch-helper uninstall-hooks [--dry-run]`: removes every Dispatch hook handler from the
//! account's Claude settings and Codex hooks.json, on this Mac or an SSH host. A handler is
//! Dispatch's when its command runs a dispatch-helper* executable as `hook <agent>`, from any
//! path, so stale entries of older helpers go too. Other handlers and settings stay; matcher
//! groups and events left empty by the removal are dropped.
use dispatch_helper_core::json::{self, Data, Format, Json, Kind, Value};
use std::{
    io::Write,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};

pub fn run(arguments: &[std::ffi::OsString]) -> std::io::Result<i32> {
    let dry = match arguments {
        [] => false,
        [flag] if flag == "--dry-run" => true,
        _ => {
            eprintln!("usage: dispatch-helper uninstall-hooks [--dry-run]");
            return Ok(2);
        }
    };
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
    // The app writes Claude settings pretty and sorted, Codex hooks.json compact.
    let files = directory("CLAUDE_CONFIG_DIR", ".claude")
        .into_iter()
        .map(|directory| (directory.join("settings.json"), Format::PrettySortedUnescaped))
        .chain(
            directory("CODEX_HOME", ".codex")
                .into_iter()
                .map(|directory| (directory.join("hooks.json"), Format::Compact)),
        );
    let mut failed = false;
    for (path, format) in files {
        match clean(&path, format, dry) {
            Ok(None) => {}
            Ok(Some(0)) => println!("{}: no Dispatch hooks", path.display()),
            Ok(Some(count)) => println!(
                "{}: {} {count} Dispatch hook{}",
                path.display(),
                if dry { "would remove" } else { "removed" },
                if count == 1 { "" } else { "s" }
            ),
            Err(error) => {
                eprintln!("{}: {error}", path.display());
                failed = true;
            }
        }
    }
    Ok(if failed { 1 } else { 0 })
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
