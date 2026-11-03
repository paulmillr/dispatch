import XCTest
#if canImport(AppKit)
@testable import DispatchApp
#else
@testable import DispatchMobile
#endif

@MainActor
final class HelperChatTransportTests: XCTestCase {
    private let route = HelperChat.Route(terminal: 7, session: "conversation")

    private func state(model: String? = "reported", effort: String? = "low") -> HelperChat.State {
        .init(busy: false, activity: nil, model: model, model_label: nil, effort: effort,
              usage: nil, goal: nil, draft: nil, attention: nil, title: nil, compacting: false, service_tier: nil)
    }

    private func notification(_ method: String, _ object: [String: Any]) throws -> HelperChat.Notification {
        try XCTUnwrap(HelperChat.Notification.decode(method, from: HelperBinary.value(object)))
    }

    func testNotificationsKeepTheirAddressAndRejectForeignConversations() throws {
        let objects: [(String, [String: Any])] = [
            ("chat.records", ["records": [], "replace": true, "earlier": "cursor"]),
            ("chat.queue", ["items": []]),
            ("chat.state", ["state": ["busy": false, "compacting": false]]),
            ("interaction.opened", ["interaction": ["id": "request", "approval": false, "blocking": true, "questions": []]])
        ]
        for (method, payload) in objects {
            let object = payload.merging(["terminal": 7, "session": "conversation"]) { _, new in new }
            let event = try notification(method, object)
            XCTAssertEqual(event.address, route, method)
            XCTAssertTrue(event.matches(route), method)
            XCTAssertFalse(event.matches(.init(terminal: 8, session: "conversation")), method)
            XCTAssertFalse(event.matches(.init(terminal: 7, session: "other")), method)
            XCTAssertTrue(event.matches(.init(terminal: 7, session: nil)), method)
        }
        let records = try notification("chat.records", ["terminal": 7, "session": "", "records": []])
        XCTAssertFalse(records.matches(route))
        XCTAssertTrue(records.matches(route, allowingUnnamedSession: true))
        let exit = try notification("terminal.exit", ["terminal": 7])
        XCTAssertTrue(exit.matches(route))
        XCTAssertFalse(exit.matches(.init(terminal: 8, session: nil)))
    }

    func testMalformedKnownNotificationsThrowAndUnknownMethodsAreIgnored() throws {
        for method in ["chat.history", "chat.records", "chat.queue", "chat.state", "interaction.opened", "terminal.exit", "chat.archive"] {
            XCTAssertThrowsError(try HelperChat.Notification.decode(method, from: .null), method)
            XCTAssertThrowsError(try HelperChat.Notification.decode(method, from: HelperBinary.value(["terminal": "wrong"])), method)
        }
        XCTAssertNil(try HelperChat.Notification.decode("future.chat.event", from: .null))
    }

    func testModelMenusKeepIDsCurrentDefaultsAndPlatformCaptions() async throws {
        let menu = HelperChat.Menu(choices: [.init(id: "model-id", label: "Model label", detail: "Description")],
                                   current: "model-id", default: "model-id")
        var methods: [String] = []
        for model in [nil, "model-id"] {
            let loaded = try await HelperChat.ModelTransport.menu(route: route, model: model) { method, input in
                methods.append(method)
                XCTAssertEqual(input.terminal, self.route.terminal)
                XCTAssertEqual(input.session, self.route.session)
                XCTAssertEqual(input.model, model)
                return menu
            }
            let desktop = HelperChat.ModelTransport.choices(loaded, detail: .description)
            let mobile = HelperChat.ModelTransport.choices(loaded, detail: .label)
            XCTAssertEqual(desktop.first?.detail, "Description")
            XCTAssertEqual(mobile.first?.detail, "Model label")
            XCTAssertEqual(desktop.first?.name, "model-id")
            XCTAssertEqual(mobile.first?.name, "model-id")
            XCTAssertEqual(desktop.first?.current, true)
            XCTAssertEqual(mobile.first?.isDefault, true)
        }
        XCTAssertEqual(methods, ["chat.models", "chat.settings"])
    }

    func testDeclinedModelChangeReturnsOnlyReportedChoice() async throws {
        let reported = try await HelperChat.ModelTransport.select(route: route, model: "requested", effort: "high", set: { input in
            XCTAssertEqual(input.model, "requested")
            XCTAssertEqual(input.effort, "high")
            return .init(written: true, may_have_sent: true, reason: nil)
        }, read: { input in
            XCTAssertEqual(input.terminal, self.route.terminal)
            XCTAssertEqual(input.session, self.route.session)
            XCTAssertNil(input.model)
            return .init(state: self.state())
        })
        XCTAssertEqual(reported.model, "reported")
        XCTAssertEqual(reported.effort, "low")
    }

    func testUnconfirmedDeliveryDoesNotReadBackOrInventASelection() async {
        do {
            _ = try await HelperChat.ModelTransport.select(route: route, model: "requested", effort: nil,
                set: { _ in .init(written: false, may_have_sent: true, reason: "Unknown delivery") },
                read: { _ in XCTFail("Undelivered selections must not read state"); return .init(state: self.state()) })
            XCTFail("Expected failed delivery")
        } catch let error as HelperChat.Delivery { XCTAssertTrue(error.uncertain) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testStateReadFailureAndMissingModelDoNotInventASelection() async {
        let failure = HelperFailure(code: "unavailable", message: "No state")
        for missingModel in [false, true] {
            do {
                _ = try await HelperChat.ModelTransport.select(route: route, model: "requested", effort: nil,
                    set: { _ in .init(written: true, may_have_sent: true, reason: nil) },
                    read: { _ in
                        if !missingModel { throw failure }
                        return .init(state: self.state(model: nil))
                    })
                XCTFail("Expected unconfirmed selection")
            } catch let error as HelperFailure {
                XCTAssertEqual(error.code, missingModel ? "unconfirmed" : "unavailable")
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCancellationAfterDeliveryPreventsReadbackAndAfterReadbackPreventsSuccess() async {
        for cancelDuringRead in [false, true] {
            let task = Task { @MainActor in
                try await HelperChat.ModelTransport.select(route: route, model: "requested", effort: nil,
                    set: { _ in
                        if !cancelDuringRead { withUnsafeCurrentTask { $0?.cancel() } }
                        return .init(written: true, may_have_sent: true, reason: nil)
                    }, read: { _ in
                        XCTAssertTrue(cancelDuringRead, "Cancellation after delivery must stop before the read")
                        withUnsafeCurrentTask { $0?.cancel() }
                        return .init(state: self.state())
                    })
            }
            do { _ = try await task.value; XCTFail("Cancelled selection must not confirm") }
            catch is CancellationError {}
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRepliesUseRequestAndQuestionIDsAndValidateOptionBounds() throws {
        let question = HelperChat.Question(id: "question-id", header: "Question", text: "Repeated display text",
            secret: false, options: [.init(id: "first", label: "One", detail: nil), .init(id: "second", label: "Two", detail: nil)],
            multiple: false, custom: true, blocks: nil)
        let interaction = HelperChat.Interaction(id: "request-id", key: nil, approval: false, blocking: true,
            questions: [question], turn: nil, record: nil)
        let chosen = try XCTUnwrap(interaction.answerInput(route: route, response: .labels([question.text: "Two"])))
        XCTAssertEqual(chosen.interaction, "request-id")
        XCTAssertEqual(chosen.answers, ["question-id": .options([1])])
        XCTAssertEqual(chosen.terminal, route.terminal)
        XCTAssertEqual(chosen.session, route.session)
        XCTAssertEqual(interaction.answerInput(route: route, response: .skip)?.answers, ["question-id": .skip])
        XCTAssertEqual(interaction.answerInput(route: route, response: .option(0))?.answers, ["question-id": .options([0])])
        XCTAssertNil(interaction.answerInput(route: route, response: .option(-1)))
        XCTAssertNil(interaction.answerInput(route: route, response: .option(2)))
        if case .toolQuestions = interaction.presentation {} else { XCTFail("Expected an inline tool form") }
    }

    private func questionnaire(multiple: Bool = true) -> ClaudeQuestions {
        .init([.init(text: "Which choices?", header: "Choices",
                     options: [.init(label: "One, two", description: "", preview: nil),
                               .init(label: "Three", description: "", preview: nil)], multiple: multiple)])
    }

    private func formInteraction(multiple: Bool = true) -> HelperChat.Interaction {
        .init(id: "form-request", key: nil, approval: false, blocking: true,
              questions: [.init(id: "stable-question-id", header: "Choices", text: "Which choices?", secret: false,
                                options: [.init(id: "first", label: "One, two", detail: nil),
                                          .init(id: "second", label: "Three", detail: nil)],
                                multiple: multiple, custom: true, blocks: nil)], turn: nil, record: nil)
    }

    func testNativeDraftSnapshotPreservesMultipleOptionsWhoseLabelsContainCommas() throws {
        let interaction = formInteraction()
        var delivered: [String: HelperChat.Answer]?
        let approval = PendingApproval(key: "form-request", operation: "Question", questions: questionnaire()) { pending in
            delivered = interaction.answerInput(route: self.route, response: .ordered(pending.structuredAnswers ?? []))?.answers
        }
        let draft = try XCTUnwrap(approval.questionDraft)
        draft.select("One, two")
        draft.select("Three")
        approval.answerDraft()
        XCTAssertEqual(approval.answers, ["Which choices?": "One, two, Three"])
        XCTAssertEqual(approval.structuredAnswers, [.options([0, 1])])
        XCTAssertEqual(delivered, ["stable-question-id": .options([0, 1])])
    }

    func testNativeCustomAnswerMatchingAnOptionRemainsTextAndFreezesBeforeEdits() throws {
        let approval = PendingApproval(key: "form-request", operation: "Question", questions: questionnaire(multiple: false)) { _ in }
        let draft = try XCTUnwrap(approval.questionDraft)
        draft.type("Three")
        approval.answerDraft()
        draft.select("One, two")
        draft.type("Later edit")
        approval.answerDraft()
        XCTAssertEqual(approval.answers, ["Which choices?": "Three"])
        XCTAssertEqual(approval.structuredAnswers, [.text("Three")])
        let input = formInteraction(multiple: false).answerInput(route: route, response: .ordered(approval.structuredAnswers ?? []))
        XCTAssertEqual(input?.answers, ["stable-question-id": .text("Three")])
    }

    func testExplicitStringAnswersUseThePayloadAndDoNotInferTheMutableDraft() throws {
        let approval = PendingApproval(key: "form-request", operation: "Question", questions: questionnaire(multiple: false)) { _ in }
        let draft = try XCTUnwrap(approval.questionDraft)
        draft.type("One, two")
        approval.answer(["Which choices?": "Three"])
        XCTAssertNil(approval.structuredAnswers)
        XCTAssertEqual(approval.answers, ["Which choices?": "Three"])
        let input = formInteraction(multiple: false).answerInput(route: route, response: .labels(approval.answers ?? [:]))
        XCTAssertEqual(input?.answers, ["stable-question-id": .options([1])])
    }

    func testOrderedRepliesValidateCountAndOptionBoundsBeforeMappingIDs() {
        let interaction = formInteraction(multiple: false)
        XCTAssertNil(interaction.answerInput(route: route, response: .ordered([])))
        XCTAssertNil(interaction.answerInput(route: route, response: .ordered([.options([2])])))
        XCTAssertNil(interaction.answerInput(route: route, response: .ordered([.options([])])))
        XCTAssertNil(interaction.answerInput(route: route, response: .ordered([.options([0, 1])])))
    }

}
