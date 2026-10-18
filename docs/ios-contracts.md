# Dispatch for iPhone: module contracts

Who owns what while the iPhone app is built in parallel streams, and the seams between them. The plan decides
scope; the mockups decide looks and copy and win over the plan's screen table where they differ (revised on
2026-10-18: two tabs, hosts managed inside Spaces, Mail-style dots); `docs/ios.md` describes the targets. This file is the integration contract: a stream may extend its
own area freely and changes another area's public types only with the orchestrator.

## The shell (after the 2026-10-18 revision)

Two tabs, Spaces and Agents, plus the New button whose glyph follows the tab (tab with a plus; compose). `MobileRoot`
presents the sheets (`MobileSheet`: newHost, newChat, settings; newTab only names New in Spaces, which opens a terminal
tab without a sheet); the streams supply their contents. The row grammar (`MobileRow`): gutter dot (`Dot.unread` blue
`#0a84ff` = needs you or a result not yet seen, `Dot.working` amber `#d9b36a`, none = idle or read), 46 pt disc in the
host tint with the host glyph, name (primary colour) with a 13 pt tertiary detail after it ("space · host" in Spaces,
the host in Agents), time, chevron, then one line (Spaces) or two (Agents) of what the tab is doing. Pink is the app
tint, your bubbles and the approval chips; it is no longer a dot colour. Green is only the connected status dot in host
detail.

| Area | Directory | Owns |
| --- | --- | --- |
| Hosts | `Mobile/Hosts`, `Mobile/Keys`, `Mobile/Store` | `HostRecord`, `HostStore` (incl. host order), `KeyStore`/`KeyRecord`, `KnownHostStore`, `HostLink`, `HostSession`, `HostSessions`; the New host sheet M8a ("Create connects once to verify and then saves"), host detail M1f (pushed; identity and live status, editable Connection, the host's spaces as an injected list, Remove host last in red with confirmation), the trust-on-first-use sheet, the no-multiplexer hint, the M1d empty-state body copy |
| Tabs | `Mobile/Tabs`, `Mobile/App` (shell) | `MobileRoot` and the New button (incl. the per-frame check that tapping New never shows an empty tab), the Spaces tab with Mail's header (toolbar row: leading glass capsule with tree toggle and sort/filter menu, trailing Edit/Done; large title below), flat list M2a, tree M2b (host sections with disclosure and unread roll-up, inset grouped cards of spaces with needs-you count and amber working dot) and M2c, edit mode M1e (red remove, Info pushes M1f, drag handles reorder hosts and spaces within a host, Add host glass button opens M8a), space details M4d, New space sheet M7a (host pull-down with "New host…" that opens M8a and returns selected; directory with recent folders), the New-tab flow (most recent space; long-press to pick or create), `TabScreen` (per-tab header with back pill count, title, subtitle, host pill, Terminal / Chat segments) |
| Chat | `Mobile/Chat`, `Mobile/Agents` | `MobileChatSession`, conversation list M3a (filter pill, blue/amber dots, two-line preview, swipe mute/close), per-conversation urgency and seen markers, thread M4a/M3b, approval M4b, banner M4c, the full-width thinking row M5a that unfolds in place into M5f, message details M5b (pushed, back pill names the space), queue M5c, New chat sheet M9a |
| Terminal | `Mobile/Terminal` | `TerminalHostView`, `TerminalFeed` and its `HelperClient` implementation (attach, observe, publish screens, input, resize, scroll), key capsule and d-pad cluster, zoom, selection; M6a |
| Transport | `Mobile/Transport` (Swift package over the Rust `dispatch-mobile-ssh` core) | SSH connection, auth, host-key delegate, exec channels, bootstrap, reconnect state machine (`docs/ios-ssh-spike.md`) |
| Code | `Mobile/Code` | The diff viewer M5d (from message details) and the composer with code M5e (`CodeComposer`, the thread's composer) |
| Resilience and Settings | `Mobile/Resilience`, `Mobile/Settings` | Network path watching, the launch cache (`HostCache`), background refresh and its notifications, the Settings sheet (per-host Chat and multiplexer, Remove all data) |
| Release | `scripts/ios-signing.py`, `test/ios-release.py`, `Mobile/App/PrivacyInfo.xcprivacy`, `docs/ios.md` | Signing config, device install (`scripts/run.py --ios-device`), the release check, the privacy manifest |

## Seams

- **Hosts → everyone:** `HostSession` is the one object the UI observes per host. Other areas receive a
  `HelperClient` (and `HelperTopology` snapshots) from it; they never import `MobileTransport` and never
  know about SSH (only `Mobile/Transport/Integration` imports it). Tabs, Chat and Terminal take `HelperClient` from
  the composition root and are tested with one scripted peer over `Pipe()` (`ScriptedHelper` in
  `Mobile/Tests/ChatTestSupport.swift`, the pattern of `DispatchTests/HelperClient/HelperClientTests.swift`) and the
  recorded fixtures under `DispatchTests/`.
- **Hosts ↔ Tabs:** the Spaces tab lists hosts as sections and edits them (M1e). Tabs takes the host list as
  `TabsHost` (one type: `TabsHost(_ session:)` maps a session) and the `SpacesHostActions` protocol (the removal
  question `removalConfirmation(for:)`, remove, reorder) that `HostSessions` implements over `HostStore`
  (`Mobile/Hosts/HostSessions+Spaces.swift`); Tabs embeds Hosts' views (M8a, M1f) through `SpacesHostViews`, and host
  detail's Spaces rows open through `HostSpaceOpening` (the shared navigator).
- **Transport → Hosts:** `SSHHostSessionDriver` (`Mobile/Transport/Integration`, app code beside the package, which
  stays platform-neutral) produces link events, the connected `HelperClient`, the hello record (with the accepted
  `features`), the multiplexers and their versions, the followed multiplexer, topology and latency. Hosts ships a
  `ScriptedHostSessionDriver` for previews and tests. Every mapping of connection states (transport → `HostLink` →
  `SpacesHostState`) is in `Mobile/Transport/Integration/HostLinkMapping.swift`.
- **Chat ↔ Tabs:** both derive from `HelperTopology`; an agent conversation is a terminal node with a
  `Binding`. Chat owns per-conversation urgency (`PaneUrgency` from `Dispatch/Attention.swift`) and the
  device-side "last seen" store; Tabs reads it for the gutter dots and the tree's counts.
- **Chat ↔ Terminal:** `chat.send` needs a published terminal screen; Terminal exposes a `TerminalPresence`
  (attach + publish for a terminal node) that `MobileChatSession` depends on.
- **Terminal ↔ Tabs:** a tab's Terminal segment hosts `TerminalHostView` with a `TerminalFeed` for that
  terminal node; Tabs decides which pane is active.
- **Identity:** terminal, tab and space ids change with every helper connection; the stable identity is the
  host plus the topology key.

## `HostSession` (the surface other areas code against)

```swift
enum HostLink: Equatable, Sendable {
    case disconnected, connecting, authenticating, bootstrapping, connected
    case reconnecting(attempt: Int, since: Date)
    case failed(String)
}

@MainActor @Observable final class HostSession: Identifiable {
    private(set) var host: HostRecord                   // updated in place by an edit that keeps the connection
    nonisolated var id: UUID                            // the host's id
    private(set) var link: HostLink
    private(set) var client: HelperClient?              // non-nil only while connected
    private(set) var hello: HelperSession.Info?          // identity, OS line, schema
    private(set) var multiplexers: [HelperClient.Multiplexer]
    private(set) var topology: HelperTopology?           // latest snapshot
    private(set) var topologyIsLive: Bool                // the snapshot is this connection's (not the cache's or the last helper's)
    private(set) var following: String?                 // the multiplexer whose topology this is ("tmux", "herdr")
    private(set) var multiplexerVersions: [String: String]
    private(set) var latency: Duration?
    private(set) var hostKeyMismatch: HostKeyOffer?
    func connect()
    func disconnect()
    func retryNow()                                      // network change, foregrounding
    func update(_ record: HostRecord)                    // rename, multiplexer preference (followed live), last connection
    func restore(hello:multiplexers:versions:following:topology:)  // the launch cache, before the helper answers
}
```

`HostSessions` also sets the session's integration hooks (`changed`, `clientEnded`, `postConnect`,
`helloReceived`) and reports a host key mismatch (`reportMismatch`); the other areas do not call them.

## The composition root (integration, after the streams merged)

`MobileComposition` (`Mobile/App`) owns `HostSessions`, `MobileTabs`, `ChatConversations`, `TerminalPresences.shared`
and the `SpacesNavigator`. `HostSessions.changed` fires in the same main-actor turn as any change of a saved host or its
session; the composition then hands each changed host to `MobileTabs.sync` (`TabsHostInput`: `TabsHost`, client,
topology, the followed multiplexer or the host's override, the hello's features) and `ChatConversations.update`
(`ChatHostSnapshot`). Chat's urgency, status line and needs-you count are injected into `MobileTabs`.
`HostSessions.clientEnded` stops the host's terminal presences; `postConnect` re-enables Pi's integration (when
installed); the connection's first live topology reattaches the presences in use through the new client. A presence is
attached while it has users (`TerminalPresences.retain`/`release`: the Terminal segment on screen, a conversation's
`TerminalChatPresence`). `TabsContent` builds the Terminal segment
(`TerminalSegmentView` over the node's presence and a `HelperTerminalFeed`) and the Chat segment (`ChatThreadView` over
`conversations.session(for:)`, whose `ChatTerminalPresence` is `TerminalChatPresence` over the same presences). One
`NavigationStack` (the navigator's path) holds the tab bar; Spaces and Agents push onto it.

## Rules that apply to every stream

- Swift 6, strict concurrency. New types are `Sendable` or `@MainActor`. Views never own shell lifetime
  (`docs/architecture.md`). Presentation changes never relaunch or terminate anything on the host.
- New files go under your area's directory; `Mobile/` is included by path, so run
  `python3 scripts/generate-project.py` and commit `project.pbxproj` with them. Do not edit other targets.
- Tests live in `Mobile/Tests/<Area>…Tests.swift`, run on the simulator through
  `bash test/run.sh --platform ios --simulator <your device>`, and are listed in `test/suites.json`
  as `fast` under `DispatchMobileTests/<Class>/<test>` (Python unit tests of the release tooling:
  `DispatchMobileScripts/<Class>/<test>`, `test/ios-release.test.py`).
- Copy and layout follow the mockups. No transient
  wrong state, even for one frame.
- Shared sources under `Dispatch/` change only by `#if canImport(AppKit)` guards or additive,
  behaviour-preserving helpers (as `PaneUrgency.init(waiting:working:unread:)` was).
