use super::*;
use std::os::unix::fs::symlink;

/// A scratch directory under the test temp root, removed (after unlocking what a test locked)
/// when the test ends, passed or not.
struct Tree {
    root: PathBuf,
    locked: Vec<PathBuf>,
}

impl Tree {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir().join(format!("listing-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        Self {
            root,
            locked: Vec::new(),
        }
    }
    fn file(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.root.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, bytes).unwrap();
        path
    }
    fn folder(&self, name: &str) -> PathBuf {
        let path = self.root.join(name);
        std::fs::create_dir_all(&path).unwrap();
        path
    }
    fn link(&self, name: &str, target: &str) {
        symlink(target, self.root.join(name)).unwrap();
    }
    /// A fifo through mkfifo(1); false where there is none.
    fn fifo(&self, name: &str) -> bool {
        Command::new("mkfifo")
            .arg(self.root.join(name))
            .status()
            .is_ok_and(|status| status.success())
    }
    /// No permissions at all; false when running as root, which they do not stop.
    fn lock(&mut self, name: &str) -> bool {
        if native::account().is_ok_and(|account| account.uid == 0) {
            return false;
        }
        let path = self.root.join(name);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0)).unwrap();
        self.locked.push(path);
        true
    }
}

impl Drop for Tree {
    fn drop(&mut self) {
        for path in &self.locked {
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755));
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn listed(path: &Path, hidden: bool, limit: u64) -> (Vec<Entry>, bool) {
    match entries(path, hidden, limit).unwrap() {
        Output::Entries(entries, truncated) => (entries, truncated),
        other => panic!("not entries: {other:?}"),
    }
}

fn names(entries: &[Entry]) -> Vec<&str> {
    entries.iter().map(|entry| entry.name.as_str()).collect()
}

fn epoch_ns() -> i128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos() as i128
}

#[test]
fn a_listing_is_one_level_in_bytewise_order_and_never_follows_a_symlink() {
    let tree = Tree::new("kinds");
    let before = epoch_ns();
    tree.file("b.txt", b"abc");
    tree.file(".hidden", b"");
    tree.file("Beta", b"");
    tree.file("alpha", b"");
    tree.file("10", b"");
    tree.file("2", b"");
    tree.file("dir/inner", b"not listed");
    tree.link("link-file", "b.txt");
    tree.link("link-dir", "dir");
    tree.link("dangling", "missing");
    let fifo = tree.fifo("fifo");
    let after = epoch_ns();

    let (entries, truncated) = listed(&tree.root, true, 100);
    assert!(!truncated);
    let mut expected = vec![
        ".hidden",
        "10",
        "2",
        "Beta",
        "alpha",
        "b.txt",
        "dangling",
        "dir",
        "fifo",
        "link-dir",
        "link-file",
    ];
    if !fifo {
        expected.retain(|name| *name != "fifo");
    }
    assert_eq!(names(&entries), expected);
    let entry = |name: &str| entries.iter().find(|entry| entry.name == name).unwrap();
    let kinds = |name: &str| (entry(name).kind, entry(name).target);
    assert_eq!(kinds("b.txt"), (FileKind::File, None));
    assert_eq!(kinds("dir"), (FileKind::Directory, None));
    assert_eq!(
        kinds("link-file"),
        (FileKind::Symlink, Some(FileKind::File))
    );
    assert_eq!(
        kinds("link-dir"),
        (FileKind::Symlink, Some(FileKind::Directory))
    );
    assert_eq!(kinds("dangling"), (FileKind::Symlink, None));
    if fifo {
        assert_eq!(kinds("fifo"), (FileKind::Other, None));
    }
    assert_eq!(entry("b.txt").size, 3);
    // A directory's size is always 0; a symlink's is its own (the target text), not the target's.
    assert_eq!(entry("dir").size, 0);
    assert_eq!(entry("link-dir").size, 3);
    assert_eq!(entry("dangling").size, "missing".len() as u64);
    for entry in &entries {
        assert_eq!(entry.mark, None);
        // Filesystem timestamps may be coarser than the clock: a second of slack either side.
        assert!(
            (before - 1_000_000_000..=after + 1_000_000_000).contains(&entry.modified_ns),
            "{} modified {} outside {before}..{after}",
            entry.name,
            entry.modified_ns
        );
    }

    let (visible, _) = listed(&tree.root, false, 100);
    assert_eq!(names(&visible), expected[1..].to_vec());
}

#[test]
fn a_bounded_listing_keeps_the_first_names_and_says_more_exist() {
    let tree = Tree::new("bound");
    for name in ["e", "c", "a", "d", "b", ".z"] {
        tree.file(name, b"");
    }
    let (kept, truncated) = listed(&tree.root, false, 3);
    assert_eq!((names(&kept), truncated), (vec!["a", "b", "c"], true));
    // Hidden names are left out before counting: five visible names fit a bound of five.
    assert!(!listed(&tree.root, false, 5).1);
    assert!(listed(&tree.root, true, 5).1);
}

#[test]
fn names_that_are_not_utf8_are_kept_lossily_in_order_and_counted() {
    let native = |bytes: &[u8]| OsString::from(std::ffi::OsStr::from_bytes(bytes));
    let given = [
        native(b"zeta"),
        native(b"caf\xff"),
        native(b".dot"),
        native(b"caf\xfe"),
        native(b"alpha"),
    ];
    let (kept, truncated) = smallest(given.clone(), false, 10);
    assert!(!truncated);
    // Two names alike once lossy are both kept, told apart by their native bytes.
    assert_eq!(
        kept,
        vec![
            ("alpha".into(), native(b"alpha")),
            ("caf\u{fffd}".into(), native(b"caf\xfe")),
            ("caf\u{fffd}".into(), native(b"caf\xff")),
            ("zeta".into(), native(b"zeta")),
        ]
    );
    // They count toward the bound like any other name, whatever order readdir gave them.
    let (kept, truncated) = smallest(given.into_iter().rev(), false, 2);
    assert!(truncated);
    assert_eq!(kept.len(), 2);
    assert_eq!(kept[1].1, native(b"caf\xfe"));
}

#[test]
fn a_name_that_is_not_utf8_on_disk_is_listed_lossily() {
    let tree = Tree::new("lossy");
    let name = std::ffi::OsStr::from_bytes(b"bad-\xff");
    // APFS refuses such names (EILSEQ); Linux filesystems take them.
    if let Err(error) = std::fs::write(tree.root.join(name), b"x") {
        eprintln!("skipped: this filesystem refuses non-UTF-8 names ({error})");
        return;
    }
    let (entries, _) = listed(&tree.root, false, 10);
    assert_eq!(names(&entries), vec!["bad-\u{fffd}"]);
    assert_eq!((entries[0].kind, entries[0].size), (FileKind::File, 1));
}

#[test]
fn a_listing_of_a_file_or_a_missing_path_fails_natively() {
    let tree = Tree::new("errors");
    let file = tree.file("plain", b"");
    assert_eq!(
        entries(&file, false, 10).unwrap_err().kind(),
        io::ErrorKind::NotADirectory
    );
    assert_eq!(
        entries(&tree.root.join("missing"), false, 10)
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotFound
    );
}

#[test]
fn a_summary_counts_below_the_path_without_following_symlinks() {
    let mut tree = Tree::new("summary");
    tree.file("one", &[0; 10]);
    tree.file("a/two", &[0; 5]);
    tree.file("a/b/three", &[0; 7]);
    tree.folder("a/empty");
    // Loops a follower would never leave, and a link to a file it would count twice.
    tree.link("a/up", "..");
    tree.link("self", ".");
    tree.link("big", "one");
    let fifo = tree.fifo("fifo");
    let far = Instant::now() + Duration::from_secs(60);
    let totals = walk(&tree.root, 100, far).unwrap();
    assert_eq!(
        totals,
        FolderSummary {
            files: 6 + u64::from(fifo),
            folders: 3,
            bytes: 22,
            truncated: false
        }
    );

    // An unreadable folder is counted, its contents are not, and the walk goes on.
    tree.file("locked/hidden", &[0; 100]);
    if tree.lock("locked") {
        let totals = walk(&tree.root, 100, far).unwrap();
        assert_eq!(
            (totals.files, totals.folders, totals.bytes),
            (6 + u64::from(fifo), 4, 22)
        );
        assert!(!totals.truncated);
    }
}

#[test]
fn a_summary_stops_at_its_entry_bound_or_deadline() {
    let tree = Tree::new("summary-bound");
    for name in ["a", "b", "c", "d/e"] {
        tree.file(name, b"x");
    }
    let far = Instant::now() + Duration::from_secs(60);
    let bounded = walk(&tree.root, 3, far).unwrap();
    assert!(bounded.truncated);
    assert_eq!(bounded.files + bounded.folders, 3);
    // Exactly as many entries as the bound: complete.
    assert!(!walk(&tree.root, 5, far).unwrap().truncated);
    let late = walk(&tree.root, 100, Instant::now()).unwrap();
    assert_eq!(
        late,
        FolderSummary {
            truncated: true,
            ..FolderSummary::default()
        }
    );
}

#[test]
fn a_summary_of_a_file_or_a_missing_path_fails_natively() {
    let tree = Tree::new("summary-errors");
    let file = tree.file("plain", b"");
    assert_eq!(
        summary(&file, 10).unwrap_err().kind(),
        io::ErrorKind::NotADirectory
    );
    assert_eq!(
        summary(&tree.root.join("missing"), 10).unwrap_err().kind(),
        io::ErrorKind::NotFound
    );
}

/// What replay hands back for a recorded completion, and its encoding again.
fn replayed(result: io::Result<Output>) -> (io::Result<Output>, Vec<u8>, Vec<u8>) {
    let recorded = file::encode(&result).unwrap();
    let replayed = file::decode(0, &recorded, std::env::consts::OS)
        .unwrap()
        .result;
    let again = file::encode(&replayed).unwrap();
    (replayed, recorded, again)
}

#[test]
fn listings_and_summaries_replay_as_recorded() {
    let tree = Tree::new("capture");
    tree.file("a", b"abc");
    tree.folder("d");
    tree.link("l", "a");
    tree.link("x", "missing");
    let (mut listed, _) = listed(&tree.root, true, 10);
    // Marks are reserved, but their encoding is not.
    listed[0].mark = Some("M".into());
    let (result, recorded, again) = replayed(Ok(Output::Entries(listed.clone(), true)));
    assert_eq!(again, recorded);
    let Ok(Output::Entries(entries, truncated)) = result else {
        panic!("not entries: {result:?}")
    };
    assert_eq!((entries, truncated), (listed, true));

    let totals = FolderSummary {
        files: 3,
        folders: 1,
        bytes: u64::MAX,
        truncated: true,
    };
    let (result, recorded, again) = replayed(Ok(Output::Summary(totals)));
    assert_eq!(again, recorded);
    assert!(matches!(result, Ok(Output::Summary(value)) if value == totals));
}

#[test]
fn a_failed_listing_replays_as_the_same_error_on_either_system() {
    let tree = Tree::new("capture-errors");
    let file = tree.file("plain", b"");
    for (error, expected) in [
        (
            entries(&file, false, 10).unwrap_err(),
            io::ErrorKind::NotADirectory,
        ),
        (
            summary(&tree.root.join("missing"), 10).unwrap_err(),
            io::ErrorKind::NotFound,
        ),
    ] {
        let (result, recorded, again) = replayed(Err(error));
        assert_eq!(again, recorded);
        assert_eq!(result.unwrap_err().kind(), expected);
    }
    // ENOTDIR, ENOENT and EACCES are numbered alike on macOS and Linux: the plugin's
    // not_directory / not_found / permission_denied hold for a recording from either.
    for os in ["macos", "linux"] {
        let kind = |number: i64| {
            file::failure(&Data::Object(vec![("errno", Data::Signed(number))]), os)
                .unwrap()
                .kind()
        };
        assert_eq!(kind(20), io::ErrorKind::NotADirectory);
        assert_eq!(kind(2), io::ErrorKind::NotFound);
        assert_eq!(kind(13), io::ErrorKind::PermissionDenied);
    }
}

#[test]
fn an_mtime_past_i64_nanoseconds_is_clamped_and_the_listing_still_records() {
    let tree = Tree::new("far-mtime");
    let far = tree.file("far", b"");
    // Year 2300: past what i64 nanoseconds since the epoch hold (2262), within what APFS and ext4 store.
    let at = std::time::UNIX_EPOCH + std::time::Duration::from_secs(10_413_792_000);
    let stored = std::fs::File::options()
        .write(true)
        .open(&far)
        .and_then(|file| file.set_times(std::fs::FileTimes::new().set_modified(at)))
        .is_ok()
        && std::fs::metadata(&far).is_ok_and(|m| m.mtime() > 9_300_000_000);
    if !stored {
        eprintln!("this file system cannot store a year-2300 mtime: skipped");
        return;
    }
    let (entries, _) = listed(&tree.root, true, 10);
    assert_eq!(entries[0].modified_ns, i128::from(i64::MAX));
    let (result, recorded, again) = replayed(Ok(Output::Entries(entries.clone(), false)));
    assert_eq!(again, recorded);
    assert!(matches!(result, Ok(Output::Entries(back, false)) if back == entries));
}
