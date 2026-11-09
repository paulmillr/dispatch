use super::*;
use std::{fs, os::unix::fs::PermissionsExt};

struct Folders(std::path::PathBuf);
impl Drop for Folders {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn program(directory: &Path, text: &str) {
    fs::create_dir_all(directory).unwrap();
    let path = directory.join("pi");
    fs::write(&path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn a_launch_steps_over_its_own_shim_only_when_one_is_in_the_way() {
    let root = std::env::temp_dir().join(format!("dispatch-launch-{}", std::process::id()));
    let _cleanup = Folders(root.clone());
    let (shims, real) = (root.join("shims"), root.join("real"));
    program(&shims, "#!/bin/sh\nexec '/helper' 'launch' 'pi' \"$@\"\n");
    program(&real, "#!/bin/sh\necho real\n");
    let image = fs::metadata(&root).unwrap();
    let path = |folders: &[&Path]| folders.iter().map(|f| f.display().to_string()).collect::<Vec<_>>().join(":");
    let mut typed = Command::new("pi");
    typed.arg("--version");

    let direct = resolved(typed, &path(&[&shims, &real]), &root, &image).unwrap();
    assert_eq!(direct.get_program(), real.join("pi"));
    assert_eq!(direct.get_args().collect::<Vec<_>>(), ["--version"]);

    let unchanged = resolved(Command::new("pi"), &path(&[&real, &shims]), &root, &image).unwrap();
    assert_eq!(unchanged.get_program(), "pi", "A real program first is left to PATH, as recorded launches are");

    let missing = resolved(Command::new("pi"), &path(&[&shims]), &root, &image).err().unwrap();
    assert_eq!(missing.kind(), io::ErrorKind::NotFound);
}
