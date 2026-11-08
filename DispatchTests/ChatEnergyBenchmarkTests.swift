import AppKit
import Darwin
import ObjectiveC
import QuartzCore
import SwiftUI
import XCTest
@testable import DispatchApp

/// Energy-relevant steady states of a shown chat, identical in the old and native transcript checkouts: idle at the
/// bottom, the agent busy without output, streaming while following and while reading history, idle in history,
/// scrolling and the rest after it. Each phase reports process and main-thread CPU, the kernel's CPU energy estimate
/// and wakeups (`proc_pid_rusage` v6), and main run-loop wakeups and busy time. A model-only phase streams to a session
/// no view shows; two plain passes repeat the phases; a profiled pass runs `/usr/bin/sample` on the test host during the
/// streaming phases and prints the report; a last, instrumented pass counts view layouts and layer redraws by class
/// (swizzled for the rest of the process, and the counting costs CPU: its CPU figures are not comparable). Disabled in
/// every suite: `python3 test/vm.py test ChatEnergyBenchmarkTests` (`--live` in a worktree), lines `CHAT_ENERGY {json}`.
/// The VM reports no energy or instruction counters; on a Mac they are the kernel's CPU estimates. docs/benchmarks.md.
@MainActor
final class ChatEnergyBenchmarkTests: XCTestCase {
    private static let phaseSeconds: Double = 10

    func testShownChatEnergyPhases() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let typing = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = typing }
        let readingHold = ChatSession.readingHoldEnabled
        ChatSession.readingHoldEnabled = true
        defer { ChatSession.readingHoldEnabled = readingHold }
        try await streamWithoutView()
        try await runPhases(pass: "plain")
        try await runPhases(pass: "plain-2")
        try await runPhases(pass: "profiled")
        RedrawCounter.install()
        RedrawCounter.enabled = true
        defer { RedrawCounter.enabled = false }
        try await runPhases(pass: "counted")
    }

    /// Three chat tabs in one pane of the real window. Only a pane's active tab is mounted, so each switch builds the chat
    /// it shows: switching every half second (latency until the chat shows its rows where its reader left them; the
    /// third tab's reader is in history), the rest after it, and a stream into a tab that is not shown.
    func testChatTabSwitchingEnergy() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let typing = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = typing }
        let readingHold = ChatSession.readingHoldEnabled
        ChatSession.readingHoldEnabled = true
        defer { ChatSession.readingHoldEnabled = readingHold }
        let app = try TmuxWalkthrough(); defer { app.close() }
        var tabs: [UUID] = []
        for index in 0..<3 {
            if index > 0 { app.workspace.newTab() }
            let surface = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await TestSupport.eventually(timeout: .seconds(15)) {
                app.runtime.views[surface].map { $0.window === app.window && !TerminalTestSupport.viewport(terminal: $0).isEmpty } == true
            }
            tabs.append(try XCTUnwrap(app.workspace.activeTab).id)
        }
        let sessions = tabs.enumerated().map { index, tab in
            let session = app.runtime.chat.session(for: tab)
            session.sessionID = "tab-energy-\(index)"
            session.turns = Self.fixture()
            session.setView(true, reason: "benchmark")
            return session
        }
        func show(_ index: Int) async throws -> Double {
            let start = CACurrentMediaTime()
            app.workspace.selectTab(tabs[index])
            try await TestSupport.eventually(timeout: .seconds(5), interval: .milliseconds(2)) {
                sessions[index].scrollPosition.showsRows() && !sessions[index].scrollPosition.isRestoring
            }
            return CACurrentMediaTime() - start
        }
        for index in [0, 1, 2] { _ = try await show(index) }
        let rows = sessions[2].visibleTranscriptRows
        let anchor = rows[max(0, rows.count - 60)].id
        sessions[2].scrollPosition.userWillScroll(deltaY: 1)
        sessions[2].atBottom = false; sessions[2].followRevision = nil
        sessions[2].scrollPosition.restore(.init(id: anchor, offset: 0))
        try await TestSupport.eventually { sessions[2].scrollPosition.visibleAnchor(retaining: [anchor]) != nil }
        try await Task.sleep(for: .seconds(2))

        func phase(_ pass: String, _ name: String, _ body: () async throws -> [String: Any]) async throws {
            let sample = EnergySample(document: nil)
            let extra = try await body()
            var line: [String: Any] = ["pass": pass, "phase": name]
            line.merge(sample.finish(document: nil)) { _, value in value }
            line.merge(extra) { _, value in value }
            print("CHAT_ENERGY " + String(decoding: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), as: UTF8.self))
        }
        var current = 2
        func switching(_ pass: String) async throws {
            try await phase(pass, "tab-switching") {
                var latencies: [Double] = []
                let end = CACurrentMediaTime() + Self.phaseSeconds
                while CACurrentMediaTime() < end {
                    let started = CACurrentMediaTime()
                    current = (current + 1) % tabs.count
                    latencies.append(try await show(current))
                    let rest = started + 0.5 - CACurrentMediaTime()
                    if rest > 0 { try await Task.sleep(for: .seconds(rest)) }
                }
                return ["switches": latencies.count, "latencies": latencies]
            }
        }
        for pass in ["plain", "plain-2"] {
            try await switching(pass)
            XCTAssertNotNil(sessions[2].scrollPosition.saved, "The third reader stays in history")
            try await phase(pass, "after-switching") { try await Task.sleep(for: .seconds(Self.phaseSeconds)); return [:] }
            let hidden = sessions[(current + 1) % tabs.count], turn = "live-" + pass
            hidden.active = true; hidden.busy = true; hidden.activeTurnID = turn
            try await phase(pass, "streaming-other-tab") {
                var text = "", updates = 0
                let end = CACurrentMediaTime() + Self.phaseSeconds
                while CACurrentMediaTime() < end {
                    text += "Streaming **reply** with `code` and results. "
                    hidden.insert(.init(id: turn + "-reply", kind: .assistant, text: text), turnID: turn)
                    updates += 1
                    try await Task.sleep(for: .milliseconds(50))
                }
                return ["updates": updates]
            }
            hidden.insert(.init(id: turn + "-done", kind: .assistant, text: "Done."), turnID: turn)
            hidden.busy = false; hidden.active = false
            try await Task.sleep(for: .seconds(1))
        }
        try await Self.sampled("tab-switching") { try await switching("profiled") }
        RedrawCounter.install()
        RedrawCounter.enabled = true
        defer { RedrawCounter.enabled = false }
        try await switching("counted")
    }

    /// Samples this process (a debuggable test host) with `/usr/bin/sample` for 8 s while `body` runs and prints the
    /// report between `CHAT_ENERGY_SAMPLE_BEGIN` and `CHAT_ENERGY_SAMPLE_END` lines.
    private static func sampled(_ name: String, _ body: () async throws -> Void) async throws {
        let file = System.temporary.appendingPathComponent("chat-energy-" + name + ".sample.txt")
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(getpid()), "8", "1", "-mayDie", "-file", file.path]
        sampler.standardOutput = FileHandle.nullDevice; sampler.standardError = FileHandle.nullDevice
        try TestSupport.start(sampler)
        try await body()
        while sampler.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        let report = (try? String(contentsOf: file, encoding: .utf8)) ?? "sample failed: \(sampler.terminationStatus)"
        print("CHAT_ENERGY_SAMPLE_BEGIN " + name); print(report); print("CHAT_ENERGY_SAMPLE_END " + name)
    }

    /// The model's share of streaming: the same updates to a session no view shows.
    private func streamWithoutView() async throws {
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: System.uuid())
        session.sessionID = "chat-energy-model"; session.showChat = true
        session.turns = Self.fixture()
        session.active = true; session.busy = true; session.activeTurnID = "live"
        var text = "", inserting: CFTimeInterval = 0
        let sample = EnergySample(document: nil)
        let end = CACurrentMediaTime() + Self.phaseSeconds
        while CACurrentMediaTime() < end {
            text += "Streaming **reply** with `code` and results. "
            let start = CACurrentMediaTime()
            session.insert(.init(id: "live-reply", kind: .assistant, text: text), turnID: "live")
            inserting += CACurrentMediaTime() - start
            try await Task.sleep(for: .milliseconds(50))
        }
        var line: [String: Any] = ["pass": "model", "phase": "streaming-no-view", "insertSeconds": inserting]
        line.merge(sample.finish(document: nil)) { _, value in value }
        print("CHAT_ENERGY " + String(decoding: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), as: UTF8.self))
    }

    private func runPhases(pass: String) async throws {
        ToolPresentationCache.shared.removeAll()
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: System.uuid())
        session.sessionID = "chat-energy"; session.showChat = true
        session.turns = Self.fixture()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 740),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator,
            focused: false, floatingSwitch: false).preferredColorScheme(.dark))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer {
            session.scrollPosition.disconnect()
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        try await TestSupport.eventually {
            session.scrollPosition.showsRows() && session.scrollPosition.isAtBottom(tolerance: 40) == true
        }
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: XCTUnwrap(window.contentView))
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
        let rows = session.visibleTranscriptRows
        try await Task.sleep(for: .seconds(2))

        var inserting: CFTimeInterval = 0
        func phase(_ name: String, seconds: Double = Self.phaseSeconds, during: (() async throws -> Void)? = nil) async throws {
            let sample = EnergySample(document: scroll.documentView)
            let insertedBefore = inserting
            if let during { try await during() } else { try await Task.sleep(for: .seconds(seconds)) }
            let result = sample.finish(document: scroll.documentView)
            var line: [String: Any] = ["pass": pass, "phase": name, "atBottom": session.scrollPosition.isAtBottom(tolerance: 40) as Any,
                                       "insertSeconds": inserting - insertedBefore]
            line.merge(result) { _, value in value }
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print("CHAT_ENERGY " + String(decoding: data, as: UTF8.self))
        }

        try await phase("idle-bottom")

        session.active = true; session.busy = true; session.activeTurnID = "live"
        session.insert(.init(id: "live-prompt", kind: .user, text: "Continue with the queued change."), turnID: "live")
        try await Task.sleep(for: .seconds(1))
        try await phase("busy-no-output")

        var text = ""
        var updates = 0
        func stream(for seconds: Double) async throws {
            let end = CACurrentMediaTime() + seconds
            while CACurrentMediaTime() < end {
                text += "Streaming **reply** with `code` and results. "
                let start = CACurrentMediaTime()
                session.insert(.init(id: "live-reply", kind: .assistant, text: text), turnID: "live")
                inserting += CACurrentMediaTime() - start
                updates += 1
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        func profiled(_ name: String, _ body: () async throws -> Void) async throws {
            if pass == "profiled" { try await Self.sampled(name, body) } else { try await body() }
        }
        try await phase("streaming-following") { try await profiled("streaming-following") { try await stream(for: Self.phaseSeconds) } }
        XCTAssertEqual(session.scrollPosition.isAtBottom(tolerance: 40), true, "Following keeps the bottom")

        session.scrollPosition.userWillScroll(deltaY: 1)
        session.atBottom = false; session.followRevision = nil
        let anchor = rows[max(0, rows.count - 60)].id
        session.scrollPosition.restore(.init(id: anchor, offset: 0))
        try await TestSupport.eventually {
            !session.scrollPosition.isRestoring && session.scrollPosition.visibleAnchor(retaining: [anchor]) != nil
        }
        try await phase("streaming-reading") { try await profiled("streaming-reading") { try await stream(for: Self.phaseSeconds) } }

        session.insert(.init(id: "live-done", kind: .assistant, text: "Done."), turnID: "live")
        session.busy = false; session.active = false
        try await Task.sleep(for: .seconds(1))
        try await phase("idle-reading")

        try await phase("wheel-scrolling") {
            let end = CACurrentMediaTime() + 3
            var index = 0
            while CACurrentMediaTime() < end {
                session.scrollPosition.userWillScroll(deltaY: 40)
                let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                  wheel1: index % 120 < 60 ? 40 : -40, wheel2: 0, wheel3: 0))
                scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
                index += 1
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        try await phase("after-scrolling")
        XCTAssertGreaterThan(updates, Int(Self.phaseSeconds * 2 * 10), "Streaming must run in both phases")
    }

    private static func fixture() -> [ChatTurn] {
        (0..<200).map { turn in
            let prose = (0..<(turn % 5 + 3)).map {
                "Paragraph \(turn)/\($0): inspect the queued changes, retain the reading position, and verify **formatted text** with `inline code`."
            }.joined(separator: "\n\n")
            let code = "\n\n```swift\n" + (0..<16).map { "let result\($0) = queue.flush(batch: \(turn + $0))" }.joined(separator: "\n") + "\n```"
            let table = "\n\n| Component | Result |\n|---|---|\n| Queue \(turn) | Checked |\n| Connection | Ready |\n| Renderer | Visible |"
            let output = (0..<12).map { "Sources/Queue\(turn).swift:\($0 + 1): result \(turn)/\($0)" }.joined(separator: "\n")
            return ChatTurn(id: "turn-\(turn)", items: [
                .init(id: "prompt-\(turn)", kind: .user, text: "Investigate change \(turn) and verify the result."),
                .init(id: "reply-\(turn)", kind: .assistant, text: prose + (turn % 3 == 0 ? code : "") + (turn % 5 == 0 ? table : "")),
                .init(id: "tool-\(turn)", kind: .tool, text: #"{"cmd":"rg result Sources"}"#, title: "exec_command",
                      output: output, completed: true, exitCode: 0),
                .init(id: "done-\(turn)", kind: .assistant, text: "Change \(turn) checked. The next task can proceed.")])
        }
    }
}

/// Counters for one phase. Run-loop wakeups and busy time come from an observer on the main run loop.
@MainActor
private final class EnergySample {
    private let start = CACurrentMediaTime()
    private let usage = EnergySample.rusage()
    private let mainCPU = EnergySample.mainThreadCPU()
    private let document: [String: Int]
    private let redraws: [String: Int]
    private var observer: CFRunLoopObserver?
    private var wakeups = 0
    private var busy: CFTimeInterval = 0
    private var busyOver8ms = 0
    private var turnStart: CFTimeInterval?

    init(document view: NSView?) {
        document = Self.documentCounters(view)
        redraws = RedrawCounter.snapshot()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { self.wakeups += 1; self.turnStart = now }
                else if let start = self.turnStart {
                    self.busy += now - start; if now - start > 0.00833 { self.busyOver8ms += 1 }
                    self.turnStart = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func finish(document view: NSView?) -> [String: Any] {
        observer.map { CFRunLoopObserverInvalidate($0) }
        let elapsed = CACurrentMediaTime() - start
        let end = Self.rusage()
        func delta(_ key: KeyPath<rusage_info_v6, UInt64>) -> Double { Double(end[keyPath: key] &- usage[keyPath: key]) }
        var result: [String: Any] = [
            "seconds": elapsed,
            // Process times in v6 are in mach time units.
            "cpuSeconds": (delta(\.ri_user_time) + delta(\.ri_system_time)) * Self.timebase / 1e9,
            "mainCPUSeconds": Self.mainThreadCPU() - mainCPU,
            "energyJoules": delta(\.ri_energy_nj) / 1e9,
            "billedEnergy": delta(\.ri_billed_energy),
            "instructions": delta(\.ri_instructions),
            "interruptWakeups": delta(\.ri_interrupt_wkups),
            "idleWakeups": delta(\.ri_pkg_idle_wkups),
            "runLoopWakeups": wakeups,
            "runLoopBusySeconds": busy,
            "runLoopTurnsOver8ms": busyOver8ms,
        ]
        let after = Self.documentCounters(view)
        if !after.isEmpty { result["document"] = after.merging(document.mapValues { -$0 }) { $0 + $1 } }
        let counts = RedrawCounter.snapshot().merging(redraws.mapValues { -$0 }) { $0 + $1 }.filter { $0.value > 0 }
        if !counts.isEmpty { result["redraws"] = counts }
        return result
    }

    /// The native document's own counters, read by reflection so the old renderer compiles too.
    private static func documentCounters(_ view: NSView?) -> [String: Int] {
        guard let view else { return [:] }
        var values: [String: Int] = [:]
        for child in Mirror(reflecting: view).children {
            if let label = child.label, ["layoutPasses", "createdHosts", "updateGeneration"].contains(label),
               let value = child.value as? Int { values[label] = value }
        }
        return values
    }

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    private static func rusage() -> rusage_info_v6 {
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        return info
    }

    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self(); defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }
}

/// Counts `-[NSView layout]`, `-[NSView drawRect:]`, `-[NSView updateLayer]`, `-[CALayer display]` and
/// `-[CALayer drawInContext:]` by the receiver's class, once per call: only the most derived implementation counts,
/// so a chain of `super` calls is one call. Classes realized after `install()` count under their nearest ancestor
/// that existed then.
private enum RedrawCounter {
    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var installed = false
    private static let lock = NSLock()
    private final class Box: @unchecked Sendable { var imp: IMP?; let label: String; init(_ label: String) { self.label = label } }

    static func snapshot() -> [String: Int] { lock.withLock { counts } }

    private static func note(_ receiver: AnyObject, _ selector: Selector, _ box: Box) {
        guard enabled, let dynamic = object_getClass(receiver),
              let method = class_getInstanceMethod(dynamic, selector), method_getImplementation(method) == box.imp else { return }
        let key = box.label + " " + NSStringFromClass(dynamic)
        lock.withLock { counts[key, default: 0] += 1 }
    }

    static func install() {
        guard !installed else { return }
        installed = true
        typealias Plain = @convention(c) (AnyObject, Selector) -> Void
        typealias Rect = @convention(c) (AnyObject, Selector, NSRect) -> Void
        typealias Context = @convention(c) (AnyObject, Selector, CGContext) -> Void
        let view: AnyClass = NSView.self, layer: AnyClass = CALayer.self
        let targets: [(AnyClass, Selector, String)] = [
            (view, #selector(NSView.layout), "layout"), (view, #selector(NSView.draw(_:)), "drawRect"),
            (view, #selector(NSView.updateLayer), "updateLayer"),
            (layer, #selector(CALayer.display), "display"), (layer, #selector(CALayer.draw(in:)), "drawInContext")]
        var count: UInt32 = 0
        // Read the list as raw pointers: its element accessor retains each class, and some root classes forward
        // `retain`. Metatypes themselves are not reference counted.
        guard let list = objc_copyClassList(&count) else { return }
        let raw = UnsafeRawPointer(list)
        defer { free(UnsafeMutableRawPointer(mutating: raw)) }
        for index in 0..<Int(count) {
            let cls = unsafeBitCast(raw.load(fromByteOffset: index * MemoryLayout<UnsafeRawPointer>.stride,
                                             as: UnsafeRawPointer.self), to: AnyClass.self)
            for (base, selector, label) in targets where descends(cls, from: base) {
                var methods: UInt32 = 0
                guard let own = class_copyMethodList(cls, &methods) else { continue }
                defer { free(own) }
                guard let method = (0..<Int(methods)).map({ own[$0] }).first(where: { method_getName($0) == selector }) else { continue }
                let original = method_getImplementation(method)
                let box = Box(label)
                let block: Any
                switch label {
                case "drawRect":
                    let call = unsafeBitCast(original, to: Rect.self)
                    block = { (receiver: AnyObject, rect: NSRect) in note(receiver, selector, box); call(receiver, selector, rect) }
                        as @convention(block) (AnyObject, NSRect) -> Void
                case "drawInContext":
                    let call = unsafeBitCast(original, to: Context.self)
                    block = { (receiver: AnyObject, context: CGContext) in note(receiver, selector, box); call(receiver, selector, context) }
                        as @convention(block) (AnyObject, CGContext) -> Void
                default:
                    let call = unsafeBitCast(original, to: Plain.self)
                    block = { (receiver: AnyObject) in note(receiver, selector, box); call(receiver, selector) }
                        as @convention(block) (AnyObject) -> Void
                }
                let imp = imp_implementationWithBlock(block)
                box.imp = imp
                method_setImplementation(method, imp)
            }
        }
    }

    private static func descends(_ cls: AnyClass, from base: AnyClass) -> Bool {
        var current: AnyClass? = cls
        while let value = current {
            if value == base { return true }
            current = class_getSuperclass(value)
        }
        return false
    }
}
