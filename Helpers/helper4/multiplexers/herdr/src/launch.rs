use super::*;

impl Herdr {
    pub(super) fn created(&self, response: Value<'_>) -> Result<(Id, String), Error> {
        let pane = response
            .get("root_pane")
            .or_else(|| response.get("pane"))
            .or_else(|| response.get("layout").and_then(|layout| layout.get("root")))
            .ok_or_else(|| error("The herdr creation response has no pane identity."))?;
        let key = text(pane, "pane_id")?;
        let native = self
            .snapshot
            .panes
            .iter()
            .find(|pane| pane.key == key)
            .ok_or_else(|| error("Could not confirm the new herdr terminal."))?;
        if pane
            .get("terminal_id")
            .and_then(Value::string)
            .is_some_and(|terminal| terminal != native.terminal)
        {
            return Err(error(
                "The herdr creation response has a different terminal identity.",
            ));
        }
        let id = self
            .graph
            .ids
            .get(&native.terminal)
            .copied()
            .ok_or_else(|| error("The new herdr terminal is not in the topology."))?;
        Ok((id, key))
    }

    pub(super) fn launch(&mut self, io: &mut dyn Io, launch: Launch) {
        let Launch {
            workspace,
            beside,
            close,
            command,
            done,
        } = launch;
        let environment = self.config.environment.clone();
        let mut argv = Vec::new();
        let removed: Vec<_> = command
            .get_envs()
            .filter_map(|(name, value)| value.is_none().then_some(name))
            .collect();
        if !removed.is_empty() {
            argv.push("env".to_owned());
            for name in removed {
                argv.push("-u".into());
                argv.push(name.to_string_lossy().into_owned());
            }
        }
        argv.push(command.get_program().to_string_lossy().into_owned());
        argv.extend(command.get_args().map(|a| a.to_string_lossy().into_owned()));
        let mut environment = match self.environment(io, environment) {
            Ok(environment) => environment,
            Err(reason) => {
                self.defer(io, done, Err(reason));
                return;
            }
        };
        // Prepared launches carry their harness route; inherited context gets the mux route.
        for (name, value) in command.get_envs() {
            if let Some(value) = value {
                environment.insert(
                    name.to_string_lossy().into_owned(),
                    value.to_string_lossy().into_owned(),
                );
            }
        }
        let cwd = command
            .get_current_dir()
            .unwrap_or(&self.config.directory)
            .to_string_lossy()
            .into_owned();
        let root = D::Object(vec![
            ("type", D::String("pane")),
            ("cwd", D::String(&cwd)),
            (
                "command",
                D::Array(argv.iter().map(|s| D::String(s)).collect()),
            ),
            (
                "env",
                D::Object(
                    environment
                        .iter()
                        .map(|(k, v)| (k.as_str(), D::String(v)))
                        .collect(),
                ),
            ),
        ]);
        self.mutation(
            io,
            "layout.apply",
            D::Object(vec![
                ("workspace_id", D::String(&workspace)),
                ("root", root),
                ("focus", D::Bool(true)),
            ]),
            Box::new(move |mux, io, result| {
                let created = result
                    .and_then(|json| mux.created(json.root()).map(|(id, pane)| (id, pane, json)));
                let (id, pane, json) = match created {
                    Ok(v) => v,
                    Err(e) => {
                        mux.defer(io, done, Err(e));
                        return;
                    }
                };
                let finish: Action = Box::new(move |mux, io, result| {
                    if let Err(e) = result {
                        mux.defer(io, done, Err(e));
                        return;
                    }
                    if let Some(close) = close {
                        mux.mutation(
                            io,
                            "pane.close",
                            D::Object(vec![("pane_id", D::String(&close))]),
                            Box::new(move |mux, io, result| {
                                mux.defer(io, done, result.map(|_| id))
                            }),
                        );
                    } else {
                        mux.defer(io, done, Ok(id));
                    }
                });
                if let Some((tab, target)) = beside {
                    let destination = D::Object(vec![
                        ("type", D::String("tab")),
                        ("tab_id", D::String(&tab)),
                        ("target_pane_id", D::String(&target)),
                        ("split", D::String("right")),
                        ("ratio", D::Real(0.5)),
                    ]);
                    mux.mutation(
                        io,
                        "pane.move",
                        D::Object(vec![
                            ("pane_id", D::String(&pane)),
                            ("destination", destination),
                            ("focus", D::Bool(true)),
                        ]),
                        finish,
                    );
                } else {
                    finish(mux, io, Ok(json));
                }
            }),
        );
    }
}
