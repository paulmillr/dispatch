# Dispatch

    brew install --cask paulmillr/tap/dispatch

> A terminal app for macs, which supercharges your existing workflows.

- 💬 Using agents? It transforms CLI/TUI into real chat with notifications.
- 🪟 Using tmux/herdr? It maps their tabs onto native app’s tabs and spaces.
- 🗂️ Using ssh? It groups spaces per-host.
- 🎨 Minimal Liquid Glass design & classic themes.
- 🪶 Zero-dependency Swift port of libghostty. GPU-accelerated.

![](https://github.com/user-attachments/assets/270c821d-6db7-4cd1-8370-e6583ba41edf)

## Why Dispatch

To manage fleet of machines, **persistent** agents on them, with first-class UI and everything you may want from a modern terminal.

Terminal multiplexers (tmux or herdr) allow running processes even when you're logged in from this session (local or remote).
They're the answer to persistence.

1. Using tmux / herdr natively means using TUI (terminal-drawn scrollbar and UI). It's simulation of a proper window, so
it's quite bad. There is no native scrolling (with history & search). No native copy-paste. Even tab clicks are simulated.
2. Using t3code / orca means not using terminal multiplexers, or having degraded non-native terminal experience.
3. Using rex / tern means using proprietary (not open-source) tool which you don't control.

**Dispatch has a lot of features, but it stays simple**.

## Main features

- **tmux and herdr** sessions / spaces displayed as native spaces / tabs
- **Chat mode:** transform CLI into UI. Including SSH agents! Consistent experience across Codex/Claude/Pi. Queue and steer, approvals (permission cards), agent questions as forms, side questions, attachments, a model and effort picker, goals, drafts kept per tab, tool cards with diffs.
- **Files mode:** a file browser with previews, an editor, uploads/downloads by drag and drop, and a git Changes/Commits view with a graph
- **Review mode**: it's like GitHub Pull Requests, but for your agents!
- **Dictation and voice:** three **always-local** engines (Apple, Whisper, Parakeet), "Navigate by voice" with wake words, and "Read replies aloud"
- **Per-host stats for SSH:** color-coded remote hosts, auto-reconnect with an overlay, and a slow-connection mode
- Zero-dependency Swift port of libghostty. libghostty is great and fast engine, but on the Mac it requires 23 dependencies (14 C/C++, 9 Zig, plus the Zig compiler), and 10 more if we count non-Mac code. Our version has no third-party code dependencies.

### Secondary features

- tmux-style ⌃B prefix keys, also in native spaces
- Single window to rule everything, for simplicity
- Classic themes & OKLCH+P3 theme creator
- Bundled coding fonts
- Disabled-by-default Kitty graphics protocol
- Zero-dependency Swift port of libghostty. Original requires 23-39 deps (depending on how you count; including Zig compiler).

### Architecture & security

- Dispatch targets Apple Silicon Macs on macOS 14+; we'll consider other architectures later
- Our Rust helper does all the heavy lifting. It runs on macOS, Linux x86 + ARM. It's uploaded to SSH hosts with per
  requests. Many features still work without it. It opens NO ports - communcation is done via SSH stream
- Reproducible builds

## Building

Single command:

    ./build.sh --release --run

It needs xcode, xcode needs apple id; easiest way to install xcode: `brew install xcodes; xcodes install 27.2`.

We have reproducible builds as well.

## License

The MIT License (MIT)

Copyright (c) 2026 Paul Miller (https://paulmillr.com)

