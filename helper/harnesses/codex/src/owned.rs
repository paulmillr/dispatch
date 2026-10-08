//! The existing Codex side-sheet recipe, using shared native jobs and stdio.
use crate::{
    channel::{Channel, Channels, failure, initialize},
    jobs::{self, Jobs},
    side,
};
use dispatch_helper_core::{
    api::{Binding, Done, Error, Expected, Io, Job, deferred},
    json::{Data, Json, Value},
};
use std::{cell::RefCell, collections::BTreeMap, path::PathBuf, process::Command, rc::Rc};

/// Directories removed when their process exits (pid -> path); harness event handling.
pub type Exits = Rc<RefCell<BTreeMap<u32, PathBuf>>>;

enum Stage {
    Child,
    Initialize,
    Configuration,
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
    command(
        jobs,
        io,
        parent.clone(),
        Box::new(move |io, result| {
            let (mut command, cwd, scratch) = match result {
                Ok(value) => value,
                Err(error) => return deferred(done)(io, Err(error)),
            };
            if read_only {
                for feature in side::FEATURES {
                    command.args(["--disable", feature]);
                }
            }
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
/// core C-AGENT-DIR), and only the side variables of its environment (c51466a
/// agent_side.rs:72-84); `app-server --stdio` with that directory and the private directory to
/// remove when the spawned process exits.
#[allow(clippy::type_complexity)]
pub fn command(
    jobs: Jobs,
    io: &mut dyn Io,
    parent: Binding,
    done: Done<(Command, PathBuf, Option<PathBuf>)>,
) {
    let pid = Data::Object(vec![("pid", Data::Unsigned(parent.process.pid.into()))]);
    let next = jobs.clone();
    jobs::native(
        &jobs,
        io,
        "process",
        pid,
        Box::new(move |io, result| {
            let observed = match result.and_then(|document| {
                let cwd = document
                    .root()
                    .get("cwd")
                    .and_then(Value::string)
                    .map(PathBuf::from);
                Ok((jobs::process(document.root())?, cwd))
            }) {
                Ok(value) => value,
                Err(error) => return deferred(done)(io, Err(error)),
            };
            if !same(&observed.0, &parent) {
                return deferred(done)(io, Err(failure("process", "The parent agent exited")));
            }
            match observed.1.filter(|path| path.is_absolute()) {
                Some(cwd) => environment(next, io, parent, cwd, None, done),
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
                            Ok(_) => environment(after, io, parent, path.clone(), Some(path), done),
                            Err(error) => deferred(done)(io, Err(error)),
                        }),
                    );
                }
            }
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

/// The parent's side variables, then the parent once more: still the same process.
#[allow(clippy::type_complexity)]
fn environment(
    jobs: Jobs,
    io: &mut dyn Io,
    parent: Binding,
    cwd: PathBuf,
    scratch: Option<PathBuf>,
    done: Done<(Command, PathBuf, Option<PathBuf>)>,
) {
    let names = side::ENVIRONMENT.into_iter().map(Data::String).collect();
    let pid = parent.process.pid;
    let input = Data::Object(vec![
        ("pid", Data::Unsigned(pid.into())),
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
                    let observed = match result.and_then(|document| jobs::process(document.root()))
                    {
                        Ok(observed) if same(&observed, &parent) => observed,
                        Ok(_) => {
                            let error = failure("process", "The parent agent exited");
                            return fail(io, scratch, error, done);
                        }
                        Err(error) => return fail(io, scratch, error, done),
                    };
                    let mut command = match cfg!(target_os = "linux") {
                        true => Command::new(format!("/proc/{}/exe", observed.pid)),
                        false => Command::new(&observed.executable),
                    };
                    std::os::unix::process::CommandExt::arg0(&mut command, &observed.executable);
                    command
                        .args(["app-server", "--stdio"])
                        .current_dir(&cwd)
                        .env_clear();
                    let variables = environment.root().object().map(|values| {
                        values
                            .map(|(name, value)| {
                                Some((name.to_owned(), value.string()?.to_owned()))
                            })
                            .collect::<Option<Vec<_>>>()
                    });
                    let Some(Some(variables)) = variables else {
                        let error = failure("environment", "Invalid parent environment");
                        return fail(io, scratch, error, done);
                    };
                    command.envs(variables);
                    deferred(done)(io, Ok((command, cwd, scratch)));
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
        let done = Box::new(move |io: &mut dyn Io, result| Self::advance(pending, io, result));
        if native {
            jobs::native(&self.jobs, io, name, params, done);
        } else {
            self.channel
                .as_ref()
                .unwrap()
                .borrow_mut()
                .request(io, name, params, done);
        }
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
            Stage::Child => {
                let observed = jobs::process(root)?;
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
            }
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
                let empty = Json::parse(b"{}")?;
                let config = root.get("config").unwrap_or_else(|| empty.root());
                let params =
                    Json::parse(&side::fork(&self.parent.session, config, self.read_only)?)?;
                self.request(
                    pending,
                    io,
                    Stage::Fork,
                    "thread/fork",
                    Data::Value(params.root()),
                );
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
