//! files.write, files.pack and files.unpack.* through the plugin, on a real System, completions delivered the
//! way the reactor delivers them.
use super::*;
use dispatch_helper_core::api::{Replacement, Update};
use dispatch_helper_core::system::System;
use std::os::unix::fs::MetadataExt;

struct Quiet;
impl Ui for Quiet {
    fn update(&mut self, _: Update) {}
}

type Slot<T> = Rc<RefCell<Option<Result<T, Error>>>>;

fn slot<T: 'static>() -> (Slot<T>, Done<T>) {
    let slot: Slot<T> = Rc::default();
    let filled = slot.clone();
    (slot, Box::new(move |_, result| *filled.borrow_mut() = Some(result)))
}

fn identity(metadata: &std::fs::Metadata) -> FileIdentity {
    FileIdentity { device: metadata.dev(), inode: metadata.ino() }
}

struct Helper {
    io: System,
    files: Files,
}

impl Helper {
    fn new() -> Self {
        Self {
            io: System::new(2, 64).unwrap(),
            files: Files::new(true),
        }
    }

    /// Run the reactor until `slot` is filled.
    fn wait<T>(&mut self, slot: &Slot<T>) -> Result<T, Error> {
        loop {
            self.io.callbacks();
            if let Some(result) = slot.borrow_mut().take() {
                return result;
            }
            let (section, event) = self.io.next().unwrap();
            if section != "then" {
                self.files.event(&mut self.io, &mut Quiet, event);
            }
        }
    }

    fn write(&mut self, path: &Path, bytes: &[u8], mode: Option<u32>, replace: bool) -> Result<Metadata, Error> {
        let (result, done) = slot();
        let parent = path
            .parent()
            .and_then(|parent| std::fs::metadata(parent).ok())
            .map_or(FileIdentity { device: 0, inode: 0 }, |metadata| identity(&metadata));
        let replaced = replace.then(|| {
            std::fs::symlink_metadata(path)
                .map_or(FileIdentity { device: 0, inode: 0 }, |metadata| identity(&metadata))
        });
        self.files.write(&mut self.io, path, bytes.to_vec(), mode, replace, parent, replaced, done);
        self.wait(&result)
    }

    fn start_pack(&mut self, transfer: &str, base: &Path, paths: &[PathBuf], limit: u64) -> Slot<Packed> {
        let (result, done) = slot();
        self.files.pack(&mut self.io, transfer, base, paths, limit, done);
        result
    }

    fn pack(&mut self, transfer: &str, base: &Path, paths: &[PathBuf], limit: u64) -> Result<Packed, Error> {
        let result = self.start_pack(transfer, base, paths, limit);
        self.wait(&result)
    }

    fn drop_pack(&mut self, transfer: &str) -> Result<(), Error> {
        let (result, done) = slot();
        self.files.pack_drop(&mut self.io, transfer, done);
        self.wait(&result)
    }

    /// files.unpack.open for an archive of the top-level `names`.
    fn open(&mut self, transfer: &str, target: &Path, policy: &str, names: &[&str]) -> Result<Transfer, Error> {
        let parent = std::fs::metadata(target)
            .map_or(FileIdentity { device: 0, inode: 0 }, |metadata| identity(&metadata));
        self.open_in(transfer, target, parent, policy, names)
    }

    /// files.unpack.open with the target identity the client listed, which a replay cannot stat.
    fn open_in(
        &mut self,
        transfer: &str,
        target: &Path,
        parent: FileIdentity,
        policy: &str,
        names: &[&str],
    ) -> Result<Transfer, Error> {
        let (result, done) = slot();
        let replacements: Vec<_> = if policy == "replace" {
            names
                .iter()
                .filter_map(|name| {
                    std::fs::symlink_metadata(target.join(name)).ok().map(|metadata| Replacement {
                        name: (*name).to_owned(),
                        identity: identity(&metadata),
                    })
                })
                .collect()
        } else { Vec::new() };
        self.files.unpack_open(&mut self.io, transfer, target, policy, &strings(names), parent, &replacements, done);
        self.wait(&result)
    }

    fn send(&mut self, transfer: &str, bytes: &[u8]) -> Result<Progress, Error> {
        let (result, done) = slot();
        self.files.unpack_write(&mut self.io, transfer, bytes.to_vec(), done);
        self.wait(&result)
    }

    fn close(&mut self, transfer: &str, commit: bool) -> Result<Unpacked, Error> {
        let (result, done) = slot();
        self.files.unpack_close(&mut self.io, transfer, commit, done);
        self.wait(&result)
    }

    /// files.pack of `paths` in `base`, then the archive's bytes, dropped.
    fn packed(&mut self, base: &Path, paths: &[PathBuf]) -> Vec<u8> {
        let packed = self.pack("source", base, paths, 0).unwrap();
        let bytes = std::fs::read(&packed.archive).unwrap();
        self.drop_pack("source").unwrap();
        assert!(!Path::new(&packed.archive).exists());
        bytes
    }

    /// The whole copy-in of an archive of the top-level `names`: open, write in windows, close with commit.
    fn copy(&mut self, bytes: &[u8], target: &Path, policy: &str, names: &[&str]) -> Result<Unpacked, Error> {
        let transfer = self.open("copy", target, policy, names)?;
        assert!(Path::new(&transfer.staging).starts_with(target));
        let mut sent = 0;
        for window in bytes.chunks(64 * 1024) {
            sent += window.len() as u64;
            assert_eq!(self.send("copy", window)?.bytes, sent);
        }
        let result = self.close("copy", true);
        assert!(!Path::new(&transfer.staging).exists());
        result
    }
}

struct Scratch(PathBuf);
impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!("dispatch-files-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn strings(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| name.to_string()).collect()
}

fn code<T: std::fmt::Debug>(result: Result<T, Error>) -> &'static str {
    result.unwrap_err().code
}

fn names(directory: &Path) -> Vec<String> {
    let mut names: Vec<_> = std::fs::read_dir(directory)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// The account's umask, read back from a file created 0777.
fn umask(scratch: &Scratch) -> u32 {
    use std::os::unix::fs::OpenOptionsExt;
    let probe = scratch.0.join("umask-probe");
    std::fs::File::options().write(true).create_new(true).mode(0o777).open(&probe).unwrap();
    let mask = !std::fs::metadata(&probe).unwrap().mode() & 0o777;
    std::fs::remove_file(&probe).unwrap();
    mask
}

#[test]
fn files_write_creates_replaces_and_refuses() {
    let scratch = Scratch::new("write");
    let mut helper = Helper::new();
    let path = scratch.0.join("note.txt");
    let metadata = helper.write(&path, b"first", None, false).unwrap();
    assert_eq!((metadata.kind, metadata.size), (FileKind::File, 5));
    let mode = std::fs::metadata(&path).unwrap().mode() & 0o7777;
    assert_eq!(mode, 0o644 & !umask(&scratch));
    assert_eq!(code(helper.write(&path, b"second", None, false)), "exists");
    assert_eq!(std::fs::read(&path).unwrap(), b"first");
    assert_eq!(helper.write(&path, b"second", Some(0o600), true).unwrap().size, 6);
    assert_eq!(std::fs::read(&path).unwrap(), b"second");
    assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o7777, 0o600);
    assert_eq!(code(helper.write(&path, &vec![0; (8 << 20) + 1], None, true)), "limit");
    let full = scratch.0.join("full");
    assert_eq!(helper.write(&full, &vec![1; 8 << 20], Some(0o4755), false).unwrap().size, 8 << 20);
    assert_eq!(std::fs::metadata(&full).unwrap().mode() & 0o7000, 0, "no set-id bits");
    assert_eq!(code(helper.write(&scratch.0.join("missing/file"), b"x", None, false)), "not_found");
    assert_eq!(code(helper.write(&path.join("below"), b"x", None, false)), "not_directory");
    for invalid in [PathBuf::from("relative"), scratch.0.join("a/../note.txt"), scratch.0.join("./x"), PathBuf::from("/")] {
        assert_eq!(code(helper.write(&invalid, b"x", None, true)), "invalid_request", "{invalid:?}");
    }
    assert_eq!(code(helper.write(&scratch.0.join("m"), b"x", Some(0o10000), true)), "invalid_request");
    // Through a symlinked parent (macOS /tmp): the checked write goes to the real folder.
    std::os::unix::fs::symlink(&scratch.0, scratch.0.join("alias")).unwrap();
    helper.write(&scratch.0.join("alias/via-link"), b"x", None, false).unwrap();
    assert!(scratch.0.join("via-link").is_file());
}

#[test]
fn files_write_is_bound_to_the_listed_parent_and_entry() {
    let scratch = Scratch::new("write-identity");
    let mut helper = Helper::new();
    let target = scratch.0.join("target");
    std::fs::create_dir(&target).unwrap();
    let path = target.join("note.txt");
    std::fs::write(&path, b"listed").unwrap();
    let parent = identity(&std::fs::metadata(&target).unwrap());
    let replaced = identity(&std::fs::symlink_metadata(&path).unwrap());

    std::fs::remove_file(&path).unwrap();
    std::fs::write(&path, b"intruder").unwrap();
    let (result, done) = slot();
    helper.files.write(&mut helper.io, &path, b"incoming".to_vec(), None, true, parent, Some(replaced), done);
    assert_eq!(code(helper.wait(&result)), "changed");
    assert_eq!(std::fs::read(&path).unwrap(), b"intruder");

    let moved = scratch.0.join("moved");
    std::fs::rename(&target, &moved).unwrap();
    std::fs::create_dir(&target).unwrap();
    let (result, done) = slot();
    helper.files.write(
        &mut helper.io,
        &target.join("new.txt"),
        b"incoming".to_vec(),
        None,
        false,
        parent,
        None,
        done,
    );
    assert_eq!(code(helper.wait(&result)), "changed");
    assert!(!target.join("new.txt").exists());
    assert_eq!(std::fs::read(moved.join("note.txt")).unwrap(), b"intruder");
}

fn tree(scratch: &Scratch) -> PathBuf {
    let base = scratch.0.join("source");
    std::fs::create_dir_all(base.join("folder/inner")).unwrap();
    std::fs::write(base.join("folder/inner/a.txt"), b"a").unwrap();
    std::fs::write(base.join("folder/b.txt"), b"bb").unwrap();
    std::fs::write(base.join("notes.txt"), b"incoming notes").unwrap();
    std::os::unix::fs::symlink("/tmp", base.join("folder/to-tmp")).unwrap();
    base
}

#[test]
fn a_pack_unpacks_into_the_target_under_each_policy() {
    let scratch = Scratch::new("policies");
    let mut helper = Helper::new();
    let base = tree(&scratch);
    let packed = helper.pack("t1", &base, &[base.join("folder"), base.join("notes.txt")], 0).unwrap();
    assert_eq!((packed.entries, packed.files, packed.folders, packed.bytes, packed.skipped), (6, 3, 2, 17, 0));
    let archive = PathBuf::from(&packed.archive);
    let name = archive.file_name().unwrap().to_string_lossy().into_owned();
    assert!(name.starts_with("dispatch-pack-") && name.ends_with(".tar.zst") && name.len() == 14 + 32 + 8, "{name}");
    assert_eq!(archive.parent(), Some(std::env::temp_dir().as_path()));
    assert_eq!(std::fs::metadata(&archive).unwrap().mode() & 0o777, 0o600);
    let bytes = std::fs::read(&archive).unwrap();
    helper.drop_pack("t1").unwrap();
    assert!(!archive.exists());
    assert_eq!(helper.drop_pack("t1"), Ok(()), "an unknown transfer is already gone");

    for (policy, expected, counts) in [
        ("replace", vec!["folder", "notes 2.txt", "notes.txt"], (1, 0, 0)),
        ("keep", vec!["folder", "folder 2", "notes 2.txt", "notes 3.txt", "notes.txt"], (0, 2, 0)),
        ("skip", vec!["folder", "notes 2.txt", "notes.txt"], (0, 0, 2)),
    ] {
        let target = scratch.0.join(format!("target-{policy}"));
        std::fs::create_dir_all(&target).unwrap();
        std::fs::write(target.join("notes.txt"), b"old").unwrap();
        std::fs::write(target.join("notes 2.txt"), b"older").unwrap();
        if policy != "replace" {
            std::fs::create_dir(target.join("folder")).unwrap();
        }
        let result = helper.copy(&bytes, &target, policy, &["folder", "notes.txt"]).unwrap();
        assert_eq!((result.replaced, result.kept, result.skipped), counts, "{policy}");
        assert_eq!((result.entries, result.bytes), (6, 17));
        assert_eq!(names(&target), expected, "{policy}");
        let notes = std::fs::read(target.join("notes.txt")).unwrap();
        assert_eq!(notes, if policy == "replace" { &b"incoming notes"[..] } else { b"old" });
    }
    let copied = scratch.0.join("target-replace/folder");
    assert_eq!(std::fs::read_link(copied.join("to-tmp")).unwrap(), Path::new("/tmp"));
    assert_eq!(std::fs::read(copied.join("inner/a.txt")).unwrap(), b"a");
}

fn archives() -> Vec<String> {
    names(&std::env::temp_dir()).into_iter().filter(|n| n.starts_with("dispatch-pack-")).collect()
}

#[test]
fn pack_requests_are_checked_one_runs_at_a_time_and_a_drop_removes_the_archive() {
    let scratch = Scratch::new("pack");
    let mut helper = Helper::new();
    let base = tree(&scratch);
    let folder = [base.join("folder")];
    for (base, paths) in [
        (PathBuf::from("relative"), folder.to_vec()),
        (base.clone(), vec![scratch.0.join("elsewhere")]),
        (base.clone(), vec![base.join("../outside")]),
        (base.clone(), vec![base.clone()]),
        (base.clone(), vec![]),
    ] {
        assert_eq!(code(helper.pack("bad", &base, &paths, 0)), "invalid_request");
    }
    // `..` that stays inside the base is fine.
    let before = archives();
    helper.pack("dots", &base, &[base.join("folder/../notes.txt")], 0).unwrap();
    assert_eq!(code(helper.pack("dots", &base, &folder, 0)), "invalid_request", "a transfer id in use");
    helper.drop_pack("dots").unwrap();

    let first = helper.start_pack("first", &base, &folder, 0);
    assert_eq!(code(helper.pack("second", &base, &folder, 0)), "busy");
    // Dropped while it runs: the archive is removed when it ends, and the pack reports the cancellation.
    helper.drop_pack("first").unwrap();
    assert_eq!(code(helper.wait(&first)), "cancelled");
    let packed = helper.pack("second", &base, &folder, 0).unwrap();
    assert_eq!(code(helper.pack("third", &base, &folder, 2)), "limit");
    helper.drop_pack("second").unwrap();
    assert!(!Path::new(&packed.archive).exists());
    // The cancelled pack's removal is a job of its own; one more round trip lets it finish.
    helper.pack("last", &base, &folder, 0).unwrap();
    helper.drop_pack("last").unwrap();
    assert_eq!(archives(), before, "no archive is left behind");
}

#[test]
fn the_first_pack_sweeps_archives_older_than_a_day() {
    let scratch = Scratch::new("sweep");
    let base = tree(&scratch);
    let temporary = std::env::temp_dir();
    let (old, recent) = (
        temporary.join(format!("dispatch-pack-sweep-old-{}.tar.zst", std::process::id())),
        temporary.join(format!("dispatch-pack-sweep-new-{}.tar.zst", std::process::id())),
    );
    let day = std::time::SystemTime::now() - std::time::Duration::from_secs(25 * 60 * 60);
    let aged = |path: &Path| {
        std::fs::write(path, b"").unwrap();
        std::fs::File::options().write(true).open(path).unwrap().set_times(std::fs::FileTimes::new().set_modified(day)).unwrap();
    };
    aged(&old);
    std::fs::write(&recent, b"").unwrap();
    let mut helper = Helper::new();
    helper.packed(&base, &[base.join("notes.txt")]);
    assert!(!old.exists() && recent.exists());
    // Only the first pack of a helper sweeps.
    aged(&old);
    helper.packed(&base, &[base.join("notes.txt")]);
    assert!(old.exists());
    std::fs::remove_file(&old).unwrap();
    std::fs::remove_file(&recent).unwrap();
}

#[test]
fn unpack_requests_are_checked_and_an_uncommitted_close_leaves_the_target_alone() {
    let scratch = Scratch::new("unpack");
    let mut helper = Helper::new();
    let base = tree(&scratch);
    let bytes = helper.packed(&base, &[base.join("folder")]);
    let target = scratch.0.join("target");
    std::fs::create_dir(&target).unwrap();
    std::fs::write(target.join("mine.txt"), b"mine").unwrap();
    assert_eq!(code(helper.open("t", &target, "merge", &["folder"])), "invalid_request");
    assert_eq!(code(helper.open("t", Path::new("relative"), "skip", &["folder"])), "invalid_request");
    assert_eq!(code(helper.open("t", &target.join("x/../y"), "skip", &["folder"])), "invalid_request");
    assert_eq!(code(helper.open("t", &target.join("mine.txt"), "skip", &["folder"])), "not_directory");
    assert_eq!(code(helper.open("t", &target.join("missing"), "skip", &["folder"])), "not_found");
    assert_eq!(code(helper.close("t", false)), "invalid_request", "nothing is open");

    let transfer = helper.open("t", &target, "replace", &["folder"]).unwrap();
    let staging = PathBuf::from(&transfer.staging);
    assert_eq!(staging.parent(), Some(target.as_path()));
    assert!(staging.file_name().unwrap().to_string_lossy().starts_with(".dispatch-copy-"));
    assert_eq!(std::fs::metadata(&staging).unwrap().mode() & 0o777, 0o700);
    assert_eq!(std::fs::metadata(staging.join("archive.tar.zst")).unwrap().len(), 0);
    assert_eq!(code(helper.open("other", &target, "replace", &["folder"])), "busy");
    assert_eq!(code(helper.send("other", b"x")), "invalid_request");
    assert_eq!(code(helper.send("t", &vec![0; (8 << 20) + 1])), "limit");
    assert_eq!(helper.send("t", &bytes[..10]).unwrap().bytes, 10);
    assert_eq!(helper.send("t", b"").unwrap().bytes, 10);
    assert_eq!(helper.close("t", false).unwrap(), Unpacked::default());
    assert!(!staging.exists());
    assert_eq!(names(&target), ["mine.txt"]);

    // A cut archive is refused at commit, and nothing reaches the target.
    let transfer = helper.open("t", &target, "replace", &["folder"]).unwrap();
    helper.send("t", &bytes[..bytes.len() / 2]).unwrap();
    assert_eq!(code(helper.close("t", true)), "invalid_request");
    assert!(!Path::new(&transfer.staging).exists());
    assert_eq!(names(&target), ["mine.txt"]);

    // A close sent while a write runs waits for it; another write meanwhile is refused.
    helper.open("t", &target, "skip", &["folder"]).unwrap();
    let (written, done) = slot();
    helper.files.unpack_write(&mut helper.io, "t", bytes.clone(), done);
    let (busy, refused) = slot();
    helper.files.unpack_write(&mut helper.io, "t", b"x".to_vec(), refused);
    let (closed, close) = slot();
    helper.files.unpack_close(&mut helper.io, "t", true, close);
    assert_eq!(helper.wait(&busy).unwrap_err().code, "busy");
    assert_eq!(helper.wait(&written).unwrap().bytes, bytes.len() as u64);
    assert_eq!(helper.wait(&closed).unwrap().entries, 5);
    assert_eq!(names(&target), ["folder", "mine.txt"]);
    // A close without commit sent while the commit runs (a client leaving then) stops its extraction, and is
    // answered once the commit ends: cancelled with nothing moved, or done if it was already moving entries in.
    helper.open("t", &target, "skip", &["folder"]).unwrap();
    helper.send("t", &bytes).unwrap();
    let (committed, commit) = slot();
    helper.files.unpack_close(&mut helper.io, "t", true, commit);
    let (late, close) = slot();
    helper.files.unpack_close(&mut helper.io, "t", false, close);
    assert_eq!(helper.wait(&late).unwrap(), Unpacked::default());
    match helper.wait(&committed) {
        Ok(unpacked) => assert_eq!(unpacked.skipped, 1),
        Err(error) => assert_eq!(error.code, "cancelled"),
    }
    assert_eq!(names(&target), ["folder", "mine.txt"]);
    // A close sent during the open (a client leaving at once) removes what the open made.
    let (opened, open) = slot();
    let parent = identity(&std::fs::metadata(&target).unwrap());
    helper.files.unpack_open(&mut helper.io, "u", &target, "skip", &strings(&["folder"]), parent, &[], open);
    let (closed, close) = slot();
    helper.files.unpack_close(&mut helper.io, "u", false, close);
    let staging = PathBuf::from(helper.wait(&opened).unwrap().staging);
    assert_eq!(helper.wait(&closed).unwrap(), Unpacked::default());
    assert!(!staging.exists());
}

/// A ustar header block as a hostile sender would write it (no pax, whole-second mtime).
fn block(name: &str, flag: u8, size: usize, link: &str) -> Vec<u8> {
    let mut b = vec![0u8; 512];
    b[..name.len()].copy_from_slice(name.as_bytes());
    b[100..108].copy_from_slice(b"0000644\0");
    b[108..116].copy_from_slice(b"0000000\0");
    b[116..124].copy_from_slice(b"0000000\0");
    b[124..136].copy_from_slice(format!("{size:011o}\0").as_bytes());
    b[136..148].copy_from_slice(b"14000000000\0");
    b[156] = flag;
    b[157..157 + link.len()].copy_from_slice(link.as_bytes());
    b[257..263].copy_from_slice(b"ustar\0");
    b[263..265].copy_from_slice(b"00");
    b[148..156].fill(b' ');
    let sum: u32 = b.iter().map(|&v| u32::from(v)).sum();
    b[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
    b
}

/// `entries` (header, content) as a tar inside one zstd frame of raw blocks: what the plugin's decoder must
/// accept from any encoder.
fn hostile(entries: &[(Vec<u8>, &[u8])]) -> Vec<u8> {
    let mut tar = Vec::new();
    for (header, content) in entries {
        tar.extend_from_slice(header);
        tar.extend_from_slice(content);
        tar.resize(tar.len().next_multiple_of(512), 0);
    }
    tar.extend_from_slice(&[0; 1024]);
    // Magic, a frame header with only a window descriptor (128 KiB), then raw blocks of at most 128 KiB.
    let mut frame = vec![0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x38];
    let chunks: Vec<_> = tar.chunks(128 * 1024).collect();
    for (i, chunk) in chunks.iter().enumerate() {
        let last = u32::from(i + 1 == chunks.len());
        let header = last | ((chunk.len() as u32) << 3);
        frame.extend_from_slice(&header.to_le_bytes()[..3]);
        frame.extend_from_slice(chunk);
    }
    frame
}

#[test]
fn hostile_archives_are_refused_without_touching_the_target() {
    let scratch = Scratch::new("hostile");
    let mut helper = Helper::new();
    let target = scratch.0.join("target");
    let outside = scratch.0.join("outside");
    std::fs::create_dir_all(&target).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(target.join("mine.txt"), b"mine").unwrap();
    let file = |name: &str| (block(name, b'0', 1, ""), &b"x"[..]);
    let outside_link = outside.to_string_lossy().into_owned();
    // Accepted when well-formed: the same encoding with a harmless entry.
    assert_eq!(helper.copy(&hostile(&[file("fine.txt")]), &target, "skip", &["fine.txt"]).unwrap().entries, 1);
    std::fs::remove_file(target.join("fine.txt")).unwrap();
    for entries in [
        vec![file("../x")],
        vec![file("/etc/x")],
        vec![(block("link", b'2', 0, &outside_link), &b""[..]), file("link/x")],
        vec![(block("tmp", b'2', 0, "/tmp"), &b""[..]), (block("tmp/", b'5', 0, ""), &b""[..])],
        vec![file("a"), (block("hard", b'1', 0, "a"), &b""[..])],
        vec![(block("dev", b'3', 0, ""), &b""[..])],
        vec![file("")],
    ] {
        let sent = ["x", "link", "tmp", "a", "hard", "dev"];
        assert_eq!(code(helper.copy(&hostile(&entries), &target, "replace", &sent)), "invalid_request");
        assert_eq!(names(&target), ["mine.txt"]);
        assert!(names(&outside).is_empty());
    }
}

#[test]
fn an_archive_may_hold_only_the_top_level_names_the_open_named() {
    let scratch = Scratch::new("names");
    let mut helper = Helper::new();
    let target = scratch.0.join("home");
    std::fs::create_dir_all(target.join("Library")).unwrap();
    std::fs::write(target.join("Library/mine"), b"mine").unwrap();
    for names in [&[][..], &[""], &["."], &[".."], &["a/b"], &["a\0b"], &[".dispatch-copy-x"]] {
        assert_eq!(code(helper.open("t", &target, "skip", names)), "invalid_request", "{names:?}");
    }
    let file = |name: &str| (block(name, b'0', 1, ""), &b"x"[..]);
    for (entries, offender) in [
        (vec![file("Documents/a"), file(".zprofile")], ".zprofile"),
        (vec![file("Library/evil")], "Library"),
    ] {
        for policy in ["replace", "keep", "skip"] {
            let error = helper.copy(&hostile(&entries), &target, policy, &["Documents"]).unwrap_err();
            assert_eq!(error.code, "invalid_request");
            assert!(error.message.contains(offender), "{}", error.message);
            assert_eq!(names(&target), ["Library"]);
            assert_eq!(names(&target.join("Library")), ["mine"]);
        }
    }
    helper.copy(&hostile(&[file("Documents/a")]), &target, "replace", &["Documents"]).unwrap();
    assert_eq!(names(&target), ["Documents", "Library"]);
}

#[test]
fn one_pack_or_one_commit_runs_at_a_time() {
    let scratch = Scratch::new("gate");
    let mut helper = Helper::new();
    let base = tree(&scratch);
    let bytes = helper.packed(&base, &[base.join("folder")]);
    let target = scratch.0.join("target");
    std::fs::create_dir(&target).unwrap();
    // A commit while a pack runs is refused and the transfer stays open for a later one.
    helper.open("t", &target, "skip", &["folder"]).unwrap();
    helper.send("t", &bytes).unwrap();
    let packing = helper.start_pack("p", &base, &[base.join("folder")], 0);
    assert_eq!(code(helper.close("t", true)), "busy");
    helper.wait(&packing).unwrap();
    helper.drop_pack("p").unwrap();
    assert_eq!(helper.close("t", true).unwrap().entries, 5);
    // A pack while a commit runs is refused.
    std::fs::remove_dir_all(target.join("folder")).unwrap();
    helper.open("t", &target, "skip", &["folder"]).unwrap();
    helper.send("t", &bytes).unwrap();
    let (committed, commit) = slot();
    helper.files.unpack_close(&mut helper.io, "t", true, commit);
    assert_eq!(code(helper.pack("p", &base, &[base.join("folder")], 0)), "busy");
    assert_eq!(helper.wait(&committed).unwrap().entries, 5);
    helper.packed(&base, &[base.join("folder")]);
}

#[test]
fn files_write_without_replace_finds_anything_at_the_path() {
    use std::os::unix::fs::PermissionsExt;
    let scratch = Scratch::new("write-exists");
    let mut helper = Helper::new();
    std::fs::write(scratch.0.join("real"), b"real").unwrap();
    std::os::unix::fs::symlink(scratch.0.join("real"), scratch.0.join("link")).unwrap();
    std::os::unix::fs::symlink(scratch.0.join("missing"), scratch.0.join("dangling")).unwrap();
    std::fs::write(scratch.0.join("closed"), b"closed").unwrap();
    std::fs::set_permissions(scratch.0.join("closed"), std::fs::Permissions::from_mode(0)).unwrap();
    std::fs::create_dir(scratch.0.join("directory")).unwrap();
    for name in ["link", "dangling", "closed", "directory"] {
        assert_eq!(code(helper.write(&scratch.0.join(name), b"new", None, false)), "exists", "{name}");
    }
    assert_eq!(std::fs::read(scratch.0.join("real")).unwrap(), b"real");
    assert!(std::fs::symlink_metadata(scratch.0.join("dangling")).unwrap().file_type().is_symlink());
    std::fs::set_permissions(scratch.0.join("closed"), std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(std::fs::read(scratch.0.join("closed")).unwrap(), b"closed");
}

#[test]
fn a_target_renamed_during_the_copy_keeps_its_staging_folder_and_says_where() {
    let scratch = Scratch::new("renamed");
    let mut helper = Helper::new();
    let base = tree(&scratch);
    let bytes = helper.packed(&base, &[base.join("folder")]);
    for commit in [true, false] {
        let target = scratch.0.join("target");
        std::fs::create_dir(&target).unwrap();
        let transfer = helper.open("t", &target, "skip", &["folder"]).unwrap();
        helper.send("t", &bytes).unwrap();
        let renamed = scratch.0.join(format!("renamed-{commit}"));
        std::fs::rename(&target, &renamed).unwrap();
        std::fs::create_dir(&target).unwrap();
        let error = helper.close("t", commit).unwrap_err();
        assert_eq!(error.code, "io", "{commit}");
        let name = Path::new(&transfer.staging).file_name().unwrap().to_string_lossy().into_owned();
        assert!(error.message.contains(&name), "{}", error.message);
        assert!(names(&target).is_empty(), "nothing reaches the folder now at the target's path");
        assert_eq!(names(&renamed), [name]);
        std::fs::remove_dir(&target).unwrap();
        // The transfer is over all the same: another can open.
        helper.open("u", &renamed, "skip", &["folder"]).unwrap();
        helper.close("u", false).unwrap();
    }
}

#[test]
fn an_unpack_is_bound_to_its_staging_folder_and_replacement_entry() {
    let scratch = Scratch::new("unpack-identity");
    let mut helper = Helper::new();
    let base = tree(&scratch);
    let bytes = helper.packed(&base, &[base.join("notes.txt")]);
    let target = scratch.0.join("target");
    std::fs::create_dir(&target).unwrap();
    std::fs::write(target.join("notes.txt"), b"listed").unwrap();

    let transfer = helper.open("staging", &target, "replace", &["notes.txt"]).unwrap();
    let staging = PathBuf::from(&transfer.staging);
    let original = scratch.0.join("original-staging");
    std::fs::rename(&staging, &original).unwrap();
    std::fs::create_dir(&staging).unwrap();
    std::fs::write(staging.join("archive.tar.zst"), b"intruder").unwrap();
    assert_eq!(code(helper.send("staging", &bytes)), "changed");
    assert_eq!(std::fs::read(staging.join("archive.tar.zst")).unwrap(), b"intruder");
    assert_eq!(std::fs::metadata(original.join("archive.tar.zst")).unwrap().len(), 0);

    // A fresh helper stands in for the disconnected first client; its stale staging state is discarded with it.
    let mut helper = Helper::new();
    let transfer = helper.open("entry", &target, "replace", &["notes.txt"]).unwrap();
    helper.send("entry", &bytes).unwrap();
    std::fs::remove_file(target.join("notes.txt")).unwrap();
    std::fs::write(target.join("notes.txt"), b"intruder").unwrap();
    assert_eq!(code(helper.close("entry", true)), "changed");
    assert_eq!(std::fs::read(target.join("notes.txt")).unwrap(), b"intruder");
    assert!(!Path::new(&transfer.staging).exists(), "a safely restored conflict leaves no staging tree");
}

#[test]
fn transfer_failures_have_their_own_codes() {
    let unsupported = io::Error::new(io::ErrorKind::Unsupported, "this file system cannot rename without replacing");
    assert_eq!(transfer::failure(unsupported).code, "unsupported");
    let changed = io::Error::new(io::ErrorKind::StaleNetworkFileHandle, "a file changed while packing");
    assert_eq!(pack::packing(changed).code, "changed");
    assert_eq!(pack::packing(io::Error::new(io::ErrorKind::InvalidData, "zstd: Corrupted block")).code, "io");
    assert_eq!(pack::packing(io::Error::new(io::ErrorKind::QuotaExceeded, "more entries than the limit")).code, "limit");
}

const COPY_ROOT: &str = "FILES_TEST_COPY_ROOT";
/// The target's `device:inode`, as the client sent it in both runs.
const COPY_PARENT: &str = "FILES_TEST_COPY_PARENT";

/// The recorded process of `a_copy_replays_with_its_random_names_without_its_files`; does nothing in an ordinary
/// run.
#[test]
fn copied_process() {
    let Some(root) = std::env::var_os(COPY_ROOT).map(PathBuf::from) else {
        return;
    };
    let mut helper = Helper::new();
    let (base, target) = (root.join("source"), root.join("target"));
    let packed = helper.pack("out", &base, &[base.join("folder")], 0);
    let dropped = helper.drop_pack("out");
    let file = |name: &str| (block(name, b'0', 1, ""), &b"x"[..]);
    let bytes = hostile(&[file("folder/a"), file("folder/b")]);
    let parent = std::env::var(COPY_PARENT).unwrap();
    let (device, inode) = parent.split_once(':').unwrap();
    let parent = FileIdentity { device: device.parse().unwrap(), inode: inode.parse().unwrap() };
    let opened = helper.open_in("in", &target, parent, "keep", &["folder"]);
    let sent = helper.send("in", &bytes);
    let closed = helper.close("in", true);
    println!("RESULT {packed:?}\nRESULT {dropped:?}\nRESULT {opened:?}\nRESULT {sent:?}\nRESULT {closed:?}");
    helper.io.finish(0).unwrap();
}

#[test]
fn a_copy_replays_with_its_random_names_without_its_files() {
    let scratch = Scratch::new("copy-replay");
    let base = tree(&scratch);
    let target = scratch.0.join("target");
    std::fs::create_dir_all(target.join("folder")).unwrap();
    let parent = std::fs::metadata(&target).unwrap();
    let parent = format!("{}:{}", parent.dev(), parent.ino());
    let recordings = Scratch::new("copy-replay-capture");
    let capture = recordings.0.join("helper.rpl.zst");
    let run = |control: &str| {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "transfer_tests::copied_process", "--nocapture"])
            .env(COPY_ROOT, &scratch.0)
            .env(COPY_PARENT, &parent)
            .env(control, &capture)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(output.status.success(), "{control}: {stdout}\n{}", String::from_utf8_lossy(&output.stderr));
        stdout.lines().filter_map(|line| line.find("RESULT ").map(|at| line[at..].to_owned())).collect::<Vec<_>>()
    };
    let live = run("DISPATCH_CAPTURE");
    if !capture.exists() {
        eprintln!("skipped: dispatch-helper-core was built without its capture feature");
        return;
    }
    assert_eq!(live.len(), 5, "{live:?}");
    assert!(live[0].contains("dispatch-pack-") && live[0].contains("entries: 5"), "{}", live[0]);
    assert!(live[2].contains(".dispatch-copy-"), "{}", live[2]);
    assert!(live[4].contains("entries: 2") && live[4].contains("kept: 1"), "{}", live[4]);
    assert_eq!(names(&target), ["folder", "folder 2"]);
    // Replay answers from the recording alone, the same random archive and staging names included.
    std::fs::remove_dir_all(&base).unwrap();
    std::fs::remove_dir_all(&target).unwrap();
    let replayed = run("DISPATCH_REPLAY");
    assert_eq!(replayed, live);
    assert!(!target.exists(), "a replay touches no file");
}
