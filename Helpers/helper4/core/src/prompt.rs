//! Native prompts as chat interactions (arch.md "Native prompts", C-PROMPTS): while a chat is
//! open, every screen change asks the harness for the prompt on it and publishes the change.
use crate::api::*;
use std::{
    cell::RefCell,
    collections::{BTreeMap, VecDeque},
    rc::Rc,
};

/// Watched terminals (wire references) and the prompt published for each; a terminal leaves
/// when its last chat observer ends, which also stops its watch.
pub(crate) type Prompts =
    Rc<RefCell<BTreeMap<Id, (Binding, Shared<dyn Harness>, Option<Interaction>, Option<Screen>)>>>;

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
        if let Some((owner, producer, published, screen)) = watched.get_mut(&terminal) {
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
            watched.insert(terminal, (binding.clone(), harness, None, None));
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
                .map(|(owner, _, _, _)| owner.clone())
            else {
                return;
            };
            let failed = screen.is_err();
            if let Some((_, _, _, saved)) = prompts.borrow_mut().get_mut(&terminal) {
                *saved = screen.ok();
            }
            refresh(&prompts, &updates, &binding);
            if failed {
                prompts.borrow_mut().remove(&terminal);
                return;
            }
            watch(io, prompts, updates, mux, terminal, local, true);
        }),
    );
}

/// Provider state can change prompt authority while its observed screen stays unchanged.
/// Called outside provider callbacks, so reevaluation never recursively borrows the harness.
pub(crate) fn refresh(prompts: &Prompts, updates: &Rc<RefCell<VecDeque<Update>>>, binding: &Binding) {
    let screens: Vec<_> = prompts.borrow().iter()
        .filter(|(_, (owner, _, _, _))| crate::dispatch::same(owner, binding))
        .map(|(&terminal, (_, producer, _, screen))| (terminal, producer.clone(), screen.clone()))
        .collect();
    for (terminal, harness, screen) in screens {
        let found = screen.as_ref().and_then(|screen| harness.borrow_mut().prompt(binding, screen));
        // Only a changed state comes back, so its own Update::Prompt refresh stops here.
        if let Some(state) = screen.as_ref().and_then(|screen| harness.borrow_mut().screen_state(binding, screen)) {
            updates.borrow_mut().push_back(Update::State { binding: binding.clone(), state });
        }
        let mut watched = prompts.borrow_mut();
        let Some((_, _, published, _)) = watched.get_mut(&terminal) else { continue };
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
