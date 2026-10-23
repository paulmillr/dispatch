import Foundation
import XCTest
@testable import DispatchMobile

/// The phone answering the watch (docs/watch.md, "Serving a request"): a composition whose one host ("studio") runs the
/// scripted helper, with one space and one agent-bound terminal; every action goes through the phone's own chat stack.
@MainActor
final class WatchRequestServerTests: XCTestCase {
    /// Connects to the scripted helper (or fails at once with `refusal`, as a Face ID key does in the background).
    private final class HelperDriver: HostSessionDriver, @unchecked Sendable {
        let helper: ScriptedHelper
        let refusal: String?
        init(_ helper: ScriptedHelper, refusal: String?) {
            self.helper = helper
            self.refusal = refusal
        }

        static let topology = HostFixture.topology([.init(name: "docs", cwd: "/Users/sam/src/docs", tabs: 1, agents: 1)])

        func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent> {
            AsyncStream { continuation in
                if let refusal {
                    continuation.yield(.link(.failed(refusal)))
                    continuation.finish()
                    return
                }
                continuation.yield(.link(.connecting))
                continuation.yield(.ready(client: helper.client, hello: HostFixture.hello(identity: host.tintSeed),
                                          multiplexers: HostFixture.multiplexers(["tmux"]), versions: ["tmux": "3.7"],
                                          topology: Self.topology))
            }
        }
    }

    private let helper = ScriptedHelper()
    private let record = HostRecord(name: "studio", address: "studio.local", user: "sam", auth: .password, order: 0, tintSeed: "studio")
    /// The terminal `HostFixture.topology` binds, and its conversation.
    private let node = "tmux:fixture:5"
    private let conversation = "fixture-5"
    private var app: MobileComposition!
    private var server: WatchRequestServer!
    private var holds: [UUID] = []
    /// Conversations "Open on iPhone" showed.
    private var shown: [ChatConversationKey] = []
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var reviews: WatchReviewEvents!
    private var blocked: WatchHostBlock?
    private var locked = false
    private let suite = "watch-server-\(UUID().uuidString)"

    private var key: WatchConversationKey { WatchConversationKey(host: record.id.uuidString, node: node) }
    private var chatKey: ChatConversationKey { ChatConversationKey(host: record.id, node: node) }
    private var session: MobileChatSession? { app.conversations.sessions[chatKey] }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func start(active: Bool = true, refusal: String? = nil) {
        helper.script { request in
            switch request.method {
            case "chat.open": .open
            case "terminals.attach": .attachedNow
            case "queue.list", "chat.list": .result([Any]())
            case "chat.send", "interactions.answer", "chat.stop", "queue.start": .result(ChatFixture.sent())
            case "queue.add": .result(ChatFixture.queued("held-\(request.id)", request.params["text"] as? String ?? ""))
            default: .result(NSNull())
            }
        }
        let hosts = HostSessions(store: HostStore(url: nil, hosts: [record]),
                                 keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                                 knownHosts: KnownHostStore(url: nil), driver: HelperDriver(helper, refusal: refusal), active: active)
        app = MobileComposition(hosts: hosts, tabs: MobileTabs(activity: TabActivityStore(url: nil), defaults: UserDefaults(suiteName: suite)!),
                                presences: TerminalPresences(), markers: ChatMarkers(store: ChatMarkerMemoryStore()),
                                outbox: ChatOutbox(store: ChatOutboxMemoryStore()),
                                drafts: ChatDraftRepository(store: ChatDraftMemoryStore()))
        reviews = WatchReviewEvents(clock: { [unowned self] in now })
        // The bridge's hold, as the test's: connect the host's own session and wait for it to settle; a host the user
        // disconnected is left alone (`HostSessions.hold`).
        server = WatchRequestServer(composition: app, hold: { [unowned self] id in
            holds.append(id)
            guard let session = app.hosts.session(id), !session.parked else { return }
            session.retryNow()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while session.link.isPending || session.link == .disconnected, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }, show: { [unowned self] in
            shown.append($0)
            return .shown
        }, reviews: reviews)
        server.grace = .milliseconds(300)
        server.budget = .seconds(5)
    }

    private func snapshot() -> WatchSnapshot {
        WatchSnapshot(generated: Date(), phone: WatchPhone(locked: locked),
                      hosts: [WatchHost(id: record.id.uuidString, name: record.name, order: 0, state: .offline, blocked: blocked)])
    }

    private func serve(_ action: WatchAction, id: String = UUID().uuidString) async -> WatchReply {
        await server.serve(WatchRequest(action, id: id)) { self.snapshot() }
    }

    private func page(_ reply: WatchReply, file: StaticString = #filePath, line: UInt = #line) throws -> WatchThread {
        guard case .thread(let page) = reply.result else {
            XCTFail("Expected a thread page, got \(reply.result)", file: file, line: line)
            throw CancellationError()
        }
        return page
    }

    private func failure(_ reply: WatchReply) -> WatchFailure? {
        if case .failure(let failure) = reply.result { return failure }
        return nil
    }

    /// Asks for the thread and plays the helper's history for its `chat.open`.
    private func openThread(records: [[String: Any]] = [], state: [String: Any] = ChatFixture.state(busy: false)) async throws -> WatchThread {
        let request = Task { await self.serve(.thread(key, limit: WatchLimits.threadItems)) }
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, "chat.history", ChatFixture.history(terminal: 5, session: conversation, records: records, state: state))
        return try page(await request.value)
    }

    private func notify(_ method: String, _ fields: [String: Any]) throws {
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        helper.notify(id, method, fields.merging(["terminal": 5, "session": conversation]) { new, _ in new })
    }

    // MARK: Snapshot and thread

    /// `hello` is the snapshot as built now; `thread` holds the host, opens the conversation and answers with a page that
    /// survives the wire and fits a reply.
    func testHelloAndAThreadPageThatFitsAReply() async throws {
        start()
        guard case .snapshot(let snapshot) = await serve(.hello).result else { return XCTFail("a snapshot") }
        XCTAssertEqual(snapshot.hosts.map(\.name), ["studio"])

        let page = try await openThread(records: ChatFixture.records("claude-thread"))
        XCTAssertEqual(holds, [record.id], "held before its session was touched")
        XCTAssertEqual(page.key, key)
        XCTAssertEqual(page.phase, .live)
        XCTAssertEqual(page.title, "zsh", "the Agents row's name")
        XCTAssertEqual(page.items.filter { $0.kind == .agent }.compactMap(\.caption), ["5 steps · 1m 26s", "4 steps · 52s"])
        XCTAssertEqual(page.items.count, 13)

        let reply = WatchReply(id: "r1", .thread(page))
        XCTAssertLessThanOrEqual(WatchCodec.size(reply), WatchLimits.replyBytes)
        XCTAssertEqual(try WatchCodec.value(WatchReply.self, in: WatchCodec.message(reply)), reply)
    }

    /// No such host or terminal: `noConversation`; a kind or version this phone does not know: `unsupported`.
    func testUnknownConversationsAndKinds() async throws {
        start()
        let unknownNode = await serve(.thread(WatchConversationKey(host: record.id.uuidString, node: "tmux:fixture:99"), limit: 40))
        XCTAssertEqual(failure(unknownNode)?.code, .noConversation)
        let badHost = await serve(.stop(WatchConversationKey(host: "not-a-host", node: node)))
        XCTAssertEqual(failure(badHost)?.code, .noConversation)
        let unknownSeen = await serve(.markSeen(WatchConversationKey(host: UUID().uuidString, node: node), through: Date()))
        XCTAssertEqual(failure(unknownSeen)?.code, .noConversation)
        let unknownKind = await serve(.unknown("terminal.screen"))
        XCTAssertEqual(failure(unknownKind)?.code, .unsupported)
        let newer = await server.serve(WatchRequest(.hello, version: WatchProtocol.version + 1)) { self.snapshot() }
        XCTAssertEqual(failure(newer)?.code, .unsupported)
    }

    // MARK: Open on iPhone, reviews

    /// `open` shows a conversation the phone lists (its own `show`: the thread, or a notification in the background),
    /// answers what it did and needs no host; one it does not list is `noConversation`.
    func testOpenShowsTheConversationOnThePhone() async throws {
        start()
        _ = try await openThread()
        let reply = await serve(.openOnPhone(key))
        XCTAssertEqual(reply.result, .opened(.shown))
        XCTAssertEqual(shown, [chatKey])
        let unknown = await serve(.openOnPhone(WatchConversationKey(host: record.id.uuidString, node: "tmux:fixture:99")))
        XCTAssertEqual(failure(unknown)?.code, .noConversation)
        XCTAssertEqual(shown, [chatKey])
    }

    /// The bridge's `show`: in the foreground the thread opens (`shown`); in the background a notification when they
    /// are allowed and it was posted (`notified`), else nothing (`unavailable`), never asking for permission.
    func testOpenShowsNotifiesOrSaysItCannot() async throws {
        start()
        _ = try await openThread()
        var posted: [RefreshNotification] = [], asked = 0
        func notifications(allowed: Bool, posts: Bool = true) -> WatchBridge.Notifications {
            WatchBridge.Notifications(authorized: { asked += 1; return allowed }, post: { posted.append($0); return posts })
        }
        var opened: [ChatConversationKey] = []
        NotificationRoute.shared.open = { opened.append($0) }
        defer { NotificationRoute.shared.open = nil }

        let shown = await WatchBridge.show(chatKey, in: app, notifications: notifications(allowed: true))
        XCTAssertEqual(shown, .shown)
        XCTAssertEqual(opened, [chatKey])
        XCTAssertEqual(asked, 0, "the foreground needs no notification")

        app.hosts.setActive(false)
        let notified = await WatchBridge.show(chatKey, in: app, notifications: notifications(allowed: true))
        XCTAssertEqual(notified, .notified)
        XCTAssertEqual(posted.map(\.key), [chatKey])
        XCTAssertEqual(posted.first?.id, "watch-open:\(record.id.uuidString):\(node)")
        XCTAssertEqual(posted.first?.body, "Opened from your Apple Watch.")

        let off = await WatchBridge.show(chatKey, in: app, notifications: notifications(allowed: false))
        XCTAssertEqual(off, .unavailable)
        XCTAssertEqual(posted.count, 1, "nothing posted without permission")
        let failed = await WatchBridge.show(chatKey, in: app, notifications: notifications(allowed: true, posts: false))
        XCTAssertEqual(failed, .unavailable)
        XCTAssertEqual(opened, [chatKey], "the background opens nothing by itself")
    }

    /// `review.undo` takes a review back through the Review tab's undo while its window is open; after it, or for a
    /// review the phone does not know, it is `requestEnded` and nothing is undone.
    func testUndoTakesAReviewBackOnlyInItsWindow() async throws {
        start()
        var undone = 0
        let id = reviews.post(key: chatKey, agent: "claude", title: "Docs", comments: 3, files: 2, window: 8) { undone += 1; return true }
        XCTAssertEqual(reviews.open(at: now).map(\.id), [id])
        let undo = await serve(.undoReview(id: id))
        XCTAssertEqual(undo.result, .done)
        XCTAssertEqual(undone, 1)
        XCTAssertTrue(reviews.open(at: now).isEmpty)
        let again = await serve(.undoReview(id: id))
        XCTAssertEqual(failure(again)?.code, .requestEnded, "gone after its undo")

        let late = reviews.post(key: chatKey, agent: "claude", title: "Docs", comments: 1, files: 1, window: 8) { undone += 1; return true }
        now = now.addingTimeInterval(9)
        XCTAssertTrue(reviews.open(at: now).isEmpty, "the snapshot leaves it out once its window closed")
        let tooLate = await serve(.undoReview(id: late))
        XCTAssertEqual(failure(tooLate), WatchRequestServer.reviewRead)
        XCTAssertEqual(undone, 1)

        let refused = reviews.post(key: chatKey, agent: "claude", title: "Docs", comments: 1, files: 1, window: 8) { false }
        let refusal = await serve(.undoReview(id: refused))
        XCTAssertEqual(failure(refusal)?.code, .requestEnded, "the agent had it already")
        reviews.finished(refused)
        XCTAssertFalse(reviews.events.contains { $0.id == refused })
    }

    // MARK: Answers

    /// Allow and Deny answer their own interaction with the chip's option; an approval answered already is `requestEnded`
    /// and sends nothing.
    func testApproveAndDenyAnswerTheirOwnRequests() async throws {
        start()
        _ = try await openThread()
        try notify("interaction.opened", ["interaction": ChatFixture.approval(id: "approval-1")])
        try notify("interaction.opened", ["interaction": ChatFixture.approval(id: "approval-2")])
        try await TestSupport.eventually { session?.approvals.count == 2 }

        var page = try page(await serve(.answer(key, request: "approval-1", .choice(WatchChoice(index: 0, label: "Allow", role: .allow)))))
        XCTAssertEqual(page.approvals.map(\.id), ["approval-2"], "the answered card leaves the page")
        try await TestSupport.eventually { helper.requests("interactions.answer").count == 1 }
        var sent = try XCTUnwrap(helper.requests("interactions.answer").last)
        XCTAssertEqual(sent.params["interaction"] as? String, "approval-1")
        XCTAssertEqual((sent.params["answers"] as? [String: Any])?["approval"] as? [UInt64], [0])

        page = try self.page(await serve(.answer(key, request: "approval-2", WatchAnswer(choice: 1))))
        XCTAssertTrue(page.approvals.isEmpty)
        try await TestSupport.eventually { helper.requests("interactions.answer").count == 2 }
        sent = try XCTUnwrap(helper.requests("interactions.answer").last)
        XCTAssertEqual(sent.params["interaction"] as? String, "approval-2")
        XCTAssertEqual((sent.params["answers"] as? [String: Any])?["approval"] as? [UInt64], [1])

        let answeredAgain = await serve(.answer(key, request: "approval-1", WatchAnswer(choice: 1)))
        XCTAssertEqual(failure(answeredAgain)?.code, .requestEnded)
        let neverAsked = await serve(.answer(key, request: "approval-9", WatchAnswer(choice: 0)))
        XCTAssertEqual(failure(neverAsked)?.code, .requestEnded)
        XCTAssertEqual(helper.requests("interactions.answer").count, 2, "a stale answer sends nothing")
    }

    /// A question form answers by option index per question; a side question per part, a typed answer where it allows
    /// one; Skip skips.
    func testQuestionFormsAndSideQuestionsAnswerPerPart() async throws {
        start()
        _ = try await openThread()
        try notify("interaction.opened", ["interaction": [
            "id": "form-1", "key": NSNull(), "approval": false, "blocking": true, "turn": NSNull(), "record": NSNull(),
            "questions": [["id": "q1", "header": "Runner", "text": "Which runners?", "secret": false, "multiple": true,
                           "custom": false, "blocks": NSNull(),
                           "options": [["id": "a", "label": "headed", "detail": NSNull()], ["id": "b", "label": "headless", "detail": NSNull()]]]]]])
        try notify("interaction.opened", ["interaction": [
            "id": "side-1", "key": NSNull(), "approval": false, "blocking": false, "turn": NSNull(), "record": NSNull(),
            "questions": [["id": "s1", "header": "Name", "text": "Branch name?", "secret": false, "multiple": false,
                           "custom": true, "blocks": NSNull(), "options": []],
                          ["id": "s2", "header": "Scope", "text": "Which packages?", "secret": false, "multiple": true,
                           "custom": false, "blocks": NSNull(),
                           "options": [["id": "x", "label": "api", "detail": NSNull()], ["id": "y", "label": "web", "detail": NSNull()]]]]]])
        try await TestSupport.eventually { session?.approvals.count == 1 && session?.questions.count == 1 }

        let incomplete = await serve(.answer(key, request: "form-1", WatchAnswer(options: [:])))
        XCTAssertEqual(failure(incomplete)?.code, .invalid, "nothing goes until every part is answered")
        var page = try page(await serve(.answer(key, request: "form-1", WatchAnswer(options: ["q1": [1, 0]]))))
        XCTAssertEqual(page.questions.map(\.id), ["side-1"])
        try await TestSupport.eventually { helper.requests("interactions.answer").count == 1 }
        var answers = helper.requests("interactions.answer").last?.params["answers"] as? [String: Any]
        XCTAssertEqual(answers?["q1"] as? [UInt64], [0, 1])

        page = try self.page(await serve(.answer(key, request: "side-1",
                                                 WatchAnswer(options: ["s2": [0, 1]], texts: ["s1": "fix/retries"]))))
        XCTAssertTrue(page.questions.isEmpty)
        try await TestSupport.eventually { helper.requests("interactions.answer").count == 2 }
        let side = try XCTUnwrap(helper.requests("interactions.answer").last)
        XCTAssertEqual(side.params["interaction"] as? String, "side-1")
        answers = side.params["answers"] as? [String: Any]
        XCTAssertEqual(answers?["s1"] as? String, "fix/retries")
        XCTAssertEqual(answers?["s2"] as? [UInt64], [0, 1])
    }

    // MARK: Composer and queue

    /// Idle, a message goes at once (`chat.send`); while the agent works it is queued (`queue.add`); steer goes into the
    /// running turn. The phone's own draft is never read or cleared.
    func testSendRoutesAsTheComposerAndLeavesTheDraft() async throws {
        start()
        _ = try await openThread()
        let chat = try XCTUnwrap(session)
        chat.drafts.edit(text: "half typed on the phone")

        var page = try page(await serve(.send(key, text: "Run the suite", steer: false)))
        try await TestSupport.eventually { helper.requests("chat.send").count == 1 }
        XCTAssertEqual(helper.requests("chat.send").last?.params["text"] as? String, "Run the suite")
        XCTAssertEqual(helper.requests("chat.send").last?.params["mode"] as? String, "prompt")
        XCTAssertEqual(page.items.last?.text, "Run the suite", "the prompt being sent shows last")
        XCTAssertEqual(chat.drafts.current.text, "half typed on the phone")

        try notify("chat.state", ["state": ChatFixture.state(busy: true)])
        try await TestSupport.eventually { chat.busy && !chat.sending }
        page = try self.page(await serve(.send(key, text: "Also lint", steer: false)))
        XCTAssertEqual(page.queue.map(\.text), ["Also lint"])
        try await TestSupport.eventually { helper.requests("queue.add").count == 1 && !chat.queueBusy }
        XCTAssertEqual(helper.requests("queue.add").last?.params["text"] as? String, "Also lint")
        XCTAssertEqual(page.route, .queue)

        _ = try self.page(await serve(.send(key, text: "keep it short", steer: true)))
        try await TestSupport.eventually { helper.requests("chat.send").count == 2 }
        XCTAssertEqual(helper.requests("chat.send").last?.params["mode"] as? String, "steer")
        XCTAssertEqual(chat.drafts.current.text, "half typed on the phone")
        let blank = await serve(.send(key, text: "  ", steer: false))
        XCTAssertEqual(failure(blank)?.code, .invalid)
    }

    /// A retried `sendMessage` (the same request id) is answered from the first: the message goes once, whether the
    /// retry comes during or after it.
    func testARetriedRequestSendsOnce() async throws {
        start()
        _ = try await openThread()
        let send = WatchAction.send(key, text: "Deploy it", steer: false)
        let first = Task { await self.serve(send, id: "request-1") }
        let during = Task { await self.serve(send, id: "request-1") }
        let replies = [await first.value, await during.value]
        XCTAssertEqual(replies[0], replies[1])
        let after = await serve(send, id: "request-1")
        XCTAssertEqual(after, replies[0])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(helper.requests("chat.send").count, 1)
        XCTAssertEqual(after.id, "request-1")
    }

    /// Stop interrupts the turn and pauses the queue; Resume restores the helper's stopped queue.
    func testStopAndResume() async throws {
        start()
        let opened = try await openThread(state: ChatFixture.state(busy: true))
        XCTAssertTrue(opened.canStop)
        _ = try page(await serve(.stop(key)))
        try await TestSupport.eventually { helper.requests("chat.stop").count == 1 }

        try notify("chat.queue", ["error": NSNull(), "items": [ChatFixture.queued("held-1", "Then lint", paused: "stopped")]])
        try await TestSupport.eventually { self.session?.queueStopped == true }
        _ = try page(await serve(.resume(key)))
        try await TestSupport.eventually { helper.requests("queue.restore").count == 1 }
    }

    /// Remove and Send now address the queue's rows by their stable ids; Send now refuses what the phone would.
    func testQueueRemoveAndSendNow() async throws {
        start()
        _ = try await openThread(state: ChatFixture.state(busy: true))
        try notify("chat.queue", ["error": NSNull(), "items": [
            ChatFixture.queued("held-1", "First"), ChatFixture.queued("held-2", "Second"),
            ChatFixture.queued("held-3", "Third", paused: "uncertain")]])
        try await TestSupport.eventually { self.session?.queue.count == 3 }

        _ = try page(await serve(.removeQueued(key, item: "helper:held-1")))
        try await TestSupport.eventually { helper.requests("queue.remove").count == 1 }
        XCTAssertEqual(helper.requests("queue.remove").last?.params["item"] as? String, "held-1")

        _ = try page(await serve(.sendQueuedNow(key, item: "helper:held-2")))
        try await TestSupport.eventually { helper.requests("queue.start").count == 1 }
        XCTAssertEqual(helper.requests("queue.start").last?.params["item"] as? String, "held-2")
        XCTAssertEqual(helper.requests("queue.start").last?.params["mode"] as? String, "steer")

        let paused = await serve(.sendQueuedNow(key, item: "helper:held-3"))
        let refused = try XCTUnwrap(failure(paused))
        XCTAssertEqual(refused.code, .notSent)
        XCTAssertEqual(refused.message, "Delivery could not be confirmed. Check the thread, then send or discard it.")
        let gone = await serve(.sendQueuedNow(key, item: "helper:gone"))
        XCTAssertEqual(failure(gone)?.code, .notSent)
        XCTAssertEqual(helper.requests("queue.start").count, 1)
    }

    // MARK: Seen

    /// `seen` moves the phone's marker to the watch's newest item, never past the newest record the phone holds and
    /// never back; the row stops showing an unseen result.
    func testSeenMovesThePhonesMarkerForwardOnly() async throws {
        start()
        let first: Int64 = 946_719_000_000, second: Int64 = 946_719_060_000
        _ = try await openThread(records: [
            ChatFixture.record("t1:started", "turn_started", turn: "t1", time: first),
            ChatFixture.record("u1", "user", turn: "t1", text: "Fix it", time: first),
            ChatFixture.record("a1", "assistant", turn: "t1", text: "Done.", time: first),
            ChatFixture.record("t1:ended", "turn_ended", turn: "t1", time: first)])
        let markers = app.conversations.markers
        XCTAssertEqual(markers.seen(host: record.id, conversation: conversation), first, "first sight is the baseline")
        try notify("chat.records", ["records": [
            ChatFixture.record("t2:started", "turn_started", turn: "t2", time: second),
            ChatFixture.record("a2", "assistant", turn: "t2", text: "Also fixed the retry.", time: second),
            ChatFixture.record("t2:ended", "turn_ended", turn: "t2", time: second)]])
        try await TestSupport.eventually { app.conversations.conversations.first?.unread == true }

        let later = Date(timeIntervalSince1970: Double(second) / 1000 + 600)
        guard case .done = await serve(.markSeen(key, through: later)).result else { return XCTFail("done") }
        XCTAssertEqual(markers.seen(host: record.id, conversation: conversation), second, "never past what the phone holds")
        XCTAssertEqual(app.conversations.conversations.first?.unread, false)

        _ = await serve(.markSeen(key, through: Date(timeIntervalSince1970: Double(first) / 1000)))
        XCTAssertEqual(markers.seen(host: record.id, conversation: conversation), second, "never back")
    }

    // MARK: Connect

    /// The host screen's Connect (`refresh` with the host) is the user's: it lifts the phone's Disconnect and connects.
    /// Pull to refresh and a thread leave a disconnected host alone.
    func testConnectLiftsADisconnectInTheForeground() async throws {
        start()
        let host = try XCTUnwrap(app.hosts.session(record.id))
        try await TestSupport.eventually { host.link == .connected }
        host.park()
        XCTAssertEqual(host.link, .disconnected)

        _ = await serve(.refresh(host: nil))
        XCTAssertTrue(host.parked, "pull to refresh is not Connect")
        XCTAssertEqual(host.link, .disconnected)

        let reply = await serve(.refresh(host: record.id.uuidString))
        guard case .snapshot = reply.result else { return XCTFail("Expected the lists, got \(reply.result)") }
        XCTAssertFalse(host.parked)
        try await TestSupport.eventually { host.link == .connected }
        XCTAssertTrue(holds.isEmpty, "the foreground connects the live session")
    }

    /// In the background Connect lifts the Disconnect and holds the host (its quiet connection); other requests do not
    /// connect a disconnected host.
    func testConnectLiftsADisconnectInTheBackground() async throws {
        start(active: false)
        let host = try XCTUnwrap(app.hosts.session(record.id))
        host.park()

        _ = await serve(.refresh(host: nil))
        XCTAssertEqual(holds, [record.id])
        XCTAssertTrue(host.parked)
        XCTAssertEqual(host.link, .disconnected, "the hold skips a disconnected host")

        _ = await serve(.refresh(host: record.id.uuidString))
        XCTAssertEqual(holds, [record.id, record.id])
        XCTAssertFalse(host.parked)
        try await TestSupport.eventually { host.link == .connected }
    }

    // MARK: Background

    /// In the background a host whose key needs Face ID cannot connect: actions answer `openPhone`, the thread is what
    /// the phone holds with that reason. Locked, the same: the host is still attempted, never `phoneLocked`.
    func testABackgroundHostBehindFaceIDAndALockedPhone() async throws {
        start(active: false, refusal: "User interaction is not allowed.")
        // What the launch cache gives the lists before any connection.
        app.hosts.session(record.id)?.restore(hello: HostFixture.hello(identity: "studio"), multiplexers: [], versions: [:],
                                              following: "tmux", topology: HelperDriver.topology)
        XCTAssertEqual(app.conversations.conversations.map(\.key), [chatKey])
        blocked = .faceID

        let stop = await serve(.stop(key))
        let refused = try XCTUnwrap(failure(stop))
        XCTAssertEqual(refused, .openPhone(host: "studio"))
        XCTAssertEqual(holds, [record.id])
        let page = try page(await serve(.thread(key, limit: 40)))
        XCTAssertEqual(page.phase, .offline)
        XCTAssertEqual(page.reason, WatchFailure.openPhone(host: "studio").message)

        blocked = nil
        let offline = await serve(.answer(key, request: "approval-1", WatchAnswer(choice: 0)))
        XCTAssertEqual(failure(offline)?.code, .hostOffline)

        locked = true
        blocked = .faceID
        holds = []
        let lockedStop = await serve(.stop(key))
        XCTAssertEqual(failure(lockedStop), .openPhone(host: "studio"))
        let lockedPage = try self.page(await serve(.thread(key, limit: 40)))
        XCTAssertEqual(lockedPage.phase, .offline)
        XCTAssertEqual(lockedPage.reason, WatchFailure.openPhone(host: "studio").message)
        XCTAssertEqual(holds, [record.id, record.id], "locked, the host is still attempted")
        XCTAssertTrue(helper.requests.isEmpty)
    }

    /// The phone locked, a password host still connects for the watch (passwords read after first unlock): the thread
    /// opens live and a message goes.
    func testALockedPhoneServesAPasswordHost() async throws {
        start(active: false)
        locked = true
        let opened = try await openThread()
        XCTAssertEqual(holds, [record.id], "held though the phone is locked")
        XCTAssertEqual(opened.phase, .live)
        let sent = await serve(.send(key, text: "Ship it", steer: false))
        XCTAssertNil(failure(sent))
        try await TestSupport.eventually { helper.requests("chat.send").count == 1 }
    }

    /// A request the bridge already answered `timedOut` (its task cancelled) changes nothing: the watch put its message
    /// back, so sending it too would send it twice once the user retries. The retry, with the same id, runs.
    func testARequestThatLostToTheBudgetChangesNothing() async throws {
        start()
        _ = try await openThread()
        let late = Task { await self.serve(.send(key, text: "Too late", steer: false), id: "late-1") }
        late.cancel()
        let abandoned = await late.value
        XCTAssertEqual(failure(abandoned)?.code, .timedOut)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(helper.requests("chat.send").isEmpty)
        XCTAssertNil(session?.optimisticPrompt)

        _ = try page(await serve(.send(key, text: "Too late", steer: false), id: "late-1"))
        try await TestSupport.eventually { helper.requests("chat.send").count == 1 }
    }

    /// Connection failures name the host's address and port; the watch gets the host's name instead.
    func testTheHostsAddressStaysOnThePhone() async throws {
        start(active: false, refusal: "studio.local refused the connection on port 22. Check that SSH is on.")
        app.hosts.session(record.id)?.restore(hello: HostFixture.hello(identity: "studio"), multiplexers: [], versions: [:],
                                              following: "tmux", topology: HelperDriver.topology)
        let said = "studio refused the connection on its SSH port. Check that SSH is on."
        let stop = await serve(.stop(key))
        XCTAssertEqual(failure(stop), WatchFailure(.hostOffline, said))
        let thread = try page(await serve(.thread(key, limit: 40)))
        XCTAssertEqual(thread.reason, said)
    }
}
