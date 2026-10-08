# Chat rendering diagnostics

## Caret invariant

Chat slowness on 120 Hz Adaptive-refresh displays (external displays and ProMotion MacBooks, especially in full screen) came from native caret rendering. The main, `/btw`, and `/side` composers all use `ChatCaretTextView`/`ChatEditorTextView`. Never revert a composer to a SwiftUI `TextField`. `ChatSideComposerTests` guards caret, IME, focus, and drafts.

## Viewport trace (disappearing transcripts)

Enable **Settings → Behavior → Advanced → Diagnostics** (off by default; applies live). After a disappearance, note the time and copy the logs before they rotate (2 × 4 MiB):

```sh
mkdir -p build/chat-viewport-capture && cp ~/Library/Logs/Dispatch/Diagnostics/* build/chat-viewport-capture/
```

`ChatViewportTrace` records geometry, row counts, scroll corrections, and watchdog decisions, at most 4 samples/s per viewport. It records no text, paths, hosts, or IDs; row IDs become in-memory HMAC tokens. Nothing is uploaded. Write failures go to unified log `com.dispatch.app`/`ChatViewport`. Read the sequence, not a single sample:

- Transcript rows > 0 but mounted rows = 0: realization gap.
- Mounted rows outside the clip rect: geometry/offset mismatch.
- `blank` → `recoveryRequested`/`rebuildRequested` → `recovered`: the watchdog's recovery.
- Visible markers throughout: content, drawing, or compositing. Markers don't prove pixels reached the screen; confirm with a screen recording or Instruments.

Leave the trace off for performance baselines. `DISPATCH_CHAT_VIEWPORT_TRACE=0` suppresses it without changing the setting, and `DISPATCH_TESTING=1` disables the production sink.

## Measuring

Repeatable runs: `benchmark-long-chat.py` (synthetic) and `benchmark-chat-scroll.py` (a real conversation); see [benchmarks](benchmarks.md). For a real conversation without a network, use the [offline Codex fixture](vm_testing.md#offline-codex-scrolling-fixture). These don't reproduce full-screen, Adaptive-refresh, or SSH-specific issues, and their display-link callbacks are not presented FPS. To measure actual frame presentation, capture in the failing environment:

```sh
xcrun xctrace record --template 'Animation Hitches' --attach <dispatch-pid> --time-limit 20s --output build/chat-profile/windowed.trace
python3 scripts/export-chat-rendering.py build/chat-profile/*.trace --output-dir build/chat-profile/exported
```

- Scroll for about 10 s, then repeat in full screen with the same display, refresh setting, section, and gesture.
- Use `Time Profiler` for CPU, in a separate capture. Keep instrumented runs apart from timing comparisons.
- Export with the recording Xcode or newer; older versions fail with `Missing features`.
- Traces contain paths and process metadata. Review them before sharing.

Report presented-frame intervals (median/p95/p99, long gaps) separately from app work (main-thread stacks, layout, commits). The original bug had 8.3 ms app commits but 97.9 ms presented intervals, with zero Hitches reported.
