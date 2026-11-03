//! Native topology mutations share one ordered command and refresh completion path.
use crate::{
    commands,
    mux::{Tmux, error, finish, gone},
    ops::Location,
};
use dispatch_helper_core::api::*;
use std::time::{Duration, Instant};

#[derive(Clone, Copy)]
pub(crate) struct Divider {
    pub loc: Location,
    pub axis: Axis,
    pub first: crate::topology::Bounds,
    pub low: u32,
    pub high: u32,
}
pub(crate) struct Change {
    pub at: Instant,
    pub ratio: f64,
    pub done: Vec<Done<()>>,
}

impl Tmux {
    pub(crate) fn mutate(
        &mut self,
        io: &mut dyn Io,
        loc: Location,
        commands: Vec<String>,
        count: usize,
        done: Done<()>,
    ) {
        self.steer(loc, true);
        self.request_count(
            io,
            loc,
            count,
            commands,
            // Done follows the read that publishes the change (core: a mutation completes only
            // after its topology went to ui.update). The command already succeeded; a failed
            // read (e.g. the kill ended the session) is that later topology, not this result.
            Box::new(move |mux, io, result| {
                mux.steer(loc, false);
                match result {
                    Err(error) => finish(io, done, Err(error)),
                    Ok(_) => mux.refresh(io, loc, Some(Box::new(move |_, io, _| finish(io, done, Ok(()))))),
                }
            }),
        );
    }

    /// Counts the client's own mutations in flight (`Client::steering`).
    fn steer(&mut self, loc: Location, sent: bool) {
        if let Some(client) = self.backends.get_mut(&loc.backend).and_then(|backend| backend.clients.get_mut(loc.client)) {
            client.steering = if sent { client.steering + 1 } else { client.steering.saturating_sub(1) };
        }
    }

    pub(crate) fn split(&mut self, io: &mut dyn Io, node: Id, ratio: f64, done: Done<()>) {
        if !ratio.is_finite() || !self.dividers.contains_key(&node) {
            finish(io, done, Err(gone("Tmux divider is no longer available")));
            return;
        }
        let at = io.now() + Duration::from_millis(60);
        let change = self.changes.entry(node).or_insert_with(|| Change {
            at,
            ratio,
            done: Vec::new(),
        });
        change.at = at;
        change.ratio = ratio.clamp(0.05, 0.95);
        change.done.push(done);
        io.timer(at);
    }

    pub(crate) fn focus(&mut self, io: &mut dyn Io, node: Id, done: Done<()>) {
        let commands = self.target(node).and_then(|(loc, target)| {
            let snapshot = self.backends[&loc.backend].clients[loc.client]
                .snapshot
                .as_ref()
                .unwrap();
            let (commands, chosen) = match target.as_bytes()[0] {
                // The pane is this client's now, whatever other clients select later (Client::chosen).
                b'%' => {
                    let pane = crate::snapshot::id(&target, '%')? as u32;
                    let window = snapshot
                        .windows
                        .iter()
                        .find(|window| window.layout.pane(pane).is_some())
                        .ok_or_else(|| gone("Tmux pane closed"))?;
                    let commands = vec![
                        format!("select-window -t @{}", window.id),
                        format!("select-pane -t {target}"),
                    ];
                    (commands, Some((window.id, pane)))
                }
                b'@' => (vec![format!("select-window -t {target}")], None),
                _ => {
                    let window = snapshot
                        .windows
                        .iter()
                        .find(|window| Some(window.id) == self.selected(loc, node))
                        .ok_or_else(|| gone("Tmux window closed"))?;
                    (vec![format!("select-window -t @{}", window.id)], None)
                }
            };
            Ok((loc, commands, chosen))
        });
        match commands {
            Ok((loc, commands, chosen)) => {
                if let Some((window, pane)) = chosen {
                    self.backends.get_mut(&loc.backend).unwrap().clients[loc.client].chosen.insert(window, pane);
                }
                let count = commands.len();
                self.mutate(io, loc, commands, count, done);
            }
            Err(error) => finish(io, done, Err(error)),
        }
    }

    pub(crate) fn rename(&mut self, io: &mut dyn Io, node: Id, name: &str, done: Done<()>) {
        if self.groups.roots.contains_key(&node) {
            self.rename_group(io, node, name, done);
            return;
        }
        let commands = self.target(node).and_then(|(loc, target)| {
            let name = commands::quote(&name.replace('#', "##"));
            let command = match target.as_bytes()[0] {
                b'%' => format!("select-pane -t {target} -T {name}"),
                b'@' => format!("rename-window -t {target} {name}"),
                _ => return Err(error("Workspace presentation rename is unavailable")),
            };
            Ok((loc, command))
        });
        match commands {
            Ok((loc, command)) => self.mutate(io, loc, vec![command], 1, done),
            Err(error) => finish(io, done, Err(error)),
        }
    }

    pub(crate) fn zoom(&mut self, io: &mut dyn Io, node: Id, zoomed: bool, done: Done<()>) {
        match self.location(node) {
            Ok(loc) => {
                let resize = format!("resize-pane -Z -t %{}", loc.pane);
                let empty = "display-message -p \"\"";
                let (yes, no) = if zoomed {
                    (empty, resize.as_str())
                } else {
                    (resize.as_str(), empty)
                };
                let command = format!(
                    "if-shell -F -t %{} '#{{window_zoomed_flag}}' {} {}",
                    loc.pane,
                    commands::quote(yes),
                    commands::quote(no)
                );
                self.mutate(io, loc, vec![command], 2, done);
            }
            Err(error) => finish(io, done, Err(error)),
        }
    }
}
