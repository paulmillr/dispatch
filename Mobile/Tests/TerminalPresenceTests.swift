import Foundation
import XCTest
@testable import DispatchMobile

/// A terminal attached without a view (the Chat segment's case): output parsed in coalesced batches, the screen
/// published to the helper at most 30 times a second, scrollback chosen by backend kind, and presences shared and
/// reattached by topology key.
@MainActor
final class TerminalPresenceTests: XCTestCase {
    func testPresenceParsesAndPublishesWithoutAView() async throws {
        let feed = ScriptedTerminalFeed(output: Data("\u{1B}[32m$\u{1B}[0m claude\r\n> \u{1B}[2mtry \"fix the tests\"\u{1B}[0m\r\u{1B}[2C".utf8))
        let presence = TerminalPresence(feed: feed, grid: (columns: 60, rows: 20), configuration: TerminalConfiguration())
        presence.start()
        XCTAssertEqual(feed.record.attachments.first?.columns, 60)
        XCTAssertEqual(feed.record.attachments.first?.rows, 20)
        try await TestSupport.eventually { !feed.record.screens.isEmpty }
        let screen = try XCTUnwrap(feed.record.screens.last)
        XCTAssertTrue(screen.text.hasPrefix("$ claude\n> try \"fix the tests\""), screen.text)
        XCTAssertEqual(screen.row, 1)
        XCTAssertEqual(screen.column, 2)
        XCTAssertTrue(screen.faintTail, "The suggestion after the cursor is faint")
        presence.stop()
        XCTAssertEqual(feed.record.detaches, 1)
    }

    /// Many small outputs (tmux sends one per `%output` line) become few parse batches and few publications;
    /// every byte arrives and the last screen is published.
    func testSmallOutputsAreCoalescedAndPublicationsThrottled() async throws {
        let line = "0123456789abcdefghijklmnopqr\n"  // 29 bytes, the spike's average tmux frame
        let count = 20_000
        let output = Data(String(repeating: line, count: count).utf8) + Data("\u{1B}[H\u{1B}[2Jdone".utf8)
        let feed = ScriptedTerminalFeed(output: output, options: .init(chunk: 29))
        let presence = TerminalPresence(feed: feed, grid: (columns: 40, rows: 10), configuration: TerminalConfiguration())
        let started = ContinuousClock.now
        presence.start()
        try await TestSupport.eventually(timeout: .seconds(30)) { presence.session.frameStats().bytesFed == output.count }
        let elapsed = ContinuousClock.now - started
        let stats = presence.session.frameStats()
        XCTAssertLessThan(stats.batches, count, "Coalesced: \(stats.batches) batches for \(count) events (the ratio depends on timing)")
        try await TestSupport.eventually { feed.record.screens.last?.text == "done" }
        let allowed = Int(elapsed / TerminalPresence.publishInterval) + 3
        XCTAssertLessThanOrEqual(feed.record.screens.count, allowed)
        presence.stop()
    }

    func testInboxKeepsOrderAndLimitsBatches() {
        let inbox = TerminalInbox()
        XCTAssertEqual(inbox.append(Data("ab".utf8)), .signal)
        XCTAssertEqual(inbox.append(Data("cdef".utf8)), .queued)
        XCTAssertEqual(inbox.take(limit: 4), Data("abcd".utf8))
        XCTAssertEqual(inbox.take(limit: 4), Data("ef".utf8))
        XCTAssertNil(inbox.take(limit: 4))
        XCTAssertEqual(inbox.append(Data("g".utf8)), .signal)
        inbox.clear()
        XCTAssertNil(inbox.take(limit: 4))
    }

    func testInboxRejectsAnEntireAppendAtItsByteLimit() {
        let inbox = TerminalInbox(limit: 5)
        XCTAssertEqual(inbox.append(Data("abc".utf8)), .signal)
        XCTAssertEqual(inbox.append(Data("def".utf8)), .overflow)
        XCTAssertEqual(inbox.take(limit: 10), Data("abc".utf8), "An overflowing event is never partly appended")
    }

    func testRemoteClipboardEventsDoNotChangeThePasteboard() async throws {
        let previous = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previous }
        UIPasteboard.general.string = "kept"
        let feed = ControlledFeed()
        let presence = TerminalPresence(feed: feed, configuration: TerminalConfiguration())
        presence.start()
        feed.events?.yield(.clipboard(Data("host-controlled".utf8)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(UIPasteboard.general.string, "kept")
        XCTAssertEqual(presence.configuration.config().clipboardWrite.rawValue, "deny")
        presence.stop()
    }

    func testScrollbackFollowsTheBackendKind() {
        XCTAssertEqual(TerminalScrollback(multiplexer: "tmux"), .client)
        XCTAssertEqual(TerminalScrollback(multiplexer: "herdr"), .server)
        XCTAssertEqual(TerminalScrollback(multiplexer: "native"), .unknown)
        XCTAssertEqual(TerminalScrollback(multiplexer: nil), .unknown)
        var tmux = TerminalScrollModel(scrollback: .client)
        XCTAssertEqual(tmux.route(5, local: .init(above: 2, below: 0)), .init(local: 5), "tmux: never the server")
        var herdr = TerminalScrollModel(scrollback: .server)
        XCTAssertEqual(herdr.server, .available)
        XCTAssertEqual(herdr.route(5, local: .init(above: 0, below: 0)), .init(server: 5))
        herdr.reattached()
        XCTAssertEqual(herdr.serverOffset, 0)
        XCTAssertEqual(herdr.server, .available, "Who owns history survives a reattach")
    }

    /// Chat and Terminal share one presence per node; a reconnect's new terminal id reattaches it with the new feed.
    func testPresencesAreSharedByKeyAndReattachAfterAReconnect() async throws {
        let first = ScriptedHelper.terminal(), second = ScriptedHelper.terminal()
        defer { first.close(); second.close() }
        let presences = TerminalPresences()
        let key = TerminalPresences.Key(host: UUID(), node: "app:%3")
        let presence = presences.open(key, feed: HelperTerminalFeed(client: first.client, terminal: 11), terminal: 11, scrollback: .client)
        presences.retain(key)
        let attach = try await first.wait(for: "terminals.attach")[0]
        first.notify(attach.id, .output(.init(terminal: 11, bytes: Data("before".utf8))), method: "terminal.output")
        try await TestSupport.eventually { presence.session.frameStats().bytesFed == 6 }
        XCTAssertTrue(presences.open(key, feed: HelperTerminalFeed(client: first.client, terminal: 11), terminal: 11) === presence)
        XCTAssertEqual(first.requests("terminals.attach").count, 1, "The same terminal is not attached twice")
        // The helper restarted: the node has a new id on the new connection.
        let reopened = presences.open(key, feed: HelperTerminalFeed(client: second.client, terminal: 4), terminal: 4)
        XCTAssertTrue(reopened === presence)
        let attach2 = try await second.wait(for: "terminals.attach")[0]
        try await TestSupport.eventually { first.cancellations.contains(attach.id) }
        second.notify(attach2.id, .output(.init(terminal: 4, bytes: Data("after".utf8))), method: "terminal.output")
        try await TestSupport.eventually { presence.session.locked { String(decoding: presence.session.surface.readText(.viewport), as: UTF8.self) } == "after" }
        presences.close(key)
        XCTAssertNil(presences.presence(key))
        XCTAssertFalse(presence.attached)
    }

    /// A new helper numbers its nodes from the start again, so an unchanged layout gives the same id after a reconnect:
    /// the presence still reattaches, through the new client, instead of restarting its feed on the closed one.
    func testAReconnectWithTheSameNodeIdReattachesThroughTheNewClient() async throws {
        let first = ScriptedHelper(), second = ScriptedHelper()
        defer { first.close(); second.close() }
        let presences = TerminalPresences()
        let key = TerminalPresences.Key(host: UUID(), node: "app:%3")
        let presence = presences.open(key, feed: HelperTerminalFeed(client: first.client, terminal: 11), terminal: 11,
                                      client: first.client, scrollback: .client)
        presences.retain(key)
        _ = try await first.wait(for: "terminals.attach")
        presences.stopAll(host: key.host)
        let reopened = presences.open(key, feed: HelperTerminalFeed(client: second.client, terminal: 11), terminal: 11,
                                      client: second.client)
        XCTAssertTrue(reopened === presence)
        _ = try await second.wait(for: "terminals.attach")
        XCTAssertTrue((presence.feed as? HelperTerminalFeed)?.client === second.client)
        XCTAssertEqual(first.requests("terminals.attach").count, 1, "Nothing is attached again on the old client")
        presences.close(key)
    }

    /// The Terminal segment asks for its presence on every update: an attachment that ended (the program exited, the
    /// attach failed) is not started again on the same feed, which would clear the last screen in a loop.
    func testAnEndedAttachmentIsNotRestartedByOpen() async throws {
        let feed = ScriptedTerminalFeed([.output(Data("bye".utf8)), .exit(0)])
        let presences = TerminalPresences()
        let key = TerminalPresences.Key(host: UUID(), node: "app:%4")
        let presence = presences.open(key, feed: feed)
        presences.retain(key)
        try await TestSupport.eventually { presence.ended != nil }
        for _ in 0..<3 { XCTAssertTrue(presences.open(key, feed: feed) === presence) }
        XCTAssertEqual(feed.record.attachments.count, 1)
        XCTAssertEqual(presence.ended, .exited(0))
        presences.close(key)
    }

    /// A presence is attached only while used (the Terminal segment on screen, a chat that needs the screen): the last
    /// release detaches it but keeps its screen, which stays drawn until the next attachment's first output repaints
    /// it; a presence nobody uses is not reattached after a reconnect.
    func testAPresenceIsAttachedOnlyWhileUsedAndKeepsItsLastScreen() async throws {
        let first = ScriptedHelper.terminal(), second = ScriptedHelper.terminal()
        defer { first.close(); second.close() }
        let presences = TerminalPresences()
        let key = TerminalPresences.Key(host: UUID(), node: "tmux:fixture:5")  // a terminal of the fixture topology
        let presence = presences.open(key, feed: HelperTerminalFeed(client: first.client, terminal: 7), terminal: 7, client: first.client)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(presence.attached, "made, not attached: nobody uses it yet")
        XCTAssertTrue(first.requests("terminals.attach").isEmpty)

        presences.retain(key)  // the Terminal segment appears
        presences.retain(key)  // a chat needs its screen
        let attach = try await first.wait(for: "terminals.attach")[0]
        first.notify(attach.id, .output(.init(terminal: 7, bytes: Data("last screen".utf8))), method: "terminal.output")
        try await TestSupport.eventually { presence.session.frameStats().bytesFed == 11 }
        presences.release(key)
        XCTAssertTrue(presence.attached, "the chat still uses it")
        presences.release(key)
        XCTAssertFalse(presence.attached, "the last user let go")
        try await TestSupport.eventually { first.cancellations.contains(attach.id) }
        XCTAssertTrue(presences.presence(key) === presence, "kept for an instant redisplay")
        let viewport = { presence.session.locked { String(decoding: presence.session.surface.readText(.viewport), as: UTF8.self) } }
        XCTAssertEqual(viewport(), "last screen")

        // A reconnect: an unused presence is not reattached; used again, it attaches through the new client and keeps
        // the last screen until the new attachment paints.
        presences.reopen(host: key.host, client: second.client, topology: HostFixture.topology())
        XCTAssertTrue(second.requests("terminals.attach").isEmpty)
        _ = presences.open(key, feed: HelperTerminalFeed(client: second.client, terminal: 9), terminal: 9, client: second.client)
        presences.retain(key)
        let attach2 = try await second.wait(for: "terminals.attach")[0]
        XCTAssertEqual(viewport(), "last screen", "no empty frame before the repaint")
        second.notify(attach2.id, .output(.init(terminal: 9, bytes: Data("fresh".utf8))), method: "terminal.output")
        try await TestSupport.eventually { viewport() == "fresh" }
        XCTAssertEqual(first.requests("terminals.attach").count, 1)
        presences.release(key)
        presences.release(key)  // an extra release is harmless
        XCTAssertFalse(presence.attached)
        presences.close(key)
    }

    /// An event of the old attachment whose hop to the main actor was queued before a reattach (the old helper's
    /// connection failing as the new one attaches) does not end the new attachment.
    func testAStaleEventOfTheOldAttachmentDoesNotEndTheNewOne() async throws {
        let old = ControlledFeed(), new = ControlledFeed()
        let presence = TerminalPresence(feed: old, grid: (columns: 40, rows: 10), configuration: TerminalConfiguration())
        presence.start()
        old.events?.yield(.failed("connection closed"))
        // Keep the main actor busy while the old attachment's consumer reaches its hop to it.
        Self.block(seconds: 0.2)
        presence.reattach(new)
        XCTAssertTrue(presence.attached)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(presence.attached, "The old attachment's failure ended the new one")
        XCTAssertNil(presence.ended)
        new.events?.yield(.exited(0))
        try await TestSupport.eventually { !presence.attached }
        XCTAssertEqual(presence.ended, .exited(0), "The current attachment's own end still counts")
        presence.stop()
    }

    /// Blocks the calling thread (the main actor here) without suspending.
    private static func block(seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    /// A feed whose events the test sends.
    final class ControlledFeed: TerminalFeed, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<TerminalFeedEvent>.Continuation?
        var events: AsyncStream<TerminalFeedEvent>.Continuation? { lock.withLock { continuation } }
        func attach(_ size: TerminalFeedSize) -> AsyncStream<TerminalFeedEvent> {
            let (stream, continuation) = AsyncStream<TerminalFeedEvent>.makeStream()
            lock.withLock { self.continuation = continuation }
            return stream
        }
        func detach() { lock.withLock { continuation }?.finish() }
        func send(_ input: Data) {}
        func resize(_ size: TerminalFeedSize) {}
        func scroll(_ request: TerminalScrollRequest) async -> TerminalScrollResult { .failed }
        func publish(_ screen: TerminalScreen) {}
    }

    func testHelperFeedPublishesTheLatestScreen() async throws {
        let peer = ScriptedHelper.terminal(open: ["terminals.attach", "terminals.publish"])
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 5)
        _ = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        feed.publish(TerminalScreen(text: "one", column: 3, row: 0, faintTail: false))
        let first = try await peer.wait(for: "terminals.publish")[0]
        feed.publish(TerminalScreen(text: "two", column: 3, row: 0, faintTail: false))
        feed.publish(TerminalScreen(text: "$ ls", column: 4, row: 1, faintTail: true))
        peer.reply(first.id, .empty)
        let published = try await peer.wait(for: "terminals.publish", count: 2)
        struct Screen: Decodable {
            struct Cursor: Decodable { let column: UInt32; let row: UInt32 }
            let terminal: UInt64, text: String, cursor: Cursor, faint_tail: Bool
        }
        struct Params: Decodable { let params: Screen }
        let latest = try HelperClientTests.decode(Params.self, published[1].body).params
        XCTAssertEqual(latest.terminal, 5)
        XCTAssertEqual(latest.text, "$ ls")
        XCTAssertEqual(latest.cursor.column, 4)
        XCTAssertEqual(latest.cursor.row, 1)
        XCTAssertTrue(latest.faint_tail)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(peer.requests("terminals.publish").count, 2, "Publications made during a call collapse to the latest")
    }
}
