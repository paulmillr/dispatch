use super::*;

const SAM: u64 = 501;

fn check(kind: &str, owner: u64, mode: u64) -> Option<String> {
    folder(Path::new("/home/sam/.pi"), SAM, kind, owner, mode)
}

/// A folder on the way to Pi's extension passes when only its owner (this account or root) can change it.
#[test]
fn private_folders_of_the_account_or_root_pass() {
    assert_eq!(check("directory", SAM, 0o40700), None);
    assert_eq!(check("directory", SAM, 0o40755), None);
    assert_eq!(check("directory", 0, 0o40755), None, "/, /Users, /home");
    assert_eq!(check("directory", SAM, 0o40750), None, "readable by the group is fine");
}

/// Group or others' write lets them rename what Pi loads: refused with the mode and the command that fixes it,
/// except in a root-owned sticky folder (`/tmp`), where they cannot touch what is not theirs.
#[test]
fn folders_others_can_write_are_refused_unless_root_and_sticky() {
    let why = check("directory", SAM, 0o40775).unwrap();
    assert!(why.starts_with("is writable by its group or others (mode 775)"), "{why}");
    assert!(why.contains("Run chmod go-w '/home/sam/.pi' and install again."), "{why}");
    assert!(check("directory", SAM, 0o40757).is_some(), "others' write");
    assert!(check("directory", 0, 0o40777).is_some(), "root's, not sticky");
    assert_eq!(check("directory", 0, 0o41777), None, "/tmp");
    assert!(check("directory", SAM, 0o41777).is_some(), "sticky, but the owner is not root");
}

/// Another account's folder or link is refused whatever its mode; a link of the account's or root's passes (where it
/// leads is checked as a folder of its own); anything else on the way is not a folder.
#[test]
fn other_owners_links_and_files() {
    assert!(check("directory", 502, 0o40700).unwrap().starts_with("belongs to another account"));
    assert!(check("symlink", 502, 0o120777).unwrap().starts_with("belongs to another account"));
    assert_eq!(check("symlink", SAM, 0o120777), None);
    assert_eq!(check("symlink", 0, 0o120755), None, "/tmp on macOS");
    assert_eq!(check("file", SAM, 0o100644).as_deref(), Some("is not a folder."));
}

/// A path in a suggested command survives the shell, quotes included.
#[test]
fn suggested_commands_quote_their_path() {
    assert_eq!(quoted(Path::new("/home/sam/it's")), "'/home/sam/it'\\''s'");
}
