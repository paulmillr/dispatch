//! The existing extension has no event channel; refresh only open chat views.
use crate::{
    bridge::{self, Shared},
    records::text,
};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json, Value},
};
use std::{
    rc::Rc,
    time::{Duration, Instant},
};

pub struct Poll {
    pub binding: Binding,
    due: Instant,
    pending: bool,
    leaf: String,
    busy: bool,
}

pub fn start(runtime: &Shared, io: &mut dyn Io, binding: &Binding) {
    let mut runtime = runtime.borrow_mut();
    runtime.legacy.retain(|_, poll| {
        poll.binding.process.pid != binding.process.pid || poll.binding == *binding
    });
    if runtime.legacy.contains_key(&binding.session) {
        return;
    }
    let value = runtime
        .states
        .get(&binding.session)
        .and_then(|document| document.root().get("state"));
    let due = io.now() + Duration::from_millis(350);
    let poll = Poll {
        binding: binding.clone(),
        due,
        pending: false,
        leaf: value.map(|value| text(value, "leafId")).unwrap_or_default(),
        busy: value
            .and_then(|value| value.get("busy"))
            .and_then(Value::boolean)
            .unwrap_or(false),
    };
    runtime.legacy.insert(binding.session.clone(), poll);
    io.timer(due);
}

pub fn tick(runtime: &Shared, io: &mut dyn Io, ui: &mut dyn Ui) {
    runtime
        .borrow_mut()
        .legacy
        .retain(|_, poll| ui.watching(&poll.binding));
    let due: Vec<_> = runtime
        .borrow()
        .legacy
        .values()
        .filter(|poll| !poll.pending && poll.due <= io.now())
        .map(|poll| poll.binding.clone())
        .collect();
    for binding in due {
        runtime
            .borrow_mut()
            .legacy
            .get_mut(&binding.session)
            .unwrap()
            .pending = true;
        let saved = runtime.clone();
        bridge::call(
            runtime,
            io,
            &binding.clone(),
            "state",
            Vec::new(),
            Box::new(move |io, result| {
                let document = match result {
                    Ok(document) => Rc::new(document),
                    Err(_) => {
                        saved.borrow_mut().legacy.remove(&binding.session);
                        return;
                    }
                };
                let Some(value) = document.root().get("state") else {
                    saved.borrow_mut().legacy.remove(&binding.session);
                    return;
                };
                let changed = {
                    let mut runtime = saved.borrow_mut();
                    let Some(poll) = runtime.legacy.get_mut(&binding.session) else {
                        return;
                    };
                    let leaf = text(value, "leafId");
                    let busy = value.get("busy").and_then(Value::boolean).unwrap_or(false);
                    let changed = poll.leaf != leaf || poll.busy && !busy;
                    poll.leaf = leaf;
                    poll.busy = busy;
                    runtime
                        .states
                        .insert(binding.session.clone(), document.clone());
                    changed
                };
                if let Ok(bytes) = json::write(&Data::Object(vec![
                    ("event", Data::String("state")),
                    ("sessionId", Data::String(&binding.session)),
                    ("value", Data::Value(value)),
                ])) && let Ok(event) = Json::parse(&bytes)
                {
                    saved.borrow_mut().updates.push((binding.clone(), event));
                }
                if changed {
                    let next = saved.clone();
                    crate::history::read(
                        &saved,
                        io,
                        &binding.clone(),
                        None,
                        Box::new(move |io, result| {
                            if next.borrow().legacy.contains_key(&binding.session)
                                && let Ok(page) = result
                            {
                                next.borrow_mut().pages.push(Update::Records {
                                    binding: binding.clone(),
                                    records: page.records,
                                });
                            }
                            finish(&next, io, &binding);
                        }),
                    );
                } else {
                    finish(&saved, io, &binding);
                }
            }),
        );
    }
}

fn finish(runtime: &Shared, io: &mut dyn Io, binding: &Binding) {
    if let Some(poll) = runtime.borrow_mut().legacy.get_mut(&binding.session) {
        poll.pending = false;
        poll.due = io.now() + Duration::from_millis(350);
        io.timer(poll.due);
    }
}
