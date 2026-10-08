//! Unchanged c1654cc proc counter policy, without serde or libc dependencies.
use super::{Counter, Cpu, Link, name};
#[cfg(target_os = "linux")]
use super::{Host, Scan};
#[cfg(target_os = "linux")]
use std::io;

pub(super) fn cpu(text: &str) -> Option<Vec<Cpu>> {
    let mut cpus = Vec::new();
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        let Some(name) = fields.next() else {
            continue;
        };
        if name != "cpu"
            && !name.strip_prefix("cpu").is_some_and(|value| {
                !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
            })
        {
            continue;
        }
        if cpus.len() >= 8193 {
            return None;
        }
        // Linux guest/guest_nice counters are already included in user/nice.
        let ticks: Option<Vec<u64>> = fields.take(8).map(|value| value.parse().ok()).collect();
        let ticks = ticks?;
        if ticks.len() < 4 {
            return None;
        }
        let total = ticks
            .iter()
            .try_fold(0u64, |sum, value| sum.checked_add(*value))?;
        let idle = ticks[3].checked_add(*ticks.get(4).unwrap_or(&0))?;
        cpus.push(Cpu {
            name: name.into(),
            busy: total.checked_sub(idle)?,
            total,
            ticks: None,
        });
    }
    if cpus.first()?.name != "cpu" {
        return None;
    }
    Some(cpus)
}

pub(super) fn network(text: &str) -> Option<Vec<Link>> {
    let mut interfaces = Vec::new();
    for line in text.lines().skip(2) {
        let (name, counters) = line.split_once(':')?;
        let name = name.trim();
        if name == "lo" {
            continue;
        }
        if name.is_empty() || name.len() > 64 || interfaces.len() >= 4096 {
            return None;
        }
        let counters: Option<Vec<u64>> = counters
            .split_whitespace()
            .map(|v| v.parse().ok())
            .collect();
        let counters = counters?;
        if counters.len() != 16 {
            return None;
        }
        interfaces.push(Link {
            name: name.into(),
            received: counters[0],
            sent: counters[8],
        });
    }
    interfaces.sort_by(|a, b| a.name.cmp(&b.name));
    if interfaces
        .windows(2)
        .any(|rows| rows[0].name == rows[1].name)
    {
        return None;
    }
    Some(interfaces)
}

pub(super) fn memory(text: &str) -> [Option<u64>; 4] {
    fn value(text: &str, key: &str) -> Option<u64> {
        let mut matches = text.lines().filter_map(|line| line.strip_prefix(key));
        let mut fields = matches.next()?.split_whitespace();
        let number = fields.next()?.parse::<u64>().ok()?.checked_mul(1024)?;
        if fields.next()? != "kB" || fields.next().is_some() || matches.next().is_some() {
            return None;
        }
        Some(number)
    }
    let total = value(text, "MemTotal:");
    let used = total
        .zip(value(text, "MemAvailable:"))
        .and_then(|(total, free)| total.checked_sub(free));
    let swap = value(text, "SwapTotal:");
    let swapped = swap
        .zip(value(text, "SwapFree:"))
        .and_then(|(total, free)| total.checked_sub(free));
    [total, used, swap, swapped]
}

#[cfg(target_os = "linux")]
pub(super) fn host(host: &mut Host) {
    host.cpu = super::text("/proc/stat", 1_048_576)
        .ok()
        .and_then(|value| cpu(&value));
    host.network = super::text("/proc/net/dev", 262_144)
        .ok()
        .and_then(|value| network(&value));
    if let Ok(text) = super::text("/proc/meminfo", 65_536) {
        host.memory = memory(&text);
    }
    host.load = super::text("/proc/loadavg", 1024).ok().and_then(|text| {
        let values: Option<Vec<f64>> = text
            .split_whitespace()
            .take(3)
            .map(|v| v.parse::<f64>().ok().filter(|v| v.is_finite() && *v >= 0.0))
            .collect();
        values.filter(|values| values.len() == 3)
    });
    host.uptime = super::text("/proc/uptime", 1024)
        .ok()
        .and_then(|text| text.split_whitespace().next()?.parse::<f64>().ok())
        .filter(|value| value.is_finite() && *value >= 0.0);
}

pub(super) fn row(bytes: &[u8], pid: i32, ticks: u64, page: u64) -> Option<Counter> {
    if bytes.len() > 16 * 1024 || pid <= 0 || ticks == 0 || page == 0 {
        return None;
    }
    let left = bytes.iter().position(|byte| *byte == b'(')?;
    let right = bytes.iter().rposition(|byte| *byte == b')')?;
    if left >= right
        || std::str::from_utf8(&bytes[..left])
            .ok()?
            .trim()
            .parse::<i32>()
            .ok()?
            != pid
    {
        return None;
    }
    let fields: Vec<_> = std::str::from_utf8(&bytes[right + 1..])
        .ok()?
        .split_whitespace()
        .collect();
    let user = fields.get(11)?.parse::<u64>().ok()?;
    let system = fields.get(12)?.parse::<u64>().ok()?;
    let start = fields.get(19)?.parse::<u64>().ok()?;
    let rss = fields.get(21)?.parse::<u64>().ok()?.checked_mul(page)?;
    let nanos = u128::from(user.checked_add(system)?) * 1_000_000_000 / u128::from(ticks);
    Some(Counter {
        pid,
        start: start.to_string(),
        name: name(&bytes[left + 1..right]),
        nanos: nanos.try_into().ok()?,
        rss,
    })
}

#[cfg(target_os = "linux")]
pub(super) fn processes(scan: &mut Scan, units: [u64; 4]) -> io::Result<()> {
    let mut candidates = 0;
    for entry in std::fs::read_dir("/proc")? {
        if scan.expired() {
            break;
        }
        let Ok(entry) = entry else {
            continue;
        };
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|value| value.parse::<i32>().ok())
            .filter(|value| *value > 0)
        else {
            continue;
        };
        if candidates == 4096 {
            scan.truncated = true;
            break;
        }
        candidates += 1;
        let read = |scan: &mut Scan| {
            let bytes = match super::super::inspect::bytes(&entry.path().join("stat"), 16 * 1024) {
                Ok(bytes) => bytes,
                Err(error) => {
                    if error.kind() == io::ErrorKind::InvalidData {
                        scan.truncated = true;
                    }
                    return None;
                }
            };
            row(&bytes, pid, units[0], units[1])
        };
        let Some(before) = read(scan) else {
            continue;
        };
        if scan.expired() {
            break;
        }
        let Some(after) = read(scan) else {
            continue;
        };
        if before.start != after.start || after.nanos < before.nanos {
            continue;
        }
        if !scan.push(after)? {
            break;
        }
    }
    Ok(())
}
