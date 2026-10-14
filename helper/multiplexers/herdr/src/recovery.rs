use super::*;

pub(super) struct Admission {
    config: Config,
    done: Action<Option<String>>,
    deadline: Instant,
    retry: Option<Instant>,
    watch: Option<u64>,
    pid: Option<u32>,
}

/// The recovery registration: this helper's own file, an encoded plain value.
pub(super) fn record(
    config: &Config,
    owner: &auth::Endpoint,
    facts: &Encoded,
) -> Result<Vec<u8>, Error> {
    let bytes = body::encode_plain(&D::Object(vec![
        ("socket", D::from(owner.path.as_path())),
        ("session", D::String(&config.session)),
        ("directory", D::from(config.directory.as_path())),
        ("uid", D::Unsigned(config.uid.into())),
        ("device", D::Unsigned(owner.device)),
        ("inode", D::Unsigned(owner.inode)),
        ("server", facts.root()),
    ]))?;
    if bytes.len() > 16384 {
        return Err(error(
            "Herdr recovery registration exceeded the size limit.",
        ));
    }
    Ok(bytes)
}

pub(super) fn read(value: &D<'_>, template: &Config) -> Result<(Config, auth::Endpoint), Error> {
    let field = |key: &str| value.get(key).ok_or_else(|| error(format!("Missing herdr field {key}.")));
    let path = |key: &str| field(key)?.path().map(PathBuf::from).ok_or_else(|| error(format!("Invalid herdr field {key}.")));
    if field("uid")?.unsigned() != Some(template.uid.into()) {
        return Err(error("Herdr registration belongs to another user."));
    }
    let socket = path("socket")?;
    if !socket.is_absolute() {
        return Err(error("Invalid herdr socket path."));
    }
    let server = Process::read(field("server")?).ok_or_else(|| error("Invalid process field."))?;
    let owner = auth::Endpoint {
        path: socket.clone(),
        device: field("device")?.unsigned().ok_or_else(|| error("Invalid herdr device."))?,
        inode: field("inode")?.unsigned().ok_or_else(|| error("Invalid herdr inode."))?,
        server,
    };
    let config = Config {
        executable: owner.server.executable.clone(),
        socket,
        session: field("session")?.string().map(str::to_owned).ok_or_else(|| error("Invalid herdr field session."))?,
        directory: path("directory")?,
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
        let input = body::encode_plain(&D::Object(vec![("path", D::from(config.socket.as_path()))])).unwrap();
        self.job(
            io,
            Job::Native {
                name: "file.realpath",
                value: input,
            },
            Box::new(move |mux, io, result| {
                let path = auth::document(result).and_then(|value| {
                    value.root().get("path").and_then(D::path).map(PathBuf::from).ok_or_else(|| error("Invalid herdr field path."))
                });
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
                                .join(format!("herdr-{token}"));
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
            Ok(path) => path.join(format!("herdr-{token}")),
            Err(reason) => {
                self.defer(io, done, Err(error(reason.to_string())));
                return;
            }
        };
        let key = key.to_owned();
        let input = body::encode_plain(&D::Object(vec![
            ("path", D::from(path.as_path())),
            ("limit", D::Unsigned(16384)),
        ]))
        .unwrap();
        self.job(
            io,
            Job::Native {
                name: "file.private",
                value: input,
            },
            Box::new(move |mux, io, result| {
                let parsed = auth::document(result).and_then(|file| {
                    let file = file.root();
                    let missing = || error("Herdr recovery registration is not private or changed.");
                    let before = file.get("before").ok_or_else(missing)?;
                    let after = file.get("after").ok_or_else(missing)?;
                    let data = file.get("data").and_then(D::bytes).ok_or_else(missing)?;
                    if body::encode_plain(before)? != body::encode_plain(after)?
                        || before.get("uid").and_then(D::unsigned) != Some(mux.config.uid.into())
                        || before.get("mode").and_then(D::unsigned).is_none_or(|mode| mode & 0o077 != 0)
                        || before.get("links").and_then(D::unsigned) != Some(1)
                        || before.get("kind").and_then(D::string) != Some("file")
                        || before.get("size").and_then(D::unsigned) != Some(data.len() as u64)
                        || data.len() > 16384
                    {
                        return Err(missing());
                    }
                    read(&body::decode_plain(data)?, &mux.config)
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
