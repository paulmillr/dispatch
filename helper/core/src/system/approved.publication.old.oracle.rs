//! Unchanged helper2 component/publish bodies; standalone native oracle adapter.
use std::{ffi::CString, fs::File, io, os::fd::AsRawFd};
pub(crate) struct Directory {
    file: File,
}
unsafe extern "C" {
    fn unlinkat(fd: i32, path: *const std::ffi::c_char, flags: i32) -> i32;
    fn renameat(
        first: i32,
        source: *const std::ffi::c_char,
        second: i32,
        target: *const std::ffi::c_char,
    ) -> i32;
    #[cfg(target_os = "linux")]
    fn syscall(number: std::ffi::c_long, ...) -> std::ffi::c_long;
    #[cfg(target_os = "macos")]
    fn renameatx_np(
        first: i32,
        source: *const std::ffi::c_char,
        second: i32,
        target: *const std::ffi::c_char,
        flags: u32,
    ) -> i32;
}
fn component(name: &str) -> io::Result<CString> {
    if name.is_empty() || name == "." || name == ".." || name.contains('/') {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    CString::new(name).map_err(|_| io::ErrorKind::InvalidInput.into())
}

impl Directory {
    pub(crate) fn remove(&self, name: &str, directory: bool) -> io::Result<()> {
        let value = component(name)?;
        // SAFETY: unlinkat removes one component without following a child symlink.
        if unsafe {
            unlinkat(
                self.file.as_raw_fd(),
                value.as_ptr(),
                if directory {
                    if cfg!(target_os = "macos") {
                        0x80
                    } else {
                        0x200
                    }
                } else {
                    0
                },
            )
        } != 0
        {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::NotFound {
                return Err(error);
            }
        }
        Ok(())
    }

    pub(crate) fn publish(&self, source: &str, target: &str, replace: bool) -> io::Result<()> {
        let source = component(source)?;
        let target = component(target)?;
        let fd = self.file.as_raw_fd();
        let status = if replace {
            // SAFETY: owned directory and validated components; rename never follows the destination symlink.
            unsafe { renameat(fd, source.as_ptr(), fd, target.as_ptr()) as i64 }
        } else {
            #[cfg(target_os = "linux")]
            {
                // Linux UAPI: asm/unistd_64.h and asm-generic/unistd.h, RENAME_NOREPLACE=1.
                #[cfg(target_arch = "x86_64")]
                const NUMBER: std::ffi::c_long = 316;
                #[cfg(target_arch = "aarch64")]
                const NUMBER: std::ffi::c_long = 276;
                // SAFETY: native syscall ABI, borrowed fds, terminated component names and documented flag.
                unsafe { syscall(NUMBER, fd, source.as_ptr(), fd, target.as_ptr(), 1u32) as i64 }
            }
            #[cfg(target_os = "macos")]
            {
                // SAFETY: owned fd and terminated names; Darwin RENAME_EXCL=4 forbids replacement atomically.
                unsafe { renameatx_np(fd, source.as_ptr(), fd, target.as_ptr(), 4) as i64 }
            }
        };
        if status == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}
pub fn publish(
    root: &std::path::Path,
    source: &str,
    target: &str,
    replace: bool,
) -> io::Result<()> {
    Directory {
        file: File::open(root)?,
    }
    .publish(source, target, replace)
}

pub(crate) fn pin(root: &std::path::Path) -> io::Result<Directory> {
    Ok(Directory {
        file: File::open(root)?,
    })
}
