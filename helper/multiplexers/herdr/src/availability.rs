use super::*;

struct Lookup {
    paths: VecDeque<PathBuf>,
    shim: Option<PathBuf>,
    login: bool,
    done: Done<Vec<String>>,
}

impl Herdr {
    pub(super) fn available(&mut self, io: &mut dyn Io, done: Done<Vec<String>>, login: bool) {
        let mut lookup = Lookup {
            paths: VecDeque::new(),
            shim: None,
            login,
            done,
        };
        if self.config.executable.components().count() != 1 {
            lookup.login = false;
            self.version(io, self.config.executable.clone(), lookup);
            return;
        }
        let path = self
            .config
            .environment
            .get("PATH")
            .map(String::as_str)
            .unwrap_or("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin");
        lookup.paths = path
            .split(':')
            .map(|part| {
                self.config
                    .directory
                    .join(part)
                    .join(&self.config.executable)
            })
            .collect();
        if let Some(path) = self.shim.as_ref() {
            let input = json::write(&D::Object(vec![(
                "path",
                D::String(&path.to_string_lossy()),
            )]))
            .unwrap();
            self.job(
                io,
                Job::Native {
                    name: "file.realpath",
                    input,
                },
                Box::new(move |mux, io, result| {
                    lookup.shim = auth::document(result).ok().and_then(|json| {
                        json.root()
                            .get("path")
                            .and_then(Value::string)
                            .map(PathBuf::from)
                    });
                    mux.search(io, lookup);
                }),
            );
        } else {
            self.search(io, lookup);
        }
    }

    fn search(&mut self, io: &mut dyn Io, mut lookup: Lookup) {
        let Some(path) = lookup.paths.pop_front() else {
            self.login(io, lookup);
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
                name: "file.realpath",
                input,
            },
            Box::new(move |mux, io, result| {
                let resolved = auth::document(result).ok().and_then(|json| {
                    json.root()
                        .get("path")
                        .and_then(Value::string)
                        .map(PathBuf::from)
                });
                if resolved.is_none() || resolved == lookup.shim {
                    mux.search(io, lookup);
                    return;
                }
                mux.job(
                    io,
                    Job::Read {
                        path: path.clone(),
                        offset: 0,
                        length: 1024,
                    },
                    Box::new(move |mux, io, result| {
                        let usable = match result {
                            Ok(Output::Read { before, bytes, .. }) => {
                                before.kind == FileKind::File
                                    && !bytes
                                        .windows(b"--herdr-launch".len())
                                        .any(|bytes| bytes == b"--herdr-launch")
                            }
                            // The old wrapper could execute a file it could not read.
                            Err(error) if error.kind() == io::ErrorKind::PermissionDenied => true,
                            _ => false,
                        };
                        if usable {
                            mux.version(io, path, lookup);
                        } else {
                            mux.search(io, lookup);
                        }
                    }),
                );
            }),
        );
    }

    fn version(&mut self, io: &mut dyn Io, path: PathBuf, lookup: Lookup) {
        let mut command = Command::new(&path);
        command
            .arg("--version")
            .current_dir(&self.config.directory)
            .env_clear()
            .envs(&self.config.environment);
        let deadline = io.now() + Duration::from_secs(3);
        self.job(io, Job::Run { command, input: Vec::new(), deadline }, Box::new(move |mux, io, result| {
            if matches!(&result, Err(error) if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied)) {
                mux.search(io, lookup);
                return;
            }
            let found = matches!(result, Ok(Output::Exit { status: Some(0), .. }));
            if found { mux.config.executable = path; }
            mux.found(io, lookup.done, found);
        }));
    }

    fn login(&mut self, io: &mut dyn Io, lookup: Lookup) {
        if !lookup.login {
            self.found(io, lookup.done, false);
            return;
        }
        let shell = self
            .config
            .environment
            .get("SHELL")
            .map(String::as_str)
            .unwrap_or("/bin/sh");
        let mut command = Command::new(shell);
        command
            .args(["-lc", "printf '\\036%s\\037' \"$PATH\""])
            .current_dir(&self.config.directory)
            .env_clear()
            .envs(&self.config.environment);
        let deadline = io.now() + Duration::from_secs(3);
        self.job(
            io,
            Job::Run {
                command,
                input: Vec::new(),
                deadline,
            },
            Box::new(move |mux, io, result| {
                if let Ok(Output::Exit {
                    status: Some(0),
                    stdout,
                }) = result
                {
                    let path = stdout
                        .iter()
                        .rposition(|byte| *byte == 30)
                        .and_then(|start| stdout[start + 1..].split(|byte| *byte == 31).next())
                        .and_then(|bytes| std::str::from_utf8(bytes).ok())
                        .filter(|path| !path.is_empty());
                    if let Some(path) = path {
                        mux.config.environment.insert("PATH".into(), path.into());
                        mux.available(io, lookup.done, false);
                        return;
                    }
                }
                mux.found(io, lookup.done, false);
            }),
        );
    }

    fn found(&mut self, io: &mut dyn Io, done: Done<Vec<String>>, found: bool) {
        let mut keys = self.endpoints.keys().cloned().collect::<Vec<_>>();
        if found {
            keys.insert(0, "herdr".into());
        }
        self.defer(io, done, Ok(keys));
    }
}
