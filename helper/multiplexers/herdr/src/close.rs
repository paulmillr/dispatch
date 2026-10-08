use super::*;

fn busy() -> Error {
    Error {
        code: "busy",
        message: "This terminal has running work.".into(),
    }
}

type Inspection = Box<dyn FnOnce(&mut Herdr, &mut dyn Io, Result<bool, Error>)>;

impl Herdr {
    pub(super) fn descendants(&self, node: Id) -> Vec<native::Pane> {
        self.snapshot
            .panes
            .iter()
            .filter(|pane| {
                node == self.backend
                    || self.graph.ids.get(&pane.terminal) == Some(&node)
                    || self.graph.ids.get(&pane.parent) == Some(&node)
                    || self.snapshot.tabs.iter().any(|tab| {
                        tab.key == pane.parent && self.graph.ids.get(&tab.parent) == Some(&node)
                    })
            })
            .cloned()
            .collect()
    }

    pub(super) fn prompt(&mut self, io: &mut dyn Io, node: Id, done: Done<()>) {
        self.inspect(
            io,
            node,
            Box::new(move |mux, io, result| match result {
                Ok(true) => mux.node(io, node, "close", Vec::new(), done),
                Ok(false) => mux.defer(io, done, Err(busy())),
                Err(error) => mux.defer(io, done, Err(error)),
            }),
        );
    }

    pub(super) fn inspect(&mut self, io: &mut dyn Io, node: Id, done: Inspection) {
        if let Err(error) = self.locate(node) {
            done(self, io, Err(error));
            return;
        }
        let expected = self
            .descendants(node)
            .into_iter()
            .map(|pane| pane.terminal)
            .collect::<std::collections::BTreeSet<_>>();
        self.call(
            io,
            "session.snapshot",
            D::Object(Vec::new()),
            Order::Normal,
            Box::new(move |mux, io, result| {
                let valid = result.and_then(|json| mux.apply(io, &json)).is_ok();
                let panes = mux.descendants(node);
                let current = panes.iter().map(|pane| pane.terminal.clone()).collect();
                if !valid || expected.is_empty() || expected != current {
                    done(mux, io, Ok(false));
                    return;
                }
                mux.panes(io, node, panes.into(), expected, done);
            }),
        );
    }

    fn panes(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        mut panes: VecDeque<native::Pane>,
        expected: std::collections::BTreeSet<String>,
        done: Inspection,
    ) {
        let Some(pane) = panes.pop_front() else {
            self.call(
                io,
                "session.snapshot",
                D::Object(Vec::new()),
                Order::Normal,
                Box::new(move |mux, io, result| {
                    let valid = result.and_then(|json| mux.apply(io, &json)).is_ok();
                    let current = mux
                        .descendants(node)
                        .into_iter()
                        .map(|pane| pane.terminal)
                        .collect();
                    done(mux, io, Ok(valid && expected == current));
                }),
            );
            return;
        };
        self.call(
            io,
            "pane.process_info",
            D::Object(vec![("pane_id", D::String(&pane.key))]),
            Order::Normal,
            Box::new(move |mux, io, result| {
                let process = result.and_then(|json| {
                    let info = field(json.root(), "process_info")?;
                    let pid = field(info, "shell_pid")?
                        .unsigned()
                        .and_then(|pid| u32::try_from(pid).ok())
                        .ok_or_else(busy)?;
                    Ok((text(info, "pane_id")?, pid))
                });
                let (address, pid) = match process {
                    Ok(process) => process,
                    Err(_) => {
                        done(mux, io, Ok(false));
                        return;
                    }
                };
                mux.call(
                    io,
                    "pane.get",
                    D::Object(vec![("pane_id", D::String(&address))]),
                    Order::Normal,
                    Box::new(move |mux, io, result| {
                        let current = result
                            .and_then(|json| text(field(json.root(), "pane")?, "terminal_id"));
                        if current.as_ref().ok() != Some(&pane.terminal) {
                            done(mux, io, Ok(false));
                            return;
                        }
                        mux.job(
                            io,
                            Job::Process { pid },
                            Box::new(move |mux, io, result| {
                                let shell = match result {
                                    Ok(Output::Process(shell)) => shell,
                                    _ => {
                                        done(mux, io, Ok(false));
                                        return;
                                    }
                                };
                                let input = json::write(&D::Object(vec![
                                    ("pid", D::Unsigned(shell.pid.into())),
                                    (
                                        "start",
                                        D::Array(
                                            shell.start.into_iter().map(D::Unsigned).collect(),
                                        ),
                                    ),
                                ]));
                                let input = match input {
                                    Ok(input) => input,
                                    Err(error) => {
                                        done(mux, io, Err(error));
                                        return;
                                    }
                                };
                                mux.job(
                                    io,
                                    Job::Native {
                                        name: "idle",
                                        input,
                                    },
                                    Box::new(move |mux, io, result| {
                                        let idle = result.ok().and_then(|output| {
                                            let Output::Bytes(bytes) = output else {
                                                return None;
                                            };
                                            Json::parse(&bytes).ok()?.root().get("idle")?.boolean()
                                        });
                                        if idle == Some(true) {
                                            mux.panes(io, node, panes, expected, done);
                                        } else {
                                            done(mux, io, Ok(false));
                                        }
                                    }),
                                );
                            }),
                        );
                    }),
                );
            }),
        );
    }
}
