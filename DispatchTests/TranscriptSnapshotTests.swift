import Foundation
import Observation
import XCTest
import os
@testable import DispatchApp

/// Transcript availability as the app shows it, through archived chats (helper chat.page).
@MainActor
final class TranscriptSnapshotTests: XCTestCase {
    private var chat: ChatCoordinator!
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
    }
    override func tearDown() async throws {
        chat.stop(); chat = nil
        try? FileManager.default.removeItem(at: root)
    }
    /// A conversation whose transcript file is at `path` (which may not exist), opened as the app opens it.
    private func open(_ path: URL, agent: String, session id: String) -> ChatSession {
        let session = chat.session(for: UUID())
        session.agentID = agent; session.sessionID = id; session.transcriptPath = path.path
        chat.start()
        return session
    }

    func testClaudeTitleOutsideInitialPageUsesValidatedHistory() async throws {
        let id = UUID().uuidString
        var rows: [[String: Any]] = [["type": "ai-title", "aiTitle": "Earlier title", "sessionId": id]]
        rows += (0..<500).map { ["type": "user", "uuid": "user-\($0)", "sessionId": id, "message": ["role": "user", "content": "Prompt \($0)"]] }
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let session = try await chat.archived(lines, agent: "claude", session: id, in: root)
        XCTAssertNil(session.status)
        XCTAssertTrue(session.hasEarlier, "The title lies before the first page")
        try await TestSupport.eventually { session.conversationTitle == "Earlier title" }
    }

    func testMissingTranscriptStillReportsReadFailure() async throws {
        let session = open(root.appendingPathComponent("missing.jsonl"), agent: "codex", session: UUID().uuidString)
        try await TestSupport.eventually(diagnostic: "no read failure reported") { session.status != nil && !session.loadingHistory }
    }

    /// App availability fragment; the native snapshot regression owns append-during-read ordering.
    func testOpeningArchiveKeepsLoadedHistoryAvailable() async throws {
        let id = UUID().uuidString, path = root.appendingPathComponent("snapshot-state.jsonl")
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "retained"]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "appended"]]
        ]
        try rows.reduce(into: Data()) { $0 += try JSONSerialization.data(withJSONObject: $1) + Data([10]) }.write(to: path)
        let session = chat.session(for: UUID())
        session.sessionID = id; session.transcriptPath = path.path
        session.insert(ChatItem(id: "retained", kind: .user, text: "retained"), turnID: "history")
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = session.loadingHistory }
            onChange: { changes.withLock { $0 += 1 } }
        chat.start()
        try await TestSupport.eventually { session.turns.flatMap(\.items).contains { $0.text == "appended" } }
        XCTAssertNil(session.status)
        XCTAssertEqual(changes.withLock { $0 }, 0, "Reading must preserve already available history")
        XCTAssertFalse(session.loadingHistory)
    }

    func testEmptyTranscriptIsPendingOnlyBeforeFirstHistory() async throws {
        let id = UUID().uuidString, path = root.appendingPathComponent("empty.jsonl")
        try Data().write(to: path)
        let empty = open(path, agent: "codex", session: id)
        try await TestSupport.eventually { empty.helper != nil }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(empty.status, "Waiting for transcript metadata.")
        XCTAssertTrue(empty.loadingHistory)
        try (try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "cli_version": "0.154.0"]]) + Data([10])).write(to: path)
        let created = open(path, agent: "codex", session: id)
        try await TestSupport.eventually { created.helper != nil && !created.loadingHistory }
        XCTAssertNil(created.status)
        try FileManager.default.removeItem(at: path)
        let removed = open(path, agent: "codex", session: id)
        try await TestSupport.eventually(diagnostic: "a removed transcript must report its failure") { removed.status != nil }
    }
}
