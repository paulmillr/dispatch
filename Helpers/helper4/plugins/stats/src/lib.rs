//! Stats Plugin. Each connection gets its own `Stats::new(local)`.
//! Sampling happens only when the app requests it; every native effect uses system.rs.
//!
//! All three reserved jobs run in isolated workers (1 s host/process, 5 s disks).
//! Their Native payloads take UTF-8 JSON `{local:bool}` and return Bytes JSON:
//! - stats.host: {boot:string,monotonic:f64,cpu?:[{name:string,busy:u64,total:u64,
//!   ticks?:[u32;4]}],network?:[{name:string,received:u64,sent:u64}],memoryTotal?:u64,
//!   memoryUsed?:u64,swapTotal?:u64,swapUsed?:u64,load?:[f64],uptime?:f64}.
//!   Clocks are seconds, capacities bytes. Local Darwin ticks use Mach USER/SYSTEM/IDLE/NICE
//!   order and preserve UInt32 components. Native workers omit failed fields independently;
//!   an empty successful network list is []. Loopback is excluded. Local memory keeps
//!   HostSampler's physicalMemory/Mach reclaimable-page calculation and systemUptime.
//! - stats.processes remote: {boot:string,monotonic:f64,truncated:bool,
//!   processes:[{pid:i32,start:string,name:string,cpuNanos:u64,rss:u64}]}.
//!   Keep c1654cc's birth verification, name sanitization, cross-user display and 4096/750ms
//!   budgets. Denied/exited omissions are not truncation. Local: {boot:string,monotonic:f64,
//!   truncated:false,ps:string}; ps is exact /bin/ps -axo pid=,pcpu=,rss=,comm= stdout.
//!   Every collector failure surfaces as an error for local and remote requests.
//! - stats.disks: {disks:[{identity:string|u64,paths:[string],total:u64,free:u64}]}.
//!   String identity is the two signed32 fsid words joined by colon; packing into u64 is
//!   lossless. Remote workers merge root/passwd-home paths by fsid and use f_bavail.
//!   Local workers keep home first, then existing visible/local mounted-volume filtering.
//!
//! Memory/swap tuples are (total,used). Remote CPU uses the aggregate ratio, local CPU the
//! core mean. Local ps percentages are available immediately and may exceed 100.
pub mod native;

use dispatch_helper4_core::{
    api::{
        Disk, Done, Error, Event, Io, Job, Json, Output, Plugin, Row, Sample, Ui, Work, deferred,
    },
    json::{self, Data},
};
use std::{io, path::PathBuf, time::Duration};

enum Call {
    Sample(Done<Sample>),
    Processes(Done<(Vec<Row>, bool)>),
    Disks(Done<Vec<Disk>>),
}
impl Call {
    fn index(&self) -> usize {
        match self {
            Self::Sample(_) => 0,
            Self::Processes(_) => 1,
            Self::Disks(_) => 2,
        }
    }
    fn finish(
        self,
        io: &mut dyn Io,
        rates: &mut native::Rates,
        local: bool,
        reset: bool,
        fixture: bool,
        result: Result<Json, Error>,
    ) {
        let slot = self.index();
        match self {
            Self::Sample(done) => {
                let result = result.and_then(|v| {
                    let value = v.root();
                    if fixture && let Some(time) = clock(value) {
                        rates.host_at(value, local, time)
                    } else {
                        rates.host(value, local)
                    }
                });
                if reset && result.is_err() {
                    rates.failed(slot, local);
                }
                done(io, result);
            }
            Self::Processes(done) => {
                let result = result.and_then(|v| {
                    let value = v.root();
                    if fixture
                        && !local
                        && let Some(time) = clock(value)
                    {
                        rates.processes_at(value, time)
                    } else {
                        rates.processes(value, local)
                    }
                });
                if reset && result.is_err() {
                    rates.failed(slot, local);
                }
                done(io, result);
            }
            Self::Disks(done) => done(io, result.and_then(|v| native::disks(v.root()))),
        }
    }
}

struct Pending {
    work: Work,
    call: Call,
    cancelled: bool,
}

pub struct Stats {
    local: bool,
    fixture: Option<PathBuf>,
    rates: native::Rates,
    jobs: [Option<Pending>; 3],
    resets: Vec<([bool; 3], Done<()>)>,
}
impl Stats {
    pub fn new(local: bool) -> Self {
        Self {
            local,
            fixture: None,
            rates: native::Rates::default(),
            jobs: [None, None, None],
            resets: Vec::new(),
        }
    }
    /// Existing app unit fixtures use real file jobs and the same projection policy.
    pub fn fixture(directory: PathBuf, local: bool) -> Self {
        let mut stats = Self::new(local);
        stats.fixture = Some(directory);
        stats
    }
    fn submit(&mut self, io: &mut dyn Io, call: Call) {
        let slot = call.index();
        let name = ["stats.host", "stats.processes", "stats.disks"][slot];
        let result = if self.jobs[slot].is_some() {
            Err(Error {
                code: "stats_busy",
                message: String::new(),
            })
        } else {
            let job = match &self.fixture {
                Some(directory) => Ok(Job::Read {
                    path: directory.join(format!("{slot}.json")),
                    offset: 0,
                    length: u64::from(dispatch_helper4_core::wire::LIMIT),
                }),
                None => json::write(&Data::Object(vec![("local", Data::Bool(self.local))])).map(
                    |input| Job::Isolated {
                        name,
                        input,
                        deadline: io.now() + Duration::from_secs(if slot == 2 { 5 } else { 1 }),
                    },
                ),
            };
            job.and_then(|job| io.submit(job).map_err(failure))
        };
        match result {
            Ok(work) => {
                self.jobs[slot] = Some(Pending {
                    work,
                    call,
                    cancelled: false,
                });
            }
            Err(error) => call.finish(
                io,
                &mut self.rates,
                self.local,
                false,
                self.fixture.is_some(),
                Err(error),
            ),
        }
    }
    fn finish(&mut self, io: &mut dyn Io) {
        for (slots, done) in std::mem::take(&mut self.resets) {
            if slots
                .iter()
                .zip(&self.jobs)
                .any(|(selected, job)| *selected && job.is_some())
            {
                self.resets.push((slots, done));
            } else {
                done(io, Ok(()));
            }
        }
    }
}

fn clock(value: json::Value<'_>) -> Option<f64> {
    value.get("monotonic")?.string()?.parse().ok()
}

fn failure(error: io::Error) -> Error {
    Error {
        code: match error.kind() {
            io::ErrorKind::Interrupted => "cancelled",
            io::ErrorKind::Unsupported => "unsupported",
            _ => "io",
        },
        message: error.to_string(),
    }
}

impl Plugin for Stats {
    fn name(&self) -> &str {
        "stats"
    }
    /// Topics are sample, processes and disks; an empty list resets all three.
    fn reset(&mut self, io: &mut dyn Io, topics: &[String], done: Done<()>) {
        let names = ["sample", "processes", "disks"];
        if topics.iter().any(|topic| !names.contains(&topic.as_str())) {
            deferred(done)(
                io,
                Err(Error {
                    code: "stats_invalid",
                    message: String::new(),
                }),
            );
            return;
        }
        let slots = names.map(|name| topics.is_empty() || topics.iter().any(|topic| topic == name));
        for (slot, selected) in slots.into_iter().enumerate() {
            if selected {
                self.rates.reset(slot);
                if let Some(job) = &mut self.jobs[slot] {
                    job.cancelled = true;
                    io.cancel(job.work);
                }
            }
        }
        self.resets.push((slots, deferred(done)));
        self.finish(io);
    }
    fn sample(&mut self, io: &mut dyn Io, done: Done<Sample>) {
        self.submit(io, Call::Sample(deferred(done)));
    }
    fn processes(&mut self, io: &mut dyn Io, done: Done<(Vec<Row>, bool)>) {
        self.submit(io, Call::Processes(deferred(done)));
    }
    fn disks(&mut self, io: &mut dyn Io, done: Done<Vec<Disk>>) {
        self.submit(io, Call::Disks(deferred(done)));
    }
    fn event(&mut self, io: &mut dyn Io, _ui: &mut dyn Ui, event: Event) {
        let Event::Done { work, result } = event else {
            return;
        };
        let Some(slot) = self
            .jobs
            .iter()
            .position(|j| j.as_ref().is_some_and(|job| job.work == work))
        else {
            return;
        };
        let job = self.jobs[slot].take().unwrap();
        let result = if job.cancelled {
            Err(io::ErrorKind::Interrupted.into())
        } else {
            result
        };
        // Core delivers physical cancellation completion. Free the job slot, but
        // do not advance or invalidate its last successful counter baseline.
        let reset = !result
            .as_ref()
            .is_err_and(|e| e.kind() == io::ErrorKind::Interrupted);
        let result = result.map_err(failure).and_then(|out| match out {
            Output::Bytes(bytes) => Json::parse(&bytes),
            Output::Read { bytes, .. } if self.fixture.is_some() => Json::parse(&bytes),
            _ => Err(Error {
                code: "stats_output",
                message: String::new(),
            }),
        });
        job.call.finish(
            io,
            &mut self.rates,
            self.local,
            reset,
            self.fixture.is_some(),
            result,
        );
        self.finish(io);
    }
}
