import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// Create review's Send, Copy and Undo (R5, S4), its targets and sheet, and `reviews.json`: through a scripted outlet,
/// a test clock and a sleep the test ends, so nothing waits for real time.
@MainActor
final class ReviewSendingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let place = ReviewPlace(host: TabsSample.mba2.id, root: "/Users/alex/src/app")
    private let tab = TabRef(host: TabsSample.mba2.id, key: "herdr:app:1")

    // MARK: Text

    /// The phone's review text is the Mac's (`ReviewText`, shared) for the same comments: host, branch and HEAD from the
    /// helper's status, the lines found again in the files as they are now.
    func testTheTextIsTheMacsFormat() async {
        let (review, _) = fixture()
        let rendered = await review.rendered(context: context(review))
        XCTAssertEqual(rendered, expected)
        XCTAssertEqual(review.preview(context: context(review)).components(separatedBy: "\n").dropFirst(),
                       expected.components(separatedBy: "\n").dropFirst(), "unrefreshed: the same body")
    }

    /// A comment whose line moved is sent at its new number; one whose file is gone says it changed.
    func testTheLinesAreFoundAgainBeforeSending() async {
        let (review, outlet) = fixture()
        var moved = ReviewSample.comments(now: now)[2]
        moved.start = ReviewLine(side: .new, number: 9)
        moved.end = ReviewLine(side: .new, number: 9)
        var gone = ReviewSample.comments(now: now)[0]
        gone.id = UUID()
        gone.path = "src/old/Removed.tsx"
        review.repository.update(moved.id, text: moved.text, in: place.scope)
        review.repository.remove(moved.id, from: place.scope)
        review.repository.add(moved, to: place.scope)
        review.repository.add(gone, to: place.scope)
        var reader = ReviewSample.reader
        let sample = reader.text
        reader.text = { path in
            if path.hasSuffix("Removed.tsx") { throw HelperFailure(code: "not_found", message: "") }
            return try await sample(path)
        }
        review.reader = { [reader] _ in reader }
        await review.send(to: target(), context: context(review))
        let text = try? XCTUnwrap(outlet.sent.first?.text)
        XCTAssertTrue(text?.contains("## src/components/ThemeToggle.tsx\n\nLine 12:") == true, text ?? "")
        XCTAssertTrue(text?.contains("## src/old/Removed.tsx\n\nLine 42 (the line has changed since; the quote is what it said):") == true,
                      text ?? "")
    }

    // MARK: Send and Undo

    func testSendTakesTheCommentsAndPostsToTheWatch() async throws {
        let (review, outlet) = fixture()
        review.sheet = tab
        await review.send(to: target(), context: context(review))
        XCTAssertEqual(outlet.sent.map(\.text), [expected])
        XCTAssertEqual(outlet.sent.first?.target.key, target().key)
        XCTAssertTrue(review.repository.review(place.scope).isEmpty, "the comments leave")
        XCTAssertEqual(review.repository.sentTo[place.scope], "claude")
        let sent = try XCTUnwrap(review.sent[place])
        XCTAssertEqual(sent.agent, "claude")
        XCTAssertEqual(sent.comments, 3)
        XCTAssertEqual(sent.files, 2)
        XCTAssertEqual(sent.until, now.addingTimeInterval(60))
        XCTAssertNil(review.sheet, "the sheet closes")
        let event = try XCTUnwrap(review.watch?.events.first)
        XCTAssertEqual(review.watch?.events.count, 1)
        XCTAssertEqual(event.key, target().key)
        XCTAssertEqual(event.agent, "claude")
        XCTAssertEqual(event.title, "claude")
        XCTAssertEqual(event.comments, 3)
        XCTAssertEqual(event.files, 2)
        XCTAssertEqual(event.undoUntil, now.addingTimeInterval(60))
        try await TestSupport.eventually { outlet.gate.asked == [.seconds(60)] }
    }

    func testUndoBeforeTheWindowBringsTheCommentsBackAndWithdraws() async throws {
        let (review, outlet) = fixture()
        await review.send(to: target(), context: context(review))
        await review.undo(place)
        XCTAssertEqual(review.repository.review(place.scope).comments.count, 3)
        XCTAssertEqual(outlet.withdrawn, 1)
        XCTAssertNil(review.sent[place])
        XCTAssertEqual(review.watch?.events.count, 0, "the watch stops offering Undo")
        try await TestSupport.eventually { outlet.gate.waiting == 0 }
    }

    /// The phone's Undo brings the comments back even when the helper refused to take the message back; the accessory
    /// says it was sent already.
    func testUndoAfterDeliveryStillRestores() async {
        let (review, outlet) = fixture()
        outlet.withdrawable = false
        await review.send(to: target(), context: context(review))
        await review.undo(place)
        XCTAssertEqual(review.repository.review(place.scope).comments.count, 3)
        XCTAssertEqual(outlet.withdrawn, 1)
        XCTAssertEqual(review.notices[place], "Already sent · comments restored")
    }

    /// An idle agent got the review at once: Undo restores the comments, withdraws nothing and says the agent has it; the
    /// watch never offers an Undo for it.
    func testUndoOfADeliveredReviewSaysTheAgentHasIt() async throws {
        let (review, outlet) = fixture()
        outlet.delivered = true
        await review.send(to: target(), context: context(review))
        XCTAssertEqual(review.watch?.open(at: now).count, 0, "no Undo on the watch")
        let id = try XCTUnwrap(review.watch?.events.first?.id)
        let watchUndo = await review.watch?.undo(id)
        XCTAssertEqual(watchUndo?.failureValue, .tooLate)
        await review.undo(place)
        XCTAssertEqual(review.repository.review(place.scope).comments.count, 3)
        XCTAssertEqual(outlet.withdrawn, 0)
        XCTAssertEqual(review.notices[place], "Comments restored · claude already has the review")
        try await TestSupport.eventually { outlet.gate.asked.contains(MobileReview.noticeDuration) }
        outlet.gate.open()
        try await TestSupport.eventually { review.notices[place] == nil }
    }

    /// A comment written during the window ends the repository's own Undo; the phone's still brings the sent ones back.
    func testUndoAfterANewCommentKeepsBoth() async {
        let (review, _) = fixture()
        await review.send(to: target(), context: context(review))
        var extra = ReviewSample.comments(now: now)[0]
        extra.id = UUID()
        extra.text = "One more."
        review.repository.add(extra, to: place.scope)
        await review.undo(place)
        XCTAssertEqual(review.repository.review(place.scope).comments.count, 4)
    }

    func testTheWindowsEndClearsTheNote() async throws {
        let (review, outlet) = fixture()
        await review.send(to: target(), context: context(review))
        XCTAssertNotNil(review.repository.copied[place.scope])
        try await TestSupport.eventually { outlet.gate.waiting == 1 }
        outlet.gate.open()
        try await TestSupport.eventually { review.sent[place] == nil }
        XCTAssertNil(review.repository.copied[place.scope], "forgetCopied")
        XCTAssertNil(review.repository.sentTo[place.scope])
        XCTAssertEqual(review.watch?.events.count, 0, "finished")
        XCTAssertTrue(review.repository.review(place.scope).isEmpty, "the agent keeps it")
        await review.undo(place)
        XCTAssertTrue(review.repository.review(place.scope).isEmpty, "nothing to undo after the window")
    }

    func testAFailedSendRestoresTheComments() async {
        let (review, outlet) = fixture()
        outlet.failure = ReviewSendError(message: "claude is not connected.")
        review.sheet = tab
        await review.send(to: target(), context: context(review))
        XCTAssertEqual(review.repository.review(place.scope).comments.count, 3)
        XCTAssertNil(review.repository.copied[place.scope], "never taken")
        XCTAssertEqual(review.failures[place], "claude is not connected. The review is in claude’s draft; the comments are still here.")
        XCTAssertEqual(outlet.drafted.map(\.text), [expected])
        XCTAssertNil(review.sent[place])
        XCTAssertEqual(review.sheet, tab, "the sheet stays to say why")
        XCTAssertEqual(review.watch?.events.count, 0)
        XCTAssertEqual(outlet.gate.asked, [])
        await review.send(to: target(), context: context(review))
        XCTAssertEqual(review.failures[place], "claude is not connected. The review is in claude’s draft; the comments are still here.")
        outlet.failure = nil
        await review.send(to: target(), context: context(review))
        XCTAssertNil(review.failures[place], "the next try clears it")
    }

    func testCopyClearsWithTheSameUndo() async {
        let (review, outlet) = fixture()
        review.sheet = tab
        await review.copy(context: context(review))
        XCTAssertEqual(outlet.copied, [expected])
        XCTAssertTrue(outlet.sent.isEmpty)
        XCTAssertNil(review.sent[place]?.agent, "Copied")
        XCTAssertEqual(review.sent[place]?.comments, 3)
        XCTAssertNil(review.repository.sentTo[place.scope])
        XCTAssertEqual(review.watch?.events.count, 0, "no watch event for a copy")
        XCTAssertNil(review.sheet)
        await review.undo(place)
        XCTAssertEqual(review.repository.review(place.scope).comments.count, 3)
        XCTAssertNil(review.sent[place])
    }

    func testAnEmptyReviewSendsNothing() async {
        let (review, outlet) = fixture(comments: [])
        await review.send(to: target(), context: context(review))
        await review.copy(context: context(review))
        XCTAssertTrue(outlet.sent.isEmpty)
        XCTAssertTrue(outlet.copied.isEmpty)
        XCTAssertNil(review.sent[place])
    }

    /// The watch's Undo takes the review back while the message can be withdrawn, else says it is too late.
    func testTheWatchsUndo() async throws {
        let (review, outlet) = fixture()
        await review.send(to: target(), context: context(review))
        let id = try XCTUnwrap(review.watch?.events.first?.id)
        let undone = await review.watch?.undo(id)
        XCTAssertNoThrow(try undone?.get())
        XCTAssertEqual(review.repository.review(place.scope).comments.count, 3)
        XCTAssertNil(review.sent[place])
        XCTAssertEqual(outlet.withdrawn, 1)

        outlet.withdrawable = false
        await review.send(to: target(), context: context(review))
        let late = try XCTUnwrap(review.watch?.events.first?.id)
        let tooLate = await review.watch?.undo(late)
        XCTAssertEqual(tooLate?.failureValue, .tooLate)
        XCTAssertTrue(review.repository.review(place.scope).isEmpty, "the agent has it: the comments stay sent")
        XCTAssertNotNil(review.sent[place])
    }

    // MARK: Delivery into a conversation

    /// A review queued on the device is withdrawn while still queued; once delivered (no longer queued) it is not.
    func testWithdrawAgainstTheDeviceQueue() async throws {
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore())
        let session = MobileChatSession.scripted(ScriptedHelper(), outbox: outbox, connected: false)
        let delivery = try await MobileComposition.send("Code review …", to: session).get()
        XCTAssertFalse(delivery.delivered)
        XCTAssertEqual(outbox.items.map(\.text), ["Code review …"])
        let first = await delivery.withdraw()
        XCTAssertTrue(first)
        XCTAssertTrue(outbox.items.isEmpty)
        let again = await delivery.withdraw()
        XCTAssertFalse(again, "gone already")

        let second = try await MobileComposition.send("Code review again", to: session).get()
        outbox.remove(try XCTUnwrap(outbox.items.first?.id))
        let delivered = await second.withdraw()
        XCTAssertFalse(delivered, "delivered: the agent has it")
    }

    /// Queued in the helper behind a running turn: Undo removes it there (`queue.remove`); sent at once to an idle agent
    /// it cannot come back.
    func testWithdrawAgainstTheHelpersQueueAndAPrompt() async throws {
        let helper = ScriptedHelper()
        helper.script { request in
            switch request.method {
            case "chat.open": .open
            case "queue.list": .result([Any]())
            case "queue.add": .result(ChatFixture.queued("held-1", request.params["text"] as! String))
            case "chat.send": .result(ChatFixture.sent())
            default: .result(NSNull())
            }
        }
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore())
        let session = MobileChatSession.scripted(helper, outbox: outbox)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        let conversation = "00000000-0000-4000-8000-000000000201"
        helper.notify(id, "chat.history", ChatFixture.history(session: conversation, state: ChatFixture.state(busy: true), pending: true))
        helper.notify(id, "chat.history", ChatFixture.history(session: conversation, records: []))
        try await TestSupport.eventually { session.phase == .verified && !session.loadingHistory }

        let queued = try await MobileComposition.send("Code review of the uncommitted changes", to: session).get()
        XCTAssertFalse(queued.delivered)
        try await TestSupport.eventually { session.queueItems.first?.helperID == "held-1" }
        let withdrawn = await queued.withdraw()
        XCTAssertTrue(withdrawn, "queue.remove answered")
        XCTAssertEqual(helper.requests("queue.remove").count, 1)
        XCTAssertEqual(helper.requests("queue.remove").first?.params["item"] as? String, "held-1")
        XCTAssertTrue(session.queueItems.isEmpty)

        // The helper's queue says it is gone, and the agent is idle.
        helper.notify(id, "chat.queue", ["terminal": 7, "session": conversation, "error": NSNull(), "items": []])
        helper.notify(id, "chat.state", ["terminal": 7, "session": conversation, "state": ChatFixture.state(busy: false)])
        try await TestSupport.eventually { !session.working && session.queueItems.isEmpty && session.queueRows.isEmpty }
        XCTAssertEqual(session.route(steer: false), .prompt)
        let prompt = try await MobileComposition.send("Another review", to: session).get()
        XCTAssertEqual(helper.requests("chat.send").count, 1, "confirmed before Send returns")
        XCTAssertTrue(prompt.delivered)
        let back = await prompt.withdraw()
        XCTAssertFalse(back, "sent to an idle agent at once")
    }

    /// A queued review the helper is already typing (`queue.remove` refused `busy`): Undo restores the comments, says it
    /// was sent, and the watch's Undo answers too late.
    func testABusyQueueRemoveIsNotAWithdrawal() async throws {
        let helper = ScriptedHelper()
        helper.script { request in
            switch request.method {
            case "chat.open": .open
            case "queue.list": .result([Any]())
            case "queue.add": .result(ChatFixture.queued("held-1", request.params["text"] as! String))
            case "queue.remove": .error(code: "busy", message: "The message is being typed.")
            default: .result(NSNull())
            }
        }
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore())
        let session = try await busySession(helper, outbox: outbox)
        let (review, outlet) = fixture()
        review.outlet.send = { text, _ in await MobileComposition.send(text, to: session) }
        await review.send(to: target(), context: context(review))
        try await TestSupport.eventually { session.queueItems.first?.helperID == "held-1" }
        let id = try XCTUnwrap(review.watch?.events.first?.id)
        XCTAssertEqual(review.watch?.open(at: now).count, 1, "queued: the watch offers Undo")
        let watchUndo = await review.watch?.undo(id)
        XCTAssertEqual(watchUndo?.failureValue, .tooLate, "the helper refused")
        XCTAssertTrue(review.repository.review(place.scope).isEmpty, "the agent gets it: the comments stay sent")
        await review.undo(place)
        XCTAssertEqual(helper.requests("queue.remove").count, 2)
        XCTAssertEqual(review.repository.review(place.scope).comments.count, 3)
        XCTAssertEqual(review.notices[place], "Already sent · comments restored")
        XCTAssertEqual(session.queueItems.count, 1, "still queued: the helper sends it")
        _ = outlet
    }

    /// A review to an idle agent whose `chat.send` fails (the terminal went, the link dropped): the comments stay, the
    /// review is in the conversation's draft and the sheet says why.
    func testAFailedPromptKeepsTheCommentsAndDraftsTheReview() async throws {
        for (code, message) in [("terminal_unavailable", "The terminal is gone."), ("connection_closed", "mba2 is not connected.")] {
            let helper = ScriptedHelper()
            helper.script { request in
                switch request.method {
                case "chat.open": .open
                case "queue.list": .result([Any]())
                case "chat.send": .error(code: code, message: message)
                default: .result(NSNull())
                }
            }
            let session = try await idleSession(helper)
            session.drafts.edit(text: "A message I was writing")
            let (review, _) = fixture()
            review.sheet = tab
            review.outlet.send = { text, _ in await MobileComposition.send(text, to: session) }
            review.outlet.draft = { text, _ in MobileComposition.draft(text, in: session) }
            await review.send(to: target(), context: context(review))
            XCTAssertEqual(helper.requests("chat.send").count, 1, code)
            XCTAssertEqual(review.repository.review(place.scope).comments.count, 3, "\(code): the comments stay")
            XCTAssertNil(review.sent[place], code)
            XCTAssertEqual(review.sheet, tab, "\(code): the sheet stays to say why")
            let failure = try XCTUnwrap(review.failures[place], code)
            XCTAssertTrue(failure.hasSuffix("The review is in claude’s draft; the comments are still here."), failure)
            XCTAssertEqual(session.drafts.current.text, expected, "\(code): the review is the draft")
            XCTAssertTrue(session.drafts.saved.contains { $0.text == "A message I was writing" }, "\(code): the old draft is kept")
            XCTAssertEqual(review.watch?.events.count, 0, code)
        }
    }

    // MARK: Targets

    /// The tab's own agent first, then the space's other agents in order; a tab without one lists the others.
    func testTargetsPutTheTabsOwnAgentFirst() {
        let tabs = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults())
        let sketch = TopologySketch(spaces: [
            .init(key: "herdr:web", name: "web", tabs: [
                .init(key: "herdr:web:1", name: "zsh", panes: [.init(key: "p:zsh", cwd: "/Users/alex/src/web")]),
                .init(key: "herdr:web:2", name: "codex", renamed: true, panes: [.init(key: "p:codex", agent: "s1")]),
                .init(key: "herdr:web:3", name: "claude", renamed: true, panes: [.init(key: "p:claude", agent: "s2")]),
            ]),
            .init(key: "herdr:api", name: "api", tabs: [
                .init(key: "herdr:api:1", name: "pi", renamed: true, panes: [.init(key: "p:pi", agent: "s3")]),
            ]),
        ])
        tabs.sync([TabsHostInput(host: TabsFixtures.host, client: nil, topology: sketch.topology)])
        let describe: (ChatConversationKey, MobilePane) -> (agent: String, model: String?) = { key, _ in
            (String(key.node.dropFirst(2)), key.node == "p:claude" ? "fable-5.1" : nil)
        }
        func targets(_ key: String) -> [ReviewTarget] {
            MobileComposition.reviewTargets(for: TabRef(host: TabsFixtures.host.id, key: key), tabs: tabs, describe: describe)
        }
        let fromClaude = targets("herdr:web:3")
        XCTAssertEqual(fromClaude.map(\.agent), ["claude", "codex"])
        XCTAssertEqual(fromClaude.map(\.here), [true, false])
        XCTAssertEqual(fromClaude.first?.key, ChatConversationKey(host: TabsFixtures.host.id, node: "p:claude"))
        XCTAssertEqual(fromClaude.first.map(CreateReviewSheet.caption), "this tab · web · fable-5.1")
        XCTAssertEqual(fromClaude.last.map(CreateReviewSheet.caption), "codex · web")
        let fromShell = targets("herdr:web:1")
        XCTAssertEqual(fromShell.map(\.agent), ["codex", "claude"])
        XCTAssertFalse(fromShell.contains(where: \.here))
        XCTAssertEqual(CreateReviewSheet.noAgentCaption(fromShell), "Copy the review, or send it to codex · web")
        XCTAssertEqual(targets("herdr:api:1").map(\.agent), ["pi"], "only the tab's space")
        XCTAssertEqual(MobileComposition.agentName(executable: "/opt/homebrew/bin/codex"), "codex")
        XCTAssertEqual(MobileComposition.agentName(executable: nil), "agent")
    }

    /// The Spaces sample's targets as R5 and R5c read them.
    func testTheSamplesTargets() async {
        let composition = MobileComposition(hosts: ResilienceFixture.sessions([]), tabs: TabsSample.model(now: now),
                                            outbox: ChatOutbox(store: ChatOutboxMemoryStore()), feedsTabs: false,
                                            splitMemory: nil, review: MobileReview(repository: ReviewRepository(store: ReviewMemoryStore())))
        let claude = composition.review.targets(tab)
        XCTAssertEqual(claude.map(\.agent), ["claude"])
        XCTAssertEqual(claude.first.map(CreateReviewSheet.caption), "this tab · app · fable-5.1")
        let dev = composition.review.targets(TabRef(host: TabsSample.mba2.id, key: "herdr:app:2"))
        XCTAssertEqual(CreateReviewSheet.noAgentCaption(dev), "Copy the review, or send it to claude · app")
        guard case .success = await composition.review.outlet.send("text", claude[0]) else { return XCTFail("the sample's send succeeds") }
    }

    // MARK: Persistence

    /// `reviews.json` keeps the comments across launches, owner-only and out of backups; Remove all data empties it.
    func testCommentsSurviveRelaunchAndRemoveAllClearsThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reviews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("reviews.json")
        let first = ReviewRepository(store: ReviewFileStore(url: url))
        for comment in ReviewSample.comments(now: now) { first.add(comment, to: place.scope) }
        first.setSummary("Keep the toggle small.", in: place.scope)
        first.flush()

        let relaunched = ReviewRepository(store: ReviewFileStore(url: url))
        XCTAssertEqual(relaunched.review(place.scope).comments.map(\.id), ReviewSample.comments(now: now).map(\.id))
        XCTAssertEqual(relaunched.review(place.scope).summary, "Keep the toggle small.")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        let review = MobileReview(repository: relaunched, clock: { [now] in now })
        review.file = url
        review.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Remove all data deletes reviews.json")
        XCTAssertTrue(review.repository.reviews.isEmpty)
        XCTAssertTrue(ReviewRepository(store: ReviewFileStore(url: url)).reviews.isEmpty)
    }

    /// `reviews.json` is read on first use, not when the composition is made; a file that cannot be read is never
    /// written over, the list says so, and comments are still taken in memory until Remove all data starts over.
    func testTheFileIsReadLazilyAndAnUnreadableOneIsKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reviews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("reviews.json")
        try Data("not json".utf8).write(to: url)
        var made = 0
        let review = MobileReview(repository: { made += 1; return ReviewRepository(store: ReviewFileStore(url: url)) }(),
                                  clock: { [now] in now })
        review.file = url
        XCTAssertEqual(made, 0, "nothing read yet")
        XCTAssertEqual(review.count(place), 0)
        XCTAssertEqual(made, 1)
        let error = try XCTUnwrap(review.repository.error)
        XCTAssertTrue(error.hasPrefix("Reviews could not be read"), error)
        review.repository.add(ReviewSample.comments(now: now)[0], to: place.scope)
        XCTAssertEqual(review.count(place), 1, "kept in memory")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json", "never written over")
        let banner = ReviewStoreBanner(error: error)
        let (window, host) = try show(banner, size: CGSize(width: 400, height: 120))
        defer { window.isHidden = true }
        XCTAssertTrue(accessibilityElements(host.view).contains { ($0.accessibilityLabel ?? "").contains("Comments are kept until Dispatch quits") })
        review.removeAll()
        XCTAssertNil(review.repository.error)
        review.repository.add(ReviewSample.comments(now: now)[0], to: place.scope)
        XCTAssertEqual(ReviewRepository(store: ReviewFileStore(url: url)).review(place.scope).comments.count, 1, "writable again")
        XCTAssertEqual(made, 1)
    }

    /// The helper reader's memory keys a connection by a token of its own: another client is another connection.
    func testTheGitMemoryKeysEachConnectionApart() {
        let memory = ReviewGitMemory()
        let first = ScriptedHelper().client, second = ScriptedHelper().client
        XCTAssertEqual(memory.token(first), memory.token(first))
        XCTAssertNotEqual(memory.token(first), memory.token(second))
        let git = ReviewHelperGit(client: first, memory: memory)
        XCTAssertEqual(git.key("/r"), git.key("/r"))
        XCTAssertNotEqual(git.key("/r"), ReviewHelperGit(client: second, memory: memory).key("/r"))
    }

    // MARK: Sheet

    func testTheSheetReadsItsLabelsWithAndWithoutAnAgent() throws {
        let (review, _) = fixture()
        let (window, host) = try show(CreateReviewSheet(context: context(review)))
        defer { window.isHidden = true }
        let labels = Set(accessibilityElements(host.view).compactMap(\.accessibilityLabel))
        for label in ["To claude", "Send to claude", "Copy review", "Preview", "Overall comment", "Dictate",
                      "Sidebar.tsx, Line 42: Use a data-theme attribute instead of a class per theme, the CSS tokens key off it already.",
                      "Sidebar.tsx, Lines 45–48: Keep the old markup. The unread class belongs on the link, not the item, and `end` breaks nested routes.",
                      "ThemeToggle.tsx, Line 12: The system option should be first."] {
            XCTAssertTrue(labels.contains(label), "missing \(label) in \(labels.sorted())")
        }
        XCTAssertEqual(CreateReviewSheet.header(review.repository.review(place.scope)), "3 comments · 2 files")
        XCTAssertEqual(ReviewSheetCommentRow.lines(ReviewSample.comments(now: now)[1]), "45–48")

        review.targets = { [place] _ in
            [ReviewTarget(key: ChatConversationKey(host: place.host, node: "p:app:claude"), agent: "claude", tab: "claude",
                          space: "app", model: "fable-5.1", here: false)]
        }
        let (other, noAgent) = try show(CreateReviewSheet(context: context(review)))
        defer { other.isHidden = true }
        let elements = accessibilityElements(noAgent.view)
        let none = Set(elements.compactMap(\.accessibilityLabel))
        XCTAssertTrue(none.contains("No agent in this tab"), "\(none.sorted())")
        XCTAssertTrue(none.contains("Copy review"))
        XCTAssertFalse(none.contains("Send to claude"))
        XCTAssertEqual(elements.first { $0.accessibilityLabel == "No agent in this tab" }?.accessibilityValue,
                       "Copy the review, or send it to claude · app")
    }

    // MARK: Support

    private var expected: String {
        let sidebar = ReviewSample.sidebar, toggle = ReviewSample.themeToggle
        return """
        Code review of the uncommitted changes in /Users/alex/src/app on mba2 (dark-mode at 3f2c1a0): 3 comments on 2 files.

        Address each comment below. Paths are relative to the repository root. Line numbers are the file's as it is now \
        (removed lines as numbered in the old version); the quoted lines show what each comment is about, marked + added, - removed.

        ## src/components/Sidebar.tsx

        Line 42:
        ```diff
        +\(sidebar[41])
        ```
        Use a data-theme attribute instead of a class per theme, the CSS tokens key off it already.

        Lines 45–48:
        ```diff
        +\(sidebar[44])
        +\(sidebar[45])
        +\(sidebar[46])
        +\(sidebar[47])
        ```
        Keep the old markup. The unread class belongs on the link, not the item, and `end` breaks nested routes.

        ## src/components/ThemeToggle.tsx

        Line 12:
        ```diff
        +\(toggle[11])
        ```
        The system option should be first.

        """
    }

    private func fixture(comments: [ReviewComment]? = nil) -> (MobileReview, ScriptedOutlet) {
        let store = ReviewMemoryStore([place.scope: Review(comments: comments ?? ReviewSample.comments(now: now), modified: now)])
        let review = MobileReview(repository: ReviewRepository(store: store), clock: { [now] in now })
        review.reader = { _ in ReviewSample.reader }
        review.targets = { [tab] _ in [Self.target(tab)] }
        review.watch = WatchReviewEvents(clock: { [now] in now })
        let outlet = ScriptedOutlet()
        review.outlet = outlet.outlet
        let gate = outlet.gate
        review.sleep = { duration in try await gate.sleep(duration) }
        return (review, outlet)
    }

    private func target() -> ReviewTarget { Self.target(tab) }

    /// A verified session whose agent is idle.
    private func idleSession(_ helper: ScriptedHelper, outbox: ChatOutbox = ChatOutbox(store: ChatOutboxMemoryStore())) async throws
        -> MobileChatSession {
        try await verifiedSession(helper, outbox: outbox, busy: false)
    }

    /// A verified session whose agent works: a review is queued in the helper.
    private func busySession(_ helper: ScriptedHelper, outbox: ChatOutbox) async throws -> MobileChatSession {
        try await verifiedSession(helper, outbox: outbox, busy: true)
    }

    private func verifiedSession(_ helper: ScriptedHelper, outbox: ChatOutbox, busy: Bool) async throws -> MobileChatSession {
        let session = MobileChatSession.scripted(helper, outbox: outbox)
        try await TestSupport.eventually { helper.subscription("chat.open") != nil }
        let id = try XCTUnwrap(helper.subscription("chat.open"))
        let conversation = "00000000-0000-4000-8000-000000000201"
        helper.notify(id, "chat.history", ChatFixture.history(session: conversation, state: ChatFixture.state(busy: busy), pending: true))
        helper.notify(id, "chat.history", ChatFixture.history(session: conversation, records: []))
        try await TestSupport.eventually { session.phase == .verified && !session.loadingHistory }
        XCTAssertEqual(session.route(steer: false), busy ? .queue : .prompt)
        return session
    }

    private static func target(_ tab: TabRef) -> ReviewTarget {
        ReviewTarget(key: ChatConversationKey(host: tab.host, node: "p:app:claude"), agent: "claude", tab: "claude", space: "app",
                     model: "fable-5.1", here: true)
    }

    private func context(_ review: MobileReview) -> ReviewContext {
        ReviewContext(review: review, place: place, tab: tab, host: "mba2", branch: "dark-mode", offline: false, push: { _ in })
    }

    private func defaults() -> UserDefaults {
        let suite = "review-sending"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func show(_ view: some View, size: CGSize = CGSize(width: 440, height: 956)) throws -> (UIWindow, UIViewController) {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return (window, host)
    }

    private func accessibilityElements(_ view: UIView) -> [NSObject] {
        var found: [NSObject] = []
        func walk(_ element: NSObject) {
            if element.isAccessibilityElement { found.append(element) }
            for child in (element.accessibilityElements as? [NSObject]) ?? [] { walk(child) }
            if let view = element as? UIView { for sub in view.subviews { walk(sub) } }
        }
        walk(view)
        return found
    }
}

/// An outlet that records what it was given, fails when told to, and counts withdrawals.
@MainActor
private final class ScriptedOutlet {
    var sent: [(text: String, target: ReviewTarget)] = []
    var copied: [String] = []
    var failure: ReviewSendError?
    var withdrawable = true
    var withdrawn = 0
    /// The agent got it at once (an idle agent's prompt).
    var delivered = false
    var drafted: [(text: String, target: ReviewTarget)] = []
    let gate = ReviewSleepGate()

    var outlet: ReviewOutlet {
        // Held strongly: a test may drop the outlet and still Undo.
        ReviewOutlet(send: { [self] text, target in
            if let failure { return .failure(failure) }
            sent.append((text, target))
            return .success(ReviewDelivery(delivered: delivered, withdraw: { [self] in
                withdrawn += 1
                return withdrawable
            }))
        }, copy: { [self] in copied.append($0) }, draft: { [self] text, target in drafted.append((text, target)) })
    }
}

/// The Undo window's sleep: it ends when the test opens the gate, or when its task is cancelled.
@MainActor
private final class ReviewSleepGate {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private(set) var asked: [Duration] = []
    var waiting: Int { waiters.count }

    func sleep(_ duration: Duration) async throws {
        asked.append(duration)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.hold(id, continuation)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(id) }
        }
    }

    func open() {
        let all = waiters
        waiters = [:]
        for continuation in all.values { continuation.resume() }
    }

    private func hold(_ id: UUID, _ continuation: CheckedContinuation<Void, any Error>) {
        if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { waiters[id] = continuation }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
