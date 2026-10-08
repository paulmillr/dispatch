//! libproc/sysctl layouts from Darwin proc_info.h and the c1654cc process.rs port.
use super::{FileIdentity, OpenFile, Process, invalid};
use std::{
    ffi::c_void,
    io,
    mem::{size_of, size_of_val},
    path::PathBuf,
};

#[repr(C)]
struct Bsd {
    flags: u32,
    status: u32,
    xstatus: u32,
    pid: u32,
    parent: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    reserved: u32,
    comm: [u8; 16],
    name: [u8; 32],
    files: u32,
    group: u32,
    jobs: u32,
    tty: u32,
    foreground: u32,
    nice: i32,
    seconds: u64,
    micros: u64,
}
#[repr(C)]
struct Task {
    virtual_size: u64,
    resident_size: u64,
    total_user: u64,
    total_system: u64,
    threads_user: u64,
    threads_system: u64,
    policy: i32,
    faults: i32,
    pageins: i32,
    cow_faults: i32,
    messages_sent: i32,
    messages_received: i32,
    syscalls_mach: i32,
    syscalls_unix: i32,
    switches: i32,
    threads: i32,
    running: i32,
    priority: i32,
}
#[repr(C)]
struct Stat {
    device: u32,
    mode: u16,
    links: u16,
    inode: u64,
    uid: u32,
    gid: u32,
    atime: i64,
    ansec: i64,
    mtime: i64,
    mnsec: i64,
    ctime: i64,
    cnsec: i64,
    birth: i64,
    bnsec: i64,
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
struct VnodePath {
    node: Vnode,
    path: [u8; 1024],
}
#[repr(C)]
struct Directory {
    cwd: VnodePath,
    root: VnodePath,
}
#[repr(C)]
struct Fd {
    fd: i32,
    kind: u32,
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
struct FilePath {
    file: FileInfo,
    node: VnodePath,
}
#[repr(C)]
struct Region {
    protection: u32,
    max: u32,
    inheritance: u32,
    flags: u32,
    offset: u64,
    behavior: u32,
    wired: u32,
    tag: u32,
    resident: u32,
    private: u32,
    swapped: u32,
    dirtied: u32,
    references: u32,
    shadow: u32,
    share: u32,
    private_resident: u32,
    shared_resident: u32,
    object: u32,
    depth: u32,
    address: u64,
    size: u64,
}
#[repr(C)]
struct RegionPath {
    region: Region,
    vnode: VnodePath,
}

#[repr(C)]
struct Date {
    second: i32,
    minute: i32,
    hour: i32,
    day: i32,
    month: i32,
    year: i32,
    weekday: i32,
    yearday: i32,
    dst: i32,
    offset: i64,
    zone: *const u8,
}

unsafe extern "C" {
    fn proc_pidinfo(pid: i32, flavor: i32, arg: u64, buffer: *mut c_void, size: i32) -> i32;
    fn proc_pidpath(pid: i32, buffer: *mut c_void, size: u32) -> i32;
    fn proc_pidfdinfo(pid: i32, fd: i32, flavor: i32, buffer: *mut c_void, size: i32) -> i32;
    fn proc_listpids(kind: u32, info: u32, buffer: *mut c_void, size: i32) -> i32;
    fn sysctl(
        mib: *mut i32,
        count: u32,
        old: *mut c_void,
        length: *mut usize,
        new: *const c_void,
        size: usize,
    ) -> i32;
    fn gmtime_r(seconds: *const i64, date: *mut Date) -> *mut Date;
}

/// Pin the executable's mapped vnode, never a replacement at its old pathname.
pub(super) fn image(pid: u32, path: &std::path::Path) -> io::Result<std::fs::File> {
    use std::os::unix::{ffi::OsStrExt, fs::MetadataExt};
    let mut address = 0u64;
    for _ in 0..16_384 {
        // SAFETY: native integer/byte layouts checked against proc_info.h in the ABI test.
        let mut info: RegionPath = unsafe { std::mem::zeroed() };
        if unsafe {
            proc_pidinfo(
                pid as i32,
                8,
                address,
                (&mut info as *mut RegionPath).cast(),
                size_of_val(&info) as i32,
            )
        } != size_of_val(&info) as i32
        {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        address = info
            .region
            .address
            .checked_add(info.region.size)
            .filter(|next| *next > address)
            .ok_or_else(invalid)?;
        if info.region.protection & 4 == 0 {
            continue;
        }
        let end = info
            .vnode
            .path
            .iter()
            .position(|b| *b == 0)
            .ok_or_else(invalid)?;
        if &info.vnode.path[..end] != path.as_os_str().as_bytes() {
            continue;
        }
        let stat = info.vnode.node.stat;
        if stat.mode & 0o170000 != 0o100000 || stat.mode & 0o111 == 0 || stat.size < 0 {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        let file = std::fs::File::open(format!("/.vol/{}/{}", stat.device, stat.inode))?;
        let m = file.metadata()?;
        if !m.is_file()
            || m.mode() & 0o111 == 0
            || m.dev() as u32 != stat.device
            || m.ino() != stat.inode
            || m.len() != stat.size as u64
        {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        return Ok(file);
    }
    Err(io::ErrorKind::PermissionDenied.into())
}

pub(super) fn snapshot(pid: u32) -> io::Result<Process> {
    let mut info: Bsd = unsafe { std::mem::zeroed() };
    if unsafe {
        proc_pidinfo(
            pid as i32,
            3,
            0,
            (&mut info as *mut Bsd).cast(),
            size_of_val(&info) as i32,
        )
    } != size_of_val(&info) as i32
    {
        return Err(io::Error::last_os_error());
    }
    if info.uid != unsafe { super::super::native::getuid() } {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!(
            "Process {pid} is owned by another account during inspection",
        )));
    }
    let mut path = [0; 4096];
    if unsafe { proc_pidpath(pid as i32, path.as_mut_ptr().cast(), path.len() as u32) } <= 0 {
        return Err(io::Error::last_os_error());
    }
    let end = path.iter().position(|b| *b == 0).ok_or_else(invalid)?;
    Ok(Process {
        pid,
        parent: info.parent,
        group: info.group as i32,
        foreground: if info.foreground > i32::MAX as u32 {
            0
        } else {
            info.foreground as i32
        },
        // Darwin NODEV is -1; the common process model uses zero for no terminal.
        tty: if info.tty == u32::MAX { 0 } else { info.tty.into() },
        start: [info.seconds, info.micros],
        executable: String::from_utf8_lossy(&path[..end]).as_ref().into(),
        arguments: vec![],
        files: vec![],
    })
}
fn argdata(pid: u32, environment: bool) -> io::Result<Vec<u8>> {
    let mut data = vec![0; 262_144];
    let mut length = data.len();
    let mut mib = [1, 49, pid as i32];
    if unsafe {
        sysctl(
            mib.as_mut_ptr(),
            3,
            data.as_mut_ptr().cast(),
            &mut length,
            std::ptr::null(),
            0,
        )
    } < 0
    {
        return Err(io::Error::last_os_error());
    }
    if length <= 4 || length > data.len() {
        return Err(invalid());
    }
    data.truncate(length);
    let count = i32::from_ne_bytes(data[..4].try_into().unwrap());
    if !(1..=8192).contains(&count) {
        return Err(invalid());
    }
    let begin = 4 + data[4..].iter().position(|b| *b == 0).ok_or_else(invalid)?;
    let begin = begin
        + data[begin..]
            .iter()
            .position(|b| *b != 0)
            .ok_or_else(invalid)?;
    let mut end = begin;
    for _ in 0..count {
        end += data[end..]
            .iter()
            .position(|b| *b == 0)
            .ok_or_else(invalid)?
            + 1;
    }
    Ok(if environment {
        data[end..].to_vec()
    } else {
        data[begin..end].to_vec()
    })
}
pub(super) fn environment(pid: u32) -> io::Result<Vec<u8>> {
    argdata(pid, true)
}
pub(super) fn arguments(pid: u32) -> io::Result<Vec<String>> {
    Ok(argdata(pid, false)?
        .split_inclusive(|b| *b == 0)
        .map(|v| String::from_utf8_lossy(&v[..v.len() - 1]).into_owned())
        .collect())
}
pub(super) fn cwd(pid: u32) -> io::Result<PathBuf> {
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
        return Err(io::Error::last_os_error());
    }
    let end = info
        .cwd
        .path
        .iter()
        .position(|b| *b == 0)
        .ok_or_else(invalid)?;
    if end == 0 || info.cwd.path[0] != b'/' {
        return Err(invalid());
    }
    Ok(PathBuf::from(
        std::str::from_utf8(&info.cwd.path[..end]).map_err(|_| invalid())?,
    ))
}
pub(super) fn label(seconds: u64) -> io::Result<String> {
    let seconds = i64::try_from(seconds).map_err(|_| invalid())?;
    let mut date: Date = unsafe { std::mem::zeroed() };
    if unsafe { gmtime_r(&seconds, &mut date) }.is_null() {
        return Err(invalid());
    }
    let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let (day, month) = (
        days.get(date.weekday as usize).ok_or_else(invalid)?,
        months.get(date.month as usize).ok_or_else(invalid)?,
    );
    Ok(format!(
        "{day} {month} {} {:02}:{:02}:{:02} {}",
        date.day,
        date.hour,
        date.minute,
        date.second,
        date.year + 1900
    ))
}
/// c1654cc process.rs:1382-1402, including stopped/background/disowned TTY jobs.
pub(super) fn jobs(shell: &Process) -> io::Result<bool> {
    let mut info: Task = unsafe { std::mem::zeroed() };
    // SAFETY: bounded native task-info buffer, ABI checked against the real SDK.
    if unsafe {
        proc_pidinfo(
            shell.pid as i32,
            4,
            0,
            (&mut info as *mut Task).cast(),
            size_of_val(&info) as i32,
        )
    } != size_of_val(&info) as i32
    {
        return Err(invalid());
    }
    if info.running != 0 {
        return Ok(true);
    }
    for (kind, value) in [(6, shell.pid), (3, shell.tty as u32)] {
        let mut pids = [0i32; 1024];
        // SAFETY: fixed native PID buffer. PROC_PPID_ONLY=6, PROC_TTY_ONLY=3.
        let count = unsafe {
            proc_listpids(
                kind,
                value,
                pids.as_mut_ptr().cast(),
                size_of_val(&pids) as i32,
            )
        };
        if count < 0 || count as usize >= size_of_val(&pids) {
            return Err(invalid());
        }
        let members = &pids[..count as usize / size_of::<i32>()];
        if kind == 3 && !members.contains(&(shell.pid as i32)) {
            return Err(invalid());
        }
        if members
            .iter()
            .any(|pid| *pid > 0 && *pid != shell.pid as i32)
        {
            return Ok(true);
        }
    }
    Ok(false)
}

pub(super) fn pids() -> io::Result<Vec<u32>> {
    let mut pids = vec![0u32; 262_144];
    let bytes = unsafe {
        proc_listpids(
            1,
            0,
            pids.as_mut_ptr().cast(),
            (pids.len() * size_of::<u32>()) as i32,
        )
    };
    if bytes < 0
        || bytes as usize % size_of::<u32>() != 0
        || bytes as usize >= pids.len() * size_of::<u32>()
    {
        return Err(invalid());
    }
    pids.truncate(bytes as usize / size_of::<u32>());
    Ok(pids)
}
pub(super) fn files(pid: u32) -> io::Result<Vec<OpenFile>> {
    let mut fds: Vec<Fd> = (0..8193).map(|_| Fd { fd: 0, kind: 0 }).collect();
    let count = unsafe {
        proc_pidinfo(
            pid as i32,
            1,
            0,
            fds.as_mut_ptr().cast(),
            (fds.len() * size_of::<Fd>()) as i32,
        )
    };
    if count < 0
        || count as usize >= fds.len() * size_of::<Fd>()
        || count as usize % size_of::<Fd>() != 0
    {
        return Err(invalid());
    }
    let mut used = 0;
    let mut paths = vec![];
    for fd in &fds[..count as usize / size_of::<Fd>()] {
        if fd.kind != 1 {
            continue;
        }
        let mut info: FilePath = unsafe { std::mem::zeroed() };
        if unsafe {
            proc_pidfdinfo(
                pid as i32,
                fd.fd,
                2,
                (&mut info as *mut FilePath).cast(),
                size_of_val(&info) as i32,
            )
        } != size_of_val(&info) as i32
        {
            continue;
        }
        if info.node.node.stat.mode & 0xf000 != 0x8000 {
            continue;
        }
        let end = info
            .node
            .path
            .iter()
            .position(|b| *b == 0)
            .ok_or_else(invalid)?;
        used += end + 1;
        if used > 262_144 {
            return Err(invalid());
        }
        let path = PathBuf::from(String::from_utf8_lossy(&info.node.path[..end]).as_ref());
        if path.extension().is_some_and(|v| v == "jsonl") {
            paths.push(OpenFile {
                path,
                identity: FileIdentity {
                    device: info.node.node.stat.device.into(),
                    inode: info.node.node.stat.inode,
                },
            });
        }
    }
    Ok(paths)
}

#[repr(C)]
struct SocketBuffer {
    cc: u32,
    hiwat: u32,
    mbcnt: u32,
    mbmax: u32,
    lowat: u32,
    flags: i16,
    timeout: i16,
}
#[repr(C)]
struct UnixSocketInfo {
    connection: u64,
    pcb: u64,
    bound: [u8; 255],
    peer: [u8; 255],
}
// proc_info.h's protocol union has size/alignment identical to its largest
// member, un_sockinfo. It is read only after checking AF_UNIX/SOCKINFO_UN.
#[repr(C)]
struct SocketInfo {
    stat: Stat,
    socket: u64,
    pcb: u64,
    kind_type: i32,
    protocol: i32,
    family: i32,
    options: i16,
    linger: i16,
    state: i16,
    qlen: i16,
    incomplete: i16,
    qlimit: i16,
    timeout: i16,
    error: u16,
    oobmark: u32,
    receive: SocketBuffer,
    send: SocketBuffer,
    kind: i32,
    reserved: u32,
    unix: UnixSocketInfo,
}
#[repr(C)]
struct SocketFdInfo {
    file: FileInfo,
    socket: SocketInfo,
}
pub(super) fn unix_listeners(pid: i32) -> io::Result<Vec<std::path::PathBuf>> {
    use std::os::unix::ffi::OsStringExt;
    // SAFETY: integer-only descriptors, fixed initialized writable storage.
    let mut descriptors: Vec<Fd> = (0..8192).map(|_| unsafe { std::mem::zeroed() }).collect();
    // SAFETY: PROC_PIDLISTFDS=1, exact writable allocation and capacity.
    let count = unsafe {
        proc_pidinfo(
            pid,
            1,
            0,
            descriptors.as_mut_ptr().cast(),
            (descriptors.len() * size_of::<Fd>()) as i32,
        )
    };
    if count < 0
        || count as usize >= descriptors.len() * size_of::<Fd>()
        || !(count as usize).is_multiple_of(size_of::<Fd>())
    {
        return Err(invalid());
    }
    let mut paths = std::collections::BTreeSet::new();
    for fd in &descriptors[..count as usize / size_of::<Fd>()] {
        if fd.kind != 2 {
            continue;
        }
        // SAFETY: all fields are integers or arrays; zero is valid storage.
        let mut info: SocketFdInfo = unsafe { std::mem::zeroed() };
        // SAFETY: PROC_PIDFDSOCKETINFO=3 and the checked proc_info.h ABI.
        if unsafe {
            proc_pidfdinfo(
                pid,
                fd.fd,
                3,
                (&mut info as *mut SocketFdInfo).cast(),
                size_of_val(&info) as i32,
            )
        } != size_of_val(&info) as i32
        {
            continue;
        }
        if info.socket.family != 1
            || info.socket.kind != 3
            || info.socket.kind_type != 1
            || i32::from(info.socket.options) & 2 == 0
        {
            continue;
        }
        let address = &info.socket.unix.bound;
        let length = usize::from(address[0]);
        if address[1] != 1 as u8 || length < 3 || length > 106 {
            continue;
        }
        let path = &address[2..length];
        let path = &path[..path.iter().position(|b| *b == 0).unwrap_or(path.len())];
        if path.is_empty() {
            continue;
        }
        paths.insert(std::path::PathBuf::from(std::ffi::OsString::from_vec(
            path.to_vec(),
        )));
        if paths.len() > 128 {
            return Err(invalid());
        }
    }
    Ok(paths.into_iter().collect())
}
