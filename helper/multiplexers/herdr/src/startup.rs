use super::*;
use std::os::unix::process::CommandExt;

impl Herdr {
    pub(super) fn start(&mut self, io: &mut dyn Io, done: Done<Id>) {
        self.starts.borrow_mut().push(done);
        if self.starts.borrow().len() > 1 {
            return;
        }
        let waiters = self.starts.clone();
        let held = std::rc::Rc::new(std::cell::Cell::new(None));
        let released = held.clone();
        let finished: Done<Id> = Box::new(move |io, result| {
            if let Some(work) = released.take() {
                io.unlock(work);
            }
            for done in std::mem::take(&mut *waiters.borrow_mut()) {
                let result = result.clone();
                io.defer(Box::new(move |io| done(io, result)));
            }
        });
        let deadline = io.now() + Duration::from_secs(4);
        let path = match io.storage() {
            Ok(path) => path.join("herdr-start.lock"),
            Err(reason) => {
                self.defer(io, finished, Err(error(reason.to_string())));
                return;
            }
        };
        match io.submit(Job::Lock { path, deadline }) {
            Ok(work) => {
                held.set(Some(work));
                self.work.insert(
                    work,
                    Box::new(move |mux, io, result| match result {
                        Ok(Output::Locked) => mux.opening(io, "", Some(deadline), true, finished),
                        Ok(_) => mux.defer(
                            io,
                            finished,
                            Err(error("Herdr startup lock is unavailable.")),
                        ),
                        Err(reason) => mux.defer(io, finished, Err(error(reason.to_string()))),
                    }),
                );
            }
            Err(reason) => self.defer(io, finished, Err(error(reason.to_string()))),
        }
    }
    pub(super) fn opening(
        &mut self,
        io: &mut dyn Io,
        key: &str,
        held: Option<Instant>,
        retry: bool,
        done: Done<Id>,
    ) {
        if let Some(endpoint) = self.endpoints.get_mut(key) {
            endpoint.open(io, "herdr", done);
            return;
        }
        if !["herdr", ""].contains(&key) {
            self.restore(io, key, done);
            return;
        }
        // An explicit registration can adopt a restarted server; observers cannot.
        if !self.pinned {
            self.owner = None;
        }
        self.generation += 1;
        let key = key.to_owned();
        self.call(
            io,
            "session.snapshot",
            D::Object(Vec::new()),
            Order::Normal,
            Box::new(move |mux, io, result| {
                match result {
                    Ok(json) => {
                        let state = mux.apply(io, &json);
                        if let Err(e) = state {
                            mux.defer(io, done, Err(e));
                            return;
                        }
                        if mux.snapshot.workspaces.is_empty() {
                            let environment =
                                match mux.environment(io, mux.config.environment.clone()) {
                                    Ok(environment) => environment,
                                    Err(reason) => {
                                        mux.defer(io, done, Err(reason));
                                        return;
                                    }
                                };
                            let cwd = mux.config.directory.to_string_lossy().into_owned();
                            mux.mutation(
                                io,
                                "workspace.create",
                                D::Object(vec![
                                    ("cwd", D::String(&cwd)),
                                    ("focus", D::Bool(true)),
                                    (
                                        "env",
                                        D::Object(
                                            environment
                                                .iter()
                                                .map(|(k, v)| (k.as_str(), D::String(v)))
                                                .collect(),
                                        ),
                                    ),
                                ]),
                                Box::new(move |mux, io, result| {
                                    let result = result.map(|_| mux.backend);
                                    mux.defer(io, done, result);
                                    mux.observe(io);
                                }),
                            );
                        } else {
                            mux.defer(io, done, Ok(mux.backend));
                            mux.observe(io);
                        }
                    }
                    Err(e) => {
                        // Only an explicit open may start a stopped endpoint; never replace a live incompatible server.
                        if held.is_some()
                            && retry
                            && e.code == "endpoint"
                            && held.is_some_and(|deadline| io.now() < deadline)
                        {
                            mux.opening(io, &key, held, false, done);
                            return;
                        }
                        if !mux.pinned && matches!(e.code, "not_found" | "connection_refused") {
                            let Some(deadline) = held else {
                                mux.start(io, done);
                                return;
                            };
                            if io.now() >= deadline {
                                mux.defer(
                                    io,
                                    done,
                                    Err(error("Timed out waiting for the herdr server.")),
                                );
                                return;
                            }
                            let paths = match mux.config.sockets() {
                                Ok(paths) => paths,
                                Err(error) => { mux.defer(io, done, Err(error)); return; }
                            };
                            mux.checking = true;
                            mux.recoverable(
                                io,
                                paths,
                                Box::new(move |mux, io, admission| {
                                    mux.checking = false;
                                    if let Err(reason) = admission {
                                        mux.defer(io, done, Err(reason));
                                        return;
                                    }
                                    let command = mux.config.server();
                                    // The server and its sessions outlive this helper.
                                    match io.daemon(command) {
                                        Ok(child) => {
                                            let at = io.now() + Duration::from_millis(50);
                                            mux.boot = Some((child.pid, deadline, done));
                                            io.timer(at);
                                        }
                                        Err(e) => mux.defer(io, done, Err(error(e.to_string()))),
                                    }
                                }),
                            );
                        } else {
                            mux.defer(io, done, Err(e));
                        }
                    }
                }
            }),
        );
    }
}

impl Config {
    fn sockets(&self) -> Result<VecDeque<PathBuf>, Error> {
        let stem = self.socket.file_stem().and_then(|stem| stem.to_str()).ok_or_else(|| error("Invalid herdr socket path."))?;
        let binary = self.socket.with_file_name(format!("{stem}-client.sock"));
        Ok(VecDeque::from([self.socket.clone(), binary.clone(), self.socket.clone(), binary]))
    }
    fn server(&self) -> Command {
        let mut command = Command::new(&self.executable);
        command.arg("server").current_dir(&self.directory).env_clear()
            .envs(client::environment(&self.environment, true))
            .env("HERDR_SOCKET_PATH", &self.socket).env("HERDR_SESSION", &self.session)
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0);
        command
    }
}

impl Herdr {
    /// Explicit typed launch shares startup serialization and socket ownership checks.
    /// Registration remains private until the server's peer and snapshot are verified.
    pub(super) fn prepare(&mut self, io: &mut dyn Io, config: Config, done: Done<Option<String>>) {
        let path = match io.storage() {
            Ok(path) => path.join("herdr-start.lock"),
            Err(reason) => { self.defer(io, done, Err(error(reason.to_string()))); return; }
        };
        let deadline = io.now() + Duration::from_secs(4);
        let work = match io.submit(Job::Lock { path, deadline }) {
            Ok(work) => work,
            Err(reason) => { self.defer(io, done, Err(error(reason.to_string()))); return; }
        };
        let done: Done<Option<String>> = Box::new(move |io, result| { io.unlock(work); deferred(done)(io, result); });
        self.work.insert(work, Box::new(move |mux, io, result| {
            if !matches!(result, Ok(Output::Locked)) {
                mux.defer(io, done, Err(error("Herdr startup lock is unavailable.")));
                return;
            }
            match io.connect(&Address::Unix(config.socket.clone())) {
                Ok(fd) => {
                    io.close(fd);
                    mux.admit(io, config, None, None, Box::new(move |mux, io, result| mux.defer(io, done, result)));
                }
                Err(reason) if matches!(reason.kind(), io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused) => {
                    let paths = match config.sockets() {
                        Ok(paths) => paths,
                        Err(error) => { mux.defer(io, done, Err(error)); return; }
                    };
                    mux.recoverable(io, paths, Box::new(move |mux, io, result| {
                        if let Err(error) = result { mux.defer(io, done, Err(error)); return; }
                        match io.daemon(config.server()) {
                            Ok(child) => mux.admit(io, config, None, Some(child.pid), Box::new(move |mux, io, result| mux.defer(io, done, result))),
                            Err(reason) => mux.defer(io, done, Err(error(reason.to_string()))),
                        }
                    }));
                }
                Err(reason) => mux.defer(io, done, Err(error(reason.to_string()))),
            }
        }));
    }
}
