//! Darwin 64-bit ABI verified against captured SDK headers; old fields match pinned libc.
use super::ffi::Statfs;
use std::ffi::{c_char, c_void};

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
    pub(super) fn getfsstat(value: *mut Statfs, size: i32, flags: i32) -> i32;
}
