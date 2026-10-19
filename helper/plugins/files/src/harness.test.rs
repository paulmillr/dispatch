//! Runs plugin calls the way the helper's reactor does, on a real System: the call, then each
//! event from System::next to `event`, deferred callbacks run between them.
use super::*;
use dispatch_helper_core::{
    api::{Ui, Update},
    system::System,
};
use std::time::Duration;

struct Quiet;
impl Ui for Quiet {
    fn update(&mut self, _: Update) {}
}

pub(crate) fn system() -> System {
    System::new(2, 64).expect("system")
}

/// One call's completion. Fails the test after 30 s without one rather than hanging.
pub(crate) fn drive<T: 'static>(
    system: &mut System,
    files: &mut Files,
    call: impl FnOnce(&mut Files, &mut dyn Io, Done<T>),
) -> Result<T, Error> {
    let slot = Rc::new(RefCell::new(None));
    let out = slot.clone();
    call(
        files,
        system,
        Box::new(move |_, result| *out.borrow_mut() = Some(result)),
    );
    // System's clock and timer, so a replayed run asks what its capture asked.
    let give_up = system.now() + Duration::from_secs(30);
    system.timer(give_up);
    loop {
        system.callbacks();
        if let Some(result) = slot.borrow_mut().take() {
            return result;
        }
        match system.next().expect("next event") {
            (_, Event::Timer { at }) if at == give_up => panic!("no completion in 30 s"),
            (_, event) => files.event(system, &mut Quiet, event),
        }
    }
}

pub(crate) fn list(
    files: &mut Files,
    path: &Path,
    hidden: bool,
    limit: u64,
) -> Result<Listing, Error> {
    let path = path.to_path_buf();
    drive(&mut system(), files, move |files, io, done| {
        files.list(io, &path, hidden, limit, false, done)
    })
}

pub(crate) fn summary(files: &mut Files, path: &Path, limit: u64) -> Result<FolderSummary, Error> {
    let path = path.to_path_buf();
    drive(&mut system(), files, move |files, io, done| {
        files.summary(io, &path, limit, done)
    })
}

/// The SSH (checked) and the local plugin: listings take one path in both.
pub(crate) fn both() -> [Files; 2] {
    [Files::new(true), Files::new(false)]
}

/// A scratch directory under the test temp root, removed (after unlocking what a test
/// locked) when the test ends, passed or not.
pub(crate) struct Tree {
    pub root: PathBuf,
    locked: Vec<PathBuf>,
}

impl Tree {
    pub fn new(name: &str) -> Self {
        Self::under(&std::env::temp_dir(), name)
    }
    pub fn under(parent: &Path, name: &str) -> Self {
        let root = parent.join(format!("files-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        Self {
            root,
            locked: Vec::new(),
        }
    }
    pub fn file(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.root.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, bytes).unwrap();
        path
    }
    pub fn link(&self, name: &str, target: &str) {
        std::os::unix::fs::symlink(target, self.root.join(name)).unwrap();
    }
    /// `name` (a directory) without any permission; false when that does not stop this
    /// process reading it (root).
    pub fn lock(&mut self, name: &str) -> bool {
        use std::os::unix::fs::PermissionsExt;
        let path = self.root.join(name);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0)).unwrap();
        self.locked.push(path.clone());
        std::fs::read_dir(&path).is_err()
    }
}

impl Drop for Tree {
    fn drop(&mut self) {
        use std::os::unix::fs::PermissionsExt;
        for path in &self.locked {
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755));
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
