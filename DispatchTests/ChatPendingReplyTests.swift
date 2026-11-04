import XCTest
@testable import DispatchApp

/// Settings › Experimental › Reply placeholder: the empty reply bubble a sent prompt arms (ChatPendingReply).
@MainActor
final class ChatPendingReplyTests: XCTestCase {
    private func sentSession() -> ChatSession {
        let session = ChatSession(id: System.uuid(), draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        session.active = true
        session.turns = [ChatTurn(id: "turn-1", items: [
            .init(id: "user-1", kind: .user, text: "Where is the retry state kept?"),
            .init(id: "answer-1", kind: .assistant, text: "In the retry ledger.", completed: true)])]
        session.awaitingPromptAck = true
        session.showOptimisticPrompt("And the backoff cap?")
        session.busy = true
        return session
    }

    /// The agent acknowledges: its turn starts with the prompt's record.
    private func acknowledge(_ session: ChatSession) {
        session.insert(session.reconcilePrompt(.init(id: "user-2", kind: .user, text: "And the backoff cap?")), turnID: "turn-2")
        session.activeTurnID = "turn-2"
        session.awaitingPromptAck = false
    }

    private func shown(_ session: ChatSession) async throws -> ChatPendingReply {
        session.armPendingReply(delay: 0.05)
        acknowledge(session)
        try await TestSupport.eventually { session.pendingReply != nil }
        return try XCTUnwrap(session.pendingReply)
    }

    func testPlaceholderWaitsForTheDelayAndTheAcknowledgement() async throws {
        let session = sentSession()
        session.armPendingReply(delay: 0.05)
        XCTAssertTrue(session.replyHaloOwnsActivity, "The composer goes neutral from the send")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(session.pendingReply, "Not before the agent acknowledged the prompt")
        acknowledge(session)
        let pending = try XCTUnwrap(session.pendingReply)
        let last = try XCTUnwrap(session.transcriptRows.last)
        XCTAssertEqual(last.id, pending.id)
        XCTAssertTrue(last.placeholder)
        XCTAssertNil(last.item)
        XCTAssertEqual(ChatReplyHalo.target(session, rows: session.transcriptRows),
                       ChatReplyHalo(first: pending.id, last: pending.id, phase: .lapping, orbit: true))
        XCTAssertTrue(session.replyShowsOrbit)
    }

    func testAcknowledgementBeforeTheDelayShowsItAfterTheDelay() async throws {
        let session = sentSession()
        session.armPendingReply(delay: 0.2)
        acknowledge(session)
        XCTAssertNil(session.pendingReply)
        try await TestSupport.eventually { session.pendingReply != nil }
        XCTAssertTrue(session.transcriptRows.last?.placeholder == true)
    }

    func testFirstContentTakesOverThePlaceholdersRowAndSettles() async throws {
        let session = sentSession()
        let pending = try await shown(session)
        session.insert(.init(id: "reply", kind: .assistant, text: "Five"), turnID: "turn-2")
        XCTAssertNil(session.pendingReply)
        let rows = session.transcriptRows
        XCTAssertFalse(rows.contains(where: \.placeholder))
        XCTAssertEqual(rows.last?.id, pending.id, "The reply keeps the placeholder's row: no second entrance")
        XCTAssertEqual(rows.last?.item?.text, "Five")
        let landed = try XCTUnwrap(session.landedReply)
        let halo = try XCTUnwrap(ChatReplyHalo.target(session, rows: rows, now: landed.at + 0.5))
        XCTAssertEqual(halo.phase, .settling(since: landed.at))
        XCTAssertFalse(halo.orbit)
        XCTAssertNil(ChatReplyHalo.target(session, rows: rows, now: landed.at + ChatReplyHalo.settle + 0.1))
        XCTAssertFalse(session.replyShowsOrbit)
        XCTAssertTrue(session.replyHaloOwnsActivity, "The composer stays neutral until the turn ends")
        session.busy = false
        XCTAssertFalse(session.replyHaloOwnsActivity)
        // Later updates of the reply stay on its row.
        session.insert(.init(id: "reply", kind: .assistant, text: "Five minutes.", completed: true), turnID: "turn-2")
        XCTAssertEqual(session.transcriptRows.last?.id, pending.id)
    }

    func testEarlierTurnsContentDoesNotTakeItOver() async throws {
        let session = sentSession()
        let pending = try await shown(session)
        session.insert(.init(id: "answer-1", kind: .assistant, text: "In the retry ledger, saved with the outbox.",
                             completed: true), turnID: "turn-1")
        XCTAssertEqual(session.pendingReply, pending)
        XCTAssertEqual(session.transcriptRows.last?.id, pending.id)
    }

    func testContentBeforeThePlaceholderShowsDisarmsIt() async throws {
        let session = sentSession()
        session.armPendingReply(delay: 0.05)
        acknowledge(session)
        session.insert(.init(id: "reply", kind: .assistant, text: "Five"), turnID: "turn-2")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(session.pendingReply)
        XCTAssertNil(session.landedReply)
        XCTAssertFalse(session.replyHaloOwnsActivity)
    }

    func testTurnEndingWithoutContentRemovesIt() async throws {
        let session = sentSession()
        _ = try await shown(session)
        session.busy = false
        XCTAssertNil(session.pendingReply)
        XCTAssertFalse(session.transcriptRows.contains(where: \.placeholder))
        XCTAssertFalse(session.replyHaloOwnsActivity)
        XCTAssertNil(ChatReplyHalo.target(session, rows: session.transcriptRows))
    }

    func testFailedPromptNeverShowsIt() async throws {
        let session = sentSession()
        session.armPendingReply(delay: 0.05)
        session.failOptimisticPrompt(restoreDraft: true)
        session.awaitingPromptAck = false
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(session.pendingReply)
        XCTAssertFalse(session.replyHaloOwnsActivity)
    }
}
