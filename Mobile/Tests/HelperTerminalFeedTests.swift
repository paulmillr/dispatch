import Foundation
import XCTest
@testable import DispatchMobile

/// `HelperTerminalFeed` against the scripted helper (`ScriptedHelper`, over `Pipe()`): the attach
/// subscription's notifications become feed events; input, resizes and scroll steps go out in order, batched while
/// a call is in flight; detach cancels the observer and drops queued work.
final class HelperTerminalFeedTests: XCTestCase {
    struct Params<P: Decodable>: Decodable { let params: P }
    struct Input: Decodable { let terminal: UInt64; let bytes: Data }
    struct Resize: Decodable { let terminal: UInt64; let size: HelperTopology.Grid }
    struct Attach: Decodable { let terminal: UInt64; let size: HelperTopology.Grid; let takeover: Bool }
    struct Scroll: Decodable { let terminal: UInt64; let lines: Int64; let page: Bool; let column: UInt16?; let row: UInt16?; let modifiers: UInt8 }

    private func params<P: Decodable>(_ type: P.Type, _ request: ScriptedHelper.Request) throws -> P {
        try HelperClientTests.decode(Params<P>.self, request.body).params
    }

    /// The next `count` events of `stream`.
    private func events(_ stream: AsyncStream<TerminalFeedEvent>, count: Int) async -> [TerminalFeedEvent] {
        var out: [TerminalFeedEvent] = []
        for await event in stream {
            out.append(event)
            if out.count == count { break }
        }
        return out
    }

    func testAttachSendsTheGridAndStreamsTheNodesUpdates() async throws {
        let peer = ScriptedHelper.terminal(attached: false)
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 7)
        let stream = feed.attach(TerminalFeedSize(columns: 50, rows: 30, cellWidth: 22, cellHeight: 48))
        let attach = try await peer.wait(for: "terminals.attach")[0]
        let sent = try params(Attach.self, attach)
        XCTAssertEqual(sent.terminal, 7)
        XCTAssertEqual(sent.size, HelperTopology.Grid(columns: 50, rows: 30, cell_width: 22, cell_height: 48))
        XCTAssertFalse(sent.takeover)
        peer.notify(attach.id, .output(.init(terminal: 7, bytes: Data("hello".utf8))), method: "terminal.output")
        peer.notify(attach.id, .output(.init(terminal: 8, bytes: Data("other".utf8))), method: "terminal.output")
        peer.notify(attach.id, .history(.init(terminal: 7, offset: 3, max: 120, viewport: 30)), method: "terminal.scroll")
        peer.notify(attach.id, .attached, method: "terminal.attached")
        peer.notify(attach.id, .clipboard(.init(bytes: Data("copied".utf8))), method: "clipboard")
        peer.notify(attach.id, .exit(.init(terminal: 7, status: 0)), method: "terminal.exit")
        var received: [TerminalFeedEvent] = []
        for await event in stream { received.append(event) }
        XCTAssertEqual(received, [.output(Data("hello".utf8)), .history(.init(offset: 3, maximum: 120, viewport: 30)),
                                  .attached, .exited(0)], "Remote clipboard notifications are denied on the phone")
    }

    func testLargeOutputIsSplitBeforeEnteringTheBoundedEventQueue() async throws {
        let peer = ScriptedHelper.terminal()
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 7)
        let stream = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        let attach = try await peer.wait(for: "terminals.attach")[0]
        let sent = Data(repeating: 0x61, count: 150_000)
        peer.notify(attach.id, .output(.init(terminal: 7, bytes: sent)), method: "terminal.output")
        peer.notify(attach.id, .exit(.init(terminal: 7, status: 0)), method: "terminal.exit")
        var chunks: [Data] = []
        for await event in stream {
            if case .output(let bytes) = event { chunks.append(bytes) }
        }
        XCTAssertEqual(chunks.map(\.count), [64 * 1024, 64 * 1024, 18_928])
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, sent)
    }

    /// An attach replays a tmux pane's whole history as one `terminal.output`; a long one is more chunks than the old
    /// 128-event bound (8 MiB), which ended the attachment mid-replay: the screen froze and keys went nowhere.
    func testALongHistoryReplayArrivesWhole() async throws {
        let peer = ScriptedHelper.terminal()
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 7)
        let stream = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        let attach = try await peer.wait(for: "terminals.attach")[0]
        // Within one unchunked frame of the scripted helper (the real one chunks larger replies).
        let sent = Data(String(repeating: "00012345 lorem ipsum dolor sit amet\r\n", count: 300_000).utf8)
        XCTAssertGreaterThan(sent.count, 10 * 1024 * 1024)
        peer.notify(attach.id, .output(.init(terminal: 7, bytes: sent)), method: "terminal.output")
        peer.notify(attach.id, .exit(.init(terminal: 7, status: 0)), method: "terminal.exit")
        // The reply is yielded while nobody takes events yet, as when the presence's task is busy.
        try await Task.sleep(for: .seconds(1))
        var received = Data(), last: TerminalFeedEvent?
        for await event in stream {
            if case .output(let bytes) = event { received.append(bytes) } else { last = event }
        }
        XCTAssertEqual(received.count, sent.count)
        XCTAssertEqual(last, .exited(0), "The replay did not end the attachment")
    }

    /// A finger makes a scroll step per line or two; steps made while a call is in flight go out as one step, at the
    /// latest cell, and every caller gets the answer. One round trip per step made a swipe over a real link trail the
    /// finger by seconds, with typing queued behind it.
    @MainActor
    func testScrollStepsMadeDuringACallJoinIntoOneStep() async throws {
        let peer = ScriptedHelper { request in
            switch request.method {
            case "terminals.attach": .attachedNow
            case "terminals.input": .open
            case "terminals.scroll": .error(code: "scrollback_app_owned", message: "")
            default: .empty
            }
        }
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 7)
        _ = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        _ = try await peer.wait(for: "terminals.attach")
        // An unanswered input call holds the worker while the steps queue.
        feed.send(Data("x".utf8))
        let input = try await peer.wait(for: "terminals.input")[0]
        let answers = Answers()
        for (index, step) in [(lines: 2, row: 3), (lines: 3, row: 4), (lines: 1, row: 5)].enumerated() {
            Task { answers.append(await feed.scroll(TerminalScrollRequest(lines: step.lines, column: 1, row: step.row))) }
            try await TestSupport.eventually { feed.queuedCount == index + 1 }
        }
        feed.send(Data("y".utf8))
        peer.reply(input.id, .empty)
        let scroll = try await peer.wait(for: "terminals.scroll")[0]
        let sent = try params(Scroll.self, scroll)
        XCTAssertEqual(sent.lines, 6)
        XCTAssertEqual(sent.row, 5)
        try await TestSupport.eventually(diagnostic: "Every joined step is answered") { answers.all.count == 3 }
        XCTAssertEqual(answers.all, [.appOwned, .appOwned, .appOwned])
        let after = try await peer.wait(for: "terminals.input", count: 2)
        XCTAssertEqual(try params(Input.self, after[1]).bytes, Data("y".utf8), "Input after the steps keeps its place")
        XCTAssertEqual(peer.requests("terminals.scroll").count, 1)
    }

    /// A scroll step still queued when the attachment ends (a detach, or a reattach) answers `failed`: its caller (the
    /// pan gesture's task, which holds the feed) never stays suspended.
    @MainActor
    func testScrollStepsQueuedAtDetachOrReattachAreAnswered() async throws {
        let peer = ScriptedHelper.terminal(open: ["terminals.attach", "terminals.input"])
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 7)
        let answers = Answers()
        let ends = [{ feed.detach() }, { _ = feed.attach(TerminalFeedSize(columns: 80, rows: 24)) }]
        for (index, end) in ends.enumerated() {
            _ = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
            // An unanswered input call holds the worker, so the scroll step stays queued behind it.
            feed.send(Data("x".utf8))
            let input = try await peer.wait(for: "terminals.input", count: index + 1)[index]
            Task { answers.append(await feed.scroll(TerminalScrollRequest(lines: 3))) }
            try await TestSupport.eventually { feed.queuedCount == 1 }
            end()
            try await TestSupport.eventually(diagnostic: "The queued scroll step was never answered") { answers.all.count == index + 1 }
            peer.reply(input.id, .empty)
        }
        XCTAssertEqual(answers.all, [.failed, .failed])
    }

    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [TerminalScrollResult] = []
        func append(_ result: TerminalScrollResult) { lock.withLock { results.append(result) } }
        var all: [TerminalScrollResult] { lock.withLock { results } }
    }

    func testInputIsOrderedAndBatchedWhileACallIsInFlight() async throws {
        let peer = ScriptedHelper.terminal(open: ["terminals.attach", "terminals.input"])
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 7)
        _ = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        _ = try await peer.wait(for: "terminals.attach")
        feed.send(Data("a".utf8))
        let first = try await peer.wait(for: "terminals.input")[0]
        feed.send(Data("b".utf8))
        feed.send(Data("c".utf8))
        feed.send(Data("\r".utf8))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(peer.requests("terminals.input").count, 1, "Nothing more is sent while the first call is in flight")
        peer.reply(first.id, .empty)
        let inputs = try await peer.wait(for: "terminals.input", count: 2)
        XCTAssertEqual(try params(Input.self, inputs[0]).bytes, Data("a".utf8))
        XCTAssertEqual(try params(Input.self, inputs[1]).bytes, Data("bc\r".utf8))
        XCTAssertEqual(try params(Input.self, inputs[1]).terminal, 7)
    }

    func testResizesCollapseToTheLatestGrid() async throws {
        let peer = ScriptedHelper.terminal(open: ["terminals.attach", "terminals.resize"])
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 3)
        _ = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        _ = try await peer.wait(for: "terminals.attach")
        feed.resize(TerminalFeedSize(columns: 50, rows: 40, cellWidth: 21, cellHeight: 45))
        let first = try await peer.wait(for: "terminals.resize")[0]
        feed.resize(TerminalFeedSize(columns: 90, rows: 20))
        feed.resize(TerminalFeedSize(columns: 50, rows: 22, cellWidth: 21, cellHeight: 45))
        peer.reply(first.id, .empty)
        let resizes = try await peer.wait(for: "terminals.resize", count: 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(peer.requests("terminals.resize").count, 2)
        XCTAssertEqual(try params(Resize.self, resizes[0]).size, HelperTopology.Grid(columns: 50, rows: 40, cell_width: 21, cell_height: 45))
        XCTAssertEqual(try params(Resize.self, resizes[1]).size, HelperTopology.Grid(columns: 50, rows: 22, cell_width: 21, cell_height: 45))
    }

    func testScrollAnswersServerOrAppOwned() async throws {
        let owned = TestBox(false)
        let peer = ScriptedHelper { request in
            switch request.method {
            case "terminals.attach": .attachedNow
            case "terminals.scroll" where owned.value: .error(code: "scrollback_app_owned", message: "")
            default: .empty
            }
        }
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 9)
        let none = await feed.scroll(TerminalScrollRequest(lines: 1))
        XCTAssertEqual(none, .failed, "Not attached: nothing is sent")
        _ = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        let server = await feed.scroll(TerminalScrollRequest(lines: 3, column: 4, row: 10, modifiers: 1))
        XCTAssertEqual(server, .server)
        let sent = try params(Scroll.self, try await peer.wait(for: "terminals.scroll")[0])
        XCTAssertEqual(sent.terminal, 9)
        XCTAssertEqual(sent.lines, 3)
        XCTAssertEqual(sent.column, 4)
        XCTAssertEqual(sent.row, 10)
        XCTAssertEqual(sent.modifiers, 1)
        XCTAssertFalse(sent.page)
        owned.value = true
        let local = await feed.scroll(TerminalScrollRequest(lines: -2))
        XCTAssertEqual(local, .appOwned)
    }

    func testDetachCancelsTheObserverAndDropsQueuedWork() async throws {
        let peer = ScriptedHelper.terminal(open: ["terminals.attach", "terminals.input"])
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 7)
        let stream = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        let attach = try await peer.wait(for: "terminals.attach")[0]
        feed.send(Data("x".utf8))
        let input = try await peer.wait(for: "terminals.input")[0]
        feed.send(Data("dropped".utf8))
        feed.detach()
        var ended = false
        for await _ in stream {}
        ended = true
        XCTAssertTrue(ended, "Detaching finishes the attachment's events")
        let deadline = Date().addingTimeInterval(5)
        while !peer.cancellations.contains(attach.id), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(peer.cancellations.contains(attach.id), "The attach observer is cancelled; the session keeps running")
        peer.reply(input.id, .empty)
        feed.send(Data("after".utf8))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(peer.requests("terminals.input").count, 1)
        // A new attachment works again, with a new observer.
        _ = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        let attaches = try await peer.wait(for: "terminals.attach", count: 2)
        XCTAssertNotEqual(attaches[0].id, attaches[1].id)
    }

    /// Input waits for the helper to confirm the attach (`terminal.attached`), as the Mac's does: a multiplexer may
    /// refuse input to a terminal it has not attached yet.
    func testInputWaitsForTheAttachToBeConfirmed() async throws {
        let peer = ScriptedHelper.terminal(open: ["terminals.attach"], attached: false)
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 7)
        _ = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        let attach = try await peer.wait(for: "terminals.attach")[0]
        feed.send(Data("ls\r".utf8))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(peer.requests("terminals.input").isEmpty, "Held until the attach is confirmed")
        peer.notify(attach.id, .attached, method: "terminal.attached")
        let input = try await peer.wait(for: "terminals.input")[0]
        XCTAssertEqual(try params(Input.self, input).bytes, Data("ls\r".utf8))
    }

    func testFailedAttachEndsTheStream() async throws {
        let peer = ScriptedHelper.terminal(attached: false)
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 7)
        let stream = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        let attach = try await peer.wait(for: "terminals.attach")[0]
        peer.reply(attach.id, .error(code: "expired", message: "Terminal is gone."))
        let received = await events(stream, count: 1)
        XCTAssertEqual(received, [.failed("Terminal is gone.")])
    }

    func testScriptedFeedRecordsAndEchoes() async throws {
        let feed = ScriptedTerminalFeed([.output(Data(repeating: 0x41, count: 10)), .attached], options: .init(chunk: 4, echo: true))
        let stream = feed.attach(TerminalFeedSize(columns: 10, rows: 5))
        let first = await events(stream, count: 4)
        XCTAssertEqual(first, [.output(Data(repeating: 0x41, count: 4)), .output(Data(repeating: 0x41, count: 4)),
                               .output(Data(repeating: 0x41, count: 2)), .attached])
        feed.send(Data("ab\u{7F}\r".utf8))
        let echo = await events(stream, count: 1)
        XCTAssertEqual(echo, [.output(Data("ab\u{8} \u{8}\r\n".utf8) + Data(feed.options.prompt.utf8))])
        feed.resize(TerminalFeedSize(columns: 20, rows: 5))
        XCTAssertEqual(feed.record.resizes, [TerminalFeedSize(columns: 20, rows: 5)])
        XCTAssertEqual(feed.record.sent, Data("ab\u{7F}\r".utf8))
    }

    struct Follow: Decodable { let terminal: UInt64; let following: Bool; let subscription: UInt64? }

    /// `terminals.follow` goes out in order with the attachment's other calls, on its only subscription (no
    /// `subscription`), and says how it went: `done`, `unsupported` (sticky for the presence), `failed`; a follow queued
    /// when its attachment ends, or asked after, answers `stale` and sends nothing. A feed whose helper accepted no
    /// `terminals.follow` (or no `screens.host`) never asks, and only a `screens.host` feed refuses to publish.
    @MainActor
    func testFollowIsOrderedAndAnswersHowItWent() async throws {
        let peer = ScriptedHelper { request in
            switch request.method {
            case "terminals.attach": .attachedNow
            case "terminals.input": .open
            case "terminals.follow": (request.params["following"] as? Bool) == true ? .error(code: "unsupported", message: "") : .empty
            default: .empty
            }
        }
        defer { peer.close() }
        let feed = HelperTerminalFeed(client: peer.client, terminal: 7, features: [HelperSession.screensHost, HelperSession.terminalsFollow])
        XCTAssertTrue(feed.hostsScreens && feed.holdsOutput)
        _ = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        _ = try await peer.wait(for: "terminals.attach")
        feed.send(Data("x".utf8))
        let input = try await peer.wait(for: "terminals.input")[0]
        let answers = Recorder<TerminalFollowResult>()
        Task { answers.append(await feed.follow(false)) }
        try await TestSupport.eventually { feed.queuedCount == 1 }
        XCTAssertTrue(peer.requests("terminals.follow").isEmpty, "behind the input in flight")
        peer.reply(input.id, .empty)
        try await TestSupport.eventually { answers.values == [.done] }
        let sent = try params(Follow.self, peer.requests("terminals.follow")[0])
        XCTAssertEqual(sent.terminal, 7)
        XCTAssertFalse(sent.following)
        XCTAssertNil(sent.subscription)
        let unsupported = await feed.follow(true)
        XCTAssertEqual(unsupported, .unsupported)
        peer.script { request in
            switch request.method {
            case "terminals.attach": .attachedNow
            case "terminals.input": .open
            case "terminals.follow": .error(code: "tmux", message: "capture failed")
            default: .empty
            }
        }
        let failed = await feed.follow(true)
        XCTAssertEqual(failed, .failed)

        // Queued behind an input when the attachment ends: answered, never sent.
        feed.send(Data("y".utf8))
        let inputs = try await peer.wait(for: "terminals.input", count: 2)
        Task { answers.append(await feed.follow(false)) }
        try await TestSupport.eventually { feed.queuedCount == 1 }
        feed.detach()
        try await TestSupport.eventually { answers.values.count == 2 }
        peer.reply(inputs[1].id, .empty)
        XCTAssertEqual(answers.values.last, .stale)
        let after = await feed.follow(false)
        XCTAssertEqual(after, .stale)
        XCTAssertEqual(peer.requests("terminals.follow").count, 3)

        _ = feed.attach(TerminalFeedSize(columns: 80, rows: 24))
        _ = try await peer.wait(for: "terminals.attach", count: 2)
        feed.publish(TerminalScreen(text: "$ ", column: 2, row: 0, faintTail: false))
        let older = HelperTerminalFeed(client: peer.client, terminal: 8)
        let unheld = HelperTerminalFeed(client: peer.client, terminal: 9, features: [HelperSession.terminalsFollow])
        for other in [older, unheld] {
            XCTAssertFalse(other.hostsScreens || other.holdsOutput)
            _ = other.attach(TerminalFeedSize(columns: 80, rows: 24))
            let none = await other.follow(false)
            XCTAssertEqual(none, .unsupported)
            other.publish(TerminalScreen(text: "$ ", column: 2, row: 0, faintTail: false))
        }
        _ = try await peer.wait(for: "terminals.publish", count: 2)
        try await Task.sleep(for: .milliseconds(50))
        struct Published: Decodable { let terminal: UInt64 }
        XCTAssertEqual(Set(try peer.requests("terminals.publish").map { try params(Published.self, $0).terminal }), [8, 9],
                       "the screens.host feed publishes nothing")
        XCTAssertEqual(peer.requests("terminals.follow").count, 3)
    }
}

/// A value shared with `@Sendable` closures in tests.
final class TestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
