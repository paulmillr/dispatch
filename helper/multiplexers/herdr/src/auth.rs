use super::*;

#[derive(Clone)]
pub(super) struct Endpoint {
    pub(super) path: PathBuf,
    pub(super) device: u64,
    pub(super) inode: u64,
    pub(super) server: Process,
}

impl Endpoint {
    pub(super) fn same(&self, other: &Self) -> bool {
        self.matches((other.device, other.inode)) && process::same(&self.server, &other.server)
    }
    pub(super) fn matches(&self, socket: (u64, u64)) -> bool {
        (self.device, self.inode) == socket
    }
}

pub(super) struct Scope {
    path: PathBuf,
    executable: PathBuf,
    uid: u32,
    owner: Option<Endpoint>,
}
impl Scope {
    pub(super) fn native(path: PathBuf, executable: PathBuf, uid: u32) -> Self {
        Self {
            path,
            executable,
            uid,
            owner: None,
        }
    }
    pub(super) fn endpoint(owner: &Endpoint, uid: u32) -> Self {
        Self {
            path: owner.path.clone(),
            executable: owner.server.executable.clone(),
            uid,
            owner: Some(owner.clone()),
        }
    }
    pub(super) fn new(config: &Config, owner: Option<Endpoint>) -> Self {
        Self {
            path: config.socket.clone(),
            executable: config.executable.clone(),
            uid: config.uid,
            owner,
        }
    }
}
type Verified = Box<dyn FnOnce(&mut Herdr, &mut dyn Io, Result<(Endpoint, Json), Error>)>;

pub(super) fn document(result: io::Result<Output>) -> Result<Json, Error> {
    match result {
        Ok(Output::Bytes(bytes)) => Json::parse(&bytes),
        Ok(_) => Err(error("Herdr endpoint identity is unavailable.")),
        Err(e) => {
            let mut reason = error(e.to_string());
            reason.code = match e.kind() {
                io::ErrorKind::NotFound => "not_found",
                io::ErrorKind::ConnectionRefused => "connection_refused",
                _ => "endpoint",
            };
            Err(reason)
        }
    }
}

pub(super) fn socket(value: Value<'_>, uid: u32) -> Result<(u64, u64), Error> {
    if value.get("kind").and_then(Value::string) != Some("socket")
        || value.get("uid").and_then(Value::unsigned) != Some(uid.into())
    {
        return Err(error("Herdr socket identity changed."));
    }
    let device = field(value, "device")?
        .unsigned()
        .ok_or_else(|| error("Herdr socket identity is unavailable."))?;
    let inode = field(value, "inode")?
        .unsigned()
        .ok_or_else(|| error("Herdr socket identity is unavailable."))?;
    Ok((device, inode))
}

impl Herdr {
    pub(super) fn retire(&mut self, io: &mut dyn Io, owner: &Endpoint) {
        if !self.owner.as_ref().is_some_and(|current| current.same(owner))
            || (self.snapshot == Snapshot::default() && self.controllers.is_empty())
        {
            return;
        }
        for terminal in self.controllers.keys().copied().collect::<Vec<_>>() {
            self.finish(io, terminal, None);
        }
        if let Some(stream) = self.subscription.take() {
            stream.close(io);
        }
        self.snapshot = Snapshot::default();
        self.selection = [None, None, None];
        self.agents.clear();
        self.origins.clear();
        self.ttys.clear();
        self.retry = None;
        self.safety = None;
        self.topology();
    }

    pub(super) fn recoverable(
        &mut self,
        io: &mut dyn Io,
        mut paths: VecDeque<PathBuf>,
        done: Action,
    ) {
        let Some(path) = paths.pop_front() else {
            done(self, io, Json::parse(b"{}"));
            return;
        };
        let input = json::write(&D::Object(vec![(
            "path",
            D::String(&path.to_string_lossy()),
        )]))
        .unwrap();
        self.job(
            io,
            Job::Native {
                name: "file.lstat",
                input,
            },
            Box::new(move |mux, io, result| {
                if matches!(result, Err(ref e) if e.kind() == io::ErrorKind::NotFound) {
                    mux.recoverable(io, paths, done);
                    return;
                }
                let before = document(result).and_then(|json| socket(json.root(), mux.config.uid));
                let before = match before {
                    Ok(value) => value,
                    Err(reason) => {
                        done(mux, io, Err(reason));
                        return;
                    }
                };
                match io.connect(&Address::Unix(path.clone())) {
                    Ok(fd) => {
                        io.close(fd);
                        done(mux, io, Err(error("Herdr endpoint is already in use.")));
                        return;
                    }
                    Err(e) if e.kind() == io::ErrorKind::ConnectionRefused => {}
                    Err(e) => {
                        done(mux, io, Err(error(e.to_string())));
                        return;
                    }
                }
                let input = json::write(&D::Object(vec![(
                    "path",
                    D::String(&path.to_string_lossy()),
                )]))
                .unwrap();
                mux.job(
                    io,
                    Job::Native {
                        name: "file.lstat",
                        input,
                    },
                    Box::new(move |mux, io, result| {
                        match document(result).and_then(|json| socket(json.root(), mux.config.uid))
                        {
                            Ok(after) if after == before => mux.recoverable(io, paths, done),
                            _ => done(mux, io, Err(error("Herdr socket changed during startup."))),
                        }
                    }),
                );
            }),
        );
    }
    /// Native jobs supply no-follow metadata and process birth; no socket bytes
    /// are sent until the observed endpoint matches this registration.
    pub(super) fn authenticate(&mut self, io: &mut dyn Io, fd: Option<i32>, done: Action) {
        let generation = self.generation;
        let scope = Scope::new(&self.config, self.owner.clone());
        self.verify(
            io,
            fd,
            scope,
            Box::new(move |mux, io, result| {
                let result = result.and_then(|(owner, facts)| {
                    if mux.generation != generation {
                        return Err(error("Herdr registration changed."));
                    }
                    mux.owner = Some(owner);
                    Ok(facts)
                });
                done(mux, io, result);
            }),
        );
    }
    pub(super) fn verify(
        &mut self,
        io: &mut dyn Io,
        fd: Option<i32>,
        scope: Scope,
        done: Verified,
    ) {
        let path = scope.path.to_string_lossy().into_owned();
        let input = json::write(&D::Object(vec![("path", D::String(&path))])).unwrap();
        self.job(
            io,
            Job::Native {
                name: "file.lstat",
                input,
            },
            Box::new(move |mux, io, result| {
                let before = document(result).and_then(|json| socket(json.root(), scope.uid));
                let before = match before {
                    Ok(value) => value,
                    Err(reason) => {
                        done(mux, io, Err(reason));
                        return;
                    }
                };
                if scope
                    .owner
                    .as_ref()
                    .is_some_and(|owner| !owner.matches(before))
                {
                    mux.retire(io, scope.owner.as_ref().unwrap());
                    done(mux, io, Err(error("Herdr socket changed.")));
                    return;
                }
                let fallback = scope.owner.clone();
                let uid = scope.uid;
                let verify: Action = Box::new(move |mux, io, result| {
                    let pid = result.and_then(|json| {
                        if json.root().get("uid").and_then(Value::unsigned)
                            != Some(scope.uid.into())
                        {
                            return Err(error("Herdr socket belongs to another user."));
                        }
                        field(json.root(), "pid")?
                            .unsigned()
                            .and_then(|pid| u32::try_from(pid).ok())
                            .ok_or_else(|| error("Herdr server identity is unavailable."))
                    });
                    let pid = match pid {
                        Ok(pid) => pid,
                        Err(reason) => {
                            done(mux, io, Err(reason));
                            return;
                        }
                    };
                    let input =
                        json::write(&D::Object(vec![("pid", D::Unsigned(pid.into()))])).unwrap();
                    mux.job(
                        io,
                        Job::Native {
                            name: "process",
                            input,
                        },
                        Box::new(move |mux, io, result| {
                            let result = document(result).and_then(|json| {
                                let server = process::read(json.root())?;
                                let named = server.executable.file_name()
                                    == Some(std::ffi::OsStr::new("herdr"))
                                    || server.executable == scope.executable;
                                if json.root().get("uid").and_then(Value::unsigned)
                                    != Some(scope.uid.into())
                                    || !named
                                    || server.pid != pid
                                    || server.arguments.len() != 2
                                    || server.arguments[1] != "server"
                                    || scope
                                        .owner
                                        .as_ref()
                                        .is_some_and(|owner| !process::same(&owner.server, &server))
                                {
                                    return Err(error("Herdr server changed."));
                                }
                                Ok((server, json))
                            });
                            let (server, facts) = match result {
                                Ok(value) => value,
                                Err(reason) => {
                                    done(mux, io, Err(reason));
                                    return;
                                }
                            };
                            let path = scope.path.to_string_lossy().into_owned();
                            let input =
                                json::write(&D::Object(vec![("path", D::String(&path))])).unwrap();
                            mux.job(
                                io,
                                Job::Native {
                                    name: "file.lstat",
                                    input,
                                },
                                Box::new(move |mux, io, result| {
                                    let result = document(result).and_then(|json| {
                                        if socket(json.root(), scope.uid)? != before {
                                            return Err(error("Herdr socket changed."));
                                        }
                                        let owner = Endpoint {
                                            path: scope.path,
                                            device: before.0,
                                            inode: before.1,
                                            server,
                                        };
                                        Ok((owner, facts))
                                    });
                                    done(mux, io, result);
                                }),
                            );
                        }),
                    );
                });
                if let Some(fd) = fd {
                    let input =
                        json::write(&D::Object(vec![("fd", D::Signed(fd.into()))])).unwrap();
                    mux.job(
                        io,
                        Job::Native {
                            name: "peer",
                            input,
                        },
                        Box::new(move |mux, io, result| {
                            verify(mux, io, document(result));
                        }),
                    );
                } else if let Some(owner) = &fallback {
                    let result = Json::parse(
                        &json::write(&D::Object(vec![
                            ("uid", D::Unsigned(uid.into())),
                            ("pid", D::Unsigned(owner.server.pid.into())),
                        ]))
                        .unwrap(),
                    );
                    verify(mux, io, result);
                } else {
                    verify(mux, io, Err(error("Herdr server identity is unavailable.")));
                }
            }),
        );
    }
}
