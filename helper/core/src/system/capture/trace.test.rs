use super::*;
use crate::{json::Data, wire::body};
use std::io::{Cursor, Write};

fn record(output: &[u8]) -> Record {
    Record {
        section: "startup".into(),
        clock: 17,
        op: "read".into(),
        args: body::encode_plain(&Data::Array(vec![Data::Signed(-3), Data::Unsigned(7)])).unwrap(),
        sequence: 2,
        output: body::encode_plain(&Data::Bytes(output)).unwrap(),
        error: Some(-5),
    }
}

fn capture(records: &[Record], checkpoint: usize) -> Vec<u8> {
    let header = Header {
        layer: Layer::App,
        wire: 19,
    };
    let mut writer = Writer::new(Vec::new(), &header).unwrap();
    for (index, record) in records.iter().enumerate() {
        if index == checkpoint {
            writer.checkpoint().unwrap();
        }
        writer.push(record).unwrap();
    }
    writer.finish().unwrap()
}

#[test]
fn records_round_trip_through_bzip2_and_the_system_tool() {
    let records: Vec<_> = [vec![], (0..180_000).map(|i| (i % 251) as u8).collect()]
        .iter()
        .map(|bytes| record(bytes))
        .collect();
    for checkpoint in [0, 1, 2] {
        let compressed = capture(&records, checkpoint);
        let (header, read) = read(Cursor::new(&compressed), 1 << 24).unwrap();
        assert_eq!(header, Header { layer: Layer::App, wire: 19 });
        assert_eq!(read, records);
        // A checkpoint ends one bzip2 member; the system bzip2 reads the members as one stream.
        let mut command = std::process::Command::new("bzip2")
            .arg("-dc")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = command.stdin.take().unwrap();
        let feeder = std::thread::spawn(move || stdin.write_all(&compressed));
        let expanded = command.wait_with_output().unwrap();
        feeder.join().unwrap().unwrap();
        assert!(expanded.status.success());
        let mut raw = Vec::new();
        super::super::bzip2::decompress(Cursor::new(capture(&records, checkpoint)), &mut raw, 1 << 24).unwrap();
        assert_eq!(expanded.stdout, raw);
    }
    let bytes: Vec<u8> = (0..180_000).map(|i| (i % 251) as u8).collect();
    assert!(matches!(body::decode_plain(&records[1].output).unwrap(), Data::Bytes(value) if value == bytes));
}

#[test]
fn a_cut_or_damaged_capture_is_never_whole() {
    let records = vec![record(b"one"), record(b"two")];
    let whole = capture(&records, 1);
    // Only the checkpoint's member boundary is a whole capture: of the records before it.
    let boundary = capture(&records[..1], usize::MAX).len();
    for end in 0..whole.len() {
        match read(Cursor::new(&whole[..end]), 1 << 20) {
            Ok((_, read)) => assert!(end == boundary && read == records[..1], "accepted a cut at {end}"),
            Err(_) => assert_ne!(end, boundary),
        }
    }
    let mut damaged = whole.clone();
    let at = damaged.len() / 2;
    damaged[at] ^= 1;
    assert!(read(Cursor::new(&damaged), 1 << 20).is_err());
    let mut trailing = whole.clone();
    trailing.push(0);
    assert!(read(Cursor::new(&trailing), 1 << 20).is_err());
    assert!(read(Cursor::new(&whole), 16).is_err(), "expansion bound");
    // Records after the last footer: the footer of an earlier checkpoint does not cover them.
    let mut writer = Writer::new(Vec::new(), &Header { layer: Layer::Native, wire: 1 }).unwrap();
    writer.push(&records[0]).unwrap();
    writer.checkpoint().unwrap();
    writer.push(&records[1]).unwrap();
    writer.output.checkpoint().unwrap();
    let cut = writer.output.finish().unwrap();
    let (mut reader, _) = Reader::new(Cursor::new(&cut), 1 << 20).unwrap();
    assert_eq!(reader.next().unwrap(), Some(records[0].clone()));
    assert_eq!(reader.next().unwrap(), Some(records[1].clone()));
    assert!(reader.next().is_err());
}

#[test]
fn an_invalid_recording_is_refused_even_after_a_checkpoint() {
    let header = Header { layer: Layer::Native, wire: 1 };
    let mut writer = Writer::new(Vec::new(), &header).unwrap();
    writer.push(&record(b"one")).unwrap();
    writer.checkpoint().unwrap();
    let invalid = writer.invalid("capture queue overflow").unwrap();
    let error = read(Cursor::new(&invalid), 1 << 20).unwrap_err();
    assert_eq!(error.to_string(), "capture invalid: capture queue overflow");
}
