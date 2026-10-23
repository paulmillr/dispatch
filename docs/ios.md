# Dispatch for iPhone and iPad

A thin client for SSH hosts. The device has no shell and starts no processes: the Rust helper on each host does the
work, and the app speaks the helper protocol (`helper/PROTOCOL.md`) over one in-process SSH connection per host.
iOS and iPadOS 26+, one app for iPhone and iPad (`TARGETED_DEVICE_FAMILY` 1,2; on an iPad see [iPad](#ipad)),
sideloaded (no App Store: the macOS helper would have to become a non-Mach-O payload, ITMS-90171). Sources are in
`Mobile/`; privacy, trust, keys and the helper's grant are in [security](security.md#dispatch-for-iphone).

**Hosts need** SSH (password, key or keyboard-interactive), macOS 14+ on Apple silicon or Linux arm64/x86-64, and tmux 3.7+ or herdr
0.9.3+ ([installing](integrations.md#tmux-and-herdr)). Shells and agents live in tmux windows or herdr tabs so they
outlive the connection; the app installs nothing but its helper. tmux before 3.7 has no bracketed-paste state: Chat to a bound agent works, other typing is refused,
and the Mac's readiness warning shows. Linux with systemd-logind `KillUserProcesses=yes` kills servers at logout
unless the user runs `loginctl enable-linger $USER`. A host without the helper ([Plain SSH](#plain-ssh): its Helper switch
off, or a helper that could not be installed) needs only SSH and a login shell: nothing is installed there.

## Building and running

```sh
./run.sh --ios [--simulator "iPhone 18 Pro"] [--just-build]   # Debug in the simulator (DISPATCH_IOS_SIMULATOR)
./run.sh --ios --simulator "iPad Pro 11-inch (M5)"            # the same on an iPad
./run.sh --ios-device [--prod] ["<name or UDID>"]           # paired iPhone or iPad; --prod is Release
test/run.sh --platform ios [--simulator NAME] [--suite full] [Class]   # Testing, below
python3 test/ios-release.py [--simulator NAME]              # Release, below
```

Needs Xcode 27 with an iOS simulator runtime. Its simulator window is DeviceHub (`Xcode.app/Contents/Applications`,
`com.apple.dt.Devices`, which `./run.sh --ios` opens); Simulator.app is gone. Without it the simulator runs headless
(`xcrun simctl io booted screenshot shot.png`). `--simulator` takes a name or a UDID; when several simulators share
the name (`scripts/ios_simulator.py`), the booted one wins, then the newest runtime, and every step uses its UDID.
`DISPATCH_IOS_SIMULATOR` is the default for all three commands (else iPhone Air); a custom-named simulator's
description says its family ("dispatch-ipad (iPad, iOS 27.0)"). **iPad simulators need the iOS 27.0 runtime**: 27.1
has only the iPhone Duo, so `xcrun simctl create my-ipad "iPad Pro 11-inch (M5)"
com.apple.CoreSimulator.SimRuntime.iOS-27-0` (also `"iPad mini (A17 Pro)"`, `"iPad Pro 13-inch (M5)"`).

**Fresh checkout.** SwiftPM resolves `MobileTransport`'s binary target before any build script runs, so the pinned
Rust with its iOS targets and `build/mobile-ssh/DispatchMobileSSHCore.xcframework` must exist first. `./run.sh --ios`
and `test/run.sh --platform ios` do it through `scripts/setup_mobile.py` (`setup-ssh-rust.py`, then
`build-mobile-ssh.py --fetch`, the only network step). `DISPATCH_SETUP_OFFLINE=1` fails with the command instead.
The package also compiles before the app's pre-build script, so setup rebuilds the XCFramework whenever its headers
differ from `Mobile/Transport/Core/include`: a pull that adds to the C header would otherwise fail in `Engine.swift`.
Every existing checkout must run `python3 scripts/setup-ssh-rust.py` once, or the helper build's offline toolchain
check fails on the missing iOS targets.

### Signing and a device

The team lives in git-ignored `build/signing.xcconfig` (included by `Mobile/Config/Signing.xcconfig`; the simulator
needs none). `python3 scripts/ios-signing.py --teams` lists teams; `ios-signing.py TEAMID --suffix .you` writes it;
`--check [--xcode]`, `--remove`. A free Apple ID works (no entitlement it lacks is used) but needs
`DISPATCH_BUNDLE_ID_SUFFIX` (`yachts.dispatch.mobile` is registered elsewhere), expires after 7 days (rerun the
install; data stays), and allows three such apps per phone. A paid team re-signs yearly. Changing team or suffix
makes a new app with empty data.

Once per device: pair by cable and Trust, turn on Developer Mode (Settings, Privacy & Security; appears after the
first pairing), and on a free account trust the developer on first launch (General, VPN & Device Management).
`--ios-device` refuses without a valid signing config, finds real iPhones and iPads only (Xcode 27's `devicectl` also
lists simulators), builds with `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`, then installs and
launches through `devicectl`.

### Release

- `./run.sh --ios-device --prod` and the release check build the helpers with Cargo's `release` profile
  (`DISPATCH_HELPER_PROFILE=release`); a plain `xcodebuild -configuration Release` uses the faster `local` one.
  Release strips the executable after making its dSYM. The bundle is about 35 MB, 20 MB of it the three helpers.
- `test/ios-release.py` (`--simulator`, `--helper-profile local`, `--skip-build`, `--no-launch`, `--with-fast-suite`)
  builds Release for simulator and device (unsigned), checks the helpers' architectures, `version` and
  `protocol-version`, Info.plist's device keys (the four prompts, none naming a device; background refresh;
  `UIDeviceFamily` 1 and 2; the iPhone's three orientations and the iPad's four, `~ipad`; `UIRequiresFullScreen` off,
  which Split View, Slide Over and Stage Manager need), the privacy manifest's form, and that every required-reason API
  the executable imports (`nm -u`, selectors) is declared in `Mobile/App/PrivacyInfo.xcprivacy`. It launches the
  simulator build and prints the size table. The fast suite cannot run against Release (`@testable`, Debug-only demos).
- Not applied yet: deduplicating licence texts (2.8 MB), shipping helpers compressed (halves them, needs a new hash
  rule), `-Osize` for app code (needs measuring).

## Architecture and data flow

| Target | What |
| --- | --- |
| `DispatchMobile` | The app, bundle id `yachts.dispatch.mobile` + suffix, iOS 26.0, iPhone and iPad. |
| `DispatchMobileTests` | Unit tests hosted by the app: `Mobile/Tests` plus the Mac's Foundation-only tests by path. |
| `DispatchMobileUITests` | XCUITests, own scheme so unit runs never start the app. |
| `TermMobile`, `TermAppleMobile` | `Vendor/Term` and `TermApple` for iOS, without `Launch`, `Pty`, `Frames`, `Session`, `TerminalView`. Fonts are `TermFonts`: a top-level `Resources` folder breaks an iOS bundle's signature. |
| `MobileTransport` | Local Swift package (`Mobile/Transport`, see its README) over the Rust engine. |
| `Dictation` | Local Swift package (`Packages/Dictation`), chat dictation's engine, shared with the Mac; its Whisper engine is `Packages/WhisperEngine` (whisper.cpp in Swift, Metal and CPU backends). |

The iOS settings group sets `ARCHS = $(ARCHS_STANDARD)` (the project's native arch is the Mac's arm64e, which no
simulator matches). Zstd is not linked: `AppReplay` compiles for its types, but no journal ever starts.

### Shared sources

Mac sources the phone uses stay in `Dispatch/` and are listed by path in `project.yml` ("Shared with the Mac app").
They change only by `#if canImport(AppKit)` guards or additive, behaviour-preserving helpers.
`Mobile/Shared/System.swift` stands in for the Mac's AppKit-only `System` (a `SystemProvider` seam replacing it is
deferred). The transcript is shared: `ChatTranscript` (Dispatch/Chat) holds the merge rules (turn placement, item
insertion, the historical batch merge, record positions and seen keys) that the Mac's `ChatSession` and the
phone's `MobileTranscript` both run; `ChatSession` keeps only its view state around them (arrivals, unread, row
caches) and `MobileTranscript` the phone's record loop. Displayed items (`ChatPatch.displayedItems`), prompt
confirmation (`AgentInput.records`) and the elapsed text are shared too. So is the Mac's git layer below its loader:
the models, the parsers, the graph's lanes (`GitGraph`) and the log's commands and pages (`Dispatch/Files/GitLog.swift`:
`GitCommands`, the exact `files.git` argument lists, and `GitLogPages`, a filter's message and author queries merged),
which the Mac's `GitQueries` and the phone's `CommitsQueries` both run; `GitParsersTests` and `GitGraphTests` run on
both. Files shares the Mac's file models too (`FilesModels`, `FilesFormatting`; `FilesAvailability` stays the Mac's).
Mac views built on the Mac chat stack
(`ChatPermissionCard`, `SyntaxHighlight`, `AgentActivityGlyph`, …) are ported, not shared. Dictation's engine is the
`Dictation` package (`Packages/Dictation`: `Dictation`, the Apple and Whisper recognizers and `WhisperModelStore`,
over `Packages/WhisperEngine`, a Swift port of whisper.cpp that reads the same ggml models and runs them on Metal, or
on the CPU through Accelerate without a GPU), which both apps link; each app makes its `Dictation.shared` and
`WhisperModelStore.shared` (`DictationSupport.swift`, models in its support folder's `Whisper`), and has its own
controls (the Mac's `ChatDictationButton` and `WhisperModelRow`, the phone's composer mic slot and
`DictationSettingsView`) and its own settings storage.

### Areas and seams

| Area | Directory | Owns |
| --- | --- | --- |
| Hosts | `Mobile/Hosts`, `Keys`, `Store` | Host, key and known-host stores, `HostSession(s)`, plain SSH shell tabs (`ShellSessions`), New host, host detail, trust sheet |
| Tabs | `Mobile/Tabs`, `Mobile/App` | Shell, New button, Spaces, a space's tabs, the switcher, New space, `TabScreen`, the menu bar and ⌘ commands (`MobileCommands`) |
| Chat | `Mobile/Chat`, `Mobile/Agents` | `MobileChatSession`, Agents list, thread, approvals, queue, New chat |
| Terminal | `Mobile/Terminal` | `TerminalHostView`, `TerminalFeed` (`PlainShellFeed` for plain SSH), `TerminalPresence`, key capsule |
| Transport | `Mobile/Transport` | SSH, auth, host-key delegate, exec and shell (PTY) channels, bootstrap, plain SSH fallback, reconnect |
| Code | `Mobile/Code` | Diff viewer, code composer |
| Files | `Mobile/Files` | Files mode's listing (`FilesBrowser`), the file preview, `MobileFilesSource` |
| Commits | `Mobile/Commits` | The Files segment's Commits mode: `CommitsLog` per tab (`MobileCommits`), `CommitsQueries` over `files.git`, the list (H3), a commit (C2), a commit's file |
| Stats | `Mobile/Stats` | `HostStatistics` (per `HostSession`), the stats sheet, host detail's strip, the iPad popover's content |
| Resilience, Settings | `Mobile/Resilience`, `Mobile/Settings` | Network watching, launch cache, background refresh, Settings |

- `HostSession` is the one object the UI observes per host. Other areas get a `HelperClient` and `HelperTopology`
  from it (on a plain SSH connection a `ShellOpener` instead, `Mobile/Hosts/ShellChannel.swift`) and never see SSH: only `Mobile/Transport/Integration` imports `MobileTransport`, and the package stays
  platform-neutral. Every connection-state mapping is in `HostLinkMapping.swift`.
- `MobileComposition` is the root: on every `HostSessions.changed` (same main-actor turn) it feeds `MobileTabs.sync`
  and `ChatConversations.update`; Chat's urgency flows back into Spaces' dots. One `NavigationStack` holds the tab bar.
- **Identity.** Node, tab, space and backend ids change with every helper connection. Everything kept on the phone
  is keyed by host plus topology `key`. A cached or previous-helper snapshot is listed but not live
  (`topologyIsLive`) until the connection's first own topology.
- Tests use one scripted peer over `Pipe()` (`ScriptedHelper`) and `ScriptedHostSessionDriver`.

### Transport

The engine is Rust `russh` 0.64.1 (`ring`, `rsa`) behind a hand-written C ABI (`Mobile/Transport/Core`, crate
`dispatch-mobile-ssh`), built into an XCFramework by `scripts/build-mobile-ssh.py` in a minimal environment so Xcode's
settings cannot leak into ring's C build. swift-nio-ssh was rejected (Apple's has no RSA user keys or
keyboard-interactive; Citadel's fork signs RSA with SHA-1 only, refused by OpenSSH 8.8+, and lacks the 2026 pre-auth
ECDSA fix), and ring over aws-lc-rs needs no cmake. Third-party Rust enters only here; `helper/` stays dependency-free.

- Private keys sign in Swift (CryptoKit, Secure Enclave) through the external-signer callback and never cross the
  FFI. File keys are parsed in Rust. RSA signs `rsa-sha2-512/256`, never `ssh-rsa`.
- The host-key callback is answered later (`dms_reply_bool`), so the trust sheet can wait; the handshake deadline
  pauses meanwhile. `disconnected` fires exactly once.
- An exec channel is a socketpair fd pumped by Rust with backpressure both ways; `HelperTransport` reads it unchanged.
- A shell channel (`dms_shell_open`, plain SSH) is a session channel with a PTY: `pty-req` with the TERM and grid it
  is given (no pixel size, no terminal modes, no `env` requests), then `shell`, then the same pump. `dms_shell_resize`
  asks for a `window-change`: one engine task per shell sends them in call order, a size superseded before it went is
  skipped (the latest wins), one asked before the shell started is sent once it has, and changes after the close are
  dropped. `dms_shell_free` releases the handle only, the fd decides the channel's life. Unlike an exec, the end of the caller's input closes the channel (a PTY has no end of
  file): closing the fd ends the shell at once and reports `Lost`. A refused `pty-req` or `shell` is `DMS_REFUSED`.
- Limits: host certificates refused, user certificates not wired; no x86_64 simulator or Intel Mac slice;
  `panic = "abort"`; release-built even in Debug.

### Connection

`SSHHostSessionDriver` connects (host key through `KnownHostStore`), logs in, uploads the helper for the host's
`uname` to `~/.dispatch/bin/versions/<sha256>/` (or the runtime folder, see [Helper contract](#helper-contract)), starts it, greets it, reads `multiplexers.list` and
`backends.list`, waits up to 2 s for the first topology, then is ready. It pings with `echo` every 10 s. A host with
its Helper switch off stops after the login, and a helper that cannot be installed, started or used leaves the
connection up without it: both are [plain SSH](#plain-ssh).

- Lost link or helper: `reconnecting` at once (keepalive 15 s × 3), backoff 1 s up to 60 s, raced by `retryNow()`
  (network change, foregrounding, pull to refresh; on a connected link it probes `echo` within 3 s, `:` on a plain
  one, and closes a dead one). Refusals (host key, login, missing key) are final; after a host-key mismatch nothing
  retries until the user acts. Each connection decides again between the helper and plain SSH.
- Foreground connects every host, background disconnects. **Disconnect** in a host's stats (`HostSession.park`) ends its
  connection and leaves the host alone: the foreground, network changes, pull to refresh, an edit that reconnects,
  background refresh and watch requests all leave it down until a **Connect** or **Reconnect** the user asks for
  (`connectByUser`: the stats sheet, host detail, the multiplexer hint, the watch's host screen; Remove and retry lifts
  it too) or the next launch (nothing is saved).
- **Which multiplexer.** Connecting never starts a server. herdr's `backends.open` starts one, so herdr is followed
  only while its server runs (`running`) or the host asks for it; otherwise tmux, retried every 2 s. A preference
  change switches live without reconnecting; until the new one answers (a snapshot or no server) the host's spaces
  are unknown (`switchingMultiplexer`). New space on the other multiplexer sets that preference after its
  `backends.create`, so the new space shows up (one multiplexer's spaces per host). The exec channel names no herdr
  socket, so the helper uses herdr's own default (`HERDR_SESSION` or `default`, under `$XDG_CONFIG_HOME/herdr` or
  `~/.config/herdr`), as `herdr` typed in a shell does; only variables the login shell's `-c` exports (`.zshenv`)
  reach it.

## Helper contract

The phone runs, on an exec channel with no PTY and no `env` requests:

```sh
exec "$HOME/.dispatch/bin/versions/<sha256>/dispatch-helper" --remote --capabilities <HelperGrant> --stdio
```

**Install root** (`HelperBootstrap.Root`). A home folder mounted `noexec` takes the upload and its checksum but cannot
run it. When the probe found a usable runtime folder, the phone moves there: on hosts whose `/bin/sh` asks the kernel,
`test -x` already refuses the cached file (`SSHBootstrapScript.blocked`) and `install` moves on by itself; elsewhere
the helper exits with 126 before greeting, `fallbackRoot` names `.runtimeDirectory` and the driver installs and starts
it once more, on the same connection, from `$XDG_RUNTIME_DIR/dispatch/bin/versions/<sha256>/` (the
same private-folder checks; the phone's probe, `SSHBootstrapScript.runtimeProbe`, reports without writing anything
whether that folder is usable, and its `dispatch` folder is created only when the helper is installed there). Nothing
else falls back: a helper that exits before greeting gives `launchFailure`'s text (the folder that cannot run
programs, a helper that could not start, or its stderr) and the host goes on as plain SSH. The launch command's
checks write their `dispatch-setup:` reason to stderr only; stdout carries nothing before the helper's frames. Both apps send
the same cache check (`SSHBootstrapScript.cacheCheck`, pinned in `HelperRootTests`); the Mac's every connection still
starts with `probe`, and its home upload and helper launch are as before, while its cache check and login changed by
text only (replay migrations 0015 and 0016). The Mac tries the runtime root only once the home folder proved unable to
run programs, for grants without agent hooks ([security](security.md#ssh-integration)), and both apps word a helper that
exited before greeting alike (`SSHBootstrapScript.launchFailure`).

The grant is the Mac's full profile with hooks less file writes (`HelperGrant`: never `file.write`). Two per-host
switches narrow it: Chat off drops `hooks.configure` and `agent.*`, Files & git off drops `git.read` (`files.git`, read
only, and `files.branch`). Turning either off sends `permissions.reduce` to the running helper (a reconnect when that
fails); turning either on reconnects, as a grant only shrinks. The
phone's hello features (`interaction.options`, `chat.list`, `projects.recent`, `multiplexers.versions`,
`terminals.coalesce`, `launch.names`, `stdio.liveness`, `terminals.activity`, `chat.attachments`,
`memberships.append`; the Mac names
`terminals.coalesce` and `chat.attachments`) are specified in `helper/PROTOCOL.md`;
what they let the helper
do on the host, and the login-shell PATH probe, are in [security](security.md#dispatch-for-iphone). The client must:

- **Ping.** With `stdio.liveness` the helper exits after 45 s without a frame; send `echo` at least every 15 s. A
  drop can reach the host late (seconds through NAT or Lima), so a reconnect may briefly meet the old helper.
- **Publish screens.** `chat.send`, `queue.start` and typed answers are verified against the screen the client
  publishes (`terminals.publish`, ≤30/s); without it they fail with `terminal_unavailable`. So a conversation keeps
  its terminal attached (`TerminalPresence`) even when only Chat shows.
- **Reattach by key**, not id: after reconnecting, `backends.open`, find terminals by topology key, then `chat.open`
  and `terminals.attach` again.
- **Follow binding changes.** A Codex conversation starts with an empty session and gets its thread id with the first
  prompt; reopen `chat.open` on a new binding. `chat.open` answers with a `chat.history` notification and
  `backends.open` with `backend.opened`, not a response frame.
- **Re-enable integrations per connection.** `installation.install` state is in helper memory. As the Mac does for a
  newly connected host, every connection with Chat on installs Claude Code's and Codex's hooks (so an agent started
  outside Dispatch still asks here) and enables Pi's extension where it is installed. Pi's extension is opt-in, as on
  the Mac: New chat asks before installing it. A per-host refusal given on the Mac stays on the Mac; the phone's
  consent is its Chat switch.
- **Surface native trust steps.** Codex shows "Hooks need review" after the helper installs hooks; until the user picks
  "Trust all" in its terminal, approvals stay in Codex's TUI.
- **Keep the outbox.** A Claude Code or Pi queue of a named conversation lives in the host's queue store: it survives
  the helper, its item ids are the same for every helper and client, and the host sends it while no client is
  connected. After reconnecting the device matches its items by id; an item the host no longer holds was sent or
  removed there and is never added again. Only a queue of a conversation the agent has not named yet dies with its
  helper; the device re-adds those, and anything possibly in flight at the drop is paused for the user, never sent
  twice.
- **Expect input refusals** right after an agent starts (`input`: nothing was typed); send once more shortly after.
- **Send raw bytes** (binary tag 11) in `terminals.input`.
- **Scrollback.** tmux replays pane history on every attach, so its scrollback is the client's
  (`scrollback_app_owned`); herdr's is the server's (`terminals.scroll`, `terminal.scroll`).

**Replays.** Every phone-only behaviour sits behind a hello feature the Mac never names, so the Mac's recorded
sessions replay unchanged. Keep it that way: herdr's corrected end-of-workspace index for a tab moved without `before`
is `memberships.append`, since the Mac's recorded restores send that move and expect the old index. Exceptions to re-record when they show up: close-tab captures made with
macOS `/bin/bash` 3.2 (idle helper-created windows now terminate), and launcher captures that recorded the herdr tty
race (replay sees a second ownership ask).

## Behaviour

- **Hosts and trust.** Trust on first use per host and port; a changed key is a hard stop with only Remove and retry.
  An unreadable `known_hosts.json` fails closed (Retry or Reset), never read as empty. New keys are ED25519 behind
  `biometryCurrentSet`, or Secure Enclave P-256; neither signs unattended. Passwords and passphrases are
  `AfterFirstUnlockThisDeviceOnly` and the app's files class C, so background refresh and watch requests log in with a
  password while the phone is locked (older builds' items and files move at the first unlocked launch). A host's colour
  is `HostTint` of the machine identity at creation, so draws with the same hash. As the Mac's `HostRegistry` does, a
  new host takes the colour the fewest of the phone's hosts show (the hash breaking ties) and keeps it
  (`HostRecord.color`); the two apps agree only where their host lists do. A host's stats (Color) pick another: Automatic is the colour it was
  given (choosing it again gives the one the fewest other hosts show), a pick is saved in `HostRecord.color` with
  `colorPicked`; its Automatic row shows the colour Automatic would give. Colours are drawn by machine (`HostColorStore`,
  published from the saved list), so two hosts of one machine show the first's: the second's picker says so and is
  disabled. Two hosts
  reaching one machine and account (a LAN and a Tailscale address) show its spaces and agents once, under the first in
  the list, as the Mac keys a host by machine and uid; the other says "Same machine as …", and background refresh
  notifies once. A failed save stays in memory flagged unsaved, with a Retry notice in Spaces.
- **Wide windows (the unfolded iPhone Duo).** A window at least 600 points both ways (`MobileSplit`: the unfolded
  Duo either way up, not its cover screen or an iPhone in landscape) shows the phone's stack, tab bar and all, in a
  sidebar column and the tab it opens beside it, without a back pill; the sidebar marks that tab's row. By window
  size, not size class: the system's split views collapse in a compact width. Both columns show the one
  `SpacesNavigator.path` (`SplitPath`: the sidebar's routes, the last tab, what it pushed), so folding shows the same
  screens as a stack and unfolding splits them again. Columns by posture (`MobileSplit.columns`): laptop (taller than
  wide, the fold across) gives the tab a phone's 405 points and the sidebar the rest (263 unfolded: glyph-only tab
  bar, Agents rows putting their host first); book (wider than tall) puts the hairline on the fold, from the system's division
  region (`MobileFoldReader`, `reservedRegions(kind: .division, options: .includeInactive)`: inactive while flat,
  off centre on the Duo, 517.5 of 951 points), else the window's middle. The fold is DeviceHub's (the simulator window): its Closed, Partially
  Open and Open buttons under the device, for the device the window shows (two Duos share a name: check the window's);
  `simctl` has no hinge control. Unfolded, the app fills the inner screen (`simctl io <udid> screenshot --display=3`);
  folded, the cover screen is `--display=primary` and the default capture is the dark inner one.
- **iPad windows.** The same split, by window width alone, with the iPad's rules (`MobileSplit.Device.pad`, chosen
  by idiom so the Duo's numbers stay): it splits from 655.5 points (a 280-point sidebar beside a 375-point tab, the
  narrowest iPhone's width) and stacks below, exactly as the iPhone (I6, I6b: the phone's header, capsule, Files bar
  and Spaces tab bar). The sidebar is what `UISplitViewController` gives its double-column primary (measured on
  iPadOS 27 and checked against it by `MobileSplitTests`): 320 points in every full-screen iPad either way up, the
  window less 448 between 728 and 768 wide (296 on a mini upright), never "the rest" (970 on a 13-inch on its side);
  under 728, where the system only overlays its sidebar, 280 down to the split's edge. iPadOS 27's own window
  arrangements (Window Controls, hold Zoom, Move & Resize): every full-screen iPad, the top halves (1210 × 486 on an
  11-inch on its side, 744 × 561.5 on a mini upright) and a 13-inch's half on its side (683 × 909) split; the other
  halves (375 to 600 wide), thirds and Slide Over (375) stack. The stack gets a compact horizontal size class, as the
  system's sidebar column has: `TabView` then draws the phone's bottom bar with New as its circle. Sizes come from the
  window (the scene's bounds, then `MobileWindowReader`), never the screen.
  The split is the Mac's layout (I1–I8). **The sidebar** (`PadSidebar`) is Spaces' tree alone on its own stack, the
  tree the phone shows (`SpacesRoot` with `spacesSidebar`: no tab bar, no Agents section, the filter row moved into the bar): its bar row
  holds the pink sidebar toggle, "Spaces", the filter menu (`TabsQuery`'s All, Needs you and Agents, and Show offline
  hosts; the disc shows the filter's glyph, pink while one filters, the needs-you count on it) and Edit as a pencil
  (the filter and Edit one bar item: as two the bar folded them into its overflow menu); beside a windowed app's controls
  (`containerCornerInsets`) the title gives way where the row would not fit in 290 points (`PadSidebar.showsTitle`),
  so the controls stay out of an overflow menu down to 280. New space ⌘N is a glass capsule at its foot, above the keyboard
  (a hardware keyboard's bar lifts it, as the system's bars are). A space's row selects the space: the
  detail column shows the tab the space showed last (`SpacesNavigator.lastTabs`), else its first, and the row is
  marked on the lens (a stacked window's space screens leave the path when it splits, so the tree is beside the tab); the tree's host disc (`SpacesHostDisc`) shows the host's stats in a popover there instead of the
  sheet (I5: `HostStatsPopoverContent`, 360 points, presented by UIKit from the window, so no column clips it). A windowed app's controls sit in the sidebar bar's leading corner.
  **The detail column** (`PadSplitDetail`) has no header: the strip (`PadStrip`) above the column's own stack, so a
  screen a mode pushes (a file's preview, a commit's file) opens under the strip, in the column.
  The strip is the shown tab's space's tabs as pills in one glass track (state dot: blue for needs you or an unseen
  result, amber working; the agent's mark, `AgentGlyph`, from the conversation's agent or the program, or a terminal
  glyph; the title as the rows name it; the selected pill on the lens with × for Close Tab, 260 points at most, the
  others 200, titles truncating; when they do not fit every pill shrinks, the widest first, down to 120 points (the
  selected one 150) before any is left out, and past that the track keeps those that fit, the selected one always,
  with a "⌄ 3" overflow menu of the rest (`PadPills`, `PadPillsLayout`), so no pill is cut by the track's edge), then "+" (a
  tap a shell in the space; held: the space screen's menu, `SpaceNewTabMenu`: Shell, the host's agents started in a new
  tab of the space as New chat starts them, and In another space…), then the mode switch: Terminal, Chat,
  Files, Review and Commits as glyphs (`PadMode`), the shown one pink on the lens, Review with the comment count. Chat
  is offered unless the tab is a plain shell, Files where the host can serve it (`MobileFilesAvailability.showsModes`:
  not over plain SSH or without the Files & git grant, so S1 and S2 do not show on an iPad), Review and Commits inside
  a repository (`SpaceGitFacts`): while that is unknown the two hold their places, greyed and disabled, so the switch
  never changes its width when a repository answers (a tab showing one keeps it, so no frame shows Files first); the
  answer is kept with the split memory (`tabs.repositories`, `MobileTabs.knownRepositories`, 64 tabs at most), so a
  launch's strip is right from its first frame, and a restored Review or Commits applies only where the tab's folder was
  a repository last time (else Files).
  A mode is the phone's segment and Files mode in one (`MobileTabs.segments`, `filesModes`, observed): a window that
  narrows to the stack shows the same view, and the iPad keeps the shown tab's mode with the tab across launches
  (`tabs.shownMode`). Under the strip the mode's row (Files' breadcrumb and buttons, Review's branch and counts with
  Create review as a pink pill, Commits' branch and count) and the line the phone's accessory is, as a banner (offline
  with Reconnect, a review sent with Undo). Terminal fills the column (the key capsule only without a hardware
  keyboard); Chat is a 720-point column in the middle; Files is the phone's listing. Review and Commits are their list
  at 360 points, a hairline and a pane (`PadListPane`): a change's diff (`ReviewDiffScreen` without its back pill, its
  header the file, the counts, Diff / Source, Comment and ⋯) or a commit (`CommitDetailScreen` in its pane form, the
  short hash, age and author, ⋯), the list's row for it marked; before a choice the pane says "Select a change to see
  its diff" or "Select a commit" (I2b, I3b). A tab's panes live with it (`MobileTabs.paneRoutes`); a change that
  leaves Review's list (committed or reverted meanwhile) empties its pane (`FilesModeSlot.paneShows`). Closing the shown
  tab shows its strip neighbour (the next, else the one before), as the Mac's strip does, and so does a tab the host
  closed (another client, its shell's exit), found on the topology's sync (`SpacesNavigator.reconcile`, else the
  space's first tab, else no tab and the sidebar back); the gone tabs' panes go with them.
  **The sidebar hides** (its toggle, Toggle Sidebar ⌃⌘S): it slides off at its own width, still alive (its stack and
  scroll stay), the tab takes the window, and the strip leads with the sidebar's pill (the needs-you count) and the
  space's capsule (the host's glyph for its stats, the name and branch for the space switcher, P3) after the window
  controls (`containerCornerOffset`); the sidebar comes back with the pill, ⌘1 or ⌘2, or when no tab is left
  (`SpacesNavigator+Sidebar.swift`). As iPadOS's split views come back as they were left, an iPad keeps the tab on
  screen, its mode and the sidebar's state (UserDefaults `tabs.shownTab`, `tabs.shownMode`, `tabs.sidebarHidden`,
  written where the host cache is: not in tests, the scripted demo or the sample unless `-DispatchSplitMemory YES`): a
  launch whose window splits shows that tab, if the cached topology still has it, with the sidebar as it was, from the
  first frame (`restoreSplit` runs before `MobileRoot`'s first body); a stacked window opens on the tab bar, as the
  phone always does. The shell's sheets (New host, New chat, Settings) and the host key questions hang off the split
  itself on an iPad, which has no tab bar to carry them. Sheets are the system's form sheets
  in the middle of the window, without the phone's grabber or detents (New tab's space picker had the phone's
  `[.medium, .large]`, which made a card at the window's bottom, its list cut by the screen: `mobilePhoneDetents`); the
  host key questions, taller than a form sheet, are page sheets (`mobileTallSheet`), their buttons a `safeAreaBar`.
  Controls that span a phone keep a phone's width on an iPad, centred: the stack's capsule at most 400 points
  (`TabSegmentCapsule.maxWidth`), the composer's code key row the terminal capsule's 404. The text names the device it
  runs on (`MobileDevice.name`: "from this iPad", "Removes … from this iPad"); the phone's text is unchanged. The
  pointer gets the system's highlight on rows, glass pills, discs, the strip's pills and modes (plain buttons and
  interactive glass have none of their own). With a hardware keyboard, Tab and the arrows move nothing in the Spaces
  lists (stacks of buttons, not focusable lists). The sidebar's slide moves the tab without resizing it, as the Mac's
  `NativeSplit` does: the tab keeps the wider of its two widths for the whole slide (`sidebarSliding`, the window's
  edge clipping the overhang), so its terminal and chat lay out once a slide. A live resize changes the tab's size
  every frame, as the system's split view does; the terminal coalesces it (Terminal).
- **Spaces.** herdr workspaces and tmux sessions are spaces, windows and tabs are tabs. A split tmux window shows one
  pane; the phone never splits. The helper's native multiplexer never counts (its sessions die with the connection).
  Close follows the Mac's policy: Close Tab sends `close.request` `check` and terminates only verified idle work,
  otherwise detaches; a space offers Detach and Terminate… and never ends by itself. An unrenamed tab is named as on
  the Mac (automatic tab names): the agent's conversation title, then for a herdr tab numbered by position its pane's
  name or folder; the Agents rows use the same title. New tab sends no folder, so the multiplexer opens it in its
  focused pane's current directory.
  Paths shorten to `~` by `hello.account.home` and `login_home` (longest match wins), never by guessing
  `/Users/<name>`.
  **The tree** (P1, W0; `SpacesRoot`) is the Spaces tab: no flat list and no sort. Under the large title a row of
  glass chips filters it (`TabsQuery`, kept in UserDefaults): All, Needs you (with the count of conversations
  waiting on the hosts reached now, `ChatConversations.needsYouCount`, the one count of the back pill, the app's badge
  and the watch: only the hosts and spaces where an agent waits) and Agents (the spaces running one; the tab bar's Agents is
  the same set by conversation); a filter leaves out the hosts without a match, the Detached rows and the OFFLINE group. Each host is a
  section: its name (a tap folds or unfolds its spaces, kept on the device; folded it says "2 spaces · 1", the spaces
  and their unread), the multiplexer chip, and a 34-point glass disc with the host's glyph and its connection dot
  (green, amber on its way, grey) that opens its stats sheet (`hostStatsSheet`). A space's row has its name, its
  folder's branch (`SpaceGitFacts.resolve`: once per folder and connection, nothing polled), the amber dot while
  something works and the unread count in blue. A host with detached work ends its card with a Detached row and the
  count, which opens the host's list (`SpacesDetachedScreen`): the topmost detached workspace or tab nodes of the
  topology (`MobileWorkspace.detached`), each with Restore (`memberships.move` back under the parent the server kept,
  herdr's; `memberships.place` for a tmux retained view, which has none; out of the list at once, until the topology
  shows it restored or the request fails), Remove from list (a tmux retained view's `close.request` terminate, which
  forgets only the descriptor, as the Mac's Remove does; a herdr node is only no longer listed on this connection) and
  Restore all; the work keeps running either way. Hosts not connected nor on their way (`SpacesHostState.offline`) go
  to the OFFLINE group at the end, header rows only (the name and chip dimmed, "as of 2h ago" from its last update,
  the glyph disc dimmed, which opens the stats sheet's offline variant); the group's header counts them and folds it
  (W0b, remembered); held, it has the "Show offline hosts" switch, which Settings' Hosts section has too (both in
  UserDefaults, `tabs.offlineFolded`, `tabs.showOffline`; a run that saves nothing, scripted or a live test, keeps them
  and the filter in a suite emptied at each launch). Edit mode lists every host, offline ones included, with
  today's controls. A connected host known to have no spaces offers New space below it. A host shows one
  multiplexer's spaces at a time: its header (and host detail's Spaces header, New space's host field) marks which,
  "tmux" or "herdr" in a grey chip, from `HostSession.spacesMultiplexer` (the followed one; no chip before one is
  followed or while a switch has not answered).
  **A space** (P2, `SpaceTabsScreen`): the back pill, the space's name with its branch (polled with `watch` while the
  screen shows) over host · path, and the space's menu ("…": Rename…, New tab, Edit tabs, Detach "keeps everything
  running", Terminate… "ends every shell and agent", which asks). Its tabs in server order, as the Mac strip shows
  them: the state dot, the agent's mark (`AgentGlyph`: Chat's key for the conversation, else the bound process's or the
  topology's names) or a terminal, the title as the Mac names it, "open" on the tab the phone showed last in the space
  (in the split, the one beside the sidebar), the time, and a line (`TabsStatus`): an agent's current step and how long
  its turn has run (the step cached on the session, `MobileChatSession.currentStep`, so streamed words redraw no row;
  the time counted each second by the row itself, only while it works), the approval or question in the primary colour
  while it waits, its last message once done (the watch's tab rows get the words, never the running time); a terminal's own
  title (OSC), else its program, else its folder. A row swipes to Detach and Close and holds the tab's menu (Rename…,
  Close Tab, Detach, Terminate…, Edit tabs). Edit tabs (P2d) shows the list's delete controls and drag handles (Close
  detaches a tab unless it is idle); a drag reorders on the server (`memberships.move` before the new neighbour: tmux's
  window order in its session, herdr's tab order), the rows keeping the new order until the
  move's answer (done or refused) or a snapshot naming the moved tab arrives (`MobileWorkspace.reorder`); a tab made
  meanwhile keeps its server place. herdr's `tab.move` puts a tab before the one at `insert_index`, counting the moved
  tab where it is, so for the end the helper sends one past the last tab to a client of `memberships.append` (the
  phone) and the last tab's index, which lands before the last tab, to any other (the Mac's recordings). The New tab capsule (P2e) opens a shell; held, a menu: Shell ("zsh in ~/src/app"), the host's agents
  (`launches.list`, each with the model New chat would start it on) started as New chat starts them and opened in
  Chat, and "In another space…" (New tab's picker). A plain host's Shell space has New tab, swipe Close and "Close all
  shells", no Rename, Detach or reordering.
  **The switcher** (P3, `SpaceSwitcherSheet`): a tab's host disc opens it over the tab (detents 560 points and large; an iPad's form sheet, the iPad strip's space capsule opening it too):
  the space's name, branch and path as its title; its tabs, the shown one checked on the lens, a tap switching the
  screen to that tab in place; New tab (held, P2e's menu); the host's row ("34% cpu · 34% mem · 18 ms" from
  `HostStatistics` and the latency; how it is connected while it has none) to its stats sheet; Rename and Close space
  (Detach or Terminate…), whose dialogs show over the stack once the sheet is gone. New space offers the host's
  installed multiplexers (never native: its sessions belong to the helper, which ends with the connection, so with
  every trip to the background). Holding New space (that row, or New tab's picker) gives a system menu of hosts and
  multiplexers that makes a space at once with the form's defaults (home, no name) and opens it as Create does; in New
  chat the same entries are a "New space on" submenu of the Space pull-down (a pull-down's items cannot be held), and
  a space made there (or with "New space…", whose form opens over New chat) becomes the chat's instead of opening.
- **Tab screen.** Under the header a glass capsule switches the tab's views (`TabSegmentCapsule`, H0): Terminal,
  Chat and Files, each a glyph and title (Chat `text.bubble`, Files `folder`), the shown one on the lens; a plain SSH
  shell tab has Terminal and Files. The Files segment carries the tab's review comment count (`FilesModeContent.reviewCount`).
  Each segment is a button labelled with its title inside a container (`tab-segments`); titles grow to xxxLarge. The
  segment and the Files mode each tab showed last stay for the run (`MobileTabs.segments`, `filesModes`); ⇧⌘C toggles
  Terminal and Chat.
- **Files.** The Files segment holds the system tab bar with Files, Review and Commits (`folder`,
  `pencil.and.list.clipboard`, `clock.arrow.circlepath`; `TabFilesSegment`), Review badged with the tab's comment
  count, and the bar's accessory slot. Outside a git repository only Files shows and the bar hides. Each mode's body,
  row under the capsule (breadcrumb or branch, round `MobileBarButton`s), accessory and pushed screens (and Review's
  count) are its `FilesModeSlot` in `FilesModeContent`, which each area installs from its own file
  (`MobileComposition+FilesMode.swift`, `+ReviewMode.swift`, `+CommitsMode.swift`); a pushed screen goes on the app's
  one stack (`TabsRoute.files`), so it covers the header, the capsule and the bar, and closing the tab takes it off.
  The system tab view gives its tabs only the header's top inset, so each mode's content adds the capsule's and the bar's
  (`FilesBarInset`), hidden until both are measured.
  Whether a host can serve Files is `MobileFilesAvailability`, from the host as Spaces sees it: a plain SSH login
  shows "Files needs the helper on mba2" with Not now and Install helper… (S1: the Helper switch on, or a new
  connection when it is on already; `HostSessions.useHelper`), the Files & git switch off "Files is not allowed on
  mba2" with Change integration… (S2: host detail), both without the bar or the capsule's badge; a link that is down
  or reconnecting after a drop keeps the modes, dimmed, with "mba2 is offline · 2m ago · Reconnect" in the accessory
  slot (S3, `FilesOfflineAccessory`), while a connection being made (foregrounding) changes nothing. Not now returns
  to the segment shown before Files. The repository and branch of a tab's folder are `SpaceGitFacts`, per host and
  topology key, only through a connected helper with `git.read`: the root (`files.git rev-parse --show-toplevel`, then
  `files.branch`) once per folder and connection (again when the folder, the connection or the grant changes, or the
  read failed), the branch every 2 s (the Mac's branch names' cadence) only while the Files segment shows or another
  view watches it. One read per key at a time, the latest folder next; the previous facts stay until the new read
  answers and a failed read keeps them. Closed tabs' and spaces' facts go with the topology.
- **Files mode** (`Mobile/Files`, installed from `MobileComposition+FilesMode.swift`; H1). Each tab keeps a
  `FilesBrowser` while it lives (`FilesBrowsers`): the folder shown is the tab's (its active pane's cwd) and follows it,
  so a cd moves the listing whatever folder the user opened, while tapping a folder or a crumb moves only the listing
  (each folder opens at its top). The breadcrumb ("web › src", the folder glyph before it, each crumb but the last
  opening its folder; held at its end once it scrolls) starts at the repository's root (`SpaceGitFacts`), else `~`,
  else "/". Rows: folders first, then by name, date (newest first) or size (largest first), a folder in the host's tint
  with "3 items · 4m", a file by kind with "2.4 KB · 2d" (ages now, m, h, d, w, mo, y), git's letter in a
  `GitStatusBadge` (M, A, D, R, C, T, ? untracked, U conflicted; ignored and clean files none), a chevron; the footer
  counts them ("The first 10,000 items" when the helper cut the listing). Everything goes through
  `MobileFilesSource` (read-only by construction: list, read, git; `HelperMobileFilesSource` is the helper's, through
  the host's connected client while its Files & git switch is on): `files.list` for the shown folder (again behind
  a listing read within 5 s only on pull to refresh, Refresh, the app coming to the foreground, the tab's agent ending
  its turn or the connection coming back, which also reads a listing first asked offline), and for each folder row as
  it shows, four at a time with at most 32 waiting, for its count (kept, so opening it shows at once; a row that scrolls
  away or the listing leaving the screen cancels its read; a count that failed is not asked again in the run). A tab
  keeps at most 48 listings, the least recently used going first. A folder that is gone on a later read shows as gone,
  not with its last contents. `files.git status --porcelain=v2 -z --untracked-files=normal` (1 MiB) runs in the
  repository's root once there is a connection for it (a root first seen offline is asked when the connection comes)
  and on each of those refreshes, a newer read cancelling the one running; parsed by the Mac's `GitParsers` and
  `GitMarks`; a status cut at its bound says "git status truncated" under the footer. The "…" menu sorts (one choice for every tab in a run, as is Show hidden files, which lists again with
  `hidden`), refreshes and copies the folder's path. Search filters the folder's rows by name (any case), then, 250 ms
  after the last keystroke, walks below it breadth first through `files.list` (listings read before reused, hidden names
  only when shown and again when that changes, never into `.git`, `node_modules`, `.build`, `DerivedData`, `target`,
  `.venv` or `__pycache__`, nor from above into `/proc`, `/sys`, `/dev`, `/run`, `/Volumes`, `/System/Volumes` or
  `/private/var/vm`; at most 400 folders looked in, 12 deep and 10 s, then "Stopped after N folders"; at most 200 hits)
  and lists those under "Below" with their folders. Loading draws placeholder rows; an empty folder offers Show
  hidden files; a folder that is gone offers its root; no permission, offline (nothing asked; a listing read before
  stays) and other failures say so with Try again, in S1's grammar. Offline the segment dims the last listing.
- **File preview** (F2, `FilePreviewScreen`, pushed on the app's stack as `FilesRoute.preview(path)`, which Review and
  Commits push too, a relative path being the repository's). The back pill names the screen below (the tab's mode, or
  the folder or mode pushed before), the title is the name, the subtitle "src · 1.8 KB · 25m ago · TypeScript" (the
  folder under the root, the size, the age, `FilesFormatting.kindName`). `FilePreview` reads the first 256 KB with
  `files.read`: a NUL or bytes that are not UTF-8 (a character cut at the window's end allowed) make it binary, `md`
  Markdown, image extensions an image (read whole up to 32 MB, else binary; its pixel size read from the header first:
  past 40 megapixels only a copy 4,096 pixels on its longest side is decoded, inline and in the viewer, and past 32,768
  pixels a side none, the file shown as binary), anything else text in the diff viewer's palette (`CodeSyntax.lines`
  off the main actor, tabs as four spaces). Longer text shows its head with "Showing the first 256 KB of 3.4
  MB" and Load all (the whole, at the head's revision, up to 8 MB; a file changed meanwhile is read again from its
  head). Code has line numbers, one row a line scrolling both ways (Wrap lines in the menu), 12.5 points by default and
  pinch to zoom, kept with the diff viewer's size (`CodeFontSize`); Find counts the matches (any case), steps through
  them with the arrows or Return and scrolls to the current one. Markdown renders with chat's renderer (Show source in
  the menu shows its code; past chat's 2,000 lines the rendering stops and says so, with Show source for all of it); an image fits the screen and opens in the attachment viewer; a binary shows its kind and
  size with Share only; a path that is a folder (a read the helper refuses that lists) shows that folder's listing, pushed,
  with its own breadcrumb row. The "…" menu: Copy path, Copy contents (whole text only), Share (the file's bytes, read
  whole up to 64 MB, written to `tmp/Files/<uuid>/` for the share sheet and deleted when it closes; the folder is
  emptied at launch), Attach to chat and Open in Terminal.
  "Ask claude" (the tab's agent as its conversation names it, else the tab's program; hidden in a tab without an
  agent) and Attach to chat switch the tab to Chat, take the Files screens off the stack and attach the file as the
  composer's attachments do (`MobileChatSession.attach`: read through `files.read`, stored by `attachments.put`) once the
  conversation takes attachments (within 15 s of opening; else the composer says "Couldn’t attach …: the conversation
  isn’t ready"). Open in Terminal is offered for a folder whose name has no C0 or C1 control character, DEL or line
  separator, while the tab's program is a shell and the host connected; tapped, it checks again (the window's program
  a shell, no agent bound, no full-screen program on the emulator's screen; else "The terminal is busy") and types ^U,
  `cd '<folder>'` (a bracketed paste when the shell turned that mode on) and Return into the pane (`terminals.input`,
  `FilesAsk.typing`), then shows Terminal. Nothing
  is written on the host: the grant has no `file.write`.
- **Commits** (H3, C2; `Mobile/Commits`). The mode's bar names the branch ("All branches" for every ref, the author
  under an author filter, "HEAD c81a2f4" when detached) and the count ("148 commits", "200+ commits" while pages
  remain, "12 matching" under a filter), then Search and the filter menu (Current branch / All branches, Author with the
  loaded log's authors, Signed only), tinted while a filter is on. Search replaces the row with a field: what is typed
  applies after 300 ms as the Mac's search does, `--grep` and `--author` run side by side and merged by date
  (`GitLogPages`); an author filter runs `--author` alone and the search then narrows its subjects; Signed only keeps
  the commits whose raw headers carry a signature. The list is one line per commit, subject and mono age, over a graph
  drawn from the parents (`GitGraph`, the Mac's lanes): the first lane 26 points in and 20 between lanes, the current
  branch's first-parent chain green, other lines amber, each row's text 22 points past the last lane it draws in, so a
  merged span indents; lanes past a quarter of the width fold into a "+n" count. A filtered log draws its dots alone.
  A hollow "Uncommitted changes ›" row heads it when the work tree has changes, joined to HEAD (it opens Review). No
  separators. Pages are 200 commits from the tip read first; the next is asked when the end row is in sight and stays so
  for 150 ms after the last rows went in. A filter the phone applies to the pages (Signed only, an author's log searched
  by subject) reads five pages by itself, then the end says how many commits it read with Load more; while pages remain
  an empty filtered list says "Looking further…", never "No matching commits". Showing the mode, the branch or the
  connection changing, and pull to refresh read the refs and HEAD, and the pages start over only when either moved;
  whether the work tree changed (`status --porcelain=v2`, 64 KB) is read beside them and the uncommitted row comes when
  it answers, never holding up the log. A read given up (a newer one, the view going) changes nothing. A failed first read says why
  with Try again; a later one keeps the rows and says it under them; without a helper to ask the list waits for the
  host. A commit (C2) is pushed over the tab: back pill "Commits", the short hash with "25m ago · Alex Rivera", "…" with
  Copy hash, Copy subject and Copy patch (`show --format= -U3`, a merge's `diff -U3` against its first parent, as its
  files are listed; up to 8 MB, a longer patch copies its start and says so, a failure says why); a card with the subject, the message, the ref chips (the
  checked-out branch filled green, branches green, tags amber, remotes outlined) and the signature's verdict, which
  `verify-commit --raw` gives once the commit is opened ("Signed · SSH key" green for a trusted key; not certified,
  unknown, expired, revoked, bad and unverified in the Mac's words and colours; "Not signed" without one; a check the
  host did not answer is unverified with "Check the signature again"; a tap shows the signer and the key); Author, Committer and Committed when someone else committed it or later, Date ("Today, 1:43 AM"),
  and the parents (a merge's "First parent" and "Merged"), each of which opens its commit; CHANGED FILES with the count
  and +n −m, and a `MobileChangeRow` per file. A file opens its diff in the commit (a merge's against its first parent),
  read-only, with a Diff / Source bar at the bottom: Source is the file as the commit left it (the diff with the whole
  file as context, up to 2 MB) with the commit's changes marked; pinch zooms as the turn's diff viewer does. The detail
  is its own view (`CommitDetailBody`), so an iPad pane can hold it. `MobileCommits` keeps the last eight tabs' logs (one
  let go while a pushed screen holds it comes back to its tab); a log keeps 40 commits' files and 4 MB of diffs and
  sources, the least recently used going first. The Files modes' pages sit under the tab's bar: the system tab bar's
  pages get the navigation bar's inset but not the `safeAreaBar`'s, so `TabFilesSegment` pads each page by the
  difference between its own top inset and the segment's, both read in the same layout pass (`FilesPageInset`), so no
  frame has a wrong one.
- **Review.** The uncommitted changes of the tab's repository (H2), one review per host and repository root
  (`ReviewPlace`; every tab in it shares the comments, as on the Mac). The Mac's models are shared (`GitModels`,
  `GitParsers`, `GitDiffPresentation`, `Review`, `ReviewRefresh`, `ReviewRepository`), so placement, the review text
  and `reviews.json` are the Mac's. `MobileReview` (one per composition) holds the comments, each repository's
  `ReviewChanges`, the review just sent with its Undo, the agents a review can go to and how it gets there; the slot is
  installed from `MobileComposition+ReviewMode.swift`. Reads go through `ReviewGitReader` (the helper's
  `ReviewHelperGit`, only with a connected helper and the Files & git grant): the Mac's commands (`status
  --porcelain=v2 --branch -z --ignored --untracked-files=normal`, both sides' `--numstat`, concurrently, 8 MiB; counts
  apply only to paths the status lists), the first 50 untracked files counted from a `files.read` of at most 256 KiB
  each within 4 MiB per status (larger or binary: no count), sizes of at most 16 binaries (`diff --stat`), a change's
  `diff [--cached] -U3 -- [old] path` (pathspecs as `:(literal)`; an untracked file read up to 2 MiB and shown as one
  added hunk, as `GitQueries.untracked`), whole files by `files.text` (refused, binary or over 2 MB: none). One status
  read per repository at a time, a refresh asked meanwhile once after it; a failed read keeps the last list (a status
  of -1 or a dropped link silently). The list reads on appear, every 2 s while it shows, on foregrounding, on pull to
  refresh and when an agent's turn ends (`MobileReview.changed(host:)`); offline nothing is read and the last list
  stays, dimmed (S3). Sections STAGED, UNSTAGED, UNTRACKED with counts (empty ones hidden), `MobileChangeRow`s with the
  status letter (A M D R C T, U for a conflict, ? untracked), a rename's "old → folder/", a binary's
  `GitChangesText.binary`, the file's comment count for that area (`ReviewComment.shows`); "No changes", "No matches"
  while searching, a spinner only after 400 ms, "Too many changes: showing the first N". The bar: "⑂ branch · N files
  +a −d" (counts hidden offline) and Search (filters by path, `GitStatus.matching`). The accessory: "Create review · 3
  comments on 2 files ›", or for a minute after Send "✓ Sent to claude · 3 comments · Undo" ("Copied" after Copy; S4).
  The Review badge and the capsule's Files badge are the repository's comment count.
  A row pushes `ReviewDiffScreen` (`FilesRoute.review`: path and area; also usable as an iPad pane, `showsBack`), which
  reads the diff and the working-tree file together before it draws. Rows from `GitDiffPresentation`: 20 pt, 12.5 pt
  monospaced (both scale with Dynamic Type), old and new numbers, a +/− column, `CodeSyntax` colours, lines truncated
  with "…", hunk headers in the unread blue; folds and the gaps between hunks are "N unmodified lines" rows that open in
  place (a gap with the file's lines), by themselves when they hold a commented line. Diff / Source: Source is the file
  with the diff's added lines tinted (without the file, the diff's new side). The file's comments for the diff's area
  are placed as the Mac places them (`ReviewPlacement`): the range tinted, a glass count chip on its first row that
  opens a glass card under the range (location and age, Edit, Delete, an "n of N" stepper through the file's comments,
  ×); file comments and comments not found among the rows are cards above the diff; a comment whose quoted lines are
  no longer in the file (`ReviewRefresh.relocate`) is S5's amber "Outdated · was lines 12–14" card with Keep for the
  file (a file comment, same id and quote) and Delete. A tap selects a line, another extends or shrinks the selection,
  the handles drag either end; the pink "Comment on 45–48" pill becomes the glass composer (`CodeEditorField`, the
  dictation mic, send) above the keyboard, and Send writes a `ReviewComment` with the Mac's fields (`System.uuid()`,
  `System.date()`, the rows' quotes, the diff's area); Edit reuses it. Comment with nothing selected hints "Tap a line
  to comment on it" and offers a file comment. ⋯: Copy path, Copy diff, Open file (Files' preview route), Comment on
  file; Review never stages or changes a file.
  Create review (R5, a full-height sheet): the To row (the agent's glyph, "To claude", "this tab · app · fable-5.1"; a
  menu of the space's agents and Copy only), "3 COMMENTS · 2 FILES" with each comment's file, lines, first quoted line
  and text (swipe to Delete; a tap closes the sheet and opens the diff on that comment, `MobileReview.reveal`), the
  overall comment (`CodeEditorField` with dictation), and pinned Copy, Preview (the exact markdown) and "Send to
  claude"; a tab without an agent says "No agent in this tab · Copy the review, or send it to claude · app" and offers
  Copy review (R5c). Send and Copy first find every comment's line again in the files as they are now
  (`ReviewRefresh.refresh` through `files.text` and the diffs; again, up to 3 times, if the review changed meanwhile;
  "Checking the lines…") and render `ReviewText` (root, host name, branch and HEAD). Send goes through
  `MobileChatSession.sendConfirmed`, the composer's routing awaited ("Sending…"): to an idle agent once `chat.send`
  confirmed it, else once the device queued it; the comments stay until then and leave only what was sent (a comment
  written meanwhile stays). A send that failed (the terminal went, the link dropped, a refusal) takes nothing: the
  review goes into the conversation's draft (a draft already there is kept among the saved ones, as on the Mac) and
  the sheet says so ("… The review is in claude's draft; the comments are still here."), else the accessory does.
  Undo, for 60 s, brings the comments back at once and withdraws a queued review (`MobileChatSession.withdraw`: on the
  device at once, in a verified helper's queue once `queue.remove` answers, asked once more while another queue change
  runs); when the helper refuses (`busy`: being typed) the accessory says "Already sent · comments restored", and for a
  review an idle agent got at once "Comments restored · claude already has the review" (5 s). The watch mirrors the
  Undo of a queued review only (`WatchReviewEvents.post`, `finished` when the window closes or the phone's Undo takes
  it; its Undo awaits the same withdrawal, too late when refused); a delivered review is posted without a window. Copy
  goes to the pasteboard with the same Undo and no watch event. `reviews.json` is read on first use (a badge, the
  list); a file that cannot be read is never written over, comments live in memory and the list shows a banner. Remove
  all data deletes `reviews.json` and starts the repository over. A pushed diff reads its change again when an agent's
  turn ends on the host and on foregrounding, leaving the screen as it is when nothing changed.
- **Space names.** As on the Mac (`Space.usesDirectoryName`), a new space is named after its folder ("/" for the root)
  and follows it until renamed. On tmux and herdr the server keeps that name, so the Mac and the phone agree: the
  helper names a tmux space after its first window's folder while the windows' `@dispatch-window` option has
  `usesDirectoryName` (`entities.rename` clears it), and herdr labels an unlabelled workspace after its pane's folder.
  The phone sends no name for a space made without one (New space's Name left empty, whose placeholder shows the
  name, and the quick menu); a typed name is set with `entities.rename`. tmux's fallback for a server with several
  sessions (`memberships.place` of a window, which needs a label) labels it with the folder's name and renames a
  typed name once the window shows in its new space.
- **Times.** A tab's own time is when it last had activity: the server's time for it (`terminals.activity`: a tmux
  window's `#{window_activity}`, the last output in any of its panes, whole seconds) or the last change the phone
  saw between two live snapshots of one connection (name, program, folder, binding, a new tab), whichever is later,
  or nil. A chat tab's row time is the later of that and its agent's newest record (`chat.list` `time_ms`, the
  Agents time); the Activity sort uses the same value. Server times are read on each live snapshot and every 30 s
  while connected, and kept per host and topology key (`TabActivityStore`, never node ids), so the next launch shows
  them before the host connects. herdr 0.9.5 reports no times and an older helper lacks the feature: those tabs
  keep only what the phone saw. Changes found across a gap (the launch cache against live data, a reconnect, a
  newly followed multiplexer) happened at an unknown time and move none.
- **Chat.** `chat.open` only for a bound terminal; the conversation is accepted once `chat.history` names the same
  process. Answers go on the subscription that delivered the request. Losing link or binding pauses input and keeps
  transcript and drafts. Dots follow Mail: blue for needs you or unseen, amber for working; a conversation's first
  sight is its baseline. As on the Mac, needs you is an open approval or question (`chat.list` `waiting` for rows not
  open) or the agent's own attention, and working is a running turn (subagents left running after it do not hold back
  its result); seen markers stay per device. A command (`/…`, `!…`) goes at once when the agent is idle, even with
  messages queued, and otherwise queues as a command: `/…` in the helper's queue with `command`, `!…` (which the
  helper's queue refuses) on the device until it reaches the head of an idle queue. Queued messages belong to the
  agent process they were typed for; Stop pauses the device's own until Resume, and Send now refuses paused or
  uncertain ones. Claude's thinking shows inline and muted; agent messages render Markdown blocks (headings, lists,
  quotes, code, tables) by the Mac's rules (`ChatMarkdownBlock`).
  **On an iPad**, a hardware keyboard drives the composer as the Mac's (`ComposerHardwareKeys`, from
  `ChatEditorTextView` and `ChatComposerShortcuts`): Return sends; Shift-Return starts a line and puts the draft in
  editor mode (`ChatDraft.multiline`, also set by any newline), where Return starts lines and ⌘Return (or ⌃Return)
  sends, and a small "Editor · ⌘↩ sends" badge says so; ⌥Return steers into the running turn (the phone's long press);
  ⌘E toggles editor mode; Esc leaves editor mode, else stops a running turn keeping the draft, else leaves the field.
  An input method's open composition keeps Return and Esc (the commands decline). Holding ⌘ lists Send, Send into
  Running Turn and Editor Mode only. The software keyboard's Return still starts a line, as on the phone. Opening a
  tab in the split's detail column focuses the composer only while a hardware keyboard is attached
  (`HardwareKeyboard`); a touch iPad gets no keyboard it did not ask for. With a hardware keyboard the composer's key
  row stays away (the keyboard has its keys); on a touch iPad it rides on the docked keyboard above the keyboard's own
  shortcut bar, and the dictation slot is the phone's. A floating keyboard leaves the composer at the bottom, as the
  terminal's capsule: SwiftUI keeps a keyboard inset for it, which lifted the composer part of the way and under the
  keyboard, so the thread ignores the keyboard's safe area while `MobileKeyboardReader` (Mobile/Shared, the terminal's
  `keyboardLayoutGuide` rule) says it floats; the user moves the keyboard. Wide columns keep the Mac's measure (`ChatMeasure`): a bubble keeps
  the phone's share (78 % user, 86 % agent) up to 80 characters of its text plus padding (about 809 points at the
  default size, scaled with Dynamic Type), on the speaker's side, uncentred as on the Mac; thinking, notes, the queue
  card and message details' quote stop at the same width, code blocks and tables use the bubble's. Message details
  push in the detail column's own stack. In the narrowest sidebar (under 300 points) an Agents row puts its host at
  the start of line two so the name stays whole. Chips, the steps disclosure and the composer's buttons light under
  a pointer.
- **Thread tools.** A chat tab's header has a ⋯ menu beside the host disc (`ChatHeaderControls`, through
  `TabsContent.chatTrailing`; beside the Duo's sidebar, where the switch takes the disc's place, before the switch): Search,
  Conversation Mode, Manage Goal, and the side conversations the agent offers. Each agent turn ends in a footnote under
  its last bubble, "5 steps in 1m 26s · 2 files +38 −4" (`ChatTurnSummary`: the steps as the Mac groups them, the turn's
  duration, the distinct paths its applied patches touched with their lines summed; "Read 3 files · 12s" when every step
  read a file); a tap opens message details. **Search** (the menu, or Edit › Find… ⌘F; ⌘G and ⇧⌘G step) puts a glass search bar in the
  composer's place: matches are occurrences of the query in the text as the bubbles draw it (Markdown's marks gone,
  case and diacritics ignored, `ChatSearchMarker`), amber, the shown one strongest and scrolled to; "2 of 2" and the
  arrows step through them, newest first; while a query is typed, earlier history pages in until there is none
  ("Searching earlier messages…", the Mac's rule; it stops when no more can load, as while the conversation is not
  verified), and Done closes it. Each row's text as drawn is parsed once while it stays the same, and the shown match
  reaches only its own row (`chatSearchCurrent`), so stepping redraws two bubbles. **Slash commands**: a draft that is "/" and a
  name lists the matching commands over the composer (`ChatSlashCommand`): the helper's list for the agent plus
  `/terminal`, and `/fork` and `/recap` for Codex (its harness runs them but does not list them); each row names who
  carries it out, Dispatch (`/btw`, `/side`, `/terminal`, `/goal`) or the agent (its name as the Mac shows it: the
  helper's label, "Claude Code" for Claude without one); a tap, or Return (and send) for the lit first row unless the
  draft is that command already (`sendFromComposer`), puts it in the composer, and
  `/terminal` sent switches the tab to Terminal. **Side conversations** (`/btw question`, `/side question`, or the menu
  with an empty composer that asks first) push their own screen (`MobileSideConversation`, `ChatSideScreen`): `chat.side`
  forks the conversation on the host, read-only for `/btw`, and the fork is read and driven as a chat of its own on the
  same terminal under its session (`chat.open`, `chat.send`, its permission requests answered there; a /btw's only
  denied); its replies never enter the main thread. "Main" returns and leaves it open (a capsule over the composer comes
  back to it); its ⋯ menu brings the last answer into the main composer as a quote, turns a /btw into a /side asking the
  first question again (Allow changes, where the agent offers /side), copies, and ends it (`chat.side.close` on the
  fork's session, which ends its process; a fork still starting is closed when the helper answers). A lost link ends
  the side conversation on the phone without a request over the dead link; the helper keeps the fork, so the phone
  remembers the forks it started until it sees them closed and asks the next verified connection to close each
  (`closeOrphanedSides`, one try). Only offered when the helper lists the command; a
  side conversation takes no attachments. **Goal** (Codex, `State.goal`): a strip under the switch, "Goal · working"
  and the objective with Pause or Resume and Stop (`/goal pause`, `/goal resume`, `/goal clear` through
  `chat.command`, as the Mac's goal controls), and over the composer the time on the goal, running subagents and the
  context used (`State.usage`; the protocol has no turn count). Manage goal (a tap on the strip, or the menu) is a
  medium sheet: the objective, editable (`/goal <text>` without a goal; with one, Codex's goal editor, `/goal edit`,
  whose question the phone answers with the new text; one line, newlines become spaces; an edit that fails or ends
  answers no later question), the time (ticking while active) and tokens, Pause or Resume, Stop goal. Codex's `/goal`
  has no turn limit or confirmation rules, so the sheet offers neither. **Jump to latest**: scrolled up while rows
  arrive at the end, the thread keeps its place and a glass pill counts them; a tap scrolls to the end. **Conversation
  mode** (the menu, or a long press on the composer's microphone; `MobileVoiceConversation`) listens continuously to
  this conversation: the host disc becomes a pink waveform disc (a tap ends it) and the composer a listening bar (the
  live words, "Listening · say “send” or pause to send", × to end). Utterances collect into a message sent after a
  1.6 s pause or on "send" ("Dispatch, send", or a sentence ending in it); the Dictation package's chat commands work
  with or without the wake word (steer, new line, scratch that, clear, stop, deny, stop listening, read that, quiet);
  permission is never granted by voice, and "Dispatch, …" that is no chat command is dropped. When the agent's turn
  ends its reply is read aloud (`AVSpeechSynthesizer`, Markdown's marks gone, code and tables named), as are a
  permission request or question it stops for, with "Reading aloud · 0:08" under the reply. Half-duplex as on the
  Mac: the microphone is muted while it reads and 300 ms after, and it waits for an utterance being spoken before
  reading; a partial the recognizer never finalizes (it heard noise and settled on nothing) counts as silence after
  2.5 s, so it holds back neither the send nor the reading. A tap on the bar stops the reading. The audio session plays and records (`Dictation.start`'s `playback`,
  `.playAndRecord`, to the speaker unless headphones are in), so replies are heard whatever the silent switch says.
  Leaving the conversation (another segment or tab), opening its side conversation (which has no listening bar), the
  app going to the background or 5 minutes without speech end it; words not sent go to the draft.
- **Host stats.** `HostStatistics` (Mobile/Stats), one per `HostSession`, which hands it each helper connection's client:
  `stats.sample` and `stats.processes` every 5 s while the app is in the foreground and the host connected through its
  helper, every 2 s while a stats sheet or popover shows the host (`beginViewing`), every 15 s under Low Power Mode
  (`System.lowPowerMode`, followed through `NSProcessInfoPowerStateDidChange`), `stats.disks` every 15 s (the first
  volume, the home folder's, is Disk). Nothing samples in the background, on a plain SSH connection or for New host's
  verifying connection, and no sample is taken before something shows the stats (the first a cadence after the
  connection); a viewer samples at once, and follows the host's session when an edit replaces it. Each request is
  bounded (3 s, the disks 6 s) and a cancelled loop sends nothing more. The numbers are current (`live`) only once the
  connection's own first sample is in; a first sample without CPU (no interval behind it) keeps the last one, stale,
  until the next. The last sample and the history stay when the link drops (stale, with their time; an edit that
  replaces the session keeps them); the history is 15 minutes of CPU and memory percent in memory, drawn as 60 bars of
  15 s on a wall-clock grid (the Mac's `historyBars`: a bar is its samples' peak, a bar between samples at most 20 s
  apart takes the later one, else it is a gap and the line breaks) at the later of the 15 s timeline and the newest
  sample's time. Peak and average are over the window's samples. Latency is `HostSession`'s.
  Other surfaces read `summary(at:)` (values, warning flags, the bars): the watch's snapshot through
  `WatchHostStatsFeed`, at most one change of numbers per 15 s (docs/watch.md, Seams). Red: CPU from 90 %, memory over 90 %, a disk over
  80 % used (the Mac's). **The sheet** (`hostStatsSheet(host:)`, which other areas call: Spaces' host discs and the switcher's host row; here from host detail's disc
  and Settings' host page): detents `[.height(372), .large]`, the screen behind usable at the small one; its title the
  host's disc, name and "OS · latency" line, xmark to close. Small: the stat strip (CPU % with load, memory used of
  total, disk free with % used; CPU and Memory choose the sparkline and the processes' order) and Disconnect; offline
  the connection facts (Address, Port, User, Key, Multiplexer) and Connect. Large: the strip over the 15-minute
  sparkline ("CPU · 15 min", "peak 82% · avg 31%"; a drag across it reads a bar's value and time in the caption), Top
  processes (three, by CPU or memory, bars proportional to the first), Connection (Address `user@host`, Latency,
  Multiplexer, Helper › the Helper and Chat switches and the multiplexer, Color ›), and Edit (New host's form) and
  Disconnect; offline an "Offline · last sample 2:02 PM" line (or why the transport failed) over the dimmed strip, the
  pencil in the bar, Forget host (asks, then removes as Remove host does) and Connect. Low Power Mode adds "Low Power
  Mode · sampling every 15 s"; a host without its helper shows "Stats need the helper" with **Install helper…** (turns
  the switch on, which reconnects) or after a fallback its reason and **Try again**. The small detent's action sits right under
  the strip or the facts; the large one's in a bottom bar (`safeAreaBar`), the rest scrolling above it. **Host detail** shows the strip and sparkline between its
  header and Connection (not for a plain SSH host), the Connection rows as fact rows with monospaced values; its disc
  opens the sheet. **The iPad popover's content** (`HostStatsPopoverContent`, 360 points, for the iPad's host glyph):
  the sheet's large content without its bar, a pencil in its header, Address, Multiplexer and Helper only, Edit and
  Disconnect (Connect offline) at its foot (a `safeAreaBar`, the rest scrolling above, so the popover's height never
  cuts them).
- **Attachments.** Offered only while the conversation's helper accepted `chat.attachments` (hello `features`) and
  the conversation is verified, and not for a command draft. The composer's "+" picks photos and screenshots
  (`PhotosPicker`, several, no library permission) or files (`fileImporter`, read under their security scope); an
  image pasted into the field (a pasteboard with images and no text; text pastes as ever) and, on an iPad, photos or
  files dropped on the composer attach too, as does Edit › Attach Files… (⇧⌘A, the file picker). The phone reads each
  file once, `ChatAttachmentImage.prepare` re-encodes or scales images off the main actor (and drops a photo's GPS,
  Exif, IPTC and camera metadata, its orientation kept: a JPEG is copied without re-encoding, a PNG re-encoded
  losslessly), `attachments.put` stores the copy on the host, and the draft the upload was started for keeps it
  (`ChatDraft.attachments`, with a small thumbnail), also when the user switched drafts meanwhile; if that draft is
  gone, the chip moves to the current one with Retry. A strip above the field shows the current draft's (thumbnail or
  document, a spinner while it uploads, Retry after a failure, ✕ to remove; uploads are session state, dropped by a
  quit); more than ten, an unreadable file or one too large even scaled says so there and
  uploads nothing. A draft with attachments sends without text (not while an upload runs); `chat.send` and `queue.add`
  carry the host paths (`attachments`). The optimistic bubble shows the thumbnails and becomes the transcript's row in
  place (`AgentInput.records` counts the record's image and file blocks; `ChatAttachment.merge` keeps the thumbnails).
  User messages show images in a grid (one large, else up to four a row) and file chips above the text; a tap opens
  them full screen (an image at the size the host keeps). An image without a thumbnail (another device's, a reload)
  is fetched with `attachments.read`, two at a time, into a memory cache keyed by host and path
  (`MobileAttachmentThumbnails`, never written); one the host no longer keeps (`not_found`, `invalid_request`) stays a
  placeholder, a read that failed otherwise is tried again after a doubling wait (5 s to 5 min), and an image dropped
  from the cache is read again when shown. Full screen, an image the host's copy of which cannot be read shows its
  thumbnail, else why. Queued messages keep their attachments (`chat-queue.json` without thumbnails) and are not edited
  in place, but "send now" steers them; after a reconnect a queued message counts as delivered (or as a helper row)
  only with as many attachments (the same host copies where the record names them). The watch shows "📎 2 images"
  before such a message's text.
- **Terminal.** Output is coalesced (up to 256 KiB per parse) because tmux sends one notification per line. An
  attach's tmux history replay is one notification; the presence holds a whole helper reply (64 MiB) unparsed, since
  overflow ends the attachment. Only a lost stream of the current attachment detaches the feed, never one that ended
  because the presence stopped. A reattach's first output repaints over the old screen so it never shows empty.
  The grid follows the view every frame, but a run of changes (a live resize, a pinch) reaches the server once, at its
  last size, 100 ms after the last change (`TerminalPresence.resizeQuiet`): every `terminals.resize` makes tmux and the
  program redraw, and the redraws of sizes the view had already left arrived after it and repainted at the wrong grid.
  Calls go out one at a time; scroll steps made meanwhile join into one (a swipe is a step per line, a round trip
  each). A presence Chat opened learns its scrollback owner when the Terminal segment opens it. The terminal keeps
  its colour scheme (Settings', `dispatch-black` by default) in light mode and under any theme. Input, sizes and screens wait for `terminal.attached`, as the Mac's do. tmux keeps one size per
  window: while another client holds it at another size (or the window is split), the screen is laid out at the
  server's grid from the top left, as the Mac's, and the view keeps asking for its own. A program's copy (OSC 52,
  kitty clipboard) is denied behind the helper: the phone has no consent surface for it, unlike the Mac's "Programs
  can copy". A plain SSH shell (`PlainShellFeed`, a PTY the user opened with nothing between) may write it
  (`TerminalFeed.clipboardWrite` sets `clipboard-write = allow` on that presence's surface; the copy goes to
  `UIPasteboard.general`); reads stay denied for every feed. A plain shell's feed opens its PTY at the presence's
  attach size, reports `.attached` as soon as the channel is open (before any output), scrolls locally from the start
  (`TerminalFeed.scrollback`), and its detach closes the shell, so a later attach is refused.
  Hardware PageUp and PageDown page herdr's history; Shift pages the terminal's own. Automatic reconnects ask nothing:
  a host that needs a keyboard-interactive answer fails them and Connect asks again.
- **Terminal search and menu (T1, T2).** The key capsule's last key keeps its role and carries the terminal's menu
  (`TerminalMenuKey`, a clear `UIButton` with the system menu over the SwiftUI glyph, so the key knows when the menu
  shows): with the software keyboard down it is the keyboard key (a tap brings the keyboard, a long press opens the
  menu, its accessibility hint says so); while the software keyboard is up it is `ellipsis.circle` in pink and a tap
  opens the menu, which then ends with Hide keyboard; on an iPad with a hardware keyboard it is the folding chevron, with
  the menu on a long press. While the menu shows the key is the pink ellipsis (the system menu grows out of the key and covers it). The menu
  follows the app's appearance, though the capsule stays dark over the terminal. The menu: Search, Paste, Select all;
  Clear screen ("⌘K on a keyboard") and Reset terminal. Paste is disabled without text on the pasteboard (asked with
  `hasStrings`, which reads nothing) and, being the app's own control, may bring the system's paste prompt; Select all
  selects screen and history with handles and offers Copy; Clear screen is the Mac's `clear_screen`. Reset terminal on
  a helper terminal reattaches the presence's feed (`TerminalPresence.resetTerminal` through `reattach`): the server's
  history position starts over, and the new attachment's first output resets the emulator (RIS, history erased) and
  repaints it from the server, for Chat too. While Chat sends through the terminal (a send, a queue start or an answer
  the helper verifies against the screen it publishes; `ChatTerminalPresence.sending`, `TerminalPresence.chatSends`)
  the item is disabled with "Not while the agent is sending": the reattach would drop that publication mid-send. A plain shell's detach would end it (`TerminalFeed.endsOnDetach`), so it, like a presence not attached, resets
  only the emulator (Ghostty's `reset`): the program's next output draws on the fresh terminal. Search swaps the key
  capsule for the search capsule (`TerminalSearchBar`, in the capsule's slot at its height so the grid keeps its rows):
  a glass field with the needle in the monospaced font, "2 of 3" and a clear button, the up and down pair, and Done.
  Opening it releases the capsule's Ctrl and Alt latches and the d-pad cluster. It is Ghostty's search on the local
  terminal (`TerminalSearch` over the surface's `search:`, `navigate_search:` and
  `end_search` binding actions), so helper terminals and plain shells search the same way, through the emulator's
  screen and scrollback (herdr's server history beyond the screen is not searched). Matches count newest first, as on
  the Mac: a new needle selects the newest ("1 of 3"), up is the older match and down the newer, both round the ends;
  the case of letters does not matter. A needle runs once typing pauses for 60 ms (a long history takes 8–12 ms on the
  main actor, which every keystroke paid), or at once when a step or Return comes first. Frames whose viewport changed
  refresh an open search at most every 24 ms, as Ghostty's search thread does (`SearchRefreshThrottle`; a refresh is
  about half a millisecond under the session's lock, frames come at up to 120 Hz); a change held back gets a frame
  when the interval ends, so the last output is searched. Each frame lays the matches on the rows: every match amber (`StateWorking`, #D9B36A), the selected one a brighter amber
  (#FFD066), both with black text; a selected match off screen is scrolled to. In the field Return is the older match,
  ⇧Return the newer, Esc is Done; the keyboard stays. Done ends the search (the highlights go) and keeps the needle,
  which the next opening searches again; the terminal gets the focus back if it had it. With a hardware keyboard Find…
  (⌘F) opens the search and Find Next and Find Previous (⌘G, ⇧⌘G) step it, from the terminal or the field (both answer
  the standard `find(_:)`, `findNext(_:)`, `findPrevious(_:)`); a closed search opens on its newest match for them, and
  the next one steps. These are the app's commands (`MobileCommand`), so the chords work on the phone too.
- **Terminal on iPad.** Rules in `TerminalAdaptation`, tests in `TerminalIPadTests` and `TerminalKeyboardUITests`.
  - *Software keyboard.* Where the keyboard is comes from `keyboardLayoutGuide` with `followsUndockedKeyboard` (a
    tracker view in the host view), not from keyboard notifications: a keyboard that comes up floating posts none, and
    floating a docked one posts a hide while it stays on screen. Docked, the capsule rides on it; floating or split, the
    capsule stays at the bottom (SwiftUI would keep a keyboard inset for a floating keyboard, so the segment ignores the
    keyboard safe area then). The shortcut bar is emptied (`inputAssistantItem`): its Undo, Redo and Paste cost the
    terminal a row and Paste is in the edit menu and ⌘V. It is emptied as the terminal takes the keys, never while
    the view is built: a scene's first `inputAssistantItem` makes UIKit's text effects window, which asks the hosting
    controller for its status bar and so re-entered SwiftUI's graph inside the layout pass building the terminal (an
    attribute cycle at full CPU on an iPad whose first frame held a terminal). On an iPad the capsule is at most six phone-width keys wide
    (404 points), centred. The grid takes its new size in the keyboard animation's first frame, as on the phone.
  - *Hardware keyboard.* With `HardwareKeyboard.shared.attached` the capsule collapses to one glass key over the
    terminal's bottom right ("Show terminal keys"); it brings the six keys back (remembered, `terminal.keysShown`),
    whose last key then folds them again; the capsule returns whole when the keyboard goes. The phone keeps its capsule
    whatever is attached (the simulator forwards the Mac's keyboard to every iPhone run). With a hardware keyboard the
    terminal becomes first responder when its segment shows. A long press on that last key opens the terminal's menu
    (Terminal search and menu). Keys are `UIKeyCommand`s without titles (none show in the
    ⌘-hold overlay, none use ⌘); `canPerformAction` must allow `keyCommand(_:)` or UIKit fires none of them (it did
    not before the iPad work: hardware keys other than text never reached the program). Ctrl-Space is iPadOS's input
    switcher, so no command fires for it: `pressesBegan` takes it. Encodings are Ghostty's, as the Mac's: Shift-Return
    is `ESC [27;2;13~` (CSI u under the kitty protocol), Ctrl-[ is `ESC [91;5u`, not ESC; a keyboard without Esc has the
    capsule's Esc, or Caps Lock mapped to Escape (Settings > General > Keyboard > Hardware Keyboard > Modifier
    Keys). ⌘C, ⌘V and ⌘A are the standard responder actions (Select All is the Mac's `select_all`); the view also
    answers `clearScreen(_:)`, `increaseSize(_:)`, `decreaseSize(_:)` and `resetFontSize(_:)` for the app's menu (⌘K,
    ⌘+, ⌘-, ⌘0) and `find(_:)`, `findNext(_:)`, `findPrevious(_:)` (⌘F, ⌘G, ⇧⌘G); the key bar's menu reaches Clear
    Screen without a keyboard.
  - *Pointer.* As the Mac's: a click, double or triple click or drag selects through the surface's mouse handling (no
    handles), or reaches a program that reads the mouse; a secondary click selects the word under it and opens Copy,
    Paste, Select All at the pointer; hover moves the surface's mouse under an I-beam a cell tall; a trackpad's
    two-finger scroll is a finger's, with momentum; a wheel's notches scroll without momentum.
  - *Sizes.* The default font is 13 points on an iPad (the Mac's 12.5 at a laptop's distance on smaller points), 12 on
    the phone; a pinch or Settings replaces it and is kept per device. A 13-inch iPad at 7 points holds well over 250
    columns.
  - *Testing.* XCUITest's key synthesizer on the iOS 27.0 simulator delivers no event for Esc, Return, Backspace, Home,
    End, Page Up and Down or forward delete, and shifts F-keys down by one (F2 arrives as F1): those are checked through
    the commands themselves. `-DispatchTerminalEcho keys` makes the sample's terminal echo every input in caret
    notation. `-DispatchHardwareKeyboard YES` keeps the terminal's software keyboard away, as Chat's composer does
    and a real keyboard would (the capsule's keyboard key still brings it). A synthesized ⌘ hold shows no overlay in the simulator. Pointer events cannot be synthesized at all.
- **Code.** The diff viewer reads current files with `files.text`. There is no Revert: the helper has no operation to
  reverse a patch. On an iPad its lines take the column's width and its file headers light under a pointer; the
  code composer's keys are Chat's above (⌘Return sends from either mode).
- **Resilience.** `host-cache.json` (last hello, multiplexers, topology, Agents rows with ≤280-character previews and titles,
  a plain SSH host's shell tabs without screens) is
  read synchronously at launch so the first frame lists every host. Live data reconciles in place (same row objects).
  Cached files decode leniently, per entry.
- **Pull to refresh and last update.** Spaces (not in edit mode) and Agents pull to refresh:
  `HostSessions.refresh` calls `retryNow()` on every host and ends once each answered, failed, retried and is still
  down, or waits on a sheet (10 s at most). A connected link's `echo` probe counts as an answer (the driver reports it
  as a latency sample); a plain SSH host counts as answered while connected (its link is checked with `:`, which sets
  no last update). Each host's last update (`HostSession.updated`: its last ready, snapshot or ping) is read by
  VoiceOver on its header and shown for an offline host ("as of 2h ago"); Agents, whose rows mix hosts, sums it up in
  the navigation subtitle under the large title ("Updated just now · vps offline", two hosts by name, then
  "+N more"; none in the Duo's sidebar). The cache keeps it (`heard`, written as the link changes, not per ping; an older cache's `saved` stands
  in, except in an entry without a hello, such as a plain host's shell tabs alone, which reports none), and a
  background refresh that reaches the host sets it.
- **Background refresh.** A `BGAppRefreshTask` (`<bundle id>.refresh`), off by default. It connects hosts with Chat
  and the helper on (`BackgroundRefresh.refreshes`; a connection that falls back to plain SSH reads nothing) through a
  session that asks nothing, so Face ID key hosts are skipped (`interactionNotAllowed`), and so is a host the user
  disconnected (`HostSessions.isParked`, until Connect or the next launch); it reads `chat.list`, notifies as Settings ›
  Notifications allows (`AgentAlerts`, against the cache's last-known rows), sets the badge, and ends within 25 s. It
  never touches seen markers.
- **Settings.** A sheet (G1) from Spaces' edit mode or ⌘,, on the canvas with the theme's cards. Everything is
  `MobileSettings` in UserDefaults; the root reads the appearance, theme and chat keys itself (`mobileAppearance()`).
  - *Hosts.* Each host's Chat, Files & git and multiplexer, and "Show offline hosts" (Spaces' OFFLINE group,
    `MobileTabs.showOffline`, the switch the group's own held menu has).
  - *Terminal.* Font (G2): `TerminalFont.all`, JetBrains Mono (TermApple's embedded face, no `font-family`), Source
    Code Pro, Fira Code, 0xProto and Departure Mono (the Mac's files, copied into the app's `TermFonts` and registered
    for the process once by `MobileFonts`, started off the main thread at launch and waited for by the first terminal,
    chat or Settings screen that draws in one; not Ioskeley Mono, 6 MB) and the system's Menlo; "ligatures" marks the fonts
    with contextual alternates, which the shaper draws. Bold text as bright colors is `DrawConfig.bold = .bright`
    (Term's config has no `bold-color`); Cursor and Blinking cursor write `cursor-style` and, off,
    `cursor-style-blink = false`, applied with `changeCursorDefaults` as the Mac's session does. Color scheme lists
    Dispatch Black and Dispatch, then Ghostty's bundled themes (the app's `themes` folder) by dark and light with a
    swatch, searchable; a stored name that is not a bundled file falls back to `dispatch-black`. Improve text
    contrast is the contrast shader at 4.5:1. Each change posts `TerminalStyle.changed` and every open presence
    restyles at once (`TerminalPresence.restyle`, then its view's background and selection handles), keeping its own
    size; the size slider only sets new terminals'.
  - *Chat.* Font (G3): San Francisco, Same as code (the terminal's font) or Comic Sans, which iOS lacks, so Chalkboard
    SE draws it; Text size is subheadline, callout or body, so it still follows Dynamic Type. `ChatTypography` in the
    environment sets the bubbles' text, level-3 headings, and the terminal's font for code blocks (3 points under the
    chat text) and inline code (94 % of it), both following the chosen size.
  - *Theme* (G4). Automatic follows Appearance; Graphite, Lavender and Nautical are the Mac's `SidebarPalette`s and,
    as on the Mac, bring their scheme (Graphite and Lavender light, Nautical dark), so Appearance is disabled under
    them. A theme replaces the tint, the bubbles, the text on the accent, the canvas and the cards: those
    `MobileColors` resolve through `UIColor.themed` by the window's `MobileThemeTrait`, bridged to SwiftUI's
    environment, so UIKit and SwiftUI views and presentations recolour live; the window's `tintColor` and the
    terminal's selection handles are the themed accent too. Each palette is made once. The terminal keeps its scheme.
  - *Notifications* (G5, `AgentAlerts`). Events between two looks at a conversation: newly needs you (an approval or
    question notifies whatever Needs you says; the agent's own attention needs it on), Finished (was busy, now idle
    and not waiting), Failed or disconnected (was busy, and its agent left the terminal or the terminal closed, in a
    live topology; a row the helper left out, a detached tab, a host going offline or Chat turned off is none). The
    cache drops a row once its terminal has no agent (the refresh's and the open app's), so a stop notifies once.
    Sound is the default, the ship's bell (`ShipsBellSound`, shared with the Mac, written off the main thread to
    `Library/Sounds` under a fingerprint of its samples, older ones removed) or none; Show message text off leaves
    "Needs you", "Finished" or "Stopped while working", and each event has its category and lock-screen placeholder
    (`agent`, `agent.finished`, `agent.stopped`; the watch's long look registers `agent`). Badge app icon sets the
    badge to `AgentAlerts.waiting`, the rows needing the user among live ones: the open app's rows that are not
    stale, the refresh's rows of the hosts it reached; 0 when off, and set only when it changes. While the app is
    open, `ChatConversations.arrived` compares live rows only (cached or reconnecting rows are no arrival) and posts
    the same banners, except for a muted conversation, the thread on screen (`AgentAlerts.onScreen`), a terminal the
    user closed, detached or terminated from the phone in the last minute (`MobileTabs.userClosed`), or a stop the
    agent recovers from within 10 s (`stopGrace`: a restart's rebinding). Permission is asked once a run: Background
    refresh on, a Notifications switch on, the Notifications screen opened, or the first banner while open; refused,
    the screen says so and links to the Settings app. The watch shows the phone's notifications as iOS mirrors them: there is no switch and
    no Allow or Deny in the banner (an approval belongs to a live subscription), so G5's Apple Watch row is a
    status, and Notifications names Background refresh when it is off.
  - *Screenshots.* `-DispatchSettingsShow G1|G2|G3|G4|G5|scheme` (Debug) opens Settings at that screen.
- **Appearance.** Dark by default (`appearance` in UserDefaults), every colour with a light variant. Deliberate
  departures from the mockups: the light user bubble is `#BF3BBF` (the mockup's `#C94FC9` fails 4.5:1), and system
  menus and segmented controls replace custom ones.
  `NewTabGuard` refuses the New tab in UIKit's tab bar delegate, because refusing in SwiftUI's binding is too late (the
  empty tab shows for frames).

**Simulator demo.** `./run.sh --ios --demo` (Debug; `-DispatchDemo YES` or `DISPATCH_MOBILE_DEMO=1`) replaces the
saved hosts with three demo hosts (`Mobile/Demo`): mba2 and studio (macOS, herdr and tmux) and ai (Ubuntu), connected
through the scripted driver to an in-process helper (`DemoHelper`) on the real wire codec, so Spaces, Agents, threads,
approvals and terminals run the app's own code. Their helpers answer `stats.*` with fictional numbers, over 15 minutes of seeded history (`HostStatsDemo`). Agents are in every state: working (web), waiting for approval (api,
Codex), asking a question (docs), finished unseen (billing) and idle (train). The threads are the real helper's
`chat.page` records of authored Claude and Codex transcripts; shells replay recorded screens, three tabs keep logging
(`live/`), and typing echoes with a prompt on Return. `python3 test/mobile-demo-fixtures.py` regenerates
`Mobile/Demo/Fixtures` (read from the source tree, never bundled); everything in them is fictional.

**Vertical bar.** iOS 27.1's vertical bar (the Duo's status, tab and bar items in a strip down one side) is off on
screens wide enough for the split and the system's choice elsewhere (`MobileVerticalBar`): unfolded as a book it kept
the tab's column off the trailing edge; on the folded cover screen it keeps the status out of the bar's row, where it
shared the camera's corner and the tab's header folded into the bar's "…" menu. SwiftUI has no modifier and its root
hosting controller answers for itself, so the root's class and `UIViewController` answer by the window's size, and
fold and unfold ask again. With the bar off the unfolded Duo keeps its status in the bar's row (its status bar is a
2-point strip): headers at the screen's trailing edge leave it about 100 points (`TabsScreenHeader.statusCorner`). The
split measures the window's bounds from UIKit (`MobileWindowReader`), which change with neither the status bar nor the
keyboard. Beside the Duo's sidebar a tab's header is one row: the capsule (glyphs, 40 points a segment) takes the host pill's
place, and the sidebar names its section in the bar's row (Edit a glyph in the narrow sidebar). An iPad's split keeps
the switch under the header and the sidebar's large title.

**Debug hooks** (compiled out of Release): `DISPATCH_MOBILE_STORE=memory` (nothing saved, no Face ID),
`DISPATCH_MOBILE_SCRIPTED=1|empty|trust|mismatch|nomux`, `DISPATCH_MOBILE_CHAT_DEMO=<screen>` (via `SIMCTL_CHILD_`; the
chat redesign's C1, C2, C3, C4, C4b, C5 listening, C5r reading aloud, C6 and S6 too, conversation mode with a scripted
voice and no audio),
`DISPATCH_MOBILE_CHAT_DEMO_WIDTH=<points>` (M3a in a sidebar column that wide),
`DISPATCH_MOBILE_CHAT_DEMO_LINK=cycle`, `DISPATCH_MOBILE_AUTHORIZE_KEYS`, `DISPATCH_MOBILE_HOST_ENV`, and launch
arguments `-DispatchTabsSample`, `-DispatchTabsShow space:|space-edit:|switcher:|tab:<key>|detached:<host>|new-space|
pick|edit`, `-DispatchTabsFilter needsYou|agents`, `-DispatchTabsCollapse <host>`, `-DispatchTabsOfflineFolded YES`,
`-DispatchSpacesMockup P1|W0` (the sample as the Spaces mockups draw it: five tabs in app, two detached, ai offline,
and for W0 build too), `-DispatchTabsEmptyHost` (a fourth, connected host without spaces), `-DispatchTabsSegment
terminal|chat|files` and `-DispatchTabsFilesMode files|review|commits` (the tab `-DispatchTabsShow` opens),
`-DispatchTabsFiles plain|denied|offline` (the sample's mba2 as Files' S1, S2, S3), `-DispatchFilesFolder src` and
`-DispatchFilesPreview src/theme.ts` (the Files listing in that folder below the tab's, that file pushed; the sample's
files are `FilesSample`'s fictional web app), `-DispatchTabsFilesRoute
commits:<hash>[:<path>]` (a commit, or its file, pushed over that tab; the sample's Commits mode reads `CommitsFixture`,
the mockup's repository), `-DispatchReviewDiff <file>[:select|compose|outdated]` (Review's diff of that sample change, pushed from the list: R2, R3, R4, S5), `-DispatchReviewSheet agent|swipe|noagent` (Create review over the shown tab: R5, R5b, R5c), `-DispatchReviewSent YES` (S4; the sample's Review is `ReviewSample`, the mockup's repository with its three comments on mba2's app repository), `-DispatchTabsScript` (one
step every 1.5 s, for recordings), `-DispatchTerminalEcho keys` (the sample's terminal echoes input in caret notation),
`-DispatchHardwareKeyboard YES|NO` (pins `HardwareKeyboard`), and with the demo `-DispatchHostStats
<host>[:small|drag|large][:cpu|memory|scrub]` (that host's stats sheet), `-DispatchHostStatsState offline|plain`
(disconnected first, or its Helper switch off), `-DispatchHostDetail <host>`, `-DispatchHostStatsPopover <host>` (the
popover's content from the top right) and `-DispatchLowPower YES` (pins `System.lowPowerMode`). With
`DISPATCH_MOBILE_SCRIPTED` or the demo, the watch's snapshot carries `WatchSampleStats`' numbers for every host
without statistics of its own (the scripted helpers send none; the demo's hosts sample theirs; docs/watch.md, Seams). To force a background refresh, pause in lldb and run:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"yachts.dispatch.mobile.refresh"]
```

### Plain SSH

A host can go without the helper: the phone opens interactive login shells on its own SSH connection, each with a
PTY, and runs nothing else there. Terminal only: no Chat, no Agents (nor the diff viewer they open), no spaces from a
server, no latency, background refresh or watch snapshot. `HostSession.mode` says how the current connection reaches
the host, `.helper` or `.plain(reason:)` (nil while not connected). A plain connection saves the host's last
connection time (`lastConnected`), as a helper's does, but no OS (no helper reports it).

- **The Helper switch.** Per host (`HostRecord.helper`, on by default; records saved before it read on), in New host's
  "On the host" section (with the Multiplexer picker, Chat and Files & git) and in host detail's Connection. Off, New
  host hides Multiplexer, Chat and Files & git and its footer says the phone only opens shells and installs nothing
  (`NewHostSheet.plainStatement`); host detail hides the multiplexer picker, Chat and Files & git. Off turns Chat and
  Files & git off with it (the record keeps `chat` and `files` off without the helper); on, from host detail, turns
  them on again. Settings lists such a host as "Plain SSH", its Chat and Files & git switches disabled with footers
  pointing to host detail, and no Multiplexer section. Turning
  the switch on, or off on a helper connection, reconnects the host; turning it off on a connection that is already
  plain (**Use plain SSH for this host**) keeps the connection and its shells and only clears the notice. With the
  switch off the driver stops after the login (`.plain(reason: nil)`): no probe, no upload, nothing in `~/.dispatch`.
- **Fallback.** With the switch on, a helper step that fails while the SSH connection stays up leaves the connection
  as plain SSH with the failure's text (`SSHHostSessionDriver.fallback`, `.plain(reason:)`): the platform probe failing,
  `uname` unidentified or unsupported, the bundled binary missing, empty or too large ("SSH helper is missing or
  invalid."), an upload or cache failure (a transient one is tried once more first), a refused exec channel, a failed or closed exec or too much probe output, a helper
  that exited before greeting (`HelperExited`: `HelperBootstrap.launchFailure`'s text from its exit status and the
  first lines of its stderr, after the one runtime-folder retry a 126 at home gets, [Install root](#helper-contract)),
  and a helper that is there but unusable (`HelperUnavailable`: `hello` failed and it still runs 2 s later, another
  protocol version, no transport limits). The helper's channel is closed, the connection kept. Not fallbacks: login,
  host key and missing-key refusals stay final, and a connection that dropped meanwhile is a loss that reconnects
  (`ConnectionLost`). A failure a dropped connection also gives (a helper channel that ended with no exit status, a
  `channelClosed` during the bootstrap: `SSHHostSessionDriver.ambiguous`) is first checked with the `:` probe
  (below): no answer makes it a loss that reconnects, without the notice. After a fallback host detail says "Plain
  SSH · helper could not be installed: <reason>" (`HostSummary.plainLine`; just "Plain SSH" with the switch off) and
  offers **Use plain SSH for this host**, which turns the switch off. Each connection decides again: a host fixed later gets its helper back at its next connection,
  and the line goes.
- **The Shell space.** A plain host shows one synthetic space, "Shell" (`MobileSpace.Kind.plainShell`), instead of a
  server's spaces: a plain connection drops the kept snapshot, in memory and in the launch cache. Its tabs are the
  phone's own shells (`ShellSessions`, held by the `HostSession`), each a PTY channel on the host's connection, keyed
  `shell:<uuid>` (tab, pane and presence). A tab is "Shell n" (numbered per host), or the program's title (OSC 0/2)
  while it sets one; its time is its last output (dated at most every 5 s), else its creation. It has no chat, dot,
  Terminal / Chat switch or Rename, and line two says how an ended one ended ("Exited", "Exited with status 3",
  "Session ended"). **New tab** (the space's button, ⌘T, New tab's picker, an ended card's New shell) opens a shell at
  once in Terminal, only while the host is plain-connected. **Close tab** (the row's menu holds only it; ⌘W) ends a
  live shell without asking; **Close space** (the space's menu, the switcher, ⇧⌘W) closes every shell tab, asking first ("Close all
  shells?") while one is live. Both work without a connection. New space is not for this host: New space names it
  "plain SSH" and cannot create, and the tree's New space row never shows (the Shell space is always listed). While
  disconnected, a host whose switch is off keeps its Shell space, every card ended, without New tab, and shows no
  multiplexer spaces or mark from the cache (`HostSession.restore` drops the cache's topology and followed multiplexer
  for it); a host that only fell back lists it only while ended cards are left, until a connection decides again. The
  host's header in Spaces shows a "Plain SSH" chip where the tmux or herdr mark goes (`PlainSSHMark`) while the switch
  is off or the connection is plain (`HostSession.plainSSH`); host detail's Spaces header shows it while plain-connected,
  and host detail lists the Shell space with its number of shells.
- **Lifetime.** A shell ends with its channel (its program exits) or with the connection: a drop, a reconnect, going
  to the background (every host disconnects), an edit that reconnects (the Helper switch, except turned off on a plain
  connection; the address, user or authentication: a replacement session takes the cards). Its tab stays as a card:
  the last screen with "Session ended", the exit status if there was one (or why the open failed), and **New shell** and **Close** where the key
  capsule was (`TerminalEndedCard`). The feed closes an ended shell's channel as soon as it has read the exit, not
  when the tab closes. Nothing restarts a shell: the connection reconnects with its usual backoff, so New
  tab works again, and `PlainShellFeed` refuses a second attachment. `ShellSessions` keeps each tab's presence attached
  for the tab's life, so leaving its screen never ends the shell; closing the tab closes the presence, whose detach
  closes the channel. The launch cache keeps the tabs (`HostCacheEntry.shells`: id, number, title, creation; never a
  screen), which a relaunch lists as ended cards without a screen.
- **Terminal.** The Terminal segment of a helper tab: key capsule and d-pad, the key bar's menu and search (Reset
  terminal resets only the emulator), hardware keyboard, the iPad's rules and the 100 ms resize quiet period. The PTY opens at the presence's grid when it attaches (80 × 24 before a view laid it
  out); later sizes are `window-change`. Scrollback is the emulator's own from the start (no server history to page).
  OSC 52 and kitty clipboard writes go to `UIPasteboard.general` (`TerminalFeed.clipboardWrite`, true only here, sets
  `clipboard-write = allow`); reads are denied, as for every feed. TERM is `xterm-256color`, fixed
  (`PlainShellFeed.term`), with no `env` requests and no terminal modes (the server's defaults). Input and sizes made
  while the channel opens are sent once it is open, in order; a write that fails is dropped, never retried.
- **Liveness and what is left out.** No helper, so no `echo` ping and no latency: the SSH keepalive (15 s × 3) watches
  the link, and a `retryNow()` on a connected plain link runs `:` on an exec channel (`SSHLogin.alive`; the engine has
  no channel-level ping). Any answer from the server counts as alive, a refused exec or a nonzero status included;
  only silence past 3 s, a closed channel or a network error count as dead, and close the link. `HostSession.plainSSH`
  (the switch off, or a plain connection) keeps the host out of Agents and Chat (`HostTopologies` hands on no
  topology), background refresh, the watch's snapshot and refresh ([watch](watch.md)), and same-machine pairing (a
  plain connection's hello is an earlier helper's). The watch's snapshot also leaves out a Shell space on a host with
  its helper (ended cards left from a plain connection).

## iPad

The same app with the iPad's conventions; every iPhone screen and the iPhone Duo's split stay as they are. One window
(`UIApplicationSupportsMultipleScenes` off: the composition and the host sessions are app-wide), resizable under
iPadOS windowing and Stage Manager; a narrow window (Slide Over, a third) is the iPhone's stack. Two kinds of iPad are
first class: **touch only** (the software keyboard and the terminal's key capsule) and **with a keyboard and
trackpad**, which adds the menu bar, ⌘ shortcuts with the ⌘-hold overlay, and every other key straight into the
terminal. `HardwareKeyboard.shared.attached` (Mobile/Shared) is the one detector; Debug's `-DispatchHardwareKeyboard
YES|NO` pins it for tests and screenshots.

### Keyboard and menu bar

`MobileCommands` (Mobile/App) puts the Mac's menus (`Dispatch/AppDelegate+Menus.swift`) where the phone has the same
thing into iPadOS's menu bar, as SwiftUI `.commands` on the `WindowGroup`; the ⌘-hold overlay lists the same items.
One table (`MobileCommand`) gives titles, chords and menus to the menu bar and to Help › Keyboard Shortcuts (⌘/, a
sheet).

| Menu | Items |
| --- | --- |
| Dispatch | Settings… ⌘, |
| File | New Tab ⌘T, New Space… ⌘N, New Chat… ⌥⌘N, New Host…; Rename Tab…, Rename Space…; Close Tab ⌘W, Close Space… ⇧⌘W, Detach Space |
| Edit | the system's undo and pasteboard items, then Find… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G (the terminal's search on the Terminal segment, the conversation's on an agent's Chat segment), Clear Screen ⌘K, Attach Files… ⇧⌘A; the system's text input items |
| View | Increase, Decrease, Reset Font Size ⌘+ ⌘- ⌘0; Toggle Sidebar ⌃⌘S (and the Mac's hidden `⌘\`), Switch Terminal / Chat ⇧⌘C, Switch Terminal / Files ⇧⌘F, Review Changes ⇧⌘U, Commits ⇧⌘L |
| Navigate | Spaces ⌘1, Agents ⌘2; Next and Previous Attention ⌘J ⇧⌘J; Previous and Next Tab ⌘[ ⌘] |
| Help | Keyboard Shortcuts ⌘/ |

- **What they act on** is the screen on top, in the stack and in the split alike (`SpacesNavigator+Commands`): the
  stack's top screen; in the split the detail column's tab (not while a screen is pushed over it) and that
  tab's space, else the sidebar's space. Items that do not apply are disabled: a tab's and a space's without one on
  screen or with their host not connected, Previous and Next Tab in a space of one tab, Attention with nothing waiting,
  and everything while a sheet or dialog is up (the shell publishes what is
  presented with a focused scene value; a chord is checked again when it runs).
- **As on the Mac**: New Tab opens in the space on screen (elsewhere as the tab bar's New: the most recent space, else
  the picker); Previous and Next Tab go round the shown tab's space in its place (the stack's top tab is replaced, the
  split's detail column shows the neighbour); Next Attention visits the tabs that need the user, then unseen results,
  from the shown one, round the end, on the Chat segment when an agent runs there. Find, Clear Screen and the font sizes
  go down the responder chain to the focused terminal (`find(_:)`, `findNext(_:)`, `findPrevious(_:)`, which its
  search capsule's field answers too; `clearScreen(_:)`, `increaseSize(_:)`, `decreaseSize(_:)`, `resetFontSize(_:)`,
  which the terminal answers and refuses past its bounds), so a size is a pinch's: a point a step,
  saved where a pinch and Settings save it; with a hardware keyboard the shown terminal has the focus. Close Space asks Detach or Terminate…, as the switcher's Close space does. ⌘1 and ⌘2 select the tab bar's sections, as
  iPad apps number their sidebar's, and go back to the tab bar (the split's detail column keeps its tab); the iPad's
  split has no tab bar, so there they set the sidebar's filter, All or Agents, and bring the sidebar back. The View
  menu's modes are the Mac's (Switch Terminal / Files toggles Files with Terminal, Review Changes and Commits show
  theirs) and apply where the strip offers the mode (`PadMode.available`); a deliberate change for the phone and the
  Duo as well, whose capsule they drive with a hardware keyboard (a shell tab on its Files segment counts as Files, so
  Find applies on the Terminal and Chat segments only, as before). Close Tab ⌘W closes the strip's selected pill, also
  while a mode's screen is pushed over it (as its × does); Previous and Next Tab ⌘[ ⌘] move along the strip (its space's
  tabs). On the iPad split ⌘1 and ⌘2 leave the tab bar on Spaces, so a window that stacks again shows Spaces. New Chat
  takes ⌥⌘N, which the Mac leaves free (its ⇧⌘N is New Local Space). Toggle Sidebar (⌃⌘S) applies where the tab header's
  sidebar button does: an iPad's split beside a tab (the Duo's split keeps its sidebar); `⌘\`, the Mac's hidden alias, is a
  view's shortcut without a title (SwiftUI's commands have no hidden item), so it is in no menu and not in the ⌘-hold
  overlay. With the sidebar hidden ⌘1 and ⌘2 bring it back, and ⌘[ ⌘], ⌘J and ⌘T act on the tab that has the window,
  which keeps it. Find, Find Next and Find Previous follow the segment: on a tab's Terminal segment the
  terminal's search (the standard `find(_:)`, `findNext(_:)`, `findPrevious(_:)` actions), on an agent's Chat segment the
  conversation's (`ChatSearchBar.request`: Find opens it, Next and Previous step its matches); Reset Terminal is not in the menu bar, as the Mac has none.
- **The system's menus.** SwiftUI's groups are the sections: a `Divider` inside a group does not separate on iPadOS,
  and a `before:`/`after:` group next to a replaced one is dropped, so File's sections take the new-item, save and
  import/export slots, and Edit's items go after the pasteboard's. The built Edit menu has no Find submenu of the
  system's, but replacing the text-editing group that stands for it conflicts with `com.apple.menu.find` ("Replacement
  elements conflict") and UIKit drops the whole replacement, Find and Clear Screen included. Replacing the save slot removes the scene's Close (⌘W), which would close the app's one window;
  the toolbar slot loses Customize Toolbar…; Format is empty. Edit, Window and the text input items are the system's.
- **The terminal keeps its keys.** Every app chord has ⌘ and the terminal claims no ⌘ chord, so a focused terminal
  gets Esc, Tab, Control and Option chords, arrows and function keys (its own `UIKeyCommand`s), and ⌘C/⌘V stay the
  responder actions. ⌘= reaches Increase Font Size as well as ⌘+. Tests pin the keyboard with
  `-DispatchHardwareKeyboard YES` (read with `bool(forKey:)`, so the string works).
- **Esc does not go back.** SwiftUI commands and shortcuts never get Esc (UIKit keeps it unless a `UIKeyCommand` asks
  for priority), and in the iPad simulator no Esc press reached the app's own first responder either (a plain view or
  a hidden text field with a priority Esc command, or `pressesBegan`), while arrows and Control chords did. A field's
  or the terminal's own Esc is theirs.
- **Seeing it.** XCUITest cannot open the menu bar (no hover or edge swipe reveals it), so `MobileCommandsTests` reads
  the built main menu (`UIMainMenuSystem`'s root menu, iPad only, skipped if UIKit stops exposing it) and
  `IPadUITests` sends the chords with `typeKey`.

## Testing

- **Suites.** `test/run.sh --platform ios` (`test/ios.py`) runs the fast suite on the simulator, an iPhone by default;
  the iPad run is `DISPATCH_IOS_SIMULATOR="<iPad simulator>" test/run.sh --platform ios` (or `--simulator`). Both run
  the same cases: one that only means something on one family skips on the other (`XCTSkip` on
  `UIDevice.current.userInterfaceIdiom`) and counts as skipped. Cases are classified
  in `test/suites.json` as `DispatchMobileTests/<Class>/<test>` and `DispatchMobileScripts/<Class>/<test>` (Python
  tests of the release tooling, `test/ios-release.test.py`, no build). A fast run fails on an unclassified case.
  `--derived-data PATH` builds elsewhere than `build/ios`, so two runs (another simulator, another session) do not
  wait on one build database. New tests go in `Mobile/Tests/<Area>…Tests.swift`; after adding files, run `python3 scripts/generate-project.py`
  and commit `project.pbxproj`.
- **UI tests.** `xcodebuild -scheme DispatchMobileUITests -destination 'platform=iOS Simulator,name=iPhone Air'
  -derivedDataPath build/ios test`, against the scripted hosts. The scheme can hang after its result line: wrap it in
  `perl -e 'alarm 595; exec @ARGV' --`. `IPadUITests` (iPad only) drive the split upright and on both sides with
  screenshots attached (and written to `TEST_RUNNER_DISPATCH_IPAD_SHOTS`), the menu bar's chords, New in both
  sections and the form sheets, with `-DispatchHardwareKeyboard YES`. Slide Over, Split View and Stage Manager sizes
  are not scriptable (XCUITest cannot resize the window); a narrow window is the iPhone's stack, which the iPhone
  suites cover. The iPhone builds keep their DerivedData in `build/ios`:
  in `build/`, the Mac's, they shared its build database and waited for each other ("database is locked").
  `-DispatchHardwareKeyboard YES|NO` pins the keyboard (YES also keeps the composer's software keyboard away, as a
  real one does). iPadOS keeps a floating software keyboard across launches: a run that floats it and stops before
  docking it again leaves the next runs a floating keyboard (Chat's docked-keyboard cases then failed with the composer
  under it), so the cases that need one dock it first and the floating cases dock it again, also in their teardown
  (`KeyboardDocking.swift`). A docking pinch on the floating keyboard does not always take; dragging it by its handle
  past the window's bottom edge docks it, the handle about 28 points under the frame XCUITest reports (which stops at
  the space bar's row). On the iOS 27.0 simulators XCUITest's `typeKey` never delivers Return, Esc, keypad Enter or Delete
  to the app (letters, Tab, Space, arrows and ⌘ chords arrive), and `typeText("\n")` inserts text without a key
  event: the composer's Return and Esc rules are unit tested through its key commands (`ChatIPadTests`),
  `ChatIPadUITests` covers focus, ⌘E, the docked keyboard, rotation and the wide screens (`DISPATCH_UI_SHOTS` through
  `TEST_RUNNER_` writes its screenshots to a folder).
- **Live fixture.** Makes this Mac a host: a loopback sshd with private HOME and sockets, a private tmux server, and
  Claude Code from `build/test-tools` against a local Messages API. The simulator cannot start processes, so `serve`
  restarts sshd when a test asks.

  ```sh
  python3 scripts/mobile-live-fixture.py start /tmp/sim-int
  python3 scripts/mobile-live-fixture.py serve /tmp/sim-int &
  TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-int/live.json test/run.sh --platform ios SSHDriverLiveTests
  TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-int/live.json TEST_RUNNER_DISPATCH_LIVE_LINUX='{"name":…,"host":…,"port":…,"user":…,"key":…,"root":"/tmp/dt-int"}' \
    xcodebuild -scheme DispatchMobileUITests -destination 'platform=iOS Simulator,name=<device>' -derivedDataPath build/ios \
    -collect-test-diagnostics never test -only-testing:DispatchMobileUITests/MobileLiveTests
  python3 scripts/mobile-live-fixture.py stop /tmp/sim-int
  ```

  The Linux entry is the Lima VM (`build/host-linux-ssh.json`, [vm_testing](vm_testing.md)).
- **Helper over stdio.** `python3 test/helper-stdio.py --live [--lima NAME | --remote user@host:port --identity KEY]
  [-k case] [--keep]` runs the helper exactly as the phone does, in a private root. Every tmux call uses `-S`, so it
  is safe inside the user's tmux. Not in `test/suites.json`, which holds XCTest ids only.
- **Transport.** `cargo test` in `Mobile/Transport/Core` and `swift test` in `Mobile/Transport`
  ([README](../Mobile/Transport/README.md)). The engine's shell cases run an in-process russh server (start and echo
  with no pixel size, modes or `env`, resize, exit status, the caller's close, a refused `pty-req`, a lost connection,
  and the C ABI); `ShellTests` open the login shell under the fixture sshd (TERM, `stty size` before and after a
  resize, `exit 3`, the connection's loss, `close()`, `PermitTTY no`); `HelperRootTests` pin the Mac's scripts, the
  runtime root, `launchFailure`, `fallbackRoot` and a failed launch whose stdout stays empty.
- **Plain SSH.** `SSHDriverTests` script the login and the helper on it (`ScriptedLogin`, `ScriptedHelperProcess`):
  Helper off connects without a bootstrap, the bootstrap failures and an incompatible helper go on as plain SSH with
  their text, the runtime-folder retry, a helper that exits before greeting, login refusals and a loss that
  reconnects, and the `:` check on a retry. `ScriptedHostSessionDriver` has a `.plain` step with
  `ScriptedShellOpener` and `ScriptedShell`, used by `PlainShellFeedTests` (the attach size and `.attached` before
  output, input and sizes in order, a lost shell, detach and reattach, a failed open), `HostSessionTests`,
  `TerminalPresenceTests` (scrollback, an ended shell not reopened, clipboard writes only from a plain shell), the Tabs
  classes (`TabsWorkspaceTests`, `TabsCommandTests`, `TabsSpacesTreeTests`, `TabsRenderTests`), `HostScreensTests`,
  `ResilienceCacheTests`, `HostStoreTests`, `BackgroundRefreshTests` and `WatchSnapshotTests`, all fast.
  `SSHDriverLiveTests/testAHostWithoutTheHelperOpensShells` (full) opens a shell on the live fixture.
- **Dictation.** `swift test` in `Packages/Dictation`, on the Mac: text placement, Whisper's cleanup, the model
  store, and both engines transcribing `say`'s speech (Apple's when the language's model is on the Mac, Whisper's
  with `ggml-small-q8_0.bin` in `DISPATCH_WHISPER_MODELS` or the Mac app's models folder; each skips otherwise).
- **iPad layout.** `IPadLayoutUITests` (iPad simulators on the iOS 27.0 runtime, windowed apps on) drive iPadOS's
  windowing through SpringBoard: the `window-controls:<bundle id>` element, Zoom held for Move & Resize ("Fill",
  "Left", "Top", "Enter Slide Over"), and the window's bottom right corner dragged in the app's coordinates (SpringBoard
  reports its frames upright whatever the orientation). A full-screen window shows no controls until it is shrunk, and
  the window's size and place outlive the app, so each case starts with Fill and ends with it. `XCUIElement.hover()`
  moves the pointer on an iPad simulator; `TEST_RUNNER_DISPATCH_UI_SHOTS=<folder>` keeps the screenshots, landscape
  ones stored upright. `MobileSplitTests` renders iPad sizes on an iPad simulator and skips those cases on an iPhone;
  `PadStripTests` (fast) cover the modes per host and repository, the pills, the sidebar's space rows, the neighbour
  after a close, the panes and the mode kept across launches. `IPadFidelityUITests` writes I1–I8, I6 and I6b on the
  iPad on its side (`TEST_RUNNER_DISPATCH_FIDELITY_OUT=<folder>`, the Spaces mockup sample `-DispatchSpacesMockup P1`, whose tabs and
  hosts are the iPad mockups';
  I6 and I6b through Move & Resize's Left; I5 from the demo's mba2). `testCrossingTheSplitWithAHardwareKeyboard` crosses
  the split's threshold both ways with a terminal taking the hardware keyboard's keys.
- **Frame checks.** No transient wrong state, frame by frame. `TransitionUITests` and `-DispatchTabsScript` drive
  recordings (`xcrun simctl io <device> recordVideo`); `scripts/transition-frames.swift` and
  `scripts/tab-bar-frames.swift` split and judge them.
- **Fidelity.** `FidelityUITests` pairs every mockup screen with the app's screenshot (`build/mockup-review`,
  `scripts/fidelity-pairs.swift`). The next iteration's mockups (Files, Review and Commits modes, the host stats
  widget, the iPad strip layout, the watch) are SwiftUI screens in `mockups/`, rendered by `mockups/shoot.py`; the
  ones built so far are in `FidelityUITests` too (H0, S1, S2 through the sample's `-DispatchTabsSegment` and
  `-DispatchTabsFiles`; H1 and F2 through `-DispatchFilesFolder` and `-DispatchFilesPreview`; H3 and C2 through
  `-DispatchTabsFilesMode commits` and `-DispatchTabsFilesRoute`; H2, S3, S4, R2–R5c through the Review hooks;
  `testTerminalScreens` writes T1 and T2 from the sample's dev tab on the terminal mockups' screen,
  `-DispatchTerminalSample theme`, `TerminalFixtures.viteTheme`). `SpacesUITests.testFidelity` writes the
  Spaces screens (P1, P1b, P2–P2e, P3, W0–W0c) from the mockup sample (`-DispatchSpacesMockup`), menus and swipes
  driven by the test, to `build/mockup-review/<ID>-<scheme>.png`; its other cases check the chips, the OFFLINE group,
  the Detached list, the space's menu, swipe, held New tab and Edit tabs, and the switcher. `AppearanceUITests` runs
  the accessibility audit in both schemes; accepted reports
  are listed in the test.
- **Review.** `ReviewChangesTests` drive the helper reader against `ScriptedHelper` (the exact commands and limits,
  the status folding, untracked counts, binaries, errors), `ReviewChanges`' one read at a time and cadence on a stepped
  sleep, and H2's rows, search and accessory; `ReviewDiffTests` the rows, gaps, Source, placement, outdated comments,
  selection and saving with the Mac's fields; `ReviewSendingTests` the text (the Mac's `ReviewText`), Send, Copy,
  Undo and the window's end through a scripted outlet and clock, withdrawing from a real `ChatOutbox`, the watch
  events, targets, `reviews.json` and Remove all data, and the sheet's labels. All run on `ReviewSample`.
- **Host stats.** `HostStatisticsTests` drive the store on a fixed clock and a sleep the test ends (`SteppedSleeper`):
  the cadences, the disks' interval, nothing in the background or for a probe, a new connection stale until its first
  sample, a stuck request, the bars and gaps, peak and average, Disconnect staying off and the colour choice;
  `HostStatsSheetTests` read every sheet state, host detail's strip and the popover through VoiceOver's elements, live
  numbers that differ from the seed, the chart following 2 s samples, the viewer following a replaced session and the
  hint's Reconnect lifting Disconnect; `BackgroundRefreshTests` that background refresh and watch holds skip a
  disconnected host; `WatchRequestServerTests` that the watch's Connect lifts it (foreground and background) and pull to
  refresh does not; `WatchHostStatsFeedTests` that the store's numbers reach the watch's snapshot at most every 15 s,
  staleness at once, and the scripted sample only where a host has none. The W and I5 screens come from the demo's hooks (Debug hooks, above),
  `FidelityUITests` lists them.

## Device checklist

Release build on a real iPhone, by hand. Nothing below has been run on a device yet.

1. Launch opens Spaces' empty state.
2. ED25519 key: Face ID on first use; Cancel fails the login. Re-enrolling Face ID invalidates the key with a clear
   message, and so does a phone without Face ID.
3. Secure Enclave key: one Face ID prompt per signature.
4. Copy and Share public key give the exact `authorized_keys` line.
5. Local Network prompt on the first LAN host; Don't Allow fails LAN hosts only.
6. Lock or switch apps for a minute: sessions drop and reconnect within seconds; agents kept running.
7. Background refresh with a password host and a Face ID host both waiting, the phone locked: only the password host
   notifies.
8. Wi-Fi off while connected: reconnects over cellular in about 4 s.
9. A backup restored onto another phone brings no host, key or password.
10. Free account: after 7 days the app stops opening until reinstalled, with data intact.
11. iPad with a Magic Keyboard: the menu bar shows its File, View and Navigate items (pointer at the top edge),
    holding ⌘ lists them, ⌘W closes the shown tab, Esc reaches vim in a terminal; without the keyboard nothing of it
    shows and the key capsule is back.

## Known limitations

- mosh deferred past v1 (the copy still says "mosh" though the connection is SSH); push notifications (need a relay)
  and App Store out of scope; iCloud never.
- iPad: one window only (multi-window needs per-scene compositions and host sessions); no Mac Catalyst and no
  "Designed for iPad" on the Mac. Esc does not go back ([Keyboard and menu bar](#keyboard-and-menu-bar)). Nothing has run on a real iPad yet.
- The iOS 26 New-button fallback (`.search` tab role) is untested: only the iOS 27 runtime has been used.
- Rekeys are not re-checked against the trusted host key (russh 0.64.1 has no hook; [security](security.md#dispatch-for-iphone)).
- Keyboard-interactive is untested against a real multi-round server (OTP, PAM).
- The app's live runs cover tmux; herdr only through the helper harness and scripted tests. Linux is covered on one
  arm64 Ubuntu VM; x86-64, other distributions and a real remote Mac with Homebrew tmux are untested.
- herdr tabs have no server time (herdr 0.9.5's API carries none): their time is only what the phone saw
  (`MobileWorkspace.noteActivity` has no caller yet). tmux times are whole seconds and per window, not per pane.
- Codex offers no "This session" approval: Codex 0.162 rejects `updatedPermissions` in PermissionRequest hooks.
