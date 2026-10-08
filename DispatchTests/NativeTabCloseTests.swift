import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class NativeTabCloseTests: XCTestCase {
    func testCommandWTerminatesIdleTmuxWindowAndAllItsPanes() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        _ = try app.server(["split-window", "-d", "-t", "edge:0", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.current?.activeWindow)
        XCTAssertEqual(tab.terminals.count, 2)
        let window = try XCTUnwrap(app.target(tab))
        app.controller.closeCurrentTab()
        try await app.wait { !app.workspace.spaces.flatMap(\.windows).contains { $0.id == tab.id } }
        try await app.wait { (try? app.server(["list-windows", "-F", "#{window_id}"]).split(separator: "\n").contains(Substring(window))) == false }
        XCTAssertTrue(app.workspace.detached.isEmpty)
    }

    func testCommandWPreservesForegroundBackgroundAndStoppedTmuxJobs() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        try await app.attach(); try await app.ready()
        for command in ["sleep 120", "sleep 120 &", "sleep 120 & kill -STOP $!"] {
            let pane = try app.server(["new-window", "-P", "-F", "#{pane_id}", "/bin/sh"]).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try app.server(["split-window", "-d", "-t", pane, "/bin/sh"])
            _ = try app.server(["send-keys", "-t", pane, command, "Enter"])
            try await app.wait { app.workspace.spaces.flatMap(\.windows).contains { $0.terminals.count == 2 && $0.terminals.contains { app.target($0) == pane } } }
            let tab = try XCTUnwrap(app.workspace.spaces.flatMap(\.windows).first { $0.terminals.contains { app.target($0) == pane } })
            let window = try XCTUnwrap(app.target(tab))
            let original = try app.server(["list-panes", "-t", window, "-F", "#{pane_id}:#{pane_pid}"])
            app.workspace.selectWindow(tab.id)
            app.controller.closeCurrentTab()
            try await app.wait { !app.workspace.spaces.flatMap(\.windows).contains { $0.id == tab.id } }
            XCTAssertEqual(try app.server(["list-panes", "-t", window, "-F", "#{pane_id}:#{pane_pid}"]), original)
        }
    }

    func testLocalHerdrCloseTerminatesIdleButDetachesBackgroundJob() async throws {
        try await checkHerdr(remote: false)
    }

    func testClosingIdlePanePreservesHiddenSiblingWork() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        _ = try app.server(["split-window", "-d", "-t", "edge:0", "/bin/sh"])
        _ = try app.server(["split-window", "-d", "-t", "edge:0", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.current?.activeWindow)
        XCTAssertEqual(tab.terminals.count, 3)
        let hidden = tab.terminals[0], idle = tab.terminals[1]
        let pane = try XCTUnwrap(app.target(hidden)), window = try XCTUnwrap(app.target(tab))
        _ = try app.server(["send-keys", "-t", pane, "sleep 120 &", "Enter"])
        app.controller.detachTab(hidden.id)
        app.controller.closeTab(idle.id)
        try await app.wait { (try? app.server(["list-panes", "-t", window, "-F", "#{pane_id}"]).split(separator: "\n").count) == 2 }
        app.controller.closeWindow(tab.id)
        try await app.wait { !app.workspace.spaces.flatMap(\.windows).contains { $0.id == tab.id } }
        XCTAssertEqual(try app.server(["list-panes", "-t", window, "-F", "#{pane_id}"]).split(separator: "\n").count, 2)
    }

    func testRemoteTmuxCloseTerminatesIdleAndPreservesBackgroundJob() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[source]?.surface != nil }
        let origin = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: origin)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.current?.activeWindow), window = try XCTUnwrap(app.target(tab))
        app.controller.closeCurrentTab()
        try await app.wait { (try? app.server(["list-windows", "-F", "#{window_id}"]).split(separator: "\n").contains(Substring(window))) == false }
        let busy = try XCTUnwrap(app.workspace.current?.activeWindow), busyWindow = try XCTUnwrap(app.target(busy))
        let pane = try XCTUnwrap(busy.terminals.first.flatMap { app.target($0) })
        _ = try app.server(["send-keys", "-t", pane, "sleep 120 & printf 'JOB_%s\\n' STARTED", "Enter"])
        try await app.wait { (try? app.server(["capture-pane", "-p", "-t", pane]).contains("JOB_STARTED")) == true }
        app.controller.closeCurrentTab()
        try await app.wait { !app.workspace.spaces.flatMap(\.windows).contains { $0.id == busy.id } }
        XCTAssertTrue(try app.server(["list-windows", "-F", "#{window_id}"]).split(separator: "\n").contains(Substring(busyWindow)))
    }

    func testRemoteHerdrCloseTerminatesIdleButDetachesBackgroundJob() async throws {
        try await checkHerdr(remote: true)
    }

    private func checkHerdr(remote: Bool) async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = remote ? try await SSHTestServer() : nil
        defer { server?.stop() }
        let root = server?.root ?? URL(fileURLWithPath: "/tmp/close-herdr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("herdr.sock").path
        defer {
            _ = try? HerdrSocket(path: socket).request("server.stop")
            if server == nil { try? FileManager.default.removeItem(at: root) }
        }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[source]?.surface != nil }
        let origin = try XCTUnwrap(app.runtime.views[source])
        if let server {
            TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: origin)
            try await TestSupport.eventually(timeout: .seconds(20)) {
                app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
            }
        }
        TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(root.path)
            + "; export XDG_STATE_HOME=" + HerdrLaunch.quote(root.path) + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: origin)
        try await app.wait { app.workspace.current?.shows("herdr") == true }
        let busy = try XCTUnwrap(app.workspace.activeTab), busyTab = try XCTUnwrap(app.workspace.activeWindowKey)
        let surface = try XCTUnwrap(HerdrTestSupport.panes(app.workspace, socket: socket).first)
        try await app.wait { app.runtime.views[surface.id]?.surface != nil }
        let view = try XCTUnwrap(app.runtime.views[surface.id])
        TerminalTestSupport.send("sleep 120 & printf 'JOB_%s\\n' STARTED", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("JOB_STARTED") }
        app.workspace.newTab()
        try await app.wait {
            app.workspace.activeWindowKey != busyTab && app.workspace.activeTab?.isConnecting == false
                && (try? HerdrTestSupport.panes(app.workspace, socket: socket))?.isEmpty == false
        }
        let idle = try XCTUnwrap(app.workspace.activeTab), idleTab = try XCTUnwrap(app.workspace.activeWindowKey)
        let idleSurface = try XCTUnwrap(HerdrTestSupport.panes(app.workspace, socket: socket).first)
        try await app.wait { app.runtime.views[idleSurface.id]?.surface != nil }
        let idleView = try XCTUnwrap(app.runtime.views[idleSurface.id])
        TerminalTestSupport.send("printf 'IDLE_%s\\n' READY", to: idleView)
        try await app.wait { TerminalTestSupport.screen(terminal: idleView).contains("IDLE_READY") }
        app.controller.closeCurrentTab()
        try await app.wait { !app.workspace.allTabIDs.contains(idle.id) }
        // Remote controls update the sidebar optimistically before the server replies.
        try await app.wait {
            guard let data = try? HerdrSocket(path: socket).request("session.snapshot"),
                  let snapshot = try? HerdrRPC.snapshot(from: data) else { return false }
            return !snapshot.tabs.contains { $0.tab_id == idleTab }
        }
        app.workspace.selectTab(busy.id)
        app.controller.closeCurrentTab()
        try await app.wait { !app.workspace.allTabIDs.contains(busy.id) }
        let retained = try HerdrRPC.snapshot(from: HerdrSocket(path: socket).request("session.snapshot"))
        XCTAssertTrue(retained.tabs.contains { $0.tab_id == busyTab })
    }
}
