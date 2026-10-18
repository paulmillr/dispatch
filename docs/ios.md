# Dispatch for iPhone

## Overview

Dispatch for iPhone is a thin client for the hosts you reach over SSH. The phone has no shell and starts no
processes; the Rust helper on each host does the work (tmux or herdr, agent transcripts, approvals, files, stats), and
the phone speaks the helper protocol (`helper/PROTOCOL.md`) over one in-process SSH connection per host. iOS 26 and
later, iPhone only, sideloaded (no App Store or TestFlight build). Sources live in `Mobile/`; the Mac app's Foundation
and SwiftUI sources are shared by path (Shared sources, below). Module boundaries between the areas are in
[ios-contracts.md](ios-contracts.md); the transport's spike is [ios-ssh-spike.md](ios-ssh-spike.md), the helper's
[ios-helper-spike.md](ios-helper-spike.md).

**What a host needs.** An SSH server you can log in to with a password, a key or keyboard-interactive, on macOS 14+
or Linux (arm64 or x86-64), and tmux 3.7+ or herdr 0.9.3+. Shells and agents run inside tmux windows or herdr tabs,
so they outlive the phone's connection; without either, Host detail says `none` and shows the install commands
([integrations](integrations.md#tmux-and-herdr)): the app installs nothing on a host but its helper. tmux before 3.7
works, with the Mac's warning that agent readiness cannot be verified (it has no bracketed-paste state). On Linux with
systemd-logind's `KillUserProcesses=yes`, servers started over SSH die at logout unless you run
`loginctl enable-linger $USER`. Agents are the Mac's: Claude Code, Codex, Pi and Nanocodex.

**What the helper does.** The app uploads the helper build it ships to `~/.dispatch/bin/versions/<sha256>/` and runs
it on a plain exec channel with one fixed grant; it reads tmux and herdr sessions, agent transcripts and the files they
show, host stats and identity, adds agent hooks so approvals reach the phone, and opens terminals and types into them
when you ask. It ends with the connection. The exact grant, features and limits are in
[security](security.md#dispatch-for-iphone).

## Building and running

### Simulator

Xcode 27 with the iOS 27 SDK and an iOS simulator runtime. The first build also builds the Rust helper, as the Mac
app's does; all three helper binaries (`darwin-universal`, `linux-aarch64`, `linux-x86_64`) and their `version`
files land in the app's `helper/` folder as plain resources, uploaded to hosts as needed.

```sh
./run.sh --ios                            # Debug build, run in the "iPhone 17" simulator
./run.sh --ios --simulator "iPhone 18 Pro"
./run.sh --ios --just-build
./run.sh --ios-device --prod              # Release, installed on the first paired iPhone (below)
./run.sh --ios-device "Paul's iPhone"     # a phone by name or UDID
test/run.sh --platform ios                # the fast suite on the simulator (Testing, below)
test/run.sh --platform ios --suite full
test/run.sh --platform ios SharedModelTests
python3 test/ios-release.py               # the release check (below)
```

`DISPATCH_IOS_SIMULATOR` changes the default simulator for all of them. When this Xcode has no Simulator.app the
simulator runs headless; `xcrun simctl io booted screenshot shot.png` shows it. The runners use the `DispatchMobile`
scheme directly too:

```sh
xcodebuild -scheme DispatchMobile -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build test
```

### A fresh checkout

A fresh checkout needs the pinned Rust with its iOS targets and the SSH engine's XCFramework before Xcode resolves the
`MobileTransport` package (SwiftPM reads the binary target before any build script runs). `./run.sh --ios` and
`test/run.sh --platform ios` prepare both through `scripts/setup_mobile.py`: `scripts/setup-ssh-rust.py`, then, when
`build/mobile-ssh/DispatchMobileSSHCore.xcframework` is missing, `scripts/build-mobile-ssh.py --fetch` (the one network
step: the locked crates into `build/cargo`). With `DISPATCH_SETUP_OFFLINE=1` nothing is downloaded and a missing piece
fails with the command to run online once. After that, builds, tests and the release check work offline: the package
has no remote dependency.

### Signing and a device

The iOS targets sign automatically. Their team comes from `build/signing.xcconfig` (git-ignored), which
`Mobile/Config/Signing.xcconfig` includes when it exists; simulator builds need none.

```
DEVELOPMENT_TEAM = ABCDE12345
// Optional: a free Apple ID cannot register yachts.dispatch.mobile if someone else has.
DISPATCH_BUNDLE_ID_SUFFIX = .yourname
```

The app needs no entitlement a free account lacks (Face ID, the Keychain, the Secure Enclave, background refresh and
the local network are Info.plist keys), so either kind of account works:

| | Free Apple ID (Personal Team) | Paid developer team |
| --- | --- | --- |
| Profile lifetime | 7 days: the app stops opening after that; re-sign weekly | 1 year |
| Apps | At most three such apps on a phone at once; 10 new App IDs a week | No such limit |
| Bundle id | Needs a `DISPATCH_BUNDLE_ID_SUFFIX` (the plain id is registered elsewhere) | Suffix optional |

Recipe, once per Mac and phone:

1. Xcode, Settings, Accounts: add your Apple ID. A free one gets a "Personal Team". `python3 scripts/ios-signing.py
   --teams` lists the team ids this Mac knows (Xcode's accounts and the Apple Development certificates in the
   keychain); Xcode's Accounts pane shows them too.
2. `python3 scripts/ios-signing.py ABCDE12345 --suffix .yourname` writes `build/signing.xcconfig` and checks it
   (ten-character team id; a suffix of `.component` parts). `--check` checks it again, `--check --xcode` also asks
   xcodebuild what it resolves (team, bundle id, automatic signing), `--remove` deletes it.
3. Connect the phone by cable, unlock it and tap Trust (pairing; later installs also work over the same network
   once Xcode's Devices window shows it as paired).
4. On the phone, Settings, Privacy & Security, Developer Mode: on, restart, confirm. The switch appears after the
   phone was first paired with Xcode.
5. `./run.sh --ios-device --prod` (or `--ios-device "Paul's iPhone"`). It refuses to start without a valid
   `build/signing.xcconfig`, finds the paired iPhone (`xcrun devicectl list devices --json-output -`, real iPhones only:
   Xcode 27's devicectl lists the simulators too), builds for that phone with `-allowProvisioningUpdates
   -allowProvisioningDeviceRegistration` (so Xcode makes the certificate and the profile and registers the phone with
   the team), then `xcrun devicectl device install app` and `xcrun devicectl device process launch
   --terminate-existing`. Without `--prod` it installs the Debug build (bigger and slower, but debuggable).
6. First launch on a free account: Settings, General, VPN & Device Management, trust the developer.

Re-signing: a free account's profile expires after 7 days; run step 5 again before then (the app's data stays, the
build is replaced in place). A paid team re-signs yearly the same way. Changing the team or the suffix makes a new
app with empty data: hosts, keys and trusted host keys do not carry over (they live in that app's container and
Keychain).

What was verified without a phone (2026-10-18, Xcode 27.0, devicectl 642.16): the Release device build compiles
unsigned (`xcodebuild -scheme DispatchMobile -configuration Release -destination 'generic/platform=iOS'
CODE_SIGNING_ALLOWED=NO -derivedDataPath build/dd build`, 2 min from cold Swift, 39 s with the helpers cached); the
`devicectl` commands and options in `scripts/run.py` match `xcrun devicectl --help`; with a fake team in
`build/signing.xcconfig` the bundle id becomes `yachts.dispatch.mobile.<suffix>` (and the background task
`<bundle id>.refresh`), an unsigned build succeeds, and a signed build fails only at signing: "No profiles for
'yachts.dispatch.mobile.release-check' were found … pass -allowProvisioningUpdates" without the flag, "No Accounts"
with it. Installing, launching and every item of the Device checklist (below) still need a phone.

### Release builds and app size

Release is the build to keep on a phone: `./run.sh --ios-device --prod` builds the helpers with the `release` Cargo
profile (fat LTO, opt-level "s"; `DISPATCH_HELPER_PROFILE=release`) and the app stripped. A plain `xcodebuild
-configuration Release` builds the helpers with the faster `local` profile instead.

Measured on the Release device build (arm64, 2026-10-18; `test/ios-release.py` prints the same table), the dSYM
(192 KB) beside the app, not in it:

| Part | Before | Now |
| --- | ---: | ---: |
| Bundle total | 54.69 MB | 34.95 MB |
| Helpers (three binaries, uploaded to hosts) | 29.75 MB | 19.64 MB |
| `helper/darwin-universal` (arm64 and x86_64: Intel Macs are hosts) | 14.14 MB | 9.35 MB |
| `helper/linux-aarch64` | 6.79 MB | 4.66 MB |
| `helper/linux-x86_64` | 8.82 MB | 5.62 MB |
| Executable (`DispatchMobile`) | 18.78 MB | 9.15 MB |
| of which app code (`Mobile/` and shared `Dispatch/`) | 4.53 MB | 4.53 MB |
| of which the SSH engine (Rust: russh, ring, tokio), after dead-stripping | 2.38 MB | 2.38 MB |
| of which Term, TermApple, MobileTransport, linker stubs | 1.74 MB | 1.74 MB |
| Terminal fonts (`TermFonts`: Symbols Nerd Font 2.44 MB, JetBrains Mono 0.61 MB) | 3.06 MB | 3.06 MB |
| Licences (`ThirdPartyLicenses`) | 3.06 MB | 3.06 MB |
| The rest (assets, themes, plists, icons) | 0.04 MB | 0.04 MB |

"Before" is the plain Release build (`local` helpers, unstripped executable); the executable's code rows are the live
symbols of the link map (`LD_GENERATE_MAP_FILE`), so they are the same in both and add up to slightly less than the
executable. Zipped (`zip -9`), the stripped bundle is 15.4 MB. Applied, neither changes behaviour:

- The Release executable is stripped once its dSYM is made (`DEPLOYMENT_POSTPROCESSING` and `STRIP_INSTALLED_PRODUCT`
  for `DispatchMobile`'s Release only): 18.78 to 9.15 MB, about 3 060 symbols left (what dyld needs). The iPhone tests never
  run against Release (they import the app `@testable` and use the Debug demos), so nothing needs the symbols.
- The release check and the README build the helpers with the `release` profile (as `./run.sh --prod` already did):
  29.75 to 19.64 MB, which also shortens the first connection's upload.

Already in place: `DEAD_CODE_STRIPPING` (YES), whole-module `-O`, `ARCHS = arm64` (no other slice), and the SSH engine's
own profile (thin LTO, one codegen unit, `panic = "abort"`, no debug info). Proposed, not applied:

- Licences: `RustSSHHelper/COPYRIGHT-library.html` (1.51 MB, the Rust standard library's attribution) and
  `MobileTransport/Dependencies.txt` (1.29 MB, one licence text per crate, written by
  `scripts/mobile-transport-licenses.py`) could deduplicate identical licence texts the way `RustSSHHelper/licenses/`
  does; most of their 2.8 MB is repeated text.
- The helpers could ship compressed and be unpacked before upload (`gzip -9`: 19.64 to 9.72 MB), at the cost of an
  unpack step and a new hash rule; the `version` file hashes the uncompressed binaries the hosts run.
- `-Osize` for the app's Swift code (the terminal stays `-O`) would cut some of the 4.5 MB of app code, but changes
  performance, so it needs measuring first.
- The x86_64 slice of the Mac helper stays: Intel Macs are hosts.

### Release check

`python3 test/ios-release.py --simulator dispatch-release` (2 min 15 s to 2 min 21 s here with the Swift and Rust
caches warm, offline after setup) builds Release for
the simulator and for devices (unsigned, with a link map) into `build/dd` with the `release` helpers
(`--helper-profile local` for the faster ones), then:

- checks both bundles: the three helpers with their architectures (the Mac one must hold arm64 and x86_64, the Linux
  ones must be ELF for aarch64 and x86-64), `version` (the hash of the three, equal to `build/helper-rust/bin/version`)
  and `protocol-version` (`HelperBinary.version`); Info.plist's device keys (`NSFaceIDUsageDescription`,
  `NSLocalNetworkUsageDescription`, the `fetch` background mode and `<bundle id>.refresh`); the bundled privacy
  manifest is the source's;
- checks the privacy manifest's form (no tracking, nothing collected, known categories with reasons that exist for
  them) and that every required-reason API the device executable imports (`nm -u`, Objective-C selectors) is declared;
- launches the Release simulator build, which must still run five seconds later (screenshot in
  `build/release-check/launch.png`);
- prints the size table above.

The fast suite cannot run against Release: the tests import the app `@testable` (Release has no testability) and use
the Debug-only demos (`ChatDemo`, `CodeDemo`, `TabsSample`). `--with-fast-suite` runs it in Debug on the same simulator
afterwards; `--skip-build` checks the existing builds, `--no-launch` skips the launch.

### Privacy manifest

`Mobile/App/PrivacyInfo.xcprivacy`: no tracking, no tracking domains, no collected data types (nothing leaves the
phone but the SSH connections you make), and the required-reason APIs the executable uses:

| Category | Reason | Why |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` (the app's own defaults) | Settings: appearance, font sizes, background refresh, Spaces' sort and filter |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` (files in the app's container) | `stat` and `fstat` (the terminal's theme files in the bundle: type and size) and the private files' permissions in Application Support |

System boot time (`systemUptime`, which shared Mac chat code reads), disk space and active keyboards are not in the
executable; the release check fails if one appears without a declaration.

`THIRD_PARTY_NOTICES.md` lists the SSH engine's crates ("iPhone SSH transport"); their texts are bundled in
`ThirdPartyLicenses/MobileTransport`.

### Targets

| Target | What |
| --- | --- |
| `DispatchMobile` | The app: bundle id `yachts.dispatch.mobile` (plus `DISPATCH_BUNDLE_ID_SUFFIX`), module `DispatchMobile`, iOS 26.0, iPhone only, dark by default (the `appearance` default, Appearance and accessibility below), tint `#e07be0`. |
| `DispatchMobileTests` | Unit tests hosted by the app: `Mobile/Tests` plus the Mac's Foundation-only test files by path. |
| `DispatchMobileUITests` | XCUITests that tap the app (its own scheme, Testing below). |
| `TermMobile`, `TermAppleMobile` | `Vendor/Term` and `TermApple` built for iOS (static, module names `Term` and `TermApple`). TermApple leaves out `Launch`, `Pty`, `Frames`, `Session` and `TerminalView` (processes, the pty, the AppKit view and its display link); the CoreText shaper, font collection, raster and Metal renderer compile unchanged. iOS-only additions: `Term/SurfaceTouch.swift` (touch selection, scroll queries) and the `TermFonts` font folder. |

The iOS targets share the `ios` settings group (`ARCHS = $(ARCHS_STANDARD)`: the project's `$(NATIVE_ARCH_ACTUAL)`
is the Mac's arm64e, which matches no simulator). `SSHHelpers` lists the iOS platforms so it can build in an iOS
scheme; it still builds the macOS and Linux helpers only. The SSH engine (`Mobile/Transport/Core`, russh behind a C
ABI) is the `MobileTransport` Swift package's binary target, built by `scripts/build-mobile-ssh.py` (the app's "Build
SSH engine" phase) into `build/mobile-ssh`.

Zstd is not linked on iOS. `AppReplay` (the Mac's Debug capture and replay journal) is compiled because the helper
transport's signatures name its ticket type, but on iOS no journal is ever begun and its compression paths are
compiled out (`SWIFT_INCLUDE_PATHS` is empty for the app and its unit tests, so `canImport(CZstd)` is false).

Assets (`Mobile/App/Assets.xcassets`): `AccentColor` `#e07be0`; state dots `StateUnread` `#0a84ff`, `StateWorking`
`#d9b36a`, `StateFinished` `#7fd3a1` (the same in both appearances, as are `OnAccent`, `LensOnTint` and `TerminalKey`);
every other colour the views draw has a light and a dark variant (Appearance and accessibility, below);
`LaunchBackground`; a placeholder `AppIcon`; `NewHost` (the mockup's display with a plus, which no SF Symbol draws);
copies of the Mac's `HostDebian` and `HostFreeBSD` glyphs for `HostGlyph`.

### Shared sources

The shared files stay in `Dispatch/` and are listed by path in `project.yml` (`DispatchMobile`, "Shared with the
Mac app"). Their Mac-only parts sit behind `#if canImport(AppKit)`; `Mobile/Shared/System.swift` stands in for the
Mac's AppKit-only `System` (ids, time, folders; no journal) and `Home` until the `SystemProvider` seam lands.

| Shared | Guarded on iOS |
| --- | --- |
| `Helper/HelperWire`, `HelperBinary`, `HelperConnection`, `HelperClient`, `HelperTopology`, `HelperDescriptors`, `HelperTransport`, `HelperBackend`, `AppReplay` | `AppReplay.Launch(Process)` |
| `Helper/HelperSession` | Everything but `HelperSession.Info` (the `hello` record): the session object spawns a local helper, and `HelperApp` lends local and SSH helpers by Mac workspace endpoint. |
| `Chat/ChatModels` | `ChatSession` (the Mac's per-surface session with its view state), `ChatQueuedMessage.process` and `matches(_:)` |
| `Chat/HelperChat` | The live chat client (`route` on) and `setup`: they reach helpers through `HelperApp` endpoints. The Codable records, pages, state, interactions and transcripts are shared. |
| `Chat/ChatCommands`, `ChatSideConversation` | The `ChatCoordinator` extensions; `ChatSideConversation` itself (it runs on the live client). `ChatSidePermission`, `ChatAgentSettings`, `ChatGoal`, `ChatCommandResult` are shared. |
| `Chat/ChatModelChoicesCache` | `prepare(for: ChatSession)` and the scope's local process; the phone scopes by agent, conversation and version (`prepare(agent:conversation:version:)`) |
| `Chat/ToolDocument` | `source(in:endpoint:)` |
| `Chat/ToolPresentationCache` | `ChatToolLayoutCache` (the Mac's chat typography) |
| `Chat/ChatPatch`, `ToolOutput`, `ToolPresentation`, `ToolOrchestration`, `ToolCommandWords`, `ToolReadCommand`, `ToolCommandPresentation`, `ClaudeQuestions`, `ChatSideQuestion`, `ChatDrafts`, `ChatOperations`, `AgentModelMenu`, `Views/ComposerFences` | Nothing |
| `WorkspaceModels` | `LayoutPreset.shortcut(keyCode:)`, `Space.tabShortcut(for:)` (Mac keyboard menus) |
| `Hosts/HostRegistry` | `HostID.login`, the Mac's `HostRecord` and the `HostRegistry` store (Mac SSH scopes); `HostID`, `HostSystem`, `HostConnectionState` are shared. The phone has its own `HostRecord` (`Mobile/Store`), which answers `system` the same way, so `HostGlyph` draws both. |
| `Hosts/TerminalHistoryStore` | `TerminalHistoryStore`; `PrivateFile` is shared |
| `SSH/SSHInvocation` | `SSHInvocation` and `SSHMaster`; `SSHConnectionID` is shared |
| `Terminal/TerminalMachine` | The commands that run the Mac's `ssh` launcher |
| `Terminal/ProgramStatusStore`, `TerminalScrollState`, `Herdr/HerdrModels` | Nothing |
| `Attention` | All but `PaneUrgency`; its precedence is `init(waiting:working:unread:)`, shared, and the Mac's `init(session:programs:)` uses it. |
| `Views/HostTint` | The tab strip modifiers (`hostTintStrip`, `hostTintBorder`, the remote-tab highlight) |
| `Views/HostGlyph` | `HostRecord.tint` (the Mac record's) and everything after `HostGlyph`: the host popovers and the AppKit secondary click |
| `Views/Chrome` | The terminal colour overrides (`NSColor`), `SidebarThemeStore.systemIsDark` (`NSApp`), `sidebarSlotWidth` |

Left out, with the reason:

| File | Why |
| --- | --- |
| `Helper/System.swift` | AppKit gated as a whole (journal, processes, the checkout); replaced by `Mobile/Shared/System.swift`. |
| `Helper/HelperWorkspace.swift`, `HelperTerminal.swift` | The Mac's workspace and renderer plumbing (`AppDelegate`, `TerminalRuntime`, `SSHReconnectController`, the renderer pty). |
| `Views/AgentActivityGlyph.swift` | The Mac sidebar's glyph, read from `TerminalRuntime` and drawn with `Chrome`/`AppFont`/`InterfaceMotion`; the phone's thinking animation is a separate SwiftUI port (`ChatWorkingRow`). |
| `Views/ChatPermissionCard`, `ChatQuestionForm`, `ChatReplyControls`, `ChatModelControls` | Built on the Mac chat view stack (`ChatToolCard`, `ChatRadioLog`, `InterfaceMotion`, `AppFont`, `LiquidGlassStore`, `ChatCoordinator`, `ChatSession`). |
| `Views/SyntaxHighlight.swift` | Needs `ChatTheme` (Settings `Preferences`, `TerminalRuntime`, `AppFont`) and `ChatMarkdown`; the phone's `CodeSyntax` ports its rules (Code, below). |
| `Chat/CodexProcess.swift` (`AgentProcess`) | Inspects local processes (`proc_pidinfo`); the phone has none. |
| Everything else in `Dispatch/` | AppKit, local processes, the Mac's SSH transport or its window and chat views. |

Deferred refactors (separate Mac PRs, after `files` merges): the `SystemProvider` seam replacing
`Mobile/Shared/System.swift`, and the `ChatSession` split into shared transcript state and Mac view state.

## Architecture and data flow

How the areas meet in the app (plan 3.1, 3.2; contracts in [ios-contracts.md](ios-contracts.md)).

- **Connection** (`Mobile/Transport/Integration`, app code; the package stays platform-neutral). `SSHHostSessionDriver`
  runs one `HostConnection` per host: `SSHHostSession.establish` connects (the host key goes to
  `HostSessionContext.verifyHostKey`: `KnownHostStore`, the trust sheet on first use, the hard stop on a mismatch),
  logs in with the host's key (Keychain ED25519 and Secure Enclave P-256 sign in Swift through the engine's signer,
  imported files go to the engine's parser; the key is read once per foreground run) or password, then
  keyboard-interactive through a plain Hosts sheet (`HostLoginPromptSheet`), installs the bundled helper for the
  host's `uname` (`darwin-universal`, `linux-aarch64`, `linux-x86_64`) under `~/.dispatch/bin/versions/<sha256>`, and
  starts it on an exec channel. The driver greets it (`hello` with `interaction.options`, `chat.list`,
  `projects.recent`, `multiplexers.versions`, `terminals.coalesce`, `launch.names`, `stdio.liveness`; the accepted list
  is `HelperSession.Info.features`), checks the schema and limits, reads `multiplexers.list` (with versions) and
  `backends.list`, waits up to 2 s for the first topology so a connected host never shows without its spaces, then
  reports `.ready`. While connected it follows one backend's topology (`backends.open`) and pings with `echo` every
  10 s (the latency the rows show, and the traffic `stdio.liveness` needs: the helper ends after 45 s without a frame).
  A lost SSH connection or helper is `reconnecting` at once (keepalive 15 s × 3 for silent losses); the policy's
  backoff (1 s, 2 s, … up to 60 s) races `HostSession.retryNow()` (a pause's timer is cancelled with it); refusals (host
  key, login, missing key, protocol version) are final, and after a host key mismatch neither a network change nor
  foregrounding starts another handshake until the user acts (Remove and retry, an edit). A disconnect while the driver
  waits for the first topology ends that wait at once. The hello's accepted `features` are kept in the cache with it. Every mapping of connection states (transport, `HostLink`, `SpacesHostState`) is in
  `HostLinkMapping.swift`.
- **Which multiplexer.** Connecting never starts a server: herdr's `backends.open` starts a herdr server and a first
  workspace when none runs, so herdr is followed only while its server runs (the `running` field of `multiplexers.list`
  rows, re-read each round; helpers without it: a process named herdr in `stats.processes`) or the host's record
  asks for it; otherwise tmux (whose open just fails without a server; the driver retries every 2 s, so a server New
  space starts shows up). The followed name is `HostSession.following`; New space goes to the same one. Changing the
  preference in host detail or Settings saves the record and the running driver follows the new choice on the same
  connection (`HostSessionContext.preferences`, `MultiplexerFollower`): the old subscription is cancelled, the new
  backend opened, `following` changes; the old multiplexer's spaces leave and Spaces detects where New space goes
  again. No reconnect.
- **Areas** (`Mobile/App/MobileComposition.swift`). Every change of a host or its session (`HostSessions.changed`, same
  main-actor turn) hands the host to Spaces (`MobileTabs.sync`: `TabsHost` with name, tint, the hello's system and
  account home, state, order; client; topology; the followed multiplexer; features) and Agents
  (`ChatConversations.update`). Chat's urgency, status line and needs-you count flow back into the Spaces rows and the
  back pill. A tab's Terminal segment opens the node's `TerminalPresence` (`TerminalPresences.shared`, a
  `HelperTerminalFeed` on the host's client, tmux scrollback client-side, herdr server-side) with the subtitle from
  `TerminalSubtitle`; its Chat segment is `ChatThreadView` over `conversations.session(for:)`, whose terminal side is
  the same presence (`TerminalChatPresence`). A presence is attached only while used: the Terminal segment while on
  screen, a conversation while its chat needs the screen published; the last release detaches it and keeps its last
  screen, which shows at once when the segment comes back. A client that goes away stops the host's presences; the next
  connection re-enables Pi's integration (when installed), and its first live topology reattaches the presences in
  use by topology key.
- **Navigation.** One `NavigationStack` around the tab bar (`SpacesNavigator`'s path): Spaces and Agents push the same
  screens, Agents and New chat open a conversation's tab on Chat, host detail's Spaces rows open the space, New
  chat's "New space…" opens New space once its sheet is gone. Pushed screens cover the tab bar as UIKit pushes do;
  the sections' titles and toolbars are the stack's.
- **Identity.** Terminal, tab, space and backend ids change with every helper connection; everything the phone keeps
  (rows, seen markers, drafts, the cache, activity) is keyed by host and topology `key`. A snapshot from the cache or the
  previous helper stays listed after a reconnect but is not live (`HostSession.topologyIsLive`) until the connection's
  first own topology: its rows are stale, tab commands refuse ("still loading"), Agents gets no client and the
  presences reattach only on the live snapshot, while New space (`backends.create`) can use the client at once. A
  connection whose followed multiplexer has no server (`HostSessionEvent.noBackend`: none chosen, herdr not running,
  tmux's open failing) clears the kept spaces instead of showing them forever; it also ends the first-topology wait
  early.

## Hosts and trust

Everything stays on the phone: no iCloud, and the app's files are out of device backups.

- **Hosts** (`Mobile/Store`): `hosts.json` and `known_hosts.json` in Application Support, written whole through
  `PrivateFile` (owner-only, atomic). A host is name, address, port, user, password or key, multiplexer preference
  (Automatic: herdr when installed, else tmux), Chat on or off, order, last connection, and the OS the helper last
  reported. Its colour is `HostTint` of the machine identity the helper gave when New host verified it (the Mac colours
  the same machine the same way), fixed once saved. A save that fails (`hosts.json`, `keys.json`,
  `known_hosts.json`) keeps the change in memory, flagged unsaved (`unsaved`, `saveError`), and Spaces shows a
  non-modal notice at its foot naming what is not saved, with Retry (`SpacesNotice`), until a save succeeds.
- **Sessions** (`Mobile/Hosts`): one `HostSession` per host ([ios-contracts.md](ios-contracts.md)). A
  `HostSessionDriver` connects it: the app's is `SSHHostSessionDriver` (Architecture, above). The app connects every
  host in the foreground and disconnects in the background. The helper runs with one grant (`HelperGrant`: the Mac's
  full profile with hooks), which the New host sheet states in words; a test fails when a capability has no
  disclosure there. A host with Chat off (Settings) runs it without hooks and agent capabilities.
- **Host keys**: trust on first use. The first connection to a host and port shows the algorithm and SHA256
  fingerprint (Trust or Cancel); a trusted key is kept per host and port, as OpenSSH names them. A different key or
  algorithm later is a hard stop: the sheet shows both fingerprints and offers only Remove and retry, which forgets
  the old key and asks again. Removing a host forgets its key unless another host uses the same address and port.
  An unreadable or other-version `known_hosts.json` fails closed: it is not read as empty (which would make every
  host a first-use question) nor moved aside; no host connects ("Known hosts unreadable: Reset or Retry") and Spaces
  shows a notice with Retry (read it again, e.g. after the first unlock) and Reset (after a confirmation: set the
  file aside, start empty, every host asks about its key again).
- **Keys** (`Mobile/Keys`): `keys.json` holds names, types, `authorized_keys` lines and fingerprints; private halves
  are in the Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synchronized. New keys are ED25519
  (CryptoKit) behind a `biometryCurrentSet` access control, so Face ID unlocks each use (Info.plist
  `NSFaceIDUsageDescription`: "Dispatch uses Face ID to unlock your SSH keys."); Secure Enclave P-256 keys (offered as
  `ecdsa-sha2-nistp256`) are made in the enclave with the same flag and never leave it. Passwords and passphrases are
  Keychain items without biometry. Import key reads OpenSSH files from Files or pasted text through
  `OpenSSHPrivateKeyParsing`; the built-in parser keeps unencrypted ED25519 keys as seeds and stores every other
  `openssh-key-v1` file (RSA, ECDSA, encrypted) with its passphrase for the transport's parser, which also checks
  the passphrase (the built-in one cannot: no bcrypt-pbkdf). PEM and PKCS#8 files wait for that parser.
- **Screens**: New host (M8a) connects once to verify, asking about the host key inside the sheet, and saves only when
  connected; its connection becomes the host's session. Host detail (M1f) is pushed from Spaces with Tabs' rows for its
  Spaces section. Spaces drives hosts through `SpacesHostActions` (removal with its question, reordering) and embeds M1f
  and M8a through `SpacesHostViews`; `HostSessions` implements the actions and makes both screens
  (`Mobile/Hosts/HostSessions+Spaces.swift`). The status line says "mosh" as the mockup does (the plan keeps the word
  until a mosh client is decided); the connection is SSH.
- **No tmux or herdr**: Host detail says `none` and leads to the install commands ([integrations](integrations.md));
  the app installs nothing but its helper.

## Spaces

`Mobile/Tabs` is the Spaces tab (M1d, M1e, M2a, M2b, M2c, M4d, M7a) and the per-tab screen Chat and Terminal share;
the shell (`Mobile/App`: `MobileRoot`, the New button, `MobileRow`) belongs to the same area.

- **Model.** `MobileWorkspace` (one per host, `@MainActor @Observable`) is built from the helper's `HelperTopology`
  snapshots: herdr workspaces and tmux sessions are spaces, their tabs and windows are tabs, a tab's panes are its
  terminals in layout order. A split tmux window shows one pane: the one picked in the subtitle's pane switcher while
  it exists, else the window's focused pane; the phone never creates splits. Rows are keyed by host and topology
  `key`: a snapshot merges into the objects already shown (an unchanged node is not even written), and after a
  reconnect the snapshot naming the same nodes under a new backend id replaces the old one. Detached nodes are left
  out. `MobileTabs` holds every host's workspace in the host store's order, the sort and filter (Activity, Name, Host;
  All, Chats, Terminals, Needs you), the tree toggle, collapsed host sections and the phone's order of each host's
  spaces, and what other areas inject: per-terminal `TabUrgency` (needs you, working, unseen; `PaneUrgency`'s
  precedence; rows draw needs you and unseen as Mail's blue unread, working amber) and a chat row's status line.
  `sync(_:)` (`TabsHostInput`: host, client, topology, multiplexer override, accepted hello features) is the
  integration point for the host sessions.
- **Hosts in Spaces.** The host list is injected (`TabsHost`: id, name, tint, glyph system, home, connection state,
  order) and edited through `SpacesHostActions` (remove after the Spaces tab's confirmation, reorder), with Hosts'
  New host (M8a) and host detail (M1f) injected as `SpacesHostViews`; the app's actions are `HostSessions`
  (`FakeSpacesHostActions` serves previews and tests). A space's count in the tree is its tabs that need you or hold
  an unseen result (Mail's unread count); a collapsed section shows the sum. Removing a host takes it off the phone;
  nothing running on it stops.
- **Activity.** The last change the phone saw per pane (a name, directory or agent binding changing, a new pane) is
  kept in `Application Support/Dispatch/tab-activity.json` by host and pane key, at most 400 panes per host and 60
  days. A pane in the first snapshot of a host has no time until something changes. `MobileWorkspace.noteActivity`
  takes activity the topology does not show (output, an agent's state), but nothing calls it yet (Known limitations).
- **Multiplexer.** `multiplexers.list` and `backends.list` after connecting; herdr is preferred over tmux, a host's
  override wins when that multiplexer is there, the helper's native multiplexer never counts (its sessions die with
  the connection). With the `multiplexers.versions` hello feature a multiplexer the helper says is not installed does
  not count, the choice carries its version, and tmux without bracketed-paste state (before 3.7) gets the Mac's
  warning, shown in New space.
- **Commands.** New space: `backends.create` (starts the tmux or herdr server when none runs), `terminals.create`
  under the backend in the chosen directory, then `entities.rename` once the topology shows it; when tmux refuses
  (several sessions attached) a window in one of its spaces is placed into a new named space with
  `memberships.place`. New tab: `terminals.create` under the space in its directory. Rename: `entities.rename`. New
  space lists the host's recent project folders from `projects.recent` when the hello accepted that feature (fetched
  when the host connects, so they are there when the sheet opens), else Home and Other folder… only.
- **Close policy (the Mac's).** Close Tab and Close Space first ask `close.request` with `check` (nothing changes):
  when every pane is verified idle the tab closes with `prompt` (the server re-verifies and detaches what turned busy)
  and the space with `terminate`; when anything runs, or the check is unavailable, it detaches and the work keeps
  running. Detach detaches; Terminate… asks with the Mac's words ("Terminate tab “dev”?", "This ends its server
  windows or panes and the processes running inside them. To keep work running, use Detach.") and terminates. A
  closing row leaves the list at once and comes back if the helper refuses. A detached tab is gone from this
  connection only: the next connection lists it again.
- **Paths.** One rule (`HomePath`) shortens paths to "~" in Spaces, host detail, the tab and Terminal subtitles and
  Chat's intro: the helper's `hello.account.home` and, when the helper reports it, the login environment's HOME
  (`hello.account.login_home`, sent to clients that name features when it differs from the account's home); the longer
  match wins, `/private/tmp` matches `/tmp`, and nothing is guessed from `/Users/<name>`. A typed "~" expands to the
  login HOME, else the account's.
- **Screens.** Mail's header (the tree toggle and sort/filter menu in one glass capsule, tinted while a filter is
  active; Edit / Done; the large title below), the flat list, the tree with host sections, edit mode, a space's tabs
  with the floating New tab (long press: the space picker), space details, New space. New in the tab bar opens a
  terminal tab in the most recent space (the last opened, else the most active), the space picker when there is none,
  and New host while no host exists (its glyph is then a display with a plus). Pushed screens put their header (back
  pill, title and subtitle, host pill) in the navigation bar: a hidden bar made the screen underneath jump for a frame
  at every push. `TabScreen` hosts the injected Terminal and Chat views (`TabsContent`), Chat by default when the tab
  runs an agent. Debug launches take `-DispatchTabsSample YES` (the mockup's hosts), `-DispatchTabsShow
  space:<key>|details:<key>|tab:<key>|new-space|pick|edit`, `-DispatchTabsTree YES`, `-DispatchTabsFilter <filter>`,
  `-DispatchTabsCollapse <host>` and `-DispatchTabsScript "tree,edit,done,space:<key>,pop,…"` (one step every 1.5 s,
  for screen recordings checked frame by frame).

## Agents and Chat

`MobileChatSession` (`Mobile/Chat`) is one agent conversation: a terminal whose topology node carries an agent
binding, identified on the device by host and topology key. It opens `chat.open` only for a bound terminal and accepts
the conversation once the helper's `chat.history` names the same process; then it pages (`chat.page`), merges records
into turns with the Mac's rules (`MobileTranscript`, a copy of `ChatSession.turn`/`insert` until the `ChatSession`
split lands; `ChatItem.continues`/`merged` expose the shared merge), sends (`chat.send`, prompt or steer; one more
send after an `input` refusal, which typed nothing), stops, answers approvals and question forms on the subscription
that delivered them (the options, including Claude's "This session", come from the helper: `interaction.options`),
reads models and efforts (`chat.models`, `chat.settings`, `chat.settings.set`) and a step's full output
(`chat.tools`). Chat input needs the terminal's screen published, so a verified conversation retains its terminal
through `ChatTerminalPresence` (the Terminal area's `TerminalPresences`); until a screen is published, messages
queue. Losing the link or the binding pauses input and retires open requests; the transcript and the drafts
(`ChatDraftRepository` in `Dispatch/Chat/ChatDrafts.swift`, keyed by host, agent and conversation) stay.

Queue and outbox: every queued message lives on the device (`ChatOutbox`, `chat-queue.json`, private) until it is
delivered: typed while working it is mirrored into the helper's queue (`queue.add`); typed while the link is down it
waits (M4c) and goes in once the same conversation is verified again (`queue.hold` around a batch for the core-held
queue). The helper's queue dies with the helper (only Codex keeps its own), so after a reconnect the device re-adds
what the new helper lacks. A message is never sent twice: one the old helper may have been sending when the link
dropped (the head of its queue, unless the same turn is still running) and any add or send whose reply was lost are
paused for the user, who sends or discards them. A message the transcript already shows as sent is dropped.

Attention: `ChatConversations` (`Mobile/Agents`) lists conversations across hosts from topology bindings, with one
`chat.list` per host when the hello accepted that feature and `chat.state` plus the newest page per conversation
otherwise. `PaneUrgency` per conversation comes from its state, open requests and `ChatMarkers` (private
`chat-markers.json`: per conversation the time of the newest record shown, and mutes by host and topology key). The
first sight of a conversation is its baseline, so only results that arrive later count as unread. Dots follow Mail:
waiting and unread are blue `.unread`, running is amber `.working`; a muted conversation keeps only the dot of an agent
blocked on the user. `needsYouCount` is the back pill's number; `dot(host:terminal:)` and `dot(host:)` feed Spaces.
`ChatModelMemory` keeps the last agent, model and effort and the menus seen, for New chat's defaults.

Debug builds show each mockup state of the thread through the real session and a scripted helper peer:
`SIMCTL_CHILD_DISPATCH_MOBILE_CHAT_DEMO=M5a xcrun simctl launch <device> yachts.dispatch.mobile` (M3a, M3b, M4a,
M4b, M4c, M5a, M5b, M5c, M5f, M9a); the transcript is the recorded fixture in `Mobile/Tests/Fixtures/Chat`
(`test/mobile-chat-fixtures.py` records it from the real helper).

## Terminal

`Mobile/Terminal` shows a host's tmux or herdr terminal with the Mac's engine (`Vendor/Term`, docs/architecture.md):
the same Ghostty-syntax config (`TerminalConfiguration`: `dispatch-black` by default, the contrast shader's
`minimum-contrast`, JetBrains Mono at 12 points, 14/10 point padding as in M6a) and the same Metal renderer.

- **Feed.** `TerminalFeed` is the seam: `attach(size)` returns the attachment's events (output, history position,
  exit), and `send`, `resize`, `scroll`, `publish` go out in order. `HelperTerminalFeed(client:terminal:)` speaks
  `terminals.attach/input/resize/scroll/publish`, one call at a time (input made meanwhile is one batch, resizes and
  publications collapse to the latest; nothing is retried). `ScriptedTerminalFeed` plays fixtures
  (`TerminalFixtures`: M6a, `vim`- and `htop`-like screens, vttest-style checks, a large file) with an optional
  line-editor echo and pacing.
- **Presence.** `TerminalPresence` keeps a node attached and parsed whether or not a view shows it while something
  uses it (`TerminalPresences.retain`/`release`: the Terminal segment on screen, a chat that needs the screen),
  because the helper verifies chat input against the screen a client publishes (`terminals.publish`, at most 30 a
  second). Unused, it is detached but keeps its last screen.
  Output is coalesced: events append to an inbox and a parse task feeds everything waiting (up to 256 KiB) in one
  batch, so tmux's one-notification-per-line output costs one parse per batch. `TerminalPresences` shares one per
  host and topology key between the Terminal segment and Chat; a reconnect's new node id reattaches it
  (`reattach`) when in use; the new attachment's first output clears the old screen and repaints it, so it never
  shows empty in between.
- **Host.** `TerminalSession` is the Mac's `Session` without the pty: frames on a render thread paced by a
  `CADisplayLink` (up to 120 Hz, `CADisableMinimumFrameDurationOnPhone`), drawn into a `CAMetalLayer`, only after a
  change and only while shown. `TerminalHostView` sizes the grid from its bounds (rotation, keyboard, pinch zoom
  between 7 and 28 points in half-point steps, kept in `terminal.fontSize`) and sends every new grid through the feed.
  The fonts are bundled as `TermFonts` (TermApple looks there on iOS: a top-level `Resources` folder breaks an iOS
  bundle's signature), the themes as `ghostty/`.
- **Input.** `UITextInput` for the software keyboard (no autocorrection, capitalisation, smart punctuation or
  predictions; marked text is the terminal's preedit); each character is a key event for Term's encoder, so Ctrl and Alt
  chords work from the M6a capsule. `UIKeyCommand`s cover hardware arrows, Esc, Tab, Home/End/Page keys, F1 to F12 and
  Ctrl/Alt chords (Option is Alt). The capsule (`TerminalKeyCapsule` in `TerminalSegmentView`): Ctrl and Alt latch for
  one key (double tap locks), Esc and Tab send at once, holding the d-pad shows the arrow cluster (drag onto a key; it
  repeats after 400 ms every 80 ms; lifting hides it), a tap pins the cluster, the last key hides or recalls the
  software keyboard while the terminal keeps hardware keys. Long press selects a word (Ghostty's boundaries), handles
  extend it, the edit menu copies and pastes (bracketed when the program asks).
- **Scrollback.** One finger scrolls with momentum. tmux replays a pane's history into the emulator on every
  attach, so its scrollback is local and `terminals.scroll` is never asked (`TerminalScrollback.client`); herdr keeps
  history on the server (`.server`: `terminals.scroll`, position from `terminal.scroll`); other multiplexers are
  learned from the first `scrollback_app_owned` answer. `TerminalScrollModel` splits a gesture exactly at the local
  scrollback's top and the server's live screen, so nothing jumps; programs that read the wheel get it.

Benchmarks (`TerminalBenchmarkTests`, full suite; iPhone 17 simulator on an Apple silicon Mac, Debug app with the
terminal frameworks optimized as always, a 51 x 53 grid): the parser alone takes 760 MiB/s of plain text; `cat`
of 256 MiB in 64 KiB notifications into a shown terminal 412 MiB/s with frames at 63/s; 4 MiB in 29-byte
notifications (tmux's size) 29 MiB/s, coalesced into about a third as many parse batches; output streamed at 8 MiB/s
keeps 60 frames a second (the simulator's display) with frames built in 1.3 ms median, 1.5 ms p95, and done on the
GPU in 2.9 ms median, 3.3 ms p95. The helper spike measured tmux at 1.7 to 2.3 MB/s for `yes`, far below these.
`testShowFixtureForScreenshot` holds a fixture full screen for `xcrun simctl io <device> screenshot`
(`TEST_RUNNER_DISPATCH_TERMINAL_SHOT=vite|vim|htop|cluster|keyboard`, `TEST_RUNNER_DISPATCH_TERMINAL_SHOT_DIR` for its
ready and release files, `…_COLUMNS` and `…_ROWS` for another grid than 50 x 33).

## Code

`Mobile/Code` is the diff viewer (M5d) and the composer with code (M5e).

- **Palette.** `CodeSyntax` ports the Mac's `SyntaxHighlight` lexer (which needs the Mac's `ChatTheme`): the same
  language names and one bounded regular expression where strings and comments are consumed whole, with the mockup's
  roles and keyword sets per language: keywords pink, calls and call receivers blue, strings green, types purple
  (capitalised names and built-in type words), numbers and constants amber (literals, `true`/`nil`/`None`, upper-case
  names that are not object keys), comments grey. Code beyond 64 KiB stays plain, as on the Mac.
- **Diff viewer.** A Patch step in message details pushes `DiffView` with the turn's patch steps, grouped by file
  (`DiffChanges` over the shared `ToolPresentation`/`ToolDocument` documents; relative paths resolve against the patch's
  working directory, else the call's, else the conversation's) and the tapped step's files open. Line numbers are
  `ToolDocument.lineNumbers` (Claude's edits have none, so their rows are unnumbered); each hunk's old and new sides are
  coloured as code of their own (the Mac's `diffLines`). Long lines wrap. Pinch zooms the code from 8 to 24 points in
  half points, kept in `code.fontSize` like the terminal's size. The trailing pill reads each open file with
  `files.text` (`{plugin: "files", path}`, absolute path) through the conversation's helper and shows it whole with the
  hunks marked where their new side stands now (near the header's line, else searched in order; removed lines sit
  where they were, unnumbered); a hunk that is no longer there gets a note, and a missing, unreadable, binary or
  oversized file or a dropped link says so in the section. Patch steps a page delivered without their diff are read in
  full (`chat.tools`) once. Revert is left out (Known limitations); a long press on a hunk does nothing.
- **Composer.** `CodeComposer` is the thread's composer ("+", the field, and the mic, Stop or send slot). Its field,
  `CodeTextView`, is a TextKit 1 `UITextView` whose draft stays plain Markdown: `ComposerMarkdown` finds fences with the
  Mac composer's `ComposerFence.scan` (`Dispatch/Views/ComposerFences.swift`, shared by path) and inline spans outside
  them, and `CodeComposerStyle` re-styles the text storage in place inside its own editing pass (`willProcessEditing`),
  so a chip that forms or a fence that closes is drawn final in the keystroke's frame and caret, selection, marked text
  and undo are untouched. A chip's backticks turn clear and take 6 points each (its padding); a fence's opening line is
  the panel's header with the language tag, its closing line the panel's bottom padding; `CodeLayoutManager` draws the
  chips and panels. With a fence in the draft the send slot moves under the text so the panel spans the field. The field
  grows with the draft (measured for the width it is about to get) up to 236 points, then scrolls. Autocorrection,
  capitalisation, smart punctuation and predictions are on in prose and off while the caret is in code (a fence, a span,
  or after an unclosed backtick). While focused, a glass key row (`CodeKeyRow`, the terminal capsule's material) offers
  the backtick, the fence, `{ }`, `( )`, `=>` and an indent; keys wrap a selection and are one undo step. A paste of
  several lines outside code offers "Paste as code" for six seconds (and the edit menu has "Paste as Code"), which
  fences the pasted text on lines of its own. Cmd-Return sends from a hardware keyboard.

`CodeDemo` (Debug) holds the mockups' content. `CodeScreenshotTests.testShowForScreenshot` (full suite) holds M5d,
the whole file or M5e full screen for `xcrun simctl io <device> screenshot`
(`TEST_RUNNER_DISPATCH_CODE_SHOT=M5d|M5d-file|M5e`, `TEST_RUNNER_DISPATCH_CODE_SHOT_DIR` for its ready and release
files); `CodeRenderingTests` attaches the same screens to the result bundle.

## Resilience

`Mobile/Resilience` keeps the lists usable through launches, drops and network changes (plan 3.2, 3.8, Phase 6).

- **Network and foreground.** `NetworkPathWatcher` reads `NWPathMonitor` (an injectable `NetworkPathSource`): when the
  path becomes usable again, or while usable moves to other interfaces (Wi-Fi to cellular, a VPN), it calls
  `HostSessions.networkChanged()`, which in the foreground calls `retryNow()` on every session; losing the path calls
  nothing (the links notice). Foregrounding already did the same. `retryNow()` on a session waiting out its backoff tries
  at once; on a connected session the driver checks the link (`echo` within 3 s, `SSHHostSessionDriver.alive`) and
  closes it when it does not answer, so a link a network change killed silently reconnects in about 4 s instead of the
  keepalive's 45 s. A connected link that answers stays as it is.
- **Instant launch from cache.** `HostCache` keeps per host the last live hello (identity, OS line, homes), the
  multiplexers with versions and the one followed, the latest topology, and Agents' rows (state, attention, a preview
  of at most 280 characters, time) in `host-cache.json` in Application Support through `PrivateFile` (owner-only,
  atomic, out of backups); nothing of a transcript beyond the preview, no secret. It is read synchronously when the
  composition starts, so the first frame already lists every host's spaces and agents (`HostSession.restore`,
  `ChatConversations.restore`); it is written half a second after live data changes and at once when the app goes to
  the background. Stale rows (a host not connected, or an Agents row not fetched live yet) dim their time to the
  tertiary colour, without animation; nothing else changes. Live data reconciles in place: Spaces applies a new
  snapshot before dropping the previous backend's, so a snapshot naming the same nodes under a new backend id (a
  reconnect, or live after cached) keeps every row's object; Agents' rows are keyed by host and topology key and sorted
  by activity, so they only move when the activity really changed. Debug runs with `DISPATCH_MOBILE_STORE=memory` or the
  scripted demo keep the cache in memory. The cache, `chat-markers.json`, `chat-models.json` and the remembered Spaces
  menu decode leniently (`Lenient`, `KeyedDecodingContainer.lenient`): a missing or unreadable key takes its default
  and an unreadable entry is left out, so an older or newer shape never drops the whole file.
- **Background refresh.** `BackgroundRefresh` is a `BGAppRefreshTask` (`<bundle id>.refresh`, Info.plist
  `BGTaskSchedulerPermittedIdentifiers` and the `fetch` background mode; SwiftUI's `.backgroundTask(.appRefresh)` runs
  it) asked for at least 15 minutes ahead whenever the app goes to the background or a run starts. It does nothing
  unless Settings' Background refresh is on and notifications are allowed (turning it on asks). A run connects every host
  with Chat on through a session that asks nothing (`HostSessions.backgroundSession`: an untrusted host key, a
  keyboard-interactive login or a key behind Face ID fail it), reads `chat.list` once (else `chat.state` and a page per
  conversation), disconnects, and posts a local notification for each conversation that needs the user now and did not
  in the cache's last-known rows (muted ones never): title "tab · host", body the last line of the agent's newest text.
  It updates the cache, never the seen markers (only opening a thread does), and ends within 25 s. Every notification
  has the `agent` category, registered at launch with a hidden-previews placeholder: with previews hidden (iOS
  Settings, Notifications, Show Previews: When Unlocked or Never) the lock screen shows "An agent needs you" instead of
  the agent's last line, and no title. Tapping a
  notification opens the thread (`NotificationRoute`, the app delegate is the notification centre's delegate from
  launch). A launch in the background connects none of the app's own sessions. The scheduler, notifier, clock and
  source are injected (`BackgroundRefreshTests`). On a device, hosts that log in with Face ID keys cannot be refreshed:
  iOS shows no Face ID in the background, so the background session reads the Keychain with an `LAContext` whose
  `interactionNotAllowed` is set: a key behind Face ID fails at once (no prompt is attempted) and that host is skipped
  for the run; password hosts are refreshed.

  Manual check in the simulator (Debug): run the app, turn Background refresh on in Settings (allow notifications),
  send it to the background (Home), then in Xcode pause it and in lldb:

  ```
  e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"yachts.dispatch.mobile.refresh"]
  ```

  and continue. A conversation that started waiting for an approval since the app last saw it shows as a notification;
  tapping it opens its thread. `_simulateExpirationForTaskWithIdentifier:` checks that an expiring run disconnects.
- **Multiplexer follow** and **paths**: Architecture (which multiplexer) and Spaces (paths), above.

Measured (iOS 27 simulator on this Mac, the live fixture, `ResilienceLiveTests`): cache to the first frame's rows
1.7 ms; cached rows to live 0.27 s after connecting (same row objects); sshd killed to reconnecting at once; sshd back
and a network change to connected 0.24 s. The app end to end: Testing, below.

## Settings

Not in the mockup, in the app's grammar: a plain inset form in a sheet, opened from a glass gear beside Add host at the
end of Spaces' edit mode. Spaces is where hosts are managed and most settings are per host; M2a's and M3a's headers stay
as the mockup draws them. (With no host yet there is no edit mode; nothing in Settings acts before a host exists except
appearance and the font size, which keep their defaults.)

| Setting | Effect |
| --- | --- |
| Appearance: System, Dark, Light | `UserDefaults.standard` string `appearance` (`system`, `dark`, `light`; default `dark`), applied live (Appearance and accessibility, below). |
| Terminal font size | 8 to 20 pt, `terminal.fontSize` (what pinch zoom writes and new terminals read). |
| Host: Chat | Off: the helper runs without `hooks.configure` and the `agent.*` capabilities (`HelperGrant.chatOffCapabilities`, at connect, and on a live connection through `permissions.reduce`, a reconnect if that fails); Spaces and Agents see the host's topology without agent bindings, so its agents are terminals only and background refresh skips it. On again reconnects (a grant only shrinks). |
| Host: Multiplexer | The control host detail shows; followed without reconnecting (Architecture). |
| Background refresh | Off by default; on asks for notification permission and stays off without it. |
| Remove all data | After a confirmation: every host (sessions end, passwords go), every key and every Keychain item of the app's vault, all trusted host keys, seen markers and mutes, the cache, drafts and the outbox, the remembered agents and models (`chat-models.json`), Spaces' per-host values (recent space, collapsed hosts, space order: `spaces.json`, private and out of backups, and any an older build left in UserDefaults); background refresh off, notifications removed. Appearance, the font size and Spaces' menu stay. Nothing changes on the hosts. |

## Appearance

The tab bar is the system's Liquid Glass `TabView`. New is a tab with the role the system draws as the separate
trailing glass circle (iOS 27's `.prominent`, iOS 26's `.search`), never selected: choosing it opens the current
section's New sheet. Refusing that selection only in SwiftUI's binding is too late: a screen recording showed the
empty New tab for 16 frames (about 250 ms) before the sheet began. `NewTabGuard` refuses it in the tab bar
controller's delegate (wrapping SwiftUI's) before UIKit switches tabs; recordings since show no blank frame. Its
glyph follows the section, as in the mockup: a tab with a plus (Spaces, M2a), compose (Agents, M3a). `MobileRow` is the row grammar Spaces and Agents share: gutter dot (blue unread as Mail, amber working), 46 pt host disc, name with a small detail after it, time, chevron, one or two lines of what the tab is doing. Hosts are managed inside Spaces (M1d empty state, M1e edit mode, M1f host detail).

### Appearance and accessibility

- **Light and dark.** Settings writes `appearance` to `UserDefaults.standard` (`system`, `dark`, `light`; dark by
  default). The root applies it live (`mobileAppearance()`, `Mobile/App/MobileAppearance.swift`):
  `preferredColorScheme` and the window's `overrideUserInterfaceStyle`, so going back to System clears the override and
  UIKit presentations follow. Info.plist no longer pins Dark. The launch screen stays black (`LaunchBackground`): it is
  drawn before the app can read the default, and black matches the default.
- **Colours.** Every colour a view draws comes from the asset catalog with light and dark variants (`MobileColors`) or
  from the system's semantic colours (labels, fills, separators): `Canvas` (#F2F2F7 / black, L1a), `GroupedRow` (white /
  #1C1C1E), `RaisedRow` (white / #2C2C2E: M5b's cards), `Hairline` and `ThinkingBorder`, `ApprovalCode` (the M4b block,
  #DCDCE0 / #1F1F20), `BubbleUser` and `BubbleUserText`, `BubbleAgent`, `FaintFill`, `ChipFill`, `ChipBorder`, `Lens`,
  `Caution` (amber text), `Destructive`, `Added`, the step badges (`StepRead`, `StepThink`, `StepRun`, `StepTool`), the
  shimmer, and the code palette (`Code…`, used through `CodePalette` as dynamic `UIColor`s). The pink, the text on it
  (`OnAccent`), the host tints and the state dots are the same in both. Glass (`glassEffect`, the tab bar, sheets)
  switches by itself. The terminal keeps its own theme (`dispatch-black`) in light, so its key capsule and arrow cluster
  are drawn in the dark scheme over it, and its keyboard stays dark; the composer's keyboard follows the app.
- **Decisions against the mockup's numbers.** The mockup's light user bubble `#C94FC9` gives white text 3.86:1, not the
  4.5:1 its note asks for; the bubble is `#BF3BBF` (same hue, 4.57:1). Light variants of the amber, red, green, the step
  badges and the syntax colours are deeper so 11 to 15 point text clears 4.5:1 on the light canvas and rows
  (`MobileColorTests`). Host names in host detail's title use the label colour in light (the pale tints do not read on
  #F2F2F7).
- **Dynamic Type.** Text uses text styles, or `scaledFont` (a `@ScaledMetric` size) where the mockup's size is none
  (13.5, 14, 24 points); fixed heights became minimum heights. `MobileRow` stacks at the accessibility sizes (name and
  chevron, then detail, time and up to two more lines of preview; the host disc gives its room to the text). Chips wrap
  onto more lines (`ChatChipFlow`), paths and short labels wrap instead of truncating (`fittingLine`). The navigation
  bar's pills and titles, and the sheets' own bars (New space, New chat), grow to xxxLarge and then show the large
  content viewer (the bar keeps its height, as the system's bar buttons do); the terminal's key capsule and the code key row grow to accessibility1. Monospace bodies
  (terminal grid, diff and file code, step output) keep their own size and pinch zoom; their chrome scales.
  `DynamicTypeTests` measures rows, bubbles, captions, chips, the banner, the thinking row and the capsules at Large,
  xxxLarge and accessibility5.
- **VoiceOver.** A row is one element: label "name, detail, time, line", the dot's meaning as its value (Unread,
  Working), Agents' swipe actions (Mute, Close) as its actions (checked through the accessibility runtime in
  `AccessibilityLabelTests`). The thinking row reads "claude is thinking, 40 seconds" with the steps as value, updates
  frequently, and its time changes only every ten seconds (whole minutes after ten). Approval and question chips are
  buttons with hints; a queue row is one button (edit) with Send now, Move up, Move down and Delete actions. The banner
  reads its title once, not the counting seconds. Headers carry the header trait; decorative glyphs are hidden; the
  terminal's capsule keys are labelled and its screen is its value. Small targets (the mic, Stop, Send, the steps
  caption, the queue's Done) have 44 point hit areas without moving.
- **Reduce Motion.** The thinking glyph stands still, the shimmer and accent scan are static, the waiting dots stop, the
  elapsed time steps by five after ten seconds; the arrow cluster and the composer's paste offer cross-fade; the diff's
  disclosure turns without animation. Nothing else animates (the tree toggle, the filter tint, the banner and the queue
  change in one frame in either mode). `ReduceMotionTests` renders each loop six times over a second: one frame with
  Reduce Motion, several without (full suite: about 30 s). Views read it through `@ReduceMotion` (the system setting,
  overridable in tests).
- **Screens and audit.** `AppearanceUITests` (full, `DispatchMobileUITests`) launches every demo screen (M1d, M8a, M2a,
  M2b, M1e, M2c, M4d, M7a, a tab on Terminal, M3a, M3b, M4a, M4b, M4c, M5a, M5b, M5c, M5f, M9a, M5d) in light and dark and attaches
  `<screen>-<scheme>` screenshots, the same at xxxLarge and AX5, and runs `performAccessibilityAudit()` on each in both
  schemes (`DISPATCH_APPEARANCE_SCREENS=M5a,M7a` limits a run). Accepted on purpose: contrast reports (the mockup's
  secondary and tertiary label opacities, host tints and the pink as text, disabled controls; the stated pairs are
  checked by `MobileColorTests` instead), Dynamic Type reports on bar items, Form buttons and the capped capsules, the
  keyboard's empty predictive buttons, Mail-style clamped previews, and New host's system address placeholder.
  `AppearanceScreenshotTests` (full) attaches M5d, M5e and M6a in both schemes (the Spaces sample has no terminal
  behind its tabs). Compared with the PNGs in `build/mockup-review` (2026-10-18): light matches L1a and L2a (canvas,
  rows, bubbles, captions, glass), with the system segmented control and the deeper user pink as the differences.

```sh
xcodebuild -scheme DispatchMobileUITests -destination 'platform=iOS Simulator,name=<device>' -derivedDataPath build \
  -collect-test-diagnostics never test -only-testing:DispatchMobileUITests/AppearanceUITests
```

## Testing

**Suites.** `test/run.sh --platform ios` (`test/ios.py`) runs the fast suite on the simulator: 421 cases, 400 XCTest and 21 Python (about 80 s with an incremental build, 45 s once built). Cases are classified in `test/suites.json` as
`DispatchMobileTests/<Class>/<test>` and `DispatchMobileScripts/<Class>/<test>`; the Mac runner leaves those entries to
`test/ios.py`, which fails a run when a selected case did not run or a fast run meets an unclassified case. `--suite
full` runs the whole bundle; `DispatchMobileScripts` alone (or one of its classes) runs only the Python cases, without a
build.

- `DispatchMobileTests` (hosted by the Debug app): `Mobile/Tests` (`MobileRowTests`, `SharedModelTests` and every
  area's tests) and, by path, `DispatchTests/HelperClient/HelperClientTests` (wire codec against the real helper
  fixtures, read from the checkout through the simulator), `ProgramStatusTests`, `ChatDraftTests`,
  `ChatSideQuestionTests`, `ChatOperationsTests` and `PortableTestSupport` (test doubles both bundles use). Their
  cases that need `ChatSession` or `ChatCoordinator` are guarded and stay Mac-only. The tests' helper peer is
  `ScriptedHelper` (`Mobile/Tests/ChatTestSupport.swift`) everywhere; the Debug demos (`ChatDemo`, `TabsSample`)
  answer in process with their own.
- Hosts: `HostStoreTests`, `KeyStoreTests`, `HostSessionTests`, `HostScreensTests` use the scripted driver and
  in-memory vaults; key encodings are checked against `ssh-keygen` output and RFC 8032.
  `HostScreensTests.testScreensRender` attaches M1f, M8a, the trust sheets and the hint to the result bundle (`xcrun
  xcresulttool export attachments`). `DISPATCH_MOBILE_ROW_PNG` (as `TEST_RUNNER_DISPATCH_MOBILE_ROW_PNG` through
  xcodebuild) makes `MobileRowTests.testRowsRender` write the M2a rows to a PNG.
- Integration: `SSHDriverTests` (the driver's state mapping, followed multiplexer, the follower switching live,
  `running`, the liveness probe, first-topology gate) and `MobileCompositionTests` (a `HostSessions` over the scripted
  driver drives Spaces and Agents; removal and reorder through the store; urgency; Agents opening a tab on Chat; Pi
  re-enabled per connection) are fast; `SSHDriverLiveTests` and `MobileLiveTests` are full and need the live fixture.
- Resilience and Settings: `ResilienceNetworkTests`, `ResilienceCacheTests`, `BackgroundRefreshTests`, `SettingsTests`
  and `HomePathTests` are fast; `ResilienceLiveTests` is full and needs the live fixture.
- Terminal and Code: `TerminalBenchmarkTests`, `testShowFixtureForScreenshot` and `CodeScreenshotTests` are full
  (Terminal, Code, above).
- Privacy: `ReleasePrivacyTests` checks that the app's files are owner-only and out of backups (`MobileFiles`,
  `tab-activity.json`).
- Release tooling (`test/ios-release.test.py`, `DispatchMobileScripts`): `scripts/ios-signing.py` (writing, parsing and
  refusing configs, team discovery), `scripts/run.py`'s device discovery (real iPhones only, by name or UDID, the
  phone as the build destination, the early signing check), and the release check's bundle, Info.plist, privacy
  manifest and link-map logic. No Xcode, network or device.

**UI tests.** `DispatchMobileUITests` (its own scheme, so unit runs never start the app) taps the app running scripted
demo hosts: `DISPATCH_MOBILE_SCRIPTED=1` (Debug) keeps four demo hosts in memory, `empty` starts with none (hosts added
there ask about their host key), and `trust`, `mismatch` and `nomux` show the host key sheets and the hint's case.
It covers New on both tabs, and M1d's Add host through Create, the host key question inside the sheet, and the
save. Its screenshots are attachments in the result bundle.

```sh
xcodebuild -scheme DispatchMobileUITests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build test
```

**Live fixture.** `scripts/mobile-live-fixture.py start /tmp/sim-…` makes this Mac a host: the loopback sshd of
`scripts/mobile-ssh-fixture.py` (private HOME, helper root and sockets), a private tmux server on the explicit socket
`ROOT/tmux-<uid>/default` (the helper's default path for the sshd's `TMUX_TMPDIR`), and `claude` on the login
shell's PATH: Claude Code from `build/test-tools` with the environment of `scripts/claude_fixture.py` (a local
Messages API). `… serve ROOT` runs `stop-sshd`/`start-sshd` when a test asks (the simulator cannot start processes);
`… stop ROOT` ends only what it recorded. Debug builds take `DISPATCH_MOBILE_STORE=memory` (nothing saved, no Face
ID), `DISPATCH_MOBILE_AUTHORIZE_KEYS=<authorized_keys>` (new keys are appended there) and `DISPATCH_MOBILE_HOST_ENV`
(per `address:port`, an environment for the helper and its install: a private HOME and sockets on a shared host).
The Linux VM (Lima, `build/host-linux-ssh.json` profile; docs/vm_testing.md) joins through
`TEST_RUNNER_DISPATCH_LIVE_LINUX`.

```sh
python3 scripts/mobile-live-fixture.py start /tmp/sim-int
python3 scripts/mobile-live-fixture.py serve /tmp/sim-int &
TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-int/live.json test/run.sh --platform ios SSHDriverLiveTests
TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-int/live.json \
  TEST_RUNNER_DISPATCH_LIVE_LINUX='{"name":"ubuntu-vm","host":"127.0.0.1","port":52687,"user":"user","key":"/Users/me/.lima/_config/user","root":"/tmp/dt-int"}' \
  xcodebuild -scheme DispatchMobileUITests -destination 'platform=iOS Simulator,name=<device>' -derivedDataPath build \
  -collect-test-diagnostics never test -only-testing:DispatchMobileUITests/MobileLiveTests
python3 scripts/mobile-live-fixture.py stop /tmp/sim-int
```

`MobileLiveTests.testThisMacEndToEnd` (iOS 27 simulator on this Mac, Debug, 2026-10-18; times are XCUITest's, which
polls about once a second, so they are upper bounds):

| Step | Time |
| --- | --- |
| M8a with a new ED25519 key: Create to the trust question | 1.96 s |
| Trust to saved (helper upload of 16 MB on the first connection, hello, topology) | 1.81 to 1.86 s |
| Saved to the fixture's tab in Spaces | 1.09 s |
| New space (M7a, through New chat's "New space…") to its terminal | 1.90 s |
| Terminal to the shell prompt; `printf` typed to its output on screen | 1.08 s; 1.83 s |
| New chat (M9a) Start to the thread with Claude bound | 2.47 s |
| Send to the approval (M4b); Allow to the tool's result | 3.33 s; 1.45 s |
| sshd and its sessions killed to the M4c banner | 1.31 s |
| sshd back to reconnected (backoff 1 s, 2 s, …; no network change) | 4.17 to 4.23 s |
| A message after the reconnect to Claude's reply in the same thread | 2.79 to 3.15 s |
| Linux VM (Ubuntu 26.04 arm64, Lima): Create to the trust question; Trust to saved (linux-aarch64 upload, 7.9 MB) | 1.96 s; 1.83 s |
| Host detail showing "Ubuntu 26.04", Connected, "tmux 3.6" | 3.97 s |
| The VM's tab to its bash prompt | 2.74 s |

Without the UI (`SSHDriverLiveTests`, the driver alone): trust question 25 ms after connect, trust to connected
0.24 to 0.30 s with the helper cached (0.92 s with the first 16 MB upload), latency 0.5 to 1.3 ms, drop noticed at once
(the sshd closes the socket), restart to connected 0.27 to 0.35 s after `retryNow()`. On the VM the helper ran under
the private HOME `/tmp/dt-int/h` (`DISPATCH_MOBILE_HOST_ENV`); nothing changed in the VM's own home. (The upload sizes
are the Debug build's helpers; Release ships smaller ones, Release builds and app size above.)

**Frame checks.** No transient wrong state is acceptable, frame by frame. `scripts/tab-bar-frames.swift` checks a
recording: push and pop from Spaces (two tabs and a space, 675 frames) and from Agents (a tab on Terminal, a tab on
Chat, space details, 472 frames): 0 wrong frames (root at rest without its bar, or a pushed screen at rest with it).
`-DispatchTabsScript` drives such recordings; the New tab guard was found the same way (Appearance).

Transitions (2026-10-18, `dispatch-rfid`, an iPhone 17 at 402 x 874 points, dark): `TransitionUITests` (full) drives
each family with a rest before and after every step, `xcrun simctl io <device> recordVideo` records it, and
`scripts/transition-frames.swift` splits the recording into pictures at rest (the same picture for 80 ms or more;
judged one by one) and frames in motion (judged only for content that must never appear), drawn as contact sheets.
Counts include the launch from the home screen; "wrong" is the count before the fixes, after them every case is 0.

| Recording | Frames | At rest | In motion | Wrong at rest, found and fixed |
| --- | ---: | ---: | ---: | --- |
| Sheets: New host, New chat, Settings (`testSheets`) | 1087 | 43 | 298 | New chat showed "The operation couldn't be completed. (Swift.CancellationError error 1.)" under the space after a cancelled launch load |
| New space from the space picker (`testNewSpaceSheet`) | 519 | 26 | 229 | 0 |
| Terminal / Chat segments, twice each way (`testSegmentSwitch`) | 567 | 21 | 41 | 0 |
| Thinking row unfolding and folding, twice (`testThinkingRow`) | 1188 | 12 | 37 | 0 (both change in one frame) |
| Queue card collapsing and expanding, twice (`testQueueCard`) | 1156 | 11 | 45 | 0 |
| Allow chip becoming the message (`testApprovalChip`) | 160 | 15 | 35 | the demo's helper answered null, so a decoding error stood under the bubble (demo only) |
| Agents filter pill and Spaces' filter menu (`testFilters`) | 783 | 35 | 174 | the Unread pill stayed grey with a dark glyph when on; Spaces' capsule had dark glyphs on untinted glass for 0.9 s after a filter was picked |
| Reconnecting banner in and out (`DISPATCH_MOBILE_CHAT_DEMO_LINK=cycle`) | 295 | 7 | 30 | 0 (in and out in one frame) |
| Tree toggle, Edit and Done from the flat list and the tree, filter on and off (`-DispatchTabsScript`) | 86 | 14 | 30 | entered from the flat list, Edit showed the tree under a capsule still saying "flat" until Done |

```sh
xcodebuild -scheme DispatchMobileUITests -destination 'platform=iOS Simulator,name=<device>' -derivedDataPath build build-for-testing
xcrun simctl io <device> recordVideo --codec h264 --force build/frames/sheets.mov &   # stop with kill -INT
xcodebuild -scheme DispatchMobileUITests -destination 'platform=iOS Simulator,name=<device>' -derivedDataPath build \
  -collect-test-diagnostics never test-without-building -only-testing:DispatchMobileUITests/TransitionUITests/testSheets
swiftc -O scripts/transition-frames.swift -o build/transition-frames
build/transition-frames build/frames/sheets.mov build/frames/sheets      # rest.png, motion-NN.png
```

**Fidelity.** `FidelityUITests.testScreensBesideTheMockup` (full) launches the 22 mockup screens through the demo
hooks (the Spaces sample, the scripted hosts, `DISPATCH_MOBILE_CHAT_DEMO`, which also has M5d with the mockup's patch
and M5e's draft) in dark and light and attaches each screenshot (`<ID>-<scheme>-app`) and its pair with the render
from `build/mockup-review` (`<ID>-<scheme>`: mockup left, app right, a guide every 50 points; light pairs use L1a for
M3a and L2a for M4a, the dark render elsewhere, for layout). `scripts/fidelity-pairs.swift` makes the same pair from
any screenshot. Strings: every text node inside the mockup's phone frames (not its captions) was grepped in `Mobile/`;
all the app's own copy is there verbatim or composed with the same words ("Spaces · 2", "Tabs · 3",
"Queued · sends when mba2 is back", "Waiting · 2m 10s", "Recent on ai, from agent history"); no typo or rewording was
found. Not found, on purpose: M8a's footnote (plan, Keys: "Private keys stay in the Keychain and unlock with Face ID;
Secure Enclave keys are available for P-256.") and demo content (M4b's e2e conversation, M5f's step results, the key
names and fingerprints, M6a's wrapped vite line), which is data, not copy. Checked on 2026-10-18 on `dispatch-rfid`:

| Screen | Element | Mockup | App | Verdict |
| --- | --- | --- | --- | --- |
| Rows (M2a, M3a, M2c) | grid | dot at 16 pt, disc at 40 pt | both 6 pt further right (the row padded 16 inside the list's 6) | fixed |
| Rows | line height | 20 pt on 15-point text, row 61.5 pt | the font's own, row 59.3 pt | fixed |
| Rows | gutter, dot, disc, glyph, name, detail, time, line, separator | 14, 10, 46, 24, 17 semibold, 13 tertiary, 15 secondary, 15 secondary, inset to the text column (96 pt) | the same (`MobileRow`, `MobileRowTests`) | matches |
| Rows | time | "9:31" | the locale's short time ("12:14 PM"); the sample's times are relative to now | intentional (data) |
| Tab bar (all roots) | bar | a full-width 60 pt capsule beside the New circle | the system's Liquid Glass `TabView` and its trailing New circle | intentional (Appearance) |
| M1d | copy, glyph, Add host | as drawn, with "mosh" | the same | intentional ("mosh": plan decision) |
| M1e | tree lens in edit mode | on | off when Edit was entered from the flat list | fixed |
| M1e | Settings gear beside Add host | none | present | intentional (Settings) |
| M1f | back pill | "‹ Spaces" pill | the system's bare chevron | fixed |
| M1f | Edit | pink | white | fixed |
| M1f | section headers | 13 pt capitals, identity right under the bar | iOS 26's title-case headers, identity 36 pt lower | fixed |
| M1f | Multiplexer row, OS line | none | present | intentional (plan M1c: the multiplexer line) |
| M1f | host name in light | the tint | the label colour | intentional (Appearance) |
| M1f | Connection row height | 44 pt | 52 pt (iOS 26 inset grouped `Form`) | open |
| M2a | sort and filter menu | custom glass panel | the system `Menu` with the same sections and ticks | intentional (system menu) |
| M2a | dots and lines in the sample | blue, amber, "thinking 48s" | none, paths (Chat's urgency replaced the sample's) | fixed (Debug sample) |
| M2b | host header inset | 32 pt, level with the spaces | 36 pt | fixed |
| M2b | count by a space | 2, 3, 2, 2 (tab counts), caption "the count of tabs that need you" | tabs that need you or hold an unseen result | intentional (Spaces: Mail's unread count) |
| M2c, M4a, M5d | back pill width | 100 pt "‹ Spaces", 51 pt "‹ 1" | about 6 pt wider (the chevron symbol's side bearings), count pill with 16 pt trailing | fixed |
| M3a | filter glyph | funnel | three lines (the sort menu's) | fixed |
| M3a | filter on | filled with the app tint | grey pill, dark glyph (the bar's shared glass ignored the style) | fixed |
| L1a | toolbar row | title alone at the top | the filter pill in a row above the title, as M3a draws it | intentional (M3a) |
| M4a, L2a | bubbles | 20 pt corners with a 6 pt tail corner, #E07BE0 / #2C2C2E, light #C94FC9 / #E9E9EB | the same; light user bubble #BF3BBF | intentional (Appearance: 4.5:1) |
| M4a | segmented control | custom glass segments | the system segmented control | intentional (Appearance) |
| M3b | key row above the keyboard | none | the code composer's key row while focused | intentional (Code: one composer) |
| M4b | chips, code block, caption | Deny, This session, Allow; mono block; "Waiting · 2m 10s" | the same | matches |
| M4c | banner | 32 pt, 16 pt corners, amber 14 %, 13 pt | the same | matches |
| M4c | queued message | under turn 1 with "Queued · sends when mba2 is back" | shown after turn 2 as if sent (demo) | fixed (Debug demo) |
| M4d | tab row detail | "thinking 48s" | "fable-5.1 · thinking 48s" (the row's status line, as M2c draws it) | open (the mockup differs between M2c and M4d) |
| M5a | thinking row | hairline with the scan, ◆ with satellite, shimmering "thinking", "·", elapsed, "8 steps · Patch" right, chevron in a 28 pt disc | the same | matches |
| M5f | step badge | 50 pt wide, so paths align | as wide as the word (READ narrower than PATCH) | fixed |
| M5b | facts | Host, Space, Tab, Model, Sent | Sent, Model, Space, Host | fixed |
| M5c | queue card | "Queued · 3", "sends after this turn", Done, rows with handles | the same | matches |
| M5d | whole-file pill glyph | white | pink | fixed |
| M5d | diff palette | keywords pink, calls blue, strings green, types purple, numbers amber, comments grey; tinted rows | the same | matches |
| M5e | chips, fence panel, key row | as drawn | the same | matches |
| M6a | key capsule | Ctrl, Esc, Tab, Alt, d-pad, keyboard; 52 pt glass | the same | matches |
| M6a | terminal in light | (dark only) | stays `dispatch-black` with a dark capsule | intentional (Appearance) |
| M7a | host pull-down | custom menu | the system `Menu` | intentional (system menu) |
| M8a | footnote | "Private keys stay in the Secure Enclave and unlock with Face ID." | "Private keys stay in the Keychain …" | intentional (plan, Keys) |
| M8a | Create key…, public key actions, the helper statement, the host key question | none | present | intentional (plan 3.1, Hosts) |
| M8a | section headers, grabber | capitals, grabber | iOS 26's headers, no grabber | fixed |
| M9a | grabber; the space note | grabber; tertiary | none; secondary | fixed |

Per screen (fixed / intentional / open): rows 2/1/0, tab bar 0/1/0, M1d 0/1/0, M1e 1/1/0, M1f 3/2/1, M2a 1/1/0,
M2b 1/1/0, M2c 1/0/0 (the back pills), M3a 2/0/0, L1a 0/1/0, M4a and L2a 0/2/0, M3b 0/1/0, M4b 0/0/0, M4c 1/0/0,
M4d 0/0/1, M5a 0/0/0, M5f 1/0/0, M5b 1/0/0, M5c 0/0/0, M5d 1/0/0, M5e 0/0/0, M6a 0/1/0, M7a 0/1/0, M8a 1/2/0,
M9a 1/0/0: 17 fixed, 16 intentional, 2 open.

```sh
xcodebuild -scheme DispatchMobileUITests -destination 'platform=iOS Simulator,name=<device>' -derivedDataPath build \
  -collect-test-diagnostics never test -only-testing:DispatchMobileUITests/FidelityUITests
xcrun xcresulttool export attachments --path <result bundle> --output-path build/fidelity/pairs
swiftc -O scripts/fidelity-pairs.swift -o build/fidelity-pairs   # build/fidelity-pairs MOCKUP.png APP.png OUT.png
```

**Release.** `python3 test/ios-release.py` (Release check, above).

## Device checklist

The simulator has no enrolled Face ID, no Secure Enclave keys, no Local Network prompt and no real background
scheduling, and tests inject `KeyProtection.none`; these need an iPhone, by hand, on a Release build installed with
`./run.sh --ios-device --prod`:

1. Install and launch: the app opens to Spaces' empty state (as `build/release-check/launch.png` shows for the
   simulator); a free account's first launch asks to trust the developer first.
2. Create an ED25519 key: Face ID is asked for on its first use (connect) with "Dispatch uses Face ID to unlock your
   SSH keys.", and Cancel fails the login.
3. Turn Face ID off and on again (or enrol another face): `biometryCurrentSet` invalidates the key; connecting says
   so rather than hanging.
4. A phone without Face ID enrolled: creating a key fails with a clear message.
5. Create a Secure Enclave key, add its line to `authorized_keys`, connect: one Face ID prompt per signature.
6. Copy and Share public key put the exact `authorized_keys` line on the pasteboard and in the share sheet.
7. Local Network: the first connection to a host on the LAN shows the system prompt with "Dispatch connects to SSH
   hosts on your local network."; Don't Allow makes LAN hosts fail to connect (hosts over the internet still work);
   turning it on in Settings, Privacy & Security, Local Network lets them connect.
8. Background sockets: connect, lock the phone or switch apps for a minute, come back: the sessions were dropped in
   the background (the app disconnects there) and reconnect within seconds; a Face ID key asks once more (the key is
   read once per foreground run); the agents kept running in tmux or herdr.
9. Background refresh with biometric keys: turn Background refresh on, leave a password host and a Face ID key host
   with an agent waiting for approval; after iOS runs the task (minutes to hours; the lldb command under Resilience
   forces it while debugging) only the password host's conversation notifies, the Face ID host is skipped silently.
10. Network change: switch Wi-Fi off with a host connected: the link reconnects over cellular in about 4 s.
11. Restore the phone from a backup onto another device: no host, key or password comes along.
12. After 7 days on a free account the app no longer opens until `./run.sh --ios-device` runs again; its data is
    still there.

## Known limitations and deferred items

- **mosh**: deferred until after v1; the connection is SSH with reconnect and reattach, though the copy keeps the
  word "mosh" (plan decision). Revisit once reconnect latency is measured on real networks.
- **Revert a hunk**: the helper has no operation to reverse a patch, and writing a reversed file through a new write
  op is a helper change not made yet; the diff viewer has no Revert.
- **iOS 26 New button**: the `.search` tab role fallback (`NewTabGuard`, Appearance) is untested: only the iOS 27
  simulator runtime is installed here, and no iOS 26 device was used.
- **Rekey host key**: russh 0.64.1 checks the host key only at a connection's first key exchange; a rekey's key is
  not compared with the trusted one (no hook without patching russh; the exact hook and why it is not a
  man-in-the-middle opening are in [security.md](security.md#dispatch-for-iphone)).
- **Keyboard-interactive** logins are tested against the engine's in-process server and the loopback sshd's flow, not
  against a live server that asks several rounds (one-time codes, PAM prompts).
- **herdr live**: the app's live runs (`MobileLiveTests`, `SSHDriverLiveTests`) use tmux; herdr is covered by the
  helper spike's runs and the scripted tests, not by the app end to end.
- **Tab activity from output**: a row's time moves with topology changes only; `MobileWorkspace.noteActivity` (tested)
  is not called for terminal output or agent state yet, so a busy tab whose names and directories stay the same keeps
  its older time.
- **Pi**: the helper does not keep the Pi integration choice across connections, so the app re-enables it on every
  connection (when installed); a helper-side persistence or a `hello` field would replace that.
- **"This session" for Codex**: Claude approvals offer "This session"; Codex 0.162 rejects `updatedPermissions` in its
  PermissionRequest hooks, so Codex offers Allow and Deny only until its hooks support it or its app-server approvals
  (`acceptForSession`) are routed through the helper.
- **Replays on `main`**: the helper changes for the phone are behind hello features the Mac never names, so recorded
  Mac sessions replay as before; close-tab captures recorded with macOS `/bin/bash` 3.2 shells and launcher captures
  that recorded the herdr tty race must be re-recorded when `mobile` merges into `main`
  ([ios-helper-spike.md](ios-helper-spike.md), "What the Mac's replay corpus sees").
- **No device run yet**: everything in the Device checklist, `--ios-device` against a real phone included.
- **Other host coverage**: Linux on one arm64 Ubuntu VM only (x86-64 Linux and other distributions untested); no
  run against a real remote Mac with Homebrew tmux; two helpers serving one phone after a late-noticed drop is
  prevented by `stdio.liveness` but not exercised.
- **Deferred by plan**: push notifications (needs a relay; background refresh is the stand-in), iPad, iCloud sync
  (never: nothing leaves the phone), App Store or TestFlight builds (the macOS helper would have to become a
  non-Mach-O payload, ITMS-90171), the `SystemProvider` seam and the `ChatSession` split (Shared sources).
