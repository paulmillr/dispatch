use super::*;

/// Preserve the old app's string extraction; key/action validation remains app-owned.
pub(super) fn table(config: &str) -> Prefix {
    let mut keys: BTreeMap<&str, &str> = [
        ("prefix", "ctrl+b"),
        ("help", "prefix+?"),
        ("settings", "prefix+s"),
        ("detach", "prefix+q"),
        ("open_notification_target", "prefix+o"),
        ("workspace_picker", "prefix+w"),
        ("goto", "prefix+g"),
        ("new_workspace", "prefix+shift+n"),
        ("rename_workspace", "prefix+shift+w"),
        ("close_workspace", "prefix+shift+d"),
        ("new_tab", "prefix+c"),
        ("rename_tab", "prefix+shift+t"),
        ("previous_tab", "prefix+p"),
        ("next_tab", "prefix+n"),
        ("switch_tab", "prefix+1..9"),
        ("close_tab", "prefix+shift+x"),
        ("cycle_pane_next", "prefix+tab"),
        ("cycle_pane_previous", "prefix+shift+tab"),
        ("split_vertical", "prefix+v"),
        ("split_horizontal", "prefix+minus"),
        ("close_pane", "prefix+x"),
        ("toggle_sidebar", "prefix+b"),
    ]
    .into_iter()
    .collect();
    let mut section = "";
    for raw in config.lines() {
        let line = raw.trim();
        if line.starts_with('[') {
            section = line;
            continue;
        }
        if section != "[keys]" || line.starts_with('#') {
            continue;
        }
        let Some((name, value)) = line.split_once('=') else {
            continue;
        };
        let Some((_, quoted)) = value.split_once('"') else {
            continue;
        };
        let Some((value, _)) = quoted.split_once('"') else {
            continue;
        };
        keys.insert(name.trim(), value);
    }
    Prefix {
        key: keys.get("prefix").map(|value| (*value).into()),
        repeat_ms: None,
        bindings: keys
            .into_iter()
            .filter_map(|(command, binding)| {
                binding.strip_prefix("prefix+").map(|key| PrefixBinding {
                    key: key.into(),
                    command: command.into(),
                    repeat: false,
                })
            })
            .collect(),
    }
}

impl Herdr {
    pub(super) fn prefix(&mut self, io: &mut dyn Io, node: Id, done: Done<Prefix>) {
        if let Some(endpoint) = self.endpoint(node) {
            endpoint.prefix(io, node, done);
            return;
        }
        if node != self.backend && !self.graph.ids.values().any(|id| *id == node) {
            self.defer(io, done, Err(error("Unknown herdr node.")));
            return;
        }
        let environment = &self.config.environment;
        let value = |name: &str| {
            environment
                .get(name)
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
        };
        let path = value("HERDR_CONFIG_PATH").or_else(|| {
            value("XDG_CONFIG_HOME")
                .or_else(|| value("HOME").map(|home| home.join(".config")))
                .map(|base| base.join("herdr/config.toml"))
        });
        let Some(path) = path else {
            self.defer(io, done, Ok(table("")));
            return;
        };
        self.job(
            io,
            Job::Read {
                path,
                offset: 0,
                length: 1 << 20,
            },
            Box::new(move |mux, io, result| {
                let table = match result {
                    Ok(Output::Read {
                        bytes,
                        before,
                        after,
                    }) if before == after && before.size <= 1 << 20 => {
                        table(std::str::from_utf8(&bytes).unwrap_or_default())
                    }
                    _ => table(""),
                };
                mux.defer(io, done, Ok(table));
            }),
        );
    }
}
