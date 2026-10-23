import Foundation
import XCTest
@testable import DispatchWatch

/// The watch's model against the scripted phone: the lists derive as the phone's do, the states say why the phone cannot
/// help, and each action is one request whose page replaces the optimistic change (or puts it back).
@MainActor
final class WatchModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func makeModel(_ scenario: ScriptedWatchLink.Scenario = .demo) -> (WatchModel, ScriptedWatchLink) {
        let now = now
        let link = ScriptedWatchLink(scenario: scenario, now: { now })
        return (WatchModel(link: link, now: { now }), link)
    }

    private func snapshot(hosts: [WatchHost], conversations: [WatchConversation] = [], spaces: [WatchSpace] = [],
                          tabs: [WatchTab] = [], generated: Date? = nil) -> WatchSnapshot {
        WatchSnapshot(generated: generated ?? now, phone: WatchPhone(foreground: true), hosts: hosts,
                      conversations: conversations, spaces: spaces, tabs: tabs)
    }

    // MARK: Lists

    /// As `ChatConversations.rebuild` sorts Agents: newest first; a tie by host name, then node key, descending; rows
    /// without a time last.
    func testConversationsSortAsThePhoneSortsAgents() {
        let (model, link) = makeModel(.empty)
        let a = "5E1D1A5C-57D1-4C0A-8000-0000000000AA", b = "5E1D1A5C-57D1-4C0A-8000-0000000000BB"
        link.push(snapshot(
            hosts: [WatchHost(id: a, name: "alpha", order: 0, state: .connected), WatchHost(id: b, name: "beta", order: 1, state: .connected)],
            conversations: [
                WatchConversation(host: a, node: "n1", name: "untimed"),
                WatchConversation(host: a, node: "n2", name: "old", lastActivity: now.addingTimeInterval(-600)),
                WatchConversation(host: a, node: "n3", name: "tie alpha", lastActivity: now),
                WatchConversation(host: b, node: "n4", name: "tie beta", lastActivity: now),
                WatchConversation(host: b, node: "n5", name: "tie beta later key", lastActivity: now),
            ]))
        XCTAssertEqual(model.conversations.map(\.name), ["tie beta later key", "tie beta", "tie alpha", "old", "untimed"])
    }

    func testSectionsFollowHostOrderAndListTabsByActivity() {
        let (model, link) = makeModel(.empty)
        let a = "5E1D1A5C-57D1-4C0A-8000-0000000000AA", b = "5E1D1A5C-57D1-4C0A-8000-0000000000BB"
        link.push(snapshot(
            hosts: [WatchHost(id: b, name: "second", order: 1, state: .offline), WatchHost(id: a, name: "first", order: 0, state: .connected)],
            spaces: [WatchSpace(host: a, key: "s2", name: "later"), WatchSpace(host: a, key: "s1", name: "earlier"),
                     WatchSpace(host: b, key: "s3", name: "remote")],
            tabs: [
                WatchTab(host: a, space: "s2", key: "t1", name: "zsh"),
                WatchTab(host: a, space: "s2", key: "t2", name: "build", activity: now.addingTimeInterval(-60)),
                WatchTab(host: a, space: "s2", key: "t3", name: "agent", activity: now),
                WatchTab(host: a, space: "s2", key: "t4", name: "bash"),
                WatchTab(host: b, space: "s3", key: "t5", name: "top"),
            ]))
        let sections = model.sections
        XCTAssertEqual(sections.map(\.host.name), ["first", "second"])
        XCTAssertEqual(sections[0].spaces.map(\.space.name), ["later", "earlier"], "the phone's space order")
        XCTAssertEqual(sections[0].spaces[0].tabs.map(\.name), ["agent", "build", "bash", "zsh"])
        XCTAssertEqual(sections[1].spaces.first?.tabs.map(\.key), ["t5"])
    }

    func testATabBoundToAnAgentOpensItsConversation() throws {
        let (model, _) = makeModel()
        let tab = try XCTUnwrap(model.tab(host: WatchFixtures.studio, key: "tmux:s:$1:@2"))
        XCTAssertEqual(tab.conversationKey, WatchFixtures.approval)
        XCTAssertNil(model.tab(host: WatchFixtures.studio, key: "tmux:s:$1:@6")?.conversationKey, "a shell tab has no thread")
    }

    // MARK: States

    func testNoticesSayWhyThePhoneCannotHelp() {
        XCTAssertEqual(makeModel(.waiting).0.notice(at: now), .waiting)
        XCTAssertEqual(makeModel(.empty).0.notice(at: now), .noHosts)
        XCTAssertNil(makeModel(.locked).0.notice(at: now), "a locked phone alone says nothing")
        XCTAssertNil(makeModel(.demo).0.notice(at: now))
        XCTAssertEqual(makeModel(.demo).0.notice(at: now.addingTimeInterval(WatchModel.staleAfter + 1)), .stale(since: now))
        guard case .unreachable(let since)? = makeModel(.unreachable).0.notice(at: now) else { return XCTFail("unreachable") }
        XCTAssertEqual(since, now.addingTimeInterval(-25 * 60))

        let (model, link) = makeModel(.demo)
        link.reachable = false
        XCTAssertEqual(model.notice(at: now), .unreachable(since: now))
    }

    /// Passwords read after first unlock, so a locked phone still connects its password hosts: the lock alone shows no
    /// notice, and a Face ID host still says to open the phone. Only a phone that marks hosts `phoneLocked` (a build from
    /// before) brings "Unlock your iPhone" back (`.locked` scenario).
    func testALockedPhoneAloneShowsNoNotice() throws {
        let (model, link) = makeModel(.demo)
        var demo = WatchFixtures.demo(now: now)
        demo.phone.locked = true
        link.push(demo)
        XCTAssertNil(model.notice(at: now))
        let pi = try XCTUnwrap(model.host(WatchFixtures.pi))
        XCTAssertEqual(WatchModel.blockedMessage(pi), "Open Dispatch on your iPhone to connect pi.")
    }

    func testABlockedHostSaysOpenThePhone() throws {
        let (model, _) = makeModel()
        let pi = try XCTUnwrap(model.host(WatchFixtures.pi))
        XCTAssertEqual(pi.blocked, .faceID)
        XCTAssertEqual(WatchModel.blockedMessage(pi), "Open Dispatch on your iPhone to connect pi.")
        XCTAssertNil(WatchModel.blockedMessage(try XCTUnwrap(model.host(WatchFixtures.studio))))
    }

    func testStartAsksThePhoneForAFreshSnapshot() async {
        let later = now.addingTimeInterval(30)
        let link = ScriptedWatchLink(scenario: .demo, now: { later })
        let model = WatchModel(link: link, now: { later })
        await model.start()
        XCTAssertEqual(link.requests.map(\.action), [.hello])
        XCTAssertEqual(model.snapshot?.generated, later)
        XCTAssertNil(model.failure)
    }

    func testStartWithoutThePhoneAsksNothing() async {
        let (model, link) = makeModel(.unreachable)
        await model.start()
        XCTAssertTrue(link.requests.isEmpty)
        XCTAssertNotNil(model.snapshot, "the last snapshot still shows")
    }

    /// WatchConnectivity activates after `start`: the phone is greeted once it is reachable, and again whenever it
    /// comes back.
    func testThePhoneIsGreetedWhenItBecomesReachable() async throws {
        let (model, link) = makeModel(.unreachable)
        await model.start()
        link.reachable = true
        try await eventually { link.requests.count == 1 }
        XCTAssertEqual(link.requests.first?.action, .hello)
        XCTAssertNil(model.notice(at: now))
        link.reachable = false
        link.reachable = true
        try await eventually { link.requests.count == 2 }
    }

    /// Launch both starts the model and finds the phone reachable: one `hello`, not one each.
    func testLaunchGreetsThePhoneOnce() async throws {
        let (model, link) = makeModel(.unreachable)
        // WatchConnectivity takes seconds to answer: the second greeting comes while the first is on its way.
        link.delay = .milliseconds(200)
        await model.start()
        link.reachable = true
        await model.start()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(link.requests.map(\.action), [.hello])
    }

    /// A thread opened before WatchConnectivity activated (a cold launch from a notification) loads once the phone is
    /// reachable, without Try Again.
    func testAThreadOpenedBeforeThePhoneIsReachableLoadsWhenItIs() async throws {
        let (model, link) = makeModel(.unreachable)
        await model.start()
        await model.open(WatchFixtures.approval)
        XCTAssertEqual(model.failures[WatchFixtures.approval], .unreachable)
        link.reachable = true
        try await eventually { model.thread(for: WatchFixtures.approval) != nil }
        XCTAssertNil(model.failures[WatchFixtures.approval])
        XCTAssertTrue(link.requests.contains { $0.action == .thread(WatchFixtures.approval, limit: WatchLimits.threadItems) })
    }

    func testAnOlderSnapshotNeverReplacesANewerOne() throws {
        let (model, link) = makeModel()
        var older = try XCTUnwrap(link.snapshot)
        older.generated = now.addingTimeInterval(-60)
        older.hosts = []
        link.push(older)
        XCTAssertEqual(model.hosts.count, 3)
    }

    // MARK: Threads

    func testOpeningAnUnseenResultLoadsItAndMarksItSeen() async throws {
        let (model, link) = makeModel()
        XCTAssertEqual(model.conversation(WatchFixtures.unseen)?.dot, .unread)
        await model.open(WatchFixtures.unseen)
        XCTAssertEqual(model.thread(for: WatchFixtures.unseen)?.title, "Summarize the nightly logs")
        XCTAssertNil(model.conversation(WatchFixtures.unseen)?.dot)
        let seen = try XCTUnwrap(link.requests.last)
        XCTAssertEqual(seen.action, .markSeen(WatchFixtures.unseen, through: now.addingTimeInterval(-18 * 60)),
                       "seen through the newest item the watch showed")
    }

    /// Needs you stays blue until answered, as on the phone: opening such a thread marks nothing.
    func testOpeningAThreadThatNeedsYouMarksNothingSeen() async {
        let (model, link) = makeModel()
        await model.open(WatchFixtures.approval)
        XCTAssertEqual(link.requests.map(\.action.kind), ["thread"])
        XCTAssertEqual(model.conversation(WatchFixtures.approval)?.dot, .unread)
    }

    func testAThreadOnScreenReloadsWhenItsRowMoves() async throws {
        let (model, link) = makeModel()
        await model.open(WatchFixtures.working)
        XCTAssertEqual(link.requests.count, 1)
        var next = try XCTUnwrap(link.snapshot)
        let index = try XCTUnwrap(next.conversations.firstIndex { $0.key == WatchFixtures.working })
        next.conversations[index].lastActivity = now.addingTimeInterval(5)
        next.generated = now.addingTimeInterval(5)
        link.push(next)
        try await eventually { link.requests.count == 2 }
        XCTAssertEqual(link.requests.last?.action, .thread(WatchFixtures.working, limit: WatchLimits.threadItems))
        XCTAssertFalse(model.outdated.contains(WatchFixtures.working))
    }

    func testAThreadNotOnScreenIsMarkedOutdatedInstead() async throws {
        let (model, link) = makeModel()
        await model.open(WatchFixtures.working)
        model.close(WatchFixtures.working)
        var next = try XCTUnwrap(link.snapshot)
        let index = try XCTUnwrap(next.conversations.firstIndex { $0.key == WatchFixtures.working })
        next.conversations[index].busy = false
        next.generated = now.addingTimeInterval(5)
        link.push(next)
        XCTAssertTrue(model.outdated.contains(WatchFixtures.working))
        XCTAssertEqual(link.requests.count, 1)
    }

    // MARK: Actions

    func testApprovingClearsTheCardAndTheRow() async throws {
        let (model, link) = makeModel()
        await model.open(WatchFixtures.approval)
        let thread = try XCTUnwrap(model.thread(for: WatchFixtures.approval))
        let approval = try XCTUnwrap(thread.approvals.first)
        XCTAssertEqual(approval.choices.map(\.label), ["Deny", "This session", "Allow"])
        let allow = try XCTUnwrap(approval.choices.first { $0.role == .allow })
        let answered = await model.answer(WatchFixtures.approval, approval: approval, choice: allow)
        XCTAssertTrue(answered)
        XCTAssertEqual(link.requests.last?.action, .answer(WatchFixtures.approval, request: "interaction-7", WatchAnswer(choice: 0)))
        XCTAssertTrue(model.thread(for: WatchFixtures.approval)?.approvals.isEmpty == true)
        XCTAssertEqual(model.thread(for: WatchFixtures.approval)?.items.last?.text, "Allow")
        XCTAssertEqual(model.conversation(WatchFixtures.approval)?.needsYou, false)
        XCTAssertEqual(model.needsYou, 1)
    }

    /// A refused answer (the request ended on the phone) puts the card back from the phone's page and says why.
    func testAFailedAnswerPutsTheCardBack() async throws {
        let (model, link) = makeModel()
        await model.open(WatchFixtures.approval)
        let approval = try XCTUnwrap(model.thread(for: WatchFixtures.approval)?.approvals.first)
        link.failNext = WatchFailure(.requestEnded, "This request is no longer waiting.")
        let answered = await model.answer(WatchFixtures.approval, approval: approval, choice: approval.choices[0])
        XCTAssertFalse(answered)
        XCTAssertEqual(model.thread(for: WatchFixtures.approval)?.approvals.map(\.id), ["interaction-7"])
        XCTAssertEqual(model.failures[WatchFixtures.approval]?.code, .requestEnded)
    }

    /// Out of reach nothing is sent: the card stays and the watch says the phone is not reachable.
    func testAnAnswerWithoutThePhoneKeepsTheCard() async throws {
        let (model, link) = makeModel()
        await model.open(WatchFixtures.approval)
        let approval = try XCTUnwrap(model.thread(for: WatchFixtures.approval)?.approvals.first)
        link.reachable = false
        let answered = await model.answer(WatchFixtures.approval, approval: approval, choice: approval.choices[2])
        XCTAssertFalse(answered)
        XCTAssertEqual(link.requests.count, 1, "only the first page")
        XCTAssertEqual(model.thread(for: WatchFixtures.approval)?.approvals.count, 1)
        XCTAssertEqual(model.failures[WatchFixtures.approval], .unreachable)
    }

    func testAQuestionIsSentOnlyOnceEveryPartIsAnswered() async throws {
        let (model, link) = makeModel()
        await model.open(WatchFixtures.question)
        let question = try XCTUnwrap(model.thread(for: WatchFixtures.question)?.questions.first)
        let incomplete = await model.answer(WatchFixtures.question, question: question, WatchAnswer())
        XCTAssertFalse(incomplete)
        XCTAssertEqual(link.requests.count, 1)

        let answered = await model.answer(WatchFixtures.question, question: question, WatchAnswer(options: ["schedule": [0]]))
        XCTAssertTrue(answered)
        XCTAssertTrue(model.thread(for: WatchFixtures.question)?.questions.isEmpty == true)
        XCTAssertEqual(model.thread(for: WatchFixtures.question)?.items.last?.text, "Cosine")
        XCTAssertNil(model.failures[WatchFixtures.question])
    }

    func testADictatedAnswerGoesAsText() async throws {
        let (model, link) = makeModel()
        await model.open(WatchFixtures.question)
        let question = try XCTUnwrap(model.thread(for: WatchFixtures.question)?.questions.first)
        await model.answer(WatchFixtures.question, question: question, WatchAnswer(texts: ["schedule": "Warmup then cosine"]))
        XCTAssertEqual(link.requests.last?.action,
                       .answer(WatchFixtures.question, request: "interaction-12", WatchAnswer(texts: ["schedule": "Warmup then cosine"])))
        XCTAssertEqual(model.thread(for: WatchFixtures.question)?.items.last?.text, "Warmup then cosine")
    }

    /// The phone routes the message: queued while the agent works, sent at once while it is idle.
    func testAMessageQueuesWhileTheAgentWorksAndSendsWhenIdle() async throws {
        let (model, link) = makeModel()
        await model.open(WatchFixtures.working)
        let sent = await model.send(WatchFixtures.working, text: "  Also bump the version.  ")
        XCTAssertTrue(sent)
        XCTAssertEqual(link.requests.last?.action, .send(WatchFixtures.working, text: "Also bump the version.", steer: false))
        XCTAssertEqual(model.thread(for: WatchFixtures.working)?.queue.map(\.text), ["Then update the docs to match.", "Also bump the version."])
        XCTAssertFalse(model.thread(for: WatchFixtures.working)?.queue.contains(where: WatchModel.isSending) ?? true)

        await model.open(WatchFixtures.notes)
        await model.send(WatchFixtures.notes, text: "Shorten the intro.")
        let notes = try XCTUnwrap(model.thread(for: WatchFixtures.notes))
        XCTAssertEqual(notes.items.last?.text, "Shorten the intro.")
        XCTAssertTrue(notes.working)
        XCTAssertTrue(notes.queue.isEmpty)
        let empty = await model.send(WatchFixtures.notes, text: "   ")
        XCTAssertFalse(empty)
    }

    func testStopPausesTheQueueAndResumeRestoresIt() async throws {
        let (model, link) = makeModel()
        await model.open(WatchFixtures.working)
        XCTAssertEqual(model.thread(for: WatchFixtures.working)?.canStop, true)
        await model.stop(WatchFixtures.working)
        var thread = try XCTUnwrap(model.thread(for: WatchFixtures.working))
        XCTAssertFalse(thread.working)
        XCTAssertTrue(thread.queueStopped)
        XCTAssertEqual(thread.queue.first?.status, "Paused after Stop.")
        XCTAssertEqual(model.conversation(WatchFixtures.working)?.busy, false)

        await model.resume(WatchFixtures.working)
        thread = try XCTUnwrap(model.thread(for: WatchFixtures.working))
        XCTAssertFalse(thread.queueStopped)
        XCTAssertNil(thread.queue.first?.status)
        XCTAssertEqual(link.requests.map(\.action.kind), ["thread", "stop", "resume"])
    }

    func testAQueuedMessageCanBeRemovedOrSentNow() async throws {
        let (model, _) = makeModel()
        await model.open(WatchFixtures.working)
        await model.send(WatchFixtures.working, text: "Second")
        var queue = try XCTUnwrap(model.thread(for: WatchFixtures.working)?.queue)
        XCTAssertEqual(queue.count, 2)
        await model.removeQueued(WatchFixtures.working, item: queue[1])
        queue = try XCTUnwrap(model.thread(for: WatchFixtures.working)?.queue)
        XCTAssertEqual(queue.map(\.text), ["Then update the docs to match."])

        let sentNow = await model.sendQueuedNow(WatchFixtures.working, item: queue[0])
        XCTAssertTrue(sentNow)
        XCTAssertTrue(model.thread(for: WatchFixtures.working)?.queue.isEmpty == true)
        XCTAssertEqual(model.thread(for: WatchFixtures.working)?.items.last?.text, "Then update the docs to match.")
    }

    /// A locked phone still connects its password hosts: their threads are live and take actions. Only the Face ID
    /// host refuses what needs it live ("Open Dispatch on your iPhone to connect pi"); a message to it waits on the phone.
    func testALockedPhoneActsOnPasswordHostsAndAsksToOpenItForFaceID() async throws {
        let (model, _) = makeModel(.locked)
        await model.open(WatchFixtures.approval)
        let thread = try XCTUnwrap(model.thread(for: WatchFixtures.approval))
        XCTAssertEqual(thread.phase, .live)
        let approval = try XCTUnwrap(thread.approvals.first)
        let allowed = await model.answer(WatchFixtures.approval, approval: approval, choice: try XCTUnwrap(approval.choices.last))
        XCTAssertTrue(allowed)
        XCTAssertNil(model.failures[WatchFixtures.approval])

        await model.open(WatchFixtures.offline)
        let stopped = await model.stop(WatchFixtures.offline)
        XCTAssertFalse(stopped)
        XCTAssertEqual(model.failures[WatchFixtures.offline], .openPhone(host: "pi"))
        XCTAssertEqual(model.failures[WatchFixtures.offline]?.message, "Open Dispatch on your iPhone to connect pi.")
        let sent = await model.send(WatchFixtures.offline, text: "Go ahead")
        XCTAssertTrue(sent, "a message waits on the phone")
        XCTAssertEqual(model.thread(for: WatchFixtures.offline)?.queue.last?.text, "Go ahead")
    }

    func testAnUnknownReplyKindReadsAsUpdateThePhone() async throws {
        let link = UnknownReplyLink()
        let model = WatchModel(link: link, now: { Date(timeIntervalSince1970: 0) })
        await model.loadThread(WatchFixtures.notes)
        XCTAssertEqual(model.failures[WatchFixtures.notes], .unsupported)
    }

    /// Two answers in flight: the second's reply comes first, then the first fails. The page stays the phone's newest,
    /// not the one from before both (which would bring back the card the phone already took).
    func testAFailureNeverUndoesANewerPage() async throws {
        let link = ManualLink()
        let key = WatchFixtures.approval
        link.snapshot = snapshot(hosts: [WatchHost(id: key.host, name: "studio", order: 0, state: .connected)],
                                 conversations: [WatchConversation(host: key.host, node: key.node, name: "Fix the build")])
        let model = WatchModel(link: link, now: { [now] in now })
        let choices = [WatchChoice(index: 1, label: "Deny", role: .deny), WatchChoice(index: 0, label: "Allow", role: .allow)]
        let first = WatchApproval(id: "first", title: "Allow Bash?", arrived: now, choices: choices)
        let second = WatchApproval(id: "second", title: "Allow Edit?", arrived: now, choices: choices)
        let page = WatchThread(key: key, generated: now, title: "Fix the build", approvals: [first, second])

        let load = Task { await model.loadThread(key) }
        try await eventually { link.pending.count == 1 }
        link.answer(0, .thread(page))
        await load.value
        let a = Task { await model.answer(key, approval: first, choice: choices[1]) }
        try await eventually { link.pending.count == 1 }
        let b = Task { await model.answer(key, approval: second, choice: choices[1]) }
        try await eventually { link.pending.count == 2 }
        XCTAssertEqual(model.thread(for: key)?.approvals.map(\.id), [])

        var newer = page
        newer.approvals = [first]
        link.answer(1, .thread(newer))
        _ = await b.value
        link.reachable = false
        link.answer(0, .failure(.timedOut))
        _ = await a.value
        XCTAssertEqual(model.thread(for: key)?.approvals.map(\.id), ["first"])
        XCTAssertEqual(model.failures[key], .timedOut)
    }

    /// Two messages on their way are two placeholders, each with its own id.
    func testTwoMessagesOnTheirWayAreTwoRows() async throws {
        let (model, link) = makeModel()
        await model.open(WatchFixtures.working)
        link.delay = .milliseconds(200)
        let one = Task { await model.send(WatchFixtures.working, text: "one") }
        let two = Task { await model.send(WatchFixtures.working, text: "two") }
        try await eventually { (model.thread(for: WatchFixtures.working)?.queue.filter(WatchModel.isSending).count ?? 0) == 2 }
        let ids = model.thread(for: WatchFixtures.working)?.queue.filter(WatchModel.isSending).map(\.id) ?? []
        XCTAssertEqual(Set(ids).count, 2)
        _ = await (one.value, two.value)
    }

    /// Waits (up to 2 s) for work the model started in a task of its own.
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    // MARK: Hosts, Open on iPhone, reviews

    /// K6's counts: a host's spaces and tabs, its agents that need you and whether one works.
    func testAHostCountsItsSpacesTabsAndAgents() {
        let (model, _) = makeModel(.mockup)
        XCTAssertEqual(model.counts(host: WatchFixtures.mba2).spaces, 2)
        XCTAssertEqual(model.counts(host: WatchFixtures.mba2).tabs, 5)
        XCTAssertEqual(model.activity(host: WatchFixtures.mba2).needsYou, 1)
        XCTAssertTrue(model.activity(host: WatchFixtures.mba2).working)
        XCTAssertEqual(model.counts(host: "none").tabs, 0)
    }

    /// K6b's Connect asks the phone to retry that host (`refresh` with it) and shows the lists it answers.
    func testConnectAsksThePhoneToRetryTheHost() async {
        let (model, link) = makeModel(.mockupOffline)
        XCTAssertEqual(model.host(WatchFixtures.mba2)?.state, .offline)
        await model.connect(host: WatchFixtures.mba2)
        XCTAssertEqual(link.requests.last?.action, .refresh(host: WatchFixtures.mba2))
        XCTAssertEqual(model.host(WatchFixtures.mba2)?.state, .connected)
        XCTAssertTrue(model.connecting.isEmpty)
    }

    /// A host only the phone's screen brings back stays as it is (pi, behind Face ID).
    func testConnectLeavesABlockedHostAlone() async {
        let (model, _) = makeModel()
        await model.connect(host: WatchFixtures.pi)
        XCTAssertEqual(model.host(WatchFixtures.pi)?.state, .offline)
    }

    /// "Open on iPhone" is one `open` request; the words follow what the phone answers it did.
    func testOpenOnIPhoneSaysWhatThePhoneDid() async {
        let (model, link) = makeModel(.mockup)
        let shown = await model.openOnPhone(WatchFixtures.sidebar)
        XCTAssertEqual(link.opened, [WatchFixtures.sidebar])
        XCTAssertEqual(shown, "Open on your iPhone")
        link.openOutcome = .notified
        let notified = await model.openOnPhone(WatchFixtures.sidebar)
        XCTAssertEqual(notified, "Tap the notification on your iPhone")
        link.openOutcome = .unavailable
        let unavailable = await model.openOnPhone(WatchFixtures.sidebar)
        XCTAssertEqual(unavailable, "Open Dispatch on your iPhone: its notifications are off.")
        XCTAssertEqual(WatchModel.openWords(.unknown), "Sent to your iPhone")
        link.reachable = false
        let away = await model.openOnPhone(WatchFixtures.sidebar)
        XCTAssertEqual(away, WatchFailure.unreachable.message)
    }

    /// K8: a review arriving with its Undo open shows once; Undo takes it back and closes the card.
    func testAReviewShowsOnceAndUndoTakesItBack() async throws {
        let (model, link) = makeModel(.mockupReview)
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.title, "Sidebar theme toggle")
        let failure = await model.undoReview(review)
        XCTAssertNil(failure)
        XCTAssertEqual(link.undone, ["review-1"])
        XCTAssertNil(model.review)
        XCTAssertEqual(model.snapshot?.reviews, [])
    }

    /// A review whose window closed is never shown, and Undo after it says the agent has it without asking the phone.
    func testALateReviewIsNotShownAndCannotBeUndone() async throws {
        let (model, link) = makeModel(.mockup)
        var next = WatchFixtures.mockup(now: now)
        let late = WatchReviewSent(id: "late", host: WatchFixtures.mba2, node: "term_1", agent: "claude", title: "t", comments: 1, files: 1,
                                   sent: now.addingTimeInterval(-20), undoUntil: now.addingTimeInterval(-12))
        next.reviews = [late]
        next.generated = now.addingTimeInterval(1)
        link.push(next)
        XCTAssertNil(model.review)
        let failure = await model.undoReview(late)
        XCTAssertEqual(failure?.code, .requestEnded)
        XCTAssertEqual(failure?.message, "Too late to undo: claude has it.")
        XCTAssertFalse(link.requests.contains { $0.action == .undoReview(id: "late") })
    }

    /// Taken back on the phone before its deadline (the event leaves the snapshot): the card says so, then closes; one
    /// the watch's own Undo took is not "taken back on your iPhone".
    func testAReviewTakenBackOnThePhoneSaysSoThenCloses() async throws {
        let (model, link) = makeModel(.mockupReview)
        model.withdrawnFor = .milliseconds(50)
        XCTAssertNotNil(model.review)
        var next = try XCTUnwrap(link.snapshot)
        next.reviews = []
        next.generated = now.addingTimeInterval(1)
        link.push(next)
        XCTAssertTrue(model.reviewWithdrawn)
        XCTAssertNotNil(model.review, "the card stays to say so")
        try await eventually { model.review == nil }
        XCTAssertFalse(model.reviewWithdrawn)
        XCTAssertTrue(model.seenReviews.isEmpty, "only what the phone still lists is remembered")

        let (own, _) = makeModel(.mockupReview)
        let failure = await own.undoReview(try XCTUnwrap(own.review))
        XCTAssertNil(failure)
        XCTAssertFalse(own.reviewWithdrawn)
        XCTAssertNil(own.review)
    }

    /// Read after its deadline (the event leaves the snapshot then): the card closes at once.
    func testAReviewReadAfterItsDeadlineCloses() throws {
        var later = now
        let link = ScriptedWatchLink(scenario: .mockupReview, now: { [now] in now })
        let model = WatchModel(link: link, now: { later })
        XCTAssertNotNil(model.review)
        later = now.addingTimeInterval(300)
        var next = try XCTUnwrap(link.snapshot)
        next.reviews = []
        next.generated = now.addingTimeInterval(1)
        link.push(next)
        XCTAssertNil(model.review)
        XCTAssertFalse(model.reviewWithdrawn)
    }

    /// A dismissed card does not come back with the next snapshot that still lists its review.
    func testADismissedReviewStaysDismissed() throws {
        let (model, link) = makeModel(.mockupReview)
        XCTAssertNotNil(model.review)
        model.dismissReview()
        var next = try XCTUnwrap(link.snapshot)
        next.generated = now.addingTimeInterval(1)
        link.push(next)
        XCTAssertNil(model.review)
    }

    /// Every snapshot the model takes reaches the complications' writer.
    func testEverySnapshotReachesTheComplications() {
        let now = now
        var written: [Int] = []
        let link = ScriptedWatchLink(scenario: .demo, now: { now })
        let model = WatchModel(link: link, now: { now }, snapshotChanged: { written.append($0.phone.needsYou) })
        XCTAssertEqual(written, [2])
        var next = WatchFixtures.demo(now: now)
        next.generated = now.addingTimeInterval(1)
        next.phone.needsYou = 3
        link.push(next)
        XCTAssertEqual(written, [2, 3])
        _ = model
    }

    // MARK: The app's

    func testScriptedModeComesFromTheEnvironmentOrTheLaunchArguments() {
        XCTAssertEqual(WatchModel.scripted(environment: ["DISPATCH_WATCH_SCRIPTED": "1"], arguments: []), .demo)
        XCTAssertEqual(WatchModel.scripted(environment: ["DISPATCH_WATCH_SCRIPTED": "empty"], arguments: []), .empty)
        XCTAssertEqual(WatchModel.scripted(environment: [:], arguments: ["app", "-DispatchWatchScripted", "locked"]), .locked)
        XCTAssertEqual(WatchModel.scripted(environment: [:], arguments: ["app", "-DispatchWatchScripted", "YES"]), .demo)
        XCTAssertNil(WatchModel.scripted(environment: ["DISPATCH_WATCH_SCRIPTED": "0"], arguments: []))
        XCTAssertNil(WatchModel.scripted(environment: [:], arguments: ["app"]))
        XCTAssertTrue(WatchModel.app(environment: ["DISPATCH_WATCH_SCRIPTED": "1"], arguments: []).link is ScriptedWatchLink)
    }
}

/// A phone newer than this build: every reply is of a kind it does not know.
@MainActor
private final class UnknownReplyLink: WatchLink {
    var snapshot: WatchSnapshot? { nil }
    var reachable: Bool { true }
    var changed: (@MainActor () -> Void)?
    func activate() {}
    func request(_ request: WatchRequest) async throws -> WatchReply { WatchReply(id: request.id, .unknown("screen")) }
}

/// A phone whose replies the test gives, one by one, in any order.
@MainActor
private final class ManualLink: WatchLink {
    var snapshot: WatchSnapshot?
    var reachable = true
    var changed: (@MainActor () -> Void)?
    private(set) var pending: [(request: WatchRequest, reply: CheckedContinuation<WatchReply, any Error>)] = []

    func activate() {}

    func request(_ request: WatchRequest) async throws -> WatchReply {
        try await withCheckedThrowingContinuation { pending.append((request, $0)) }
    }

    /// Answers the request at `index` of those waiting.
    func answer(_ index: Int, _ result: WatchResult) {
        let (request, reply) = pending.remove(at: index)
        reply.resume(returning: WatchReply(id: request.id, result))
    }
}
