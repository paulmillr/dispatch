# Dispatch for iPhone

A thin client for SSH hosts. The phone has no shell and starts no processes: the Rust helper on each host does the
work, and the phone speaks the helper protocol (`helper/PROTOCOL.md`) over one in-process SSH connection per host.
iOS 26+, iPhone only, sideloaded (no App Store: the macOS helper would have to become a non-Mach-O payload,
ITMS-90171). Sources are in `Mobile/`; privacy, trust, keys and the helper's grant are in
[security](security.md#dispatch-for-iphone).

**Hosts need** SSH (password, key or keyboard-interactive), macOS 14+ or Linux arm64/x86-64, and tmux 3.7+ or herdr
0.9.3+ ([installing](integrations.md#tmux-and-herdr)). Shells and agents live in tmux windows or herdr tabs so they
outlive the connection; the app installs nothing but its helper. tmux before 3.7 has no bracketed-paste state: Chat to a bound agent works, other typing is refused,
and the Mac's readiness warning shows. Linux with systemd-logind `KillUserProcesses=yes` kills servers at logout
unless the user runs `loginctl enable-linger $USER`.

## Building and running

```sh
./run.sh --ios [--simulator "iPhone 18 Pro"] [--just-build]   # Debug in the simulator (DISPATCH_IOS_SIMULATOR)
./run.sh --ios-device [--prod] ["<name or UDID>"]           # paired iPhone; --prod is Release
test/run.sh --platform ios [--suite full] [Class]           # Testing, below
python3 test/ios-release.py                                 # Release, below
```

Needs Xcode 27 with an iOS simulator runtime. Without Simulator.app the simulator runs headless
(`xcrun simctl io booted screenshot shot.png`).

**Fresh checkout.** SwiftPM resolves `MobileTransport`'s binary target before any build script runs, so the pinned
Rust with its iOS targets and `build/mobile-ssh/DispatchMobileSSHCore.xcframework` must exist first. `./run.sh --ios`
and `test/run.sh --platform ios` do it through `scripts/setup_mobile.py` (`setup-ssh-rust.py`, then
`build-mobile-ssh.py --fetch`, the only network step). `DISPATCH_SETUP_OFFLINE=1` fails with the command instead.
Every existing checkout must run `python3 scripts/setup-ssh-rust.py` once, or the helper build's offline toolchain
check fails on the missing iOS targets.

### Signing and a device

The team lives in git-ignored `build/signing.xcconfig` (included by `Mobile/Config/Signing.xcconfig`; the simulator
needs none). `python3 scripts/ios-signing.py --teams` lists teams; `ios-signing.py TEAMID --suffix .you` writes it;
`--check [--xcode]`, `--remove`. A free Apple ID works (no entitlement it lacks is used) but needs
`DISPATCH_BUNDLE_ID_SUFFIX` (`yachts.dispatch.mobile` is registered elsewhere), expires after 7 days (rerun the
install; data stays), and allows three such apps per phone. A paid team re-signs yearly. Changing team or suffix
makes a new app with empty data.

Once per phone: pair by cable and Trust, turn on Developer Mode (Settings, Privacy & Security; appears after the
first pairing), and on a free account trust the developer on first launch (General, VPN & Device Management).
`--ios-device` refuses without a valid signing config, finds real iPhones only (Xcode 27's `devicectl` also lists
simulators), builds with `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`, then installs and launches
through `devicectl`.

### Release

- `./run.sh --ios-device --prod` and the release check build the helpers with Cargo's `release` profile
  (`DISPATCH_HELPER_PROFILE=release`); a plain `xcodebuild -configuration Release` uses the faster `local` one.
  Release strips the executable after making its dSYM. The bundle is about 35 MB, 20 MB of it the three helpers.
- `test/ios-release.py` (`--simulator`, `--helper-profile local`, `--skip-build`, `--no-launch`, `--with-fast-suite`)
  builds Release for simulator and device (unsigned), checks the helpers' architectures, `version` and
  `protocol-version`, Info.plist's device keys, the privacy manifest's form, and that every required-reason API the
  executable imports (`nm -u`, selectors) is declared in `Mobile/App/PrivacyInfo.xcprivacy`. It launches the simulator
  build and prints the size table. The fast suite cannot run against Release (`@testable`, Debug-only demos).
- Not applied yet: deduplicating licence texts (2.8 MB), shipping helpers compressed (halves them, needs a new hash
  rule), `-Osize` for app code (needs measuring). The Mac helper keeps x86_64: Intel Macs are hosts.

## Architecture and data flow

| Target | What |
| --- | --- |
| `DispatchMobile` | The app, bundle id `yachts.dispatch.mobile` + suffix, iOS 26.0. |
| `DispatchMobileTests` | Unit tests hosted by the app: `Mobile/Tests` plus the Mac's Foundation-only tests by path. |
| `DispatchMobileUITests` | XCUITests, own scheme so unit runs never start the app. |
| `TermMobile`, `TermAppleMobile` | `Vendor/Term` and `TermApple` for iOS, without `Launch`, `Pty`, `Frames`, `Session`, `TerminalView`. Fonts are `TermFonts`: a top-level `Resources` folder breaks an iOS bundle's signature. |
| `MobileTransport` | Local Swift package (`Mobile/Transport`, see its README) over the Rust engine. |

The iOS settings group sets `ARCHS = $(ARCHS_STANDARD)` (the project's native arch is the Mac's arm64e, which no
simulator matches). Zstd is not linked: `AppReplay` compiles for its types, but no journal ever starts.

### Shared sources

Mac sources the phone uses stay in `Dispatch/` and are listed by path in `project.yml` ("Shared with the Mac app").
They change only by `#if canImport(AppKit)` guards or additive, behaviour-preserving helpers.
`Mobile/Shared/System.swift` stands in for the Mac's AppKit-only `System`. Deferred to separate Mac PRs: a
`SystemProvider` seam replacing that file, and splitting `ChatSession` into shared transcript state and Mac view
state (until then `MobileTranscript` copies `ChatSession.turn`/`insert`). Mac views built on the Mac chat stack
(`ChatPermissionCard`, `SyntaxHighlight`, `AgentActivityGlyph`, …) are ported, not shared.

### Areas and seams

| Area | Directory | Owns |
| --- | --- | --- |
| Hosts | `Mobile/Hosts`, `Keys`, `Store` | Host, key and known-host stores, `HostSession(s)`, New host, host detail, trust sheet |
| Tabs | `Mobile/Tabs`, `Mobile/App` | Shell, New button, Spaces, space details, New space, `TabScreen` |
| Chat | `Mobile/Chat`, `Mobile/Agents` | `MobileChatSession`, Agents list, thread, approvals, queue, New chat |
| Terminal | `Mobile/Terminal` | `TerminalHostView`, `TerminalFeed`, `TerminalPresence`, key capsule |
| Transport | `Mobile/Transport` | SSH, auth, host-key delegate, exec channels, bootstrap, reconnect |
| Code | `Mobile/Code` | Diff viewer, code composer |
| Resilience, Settings | `Mobile/Resilience`, `Mobile/Settings` | Network watching, launch cache, background refresh, Settings |

- `HostSession` is the one object the UI observes per host. Other areas get a `HelperClient` and `HelperTopology`
  from it and never see SSH: only `Mobile/Transport/Integration` imports `MobileTransport`, and the package stays
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
- Limits: host certificates refused, user certificates not wired; no x86_64 simulator or Intel Mac slice;
  `panic = "abort"`; release-built even in Debug.

### Connection

`SSHHostSessionDriver` connects (host key through `KnownHostStore`), logs in, uploads the helper for the host's
`uname` to `~/.dispatch/bin/versions/<sha256>/`, starts it, greets it, reads `multiplexers.list` and
`backends.list`, waits up to 2 s for the first topology, then is ready. It pings with `echo` every 10 s.

- Lost link or helper: `reconnecting` at once (keepalive 15 s × 3), backoff 1 s up to 60 s, raced by `retryNow()`
  (network change, foregrounding; on a connected link it probes `echo` within 3 s and closes a dead one).
  Refusals (host key, login, missing key, protocol version) are final; after a host-key mismatch nothing retries
  until the user acts.
- Foreground connects every host, background disconnects.
- **Which multiplexer.** Connecting never starts a server. herdr's `backends.open` starts one, so herdr is followed
  only while its server runs (`running`) or the host asks for it; otherwise tmux, retried every 2 s. A preference
  change switches live without reconnecting.

## Helper contract

The phone runs, on an exec channel with no PTY and no `env` requests:

```sh
exec "$HOME/.dispatch/bin/versions/<sha256>/dispatch-helper" --remote --capabilities <HelperGrant> --stdio
```

The grant is the Mac's full profile with hooks (`HelperGrant`; Chat off drops `hooks.configure` and `agent.*`). The
phone-only hello features (`interaction.options`, `chat.list`, `projects.recent`, `multiplexers.versions`,
`terminals.coalesce`, `launch.names`, `stdio.liveness`) are specified in `helper/PROTOCOL.md`; what they let the helper
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
- **Re-enable integrations per connection.** `installation.install` state is in helper memory: Pi's extension needs
  it on each connection before a launch.
- **Surface native trust steps.** Codex shows "Hooks need review" after the helper installs hooks; until the user picks
  "Trust all" in its terminal, approvals stay in Codex's TUI.
- **Keep the outbox.** The helper's queue dies with the helper (only Codex's native queue survives). The device keeps
  every queued message until delivered and re-adds after reconnecting; anything possibly in flight at the drop is
  paused for the user, never sent twice.
- **Expect input refusals** right after an agent starts (`input`: nothing was typed); send once more shortly after.
- **Send raw bytes** (binary tag 11) in `terminals.input`.
- **Scrollback.** tmux replays pane history on every attach, so its scrollback is the client's
  (`scrollback_app_owned`); herdr's is the server's (`terminals.scroll`, `terminal.scroll`).

**Replays.** Every phone-only behaviour sits behind a hello feature the Mac never names, so the Mac's recorded
sessions replay unchanged. Keep it that way. Exceptions to re-record when they show up: close-tab captures made with
macOS `/bin/bash` 3.2 (idle helper-created windows now terminate), and launcher captures that recorded the herdr tty
race (replay sees a second ownership ask).

## Behaviour

- **Hosts and trust.** Trust on first use per host and port; a changed key is a hard stop with only Remove and retry.
  An unreadable `known_hosts.json` fails closed (Retry or Reset), never read as empty. New keys are ED25519 behind
  `biometryCurrentSet`, or Secure Enclave P-256. A host's colour is `HostTint` of the machine identity at creation, so
  it matches the Mac. A failed save stays in memory flagged unsaved, with a Retry notice in Spaces.
- **Spaces.** herdr workspaces and tmux sessions are spaces, windows and tabs are tabs. A split tmux window shows one
  pane; the phone never splits. The helper's native multiplexer never counts (its sessions die with the connection).
  Close follows the Mac's policy: `close.request` `check`, terminate only verified idle work, otherwise detach.
  Paths shorten to `~` by `hello.account.home` and `login_home` (longest match wins), never by guessing
  `/Users/<name>`.
- **Chat.** `chat.open` only for a bound terminal; the conversation is accepted once `chat.history` names the same
  process. Answers go on the subscription that delivered the request. Losing link or binding pauses input and keeps
  transcript and drafts. Dots follow Mail: blue for needs you or unseen, amber for working; a conversation's first
  sight is its baseline.
- **Terminal.** Output is coalesced (up to 256 KiB per parse) because tmux sends one notification per line. A
  reattach's first output repaints over the old screen so it never shows empty. The terminal stays `dispatch-black`
  in light mode.
- **Code.** The diff viewer reads current files with `files.text`. There is no Revert: the helper has no operation to
  reverse a patch.
- **Resilience.** `host-cache.json` (last hello, multiplexers, topology, Agents rows with ≤280-character previews) is
  read synchronously at launch so the first frame lists every host. Live data reconciles in place (same row objects).
  Cached files decode leniently, per entry.
- **Background refresh.** A `BGAppRefreshTask` (`<bundle id>.refresh`), off by default. It connects hosts with Chat
  on through a session that asks nothing, so Face ID key hosts are skipped (`interactionNotAllowed`), reads
  `chat.list`, notifies conversations that newly need the user, and ends within 25 s. It never touches seen markers.
- **Appearance.** Dark by default (`appearance` in UserDefaults), every colour with a light variant. Deliberate
  departures from the mockups: the light user bubble is `#BF3BBF` (the mockup's `#C94FC9` fails 4.5:1), and system
  menus and segmented controls replace custom ones.
  `NewTabGuard` refuses the New tab in UIKit's tab bar delegate, because refusing in SwiftUI's binding is too late (the
  empty tab shows for frames).

**Debug hooks** (compiled out of Release): `DISPATCH_MOBILE_STORE=memory` (nothing saved, no Face ID),
`DISPATCH_MOBILE_SCRIPTED=1|empty|trust|mismatch|nomux`, `DISPATCH_MOBILE_CHAT_DEMO=<screen>` (via `SIMCTL_CHILD_`),
`DISPATCH_MOBILE_CHAT_DEMO_LINK=cycle`, `DISPATCH_MOBILE_AUTHORIZE_KEYS`, `DISPATCH_MOBILE_HOST_ENV`, and launch
arguments `-DispatchTabsSample`, `-DispatchTabsShow`, `-DispatchTabsTree`, `-DispatchTabsFilter`,
`-DispatchTabsCollapse`, `-DispatchTabsScript` (one step every 1.5 s, for recordings). To force a background refresh,
pause in lldb and run:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"yachts.dispatch.mobile.refresh"]
```

## Testing

- **Suites.** `test/run.sh --platform ios` (`test/ios.py`) runs the fast suite on the simulator. Cases are classified
  in `test/suites.json` as `DispatchMobileTests/<Class>/<test>` and `DispatchMobileScripts/<Class>/<test>` (Python
  tests of the release tooling, `test/ios-release.test.py`, no build). A fast run fails on an unclassified case.
  New tests go in `Mobile/Tests/<Area>…Tests.swift`; after adding files, run `python3 scripts/generate-project.py`
  and commit `project.pbxproj`.
- **UI tests.** `xcodebuild -scheme DispatchMobileUITests -destination 'platform=iOS Simulator,name=iPhone 17'
  -derivedDataPath build test`, against the scripted hosts.
- **Live fixture.** Makes this Mac a host: a loopback sshd with private HOME and sockets, a private tmux server, and
  Claude Code from `build/test-tools` against a local Messages API. The simulator cannot start processes, so `serve`
  restarts sshd when a test asks.

  ```sh
  python3 scripts/mobile-live-fixture.py start /tmp/sim-int
  python3 scripts/mobile-live-fixture.py serve /tmp/sim-int &
  TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-int/live.json test/run.sh --platform ios SSHDriverLiveTests
  TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-int/live.json TEST_RUNNER_DISPATCH_LIVE_LINUX='{"name":…,"host":…,"port":…,"user":…,"key":…,"root":"/tmp/dt-int"}' \
    xcodebuild -scheme DispatchMobileUITests -destination 'platform=iOS Simulator,name=<device>' -derivedDataPath build \
    -collect-test-diagnostics never test -only-testing:DispatchMobileUITests/MobileLiveTests
  python3 scripts/mobile-live-fixture.py stop /tmp/sim-int
  ```

  The Linux entry is the Lima VM (`build/host-linux-ssh.json`, [vm_testing](vm_testing.md)).
- **Helper over stdio.** `python3 test/helper-stdio.py --live [--lima NAME | --remote user@host:port --identity KEY]
  [-k case] [--keep]` runs the helper exactly as the phone does, in a private root. Every tmux call uses `-S`, so it
  is safe inside the user's tmux. Not in `test/suites.json`, which holds XCTest ids only.
- **Transport.** `cargo test` in `Mobile/Transport/Core` and `swift test` in `Mobile/Transport`
  ([README](../Mobile/Transport/README.md)).
- **Frame checks.** No transient wrong state, frame by frame. `TransitionUITests` and `-DispatchTabsScript` drive
  recordings (`xcrun simctl io <device> recordVideo`); `scripts/transition-frames.swift` and
  `scripts/tab-bar-frames.swift` split and judge them.
- **Fidelity.** `FidelityUITests` pairs every mockup screen with the app's screenshot (`build/mockup-review`,
  `scripts/fidelity-pairs.swift`). `AppearanceUITests` runs the accessibility audit in both schemes; accepted reports
  are listed in the test.

## Device checklist

Release build on a real iPhone, by hand. Nothing below has been run on a device yet.

1. Launch opens Spaces' empty state.
2. ED25519 key: Face ID on first use; Cancel fails the login. Re-enrolling Face ID invalidates the key with a clear
   message, and so does a phone without Face ID.
3. Secure Enclave key: one Face ID prompt per signature.
4. Copy and Share public key give the exact `authorized_keys` line.
5. Local Network prompt on the first LAN host; Don't Allow fails LAN hosts only.
6. Lock or switch apps for a minute: sessions drop and reconnect within seconds; agents kept running.
7. Background refresh with a password host and a Face ID host both waiting: only the password host notifies.
8. Wi-Fi off while connected: reconnects over cellular in about 4 s.
9. A backup restored onto another phone brings no host, key or password.
10. Free account: after 7 days the app stops opening until reinstalled, with data intact.

## Known limitations

- mosh deferred past v1 (the copy still says "mosh" though the connection is SSH); push notifications (need a relay),
  iPad and App Store out of scope; iCloud never.
- The iOS 26 New-button fallback (`.search` tab role) is untested: only the iOS 27 runtime has been used.
- Rekeys are not re-checked against the trusted host key (russh 0.64.1 has no hook; [security](security.md#dispatch-for-iphone)).
- Keyboard-interactive is untested against a real multi-round server (OTP, PAM).
- The app's live runs cover tmux; herdr only through the helper harness and scripted tests. Linux is covered on one
  arm64 Ubuntu VM; x86-64, other distributions and a real remote Mac with Homebrew tmux are untested.
- A tab's time moves with topology changes only: `MobileWorkspace.noteActivity` has no caller yet.
- Codex offers no "This session" approval: Codex 0.162 rejects `updatedPermissions` in PermissionRequest hooks.
