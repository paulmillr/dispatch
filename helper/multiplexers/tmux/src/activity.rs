//! Last-activity times of published windows (feature terminals.activity): tmux keeps one per
//! window, `#{window_activity}` (whole seconds), and none per pane. Asked only when a client
//! names the feature, through a control client the backend already has.
use crate::{
    mux::{Tmux, finish},
    ops::Location,
};
use dispatch_helper_core::api::*;
use std::{cell::RefCell, rc::Rc};

/// The one command each backend runs: every window of the server with its session.
pub(crate) const COMMAND: &str = "list-windows -a -F \"#{session_id}|#{window_id}|#{window_activity}\"";

/// `$session|@window|seconds` lines as (tab node key within the backend, Unix ms). Lines that
/// are not that shape (an older tmux without the format) are skipped.
pub(crate) fn parse(lines: &crate::control::Lines) -> Vec<(String, u64)> {
    lines
        .iter()
        .filter_map(|line| {
            let text = String::from_utf8_lossy(line);
            let [session, window, seconds] = crate::snapshot::fields(&text).ok()?;
            let session = crate::snapshot::id(session, '$').ok()?;
            let window = crate::snapshot::id(window, '@').ok()?;
            let seconds: u64 = seconds.parse().ok().filter(|seconds| *seconds > 0)?;
            Some((format!("${session}:@{window}"), seconds.checked_mul(1000)?))
        })
        .collect()
}

impl Tmux {
    pub(crate) fn activity(&mut self, io: &mut dyn Io, done: Done<Vec<(Id, u64)>>) {
        let locations: Vec<Location> = self
            .backends
            .iter()
            .filter(|(_, backend)| !backend.suspended() && backend.opening == 0)
            .filter_map(|(&backend, state)| {
                let client = state
                    .clients
                    .iter()
                    .position(|client| !client.ended && !client.leaving && client.snapshot.is_some())?;
                Some(Location { backend, client, pane: 0 })
            })
            .collect();
        if locations.is_empty() {
            return finish(io, done, Ok(Vec::new()));
        }
        let rows: Rc<RefCell<Vec<(Id, u64)>>> = Rc::default();
        let remaining = Rc::new(std::cell::Cell::new(locations.len()));
        let done = Rc::new(RefCell::new(Some(done)));
        for location in locations {
            let (rows, remaining, done) = (rows.clone(), remaining.clone(), done.clone());
            self.request(
                io,
                location,
                vec![COMMAND.to_owned()],
                Box::new(move |mux, io, result| {
                    // A backend that cannot answer (its client just ended) has no times to give.
                    if let (Ok(batch), Some(backend)) = (result, mux.backends.get(&location.backend))
                        && let Some(lines) = batch.first()
                    {
                        let published = |id: &Id| mux.nodes.iter().any(|node| node.id == *id && !node.detached);
                        rows.borrow_mut().extend(parse(lines).into_iter().filter_map(|(key, time)| {
                            backend.ids.get(&key).filter(|id| published(id)).map(|id| (*id, time))
                        }));
                    }
                    remaining.set(remaining.get() - 1);
                    if remaining.get() == 0
                        && let Some(done) = done.borrow_mut().take()
                    {
                        finish(io, done, Ok(std::mem::take(&mut *rows.borrow_mut())));
                    }
                }),
            );
        }
    }
}

#[cfg(test)]
#[path = "activity.test.rs"]
mod tests;
