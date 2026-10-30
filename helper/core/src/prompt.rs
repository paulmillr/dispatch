//! Native prompts as chat interactions (arch.md "Native prompts", C-PROMPTS): while a chat is
//! open, every screen change asks the harness for the prompt on it and publishes the change.
use crate::api::*;
use std::{
    cell::RefCell,
    collections::{BTreeMap, VecDeque},
    rc::Rc,
    time::Duration,
};

/// Watched terminals (wire references) and the prompt published for each, the screen it was read from, and whether
/// that screen is sampled (`sample`); a terminal leaves when its last chat observer ends, which also stops its watch.
pub(crate) type Prompts =
    Rc<RefCell<BTreeMap<Id, (Binding, Shared<dyn Harness>, Option<Interaction>, Option<Screen>, bool)>>>;

/// While a native prompt is open on a screen the helper reads itself (`Multiplexer::hosted`: tmux and herdr screens
/// are taken once their output settled), that screen is also read as it is now this often, so the prompt leaves Chat
/// as soon as the terminal stops showing it, as with the app's publications (TerminalBackend.swift
/// ScreenPublication.interval). Chat input waits for a prompt to close: a send right after answering one would
/// otherwise be queued behind it.
const SAMPLE: Duration = Duration::from_millis(33);

/// Watch `terminal` unless it already is; `local` is the mux's own id.
#[allow(clippy::too_many_arguments)]
pub(crate) fn start(
    io: &mut dyn Io,
    prompts: &Prompts,
    updates: &Rc<RefCell<VecDeque<Update>>>,
    mux: Shared<dyn Multiplexer>,
    harness: Shared<dyn Harness>,
    terminal: Id,
    local: Id,
    binding: Binding,
) {
    let fresh = {
        let mut watched = prompts.borrow_mut();
        if let Some((owner, producer, published, screen, _)) = watched.get_mut(&terminal) {
            if !crate::dispatch::same(owner, &binding) {
                *screen = None;
                if let Some(mut gone) = published.take() {
                    gone.questions.clear();
                    updates.borrow_mut().push_back(Update::Interaction {
                        binding: owner.clone(),
                        interaction: gone,
                    });
                }
            }
            *owner = binding.clone();
            *producer = harness;
            false
        } else {
            watched.insert(terminal, (binding.clone(), harness, None, None, false));
            true
        }
    };
    if fresh {
        watch(
            io,
            prompts.clone(),
            updates.clone(),
            mux,
            terminal,
            local,
            false,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn watch(
    io: &mut dyn Io,
    prompts: Prompts,
    updates: Rc<RefCell<VecDeque<Update>>>,
    mux: Shared<dyn Multiplexer>,
    terminal: Id,
    local: Id,
    changed: bool,
) {
    let viewer = mux.clone();
    viewer.borrow_mut().screen(
        io,
        local,
        changed,
        Box::new(move |io, screen| {
            // A provisional conversation may have acquired its real session since this
            // screen read started. Publish into the current observer's scope.
            let Some(binding) = prompts
                .borrow()
                .get(&terminal)
                .map(|(owner, _, _, _, _)| owner.clone())
            else {
                return;
            };
            let failed = screen.is_err();
            if let Some((_, _, _, saved, _)) = prompts.borrow_mut().get_mut(&terminal) {
                *saved = screen.ok();
            }
            refresh(&prompts, &updates, &binding);
            if failed {
                prompts.borrow_mut().remove(&terminal);
                return;
            }
            sample(io, prompts.clone(), updates.clone(), mux.clone(), terminal, local, false);
            watch(io, prompts, updates, mux, terminal, local, true);
        }),
    );
}

/// Read `terminal`'s screen now every `SAMPLE` while a prompt is published for it and its multiplexer reads it
/// itself; one sampler per terminal (`running`: this is it, rearming).
fn sample(
    io: &mut dyn Io,
    prompts: Prompts,
    updates: Rc<RefCell<VecDeque<Update>>>,
    mux: Shared<dyn Multiplexer>,
    terminal: Id,
    local: Id,
    running: bool,
) {
    let hosted = mux.borrow().hosted(local);
    {
        let mut watched = prompts.borrow_mut();
        let Some((_, _, published, _, sampling)) = watched.get_mut(&terminal) else { return };
        if *sampling && !running {
            return;
        }
        *sampling = published.is_some() && hosted;
        if !*sampling {
            return;
        }
    }
    let at = io.now() + SAMPLE;
    let (again, stop) = (prompts.clone(), prompts.clone());
    let read = Box::new(move |io: &mut dyn Io| {
        let viewer = mux.clone();
        viewer.borrow_mut().screen(
            io,
            local,
            false,
            Box::new(move |io, screen| {
                let binding = {
                    let mut watched = again.borrow_mut();
                    let Some((owner, _, _, saved, _)) = watched.get_mut(&terminal) else { return };
                    match screen {
                        Ok(screen) if saved.as_ref() != Some(&screen) => {
                            *saved = Some(screen);
                            Some(owner.clone())
                        }
                        _ => None,
                    }
                };
                if let Some(binding) = binding {
                    refresh(&again, &updates, &binding);
                }
                sample(io, again, updates, mux, terminal, local, true);
            }),
        );
    });
    if io.after(at, read).is_err()
        && let Some((_, _, _, _, sampling)) = stop.borrow_mut().get_mut(&terminal)
    {
        *sampling = false;
    }
}

/// Provider state can change prompt authority while its observed screen stays unchanged.
/// Called outside provider callbacks, so reevaluation never recursively borrows the harness.
pub(crate) fn refresh(prompts: &Prompts, updates: &Rc<RefCell<VecDeque<Update>>>, binding: &Binding) {
    let screens: Vec<_> = prompts.borrow().iter()
        .filter(|(_, (owner, _, _, _, _))| crate::dispatch::same(owner, binding))
        .map(|(&terminal, (_, producer, _, screen, _))| (terminal, producer.clone(), screen.clone()))
        .collect();
    for (terminal, harness, screen) in screens {
        let found = screen.as_ref().and_then(|screen| harness.borrow_mut().prompt(binding, screen));
        // Only a changed state comes back, so its own Update::Prompt refresh stops here.
        if let Some(state) = screen.as_ref().and_then(|screen| harness.borrow_mut().screen_state(binding, screen)) {
            updates.borrow_mut().push_back(Update::State { binding: binding.clone(), state });
        }
        let mut watched = prompts.borrow_mut();
        let Some((_, _, published, _, _)) = watched.get_mut(&terminal) else { continue };
        if *published == found { continue; }
        let mut updates = updates.borrow_mut();
        if let Some(mut gone) = published.take().filter(|old| found.as_ref().is_none_or(|new| new.id != old.id)) {
            gone.questions.clear();
            updates.push_back(Update::Interaction { binding: binding.clone(), interaction: gone });
        }
        if let Some(prompt) = &found {
            updates.push_back(Update::Interaction { binding: binding.clone(), interaction: prompt.clone() });
        }
        *published = found;
    }
}

#[cfg(test)]
#[path = "prompt.test.rs"]
mod tests;
