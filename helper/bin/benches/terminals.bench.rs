//! Terminal latency and throughput through the real assembled helper (helper.md: "heavily
//! benched: 100+ terminals/sessions, latency and throughput"). Native backend, private HOME.
//! Run: cargo bench -p dispatch-helper --bench terminals [-- quick]
use dispatch_helper_core::{
    json::{Json, Value},
    wire::{self, Collector, Header, Kind, Received},
};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    path::Path,
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    time::{Duration, Instant},
};

static SPAWNED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

struct Helper {
    child: Child,
    input: ChildStdin,
    output: ChildStdout,
    serial: u64,
    /// Terminal output per attach stream, until taken.
    streams: BTreeMap<u64, Vec<u8>>,
    exited: BTreeMap<u64, i64>,
    /// When the first terminal output byte arrived.
    first: Option<Instant>,
    /// Chunked messages in progress, per request id.
    collectors: BTreeMap<u64, Collector>,
}

/// A panicking case still kills and reaps its helper.
impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Helper {
    fn spawn(root: &Path) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_dispatch-helper"));
        command
            .args(["--shell", "/bin/sh", "--cwd"])
            .arg(root)
            .current_dir(root)
            .env_clear()
            .env("HOME", root)
            .env("DISPATCH_TEST_ROOT", root)
            .env("PATH", "/usr/bin:/bin")
            .env("LANG", "C.UTF-8")
            // Opt-in IO capture for profiling: DISPATCH_BENCH_CAPTURE=<directory>, with --features capture.
            // DISPATCH_CAPTURE names one file: one per spawned helper.
            .envs(std::env::var_os("DISPATCH_BENCH_CAPTURE").map(|dir| {
                let n = SPAWNED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let file = format!("helper-{}-{n}.jsonl", std::process::id());
                ("DISPATCH_CAPTURE", Path::new(&dir).join(file).into_os_string())
            }))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        // The kernel kills the helper when this bench dies, even by SIGKILL, where Drop never runs.
        #[cfg(target_os = "linux")]
        unsafe {
            unsafe extern "C" {
                fn prctl(option: i32, ...) -> i32;
            }
            // PR_SET_PDEATHSIG = 1, SIGKILL = 9.
            std::os::unix::process::CommandExt::pre_exec(&mut command, || match prctl(1, 9) {
                0 => Ok(()),
                _ => Err(std::io::Error::last_os_error()),
            });
        }
        let mut child = command.spawn().unwrap();
        let (input, output) = (child.stdin.take().unwrap(), child.stdout.take().unwrap());
        Self {
            child,
            input,
            output,
            serial: 0,
            streams: BTreeMap::new(),
            exited: BTreeMap::new(),
            first: None,
            collectors: BTreeMap::new(),
        }
    }

    /// Request bodies are JSON until the binary wire flip switches this one encoder.
    fn send(&mut self, method: &str, params: &str) -> u64 {
        self.serial += 1;
        let body = format!(r#"{{"method":"{method}","params":{params}}}"#);
        let frame = wire::frame(Kind::Request, self.serial, body.as_bytes()).unwrap();
        self.input.write_all(&frame).unwrap();
        self.serial
    }

    /// One whole message (chunks joined by the shared Collector); terminal output and exits
    /// are filed under their stream id.
    fn next(&mut self) -> (Kind, u64, Json) {
        let (header, text) = loop {
            let mut head = [0; 13];
            self.output.read_exact(&mut head).unwrap();
            let header = Header::decode(&head, wire::LIMIT).unwrap();
            let mut body = vec![0; header.len as usize];
            self.output.read_exact(&mut body).unwrap();
            let collector = self
                .collectors
                .entry(header.id)
                .or_insert_with(|| Collector::new(header.id, wire::LIMIT as usize));
            if let Some(Received::Json(text)) = collector.push(header, &body).unwrap() {
                self.collectors.remove(&header.id);
                break (header, text);
            }
        };
        let value = Json::parse(&text).unwrap();
        let root = value.root();
        match root.get("method").and_then(Value::string) {
            Some("terminal.output") => {
                let bytes = root.get("params").unwrap().get("bytes").unwrap();
                let bytes = dispatch_helper_core::base64::decode(bytes).unwrap();
                self.first.get_or_insert_with(Instant::now);
                self.streams.entry(header.id).or_default().extend(bytes);
            }
            Some("terminal.exit") => {
                let status = root.get("params").and_then(|p| p.get("status"));
                self.exited
                    .insert(header.id, status.and_then(Value::signed).unwrap_or(-1));
            }
            _ => {}
        }
        (header.kind, header.id, value)
    }

    /// The response (or named notice) for one request; other frames are filed meanwhile.
    fn wait(&mut self, id: u64, notice: Option<&str>) -> Json {
        loop {
            let (kind, from, value) = self.next();
            let root = value.root();
            if from != id {
                continue;
            }
            assert!(root.get("error").is_none(), "{:?}", root.write());
            let named = root.get("method").and_then(Value::string);
            if kind == Kind::Response || (notice.is_some() && named == notice) {
                return value;
            }
        }
    }

    fn call(&mut self, method: &str, params: &str) -> Json {
        let id = self.send(method, params);
        self.wait(id, None)
    }
}

/// Native root, then `count` terminals running `command`, each attached; returns (terminal, stream).
fn terminals(helper: &mut Helper, count: usize, command: &str) -> Vec<(u64, u64)> {
    let list = helper.call("backends.list", "{}");
    let backends = list.root().get("result").unwrap();
    let native = backends
        .array()
        .unwrap()
        .find(|b| b.get("key").and_then(Value::string) == Some("native"))
        .expect("native backend");
    let mux = native.get("mux").unwrap().unsigned().unwrap();
    let open = helper.send("backends.open", &format!(r#"{{"mux":{mux},"key":"native"}}"#));
    let opened = helper.wait(open, Some("backend.opened"));
    let root = opened.root().get("params").unwrap().unsigned().unwrap();
    let command = json_string(command);
    (0..count)
        .map(|_| {
            let created = helper.call(
                "terminals.create",
                &format!(r#"{{"parent":{root},"command":{command}}}"#),
            );
            let terminal = created.root().get("result").unwrap().unsigned().unwrap();
            let stream = helper.send(
                "terminals.attach",
                &format!(r#"{{"terminal":{terminal},"rows":24,"columns":200}}"#),
            );
            helper.wait(stream, Some("terminal.attached"));
            (terminal, stream)
        })
        .collect()
}

fn json_string(text: &str) -> String {
    let mut out = Vec::new();
    wire::string(&mut out, text);
    String::from_utf8(out).unwrap()
}

fn cpu(pid: u32) -> f64 {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).unwrap();
    let fields: Vec<&str> = stat.rsplit_once(") ").unwrap().1.split(' ').collect();
    let ticks: f64 = fields[11].parse::<f64>().unwrap() + fields[12].parse::<f64>().unwrap();
    ticks / 100.0
}

/// Helper CPU seconds per thread name while `count` quiet terminals stay attached for 3s.
/// helper.md: "minimal amount of resources", events instead of polling.
fn idle(root: &Path, count: usize) {
    let mut helper = Helper::spawn(root);
    helper.call("hello", "{}");
    let pid = helper.child.id();
    terminals(&mut helper, count, "exec cat");
    let threads = || -> BTreeMap<String, f64> {
        let mut usage = BTreeMap::new();
        for task in std::fs::read_dir(format!("/proc/{pid}/task")).unwrap().flatten() {
            let stat = std::fs::read_to_string(task.path().join("stat")).unwrap_or_default();
            let Some((name, rest)) = stat.split_once(" (").and_then(|(_, r)| r.rsplit_once(") ")) else {
                continue;
            };
            let fields: Vec<&str> = rest.split(' ').collect();
            let ticks: f64 = fields[11].parse::<f64>().unwrap() + fields[12].parse::<f64>().unwrap();
            *usage.entry(name.to_owned()).or_default() += ticks / 100.0;
        }
        usage
    };
    let before = threads();
    std::thread::sleep(Duration::from_secs(3));
    let after = threads();
    let used: Vec<String> = after
        .iter()
        .map(|(name, t)| format!("{name}={:.2}s", t - before.get(name).copied().unwrap_or(0.0)))
        .collect();
    println!("idle     terminals={count:>3} over=3s helper_cpu {}", used.join(" "));
}

fn percentile(sorted: &[Duration], p: usize) -> Duration {
    sorted[(sorted.len() * p / 100).min(sorted.len() - 1)]
}

fn latency(root: &Path, count: usize, samples: usize) {
    let mut helper = Helper::spawn(root);
    helper.call("hello", "{}");
    let terminals = terminals(&mut helper, count, "exec cat");
    let mut times = Vec::with_capacity(samples);
    for round in 0..samples {
        let (terminal, stream) = terminals[round % terminals.len()];
        let marker = format!("m{round}x");
        let bytes: Vec<String> = format!("{marker}\n").bytes().map(|b| b.to_string()).collect();
        let start = Instant::now();
        helper.send(
            "terminals.input",
            &format!(r#"{{"terminal":{terminal},"bytes":[{}]}}"#, bytes.join(",")),
        );
        loop {
            let seen = helper.streams.get(&stream).is_some_and(|out| {
                out.windows(marker.len()).any(|w| w == marker.as_bytes())
            });
            if seen {
                break;
            }
            helper.next();
        }
        times.push(start.elapsed());
        helper.streams.remove(&stream);
    }
    times.sort();
    println!(
        "latency  terminals={count:>3} samples={samples} p50={:?} p90={:?} p99={:?} max={:?}",
        percentile(&times, 50),
        percentile(&times, 90),
        percentile(&times, 99),
        times[times.len() - 1]
    );
}

fn throughput(root: &Path, count: usize, size: usize) {
    let mut helper = Helper::spawn(root);
    helper.call("hello", "{}");
    let pid = helper.child.id();
    // Each terminal waits on its own input until every terminal is attached (a time-based
    // wait loses to a slow 100-terminal setup); then exactly `size` bytes, no newline.
    // One program: the macOS login prefix runs `exec -l <command>` (old TermApple/Launch.swift:
    // 248-259), which would replace the shell with its first word and drop the rest.
    let command = format!("sh -c \"read go; head -c {size} /dev/zero | tr '\\0' a\"");
    let terminals = terminals(&mut helper, count, &command);
    for (terminal, _) in &terminals {
        helper.call("terminals.input", &format!(r#"{{"terminal":{terminal},"bytes":[10]}}"#));
    }
    let cpu_before = cpu(pid);
    // Request round trips while output streams: a reply must not queue behind bulk output.
    let mut replies = Vec::new();
    let mut pending: Option<(u64, Instant)> = None;
    while terminals.iter().any(|(_, s)| !helper.exited.contains_key(s)) {
        if pending.is_none() && helper.first.is_some() {
            pending = Some((helper.send("echo", r#"{"value":1}"#), Instant::now()));
        }
        let (kind, id, _) = helper.next();
        if let Some((request, sent)) = pending
            && kind == Kind::Response
            && id == request
        {
            replies.push(sent.elapsed());
            pending = None;
        }
    }
    replies.sort();
    // From the first output byte to the last exit.
    let elapsed = helper.first.unwrap().elapsed();
    let received: Vec<usize> = terminals
        .iter()
        .map(|(_, s)| helper.streams.get(s).map_or(0, |out| out.iter().filter(|b| **b == b'a').count()))
        .collect();
    assert!(
        received.iter().all(|r| *r == size),
        "lost terminal output: {received:?}"
    );
    let total = (count * size) as f64 / (1 << 20) as f64;
    println!(
        "throughput terminals={count:>3} each={}KiB total={total:.0}MiB wall={:?} rate={:.1}MiB/s helper_cpu={:.2}s replies={} p50={:?} max={:?}",
        size >> 10,
        elapsed,
        total / elapsed.as_secs_f64(),
        cpu(pid) - cpu_before,
        replies.len(),
        replies.get(replies.len() / 2).copied().unwrap_or_default(),
        replies.last().copied().unwrap_or_default()
    );
}

fn main() {
    let quick = std::env::args().any(|a| a == "quick");
    let root = std::env::var_os("DISPATCH_TEST_ROOT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap())
        .join(format!("bench-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let scales: &[usize] = if quick { &[1, 10] } else { &[1, 10, 100] };
    if std::env::args().any(|a| a == "idle") {
        idle(&root, 10);
        return std::fs::remove_dir_all(&root).unwrap();
    }
    for &count in scales {
        latency(&root, count, if quick { 50 } else { 300 });
    }
    for &count in scales {
        idle(&root, count);
    }
    for &count in scales {
        throughput(&root, count, 1 << 20);
    }
    std::fs::remove_dir_all(&root).unwrap();
}
