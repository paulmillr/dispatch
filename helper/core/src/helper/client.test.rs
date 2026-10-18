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
    client.queue(wire::Kind::Notify, 7, output(3, b"a"), None);
    client.queue(wire::Kind::Notify, 7, output(3, b"b"), None);
    assert_eq!(client.messages.len(), 2);
    assert!(client.coalesced.is_none());
}

#[test]
fn output_of_one_stream_joins_until_something_else_comes() {
    let now = Instant::now();
    let mut client = Client::new(1);
    client.queue(wire::Kind::Notify, 7, output(3, b"ab"), Some(now));
    client.queue(wire::Kind::Notify, 7, output(3, b"cd"), Some(now));
    assert!(client.messages.is_empty(), "held for the window");
    // Another terminal, or any other message, releases what is held first: order is kept.
    client.queue(wire::Kind::Notify, 7, output(4, b"x"), Some(now));
    client.queue(wire::Kind::Response, 9, b"reply".to_vec(), Some(now));
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
    client.queue(wire::Kind::Notify, 7, output(3, &chunk), Some(now));
    client.queue(wire::Kind::Notify, 7, output(3, &chunk), Some(now));
    assert_eq!(client.messages.len(), 1, "the first half went out when the second did not fit");
    client.release();
    let messages = bodies(&mut client);
    assert_eq!(messages.len(), 2);
    assert!(messages.iter().all(|(_, frame)| frame.len() < wire::CHUNK), "inline frames");
}
