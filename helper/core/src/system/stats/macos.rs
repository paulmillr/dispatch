//! Native Darwin facts, copied before their OS allocations are released.
use super::{Cpu, Disk, Host, Link, Scan, darwin::*, ffi, invalid};
use std::{
    ffi::CStr,
    io,
    mem::{MaybeUninit, size_of},
    process::Command,
    ptr,
};

pub(in crate::system) fn sysctl(name: &CStr, capacity: usize) -> io::Result<Vec<u8>> {
    let mut bytes = vec![0; capacity];
    let mut length = bytes.len();
    // SAFETY: the kernel receives exactly the output capacity, with no input value.
    if unsafe {
        sysctlbyname(
            name.as_ptr(),
            bytes.as_mut_ptr().cast(),
            &mut length,
            ptr::null_mut(),
            0,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    if length > bytes.len() {
        return Err(invalid());
    }
    bytes.truncate(length);
    Ok(bytes)
}

pub(super) fn boot() -> io::Result<String> {
    sysctl(c"kern.uuid", 256)?;
    let bytes = sysctl(c"kern.bootsessionuuid", 256)?;
    Ok(String::from_utf8_lossy(&bytes)
        .trim_end_matches('\0')
        .into())
}

pub(super) fn host(host: &mut Host, local: bool) {
    // Each mach_host_self() adds a reference to the host port, and this runs in the long-lived helper (a
    // native job, every sample): one per sample, released at the end.
    // SAFETY: a scalar Mach call returning a send right this function owns.
    let port = unsafe { mach_host_self() };
    let (mut cores, mut count) = (0, 0);
    let mut info = ptr::null_mut();
    // SAFETY: Mach initializes an owned array and its exact element count on success.
    if unsafe { host_processor_info(port, 2, &mut cores, &mut info, &mut count) } == 0
        && !info.is_null()
    {
        if count as usize == cores as usize * 4 && (local || (cores > 0 && cores <= 8192)) {
            let mut rows = Vec::new();
            // SAFETY: successful Mach call reports this many initialized integers.
            for (index, values) in unsafe { std::slice::from_raw_parts(info, count as usize) }
                .as_chunks::<4>()
                .0
                .iter()
                .enumerate()
            {
                let ticks = values.map(|value| value as u32);
                let total = ticks.into_iter().map(u64::from).sum();
                rows.push(Cpu {
                    name: format!("cpu{index}"),
                    busy: total - u64::from(ticks[2]),
                    total,
                    ticks: local.then_some(ticks),
                });
            }
            rows.insert(
                0,
                Cpu {
                    name: "cpu".into(),
                    busy: rows.iter().map(|row| row.busy).sum(),
                    total: rows.iter().map(|row| row.total).sum(),
                    ticks: None,
                },
            );
            host.cpu = Some(rows);
        }
        // SAFETY: release the exact allocation Mach returned, once after copying it.
        unsafe { vm_deallocate(mach_task_self_, info as usize, count as usize * 4) };
    }
    host.memory[0] = sysctl(c"hw.memsize", 8)
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .map(u64::from_ne_bytes);
    let mut vm = MaybeUninit::<Vm>::zeroed();
    let mut length = (size_of::<Vm>() / size_of::<i32>()) as u32;
    // SAFETY: HOST_VM_INFO64 writes its complete native structure into this exact storage.
    if unsafe { host_statistics64(port, 4, vm.as_mut_ptr().cast(), &mut length) } == 0 {
        let vm = unsafe { vm.assume_init() };
        let pages = u64::from(vm.active_count)
            + u64::from(vm.inactive_count)
            + u64::from(vm.wire_count)
            + u64::from(vm.compressor_page_count);
        let reclaimable = u64::from(vm.external_page_count) + u64::from(vm.purgeable_count);
        // SAFETY: _SC_PAGESIZE is a scalar sysconf query.
        let page = unsafe { ffi::sysconf(29) };
        if page > 0 {
            host.memory[1] = host.memory[0]
                .map(|total| total.min(pages.saturating_sub(reclaimable) * page as u64));
        }
    }
    // SAFETY: release the one reference taken above; nothing uses the port after this.
    unsafe { mach_port_deallocate(mach_task_self_, port) };
    if let Ok(bytes) = sysctl(c"vm.swapusage", 32)
        && bytes.len() >= 24
    {
        host.memory[2] = bytes[..8].try_into().ok().map(u64::from_ne_bytes);
        host.memory[3] = bytes[16..24].try_into().ok().map(u64::from_ne_bytes);
    }
    let mut load = [0.0; 3];
    // SAFETY: exactly three writable doubles are passed to getloadavg.
    if unsafe { getloadavg(load.as_mut_ptr(), load.len() as i32) } == 3 {
        host.load = Some(load.to_vec());
    }
    // CLOCK_UPTIME_RAW matches local awake uptime; remote CLOCK_MONOTONIC_RAW includes sleep.
    host.uptime = ffi::clock(if local { 8 } else { 4 }).ok();
    if let Ok(mut rows) = interfaces((!local).then_some(4096)) {
        if local {
            host.time = ffi::time(true).ok();
            let mut names = std::collections::BTreeMap::new();
            for row in rows {
                names.insert(row.name.clone(), row);
            }
            rows = names.into_values().collect();
        } else {
            rows.sort_by(|a, b| a.name.cmp(&b.name));
        }
        host.network = Some(rows);
    }
}

/// Every interface's 64-bit byte counters, loopback left out, at most `limit`, from the interface MIB: the highest
/// index (net.link.generic.system.ifcount: CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT), then each
/// index's ifmibdata (net.link.generic.ifdata.<index>.general: …, IFMIB_IFDATA, index, IFDATA_GENERAL). getifaddrs and
/// NET_RT_IFLIST2 tell an account without Apple's network-statistics entitlement its counters cut to 32 bits (and
/// rounded to KiB): they wrap every 4 GiB, under a minute at 600 Mbit/s, so a background sample a minute after the
/// last could find a counter smaller and leave out the rate. A removed interface leaves its index unreadable: skipped.
fn interfaces(limit: Option<usize>) -> io::Result<Vec<Link>> {
    let (mut count, mut size) = (0i32, size_of::<i32>());
    let mut name = [4, 18, 0, 1, 1];
    // SAFETY: the kernel writes one int into this exact storage; no new value.
    if unsafe {
        sysctl_mib(
            name.as_mut_ptr(),
            5,
            (&raw mut count).cast(),
            &mut size,
            ptr::null(),
            0,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    let mut rows = Vec::new();
    for index in 1..=count.clamp(0, 65_535) {
        if limit.is_some_and(|limit| rows.len() == limit) {
            break;
        }
        let mut record = [0u8; 180];
        let mut length = record.len();
        let mut name = [4, 18, 0, 2, index, 1];
        // SAFETY: the kernel writes at most `length` bytes into this buffer and reports how many it wrote.
        if unsafe {
            sysctl_mib(
                name.as_mut_ptr(),
                6,
                record.as_mut_ptr().cast(),
                &mut length,
                ptr::null(),
                0,
            )
        } == 0
            && let Some(row) = link(&record[..length.min(record.len())])
        {
            rows.push(row);
        }
    }
    Ok(rows)
}

/// One ifmibdata as a link, None for loopback or a short record: the name (IFNAMSIZ 16 bytes, NUL-ended) at 0, the
/// interface flags at 20, its if_data64 at 52 (4-byte packed) with ifi_ibytes at 116 and ifi_obytes at 124.
pub(super) fn link(record: &[u8]) -> Option<Link> {
    let bytes = |at: usize, length: usize| record.get(at..at + length);
    let counter = |at: usize| Some(u64::from_ne_bytes(bytes(at, 8)?.try_into().ok()?));
    let flags = u32::from_ne_bytes(bytes(20, 4)?.try_into().ok()?);
    let name = bytes(0, 16)?;
    let name = &name[..name.iter().position(|byte| *byte == 0)?];
    if flags & 8 != 0 || name.is_empty() {
        return None; // IFF_LOOPBACK
    }
    Some(Link {
        name: String::from_utf8_lossy(name).into_owned(),
        received: counter(116)?,
        sent: counter(124)?,
    })
}

/// Moves this process, and the /bin/ps it starts, to Darwin's background band while the Mac is not busy: its
/// 1-minute load below its core count. Called only by the isolated `stats.processes` worker (system::isolated), a
/// process of its own. ps costs about 36 ms of CPU on a Mac with 1,500 processes, on a performance core at about
/// 3.5 W; in the background band it runs on the efficiency cores at about 0.18 W, taking 80 to 160 ms, so about a
/// fifth of the energy. On a busy Mac the band can wait more than a second, past the list's 750 ms budget, so then
/// the list keeps the default priority. A failure only leaves the default.
pub(in crate::system) fn background() {
    let mut load = [0.0; 1];
    let cores = std::thread::available_parallelism().map_or(1, usize::from) as f64;
    // SAFETY: exactly one writable double is passed to getloadavg.
    if unsafe { getloadavg(load.as_mut_ptr(), 1) } == 1 && load[0] < cores {
        // SAFETY: a scalar call on this process: PRIO_DARWIN_PROCESS (4), itself (0), PRIO_DARWIN_BG (0x1000),
        // which its children inherit.
        unsafe { setpriority(4, 0, 0x1000) };
    }
}

/// Every account's processes as /bin/ps lists them (stats.rs: why not proc_pidinfo). `cpu` is ps's %CPU,
/// the kernel's running average of each process's recent use (it decays over seconds), 100 being one
/// core: there at the first sample.
pub(super) fn processes(scan: &mut Scan) -> io::Result<()> {
    let mut command = Command::new("/bin/ps");
    // Numbers in the C format whatever the account's locale (ssh passes on the client's LANG and LC_*).
    command
        .args(["-axo", "pid=,pcpu=,rss=,comm="])
        .env_remove("LC_ALL")
        .env("LC_NUMERIC", "C");
    match super::super::process::run(command, Vec::new(), Some(scan.deadline()), usize::MAX)? {
        (status, bytes) if status.success() => super::ps(scan, &bytes),
        (status, _) => Err(io::Error::other(status.to_string())),
    }
}

pub(super) fn disks(rows: &mut Vec<Disk>) -> io::Result<()> {
    if let Some(row) = ffi::disk(&ffi::home()?)?
        && row.total > 0
    {
        rows.push(row);
    }
    // SAFETY: first query obtains the current native mount count without an output buffer.
    let count = unsafe { getfsstat(ptr::null_mut(), 0, 2) }; // MNT_NOWAIT.
    if count <= 0 {
        return Ok(());
    }
    let mut mounts = Vec::<MaybeUninit<ffi::Statfs>>::with_capacity(count as usize);
    let size =
        i32::try_from(mounts.capacity() * size_of::<ffi::Statfs>()).map_err(|_| invalid())?;
    // SAFETY: native mount storage has exactly the passed capacity; no references exist yet.
    let returned = unsafe { getfsstat(mounts.as_mut_ptr().cast(), size, 2) };
    if returned <= 0 {
        return Ok(());
    }
    // SAFETY: getfsstat initializes at most capacity full records, even if new mounts appeared.
    unsafe { mounts.set_len((returned as usize).min(mounts.capacity())) };
    for mount in mounts {
        let mount = unsafe { mount.assume_init() };
        if mount.flags & 0x1000 == 0 || mount.flags & 0x100000 != 0 {
            continue; // MNT_LOCAL and MNT_DONTBROWSE: Foundation's local/hidden volume filter.
        }
        let end = mount
            .mount
            .iter()
            .position(|byte| *byte == 0)
            .ok_or_else(invalid)?;
        let bytes: Vec<_> = mount.mount[..end].iter().map(|byte| *byte as u8).collect();
        let path = String::from_utf8_lossy(&bytes);
        if path == "/" || path.starts_with("/System/") {
            continue;
        }
        if let Some(row) = ffi::disk(&path)?
            && row.total > 0
        {
            rows.push(row);
        }
    }
    Ok(())
}
