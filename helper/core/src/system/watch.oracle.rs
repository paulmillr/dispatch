//! Unchanged helper2 native watch producers; Reactor import points to the port.
#[cfg(target_os = "linux")]
pub(crate) mod watch {
    use crate::system::reactor::{Reactor, Ready};
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

        pub fn add(&mut self, path: &Path, directory: bool, _old: Option<i32>) -> io::Result<i32> {
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
            Ok(id)
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

        pub fn descriptors(&self) -> usize {
            1
        }
    }
}

#[cfg(target_os = "macos")]
pub(crate) mod watch {
    use crate::system::reactor::{Reactor, Ready};
    use std::{
        collections::BTreeMap,
        io,
        path::{Path, PathBuf},
    };
    use std::{
        fs::{File, OpenOptions},
        os::{
            fd::{AsRawFd, OwnedFd},
            unix::fs::{MetadataExt, OpenOptionsExt},
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

        pub fn add(&mut self, path: &Path, directory: bool, old: Option<i32>) -> io::Result<i32> {
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(0x8000)
                .open(path)?; // O_EVTONLY.
            let metadata = file.metadata()?;
            if directory && !metadata.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::NotADirectory,
                    "expected watch directory",
                ));
            }
            if let Some(fd) = old.filter(|fd| self.files.contains_key(fd)) {
                let previous = self.files[&fd].metadata()?;
                if (metadata.dev(), metadata.ino()) == (previous.dev(), previous.ino()) {
                    return Ok(fd);
                }
            }
            let fd = file.as_raw_fd();
            Reactor::watch(self.queue.as_raw_fd(), fd, true)?;
            self.files.insert(fd, file);
            Ok(fd)
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

        pub fn descriptors(&self) -> usize {
            self.files.len()
        }
    }
}
