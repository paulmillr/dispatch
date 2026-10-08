//! Native bodies from unchanged c1654cc runtime/os/herdr_start; direct extern ABI adapter only.
use std::{
    ffi::CString,
    fs::File,
    io,
    os::{
        fd::{AsRawFd, FromRawFd, RawFd},
        unix::{fs::MetadataExt, net::UnixStream},
    },
    path::Path,
    time::{Duration, Instant},
};
mod libc {
    use std::ffi::{c_char, c_int};
    pub const O_RDWR: i32 = 2;
    pub const LOCK_EX: i32 = 2;
    pub const LOCK_NB: i32 = 4;
    #[cfg(target_os = "linux")]
    pub const O_CREAT: i32 = 0x40;
    #[cfg(target_os = "macos")]
    pub const O_CREAT: i32 = 0x200;
    #[cfg(target_os = "linux")]
    pub const O_NOFOLLOW: i32 = 0x20000;
    #[cfg(target_os = "macos")]
    pub const O_NOFOLLOW: i32 = 0x100;
    #[cfg(target_os = "linux")]
    pub const O_CLOEXEC: i32 = 0x80000;
    #[cfg(target_os = "macos")]
    pub const O_CLOEXEC: i32 = 0x1000000;
    #[cfg(target_os = "linux")]
    pub const O_NONBLOCK: i32 = 0x800;
    #[cfg(target_os = "macos")]
    pub const O_NONBLOCK: i32 = 4;
    unsafe extern "C" {
        pub fn openat(fd: c_int, path: *const c_char, flags: c_int, ...) -> c_int;
        pub fn flock(fd: c_int, flags: c_int) -> c_int;
        pub fn getuid() -> u32;
        pub fn shutdown(fd: c_int, how: c_int) -> c_int;
    }
}
mod os {
    use super::*;
    pub fn uid() -> u32 {
        // SAFETY: getuid has no preconditions.
        unsafe { libc::getuid() }
    }
    pub(crate) fn try_exclusive_lock(fd: RawFd) -> io::Result<()> {
        // SAFETY: flock validates the borrowed descriptor; the nonblocking lock is
        // released by closing its owned file description, including on worker death.
        if unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}
fn component(name: &str) -> io::Result<CString> {
    if name.is_empty() || name == "." || name == ".." || name.contains('/') {
        return Err(io::Error::other("Invalid runtime component"));
    }
    CString::new(name).map_err(|_| io::Error::other("Invalid runtime component"))
}
struct Directory(File);
impl Directory {
    pub(crate) fn lock_file(&self, name: &str) -> io::Result<File> {
        let name = component(name)?;
        // SAFETY: borrowed directory and one terminated component; the returned
        // descriptor is exclusively owned, with no symlink following or inheritance.
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDWR
                    | libc::O_CREAT
                    | libc::O_NOFOLLOW
                    | libc::O_CLOEXEC
                    | libc::O_NONBLOCK,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: successful openat returned one new owned descriptor.
        let file = unsafe { File::from_raw_fd(fd) };
        let metadata = file.metadata()?;
        if !metadata.is_file()
            || metadata.uid() != os::uid()
            || metadata.mode() & 0o077 != 0
            || metadata.nlink() != 1
            || metadata.len() != 0
        {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        Ok(file)
    }
}
pub fn advisory(path: &Path, deadline: Instant) -> io::Result<File> {
    let directory = Directory(File::open(
        path.parent().ok_or(io::ErrorKind::InvalidInput)?,
    )?);
    let lock = directory.lock_file(
        path.file_name()
            .and_then(|v| v.to_str())
            .ok_or(io::ErrorKind::InvalidInput)?,
    )?;
    loop {
        if Instant::now() >= deadline {
            return Err(io::ErrorKind::TimedOut.into());
        }
        match os::try_exclusive_lock(lock.as_raw_fd()) {
            Ok(()) => break,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) =>
            {
                std::thread::sleep(Duration::from_millis(20))
            }
            Err(error) => return Err(error),
        }
    }
    Ok(lock)
}
pub fn shutdown(stream: &UnixStream) -> io::Result<()> {
    // helper2 system.rs:1615-1622, Write branch; owned UnixStream is the test adapter.
    if unsafe { libc::shutdown(stream.as_raw_fd(), 1) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

// helper2 runtime.rs:107-149 native endpoint operations, absolute-path test adapter.
pub fn route(
    root: &Path,
    id: u64,
) -> io::Result<(
    std::os::unix::net::UnixDatagram,
    std::os::unix::net::UnixListener,
)> {
    use std::os::unix::{
        fs::PermissionsExt,
        net::{UnixDatagram, UnixListener},
    };
    let datagram = root.join(format!("{id}.d"));
    let stream = root.join(format!("{id}.s"));
    let socket = UnixDatagram::bind(&datagram)?;
    std::fs::set_permissions(&datagram, std::fs::Permissions::from_mode(0o600))?;
    socket.set_nonblocking(true)?;
    let listener = UnixListener::bind(&stream)?;
    std::fs::set_permissions(&stream, std::fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    Ok((socket, listener))
}
