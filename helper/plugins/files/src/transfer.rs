//! What write.rs, pack.rs and unpack.rs share: chained jobs, random names, path checks, and the codes for the
//! failures the transfer jobs make themselves.
use super::*;
use std::path::Component;

/// One long transfer job (a pack or a commit) per helper: the worker pool has two threads, and the other one is
/// left to everything else. Held from the request until the job's completion.
pub(super) type Gate = Rc<std::cell::Cell<bool>>;

/// Git reads may overlap each other, but no helper file publication may overlap their config scan and command.
/// This closes the scan/run race for clients of this helper: a clean config cannot be exchanged for one naming a
/// program until the Git process has ended.
#[derive(Default)]
pub(super) struct Access {
    readers: std::cell::Cell<u32>,
    writer: std::cell::Cell<bool>,
}

pub(super) type SharedAccess = Rc<Access>;

impl Access {
    pub(super) fn begin_read(&self) -> bool {
        if self.writer.get() {
            return false;
        }
        let Some(readers) = self.readers.get().checked_add(1) else { return false };
        self.readers.set(readers);
        true
    }

    pub(super) fn end_read(&self) {
        let readers = self.readers.get();
        debug_assert!(readers > 0);
        if readers > 0 {
            self.readers.set(readers - 1);
        }
    }

    pub(super) fn begin_write(&self) -> bool {
        if self.writer.get() || self.readers.get() != 0 {
            return false;
        }
        self.writer.set(true);
        true
    }

    pub(super) fn end_write(&self) {
        debug_assert!(self.writer.get());
        self.writer.set(false);
    }
}

#[cfg(test)]
mod tests {
    use super::Access;

    #[test]
    fn git_reads_share_access_but_publications_are_exclusive() {
        let access = Access::default();
        assert!(access.begin_read());
        assert!(access.begin_read());
        assert!(!access.begin_write());
        access.end_read();
        assert!(!access.begin_write());
        access.end_read();
        assert!(access.begin_write());
        assert!(!access.begin_read());
        assert!(!access.begin_write());
        access.end_write();
        assert!(access.begin_read());
        access.end_read();
    }
}

/// Run `job` on a worker and `then` with its result, which always comes later, never during this call.
pub(super) fn job(io: &mut dyn Io, job: Job, then: impl FnOnce(&mut dyn Io, io::Result<Output>) + 'static) {
    match io.submit(job) {
        Ok(work) => io.then(work, Box::new(then)),
        Err(value) => io.defer(Box::new(move |io| then(io, Err(value)))),
    }
}

/// 16 bytes of the helper's recorded entropy as 32 hex digits: replay names the same files.
pub(super) fn random(io: &mut dyn Io) -> io::Result<String> {
    let mut bytes = [0u8; 16];
    io.random(&mut bytes)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// An absolute path as given, without `.`, `..` or empty components: what is written or extracted is exactly
/// what was named.
pub(super) fn plain(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let bytes = path.as_os_str().as_bytes();
    bytes == b"/"
        || (bytes.first() == Some(&b'/')
            && bytes[1..]
                .split(|&b| b == b'/')
                .all(|part| !matches!(part, b"" | b"." | b"..")))
}

/// `path` with `.` and `..` resolved lexically; None for a relative path.
pub(super) fn normal(path: &Path) -> Option<PathBuf> {
    if !path.is_absolute() {
        return None;
    }
    let mut result = PathBuf::from("/");
    for part in path.components() {
        match part {
            Component::RootDir | Component::CurDir => {}
            Component::ParentDir => {
                result.pop();
            }
            Component::Normal(name) => result.push(name),
            Component::Prefix(_) => return None,
        }
    }
    Some(result)
}

/// A transfer job's failure. The jobs' own refusals carry no OS number: a bound (`limit`), a refused request or
/// archive (`invalid_request`) and a file system that cannot rename without replacing (`unsupported`); the rest
/// are native errors.
pub(super) fn failure(value: io::Error) -> Error {
    let code = match (value.raw_os_error(), value.kind()) {
        (None, io::ErrorKind::QuotaExceeded) => "limit",
        (None, io::ErrorKind::InvalidData | io::ErrorKind::InvalidInput) => "invalid_request",
        (_, io::ErrorKind::AlreadyExists) => "exists",
        (_, io::ErrorKind::NotADirectory) => "not_directory",
        // A file system without no-replace renames (native.rs says which).
        (None, io::ErrorKind::Unsupported) => "unsupported",
        _ => return native(value),
    };
    Error {
        code,
        message: value.to_string(),
    }
}
