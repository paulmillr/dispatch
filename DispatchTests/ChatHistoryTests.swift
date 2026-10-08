import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ChatHistoryTests: XCTestCase {
    private let sessionID = "11111111-1111-4111-8111-111111111111"
    private func line(_ type: String, _ payload: [String: Any], time: Int = 0) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2000-01-01T00:\(String(format: "%02d", time / 60 % 60)):\(String(format: "%02d", time % 60)).000Z", "payload": payload], options: [.sortedKeys])
        data.append(10); return data
    }
    private func transcript(turns: Int) throws -> (URL, Data) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-history-" + UUID().uuidString + ".jsonl")
        var data = try line("session_meta", ["id": sessionID, "cli_version": "0.153.4"])
        for index in 0..<turns {
            data += try turn(index)
        }
        try data.write(to: path)
        return (path, data)
    }
    private func turn(_ index: Int) throws -> Data {
        let id = "turn-\(index)"
        return try line("event_msg", ["type": "task_started", "turn_id": id], time: index) +
            line("event_msg", ["type": "user_message", "turn_id": id, "message": "Question \(index)"], time: index) +
            line("response_item", ["type": "function_call", "call_id": "call-\(index)", "name": "exec_command", "arguments": "{\"cmd\":\"echo \(index)\"}"], time: index) +
            line("response_item", ["type": "function_call_output", "call_id": "call-\(index)", "output": String(repeating: "line of output\n", count: 100)], time: index) +
            line("event_msg", ["type": "agent_message", "turn_id": id, "message": "Answer \(index)"], time: index) +
            line("event_msg", ["type": "task_complete", "turn_id": id], time: index)
    }

    /// A Codex transcript file opened as an archived chat, and every earlier page loaded.
    private func archived(_ data: Data) async throws -> (ChatCoordinator, ChatSession) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-history-" + UUID().uuidString + ".jsonl")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        addTeardownBlock { chat.stop() }
        return (chat, try await chat.archived(url, agent: "codex", session: sessionID))
    }
    private func answers(_ session: ChatSession) -> [String] {
        session.turns.flatMap(\.items).filter { $0.kind == .assistant }.map(\.text)
    }
    private func loadAll(_ session: ChatSession, _ chat: ChatCoordinator, pages: Int = 50) async throws -> Int {
        var loaded = 0
        for _ in 0..<pages where session.hasEarlier { _ = try await chat.earlier(session); loaded += 1 }
        XCTAssertFalse(session.hasEarlier)
        return loaded
    }

    func testRecentPageArrivesFirstAndOlderPagesDoNotMoveLiveCursor() async throws {
        let (path, data) = try transcript(turns: 1_000)
        try? FileManager.default.removeItem(at: path)
        let (chat, session) = try await archived(data)
        XCTAssertTrue(session.hasEarlier)
        XCTAssertTrue(answers(session).contains("Answer 999"))
        XCTAssertFalse(answers(session).contains("Answer 0"))
        _ = try await loadAll(session, chat)
        XCTAssertEqual(answers(session).count, 1_000, "Every older message stays reachable")
        XCTAssertEqual(Set(answers(session)).count, 1_000, "Pages never replay a line")
    }

    func testReadableHistoryBatchesRemainBoundedAndPreserveEveryRecord() async throws {
        let (path, data) = try transcript(turns: 250)
        try? FileManager.default.removeItem(at: path)
        let (chat, session) = try await archived(data)
        var keys = Set(session.turns.flatMap(\.items).map(\.id))
        for _ in 0..<20 where session.hasEarlier {
            let page = try await XCTUnwrap(session.helper).page(earlier: session.helperEarlier)
            XCTAssertLessThanOrEqual(page.records.count, 600, "Old history contract: at most three 200-record pages per batch")
            for item in page.records.compactMap(\.display) {
                if case .item(let value) = item.action { XCTAssertTrue(keys.insert(value.id).inserted) }
            }
            // The same helper cursor is consumed by the shipping app's paging path.
            _ = try await chat.earlier(session)
        }
        XCTAssertFalse(session.hasEarlier)
        XCTAssertEqual(answers(session), (0..<250).map { "Answer \($0)" })
    }

    func testPartialTailAndReplacementInvalidateOldPageRequests() async throws {
        let (path, data) = try transcript(turns: 100)
        defer { try? FileManager.default.removeItem(at: path) }
        let next = try turn(100)
        try (data + next.prefix(next.count - 20)).write(to: path)
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let session = try await chat.archived(path, agent: "codex", session: sessionID)
        let helper = try XCTUnwrap(session.helper), cursor = try XCTUnwrap(session.helperEarlier)
        let writer = try FileHandle(forWritingTo: path)
        try writer.seekToEnd(); try writer.write(contentsOf: next.suffix(20)); try writer.close()
        try await TestSupport.eventually { self.answers(session).contains("Answer 100") }
        XCTAssertEqual(answers(session).filter { $0 == "Answer 100" }.count, 1)
        try data.write(to: path, options: .atomic)
        do {
            let stale = try await helper.page(earlier: cursor)
            XCTAssertTrue(stale.records.isEmpty, "A replaced file cannot answer the old cursor")
        } catch let error as HelperFailure {
            XCTAssertEqual(error.code, "history", "A replaced file invalidates its old history cursor")
        }
        try await TestSupport.eventually { self.answers(session).contains("Answer 99") && !self.answers(session).contains("Answer 100") }
    }

    private func record(_ kind: String, _ id: String, turn: String = "running", text: String = "") -> HelperChat.Record {
        .init(id: id, turn: turn, kind: kind, text: text, title: "", output: "", blocks: [],
              completed: true, exit_code: nil, patch: nil, time_ms: nil, documents: [], tool: nil, inline_reasoning: false)
    }

    private func state(_ busy: Bool, model: String? = nil) -> HelperChat.State {
        .init(busy: busy, activity: nil, model: model, model_label: nil, effort: nil, usage: nil,
              goal: nil, draft: nil, attention: nil, title: nil, compacting: false, service_tier: nil)
    }

    private func activity() -> (ChatCoordinator, ChatSession) {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.helper = HelperChat(terminal: 0); session.sessionID = sessionID
        addTeardownBlock { @MainActor in chat.stop() }
        chat.receiveHelper(.records([record("turn_started", "start")]), session: session)
        chat.receiveHelper(.state(state(true)), session: session)
        return (chat, session)
    }

    /// A history page without record times dates them at the epoch (Pi's live events still send 0).
    /// A running turn it introduces counts from when the activity appeared and finishes on that clock;
    /// a live end gives no "worked for" duration measured from 1970.
    func testUntimedHistoryTurnIsNotTimedFromTheEpoch() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.helper = HelperChat(terminal: 0); session.sessionID = sessionID
        addTeardownBlock { @MainActor in chat.stop() }
        chat.receiveHelper(.history(.init(terminal: 0,
            binding: .init(session: sessionID, transcript: nil, pid: nil, start: nil, executable: nil),
            session: sessionID, key: "codex", label: "Codex", commands: [], native_queue: false,
            state: state(true), state_error: nil, records: [record("turn_started", "start"), record("user", "prompt", text: "Hi")],
            earlier: nil, history_error: nil, history_pending: false, capabilities: [])), session: session)
        let running = AgentWorkingState(session), appeared = Date()
        XCTAssertTrue(running.visible)
        XCTAssertEqual(AgentWorkingAnimation.timeText(running, now: appeared.addingTimeInterval(7), appeared: appeared), "7s")
        chat.receiveHelper(.records([record("turn_ended", "end")]), session: session)
        let ended = try XCTUnwrap(session.turns.last?.ended)
        let finished = running.finished(at: ended, label: "Finished", receivedAt: appeared.addingTimeInterval(9))
        XCTAssertEqual(AgentWorkingAnimation.timeText(finished, now: appeared.addingTimeInterval(10), appeared: appeared), "9s")
        XCTAssertFalse(session.visibleTranscriptRows.contains { $0.workedFor != nil })
    }

    func testActivityLookupDoesNotInheritAnEarlierReview() {
        let (chat, session) = activity()
        chat.receiveHelper(.records([record("turn_ended", "review-end"),
            record("turn_started", "later-start", turn: "later"),
            record("turn_ended", "later-end", turn: "later")]), session: session)
        chat.receiveHelper(.state(state(false)), session: session)
        XCTAssertEqual(session.activeTurnID, "later")
        XCTAssertFalse(session.busy)
        XCTAssertFalse(AgentWorkingState(session).visible)
    }

    func testReconnectRecoversActivityWithoutReplayingTurnStart() {
        for completed in [false, true] {
            let (chat, session) = activity()
            let rows = session.turns.map(\.id)
            session.busy = false
            chat.receiveHelper(.state(state(!completed)), session: session)
            XCTAssertEqual(session.busy, !completed)
            XCTAssertEqual(session.activeTurnID, "running")
            XCTAssertEqual(AgentWorkingState(session).visible, !completed)
            XCTAssertEqual(session.turns.map(\.id), rows, "Reconnect state cannot replay history")
        }
    }

    func testFreshRepliesHealIdleActivityAndLateOutputDoesNotReviveCompletedTurn() {
        let (chat, session) = activity()
        session.busy = false
        chat.receiveHelper(.records([record("assistant", "working", text: "Still working")]), session: session)
        chat.receiveHelper(.state(state(true)), session: session)
        XCTAssertTrue(session.busy); XCTAssertTrue(AgentWorkingState(session).visible)
        chat.receiveHelper(.records([record("turn_ended", "end")]), session: session)
        chat.receiveHelper(.state(state(false)), session: session)
        chat.receiveHelper(.records([record("assistant", "done", text: "Done")]), session: session)
        XCTAssertFalse(session.busy); XCTAssertFalse(AgentWorkingState(session).visible)
        XCTAssertEqual(answers(session), ["Still working", "Done"])
    }

    func testActivityRecoveryRetriesTransientFailureAndIgnoresStaleCompletion() {
        let (chat, session) = activity()
        let rows = session.turns.map(\.id)
        session.status = "Transcript temporarily unavailable"
        session.busy = false
        chat.receiveHelper(.history(.init(terminal: 0,
            binding: .init(session: sessionID, transcript: nil, pid: nil, start: nil, executable: nil),
            session: sessionID, key: "fixture", label: "Fixture", commands: [], native_queue: false,
            state: state(true), state_error: nil, records: [], earlier: nil, history_error: nil,
            history_pending: false, capabilities: [])), session: session)
        XCTAssertNil(session.status)
        XCTAssertTrue(session.busy)
        chat.receiveHelper(.records([record("turn_ended", "new-end")]), session: session)
        chat.receiveHelper(.state(state(false)), session: session)
        // Replayed records from the retained cursor cannot restart the completed turn.
        chat.receiveHelper(.records([record("turn_started", "start")]), session: session)
        XCTAssertFalse(session.busy)
        XCTAssertNil(session.activityCheck)
        XCTAssertEqual(session.turns.map(\.id), rows)
    }

    func testOnlyIdentifiedConversationsWaitForInitialHistoryBeforeInput() {
        for identity in ["", sessionID] {
            let (chat, session) = activity()
            session.sessionID = nil
            for pending in [true, false] {
                chat.receiveHelper(.history(.init(terminal: 0,
                    binding: .init(session: identity, transcript: nil, pid: nil, start: nil, executable: nil),
                    session: identity, key: "codex", label: "Codex", commands: [], native_queue: false,
                    state: state(false), state_error: nil, records: [], earlier: nil, history_error: nil,
                    history_pending: pending, capabilities: [])), session: session)
                XCTAssertEqual([session.loadingHistory, chat.inputReady(session)],
                    [pending && !identity.isEmpty, !pending || identity.isEmpty])
            }
        }
    }

    func testModelNamesTheBoundAgentUntilItReportsOne() {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.helper = HelperChat(terminal: 0)
        addTeardownBlock { @MainActor in chat.stop() }
        func bind(_ key: String, _ label: String, _ conversation: String, model: String? = nil) {
            chat.receiveHelper(.history(.init(terminal: 0,
                binding: .init(session: conversation, transcript: nil, pid: nil, start: nil, executable: nil),
                session: conversation, key: key, label: label, commands: [], native_queue: false,
                state: state(false, model: model), state_error: nil, records: [], earlier: nil, history_error: nil,
                history_pending: false, capabilities: [])), session: session)
        }
        // A freshly launched agent reports no model before its first reply.
        bind("claude", "Claude Code", "")
        XCTAssertEqual(session.model, "Claude Code")
        bind("codex", "Codex", "codex-conversation", model: "gpt-6-astra")
        XCTAssertEqual(session.model, "gpt-6-astra")
        // Another agent's conversation in the same terminal neither keeps that model nor names the previous agent.
        bind("claude", "Claude Code", "claude-conversation")
        XCTAssertEqual(session.model, "Claude Code")
    }

    func testToolDenseInitialHistoryIncludesMoreRepliesWhileEarlierPagesStayBounded() async throws {
        var data = try line("session_meta", ["id": sessionID])
        for turn in 0..<40 {
            let id = "turn-\(turn)"
            data += try line("event_msg", ["type": "task_started", "turn_id": id])
            data += try line("event_msg", ["type": "user_message", "turn_id": id, "message": "Question \(turn)"])
            for tool in 0..<20 {
                let call = "\(turn)-\(tool)"
                data += try line("response_item", ["type": "function_call", "turn_id": id, "call_id": call,
                    "name": "exec_command", "arguments": "echo \(call)"])
                data += try line("response_item", ["type": "function_call_output", "turn_id": id, "call_id": call, "output": call])
            }
            data += try line("event_msg", ["type": "agent_message", "turn_id": id, "message": "Answer \(turn)"])
            data += try line("event_msg", ["type": "task_complete", "turn_id": id])
        }
        let (chat, session) = try await archived(data)
        XCTAssertTrue(session.hasEarlier)
        XCTAssertTrue(answers(session).contains("Answer 39"))
        // 400 records (44 per turn) on the first page: 9 complete replies, twice an ordinary 200-record page.
        XCTAssertGreaterThanOrEqual(answers(session).count, 9, "Twenty tools per turn must not leave only a few recent replies")
        _ = try await loadAll(session, chat)
        XCTAssertEqual(answers(session), (0..<40).map { "Answer \($0)" })
        let tools = session.turns.flatMap(\.items).filter { $0.kind == .tool }
        XCTAssertEqual(Set(tools.map(\.id)).count, 800)
    }

    func testInitialHistoryHasLargerByteBudgetWithoutChangingEarlierByteBudget() async throws {
        var data = try line("session_meta", ["id": sessionID]), size = 0
        let output = String(repeating: "x", count: 160 * 1024)
        for index in 0..<40 {
            let record = try line("response_item", ["type": "function_call_output", "turn_id": "large-output",
                "call_id": "call-\(index)", "output": output])
            size = max(size, record.count)
            data += record
        }
        // A page ends at the record that crosses its byte budget: 4 MiB first, 2 MiB for earlier pages.
        func records(_ budget: Int) -> Int { (budget + size - 1) / size }
        let (chat, session) = try await archived(data)
        XCTAssertTrue(session.hasEarlier)
        let first = session.turns.flatMap(\.items).count
        XCTAssertEqual(first, records(4 * 1024 * 1024))
        _ = try await chat.earlier(session)
        XCTAssertEqual(session.turns.flatMap(\.items).count - first, records(2 * 1024 * 1024), "Earlier history keeps the smaller byte budget")
        XCTAssertEqual(Set(session.turns.flatMap(\.items).map(\.id)).count, session.turns.flatMap(\.items).count)
    }

    func testReversePagesCrossBlockBoundariesAndSkipMalformedOversizedRecords() async throws {
        let (path, original) = try transcript(turns: 100)
        try? FileManager.default.removeItem(at: path)
        let output = String(repeating: "0123456789\n", count: 210_000)
        var data = original
        data += Data("malformed\n".utf8)
        data += try line("future_record", ["type": "unknown", "turn_id": "turn-99"])
        data += Data(repeating: 120, count: 4_194_305); data.append(10)
        data += try line("response_item", ["type": "function_call_output", "turn_id": "turn-99", "call_id": "large", "output": output])
        let (chat, session) = try await archived(data)
        XCTAssertTrue(session.hasEarlier)
        XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.output == output }, "A full record may cross both the block and page byte boundaries")
        XCTAssertFalse(session.busy, "Unknown and oversized records must not hide completed activity")
        _ = try await loadAll(session, chat, pages: 10)
        XCTAssertEqual(Set(answers(session)).count, 100)
    }

    func testRecentPagingOfRealCodexResumeHistoryFromLocalEndpoint() async throws {
        let binary = try CodexTestSupport.requireBinary()
        let turnCount = 60
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-real-history-" + UUID().uuidString)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/seed-codex-history.py").path, "--state", state.path, "--turns", String(turnCount), "--codex", binary]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; try? FileManager.default.removeItem(at: state) }
        try await TestSupport.eventually(timeout: .seconds(60), interval: .milliseconds(50),
                                         diagnostic: "Local Codex history generation timed out") { !process.isRunning }
        XCTAssertEqual(process.terminationStatus, 0)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent("history.json"))) as? [String: Any])
        let id = try XCTUnwrap(info["session_id"] as? String), path = try XCTUnwrap(info["transcript_path"] as? String)
        XCTAssertEqual(info["requests"] as? Int, turnCount)
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let session = try await chat.archived(URL(fileURLWithPath: path), agent: "codex", session: id)
        func replies() -> Set<String> { Set(answers(session).filter { $0.hasPrefix("Local fixture reply:") }) }
        XCTAssertTrue(session.hasEarlier)
        XCTAssertTrue(replies().contains("Local fixture reply: history message \(turnCount - 1)"))
        XCTAssertFalse(replies().contains("Local fixture reply: history message 0"))
        _ = try await loadAll(session, chat, pages: 10)
        XCTAssertEqual(replies().count, turnCount)
        let requests = try String(contentsOf: state.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(requests.count, turnCount, "Loading existing history must not request model responses")
    }

    func testTranscriptKeysAndTimestampCompatibility() throws {
        XCTAssertEqual(ChatRecord.contentKey(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ChatRecord.contentKey(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testHistoricalInsertionAndMergeKeepStableOrder() {
        let session = ChatSession(id: UUID()), date = Date(timeIntervalSince1970: 100)
        for (id, offset) in [("c", 30), ("a", 10), ("b", 20)] {
            session.insert(ChatItem(id: id, kind: .tool, text: id), turnID: "turn", at: date,
                           historical: true, fileOffset: UInt64(offset))
        }
        XCTAssertEqual(session.turns[0].items.map(\.id), ["a", "b", "c"])
        session.insert(ChatItem(id: "c", kind: .tool, text: "", output: "done", completed: true),
                       turnID: "turn", at: date, historical: true, fileOffset: 40)
        XCTAssertEqual(session.turns[0].items.map(\.id), ["a", "b", "c"])
        session.insert(ChatItem(id: "c", kind: .tool, text: ""), turnID: "turn", at: date,
                       historical: true, fileOffset: 5)
        XCTAssertEqual(session.turns[0].items.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(session.turns[0].items[0].output, "done")
        _ = session.turn("later", at: date, fileOffset: 80)
        _ = session.turn("earlier", at: date, fileOffset: 1)
        XCTAssertEqual(session.turns.map(\.id), ["earlier", "turn", "later"])
        _ = session.turn("later", at: date.addingTimeInterval(-1), fileOffset: 80)
        XCTAssertEqual(session.turns.map(\.id), ["later", "earlier", "turn"])
    }

    func testPagesThroughOneLargeLegacyTurnKeepToolContextAndOutputs() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-history-legacy-" + UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        var data = try line("session_meta", ["id": sessionID, "cli_version": "0.153.2"])
        data += try line("event_msg", ["type": "task_started", "turn_id": "one-long-turn"])
        for index in 0..<250 {
            data += try line("response_item", ["type": "function_call", "call_id": "call-\(index)", "name": "exec_command", "arguments": "echo \(index)"])
            data += try line("response_item", ["type": "function_call_output", "call_id": "call-\(index)", "output": "Result \(index)"])
        }
        // No trailing task_complete: the only turn ID is before the recent page.
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        let root = path.deletingLastPathComponent().appendingPathComponent("dispatch-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let session = try await chat.archived(lines, agent: "codex", session: sessionID, in: root)
        for _ in 0..<5 where session.hasEarlier {
            chat.loadEarlier(session)
            try await TestSupport.eventually { !session.loadingEarlier }
        }
        XCTAssertFalse(session.hasEarlier)
        XCTAssertEqual(session.turns.count, 1)
        XCTAssertEqual(session.turns[0].items.count, 250)
        XCTAssertEqual(session.turns[0].items.map(\.id), (0..<250).map { "tool-call-\($0)" }, "Equal timestamps must retain file order across backwards pages")
        XCTAssertTrue(session.turns[0].items.allSatisfy { !$0.text.isEmpty && !$0.output.isEmpty && $0.completed })
    }

    func testPrependingToolsKeepsTheExistingGroupIdentity() {
        let session = ChatSession(id: UUID())
        let a = ChatItem(id: "a", kind: .tool, text: "first"), b = ChatItem(id: "b", kind: .tool, text: "second")
        session.insert(a, turnID: "turn", at: Date(timeIntervalSince1970: 10))
        session.insert(b, turnID: "turn", at: Date(timeIntervalSince1970: 20))
        let groupID = session.transcriptRows[0].id
        session.expandedToolGroups.insert(groupID)
        session.insert(ChatItem(id: "older", kind: .tool, text: "older"), turnID: "turn", at: Date(timeIntervalSince1970: 5), historical: true)
        XCTAssertEqual(session.transcriptRows[0].id, groupID)
        XCTAssertEqual(session.visibleTranscriptRows.count, 4)
    }

    func testPrependingToolsKeepsAnExpandedStandaloneToolVisible() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-history-group-" + UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        var data = try line("session_meta", ["id": sessionID, "cli_version": "0.154.0"])
        data += try line("event_msg", ["type": "task_started", "turn_id": "long-turn"])
        for id in ["older", "recent"] {
            data += try line("response_item", ["type": "function_call", "call_id": id, "name": "exec_command", "arguments": "echo result"])
            data += try line("response_item", ["type": "function_call_output", "call_id": id, "output": "Result"])
        }
        // Place the recent tool at the page boundary, with no later message
        // available as a fallback anchor when its output fills the viewport.
        // The harness's first history page holds 400 records.
        for _ in 0..<(400 - 2) {
            data += try line("event_msg", ["type": "token_count"])
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        let root = path.deletingLastPathComponent().appendingPathComponent("dispatch-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { coordinator.stop() }
        let session = try await coordinator.archived(lines, agent: "codex", session: sessionID, in: root)
        let row = try XCTUnwrap(session.visibleTranscriptRows.first)
        XCTAssertEqual(session.visibleTranscriptRows.count, 1)
        XCTAssertEqual(row.item?.id, "tool-recent")
        session.expanded.insert(row.id)
        coordinator.loadEarlier(session)
        try await eventually { !session.loadingEarlier }
        XCTAssertTrue(session.visibleTranscriptRows.contains { $0.id == row.id })
        XCTAssertTrue(session.expanded.contains(row.id))
        XCTAssertEqual(session.expandedToolGroups.count, 1)
    }

    func testOpeningTallChatAutomaticallyPreloadsCollapsedHistoryAndKeepsLatestReplyVisible() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-opening-dense-" + UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let totalTurns = 40
        var data = try line("session_meta", ["id": sessionID])
        for turn in 0..<totalTurns {
            let id = "turn-\(turn)"
            data += try line("event_msg", ["type": "task_started", "turn_id": id])
            data += try line("event_msg", ["type": "user_message", "turn_id": id, "message": "Question \(turn)"])
            for tool in 0..<60 {
                let call = "\(turn)-\(tool)"
                data += try line("response_item", ["type": "function_call", "turn_id": id, "call_id": call,
                    "name": "exec_command", "arguments": "echo \(call)"])
                data += try line("response_item", ["type": "function_call_output", "turn_id": id, "call_id": call, "output": "done"])
            }
            data += try line("event_msg", ["type": "agent_message", "turn_id": id, "message": "Answer \(turn)"])
            data += try line("event_msg", ["type": "task_complete", "turn_id": id])
        }
        let root = path.deletingLastPathComponent().appendingPathComponent("dispatch-opening-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { coordinator.stop() }
        let session = try await coordinator.archived(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init),
                                                     agent: "codex", session: sessionID, in: root)
        session.showChat = true
        XCTAssertNil(session.status); XCTAssertTrue(session.hasEarlier)
        let initialTurnCount = session.turns.count, initialHistoryRevision = session.historyRevision
        XCTAssertLessThanOrEqual(initialTurnCount, 4, "The initial raw-record budget should leave a short collapsed transcript")
        XCTAssertTrue(session.visibleTranscriptRows.contains { $0.group != nil })
        XCTAssertTrue(session.visibleTranscriptRows.allSatisfy { row in
            row.group.map { !session.groupIsExpanded($0, turnID: row.turnID) } ?? true
        })
        let latestRowID = try XCTUnwrap(session.visibleTranscriptRows.last { $0.item?.text == "Answer 39" }?.id)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let hosting = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        // This deliberately sends no wheel events and makes no explicit history
        // requests: ChatTranscriptView.onAppear must start the real reader.
        try await eventually { session.turns.count > initialTurnCount }
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: hosting)
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        try await eventually {
            let atLimit = session.historyRevision - initialHistoryRevision >= 4
            let filledReserve = scroll.contentView.bounds.minY >= session.scrollPosition.earlierPrefetchDistance
            return !session.loadingEarlier && (atLimit || filledReserve)
                && session.scrollPosition.isAtBottom(tolerance: 2) == true
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(session.earlierError)
        XCTAssertGreaterThan(session.historyRevision, initialHistoryRevision)
        XCTAssertLessThanOrEqual(session.historyRevision - initialHistoryRevision, 4,
            "Opening must keep the four accepted-load bound even when tools collapse into short rows")
        XCTAssertLessThan(session.turns.count, totalTurns)
        XCTAssertTrue(session.hasEarlier)
        XCTAssertTrue(session.atBottom)
        XCTAssertEqual(session.scrollPosition.isAtBottom(tolerance: 2), true)
        XCTAssertFalse(session.hasNewMessages)
        let document = try XCTUnwrap(scroll.documentView)
        let latestMarker = try XCTUnwrap(PresentationTestSupport.views(of: ChatScrollMarker.Marker.self, in: document)
            .first { $0.id == latestRowID })
        XCTAssertTrue(latestMarker.convert(latestMarker.bounds, to: document).intersects(scroll.contentView.bounds),
            "Opening history must leave the latest reply in the native viewport")
    }

    func testFindSearchesEarlierHistoryAndRevealsItsMatch() async throws {
        try await findEarlier(following: true)
    }

    func testFindSearchesEarlierHistoryWhileReading() async throws {
        try await findEarlier(following: false)
    }

    private func findEarlier(following: Bool) async throws {
        AppFont.register()
        let (path, _) = try transcript(turns: 1_000)
        defer { try? FileManager.default.removeItem(at: path) }
        let coordinator = ChatCoordinator(enabled: false)
        let session = coordinator.session(for: UUID())
        session.sessionID = sessionID; session.transcriptPath = path.path; session.showChat = true
        coordinator.start(); defer { coordinator.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator,
            focused: false, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await eventually { session.hasEarlier && !session.turns.isEmpty && !session.loadingEarlier && !session.scrollPosition.isRestoring }
        XCTAssertFalse(session.turns.flatMap(\.items).contains { $0.text == "Answer 0" })
        if !following {
            let root = try XCTUnwrap(window.contentView)
            let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: root).max {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            })
            let document = try XCTUnwrap(scroll.documentView)
            session.atBottom = false; session.followRevision = nil
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height / 2))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        session.search.open(); session.search.query = "Answer 0"
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "turns=\(session.turns.count) earlier=\(session.hasEarlier) loading=\(session.loadingEarlier) restoring=\(session.scrollPosition.isRestoring) total=\(String(describing: session.search.total)) status=\(session.search.status ?? "none")") {
            !session.hasEarlier && session.search.total == 1 && session.search.status == nil
        }
        session.search.move(1)
        try await eventually { session.searchMatch != nil }
        XCTAssertEqual(session.searchMatch?.document.text, "Answer 0")
        try await eventually { session.scrollPosition.visibleAnchor()?.id == session.searchMatch?.document.row }
        let capture = try await PresentationTestSupport.capture(window, named: "find-earlier-history")
        // macOS 27 Vision can read the rendered zero as the letter O.
        try PresentationTestSupport.assertText("Answer 0", ["Answer O"], in: capture)
        session.search.close()
        try await eventually { session.searchMatches.isEmpty }
        session.earlierError = "Could not read earlier messages."
        session.search.open()
        try await eventually { session.search.status == "Search incomplete: Could not read earlier messages." }
    }

    func testNativePagingPreservesPixelOffsetAndSeparatesNewMessages() async throws {
        AppFont.register()
        let (path, _) = try transcript(turns: 1_000)
        defer { try? FileManager.default.removeItem(at: path) }
        let coordinator = ChatCoordinator(enabled: false)
        let session = coordinator.session(for: UUID())
        session.sessionID = sessionID; session.transcriptPath = path.path; session.showChat = true
        coordinator.start(); defer { coordinator.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        func mount() {
            window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false)
                .foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
            window.makeKeyAndOrderFront(nil)
        }
        var geometry: [ChatViewportTrace.Sample] = []
        session.scrollPosition.diagnosticSink = {
            if geometry.count == 64 { geometry.removeFirst() }
            geometry.append($0)
        }
        defer {
            session.scrollPosition.diagnosticSink = nil
            if let data = try? JSONEncoder().encode(geometry) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "native-paging-geometry"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        mount()
        try await eventually { session.hasEarlier && !session.turns.isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.text == "Answer 999" })
        XCTAssertLessThan(session.turns.count, 1_000, "Opening should leave history for the explicit prepend checks")
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: try XCTUnwrap(window.contentView)).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        XCTAssertTrue(session.atBottom)
        // Use a position within a row, away from the automatic prefetch threshold.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700)); scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(250))
        session.atBottom = false
        let anchor = try XCTUnwrap(session.scrollPosition.visibleAnchor())
        session.scrollPosition.recordDiagnostic(.transcript, force: true)
        print("Paging before: \(anchor); geometry=\(String(decoding: try JSONEncoder().encode(geometry.last), as: UTF8.self))")
        let turnCount = session.turns.count
        coordinator.loadEarlier(session)
        coordinator.loadEarlier(session) // only one request may be in flight
        try await eventually { session.turns.count > turnCount && !session.loadingEarlier }
        try await Task.sleep(for: .milliseconds(350))
        let restored = try XCTUnwrap(session.scrollPosition.visibleAnchor())
        session.scrollPosition.recordDiagnostic(.transcript, force: true)
        print("Paging after: \(restored); geometry=\(String(decoding: try JSONEncoder().encode(geometry.last), as: UTF8.self))")
        XCTAssertEqual(restored.id, anchor.id)
        XCTAssertEqual(restored.offset, anchor.offset, accuracy: 1, "Prepending must preserve the position inside the visible row")
        XCTAssertFalse(session.hasNewMessages)
        // A page can finish reading while the scrollbar thumb is still held.
        // Publish it only when tracking ends, at the final reading position.
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .legacy
        let bar = try XCTUnwrap(scroll.verticalScroller)
        let point = scroll.convert(NSPoint(x: bar.frame.midX, y: bar.frame.midY), to: nil)
        session.scrollPosition.handleScrollEvent(try PresentationTestSupport.mouseEvent(.leftMouseDown, in: window, at: point))
        XCTAssertTrue(session.scrollPosition.isTrackingScroller)
        let beforeDrag = session.turns.count
        coordinator.loadEarlier(session)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(session.loadingEarlier)
        XCTAssertEqual(session.turns.count, beforeDrag)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1150)); scroll.reflectScrolledClipView(scroll.contentView)
        // Lazy rows at the new position are registered on the next layout pass.
        try await eventually { session.scrollPosition.visibleAnchor() != nil }
        let dragAnchor = try XCTUnwrap(session.scrollPosition.visibleAnchor())
        session.scrollPosition.handleScrollEvent(try PresentationTestSupport.mouseEvent(.leftMouseUp, in: window, at: point))
        try await eventually { session.turns.count > beforeDrag && !session.loadingEarlier }
        try await Task.sleep(for: .milliseconds(200))
        let afterDrag = try XCTUnwrap(session.scrollPosition.visibleAnchor())
        XCTAssertEqual(afterDrag.id, dragAnchor.id)
        XCTAssertEqual(afterDrag.offset, dragAnchor.offset, accuracy: 1)
        // Reading old records must not change the current live turn's status.
        session.busy = true; session.activeTurnID = "current-live"
        coordinator.loadEarlier(session)
        try await eventually { !session.loadingEarlier }
        XCTAssertTrue(session.busy); XCTAssertEqual(session.activeTurnID, "current-live")
        session.active = false // this test has no terminal process
        session.insert(ChatItem(id: "live", kind: .assistant, text: "A new live message"), turnID: "latest", at: Date())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(session.hasNewMessages); XCTAssertFalse(session.atBottom)
        let beforeSwitch = try XCTUnwrap(session.scrollPosition.visibleAnchor())
        window.contentView = nil
        mount()
        try await Task.sleep(for: .milliseconds(350))
        let afterSwitch = try XCTUnwrap(session.scrollPosition.visibleAnchor())
        XCTAssertEqual(afterSwitch.id, beforeSwitch.id)
        XCTAssertEqual(afterSwitch.offset, beforeSwitch.offset, accuracy: 1)
        // Scrolling into the top boundary fetches the next page automatically.
        let countBeforeScroll = session.turns.count
        let restoredScroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: try XCTUnwrap(window.contentView)).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        restoredScroll.contentView.scroll(to: NSPoint(x: 0, y: 100)); restoredScroll.reflectScrolledClipView(restoredScroll.contentView)
        try await Task.sleep(for: .milliseconds(200))
        try await eventually { session.turns.count > countBeforeScroll }
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        try await TestSupport.eventually(file: file, line: line, diagnostic: "History condition timed out", condition)
    }
}
