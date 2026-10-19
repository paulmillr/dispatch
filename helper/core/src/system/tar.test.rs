use super::*;

fn header(name: &[u8], kind: Kind, size: u64) -> Header {
    Header {
        name: name.to_vec(),
        kind,
        mode: if kind == Kind::Directory { 0o755 } else { 0o600 },
        uid: 501,
        gid: 20,
        size,
        modified: (1_700_000_000, 123_456_789),
        link: Vec::new(),
    }
}

/// `entries` with their contents written as one archive.
fn archive(entries: &[(Header, Vec<u8>)]) -> Vec<u8> {
    let mut writer = Writer::new(Vec::new());
    for (h, content) in entries {
        writer.entry(h).unwrap();
        writer.write_all(content).unwrap();
    }
    writer.finish().unwrap()
}

fn read(bytes: &[u8]) -> io::Result<Vec<(Header, Vec<u8>)>> {
    let mut reader = Reader::new(bytes);
    let mut entries = Vec::new();
    while let Some(h) = reader.next()? {
        let mut content = Vec::new();
        reader.read_to_end(&mut content)?;
        entries.push((h, content));
    }
    Ok(entries)
}

fn sample() -> Vec<(Header, Vec<u8>)> {
    let long_name = vec![b'n'; 150];
    let deep: Vec<u8> = (0..30).map(|i| format!("folder{i:03}")).collect::<Vec<_>>().join("/").into_bytes();
    assert!(deep.len() > 255);
    let split = [vec![b'd'; 120], b"/".to_vec(), vec![b'f'; 90]].concat();
    let mut link = header(b"link", Kind::Symlink, 0);
    link.link = [b"../".repeat(10), vec![b't'; 200]].concat();
    let mut big = header(b"ids", Kind::File, 3);
    (big.uid, big.gid) = (3_000_000, 4_000_000);
    let mut old = header(b"old", Kind::File, 0);
    old.modified = (-86_400 - 1, 250_000_000);
    let mut whole = header(b"whole", Kind::File, 0);
    whole.modified = (1_000, 0);
    whole.mode = 0o755;
    vec![
        (header(b"top", Kind::Directory, 0), Vec::new()),
        (header(b"top/empty", Kind::File, 0), Vec::new()),
        (header(b"top/text", Kind::File, 5), b"hello".to_vec()),
        (header(&long_name, Kind::File, 600), vec![7; 600]),
        (header(&deep, Kind::Directory, 0), Vec::new()),
        (header(&split, Kind::File, 1), b"x".to_vec()),
        (link, Vec::new()),
        (big, b"abc".to_vec()),
        (old, Vec::new()),
        (whole, Vec::new()),
    ]
}

#[test]
fn every_entry_comes_back_as_written_with_pax_for_what_ustar_cannot_hold() {
    let entries = sample();
    let bytes = archive(&entries);
    assert_eq!(bytes.len() % BLOCK, 0);
    assert!(bytes.ends_with(&[0; 2 * BLOCK]));
    assert_eq!(read(&bytes).unwrap(), entries);
    // The 120/90 split name needs no pax header; the 150-byte one does.
    let text = String::from_utf8_lossy(&bytes);
    assert!(text.contains(&format!("path={}\n", "n".repeat(150))));
    assert!(!text.contains(&format!("path={}", "d".repeat(120))));
    assert!(text.contains("mtime=1700000000.123456789\n"));
    assert!(text.contains("mtime=-86400.75\n"));
    assert!(text.contains("uid=3000000\n") && text.contains("gid=4000000\n"));
    // A whole second in range is the ustar field alone.
    assert!(!text.contains("mtime=1000\n"));
}

#[test]
fn a_size_past_eight_gibibytes_travels_in_pax() {
    let size = 9 << 30;
    let mut bytes = Vec::new();
    Writer::new(&mut bytes).entry(&header(b"huge", Kind::File, size)).unwrap();
    assert!(String::from_utf8_lossy(&bytes).contains(&format!("size={size}\n")));
    let read = Reader::new(bytes.as_slice()).next().unwrap().unwrap();
    assert_eq!(read, header(b"huge", Kind::File, size));
}

#[test]
fn a_cut_or_damaged_archive_is_refused() {
    let bytes = archive(&sample());
    for cut in [100, BLOCK, 3 * BLOCK + 7, bytes.len() - 2 * BLOCK] {
        let error = read(&bytes[..cut]).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData, "cut at {cut}: {error}");
    }
    let mut damaged = bytes.clone();
    damaged[10] ^= 1;
    assert!(read(&damaged).unwrap_err().to_string().contains("checksum"));
}

#[test]
fn hard_links_devices_and_fifos_are_refused() {
    for (flag, message) in [(b'1', "hard links"), (b'3', "devices"), (b'4', "devices"), (b'6', "fifos"), (b'L', "unsupported")] {
        let mut plain = header(b"entry", Kind::File, 0);
        plain.modified = (1_000, 0);
        let mut bytes = archive(&[(plain, Vec::new())]);
        bytes[156] = flag;
        bytes[148..156].fill(b' ');
        let sum: u64 = bytes[..BLOCK].iter().map(|&b| u64::from(b)).sum();
        octal(&mut bytes[148..155], sum);
        let error = read(&bytes).unwrap_err();
        assert!(error.to_string().contains(message), "{error}");
    }
}

#[test]
fn the_system_tar_lists_what_was_written() {
    let tar = Path::new("/usr/bin/tar");
    if !tar.exists() {
        eprintln!("no /usr/bin/tar: external check skipped");
        return;
    }
    let entries = sample();
    let directory = std::env::temp_dir().join(format!("dispatch-tar-test-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let file = directory.join("sample.tar");
    std::fs::write(&file, archive(&entries)).unwrap();
    let output = std::process::Command::new(tar).arg("-tf").arg(&file).output().unwrap();
    std::fs::remove_dir_all(&directory).unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let listed: Vec<_> = output.stdout.split(|&b| b == b'\n').filter(|l| !l.is_empty()).map(|l| l.strip_suffix(b"/").unwrap_or(l).to_vec()).collect();
    let names: Vec<_> = entries.iter().map(|(h, _)| h.name.clone()).collect();
    assert_eq!(listed, names);
}

use std::path::Path;
