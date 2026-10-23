import Foundation
import XCTest
@testable import DispatchMobile

/// A plain SSH shell as a terminal feed (docs/ios.md, Plain SSH): the PTY opens at the attach size, `.attached` comes as
/// soon as it is open and before its output, sizes become window-changes, the shell's end is the attachment's end, and
/// detaching closes the shell for good. Played against `ScriptedShellOpener`'s shells.
final class PlainShellFeedTests: XCTestCase {
    private struct Refused: LocalizedError {
        var errorDescription: String? { "The host refused the shell." }
    }

    /// Reads a feed's events one at a time.
    private final class Events: @unchecked Sendable {
        private var iterator: AsyncStream<TerminalFeedEvent>.Iterator
        init(_ stream: AsyncStream<TerminalFeedEvent>) { iterator = stream.makeAsyncIterator() }
        func next() async -> TerminalFeedEvent? {
            var reading = iterator
            defer { iterator = reading }
            return await reading.next()
        }
        /// Every event to the end of the stream.
        func rest() async -> [TerminalFeedEvent] {
            var events: [TerminalFeedEvent] = []
            while let event = await next() { events.append(event) }
            return events
        }
    }

    private static func size(_ columns: Int, _ rows: Int) -> TerminalFeedSize {
        TerminalFeedSize(columns: columns, rows: rows, cellWidth: 30, cellHeight: 60)
    }

    func testTheShellOpensAtTheAttachSizeAndAttachedComesBeforeItsOutput() async throws {
        let opener = ScriptedShellOpener { term, columns, rows in
            ScriptedShell(term: term, columns: columns, rows: rows, output: [Data("Last login: Mon\r\n".utf8), Data("$ ".utf8)])
        }
        let feed = PlainShellFeed(opener: opener)
        let events = Events(feed.attach(Self.size(100, 30)))
        let first = await events.next()
        XCTAssertEqual(first, .attached, "Attached as soon as the channel is open: there is no server screen to wait for")
        let shell = try XCTUnwrap(opener.shells.first)
        XCTAssertEqual(shell.term, "xterm-256color")
        XCTAssertEqual(PlainShellFeed.term, "xterm-256color")
        XCTAssertEqual(shell.size, .init(columns: 100, rows: 30))
        let second = await events.next(), third = await events.next()
        XCTAssertEqual(second, .output(Data("Last login: Mon\r\n".utf8)))
        XCTAssertEqual(third, .output(Data("$ ".utf8)))
        shell.emit("ls\r\n")
        let fourth = await events.next()
        XCTAssertEqual(fourth, .output(Data("ls\r\n".utf8)), "Output streams as it arrives")
        shell.end(.status(3))
        let rest = await events.rest()
        XCTAssertEqual(rest, [.exited(3)])
    }

    /// Input and sizes made while the channel opens wait for it and keep their order; later ones follow.
    func testInputAndSizesReachTheShellInOrder() async throws {
        let opener = ScriptedShellOpener()
        let feed = PlainShellFeed(opener: opener)
        let events = Events(feed.attach(Self.size(80, 24)))
        feed.send(Data("echo one".utf8))
        feed.resize(Self.size(120, 40))
        feed.send(Data("\r".utf8))
        let first = await events.next()
        XCTAssertEqual(first, .attached)
        let shell = try XCTUnwrap(opener.shells.first)
        try await TestSupport.eventually { shell.written == Data("echo one\r".utf8) && shell.resizes.count == 1 }
        XCTAssertEqual(shell.resizes, [.init(columns: 120, rows: 40)])
        XCTAssertEqual(shell.size, .init(columns: 80, rows: 24), "Opened at the attach size; the later one is a window-change")
        feed.resize(Self.size(60, 20))
        feed.send(Data())
        try await TestSupport.eventually { shell.resizes.count == 2 }
        XCTAssertEqual(shell.resizes.last, .init(columns: 60, rows: 20))
        XCTAssertEqual(shell.writes.count, 2, "Empty input is not written")
        feed.detach()
    }

    func testALostShellExitsWithoutAStatus() async throws {
        let opener = ScriptedShellOpener()
        let feed = PlainShellFeed(opener: opener)
        let events = Events(feed.attach(Self.size(80, 24)))
        let first = await events.next()
        XCTAssertEqual(first, .attached)
        let shell = try XCTUnwrap(opener.shells.first)
        shell.end(.lost)
        let rest = await events.rest()
        XCTAssertEqual(rest, [.exited(nil)])
        XCTAssertTrue(shell.isClosed, "an ended shell's channel is closed by the feed, not left to its tab")
        XCTAssertEqual(shell.ended, .lost)
    }

    /// Unlike a helper feed's, a plain shell's detach ends it: the channel is closed, the stream finishes without an
    /// exit of its own, and the shell cannot be attached again.
    func testDetachClosesTheShellAndAReattachIsRefused() async throws {
        let opener = ScriptedShellOpener()
        let feed = PlainShellFeed(opener: opener)
        let events = Events(feed.attach(Self.size(80, 24)))
        let first = await events.next()
        XCTAssertEqual(first, .attached)
        let shell = try XCTUnwrap(opener.shells.first)
        feed.detach()
        try await TestSupport.eventually { shell.isClosed }
        let rest = await events.rest()
        XCTAssertEqual(rest, [], "A detach is no exit: nothing more is reported")
        feed.send(Data("late".utf8))
        let again = await Events(feed.attach(Self.size(80, 24))).rest()
        XCTAssertEqual(again, [.failed(PlainShellFeed.endedMessage)])
        XCTAssertEqual(opener.shells.count, 1, "No second shell")
        XCTAssertEqual(shell.writes, [], "Nothing is written after the detach")
    }

    /// A detach while the channel is still opening closes it once it opens.
    func testADetachWhileOpeningClosesTheShellOnceOpen() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let opener = GatedOpener(gate: gate.stream)
        let feed = PlainShellFeed(opener: opener)
        let events = Events(feed.attach(Self.size(80, 24)))
        feed.send(Data("never".utf8))
        feed.detach()
        gate.continuation.finish()
        let rest = await events.rest()
        XCTAssertEqual(rest, [])
        let shell = try XCTUnwrap(opener.scripted.shells.first)
        try await TestSupport.eventually { shell.isClosed }
        XCTAssertEqual(shell.writes, [], "Input made before the detach is dropped, never sent late")
    }

    func testAReattachAfterTheShellExitedIsRefused() async throws {
        let opener = ScriptedShellOpener { term, columns, rows in
            ScriptedShell(term: term, columns: columns, rows: rows, output: [Data("bye\r\n".utf8)], exit: .status(0))
        }
        let feed = PlainShellFeed(opener: opener)
        let events = await Events(feed.attach(Self.size(80, 24))).rest()
        XCTAssertEqual(events, [.attached, .output(Data("bye\r\n".utf8)), .exited(0)])
        let again = await Events(feed.attach(Self.size(80, 24))).rest()
        XCTAssertEqual(again, [.failed(PlainShellFeed.endedMessage)])
        XCTAssertEqual(opener.shells.count, 1)
    }

    func testAFailedOpenFailsTheAttachment() async throws {
        let opener = ScriptedShellOpener()
        opener.fail(Refused())
        let feed = PlainShellFeed(opener: opener)
        let stream = feed.attach(Self.size(80, 24))
        feed.send(Data("x".utf8))
        let events = await Events(stream).rest()
        XCTAssertEqual(events, [.failed("The host refused the shell.")])
        opener.fail(nil)
        let again = await Events(feed.attach(Self.size(80, 24))).rest()
        XCTAssertEqual(again, [.failed(PlainShellFeed.endedMessage)], "One attachment per feed, also after a failure")
        XCTAssertTrue(opener.shells.isEmpty)
    }

    func testScrollIsAppOwnedAndThePresenceHintsFollow() async {
        let feed = PlainShellFeed(opener: ScriptedShellOpener())
        let result = await feed.scroll(TerminalScrollRequest(lines: 3))
        XCTAssertEqual(result, .appOwned)
        XCTAssertEqual(feed.scrollback, .client)
        XCTAssertTrue(feed.clipboardWrite)
        let helperLike = ScriptedTerminalFeed(output: Data())
        XCTAssertEqual(helperLike.scrollback, .unknown, "Other feeds keep asking the topology")
        XCTAssertFalse(helperLike.clipboardWrite, "Other feeds never write the pasteboard")
    }

    /// Opens through a `ScriptedShellOpener` once `gate` finishes.
    private final class GatedOpener: ShellOpener, @unchecked Sendable {
        let scripted = ScriptedShellOpener()
        let gate: AsyncStream<Void>
        init(gate: AsyncStream<Void>) { self.gate = gate }
        func open(term: String, columns: Int, rows: Int) async throws -> any ShellChannel {
            for await _ in gate {}
            return try await scripted.open(term: term, columns: columns, rows: rows)
        }
    }
}
