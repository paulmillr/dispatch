use super::*;

#[derive(Clone, Debug, PartialEq)]
enum Tree {
    Leaf(String),
    Split(String, f64, Box<Tree>, Box<Tree>),
}
impl Tree {
    fn read(state: &Snapshot, tab: &str) -> Result<Self, Error> {
        if state
            .layouts
            .iter()
            .any(|view| view.key == tab && view.zoomed == Some(true))
        {
            return Err(error("A zoomed herdr layout cannot be moved."));
        }
        Self::layout(state, tab)
    }
    /// The tab's split, zoomed or not.
    fn layout(state: &Snapshot, tab: &str) -> Result<Self, Error> {
        let view = state
            .layouts
            .iter()
            .find(|view| view.key == tab)
            .ok_or_else(|| expired("The original herdr layout is no longer available."))?;
        fn branch(
            state: &Snapshot,
            view: &native::View,
            route: &mut Vec<bool>,
            index: &mut usize,
        ) -> Result<Tree, Error> {
            if route.len() >= 64 {
                return Err(error("Herdr layout is too deep."));
            }
            let split = view
                .splits
                .as_deref()
                .unwrap_or_default()
                .iter()
                .find(|split| native::path(&split.key).as_ref() == Some(route));
            if let Some(split) = split {
                if !matches!(split.direction.as_str(), "right" | "down")
                    || !split.ratio.is_finite()
                    || split.ratio <= 0.0
                    || split.ratio >= 1.0
                {
                    return Err(error("Invalid herdr split."));
                }
                route.push(false);
                let first = branch(state, view, route, index)?;
                *route.last_mut().unwrap() = true;
                let second = branch(state, view, route, index)?;
                route.pop();
                Ok(Tree::Split(
                    split.direction.clone(),
                    split.ratio,
                    Box::new(first),
                    Box::new(second),
                ))
            } else {
                let key = &view
                    .panes
                    .get(*index)
                    .ok_or_else(|| error("Missing herdr pane."))?
                    .0;
                *index += 1;
                let pane = state
                    .panes
                    .iter()
                    .find(|pane| &pane.key == key && pane.parent == view.key)
                    .ok_or_else(|| expired("The herdr pane changed."))?;
                Ok(Tree::Leaf(pane.terminal.clone()))
            }
        }
        let mut index = 0;
        let tree = branch(state, view, &mut Vec::new(), &mut index)?;
        if index != view.panes.len() {
            return Err(error("Invalid herdr layout."));
        }
        Ok(tree)
    }
    fn first(&self) -> &str {
        match self {
            Self::Leaf(key) => key,
            Self::Split(_, _, first, _) => first.first(),
        }
    }
    fn without(&self, terminal: &str) -> Option<Self> {
        match self {
            Self::Leaf(key) => (key != terminal).then(|| self.clone()),
            Self::Split(direction, ratio, first, second) => {
                match (first.without(terminal), second.without(terminal)) {
                    (Some(first), Some(second)) => Some(Self::Split(
                        direction.clone(),
                        *ratio,
                        Box::new(first),
                        Box::new(second),
                    )),
                    (first, second) => first.or(second),
                }
            }
        }
    }
    fn moves(&self, moves: &mut Vec<(String, Option<(String, String, f64)>)>) {
        if let Self::Split(direction, ratio, first, second) = self {
            moves.push((
                second.first().into(),
                Some((first.first().into(), direction.clone(), *ratio)),
            ));
            first.moves(moves);
            second.moves(moves);
        }
    }
    /// The pane moves that build this tree from its terminals: the first alone, then each beside its sibling.
    fn plan(&self) -> Vec<(String, Option<(String, String, f64)>)> {
        let mut moves = vec![(self.first().into(), None)];
        self.moves(&mut moves);
        moves
    }
}

/// Where a tab moved whole goes: a new workspace with this label, or a new tab of this workspace at this place
/// among its other tabs.
///
/// Consistency: a window moves the same way on every multiplexer, and tmux is the reference. tmux moves a window
/// in one command (tmux `place.rs` Place::Workspace, `affinity.rs` r#move): it keeps its splits, zoom, active pane,
/// id and place, and the server's focus does not move. A herdr move must end the same; what it can't do the way
/// tmux does (herdr has no tab move between workspaces) the helper builds from pane moves. A change to what a move
/// does on one belongs on the other.
pub(super) enum Target {
    Workspace(String),
    Tab(String, usize),
}

/// One step of a tab moved whole, on the terminals it holds.
enum Step {
    /// The terminal's pane zoomed or not.
    Zoom(String, bool),
    /// The terminal's pane into the new tab: alone at the target, or beside a terminal there (direction, ratio).
    Move(String, Option<(String, String, f64)>),
    /// The new tab holds the tree.
    Check,
    /// The new tab at its place among the target's tabs.
    Order,
    /// herdr's focus on this terminal, as before the move: moving panes and zooming take it elsewhere (a tmux
    /// window keeps its active pane, and tmux's focus stays where it was).
    Focus(String),
}

/// A tab moved whole: herdr moves no tab between workspaces, so its panes move one by one into a new tab that
/// rebuilds its split (no new shells). The app sees one move: no topology while it runs, and when a step fails the
/// panes go back into a tab at the origin's place before the failure answers (nothing changed), else `uncertain`.
struct Relocation {
    window: Option<Id>,
    generation: u64,
    tree: Tree,
    label: String,
    zoomed: Option<String>,
    to: Target,
    /// The origin's workspace, its place among the other tabs, and the terminals to focus at the end: the tab's
    /// own focused pane, then the one herdr focused (herdr sets a tab's focused pane only by focusing it).
    origin: (String, usize, Vec<String>),
    steps: VecDeque<Step>,
    tab: Option<String>,
    failure: Option<Error>,
}
impl Relocation {
    fn new(
        window: Option<Id>,
        generation: u64,
        tree: Tree,
        label: String,
        zoomed: Option<String>,
        to: Target,
        origin: (String, usize, Vec<String>),
    ) -> Self {
        // herdr moves no pane out of a zoomed tab: the zoom comes off first and back on in the new tab.
        let mut steps: VecDeque<_> = zoomed
            .clone()
            .map(|terminal| Step::Zoom(terminal, false))
            .into_iter()
            .collect();
        steps.extend(
            tree.plan()
                .into_iter()
                .map(|(terminal, split)| Step::Move(terminal, split)),
        );
        steps.extend([Step::Check, Step::Order]);
        steps.extend(zoomed.clone().map(|terminal| Step::Zoom(terminal, true)));
        steps.extend(origin.2.iter().cloned().map(Step::Focus));
        Self {
            window,
            generation,
            tree,
            label,
            zoomed,
            to,
            origin,
            steps,
            tab: None,
            failure: None,
        }
    }
}

pub(super) struct Origin {
    generation: u64,
    terminal: String,
    tab: String,
    workspace: String,
    label: String,
    tree: Tree,
    remaining: Option<Tree>,
    destination: Option<String>,
}
impl Origin {
    pub(super) fn capture(
        state: &Snapshot,
        terminal: &str,
        generation: u64,
    ) -> Result<Option<Self>, Error> {
        let pane = state
            .panes
            .iter()
            .find(|pane| pane.terminal == terminal)
            .ok_or_else(|| expired("The herdr terminal exited."))?;
        if state
            .panes
            .iter()
            .filter(|other| other.parent == pane.parent)
            .count()
            <= 1
        {
            return Ok(None);
        }
        let tab = state
            .tabs
            .iter()
            .find(|tab| tab.key == pane.parent)
            .ok_or_else(|| expired("The herdr tab exited."))?;
        Ok(Some(Self {
            generation,
            terminal: terminal.into(),
            tab: tab.key.clone(),
            workspace: tab.parent.clone(),
            label: tab.label.clone(),
            tree: Tree::read(state, &tab.key)?,
            remaining: None,
            destination: None,
        }))
    }
    pub(super) fn confirm(&mut self, state: &Snapshot) -> Result<(), Error> {
        let pane = state
            .panes
            .iter()
            .find(|pane| pane.terminal == self.terminal && pane.parent != self.tab)
            .ok_or_else(|| error("The herdr terminal did not leave its original tab."))?;
        let remaining = Tree::read(state, &self.tab)?;
        if self.tree.without(&self.terminal).as_ref() != Some(&remaining) {
            return Err(expired(
                "The original herdr layout changed during extraction.",
            ));
        }
        self.remaining = Some(remaining);
        self.destination = Some(pane.parent.clone());
        Ok(())
    }
    pub(super) fn plan(
        &self,
        state: &Snapshot,
        generation: u64,
    ) -> Result<Vec<(String, Option<(String, String, f64)>)>, Error> {
        if self.generation != generation
            || !state
                .tabs
                .iter()
                .any(|tab| tab.key == self.tab && tab.parent == self.workspace)
            || !state
                .workspaces
                .iter()
                .any(|workspace| workspace.key == self.workspace)
            || !state.panes.iter().any(|pane| {
                pane.terminal == self.terminal && Some(&pane.parent) == self.destination.as_ref()
            })
            || self.remaining.as_ref() != Some(&Tree::read(state, &self.tab)?)
        {
            return Err(expired(
                "The original herdr layout changed; the terminal stays separate.",
            ));
        }
        let moves = self.tree.plan();
        if moves
            .iter()
            .any(|(key, _)| !state.panes.iter().any(|pane| &pane.terminal == key))
        {
            return Err(expired("An original herdr terminal exited."));
        }
        Ok(moves)
    }
}

impl Herdr {
    pub(super) fn retained(&mut self, nodes: &mut [Node]) {
        let parents: BTreeMap<_, _> = nodes.iter().map(|node| (node.id, node.parent)).collect();
        self.detached.retain(|id| parents.contains_key(id));
        for node in nodes {
            let mut id = Some(node.id);
            for _ in 0..parents.len() {
                let Some(current) = id else {
                    break;
                };
                if self.detached.contains(&current) {
                    node.detached = true;
                    break;
                }
                id = parents.get(&current).copied().flatten();
            }
        }
    }
    pub(super) fn reveal(&mut self, node: Id) {
        let Ok((nodes, _)) = self.graph.topology(self.backend, &self.snapshot) else {
            return;
        };
        let mut id = Some(node);
        for _ in 0..nodes.len() {
            let Some(current) = id else {
                break;
            };
            self.detached.remove(&current);
            id = nodes
                .iter()
                .find(|node| node.id == current)
                .and_then(|node| node.parent);
        }
    }

    pub fn seek(&mut self, io: &mut dyn Io, terminal: Id, offset: u64, done: Done<()>) {
        if let Some(endpoint) = self.endpoint(terminal) {
            endpoint.seek(io, terminal, offset, done);
            return;
        }
        let stable = self
            .snapshot
            .panes
            .iter()
            .find(|pane| self.graph.ids.get(&pane.terminal) == Some(&terminal))
            .map(|pane| pane.terminal.clone());
        let Some(stable) = stable else {
            self.defer(
                io,
                done,
                Err(expired("This herdr terminal is no longer available.")),
            );
            return;
        };
        self.call(
            io,
            "pane.list",
            D::Object(Vec::new()),
            Order::Normal,
            Box::new(move |mux, io, result| {
                let pane = result.and_then(|json| {
                    field(json.root(), "panes")?
                        .array()
                        .ok_or_else(|| error("Invalid herdr pane list."))?
                        .find(|pane| {
                            pane.get("terminal_id").and_then(Value::string) == Some(&stable)
                        })
                        .ok_or_else(|| expired("This herdr terminal is no longer available."))
                        .and_then(|pane| text(pane, "pane_id"))
                });
                match pane {
                    Ok(pane) => mux.mutation(
                        io,
                        "pane.scroll",
                        D::Object(vec![
                            ("pane_id", D::String(&pane)),
                            ("offset_from_bottom", D::Unsigned(offset)),
                        ]),
                        Box::new(move |mux, io, result| mux.defer(io, done, result.map(|_| ()))),
                    ),
                    Err(reason) => mux.defer(io, done, Err(reason)),
                }
            }),
        );
    }

    pub fn place(&mut self, io: &mut dyn Io, node: Id, to: &Place, done: Done<()>) {
        if let Some(endpoint) = self.endpoint(node) {
            endpoint.place(io, node, to, done);
            return;
        }
        if let Place::Before { parent, before } = to {
            self.r#move(io, node, *parent, *before, done);
            return;
        }
        if let Place::Workspace { label } = to {
            // A window moves whole, named by its tab or any terminal of it, as a tmux pane names its window
            // (kept consistent with tmux: see Target).
            let tab = match self.locate(node) {
                Ok((Kind::Tab, key)) => Ok(key),
                Ok((Kind::Terminal, key)) => Ok(self
                    .snapshot
                    .panes
                    .iter()
                    .find(|pane| pane.key == key)
                    .unwrap()
                    .parent
                    .clone()),
                Ok(_) => Err(Error {
                    code: "unsupported",
                    message: "A herdr workspace does not move into another.".into(),
                }),
                Err(reason) => Err(reason),
            };
            match tab {
                Ok(tab) => self.relocate(io, node, tab, Target::Workspace(label.clone()), done),
                Err(reason) => self.defer(io, done, Err(reason)),
            }
            return;
        }
        let source = self
            .snapshot
            .panes
            .iter()
            .find(|pane| self.graph.ids.get(&pane.terminal) == Some(&node))
            .cloned();
        let Some(source) = source else {
            self.defer(
                io,
                done,
                Err(expired("This herdr terminal is no longer available.")),
            );
            return;
        };
        if matches!(to, Place::Restore) {
            let origin = self.origins.remove(&source.terminal);
            // Native restoration needs several moves. Intermediate membership is not a completed return.
            self.placements += 1;
            let done: Action<()> = Box::new(move |mux, io, result| {
                mux.placements -= 1;
                mux.topology();
                mux.defer(io, done, result);
            });
            self.call(
                io,
                "session.snapshot",
                D::Object(Vec::new()),
                Order::Normal,
                Box::new(move |mux, io, result| {
                    let prepared = result.and_then(|json| {
                        let state = Snapshot::read(field(json.root(), "snapshot")?)?;
                        let origin = origin
                            .ok_or_else(|| expired("No original herdr layout is retained."))?;
                        let moves = origin.plan(&state, mux.generation)?;
                        let tabs = moves
                            .iter()
                            .map(|(key, _)| {
                                (
                                    key.clone(),
                                    state
                                        .panes
                                        .iter()
                                        .find(|pane| &pane.terminal == key)
                                        .unwrap()
                                        .parent
                                        .clone(),
                                )
                            })
                            .collect();
                        Ok((origin, moves.into(), tabs, state))
                    });
                    match prepared {
                        Ok((origin, moves, tabs, state)) => {
                            mux.returning(io, node, origin, moves, tabs, state, done)
                        }
                        Err(reason) => done(mux, io, Err(reason)),
                    }
                }),
            );
            return;
        }
        let target = match to {
            Place::Split { target, .. } => self
                .snapshot
                .panes
                .iter()
                .find(|pane| self.graph.ids.get(&pane.terminal) == Some(target))
                .cloned(),
            _ => None,
        };
        let to = to.clone();
        self.call(
            io,
            "session.snapshot",
            D::Object(Vec::new()),
            Order::Normal,
            Box::new(move |mux, io, result| {
                let destination = result.and_then(|json| {
                    let state = Snapshot::read(field(json.root(), "snapshot")?)?;
                    let origin = if matches!(to, Place::Extract(_)) {
                        Origin::capture(&state, &source.terminal, mux.generation)?
                    } else {
                        None
                    };
                    let source = state
                        .panes
                        .iter()
                        .find(|pane| {
                            pane.terminal == source.terminal && pane.parent == source.parent
                        })
                        .ok_or_else(|| {
                            error("The herdr terminal moved or exited before it could move.")
                        })?;
                    let destination = match &to {
                        Place::Extract(label) => D::Object(vec![
                            ("type", D::String("new_workspace")),
                            ("label", D::String(label)),
                        ]),
                        Place::Tab { workspace, label } => {
                            let workspace = state
                                .workspaces
                                .iter()
                                .find(|candidate| {
                                    mux.graph.ids.get(&candidate.key) == Some(workspace)
                                })
                                .ok_or_else(|| {
                                    expired("The herdr move target is no longer available.")
                                })?;
                            D::Object(vec![
                                ("type", D::String("new_tab")),
                                ("workspace_id", D::String(&workspace.key)),
                                ("label", D::String(label)),
                            ])
                        }
                        Place::Split { axis, ratio, .. } => {
                            let target = target
                                .as_ref()
                                .and_then(|original| {
                                    state.panes.iter().find(|pane| {
                                        pane.terminal == original.terminal
                                            && pane.parent == original.parent
                                    })
                                })
                                .ok_or_else(|| {
                                    expired("The herdr move target is no longer available.")
                                })?;
                            if !ratio.is_finite() || *ratio <= 0.0 || *ratio >= 1.0 {
                                return Err(error("Invalid herdr split ratio."));
                            }
                            D::Object(vec![
                                ("type", D::String("tab")),
                                ("tab_id", D::String(&target.parent)),
                                ("target_pane_id", D::String(&target.key)),
                                (
                                    "split",
                                    D::String(if *axis == Axis::Rows { "down" } else { "right" }),
                                ),
                                ("ratio", D::Real(*ratio)),
                            ])
                        }
                        Place::Before { .. } | Place::Restore | Place::Workspace { .. } => {
                            unreachable!()
                        }
                    };
                    if let Place::Extract(label) | Place::Tab { label, .. } = &to {
                        if !native::label(label) {
                            return Err(error("Invalid herdr label."));
                        }
                    }
                    json::write(&D::Object(vec![
                        ("pane_id", D::String(&source.key)),
                        ("destination", destination),
                        ("focus", D::Bool(false)),
                    ]))
                    .and_then(|bytes| Json::parse(&bytes))
                    .map(|params| (params, origin))
                });
                match destination {
                    Ok((params, origin)) => mux.mutation(
                        io,
                        "pane.move",
                        D::Value(params.root()),
                        Box::new(move |mux, io, result| {
                            let result = result.and_then(|_| {
                                if let Some(mut origin) = origin {
                                    origin.confirm(&mux.snapshot)?;
                                    mux.origins.insert(origin.terminal.clone(), origin);
                                }
                                Ok(())
                            });
                            if result.is_ok() {
                                mux.reveal(node);
                                mux.topology();
                            }
                            mux.defer(io, done, result);
                        }),
                    ),
                    Err(reason) => mux.reconcile(
                        io,
                        Err(reason),
                        Box::new(move |mux, io, result| {
                            mux.defer(io, done, result.map(|_| ()));
                        }),
                    ),
                }
            }),
        );
    }

    fn returning(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        origin: Origin,
        mut moves: VecDeque<(String, Option<(String, String, f64)>)>,
        mut tabs: BTreeMap<String, String>,
        state: Snapshot,
        done: Action<()>,
    ) {
        if origin.generation != self.generation
            || tabs.iter().any(|(terminal, tab)| {
                !state
                    .panes
                    .iter()
                    .any(|pane| &pane.terminal == terminal && &pane.parent == tab)
            })
        {
            done(
                self,
                io,
                Err(expired("The herdr terminals changed during restoration.")),
            );
            return;
        }
        let Some((terminal, split)) = moves.pop_front() else {
            let restored = state
                .panes
                .iter()
                .find(|pane| pane.terminal == origin.terminal)
                .and_then(|pane| state.tabs.iter().find(|tab| tab.key == pane.parent));
            let result = restored
                .filter(|tab| tab.parent == origin.workspace)
                .ok_or_else(|| expired("The restored herdr tab changed."))
                .and_then(|tab| Tree::read(&state, &tab.key))
                .and_then(|tree| {
                    if tree == origin.tree {
                        Ok(())
                    } else {
                        Err(error("The native herdr layout did not restore exactly."))
                    }
                });
            self.reveal(node);
            done(self, io, result);
            return;
        };
        let pane = state
            .panes
            .iter()
            .find(|pane| pane.terminal == terminal)
            .unwrap();
        let workspace = origin.workspace.clone();
        let label = origin.label.clone();
        let destination = if let Some((target, direction, ratio)) = &split {
            let target = state
                .panes
                .iter()
                .find(|pane| &pane.terminal == target)
                .unwrap();
            D::Object(vec![
                ("type", D::String("tab")),
                ("tab_id", D::String(&target.parent)),
                ("target_pane_id", D::String(&target.key)),
                ("split", D::String(direction)),
                ("ratio", D::Real(*ratio)),
            ])
        } else {
            D::Object(vec![
                ("type", D::String("new_tab")),
                ("workspace_id", D::String(&workspace)),
                ("label", D::String(&label)),
            ])
        };
        self.mutation(
            io,
            "pane.move",
            D::Object(vec![
                ("pane_id", D::String(&pane.key)),
                ("destination", destination),
                ("focus", D::Bool(false)),
            ]),
            Box::new(move |mux, io, result| {
                if let Err(reason) = result {
                    done(mux, io, Err(reason));
                    return;
                }
                let Some(pane) = mux
                    .snapshot
                    .panes
                    .iter()
                    .find(|pane| pane.terminal == terminal)
                else {
                    done(mux, io, Err(expired("The restored herdr terminal exited.")));
                    return;
                };
                tabs.insert(terminal, pane.parent.clone());
                mux.returning(io, node, origin, moves, tabs, mux.snapshot.clone(), done);
            }),
        );
    }

    /// Moves the tab `key` whole to `to`, ending as a tmux window move does (see Target); `node` is what the app
    /// moves (the tab, or a terminal of it).
    pub(super) fn relocate(
        &mut self,
        io: &mut dyn Io,
        node: Id,
        key: String,
        to: Target,
        done: Done<()>,
    ) {
        self.placements += 1;
        let done: Action<()> = Box::new(move |mux, io, result| {
            mux.placements -= 1;
            if result.is_ok() {
                mux.reveal(node);
            }
            mux.topology();
            mux.defer(io, done, result);
        });
        self.call(
            io,
            "session.snapshot",
            D::Object(Vec::new()),
            Order::Normal,
            Box::new(move |mux, io, result| {
                let prepared = result.and_then(|json| mux.apply(io, &json)).and_then(|()| {
                    let state = &mux.snapshot;
                    let tab = state
                        .tabs
                        .iter()
                        .find(|tab| tab.key == key)
                        .ok_or_else(|| expired("This herdr tab is no longer available."))?;
                    match &to {
                        Target::Workspace(label) if !native::label(label) => {
                            return Err(error("Invalid herdr label."));
                        }
                        Target::Tab(workspace, _)
                            if !state.workspaces.iter().any(|w| &w.key == workspace) =>
                        {
                            return Err(expired("The herdr move target is no longer available."));
                        }
                        _ => {}
                    }
                    let view = state
                        .layouts
                        .iter()
                        .find(|view| view.key == key)
                        .ok_or_else(|| {
                            expired("The original herdr layout is no longer available.")
                        })?;
                    let zoomed = match view.zoomed == Some(true) {
                        true => Some(
                            mux.pane(&view.focus)
                                .ok_or_else(|| error("Missing zoomed herdr pane."))?
                                .terminal,
                        ),
                        false => None,
                    };
                    let index = state
                        .tabs
                        .iter()
                        .filter(|other| other.parent == tab.parent)
                        .position(|other| other.key == key)
                        .unwrap();
                    let tree = Tree::layout(state, &key)?;
                    let mut focus: Vec<_> = [Some(view.focus.as_str()), state.focus[2].as_deref()]
                        .into_iter()
                        .flatten()
                        .filter_map(|key| mux.pane(key).map(|pane| pane.terminal))
                        .collect();
                    focus.dedup();
                    let origin = (tab.parent.clone(), index, focus);
                    let window = mux.graph.ids.get(&key).copied();
                    Ok(Relocation::new(
                        window,
                        mux.generation,
                        tree,
                        tab.label.clone(),
                        zoomed,
                        to,
                        origin,
                    ))
                });
                match prepared {
                    Ok(relocation) => mux.relocation(io, relocation, done),
                    Err(reason) => done(mux, io, Err(reason)),
                }
            }),
        );
    }
    /// The pane holding this terminal, by pane key or terminal id.
    fn pane(&self, key: &str) -> Option<native::Pane> {
        self.snapshot
            .panes
            .iter()
            .find(|pane| pane.key == key || pane.terminal == key)
            .cloned()
    }
    fn relocation(&mut self, io: &mut dyn Io, mut r: Relocation, done: Action<()>) {
        if r.generation != self.generation {
            let reason = Error {
                code: "uncertain",
                message: "The herdr server restarted during a move.".into(),
            };
            return done(self, io, Err(reason));
        }
        let Some(step) = r.steps.pop_front() else {
            // A rebuilt tab is the same window to the app, as a tmux window keeps its id when it moves.
            if let (Some(window), Some(tab)) = (r.window, r.tab.take()) {
                self.graph.ids.retain(|_, id| *id != window);
                self.graph.ids.insert(tab, window);
            }
            return match r.failure.take() {
                // Back where it was: nothing changed, whatever the failed step's reply.
                Some(failure) if failure.code == "uncertain" => {
                    done(self, io, Err(error(failure.message)))
                }
                Some(failure) => done(self, io, Err(failure)),
                None => done(self, io, Ok(())),
            };
        };
        let gone = || expired("A herdr terminal exited during a move.");
        match step {
            Step::Zoom(terminal, on) => {
                let Some(pane) = self.pane(&terminal) else {
                    return self.retreat(io, r, gone(), done);
                };
                let params = vec![
                    ("pane_id", D::String(&pane.key)),
                    ("mode", D::String(if on { "on" } else { "off" })),
                ];
                self.mutation(
                    io,
                    "pane.zoom",
                    D::Object(params),
                    Box::new(move |mux, io, result| match result {
                        Ok(_) => mux.relocation(io, r, done),
                        Err(reason) => mux.retreat(io, r, reason, done),
                    }),
                );
            }
            Step::Move(terminal, split) => {
                let Some(source) = self.pane(&terminal) else {
                    return self.retreat(io, r, gone(), done);
                };
                let tab = r.tab.clone().unwrap_or_default();
                let beside = split.as_ref().map(|(terminal, ..)| {
                    self.pane(terminal)
                        .filter(|pane| pane.parent == tab)
                        .map(|pane| pane.key)
                });
                let label = r.label.clone();
                let destination = match (&split, &beside, &r.to) {
                    (Some((_, direction, ratio)), Some(Some(beside)), _) => vec![
                        ("type", D::String("tab")),
                        ("tab_id", D::String(&tab)),
                        ("target_pane_id", D::String(beside)),
                        ("split", D::String(direction)),
                        ("ratio", D::Real(*ratio)),
                    ],
                    (Some(_), _, _) => {
                        return self.retreat(
                            io,
                            r,
                            expired("The herdr move target is no longer available."),
                            done,
                        );
                    }
                    (None, _, Target::Workspace(name)) => vec![
                        ("type", D::String("new_workspace")),
                        ("label", D::String(name)),
                        ("tab_label", D::String(&label)),
                    ],
                    (None, _, Target::Tab(workspace, _)) => vec![
                        ("type", D::String("new_tab")),
                        ("workspace_id", D::String(workspace)),
                        ("label", D::String(&label)),
                    ],
                };
                let params = json::write(&D::Object(vec![
                    ("pane_id", D::String(&source.key)),
                    ("destination", D::Object(destination)),
                    ("focus", D::Bool(false)),
                ]))
                .and_then(|bytes| Json::parse(&bytes));
                let params = match params {
                    Ok(params) => params,
                    Err(reason) => return self.retreat(io, r, reason, done),
                };
                self.mutation(
                    io,
                    "pane.move",
                    D::Value(params.root()),
                    Box::new(move |mux, io, result| {
                        // The first pane opens the new tab: not the origin's, and in the target workspace.
                        let landed = mux
                            .pane(&terminal)
                            .map(|pane| pane.parent)
                            .filter(|parent| match &r.tab {
                                Some(tab) => parent == tab,
                                None => {
                                    *parent != source.parent
                                        && mux.snapshot.tabs.iter().any(|tab| {
                                            &tab.key == parent
                                                && match &r.to {
                                                    Target::Workspace(_) => {
                                                        tab.parent != r.origin.0
                                                    }
                                                    Target::Tab(workspace, _) => {
                                                        &tab.parent == workspace
                                                    }
                                                }
                                        })
                                }
                            });
                        // A pane that landed moved, even when its reply was lost.
                        if landed.is_some() {
                            r.tab = landed.clone();
                        }
                        match (result, landed) {
                            (Err(reason), _) => mux.retreat(io, r, reason, done),
                            (Ok(_), None) => {
                                mux.retreat(io, r, error("A herdr pane did not move."), done)
                            }
                            (Ok(_), Some(_)) => mux.relocation(io, r, done),
                        }
                    }),
                );
            }
            Step::Check => {
                let tab = r.tab.clone().unwrap_or_default();
                if Tree::layout(&self.snapshot, &tab).ok().as_ref() == Some(&r.tree) {
                    self.relocation(io, r, done);
                } else {
                    self.retreat(io, r, error("The herdr layout did not move exactly."), done);
                }
            }
            Step::Focus(terminal) => {
                let focused = self.snapshot.focus[2]
                    .as_deref()
                    .and_then(|key| self.pane(key));
                match self.pane(&terminal) {
                    // Already there, or gone: nothing to put back.
                    Some(pane) if focused.is_none_or(|focused| focused.key != pane.key) => {
                        let params = vec![("pane_id", D::String(&pane.key))];
                        self.mutation(
                            io,
                            "pane.focus",
                            D::Object(params),
                            Box::new(move |mux, io, result| match result {
                                Ok(_) => mux.relocation(io, r, done),
                                Err(reason) => mux.retreat(io, r, reason, done),
                            }),
                        );
                    }
                    _ => self.relocation(io, r, done),
                }
            }
            Step::Order => {
                let (Target::Tab(workspace, index), Some(tab)) = (&r.to, r.tab.clone()) else {
                    return self.relocation(io, r, done);
                };
                let tabs: Vec<_> = self
                    .snapshot
                    .tabs
                    .iter()
                    .filter(|other| &other.parent == workspace)
                    .map(|other| &other.key)
                    .collect();
                let index = (*index).min(tabs.len().saturating_sub(1));
                match tabs.iter().position(|other| **other == tab) {
                    None => self.retreat(io, r, gone(), done),
                    Some(at) if at == index => self.relocation(io, r, done),
                    Some(at) => {
                        // herdr inserts before the tab now at the index: past its own place, one further.
                        let insert = if at < index { index + 1 } else { index };
                        let params = vec![
                            ("tab_id", D::String(&tab)),
                            ("insert_index", D::Unsigned(insert as u64)),
                        ];
                        self.mutation(
                            io,
                            "tab.move",
                            D::Object(params),
                            Box::new(move |mux, io, result| match result {
                                Ok(_) => mux.relocation(io, r, done),
                                Err(reason) => mux.retreat(io, r, reason, done),
                            }),
                        );
                    }
                }
            }
        }
    }
    /// A step failed. Before any pane moved, only the zoom comes back; once some moved, every pane goes back into a
    /// tab at the origin's place; once all moved, or while going back, the move answers `uncertain`.
    fn retreat(&mut self, io: &mut dyn Io, r: Relocation, reason: Error, done: Action<()>) {
        let (alive, gone): (Vec<_>, Vec<_>) = r
            .tree
            .plan()
            .into_iter()
            .map(|(terminal, _)| terminal)
            .partition(|terminal| self.pane(terminal).is_some());
        let whole = r.tab.is_some()
            && alive
                .iter()
                .all(|terminal| self.pane(terminal).map(|pane| pane.parent) == r.tab);
        if r.failure.is_some() || whole {
            return done(
                self,
                io,
                Err(Error {
                    code: "uncertain",
                    message: reason.message,
                }),
            );
        }
        let zoomed = r.zoomed.clone().filter(|terminal| alive.contains(terminal));
        let mut back = if r.tab.is_none() {
            Relocation {
                steps: zoomed
                    .map(|terminal| Step::Zoom(terminal, true))
                    .into_iter()
                    .collect(),
                ..r
            }
        } else {
            let tree = gone
                .iter()
                .try_fold(r.tree.clone(), |tree, terminal| tree.without(terminal));
            let Some(tree) = tree else {
                return done(self, io, Err(reason));
            };
            let to = Target::Tab(r.origin.0.clone(), r.origin.1);
            Relocation::new(r.window, r.generation, tree, r.label, zoomed, to, r.origin)
        };
        back.failure = Some(reason);
        self.relocation(io, back, done);
    }
}
