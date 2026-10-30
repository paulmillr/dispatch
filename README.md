# Dispatch

A terminal app for macs, which supercharges your existing workflows.

- 💬 Using agents? It transforms CLI/TUI into real chat with notifications.
- 🪟 Using tmux/herdr? It maps their tabs onto native app’s tabs and spaces.
- 🗂️ Using ssh? It groups spaces per-host.
- 🎨 Not using anything? Polished liquid glass design, themes & GPU acceleration.

That’s it. No bloat!

![](https://github.com/user-attachments/assets/270c821d-6db7-4cd1-8370-e6583ba41edf)

## Quick start

    brew install --cask paulmillr/tap/dispatch

Dispatch is a normal terminal. The goal is to improve user's workflow, not to change it.

1. Locally it can be used as-is. For SSH: use standard command e.g. `ssh host`
    - SSH-ing somewhere presents a popup, which asks to upload optional dispatch-helper
    - SSH helper opens no ports and serves as a part which does all the heavy lifting for the app
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

Extra features:

- Spaces: tree view, reopen on launch, restore history, git branch titles, compact space list
- Review tab (files mode, ⇧⌘U): comment on any line of the uncommitted changes, then Create review sends the comments as one review to an agent chat (this tab's or another's), or copies it to paste anywhere; ⌥↓/⌥↑ step through the comments, ⇧⌘⏎ creates the review
- Disable spaces (Settings › General › Window): no tab strips; the sidebar lists every tab and "+ tab" replaces "+ space"
- Check out sidebar footer: clicking on a host brings up stats widget
- Auto-improve text contrast on light themes
- Single window for *everything*: no multiple windows
- OSC-7501 support

## How it works

There are two parts: Swift macos app and Rust helper. Rust helper parses tmux/herdr windows, adds hooks to agent chats, to ensure everything stays smooth. It also monitors system usage. It has no extended rights and opens no listening ports. Audit it by yourself!

## Run

Homebrew contains notarized binary:

    brew install --cask paulmillr/tap/dispatch

To compile by yourself, you'll need Xcode 26+. The app is tested on macOS 26 & 27, but may run on macOS 14+.

```sh
./run.sh               # build Debug and launch
./run.sh --prod        # Release
./run.sh --just-build  # build without launching
./run.sh --test        # fast tests (see test/README.md)
```

Easiest way to install xcode (needs apple id): `brew install xcodes; xcodes install 27.0`.

All deps are downloaded into `build`.

Official website (redirects to GitHub): https://dispatch.yachts

## Dispatch for iPhone and iPad

A thin client for your Macs and Linux machines: Spaces (tmux/herdr tabs and a real terminal) and Agents (chat with
approvals, queue and diffs) over SSH. The same Rust helper does the work on each host; nothing leaves the device but
your SSH connections. On an iPad, Spaces sits beside the tab it opens, and a hardware keyboard adds the menu bar and
the Mac's ⌘ shortcuts. Needs iOS or iPadOS 26+, Xcode 27, and on each host tmux 3.7+ or herdr 0.9.3+. Sideloaded, no
App Store.

```sh
./run.sh --ios                                         # try it in the simulator
./run.sh --ios --simulator "iPad Pro 11-inch (M5)"     # on an iPad (the iOS 27.0 runtime has the iPads)
python3 scripts/ios-signing.py TEAMID --suffix .you    # once: your team from Xcode, Settings, Accounts
# on the iPhone or iPad: pair it by cable, turn on Developer Mode
./run.sh --ios-device --prod                           # build, install, launch; again weekly on a free Apple ID
```

See [docs/ios.md](docs/ios.md).

The Apple Watch companion: `./run.sh --watch` (paired iPhone and watch simulators), [docs/watch.md](docs/watch.md).

## Releasing

The maintainer's Mac builds the Mac app and the iPhone app without any signing key; a separate signing machine
re-signs, notarizes and uploads them. They exchange release folders through the private `dispatch-release`
repository, and the maintainer verifies the signed Mac app byte for byte against the reference copy (only signatures
differ). The DMG goes to a GitHub release tagged `X.Y.Z` and the cask in `homebrew-tap`, the iPhone app to TestFlight;
both are the Pilot account's (`yachts.dispatch.pilot.*`; `--stable` builds the stable account's, published nowhere yet).
Full procedure: [docs/releasing.md](docs/releasing.md).

```sh
scripts/release-prepare.sh [--stable]          # maintainer: build, keep a reference copy, push to ../dispatch-release
git pull && bin/release-publish.sh             # signing machine, in dispatch-release: notarized DMG, TestFlight upload
scripts/release-prepare.sh --verify --team TEAMID  # maintainer, after pulling: check the DMG, print publish steps
```

Apple silicon only. Test the download on a disposable Mac before publishing.

## License

The MIT License (MIT)

Copyright (c) 2026 Paul Miller (https://paulmillr.com)

