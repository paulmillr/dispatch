//! Remembered views and hidden native panes have independent lifetimes.
use crate::{
    mux::{Tmux, allocate, error, finish, gone},
    ops::Location,
};
use dispatch_helper4_core::api::*;
use std::collections::{BTreeMap, BTreeSet};

pub(crate) struct View {
    pub node: Node,
    pub session: u64,
    pub panes: BTreeSet<u32>,
}
#[derive(Default)]
pub(crate) struct Selection {
    pub all: bool,
    pub panes: BTreeMap<u64, BTreeSet<u32>>,
    pub hidden: BTreeMap<u64, BTreeSet<u32>>,
}
impl Tmux {
    /// Logical retained descriptors; the pane set remains scoped to its original backend.
    pub fn retained(&self) -> Vec<(Id, Node, Vec<u32>)> {
        self.backends
            .iter()
            .flat_map(|(id, backend)| {
                backend
                    .views
                    .values()
                    .map(|view| (*id, view.node.clone(), view.panes.iter().copied().collect()))
            })
            .collect()
    }
    pub(crate) fn remember(&mut self, loc: Location, node: Id, panes: BTreeSet<u32>) -> Option<Id> {
        let Some(mut node) = self.nodes.iter().find(|value| value.id == node).cloned() else {
            return None;
        };
        let backend = self.backends.get_mut(&loc.backend).unwrap();
        let client = &backend.clients[loc.client];
        let panes: BTreeSet<_> = panes
            .into_iter()
            .filter(|pane| !client.dismissed.contains(pane))
            .collect();
        let session = client.snapshot.as_ref().unwrap().session;
        let remembered: BTreeSet<_> = backend
            .views
            .values()
            .filter(|view| view.session == session)
            .flat_map(|view| view.panes.iter().copied())
            .collect();
        let panes: BTreeSet<_> = panes.difference(&remembered).copied().collect();
        if panes.is_empty() {
            return None;
        }
        node.id = allocate(&mut self.next);
        node.key = format!("tmux:{}:retained:{}", backend.namespace(), node.id);
        node.parent = None;
        node.agent = None;
        node.detached = true;
        let id = node.id;
        backend.views.insert(
            id,
            View {
                node,
                session,
                panes,
            },
        );
        Some(id)
    }
    /// Forget only a logical descriptor. Native jobs and pending hidden intent survive.
    pub fn forget(&mut self, io: &mut dyn Io, node: Id) -> bool {
        let removed = self
            .backends
            .values_mut()
            .any(|backend| backend.views.remove(&node).is_some());
        if removed {
            self.changed = true;
            io.timer(io.now());
        }
        removed
    }
    /// Restore a single remembered view without importing another hidden window.
    pub fn restore(&mut self, io: &mut dyn Io, node: Id, done: Done<()>) {
        let Some((id, key, session, panes)) = self.backends.iter().find_map(|(id, backend)| {
            backend
                .views
                .get(&node)
                .map(|view| (*id, backend.key.clone(), view.session, view.panes.clone()))
        }) else {
            finish(
                io,
                done,
                Err(gone("Detached tmux work is no longer available")),
            );
            return;
        };
        self.observe(
            io,
            &key,
            Some((session, panes.clone())),
            Box::new(move |mux, io, result| {
                if let Err(error) = result {
                    finish(io, done, Err(error));
                    return;
                }
                let available: BTreeSet<_> = mux.backends[&id]
                    .clients
                    .iter()
                    .filter(|client| client.live())
                    .filter_map(|client| client.snapshot.as_ref())
                    .filter(|snapshot| snapshot.session == session)
                    .flat_map(|snapshot| {
                        snapshot
                            .windows
                            .iter()
                            .flat_map(|window| window.layout.ids())
                    })
                    .collect();
                let result = if panes.is_subset(&available) {
                    Ok(())
                } else {
                    Err(Error {
                        code: "missing",
                        message: "Some detached work no longer exists on the tmux server.".into(),
                    })
                };
                let focus = mux.nodes.iter().find_map(|node| {
                    let loc = mux.location(node.id).ok()?;
                    (loc.backend == id && panes.contains(&loc.pane)).then_some(node.id)
                });
                if let Some(focus) = focus {
                    mux.focus(
                        io,
                        focus,
                        Box::new(move |io, focused| finish(io, done, result.and(focused))),
                    );
                } else {
                    finish(io, done, result);
                }
            }),
        );
    }
    pub(crate) fn placement(&mut self, io: &mut dyn Io, node: Id, place: &Place, done: Done<()>) {
        let valid = self.backends.values().any(|backend| {
            backend.views.get(&node).is_some_and(|view| match place {
                Place::Workspace { label } => label.is_empty() || label == &view.node.name,
                // Its own session's workspace, live or not: after every window was detached
                // the restore reopens the server (c1654cc restoreDetached after disconnect).
                Place::Before { parent, before } => {
                    before.is_none()
                        && backend.ids.get(&format!("${}", view.session)) == Some(parent)
                }
                _ => false,
            })
        });
        if valid {
            self.restore(io, node, done);
        } else {
            finish(
                io,
                done,
                Err(Error {
                    code: "unsupported",
                    message: "Placement unavailable".into(),
                }),
            );
        }
    }
}
