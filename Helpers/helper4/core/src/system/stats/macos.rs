//! Native Darwin facts, copied before their OS allocations are released.
use super::{Counter, Cpu, Disk, Host, Link, Scan, darwin::*, ffi, invalid, name};
use std::{
    ffi::CStr,
    io,
    mem::{MaybeUninit, size_of, size_of_val},
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

pub(super) fn timebase() -> io::Result<[u32; 2]> {
    let mut value = MaybeUninit::zeroed();
    // SAFETY: the kernel initializes both words in the native Mach timebase structure.
    if unsafe { mach_timebase_info(value.as_mut_ptr()) } != 0 {
        return Err(invalid());
    }
    let value = unsafe { value.assume_init() };
    if value.numer == 0 || value.denom == 0 {
        return Err(invalid());
    }
    Ok([value.numer, value.denom])
}

pub(super) fn host(host: &mut Host, local: bool) {
    let (mut cores, mut count) = (0, 0);
    let mut info = ptr::null_mut();
    // SAFETY: Mach initializes an owned array and its exact element count on success.
    if unsafe { host_processor_info(mach_host_self(), 2, &mut cores, &mut info, &mut count) } == 0
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
    if unsafe { host_statistics64(mach_host_self(), 4, vm.as_mut_ptr().cast(), &mut length) } == 0 {
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
    let mut interfaces = ptr::null_mut();
    // SAFETY: successful getifaddrs initializes an owned native linked list.
    if unsafe { getifaddrs(&mut interfaces) } == 0 {
        if local {
            host.time = ffi::time(true).ok();
        }
        let mut rows = Vec::new();
        let mut cursor = interfaces;
        loop {
            if cursor.is_null() || (!local && rows.len() == 4096) {
                break;
            }
            // SAFETY: cursor follows this live list; no pointers escape its lifetime.
            let entry = unsafe { &*cursor };
            cursor = entry.ifa_next;
            if entry.ifa_addr.is_null() || entry.ifa_data.is_null() || entry.ifa_flags & 8 != 0 {
                continue;
            }
            // SAFETY: Darwin sockaddr starts with two bytes, length and address family.
            let address = unsafe { &*entry.ifa_addr.cast::<[u8; 2]>() };
            if address[1] != 18 {
                continue;
            }
            let data = unsafe { &*entry.ifa_data };
            rows.push(Link {
                name: unsafe { CStr::from_ptr(entry.ifa_name) }
                    .to_string_lossy()
                    .into_owned(),
                received: data.ifi_ibytes.into(),
                sent: data.ifi_obytes.into(),
            });
        }
        // SAFETY: release the list once after copying its counters and names.
        unsafe { freeifaddrs(interfaces) };
        if local {
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

fn process(pid: i32) -> Option<Process> {
    let mut value = MaybeUninit::<Process>::zeroed();
    let size = size_of::<Process>() as i32;
    // SAFETY: PROC_PIDTASKALLINFO writes this exact structure; only full replies are accepted.
    if unsafe { proc_pidinfo(pid, 2, 0, value.as_mut_ptr(), size) } != size {
        return None;
    }
    let value = unsafe { value.assume_init() };
    if value.pbsd.pbi_pid != pid as u32 || value.pbsd.pbi_start_tvusec >= 1_000_000 {
        return None;
    }
    Some(value)
}

pub(super) fn processes(scan: &mut Scan, units: [u64; 4]) -> io::Result<()> {
    let mut pids = vec![0; 4097];
    // SAFETY: libproc receives the exact allocated buffer size in bytes.
    let count = unsafe { proc_listallpids(pids.as_mut_ptr(), size_of_val(pids.as_slice()) as i32) };
    if count <= 0 {
        return Err(io::Error::last_os_error());
    }
    scan.truncated = count > 4096;
    for pid in pids.into_iter().take((count as usize).min(4096)) {
        if scan.expired() {
            break;
        }
        if pid <= 0 {
            continue;
        }
        let Some(before) = process(pid) else { continue };
        if scan.expired() {
            break;
        }
        let Some(after) = process(pid) else { continue };
        let bsd = after.pbsd;
        if (before.pbsd.pbi_start_tvsec, before.pbsd.pbi_start_tvusec)
            != (bsd.pbi_start_tvsec, bsd.pbi_start_tvusec)
        {
            continue;
        }
        let Some(ticks) = after
            .ptinfo
            .pti_total_user
            .checked_add(after.ptinfo.pti_total_system)
        else {
            continue;
        };
        if ticks
            < before
                .ptinfo
                .pti_total_user
                .saturating_add(before.ptinfo.pti_total_system)
        {
            continue;
        }
        let Some(nanos) = (u128::from(ticks) * u128::from(units[2]) / u128::from(units[3]))
            .try_into()
            .ok()
        else {
            continue;
        };
        let raw = if bsd.pbi_name[0] != 0 {
            bsd.pbi_name.as_slice()
        } else {
            bsd.pbi_comm.as_slice()
        };
        let end = raw
            .iter()
            .position(|value| *value == 0)
            .unwrap_or(raw.len());
        if !scan.push(Counter {
            pid,
            start: format!("{}:{}", bsd.pbi_start_tvsec, bsd.pbi_start_tvusec),
            name: name(&raw[..end]),
            nanos,
            rss: after.ptinfo.pti_resident_size,
        })? {
            break;
        }
    }
    Ok(())
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
