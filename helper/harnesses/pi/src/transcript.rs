//! Native transcript writes also cover commands with no extension lifecycle event.
use crate::{
    bridge::{self, Shared},
    records::text,
};
use dispatch_helper_core::api::*;
use std::rc::Rc;

pub fn start(runtime: &Shared, io: &mut dyn Io, binding: &Binding) -> Result<(), Error> {
    let old: Vec<_> = runtime
        .borrow()
        .transcripts
        .iter()
        .filter(|(_, previous)| previous.process.pid == binding.process.pid && *previous != binding)
        .map(|(watch, _)| *watch)
        .collect();
    for watch in old {
        runtime.borrow_mut().transcripts.remove(&watch);
        io.unwatch(watch);
    }
    if runtime
        .borrow()
        .transcripts
        .values()
        .any(|previous| previous == binding)
    {
        return Ok(());
    }
    let path = runtime
        .borrow()
        .registrations
        .get(&binding.process.pid)
        .and_then(|registration| registration.path.clone());
    if let Some(path) = path {
        let watch = io
            .watch(&path, false)
            .map_err(|error| bridge::fail("io", error.to_string()))?;
        runtime
            .borrow_mut()
            .transcripts
            .insert(watch, binding.clone());
    }
    Ok(())
}

pub fn event(runtime: &Shared, io: &mut dyn Io, ui: &mut dyn Ui, event: &Event) {
    match event {
        Event::Changed { watch, .. } => {
            let binding = runtime.borrow().transcripts.get(watch).cloned();
            if let Some(binding) = binding.filter(|binding| ui.watching(binding)) {
                refresh(runtime, io, &binding);
            }
        }
        Event::Exit { pid, .. } => stop(runtime, io, *pid),
        _ => {}
    }
}

fn refresh(runtime: &Shared, io: &mut dyn Io, binding: &Binding) {
    if let Some(dirty) = runtime.borrow_mut().refreshing.get_mut(&binding.session) {
        *dirty = true;
        return;
    }
    runtime
        .borrow_mut()
        .refreshing
        .insert(binding.session.clone(), false);
    let saved = runtime.clone();
    let binding = binding.clone();
    bridge::call(
        runtime,
        io,
        &binding.clone(),
        "state",
        Vec::new(),
        Box::new(move |io, result| {
            let document = match result {
                Ok(document) => document,
                Err(_) => {
                    finish(&saved, io, &binding);
                    return;
                }
            };
            let Some(value) = document.root().get("state") else {
                finish(&saved, io, &binding);
                return;
            };
            if text(value, "sessionId") != binding.session {
                finish(&saved, io, &binding);
                return;
            }
            if let Ok(state) = crate::harness::state(value) {
                saved.borrow_mut().pages.push(Update::State {
                    binding: binding.clone(),
                    state,
                });
            }
            saved
                .borrow_mut()
                .states
                .insert(binding.session.clone(), Rc::new(document));
            let next = saved.clone();
            crate::history::read(
                &saved,
                io,
                &binding.clone(),
                None,
                Box::new(move |io, result| {
                    if let Ok(page) = result {
                        next.borrow_mut().pages.push(Update::Records {
                            binding: binding.clone(),
                            records: page.records,
                        });
                        io.timer(io.now());
                    }
                    finish(&next, io, &binding);
                }),
            );
        }),
    );
}

fn finish(runtime: &Shared, io: &mut dyn Io, binding: &Binding) {
    let dirty = runtime
        .borrow_mut()
        .refreshing
        .remove(&binding.session)
        .unwrap_or(false);
    if dirty {
        refresh(runtime, io, binding);
    }
}

pub fn stop(runtime: &Shared, io: &mut dyn Io, pid: u32) {
    let watches: Vec<_> = runtime
        .borrow()
        .transcripts
        .iter()
        .filter(|(_, binding)| binding.process.pid == pid)
        .map(|(watch, binding)| (*watch, binding.session.clone()))
        .collect();
    for (watch, session) in watches {
        runtime.borrow_mut().transcripts.remove(&watch);
        runtime.borrow_mut().refreshing.remove(&session);
        io.unwatch(watch);
    }
}
