//! c1654cc stats.rs/stats_processes.rs and HostMetrics: fixed-worker producers only.
#[cfg(target_os = "macos")]
mod darwin;
mod ffi;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
pub(super) mod macos;

use crate::json::{self, Data};
#[cfg(target_os = "linux")]
use std::path::Path;
use std::{
    io,
    process::Command,
    time::{Duration, Instant},
};

fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn write(value: &Data<'_>) -> io::Result<Vec<u8>> {
    json::write(value).map_err(|_| invalid())
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
    Ok((boot()?, time(local)?))
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

struct Counter {
    pid: i32,
    start: String,
    name: String,
    nanos: u64,
    rss: u64,
}
impl Counter {
    fn data(&self) -> Data<'_> {
        Data::Object(vec![
            ("pid", Data::Signed(self.pid.into())),
            ("start", Data::String(&self.start)),
            ("name", Data::String(&self.name)),
            ("cpuNanos", Data::Unsigned(self.nanos)),
            ("rss", Data::Unsigned(self.rss)),
        ])
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
    fn expired(&mut self) -> bool {
        if self.started.elapsed() >= Duration::from_millis(750) {
            self.truncated = true;
            return true;
        }
        false
    }
    fn push(&mut self, row: Counter) -> io::Result<bool> {
        let length = write(&row.data())?.len() + 1;
        // c1654cc protocol::PAYLOAD_LIMIT, independent of the larger helper wire limit.
        if self.bytes + length > 1_048_576 {
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

fn ps(result: io::Result<Vec<u8>>) -> io::Result<Vec<u8>> {
    let bytes = result?;
    let (boot, time) = clocks(true)?;
    let ps = String::from_utf8_lossy(&bytes);
    write(&Data::Object(vec![
        ("boot", Data::String(&boot)),
        ("monotonic", Data::Real(time)),
        ("truncated", Data::Bool(false)),
        ("ps", Data::String(&ps)),
    ]))
}

pub(super) fn native(operation: &str, local: bool) -> io::Result<Vec<u8>> {
    // c1654cc's local host/storage producer is Darwin-only; local ps is also usable on Linux.
    #[cfg(target_os = "linux")]
    if local && operation != "stats.processes" {
        return Err(io::ErrorKind::Unsupported.into());
    }
    match operation {
        "stats.host" => {
            let (boot, time) = clocks(local)?;
            let mut host = Host::default();
            #[cfg(target_os = "linux")]
            linux::host(&mut host);
            #[cfg(target_os = "macos")]
            macos::host(&mut host, local);
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
                ("boot", Data::String(&boot)),
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
        "stats.processes" if local => {
            let mut command = Command::new("/bin/ps");
            command.args(["-axo", "pid=,pcpu=,rss=,comm="]);
            let result = super::process::run(command, Vec::new(), None, usize::MAX);
            ps(result.and_then(|(status, bytes)| {
                if status.success() {
                    Ok(bytes)
                } else {
                    Err(io::Error::other(status.to_string()))
                }
            }))
        }
        "stats.processes" => {
            let mut scan = Scan {
                started: Instant::now(),
                rows: vec![],
                truncated: false,
                bytes: 1024,
            };
            let boot = boot()?;
            let units = ffi::units()?;
            #[cfg(target_os = "linux")]
            linux::processes(&mut scan, units)?;
            #[cfg(target_os = "macos")]
            macos::processes(&mut scan, units)?;
            let time = time(false)?;
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
