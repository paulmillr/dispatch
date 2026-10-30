# Dispatch for iPhone and iPad

A thin client for SSH hosts. The device has no shell and starts no processes: the Rust helper on each host does the
work, and the app speaks the helper protocol (`helper/PROTOCOL.md`) over one in-process SSH connection per host.
iOS and iPadOS 26+, one app for iPhone and iPad ([iPad](#ipad)), sideloaded (no App Store: the macOS helper would
have to become a non-Mach-O payload, ITMS-90171). Sources are in `Mobile/`; privacy, trust, keys and the helper's
grant are in [security](security.md#dispatch-for-iphone); the Apple Watch companion in [watch](watch.md).

**Hosts need** SSH (password, key or keyboard-interactive), macOS 14+ on Apple silicon or Linux arm64/x86-64, and
tmux 3.7+ or herdr 0.9.3+ ([installing](integrations.md#tmux-and-herdr)). Shells and agents live in tmux windows or
herdr tabs so they outlive the connection; the app installs nothing but its helper. tmux before 3.7 has no
bracketed-paste state: Chat to a bound agent works, other typing is refused. Linux with systemd-logind
`KillUserProcesses=yes` kills servers at logout unless the user runs `loginctl enable-linger $USER`. A host without
the helper ([Plain SSH](#plain-ssh)) needs only SSH and a login shell.

## Building and running

```sh
./run.sh --ios [--simulator "iPhone 18 Pro"] [--just-build]   # Debug in the simulator (DISPATCH_IOS_SIMULATOR)
./run.sh --ios --simulator "iPad Pro 11-inch (M5)"            # the same on an iPad
./run.sh --ios --demo                                         # three scripted demo hosts, no SSH (Debug hooks, below)
./run.sh --ios-device [--prod] ["<name or UDID>"]           # paired iPhone or iPad; --prod is Release
test/run.sh --platform ios [--simulator NAME] [--suite full] [Class]   # Testing, below
python3 test/ios-release.py [--simulator NAME]              # Release check, below
./run.sh --archive PATH [--build-number N]                  # unsigned App Store archive (docs/releasing.md)
```

- Needs Xcode 27 with an iOS simulator runtime. The simulator window is DeviceHub (`com.apple.dt.Devices`, which
  `./run.sh --ios` opens); Simulator.app is gone, and without DeviceHub the simulator runs headless
  (`xcrun simctl io booted screenshot`). `--simulator` takes a name or UDID (`scripts/ios_simulator.py`: the booted
  one wins, then the newest runtime); the default is `DISPATCH_IOS_SIMULATOR`, else iPhone Air.
- **iPad simulators need the iOS 27.0 runtime**: 27.1 has only the iPhone Duo. `xcrun simctl create my-ipad "iPad Pro
  11-inch (M5)" com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
- **Fresh checkout.** SwiftPM resolves `MobileTransport`'s binary target before any build script runs, for every
  scheme (the Mac app's too), so the pinned Rust with its iOS targets and
  `build/mobile-ssh/DispatchMobileSSHCore.xcframework` must exist first. `scripts/setup.sh` does it through
  `scripts/setup_mobile.py` (`setup-ssh-rust.py`, then `build-mobile-ssh.py --fetch`, the only network step);
  `DISPATCH_SETUP_OFFLINE=1` fails with the command instead. Setup rebuilds the XCFramework whenever its headers
  differ from `Mobile/Transport/Core/include`. Existing checkouts run `python3 scripts/setup-ssh-rust.py` once.

### Signing and a device

The team lives in git-ignored `build/signing.xcconfig` (included by `Mobile/Config/Signing.xcconfig`; the simulator
needs none): `python3 scripts/ios-signing.py --teams`, then `ios-signing.py TEAMID --suffix .you`; `--check [--xcode]`,
`--remove`. A free Apple ID works but needs `DISPATCH_BUNDLE_ID_SUFFIX` (`yachts.dispatch.pilot.mobile` is registered
elsewhere), expires after 7 days (rerun the install; data stays) and allows three such apps per phone. Changing team
or suffix makes a new app with empty data.

Once per device: pair by cable and Trust, turn on Developer Mode (Settings, Privacy & Security), and on a free account
trust the developer on first launch (General, VPN & Device Management). `--ios-device` refuses without a valid signing
config, finds real devices only, builds with `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`, then
installs and launches through `devicectl`.

### Pilot and stable

Two Apple accounts, each with its own apps; nothing is transferred between them. Every bundle id starts with
`DISPATCH_BUNDLE_ID_PREFIX` (`project.yml`): `yachts.dispatch.pilot` by default, the Pilot account's apps
(`yachts.dispatch.pilot.app`, `yachts.dispatch.pilot.mobile`, `….mobile.watchkitapp`, `….mobile.watchkitapp.widgets`,
`group.yachts.dispatch.pilot.mobile`). `--stable` on `./run.sh` and `scripts/release-prepare.sh` passes
`DISPATCH_BUNDLE_ID_PREFIX=yachts.dispatch` to xcodebuild for the stable account's (`yachts.dispatch.app`,
`yachts.dispatch.mobile`, …; published nowhere yet: the GitHub release, Homebrew and TestFlight are Pilot's). Both are named Dispatch and install side by side as
separate apps with separate data (UserDefaults, Keychain, containers); the Mac ones still share
`~/Library/Application Support/Dispatch`. `build/signing.xcconfig` holds the Pilot team;
`ios-signing.py TEAMID --stable` writes the stable team to `build/signing-stable.xcconfig`, whose team and suffix
`./run.sh --ios-device --stable` passes on the command line (over `build/signing.xcconfig`). A command-line setting
changes every target's build description, so switching between the two rebuilds everything.

### Release

`./run.sh --ios-device --prod` and `test/ios-release.py` build the helpers with Cargo's `release` profile
(`DISPATCH_HELPER_PROFILE=release`); a plain `xcodebuild -configuration Release` uses the faster `local` one. Release
strips the executable after making its dSYM; the bundle is about 35 MB, 20 MB of it the three helpers.
`test/ios-release.py` (`--simulator`, `--helper-profile local`, `--skip-build`, `--no-launch`, `--with-fast-suite`)
builds Release for simulator and device, checks the helpers' architectures and versions, Info.plist's device keys, the
privacy manifest, and that every required-reason API the executable imports is declared in
`Mobile/App/PrivacyInfo.xcprivacy`; the same for the embedded watch app. The fast suite cannot run against Release
(`@testable`, Debug-only demos). TestFlight builds come from `scripts/release-prepare.sh`: `./run.sh --archive` builds
Release for any iPhone without signing (`CODE_SIGNING_ALLOWED=NO`; Xcode signs iOS code only with a team), the script
signs it ad hoc with the targets' entitlements, and the signing machine exports and uploads it
([releasing.md](releasing.md)). Not applied yet: deduplicating licence texts (2.8 MB), shipping helpers compressed,
`-Osize` for app code.

## Architecture and data flow

| Target | What |
| --- | --- |
| `DispatchMobile` | The app, bundle id `yachts.dispatch.pilot.mobile` + suffix (Pilot and stable), iOS 26.0, iPhone and iPad. Embeds the watch app. |
| `DispatchMobileTests` | Unit tests hosted by the app: `Mobile/Tests` plus the Mac's Foundation-only tests by path. |
| `DispatchMobileUITests` | XCUITests, own scheme so unit runs never start the app. |
| `TermMobile`, `TermAppleMobile` | `Vendor/Term` and `TermApple` for iOS, without `Launch`, `Pty`, `Frames`, `Session`, `TerminalView`. Fonts are `TermFonts`: a top-level `Resources` folder breaks an iOS bundle's signature. |
| `MobileTransport` | Local Swift package (`Mobile/Transport`, see its README) over the Rust SSH engine. |
| `Dictation` | Local Swift package (`Packages/Dictation`) shared with the Mac; its Whisper engine is `Packages/WhisperEngine`, its Parakeet engine Core ML models it downloads. |

The iOS settings group sets `ARCHS = $(ARCHS_STANDARD)` (the project's native arch is the Mac's arm64e). Zstd is not
linked: `AppReplay` compiles for its types, but no journal ever starts.

### Shared sources

Mac sources the phone uses stay in `Dispatch/` and are listed by path in `project.yml` ("Shared with the Mac app").
They change only by `#if canImport(AppKit)` guards or additive, behaviour-preserving helpers; `test/ios.py` is the
build that catches a Mac-only type leaking in. `Mobile/Shared/System.swift` stands in for the Mac's AppKit-only
`System` (a `SystemProvider` seam replacing it is deferred). Shared today: the chat transcript merge rules (`ChatTranscript`, run by the Mac's `ChatSession` and the
phone's `MobileTranscript`), displayed items and prompt confirmation, the git models, parsers, graph lanes and log
commands (`Dispatch/Files/GitLog.swift`), the Files models, the Review models and text, and the Dictation package.
Mac views built on the Mac chat stack are ported, not shared.

### Areas and seams

| Area | Directory | Owns |
| --- | --- | --- |
| Hosts | `Mobile/Hosts`, `Keys`, `Store` | Host, key and known-host stores, `HostSession(s)`, plain SSH shell tabs (`ShellSessions`), New host, host detail, trust sheet |
| Tabs | `Mobile/Tabs`, `Mobile/App` | Shell, Spaces tree, a space's tabs, the switcher, `TabScreen`, the iPad split and strip, the menu bar (`MobileCommands`) |
| Chat | `Mobile/Chat`, `Mobile/Agents` | `MobileChatSession`, Agents list, thread, approvals, queue, side conversations, New chat |
| Terminal | `Mobile/Terminal` | `TerminalHostView`, `TerminalFeed` (`PlainShellFeed` for plain SSH), `TerminalPresence`, key capsule, search |
| Transport | `Mobile/Transport` | SSH, auth, host-key delegate, exec and shell (PTY) channels, bootstrap, plain SSH fallback, reconnect |
| Code, Files, Commits, Reviews | `Mobile/Code`, `Files`, `Commits`, `Reviews` | Diff viewer and code composer; Files listing and preview; the Commits log; Review comments and sending |
| Stats | `Mobile/Stats` | `HostStatistics` per `HostSession`, the stats sheet and popover |
| Resilience, Settings, Watch | `Mobile/Resilience`, `Settings`, `Watch` | Network watching, launch cache, background refresh, notifications; Settings; the phone's side of the watch link |

- `HostSession` is the one object the UI observes per host. Other areas get a `HelperClient` and `HelperTopology`
  from it (a `ShellOpener` on a plain SSH connection) and never see SSH: only `Mobile/Transport/Integration` imports
  `MobileTransport`, and the package stays platform-neutral. Every connection-state mapping is in
  `HostLinkMapping.swift`.
- `MobileComposition` is the root: on every `HostSessions.changed` (same main-actor turn) it feeds `MobileTabs.sync`
  and `ChatConversations.update`; Chat's urgency flows back into Spaces' dots. One `NavigationStack` holds the tab bar.
- **Identity.** Node, tab, space and backend ids change with every helper connection. Everything kept on the phone
  (activity times, seen markers, split memory, the launch cache) is keyed by host plus topology `key`. A cached or
  previous-helper snapshot is listed but not live (`topologyIsLive`) until the connection's first own topology.
- Tests use one scripted peer over `Pipe()` (`ScriptedHelper`) and `ScriptedHostSessionDriver`.

### Transport

The engine is Rust `russh` (`ring`, `rsa`) behind a hand-written C ABI (`Mobile/Transport/Core`, crate
`dispatch-mobile-ssh`), built into an XCFramework by `scripts/build-mobile-ssh.py` in a minimal environment so Xcode's
settings cannot leak into ring's C build. swift-nio-ssh was rejected (Apple's has no RSA user keys or
keyboard-interactive; Citadel's fork signs RSA with SHA-1 only, refused by OpenSSH 8.8+), and ring over aws-lc-rs needs
no cmake. Third-party Rust enters only here; `helper/` stays dependency-free.

- Private keys sign in Swift (CryptoKit, Secure Enclave) through the external-signer callback and never cross the
  FFI. File keys are parsed in Rust. RSA signs `rsa-sha2-512/256`, never `ssh-rsa`.
- The host-key callback is answered later (`dms_reply_bool`), so the trust sheet can wait; the handshake deadline
  pauses meanwhile. `disconnected` fires exactly once.
- An exec channel is a socketpair fd pumped by Rust with backpressure both ways; `HelperTransport` reads it unchanged.
  A shell channel (plain SSH) is a session channel with a PTY; the package README specifies it.
- Limits: host certificates refused, user certificates not wired; no x86_64 simulator or Intel Mac slice;
  `panic = "abort"`; release-built even in Debug.

### Connection

`SSHHostSessionDriver` connects (host key through `KnownHostStore`), logs in, uploads the helper for the host's `uname`
to `~/.dispatch/bin/versions/<sha256>/` (or the runtime folder, [Helper contract](#helper-contract)), starts it, greets
it, reads `multiplexers.list` and `backends.list`, waits up to 2 s for the first topology, then is ready. It pings
with `echo` every 10 s. A host with its Helper switch off stops after the login, and a helper that cannot be
installed, started or used leaves the connection up without it: both are [plain SSH](#plain-ssh).

- Lost link or helper: `reconnecting` at once (keepalive 15 s × 3), backoff 1 s up to 60 s, raced by `retryNow()`
  (network change, foregrounding, pull to refresh; on a connected link it probes `echo` within 3 s, `:` on a plain
  one, and closes a dead one). Refusals (host key, login, missing key) are final; after a host-key mismatch nothing
  retries until the user acts. Each connection decides again between the helper and plain SSH.
- Foreground connects every host, background disconnects. **Disconnect** in a host's stats (`HostSession.park`) leaves
  the host alone until a Connect or Reconnect the user asks for (`connectByUser`) or the next launch; nothing else
  (network changes, pull to refresh, background refresh, watch requests) lifts it.
- **Which multiplexer.** Connecting never starts a server. herdr's `backends.open` starts one, so herdr is followed
  only while its server runs or the host asks for it; otherwise tmux, retried every 2 s. A preference change switches
  live without reconnecting; until the new one answers the host's spaces are unknown (`switchingMultiplexer`). The
  exec channel names no herdr socket, so the helper uses herdr's own default, as `herdr` typed in a shell does; only
  variables the login shell's `-c` exports (`.zshenv`) reach it.

## Helper contract

The phone runs, on an exec channel with no PTY and no `env` requests:

```sh
exec "$HOME/.dispatch/bin/versions/<sha256>/dispatch-helper" --remote --capabilities <HelperGrant> --stdio
```

**Install root** (`HelperBootstrap.Root`). A home folder mounted `noexec` takes the upload but cannot run it: `test -x`
refuses it on hosts whose `/bin/sh` asks the kernel, elsewhere the helper exits 126 before greeting. Either way the
driver installs and starts it once more, on the same connection, from `$XDG_RUNTIME_DIR/dispatch/bin/versions/<sha256>/`
(`fallbackRoot`; the probe reports whether that folder is usable without writing anything). Nothing else falls back: a
helper that exits before greeting gives `launchFailure`'s text and the host goes on as plain SSH. The launch command's
checks write their `dispatch-setup:` reason to stderr only. Both apps send the same cache check
(`SSHBootstrapScript.cacheCheck`, pinned in `HelperRootTests`); the Mac tries the runtime root only once the home
folder proved unable to run programs, for grants without agent hooks ([security](security.md#ssh-integration)).

**The grant** is the Mac's full profile with hooks less file writes (`HelperGrant`: never `file.write`). Two per-host
switches narrow it: Chat off drops `hooks.configure` and `agent.*`, Files & git off drops `git.read`. Turning either
off sends `permissions.reduce` to the running helper (a reconnect when that fails); turning either on reconnects, as a
grant only shrinks. The phone's hello features (`SSHHostSessionDriver`) are specified in `helper/PROTOCOL.md`; what
they let the helper do on the host is in [security](security.md#dispatch-for-iphone). The client must:

- **Ping.** With `stdio.liveness` the helper exits after 45 s without a frame; send `echo` at least every 15 s. A drop
  can reach the host late, so a reconnect may briefly meet the old helper. Only time the helper reads the phone
  counts, and `stdio.liveness` implies `requests.backlog`: during a flood of terminal output the helper still reads
  the pings (and keystrokes, cancels) even though their replies wait behind the output.
- **Host screens.** `chat.send`, `queue.start` and typed answers are verified against the terminal's screen, which
  the helper reads only while a client attaches the terminal; without a screen they fail with `terminal_unavailable`.
  So a conversation keeps its terminal attached (`TerminalPresence`) even when only Chat shows. The phone names
  `screens.host`, as the Mac does: an accepting helper reads the screens of the tmux and herdr terminals the phone
  attaches from the multiplexer itself, and the phone publishes nothing for them (`HelperTerminalFeed.hostsScreens`;
  every helper terminal on the phone is tmux or herdr): one `terminals.publish` would turn those reads off for that
  terminal until the phone's attach of it ends, and nothing reads the screen's text on the phone for it either. An
  older helper that drops the feature gets the screens published as before (`terminals.publish`, ≤30/s, after
  output). Reset terminal waits for a send in flight either way: its reattach ends the attach the send is verified
  through.
- **Held output.** With `terminals.follow` accepted too (`holdsOutput`), a presence no terminal view shows (only a
  conversation uses it: the Chat segment, Files, another tab or the tab list) asks for `terminals.follow
  {terminal, following: false}` after a 2 s grace (`TerminalPresence.followGrace`; a glance at Chat and back holds
  nothing), names no `subscription` (the phone has one attach per terminal and connection), and stays attached:
  input, exits, chat records and the helper's own reads go on, the output stops, so the presence parses and reads
  nothing. A Terminal segment showing it again sends `following: true` at once, and the repaint that comes as the next
  output is parsed as ordinary output (tmux: `\ec` and the whole history, so the scrollback is complete again;
  herdr: the alternate screen's full frame). `unsupported` keeps the terminal following for good; a failed `true`
  leaves the output held, so the presence attaches again (its replay repaints); a failed `false` keeps following. A
  new attach (a reconnect, Reset terminal, the last user leaving and coming back) follows: the helper forgot the old
  hold with its subscription.
- **Reattach by key**, not id: after reconnecting, `backends.open`, find terminals by topology key, then `chat.open`
  and `terminals.attach` again.
- **Follow binding changes.** A Codex conversation gets its thread id with the first prompt; reopen `chat.open` on a
  new binding. `chat.open` answers with a `chat.history` notification and `backends.open` with `backend.opened`, not a
  response frame.
- **Re-enable integrations per connection.** `installation.install` state is in helper memory: every connection with
  Chat on installs Claude Code's and Codex's hooks and enables Pi's extension where installed (Pi's is opt-in: New
  chat asks first). A per-host refusal given on the Mac stays on the Mac; the phone's consent is its Chat switch.
- **Surface native trust steps.** Codex shows "Hooks need review" after the helper installs hooks; until the user picks
  "Trust all" in its terminal, approvals stay in Codex's TUI.
- **Keep the outbox.** A Claude Code or Pi queue of a named conversation lives in the host's queue store and survives
  the helper; after reconnecting the device matches its items by id, and an item the host no longer holds was sent
  or removed there. Only a queue of a conversation the agent has not named yet dies with its helper; the device
  re-adds those, and anything possibly in flight at the drop is paused for the user, never sent twice.
- **Expect input refusals** right after an agent starts (`input`: nothing was typed); send once more shortly after.
- **Send raw bytes** (binary tag 11) in `terminals.input`.
- **Scrollback.** tmux replays pane history on every attach, so its scrollback is the client's
  (`scrollback_app_owned`); herdr's is the server's (`terminals.scroll`, `terminal.scroll`).

**Replays.** Every phone-only behaviour sits behind a hello feature the Mac never names, so the Mac's recorded sessions
replay unchanged. Keep it that way (`memberships.append` exists for exactly this: herdr's corrected end-of-workspace
index, which the Mac's recordings do not expect). `screens.host` and `terminals.follow` are the Mac's own features: the
phone names them too and uses them as the Mac does, so the helper does nothing for the phone that the Mac's
recordings do not already cover, and a helper serving both keeps each client's behaviour on its own connection.

## Behaviour

The policies below are the ones a change must keep; the screens themselves are described where they are built
(each view's header comment names its mockup).

- **Hosts and trust.** Trust on first use per host and port; a changed key is a hard stop with only Remove and retry.
  An unreadable `known_hosts.json` fails closed, never read as empty. New keys are ED25519 behind
  `biometryCurrentSet`, or Secure Enclave P-256; neither signs unattended. Passwords and passphrases are
  `AfterFirstUnlockThisDeviceOnly` and the app's files class C, so background refresh and watch requests log in with a
  password while the phone is locked. A new host takes the colour the fewest hosts show and keeps it; colours are
  drawn per machine (`HostColorStore`). Two hosts reaching one machine and account show its spaces and agents once,
  under the first in the list (`sameMachine`), as the Mac keys a host by machine and uid.
- **Windows.** A window at least 600 points both ways (the unfolded iPhone Duo) or an iPad window from 655.5 points
  wide shows the Spaces tree in a sidebar beside the open tab (`MobileSplit`, by window size, never size class or
  screen); narrower windows are the phone's stack. Both columns show the one `SpacesNavigator.path`, so folding and
  unfolding keep the screens. The iPad's detail column has a strip of the space's tabs and a mode switch (Terminal,
  Chat, Files, Review, Commits; `PadStrip`, `PadMode`); the sidebar can hide (⌃⌘S) and comes back when no tab is
  left. An iPad remembers the shown tab, mode and sidebar state across launches (`restoreSplit`, before the first
  body), keyed by topology key. The vertical bar of iOS 27.1 is off on windows wide enough for the split
  (`MobileVerticalBar`).
- **Spaces.** herdr workspaces and tmux sessions are spaces; windows and tabs are tabs. A split tmux window shows one
  pane; the phone never splits. The helper's native multiplexer never counts (its sessions die with the connection).
  Close follows the Mac's policy: Close Tab sends `close.request` `check` and terminates only verified idle work,
  otherwise detaches; a space offers Detach and Terminate… and never ends by itself. Tab names, space names
  (`usesDirectoryName`, kept on the server) and the Activity sort follow the Mac. New tab sends no folder, so the
  multiplexer opens it in its focused pane's directory. Reorders go to the server (`memberships.move`) and the rows
  keep the new order until the answer or a snapshot naming the moved tab. Paths shorten to `~` by
  `hello.account.home` and `login_home`, never by guessing `/Users/<name>`. A host shows one multiplexer's spaces at
  a time; hosts not connected nor on their way go to the OFFLINE group.
- **Times.** A tab's time is the later of the server's (`terminals.activity`, read on each live snapshot and every
  30 s) and the last change the phone saw between two live snapshots of one connection; kept per host and topology
  key (`TabActivityStore`). Changes found across a gap (cache against live, a reconnect) happened at an unknown time
  and move nothing. herdr 0.9.5 reports no times.
- **Files, Review and Commits** read only, through `MobileFilesSource` and `ReviewGitReader` (never `file.write`),
  only with a connected helper and the Files & git grant; their exact commands, bounds and cadences are the ones
  [security](security.md#dispatch-for-iphone) lists, and the Mac's shared parsers and placement rules apply. The
  repository and branch of a folder are `SpaceGitFacts`, once per folder and connection, the branch every 10 s (the
  Mac's for a shown branch) only while something shows it. A review is one per host and repository root
  (`ReviewPlace`, `reviews.json`, the Mac's format); Send finds every comment's lines again first, goes through the composer's routing, and leaves the comments
  in place until confirmed; Undo (60 s) withdraws a queued review and the watch mirrors only that Undo. Open in
  Terminal types into the shell only while its program is a shell with no full-screen program up, never for a folder
  name with control characters.
- **Chat.** `chat.open` only for a bound terminal; the conversation is accepted once `chat.history` names the same
  process. Losing link or binding pauses input and keeps transcript and drafts. Dots follow Mail: blue for needs you
  or unseen, amber for working; a conversation's first sight is its baseline; seen markers stay per device. Needs you
  is an open approval or question or the agent's own attention, as on the Mac. A command (`/…`, `!…`) goes at once
  when the agent is idle, otherwise queues (`/…` in the helper's queue, `!…` on the device until it reaches the head
  of an idle queue). Queued messages belong to the agent process they were typed for; Stop pauses the device's own
  until Resume, and Send now refuses paused or uncertain ones. Side conversations (`/btw`, `/side`) are forks the
  helper lists; a lost link ends one on the phone and the next verified connection closes the orphaned fork
  (`closeOrphanedSides`). Attachments are offered only while the helper accepted `chat.attachments` and the
  conversation is verified; images lose their metadata before upload, uploads are session state, and a queued
  message counts as delivered after a reconnect only with as many attachments. Conversation mode
  (`MobileVoiceConversation`) is half-duplex as the Mac's and never grants permission by voice. Composers are
  `ChatEditorTextView`-based, as on the Mac.
- **Terminal.** Output is coalesced (up to 256 KiB per parse) because tmux sends one notification per line; the
  presence holds a whole helper reply (64 MiB) unparsed, since overflow ends the attachment. Only a lost stream of the
  current attachment detaches the feed. A run of size changes reaches the server once, 100 ms after the last
  (`TerminalPresence.resizeQuiet`); calls go out one at a time and scroll steps join. Input, sizes and screens wait
  for `terminal.attached`. A program's copy (OSC 52, kitty) is denied behind the helper (no consent surface) and
  allowed from a plain shell; reads are denied for every feed. Reset terminal reattaches a helper terminal (RIS from
  the server's history) and only resets the emulator for a plain shell; it is disabled while Chat sends through the
  terminal. Search is Ghostty's on the local emulator (`TerminalSearch`), newest match first. The iPad rules
  (software keyboard placement from `keyboardLayoutGuide`, the hardware keyboard taking every key without ⌘,
  pointer selection) are in `TerminalAdaptation` and `TerminalHostView`.
- **Host stats.** `HostStatistics`, one per `HostSession`: `stats.sample` and `stats.processes` every 15 s in the
  foreground (one per chart bar), 2 s while a sheet shows the host, 30 s under Low Power Mode (a bar without its own
  sample takes the next one, `barHold` 35 s), `stats.disks` with a sample at most every 15 s; nothing in the
  background, on plain SSH or before something shows the stats. Numbers are `live` only after the connection's own
  first sample; the last sample and 15 minutes of history stay through a drop, stale. Red thresholds are the Mac's
  (CPU 90 %, memory 90 %, disk 80 %). The watch reads `summary(at:)` through `WatchHostStatsFeed`, at most one change
  per 15 s ([watch](watch.md#seams)).
- **Resilience.** `host-cache.json` (last hello, multiplexers, topology, Agents rows with ≤280-character previews, a
  plain host's shell tabs without screens) is read synchronously at launch so the first frame lists every host; live
  data reconciles in place and cached files decode leniently per entry. Pull to refresh calls `retryNow()` on every
  host and waits at most 10 s. Each host's last update (`HostSession.updated`) is shown for an offline host and read by
  VoiceOver.
- **Background refresh.** A `BGAppRefreshTask` (`<bundle id>.refresh`), off by default. It connects hosts with Chat
  and the helper on through a session that asks nothing (Face ID key hosts and parked hosts are skipped), reads
  `chat.list`, notifies as Settings allows (`AgentAlerts`), sets the badge, and ends within 25 s. It never touches
  seen markers.
- **Notifications** (`AgentAlerts`). Events between two looks at a conversation: newly needs you, Finished (was busy,
  now idle and not waiting), Failed or disconnected (was busy, and its agent left the terminal or the terminal closed
  in a live topology). While the app is open the same banners post for live rows only, except the thread on screen, a
  muted conversation, a terminal the user closed from the phone in the last minute, or a stop the agent recovers from
  within 10 s. Permission is asked once a run. There is no Allow or Deny in a banner: an approval belongs to a live
  subscription.
- **Settings.** Everything is `MobileSettings` in UserDefaults. Per host: Chat, Files & git, multiplexer. Terminal
  font (`TerminalFont.all`: the Mac's bundled fonts in `TermFonts` plus Menlo), colour scheme (Ghostty's bundled
  themes, `dispatch-black` by default and kept in light mode), contrast (`TextContrast`, shared) and line spacing
  (`LineSpacing`, shared, one key for terminal and chat); each change posts `TerminalStyle.changed` and every open
  presence restyles at once, keeping its own size. Terminal font size: 12 on iPhone, 14.5 on iPad, kept as the size
  at the standard text size and drawn scaled as body text scales (`TerminalAdaptation.fontSize`, capped at XXXL's
  ×1.32); a text-size change moves every open terminal by the change; every font at Source Code Pro's apparent size
  (`TerminalFontScale`, shared). Chat font and text size (`ChatTypography`, following Dynamic Type).
  Theme (the Mac's `SidebarPalette`s, resolved through `UIColor.themed` so UIKit and SwiftUI recolour live).
  Notifications, Background refresh, the Apple Watch status row.
- **Appearance.** Dark by default, every colour with a light variant. System menus and segmented controls replace
  the mockups' custom ones.

**Debug hooks** (compiled out of Release). Environment through `SIMCTL_CHILD_`: `DISPATCH_MOBILE_STORE=memory`
(nothing saved, no Face ID), `DISPATCH_MOBILE_SCRIPTED=1|empty|trust|mismatch|nomux` (scripted hosts, no SSH),
`DISPATCH_MOBILE_DEMO=1` (the demo hosts), `DISPATCH_MOBILE_CHAT_DEMO=<screen>`, `DISPATCH_MOBILE_AUTHORIZE_KEYS`,
`DISPATCH_MOBILE_HOST_ENV`. Launch arguments open screens and pin state for tests and screenshots: `-DispatchTabsSample`
and `-DispatchTabsShow …` (`SpacesRoot`), `-DispatchSpacesMockup`, `-DispatchTabsSegment`, `-DispatchTabsFilesMode`,
`-DispatchFilesFolder`, `-DispatchFilesPreview`, `-DispatchTabsFilesRoute`, `-DispatchReviewDiff`, `-DispatchReviewSheet`,
`-DispatchHostStats`, `-DispatchHostDetail`, `-DispatchSettingsShow G1…G5`, `-DispatchHardwareKeyboard YES|NO`,
`-DispatchTerminalEcho keys`, `-DispatchLowPower YES`, `-DispatchSplitMemory YES`, `-DispatchTabsScript`.
`grep -rn 'forKey: "Dispatch' Mobile` lists them with their parsers. The demo (`Mobile/Demo`: mba2, studio and ai through the scripted
driver to an in-process `DemoHelper` on the real wire codec; fixtures regenerated by `test/mobile-demo-fixtures.py`,
all fictional) runs the app's own code for Spaces, Agents, threads, approvals, terminals and stats. To force a
background refresh, pause in lldb:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"yachts.dispatch.pilot.mobile.refresh"]
```

### Plain SSH

A host can go without the helper: the phone opens interactive login shells on its own SSH connection, each with a
PTY, and runs nothing else there. Terminal only: no Chat, Agents, server spaces, latency, background refresh or watch
snapshot. `HostSession.mode` says how the current connection reaches the host, `.helper` or `.plain(reason:)`.

- **The Helper switch** (`HostRecord.helper`, on by default) is in New host and host detail. Off turns Chat and
  Files & git off with it and hides them; Settings lists such a host as "Plain SSH". Turning the switch on, or off on
  a helper connection, reconnects; turning it off on a connection that is already plain keeps the shells. With the
  switch off the driver stops after the login: no probe, no upload, nothing in `~/.dispatch`.
- **Fallback.** With the switch on, a helper step that fails while the SSH connection stays up leaves the connection
  as plain SSH with the failure's text (`SSHHostSessionDriver.fallback`): an unsupported or unidentified platform, a
  missing bundled binary, an upload or cache failure (a transient one tried once more), a refused exec channel, a
  helper that exited before greeting (after the one runtime-folder retry) or is unusable (`hello` failed, another
  protocol version). Login, host key and missing-key refusals stay final, and a connection that dropped meanwhile
  is a loss that reconnects; an ambiguous failure is first checked with the `:` probe. Host detail then says "Plain
  SSH · helper could not be installed: <reason>" and offers **Use plain SSH for this host**. Each connection decides
  again.
- **The Shell space.** A plain host shows one synthetic space, "Shell" (`MobileSpace.Kind.plainShell`), whose tabs are
  the phone's own shells (`ShellSessions`, keyed `shell:<uuid>`). New tab opens a shell at once, only while
  plain-connected; Close tab ends a live shell without asking; Close space asks while one is live; New space is not
  for this host. A shell ends with its channel or the connection (a drop, the background, an edit that reconnects),
  and its tab stays as a card with the last screen and exit status (`TerminalEndedCard`); nothing restarts a shell.
  The launch cache keeps the tabs without screens, listed as ended cards. The PTY opens at the presence's grid, TERM is
  `xterm-256color`, scrollback is the emulator's, OSC 52 writes go to the pasteboard.
- **Liveness.** No helper, so no `echo` ping or latency: the SSH keepalive watches the link, and `retryNow()` runs
  `:` on an exec channel (any answer counts as alive; silence past 3 s closes the link). `HostSession.plainSSH` keeps
  the host out of Agents, Chat, background refresh, the watch and same-machine pairing.

## iPad

The same app with the iPad's conventions; every iPhone screen and the Duo's split stay as they are. One window
(`UIApplicationSupportsMultipleScenes` off: the composition and host sessions are app-wide), resizable under iPadOS
windowing and Stage Manager; a narrow window is the iPhone's stack. Two kinds of iPad are first class: **touch only**
(software keyboard and the terminal's key capsule) and **with a keyboard and trackpad** (the menu bar, ⌘ shortcuts, every
other key straight into the terminal). `HardwareKeyboard.shared.attached` is the one detector; Debug's
`-DispatchHardwareKeyboard YES|NO` pins it. Sheets are the system's form sheets on an iPad, the phone's detents on a
phone (`mobilePhoneDetents`). Nothing has run on a real iPad yet.

### Keyboard and menu bar

`MobileCommands` (Mobile/App) puts the Mac's menus where the phone has the same thing into iPadOS's menu bar, as
SwiftUI `.commands`; one table (`MobileCommand`) feeds the menu bar, the ⌘-hold overlay and Help › Keyboard Shortcuts
(⌘/). The chords work on the phone too with a keyboard.

| Menu | Items |
| --- | --- |
| Dispatch | Settings… ⌘, |
| File | New Tab ⌘T, New Space… ⌘N, New Chat… ⌥⌘N, New Host…; Rename Tab…, Rename Space…; Close Tab ⌘W, Close Space… ⇧⌘W, Detach Space |
| Edit | the system's items, then Find… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G (the terminal's search or the conversation's), Clear Screen ⌘K, Attach Files… ⇧⌘A |
| View | Increase, Decrease, Reset Font Size ⌘+ ⌘- ⌘0; Toggle Sidebar ⌃⌘S, Switch Terminal / Chat ⇧⌘C, Switch Terminal / Files ⇧⌘F, Review Changes ⇧⌘U, Commits ⇧⌘L |
| Navigate | Spaces ⌘1, Agents ⌘2; Next and Previous Attention ⌘J ⇧⌘J; Previous and Next Tab ⌘[ ⌘] |
| Help | Keyboard Shortcuts ⌘/ |

- Commands act on the screen on top, in the stack and the split alike (`SpacesNavigator+Commands`); items that do
  not apply are disabled, and everything is while a sheet is up. Find, Clear Screen and the font sizes go down the
  responder chain to the focused terminal or the chat search. Every app chord has ⌘ and the terminal claims no ⌘
  chord, so a focused terminal gets Esc, Tab, Control and Option chords, arrows and function keys.
- **Esc does not go back.** SwiftUI commands never get Esc, and in the simulator no Esc press reached the app's own
  first responder either; a field's or the terminal's own Esc is theirs.
- SwiftUI's menu-group quirks (why the sections sit where they do, why Find is not a submenu) are documented in
  `MobileCommands.swift`.

## Testing

- **Suites.** `test/run.sh --platform ios` (`test/ios.py`) runs the fast suite on the simulator, an iPhone by default;
  `DISPATCH_IOS_SIMULATOR="<iPad simulator>"` runs the same cases on an iPad (family-specific cases `XCTSkip` on the
  other). Cases are classified in `test/suites.json` as `DispatchMobileTests/<Class>/<test>` and
  `DispatchMobileScripts/<Class>/<test>` (Python tests of the release tooling); a fast run fails on an unclassified
  case. `--derived-data PATH` builds elsewhere than `build/ios`, so two runs do not wait on one build database. New
  tests go in `Mobile/Tests/<Area>…Tests.swift`; after adding files, run `python3 scripts/generate-project.py` and
  commit `project.pbxproj`.
- **UI tests.** `xcodebuild -scheme DispatchMobileUITests -destination 'platform=iOS Simulator,name=iPhone Air'
  -derivedDataPath build/ios test`, against the scripted hosts; `test/run.sh` skips them. The scheme can hang after
  its result line: wrap it in `perl -e 'alarm 595; exec @ARGV' --`. Known simulator limits: XCUITest's `typeKey` never
  delivers Return, Esc, Delete, Home, End or Page keys and shifts F-keys down by one (those rules are unit tested
  through the commands); a synthesized ⌘ hold shows no overlay; pointer events and window resizing (Split View, Slide
  Over, Stage Manager sizes) cannot be synthesized, except through SpringBoard's window controls
  (`IPadLayoutUITests`); iPadOS keeps a floating software keyboard across launches, so cases dock it first and in
  teardown (`KeyboardDocking.swift`). `TEST_RUNNER_DISPATCH_UI_SHOTS=<folder>` keeps screenshots.
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
  [-k case] [--keep]` runs the helper exactly as the phone does, in a private root. Not in `test/suites.json`.
- **Transport.** `cargo test` in `Mobile/Transport/Core` (an in-process russh server) and `swift test` in
  `Mobile/Transport` (the login shell under the fixture sshd; `HelperRootTests` pin the bootstrap scripts).
- **Dictation.** `swift test` in `Packages/Dictation`, on the Mac; engine cases skip without their models.
- **Frame checks.** No transient wrong state, frame by frame: `TransitionUITests` and `-DispatchTabsScript` drive
  recordings (`xcrun simctl io <device> recordVideo`); `scripts/transition-frames.swift` and
  `scripts/tab-bar-frames.swift` split and judge them.
- **Fidelity.** `FidelityUITests`, `IPadFidelityUITests` and `SpacesUITests.testFidelity` pair every mockup screen
  with the app's screenshot in `build/mockup-review` (`scripts/fidelity-pairs.swift`); the mockups are SwiftUI
  screens in `mockups/`, rendered by `mockups/shoot.py`. `AppearanceUITests` runs the accessibility audit in both
  schemes; accepted reports are listed in the test.

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
11. iPad with a Magic Keyboard: the menu bar shows its items, holding ⌘ lists them, ⌘W closes the shown tab, Esc
    reaches vim in a terminal; without the keyboard the key capsule is back.

## Known limitations

- mosh deferred past v1; push notifications (need a relay) and App Store out of scope; iCloud never.
- iPad: one window only (multi-window needs per-scene compositions and host sessions); no Mac Catalyst and no
  "Designed for iPad" on the Mac. Esc does not go back.
- The iOS 26 New-button fallback (`.search` tab role) is untested: only the iOS 27 runtime has been used.
- Rekeys are not re-checked against the trusted host key (russh has no hook; [security](security.md#dispatch-for-iphone)).
- Keyboard-interactive is untested against a real multi-round server (OTP, PAM).
- Live runs cover tmux; herdr only through the helper harness and scripted tests. Linux is covered on one arm64
  Ubuntu VM; x86-64, other distributions and a real remote Mac with Homebrew tmux are untested.
- herdr tabs have no server time; tmux times are whole seconds and per window, not per pane.
- Codex offers no "This session" approval: Codex rejects `updatedPermissions` in PermissionRequest hooks.
- A program's copy (OSC 52) is denied behind the helper: the phone has no consent surface for it, unlike the Mac's
  "Programs can copy".
