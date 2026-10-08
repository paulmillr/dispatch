//! Fresh native activity and registration notifications; System owns all IO.
use super::*;

impl Claude {
    pub(super) fn current(&self, binding: &Binding) -> Result<State, Error> {
        let key = key(binding);
        let cache = self.cache.get(&Source::Live(key.clone()));
        let startup = self.startup.get(&key);
        let registration = self.sessions.get(&key);
        if cache.is_none() && startup.is_none() && registration.is_none() {
            return Err(error("state", "Claude state is not loaded"));
        }
        let mut state = cache.map(|c| c.parser.state.clone()).unwrap_or_default();
        if let Some(registration) = registration {
            state.busy = registration.status != "idle";
            state.activity = Some(registration.status.clone());
            // Native dialog kind while Terminal waits (pi reports its prompt kind the same way).
            state.dialog = registration.waiting.clone();
            state.title = registration.name.clone().or(state.title);
            state.version = registration.version.clone();
            // c1654cc ChatCommands.swift refreshCommandInteraction (claude): a native prompt
            // without a pending card, still there after the hook guard, needs Terminal.
            state.attention = registration
                .waiting
                .as_deref()
                .and_then(|reason| match reason {
                    "permission prompt" => Some("Claude needs permission in Terminal."),
                    "input needed" => Some("Claude is waiting for an answer in Terminal."),
                    "dialog open" => Some("Claude has a dialog open in Terminal."),
                    _ => None,
                })
                .filter(|_| {
                    self.waits.get(&key) == Some(&None)
                        && self.interactions.cards(binding).is_empty()
                })
                .map(str::to_owned);
        }
        // c1654cc: the picker's confirmation sets the model; only a newer model call replaces it.
        if let Some((after, model, effort)) = self.chosen.get(&key)
            && cache.is_none_or(|c| c.parser.configured == *after)
        {
            state.model = Some(model.clone());
            state.effort = effort.clone().or(state.effort);
        }
        if state.model.is_none() && cache.is_none_or(|c| c.empty) {
            if let Some(startup) = startup {
                state.model = state.model.or_else(|| startup.model.clone());
                state.effort = startup.effort.clone();
            }
        }
        state.model_label = state.model.as_ref().and_then(|model| {
            self.labels
                .get(&key)
                .and_then(|labels| labels.get(model))
                .cloned()
        });
        Ok(state)
    }

    pub(super) fn probe(&mut self, io: &mut dyn Io, request: Observation, job: Job) {
        match io.submit(job) {
            Ok(work) => {
                self.probes.insert(work, request);
            }
            Err(error) => {
                request
                    .consumer
                    .complete(io, None, Err(crate::history::error("io", error)))
            }
        }
    }

    pub(super) fn observe(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        done: Option<Done<State>>,
    ) {
        let probe = Probe::new(
            binding.process.clone(),
            Some(binding.session.clone()),
            self.home.clone(),
            self.remote,
        );
        let consumer = Consumer::State {
            binding: binding.clone(),
            done,
        };
        self.start(io, probe, consumer);
    }

    pub(super) fn start(&mut self, io: &mut dyn Io, probe: Probe, consumer: Consumer) {
        let serial = self.newest.entry(probe.process.pid).or_default();
        *serial += 1;
        let request = Observation {
            serial: *serial,
            probe,
            consumer,
        };
        match request.probe.job() {
            Ok(job) => self.probe(io, request, job),
            Err(error) => request.consumer.complete(io, None, Err(error)),
        }
    }

    pub(super) fn registry(&mut self, io: &mut dyn Io, session: &Session) {
        let watches = self
            .registrations
            .iter()
            .filter_map(|(watch, binding)| {
                (binding.process.pid == session.binding.process.pid && *binding != session.binding)
                    .then_some(*watch)
            })
            .collect::<Vec<_>>();
        for watch in watches {
            io.unwatch(watch);
            self.registrations.remove(&watch);
        }
        if self
            .registrations
            .values()
            .any(|binding| *binding == session.binding)
        {
            return;
        }
        if let Ok(watch) = io.watch(&session.registry, false) {
            self.registrations.insert(watch, session.binding.clone());
        }
    }
    /// Start the old 3 s guard when a native prompt starts waiting (none once hooks are
    /// disabled); a guard that just passed becomes attention on this fresh observation.
    pub(super) fn wait(&mut self, io: &mut dyn Io, binding: &Binding) {
        let key = key(binding);
        // A live hook owns the prompt. As in the old app, any native fallback
        // gets a fresh guard after that authority closes, even on an unchanged screen.
        if !self.interactions.cards(binding).is_empty()
            || self.sessions.get(&key).is_none_or(|s| s.waiting.is_none()) {
            self.waits.remove(&key);
            self.due.remove(&key);
            return;
        }
        if self.due.remove(&key) {
            self.waits.insert(key, None);
        } else if !self.waits.contains_key(&key) {
            let deadline = (!self.interactions.revoked())
                .then(|| io.now() + std::time::Duration::from_secs(3));
            if let Some(deadline) = deadline {
                io.timer(deadline);
            }
            self.waits.insert(key, deadline);
        }
    }

    /// Re-observe every prompt whose guard passed; publication follows the observation.
    pub(super) fn guard(&mut self, io: &mut dyn Io, at: std::time::Instant) {
        let due = self
            .waits
            .iter()
            .filter(|(_, deadline)| deadline.is_some_and(|d| d <= at))
            .map(|(key, _)| key.clone())
            .collect::<Vec<_>>();
        for key in due {
            if let Some(binding) = self.sessions.get(&key).map(|s| s.binding.clone()) {
                self.due.insert(key);
                self.observe(io, &binding, None);
            }
        }
    }
}
