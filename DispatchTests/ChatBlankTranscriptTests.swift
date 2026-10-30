import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// The transcript never goes blank: mass row changes at the followed bottom (a collapsed group, a helper
/// replacement, a reset and refill) keep rows on screen. The oracle samples the rows' markers about every frame; a
/// viewport whose markers are all hidden, gone or outside the clip while the transcript has rows is blank.
@MainActor
final class ChatBlankTranscriptTests: XCTestCase {
    @MainActor private final class Mount {
        let coordinator = ChatCoordinator(enabled: false)
        let session: ChatSession
        let window: NSWindow
        private var sampler: Task<Void, Never>?
        private var blankSince: TimeInterval?
        private(set) var longestBlank: TimeInterval = 0
        private(set) var blankEpisodes = 0

        init(prepare: (ChatSession, ChatCoordinator) -> Void) throws {
            try DesktopTestSupport.requireUnlocked(); AppFont.register()
            session = coordinator.session(for: System.uuid())
            session.sessionID = "blank-transcript"; session.showChat = true
            prepare(session, coordinator)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false,
                                                                  floatingSwitch: false))
            window.makeKeyAndOrderFront(nil)
        }

        /// Sample until `stop`; a few frames of layout count as a blank only past 150 ms (`assertNoBlank`).
        func sample() {
            sampler = Task { @MainActor [weak self] in
                while !Task.isCancelled, let self {
                    let now = ProcessInfo.processInfo.systemUptime
                    let blank = !self.session.visibleTranscriptRows.isEmpty && !self.session.scrollPosition.showsRows()
                    if blank {
                        if self.blankSince == nil { self.blankSince = now; self.blankEpisodes += 1 }
                        self.longestBlank = max(self.longestBlank, now - (self.blankSince ?? now))
                    } else { self.blankSince = nil }
                    try? await Task.sleep(for: .milliseconds(8))
                }
            }
        }

        func stop() { sampler?.cancel(); sampler = nil }

        func close() {
            stop()
            session.scrollPosition.disconnect()
            window.orderOut(nil); window.contentView = nil; window.close()
            coordinator.stop()
        }
    }

    private static func turns(_ range: Range<Int>) -> [ChatTurn] {
        range.map { index in
            var items: [ChatItem] = [.init(id: "user-\(index)", kind: .user, text: "Question \(index): why does the write queue stall after a reconnect?")]
            items.append(.init(id: "answer-\(index)", kind: .assistant,
                               text: "Answer \(index)\n\n" + String(repeating: "The queue drains once the link is back.\n\n", count: 3)))
            if index % 2 == 0 {
                for step in 0..<3 {
                    items.append(.init(id: "tool-\(index)-\(step)", kind: .tool, text: #"{"cmd":"rg reconnect Sources"}"#, title: "exec_command",
                                       output: "Sources/Net/Reconnect.swift:\(step + 10): match", completed: true, exitCode: 0))
                }
            }
            return ChatTurn(id: "turn-\(index)", items: items)
        }
    }

    private static func record(_ kind: String, _ id: String, turn: String, text: String = "", time: Int64) -> HelperChat.Record {
        .init(id: id, turn: turn, kind: kind, text: text, title: kind == "tool" ? "exec_command" : "",
              output: kind == "tool" ? "Sources/Net/Queue.swift: flushPending" : "", blocks: [], completed: true,
              exit_code: kind == "tool" ? 0 : nil, patch: nil, time_ms: time, documents: [], tool: nil, inline_reasoning: false)
    }

    /// A finished history and a live turn of 30 timed steps (untimed live steps would show only three).
    private static func records(turns: Int) -> [HelperChat.Record] {
        var records: [HelperChat.Record] = []
        for index in 0..<turns {
            let turn = "turn-\(index)", base = Int64(1_750_000_000_000) + Int64(index) * 60_000
            records += [record("turn_started", "start-\(index)", turn: turn, time: base),
                        record("user", "user-\(index)", turn: turn, text: "Question \(index): why does the write queue stall?", time: base + 1000),
                        record("assistant", "answer-\(index)", turn: turn,
                               text: "Answer \(index)\n\n" + String(repeating: "The queue drains once the link is back.\n\n", count: 3), time: base + 2000),
                        record("turn_ended", "end-\(index)", turn: turn, time: base + 3000)]
        }
        let base = Int64(1_750_000_000_000) + Int64(turns) * 60_000
        records += [record("turn_started", "start-live", turn: "live", time: base),
                    record("user", "user-live", turn: "live", text: "Trace the reconnect stall.", time: base + 1000),
                    record("assistant", "working", turn: "live", text: "Tracing why the reconnect handler drops queued writes.", time: base + 2000)]
        for step in 0..<30 {
            records.append(record("tool", "live-step-\(step)", turn: "live", text: #"{"cmd":"rg flushPending Sources"}"#,
                                  time: base + 3000 + Int64(step) * 1000))
        }
        return records
    }

    /// The live turn's group, expanded by the reader, who follows the bottom.
    private func expandLiveGroup(_ mount: Mount) async throws -> ChatToolGroup {
        let session = mount.session
        let group = try XCTUnwrap(session.transcriptRows.last { $0.group != nil }?.group)
        session.setGroupExpanded(group, true)
        session.revealLatestMessages()
        try await TestSupport.eventually(timeout: .seconds(5)) {
            session.atBottom && session.scrollPosition.showsRows()
                && session.scrollPosition.isAtBottom(tolerance: 40) == true
        }
        try await Task.sleep(for: .milliseconds(800))
        return group
    }

    private func assertNoBlank(_ mount: Mount, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        print("Blank transcript oracle: \(what): longest \(mount.longestBlank) s, \(mount.blankEpisodes) episodes")
        XCTAssertLessThan(mount.longestBlank, 0.15, "\(what): blank for \(mount.longestBlank) s in \(mount.blankEpisodes) episodes",
                          file: file, line: line)
    }

    func testCollapsingAnExpandedGroupAtTheBottomKeepsRowsOnScreen() async throws {
        let mount = try Mount { session, _ in
            session.turns = Self.turns(0..<150)
            session.active = true; session.busy = true; session.activeTurnID = "live"
            session.insert(.init(id: "prompt", kind: .user, text: "Trace the reconnect stall."), turnID: "live")
            session.insert(.init(id: "working", kind: .assistant, text: "Tracing why the reconnect handler drops queued writes."), turnID: "live")
            for index in 0..<30 {
                session.insert(.init(id: "live-step-\(index)", kind: .tool, text: #"{"cmd":"rg flushPending Sources"}"#, title: "exec_command",
                                     output: "Sources/Net/Queue.swift:\(index): flushPending", completed: true, exitCode: 0), turnID: "live")
            }
        }
        defer { mount.close() }
        for round in 1...3 {
            let group = try await expandLiveGroup(mount)
            let rows = mount.session.visibleTranscriptRows.count
            mount.sample()
            mount.session.setGroupExpanded(group, false)
            XCTAssertLessThanOrEqual(mount.session.visibleTranscriptRows.count, rows - 28, "About 30 rows leave at once")
            try await Task.sleep(for: .seconds(3))
            mount.stop()
            assertNoBlank(mount, "collapse \(round)")
            XCTAssertTrue(mount.session.scrollPosition.showsRows())
        }
    }

    func testHelperReplacementWhileAnExpandedGroupShowsChangesNothing() async throws {
        let records = Self.records(turns: 150)
        let mount = try Mount { session, coordinator in
            coordinator.receiveHelper(.page(.init(records: records, earlier: "cursor", state: nil, snapshot: nil)), session: session)
            session.active = true; session.busy = true; session.activeTurnID = "live"
        }
        defer { mount.close() }
        let group = try await expandLiveGroup(mount)
        let rows = mount.session.visibleTranscriptRows.map(\.id)
        mount.sample()
        mount.coordinator.receiveHelper(.replacement(.init(records: records, earlier: "cursor", state: nil, snapshot: nil)), session: mount.session)
        XCTAssertEqual(mount.session.visibleTranscriptRows.map(\.id), rows)
        XCTAssertEqual(mount.session.groupDisclosure(group, turnID: "live"), .all)
        try await Task.sleep(for: .seconds(3))
        mount.stop()
        assertNoBlank(mount, "replacement")
        XCTAssertTrue(mount.session.atBottom)
    }

    func testAReplacementThatDropsTheTallLastTurnKeepsRowsOnScreen() async throws {
        let records = Self.records(turns: 150)
        let mount = try Mount { session, coordinator in
            coordinator.receiveHelper(.page(.init(records: records, earlier: nil, state: nil, snapshot: nil)), session: session)
        }
        defer { mount.close() }
        _ = try await expandLiveGroup(mount)
        let rows = mount.session.visibleTranscriptRows.count
        mount.sample()
        // The transcript, read from its start, no longer has the live turn (a rewound conversation).
        let kept = records.filter { $0.turn != "live" }
        mount.coordinator.receiveHelper(.replacement(.init(records: kept, earlier: nil, state: nil, snapshot: nil)), session: mount.session)
        XCTAssertLessThanOrEqual(mount.session.visibleTranscriptRows.count, rows - 30)
        try await Task.sleep(for: .seconds(3))
        mount.stop()
        assertNoBlank(mount, "dropped turn")
    }

    func testResetAndLaterRefillTwiceKeepsRowsOnScreen() async throws {
        let turns = Self.turns(0..<180)
        let mount = try Mount { session, _ in session.turns = turns }
        defer { mount.close() }
        try await TestSupport.eventually(timeout: .seconds(5)) { mount.session.scrollPosition.showsRows() }
        try await Task.sleep(for: .milliseconds(800))
        mount.sample()
        for round in 1...2 {
            mount.session.resetConversation()
            try await Task.sleep(for: .milliseconds(1500))
            mount.session.turns = turns; mount.session.historyRevision += 1; mount.session.revision += 1
            try await Task.sleep(for: .seconds(4))
            assertNoBlank(mount, "refill \(round)")
        }
        mount.stop()
        XCTAssertTrue(mount.session.scrollPosition.showsRows())
    }
}
