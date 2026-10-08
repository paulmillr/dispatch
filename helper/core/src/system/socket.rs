//! helper2 system.rs Socket::start/complete; System owns the returned file and capture.
use super::reactor;
use crate::api::Address;
use std::{
    fs::File,
    io,
    net::SocketAddr,
    os::{fd::FromRawFd, unix::ffi::OsStrExt},
};

unsafe extern "C" {
    fn socket(domain: i32, kind: i32, protocol: i32) -> i32;
    fn connect(fd: i32, address: *const u8, length: u32) -> i32;
    fn fcntl(fd: i32, command: i32, ...) -> i32;
    fn getpeername(fd: i32, address: *mut u8, length: *mut u32) -> i32;
}

pub(super) fn start(endpoint: &Address) -> io::Result<File> {
    let mut address = [0; 128];
    let (family, length) = match endpoint {
        Address::Unix(path) => {
            let bytes = path.as_os_str().as_bytes();
            #[cfg(target_os = "linux")]
            const SIZE: usize = 108;
            #[cfg(target_os = "macos")]
            const SIZE: usize = 104;
            if bytes.is_empty() || bytes.len() >= SIZE || bytes.contains(&0) {
                return Err(io::ErrorKind::InvalidInput.into());
            }
            address[2..2 + bytes.len()].copy_from_slice(bytes);
            (1, bytes.len() + 3)
        }
        Address::Tcp(SocketAddr::V4(endpoint)) => {
            address[2..4].copy_from_slice(&endpoint.port().to_be_bytes());
            address[4..8].copy_from_slice(&endpoint.ip().octets());
            (2, 16)
        }
        Address::Tcp(SocketAddr::V6(endpoint)) => {
            address[2..4].copy_from_slice(&endpoint.port().to_be_bytes());
            address[4..8].copy_from_slice(&endpoint.flowinfo().to_ne_bytes());
            address[8..24].copy_from_slice(&endpoint.ip().octets());
            address[24..28].copy_from_slice(&endpoint.scope_id().to_ne_bytes());
            #[cfg(target_os = "linux")]
            let family = 10;
            #[cfg(target_os = "macos")]
            let family = 30;
            (family, 28)
        }
    };
    #[cfg(target_os = "linux")]
    address[..2].copy_from_slice(&(family as u16).to_ne_bytes());
    #[cfg(target_os = "macos")]
    {
        address[0] = length as u8;
        address[1] = family as u8;
    }
    // SAFETY: family selects the complete encoded sockaddr; SOCK_STREAM returns a new fd.
    let fd = unsafe { socket(family, 1, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the new exclusively owned fd is closed by File on every subsequent error.
    let file = unsafe { File::from_raw_fd(fd) };
    // SAFETY: F_SETFD/FD_CLOEXEC changes only this new owned descriptor.
    if unsafe { fcntl(fd, 2, 1) } < 0 {
        return Err(io::Error::last_os_error());
    }
    reactor::nonblocking(fd)?;
    // SAFETY: the complete sockaddr remains live for the native nonblocking call.
    if unsafe { connect(fd, address.as_ptr(), length as u32) } != 0 {
        let error = io::Error::last_os_error();
        #[cfg(target_os = "linux")]
        const PROGRESS: i32 = 115;
        #[cfg(target_os = "macos")]
        const PROGRESS: i32 = 36;
        if error.raw_os_error() != Some(PROGRESS) {
            return Err(error);
        }
    }
    Ok(file)
}

pub(super) fn complete(fd: i32) -> io::Result<()> {
    let mut error = 0i32;
    let mut length = std::mem::size_of_val(&error) as u32;
    #[cfg(target_os = "linux")]
    const OPTION: (i32, i32) = (1, 4);
    #[cfg(target_os = "macos")]
    const OPTION: (i32, i32) = (0xffff, 0x1007);
    // SAFETY: SO_ERROR writes one live native i32 and updates its live socklen_t.
    if unsafe {
        super::native::getsockopt(
            fd,
            OPTION.0,
            OPTION.1,
            (&mut error as *mut i32).cast(),
            &mut length,
        )
    } < 0
    {
        return Err(io::Error::last_os_error());
    }
    if error != 0 {
        return Err(io::Error::from_raw_os_error(error));
    }
    let mut address = [0; 128];
    let mut length = address.len() as u32;
    // SAFETY: sockaddr_storage-sized output remains live; success proves establishment.
    if unsafe { getpeername(fd, address.as_mut_ptr(), &mut length) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

// A listener owns the inode it bound, never a replacement at the same path.
pub(super) struct Listener {
    pub(super) listener: std::os::unix::net::UnixListener,
    path: std::path::PathBuf,
    identity: (u64, u64),
}
impl Listener {
    pub(super) fn new(
        listener: std::os::unix::net::UnixListener,
        path: &std::path::Path,
    ) -> std::io::Result<Self> {
        use std::os::unix::fs::MetadataExt;
        let metadata = std::fs::symlink_metadata(path)?;
        Ok(Self {
            listener,
            path: path.to_owned(),
            identity: (metadata.dev(), metadata.ino()),
        })
    }
}
impl Drop for Listener {
    fn drop(&mut self) {
        use std::os::unix::fs::MetadataExt;
        if std::fs::symlink_metadata(&self.path)
            .is_ok_and(|metadata| (metadata.dev(), metadata.ino()) == self.identity)
        {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}
