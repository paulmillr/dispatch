use super::*;

#[derive(Default)]
pub(super) struct Screens {
    values: BTreeMap<Id, Screen>,
    unseen: std::collections::BTreeSet<Id>,
    waiting: BTreeMap<Id, Vec<Done<Screen>>>,
}

impl Screens {
    pub(super) fn read(
        &mut self,
        io: &mut dyn Io,
        terminal: Id,
        changed: bool,
        done: Done<Screen>,
    ) {
        if let Some(screen) = self
            .values
            .get(&terminal)
            .filter(|_| !changed || self.unseen.contains(&terminal))
            .cloned()
        {
            self.unseen.remove(&terminal);
            io.defer(Box::new(move |io| done(io, Ok(screen))));
        } else {
            self.waiting.entry(terminal).or_default().push(done);
        }
    }
    pub(super) fn publish(&mut self, io: &mut dyn Io, terminal: Id, screen: Screen) {
        if self.values.get(&terminal) != Some(&screen) {
            self.values.insert(terminal, screen.clone());
            let waiting = self.waiting.remove(&terminal).unwrap_or_default();
            if waiting.is_empty() {
                self.unseen.insert(terminal);
            } else {
                self.unseen.remove(&terminal);
            }
            for done in waiting {
                let screen = screen.clone();
                io.defer(Box::new(move |io| done(io, Ok(screen))));
            }
        }
    }
    /// Drop the last screen (its source stopped); readers waiting keep waiting.
    pub(super) fn forget(&mut self, terminal: Id) {
        self.values.remove(&terminal);
        self.unseen.remove(&terminal);
    }
    /// A reader waits for this terminal's next screen.
    pub(super) fn waiting(&self, terminal: Id) -> bool {
        self.waiting.get(&terminal).is_some_and(|waiting| !waiting.is_empty())
    }
    pub(super) fn close(&mut self, io: &mut dyn Io, terminal: Id, reason: Error) {
        self.values.remove(&terminal);
        self.unseen.remove(&terminal);
        for done in self.waiting.remove(&terminal).unwrap_or_default() {
            let reason = reason.clone();
            io.defer(Box::new(move |io| done(io, Err(reason))));
        }
    }
}
