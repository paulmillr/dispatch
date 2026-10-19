# Dispatch benchmarks

Results are informational: no timing threshold fails a build. Every script takes `--help`.

## Unified runner: `scripts/benchmark.py`

Builds optimized production code, runs workloads serially in fresh processes (3 by default), keeps raw samples, and compares runs.

```sh
python3 scripts/benchmark.py run --suite core --environment hardware --label before
python3 scripts/benchmark.py run --suite core --environment hardware --label after
python3 scripts/benchmark.py compare before after --output build/benchmarks/comparison.json
python3 scripts/benchmark.py run --suite full --environment vm --desktop --label full-before   # inside the VM
```

| Suite | Adds |
|---|---|
| core | Headless; needs only Xcode. herdr line buffering, tmux unescaping (64 KiB/2 MiB), colored-output filtering, fragmented tmux framing (1/64 KiB reads) |
| quick | Chat history scrolling, code preview resizing |
| full | Space/tab switching, splits/resize, local/SSH/tmux/herdr input and scrollback, sidebar at 40/240 spaces, settings open/scroll, terminal lifecycle, idle terminals, concurrent output while switching, dense chat paging |
| soak | Longer idle and mixed-output phases; `--duration` is seconds **per phase** |

- Desktop suites (`quick` and up) need `--desktop`, prepared offline dependencies, a current generated project, and an unlocked, idle desktop. Use the [VM](vm_testing.md) or a dedicated Mac, never alongside another desktop test runner. `--environment` is only a label: the runner doesn't boot or control a VM.
- The `full` and `soak` SSH workload needs a root-owned sshd, because Release helpers always check for one. The runner uses the first running `dispatch-*` Lima VM that accepts a non-interactive SSH login (never `dispatch-manual-ssh`). Without one, it uses the loopback sshd if `sudo -n` works, as in the test VM. Otherwise it skips the four `ssh-*` metrics and says so. `report.json` records the choice as `ssh_backend`.
- Missing dependencies, skipped tests, failed assertions, incomplete reports, or source changes during a run fail it. Labels never overwrite existing runs. `--runs 1` checks the harness, not performance.
- Artifacts: `build/benchmarks/<label>/report.json` (revision, content hash, hardware/OS, tool versions, power, display, raw samples) plus per-repetition logs and xcresults.

**What the numbers mean**
- CPU and memory cover the test-host process only, not its children. Sampled peak RSS is a lower bound.
- Heartbeat gaps measure main-thread scheduling, not display frames. UI latency ends at layout/display submission or observed text, not scanout.
- Terminal lifecycle includes fixture window/runtime/tmux setup. It is not app launch time.
- `compare` prints median changes. The JSON adds p95 only at ≥20 observations and p99 at ≥1,000, and omits percent change for zero or negative baselines.
- `compare` rejects mismatched environment, configuration, SSH backend, suite version, duration, repetitions, metrics/units, or fixed sample counts. Never pool hardware and VM runs. Keep display, power, and tools fixed, and alternate before/after runs to probe noise.

**Adding a workload:** exercise production code and assert correct output. Keep fixture setup and compilation outside timed sections. Register UI workloads in `QUICK`/`FULL` and their reports in `EXPECTED`, and bump `VERSION` whenever fixtures, measurement boundaries, or semantics change. Core workloads live in `scripts/benchmarks/CoreBenchmark.swift`. Harness self-tests: `python3 test/benchmark.py`.

## Specialized scripts

| Script | Measures | Notes |
|---|---|---|
| `benchmark-terminal-throughput.py` | Any terminal's consume speed, writer stalls, and CPU per MB | Run *inside* the terminal under test (Dispatch, Ghostty, Terminal.app…). `--ceiling`: the pty's own limit on this machine. `--self-test`: checks for loss or reordering (also an XCTest). Uses no Dispatch code. |
| `benchmark-terminal-fps.py --label L` | Distinct composited frames with contrast off/on | Hardware desktop. Frame-numbered output captured from its own window, so duplicate captures can't inflate FPS. Includes capture overhead, not panel scanout, and is capped by the display refresh rate. Output in `build/terminal-fps-benchmark/`. |
| `benchmark-long-chat.py --label L` | Native transcript reader and chat view on large synthetic JSONL | No CLI, network, or personal data. `--profile` timings are diagnostic only. |
| `benchmark-chat-scroll.py SESSION --label L` | Scrolling a real, chosen Codex conversation | Uses personal history. Supports profiler captures. |
| `benchmark-host-scaling.py --label L` | 1–4 remote hosts with Thinking animation: scrolling, switching, typing, idle CPU | Needs `dispatch-perf-{1..4}` Linux guests from `scripts/ssh-vm.py`. `--backend tmux` (default) or `ssh`. |

`--no-build` reuses the last products. Use it only if their sources haven't changed. Build profiling is [below](#build-profiling).

## Chat rendering

### Viewport trace (disappearing transcripts)

Enable **Settings → Behavior → Advanced → Diagnostics** (off by default; applies live). After a disappearance, note the time and copy the logs before they rotate (2 × 4 MiB):

```sh
mkdir -p build/chat-viewport-capture && cp ~/Library/Logs/Dispatch/Diagnostics/* build/chat-viewport-capture/
```

`ChatViewportTrace` records geometry, row counts, scroll corrections, and watchdog decisions, at most 4 samples/s per viewport. It records no text, paths, hosts, or IDs; row IDs become in-memory HMAC tokens. Nothing is uploaded. Write failures go to unified log `yachts.dispatch.app`/`ChatViewport`. Read the sequence, not a single sample:

- Transcript rows > 0 but mounted rows = 0: realization gap.
- Mounted rows outside the clip rect: geometry/offset mismatch.
- `blank` → `recoveryRequested`/`rebuildRequested` → `recovered`: the watchdog's recovery.
- Visible markers throughout: content, drawing, or compositing. Markers don't prove pixels reached the screen; confirm with a screen recording or Instruments.

Leave the trace off for performance baselines. `DISPATCH_CHAT_VIEWPORT_TRACE=0` suppresses it without changing the setting, and `DISPATCH_TESTING=1` disables the production sink.

### Measuring frame presentation

Repeatable runs: `benchmark-long-chat.py` (synthetic) and `benchmark-chat-scroll.py` (a real conversation) (above). For a real conversation without a network, use the [offline Codex fixture](../test/README.md#offline-codex-scrolling-fixture). These don't reproduce full-screen, Adaptive-refresh, or SSH-specific issues, and their display-link callbacks are not presented FPS. To measure actual frame presentation, capture in the failing environment:

```sh
xcrun xctrace record --template 'Animation Hitches' --attach <dispatch-pid> --time-limit 20s --output build/chat-profile/windowed.trace
python3 scripts/export-chat-rendering.py build/chat-profile/*.trace --output-dir build/chat-profile/exported
```

- Scroll for about 10 s, then repeat in full screen with the same display, refresh setting, section, and gesture.
- Use `Time Profiler` for CPU, in a separate capture. Keep instrumented runs apart from timing comparisons.
- Export with the recording Xcode or newer; older versions fail with `Missing features`.
- Traces contain paths and process metadata. Review them before sharing.

Report presented-frame intervals (median/p95/p99, long gaps) separately from app work (main-thread stacks, layout, commits). The original bug had 8.3 ms app commits but 97.9 ms presented intervals, with zero Hitches reported.

## Build profiling

Keep DerivedData. `python3 scripts/profile-build.py --label L [--clean] [--diagnostics] [--cache]` writes to `tmp/profiling/compilation/`, and `bash scripts/build.sh -showBuildTimingSummary` lists build tasks. Compiler caching (`COMPILATION_CACHE_ENABLE_CACHING=YES SWIFT_ENABLE_EXPLICIT_MODULES=YES`) speeds clean builds (about 55 s to 4 s once the cache is warm) but slows every edit (about +0.8 s for a body change, 15 s to 22 s for an interface change), so it's opt-in.
