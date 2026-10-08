//! Native endpoint admission; filesystem and credentials are observed by core System.
use crate::mux::{Continue, Tmux, allocate, error};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Value},
};
use std::{
    collections::VecDeque,
    io,
    os::fd::RawFd,
    path::PathBuf,
    time::{Duration, Instant},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Endpoint {
    pub path: PathBuf,
    private: bool,
    uid: u64,
    directory: [u64; 2],
    socket: [u64; 2],
    pub pid: u32,
    start: [u64; 2],
    pub executable: PathBuf,
}

impl Endpoint {
    pub(crate) fn identity(&self) -> String {
        // Socket spellings and admission policy do not change the verified server they reach.
        format!("server:{}:{}:{:?}:{:?}", self.uid, self.pid, self.start, self.socket)
    }

    pub(crate) fn key(&self, namespace: &str) -> String {
        let pair =
            |values: &[u64; 2]| Data::Array(values.iter().map(|v| Data::Unsigned(*v)).collect());
        let body = json::write(&Data::Object(vec![
            ("key", Data::String(namespace)),
            (
                "path",
                Data::String(self.path.to_str().expect("validated endpoint path")),
            ),
            ("private", Data::Bool(self.private)),
            ("uid", Data::Unsigned(self.uid)),
            ("directory", pair(&self.directory)),
            ("socket", pair(&self.socket)),
            ("pid", Data::Unsigned(self.pid.into())),
            ("start", pair(&self.start)),
            (
                "executable",
                Data::String(self.executable.to_str().expect("validated executable")),
            ),
        ]))
        .expect("typed endpoint");
        format!("tmux-reopen:{}", String::from_utf8(body).expect("JSON"))
    }

    pub(crate) fn parse(key: &str) -> io::Result<Option<(String, Self)>> {
        let Some(body) = key.strip_prefix("tmux-reopen:") else {
            return Ok(None);
        };
        let document = Json::parse(body.as_bytes()).map_err(|_| io::ErrorKind::InvalidData)?;
        let root = document.root();
        let text = |key| {
            root.get(key)
                .and_then(Value::string)
                .ok_or(io::ErrorKind::InvalidData)
        };
        let pair = |key| -> io::Result<[u64; 2]> {
            root.get(key)
                .and_then(Value::array)
                .ok_or(io::ErrorKind::InvalidData)?
                .map(Value::unsigned)
                .collect::<Option<Vec<_>>>()
                .ok_or(io::ErrorKind::InvalidData)?
                .try_into()
                .map_err(|_| io::ErrorKind::InvalidData.into())
        };
        Ok(Some((
            text("key")?.into(),
            Self {
                path: text("path")?.into(),
                private: root
                    .get("private")
                    .and_then(Value::boolean)
                    .ok_or(io::ErrorKind::InvalidData)?,
                uid: number(root, "uid")?,
                directory: pair("directory")?,
                socket: pair("socket")?,
                pid: number(root, "pid")?
                    .try_into()
                    .map_err(|_| io::ErrorKind::InvalidData)?,
                start: pair("start")?,
                executable: text("executable")?.into(),
            },
        )))
    }
}

#[derive(Clone, Copy)]
enum Step {
    Account,
    Environment,
    Parent,
    Follow,
    Socket,
    Connect,
    Peer,
    Server,
}

pub(crate) struct Check {
    key: String,
    expected: Option<Endpoint>,
    server: Option<u32>,
    directory: Option<[u64; 2]>,
    socket: Option<[u64; 2]>,
    endpoint: Endpoint,
    steps: VecDeque<Step>,
    step: Option<Step>,
    fd: Option<RawFd>,
    work: Option<Work>,
    at: Instant,
    done: Continue<Result<Endpoint, Error>>,
}

fn number(value: Value<'_>, key: &str) -> io::Result<u64> {
    value
        .get(key)
        .and_then(Value::unsigned)
        .ok_or_else(|| io::ErrorKind::InvalidData.into())
}
fn identity(value: Value<'_>) -> io::Result<[u64; 2]> {
    Ok([number(value, "device")?, number(value, "inode")?])
}

impl Check {
    fn facts(&mut self, output: Output) -> io::Result<()> {
        let step = self.step.take().unwrap();
        if matches!(step, Step::Follow) {
            let Output::Metadata(metadata) = output else {
                return Err(io::ErrorKind::InvalidData.into());
            };
            if metadata.kind != FileKind::Directory {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            return self.directory([metadata.device, metadata.inode]);
        }
        let Output::Bytes(bytes) = output else {
            return Err(io::ErrorKind::InvalidData.into());
        };
        let json = Json::parse(&bytes).map_err(|error| io::Error::other(error.message))?;
        let root = json.root();
        match step {
            Step::Account => {
                self.endpoint.uid = number(root, "uid")?;
                if let Some(expected) = &self.expected {
                    self.endpoint.path = expected.path.clone();
                    self.endpoint.private = expected.private;
                } else if self.key == "tmux" {
                    self.endpoint.private = true;
                    self.steps.push_front(Step::Environment);
                } else {
                    let path = PathBuf::from(&self.key);
                    self.endpoint.path = if path.is_absolute() {
                        path
                    } else {
                        PathBuf::from(
                            root.get("cwd")
                                .and_then(Value::string)
                                .ok_or(io::ErrorKind::InvalidData)?,
                        )
                        .join(path)
                    };
                }
            }
            Step::Environment => {
                let root = root
                    .get("TMUX_TMPDIR")
                    .and_then(Value::string)
                    .unwrap_or("/tmp");
                let path = PathBuf::from(root);
                if !path.is_absolute() {
                    return Err(io::ErrorKind::InvalidInput.into());
                }
                self.endpoint.path = path
                    .join(format!("tmux-{}", self.endpoint.uid))
                    .join("default");
            }
            Step::Parent => {
                let kind = root
                    .get("kind")
                    .and_then(Value::string)
                    .ok_or(io::ErrorKind::InvalidData)?;
                if kind == "symlink" && !self.endpoint.private {
                    self.steps.push_front(Step::Follow);
                    return Ok(());
                }
                if kind != "directory"
                    || self.endpoint.private
                        && (number(root, "uid")? != self.endpoint.uid
                            || number(root, "mode")? & 0o077 != 0)
                {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
                self.directory(identity(root)?)?;
            }
            Step::Socket => {
                if root.get("kind").and_then(Value::string) != Some("socket")
                    || number(root, "uid")? != self.endpoint.uid
                {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
                let socket = identity(root)?;
                if self.socket.is_some_and(|previous| previous != socket) {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
                self.socket = Some(socket);
                self.endpoint.socket = socket;
            }
            Step::Peer => {
                if number(root, "uid")? != self.endpoint.uid {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
                let pid = number(root, "pid")?
                    .try_into()
                    .map_err(|_| io::ErrorKind::InvalidData)?;
                if pid <= 1
                    || self.server.is_some_and(|server| server != pid)
                    || self.endpoint.pid != 0 && self.endpoint.pid != pid
                {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
                self.endpoint.pid = pid;
            }
            Step::Server => {
                if number(root, "pid")? != u64::from(self.endpoint.pid)
                    || number(root, "uid")? != self.endpoint.uid
                {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
                let executable = PathBuf::from(
                    root.get("executable")
                        .and_then(Value::string)
                        .ok_or(io::ErrorKind::InvalidData)?,
                );
                if !executable.is_absolute()
                    || executable.file_name() != Some(std::ffi::OsStr::new("tmux"))
                {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
                let start: [u64; 2] = root
                    .get("start")
                    .and_then(Value::array)
                    .ok_or(io::ErrorKind::InvalidData)?
                    .map(Value::unsigned)
                    .collect::<Option<Vec<_>>>()
                    .ok_or(io::ErrorKind::InvalidData)?
                    .try_into()
                    .map_err(|_| io::ErrorKind::InvalidData)?;
                if !self.endpoint.executable.as_os_str().is_empty()
                    && (self.endpoint.executable != executable || self.endpoint.start != start)
                {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
                self.endpoint.executable = executable;
                self.endpoint.start = start;
            }
            Step::Follow | Step::Connect => unreachable!(),
        }
        Ok(())
    }
    fn directory(&mut self, identity: [u64; 2]) -> io::Result<()> {
        if self.directory.is_some_and(|previous| previous != identity) {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        self.directory = Some(identity);
        self.endpoint.directory = identity;
        Ok(())
    }
    fn next(&mut self, io: &mut dyn Io) -> io::Result<bool> {
        if io.now() >= self.at {
            return Err(io::ErrorKind::TimedOut.into());
        }
        let Some(step) = self.steps.pop_front() else {
            if self
                .expected
                .as_ref()
                .is_some_and(|expected| expected != &self.endpoint)
            {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            return Ok(true);
        };
        self.step = Some(step);
        if matches!(step, Step::Connect) {
            let fd = io.connect(&Address::Unix(self.endpoint.path.clone()))?;
            self.fd = Some(fd);
            io.interest(fd, false, true)?;
            return Ok(false);
        }
        let parent = self
            .endpoint
            .path
            .parent()
            .ok_or(io::ErrorKind::InvalidInput)?
            .to_path_buf();
        let job = match step {
            Step::Follow => Job::Stat {
                path: parent,
                follow: true,
            },
            _ => {
                let (name, input) = match step {
                    Step::Account => (
                        "process",
                        Data::Object(vec![("pid", Data::Unsigned(io.pid().into()))]),
                    ),
                    Step::Environment => (
                        "environment",
                        Data::Object(vec![
                            ("pid", Data::Unsigned(io.pid().into())),
                            ("names", Data::Array(vec![Data::String("TMUX_TMPDIR")])),
                        ]),
                    ),
                    Step::Parent => (
                        "file.lstat",
                        Data::Object(vec![(
                            "path",
                            Data::String(parent.to_str().ok_or(io::ErrorKind::InvalidInput)?),
                        )]),
                    ),
                    Step::Socket => (
                        "file.lstat",
                        Data::Object(vec![(
                            "path",
                            Data::String(
                                self.endpoint
                                    .path
                                    .to_str()
                                    .ok_or(io::ErrorKind::InvalidInput)?,
                            ),
                        )]),
                    ),
                    Step::Peer => (
                        "peer",
                        Data::Object(vec![("fd", Data::Signed(self.fd.unwrap().into()))]),
                    ),
                    Step::Server => (
                        "process",
                        Data::Object(vec![("pid", Data::Unsigned(self.endpoint.pid.into()))]),
                    ),
                    _ => unreachable!(),
                };
                Job::Native {
                    name,
                    input: json::write(&input).map_err(|error| io::Error::other(error.message))?,
                }
            }
        };
        self.work = Some(io.submit(job)?);
        Ok(false)
    }
    fn finish(mut self, mux: &mut Tmux, io: &mut dyn Io, result: io::Result<bool>) {
        if let Some(work) = self.work.take() {
            io.cancel(work);
        }
        if let Some(fd) = self.fd.take() {
            io.close(fd);
        }
        (self.done)(mux, io, result.map(|_| self.endpoint).map_err(error));
    }
}

impl Tmux {
    pub(crate) fn endpoint(
        &mut self,
        io: &mut dyn Io,
        key: String,
        expected: Option<Endpoint>,
        server: Option<u32>,
        done: Continue<Result<Endpoint, Error>>,
    ) {
        if key.is_empty() || key.len() > 4096 || key.starts_with('@') || key.contains('\0') {
            done(self, io, Err(error(io::ErrorKind::InvalidInput)));
            return;
        }
        let at = io.now() + Duration::from_secs(2);
        let mut check = Check {
            key,
            expected,
            server,
            directory: None,
            socket: None,
            endpoint: Endpoint {
                path: PathBuf::from("."),
                private: false,
                uid: 0,
                directory: [0; 2],
                socket: [0; 2],
                pid: 0,
                start: [0; 2],
                executable: PathBuf::new(),
            },
            steps: [
                Step::Account,
                Step::Parent,
                Step::Socket,
                Step::Connect,
                Step::Peer,
                Step::Server,
                Step::Parent,
                Step::Socket,
                Step::Peer,
                Step::Server,
            ]
            .into(),
            step: None,
            fd: None,
            work: None,
            at,
            done,
        };
        match check.next(io) {
            Ok(false) => {
                io.timer(at);
                self.checks.insert(allocate(&mut self.next), check);
            }
            result => check.finish(self, io, result),
        }
    }
    pub(crate) fn endpoints(&mut self, io: &mut dyn Io, event: Event) -> Option<Event> {
        let id = self.checks.iter().find_map(|(id, check)| match &event {
            Event::Done { work, .. } if check.work == Some(*work) => Some(*id),
            Event::Ready {
                fd, write: true, ..
            } if check.fd == Some(*fd) && matches!(check.step, Some(Step::Connect)) => Some(*id),
            _ => None,
        });
        if let Some(id) = id {
            let mut check = self.checks.remove(&id).unwrap();
            let result = match event {
                Event::Done { result, .. } => {
                    check.work = None;
                    result.and_then(|output| check.facts(output))
                }
                Event::Ready { fd, .. } => {
                    io.connected(fd).and_then(|_| io.interest(fd, false, false))
                }
                _ => unreachable!(),
            }
            .and_then(|_| check.next(io));
            match result {
                Ok(false) => {
                    self.checks.insert(id, check);
                }
                result => check.finish(self, io, result),
            }
            return None;
        }
        if let Event::Timer { at } = &event {
            let expired: Vec<_> = self
                .checks
                .iter()
                .filter_map(|(id, check)| (check.at <= *at).then_some(*id))
                .collect();
            for id in expired {
                self.checks.remove(&id).unwrap().finish(
                    self,
                    io,
                    Err(io::ErrorKind::TimedOut.into()),
                );
            }
        }
        Some(event)
    }
}
