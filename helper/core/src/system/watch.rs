//! Shared native file invalidation. Path operations belong on disk workers.
use super::reactor::{Reactor, Ready};
use std::{
    collections::BTreeMap,
    io,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
};

#[derive(Debug, PartialEq, Eq)]
pub struct Change {
    pub token: u64,
    pub reset: bool,
}

struct Target {
    path: PathBuf,
    parent: PathBuf,
    directory: bool,
}

pub struct Watcher {
    native: platform::Native,
    targets: BTreeMap<u64, Target>,
    sources: BTreeMap<PathBuf, i32>,
    capacity: usize,
}

impl Watcher {
    pub fn new(reactor: &Reactor, capacity: usize) -> io::Result<Self> {
        Ok(Self {
            native: platform::Native::new(reactor)?,
            targets: BTreeMap::new(),
            sources: BTreeMap::new(),
            capacity,
        })
    }

    /// Arm `path`. True when a missing folder level appeared while arming: its creation
    /// could not be reported, so the caller reports a reset for it.
    pub fn set(&mut self, token: u64, path: &Path, directory: bool) -> io::Result<bool> {
        let mut appeared = false;
        loop {
            let parent = self.arm(token, path, directory)?;
            // `mkdir -p` may create the next level between finding the nearest existing folder
            // and arming it; everything after happens a level deeper and is never reported
            // (claude run 138b). If that level exists now, arm again, deeper.
            let next = path
                .parent()
                .and_then(|folder| folder.ancestors().find(|a| a.parent() == Some(&parent)));
            if !next.is_some_and(|next| next.exists()) {
                return Ok(appeared);
            }
            appeared = true;
        }
    }

    /// One arm: the nearest existing folder of `path`, then `path` itself when it exists.
    fn arm(&mut self, token: u64, path: &Path, directory: bool) -> io::Result<PathBuf> {
        if !path.is_absolute() || path.parent().is_none() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "expected absolute file path",
            ));
        }
        if !self.targets.contains_key(&token) && self.targets.len() == self.capacity {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "watch capacity exceeded",
            ));
        }
        let result = (|| {
            let mut parent = path.parent().unwrap();
            let registration = loop {
                match self
                    .native
                    .add(parent, true, self.sources.get(parent).copied())
                {
                    Ok(Some(id)) => break id,
                    Ok(None) => return Err(io::ErrorKind::NotADirectory.into()),
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {
                        parent = parent.parent().ok_or(error)?;
                    }
                    Err(error) => return Err(error),
                }
            };
            // The ancestor watch precedes the file open, including when the file is absent.
            let file = match self
                .native
                .add(path, directory, self.sources.get(path).copied())
            {
                Ok(id) => id,
                Err(error) if error.kind() == io::ErrorKind::NotFound => None,
                Err(error) => return Err(error),
            };
            self.sources.insert(parent.to_owned(), registration);
            if let Some(id) = file {
                self.sources.insert(path.to_owned(), id);
            } else {
                self.sources.remove(path);
            }
            self.targets.insert(
                token,
                Target {
                    path: path.to_owned(),
                    parent: parent.to_owned(),
                    directory,
                },
            );
            Ok(parent.to_owned())
        })();
        self.prune()?;
        result
    }

    pub fn remove(&mut self, token: u64) -> io::Result<()> {
        self.targets.remove(&token);
        self.prune()
    }

    /// Re-arm after a change; true when a folder level appeared while arming.
    pub fn refresh(&mut self, token: u64) -> io::Result<bool> {
        match self.targets.get(&token) {
            Some(target) => self.set(token, &target.path.clone(), target.directory),
            None => Ok(false),
        }
    }

    fn prune(&mut self) -> io::Result<()> {
        self.sources.retain(|path, _| {
            self.targets
                .values()
                .any(|target| path == &target.path || path == &target.parent)
        });
        self.native.retain(&self.sources)
    }

    pub fn changed(&mut self, ready: Ready, mut emit: impl FnMut(Change)) -> io::Result<()> {
        let mut changed = BTreeMap::new();
        self.native.drain(ready, |id, name, reset, overflow| {
            for (&token, target) in &self.targets {
                let parent = self.sources.get(&target.parent) == Some(&id);
                let file = self.sources.get(&target.path) == Some(&id);
                let child = name.is_empty()
                    || target
                        .path
                        .strip_prefix(&target.parent)
                        .ok()
                        .and_then(|path| path.components().next())
                        .is_some_and(|part| part.as_os_str().as_bytes() == name);
                if overflow || file || (parent && child) {
                    *changed.entry(token).or_insert(false) |= overflow || reset || parent;
                }
            }
        })?;
        for (token, reset) in changed {
            emit(Change { token, reset });
        }
        Ok(())
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::{Reactor, Ready};
    use std::{
        collections::BTreeMap,
        io,
        path::{Path, PathBuf},
    };
    use std::{
        collections::BTreeSet,
        ffi::CString,
        fs::File,
        io::Read,
        os::{
            fd::{AsRawFd, FromRawFd, OwnedFd},
            unix::ffi::OsStrExt,
        },
        sync::Arc,
    };

    unsafe extern "C" {
        fn inotify_init1(flags: i32) -> i32;
        fn inotify_add_watch(fd: i32, path: *const std::ffi::c_char, mask: u32) -> i32;
        fn inotify_rm_watch(fd: i32, watch: i32) -> i32;
    }

    pub struct Native {
        file: File,
        queue: Arc<OwnedFd>,
        ids: BTreeSet<i32>,
    }

    impl Native {
        pub fn new(reactor: &Reactor) -> io::Result<Self> {
            // SAFETY: IN_NONBLOCK | IN_CLOEXEC are valid flags; no pointers cross this call.
            let fd = unsafe { inotify_init1(0x800 | 0x80000) };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: inotify_init1 returned a new, uniquely owned descriptor.
            let file = unsafe { File::from_raw_fd(fd) };
            let queue = reactor.handle();
            Reactor::watch(queue.as_raw_fd(), fd, true)?;
            Ok(Self {
                file,
                queue,
                ids: BTreeSet::new(),
            })
        }

        pub fn add(
            &mut self,
            path: &Path,
            directory: bool,
            _old: Option<i32>,
        ) -> io::Result<Option<i32>> {
            let path = CString::new(path.as_os_str().as_bytes())?;
            // Parent watches need namespace changes, not every child's writes.
            let mask = if directory {
                0x0100_0000 | 0x0fc4
            } else {
                0x0c0e
            };
            // SAFETY: path is NUL-terminated and live for the synchronous call.
            let id = unsafe { inotify_add_watch(self.file.as_raw_fd(), path.as_ptr(), mask) };
            if id < 0 {
                return Err(io::Error::last_os_error());
            }
            self.ids.insert(id);
            Ok(Some(id))
        }

        pub fn retain(&mut self, sources: &BTreeMap<PathBuf, i32>) -> io::Result<()> {
            let mut result = Ok(());
            self.ids.retain(|id| {
                if sources.values().any(|source| source == id) {
                    return true;
                }
                // SAFETY: the descriptor and watch ID belong to this inotify instance.
                if unsafe { inotify_rm_watch(self.file.as_raw_fd(), *id) } < 0 {
                    let error = io::Error::last_os_error();
                    // EINVAL means the kernel already removed a deleted/unmounted watch.
                    if error.raw_os_error() != Some(22) {
                        result = Err(error);
                    }
                }
                false
            });
            result
        }

        pub fn drain(
            &mut self,
            ready: Ready,
            mut emit: impl FnMut(i32, &[u8], bool, bool),
        ) -> io::Result<()> {
            if ready.fd != self.file.as_raw_fd() {
                return Ok(());
            }
            // One bounded batch; rearming preserves further readiness without a busy loop.
            let mut bytes = [0u8; 64 * 1024];
            let count = loop {
                match self.file.read(&mut bytes) {
                    Ok(count) => break count,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break 0,
                    Err(error) => return Err(error),
                }
            };
            Reactor::watch(self.queue.as_raw_fd(), self.file.as_raw_fd(), false)?;
            let mut offset = 0;
            while offset + 16 <= count {
                let id = i32::from_ne_bytes(bytes[offset..offset + 4].try_into().unwrap());
                let mask = u32::from_ne_bytes(bytes[offset + 4..offset + 8].try_into().unwrap());
                let length = u32::from_ne_bytes(bytes[offset + 12..offset + 16].try_into().unwrap())
                    as usize;
                let end = offset + 16 + length;
                if end > count {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "partial inotify event",
                    ));
                }
                let name = &bytes[offset + 16..end];
                let name = &name[..name
                    .iter()
                    .position(|byte| *byte == 0)
                    .unwrap_or(name.len())];
                emit(id, name, mask & (0x0fc0 | 0x8000) != 0, mask & 0x4000 != 0);
                offset = end;
            }
            Ok(())
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::{Reactor, Ready};
    use std::{
        collections::BTreeMap,
        io,
        path::{Path, PathBuf},
    };
    use std::{
        fs::{File, OpenOptions},
        os::{
            fd::{AsRawFd, OwnedFd},
            unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt},
        },
        sync::Arc,
    };

    pub struct Native {
        queue: Arc<OwnedFd>,
        files: BTreeMap<i32, File>,
    }

    impl Native {
        pub fn new(reactor: &Reactor) -> io::Result<Self> {
            Ok(Self {
                queue: reactor.handle(),
                files: BTreeMap::new(),
            })
        }

        pub fn add(
            &mut self,
            path: &Path,
            directory: bool,
            old: Option<i32>,
        ) -> io::Result<Option<i32>> {
            let file = match OpenOptions::new()
                .read(true)
                .custom_flags(0x8000)
                .open(path)
            {
                Ok(file) => file,
                Err(error) if error.raw_os_error() == Some(102) => {
                    // Darwin cannot open a socket inode with O_EVTONLY. Its namespace
                    // changes are already covered by the preceding ancestor watch.
                    if !directory && std::fs::metadata(path)?.file_type().is_socket() {
                        return Ok(None);
                    }
                    return Err(error);
                }
                Err(error) => return Err(error),
            };
            let metadata = file.metadata()?;
            if directory && !metadata.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::NotADirectory,
                    "expected watch directory",
                ));
            }
            if metadata.file_type().is_socket() {
                return Ok(None);
            }
            if let Some(fd) = old.filter(|fd| self.files.contains_key(fd)) {
                let previous = self.files[&fd].metadata()?;
                if (metadata.dev(), metadata.ino()) == (previous.dev(), previous.ino()) {
                    return Ok(Some(fd));
                }
            }
            let fd = file.as_raw_fd();
            Reactor::watch(self.queue.as_raw_fd(), fd, true)?;
            self.files.insert(fd, file);
            Ok(Some(fd))
        }

        pub fn retain(&mut self, sources: &BTreeMap<PathBuf, i32>) -> io::Result<()> {
            // Closing the last descriptor removes its vnode filter from kqueue.
            self.files
                .retain(|fd, _| sources.values().any(|source| source == fd));
            Ok(())
        }

        pub fn drain(
            &mut self,
            ready: Ready,
            mut emit: impl FnMut(i32, &[u8], bool, bool),
        ) -> io::Result<()> {
            if ready.vnode && self.files.contains_key(&ready.fd) {
                emit(
                    ready.fd,
                    &[],
                    ready.closed || ready.changes & (1 | 0x20 | 0x40) != 0,
                    false,
                );
            }
            Ok(())
        }
    }
}
