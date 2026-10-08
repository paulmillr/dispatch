use crate::api::*;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    time::{Duration, Instant},
};

/// Old settle bound: an unchanged menu after one second is the endpoint of a clamped list;
/// c1654cc Dispatch/Chat/ChatModelPicker.swift:487-499.
const SETTLE: Duration = Duration::from_secs(1);
/// Old picker sampling interval: the screen is read again every 40 ms between changes;
/// c1654cc Dispatch/Chat/ChatModelPicker.swift:489-496.
const SAMPLE: Duration = Duration::from_millis(40);

/// One menu walk; taken by whichever screen arrives first.
struct Walk {
    // Request admission is checked again after async boundaries, not just when replying.
    active: Option<Rc<Cell<bool>>>,
    mux: Shared<dyn Multiplexer>,
    harness: Shared<dyn Harness>,
    terminal: Id,
    binding: Rc<Binding>,
    goal: Rc<Goal>,
    steps: u32,
    ask: Ask,
    done: Done<Menu>,
    /// When the last key (or the walk) started; the settle bound counts from here.
    keyed: Instant,
    /// A screen was delivered at least once.
    seen: bool,
}
type Pending = Rc<RefCell<Option<Walk>>>;

/// The one screen -> harness -> keys loop shared by tmux, herdr and native: read the screen,
/// ask the harness for the next step, type its keys after the pane check, ask the user when the
/// harness pauses, repeat on the next screen change or the unchanged screen after `SETTLE`,
/// at most `steps` times; c1654cc Dispatch/Chat/ChatModelPicker.swift:72, 132, 217, 231-248, 474-499, 611-636.
#[allow(clippy::too_many_arguments)]
pub fn drive(
    io: &mut dyn Io,
    active: Option<Rc<Cell<bool>>>,
    mux: Shared<dyn Multiplexer>,
    harness: Shared<dyn Harness>,
    terminal: Id,
    binding: Rc<Binding>,
    goal: Rc<Goal>,
    steps: u32,
    changed: bool,
    ask: Ask,
    done: Done<Menu>,
) {
    let walk = Walk {
        active,
        mux,
        harness,
        terminal,
        binding,
        goal,
        steps,
        ask,
        done,
        keyed: io.now(),
        seen: false,
    };
    next(io, walk, changed);
}

fn next(io: &mut dyn Io, walk: Walk, changed: bool) {
    if walk.active.as_ref().is_some_and(|active| !active.get()) {
        return (walk.done)(io, Err(Error { code: "cancelled", message: String::new() }));
    }
    let (mux, terminal, settle) = (walk.mux.clone(), walk.terminal, walk.keyed + SETTLE);
    if io.now() >= settle {
        if !walk.seen {
            // No screen was ever published for this terminal: nothing can be verified. The old
            // app failed such a send at once (no terminal view).
            return (walk.done)(
                io,
                Err(Error {
                    code: "terminal_unavailable",
                    message:
                        "The terminal shows no screen to act on. Open the terminal to continue."
                            .into(),
                }),
            );
        }
        // The settle bound passed without a key: the current screen is final (a clamped end).
        return screen(
            io,
            mux,
            terminal,
            false,
            true,
            Rc::new(RefCell::new(Some(walk))),
        );
    }
    let pending: Pending = Rc::new(RefCell::new(Some(walk)));
    let waiting = pending.clone();
    // Without timed callbacks the walk keeps waiting for the next change only.
    let _ = io.after(
        (io.now() + SAMPLE).min(settle),
        Box::new(move |io| {
            if let Some(walk) = waiting.borrow_mut().take() {
                // A sample: the current screen again, or the settle verdict at the bound.
                next(io, walk, false);
            }
        }),
    );
    screen(io, mux, terminal, changed, false, pending);
}

fn screen(
    io: &mut dyn Io,
    mux: Shared<dyn Multiplexer>,
    terminal: Id,
    changed: bool,
    settled: bool,
    pending: Pending,
) {
    mux.borrow_mut().screen(
        io,
        terminal,
        changed,
        deferred(Box::new(move |io, screen| {
            if let Some(walk) = pending.borrow_mut().take() {
                step(io, walk, screen, settled);
            }
        })),
    );
}

fn step(io: &mut dyn Io, mut walk: Walk, screen: Result<Screen, Error>, settled: bool) {
    if walk.active.as_ref().is_some_and(|active| !active.get()) {
        return (walk.done)(io, Err(Error { code: "cancelled", message: String::new() }));
    }
    let step = match screen {
        Ok(screen) => {
            walk.seen = true;
            walk.harness
                .borrow_mut()
                .menu(io, &walk.binding, &walk.goal, &screen, settled)
        }
        Err(error) => Step::Fail(error),
    };
    match step {
        Step::Done(menu) => (walk.done)(io, Ok(menu)),
        Step::Fail(error) => (walk.done)(io, Err(error)),
        // Samples between changes are free; a wait past the settle bound costs a step.
        Step::Wait if !settled => next(io, walk, true),
        _ if walk.steps == 0 => (walk.done)(
            io,
            Err(Error {
                code: "deadline",
                message: String::new(),
            }),
        ),
        Step::Wait => {
            walk.steps -= 1;
            walk.keyed = io.now();
            next(io, walk, true);
        }
        Step::Submit(input) => {
            keys(io, walk.active, walk.mux, walk.harness, walk.terminal, walk.binding, input,
                Box::new(move |io, result| (walk.done)(io, result.map(|()| Menu::default()))));
        }
        Step::Keys(keys) => {
            walk.steps -= 1;
            resume(io, walk, Ok(Sent::Keys(keys)));
        }
        Step::Ask(interaction) => {
            walk.steps -= 1;
            let user = walk.ask.clone();
            user(
                io,
                interaction,
                deferred(Box::new(move |io, sent| resume(io, walk, sent))),
            );
        }
    }
}

/// Type keys (from a step or the user's answer) after the pane check, then continue the walk.
fn resume(io: &mut dyn Io, walk: Walk, sent: Result<Sent, Error>) {
    if walk.active.as_ref().is_some_and(|active| !active.get()) {
        return (walk.done)(io, Err(Error { code: "cancelled", message: String::new() }));
    }
    match sent {
        Err(error) => (walk.done)(io, Err(error)),
        Ok(Sent::Native { .. }) => {
            let mut walk = walk;
            walk.keyed = io.now();
            next(io, walk, true)
        }
        Ok(Sent::Keys(input)) => {
            let (mux, harness, terminal, binding) = (
                walk.mux.clone(),
                walk.harness.clone(),
                walk.terminal,
                walk.binding.clone(),
            );
            keys(
                io,
                walk.active.clone(),
                mux,
                harness,
                terminal,
                binding,
                input,
                deferred(Box::new(move |io, typed| match typed {
                    Ok(()) => {
                        let mut walk = walk;
                        walk.keyed = io.now();
                        next(io, walk, true)
                    }
                    Err(error) => (walk.done)(io, Err(error)),
                })),
            );
        }
    }
}

/// Every typed path (menus, sends, wire keys) types `input` one element at a time. Before
/// each element the harness re-verifies the captured conversation, then the mux types it
/// with its own pane check; the next starts after the previous completed. Old app: paste,
/// ownership recheck, then Return as its own key event (c1654cc TerminalView+Input.swift:
/// 74-83); old herdr_submit.rs:153-159 rechecked the conversation before every partial write.
/// A failure after something was typed is `uncertain`.
pub(crate) fn keys(
    io: &mut dyn Io,
    active: Option<Rc<Cell<bool>>>,
    mux: Shared<dyn Multiplexer>,
    harness: Shared<dyn Harness>,
    terminal: Id,
    binding: Rc<Binding>,
    input: Vec<Input>,
    done: Done<()>,
) {
    next_key(
        io,
        active,
        mux,
        harness,
        terminal,
        binding,
        input.into(),
        false,
        done,
    );
}

#[allow(clippy::too_many_arguments)]
fn next_key(
    io: &mut dyn Io,
    active: Option<Rc<Cell<bool>>>,
    mux: Shared<dyn Multiplexer>,
    harness: Shared<dyn Harness>,
    terminal: Id,
    binding: Rc<Binding>,
    mut input: std::collections::VecDeque<Input>,
    typed: bool,
    done: Done<()>,
) {
    let Some(first) = input.pop_front() else {
        return deferred(done)(io, Ok(()));
    };
    let failed = move |io: &mut dyn Io, error: Error, done: Done<()>| {
        let code = if typed { "uncertain" } else { error.code };
        done(
            io,
            Err(Error {
                code,
                message: error.message,
            }),
        )
    };
    if active.as_ref().is_some_and(|active| !active.get()) {
        return failed(io, Error { code: "cancelled", message: String::new() }, done);
    }
    let process = binding.process.clone();
    let checker = harness.clone();
    checker.borrow_mut().identify(
        io,
        &process,
        None,
        deferred(Box::new(move |io, current| match current {
            _ if active.as_ref().is_some_and(|active| !active.get()) => {
                failed(io, Error { code: "cancelled", message: String::new() }, done)
            }
            // A provisional binding (session "") is still the destination once its own
            // process reports the real session (Binding.session).
            Ok(Some(current))
                if crate::dispatch::same(&current, &binding)
                    || (binding.session.is_empty()
                        && current.process.pid == binding.process.pid
                        && current.process.start == binding.process.start) =>
            {
                let typist = mux.clone();
                typist.borrow_mut().keys(
                    io,
                    terminal,
                    &binding.process.clone(),
                    &[first],
                    Box::new(move |io, result| match result {
                        Ok(()) => next_key(io, active, mux, harness, terminal, binding, input, true, done),
                        Err(error) => failed(io, error, done),
                    }),
                );
            }
            Err(error) => failed(io, error, done),
            _ => failed(
                io,
                Error {
                    code: "destination_changed",
                    message: String::new(),
                },
                done,
            ),
        })),
    );
}
