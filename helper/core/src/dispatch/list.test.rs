use super::*;

fn record(kind: RecordKind, text: &str, time: Option<i64>) -> Record {
    Record { kind, text: text.into(), time_ms: time, ..Default::default() }
}

#[test]
fn a_row_shows_the_newest_assistant_text_and_the_newest_time() {
    let records = [
        record(RecordKind::User, "hello", Some(1)),
        record(RecordKind::Assistant, "first answer", Some(2)),
        record(RecordKind::Assistant, "  ", Some(3)),
        record(RecordKind::Tool, "ls", Some(4)),
    ];
    assert_eq!(last(&records), (Some("first answer".into()), Some(4)));
    assert_eq!(last(&[]), (None, None));
}

#[test]
fn a_long_answer_is_cut_at_a_character_boundary() {
    let text = "é".repeat(PREVIEW + 10);
    let (preview, _) = last(&[record(RecordKind::Assistant, &text, None)]);
    let preview = preview.unwrap();
    assert_eq!(preview.chars().count(), PREVIEW + 1);
    assert!(preview.ends_with('…'));
}

fn node(id: Id, key: &str, kind: Kind, detached: bool) -> Node {
    Node {
        id,
        key: key.into(),
        parent: None,
        kind,
        name: String::new(),
        renamed: None,
        cwd: None,
        size: None,
        agent: None,
        tty: None,
        detached,
    }
}

#[test]
fn activity_rows_name_the_published_node_and_its_key() {
    let mut nodes = BTreeMap::new();
    for (mux, local, key, kind, detached) in [
        (1, 4, "tmux:s:$1:@2", Kind::Tab, false),
        (1, 5, "tmux:s:$1:%3", Kind::Terminal, false),
        (1, 6, "tmux:s:$1:@7", Kind::Tab, true),
        (0, 4, "herdr:w:1:t:1", Kind::Tab, false),
    ] {
        let id = crate::dispatch::reference(mux, local);
        nodes.insert(id, (mux, node(id, key, kind, detached)));
    }
    // Node 4 of mux 1 is not mux 0's node 4; a closed node (9) and a detached one (6) have no row.
    let rows = seen(1, vec![(5, 2_000), (4, 1_000), (9, 3_000), (6, 4_000), (4, 1_000)], &nodes);
    let expected = |local, key: &str, kind, time_ms| Seen { node: crate::dispatch::reference(1, local), key: key.into(), kind, time_ms };
    assert_eq!(
        rows,
        vec![expected(4, "tmux:s:$1:@2", Kind::Tab, 1_000), expected(5, "tmux:s:$1:%3", Kind::Terminal, 2_000)]
    );
    assert!(seen(0, Vec::new(), &nodes).is_empty());
}

#[test]
fn an_activity_row_is_encoded_with_its_four_fields() {
    let row = Seen { node: 7, key: "tmux:s:$1:@2".into(), kind: Kind::Tab, time_ms: 1_792_410_353_000 };
    let mut out = crate::wire::body::SCHEMA.to_vec();
    crate::encode::Encode::encode(&row, &mut out);
    let value = crate::wire::body::decode(&out).unwrap();
    let keys: Vec<&str> = value.object().unwrap().map(|(key, _)| key).collect();
    assert_eq!(keys, ["node", "key", "kind", "time_ms"]);
    assert_eq!(value.get("node").and_then(Data::unsigned), Some(7));
    assert_eq!(value.get("key").and_then(Data::string), Some("tmux:s:$1:@2"));
    assert_eq!(value.get("kind").and_then(Data::string), Some("tab"));
    assert_eq!(value.get("time_ms").and_then(Data::unsigned), Some(1_792_410_353_000));
}
