use super::*;

const A: Owner = Owner { pid: 10, start: [100, 1], token: 7 };
const B: Owner = Owner { pid: 20, start: [200, 2], token: 9 };

fn bound() -> Bound {
    Bound { session: "s-1".into(), pid: 42, start: [5, 6] }
}

fn add(record: &mut Record, id: &str, text: &str) -> Queued {
    let op = Op::Add { id: id.into(), text: text.into(), mode: Mode::Prompt, command: false, binding: bound(), attachments: Vec::new() };
    match record.apply(&op).unwrap() {
        Answer::Added(queued) => queued,
        other => panic!("{other:?}"),
    }
}

fn record() -> Record {
    Record::new("claude", "s-1", "tmux", "tmux:server:501:1:2:/tmp/s:$1:%3")
}

#[test]
fn a_record_survives_its_file_with_every_field() {
    let mut record = record();
    add(&mut record, "q-1", "first\nline");
    add(&mut record, "q-2", "second");
    record.hold = Some(A);
    record.awaiting = Some(Awaiting { owner: B, item: "q-0".into() });
    record.items[0].claim = Some(A);
    record.items[1].pause = Some(Pause::NeedsEdit);
    record.items[1].editing = Some(B);
    record.items[1].mode = Mode::FollowUp;
    record.items[1].command = true;
    let bytes = record.encode().unwrap();
    assert_eq!(Record::decode(&bytes).unwrap(), record);
}

#[test]
fn another_format_or_a_damaged_file_is_not_read() {
    let mut bytes = record().encode().unwrap();
    bytes.truncate(bytes.len() - 3);
    assert!(Record::decode(&bytes).is_err());
    let other = body::encode_plain(&Data::Object(vec![("format", Data::Unsigned(3))])).unwrap();
    let refused = Record::decode(&other).unwrap_err();
    assert_eq!((refused.code, refused.message.as_str()), ("storage", "The stored queue has another format"));
}

#[test]
fn a_conversation_has_one_file_for_every_helper() {
    let storage = Path::new("/home/u/.dispatch/state");
    let one = path(storage, "claude", "s-1");
    assert_eq!(one, path(storage, "claude", "s-1"));
    assert_ne!(one, path(storage, "pi", "s-1"));
    assert_ne!(one, path(storage, "claude", "s-2"));
    // The separator keeps ("ab", "c") apart from ("a", "bc").
    assert_ne!(path(storage, "ab", "c"), path(storage, "a", "bc"));
    assert!(one.starts_with(storage.join(DIRECTORY)));
    assert_eq!(one.file_name().unwrap().len(), 34);
}

#[test]
fn an_add_retried_on_a_newer_file_adds_once() {
    let mut record = record();
    let first = add(&mut record, "q-1", "hello");
    let again = add(&mut record, "q-1", "hello");
    assert_eq!(first, again);
    assert_eq!(record.items.len(), 1);
    assert_eq!(first.revision, 1);
}

#[test]
fn the_queue_keeps_its_limit() {
    let mut record = record();
    for index in 0..ITEMS {
        add(&mut record, &format!("q-{index}"), "x");
    }
    let op = Op::Add { id: "q-over".into(), text: "x".into(), mode: Mode::Prompt, command: false, binding: bound(), attachments: Vec::new() };
    assert_eq!(record.apply(&op).unwrap_err().code, "invalid_input");
}

#[test]
fn revisions_expire_edits_from_an_older_view() {
    let mut record = record();
    let item = add(&mut record, "q-1", "hello");
    let update = |text: &str, revision| Op::Update {
        id: "q-1".into(),
        revision,
        text: Some(text.into()),
        command: None,
        binding: bound(),
    };
    record.apply(&update("hi", item.revision)).unwrap();
    assert_eq!(record.items[0].text, "hi");
    let stale = record.apply(&update("lost", item.revision)).unwrap_err();
    assert_eq!(stale.code, "expired");
    let removal = Op::Remove { id: "q-1".into(), revision: item.revision };
    assert_eq!(record.apply(&removal).unwrap_err().code, "expired");
}

#[test]
fn an_edit_clears_its_pause_and_rebinds() {
    let mut record = record();
    let item = add(&mut record, "q-1", "hello");
    record.items[0].pause = Some(Pause::DestinationChanged);
    record.items[0].editing = Some(A);
    let moved = Bound { session: "s-2".into(), pid: 43, start: [7, 8] };
    record
        .apply(&Op::Update { id: "q-1".into(), revision: item.revision, text: Some("again".into()), command: Some(true), binding: moved.clone() })
        .unwrap();
    let edited = &record.items[0];
    assert_eq!((edited.pause, edited.editing, edited.command), (None, None, true));
    assert_eq!(edited.binding, moved);
    assert!(edited.revision > item.revision);
}

#[test]
fn only_one_helper_claims_the_head() {
    let mut record = record();
    add(&mut record, "q-1", "one");
    add(&mut record, "q-2", "two");
    // Not the head.
    assert_eq!(record.apply(&Op::Claim { id: "q-2".into(), owner: A, binding: bound() }).unwrap_err().code, "busy");
    // Both helpers read the same file; A's checked write lands first.
    let read = record.clone();
    let mut by_a = read.clone();
    assert!(matches!(by_a.apply(&Op::Claim { id: "q-1".into(), owner: A, binding: bound() }), Ok(Answer::Claimed(_))));
    // B's write fails (the file changed); B applies its claim again to the file A wrote.
    let mut by_b = by_a.clone();
    assert_eq!(by_b.apply(&Op::Claim { id: "q-1".into(), owner: B, binding: bound() }).unwrap_err().code, "busy");
    assert_eq!(by_a.items[0].claim, Some(A));
}

#[test]
fn nothing_is_claimed_while_held_awaiting_paused_or_edited() {
    let base = {
        let mut record = record();
        add(&mut record, "q-1", "one");
        record
    };
    let claim = Op::Claim { id: "q-1".into(), owner: A, binding: bound() };
    let mut held = base.clone();
    held.apply(&Op::Hold { held: true, owner: A }).unwrap();
    assert!(held.apply(&claim).is_err());
    let mut awaiting = base.clone();
    awaiting.awaiting = Some(Awaiting { owner: B, item: "q-0".into() });
    assert!(awaiting.apply(&claim).is_err());
    let mut paused = base.clone();
    paused.apply(&Op::Stop).unwrap();
    assert!(paused.apply(&claim).is_err());
    let mut edited = base.clone();
    edited.apply(&Op::Edit { id: "q-1".into(), revision: 1, editing: true, owner: B }).unwrap();
    assert!(edited.apply(&claim).is_err());
    let mut free = base;
    assert!(free.apply(&claim).is_ok());
}

#[test]
fn a_written_send_removes_the_item_and_awaits_the_agent() {
    let mut record = record();
    add(&mut record, "q-1", "one");
    add(&mut record, "q-2", "two");
    record.apply(&Op::Claim { id: "q-1".into(), owner: A, binding: bound() }).unwrap();
    record.apply(&Op::Finish { id: "q-1".into(), owner: A, outcome: Outcome::Written }).unwrap();
    assert_eq!(record.items.iter().map(|item| item.id.as_str()).collect::<Vec<_>>(), ["q-2"]);
    let sent = Awaiting { owner: A, item: "q-1".into() };
    assert_eq!(record.awaiting, Some(sent.clone()));
    // Nobody sends the next one until the agent acknowledges.
    assert!(record.apply(&Op::Claim { id: "q-2".into(), owner: B, binding: bound() }).is_err());
    // An acknowledgement of another send leaves this one awaited.
    record.apply(&Op::Acknowledge(Awaiting { owner: A, item: "q-0".into() })).unwrap();
    assert!(record.awaiting.is_some());
    record.apply(&Op::Acknowledge(sent)).unwrap();
    assert!(record.apply(&Op::Claim { id: "q-2".into(), owner: B, binding: bound() }).is_ok());
}

#[test]
fn send_outcomes_pause_or_free_the_item() {
    for (outcome, pause) in [
        (Outcome::Uncertain, Some(Pause::Uncertain)),
        (Outcome::NeedsEdit, Some(Pause::NeedsEdit)),
        (Outcome::Retry, None),
    ] {
        let mut record = record();
        add(&mut record, "q-1", "one");
        record.apply(&Op::Claim { id: "q-1".into(), owner: A, binding: bound() }).unwrap();
        record.apply(&Op::Finish { id: "q-1".into(), owner: A, outcome }).unwrap();
        assert_eq!((record.items[0].pause, record.items[0].claim), (pause, None), "{outcome:?}");
        assert_eq!(record.awaiting, None);
    }
}

#[test]
fn a_gone_sender_leaves_an_uncertain_item_that_is_never_sent_again() {
    let mut record = record();
    add(&mut record, "q-1", "one");
    record.apply(&Op::Claim { id: "q-1".into(), owner: A, binding: bound() }).unwrap();
    record.items[0].editing = None;
    assert_eq!(record.foreign(&B), vec![A]);
    record.apply(&Op::Release(vec![A])).unwrap();
    assert_eq!((record.items[0].pause, record.items[0].claim), (Some(Pause::Uncertain), None));
    assert!(record.apply(&Op::Claim { id: "q-1".into(), owner: B, binding: bound() }).is_err());
    // The gone sender's late result changes nothing.
    let before = record.clone();
    record.apply(&Op::Finish { id: "q-1".into(), owner: A, outcome: Outcome::Written }).unwrap();
    assert_eq!(record, before);
    // Resume does not release an uncertain item either; only an edit (review) does.
    record.apply(&Op::Restore).unwrap();
    assert_eq!(record.items[0].pause, Some(Pause::Uncertain));
}

#[test]
fn a_gone_helper_releases_its_awaiting_and_edits() {
    let mut record = record();
    add(&mut record, "q-1", "one");
    record.awaiting = Some(Awaiting { owner: A, item: "q-0".into() });
    record.items[0].editing = Some(A);
    record.hold = Some(A);
    record.apply(&Op::Release(vec![A])).unwrap();
    assert_eq!((record.awaiting.clone(), record.items[0].editing, record.items[0].pause, record.hold), (None, None, None, None));
}

#[test]
fn an_item_in_flight_cannot_be_changed_or_taken() {
    let mut record = record();
    let item = add(&mut record, "q-1", "one");
    record.apply(&Op::Claim { id: "q-1".into(), owner: A, binding: bound() }).unwrap();
    let update = Op::Update { id: "q-1".into(), revision: item.revision, text: None, command: None, binding: bound() };
    assert_eq!(record.apply(&update).unwrap_err().code, "busy");
    assert_eq!(record.apply(&Op::Remove { id: "q-1".into(), revision: item.revision }).unwrap_err().code, "busy");
    let take = Op::Take { id: "q-1".into(), revision: item.revision, binding: bound() };
    assert_eq!(record.apply(&take).unwrap_err().code, "busy");
}

#[test]
fn send_now_takes_only_an_unpaused_item_for_its_agent() {
    let mut record = record();
    let item = add(&mut record, "q-1", "one");
    let other = Bound { pid: 99, ..bound() };
    let take = |binding: Bound| Op::Take { id: "q-1".into(), revision: item.revision, binding };
    assert_eq!(record.apply(&take(other)).unwrap_err().code, "invalid_input");
    record.apply(&Op::Stop).unwrap();
    assert_eq!(record.apply(&take(bound())).unwrap_err().code, "invalid_input");
    record.apply(&Op::Restore).unwrap();
    assert!(matches!(record.apply(&take(bound())), Ok(Answer::Taken(taken)) if taken.text == "one"));
    assert!(record.items.is_empty());
}

#[test]
fn stop_resume_and_revocation() {
    let mut record = record();
    add(&mut record, "q-1", "one");
    add(&mut record, "q-2", "two");
    record.items[1].pause = Some(Pause::Uncertain);
    record.apply(&Op::Stop).unwrap();
    assert_eq!(record.items.iter().map(|i| i.pause).collect::<Vec<_>>(), [Some(Pause::Stopped), Some(Pause::Uncertain)]);
    record.apply(&Op::Restore).unwrap();
    assert_eq!(record.items.iter().map(|i| i.pause).collect::<Vec<_>>(), [None, Some(Pause::Uncertain)]);
    record.apply(&Op::Revoke).unwrap();
    // Held only by the helper that lost its permission: the store's hold is the clients' own.
    assert!(record.hold.is_none());
    assert!(record.items.iter().all(|item| item.pause == Some(Pause::Stopped)));
}

#[test]
fn reorder_needs_exactly_the_queued_ids() {
    let mut record = record();
    add(&mut record, "q-1", "one");
    add(&mut record, "q-2", "two");
    assert!(record.apply(&Op::Reorder(vec!["q-2".into()])).is_err());
    assert!(record.apply(&Op::Reorder(vec!["q-2".into(), "q-3".into()])).is_err());
    record.apply(&Op::Reorder(vec!["q-2".into(), "q-1".into()])).unwrap();
    assert_eq!(record.items[0].id, "q-2");
}

#[test]
fn a_moved_head_is_paused_unless_it_is_in_flight() {
    let mut record = record();
    add(&mut record, "q-1", "one");
    record.apply(&Op::Moved { id: "q-1".into() }).unwrap();
    assert_eq!(record.items[0].pause, Some(Pause::DestinationChanged));
    let mut flight = self::record();
    add(&mut flight, "q-1", "one");
    flight.apply(&Op::Claim { id: "q-1".into(), owner: A, binding: bound() }).unwrap();
    flight.apply(&Op::Moved { id: "q-1".into() }).unwrap();
    assert_eq!(flight.items[0].pause, None);
}

#[test]
fn a_leaving_client_ends_only_its_own_edits() {
    let mut record = record();
    add(&mut record, "q-1", "one");
    add(&mut record, "q-2", "two");
    record.items[0].editing = Some(A);
    record.items[1].editing = Some(A);
    record.hold = Some(A);
    record.apply(&Op::Left { owner: A, ids: vec!["q-1".into()], hold: false }).unwrap();
    assert_eq!((record.items[0].editing, record.items[1].editing, record.hold), (None, Some(A), Some(A)));
    record.apply(&Op::Left { owner: A, ids: Vec::new(), hold: true }).unwrap();
    assert_eq!(record.hold, None);
}

#[test]
fn an_emptied_queue_keeps_its_file_only_while_held() {
    let mut record = record();
    assert!(record.empty());
    record.apply(&Op::Hold { held: true, owner: A }).unwrap();
    assert!(!record.empty());
    record.apply(&Op::Hold { held: false, owner: A }).unwrap();
    add(&mut record, "q-1", "one");
    assert!(!record.empty());
}

#[test]
fn only_an_unpaused_head_is_sent_without_a_client() {
    let mut record = record();
    assert!(!record.sendable());
    add(&mut record, "q-1", "one");
    add(&mut record, "q-2", "two");
    assert!(record.sendable());
    record.items[0].pause = Some(Pause::Uncertain);
    // The drain never passes a paused head: the second item waits for review too.
    assert!(!record.sendable());
    record.items[0].pause = None;
    record.hold = Some(A);
    assert!(!record.sendable());
}

#[test]
fn a_claim_moved_off_the_head_still_blocks_every_other_send() {
    let mut record = record();
    let x = add(&mut record, "q-x", "x");
    let y = add(&mut record, "q-y", "y");
    record.apply(&Op::Claim { id: "q-x".into(), owner: A, binding: bound() }).unwrap();
    // A client reorders while X is being typed: Y is the head now, but nothing else may be typed.
    record.apply(&Op::Reorder(vec!["q-y".into(), "q-x".into()])).unwrap();
    assert_eq!(record.apply(&Op::Claim { id: "q-y".into(), owner: B, binding: bound() }).unwrap_err().code, "busy");
    let take = Op::Take { id: "q-y".into(), revision: y.revision, binding: bound() };
    assert_eq!(record.apply(&take).unwrap_err().code, "busy");
    record.apply(&Op::Finish { id: "q-x".into(), owner: A, outcome: Outcome::Retry }).unwrap();
    assert!(record.apply(&take).is_ok());
    let _ = x;
}

#[test]
fn a_claim_needs_the_binding_the_drain_checked() {
    let mut record = record();
    add(&mut record, "q-1", "one");
    let other = Bound { pid: 7, ..bound() };
    assert_eq!(record.apply(&Op::Claim { id: "q-1".into(), owner: A, binding: other }).unwrap_err().code, "busy");
}

#[test]
fn a_hold_ends_with_its_owner() {
    let mut record = record();
    add(&mut record, "q-1", "one");
    record.apply(&Op::Hold { held: true, owner: A }).unwrap();
    assert!(!record.sendable());
    record.apply(&Op::Release(vec![B])).unwrap();
    assert!(!record.sendable());
    record.apply(&Op::Release(vec![A])).unwrap();
    assert!(record.sendable());
}

#[test]
fn an_unacknowledged_send_keeps_the_file_and_its_own_loss_spares_edits() {
    let mut record = record();
    add(&mut record, "q-1", "one");
    record.apply(&Op::Claim { id: "q-1".into(), owner: A, binding: bound() }).unwrap();
    record.apply(&Op::Finish { id: "q-1".into(), owner: A, outcome: Outcome::Written }).unwrap();
    assert!(record.items.is_empty() && !record.empty());
    add(&mut record, "q-2", "two");
    record.items[0].editing = Some(A);
    record.apply(&Op::Lost(A)).unwrap();
    assert_eq!((record.awaiting.clone(), record.items[0].editing), (None, Some(A)));
    assert!(record.items.iter().all(|item| item.pause.is_none()));
}

#[test]
fn placeholder_marks_take_the_helpers_identity() {
    let op = Op::Edit { id: "q-1".into(), revision: 1, editing: true, owner: UNSET }.resolved(A);
    assert_eq!(op, Op::Edit { id: "q-1".into(), revision: 1, editing: true, owner: A });
    let op = Op::Hold { held: true, owner: B }.resolved(A);
    assert_eq!(op, Op::Hold { held: true, owner: B });
}

fn attached(record: &mut Record, id: &str, text: &str, attachments: Vec<Attachment>) -> Queued {
    let op = Op::Add { id: id.into(), text: text.into(), mode: Mode::Prompt, command: false, binding: bound(), attachments };
    match record.apply(&op).unwrap() {
        Answer::Added(queued) => queued,
        other => panic!("{other:?}"),
    }
}

fn files() -> Vec<Attachment> {
    let path = |name: &str| format!("/home/sam/.dispatch/attachments/0123456789abcdef0123456789abcdef/{name}");
    vec![
        Attachment { path: path("diagram.png"), image: true },
        Attachment { path: path("notes.txt"), image: false },
    ]
}

#[test]
fn a_file_without_attachments_stays_format_1_and_one_with_them_is_format_2() {
    let format = |record: &Record| {
        body::decode_plain(&record.encode().unwrap()).unwrap().get("format").and_then(Data::unsigned).unwrap()
    };
    let mut record = record();
    add(&mut record, "q-1", "plain");
    assert_eq!(format(&record), 1, "what older helpers read, as before");
    let plain = record.encode().unwrap();
    assert!(!String::from_utf8_lossy(&plain).contains("attachments"));
    attached(&mut record, "q-2", "with files", files());
    assert_eq!(format(&record), 2);
    let decoded = Record::decode(&record.encode().unwrap()).unwrap();
    assert_eq!(decoded, record);
    assert_eq!(decoded.items[1].attachments, files());
    // Once it is sent the file is format 1 again, as an older helper wrote it.
    record.items.pop();
    record.serial = 1;
    assert_eq!(record.encode().unwrap(), plain);
}

#[test]
fn a_format_1_file_reads_with_no_attachments() {
    let mut record = record();
    add(&mut record, "q-1", "plain");
    let decoded = Record::decode(&record.encode().unwrap()).unwrap();
    assert!(decoded.items[0].attachments.is_empty());
    let damaged = body::encode_plain(&Data::Object(vec![("format", Data::Unsigned(2)), ("items", Data::Array(vec![
        Data::Object(vec![("attachments", Data::String("not a list"))]),
    ]))])).unwrap();
    assert_eq!(Record::decode(&damaged).unwrap_err().code, "storage");
}

#[test]
fn an_item_with_attachments_previews_them_and_is_not_editable() {
    let mut record = record();
    let queued = attached(&mut record, "q-1", "Look", files());
    assert_eq!(
        queued.preview,
        [Preview::Text("Look".into()), Preview::Attachment("image".into()), Preview::Attachment("file".into())]
    );
    assert!(!queued.editable);
    // Only the attachments: no empty text preview.
    let only = attached(&mut record, "q-2", "", files()[..1].to_vec());
    assert_eq!(only.preview, [Preview::Attachment("image".into())]);
    let plain = add(&mut record, "q-3", "plain");
    assert_eq!((plain.preview, plain.editable), (vec![Preview::Text("plain".into())], true));
    // An edit is refused; removing it is not.
    let edit = Op::Update { id: "q-1".into(), revision: queued.revision, text: Some("other".into()), command: None, binding: bound() };
    assert_eq!(record.apply(&edit).unwrap_err().code, "invalid_input");
    let remove = Op::Update { id: "q-1".into(), revision: queued.revision, text: None, command: None, binding: bound() };
    record.apply(&remove).unwrap();
    assert_eq!(record.items.len(), 2);
}
