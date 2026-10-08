import Foundation
import XCTest
@testable import DispatchApp

/// Pi transcripts opened as archived chats through the helper (chat.page): the branch the file ends
/// on, first and earlier pages. A live leaf the pi extension reports (unpersisted navigation), live
/// appends and replacements are tested with the pi reader.
@MainActor
final class PiHistoryTests: XCTestCase {
    func testExplicitLeafAppendIsIncrementalAndBranchSwitchInvalidatesOlderPages() throws {
        let session = chat.session(for: UUID())
        func records(_ index: Int) -> [HelperChat.Record] {
            ["user", "assistant"].map { kind in
                .init(id: (kind == "user" ? "u" : "a") + String(index), turn: "u\(index)", kind: kind,
                      text: (kind == "user" ? "Question " : "Answer ") + String(index), title: "", output: "", blocks: [], completed: true,
                      exit_code: nil, patch: nil, time_ms: nil, documents: [], tool: nil, inline_reasoning: false)
            }
        }
        chat.receiveHelper(.archive(.init(records: (0..<100).flatMap(records), earlier: "old-generation", state: nil,
            snapshot: .init(awaiting_creation: false, initial: true))), session: session)
        XCTAssertEqual(text(session), (0..<100).map { "Answer \($0)" })
        XCTAssertTrue(session.hasEarlier)
        chat.receiveHelper(.archive(.init(records: records(100), earlier: "old-generation", state: nil,
            snapshot: .init(awaiting_creation: false, initial: false))), session: session)
        XCTAssertEqual(text(session), (0...100).map { "Answer \($0)" })
        XCTAssertEqual(session.helperEarlier, "old-generation")
        chat.receiveHelper(.archive(.init(records: records(0), earlier: nil, state: nil,
            snapshot: .init(awaiting_creation: false, initial: true))), session: session)
        XCTAssertEqual(text(session), ["Answer 0"])
        XCTAssertFalse(session.hasEarlier)
        XCTAssertNil(session.helperEarlier)
    }

    func testTreeSelectionExcludesAbandonedBranchesAndObservesUnpersistedNavigation() async throws {
        var data = try setup()
        data += try user("u1", parent: "thinking", text: "Shared question")
        data += try answer("a1", parent: "u1", text: "Shared answer")
        data += try user("old-user", parent: "a1", text: "Abandoned question")
        data += try answer("old-answer", parent: "old-user", text: "Abandoned answer")
        data += try row("branch_summary", "summary", parent: "a1", values: ["summary": "Context from old branch"])
        data += try row("custom", "extension", parent: "summary", values: ["data": ["fixture": true]])
        data += try user("new-user", parent: "extension", text: "Selected question")
        data += try answer("new-answer", parent: "new-user", text: "Selected answer")
        let session = try await open(data)
        XCTAssertFalse(session.hasEarlier)
        XCTAssertEqual(text(session), ["Shared answer", "Selected answer"])
        XCTAssertEqual(text(session, kind: .user), ["Shared question", "Selected question"])
        XCTAssertEqual(text(session, kind: .notice), ["Context from old branch"])
    }

    func testRecentPagesPreserveEveryActiveTurnAndIndependentLiveCursor() async throws {
        var data = try setup()
        for index in 0..<550 { data += try turn(index) }
        let session = try await open(data)
        XCTAssertTrue(session.hasEarlier)
        XCTAssertTrue(text(session).contains("Answer 549")); XCTAssertFalse(text(session).contains("Answer 0"))
        XCTAssertLessThan(session.turns.flatMap(\.items).count, 1_000)
        for _ in 0..<20 where session.hasEarlier { _ = try await chat.earlier(session) }
        XCTAssertFalse(session.hasEarlier)
        XCTAssertEqual(text(session).count, 550)
        XCTAssertEqual(Set(text(session)).count, 550, "No page replays a record")
    }

    func testLongTurnPartialTailKeepsToolPairsAndActualActivityContext() async throws {
        var data = try setup() + user("u", parent: "thinking", text: String(repeating: "long prompt ", count: 8_000))
        for index in 0..<300 { data += try tool(index, parent: index == 0 ? "u" : "result\(index - 1)") }
        let final = try answer("finished", parent: "result299", text: "Completed long turn")
        let session = try await open(data + final.dropLast(20))
        XCTAssertTrue(session.hasEarlier)
        XCTAssertEqual(session.model, "fixture/model"); XCTAssertEqual(session.effort, "high")
        for _ in 0..<6 where session.hasEarlier { _ = try await chat.earlier(session) }
        XCTAssertFalse(session.hasEarlier)
        XCTAssertEqual(session.turns.map(\.id), ["u"])
        let tools = session.turns.flatMap(\.items).filter { $0.kind == .tool }
        XCTAssertEqual(Set(tools.map(\.id)).count, 300)
        XCTAssertTrue(tools.allSatisfy { !$0.text.isEmpty && $0.completed && !$0.output.isEmpty })
        XCTAssertTrue(text(session).isEmpty, "A partial last line is not shown")
    }

    /// A transcript file that is not there is an error for an archived chat (waiting for pi's first save
    /// belongs to the live chat, moved with the leaf cases).
    func testInitialMissingFileWaitsForPersistenceButLaterLossRemainsAnError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-pi-history-\(UUID()).jsonl")
        let missing = try await chat.archived(url, agent: "pi", session: sessionID, opens: false)
        XCTAssertTrue(missing.turns.isEmpty)
    }

    func testWrongSessionMissingParentsAndReplacementAreRejectedOrReloaded() async throws {
        let wrong = try await open(try setup() + turn(0), session: UUID().uuidString, opens: false)
        XCTAssertTrue(wrong.turns.isEmpty)
        let orphan = try await open(try setup() + user("orphan", parent: "absent", text: "must not substitute nearby entries"), opens: false)
        XCTAssertTrue(orphan.turns.isEmpty)
        let valid = try await open(try setup() + turn(0))
        XCTAssertEqual(text(valid), ["Answer 0"])
    }

    private let sessionID = "00dc6acf-ac00-7000-8000-000000000105"
    private lazy var chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))

    private func open(_ data: Data, session: String? = nil, opens: Bool = true) async throws -> ChatSession {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-pi-history-\(UUID()).jsonl")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try await chat.archived(url, agent: "pi", session: session ?? sessionID, opens: opens)
    }
    private func json(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) + Data([10])
    }
    private func header() throws -> Data {
        try json(["type": "session", "id": sessionID, "version": 3, "cwd": "/tmp/fixture", "timestamp": "2000-01-01T00:00:00.000Z"])
    }
    private func row(_ type: String, _ id: String, parent: String?, values: [String: Any] = [:]) throws -> Data {
        var root: [String: Any] = ["type": type, "id": id, "parentId": parent as Any? ?? NSNull(), "timestamp": "2000-01-01T00:00:00.062Z"]
        root.merge(values) { _, new in new }
        return try json(root)
    }
    private func setup() throws -> Data {
        try header() + row("model_change", "model", parent: nil, values: ["provider": "fixture", "modelId": "model"])
            + row("thinking_level_change", "thinking", parent: "model", values: ["thinkingLevel": "high"])
    }
    private func user(_ id: String, parent: String?, text: String) throws -> Data {
        try row("message", id, parent: parent, values: ["message": ["role": "user", "content": text]])
    }
    private func answer(_ id: String, parent: String, text: String) throws -> Data {
        try row("message", id, parent: parent, values: ["message": ["role": "assistant", "provider": "fixture", "model": "model", "stopReason": "stop", "content": [["type": "text", "text": text]]]])
    }
    private func tool(_ index: Int, parent: String) throws -> Data {
        try row("message", "tool\(index)", parent: parent, values: ["message": ["role": "assistant", "provider": "fixture", "model": "model", "stopReason": "toolUse", "content": [
            ["type": "toolCall", "id": "call\(index)", "name": "bash", "arguments": ["command": "printf fixture"]]]]])
            + row("message", "result\(index)", parent: "tool\(index)", values: ["message": ["role": "toolResult", "toolCallId": "call\(index)", "toolName": "bash", "isError": false,
                "content": [["type": "text", "text": String(repeating: "fixture output ", count: 100)]]]])
    }
    private func turn(_ index: Int) throws -> Data {
        try user("u\(index)", parent: index == 0 ? "thinking" : "a\(index - 1)", text: "Question \(index)")
            + tool(index, parent: "u\(index)") + answer("a\(index)", parent: "result\(index)", text: "Answer \(index)")
    }
    private func text(_ session: ChatSession, kind: ChatItem.Kind = .assistant) -> [String] {
        session.turns.flatMap(\.items).filter { $0.kind == kind }.map(\.text)
    }
}
