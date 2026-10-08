//! Herdr's snapshot fields, split paths and terminal-frame admission.
use dispatch_helper4_core::{
    api::{Axis, Error, Grid, Id, Kind, Layout, Node, Shared, Split},
    json::Value,
};
use std::{collections::BTreeMap, path::PathBuf};

pub fn error(message: impl Into<String>) -> Error {
    Error {
        code: "herdr",
        message: message.into(),
    }
}

pub(super) fn expired(message: impl Into<String>) -> Error {
    Error {
        code: "expired",
        message: message.into(),
    }
}

pub(super) fn focus(event: Value<'_>) -> Option<usize> {
    match event.get("event").and_then(Value::string) {
        Some("workspace_focused" | "workspace.focused") => Some(0),
        Some("tab_focused" | "tab.focused") => Some(1),
        Some("pane_focused" | "pane.focused") => Some(2),
        _ => None,
    }
}

pub(super) fn mutation(method: &str) -> bool {
    !matches!(
        method,
        "events.subscribe"
            | "session.snapshot"
            | "agent.list"
            | "pane.list"
            | "pane.get"
            | "pane.process_info"
            | "layout.export"
    )
}
pub(super) fn delivery(mut reason: Error, attempted: bool) -> Error {
    if attempted && reason.code != "expired" {
        reason.code = "uncertain";
    }
    reason
}

pub(super) fn size(grid: Grid) -> bool {
    (1..=4096).contains(&grid.columns)
        && (1..=4096).contains(&grid.rows)
        && grid
            .pixels
            .is_none_or(|(width, height)| width <= 4096 && height <= 4096)
}
pub(super) fn label(value: &str) -> bool {
    !value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control)
}
pub fn field<'a>(v: Value<'a>, key: &str) -> Result<Value<'a>, Error> {
    v.get(key)
        .ok_or_else(|| error(format!("Missing herdr field {key}.")))
}
pub fn text(v: Value<'_>, key: &str) -> Result<String, Error> {
    field(v, key)?
        .string()
        .map(str::to_owned)
        .ok_or_else(|| error(format!("Invalid herdr field {key}.")))
}
fn optional(v: Value<'_>, key: &str) -> Result<Option<String>, Error> {
    match v
        .get(key)
        .filter(|v| v.kind() != dispatch_helper4_core::json::Kind::Null)
    {
        Some(v) => v
            .string()
            .map(|s| Some(s.into()))
            .ok_or_else(|| error(format!("Invalid herdr field {key}."))),
        None => Ok(None),
    }
}
fn list<T>(
    v: Value<'_>,
    key: &str,
    read: impl Fn(Value<'_>) -> Result<T, Error>,
) -> Result<Vec<T>, Error> {
    field(v, key)?
        .array()
        .ok_or_else(|| error(format!("Invalid herdr array {key}.")))?
        .map(read)
        .collect()
}

#[derive(Clone, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Rect {
    fn read(v: Value<'_>) -> Result<Self, Error> {
        let n = |k| {
            field(v, k)?
                .number()
                .ok_or_else(|| error("Invalid herdr rectangle."))
        };
        Ok(Self {
            x: n("x")?,
            y: n("y")?,
            width: n("width")?,
            height: n("height")?,
        })
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Workspace {
    pub key: String,
    pub label: String,
    pub active: String,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Tab {
    pub key: String,
    pub parent: String,
    pub label: String,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Pane {
    pub key: String,
    pub terminal: String,
    pub parent: String,
    pub cwd: Option<String>,
    pub title: Option<String>,
    pub label: Option<String>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Divider {
    pub key: String,
    pub direction: String,
    pub ratio: f64,
    pub rect: Rect,
}
#[derive(Clone, Debug, PartialEq)]
pub struct View {
    pub key: String,
    pub focus: String,
    pub area: Rect,
    pub panes: Vec<(String, Rect)>,
    pub zoomed: Option<bool>,
    pub splits: Option<Vec<Divider>>,
}
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    pub focus: [Option<String>; 3],
    pub workspaces: Vec<Workspace>,
    pub tabs: Vec<Tab>,
    pub panes: Vec<Pane>,
    pub layouts: Vec<View>,
}
impl Snapshot {
    pub(super) fn select(&mut self, selection: &[Option<String>; 3]) {
        let Some(workspace) = self
            .workspaces
            .iter_mut()
            .find(|workspace| selection[0].as_ref() == Some(&workspace.key))
        else {
            return;
        };
        let tab = selection[1]
            .as_ref()
            .filter(|key| {
                self.tabs
                    .iter()
                    .any(|tab| &tab.key == *key && tab.parent == workspace.key)
            })
            .cloned()
            .unwrap_or_else(|| workspace.active.clone());
        workspace.active = tab.clone();
        let pane = selection[2]
            .as_ref()
            .filter(|key| {
                self.panes
                    .iter()
                    .any(|pane| &pane.key == *key && pane.parent == tab)
            })
            .cloned()
            .or_else(|| {
                self.layouts
                    .iter()
                    .find(|view| view.key == tab)
                    .map(|view| view.focus.clone())
            });
        if let Some(pane) = &pane
            && let Some(view) = self.layouts.iter_mut().find(|view| view.key == tab)
        {
            view.focus = pane.clone();
        }
        self.focus = [Some(workspace.key.clone()), Some(tab), pane];
    }
    pub fn read(v: Value<'_>) -> Result<Self, Error> {
        Ok(Self {
            focus: [
                optional(v, "focused_workspace_id")?,
                optional(v, "focused_tab_id")?,
                optional(v, "focused_pane_id")?,
            ],
            workspaces: list(v, "workspaces", |w| {
                Ok(Workspace {
                    key: text(w, "workspace_id")?,
                    label: text(w, "label")?,
                    active: text(w, "active_tab_id")?,
                })
            })?,
            tabs: list(v, "tabs", |t| {
                Ok(Tab {
                    key: text(t, "tab_id")?,
                    parent: text(t, "workspace_id")?,
                    label: text(t, "label")?,
                })
            })?,
            panes: list(v, "panes", |p| {
                Ok(Pane {
                    key: text(p, "pane_id")?,
                    terminal: text(p, "terminal_id")?,
                    parent: text(p, "tab_id")?,
                    cwd: optional(p, "cwd")?,
                    title: optional(p, "title")?,
                    label: optional(p, "label")?,
                })
            })?,
            layouts: list(v, "layouts", |l| {
                Ok(View {
                    key: text(l, "tab_id")?,
                    focus: text(l, "focused_pane_id")?,
                    area: Rect::read(field(l, "area")?)?,
                    panes: list(l, "panes", |p| {
                        Ok((text(p, "pane_id")?, Rect::read(field(p, "rect")?)?))
                    })?,
                    zoomed: l
                        .get("zoomed")
                        .filter(|v| v.kind() != dispatch_helper4_core::json::Kind::Null)
                        .map(|v| {
                            v.boolean()
                                .ok_or_else(|| error("Invalid herdr zoom state."))
                        })
                        .transpose()?,
                    splits: l
                        .get("splits")
                        .filter(|v| v.kind() != dispatch_helper4_core::json::Kind::Null)
                        .map(|_| {
                            list(l, "splits", |d| {
                                Ok(Divider {
                                    key: text(d, "id")?,
                                    direction: text(d, "direction")?,
                                    ratio: field(d, "ratio")?
                                        .number()
                                        .ok_or_else(|| error("Invalid herdr split ratio."))?,
                                    rect: Rect::read(field(d, "rect")?)?,
                                })
                            })
                        })
                        .transpose()?,
                })
            })?,
        })
    }
}

pub fn path(key: &str) -> Option<Vec<bool>> {
    let parts: Vec<_> = key.split('_').collect();
    if parts.len() != 3 || parts[0] != "split" || parts[1].parse::<i64>().is_err() {
        return None;
    }
    if parts[2] == "root" {
        return Some(Vec::new());
    }
    if parts[2].is_empty() {
        return None;
    }
    parts[2]
        .bytes()
        .map(|b| match b {
            b'0' => Some(false),
            b'1' => Some(true),
            _ => None,
        })
        .collect()
}

#[derive(Default)]
pub struct Graph {
    pub ids: BTreeMap<String, Id>,
    pub next: Shared<Id>,
}
impl Graph {
    pub fn focus(&self, snapshot: &Snapshot) -> Option<Id> {
        snapshot
            .focus
            .iter()
            .enumerate()
            .rev()
            .find_map(|(index, key)| {
                let key = key.as_ref()?;
                let key = match index {
                    2 => {
                        &snapshot
                            .panes
                            .iter()
                            .find(|pane| &pane.key == key)?
                            .terminal
                    }
                    1 => &snapshot.tabs.iter().find(|tab| &tab.key == key)?.key,
                    _ => {
                        &snapshot
                            .workspaces
                            .iter()
                            .find(|workspace| &workspace.key == key)?
                            .key
                    }
                };
                self.ids.get(key).copied()
            })
    }
    pub fn issue(&mut self) -> Id {
        let mut next = self.next.borrow_mut();
        *next += 1;
        *next
    }
    pub fn id(&mut self, key: &str) -> Id {
        if let Some(id) = self.ids.get(key) {
            return *id;
        }
        let id = self.issue();
        self.ids.insert(key.into(), id);
        id
    }
    pub fn topology(
        &mut self,
        backend: Id,
        s: &Snapshot,
    ) -> Result<(Vec<Node>, Vec<Layout>), Error> {
        let mut staged = Graph {
            ids: self.ids.clone(),
            next: self.next.clone(),
        };
        let mut nodes = Vec::new();
        for w in &s.workspaces {
            nodes.push(Node {
                detached: false, renamed: None,
                tty: None,
                id: staged.id(&w.key),
                key: w.key.clone(),
                parent: Some(backend),
                kind: Kind::Workspace,
                name: w.label.clone(),
                cwd: None,
                size: None,
                agent: None,
            });
        }
        for t in &s.tabs {
            nodes.push(Node {
                detached: false, renamed: Some(t.label != (s.tabs.iter().filter(|tab| tab.parent == t.parent)
                    .position(|tab| tab.key == t.key).unwrap() + 1).to_string()),
                tty: None,
                id: staged.id(&t.key),
                key: t.key.clone(),
                parent: Some(staged.id(&t.parent)),
                kind: Kind::Tab,
                name: t.label.clone(),
                cwd: None,
                size: None,
                agent: None,
            });
        }
        let mut panes = BTreeMap::new();
        for p in &s.panes {
            let id = staged.id(&p.terminal);
            panes.insert(p.key.as_str(), id);
            nodes.push(Node {
                detached: false, renamed: None,
                tty: None,
                id,
                key: p.terminal.clone(),
                parent: Some(staged.id(&p.parent)),
                kind: Kind::Terminal,
                name: p
                    .label
                    .as_ref()
                    .or(p.title.as_ref())
                    .cloned()
                    .unwrap_or_default(),
                cwd: p.cwd.as_ref().map(PathBuf::from),
                size: None,
                agent: None,
            });
        }
        let mut layouts = Vec::new();
        for l in &s.layouts {
            if l.panes.is_empty() {
                continue;
            }
            let mut leaves = l.panes.iter();
            let full = staged.tree(l, &mut leaves, &panes, &mut Vec::new())?;
            if leaves.next().is_some() {
                return Err(error("Invalid herdr layout."));
            }
            let focus = panes.get(l.focus.as_str()).copied();
            let visible = if l.zoomed == Some(true) {
                Split::Leaf(focus.ok_or_else(|| error("Missing zoomed herdr pane."))?)
            } else {
                full.clone()
            };
            layouts.push(Layout {
                container: staged.id(&l.key),
                full,
                visible,
                focus,
            });
        }
        let mut known = BTreeMap::new();
        for node in &nodes {
            if node.id == backend || node.key.is_empty() || known.insert(node.id, node).is_some() {
                return Err(error("Invalid herdr node identity."));
            }
        }
        for node in &nodes {
            let valid = match node.kind {
                Kind::Workspace => node.parent == Some(backend),
                Kind::Tab => node
                    .parent
                    .and_then(|id| known.get(&id))
                    .is_some_and(|parent| parent.kind == Kind::Workspace),
                Kind::Terminal => node
                    .parent
                    .and_then(|id| known.get(&id))
                    .is_some_and(|parent| parent.kind == Kind::Tab),
            };
            if !valid {
                return Err(error("Invalid herdr node parent."));
            }
        }
        let mut containers = std::collections::BTreeSet::new();
        for layout in &layouts {
            if !containers.insert(layout.container)
                || !known
                    .get(&layout.container)
                    .is_some_and(|node| node.kind == Kind::Tab)
            {
                return Err(error("Invalid herdr layout container."));
            }
            let mut pending = vec![&layout.full];
            let mut leaves = std::collections::BTreeSet::new();
            loop {
                let Some(split) = pending.pop() else {
                    break;
                };
                match split {
                    Split::Leaf(id) => {
                        if !leaves.insert(*id)
                            || !known.get(id).is_some_and(|node| {
                                node.kind == Kind::Terminal && node.parent == Some(layout.container)
                            })
                        {
                            return Err(error("Invalid herdr layout pane."));
                        }
                    }
                    Split::Branch { children, .. } => {
                        pending.extend(children.iter().map(|(_, split)| split));
                    }
                }
            }
            if layout.focus.is_some_and(|focus| !leaves.contains(&focus)) {
                return Err(error("Invalid herdr layout focus."));
            }
        }
        self.ids = staged.ids;
        Ok((nodes, layouts))
    }
    fn tree<'a>(
        &mut self,
        l: &View,
        leaves: &mut impl Iterator<Item = &'a (String, Rect)>,
        panes: &BTreeMap<&str, Id>,
        route: &mut Vec<bool>,
    ) -> Result<Split, Error> {
        if route.len() >= 64 {
            return Err(error("Herdr layout is too deep."));
        }
        let branch = l
            .splits
            .as_deref()
            .unwrap_or_default()
            .iter()
            .find(|d| path(&d.key).as_ref() == Some(route));
        let Some(d) = branch else {
            return Ok(Split::Leaf(
                *panes
                    .get(
                        leaves
                            .next()
                            .ok_or_else(|| error("Missing herdr layout pane."))?
                            .0
                            .as_str(),
                    )
                    .ok_or_else(|| error("Unknown herdr layout pane."))?,
            ));
        };
        let axis = match d.direction.as_str() {
            "down" => Axis::Rows,
            "right" => Axis::Columns,
            _ => return Err(error("Invalid herdr split direction.")),
        };
        // The old app displays native cell rectangles, not the server's float setting.
        // Common consumers use fractions directly; preserve that rounded cell partition.
        let length = match axis {
            Axis::Columns => d.rect.width,
            Axis::Rows => d.rect.height,
        };
        let denominator = length as u32;
        let numerator = (length * d.ratio).round() as u32;
        if length != f64::from(denominator) {
            return Err(error("Invalid herdr split geometry."));
        }
        if numerator == 0 || numerator >= denominator {
            return Err(error("Invalid herdr split ratio."));
        }
        route.push(false);
        let first = self.tree(l, leaves, panes, route)?;
        *route.last_mut().unwrap() = true;
        let second = self.tree(l, leaves, panes, route)?;
        route.pop();
        Ok(Split::Branch {
            id: self.id(&format!("{}/{}", l.key, d.key)),
            axis,
            children: vec![(numerator, first), (denominator - numerator, second)],
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decoder {
    pub sequence: Option<u64>,
    pub grid: Option<Grid>,
    pub full: bool,
    pub resize: bool,
    pub reset: bool,
}
impl Default for Decoder {
    fn default() -> Self {
        Self {
            sequence: None,
            grid: None,
            full: true,
            resize: false,
            reset: false,
        }
    }
}
impl Decoder {
    pub fn resize(&mut self, grid: Grid) {
        self.grid = Some(grid);
        self.full = true;
        self.resize = false;
    }
    pub fn frame(&mut self, v: Value<'_>) -> Result<Option<Vec<u8>>, Error> {
        let kind = text(v, "type")?;
        if kind == "terminal.reset" && self.reset {
            self.sequence = None;
            self.full = true;
            self.resize = true;
            return Ok(None);
        }
        if kind == "terminal.closed" {
            let reason = optional(v, "reason")?.unwrap_or_else(|| "Herdr terminal closed.".into());
            let words: Vec<_> = reason.split(' ').filter(|w| !w.is_empty()).collect();
            if words.len() == 3 && words[0] == "terminal" && words[2] == "exited"
                || reason.starts_with("terminal attach ended: terminal ")
                    && reason.ends_with(" not found")
            {
                return Err(Error {
                    code: "closed",
                    message: reason,
                });
            }
            return Err(error(reason));
        }
        let seq = field(v, "seq")?
            .unsigned()
            .ok_or_else(|| error("Invalid herdr terminal frame."))?;
        let width = field(v, "width")?
            .unsigned()
            .ok_or_else(|| error("Invalid herdr terminal frame."))?;
        let height = field(v, "height")?
            .unsigned()
            .ok_or_else(|| error("Invalid herdr terminal frame."))?;
        let full = v.get("full").and_then(|v| v.boolean()) == Some(true);
        let encoded = text(v, "bytes")?;
        if kind != "terminal.frame" || text(v, "encoding")? != "ansi" || width == 0 || height == 0 {
            return Err(error("Invalid herdr terminal frame."));
        }
        if self.sequence.is_some_and(|last| seq <= last) {
            return Ok(None);
        }
        if self
            .grid
            .is_some_and(|g| width != u64::from(g.columns) || height != u64::from(g.rows))
        {
            return Ok(None);
        }
        if self.sequence.is_none() && !full {
            return Err(error("Herdr did not send an initial full frame."));
        }
        if self.full && !full {
            return Ok(None);
        }
        let output = decode(&encoded)?;
        self.sequence = Some(seq);
        self.full = false;
        Ok(Some(output))
    }
}

pub use crate::base64::{decode, encode};

// c1654cc HerdrRPC.swift:8-28; the stream owns the final LF and IO.
pub(super) fn request(id: &str, method: &str, params: &[u8]) -> Result<Vec<u8>, Error> {
    use dispatch_helper4_core::json::{self, Data as D, Json};
    let params = Json::parse(params)?;
    json::write(&D::Object(vec![
        ("id", D::String(id)),
        ("method", D::String(method)),
        ("params", D::Value(params.root())),
    ]))
}

pub(super) fn response(
    value: Value<'_>,
    id: &str,
    peer: &str,
) -> Result<dispatch_helper4_core::json::Json, Error> {
    use dispatch_helper4_core::json::{self, Json};
    for name in ["id", "result", "error"] {
        if value
            .object()
            .into_iter()
            .flatten()
            .filter(|(key, _)| *key == name)
            .count()
            > 1
        {
            return Err(error(format!("{peer} returned duplicate reply fields.")));
        }
    }
    if value.get("id").and_then(Value::string) != Some(id) {
        return Err(error(format!("{peer} returned an unexpected request ID.")));
    }
    if let Some(native) = value
        .get("error")
        .filter(|value| value.kind() == json::Kind::Object)
    {
        return Err(error(
            native
                .get("message")
                .and_then(Value::string)
                .map(str::to_owned)
                .unwrap_or_else(|| format!("{peer} request failed.")),
        ));
    }
    let result = value
        .get("result")
        .ok_or_else(|| error(format!("{peer} response has no result.")))?;
    Json::parse(&result.write()?)
}
