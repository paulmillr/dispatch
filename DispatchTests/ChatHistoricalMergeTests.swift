import XCTest
@testable import DispatchApp

@MainActor
final class ChatHistoricalMergeTests: XCTestCase {
    private func session() -> ChatSession {
        ChatSession(id: UUID(), draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
    }

    private func record(_ key: String, turn: String = "turn", time: Double, offset: UInt64? = nil,
                        action: ChatRecord.Action, reviewing: Bool? = nil) -> ChatRecord {
        ChatRecord(key: key, turnID: turn, date: Date(timeIntervalSince1970: time), action: action,
                   fileOffset: offset, reviewing: reviewing)
    }

    private func assertSameHistory(_ actual: ChatSession, _ expected: ChatSession,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.turns.map(\.id), expected.turns.map(\.id), file: file, line: line)
        for (a, b) in zip(actual.turns, expected.turns) {
            XCTAssertEqual(a.started, b.started, file: file, line: line)
            XCTAssertEqual(a.ended, b.ended, file: file, line: line)
            XCTAssertEqual(a.fileOffset, b.fileOffset, file: file, line: line)
            XCTAssertEqual(a.items, b.items, file: file, line: line)
            XCTAssertEqual(a.items.map(\.rowID), b.items.map(\.rowID), file: file, line: line)
        }
        XCTAssertEqual(actual.itemDates, expected.itemDates, file: file, line: line)
        XCTAssertEqual(actual.itemOffsets, expected.itemOffsets, file: file, line: line)
        XCTAssertEqual(actual.seen, expected.seen, file: file, line: line)
    }

    func testBulkMergeMatchesIncrementalInsertionForShuffledUpdatesAndRepeatedPages() {
        let coordinator = ChatCoordinator(enabled: true)
        let actual = session(), expected = session()
        var seed: UInt64 = 0x1357_2468
        func next(_ limit: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(limit))
        }
        let kinds: [ChatItem.Kind] = [.user, .assistant, .reasoning, .tool, .notice]
        let records: [ChatRecord] = (0..<500).map { index in
            let id = (next(5) == 0 ? "pi-" : "item-") + String(next(30))
            let item = ChatItem(id: id, kind: kinds[next(kinds.count)], text: "text-\(next(8))",
                                title: next(2) == 0 ? "" : "tool", output: next(3) == 0 ? "result" : "",
                                completed: next(3) == 0)
            let action: ChatRecord.Action
            switch next(12) {
            case 0: action = .started
            case 1: action = .ended
            case 2: action = .compacted
            default: action = .item(item)
            }
            return record("record-\(index)", turn: "turn-\(next(5))", time: Double(next(8)),
                          offset: next(4) == 0 ? nil : UInt64(next(12)), action: action)
        }
        // Warm caches with live history, then prepend several batches. This
        // includes overlapping text/ID matches and equal ordering keys.
        for target in [actual, expected] {
            coordinator.apply(Array(records.prefix(50)), to: target, earlier: false, historical: false)
            _ = target.transcriptRows
        }
        for start in stride(from: 50, to: records.count, by: 75) {
            let batch = Array(records[start..<min(start + 75, records.count)])
            coordinator.apply(batch, to: expected, earlier: true, historical: false)
            coordinator.apply(batch, to: actual, earlier: true, historical: true)
            assertSameHistory(actual, expected)
            let revision = actual.revision
            coordinator.apply(batch, to: actual, earlier: true, historical: true)
            assertSameHistory(actual, expected)
            XCTAssertEqual(actual.revision, revision)
        }
    }

    func testTimestampCorrectionsRetainThePreviousStableTieOrder() {
        let coordinator = ChatCoordinator(enabled: true)
        let actual = session(), expected = session()
        let records: [ChatRecord] = [
            record("a", time: 10, action: .item(ChatItem(id: "a", kind: .tool, text: "a"))),
            record("b", time: 20, action: .item(ChatItem(id: "b", kind: .tool, text: "b"))),
            record("b-older", time: 5, action: .item(ChatItem(id: "b", kind: .tool, text: "b"))),
            record("a-older", time: 5, action: .item(ChatItem(id: "a", kind: .tool, text: "a"))),
            record("second", turn: "second", time: 20, action: .started),
            record("third", turn: "third", time: 30, action: .started),
            record("third-older", turn: "third", time: 5, action: .started),
            record("second-older", turn: "second", time: 5, action: .started),
        ]
        coordinator.apply(records, to: expected, earlier: true, historical: false)
        coordinator.apply(records, to: actual, earlier: true, historical: true)
        assertSameHistory(actual, expected)
        XCTAssertEqual(actual.turns.first?.items.map(\.id), ["b", "a"])
        XCTAssertEqual(actual.turns.map(\.id), ["turn", "third", "second"])
    }

    func testDirectSnapshotsWithMissingMetadataAndDuplicateIDsKeepIncrementalBehavior() {
        let coordinator = ChatCoordinator(enabled: true)
        for duplicateTurns in [false, true] {
            let actual = session(), expected = session()
            let snapshot = ChatTurn(id: "turn", started: Date(timeIntervalSince1970: 10), items: [
                ChatItem(id: "same", kind: .tool, text: "first"),
                ChatItem(id: "between", kind: .assistant, text: "reply"),
                ChatItem(id: "same", kind: .tool, text: "second"),
            ])
            for target in [actual, expected] { target.turns = duplicateTurns ? [snapshot, snapshot] : [snapshot] }
            let records: [ChatRecord] = (0..<36).map { index in
                let id = index % 4 == 0 ? "same" : "item-\(index % 7)"
                let kind: ChatItem.Kind = index % 2 == 0 ? .tool : .assistant
                let item = ChatItem(id: id, kind: kind, text: "text-\(index % 3)")
                let offset: UInt64? = index % 3 == 0 ? nil : UInt64(index * 3 % 7)
                return record("record-\(index)", time: Double(index * 7 % 19),
                              offset: offset, action: .item(item))
            }
            coordinator.apply(records, to: expected, earlier: true, historical: false)
            coordinator.apply(records, to: actual, earlier: true, historical: true)
            assertSameHistory(actual, expected)
        }
    }

    func testTextMatchingUsesTheFirstDisplayedMatchAndPreservesPiIdentitiesAndFinalContent() throws {
        let coordinator = ChatCoordinator(enabled: true)
        let actual = session(), expected = session()
        let records: [ChatRecord] = [
            record("a", time: 10, action: .item(ChatItem(id: "a", kind: .assistant, text: "Alpha"))),
            record("b", time: 20, action: .item(ChatItem(id: "b", kind: .assistant, text: "Beta"))),
            record("b-alpha", time: 20, action: .item(ChatItem(id: "b", kind: .assistant, text: "Alpha"))),
            record("a-beta", time: 5, action: .item(ChatItem(id: "a", kind: .assistant, text: "Beta"))),
            record("b-beta", time: 1, action: .item(ChatItem(id: "b", kind: .assistant, text: "Beta"))),
            record("pi-one", time: 30, action: .item(ChatItem(id: "pi-one", kind: .assistant, text: "Beta"))),
            record("pi-two", time: 31, action: .item(ChatItem(id: "pi-two", kind: .assistant, text: "Beta"))),
            record("final", time: 40, offset: 50, action: .item(ChatItem(id: "final", kind: .assistant,
                rowID: "accepted-row", text: "Complete reply", completed: true))),
            record("stale", time: 39, offset: 40, action: .item(ChatItem(id: "final", kind: .assistant, text: "Complete"))),
            record("tool-result", time: 42, action: .item(ChatItem(id: "tool", kind: .tool, text: "", output: "done", completed: true, exitCode: 0))),
            record("tool-call", time: 41, action: .item(ChatItem(id: "tool", kind: .tool, text: "echo done", title: "Shell"))),
        ]
        coordinator.apply(records, to: expected, earlier: true, historical: false)
        coordinator.apply(records, to: actual, earlier: true, historical: true)
        assertSameHistory(actual, expected)
        let items = try XCTUnwrap(actual.turns.first?.items)
        XCTAssertEqual(items.filter { $0.id.hasPrefix("pi-") }.count, 2)
        XCTAssertEqual(items.first { $0.id == "final" }?.text, "Complete reply")
        XCTAssertEqual(items.first { $0.id == "final" }?.rowID, "accepted-row")
        XCTAssertEqual(items.first { $0.id == "tool" }?.text, "echo done")
        XCTAssertEqual(items.first { $0.id == "tool" }?.output, "done")
    }

    func testInitialHistoricalBatchKeepsPromptActivityAndSettingsEventOrder() throws {
        let coordinator = ChatCoordinator(enabled: true)
        let actual = session(), expected = session()
        for target in [actual, expected] {
            target.active = true; target.awaitingPromptAck = true
            target.optimisticPrompt = ChatItem(id: "pending", kind: .user, text: "New prompt")
            target.promptBoundary = .local(Date(timeIntervalSince1970: 50))
        }
        let settings = try XCTUnwrap(ChatAgentSettings(["model": "new-model", "effort": "high", "service_tier": "fast",
            "collaboration_mode": ["mode": "plan"]]))
        let records: [ChatRecord] = [
            record("old-start", turn: "old", time: 10, action: .started, reviewing: true),
            record("old-user", turn: "old", time: 11, action: .item(ChatItem(id: "old-user", kind: .user, text: "New prompt"))),
            record("settings", time: 49, action: .settings(settings)),
            record("start", time: 50, action: .started, reviewing: false),
            record("user", time: 51, action: .item(ChatItem(id: "user", kind: .user, text: "New prompt"))),
            record("end", time: 60, action: .ended),
        ]
        coordinator.apply(records, to: expected, earlier: false, historical: false)
        coordinator.apply(records, to: actual, earlier: false, historical: true)
        assertSameHistory(actual, expected)
        XCTAssertNil(actual.optimisticPrompt)
        XCTAssertFalse(actual.awaitingPromptAck)
        XCTAssertFalse(actual.busy)
        XCTAssertEqual(actual.activeTurnID, "turn")
        XCTAssertEqual(actual.turns.last?.items.first?.rowID, "pending")
        XCTAssertEqual(actual.model, expected.model)
        XCTAssertEqual(actual.effort, expected.effort)
        XCTAssertEqual(actual.serviceTier, expected.serviceTier)
        XCTAssertEqual(actual.collaborationMode, expected.collaborationMode)
        XCTAssertEqual(actual.settingsRevision, expected.settingsRevision)
        XCTAssertEqual(actual.reviewing, expected.reviewing)
        XCTAssertEqual(actual.revision, 0, "Historical publication should not emit per-item live updates")
    }

    func testEarlierBatchDoesNotChangeLiveSettingsOrConsumeAnOptimisticPrompt() throws {
        let coordinator = ChatCoordinator(enabled: true)
        let target = session()
        target.model = "live-model"; target.reviewing = true
        target.activeTurnID = "live"; target.busy = true; target.awaitingPromptAck = true
        target.optimisticPrompt = ChatItem(id: "pending", kind: .user, text: "Repeated prompt")
        target.promptBoundary = .firstRemoteTurn
        let records: [ChatRecord] = [
            record("settings", time: 1, action: .configuration(model: "old-model", effort: nil), reviewing: false),
            record("metadata", time: 1, action: .metadata("session", "version")),
            record("start", time: 2, action: .started),
            record("user", time: 3, action: .item(ChatItem(id: "old-user", kind: .user, text: "Repeated prompt"))),
            record("end", time: 4, action: .ended),
        ]
        coordinator.apply(records, to: target, earlier: true, historical: true)
        XCTAssertEqual(target.model, "live-model")
        XCTAssertTrue(target.reviewing)
        XCTAssertEqual(target.version, "version")
        XCTAssertEqual(target.activeTurnID, "live")
        XCTAssertTrue(target.busy)
        XCTAssertTrue(target.awaitingPromptAck)
        XCTAssertEqual(target.optimisticPrompt?.id, "pending")
        XCTAssertEqual(target.turns.first?.ended, Date(timeIntervalSince1970: 4))
        XCTAssertNil(target.turns.first?.items.first?.rowID)
    }
}
