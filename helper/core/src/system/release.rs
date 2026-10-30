//! `login.release`: what the Mac's `SSHBootstrap.publish` script does on the host, run by the greeting probe it already
//! verified, so releasing the waiting login costs no exec channel of its own. It names the helper the login is to run
//! in `~/.dispatch/sessions/<session>/ready`, where the login script (`SSHLauncherCommand.remoteCommand`) waits for it;
//! the login checks that helper itself (its folders, owner, mode and SHA-256) before it runs it.
//!
//! The same checks as the script, through descriptors: `$HOME` (followed, as `cd -P` does) owned by the account and
//! writable by nobody else; `.dispatch`, `sessions` and the session's folder each made if missing, then opened without
//! following a link and required to be a folder of the account with mode 0700 (whoever made it: a login, another
//! release); no `ready` there yet; the path written to a new `ready.<pid>` (O_EXCL, 0600), then renamed to `ready`
//! without replacing one that appeared meanwhile. Each refusal is the script's own reason, which the app shows as the
//! login falls back. Runs on a worker, live only: a replay answers the recorded result.
use super::native;
use crate::json::Data;
use std::{ffi::OsStr, fs::File, io, io::Write, os::unix::fs::MetadataExt, path::Path};

/// A session id as the app makes them (`SSHBootstrap.validSessionID`): 24 lowercase hex digits.
pub(crate) fn session(id: &str) -> bool {
    id.len() == 24 && id.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// A helper path the login accepts: `.dispatch/bin/versions/<sha256>/dispatch-helper` under `$HOME`, or
/// `dispatch/bin/versions/<sha256>/dispatch-helper` under `$XDG_RUNTIME_DIR`.
pub(crate) fn published(path: &str) -> bool {
    let Some(rest) = path.strip_prefix(".dispatch/bin/versions/").or_else(|| path.strip_prefix("dispatch/bin/versions/"))
    else {
        return false;
    };
    let Some(digest) = rest.strip_suffix("/dispatch-helper") else { return false };
    digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// The native job: `{session, path}` in, `{}` once released or `{reason}` when refused.
pub(super) fn job(input: &[u8]) -> io::Result<Vec<u8>> {
    let value = crate::wire::body::decode_plain(input).map_err(|_| io::ErrorKind::InvalidInput)?;
    let text = |key| value.get(key).and_then(Data::string).ok_or(io::ErrorKind::InvalidInput);
    let (id, path) = (text("session")?, text("path")?);
    if !session(id) || !published(path) {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let home = std::env::var_os("HOME");
    let reason = release(home.as_deref().map(Path::new), unsafe { native::getuid() }, id, path, std::process::id()).err();
    let fields = reason.as_deref().map(|reason| vec![("reason", Data::String(reason))]).unwrap_or_default();
    crate::wire::body::encode_plain(&Data::Object(fields))
        .map_err(|error| io::Error::other(error.message))
}

/// Releases `session` under `home` for the account `owner`, naming `path`; `pid` names the pending file. Err: the
/// script's reason, word for word.
pub(crate) fn release(home: Option<&Path>, owner: u32, session: &str, path: &str, pid: u32) -> Result<(), String> {
    let home = home.filter(|home| home.is_absolute()).ok_or("no home folder")?;
    let directory = native::directory(home, crate::api::Expected::Any).map_err(|_| "no home folder")?;
    let metadata = directory.metadata().map_err(|_| "home folder writable by others")?;
    if metadata.uid() != owner || metadata.mode() & 0o022 != 0 {
        return Err("home folder writable by others".into());
    }
    let mut folder = directory;
    for name in [".dispatch", "sessions", session] {
        folder = private(&folder, name, owner)?;
    }
    if native::exists(&folder, OsStr::new("ready")).unwrap_or(false) {
        return Err("session already released".into());
    }
    let pending = format!("ready.{pid}");
    let pending = OsStr::new(&pending);
    let mut file = native::open(&folder, pending, Some(0o600)).map_err(|_| "cannot write the ready file")?;
    let written = (|| {
        use std::os::unix::fs::PermissionsExt;
        // What umask 077 gives the script's file, whatever this process's umask is.
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        file.write_all(path.as_bytes())?;
        file.write_all(b"\n")
    })();
    drop(file);
    if written.is_err() {
        let _ = native::remove(&folder, pending);
        return Err("cannot write the ready file".into());
    }
    // Never over a `ready` that appeared since the check (the script's `mv -f` would): that is another release.
    native::publish(&folder, pending, OsStr::new("ready"), false).map_err(|error| {
        let _ = native::remove(&folder, pending);
        if error.kind() == io::ErrorKind::AlreadyExists { "session already released" } else { "cannot release the session" }
            .to_owned()
    })
}

/// The script's `enter_private`: `name` made if missing (an existing one is not a failure: logins and releases make the
/// same folders at the same moment), then opened without following a link and checked: a folder of `owner` with mode
/// 0700 (`stat`'s permission digits: the special bits count on Linux, as `%a` prints them, and not on macOS, whose
/// `%Lp` leaves them out). Refused: "unsafe folder <name>" when something else is there, else "cannot create folder
/// <name>".
fn private(parent: &File, name: &str, owner: u32) -> Result<File, String> {
    let child = OsStr::new(name);
    let _ = native::mkdir(parent, child, 0o700);
    let mask = if cfg!(target_os = "macos") { 0o777 } else { 0o7777 };
    let unsafe_folder = || format!("unsafe folder {name}");
    match native::folder(parent, child) {
        Ok(folder) => match folder.metadata() {
            Ok(metadata) if metadata.is_dir() && metadata.uid() == owner && metadata.mode() & mask == 0o700 => Ok(folder),
            _ => Err(unsafe_folder()),
        },
        Err(_) if native::exists(parent, child).unwrap_or(true) => Err(unsafe_folder()),
        Err(_) => Err(format!("cannot create folder {name}")),
    }
}

#[cfg(test)]
#[path = "release.test.rs"]
mod tests;
