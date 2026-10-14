use super::*;
use std::io::{Cursor, Read, Write};

fn system(level: u8, input: &[u8]) -> Vec<u8> {
    let mut command = std::process::Command::new("bzip2")
        .arg(format!("-{level}c"))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = command.stdin.take().unwrap();
    let source = input.to_vec();
    let feeder = std::thread::spawn(move || stdin.write_all(&source));
    let output = command.wait_with_output().unwrap();
    feeder.join().unwrap().unwrap();
    assert!(output.status.success());
    output.stdout
}

#[test]
fn encoder_matches_system_bzip2_for_any_write_split() {
    let mut source: Vec<_> = (0..210_000).map(|i| (i % 251) as u8).collect();
    source.extend([b'x'; 259]);
    for level in [1, 9] {
        let expected = system(level, &source);
        for chunk in [1, 17, 8192] {
            let mut encoder = Encoder::new(Vec::new(), level).unwrap();
            for bytes in source.chunks(chunk) {
                encoder.write_all(bytes).unwrap();
            }
            let encoded = encoder.finish().unwrap();
            assert_eq!(encoded, expected);
            let mut decoder = Decoder::new(encoded.as_slice(), source.len()).unwrap();
            let mut decoded = Vec::new();
            let mut buffer = vec![0; chunk];
            for _ in 0.. {
                let count = decoder.read(&mut buffer).unwrap();
                if count == 0 {
                    break;
                }
                decoded.extend_from_slice(&buffer[..count]);
            }
            assert_eq!(decoded, source);
        }
        let mut decoder = Decoder::new(expected.as_slice(), source.len() - 1).unwrap();
        assert!(decoder.read_to_end(&mut Vec::new()).is_err(), "expansion bound");
    }
}

#[test]
fn errors_never_certify_a_stream() {
    let mut encoder = Encoder::new(Vec::new(), 9).unwrap();
    encoder.write_all(b"hello\0world").unwrap();
    let encoded = encoder.finish().unwrap();
    for end in 0..encoded.len() {
        let mut input = Decoder::new(Cursor::new(encoded[..end].to_vec()), 11).unwrap();
        assert!(input.read_to_end(&mut Vec::new()).is_err(), "accepted truncation {end}");
    }
    let mut damaged = encoded.clone();
    damaged[10] ^= 1;
    let mut trailing = encoded.clone();
    trailing.push(0);
    for source in [damaged, trailing, b"not bzip2".to_vec()] {
        let mut input = Decoder::new(Cursor::new(source), 11).unwrap();
        assert!(input.read_to_end(&mut Vec::new()).is_err());
        assert!(input.read(&mut [0; 1]).is_err());
    }
    for level in [0, 10] {
        assert!(Encoder::new(Vec::new(), level).is_err());
    }
    struct Fault;
    impl Write for Fault {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::ErrorKind::PermissionDenied.into())
        }
        fn flush(&mut self) -> io::Result<()> {
            Err(io::ErrorKind::PermissionDenied.into())
        }
    }
    let mut encoder = Encoder::new(Fault, 9).unwrap();
    let _ = encoder.write_all(&[0; 8192]);
    assert_eq!(encoder.finish().err().unwrap().kind(), io::ErrorKind::PermissionDenied);
}
