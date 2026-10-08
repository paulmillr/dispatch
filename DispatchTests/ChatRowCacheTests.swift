import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class ChatRowCacheTests: XCTestCase {
    private func tool(_ id: String) -> ChatItem {
        ChatItem(id: id, kind: .tool, text: #"{"cmd":"echo hello"}"#,
                 title: "exec_command", output: "hello", completed: true)
    }

    private func turn(_ id: String) -> ChatTurn {
        ChatTurn(id: id, items: [ChatItem(id: "reply", kind: .assistant, text: "Working"), tool("one"), tool("two")])
    }

    private func groupPresentations(_ session: ChatSession) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: session.transcriptRows.compactMap { row in
            guard let turnID = row.turnID, let group = row.group else { return nil }
            return (turnID, group.presentationID)
        })
    }

    func testPrependingBeyond256TurnsKeepsUnchangedGroupPresentations() {
        let session = ChatSession(id: UUID())
        session.turns = (0..<300).map { turn("turn-\($0)") }
        let before = groupPresentations(session)
        session.turns.insert(turn("older"), at: 0)
        let prepended = groupPresentations(session)
        XCTAssertEqual(prepended.count, 301)
        for (turnID, presentation) in before {
            XCTAssertEqual(prepended[turnID], presentation, "Older history must not restart unchanged groups' summary tasks")
        }

        session.turns[151].items[1].output = "new output"
        let updated = groupPresentations(session)
        XCTAssertNotEqual(updated["turn-150"], before["turn-150"])
        for (turnID, presentation) in prepended where turnID != "turn-150" {
            XCTAssertEqual(updated[turnID], presentation)
        }
        XCTAssertEqual(session.transcriptRows.first { $0.turnID == "turn-150" }?.group?.children.first?.item?.output, "new output")
    }

    func testTimestampCorrectionRefreshesReplyWithoutRebuildingOtherTurns() {
        let session = ChatSession(id: UUID()), start = Date(timeIntervalSince1970: 1_750_000_000)
        session.insert(ChatItem(id: "prompt", kind: .user, text: "Question"), turnID: "one", at: start)
        let reply = ChatItem(id: "reply", kind: .assistant, text: "Working")
        session.insert(reply, turnID: "one", at: start.addingTimeInterval(60))
        session.insert(tool("tool"), turnID: "one", at: start.addingTimeInterval(90))
        session.turns.append(turn("two"))
        let other = groupPresentations(session)["two"]

        session.insert(reply, turnID: "one", at: start.addingTimeInterval(50), historical: true)
        XCTAssertEqual(session.transcriptRows.first { $0.item?.id == "reply" }?.replyTime, start.addingTimeInterval(50))
        XCTAssertEqual(groupPresentations(session)["two"], other)
        session.turns[0].ended = start.addingTimeInterval(180)
        XCTAssertEqual(session.transcriptRows.first { $0.id == "worked-for:one" }?.workedFor, 180)
        XCTAssertEqual(groupPresentations(session)["two"], other)
    }

    func testApprovalsAndOptimisticPromptKeepExistingGroupPresentations() {
        let session = ChatSession(id: UUID())
        session.turns = [turn("one"), turn("two")]
        let before = groupPresentations(session)
        let approval = PendingApproval(key: "approval", operation: "echo hello", turnID: "one") { _ in }
        session.approvals = [approval]
        session.showOptimisticPrompt("Next question")
        XCTAssertEqual(groupPresentations(session), before)
        XCTAssertTrue(session.transcriptRows.contains { $0.approval === approval })
        XCTAssertEqual(session.transcriptRows.last?.item?.text, "Next question")

        session.approvals = []; session.optimisticPrompt = nil
        XCTAssertEqual(groupPresentations(session), before)
        session.turns.reverse()
        XCTAssertEqual(session.transcriptRows.compactMap(\.turnID), ["two", "one"])
        XCTAssertEqual(groupPresentations(session), before)
    }

    func testGeometryPruningRetainsRevisionsSharedBySurvivingTurns() {
        let session = ChatSession(id: UUID()), shared = tool("shared"), typography = ChatTypography()
        session.turns = [ChatTurn(id: "one", items: [shared]), ChatTurn(id: "two", items: [shared])]
        _ = session.transcriptRows
        session.toolLayouts.remember(CGSize(width: 500, height: 240), for: shared.presentationID, typography: typography)

        session.turns.removeFirst()
        _ = session.transcriptRows
        XCTAssertEqual(session.toolLayouts.height(for: shared.presentationID, width: 500, typography: typography), 240)
        session.turns[0].items[0].output = "Changed"
        _ = session.transcriptRows
        XCTAssertNil(session.toolLayouts.height(for: shared.presentationID, width: 500, typography: typography))

        let saved = session.turns
        session.resetConversation()
        XCTAssertTrue(session.transcriptRows.isEmpty)
        session.turns = saved
        XCTAssertEqual(session.transcriptRows.first?.item?.output, "Changed")
    }

    func testToolNameClassificationPreservesNamespaceAndCaseSemantics() {
        for title in ["", ".", "exec", "EXEC", "functions.Exec", "tools.namespace.APPLY_PATCH",
                      "exec.", ".exec", "tools..exec", "namespace.İ", "namespace.Σ", "namespace.e\u{301}", "namespace.\u{301}exec"] {
            XCTAssertEqual(ToolOrchestration.normalizedName(title), title.components(separatedBy: ".").last?.lowercased() ?? "")
        }
        XCTAssertTrue(ToolOrchestration.isWrapper(ChatItem(id: "exec", kind: .tool, text: "", title: "functions.Exec")))
        XCTAssertFalse(ToolOrchestration.isWrapper(ChatItem(id: "exec", kind: .tool, text: "", title: "exec.")))
        XCTAssertTrue(ChatPatch.isPatchOperation(ChatItem(id: "patch", kind: .tool, text: "", title: "tools.APPLY_PATCH")))
    }

    func testTimingOnlyUpdatesPreserveProjectedToolFormattingIdentity() throws {
        let session = ChatSession(id: UUID()), start = Date(timeIntervalSince1970: 1_750_000_000)
        let wrapper = ChatItem(id: "wrapper", kind: .tool,
                               text: #"text(await tools.exec_command({cmd:"echo hello"}));"#,
                               title: "exec", output: "hello", completed: true)
        session.turns = [ChatTurn(id: "one", started: start, items: [wrapper])]
        let first = try XCTUnwrap(session.transcriptRows.first?.item)
        XCTAssertEqual(first.title, "exec_command")
        session.turns[0].ended = start.addingTimeInterval(180)
        session.turns[0].started = start.addingTimeInterval(-10)
        session.turns[0].fileOffset = 42
        session.turns[0].invalidatePresentation()
        XCTAssertEqual(session.transcriptRows.first?.item?.presentationID, first.presentationID)
        XCTAssertEqual(session.transcriptRows.last?.workedFor, 190)

        session.turns[0].items[0].output = "changed output"
        XCTAssertNotEqual(session.transcriptRows.first?.item?.presentationID, first.presentationID)
        XCTAssertEqual(session.transcriptRows.first?.item?.output, "changed output")
    }
}
