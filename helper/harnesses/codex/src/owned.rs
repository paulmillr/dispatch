//! The existing Codex side-sheet recipe, using shared native jobs and stdio.
use crate::{
    channel::{Channel, Channels, failure, initialize},
    jobs::{self, Jobs},
    side,
};
use dispatch_helper_core::{
    api::{Binding, Done, Error, Expected, Io, Job, Process, deferred},
    json::{Data, Json, Value},
    wire::body::Encoded,
};
use std::{cell::RefCell, collections::BTreeMap, path::PathBuf, process::Command, rc::Rc};

/// Directories removed when their process exits (pid -> path); harness event handling.
pub type Exits = Rc<RefCell<BTreeMap<u32, PathBuf>>>;

/// What `command` prepared: the command, its directory, the private directory it made (to remove
/// when the spawned process exits), and whether the parent layers a `--profile`.
pub struct Prepared {
    pub command: Command,
    pub cwd: PathBuf,
    pub scratch: Option<PathBuf>,
    pub profile: bool,
}

const PROFILE: &str = "Side conversations are unavailable for a Codex started with --profile: its side agent could not load that profile, so it could run on another provider. Start Codex with -c key=value overrides instead.";

enum Stage {
    Child,
    Initialize,
    Configuration,
    Thread,
    /// The parent's further variables, for a side agent started again with them.
    Environment,
    Fork,
    Send,
}

struct Open {
    jobs: Jobs,
    channels: Channels,
    parent: Binding,
    question: String,
    read_only: bool,
    stage: Stage,
    cwd: PathBuf,
    /// The private directory made for a parent without a known directory, until the side
    /// agent runs in it (then `exits` owns its removal).
    scratch: Option<PathBuf>,
    exits: Exits,
    channel: Option<Rc<RefCell<Channel>>>,
    key: String,
    done: Option<Done<Binding>>,
    /// The parent's variables requested beyond side::ENVIRONMENT, and how many of all requested
    /// the running side agent got.
    names: Vec<String>,
    variables: usize,
    /// The names the parent lists in side::DECLARED.
    declared: Vec<String>,
    /// The side agent's effective configuration (config/read) and the parent's model (thread/read).
    configuration: Option<Json>,
    pinned: Option<side::Pinned>,
}

/// The side's command: without side::DECLARED (a list of names, read here), read-only features
/// off; and how many variables it passes on.
pub(crate) fn launchable(mut command: Command, read_only: bool) -> (Command, Vec<String>, usize) {
    let declared = command
        .get_envs()
        .find(|(name, _)| *name == side::DECLARED)
        .and_then(|(_, value)| value)
        .map(|value| {
            use std::os::unix::ffi::OsStrExt;
            side::declared(value.as_bytes())
        })
        .unwrap_or_default();
    command.env_remove(side::DECLARED);
    let variables = command.get_envs().filter(|(_, value)| value.is_some()).count();
    if read_only {
        for feature in side::FEATURES {
            command.args(["--disable", feature]);
        }
    }
    (command, declared, variables)
}

#[allow(clippy::too_many_arguments)]
pub fn open(
    jobs: Jobs,
    channels: Channels,
    exits: Exits,
    io: &mut dyn Io,
    parent: Binding,
    question: &str,
    read_only: bool,
    done: Done<Binding>,
) {
    let (next, question) = (jobs.clone(), question.to_owned());
    let names: Vec<String> = side::SIDE_ENVIRONMENT.map(str::to_owned).to_vec();
    command(
        jobs,
        io,
        parent.clone(),
        names.clone(),
        Box::new(move |io, result| {
            let Prepared { command, cwd, scratch, profile } = match result {
                Ok(value) => value,
                Err(error) => return deferred(done)(io, Err(error)),
            };
            if profile {
                remove(io, scratch);
                return deferred(done)(io, Err(failure("profile", PROFILE)));
            }
            let (command, declared, variables) = launchable(command, read_only);
            let pending = Rc::new(RefCell::new(Open {
                jobs: next,
                channels,
                parent,
                question,
                read_only,
                stage: Stage::Child,
                cwd,
                scratch,
                exits,
                channel: None,
                key: String::new(),
                done: Some(deferred(done)),
                names,
                variables,
                declared,
                configuration: None,
                pinned: None,
            }));
            let spawned = pending.borrow_mut().spawn(&pending, io, command);
            if let Err(error) = spawned {
                pending.borrow_mut().finish(io, Err(error));
            }
        }),
    );
}

/// Codex as `parent` runs it: its own executable file (c51466a process.rs:879-896, core R5; argv0
/// stays the path), its directory or else a fresh private one (c1654cc Settings.swift:226-232,
/// core C-AGENT-DIR), only the side variables of its environment (c51466a
/// agent_side.rs:72-84) and `names` besides, and its own configuration overrides
/// (side::overrides); `app-server --stdio` with that directory and the private directory to
/// remove when the spawned process exits.
pub fn command(
    jobs: Jobs,
    io: &mut dyn Io,
    parent: Binding,
    names: Vec<String>,
    done: Done<Prepared>,
) {
    let pid = Data::Object(vec![("pid", Data::Unsigned(parent.process.pid.into()))]);
    let next = jobs.clone();
    jobs::native(
        &jobs,
        io,
        "process",
        pid,
        Box::new(move |io, result| {
            let observed = match result.and_then(|value| {
                let value = value.root();
                let cwd = value.get("cwd").and_then(Data::path).map(PathBuf::from);
                Ok((jobs::process(&value)?, cwd))
            }) {
                Ok(value) => value,
                Err(error) => return deferred(done)(io, Err(error)),
            };
            if !same(&observed.0, &parent) {
                return deferred(done)(io, Err(failure("process", "The parent agent exited")));
            }
            match observed.1.filter(|path| path.is_absolute()) {
                Some(cwd) => environment(next, io, parent, cwd, None, names, done),
                None => {
                    let made = jobs::uuid(io)
                        .and_then(|id| Ok(io.directory()?.join("agents").join(id)))
                        .map_err(crate::channel::os);
                    let path = match made {
                        Ok(path) => path,
                        Err(error) => return deferred(done)(io, Err(error)),
                    };
                    let job = Job::MakeDir {
                        path: path.clone(),
                        mode: 0o700,
                    };
                    let after = next.clone();
                    jobs::submit(
                        &next,
                        io,
                        job,
                        Box::new(move |io, result| match result {
                            Ok(_) => {
                                environment(after, io, parent, path.clone(), Some(path), names, done)
                            }
                            Err(error) => deferred(done)(io, Err(error)),
                        }),
                    );
                }
            }
        }),
    );
}

/// The variables the configuration of `channel`'s server names for its default provider
/// (side::referenced, without MCP servers), for the model catalog: when the parent has any of
/// them, a server started again with them (in the same directory) replaces `channel`.
#[allow(clippy::too_many_arguments)]
pub fn credentials(
    jobs: Jobs,
    io: &mut dyn Io,
    parent: Binding,
    channel: Rc<RefCell<Channel>>,
    cwd: PathBuf,
    names: Vec<String>,
    declared: Vec<String>,
    variables: usize,
    exits: Exits,
    done: Done<Rc<RefCell<Channel>>>,
) {
    let directory = cwd.to_string_lossy().into_owned();
    let current = channel.clone();
    channel.borrow_mut().request(
        io,
        "config/read",
        Data::Object(vec![("cwd", Data::String(&directory))]),
        Box::new(move |io, result| {
            let configuration = match result {
                Ok(configuration) => configuration,
                Err(error) => return deferred(done)(io, Err(error)),
            };
            let config = configuration.root().get("config");
            let provider = config
                .and_then(|config| config.get("model_provider"))
                .and_then(Value::string)
                .unwrap_or("openai");
            let referenced = match config {
                Some(config) => side::referenced(config, provider, true, &declared),
                None => Vec::new(),
            };
            let mut further: Vec<String> = referenced
                .into_iter()
                .filter(|name| !side::ENVIRONMENT.contains(&name.as_str()) && !names.contains(name))
                .collect();
            if further.is_empty() {
                return deferred(done)(io, Ok(current));
            }
            further.splice(0..0, names);
            environment(
                jobs,
                io,
                parent.clone(),
                cwd,
                None,
                further,
                Box::new(move |io, result| {
                    let prepared = match result {
                        Ok(prepared) => prepared,
                        Err(error) => return deferred(done)(io, Err(error)),
                    };
                    let (command, _, count) = launchable(prepared.command, false);
                    if count <= variables {
                        return deferred(done)(io, Ok(current));
                    }
                    let pid = current.borrow().pid;
                    let scratch = exits.borrow_mut().remove(&pid);
                    let _ = current
                        .borrow_mut()
                        .close(io, failure("models", "Replaced by a catalog server with the parent's credentials."));
                    let replacement = match Channel::spawn(io, parent, command) {
                        Ok(channel) => Rc::new(RefCell::new(channel)),
                        Err(error) => {
                            remove(io, scratch);
                            return deferred(done)(io, Err(error));
                        }
                    };
                    if let Some(path) = scratch {
                        exits.borrow_mut().insert(replacement.borrow().pid, path);
                    }
                    let next = replacement.clone();
                    crate::channel::initialize(
                        replacement,
                        io,
                        "dispatch",
                        Box::new(move |io, result| deferred(done)(io, result.map(|_| next))),
                    );
                }),
            );
        }),
    );
}

/// Removes a private directory `command` made that no process runs in.
pub fn remove(io: &mut dyn Io, scratch: Option<PathBuf>) {
    if let Some(path) = scratch {
        let _ = io.submit(Job::Remove {
            path,
            expected: Expected::Any,
        });
    }
}

fn same(observed: &dispatch_helper_core::api::Process, parent: &Binding) -> bool {
    observed.pid == parent.process.pid
        && observed.start == parent.process.start
        && observed.executable == parent.process.executable
}

/// The parent's side variables (side::ENVIRONMENT, then `names`), then the parent once more:
/// still the same process.
pub(crate) fn environment(
    jobs: Jobs,
    io: &mut dyn Io,
    parent: Binding,
    cwd: PathBuf,
    scratch: Option<PathBuf>,
    names: Vec<String>,
    done: Done<Prepared>,
) {
    let extra = names.iter().filter(|name| !side::ENVIRONMENT.contains(&name.as_str()));
    let names = side::ENVIRONMENT
        .into_iter()
        .chain(extra.map(String::as_str))
        .map(Data::String)
        .collect();
    let pid = parent.process.pid;
    // Bound to the parent's exact process: a reused pid's environment is never read.
    let start = parent.process.start.iter().map(|n| Data::Unsigned(*n)).collect();
    let executable = parent.process.executable.clone();
    let input = Data::Object(vec![
        ("pid", Data::Unsigned(pid.into())),
        ("start", Data::Array(start)),
        ("executable", Data::from(executable.as_path())),
        ("names", Data::Array(names)),
    ]);
    let next = jobs.clone();
    // A failure after the private directory was made removes it again.
    let fail = |io: &mut dyn Io, scratch, error, done: Done<_>| {
        remove(io, scratch);
        deferred(done)(io, Err(error))
    };
    jobs::native(
        &jobs,
        io,
        "environment",
        input,
        Box::new(move |io, result| {
            let environment = match result {
                Ok(environment) => environment,
                Err(error) => return fail(io, scratch, error, done),
            };
            let pid = Data::Object(vec![("pid", Data::Unsigned(pid.into()))]);
            jobs::native(
                &next,
                io,
                "process",
                pid,
                Box::new(move |io, result| {
                    let observed = match result.and_then(|value| jobs::process(&value.root()))
                    {
                        Ok(observed) if same(&observed, &parent) => observed,
                        Ok(_) => {
                            let error = failure("process", "The parent agent exited");
                            return fail(io, scratch, error, done);
                        }
                        Err(error) => return fail(io, scratch, error, done),
                    };
                    let mut command = match io.os() == "linux" {
                        true => Command::new(format!("/proc/{}/exe", observed.pid)),
                        false => Command::new(&observed.executable),
                    };
                    std::os::unix::process::CommandExt::arg0(&mut command, &observed.executable);
                    let overrides = side::overrides(&observed.arguments);
                    command
                        .args(["app-server", "--stdio"])
                        .args(&overrides.arguments)
                        .current_dir(&cwd)
                        .env_clear();
                    // Values are bytes: the parent's environment passes on unchanged.
                    let environment = environment.root();
                    let variables = environment.object().map(|values| {
                        values
                            .map(|(name, value)| {
                                use std::os::unix::ffi::OsStrExt;
                                Some((name, std::ffi::OsStr::from_bytes(value.bytes()?)))
                            })
                            .collect::<Option<Vec<_>>>()
                    });
                    let Some(Some(variables)) = variables else {
                        let error = failure("environment", "Invalid parent environment");
                        return fail(io, scratch, error, done);
                    };
                    command.envs(variables);
                    let profile = overrides.profile;
                    deferred(done)(io, Ok(Prepared { command, cwd, scratch, profile }));
                }),
            );
        }),
    );
}

impl Open {
    fn request(
        &mut self,
        pending: &Rc<RefCell<Self>>,
        io: &mut dyn Io,
        stage: Stage,
        name: &'static str,
        params: Data<'_>,
    ) {
        let native = matches!(stage, Stage::Child);
        self.stage = stage;
        let pending = pending.clone();
        if native {
            // The side process's facts come from System (a native job), not from codex.
            let done = Box::new(move |io: &mut dyn Io, result: Result<Encoded, Error>| {
                let mut open = pending.borrow_mut();
                let result = result
                    .and_then(|value| jobs::process(&value.root()))
                    .and_then(|observed| open.child(&pending, io, observed));
                if let Err(error) = result {
                    open.finish(io, Err(error));
                }
            });
            jobs::native(&self.jobs, io, name, params, done);
        } else {
            let done = Box::new(move |io: &mut dyn Io, result| Self::advance(pending, io, result));
            self.channel
                .as_ref()
                .unwrap()
                .borrow_mut()
                .request(io, name, params, done);
        }
    }

    fn child(&mut self, pending: &Rc<RefCell<Self>>, io: &mut dyn Io, observed: Process) -> Result<(), Error> {
        let channel = self.channel.as_ref().unwrap();
        if observed.pid != channel.borrow().pid {
            return Err(failure("process", "Side process changed"));
        }
        channel.borrow_mut().binding.process = observed;
        self.stage = Stage::Initialize;
        let pending = pending.clone();
        initialize(
            channel.clone(),
            io,
            "dispatch_side",
            Box::new(move |io, result| {
                let result = result.and_then(|_| Json::parse(b"{}"));
                Self::advance(pending, io, result);
            }),
        );
        Ok(())
    }

    fn finish(&mut self, io: &mut dyn Io, result: Result<Binding, Error>) {
        let Some(done) = self.done.take() else {
            return;
        };
        self.channels.borrow_mut().remove(&self.key);
        match &result {
            Ok(binding) => {
                let channel = self.channel.as_ref().unwrap().clone();
                channel.borrow_mut().ready = true;
                self.channels
                    .borrow_mut()
                    .insert(binding.session.clone(), channel);
            }
            Err(error) => {
                if let Some(channel) = &self.channel {
                    let _ = channel.borrow_mut().close(io, error.clone());
                }
                remove(io, self.scratch.take());
            }
        }
        done(io, result);
    }

    /// Runs the side agent: its channel is known before the child's identity check.
    fn spawn(
        &mut self,
        pending: &Rc<RefCell<Self>>,
        io: &mut dyn Io,
        command: Command,
    ) -> Result<(), Error> {
        let mut channel = Channel::spawn(io, self.parent.clone(), command)?;
        channel.read_only = self.read_only;
        let pid = channel.pid;
        // ChatSideConnection.swift:93-94: the empty directory goes when the agent exits.
        if let Some(path) = self.scratch.take() {
            self.exits.borrow_mut().insert(pid, path);
        }
        let channel = Rc::new(RefCell::new(channel));
        self.key = format!("side:{pid}");
        self.channels
            .borrow_mut()
            .insert(self.key.clone(), channel.clone());
        self.channel = Some(channel);
        self.request(
            pending,
            io,
            Stage::Child,
            "process",
            Data::Object(vec![("pid", Data::Unsigned(pid.into()))]),
        );
        Ok(())
    }

    /// `thread/fork` on the parent's provider and model.
    fn fork(&mut self, pending: &Rc<RefCell<Self>>, io: &mut dyn Io) -> Result<(), Error> {
        let configuration = self.configuration.as_ref().unwrap().root();
        let pinned = self.pinned.as_ref().unwrap();
        let params = side::fork(&self.parent.session, configuration, self.read_only, pinned)?;
        let params = Json::parse(&params)?;
        self.request(pending, io, Stage::Fork, "thread/fork", Data::Value(params.root()));
        Ok(())
    }

    /// The parent's configuration names variables the side agent was not given: a side agent
    /// with them replaces it (in the same private directory), unless the parent has none of them.
    fn respawn(pending: Rc<RefCell<Self>>, io: &mut dyn Io, result: Result<Prepared, Error>) {
        let mut open = pending.borrow_mut();
        if open.done.is_none() {
            // Closed meanwhile.
            return;
        }
        let result = result.and_then(|prepared| {
            let (command, _, variables) = launchable(prepared.command, open.read_only);
            if variables <= open.variables {
                return open.fork(&pending, io);
            }
            let previous = open.channel.take().unwrap();
            let pid = previous.borrow().pid;
            let key = std::mem::take(&mut open.key);
            open.channels.borrow_mut().remove(&key);
            let scratch = open.exits.borrow_mut().remove(&pid);
            open.scratch = scratch;
            let _ = previous
                .borrow_mut()
                .close(io, failure("side", "Replaced by a side agent with the parent's credentials."));
            open.variables = variables;
            open.spawn(&pending, io, command)
        });
        if let Err(error) = result {
            open.finish(io, Err(error));
        }
    }

    fn advance(pending: Rc<RefCell<Self>>, io: &mut dyn Io, result: Result<Json, Error>) {
        let mut open = pending.borrow_mut();
        let result = result.and_then(|document| open.step(&pending, io, document));
        if let Err(error) = result {
            open.finish(io, Err(error));
        }
    }

    fn step(
        &mut self,
        pending: &Rc<RefCell<Self>>,
        io: &mut dyn Io,
        document: Json,
    ) -> Result<(), Error> {
        let root = document.root();
        match self.stage {
            // Answered by a native job: Open::child.
            Stage::Child => return Err(failure("process", "Side process facts arrived as a codex reply")),
            // A side agent started again with the parent's further variables forks at once.
            Stage::Initialize if self.pinned.is_some() => self.fork(pending, io)?,
            Stage::Initialize => {
                let cwd = self.cwd.to_string_lossy().into_owned();
                self.request(
                    pending,
                    io,
                    Stage::Configuration,
                    "config/read",
                    Data::Object(vec![("cwd", Data::String(&cwd))]),
                );
            }
            Stage::Configuration => {
                let configuration = match root.get("config") {
                    Some(config) => Json::parse(&config.write()?)?,
                    None => Json::parse(b"{}")?,
                };
                self.configuration = Some(configuration);
                let session = self.parent.session.clone();
                self.request(
                    pending,
                    io,
                    Stage::Thread,
                    "thread/read",
                    Data::Object(vec![
                        ("threadId", Data::String(&session)),
                        ("includeTurns", Data::Bool(false)),
                    ]),
                );
            }
            Stage::Thread => {
                let pinned = side::pinned(root)?;
                let configuration = self.configuration.as_ref().unwrap().root();
                let referenced =
                    side::referenced(configuration, &pinned.provider, self.read_only, &self.declared);
                self.pinned = Some(pinned);
                let further: Vec<String> = referenced
                    .into_iter()
                    .filter(|name| {
                        !side::ENVIRONMENT.contains(&name.as_str()) && !self.names.contains(name)
                    })
                    .collect();
                if further.is_empty() {
                    return self.fork(pending, io);
                }
                self.names.extend(further);
                self.stage = Stage::Environment;
                let next = pending.clone();
                environment(
                    self.jobs.clone(),
                    io,
                    self.parent.clone(),
                    self.cwd.clone(),
                    None,
                    self.names.clone(),
                    Box::new(move |io, result| Self::respawn(next, io, result)),
                );
            }
            Stage::Environment => {
                return Err(failure("side", "The parent's environment arrived as a codex reply"));
            }
            Stage::Fork => {
                let thread = root
                    .get("thread")
                    .ok_or_else(|| failure("side", "Side conversation unavailable"))?;
                let id = thread
                    .get("id")
                    .and_then(Value::string)
                    .filter(|id| *id != self.parent.session)
                    .ok_or_else(|| failure("side", "Side conversation unavailable"))?;
                if thread.get("ephemeral").and_then(Value::boolean) != Some(true) {
                    return Err(failure("side", "Ephemeral side conversation not confirmed"));
                }
                side::confirmed(root, self.pinned.as_ref().unwrap())?;
                if self.read_only
                    && (root
                        .get("sandbox")
                        .and_then(|value| value.get("type"))
                        .and_then(Value::string)
                        != Some("readOnly")
                        || root.get("approvalPolicy").and_then(Value::string) != Some("never"))
                {
                    return Err(failure("side", "Read-only permissions not confirmed"));
                }
                let channel = self.channel.as_ref().unwrap();
                {
                    let mut channel = channel.borrow_mut();
                    channel.binding.session = id.into();
                    channel.binding.transcript = None;
                }
                let question = self.question.trim().to_owned();
                if question.is_empty() || question.len() > 1_048_576 {
                    let binding = channel.borrow().binding.clone();
                    self.finish(io, Ok(binding));
                } else {
                    let mut params = vec![
                        ("threadId", Data::String(id)),
                        (
                            "input",
                            Data::Array(vec![Data::Object(vec![
                                ("type", Data::String("text")),
                                ("text", Data::String(&question)),
                            ])]),
                        ),
                    ];
                    if self.read_only {
                        params.extend(side::permissions());
                    }
                    self.request(pending, io, Stage::Send, "turn/start", Data::Object(params));
                }
            }
            Stage::Send => {
                let binding = self.channel.as_ref().unwrap().borrow().binding.clone();
                self.finish(io, Ok(binding));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "owned.test.rs"]
mod tests;
