use super::*;
use crate::{json::Data, wire::body};
use std::io::{Cursor, Read, Write};

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

type Start = fn(Vec<u8>, &Header) -> io::Result<Writer<Vec<u8>>>;

fn capture(start: Start, records: &[Record], checkpoint: usize) -> Vec<u8> {
    let header = Header {
        layer: Layer::App,
        wire: 19,
    };
    let mut writer = start(Vec::new(), &header).unwrap();
    for (index, record) in records.iter().enumerate() {
        if index == checkpoint {
            writer.checkpoint().unwrap();
        }
        writer.push(record).unwrap();
    }
    writer.finish().unwrap()
}

#[test]
fn records_round_trip_through_zstd_and_the_system_tool() {
    round_trip(Writer::new);
    round_trip(Writer::corpus);
    let records = [record(&(0..180_000).map(|i| (i % 251) as u8).collect::<Vec<_>>())];
    let bytes: Vec<u8> = (0..180_000).map(|i| (i % 251) as u8).collect();
    assert!(matches!(body::decode_plain(&records[0].output).unwrap(), Data::Bytes(value) if value == bytes));
}

fn round_trip(start: Start) {
    let records: Vec<_> = [vec![], (0..180_000).map(|i| (i % 251) as u8).collect()]
        .iter()
        .map(|bytes| record(bytes))
        .collect();
    for checkpoint in [0, 1, 2] {
        let compressed = capture(start, &records, checkpoint);
        let (header, read) = read(Cursor::new(&compressed), 1 << 24).unwrap();
        assert_eq!(header, Header { layer: Layer::App, wire: 19 });
        assert_eq!(read, records);
        // A checkpoint ends one zstd frame; the zstd tool reads the frames as one stream, as our decoder does.
        let mut raw = Vec::new();
        super::super::zstd::Decoder::new(Cursor::new(&compressed), 1 << 24).unwrap().read_to_end(&mut raw).unwrap();
        let Ok(mut command) = std::process::Command::new("zstd")
            .args(["-dc", "--long=27"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
        else {
            continue;
        };
        let mut stdin = command.stdin.take().unwrap();
        let feeder = std::thread::spawn(move || stdin.write_all(&compressed));
        let expanded = command.wait_with_output().unwrap();
        feeder.join().unwrap().unwrap();
        assert!(expanded.status.success());
        assert_eq!(expanded.stdout, raw);
    }
}

#[test]
fn a_cut_or_damaged_capture_is_never_whole() {
    cut_or_damaged(Writer::new);
    cut_or_damaged(Writer::corpus);
}

fn cut_or_damaged(start: Start) {
    let records = vec![record(b"one"), record(b"two")];
    let whole = capture(start, &records, 1);
    // Only the checkpoint's frame boundary is a whole capture: of the records before it.
    let boundary = capture(start, &records[..1], usize::MAX).len();
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
    let mut writer = start(Vec::new(), &Header { layer: Layer::Native, wire: 1 }).unwrap();
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

#[test]
fn the_corpus_stores_a_payload_recorded_again_once() {
    // A helper binary uploaded again and again: far apart, beyond a live capture's window and zstd's own level-9 one.
    let mut state = 0x9e37_79b9_7f4a_7c15u64;
    let payload: Vec<u8> = (0..20 << 20)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state as u8
        })
        .collect();
    let chunks: Vec<_> = payload.chunks(1 << 20).collect();
    let records: Vec<_> = chunks.iter().chain(&chunks).chain(&chunks).map(|chunk| record(chunk)).collect();
    let compressed = capture(Writer::corpus, &records, usize::MAX);
    assert!(compressed.len() < payload.len() + (payload.len() >> 4), "{} bytes", compressed.len());
    assert_eq!(read(Cursor::new(&compressed), 1 << 27).unwrap().1, records);
}
