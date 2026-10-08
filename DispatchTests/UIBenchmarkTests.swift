import AppKit
import Darwin
import QuartzCore
import SwiftUI
import XCTest
@testable import DispatchApp

/// Real AppKit/SwiftUI windows and terminal transports. Measurements end after
/// layout/display submission or an observed terminal reply, not physical scanout.
@MainActor
final class UIBenchmarkTests: XCTestCase {
    private var output: URL {
        if let path = ProcessInfo.processInfo.environment["DISPATCH_BENCHMARK_OUTPUT"] {
            return URL(fileURLWithPath: path).appendingPathComponent("ui")
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ui-benchmark-validation")
    }

    private struct Report: Codable {
        let name: String
        let seconds: [Double]
        let cpuSeconds: Double
        let residentBefore: UInt64
        let residentAfter: UInt64
        let peakResident: UInt64
        let heartbeatSeconds: [Double]
    }

    private func measure(_ name: String, count: Int = 24, window: NSWindow,
                         maximumSeconds: Double = 5, pauseSeconds: Double = 0.016,
                         action: (Int) async throws -> Void) async throws {
        var samples: [Double] = [], gaps: [Double] = []
        let before = resident(), cpu = cpuTime(), mainCPU = threadCPUTime()
        var peak = before
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                let now = ContinuousClock.now
                gaps.append(Self.seconds(previous.duration(to: now))); previous = now
            }
        }
        defer { heartbeat.cancel() }
        for index in 0..<count {
            let start = ContinuousClock.now
            try await action(index)
            await display(window)
            samples.append(Self.seconds(start.duration(to: .now)))
            peak = max(peak, resident())
            try await Task.sleep(for: .seconds(pauseSeconds))
        }
        heartbeat.cancel()
        let report = Report(name: name, seconds: samples, cpuSeconds: cpuTime() - cpu,
                            residentBefore: before, residentAfter: resident(), peakResident: peak, heartbeatSeconds: gaps)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: output.appendingPathComponent(name + ".json"))
        let sorted = samples.sorted()
        print("UI BENCHMARK \(name): n=\(count) median=\(sorted[count / 2]) p95=\(sorted[min(count - 1, count * 95 / 100)]) max=\(sorted.last!) cpu=\(report.cpuSeconds) mainCPU=\(threadCPUTime() - mainCPU) peakRSS=\(peak) maxGap=\(gaps.max() ?? 0)")
        XCTAssertLessThan(sorted.last!, maximumSeconds, "A benchmark action exceeded its deadline")
    }

    private var sustainedSeconds: Double {
        min(3600, max(5, Double(ProcessInfo.processInfo.environment["DISPATCH_BENCHMARK_SECONDS"] ?? "5") ?? 5))
    }

    /// Fixture/window readiness, not full application process launch or workspace restoration.
    func testTerminalLifecycle() async throws {
        let observer = try await mount(Text("Terminal lifecycle"))
        defer { close(observer) }
        try await measure("local-terminal-create-ready-close", count: 8, window: observer, maximumSeconds: 20) { _ in
            let app = try TmuxWalkthrough()
            defer {
                app.close()
                XCTAssertTrue(app.runtime.views.isEmpty, "Closing the fixture must release terminal views")
            }
            let view = try await self.terminal(app)
            TerminalTestSupport.send("printf 'BENCH_LIFECYCLE_%s\\n' READY", to: view)
            try await TestSupport.eventually { TerminalTestSupport.viewport(terminal: view).contains("BENCH_LIFECYCLE_READY") }
        }
    }

    func testIdleTerminals() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        for index in 0..<4 {
            if index > 0 { app.workspace.newLocalSpace() }
            _ = try await terminal(app)
        }
        // Settle prompt creation before collecting idle CPU and resident memory.
        try await Task.sleep(for: .seconds(1))
        let duration = sustainedSeconds
        try await measure("idle-four-terminals", count: 1, window: app.window, maximumSeconds: duration + 10) { _ in
            try await Task.sleep(for: .seconds(duration))
            XCTAssertEqual(app.workspace.spaces.count, 4)
        }
    }

    func testMixedOutputAndNavigation() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        var spaces: [UUID] = []
        var terminals: [TerminalView] = []
        let duration = sustainedSeconds
        for index in 0..<3 {
            if index > 0 { app.workspace.newLocalSpace() }
            spaces.append(try XCTUnwrap(app.workspace.selectedSpace))
            let view = try await terminal(app)
            terminals.append(view)
            // Bounded owned shell jobs; the fixture also terminates them on failure.
            let iterations = Int((duration * 3 + 60) * 50)
            TerminalTestSupport.send("i=0; while test $i -lt \(iterations); do printf 'BENCH_OUTPUT_%s_%s\\n' \(index) $i; i=$((i+1)); sleep 0.02; done", to: view)
            try await TestSupport.eventually { TerminalTestSupport.viewport(terminal: view).contains("BENCH_OUTPUT_\(index)_") }
        }
        let iterations = Int(duration * 10)
        try await measure("mixed-three-output-space-switch", count: iterations, window: app.window, pauseSeconds: 0.1) { index in
            app.workspace.selectSpace(spaces[index % spaces.count])
            _ = try await self.terminal(app)
        }
        // Finish the requested sustained interval even on very fast machines.
        try await measure("mixed-three-output-sustained", count: 1, window: app.window, maximumSeconds: duration + 10) { _ in
            let before = terminals.map { TerminalTestSupport.viewport(terminal: $0) }
            try await Task.sleep(for: .seconds(duration))
            for (index, view) in terminals.enumerated() {
                XCTAssertNotEqual(TerminalTestSupport.viewport(terminal: view), before[index], "Output must continue during the workload")
            }
        }
    }

    private func display(_ window: NSWindow) async {
        // Let observation updates and AppKit's deferred input work run before
        // flushing layout. The same barrier is used for every baseline/retest.
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
        CATransaction.flush()
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

    /// The calling (main) thread only: the UI work behind a measured action, excluding transport threads.
    private func threadCPUTime() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self(); defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }

    private func cpuTime() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private func wheel(_ view: NSView, pixels: Int32) throws {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
    }
    private func scrollView(_ window: NSWindow) throws -> NSScrollView {
        try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: XCTUnwrap(window.contentView))
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
    }
    private func mount<Content: View>(_ content: Content, size: NSSize = .init(width: 900, height: 700)) async throws -> NSWindow {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250)); await display(window)
        return window
    }
    private func close(_ window: NSWindow) { window.orderOut(nil); window.contentView = nil; window.close() }
    private func terminal(_ app: TmuxWalkthrough, _ stage: String = "terminal") async throws -> TerminalView {
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await TestSupport.eventually(diagnostic: "\(stage): window=\(app.runtime.views[id]?.window === app.window) surface=\(app.runtime.views[id]?.surface != nil) screen=\(app.runtime.views[id].map { TerminalTestSupport.screen(terminal: $0) } ?? "missing")") {
            app.runtime.views[id].map { $0.window === app.window && !TerminalTestSupport.viewport(terminal: $0).isEmpty } == true
        }
        return try XCTUnwrap(app.runtime.views[id])
    }

    func testLocalChatSpaceSwitchingWithSingleAndTwoTabs() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let source = try XCTUnwrap(app.workspace.selectedSpace)
        let chatTab = try XCTUnwrap(app.workspace.activeTab).id
        let session = app.runtime.chat.session(for: chatTab)
        session.setView(true, reason: "benchmark")
        session.draft = "Unsent switch benchmark draft"
        session.turns = (0..<100).map { index in
            ChatTurn(id: "switch-\(index)", items: [ChatItem(id: "message-\(index)", kind: .assistant,
                text: "## Result \(index)\n\nA response with **formatted text** and a `command`.\n\n" + String(repeating: "Chat history content. ", count: 20))])
        }
        app.workspace.newLocalSpace()
        let destination = try XCTUnwrap(app.workspace.selectedSpace)
        _ = try await terminal(app)
        for count in [1, 2] {
            if count == 2 {
                app.workspace.selectSpace(source); app.workspace.newTab(); app.workspace.selectTab(chatTab)
            }
            app.workspace.selectSpace(destination)
            await display(app.window)
            try await measure("local-chat-space-switch-\(count)-tabs", count: 16, window: app.window, pauseSeconds: 0.35) { index in
                app.workspace.selectSpace(index.isMultiple(of: 2) ? source : destination)
            }
            XCTAssertEqual(session.draft, "Unsent switch benchmark draft")
        }
    }

    /// Alternates an SSH herdr space and an SSH tmux space, two tabs each, over the loopback sshd.
    func testRemoteTmuxAndHerdrSpaceSwitching() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        // The SSH shell that started herdr then starts tmux; only herdr keeps it.
        app.workspace.closeLaunching["herdr"] = false
        let server = try await SSHTestServer(); defer { server.stop() }
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { _ = try? HerdrSocket(path: socket).request("server.stop") }
        let source = try await terminal(app, "local shell")
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: source)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source.id && $0.shellPID != nil }
        }
        TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path)
            + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: source)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        let herdr = try XCTUnwrap(app.workspace.selectedSpace)
        _ = try await terminal(app, "first herdr tab")
        app.workspace.newTab()
        try await TestSupport.eventually(timeout: .seconds(15)) {
            app.workspace.currentTabs.count == 2 && app.workspace.activeTab?.isConnecting == false
        }
        _ = try await terminal(app, "second herdr tab")
        app.workspace.selectTab(source.id)
        try await app.attach(); try await app.ready()
        let tmux = try XCTUnwrap(app.workspace.selectedSpace)
        app.workspace.newTab()
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.windows.count == 2 }
        try await app.ready()
        XCTAssertNotEqual(herdr, tmux)
        XCTAssertNotEqual(app.workspace.hosts.record(app.workspace.spaces.first { $0.id == tmux }!.hostID).id, .local)
        XCTAssertNotEqual(app.workspace.hosts.record(app.workspace.spaces.first { $0.id == herdr }!.hostID).id, .local)
        // Visit both once so measurements cover retained, already attached views.
        for space in [herdr, tmux] { app.workspace.selectSpace(space); _ = try await terminal(app, space == herdr ? "herdr revisit" : "tmux revisit") }
        // Submission: selection through layout/display. Ready: the destination terminal drew in the window.
        try await measure("remote-tmux-herdr-space-switch", count: 24, window: app.window, pauseSeconds: 0.35) { index in
            app.workspace.selectSpace(index.isMultiple(of: 2) ? herdr : tmux)
        }
        try await measure("remote-tmux-herdr-space-switch-ready", count: 24, window: app.window, pauseSeconds: 0.35) { index in
            app.workspace.selectSpace(index.isMultiple(of: 2) ? herdr : tmux)
            let id = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await TestSupport.eventually(timeout: .seconds(5), interval: .milliseconds(1)) {
                app.runtime.views[id].map { $0.window === app.window && $0.surface != nil && !TerminalTestSupport.viewport(terminal: $0).isEmpty } == true
            }
        }
        _ = try await PresentationTestSupport.capture(app.window, named: "remote-space-switch", in: "ui-benchmark-validation")
    }

    func testDesktopNavigationAndResize() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        var tabs: [UUID] = [], spaces: [UUID] = []
        for index in 0..<6 {
            if index > 0 { app.workspace.newLocalSpace() }
            spaces.append(try XCTUnwrap(app.workspace.selectedSpace))
            tabs.append(try await terminal(app).id)
            app.workspace.newTab(); tabs.append(try await terminal(app).id)
        }
        try await measure("desktop-space-switch-6", window: app.window) { index in
            app.workspace.selectSpace(spaces[index % spaces.count])
            _ = try await self.terminal(app)
        }
        try await measure("desktop-tab-switch-12", window: app.window) { index in
            app.workspace.selectTab(tabs[index % tabs.count])
            _ = try await self.terminal(app)
        }
        try await measure("desktop-sidebar-toggle", window: app.window) { _ in app.controller.toggleSidebar() }
        app.workspace.newTab(); _ = try await terminal(app)
        XCTAssertTrue(app.workspace.applyLayout(.columns))
        try await measure("desktop-split-window-resize", window: app.window) { index in
            app.window.setContentSize(NSSize(width: 1000 + (index % 8) * 20, height: 650 + (index % 6) * 12))
        }
        _ = try await PresentationTestSupport.capture(app.window, named: "desktop", in: "ui-benchmark-validation")
    }

    func testLiveTerminalInputAndScroll() async throws {
        // scripts/benchmark.py chooses the ssh server: a Lima VM profile, the
        // loopback fixture (a Release helper needs it behind root sshd), or none.
        let environment = ProcessInfo.processInfo.environment
        let sshMode = environment["DISPATCH_BENCHMARK_SSH"] ?? "loopback"
        for backend in ["local", "ssh", "tmux", "herdr"] where backend != "ssh" || sshMode != "skipped" {
            let app = try TmuxWalkthrough()
            let server = backend == "ssh" && sshMode == "loopback" ? try await SSHTestServer() : nil
            let lima = try (backend == "ssh" && sshMode == "lima") ? environment["DISPATCH_BENCHMARK_SSH_PROFILE"].map {
                try JSONDecoder().decode(SSHLinuxTestProfile.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
            } : nil
            var limaScope: SSHIntegrationScope?
            let directory = URL(fileURLWithPath: "/tmp/ui-herdr-\(UUID().uuidString.prefix(8))")
            let socket = directory.appendingPathComponent("herdr.sock").path
            defer {
                if let limaScope { app.runtime.ssh.permissions.reset(limaScope) }
                app.close(); server?.stop()
                if backend == "herdr", let api = try? HerdrSocket(path: socket) { try? api.request("server.stop") }
                try? FileManager.default.removeItem(at: directory)
            }
            let origin = try await terminal(app)
            if backend == "ssh" {
                let arguments: [String]
                if let server { arguments = server.options + [server.destination] }
                else {
                    let profile = try XCTUnwrap(lima, "DISPATCH_BENCHMARK_SSH=\(sshMode) needs a usable server")
                    arguments = profile.options + [profile.destination]
                    limaScope = try await SSHTestServer.authorize(arguments: arguments, grant: .init(profile: .full, hooks: false))
                }
                TerminalTestSupport.send("ssh " + arguments.map(HerdrLaunch.quote).joined(separator: " "), to: origin)
                try await TestSupport.eventually(timeout: .seconds(20)) { app.runtime.ssh.links.values.contains { $0.shellPID != nil } }
            } else if backend == "tmux" { try await app.attach(); try await app.ready() }
            else if backend == "herdr" {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(directory.path) + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: origin)
                try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
            }
            let view = try await terminal(app)
            // Warm transport, prompt, and font caches before timed requests.
            TerminalTestSupport.send("printf 'UI_WARM_%s\\n' READY", to: view)
            try await TestSupport.eventually { TerminalTestSupport.viewport(terminal: view).contains("UI_WARM_READY") }
            try await measure("\(backend)-input-reply", count: 16, window: app.window) { index in
                let marker = "UI_\(backend)_\(index)_DONE"
                TerminalTestSupport.send("printf 'UI_\(backend)_\(index)_%s\\n' DONE", to: view)
                try await TestSupport.eventually(interval: .milliseconds(5)) { TerminalTestSupport.viewport(terminal: view).contains(marker) }
            }
            TerminalTestSupport.send("i=0; while test $i -lt 2000; do printf 'build/file-%s.swift: compiling output line\\n' $i; i=$((i+1)); done; printf 'UI_SCROLL_%s\\n' READY", to: view)
            try await TestSupport.eventually(timeout: .seconds(15)) { TerminalTestSupport.viewport(terminal: view).contains("UI_SCROLL_READY") }
            try await measure("\(backend)-terminal-scroll", count: 48, window: app.window) { index in
                let before = TerminalTestSupport.viewport(terminal: view)
                try self.wheel(view, pixels: index < 24 ? 90 : -90)
                try await TestSupport.eventually(timeout: .seconds(2), interval: .milliseconds(5)) {
                    TerminalTestSupport.viewport(terminal: view) != before
                }
            }
            _ = try await PresentationTestSupport.capture(app.window, named: backend, in: "ui-benchmark-validation")
        }
    }

    func testChatHistoryAndCodePreviews() async throws {
        let coordinator = ChatCoordinator(enabled: false)
        let session = coordinator.session(for: UUID())
        session.showChat = true; session.sessionID = "ui-benchmark"; session.atBottom = false
        let code = (0..<350).map { "let result\($0) = await client.request(\"workspace\", retry: false) // line \($0)" }.joined(separator: "\n")
        session.turns = (0..<150).map { index in
            ChatTurn(id: "turn-\(index)", items: [
                ChatItem(id: "user-\(index)", kind: .user, text: "Inspect the workspace and explain the change for task \(index)."),
                ChatItem(id: "assistant-\(index)", kind: .assistant, text: "### Changes for task \(index)\n\nThe **workspace** keeps its `terminal` identity.\n\n- Preserve the selected pane\n- Refresh after the command\n\n```swift\nlet tab = workspace.activeTab\nprint(tab?.id)\n```"),
                ChatItem(id: "tool-\(index)", kind: .tool, text: #"{"cmd":"swift build"}"#, title: "exec_command", output: "Build complete.\n" + String(repeating: "Compiling module\n", count: 200), completed: true)])
        }
        let window = try await mount(ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        defer { close(window); coordinator.stop() }
        let scroll = try scrollView(window)
        let start = scroll.contentView.bounds.minY
        try await measure("chat-mixed-history-scroll-450", count: 60, window: window) { index in
            try self.wheel(scroll, pixels: index < 40 ? -130 : 130)
        }
        XCTAssertGreaterThan(abs(scroll.contentView.bounds.minY - start), 100, "The benchmark must traverse chat history")
        _ = try await PresentationTestSupport.capture(window, named: "chat", in: "ui-benchmark-validation")
        window.contentView = NSHostingView(rootView: ChatCodeBlock(code: code, language: "swift").padding(20).preferredColorScheme(.dark))
        await display(window)
        try await measure("code-block-resize-350-lines", window: window) { index in
            window.setContentSize(NSSize(width: 720 + index % 10 * 20, height: 650))
        }
        window.contentView = NSHostingView(rootView: CodeDocumentView(document: .init(path: "Workspace.swift", diff: code), directory: "/tmp").padding(20).preferredColorScheme(.dark))
        await display(window)
        try await measure("code-document-resize-350-lines", window: window) { index in
            window.setContentSize(NSSize(width: 720 + index % 10 * 20, height: 650))
        }
    }

    func testSidebarScrollingAndFiltering() async throws {
        for count in [40, 240] {
            let controller = AppDelegate(), workspace = controller.workspace
            controller.settings.values.spaceOrder = .tree
            for index in 0..<count {
                var space = Space(name: "Project \(index)", directory: "/tmp")
                let generation = UUID(), host = "build-\(index % 8)"
                workspace.hosts.begin(space.tabs[0].id, generation: generation, destination: "dev@" + host)
                workspace.hosts.update(space.tabs[0].id, generation: generation, destination: "dev@" + host,
                    greeting: SSHGreeting(version: 1, host: host, boot: "boot", uid: 501, home: "/home/dev", capabilities: []), state: .connected)
                space.hostID = .authenticated(host); workspace.spaces.append(space)
            }
            workspace.selectSpace(at: 0)
            let window = try await mount(SpaceSidebar(workspace: workspace, settings: controller.settings, controller: controller), size: .init(width: 264, height: 740))
            defer { close(window) }
            let scroll = try scrollView(window)
            let start = scroll.contentView.bounds.minY
            try await measure("sidebar-scroll-\(count)", count: 48, window: window) { index in
                try self.wheel(scroll, pixels: index < 24 ? -100 : 100)
                if index == 23 {
                    await self.display(window)
                    XCTAssertGreaterThan(abs(scroll.contentView.bounds.minY - start), 100)
                }
            }
            let field = try await PresentationTestSupport.openSpaceSearch(controller, in: XCTUnwrap(window.contentView))
            window.makeFirstResponder(field)
            let editor = try XCTUnwrap(window.fieldEditor(false, for: field) as? NSTextView)
            try await measure("sidebar-filter-\(count)", window: window) { index in
                editor.selectAll(nil)
                editor.insertText(index.isMultiple(of: 2) ? "Project 3" : "", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            _ = try await PresentationTestSupport.capture(window, named: "sidebar-\(count)", in: "ui-benchmark-validation")
        }
    }

    func testSettings() async throws {
        let root = URL(fileURLWithPath: "/tmp/ui-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(file: root.appendingPathComponent("settings.json"))
        let window = try await mount(SettingsView(store: store, workspace: Workspace()), size: .init(width: 560, height: 550))
        defer { close(window) }
        await display(window)
        let scroll = try scrollView(window)
        let start = scroll.contentView.bounds.minY
        try await measure("settings-scroll", count: 48, window: window) { index in
            try self.wheel(scroll, pixels: index < 24 ? -50 : 50)
            if index == 23 {
                await self.display(window)
                XCTAssertGreaterThan(abs(scroll.contentView.bounds.minY - start), 100)
            }
        }
    }
}
