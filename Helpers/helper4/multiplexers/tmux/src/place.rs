//! Placement moves existing windows or panes; native processes remain owned by tmux. Placement never
//! changes focus: old moves wrote metadata only and selection was the app's own call (c1654cc
//! TmuxCoordinator.swift:1082-1103 then select() :1111-1125), which is Multiplexer::focus here.
use crate::{
    affinity::{Affinity, uuid},
    commands,
    mux::{Tmux, error, finish, gone},
};
use dispatch_helper4_core::api::*;

impl Tmux {
    pub fn place(&mut self, io: &mut dyn Io, node: Id, to: &Place, done: Done<()>) {
        if let Place::Before { parent, before } = to {
            self.r#move(io, node, *parent, *before, done);
            return;
        }
        let prepared = (|| {
            let (loc, target) = self.target(node)?;
            let snapshot = self.backends[&loc.backend].clients[loc.client]
                .snapshot
                .as_ref()
                .unwrap();
            let window = match target.as_bytes()[0] {
                b'@' => crate::snapshot::id(&target, '@')?,
                b'%' => {
                    let pane = crate::snapshot::id(&target, '%')? as u32;
                    snapshot
                        .windows
                        .iter()
                        .find(|window| window.layout.pane(pane).is_some())
                        .ok_or_else(|| gone("Tmux source window closed"))?
                        .id
                }
                _ => return Err(error("Tmux placement requires a window or pane")),
            };
            let commands = match to {
                Place::Restore | Place::Extract(_) => return Err(Error {
                    code: "unsupported", message: "Tmux keeps split terminals in their native window.".into(),
                }),
                Place::Workspace { label } => {
                    if label.is_empty() || label.len() > 4096 {
                        return Err(error("Invalid tmux group name"));
                    }
                    // Every old new-group write names by directory with the label as fallback
                    // (c1654cc TmuxHostMoves.swift:101, TmuxCoordinator.swift:975, :1098).
                    vec![
                        Affinity {
                            group: uuid(io)?,
                            name: label.clone(),
                            order: 0,
                            directory: Some(true),
                            creation: None,
                        }
                        .command(window)?,
                    ]
                }
                Place::Tab { workspace, label } => {
                    let source = self.location(node)?;
                    if label.is_empty() || label.len() > 4096 {
                        return Err(error("Invalid tmux tab name"));
                    }
                    let (backend, session, group) = self
                        .groups
                        .roots
                        .get(workspace)
                        .ok_or_else(|| error("Tmux destination is unavailable"))?;
                    if *backend != loc.backend || *session != snapshot.session {
                        return Err(error("Tmux destination is on another session"));
                    }
                    let members = self.members(loc, group);
                    let first = *members
                        .first()
                        .ok_or_else(|| error("Tmux destination is empty"))?;
                    let order = members
                        .iter()
                        .map(|window| self.affinity(loc, *window).order)
                        .max()
                        .unwrap()
                        + 1;
                    let value = Affinity {
                        name: self.name(loc, first),
                        order,
                        creation: None,
                        ..self.affinity(loc, first).clone()
                    };
                    let option = value.option(&format!("%{}", source.pane), true)?;
                    vec![
                        format!(
                            "break-pane -d -s %{} -t ${}: -n {}",
                            source.pane,
                            snapshot.session,
                            commands::quote(label),
                        ),
                        option,
                    ]
                }
                Place::Split {
                    target,
                    axis,
                    ratio,
                } => {
                    let source = self.location(node)?;
                    let destination = self.location(*target)?;
                    let other = self.backends[&destination.backend].clients[destination.client]
                        .snapshot
                        .as_ref()
                        .unwrap();
                    if source.backend != destination.backend || snapshot.session != other.session {
                        return Err(error("Tmux destination is on another session"));
                    }
                    if source.pane == destination.pane {
                        return Err(error("Tmux source and target panes must be different"));
                    }
                    if !ratio.is_finite() || *ratio <= 0.0 || *ratio >= 1.0 {
                        return Err(error("Invalid tmux split ratio"));
                    }
                    let pane = &other.panes[&destination.pane];
                    let (flag, dimension) = match axis {
                        Axis::Columns => ("-h", pane.width),
                        Axis::Rows => ("-v", pane.height),
                    };
                    let size =
                        (f64::from(dimension.saturating_sub(1)) * (1.0 - ratio)).round() as u32;
                    if size == 0 {
                        return Err(error("Tmux destination is too small"));
                    }
                    vec![format!(
                        "join-pane -d {flag} -l {size} -s %{} -t %{}",
                        source.pane, destination.pane,
                    )]
                }
                Place::Before { .. } => unreachable!(),
            };
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
