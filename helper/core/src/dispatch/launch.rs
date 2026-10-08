//! One prepared-command continuation for every harness and multiplexer.
use super::*;

impl Request<'_> {
    fn endpoint(&mut self, index: usize) -> Result<std::path::PathBuf, Error> {
        let previous = self.io.section(&format!("harness/{index}"));
        let route = self.io.route();
        self.io.section(&previous);
        route.map(|(_, path)| path).map_err(|error| Error {
            code: "io",
            message: error.to_string(),
        })
    }

    /// With a size the terminal is observed before its IO can be missed, like c1654cc
    /// Dispatch/Terminal/SwiftTerminal.swift:72-82 installing callbacks before launch.
    /// Protocol result: Id; with size, terminal.created then the terminals.attach stream
    pub(super) fn create(&mut self, p: Value<'_>) -> Result<(), Error> {
        let (index, mux) = self.mux(p)?;
        let observed = p.get("size").is_some() || p.get("rows").is_some();
        let grid = observed.then(|| size(p)).transpose()?;
        let parent = optional(p, "parent")
            .or_else(|| {
                self.helper
                    .nodes
                    .borrow()
                    .iter()
                    .find_map(|(&id, (module, node))| {
                        (*module == index && node.parent.is_none()).then_some(id)
                    })
            })
            .ok_or_else(|| invalid("parent"))?;
        let key = (self.fd, index, self.id);
        let dependency = if self.helper.nodes.borrow().contains_key(&parent) {
            None
        } else {
            self.helper
                .creations
                .borrow()
                .get(&(self.fd, index, parent))
                .cloned()
        };
        let pending = Rc::new(RefCell::new(Creation::default()));
        let registry = self.helper.creations.clone();
        registry.borrow_mut().insert(key, pending.clone());
        let done = match grid {
            None => self.unit_id(index, None),
            Some(grid) => {
                let created = self.unit_id(index, Some("terminal.created"));
                let attached = self.done(Some("terminal.attached"));
                let windows = self.helper.windows.clone();
                let replies = self.replies.clone();
                let (adoptions, fd, request, mux) =
                    (self.helper.adoptions.clone(), self.fd, self.id, mux.clone());
                Box::new(move |io: &mut dyn Io, result: Result<Id, Error>| {
                    adoptions.borrow_mut().push((
                        fd,
                        request,
                        result.as_ref().ok().map(|id| reference(index, *id)),
                    ));
                    match result {
                        Ok(id) => {
                            created(io, Ok(id));
                            let attached = super::window(
                                replies,
                                windows,
                                fd,
                                request,
                                reference(index, id),
                                attached,
                            );
                            mux.borrow_mut().attach(io, id, grid, false, attached);
                        }
                        Err(error) => created(io, Err(error)),
                    }
                }) as Done<Id>
            }
        };
        let state = pending.clone();
        let entries = registry.clone();
        let done: Done<Id> = Box::new(move |io, result| {
            if entries
                .borrow()
                .get(&key)
                .is_some_and(|current| Rc::ptr_eq(current, &state))
            {
                entries.borrow_mut().remove(&key);
            }
            if state.borrow().result.is_none() {
                state.borrow_mut().result = Some(result.clone());
            }
            let waiting = std::mem::take(&mut state.borrow_mut().waiting);
            done(io, result.clone());
            for waiter in waiting {
                deferred(waiter)(io, result.clone());
            }
        });
        let beside = optional(p, "beside").map(local);
        let active = pending.clone();
        let create: Done<Option<std::process::Command>> =
            deferred(Box::new(move |io, result| match result {
                Ok(command) => {
                    let cancelled = active.borrow().result.clone();
                    if let Some(Err(error)) = cancelled {
                        done(io, Err(error));
                        return;
                    }
                    let create: Done<Id> = Box::new(move |io, result| match result {
                        Ok(_) if active.borrow().result.is_some() => done(
                            io,
                            Err(Error {
                                code: "cancelled",
                                message: String::new(),
                            }),
                        ),
                        Ok(parent) => mux
                            .borrow_mut()
                            .create(io, parent, beside, command, grid, done),
                        Err(error) => done(io, Err(error)),
                    });
                    match dependency {
                        None => create(io, Ok(local(parent))),
                        Some(dependency) => {
                            let result = dependency.borrow().result.clone();
                            if let Some(result) = result {
                                create(io, result);
                            } else {
                                dependency.borrow_mut().waiting.push(create);
                            }
                        }
                    }
                }
                Err(error) => done(io, Err(error)),
            }));
        let prepared: Result<(), Error> = (|| {
            if let Some(index) = optional(p, "launch") {
                let harness = self
                    .helper
                    .harnesses
                    .get(index as usize)
                    .cloned()
                    .ok_or_else(|| invalid("launch"))?;
                let route = self.endpoint(index as usize)?;
                // Like a typed launch and the old CodexLauncherCommand, the terminal runs the
                // launcher, which owns whatever the harness starts for this agent (a private
                // server lives exactly as long as the command, not as long as this helper).
                let mut command =
                    std::process::Command::new(self.io.executable().map_err(|e| Error {
                        code: "io_failure",
                        message: e.to_string(),
                    })?);
                command
                    .arg("launch")
                    .arg(harness.borrow().key())
                    .envs(environment(p)?)
                    .env("DISPATCH_HELPER_ENDPOINT", route);
                if let Some(cwd) = p
                    .get("cwd")
                    .and_then(Value::string)
                    .filter(|s| !s.is_empty())
                {
                    command.current_dir(cwd);
                }
                create(self.io, Ok(Some(command)));
            } else if let Some(command) = self.script(p)? {
                create(self.io, Ok(Some(command)));
            } else {
                self.shell(p, create)?;
            }
            Ok(())
        })();
        if let Err(error) = &prepared {
            registry.borrow_mut().remove(&key);
            pending.borrow_mut().result = Some(Err(error.clone()));
        }
        prepared
    }

    /// N-SHELL: the default shell prepared like the old relay (relay.rs:150-160, startup.rs:
    /// 115-238). With shell integration its startup files are written to a fresh private
    /// directory under Io::directory before the mux gets the Command; every mux gets one.
    fn shell(
        &mut self,
        p: Value<'_>,
        create: Done<Option<std::process::Command>>,
    ) -> Result<(), Error> {
        let failure = |error: std::io::Error| Error {
            code: "io_failure",
            message: error.to_string(),
        };
        let shell = self.helper.shell.clone();
        let Some(integration) = self.helper.integration.clone() else {
            // No startup files: no directory or executable effect is needed.
            let empty = Path::new("");
            let (mut command, _) =
                crate::system::startup::prepare(&shell, empty, empty, empty, None, None, &|name| {
                    std::env::var_os(name)
                });
            self.place(p, &mut command)?;
            create(self.io, Ok(Some(command)));
            return Ok(());
        };
        self.helper.startups += 1;
        let directory = self
            .io
            .directory()
            .map_err(failure)?
            .join(format!("startup-{}", self.helper.startups));
        let helper = self.io.executable().map_err(failure)?;
        let (_, home) = crate::system::System::account().map_err(failure)?;
        let (mut command, files) = crate::system::startup::prepare(
            &shell,
            &home,
            &directory,
            &helper,
            None,
            Some(&integration),
            &|name| std::env::var_os(name),
        );
        self.place(p, &mut command)?;
        let work = self
            .io
            .submit(Job::MakeDir {
                path: directory.clone(),
                mode: 0o700,
            })
            .map_err(failure)?;
        self.io
            .then(work, write(directory, files.into(), command, create));
        Ok(())
    }
}

/// Writes the startup files one by one (0600, never replacing), then hands over the shell.
pub(crate) fn write(
    directory: std::path::PathBuf,
    mut files: std::collections::VecDeque<(String, Vec<u8>)>,
    command: std::process::Command,
    create: Done<Option<std::process::Command>>,
) -> Box<dyn FnOnce(&mut dyn Io, std::io::Result<Output>)> {
    Box::new(move |io, result| {
        let next = result.and_then(|_| {
            files
                .pop_front()
                .map(|(name, bytes)| {
                    io.submit(Job::Write {
                        path: directory.join(name),
                        bytes,
                        mode: 0o600,
                        expected: Expected::Absent,
                    })
                })
                .transpose()
        });
        match next {
            Ok(Some(work)) => io.then(work, write(directory, files, command, create)),
            Ok(None) => create(io, Ok(Some(command))),
            Err(error) => create(
                io,
                Err(Error {
                    code: "io_failure",
                    message: error.to_string(),
                }),
            ),
        }
    })
}

impl Request<'_> {
    /// Protocol result: Install with status off, restart or ready
    /// Core derives status like c1654cc ChatCoordinator.swift:216-227.
    pub(super) fn install(&mut self, p: Value<'_>, audit: bool) -> Result<(), Error> {
        let index = number(p, "launch")? as usize;
        let harness = self
            .helper
            .harnesses
            .get(index)
            .cloned()
            .ok_or_else(|| invalid("launch"))?;
        let route = self.endpoint(index)?;
        // A running agent's own config root (old per-agent install target, c51466a
        // hook_transport.rs:1055-1077); it must be this harness's agent.
        let terminal = optional(p, "terminal");
        let mut provisional = false;
        let agent = terminal
            .map(|terminal| self.helper.binding(terminal, None).or_else(|error| {
                provisional = true;
                self.helper.candidate(terminal).map(|(index, binding, _)| (index, binding)).ok_or(error)
            }))
            .transpose()?
            .map(|(owner, binding)| {
                (owner == index)
                    .then_some(binding)
                    .ok_or_else(|| invalid("terminal"))
            })
            .transpose()?;
        let enabled = if audit {
            None
        } else {
            p.get("enabled").and_then(Value::boolean)
        };
        let (nodes, installs, done) = (
            self.helper.nodes.clone(),
            self.helper.installs.clone(),
            self.done(None),
        );
        let live = move || -> Vec<Binding> {
            nodes
                .borrow()
                .values()
                .filter_map(|(_, node)| node.agent.clone())
                .filter(|(harness, _)| *harness == index)
                .map(|(_, binding)| binding)
                .collect()
        };
        let before = live();
        let process = agent.as_ref().map(|binding| binding.process.clone());
        let action: Done<()> = Box::new(move |io, checked| {
            if let Err(error) = checked { return done(io, Err(error)); }
            harness.borrow_mut().install(
            io,
            &route,
            enabled,
            agent.as_ref(),
            Box::new(move |io, result| {
                done(
                    io,
                    result.map(|mut install| {
                        // Edit reports can describe the pre-install snapshot. A successful
                        // mutation reports the completed state to the app.
                        install.installed = enabled.unwrap_or(install.installed);
                        let mut installs = installs.borrow_mut();
                        match enabled {
                            Some(true) if install.restart => {
                                installs.insert(index, Installed::Stale(before));
                            }
                            Some(true) => {
                                installs.insert(index, Installed::On);
                            }
                            Some(false) => {
                                installs.insert(index, if install.optional { Installed::Disabled } else { Installed::Off });
                            }
                            None => {}
                        }
                        let status = match installs.get(&index) {
                            Some(Installed::Off | Installed::Disabled) => "off",
                            _ if !install.installed => "off",
                            Some(Installed::Stale(stale))
                                if live().iter().any(|b| stale.iter().any(|s| same(b, s))) =>
                            {
                                "restart"
                            }
                            _ => "ready",
                        };
                        Installation(install, status)
                    }),
                )
            }),
            );
        });
        if let Some(terminal) = terminal.filter(|_| provisional) {
            let index = self.helper.nodes.borrow().get(&terminal).map(|(index, _)| *index)
                .ok_or_else(|| invalid("terminal"))?;
            self.helper.multiplexers[index].borrow_mut().check(self.io, local(terminal), &process.unwrap(), deferred(action));
        } else { action(self.io, Ok(())); }
        Ok(())
    }
}

/// The producer's installation facts plus the core-derived status.
struct Installation(Install, &'static str);
impl crate::encode::Encode for Installation {
    fn encode(&self, out: &mut Vec<u8>) {
        self.0.encode(out);
        out.pop();
        out.extend(b",\"status\":");
        self.1.encode(out);
        out.push(b'}');
    }
}
