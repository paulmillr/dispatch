//! One complete native window/pane/focus transaction.
use crate::{control::Lines, mux::error, topology::Layout};
use dispatch_helper_core::api::Error;
use std::collections::BTreeMap;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Window {
    pub id: u64,
    pub name: String,
    pub layout: Layout,
    pub visible: Layout,
    pub active: bool,
    pub pane: u32,
    pub affinity: String,
    pub renamed: Option<bool>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pane {
    pub width: u32,
    pub height: u32,
    pub title: String,
    pub pid: i32,
    pub tty: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub windows: Vec<Window>,
    pub panes: BTreeMap<u32, Pane>,
    pub session: u64,
    pub client: i32,
    pub server: i32,
    pub socket: String,
    pub name: String,
}
pub(crate) fn id(value: &str, prefix: char) -> Result<u64, Error> {
    let value = value
        .strip_prefix(prefix)
        .ok_or_else(|| error("invalidFrame"))?;
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err(error("invalidFrame"));
    }
    value
        .parse::<u64>()
        .ok()
        .filter(|v| *v <= i64::MAX as u64)
        .ok_or_else(|| error("invalidFrame"))
}
pub(crate) fn fields<const N: usize>(line: &str) -> Result<[&str; N], Error> {
    line.splitn(N, '|')
        .collect::<Vec<_>>()
        .try_into()
        .map_err(|_| error("invalidFrame"))
}
impl Snapshot {
    pub fn parse(windows: &Lines, panes: &Lines, focus: &Lines) -> Result<Self, Error> {
        let result = (|| -> Result<Self, Error> {
            let mut values: Vec<Window> = Vec::new();
            for line in windows.iter() {
                let text = String::from_utf8_lossy(line);
                // Older recorded snapshots start directly with the window id.
                let (renamed, text) = match text.split_once('|') {
                    Some(("0", rest)) => (Some(true), rest),
                    Some(("1", rest)) => (Some(false), rest),
                    _ => (None, text.as_ref()),
                };
                let [w, full, visible, active, pane, affinity, name] = fields(text)?;
                let mut value = Window {
                    id: id(w, '@')?,
                    name: name.into(),
                    layout: Layout::parse(full).map_err(|_| error("malformed"))?,
                    visible: Layout::parse(visible).map_err(|_| error("malformed"))?,
                    active: active == "1",
                    pane: id(pane, '%')?
                        .try_into()
                        .map_err(|_| error("invalidFrame"))?,
                    affinity: affinity.into(),
                    renamed,
                };
                if value
                    .visible
                    .ids()
                    .iter()
                    .any(|p| value.layout.pane(*p).is_none())
                    || value.layout.pane(value.pane).is_none()
                {
                    return Err(error("invalidFrame"));
                }
                if let Some(old) = values.iter_mut().find(|old| old.id == value.id) {
                    let active = value.active;
                    value.active = old.active;
                    if value != *old {
                        return Err(error("invalidFrame"));
                    }
                    old.active |= active;
                } else {
                    values.push(value);
                }
            }
            let text =
                String::from_utf8_lossy(focus.iter().next().ok_or_else(|| error("invalidFrame"))?);
            let [w, pane, session, client, server, socket, name] = fields(&text)?;
            let window = id(w, '@')?;
            let pane = id(pane, '%')?
                .try_into()
                .map_err(|_| error("invalidFrame"))?;
            let selected = values
                .iter_mut()
                .find(|w| w.id == window)
                .ok_or_else(|| error("invalidFrame"))?;
            if selected.layout.pane(pane).is_none() {
                return Err(error("invalidFrame"));
            }
            selected.pane = pane;
            for value in &mut values {
                value.active = value.id == window;
            }
            let mut states = BTreeMap::new();
            for line in panes.iter() {
                let text = String::from_utf8_lossy(line);
                let [pane, width, height, pid, tty, title] = fields(&text)?;
                let size = |s: &str| {
                    s.parse::<u32>()
                        .ok()
                        .filter(|n| (1..=10000).contains(n))
                        .ok_or_else(|| error("invalidFrame"))
                };
                let pane = id(pane, '%')?
                    .try_into()
                    .map_err(|_| error("invalidFrame"))?;
                let value = Pane {
                    width: size(width)?,
                    height: size(height)?,
                    title: title.into(),
                    pid: pid.parse().unwrap_or(0),
                    tty: tty.into(),
                };
                if states.get(&pane).is_some_and(|old| old != &value) {
                    return Err(error("invalidFrame"));
                }
                states.insert(pane, value);
            }
            if values
                .iter()
                .any(|w| w.layout.ids().iter().any(|p| !states.contains_key(p)))
            {
                return Err(error("invalidFrame"));
            }
            Ok(Self {
                windows: values,
                panes: states,
                session: id(session, '$')?,
                client: client.parse().unwrap_or(0),
                server: server.parse().unwrap_or(0),
                socket: socket.into(),
                name: name.into(),
            })
        })();
        result.map_err(|e| {
            error(format!(
                "Could not read tmux windows: {} ({})",
                e.message,
                String::from_utf8_lossy(windows.text())
                    .chars()
                    .take(500)
                    .collect::<String>()
            ))
        })
    }
}
