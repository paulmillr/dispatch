//! Native metadata groups complete windows without moving their panes.
use crate::{
    commands,
    mux::{Tmux, error, finish, gone},
    ops::Location,
};
use dispatch_helper4_core::{
    api::*,
    base64,
    json::{self, Data, Kind},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt::Write,
    path::Path,
};

#[derive(Clone)]
pub(crate) struct Affinity {
    pub group: String,
    pub name: String,
    pub order: u64,
    pub directory: Option<bool>,
    pub creation: Option<String>,
}
fn identity(value: &str) -> Option<String> {
    (value.split('-').map(str::len).collect::<Vec<_>>() == [8, 4, 4, 4, 12]
        && value
            .bytes()
            .all(|byte| byte == b'-' || byte.is_ascii_hexdigit()))
    .then(|| value.to_ascii_uppercase())
}
pub(crate) fn uuid(io: &mut dyn Io) -> Result<String, Error> {
    let mut bytes = [0; 16];
    io.random(&mut bytes).map_err(error)?;
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    let mut text = String::new();
    for (index, byte) in bytes.iter().enumerate() {
        if matches!(index, 4 | 6 | 8 | 10) {
            text.push('-');
        }
        write!(text, "{byte:02X}").unwrap();
    }
    Ok(text)
}
impl Affinity {
    pub fn parse(value: &str) -> Option<Self> {
        if value.len() > 16384 {
            return None;
        }
        let text = json::write(&Data::String(value)).ok()?;
        let document = Json::parse(&text).ok()?;
        let bytes = base64::decode(document.root()).ok()?;
        let document = Json::parse(&bytes).ok()?;
        let root = document.root();
        // Codable selects the first duplicate member, unlike Foundation projection.
        let get = |name| {
            root.object()?
                .find(|(key, _)| *key == name)
                .map(|(_, value)| value)
        };
        let name = get("name")?.string()?;
        let order = get("order")?.number()?;
        if get("version")?.number()? != 1.0
            || name.is_empty()
            || name.len() > 4096
            || !(0.0..1_000_000.0).contains(&order)
            || order.fract() != 0.0
        {
            return None;
        }
        let directory = match get("usesDirectoryName") {
            None => None,
            Some(value) if value.kind() == Kind::Null => None,
            Some(value) => Some(value.boolean()?),
        };
        let creation = match get("creation") {
            None => None,
            Some(value) if value.kind() == Kind::Null => None,
            Some(value) => Some(identity(value.string()?)?),
        };
        Some(Self {
            group: identity(get("group")?.string()?)?,
            name: name.into(),
            order: order as u64,
            directory,
            creation,
        })
    }
    pub fn encode(&self) -> Result<String, Error> {
        let mut fields = vec![
            ("version", Data::Unsigned(1)),
            ("group", Data::String(&self.group)),
            ("name", Data::String(&self.name)),
            ("order", Data::Unsigned(self.order)),
        ];
        if let Some(value) = self.directory {
            fields.push(("usesDirectoryName", Data::Bool(value)));
        }
        if let Some(value) = &self.creation {
            fields.push(("creation", Data::String(value)));
        }
        Ok(base64::encode(&json::write(&Data::Object(fields))?))
    }
    pub fn command(&self, window: u64) -> Result<String, Error> {
        self.option(&format!("@{window}"), true)
    }
    pub fn option(&self, target: &str, overwrite: bool) -> Result<String, Error> {
        Ok(format!(
            "set-option -w{} -t {target} @dispatch-window {}",
            if overwrite { "" } else { "oq" },
            commands::quote(&self.encode()?)
        ))
    }
}
#[derive(Default)]
pub(crate) struct Groups {
    pub windows: BTreeMap<(Id, u64, u64), Affinity>,
    defaults: BTreeMap<(Id, u64), String>,
    focused: BTreeMap<(Id, u64), Affinity>,
    saved: BTreeSet<(Id, u64, u64)>,
    pub roots: BTreeMap<Id, (Id, u64, String)>,
    pub keys: BTreeMap<Id, String>,
    pub selected: BTreeMap<(Id, u64, String), u64>,
}
impl Tmux {
    pub(crate) fn name(&self, loc: Location, window: u64) -> String {
        let client = &self.backends[&loc.backend].clients[loc.client];
        let state = client
            .snapshot
            .as_ref()
            .unwrap()
            .windows
            .iter()
            .find(|state| state.id == window)
            .unwrap();
        let pane = state.layout.ids()[0];
        display(
            self.affinity(loc, window),
            client.cwd.get(&pane).map(|path| path.as_path()),
        )
    }
    pub(crate) fn affinity(&self, loc: Location, window: u64) -> &Affinity {
        let session = self.backends[&loc.backend].clients[loc.client]
            .snapshot
            .as_ref()
            .unwrap()
            .session;
        &self.groups.windows[&(loc.backend, session, window)]
    }
    pub(crate) fn resolve(&mut self, io: &mut dyn Io, loc: Location) -> Result<(), Error> {
        let snapshot = self.backends[&loc.backend].clients[loc.client]
            .snapshot
            .as_ref()
            .unwrap();
        let session = (loc.backend, snapshot.session);
        if !self.groups.defaults.contains_key(&session) {
            self.groups.defaults.insert(session, uuid(io)?);
        }
        let fallback = snapshot
            .windows
            .iter()
            .find(|window| window.active)
            .and_then(|window| {
                Affinity::parse(&window.affinity).or_else(|| {
                    self.groups
                        .windows
                        .get(&(loc.backend, snapshot.session, window.id))
                        .cloned()
                })
            })
            .or_else(|| self.groups.focused.get(&session).cloned())
            .unwrap_or_else(|| Affinity {
                group: self.groups.defaults[&session].clone(),
                name: snapshot.name.clone(),
                order: 0,
                directory: Some(true),
                creation: None,
            });
        let mut commands = Vec::new();
        for window in &snapshot.windows {
            let key = (loc.backend, snapshot.session, window.id);
            let value = Affinity::parse(&window.affinity)
                .or_else(|| self.groups.windows.get(&key).cloned())
                .unwrap_or_else(|| Affinity {
                    order: window.id,
                    ..fallback.clone()
                });
            if window.affinity.is_empty() && self.groups.saved.insert(key) {
                // This snapshot can predate a creator's explicit metadata write.
                commands.push(value.option(&format!("@{}", window.id), false)?);
            }
            self.groups.windows.insert(key, value);
        }
        if let Some(window) = snapshot.windows.iter().find(|window| window.active) {
            self.groups.focused.insert(
                session,
                self.groups.windows[&(loc.backend, snapshot.session, window.id)].clone(),
            );
        }
        if !commands.is_empty() {
            self.request(io, loc, commands, Box::new(|_, _, _| {}));
        }
        Ok(())
    }
    pub(crate) fn members(&self, loc: Location, group: &str) -> Vec<u64> {
        let snapshot = self.backends[&loc.backend].clients[loc.client]
            .snapshot
            .as_ref()
            .unwrap();
        let mut members: Vec<_> = snapshot
            .windows
            .iter()
            .filter(|window| self.affinity(loc, window.id).group == group)
            .map(|window| window.id)
            .collect();
        members.sort_by_key(|window| (self.affinity(loc, *window).order, *window));
        members
    }
    pub(crate) fn selected(&self, loc: Location, node: Id) -> Option<u64> {
        let (_, session, group) = self.groups.roots.get(&node)?;
        let members = self.members(loc, group);
        self.groups
            .selected
            .get(&(loc.backend, *session, group.clone()))
            .copied()
            .filter(|window| members.contains(window))
            .or_else(|| members.first().copied())
    }
    pub(crate) fn rename_group(&mut self, io: &mut dyn Io, node: Id, name: &str, done: Done<()>) {
        let prepared = (|| {
            if name.is_empty() || name.len() > 4096 {
                return Err(error("Invalid tmux group name"));
            }
            let (loc, _) = self.target(node)?;
            let group = &self.groups.roots[&node].2;
            let commands = self
                .members(loc, group)
                .iter()
                .enumerate()
                .map(|(order, window)| {
                    Affinity {
                        group: group.clone(),
                        name: name.into(),
                        order: order as u64,
                        directory: Some(false),
                        creation: None,
                    }
                    .command(*window)
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok((loc, commands))
        })();
        match prepared {
            Ok((loc, commands)) => {
                let count = commands.len();
                self.mutate(io, loc, commands, count, done);
            }
            Err(error) => finish(io, done, Err(error)),
        }
    }
    pub(crate) fn r#move(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        parent: Id,
        before: Option<Id>,
        done: Done<()>,
    ) {
        let prepared = (|| {
            let (loc, target) = self.target(node)?;
            if !target.starts_with('@') {
                return Err(Error {
                    code: "unsupported",
                    message: "Operation is not implemented".into(),
                });
            }
            let window = crate::snapshot::id(&target, '@')?;
            let snapshot = self.backends[&loc.backend].clients[loc.client]
                .snapshot
                .as_ref()
                .unwrap();
            let (value, mut members) = if parent == loc.backend {
                let name = snapshot
                    .windows
                    .iter()
                    .find(|state| state.id == window)
                    .ok_or_else(|| gone("Tmux window closed"))?
                    .name
                    .clone();
                (
                    Affinity {
                        group: uuid(io)?,
                        name: label(&name),
                        order: 0,
                        directory: Some(true),
                        creation: None,
                    },
                    Vec::new(),
                )
            } else {
                let (backend, session, group) = self
                    .groups
                    .roots
                    .get(&parent)
                    .ok_or_else(|| error("Tmux destination is unavailable"))?;
                if *backend != loc.backend || *session != snapshot.session {
                    return Err(error("Tmux destination is on another session"));
                }
                let members = self.members(loc, group);
                let mut value = self
                    .affinity(
                        loc,
                        *members
                            .first()
                            .ok_or_else(|| error("Tmux destination is empty"))?,
                    )
                    .clone();
                value.name = self.name(loc, members[0]);
                value.directory = Some(value.directory.unwrap_or(false));
                value.creation = None;
                (value, members)
            };
            members.retain(|member| *member != window);
            let position = if let Some(before) = before {
                let (other, target) = self.target(before)?;
                if other.backend != loc.backend || other.client != loc.client {
                    return Err(error("Tmux move target changed"));
                }
                let target = crate::snapshot::id(&target, '@')?;
                members
                    .iter()
                    .position(|member| *member == target)
                    .ok_or_else(|| error("Tmux move target is outside the destination"))?
            } else {
                members.len()
            };
            members.insert(position, window);
            let mut commands = members
                .iter()
                .enumerate()
                .map(|(order, window)| {
                    Affinity {
                        order: order as u64,
                        ..value.clone()
                    }
                    .command(*window)
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok((loc, commands))
        })();
        match prepared {
            Ok((loc, commands)) => {
                let count = commands.len();
                self.mutate(io, loc, commands, count, done);
            }
            Err(error) => finish(io, done, Err(error)),
        }
    }
}
pub(crate) fn label(name: &str) -> String {
    if name.chars().count() > 4 && name.to_lowercase().ends_with(".exe") && !name.contains(' ') {
        name[..name.len() - 4].into()
    } else {
        name.into()
    }
}
pub(crate) fn display(value: &Affinity, directory: Option<&Path>) -> String {
    if value.directory == Some(true)
        && let Some(path) = directory.filter(|path| path.is_absolute())
    {
        return path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "/".into());
    }
    value.name.clone()
}
