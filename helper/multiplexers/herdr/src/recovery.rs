use super::*;

pub(super) struct Admission {
    config: Config,
    done: Action<Option<String>>,
    deadline: Instant,
    retry: Option<Instant>,
    watch: Option<u64>,
    pid: Option<u32>,
}

pub(super) fn record(
    config: &Config,
    owner: &auth::Endpoint,
    facts: &Json,
) -> Result<Vec<u8>, Error> {
    let bytes = json::write(&D::Object(vec![
        ("socket", D::String(&owner.path.to_string_lossy())),
        ("session", D::String(&config.session)),
        ("directory", D::String(&config.directory.to_string_lossy())),
        ("uid", D::Unsigned(config.uid.into())),
        ("device", D::Unsigned(owner.device)),
        ("inode", D::Unsigned(owner.inode)),
        ("server", D::Value(facts.root())),
    ]))?;
    if bytes.len() > 16384 {
        return Err(error(
            "Herdr recovery registration exceeded the size limit.",
        ));
    }
    Ok(bytes)
}

pub(super) fn read(value: Value<'_>, template: &Config) -> Result<(Config, auth::Endpoint), Error> {
    let uid = field(value, "uid")?.unsigned();
    if uid != Some(template.uid.into()) {
        return Err(error("Herdr registration belongs to another user."));
    }
    let path = PathBuf::from(text(value, "socket")?);
    if !path.is_absolute() {
        return Err(error("Invalid herdr socket path."));
    }
    let server = process::read(field(value, "server")?)?;
    let owner = auth::Endpoint {
        path: path.clone(),
        device: field(value, "device")?
            .unsigned()
            .ok_or_else(|| error("Invalid herdr device."))?,
        inode: field(value, "inode")?
            .unsigned()
            .ok_or_else(|| error("Invalid herdr inode."))?,
        server,
    };
    let config = Config {
        executable: owner.server.executable.clone(),
        socket: path,
        session: text(value, "session")?,
        directory: PathBuf::from(text(value, "directory")?),
        environment: template.environment.clone(),
        uid: template.uid,
    };
    Ok((config, owner))
}

impl Herdr {
    pub(super) fn admit(
        &mut self,
        io: &mut dyn Io,
        config: Config,
        saved: Option<(String, auth::Endpoint)>,
        pid: Option<u32>,
        done: Action<Option<String>>,
    ) {
        let fd = match io.connect(&Address::Unix(config.socket.clone())) {
            Ok(fd) => fd,
            Err(reason)
                if saved.is_none()
                    && matches!(
                        reason.kind(),
                        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                    ) =>
            {
                if self.admissions.len() >= 128 {
                    done(self, io, Err(error("Herdr registration limit")));
                    return;
                }
                let deadline = io.now() + Duration::from_secs(5);
                io.timer(deadline);
                self.awaiting(
                    io,
                    Admission {
                        config,
                        done,
                        deadline,
                        retry: None,
                        watch: None,
                        pid,
                    },
                );
                return;
            }
            Err(reason) => {
                done(self, io, Err(error(reason.to_string())));
                return;
            }
        };
        self.admitted(io, config, saved, done, fd);
    }

    fn awaiting(&mut self, io: &mut dyn Io, mut admission: Admission) {
        // Watch the nearest existing directory, including startup-created ancestors.
        // Recheck after registration so a creation between connect and watch is seen.
        admission.watch = None;
        for path in admission.config.socket.ancestors().skip(1) {
            match io.watch(path, true) {
                Ok(watch) => {
                    admission.watch = Some(watch);
                    break;
                }
                Err(reason) if reason.kind() == io::ErrorKind::NotFound => {}
                Err(_) => break,
            }
        }
        match io.connect(&Address::Unix(admission.config.socket.clone())) {
            Ok(fd) => {
                if let Some(watch) = admission.watch {
                    io.unwatch(watch);
                }
                self.admitted(io, admission.config, None, admission.done, fd);
            }
            Err(reason)
                if matches!(
                    reason.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                ) =>
            {
                // A bound Unix socket's listen transition has no directory event.
                // Platforms lacking a directory watcher need the same bounded fallback.
                admission.retry = if admission.watch.is_none()
                    || reason.kind() == io::ErrorKind::ConnectionRefused
                {
                    let at = admission.deadline.min(io.now() + Duration::from_millis(50));
                    io.timer(at);
                    Some(at)
                } else {
                    None
                };
                self.admissions.push(admission);
            }
            Err(reason) => {
                if let Some(watch) = admission.watch {
                    io.unwatch(watch);
                }
                (admission.done)(self, io, Err(error(reason.to_string())));
            }
        }
    }

    pub(super) fn admission(&mut self, io: &mut dyn Io, event: &Event) {
        let pending = std::mem::take(&mut self.admissions);
        for admission in pending {
            if let Event::Exit { pid, status } = event && admission.pid == Some(*pid) {
                if let Some(watch) = admission.watch { io.unwatch(watch); }
                (admission.done)(self, io, Err(error(format!("Herdr server exited ({status:?})."))));
                continue;
            }
            let (expired, changed) = match event {
                Event::Timer { at } => (
                    *at >= admission.deadline,
                    admission.retry.is_some_and(|retry| retry <= *at),
                ),
                Event::Changed { watch, .. } => (false, admission.watch == Some(*watch)),
                _ => (false, false),
            };
            if expired || changed {
                if let Some(watch) = admission.watch {
                    io.unwatch(watch);
                }
                if expired {
                    (admission.done)(
                        self,
                        io,
                        Err(error("Timed out waiting for the herdr server.")),
                    );
                } else {
                    match io.connect(&Address::Unix(admission.config.socket.clone())) {
                        Ok(fd) => self.admitted(io, admission.config, None, admission.done, fd),
                        Err(reason)
                            if matches!(
                                reason.kind(),
                                io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                            ) =>
                        {
                            self.awaiting(io, admission);
                        }
                        Err(reason) => {
                            (admission.done)(self, io, Err(error(reason.to_string())))
                        }
                    }
                }
            } else {
                self.admissions.push(admission);
            }
        }
    }

    fn admitted(
        &mut self,
        io: &mut dyn Io,
        config: Config,
        saved: Option<(String, auth::Endpoint)>,
        done: Action<Option<String>>,
        fd: i32,
    ) {
        let input = json::write(&D::Object(vec![(
            "path",
            D::String(&config.socket.to_string_lossy()),
        )]))
        .unwrap();
        self.job(
            io,
            Job::Native {
                name: "file.realpath",
                input,
            },
            Box::new(move |mux, io, result| {
                let path = auth::document(result)
                    .and_then(|json| text(json.root(), "path").map(PathBuf::from));
                let mut config = config;
                match path {
                    Ok(path) if path.is_absolute() => config.socket = path,
                    Ok(_) => {
                        io.close(fd);
                        done(mux, io, Err(error("Invalid herdr socket path.")));
                        return;
                    }
                    Err(reason) => {
                        io.close(fd);
                        done(mux, io, Err(reason));
                        return;
                    }
                }
                let scope =
                    auth::Scope::new(&config, saved.as_ref().map(|(_, owner)| owner.clone()));
                mux.verify(
                    io,
                    Some(fd),
                    scope,
                    Box::new(move |mux, io, result| {
                        io.close(fd);
                        let (owner, facts) = match result {
                            Ok(value) => value,
                            Err(reason) => {
                                done(mux, io, Err(reason));
                                return;
                            }
                        };
                        if let Some(key) = mux.registered(&owner) {
                            let result = mux.register(config, owner, key).map(Some);
                            done(mux, io, result);
                            return;
                        }
                        if let Some((key, _)) = saved {
                            let result = mux.register(config, owner, key).map(Some);
                            done(mux, io, result);
                            return;
                        }
                        if mux.endpoints.len() + mux.registrations >= 128 {
                            done(mux, io, Err(error("Herdr registration limit")));
                            return;
                        }
                        let prepared = (|| {
                            let mut bytes = [0; 32];
                            io.random(&mut bytes)
                                .map_err(|reason| error(reason.to_string()))?;
                            let token = bytes
                                .iter()
                                .map(|byte| format!("{byte:02x}"))
                                .collect::<String>();
                            let path = io
                                .storage()
                                .map_err(|reason| error(reason.to_string()))?
                                .join(format!("herdr-{token}.json"));
                            let bytes = record(&config, &owner, &facts)?;
                            Ok::<_, Error>((format!("herdr/{token}"), path, bytes))
                        })();
                        let (key, path, bytes) = match prepared {
                            Ok(value) => value,
                            Err(reason) => {
                                done(mux, io, Err(reason));
                                return;
                            }
                        };
                        mux.registrations += 1;
                        mux.job(
                            io,
                            Job::Write {
                                path,
                                bytes,
                                mode: 0o600,
                                expected: Expected::Absent,
                            },
                            Box::new(move |mux, io, result| {
                                mux.registrations -= 1;
                                let result = match result {
                                    Ok(Output::Written) => {
                                        mux.register(config, owner, key).map(Some)
                                    }
                                    Ok(_) => {
                                        Err(error("Herdr recovery registration was not saved."))
                                    }
                                    Err(reason) => Err(error(reason.to_string())),
                                };
                                done(mux, io, result);
                            }),
                        );
                    }),
                );
            }),
        );
    }

    pub(super) fn restore(&mut self, io: &mut dyn Io, key: &str, done: Done<Id>) {
        let Some(token) = key.strip_prefix("herdr/").filter(|token| {
            token.len() == 64
                && token
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        }) else {
            self.defer(
                io,
                done,
                Err(expired("This herdr session is no longer available.")),
            );
            return;
        };
        let path = match io.storage() {
            Ok(path) => path.join(format!("herdr-{token}.json")),
            Err(reason) => {
                self.defer(io, done, Err(error(reason.to_string())));
                return;
            }
        };
        let key = key.to_owned();
        let input = json::write(&D::Object(vec![
            ("path", D::String(&path.to_string_lossy())),
            ("limit", D::Unsigned(16384)),
        ]))
        .unwrap();
        self.job(
            io,
            Job::Native {
                name: "file.private",
                input,
            },
            Box::new(move |mux, io, result| {
                let parsed = auth::document(result).and_then(|json| {
                    let before = field(json.root(), "before")?;
                    let after = field(json.root(), "after")?;
                    let data = text(json.root(), "data")?;
                    if before.write()? != after.write()?
                        || before.get("uid").and_then(Value::unsigned)
                            != Some(mux.config.uid.into())
                        || before
                            .get("mode")
                            .and_then(Value::unsigned)
                            .is_none_or(|mode| mode & 0o077 != 0)
                        || before.get("links").and_then(Value::unsigned) != Some(1)
                        || before.get("kind").and_then(Value::string) != Some("file")
                        || before.get("size").and_then(Value::unsigned) != Some(data.len() as u64)
                        || data.len() > 16384
                    {
                        return Err(error(
                            "Herdr recovery registration is not private or changed.",
                        ));
                    }
                    read(Json::parse(data.as_bytes())?.root(), &mux.config)
                });
                let (config, owner) = match parsed {
                    Ok(value) => value,
                    Err(reason) => {
                        mux.defer(io, done, Err(reason));
                        return;
                    }
                };
                mux.admit(
                    io,
                    config,
                    Some((key, owner)),
                    None,
                    Box::new(move |mux, io, result| match result {
                        Ok(Some(key)) => mux.open(io, &key, done),
                        Ok(None) => mux.defer(
                            io, done, Err(expired("This herdr session is no longer available.")),
                        ),
                        Err(reason) => mux.defer(io, done, Err(reason)),
                    }),
                );
            }),
        );
    }
}
