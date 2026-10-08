# Dispatch

A macOS terminal, reimagined for the agentic era.

- 💬 **Chat mode:** turns CLI agents into real chat (Codex, Claude, Pi,
  [Nanocodex](https://github.com/gakonst/nanocodex))
- 🪟 **Tmux & herdr:** native tabs, smooth scrolling, copy-paste
- 🔔 **Notifications:** know when an agent needs you
- 🗂️ **Spaces & tabs:** vertical spaces, horizontal tabs, colorized per-machine
- ✂️ **Smart splits:** regroup existing tabs instead of opening new ones

All of this while being:

- 🏎 **Fast:** Swift rewrite of libghostty
- ⌨️ **Keyboard-first:** works with your tmux/herdr control key
- 🎨 **Design-focused:** it's an old-school terminal, just modernized and UX-friendly. We fight bloat!

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

## Using Dispatch

1. Open new tab.
    - For local usage: do nothing
    - For remote usage: use standard ssh command
    - After ssh auth, you'd be asked to upload Rust helper there to handle all the heavy lifting. **The helper is optional.**
2. Run `tmux -CC` or `herdr` locally / remotely to get native spaces and tabs.
3. Try chat mode: Start an agent in a terminal, it would auto-switch the tab to **Chat Mode**.
    - Chat mode always queues across all agents; with extra option to steer
    - shift+enter enables multi-line editor with syntax highlight for markdown code
    - Requires codex-cli 0.161.0, claude 2.1.293, pi 1.1.0 or nanocodex
4. Try splits: open 4 tabs, use ctrl+1, ctrl+2, ctrl+3, ctrl+4

Extra features:

- Spaces: tree view, reopen on launch, restore history, git branch titles, compact space list
- Check out sidebar footer: clicking on a host brings up stats widget
- Auto-improve text contrast on light themes

## Architecture

Dispatch is two things: Swift macOS app and Rust helper.

The Rust helper is optional. The helper talks to tmux, herdr, reads agent chats.

## License

The MIT License (MIT)

Copyright (c) 2026 Paul Miller (https://paulmillr.com)
