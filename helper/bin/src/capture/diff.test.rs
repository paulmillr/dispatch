use super::*;
use super::super::tests::{layered, on, record, scratch, write};
use dispatch_helper_core::{json::Data, system::capture::trace, wire::{self, body}};

fn packet(kind: wire::Kind, id: u64, value: &Data<'_>) -> Vec<u8> {
    wire::packet(kind, id, &body::encode(value).unwrap()).unwrap()
}

fn request(id: u64, method: &str, params: Data<'_>) -> Vec<u8> {
    packet(wire::Kind::Request, id, &Data::Object(vec![("method", Data::String(method)), ("params", params)]))
}

fn read(path: &str, host: &str) -> Vec<u8> {
    request(1, "files.read", Data::Object(vec![("path", Data::String(path)), ("host", Data::String(host))]))
}

fn changed(old: Option<&str>, new: Option<&str>, first: String) -> Group {
    Group { change: (old.map(String::from), new.map(String::from)), count: 1, pairs: 1, first }
}

#[test]
fn two_captures_differ_once_at_each_place_their_decoded_values_do() {
    let root = scratch("diff-two");
    let (a, b) = (root.join("a.rpl.zst"), root.join("b.rpl.zst"));
    let reply = |result: Data<'_>| packet(wire::Kind::Response, 1, &Data::Object(vec![("result", result)]));
    // A request frame's two params, a reply's field only in a, a record only in a and one only in b, bytes that are no
    // text, and a request frame b recorded as other bytes.
    write(&a, &[
        on("app/3", record("out.wire", &Data::Bytes(&read("/home/alice/notes", "198.51.100.23")), &Data::Null)),
        on("app/3", record("in.read", &Data::Null, &Data::Bytes(&reply(Data::Object(vec![("size", Data::Unsigned(12)), ("owner", Data::String("alice"))]))))),
        on("app/4", record("in.size", &Data::Null, &Data::Object(vec![("rows", Data::Unsigned(24))]))),
        on("app/5", record("in.output", &Data::Null, &Data::Bytes(&[0xfe, 0xff, b' ', b'A']))),
        on("app/6", record("out.wire", &Data::Bytes(&request(2, "files.list", Data::Object(Vec::new()))), &Data::Null)),
    ]);
    write(&b, &[
        on("app/3", record("out.wire", &Data::Bytes(&read("/home/bobby/notes", "198.51.7.4")), &Data::Null)),
        on("app/3", record("in.read", &Data::Null, &Data::Bytes(&reply(Data::Object(vec![("size", Data::Unsigned(12))]))))),
        on("app/5", record("in.output", &Data::Null, &Data::Bytes(&[0xfe, 0xfd, b' ', b'A']))),
        on("app/6", record("out.wire", &Data::Bytes(b"not a frame"), &Data::Null)),
        on("app/7", record("in.hangup", &Data::Null, &Data::Null)),
    ]);
    let place = |i: &str, j: &str, rest: &str| format!("{}:{i} {}:{j} {rest}", a.display(), b.display());
    let found = (compare(&a, &a, 1).map_err(|error| error.to_string()), compare(&a, &b, 1).map_err(|error| error.to_string()));
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(found, (Ok(Compared { pairs: 1, groups: Vec::new(), unpaired: Vec::new() }), Ok(Compared { pairs: 1, groups: vec![
        changed(None, Some("app/7 in.hangup"), place("-", "4", "app/7 in.hangup")),
        changed(None, Some("b\"not a frame\""), place("4", "3", "app/6 out.wire args[0]")),
        changed(Some("\"100.23\""), Some("\"7.4\""), place("0", "0", "app/3 out.wire args[0] request 1 files.read.host")),
        changed(Some("\"alice\""), Some("\"bobby\""), place("0", "0", "app/3 out.wire args[0] request 1 files.read.path")),
        changed(Some("app/4 in.size -> {rows: 24}"), None, place("2", "-", "app/4 in.size")),
        changed(Some("hex(ff)"), Some("hex(fd)"), place("3", "2", "app/5 in.output output[0]")),
        changed(Some("owner: \"alice\""), None, place("1", "1", "app/3 in.read output[0] response 1.result")),
        changed(Some("request 2 files.list {}"), None, place("4", "3", "app/6 out.wire args[0]")),
    ], unpaired: Vec::new() })));
}

#[test]
fn directories_pair_each_tests_captures_by_their_records_whatever_their_names() {
    let root = scratch("diff-dirs");
    let size = |rows| vec![on("app/1", record("in.size", &Data::Null, &Data::Object(vec![("rows", Data::Unsigned(rows))])))];
    let opened = |path: &str| vec![
        on("app/1", record("out.wire", &Data::Bytes(&read(path, "h")), &Data::Null)),
        on("app/1", record("in.hangup", &Data::Null, &Data::Null)),
    ];
    let (a, b) = (root.join("a"), root.join("b"));
    // Three of a test's captures with the same records but other values, named in another order on each side: each
    // pairs with its own.
    for (index, rows) in [24, 30, 36].into_iter().enumerate() {
        write(&a.join(format!("T/a{index}.rpl.zst")), &size(rows));
        write(&b.join(format!("T/b{}.rpl.zst", (index + 1) % 3)), &size(rows));
    }
    write(&a.join("T/a3.rpl.zst"), &opened("/home/alice"));
    write(&a.join("U/x.rpl.zst"), &size(24));
    write(&b.join("T/zz.rpl.zst"), &opened("/home/bobby"));
    write(&b.join("V/new.rpl.zst"), &[on("app/1", record("in.read", &Data::Null, &Data::Null))]);
    let found = compare(&a, &b, 2).map_err(|error| error.to_string());
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(found, Ok(Compared { pairs: 4, groups: vec![changed(Some("\"alice\""), Some("\"bobby\""), format!("{}:0 {}:0 app/1 out.wire args[0] request 1 files.read.path",
        a.join("T/a3.rpl.zst").display(), b.join("T/zz.rpl.zst").display()))], unpaired: vec![a.join("U/x.rpl.zst"), b.join("V/new.rpl.zst")] }));
}

#[test]
fn an_app_journal_and_a_helper_capture_are_not_compared() {
    let root = scratch("diff-layers");
    let (a, b) = (root.join("a.rpl.zst"), root.join("b.rpl.zst"));
    write(&a, &[record("in.read", &Data::Null, &Data::Null)]);
    layered(&b, trace::Layer::Native, &[record("in.read", &Data::Null, &Data::Null)]);
    let found = compare(&a, &b, 1).map(|_| ()).map_err(|error| error.to_string());
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(found, Err(format!("{} and {}: layers differ (App and Native)", a.display(), b.display())));
}

#[test]
fn values_too_different_to_align_are_one_change_shown_shortened() {
    let root = scratch("diff-far");
    let (a, b) = (root.join("a.rpl.zst"), root.join("b.rpl.zst"));
    let text = |letter: char| (0..1500).map(|index| format!("{letter}{index}")).collect::<Vec<_>>().join(" ");
    let (old, new) = (text('a'), text('b'));
    write(&a, &[record("in.output", &Data::Null, &Data::String(&old))]);
    write(&b, &[record("in.output", &Data::Null, &Data::String(&new))]);
    let found = compare(&a, &b, 1).map_err(|error| error.to_string());
    std::fs::remove_dir_all(&root).unwrap();
    let shortened = |text: &str| format!("{:?} ... ({} bytes)", &text[..1000], text.len());
    assert_eq!(found, Ok(Compared { pairs: 1, groups: vec![changed(Some(&shortened(&old)), Some(&shortened(&new)),
        format!("{}:0 {}:0 app in.output output[0]", a.display(), b.display()))], unpaired: Vec::new() }));
}

#[test]
fn a_word_ends_at_a_terminal_escape_and_at_a_character_beyond_ascii() {
    let root = scratch("diff-words");
    let (a, b) = (root.join("a.rpl.zst"), root.join("b.rpl.zst"));
    let shown = |name: &str| format!("\x1b[0;39;49m{name}@host \x1b]0;{name}\x07│{name}│ é{name}");
    write(&a, &[record("in.output", &Data::Null, &Data::String(&shown("alice")))]);
    write(&b, &[record("in.output", &Data::Null, &Data::String(&shown("bobby")))]);
    let found = compare(&a, &b, 1).map_err(|error| error.to_string());
    std::fs::remove_dir_all(&root).unwrap();
    // The name in a colored prompt, a window title, between box lines and after an accented letter: four times the
    // same change.
    let first = format!("{}:0 {}:0 app in.output output[0]", a.display(), b.display());
    assert_eq!(found, Ok(Compared { pairs: 1, groups: vec![Group { count: 4, ..changed(Some("\"alice\""), Some("\"bobby\""), first) }],
        unpaired: Vec::new() }));
}

#[test]
fn a_long_word_that_changed_shows_where_it_differs() {
    let root = scratch("diff-long");
    let (a, b) = (root.join("a.rpl.zst"), root.join("b.rpl.zst"));
    let word = |name: &str| format!("{}{name}{}", "x".repeat(1500), "y".repeat(1500));
    write(&a, &[record("in.output", &Data::Null, &Data::String(&word("alice")))]);
    write(&b, &[record("in.output", &Data::Null, &Data::String(&word("bobby")))]);
    let found = compare(&a, &b, 1).map_err(|error| error.to_string());
    std::fs::remove_dir_all(&root).unwrap();
    let around = |name: &str| format!("... {:?} ... (3005 bytes)", format!("{}{name}{}", "x".repeat(40), "y".repeat(40)));
    assert_eq!(found, Ok(Compared { pairs: 1, groups: vec![changed(Some(&around("alice")), Some(&around("bobby")),
        format!("{}:0 {}:0 app in.output output[0]", a.display(), b.display()))], unpaired: Vec::new() }));
}
