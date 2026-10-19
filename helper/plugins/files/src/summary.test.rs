use super::*;
use crate::harness::{Tree, both, summary};

#[test]
fn a_summary_totals_the_tree_below_without_following_symlinks() {
    let mut tree = Tree::new("summary");
    tree.file("a", &[1; 4]);
    tree.file("d/b", &[1; 6]);
    tree.file("d/e/c", b"");
    tree.link("d/loop", "..");
    tree.link("big", "a");
    tree.file("locked/unseen", &[1; 50]);
    let locked = tree.lock("locked");
    for mut files in both() {
        let totals = summary(&mut files, &tree.root, 0).unwrap();
        // Symlinks count as files without bytes; a folder that cannot be read counts, its
        // contents do not (as root they do).
        let (files_below, bytes) = if locked { (5, 10) } else { (6, 60) };
        assert_eq!(
            totals,
            FolderSummary {
                files: files_below,
                folders: 3,
                bytes,
                truncated: false
            }
        );
        let bounded = summary(&mut files, &tree.root, 2).unwrap();
        assert!(bounded.truncated);
        assert_eq!(bounded.files + bounded.folders, 2);
    }
}

#[test]
fn a_summary_fails_with_the_paths_own_reason() {
    let mut tree = Tree::new("summary-errors");
    let file = tree.file("plain", b"");
    tree.file("locked/inner", b"");
    let locked = tree.lock("locked");
    for mut files in both() {
        let code = |result: Result<FolderSummary, Error>| result.unwrap_err().code;
        assert_eq!(
            code(summary(&mut files, Path::new("relative"), 0)),
            "invalid_request"
        );
        assert_eq!(code(summary(&mut files, &file, 0)), "not_directory");
        assert_eq!(
            code(summary(&mut files, &tree.root.join("missing"), 0)),
            "not_found"
        );
        if locked {
            assert_eq!(
                code(summary(&mut files, &tree.root.join("locked"), 0)),
                "permission_denied"
            );
        }
    }
}
