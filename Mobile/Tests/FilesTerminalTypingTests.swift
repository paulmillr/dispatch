import Foundation
import XCTest
@testable import DispatchMobile

/// Open in Terminal (docs/ios.md, Files; `FilesTerminalTyping`): nothing is typed before the pane's screen is the
/// server's as it is now, never into a full-screen program, bracketed as the shell asks at that moment, and the result is
/// the helper's answer, never assumed.
@MainActor
final class FilesTerminalTypingTests: XCTestCase {
    private static let features: Set<String> = [HelperSession.screensHost, HelperSession.terminalsFollow]

    /// What the closure sends, or the error it throws instead.
    private final class Sent {
        var bytes: [Data] = []
        var failure: (any Error)?
        var during: (@MainActor () async -> Void)?
    }

    private struct Fixture {
        let peer: ScriptedHelper
        let presences: TerminalPresences
        let key: TerminalPresences.Key
        let presence: TerminalPresence
        let attach: ScriptedHelper.Request

        func output(_ text: String) { peer.notify(attach.id, .output(.init(terminal: 7, bytes: Data(text.utf8))), method: "terminal.output") }
        func attached() { peer.notify(attach.id, .attached, method: "terminal.attached") }
    }

    /// The pane's presence attached as Open in Terminal attaches it (a use that shows it), its attach left to the test.
    private func fixture(features: Set<String> = features) async throws -> Fixture {
        let peer = ScriptedHelper.terminal(attached: false)
        let presences = TerminalPresences()
        let key = TerminalPresences.Key(host: UUID(), node: "tmux:fixture:7")
        let presence = presences.open(key, feed: HelperTerminalFeed(client: peer.client, terminal: 7, features: features),
                                      terminal: 7, client: peer.client, scrollback: .client)
        presences.retain(key, showing: true)
        let attach = try await peer.wait(for: "terminals.attach")[0]
        addTeardownBlock { @MainActor in
            presences.close(key)
            peer.close()
        }
        return Fixture(peer: peer, presences: presences, key: key, presence: presence, attach: attach)
    }

    private func type(_ presence: TerminalPresence, _ sent: Sent, ready: Bool = true,
                      timeout: Duration = .seconds(5)) async -> String? {
        await FilesTerminalTyping.type("/Users/sam/src/web", into: presence, ready: { ready }, send: { bytes in
            if let during = sent.during { await during() }
            if let failure = sent.failure { throw failure }
            sent.bytes.append(bytes)
        }, timeout: timeout)
    }

    /// A shell's screen, then the attach complete: the cd goes, plain, once.
    func testTypesOnceTheScreenIsTheServers() async throws {
        let f = try await fixture()
        f.output("$ ")
        f.attached()
        let sent = Sent()
        let result = await type(f.presence, sent)
        XCTAssertNil(result)
        XCTAssertEqual(sent.bytes, [FilesAsk.typing("/Users/sam/src/web", bracketed: false)!])
    }

    /// A presence whose attach never completes (no screen from the server, as for a pane never shown): nothing is typed.
    func testNoScreenFromTheServerTypesNothing() async throws {
        let f = try await fixture()
        f.output("$ ")
        let sent = Sent()
        let result = await type(f.presence, sent, timeout: .milliseconds(300))
        XCTAssertEqual(result, FilesTerminalTyping.stale)
        XCTAssertTrue(sent.bytes.isEmpty)
        XCTAssertFalse(f.presence.current)
    }

    /// A presence last seen at a prompt, detached since: its old screen says nothing. Attached again, the server's
    /// screen shows vim on the alternate screen, and the cd is refused.
    func testAStalePresenceIsReadAgainBeforeTyping() async throws {
        let f = try await fixture()
        f.output("$ ")
        f.attached()
        try await TestSupport.eventually { f.presence.current }
        f.presences.release(f.key, showing: true)
        XCTAssertFalse(f.presence.attached)
        XCTAssertFalse(f.presence.current, "Detached: an old screen")
        XCTAssertFalse(f.presence.filesTypingState.alternate, "What the old screen claims")
        f.presences.retain(f.key, showing: true)
        let again = try await f.peer.wait(for: "terminals.attach", count: 2)[1]
        f.peer.notify(again.id, .output(.init(terminal: 7, bytes: Data("\u{1B}[?1049h~ vim".utf8))), method: "terminal.output")
        f.peer.notify(again.id, .attached, method: "terminal.attached")
        let sent = Sent()
        let result = await type(f.presence, sent)
        XCTAssertEqual(result, FilesTerminalTyping.busy, "The server's screen is vim's")
        XCTAssertTrue(sent.bytes.isEmpty)
    }

    /// A full-screen program up, or the pane's program no longer a shell when the screen came: refused.
    func testAFullScreenProgramOrAnotherProgramRefuses() async throws {
        let f = try await fixture()
        f.output("\u{1B}[?1049h")
        f.attached()
        let sent = Sent()
        let alternate = await type(f.presence, sent)
        XCTAssertEqual(alternate, FilesTerminalTyping.busy)
        f.output("\u{1B}[?1049l$ ")
        try await TestSupport.eventually { f.presence.current && !f.presence.filesTypingState.alternate }
        let other = await type(f.presence, sent, ready: false)
        XCTAssertEqual(other, FilesTerminalTyping.busy)
        XCTAssertTrue(sent.bytes.isEmpty)
    }

    /// The shell asked for bracketed paste: the cd is one.
    func testBracketedPasteAsTheShellAsks() async throws {
        let f = try await fixture()
        f.output("\u{1B}[?2004h$ ")
        f.attached()
        let sent = Sent()
        let result = await type(f.presence, sent)
        XCTAssertNil(result)
        XCTAssertEqual(sent.bytes, [FilesAsk.typing("/Users/sam/src/web", bracketed: true)!])
    }

    /// The helper refuses the input: the failure is the answer, and it is not sent again; an answer that leaves the
    /// outcome open (uncertain, the link lost) says the cd may have arrived.
    func testASendFailureIsSurfacedAndNotRetried() async throws {
        let f = try await fixture()
        f.output("$ ")
        f.attached()
        let sent = Sent()
        sent.failure = HelperFailure(code: "io", message: "The pane is gone")
        let result = await type(f.presence, sent)
        XCTAssertEqual(result, FilesTerminalTyping.failed("The pane is gone"))
        XCTAssertTrue(sent.bytes.isEmpty)

        // The real client: terminals.input answered with an error.
        f.peer.script { request in
            request.method == "terminals.input" ? .error(code: "uncertain", message: "Input did not finish") : .open
        }
        let client = f.peer.client
        let real = await FilesTerminalTyping.type("/w", into: f.presence, ready: { true }) { bytes in
            try await client.input(HelperClient.Output(terminal: 7, bytes: bytes))
        }
        XCTAssertEqual(real, FilesTerminalTyping.uncertain("Input did not finish"))
        XCTAssertEqual(f.peer.requests("terminals.input").count, 1, "Never retried")
        XCTAssertEqual(FilesTerminalTyping.outcome(HelperFailure(code: "permission_denied", message: "")),
                       FilesTerminalTyping.failed("permission_denied"))
        XCTAssertEqual(FilesTerminalTyping.outcome(HelperFailure(code: "connection_closed", message: "Closed")),
                       FilesTerminalTyping.uncertain("Closed"))
        XCTAssertEqual(FilesTerminalTyping.outcome(CancellationError()), FilesTerminalTyping.uncertain("stopped"))
        XCTAssertTrue(FilesTerminalTyping.outcome(HelperWire.Failure.truncated).hasPrefix("The cd may not have reached"))
    }

    /// The mode changing while the request is in flight: held output resumed (the repaint, not the old screen, decides:
    /// the shell turned bracketed paste on meanwhile); a full-screen program whose switch reached the phone before the
    /// helper's answer is reported, one whose switch comes after it is not (the phone cannot see it: only the helper
    /// could close that window).
    func testAModeChangingInFlight() async throws {
        let peer = ScriptedHelper.terminal(attached: false)
        let presences = TerminalPresences()
        let chat = TerminalChatPresence(presences: presences)
        let conversation = ChatConversationKey(host: UUID(), node: "tmux:fixture:7")
        let key = TerminalPresences.Key(host: conversation.host, node: conversation.node)
        defer {
            presences.close(key)
            peer.close()
        }
        let presence = presences.open(key, feed: HelperTerminalFeed(client: peer.client, terminal: 7, features: Self.features),
                                      terminal: 7, client: peer.client, scrollback: .client)
        presence.followGrace = .milliseconds(100)
        chat.retain(conversation, terminal: 7, client: peer.client, features: Self.features)
        let attach = try await peer.wait(for: "terminals.attach")[0]
        peer.notify(attach.id, .output(.init(terminal: 7, bytes: Data("$ ".utf8))), method: "terminal.output")
        peer.notify(attach.id, .attached, method: "terminal.attached")
        try await TestSupport.eventually { presence.holding }
        XCTAssertFalse(presence.current, "Held: its screen stops")

        presences.retain(key, showing: true)
        _ = try await peer.wait(for: "terminals.follow", count: 2)
        XCTAssertFalse(presence.current, "Until the repaint")
        let sent = Sent()
        let typing = Task { await type(presence, sent) }
        await Task.yield()
        XCTAssertTrue(sent.bytes.isEmpty, "Nothing typed before the repaint")
        peer.notify(attach.id, .output(.init(terminal: 7, bytes: Data("\u{1B}c\u{1B}[?2004h$ ".utf8))), method: "terminal.output")
        let result = await typing.value
        XCTAssertNil(result)
        XCTAssertEqual(sent.bytes, [FilesAsk.typing("/Users/sam/src/web", bracketed: true)!])

        let late = Sent()
        late.during = {
            peer.notify(attach.id, .output(.init(terminal: 7, bytes: Data("\u{1B}[?1049h".utf8))), method: "terminal.output")
            try? await TestSupport.eventually { presence.filesTypingState.alternate }
        }
        let changed = await type(presence, late)
        XCTAssertEqual(changed, FilesTerminalTyping.changed, "The switch was on the phone before the answer")

        peer.notify(attach.id, .output(.init(terminal: 7, bytes: Data("\u{1B}[?1049l$ ".utf8))), method: "terminal.output")
        try await TestSupport.eventually { presence.current && !presence.filesTypingState.alternate }
        let unseen = await type(presence, Sent())
        XCTAssertNil(unseen, "A switch after the answer is not seen")
        peer.notify(attach.id, .output(.init(terminal: 7, bytes: Data("\u{1B}[?1049h".utf8))), method: "terminal.output")
        try await TestSupport.eventually { presence.filesTypingState.alternate }
        presences.release(key, showing: true)
        chat.release(conversation)
    }

    /// The result waits for the send: a send still going has no answer yet (the tab is shown only after it).
    func testTheAnswerWaitsForTheSend() async throws {
        let f = try await fixture()
        f.output("$ ")
        f.attached()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let sent = Sent()
        var sending = false
        sent.during = {
            sending = true
            for await _ in gate {}
        }
        var answered = false
        let typing = Task { () -> String? in
            let result = await type(f.presence, sent)
            answered = true
            return result
        }
        try await TestSupport.eventually { sending }
        XCTAssertFalse(answered, "Not before the helper answered")
        open.finish()
        let result = await typing.value
        XCTAssertNil(result)
        XCTAssertTrue(answered)
    }

    // MARK: Review fixes

    /// herdr sends its own rendering (`\e[?1049h\e[?7l` first, on every attach and repaint), so the emulator's modes
    /// are herdr's, not the program's: nothing is typed, and the composition does not offer it for herdr hosts.
    func testHerdrPanesAreNeverTypedInto() async throws {
        let peer = ScriptedHelper.terminal(attached: false)
        let presences = TerminalPresences()
        let key = TerminalPresences.Key(host: UUID(), node: "term_fixture_7")
        defer {
            presences.close(key)
            peer.close()
        }
        let presence = presences.open(key, feed: HelperTerminalFeed(client: peer.client, terminal: 7, features: Self.features),
                                      terminal: 7, client: peer.client, scrollback: .server)
        presences.retain(key, showing: true)
        let attach = try await peer.wait(for: "terminals.attach")[0]
        peer.notify(attach.id, .output(.init(terminal: 7, bytes: Data("\u{1B}[?1049h\u{1B}[?7l$ ".utf8))), method: "terminal.output")
        peer.notify(attach.id, .attached, method: "terminal.attached")
        try await TestSupport.eventually { presence.current }
        XCTAssertTrue(presence.filesTypingState.alternate, "herdr's rendering, whatever runs in the pane")
        let sent = Sent()
        let result = await type(presence, sent)
        XCTAssertEqual(result, FilesTerminalTyping.unknownModes)
        XCTAssertTrue(sent.bytes.isEmpty)
        XCTAssertEqual(TerminalScrollback(multiplexer: "herdr"), .server)
        XCTAssertEqual(TerminalScrollback(multiplexer: "tmux"), .client, "tmux's restore carries the pane's own modes")
    }

    /// The caller cancelled (the preview left) while the screen was awaited: nothing is typed.
    func testCancelledWhileWaitingTypesNothing() async throws {
        let f = try await fixture()
        let sent = Sent()
        let typing = Task { await type(f.presence, sent) }
        await Task.yield()
        typing.cancel()
        f.output("$ ")
        f.attached()
        let result = await typing.value
        XCTAssertEqual(result, FilesTerminalTyping.stopped)
        XCTAssertTrue(sent.bytes.isEmpty)
    }

    /// The whole operation is bounded: a helper that never answers the input leaves its outcome unknown, said so.
    func testASendWithoutAnAnswerIsBounded() async throws {
        let f = try await fixture()
        f.output("$ ")
        f.attached()
        f.peer.script { request in request.method == "terminals.input" ? .open : .empty }
        let client = f.peer.client
        let started = ContinuousClock.now
        let result = await FilesTerminalTyping.type("/w", into: f.presence, ready: { true }, send: { bytes in
            try await client.input(HelperClient.Output(terminal: 7, bytes: bytes))
        }, limit: .milliseconds(400))
        XCTAssertEqual(result, FilesTerminalTyping.uncertain("no answer in time"))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertEqual(f.peer.requests("terminals.input").count, 1)
    }

    /// An attachment that ended (here: the helper refused the attach) says why, at once, instead of waiting.
    func testAnEndedAttachmentSaysWhy() async throws {
        let peer = ScriptedHelper { request in
            request.method == "terminals.attach" ? .error(code: "expired", message: "The pane is gone") : .empty
        }
        let presences = TerminalPresences()
        let key = TerminalPresences.Key(host: UUID(), node: "tmux:fixture:7")
        defer {
            presences.close(key)
            peer.close()
        }
        let presence = presences.open(key, feed: HelperTerminalFeed(client: peer.client, terminal: 7), terminal: 7,
                                      client: peer.client, scrollback: .client)
        presences.retain(key, showing: true)
        try await TestSupport.eventually { presence.ended != nil }
        let sent = Sent()
        let result = await type(presence, sent)
        guard case .failed? = presence.ended else { return XCTFail("\(String(describing: presence.ended))") }
        XCTAssertEqual(result, FilesTerminalTyping.ended(presence.ended!))
        XCTAssertTrue(result?.hasPrefix("The terminal is not attached") == true, result ?? "")
        XCTAssertTrue(sent.bytes.isEmpty)
    }

    /// The hold's marker is the helper's answer to it: output that was on its way before the hold took effect (sent
    /// after the request, before the answer) is not the repaint, and neither is anything before the repaint itself.
    func testOutputInTransitBeforeAHoldIsNotTheRepaint() async throws {
        let peer = ScriptedHelper.terminal(open: ["terminals.attach", "terminals.follow"], attached: false)
        let presences = TerminalPresences()
        let chat = TerminalChatPresence(presences: presences)
        let conversation = ChatConversationKey(host: UUID(), node: "tmux:fixture:7")
        let key = TerminalPresences.Key(host: conversation.host, node: conversation.node)
        defer {
            presences.close(key)
            peer.close()
        }
        let presence = presences.open(key, feed: HelperTerminalFeed(client: peer.client, terminal: 7, features: Self.features),
                                      terminal: 7, client: peer.client, scrollback: .client)
        presence.followGrace = .milliseconds(100)
        chat.retain(conversation, terminal: 7, client: peer.client, features: Self.features)
        let attach = try await peer.wait(for: "terminals.attach")[0]
        func output(_ text: String) {
            peer.notify(attach.id, .output(.init(terminal: 7, bytes: Data(text.utf8))), method: "terminal.output")
        }
        output("$ ")
        peer.notify(attach.id, .attached, method: "terminal.attached")
        let hold = try await peer.wait(for: "terminals.follow")[0]
        XCTAssertTrue(presence.holding)

        // Shown before the helper answered the hold: following again, but nothing current yet.
        presences.retain(key, showing: true)
        XCTAssertFalse(presence.holding)
        output("\u{1B}[?1049hvim, sent before the hold took effect")
        try await TestSupport.eventually { presence.session.isAlternate }
        XCTAssertFalse(presence.current, "The hold is not answered: what came may be from before it")
        peer.reply(hold.id, .empty)
        // The resume goes out only after the hold's answer was taken in (one call after another).
        let resume = try await peer.wait(for: "terminals.follow", count: 2)[1]
        XCTAssertFalse(presence.current, "Answered: everything so far is from before the hold, no repaint yet")
        peer.reply(resume.id, .empty)
        output("\u{1B}c\u{1B}[?1049l$ ")
        try await TestSupport.eventually { presence.current }
        XCTAssertFalse(presence.filesTypingState.alternate, "The repaint's screen: the shell")
        presences.release(key, showing: true)
        chat.release(conversation)
    }
}
