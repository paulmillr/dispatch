use super::*;
use crate::api::Output;
use std::collections::{BTreeMap, BTreeSet};
use std::os::unix::fs::symlink;

/// A fresh directory under the test temp folder, removed afterwards.
struct Scratch(PathBuf);
impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!("dispatch-archive-{name}-{}", std::process::id()));
        let _ = remove_tree(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = remove_tree(&self.0);
    }
}

fn stamp(path: &Path, seconds: u64, nanos: u32) {
    let at = UNIX_EPOCH + Duration::new(seconds, nanos);
    File::open(path).unwrap().set_times(fs::FileTimes::new().set_modified(at)).unwrap();
}

/// Deterministic bytes that zstd cannot shrink to nothing.
fn noise(length: usize) -> Vec<u8> {
    let mut state: u32 = 0x1234_5678;
    (0..length)
        .map(|_| {
            state = state.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            (state >> 16) as u8
        })
        .collect()
}

fn mode(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

/// The sample tree under `root/a`: nested and empty folders, empty and 3 MiB files, a 150-byte name, a path over
/// 300 bytes, a link with a long target, modes 0755 and 0600, mtimes with nanoseconds, and a fifo (skipped).
fn sample(root: &Path) -> PathBuf {
    let a = root.join("a");
    fs::create_dir_all(a.join("b/c")).unwrap();
    fs::create_dir(a.join("empty-folder")).unwrap();
    fs::write(a.join("b/c/deep.txt"), b"deep").unwrap();
    fs::write(a.join("empty-file"), b"").unwrap();
    fs::write(a.join("big.bin"), noise(3 << 20)).unwrap();
    fs::write(a.join(format!("{}.txt", "n".repeat(146))), b"long name").unwrap();
    let mut long = a.clone();
    for i in 0..12 {
        long.push(format!("level-{i:02}-{}", "x".repeat(16)));
    }
    fs::create_dir_all(&long).unwrap();
    fs::write(long.join("leaf.txt"), b"leaf").unwrap();
    assert!(long.join("leaf.txt").strip_prefix(root).unwrap().as_os_str().len() > 300);
    symlink(format!("../{}/target", "t".repeat(120)), a.join("link")).unwrap();
    fs::write(a.join("run.sh"), b"#!/bin/sh\n").unwrap();
    mode(&a.join("run.sh"), 0o755);
    fs::write(a.join("private"), b"secret").unwrap();
    mode(&a.join("private"), 0o600);
    // A socket path here would pass sun_path's bound; a fifo is skipped the same way.
    assert!(std::process::Command::new("mkfifo").arg(a.join("fifo")).status().unwrap().success());
    for (i, file) in ["b/c/deep.txt", "empty-file", "big.bin", "run.sh", "private"].iter().enumerate() {
        stamp(&a.join(file), 1_600_000_000 + i as u64, 123_456_789 + i as u32);
    }
    stamp(&a.join("b/c"), 1_500_000_000, 987_654_321);
    stamp(&a.join("empty-folder"), 1_500_000_001, 5);
    stamp(&a, 1_500_000_002, 0);
    a
}

#[derive(Debug, PartialEq)]
enum Fact {
    Folder { mode: u32, modified: (i64, i64) },
    File { mode: u32, modified: (i64, i64), content: Vec<u8> },
    Link(PathBuf),
}

/// Everything under `root` without following a link, by relative name.
fn facts(root: &Path) -> BTreeMap<PathBuf, Fact> {
    let mut found = BTreeMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(path) = stack.pop() {
        let m = fs::symlink_metadata(&path).unwrap();
        let name = path.strip_prefix(root).unwrap().to_path_buf();
        let modified = (m.mtime(), m.mtime_nsec());
        let fact = if m.file_type().is_symlink() {
            Fact::Link(fs::read_link(&path).unwrap())
        } else if m.is_dir() {
            for entry in fs::read_dir(&path).unwrap() {
                stack.push(entry.unwrap().path());
            }
            Fact::Folder { mode: m.mode() & 0o7777, modified }
        } else if m.is_file() {
            Fact::File { mode: m.mode() & 0o7777, modified, content: fs::read(&path).unwrap() }
        } else {
            continue;
        };
        found.insert(name, fact);
    }
    found
}

/// `bytes` staged as files.unpack.open and .write leave them: `<target>/.dispatch-copy-test/archive.tar.zst`.
fn staged(target: &Path, bytes: &[u8]) -> (PathBuf, PathBuf) {
    let staging = target.join(format!("{STAGING}test"));
    stage(&staging).unwrap();
    let archive = staging.join(ARCHIVE);
    fs::write(&archive, bytes).unwrap();
    (archive, staging)
}

/// The Staging a files.unpack.open of `staging` in `target` would record now.
fn located(staging: &Path, target: &Path) -> Staging {
    let identity = |path: &Path| {
        let m = fs::metadata(path).unwrap();
        FileIdentity { device: m.dev(), inode: m.ino() }
    };
    Staging { path: staging.to_owned(), target: target.to_owned(), folder: identity(staging), parent: identity(target) }
}

/// The first component of every name in a readable archive: what the client that packed it would send as
/// `names`. A damaged archive yields what could be read.
fn tops(bytes: &[u8]) -> BTreeSet<Vec<u8>> {
    let mut tops = BTreeSet::new();
    let Ok(decoder) = zstd::Decoder::new(bytes, usize::MAX) else { return tops };
    let mut reader = tar::Reader::new(decoder);
    while let Ok(Some(header)) = reader.next() {
        let top = header.name.split(|&b| b == b'/').find(|part| *part != b".").unwrap_or_default();
        tops.insert(top.to_vec());
    }
    tops
}

fn job(archive: &Path, staging: &Path, target: &Path, policy: Policy, names: &BTreeSet<Vec<u8>>) -> UnpackJob {
    UnpackJob {
        archive: archive.to_owned(),
        staging: located(staging, target),
        policy,
        names: names.clone(),
        stop: Stop::default(),
    }
}

fn unpacked(target: &Path, bytes: &[u8], policy: Policy) -> io::Result<Unpacked> {
    unpacked_as(target, bytes, policy, &tops(bytes))
}

fn unpacked_as(target: &Path, bytes: &[u8], policy: Policy, names: &BTreeSet<Vec<u8>>) -> io::Result<Unpacked> {
    let (archive, staging) = staged(target, bytes);
    let result = unpack(&job(&archive, &staging, target, policy, names));
    assert!(!staging.exists(), "the staging directory is always removed");
    result
}

/// A crafted archive, as a hostile client could send.
fn crafted(entries: &[(tar::Header, &[u8])]) -> Vec<u8> {
    let mut writer = tar::Writer::new(zstd::Encoder::live(Vec::new()).unwrap());
    for (header, content) in entries {
        writer.entry(header).unwrap();
        writer.write_all(content).unwrap();
    }
    writer.finish().unwrap().finish().unwrap()
}

fn entry(name: &str, kind: tar::Kind, content: &[u8]) -> tar::Header {
    tar::Header {
        name: name.as_bytes().to_vec(),
        kind,
        mode: if kind == tar::Kind::Directory { 0o755 } else { 0o644 },
        uid: 0,
        gid: 0,
        size: content.len() as u64,
        modified: (1_700_000_000, 0),
        link: Vec::new(),
    }
}

fn names(directory: &Path) -> Vec<String> {
    let mut names: Vec<_> = fs::read_dir(directory).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    names.sort();
    names
}

fn decoded(bytes: &[u8]) -> Vec<u8> {
    let mut tar = Vec::new();
    zstd::Decoder::new(bytes, usize::MAX).unwrap().read_to_end(&mut tar).unwrap();
    tar
}

#[test]
fn a_packed_tree_unpacks_as_it_was() {
    let scratch = Scratch::new("round-trip");
    let source = scratch.0.join("source");
    let a = sample(&source);
    let archive = scratch.0.join("dispatch-pack-test.tar.zst");
    let packed = pack(&source, &[a.clone(), a.join("b")], &archive, 250_000, &Stop::default()).unwrap();
    let before = facts(&a);
    let regular: Vec<_> = before.values().filter(|f| matches!(f, Fact::File { .. })).collect();
    assert_eq!(packed.files, regular.len() as u64);
    assert_eq!(packed.folders, before.values().filter(|f| matches!(f, Fact::Folder { .. })).count() as u64);
    assert_eq!(packed.entries, before.len() as u64, "a/b is inside a and stored once");
    assert_eq!(packed.skipped, 1, "the fifo");
    assert_eq!(packed.bytes, regular.iter().map(|f| match f { Fact::File { content, .. } => content.len() as u64, _ => 0 }).sum::<u64>());
    assert_eq!(packed.size, fs::metadata(&archive).unwrap().len());
    assert_eq!(fs::metadata(&archive).unwrap().mode() & 0o777, 0o600);

    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    let bytes = fs::read(&archive).unwrap();
    let result = unpacked(&target, &bytes, Policy::Replace).unwrap();
    assert_eq!(result, Unpacked { entries: packed.entries, bytes: packed.bytes, ..Unpacked::default() });
    assert_eq!(names(&target), ["a"]);
    assert_eq!(facts(&target.join("a")), before);
}

#[test]
fn the_system_tar_and_zstd_read_the_archive() {
    let scratch = Scratch::new("external");
    let a = sample(&scratch.0);
    let archive = scratch.0.join("dispatch-pack-external.tar.zst");
    pack(&scratch.0, &[a.clone()], &archive, 250_000, &Stop::default()).unwrap();
    let tar = Path::new("/usr/bin/tar");
    if tar.exists() {
        let plain = scratch.0.join("plain.tar");
        fs::write(&plain, decoded(&fs::read(&archive).unwrap())).unwrap();
        let output = std::process::Command::new(tar).arg("-tf").arg(&plain).output().unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let mut listed: Vec<_> = String::from_utf8(output.stdout).unwrap().lines().map(|l| l.trim_end_matches('/').to_owned()).collect();
        listed.sort();
        let mut expected: Vec<_> = facts(&a).keys().map(|k| Path::new("a").join(k).to_string_lossy().trim_end_matches('/').to_owned()).collect();
        expected.sort();
        assert_eq!(listed, expected);
    } else {
        eprintln!("no /usr/bin/tar: external tar check skipped");
    }
    let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].into_iter().map(Path::new).find(|p| p.exists());
    match zstd {
        Some(zstd) => {
            let output = std::process::Command::new(zstd).arg("-t").arg(&archive).output().unwrap();
            assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        }
        None => eprintln!("no zstd: external zstd check skipped"),
    }
}

#[test]
fn a_pack_over_its_limit_fails_and_leaves_no_archive() {
    let scratch = Scratch::new("limit");
    let a = sample(&scratch.0);
    let archive = scratch.0.join("dispatch-pack-limit.tar.zst");
    let error = pack(&scratch.0, &[a], &archive, 3, &Stop::default()).unwrap_err();
    assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::QuotaExceeded, None));
    assert!(!archive.exists());
    // Never a path outside the base, nor the base itself.
    for path in [scratch.0.join("../elsewhere"), scratch.0.clone(), PathBuf::from("relative")] {
        assert_eq!(pack(&scratch.0, &[path], &archive, 10, &Stop::default()).unwrap_err().kind(), io::ErrorKind::InvalidInput);
    }
    // An existing archive name is never reused.
    fs::write(&archive, b"").unwrap();
    assert_eq!(pack(&scratch.0, &[scratch.0.join("a")], &archive, 0, &Stop::default()).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
}

#[test]
fn entries_that_would_leave_the_tree_are_refused_and_nothing_moves() {
    let scratch = Scratch::new("escape");
    let target = scratch.0.join("target");
    let outside = scratch.0.join("outside");
    fs::create_dir_all(&target).unwrap();
    fs::create_dir_all(&outside).unwrap();
    fs::write(target.join("keep.txt"), b"mine").unwrap();
    let mut link = entry("link", tar::Kind::Symlink, b"");
    link.link = outside.as_os_str().as_bytes().to_vec();
    let mut folder_link = entry("folder", tar::Kind::Symlink, b"");
    folder_link.link = b"/tmp".to_vec();
    let file = |name: &str| (entry(name, tar::Kind::File, b"x"), &b"x"[..]);
    let cases: Vec<Vec<(tar::Header, &[u8])>> = vec![
        vec![file("ok.txt"), file("../x")],
        vec![file("/etc/x")],
        vec![file("a/../../x")],
        vec![file("a//x")],
        vec![(link.clone(), &b""[..]), file("link/x")],
        vec![(entry("folder/inner", tar::Kind::File, b"x"), &b"x"[..]), (folder_link, &b""[..])],
        vec![file("dup"), file("dup")],
        vec![file(&format!("{STAGING}other/x"))],
        vec![(entry("dir", tar::Kind::Directory, b""), &b""[..]), (link, &b""[..]), file("dir")],
    ];
    for entries in cases {
        let error = unpacked(&target, &crafted(&entries), Policy::Replace).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData, "{error}");
        assert_eq!(names(&target), ["keep.txt"], "{error}");
        assert!(names(&outside).is_empty());
    }
}

#[test]
fn a_cut_or_damaged_archive_moves_nothing() {
    let scratch = Scratch::new("damaged");
    let a = sample(&scratch.0.join("source"));
    let archive = scratch.0.join("dispatch-pack-damaged.tar.zst");
    pack(&scratch.0.join("source"), &[a], &archive, 250_000, &Stop::default()).unwrap();
    let bytes = fs::read(&archive).unwrap();
    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    let mut flipped = bytes.clone();
    let middle = flipped.len() / 2;
    flipped[middle] ^= 0x55;
    let mut tail = bytes.clone();
    *tail.last_mut().unwrap() ^= 1;
    for broken in [&bytes[..bytes.len() / 2], &bytes[..bytes.len() - 3], &flipped[..], &tail[..], &b"not zstd"[..]] {
        let error = unpacked(&target, broken, Policy::Replace).unwrap_err();
        assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::InvalidData, None), "{error}");
        assert!(names(&target).is_empty());
    }
}

/// The archive of `entries` under `root`, packed as files.pack would.
fn packed(root: &Path, entries: &[(&str, &[u8])]) -> Vec<u8> {
    let source = root.join("incoming");
    let mut paths = Vec::new();
    for (name, content) in entries {
        let path = source.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, content).unwrap();
        let top = source.join(Path::new(name).components().next().unwrap());
        if !paths.contains(&top) {
            paths.push(top);
        }
    }
    let archive = root.join("dispatch-pack-incoming.tar.zst");
    pack(&source, &paths, &archive, 250_000, &Stop::default()).unwrap();
    let bytes = fs::read(&archive).unwrap();
    fs::remove_file(&archive).unwrap();
    remove_tree(&source).unwrap();
    bytes
}

fn existing(target: &Path) {
    fs::create_dir_all(target.join("folder")).unwrap();
    fs::write(target.join("folder/old.txt"), b"old").unwrap();
    fs::write(target.join("notes.txt"), b"old notes").unwrap();
    fs::write(target.join("notes 2.txt"), b"older notes").unwrap();
    fs::write(target.join(".profile"), b"old profile").unwrap();
}

const INCOMING: [(&str, &[u8]); 4] = [("folder/new.txt", b"new"), ("notes.txt", b"new notes"), (".profile", b"new profile"), ("fresh.txt", b"fresh")];

#[test]
fn replace_puts_each_incoming_entry_in_place_of_the_existing_one() {
    let scratch = Scratch::new("replace");
    let target = scratch.0.join("target");
    existing(&target);
    let bytes = packed(&scratch.0, &INCOMING);
    let result = unpacked(&target, &bytes, Policy::Replace).unwrap();
    assert_eq!((result.replaced, result.kept, result.skipped), (3, 0, 0));
    assert_eq!(names(&target), [".profile", "folder", "fresh.txt", "notes 2.txt", "notes.txt"]);
    assert_eq!(names(&target.join("folder")), ["new.txt"], "a folder is replaced whole");
    assert_eq!(fs::read(target.join("notes.txt")).unwrap(), b"new notes");
    assert_eq!(fs::read(target.join(".profile")).unwrap(), b"new profile");
}

#[test]
fn keep_names_the_incoming_entry_like_finder() {
    let scratch = Scratch::new("keep");
    let target = scratch.0.join("target");
    existing(&target);
    let bytes = packed(&scratch.0, &INCOMING);
    let result = unpacked(&target, &bytes, Policy::Keep).unwrap();
    assert_eq!((result.replaced, result.kept, result.skipped), (0, 3, 0));
    assert_eq!(names(&target), [".profile", ".profile 2", "folder", "folder 2", "fresh.txt", "notes 2.txt", "notes 3.txt", "notes.txt"]);
    assert_eq!(fs::read(target.join("notes.txt")).unwrap(), b"old notes");
    assert_eq!(fs::read(target.join("notes 2.txt")).unwrap(), b"older notes");
    assert_eq!(fs::read(target.join("notes 3.txt")).unwrap(), b"new notes");
    assert_eq!(names(&target.join("folder 2")), ["new.txt"]);
    assert_eq!(numbered(b"archive.tar.gz", 2, false), b"archive.tar 2.gz");
    assert_eq!(numbered(b"v1.2", 2, true), b"v1.2 2");
    assert_eq!(numbered(b"trailing.", 4, false), b"trailing. 4");
}

#[test]
fn skip_leaves_existing_entries_alone() {
    let scratch = Scratch::new("skip");
    let target = scratch.0.join("target");
    existing(&target);
    let bytes = packed(&scratch.0, &INCOMING);
    let result = unpacked(&target, &bytes, Policy::Skip).unwrap();
    assert_eq!((result.entries, result.replaced, result.kept, result.skipped), (5, 0, 0, 3));
    assert_eq!(names(&target), [".profile", "folder", "fresh.txt", "notes 2.txt", "notes.txt"]);
    assert_eq!(names(&target.join("folder")), ["old.txt"]);
    assert_eq!(fs::read(target.join("notes.txt")).unwrap(), b"old notes");
}

#[test]
fn modes_are_restored_under_the_umask_and_read_only_folders_still_move() {
    let scratch = Scratch::new("modes");
    let source = scratch.0.join("source");
    fs::create_dir_all(source.join("locked/inner")).unwrap();
    fs::write(source.join("locked/inner/file"), b"x").unwrap();
    fs::write(source.join("setuid"), b"x").unwrap();
    mode(&source.join("setuid"), 0o4755);
    mode(&source.join("locked/inner"), 0o555);
    mode(&source.join("locked"), 0o555);
    let archive = scratch.0.join("dispatch-pack-modes.tar.zst");
    pack(&source, &[source.join("locked"), source.join("setuid")], &archive, 250_000, &Stop::default()).unwrap();
    mode(&source.join("locked/inner"), 0o755);
    mode(&source.join("locked"), 0o755);
    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    unpacked(&target, &fs::read(&archive).unwrap(), Policy::Replace).unwrap();
    let probe = scratch.0.join("probe");
    fs::DirBuilder::new().mode(0o777).create(&probe).unwrap();
    let umask = !fs::metadata(&probe).unwrap().mode() & 0o777;
    assert_eq!(fs::metadata(target.join("locked")).unwrap().mode() & 0o7777, 0o555 & !umask);
    assert_eq!(fs::metadata(target.join("locked/inner")).unwrap().mode() & 0o7777, 0o555 & !umask);
    assert_eq!(fs::metadata(target.join("setuid")).unwrap().mode() & 0o7777, 0o755 & !umask, "set-id bits are dropped");
    // A replace of a read-only folder fails before anything is lost, and the read-only staging is still removed.
    mode(&target.join("locked/inner"), 0o755);
    let again = unpacked(&target, &fs::read(&archive).unwrap(), Policy::Replace);
    assert!(target.join("locked/inner/file").exists(), "{again:?}");
    remove_tree(&target).unwrap();
}

#[test]
fn append_remove_tree_and_sweep() {
    let scratch = Scratch::new("small");
    let file = scratch.0.join("staged");
    assert_eq!(append(&file, b"x").unwrap_err().kind(), io::ErrorKind::NotFound, "never created");
    fs::write(&file, b"").unwrap();
    assert_eq!(append(&file, b"abc").unwrap(), 3);
    assert_eq!(append(&file, b"de").unwrap(), 5);
    symlink(&file, scratch.0.join("alias")).unwrap();
    assert!(append(&scratch.0.join("alias"), b"x").is_err(), "never through a link");
    assert_eq!(fs::read(&file).unwrap(), b"abcde");

    let tree = scratch.0.join("tree");
    fs::create_dir_all(tree.join("closed/deeper")).unwrap();
    fs::write(tree.join("closed/deeper/file"), b"x").unwrap();
    symlink(&file, tree.join("closed/link")).unwrap();
    mode(&tree.join("closed/deeper"), 0o500);
    mode(&tree.join("closed"), 0o500);
    remove_tree(&tree).unwrap();
    assert!(!tree.exists());
    assert!(file.exists(), "a link inside is removed, not followed");
    assert_eq!(remove_tree(&tree).unwrap_err().kind(), io::ErrorKind::NotFound);

    let temporary = std::env::temp_dir();
    let prefix = format!("dispatch-sweep-test-{}-", std::process::id());
    let (old, new) = (temporary.join(format!("{prefix}old")), temporary.join(format!("{prefix}new")));
    fs::write(&old, b"").unwrap();
    fs::write(&new, b"").unwrap();
    let day = SystemTime::now() - Duration::from_secs(25 * 60 * 60);
    File::options().write(true).open(&old).unwrap().set_times(fs::FileTimes::new().set_modified(day)).unwrap();
    let (directory, removed) = sweep(&prefix, Duration::from_secs(24 * 60 * 60)).unwrap();
    assert_eq!((directory, removed), (temporary, 1));
    assert!(!old.exists() && new.exists());
    fs::remove_file(&new).unwrap();
}

#[test]
fn unpack_takes_only_its_own_staging_directory() {
    let scratch = Scratch::new("staging");
    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    let elsewhere = scratch.0.join(format!("{STAGING}x"));
    fs::create_dir(&elsewhere).unwrap();
    fs::create_dir(target.join("other")).unwrap();
    fs::create_dir(target.join(STAGING)).unwrap();
    for (archive, staging) in [
        (elsewhere.join("archive.tar.zst"), elsewhere.clone()),
        (target.join("other/archive.tar.zst"), target.join("other")),
        (target.join(STAGING).join("archive.tar.zst"), target.join(STAGING)),
    ] {
        let names = BTreeSet::from([b"x".to_vec()]);
        let mut job = job(&archive, &staging, &target, Policy::Skip, &names);
        job.staging.target = target.clone();
        assert_eq!(unpack(&job).unwrap_err().kind(), io::ErrorKind::InvalidInput);
    }
    assert!(elsewhere.exists());
}

#[test]
fn only_the_top_level_names_the_client_sent_are_unpacked() {
    let scratch = Scratch::new("names");
    let target = scratch.0.join("target");
    fs::create_dir_all(target.join("Library")).unwrap();
    fs::write(target.join("Library/mine"), b"mine").unwrap();
    let sent = BTreeSet::from([b"Documents".to_vec()]);
    let file = |name: &str| (entry(name, tar::Kind::File, b"x"), &b"x"[..]);
    // An extra top beside the one sent, and the sent one swapped for another: refused before anything moves,
    // whatever the policy.
    for (entries, offender) in [
        (vec![file("Documents/a"), file(".zprofile")], ".zprofile"),
        (vec![file("Library/evil")], "Library"),
    ] {
        for policy in [Policy::Replace, Policy::Keep, Policy::Skip] {
            let error = unpacked_as(&target, &crafted(&entries), policy, &sent).unwrap_err();
            assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::InvalidData, None), "{error}");
            assert!(error.to_string().contains(offender), "{error}");
            assert_eq!(names(&target), ["Library"]);
            assert_eq!(names(&target.join("Library")), ["mine"]);
        }
    }
    let result = unpacked_as(&target, &crafted(&[file("Documents/a")]), Policy::Replace, &sent).unwrap();
    assert_eq!(result.entries, 1);
    assert_eq!(names(&target), ["Documents", "Library"]);
}

/// One ustar header block for a file of `size` bytes (base-256 above the octal field's range), as a hostile
/// sender could write it; no content follows.
fn sized(name: &str, size: u64) -> Vec<u8> {
    let mut b = vec![0u8; 512];
    b[..name.len()].copy_from_slice(name.as_bytes());
    b[100..108].copy_from_slice(b"0000644\0");
    b[108..116].copy_from_slice(b"0000000\0");
    b[116..124].copy_from_slice(b"0000000\0");
    b[124] = 0x80;
    b[128..136].copy_from_slice(&size.to_be_bytes());
    b[136..148].copy_from_slice(b"14000000000\0");
    b[156] = b'0';
    b[257..263].copy_from_slice(b"ustar\0");
    b[263..265].copy_from_slice(b"00");
    b[148..156].fill(b' ');
    let sum: u32 = b.iter().map(|&v| u32::from(v)).sum();
    b[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
    b
}

fn compressed(tar: &[u8]) -> Vec<u8> {
    let mut encoder = zstd::Encoder::live(Vec::new()).unwrap();
    encoder.write_all(tar).unwrap();
    encoder.finish().unwrap()
}

#[test]
fn names_link_targets_and_components_past_the_system_limits_are_refused() {
    let scratch = Scratch::new("long-names");
    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    let deep = format!("top/{}", vec!["d".repeat(200); 21].join("/"));
    assert!(deep.len() > tar::PATH_MAX);
    let mut link = entry("top/link", tar::Kind::Symlink, b"");
    link.link = "x/".repeat(2100).into_bytes();
    for entries in [
        vec![(entry(&deep, tar::Kind::File, b"x"), &b"x"[..])],
        vec![(entry(&format!("top/{}", "n".repeat(256)), tar::Kind::File, b"x"), &b"x"[..])],
        vec![(link, &b""[..])],
    ] {
        let error = unpacked(&target, &crafted(&entries), Policy::Replace).unwrap_err();
        assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::InvalidData, None), "{error}");
        assert!(names(&target).is_empty());
    }
}

#[test]
fn the_names_kept_for_links_are_bounded() {
    let scratch = Scratch::new("many-links");
    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    // 17,000 links with 4 KiB targets hold more than 64 MiB of names; the bound stops it before the links pass.
    let target_bytes = "t".repeat(4000);
    let links: Vec<_> = (0..17_000)
        .map(|i| {
            let mut link = entry(&format!("top/{i:05}"), tar::Kind::Symlink, b"");
            link.link = target_bytes.clone().into_bytes();
            (link, &b""[..])
        })
        .collect();
    let error = unpacked(&target, &crafted(&links), Policy::Replace).unwrap_err();
    assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::QuotaExceeded, None), "{error}");
    assert!(error.to_string().contains("names"), "{error}");
    assert!(names(&target).is_empty());
}

#[test]
fn a_size_bomb_fails_on_its_header_before_anything_is_written() {
    let scratch = Scratch::new("size-bomb");
    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    let mut sizes = vec![(64 << 30) + 1, 1 << 40];
    // Within the content bound but more than the disk can take, when this disk has under 63 GiB free.
    let free = stats::available(&target).unwrap();
    if free < 63 << 30 {
        sizes.push(free);
    }
    for size in sizes {
        let tar = [sized("top/huge", size), vec![0; 1024]].concat();
        let started = std::time::Instant::now();
        let error = unpacked(&target, &compressed(&tar), Policy::Replace).unwrap_err();
        assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::QuotaExceeded, None), "{size}: {error}");
        assert!(error.to_string().contains("content") || error.to_string().contains("free space"), "{error}");
        assert!(started.elapsed() < Duration::from_secs(5), "failed fast");
        assert!(names(&target).is_empty());
    }
}

#[test]
fn an_archive_frame_asking_for_a_large_window_is_refused() {
    let scratch = Scratch::new("window");
    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    // Magic, a frame header whose window descriptor asks for 16 MiB, then one empty last raw block.
    let frame = [0x28, 0xb5, 0x2f, 0xfd, 0x00, 14 << 3, 0x01, 0x00, 0x00];
    let error = unpacked(&target, &frame, Policy::Replace).unwrap_err();
    assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::InvalidData, None), "{error}");
    assert!(error.to_string().contains("zstd"), "{error}");
}

#[test]
fn a_stopped_pack_or_unpack_ends_before_its_next_entry_and_leaves_nothing() {
    let scratch = Scratch::new("stop");
    let a = sample(&scratch.0.join("source"));
    let archive = scratch.0.join("dispatch-pack-stop.tar.zst");
    let stop = Stop::default();
    stop.set();
    let error = pack(&scratch.0.join("source"), &[a.clone()], &archive, 250_000, &stop).unwrap_err();
    assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::Interrupted, None));
    assert!(!archive.exists());
    pack(&scratch.0.join("source"), &[a], &archive, 250_000, &Stop::default()).unwrap();
    let bytes = fs::read(&archive).unwrap();
    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    let (archive, staging) = staged(&target, &bytes);
    let mut job = job(&archive, &staging, &target, Policy::Replace, &tops(&bytes));
    job.stop = stop;
    let error = unpack(&job).unwrap_err();
    assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::Interrupted, None));
    assert!(names(&target).is_empty(), "nothing moved and the staging folder is gone");
}

/// `existing`'s target with ASIDE set to `hook` while `bytes` unpack with replace.
fn replaced_with(target: &Path, bytes: &[u8], hook: impl FnMut(&std::ffi::OsStr) + 'static) -> io::Result<Unpacked> {
    ASIDE.with_borrow_mut(|slot| *slot = Some(Box::new(hook)));
    let (archive, staging) = staged(target, bytes);
    let result = unpack(&job(&archive, &staging, target, Policy::Replace, &tops(bytes)));
    ASIDE.with_borrow_mut(|slot| *slot = None);
    result
}

#[test]
fn a_replace_that_cannot_complete_never_loses_the_original() {
    let scratch = Scratch::new("put-back");
    let bytes = packed(&scratch.0, &[("notes.txt", b"new notes")]);
    // Something takes the name while the original is aside: the original goes to the next free number.
    let target = scratch.0.join("taken");
    existing(&target);
    let into = target.clone();
    let error = replaced_with(&target, &bytes, move |name| fs::write(into.join(name), b"intruder").unwrap()).unwrap_err();
    assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::Other, None), "{error}");
    assert!(error.to_string().contains("\"notes 3.txt\""), "{error}");
    assert_eq!(fs::read(target.join("notes.txt")).unwrap(), b"intruder");
    assert_eq!(fs::read(target.join("notes 3.txt")).unwrap(), b"old notes");
    assert!(!names(&target).iter().any(|name| name.starts_with(STAGING)), "the staging folder is removed");
    // Nothing can be moved into the target any more: the original stays in the staging folder, which stays.
    let target = scratch.0.join("closed");
    existing(&target);
    let into = target.clone();
    let error = replaced_with(&target, &bytes, move |name| {
        fs::write(into.join(name), b"intruder").unwrap();
        mode(&into, 0o500);
    });
    mode(&target, 0o755);
    // SAFETY: getuid only reads this process's account. Root writes into a 0500 folder anyway.
    if unsafe { native::getuid() } == 0 {
        return;
    }
    let error = error.unwrap_err();
    let staging = target.join(format!("{STAGING}test"));
    assert!(error.to_string().contains(&staging.join("old").display().to_string()), "{error}");
    assert_eq!(fs::read(staging.join("old/notes.txt")).unwrap(), b"old notes");
    assert_eq!(fs::read(target.join("notes.txt")).unwrap(), b"intruder");
}

#[test]
fn a_staging_folder_is_made_new_or_not_at_all() {
    let scratch = Scratch::new("stage");
    let existing = scratch.0.join(format!("{STAGING}taken"));
    fs::create_dir(&existing).unwrap();
    fs::write(existing.join("theirs"), b"x").unwrap();
    assert_eq!(stage(&existing).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
    assert_eq!(names(&existing), ["theirs"], "a folder that exists is never taken");
    symlink(&scratch.0, scratch.0.join(format!("{STAGING}link"))).unwrap();
    assert_eq!(stage(&scratch.0.join(format!("{STAGING}link"))).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
    assert_eq!(stage(&scratch.0.join("plain")).unwrap_err().kind(), io::ErrorKind::InvalidInput);
    let made = scratch.0.join(format!("{STAGING}new"));
    let m = stage(&made).unwrap();
    let on_disk = fs::symlink_metadata(&made).unwrap();
    assert_eq!((m.dev(), m.ino(), on_disk.mode() & 0o777), (on_disk.dev(), on_disk.ino(), 0o700));
    assert_eq!(fs::metadata(made.join(ARCHIVE)).unwrap().len(), 0);
    assert_eq!(fs::metadata(made.join(ARCHIVE)).unwrap().mode() & 0o777, 0o600);
}

#[test]
fn a_staging_folder_is_touched_only_where_it_was_made() {
    let scratch = Scratch::new("pinned");
    let bytes = packed(&scratch.0, &[("notes.txt", b"new notes")]);
    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    let (archive, staging) = staged(&target, &bytes);
    let job = job(&archive, &staging, &target, Policy::Replace, &tops(&bytes));
    // The target renamed and another folder put at its path, holding a folder of the staging folder's name.
    let renamed = scratch.0.join("renamed");
    fs::rename(&target, &renamed).unwrap();
    fs::create_dir_all(&staging).unwrap();
    fs::write(staging.join("theirs"), b"x").unwrap();
    for error in [unpack(&job).unwrap_err(), discard(&job.staging).unwrap_err()] {
        assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::Other, None), "{error}");
        assert!(error.to_string().contains(&format!("{STAGING}test")), "{error}");
    }
    assert_eq!(names(&staging), ["theirs"]);
    assert_eq!(names(&renamed), [format!("{STAGING}test")]);
    assert_eq!(names(&renamed.join(format!("{STAGING}test"))), [ARCHIVE]);
    // The target back where it was: a folder of the staging name that Job::Stage did not make is not removed.
    fs::remove_dir_all(&target).unwrap();
    fs::rename(&renamed, &target).unwrap();
    fs::remove_dir_all(&staging).unwrap();
    fs::create_dir(&staging).unwrap();
    let mut fresh = job.clone();
    fresh.staging.parent = located(&staging, &target).parent;
    assert_eq!(discard(&fresh.staging).unwrap_err().kind(), io::ErrorKind::Other);
    assert!(staging.exists());
    // The folder it made, where it made it, goes; one already gone is no failure.
    fs::remove_dir(&staging).unwrap();
    let (_, staging) = staged(&target, &bytes);
    let made = located(&staging, &target);
    discard(&made).unwrap();
    assert!(!staging.exists());
    discard(&made).unwrap();
}

#[test]
fn removing_a_tree_never_follows_a_link_and_opens_up_closed_folders() {
    let scratch = Scratch::new("remove");
    let outside = scratch.0.join("outside");
    fs::create_dir(&outside).unwrap();
    mode(&outside, 0o500);
    let tree = scratch.0.join("tree");
    fs::create_dir_all(tree.join("open/closed")).unwrap();
    fs::write(tree.join("open/closed/file"), b"x").unwrap();
    symlink(&outside, tree.join("open/to-outside")).unwrap();
    mode(&tree.join("open/closed"), 0);
    mode(&tree.join("open"), 0o500);
    remove_tree(&tree).unwrap();
    assert!(!tree.exists());
    assert_eq!(fs::metadata(&outside).unwrap().mode() & 0o777, 0o500, "the link's target keeps its mode");
    mode(&outside, 0o700);
    // A listing through the descriptor is the folder's, wherever its path now leads.
    fs::create_dir(scratch.0.join("listed")).unwrap();
    fs::write(scratch.0.join("listed/a"), b"").unwrap();
    let folder = native::directory(&scratch.0.join("listed"), Expected::Any).unwrap();
    fs::rename(scratch.0.join("listed"), scratch.0.join("moved")).unwrap();
    fs::create_dir(scratch.0.join("listed")).unwrap();
    let listed: Vec<_> = native::entries(&folder).unwrap().into_iter().map(|(name, kind)| (name.into_string().unwrap(), kind)).collect();
    assert_eq!(listed, [("a".to_owned(), REGULAR)]);
    assert_eq!(native::entries(&folder).unwrap().len(), 1, "read from the start each time");
}

#[test]
fn a_pack_skips_and_counts_what_this_account_cannot_read() {
    let scratch = Scratch::new("unreadable");
    let source = scratch.0.join("source");
    fs::create_dir_all(source.join("a/closed")).unwrap();
    fs::write(source.join("a/closed/secret"), b"x").unwrap();
    fs::write(source.join("a/locked.txt"), b"x").unwrap();
    fs::write(source.join("a/open.txt"), b"x").unwrap();
    mode(&source.join("a/closed"), 0);
    mode(&source.join("a/locked.txt"), 0);
    let archive = scratch.0.join("dispatch-pack-unreadable.tar.zst");
    let packed = pack(&source, &[source.join("a")], &archive, 250_000, &Stop::default());
    mode(&source.join("a/closed"), 0o700);
    mode(&source.join("a/locked.txt"), 0o600);
    // SAFETY: getuid only reads this process's account. Root reads them anyway.
    if unsafe { native::getuid() } == 0 {
        return;
    }
    let packed = packed.unwrap();
    assert_eq!((packed.entries, packed.folders, packed.files, packed.skipped), (2, 1, 1, 2));
    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    unpacked(&target, &fs::read(&archive).unwrap(), Policy::Replace).unwrap();
    assert_eq!(names(&target.join("a")), ["open.txt"]);
}

#[test]
fn a_file_system_without_no_replace_renames_says_so() {
    let number = if cfg!(target_os = "macos") { 45 } else { 22 };
    let error = native::unreplacing(io::Error::from_raw_os_error(number));
    assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::Unsupported, None));
    assert!(error.to_string().contains("cannot rename without replacing"));
    let other = native::unreplacing(io::Error::from_raw_os_error(17));
    assert_eq!(other.raw_os_error(), Some(17));
}

#[test]
fn colliding_names_are_refused_before_anything_moves() {
    let scratch = Scratch::new("collisions");
    let target = scratch.0.join("target");
    let outside = scratch.0.join("outside");
    fs::create_dir_all(&target).unwrap();
    fs::create_dir_all(&outside).unwrap();
    fs::write(target.join("keep.txt"), b"mine").unwrap();
    let file = |name: &str| (entry(name, tar::Kind::File, b"x"), &b"x"[..]);
    let link = |name: &str, to: &Path| {
        let mut link = entry(name, tar::Kind::Symlink, b"");
        link.link = to.as_os_str().as_bytes().to_vec();
        (link, &b""[..])
    };
    let insensitive = {
        fs::write(scratch.0.join("Probe"), b"").unwrap();
        let found = scratch.0.join("probe").exists();
        fs::remove_file(scratch.0.join("Probe")).unwrap();
        found
    };
    let mut cases = vec![
        // The same file twice, and a link after a file of its name.
        vec![file("dup"), file("dup")],
        vec![file("x"), link("x", &outside)],
    ];
    if insensitive {
        // On a case-insensitive file system `A` and `a` are one name: a link `A` beside a folder `a`.
        cases.push(vec![link("A", &outside), file("a/x")]);
        cases.push(vec![file("a/x"), link("A", &outside)]);
        cases.push(vec![(entry("a", tar::Kind::Directory, b""), &b""[..]), file("A/x")]);
    }
    for entries in cases {
        let error = unpacked(&target, &crafted(&entries), Policy::Replace).unwrap_err();
        assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::InvalidData, None), "{error}");
        assert_eq!(names(&target), ["keep.txt"], "{error}");
        assert!(names(&outside).is_empty());
    }
    if !insensitive {
        // Two names on a case-sensitive one: both arrive, and nothing lands outside.
        unpacked(&target, &crafted(&[link("A", &outside), file("a/x")]), Policy::Replace).unwrap();
        assert_eq!(names(&target), ["A", "a", "keep.txt"]);
        assert!(names(&outside).is_empty());
    }
}

#[test]
fn keep_fails_when_every_number_is_taken_and_loses_nothing() {
    let scratch = Scratch::new("numbers");
    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    fs::write(target.join("notes.txt"), b"old").unwrap();
    for number in 2..=NUMBERS {
        fs::write(target.join(format!("notes {number}.txt")), b"").unwrap();
    }
    let bytes = packed(&scratch.0, &[("notes.txt", b"new notes")]);
    let error = unpacked(&target, &bytes, Policy::Keep).unwrap_err();
    assert_eq!((error.kind(), error.raw_os_error()), (io::ErrorKind::QuotaExceeded, None), "{error}");
    assert!(error.to_string().contains("notes.txt"), "{error}");
    assert_eq!(fs::read(target.join("notes.txt")).unwrap(), b"old");
    assert_eq!(names(&target).len(), NUMBERS as usize);
}

/// What replay hands back for a recorded completion, and its encoding again.
fn replayed(result: io::Result<Output>) -> (io::Result<Output>, Vec<u8>, Vec<u8>) {
    let recorded = super::super::file::encode(&result).unwrap();
    let replayed = super::super::file::decode(0, &recorded, std::env::consts::OS).unwrap().result;
    let again = super::super::file::encode(&replayed).unwrap();
    (replayed, recorded, again)
}

#[test]
fn transfer_job_outputs_replay_as_recorded() {
    let scratch = Scratch::new("replay");
    let source = scratch.0.join("source");
    let a = sample(&source);
    let archive = scratch.0.join("dispatch-pack-replay.tar.zst");
    let packed = pack(&source, &[a], &archive, 250_000, &Stop::default()).unwrap();
    let (result, recorded, again) = replayed(Ok(Output::Packed(packed.clone())));
    assert_eq!(again, recorded);
    assert!(matches!(result, Ok(Output::Packed(back)) if back == packed));

    let (result, recorded, again) = replayed(Ok(Output::Appended(u64::MAX)));
    assert_eq!(again, recorded);
    assert!(matches!(result, Ok(Output::Appended(u64::MAX))));

    let target = scratch.0.join("target");
    fs::create_dir(&target).unwrap();
    let unpacked = unpacked(&target, &fs::read(&archive).unwrap(), Policy::Replace).unwrap();
    let (result, recorded, again) = replayed(Ok(Output::Unpacked(unpacked)));
    assert_eq!(again, recorded);
    assert!(matches!(result, Ok(Output::Unpacked(back)) if back == unpacked));

    // RemoveTree and Discard answer Removed; Stage the folder's metadata.
    let (result, recorded, again) = replayed(Ok(Output::Removed));
    assert_eq!(again, recorded);
    assert!(matches!(result, Ok(Output::Removed)));
    let folder = super::super::metadata(stage(&target.join(format!("{STAGING}replay"))).unwrap());
    let (result, recorded, again) = replayed(Ok(Output::Metadata(folder)));
    assert_eq!(again, recorded);
    assert!(matches!(result, Ok(Output::Metadata(back)) if back == folder));

    let (directory, removed) = sweep("dispatch-replay-sweep-none-", Duration::from_secs(1)).unwrap();
    let (result, recorded, again) = replayed(Ok(Output::Swept(directory.clone(), removed)));
    assert_eq!(again, recorded);
    assert!(matches!(result, Ok(Output::Swept(back, 0)) if back == directory));

    // The jobs' own failures keep their kind and message, without an OS number.
    for error in [limited("more than 64 GiB of content"), refused("an absolute name"), changed(), stopped()] {
        let (kind, message) = (error.kind(), error.to_string());
        let (result, recorded, again) = replayed(Err(error));
        assert_eq!(again, recorded);
        let back = result.unwrap_err();
        assert_eq!((back.kind(), back.raw_os_error(), back.to_string()), (kind, None, message));
    }
}
