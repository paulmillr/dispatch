use super::*;

#[derive(Clone)]
pub(super) struct Permit {
    pub terminal: Id,
    pub pane: String,
    pub shell: Process,
    pub agent: Process,
}
impl Permit {
    pub fn same(&self, other: &Self) -> bool {
        self.terminal == other.terminal
            && self.pane == other.pane
            && crate::process::same(&self.shell, &other.shell)
            && self.shell.tty == other.shell.tty
            && self.shell.foreground == other.shell.foreground
            && crate::process::same(&self.agent, &other.agent)
    }
}
type Checked = Box<dyn FnOnce(&mut Herdr, &mut dyn Io, Result<Permit, Error>)>;

impl Herdr {
    fn proof(&mut self, io: &mut dyn Io, method: &str, params: D<'_>, done: Action) {
        match json::write(&params) {
            Ok(params) => self.calls.push_front(Call {
                background: false,
                method: method.into(),
                params,
                done,
                guard: None,
                proof: true,
                deadline: None,
            }),
            Err(reason) => self.deferred.push_back(Box::new(move |mux, io| {
                done(mux, io, Err(reason));
            })),
        }
        io.timer(io.now());
    }
    pub(super) fn control(
        &mut self,
        io: &mut dyn Io,
        terminal: Id,
        process: &Process,
        bytes: Option<&[u8]>,
        done: Done<()>,
    ) {
        let bytes = bytes.map(<[u8]>::to_vec);
        self.permit(
            io,
            terminal,
            process.clone(),
            Box::new(move |mux, io, result| {
                let result = result.and_then(|_| match bytes {
                    Some(bytes) => mux.stream(io, terminal, &bytes),
                    None => Ok(()),
                });
                mux.defer(io, done, result);
            }),
        );
    }
    pub(super) fn type_checked(
        &mut self,
        io: &mut dyn Io,
        terminal: Id,
        process: &Process,
        inputs: &[Input],
        done: Done<()>,
    ) {
        let [input] = inputs else {
            self.defer(
                io,
                done,
                if inputs.is_empty() {
                    Ok(())
                } else {
                    Err(error("Expected one checked input element."))
                },
            );
            return;
        };
        if let Input::Raw(bytes) = input {
            self.control(io, terminal, process, Some(bytes), done);
            return;
        }
        let input = input.clone();
        self.permit(
            io,
            terminal,
            process.clone(),
            Box::new(move |mux, io, result| {
                let permit = match result {
                    Ok(permit) => permit,
                    Err(reason) => {
                        mux.defer(io, done, Err(reason));
                        return;
                    }
                };
                let (method, params) = match crate::input::encode(&permit.pane, &input) {
                    Ok(fields) => fields,
                    Err(reason) => {
                        mux.defer(io, done, Err(reason));
                        return;
                    }
                };
                mux.calls.push_front(Call {
                    background: false,
                    method: method.into(),
                    params,
                    guard: Some(permit),
                    proof: false,
                    deadline: None,
                    done: Box::new(move |mux, io, result| {
                        let result = result.map(|_| ());
                        if matches!(input, Input::Paste(_)) && result.is_ok() {
                            let holder = std::rc::Rc::new(std::cell::RefCell::new(Some(done)));
                            let callback = holder.clone();
                            let at = io.now() + Duration::from_millis(300);
                            if let Err(reason) = io.after(
                                at,
                                Box::new(move |io| {
                                    if let Some(done) = callback.borrow_mut().take() {
                                        io.defer(Box::new(move |io| done(io, Ok(()))));
                                    }
                                }),
                            ) {
                                let done = holder.borrow_mut().take().unwrap();
                                mux.defer(
                                    io,
                                    done,
                                    Err(native::delivery(error(reason.to_string()), true)),
                                );
                            }
                        } else {
                            mux.defer(io, done, result);
                        }
                    }),
                });
                io.timer(io.now());
            }),
        );
    }
    pub(super) fn permit(&mut self, io: &mut dyn Io, terminal: Id, agent: Process, done: Checked) {
        let native = match self.locate(terminal) {
            Ok((Kind::Terminal, pane)) => self
                .snapshot
                .panes
                .iter()
                .find(|item| item.key == pane)
                .map(|item| item.terminal.clone()),
            _ => None,
        };
        let Some(native) = native else {
            done(
                self,
                io,
                Err(expired("This herdr terminal is no longer available.")),
            );
            return;
        };
        self.proof(io, "session.snapshot", D::Object(vec![]), Box::new(move |mux, io, result| {
            let pane = result.and_then(|json| {
                let snapshot = Snapshot::read(field(json.root(), "snapshot")?)?;
                let mut panes = snapshot.panes.iter().filter(|pane| pane.terminal == native);
                let pane = panes.next().ok_or_else(|| expired("This herdr terminal is no longer available."))?;
                if panes.next().is_some() {
                    return Err(expired("This herdr terminal is no longer available."));
                }
                Ok(pane.key.clone())
            });
            let pane = match pane {
                Ok(pane) => pane,
                Err(reason) => {
                    done(mux, io, Err(reason));
                    return;
                }
            };
            let key = pane.clone();
            mux.proof(io, "pane.process_info", D::Object(vec![("pane_id", D::String(&key))]),
                Box::new(move |mux, io, result| {
                    let info = result.and_then(|json| {
                        let info = field(json.root(), "process_info")?;
                        if text(info, "pane_id")? != pane {
                            return Err(expired("This herdr terminal is no longer available."));
                        }
                        let shell = field(info, "shell_pid")?.unsigned()
                            .and_then(|pid| u32::try_from(pid).ok())
                            .ok_or_else(|| error("Cannot identify the process in this herdr terminal."))?;
                        let group = field(info, "foreground_process_group_id")?.signed()
                            .ok_or_else(|| expired("The agent no longer owns this terminal."))?;
                        Ok((shell, group))
                    });
                    let (pid, group) = match info {
                        Ok(info) => info,
                        Err(reason) => {
                            done(mux, io, Err(reason));
                            return;
                        }
                    };
                    mux.job(io, Job::Process { pid }, Box::new(move |mux, io, result| {
                        let shell = match result {
                            Ok(Output::Process(shell)) if shell.tty != 0 && shell.tty == agent.tty
                                && i64::from(shell.foreground) == group && group > 1 => shell,
                            _ => {
                                done(mux, io, Err(expired("The agent no longer owns this terminal.")));
                                return;
                            }
                        };
                        mux.shell(terminal, &shell);
                        let input = match json::write(&D::Object(vec![("tty", D::Unsigned(shell.tty))])) {
                            Ok(input) => input,
                            Err(reason) => {
                            done(mux, io, Err(reason));
                            return;
                        }
                        };
                        mux.job(io, Job::Native { name: "foreground", input }, Box::new(move |mux, io, result| {
                            let valid = crate::process::foreground(result, &shell).ok()
                                .and_then(|processes| mux.candidate(&processes))
                                .is_some_and(|(_, current)| crate::process::owns(&shell, &current, &agent));
                            if !valid {
                                done(mux, io, Err(expired("The agent no longer owns this terminal.")));
                                return;
                            }
                            mux.job(io, Job::Process { pid: shell.pid }, Box::new(move |mux, io, result| {
                                let valid = matches!(result, Ok(Output::Process(ref current))
                                    if crate::process::same(current, &shell) && current.tty == shell.tty
                                        && current.foreground == shell.foreground);
                                if !valid {
                                    done(mux, io, Err(expired("The agent no longer owns this terminal.")));
                                    return;
                                }
                                let key = pane.clone();
                                mux.proof(io, "pane.get", D::Object(vec![("pane_id", D::String(&key))]),
                                    Box::new(move |mux, io, result| {
                                        let valid = result.as_ref().ok()
                                            .and_then(|json| json.root().get("pane"))
                                            .and_then(|pane| pane.get("terminal_id"))
                                            .and_then(Value::string) == Some(native.as_str());
                                        let result = if valid {
                                            Ok(Permit { terminal, pane, shell, agent })
                                        } else {
                                            Err(expired("This herdr terminal is no longer available."))
                                        };
                                        done(mux, io, result);
                                    }));
                            }));
                        }));
                    }));
                }));
        }));
    }
}
