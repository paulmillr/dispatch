import Foundation
import XCTest
@testable import DispatchMobile

/// The phone's transcript: the Mac's merge, the thread's rows and the step caption ("5 steps · 1m 26s").
final class ChatTranscriptTests: XCTestCase {
    private func records(_ objects: [[String: Any]]) throws -> [HelperChat.Record] {
        try JSONDecoder().decode([HelperChat.Record].self, from: JSONSerialization.data(withJSONObject: objects))
    }

    func testElapsedTextMatchesTheMac() {
        XCTAssertEqual(ChatTurnSummary.elapsed(0), "0s")
        XCTAssertEqual(ChatTurnSummary.elapsed(52.9), "52s")
        XCTAssertEqual(ChatTurnSummary.elapsed(86), "1m 26s")
        XCTAssertEqual(ChatTurnSummary.elapsed(3600 + 5 * 60 + 9), "1h 5m")
    }

    func testCaptionCountsStepsAndTheTurnsDuration() {
        let tool = ChatItem(id: "t", kind: .tool, text: "{}", title: "Read")
        XCTAssertEqual(ChatTurnSummary(steps: [tool], duration: 52).caption, "1 step · 52s")
        XCTAssertEqual(ChatTurnSummary(steps: Array(repeating: tool, count: 5), duration: 86).caption, "5 steps · 1m 26s")
        XCTAssertEqual(ChatTurnSummary(steps: [], duration: 3).caption, "3s")
        XCTAssertNil(ChatTurnSummary(steps: [], duration: nil).caption)
    }

    func testATurnReadWithoutTimesHasNoDuration() throws {
        var transcript = MobileTranscript()
        transcript.apply(try records([
            ChatFixture.record("s", "turn_started", turn: "t1"),
            ChatFixture.record("u", "user", turn: "t1", text: "hi"),
            ChatFixture.record("a", "assistant", turn: "t1", text: "hello"),
            ChatFixture.record("e", "turn_ended", turn: "t1")]), historical: true)
        XCTAssertEqual(transcript.rows.map(\.kind.label), ["user", "agent"])
        XCTAssertNil(transcript.rows.last?.kind.summary?.duration)
        XCTAssertNil(transcript.rows.last?.kind.summary?.caption)
    }

    func testOnlyTheLastAgentMessageOfAnEndedTurnCarriesTheCaption() throws {
        var transcript = MobileTranscript()
        let all = try ChatFixture.records("claude-thread")
        // The first turn without its end: still live, so no caption yet.
        let live = all.filter { $0["id"] as? String != "f1:ended" && $0["turn"] as? String == "p1" }
        transcript.apply(try records(live), historical: true)
        XCTAssertEqual(transcript.rows.compactMap(\.kind.summary), [])
        XCTAssertEqual(transcript.openTurn?.id, "p1", "A conversation opened mid-turn shows that turn as live")
        transcript.apply(try records(all), historical: false)
        XCTAssertEqual(transcript.rows.compactMap(\.kind.summary?.caption), ["5 steps · 1m 26s", "4 steps · 52s"])
        XCTAssertEqual(transcript.rows.count, 4, "Re-applied records merge; nothing doubles")
        XCTAssertEqual(transcript.lastAgentItem?.id, "claude-f2-0")
        XCTAssertEqual(transcript.lastActivity, Date(timeIntervalSince1970: 946_719_172))
    }

    func testAWrapperThatOnlyRepeatsItsPatchIsOneStep() {
        let diff = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
        var patch = ChatItem(id: "p", kind: .tool, text: "*** Begin Patch\n*** Update File: x\n@@\n-a\n+b\n*** End Patch", title: "apply_patch")
        patch.patch = ChatPatch(documents: [ToolDocument(path: "x", diff: diff, workingDirectory: nil)], state: .completed)
        let wrapper = ChatItem(id: "w", kind: .tool, text: patch.text, title: "shell")
        let shown = ChatTurnSummary.displayed([wrapper, patch], turnID: "t")
        XCTAssertLessThanOrEqual(shown.count, 2)
        XCTAssertEqual(shown.last?.id, "p")
    }
}
