use super::*;

fn json(result: io::Result<Output>) -> Result<Json, Error> {
    match result {
        Ok(Output::Bytes(bytes)) => Json::parse(&bytes),
        Ok(_) => Err(error("Herdr launch context is missing.")),
        Err(error) => Err(native::error(error.to_string())),
    }
}

impl Herdr {
    pub(super) fn probe(&mut self, io: &mut dyn Io, process: &Process, done: Done<Option<String>>) {
        self.context(io, process, false, done);
    }

    pub(super) fn context(&mut self, io: &mut dyn Io, process: &Process, typed: bool, done: Done<Option<String>>) {
        if !typed && !client::matches(process) {
            self.defer(io, done, Ok(None));
            return;
        }
        if typed {
            match client::arguments(process, true).map(client::invocation) {
                Ok(client::Invocation::Local(_)) => {},
                Ok(_) => { self.defer(io, done, Ok(None)); return; },
                Err(error) => { self.defer(io, done, Err(error)); return; },
            }
        }
        let process = process.clone();
        let input = match json::write(&D::Object(vec![("pid", D::Unsigned(process.pid.into()))])) {
            Ok(input) => input,
            Err(error) => {
                self.defer(io, done, Err(error));
                return;
            }
        };
        self.job(
            io,
            Job::Native {
                name: "process",
                input,
            },
            Box::new(move |mux, io, result| {
                let facts = match json(result) {
                    Ok(facts) => facts,
                    Err(error) => {
                        mux.defer(io, done, Err(error));
                        return;
                    }
                };
                let mut fields = vec![
                    ("pid", D::Unsigned(process.pid.into())),
                    (
                        "names",
                        D::Array(
                            [
                                "HOME",
                                "PATH",
                                "SHELL",
                                "TERM",
                                "LANG",
                                "LC_ALL",
                                "XDG_CONFIG_HOME",
                                "HERDR_CONFIG_PATH",
                                "XDG_DATA_HOME",
                                "HERDR_SESSION",
                                "HERDR_SOCKET_PATH",
                                "HERDR_ENV",
                            ]
                            .into_iter()
                            .map(D::String)
                            .collect(),
                        ),
                    ),
                ];
                let executable = process.executable.to_string_lossy();
                if typed {
                    fields.extend([
                        ("start", D::Array(process.start.into_iter().map(D::Unsigned).collect())),
                        ("executable", D::String(&executable)),
                    ]);
                }
                let input = match json::write(&D::Object(fields)) {
                    Ok(input) => input,
                    Err(error) => {
                        mux.defer(io, done, Err(error));
                        return;
                    }
                };
                let complete = input.clone();
                mux.job(
                    io,
                    Job::Native {
                        name: "environment",
                        input,
                    },
                    Box::new(move |mux, io, result| {
                        let result = json(result).and_then(|environment| {
                            let home = mux
                                .config
                                .environment
                                .get("HOME")
                                .map(PathBuf::from)
                                .unwrap_or_default();
                            Config::context(&process, &facts, &environment, (mux.config.uid, &home), typed)
                        });
                        match result {
                            Ok(Some(_)) if typed => {
                                mux.job(io, Job::Native { name: "process.environment", input: complete }, Box::new(move |mux, io, result| {
                                    let home = mux.config.environment.get("HOME").map(PathBuf::from).unwrap_or_default();
                                    let config = match json(result).and_then(|environment| Config::context(&process, &facts, &environment, (mux.config.uid, &home), true)) {
                                        Ok(Some(config)) => config,
                                        Ok(None) => { mux.defer(io, done, Ok(None)); return; },
                                        Err(error) => { mux.defer(io, done, Err(error)); return; },
                                    };
                                    let input = json::write(&D::Object(vec![
                                        ("program", D::String("herdr")),
                                        ("cwd", D::String(&config.directory.to_string_lossy())),
                                        ("path", D::String(config.environment.get("PATH").map(String::as_str).unwrap_or_default())),
                                        ("skip", D::String(&process.executable.to_string_lossy())),
                                    ])).unwrap();
                                    mux.job(io, Job::Native { name: "file.program", input }, Box::new(move |mux, io, result| {
                                        match json(result).and_then(|value| text(value.root(), "path")) {
                                            Ok(path) => {
                                                let mut config = config;
                                                config.executable = path.into();
                                                mux.prepare(io, config, done);
                                            }
                                            Err(error) => mux.defer(io, done, Err(error)),
                                        }
                                    }));
                                }));
                            }
                            Ok(Some(config)) => mux.admit(
                                io, config, None, None,
                                Box::new(move |mux, io, result| mux.defer(io, done, result)),
                            ),
                            Ok(None) => mux.defer(io, done, Ok(None)),
                            Err(reason) => mux.defer(io, done, Err(reason)),
                        }
                    }),
                );
            }),
        );
    }

    pub(super) fn registered(&self, owner: &auth::Endpoint) -> Option<String> {
        if self
            .owner
            .as_ref()
            .is_some_and(|existing| existing.same(owner))
        {
            return Some("herdr".into());
        }
        self.endpoints
            .iter()
            .find(|(_, endpoint)| {
                endpoint
                    .owner
                    .as_ref()
                    .is_some_and(|existing| existing.same(owner))
            })
            .map(|(key, _)| key.clone())
    }
    pub(super) fn register(
        &mut self,
        config: Config,
        owner: auth::Endpoint,
        key: String,
    ) -> Result<String, Error> {
        if let Some(key) = self.registered(&owner) {
            let integration = client::capability(&config.environment);
            if !integration.is_empty() {
                if key == "herdr" { self.integration = integration; }
                else if let Some(endpoint) = self.endpoints.get_mut(&key) { endpoint.integration = integration; }
            }
            return Ok(key);
        }
        if self.endpoints.len() >= 128 {
            return Err(error("Herdr registration limit"));
        }
        let mut endpoint = Herdr::new(config);
        endpoint.owner = Some(owner);
        endpoint.pinned = true;
        endpoint.backend = self.graph.issue();
        endpoint.graph.next = self.graph.next.clone();
        endpoint.harnesses = self.harnesses.clone();
        self.endpoints.insert(key.clone(), Box::new(endpoint));
        Ok(key)
    }

    pub(super) fn endpoint(&mut self, id: Id) -> Option<&mut Herdr> {
        self.endpoints
            .values_mut()
            .find(|endpoint| {
                endpoint.backend == id || endpoint.graph.ids.values().any(|current| *current == id)
            })
            .map(Box::as_mut)
    }

    pub(super) fn route(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) {
        match event {
            Event::Timer { at } => {
                self.dispatch(io, ui, Event::Timer { at });
                for endpoint in self.endpoints.values_mut() {
                    endpoint.dispatch(io, ui, Event::Timer { at });
                }
            }
            Event::Exit { pid, status } => {
                self.dispatch(io, ui, Event::Exit { pid, status });
                for endpoint in self.endpoints.values_mut() {
                    endpoint.dispatch(io, ui, Event::Exit { pid, status });
                }
            }
            event => {
                if let Some(endpoint) = self
                    .endpoints
                    .values_mut()
                    .find(|endpoint| endpoint.owns(&event))
                {
                    endpoint.dispatch(io, ui, event);
                } else {
                    self.dispatch(io, ui, event);
                }
            }
        }
    }

    fn owns(&self, event: &Event) -> bool {
        match event {
            Event::Done { work, .. } => self.work.contains_key(work),
            Event::Ready { fd, .. } => {
                let stream = |stream: &Stream| stream.input == *fd || stream.output == *fd;
                self.request
                    .as_ref()
                    .is_some_and(|request| stream(&request.stream))
                    || self.subscription.as_ref().is_some_and(stream)
                    || self.controllers.values().any(|controller| {
                        controller
                            .relay
                            .as_ref()
                            .is_some_and(|relay| relay.owns(*fd))
                            || controller.stderr == Some(*fd)
                            || controller.stream.as_ref().is_some_and(stream)
                    })
            }
            _ => false,
        }
    }
}
