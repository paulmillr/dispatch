use super::*;
use crate::helper::activity::{Told, body as agent};
use crate::helper::client::Client;

const BACKEND: u64 = 3;
const CHAT: u64 = 5;
const ATTACH: u64 = 7;

fn told(busy: bool, activity: &str, waiting: Option<&str>) -> Told {
    Told { busy, activity: Some(activity.into()), waiting: waiting.map(Into::into), time_ms: None, reply_ms: None }
}

fn node(id: u64, parent: Option<u64>, kind: Kind, name: &str) -> Node {
    Node {
        id,
        key: format!("tmux:fixture:{id}"),
        parent,
        kind,
        name: name.into(),
        renamed: None,
        cwd: None,
        size: None,
        agent: None,
        tty: None,
        detached: false,
    }
}

/// A backend with one tab named `tab` holding terminals titled `titles`.
fn topology(tab: &str, titles: &[&str]) -> Vec<u8> {
    let mut nodes = vec![node(1, None, Kind::Workspace, "space"), node(2, Some(1), Kind::Tab, tab)];
    for (index, title) in titles.iter().enumerate() {
        nodes.push(node(10 + index as u64, Some(2), Kind::Terminal, title));
    }
    wire::topology(1, &nodes, &[], None, None)
}

fn records(text: &str) -> Vec<u8> {
    crate::encode::notify("chat.records", &[("terminal", &9u64), ("session", &"s-fixture"), ("records", &text)])
}

fn state(activity: &str) -> Vec<u8> {
    crate::encode::notify("chat.state", &[("terminal", &9u64), ("session", &"s-fixture"), ("state", &activity)])
}

fn output(bytes: &[u8]) -> Vec<u8> {
    crate::encode::notify("terminal.output", &[("terminal", &9u64), ("bytes", &crate::encode::Bytes(bytes))])
}

/// A client with pacing on and `pending` open requests (its subscriptions).
fn paced(pending: &[u64]) -> Client {
    let mut client = Client::new(1);
    client.pending.extend(pending.iter().copied());
    client.pace(Pace::Interval(15_000));
    client
}

fn notify(client: &mut Client, id: u64, body: &[u8]) {
    client.queue(wire::Kind::Notify, id, body.to_vec(), None, false);
}

/// (stream, body) of each message queued to be sent, taken.
fn sent(client: &mut Client) -> Vec<(u64, Vec<u8>)> {
    client
        .messages
        .drain(..)
        .map(|mut message| {
            let mut frame = Vec::new();
            while message.size() > 0 {
                frame.extend(message.next().unwrap());
            }
            // Frame header (13) and schema (8).
            (message.id, frame[13 + 8..].to_vec())
        })
        .collect()
}

#[test]
fn without_pacing_nothing_is_held() {
    let mut client = Client::new(1);
    notify(&mut client, BACKEND, &agent(9, &told(true, "Reading", None), 1));
    notify(&mut client, BACKEND, &topology("tab", &["one"]));
    notify(&mut client, BACKEND, &topology("tab", &["two"]));
    assert_eq!(client.messages.len(), 3);
    assert!(!client.pacing.holding());
}

#[test]
fn activity_waits_and_goes_before_the_next_message_in_order() {
    let mut client = paced(&[BACKEND, CHAT]);
    let first = agent(9, &told(false, "Reading", None), 1);
    let other = agent(8, &told(false, "Writing", None), 1);
    notify(&mut client, BACKEND, &first);
    notify(&mut client, BACKEND, &other);
    assert!(client.messages.is_empty(), "same busy and waiting: held");
    // A reply goes after everything held, which keeps the order it was produced in.
    client.queue(wire::Kind::Response, 11, b"reply".to_vec(), None, false);
    let messages = sent(&mut client);
    assert_eq!(messages.len(), 3);
    assert_eq!(messages[0], (BACKEND, first));
    assert_eq!(messages[1], (BACKEND, other));
    assert_eq!(messages[2].0, 11);
    assert!(!client.pacing.holding());
}

#[test]
fn a_later_summary_of_the_same_terminal_supersedes_the_held_one() {
    let mut client = paced(&[BACKEND]);
    let other = agent(8, &told(false, "Writing", None), 1);
    notify(&mut client, BACKEND, &agent(9, &told(false, "Reading", None), 1));
    notify(&mut client, BACKEND, &other);
    let latest = agent(9, &told(false, "Searching", None), 2);
    notify(&mut client, BACKEND, &latest);
    client.unpace();
    assert_eq!(sent(&mut client), vec![(BACKEND, other), (BACKEND, latest)]);
}

#[test]
fn busy_and_waiting_changes_go_at_once_and_drop_what_they_supersede() {
    let mut client = paced(&[BACKEND]);
    let busy = agent(9, &told(true, "Reading", None), 1);
    notify(&mut client, BACKEND, &busy);
    assert_eq!(sent(&mut client), vec![(BACKEND, busy)], "idle to busy: a turn started");
    notify(&mut client, BACKEND, &agent(9, &told(true, "Writing", None), 2));
    let other = agent(8, &told(false, "Writing", None), 1);
    notify(&mut client, BACKEND, &other);
    assert!(client.messages.is_empty());
    let waiting = agent(9, &told(true, "Writing", Some("interaction")), 3);
    notify(&mut client, BACKEND, &waiting);
    // The held summary of terminal 9 is superseded; terminal 8's goes first, as it was produced first.
    assert_eq!(sent(&mut client), vec![(BACKEND, other), (BACKEND, waiting)]);
    let idle = agent(9, &told(false, "Writing", Some("interaction")), 4);
    notify(&mut client, BACKEND, &idle);
    assert_eq!(sent(&mut client), vec![(BACKEND, idle)], "busy to idle: the turn ended");
}

#[test]
fn a_summary_compares_with_what_its_own_subscription_was_told() {
    let mut client = paced(&[BACKEND, 4]);
    notify(&mut client, BACKEND, &agent(9, &told(true, "Reading", None), 1));
    sent(&mut client);
    // Another backends.open of the same client has not been told terminal 9 is busy.
    let busy = agent(9, &told(true, "Reading", None), 1);
    notify(&mut client, 4, &busy);
    assert_eq!(sent(&mut client), vec![(4, busy)]);
}

#[test]
fn topologies_that_change_only_pane_titles_wait() {
    let mut client = paced(&[BACKEND]);
    let first = topology("tab", &["one", "two"]);
    notify(&mut client, BACKEND, &first);
    assert_eq!(sent(&mut client), vec![(BACKEND, first)], "a subscription's first topology goes at once");
    notify(&mut client, BACKEND, &topology("tab", &["one*", "two"]));
    let titled = topology("tab", &["one**", "two"]);
    notify(&mut client, BACKEND, &titled);
    assert!(client.messages.is_empty(), "pane titles only: held");
    client.unpace();
    assert_eq!(sent(&mut client), vec![(BACKEND, titled)], "the newer whole topology supersedes the held one");
    // A tab name is not a pane title, nor is a new pane.
    let renamed = topology("renamed", &["one**", "two"]);
    notify(&mut client, BACKEND, &renamed);
    assert_eq!(sent(&mut client), vec![(BACKEND, renamed)]);
    notify(&mut client, BACKEND, &topology("renamed", &["one", "two"]));
    let split = topology("renamed", &["one", "two", "three"]);
    notify(&mut client, BACKEND, &split);
    assert_eq!(sent(&mut client), vec![(BACKEND, split)], "the held title change is superseded by the split");
}

#[test]
fn background_chats_wait_records_whole_and_state_latest() {
    let mut client = paced(&[BACKEND, CHAT]);
    notify(&mut client, CHAT, &records("in front"));
    assert_eq!(client.messages.len(), 1, "a chat in front goes at once");
    sent(&mut client);
    client.pace(Pace::Background(CHAT, true));
    notify(&mut client, CHAT, &state("one"));
    notify(&mut client, CHAT, &records("a"));
    notify(&mut client, CHAT, &state("two"));
    notify(&mut client, CHAT, &records("b"));
    assert!(client.messages.is_empty());
    client.unpace();
    assert_eq!(
        sent(&mut client),
        vec![(CHAT, records("a")), (CHAT, state("two")), (CHAT, records("b"))],
        "every record, the latest state where it came"
    );
    client.pace(Pace::Background(CHAT, false));
    notify(&mut client, CHAT, &state("three"));
    assert_eq!(client.messages.len(), 1, "back in front");
}

#[test]
fn only_an_open_request_is_marked_background() {
    let mut client = paced(&[BACKEND]);
    client.pace(Pace::Background(CHAT, true));
    notify(&mut client, CHAT, &records("a"));
    assert_eq!(client.messages.len(), 1, "no such subscription: nothing marked");
}

#[test]
fn an_ended_subscription_takes_what_was_held_for_it() {
    let mut client = paced(&[BACKEND, CHAT]);
    client.pace(Pace::Background(CHAT, true));
    notify(&mut client, CHAT, &records("a"));
    let held = agent(9, &told(false, "Reading", None), 1);
    notify(&mut client, BACKEND, &held);
    client.cancel(&mut NoIo, CHAT);
    client.unpace();
    assert_eq!(sent(&mut client), vec![(BACKEND, held)]);
    // Its mark went with it: a request that reuses the id is in front.
    client.pending.insert(CHAT);
    notify(&mut client, CHAT, &records("b"));
    assert_eq!(client.messages.len(), 1);
}

#[test]
fn turning_pacing_off_sends_what_is_held() {
    let mut client = paced(&[BACKEND]);
    notify(&mut client, BACKEND, &agent(9, &told(false, "Reading", None), 1));
    client.pace(Pace::Interval(0));
    assert_eq!(client.messages.len(), 1);
    notify(&mut client, BACKEND, &agent(9, &told(false, "Writing", None), 2));
    assert_eq!(client.messages.len(), 2, "off: nothing held");
}

#[test]
fn output_releases_what_is_held_after_older_coalesced_output() {
    let now = Instant::now();
    let mut client = paced(&[BACKEND, ATTACH]);
    client.queue(wire::Kind::Notify, ATTACH, output(b"a"), Some(now), false);
    let held = agent(9, &told(false, "Reading", None), 1);
    notify(&mut client, BACKEND, &held);
    client.queue(wire::Kind::Notify, ATTACH, output(b"b"), Some(now), false);
    client.release();
    let messages = sent(&mut client);
    assert_eq!(messages, vec![(ATTACH, output(b"a")), (BACKEND, held), (ATTACH, output(b"b"))]);
}

#[test]
fn held_items_go_at_their_deadline() {
    let start = Instant::now();
    let mut client = paced(&[BACKEND]);
    assert_eq!(client.paced(start), None, "nothing held: no timer");
    notify(&mut client, BACKEND, &agent(9, &told(false, "Reading", None), 1));
    let due = start + Duration::from_millis(15_000);
    assert_eq!(client.paced(start), Some(due), "a timer for the first held one's deadline");
    notify(&mut client, BACKEND, &agent(8, &told(false, "Reading", None), 1));
    assert_eq!(client.paced(start + Duration::from_millis(10)), None, "the timer is set");
    assert!(client.messages.is_empty());
    assert_eq!(client.paced(due), None);
    assert_eq!(client.messages.len(), 2, "both went at the deadline");
    // The next one held starts its own interval.
    notify(&mut client, BACKEND, &agent(8, &told(false, "Writing", None), 2));
    client.pacing.armed = None;
    let later = due + Duration::from_secs(1);
    assert_eq!(client.paced(later), Some(later + Duration::from_millis(15_000)));
}

#[test]
fn a_shorter_interval_sets_an_earlier_timer() {
    let start = Instant::now();
    let mut client = paced(&[BACKEND]);
    notify(&mut client, BACKEND, &agent(9, &told(false, "Reading", None), 1));
    assert!(client.paced(start).is_some());
    client.pace(Pace::Interval(1_000));
    assert_eq!(client.paced(start), Some(start + Duration::from_millis(1_000)));
}

#[test]
fn a_large_backlog_goes_at_once() {
    let mut client = paced(&[CHAT]);
    client.pace(Pace::Background(CHAT, true));
    let text = "x".repeat(100_000);
    for _ in 0..(LIMIT / 100_000) {
        notify(&mut client, CHAT, &records(&text));
    }
    assert!(client.messages.is_empty());
    notify(&mut client, CHAT, &records(&text));
    assert_eq!(client.messages.len(), LIMIT / 100_000 + 1, "past LIMIT bytes everything held goes");
    assert!(!client.pacing.holding());
}

#[test]
fn replies_and_other_notifications_are_never_held() {
    let pacing = &mut Pacing::default();
    pacing.set(15_000);
    assert_eq!(pacing.classify(wire::Kind::Response, BACKEND, b"reply"), Class::Now(None));
    let exit = crate::encode::notify("terminal.exit", &[("terminal", &9u64), ("status", &0i32)]);
    assert_eq!(pacing.classify(wire::Kind::Notify, BACKEND, &exit), Class::Now(None));
    let opened = crate::encode::notify("interaction.opened", &[("terminal", &9u64)]);
    pacing.background(CHAT, true, true);
    assert_eq!(pacing.classify(wire::Kind::Notify, CHAT, &opened), Class::Now(None), "even on a background chat");
}

/// One multiplexer update routed as the reactor routes it.
fn route(helper: &DispatchHelper, observers: &Observers, replies: &Replies, update: Update) {
    Updates {
        pending: helper.updates.clone(),
        exits: Vec::new(),
        replies: replies.clone(),
        observers,
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
        activity: helper.activity.clone(),
        topologies: helper.topologies.clone(),
    }
    .update(update);
}

#[test]
fn an_equal_topology_is_not_sent_again_on_a_subscription() {
    let helper = DispatchHelper::new();
    let (replies, mut observers): (Replies, Observers) = Default::default();
    let shown = |title: &str| Update::Topology {
        backend: 1,
        key: None,
        nodes: vec![node(2, None, Kind::Tab, "tab"), node(10, Some(2), Kind::Terminal, title)],
        layouts: Vec::new(),
        focus: None,
    };
    let sent = |replies: &Replies| -> Vec<(RawFd, u64)> {
        replies.borrow_mut().drain(..).map(|(fd, _, id, body)| {
            assert_eq!(wire::body::method(&body), Some("topology"));
            (fd, id)
        }).collect()
    };
    // The phone names notify.pace; a client that does not (the Mac) gets every topology (below).
    for phone in [3, 4] {
        helper.features.borrow_mut().insert(phone, [crate::dispatch::features::NOTIFY_PACE].into_iter().collect());
    }
    observers.push((3, 1, Scope::Backend(0)));
    route(&helper, &observers, &replies, shown("one"));
    assert_eq!(sent(&replies), [(3, 1)]);
    route(&helper, &observers, &replies, shown("one"));
    assert_eq!(sent(&replies), [], "the same topology again");
    // A new subscription (another client's, or a second backends.open) gets its first one.
    observers.push((4, 1, Scope::Backend(0)));
    route(&helper, &observers, &replies, shown("one"));
    assert_eq!(sent(&replies), [(4, 1)]);
    route(&helper, &observers, &replies, shown("two"));
    assert_eq!(sent(&replies), [(3, 1), (4, 1)]);
    // Back to an earlier one: it differs from the last one sent.
    route(&helper, &observers, &replies, shown("one"));
    assert_eq!(sent(&replies), [(3, 1), (4, 1)]);
    // A client without notify.pace is sent the same topology again (the Mac's split waits for it).
    observers.retain(|_| false);
    observers.push((5, 1, Scope::Backend(0)));
    route(&helper, &observers, &replies, shown("one"));
    route(&helper, &observers, &replies, shown("one"));
    assert_eq!(sent(&replies), [(5, 1), (5, 1)]);
}

/// Cancels here abort no drains: nothing is asked of the system.
struct NoIo;
#[rustfmt::skip]
impl Io for NoIo {
    fn now(&self) -> Instant { unreachable!() }
    fn timer(&mut self, _: Instant) { unreachable!() }
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
