use super::*;
use crate::harness::{Tree, both, drive, list, system};
use dispatch_helper_core::api::FileKind;
use std::process::Command;

fn names(listing: &Listing) -> Vec<&str> {
    listing
        .entries
        .iter()
        .map(|entry| entry.name.as_str())
        .collect()
}

fn code<T: std::fmt::Debug>(result: Result<T, Error>) -> &'static str {
    result.unwrap_err().code
}

#[test]
fn a_listing_names_its_path_and_shows_dot_names_only_when_asked() {
    let tree = Tree::new("list");
    tree.file("b", b"12");
    tree.file(".a", b"");
    tree.file("C/inner", b"");
    tree.link("l", "b");
    for mut files in both() {
        let all = list(&mut files, &tree.root, true, 0).unwrap();
        assert_eq!(all.path, tree.root.to_str().unwrap());
        assert_eq!(
            (names(&all), all.truncated),
            (vec![".a", "C", "b", "l"], false)
        );
        let kinds: Vec<_> = all
            .entries
            .iter()
            .map(|e| (e.kind, e.target, e.size))
            .collect();
        assert_eq!(
            kinds,
            vec![
                (FileKind::File, None, 0),
                (FileKind::Directory, None, 0),
                (FileKind::File, None, 2),
                (FileKind::Symlink, Some(FileKind::File), 1),
            ]
        );
        let visible = list(&mut files, &tree.root, false, 0).unwrap();
        assert_eq!(names(&visible), vec!["C", "b", "l"]);
    }
}

#[test]
fn a_listing_holds_at_most_ten_thousand_entries() {
    let tree = Tree::new("list-bound");
    for index in 0..10_001 {
        std::fs::File::create(tree.root.join(format!("{index:05}"))).unwrap();
    }
    let mut files = Files::new(true);
    // 0 is the plugin's own bound; a larger one is capped at it.
    for limit in [0, 10_000, 20_000, u64::MAX] {
        let listing = list(&mut files, &tree.root, false, limit).unwrap();
        assert_eq!((listing.entries.len(), listing.truncated), (10_000, true));
        assert_eq!(listing.entries.last().unwrap().name, "09999");
    }
    let listing = list(&mut files, &tree.root, false, 3).unwrap();
    assert_eq!(
        (names(&listing), listing.truncated),
        (vec!["00000", "00001", "00002"], true)
    );
    std::fs::remove_file(tree.root.join("10000")).unwrap();
    assert!(!list(&mut files, &tree.root, false, 0).unwrap().truncated);
}

#[test]
fn a_listing_fails_with_the_paths_own_reason() {
    let mut tree = Tree::new("list-errors");
    let file = tree.file("plain", b"");
    tree.file("locked/inner", b"");
    let locked = tree.lock("locked");
    for mut files in both() {
        assert_eq!(
            code(list(&mut files, Path::new("relative"), false, 0)),
            "invalid_request"
        );
        assert_eq!(code(list(&mut files, &file, false, 0)), "not_directory");
        assert_eq!(
            code(list(&mut files, &tree.root.join("missing"), false, 0)),
            "not_found"
        );
        if locked {
            assert_eq!(
                code(list(&mut files, &tree.root.join("locked"), false, 0)),
                "permission_denied"
            );
        }
    }
}

const REPLAY_TREE: &str = "FILES_TEST_REPLAY_TREE";

/// The recorded process of `a_listing_and_a_summary_replay_without_their_tree`; does nothing
/// in an ordinary run.
#[test]
fn replayed_process() {
    let Some(root) = std::env::var_os(REPLAY_TREE).map(PathBuf::from) else {
        return;
    };
    let mut system = system();
    let mut files = Files::new(true);
    let listing = drive(&mut system, &mut files, |files, io, done| {
        files.list(io, &root, true, 0, false, done)
    });
    let totals = drive(&mut system, &mut files, |files, io, done| {
        files.summary(io, &root, 0, done)
    });
    let missing = drive(&mut system, &mut files, |files, io, done| {
        files.list(io, &root.join("missing"), true, 0, false, done)
    });
    println!("RESULT {listing:?}\nRESULT {totals:?}\nRESULT {missing:?}");
    system.finish(0).unwrap();
}

#[test]
fn a_listing_and_a_summary_replay_without_their_tree() {
    let tree = Tree::new("replay");
    tree.file("a", b"abc");
    tree.file(".b/c", b"de");
    tree.link("l", "a");
    tree.link("x", "missing");
    // Beside the tree, which replay runs without; removed with its own directory.
    let recordings = Tree::new("replay-capture");
    let capture = recordings.root.join("helper.rpl.zst");
    let run = |control: &str| {
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "list::tests::replayed_process", "--nocapture"])
            .env(REPLAY_TREE, &tree.root)
            .env(control, &capture)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            output.status.success(),
            "{control}: {stdout}\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
        // libtest's "test ... " precedes the first line without a break.
        stdout
            .lines()
            .filter_map(|line| line.find("RESULT ").map(|at| line[at..].to_owned()))
            .collect::<Vec<_>>()
    };
    let live = run("DISPATCH_CAPTURE");
    if !capture.exists() {
        eprintln!("skipped: dispatch-helper-core was built without its capture feature");
        return;
    }
    assert_eq!(live.len(), 3);
    assert!(
        live[0].contains(r#"name: "x", kind: Symlink, size: 7"#),
        "{}",
        live[0]
    );
    assert!(
        live[1].contains("files: 4, folders: 1, bytes: 5"),
        "{}",
        live[1]
    );
    assert!(live[2].contains(r#"code: "not_found""#), "{}", live[2]);
    // Replay answers from the recording alone.
    std::fs::remove_dir_all(&tree.root).unwrap();
    let replayed = run("DISPATCH_REPLAY");
    assert_eq!(replayed, live);
}
