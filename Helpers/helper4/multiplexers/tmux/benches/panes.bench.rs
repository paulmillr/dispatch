//! tmux pane latency and throughput through the real tmux mux on core System (helper.md:38:
//! "heavily benched: 100+ terminals/sessions, latency and throughput"). Private socket under
//! DISPATCH_TEST_ROOT; tmux from DISPATCH_TMUX_EXECUTABLE.
//! Run: cargo bench -p dispatch-helper4-tmux --bench panes (cargo test runs a quick variant).
use dispatch_helper4_core::{api::*, system::System};
use dispatch_helper4_tmux::Tmux;
use std::{
    cell::RefCell,
    collections::BTreeMap,
    path::PathBuf,
    process::Command,
    rc::Rc,
    time::{Duration, Instant},
};

#[derive(Default)]
struct View {
    nodes: Vec<Node>,
    output: BTreeMap<Id, Vec<u8>>,
    /// Throughput counts bytes as they arrive (rescanning all output is quadratic).
    counts: BTreeMap<Id, usize>,
    first: Option<Instant>,
}
impl Ui for View {
    fn update(&mut self, update: Update) {
        match update {
            Update::Topology { nodes, .. } => self.nodes = nodes,
            Update::Output { terminal, bytes } => {
                self.first.get_or_insert_with(Instant::now);
                *self.counts.entry(terminal).or_default() +=
                    bytes.iter().filter(|b| **b == b'a').count();
                self.output.entry(terminal).or_default().extend(bytes);
            }
            _ => {}
        }
    }
}

struct Bench {
    io: System,
    mux: Tmux,
    ui: View,
    tmux: PathBuf,
    /// One server per run: kill-server returns before the old server has exited.
    socket: String,
    /// A bench must never hang a gate: every wait goes through pump, which fails here.
    limit: Instant,
}
static RUNS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
impl Bench {
    fn pump(&mut self) {
        self.io.callbacks();
        let (_, event) = self.io.next().unwrap();
        if matches!(event, Event::Timer { at } if at >= self.limit) {
            panic!(
                "tmux bench made no progress within its limit (socket {})",
                self.socket
            );
        }
        self.mux.event(&mut self.io, &mut self.ui, event);
    }
    fn call<T: 'static>(
        &mut self,
        start: impl FnOnce(&mut Tmux, &mut System, Done<T>),
    ) -> Result<T, Error> {
        let result = Rc::new(RefCell::new(None));
        let saved = result.clone();
        start(
            &mut self.mux,
            &mut self.io,
            Box::new(move |_, value| *saved.borrow_mut() = Some(value)),
        );
        loop {
            self.io.callbacks();
            if let Some(value) = result.borrow_mut().take() {
                return value;
            }
            self.pump();
        }
    }
    fn native(&self, args: &[&str]) {
        let status = Command::new(&self.tmux)
            .args(["-S", &self.socket, "-f", "/dev/null"])
            .args(args)
            .env_remove("TMUX")
            .status()
            .unwrap();
        assert!(status.success(), "{args:?}");
    }
    /// `count` panes running `command`, opened and attached through the mux.
    fn start(count: usize, command: &str) -> (Self, Vec<Id>) {
        let tmux = PathBuf::from(std::env::var_os("DISPATCH_TMUX_EXECUTABLE").unwrap());
        let mut bench = Bench {
            io: System::new(2, 128).unwrap(),
            mux: Tmux::new(tmux.clone()),
            ui: View::default(),
            tmux,
            socket: format!(
                "{}.sock",
                RUNS.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ),
            limit: Instant::now(),
        };
        bench.io.section("mux/tmux-bench");
        bench.limit = bench.io.now() + Duration::from_secs(60);
        bench.io.timer(bench.limit);
        bench.native(&["new-session", "-d", "-x", "80", "-y", "24", command]);
        for _ in 1..count {
            bench.native(&["new-window", "-d", command]);
        }
        let socket = bench.socket.clone();
        bench
            .call(|mux, io, done| mux.open(io, &socket, done))
            .unwrap();
        let terminals: Vec<Id> = loop {
            let ids: Vec<_> = bench
                .ui
                .nodes
                .iter()
                .filter(|n| n.kind == Kind::Terminal)
                .map(|n| n.id)
                .collect();
            if ids.len() == count {
                break ids;
            }
            bench.pump();
        };
        let grid = Grid {
            pixels: None,
            columns: 80,
            rows: 24,
        };
        for &id in &terminals {
            bench
                .call(|mux, io, done| mux.attach(io, id, grid, false, done))
                .unwrap();
        }
        bench.ui.output.clear();
        bench.ui.counts.clear();
        bench.ui.first = None;
        (bench, terminals)
    }
    fn stop(self) {
        self.native(&["kill-server"]);
    }
}

fn percentile(sorted: &[Duration], p: usize) -> Duration {
    sorted[(sorted.len() * p / 100).min(sorted.len() - 1)]
}

fn latency(count: usize, samples: usize) {
    let (mut bench, terminals) = Bench::start(count, "exec cat");
    let mut times = Vec::with_capacity(samples);
    for round in 0..samples {
        let terminal = terminals[round % terminals.len()];
        let marker = format!("m{round}x");
        let start = Instant::now();
        let input = format!("{marker}\n");
        bench
            .call(|mux, io, done| mux.input(io, terminal, input.as_bytes(), done))
            .unwrap();
        while !bench
            .ui
            .output
            .get(&terminal)
            .is_some_and(|out| out.windows(marker.len()).any(|w| w == marker.as_bytes()))
        {
            bench.pump();
        }
        times.push(start.elapsed());
        bench.ui.output.remove(&terminal);
    }
    times.sort();
    println!(
        "latency    panes={count:>3} samples={samples} p50={:?} p90={:?} p99={:?} max={:?}",
        percentile(&times, 50),
        percentile(&times, 90),
        percentile(&times, 99),
        times[times.len() - 1]
    );
    bench.stop();
}

fn throughput(count: usize, size: usize) {
    // Each pane waits for its own input until every pane is attached, then prints `size` bytes.
    let command = format!("sh -c \"read go; head -c {size} /dev/zero | tr '\\0' a; exec cat\"");
    let (mut bench, terminals) = Bench::start(count, &command);
    for &terminal in &terminals {
        bench
            .call(|mux, io, done| mux.input(io, terminal, b"\n", done))
            .unwrap();
    }
    let received = |ui: &View, id: &Id| ui.counts.get(id).copied().unwrap_or(0);
    while terminals.iter().any(|id| received(&bench.ui, id) < size) {
        bench.pump();
    }
    let elapsed = bench.ui.first.unwrap().elapsed();
    let lost: Vec<_> = terminals
        .iter()
        .map(|id| received(&bench.ui, id))
        .filter(|r| *r != size)
        .collect();
    assert!(lost.is_empty(), "pane output differs from {size}: {lost:?}");
    let total = (count * size) as f64 / (1 << 20) as f64;
    println!(
        "throughput panes={count:>3} each={}KiB total={total:.1}MiB wall={elapsed:?} rate={:.1}MiB/s",
        size >> 10,
        total / elapsed.as_secs_f64()
    );
    bench.stop();
}

fn main() {
    let full = std::env::args().any(|a| a == "--bench");
    // Like the live tests, run only where a tmux executable is configured.
    if std::env::var_os("DISPATCH_TMUX_EXECUTABLE").is_none() {
        println!("SKIPPED tmux bench: set DISPATCH_TMUX_EXECUTABLE");
        return;
    }
    // The mux verifies the server's absolute socket path, and Unix socket paths are short
    // (tmux itself refuses longer ones); deep test roots need a short bench directory.
    let root = std::env::var_os("DISPATCH_TMUX_BENCH_ROOT")
        .or_else(|| std::env::var_os("DISPATCH_TEST_ROOT"))
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap())
        .join(format!("tmux-bench-{}", std::process::id()));
    let socket = root.join("99.sock").into_os_string().len();
    if socket > 100 {
        println!(
            "SKIPPED tmux bench: socket path is {socket} bytes (Unix limit ~104); set DISPATCH_TMUX_BENCH_ROOT to a short directory"
        );
        return;
    }
    std::fs::create_dir_all(&root).unwrap();
    // System::new keeps its hook routes under DISPATCH_TEST_ROOT, else the real HOME.
    let home = std::env::var_os("HOME").map(PathBuf::from);
    assert!(home.as_ref().is_none_or(|home| !home.starts_with(&root)));
    // SAFETY: single-threaded here, before the first System.
    unsafe { std::env::set_var("DISPATCH_TEST_ROOT", &root) };
    // A relative socket keeps the Unix path short under deep test roots.
    std::env::set_current_dir(&root).unwrap();
    let scales: &[usize] = if full { &[1, 10, 100] } else { &[1, 10] };
    for &count in scales {
        latency(count, if full { 300 } else { 30 });
    }
    for &count in scales {
        throughput(count, if full { 1 << 20 } else { 64 << 10 });
    }
    std::env::set_current_dir(root.parent().unwrap()).unwrap();
    std::fs::remove_dir_all(&root).unwrap();
}
