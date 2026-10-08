import Foundation
import XCTest
@testable import DispatchApp

/// Claude transcripts as the app shows them: each case writes transcript lines and opens them as an archived
/// conversation through the helper (chat.page reads the file).
@MainActor
final class ClaudeTranscriptTests: XCTestCase {

    private let session = "00000000-0000-4000-8000-000000000102"
    private func line(_ type: String, _ id: String, _ message: [String: Any], extra: [String: Any] = [:]) throws -> Data {
        var root: [String: Any] = ["type": type, "uuid": id, "sessionId": session, "version": "2.1.260",
                                   "timestamp": "2000-01-01T10:00:00.123Z", "isSidechain": false, "message": message]
        root.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) + Data([10])
    }
    private func raw(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) + Data([10])
    }

    private var chat: ChatCoordinator!
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-claude-transcript-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
    }
    override func tearDown() async throws {
        chat.stop(); chat = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func open(_ transcript: Data, opens: Bool = true) async throws -> ChatSession {
        let lines = String(decoding: transcript, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return try await chat.archived(lines.last == "" ? Array(lines.dropLast()) : lines, agent: "claude", session: session, in: root, opens: opens)
    }
    private func items(_ session: ChatSession) -> [ChatItem] { session.turns.flatMap(\.items) }

    func testConversationTitlesRespectIdentityAndNewerMetadata() async throws {
        let state = try await open(try raw(["type": "ai-title", "aiTitle": "Older", "sessionId": session])
            + raw(["type": "ai-title", "aiTitle": "Generated title", "sessionId": session])
            + raw(["type": "custom-title", "customTitle": "My title", "sessionId": session]))
        // A title of another session makes the whole page foreign to the reader (claude helper tests: parser level).
        XCTAssertEqual(state.conversationTitle, "My title")
        state.title = "Live name"
        XCTAssertEqual(state.conversationTitle, "Live name")
        state.title = nil
        XCTAssertEqual(state.conversationTitle, "My title")
        state.resetConversation()
        XCTAssertNil(state.conversationTitle)
    }

    func testTaskNotificationsAreNoticesNotUserMessages() async throws {
        let notification = "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background command \"make 2&gt;&amp;1\" completed (exit code 0)</summary>\n</task-notification>"
        let state = try await open(try line("user", "n1", ["role": "user", "content": notification],
                                            extra: ["origin": ["kind": "task-notification"], "promptSource": "system", "promptId": "p1"])
            + line("user", "u1", ["role": "user", "content": "<task-notification> typed by me"],
                   extra: ["origin": ["kind": "human"], "promptSource": "typed", "promptId": "p2"]))
        XCTAssertEqual(items(state).map(\.kind), [.notice, .user])
        XCTAssertEqual(items(state).first?.text, "Background command \"make 2>&1\" completed (exit code 0)")
        XCTAssertEqual(items(state).last?.text, "<task-notification> typed by me")
        XCTAssertEqual(state.turns.count, 2)
    }

    func testRealRecordShapesPreserveTurnsThinkingAndToolResults() async throws {
        let state = try await open(try line("user", "u1", ["role": "user", "content": "thinking tool check"])
            + line("assistant", "a1", ["role": "assistant", "model": "fixture", "stop_reason": "tool_use", "content": [
                ["type": "thinking", "thinking": "Synthetic trace", "signature": "private"],
                ["type": "tool_use", "id": "call-1", "name": "Bash", "input": ["command": "printf marker"]]]], extra: ["effort": "high"])
            + line("user", "r1", ["role": "user", "content": [["type": "tool_result", "tool_use_id": "call-1", "content": "marker", "is_error": false]]])
            + line("assistant", "a2", ["role": "assistant", "model": "fixture", "stop_reason": "end_turn", "content": [["type": "text", "text": "Completed"]]])
            + line("user", "u2", ["role": "user", "content": "again"]))
        XCTAssertEqual(items(state).filter { $0.kind == .user }.map(\.text), ["thinking tool check", "again"])
        XCTAssertEqual(items(state).filter { $0.kind == .reasoning }.map(\.text), ["Synthetic trace"])
        XCTAssertEqual(state.turns.count, 2)
        let tools = try XCTUnwrap(state.turns.first).items.filter { $0.kind == .tool }
        XCTAssertEqual(tools.count, 1, "The call and its result are one tool card in the first turn")
        XCTAssertEqual(tools.first?.output, "marker")
        XCTAssertEqual(tools.first?.completed, true)
        XCTAssertNotNil(state.turns.first?.ended)
    }

    func testIgnoresSidechainsInjectedContextAndRedactedThinking() async throws {
        let rows = try line("user", "side", ["role": "user", "content": "hidden sidechain"], extra: ["isSidechain": true])
            + line("user", "meta", ["role": "user", "content": "injected instructions"], extra: ["isMeta": true])
            + line("assistant", "redacted", ["role": "assistant", "content": [["type": "redacted_thinking", "data": "private"]]])
            + line("user", "real", ["role": "user", "content": "visible"])
        let opened = try await open(rows)
        XCTAssertEqual(items(opened).map(\.text), ["visible"])
        // The reader drops a page holding another session's record whole (old TranscriptReader gate);
        // where a foreign record ends the parse is the claude helper's parser test.
        let foreign = try await open(rows + line("user", "foreign", ["role": "user", "content": "wrong session"], extra: ["sessionId": "00000000-0000-4000-8000-000000000103"])
            + line("user", "later", ["role": "user", "content": "must stay rejected"]), opens: false)
        XCTAssertTrue(items(foreign).isEmpty, "\(items(foreign).map(\.text))")
    }

    func testResponseBeforePromptFollowsAttachmentParentsAcrossReads() async throws {
        let state = try await open(try line("user", "old", ["role": "user", "content": "previous prompt"])
            + line("assistant", "answer", ["role": "assistant", "model": "fixture", "stop_reason": "tool_use",
                "content": [["type": "tool_use", "id": "question", "name": "AskUserQuestion", "input": ["questions": []]]]],
                extra: ["parentUuid": "attachment"])
            + line("user", "new", ["role": "user", "content": "current prompt"], extra: ["promptId": "current"])
            + line("attachment", "attachment", [:], extra: ["parentUuid": "new"]))
        XCTAssertEqual(state.turns.map { $0.items.map(\.id) }, [["user-old"], ["user-new", "tool-question"]],
                       "An unlinked tool joins the prompt its parent chain reaches, not the previous one")
    }

    func testPageContextDoesNotOverrideParentsWithinThePageOrLaterLiveReads() async throws {
        let state = try await open(try line("assistant", "old-answer", ["role": "assistant", "content": [["type": "text", "text": "older page prefix"]]],
                                            extra: ["parentUuid": "outside-page"])
            + line("assistant", "answer", ["role": "assistant", "content": [["type": "text", "text": "new reply"]]], extra: ["parentUuid": "new"])
            + line("user", "new", ["role": "user", "content": "new prompt"])
            + line("assistant", "later-answer", ["role": "assistant", "content": [["type": "text", "text": "later reply"]]], extra: ["parentUuid": "later"])
            + line("user", "later", ["role": "user", "content": "later prompt"]))
        let turns = state.turns.map { $0.items.map(\.text) }
        XCTAssertTrue(turns.contains(["new prompt", "new reply"]), "\(turns)")
        XCTAssertTrue(turns.contains(["later prompt", "later reply"]), "\(turns)")
    }

    func testUnresolvedParentCyclesStayBoundedAndForeignRecordsCannotResolveThem() async throws {
        let cycle = try await open(try line("assistant", "a", ["role": "assistant", "content": [["type": "text", "text": "unresolved"]]], extra: ["parentUuid": "b"])
            + line("attachment", "b", [:], extra: ["parentUuid": "a"])
            + line("user", "b", ["role": "user", "content": "foreign"], extra: ["sessionId": "00000000-0000-4000-8000-000000000103"])
            + line("user", "b", ["role": "user", "content": "too late"]), opens: false)
        XCTAssertTrue(items(cycle).isEmpty, "\(items(cycle).map(\.text))")
        var bounded = Data()
        for index in 0...400 { bounded += try line("attachment", "node-\(index)", [:], extra: ["parentUuid": "missing"]) }
        bounded += try line("user", "after", ["role": "user", "content": "after an unbounded graph"])
        // The unresolved attachments show nothing and stay bounded; the row after them is this session's
        // (old reader and helper agree; the parser's fail-closed bound is the claude helper's test).
        let failed = try await open(bounded)
        XCTAssertEqual(items(failed).map(\.text), ["after an unbounded graph"])
    }

    func testMalformedAndInterruptedInput() async throws {
        let state = try await open(Data("{bad}\n[]\n".utf8) + line("user", "u1", ["role": "user", "content": "hello"])
            + line("user", "interrupt", ["role": "user", "content": "[Request interrupted by user]"]))
        XCTAssertEqual(items(state).map(\.text), ["hello"])
        XCTAssertEqual(state.turns.count, 1)
        XCTAssertNotNil(state.turns.first?.ended, "Interruption must end the current turn")
    }

    func testNativeCommandsDoNotCreatePhantomUserTurns() async throws {
        let command = "<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"
        // Printed output reaches the pending command, never the transcript (Claude 2.1.285 writes it as a user
        // record or as a styled system record); /compact records its bare command and a transcript-only summary.
        let state = try await open(try line("user", "clear", ["role": "user", "content": command])
            + line("user", "model", ["role": "user", "content": command], extra: ["promptId": "local-command"])
            + line("user", "output", ["role": "user", "content": "<local-command-stdout>Set model for this session</local-command-stdout>"], extra: ["promptId": "local-command"])
            + line("system", "styled", [:], extra: ["subtype": "local_command", "content": "<local-command-stdout>\u{1B}[2mCompacted (ctrl+o to see full summary)\u{1B}[22m</local-command-stdout>"])
            + line("system", "name", [:], extra: ["subtype": "local_command", "content": command])
            + line("user", "compact", ["role": "user", "content": "/compact"], extra: ["promptId": "p0"])
            + line("user", "summary", ["role": "user", "content": "This session is being continued from a previous conversation."],
                   extra: ["promptId": "p0", "isCompactSummary": true, "isVisibleInTranscriptOnly": true])
            + line("user", "typed", ["role": "user", "content": command], extra: ["promptId": "human", "promptSource": "typed"]))
        XCTAssertEqual(items(state).map(\.kind), [.user], "\(items(state).map(\.text))")
        XCTAssertEqual(items(state).first?.text, command, "A typed command text is the user's message")
        XCTAssertEqual(state.turns.count, 1)
    }

    func testModelTurnCommandsShowTheEnteredCommand() async throws {
        // Claude 2.1.285 /init: human command markup, then its expanded prompt as isMeta.
        let state = try await open(try line("user", "c1", ["role": "user", "content": "<command-message>init</command-message>\n<command-name>/init</command-name>"],
                                            extra: ["origin": ["kind": "human"], "promptId": "p1"])
            + line("user", "m1", ["role": "user", "content": [["type": "text", "text": "Please analyze this codebase"]]], extra: ["isMeta": true, "promptId": "p1"])
            + line("assistant", "a1", ["role": "assistant", "content": [["type": "text", "text": "Done."]], "stop_reason": "end_turn"])
            + line("user", "c2", ["role": "user", "content": "<command-name>/review</command-name>\n<command-message>review</command-message>\n<command-args> 12 </command-args>"],
                   extra: ["origin": ["kind": "human"], "promptId": "p2"]))
        XCTAssertEqual(items(state).map(\.kind), [.user, .assistant, .user])
        XCTAssertEqual(items(state).filter { $0.kind == .user }.map(\.text), ["/init", "/review 12"])
        XCTAssertEqual(state.turns.count, 2)
    }
}
