use dispatch_helper_core::{DispatchHelper, api::Grid, system::System};
use std::{collections::BTreeMap, path::PathBuf};

/// Programs typed in a helper shell run through `launch <key>`, and the helper invoked under
/// such a name is that launch (old ssh-helper main.rs:47-51 argv0 aliases, startup.rs AGENTS;
/// ShellCommandWrapper.swift:5). Claude follows once its launch takes arguments.
const TYPED: [(&str, &str); 3] = [("codex", "codex"), ("pi", "pi"), ("herdr", "herdr")];

fn main() -> std::io::Result<()> {
    if let Some(mut command) = System::restore()? {
        use std::os::unix::process::CommandExt;
        return Err(command.exec());
    }
    let name = std::env::args_os().next().map(PathBuf::from);
    let alias = name
        .as_ref()
        .and_then(|path| path.file_name()?.to_str())
        .and_then(|name| TYPED.iter().find(|(program, _)| *program == name));
    let mut argv: Vec<std::ffi::OsString> = alias
        .map(|(_, key)| vec!["launch".into(), (*key).into()])
        .unwrap_or_default()
        .into_iter()
        .chain(std::env::args_os().skip(1))
        .collect();
    // Private exec supervision metadata is consumed by run_login, never shell arguments.
    if argv.first().is_some_and(|arg| arg == "login")
        && argv.len() >= 3
        && argv[argv.len() - 2] == "--login-worker"
    {
        argv.truncate(argv.len() - 2);
    }
    let first = |value: &str| argv.first().is_some_and(|arg| arg == value);
    if first("--stats-fixture") {
        let directory = argv
            .get(1)
            .cloned()
            .ok_or_else(|| std::io::Error::other("missing stats fixture directory"))?;
        let local = argv.get(2).is_some_and(|arg| arg == "--local");
        let mut helper = DispatchHelper::new();
        helper.add_plugin(dispatch_helper_stats::Stats::fixture(
            directory.into(),
            local,
        ));
        return helper.run_stdio();
    }
    if let Some(code) = dispatch_helper_core::system::isolated() {
        std::process::exit(code);
    }
    if first("renderer") {
        return dispatch_helper_core::system::renderer::run();
    }
    if first("exit-status") {
        let session = argv
            .get(1)
            .and_then(|arg| arg.to_str())
            .filter(|_| argv.len() == 2)
            .ok_or_else(|| std::io::Error::other("missing login session"))?;
        let socket = dispatch_helper_core::system::login::endpoint(session)?;
        println!("{}", dispatch_helper_core::system::login::status(&socket)?);
        return Ok(());
    }
    let mut args = argv.iter().cloned();
    let mode = if first("login") || first("connect") {
        args.next()
    } else {
        None
    };
    let mut session = None;
    let mut script = None;
    let mut permissions = None;
    if mode.as_deref() == Some(std::ffi::OsStr::new("login")) {
        let profile = args
            .next()
            .ok_or_else(|| std::io::Error::other("missing login profile"))?;
        if profile != "full" && profile != "statistics" {
            return Err(std::io::Error::other("invalid login profile"));
        }
        permissions = Some(if profile == "statistics" {
            std::collections::BTreeSet::from(["stats.sample".to_owned()])
        } else {
            [
                "stats.sample",
                "agent.inspect",
                "agent.submit",
                "backend.register",
                "tmux.pane",
                "herdr.start",
                "herdr.rpc",
                "herdr.terminal",
                "file.text",
            ]
            .map(str::to_owned)
            .into_iter()
            .collect()
        });
    }
    let mut socket = None;
    let mut options = BTreeMap::new();
    let mut remote = false;
    // Malformed hook invocations also fail open below; None = nothing to send.
    let hook = first("hook").then(|| {
        args.next();
        let key = args.next().and_then(|arg| arg.into_string().ok());
        let endpoint = args
            .next()
            .or_else(|| std::env::var_os("DISPATCH_HELPER_ENDPOINT"))
            .map(PathBuf::from);
        key.filter(|_| args.next().is_none())
            .map(|key| (key, endpoint))
    });
    // `launch <key> [args...]`: every remaining argument belongs to the typed command.
    let launch = if first("launch") {
        args.next();
        let key = args
            .next()
            .and_then(|arg| arg.into_string().ok())
            .ok_or_else(|| std::io::Error::other("missing harness key"))?;
        let arguments = args
            .by_ref()
            .map(|arg| arg.into_string())
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| std::io::Error::other("non-UTF-8 launch argument"))?;
        Some((key, arguments))
    } else {
        None
    };
    loop {
        let Some(arg) = args.next() else {
            break;
        };
        if arg == "--socket" {
            socket = args.next().map(PathBuf::from);
        } else if arg == "--session" {
            session = args.next().and_then(|arg| arg.into_string().ok());
        } else if arg == "--capabilities" {
            let values = args
                .next()
                .and_then(|arg| arg.into_string().ok())
                .ok_or_else(|| std::io::Error::other("missing capabilities"))?;
            permissions = Some(
                values
                    .split(',')
                    .filter(|value| !value.is_empty())
                    .map(str::to_owned)
                    .collect(),
            );
        } else if arg == "--hooks" {
            if let Some(capabilities) = &mut permissions {
                capabilities.insert("hooks.configure".into());
            }
        } else if arg == "--stdio" {
        } else if arg == "--remote" {
            remote = true;
        } else if matches!(
            arg.to_str(),
            Some("--shell" | "--cwd" | "--tmux" | "--herdr" | "--herdr-socket" | "--herdr-session")
        ) {
            let value = args
                .next()
                .ok_or_else(|| std::io::Error::other("missing option value"))?;
            options.insert(arg, value);
        } else {
            if mode.as_deref() == Some(std::ffi::OsStr::new("login")) && script.is_none() {
                script = Some(arg);
                continue;
            }
            return Err(std::io::Error::other(format!(
                "unknown helper option {}",
                arg.to_string_lossy()
            )));
        }
    }
    if mode.is_some() {
        remote = true;
        let session = session
            .as_deref()
            .ok_or_else(|| std::io::Error::other("missing login session"))?;
        socket = Some(match socket {
            Some(socket) => socket,
            None => dispatch_helper_core::system::login::endpoint(session)?,
        });
        if mode.as_deref() == Some(std::ffi::OsStr::new("connect")) {
            return dispatch_helper_core::system::login::connect(socket.as_deref().unwrap());
        }
    }
    let cwd = options
        .get(std::ffi::OsStr::new("--cwd"))
        .map(PathBuf::from)
        .unwrap_or(System::cwd()?);
    let shell = options
        .get(std::ffi::OsStr::new("--shell"))
        .cloned()
        .or_else(|| std::env::var_os("SHELL"))
        .unwrap_or("/bin/sh".into());
    let (uid, home) = System::account()?;
    let mut helper = DispatchHelper::new();
    *helper.permissions.borrow_mut() = permissions;
    helper.shell = shell.clone().into();
    let harnesses = [
        (
            "claude",
            helper.add_harness(dispatch_helper_claude::Claude::new(home.clone(), remote)),
        ),
        (
            "pi",
            helper.add_harness(dispatch_helper_pi::Pi::new(home.clone())),
        ),
        (
            "nanocodex",
            helper.add_harness(dispatch_helper_nanocodex::Nano::new(uid, home, remote)),
        ),
        (
            "codex",
            helper.add_harness(dispatch_helper_codex::Codex::new()),
        ),
    ];
    for (program, key) in TYPED {
        if let Some((_, harness)) = harnesses.iter().find(|(name, _)| *name == key) {
            helper.typed(harness, program);
        }
    }
    if let Some((key, arguments)) = launch {
        let mut io = System::new(1, 16)?;
        let result = (|| -> std::io::Result<i32> {
            if key == "herdr" {
                let endpoint = std::env::var_os("DISPATCH_HELPER_ENDPOINT").map(PathBuf::from);
                dispatch_helper_core::system::sender::launch(&mut io, &key, &arguments, endpoint.as_deref())?;
                return Ok(0);
            }
            let (index, (_, harness)) = harnesses
                .into_iter()
                .enumerate()
                .find(|(_, (name, _))| *name == key)
                .ok_or_else(|| std::io::Error::other("unknown harness key"))?;
            let endpoint = std::env::var_os("DISPATCH_HELPER_ENDPOINT").map(PathBuf::from);
            if harness.borrow().configures(&arguments) {
                dispatch_helper_core::system::sender::setup(
                    &mut io,
                    &format!("harness/{index}"),
                    endpoint.as_deref(),
                )?;
            }
            dispatch_helper_core::system::launch::run(&mut io, harness, &arguments)
        })();
        let status = io.finish(result.as_ref().copied().unwrap_or(1))?;
        result?;
        std::process::exit(status);
    }
    if let Some(hook) = hook {
        let result = (|| -> std::io::Result<()> {
            let mut io = System::new(1, 16)?;
            // Hooks fail open: the agent continues in its ordinary terminal UI and nothing leaks
            // into its diagnostics (old ssh-helper main.rs:132-136).
            // The harness's registration order is its route section (harness/<index>).
            if let Some((key, endpoint)) = hook
                && let Some(index) = harnesses.iter().position(|(name, _)| *name == key)
            {
                let section = format!("harness/{index}");
                let harness = harnesses[index].1.clone();
                let _ =
                    dispatch_helper_core::system::sender::run(&mut io, harness, &section, endpoint.as_deref());
            }
            io.finish(0)?;
            Ok(())
        })();
        // Native hooks fail open, but replay must never hide a verification failure.
        if System::recording().is_some() { result?; }
        std::process::exit(0);
    }
    #[cfg(feature = "tmux")]
    helper.add_multiplexer(dispatch_helper_tmux::Tmux::new("tmux".into()));
    let native = helper.add_multiplexer(dispatch_helper_native::Native::new(
        shell.clone().into(),
        cwd.clone(),
        Grid {
            pixels: None,
            columns: 80,
            rows: 24,
        },
    ));
    helper.default_backend(&native, "native");
    helper.add_multiplexer(dispatch_helper_herdr::Herdr::new(
        dispatch_helper_herdr::Config {
            executable: options
                .get(std::ffi::OsStr::new("--herdr"))
                .map(PathBuf::from)
                .unwrap_or("herdr".into()),
            socket: options
                .get(std::ffi::OsStr::new("--herdr-socket"))
                .cloned()
                .or_else(|| std::env::var_os("HERDR_SOCKET_PATH"))
                .map(PathBuf::from)
                .unwrap_or_default(),
            session: options
                .get(std::ffi::OsStr::new("--herdr-session"))
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or("main".into()),
            directory: cwd.clone(),
            environment: std::env::vars().collect(),
            uid,
        },
    ));
    // Interactive shells of every mux define the typed programs (old ssh-helper startup.rs).
    let typed: Vec<_> = TYPED
        .iter()
        .map(|(p, k)| (p.to_string(), k.to_string()))
        .collect();
    helper.startup(dispatch_helper_core::system::startup::Integration::typed(
        &typed,
    ));
    helper.add_plugin(dispatch_helper_files::Files::new(remote));
    helper.add_plugin(dispatch_helper_stats::Stats::new(!remote));
    if mode.as_deref() == Some(std::ffi::OsStr::new("login")) {
        let mut command = std::process::Command::new(&shell);
        command.env("SHELL", &shell).env("TERM", "xterm-256color");
        for name in ["TOKEN", "SOCKET", "SESSION", "HELPER", "STARTUP"] {
            command.env_remove(format!("DISPATCH_SSH_{name}"));
        }
        match &script {
            Some(script) => command.arg("-c").arg(script),
            None => command.arg("-l"),
        };
        // No terminal (e.g. `ssh host cmd` without a PTY): run the shell itself with ordinary
        // ssh semantics, like c1654cc ssh-helper relay.rs:107-114.
        if System::recording().is_none() && !std::io::IsTerminal::is_terminal(&std::io::stdin()) {
            use std::os::unix::process::CommandExt;
            return Err(command.exec());
        }
        command
            .current_dir(&cwd)
            .env("DISPATCH_SSH_SESSION", session.as_deref().unwrap())
            .env("DISPATCH_SSH_HELPER", System::image()?);
        // A failed login says what failed in plain words (e.g. no PTY could be opened).
        match helper.run_login(socket.as_deref().unwrap(), Some(command)) {
            Ok(status) => std::process::exit(status),
            Err(error) => {
                eprintln!("dispatch-helper: {error}");
                std::process::exit(1);
            }
        }
    }
    match socket {
        Some(socket) => helper.run(&socket),
        None => helper.run_stdio(),
    }
}
