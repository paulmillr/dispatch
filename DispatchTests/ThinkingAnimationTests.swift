import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ThinkingAnimationTests: XCTestCase {
    func testActivityStaysDockedWhileReadingHistoryAndHidesAfterCompletion() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "persistent-activity"; session.active = true; session.busy = true
        session.showChat = true; session.atBottom = false; session.activeTurnID = "live"
        session.turns = (0..<30).map { index in
            .init(id: "old-\(index)", ended: .now, items: [.init(id: "answer", kind: .assistant, text: "An older answer in the conversation.")])
        } + [.init(id: "live", items: [.init(id: "summary", kind: .reasoning, text: "Inspecting every queued operation before committing.")])]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        let first = try await PresentationTestSupport.capture(window, named: "activity-docked-history", in: "thinking-animation-validation")
        XCTAssertFalse(try first.text().contains("Inspecting every queued operation"), "Reasoning stays hidden while reading history")
        let firstRow = try XCTUnwrap(first.recognizedText().first { $0.topCandidates(1).first?.string.contains("thinking") == true })
        func composerTop() throws -> CGFloat {
            let content = try XCTUnwrap(window.contentView)
            let editor = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: content).first)
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            let frame = scroll.convert(scroll.bounds, to: content)
            return (content.isFlipped ? content.bounds.height - frame.minY : frame.maxY) / content.bounds.height
        }
        let firstGap = firstRow.boundingBox.midY - (try composerTop())
        session.turns[30].items.append(.init(id: "tool", kind: .tool, text: "git status", title: "Shell", completed: true))
        try await Task.sleep(for: .milliseconds(100))
        let recent = try await PresentationTestSupport.capture(window)
        XCTAssertFalse(try recent.text().contains("Last:"))
        let recentRow = try XCTUnwrap(recent.recognizedText().first { $0.topCandidates(1).first?.string.contains("thinking") == true })
        XCTAssertEqual(recentRow.boundingBox.midY - (try composerTop()), firstGap, accuracy: 0.01)
        session.turns[30].ended = .now; session.busy = false
        try await Task.sleep(for: .milliseconds(500))
        let done = try await PresentationTestSupport.capture(window, named: "activity-docked-finished", in: "thinking-animation-validation")
        XCTAssertFalse(try done.text().contains("thinking"))
        XCTAssertFalse(try done.text().contains("Inspecting every queued operation"))
        XCTAssertFalse(session.atBottom, "Activity updates must not drag a history reader to the latest message")
    }

    func testCompletedActivityKeepsDetailsWithoutLastFragment() {
        let session = ChatSession(id: UUID())
        session.active = true; session.busy = true; session.activeTurnID = "turn"
        session.turns = [.init(id: "turn", items: [.init(id: "tool", kind: .tool, text: "git status", title: "Shell", completed: true)])]
        let state = AgentWorkingState(session)
        XCTAssertEqual(state.label, "thinking")
        XCTAssertEqual(state.fragment, "")
        let end = Date(timeIntervalSince1970: 100)
        let finished = state.finished(at: end, label: "Finished")
        XCTAssertFalse(finished.visible)
        XCTAssertEqual(finished.label, "Finished")
        XCTAssertEqual(finished.finishedAt, end)
        XCTAssertEqual(finished.details, state.details)
        session.awaitingPromptAck = true
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
    }

    func testLastActivityStaysHiddenRegardlessOfRowExpansion() throws {
        let session = ChatSession(id: UUID())
        session.active = true; session.busy = true; session.activeTurnID = "turn"
        session.turns = [.init(id: "turn", items: [
            .init(id: "assistant", kind: .assistant, text: "Checking the changes."),
            .init(id: "tool", kind: .tool, text: "git status", title: "Shell", completed: true)])]
        let group = try XCTUnwrap(session.transcriptRows.first?.group)
        let row = try XCTUnwrap(group.children.last)
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
        session.expanded.insert(row.id)
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
        session.setGroupExpanded(group, false)
        XCTAssertEqual(AgentWorkingState(session).fragment, "", "Collapsed groups must not bring back last activity")
        session.setGroupExpanded(group, true)
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
        session.expanded.remove(row.id)
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
        session.turns[0].items[1].title = "apply_patch"
        XCTAssertEqual(AgentWorkingState(session).fragment, "", "Expanded patches must not show last activity")
        session.collapsedLiveTools.insert(row.id)
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
    }

    func testReduceMotionClockStepsEveryFiveSecondsAfterTen() throws {
        let session = ChatSession(id: UUID())
        session.active = true; session.busy = true; session.activeTurnID = "turn"
        let start = Date(timeIntervalSinceReferenceDate: 0)
        session.turns = [.init(id: "turn", started: start)]
        let state = AgentWorkingState(session)
        func shown(_ seconds: TimeInterval, reduceMotion: Bool = true) -> String {
            AgentWorkingAnimation.timeText(state, now: start.addingTimeInterval(seconds), appeared: start, reduceMotion: reduceMotion)
        }
        XCTAssertEqual((1...10).map { shown(TimeInterval($0)) }, (1...10).map { "\($0)s" })
        XCTAssertEqual([11, 14.9, 15, 19, 20, 59, 60, 64, 65].map { shown($0) },
                       ["10s", "10s", "15s", "15s", "20s", "55s", "1m 0s", "1m 0s", "1m 5s"])
        XCTAssertEqual(shown(14, reduceMotion: false), "14s", "Without Reduce Motion the clock counts every second")
        let finished = state.finished(at: start.addingTimeInterval(13), label: "Finished")
        XCTAssertEqual(AgentWorkingAnimation.timeText(finished, now: start.addingTimeInterval(20), appeared: start, reduceMotion: true),
                       "13s", "A finished turn keeps its exact duration")
    }

    func testFinishedDurationSwitchesToCompletionTimeAfterFiveMinutes() throws {
        let session = ChatSession(id: UUID())
        session.active = true; session.busy = true; session.activeTurnID = "turn"
        let finish = try XCTUnwrap(ISO8601DateFormatter().date(from: "2000-01-01T20:15:00Z"))
        let start = finish.addingTimeInterval(-313)
        session.turns = [.init(id: "turn", started: start)]
        let active = AgentWorkingState(session)
        let state = active.finished(at: finish, label: "Finished")
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(AgentWorkingAnimation.timeText(state, now: finish.addingTimeInterval(299), appeared: start, timeZone: zone), "5m 13s")
        XCTAssertEqual(AgentWorkingAnimation.timeText(state, now: finish.addingTimeInterval(300), appeared: start, timeZone: zone), "8:15pm")
        XCTAssertEqual(AgentWorkingAnimation.timeText(state, now: finish.addingTimeInterval(3600), appeared: start, timeZone: zone), "8:15pm")
        XCTAssertEqual(AgentWorkingAnimation.timeText(active, now: finish, appeared: start, timeZone: zone), "5m 13s")
        XCTAssertEqual(AgentWorkingAnimation.timeText(active.finished(at: finish, label: "Stopped"), now: finish.addingTimeInterval(300), appeared: start, timeZone: zone), "5m 13s")
    }

    func testAdaptiveActivityUsesCurrentEventsAndKeepsRecentDetails() {
        let session = ChatSession(id: UUID())
        session.active = true; session.busy = true; session.activeTurnID = "turn"
        session.turns = [.init(id: "turn", items: [.init(id: "summary", kind: .reasoning, text: "Checking references")])]
        XCTAssertEqual(AgentWorkingState(session).label, "thinking")
        session.turns[0].items.append(.init(id: "tool", kind: .tool, text: #"{"cmd":"rg references Sources"}"#, title: "exec_command"))
        var state = AgentWorkingState(session)
        XCTAssertEqual(state.label, "searching")
        XCTAssertEqual(state.fragment, "rg references Sources")
        XCTAssertEqual(state.details.map(\.text), ["rg references Sources"])
        session.turns[0].items[1].completed = true
        state = AgentWorkingState(session)
        XCTAssertEqual(state.label, "thinking"); XCTAssertEqual(state.fragment, "")
        XCTAssertEqual(state.details.last?.title, "Completed tool")
        session.turns[0].items.append(.init(id: "next-summary", kind: .reasoning, text: "Reviewing the matches"))
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
        session.turns[0].items.append(.init(id: "read", kind: .tool, text: #"{"path":"Sources/App.swift"}"#, title: "read_file"))
        state = AgentWorkingState(session)
        XCTAssertEqual(state.label, "reading"); XCTAssertEqual(state.fragment, "Sources/App.swift")
        XCTAssertEqual(state.details.count, 2)
        session.awaitingPromptAck = true
        state = AgentWorkingState(session)
        XCTAssertEqual(state.fragment, ""); XCTAssertTrue(state.details.isEmpty)
    }

    func testActivityFormatsShellArgumentsLikeToolCards() {
        let session = ChatSession(id: UUID())
        session.active = true; session.busy = true; session.activeTurnID = "turn"
        let cases: [(String, String, String)] = [
            (#"["\/bin\/zsh", "-lc", "cp index.js \/tmp\/index.js"]"#, "cp index.js /tmp/index.js", "running"),
            (#"{"command":["/bin/zsh","-lc","rg TODO Sources"]}"#, "rg TODO Sources", "searching"),
            (#"{"cmd":["/bin/bash","-c","cat index.js"]}"#, "cat index.js", "reading"),
            (#"["cp","a b.js","/tmp/a b.js"]"#, "cp 'a b.js' '/tmp/a b.js'", "running"),
            (#"{"cmd":"git status"}"#, "git status", "running")
        ]
        for (payload, expected, label) in cases {
            var item = ChatItem(id: "tool", kind: .tool, text: payload, title: "shell")
            session.turns = [.init(id: "turn", items: [item])]
            XCTAssertEqual(AgentWorkingState(session).fragment, expected)
            XCTAssertEqual(AgentWorkingState(session).label, label)
            XCTAssertEqual(AgentWorkingState(session).details.last?.text, ToolPresentation(item).input)
            item.completed = true; session.turns[0].items = [item]
            XCTAssertEqual(AgentWorkingState(session).fragment, "")
        }
    }

    func testToolActivityFooterExpandsStopAndStatistics() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let session = ChatSession(id: UUID())
        session.active = true; session.busy = true; session.showChat = true; session.activeTurnID = "turn"
        session.turns = [.init(id: "turn", items: [
            .init(id: "summary", kind: .reasoning, text: "Checking the workspace before committing."),
            .init(id: "tool", kind: .tool, text: "git status", title: "Shell")])]
        session.usage = ChatUsage(["info": ["total_token_usage": ["input_tokens": 1200, "output_tokens": 340],
                                          "last_token_usage": ["total_tokens": 250], "model_context_window": 1000]])
        var stopCount = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: AgentWorkingIndicator(session: session, canStop: true, stop: { stopCount += 1 })
            .padding(20).background(Chrome.terminal).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        let collapsed = try await PresentationTestSupport.capture(window, named: "activity-collapsed", in: "thinking-animation-validation")
        XCTAssertFalse(try collapsed.text().contains("Checking the workspace"))
        let row = try XCTUnwrap(collapsed.recognizedText().first { $0.topCandidates(1).first?.string.contains("running") == true })
        let content = try XCTUnwrap(window.contentView), box = row.boundingBox
        let point = NSPoint(x: box.midX * content.bounds.width, y: (content.isFlipped ? 1 - box.midY : box.midY) * content.bounds.height)
        try PresentationTestSupport.click(window, at: content.convert(point, to: nil))
        try await Task.sleep(for: .milliseconds(150))
        let expanded = try await PresentationTestSupport.capture(window, named: "activity-expanded", in: "thinking-animation-validation")
        let text = try expanded.text()
        XCTAssertFalse(text.contains("Checking the workspace"), text)
        XCTAssertFalse(text.contains("Reported summary"), text)
        XCTAssertTrue(text.contains("Stop thinking"), text)
        XCTAssertFalse(text.contains("Elapsed"), text)
        XCTAssertFalse(text.contains("Tools:"), text)
        XCTAssertFalse(text.contains("1 running"), text)
        XCTAssertTrue(text.contains("75%"), text)
        XCTAssertTrue(text.contains("1.2K in"), text)
        XCTAssertTrue(text.contains("340 out"), text)
        XCTAssertFalse(text.contains("context remaining"), "Expanded activity uses the same compact stats as the composer")
        let stop = try XCTUnwrap(expanded.recognizedText().first { $0.topCandidates(1).first?.string.contains("Stop thinking") == true })
        let stopPoint = NSPoint(x: stop.boundingBox.midX * content.bounds.width,
            y: (content.isFlipped ? 1 - stop.boundingBox.midY : stop.boundingBox.midY) * content.bounds.height)
        try PresentationTestSupport.click(window, at: content.convert(stopPoint, to: nil))
        try await TestSupport.eventually { stopCount == 1 }
        session.interruptionID = UUID()
        try await Task.sleep(for: .milliseconds(100))
        let visible = try await PresentationTestSupport.capture(window).text()
        XCTAssertTrue(visible.contains("Stopping"))
        session.busy = false
        try await Task.sleep(for: .milliseconds(100))
        let stopped = try await PresentationTestSupport.capture(window).text()
        XCTAssertFalse(stopped.contains("Stop thinking"))

        session.interruptionID = nil; session.busy = true; session.activeTurnID = "fresh"
        session.turns.append(.init(id: "fresh", items: []))
        try await Task.sleep(for: .milliseconds(100))
        let fresh = try await PresentationTestSupport.capture(window)
        let thinking = try XCTUnwrap(fresh.recognizedText().first { $0.topCandidates(1).first?.string.contains("thinking") == true })
        let thinkingPoint = NSPoint(x: thinking.boundingBox.midX * content.bounds.width,
            y: (content.isFlipped ? 1 - thinking.boundingBox.midY : thinking.boundingBox.midY) * content.bounds.height)
        try PresentationTestSupport.click(window, at: content.convert(thinkingPoint, to: nil))
        try await Task.sleep(for: .milliseconds(100))
        let emptyTurn = try await PresentationTestSupport.capture(window).text()
        XCTAssertTrue(emptyTurn.contains("Stop thinking"), "An initial turn can expand before any summary or tool arrives")
        XCTAssertFalse(emptyTurn.contains("Elapsed"), emptyTurn)
        XCTAssertFalse(emptyTurn.contains("Tools:"), emptyTurn)
        XCTAssertTrue(emptyTurn.contains("75%"), emptyTurn)
    }

    func testHistoryLoadingUsesActivityWithoutHistoricalReasoning() {
        let session = ChatSession(id: UUID())
        session.loadingHistory = true
        session.activeTurnID = "restored"
        session.turns = [.init(id: "restored", items: [.init(id: "reason", kind: .reasoning, text: "Historical summary")])]
        for busy in [false, true] {
            session.busy = busy
            let state = AgentWorkingState(session)
            XCTAssertTrue(state.visible)
            XCTAssertTrue(state.loading)
            XCTAssertEqual(state.label, "Loading conversation…")
            XCTAssertNil(state.started)
            XCTAssertTrue(state.fragment.isEmpty)
            XCTAssertTrue(state.details.isEmpty)
        }
        session.busy = false; session.loadingHistory = false
        XCTAssertFalse(AgentWorkingState(session).visible)

        session.active = true; session.busy = true
        session.loadingHistory = true; session.awaitingPromptAck = true
        let submitted = AgentWorkingState(session)
        XCTAssertTrue(submitted.visible)
        XCTAssertFalse(submitted.loading)
        XCTAssertEqual(submitted.label, "thinking")
    }

    func testReasoningStaysInHistoryButHiddenFromActivityStates() throws {
        let session = ChatSession(id: UUID())
        session.active = true; session.busy = true; session.activeTurnID = "current"
        session.turns = [ChatTurn(id: "old", ended: .now, items: [.init(id: "reason", kind: .reasoning, text: "Old summary")]),
                         ChatTurn(id: "current", items: [.init(id: "reason", kind: .reasoning, text: "Current\nsummary")])]
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
        XCTAssertTrue(AgentWorkingState(session).details.isEmpty)
        XCTAssertEqual(session.transcriptRows.compactMap { $0.item?.text }, ["Old summary", "Current\nsummary"])
        XCTAssertEqual(session.visibleTranscriptRows.count, 2)
        XCTAssertEqual(session.turns.flatMap(\.items).count, 2, "Source reasoning is retained for transcript reconciliation")
        session.awaitingPromptAck = true
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
        XCTAssertTrue(AgentWorkingState(session).visible)
        session.loadingHistory = true
        XCTAssertTrue(AgentWorkingState(session).visible, "Discovering the new rollout must not hide a submitted turn")
        session.loadingHistory = false
        session.awaitingPromptAck = false; session.activeTurnID = "next"
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
        session.activeTurnID = "current"
        let approval = PendingApproval(key: "thinking-test", operation: "Approval") { _ in }
        session.approvals = [approval]
        XCTAssertTrue(AgentWorkingState(session).waiting)
        approval.resolve(.deny)
        session.turns[1].items.append(.init(id: "answer", kind: .assistant, text: "Answer"))
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
        XCTAssertTrue(AgentWorkingState(session).visible)
        session.busy = false
        XCTAssertFalse(AgentWorkingState(session).visible)
        session.turns[1].items += [
            .init(id: "tool-1", kind: .tool, text: "git status", title: "Shell"),
            .init(id: "middle-summary", kind: .reasoning, text: "Between tool calls"),
            .init(id: "tool-2", kind: .tool, text: "git diff", title: "Shell")
        ]
        let group = try XCTUnwrap(session.transcriptRows.compactMap(\.group).first)
        XCTAssertEqual(group.children.compactMap { $0.item?.id }, ["tool-1"])
        XCTAssertTrue(session.transcriptRows.contains { $0.item?.text == "Answer" })
        session.setGroupExpanded(group, true)
        XCTAssertEqual(session.visibleTranscriptRows.compactMap { $0.item?.id }, ["reason", "reason", "answer", "tool-1", "middle-summary", "tool-2"])
    }

    func testReportedSummaryEventsDeduplicateAndIgnoreRawReasoning() async throws {
        // Codex reports one summary twice (event and response item) beside raw reasoning: the chat shows
        // the summary once and never the raw text.
        let lines = [
            #"{"type":"session_meta","payload":{"id":"thinking"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"Reported summary"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_reasoning_raw_content","text":"DO_NOT_DISPLAY"}}"#,
            #"{"type":"response_item","payload":{"id":"reason","type":"reasoning","summary":[{"type":"summary_text","text":"Reported summary"}],"content":[{"type":"reasoning_text","text":"DO_NOT_DISPLAY"}],"encrypted_content":"DO_NOT_DISPLAY"}}"#
        ]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-thinking-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let session = try await chat.archived(lines, agent: "codex", session: "thinking", in: root)
        XCTAssertEqual(session.turns.flatMap(\.items).map(\.text), ["Reported summary"])
    }

    func testThinkingSweepsForTenSecondsBeforeTracesAndDuringToolWork() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let session = ChatSession(id: UUID())
        session.active = true; session.busy = true; session.showChat = true
        session.awaitingPromptAck = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: AgentWorkingIndicator(session: session)
            .padding(20).background(Chrome.terminal).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        let directory = CodexTestSupport.root.appendingPathComponent("build/thinking-animation-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gif = try XCTUnwrap(CGImageDestinationCreateWithURL(directory.appendingPathComponent("thinking-10s.gif") as CFURL,
            "com.compuserve.gif" as CFString, 100, nil))
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var sweepPositions: [[Double]] = [[], []]
        var sweepRow: Int?
        // A shimmer moves across the label, so OCR can misread one frame ("runing") while the next reads fine.
        // Each checkpoint's text must be read by OCR on that frame or a later one of the same phase.
        var unread: [String] = []
        let clock = ContinuousClock(), began = ContinuousClock.now
        for frame in 0..<100 {
            try await clock.sleep(until: began.advanced(by: .milliseconds((frame + 1) * 100)))
            if frame == 30 {
                session.awaitingPromptAck = false; session.activeTurnID = "turn"
                session.turns = [.init(id: "turn", items: [
                    .init(id: "reason", kind: .reasoning, text: "two files changed, one new; tests green before commit"),
                    .init(id: "tool", kind: .tool, text: "git status", title: "Shell")])]
            }
            let snapshot = try await PresentationTestSupport.capture(window)
            let bitmap = snapshot.bitmap
            CGImageDestinationAddImage(gif, try XCTUnwrap(bitmap.cgImage),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
            // The one-pixel rule has many violet pixels in the same row. The
            // orbit/diamond cannot satisfy this, so a rotating icon alone fails.
            for y in sweepRow.map({ [$0] }) ?? Array(0..<bitmap.pixelsHigh) {
                var xs: [Double] = []
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.redComponent - color.greenComponent > 0.045 && color.blueComponent - color.greenComponent > 0.045 {
                        xs.append(Double(x) / Double(bitmap.pixelsWide))
                    }
                }
                if xs.count > 15 {
                    sweepRow = y
                    sweepPositions[frame < 30 ? 0 : 1].append(xs.reduce(0, +) / Double(xs.count))
                    break
                }
            }
            if [5, 25, 65, 85].contains(frame) {
                try PresentationTestSupport.save(bitmap, named: "thinking-frame-\(frame)", in: "thinking-animation-validation")
                let expected = frame < 30 ? ["thinking"] : frame == 65 ? ["running", "git status"] : ["running"]
                for text in expected { try PresentationTestSupport.assertRendered(text, in: try XCTUnwrap(window.contentView)) }
                unread += expected
                if frame == 65 { XCTAssertFalse(try snapshot.text().contains("two files changed")) }
            }
            try unread.removeAll { try snapshot.reads([$0]) }
            if frame == 29 || frame == 99 { XCTAssertEqual(unread, [], "OCR never read these in the frames after their checkpoint") }
        }
        XCTAssertTrue(CGImageDestinationFinalize(gif))
        for positions in sweepPositions {
            XCTAssertLessThan(try XCTUnwrap(positions.min()), 0.3, "Violet sweep reaches the left, with or without a trace")
            XCTAssertGreaterThan(try XCTUnwrap(positions.max()), 0.7, "Violet sweep reaches the right, with or without a trace")
        }
    }

    func testRealCodexShowsThinkingBeforeAndDuringReportedSummary() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let fixture = try CodexEndpointFixture(prefix: "dispatch-thinking-e2e-", delay: 0.04, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true); runtime.workspace = controller.workspace
        runtime.start(preferences: Preferences())
        let workspace = controller.workspace
        workspace.defaultDirectory = fixture.state.appendingPathComponent("work").path
        workspace.onCloseTabs = { runtime.close($0) }; workspace.newSpace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil; runtime.stop(); runtime.chat = previousChat }
        let id = try XCTUnwrap(workspace.activeTab).id
        try await TestSupport.eventually {
            runtime.views[id].map { $0.surface != nil && !TerminalTestSupport.screen(terminal: $0).isEmpty } == true
        }
        let terminal = try XCTUnwrap(runtime.views[id])
        TerminalTestSupport.send(CodexTestSupport.command(state: fixture.state, binary: fixture.binary), to: terminal)
        let session = runtime.chat.session(for: id)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            session.active && AgentModelMenu.containsModel(TerminalTestSupport.screen(terminal: terminal), slug: "dispatch-fixture", name: "Dispatch fixture")
        }
        runtime.chat.chooseChat(true, session: session)
        session.draft = "DISPATCH_THINKING_ANIMATION commit"; runtime.chat.submit(session)
        XCTAssertTrue(session.busy)
        try await Task.sleep(for: .milliseconds(450))
        let pending = try await PresentationTestSupport.capture(window, named: "real-codex-before-summary", in: "thinking-animation-validation")
        XCTAssertTrue(try pending.text().contains("thinking"))
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
        try await TestSupport.eventually(timeout: .seconds(10)) {
            session.busy && session.turns.flatMap(\.items).contains { $0.kind == .reasoning && $0.text.contains("two files changed") }
        }
        try await Task.sleep(for: .milliseconds(900))
        let reported = try await PresentationTestSupport.capture(window, named: "real-codex-reported-summary", in: "thinking-animation-validation")
        XCTAssertFalse(try reported.text().contains("two files changed"))
        XCTAssertEqual(AgentWorkingState(session).fragment, "")
        XCTAssertTrue(session.visibleTranscriptRows.contains { $0.item?.kind == .reasoning })
        try await TestSupport.eventually(timeout: .seconds(10)) { !session.busy }
        XCTAssertFalse(AgentWorkingState(session).visible)
        XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .reasoning }.map(\.text),
                       ["two files changed, one new; tests green before commit"])
        passed = testRun?.failureCount == 0
    }

    func testLiveActivityStaysReadableAndExpandsWithoutDuplicateIndicator() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "thinking-animation"; session.showChat = true
        session.active = true; session.busy = true; session.activeTurnID = "turn"
        let summary = "Checking the supplied summary before updating the workspace."
        session.turns = [.init(id: "turn", items: [.init(id: "user", kind: .user, text: "Inspect the workspace."),
                                                .init(id: "reason", kind: .reasoning, text: summary)])]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false)
            .foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        let early = try await PresentationTestSupport.capture(window, named: "thinking-early", in: "thinking-animation-validation")
        try await Task.sleep(for: .milliseconds(650))
        let later = try await PresentationTestSupport.capture(window, named: "thinking-later", in: "thinking-animation-validation")
        XCTAssertNotEqual(early.bitmap.representation(using: .png, properties: [:]), later.bitmap.representation(using: .png, properties: [:]))
        let rows = try later.recognizedText()
        let thinking = rows.filter { $0.topCandidates(1).first?.string.contains("thinking") == true }
        XCTAssertEqual(thinking.count, 1, "Only the working indicator is visible")
        let text = try later.text()
        XCTAssertFalse(text.contains("Checking"), text)
        XCTAssertTrue(text.contains("Reasoning summary"), text)
        XCTAssertFalse(text.contains("Working"), text)
        let box = try XCTUnwrap(thinking.first).boundingBox
        let content = try XCTUnwrap(window.contentView)
        let point = NSPoint(x: box.midX * content.bounds.width,
                            y: (content.isFlipped ? 1 - box.midY : box.midY) * content.bounds.height)
        let existingWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        try PresentationTestSupport.click(window, at: content.convert(point, to: nil))
        var popover: NSWindow?
        try await TestSupport.eventually {
            popover = NSApp.windows.first { $0.isVisible && $0.contentView != nil && !existingWindows.contains($0.windowNumber) }
            return popover != nil
        }
        // A native popover can be visible before the compositor has drawn its content.
        var rendered: PresentationTestSupport.Snapshot?
        var expandedText = ""
        try await TestSupport.eventually(diagnostic: expandedText) {
            rendered = try await PresentationTestSupport.capture(XCTUnwrap(popover), named: "thinking-expanded", in: "thinking-animation-validation")
            expandedText = try XCTUnwrap(rendered).text()
            return expandedText.contains("thinking")
        }
        let expanded = try XCTUnwrap(rendered)
        XCTAssertTrue(try expanded.text().contains("thinking"))
        XCTAssertFalse(try expanded.text().contains("Reported summary"))
        XCTAssertFalse(try expanded.text().contains(summary))
        popover?.performClose(nil)
        session.busy = false; session.turns[0].ended = .now
        try await Task.sleep(for: .milliseconds(100))
        let done = try await PresentationTestSupport.capture(window, named: "thinking-complete", in: "thinking-animation-validation")
        XCTAssertFalse(try done.text().contains(summary))
        XCTAssertTrue(try done.text().contains("Reasoning summary"))
        XCTAssertFalse(try done.text().contains("thinking"))
        let disclosure = try XCTUnwrap(done.recognizedText().first {
            $0.topCandidates(1).first?.string.contains("Reasoning summary") == true
        }).boundingBox
        let disclosurePoint = NSPoint(x: disclosure.midX * content.bounds.width,
                                      y: (content.isFlipped ? 1 - disclosure.midY : disclosure.midY) * content.bounds.height)
        try PresentationTestSupport.click(window, at: content.convert(disclosurePoint, to: nil))
        try await Task.sleep(for: .milliseconds(150))
        let revealed = try await PresentationTestSupport.capture(window, named: "reasoning-summary-expanded", in: "thinking-animation-validation")
        XCTAssertTrue(try revealed.text().contains(summary))
        let editor = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: content).first)
        XCTAssertEqual(editor.displayedPlaceholder, "Reply…")
        try PresentationTestSupport.click(window, at: content.convert(disclosurePoint, to: nil))
        try await Task.sleep(for: .milliseconds(150))
        let visible = try await PresentationTestSupport.capture(window).text()
        XCTAssertFalse(visible.contains(summary))
    }

    func testHiddenThinkingStopsAndReducedMotionKeepsReasoningHidden() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let session = ChatSession(id: UUID())
        session.active = true; session.busy = true; session.showChat = true
        session.turns = [.init(id: "turn", items: [.init(id: "reason", kind: .reasoning, text: "Supplied thought fragment")])]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: AgentWorkingIndicator(session: session).padding(12).background(Chrome.terminal))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        session.showChat = false
        try await Task.sleep(for: .milliseconds(100))
        let first = try await PresentationTestSupport.capture(window)
        try await Task.sleep(for: .milliseconds(250))
        let second = try await PresentationTestSupport.capture(window)
        XCTAssertEqual(first.bitmap.representation(using: .png, properties: [:]), second.bitmap.representation(using: .png, properties: [:]), "Hidden chat must stop its animation timeline")
        session.showChat = true
        window.contentView = NSHostingView(rootView: AgentWorkingAnimation(session: session, reduceMotion: true)
            .padding(12).background(Chrome.terminal))
        try await Task.sleep(for: .milliseconds(100))
        let reduced = try await PresentationTestSupport.capture(window, named: "thinking-reduced-motion", in: "thinking-animation-validation")
        XCTAssertFalse(try reduced.text().contains("Supplied thought fragment"))
        XCTAssertTrue(try reduced.text().contains("thinking"))
    }
}
