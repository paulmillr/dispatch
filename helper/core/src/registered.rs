//! One trait adapter: native effects go back to the part that submitted them.
use crate::api::*;
use std::{path::Path, process::Command, rc::Rc};

pub(crate) struct Registered<T> {
    pub part: T,
    pub section: String,
    /// Harnesses only: hooks are off (installation.install enabled:false, decisions-1002).
    pub muted: Option<Box<dyn Fn() -> bool>>,
    pub permitted: Rc<dyn Fn(&str) -> bool>,
}

fn denied() -> Error {
    Error {
        code: "permission_denied",
        message: "This SSH feature is disabled".into(),
    }
}

fn returned<T: 'static>(caller: String, done: Done<T>) -> Done<T> {
    Box::new(move |io, result| {
        let callee = io.section(&caller);
        deferred(done)(io, result);
        io.section(&callee);
    })
}

// Each call names only its original API arguments; the routing rule is shared.
macro_rules! calls {
    ($(fn $method:ident($($name:ident: $ty:ty),*) -> $result:ty;)*) => {$ (
        fn $method(&mut self, io: &mut dyn Io, $($name: $ty,)* done: Done<$result>) {
            let permitted = self.permitted.clone();
            if !permitted(stringify!($method)) {
                deferred(done)(io, Err(denied()));
                return;
            }
            let previous = io.section(&self.section);
            let caller = previous.clone();
            self.part.$method(io, $($name,)* returned(caller, Box::new(move |io, result| {
                done(io, if permitted(stringify!($method)) { result } else { Err(denied()) });
            })));
            io.section(&previous);
        }
    )*};
}
macro_rules! effects {
    ($(fn $method:ident($($name:ident: $ty:ty),*);)*) => {$ (
        fn $method(&mut self, io: &mut dyn Io, $($name: $ty),*) {
            let previous = io.section(&self.section);
            self.part.$method(io, $($name),*);
            io.section(&previous);
        }
    )*};
}

impl<T: Harness> Harness for Registered<T> {
    fn name(&self) -> &str {
        self.part.name()
    }
    fn key(&self) -> &str {
        self.part.key()
    }
    fn configures(&self, arguments: &[String]) -> bool {
        self.part.configures(arguments)
    }
    fn native_queue(&self) -> bool {
        self.part.native_queue()
    }
    fn matches(&self, process: &Process) -> bool {
        self.part.matches(process)
    }
    fn hook(&mut self, message: &Json) -> Result<Hook, Error> {
        self.part.hook(message)
    }
    fn commands(&self, binding: &Binding) -> Vec<String> {
        self.part.commands(binding)
    }
    fn menu(&mut self, io: &mut dyn Io, binding: &Binding, goal: &Goal, screen: &Screen, settled: bool) -> Step {
        let method = if matches!(goal, Goal::Models | Goal::Efforts { .. }) {
            "models"
        } else {
            "send"
        };
        if !(self.permitted)(method) {
            return Step::Fail(denied());
        }
        let previous = io.section(&self.section);
        let step = self.part.menu(io, binding, goal, screen, settled);
        io.section(&previous);
        step
    }
    fn prompt(&mut self, binding: &Binding, screen: &Screen) -> Option<Interaction> {
        if !(self.permitted)("state") {
            return None;
        }
        self.part.prompt(binding, screen)
    }
    fn screen_state(&mut self, binding: &Binding, screen: &Screen) -> Option<State> {
        if !(self.permitted)("state") {
            return None;
        }
        self.part.screen_state(binding, screen)
    }
    calls! {
        fn launch(cwd: &Path, arguments: &[String]) -> Command;
        fn command(binding: &Binding, text: &str) -> Outcome;
        fn identify(process: &Process, hook: Option<&Hook>) -> Option<Binding>;
        fn candidate(process: &Process) -> Option<Error>;
        fn history(binding: &Binding, earlier: Option<&str>) -> Page;
        fn read(source: &Transcript) -> Archive;
        fn state(binding: &Binding) -> State;
        fn send(binding: &Binding, text: &str, mode: Mode, command: bool) -> Sent;
        fn stop(binding: &Binding) -> Sent;
        fn models(binding: &Binding) -> Menu;
        fn efforts(binding: &Binding, model: &str) -> Menu;
        fn select(binding: &Binding, model: &str, effort: Option<&str>) -> Sent;
        fn answer(binding: &Binding, interaction: &str, answers: Vec<(String, Answer)>) -> Sent;
        fn tool(binding: &Binding, record: &str) -> Record;
        fn queue(binding: &Binding) -> Vec<Queued>;
        fn queue_add(binding: &Binding, text: &str, mode: Mode) -> Queued;
        fn queue_edit(binding: &Binding, item: &str, revision: u64, text: Option<&str>) -> ();
        fn queue_send(binding: &Binding, item: &str, revision: u64, mode: Mode) -> Sent;
        fn queue_order(binding: &Binding, items: &[String]) -> ();
        fn side(binding: &Binding, question: &str, read_only: bool) -> Binding;
        fn side_close(side: &Binding) -> ();
        fn revoke(binding: &Binding, retire: bool) -> ();
        fn install(route: &Path, enabled: Option<bool>, agent: Option<&Binding>) -> Install;
    }
    effects! {
        fn exited(process: &Process, status: Option<i32>);
    }
    /// Every hook path (own route, a mux forwarding a bound hook) ends here, so muting here
    /// covers all of them.
    fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) {
        if let Event::Hook { message, reply, .. } = &event
            && self.muted.as_ref().is_some_and(|muted| muted())
        {
            if let Some(reply) = reply {
                let hook = Json::parse(message).and_then(|doc| self.part.hook(&doc));
                let _ = io.reply(*reply, &hook.map(|hook| hook.fallback).unwrap_or_default());
            }
            return;
        }
        let previous = io.section(&self.section);
        self.part.event(io, ui, event);
        io.section(&previous);
    }
}

impl<T: Multiplexer> Multiplexer for Registered<T> {
    fn name(&self) -> &str {
        self.part.name()
    }
    fn harnesses(&mut self, list: Vec<Shared<dyn Harness>>) {
        self.part.harnesses(list);
    }
    fn external(&self) -> bool {
        self.part.external()
    }
    fn program(&self) -> Option<String> {
        self.part.program()
    }
    calls! {
        fn control(terminal: Id) -> Process;
        fn claim(process: &Process, write: ControlWrite) -> Option<ControlTarget>;
        fn release(client: &Process) -> ();
        fn enable(enabled: bool) -> ();
        fn probe(process: &Process) -> Option<String>;
        fn launch(process: &Process) -> Option<String>;
        fn backends() -> Vec<String>;
        fn open(key: &str) -> Id;
        fn create(parent: Id, beside: Option<Id>, command: Option<Command>, size: Option<Grid>) -> Id;
        fn rename(node: Id, name: &str) -> ();
        fn focus(node: Id) -> ();
        fn r#move(node: Id, parent: Id, before: Option<Id>) -> ();
        fn split(node: Id, ratio: f64) -> ();
        fn zoom(terminal: Id, zoomed: bool) -> ();
        fn close(node: Id, how: Close) -> ();
        fn idle(node: Id) -> bool;
        fn attach(terminal: Id, size: Grid, takeover: bool) -> ();
        fn input(terminal: Id, bytes: &[u8]) -> ();
        fn check(terminal: Id, process: &Process) -> ();
        fn keys(terminal: Id, process: &Process, input: &[Input]) -> ();
        fn resize(terminal: Id, size: Grid) -> ();
        fn scroll(terminal: Id, scroll: &Scroll) -> ();
        fn seek(terminal: Id, offset: u64) -> ();
        fn place(node: Id, place: &Place) -> ();
        fn screen(terminal: Id, changed: bool) -> Screen;
        fn prefix(node: Id) -> Prefix;
        fn command(node: Id, command: &str) -> ();
    }
    fn stream(&mut self, io: &mut dyn Io, id: Id, event: Control) -> Result<(), Error> {
        if !(self.permitted)("stream") {
            return Err(denied());
        }
        let previous = io.section(&self.section);
        let result = self.part.stream(io, id, event);
        io.section(&previous);
        result
    }
    effects! {
        fn invalidate(process: &Process);
        fn publish(terminal: Id, screen: Screen);
        fn event(ui: &mut dyn Ui, event: Event);
    }
}

impl<T: Plugin> Plugin for Registered<T> {
    fn read(
        &mut self,
        io: &mut dyn Io,
        read: &Read,
        limit: usize,
        mut chunk: Chunk,
        done: Done<Metadata>,
    ) {
        if !(self.permitted)("read") {
            return deferred(done)(io, Err(denied()));
        }
        let caller = io.section(&self.section);
        let section = self.section.clone();
        let permitted = self.permitted.clone();
        self.part.read(
            io,
            read,
            limit,
            Box::new(move |io, bytes, done| {
                if !permitted("read") {
                    return deferred(done)(io, Err(denied()));
                }
                chunk(io, bytes, returned(section.clone(), done));
            }),
            returned(caller.clone(), done),
        );
        io.section(&caller);
    }

    fn name(&self) -> &str {
        self.part.name()
    }
    calls! {
        fn reset(topics: &[String]) -> ();
        fn text(path: &Path) -> String;
        fn sample() -> Sample;
        fn processes() -> (Vec<Row>, bool);
        fn disks() -> Vec<Disk>;
        fn branch(cwd: &Path) -> Option<String>;
    }
    effects! { fn event(ui: &mut dyn Ui, event: Event); }
}
