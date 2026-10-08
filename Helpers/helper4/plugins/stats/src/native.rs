//! Native field projection and the c1654cc host/process rate policy.
use dispatch_helper4_core::{
    api::{Disk, Error, Row, Sample},
    json::Value,
};
use std::{
    collections::{HashMap, HashSet},
    path::Path,
};

struct Cpu {
    name: String,
    busy: u64,
    total: u64,
    ticks: Option<[u32; 4]>,
}
struct Link {
    name: String,
    received: u64,
    sent: u64,
}

#[derive(Default)]
pub struct Rates {
    cpu: History<Vec<Cpu>>,
    network: History<Vec<Link>>,
    processes: History<HashMap<u32, (String, u64)>>,
}
type History<T> = Option<(String, f64, T)>;

fn invalid() -> Error {
    Error {
        code: "stats_invalid",
        message: String::new(),
    }
}
fn count(value: Value<'_>, key: &str) -> Option<u64> {
    value.get(key)?.unsigned()
}
fn number(value: Value<'_>, key: &str) -> Option<f64> {
    value.get(key)?.number().filter(|n| n.is_finite())
}
fn text<'a>(value: Value<'a>, key: &str) -> Option<&'a str> {
    value.get(key)?.string()
}
fn safe(value: &str, limit: usize) -> bool {
    !value.is_empty()
        && value.len() <= limit
        && !value.chars().any(dispatch_helper4_core::text::control)
}

impl Rates {
    /// Errors invalidate only their own remote counter history. Local native field
    /// failures preserve Mach/getifaddrs history, as HostSampler does.
    pub fn failed(&mut self, slot: usize, local: bool) {
        if !local {
            self.reset(slot);
        }
    }

    pub fn reset(&mut self, slot: usize) {
        match slot {
            0 => {
                self.cpu = None;
                self.network = None;
            }
            1 => self.processes = None,
            _ => {}
        }
    }

    pub fn host(&mut self, value: Value<'_>, local: bool) -> Result<Sample, Error> {
        let time = number(value, "monotonic").ok_or_else(invalid)?;
        self.host_at(value, local, time)
    }

    pub fn host_at(&mut self, value: Value<'_>, local: bool, time: f64) -> Result<Sample, Error> {
        let boot = text(value, "boot").ok_or_else(invalid)?;
        let mut sample = Sample {
            boot: boot.into(),
            cpu_present: value.get("cpu").and_then(Value::array).is_some(),
            memory: count(value, "memoryTotal").zip(count(value, "memoryUsed")),
            swap: count(value, "swapTotal").zip(count(value, "swapUsed")),
            load: value
                .get("load")
                .and_then(Value::array)
                .map(|v| v.map(|n| n.number().ok_or_else(invalid)).collect())
                .transpose()?
                .unwrap_or_default(),
            uptime: number(value, "uptime").unwrap_or_default(),
            ..Sample::default()
        };
        let cpu: Option<Vec<Cpu>> = value
            .get("cpu")
            .and_then(Value::array)
            .map(|rows| {
                rows.map(|row| {
                    let ticks = row
                        .get("ticks")
                        .and_then(Value::array)
                        .map(|values| {
                            let values: Vec<u32> = values
                                .map(|v| {
                                    v.unsigned()
                                        .and_then(|v| u32::try_from(v).ok())
                                        .ok_or_else(invalid)
                                })
                                .collect::<Result<_, _>>()?;
                            values.try_into().map_err(|_| invalid())
                        })
                        .transpose()?;
                    Ok(Cpu {
                        name: text(row, "name").ok_or_else(invalid)?.into(),
                        busy: count(row, "busy").ok_or_else(invalid)?,
                        total: count(row, "total").ok_or_else(invalid)?,
                        ticks,
                    })
                })
                .collect::<Result<_, Error>>()
            })
            .transpose()?;
        let network: Option<Vec<Link>> = value
            .get("network")
            .and_then(Value::array)
            .map(|rows| {
                rows.map(|row| {
                    Ok(Link {
                        name: text(row, "name").ok_or_else(invalid)?.into(),
                        received: count(row, "received").ok_or_else(invalid)?,
                        sent: count(row, "sent").ok_or_else(invalid)?,
                    })
                })
                .collect::<Result<_, Error>>()
            })
            .transpose()?;

        if let Some(rows) = cpu {
            if local {
                let rows: Vec<Cpu> = rows.into_iter().filter(|r| r.name != "cpu").collect();
                let old = self.cpu.as_ref().map(|(_, _, rows)| rows);
                let mut valid = old.is_some_and(|old| old.len() == rows.len()) && !rows.is_empty();
                for (index, row) in rows.iter().enumerate() {
                    let ticks = row.ticks.ok_or_else(invalid)?;
                    let before = old
                        .and_then(|old| old.get(index))
                        .and_then(|r| r.ticks)
                        .unwrap_or(ticks);
                    valid &= ticks.iter().zip(before).all(|(now, old)| *now >= old);
                    let delta: [u64; 4] =
                        std::array::from_fn(|i| u64::from(ticks[i].wrapping_sub(before[i])));
                    let total: u64 = delta.iter().sum();
                    sample.cores.push(if total > 0 {
                        (total - delta[2]) as f64 / total as f64 * 100.0
                    } else {
                        0.0
                    });
                }
                if valid {
                    sample.cpu = Some(sample.cores.iter().sum::<f64>() / sample.cores.len() as f64);
                }
                self.cpu = Some((boot.into(), time, rows));
            } else {
                if let Some((prior, at, old)) = &self.cpu {
                    let elapsed = time - at;
                    if !boot.is_empty()
                        && prior == boot
                        && time > *at
                        && elapsed.is_finite()
                        && rows.len() <= 8193
                        && rows.len() == old.len()
                        && rows.first().is_some_and(|r| r.name == "cpu")
                        && rows.iter().map(|r| &r.name).collect::<HashSet<_>>().len() == rows.len()
                        && rows.iter().zip(old).all(|(r, o)| {
                            r.name == o.name
                                && r.total > o.total
                                && r.busy >= o.busy
                                && r.busy <= r.total
                                && o.busy <= o.total
                                && r.busy - o.busy <= r.total - o.total
                        })
                    {
                        let mut values = rows.iter().zip(old).map(|(r, o)| {
                            (r.busy - o.busy) as f64 / (r.total - o.total) as f64 * 100.0
                        });
                        sample.cpu = values.next();
                        sample.cores = values.collect();
                    }
                }
                self.cpu = Some((boot.into(), time, rows));
            }
        } else if !local {
            self.cpu = None;
        }

        if let Some(mut rows) = network {
            rows.sort_by(|a, b| a.name.cmp(&b.name));
            if let Some((prior, at, old)) = &self.network {
                let elapsed = time - at;
                if (local || (!boot.is_empty() && prior == boot))
                    && elapsed > 0.0
                    && elapsed.is_finite()
                    && (local || rows.len() <= 4096)
                    && rows.len() == old.len()
                    && rows.windows(2).all(|r| r[0].name != r[1].name)
                    && rows.iter().zip(old).all(|(r, o)| {
                        r.name == o.name && r.received >= o.received && r.sent >= o.sent
                    })
                {
                    let received = rows.iter().zip(old).fold(0.0, |n, (r, o)| {
                        n + (r.received - o.received) as f64 / elapsed
                    });
                    let sent = rows
                        .iter()
                        .zip(old)
                        .fold(0.0, |n, (r, o)| n + (r.sent - o.sent) as f64 / elapsed);
                    if received.is_finite() && sent.is_finite() {
                        sample.received_per_second = Some(received);
                        sample.sent_per_second = Some(sent);
                    }
                }
            }
            self.network = Some((boot.into(), time, rows));
        } else if !local {
            self.network = None;
        }
        Ok(sample)
    }

    pub fn processes(&mut self, value: Value<'_>, local: bool) -> Result<(Vec<Row>, bool), Error> {
        if local {
            return Ok((ps(text(value, "ps").ok_or_else(invalid)?), false));
        }
        let Some(time) = number(value, "monotonic") else {
            self.reset(1);
            return Err(invalid());
        };
        self.processes_at(value, time)
    }

    pub fn processes_at(&mut self, value: Value<'_>, time: f64) -> Result<(Vec<Row>, bool), Error> {
        let result = (|| {
            let boot = text(value, "boot")
                .filter(|s| safe(s, 256))
                .ok_or_else(invalid)?;
            if !time.is_finite() || time < 0.0 {
                return Err(invalid());
            }
            let truncated = value
                .get("truncated")
                .and_then(Value::boolean)
                .ok_or_else(invalid)?;
            let rows = value
                .get("processes")
                .and_then(Value::array)
                .ok_or_else(invalid)?;
            let before = self
                .processes
                .as_ref()
                .filter(|(prior, at, _)| prior == boot && time > *at && (time - at).is_finite());
            let mut current = HashMap::new();
            let mut output = Vec::new();
            for row in rows {
                let pid = count(row, "pid")
                    .filter(|p| *p > 0 && *p <= i32::MAX as u64)
                    .ok_or_else(invalid)? as u32;
                let start = text(row, "start")
                    .filter(|s| safe(s, 64))
                    .ok_or_else(invalid)?;
                let parts: Vec<&str> = start.split(':').collect();
                if !(1..=2).contains(&parts.len())
                    || parts.iter().any(|s| {
                        s.is_empty()
                            || !s.bytes().all(|b| b.is_ascii_digit())
                            || s.parse::<u64>().is_err()
                    })
                    || (parts.len() == 2
                        && parts[1].parse::<u64>().map_err(|_| invalid())? >= 1_000_000)
                {
                    return Err(invalid());
                }
                let name = text(row, "name")
                    .filter(|s| safe(s, 128))
                    .ok_or_else(invalid)?;
                let nanos = count(row, "cpuNanos").ok_or_else(invalid)?;
                let rss = count(row, "rss")
                    .filter(|r| *r <= i64::MAX as u64)
                    .ok_or_else(invalid)?;
                let cpu = before
                    .and_then(|(_, at, rows)| {
                        let (birth, old) = rows.get(&pid)?;
                        if birth != start {
                            return None;
                        }
                        let delta = nanos.checked_sub(*old)?;
                        Some(delta as f64 / 1_000_000_000.0 / (time - at) * 100.0)
                    })
                    .filter(|n| n.is_finite() && *n >= 0.0);
                if current.insert(pid, (start.into(), nanos)).is_some() || current.len() > 4096 {
                    return Err(invalid());
                }
                output.push(Row {
                    pid,
                    start: Some(start.into()),
                    name: name.into(),
                    cpu,
                    rss: Some(rss),
                });
            }
            Ok(((output, truncated), (boot.into(), time, current)))
        })();
        match result {
            Ok((output, counters)) => {
                self.processes = Some(counters);
                Ok(output)
            }
            Err(error) => {
                self.processes = None;
                Err(error)
            }
        }
    }
}

/// The exact three numeric columns followed by the entire command, including spaces.
pub fn ps(value: &str) -> Vec<Row> {
    value
        .lines()
        .filter_map(|line| {
            let mut rest = line;
            let mut fields = [""; 4];
            for field in &mut fields[..3] {
                rest = rest.trim_start_matches([' ', '\t']);
                let end = rest.find([' ', '\t'])?;
                *field = &rest[..end];
                rest = &rest[end..];
            }
            fields[3] = rest.trim_start_matches([' ', '\t']);
            if fields[3].is_empty() {
                return None;
            }
            Some(Row {
                pid: fields[0].parse().ok()?,
                start: None,
                name: Path::new(fields[3])
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or(fields[3])
                    .into(),
                cpu: Some(fields[1].parse().ok()?),
                rss: Some(fields[2].parse::<u64>().ok()?.checked_mul(1024)?),
            })
        })
        .collect()
}

pub fn disks(value: Value<'_>) -> Result<Vec<Disk>, Error> {
    value
        .get("disks")
        .and_then(Value::array)
        .ok_or_else(invalid)?
        .map(|row| {
            let identity = row.get("identity").ok_or_else(invalid)?;
            let identity = if let Some(identity) = identity.unsigned() {
                identity
            } else {
                let (a, b) = identity
                    .string()
                    .and_then(|s| s.split_once(':'))
                    .ok_or_else(invalid)?;
                let a = a.parse::<i32>().map_err(|_| invalid())? as u32;
                let b = b.parse::<i32>().map_err(|_| invalid())? as u32;
                u64::from(a) << u32::BITS | u64::from(b)
            };
            let total = count(row, "total").ok_or_else(invalid)?;
            let available = count(row, "free").ok_or_else(invalid)?.min(total);
            let paths = row
                .get("paths")
                .and_then(Value::array)
                .ok_or_else(invalid)?
                .map(|p| p.string().map(Into::into).ok_or_else(invalid))
                .collect::<Result<_, _>>()?;
            Ok(Disk {
                identity,
                paths,
                total,
                available,
            })
        })
        .collect()
}
