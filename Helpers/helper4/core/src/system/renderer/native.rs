//! Native ancillary and terminal layouts; fixtures come from Swift's imported headers.
use std::{ffi::c_void, io, mem, ptr};

#[cfg(target_os = "linux")]
type Flags = u32;
#[cfg(target_os = "macos")]
type Flags = u64;
#[cfg(target_os = "linux")]
type Length = usize;
#[cfg(target_os = "macos")]
type Length = u32;
#[cfg(target_os = "linux")]
type Count = usize;
#[cfg(target_os = "macos")]
type Count = i32;

#[derive(Clone, Copy)]
#[repr(C)]
pub(crate) struct Termios {
    input: Flags,
    output: Flags,
    control: Flags,
    local: Flags,
    #[cfg(target_os = "linux")]
    line: u8,
    #[cfg(target_os = "linux")]
    chars: [u8; 32],
    #[cfg(target_os = "macos")]
    chars: [u8; 20],
    ispeed: Flags,
    ospeed: Flags,
}

#[repr(C)]
pub(super) struct Iovec {
    base: *const u8,
    length: usize,
}
#[repr(C)]
pub(super) struct Message {
    name: *const u8,
    namelen: u32,
    iov: *const Iovec,
    iovlen: Count,
    control: *const u8,
    controllen: Length,
    flags: i32,
}
#[repr(C)]
pub(super) struct Header {
    length: Length,
    level: i32,
    kind: i32,
}
#[repr(C)]
struct Rights {
    header: Header,
    descriptors: [i32; 2],
}

unsafe extern "C" {
    fn tcgetattr(fd: i32, state: *mut Termios) -> i32;
    fn tcsetattr(fd: i32, action: i32, state: *const Termios) -> i32;
    fn cfmakeraw(state: *mut Termios);
    fn sendmsg(fd: i32, message: *const Message, flags: i32) -> isize;
    pub(super) fn pipe(descriptors: *mut i32) -> i32;
    pub(super) fn read(fd: i32, bytes: *mut c_void, size: usize) -> isize;
    pub(super) fn write(fd: i32, bytes: *const c_void, size: usize) -> isize;
    pub(super) fn signal(number: i32, handler: usize) -> usize;
    #[cfg(target_os = "macos")]
    fn setsockopt(fd: i32, level: i32, option: i32, value: *const i32, size: u32) -> i32;
    pub(super) fn fcntl(fd: i32, command: i32, ...) -> i32;
    #[cfg(target_os = "linux")]
    #[link_name = "__errno_location"]
    pub(super) fn errno() -> *mut i32;
    #[cfg(target_os = "macos")]
    #[link_name = "__error"]
    pub(super) fn errno() -> *mut i32;
}

/// Observe the outer terminal before a login renderer switches it to raw mode.
pub(crate) fn modes(fd: i32) -> io::Result<Option<Termios>> {
    let mut state = mem::MaybeUninit::zeroed();
    // SAFETY: tcgetattr writes the header-verified native structure.
    if unsafe { tcgetattr(fd, state.as_mut_ptr()) } == 0 {
        Ok(Some(unsafe { state.assume_init() }))
    } else {
        let error = io::Error::last_os_error();
        if error.raw_os_error().is_some_and(|code| {
            code == 25 || (cfg!(target_os = "macos") && matches!(code, 19 | 102))
        }) {
            // Darwin non-TTY ioctls report ENODEV for /dev/null and ENOTSUP for sockets.
            // Nonterminal SSH stdio keeps the ordinary PTY defaults.
            Ok(None)
        } else {
            Err(error)
        }
    }
}

pub(crate) struct Raw(Termios);
impl Raw {
    pub(crate) fn new() -> io::Result<Self> {
        let state = modes(0)?.ok_or_else(|| io::Error::from_raw_os_error(25))?;
        let mut raw = state;
        // SAFETY: cfmakeraw changes only the live native termios structure.
        unsafe { cfmakeraw(&mut raw) };
        // SAFETY: TCSANOW applies the verified native structure without waiting for output.
        if unsafe { tcsetattr(0, 0, &raw) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(state))
    }
}
impl Drop for Raw {
    fn drop(&mut self) {
        // SAFETY: restore the same inherited terminal using its captured native state.
        unsafe { tcsetattr(0, 0, &self.0) };
    }
}

pub(super) fn configure(fd: i32) -> io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        let enabled = 1;
        // SAFETY: SO_NOSIGPIPE accepts one native integer; only this socket is changed.
        if unsafe {
            setsockopt(
                fd,
                0xffff,
                0x1022,
                &enabled,
                mem::size_of_val(&enabled) as u32,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
    }
    #[cfg(target_os = "linux")]
    let _ = fd;
    Ok(())
}

pub(super) fn send(fd: i32, bytes: &[u8], descriptors: bool) -> io::Result<usize> {
    let iov = Iovec {
        base: bytes.as_ptr(),
        length: bytes.len(),
    };
    let rights = Rights {
        header: Header {
            length: mem::size_of::<Rights>() as Length,
            #[cfg(target_os = "linux")]
            level: 1,
            #[cfg(target_os = "macos")]
            level: 0xffff,
            kind: 1,
        },
        descriptors: [0, 1],
    };
    let message = Message {
        name: ptr::null(),
        namelen: 0,
        iov: &iov,
        iovlen: 1,
        control: if descriptors {
            (&rights as *const Rights).cast()
        } else {
            ptr::null()
        },
        controllen: if descriptors {
            mem::size_of::<Rights>() as Length
        } else {
            0
        },
        flags: 0,
    };
    #[cfg(target_os = "linux")]
    let flags = 0x4000; // MSG_NOSIGNAL.
    #[cfg(target_os = "macos")]
    let flags = 0;
    // SAFETY: message/iovec/control and payload remain live; sendmsg borrows every pointer.
    let count = unsafe { sendmsg(fd, &message, flags) };
    if count < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(count as usize)
    }
}

pub(crate) fn grid() -> io::Result<crate::api::Grid> {
    #[repr(C)]
    struct Size {
        rows: u16,
        columns: u16,
        x: u16,
        y: u16,
    }
    unsafe extern "C" {
        fn ioctl(fd: i32, op: usize, ...) -> i32;
    }
    #[cfg(target_os = "linux")]
    const QUERY: usize = 0x5413;
    #[cfg(target_os = "macos")]
    const QUERY: usize = 0x40087468;
    let mut size = Size {
        rows: 0,
        columns: 0,
        x: 0,
        y: 0,
    };
    // SAFETY: the winsize layout is already verified by the native PTY ABI fixtures.
    if unsafe { ioctl(0, QUERY, &mut size) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(crate::api::Grid {
        pixels: None,
        columns: size.columns.max(1),
        rows: size.rows.max(1),
    })
}
