//! Darwin 64-bit ABI verified against captured SDK headers; old fields match pinned libc.
use super::ffi::Statfs;
use std::ffi::{c_char, c_void};

#[repr(C)]
pub(super) struct Timebase {
    pub numer: u32,
    pub denom: u32,
}

#[repr(C)]
pub(super) struct Vm {
    pub free_count: u32,
    pub active_count: u32,
    pub inactive_count: u32,
    pub wire_count: u32,
    pub zero_fill_count: u64,
    pub reactivations: u64,
    pub pageins: u64,
    pub pageouts: u64,
    pub faults: u64,
    pub cow_faults: u64,
    pub lookups: u64,
    pub hits: u64,
    pub purges: u64,
    pub purgeable_count: u32,
    pub speculative_count: u32,
    pub decompressions: u64,
    pub compressions: u64,
    pub swapins: u64,
    pub swapouts: u64,
    pub compressor_page_count: u32,
    pub throttled_count: u32,
    pub external_page_count: u32,
    pub internal_page_count: u32,
    pub total_uncompressed_pages_in_compressor: u64,
    pub swapped_count: u64,
}

#[repr(C)]
pub(super) struct Bsd {
    pub pbi_flags: u32,
    pub pbi_status: u32,
    pub pbi_xstatus: u32,
    pub pbi_pid: u32,
    pub pbi_ppid: u32,
    pub pbi_uid: u32,
    pub pbi_gid: u32,
    pub pbi_ruid: u32,
    pub pbi_rgid: u32,
    pub pbi_svuid: u32,
    pub pbi_svgid: u32,
    pub rfu_1: u32,
    pub pbi_comm: [u8; 16],
    pub pbi_name: [u8; 32],
    pub pbi_nfiles: u32,
    pub pbi_pgid: u32,
    pub pbi_pjobc: u32,
    pub e_tdev: u32,
    pub e_tpgid: u32,
    pub pbi_nice: i32,
    pub pbi_start_tvsec: u64,
    pub pbi_start_tvusec: u64,
}

#[repr(C)]
pub(super) struct Task {
    pub pti_virtual_size: u64,
    pub pti_resident_size: u64,
    pub pti_total_user: u64,
    pub pti_total_system: u64,
    pub pti_threads_user: u64,
    pub pti_threads_system: u64,
    pub pti_policy: i32,
    pub pti_faults: i32,
    pub pti_pageins: i32,
    pub pti_cow_faults: i32,
    pub pti_messages_sent: i32,
    pub pti_messages_received: i32,
    pub pti_syscalls_mach: i32,
    pub pti_syscalls_unix: i32,
    pub pti_csw: i32,
    pub pti_threadnum: i32,
    pub pti_numrunning: i32,
    pub pti_priority: i32,
}

#[repr(C)]
pub(super) struct Process {
    pub pbsd: Bsd,
    pub ptinfo: Task,
}

#[repr(C)]
pub(super) struct Interfaces {
    pub ifa_next: *mut Interfaces,
    pub ifa_name: *mut c_char,
    pub ifa_flags: u32,
    pub ifa_addr: *mut c_void,
    pub ifa_netmask: *mut c_void,
    pub ifa_dstaddr: *mut c_void,
    pub ifa_data: *mut Interface,
}

#[repr(C)]
pub(super) struct Interface {
    pub ifi_type: u8,
    pub ifi_typelen: u8,
    pub ifi_physical: u8,
    pub ifi_addrlen: u8,
    pub ifi_hdrlen: u8,
    pub ifi_recvquota: u8,
    pub ifi_xmitquota: u8,
    pub ifi_unused1: u8,
    pub ifi_mtu: u32,
    pub ifi_metric: u32,
    pub ifi_baudrate: u32,
    pub ifi_ipackets: u32,
    pub ifi_ierrors: u32,
    pub ifi_opackets: u32,
    pub ifi_oerrors: u32,
    pub ifi_collisions: u32,
    pub ifi_ibytes: u32,
    pub ifi_obytes: u32,
    pub ifi_imcasts: u32,
    pub ifi_omcasts: u32,
    pub ifi_iqdrops: u32,
    pub ifi_noproto: u32,
    pub ifi_recvtiming: u32,
    pub ifi_xmittiming: u32,
    pub ifi_lastchange: [i32; 2],
    pub ifi_unused2: u32,
    pub ifi_hwassist: u32,
    pub ifi_reserved1: u32,
    pub ifi_reserved2: u32,
}

unsafe extern "C" {
    pub(super) fn sysctlbyname(
        name: *const c_char,
        old: *mut c_void,
        size: *mut usize,
        new: *mut c_void,
        length: usize,
    ) -> i32;
    pub(super) fn mach_timebase_info(value: *mut Timebase) -> i32;
    pub(super) fn mach_host_self() -> u32;
    pub(super) static mach_task_self_: u32;
    pub(super) fn host_processor_info(
        host: u32,
        flavor: i32,
        cores: *mut u32,
        info: *mut *mut i32,
        count: *mut u32,
    ) -> i32;
    pub(super) fn vm_deallocate(task: u32, address: usize, size: usize) -> i32;
    pub(super) fn host_statistics64(host: u32, flavor: i32, info: *mut i32, count: *mut u32)
    -> i32;
    pub(super) fn getloadavg(load: *mut f64, count: i32) -> i32;
    pub(super) fn getifaddrs(value: *mut *mut Interfaces) -> i32;
    pub(super) fn freeifaddrs(value: *mut Interfaces);
    pub(super) fn proc_listallpids(pids: *mut i32, size: i32) -> i32;
    pub(super) fn proc_pidinfo(
        pid: i32,
        flavor: i32,
        argument: u64,
        value: *mut Process,
        size: i32,
    ) -> i32;
    #[cfg_attr(target_arch = "x86_64", link_name = "getfsstat$INODE64")]
    pub(super) fn getfsstat(value: *mut Statfs, size: i32, flags: i32) -> i32;
}
