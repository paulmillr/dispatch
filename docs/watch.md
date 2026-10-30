# Dispatch for Apple Watch

A WatchConnectivity companion of [Dispatch for iPhone](ios.md). The phone keeps every SSH connection and helper; the
watch shows what the phone has (Agents, approvals, Spaces, host stats) and sends actions back. No Rust and no SSH on
the watch, and nothing on it knows a host's address, a key, a node id or the helper protocol. watchOS 26+, embedded in
the phone app (`DispatchMobile.app/Watch`) and sideloaded with it. Sources are in `Watch/`; the phone's side of the
link is in `Mobile/Watch`. What crosses the link, and the consent model, are in
[security](security.md#dispatch-for-iphone) (Apple Watch).

## Building and running

```sh
./run.sh --watch [--watch-simulator NAME] [--just-build]   # Debug on paired simulators (DISPATCH_WATCH_SIMULATOR)
test/run.sh --platform watch [--suite full] [Class]        # Testing, below
```

`--watch` builds the `DispatchMobile` scheme (which embeds the watch app) into `build/ios`, boots the pair, opens
DeviceHub, installs the phone app on the phone and `DispatchMobile.app/Watch/DispatchWatch.app` on the watch (a
simulator does not install an embedded watch app by itself), and launches both, phone first. `SIMCTL_CHILD_` variables
reach both launches: `SIMCTL_CHILD_DISPATCH_MOBILE_SCRIPTED=1 SIMCTL_CHILD_DISPATCH_MOBILE_STORE=memory ./run.sh --watch`
runs the phone on its scripted hosts (no SSH) and the watch over WatchConnectivity; add
`SIMCTL_CHILD_DISPATCH_WATCH_SCRIPTED=1` for the watch's own scripted phone instead. A booted phone keeps those
variables for every later launch, UI tests included: shut it down and boot it without them first.

- **Simulator pair** (`scripts/watch_simulator.py`). The watch is found by name or UDID (booted first, then the newest
  runtime). Its phone is the one it is paired with; otherwise "Dispatch Watch iPhone" is made once (an iPhone 18 Pro
  on the newest runtime that supports it, iOS 27.0: 27.1 has only the Duo) and paired. An existing phone is never
  paired. To undo: `xcrun simctl unpair <pair>`, `xcrun simctl delete <udid>`.
- Built from an iOS destination, the embedded watch app compiles for arm64 and x86_64 (`ONLY_ACTIVE_ARCH` has no
  watch destination to narrow to): anything arm64-only linked into the watch breaks the phone's simulator build.
- After a `DispatchWatch` test run the Debug watch app's `PlugIns` holds `DispatchWatchTests.xctest`, which the next
  phone build embeds (Debug only).
- Both targets set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`: change them together (Apple requires a match;
  the simulator's embedded-binary validation does not check it).
- Right after a simulator boots, WatchConnectivity's daemon can take 25 s to activate the phone's session; the watch
  shows its last context or "Waiting for your iPhone" until then.
- Not run yet: a signed device build and a real paired watch.

| Target | What |
| --- | --- |
| `DispatchWatch` | The watch app: single-target SwiftUI, bundle id the phone's + `.watchkitapp`, watchOS 26.0. Sources `Watch/App`, `Watch/Shared`, `Watch/Complication`; embeds `DispatchWatchWidgets`. |
| `DispatchWatchWidgets` | The complications: a WidgetKit extension in the watch app's `PlugIns`, bundle id the watch app's + `.widgets`. Sources `Watch/Widgets`, `Watch/Complication`, `Watch/Shared`. |
| `DispatchWatchTests`, `DispatchWatchUITests` | Unit tests hosted by the watch app (`Watch/Tests`); UI tests with their own scheme (`Watch/UITests`). |
| `DispatchMobile` | Embeds `DispatchWatch` ("Embed Watch Content") and compiles `Watch/Shared` and `Mobile/Watch`. |

The `watchApp` setting group mirrors `mobileApp` (`$(ARCHS_STANDARD)`, automatic signing from
`Mobile/Config/Signing.xcconfig`, the same team and `DISPATCH_BUNDLE_ID_SUFFIX`). `Watch/App/Info.plist` names the
phone in `WKCompanionAppBundleIdentifier` and sets `WKRunsIndependentlyOfCompanionApp` false. The watch app and its
widget extension share one App Group, `group.$(DISPATCH_BUNDLE_ID_PREFIX).mobile$(DISPATCH_BUNDLE_ID_SUFFIX)`, by default
`group.yachts.dispatch.pilot.mobile` (`DISPATCH_APP_GROUP`; docs/ios.md, Pilot and stable;
a device build needs it on the team, the simulator signs ad hoc); without its container the complications say
"Nothing waiting". The watch app has no `PrivacyInfo.xcprivacy` and must get one in `Watch/App` as soon as it uses a
required-reason API; `test/ios-release.py` checks the embedded executable against it.

## Architecture and data flow

| Side | Where | What |
| --- | --- | --- |
| Both | `Watch/Shared` (Foundation only) | `WatchProtocol` (version, requests, replies, failures, `WatchLimits`), `WatchSnapshot`, `WatchThread` (a thread page), `WatchCodec` (encoding, `fit`, `WatchText`) |
| Watch | `Watch/App/Model` | `WatchLink` (`SessionWatchLink` over `WCSession`, `ScriptedWatchLink` for previews and tests), `WatchModel` (`@Observable`: lists, notices, thread cache, actions) |
| Phone | `Mobile/Watch` | `WatchBridge` (the `WCSessionDelegate`), `WatchSnapshotBuilder`, `WatchRequestServer`, `WatchThreadBuilder`, `WatchHostStatsFeed`, `WatchReviewEvents` |

**Wire.** Every WatchConnectivity dictionary has one key, `dispatch.watch`, holding a binary property list (it stores
the snapshot's repeated keys once: about half of JSON). The phone pushes `WatchSnapshot` with
`updateApplicationContext` (latest wins; kept for the watch app's next launch) and, while the watch app is reachable,
as a message too. The watch sends one `WatchRequest` per `sendMessage` with a reply handler; the phone answers one
`WatchReply` with the request's `id`. Every message names its `kind`; every field added later is optional; an unknown
request kind is answered `unsupported`, an unknown reply kind or enum value decodes as `unknown`, a row that does not
decode drops only that row. `WatchProtocol.version` changes only for a change an older peer would misread; new
requests and fields are additions (an older phone answers `unsupported` and sends none of the fields; the watch falls
back to what it had). A property list has no null: a CPU gap travels as -1, `stale` only when true.

**Identity.** As the phone keys everything ([ios](ios.md#areas-and-seams), Identity): a host is `HostRecord.id`, a
conversation, space or tab is host plus topology `key`. Approvals and questions are named by the helper's interaction
id, never the phone's card id (new each run). Queue items are `QueueRow.id` (the outbox item's UUID, or `helper:<id>`
from the host's queue store), which survive reconnects. Node ids never cross.

### The bridge

`WatchBridge` (`@MainActor`, made and kept by `MobileComposition.app()`) activates `WCSession.default` synchronously at
launch (a message that wakes the app is delivered only to an activated session with its delegate set) and again after
`sessionDidDeactivate`. Nothing is sent while `isPaired && isWatchAppInstalled` is false. Every push, skipped push,
request and hold is logged under subsystem `yachts.dispatch.mobile`, category `Watch`; the watch logs under
`yachts.dispatch.watch`, category `Link`.

- **Pushing.** The snapshot is built inside `withObservationTracking` over everything it reads, so any change schedules
  the next build; changes coalesce behind a 1 s wait (at most one push a second). It is fitted (`WatchCodec.fit`) and
  skipped when unchanged but for `generated`; pushed at once on scene phase changes, protected-data changes,
  activation, `sessionWatchStateDidChange` and reachability. Plain SSH hosts, Shell spaces and a `sameMachine` host's
  spaces are left out; connection failures are redacted to the host's name (`WatchSnapshotBuilder.redact`, also on
  every reply's texts). A host that is not connected carries `blocked` (`hostKeyChanged`, `trustHostKey`, `login`,
  `faceID`: what only the phone can do); `phoneLocked` is reserved and never sent.
- **Serving.** A request hops to the main actor, takes a background task, is served within `WatchLimits.phoneBudget`
  (15 s; the watch waits 20 s; in the background at most `backgroundTimeRemaining` less 1.5 s, since a reply after
  expiry never leaves the suspended app), and is answered with the thread page as it stands. A request that needs a
  host first awaits `HostSessions.hold`, then its conversation, both 2 s under the budget, so the phone answers with
  what it has rather than the bridge timing out. A request that loses to the budget changes nothing afterwards. A
  request id already answered gets the same reply from the last 64, and one in flight is waited for, so a retried
  `sendMessage` never acts twice; failures are not kept.

| Kind | iPhone calls | Reply |
| --- | --- | --- |
| `hello` | none; the snapshot as built now | `snapshot` |
| `refresh` | holds (background) or `retryNow()`s (foreground) the hosts with Chat on, never a plain SSH host; with a host it is the user's Connect and lifts the phone's Disconnect | `snapshot` |
| `thread` | holds the host; `ChatConversations.session(for:)`; waits for a verified, loaded session, else answers with what the phone holds | `thread` |
| `answer` | the pending approval, question form or side question by interaction id (waited for up to 2 s after a reopen), answered through `MobileChatSession` | `thread` |
| `send` | `MobileChatSession.send(text:steer:)`, the composer's routing without touching the phone's drafts; a host that is down queues on the phone | `thread` |
| `stop`, `resume`, `queue.remove`, `queue.sendNow` | the session's own actions, with the phone's own permission checks | `thread` |
| `seen` | `ChatConversations.markSeen` through the item's time; no host needed | `done` |
| `open` | foreground: the thread opens at once; background: a local notification when allowed, else `unavailable` | `opened` |
| `review.undo` | `WatchReviewEvents.undo` while the review's window is open | `done` |

Failures (`WatchFailure`): `noConversation`, `openPhone` (the host is `blocked`), `hostOffline`, `timedOut`, `failed`
(the paused reason), `requestEnded` (no longer pending), `invalid`, `notSent` (the outbox refused or Send now is not
allowed), `unsupported`. Every action applies on the phone's own objects, so the watch is the phone's extension, not
another device: a seen mark moves the phone's marker, a sent message takes the phone's route.

### Seams

Two inputs are protocols the phone's features fill:

- `WatchStatsSource` (`stats(for:) -> WatchHostStats?`): `WatchHostStatsFeed` reads each host's `HostStatistics`
  (`summary(at:)`: values, the strip's red flags, 60 CPU bars of 15 s, the sample time, `stale`) and publishes a change
  of numbers at most every 15 s (one bar), appearance, disappearance and staleness at once. Where a host has no
  reading it answers nil, except in Debug's scripted modes, where `WatchSampleStats` derives numbers from the host's
  id (the demo's hosts sample their own).
- `WatchReviewEvents`: the Review tab posts a sent review with its undo window and closure, and `finished` when the
  window closed or the phone's own Undo took it; the snapshot carries the open ones (at most eight). A review an idle
  agent got at once is posted without a window, so the watch offers no Undo.

### Background

In the foreground the live sessions serve everything. In the background a request that needs a host holds it:

- **Quiet, on the real session.** `HostSessions.hold(id)` connects the saved host's own session (so the whole chat
  stack sees its client) with the context background refresh uses: Keychain reads with `interactive: false`, only
  already-trusted host keys, no keyboard-interactive. A Face ID key, an untrusted key or a login prompt fails at once
  and the reply is `openPhone`; the refusal is kept per host (`quietRefusals`) until it connects or the app comes to
  the foreground. A held run the foreground takes over asks as usual. `hold` returns once the link is connected,
  failed or retrying, after `holdBudget` (15 s) or when the request gives up; a held host already connected gets a
  `retryNow` (the app may have been suspended).
- **Locked.** The lock refuses nothing: passwords and passphrases are `AfterFirstUnlockThisDeviceOnly` and the app's
  files class C, so a password host connects while locked. Face ID and Secure Enclave keys fail the quiet read locked
  or not. Before the first unlock since the phone started nothing connects.
- **How long.** A hold lasts 60 s (`holdLength`) after the host's last watch request, then disconnects if the app is
  still in the background. iOS suspends the app soon after the background task ends (0.3 s on the simulator); the
  hold's timer then fires on the next wake, and the next request reconnects. Coming to the foreground clears every
  hold; going to the background disconnects everything, holds included.

### Consent

No switch. A watch request connects one host because the user just asked for it on their wrist, the consent opening
the phone app gives; background refresh, which connects on the system's schedule, stays off until turned on. Settings
has an **Apple Watch** row (under Background refresh, hidden where `WCSession.isSupported()` is false) saying "Not
paired", "Not installed" or "Installed"; uninstalling the watch app is the off switch. An approval from the watch rests
on the watch's own lock (passcode, wrist detection).

## Behaviour

What the model layer (`WatchModel`) guarantees; the screens (`Watch/App/Agents`, `Shell`, `Spaces`, each file's header
naming its mockup) follow it.

- **States** (`WatchModel.notice(at:)`, most pressing first): no snapshot and no phone; phone out of reach (the last
  snapshot, "Updated 25 min ago", nothing sent); trusted host keys unreadable; the phone offline; no hosts; a snapshot
  older than 10 min while reachable. A locked phone alone shows nothing (its password hosts still connect). Per host,
  `blocked` says what only the phone can do; rows of a host not live dim as on the phone.
- **Agents and Spaces** are the phone's lists in the phone's order with the phone's dots and badge; previews are one
  flattened line. Two pushes (hosts and spaces, then a space's tabs, then a tab) rather than one indented list. An
  agent's tab opens its thread; any other tab shows its facts and "Terminal on your iPhone". A host screen shows the
  phone's stats strip and 15-minute CPU sparkline, dimmed when the phone marks them stale or the host offline, with
  Connect (`refresh` with that host) when offline.
- **Thread.** Opening fetches a page (40 items) and caches it; the cached page shows while a newer one loads, and a
  page goes when the snapshot no longer lists its conversation. A page on screen reloads when its row moves past it;
  one off screen reloads on its next open. A thread opened before the phone was reachable loads once it is; launch
  greets the phone with one `hello`. Older history stays on the phone.
- **Approvals and questions.** Only pending ones, with the phone's chips, affirmative first. Nothing is sent until
  every part of a question is answered; a secret question says "Answer on your iPhone".
- **Composer and queue.** Reply opens the system's text input, then a confirm screen saying where the words go
  (sent at once, queued, or queued on the phone): nothing leaves the watch before Send. Steer is the phone's long-press
  send as a second input. Queue rows swipe for Remove and Send now where the phone allows it; no editing of queued
  text.
- **Optimistic, then the phone's page.** An answer removes its card, a message shows as "Sending…", a removed row
  goes, at once; the reply's page replaces the guess. On a failure the page as it was comes back with the reason,
  unless another action's page replaced the guess meanwhile.
- **Seen.** Opening a thread whose row shows an unseen result sends `seen` through its newest item's time; the phone's
  marker moves there and never back. A needs-you row stays blue until answered. Background refresh still never marks
  anything.
- **Review sent.** A snapshot carrying a review the phone just sent, with its Undo still open, is presented once over
  whatever shows, with Undo until the deadline; one that arrives after its window never shows; one the phone's own
  Undo took back says so and closes. It waits while a thread's own sheet is up (one sheet cannot present over
  another).
- **Complications.** One widget, "Needs you" (`NeedsYouWidget`), in the rectangular, corner, circular and inline
  families; pink only while something needs you. The entry (`WatchComplicationEntry`: the count, the newest needs-you
  row, the snapshot's time) is a JSON file in the App Group container (`WatchComplicationStore`, data protection class
  C, a plain file so no required-reason API), written newest-wins from every snapshot the watch app takes and from the
  phone's `transferCurrentComplicationUserInfo` (only while a complication is on the active face, only when the count
  or first line changed, within the day's budget of 50), which wakes the watch app in the background
  (`.backgroundTask(.watchConnectivity)`). The timeline is the entry, then from five minutes past its time the same
  with "As of …"; a tap opens `dispatch-watch://open?host=…&node=…`. Once the budget is spent, or with the
  complication only in the Smart Stack, a face can show an old count; its "As of" time says so. Untested: a face
  carrying it and a real background wake (simctl can configure neither).
- **Notifications.** Background refresh's notifications reach the watch as iOS forwards any iPhone notification;
  `WatchAppDelegate` registers category `agent` (no actions: a refresh holds no interaction, and an approval belongs
  to a live subscription), and a tap routes through `WatchRouter` to the thread, on a cold launch too. Untested: a
  forwarded notification and its tap (a simulator cannot forward); the route itself is tested.
- **Not on the watch.** Hosts, keys, trust and login sheets, Settings, New chat, New space, New tab, the terminal, the
  diff viewer, message details, the model and effort picker, mute and close, editing queued messages, the phone's
  drafts, the review itself (only a sent review's Undo is mirrored).

**Debug hooks** (compiled out of Release): `DISPATCH_WATCH_SCRIPTED=1|empty|unreachable|locked|waiting|mockup|
mockup-offline|mockup-review` (via `SIMCTL_CHILD_`), or the launch argument `-DispatchWatchScripted <value>` (so
`xcrun simctl launch <udid> <bundle id> -DispatchWatchScripted locked` works without a paired phone): `ScriptedWatchLink`'s
phone, defined in `WatchModel` and `WatchFixtures`. `-DispatchWatchShow spaces|spaces:<host>|space:<host>/<key>|
tab:<host>/<key>|host:<host>` opens a screen, `-DispatchWatchSheet question[:<option>]|reply:<text>` a thread's sheet,
`-DispatchWatchOpen <host>/<node>` takes a notification tap's route, `-DispatchWatchNotify <host>/<node>` posts a local
`agent` notification 3 s after launch (provisional authorization, so no prompt).

### Limits

- **Sizes** (`WatchLimits`). WatchConnectivity refuses a payload over about 64 KiB. The snapshot is fitted to 32 KiB:
  texts clipped (previews, steps and asks 120 characters, names and titles 200), then the hosts' CPU lines dropped and
  steps cut to 40, then rows left out a tenth at a time, least useful first (terminal tabs, idle conversations,
  anything that does not need the user); `truncated` says so and the watch shows "Some rows are on your iPhone". 5
  hosts × 6 conversations at their longest is about 25 KB, nothing cut. Replies are fitted to 48 KiB (item text 1,000
  characters, oldest items first).
- **Reachability.** The watch can ask only while `isReachable`; the phone app need not run, `sendMessage` wakes it. A
  reply takes up to the phone's 15 s budget when a host must connect first; the watch gives up after 20 s.
- **Locked phone.** Password hosts connect; Face ID and Secure Enclave key hosts need the phone open, since those keys
  never sign unattended.
- **Simulator.** A message takes 1 to 3.5 s each way. Not shown by simulators: a locked phone, forwarded
  notifications and their tap, Face ID keys, real SSH hosts, a face with the complication, a device. The watch cannot
  be tapped from `simctl`; the debug hooks and the UI tests stand in.
- **Open, outside the watch.** Stop (`chat.stop`) leaves the interrupted prompt in Claude Code's input, and the next
  `chat.send` is refused as "not ready for input" until it is cleared; a message sent from the watch then is lost (the
  phone keeps no draft for it) and the watch learns of the failure only from its next page.

## Testing

- **Suite.** `test/run.sh --platform watch` (`test/ios.py --platform watch`) runs `DispatchWatchTests` on a watch
  simulator (`--simulator`, `DISPATCH_WATCH_SIMULATOR`, default Apple Watch Series 12 (46mm)) with the `DispatchWatch`
  scheme in `build/ios`. Cases are classified in `test/suites.json` as `DispatchWatchTests/<Class>/<test>`; a fast run
  fails on an unclassified case. The watch needs no paired phone; xcodebuild boots it. New tests go in
  `Watch/Tests/<Area>Tests.swift`; after adding files, run `python3 scripts/generate-project.py` and commit
  `project.pbxproj` and the `DispatchWatch*.xcscheme` files.
- The phone's side runs in the iPhone suite: `WatchSnapshotTests`, `WatchThreadBuilderTests`,
  `WatchRequestServerTests`, `WatchBridgeTests`, `WatchHostStatsFeedTests`; the pair logic's tests in
  `test/ios-release.test.py`.
- **UI tests** (`DispatchWatchUITests`, own scheme, not in `test/suites.json` or `test/run.sh`):

  ```sh
  xcodebuild -scheme DispatchWatchUITests -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)' \
    -derivedDataPath build/ios test [-only-testing:DispatchWatchUITests/WatchLiveTests/<test>]
  ```

  `WatchLiveTests.testScriptedTapsThroughAgentsAndSpaces` needs no phone. `testLiveRoundTripWithThePairedPhone` and
  `testLiveSendWithThePairedPhone` run against Dispatch on the paired phone (`XCTSkip` without one); with
  `TEST_RUNNER_DISPATCH_LIVE_FIXTURE` the phone is on the live fixture (`scripts/mobile-live-fixture.py`,
  [ios](ios.md#testing)) and the tests answer, approve, send and stop a real Claude Code turn. Run the send test with
  the phone app in the background (`xcrun simctl launch <phone> com.apple.mobilesafari` first). `WatchFidelityTests`
  opens each mockup screen on the scripted mockup phone and, with `TEST_RUNNER_DISPATCH_WATCH_FIDELITY=<dir>`, saves
  `<ID>.png`; `WatchComplicationTests` renders the faces with `TEST_RUNNER_DISPATCH_WATCH_AGENTS_SHOTS=<dir>`. A watch
  list is lazy: the tests scroll with `XCUIDevice.rotateDigitalCrown`, then drag the frontmost list. A UI test run can
  leave `xcodebuild` waiting about 10 minutes after a failure before it exits.
- **Logs.** `xcrun simctl spawn <udid> log stream --level debug --predicate 'subsystem == "yachts.dispatch.mobile"'`
  (or `yachts.dispatch.watch`), after `log config --subsystem … --mode level:debug` for the debug lines.
- **Verified on simulators** (2026-10-21 and 2026-10-23, Xcode 27.1, iOS 27.0 phone paired with watchOS 27.0): the
  snapshot at activation and on every change, pushed also as a message; every request kind, including a background
  wake that held a host and answered within its task; the live actions against the fixture (a question answered, an
  approval asked for from the watch and allowed, a message sent, Stop on a held turn); the redesign's fields and Open
  on iPhone. Not run: a review sent from the phone with the watch attached, a face with the complication, a device.
