import AppKit
import Darwin
import QuartzCore
import XCTest
@testable import DispatchApp

/// Opt-in real SSH host scaling, driven by scripts/benchmark-host-scaling.py.
/// All cases use the same transcript, visible remote space, window, and display.
@MainActor
final class HostScalingBenchmarkTests: XCTestCase {
    private struct Profile: Decodable { let destination: String; let options: [String] }
    private struct Configuration: Decodable {
        let label: String
        let spacesPerHost: [Int]
        let profiles: [Profile]
        let duration: Double
        let variant: String
        let profile: Bool
        let profilePhase: String?
        let thinking: Bool
        let backend: String
    }
    private let directory = CodexTestSupport.root.appendingPathComponent("build/host-scaling-benchmark")

    func testConnectedHostsAndChatScrolling() async throws {
        let input = directory.appendingPathComponent("input.json")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("Run scripts/benchmark-host-scaling.py") }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: input))
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        app.runtime.chat.setEnabled(true)
        #if DISPATCH_BENCHMARK
        HostScalingAnimationProbe.paused = config.variant == "animation-off"
        defer { HostScalingAnimationProbe.tick = nil; HostScalingAnimationProbe.paused = false }
        #endif
        app.controller.settings.values = Preferences()
        app.controller.settings.values.spaceOrder = .tree
        app.workspace.spaceOrder = .tree
        if !app.controller.sidebarVisible { app.controller.toggleSidebar() }
        app.window.setContentSize(NSSize(width: 1120, height: 740))
        if let screen = app.window.screen {
            app.window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - app.window.frame.width / 2,
                y: screen.visibleFrame.midY - app.window.frame.height / 2))
        }
        HostStats.shared.startBackgroundHistory()
        defer { HostStats.shared.stop() }
        var scopes: [SSHIntegrationScope] = []
        defer { for scope in scopes { app.runtime.ssh.permissions.reset(scope) } }
        for profile in config.profiles.prefix(config.spacesPerHost.count) {
            scopes.append(try await SSHTestServer.authorize(arguments: profile.options + [profile.destination],
                grant: .init(profile: .full, hooks: false)))
        }
        var spaces: [UUID] = [], surfaces: [UUID] = []
        for (host, count) in config.spacesPerHost.enumerated() {
            var origin: UUID?
            for index in 0..<count {
                if config.backend == "tmux", index > 0 {
                    let previous = app.workspace.activeSurfaceID
                    app.workspace.newBackendSpace()
                    try await TestSupport.eventually(timeout: .seconds(20)) {
                        app.workspace.activeSurfaceID != previous && app.workspace.current?.shows("tmux") == true
                            && app.workspace.activeTab?.isConnecting == false
                    }
                } else {
                    if !spaces.isEmpty { app.workspace.newLocalSpace() }
                    let id = try XCTUnwrap(app.workspace.activeSurfaceID)
                    origin = id
                    try await TestSupport.eventually(timeout: .seconds(15)) {
                        app.runtime.views[id].map { $0.surface != nil && !TerminalTestSupport.viewport(terminal: $0).isEmpty } == true
                    }
                    let profile = config.profiles[host]
                    TerminalTestSupport.send("ssh " + (profile.options + [profile.destination]).map(HerdrLaunch.quote).joined(separator: " "),
                        to: try XCTUnwrap(app.runtime.views[id]))
                    try await TestSupport.eventually(timeout: .seconds(40), diagnostic: "SSH host \(host) failed to authenticate") {
                        app.runtime.ssh.links.values.contains { $0.launch.tabID == id && $0.shellPID != nil }
                            && app.workspace.hosts.terminals[id]?.authenticated == true
                    }
                    if config.backend == "tmux" {
                        let serverRoot = "/tmp/dispatch-host-scaling-" + UUID().uuidString
                        let command = "mkdir -m 700 " + HerdrLaunch.quote(serverRoot) + "; touch " + HerdrLaunch.quote(serverRoot + "/.fixture")
                            + "; /usr/bin/tmux -u -S " + HerdrLaunch.quote(serverRoot + "/tmux.sock")
                            + " -f /dev/null -CC new-session -s benchmark /bin/bash"
                        TerminalTestSupport.send(command, to: try XCTUnwrap(app.runtime.views[id]))
                        try await TestSupport.eventually(timeout: .seconds(20)) {
                            app.workspace.current?.shows("tmux") == true && app.workspace.activeTab?.isConnecting == false
                        }
                    }
                }
                let ssh = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == origin })
                let id = try XCTUnwrap(app.workspace.activeSurfaceID)
                try await TestSupport.eventually(timeout: .seconds(15)) {
                    app.runtime.views[id].map { $0.surface != nil && !TerminalTestSupport.viewport(terminal: $0).isEmpty } == true
                }
                let root = "/tmp/dispatch-host-scaling-" + UUID().uuidString
                let conversation = UUID().uuidString
                let now = ISO8601DateFormatter().string(from: .now)
                var records: [[String: Any]] = [
                    ["timestamp": now, "type": "session_meta", "payload": ["id": conversation, "cli_version": "0.153.2", "source": "cli", "cwd": root]],
                    ["timestamp": now, "type": "event_msg", "payload": ["type": "task_started", "turn_id": "benchmark-active", "started_at": now]]]
                if !config.thinking {
                    records.append(["timestamp": now, "type": "event_msg", "payload": ["type": "task_complete", "turn_id": "benchmark-active"]])
                }
                var transcript = Data()
                for record in records { transcript.append(try JSONSerialization.data(withJSONObject: record)); transcript.append(10) }
                func remote(_ argv: [String], input: Data = Data()) async throws {
                    let result = try await SSHTestCommand.run(master: ssh.launch.master, argv: argv, input: input)
                    guard result.status == 0 else { throw HerdrFailure(String(decoding: result.output, as: UTF8.self)) }
                }
                try await remote(["/bin/mkdir", "-m", "700", root])
                try await remote(["/bin/cp", "/bin/bash", root + "/codex"])
                try await remote(["/usr/bin/touch", root + "/.fixture"])
                try await remote(["/usr/bin/tee", root + "/rollout.jsonl"], input: transcript)
                // A waiting-shell protocol fixture keeps a real foreground process and
                // open rollout. It is not a Codex CLI or a model service.
                let launch = HerdrLaunch.quote(root + "/codex") + " -c " + HerdrLaunch.quote("read -r -t 900 dispatch_fixture_wait") + " 3<" + HerdrLaunch.quote(root + "/rollout.jsonl")
                TerminalTestSupport.send("/bin/sh -c " + HerdrLaunch.quote(launch), to: try XCTUnwrap(app.runtime.views[id]))
                let chat = app.runtime.chat.session(for: id)
                try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Protocol fixture did not attach") {
                    chat.active && chat.remoteAgent != nil && chat.sessionID == conversation && chat.transcriptAvailable && !chat.loadingHistory && chat.busy == config.thinking
                }
                if config.backend == "tmux" {
                    guard app.workspace.spaces.first(where: { $0.tabs.contains { $0.id == id } })?.shows("tmux") == true else {
                        throw HerdrFailure("Benchmark chat must use a remote tmux pane")
                    }
                }
                surfaces.append(id)
                spaces.append(try XCTUnwrap(app.workspace.spaces.first { $0.tabs.contains { $0.id == id } }?.id))
            }
        }
        XCTAssertEqual(app.workspace.spaces.count, config.spacesPerHost.reduce(0, +))
        XCTAssertEqual(app.workspace.liveHosts.filter { $0.id != .local }.count, config.spacesPerHost.count)
        let connected = app.runtime.ssh.links.count
        XCTAssertEqual(connected, config.backend == "tmux" ? config.spacesPerHost.count : config.spacesPerHost.reduce(0, +))
        XCTAssertEqual(Set(app.workspace.spaces.filter { $0.shows("tmux") }.compactMap(\.backend)).count, config.backend == "tmux" ? config.spacesPerHost.count : 0)
        XCTAssertEqual(app.workspace.spaces.filter { $0.structured }.count, config.backend == "tmux" ? spaces.count : 0)
        for id in surfaces {
            let session = app.runtime.chat.session(for: id)
            session.turns = history() + [ChatTurn(id: "benchmark-active", items: [
                ChatItem(id: "active-reasoning", kind: .reasoning, text: "Reviewing the workspace and checking the change.")])]
            session.activeTurnID = "benchmark-active"
            session.atBottom = false
            session.setView(true, reason: "benchmark")
        }
        if config.variant == "sidebar-hidden" {
            await display(app.window)
            let split = try XCTUnwrap(PresentationTestSupport.views(of: TerminalSplitView.self,
                in: XCTUnwrap(app.window.contentView)).first { $0.sidebar })
            let width = split.arrangedSubviews[0].frame.width + split.dividerThickness
            app.controller.toggleSidebar()
            app.window.setContentSize(NSSize(width: 1120 - width, height: 740))
        }
        // Visit every chat once, so switching measures retained, already opened work.
        for space in spaces {
            app.workspace.selectSpace(space)
            await display(app.window)
            try await Task.sleep(for: .milliseconds(120))
        }
        app.workspace.selectSpace(spaces[0])
        await display(app.window)
        try await Task.sleep(for: .seconds(2))
        let session = app.runtime.chat.session(for: surfaces[0])
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: XCTUnwrap(app.window.contentView))
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
        session.scrollPosition.cancelPreservation()
        let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        let warmup = ScrollFrames(scroll: scroll, window: app.window, position: session.scrollPosition,
            measureContinuity: false, pauseBetweenGestures: false, speed: 1200)
        _ = await warmup.run(seconds: 3)
        if config.profile && config.profilePhase != "switching" {
            try JSONSerialization.data(withJSONObject: ["pid": getpid(), "label": config.label])
                .write(to: directory.appendingPathComponent("ready.json"))
            try await Task.sleep(for: .seconds(2))
        }
        let frames = ScrollFrames(scroll: scroll, window: app.window, position: session.scrollPosition,
            measureContinuity: false, pauseBetweenGestures: false, speed: 1200)
        var animationTicks: [UUID: [Double]] = [:]
        #if DISPATCH_BENCHMARK
        HostScalingAnimationProbe.tick = { id in animationTicks[id, default: []].append(CACurrentMediaTime()) }
        #endif
        let scrolling = await frames.run(seconds: config.duration)
        #if DISPATCH_BENCHMARK
        HostScalingAnimationProbe.tick = nil
        if config.thinking && config.variant != "animation-off" {
            XCTAssertGreaterThan(animationTicks[surfaces[0], default: []].count, 2, "Thinking must animate during scrolling")
        }
        #endif
        XCTAssertTrue(surfaces.allSatisfy { app.runtime.chat.sessions[$0]?.active == true && app.runtime.chat.sessions[$0]?.busy == config.thinking })
        XCTAssertGreaterThan(frames.distance, 1000, "Must scroll real chat content")
        if config.profile && config.profilePhase == "switching" {
            try JSONSerialization.data(withJSONObject: ["pid": getpid(), "label": config.label])
                .write(to: directory.appendingPathComponent("ready.json"))
            try await Task.sleep(for: .seconds(2))
        }
        // Always alternate the same two chats: cycling all spaces would weight the
        // scrolled foreground differently as the number of spaces increases.
        var switches: [Double] = []
        for index in 0..<48 {
            let start = CACurrentMediaTime()
            app.workspace.selectSpace(spaces[(index + 1) % 2])
            await display(app.window)
            switches.append((CACurrentMediaTime() - start) * 1000)
            try await Task.sleep(for: .milliseconds(50))
        }
        app.workspace.selectSpace(spaces[0]); await display(app.window)
        let editor = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self,
            in: XCTUnwrap(app.window.contentView)).first)
        app.window.makeFirstResponder(editor)
        var typing: [Double] = []
        for index in 0..<48 {
            let start = CACurrentMediaTime()
            editor.insertText("x", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
            await display(app.window)
            typing.append((CACurrentMediaTime() - start) * 1000)
            XCTAssertEqual(editor.string.count, index + 1)
            try await Task.sleep(for: .milliseconds(35))
        }
        let idleCPU = cpuTime(), idleStart = CACurrentMediaTime()
        var heartbeat: [Double] = []
        var previous = idleStart
        while CACurrentMediaTime() - idleStart < 5 {
            try await Task.sleep(for: .milliseconds(16))
            let now = CACurrentMediaTime(); heartbeat.append((now - previous) * 1000); previous = now
        }
        let report: [String: Any] = ["label": config.label, "variant": config.variant,
            "spacesPerHost": config.spacesPerHost, "hosts": app.workspace.liveHosts.filter { $0.id != .local }.count,
            "spaces": app.workspace.spaces.count, "sshConnections": connected,
            "statisticsSeries": SSHStatisticsStore.shared.series.count,
            "chatSessions": app.runtime.chat.sessions.count, "scrolling": scrolling,
            "chatViewportWidth": scroll.contentView.bounds.width,
            "thinking": config.thinking, "backend": config.backend, "tmuxConnections": Set(app.workspace.spaces.filter { $0.shows("tmux") }.compactMap(\.backend)).count,
            "animationTicks": surfaces.map { animationTicks[$0, default: []] },
            "switchMs": switches, "typingMs": typing, "idleHeartbeatMs": heartbeat,
            "idleCPUSeconds": cpuTime() - idleCPU, "idleSeconds": CACurrentMediaTime() - idleStart,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "note": "Real SSH shells/full helper; identical synthetic history and a waiting-shell remote protocol fixture per space; real discovery/transcript polling and Thinking animation, no model service. Display callbacks and layout submission, not physical scanout. CPU/RSS cover app process only."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(config.label + ".json"))
        _ = try await PresentationTestSupport.capture(app.window, named: config.label, in: "host-scaling-benchmark")
        print("HOST SCALING", config.label, "Hz", scrolling["callbackHz"] ?? "?", "CPU", scrolling["cpuSeconds"] ?? "?")
        XCTAssertEqual(app.runtime.ssh.links.count, connected, "All SSH sessions must survive measurement")
        XCTAssertTrue(surfaces.allSatisfy { app.runtime.chat.sessions[$0]?.active == true && app.runtime.chat.sessions[$0]?.busy == config.thinking })
        await app.close().value
    }

    private func history() -> [ChatTurn] {
        (0..<150).map { index in
            ChatTurn(id: "turn-\(index)", items: [
                .init(id: "user-\(index)", kind: .user, text: "Inspect the workspace and explain the change for task \(index)."),
                .init(id: "assistant-\(index)", kind: .assistant,
                    text: "### Changes for task \(index)\n\nThe **workspace** keeps its `terminal` identity.\n\n- Preserve the selected pane\n- Refresh after the command\n\n```swift\nlet tab = workspace.activeTab\nprint(tab?.id)\n```"),
                .init(id: "tool-\(index)", kind: .tool, text: #"{"cmd":"swift build"}"#, title: "exec_command",
                    output: "Build complete.\n" + String(repeating: "Compiling module\n", count: 200), completed: true)])
        }
    }
    private func display(_ window: NSWindow) async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            window.contentView?.layoutSubtreeIfNeeded(); window.contentView?.displayIfNeeded()
        }
        CATransaction.flush()
    }
    private func cpuTime() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
