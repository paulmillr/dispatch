use super::*;
use std::path::{Component, Path};

pub(crate) enum Invocation {
    Local(Option<String>),
    Remote,
    Passthrough,
}

/// c1654cc HerdrLaunch.swift:225; explicit command overrides are applied later.
pub(super) fn clean(environment: &mut BTreeMap<String, String>) {
    environment.retain(|key, _| !key.starts_with("DISPATCH_") && !key.starts_with("GHOSTTY_"));
}

/// The app's launch capability belongs to an owned pane, never its persistent server.
/// ShellCommandWrapper needs both executable variables; NativeSSHEnvironment needs the
/// startup/user directories, and the app's launcher authenticates with the mailbox fields.
/// Preserve an explicit isolation root so retained agents can discover a replacement owner.
pub(super) fn capability(environment: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    environment.iter().filter(|(key, _)| matches!(key.as_str(),
        "DISPATCH_HERDR_DIRECTORY" | "DISPATCH_HERDR_TAB" | "DISPATCH_HERDR_TOKEN"
        | "DISPATCH_NATIVE_STARTUP" | "DISPATCH_NATIVE_ZDOTDIR"
        | "DISPATCH_EXECUTABLE" | "DISPATCH_HELPER_EXECUTABLE"
        | "DISPATCH_TEST_ROOT"))
        .map(|(key, value)| (key.clone(), value.clone())).collect()
}

/// c51466a server/controller environment policies over the registered owner.
pub(super) fn environment(
    environment: &BTreeMap<String, String>,
    server: bool,
) -> BTreeMap<String, String> {
    environment
        .iter()
        .filter(|(name, _)| {
            !name.starts_with("DISPATCH_")
                && !name.starts_with("GHOSTTY_")
                && if server {
                    !name.starts_with("HERDR_")
                } else {
                    !["HERDR_ENV", "HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH"]
                        .contains(&name.as_str())
                }
        })
        .map(|(name, value)| (name.clone(), value.clone()))
        .collect()
}

pub(super) fn matches(process: &Process) -> bool {
    let executable = process
        .executable
        .file_name()
        .and_then(|name| name.to_str());
    let argument = process
        .arguments
        .first()
        .and_then(|name| Path::new(name).file_name());
    executable.is_some_and(|name| name == "herdr" || name.starts_with("herdr-"))
        || argument == Some(std::ffi::OsStr::new("herdr"))
}

/// c1654cc HerdrLaunch.swift:188-203; management/remote invocations stay native.
pub(crate) fn invocation(args: &[String]) -> Invocation {
    if args.len() == 3 && args[0] == "session" && args[1] == "attach" {
        return if ["help", "--help", "-h"].contains(&args[2].as_str()) {
            Invocation::Passthrough
        } else {
            Invocation::Local(Some(args[2].clone()))
        };
    }
    let mut session = None;
    let mut index = 0;
    let mut remaining = Vec::new();
    for _ in 0..args.len() {
        let Some(arg) = args.get(index) else {
            break;
        };
        if arg == "--" {
            remaining.extend(args[index..].iter().map(String::as_str));
            break;
        }
        if arg == "--session" && index + 1 < args.len() {
            session = Some(args[index + 1].clone());
            index += 2;
            continue;
        }
        if let Some(name) = arg.strip_prefix("--session=") {
            session = Some(name.into());
        } else {
            remaining.push(arg.as_str());
        }
        index += 1;
    }
    if remaining
        .iter()
        .any(|s| *s == "--remote" || s.starts_with("--remote="))
    {
        Invocation::Remote
    } else if remaining.is_empty() || remaining.first() == Some(&"client") {
        Invocation::Local(session)
    } else {
        Invocation::Passthrough
    }
}

pub(super) fn arguments(process: &Process, typed: bool) -> Result<&[String], Error> {
    if !typed {
        return Ok(process.arguments.get(1..).unwrap_or_default());
    }
    match process.arguments.as_slice() {
        [_, command, key, args @ ..] if command == "launch" && key == "herdr" => Ok(args),
        [program, args @ ..] if Path::new(program).file_name() == Some(std::ffi::OsStr::new("herdr")) => Ok(args),
        _ => Err(error("The herdr launcher changed.")),
    }
}

impl Config {
    /// Decode a prospective local client endpoint from private System observations.
    /// The caller still verifies foreground ownership and the server peer/snapshot,
    /// and resolves socket aliases through System before registering the endpoint.
    pub fn client(
        process: &Process,
        facts: &Json,
        environment: &Json,
        account: (u32, &Path),
    ) -> Result<Option<Self>, Error> {
        Self::context(process, facts, environment, account, false)
    }

    pub(super) fn context(process: &Process, facts: &Json, environment: &Json, account: (u32, &Path), typed: bool) -> Result<Option<Self>, Error> {
        let observed = process::read(facts.root())?;
        if !process::same(process, &observed)
            || process.tty == 0
            || process.tty != observed.tty
            || process.group != observed.group
            || process.foreground != observed.foreground
            || process.arguments != observed.arguments
            || facts.root().get("uid").and_then(Value::unsigned) != Some(account.0.into())
        {
            return Err(error("The herdr client changed."));
        }
        if !typed && !matches(process) {
            return Ok(None);
        }
        let mut environment = environment
            .root()
            .object()
            .ok_or_else(|| error("Herdr launch context is missing."))?
            .map(|(key, value)| {
                value
                    .string()
                    .map(|value| (key.to_owned(), value.to_owned()))
                    .ok_or_else(|| error("Herdr launch context is missing."))
            })
            .collect::<Result<BTreeMap<_, _>, _>>()?;
        if environment
            .get("HERDR_ENV")
            .is_some_and(|value| value == "1")
        {
            return Ok(None);
        }
        let args = arguments(process, typed)?;
        let Invocation::Local(explicit) = invocation(args) else {
            return Ok(None);
        };
        let session = explicit
            .as_ref()
            .or_else(|| environment.get("HERDR_SESSION"))
            .cloned()
            .unwrap_or_else(|| "default".into());
        if session.is_empty()
            || session == "."
            || session == ".."
            || session.len() > 64
            || !session
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err(error("Invalid herdr session name."));
        }
        let directory = PathBuf::from(text(facts.root(), "cwd")?);
        if !directory.is_absolute() {
            return Err(error("Herdr launch context is missing."));
        }
        let home = environment
            .get("HOME")
            .map(String::as_str)
            .or_else(|| account.1.to_str())
            .ok_or_else(|| error("Herdr launch context is missing."))?;
        let base = environment
            .get("XDG_CONFIG_HOME")
            .filter(|path| Path::new(path).is_absolute())
            .map(PathBuf::from)
            .unwrap_or_else(|| Path::new(home).join(".config"))
            .join("herdr");
        let default = if session == "default" {
            base
        } else {
            base.join("sessions").join(&session)
        };
        let socket = if explicit.is_none() {
            environment.get("HERDR_SOCKET_PATH").map(PathBuf::from)
        } else {
            None
        }
        .unwrap_or_else(|| default.join("herdr.sock"));
        let socket = if socket.is_absolute() {
            socket
        } else {
            directory.join(socket)
        };
        let mut normalized = PathBuf::new();
        for component in socket.components() {
            match component {
                Component::ParentDir => {
                    normalized.pop();
                }
                Component::CurDir => {}
                _ => normalized.push(component.as_os_str()),
            }
        }
        let pane = typed.then(|| capability(&environment));
        clean(&mut environment);
        environment.extend(pane.into_iter().flatten());
        environment.insert(
            "HERDR_SOCKET_PATH".into(),
            normalized.to_string_lossy().into_owned(),
        );
        environment.insert("HERDR_SESSION".into(), session.clone());
        Ok(Some(Self {
            executable: process.executable.clone(),
            socket: normalized,
            session,
            directory,
            environment,
            uid: account.0,
        }))
    }
}

impl Herdr {
    pub(super) fn environment(
        &self,
        io: &mut dyn Io,
        mut environment: BTreeMap<String, String>,
    ) -> Result<BTreeMap<String, String>, Error> {
        environment.extend(self.integration.clone());
        // The parent login shell restores the user directory after loading private wrappers.
        // New panes enter the wrappers again; DISPATCH_NATIVE_ZDOTDIR keeps the user path.
        if let Some(startup) = self.integration.get("DISPATCH_NATIVE_STARTUP") {
            environment.insert("ZDOTDIR".into(), format!("{startup}/zsh"));
        }
        let (_, route) = io.route().map_err(|reason| error(reason.to_string()))?;
        environment.insert(
            "DISPATCH_HELPER_ENDPOINT".into(),
            route.to_string_lossy().into_owned(),
        );
        Ok(environment)
    }
}
