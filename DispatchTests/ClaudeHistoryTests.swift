import Foundation
import XCTest
@testable import DispatchApp

/// Claude transcripts opened as archived chats through the helper (chat.page): what the chat shows on
/// the first page and as earlier pages load. Live appends to the file are the claude reader's own tests.
@MainActor
final class ClaudeHistoryTests: XCTestCase {
    func testOutOfOrderResponseSurvivesInitialPageBoundaryAndLiveAppend() async throws {
        let response = try row("assistant", "early", ["role": "assistant", "content": [["type": "text", "text": "early reply"]]],
                               extra: ["parentUuid": "attachment-49"])
        var data = response + (try question(1))
        for index in 0..<50 {
            data += try row("attachment", "attachment-\(index)", extra:
                ["parentUuid": index == 0 ? "u1" : "attachment-\(index - 1)"])
        }
        let session = try await open(data)
        XCTAssertFalse(session.hasEarlier)
        XCTAssertEqual(answers(session), ["early reply"])
        XCTAssertEqual(session.turns.filter { $0.items.contains { $0.kind == .assistant } }.map(\.id), ["p1"])
    }

    func testEarlierResponseUsesParentFromNewerPageWithoutChangingLiveCursor() async throws {
        var data = try question(0) + row("assistant", "early", ["role": "assistant",
            "content": [["type": "text", "text": "reply before page boundary"]]], extra: ["parentUuid": "u1"])
        data += try row("attachment", "padding-0") + row("attachment", "padding-1") + question(1)
        for index in 0..<399 { data += try row("attachment", "tail-\(index)", extra: ["parentUuid": "u1"]) }
        let session = try await open(data)
        XCTAssertTrue(session.hasEarlier)
        XCTAssertTrue(answers(session).isEmpty)
        _ = try await chat.earlier(session)
        XCTAssertFalse(session.hasEarlier)
        XCTAssertEqual(answers(session), ["reply before page boundary"])
        XCTAssertEqual(session.turns.filter { $0.items.contains { $0.kind == .assistant } }.map(\.id), ["p1"])
    }

    func testRecentClaudeHistoryKeepsEveryOlderTurnAndIndependentLiveCursor() async throws {
        var data = Data("{\"type\":\"file-history-snapshot\",\"snapshot\":{}}\n".utf8)
        for index in 0..<1_000 { data += try turn(index) }
        let session = try await open(data)
        XCTAssertTrue(session.hasEarlier)
        XCTAssertTrue(answers(session).contains("Answer 999"))
        XCTAssertFalse(answers(session).contains("Answer 0"))
        XCTAssertEqual(answers(session).count, 100, "The first page holds the 100 most recent complete turns")
        var pages = 0
        for _ in 0..<30 where session.hasEarlier {
            let before = answers(session).count
            _ = try await chat.earlier(session)
            if pages == 0 { XCTAssertEqual(answers(session).count - before, 50, "An earlier page holds 50 turns") }
            pages += 1
        }
        XCTAssertFalse(session.hasEarlier)
        XCTAssertEqual(answers(session).count, 1_000)
        XCTAssertEqual(Set(answers(session)).count, 1_000, "No page replays a record")
        XCTAssertEqual(answers(session).first, "Answer 0")
    }

    func testLongTurnPartialTailAndContextLookup() async throws {
        // A large first user record must not be mistaken for a metadata header.
        var data = try question(1, text: String(repeating: "long prompt ", count: 8_000))
        for index in 0..<300 { data += try tool(index, prompt: 1) }
        let final = try answer(1)
        let session = try await open(data + final.dropLast(20))
        XCTAssertTrue(session.hasEarlier)
        XCTAssertEqual(session.model, "fixture"); XCTAssertEqual(session.effort, "high")
        for _ in 0..<5 where session.hasEarlier { _ = try await chat.earlier(session) }
        XCTAssertFalse(session.hasEarlier)
        XCTAssertEqual(session.turns.map(\.id), ["p1"])
        let tools = session.turns.flatMap(\.items).filter { $0.kind == .tool }
        XCTAssertEqual(Set(tools.map(\.id)).count, 300)
        XCTAssertTrue(tools.allSatisfy { !$0.text.isEmpty && $0.completed && !$0.output.isEmpty })
        XCTAssertTrue(answers(session).isEmpty, "A partial last line is not shown")
    }

    func testWrongSessionPageIsRejectedAndEmptyFileCanStartLater() async throws {
        let empty = try await open(Data(), opens: false)
        XCTAssertTrue(empty.turns.isEmpty)
        let started = try await open(try turn(0))
        XCTAssertEqual(answers(started), ["Answer 0"])
        let foreign = try row("user", "foreign", ["role": "user", "content": "wrong"], extra: ["sessionId": UUID().uuidString])
        let rejected = try await open(try turn(0) + foreign, opens: false)
        XCTAssertTrue(rejected.turns.isEmpty)
    }

    func testForeignHistoryAndReplacedFileInvalidatePendingOlderPages() async throws {
        var data = try row("user", "foreign", ["role": "user", "content": "wrong"], extra: ["sessionId": UUID().uuidString])
        for index in 0..<100 { data += try turn(index) }
        let session = try await open(data)
        XCTAssertTrue(session.hasEarlier)
        let shown = answers(session)
        for _ in 0..<3 where session.hasEarlier && session.earlierError == nil {
            XCTAssertTrue(chat.loadEarlier(session))
            try await TestSupport.eventually(timeout: .seconds(10)) { !session.loadingEarlier }
        }
        XCTAssertNotNil(session.earlierError, "An earlier page holding another conversation is refused")
        XCTAssertFalse(session.turns.flatMap(\.items).contains { $0.text == "wrong" })
        XCTAssertTrue(Set(shown).isSubset(of: Set(answers(session))))
    }

    private let sessionID = "00000000-0000-4000-8000-000000000101"
    private lazy var chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))

    private func open(_ data: Data, opens: Bool = true) async throws -> ChatSession {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-claude-history-\(UUID()).jsonl")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try await chat.archived(url, agent: "claude", session: sessionID, opens: opens)
    }
    private func row(_ type: String, _ id: String, _ message: [String: Any] = [:], extra: [String: Any] = [:]) throws -> Data {
        var root: [String: Any] = ["type": type, "uuid": id, "message": message, "sessionId": sessionID,
                                   "version": "2.1.260", "timestamp": "2000-01-01T10:00:00.123Z"]
        root.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) + Data([10])
    }
    private func question(_ index: Int, text: String? = nil) throws -> Data {
        try row("user", "u\(index)", ["role": "user", "content": text ?? "Question \(index)"], extra: ["promptId": "p\(index)"])
    }
    private func tool(_ index: Int, prompt: Int) throws -> Data {
        try row("assistant", "a\(index)", ["role": "assistant", "model": "fixture", "stop_reason": "tool_use", "content": [
            ["type": "tool_use", "id": "call\(index)", "name": "Bash", "input": ["command": "printf fixture"]]]], extra: ["effort": "high"])
        + row("user", "r\(index)", ["role": "user", "content": [["type": "tool_result", "tool_use_id": "call\(index)",
            "content": String(repeating: "fixture output ", count: 100), "is_error": false]]], extra: ["promptId": "p\(prompt)"])
    }
    private func answer(_ index: Int) throws -> Data {
        try row("assistant", "f\(index)", ["role": "assistant", "model": "fixture", "stop_reason": "end_turn",
            "content": [["type": "text", "text": "Answer \(index)"]]], extra: ["effort": "high"])
    }
    private func turn(_ index: Int) throws -> Data { try question(index) + tool(index, prompt: index) + answer(index) }
    private func answers(_ session: ChatSession) -> [String] {
        session.turns.flatMap(\.items).filter { $0.kind == .assistant }.map(\.text)
    }
}
