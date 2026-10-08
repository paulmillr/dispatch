import Foundation
import XCTest
@testable import DispatchApp

/// Pi transcripts as the app shows them: each case writes session lines and opens them as an archived
/// conversation through the helper (chat.page reads the file).
@MainActor
final class PiTranscriptTests: XCTestCase {
    private func record(_ id: String, _ kind: String, _ text: String, completed: Bool = false, output: String = "") -> HelperChat.Record {
        .init(id: id, turn: "u", kind: kind, text: text, title: kind == "tool" ? "bash" : "", output: output,
              blocks: [], completed: completed, exit_code: nil, patch: nil, time_ms: nil, documents: [], tool: nil, inline_reasoning: false)
    }

    func testLiveSnapshotsSharePersistedBlockIDsWithoutChangingActivityOrConfiguration() throws {
        let session = chat.session(for: UUID())
        session.model = "fixture/model"; session.effort = "high"; session.busy = true
        let partial = record("live/text", "assistant", "par")
        let final = record("live/text", "assistant", "partial reply", completed: true)
        chat.receiveHelper(.records([partial]), session: session)
        XCTAssertEqual(session.turns.flatMap(\.items).map(\.id), [partial.id])
        XCTAssertFalse(try XCTUnwrap(session.turns.first?.items.first).completed)
        chat.receiveHelper(.records([final]), session: session)
        XCTAssertEqual(session.turns.flatMap(\.items).map(\.id), [partial.id])
        XCTAssertTrue(try XCTUnwrap(session.turns.first?.items.first).completed)
        XCTAssertEqual(session.model, "fixture/model"); XCTAssertEqual(session.effort, "high")
        XCTAssertTrue(session.busy)
    }

    func testCompletedTextAndThinkingSurviveAnOlderLiveSnapshot() throws {
        let session = chat.session(for: UUID())
        chat.receiveHelper(.records([record("thinking", "reasoning", "Synthetic"), record("text", "assistant", "Tool")]), session: session)
        chat.receiveHelper(.records([record("thinking", "reasoning", "Synthetic fixture trace"), record("text", "assistant", "Tool result received:")]), session: session)
        XCTAssertEqual(session.turns[0].items.map(\.text), ["Synthetic fixture trace", "Tool result received:"])
        let old = [record("thinking", "reasoning", "Synthetic fixture trace is"), record("text", "assistant", "Tool result received: comp")]
        let done = [record("thinking", "reasoning", "Synthetic fixture trace is complete.", completed: true), record("text", "assistant", "Tool result received: completed.", completed: true)]
        chat.receiveHelper(.records(done), session: session)
        let completed = session.turns[0].items
        XCTAssertTrue(completed.allSatisfy(\.completed))
        chat.receiveHelper(.records(old), session: session)
        XCTAssertEqual(session.turns[0].items, completed)
        chat.receiveHelper(.records([record("text", "assistant", "Corrected completed reply.", completed: true)]), session: session)
        XCTAssertEqual(session.turns[0].items.last?.text, "Corrected completed reply.")
    }

    func testCompletedToolsRejectStaleLiveArgumentsAndAcceptLatePersistedCalls() throws {
        let session = chat.session(for: UUID())
        chat.receiveHelper(.records([record("call", "tool", "printf f")]), session: session)
        let stale = record("call", "tool", "printf fi")
        let done = record("call", "tool", "printf fixture", completed: true, output: "fixture")
        chat.receiveHelper(.records([done]), session: session)
        let completed = session.turns[0].items
        XCTAssertEqual(completed.map(\.text), ["printf fixture"])
        XCTAssertEqual(completed.map(\.output), ["fixture"])
        XCTAssertTrue(completed.allSatisfy(\.completed))
        chat.receiveHelper(.records([stale]), session: session)
        XCTAssertEqual(session.turns[0].items, completed)
        let late = chat.session(for: UUID())
        chat.receiveHelper(.page(.init(records: [record("call", "tool", "", completed: true, output: "fixture")], earlier: nil, state: nil, snapshot: nil)), session: late)
        chat.receiveHelper(.records([stale]), session: late)
        XCTAssertEqual(late.turns[0].items.map(\.text), [""])
        chat.receiveHelper(.page(.init(records: [done], earlier: nil, state: nil, snapshot: nil)), session: late)
        XCTAssertEqual(late.turns[0].items.map(\.text), completed.map(\.text))
        XCTAssertEqual(late.turns[0].items.map(\.output), completed.map(\.output))
    }

    func testFirstTurnLiveUserPrecedesReplyAndMergesWithPersistedHistory() throws {
        let session = chat.session(for: UUID()); session.active = true
        session.showOptimisticPrompt("first question")
        let user = record("user", "user", "first question", completed: true)
        chat.receiveHelper(.records([user, record("reply", "assistant", "par")]), session: session)
        XCTAssertNil(session.optimisticPrompt)
        XCTAssertEqual(session.turns.flatMap(\.items).map(\.kind), [.user, .assistant])
        chat.receiveHelper(.page(.init(records: [user, record("reply", "assistant", "partial reply", completed: true)], earlier: nil, state: nil, snapshot: nil)), session: session)
        XCTAssertEqual(session.turns.flatMap(\.items).map(\.kind), [.user, .assistant])
        XCTAssertEqual(session.turns.flatMap(\.items).map(\.text), ["first question", "partial reply"])
        XCTAssertTrue(try XCTUnwrap(session.turns.flatMap(\.items).last).completed)
    }

    private let sessionID = "00dc6acf-ac00-7000-8000-000000000105"
    private func json(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) + Data([10])
    }
    private func header(version: Int = 3, session: String? = nil) throws -> Data {
        try json(["type": "session", "id": session ?? sessionID, "version": version,
                  "timestamp": "2000-01-01T00:00:00.000Z", "cwd": "/tmp/fixture"])
    }
    private func row(_ type: String, _ id: String, _ values: [String: Any], parent: String? = nil) throws -> Data {
        var root: [String: Any] = ["type": type, "id": id, "parentId": parent as Any? ?? NSNull(), "timestamp": "2000-01-01T00:00:00.062Z"]
        root.merge(values) { _, new in new }
        return try json(root)
    }
    private func message(_ id: String, _ value: [String: Any], parent: String? = nil) throws -> Data {
        try row("message", id, ["message": value], parent: parent)
    }

    private var chat: ChatCoordinator!
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-pi-transcript-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
    }
    override func tearDown() async throws {
        chat.stop(); chat = nil
        try? FileManager.default.removeItem(at: root)
    }
    /// `opens`: false for a transcript the reader must refuse whole.
    private func open(_ transcript: Data, opens: Bool = true) async throws -> ChatSession {
        let lines = String(decoding: transcript, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return try await chat.archived(lines.last == "" ? Array(lines.dropLast()) : lines, agent: "pi", session: sessionID, in: root, opens: opens)
    }
    private func items(_ session: ChatSession) -> [ChatItem] { session.turns.flatMap(\.items) }

    func testLFFramingWaitsForCompleteRecordsAndPreservesUnicodeSeparators() async throws {
        // Unicode line and paragraph separators are text, not record boundaries.
        let text = "line one\nline two\u{2028}paragraph\u{2029}emoji 🐱"
        let state = try await open(try header() + message("u", ["role": "user", "content": text])
            + message("f", ["role": "assistant", "stopReason": "length", "content": []], parent: "u"))
        XCTAssertEqual(items(state).map(\.text), [text])
        XCTAssertNotNil(state.turns.first?.ended)
    }

    func testMalformedLinesRecoverWithoutLeakingContent() async throws {
        let state = try await open(try header() + Data("{bad}\n[]\n".utf8)
            + message("u", ["role": "user", "content": "after malformed lines"])
            + row("custom", "hidden", ["data": ["secret": "private"]], parent: "u"))
        XCTAssertEqual(items(state).map(\.text), ["after malformed lines"])
    }

    func testFailedToolResultsAndManualBashPreserveOutcome() async throws {
        let state = try await open(try header()
            + message("r", ["role": "toolResult", "toolCallId": "call", "toolName": "bash", "content": [["type": "text", "text": "failed"]], "isError": true, "details": ["exitCode": 42]])
            + message("b", ["role": "bashExecution", "command": "false", "output": "manual failure", "exitCode": 1, "cancelled": false], parent: "r"))
        XCTAssertEqual(items(state).map(\.exitCode), [42, 1])
        XCTAssertEqual(items(state).map(\.output), ["failed", "manual failure"])
    }

    func testNativeRecordShapesPreserveThinkingToolsResultsAndTurnCompletion() async throws {
        let state = try await open(try header()
            + row("model_change", "m", ["provider": "dispatch-local", "modelId": "dispatch-fixture"])
            + row("thinking_level_change", "t", ["thinkingLevel": "high"], parent: "m")
            + message("u", ["role": "user", "content": [["type": "text", "text": "tool check"], ["type": "image", "data": "private"]]], parent: "t")
            + message("a", ["role": "assistant", "provider": "dispatch-local", "model": "dispatch-fixture", "stopReason": "toolUse", "content": [
                ["type": "thinking", "thinking": "Synthetic fixture trace", "thinkingSignature": "private"],
                ["type": "toolCall", "id": "call", "name": "bash", "arguments": ["command": "printf fixture"]]]], parent: "u")
            + message("r", ["role": "toolResult", "toolCallId": "call", "toolName": "bash", "content": [["type": "text", "text": "fixture"]], "isError": false], parent: "a")
            + message("f", ["role": "assistant", "provider": "dispatch-local", "model": "dispatch-fixture", "stopReason": "stop", "content": [["type": "text", "text": "Completed"]]], parent: "r"))
        XCTAssertEqual(items(state).filter { $0.kind == .user }.map(\.text), ["tool check\n[Image]"])
        XCTAssertEqual(items(state).filter { $0.kind == .reasoning }.map(\.text), ["Synthetic fixture trace"])
        let tools = items(state).filter { $0.kind == .tool }
        XCTAssertEqual(tools.count, 1, "The call and its result are one tool card")
        XCTAssertEqual(tools.first?.output, "fixture"); XCTAssertEqual(tools.first?.completed, true)
        XCTAssertEqual(state.turns.count, 1)
        XCTAssertNotNil(state.turns.first?.ended)
        XCTAssertEqual(state.model, "dispatch-local/dispatch-fixture")
        XCTAssertEqual(state.effort, "high")
    }

    func testIdentityAndFormatValidationRejectForeignOrRepeatedHeaders() async throws {
        for version in [1, 4] {
            let unsupported = try await open(try header(version: version) + message("u", ["role": "user", "content": "hidden"]), opens: false)
            XCTAssertTrue(items(unsupported).isEmpty, "version \(version)")
        }
        let foreign = try await open(try header(session: UUID().uuidString) + message("u", ["role": "user", "content": "hidden"]), opens: false)
        XCTAssertTrue(items(foreign).isEmpty, "Another session's file is not this conversation")
        let repeated = try await open(try header(version: 2) + message("v", ["role": "user", "content": "visible"])
            + header(session: UUID().uuidString) + message("u", ["role": "user", "content": "hidden"], parent: "v"))
        XCTAssertEqual(items(repeated).map(\.text), ["visible"], "A second, foreign header ends the transcript")
    }

    func testErrorsCancellationCompactionAndExtensionMessagesStayDistinct() async throws {
        var bytes = try header()
        bytes += try message("u", ["role": "user", "content": "do work"])
        bytes += try message("a", ["role": "assistant", "content": [["type": "thinking", "thinking": "private", "redacted": true]], "stopReason": "error", "errorMessage": "Fixture unavailable"], parent: "u")
        bytes += try message("b", ["role": "assistant", "content": [], "stopReason": "aborted"], parent: "a")
        bytes += try row("compaction", "c", ["summary": "old context", "retainedTail": [["role": "user", "content": "do not replay"]]], parent: "b")
        bytes += try row("branch_summary", "s", ["summary": "Branch context"], parent: "c")
        bytes += try row("custom_message", "hidden", ["content": "hidden instructions", "display": false], parent: "s")
        bytes += try row("custom_message", "visible", ["content": "Extension notice", "display": true, "customType": "fixture"], parent: "hidden")
        let state = try await open(bytes)
        XCTAssertEqual(items(state).filter { $0.kind == .user }.map(\.text), ["do work"])
        XCTAssertTrue(items(state).filter { $0.kind == .reasoning }.isEmpty)
        XCTAssertEqual(items(state).filter { $0.kind == .notice }.map(\.text), ["Fixture unavailable", "Response interrupted.", "Branch context", "Extension notice"])
        XCTAssertFalse(items(state).contains { $0.text.contains("do not replay") || $0.text.contains("hidden instructions") })
    }

    func testIdenticalNativeMessagesAroundToolsKeepTheirDistinctIDs() async throws {
        for timestamped in [true, false] {
            let repeated: [[String: Any]] = [["type": "thinking", "thinking": "Checking"], ["type": "text", "text": "Done"]]
            var first: [String: Any] = ["role": "assistant", "stopReason": "toolUse", "content": repeated + [
                ["type": "toolCall", "id": "call", "name": "bash", "arguments": ["command": "printf fixture"]]]]
            var last: [String: Any] = ["role": "assistant", "stopReason": "stop", "content": repeated]
            if timestamped { first["timestamp"] = 1_789_196_398_304 as Int64; last["timestamp"] = 1_789_196_399_000 as Int64 }
            let state = try await open(try header() + message("u", ["role": "user", "content": "check twice"])
                + message("first", first, parent: "u")
                + message("result", ["role": "toolResult", "toolCallId": "call", "toolName": "bash", "content": [["type": "text", "text": "fixture"]]], parent: "first")
                + message("last", last, parent: "result"))
            let text = items(state).filter { $0.kind == .assistant || $0.kind == .reasoning }
            XCTAssertEqual(text.map(\.text), ["Checking", "Done", "Checking", "Done"])
            XCTAssertEqual(Set(text.map(\.id)).count, 4)
        }
    }
}
