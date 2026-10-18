use super::*;
use crate::json::Json;

#[test]
fn agent_json_with_a_repeated_key_is_refused_when_encoded_not_when_read() {
    // root() expects what was checked when made; the reader refuses a repeated key at any depth.
    let repeated = Json::parse(br#"{"turn":{"model":"m1","model":"m2"}}"#).unwrap();
    assert_eq!(Encoded::value(&Data::Value(repeated.root())).map(|_| ()), Err(crate::dispatch::invalid("request")));
    let distinct = Json::parse(br#"{"turn":{"model":"m1","effort":"high"}}"#).unwrap();
    let made = Encoded::value(&Data::Value(distinct.root())).unwrap();
    assert_eq!(encode_plain(&made.root()), encode_plain(&Data::Value(distinct.root())));
}

/// A wire body: an array holding one array of `count` nulls per count.
fn arrays(counts: &[usize]) -> Vec<u8> {
    let mut out = SCHEMA.to_vec();
    array(&mut out, counts.len());
    for count in counts {
        array(&mut out, *count);
        out.resize(out.len() + count, 0);
    }
    out
}

#[test]
fn a_wire_body_holds_at_most_values_values_in_all_its_arrays() {
    // Every array is a value too: VALUES in all, then one more, in one array or spread over two.
    let decoded = |counts: &[usize]| decode(&arrays(counts)).map(|_| ()).map_err(|error| error.code);
    assert_eq!(decoded(&[VALUES - 2]), Ok(()));
    assert_eq!(decoded(&[VALUES / 2, VALUES / 2 - 3]), Ok(()));
    assert_eq!(decoded(&[VALUES - 1]), Err("protocol"));
    assert_eq!(decoded(&[VALUES / 2, VALUES / 2 - 2]), Err("protocol"));
    // A plain value is the helper's own (a capture's, a job's): not counted.
    assert!(decode_plain(&arrays(&[VALUES])[SCHEMA.len()..]).is_ok());
}

/// `value` encoded by core, as the wire carries it: a schema record (tag 10), not a keyed object, read back as `expected`.
fn round_trip(value: &dyn crate::encode::Encode, expected: Data<'_>) {
    let encoded = crate::encode::value(value);
    assert_eq!(encoded[0], 10, "a schema record");
    let mut body = SCHEMA.to_vec();
    body.extend_from_slice(&encoded);
    let decoded = decode(&body).unwrap();
    assert_eq!(encode_plain(&decoded).unwrap(), encode_plain(&expected).unwrap());
}

#[test]
fn files_records_round_trip_as_schema_records() {
    use crate::api::*;
    let object = |fields: Vec<(&'static str, Data<'static>)>| Data::Object(fields);
    let entry = |name: &'static str, kind, target, mark: Option<&str>| Entry {
        name: name.into(),
        kind,
        size: 42,
        modified_ns: -1_500,
        target,
        mark: mark.map(str::to_owned),
        device: 7,
        inode: 11,
    };
    let link = entry("docs", FileKind::Symlink, Some(FileKind::Directory), Some("M"));
    let dangling = entry("gone", FileKind::Symlink, None, None);
    let entry_data = |name, target: Data<'static>, mark: Data<'static>| {
        object(vec![
            ("name", Data::String(name)),
            ("kind", Data::String("symlink")),
            ("size", Data::Unsigned(42)),
            ("modified_ns", Data::String("-1500")),
            ("device", Data::Unsigned(7)),
            ("inode", Data::Unsigned(11)),
            ("target", target),
            ("mark", mark),
        ])
    };
    round_trip(&link, entry_data("docs", Data::String("directory"), Data::String("M")));
    round_trip(&dangling, entry_data("gone", Data::Null, Data::Null));
    round_trip(
        &Listing {
            path: "/tmp".into(),
            entries: vec![link.clone(), dangling.clone()],
            truncated: true,
            device: 13,
            inode: 17,
        },
        object(vec![
            ("path", Data::String("/tmp")),
            (
                "entries",
                Data::Array(vec![
                    entry_data("docs", Data::String("directory"), Data::String("M")),
                    entry_data("gone", Data::Null, Data::Null),
                ]),
            ),
            ("truncated", Data::Bool(true)),
            ("device", Data::Unsigned(13)),
            ("inode", Data::Unsigned(17)),
        ]),
    );
    round_trip(
        &FolderSummary { files: 1, folders: 2, bytes: 3, truncated: false },
        object(vec![
            ("files", Data::Unsigned(1)),
            ("folders", Data::Unsigned(2)),
            ("bytes", Data::Unsigned(3)),
            ("truncated", Data::Bool(false)),
        ]),
    );
    round_trip(
        &Packed { archive: "/tmp/a.tar.zst".into(), entries: 1, files: 2, folders: 3, bytes: 4, size: 5, skipped: 6 },
        object(vec![
            ("archive", Data::String("/tmp/a.tar.zst")),
            ("entries", Data::Unsigned(1)),
            ("files", Data::Unsigned(2)),
            ("folders", Data::Unsigned(3)),
            ("bytes", Data::Unsigned(4)),
            ("size", Data::Unsigned(5)),
            ("skipped", Data::Unsigned(6)),
        ]),
    );
    round_trip(
        &Transfer { transfer: "t1".into(), staging: "/tmp/.dispatch-copy-x".into() },
        object(vec![("transfer", Data::String("t1")), ("staging", Data::String("/tmp/.dispatch-copy-x"))]),
    );
    round_trip(&Progress { bytes: 7 }, object(vec![("bytes", Data::Unsigned(7))]));
    round_trip(
        &Unpacked { entries: 1, bytes: 2, replaced: 3, kept: 4, skipped: 5 },
        object(vec![
            ("entries", Data::Unsigned(1)),
            ("bytes", Data::Unsigned(2)),
            ("replaced", Data::Unsigned(3)),
            ("kept", Data::Unsigned(4)),
            ("skipped", Data::Unsigned(5)),
        ]),
    );
    round_trip(
        &Git { status: -1, output: "fatal".into(), truncated: false },
        object(vec![("status", Data::Signed(-1)), ("output", Data::String("fatal")), ("truncated", Data::Bool(false))]),
    );
}
