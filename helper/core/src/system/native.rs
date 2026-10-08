//! Direct Unix ABI, matching the native headers and c1654cc os.rs.
use crate::api::Grid;
use std::{
    ffi::{CStr, OsStr, c_char, c_void},
    fs::File,
    io,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::ffi::OsStrExt,
    },
    path::{Path, PathBuf},
};

#[repr(C)]
pub(super) struct Timespec {
    pub sec: std::ffi::c_long,
    pub nanos: std::ffi::c_long,
}
#[cfg(target_os = "linux")]
type Clock = i32;
#[cfg(target_os = "macos")]
type Clock = u32;

pub(super) fn clock(id: u32) -> io::Result<Timespec> {
    unsafe extern "C" {
        fn clock_gettime(clock: Clock, value: *mut Timespec) -> i32;
    }
    let mut value = std::mem::MaybeUninit::zeroed();
    // SAFETY: Timespec is verified against native headers; success initializes it.
    if unsafe { clock_gettime(id as Clock, value.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { value.assume_init() })
}

#[repr(C)]
struct Size {
    rows: u16,
    columns: u16,
    x: u16,
    y: u16,
}
#[cfg(target_os = "linux")]
type Mask = [u64; 16];
#[cfg(target_os = "macos")]
type Mask = u32;
#[repr(C)]
struct Action {
    handler: usize,
    mask: Mask,
    flags: i32,
    #[cfg(target_os = "linux")]
    restorer: usize,
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
    home: *mut c_char,
    shell: *mut c_char,
    #[cfg(target_os = "macos")]
    expire: i64,
}
#[cfg(target_os = "linux")]
#[repr(C)]
struct Credentials {
    pid: i32,
    uid: u32,
    gid: u32,
}

pub(super) const EEXIST: i32 = 17;
pub(super) const ESTALE: i32 = if cfg!(target_os = "macos") { 70 } else { 116 };
// open(2) flags. Linux arm64 swaps O_DIRECTORY and O_NOFOLLOW with x86-64's O_DIRECT and O_LARGEFILE.
#[cfg(all(
    target_os = "linux",
    not(any(target_arch = "x86_64", target_arch = "aarch64"))
))]
compile_error!("open(2) flags are defined for x86-64 and arm64 Linux only");
pub(super) const O_NONBLOCK: i32 = if cfg!(target_os = "macos") { 4 } else { 0x800 };
pub(super) const O_NOFOLLOW: i32 = if cfg!(target_os = "macos") {
    0x100
} else if cfg!(target_arch = "aarch64") {
    0x8000
} else {
    0x20000
};
pub(super) const O_DIRECTORY: i32 = if cfg!(target_os = "macos") {
    0x100000
} else if cfg!(target_arch = "aarch64") {
    0x4000
} else {
    0x10000
};
pub(super) const O_CLOEXEC: i32 = if cfg!(target_os = "macos") {
    0x1000000
} else {
    0x80000
};

/// Pin the parent once; guarded transactions reject a symlink, plain IO accepts path aliases.
pub(super) fn directory(path: &Path, expected: crate::api::Expected) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    const FLAGS: i32 = O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
    let flags = if expected == crate::api::Expected::Any {
        FLAGS & !O_NOFOLLOW
    } else {
        FLAGS
    };
    let file = File::options().read(true).custom_flags(flags).open(path)?;
    if expected != crate::api::Expected::Any && unsafe { flock(file.as_raw_fd(), 2) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(file)
}

fn component(name: &OsStr) -> io::Result<std::ffi::CString> {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes == b"." || bytes == b".." || bytes.contains(&b'/') {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    std::ffi::CString::new(bytes).map_err(|_| io::ErrorKind::InvalidInput.into())
}

/// Open only this pinned directory's child, never follow the child's symlink.
pub(super) fn open(parent: &File, name: &OsStr, mode: Option<u32>) -> io::Result<File> {
    let name = component(name)?;
    const FLAGS: i32 = O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
    let flags = FLAGS
        | mode.map_or(0, |_| {
            if cfg!(target_os = "linux") {
                1 | 0x40 | 0x80
            } else {
                1 | 0x200 | 0x800
            }
        });
    unsafe extern "C" {
        fn openat(fd: i32, path: *const c_char, flags: i32, ...) -> i32;
    }
    // SAFETY: validated one-component name, borrowed live directory, valid native flags.
    let fd = unsafe { openat(parent.as_raw_fd(), name.as_ptr(), flags, mode.unwrap_or(0)) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: openat returned a new uniquely owned descriptor.
    Ok(unsafe { File::from_raw_fd(fd) })
}

pub(super) fn remove(parent: &File, name: &OsStr) -> io::Result<()> {
    let name = component(name)?;
    unsafe extern "C" {
        fn unlinkat(fd: i32, path: *const c_char, flags: i32) -> i32;
    }
    // SAFETY: pinned directory and validated child name, no symlink traversal.
    if unsafe { unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    // unlink(dir) is EISDIR on Linux, EPERM on Darwin; keep both operations pinned.
    if error.raw_os_error() != Some(if cfg!(target_os = "macos") { 1 } else { 21 }) {
        return Err(error);
    }
    let flags = if cfg!(target_os = "macos") {
        0x80
    } else {
        0x200
    };
    // SAFETY: validated child beneath a borrowed pinned parent, nonrecursive AT_REMOVEDIR.
    if unsafe { unlinkat(parent.as_raw_fd(), name.as_ptr(), flags) } == 0 {
        return Ok(());
    }
    let directory = io::Error::last_os_error();
    Err(if directory.raw_os_error() == Some(20) {
        error
    } else {
        directory
    })
}

/// Atomic publication relative to the same parent used for checking and writing.
pub(super) fn publish(
    parent: &File,
    source: &OsStr,
    target: &OsStr,
    replace: bool,
) -> io::Result<()> {
    let source = component(source)?;
    let target = component(target)?;
    let fd = parent.as_raw_fd();
    unsafe extern "C" {
        fn renameat(first: i32, source: *const c_char, second: i32, target: *const c_char) -> i32;
    }
    let status = if replace {
        // SAFETY: owned pinned directory and valid terminated child names.
        unsafe { renameat(fd, source.as_ptr(), fd, target.as_ptr()) as std::ffi::c_long }
    } else {
        #[cfg(target_os = "linux")]
        {
            unsafe extern "C" {
                fn syscall(number: std::ffi::c_long, ...) -> std::ffi::c_long;
            }
            #[cfg(target_arch = "x86_64")]
            const NUMBER: std::ffi::c_long = 316;
            #[cfg(target_arch = "aarch64")]
            const NUMBER: std::ffi::c_long = 276;
            // SAFETY: native renameat2 ABI, pinned fds and RENAME_NOREPLACE.
            unsafe { syscall(NUMBER, fd, source.as_ptr(), fd, target.as_ptr(), 1u32) }
        }
        #[cfg(target_os = "macos")]
        {
            unsafe extern "C" {
                fn renameatx_np(
                    first: i32,
                    source: *const c_char,
                    second: i32,
                    target: *const c_char,
                    flags: u32,
                ) -> i32;
            }
            // SAFETY: Darwin RENAME_EXCL and the same pinned directory for both children.
            unsafe { renameatx_np(fd, source.as_ptr(), fd, target.as_ptr(), 4) as std::ffi::c_long }
        }
    };
    if status == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
    pub(super) fn getuid() -> u32;
    fn getpwuid_r(
        uid: u32,
        entry: *mut Passwd,
        bytes: *mut c_char,
        length: usize,
        result: *mut *mut Passwd,
    ) -> i32;
    #[cfg(target_os = "linux")]
    fn sysconf(name: i32) -> i64;
    fn openpty(
        master: *mut i32,
        slave: *mut i32,
        name: *mut c_char,
        modes: *const c_void,
        size: *const Size,
    ) -> i32;
    fn fcntl(fd: i32, op: i32, ...) -> i32;
    fn ioctl(fd: i32, op: usize, ...) -> i32;
    fn setsid() -> i32;
    fn tcgetpgrp(fd: i32) -> i32;
    fn kill(pid: i32, signal: i32) -> i32;
    fn sigemptyset(set: *mut Mask) -> i32;
    fn sigaction(signal: i32, action: *const Action, old: *mut Action) -> i32;
    fn sigprocmask(op: i32, mask: *const Mask, old: *mut Mask) -> i32;
    pub(super) fn getsockopt(
        fd: i32,
        level: i32,
        name: i32,
        value: *mut c_void,
        size: *mut u32,
    ) -> i32;
    #[cfg(target_os = "macos")]
    fn getpeereid(fd: i32, uid: *mut u32, gid: *mut u32) -> i32;
}

pub(super) struct Account {
    pub uid: u32,
    #[cfg(target_os = "macos")]
    pub name: std::ffi::OsString,
    pub home: PathBuf,
}
pub(super) fn account() -> io::Result<Account> {
    lookup(65_536)
}
fn lookup(length: usize) -> io::Result<Account> {
    let uid = unsafe { getuid() };
    let mut entry = std::mem::MaybeUninit::zeroed();
    let mut bytes = vec![0; length];
    loop {
        let mut result = std::ptr::null_mut();
        // SAFETY: the passwd record and its terminated strings belong to our live scratch buffer.
        let status = unsafe {
            getpwuid_r(
                uid,
                entry.as_mut_ptr(),
                bytes.as_mut_ptr(),
                bytes.len(),
                &mut result,
            )
        };
        if status == 34 {
            // helper2 system.rs:482: retry native ERANGE, bounded by its1MiB service limit.
            let size = bytes
                .len()
                .checked_mul(2)
                .filter(|size| *size > bytes.len() && *size <= 1_048_576)
                .ok_or_else(|| io::Error::from(io::ErrorKind::OutOfMemory))?;
            bytes.resize(size, 0);
            continue;
        }
        if status != 0 {
            return Err(io::Error::from_raw_os_error(status));
        }
        if result.is_null() {
            return Err(io::ErrorKind::NotFound.into());
        }
        let entry = unsafe { entry.assume_init() };
        if entry.name.is_null() || entry.home.is_null() {
            return Err(io::Error::other("passwd account lookup failed"));
        }
        let home = unsafe { CStr::from_ptr(entry.home) }.to_bytes();
        if home.len() >= 4096 {
            return Err(io::Error::other("passwd account lookup failed"));
        }
        let home = PathBuf::from(OsStr::from_bytes(home));
        if !home.is_absolute() {
            return Err(io::ErrorKind::InvalidData.into());
        }
        return Ok(Account {
            uid,
            #[cfg(target_os = "macos")]
            name: OsStr::from_bytes(unsafe { CStr::from_ptr(entry.name) }.to_bytes()).to_owned(),
            home,
        });
    }
}
#[cfg(target_os = "linux")]
pub(super) fn ticks() -> i64 {
    #[cfg(target_os = "linux")]
    const TICKS: i32 = 2;
    unsafe { sysconf(TICKS) }
}
pub(super) fn tty(device: u64) -> u64 {
    #[cfg(target_os = "macos")]
    {
        device as u32 as u64
    }
    #[cfg(target_os = "linux")]
    {
        let major = ((device >> 8) & 0xfff) | ((device >> 32) & 0xfffff000);
        let minor = (device & 0xff) | ((device >> 12) & 0xffffff00);
        let (major, minor) = (major as u32, minor as u32);
        ((minor & 0xff) | (major << 8) | ((minor & !0xff) << 12)) as u64
    }
}
pub(super) fn private(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    const FLAGS: i32 = O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(FLAGS)
        .open(path)
}
pub(super) fn peer(fd: i32) -> io::Result<(u32, u32)> {
    #[cfg(target_os = "linux")]
    let (uid, pid, count) = {
        let mut info = Credentials {
            pid: 0,
            uid: 0,
            gid: 0,
        };
        let mut count = std::mem::size_of_val(&info) as u32;
        if unsafe {
            getsockopt(
                fd,
                1,
                17,
                (&mut info as *mut Credentials).cast(),
                &mut count,
            )
        } < 0
        {
            return Err(io::Error::last_os_error());
        }
        (
            info.uid,
            info.pid,
            count == std::mem::size_of_val(&info) as u32,
        )
    };
    #[cfg(target_os = "macos")]
    let (uid, pid, count) = {
        let (mut uid, mut gid, mut pid) = (0, 0, 0i32);
        if unsafe { getpeereid(fd, &mut uid, &mut gid) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut count = std::mem::size_of_val(&pid) as u32;
        if unsafe { getsockopt(fd, 0, 2, (&mut pid as *mut i32).cast(), &mut count) } < 0 {
            return Err(io::Error::last_os_error());
        }
        (uid, pid, count == std::mem::size_of_val(&pid) as u32)
    };
    if !count || pid <= 0 {
        return Err(io::Error::from_raw_os_error(22));
    }
    Ok((uid, pid as u32))
}
fn size(grid: Grid) -> io::Result<Size> {
    if grid.rows == 0 || grid.columns == 0 {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let (width, height) = grid.pixels.unwrap_or((0, 0));
    Ok(Size {
        rows: grid.rows,
        columns: grid.columns,
        x: width.saturating_mul(grid.columns),
        y: height.saturating_mul(grid.rows),
    })
}
pub(super) fn cloexec(fd: i32) -> io::Result<()> {
    // Preserve descriptor flags when adding FD_CLOEXEC; neither call takes a pointer.
    let flags = unsafe { fcntl(fd, 1) };
    if flags < 0 || unsafe { fcntl(fd, 2, flags | 1) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
pub(super) fn pty(
    grid: Grid,
    modes: Option<&super::renderer::native::Termios>,
) -> io::Result<(File, File)> {
    let size = size(grid)?;
    let (mut master, mut slave) = (-1, -1);
    if unsafe {
        openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            modes.map_or(std::ptr::null(), |m| {
                (m as *const super::renderer::native::Termios).cast()
            }),
            &size,
        )
    } < 0
    {
        // Say what failed: a host without /dev/ptmx or out of PTYs (user decision: a clear
        // failure, no non-PTY fallback).
        let error = io::Error::last_os_error();
        return Err(io::Error::new(
            error.kind(),
            format!("no pseudo-terminal (PTY) could be opened: {error}"),
        ));
    }
    // Successful openpty returns independently owned descriptors, closed on every error path.
    let pair = unsafe { (File::from_raw_fd(master), File::from_raw_fd(slave)) };
    for fd in [pair.0.as_raw_fd(), pair.1.as_raw_fd()] {
        cloexec(fd)?;
    }
    Ok(pair)
}
/// Only an owned, unreaped child may be passed here; c1654cc os.rs:679-697.
pub(super) fn hangup(master: i32, child: u32) {
    // SAFETY: master is a live owned PTY, child is pinned by its unreaped Child.
    unsafe {
        let group = tcgetpgrp(master);
        if group > 1 {
            kill(-group, 1);
        }
        if child > 1 && child as i32 != group {
            kill(child as i32, 1);
        }
    }
}

/// Only the live master of an owned, unreaped PTY child may be passed here.
pub(super) fn interrupt(master: i32, signal: i32) -> io::Result<()> {
    if !matches!(signal, 2 | 3) {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    // SAFETY: the kernel resolves the foreground group on our still-owned terminal.
    let group = unsafe { tcgetpgrp(master) };
    if group < 0 {
        return Err(io::Error::last_os_error());
    }
    if group > 1 && unsafe { kill(-group, signal) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

pub(super) fn session() -> io::Result<()> {
    #[cfg(target_os = "linux")]
    const CONTROL: usize = 0x540e;
    #[cfg(target_os = "macos")]
    const CONTROL: usize = 0x20007461;
    #[cfg(target_os = "linux")]
    const SET: i32 = 2;
    #[cfg(target_os = "macos")]
    const SET: i32 = 3;
    // Called only in pre_exec: stack storage and async-signal-safe syscalls, no allocator.
    unsafe {
        if setsid() < 0 || ioctl(0, CONTROL, 0i32) < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut action: Action = std::mem::zeroed();
        if sigemptyset(&mut action.mask) < 0 {
            return Err(io::Error::last_os_error());
        }
        for signal in [13, 1, 15, 2, 3, 28] {
            if sigaction(signal, &action, std::ptr::null_mut()) < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        let mut mask: Mask = std::mem::zeroed();
        if sigemptyset(&mut mask) < 0 || sigprocmask(SET, &mask, std::ptr::null_mut()) < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}
pub(super) fn resize(fd: i32, grid: Grid) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    const RESIZE: usize = 0x5414;
    #[cfg(target_os = "macos")]
    const RESIZE: usize = 0x80087467;
    let size = size(grid)?;
    if unsafe { ioctl(fd, RESIZE, &size) } < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// Old herdr_start.rs:87-107 lock retry on the fixed disk workers, never the reactor.
pub(super) fn advisory(path: &Path, deadline: std::time::Instant) -> io::Result<File> {
    let file = lock(path, true, unsafe { getuid() })?;
    loop {
        if std::time::Instant::now() >= deadline {
            return Err(io::ErrorKind::TimedOut.into());
        }
        // SAFETY: uniquely owned private lock file; LOCK_EX | LOCK_NB.
        if unsafe { flock(file.as_raw_fd(), 2 | 4) } == 0 {
            return Ok(file);
        }
        let error = io::Error::last_os_error();
        if !matches!(
            error.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
        ) {
            return Err(error);
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

pub(super) fn lock(path: &Path, create: bool, uid: u32) -> io::Result<File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    const FLAGS: i32 = O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
    let file = File::options()
        .read(true)
        .write(true)
        .create(create)
        .mode(0o600)
        .custom_flags(FLAGS)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != uid
        || metadata.mode() & 0o077 != 0
        || metadata.nlink() != 1
        || metadata.len() != 0
    {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(file)
}

/// SIGTERM to an owned, unreaped child whose helper is ending.
pub(super) fn end(child: u32) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    let resume = 18;
    #[cfg(target_os = "macos")]
    let resume = 19;
    for signal in [15, resume] {
        // The unreaped owned child pins this PID. Resume permits a stopped child
        // to handle its pending SIGTERM; neither signal targets its parent.
        if unsafe { kill(child as i32, signal) } < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(3) {
                return Err(error);
            }
        }
    }
    Ok(())
}

/// After fork: deliver SIGTERM to this child when the helper's thread dies.
#[cfg(target_os = "linux")]
pub(super) fn orphaned() -> io::Result<()> {
    unsafe extern "C" {
        fn prctl(option: i32, argument: u64, ...) -> i32;
    }
    // SAFETY: PR_SET_PDEATHSIG (1) with SIGTERM; async-signal-safe.
    if unsafe { prctl(1, 15) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
