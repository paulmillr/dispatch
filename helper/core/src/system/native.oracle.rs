//! Unchanged helper2 passwd fallback; HOME adapter selects the native branch.
use std::{
    ffi::{CStr, OsString, c_char},
    io,
    os::unix::ffi::OsStringExt,
    path::PathBuf,
    ptr,
};
fn variable(_: &str) -> Option<OsString> {
    None
}
unsafe extern "C" {
    fn getuid() -> u32;
}
mod service {
    pub const LIMIT: usize = 1_048_576;
}
#[repr(C)]
struct Passwd {
    name: *mut c_char,
    password: *mut c_char,
    uid: u32,
    gid: u32,
    #[cfg(target_os = "macos")]
    change: i64,
    #[cfg(target_os = "macos")]
    class: *mut c_char,
    gecos: *mut c_char,
    directory: *mut c_char,
    shell: *mut c_char,
    #[cfg(target_os = "macos")]
    expire: i64,
}

unsafe extern "C" {
    fn getpwuid_r(
        uid: u32,
        entry: *mut Passwd,
        buffer: *mut c_char,
        size: usize,
        result: *mut *mut Passwd,
    ) -> i32;
}

pub fn home() -> io::Result<PathBuf> {
    if let Some(value) = variable("HOME") {
        let path = PathBuf::from(value);
        if path.is_absolute() {
            return Ok(path);
        }
    }
    let mut bytes = vec![0; 1024];
    loop {
        let mut entry = std::mem::MaybeUninit::<Passwd>::uninit();
        let mut result = ptr::null_mut();
        // SAFETY: entry and buffer have the native passwd layout/storage and remain
        // live for the call. getpwuid_r returns pointers into this caller-owned buffer.
        let error = unsafe {
            getpwuid_r(
                getuid(),
                entry.as_mut_ptr(),
                bytes.as_mut_ptr(),
                bytes.len(),
                &mut result,
            )
        };
        if error == 34 {
            // ERANGE on both supported platforms.
            let size = bytes
                .len()
                .checked_mul(2)
                .filter(|size| *size <= service::LIMIT)
                .ok_or_else(|| io::Error::from(io::ErrorKind::OutOfMemory))?;
            bytes.resize(size, 0);
            continue;
        }
        if error != 0 {
            return Err(io::Error::from_raw_os_error(error));
        }
        if result.is_null() {
            return Err(io::ErrorKind::NotFound.into());
        }
        // SAFETY: successful lookup with a nonnull result initializes entry.
        let directory = unsafe { entry.assume_init().directory };
        if directory.is_null() {
            return Err(io::ErrorKind::NotFound.into());
        }
        // SAFETY: getpwuid_r provides a NUL-terminated string valid until bytes drops.
        let directory = unsafe { CStr::from_ptr(directory) }.to_bytes();
        let path = PathBuf::from(OsString::from_vec(directory.to_vec()));
        return if path.is_absolute() {
            Ok(path)
        } else {
            Err(io::ErrorKind::InvalidData.into())
        };
    }
}
