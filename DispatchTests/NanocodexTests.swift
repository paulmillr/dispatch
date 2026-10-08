import Foundation
import XCTest
@testable import DispatchApp

@MainActor
final class NanocodexTests: XCTestCase {
    func testLiveEventsReconcileWithCommittedRolloutIncludingSteers() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/nanocodex-0.6.5.jsonl")
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let archive = try await chat.archived(url, agent: "nanocodex", session: "00000000-0000-7000-8000-000000000001")
        let helper = try XCTUnwrap(archive.helper), page = try await helper.page(earlier: nil)
        let live = chat.session(for: UUID())
        func rows(_ session: ChatSession) -> [String] {
            session.turns.flatMap(\.items).map { "\($0.kind.rawValue): " + ($0.kind == .tool ? $0.title + " → " + $0.output : $0.text) }
        }
        let expected = ["user: SLOW_RESPONSE tool check", "user: steer: keep it short", "tool: shell_command → unsupported call: shell_command", "assistant: Local fixture reply: steer: keep it short"]
        // Seed the four live rows, then apply the entire committed page. The old
        // archive-only assertion uses a set; archive records are not the live event stream.
        let records = try expected.map { row in
            try XCTUnwrap(page.records.first { record in
                "\(record.kind): " + (record.kind == "tool" ? record.title + " → " + record.output : record.text) == row
            })
        }
        chat.receiveHelper(.records(records + page.records.filter { $0.kind == "turn_ended" }), session: live)
        XCTAssertEqual(rows(live), expected)
        XCTAssertNotNil(live.turns.first?.ended)
        let turns = live.turns.map(\.id)
        chat.receiveHelper(.page(page), session: live)
        XCTAssertEqual(rows(live), expected)
        XCTAssertEqual(live.turns.map(\.id), turns)
        XCTAssertEqual(Set(rows(archive)), Set(expected))
        XCTAssertEqual(archive.model, "gpt-6-sol")
    }

    func testPendingReceiptsResolveByRequestIDAndRejectionsAreNotSent() throws {
        // Native receipt lookup/request-id matching is owned by the helper. Its common
        // outcome determines whether the app keeps the draft and may retry.
        let sent = HelperChat.Sent(written: true, may_have_sent: true, reason: nil)
        XCTAssertNoThrow(try sent.confirmed())
        for reason in ["rejected", "changed conversation"] {
            let refused = HelperChat.Sent(written: false, may_have_sent: false, reason: reason)
            do { try refused.confirmed(); XCTFail("A rejected prompt must fail") }
            catch let delivery as HelperChat.Delivery {
                XCTAssertFalse(ChatInputNotSent.deliveryUncertain(delivery, started: true))
                XCTAssertEqual(delivery.errorDescription, reason)
            }
        }
        let uncertain = HelperChat.Sent(written: false, may_have_sent: true, reason: "lost reply")
        do { try uncertain.confirmed(); XCTFail("An unconfirmed prompt must not retry") }
        catch let delivery as HelperChat.Delivery {
            XCTAssertTrue(ChatInputNotSent.deliveryUncertain(delivery, started: true))
            XCTAssertEqual(delivery.errorDescription, "lost reply")
        }
    }
}
