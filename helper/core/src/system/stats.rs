//! c1654cc stats.rs/stats_processes.rs and HostMetrics: fixed-worker producers only.
#[cfg(target_os = "macos")]
mod darwin;
mod ffi;
pub(super) use ffi::available;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
pub(super) mod macos;

use crate::json::Data;
#[cfg(target_os = "linux")]
use std::path::Path;
use std::{
    io,
    time::{Duration, Instant},
};

fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn write(value: &Data<'_>) -> io::Result<Vec<u8>> {
    crate::wire::body::encode_plain(value).map_err(|_| invalid())
}
#[cfg(target_os = "linux")]
fn text(path: &str, limit: usize) -> io::Result<String> {
    String::from_utf8(super::inspect::bytes(Path::new(path), limit)?).map_err(|_| invalid())
}

fn boot() -> io::Result<String> {
    #[cfg(target_os = "linux")]
    let boot = {
        text("/etc/machine-id", 256)?;
        text("/proc/sys/kernel/random/boot_id", 256)?.trim().into()
    };
    #[cfg(target_os = "macos")]
    let boot = macos::boot()?;
    Ok(boot)
}

fn clocks(local: bool) -> io::Result<(String, f64)> {
    if synthetic() {
        return Ok((BOOT.into(), clock(local)?));
    }
    Ok((boot()?, time(local)?))
}

/// While capturing (DISPATCH_CAPTURE, a test instrument) the host's statistics would be recorded as they are: its
/// CPUs, memory, swap, load, uptime, boot, network interfaces and their traffic, its disks. A capture reports one fixed
/// synthetic host instead, the same on every machine (docs/capture_scrub.md); its counters grow with its clock, so
/// rates still come out. Replay answers the recorded values either way.
fn synthetic() -> bool {
    super::capture::control("DISPATCH_CAPTURE").is_some()
}
const BOOT: &str = if cfg!(target_os = "linux") {
    "bb000000-0000-4000-8000-000000000002"
} else {
    "BB000000-0000-4000-8000-000000000001"
};
/// The synthetic host's clock: a day of uptime, then the real clock's time into its current day. Each sample is an
/// isolated job of its own (a fresh process), so the clock must grow across processes: only a day's wrap goes back.
fn clock(local: bool) -> io::Result<f64> {
    Ok(86_400.0 + time(local)? % 86_400.0)
}
/// The synthetic host: four cores, each a quarter busy at 100 ticks a second; one interface with steady traffic;
/// 16 GiB of memory, half used, no swap; one 500 GB disk, half free.
fn fixture(operation: &str, local: bool) -> io::Result<Vec<u8>> {
    let time = clock(local)?;
    match operation {
        "stats.host" => {
            let ticks = (time * 100.0) as u64;
            // This Mac's cores also tell their ticks (user, system, idle, nice), as macos::host does.
            let split = [ticks / 8, ticks / 8, ticks - ticks / 4, 0].map(|value| value as u32);
            let core = |name: String| Cpu { name, busy: ticks / 4, total: ticks, ticks: local.then_some(split) };
            let mut cpu = vec![Cpu { name: "cpu".into(), busy: ticks, total: 4 * ticks, ticks: None }];
            cpu.extend((0..4).map(|index| core(format!("cpu{index}"))));
            let host = Host {
                cpu: Some(cpu),
                network: Some(vec![Link {
                    name: if cfg!(target_os = "linux") { "eth0" } else { "en0" }.into(),
                    received: 1_000_000 + (time * 2_000.0) as u64,
                    sent: 1_000_000 + (time * 1_000.0) as u64,
                }]),
                memory: [Some(16 << 30), Some(8 << 30), Some(0), Some(0)],
                load: Some(vec![1.0; 3]),
                uptime: Some(time),
                time: Some(time),
            };
            report(BOOT, time, &host)
        }
        "stats.disks" => {
            let mut paths = vec!["/".to_owned()];
            if !local {
                paths.push(ffi::home()?);
            }
            let disk = Disk { identity: [1, 1], paths, total: 500_000_000_000, free: 250_000_000_000 };
            write(&Data::Object(vec![("disks", Data::Array(vec![disk.data("1:1")]))]))
        }
        _ => Err(io::ErrorKind::Unsupported.into()),
    }
}

/// `stats.host`'s value: the boot, the clock and what the host told.
fn report(boot: &str, time: f64, host: &Host) -> io::Result<Vec<u8>> {
    let cpu = host
        .cpu
        .as_ref()
        .map(|v| Data::Array(v.iter().map(Cpu::data).collect()))
        .unwrap_or(Data::Null);
    let network = host
        .network
        .as_ref()
        .map(|v| Data::Array(v.iter().map(Link::data).collect()))
        .unwrap_or(Data::Null);
    let mut fields = vec![
        ("boot", Data::String(boot)),
        ("monotonic", Data::Real(host.time.unwrap_or(time))),
        ("cpu", cpu),
        ("network", network),
    ];
    for (key, value) in ["memoryTotal", "memoryUsed", "swapTotal", "swapUsed"]
        .into_iter()
        .zip(host.memory)
    {
        fields.push((key, value.map(Data::Unsigned).unwrap_or(Data::Null)));
    }
    fields.push((
        "load",
        host.load
            .as_ref()
            .map(|v| Data::Array(v.iter().copied().map(Data::Real).collect()))
            .unwrap_or(Data::Null),
    ));
    fields.push(("uptime", host.uptime.map(Data::Real).unwrap_or(Data::Null)));
    write(&Data::Object(fields))
}

fn time(local: bool) -> io::Result<f64> {
    ffi::time(local)
}

struct Cpu {
    name: String,
    busy: u64,
    total: u64,
    ticks: Option<[u32; 4]>,
}
impl Cpu {
    fn data(&self) -> Data<'_> {
        let mut fields = vec![
            ("name", Data::String(&self.name)),
            ("busy", Data::Unsigned(self.busy)),
            ("total", Data::Unsigned(self.total)),
        ];
        if let Some(ticks) = self.ticks {
            fields.push((
                "ticks",
                Data::Array(
                    ticks
                        .into_iter()
                        .map(|v| Data::Unsigned(v.into()))
                        .collect(),
                ),
            ));
        }
        Data::Object(fields)
    }
}
struct Link {
    name: String,
    received: u64,
    sent: u64,
}
impl Link {
    fn data(&self) -> Data<'_> {
        Data::Object(vec![
            ("name", Data::String(&self.name)),
            ("received", Data::Unsigned(self.received)),
            ("sent", Data::Unsigned(self.sent)),
        ])
    }
}
#[derive(Default)]
struct Host {
    cpu: Option<Vec<Cpu>>,
    network: Option<Vec<Link>>,
    memory: [Option<u64>; 4],
    load: Option<Vec<f64>>,
    uptime: Option<f64>,
    time: Option<f64>,
}

/// One process. Its CPU use is what the OS tells in one look: `cpu`, a percentage of one core (macOS),
/// or `nanos`, the CPU time used so far, with `start` telling this process from a later one with its pid
/// (Linux); the stats plugin turns the growth between two samples into a percentage.
struct Counter {
    pid: i32,
    start: Option<String>,
    name: String,
    cpu: Option<f64>,
    nanos: Option<u64>,
    rss: u64,
}
impl Counter {
    fn data(&self) -> Data<'_> {
        let fields = [
            Some(("pid", Data::Signed(self.pid.into()))),
            self.start.as_deref().map(|v| ("start", Data::String(v))),
            Some(("name", Data::String(&self.name))),
            self.cpu.map(|v| ("cpu", Data::Real(v))),
            self.nanos.map(|v| ("cpuNanos", Data::Unsigned(v))),
            Some(("rss", Data::Unsigned(self.rss))),
        ];
        Data::Object(fields.into_iter().flatten().collect())
    }
}

fn name(bytes: &[u8]) -> String {
    let mut result = String::new();
    for ch in String::from_utf8_lossy(bytes).chars() {
        let ch =
            if ch.is_control() || matches!(ch, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}') {
                ' '
            } else {
                ch
            };
        if result.len() + ch.len_utf8() > 128 {
            break;
        }
        result.push(ch);
    }
    let result = result.trim().to_owned();
    if result.is_empty() {
        "?".into()
    } else {
        result
    }
}

struct Scan {
    started: Instant,
    rows: Vec<Counter>,
    truncated: bool,
    bytes: usize,
}
impl Scan {
    /// The list's time budget, inside its job's 1 s.
    fn deadline(&self) -> Instant {
        self.started + Duration::from_millis(750)
    }
    #[cfg(target_os = "linux")]
    fn expired(&mut self) -> bool {
        if Instant::now() >= self.deadline() {
            self.truncated = true;
            return true;
        }
        false
    }
    fn push(&mut self, row: Counter) -> io::Result<bool> {
        let length = write(&row.data())?.len() + 1;
        // c1654cc protocol::PAYLOAD_LIMIT, independent of the larger helper wire limit; the stats
        // plugin takes at most 4096 rows.
        if self.rows.len() == 4096 || self.bytes + length > 1_048_576 {
            self.truncated = true;
            return Ok(false);
        }
        self.bytes += length;
        self.rows.push(row);
        Ok(true)
    }
}

struct Disk {
    identity: [i32; 2],
    paths: Vec<String>,
    total: u64,
    free: u64,
}
impl Disk {
    fn data<'a>(&'a self, identity: &'a str) -> Data<'a> {
        Data::Object(vec![
            (
                "paths",
                Data::Array(self.paths.iter().map(|v| Data::String(v)).collect()),
            ),
            ("identity", Data::String(identity)),
            ("total", Data::Unsigned(self.total)),
            ("free", Data::Unsigned(self.free)),
        ])
    }
}

/// `ps -o pid=,pcpu=,rss=,comm=` output: three aligned numbers (rss in KiB), then the executable's
/// path, spaces included; a row is named by the path's last component. A line that is no process row
/// is left out.
#[cfg(any(target_os = "macos", test))]
fn ps(scan: &mut Scan, output: &[u8]) -> io::Result<()> {
    let row = |line: &str| {
        let mut rest = line;
        let mut numbers = [""; 3];
        for number in &mut numbers {
            rest = rest.trim_start_matches([' ', '\t']);
            (*number, rest) = rest.split_at(rest.find([' ', '\t'])?);
        }
        let path = rest.trim_start_matches([' ', '\t']);
        if path.is_empty() {
            return None;
        }
        Some(Counter {
            pid: numbers[0].parse().ok().filter(|pid| *pid > 0)?,
            start: None,
            name: name(path.rsplit('/').next()?.as_bytes()),
            cpu: Some(
                numbers[1]
                    .parse()
                    .ok()
                    .filter(|cpu: &f64| cpu.is_finite() && *cpu >= 0.0)?,
            ),
            nanos: None,
            rss: numbers[2].parse::<u64>().ok()?.checked_mul(1024)?,
        })
    };
    for row in String::from_utf8_lossy(output).lines().filter_map(row) {
        if !scan.push(row)? {
            break;
        }
    }
    Ok(())
}

pub(super) fn native(operation: &str, local: bool) -> io::Result<Vec<u8>> {
    // c1654cc's local host/storage producer is Darwin-only; the process list has one producer per OS.
    #[cfg(target_os = "linux")]
    if local && operation != "stats.processes" {
        return Err(io::ErrorKind::Unsupported.into());
    }
    if synthetic() && operation != "stats.processes" {
        return fixture(operation, local);
    }
    match operation {
        "stats.host" => {
            let (boot, time) = clocks(local)?;
            let mut host = Host::default();
            #[cfg(target_os = "linux")]
            linux::host(&mut host);
            #[cfg(target_os = "macos")]
            macos::host(&mut host, local);
            report(&boot, time, &host)
        }
        // One process list per OS, the same for this Mac and an SSH host, as rows: a capture records the
        // list, not how it was made. macOS: /bin/ps. It is setuid root, so it sees every account's processes,
        // with a CPU % at once. The helper runs as an ordinary user, and proc_pidinfo refuses it other
        // accounts' task info (CPU time, memory): a scan of its own missed system processes, had only the
        // kernel's names (cut at 31 bytes) and no CPU % before a second sample. Linux: /proc, whose stat
        // files every account may read; a CPU % needs two samples (the stats plugin keeps the previous one).
        // Later: captures recording protocol messages rather than wire frames, so a scrub can drop the
        // processes a test does not need instead of masking them (docs/capture_scrub.md).
        "stats.processes" => {
            let mut scan = Scan {
                started: Instant::now(),
                rows: vec![],
                truncated: false,
                bytes: 1024,
            };
            let boot = if synthetic() { BOOT.into() } else { boot()? };
            #[cfg(target_os = "linux")]
            linux::processes(&mut scan, ffi::units()?)?;
            #[cfg(target_os = "macos")]
            macos::processes(&mut scan)?;
            let time = if synthetic() { clock(false)? } else { time(false)? };
            write(&Data::Object(vec![
                ("boot", Data::String(&boot)),
                ("monotonic", Data::Real(time)),
                ("truncated", Data::Bool(scan.truncated)),
                (
                    "processes",
                    Data::Array(scan.rows.iter().map(Counter::data).collect()),
                ),
            ]))
        }
        "stats.disks" => {
            let mut rows: Vec<Disk> = Vec::new();
            #[cfg(target_os = "macos")]
            if local {
                macos::disks(&mut rows)?;
            }
            if !local {
                let home = ffi::home()?;
                for path in ["/", home.as_str()] {
                    let Some(row) = ffi::disk(path)? else {
                        continue;
                    };
                    if let Some(existing) = rows.iter_mut().find(|v| v.identity == row.identity) {
                        existing.paths.push(path.into());
                    } else {
                        rows.push(row);
                    }
                }
            }
            let identities: Vec<_> = rows
                .iter()
                .map(|v| format!("{}:{}", v.identity[0], v.identity[1]))
                .collect();
            write(&Data::Object(vec![(
                "disks",
                Data::Array(
                    rows.iter()
                        .zip(&identities)
                        .map(|(row, id)| row.data(id))
                        .collect(),
                ),
            )]))
        }
        _ => Err(io::ErrorKind::Unsupported.into()),
    }
}

#[cfg(test)]
#[path = "stats.test.rs"]
mod tests;
