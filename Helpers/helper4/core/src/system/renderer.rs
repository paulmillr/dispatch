//! The renderer child passes two descriptors once; terminal bytes bypass this control socket.
pub(crate) mod native;

use super::{reactor, socket};
use crate::api::Address;
use std::{
    fs::File,
    io,
    os::fd::{AsRawFd, FromRawFd, RawFd},
    path::PathBuf,
    sync::atomic::{AtomicI32, AtomicU32, Ordering},
};

static WAKE: AtomicI32 = AtomicI32::new(-1);
static SIGNALS: AtomicU32 = AtomicU32::new(0);

extern "C" fn signal(number: i32) {
    SIGNALS.fetch_or(1 << number, Ordering::Relaxed);
    let fd = WAKE.load(Ordering::Relaxed);
    if fd >= 0 {
        // SAFETY: errno points to this thread's live native integer; preserve interrupted IO.
        let location = unsafe { native::errno() };
        // SAFETY: the errno pointer remains valid on this signal-handler thread.
        let saved = unsafe { *location };
        // SAFETY: write is async-signal-safe; this nonblocking pipe stays open while installed.
        unsafe { native::write(fd, b"R".as_ptr().cast(), 1) };
        // SAFETY: restore the same live thread-local errno after the wake write.
        unsafe { *location = saved };
    }
}

pub(crate) struct Signals {
    pub(crate) read: File,
    _write: File,
    previous: Vec<(i32, usize)>,
}
impl Signals {
    /// Record `numbers` (bit `1 << number` in `take`) and wake `read`; SIGPIPE is ignored.
    pub(crate) fn new(numbers: &[i32], inherit: bool) -> io::Result<Self> {
        let mut descriptors = [-1; 2];
        // SAFETY: pipe writes exactly two descriptors into a live two-integer array.
        if unsafe { native::pipe(descriptors.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: successful pipe returned two new exclusively owned descriptors.
        let read = unsafe { File::from_raw_fd(descriptors[0]) };
        // SAFETY: the second pipe descriptor has the same exclusive ownership.
        let write = unsafe { File::from_raw_fd(descriptors[1]) };
        for fd in [read.as_raw_fd(), write.as_raw_fd()] {
            // SAFETY: F_SETFD/FD_CLOEXEC affects only newly owned pipe descriptors.
            if unsafe { native::fcntl(fd, 2, 1) } < 0 {
                return Err(io::Error::last_os_error());
            }
            reactor::nonblocking(fd)?;
        }
        let mut signals = Self {
            read,
            _write: write,
            previous: Vec::new(),
        };
        SIGNALS.store(0, Ordering::Relaxed);
        WAKE.store(signals._write.as_raw_fd(), Ordering::Relaxed);
        for &number in numbers.iter().chain(&[13]) {
            let handler = if number == 13 {
                1
            } else {
                signal as *const () as usize
            }; // SIG_IGN for SIGPIPE.
            // SAFETY: valid native signal numbers and an ABI-correct handler or SIG_IGN.
            let previous = unsafe { native::signal(number, handler) };
            if previous == usize::MAX {
                return Err(io::Error::last_os_error());
            }
            if inherit && (previous == 1 || number == 13) {
                // Capture must not change SIGPIPE, nohup or ignored background signals.
                unsafe { native::signal(number, previous) };
            }
            signals.previous.push((number, previous));
        }
        Ok(signals)
    }

    pub(crate) fn take(&self) -> io::Result<u32> {
        let mut bytes = [0u8; 64];
        loop {
            // SAFETY: the live buffer has exactly the requested capacity.
            let count = unsafe {
                native::read(
                    self.read.as_raw_fd(),
                    bytes.as_mut_ptr().cast(),
                    bytes.len(),
                )
            };
            if count < 0 {
                let error = io::Error::last_os_error();
                match error.kind() {
                    io::ErrorKind::Interrupted => continue,
                    io::ErrorKind::WouldBlock => break,
                    _ => return Err(error),
                }
            }
            if count == 0 {
                break;
            }
        }
        Ok(SIGNALS.swap(0, Ordering::Relaxed))
    }
}
impl Drop for Signals {
    fn drop(&mut self) {
        WAKE.store(-1, Ordering::Relaxed);
        for &(number, handler) in &self.previous {
            // SAFETY: restore each native disposition returned by the original installation.
            unsafe { native::signal(number, handler) };
        }
    }
}

/// Runs before normal helper initialization, so there are no workers or module state to inherit.
pub fn run() -> io::Result<()> {
    let names = [
        "DISPATCH_RENDERER_SOCKET",
        "DISPATCH_RENDERER_TAB",
        "DISPATCH_RENDERER_TOKEN",
    ];
    let values = names.map(std::env::var);
    let [path, tab, token] = values.map(|value| value.map_err(|_| io::ErrorKind::InvalidInput));
    let (path, tab, token) = (path?, tab?, token?);
    if tab.contains(['\n', '\r'])
        || token.contains(['\n', '\r'])
        || tab.is_empty()
        || token.is_empty()
    {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let hello = format!("{tab}\n{token}\nrenderer\n").into_bytes();
    if hello.len() > 256 {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    for name in names {
        // SAFETY: this branch runs in the fresh single-threaded binary before any workers start.
        unsafe { std::env::remove_var(name) };
    }
    let _raw = native::Raw::new()?;
    // SIGHUP, SIGINT, SIGTERM end the renderer; SIGWINCH resizes.
    let signals = Signals::new(&[1, 2, 15, 28], false)?;
    let mut reactor = reactor::Reactor::new()?;
    let control = socket::start(&Address::Unix(PathBuf::from(path)))?;
    let fd = control.as_raw_fd();
    native::configure(fd)?;
    reactor.interest(signals.read.as_raw_fd(), true, false)?;
    let mut connected = false;
    let mut offset = 0;
    let mut resize = true;
    loop {
        reactor.interest(fd, true, !connected || offset < hello.len() || resize)?;
        let event = reactor.wait()?;
        if event.fd == signals.read.as_raw_fd() {
            let flags = signals.take()?;
            if flags & (1 << 1 | 1 << 2 | 1 << 15) != 0 {
                return Ok(());
            }
            resize |= flags & 1 << 28 != 0;
            continue;
        }
        if event.write {
            if !connected {
                socket::complete(fd)?;
                connected = true;
            }
            let result = if offset < hello.len() {
                native::send(fd, &hello[offset..], offset == 0)
            } else if resize {
                native::send(fd, b"R", false)
            } else {
                Ok(0)
            };
            match result {
                Ok(count) if offset < hello.len() => {
                    if count == 0 {
                        return Err(io::ErrorKind::WriteZero.into());
                    }
                    offset += count;
                }
                Ok(count) if count > 0 => resize = false,
                Ok(_) => {}
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) => {}
                Err(error) => return Err(error),
            }
        }
        if event.read || event.closed {
            let mut bytes = [0u8; 64];
            // SAFETY: the nonblocking control socket and live buffer belong to this run.
            let count = unsafe { native::read(fd, bytes.as_mut_ptr().cast(), bytes.len()) };
            if count == 0 {
                return Ok(());
            }
            if count < 0 {
                let error = io::Error::last_os_error();
                if !matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) {
                    return Err(error);
                }
            }
        }
    }
}

impl super::System {
    pub(crate) fn signals(&mut self, numbers: &[i32], inherit: bool) -> io::Result<RawFd> {
        let args = format!("{numbers:?}");
        if let Some(result) = self.replay("signals", &args) {
            return result.and_then(|bytes| {
                bytes
                    .try_into()
                    .map(i32::from_le_bytes)
                    .map_err(|_| super::file::invalid())
            });
        }
        let result = Signals::new(numbers, inherit).map(|signals| {
            let fd = signals.read.as_raw_fd();
            self.signals.insert(fd, signals);
            fd
        });
        let bytes = result
            .as_ref()
            .map(|fd| fd.to_le_bytes().to_vec())
            .unwrap_or_default();
        self.record("signals", &args, &result, &bytes)?;
        result
    }
}
