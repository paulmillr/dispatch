import AppKit
import CryptoKit
import Darwin
import QuartzCore
import SwiftUI
import XCTest
@testable import DispatchApp

/// Opt-in hardware benchmark. The input lives in build/, never in the repository's
/// fixtures: a personal conversation is copied into an isolated Codex home.
@MainActor
final class ChatScrollBenchmarkTests: XCTestCase {
    private let directory = CodexTestSupport.root.appendingPathComponent("build/chat-scroll-benchmark")

    /// Synthetic local history: 20 user messages, each followed by ten agent
    /// replies with 10 or 20 tool calls. No CLI or external model is involved.
    func testDenseAgenticHistoryPaging() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        for steps in [10, 20] {
            let id = UUID().uuidString
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("dense-scroll-\(id).jsonl")
            defer { try? FileManager.default.removeItem(at: path) }
            var data = Data()
            func line(_ type: String, _ payload: [String: Any]) throws {
                data.append(try JSONSerialization.data(withJSONObject: ["type": type,
                    "timestamp": "2000-01-01T00:00:00.000Z", "payload": payload], options: [.sortedKeys]))
                data.append(10)
            }
            try line("session_meta", ["id": id, "cli_version": "0.154.0"])
            for turn in 0..<20 {
                let turnID = "turn-\(turn)"
                try line("event_msg", ["type": "task_started", "turn_id": turnID])
                try line("event_msg", ["type": "user_message", "turn_id": turnID, "message": "Investigate task \(turn)"])
                for reply in 0..<10 {
                    try line("event_msg", ["type": "agent_message", "turn_id": turnID,
                        "message": "Reply \(turn)/\(reply): inspecting the implementation and checking the results.\n\nThis is a synthetic benchmark paragraph with **formatting** and `code`."])
                    for step in 0..<steps {
                        let call = "call-\(turn)-\(reply)-\(step)"
                        try line("response_item", ["type": "function_call", "turn_id": turnID,
                            "call_id": call, "name": "exec_command", "arguments": "{\"cmd\":\"rg example Sources\"}"])
                        try line("response_item", ["type": "function_call_output", "turn_id": turnID,
                            "call_id": call, "output": String(repeating: "Sources/Example.swift:42: synthetic tool output\n", count: 40)])
                    }
                }
                try line("event_msg", ["type": "task_complete", "turn_id": turnID])
            }
            try data.write(to: path)
            // The harness reads the rollout (chat.page); each earlier page is timed as the app sees it.
            let coordinator = ChatCoordinator(enabled: false)
            defer { coordinator.stop() }
            let probe = try await coordinator.archived(path, agent: "codex", session: id)
            var readTimes: [Double] = [], records: [Int] = []
            while probe.hasEarlier {
                let before = probe.turns.flatMap(\.items).count
                readTimes.append(try await coordinator.earlier(probe))
                records.append(probe.turns.flatMap(\.items).count - before)
            }
            let session = try await coordinator.archived(path, agent: "codex", session: id)
            session.showChat = true
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator,
                                                                 focused: false, floatingSwitch: false))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: XCTUnwrap(window.contentView))
                .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
            session.atBottom = false
            session.scrollPosition.cancelPreservation()
            var gestures: [[String: Any]] = []
            for _ in 0..<6 {
                guard session.hasEarlier else { break }
                // Start at the production prefetch boundary and keep an upward
                // gesture active for one second, including time at the top.
                let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(360, maximum)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(100))
                guard session.hasEarlier else { break }
                let revision = session.historyRevision
                let start = CACurrentMediaTime()
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
                var topFrames = 0, loadingFrames = 0, maxAnchorMovement = 0.0, lostAnchors = 0
                var jumps: [[String: Any]] = []
                for _ in 0..<60 {
                    let document = try XCTUnwrap(scroll.documentView)
                    let oldY = scroll.contentView.bounds.minY
                    let oldHeight = document.bounds.height
                    let oldRevision = session.historyRevision
                    let oldAnchor = session.scrollPosition.visibleAnchor()
                    let before = Dictionary(PresentationTestSupport.views(of: ChatScrollMarker.Marker.self, in: document).compactMap { marker -> (String, CGFloat)? in
                        let frame = marker.convert(marker.bounds, to: document).offsetBy(dx: 0, dy: -scroll.contentView.bounds.minY)
                        return frame.maxY > 1 && frame.minY < scroll.contentView.bounds.height ? (marker.id, frame.minY) : nil
                    }, uniquingKeysWith: { first, _ in first })
                    session.scrollPosition.userWillScroll(deltaY: 40)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scroll.contentView.bounds.minY - 40)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    if scroll.contentView.bounds.minY <= 1 { topFrames += 1 }
                    if session.loadingEarlier { loadingFrames += 1 }
                    try await Task.sleep(for: .milliseconds(16))
                    if !before.isEmpty {
                        let movements = PresentationTestSupport.views(of: ChatScrollMarker.Marker.self, in: document).compactMap { marker -> Double? in
                            guard let offset = before[marker.id] else { return nil }
                            return Double(marker.convert(marker.bounds, to: document).minY - scroll.contentView.bounds.minY - offset)
                        }.sorted()
                        if movements.isEmpty {
                            lostAnchors += 1
                            jumps.append(["lostAnchor": true, "oldY": oldY, "newY": scroll.contentView.bounds.minY,
                                "oldHeight": oldHeight, "newHeight": document.bounds.height,
                                "oldRevision": oldRevision, "revision": session.historyRevision,
                                "before": before, "restoring": session.scrollPosition.isRestoring,
                                "rows": session.visibleTranscriptRows.map(\.id),
                                "mounted": PresentationTestSupport.views(of: ChatScrollMarker.Marker.self, in: document).map(\.id)])
                        }
                        else {
                            let movement = abs(movements[movements.count / 2])
                            maxAnchorMovement = max(maxAnchorMovement, movement)
                            // A page shorter than the viewport leaves blank
                            // space below it. Removing that blank space on the
                            // first prepend necessarily clamps the clip offset.
                            XCTAssertLessThanOrEqual(movement, 80 + Double(max(0, scroll.contentView.bounds.height - oldHeight)))
                            if movement > 80 {
                                jumps.append(["oldY": oldY, "newY": scroll.contentView.bounds.minY,
                                    "oldHeight": oldHeight, "newHeight": document.bounds.height,
                                    "oldRevision": oldRevision, "revision": session.historyRevision,
                                    "anchor": oldAnchor?.id ?? "none", "before": before,
                                    "movements": movements, "restoring": session.scrollPosition.isRestoring])
                            }
                        }
                    }
                }
                let held = CACurrentMediaTime() - start
                let publishedDuringGesture = session.historyRevision - revision
                let release = CACurrentMediaTime()
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
                try await TestSupport.eventually(timeout: .seconds(10)) { !session.loadingEarlier }
                window.contentView?.layoutSubtreeIfNeeded()
                let releaseMs = (CACurrentMediaTime() - release) * 1000
                try await Task.sleep(for: .milliseconds(150))
                gestures.append(["heldMs": held * 1000, "topFrames": topFrames, "loadingFrames": loadingFrames,
                    "publishedDuringGesture": publishedDuringGesture, "releaseToLayoutMs": releaseMs,
                    "publishedAfterRelease": session.historyRevision - revision, "rows": session.visibleTranscriptRows.count,
                    "maxAnchorMovement": maxAnchorMovement, "lostAnchors": lostAnchors, "jumps": jumps])
                XCTAssertGreaterThan(publishedDuringGesture, 0, "Ready history must appear during the gesture")
                XCTAssertGreaterThan(session.historyRevision, revision)
                XCTAssertEqual(lostAnchors, 0)
            }
            let sorted = readTimes.sorted()
            let report: [String: Any] = ["stepsPerReply": steps, "userMessages": 20, "repliesPerUser": 10,
                "sourceBytes": data.count, "earlierPages": readTimes.count, "readMs": readTimes,
                "readP50Ms": sorted[sorted.count / 2], "readP95Ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
                "readMaxMs": sorted.last!, "recordsPerPage": records, "gestures": gestures,
                "note": "Local synthetic file; collapsed tool groups; controlled live-scroll notifications and 40pt steps; release includes apply and synchronous layout, not physical display latency"]
            let results = ProcessInfo.processInfo.environment["DISPATCH_BENCHMARK_OUTPUT"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("dense")
            } ?? CodexTestSupport.root.appendingPathComponent("build/dense-scroll-validation")
            try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: results.appendingPathComponent("dense-\(steps).json"))
            print("DENSE SCROLL BENCHMARK", String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
        }
    }

    /// Opt-in, synthetic 500 MiB reader + native UI benchmark. The fixture is
    /// streamed by benchmark-long-chat.py, outside the measured process.
    func testLargeSyntheticConversation() async throws {
        let output = CodexTestSupport.root.appendingPathComponent("build/long-chat-benchmark")
        let input = output.appendingPathComponent("input.json")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("Run scripts/benchmark-long-chat.py") }
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [String: Any])
        let path = try XCTUnwrap(config["path"] as? String), id = try XCTUnwrap(config["session"] as? String)
        let label = try XCTUnwrap(config["label"] as? String)
        let pageLimit = try XCTUnwrap(config["pages"] as? Int)
        let livePages = config["livePages"] as? Bool == true
        let desktopUnlocked = ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue != true
        AppFont.register()
        try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier])
            .write(to: output.appendingPathComponent("ready.json"), options: .atomic)
        if config["profile"] as? Bool == true { try await Task.sleep(for: .seconds(3)) }
        func rss() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.resident_size : 0
        }
        func summary(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            func p(_ value: Double) -> Double { sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * value)] }
            return ["p50Ms": p(0.5), "p95Ms": p(0.95), "maxMs": p(1), "totalMs": values.reduce(0, +)]
        }
        // The harness reads the transcript (chat.page); the app times opening and each earlier page.
        // Configuration, activity and bytes read are the harness's (codex benchmarks); reported as 0.
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let before = rss(), start = CACurrentMediaTime()
        let session = try await coordinator.archived(URL(fileURLWithPath: path), agent: "codex", session: id, timeout: .seconds(120))
        session.showChat = true
        let openMs = (CACurrentMediaTime() - start) * 1000
        let initialBytes = 0, configurationMs = 0.0, activityMs = 0.0
        let afterOpen = rss()
        var reads: [Double] = [], applies: [Double] = [], rowTimes: [Double] = [], rssPages: [UInt64] = []
        func measureRows() {
            guard config["measureHistoryRows"] as? Bool == true else { return }
            let start = CACurrentMediaTime()
            _ = session.visibleTranscriptRows
            rowTimes.append((CACurrentMediaTime() - start) * 1000)
        }
        func items() -> Int { session.turns.reduce(0) { $0 + $1.items.count } }
        var records = items()
        measureRows()
        for _ in 0..<pageLimit where session.hasEarlier {
            // A page's read and merge are one helper round trip here (no separate apply time).
            reads.append(try await coordinator.earlier(session))
            records = items()
            measureRows()
            rssPages.append(rss())
        }
        let livePagesLeft = session.hasEarlier
        // Normally freeze pagination for repeatable retained-history comparisons.
        // Live mode starts with the recent page and measures fetching during scrolling.
        session.hasEarlier = livePages && livePagesLeft
        var mountMs = 0.0
        var scrollResult: [String: Any] = ["skipped": "Desktop locked"]
        if desktopUnlocked {
            let mountStart = CACurrentMediaTime()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false)
                .overlay(alignment: .bottom) {
                    if config["reconnectOverlay"] as? Bool == true {
                        SSHReconnectControl(state: .init(), reconnect: {}, cancel: {}, wheel: { session.scrollPosition.forwardWheel($0) })
                            .frame(width: 116, height: 30).padding(.bottom, 10)
                    }
                })
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            mountMs = (CACurrentMediaTime() - mountStart) * 1000
            try await Task.sleep(for: .milliseconds(500))
            let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: XCTUnwrap(window.contentView))
                .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
            XCTAssertTrue(NSApp.isActive && window.isKeyWindow, "Scrolling benchmarks must be foregrounded")
            let historyBeforeScrolling = session.historyRevision
            let turnsBeforeScrolling = session.turns.count
            if !livePages { XCTAssertFalse(session.hasEarlier, "Fixed-history scrolling must not enable pagination") }
            session.atBottom = false
            let frames = ScrollFrames(scroll: scroll, window: window, position: session.scrollPosition,
                                      measureContinuity: false, pauseBetweenGestures: livePages,
                                      liveSession: livePages ? session : nil, speed: config["speed"] as? Double ?? 2400)
            scrollResult = await frames.run(seconds: config["duration"] as? Double ?? 5)
            XCTAssertGreaterThan(frames.distance, 100)
            XCTAssertTrue(NSApp.isActive && window.isKeyWindow, "Benchmark lost foreground focus")
            scrollResult["foregroundVerified"] = NSApp.isActive && window.isKeyWindow
            scrollResult["historyPublishedDuringScroll"] = session.historyRevision - historyBeforeScrolling
            scrollResult["turnsAddedDuringScroll"] = session.turns.count - turnsBeforeScrolling
            if livePages {
                XCTAssertGreaterThan(session.historyRevision, 0, "Live scrolling must actually prepend history")
                XCTAssertNil(session.earlierError)
                records = session.seen.count
            } else {
                XCTAssertEqual(session.historyRevision, historyBeforeScrolling, "Fixed-history scrolling must not prepend history")
                XCTAssertEqual(session.turns.count, turnsBeforeScrolling, "Fixed-history scrolling must retain the same turns")
            }
            window.orderOut(nil); window.contentView = nil
        }
        var scanPages = 0, scanRecords = 0
        let scanStart = CACurrentMediaTime()
        if config["scanAll"] as? Bool == true {
            session.hasEarlier = livePagesLeft
            while session.hasEarlier {
                let before = items()
                _ = try await coordinator.earlier(session)
                if session.earlierError != nil { break }
                scanPages += 1; scanRecords += items() - before
            }
        }
        let scanMs = (CACurrentMediaTime() - scanStart) * 1000
        if !livePages, !session.hasEarlier, let expected = config["expectedRecords"] as? Int {
            XCTAssertEqual(records + scanRecords, expected, "Every synthetic record must remain reachable")
        }
        // An archived chat is not polled; the live tail is the harness's.
        let polls: [Double] = []
        let result: [String: Any] = ["label": label, "sourceBytes": try FileManager.default.attributesOfItem(atPath: path)[.size]!,
            "profiled": config["profile"] as? Bool ?? false, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "openMs": openMs, "initialBytesRead": initialBytes, "configurationMs": configurationMs, "activityMs": activityMs,
            "read": summary(reads), "readMs": reads, "apply": summary(applies), "applyMs": applies,
            "measureHistoryRows": config["measureHistoryRows"] as? Bool ?? false,
            "rows": summary(rowTimes), "rowsMs": rowTimes,
            "rssBefore": before, "rssAfterOpen": afterOpen, "rssAfterPages": rssPages, "rssAfter": rss(),
            "retainedRecords": records, "retainedTurns": session.turns.count, "retainedRows": session.visibleTranscriptRows.count,
            "mountMs": mountMs, "scroll": scrollResult, "poll": summary(polls),
            "remainingScanPages": scanPages, "remainingScanRecords": scanRecords,
            "remainingScanMs": scanMs, "hasEarlier": session.hasEarlier]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(label + ".json"), options: .atomic)
        if config["profile"] as? Bool == true { try await Task.sleep(for: .seconds(32)) }
        print("LONG CHAT BENCHMARK \(label): open \(openMs) ms, page \(summary(reads)), apply \(summary(applies))")
    }

    func testLocalTmuxConversationScrolling() async throws {
        let input = directory.appendingPathComponent("input.json")
        guard FileManager.default.fileExists(atPath: input.path) else {
            print("CHAT SCROLL BENCHMARK: opt in with scripts/benchmark-chat-scroll.py")
            return
        }
        struct Input: Decodable {
            let transcript: String; let label: String; let duration: Double
            var expandedTools: Bool?; var width: Double?; var measureContinuity: Bool?
        }
        let config = try JSONDecoder().decode(Input.self, from: Data(contentsOf: input))
        let source = URL(fileURLWithPath: config.transcript)
        var sourceData = try Data(contentsOf: source)
        let sourceBytes = sourceData.count
        let header = Data(sourceData.prefix(while: { $0 != 10 }))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: header) as? [String: Any])
        let payload = try XCTUnwrap(metadata["payload"] as? [String: Any])
        let conversation = try XCTUnwrap(payload["id"] as? String)
        let hash = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        let endpoint = try CodexEndpointFixture(prefix: "dispatch-scroll-", delay: 0.05, hooks: false)
        defer { endpoint.stop(removeState: true) }
        try await endpoint.start(timeout: .seconds(15))
        let day = String(try XCTUnwrap(payload["timestamp"] as? String).prefix(10))
        _ = try XCTUnwrap(day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression))
        let destination = endpoint.state.appendingPathComponent("codex-home/sessions/" + day.replacingOccurrences(of: "-", with: "/"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try sourceData.write(to: destination.appendingPathComponent(source.lastPathComponent))
        sourceData = Data()
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough()
        defer { app.close() }
        if let width = config.width { app.window.setContentSize(NSSize(width: width, height: 740)) }
        if let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
            app.window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - app.window.frame.width / 2,
                                             y: screen.visibleFrame.midY - app.window.frame.height / 2))
        }
        let command = CodexTestSupport.command(state: endpoint.state, binary: endpoint.binary, resume: conversation)
        _ = try app.server(["send-keys", "-t", "%0", command, "Enter"])
        try await app.attach(); try await app.ready()
        let session = runtime.chat.session(for: try XCTUnwrap(app.workspace.activeSurfaceID))
        // A personal rollout records the original directory. Keep this resume
        // inside the fixture's already-trusted empty working directory.
        try await TestSupport.eventually(timeout: .seconds(15)) {
            if session.sessionID == conversation { return true }
            return try app.server(["capture-pane", "-p", "-t", "%0"]).contains("Choose working directory to resume this session")
        }
        if session.sessionID != conversation {
            _ = try app.server(["send-keys", "-t", "%0", "Down", "Enter"])
        }
        do {
            try await TestSupport.eventually(timeout: .seconds(45)) {
                session.active && session.sessionID == conversation && !session.loadingHistory && !session.turns.isEmpty
            }
        } catch {
            print("SCROLL STARTUP", session.status as Any, session.sessionID as Any, session.process as Any)
            print(try app.server(["capture-pane", "-p", "-t", "%0"]))
            throw error
        }
        runtime.chat.chooseChat(true, session: session)
        try await Task.sleep(for: .seconds(1))
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: XCTUnwrap(app.window.contentView))
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
        session.atBottom = false
        session.scrollPosition.cancelPreservation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["pid": getpid(), "label": config.label]).write(to: directory.appendingPathComponent("ready.json"))
        print("CHAT SCROLL READY", getpid(), "bytes", sourceBytes, "sha256", hash)
        for pass in 0..<3 {
            if pass == 1 {
                while session.hasEarlier {
                    runtime.chat.loadEarlier(session)
                    try await TestSupport.eventually(timeout: .seconds(15)) { !session.loadingEarlier }
                    XCTAssertNil(session.earlierError)
                    if session.earlierError != nil { break }
                }
                if config.expandedTools == true {
                    let rows: [ChatTranscriptRow] = session.transcriptRows.flatMap { $0.group?.children ?? [$0] }
                    let tools = rows.filter { $0.item?.kind == .tool }.suffix(2)
                    session.expanded.formUnion(tools.map(\.id))
                    session.expandedToolGroups.formUnion(tools.compactMap(\.toolGroupID))
                }
            }
            if pass > 0 {
                session.atBottom = true; session.scrollPosition.jumpToLatest()
                try await Task.sleep(for: .milliseconds(500))
                session.atBottom = false; session.scrollPosition.cancelPreservation()
            }
            let name = config.label + "-" + ["paging", "history-cold", "history-warm"][pass]
            let historyRevision = session.historyRevision
            let sampler = ScrollFrames(scroll: scroll, window: app.window, position: session.scrollPosition,
                                       measureContinuity: config.measureContinuity == true,
                                       pauseBetweenGestures: pass == 0 && config.measureContinuity == true)
            let result = await sampler.run(seconds: config.duration)
            var report: [String: Any] = ["name": name, "conversation": conversation, "sourceBytes": sourceBytes,
                "sourceSHA256": hash, "turns": session.turns.count, "rows": session.visibleTranscriptRows.count,
                "hasEarlier": session.hasEarlier, "modelRequests": requestCount(endpoint), "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "expandedTools": session.expanded.count,
                "historyPagesPublished": session.historyRevision - historyRevision,
                "runtimeCheckers": (ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":")
                    .filter { $0.contains("MainThreadChecker") || $0.contains("RPAC") }.map(String.init)]
            report.merge(result) { _, value in value }
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: directory.appendingPathComponent(name + ".json"))
            print("CHAT SCROLL RESULT", name, result.filter { !($0.value is [Double]) && $0.key != "discontinuities" })
            XCTAssertGreaterThan(sampler.distance, 1000, "The workload must actually scroll")
            if config.measureContinuity == true {
                if pass == 0 { XCTAssertGreaterThan(session.historyRevision, historyRevision, "Continuity sampling must include actual history publication") }
                XCTAssertGreaterThan(sampler.messageMovements.count, 100)
                XCTAssertEqual(sampler.lostVisibleAnchors, 0, "A wheel step must not skip every visible message")
                XCTAssertLessThanOrEqual(sampler.messageMovements.map { abs($0) }.max() ?? 0, 160,
                                         "Compare message positions, since pagination can legitimately change document coordinates")
            }
        }
        XCTAssertEqual(requestCount(endpoint), 0, "Reading and scrolling history must not request a model response")
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined(), hash)
    }

    private func requestCount(_ endpoint: CodexEndpointFixture) -> Int {
        (try? String(contentsOf: endpoint.state.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").count) ?? 0
    }
}

/// Display-paced wheel input, with a late run-loop observer recording work
/// through layout/display submission. Neither measure claims physical scanout.
@MainActor
final class ScrollFrames: NSObject {
    let scroll: NSScrollView
    let window: NSWindow
    let position: ChatScrollPosition
    var distance = 0.0
    private var gaps: [Double] = [], work: [Double] = [], positions: [Double] = []
    private var previous = 0.0, pending = 0.0, start = 0.0
    private var direction: Int32 = 1
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var peak: UInt64 = 0
    private let measureContinuity: Bool
    private let pauseBetweenGestures: Bool
    private let liveSession: ChatSession?
    private let speed: Double
    private var boundarySeconds = 0.0, loadingNearEdgeSeconds = 0.0, loadingSeconds = 0.0
    private var wasBlocked = false, wasLoadingNearEdge = false, wasLoading = false
    private var waitStart: Double?, waits: [Double] = []
    private var firstVisibleTurn: Int?, oldestVisibleTurn: Int?
    private var initialHistoryRevision = 0, initialTurnCount = 0
    private var previousAnchor: ChatScrollPosition.Anchor?
    private var previousPixels = 0.0
    private var anchorJumps = 0, maxAnchorJump = 0.0
    private var visibleFrames: [String: CGRect] = [:]
    private(set) var messageMovements: [Double] = []
    private(set) var lostVisibleAnchors = 0
    private var discontinuities: [[String: Any]] = []

    init(scroll: NSScrollView, window: NSWindow, position: ChatScrollPosition, measureContinuity: Bool, pauseBetweenGestures: Bool, liveSession: ChatSession? = nil, speed: Double = 2400) {
        self.scroll = scroll; self.window = window; self.position = position; self.measureContinuity = measureContinuity
        self.pauseBetweenGestures = pauseBetweenGestures
        self.liveSession = liveSession; self.speed = speed
    }

    func run(seconds: Double) async -> [String: Any] {
        let before = resident(), cpu = cpuTime()
        peak = before; start = CACurrentMediaTime()
        initialHistoryRevision = liveSession?.historyRevision ?? 0
        initialTurnCount = liveSession?.turns.count ?? 0
        let link = window.displayLink(target: self, selector: #selector(tick))
        self.link = link
        let fps = Float(window.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.pending > 0 else { return }
                self.work.append(CACurrentMediaTime() - self.pending); self.pending = 0
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        link.add(to: .main, forMode: .common)
        try? await Task.sleep(for: .seconds(seconds))
        link.invalidate(); self.link = nil
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes); observer = nil
        let elapsed = CACurrentMediaTime() - start
        if let waitStart { waits.append(CACurrentMediaTime() - waitStart) }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] * 1000
        }
        return ["elapsed": elapsed, "displayMaxFPS": fps, "displayScale": window.backingScaleFactor,
            "displayName": window.screen?.localizedName ?? "Unknown",
            "windowWidth": window.frame.width, "windowHeight": window.frame.height,
            "callbacks": positions.count, "callbackHz": Double(positions.count) / elapsed,
            "gapP50Ms": percentile(gaps, 0.5), "gapP95Ms": percentile(gaps, 0.95), "gapMaxMs": percentile(gaps, 1),
            "workP50Ms": percentile(work, 0.5), "workP95Ms": percentile(work, 0.95), "workMaxMs": percentile(work, 1),
            "workP99Ms": percentile(work, 0.99),
            "workOver120Budget": work.filter { $0 > 1.0 / 120 }.count,
            "lateDisplayIntervals": gaps.filter { $0 > 1.5 / Double(fps) }.count,
            "rssBefore": before, "rssAfter": resident(), "rssPeak": peak, "cpuSeconds": cpuTime() - cpu,
            "livePages": liveSession != nil, "speed": speed,
            "boundaryWaitSeconds": boundarySeconds, "boundaryWaitEpisodes": waits.count,
            "boundaryWaitMaxMs": (waits.max() ?? 0) * 1000,
            "loadingNearEdgeSeconds": loadingNearEdgeSeconds, "loadingSeconds": loadingSeconds,
            "pagesPublished": (liveSession?.historyRevision ?? 0) - initialHistoryRevision,
            "turnsAdded": (liveSession?.turns.count ?? 0) - initialTurnCount,
            "visibleTurnsTraversed": max(0, (firstVisibleTurn ?? 0) - (oldestVisibleTurn ?? 0)),
            "anchorJumps": anchorJumps, "maxAnchorJump": maxAnchorJump,
            "distance": distance, "gaps": gaps, "work": work, "positions": positions,
            "measureContinuity": measureContinuity, "messageMovements": messageMovements,
            "pauseBetweenGestures": pauseBetweenGestures,
            "discontinuities": discontinuities,
            "lostVisibleAnchors": lostVisibleAnchors,
            "maxMessageMovement": messageMovements.map { abs($0) }.max() ?? 0]
    }
    @objc private func tick(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        if previous > 0 {
            gaps.append(now - previous)
            if wasBlocked { boundarySeconds += now - previous }
            if wasLoadingNearEdge { loadingNearEdgeSeconds += now - previous }
            if wasLoading { loadingSeconds += now - previous }
        }
        if pending > 0 { work.append(now - pending) }
        pending = now; previous = now
        let old = scroll.contentView.bounds.minY
        if let session = liveSession {
            wasBlocked = old <= 2 && session.hasEarlier
            // Conservative exposure metric: loading within one viewport of
            // the history edge, including when the spinner is just offscreen.
            wasLoadingNearEdge = session.loadingEarlier && old < scroll.contentView.bounds.height
            wasLoading = session.loadingEarlier
            if wasBlocked, waitStart == nil { waitStart = now }
            if !wasBlocked, let began = waitStart { waits.append(now - began); waitStart = nil }
            if let before = previousAnchor, let after = position.visibleAnchor(retaining: [before.id]) {
                let shift = Double(after.offset - before.offset)
                // Only compare the same still-visible row. Upward input moves
                // it down; a prepend must not add a large unrelated displacement.
                let jump = max(-shift - 2, shift - previousPixels * 2 - 64)
                if jump > 0 { anchorJumps += 1; maxAnchorJump = max(maxAnchorJump, jump) }
            }
            previousAnchor = position.visibleAnchor()
            if let part = previousAnchor?.id.components(separatedBy: ":").first(where: { $0.hasPrefix("turn-") }),
               let turn = Int(part.dropFirst(5)) {
                firstVisibleTurn = firstVisibleTurn ?? turn
                oldestVisibleTurn = min(oldestVisibleTurn ?? turn, turn)
            }
        }
        // AppKit applies precise wheel scrolling after the event callback.
        // Include the movement since the preceding display, not only movement
        // synchronous with scrollWheel (which can correctly be zero).
        if let last = positions.last { distance += abs(old - last) }
        positions.append(old)
        if measureContinuity, let document = scroll.documentView {
            // Optional diagnostic work: leave it off for comparable frame-time
            // benchmarks, and retain viewport-relative movement for jump tests.
            let current = Dictionary(PresentationTestSupport.views(of: ChatScrollMarker.Marker.self, in: document).map {
                ($0.id, $0.convert($0.bounds, to: document).offsetBy(dx: 0, dy: -old))
            }, uniquingKeysWith: { first, _ in first })
            if !visibleFrames.isEmpty {
                let movement = visibleFrames.compactMap { id, frame in current[id].map { Double($0.minY - frame.minY) } }.sorted()
                if movement.isEmpty { lostVisibleAnchors += 1 }
                else { messageMovements.append(movement[movement.count / 2]) }
                if movement.isEmpty || abs(movement[movement.count / 2]) > 160 {
                    discontinuities.append(["frame": positions.count - 1, "scrollY": old, "documentHeight": document.bounds.height,
                        "rows": visibleFrames.map { id, frame -> [String: Any] in
                            ["id": id, "beforeY": frame.minY, "beforeHeight": frame.height,
                             "afterY": current[id]?.minY ?? -99999, "afterHeight": current[id]?.height ?? -99999]
                        }])
                }
            }
            visibleFrames = current.filter { $0.value.maxY > 1 && $0.value.minY < scroll.contentView.bounds.height }
        }
        let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        if liveSession != nil { direction = 1 }
        else if old < 50 { direction = -1 }
        else if old > maximum - 50 { direction = 1 }
        // Requested speed is independent of the display's refresh rate.
        let pixels = direction * Int32(max(1, speed * sender.duration))
        // Real readers pause between gestures. Continue measuring every display
        // frame during the pause, including the deferred history publication.
        previousPixels = 0
        if pauseBetweenGestures && (now - start).truncatingRemainder(dividingBy: 2) >= 1.4 { return }
        previousPixels = Double(abs(pixels))
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0),
           let event = NSEvent(cgEvent: cg) {
            // Directly delivered synthetic wheel events bypass AppKit's local
            // event monitor. Exercise the same transcript coordination callback
            // before every delivery, including fixed-history scrolling.
            position.userWillScroll(deltaY: event.scrollingDeltaY)
            scroll.scrollWheel(with: event)
        }
        if positions.count % 60 == 0 { peak = max(peak, resident()) }
    }
    private func resident() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    private func cpuTime() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
