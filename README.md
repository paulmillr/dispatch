# Dispatch

A terminal app for macs, which supercharges your existing workflows.

- 💬 Using agents? It transforms CLI/TUI into real chat with notifications.
- 🪟 Using tmux/herdr? It maps their tabs onto native app’s tabs and spaces.
- 🗂️ Using ssh? It groups spaces per-host.
- 🎨 Not using anything? Polished liquid glass design, themes & GPU acceleration.

That’s it. No bloat!

[![](https://github.com/user-attachments/assets/e937fe12-4eae-4a04-86f3-fb5d23118bcd)](https://github.com/user-attachments/assets/e937fe12-4eae-4a04-86f3-fb5d23118bcd)

## Quick start

Dispatch is a normal terminal. The goal is to improve user's workflow, not to change it.

1. Locally it can be used as-is. For SSH: use standard command e.g. `ssh host`
    - SSH-ing somewhere presents a popup, which asks to upload optional dispatch-helper
    - SSH helper opens no ports and serves as a part which does all the heavy lifting for the app
2. Try **Native Tabs**: run `tmux -CC` / `tmux -CC attach` or `herdr` locally / remotely
3. Try **Chat Mode**: Start an agent in a terminal, it would auto-switch the tab to chat
    - All sent messages are queued - not steered
    - There is a separate key combo to steer; also it's possible to steer queued message
    - Multi-line editor is enabled with shift+enter. It highlights markdown code brackets
    - Requires codex-cli 0.161.0, claude 2.1.293, pi 1.1.0 or nanocodex
    - Try [Nanocodex](https://github.com/gakonst/nanocodex): Codex rebuilt so that it's faster and can be embedded in third party applications via an ergonomic library API
4. Try splits: open 4 tabs, use ctrl+1, ctrl+2, ctrl+3, ctrl+4

Extra features:

- Spaces: tree view, reopen on launch, restore history, git branch titles, compact space list
- Check out sidebar footer: clicking on a host brings up stats widget
- Auto-improve text contrast on light themes
- OSC-7501 support

## How it works

There are two parts: Swift macos app and Rust helper. Rust helper parses tmux/herdr windows, adds hooks to agent chats, to ensure everything stays smooth. It also monitors system usage. It has no extended rights and opens no listening ports. Audit it by yourself!

## Run

Requires Xcode 26+. Tested on macOS 26 & 27, but may run on macOS 14+.

```sh
./run.sh               # build Debug and launch
./run.sh --prod        # Release
./run.sh --just-build  # build without launching
./run.sh --test        # fast tests (see test/README.md)
```

Easiest way to install xcode (needs apple id): `brew install xcodes; xcodes install 27.0`.

All deps are downloaded into `build`.
For signed, notarized macOS downloads, see [distribution](docs/distribution.md).

## Architecture

Dispatch is two things: Swift macOS app and Rust helper.

The Rust helper is optional. The helper talks to tmux, herdr, reads agent chats.

## License

The MIT License (MIT)

Copyright (c) 2026 Paul Miller (https://paulmillr.com)
