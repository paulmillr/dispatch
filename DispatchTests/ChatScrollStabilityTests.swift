import AppKit
import Observation
import SwiftUI
import XCTest
import os
@testable import DispatchApp

@MainActor
final class ChatScrollStabilityTests: XCTestCase {
    func testDiagnosticsOptInDiscardsQueuedSamplesOnDisableAndCanReenable() async throws {
        let fixture = try NativeScrollFixture(rows: 8)
        defer { fixture.close() }
        fixture.markers[0].update(id: "private-user@private-host:/Users/private-user/private-transcript", position: fixture.position)
        var sample: ChatViewportTrace.Sample?
        fixture.position.diagnosticSink = { sample = $0 }
        fixture.position.recordDiagnostic(.watchdog, force: true)
        let value = try XCTUnwrap(sample)
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        for privateValue in ["private-user", "private-host", "private-transcript", "surface", "uptime"] {
            XCTAssertFalse(text.contains(privateValue), privateValue)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ChatViewportTrace(writer: ChatViewportTraceWriter(directory: root))
        XCTAssertFalse(recorder.isEnabled)
        recorder.record(value)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let file = root.appendingPathComponent("chat-viewport.jsonl")
        let previous = root.appendingPathComponent("chat-viewport.previous.jsonl")
        // An earlier launch's log, rotated and current.
        let writer = ChatViewportTraceWriter(directory: root)
        try await writer.append([value])
        try Data("old\n".utf8).write(to: previous)
        recorder.setEnabled(true)
        try await TestSupport.eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("diagnostics.json").path) }
        XCTAssertEqual(try Data(contentsOf: file).split(separator: 0x0a).count, 1, "Launching with diagnostics on keeps the earlier log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        recorder.record(value)
        recorder.setEnabled(false)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(try Data(contentsOf: file).split(separator: 0x0a).count, 1, "Disabling discards samples waiting for the batch timer")
        recorder.setEnabled(true)
        try await TestSupport.eventually { !FileManager.default.fileExists(atPath: file.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path), "Turning diagnostics back on starts a new log")
        recorder.record(value)
        try await TestSupport.eventually(timeout: .seconds(5)) { FileManager.default.fileExists(atPath: file.path) }
        recorder.setEnabled(false)
        let lines = try Data(contentsOf: file).split(separator: 0x0a)
        XCTAssertEqual(lines.count, 1)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("diagnostics.json"))) as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), ["format", "started", "applicationVersion", "applicationBuild"])
    }

    func testDiagnosticsWriteFailureStaysVisibleWithoutExposingSystemError() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let recorder = ChatViewportTrace(writer: ChatViewportTraceWriter(directory: file))
        recorder.setEnabled(true)
        defer { recorder.setEnabled(false) }
        try await TestSupport.eventually { recorder.error != nil }
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(recorder.error, "Could not write diagnostics. Check access to the log folder.")
    }

    func testViewportTraceDistinguishesMissingRowsAndRecordsRecoveryWithoutText() async throws {
        let fixture = try NativeScrollFixture(rows: 8)
        defer { fixture.close() }
        fixture.move(to: 750)
        try await Task.sleep(for: .milliseconds(60))
        var samples: [ChatViewportTrace.Sample] = []
        fixture.position.diagnosticSink = { samples.append($0) }
        fixture.position.diagnosticState = {
            .init(revision: 12, historyRevision: 3, rows: 8, turns: 2,
                  busy: true, atBottom: false, following: false, loadingHistory: false, loadingEarlier: false)
        }
        fixture.position.hasContent = { true }
        fixture.position.recordDiagnostic(.transcript, force: true)
        let healthy = try XCTUnwrap(samples.last)
        XCTAssertEqual(healthy.transcript?.rows, 8)
        XCTAssertEqual(healthy.markers.mounted, 8)
        XCTAssertGreaterThan(healthy.markers.visible, 0)
        XCTAssertEqual(healthy.clip?.y, fixture.scroll.contentView.bounds.minY)
        XCTAssertEqual(healthy.document?.height, 2400)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(healthy), as: UTF8.self).contains("row-"))
        fixture.markers.forEach { $0.removeFromSuperview() }
        let start = ProcessInfo.processInfo.systemUptime
        for second in 0...4 {
            fixture.position.geometryChanged()
            fixture.position.checkViewport(now: start + Double(second))
        }
        let blank = try XCTUnwrap(samples.first { $0.event == .blank })
        XCTAssertEqual(blank.transcript?.rows, 8)
        XCTAssertEqual(blank.markers.mounted, 0)
        XCTAssertEqual(blank.markers.visible, 0)
        XCTAssertTrue(samples.contains { $0.event == .recoveryRequested })
        XCTAssertTrue(samples.contains { $0.event == .rebuildRequested })
        fixture.markers.forEach { fixture.document.addSubview($0) }
        fixture.position.checkViewport(now: start + 5)
        XCTAssertGreaterThan(try XCTUnwrap(samples.last { $0.event == .recovered }).markers.visible, 0)
        fixture.position.disconnect()
        XCTAssertEqual(samples.last?.event, .disconnected)
        XCTAssertNil(fixture.position.diagnosticState)
    }

    func testViewportTraceCoalescesLayoutEventsAndStopsSamplingHiddenChats() throws {
        let fixture = try NativeScrollFixture(rows: 8)
        defer { fixture.close() }
        var samples: [ChatViewportTrace.Sample] = []
        fixture.position.diagnosticSink = { samples.append($0) }
        let now = ProcessInfo.processInfo.systemUptime
        fixture.position.recordDiagnostic(.connected, force: true, now: now)
        for _ in 0..<1000 { fixture.position.recordDiagnostic(.geometry, now: now + 0.1) }
        XCTAssertEqual(samples.count, 1)
        fixture.position.recordDiagnostic(.watchdog, force: true, now: now + 2)
        XCTAssertEqual(samples.last?.events["geometry"], 1000)
        fixture.scroll.isHidden = true
        fixture.position.recordDiagnostic(.watchdog, force: true, now: now + 4)
        let hiddenCount = samples.count
        fixture.position.recordDiagnostic(.watchdog, force: true, now: now + 6)
        XCTAssertEqual(samples.count, hiddenCount)
        fixture.scroll.isHidden = false
        fixture.position.recordDiagnostic(.watchdog, force: true, now: now + 8)
        XCTAssertEqual(samples.count, hiddenCount + 1)
    }

    func testViewportTraceRotatesBoundedFilesAndReportsDroppedSamples() async throws {
        let fixture = try NativeScrollFixture(rows: 8)
        defer { fixture.close() }
        var sample: ChatViewportTrace.Sample?
        fixture.position.diagnosticSink = { sample = $0 }
        fixture.position.recordDiagnostic(.watchdog, force: true)
        let value = try XCTUnwrap(sample)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ChatViewportTraceWriter(directory: root, maximumBytes: 8192)
        try await writer.append(Array(repeating: value, count: 30))
        // A new writer must honor sizes left by an earlier app launch too.
        try await ChatViewportTraceWriter(directory: root, maximumBytes: 8192).append([value])
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["chat-viewport.jsonl", "chat-viewport.previous.jsonl"])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, 8192)
            XCTAssertFalse(data.isEmpty)
            for line in data.split(separator: 0x0a) { _ = try decoder.decode(ChatViewportTrace.Sample.self, from: Data(line)) }
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
        let queueRoot = root.appendingPathComponent("queue")
        let recorder = ChatViewportTrace(writer: ChatViewportTraceWriter(directory: queueRoot), capacity: 2)
        recorder.setEnabled(true)
        for _ in 0..<10 { recorder.record(value) }
        XCTAssertEqual(recorder.dropped, 8)
        let output = queueRoot.appendingPathComponent("chat-viewport.jsonl")
        try await TestSupport.eventually(timeout: .seconds(5)) {
            guard let data = try? Data(contentsOf: output) else { return false }
            return data.split(separator: 0x0a).count == 3
        }
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("\"event\":\"dropped\""))
        XCTAssertTrue(text.contains("\"count\":8"))
    }

    func testViewportTraceRecordsPostMountHiddenRowsAndTheScrollThatRevealsThem() async throws {
        // The observed failure: right after remounting, the lazy stack keeps
        // its realized rows mounted but hidden, until the reader scrolls.
        let position = ChatScrollPosition()
        var samples: [ChatViewportTrace.Sample] = []
        position.diagnosticSink = { samples.append($0) }
        let fixture = try NativeScrollFixture(rows: 8, position: position)
        defer { fixture.close() }
        position.hasContent = { true }
        fixture.markers.forEach { $0.isHidden = true }
        try await TestSupport.eventually(timeout: .seconds(2)) { samples.contains { $0.event == .mountBlank } }
        let blank = try XCTUnwrap(samples.first { $0.event == .mountBlank })
        XCTAssertLessThan(try XCTUnwrap(blank.sinceAttach), 1, "Recorded before the watchdog's two-interval escalation")
        XCTAssertEqual(blank.markers.mounted, 8)
        XCTAssertEqual(blank.markers.hidden, 8)
        XCTAssertEqual(blank.markers.visible, 0)
        XCTAssertEqual(blank.markers.rows.count, 8, "Hidden rows keep their frames in the record")
        XCTAssertTrue(blank.markers.rows.allSatisfy(\.hidden))
        XCTAssertEqual(blank.markers.rows.map(\.frame.y), (0..<8).map { Double($0) * 300 })
        fixture.position.userWillScroll(deltaY: -20)
        let firstScroll = try XCTUnwrap(samples.last { $0.event == .userScroll }, "The scroll that ends a blank is sampled despite throttling")
        XCTAssertEqual(firstScroll.markers.visible, 0)
        XCTAssertFalse(samples.contains { $0.event == .mountRecovered })
        // As SwiftUI does once it observes the reader's scroll.
        fixture.markers.forEach { $0.isHidden = false }
        fixture.move(to: 40)
        let recovered = try XCTUnwrap(samples.last { $0.event == .mountRecovered })
        XCTAssertGreaterThan(recovered.markers.visible, 0)
        XCTAssertLessThan(try XCTUnwrap(recovered.wheelAge), 1, "The record attributes recovery to the reader")
        XCTAssertEqual(samples.filter { $0.event == .mountRecovered }.count, 1)
    }

    func testPostMountHiddenRowsRebuildOnceWithoutWaitingForWheelOrWatchdog() async throws {
        // Switching to a busy chat tab: the remounted lazy stack is already at
        // its destination but keeps only hidden rows, so an item scroll is a
        // no-op. The reader must not have to scroll to see the transcript.
        let position = ChatScrollPosition()
        var attempts: [(ChatScrollPosition.Anchor?, Bool)] = []
        position.hasContent = { true }
        position.recoverViewport = { attempts.append(($0, $1)) }
        let fixture = try NativeScrollFixture(rows: 8, position: position)
        defer { fixture.close() }
        fixture.markers.forEach { $0.isHidden = true }
        try await TestSupport.eventually(timeout: .milliseconds(1000)) { !attempts.isEmpty }
        XCTAssertEqual(attempts.map(\.1), [true])
        XCTAssertEqual(position.interactionRevision, 0, "Recovery is not user scrolling")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(attempts.count, 1, "One rebuild per mount")
    }

    func testViewportTraceReportsSwiftUIScrollGeometryAndRowCategoriesWithoutText() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "viewport-trace-rows"; session.showChat = true
        session.turns = (0..<12).map { index in
            ChatTurn(id: "turn-\(index)", items: [
                .init(id: "question-\(index)", kind: .user, text: "Secret question \(index)"),
                .init(id: "tool-\(index)", kind: .tool, text: "{\"command\":\"ls secret\"}", title: "Bash", output: "secret.txt", completed: true),
                .init(id: "answer-\(index)", kind: .assistant, text: "Secret answer \(index)\n\n" + String(repeating: "Private paragraph.\n\n", count: 3))])
        }
        var samples: [ChatViewportTrace.Sample] = []
        session.scrollPosition.diagnosticSink = { samples.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { session.scrollPosition.disconnect(); window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually(timeout: .seconds(3)) { samples.contains { $0.event == .mountCheck } }
        let sample = try XCTUnwrap(samples.last { $0.event == .mountCheck })
        let clip = try XCTUnwrap(sample.clip)
        if #available(macOS 15, *) {
            // SwiftUI's view of the same viewport; a disagreement is the signal.
            let swiftUI = try XCTUnwrap(sample.swiftUI)
            XCTAssertEqual(swiftUI.containerHeight, clip.height, accuracy: 1)
            XCTAssertEqual(swiftUI.visibleY, clip.y, accuracy: 1)
            XCTAssertEqual(swiftUI.contentHeight, try XCTUnwrap(sample.document).height, accuracy: 48)
        }
        let rows = sample.markers.rows
        XCTAssertFalse(rows.isEmpty)
        let count = session.visibleTranscriptRows.count
        XCTAssertTrue(rows.allSatisfy { ($0.index ?? -1) >= 0 && ($0.index ?? count) < count })
        XCTAssertTrue(rows.contains { $0.index == count - 1 }, "Opening at the bottom includes the last row")
        XCTAssertTrue(Set(rows.compactMap(\.kind)).isSubset(of: ["user", "assistant", "tool", "tool-expanded", "group", "group-expanded"]))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(samples), as: UTF8.self).lowercased().contains("secret"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(samples), as: UTF8.self).contains("Private"))
    }

    func testBlankViewportRecoversDespiteContinuousLayoutUpdates() async throws {
        let fixture = try NativeScrollFixture(rows: 8)
        defer { fixture.close() }
        fixture.move(to: 750)
        try await Task.sleep(for: .milliseconds(60))
        let anchor = try XCTUnwrap(fixture.position.visibleAnchor())
        fixture.position.hasContent = { true }
        var attempts: [(ChatScrollPosition.Anchor?, Bool)] = []
        fixture.position.recoverViewport = { attempts.append(($0, $1)) }
        fixture.markers.forEach { $0.removeFromSuperview() }
        fixture.position.restore(anchor)
        let start = ProcessInfo.processInfo.systemUptime
        for second in 0...4 {
            // Keep a layout adjustment queued at every watchdog check, as can
            // happen while new messages stream into an empty lazy viewport.
            fixture.position.geometryChanged()
            fixture.position.checkViewport(now: start + Double(second))
        }
        XCTAssertEqual(attempts.first?.0, anchor)
        XCTAssertEqual(attempts.first?.1, false)
        XCTAssertEqual(attempts.last?.1, true, "Layout churn must not starve viewport recovery")
        XCTAssertEqual(fixture.position.interactionRevision, 0)
    }

    func testIdleViewportDetectsMissingRowsAndEscalatesRecoveryWithoutWheelInput() async throws {
        let fixture = try NativeScrollFixture(rows: 8)
        defer { fixture.close() }
        fixture.move(to: 750)
        try await Task.sleep(for: .milliseconds(60))
        let anchor = try XCTUnwrap(fixture.position.visibleAnchor())
        var attempts: [(ChatScrollPosition.Anchor?, Bool)] = []
        fixture.position.hasContent = { true }
        fixture.position.recoverViewport = { attempts.append(($0, $1)) }
        // Preserve the document extent but remove the mounted row range, as can
        // happen when a lazy transcript invalidates its realized content.
        fixture.markers.forEach { $0.removeFromSuperview() }
        // A restoration can also stall after its first realization request if
        // the lazy stack produces no subsequent geometry notification.
        fixture.position.restore(anchor)
        try await TestSupport.eventually(timeout: .seconds(9)) { attempts.contains { $0.1 } }
        XCTAssertEqual(attempts.first?.0, anchor)
        XCTAssertEqual(attempts.first?.1, false, "Realize the retained row before rebuilding")
        XCTAssertEqual(attempts.last?.0, anchor)
        XCTAssertEqual(fixture.position.interactionRevision, 0, "Recovery is not user scrolling")
        let count = attempts.count
        fixture.markers.forEach { fixture.document.addSubview($0) }
        try await Task.sleep(for: .milliseconds(60))
        fixture.position.checkViewport(redraw: true)
        XCTAssertEqual(attempts.count, count, "Healthy content must not be rebuilt")
        XCTAssertEqual(fixture.position.visibleAnchor(), anchor)
    }

    func testViewportRecoveryIgnoresEmptyHiddenAndActivelyScrolledContentAndDisconnects() async throws {
        let fixture = try NativeScrollFixture(rows: 8)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(60))
        fixture.markers.forEach { $0.removeFromSuperview() }
        var attempts = 0
        fixture.position.recoverViewport = { _, _ in attempts += 1 }
        try await Task.sleep(for: .milliseconds(850))
        let now = ProcessInfo.processInfo.systemUptime
        fixture.position.hasContent = { false }
        for index in 0..<4 { fixture.position.checkViewport(now: now + Double(index)) }
        fixture.position.hasContent = { true }
        fixture.scroll.isHidden = true
        for index in 0..<4 { fixture.position.checkViewport(now: now + Double(index)) }
        fixture.scroll.isHidden = false
        fixture.position.scrollbar?.beganDragging?()
        for index in 0..<4 { fixture.position.checkViewport(now: now + Double(index)) }
        fixture.position.scrollbar?.endedDragging?()
        fixture.position.userWillScroll(deltaY: 10)
        for _ in 0..<4 { fixture.position.checkViewport() }
        XCTAssertEqual(attempts, 0)
        fixture.position.disconnect()
        fixture.position.checkViewport(redraw: true)
        XCTAssertNil(fixture.position.hasContent)
        XCTAssertNil(fixture.position.recoverViewport)
        XCTAssertEqual(attempts, 0)
    }

    func testTranscriptRebuildAndWakePreserveReadingPositionDraftAndIdleThinking() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "viewport-recovery"; session.showChat = true; session.active = true; session.busy = true
        session.draft = "Keep my unfinished reply"
        session.turns = (0..<30).map { index in
            ChatTurn(id: "turn-\(index)", items: [.init(id: "answer-\(index)", kind: .assistant,
                text: "Recovered answer \(index)\n\n" + String(repeating: "Visible transcript content.\n\n", count: 3))])
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { session.scrollPosition.disconnect(); window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: XCTUnwrap(window.contentView))
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
        let document = try XCTUnwrap(scroll.documentView)
        session.scrollPosition.userWillScroll(deltaY: 240)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(400))
        let anchor = try XCTUnwrap(session.scrollPosition.visibleAnchor())
        XCTAssertFalse(session.atBottom)
        let originalMarker = try XCTUnwrap(PresentationTestSupport.views(of: ChatScrollMarker.Marker.self, in: document)
            .first { $0.id == anchor.id })
        session.scrollPosition.recoverViewport?(anchor, true)
        try await TestSupport.eventually(timeout: .seconds(5)) {
            guard let restored = session.scrollPosition.visibleAnchor() else { return false }
            return originalMarker.window == nil && restored.id == anchor.id && abs(restored.offset - anchor.offset) < 2
        }
        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.makeKeyAndOrderFront(nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(session.scrollPosition.visibleAnchor()?.id, anchor.id)
        XCTAssertEqual(try XCTUnwrap(session.scrollPosition.visibleAnchor()).offset, anchor.offset, accuracy: 2)
        XCTAssertEqual(session.draft, "Keep my unfinished reply")
        XCTAssertTrue(session.busy)
        let snapshot = try await PresentationTestSupport.capture(window, named: "idle-viewport-recovered", in: "chat-scroll-stability-validation")
        XCTAssertTrue(try snapshot.text().contains("Visible transcript content"))
        session.atBottom = true
        session.scrollPosition.recoverViewport?(nil, true)
        try await TestSupport.eventually(timeout: .seconds(5)) {
            session.scrollPosition.visibleAnchor() != nil && session.scrollPosition.isAtBottom(tolerance: 24) == true
        }
        XCTAssertEqual(session.draft, "Keep my unfinished reply")
    }

    func testDefaultSystemFontKeepsBottomFollowingAndExpandedToolScrollingStable() async throws {
        let previous = ChatThemeStore.shared.current
        defer { ChatThemeStore.shared.current = previous }
        var preferences = Preferences()
        XCTAssertEqual(preferences.chatFont, .system)
        ChatThemeStore.shared.current.typography = ChatTypography(preferences: preferences)
        XCTAssertEqual(ChatThemeStore.shared.current.typography.reply.familyName, NSFont.systemFont(ofSize: 12).familyName)
        try await testBottomFollowingSurvivesLargeRepliesAndStopsWhenReadingHistory()
        try await testExpandedToolsKeepMessagesStableWhileScrollingBothDirections()
    }

    func testHistoryPrefetchAnticipatesFastScrollingButStaysBounded() async throws {
        let position = ChatScrollPosition()
        XCTAssertEqual(position.earlierPrefetchDistance, 2400)
        position.observedHistoryRead(seconds: .nan)
        position.observedHistoryRead(seconds: .infinity)
        position.observedHistoryRead(seconds: -1)
        position.userWillScroll(deltaY: 150)
        XCTAssertEqual(position.earlierPrefetchDistance, 3150, accuracy: 1)
        position.observedHistoryRead(seconds: 1)
        XCTAssertEqual(position.earlierPrefetchDistance, 4800, "Read latency must extend the lead, capped at twelve viewports")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(position.earlierPrefetchDistance, 2400, "Idle views must return to the six-screen buffer")
        position.userWillScroll(deltaY: -100)
        XCTAssertEqual(position.earlierPrefetchDistance, 2400)
        position.userWillScroll(deltaY: 10000)
        XCTAssertEqual(position.earlierPrefetchDistance, 4800)
    }

    func testOpeningHistoryPreloadFillsShortContentAndStopsAtItsViewportTarget() async throws {
        let fixture = try NativeScrollFixture(rows: 2, rowHeight: 150)
        defer { fixture.close() }
        fixture.position.followsBottom = { true }
        var requests = 0
        fixture.position.loadEarlier = { userInitiated in
            XCTAssertFalse(userInitiated, "Opening must build a reserve without wheel input")
            requests += 1
            fixture.document.frame.size.height += 1400
            for marker in fixture.markers { marker.frame.origin.y += 1400 }
            fixture.position.historyLoadFinished(madeProgress: true)
            return true
        }
        fixture.position.beginOpeningHistoryPreload()
        XCTAssertEqual(requests, 0, "Initial content must get a layout before loading more")
        try await waitForHistoryCondition { requests >= 2 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(requests, 2, "Enough scroll reserve must stop loading before the four-batch cap")
        XCTAssertGreaterThanOrEqual(fixture.scroll.contentView.bounds.minY, fixture.position.earlierPrefetchDistance)
        XCTAssertEqual(fixture.position.isAtBottom(tolerance: 1), true)
    }

    func testOpeningHistoryPreloadCountsAcceptedLoadsAndCapsInvisibleProgress() async throws {
        let fixture = try NativeScrollFixture(rows: 2, rowHeight: 150)
        defer { fixture.close() }
        var ready = false, accepted = 0, attempts = 0
        fixture.position.loadEarlier = { _ in
            attempts += 1
            guard ready else { return false }
            accepted += 1
            // Tool-only or ignored records can advance history without changing
            // native document geometry. Completion must still continue the fill.
            fixture.position.historyLoadFinished(madeProgress: true)
            return true
        }
        fixture.position.beginOpeningHistoryPreload()
        try await waitForHistoryCondition { attempts > 0 }
        XCTAssertEqual(accepted, 0)
        ready = true
        fixture.position.geometryChanged()
        try await waitForHistoryCondition { accepted == 4 }
        fixture.position.geometryChanged()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(accepted, 4, "Rejected readiness checks must not spend the four accepted loads")

        var wheelRequests = 0
        fixture.position.loadEarlier = { userInitiated in
            if userInitiated { wheelRequests += 1 }
            return false
        }
        fixture.position.userWillScroll(deltaY: 1)
        XCTAssertEqual(wheelRequests, 1, "Automatic limits must not block explicit upward scrolling")
    }

    func testOpeningHistoryPreloadContinuesAfterRestorationAndStopsWithoutProgress() async throws {
        let fixture = try NativeScrollFixture(rows: 6)
        defer { fixture.close() }
        fixture.move(to: 750)
        let anchor = try XCTUnwrap(fixture.position.visibleAnchor())
        fixture.position.preserveForPrepend()
        fixture.document.frame.size.height += 300
        for marker in fixture.markers { marker.frame.origin.y += 300 }
        var requests = 0
        fixture.position.loadEarlier = { _ in
            XCTAssertFalse(fixture.position.isRestoring)
            requests += 1
            if requests == 1 {
                fixture.position.preserveForPrepend()
                fixture.document.frame.size.height += 300
                for marker in fixture.markers { marker.frame.origin.y += 300 }
            }
            fixture.position.historyLoadFinished(madeProgress: requests == 1)
            return true
        }
        fixture.position.beginOpeningHistoryPreload()
        XCTAssertEqual(requests, 0)
        try await waitForHistoryCondition { requests == 2 && !fixture.position.isRestoring }
        XCTAssertEqual(fixture.position.visibleAnchor(), anchor)
        fixture.position.geometryChanged()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(requests, 2, "A completed read without progress must not loop")
    }

    func testKeyboardNavigationRearmsExhaustedHistoryPreloadAndIgnoresComposer() async throws {
        let fixture = try NativeScrollFixture(rows: 2, rowHeight: 150)
        defer { fixture.close() }
        let content = NSView(frame: fixture.scroll.frame)
        fixture.window.contentView = content
        content.addSubview(fixture.scroll)
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        content.addSubview(composer)
        let transcriptResponder = NavigationResponderView(frame: .zero)
        fixture.document.addSubview(transcriptResponder)

        var requests: [Bool] = [], userScrolls = 0
        fixture.position.userScrolled = { userScrolls += 1 }
        fixture.position.loadEarlier = { userInitiated in
            requests.append(userInitiated)
            fixture.position.historyLoadFinished(madeProgress: true)
            return true
        }
        fixture.position.beginOpeningHistoryPreload()
        try await waitForHistoryCondition { requests.count == 4 }
        XCTAssertEqual(requests, [false, false, false, false])

        XCTAssertTrue(fixture.window.makeFirstResponder(composer))
        XCTAssertNil(composer.enclosingScrollView)
        let pageUp = TerminalTestSupport.keyEvent(116, "\u{f72c}", in: fixture.window)
        fixture.position.handleScrollEvent(pageUp)
        fixture.position.geometryChanged()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(requests.count, 4, "Composer navigation must not rearm exhausted transcript preloading")
        XCTAssertEqual(userScrolls, 0, "Composer navigation must preserve transcript following")

        XCTAssertTrue(fixture.window.makeFirstResponder(transcriptResponder))
        XCTAssertTrue(transcriptResponder.enclosingScrollView === fixture.scroll)
        fixture.position.handleScrollEvent(pageUp)
        try await waitForHistoryCondition { requests.count == 9 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(Array(requests.dropFirst(4)), [true, false, false, false, false],
            "Keyboard navigation must request upward history and restore four automatic loads")
        XCTAssertEqual(userScrolls, 1, "Keyboard navigation must relinquish transcript following")
    }

    func testOpeningHistoryPreloadStopsAtEOFOrErrorAndRejectsConcurrentReads() async throws {
        for fails in [false, true] {
            let fixture = try NativeScrollFixture(rows: 2, rowHeight: 150)
            defer { fixture.close() }
            var hasEarlier = true, loading = false, error = false, requests = 0
            fixture.position.loadEarlier = { _ in
                guard hasEarlier, !loading, !error else { return false }
                loading = true; requests += 1
                return true
            }
            fixture.position.beginOpeningHistoryPreload()
            try await waitForHistoryCondition { requests == 1 }
            fixture.position.geometryChanged()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(requests, 1)
            loading = false
            error = fails; hasEarlier = fails
            fixture.position.historyLoadFinished(madeProgress: !fails)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(requests, 1, "EOF and errors must stop automatic history requests")
        }
    }

    func testDisconnectCancelsQueuedOpeningPreloadAndRequiresNewAppearance() async throws {
        let fixture = try NativeScrollFixture(rows: 2, rowHeight: 150)
        defer { fixture.close() }
        var requests = 0
        fixture.position.loadEarlier = { _ in requests += 1; return true }
        fixture.position.beginOpeningHistoryPreload()
        fixture.position.disconnect()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(requests, 0)
        XCTAssertNil(fixture.position.loadEarlier)
        fixture.position.loadEarlier = { _ in
            requests += 1
            fixture.position.historyLoadFinished(madeProgress: false)
            return true
        }
        for marker in fixture.markers { fixture.position.register(marker, id: marker.id) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(requests, 0, "Reattaching native markers must not restart an old view's budget")
        fixture.position.beginOpeningHistoryPreload()
        try await waitForHistoryCondition { requests == 1 }
    }

    func testPassiveHistoryKeepsBottomUnlessUserMovesWhileReadIsPending() async throws {
        let sessionID = UUID().uuidString
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-opening-history-\(sessionID).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        func line(_ type: String, _ payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload]) + Data([10])
        }
        var data = try line("session_meta", ["id": sessionID])
        for index in 0..<600 {
            data += try line("event_msg", ["type": "agent_message", "turn_id": "turn", "message": "Reply \(index)"])
        }
        let root = path.deletingLastPathComponent().appendingPathComponent("dispatch-opening-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        for userMoves in [false, true] {
            let coordinator = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
            defer { coordinator.stop() }
            let session = try await coordinator.archived(lines, agent: "codex", session: sessionID, in: root)
            XCTAssertNil(session.status); XCTAssertTrue(session.hasEarlier)
            let fixture = try NativeScrollFixture(rows: 6, position: session.scrollPosition)
            defer { fixture.close() }
            let rows = session.visibleTranscriptRows
            XCTAssertGreaterThanOrEqual(rows.count, fixture.markers.count)
            for (marker, row) in zip(fixture.markers, rows) { marker.update(id: row.id, position: fixture.position) }
            session.followRevision = session.revision
            fixture.position.followsBottom = { session.atBottom && session.followRevision != nil }
            fixture.position.userScrolled = { session.followRevision = nil }
            fixture.position.geometryChanged()
            try await waitForHistoryCondition { fixture.position.isAtBottom(tolerance: 1) == true }
            XCTAssertTrue(coordinator.loadEarlier(session, preservingBottom: true))
            XCTAssertTrue(session.loadingEarlier)
            if userMoves {
                fixture.position.userWillScroll(deltaY: 40)
                fixture.move(to: 750)
            }
            let anchor = try XCTUnwrap(fixture.position.visibleAnchor())
            try await waitForHistoryCondition { !session.loadingEarlier }
            XCTAssertNil(session.earlierError)
            // Model publication precedes native layout. Apply that later height
            // change only after the real coordinator has chosen how to retain it.
            fixture.document.frame.size.height += 600
            for marker in fixture.markers { marker.frame.origin.y += 600 }
            fixture.position.geometryChanged()
            try await waitForHistoryCondition { !fixture.position.isRestoring }
            if userMoves {
                XCTAssertEqual(fixture.position.visibleAnchor(), anchor, "An earlier follow decision must not undo intervening user movement")
                XCTAssertEqual(fixture.position.isAtBottom(tolerance: 1), false)
            } else {
                XCTAssertEqual(fixture.position.isAtBottom(tolerance: 1), true)
            }
        }
    }

    private func waitForHistoryCondition(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "History did not reach the expected settled state", file: file, line: line)
    }

    func testBottomFollowingSurvivesLargeRepliesAndStopsWhenReadingHistory() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "bottom-follow"; session.showChat = true
        session.turns = (0..<20).map { index in
            ChatTurn(id: "turn-\(index)", items: [.init(id: "answer-\(index)", kind: .assistant,
                text: String(repeating: "An earlier answer with several lines of text.\n\n", count: 3))])
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: XCTUnwrap(window.contentView))
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
        let bar = try XCTUnwrap(session.scrollPosition.scrollbar)
        var viewportWidth = scroll.contentView.bounds.width
        func assertStableScrollbar(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(scroll.hasVerticalScroller, file: file, line: line)
            XCTAssertTrue(session.scrollPosition.scrollbar === bar, file: file, line: line)
            XCTAssertEqual(bar.frame.width, 14, accuracy: 0.25, file: file, line: line)
            XCTAssertEqual(bar.frame.maxX, scroll.bounds.maxX, accuracy: 0.25, file: file, line: line)
            XCTAssertEqual(bar.frame.height, scroll.bounds.height, accuracy: 0.25, file: file, line: line)
            XCTAssertEqual(bar.thumb.frame.size, bar.bounds.size, file: file, line: line)
            XCTAssertEqual(scroll.contentView.frame.width, scroll.bounds.width, accuracy: 0.25, file: file, line: line)
            XCTAssertEqual(scroll.contentView.bounds.width, viewportWidth, accuracy: 0.25, file: file, line: line)
        }
        func assertBottom(file: StaticString = #filePath, line: UInt = #line) {
            assertStableScrollbar(file: file, line: line)
            XCTAssertTrue(session.atBottom, file: file, line: line)
            let remaining = (scroll.documentView?.bounds.maxY ?? 0) - scroll.contentView.bounds.maxY
            // The bottom scroll target precedes the transcript's 22-point padding.
            XCTAssertLessThanOrEqual(remaining, 24, "Newest reply must stay visible; gap=\(remaining)", file: file, line: line)
        }
        /// A new row reaches the bottom by gliding with its fade, not in the frame it arrives.
        func assertBottomAfterGlide(file: StaticString = #filePath, line: UInt = #line) async throws {
            try await TestSupport.eventually(timeout: .seconds(1)) { !session.scrollPosition.glidesToBottom }
            assertBottom(file: file, line: line)
        }
        assertBottom()
        XCTAssertFalse(bar.revealed)
        session.active = true; session.busy = true; session.activeTurnID = "live"
        session.insert(.init(id: "prompt", kind: .user, text: "Explain the result"), turnID: "live")
        for part in 1...6 {
            session.insert(.init(id: "reply", kind: .assistant,
                text: String(repeating: "A streamed reply containing **formatted text** and more explanation.\n\n", count: part * 8)), turnID: "live")
            try await Task.sleep(for: .milliseconds(100))
            try await assertBottomAfterGlide()
            XCTAssertFalse(bar.revealed, "Streaming must never reveal the scrollbar")
        }
        // Neither an idle gap nor subsequent output should reveal the thumb.
        try await Task.sleep(for: .milliseconds(1500))
        assertBottom()
        _ = try await PresentationTestSupport.capture(window, named: "interaction-streaming-scrollbar", in: "chat-scroll-stability-validation")
        // Wheel input near the bottom cancels queued following, but must not
        // invalidate the observed bottom state on each bounce/momentum event.
        let bottomChanges = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = session.atBottom
        } onChange: { bottomChanges.withLock { $0 += 1 } }
        let bottomY = try XCTUnwrap(scroll.documentView).bounds.maxY - scroll.contentView.bounds.height
        for offset in [0.0, -16, -8, -1, 0, -1, 0] {
            session.scrollPosition.userWillScroll(deltaY: offset < 0 ? 1 : -1)
            XCTAssertNil(session.followRevision, "Wheel input must cancel pending automatic following")
            XCTAssertTrue(session.atBottom, "Input alone must not change measured bottom proximity")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottomY + offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertTrue(session.atBottom)
        }
        XCTAssertEqual(bottomChanges.withLock { $0 }, 0, "Bottom bounce must not invalidate SwiftUI's bottom state")
        session.scrollPosition.userWillScroll(deltaY: 240)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 240))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(session.atBottom)
        assertStableScrollbar()
        XCTAssertTrue(bar.revealed, "User scrolling reveals the thumb")
        _ = try await PresentationTestSupport.capture(window, named: "interaction-visible-scrollbar", in: "chat-scroll-stability-validation")
        let reading = scroll.contentView.bounds.minY
        session.insert(.init(id: "later", kind: .assistant, text: String(repeating: "Later output.\n\n", count: 15)), turnID: "live")
        XCTAssertNil(session.followRevision, "Live output must not re-arm following after scrolling away")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(scroll.contentView.bounds.minY, reading, accuracy: 1)
        XCTAssertFalse(session.atBottom)
        session.scrollPosition.jumpToLatest()
        try await Task.sleep(for: .milliseconds(100))
        session.insert(.init(id: "last", kind: .assistant, text: String(repeating: "Follow again.\n\n", count: 15)), turnID: "live")
        try await Task.sleep(for: .milliseconds(150))
        try await assertBottomAfterGlide()
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertFalse(bar.revealed)
        // SwiftUI owns the scroll view layout. Exercise both widening and
        // narrowing the real window while live output follows the bottom.
        for size in [NSSize(width: 1200, height: 750), NSSize(width: 650, height: 550), NSSize(width: 440, height: 550), NSSize(width: 240, height: 550), NSSize(width: 1000, height: 650)] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(150))
            viewportWidth = scroll.contentView.bounds.width
            assertBottom()
            XCTAssertFalse(bar.revealed, "Resizing must not reveal the thumb")
        }

    }

    func testScrollbarVisibilityFollowsInteractionNotDocumentUpdates() async throws {
        let fixture = try NativeScrollFixture()
        defer { fixture.close() }
        let bar = try XCTUnwrap(fixture.position.scrollbar)
        XCTAssertFalse(bar.revealed)
        let width = fixture.scroll.contentView.bounds.width
        fixture.move(to: 750)
        XCTAssertFalse(bar.revealed, "Programmatic movement stays quiet")
        bar.thumb.doubleValue = 0.5
        XCTAssertTrue(bar.thumb.sendAction(bar.thumb.action, to: bar.thumb.target))
        XCTAssertEqual(fixture.scroll.contentView.bounds.minY,
            (fixture.document.bounds.height - fixture.scroll.contentView.bounds.height) * 0.5, accuracy: 0.25)

        fixture.position.userWillScroll(deltaY: -10)
        XCTAssertTrue(bar.revealed)
        for _ in 0..<8 {
            fixture.document.frame.size.height += 10
            fixture.position.geometryChanged()
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertFalse(bar.revealed, "Streaming must not extend the user's visibility timer")
        XCTAssertEqual(bar.thumb.alphaValue, 0, accuracy: 0.01)
        XCTAssertEqual(fixture.scroll.contentView.bounds.width, width)
        let entered = try PresentationTestSupport.mouseEvent(.leftMouseDown, in: fixture.window, at: .zero)
        bar.mouseEntered(with: entered)
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(bar.revealed, "Hover keeps the scrollbar available")
        bar.mouseExited(with: entered)
        bar.thumb.began?()
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(bar.revealed, "Dragging must outlive the idle timeout")
        XCTAssertTrue(fixture.position.isTrackingScroller)
        bar.thumb.ended?()
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertFalse(bar.revealed)
        XCTAssertFalse(fixture.position.isTrackingScroller)
        fixture.position.disconnect()
        XCTAssertNil(bar.superview)
    }

    func testExpandedToolsKeepMessagesStableWhileScrollingBothDirections() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "scroll-stability"; session.showChat = true; session.atBottom = false
        session.turns = (0..<80).map { index in
            ChatTurn(id: "turn-\(index)", items: [
                .init(id: "user-\(index)", kind: .user, text: "Inspect result \(index)"),
                .init(id: "answer-\(index)", kind: .assistant,
                      text: String(repeating: "A paragraph of reported output with **Markdown** and `code`.\n\n", count: index % 4 + 1)),
                .init(id: "tool-\(index)", kind: .tool, text: #"{"cmd":"printf test"}"#, title: "exec_command",
                      output: (0..<(index % 15 + 8)).map { "Output line \($0) for step \(index)" }.joined(separator: "\n"), completed: true, exitCode: 0)
            ])
        }
        // Tools following an assistant reply now live under that reply's group.
        // Expand the groups first, then the child cards the user can see.
        session.expandedToolGroups = Set(session.transcriptRows.compactMap { $0.group?.id })
        let tools = session.visibleTranscriptRows.filter { $0.item?.kind == .tool }
        XCTAssertEqual(tools.count, 80, "The scrolling fixture must include every tool's expanded output")
        session.expanded = Set(tools.map(\.id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false)
            .foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: XCTUnwrap(window.contentView))
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
        let document = try XCTUnwrap(scroll.documentView)
        func frames() -> [String: CGRect] {
            Dictionary(PresentationTestSupport.views(of: ChatScrollMarker.Marker.self, in: document).map {
                ($0.id, $0.convert($0.bounds, to: document).offsetBy(dx: 0, dy: -scroll.contentView.bounds.minY))
            }, uniquingKeysWith: { first, _ in first })
        }
        var samples: [[String: Any]] = [], jumps = 0, worst = 0.0, comparisons = 0
        for step in 0..<240 {
            if step == 120 {
                XCTAssertGreaterThan(session.toolLayouts.count, 0)
                ToolPresentationCache.shared.removeAll()
            }
            let down = step < 120
            let before = frames().filter { $0.value.maxY > 1 && $0.value.minY < scroll.contentView.bounds.height }
            let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: down ? -32 : 32, wheel2: 0, wheel3: 0))
            scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
            try await Task.sleep(for: .milliseconds(25))
            let after = frames()
            let movement = before.compactMap { id, frame in after[id].map { Double($0.minY - frame.minY) } }.sorted()
            let delta = movement.isEmpty ? Double(scroll.contentView.bounds.height) : movement[movement.count / 2]
            if !before.isEmpty {
                comparisons += 1; worst = max(worst, abs(delta))
                if abs(delta) > 96 || (down ? delta > 8 : delta < -8) { jumps += 1 }
            }
            samples.append(["step": step, "direction": down ? "down" : "up", "visibleMessageMovement": delta,
                            "commonRows": movement.count, "scrollY": scroll.contentView.bounds.minY,
                            "documentHeight": document.bounds.height])
        }
        let output = CodexTestSupport.root.appendingPathComponent("build/chat-scroll-stability-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["samples": samples, "jumps": jumps, "worstMessageMovement": worst], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("expanded-tools.json"))
        _ = try await PresentationTestSupport.capture(window, named: "expanded-tools-final", in: "chat-scroll-stability-validation")
        XCTAssertGreaterThan(comparisons, 200)
        XCTAssertEqual(jumps, 0, "32-point wheel input must not skip visible messages; worst movement \(worst) points")

        // Recreating Chat should also preserve an offset inside expanded output,
        // rather than scrolling past its temporary header while formatting loads.
        let tool = try XCTUnwrap(PresentationTestSupport.views(of: ChatScrollMarker.Marker.self, in: document)
            .first { $0.id.hasSuffix(":tool-0") && $0.bounds.height > 120 })
        let toolY = tool.convert(tool.bounds, to: document).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: toolY + 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(150))
        let anchor = try XCTUnwrap(session.scrollPosition.visibleAnchor())
        XCTAssertEqual(anchor.id, tool.id)
        window.contentView = nil
        ToolPresentationCache.shared.removeAll()
        session.atBottom = false
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false)
            .foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        try await Task.sleep(for: .milliseconds(500))
        let restored = try XCTUnwrap(session.scrollPosition.visibleAnchor())
        XCTAssertEqual(restored.id, anchor.id)
        XCTAssertEqual(restored.offset, anchor.offset, accuracy: 1)
    }

    func testPrependingHistoryDuringWheelScrollingKeepsVisibleMessagesContinuous() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.sessionID = "prepend-continuity"; session.showChat = true
        func turns(_ range: Range<Int>) -> [ChatTurn] {
            range.map { index in
                ChatTurn(id: "turn-\(index)", items: [
                    .init(id: "user-\(index)", kind: .user, text: "Explain result \(index)"),
                    .init(id: "answer-\(index)", kind: .assistant,
                          text: String(repeating: "A paragraph with **formatted text** and `code`.\n\n", count: index % 4 + 1))
                ])
            }
        }
        session.turns = turns(15..<210)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: XCTUnwrap(window.contentView))
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
        let document = try XCTUnwrap(scroll.documentView)
        func frames() -> [String: CGRect] {
            Dictionary(PresentationTestSupport.views(of: ChatScrollMarker.Marker.self, in: document).map {
                ($0.id, $0.convert($0.bounds, to: document).offsetBy(dx: 0, dy: -scroll.contentView.bounds.minY))
            }, uniquingKeysWith: { first, _ in first })
        }
        for step in 0..<120 {
            let before = frames().filter { $0.value.maxY > 1 && $0.value.minY < scroll.contentView.bounds.height }
            XCTAssertFalse(before.isEmpty, "The viewport must contain message markers")
            session.scrollPosition.userWillScroll(deltaY: 32)
            if step == 60 {
                session.scrollPosition.preserveForPrepend()
                withTransaction(Transaction(animation: nil)) {
                    session.turns.insert(contentsOf: turns(0..<15), at: 0)
                    session.historyRevision += 1
                }
                session.scrollPosition.restoreAfterPrepend()
            }
            let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                              wheel1: 32, wheel2: 0, wheel3: 0))
            scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
            try await Task.sleep(for: .milliseconds(20))
            let after = frames()
            let movement = before.compactMap { id, frame in after[id].map { $0.minY - frame.minY } }.sorted()
            XCTAssertFalse(movement.isEmpty, "Prepending must not lose every visible message at step \(step)")
            if !movement.isEmpty {
                let delta = movement[movement.count / 2]
                XCTAssertGreaterThanOrEqual(delta, -8, "History must not move the viewport against wheel intent")
                XCTAssertLessThanOrEqual(delta, 96, "A 32-point wheel step must not jump over messages")
            }
        }
        XCTAssertEqual(session.turns.count, 210)
        XCTAssertFalse(session.scrollPosition.isRestoring)
    }

    func testScrollbarTrackingDefersPrependAndPreservesItsFinalReadingPosition() async throws {
        let fixture = try NativeScrollFixture()
        defer { fixture.close() }
        fixture.move(to: 750)
        let before = try XCTUnwrap(fixture.position.visibleAnchor())
        let bar = try XCTUnwrap(fixture.position.scrollbar)
        let point = fixture.scroll.convert(NSPoint(x: bar.frame.midX, y: bar.frame.midY), to: nil)
        fixture.position.handleScrollEvent(try PresentationTestSupport.mouseEvent(.leftMouseDown, in: fixture.window, at: point))
        XCTAssertTrue(fixture.position.isTrackingScroller)
        let height = fixture.document.frame.height
        var applied = 0
        fixture.position.performAfterScrolling {
            applied += 1
            fixture.position.preserveForPrepend()
            fixture.document.frame.size.height += 600
            for marker in fixture.markers { marker.frame.origin.y += 600 }
            fixture.position.geometryChanged()
        }
        XCTAssertEqual(applied, 0); XCTAssertEqual(fixture.document.frame.height, height)
        fixture.move(to: 1150)
        let dragged = try XCTUnwrap(fixture.position.visibleAnchor())
        XCTAssertNotEqual(dragged.id, before.id)
        fixture.position.handleScrollEvent(try PresentationTestSupport.mouseEvent(.leftMouseUp, in: fixture.window, at: point))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(applied, 1); XCTAssertFalse(fixture.position.isTrackingScroller)
        let restored = try XCTUnwrap(fixture.position.visibleAnchor())
        XCTAssertEqual(restored, dragged, "Prepend preserves where the reader finished dragging, not where the fetch began")
        XCTAssertFalse(fixture.position.isRestoring)
    }

    func testLivePrependRetainsPixelsWhenFirstVisibleMarkerIsRecycled() throws {
        let fixture = try NativeScrollFixture()
        defer { fixture.close() }
        fixture.move(to: 750)
        fixture.position.userWillScroll(deltaY: 40)
        let first = try XCTUnwrap(fixture.position.visibleAnchor())
        fixture.position.preserveForPrepend()
        try XCTUnwrap(fixture.markers.first { $0.id == first.id }).removeFromSuperview()
        fixture.document.frame.size.height += 600
        for marker in fixture.markers { marker.frame.origin.y += 600 }
        fixture.position.geometryChanged()
        XCTAssertEqual(fixture.scroll.contentView.bounds.minY, 1350, accuracy: 0.25)
        XCTAssertNotNil(fixture.position.visibleAnchor())
    }

    func testLateItemScrollCannotUndoAPrependedPixelAnchor() throws {
        let fixture = try NativeScrollFixture()
        defer { fixture.close() }
        fixture.move(to: 750)
        let anchor = try XCTUnwrap(fixture.position.visibleAnchor())
        fixture.position.preserveForPrepend()
        fixture.document.frame.size.height += 600
        for marker in fixture.markers { marker.frame.origin.y += 600 }
        fixture.position.geometryChanged()
        XCTAssertEqual(fixture.position.visibleAnchor(), anchor)
        // Item-ID scrolling can arrive after layout has already restored the
        // prepend. Its clip-only change must not discard the within-row offset.
        fixture.move(to: 1300)
        XCTAssertEqual(fixture.position.visibleAnchor(), anchor)
        fixture.position.userWillScroll(deltaY: 40)
        fixture.move(to: 1310)
        XCTAssertEqual(fixture.scroll.contentView.bounds.minY, 1310, accuracy: 0.25)
    }

    func testLiveScrollingCancelsStalePreservationAndFollowIntent() async throws {
        let fixture = try NativeScrollFixture()
        defer { fixture.close() }
        fixture.move(to: 750)
        fixture.position.preserveForPrepend()
        var follow = true
        fixture.position.userScrolled = { follow = false }
        let revision = fixture.position.interactionRevision
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scroll)
        XCTAssertFalse(follow); XCTAssertFalse(fixture.position.isRestoring)
        XCTAssertNotEqual(fixture.position.interactionRevision, revision)
        var pageApplied = false
        fixture.position.performAfterScrolling { pageApplied = true }
        XCTAssertTrue(pageApplied, "Wheel gestures must not hold ready history until release")
        fixture.move(to: 1150)
        fixture.position.geometryChanged()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.scroll.contentView.bounds.minY, 1150, accuracy: 0.25)
        fixture.position.handleScrollEvent(try PresentationTestSupport.mouseEvent(.leftMouseUp, in: fixture.window, at: .zero))
        XCTAssertTrue(pageApplied)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: fixture.scroll)
        XCTAssertTrue(pageApplied)
    }

    func testDisconnectReleasesDeferredHistoryWork() throws {
        let fixture = try NativeScrollFixture()
        defer { fixture.close() }
        let bar = try XCTUnwrap(fixture.position.scrollbar)
        let point = fixture.scroll.convert(NSPoint(x: bar.frame.midX, y: bar.frame.midY), to: nil)
        fixture.position.handleScrollEvent(try PresentationTestSupport.mouseEvent(.leftMouseDown, in: fixture.window, at: point))
        var applied = false
        fixture.position.performAfterScrolling { applied = true }
        XCTAssertFalse(applied)
        fixture.position.disconnect()
        XCTAssertTrue(applied)
        XCTAssertFalse(fixture.position.isTrackingScroller)
    }

    func testReusedMarkerTracksItsCurrentMessageAndChat() throws {
        let fixture = try NativeScrollFixture()
        defer { fixture.close() }
        fixture.move(to: 750)
        let marker = fixture.markers[2]
        marker.update(id: "replacement-message", position: fixture.position)
        XCTAssertEqual(fixture.position.visibleAnchor(), .init(id: "replacement-message", offset: -150))

        let replacement = ChatScrollPosition()
        defer { replacement.disconnect() }
        marker.update(id: "other-chat-message", position: replacement)
        XCTAssertEqual(replacement.visibleAnchor(), .init(id: "other-chat-message", offset: -150))
        XCTAssertEqual(fixture.position.visibleAnchor()?.id, "row-3", "The previous chat must not retain a reused row")
    }

    func testPrependRetainsTheNextVisibleMessageWhenTheFirstRowBecomesAGroup() async throws {
        let fixture = try NativeScrollFixture()
        defer { fixture.close() }
        fixture.move(to: 750)
        // Pagination can replace a single tool row with a collapsed tool group.
        let removed = fixture.markers[2]
        fixture.position.preserveForPrepend(retaining: Set(fixture.markers.map(\.id)).subtracting([removed.id]))
        fixture.position.unregister(removed, id: removed.id)
        removed.removeFromSuperview()
        fixture.document.frame.size.height += 600
        for marker in fixture.markers { marker.frame.origin.y += 600 }
        fixture.position.geometryChanged()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.position.visibleAnchor(), .init(id: "row-3", offset: 150))
        XCTAssertFalse(fixture.position.isRestoring)
    }

    @MainActor private final class NativeScrollFixture {
        let position: ChatScrollPosition
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 380, height: 3000))
        let window: NSWindow
        var markers: [ChatScrollMarker.Marker] = []
        init(rows: Int = 10, rowHeight: CGFloat = 300, position: ChatScrollPosition? = nil) throws {
            try DesktopTestSupport.requireUnlocked()
            self.position = position ?? ChatScrollPosition()
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scroll.hasVerticalScroller = true; scroll.scrollerStyle = .legacy
            document.frame.size.height = CGFloat(rows) * rowHeight
            scroll.documentView = document; window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            for index in 0..<rows {
                let marker = ChatScrollMarker.Marker(id: "row-\(index)", position: self.position)
                marker.frame = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: 380, height: rowHeight)
                document.addSubview(marker); markers.append(marker)
                self.position.register(marker, id: marker.id)
            }
        }
        func move(to y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        func close() { position.disconnect(); window.orderOut(nil); window.contentView = nil; window.close() }
    }
    private final class NavigationResponderView: NSView { override var acceptsFirstResponder: Bool { true } }
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
}
