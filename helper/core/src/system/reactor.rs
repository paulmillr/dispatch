//! Native readiness only. File operations run outside this reactor.
use std::{
    io,
    os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd},
    sync::Arc,
    time::{Duration, Instant},
};

unsafe extern "C" {
    fn fcntl(fd: i32, command: i32, ...) -> i32;
}

pub fn nonblocking(fd: RawFd) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    const NONBLOCK: i32 = 0x800;
    #[cfg(target_os = "macos")]
    const NONBLOCK: i32 = 4;
    // SAFETY: fcntl takes an integer descriptor and the specified integer flags.
    let flags = unsafe { fcntl(fd, 3) };
    // SAFETY: as above; preserve every inherited status flag.
    if flags < 0 || unsafe { fcntl(fd, 4, flags | NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

pub struct Reactor {
    fd: Arc<OwnedFd>,
    registered: Vec<(RawFd, bool, bool)>,
    paused: std::collections::BTreeSet<RawFd>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ready {
    pub fd: RawFd,
    pub read: bool,
    pub write: bool,
    pub closed: bool,
    pub process: bool,
    pub vnode: bool,
    pub changes: u32,
}

pub struct Exit {
    queue: Arc<OwnedFd>,
    #[cfg(target_os = "linux")]
    source: OwnedFd,
    #[cfg(target_os = "macos")]
    pid: i32,
}

impl Exit {
    pub(super) fn exited(&self, ready: Ready) -> bool {
        #[cfg(target_os = "linux")]
        {
            self.matches(ready)
        }
        #[cfg(target_os = "macos")]
        {
            self.matches(ready) && ready.changes & 0x8000_0000 != 0
        }
    }
    pub fn matches(&self, ready: Ready) -> bool {
        #[cfg(target_os = "linux")]
        {
            !ready.process && ready.fd == self.source.as_raw_fd()
        }
        #[cfg(target_os = "macos")]
        {
            ready.process && ready.fd == self.pid
        }
    }
}

impl Drop for Exit {
    fn drop(&mut self) {
        #[cfg(target_os = "linux")]
        let _ = platform::interest(
            self.queue.as_raw_fd(),
            self.source.as_raw_fd(),
            Some((self.source.as_raw_fd(), true, false)),
            false,
            false,
        );
        #[cfg(target_os = "macos")]
        let _ = platform::child(self.queue.as_raw_fd(), self.pid, false, 0);
    }
}

impl Reactor {
    pub(super) fn queue(parent: RawFd, child: RawFd, enabled: bool) -> io::Result<()> {
        platform::interest(
            parent,
            child,
            (!enabled).then_some((child, true, false)),
            enabled,
            false,
        )
    }
    pub(crate) fn handle(&self) -> Arc<OwnedFd> {
        Arc::clone(&self.fd)
    }
    pub(crate) fn watch(queue: RawFd, fd: RawFd, initial: bool) -> io::Result<()> {
        platform::watch(queue, fd, initial)
    }
    pub fn writing(&self, fd: RawFd) -> bool {
        self.registered
            .iter()
            .any(|&(id, _, write)| id == fd && write)
    }

    pub fn reading(&self, fd: RawFd) -> bool {
        self.registered
            .iter()
            .any(|&(source, read, _)| source == fd && read)
    }
    pub fn new() -> io::Result<Self> {
        let fd = platform::create();
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: create returned a new owned descriptor which is not shared.
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        Ok(Self {
            fd: Arc::new(fd),
            registered: Vec::new(),
            paused: std::collections::BTreeSet::new(),
        })
    }

    pub fn interest(&mut self, fd: RawFd, read: bool, write: bool) -> io::Result<()> {
        let previous = self.registered.iter().position(|entry| entry.0 == fd);
        if previous.is_some_and(|index| self.registered[index] == (fd, read, write)) {
            return Ok(());
        }
        platform::interest(
            self.fd.as_raw_fd(),
            fd,
            previous.map(|i| {
                let (_, read, write) = self.registered[i];
                (fd, read && !self.paused.contains(&fd), write)
            }),
            read && !self.paused.contains(&fd),
            write,
        )?;
        if let Some(index) = previous {
            if read || write {
                self.registered[index] = (fd, read, write);
            } else {
                self.registered.swap_remove(index);
            }
        } else if read || write {
            self.registered.push((fd, read, write));
        }
        if !read && !write {
            self.paused.remove(&fd);
        }
        Ok(())
    }

    /// Mask native reads without losing the owner's desired interests or disabling writes.
    pub fn pause(&mut self, fd: RawFd, paused: bool) -> io::Result<()> {
        let previous = self.paused.contains(&fd);
        if paused == previous {
            return Ok(());
        }
        if let Some(&(_, read, write)) = self.registered.iter().find(|entry| entry.0 == fd) {
            platform::interest(
                self.fd.as_raw_fd(),
                fd,
                Some((fd, read && !previous, write)),
                read && !paused,
                write,
            )?;
        }
        if paused {
            self.paused.insert(fd);
        } else {
            self.paused.remove(&fd);
        }
        Ok(())
    }

    pub fn wait(&self) -> io::Result<Ready> {
        self.next(None)?
            .ok_or_else(|| io::ErrorKind::TimedOut.into())
    }

    pub fn poll(&self) -> io::Result<Option<Ready>> {
        loop {
            match platform::wait(self.fd.as_raw_fd(), Some(Duration::ZERO)) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                result => return result,
            }
        }
    }

    pub fn until(&self, deadline: Instant) -> io::Result<Option<Ready>> {
        self.next(Some(deadline))
    }

    pub fn child(&self, pid: u32) -> io::Result<Exit> {
        self.process(pid, 0x8000_0000)
    }
    pub(super) fn observe(&self, pid: u32) -> io::Result<Exit> {
        // Darwin NOTE_EXIT | NOTE_FORK | NOTE_EXEC; Linux pidfd provides exit only.
        self.process(pid, 0x8000_0000 | 0x4000_0000 | 0x2000_0000)
    }
    fn process(&self, pid: u32, changes: u32) -> io::Result<Exit> {
        let pid = i32::try_from(pid).map_err(|_| io::ErrorKind::InvalidInput)?;
        if pid <= 0 {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        #[cfg(target_os = "linux")]
        let source = {
            let _ = changes;
            platform::child(self.fd.as_raw_fd(), pid)?
        };
        #[cfg(target_os = "macos")]
        platform::child(self.fd.as_raw_fd(), pid, true, changes)?;
        Ok(Exit {
            queue: Arc::clone(&self.fd),
            #[cfg(target_os = "linux")]
            source,
            #[cfg(target_os = "macos")]
            pid,
        })
    }

    fn next(&self, deadline: Option<Instant>) -> io::Result<Option<Ready>> {
        loop {
            let remaining = match deadline {
                Some(deadline) => match deadline.checked_duration_since(Instant::now()) {
                    Some(remaining) if !remaining.is_zero() => Some(remaining),
                    _ => return Ok(None),
                },
                None => None,
            };
            match platform::wait(self.fd.as_raw_fd(), remaining) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Ok(None) => continue,
                result => return result,
            }
        }
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::{AsRawFd, Duration, FromRawFd, OwnedFd};
    use std::io;
    #[repr(C)]
    #[cfg_attr(target_arch = "x86_64", repr(packed))]
    struct Event {
        events: u32,
        data: u64,
    }
    unsafe extern "C" {
        fn epoll_create1(flags: i32) -> i32;
        fn epoll_ctl(epoll: i32, operation: i32, fd: i32, event: *const Event) -> i32;
        fn epoll_wait(epoll: i32, events: *mut Event, count: i32, timeout: i32) -> i32;
        fn syscall(number: std::ffi::c_long, ...) -> std::ffi::c_long;
    }
    pub fn create() -> i32 {
        // SAFETY: EPOLL_CLOEXEC is a valid flag and no pointers cross the call.
        unsafe { epoll_create1(0x80000) }
    }
    pub fn interest(
        epoll: i32,
        fd: i32,
        old: Option<(i32, bool, bool)>,
        read: bool,
        write: bool,
    ) -> io::Result<()> {
        let active = old.is_some_and(|(_, r, w)| r || w);
        if !active && !read && !write {
            return Ok(());
        }
        let operation = if !read && !write {
            2
        } else if active {
            3
        } else {
            1
        };
        let event = Event {
            events: u32::from(read) | (u32::from(write) << 2),
            data: fd as u64,
        };
        // SAFETY: event has the Linux ABI layout and is live for the synchronous call.
        if unsafe { epoll_ctl(epoll, operation, fd, &event) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
    pub fn wait(epoll: i32, remaining: Option<Duration>) -> io::Result<Option<super::Ready>> {
        let mut event = Event { events: 0, data: 0 };
        let timeout = remaining.map_or(-1, |value| {
            value
                .as_millis()
                .saturating_add(u128::from(value.subsec_nanos() % 1_000_000 != 0))
                .min(i32::MAX as u128) as i32
        });
        // SAFETY: space for one event; the timeout is the remaining operation deadline.
        match unsafe { epoll_wait(epoll, &mut event, 1, timeout) } {
            -1 => return Err(io::Error::last_os_error()),
            0 => return Ok(None),
            _ => {}
        }
        Ok(Some(super::Ready {
            fd: event.data as i32,
            read: event.events & 1 != 0,
            write: event.events & 4 != 0,
            closed: event.events & (8 | 16 | 0x2000) != 0,
            process: false,
            vnode: false,
            changes: 0,
        }))
    }

    pub fn child(queue: i32, pid: i32) -> io::Result<OwnedFd> {
        // SAFETY: pidfd_open(434 on x86_64/aarch64) takes a PID and zero flags.
        let fd = unsafe { syscall(434, pid, 0u32) } as i32;
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: pidfd_open returned a new owned close-on-exec descriptor.
        let source = unsafe { OwnedFd::from_raw_fd(fd) };
        interest(queue, source.as_raw_fd(), None, true, false)?;
        Ok(source)
    }
    pub fn watch(queue: i32, fd: i32, initial: bool) -> io::Result<()> {
        let event = Event {
            events: 1 | (1 << 30),
            data: fd as u64,
        };
        // SAFETY: native one-shot inotify readiness, using the same owned epoll queue.
        if unsafe { epoll_ctl(queue, if initial { 1 } else { 3 }, fd, &event) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::Duration;
    use std::{io, ptr};
    #[repr(C)]
    struct Timespec {
        seconds: i64,
        nanos: i64,
    }
    #[repr(C)]
    struct Event {
        ident: usize,
        filter: i16,
        flags: u16,
        fflags: u32,
        data: isize,
        udata: *mut u8,
    }
    unsafe extern "C" {
        fn kqueue() -> i32;
        fn kevent(
            queue: i32,
            changes: *const Event,
            nchanges: i32,
            events: *mut Event,
            nevents: i32,
            timeout: *const u8,
        ) -> i32;
    }
    pub fn create() -> i32 {
        // SAFETY: kqueue returns a new descriptor; fcntl marks that descriptor close-on-exec.
        unsafe {
            let fd = kqueue();
            if fd >= 0 {
                super::fcntl(fd, 2, 1);
            }
            fd
        }
    }
    pub fn interest(
        queue: i32,
        fd: i32,
        old: Option<(i32, bool, bool)>,
        read: bool,
        write: bool,
    ) -> io::Result<()> {
        for (filter, enabled, previous) in [
            (-1, read, old.is_some_and(|(_, r, _)| r)),
            (-2, write, old.is_some_and(|(_, _, w)| w)),
        ] {
            if enabled == previous {
                continue;
            }
            let change = Event {
                ident: fd as usize,
                filter,
                flags: if enabled { 1 | 4 } else { 2 }, // EV_ADD|EV_ENABLE or EV_DELETE.
                fflags: 0,
                data: 0,
                udata: ptr::null_mut(),
            };
            // SAFETY: change has Darwin's kevent layout; no event output is requested.
            if unsafe { kevent(queue, &change, 1, ptr::null_mut(), 0, ptr::null()) } < 0 {
                let error = io::Error::last_os_error();
                // A revoked terminal (its SSH session hung up) already dropped the filter.
                if enabled || error.kind() != io::ErrorKind::NotFound {
                    return Err(error);
                }
            }
        }
        Ok(())
    }
    pub fn wait(queue: i32, remaining: Option<Duration>) -> io::Result<Option<super::Ready>> {
        let mut event = Event {
            ident: 0,
            filter: 0,
            flags: 0,
            fflags: 0,
            data: 0,
            udata: ptr::null_mut(),
        };
        let timeout = remaining.map(|value| Timespec {
            seconds: value.as_secs().min(i64::MAX as u64) as i64,
            nanos: i64::from(value.subsec_nanos()),
        });
        let pointer = timeout
            .as_ref()
            .map_or(ptr::null(), |value| (value as *const Timespec).cast());
        // SAFETY: one event and an optional native timespec live through the call.
        match unsafe { kevent(queue, ptr::null(), 0, &mut event, 1, pointer) } {
            -1 => return Err(io::Error::last_os_error()),
            0 => return Ok(None),
            _ => {}
        }
        Ok(Some(super::Ready {
            fd: event.ident as i32,
            read: event.filter == -1,
            write: event.filter == -2,
            closed: event.flags & (0x8000 | 0x4000) != 0,
            process: event.filter == -5,
            vnode: event.filter == -4,
            changes: event.fflags,
        }))
    }

    pub fn child(queue: i32, pid: i32, enabled: bool, changes: u32) -> io::Result<()> {
        let change = Event {
            ident: pid as usize,
            filter: -5,
            flags: if enabled {
                1 | if changes == 0x8000_0000 { 0x10 } else { 0x20 }
            } else {
                2
            },
            fflags: changes,
            data: 0,
            udata: ptr::null_mut(),
        }; // EVFILT_PROC, EV_ADD|EV_ONESHOT or EV_DELETE, NOTE_EXIT.
        // SAFETY: the change has Darwin's kevent ABI and lives through registration.
        if unsafe { kevent(queue, &change, 1, ptr::null_mut(), 0, ptr::null()) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
    pub fn watch(queue: i32, fd: i32, _initial: bool) -> io::Result<()> {
        let change = Event {
            ident: fd as usize,
            filter: -4,
            flags: 1 | 4 | 0x20,
            fflags: 1 | 2 | 4 | 8 | 0x10 | 0x20 | 0x40,
            data: 0,
            udata: ptr::null_mut(),
        };
        // SAFETY: native EVFILT_VNODE watches the owned O_EVTONLY descriptor.
        if unsafe { kevent(queue, &change, 1, ptr::null_mut(), 0, ptr::null()) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}
