import Foundation
import XCTest
#if canImport(AppKit)
@testable import DispatchApp
#else
@testable import DispatchMobile
#endif

@MainActor
final class ChatPresentationPolicyTests: XCTestCase {
    func testInlineMarkdownPreservesFormattingAndFiltersLinksBeforePlatformStyling() {
        let source = "**bold** *soft* `code`\r\n[web](HTTPS://example.com/docs) " +
            "[credentials](https://user:pass@example.com) [local](/tmp/example.swift:4) " +
            "[file](file:///tmp/example.swift) [shell](ssh://example.com)\u{202E}"
        let value = ChatMarkdownPolicy.inline(source)
        XCTAssertEqual(value.runs.compactMap { $0.link?.absoluteString }, ["HTTPS://example.com/docs"])
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(String(value.characters).contains("⟦RLO⟧"))
        XCTAssertFalse(String(value.characters).contains("\r"))
        let optedIn = ChatMarkdownPolicy.inline(source, allowingAdditionalLink: { $0.absoluteString == "file:///tmp/example.swift" })
        XCTAssertEqual(optedIn.runs.compactMap { $0.link?.absoluteString }, ["HTTPS://example.com/docs", "file:///tmp/example.swift"])
        XCTAssertEqual(ChatMarkdownPolicy.inline(source), value, "A platform's allowance must never change the default policy")
    }

    func testCacheBoundsCountAndUTF8BytesWithoutEvictingForOversizedMessages() {
        var cache = ChatTextCache<String, Int>(limit: .init(count: 2, bytes: 4))
        cache.insert(1, for: "first", source: "λλ")
        cache.insert(2, for: "second", source: "text")
        cache.insert(3, for: "large", source: "λλλ")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache["first"], 1)
        XCTAssertNil(cache["large"])
        cache.insert(4, for: "second", source: "text")
        XCTAssertEqual(cache["first"], 1, "Replacing a cached revision does not evict another entry")
        cache.insert(5, for: "third", source: "new")
        XCTAssertEqual(cache.count, 1)
        XCTAssertNil(cache["first"])
        XCTAssertEqual(cache["third"], 5)
    }

    func testChoiceSelectionUsesDraftStateForCommaLabelsAndCustomAnswers() {
        let form = ClaudeQuestions([
            .init(text: "Choose", header: "", options: [
                .init(label: "Read, then write", description: "", preview: nil),
                .init(label: "Other", description: "", preview: nil)], multiple: true),
            .init(text: "Details", header: "", options: [], multiple: false)
        ])
        let draft = ClaudeQuestionDraft(form)
        draft.select("Read, then write")
        XCTAssertTrue(draft.isSelected("Read, then write", in: draft.question))
        draft.select("Other")
        XCTAssertEqual(draft.answer(draft.question), "Read, then write, Other")
        draft.type("Read, then write")
        XCTAssertFalse(draft.isSelected("Read, then write", in: draft.question), "A matching custom answer does not select the chip")
        draft.next()
        draft.type("Details kept")
        XCTAssertTrue(draft.actions.canSubmit)
        draft.back()
        XCTAssertTrue(draft.usingCustom.contains(draft.question.id))
        XCTAssertEqual(draft.answer(draft.question), "Read, then write")
        draft.select("Other")
        XCTAssertFalse(draft.isSelected("Other", in: draft.question), "A multi-choice chip toggles its stored choice")
        XCTAssertTrue(draft.isSelected("Read, then write", in: draft.question))
    }

    func testSideQuestionInvalidCustomNeverFallsBackAndUncertainDeliveryLocksAllActions() throws {
        let request = try sideQuestion()
        request.next()
        XCTAssertEqual(request.index, 0, "Next requires the current answer")
        request.select("Read, then write")
        XCTAssertTrue(request.isSelected("Read, then write", in: request.question))
        request.type(" ")
        XCTAssertNil(request.answers, "An invalid active custom answer must not send the previous option")
        request.type("hidden\u{0}answer")
        XCTAssertNil(request.answers)
        request.type("Custom answer")
        request.next()
        request.select("Done")
        XCTAssertTrue(request.canSubmit(skip: false))
        request.back()
        XCTAssertEqual(request.answer(request.question), "Custom answer")
        request.submissionUncertain = true
        XCTAssertFalse(request.actions.canEdit)
        XCTAssertFalse(request.actions.canGoNext)
        XCTAssertFalse(request.canSubmit(skip: false))
        XCTAssertFalse(request.canSubmit(skip: true))
        request.select("Read, then write")
        request.type("Changed")
        request.next()
        XCTAssertEqual(request.index, 0)
        XCTAssertEqual(request.answer(request.question), "Custom answer")
        request.submissionUncertain = false
        request.submitted = true
        XCTAssertFalse(request.canSubmit(skip: true))
        XCTAssertFalse(request.canSubmit(skip: false))
    }

    private func sideQuestion() throws -> ChatSideQuestion {
        let object: [String: Any] = ["id": "request", "approval": false, "blocking": false, "questions": [
            ["id": "first", "header": "", "text": "Choose", "secret": false, "multiple": false, "custom": true,
             "options": [["id": "comma", "label": "Read, then write"]]],
            ["id": "second", "header": "", "text": "Finish", "secret": false, "multiple": false, "custom": false,
             "options": [["id": "done", "label": "Done"]]]
        ]]
        let interaction = try JSONDecoder().decode(HelperChat.Interaction.self, from: JSONSerialization.data(withJSONObject: object))
        return try XCTUnwrap(ChatSideQuestion(interaction: interaction, session: "conversation"))
    }
}
