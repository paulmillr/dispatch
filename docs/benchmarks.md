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
| transcript | Cold chat mount, tab switching, streamed updates, wheel scrolling and idle cost |
| full | Space/tab switching, splits/resize, local/SSH/tmux/herdr input and scrollback, sidebar at 40/240 spaces, settings open/scroll, terminal lifecycle, idle terminals, concurrent output while switching, dense chat paging |
| soak | Longer idle and mixed-output phases; `--duration` is seconds **per phase** |

- Desktop suites (`quick` and up) need `--desktop`, prepared offline dependencies, a current generated project, and an unlocked, idle desktop. Use the [VM](vm_testing.md) or a dedicated Mac, never alongside another desktop test runner. `--environment` is only a label: the runner doesn't boot or control a VM.
- The `full` and `soak` SSH workload needs a root-owned sshd, because Release helpers always check for one. The runner uses the first running `dispatch-*` Lima VM that accepts a non-interactive SSH login (never `dispatch-manual-ssh`). Without one, it uses the loopback sshd if `sudo -n` works, as in the test VM. Otherwise it skips the two SSH workloads (`ssh-input-reply` and `ssh-terminal-scroll`) and says so. `report.json` records the choice as `ssh_backend`.
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
| `benchmark-long-chat.py --label L --foreground` | Native transcript reader and chat view on large synthetic JSONL | No CLI, network, or personal data. `--foreground` activates the isolated app and is required for UI measurements; omit it for reader measurements only. `--profile` timings are diagnostic only. |
| `benchmark-chat-frames.py --label L` | Mixed messages, expanded tools and streaming while scrolling; changed composited FPS, frame gaps, main-loop work, CPU and RSS | Three fresh Release processes; 120 Hz precise input; own-window capture. Identical harness required in both checkouts. `--profile` is diagnostic only. |
| `benchmark-chat-scroll.py SESSION --label L` | Scrolling a real, chosen Codex conversation | Uses personal history. Supports profiler captures. |
| `benchmark-host-scaling.py --label L` | 1–4 remote hosts with Thinking animation: scrolling, switching, typing, idle CPU | Needs `dispatch-perf-{1..4}` Linux guests from `scripts/ssh-vm.py`. `--backend tmux` (default) or `ssh`. |

`--no-build` reuses the last products. Use it only if their sources haven't changed. Build profiling is [below](#build-profiling).

## Chat rendering

### Viewport trace (disappearing transcripts)

Enable **Settings → Extra → Troubleshooting → Diagnostics** (off by default; applies live). After a disappearance, note the time and copy the logs before they rotate (2 × 4 MiB):

```sh
mkdir -p build/chat-viewport-capture && cp ~/Library/Logs/Dispatch/Diagnostics/* build/chat-viewport-capture/
```

`ChatViewportTrace` records geometry, row counts and scroll corrections on layout, input and visibility events, at most 4 samples/s per viewport. It records no text, paths, hosts, or IDs; row IDs become in-memory HMAC tokens. Nothing is uploaded. Write failures go to unified log `yachts.dispatch.app`/`ChatViewport`. Read the sequence, not a single sample:

- Transcript rows > 0 but mounted rows = 0: realization gap.
- Mounted rows outside the clip rect: geometry/offset mismatch.
- Older captures can contain `watchdog`, `recoveryRequested` and `rebuildRequested` events from the retired SwiftUI recovery bridge. The native container emits none of these.
- Visible rows throughout (the sample's `markers` summary, taken from the document's mounted rows): content, drawing, or compositing. Row geometry doesn't prove pixels reached the screen; confirm with a screen recording or Instruments.

Leave the trace off for performance baselines. `DISPATCH_CHAT_VIEWPORT_TRACE=0` suppresses it without changing the setting, and `DISPATCH_TESTING=1` disables the production sink.

What caused it before (fixed 2026-10-27): many rows (10 and more) leaving at once at the followed bottom, a user-expanded tool group collapsing because a history replacement reset it, left the lazy stack showing only hidden rows, on macOS 27 only. `ChatBlankTranscriptTests` (visible rows sampled every 8 ms) reproduces that class of failure and blanks only on macOS 27: run it on a macOS 27 machine or guest. Already ruled out as causes, so not worth auditing again: theme, font, sanitization and colour scheme; the always-on `.mask`; Liquid Glass; opacity transitions; drawing loss on occlusion, order-out or miniaturize; accessibility clients (though `AXScrollToBottom` on the lazy stack crashes SwiftUI on macOS 27); estimate drift alone; search; the empty-conversation placeholder; a new chat session; SSH reconnect resets; re-entering Chat during the mode transition. Bursts, a single row shrinking, width, theme and font changes, occlusion and remounts did not blank.

A further case (2026-11-03) did blank on remount: a history with very tall replies retained only hidden rows after opening, and rebuilding its content repeated the failure. In the capture, 83 transcript rows remained unchanged while the document estimate jumped from 4,927 to 42,672 points; scrolling finally realized the messages. `ChatBlankTranscriptTests.testOpeningHistoryWithATallReplyBeforeTheLatestTurnKeepsRowsOnScreen` reproduces this shape with fictional text and repeated mounts, with and without diagnostics. Opening and recovery now realize the final message by identity and correct to its measured frame instead of initially following the estimated document end. Established following still handles row recycling during resizing and live output. The regression checks the actual final row's visibility as well as sustained blanks, bottom position and unchanged user-interaction revision.

The initial version of that fix removed the initial bottom anchor and eager scroll target, allowing a tab switch to display its first history rows before jumping to the latest message. Screen captures confirmed the flash after that change and its absence before it. That recurring coordination failure motivated the AppKit-owned transcript container: row measurement, placement and scroll correction now complete in one native layout pass, with SwiftUI retained inside individual rows. The periodic viewport watchdog and lazy-stack rebuild escalation are removed. `NativeChatTranscriptTests` covers bounded hosting, synchronous measurement, anchor retention, removal/prepending, resizing, cancellation and idle behaviour. `ChatBlankTranscriptTests.testSwitchingChatsShowsTheLatestMessagesFromTheFirstIncomingFrame` checks actual presented pixels; row geometry alone can report the settled position while WindowServer presents an older frame.

Compare transcript container performance on the same unlocked, otherwise idle Mac:

```sh
python3 scripts/benchmark.py run --suite transcript --label before --runs 3 --desktop --environment hardware
python3 scripts/benchmark.py run --suite transcript --label after --runs 3 --desktop --environment hardware
python3 scripts/benchmark.py compare build/benchmarks/before/report.json build/benchmarks/after/report.json
```

Use separate checkouts for the two implementations. The workload is identical in each: a cold mount, 24 tab switches, 100 streamed updates, 100 scroll steps and three seconds idle. Reports include layout/display-submission latency, CPU time, resident memory and main-actor scheduling gaps. These are not physical presentation FPS; the presented-pixel regressions cover rendering correctness separately.

The initial container microbenchmark showed a 0.17 → 4.07 ms median scroll-step regression. That result
prompted further optimization and the sustained frame benchmark below. A scroll-event duration alone is not a
frame duration: the old SwiftUI stack defers much of its work beyond that callback. The native document reuses
prefix geometry and constructs rows synchronously only for the presented clip, after refining that range; it builds
the lookahead (larger while scrolling fast) one row per run-loop turn of its own, after the turn that scrolled, and
measures a lookahead row again when its content grows asynchronously, before it enters the clip. Each row is sized once from its
root's ideal height at its final width (no layout at the 100-point estimate; a size reported during the row's own
first layout is checked against the measurement instead of starting another pass), keeps its root while its row revision is
unchanged, and stays hidden in a bounded cache after it leaves the lookahead. A pass with an unchanged clip and
nothing invalidated does no work. The 10,000-row regression verifies that initial bottom layout constructs only the
two required rows. A large-arrival regression exposed 461 constructions for a 1,000-row burst; short arrivals now glide over at most two viewports, while larger bursts pin directly with viewport-sized hosting work.

Measured 2026-11-03 on the same Apple M5 Pro / 64 GiB, macOS 27.2, Xcode 27.2, AC power. Baseline
`d7f0cbc5` has only the identical harness added. Each renderer ran three fresh Release processes, six ten-second
phases per process, serially without concurrent builds or tests. The 1,000×740 window at 2× scale used the 120 Hz
virtual display, alongside the unchanged 60 Hz main display. Its screen display link delivers 120 Hz; AppKit's
window link delivers 60 Hz. Input uses an independent 120 Hz timer; achieved input rates remain in the reports.
Captured FPS counts changed transcript pixels, not timer callbacks, and does not establish physical 120 Hz scanout.

| Workload (points/s) | Old / native captured FPS | Old / native p95 presentation gap | Old / native CPU per 10 s |
|---|---:|---:|---:|
| Mixed messages, 2,400 | 58.8 / 79.3 | 23.5 / 21.6 ms | 2.42 / 4.03 s |
| Mixed messages, 6,000 | 56.6 / 80.7 | 26.8 / 22.2 ms | 2.86 / 4.48 s |
| Expanded tools, 2,400 | 46.9 / 64.7 | 44.5 / 31.6 ms | 4.61 / 4.00 s |
| Expanded tools, 6,000 | 30.1 / 63.5 | 68.2 / 35.6 ms | 7.65 / 5.41 s |
| Streaming while reading, 2,400 | 57.7 / 65.0 | 25.9 / 22.5 ms | 3.00 / 4.31 s |
| Streaming while reading, 6,000 | 53.0 / 75.1 | 29.9 / 24.8 ms | 4.64 / 5.04 s |

Changed pixels span more than 99.4% of every measured phase in both implementations. FPS and CPU are medians of three runs; frame-gap percentiles pool raw observed intervals. Frame delivery improves
in all six cases. Expanded tools also use less CPU, while mixed and streaming cases spend more CPU delivering more
frames. Native main-loop busy-turn medians are 0.67–1.32 ms; p95 ranges from 3.62 to 30.69 ms, so the heaviest
workloads still exceed the 8.33 ms budget. These results establish improvement against the old renderer, not
sustained 120 FPS. Native sampled peak RSS is 207–418 MiB across the phases, versus 189–364 MiB before; reports
retain each phase and run. The earlier short microbenchmark's lower memory result does not hold for this sustained
workload.

Raw frame reports: `tmp/native-transcript-baseline/build/chat-frame-benchmarks/old-v4-final/report.json` and
`build/chat-frame-benchmarks/native-final-confirmation/report.json`; environment-checked comparison with raw samples:
`tmp/native-transcript-final-frame-comparison.json`. Earlier submission-only reports remain in
`tmp/native-transcript-baseline/build/benchmarks/transcript-before-renderer/report.json` and
`build/benchmarks/transcript-after-intrinsic-sizing/report.json` for diagnosis; they precede the final optimization.

### Measuring frame presentation

#### Native row overhead experiments (2026-11-03)

Three candidate changes were measured against the final native renderer using the same hardware, display,
Release settings and six scrolling phases above: three fresh processes per candidate, ten seconds per phase,
serially without other builds or tests. These experiments did **not** establish a CPU improvement worth changing
production behavior. All three candidates were reverted; only benchmark instrumentation remains.

| Workload (points/s) | Control CPU | Unchanged row roots | Roots + deferred layout | Reused host containers |
|---|---:|---:|---:|---:|
| Mixed messages, 2,400 | 4.002 s | 4.075 s | 4.016 s | 3.973 s |
| Mixed messages, 6,000 | 4.482 s | 4.456 s | 4.483 s | 4.528 s |
| Expanded tools, 2,400 | 3.903 s | 3.938 s | 3.948 s | 3.962 s |
| Expanded tools, 6,000 | 5.804 s | 5.385 s | 5.390 s | 5.520 s |
| Streaming while reading, 2,400 | 4.342 s | 4.266 s | 4.309 s | 4.419 s |
| Streaming while reading, 6,000 | 5.058 s | 5.147 s | 5.241 s | 5.136 s |

Values are median whole-process CPU seconds per ten seconds, including capture overhead. The unchanged-root
candidate compared the row's model, layout metadata, theme, search, streaming and arrival inputs before replacing
its root. It removed about 1,170 root replacements per streaming phase; sizing passes fell from 1,308 to 130 at
2,400 points/s and from 1,496 to 335 at 6,000. Despite those large count reductions, total CPU barely changed and
fast-streaming captured FPS fell from 77.0 to 67.6. The extra equality/cache rules were rejected.

The deferred-layout candidate also removed `layoutSubtreeIfNeeded()` before querying intrinsic height. Time
inside synchronous measurement fell, but sizing notifications approximately doubled for mixed messages and whole
CPU remained similar: work moved into later layout. The host-reuse candidate recycled only containers retiring in
the same pass, with `.id(rowID)` resetting message state. It avoided 21/65 container allocations in the mixed phases,
but retained the cost of building and laying out each new message graph and did not reduce CPU meaningfully.

Expanded fast-scrolling CPU fell in all candidates, but the unchanged-root run mounted 202 new rows versus 255 in
the control while asynchronous formatting settled. That phase alone cannot isolate the saving from eliminating
only three root replacements. Frame delivery varied between runs and no candidate improved every workload. These
results do not remove the CPU regressions against the old SwiftUI renderer reported above, establish sustained
120 FPS, or measure watts/joules.

A diagnostic Time Profiler run assigned 24.4% of main-thread sample weight to the document's measurement path
and 31.2% to hosting-view layout; these overlap. Its CPU table exported successfully, but xctrace reported a corrupt
logging stream, so the overall trace is incomplete and is not a successful comparison run. This supports looking at
new row graph/layout work; it does not prove that all such work is avoidable. Container initialization itself took
0.04–0.11 seconds per phase; deferred SwiftUI graph construction is counted under sizing, not that initialization
timer. Counting all row measurements as costly rebuilds overstates their CPU impact.

Reports are under `build/chat-frame-benchmarks/{overhead-before,overhead-cached-v2,overhead-intrinsic-only,overhead-host-reuse}/report.json`.
`tmp/chat-overhead-experiments.json` retains each run's CPU/FPS and median operation totals; experiment sources are
preserved in `tmp/chat-overhead-experiments/`. The exported diagnostic CPU summary is
`tmp/chat-overhead-profile-before-hotspots.json`.

Native benchmark builds add `nativeLayout` to each phase's raw JSON: configuration updates (`updates`), effective
and skipped layout passes (`layouts`, `skippedLayouts`), root replacements and roots kept by an unchanged row revision
(`rootUpdates`, `keptRoots`), hosts created (`createdHosts`, split into `synchronousHosts` built for the presented clip
and `deferredHosts` built by the lookahead) and retired (`retiredHosts`), deferred lookahead builds and re-measurements
(`deferredBuilds`), cached hosts shown again (`cacheHits`),
the peak counts of hidden cached hosts and of all hosts (`cachedHostsPeak`, `hostsPeak`), idle cache releases
(`idleRetirements`), sizing passes (`sizings`) and those that had to lay the row out first (`sizingFallbacks`), row size changes, reported or found by the check after a row's own layout (`rowInvalidations`), and invalidations a
row's own layout reported without a change (`settledInvalidations`), and time inside layout, measurement, container creation,
root replacement, sizing and the deferred builder (`layoutSeconds`, `measureSeconds`, `creationSeconds`,
`rootUpdateSeconds`, `sizingSeconds`, `deferredSeconds`). Totals reset immediately before scrolling. Times are nested
and must not be added together; deferred construction runs in its own run-loop turns, outside the input callback.
This instrumentation is compiled only with `DISPATCH_BENCHMARK`; normal Debug and Release apps have no counters or
timing calls. The harness probes optional native document hooks, so the same harness also compiles against the old
SwiftUI renderer. The comparable top-level metrics and workload version remain unchanged.

#### Transcript rewrite (2026-11-03)

The rewritten scroll controller and document were measured against both earlier renderers above with the same
harness, hardware, Release settings, 120 Hz virtual display and six phases, ten seconds per phase, serially while
holding the shared build lock. Two macOS test VMs stayed booted but idle during every set; the earlier reports do not
record whether VMs were running. The final tree ran five fresh processes (the earlier renderers three); `benchmark.py
compare` only compares equal repeat counts, so the five-run figures below come from the same per-run samples, pooled
the same way (medians of run medians; p95 over all raw intervals).

| Workload (points/s) | Captured FPS: old / native / rewrite | p95 presentation gap (ms) | Main-thread CPU per 10 s |
|---|---:|---:|---:|
| Mixed messages, 2,400 | 58.8 / 79.3 / 80.2 | 23.5 / 21.6 / 20.6 | 2.08 / 3.64 / 3.55 s |
| Mixed messages, 6,000 | 56.6 / 80.7 / 72.4 | 26.8 / 22.2 / 23.9 | 2.60 / 4.15 / 4.18 s |
| Expanded tools, 2,400 | 46.9 / 64.7 / 72.1 | 44.5 / 31.6 / 24.6 | 4.35 / 3.71 / 3.76 s |
| Expanded tools, 6,000 | 30.1 / 63.5 / 57.9 | 68.2 / 35.6 / 36.0 | 7.38 / 5.15 / 5.18 s |
| Streaming while reading, 2,400 | 57.7 / 65.0 / 62.8 | 25.9 / 22.5 / 21.5 | 2.66 / 3.99 / 3.96 s |
| Streaming while reading, 6,000 | 53.0 / 75.1 / 69.6 | 29.9 / 24.8 / 24.7 | 4.24 / 4.74 / 4.77 s |

Busy main-loop turns over 8.33 ms are 2.6–6.0% against the previous native renderer's 3.3–9.1% (old: 0.8–11.4%).
Median peak RSS is 206–412 MiB, against 207–418 MiB native and 189–364 MiB old. Every row was built by the deferred
lookahead; none on the input path. The rewrite's input timer achieved 116–118 Hz in the mixed phases, against 109–113
Hz for the previous native renderer.

As first merged, the rewrite was much slower with expanded tools: 53.0 and 22.6 FPS, p95 gaps of 45.5 and 108.2 ms,
and 7.4 and 9.9 s of main-thread CPU. Expanded tool rows are first measured at their header height (about 80 points)
and grow by several hundred points when their formatted output arrives asynchronously. The pass anchored on the
topmost visible row even while that row waited to be measured again, so each growth pushed the visible content down:
at 2,400 points/s the document hosted 270 rows where the previous renderer hosted 66 over the same wheel distance,
and at 6,000 the scroll outran the builder, whose back-off moved 587 constructions onto the input path. The lookahead
builder now also measures again rows whose content changed size, while the reader scrolls a pass keeps the next
measured row instead of a cut-off one awaiting that (at rest the cut-off row keeps its offset), the lookahead ahead
covers 0.25 s of travel (up to three viewports) and the builder no longer backs off: hosted rows fell to about 65 and
195. A Time Profiler run attributed 18.5% of mixed-scrolling
main-thread weight (12.5% in the previous native profile) to SwiftUI asking the representable's AppKit `fittingSize`
on each outer layout, which builds a temporary constraint engine over every hosted row; the representable now takes
the size it is proposed, which lowered main-thread CPU by 0.2–0.8 s per phase. The per-layout ideal-height check every row host
runs (for content that grows on its own) took 0.1–0.2% of main-thread weight. The overlay scrollbar now keeps one
pending fade timer instead of scheduling a main-queue wake-up per wheel event, which removed about 5% of busy
run-loop turns in the mixed phases without a measurable frame-delivery change.

These results establish lower p95 presentation gaps than the old renderer in every phase and than the previous native
renderer in four of six, fewer over-budget turns than the previous native renderer in every phase, main-thread CPU
equal to the previous native renderer and below the old one with expanded tools. They do **not** establish higher
captured FPS than the previous native renderer in every phase: mixed and streaming at 6,000 points/s, expanded tools
at 6,000 and streaming at 2,400 remain 2–8 FPS below it. Individual runs of one tree differ by up to 26 FPS (the
previous renderer's by up to 18). In slow runs busy turns are short but most presented intervals are two display
frames. The harness's 120 Hz input timer is not synchronized with the display, so its phase against the display's
commit deadline is set by chance at each run's start; within the rewrite's mixed runs, a higher achieved input rate
goes with lower FPS (correlation −0.57 over 29 runs at 2,400 points/s), while the previous renderer's busier main
thread kept its timer at 109–113 Hz. This explains part of the spread; it does not show that the remaining gap is
only an artifact.

Scheduling experiments did not improve delivery and were reverted. On macOS 27 Core Animation commits in the display
update cycle (`UC::DriverCore`, a run-loop source of the iteration after the input), so a block queued at the end of
the input's turn runs before that input's frame is committed. Building instead right after the commit (from a probe
view's layout in that cycle, which a block queued there follows) lowered FPS in all six phases and raised over-budget
turns: the build then fills the interval before the next input. Pacing builds with a view's or a screen's display
link held delivery near 60 FPS: on this setup both links deliver 64 callbacks a second even when asked for 120, and
an active link appears to move the update cycle to its cadence. A nested `CATransaction` completion block runs before
the commit and cannot mark it. Main-thread CPU in mixed and streaming phases remains 0.5–1.6 s above the old
renderer, which delivered about 60 FPS.

Reports are under `build/chat-frame-benchmarks/`: the final five-run set `rewrite-final-5`, the merged tree
`rewrite-merge` and `rewrite-merge-repeat`, intermediate trees `rewrite-final`, `rewrite-final-repeat`,
`rewrite-combined`, `cadence-scrollbar` (three-run sets with `compare-old.md` and `compare-native.md`), the reverted
experiments `fix4-diag`, `fix5-diag`, `cadence-probe` and `cadence-screenlink`, and Time Profiler captures
`prof-fix1` and `prof-combined` (both reported a corrupt log stream; the CPU and run-loop tables exported).

#### Running the measurement

For a matched renderer comparison, copy `DispatchTests/ChatScrollingFrameBenchmarkTests.swift`,
`DispatchTests/ChatScrollBenchmarkTests.swift` and `scripts/benchmark-chat-frames.py` into both checkouts:

```sh
python3 scripts/benchmark-chat-frames.py --label renderer-before --runs 3 --duration 10
python3 scripts/benchmark-chat-frames.py --label renderer-after --runs 3 --duration 10
python3 scripts/benchmark.py compare BEFORE/report.json AFTER/report.json
```

The six phases combine mixed markdown/code/tables, expanded multi-step tools and 20 Hz streaming while reading
history, each at 2,400 and 6,000 points/s. All content is fictional; no agent or network is involved. A fresh
1,000×740 window uses the fastest available display. Precise wheel input runs independently of the window's
display link; reports retain requested and achieved input cadence. Sparse transcript pixel hashes reject duplicate
captures and exclude chrome, composer and thinking animation. Report captured composited FPS separately from input
rate. ScreenCaptureKit includes capture overhead and does not establish physical panel scanout.

Main-loop work includes every busy turn through the final before-waiting observer, including drawing deferred
beyond the input callback. CPU includes main-thread and whole-process totals. Reports retain raw intervals and the
share of busy turns exceeding 8.33 ms. Document-coordinate distance is only a scrolling guard: correcting estimated
heights changes that coordinate without moving the visible anchor. Source changes, failed workloads or missing
frame samples fail the run. Compile both checkouts first (`--build-only`), then measure serially on an idle desktop;
keep profiled runs separate. Artifacts stay under `build/chat-frame-benchmarks/<label>/`.

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

### Energy of a shown chat (2026-11-03)

`ChatEnergyBenchmarkTests` (disabled in every suite; run it explicitly) holds a 1,000×740 `ChatView` over 200 fictional
turns in each of seven ten-second states: idle at the bottom, busy without output, a 20 Hz stream while following and
while reading 60 rows up, idle in history, three seconds of wheel input and the rest after it. It reports process and
main-thread CPU, `proc_pid_rusage` v6 energy, instructions and wakeups, main run-loop wakeups and busy time, and in a
last pass counts `layout`, `drawRect:`, `updateLayer`, `display` and `drawInContext:` by class. The test VM has no
energy or instruction counters, so the figures below are Debug CPU in the VM (`test/vm.py`), which inflates SwiftUI;
compare states and trees, not absolute cost. Old is the SwiftUI lazy-stack renderer, new the AppKit document.

| Main-thread CPU per 10 s | old | new | new, footer without `ViewThatFits` |
|---|---:|---:|---:|
| Idle at the bottom / in history / after scrolling | 0.04–0.05 s | 0.03–0.05 s | 0.02–0.03 s |
| Busy, no output | 0.33–0.36 s | 0.31–0.33 s | 0.05 s |
| Streaming, following | 8.0–8.2 s | 8.3–8.4 s | 6.3 s |
| Streaming, reading history | 7.3 s | 6.1–6.2 s | 1.5 s |
| Wheel scrolling (3 s) | 0.74–0.76 s | 0.61–0.67 s | 0.51 s |

- **Neither renderer has an idle cost.** At rest the new document makes no layout passes and draws nothing; run-loop
  wakeups (13–17 a second, the harness included) are equal. The old renderer redrew text about five times a second at
  rest.
- **The model is not the cost.** The same stream to a session no view shows takes 0.05–0.12 s, `ChatSession.insert`
  0.01–0.07 s of it.
- **The composer footer is most of it.** `composerFooter` is a `ViewThatFits` over five or six full footer rows, each
  with its own `ChatComposerActivity` (whose `AgentWorkingState` reads `session.turns`), orbit view and one-second
  timeline. Every record re-evaluates them all, and AppKit's constraint pass then asks the root `NSHostingView` for its
  `minSize`, which measures every candidate: 58% of main-thread samples while streaming in history, 26% while
  following. Showing only the regular row (an experiment, not a fix: narrow panes need the others) removed 4.6 s of
  6.2 s while reading and 0.27 of 0.33 s while busy.
- **Following, the rest is the live row:** its host's layout (17% of samples), `ChatSelectableText.updateNSView`
  setting the text again (11%), the document measuring the row (10%), markdown attribution (4%) and text drawing (4%).
- **Redraws.** The overlay scrollbar's thumb draws on every layout pass, faded out or not (`ChatScrollbar.update`
  sets `needsDisplay` unconditionally): 170–270 draws per ten seconds of streaming or scrolling, in both trees. The new
  document draws the streaming row's text views about 60% more often than the old renderer while following (1,100
  against 675) and text 33% more while wheel scrolling, with about twice the layer `display` calls; while reading
  during a stream it makes far fewer (330 against 2,730).

`testChatTabSwitchingEnergy` uses the real window (`TmuxWalkthrough`): three chat tabs of 200 turns in one pane, the third
read 60 rows up. A pane mounts only its active tab, so every switch builds the chat it shows and tears down the last. It
switches every half second for ten seconds (latency: from `selectTab` until the chat shows rows where its reader left
them, polled every 2 ms), rests ten seconds, then streams at 20 Hz into a tab that is not shown.

| Per 10 s, 20 switches | old | new |
|---|---:|---:|
| Main-thread CPU while switching | 2.48–2.49 s | 2.93–2.95 s |
| Busy turns over 8.33 ms | 19–21 | 34–38 |
| Main run-loop wakeups | 2,310–2,380 | 1,700–1,760 |
| Switch latency, median / p90 | 105–113 / 137 ms | 109 / 131–133 ms |
| Text `drawRect:` / view layouts (counted pass) | 472 / 3,450 | 750 / 4,507 |
| Main-thread CPU at rest after switching | 0.13–0.18 s | 0.16–0.18 s |
| Main-thread CPU, a tab not shown streaming | 0.20 s | 0.19–0.20 s |

A switch costs about 23 ms more main-thread CPU in the new document (Debug), at the same latency. The profiles put the
difference in building rows: each row is its own `NSHostingView` with its own graph, sized by `intrinsicContentSize` and
moved into the window one by one, where the old lazy stack built one graph; the document measures each row it mounts
(`measure`, `fittedHeight`), and the deferred lookahead then builds a viewport of rows above the visible ones (about 30% of the
document's own samples), which a reader who switches away again never sees. Nothing survives a switch: the
document, its hosts and its measured heights go with the view. A tab that is not shown costs the same in both: its rows
are not mounted.

**After the fixes (same day, same harness).** The footer's variants share one `ChatComposerActivityState`, which
publishes the activity only when it changes, and the clock sits in a slot sized by a template (digits as zeros), so a
tick changes no size. A hidden scrollbar thumb takes the clip's position only when it shows. A message text view reads
its attribute runs through one slice (`run.font` and friends instantiated a key path per run), drops the inline
presentation intents once it has set their fonts (TextKit re-derived a font from each on every edit), and edits only
what follows an unchanged prefix. A document that just entered a window builds no lookahead for 0.3 s unless its clip
moves.

| Main-thread CPU per 10 s | before | after |
|---|---:|---:|
| Busy, no output | 0.31–0.33 s | 0.07–0.12 s |
| Streaming, following | 8.3–8.4 s | 5.4–5.8 s |
| Streaming, reading history | 6.1–6.2 s | 1.5–1.6 s |
| Wheel scrolling (3 s) | 0.61–0.67 s | 0.61–0.66 s |
| Idle (all three states) | 0.03–0.05 s | 0.02–0.05 s |
| Tab switching, 20 switches | 2.93–2.95 s | 3.01–3.08 s |
| Switch latency, median / p90 | 109 / 131–133 ms | 96 / 105–106 ms |

The thumb no longer draws during a stream (248 draws per ten seconds following, 187 reading, now 0 and 1). Following
now takes about twice as many busy turns over 8.33 ms (300–380 against 145–170) and run-loop wakeups (630–720 against
220–260) for the same number of transcript updates, and draws the streaming text more often (1,450 against 1,090):
the main thread is no longer saturated, so display-link frames (the arrival glide, typed reveal) run instead of being
skipped. A switch shows its chat about 14 ms sooner (the lookahead is out of its way) at the same CPU: the lookahead
still runs once the chat has shown 0.3 s, as it does in this harness's half-second dwell. Keeping a transcript alive
across switches (its hosts and heights, the newest three for 60 s) was tried and dropped: hosts that enter a window
again lay out about as expensively as new ones, so it saved 8% of switching CPU but showed each chat 15 ms later.
Measuring text with the view's own layout manager instead of `boundingRect` would save a second typesetting per change,
but its line heights differ by up to 2 points from `boundingRect`'s for lines mixing fonts with emoji or CJK, so it was
left alone.

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

## Profiling and debugging recipes

These are throwaway setups: the probe test, extension or script lives in `tmp/` or a scratch worktree and is removed
afterwards.

### SwiftUI redraws on the Mac

- Attach `xcrun xctrace record --template SwiftUI` (or `Time Profiler`) to the XCTest host's pid. The probe test writes
  its pid to a file and **waits for a `ready` file before it creates any window** (views created before the attach show
  as "[unknown view: created before tracing started?]"), and **waits for a `release` file after its last phase**: stop
  xctrace with SIGINT first, since a host that exits while recording leaves the trace's log data incomplete.
- Points of Interest signposts come back empty under attach. Align phases by printing `Date().timeIntervalSince1970`
  and subtracting the trace's `<start-date>`. Export with `xctrace export --xpath` (`swiftui-updates`, `time-profile`);
  rows use id/ref deduplication, so resolve refs while streaming (about 600 MB of XML for 60 s).
- Instruments inflates SwiftUI time. For CPU numbers, build Release for testing (`ENABLE_TESTABILITY=YES
  ENABLE_HARDENED_RUNTIME=NO`, as `scripts/benchmark.py` does) and measure each phase in-process with `getrusage` and
  the main thread's `thread_info`. If an incremental Release rebuild leaves the test bundle with "different Team IDs",
  build clean.

### Animations frame by frame

- **Mac:** append a throwaway test that mounts the real view (`ChatView`) in a borderless window, makes the change the
  way the coordinator does, and loops `SCScreenshotManager.captureImage` about every 5 ms. Write a GIF at real timing
  and a contact sheet (every frame for the first 60 ms, then every 30–40 ms) under `build/`. Captures need the test
  host's Screen Recording permission, so this runs on the host, live.
- **iPhone:** host the real view in a 402×874 `UIWindow` inside a unit test and take
  `window.drawHierarchy(afterScreenUpdates: false)` about every 16 ms; in-flight animations and zoom transitions show.
  Activate buttons with `accessibilityActivate()`; drags cannot be driven this way.

### CPU of iPhone and Watch views in the simulator

Measure, don't judge by feel: launch a Release simulator build with `simctl launch` (environment through
`SIMCTL_CHILD_*`), feed it a fixed workload (a debug hook that replays a fixture snapshot every second), and read
`ps -o time= -p <pid>` deltas, plus the device's `backboardd` for render-server cost. `xcrun xctrace record --device
<udid> --attach <pid>` (Time Profiler) gives the stacks. The simulator caps at 60 fps; devices run 120.

### SSH over a slow or lossy link

The Lima guest's sshd is reached over vsock, so `tc netem` on the guest's interfaces changes nothing for `limactl`'s
forwarded port. Shape the guest's loopback instead and reach it through a tunnel:

```sh
ssh -N -L 127.0.0.1:2223:127.0.0.1:22 -p <sshLocalPort> -i ~/.lima/_config/user user@127.0.0.1 &
limactl shell <vm> -- sudo sh -c 'ip link set lo mtu 1500; ethtool -K lo tso off gso off gro off;
  tc qdisc replace dev lo root netem delay 300ms 30ms loss 3% rate 2mbit limit 20000'
```

Connections to `127.0.0.1:2223` then cross the shaped loopback (delay and loss apply per direction). Change or clear
the qdisc through `limactl shell`, never through the tunnel (a 100 % loss profile could not be cleared), and restore
`mtu 65536` afterwards. `test/helper-stdio.py`'s fixture session speaks the phone's `--stdio` channel over such a port.

### A frozen terminal tab

Measure the I/O before theorizing. While typing into the frozen tab, `sudo fs_usage -w -f filesys <app pid> <helper
pid>` and sum the `B=` bytes per descriptor: equal counts at every hop mean input and output flow. Then `sample <app
pid>`: each terminal has a poll thread and two condition-wait threads, and its render thread is the `CFRunLoopRun`
thread created just before them; a set without a render thread means the render thread ended (a run loop returns once it
has no sources left, which is why the render thread keeps a port on it). A tab that draws once on resize points at the
display link or render thread, not I/O. Find the app with `pgrep -f MacOS/Dispatch$`: `pgrep -x Dispatch` also matches
the `Dispatch --ssh-launch` children.
