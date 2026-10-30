# Dispatch

    brew install --cask paulmillr/tap/dispatch

> A terminal app for macs, which supercharges your existing workflows.

- 💬 Using agents? It transforms CLI/TUI into real chat with notifications.
- 🪟 Using tmux/herdr? It maps their tabs onto native app’s tabs and spaces.
- 🗂️ Using ssh? It groups spaces per-host.
- 🎨 Not using anything? Minimal Liquid Glass design & classic themes.
- 🪶 Zero-dependency Swift port of libghostty. GPU-accelerated.

![](https://github.com/user-attachments/assets/270c821d-6db7-4cd1-8370-e6583ba41edf)

## Why Dispatch

We used **herdr** and saw something new coming. herdr is like **tmux**, but better in a few ways:
it groups tabs into spaces, it's easy to move around, it names spaces for you, and it shows what
every agent is doing.

But herdr, like tmux, draws everything inside the terminal. That has limits: you can't select text
across panes, scrolling doesn't feel native, and editing text is hard. Also, many people will
keep using tmux, so we have to support both.

Most new tools (like t3code) are chat apps, not terminals. We think people will still need a
terminal. It just needs to understand agents and contain features relevant for 2027.

Other new terminals try to solve this too:

- **Rex** needs its own multiplexer. Dispatch works with tmux and herdr.
- **Tern** has chat only for omp. Dispatch works with Codex, Claude Code and Pi.

Dispatch is a native Mac app. tmux and herdr tabs become real Mac tabs. Agents become real chats.
The design follows Apple's guidelines. **It has a lot of features, but it stays simple**.

## Unique features

- **tmux and herdr** spaces displayed as native spaces / tabs
- **Chat mode:** consistent experience across Codex/Claude/Pi. Queue and steer, approvals (permission cards), agent questions as forms, side questions, attachments, a model and effort picker, goals, drafts kept per tab, tool cards with diffs.
- **Files mode:** a file browser with previews, an editor, uploads/downloads by drag and drop, and a git Changes/Commits view with a graph
- **Review mode**: it's like GitHub Pull Requests, but for your agents!
- **Dictation and voice:** a composer mic with three **always-local** engines (Apple, Whisper, Parakeet), "Navigate by voice" with wake words, and "Read replies aloud"
- **Per-host stats for SSH:** color-coded remote hosts, auto-reconnect with an overlay, and a slow-connection mode
- One window to rule them all, for simplicity. Instead of creating a new window, create a second space.
- Cool theme picker: classic themes and theme creator with oklch / P3 colors
- Zero-dependency Swift port of libghostty. libghostty is great and fast engine, but it requires 37 dependencies: Zig compiler, 10 Zig libs, 15 C libs, etc. Our version has no third-party code dependencies.

### Non-unique features

- tmux-style ⌃B prefix keys, also in native spaces
- Bundled coding fonts
- Disabled-by-default Kitty graphics protocol
- Ghostty-compatible engine: Ghostty config syntax, Ghostty's bundled themes, and shell integration for bash/zsh/elvish/nushell

### Architecture & security

- Dispatch targets Apple Silicon Macs on macOS 14+
- Our Rust helper does all the heavy lifting. It runs on macOS, Linux x86 + ARM
- Helper opens no ports. Dispatch communicates with it using SSH stream.
- Other platforms may be added later

## Quick start

1. Either download via [Homebrew](https://brew.sh): `brew install --cask paulmillr/tap/dispatch`
2. Or compile by yourself: clone repo and do `./run.sh --prod`. It needs xcode, xcode needs apple id; easiest way to install xcode: `brew install xcodes; xcodes install 27.2`.

Dispatch is a normal terminal. If you've used terminals, it should be intuitive.

1. Locally it can be used as-is. For SSH: use standard command e.g. `ssh host`
    - SSH-ing somewhere presents a popup, which asks to upload optional dispatch-helper
2. Try **Native Tabs**: run `tmux -CC` / `tmux -CC attach` or `herdr` locally / remotely
3. Try **Chat Mode**: Start an agent in a terminal, it would auto-switch the tab to chat.
    - It uses hooks, local usage needs pre setup, remote usage is easier
    - For local usage: Settings => Hosts => This Mac => Install (next to codex, claude etc)
    - For usage over SSH: just ssh somewhere, ensure to check the checkbox while connecting to auto-install hooks
    - All sent messages are queued - not steered
    - There is a separate key combo to steer; also it's possible to steer queued message
    - Multi-line editor is enabled with shift+enter. It highlights markdown code brackets
    - Requires codex-cli 0.164.0, claude 2.1.311, pi 1.4.0 or nanocode
    - Try [Nanocodex](https://github.com/gakonst/nanocodex): Codex rebuilt so that it's faster and can be embedded in third party applications via an ergonomic library API
4. Try splits: open 4 tabs, use ctrl+1, ctrl+2, ctrl+3, ctrl+4

## License

The MIT License (MIT)

Copyright (c) 2026 Paul Miller (https://paulmillr.com)

