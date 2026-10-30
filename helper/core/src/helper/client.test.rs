use super::*;

fn output(terminal: u64, bytes: &[u8]) -> Vec<u8> {
    crate::encode::notify("terminal.output", &[("terminal", &terminal), ("bytes", &crate::encode::Bytes(bytes))])
}

fn bodies(client: &mut Client) -> Vec<(u64, Vec<u8>)> {
    client
        .messages
        .drain(..)
        .map(|mut message| {
            let mut frame = Vec::new();
            while message.size() > 0 {
                frame.extend(message.next().unwrap());
            }
            (message.id, frame)
        })
        .collect()
}

#[test]
fn without_the_feature_every_notification_is_its_own_message() {
    let mut client = Client::new(1);
    client.queue(wire::Kind::Notify, 7, output(3, b"a"), None, false);
    client.queue(wire::Kind::Notify, 7, output(3, b"b"), None, false);
    assert_eq!(client.messages.len(), 2);
    assert!(client.coalesced.is_none());
}

#[test]
fn output_of_one_stream_joins_until_something_else_comes() {
    let now = Instant::now();
    let mut client = Client::new(1);
    client.queue(wire::Kind::Notify, 7, output(3, b"ab"), Some(now), false);
    client.queue(wire::Kind::Notify, 7, output(3, b"cd"), Some(now), false);
    assert!(client.messages.is_empty(), "held for the window");
    // Another terminal, or any other message, releases what is held first: order is kept.
    client.queue(wire::Kind::Notify, 7, output(4, b"x"), Some(now), false);
    client.queue(wire::Kind::Response, 9, b"reply".to_vec(), Some(now), false);
    let messages = bodies(&mut client);
    assert_eq!(messages.len(), 3);
    assert_eq!(super::output(&messages[0].1[13 + 8..]).unwrap(), (3, b"abcd".to_vec()));
    assert_eq!(super::output(&messages[1].1[13 + 8..]).unwrap(), (4, b"x".to_vec()));
    assert_eq!(messages[2].0, 9);
}

#[test]
fn a_full_frame_goes_out_at_once() {
    let now = Instant::now();
    let mut client = Client::new(1);
    let chunk = vec![b'y'; LIMIT / 2 + 1];
    client.queue(wire::Kind::Notify, 7, output(3, &chunk), Some(now), false);
    client.queue(wire::Kind::Notify, 7, output(3, &chunk), Some(now), false);
    assert_eq!(client.messages.len(), 1, "the first half went out when the second did not fit");
    client.release();
    let messages = bodies(&mut client);
    assert_eq!(messages.len(), 2);
    assert!(messages.iter().all(|(_, frame)| frame.len() < wire::CHUNK), "inline frames");
}

/// Writes everything admitted, as a client that reads at once would let the helper.
fn drain(client: &mut Client) {
    while let Some(count) = client.output.front().map(<[u8]>::len) {
        client.output.consume(count).unwrap();
    }
}

#[test]
fn without_requests_backlog_a_full_queue_stops_reading_as_recorded() {
    let mut client = Client::new(1);
    assert!(client.reading(false) && client.reading(true));
    // Output that fills the queue: four inline frames of 60 000 bytes leave less than a frame.
    for _ in 0..5 {
        client.queue(wire::Kind::Notify, 7, output(3, &[b'y'; 60_000]), None, false);
    }
    client.admit().unwrap();
    assert!(client.output.space() < FRAME);
    assert!(!client.reading(false), "recorded clients: no reads while the queue is full");
    assert!(client.reading(true), "requests.backlog: requests are still read, output does not count");
    client.eof = true;
    assert!(!client.reading(true), "nothing to read after EOF");
}

#[test]
fn requests_backlog_stops_reading_past_its_bound_of_waiting_replies() {
    let mut client = Client::new(1);
    for _ in 0..5 {
        client.queue(wire::Kind::Notify, 7, output(3, &[b'y'; 60_000]), None, false);
    }
    client.admit().unwrap();
    // Replies to requests read meanwhile wait behind the admitted output.
    for id in 0..BACKLOG as u64 - 1 {
        client.queue(wire::Kind::Response, 100 + id, b"reply".to_vec(), None, false);
    }
    assert!(client.reading(true));
    client.queue(wire::Kind::Response, 99, b"reply".to_vec(), None, false);
    assert!(!client.reading(true), "a request flood stops at BACKLOG replies");
    drain(&mut client);
    client.admit().unwrap();
    assert!(client.reading(true), "reading resumes once they go out");
    // One large reply passes the byte bound alone.
    client.queue(wire::Kind::Response, 9, vec![0; BACKLOG_BYTES], None, false);
    assert!(!client.reading(true));
}

#[test]
fn a_window_client_counts_output_as_admitted_and_replies_pass_it_when_closed() {
    let mut client = Client::new(1);
    let chunk = [b'y'; 60_000];
    for _ in 0..6 {
        client.queue(wire::Kind::Notify, 7, output(3, &chunk), None, true);
    }
    client.queue(wire::Kind::Response, 8, b"reply".to_vec(), None, true);
    let mut answered = Vec::new();
    for _ in 0..10 {
        answered.extend(client.admit().unwrap());
        drain(&mut client);
    }
    // 5 x 60 000 reach the window (262 144); the sixth waits, the reply passes it.
    assert_eq!(client.unacked, 300_000);
    assert_eq!(answered, [8]);
    assert_eq!(client.messages.len(), 1, "the sixth output waits for acknowledgements");
    // An acknowledgement below the window lets it go; one of another subscription changes nothing.
    client.acknowledge(9, 60_000);
    assert_eq!(client.unacked, 300_000);
    client.acknowledge(7, 60_000);
    client.admit().unwrap();
    assert!(client.messages.is_empty());
    assert_eq!(client.unacked, 300_000);
}

#[test]
fn a_subscription_that_ends_takes_its_outstanding_output_and_others_count_nothing() {
    let mut client = Client::new(1);
    client.pending.extend([7, 8, 9]);
    client.queue(wire::Kind::Notify, 7, output(3, b"abc"), None, true);
    client.queue(wire::Kind::Notify, 8, output(4, b"defg"), None, true);
    client.queue(wire::Kind::Notify, 9, output(5, b"hi"), None, true);
    client.admit().unwrap();
    assert_eq!(client.unacked, 9);
    // Cancelled: the client drops whatever of it is still coming, so none of it is acknowledged.
    client.output.consume(1).unwrap();
    client.cancel(&mut NoIo, 7);
    assert_eq!(client.unacked, 6);
    // Answered: its stream ended too.
    client.queue(wire::Kind::Response, 8, b"done".to_vec(), None, true);
    assert_eq!(client.admit().unwrap(), [8]);
    assert_eq!(client.unacked, 2);
    // More than outstanding counts as all of it; a late ack of an ended stream is a no-op.
    client.acknowledge(9, 100);
    client.acknowledge(7, 3);
    assert_eq!(client.unacked, 0);
    // Coalesced output counts what it joined; a client without the window counts nothing.
    let now = Instant::now();
    let mut coalescing = Client::new(1);
    coalescing.queue(wire::Kind::Notify, 7, output(3, b"ab"), Some(now), true);
    coalescing.queue(wire::Kind::Notify, 7, output(3, b"cd"), Some(now), true);
    coalescing.release();
    coalescing.admit().unwrap();
    assert_eq!(coalescing.unacked, 4);
    let mut plain = Client::new(1);
    for _ in 0..10 {
        plain.queue(wire::Kind::Notify, 7, output(3, &[b'y'; 60_000]), None, false);
        plain.admit().unwrap();
        drain(&mut plain);
    }
    assert_eq!(plain.unacked, 0);
    assert!(plain.messages.is_empty());
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
