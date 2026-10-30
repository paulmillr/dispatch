use super::*;

fn file(inode: u64, size: u64, changed_ns: i128) -> Metadata {
    Metadata { kind: FileKind::File, size, device: 1, inode, modified_ns: 0, changed_ns }
}

#[test]
fn a_reload_of_the_same_rollout_continues_it() {
    let reached = Some((file(7, 4_000, 1), 4_000));
    // An attribute change or a failed read: the same file, maybe grown, its page reaching back.
    assert!(continues(reached, Some(file(7, 4_000, 2)), Some("3000")));
    assert!(continues(reached, Some(file(7, 5_000, 2)), Some("generation:3500")));
    assert!(continues(reached, Some(file(7, 5_000, 2)), None));
    // A page that starts after what was shown would leave a gap: replace instead.
    assert!(!continues(reached, Some(file(7, 90_000, 2)), Some("60000")));
    // Shortened, replaced, another rollout, or no follow to compare with.
    assert!(!continues(reached, Some(file(7, 3_000, 2)), None));
    assert!(!continues(reached, Some(file(8, 5_000, 2)), None));
    assert!(!continues(None, Some(file(7, 5_000, 2)), None));
    assert!(!continues(reached, None, None));
}
