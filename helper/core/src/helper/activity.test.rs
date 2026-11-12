use super::*;

fn binding(session: &str) -> Binding {
    Binding {
        session: session.into(),
        transcript: None,
        process: Process {
            pid: 4242,
            parent: 1,
            group: 4242,
            foreground: 4242,
            tty: 7,
            start: [1_800_000_000, 0],
            executable: "/opt/example/claude".into(),
            arguments: vec!["claude".into()],
            files: vec![],
        },
    }
}
fn busy(busy: bool) -> State {
    State { busy, activity: Some(if busy { "busy" } else { "idle" }.into()), ..State::default() }
}
const TERMINAL: Id = 7;

/// The summaries of the notifications due at `now`, and when the next held one is.
fn due(activity: &mut Activity, now: Instant) -> (Vec<(bool, Option<i64>, u64)>, Option<Instant>) {
    let (bodies, next) = activity.due(now, |_| true);
    let told = bodies
        .into_iter()
        .map(|(terminal, body)| {
            assert_eq!(terminal, TERMINAL);
            let mut framed = crate::wire::body::SCHEMA.to_vec();
            framed.extend_from_slice(&body);
            let value = crate::wire::body::decode(&framed).unwrap();
            assert_eq!(value.get("method").and_then(crate::json::Data::string), Some("agent.changed"));
            let summary = value.get("params").and_then(|params| params.get("summary")).unwrap();
            let keys: Vec<&str> = summary.object().unwrap().map(|(key, _)| key).collect();
            assert_eq!(keys, ["waiting", "busy", "activity", "revision", "time_ms", "reply_ms"]);
            (
                summary.get("busy").and_then(crate::json::Data::boolean).unwrap(),
                summary.get("reply_ms").and_then(crate::json::Data::signed),
                summary.get("revision").and_then(crate::json::Data::unsigned).unwrap(),
            )
        })
        .collect();
    (told, next)
}

#[test]
fn changes_of_one_terminal_reach_list_clients_at_most_every_window() {
    let mut activity = Activity::default();
    let (one, start) = (binding("s1"), Instant::now());
    activity.state(TERMINAL, &one, &busy(true));
    assert_eq!(due(&mut activity, start), (vec![(true, None, 1)], None));
    // Nothing changed: nothing to tell.
    assert!(!activity.pending());
    assert_eq!(due(&mut activity, start), (vec![], None));

    // Three changes within the window: held until it ends, then told once as they ended.
    let soon = start + Duration::from_millis(100);
    activity.state(TERMINAL, &one, &busy(false));
    activity.overview(TERMINAL, &one, &Overview { reply_ms: Some(1_000), ..Overview::default() });
    assert_eq!(due(&mut activity, soon), (vec![], Some(start + WINDOW)));
    activity.overview(TERMINAL, &one, &Overview { reply_ms: Some(2_000), ..Overview::default() });
    assert_eq!(due(&mut activity, soon + Duration::from_millis(100)), (vec![], Some(start + WINDOW)));
    assert_eq!(due(&mut activity, start + WINDOW), (vec![(false, Some(2_000), 2)], None));

    // A change undone within the window is not told.
    let later = start + WINDOW + Duration::from_millis(50);
    activity.state(TERMINAL, &one, &busy(true));
    assert_eq!(due(&mut activity, later), (vec![], Some(start + WINDOW + WINDOW)));
    activity.state(TERMINAL, &one, &busy(false));
    assert_eq!(due(&mut activity, start + WINDOW + WINDOW), (vec![], None));
}

#[test]
fn a_change_nobody_lists_is_taken_as_told() {
    let mut activity = Activity::default();
    activity.state(TERMINAL, &binding("s1"), &busy(true));
    let (bodies, next) = activity.due(Instant::now(), |_| false);
    assert!(bodies.is_empty() && next.is_none());
    assert!(!activity.pending());
}

#[test]
fn another_conversation_starts_its_row_again_and_ended_ones_go() {
    let mut activity = Activity::default();
    let now = Instant::now();
    activity.state(TERMINAL, &binding("s1"), &busy(true));
    let _ = due(&mut activity, now);
    // The terminal's agent started another conversation: told at once, from revision 1.
    activity.state(TERMINAL, &binding("s2"), &busy(true));
    assert_eq!(due(&mut activity, now), (vec![(true, None, 1)], None));
    // An open question is `waiting`; its terminal's conversation gone, its row goes too.
    activity.refresh(|_, _| true, |_, _| true);
    assert!(activity.pending());
    activity.refresh(|_, _| false, |_, _| false);
    assert!(activity.idle() && !activity.pending());
}

/// The clock and timers `DispatchHelper::activity` uses; nothing else is asked of the system.
struct Clock {
    now: Instant,
    timers: Vec<Instant>,
}
#[rustfmt::skip]
impl Io for Clock {
    fn now(&self) -> Instant { self.now }
    fn timer(&mut self, at: Instant) { self.timers.push(at) }
    fn defer(&mut self, _: Box<dyn FnOnce(&mut dyn Io)>) { unreachable!() }
    fn interest(&mut self, _: RawFd, _: bool, _: bool) -> std::io::Result<()> { unreachable!() }
    fn read(&mut self, _: RawFd, _: &mut [u8]) -> std::io::Result<usize> { unreachable!() }
    fn write(&mut self, _: RawFd, _: &[u8]) -> std::io::Result<usize> { unreachable!() }
    fn close(&mut self, _: RawFd) { unreachable!() }
    fn accept(&mut self, _: RawFd) -> std::io::Result<RawFd> { unreachable!() }
    fn child(&mut self, _: u32) -> std::io::Result<()> { unreachable!() }
    fn submit(&mut self, _: Job) -> std::io::Result<Work> { unreachable!() }
    fn cancel(&mut self, _: Work) -> bool { unreachable!() }
    fn watch(&mut self, _: &std::path::Path, _: bool) -> std::io::Result<u64> { unreachable!() }
    fn unwatch(&mut self, _: u64) { unreachable!() }
    fn spawn(&mut self, _: std::process::Command, _: Option<Grid>) -> std::io::Result<Spawned> { unreachable!() }
    fn resize(&mut self, _: RawFd, _: Grid) -> std::io::Result<()> { unreachable!() }
    fn hangup(&mut self, _: RawFd) -> std::io::Result<()> { unreachable!() }
    fn connect(&mut self, _: &Address) -> std::io::Result<RawFd> { unreachable!() }
    fn route(&mut self) -> std::io::Result<(u64, std::path::PathBuf)> { unreachable!() }
    fn reply(&mut self, _: u64, _: &[u8]) -> std::io::Result<()> { unreachable!() }
}

fn route(helper: &DispatchHelper, observers: &Observers, replies: &Replies, module: usize, update: Update) {
    Updates {
        pending: helper.updates.clone(),
        exits: Vec::new(),
        replies: replies.clone(),
        observers,
        module,
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
        activity: helper.activity.clone(),
    }
    .update(update);
}

/// (client, request, summary has the row's times) of each agent.changed sent since the last call.
fn changed(replies: &Replies) -> Vec<(RawFd, u64, bool)> {
    replies
        .borrow_mut()
        .drain(..)
        .filter(|(_, _, _, body)| wire::body::method(body) == Some("agent.changed"))
        .map(|(fd, _, id, body)| {
            let mut framed = wire::body::SCHEMA.to_vec();
            framed.extend_from_slice(&body);
            let value = wire::body::decode(&framed).unwrap();
            let summary = value.get("params").and_then(|params| params.get("summary")).unwrap();
            (fd, id, summary.get("time_ms").is_some())
        })
        .collect()
}

#[test]
fn list_clients_hear_of_state_changes_and_others_do_not() {
    let helper = DispatchHelper::new();
    let (replies, mut observers): (Replies, Observers) = Default::default();
    let (mac, phone) = (3, 4);
    let one = binding("s1");
    let node = Node {
        id: TERMINAL,
        key: "tmux:s:$1:%3".into(),
        parent: None,
        kind: Kind::Terminal,
        name: String::new(),
        renamed: None,
        cwd: None,
        size: None,
        agent: Some((0, one.clone())),
        tty: None,
        detached: false,
    };
    helper.nodes.borrow_mut().insert(TERMINAL, (0, node));
    observers.push((mac, 1, Scope::Backend(0)));
    observers.push((phone, 2, Scope::Backend(0)));
    let mut clock = Clock { now: Instant::now(), timers: Vec::new() };
    let start = clock.now;

    // No client named the feature: nothing is kept, timed or sent.
    route(&helper, &observers, &replies, usize::MAX, Update::State { binding: one.clone(), state: busy(true) });
    helper.activity(&mut clock, &replies, &observers);
    assert!(helper.activity.borrow().idle());
    assert_eq!(changed(&replies), []);

    helper.features.borrow_mut().insert(phone, [AGENTS_ACTIVITY].into_iter().collect());
    route(&helper, &observers, &replies, usize::MAX, Update::State { binding: one.clone(), state: busy(true) });
    helper.activity(&mut clock, &replies, &observers);
    assert_eq!(changed(&replies), [(phone, 2, true)]);

    // The turn ends 100 ms later: held, with a timer for the end of the window.
    clock.now = start + Duration::from_millis(100);
    route(&helper, &observers, &replies, usize::MAX, Update::State { binding: one.clone(), state: busy(false) });
    route(&helper, &observers, &replies, usize::MAX, Update::Overview { binding: one.clone(), overview: Overview { reply_ms: Some(9), ..Overview::default() } });
    helper.activity(&mut clock, &replies, &observers);
    assert_eq!(changed(&replies), []);
    assert_eq!(clock.timers, [start + WINDOW]);
    clock.now = start + WINDOW;
    helper.activity.borrow_mut().armed = None;
    helper.activity(&mut clock, &replies, &observers);
    assert_eq!(changed(&replies), [(phone, 2, true)]);

    // A row read is internal: no chat or backend subscriber gets an Overview of its own.
    route(&helper, &observers, &replies, usize::MAX, Update::Overview { binding: one.clone(), overview: Overview::default() });
    assert!(replies.borrow().is_empty());

    // The multiplexer's own agent.changed (a binding change): the Mac's summary as before, the
    // phone's with what it was told.
    route(&helper, &observers, &replies, 0, Update::Agent { terminal: TERMINAL, summary: Summary::default() });
    assert_eq!(changed(&replies), [(mac, 1, false), (phone, 2, true)]);
}

#[test]
fn harnesses_are_told_only_when_what_they_list_changes() {
    let mut activity = Activity::default();
    let listed = |bindings: Vec<Binding>| BTreeMap::from([(0, bindings)]);
    assert_eq!(activity.listen(listed(vec![binding("s1")])), [(0, vec![binding("s1")])]);
    assert_eq!(activity.listen(listed(vec![binding("s1")])), []);
    assert_eq!(activity.listen(BTreeMap::new()), [(0, vec![])]);
    assert!(activity.idle());
}
