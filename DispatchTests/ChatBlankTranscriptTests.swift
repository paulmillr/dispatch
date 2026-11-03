import AppKit
import SwiftUI
import XCTest
@preconcurrency import ScreenCaptureKit
@testable import DispatchApp

/// The transcript never goes blank: mass row changes at the followed bottom (a collapsed group, a helper
/// replacement, a reset and refill) keep rows on screen. The oracle samples the rows' markers about every frame; a
/// viewport whose markers are all hidden, gone or outside the clip while the transcript has rows is blank.
@MainActor
final class ChatBlankTranscriptTests: XCTestCase {
    func testSwitchingChatsShowsTheLatestMessagesFromTheFirstIncomingFrame() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Window capture requires macOS 14.4") }
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let names = ["ALPHA", "BRAVO"]
        let sessions = names.enumerated().map { tab, name in
            let session = coordinator.session(for: System.uuid())
            session.sessionID = "switch-\(tab)"; session.showChat = true
            session.turns = (0..<80).map { index in
                ChatTurn(id: "tab-\(tab)-turn-\(index)", items: [
                    .init(id: "tab-\(tab)-answer-\(index)", kind: .assistant,
                          text: "\(name) \(index == 79 ? "LATEST" : "EARLIER") REPLY \(index)\n\n"
                            + String(repeating: "The queue drains once the link is back.\n\n", count: index % 5 + 1))])
            }
            return session
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            sessions.forEach { $0.scrollPosition.disconnect() }
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        func content(_ session: ChatSession) -> AnyView {
            // TerminalContentView changes this identity when its pane selects another tab.
            AnyView(ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false).id(session.id))
        }
        let host = NSHostingView(rootView: content(sessions[0]))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually {
            sessions[0].scrollPosition.showsRows() && sessions[0].scrollPosition.isAtBottom(tolerance: 40) == true
        }
        let metadata = try await SCShareableContent.currentProcess
        let source = try XCTUnwrap(metadata.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: source)
        let configuration = SCStreamConfiguration()
        configuration.width = 900; configuration.height = 700
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        for round in 0..<10 {
            let tab = (round + 1) % 2, session = sessions[tab], name = names[tab]
            let start = ProcessInfo.processInfo.systemUptime
            var frames: [(elapsed: TimeInterval, snapshot: PresentationTestSupport.Snapshot)] = []
            var capturedPixels = Set<Data>()
            host.rootView = content(session)
            // Capture the compositor directly: layout markers can already report the final position while
            // WindowServer still presents a frame containing earlier messages. OCR runs after capturing.
            while ProcessInfo.processInfo.systemUptime - start < 0.25 {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                // Repeated captures can contain identical pixels. Every distinct frame still reaches OCR.
                let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
                guard capturedPixels.insert(pixels).inserted else { continue }
                frames.append((ProcessInfo.processInfo.systemUptime - start,
                               .init(bitmap: NSBitmapImageRep(cgImage: image))))
            }
            var incomingFrames = 0
            for (index, frame) in frames.enumerated() {
                let text = try frame.snapshot.text().uppercased()
                guard text.contains(name) else { continue } // The outgoing tab may still be presented.
                incomingFrames += 1
                let latest = text.contains("\(name) LATEST")
                if !latest {
                    try PresentationTestSupport.save(frame.snapshot.bitmap, named: "switch-\(round)-frame-\(index)",
                        in: "chat-scroll-stability-validation")
                }
                XCTAssertTrue(latest, "Switch \(round), frame at \(frame.elapsed) s showed earlier messages: \(text)")
            }
            XCTAssertGreaterThan(incomingFrames, 0, "The captures must include the newly selected chat")
            XCTAssertEqual(session.scrollPosition.isAtBottom(tolerance: 40), true)
            XCTAssertEqual(session.scrollPosition.interactionRevision, 0)
        }
    }

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

    func testOpeningHistoryWithATallReplyBeforeTheLatestTurnKeepsRowsOnScreen() async throws {
        // The archived failure had 83 rows in four turns, a very tall reply near the end, and a short live turn.
        // Reopening it kept only hidden rows even after a rebuild. Use fictional text with the same shape.
        var lastSample: ChatViewportTrace.Sample?
        let mount = try Mount { session, _ in
            session.turns = (0..<2).map { turn in
                let answers: [ChatItem] = (0..<(34 + turn)).map { index in
                    .init(id: "answer-\(turn)-\(index)", kind: .assistant,
                          text: String(repeating: "The queue drains once the link is back.\n\n", count: index == 10 || index == 25 ? 200 : 3))
                }
                return ChatTurn(id: "history-\(turn)", items: [
                    .init(id: "question-\(turn)", kind: .user, text: "Inspect the queue.")
                ] + answers)
            }
            let steps: [ChatItem] = (0..<6).map { index in
                .init(id: "step-\(index)", kind: .assistant, text: String(repeating: "The queue drains once the link is back.\n\n", count: 3))
            }
            session.turns.append(ChatTurn(id: "inspection", items: [
                .init(id: "inspect", kind: .user, text: "Inspect the result.")
            ] + steps))
            session.turns[2].items.append(.init(id: "long-answer", kind: .assistant,
                text: String(repeating: "The final inspection confirms that the pending queue drains.\n\n", count: 120)))
            session.turns[2].started = Date(timeIntervalSince1970: 1_750_000_000)
            session.turns[2].ended = Date(timeIntervalSince1970: 1_750_000_180)
            session.turns.append(ChatTurn(id: "live", items: [
                .init(id: "prompt", kind: .user, text: "Check the result."),
                .init(id: "command", kind: .tool, text: #"{"cmd":"rg queue Sources"}"#, title: "exec_command",
                      output: "Sources/Queue.swift: flushPending", completed: true, exitCode: 0),
                .init(id: "latest", kind: .assistant, text: "The result confirms that the pending queue drains.")]))
            session.active = true; session.busy = true; session.activeTurnID = "live"
            session.scrollPosition.diagnosticSink = { lastSample = $0 }
        }
        defer { mount.close() }
        XCTAssertEqual(mount.session.visibleTranscriptRows.count, 83)
        for round in 0..<4 {
            if round > 0 {
                mount.session.scrollPosition.disconnect()
                mount.window.contentView = nil
                // Check both the instrumented configuration in the archive and ordinary rendering.
                if round == 2 { mount.session.scrollPosition.diagnosticSink = nil; lastSample = nil }
                mount.window.contentView = NSHostingView(rootView: ChatView(session: mount.session,
                    coordinator: mount.coordinator, focused: false, floatingSwitch: false))
            }
            mount.sample()
            let start = ProcessInfo.processInfo.systemUptime
            try await TestSupport.eventually(timeout: .seconds(3), diagnostic: "Last viewport: \(String(describing: lastSample))") {
                ProcessInfo.processInfo.systemUptime - start > 1
                    && mount.session.scrollPosition.showsRows() && mount.session.scrollPosition.isAtBottom(tolerance: 40) == true
            }
            mount.stop()
            assertNoBlank(mount, "tall reply on mount \(round)")
            let lastID = try XCTUnwrap(mount.session.presentedTranscriptRows.last?.id)
            let marker = try XCTUnwrap(PresentationTestSupport.transcriptRows(in: XCTUnwrap(mount.window.contentView))[lastID])
            let scroll = try XCTUnwrap(marker.enclosingScrollView)
            XCTAssertFalse(marker.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(marker.convert(marker.bounds, to: scroll.documentView).intersects(scroll.contentView.bounds),
                          "The actual final message must be visible, not just an earlier row")
            XCTAssertNotNil(mount.session.followRevision)
            XCTAssertEqual(mount.session.scrollPosition.interactionRevision, 0)
        }
        _ = try await PresentationTestSupport.capture(mount.window, named: "tall-chat-reopened", in: "chat-scroll-stability-validation")
    }
}
