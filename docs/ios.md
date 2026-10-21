# Dispatch for iPhone and iPad

A thin client for SSH hosts. The device has no shell and starts no processes: the Rust helper on each host does the
work, and the app speaks the helper protocol (`helper/PROTOCOL.md`) over one in-process SSH connection per host.
iOS and iPadOS 26+, one app for iPhone and iPad (`TARGETED_DEVICE_FAMILY` 1,2; on an iPad see [iPad](#ipad)),
sideloaded (no App Store: the macOS helper would have to become a non-Mach-O payload, ITMS-90171). Sources are in
`Mobile/`; privacy, trust, keys and the helper's grant are in [security](security.md#dispatch-for-iphone).

**Hosts need** SSH (password, key or keyboard-interactive), macOS 14+ or Linux arm64/x86-64, and tmux 3.7+ or herdr
0.9.3+ ([installing](integrations.md#tmux-and-herdr)). Shells and agents live in tmux windows or herdr tabs so they
outlive the connection; the app installs nothing but its helper. tmux before 3.7 has no bracketed-paste state: Chat to a bound agent works, other typing is refused,
and the Mac's readiness warning shows. Linux with systemd-logind `KillUserProcesses=yes` kills servers at logout
unless the user runs `loginctl enable-linger $USER`.

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
  rule), `-Osize` for app code (needs measuring). The Mac helper keeps x86_64: Intel Macs are hosts.

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
confirmation (`AgentInput.records`) and the elapsed text are shared too. Mac views built on the Mac chat stack
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
| Hosts | `Mobile/Hosts`, `Keys`, `Store` | Host, key and known-host stores, `HostSession(s)`, New host, host detail, trust sheet |
| Tabs | `Mobile/Tabs`, `Mobile/App` | Shell, New button, Spaces, space details, New space, `TabScreen`, the menu bar and ⌘ commands (`MobileCommands`) |
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

The grant is the Mac's full profile with hooks less file writes and Git reads (`HelperGrant`: no `file.write` or
`git.read`; Chat off drops `hooks.configure` and `agent.*`). The
phone's hello features (`interaction.options`, `chat.list`, `projects.recent`, `multiplexers.versions`,
`terminals.coalesce`, `launch.names`, `stdio.liveness`, `terminals.activity`; the Mac names only
`terminals.coalesce`) are specified in `helper/PROTOCOL.md`;
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
sessions replay unchanged. Keep it that way. Exceptions to re-record when they show up: close-tab captures made with
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
  (`HostRecord.color`); the two apps agree only where their host lists do, and the phone has no colour picker. Two hosts
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
  bar, rows naming their space); book (wider than tall) puts the hairline on the fold, from the system's division
  region (`MobileFoldReader`, `reservedRegions(kind: .division, options: .includeInactive)`: inactive while flat,
  off centre on the Duo, 517.5 of 951 points), else the window's middle. The fold is DeviceHub's (the simulator window): its Closed, Partially
  Open and Open buttons under the device, for the device the window shows (two Duos share a name: check the window's);
  `simctl` has no hinge control. Unfolded, the app fills the inner screen (`simctl io <udid> screenshot --display=3`);
  folded, the cover screen is `--display=primary` and the default capture is the dark inner one.
- **iPad windows.** The same split, by window width alone, with the iPad's rules (`MobileSplit.Device.pad`, chosen
  by idiom so the Duo's numbers stay): it splits from 655.5 points (a 280-point sidebar beside a 375-point tab, the
  narrowest iPhone's width) and stacks below, exactly as the iPhone. The sidebar is what `UISplitViewController` gives
  its double-column primary (measured on iPadOS 27 and checked against it by `MobileSplitTests`): 320 points in every
  full-screen iPad either way up, the window less 448 between 728 and 768 wide (296 on a mini upright), never "the
  rest" (970 on a 13-inch on its side); under 728, where the system only overlays its sidebar, 280 down to the split's
  edge. iPadOS 27's own window arrangements (Window Controls, hold Zoom, Move & Resize): every full-screen iPad, the
  top halves (1210 × 486 on an 11-inch on its side, 744 × 561.5 on a mini upright) and a 13-inch's half on its side
  (683 × 909) split; the other halves (375 to 600 wide), thirds and Slide Over (375) stack. The stack and the sidebar
  get a compact horizontal size class, as the system's sidebar column has: `TabView` then draws the phone's bottom bar
  with New as its circle (in a regular width it drew iPadOS's floating top bar under the large title, New folded into
  a chevron). The phone's narrow variant (glyph-only bar, rows naming their space) stays the Duo's. Sizes come from the
  window (the scene's bounds, then `MobileWindowReader`), never the screen. A windowed app's window controls sit in the sidebar bar's leading
  corner; the bar's items fit beside them from 280 points (at 250 they went into the bar's overflow menu). The tab's
  header carries the sidebar button where the stack has its back pill: the sidebar slides off at its own width, still
  alive (its stack, scroll and tab bar stay), the tab takes the window, and the button keeps the needs-you count; the
  sidebar comes back when a section is chosen or no tab is left (`SpacesNavigator+Sidebar.swift`). As iPadOS's split
  views come back as they were left, an iPad keeps the tab on screen and the sidebar's state (UserDefaults
  `tabs.shownTab`, `tabs.sidebarHidden`, written where the host cache is: not in tests, the scripted demo or the sample
  unless `-DispatchSplitMemory YES`): a launch whose window splits shows that tab, if the cached topology still has it,
  with the sidebar as it was, from the first frame (`restoreSplit` runs before `MobileRoot`'s first body); a stacked
  window opens on the tab bar, as the phone always does. Sheets are the system's form sheets
  in the middle of the window, without the phone's grabber or detents (New tab's space picker had the phone's
  `[.medium, .large]`, which made a card at the window's bottom, its list cut by the screen: `mobilePhoneDetents`); the
  host key questions, taller than a form sheet, are page sheets (`mobileTallSheet`), their buttons a `safeAreaBar`.
  Controls that span a phone keep a phone's width on an iPad, centred: the Terminal / Chat control at most 400 points
  (`TabSegmentControl.maxWidth`; across a 13-inch's column it read as a phone's stretched), the composer's code key
  row the terminal capsule's 404. The text names the device it runs on (`MobileDevice.name`: "from this iPad",
  "Removes … from this iPad"); the phone's text is unchanged. The pointer gets the system's highlight on rows, glass
  pills, host discs and the tree and sort capsule (plain buttons and interactive glass have none of their own); bar
  buttons and the tab bar have theirs. With a hardware keyboard, Tab and the arrows move nothing in the Spaces lists
  (stacks of buttons, not focusable lists). The sidebar's slide moves the tab without resizing it, as the Mac's
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
  `/Users/<name>`. In the tree the whole host row shows or hides its spaces; a connected host known to have none
  offers New space below it. A host shows one multiplexer's spaces at a time: its header (and host detail's Spaces
  header, New space's host field) marks which, "tmux" or "herdr" in a grey chip, from `HostSession.spacesMultiplexer`
  (the followed one; no chip before one is followed or while a switch has not answered). New space offers the host's
  installed multiplexers (never native: its sessions belong to the helper, which ends with the connection, so with
  every trip to the background). Holding New space (that row, or New tab's picker) gives a system menu of hosts and
  multiplexers that makes a space at once with the form's defaults (home, no name) and opens it as Create does; in New
  chat the same entries are a "New space on" submenu of the Space pull-down (a pull-down's items cannot be held), and
  a space made there (or with "New space…", whose form opens over New chat) becomes the chat's instead of opening.
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
- **Terminal.** Output is coalesced (up to 256 KiB per parse) because tmux sends one notification per line. An
  attach's tmux history replay is one notification; the presence holds a whole helper reply (64 MiB) unparsed, since
  overflow ends the attachment. Only a lost stream of the current attachment detaches the feed, never one that ended
  because the presence stopped. A reattach's first output repaints over the old screen so it never shows empty.
  The grid follows the view every frame, but a run of changes (a live resize, a pinch) reaches the server once, at its
  last size, 100 ms after the last change (`TerminalPresence.resizeQuiet`): every `terminals.resize` makes tmux and the
  program redraw, and the redraws of sizes the view had already left arrived after it and repainted at the wrong grid.
  Calls go out one at a time; scroll steps made meanwhile join into one (a swipe is a step per line, a round trip
  each). A presence Chat opened learns its scrollback owner when the Terminal segment opens it. The terminal stays
  `dispatch-black` in light mode. Input, sizes and screens wait for `terminal.attached`, as the Mac's do. tmux keeps one size per
  window: while another client holds it at another size (or the window is split), the screen is laid out at the
  server's grid from the top left, as the Mac's, and the view keeps asking for its own. A program's copy (OSC 52,
  kitty clipboard) is denied: the phone has no consent surface for it, unlike the Mac's "Remote programs can copy".
  Hardware PageUp and PageDown page herdr's history; Shift pages the terminal's own. Automatic reconnects ask nothing:
  a host that needs a keyboard-interactive answer fails them and Connect asks again.
- **Terminal on iPad.** Rules in `TerminalAdaptation`, tests in `TerminalIPadTests` and `TerminalKeyboardUITests`.
  - *Software keyboard.* Where the keyboard is comes from `keyboardLayoutGuide` with `followsUndockedKeyboard` (a
    tracker view in the host view), not from keyboard notifications: a keyboard that comes up floating posts none, and
    floating a docked one posts a hide while it stays on screen. Docked, the capsule rides on it; floating or split, the
    capsule stays at the bottom (SwiftUI would keep a keyboard inset for a floating keyboard, so the segment ignores the
    keyboard safe area then). The shortcut bar is emptied (`inputAssistantItem`): its Undo, Redo and Paste cost the
    terminal a row and Paste is in the edit menu and ⌘V. On an iPad the capsule is at most six phone-width keys wide
    (404 points), centred. The grid takes its new size in the keyboard animation's first frame, as on the phone.
  - *Hardware keyboard.* With `HardwareKeyboard.shared.attached` the capsule collapses to one glass key over the
    terminal's bottom right ("Show terminal keys"); it brings the six keys back (remembered, `terminal.keysShown`),
    whose last key then folds them again; the capsule returns whole when the keyboard goes. The phone keeps its capsule
    whatever is attached (the simulator forwards the Mac's keyboard to every iPhone run). With a hardware keyboard the
    terminal becomes first responder when its segment shows. Keys are `UIKeyCommand`s without titles (none show in the
    ⌘-hold overlay, none use ⌘); `canPerformAction` must allow `keyCommand(_:)` or UIKit fires none of them (it did
    not before the iPad work: hardware keys other than text never reached the program). Ctrl-Space is iPadOS's input
    switcher, so no command fires for it: `pressesBegan` takes it. Encodings are Ghostty's, as the Mac's: Shift-Return
    is `ESC [27;2;13~` (CSI u under the kitty protocol), Ctrl-[ is `ESC [91;5u`, not ESC; a keyboard without Esc has the
    capsule's Esc, or Caps Lock mapped to Escape (Settings > General > Keyboard > Hardware Keyboard > Modifier
    Keys). ⌘C, ⌘V and ⌘A are the standard responder actions (Select All is the Mac's `select_all`); the view also
    answers `clearScreen(_:)`, `increaseSize(_:)`, `decreaseSize(_:)` and `resetFontSize(_:)` for the app's menu (⌘K,
    ⌘+, ⌘-, ⌘0), which nothing sends without that menu.
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
- **Resilience.** `host-cache.json` (last hello, multiplexers, topology, Agents rows with ≤280-character previews and titles) is
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

**Simulator demo.** `./run.sh --ios --demo` (Debug; `-DispatchDemo YES` or `DISPATCH_MOBILE_DEMO=1`) replaces the
saved hosts with three demo hosts (`Mobile/Demo`): mba2 and studio (macOS, herdr and tmux) and ai (Ubuntu), connected
through the scripted driver to an in-process helper (`DemoHelper`) on the real wire codec, so Spaces, Agents, threads,
approvals and terminals run the app's own code. Agents are in every state: working (web), waiting for approval (api,
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
keyboard. Beside the Duo's sidebar a tab's header is one row: the Terminal / Chat switch (glyphs) takes the host pill's
place, and the sidebar names its section in the bar's row (Edit a glyph in the narrow sidebar). An iPad's split keeps
the switch under the header and the sidebar's large title.

**Debug hooks** (compiled out of Release): `DISPATCH_MOBILE_STORE=memory` (nothing saved, no Face ID),
`DISPATCH_MOBILE_SCRIPTED=1|empty|trust|mismatch|nomux`, `DISPATCH_MOBILE_CHAT_DEMO=<screen>` (via `SIMCTL_CHILD_`),
`DISPATCH_MOBILE_CHAT_DEMO_WIDTH=<points>` (M3a in a sidebar column that wide),
`DISPATCH_MOBILE_CHAT_DEMO_LINK=cycle`, `DISPATCH_MOBILE_AUTHORIZE_KEYS`, `DISPATCH_MOBILE_HOST_ENV`, and launch
arguments `-DispatchTabsSample`, `-DispatchTabsShow`, `-DispatchTabsTree`, `-DispatchTabsFilter`,
`-DispatchTabsCollapse`, `-DispatchTabsEmptyHost` (a fourth, connected host without spaces), `-DispatchTabsScript` (one
step every 1.5 s, for recordings), `-DispatchTerminalEcho keys` (the sample's terminal echoes input in caret notation),
`-DispatchHardwareKeyboard YES|NO` (pins `HardwareKeyboard`). To force a background refresh, pause in lldb and run:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"yachts.dispatch.mobile.refresh"]
```

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
| Edit | the system's, and Clear Screen ⌘K |
| View | Increase, Decrease, Reset Font Size ⌘+ ⌘- ⌘0; Toggle Sidebar ⌃⌘S (and the Mac's hidden `⌘\`), Switch Terminal / Chat ⇧⌘C |
| Navigate | Spaces ⌘1, Agents ⌘2; Next and Previous Attention ⌘J ⇧⌘J; Previous and Next Tab ⌘[ ⌘] |
| Help | Keyboard Shortcuts ⌘/ |

- **What they act on** is the screen on top, in the stack and in the split alike (`SpacesNavigator+Commands`): the
  stack's top screen; in the split the detail column's tab (not while its space details are pushed over it) and that
  tab's space, else the sidebar's space. Items that do not apply are disabled: a tab's and a space's without one on
  screen or with their host not connected, Previous and Next Tab in a space of one tab, Attention with nothing waiting,
  and everything while a sheet or dialog is up (the shell publishes what is
  presented with a focused scene value; a chord is checked again when it runs).
- **As on the Mac**: New Tab opens in the space on screen (elsewhere as the tab bar's New: the most recent space, else
  the picker); Previous and Next Tab go round the shown tab's space in its place (the stack's top tab is replaced, the
  split's detail column shows the neighbour); Next Attention visits the tabs that need the user, then unseen results,
  from the shown one, round the end, on the Chat segment when an agent runs there. Clear Screen and the font sizes
  go down the responder chain to the focused terminal (`clearScreen(_:)`, `increaseSize(_:)`, `decreaseSize(_:)`,
  `resetFontSize(_:)`, which the terminal answers and refuses past its bounds), so a size is a pinch's: a point a step,
  saved where a pinch and Settings save it; with a hardware keyboard the shown terminal has the focus. Close Space asks Detach or Terminate…, as space details' Close does. ⌘1 and ⌘2 select the tab bar's sections, as
  iPad apps number their sidebar's, and go back to the tab bar (the split's detail column keeps its tab). New Chat
  takes ⌥⌘N, which the Mac leaves free (its ⇧⌘N is New Local Space). Toggle Sidebar (⌃⌘S) applies where the tab header's
  sidebar button does: an iPad's split beside a tab (the Duo's split keeps its sidebar); `⌘\`, the Mac's hidden alias, is a
  view's shortcut without a title (SwiftUI's commands have no hidden item), so it is in no menu and not in the ⌘-hold
  overlay. With the sidebar hidden ⌘1 and ⌘2 bring it back, and ⌘[ ⌘], ⌘J and ⌘T act on the tab that has the window,
  which keeps it. Search is not offered: the app has no search.
- **The system's menus.** SwiftUI's groups are the sections: a `Divider` inside a group does not separate on iPadOS,
  and a `before:`/`after:` group next to a replaced one is dropped, so File's sections take the new-item, save and
  import/export slots. Replacing the save slot removes the scene's Close (⌘W), which would close the app's one window;
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
  ([README](../Mobile/Transport/README.md)).
- **Dictation.** `swift test` in `Packages/Dictation`, on the Mac: text placement, Whisper's cleanup, the model
  store, and both engines transcribing `say`'s speech (Apple's when the language's model is on the Mac, Whisper's
  with `ggml-small-q8_0.bin` in `DISPATCH_WHISPER_MODELS` or the Mac app's models folder; each skips otherwise).
- **iPad layout.** `IPadLayoutUITests` (iPad simulators on the iOS 27.0 runtime, windowed apps on) drive iPadOS's
  windowing through SpringBoard: the `window-controls:<bundle id>` element, Zoom held for Move & Resize ("Fill",
  "Left", "Top", "Enter Slide Over"), and the window's bottom right corner dragged in the app's coordinates (SpringBoard
  reports its frames upright whatever the orientation). A full-screen window shows no controls until it is shrunk, and
  the window's size and place outlive the app, so each case starts with Fill and ends with it. `XCUIElement.hover()`
  moves the pointer on an iPad simulator; `TEST_RUNNER_DISPATCH_UI_SHOTS=<folder>` keeps the screenshots, landscape
  ones stored upright. `MobileSplitTests` renders iPad sizes on an iPad simulator and skips those cases on an iPhone.
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
