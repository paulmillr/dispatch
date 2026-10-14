use super::*;
use dispatch_helper_core::wire::body::Encoded;
use std::collections::VecDeque;
#[derive(Clone, Copy)]
enum Stage {
    Process,
    Environment,
    Directory,
    List,
    File,
    Parent,
    Socket,
    Connect,
    Peer,
    Verify,
    Alive,
}
pub(super) struct Find {
    stage: Stage,
    process: Process,
    birth: f64,
    path: PathBuf,
    file: PathBuf,
    files: VecDeque<PathBuf>,
    record: Option<Json>,
    fd: Option<RawFd>,
    pub done: Done<Option<Binding>>,
}
/// A native process answer names `p`, owned by `uid`.
fn same(v: &Data<'_>, p: &Process, uid: u32) -> bool {
    v.get("pid").and_then(Data::unsigned) == Some(p.pid.into())
        && v.get("uid").and_then(Data::unsigned) == Some(uid.into())
        && v.get("executable").and_then(Data::path) == Some(p.executable.as_path())
        && v.get("start")
            .and_then(Data::array)
            .map(|a| a.filter_map(Data::unsigned).collect::<Vec<_>>())
            == Some(p.start.to_vec())
}
/// A native metadata answer: this kind, owned by `uid`, private.
pub(crate) fn private(v: &Data<'_>, uid: u32, kind: &str) -> bool {
    v.get("kind").and_then(Data::string) == Some(kind)
        && v.get("uid").and_then(Data::unsigned) == Some(uid.into())
        && v.get("mode")
            .and_then(Data::unsigned)
            .is_some_and(|m| m & 0o077 == 0)
}
fn uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn process(p: &Process) -> Result<Job, Error> {
    native("process", vec![("pid", Data::Unsigned(p.pid.into()))])
}
fn path(name: &'static str, p: &Path) -> Result<Job, Error> {
    native(name, vec![("path", Data::from(p))])
}

impl Nano {
    pub(super) fn identify(&mut self, io: &mut dyn Io, p: Process, done: Done<Option<Binding>>) {
        if !self.matches(&p) {
            done(io, Ok(None));
            return;
        }
        if let Some(c) = self.channels.get(&p.pid).filter(|c| {
            c.binding.process.start == p.start
                && c.binding.process.executable == p.executable
                && c.snapshot.as_ref().is_some_and(|s| {
                    c.conversations
                        .contains_key(string(s.root(), "active_session_id"))
                        || c.waits.iter().any(|w| w.transition)
                })
        }) {
            done(io, Ok(Some(c.binding.clone())));
            return;
        }
        let job = process(&p);
        let find = Find {
            stage: Stage::Process,
            process: p,
            birth: 0.0,
            path: PathBuf::new(),
            file: PathBuf::new(),
            files: VecDeque::new(),
            record: None,
            fd: None,
            done,
        };
        self.submit(io, find, job);
    }
    fn submit(&mut self, io: &mut dyn Io, find: Find, job: Result<Job, Error>) {
        match job {
            Ok(job) => self.job(
                io,
                job,
                Box::new(move |this, io, result| this.scan(io, find, result)),
            ),
            Err(e) => (find.done)(io, Err(e)),
        }
    }
    pub(super) fn scan(&mut self, io: &mut dyn Io, mut f: Find, output: Result<Output, Error>) {
        if matches!(f.stage, Stage::List) {
            f.files = match output {
                Ok(Output::List(names)) => {
                    let names = if self.remote {
                        names
                            .into_iter()
                            .filter(|(n, _)| n.ends_with(".json"))
                            .take(4096)
                            .collect::<Vec<_>>()
                    } else {
                        names
                            .into_iter()
                            .take(256)
                            .filter(|(n, _)| n.ends_with(".json"))
                            .collect()
                    };
                    names
                        .into_iter()
                        .map(|(name, _)| f.path.join(name))
                        .collect()
                }
                _ => {
                    (f.done)(io, Ok(None));
                    return;
                }
            };
            self.candidate(io, f);
            return;
        }
        if matches!(f.stage, Stage::Connect) {
            let fd = f.fd.unwrap();
            if let Err(e) = io.interest(fd, false, false) {
                io.close(fd);
                (f.done)(io, Err(error("io", e.to_string())));
                return;
            }
            f.stage = Stage::Peer;
            let job = native("peer", vec![("fd", Data::Signed(f.fd.unwrap().into()))]);
            self.submit(io, f, job);
            return;
        }
        let doc = output.and_then(|o| match o {
            Output::Value(b) => Encoded::plain(&b),
            _ => Err(error(
                "protocol",
                "Nanocodex returned invalid native facts.",
            )),
        });
        let doc = match doc {
            Ok(d) => d,
            Err(e) => {
                if matches!(f.stage, Stage::File) {
                    self.candidate(io, f);
                } else {
                    if let Some(fd) = f.fd {
                        io.close(fd);
                    }
                    (f.done)(io, Err(e));
                }
                return;
            }
        };
        let v = &doc.root();
        let job = match f.stage {
            Stage::Process => {
                if !same(v, &f.process, self.uid) {
                    (f.done)(io, Ok(None));
                    return;
                }
                let Some(birth) = v.get("started_at").and_then(Data::number) else {
                    (f.done)(io, Ok(None));
                    return;
                };
                // Old pi::birth subtracts Linux's one-second epoch uncertainty;
                // nanocodex::decode then allows a further second for registration.
                f.birth = birth
                    - if self.remote && v.get("pid_domain").and_then(Data::string).unwrap_or("").starts_with("linux:") {
                        1.0
                    } else {
                        0.0
                    };
                f.stage = Stage::Environment;
                native(
                    "environment",
                    vec![
                        ("pid", Data::Unsigned(f.process.pid.into())),
                        (
                            "start",
                            Data::Array(
                                f.process
                                    .start
                                    .iter()
                                    .copied()
                                    .map(Data::Unsigned)
                                    .collect(),
                            ),
                        ),
                        ("executable", Data::from(f.process.executable.as_path())),
                        (
                            "names",
                            Data::Array(vec![Data::String("HOME"), Data::String("CODEX_HOME")]),
                        ),
                    ],
                )
            }
            Stage::Environment => {
                // Environment values are bytes, here paths.
                let variable = |name| v.get(name).and_then(Data::path).unwrap_or(Path::new(""));
                let (codex, home) = (variable("CODEX_HOME"), variable("HOME"));
                let base = if !codex.as_os_str().is_empty() && (self.remote || codex.is_absolute()) {
                    codex.to_path_buf()
                } else {
                    if home.as_os_str().is_empty() {
                        self.home.clone()
                    } else {
                        home.to_path_buf()
                    }
                    .join(".codex")
                };
                if !base.is_absolute() {
                    (f.done)(io, Ok(None));
                    return;
                }
                f.path = base.join("nanocodex/tui/instances");
                f.stage = Stage::Directory;
                path("file.lstat", &f.path)
            }
            Stage::Directory => {
                if !private(v, self.uid, "directory") {
                    (f.done)(io, Ok(None));
                    return;
                }
                f.stage = Stage::List;
                Ok(Job::List {
                    path: f.path.clone(),
                })
            }
            Stage::File | Stage::Verify => {
                let record = (|| -> Option<Json> {
                    let before = v.get("before")?;
                    let after = v.get("after")?;
                    let bytes = v.get("data")?.bytes()?;
                    if bytes.len() > 16384 || !private(before, self.uid, "file") {
                        return None;
                    }
                    if self.remote
                        && (before.get("links")?.unsigned()? > 1
                            || before.get("size")?.unsigned()? != bytes.len() as u64
                            || before.get("size")?.unsigned()? != after.get("size")?.unsigned()?
                            || before.get("mtime_ns")?.signed()?
                                != after.get("mtime_ns")?.signed()?)
                    {
                        return None;
                    }
                    let d = Json::parse(bytes).ok()?;
                    if !valid(d.root(), &f.process, f.birth, self.remote) {
                        return None;
                    }
                    Some(d)
                })();
                let Some(record) = record else {
                    if matches!(f.stage, Stage::Verify) {
                        io.close(f.fd.unwrap());
                        (f.done)(io, Ok(None));
                        return;
                    }
                    self.candidate(io, f);
                    return;
                };
                if matches!(f.stage, Stage::Verify) {
                    let before = f.record.as_ref().unwrap().root();
                    let after = record.root();
                    if ["active_session_id", "auth_token", "socket_path"]
                        .iter()
                        .any(|key| string(before, key) != string(after, key))
                    {
                        io.close(f.fd.unwrap());
                        (f.done)(io, Ok(None));
                        return;
                    }
                    f.stage = Stage::Alive;
                    let job = process(&f.process);
                    self.submit(io, f, job);
                    return;
                }
                f.path = string(record.root(), "socket_path").into();
                f.record = Some(record);
                if self.remote {
                    f.stage = Stage::Parent;
                    path("file.lstat", f.path.parent().unwrap_or(Path::new("/")))
                } else {
                    f.stage = Stage::Socket;
                    path("file.lstat", &f.path)
                }
            }
            Stage::Parent => {
                if !private(v, self.uid, "directory") {
                    (f.done)(
                        io,
                        Err(error(
                            "not_sent",
                            "Nanocodex’s control socket is unavailable.",
                        )),
                    );
                    return;
                }
                f.stage = Stage::Socket;
                path("file.lstat", &f.path)
            }
            Stage::Socket => {
                if !private(v, self.uid, "socket") {
                    (f.done)(
                        io,
                        Err(error(
                            "not_sent",
                            "Nanocodex’s control socket is unavailable.",
                        )),
                    );
                    return;
                }
                let fd = match io.connect(&Address::Unix(f.path.clone())) {
                    Ok(fd) => fd,
                    Err(e) => {
                        (f.done)(io, Err(error("io", e.to_string())));
                        return;
                    }
                };
                f.fd = Some(fd);
                f.stage = Stage::Connect;
                if let Err(e) = io.interest(fd, false, true) {
                    io.close(fd);
                    (f.done)(io, Err(error("io", e.to_string())));
                    return;
                }
                let at = io.now() + Duration::from_secs(if self.remote { 2 } else { 5 });
                io.timer(at);
                self.connecting.insert(fd, (at, f));
                return;
            }
            Stage::Peer => {
                if v.get("uid").and_then(Data::unsigned) != Some(self.uid.into())
                    || v.get("pid").and_then(Data::unsigned) != Some(f.process.pid.into())
                {
                    io.close(f.fd.unwrap());
                    (f.done)(
                        io,
                        Err(error(
                            "not_sent",
                            "Nanocodex’s control socket belongs to a different process.",
                        )),
                    );
                    return;
                }
                f.stage = Stage::Verify;
                self.registration(&f.file)
            }
            Stage::Alive => {
                let fd = f.fd.unwrap();
                if !same(v, &f.process, self.uid) {
                    io.close(fd);
                    (f.done)(io, Ok(None));
                    return;
                }
                let r = f.record.as_ref().unwrap().root();
                let session = string(r, "active_session_id").to_owned();
                let transcript = transcript(r, self.remote);
                let auth = json::write(&Data::Object(vec![
                    ("protocol_version", Data::Unsigned(1)),
                    ("instance_id", Data::String(string(r, "instance_id"))),
                    ("auth_token", Data::String(string(r, "auth_token"))),
                ]));
                let mut auth = match auth {
                    Ok(v) => v,
                    Err(e) => {
                        io.close(fd);
                        (f.done)(io, Err(e));
                        return;
                    }
                };
                auth.push(b'\n');
                let pid = f.process.pid;
                self.closed(io, pid, "The Nanocodex conversation changed.".into());
                self.channels.insert(
                    pid,
                    control::Channel::new(
                        io,
                        fd,
                        Binding {
                            session,
                            transcript,
                            process: f.process,
                        },
                        string(r, "instance_id").into(),
                        f.done,
                        self.remote,
                    ),
                );
                if let Err(e) = self
                    .channels
                    .get_mut(&pid)
                    .unwrap()
                    .client
                    .stream
                    .send(io, auth, None, None)
                {
                    self.closed(io, pid, e.to_string());
                }
                return;
            }
            Stage::Connect | Stage::List => unreachable!(),
        };
        self.submit(io, f, job);
    }
    fn candidate(&mut self, io: &mut dyn Io, mut f: Find) {
        let Some(p) = f.files.pop_front() else {
            (f.done)(io, Ok(None));
            return;
        };
        f.stage = Stage::File;
        f.file = p;
        let job = self.registration(&f.file);
        self.submit(io, f, job);
    }
    fn registration(&self, path: &Path) -> Result<Job, Error> {
        native(
            "file.private",
            vec![
                ("path", Data::from(path)),
                (
                    "limit",
                    Data::Unsigned(if self.remote { 16384 } else { 65536 }),
                ),
            ],
        )
    }
}

pub(crate) fn valid(r: Value<'_>, process: &Process, birth: f64, remote: bool) -> bool {
    let Some(started) = r.get("started_at_unix_ms").and_then(Value::number) else {
        return false;
    };
    let started = started / 1000.0;
    if r.get("protocol_version").and_then(Value::unsigned) != Some(1)
        || r.get("pid").and_then(Value::unsigned) != Some(process.pid as u64)
        || !started.is_finite()
        || started < birth - 1.0
        || !uuid(string(r, "instance_id"))
        || !matches!(string(r, "backend"), "native" | "managed")
        || !string(r, "socket_path").starts_with('/')
        || string(r, "socket_path").len() >= 104
        || !(32..=256).contains(&string(r, "auth_token").len())
    {
        return false;
    }
    if !remote && string(r, "active_generation").parse::<u64>().is_err()
        || remote
            && !string(r, "active_session_id").is_empty()
            && !uuid(string(r, "active_session_id"))
    {
        return false;
    }
    true
}

pub(crate) fn transcript(r: Value<'_>, remote: bool) -> Option<PathBuf> {
    value(r, "conversation.rollout_path")
        .and_then(Value::string)
        .filter(|path| {
            path.starts_with('/')
                && (!remote || path.len() < 4096)
                && string(r, "conversation.session_id") == string(r, "active_session_id")
        })
        .map(PathBuf::from)
}
