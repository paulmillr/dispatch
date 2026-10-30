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

Enable **Settings → Extra → Troubleshooting → Diagnostics** (off by default; applies live). After a disappearance, note the time and copy the logs before they rotate (2 × 4 MiB):

```sh
mkdir -p build/chat-viewport-capture && cp ~/Library/Logs/Dispatch/Diagnostics/* build/chat-viewport-capture/
```

`ChatViewportTrace` records geometry, row counts, scroll corrections, and watchdog decisions, at most 4 samples/s per viewport. It records no text, paths, hosts, or IDs; row IDs become in-memory HMAC tokens. Nothing is uploaded. Write failures go to unified log `yachts.dispatch.app`/`ChatViewport`. Read the sequence, not a single sample:

- Transcript rows > 0 but mounted rows = 0: realization gap.
- Mounted rows outside the clip rect: geometry/offset mismatch.
- `blank` → `recoveryRequested`/`rebuildRequested` → `recovered`: the watchdog's recovery.
- `rebuildRequested` with no `blank` before it: a rebuild in the same pass as a mass row change (a long group closing, a dropped turn, a page filling an empty transcript). `blank` then `rebuildRequested` within about 0.2 s: the check after layout settles. A rebuild that leaves the viewport blank is checked like a mount and retried after 2, 4, 8 … up to 30 s.
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

### Reply and send cost

Main-thread time a shown chat spends on one event, from a Release build-for-testing in the test VM (no Main Thread
Checker): two SSH hosts with remote tmux, three fixture Claude chats each (`scripts/claude_fixture.py`, prompt
`thinking tool long reply`, whose last reply is 82 markdown blocks). The main thread's CPU time is sampled every 50 ms;
a send is the 1.5 s after submit, a landing the reply's record arriving and its turn ending (0.5 s before to 2 s after),
both less the idle rate before the send. Median of three, 2026-10-28, the same tree with and without the changes:

| Main thread per event | before | after |
| --- | --- | --- |
| send, window shown | 237 ms | 230 ms |
| reply landing, window shown | 278 ms | 238 ms |
| send, window ordered out | 246 ms | 128 ms |
| reply landing, window ordered out | 286 ms | 61 ms |
| send to five chats in other tabs | 72–99 ms | 67–99 ms |

The window off screen holds its transcript (`ChatSession.holdTranscript`, [architecture](architecture.md)); what is
left there is outside the transcript (composer, sidebar, tabs, chat coordination). Shown, about half of a landing is the
reply's entrance (the 0.22 s fade and the followed bottom's glide: a SwiftUI render, a commit and the newly exposed text
drawn each frame) and a third the new row's first layout; a send is mostly its frames (the message's flight, the
composer folding). The text views themselves no longer show: a block's text is built and measured only when it changes
(`ChatTextMetrics`), and none posts frame notifications.

## SSH traffic of a remote host

Measured on the SSH host, not the Mac (the app cannot be sampled from there): `nettop -P -x -L 12 -s 5 -J
bytes_in,bytes_out,packets_in,packets_out` filtered to the `sshd-session: <user>@…` process the app's ControlMaster
connection owns (one process carries the helper channel and every terminal); `tmux list-windows -F
'#{window_index} #{window_activity}'` before and after says which panes produced output; `tmux capture-pane -p -t %N |
wc -c` sizes a screen. Five Claude Code panes of 132×64 in the user's tmux server, two of them busy (a spinner and
tool output), the Mac on Wi‑Fi.

| | 2026-10-27 before `screens.host` / `terminals.follow` | 2026-10-27 after |
| --- | --- | --- |
| app → host | ~49 KB/s, ~14 packets/s | ~0.03–0.08 KB/s, ~0.4–0.7 packets/s |
| host → app | ~5 KB/s, ~29 packets/s (mostly ACKs) | ~0.3–7 KB/s, ~1 packet/s (agent output and chat records, in bursts) |
| one session's total | 432 MB in, 52 MB out | 0.14 MB in, 6.7 MB out after its first hour |
| host CPU | sshd 0.3 %, helper 0.8 % | sshd 0 %, helper 0.9 % |

Before, the app published every terminal's full screen text (3–9 KB) on every TUI repaint, 5–8 times a second per busy
chat, hidden chat tabs included (`terminals.publish`), and the link never went quiet. After, the helper reads tmux and
herdr screens itself (`screens.host`), hidden chat terminals send no output (`terminals.follow`), and the idle
cadences are latency 60 s, stats 15 s shown / 60 s hidden, branch 10 s shown / 60 s hidden. The remaining traffic is
what the agents produce.

## Build profiling

Keep DerivedData. `python3 scripts/profile-build.py --label L [--clean] [--diagnostics] [--cache]` writes to `tmp/profiling/compilation/`, and `bash scripts/build.sh -showBuildTimingSummary` lists build tasks. Compiler caching (`COMPILATION_CACHE_ENABLE_CACHING=YES SWIFT_ENABLE_EXPLICIT_MODULES=YES`) speeds clean builds (about 55 s to 4 s once the cache is warm) but slows every edit (about +0.8 s for a body change, 15 s to 22 s for an interface change), so it's opt-in.
