use super::Codex;
use crate::channel::failure;
use dispatch_helper4_core::{api::*, json::Value};

impl Codex {
    pub(super) fn resumed(
        &mut self,
        io: &mut dyn Io,
        ui: &mut dyn Ui,
        binding: Binding,
        root: Value<'_>,
    ) {
        if let Some(thread) = root.get("thread") {
            // A pathless chat can attach before the native server reports its rollout. Native
            // items omit question tool results; start the same validated history/follow then.
            if let Some(next) = crate::attach::location(thread, &binding.process)
                .filter(|next| next.session == binding.session && next.transcript.is_some())
                .filter(|next| self.bindings.get(&binding.session)
                    .is_some_and(|known| known.transcript != next.transcript))
            {
                self.bindings.insert(next.session.clone(), next.clone());
                self.reloads.borrow_mut().push(next);
                let now = io.now();
                io.timer(now);
            }
            let mut states = self.states.borrow_mut();
            let state = states.entry(binding.session.clone()).or_default();
            state.model = thread
                .get("model")
                .and_then(Value::string)
                .map(str::to_owned);
            state.effort = thread
                .get("reasoningEffort")
                .and_then(Value::string)
                .map(str::to_owned);
            state.title = crate::native::title(thread);
        }
        let Some(page) = root
            .get("initialTurnsPage")
            .and_then(|page| page.get("data"))
        else {
            return;
        };
        let opened = self
            .forms
            .borrow_mut()
            .entry(binding.session.clone())
            .or_default()
            .resumed(page, &binding.session);
        for interaction in opened {
            ui.update(Update::Interaction {
                binding: binding.clone(),
                interaction,
            });
        }
        let documents = self
            .live
            .borrow_mut()
            .entry(binding.session.clone())
            .or_default()
            .snapshot(&binding.session, page);
        for document in documents {
            self.publish(io, ui, binding.clone(), document.root());
        }
    }
    pub(super) fn publish(
        &mut self,
        io: &mut dyn Io,
        ui: &mut dyn Ui,
        binding: Binding,
        root: Value<'_>,
    ) {
        let Some(params) = root.get("params").filter(|params| {
            params.get("threadId").and_then(Value::string) == Some(&binding.session)
        }) else {
            return;
        };
        let method = root.get("method").and_then(Value::string).unwrap_or("");
        // Core C-COMPACT (old PreCompact/PostCompact status, ChatCoordinator.swift:795-796): a
        // native contextCompaction item runs from its start until it completes.
        let item = params.get("item").and_then(|item| item.get("type"));
        if matches!(method, "item/started" | "item/completed")
            && item.and_then(Value::string) == Some("contextCompaction")
        {
            let mut states = self.states.borrow_mut();
            let state = states.entry(binding.session.clone()).or_default();
            state.compacting = method == "item/started";
            ui.update(Update::State {
                binding: binding.clone(),
                state: state.clone(),
            });
        }
        if method == "item/completed"
            && let Some(item) = params
                .get("item")
                .filter(|item| item.get("type").and_then(Value::string) == Some("commandExecution"))
        {
            self.executed(io, &binding.session, item);
        }
        let side = self.sides.borrow().contains_key(&binding.session);
        let (interactions, declined, mut notice) = {
            let mut forms = self.forms.borrow_mut();
            let pending = forms.entry(binding.session.clone()).or_default();
            pending.side = side;
            let interactions = pending.read(root);
            (
                interactions,
                std::mem::take(&mut pending.outbox),
                pending.notice.take(),
            )
        };
        // Side requests Dispatch answers itself are answered at once, and why is shown, like a
        // reply that could not be written; ChatSideConversation.swift:240-272.
        for bytes in declined {
            let written = self
                .channel(&binding)
                .and_then(|channel| channel.borrow_mut().write(io, bytes));
            if let Err(error) = written {
                notice = Some(error.message);
            }
        }
        if let Some(notice) = notice {
            let mut states = self.states.borrow_mut();
            let state = states.entry(binding.session.clone()).or_default();
            state.attention = Some(notice);
            ui.update(Update::State {
                binding: binding.clone(),
                state: state.clone(),
            });
        }
        for interaction in interactions {
            if let Some(record) = interaction
                .record
                .as_deref()
                .filter(|_| !interaction.questions.is_empty())
            {
                self.follows.want(&binding.session, record);
            }
            ui.update(Update::Interaction {
                binding: binding.clone(),
                interaction,
            });
        }
        let records = self
            .live
            .borrow_mut()
            .entry(binding.session.clone())
            .or_default()
            .read(method, params);
        match records {
            Ok(records) if !records.is_empty() => {
                // c1654cc ChatCoordinator.swift:1134-1144: a live user message answers quoted async forms.
                let answered = records
                    .iter()
                    .filter(|record| record.kind == RecordKind::User)
                    .flat_map(|record| {
                        self.forms
                            .borrow_mut()
                            .entry(binding.session.clone())
                            .or_default()
                            .answered(&record.text)
                    })
                    .collect::<Vec<_>>();
                for interaction in answered {
                    ui.update(Update::Interaction {
                        binding: binding.clone(),
                        interaction,
                    });
                }
                ui.update(Update::Records {
                    binding: binding.clone(),
                    records,
                });
            }
            Err(error) => {
                if let Ok(channel) = self.channel(&binding) {
                    let _ = channel.borrow_mut().close(io, error.clone());
                }
                let mut states = self.states.borrow_mut();
                let state = states.entry(binding.session.clone()).or_default();
                state.busy = false;
                state.attention = Some(error.message);
                ui.update(Update::State {
                    binding: binding.clone(),
                    state: state.clone(),
                });
                return;
            }
            _ => {}
        }
        if method == "thread/queue/changed" {
            self.refresh(io, binding);
        } else if matches!(method, "thread/goal/updated" | "thread/goal/cleared") {
            let value = params.get("goal");
            let goal = value.and_then(crate::native::goal);
            if method == "thread/goal/cleared" || goal.is_some() {
                let mut states = self.states.borrow_mut();
                let state = states.entry(binding.session.clone()).or_default();
                state.goal = goal;
                ui.update(Update::State {
                    binding,
                    state: state.clone(),
                });
            }
        } else if method == "thread/tokenUsage/updated" {
            if let Some(usage) = crate::native::usage(params) {
                let mut states = self.states.borrow_mut();
                let state = states.entry(binding.session.clone()).or_default();
                state.usage = Some(usage);
                ui.update(Update::State {
                    binding,
                    state: state.clone(),
                });
            }
        } else if method == "thread/name/updated" {
            let mut states = self.states.borrow_mut();
            let state = states.entry(binding.session.clone()).or_default();
            state.title = crate::native::title(params);
            ui.update(Update::State {
                binding,
                state: state.clone(),
            });
        } else if method == "thread/settings/updated" {
            if let Some(settings) = params.get("threadSettings") {
                let mut states = self.states.borrow_mut();
                let state = states.entry(binding.session.clone()).or_default();
                crate::native::settings(settings, state);
                ui.update(Update::State {
                    binding,
                    state: state.clone(),
                });
            }
        } else if matches!(method, "turn/started" | "turn/completed" | "thread/status/changed") {
            let mut states = self.states.borrow_mut();
            let state = states.entry(binding.session.clone()).or_default();
            let turn = params.get("turn");
            let live = self.live.borrow();
            let live = live.get(&binding.session);
            state.activity = live.and_then(crate::live::Live::running);
            state.busy = live.and_then(|live| live.active).unwrap_or(state.activity.is_some());
            if method == "turn/completed" {
                state.attention = turn
                    .and_then(|turn| turn.get("error"))
                    .and_then(|error| error.get("message"))
                    .and_then(Value::string)
                    .map(str::to_owned);
            }
            ui.update(Update::State {
                binding,
                state: state.clone(),
            });
        } else if method == "error" {
            let message = params
                .get("error")
                .and_then(|error| error.get("message"))
                .and_then(Value::string)
                .unwrap_or("The Codex request failed");
            let error = failure("native", message);
            let mut states = self.states.borrow_mut();
            let state = states.entry(binding.session.clone()).or_default();
            state.attention = Some(error.message);
            ui.update(Update::State {
                binding,
                state: state.clone(),
            });
        }
    }
}
