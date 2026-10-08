import XCTest
@testable import DispatchApp

@MainActor
final class ChatSideQuestionTests: XCTestCase {
    /// A helper interaction: a choice that also takes text, free text, and a secret.
    private func interaction(blocking: Bool = false) -> [String: Any] {
        ["id": "request", "approval": false, "blocking": blocking, "questions": [
            ["id": "choice", "header": "Approach", "text": "Which approach?", "secret": false, "multiple": false, "custom": true,
             "options": [["id": "small", "label": "Small", "detail": "Keep it focused."], ["id": "broad", "label": "Broad", "detail": "Include more."]]],
            ["id": "detail", "header": "Detail", "text": "Which approach?", "secret": false, "multiple": false, "custom": true, "options": []],
            ["id": "secret", "header": "Private", "text": "Private value?", "secret": true, "multiple": false, "custom": true, "options": []]
        ]]
    }
    private func answers(_ question: ChatSideQuestion) throws -> String {
        String(decoding: try JSONEncoder().encode(try XCTUnwrap(question.answers)), as: UTF8.self)
    }

    func testMainQuestionsKeepDraftAndRespectBlockingAndResolution() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.active = true; session.sessionID = "side"; session.busy = true
        session.draft = "keep my draft"
        session.questions = [try ChatSideQuestion.helper(interaction(), session: "side")]
        XCTAssertFalse(session.waitingForAnswer)
        XCTAssertFalse(AgentWorkingState(session).waiting)
        let question = try ChatSideQuestion.helper(interaction(blocking: true), session: "side")
        session.questions = [question]
        XCTAssertTrue(session.waitingForAnswer)
        XCTAssertTrue(AgentWorkingState(session).waiting)
        question.type("unsent custom answer")
        question.submitted = true
        XCTAssertFalse(session.waitingForAnswer, "A submitted answer no longer waits")
        question.clearAnswers()
        XCTAssertTrue(question.custom.isEmpty)
        session.questions = []
        XCTAssertEqual(session.draft, "keep my draft")
    }

    func testQuestionHistoryShowsAnswersWithoutRawProtocolAndRedactsSecrets() async throws {
        let questions: [[String: Any]] = [
            ["id": "choice", "header": "Approach", "question": "Which approach?", "isOther": true, "isSecret": false,
             "options": [["label": "Small", "description": "Keep it focused."], ["label": "Broad", "description": "Include more."]]],
            ["id": "detail", "header": "Detail", "question": "Which approach?", "isOther": true, "isSecret": false],
            ["id": "secret", "header": "Private", "question": "Private value?", "isOther": true, "isSecret": true]]
        let answered: [String: Any] = ["answers": ["choice": ["answers": ["Small"]], "detail": ["answers": []], "secret": ["answers": ["private-value"]]]]
        func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
        let id = "00000000-0000-4000-8000-000000000131"
        let lines = try [
            ["type": "session_meta", "payload": ["id": id, "cli_version": "0.154.0", "source": "cli"]],
            ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn"]],
            ["type": "response_item", "payload": ["type": "function_call", "call_id": "question", "name": "request_user_input", "arguments": json(["questions": questions])]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "question", "output": json(answered)]]
        ].map { try json($0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-question-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let session = try await chat.archived(lines, agent: "codex", session: id, in: root)
        let presentation = ToolPresentation(try XCTUnwrap(session.turns.flatMap(\.items).first { $0.kind == .tool }))
        XCTAssertEqual(presentation.title, "Questions answered")
        XCTAssertTrue(presentation.input.isEmpty)
        XCTAssertTrue(presentation.output.contains("Small"))
        XCTAssertTrue(presentation.output.contains("Skipped"))
        XCTAssertFalse(presentation.output.contains("private-value"))
    }

    func testAnswersUseIDsAndRequireExplicitCompleteInput() throws {
        let request = try ChatSideQuestion.helper(interaction(), session: "side")
        XCTAssertFalse(request.blocking)
        XCTAssertFalse(request.complete)
        XCTAssertNil(request.answers)
        request.select("Small")
        request.index = 1; request.type("  ")
        XCTAssertNil(request.answer(request.question))
        request.type("Custom λ")
        request.index = 2; request.type("private-value")
        request.index = 0
        XCTAssertEqual(request.answer(request.question), "Small")
        XCTAssertTrue(request.complete)
        let sent = try JSONSerialization.jsonObject(with: Data(try answers(request).utf8)) as? [String: Any]
        XCTAssertEqual(sent?["choice"] as? [Int], [0])
        XCTAssertEqual(sent?["detail"] as? String, "Custom λ")
        XCTAssertEqual(sent?["secret"] as? String, "private-value")
        XCTAssertFalse(request.summary(skip: false).contains("private-value"))
        request.submitted = true
        request.select("Broad")
        XCTAssertEqual(request.answer(request.question), "Small", "A submitted form does not change")
        request.clearAnswers()
        XCTAssertTrue(request.custom.isEmpty)
    }

    func testSkipAndCustomChoiceSwitching() throws {
        let request = try ChatSideQuestion.helper(interaction(), session: "side")
        request.select("Small"); request.type("Another approach")
        XCTAssertEqual(request.answer(request.question), "Another approach")
        request.select("Broad")
        XCTAssertEqual(request.answer(request.question), "Broad")
        XCTAssertEqual(request.summary(skip: true).components(separatedBy: "Skipped").count - 1, 3)
    }

    func testMalformedDuplicateAndOversizedQuestionsAreRejected() throws {
        // Malformed and duplicate payloads are the harness's to reject (moved to codex); an empty
        // interaction is no form, and an oversized answer is never sent.
        var empty = interaction(); empty["questions"] = []
        let value = try JSONDecoder().decode(HelperChat.Interaction.self, from: JSONSerialization.data(withJSONObject: empty))
        XCTAssertNil(ChatSideQuestion(interaction: value, session: "side"))
        let request = try ChatSideQuestion.helper(interaction(), session: "side")
        request.type(String(repeating: "λ", count: 9000))
        XCTAssertNil(request.answer(request.question))
    }
}
