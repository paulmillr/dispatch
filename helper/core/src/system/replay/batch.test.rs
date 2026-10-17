use super::*;

#[test]
fn every_regular_capture_inside_the_tree_is_listed_and_no_link_is_followed() {
    let root = std::env::temp_dir().join(format!("batch-captures-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let (tree, outside) = (root.join("tree"), root.join("outside"));
    fs::create_dir_all(tree.join("sub")).unwrap();
    fs::create_dir_all(&outside).unwrap();
    for file in ["tree/a.rpl.zst", "tree/a.txt", "tree/a.mismatch-1.rpl.zst", "tree/sub/b.rpl.zst", "outside/c.rpl.zst"] {
        File::create(root.join(file)).unwrap();
    }
    // Links to a capture and to a directory outside the tree, and one up the tree (a loop).
    for (link, target) in [("tree/c.rpl.zst", "../outside/c.rpl.zst"), ("tree/out", "../outside"), ("tree/sub/up", "..")] {
        std::os::unix::fs::symlink(target, root.join(link)).unwrap();
    }
    let listed = captures(&tree).map_err(|error| error.kind());
    fs::remove_dir_all(&root).unwrap();
    assert_eq!(listed, Ok(vec![tree.join("a.rpl.zst"), tree.join("sub/b.rpl.zst")]));
}
