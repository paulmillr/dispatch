//! Native layouts from c1654cc's pinned libc and the system headers, for 64-bit targets.
use super::{Disk, invalid};
use std::{
    ffi::{CStr, CString, c_char, c_long},
    io,
    mem::MaybeUninit,
    ptr,
};

#[repr(C)]
pub(super) struct Passwd {
    pub name: *mut c_char,
    pub password: *mut c_char,
    pub uid: u32,
    pub gid: u32,
    #[cfg(target_os = "macos")]
    pub change: c_long,
    #[cfg(target_os = "macos")]
    pub class: *mut c_char,
    pub gecos: *mut c_char,
    pub home: *mut c_char,
    pub shell: *mut c_char,
    #[cfg(target_os = "macos")]
    pub expire: c_long,
}

#[cfg(all(target_os = "linux", target_env = "musl"))]
type Word = u64;
#[cfg(all(target_os = "linux", not(target_env = "musl")))]
type Word = i64;
#[cfg(target_os = "linux")]
type Clock = i32;
#[cfg(target_os = "macos")]
type Clock = u32;

#[cfg(target_os = "linux")]
#[repr(C)]
pub(super) struct Statfs {
    pub kind: Word,
    pub block: Word,
    pub blocks: u64,
    pub free: u64,
    pub available: u64,
    pub files: u64,
    pub unused: u64,
    pub identity: [i32; 2],
    pub name: Word,
    pub fragment: Word,
    pub flags: Word,
    pub reserved: [Word; 4],
}

#[cfg(target_os = "macos")]
#[repr(C)]
pub(super) struct Statfs {
    pub block: u32,
    pub iosize: i32,
    pub blocks: u64,
    pub free: u64,
    pub available: u64,
    pub files: u64,
    pub unused: u64,
    pub identity: [i32; 2],
    pub owner: u32,
    pub kind: u32,
    pub flags: u32,
    pub subtype: u32,
    pub name: [c_char; 16],
    pub mount: [c_char; 1024],
    pub device: [c_char; 1024],
    pub extended: u32,
    pub reserved: [u32; 7],
}

unsafe extern "C" {
    pub(super) fn sysconf(name: i32) -> c_long;
    fn getuid() -> u32;
    fn getpwuid_r(
        uid: u32,
        value: *mut Passwd,
        bytes: *mut c_char,
        length: usize,
        result: *mut *mut Passwd,
    ) -> i32;
    #[cfg_attr(
        all(target_os = "macos", target_arch = "x86_64"),
        link_name = "statfs$INODE64"
    )]
    fn statfs(path: *const c_char, value: *mut Statfs) -> i32;
}

pub(super) fn clock(clock: Clock) -> io::Result<f64> {
    let value = super::super::native::clock(clock as u32)?;
    Ok(value.sec as f64 + value.nanos as f64 / 1e9)
}

pub(super) fn time(local: bool) -> io::Result<f64> {
    #[cfg(target_os = "linux")]
    let clock = {
        let _ = local;
        1 // CLOCK_MONOTONIC.
    };
    #[cfg(target_os = "macos")]
    let clock = if local { 8 } else { 6 }; // CLOCK_UPTIME_RAW / CLOCK_MONOTONIC.
    self::clock(clock)
}

pub(super) fn home() -> io::Result<String> {
    let mut value = MaybeUninit::zeroed();
    let mut bytes = vec![0; 65_536];
    let mut result = ptr::null_mut();
    // SAFETY: buffers and result pointer remain live until the account name is copied.
    let status = unsafe {
        getpwuid_r(
            getuid(),
            value.as_mut_ptr(),
            bytes.as_mut_ptr(),
            bytes.len(),
            &mut result,
        )
    };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status));
    }
    if result.is_null() {
        return Err(io::ErrorKind::NotFound.into());
    }
    let value = unsafe { value.assume_init() };
    if value.home.is_null() || value.shell.is_null() {
        return Err(io::ErrorKind::NotFound.into());
    }
    // SAFETY: successful getpwuid_r returns terminated strings inside the live scratch buffer.
    Ok(unsafe { CStr::from_ptr(value.home) }
        .to_string_lossy()
        .into_owned())
}

pub(super) fn disk(path: &str) -> io::Result<Option<Disk>> {
    let name = CString::new(path).map_err(|_| invalid())?;
    let mut value = MaybeUninit::zeroed();
    // SAFETY: terminated path and exact statfs storage; failure omits this row as in c1654cc.
    if unsafe { statfs(name.as_ptr(), value.as_mut_ptr()) } != 0 {
        return Ok(None);
    }
    let value = unsafe { value.assume_init() };
    #[cfg(all(target_os = "linux", not(target_env = "musl")))]
    let block = u64::try_from(value.block).map_err(|_| invalid())?;
    #[cfg(any(target_os = "macos", target_env = "musl"))]
    let block = u64::from(value.block);
    let Some(total) = value.blocks.checked_mul(block) else {
        return Ok(None);
    };
    let Some(free) = value.available.checked_mul(block) else {
        return Ok(None);
    };
    Ok(Some(Disk {
        identity: value.identity,
        paths: vec![path.into()],
        total,
        free: free.min(total),
    }))
}

pub(super) fn units() -> io::Result<[u64; 4]> {
    #[cfg(target_os = "linux")]
    let names = [2, 30]; // _SC_CLK_TCK / _SC_PAGESIZE.
    #[cfg(target_os = "macos")]
    let names = [3, 29];
    // SAFETY: sysconf has scalar arguments only.
    let values = names.map(|name| unsafe { sysconf(name) });
    #[cfg(target_os = "linux")]
    if values.iter().any(|value| *value <= 0) {
        return Err(invalid());
    }
    #[cfg(target_os = "linux")]
    let base = [1u32; 2];
    #[cfg(target_os = "macos")]
    let base = super::macos::timebase()?;
    Ok([
        values[0].max(0) as u64,
        values[1].max(0) as u64,
        base[0].into(),
        base[1].into(),
    ])
}
