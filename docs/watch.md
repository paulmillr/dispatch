# Dispatch for Apple Watch

A WatchConnectivity companion of [Dispatch for iPhone](ios.md). The phone keeps every SSH connection and helper; the
watch shows what the phone has (Agents, approvals, Spaces) and sends actions back. No Rust and no SSH on the watch.
watchOS 26+, embedded in the phone app (`DispatchMobile.app/Watch`) and sideloaded with it. Sources are in `Watch/`;
the phone's side of the link is in `Mobile/Watch`.

## Building and running

```sh
./run.sh --watch [--watch-simulator NAME] [--just-build]   # Debug on paired simulators (DISPATCH_WATCH_SIMULATOR)
test/run.sh --platform watch [--suite full] [Class]        # Testing, below
```

`--watch` builds the `DispatchMobile` scheme (which builds and embeds the watch app) for the watch's paired iPhone
simulator into `build/ios`, boots both, opens DeviceHub, installs the phone app on the phone and
`DispatchMobile.app/Watch/DispatchWatch.app` on the watch, and launches both, phone first. The watch app alone:
`xcodebuild -scheme DispatchWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)'
-derivedDataPath build/ios build`. `SIMCTL_CHILD_` variables reach both launches, as with `--ios`:
`SIMCTL_CHILD_DISPATCH_MOBILE_SCRIPTED=1 SIMCTL_CHILD_DISPATCH_MOBILE_STORE=memory ./run.sh --watch` runs the phone on
its scripted hosts (no SSH, docs/ios.md Debug hooks) and the watch over WatchConnectivity; add
`SIMCTL_CHILD_DISPATCH_WATCH_SCRIPTED=1` for the watch's own scripted phone instead.

**Simulator pair** (`scripts/watch_simulator.py`). The watch is found by name or UDID as `--simulator` finds an iPhone
(booted first, then the newest runtime). Its phone is the one it is already paired with; otherwise it is paired with
"Dispatch Watch iPhone", an iPhone 18 Pro made once, and the pair is made active. An existing phone (another session's
booted iPhone Duo) is never paired. To undo: `xcrun simctl unpair <pair>`, `xcrun simctl delete <udid>`.

- A simulator does not install a phone app's embedded watch app on its paired watch, as a device does (a connected
  pair showed nothing 20 s after `simctl install`): `--watch` installs `DispatchWatch.app` on the watch itself.
- Xcode 27.1's iOS 27.1 runtime supports only the iPhone Duo: `simctl create` of an iPhone 18 Pro on it fails
  ("Incompatible device"). The phone goes on the newest runtime whose `supportedDeviceTypes` has its type (iOS 27.0).
- Built from an iOS destination, the embedded watch app compiles for arm64 and x86_64: `ONLY_ACTIVE_ARCH` has no watch
  run destination to narrow to. Anything arm64-only linked into the watch would break the phone's simulator build.
- After a `DispatchWatch` test run, the Debug watch app's `PlugIns` holds `DispatchWatchTests.xctest`, and the next
  phone build embeds it with the app (Debug only, as the phone's own tests sit in its `PlugIns`).
- The simulator build's embedded-binary validation (`embeddedBinaryValidationUtility`, ad hoc) accepted a watch app
  whose version or bundle id prefix differed from the phone's; nothing local enforces either. Both targets set
  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`: change them together.
- Launched right after its simulator booted, the phone app's session activated 25 s later (WatchConnectivity's daemon
  was still starting): "Snapshot not pushed: session not activated", then "Snapshot pushed (activated)". The watch
  shows its last context, or "Waiting for your iPhone", until then.
- Not run yet: a signed device build and a real paired watch.

## Targets

| Target | What |
| --- | --- |
| `DispatchWatch` | The watch app: single-target SwiftUI (`WKApplication`), bundle id the phone's + `.watchkitapp`, watchOS 26.0. Sources `Watch/App` and `Watch/Shared`. |
| `DispatchWatchTests` | Unit tests hosted by the watch app (`Watch/Tests`), bundle id `….watchkitapp.tests`. |
| `DispatchWatchUITests` | UI tests that launch the watch app (`Watch/UITests`, bundle id `….watchkitapp.uitests`), own scheme (Testing). |
| `DispatchMobile` | Embeds `DispatchWatch` ("Embed Watch Content", `$(CONTENTS_FOLDER_PATH)/Watch`) and compiles `Watch/Shared` (Foundation-only) and `Mobile/Watch` (its `Mobile` glob). |

XcodeGen 2.46 expresses the modern watch app as `type: application`, `platform: watchOS`; a plain target dependency of
the iOS app on it makes the "Embed Watch Content" copy phase (no `embed:` key needed). `deploymentTarget.watchOS` is in
the project's options. The `watchApp` setting group mirrors `mobileApp`: device family 4, `$(ARCHS_STANDARD)` (the
project's arm64e matches no watch), automatic signing from `Mobile/Config/Signing.xcconfig` (the same team and
`DISPATCH_BUNDLE_ID_SUFFIX`), ad hoc in the simulator. `Watch/App/Info.plist` names the phone in
`WKCompanionAppBundleIdentifier` (`yachts.dispatch.mobile$(DISPATCH_BUNDLE_ID_SUFFIX)`) and sets
`WKRunsIndependentlyOfCompanionApp` false. The icon is the phone's 1024 px PNG as a single watchOS size; the accent
colour is the phone's. The watch app has no `PrivacyInfo.xcprivacy`: it needs one in `Watch/App` as soon as it uses a
required-reason API (UserDefaults, file timestamps). `test/ios-release.py` checks the embedded app's executable
(arm64 and arm64_32 in a device build) against it and fails on an undeclared use; it also lists the watch app's size.

## Architecture and data flow

The phone does every SSH and helper call; the watch shows the phone's Agents and Spaces and sends actions back over
WatchConnectivity. Nothing on the watch knows a host's address, a key, a node id or the helper protocol.

| Side | Where | What |
| --- | --- | --- |
| Both | `Watch/Shared` (Foundation only, compiled into both apps) | `WatchProtocol.swift` (version, `WatchRequest`/`WatchAction`, `WatchReply`/`WatchResult`, `WatchFailure`, `WatchLimits`), `WatchSnapshot.swift` (hosts, Agents rows, spaces, tabs, the phone's state), `WatchThread.swift` (a thread page: items, approvals, questions, queue), `WatchCodec.swift` (encoding, `fit`, `WatchText`, `WatchNotification`, `WatchTint`) |
| Watch | `Watch/App/Model` | `WatchLink` (`SessionWatchLink` over `WCSession`, `ScriptedWatchLink` for previews and tests), `WatchModel` (`@Observable`: lists, notices, thread cache, actions) |
| Phone | `Mobile/Watch` | `WatchBridge`: the phone's `WCSessionDelegate`; builds snapshots, serves requests (below) |

**Wire.** Every WatchConnectivity dictionary has one key, `dispatch.watch`, holding a binary property list
(`PropertyListEncoder`): the snapshot repeats host ids, keys and field names in every row, which a binary plist stores
once (5 hosts × 6 conversations: 15.0 KB, JSON 28.5 KB). The phone pushes `WatchSnapshot` with
`updateApplicationContext` (latest wins; the system keeps it for the watch app's next launch). The watch sends one
`WatchRequest` per `sendMessage` with a reply handler; the phone answers one `WatchReply` with the request's `id`.
Every message names its `kind`; every field added later is optional. An unknown request kind is answered
`unsupported`, an unknown reply kind or enum value decodes as `unknown`, a row that does not decode drops only that
row. `WatchProtocol.version` changes only for a change an older peer would misread: a `terminal.screen` request (a
tab's screen as text) with a `screen` reply is an addition, not a version.

**Identity.** As the phone keys everything (docs/ios.md, Identity): a host is `HostRecord.id`, a conversation is host
plus its terminal's topology `key` (`WatchConversationKey`, the phone's `ChatConversationKey`), a space or tab is
host plus its topology key (`SpaceRef`, `TabRef`). Approvals and questions are named by the helper's interaction id
(`HelperChat.Interaction.id`), never the phone's card id (`PendingApproval.id` is new each run). Queue items are
`QueueRow.id` (the outbox item's UUID, or `helper:<id>` from the host's queue store), which survive reconnects. Node
ids never cross: they belong to one helper connection.

### The bridge

`Mobile/Watch/WatchBridge.swift`, `@MainActor`, made by `MobileComposition.app()` and kept by it. It activates
`WCSession.default` synchronously at launch (a message that wakes the app is delivered only to an activated session
with its delegate set) and again after `sessionDidDeactivate` (the user switched watches); its callbacks hop to the
main queue in arrival order. Nothing is sent while `isPaired && isWatchAppInstalled` is false. The session is behind
`WatchSessioning` (`WCSession`, or the tests' `ScriptedWatchSession`). Why a push sent nothing ("session not
activated", "no watch paired", "watch app not installed") and every push or failure are logged (subsystem
`yachts.dispatch.mobile`, category `Watch`; pushes at info level), as are each request ("Request thread 811B293F
received (app in the background)", "Answered thread 811B293F with thread in 13001 ms"), each hold ("Hold 24CF4CFD
(background): disconnected → connected in 122 ms, held") and each host state change of the snapshot ("Host 24CF4CFD:
connected → offline"); hosts by the first 8 characters of their id, a failure's words private. The watch's side logs
under `yachts.dispatch.watch`, category `Link` (activation, reachability, each snapshot, each request and its reply
time; the snapshot's conversation keys at debug level, the ones `-DispatchWatchOpen` takes).

**Pushing the snapshot.** The bridge builds a `WatchSnapshot` inside `withObservationTracking` over what it reads
(`HostSessions`, `ChatConversations.conversations`, `MobileTabs` sections, activity times, markers), so any change
(a `MobileComposition.sync`, a row's summary, a 30 s server-time poll, a seen marker) schedules the next build. Changes
are coalesced: the first starts a 1 s wait, then one build re-arms the tracking (at most one push a second, however
busy the hosts). The snapshot is fitted (`WatchCodec.fit`, `WatchLimits.snapshotBytes`) and skipped when it equals the
last one pushed but for `generated`. Also pushed at once on scene phase changes,
`protectedDataWillBecomeUnavailable`/`DidBecomeAvailable`, activation and `sessionWatchStateDidChange` (the app was
just installed; what was pushed before counts as not sent). It goes with `updateApplicationContext`; while the watch
app is reachable it also goes as a message without a reply handler (`SessionWatchLink` takes a snapshot from either),
and `sessionReachabilityDidChange` to reachable pushes at once, even unchanged. Field sources:

| Snapshot | From |
| --- | --- |
| `phone` | `foreground`: `HostSessions.active`; `locked`: the bridge's reading (`isProtectedDataAvailable` at launch, false from `protectedDataWillBecomeUnavailable`, while it is still true, to `DidBecomeAvailable`); `offline`: `HostSessions.networkUnavailable`; `knownHostsUnreadable`: `KnownHostStore.unreadable`; `needsYou`: `ChatConversations.needsYouCount` |
| `hosts` | `HostSessions.ordered`: `SpacesHostState(link)`, `HostSummary.tint` in the dark appearance as `#RRGGBB` (`HostTint.oklch` with the dark tone and the host's colour, as `HostTint.color` draws it when `Chrome.palette` is dark: no trait resolves it; `WatchTint.hex`; nil offline), `HostSystem.os` ("Darwin" → `macos`, else `linux`), `HostSummary.osLabel`, `HostSession.problem` or the `.failed` reason (the address, port and user it may name replaced by the host's name: `WatchSnapshotBuilder.redact`, also applied to every reply's texts), `blocked` (below), `HostRecord.chat`, `topologyIsLive && !switchingMultiplexer`, `spacesMultiplexer`, `MobileComposition.sameMachine`, `lastConnected` |
| `conversations` | `ChatConversations.conversations` in its order: key, `name`, `space`, `MobileComposition.tab(for:)`'s key, `MobileChatSession.agentKey` (else the binding executable's file name), `WatchText.preview(summary.preview)`, `attention`, `dot`, `summary.needsYou`, `busy`, `muted`, `lastActivity`, `stale` |
| `spaces`, `tabs` | per `MobileTabs.workspaces` but a `sameMachine` host's (its spaces show under the first host): `orderedSpaces`, unfiltered (Spaces' filter is the phone's view), `unread` (tabs whose urgency is needs you or unseen) and `working` as `SpacesSpaceRow` counts them, `TabsHost.abbreviate(cwd)`, `activity(of:)`; each space's tabs in server order with `label(of:host:)`, `program`, `abbreviate(cwd)`, `isChat`, the agent pane's agent (as a conversation's) and key, `urgency(of:)`, line two (`TabsTabRow.line`), `activity(of:)` |

`blocked`, only for a host that is not connected, the first that applies: `hostKeyChanged` for `hostKeyMismatch` (or a
mismatch in `trustRequests`); `trustHostKey` when `trustRequests` holds the host or a quiet attempt met an untrusted key;
`login` for a waiting `HostLoginPrompt` or a quiet attempt asked a keyboard-interactive round; `faceID` when a quiet
attempt or the link failed `interactionNotAllowed`, or the phone is not in the foreground and the host's key is a
Secure Enclave key or `KeyStore.keyProtection` is `biometry`. Quiet attempts' refusals are `HostSessions.quietRefusals`.
Never `phoneLocked`: that value is reserved (builds before passwords read after first unlock sent it for every host
while locked); `phone.locked` is information only.

**Serving a request.** `session(_:didReceiveMessage:replyHandler:)` hops to the main actor, takes a background task
(`beginBackgroundTask`), serves within `WatchLimits.phoneBudget` (15 s; the watch waits 20 s), replies with
`WatchCodec.message(reply)` and ends the task. In the background the budget is at most the task's time left
(`backgroundTimeRemaining`) less 1.5 s, the server's wait 2 s under that: a phone app the message woke had 14 s left on
the simulator, and a reply after the expiration would never leave the suspended app. A request that does not decode, or of a kind or version it does not
know, is answered `unsupported`/`invalid`. Every action applies on the phone's own objects, then is answered with the
thread page as it stands; a helper failure that comes later (`MobileChatSession.failure`) shows in the next page.

`WatchRequestServer` (`Mobile/Watch/WatchRequestServer.swift`) does the serving; the bridge decodes and races it against
the budget. A request that needs a host first awaits `HostSessions.hold` (the phone locked or not), then waits for its
conversation, both up to 13 s (2 s under the budget, so the phone answers with what it has rather than the bridge timing
out), and up to 2 s more for a verified conversation's terminal to attach (until then the composer would queue). A
request that loses to the budget is cancelled and changes nothing afterwards: the watch was told `timedOut` and put its
card or message back. A request id already answered gets the same reply again from a list of the last 64, and one still
being served is waited for, so a retried `sendMessage` never sends twice; failures are not kept (a failed request
changed nothing, a retry runs again).

| Kind | iPhone calls | Reply |
| --- | --- | --- |
| `hello` | none; the snapshot as built now | `snapshot` |
| `refresh` | holds the host(s) with Chat on (background) or `HostSession.retryNow()` (foreground); waits for the links up to the budget, then `ChatConversations.refresh(host:)` for each connected one | `snapshot` |
| `thread` | holds the host; `ChatConversations.session(for: ChatConversationKey)`; waits for `phase == .verified && !loadingHistory` (or paused, or the host down for good, or the budget). A host that cannot connect still answers with what the phone holds, phase `offline`, the reason being the failure below (`openPhone`'s text) | `thread` |
| `answer`, approval | `session.approvals.first { $0.interaction.id == request && $0.pending.pending }` (waited for up to 2 s: a reopened subscription delivers its open interactions after the history), the choice from `MobileChatSession.choices(for:)` by index, `session.answer(_:with:)` | `thread` |
| `answer`, question form | the same approval with `pending.questions`; `answers` keyed by question text, the chosen labels (by the watch's indices per part id) joined by ", " (`ClaudeQuestionDraft.answer`'s form) or the text; `session.answer(_:answers:)`, `nil` for skip | `thread` |
| `answer`, side question | `session.questions.first { $0.id == request }`; `clearAnswers()`, then per part `index = i`, `select(label)` per option or `type(text)`; `session.answer(_:skip:)` | `thread` |
| `send` | `MobileChatSession.send(text:steer:)`: `send(steer:)`'s routing without `drafts` (the phone's draft is neither taken nor cleared). A host that is down is no failure: the message waits on the phone (route `outbox`), as the composer's would | `thread` |
| `stop`, `resume` | `session.stop()`, `session.resumeQueue()` | `thread` |
| `queue.remove`, `queue.sendNow` | the `QueueRow` with that `id` (waited for up to 2 s, and for a queue change in flight to end); `removeQueued(_:)` (a row already gone is done; a device row goes offline too); `canSendNow(_:)` then `sendQueuedNow(_:)`, else `notSent` with the row's status | `thread` |
| `seen` | `ChatConversations.markSeen(_:through:)`: the conversation id (`session.conversation`, else the row's `binding.session`), `min(through, summary.lastActivity)`, `ChatMarkers.markSeen`, rebuild. No host needed | `done` |

Failures (`WatchFailure`): `noConversation` for a host or topology key the phone does not list (or a terminal that
no longer runs an agent); `phoneLocked` is reserved and never sent (a locked phone connects password hosts; see
Background); for an action that needs the live conversation (`answer`, `stop`, `resume`, `queue.sendNow`, removing a
row only the host's queue holds) and does not have it: `openPhone` when the snapshot builder marks the host `blocked`
(Face ID, trust, a changed key, a login; one rule for both), else `hostOffline` with the link's failure or
`HostSession.problem`, `timedOut` when the host is up but the conversation did not open in time, `failed` with the
paused reason; `requestEnded` for an approval or question that is no longer pending; `invalid` for an answer that
does not complete its parts or names no offered choice, or empty text; `notSent` when the outbox refuses a message or
Send now is not allowed; `unsupported` for an unknown kind or a newer `version`.

The page (`WatchThreadBuilder`): per turn, `ChatPatch.displayedItems` in order (as `ChatTurnSummary.displayed`), each
user, agent, notice and narration item as an item (`WatchText.plain`, row id as `ChatThreadRow.id` builds it), each
tool as one line with the same id form (`ChatStep`: `kind.label`, `title`, `detail`, `failed`, `running`), other
reasoning left out; `ChatTurnSummary.caption` on an ended turn's last agent item; `optimisticPrompt` last (its
`pending-…` id); the newest `limit` items, at most 200 (`earlier` when more exist, here or on the host). Approvals:
`approvalPresentation` (title, code), `choices(for:)` as `WatchChoice` (role from `ApprovalChoice.Role`). Questions:
question forms (pending approvals with `pending.questions`) first, then unsubmitted side questions; parts from the
interaction's questions (`HelperChat.Question`: id, header, text, options by index, `multiple`, `secret`). A form's
parts have `custom` false (the phone's form offers only its options); a side question's parts take
`ChatSideQuestion.Question`'s `allowsCustom`, `isSecret` and `multiple` (added for this, default false), and the
side question has no arrival time. `queueRows` with `canSendNow`, `queueStopped`, `canStop` (verified and working),
`route` (`route(steer: false)`: prompt → `send`, queue → `queue`, outbox → `outbox`), notes (`ChatThreadView`'s but
the paused reason, which is `reason`: Codex hook trust, attaching, `commandResult`), `failure`. Phase: verified →
`live`, opening, paused (reason), detached → `offline` (reason: the phone's own when it knows better, else the link's
failure or the host's problem). Then `WatchCodec.fit` (`WatchLimits.replyBytes`).

### Background

In the foreground the live sessions serve everything ("foreground connects every host"). In the background
(`HostSessions.active` false) a request that needs a host holds it:

- **Quiet, on the real session.** New `HostSessions.hold(_ id: UUID)` connects the saved host's own session (the one in
  `sessions`, so `MobileComposition.sync` hands its client to `ChatConversations` and the thread's `MobileChatSession`
  opens exactly as in the foreground) with the context `backgroundSession` uses: Keychain reads with `interactive:
  false`, only already-trusted host keys, no keyboard-interactive. A separate session as `HostSessionsRefreshSource`
  makes is enough for a summary but not here: nothing in the chat stack (sessions, outbox, markers) would see its
  client. As in background refresh, a Face ID key fails at once (`interactionNotAllowed`) and the reply is `openPhone`;
  a host key not yet trusted or a login prompt likewise. Each Keychain read, host key question and keyboard-interactive
  round of the app's sessions asks whether the attempt is quiet: the app in the background and the host held. So a held
  run the foreground takes over asks as usual, and the foreground's next `retryNow` connects interactively; New host's
  probe never goes quiet. A quiet refusal is kept per host (`HostSessions.quietRefusals`: `faceID`, `hostKey`, `login`)
  until the host connects or the app comes to the foreground. `hold` returns once the link is connected, failed or
  retrying, a host key or login sheet waits (in the foreground), after `holdBudget` (15 s) or when the request gives up;
  a held host already connected gets a `retryNow` (an `echo` probe: the app may have been suspended).
- **Locked.** The lock refuses nothing: passwords and passphrases are `AfterFirstUnlockThisDeviceOnly` and the app's
  files class C (docs/security.md), so a hold with the phone locked connects a password host as it would unlocked. A
  Face ID key (`WhenUnlockedThisDeviceOnly` behind `biometryCurrentSet`) or a Secure Enclave key fails the quiet read
  (`interactionNotAllowed`) locked or not: `faceID`, `openPhone`. Only before the first unlock since the phone started
  is a password unreadable too; that read fails the same way.
- **How long.** A hold lasts 60 s (`holdLength`) after the host's last watch request (a thread on the watch reloads and
  extends it), then the session disconnects if the app is still in the background. iOS may suspend the app sooner once
  the background task ends; the link then drops and the next request reconnects (`retryNow`). On the simulator it
  always did: suspended 0.3 s after the reply's task ended, and the hold's timer, which does not run while suspended,
  disconnected the host on the next wake (a `hello` 2 min later: "Host …: connected → offline" 1 s after it). Coming to the foreground
  clears every hold (`setActive(true)`: every host, interactive); going to the background disconnects everything as
  before, holds included.

**Consent.** No switch. Background refresh connects on the system's schedule with nobody asking, which is why it is off
until the user turns it on; a watch request connects one host because the user just asked for it on their wrist, the
consent opening the phone app gives. Settings has an **Apple Watch** row (under Background refresh, hidden where
`WCSession.isSupported()` is false) saying "Not paired", "Not installed" (its footer: install Dispatch from the Watch
app) or "Installed" (`WCSession.isPaired`, `isWatchAppInstalled`, read again on `sessionWatchStateDidChange`);
uninstalling the watch app is the off switch. An approval from the watch rests on the watch's own lock (passcode,
wrist detection), as docs/security.md's iPhone section says (Apple Watch).

## Behaviour

What the model layer does (`WatchModel`); the screens follow it.

- **States** (`WatchModel.notice(at:)`, most pressing first): no snapshot and no phone: waiting; phone out of reach
  (`WCSession.isReachable` false): the last snapshot, "Updated 25 min ago", nothing sent; locked with a host blocked
  `phoneLocked` (only an older phone build sends that): "Unlock your iPhone"; trusted host keys unreadable: "Open
  Dispatch on your iPhone"; the phone offline; no hosts: add one on the phone; reachable but the snapshot older than
  10 min: stale with its time. A locked phone alone shows nothing: its password hosts still connect. Per host,
  `blocked` says "Open Dispatch on your iPhone to connect pi" (Face ID, trust, changed key, login; "Unlock your
  iPhone" for an older phone's `phoneLocked`), and an offline host shows its `problem` and last connection. Rows of a
  host not live dim as on the phone (`stale`). The notice is a banner (symbol, title, second line;
  `WatchNoticeContent`): Spaces' first row ("iPhone out of reach" / "Updated 25 min ago", "Unlock your iPhone" /
  "Dispatch can't reach your hosts while it's locked.", "Waiting for your iPhone", "No hosts" / "Add a host on your
  iPhone.", "iPhone offline", "Updated 3 hr ago"), and one short line pinned above Agents' rows (the Agents list is its
  screen's own, and a two-line card there would hold 40 % of a 42 mm screen); `waiting` is left to Agents' empty
  state. Under "Unlock your iPhone" a host blocked only by the lock says nothing more. Times re-read every 30 s.
- **Agents.** Sorted as the phone's (`ChatConversations.rebuild`: newest activity, then host name, then node key,
  descending). Dots as the phone's: blue for needs you or an unseen result, amber working, muted rows keep only needs
  you. The badge is the phone's needs-you count. Previews are one flattened line of at most 120 characters. A row is
  the dot, the name (two lines), the agent's mark in the host's tint with "host · space" and the time, then the
  preview (two lines; the agent's attention line instead when it needs you). The phone's 46 pt host disc does not fit
  a 42 mm row: the mark (Claude's asterisk, Codex's braces, Pi's π, else a terminal) carries the tint. A blocked host
  with rows says `blockedMessage` under the list; the toolbar's leading button is Refresh (watchOS lists have no pull to
  refresh). No rows: the phone's "No agents yet"; before the first snapshot "Waiting for your iPhone".
- **Thread.** Opening fetches a page (40 items) and caches it; the cached page shows while a newer one loads, and a
  page goes when the snapshot no longer lists its conversation (as a row or a tab's agent). A page
  on screen reloads when its row moves past it (time, needs you, working, stale); one off screen is marked outdated and
  reloads on its next open. A thread opened before the phone was reachable (a cold launch from a notification opens it
  before WatchConnectivity activated) loads once it is, without Try Again; launch greets the phone with one `hello`
  however many starts meet it. Items: user and agent messages (Markdown flattened by `WatchText.plain`), thinking muted,
  tools as one line each ("Run · cargo test · ok"), the turn caption ("5 steps · 1m 26s"), notices. Older history stays
  on the phone ("Earlier messages are on your iPhone"). One list: a header (agent · model, then "Attaching…", the
  paused or offline reason, and the phone's notes), the items, the working line ("editing files 4m 2s"), failure lines
  (the watch's, then the phone's `failure`; a tap dismisses one), the requests, the queue, the composer. It opens at the
  first request, else at the newest item.
- **Approvals and questions.** Only pending ones, with the phone's chips in the phone's order (Deny, This session when
  offered, Allow). Questions offer their options (several when `multiple`), dictation where a typed answer is allowed,
  Skip; a secret question says "Answer on your iPhone". Nothing is sent until every part is answered. An approval is
  the agent's bubble (title, the command in three lines, "Waiting · 2m") with each chip a full-width row: Deny red,
  This session grey, Allow pink. A question is a bubble with Answer, which opens the form as a sheet (options with
  checkmarks, "Dictate or type", Send, Skip); a typed answer replaces a part's chosen options and the other way round.
- **Composer and queue.** Dictation or the system text input (`TextFieldLink`); the phone routes the text as its own
  composer would (sent at once when idle, else queued; `route` gives the placeholder: "Message", "Queue a message…",
  "Queued on your iPhone"; "Queue another…" with messages waiting, as the phone). Steer is the phone's long-press send:
  watchOS has no context menu, so a live, working agent gets a second input, Steer. Queue rows ("Queued · 2") show
  their status and swipe for Remove and Send now where the phone allows it; Stop while working, Resume after Stop. No
  editing of queued text (remove and send again). The message on its way is a faded bubble with "Sending…".
- **Optimistic, then the phone's page.** An answer removes its card, a message shows as "Sending…", a removed row
  goes, at once; the reply's page replaces the guess. On a failure the page as it was comes back with the reason
  (`WatchFailure.message`): a card whose answer did not go out shows again, unless another action's page replaced the
  guess meanwhile (then the reload brings it). Each message on its way has its own placeholder.
- **Seen.** Opening a thread whose row shows an unseen result sends `seen` through its newest item's time; the phone's
  marker (`ChatMarkers`) moves there and never back, so the phone shows it read too: the watch is the phone's
  extension, not another device. A needs-you row stays blue until answered, as on the phone. Background refresh still
  never marks anything.
- **Spaces.** Hosts in the phone's order, each with its spaces (the phone's order) and their tabs (most recent first,
  the phone's Activity sort). A tab bound to an agent opens its thread; any other tab shows its name, folder and
  program. No terminal in v1. Two pushes, hosts and spaces, then a space's tabs (`SpaceScreen`), then a tab: one list
  of hosts, spaces and tabs would be mostly indentation on a 42 mm screen, and a host with ten tabs would bury the
  next host. A host's header is its mark (the system's glyph, `apple.logo` or `server.rack`, in a disc of its tint;
  the name's initial before it was reached), its name, a state dot (green connected, amber connecting, grey offline)
  and the multiplexer in a grey chip; then its `blockedMessage` or offline `problem` with "Last connected 2 hr ago";
  "Same machine as studio: its spaces show there." for a second host on one machine; "No spaces". A space row: the
  dot (blue when a tab needs you or holds an unseen result, else amber while one works), the name, the folder (deeper
  than `~/a/b` as "…/b/c"), the time ("now", "5m", "2h", "3d", "2w", "1y": `WatchTime.relative`, the phone's "9:31" or
  "Yesterday" does not fit beside a name) and the unread count. A tab row: the dot (`WatchUrgency`), a bubble for a
  chat tab or a terminal, the name (two lines), the status (else the program when the name is not already it), the
  time. An agent's tab (`chat` with an agent pane) pushes its thread; any other a tab screen: name, host, system,
  space, folder, program, "40 min ago", status, and "Terminal on your iPhone". A truncated snapshot ends with "Some rows
  are on your iPhone". The leading toolbar button is Refresh, as in Agents.
- **Notifications.** Background refresh's notifications reach the watch as iOS forwards any iPhone notification (the
  phone locked, the watch worn). Their `userInfo` is `host` and `node` (`RefreshNotification`). The app's
  `WKApplicationDelegate` (`WatchAppDelegate`) is the `UNUserNotificationCenter` delegate and registers category
  `agent` (`WatchNotification.category`, no actions); `DispatchWatchApp` declares a `WKNotificationScene` for it whose
  long look is the title ("claude · studio"), subtitle and body. A default-action tap reads the key with
  `WatchNotification.key` and hands it to `WatchRouter.shared` (`pending`), which `WatchRoot` takes (on appear, so a
  cold launch from the tap works too): Agents comes forward with that thread pushed. No Approve action on the
  notification: it is posted by a refresh that holds no interaction, and an approval belongs to a live subscription.
  Untested: a forwarded iPhone notification and its tap (needs a paired phone; a simulator cannot forward), and the
  tap on the debug hook's local notification (simctl cannot tap; the notification is delivered, provisionally, to
  Notification Center). Tested: the route itself (`-DispatchWatchOpen`, `WatchRouter` in `WatchShellTests`).
- **Not on the watch.** Adding, editing or removing hosts, keys, trust and login sheets (secrets and trust decisions
  stay on the phone's screen), Settings, New chat, New space and New tab (multi-step forms), the terminal, the diff
  viewer, message details and step output, the model and effort picker, mute and close (cheap to add later), editing
  queued messages, the phone's drafts (the watch's messages never touch them).
- **Debug hooks** (compiled out of Release): `DISPATCH_WATCH_SCRIPTED=1|empty|unreachable|locked|waiting` (via
  `SIMCTL_CHILD_`), or the launch argument `-DispatchWatchScripted <value>` (read from the process arguments, so
  `xcrun simctl launch <udid> <bundle id> -DispatchWatchScripted locked` works without a paired phone):
  `ScriptedWatchLink`'s phone. `1` (or `demo`): hosts "studio" (macOS, tmux) and "lab" (Linux, herdr) connected, "pi"
  offline behind Face ID; an approval, a question, a working agent, an unseen result; five spaces, nine tabs.
  `empty`: reachable, no hosts. `unreachable`: the demo's snapshot from 25 min ago, the phone out of reach. `locked`:
  the demo with the phone locked and in the background: studio and lab (passwords) stay connected and take actions,
  pi (Face ID) answers `answer`, `stop`, `resume` and Send now with `openPhone`; no notice. `waiting`: no snapshot,
  unreachable.
  Screens without touches: `-DispatchWatchShow spaces|spaces:<host>|space:<host>/<space key>|tab:<host>/<tab key>`
  opens Spaces (scrolled to a host's section), a space or a tab screen; `-DispatchWatchOpen <host>/<node>` takes a
  notification tap's route to a thread; `-DispatchWatchNotify <host>/<node>` posts a local `agent` notification with
  the phone's `userInfo` 3 s after launch (provisional authorization, so no prompt; simctl cannot grant notifications).
  Hosts are `WatchFixtures`' UUIDs (`5E1D1A5C-57D1-4C0A-8000-00000000000{1,2,3}`).
- **Screens** (Agents). `Watch/App/Agents`: `AgentsScreen.swift` (`AgentsScreen`, `AgentsRow`, the blocked note,
  the empty state), `ThreadScreen.swift` (`ThreadScreen`, `ThreadHeader`), `ThreadItems.swift` (items, bubbles, tool
  lines, the working line), `ThreadRequests.swift` (approval card and chips, question card, `QuestionSheet`,
  `QuestionDraft`), `ThreadComposer.swift` (placeholders, queue rows), `AgentsStyle.swift` (the phone's chat colours
  in their dark values, the agent marks). Tests: `Watch/Tests/WatchAgentsViewTests.swift`; with
  `TEST_RUNNER_DISPATCH_WATCH_AGENTS_SHOTS=<dir>` its render test saves every scenario's rows and threads as PNGs.
- **Screens** (app shell and Spaces). `Watch/App/DispatchWatchApp.swift` (`@main`: one `WatchModel.app()`, `start()` at
  launch and on every return to active, `refresh()` too after more than 30 s away; the notification scene).
  `Watch/App/Shell`: `WatchRoot.swift` (`WatchRoot`: Agents and Spaces as `.verticalPage` pages inside one
  `NavigationStack`, the needs-you badge in Agents' trailing toolbar: watchOS has no `badge` and a vertical page no tab
  bar; a stack per page crashed at launch on watchOS 26, "nest wrapped navigation controllers"), `WatchNoticeView.swift`
  (notice words and banners, the host problem line), `WatchNotifications.swift` (`WatchRouter`, `WatchAppDelegate`,
  the debug hooks, `WatchNotificationController`), `WatchStyle.swift` (`Color(watchHex:)`, `WatchDots`, `WatchTime`,
  `WatchHostMark`, `WatchDotView`). `Watch/App/Spaces`: `SpacesScreen.swift`, `SpaceScreen.swift`,
  `TabDetailScreen.swift`, `SpacesText.swift` (row words, routes `WatchSpaceRoute`/`WatchTabRoute`). Tests:
  `Watch/Tests/WatchShellTests.swift`, `WatchSpacesViewTests.swift`.

### Limits

- **Sizes** (`WatchLimits`). WatchConnectivity refuses a context or message over its payload limit (about 64 KiB,
  `WCErrorCodePayloadTooLarge`). The snapshot is fitted to 32 KiB: texts clipped (previews 120, names and lines 200),
  then rows left out a tenth at a time, least useful first: terminal tabs, idle conversations and their tabs, anything
  that does not need the user; `truncated` says so. 5 hosts × 6 conversations at their longest: 15.0 KB, nothing left
  out; 8 × 12: fitted, every needs-you row kept. Replies are fitted to 48 KiB (item text 1,000 characters, oldest items
  first). A thread page is about 1 KB.
- **Reachability.** The watch can ask only while `isReachable` (the phone in Bluetooth or Wi-Fi range); the phone app
  need not run: `sendMessage` wakes it in the background. A reply takes up to the phone's 15 s budget when a host must
  connect first; the watch gives up after 20 s (`timedOut`).
- **Locked phone.** Most of the time a watch is used the phone is in a pocket, locked. Password hosts connect then
  (passwords `AfterFirstUnlockThisDeviceOnly`, files class C: docs/security.md); hosts with a Face ID or Secure
  Enclave key need the phone open ("Open Dispatch on your iPhone to connect pi"), since those keys never sign
  unattended. Before the first unlock since the phone started nothing connects.
- **Simulator.** WatchConnectivity needs the phone and watch simulators paired (`scripts/watch_simulator.py`) and both
  apps installed (`./run.sh --watch`). The link works end to end on the simulators (Testing, Verified on simulators);
  a message takes 1 to 3.5 s each way there. Not on a device yet.

## Testing

- **Suite.** `test/run.sh --platform watch` (`test/ios.py --platform watch`) runs `DispatchWatchTests` on a watch
  simulator (`--simulator`, `DISPATCH_WATCH_SIMULATOR`, default Apple Watch Series 12 (46mm)) with the `DispatchWatch`
  scheme in `build/ios` (`--derived-data` for another). Cases are classified in `test/suites.json` as
  `DispatchWatchTests/<Class>/<test>`; a fast run fails on an unclassified case, as the iPhone's does. No Python cases
  and no SSH engine setup. The watch needs no paired phone; xcodebuild boots it.
- The pair logic's tests (`test/ios-release.test.py`, `DispatchMobileScripts/DeviceDiscoveryTests`) run in the iPhone
  suite.
- **UI tests** (`Watch/UITests`, target and scheme `DispatchWatchUITests`; not in `test/suites.json`, which holds unit
  cases, and not in `test/run.sh --platform watch`):

  ```sh
  xcodebuild -scheme DispatchWatchUITests -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)' \
    -derivedDataPath build/ios test [-only-testing:DispatchWatchUITests/WatchLiveTests/<test>]
  ```

  `testScriptedTapsThroughAgentsAndSpaces` (`-DispatchWatchScripted 1`, no phone): Agents → the approval's thread →
  Allow, the question's Answer → Cosine → Send, then Spaces → dispatch → zsh ("Terminal on your iPhone").
  `testLiveRoundTripWithThePairedPhone` runs against Dispatch on the paired phone (start it first, e.g. with the
  scripted hosts as in Building and running): waits up to 10 s for the phone's rows (else `XCTSkip`, so it is safe
  without a phone), taps Refresh, opens the first row, then taps Allow, a question's first option or Stop when the page
  offers one and checks the card stays gone through the phone's budget. With `TEST_RUNNER_DISPATCH_LIVE_FIXTURE` (the
  phone on the live fixture, below) it instead answers a pending question with Yes, asks for an approval from the
  composer ("permission tool please, from the watch") and Allows it, sends "hello from the watch", sends a
  `FIXTURE_BARRIER_…` prompt (the fixture holds that turn up to 20 s) and taps Stop, each time waiting for the
  agent's reply on the page and no failure line. `testLiveSendWithThePairedPhone` sends one message and waits for the
  reply (Refresh and reopen when no push brought it): run it with the phone app in the background. The composer is
  typed into as a keyboard would: the system input opens on its keyboard with a focused text view, Done submits. A
  watch list is lazy: the tests scroll with `XCUIDevice.rotateDigitalCrown`, then drag the frontmost list (a sheet's
  list does not take the simulated crown); the crown stops at a list's end, so Agents pages on to Spaces by a swipe. A
  UI test run left `xcodebuild` waiting about 10 minutes after a failure before it exited.

**Verified on simulators** (2026-10-21, Xcode 27.1, Dispatch Watch iPhone on iOS 27.0 paired with Apple Watch Series 12
(46mm) on watchOS 27.0, pair "(active, connected)"). The phone ran
`SIMCTL_CHILD_DISPATCH_MOBILE_SCRIPTED=1 SIMCTL_CHILD_DISPATCH_MOBILE_STORE=memory DISPATCH_SETUP_OFFLINE=1 ./run.sh
--watch`; logs from `xcrun simctl spawn <phone> log stream --level debug --predicate 'subsystem ==
"yachts.dispatch.mobile"'` and `xcrun simctl spawn <watch> log stream --level debug --predicate 'subsystem ==
"yachts.dispatch.watch"'` (`log config --subsystem … --mode level:debug` first for the debug lines).

- Snapshot: the application context reached the watch at activation and on every change ("Snapshot pushed (change):
  4 hosts, 6 conversations, 1730 bytes" on the phone, "Snapshot from …: 4 hosts, 6 conversations, 6 spaces, 11 tabs"
  on the watch, launched without `-DispatchWatchScripted`); Agents and Spaces showed the phone's scripted hosts (ai,
  mba2, studio; vps offline). Pushed also as a message while the watch app ran.
- Requests: `hello` (1 to 3.5 s round trip), `refresh` (the toolbar button: "Answered refresh … with snapshot in
  162 ms") and `thread` (`-DispatchWatchOpen <host>/<node>` or the live UI test: "Answered thread … with thread in
  13012 ms"; the scripted hosts' helper never answers, so the page is the opening one after the server's 13 s wait).
  A scripted phone conversation never verifies, so it offers no action; the actions were verified on the live fixture.
- Actions on a live conversation (2026-10-21; this Mac as the host through `scripts/mobile-live-fixture.py`, Claude
  Code 2.1 against the local Messages API). Recipe:

  ```sh
  python3 scripts/mobile-live-fixture.py start /tmp/sim-int; python3 scripts/mobile-live-fixture.py serve /tmp/sim-int &
  DISPATCH_SETUP_OFFLINE=1 ./run.sh --watch --just-build
  # the phone: a copy of MobileLiveTests.testThisMacEndToEnd up to "Allow" that then sleeps (simctl cannot tap), run with
  # TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-int/live.json -only-testing:DispatchMobileUITests/<copy>
  TEST_RUNNER_DISPATCH_LIVE_FIXTURE=/tmp/sim-int/live.json xcodebuild -scheme DispatchWatchUITests \
    -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)' -derivedDataPath build/ios test \
    -only-testing:DispatchWatchUITests/WatchLiveTests/testLiveRoundTripWithThePairedPhone
  xcrun simctl launch <phone> com.apple.mobilesafari    # then, the phone app in the background:
  … -only-testing:DispatchWatchUITests/WatchLiveTests/testLiveSendWithThePairedPhone
  python3 scripts/mobile-live-fixture.py stop /tmp/sim-int
  ```

  A phone booted with `SIMCTL_CHILD_` variables (`./run.sh --watch` boots it) keeps them for every later launch, UI
  tests' included (a `DISPATCH_MOBILE_STORE=memory` test came up on the scripted hosts): shut it down and boot it
  without them first. Verified, each with "Request <kind> … received" and "Answered <kind> … with thread in 2 to 14
  ms" on the phone and the agent's reply on the watch's page: a question answered with Yes (Claude's terminal prompt:
  the permission hook gives up after 60 s and the phone shows Yes / Yes, and don't ask again / No, so an approval
  held for the watch longer than that is a question by then; the tool ran, "Tool result received: completed."), an
  approval asked for from the watch's composer and allowed (the fixture got the tool result), "hello from the watch"
  sent (Sending…, then the user's bubble and "Local Claude fixture reply: hello from the watch"), and Stop on a held
  turn (the fixture's request ended `disconnected` 6.7 s in; Stop and the working line left the page). With Safari in
  front: "Request thread … received (app in the background)", "Hold 0BDD84F1 (background): disconnected → connected in
  233 ms, held", "Answered send … with thread in 13 ms", the prompt in the fixture's requests and its reply on the
  watch's page 1.7 s later.
- Background: with Safari in front the phone app disconnected its hosts and was suspended 0.3 s later. A watch
  `thread` request woke it ("Request thread 811B293F received (app in the background)", background task with 14 s
  left), held the host ("Hold 24CF4CFD (background): disconnected → connected in 122 ms, held") and answered in
  13.0 s. The app was suspended again once the task ended, so the hold's 60 s timer did not fire on time; the next
  wake (a `hello` 2 min later) disconnected the host ("Host 24CF4CFD: connected → offline").
- Not shown by the simulators: a locked phone (`simctl` cannot lock one, and a simulator without a passcode always has
  protected data), forwarded iPhone notifications and their tap, Face ID keys, real SSH hosts, a device. The watch
  cannot be tapped from `simctl`; the debug routes and the UI tests stand in.
- Found by the live link and fixed: the watch app trapped on the first reply ("BUG IN CLIENT OF LIBDISPATCH: Block
  was expected to execute on queue com.apple.main-thread": the reply handler, formed in a main-actor method, was
  main-actor isolated and WatchConnectivity calls it on its own queue); a thread opened before WatchConnectivity
  activated stayed on "Your iPhone isn't reachable" until Try Again; launch sent `hello` twice; a request woken in the
  background could outlast its background task; the thread page never drew its last row, so the composer (Message,
  Queue, Steer) was missing and could not be scrolled to (watchOS 27 leaves a `List`'s last row out of its scroll
  range here, `Section` or not): an empty 1 pt row now ends the list. `testScriptedTapsThroughAgentsAndSpaces` passes.
  Open, outside the watch: Stop (`chat.stop`) leaves the interrupted prompt in Claude Code's input (Claude restores
  it), and the next `chat.send` is refused as "not ready for input" until that input is cleared; a message sent from
  the watch then is lost (the phone keeps no draft for it, though the failure says "Your draft is preserved"), and the
  watch learns of the failure only from its next page.
- New tests go in `Watch/Tests/<Area>Tests.swift`; after adding files, run `python3 scripts/generate-project.py` and
  commit `project.pbxproj` and `Dispatch.xcodeproj/xcshareddata/xcschemes/DispatchWatch.xcscheme` (and
  `DispatchWatchUITests.xcscheme`).
