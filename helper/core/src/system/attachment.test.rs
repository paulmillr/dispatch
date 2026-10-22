use super::*;
use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf};

const FOLDER: &str = "00112233445566778899aabbccddeeff";
const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";

/// A private scratch home: `<home>/.dispatch/attachments` is the root under test.
struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        let mut nonce = [0; 16];
        super::super::random(&mut nonce).unwrap();
        let home = std::env::temp_dir().join(format!("dispatch-attach-{:x}", u128::from_ne_bytes(nonce)));
        fs::create_dir_all(home.join(".dispatch")).unwrap();
        fs::set_permissions(home.join(".dispatch"), fs::Permissions::from_mode(0o700)).unwrap();
        Self(home)
    }
    fn root(&self) -> PathBuf {
        self.0.join(".dispatch/attachments")
    }
}
impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn request(root: &Path, folder: &str, name: &str, field: (&'static str, Data<'_>)) -> Vec<u8> {
    crate::wire::body::encode_plain(&Data::Object(vec![
        ("root", Data::from(root)),
        ("folder", Data::String(folder)),
        ("name", Data::String(name)),
        field,
    ]))
    .unwrap()
}

fn put(root: &Path, folder: &str, name: &str, data: &[u8]) -> io::Result<PathBuf> {
    let answer = native("attachment.put", &request(root, folder, name, ("data", Data::Bytes(data))))?;
    let value = crate::wire::body::decode_plain(&answer).unwrap();
    Ok(value.get("path").and_then(Data::path).unwrap().to_owned())
}

fn read(root: &Path, folder: &str, name: &str, limit: u64) -> io::Result<(u64, Vec<u8>)> {
    let answer = native("attachment.read", &request(root, folder, name, ("limit", Data::Unsigned(limit))))?;
    let value = crate::wire::body::decode_plain(&answer).unwrap();
    Ok((value.get("size").and_then(Data::unsigned).unwrap(), value.get("data").and_then(Data::bytes).unwrap().to_vec()))
}

fn mode(path: &Path) -> u32 {
    fs::symlink_metadata(path).unwrap().mode() & 0o777
}

#[test]
fn put_makes_a_private_folder_and_file_and_read_gives_them_back() {
    let home = Home::new();
    let root = home.root();
    let path = put(&root, FOLDER, "diagram.png", PNG).unwrap();
    assert_eq!(path, root.join(FOLDER).join("diagram.png"));
    assert_eq!((mode(&root), mode(&root.join(FOLDER)), mode(&path)), (0o700, 0o700, 0o600));
    assert_eq!(read(&root, FOLDER, "diagram.png", attachment::LIMIT).unwrap(), (PNG.len() as u64, PNG.to_vec()));
    // A send reads only the head.
    assert_eq!(read(&root, FOLDER, "diagram.png", 4).unwrap(), (PNG.len() as u64, PNG[..4].to_vec()));
}

#[test]
fn put_never_reuses_a_folder_or_writes_through_a_symlink() {
    let home = Home::new();
    let root = home.root();
    put(&root, FOLDER, "a.txt", b"one").unwrap();
    let again = put(&root, FOLDER, "b.txt", b"two").unwrap_err();
    assert_eq!(again.kind(), io::ErrorKind::AlreadyExists);
    assert!(!root.join(FOLDER).join("b.txt").exists());
    // A folder name that is a symlink to elsewhere: refused, nothing written there.
    let elsewhere = home.0.join("elsewhere");
    fs::create_dir(&elsewhere).unwrap();
    let other = "ffeeddccbbaa99887766554433221100";
    std::os::unix::fs::symlink(&elsewhere, root.join(other)).unwrap();
    assert!(put(&root, other, "c.txt", b"three").is_err());
    assert_eq!(fs::read_dir(&elsewhere).unwrap().count(), 0);
}

#[test]
fn a_root_that_is_a_symlink_or_shared_is_refused() {
    let home = Home::new();
    let real = home.0.join("real");
    fs::create_dir(&real).unwrap();
    fs::set_permissions(&real, fs::Permissions::from_mode(0o700)).unwrap();
    std::os::unix::fs::symlink(&real, home.root()).unwrap();
    assert!(put(&home.root(), FOLDER, "a.txt", b"x").is_err());
    assert_eq!(fs::read_dir(&real).unwrap().count(), 0);
    let shared = Home::new();
    fs::create_dir(shared.root()).unwrap();
    fs::set_permissions(shared.root(), fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(put(&shared.root(), FOLDER, "a.txt", b"x").unwrap_err().kind(), io::ErrorKind::PermissionDenied);
}

#[test]
fn read_refuses_links_other_shapes_and_oversized_files() {
    let home = Home::new();
    let root = home.root();
    put(&root, FOLDER, "real.txt", b"secret").unwrap();
    // A symlink placed where an attachment would be (to a file the account owns).
    std::os::unix::fs::symlink(root.join(FOLDER).join("real.txt"), root.join(FOLDER).join("link.txt")).unwrap();
    assert!(read(&root, FOLDER, "link.txt", 64).is_err());
    // A hard link to another file is not a private copy either.
    fs::hard_link(root.join(FOLDER).join("real.txt"), root.join(FOLDER).join("hard.txt")).unwrap();
    assert_eq!(read(&root, FOLDER, "hard.txt", 64).unwrap_err().kind(), io::ErrorKind::PermissionDenied);
    for (folder, name) in [(FOLDER, "../x"), (FOLDER, ".hidden"), ("../attachments", "real.txt"), ("ABC", "real.txt"), (FOLDER, "a/b")] {
        assert_eq!(read(&root, folder, name, 64).unwrap_err().kind(), io::ErrorKind::InvalidInput, "{folder}/{name}");
    }
    assert_eq!(read(&root, FOLDER, "gone.txt", 64).unwrap_err().kind(), io::ErrorKind::NotFound);
    // Larger than an attachment can be (made by something else): refused.
    let big = fs::File::create(root.join(FOLDER).join("big.bin")).unwrap();
    big.set_len(attachment::LIMIT + 1).unwrap();
    fs::set_permissions(root.join(FOLDER).join("big.bin"), fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(read(&root, FOLDER, "big.bin", 64).unwrap_err().kind(), io::ErrorKind::InvalidData);
}

#[test]
fn put_refuses_empty_and_oversized_data() {
    let home = Home::new();
    assert!(put(&home.root(), FOLDER, "a.txt", b"").is_err());
    let big = vec![0; attachment::LIMIT as usize + 1];
    assert!(put(&home.root(), FOLDER, "a.txt", &big).is_err());
    assert!(!home.root().join(FOLDER).exists());
}

#[test]
fn the_clock_is_unix_milliseconds() {
    let answer = native("attachment.clock", &crate::wire::body::encode_plain(&Data::Object(Vec::new())).unwrap()).unwrap();
    let ms = crate::wire::body::decode_plain(&answer).unwrap().get("ms").and_then(Data::signed).unwrap();
    // After 2026-01-01, before 2100.
    assert!((1_767_225_600_000..4_102_444_800_000).contains(&ms), "{ms}");
}
