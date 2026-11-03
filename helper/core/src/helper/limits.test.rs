//! Limits (helper/limits.rs) against a real helper loop on a socket: a flooding or stalled client is refused or
//! closed while a healthy one keeps being served; and the subscription index fans an update out to every
//! subscription of its target, in arrival order, at the limit.
use super::*;
use crate::{json::Data, wire::{Header, Kind, Received, body::{self, Encoded}}};
use std::{
    io::{Read, Write},
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::PathBuf,
    process::Command,
};

/// A multiplexer that is never asked anything: terminals.observe only names it.
struct Fake;
#[rustfmt::skip]
impl Multiplexer for Fake {
    fn name(&self) -> &str { "fake" }
    fn external(&self) -> bool { false }
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
    fn input(&mut self, _: &mut dyn Io, _: Id, _: &[u8], _: Done<()>) { unreachable!() }
    fn keys(&mut self, _: &mut dyn Io, _: Id, _: &Process, _: &[Input], _: Done<()>) { unreachable!() }
    fn resize(&mut self, _: &mut dyn Io, _: Id, _: Grid, _: Done<()>) { unreachable!() }
    fn scroll(&mut self, _: &mut dyn Io, _: Id, _: &Scroll, _: Done<()>) { unreachable!() }
    fn screen(&mut self, _: &mut dyn Io, _: Id, _: bool, _: Done<Screen>) { unreachable!() }
    fn publish(&mut self, _: &mut dyn Io, _: Id, _: Screen) { unreachable!() }
    fn event(&mut self, _: &mut dyn Io, _: &mut dyn Ui, _: Event) { unreachable!() }
}

/// Small bounds, so a test reaches each with a handful of sockets; at most 5 connections are not crowded.
fn small() -> Limits {
    Limits {
        connections: 10,
        pending: 64,
        pending_total: 256,
        subscriptions: 16,
        subscriptions_total: 40,
        share: 8,
        input: 1 << 20,
        small: 65_536,
        idle: Duration::from_secs(60),
        rate: 16 << 10,
    }
}

/// A helper serving a fresh socket on a thread of its own, which ends with the test process (the helper loop has
/// no way out but its clients); its folder goes with this.
struct Served {
    socket: PathBuf,
    directory: PathBuf,
}
impl Drop for Served {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn serve(limits: Limits) -> Served {
    let mut nonce = [0; 8];
    std::fs::File::open("/dev/urandom").unwrap().read_exact(&mut nonce).unwrap();
    let root = std::env::var_os("DISPATCH_TEST_ROOT").map_or_else(std::env::temp_dir, PathBuf::from);
    std::fs::create_dir_all(&root).unwrap();
    let directory = root.join(format!("limits-{:x}", u64::from_ne_bytes(nonce)));
    std::fs::create_dir(&directory).unwrap();
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
    let socket = directory.join("s");
    let path = socket.clone();
    std::thread::spawn(move || {
        let mut helper = DispatchHelper::new();
        helper.limits = limits;
        helper.add_multiplexer(Fake);
        helper.run(&path).unwrap();
    });
    let started = Instant::now();
    loop {
        if let Ok(probe) = UnixStream::connect(&socket) {
            // The probe connection is closed at once; wait until the helper has let it go.
            drop(probe);
            break;
        }
        assert!(started.elapsed() < Duration::from_secs(10), "the helper did not listen");
        std::thread::sleep(Duration::from_millis(10));
    }
    std::thread::sleep(Duration::from_millis(100));
    Served { socket, directory }
}

/// One answer: its result, or its error's code and message.
type Answer = Result<Encoded, (String, String)>;

struct Peer {
    stream: UnixStream,
    collectors: BTreeMap<u64, wire::Collector>,
    answers: BTreeMap<u64, Answer>,
}

impl Peer {
    fn connect(served: &Served) -> Peer {
        let stream = UnixStream::connect(&served.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        Peer { stream, collectors: BTreeMap::new(), answers: BTreeMap::new() }
    }

    fn frame(method: &str, id: u64, params: Data<'_>) -> Vec<u8> {
        let body = body::encode(&Data::Object(vec![("method", Data::String(method)), ("params", params)])).unwrap();
        wire::packet(Kind::Request, id, &body).unwrap()
    }

    fn write(&mut self, bytes: &[u8]) {
        self.stream.write_all(bytes).unwrap();
    }

    fn send(&mut self, id: u64, method: &str, params: Data<'_>) {
        let frame = Self::frame(method, id, params);
        self.write(&frame);
    }

    fn observe(&mut self, id: u64, terminal: u64) {
        self.send(id, "terminals.observe", Data::Object(vec![("terminal", Data::Unsigned(terminal))]));
    }

    fn cancel(&mut self, id: u64) {
        self.write(&wire::packet(Kind::Cancel, id, &[]).unwrap());
    }

    /// The next whole message, None once the helper closed the connection.
    fn next(&mut self) -> Option<(Kind, u64, Encoded)> {
        loop {
            let mut head = [0; 13];
            match self.stream.read_exact(&mut head) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return None,
                Err(error) if error.kind() == io::ErrorKind::ConnectionReset => return None,
                Err(error) => panic!("read: {error}"),
            }
            let header = Header::decode(&head, wire::LIMIT).unwrap();
            let mut bytes = vec![0; header.len as usize];
            self.stream.read_exact(&mut bytes).unwrap();
            let collector =
                self.collectors.entry(header.id).or_insert_with(|| wire::Collector::new(header.id, wire::LIMIT as usize));
            if let Some(Received::Value(value)) = collector.push(header, &bytes).unwrap() {
                self.collectors.remove(&header.id);
                return Some((header.kind, header.id, value));
            }
        }
    }

    fn error(value: &Encoded) -> Option<(String, String)> {
        let root = value.root();
        let error = root.get("error")?;
        Some((
            error.get("code").and_then(Data::string).unwrap_or_default().to_owned(),
            error.get("message").and_then(Data::string).unwrap_or_default().to_owned(),
        ))
    }

    /// Read until request `id` is answered; what else is answered meanwhile is kept.
    fn answer(&mut self, id: u64) -> Answer {
        while !self.answers.contains_key(&id) {
            let (kind, from, value) = self.next().expect("the helper closed the connection");
            if kind != Kind::Response {
                continue;
            }
            let answer = match Self::error(&value) {
                Some(error) => Err(error),
                None => Ok(value.clone()),
            };
            self.answers.insert(from, answer);
        }
        self.answers.remove(&id).unwrap()
    }

    /// An echo round trip: the connection is served.
    fn echo(&mut self, id: u64) {
        self.send(id, "echo", Data::Unsigned(id));
        let value = self.answer(id).expect("echo");
        assert_eq!(value.root().get("result").and_then(Data::unsigned), Some(id));
    }

    /// The requests answered so far, besides those asked for: the refused ones, with their messages.
    fn refused(&mut self) -> BTreeMap<u64, String> {
        std::mem::take(&mut self.answers)
            .into_iter()
            .map(|(id, answer)| match answer {
                Err((code, message)) if code == "busy" => (id, message),
                other => panic!("{id} answered {:?}", other.map(|_| ())),
            })
            .collect()
    }

    /// The helper closes this connection (within the read timeout).
    fn closes(&mut self) -> bool {
        while self.next().is_some() {}
        true
    }
}

#[test]
fn a_subscription_flood_without_output_is_refused_while_a_healthy_client_keeps_its_share() {
    let served = serve(small());
    let mut healthy = Peer::connect(&served);
    healthy.echo(1);
    // Subscriptions that never produce output: each stays open until cancelled, so only the limit ends the flood.
    let mut flood = Peer::connect(&served);
    for id in 1..=20 {
        flood.observe(id, id);
    }
    flood.echo(100);
    let refused = flood.refused();
    assert_eq!(refused.keys().copied().collect::<Vec<_>>(), [17, 18, 19, 20]);
    assert!(refused[&17].contains("16 subscriptions are open on this connection"), "{}", refused[&17]);
    // Identical subscriptions are each a subscription.
    let mut same = Peer::connect(&served);
    for id in 1..=16 {
        same.observe(id, 5);
    }
    same.echo(100);
    assert!(same.refused().is_empty());
    // 32 of 40 open: a third flood gets the rest, then only connections below their share open more.
    let mut third = Peer::connect(&served);
    for id in 1..=12 {
        third.observe(id, 1000 + id);
    }
    third.echo(100);
    let refused = third.refused();
    assert_eq!(refused.keys().copied().collect::<Vec<_>>(), [9, 10, 11, 12]);
    assert!(refused[&9].contains("40 subscriptions are open in this helper"), "{}", refused[&9]);
    // The healthy client was answered throughout and still opens its own.
    for id in 2..=5 {
        healthy.observe(id, 7);
    }
    healthy.echo(6);
    assert!(healthy.refused().is_empty());
}

#[test]
fn cancelling_subscriptions_reclaims_their_capacity() {
    let served = serve(small());
    let mut flood = Peer::connect(&served);
    for id in 1..=16 {
        flood.observe(id, id);
    }
    flood.observe(17, 17);
    flood.echo(100);
    assert_eq!(flood.refused().keys().copied().collect::<Vec<_>>(), [17]);
    for id in 1..=4 {
        flood.cancel(id);
    }
    for id in 18..=22 {
        flood.observe(id, id);
    }
    flood.echo(101);
    assert_eq!(flood.refused().keys().copied().collect::<Vec<_>>(), [22], "four cancelled, four admitted");
    // Request ids of cancelled subscriptions may be used again.
    flood.cancel(5);
    flood.observe(1, 1);
    flood.echo(102);
    assert!(flood.refused().is_empty());
}

#[test]
fn open_requests_are_bounded_per_connection() {
    let served = serve(Limits { pending: 10, ..small() });
    let mut flood = Peer::connect(&served);
    for id in 1..=10 {
        flood.observe(id, id);
    }
    // Any request past the bound is answered without running, an echo too.
    flood.send(11, "echo", Data::Unsigned(11));
    let (code, message) = flood.answer(11).unwrap_err();
    assert_eq!(code, "busy");
    assert!(message.contains("10 requests are open on this connection"), "{message}");
    assert!(flood.refused().is_empty());
    flood.cancel(1);
    flood.echo(12);
    let mut healthy = Peer::connect(&served);
    healthy.echo(1);
}

/// Crowded past three connections, timed by the second: what the next tests need.
fn crowded() -> Limits {
    Limits { connections: 6, idle: Duration::from_secs(1), ..small() }
}

#[test]
fn idle_partial_frames_expire_under_pressure_while_a_healthy_client_is_served() {
    let served = serve(crowded());
    // A healthy client holds a subscription: it is settled, however quiet.
    let mut healthy = Peer::connect(&served);
    healthy.observe(1, 1);
    healthy.echo(2);
    let request = Peer::frame("echo", 9, Data::Unsigned(9));
    // Not crowded (at most half the connection limit): a partial frame is kept however long it waits.
    let mut patient = Peer::connect(&served);
    patient.write(&request[..5]);
    std::thread::sleep(Duration::from_millis(2500));
    healthy.echo(3);
    patient.write(&request[5..]);
    assert_eq!(patient.answer(9).unwrap().root().get("result").and_then(Data::unsigned), Some(9));
    // Many slow clients, each holding a partial frame: once crowded they are timed.
    patient.write(&request[..5]);
    let before = Instant::now();
    let mut slow: Vec<_> = (0..4).map(|_| Peer::connect(&served)).collect();
    for peer in &mut slow {
        peer.write(&request[..20]);
    }
    // The healthy client is served throughout, and the stalled ones are closed, not before their idle time.
    for id in 4..9 {
        healthy.echo(id);
    }
    assert!(patient.closes());
    for peer in &mut slow {
        assert!(peer.closes());
    }
    assert!(before.elapsed() >= Duration::from_secs(1), "closed before their idle time");
    healthy.echo(9);
    let mut later = Peer::connect(&served);
    later.echo(1);
}

#[test]
fn idle_connections_cannot_lock_out_a_reconnect_for_long() {
    let served = serve(crowded());
    let mut healthy = Peer::connect(&served);
    healthy.observe(1, 1);
    healthy.echo(2);
    // Five connections that never send a frame fill the limit.
    let mut idle: Vec<_> = (0..5).map(|_| Peer::connect(&served)).collect();
    std::thread::sleep(Duration::from_millis(200));
    // The next one is told why, then closed.
    let mut refused = Peer::connect(&served);
    let (kind, id, value) = refused.next().expect("a refusal");
    assert_eq!((kind, id), (Kind::Response, 0));
    let (code, message) = Peer::error(&value).expect("an error");
    assert_eq!(code, "busy");
    assert!(message.contains("already serves 6 connections"), "{message}");
    assert!(refused.closes());
    healthy.echo(3);
    // Crowded, the ones that never completed a frame are closed after the idle time; the place is free again.
    for peer in &mut idle {
        assert!(peer.closes());
    }
    let mut reconnect = Peer::connect(&served);
    reconnect.echo(1);
    healthy.echo(4);
}

#[test]
fn a_trickled_frame_is_closed_at_its_deadline_however_it_trickles() {
    // 150 bytes at 100 bytes a second: 1.5 s past the idle time in all.
    let served = serve(Limits { rate: 100, ..crowded() });
    let mut healthy = Peer::connect(&served);
    healthy.observe(1, 1);
    healthy.echo(2);
    // Settled fillers (each with a subscription) keep the helper crowded.
    let mut fillers: Vec<_> = (0..3).map(|_| Peer::connect(&served)).collect();
    for peer in &mut fillers {
        peer.observe(1, 1);
        peer.echo(2);
    }
    let request = Peer::frame("echo", 1, Data::Bytes(&[1; 130]));
    assert!(request.len() >= 150);
    let mut trickler = Peer::connect(&served);
    let started = Instant::now();
    trickler.write(&request[..13]);
    // Then a byte every 300 ms: never silent for the idle time.
    for byte in &request[13..] {
        if trickler.stream.write_all(std::slice::from_ref(byte)).is_err() {
            break;
        }
        std::thread::sleep(Duration::from_millis(300));
        if started.elapsed() > Duration::from_secs(20) {
            break;
        }
    }
    assert!(trickler.closes());
    let elapsed = started.elapsed();
    assert!(elapsed >= Duration::from_millis(2200), "closed after {elapsed:?}, before its deadline");
    assert!(elapsed < Duration::from_secs(15), "trickled for {elapsed:?}");
    healthy.echo(3);
    fillers[0].echo(3);
}

#[test]
fn large_frames_past_the_input_budget_are_refused_beyond_each_connections_share() {
    let served = serve(small());
    let big = |id, size| Peer::frame("echo", id, Data::Bytes(&vec![7u8; size]));
    let mut first = Peer::connect(&served);
    let request = big(1, 700_000);
    first.write(&request[..300_000]);
    let mut healthy = Peer::connect(&served);
    healthy.echo(1);
    // 700 kB announced by `first`, and 600 kB more is past 1 MiB and past this connection's half of it: read whole,
    // dropped, answered busy.
    let mut second = Peer::connect(&served);
    second.write(&big(2, 600_000));
    let (code, message) = second.answer(2).unwrap_err();
    assert_eq!(code, "busy");
    assert!(message.contains("too many large requests"), "{message}");
    // Small requests are always read; the connection stays usable.
    second.echo(3);
    // Within its share (half of the budget, with one other holder) a healthy client's large request is admitted
    // while `first` holds its reservation.
    let payload = vec![9u8; 450_000];
    healthy.send(5, "echo", Data::Bytes(&payload));
    let value = healthy.answer(5).unwrap();
    assert_eq!(value.root().get("result").and_then(Data::bytes), Some(&payload[..]));
    first.write(&request[300_000..]);
    assert_eq!(first.answer(1).unwrap().root().get("result").and_then(Data::bytes).map(<[u8]>::len), Some(700_000));
    second.write(&big(4, 600_000));
    assert!(second.answer(4).is_ok());
}

/// Clients as the loop holds them, for Limits::track.
fn clients(count: usize) -> BTreeMap<RawFd, Client> {
    (0..count as RawFd).map(|fd| (fd, Client::new(fd))).collect()
}

#[test]
fn under_pressure_every_unsettled_connection_is_timed_whether_it_is_read_or_not() {
    let limits = Limits { connections: 6, ..small() };
    let header = |len: u32| wire::Header { kind: Kind::Request, id: 1, len }.encode(wire::LIMIT).unwrap();
    let mut clients = clients(3);
    // 0: settled, a subscription open after a frame; 1: a partial frame, its output backed up (not read);
    // 2: a large frame half sent, then its read side ended with a reply still owed.
    let settled = clients.get_mut(&0).unwrap();
    settled.feed(&wire::packet(Kind::Request, 1, b"x").unwrap(), &limits, 0, 0).unwrap();
    settled.pending.insert(1);
    let backed = clients.get_mut(&1).unwrap();
    backed.feed(&header(100)[..9], &limits, 0, 0).unwrap();
    backed.listening = false;
    let closing = clients.get_mut(&2).unwrap();
    closing.feed(&header(700_000), &limits, 0, 0).unwrap();
    closing.feed(&[0; 1000], &limits, 0, 0).unwrap();
    assert_eq!(closing.reserved, 700_000);
    closing.pending.insert(7);
    closing.ended();
    assert_eq!(closing.reserved, 0, "an ended connection's reservation goes");
    // Not crowded: nothing is timed and the clock is never read.
    assert_eq!(limits.track(&mut clients, || unreachable!("the clock while not crowded")), None);
    clients.insert(3, Client::new(3));
    let start = Instant::now();
    let first = limits.track(&mut clients, || start);
    assert_eq!(first, Some(start + limits.idle));
    assert_eq!(clients[&0].due, None, "settled");
    let at = start + limits.idle;
    let due: Vec<_> = limits.expired(&clients, at).into_iter().map(|(fd, why)| (fd, why)).collect();
    assert_eq!(due, [(1, Unsettled::Frame(0)), (2, Unsettled::Closing), (3, Unsettled::Fresh)]);
}

#[test]
fn traffic_moves_the_idle_time_but_never_the_deadline() {
    let limits = Limits { connections: 2, rate: 1000, ..small() };
    let mut clients = clients(2);
    let header = wire::Header { kind: Kind::Request, id: 1, len: 2000 }.encode(wire::LIMIT).unwrap();
    clients.get_mut(&1).unwrap().feed(&header, &limits, 0, 0).unwrap();
    let start = Instant::now();
    limits.track(&mut clients, || start);
    // A byte every 30 s keeps it from going idle; 2000 bytes at 1000 a second allow it 2 s past the idle time in all.
    for step in 1..=3 {
        let client = clients.get_mut(&1).unwrap();
        client.feed(&[0], &limits, 0, 0).unwrap();
        client.stamp = None;
        let now = start + Duration::from_secs(30 * step);
        limits.track(&mut clients, || now);
    }
    assert_eq!(clients[&1].due, Some(start + limits.idle + Duration::from_secs(2)));
    // A completed frame starts the allowance again.
    let client = clients.get_mut(&1).unwrap();
    client.feed(&[0; 1997], &limits, 0, 0).unwrap();
    client.pending.insert(1);
    let later = start + Duration::from_secs(100);
    limits.track(&mut clients, || later);
    assert_eq!(clients[&1].due, None, "settled once its request is open");
}

#[test]
fn a_large_frame_is_admitted_within_the_budget_or_its_fair_share() {
    let limits = small();
    assert!(limits.admits(65_536, u64::MAX / 2, 63), "small frames always");
    assert!(limits.admits(700_000, 300_000, 1));
    // 1 MiB among two holders: 512 KiB each.
    assert!(limits.admits(500_000, 700_000, 1));
    assert!(!limits.admits(600_000, 700_000, 1));
    // Among five, a fifth.
    assert!(limits.admits(200_000, 900_000, 4));
    assert!(!limits.admits(300_000, 900_000, 4));
}

/// One update routed as the reactor routes a multiplexer's.
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
    }
    .update(update);
}

/// (client, request, method) of each notification sent since the last call.
fn notified(replies: &Replies) -> Vec<(RawFd, u64, String)> {
    replies
        .borrow_mut()
        .drain(..)
        .map(|(fd, kind, id, body)| {
            assert_eq!(kind, Kind::Notify);
            (fd, id, wire::body::method(&body).unwrap().to_owned())
        })
        .collect()
}

#[test]
fn an_update_reaches_every_subscription_of_its_target_at_the_limit() {
    let limits = Limits::default();
    let helper = DispatchHelper::new();
    let replies: Replies = Default::default();
    let mut observers = Observers::default();
    const TERMINAL: Id = 5;
    let (mac, phone) = (3, 4);
    // The Mac at its limit, every subscription the same attach; the phone at its limit on other terminals.
    for id in 0..limits.subscriptions as u64 {
        limits.subscribe(&observers, mac).unwrap();
        observers.push((mac, id, Scope::Terminal(TERMINAL)));
        observers.push((phone, id, Scope::Terminal(1000 + id)));
    }
    assert_eq!(limits.subscribe(&observers, mac).unwrap_err().code, "busy");
    assert_eq!(observers.targets(), 1 + limits.subscriptions, "identical subscriptions share their target");
    route(&helper, &observers, &replies, Update::Output { terminal: TERMINAL, bytes: b"ok".to_vec() });
    let sent = notified(&replies);
    assert_eq!(sent.len(), limits.subscriptions);
    assert!(sent.iter().enumerate().all(|(index, sent)| *sent == (mac, index as u64, "terminal.output".into())));
    route(&helper, &observers, &replies, Update::Output { terminal: 999, bytes: b"none".to_vec() });
    assert!(notified(&replies).is_empty());
    route(&helper, &observers, &replies, Update::Output { terminal: 1000 + 77, bytes: b"one".to_vec() });
    assert_eq!(notified(&replies), [(phone, 77, "terminal.output".into())]);
}

#[test]
fn an_update_reaches_its_subscriptions_in_arrival_order() {
    let helper = DispatchHelper::new();
    let replies: Replies = Default::default();
    let mut observers = Observers::default();
    const TERMINAL: Id = 9;
    let (mac, phone) = (3, 4);
    observers.push((mac, 1, Scope::Terminal(TERMINAL)));
    observers.push((phone, 2, Scope::Events(TERMINAL)));
    observers.push((mac, 3, Scope::Chat(TERMINAL, "s".into())));
    observers.push((mac, 4, Scope::Terminal(TERMINAL)));
    observers.push((phone, 5, Scope::Chat(TERMINAL + 1, String::new())));
    observers.push((phone, 6, Scope::Backend(0)));
    observers.push((mac, 7, Scope::Created));
    observers.push((phone, 8, Scope::Chat(TERMINAL, String::new())));
    // A created terminal's subscription keeps its place when it becomes the terminal's attach.
    observers.adopt(mac, 7, Some(TERMINAL));
    assert!(observers.chats(TERMINAL) && observers.chats(TERMINAL + 1) && !observers.chats(TERMINAL + 2));
    route(&helper, &observers, &replies, Update::Exit { terminal: TERMINAL, status: Some(0) });
    let order: Vec<_> = notified(&replies).into_iter().map(|(fd, id, _)| (fd, id)).collect();
    assert_eq!(order, [(mac, 1), (phone, 2), (mac, 3), (mac, 4), (mac, 7), (phone, 8)]);
    observers.remove(mac, 1);
    observers.remove_client(phone);
    assert_eq!((observers.len(), observers.count(mac), observers.count(phone)), (3, 3, 0));
    route(&helper, &observers, &replies, Update::Output { terminal: TERMINAL, bytes: b"x".to_vec() });
    assert_eq!(notified(&replies).into_iter().map(|(_, id, _)| id).collect::<Vec<_>>(), [4, 7]);
}
