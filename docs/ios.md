# Dispatch for iPhone and iPad

A thin client for SSH hosts. The device has no shell and starts no processes: the Rust helper on each host does the
work, and the app speaks the helper protocol (`helper/PROTOCOL.md`) over one in-process SSH connection per host.
iOS and iPadOS 26+, one app for iPhone and iPad ([iPad](#ipad)), with local device installs and Ad Hoc
releases to registered devices ([releasing](releasing.md#iphone)). Sources are in `Mobile/`; privacy, trust, keys and the helper's
grant are in [security](security.md#dispatch-for-iphone); the Apple Watch companion in [watch](watch.md).

**Hosts need** SSH (password, key or keyboard-interactive), macOS 14+ on Apple silicon or Linux arm64/x86-64, and
tmux 3.7+ or herdr 0.9.3+ ([installing](integrations.md#tmux-and-herdr)). Shells and agents live in tmux windows or
herdr tabs so they outlive the connection; the app installs nothing but its helper. tmux before 3.7 has no
bracketed-paste state: Chat to a bound agent works, other typing is refused. Linux with systemd-logind
`KillUserProcesses=yes` kills servers at logout unless the user runs `loginctl enable-linger $USER`. A host without
the helper ([Plain SSH](#plain-ssh)) needs only SSH and a login shell.

## Building and running

```sh
./build.sh --ios --run [--simulator "iPhone 18 Pro"]         # Debug in the simulator (DISPATCH_IOS_SIMULATOR)
./build.sh --ios --run --simulator "iPad Pro 11-inch (M5)"   # the same on an iPad
./build.sh --ios --demo                                      # three scripted demo hosts, no SSH (Debug hooks, below)
./build.sh --ios-device ["<name or UDID>"] [--release] --run # paired iPhone or iPad; Debug without --release
test/run.sh --platform ios [--simulator NAME] [--suite full] [Class]   # Testing, below
python3 test/ios-release.py [--simulator NAME]               # Release check, below
./build.sh --archive PATH [--build-number N]                 # unsigned App Store archive (docs/releasing.md)
```

- Needs Xcode 27 with an iOS simulator runtime. The simulator window is DeviceHub (`com.apple.dt.Devices`, which
  `./build.sh --ios --run` tries first, falling back to Simulator.app); without either the simulator runs headless
  (`xcrun simctl io booted screenshot`). `--simulator` takes a name or UDID (`scripts/ios_simulator.py`: the booted
  one wins, then the newest runtime); the default is `DISPATCH_IOS_SIMULATOR`, else iPhone Air.
- **Two iOS 27.2 runtimes**: `iOS-27-2` has every iPhone and iPad but the Duo, and `iOS-27-2-iPhone19-4` has only the
  iPhone Duo. Name the runtime when creating one: `xcrun simctl create my-ipad "iPad Pro 11-inch (M5)"
  com.apple.CoreSimulator.SimRuntime.iOS-27-2`.
- **Two projects.** The iPhone and Watch apps are `DispatchMobile.xcodeproj` (`project-mobile.yml`), the Mac app
  `Dispatch.xcodeproj` (`project.yml`); both include `project-shared.yml` (the base settings, the `Dictation` package
  and the `SSHHelpers` target), and `scripts/generate-project.py` generates both. Only the iPhone project has the
  `MobileTransport` package, so building the Mac app never needs the SSH engine below.
- **Fresh checkout.** SwiftPM resolves `MobileTransport`'s binary target before any build script runs, for every
  scheme of `DispatchMobile.xcodeproj`, so the pinned Rust with its iOS targets and
  `build/mobile-ssh/DispatchMobileSSHCore.xcframework` must exist first. `scripts/setup.sh --mobile` (which
  `./build.sh --ios` and `test/run.sh --platform ios` run) does it through `scripts/setup_mobile.py`
  (`setup-ssh-rust.py`, then `build-mobile-ssh.py --fetch`, the only network step: the locked crates and russh's
  crate, which it stages patched into `build/mobile-ssh/russh`); `DISPATCH_SETUP_OFFLINE=1` fails with the command
  instead. Setup rebuilds the XCFramework whenever its headers differ from `Mobile/Transport/Core/include`, and stages
  russh whenever `build/mobile-ssh/russh` is missing or stale (offline from the cached crate). Existing checkouts run
  `python3 scripts/setup-ssh-rust.py` once.

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

### Bundle ids

Every bundle id starts with `DISPATCH_BUNDLE_ID_PREFIX` (`project-shared.yml`), `yachts.dispatch.pilot`: the Pilot
account's apps (`yachts.dispatch.pilot.app`, `yachts.dispatch.pilot.mobile`, `….mobile.watchkitapp`,
`….mobile.watchkitapp.widgets`, `group.yachts.dispatch.pilot.mobile`), the ones the GitHub release and Homebrew
publish. `build/signing.xcconfig` holds the team that signs them for a device.

### Release

`./build.sh --ios-device --release` and `test/ios-release.py` build the helpers with Cargo's `release` profile
(`DISPATCH_HELPER_PROFILE=release`); a plain `xcodebuild -configuration Release` uses the faster `local` one. Release
strips the executable after making its dSYM; the bundle is about 36 MB, 8 MB of it the three helpers. They are gzipped
(`helper/<name>.gz`, scripts/build-ssh-helper.py): App Store Connect refuses a Mach-O file that is not a bundle's
executable ("Invalid bundle structure"), and `HelperBootstrap.helper` expands the host's one before the upload, whose
size and SHA-256 are the expanded file's (`GzipMember`, shared with the Mac's `SSHHelperArchive`).
`test/ios-release.py` (`--simulator`, `--helper-profile local`, `--skip-build`, `--no-launch`, `--with-fast-suite`)
builds Release for simulator and device, checks the helpers' architectures and versions, Info.plist's device keys, the
privacy manifest, and that every required-reason API the executable imports is declared in
`Mobile/App/PrivacyInfo.xcprivacy`; the same for the embedded watch app. The fast suite cannot run against Release
(`@testable`, Debug-only demos). `./build.sh --archive` builds Release for any iPhone without signing
(`CODE_SIGNING_ALLOWED=NO`; Xcode signs iOS code only with a team); the Ad Hoc release signs and exports it
([releasing.md](releasing.md#iphone)). Not applied yet: deduplicating licence texts (2.8 MB), `-Osize` for app
code.

## Architecture and data flow

| Target | What |
| --- | --- |
| `DispatchMobile` | The app, bundle id `yachts.dispatch.pilot.mobile` + suffix (Bundle ids), iOS 26.0, iPhone and iPad. Embeds the watch app. |
| `DispatchMobileTests` | Unit tests hosted by the app: `Mobile/Tests` plus the Mac's Foundation-only tests by path. |
| `DispatchMobileUITests` | XCUITests, own scheme so unit runs never start the app. |
| `TermMobile`, `TermAppleMobile` | `Vendor/Term` and `TermApple` for iOS, without `Launch`, `Pty`, `Frames`, `Session`, `TerminalView`. Fonts are `TermFonts`: a top-level `Resources` folder breaks an iOS bundle's signature. |
| `MobileTransport` | Local Swift package (`Mobile/Transport`, see its README) over the Rust SSH engine. |
| `Dictation` | Local Swift package (`Packages/Dictation`) shared with the Mac; its Whisper engine is `Packages/WhisperEngine`, its Parakeet engine Core ML models it downloads. |

The iOS settings group sets `ARCHS = $(ARCHS_STANDARD)` (the project's native arch is the Mac's arm64e). Zstd is not
linked: `AppReplay` compiles for its types, but no journal ever starts.

### Shared sources

Mac sources the phone uses stay in `Dispatch/` and are listed by path in `project-mobile.yml` ("Shared with the Mac
app"). They change only by `#if canImport(AppKit)` guards or additive, behaviour-preserving helpers; `test/ios.py` is
the build that catches a Mac-only type leaking in. `Mobile/Shared/System.swift` stands in for the Mac's AppKit-only
`System` (a `SystemProvider` seam replacing it is deferred). Shared cores include:

- Chat transcript merge rules (`ChatTranscript`), displayed items and prompt confirmation; helper notification
  decoding, interaction replies and model menu/readback (`HelperChatTransport`). A model selection is confirmed only
  by the agent's subsequent state; a failed read never substitutes the requested choice. An uncertain question reply
  stays blocked until the helper resolves it.
- A turn's summary, steps and their folding (`ChatTurnSummary`, `ChatStep`, `ChatStepFold` in
  `ChatTurnSteps.swift`), with the times and token counts message details word: the phone's message details and bubble
  corners, and the Mac's message Info, read a turn the same way. Their colours and badges stay with each client.
- Inline Markdown parsing and safe-link filtering (`ChatMarkdownPolicy`), with an explicit Mac file-link allowance;
  count and UTF-8 byte limits on cached parses. Question selection, custom-answer validation, navigation and action
  availability (`ChatQuestionPolicy`) are shared. Selection uses stored choices, so commas in labels do not change
  which chips are selected, and an invalid custom answer never falls back to an old option.
- Helper capability groups (`HelperCapabilities`), hello validation/configuration and multiplexer descriptors.
  Platform grants and opt-in hello feature lists remain distinct; the phone still has no file-write capability.
- A Markdown file as a document (`FileMarkdownDocument`: paragraphs flowed, front matter, headings for the outline
  and folds) and how a page sets it (`FileMarkdownLayout`: the 36 em measure, six heading sizes, the gaps); the phone's
  `FileMarkdownReader` and the Mac's `FileMarkdownView` draw it each in their own fonts.
- Files wire shapes and error classification (`FilesWire`, `FilesSourceFailure`), strict UTF-8 prefix decoding,
  orientation-aware image metadata/thumbnail bounds, occurrence scanning, and naming a binary's format from its
  first bytes (`FileFormat`; every read bounds-checked). Preview byte/pixel limits stay with
  each client. Invalid trailing UTF-8 is rejected; only an incomplete valid scalar at a read boundary is trimmed.
- Git models, parsers, graph lanes, command construction and commit reads (`GitCommitReads`); untracked content and
  status enrichment; Review models, text and source policy. Staged content changed again in the working tree uses the
  index diff for Source and comment placement. A missing file is distinct from a failed or offline read.
- Statistics wire decoding and history buckets, spoken Markdown, dictation model instances, signature explanations,
  syntax scanning with each client's language/token profile, and font identities/catalogs.
- Theme parsing and linear-light classification (`TerminalTheme`, `ThemeColorMath`); a scheme with no definite side
  appears in both picker sections. Native fonts and views remain platform-specific.

The TermApple targets share surface configuration, renderer construction (including font features), pumping,
snapshot/search coordination and frame demand. Native display links, PTY/feed lifetime and transport ordering remain
in their platform adapters. The Dictation package is also shared.
Mac views built on the Mac chat stack are ported, not shared.

### Areas and seams

| Area | Directory | Owns |
| --- | --- | --- |
| Hosts | `Mobile/Hosts`, `Keys`, `Store` | Host, key and known-host stores, `HostSession(s)`, plain SSH shell tabs (`ShellSessions`), New host and Edit host, trust sheet |
| Tabs | `Mobile/Tabs`, `Mobile/App` | Shell, Spaces tree, a space's tabs, `TabScreen` and its header menu, the iPad split and strip (with the space switcher), the menu bar (`MobileCommands`) |
| Chat | `Mobile/Chat`, `Mobile/Agents` | `MobileChatSession`, Agents list, thread, approvals, queue, side conversations, New chat |
| Terminal | `Mobile/Terminal` | `TerminalHostView`, `TerminalFeed` (`PlainShellFeed` for plain SSH), `TerminalPresence`, key capsule, search |
| Transport | `Mobile/Transport` | SSH, auth, host-key delegate, exec and shell (PTY) channels, bootstrap, plain SSH fallback, reconnect |
| Code, Files, Commits, Reviews | `Mobile/Code`, `Files`, `Commits`, `Reviews` | Diff viewer and code composer; Files listing and preview; the Commits log; Review comments and sending |
| Stats | `Mobile/Stats` | `HostStatistics` per `HostSession`, the host sheet and popover |
| Resilience, Settings, Watch | `Mobile/Resilience`, `Settings`, `Watch` | Network watching, launch cache, background refresh, notifications; Settings; the phone's side of the watch link |

- `HostSession` is the one object the UI observes per host. Other areas get a `HelperClient` and `HelperTopology`
  from it (a `ShellOpener` on a plain SSH connection) and never see SSH: only `Mobile/Transport/Integration` imports
  `MobileTransport`, and the package stays platform-neutral. Every connection-state mapping is in
  `HostLinkMapping.swift`.
- `MobileComposition` is the root: on every `HostSessions.changed` (same main-actor turn) it feeds `MobileTabs.sync`
  and `ChatConversations.update`; Chat's urgency flows back into Spaces' dots. One `NavigationStack` holds the tab bar.
- **Identity.** Node, tab, space and backend ids change with every helper connection. Everything kept on the phone
  (activity times, seen markers, split memory, the launch cache) is keyed by host plus topology `key`. A cached or
  previous-helper snapshot is listed but not live (`topologyIsLive`) until the connection's first own topology. A new
  helper reports its first snapshots before its agent discovery has run: for 2 s after `ready` a terminal it reports
  unbound keeps the binding the kept snapshot showed (`HostSession.bindingGrace`), then the helper's own snapshot stands.
- Tests use one scripted peer over `Pipe()` (`ScriptedHelper`) and `ScriptedHostSessionDriver`.

### Transport

The engine is Rust `russh` 0.65.0 (`ring`, `rsa`) with one patch (`Mobile/Transport/Core/russh.patch`: every rekey's
host key goes through `check_server_key`, [security](security.md#dispatch-for-iphone)), behind a hand-written C ABI (`Mobile/Transport/Core`, crate
`dispatch-mobile-ssh`), built into an XCFramework by `scripts/build-mobile-ssh.py` in a minimal environment so Xcode's
settings cannot leak into ring's C build. The engine's `Cargo.toml` names russh by path, `build/mobile-ssh/russh`:
`scripts/vendor-russh.py` stages the published crate there (SHA-256 checked, kept in `build/downloads`) with the patch
applied, online from `build-mobile-ssh.py --fetch` and offline before every build (again when the patch or the script
changes; `--check` compares). swift-nio-ssh was rejected (Apple's has no RSA user keys or
keyboard-interactive; Citadel's fork signs RSA with SHA-1 only, refused by OpenSSH 8.8+), and ring over aws-lc-rs needs
no cmake. Third-party Rust enters only here; `helper/` stays dependency-free.

- Private keys sign in Swift (CryptoKit, Secure Enclave) through the external-signer callback and never cross the
  FFI. File keys are parsed in Rust. RSA signs `rsa-sha2-512/256`, never `ssh-rsa`.
- The host-key callback is answered later (`dms_reply_bool`), so the trust sheet can wait; the handshake deadline
  pauses meanwhile. Rekeys never ask: each must present the first exchange's key and algorithm, or the connection
  ends (`disconnected` with `DMS_HOST_KEY_CHANGED`, `SSHTransportError.hostKeyChangedAtRekey`: final, like a
  mismatch, so the host waits for Connect, whose connection checks the key as usual). `disconnected` fires exactly once.
- An exec channel is a socketpair fd pumped by Rust with backpressure both ways; `HelperTransport` reads it unchanged.
  A shell channel (plain SSH) is a session channel with a PTY; the package README specifies it.
- Limits: host certificates refused, user certificates not wired; no x86_64 simulator or Intel Mac slice;
  `panic = "abort"`; release-built even in Debug.

### Connection

`SSHHostSessionDriver` connects (host key through `KnownHostStore`), logs in, uploads the helper for the host's `uname`
to `~/.dispatch/bin/versions/<sha256>/` (or the runtime folder, [Helper contract](#helper-contract)), starts it, greets
it, reads `multiplexers.list` and `backends.list`, waits up to 2 s for the first topology, then is ready. It pings
with `echo` at once, then on the ticks of the shared 15 s clock that no stats sample covers (Traffic, below). A host
with its Helper switch off stops after the login, and a helper that cannot be installed, started or used leaves the
connection up without it: both are [plain SSH](#plain-ssh).

- **Traffic.** Everything the phone sends a host on a timer waits for the same clock (`HostTraffic`): 15 s ticks of
  the wall clock, the stats chart's bars. The stats' samples (`HostStatistics`, 30 s ticks under Low Power Mode), the
  liveness ping and the branch poll (`SpaceGitFacts`) end their waits on them, so every host's periodic frames leave
  together: while nothing else flows a cellular radio, which stays up about 10 s after a burst, can idle between ticks in
  the foreground (with the old 10 s ping beside 15 s stats it never did). A tick the stats sample on sends no `echo`
  (`HostPulse`): the sample's requests are the helper's frame for that tick and `stats.sample`'s round trip is the
  latency; a sample that gets no answer (refused before it left, or lost) sends the tick's `echo` itself. Without a
  sample on a tick (the background's linger, Low Power Mode's other ticks, a stats sheet's 2 s samples, which are off
  the clock) the ping goes, without waiting for the last ping's answer (it can sit behind a flood of output; the
  helper reads the request at once). So the helper hears a frame every 15 s (`stdio.liveness`); around a change (a
  sample cancelled just after the ping skipped its tick, the background, a connection's first tick, up to a second
  late) a gap can reach about 30 s, under the helper's 45 s. The SSH keepalive (15 s × 3) is the transport's own.

- Lost link or helper: `reconnecting` at once (keepalive 15 s × 3), backoff 1 s up to 60 s, raced by `retryNow()`
  (network change, foregrounding, pull to refresh; on a connected link it probes `echo` within 3 s, `:` on a plain
  one, and closes a dead one). Refusals (host key, login, missing key) are final; after a host-key mismatch nothing
  retries until the user acts. A failed attempt 5 minutes or more after the loss ends the retries too (about ten,
  `HostConnection.giveUpAfter`): the host is offline ("Stopped reconnecting after 5 minutes: …") with Connect, and a
  network change, foregrounding or pull to refresh starts a new run. Each connection decides again between the helper
  and plain SSH.
- Foreground connects every host, background disconnects: hosts still on their way at once, connected ones after 25 s
  of background time (`HostSessions.lingerLength`, `beginBackgroundTask`; sooner when iOS takes the time back), so a
  switch to another app and back keeps the connections; returning, each checks with `echo` that it still answers.
  **Disconnect** in a host's sheet (`HostSession.park`; also
  while connecting or reconnecting, where it stops the retries) leaves the host alone until a
  Connect or Reconnect the user asks for (`connectByUser`); nothing else (network changes, pull to refresh, background
  refresh, watch requests, a relaunch) lifts it. It is saved with the host (`HostRecord.parked` in `hosts.json`).
- **Which multiplexer.** Connecting never starts a server. herdr's `backends.open` starts one, so herdr is followed
  only while its server runs. Automatic prefers running herdr, otherwise tmux; an explicit herdr preference waits
  for its server without opening it. Discovery and failed follows retry every 2 s. A preference change switches
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

- **Ping.** With `stdio.liveness` the helper exits after 45 s without a frame; send one at least every 15 s (`echo`,
  or a tick's stats sample in its place, Traffic above). A drop
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
- **Steady sizes.** The hello names `sizes.steady`: attaching a tmux terminal at the phone's size resizes its window
  alone. Without it tmux sized every other window of the session to the helper control client's default 80x24
  (whichever window was current, and all of them when nothing else was attached), on the Mac too, and each redrew.
- **Bound first topology.** The hello names `topology.bound`: a tmux server's first topology waits (at most 1 s) for
  the helper's agent discovery, so a reconnect's tabs come back as the agents they are, not plain terminals the next
  topology turns into agents. herdr's still come unbound first; `HostSession.bindingGrace` covers both.
- **Reattach by key**, not id: after reconnecting, `backends.open`, find terminals by topology key, then `chat.open`
  and `terminals.attach` again.
- **Follow binding changes.** A Codex conversation gets its thread id with the first prompt; reopen `chat.open` on a
  new binding. `chat.open` answers with a `chat.history` notification and `backends.open` with `backend.opened`, not a
  response frame.
- **Re-enable integrations per connection.** `installation.install` state is in helper memory: every connection with
  Chat on installs Claude Code's and Codex's hooks and Pi's extension (inert outside the terminals Dispatch can show:
  [security](security.md#agent-chat)); New chat installs a missing one before it starts. A per-host refusal given on the Mac stays on the Mac; the phone's consent is its Chat switch.
- **Surface native trust steps.** Codex shows "Hooks need review" after the helper installs hooks; until the user picks
  "Trust all" in its terminal, approvals stay in Codex's TUI. While one waits there (the helper's `chat.state`
  `dialog` "approval") the thread and the watch say so and how to bring the next ones to the phone; otherwise nothing.
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
  An unreadable `known_hosts.json` fails closed, never read as empty. New keys are ED25519 or Secure Enclave P-256.
  Software keys (ED25519, imported), passwords and passphrases are `AfterFirstUnlockThisDeviceOnly` and the app's files
  class C, so connecting, reconnecting, background refresh and watch requests log in without a prompt, also while the
  phone is locked; only a Secure Enclave key asks Face ID (the enclave's access control, at each signature) and never
  signs unattended. Software keys older builds kept behind `biometryCurrentSet` move once, at their first use in the
  foreground, with one Face ID prompt for all of them (`KeyStore.moveFaceIDKeys`, copy first so a cut-short move loses
  nothing). A new host takes the colour the fewest hosts show and keeps it until Edit host's Color picks another
  (Automatic gives back the free one); colours are drawn per machine (`HostColorStore`). Two hosts reaching one machine and account show its spaces and agents once,
  under the first in the list (`sameMachine`), as the Mac keys a host by machine and uid.
- **Windows.** A window at least 600 points both ways (the unfolded iPhone Duo) or an iPad window from 655.5 points
  wide shows the Spaces tree in a sidebar beside the open tab (`MobileSplit`, by window size, never size class or
  screen); narrower windows are the phone's stack. Both columns show the one `SpacesNavigator.path`, so folding and
  unfolding keep the screens. The unfolded Duo held as a book gives the sidebar the iPad's 320 points and the tab the
  rest, across the fold (`MobileSplit.bookSidebar`); its tab's header is the phone's without Back. The iPad's detail
  column has a strip of the space's tabs and one mode button (`PadStrip`, `PadModeButton`, `PadMode`): the shown mode's
  glyph, with its title where the column is 640 points or wider, whose menu lists Terminal, Chat, Files, Review (its
  comment count) and Commits, as the Mac's and the phone's do; the sidebar can hide (⌃⌘S) and comes back when no tab is
  left. An iPad remembers the shown tab, mode and sidebar state across launches (`restoreSplit`, before the first
  body), keyed by topology key. The vertical bar of iOS 27.1 is off on windows wide enough for the split
  (`MobileVerticalBar`).
- **Landscape.** A phone's window wider than tall that does not split (every iPhone on its side, the Duo's cover
  screen; `MobileLandscape`, by the window's size, which the keyboard does not change) gives a tab the whole window:
  no navigation bar, no capsule, no composer row, no key capsule at rest. The chrome is one rail (`TabRail` in
  `TabScreen`) on the Dynamic Island's side, which follows the interface's orientation (`MobileOrientationReader`),
  its glass 2 points clear of the island: the padding is the island's safe-area inset less 10 (`MobileLandscape.
  railInset`; the inset measured from the window with its size, `MobileWindowReader`): 52 where it keeps 62 (iPhone
  17, 18 Pro, Pro Max), 58 on the Air, whose island sits 6 points lower (68), 37 for the 17e's notch (47); the content
  runs into the other side's inset to 12 points from the
  glass. The rail holds Back with the needs-you count and the menu disc, the five modes stood on end (`PadModeSwitch`),
  and the mode's action at its foot: Terminal's keyboard button (a tap raises the keyboard with the key row riding it;
  held, Esc, Ctrl-C, Ctrl-D, Tab, Previous Command and Paste), Chat's Reply (the composer while empty and unfocused is
  folded into it; Reply unfolds and focuses it), Review's Create review with the comment count (`FilesRailAction`); a mode without one (Files, Commits, Chat with
  its composer open) keeps the foot's place empty and the rail spans the window's height, so the modes never move.
  Above a docked keyboard the rail keeps only Back and the disc. Review and Commits list beside their panes (a
  300-point list headed by the mode's row); Files lists under its row. The tab's title capsule (the upright header's, without its menu) shows for 2.5 s as
  the tab opens. The segment and Files mode chosen on its side are the ones upright shows. Mockups L12–L15.
- **Spaces.** herdr workspaces and tmux sessions are spaces; windows and tabs are tabs. A split tmux window shows one
  pane; the phone never splits. The helper's native multiplexer never counts (its sessions die with the connection).
  Close Tab ends the tab, unlike the Mac's (whose busy tabs detach): a tab whose every pane runs an agent with its
  turn over (idle, or a result not yet seen, as Chat knows it live) is terminated at once; otherwise `close.request`
  `check` asks the helper, and verified idle work is closed through `prompt`, while busy work, or a check the
  multiplexer cannot answer, asks first ("Close “name”?" naming the agent and its state or the program; Terminate).
  A phone's Detach only hides the tab on that connection (the helper's per-connection selection; the Mac keeps it,
  and it is back after a reconnect), so the swipe offers Close alone and Detach stays in the tab's menu. A space
  offers Detach and Terminate… and never ends by itself. Tab names, space names
  (`usesDirectoryName`, kept on the server) and the Activity sort follow the Mac. New tab sends no folder, so the
  multiplexer opens it in its focused pane's directory. New space (the tab bar's New in Spaces, the host's line and
  its quick menu) always makes a space of its own with one shell tab and opens it over the space's screen; its tab
  counts only once it shows in a space that was not there before (a tmux window placed into a new space is waited
  for, one left in an existing space is closed again), so a space with the same folder or name is never reused. A space
  lists its tabs by activity (their times, below): most recent first, tabs with no time yet last, ties in server order;
  the iPad strip keeps server order. A
  space's Edit renames the space and its tabs in place (`entities.rename`) beside reorder and close, its rows in server
  order. Reorders go to the server (`memberships.move`) and the rows
  keep the new order until the answer or a snapshot naming the moved tab. In the Spaces list a space's long press is
  its menu, as a tab's is (`SpaceMenuItems`, the space screen's "…" too): New tab, Rename…, Edit Spaces, then Detach and
  Terminate… (a Shell space: Close all shells); dragged from there, without Edit, a space dropped on another of its
  host's takes that one's place (`SpaceDrag`, `MobileTabs.moveSpace`). The spaces' order is this device's, as Edit's
  handles keep it. Paths shorten to `~` by
  `hello.account.home` and `login_home`, never by guessing `/Users/<name>`. A host shows one multiplexer's spaces at
  a time; hosts not connected nor on their way go to the OFFLINE group.
- **A tab's header** (phone stack, B7), as Messages heads a conversation. Back is its own glass circle at the leading
  end: it carries the needs-you count as a badge on its corner, and VoiceOver reads "Back to <screen>" and the count as
  its value (other pushed screens keep their labelled pill). Beside it one glass capsule holds the host's glyph on a
  disc of its colour, the tab's title and `host · folder` under it, one line each (a long title truncates; VoiceOver
  reads all of it); a tap opens the tab's one menu (`TabMenuItems`, the landscape rail's and iPad's disc opens the
  same): on Chat Search, the host's Stats, Side Conversation (read-only; one with changes is the composer's `/side`)
  or the open one, and Manage goal; elsewhere Stats first; the pane picker when the segment can show more than one pane
  (on Chat only the panes running an agent, the shown one checked); the tab's row menu (Rename…, Detach, Close Tab). The
  folder in `host · folder` is its last component;
  Terminal adds `· shell`. The same `host · folder` (the
  folder's name, never its path) heads a space's screen, the switcher's space and the iPad's header beside its sidebar,
  names a space on the watch (its Spaces rows and a space's header, `SpacesText.folder`), and is a tab row's line when it has
  nothing else to say; a folder whose name is the title beside it goes unsaid (the host alone, never "app" under "app";
  `TabScreenHeader.distinct`), and VoiceOver reads the full path. The Mac's hover card leads with it too. The trailing control is the mode
  button (`TabModeButton`), as the Mac strip's: a system bar item, a menu (so the bar draws its glass; a button-style
  Toggle draws on as a pink prominent disc and takes no menu). A tap opens it on every segment, as the Mac's click
  does: Terminal, Chat (dimmed without an agent), Files, and Review (with its comment count) and Commits inside a
  repository, the shown one checked; VoiceOver reads it as Mode, the shown one its value. On Chat or Files it is on,
  its symbol filled in the accent; in Terminal it is off, its outline in the label colour naming where the tab would
  go: Chat on a tab running an agent, else Files.
  Conversation mode's waveform takes its place while on. No switch sits under the header, in Files neither: Files,
  Review and Commits are the mode button's menu, its glyph the shown mode's (the folder, Review's clipboard, Commits'
  clock), and the mode's accessory (Create review, offline) sits in a glass capsule at the bottom (`TabFilesSegment`). The
  header never overflows into the bar's "…" menu (`TabsScreenHeader.leadingWidth`). The phone has no space switcher
  (Back returns to the space); the iPad strip's space capsule opens it. Beside the unfolded Duo's sidebar the header
  is the same without Back (its title capsule holds the conversation's items and the panes); the iPad strip has its
  own mode button and a phone on its side its rail.
- **Times.** A chat tab's time is its agent's newest record (the conversation's own timestamps). A terminal's, and a
  chat's whose agent has written nothing yet, is the last change the phone saw between two live snapshots of one
  connection: a new title (shell integration names a pane after the running command, then its folder), folder, agent
  or window name; kept per host and topology key (`TabActivityStore`). Changes found across a gap (cache against live,
  a reconnect) happened at an unknown time and move nothing. The server's output times (`terminals.activity`, tmux's
  `#{window_activity}`) are not used: any resize redraws a window, and one control client sizing one window resizes
  its siblings, so every tab beside the one just opened read "now".
- **Files, Review and Commits** read only, through `MobileFilesSource` and `ReviewGitReader` (never `file.write`),
  only with a connected helper and the Files & git grant; their exact commands, bounds and cadences are the ones
  [security](security.md#dispatch-for-iphone) lists, and the Mac's shared parsers and placement rules apply. The
  repository and branch of a folder are `SpaceGitFacts`, once per folder and connection, the branch on the shared 15 s
  ticks (Traffic) only while something shows it. A review is one per host and repository root
  (`ReviewPlace`, `reviews.json`, the Mac's format); Send finds every comment's lines again first, goes through the composer's routing, and leaves the comments
  in place until confirmed; Undo (60 s) withdraws a queued review and the watch mirrors only that Undo. Open in
  Terminal types into the shell only while its program is a shell with no full-screen program up, never for a folder
  name with control characters, and only on tmux (herdr sends its own rendering of a pane, so the program's modes never
  reach the phone): it attaches the pane's terminal through the current connection (held output follows again), waits
  up to 5 s for the server's screen of now (the attachment complete, or after a hold the helper's answer to it and the
  repaint since, all parsed) and reads the alternate screen and bracketed paste from that, awaits the helper's answer
  to the input (10 s for all of it), and shows Terminal only once it was taken and while the preview is still shown;
  leaving the preview stops it before anything is typed. A refused send says it did not reach the terminal, one with
  no answer or an uncertain one that it may have; neither is retried. The phone checks the screen the helper had sent
  when it answered: a program that takes the pane after that (a command typed just before) still gets the `cd`, a
  window only the helper could close. A binary shows what its first bytes say it is (`FileFormat`, the Mac's: "ELF
  64-bit LSB pie executable, arm64"), else its kind by name, and its size. Share, Save to Photos and Attach to chat take
  only the whole revision the preview read, with the helper's metadata (off while loading, failed, offline or a
  folder): a file past the limit, a short read or a file changed since fail instead of sharing part of it. Share and
  Save to Photos copy it to the phone first (`FilePreview.download`: up to 4 GB, in 8 MB reads of that revision, the
  More button spinning meanwhile, cancelled by leaving the preview, the copy removed after); Save to Photos is offered
  for images and for videos by name (`.mp4`, `.mov`, `.m4v`), which Photos imports from the copy. Such a video shows
  its name and size with Play: nothing is read until it is tapped, then the same copy is made and plays in the system
  player (`VideoPlayer`); leaving the preview stops it and removes the copy. Attach to chat reads the file
  into memory (up to its attachment limit). A path that
  turns out to be a folder (the helper's `is_directory`) shows its listing. A folder row's item count waits while the
  host is offline and is asked again when it reconnects, for every row still on screen in their order (four at a
  time, none dropped).
- **Markdown files** render as a page, as the Mac's preview does (`FileMarkdownReader`, the shared
  `FileMarkdownDocument`): prose two points over chat's text in chat's font (San Francisco for Same as code), scaling
  with Dynamic Type, at most 36 em wide; six heading sizes; code highlighted, tables and quotes in the Mac's rhythm. A
  tap on a heading with a section folds it ("…" after its title) and another opens it; "…" › Outline lists the
  headings, goes to one (opening the folded sections around it), and has Fold All (a lone title stays open) and
  Unfold All. Folds belong to the screen. Show source still shows the file's text, with Find and Wrap lines.
- **Chat.** `chat.open` only for a bound terminal; the conversation is accepted once `chat.history` names the same
  process. Losing link or binding pauses input and keeps transcript and drafts. Dots follow Mail: blue for needs you
  or unseen, amber for working; a conversation's first sight is its baseline; seen markers stay per device. Needs you
  is an open approval or question or the agent's own attention, as on the Mac. A command (`/…`, `!…`) goes at once
  when the agent is idle, otherwise queues (`/…` in the helper's queue, `!…` on the device until it reaches the head
  of an idle queue). Queued messages belong to the agent process they were typed for; Stop pauses the device's own
  until Resume, and Send now refuses paused or uncertain ones. Side conversations (`/btw`, `/side`) are forks the
  helper lists; a lost link ends one on the phone and the next verified connection closes the orphaned fork
  (`closeOrphanedSides`). Background shells the agent reports (`State.shells`, Claude Code) show as a line over the
  composer while any runs (one names what it does, more say how many); a tap opens a sheet with each shell's
  description, command and running time, which closes with the last shell. Attachments are offered only while the helper accepted `chat.attachments` and the
  conversation is verified; images lose their metadata before upload, uploads are session state, and a queued
  message counts as delivered after a reconnect only with as many attachments. Times stay out of the bubbles' corners
  and appear on a swipe (`ChatReveal`, below). A turn's last reply shows its step count above its time; changed files
  and line counts stay in message details. VoiceOver still reads the full summary (changed files, read files or steps, then when the turn
  ended) as the bubble's value (`ChatCorner.swiped`, `spokenOnly`); other replies read their own time, and Claude's
  and Pi's thinking has none. Once a turn ends on a reply its thinking leaves the thread (`ChatThinkingFold`, shared with the Mac and the watch) and message details list each thought as a `Think` step that pushes its whole text, counted apart from the tools ("4 · 1 thought"); a turn stopped or failed before a reply keeps it, and a side conversation, which has no details, keeps it too. A turn seen ending live holds its thoughts for 1.2 s, then they fade; a reader scrolled up holds them until they return to the end or the next turn starts. Message details keep "12 steps · 2m 4s"; a steps summary's time under 5 s is left out ("2 steps", `ChatTranscript.summaryElapsed`), on the Mac's step groups and the watch too, while a step's own row keeps its time. While a turn runs the
  working row (M5a) stays under the thread, its answer begun or not; its count and unfolded log are the steps since the
  agent last wrote (a message or Claude's or Pi's thinking), as the Mac's live tool group counts them, and it holds Stop
  beside the elapsed time, away from the trailing controls (the composer's slot stays the mic; Esc from a hardware
  keyboard still stops). Its log's kind badges are all as wide as the widest word, so what each step acted on starts
  at one place. A step opened there or from message details shows what it did as the Mac's opened step does
  (`ChatStepOutput`, from the shared `ToolPresentation`): its title, summary and status, folder, the command unless the
  summary says it, changed files' diffs, the output (a read's source at its own line numbers) with Copy, and Tool
  details with the raw input and output. Queued messages (M5c) are the user's own bubbles, faded, at the thread's end under the working row, as
  Messages' Send Later (`ChatQueuedBubbles`; while the link is down the same bubbles, held): under the last, "3 queued ·
  sends after this turn" (with Resume after Stop), under one that waits for the user its status. A tap or long press
  on one is its menu, each action named: Send (paused or uncertain), Send Now ("Interrupts the current turn" while the
  agent works), Edit, Move Up and Move Down, Delete. Edit loads it into the composer (`beginQueueEdit`): the draft
  there is set aside among the saved drafts, a bar says "Editing queued message" with Cancel, and send is ✓, which
  saves the text in its place (`queue.update` by revision) and brings the draft back; a message that went out
  meanwhile keeps the edit as the draft, with a note. Leaving the conversation cancels the edit. An agent this phone starts (New chat, New
  tab's agents) shows a spinner on Start or New tab until its tab shows, then "Starting Claude…" in the thread until
  the conversation is verified (at most 15 s), as the Mac covers a launch until Chat opens. Opening a conversation says its stage (`ChatLoadingLine`): "Opening conversation…" until the helper answers, then "Reading Claude's transcript…" while it reads (`history_pending`), with the seconds from the third on; the helper reports nothing finer. Menus a long press opens (send's options, the mode button's modes) and the tab's menu give a medium tap as they open (`menuOpenHaptic`), as the system's context menus do. Records and busy state
  arrive apart: for 3 s after the agent stops the row stays until the turn's end comes, and after the turn ends a busy
  state that ran through it keeps the row away, so the row goes as the summary comes; busy work that starts after the
  end (another device's prompt) shows the row at once, and a turn left open by an idle agent shows neither.
  The thread follows its end until something other than the app scrolls it toward older rows (`ChatFollow`): a drag
  stops following as it starts, and VoiceOver's scroll, the status bar's tap or Page Up leave it too; rows, the keyboard
  and the composer changing height never do (the thread goes back to the end, exactly: following, the scroll view sits
  at its last row whatever the rows' real heights turn out to be, `pinToEnd`), a drag that only took the keyboard down
  keeps following, a send or the pill returns to the end, and "Jump to latest" shows only while not following with
  newer rows below, never at the end. Left scrolled up (the space, a segment switch), the thread opens again where it
  was read (`MobileChatSession.readingPosition`, in memory): the row at the visible top and how far past its top, kept
  when a scroll stops and when the thread goes; it draws from that row, puts it back through the first layouts (the
  navigation bar's inset comes late) until the user scrolls, does not follow, and the rows that came meanwhile count
  into the pill. Left at its end, or with that row gone, it opens at its end, the queue and working row under it.
  Opening a thread draws only its last rows, about two screens by an estimate from
  their text (`ChatThreadView.tailStart`): the stack is not lazy, so rows keep their real heights for following the
  end, and drawing the whole page made opening a tab take half a second. When the user's scroll comes within half a
  screen of the top, older rows the phone holds draw above in steps while the thread keeps its distance from the end,
  so the rows being read stay put; past the first of them the helper's earlier page is asked for (`chat.page`), never
  on opening. Drawn while not following, they move the scroll view's offset by their height (a finger still
  dragging included); following, the end stays in view. Parsed bubble text is kept per text and font
  (`MobileChatMarkdownView.contents`). Send's tap sends as the draft goes now; its long press only presents what the tap
  can do: Send; Send now and Queue while the agent works; Queue alone while the tap queues and the agent cannot take it
  into its turn (terminal not attached, not verified, a command waiting for an idle agent: "Send" would promise what
  the tap does not do); "Complete /…" with the slash list up and "Open Terminal" for `/terminal`. Settings › Chat ›
  While the agent works (`MobileSettings.chatSendWhileWorkingKey`, the Mac's Chat mode option) can make the tap Send
  now while the agent can take the draft into its turn; Queue in the long press (and ⌥⌘Return) then queues it.
  Hardware keyboards follow the Mac: Return sends in compact mode, Option-Return and Shift-Return insert a newline,
  Command-Return and Control-Return send in either mode, and Command-Option-Return takes the alternate send action
  (steer by default, queue when ordinary send steers). A draft starts out of editor mode; a multi-line paste or ⌘E turns
  it on, and a typed newline leaves it as it is. Settings ›
  Chat's other options, as the Mac's Chat mode: Open agents in (an agent tab's first segment,
  `TabSegment.initial`; a pick on the tab sticks). A hardware keyboard's first Esc arms the stop for a second, shown
  above the field; a second Esc stops the agent. There is no Escape setting, and its removed saved choice is ignored. The code keys above
  the field show only once picked under "+" (Show code keys, `MobileSettings.composerCodeKeysKey`, kept app-wide; not
  offered with a hardware keyboard). Dragging the thread down onto the composer, or on into the keyboard, takes a
  software keyboard down (`ChatKeyboardDragDismissal`; a hardware keyboard's focus stays). The hairline's glint is the
  light on "thinking": one 2.2 s ease-in-out sweep, leading to trailing, the label lit where and while the glint passes
  over it (`ChatThinkingSweep`, `ChatSweepTrack`). The thread's loops (the ◆'s breathing and satellite, the glint and
  the light, the reconnect banner's dots) run in Core Animation (`CompositorView`, Mobile/Chat/ChatMotion.swift): SwiftUI
  draws their still artwork once, the compositor moves it at the phone's `MotionRate` (the ◆'s breathing and the dots
  30 fps, the satellite and the sweep 60, everything 30 in Low Power Mode, where the glint and the light stay off: `MotionRate.decorates`), and nothing runs in the background, while
  the row is scrolled out of sight or while a sheet covers it (`coversLoops`: the thread's own sheets and preview, the
  shell's sheets, a host's stats sheet). The background is followed from its notifications (`applicationState` still
  reads background when `willEnterForeground` arrives). A row scrolled under the translucent composer counts as shown. As `TimelineView(.animation)` loops they cost about 12% of a core in the app and as
  much in the render server at 60 Hz. With Reduce Motion they stand still; tests draw a chosen instant
  (`animationDateOverride`) in SwiftUI, the frame the loops show then.
  The thread runs on under the header and the composer (a bottom `safeAreaBar`), with the soft scroll edge at both,
  as the side conversation's: left to the system, an iPhone drew the header's edge as the hard one (an opaque band
  ending in a line) where the simulator drew the soft one.
  Conversation mode starts from "+" (Conversation Mode) or a long press on the mic
  (`MobileVoiceConversation`); it is half-duplex as the Mac's and never grants permission by voice. Read Aloud, in a
  message's long press and in message details' ⋯, reads that one message in the system's voice
  (`MobileMessageReader`): all of it, Markdown's marks gone, each code block and table said in a few words instead of
  read ("Swift code, 12 lines.", "Shell command.", "A table, 3 rows."; `SpokenMarkdown.message`). "Reading aloud ·
  0:08" and Stop show under the message; another message's Read Aloud takes over, and leaving the conversation stops
  it. It is spoken audio that ducks other audio, and hides while conversation mode reads replies itself. Both speak
  in Settings › Chat › Voice (`SpeechVoice`, `MobileSettings.speechVoiceKey`): by default Spoken Content's voice,
  speed and pitch from the Settings app (`prefersAssistiveTechnologySettings`), which is also the fallback when the
  chosen voice is deleted; or one of the phone's voices by identifier, listed for the user's languages without the
  novelty voices, grouped Personal Voice (after its permission), Premium, Enhanced and Default, a tap playing a
  sample. Both keep
  the phone from auto-locking while they run (`ScreenAwake`): the lock would send the app to the background, where it
  may neither listen nor speak and conversation mode ends. Composers are
  `ChatEditorTextView`-based, as on the Mac.
  A reply or Pi's thinking streaming into the live turn, or a short Claude Code post, types out as on the Mac (docs/architecture.md, Typed reveal;
  `MobileTypedMarkdown`): a text renderer draws its caret, and a bubble that hugs its text is as wide as what has
  arrived from the first frame.
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
- **The host sheet** (`HostStatsSheet`) is a host's one screen besides Edit host: the host's disc, name and status line
  ("macOS 26.1 · 18 ms") with the Edit pencil at both detents. The small detent (the screen behind it still usable)
  shows the stat strip and Disconnect, or offline the connection list and Connect; the large one adds the processes,
  the banners and the connection list (Address "user@host" with a port that is not 22, Key, Multiplexer, leading to
  the install hint when the host has none) over the same one action. The disc in Spaces, Info in edit mode and the
  switcher's host row open it; an iPad's host glyph opens the same content as a popover (I5). Everything the user sets
  is Edit host's (New host's form with the host's Color and, last, Remove host), saved with Save; Files' Change
  integration… opens Edit host directly.
- **Host stats.** `HostStatistics`, one per `HostSession`: `stats.sample` on every 15 s tick of the shared clock in the
  foreground (one per chart bar, Traffic), every 2 s while a sheet or popover shows the host, 30 s under Low Power Mode
  (a bar without its own sample takes the next one, `barHold` 35 s). `stats.processes` (some 100 KB from a busy Mac)
  only with a viewer's samples, the first at once when the sheet opens; `stats.disks` with a sample at most every 15 s
  while viewed, every minute otherwise; a sample's requests go out together. Nothing in the background, on plain SSH
  or before something shows the stats. Numbers are `live` only after the connection's own
  first sample; the last sample and 15 minutes of history stay through a drop, stale. Red thresholds are the Mac's
  (CPU 90 %, memory 90 %, disk 80 %). The watch reads `summary(at:)` through `WatchHostStatsFeed`, at most one change
  per 15 s ([watch](watch.md#seams)).
- **Resilience.** `host-cache.json` (last hello, multiplexers, topology, Agents rows with ≤280-character previews, a
  plain host's shell tabs without screens) is read synchronously at launch so the first frame lists every host; live
  data reconciles in place and cached files decode leniently per entry. Pull to refresh calls `retryNow()` on every
  host and waits at most 10 s. Each host's last update (`HostSession.updated`) is shown for an offline host and read by
  VoiceOver.
- **Background refresh.** A `BGAppRefreshTask` (`<bundle id>.refresh`), off by default. It connects hosts with Chat
  and the helper on through a session that asks nothing (Secure Enclave key hosts, a key an older build left behind
  Face ID, and parked hosts are skipped), reads
  `chat.list`, notifies as Settings allows (`AgentAlerts`), sets the badge, and ends within 25 s. It never touches
  seen markers.
- **Notifications** (`AgentAlerts`). Events between two looks at a conversation: newly needs you, Finished (was busy,
  now idle and not waiting), Failed or disconnected (was busy, and its agent left the terminal or the terminal closed
  in a live topology). While the app is open the same banners post for live rows only, except the thread on screen, a
  muted conversation, a terminal the user closed from the phone in the last minute, or a stop the agent recovers from
  within 10 s. Permission is asked once a run. There is no Allow or Deny in a banner: an approval belongs to a live
  subscription.
- **Settings.** Everything is `MobileSettings` in UserDefaults. Removed `terminal.contrast` and the `chats` filter are ignored; use `terminal.textContrast` and `agents`. Spaces reads per-host state only from `spaces.json`, without importing the old `tabs.recent`, `tabs.collapsed` or `tabs.spaceOrder` defaults (Remove all data still clears them). The Settings app's Dispatch page
  (`Mobile/App/Settings.bundle`) mirrors the fixed choices on the same keys (appearance, line spacing, the
  terminal's contrast, ligatures, bold, cursor, chat's font and size, the notification switches and sound, colour
  vision, Color-code hosts, unsafe pastes; not the font lists, colour schemes, dictation or background refresh, which need live lists or a permission
  prompt). What it changes arrives as `UserDefaults.didChangeNotification` when the app is back and goes through the
  setters (`MobileSettings.reload`), so terminals restyle and notifications follow; `SettingsTests` keeps the page's
  values and defaults equal to the models'. Per host (Edit host, not Settings): Chat, Files & git, multiplexer. Unsafe
  pastes sit under Hosts. Terminal
  font (`TerminalFont.all`: the Mac's list in its order, Source Code Pro, Menlo, then every font the Mac bundles, in
  `TermFonts`), Ligatures (on, the Mac's `fontLigatures`: off writes `font-feature = -calt, -liga, -dlig`), colour scheme (Ghostty's bundled
  themes and Dispatch's two, by side and `SchemeGroup`: Dispatch, true black, leads Dark · OLED, Dispatch Gray leads
  Dark · Graphite; `dispatch-black` by default and kept in light mode), contrast (`TextContrast`, shared) and line spacing
  (`LineSpacing`, shared, one key for terminal and chat); each change posts `TerminalStyle.changed` and every open
  presence restyles at once, keeping its own size. Terminal font size: 12 on iPhone, 14.5 on iPad, kept as the size
  at the standard text size and drawn scaled as body text scales (`TerminalAdaptation.fontSize`, capped at XXXL's
  ×1.32); a text-size change moves every open terminal by the change; every font at Source Code Pro's apparent size
  (`TerminalFontScale`, shared). Chat font and text size (`ChatTypography`, following Dynamic Type). Times on swipe
  (`ChatReveal`, always), as Messages: nothing in the bubbles' corners, the text keeps no room and VoiceOver still
  reads a reply's corner (time, or the turn's summary) as the bubble's value. A drag toward the leading edge (a pan
  that begins only sideways, so scrolling is untouched) slides the user's messages over by a 72 pt column plus its
  16 pt gap, then a fifth as far, their times coming in after them (`ChatRevealSent`); the replies stay put and their
  times fade in at the trailing edge in the room the bubble leaves, on two lines where needed, the turn's last reply's
  under its step count ("23 steps"; what it changed is the message's details') (`ChatRevealReceived`). Letting go
  hides them again, in the thread and the side conversation.
  Colorblind-friendly (`colorVision`, the Mac's `ColorVision`, red-green or blue-yellow): hosts take that vision's
  colours (`HostColor.look` through `HostColorStore.shared`, the watch's tints too), added and removed (diffs, counts,
  git's A and D) the green and red of the vision's first bundled light or dark scheme (`ColorVisionTrait`,
  `UIColor.change`), Color scheme lists only the schemes made for it (`ColorVision.bundledSchemes`, shared), and
  turning it on, off or over swaps the terminal's scheme for the vision's on the same side, or `dispatch-black`.
  Color-code hosts (`hosts.colors`, on) off draws every host gray, as the Mac's `showHostColors`.
  Notifications (the app icon's badge always counts the conversations waiting for you), Background refresh, the Apple
  Watch status row. There is no app theme: the chrome and chat take the asset catalog's colours for Appearance, and
  only the terminal has a scheme. Whether Spaces lists the offline hosts is its filter menu's (Show offline hosts),
  not a setting.
- **Appearance.** Dark by default, every colour with a light variant. System menus and segmented controls replace
  the mockups' custom ones.

**Debug hooks** (compiled out of Release). Environment through `SIMCTL_CHILD_`: `DISPATCH_MOBILE_STORE=memory`
(nothing saved, no Face ID), `DISPATCH_MOBILE_SCRIPTED=1|empty|trust|mismatch|nomux` (scripted hosts, no SSH),
`DISPATCH_MOBILE_DEMO=1` (the demo hosts), `DISPATCH_MOBILE_CHAT_DEMO=<screen>` (with
`DISPATCH_MOBILE_CHAT_DEMO_ECHO=<seconds>` its peer answers what is sent, streamed after that long), `DISPATCH_MOBILE_AUTHORIZE_KEYS`,
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

- **The Helper switch** (`HostRecord.helper`, on by default) is in New host and Edit host. Off turns Chat and
  Files & git off with it and hides them; Spaces marks such a host "Plain SSH". Turning the switch on, or off on
  a helper connection, reconnects; turning it off on a connection that is already plain keeps the shells. With the
  switch off the driver stops after the login: no probe, no upload, nothing in `~/.dispatch`.
- **Fallback.** With the switch on, a helper step that fails while the SSH connection stays up leaves the connection
  as plain SSH with the failure's text (`SSHHostSessionDriver.fallback`): an unsupported or unidentified platform, a
  missing bundled binary, an upload or cache failure (a transient one tried once more), a refused exec channel, a
  helper that exited before greeting (after the one runtime-folder retry) or is unusable (`hello` failed, another
  protocol version). Login, host key and missing-key refusals stay final, and a connection that dropped meanwhile
  is a loss that reconnects; an ambiguous failure is first checked with the `:` probe. The host sheet's card then says
  "The helper could not start on <host>: <reason>" with Try again and **Use plain SSH**, which turns the switch off.
  Each connection decides again.
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

## SwiftUI and UIKit pitfalls

Found while building the thread and its animations; each cost a debugging session.

- **Scrolling.** `onAppear` in a non-lazy `VStack` fires at once for every row. `onScrollVisibilityChange` never
  reported a child visible after a programmatic `setContentOffset`; scroll geometry does. `defaultScrollAnchor(for:
  .sizeChanges)` does not hold after a drag, so rows drawn above the reader move `UIScrollView.contentOffset`
  explicitly (`ChatScrollViewProbe`, `grew(by:)`). SwiftUI's `ScrollGeometry.contentOffset` is UIKit's raw offset:
  add `contentInsets.top` to compare with the end.
- **Pushes.** A pushed thread lays out at its end with no top inset; the navigation bar's inset arrives later and UIKit
  lowers the offset by it, which reads like the user scrolling up (`ChatFollow.moved(resized:)` ignores drops while
  insets or the container height change). Mid-push geometry is inconsistent, `onScrollGeometryChange` can merge
  changes, and on a device that sample can come before the probe attaches (the simulator never does this), so the
  probe re-applies the end on `didMoveToWindow`. On a device, tapping the composer is a quick check: a snap to the end
  means the thread was still following. A `@State` set in the tap that pushes reads stale in the destination's first
  body (same update): pass such decisions through a plain `@MainActor` object.
- **Animations in the thread.** Height changes inside the thread cannot animate: the scroll content lays out at once
  and an inserted card draws over the composer. Snap the layout and fade or transform only the inserted view
  (`Transition.animation(...)`), or animate only same-height changes. `withAnimation` around a session call animates
  every view reading that state; scope with `.animation(_:value:)` on the view. `navigationSubtitle` takes no content
  transition.
- **Type-checking.** Long `body` modifier chains in `ChatThreadView` hit "unable to type-check"; an optional ternary in
  `.environment(\.key, cond ? nil : x)` is the usual trigger. Split into functions and type the value in a property.
- **Reading state in `body`.** Read collections inside the `ScrollView` content closure, not in `body` above it:
  reading `entries` in `body` made the working-row handoff test jitter. Accessibility frames lag a scroll; wait until
  they stop changing before comparing positions.

## Testing

- **Suites.** `test/run.sh --platform ios` (`test/ios.py`) runs the fast suite on the simulator, an iPhone by default;
  `DISPATCH_IOS_SIMULATOR="<iPad simulator>"` runs the same cases on an iPad (family-specific cases `XCTSkip` on the
  other). Cases are classified in `test/suites.json` as `DispatchMobileTests/<Class>/<test>` and
  `DispatchMobileScripts/<Class>/<test>` (Python tests of the release tooling); a fast run fails on an unclassified
  case. `--derived-data PATH` builds elsewhere than `build/ios`, so two runs do not wait on one build database. New
  tests go in `Mobile/Tests/<Area>…Tests.swift`; after adding files, run `python3 scripts/generate-project.py` and
  commit `DispatchMobile.xcodeproj/project.pbxproj`.
- **UI tests.** `xcodebuild -project DispatchMobile.xcodeproj -scheme DispatchMobileUITests
  -destination 'platform=iOS Simulator,name=iPhone Air' -derivedDataPath build/ios test`, against the scripted hosts;
  `test/run.sh` skips them. The scheme can hang after its result line: wrap it in
  `perl -e 'alarm 595; exec @ARGV' --`. Known simulator limits: XCUITest's `typeKey` never delivers Return, Esc,
  Delete, Home, End or Page keys and shifts F-keys down by one (those rules are unit tested through the commands); a
  synthesized ⌘ hold shows no overlay; pointer events and window resizing (Split View, Slide Over, Stage Manager
  sizes) cannot be synthesized, except through SpringBoard's window controls (`IPadLayoutUITests`); iPadOS keeps a
  floating software keyboard across launches, so cases dock it first and in teardown (`KeyboardDocking.swift`).
  `TEST_RUNNER_DISPATCH_UI_SHOTS=<folder>` keeps screenshots.
- **Live fixture.** Makes this Mac a host: a loopback sshd with private HOME and sockets, a private tmux server, and
  Claude Code from `build/test-tools` against a local Messages API. The simulator cannot start processes, so `serve`
  restarts sshd when a test asks.

  ```sh
  python3 scripts/mobile-live-fixture.py start /tmp/sim-int
  python3 scripts/mobile-live-fixture.py serve /tmp/sim-int &
  TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-int/live.json test/run.sh --platform ios SSHDriverLiveTests
  TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-int/live.json TEST_RUNNER_DISPATCH_LIVE_LINUX='{"name":…,"host":…,"port":…,"user":…,"key":…,"root":"/tmp/dt-int"}' \
    xcodebuild -project DispatchMobile.xcodeproj -scheme DispatchMobileUITests \
    -destination 'platform=iOS Simulator,name=<device>' -derivedDataPath build/ios \
    -collect-test-diagnostics never test -only-testing:DispatchMobileUITests/MobileLiveTests
  python3 scripts/mobile-live-fixture.py stop /tmp/sim-int
  ```

  The Linux entry is the Lima VM (`build/host-linux-ssh.json`, [vm_testing](vm_testing.md)).
- **Helper over stdio.** `python3 test/helper-stdio.py --live [--lima NAME | --remote user@host:port --identity KEY]
  [-k case] [--keep]` runs the helper exactly as the phone does, in a private root. Not in `test/suites.json`.
- **Transport.** `cargo test` in `Mobile/Transport/Core` (an in-process russh server, and a scripted hostile server
  for the pre-authentication flaws and rekeys, `tests/hostile.rs`) and `swift test` in
  `Mobile/Transport` (the login shell under the fixture sshd; `HelperRootTests` pin the bootstrap scripts).
- **Dictation.** `swift test` in `Packages/Dictation`, on the Mac; engine cases skip without their models.
- **Frame checks.** No transient wrong state, frame by frame: `TransitionUITests` and `-DispatchTabsScript` drive
  recordings (`xcrun simctl io <device> recordVideo`); `scripts/transition-frames.swift` and
  `scripts/tab-bar-frames.swift` split and judge them.
- **Fidelity.** `FidelityUITests`, `IPadFidelityUITests` and `SpacesUITests.testFidelity` pair every mockup screen
  with the app's screenshot in `build/mockup-review` (`scripts/fidelity-pairs.swift`); the mockups are SwiftUI
  screens in `mockups/`, rendered by `mockups/shoot.py`. `AppearanceUITests` runs the accessibility audit in both
  schemes; accepted reports are listed in the test.
- **Animation frames by hand.** For a frame-by-frame look at one animation, append a throwaway extension to a test class
  (`ChatRedesignTests` has the helpers), host the real view in a 402×874 `UIWindow`, and save
  `window.drawHierarchy(afterScreenUpdates: false)` every ~16 ms as a numbered sheet ([benchmarks](benchmarks.md#animations-frame-by-frame)).
  Activate buttons with `accessibilityActivate()`; drags cannot be driven. "No UIWindowScene" is a simulator hiccup:
  rerun.
- **Exploring the app headlessly.** Start the live fixture, add a throwaway XCUITest that adds the host like
  `MobileLiveTests.addHost`, drives the screens and writes `XCUIScreen.main.screenshot().pngRepresentation` (and
  `app.debugDescription`) to a folder, and delete it afterwards. The fixture's Claude echoes prompts ("Local Claude
  fixture reply: …"); "permission tool please" yields an approval. In forms: New host defaults to Key file (tap
  Password first); a text field's `value` comes back truncated and a tap lands mid-text, so clear a field by tapping
  it, then tapping near its trailing edge (`coordinate(withNormalizedOffset: (0.97, 0.5))`) and deleting its length plus
  a margin. Use `192.0.2.1` (TEST-NET-1) for a host that never answers, and don't match failure text on words the form's
  own helper text contains.
- **Simulator window.** DeviceHub owns the iPhone Duo's hinge (its Closed, Partially Open and Open toolbar buttons;
  `simctl` has none). System Events sees no DeviceHub windows, but the accessibility API does
  (`AXUIElementCreateApplication(pid)` + `AXUIElementPerformAction`, retried when SwiftUI redraws); its title names only
  the model, so with two Duos check which one changed. `xcrun simctl io <udid> screenshot --display=3` takes the inner
  screen, `--display=primary` the cover. Device ▸ Orientation works where repeated Rotate Right does not.

## Device checklist

Release build on a real iPhone, by hand. Nothing below has been run on a device yet.

1. Launch opens Spaces' empty state.
2. ED25519 key: no Face ID on connect or reconnect, also with the phone locked. A key made by a build before
   2026-10-31: one Face ID prompt at its first connect moves every such key, then none again; Cancel fails that login.
3. Secure Enclave key: one Face ID prompt per signature.
4. Copy and Share public key give the exact `authorized_keys` line.
5. Local Network prompt on the first LAN host; Don't Allow fails LAN hosts only.
6. Lock or switch apps for a minute: sessions drop and reconnect within seconds; agents kept running.
7. Background refresh with a password host, an ED25519 key host and a Secure Enclave key host all waiting, the phone
   locked: the password and ED25519 hosts notify, the Secure Enclave one does not.
8. Wi-Fi off while connected: reconnects over cellular in about 4 s.
9. A backup restored onto another phone brings no host, key or password.
10. Free account: after 7 days the app stops opening until reinstalled, with data intact.
11. iPad with a Magic Keyboard: the menu bar shows its items, holding ⌘ lists them, ⌘W closes the shown tab, Esc
    reaches vim in a terminal; without the keyboard the key capsule is back.

## Known limitations

- mosh deferred past v1; push notifications (need a relay) out of scope; iCloud never.
- iPad: one window only (multi-window needs per-scene compositions and host sessions); no Mac Catalyst and no
  "Designed for iPad" on the Mac. Esc does not go back.
- The iOS 26 New-button fallback (`.search` tab role) is untested: only the iOS 27 runtime has been used.
- Keyboard-interactive is untested against a real multi-round server (OTP, PAM).
- Live runs cover tmux; herdr only through the helper harness and scripted tests. Linux is covered on one arm64
  Ubuntu VM; x86-64, other distributions and a real remote Mac with Homebrew tmux are untested.
- herdr tabs have no server time; tmux times are whole seconds and per window, not per pane.
- Codex offers no "This session" approval: Codex rejects `updatedPermissions` in PermissionRequest hooks.
- A program's copy (OSC 52) is denied behind the helper: the phone has no consent surface for it, unlike the Mac's
  "Programs can copy".
