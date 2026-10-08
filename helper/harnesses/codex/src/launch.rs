//! c1654cc CodexLauncher: private nonterminal server preparation and TUI-exit cleanup.
use crate::{
    channel::os,
    jobs::{self, Jobs},
};
use dispatch_helper_core::{
    api::*,
    json::{Data, Value},
};
use std::{
    cell::RefCell,
    collections::BTreeMap,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    rc::Rc,
    time::{Duration, Instant},
};

pub struct Server {
    pub pid: u32,
    pub process: Option<Process>,
    /// Started here; a typed launch's server belongs to its launcher, which ends it.
    pub owned: bool,
}
pub type Servers = Rc<RefCell<BTreeMap<String, Server>>>;
type Pending = Rc<RefCell<BTreeMap<u64, Rc<RefCell<Waiting>>>>>;
type Tui = Box<dyn FnOnce(Option<&str>) -> Command>;

/// The original `codex` arguments: which belong to the private server and whether a picker needs
/// the launch directory; c1654cc CodexLauncher.swift:10-62.
#[derive(Default)]
pub struct Invocation {
    pub server: Vec<String>,
    directory: bool,
    selects: bool,
    all: bool,
}

impl Invocation {
    /// None keeps the CLI's own semantics (subcommands, help, profiles, unknown flags).
    pub fn parse(arguments: &[String]) -> Option<Self> {
        const VALUES: [&str; 12] = [
            "-m",
            "--model",
            "-s",
            "--sandbox",
            "-a",
            "--ask-for-approval",
            "-C",
            "--cd",
            "--add-dir",
            "--local-provider",
            "-i",
            "--image",
        ];
        const FLAGS: [&str; 8] = [
            "--no-alt-screen",
            "--oss",
            "--search",
            "--full-auto",
            "--approve-for-me",
            "--dangerously-bypass-approvals-and-sandbox",
            "--last",
            "--all",
        ];
        let mut result = Self::default();
        let mut positional = false;
        let mut index = 0;
        for _ in 0..=arguments.len() {
            let Some(argument) = arguments.get(index).map(String::as_str) else {
                break;
            };
            if ["-c", "--config", "--enable", "--disable"].contains(&argument) {
                result
                    .server
                    .extend([argument.to_owned(), arguments.get(index + 1)?.clone()]);
                index += 2;
                continue;
            }
            if ["--config=", "--enable=", "--disable="]
                .iter()
                .any(|prefix| argument.starts_with(prefix))
            {
                result.server.push(argument.into());
                index += 1;
                continue;
            }
            if VALUES.contains(&argument) {
                arguments.get(index + 1)?;
                result.directory |= argument == "-C" || argument == "--cd";
                index += 2;
                continue;
            }
            result.directory |= argument.starts_with("--cd=");
            result.all |= argument == "--all";
            if VALUES
                .iter()
                .filter(|value| value.starts_with("--"))
                .any(|value| {
                    argument
                        .strip_prefix(value)
                        .is_some_and(|rest| rest.starts_with('='))
                })
                || FLAGS.contains(&argument)
            {
                index += 1;
                continue;
            }
            if argument == "--" {
                if index + 1 < arguments.len() {
                    result.selects = false;
                }
                return Some(result);
            }
            if argument.starts_with('-') {
                return None;
            }
            if positional {
                result.selects = false;
            } else {
                if SUBCOMMANDS.contains(&argument) {
                    return None;
                }
                result.selects = argument == "resume" || argument == "fork";
                positional = true;
            }
            index += 1;
        }
        Some(result)
    }

    /// A remote TUI has no implicit cwd: a resume/fork picker gets the launch directory unless an
    /// explicit id, --all or a directory override is given; c1654cc CodexLauncher.swift:16-22.
    pub fn remote(&self, arguments: &[String], endpoint: &str, directory: &str) -> Vec<String> {
        let mut result = vec!["--remote".to_owned(), endpoint.into()];
        if self.selects && !self.all && !self.directory {
            result.extend(["--cd".to_owned(), directory.into()]);
        }
        result.extend(arguments.iter().cloned());
        result
    }
}

const SUBCOMMANDS: [&str; 28] = [
    "agents",
    "exec",
    "e",
    "review",
    "login",
    "logout",
    "mcp",
    "mcp-server",
    "plugin",
    "app-server",
    "remote-control",
    "app",
    "completion",
    "update",
    "doctor",
    "sandbox",
    "debug",
    "apply",
    "a",
    "queue",
    "archive",
    "delete",
    "migrate-rollouts",
    "unarchive",
    "cloud",
    "exec-server",
    "features",
    "help",
];

/// Whether to isolate a TUI fallback. Explicit endpoints and service commands keep their own
/// launch policy. Unknown options must not silently opt an interactive launch into the shared
/// daemon; after one, positional arguments may be option values, so stop classifying commands.
pub fn native(arguments: &[String]) -> bool {
    let mut arguments = arguments.iter();
    let mut positional = false;
    for _ in 0..=arguments.len() {
        let Some(argument) = arguments.next() else {
            break;
        };
        let (option, inline) = argument
            .split_once('=')
            .map_or((argument.as_str(), false), |(key, _)| (key, true));
        match option {
            "--" => return true,
            "--remote" | "--no-daemon" | "--help" | "-h" | "--version" | "-V" => return false,
            "-c" | "--config" | "--enable" | "--disable" | "-m" | "--model" | "-s"
            | "--sandbox" | "-a" | "--ask-for-approval" | "-C" | "--cd" | "--add-dir"
            | "--local-provider" | "-i" | "--image" | "-p" | "--profile" => {
                if !inline && arguments.next().is_none() {
                    return false;
                }
            }
            "--no-alt-screen"
            | "--strict-config"
            | "--worktree"
            | "--dangerously-bypass-hook-trust"
            | "--oss"
            | "--search"
            | "--full-auto"
            | "--approve-for-me"
            | "--dangerously-bypass-approvals-and-sandbox"
            | "--last"
            | "--all" => {}
            _ if argument.starts_with('-') => positional = true,
            _ if !positional => {
                if SUBCOMMANDS.contains(&argument.as_str()) {
                    return false;
                }
                positional = true;
            }
            _ => {}
        }
    }
    true
}

#[derive(Clone, Default)]
pub struct Launch {
    pub servers: Servers,
    pending: Pending,
}
struct Waiting {
    jobs: Jobs,
    pending: Pending,
    servers: Servers,
    path: PathBuf,
    endpoint: String,
    watch: u64,
    pid: u32,
    deadline: Instant,
    done: Option<Done<Command>>,
    /// TUI command for the ready endpoint, or the fallback when the server is unavailable.
    tui: Option<Tui>,
    checking: bool,
}

impl Launch {
    /// Launch `codex <arguments>` in `cwd`: probe help once, then use a private app-server when
    /// the invocation allows one (c1654cc CodexLauncher.swift:69-112), else an embedded TUI.
    /// A failed probe must not select the shared daemon. Only successful legacy help without
    /// --no-daemon permits the old passthrough; explicit endpoints and services remain untouched.
    pub fn invoke(
        &self,
        jobs: Jobs,
        io: &mut dyn Io,
        cwd: &Path,
        arguments: &[String],
        done: Done<Command>,
    ) {
        let cwd = cwd.to_owned();
        let arguments = arguments.to_vec();
        let launch = self.clone();
        let mut probe = Command::new("codex");
        probe
            .arg("--help")
            .current_dir(&cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let deadline = io.now() + Duration::from_secs(2);
        jobs::submit(
            &jobs.clone(),
            io,
            Job::Run {
                command: probe,
                input: Vec::new(),
                deadline,
            },
            Box::new(move |io, result| {
                let help = match result {
                    Ok(Output::Exit {
                        status: Some(0),
                        stdout,
                    }) if stdout.len() <= 65_536 => stdout,
                    _ => Vec::new(),
                };
                let isolated = native(&arguments)
                    && (help.iter().all(u8::is_ascii_whitespace)
                        || help
                            .split(u8::is_ascii_whitespace)
                            .any(|word| word == b"--no-daemon"));
                let invocation = (help.windows(8).any(|word| word == b"--remote")
                    && help.windows(7).any(|word| word == b"unix://"))
                .then(|| Invocation::parse(&arguments))
                .flatten();
                let server = invocation
                    .as_ref()
                    .map(|invocation| invocation.server.clone());
                let directory = cwd.to_string_lossy().into_owned();
                let working = cwd.clone();
                let tui: Tui = Box::new(move |endpoint| {
                    let mut command = Command::new("codex");
                    command.current_dir(&working);
                    match (endpoint, &invocation) {
                        (Some(endpoint), Some(invocation)) => {
                            command.args(invocation.remote(&arguments, endpoint, &directory));
                        }
                        _ => {
                            if isolated {
                                command.arg("--no-daemon");
                            }
                            command.args(&arguments);
                        }
                    }
                    command
                });
                match server {
                    Some(server) => launch.prepare(jobs, io, cwd, &server, tui, done),
                    None => deferred(done)(io, Ok(tui(None))),
                }
            }),
        );
    }

    /// c1654cc CodexLauncher.swift:93-97: the server listens in a fresh private directory,
    /// `/tmp/dispatch-codex-<UUID>/control.sock` (DISPATCH_TEST_ROOT replaces /tmp in tests), so
    /// the socket path fits sun_path on every platform. Any failure falls back to the TUI
    /// without a private server, like the old passthrough.
    pub fn prepare(
        &self,
        jobs: Jobs,
        io: &mut dyn Io,
        cwd: PathBuf,
        server: &[String],
        tui: Tui,
        done: Done<Command>,
    ) {
        let Ok(id) = jobs::uuid(io) else {
            deferred(done)(io, Ok(tui(None)));
            return;
        };
        let base = std::env::var_os("DISPATCH_TEST_ROOT").map_or("/tmp".into(), PathBuf::from);
        let root = base.join(format!("dispatch-codex-{id}"));
        let path = root.join("control.sock");
        let mut command = Command::new("codex");
        command
            .args([
                "app-server",
                "--listen",
                &format!("unix://{}", path.display()),
            ])
            .args(server)
            .current_dir(&cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let (launch, next) = (self.clone(), jobs.clone());
        let pid = Data::Object(vec![("pid", Data::Unsigned(io.pid().into()))]);
        jobs::native(
            &jobs,
            io,
            "process",
            pid,
            Box::new(move |io, result| {
                let uid = result
                    .ok()
                    .and_then(|value| value.root().get("uid").and_then(Value::unsigned));
                let made = next.clone();
                let create = Job::MakeDir {
                    path: root.clone(),
                    mode: 0o700,
                };
                jobs::submit(
                    &next,
                    io,
                    create,
                    Box::new(move |io, result| {
                        let directory = root.to_string_lossy().into_owned();
                        let input = Data::Object(vec![("path", Data::String(&directory))]);
                        let checked = made.clone();
                        let created = result.is_ok();
                        jobs::native(
                            &made,
                            io,
                            "file.lstat",
                            input,
                            Box::new(move |io, result| {
                                // Shared /tmp: only a directory of ours, private to us.
                                let private = result.ok().is_some_and(|value| {
                                    let field =
                                        |name| value.root().get(name).and_then(Value::unsigned);
                                    value.root().get("kind").and_then(Value::string)
                                        == Some("directory")
                                        && uid.is_some()
                                        && field("uid") == uid
                                        && field("mode").is_some_and(|mode| mode & 0o777 == 0o700)
                                });
                                if created && private {
                                    launch.listen(checked, io, path, command, tui, done);
                                } else {
                                    deferred(done)(io, Ok(tui(None)));
                                }
                            }),
                        );
                    }),
                );
            }),
        );
    }

    /// Starts the private server `command` listening on `path` and waits for its socket.
    fn listen(
        &self,
        jobs: Jobs,
        io: &mut dyn Io,
        path: PathBuf,
        command: Command,
        tui: Tui,
        done: Done<Command>,
    ) {
        let endpoint = format!("unix://{}", path.display());
        let result = (|| {
            let watch = io.watch(&path, false).map_err(os)?;
            let spawned = match io.spawn(command, None) {
                Ok(spawned) => spawned,
                Err(error) => {
                    io.unwatch(watch);
                    return Err(os(error));
                }
            };
            if let Err(error) = io.child(spawned.pid) {
                io.unwatch(watch);
                let _ = io.terminate(spawned.pid);
                return Err(os(error));
            }
            Ok((path, endpoint, watch, spawned.pid))
        })();
        let (path, endpoint, watch, pid) = match result {
            Ok(value) => value,
            Err(_) => {
                deferred(done)(io, Ok(tui(None)));
                return;
            }
        };
        let deadline = io.now() + Duration::from_secs(5);
        io.timer(deadline);
        let waiting = Rc::new(RefCell::new(Waiting {
            jobs,
            pending: self.pending.clone(),
            servers: self.servers.clone(),
            path,
            endpoint,
            watch,
            pid,
            deadline,
            done: Some(deferred(done)),
            tui: Some(tui),
            checking: false,
        }));
        self.pending.borrow_mut().insert(watch, waiting.clone());
        Waiting::check(waiting, io);
    }

    pub fn exited(&self, jobs: &Jobs, io: &mut dyn Io, process: &Process) {
        // A typed launch (core system/launch.rs) reports its own command, a child of this
        // process: the servers it prepared serve that command.
        let launched = process.parent == io.pid();
        let endpoints = self
            .servers
            .borrow()
            .iter()
            .filter(|(_, server)| match &server.process {
                Some(owner) => owner.pid == process.pid && owner.start == process.start,
                None => launched && server.owned,
            })
            .map(|(endpoint, _)| endpoint.clone())
            .collect::<Vec<_>>();
        for endpoint in endpoints {
            let server = self.servers.borrow_mut().remove(&endpoint);
            let Some(server) = server.filter(|server| server.owned) else {
                continue;
            };
            let _ = io.terminate(server.pid);
            // c1654cc CodexLauncher.swift:97 removed its private root: the socket, then its
            // directory once empty (core C-RMDIR). The directory waits for the socket's removal.
            if let Some(path) = endpoint.strip_prefix("unix://") {
                let socket = PathBuf::from(path);
                let directory = socket.parent().map(Path::to_path_buf);
                let remove = |path| Job::Remove {
                    expected: Expected::Any,
                    path,
                };
                jobs::submit(
                    jobs,
                    io,
                    remove(socket),
                    Box::new(move |io, _| {
                        if let Some(directory) = directory {
                            let _ = io.submit(remove(directory));
                        }
                    }),
                );
            }
        }
    }

    pub fn event(&self, io: &mut dyn Io, event: &Event) {
        let waiting = self.pending.borrow().values().cloned().collect::<Vec<_>>();
        for pending in waiting {
            let current = pending.borrow();
            let expired = matches!(event, Event::Timer { .. }) && current.deadline <= io.now();
            let exited = matches!(event, Event::Exit { pid, .. } if *pid == current.pid);
            let changed = matches!(event, Event::Changed { watch, .. } if *watch == current.watch);
            drop(current);
            if expired || exited {
                pending.borrow_mut().finish(io, false);
            } else if changed {
                Waiting::check(pending, io);
            }
        }
        if let Event::Exit { pid, .. } = event {
            self.servers
                .borrow_mut()
                .retain(|_, server| server.pid != *pid);
        }
    }
}

impl Waiting {
    fn check(waiting: Rc<RefCell<Self>>, io: &mut dyn Io) {
        let mut current = waiting.borrow_mut();
        if current.checking || current.done.is_none() {
            return;
        }
        current.checking = true;
        let path = current.path.clone();
        let next = waiting.clone();
        jobs::submit(
            &current.jobs,
            io,
            Job::Stat { path, follow: true },
            Box::new(move |io, result| {
                let mut current = next.borrow_mut();
                current.checking = false;
                if matches!(result, Ok(Output::Metadata(metadata)) if metadata.kind == FileKind::Other)
                {
                    current.finish(io, true);
                }
            }),
        );
    }

    fn finish(&mut self, io: &mut dyn Io, ready: bool) {
        let Some(done) = self.done.take() else { return };
        io.unwatch(self.watch);
        self.pending.borrow_mut().remove(&self.watch);
        if ready {
            self.servers.borrow_mut().insert(
                self.endpoint.clone(),
                Server {
                    pid: self.pid,
                    process: None,
                    owned: true,
                },
            );
        } else {
            let _ = io.terminate(self.pid);
        }
        let tui = self.tui.take().unwrap();
        done(io, Ok(tui(ready.then_some(self.endpoint.as_str()))));
    }
}
