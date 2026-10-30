//! terminals.follow (dispatch/following.rs): which subscriptions get a terminal's updates while one holds its output,
//! and the operation itself, against a multiplexer that records what it is asked.
use super::*;
use crate::{
    dispatch::{Request, features},
    json::Data,
};
use std::{
    path::{Path, PathBuf},
    process::Command,
};

#[derive(Default)]
struct Queue(VecDeque<Box<dyn FnOnce(&mut dyn Io)>>);
impl Queue {
    fn settle(&mut self) {
        while let Some(work) = self.0.pop_front() {
            work(self);
        }
    }
}
#[rustfmt::skip]
impl Io for Queue {
    fn now(&self) -> Instant { Instant::now() }
    fn timer(&mut self, _: Instant) {}
    fn defer(&mut self, work: Box<dyn FnOnce(&mut dyn Io)>) { self.0.push_back(work); }
    fn interest(&mut self, _: RawFd, _: bool, _: bool) -> io::Result<()> { unreachable!() }
    fn read(&mut self, _: RawFd, _: &mut [u8]) -> io::Result<usize> { unreachable!() }
    fn write(&mut self, _: RawFd, _: &[u8]) -> io::Result<usize> { unreachable!() }
    fn close(&mut self, _: RawFd) { unreachable!() }
    fn accept(&mut self, _: RawFd) -> io::Result<RawFd> { unreachable!() }
    fn child(&mut self, _: u32) -> io::Result<()> { unreachable!() }
    fn submit(&mut self, _: Job) -> io::Result<Work> { unreachable!() }
    fn cancel(&mut self, _: Work) -> bool { unreachable!() }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> { unreachable!() }
    fn unwatch(&mut self, _: u64) { unreachable!() }
    fn spawn(&mut self, _: Command, _: Option<Grid>) -> io::Result<Spawned> { unreachable!() }
    fn resize(&mut self, _: RawFd, _: Grid) -> io::Result<()> { unreachable!() }
    fn hangup(&mut self, _: RawFd) -> io::Result<()> { unreachable!() }
    fn connect(&mut self, _: &Address) -> io::Result<RawFd> { unreachable!() }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> { unreachable!() }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> { unreachable!() }
}

/// What the multiplexer was asked: input bytes, and repaints (terminal, token).
#[derive(Default)]
struct Asked {
    input: Vec<Vec<u8>>,
    restores: Vec<(Id, u64)>,
}

/// A multiplexer that takes input and repaints (or cannot repaint, as native) and is asked nothing else here.
struct Recording {
    asked: Rc<RefCell<Asked>>,
    restores: bool,
}
#[rustfmt::skip]
impl Multiplexer for Recording {
    fn name(&self) -> &str { "recording" }
    fn external(&self) -> bool { true }
    fn harnesses(&mut self, _: Vec<Shared<dyn Harness>>) {}
    fn backends(&mut self, _: &mut dyn Io, _: Done<Vec<String>>) { unreachable!() }
    fn open(&mut self, _: &mut dyn Io, _: &str, _: Done<Id>) { unreachable!() }
    fn create(&mut self, _: &mut dyn Io, _: Id, _: Option<Id>, _: Option<Command>, _: Option<Grid>, _: Done<Id>) { unreachable!() }
    fn rename(&mut self, _: &mut dyn Io, _: Id, _: &str, _: Done<()>) { unreachable!() }
    fn focus(&mut self, _: &mut dyn Io, _: Id, _: Done<()>) { unreachable!() }
    fn r#move(&mut self, _: &mut dyn Io, _: Id, _: Id, _: Option<Id>, _: Done<()>) { unreachable!() }
    fn split(&mut self, _: &mut dyn Io, _: Id, _: f64, _: Done<()>) { unreachable!() }
    fn zoom(&mut self, _: &mut dyn Io, _: Id, _: bool, _: Done<()>) { unreachable!() }
    fn close(&mut self, _: &mut dyn Io, _: Id, _: Close, _: Done<()>) { unreachable!() }
    fn attach(&mut self, _: &mut dyn Io, _: Id, _: Grid, _: bool, _: bool, _: Done<()>) { unreachable!() }
    fn input(&mut self, io: &mut dyn Io, _: Id, bytes: &[u8], done: Done<()>) {
        self.asked.borrow_mut().input.push(bytes.to_vec());
        deferred(done)(io, Ok(()));
    }
    fn keys(&mut self, _: &mut dyn Io, _: Id, _: &Process, _: &[Input], _: Done<()>) { unreachable!() }
    fn resize(&mut self, _: &mut dyn Io, _: Id, _: Grid, _: Done<()>) { unreachable!() }
    fn scroll(&mut self, _: &mut dyn Io, _: Id, _: &Scroll, _: Done<()>) { unreachable!() }
    fn screen(&mut self, _: &mut dyn Io, _: Id, _: bool, _: Done<Screen>) { unreachable!() }
    fn publish(&mut self, _: &mut dyn Io, _: Id, _: Screen) { unreachable!() }
    fn event(&mut self, _: &mut dyn Io, _: &mut dyn Ui, _: Event) { unreachable!() }
    fn restores(&self) -> bool { self.restores }
    fn restore(&mut self, io: &mut dyn Io, terminal: Id, token: u64, done: Done<()>) {
        self.asked.borrow_mut().restores.push((terminal, token));
        deferred(done)(io, Ok(()));
    }
}

const TERMINAL: Id = 5;
/// The Mac's attach subscription and the iPhone's, both of TERMINAL.
const MAC: (RawFd, u64) = (3, 10);
const PHONE: (RawFd, u64) = (4, 20);

struct Bench {
    helper: DispatchHelper,
    io: Queue,
    replies: Replies,
    observers: Vec<Observer>,
    asked: Rc<RefCell<Asked>>,
}

fn bench(restores: bool) -> Bench {
    let mut helper = DispatchHelper::new();
    let asked = Rc::new(RefCell::new(Asked::default()));
    helper.add_multiplexer(Recording { asked: asked.clone(), restores });
    let replies: Replies = Default::default();
    let mut io = Queue::default();
    for (fd, subscription) in [MAC, PHONE] {
        // Their attaches opened: each has its input window.
        crate::dispatch::window(replies.clone(), helper.windows.clone(), fd, subscription, TERMINAL, Box::new(|_, _| {}))(
            &mut io,
            Ok(()),
        );
    }
    helper.features.borrow_mut().insert(MAC.0, [features::TERMINALS_FOLLOW].into_iter().collect());
    io.settle();
    replies.borrow_mut().clear();
    let observers = [MAC, PHONE].map(|(fd, id)| (fd, id, Scope::Terminal(TERMINAL))).to_vec();
    Bench { helper, io, replies, observers, asked }
}

impl Bench {
    /// One update of the multiplexer, as the reactor routes it.
    fn route(&mut self, update: Update) {
        let helper = &self.helper;
        Updates {
            pending: helper.updates.clone(),
            exits: Vec::new(),
            replies: self.replies.clone(),
            observers: &self.observers,
            module: 0,
            nodes: helper.nodes.clone(),
            scopes: helper.scopes.clone(),
            retired: helper.retired.clone(),
            questions: helper.questions.clone(),
            interactions: helper.interactions.clone(),
            held: helper.held.clone(),
            sides: helper.sides.clone(),
            controls: helper.controls.clone(),
            probes: helper.probes.clone(),
            candidates: helper.candidates.clone(),
            login: None,
            features: helper.features.clone(),
            follows: helper.follows.clone(),
        }
        .update(update);
    }
    fn output(&mut self, bytes: &str) {
        self.route(Update::Output { terminal: TERMINAL, bytes: bytes.into() });
    }
    /// A request of client `fd` with id `id`, as the reactor hands a feature operation over.
    fn request(&mut self, fd: RawFd, id: u64, method: &str, params: Data<'_>) -> Result<(), Error> {
        let document = Rc::new(wire::body::Encoded::value(&Data::Null).unwrap());
        let mut request =
            Request { helper: &mut self.helper, io: &mut self.io, replies: self.replies.clone(), document, fd, id };
        let result = if features::operation(method).is_some() {
            request.extension(method, &params)
        } else {
            request.dispatch(method, &params)
        };
        self.io.settle();
        result
    }
    fn follow(&mut self, following: bool) -> Result<(), Error> {
        let params = Data::Object(vec![("terminal", Data::Unsigned(TERMINAL)), ("following", Data::Bool(following))]);
        self.request(MAC.0, 30, features::TERMINALS_FOLLOW, params)
    }
    /// What went out since the last call: `fd/id method bytes` for notifications, `fd/id ok|code` for replies.
    fn sent(&self) -> Vec<String> {
        self.replies
            .borrow_mut()
            .drain(..)
            .map(|(fd, _, id, body)| {
                let framed = [&wire::body::SCHEMA[..], &body].concat();
                let data = wire::body::decode(&framed).unwrap();
                match data.get("method").and_then(Data::string) {
                    Some(method) => {
                        let bytes = data.get("params").and_then(|p| p.get("bytes")).and_then(Data::bytes);
                        format!("{fd}/{id} {method} {}", String::from_utf8_lossy(bytes.unwrap_or_default()))
                    }
                    None => match data.get("error").and_then(|e| e.get("code")).and_then(Data::string) {
                        Some(code) => format!("{fd}/{id} {code}"),
                        None => format!("{fd}/{id} ok"),
                    },
                }
            })
            .collect()
    }
}

#[test]
fn held_output_is_dropped_for_that_subscription_only_and_its_exit_still_arrives() {
    let mut bench = bench(true);
    bench.follow(false).unwrap();
    assert_eq!(bench.sent(), ["3/30 ok"]);
    bench.output("spinner");
    bench.route(Update::Stderr { terminal: TERMINAL, bytes: b"note".to_vec() });
    assert_eq!(bench.sent(), ["4/20 terminal.output spinner", "4/20 terminal.stderr note"], "the iPhone still gets it");
    bench.route(Update::Exit { terminal: TERMINAL, status: Some(0) });
    assert_eq!(bench.sent(), ["3/10 terminal.exit ", "4/20 terminal.exit "]);
}

#[test]
fn following_again_sends_one_repaint_to_that_subscription_before_later_output() {
    let mut bench = bench(true);
    bench.follow(false).unwrap();
    bench.output("missed");
    bench.sent();
    bench.follow(true).unwrap();
    assert_eq!(bench.asked.borrow().restores, [(TERMINAL, 1)]);
    assert_eq!(bench.sent(), ["3/30 ok"], "answered once the repaint is queued");
    // Output tmux sent before the repaint's capture ran is in the repaint: until it arrives the subscription is held.
    bench.output("before");
    assert_eq!(bench.sent(), ["4/20 terminal.output before"]);
    bench.route(Update::Restore { terminal: TERMINAL, token: 1, bytes: b"repaint".to_vec() });
    assert_eq!(bench.sent(), ["3/10 terminal.output repaint"], "the iPhone never sees it");
    bench.output("after");
    assert_eq!(bench.sent(), ["3/10 terminal.output after", "4/20 terminal.output after"]);
    // A second repaint of that token (none is asked for twice) reaches nobody.
    bench.route(Update::Restore { terminal: TERMINAL, token: 1, bytes: b"again".to_vec() });
    assert!(bench.sent().is_empty());
}

#[test]
fn hiding_again_before_the_repaint_arrives_keeps_the_output_held() {
    let mut bench = bench(true);
    bench.follow(false).unwrap();
    bench.follow(true).unwrap();
    bench.follow(false).unwrap();
    bench.sent();
    bench.route(Update::Restore { terminal: TERMINAL, token: 1, bytes: b"stale".to_vec() });
    bench.output("hidden");
    assert_eq!(bench.sent(), ["4/20 terminal.output hidden"]);
    // Shown again: a new repaint, of its own token.
    bench.follow(true).unwrap();
    assert_eq!(bench.asked.borrow().restores, [(TERMINAL, 1), (TERMINAL, 2)]);
    bench.route(Update::Restore { terminal: TERMINAL, token: 2, bytes: b"fresh".to_vec() });
    assert_eq!(bench.sent(), ["3/30 ok", "3/10 terminal.output fresh"]);
}

#[test]
fn following_by_default_and_asking_twice_changes_nothing() {
    let mut bench = bench(true);
    bench.follow(true).unwrap();
    bench.output("x");
    assert_eq!(bench.sent(), ["3/30 ok", "3/10 terminal.output x", "4/20 terminal.output x"]);
    assert!(bench.asked.borrow().restores.is_empty(), "nothing was held: no repaint");
    bench.follow(false).unwrap();
    bench.follow(false).unwrap();
    bench.follow(true).unwrap();
    bench.follow(true).unwrap();
    assert_eq!(bench.asked.borrow().restores.len(), 1);
}

#[test]
fn input_still_reaches_a_held_terminal() {
    let mut bench = bench(true);
    bench.follow(false).unwrap();
    bench.sent();
    let params = Data::Object(vec![
        ("terminal", Data::Unsigned(TERMINAL)),
        ("bytes", Data::Bytes(b"ls\r")),
        ("subscription", Data::Unsigned(MAC.1)),
    ]);
    bench.request(MAC.0, 31, "terminals.input", params).unwrap();
    assert_eq!(bench.asked.borrow().input, [b"ls\r".to_vec()]);
    // Its credit comes back as before: input windows are not output.
    assert_eq!(bench.sent(), ["3/10 terminal.input_window ", "3/31 ok"]);
}

#[test]
fn only_an_attach_of_the_client_can_be_held_and_only_where_it_can_be_repainted() {
    let mut tmux = bench(true);
    let params = |terminal: Id, subscription: Option<u64>| {
        let mut fields = vec![("terminal", Data::Unsigned(terminal)), ("following", Data::Bool(false))];
        fields.extend(subscription.map(|s| ("subscription", Data::Unsigned(s))));
        Data::Object(fields)
    };
    let code = |result: Result<(), Error>| result.unwrap_err().code;
    assert_eq!(code(tmux.request(MAC.0, 32, features::TERMINALS_FOLLOW, params(6, None))), "invalid_input");
    assert_eq!(code(tmux.request(MAC.0, 33, features::TERMINALS_FOLLOW, params(TERMINAL, Some(PHONE.1)))), "invalid_input");
    let unknown = Data::Object(vec![("terminal", Data::Unsigned(TERMINAL)), ("following", Data::Bool(false)), ("x", Data::Null)]);
    assert_eq!(code(tmux.request(MAC.0, 34, features::TERMINALS_FOLLOW, unknown)), "invalid_input");
    tmux.request(MAC.0, 35, features::TERMINALS_FOLLOW, params(TERMINAL, Some(MAC.1))).unwrap();
    // Native terminals have no host screen to repaint from: their output is never held.
    let mut native = bench(false);
    assert_eq!(code(native.follow(false)), "unsupported");
    native.output("x");
    assert_eq!(native.sent(), ["3/10 terminal.output x", "4/20 terminal.output x"]);
}

#[test]
fn a_client_without_the_feature_has_no_such_operation() {
    assert_eq!(features::operation("terminals.follow"), Some(features::TERMINALS_FOLLOW));
    let root = Data::Object(vec![
        ("method", Data::String("terminals.follow")),
        ("params", Data::Object(vec![("terminal", Data::Unsigned(TERMINAL)), ("following", Data::Bool(false))])),
    ]);
    // Without the feature the request goes to the ordinary table, which has no terminals.follow.
    assert_eq!(crate::dispatch::parameters(&root, |_| true).err().map(|e| e.code), Some("unsupported"));
    let bench = bench(true);
    assert!(!features::enabled(&bench.helper.features, PHONE.0, features::TERMINALS_FOLLOW));
}

#[test]
fn ended_subscriptions_are_forgotten() {
    let mut bench = bench(true);
    bench.follow(false).unwrap();
    bench.observers.retain(|(fd, _, _)| *fd != MAC.0);
    let open = bench.observers.clone();
    bench.helper.follows.borrow_mut().retain(|(fd, id)| open.iter().any(|(peer, request, _)| (*peer, *request) == (fd, id)));
    assert!(bench.helper.follows.borrow().is_empty());
}

#[test]
fn an_ack_names_its_terminal_and_is_queued_for_the_loop() {
    let mut bench = bench(true);
    let ack = |bytes: u64| Data::Object(vec![("terminal", Data::Unsigned(TERMINAL)), ("bytes", Data::Unsigned(bytes))]);
    bench.request(MAC.0, 31, features::TERMINALS_ACK, ack(70_000)).unwrap();
    bench.request(PHONE.0, 32, features::TERMINALS_ACK, ack(5)).unwrap();
    // Not attached (or no longer): nothing to acknowledge, and no error.
    let other = Data::Object(vec![("terminal", Data::Unsigned(TERMINAL + 1)), ("bytes", Data::Unsigned(1))]);
    bench.request(MAC.0, 33, features::TERMINALS_ACK, other).unwrap();
    assert_eq!(bench.sent(), ["3/31 ok", "4/32 ok", "3/33 ok"]);
    assert_eq!(bench.helper.acks, [(MAC.0, MAC.1, 70_000), (PHONE.0, PHONE.1, 5)], "applied by the loop before it admits output");
    let extra = Data::Object(vec![("bytes", Data::Unsigned(1)), ("terminal", Data::Unsigned(TERMINAL)), ("x", Data::Null)]);
    assert_eq!(bench.request(MAC.0, 34, features::TERMINALS_ACK, extra).unwrap_err().code, "invalid_input");
    let missing = Data::Object(vec![("terminal", Data::Unsigned(TERMINAL))]);
    assert_eq!(bench.request(MAC.0, 35, features::TERMINALS_ACK, missing).unwrap_err().code, "invalid_input");
    assert_eq!(bench.helper.acks.len(), 2);
}
