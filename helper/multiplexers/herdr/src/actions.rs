use super::*;

#[derive(Clone, Debug, PartialEq)]
enum Tree {
    Leaf(String),
    Split(String, f64, Box<Tree>, Box<Tree>),
}
impl Tree {
    fn read(state: &Snapshot, tab: &str) -> Result<Self, Error> {
        let view = state
            .layouts
            .iter()
            .find(|view| view.key == tab)
            .ok_or_else(|| expired("The original herdr layout is no longer available."))?;
        if view.zoomed == Some(true) {
            return Err(error("A zoomed herdr layout cannot be moved."));
        }
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
        let mut moves = vec![(self.tree.first().into(), None)];
        self.tree.moves(&mut moves);
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
                        Place::Workspace { label } | Place::Extract(label) => D::Object(vec![
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
                        Place::Before { .. } | Place::Restore => unreachable!(),
                    };
                    if let Place::Workspace { label }
                    | Place::Extract(label)
                    | Place::Tab { label, .. } = &to
                    {
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
}
