//! Executed c1654cc Helpers/ssh-helper/src/process.rs files producers.
//! Only serde JSON construction is adapted to tuples; the syscall/filter bodies are unchanged.
use std::{fs, io, os::unix::fs::MetadataExt};
pub type Value = Vec<(String, u64, u64)>;
#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    macro_rules! json {
        ({"path": $path:expr, "inode": $inode:expr, "device": $device:expr}) => {
            (
                $path.to_string_lossy().into_owned(),
                $device as u64,
                $inode as u64,
            )
        };
        ($files:expr) => {
            $files
        };
    }
    pub fn files(pid: i32) -> io::Result<Value> {
        let mut files = Vec::new();
        for entry in fs::read_dir(format!("/proc/{pid}/fd"))?.take(131_072) {
            let Ok(entry) = entry else { continue };
            let Ok(metadata) = fs::metadata(entry.path()) else {
                continue;
            };
            let Ok(path) = fs::read_link(entry.path()) else {
                continue;
            };
            if !metadata.is_file() || path.extension().and_then(|p| p.to_str()) != Some("jsonl") {
                continue;
            }
            if files.len() >= 128 {
                break;
            }
            files.push(json!({"path": path, "inode": metadata.ino(), "device": metadata.dev()}));
        }
        Ok(json!(files))
    }
}
#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use std::{
        ffi::CStr,
        mem::{size_of, size_of_val},
    };
    fn changed() -> io::Error {
        io::ErrorKind::PermissionDenied.into()
    }
    macro_rules! json {
        ({"path": $path:expr, "inode": $inode:expr, "device": $device:expr}) => {
            ($path.into_owned(), $device as u64, $inode as u64)
        };
        ($files:expr) => {
            $files
        };
    }
    mod libc {
        #![allow(non_camel_case_types)]
        pub const S_IFMT: u16 = 0xf000;
        pub const S_IFREG: u16 = 0x8000;
        #[repr(C)]
        pub struct proc_fdinfo {
            pub proc_fd: i32,
            pub proc_fdtype: u32,
        }
        #[repr(C)]
        pub struct vinfo_stat {
            pub vst_dev: u32,
            pub vst_mode: u16,
            pub vst_nlink: u16,
            pub vst_ino: u64,
            pub vst_uid: u32,
            pub vst_gid: u32,
            pub vst_atime: i64,
            pub vst_atimensec: i64,
            pub vst_mtime: i64,
            pub vst_mtimensec: i64,
            pub vst_ctime: i64,
            pub vst_ctimensec: i64,
            pub vst_birthtime: i64,
            pub vst_birthtimensec: i64,
            pub vst_size: i64,
            pub vst_blocks: i64,
            pub vst_blksize: i32,
            pub vst_flags: u32,
            pub vst_gen: u32,
            pub vst_rdev: u32,
            pub vst_qspare: [i64; 2],
        }
        #[repr(C)]
        pub struct vnode_info {
            pub vi_stat: vinfo_stat,
            pub vi_type: i32,
            pub vi_pad: i32,
            pub vi_fsid: [i32; 2],
        }
        #[repr(C)]
        pub struct vnode_info_path {
            pub vip_vi: vnode_info,
            pub vip_path: [[std::ffi::c_char; 32]; 32],
        }
        unsafe extern "C" {
            pub fn proc_pidinfo(
                pid: i32,
                flavor: i32,
                arg: u64,
                buffer: *mut std::ffi::c_void,
                size: i32,
            ) -> i32;
            pub fn proc_pidfdinfo(
                pid: i32,
                fd: i32,
                flavor: i32,
                buffer: *mut std::ffi::c_void,
                size: i32,
            ) -> i32;
        }
    }
    #[repr(C)]
    struct FileInfo {
        flags: u32,
        status: u32,
        offset: i64,
        kind: i32,
        guard: u32,
    }
    #[repr(C)]
    struct VnodePath {
        file: FileInfo,
        vnode: libc::vnode_info_path,
    }
    pub fn files(pid: i32) -> io::Result<Value> {
        // SAFETY: zero is valid storage for an array of integer proc_fdinfo.
        let mut descriptors: Vec<libc::proc_fdinfo> = (0..131_072)
            .map(|_| unsafe { std::mem::zeroed() })
            .collect();
        // SAFETY: writable descriptors allocation with its exact byte capacity.
        let count = unsafe {
            libc::proc_pidinfo(
                pid,
                1,
                0,
                descriptors.as_mut_ptr().cast(),
                (descriptors.len() * size_of::<libc::proc_fdinfo>()) as i32,
            )
        };
        if count < 0 || count as usize >= descriptors.len() * size_of::<libc::proc_fdinfo>() {
            return Err(changed());
        }
        let mut files = Vec::new();
        for fd in &descriptors[..count as usize / size_of::<libc::proc_fdinfo>()] {
            if fd.proc_fdtype != 1 {
                continue;
            }
            // SAFETY: FileInfo and libc vnode_info_path are integer/array-only.
            let mut info: VnodePath = unsafe { std::mem::zeroed() };
            // SAFETY: PROC_PIDFDVNODEPATHINFO is 2; output matches proc_info.h.
            if unsafe {
                libc::proc_pidfdinfo(
                    pid,
                    fd.proc_fd,
                    2,
                    (&mut info as *mut VnodePath).cast(),
                    size_of_val(&info) as i32,
                )
            } != size_of_val(&info) as i32
            {
                continue;
            }
            let stat = &info.vnode.vip_vi.vi_stat;
            if stat.vst_mode & libc::S_IFMT != libc::S_IFREG {
                continue;
            }
            let bytes = info.vnode.vip_path.as_flattened();
            if !bytes.contains(&0) {
                continue;
            }
            // SAFETY: the fixed path array contains a checked terminating NUL.
            let path = unsafe { CStr::from_ptr(bytes.as_ptr()) }.to_string_lossy();
            if !path.ends_with(".jsonl") {
                continue;
            }
            if files.len() >= 128 {
                break;
            }
            files.push(json!({"path": path, "inode": stat.vst_ino, "device": stat.vst_dev}));
        }
        Ok(json!(files))
    }
}
pub use platform::files;

/// c1654cc process.rs:980-986/1554-1578 plus the caller's optional UTF8 projection.
pub fn cwd(pid: u32) -> Option<String> {
    #[cfg(target_os = "linux")]
    let path = std::fs::read_link(format!("/proc/{pid}/cwd")).ok()?;
    #[cfg(target_os = "macos")]
    let path = {
        use std::{ffi::c_void, mem::size_of_val, os::unix::ffi::OsStringExt};
        #[repr(C)]
        struct Stat {
            dev: u32,
            mode: u16,
            links: u16,
            ino: u64,
            uid: u32,
            gid: u32,
            atime: i64,
            atimens: i64,
            mtime: i64,
            mtimens: i64,
            ctime: i64,
            ctimens: i64,
            birth: i64,
            birthns: i64,
            size: i64,
            blocks: i64,
            blksize: i32,
            flags: u32,
            generation: u32,
            rdev: u32,
            spare: [i64; 2],
        }
        #[repr(C)]
        struct Vnode {
            stat: Stat,
            kind: i32,
            pad: i32,
            fsid: [i32; 2],
        }
        #[repr(C)]
        struct Path {
            vnode: Vnode,
            path: [u8; 1024],
        }
        #[repr(C)]
        struct Directory {
            cwd: Path,
            root: Path,
        }
        unsafe extern "C" {
            fn proc_pidinfo(pid: i32, flavor: i32, arg: u64, buffer: *mut c_void, size: i32)
            -> i32;
        }
        let mut info: Directory = unsafe { std::mem::zeroed() };
        if unsafe {
            proc_pidinfo(
                pid as i32,
                9,
                0,
                (&mut info as *mut Directory).cast(),
                size_of_val(&info) as i32,
            )
        } != size_of_val(&info) as i32
        {
            return None;
        }
        let end = info.cwd.path.iter().position(|b| *b == 0)?;
        std::path::PathBuf::from(std::ffi::OsString::from_vec(info.cwd.path[..end].to_vec()))
    };
    path.is_absolute()
        .then_some(path)?
        .to_str()
        .map(str::to_owned)
}
