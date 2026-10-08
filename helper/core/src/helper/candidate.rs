//! Setup metadata never becomes a binding and cannot authorize chat input.
use super::*;

pub(crate) type Candidate = (usize, Binding, Error);
pub(crate) type Shared = Rc<RefCell<Candidates>>;

#[derive(Default)]
pub(crate) struct Candidates {
    pub found: BTreeMap<Id, Candidate>,
    pub observed: BTreeMap<Id, Process>,
    pub dirty: BTreeSet<Id>,
    changed: BTreeSet<Id>,
}

impl DispatchHelper {
    pub(crate) fn candidate(&self, terminal: Id) -> Option<Candidate> {
        let nodes = self.nodes.borrow();
        let (_, node) = nodes.get(&terminal)?;
        let candidate = self.candidates.borrow().found.get(&terminal)?.clone();
        (node.agent.is_none() && node.tty == Some(candidate.1.process.tty)).then_some(candidate)
    }

    pub(super) fn candidates(&self, io: &mut dyn Io, replies: &Replies, observers: &[Observer]) {
        let mut candidates = self.candidates.borrow_mut();
        candidates
            .observed
            .retain(|terminal, _| self.nodes.borrow().contains_key(terminal));
        candidates.found.retain(|terminal, (_, binding, _)| {
            self.nodes.borrow().get(terminal).is_some_and(|(_, node)| {
                node.agent.is_none() && node.tty == Some(binding.process.tty)
            })
        });
        for terminal in std::mem::take(&mut candidates.changed) {
            let body = crate::encode::notify(
                "agent.changed",
                &[("terminal", &terminal), ("summary", &Summary::default())],
            );
            for (fd, id, scope) in observers {
                let watching = match scope {
                    Scope::Backend(index) => *index == (terminal >> 48) as usize,
                    Scope::Terminal(id) | Scope::Events(id) => *id == terminal,
                    _ => false,
                };
                if watching {
                    replies
                        .borrow_mut()
                        .push_back((*fd, wire::Kind::Notify, *id, body.clone()));
                }
            }
        }
        let dirty = std::mem::take(&mut candidates.dirty);
        drop(candidates);
        for terminal in dirty {
            let process = self.candidates.borrow().observed.get(&terminal).cloned();
            if self
                .candidates
                .borrow_mut()
                .found
                .remove(&terminal)
                .is_some()
            {
                self.candidates.borrow_mut().changed.insert(terminal);
            }
            let Some(process) = process else { continue };
            if !self
                .nodes
                .borrow()
                .get(&terminal)
                .is_some_and(|(_, node)| node.agent.is_none() && node.tty == Some(process.tty))
            {
                continue;
            }
            let matching: Vec<_> = self
                .harnesses
                .iter()
                .enumerate()
                .filter(|(_, harness)| harness.borrow().matches(&process))
                .collect();
            let [(index, harness)] = matching.as_slice() else {
                continue;
            };
            let index = *index;
            let (saved, nodes) = (self.candidates.clone(), self.nodes.clone());
            harness.borrow_mut().candidate(
                io,
                &process.clone(),
                deferred(Box::new(move |_, result| {
                    let mut saved = saved.borrow_mut();
                    if saved.observed.get(&terminal) != Some(&process)
                        || !nodes.borrow().get(&terminal).is_some_and(|(_, node)| {
                            node.agent.is_none() && node.tty == Some(process.tty)
                        })
                    {
                        return;
                    }
                    if let Ok(Some(error)) = result {
                        let binding = Binding {
                            session: String::new(),
                            transcript: None,
                            process,
                        };
                        saved.found.insert(terminal, (index, binding, error));
                        saved.changed.insert(terminal);
                    }
                })),
            );
        }
    }
}
