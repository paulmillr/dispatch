import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class HostNativeIntegrationTests: XCTestCase {
    func testRecordedHostProcessLifecycleDoesNotConsultRetiredPID() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        defer { if !AppReplay.replaying, child.isRunning { child.terminate(); child.waitUntilExit() } }
        let bytes = try AppReplay.query(kind: "test.host.spawn", input: JSONEncoder().encode(AppReplay.Launch(child))) {
            try child.run()
            return try JSONEncoder().encode(XCTUnwrap(AgentProcess.capture(child.processIdentifier)))
        }
        let process = try JSONDecoder().decode(AgentProcess.self, from: bytes)
        let before = HostProcessWatcher.alive(process)
        HostProcessWatcher.terminate(process)
        _ = try AppReplay.query(kind: "test.host.wait", input: JSONEncoder().encode(process)) {
            child.waitUntilExit()
            return Data()
        }
        XCTAssertEqual([before, HostProcessWatcher.alive(process)], [true, false])
        if AppReplay.replaying { XCTAssertEqual(child.processIdentifier, 0) }
    }

    // On the helper route a host move is the app's placement (Workspace.placeHostTerminal, run by the host
    // coordinator's synchronize); the old tmux/herdr move lock (hostMoves.isBusy) has no counterpart.
    // Pane processes are read from the test's own tmux server.

    /// The tmux process of a pane ("%3"); nil once the pane is gone.
    private func pid(_ app: TmuxWalkthrough, _ pane: String) -> String? {
        guard let pid = try? app.server(["display-message", "-p", "-t", pane, "#{pane_pid}"]).trimmingCharacters(in: .whitespacesAndNewlines), !pid.isEmpty else { return nil }
        return pid
    }

    /// What the workspace shows (spaces, their host, windows and terminals), for failure messages.
    private func shown(_ app: TmuxWalkthrough) -> String {
        app.workspace.spaces.map { space in
            "\(space.name)[\(space.id.uuidString.prefix(4)) host=\(space.hostID.rawValue) windows=\(space.containers.map { $0.terminals.map { String($0.id.uuidString.prefix(4)) }.joined(separator: "+") }) tabs=\(space.tabs.count)\(space.id == app.workspace.selectedSpace ? " selected" : "")]"
        }.joined(separator: " ") + " error=\(app.error ?? "none") active=\(app.workspace.activeSurfaceID?.uuidString.prefix(4) ?? "none") tmux=\((try? app.server(["list-windows", "-a", "-F", "#{session_name}:#{window_id}:#{window_panes}"])) ?? "")"
    }

    private func panes(_ app: TmuxWalkthrough) -> String { (try? app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])) ?? "" }

    func testDisconnectDuringTmuxHostMoveReleasesSidebarLock() async throws {
        for queuedReturn in [false, true] {
            let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
            _ = try app.server(["new-window", "-t", "edge", "/bin/sh"])
            try await app.attach(); try await app.ready()
            let terminal = try XCTUnwrap(app.workspace.activeSurfaceID)
            let processes = panes(app)
            // The server stops answering mid-move (the old test discarded the move's tmux command).
            try app.stall()
            let generation = UUID()
            app.workspace.hosts.begin(terminal, generation: generation, destination: "test-remote")
            app.workspace.placeHostTerminal(terminal)
            if queuedReturn { app.workspace.restoreHostTerminal(terminal, generation: generation) }
            try app.disconnect()
            app.resume()
            XCTAssertTrue(app.workspace.allTabIDs.contains(terminal))
            try await app.wait { self.panes(app) == processes }
        }
    }

    func testFirstShellOfNewTmuxServerHasPrivateSSHWrapper() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try app.server(["kill-server"])
        try await app.attach(command: "export PATH=\(TestSupport.path):$PATH; tmux -u -L \(app.socket) -f /dev/null -CC new-session -s edge /bin/zsh")
        try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab), view = try XCTUnwrap(app.runtime.views[tab.id])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: view)
        try await TestSupport.eventually(timeout: .seconds(20)) { app.workspace.hosts.terminals[tab.id]?.authenticated == true }
        XCTAssertTrue(app.runtime.ssh.links.values.contains { $0.launch.tabID == tab.id })
        TerminalTestSupport.send("exit", to: view)
        try await TestSupport.eventually { app.workspace.hosts.terminals[tab.id] == nil }
    }

    func testCloseAndDetachDuringTmuxHostMoveFollowTheOriginalTerminals() async throws {
        for action in 0..<3 {
            let closing = action != 0
            let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
            _ = try app.server(["new-window", "-t", "edge", "/bin/sh"])
            try await app.attach(); try await app.ready()
            let original = try XCTUnwrap(app.workspace.current), terminal = try XCTUnwrap(app.workspace.activeSurfaceID)
            let window = try XCTUnwrap(original.activeWindow), target = try XCTUnwrap(app.target(window))
            app.workspace.hosts.begin(terminal, generation: UUID(), destination: "test-remote")
            app.workspace.placeHostTerminal(terminal)
            if action == 2 {
                // Closing the moving terminal's window ends it on the server (the old closeWindow).
                let container = try XCTUnwrap(app.workspace.spaces.flatMap(\.containers).first { $0.id == window.id })
                app.workspace.helper(containing: window.id)?.close(container.node, policy: .terminate)
                try await TestSupport.eventually(timeout: .seconds(12)) {
                    !app.workspace.allTabIDs.contains(terminal) && !((try? app.server(["list-windows", "-a", "-F", "#{window_id}"])) ?? "").contains(target)
                }
                XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}"]).split(separator: "\n").count, 1,
                               "Closing one window during regrouping preserves the other window")
                continue
            } else if closing { app.workspace.closeSpace(original.id, policy: .terminate) }
            else { app.workspace.detachSpace(original.id) }
            // The session's spaces leave (the moved terminal's too); closing ends its panes, detaching keeps them.
            try await TestSupport.eventually(timeout: .seconds(12), diagnostic: "Close during host move: action=\(action) terminal=\(terminal) attached=\(app.attached) spaces=\(app.workspace.spaces.map { ($0.id, $0.node, $0.backend, $0.tabs.map(\.id)) }) helper=\(app.runtime.helpers[.local]?.error ?? "none")") {
                !app.attached && !app.workspace.allTabIDs.contains(terminal) && (!closing || panes(app).isEmpty)
            }
            if closing { XCTAssertTrue(panes(app).isEmpty) }
            else { XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}"]).split(separator: "\n").count, 2) }
        }
    }

    func testNewTmuxShellWrapsSSHAndCommandNOffersTheOwningBackend() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try app.server(["set-option", "-g", "default-shell", "/bin/zsh"])
        try await app.attach(); try await app.ready()
        let original = try XCTUnwrap(app.workspace.current)
        app.workspace.newTab()
        try await app.wait { app.workspace.current?.windows.count == 2 && app.workspace.activeTab?.id != original.activeTab?.id }
        try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab), view = try XCTUnwrap(app.runtime.views[tab.id])
        let window = try XCTUnwrap(app.target(try XCTUnwrap(app.workspace.current?.activeWindow)))
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: view)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: shown(app)) {
            app.workspace.hosts.terminals[tab.id]?.authenticated == true && app.workspace.current?.id != original.id && app.workspace.activeSurfaceID == tab.id
        }
        let host = try XCTUnwrap(app.workspace.hosts.terminals[tab.id]).host
        XCTAssertTrue(app.workspace.followsDetectedSSH)
        let session = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == tab.id })
        // Contextual shells clear forwarding and RemoteCommand. Their resolved
        // configuration needs its own explicit test grant before authentication.
        try await server.authorize(arguments: session.launch.shell.arguments)
        app.controller.newSpace()
        let created = try XCTUnwrap(app.workspace.activeTab)
        XCTAssertNil(app.workspace.current?.backend, "A plain shell space, not a multiplexer's")
        _ = created
        XCTAssertEqual(app.workspace.current?.hostID, host, "The new SSH space is seeded before authentication")
        try await TestSupport.eventually(timeout: .seconds(20)) { app.workspace.hosts.terminals[created.id]?.authenticated == true }
        app.workspace.closeSpace(app.workspace.selectedSpace!)
        app.workspace.selectTab(tab.id)
        try await PresentationTestSupport.chooseNewSpace("New tmux space", in: app.workspace)
        try await TestSupport.eventually(diagnostic: shown(app)) { app.workspace.current?.hostID == .local && app.workspace.current?.structured == true }
        app.workspace.selectTab(tab.id)
        TerminalTestSupport.send("exit", to: view)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            app.workspace.hosts.terminals[tab.id] == nil && app.workspace.spaces.first(where: { $0.id == original.id })?.windows.contains(where: { app.target($0) == window }) == true
        }
        XCTAssertEqual(app.workspace.activeSurfaceID, tab.id, "Return from SSH: selected=\(String(describing: app.workspace.selectedSpace)) spaces=\(app.workspace.spaces.map { ($0.id, $0.node, $0.tabs.map(\.id)) })")
        XCTAssertTrue(app.runtime.views[tab.id] === view)
    }

    func testManualTmuxWindowMoveSupersedesAutomaticReturn() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try app.server(["set-option", "-g", "default-shell", "/bin/zsh"])
        try await app.attach(); try await app.ready()
        app.workspace.newTab()
        try await app.wait { app.workspace.current?.windows.count == 2 }
        try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab), view = try XCTUnwrap(app.runtime.views[tab.id])
        let command = "ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ")
        TerminalTestSupport.send(command, to: view)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: shown(app)) { app.workspace.hosts.terminals[tab.id]?.authenticated == true && app.workspace.current?.tabs.count == 1 }
        let window = try XCTUnwrap(app.workspace.current?.activeWindow)
        let automatic = app.workspace.selectedSpace
        app.workspace.moveWindowToNewSpace(window.id)
        XCTAssertNotEqual(app.workspace.selectedSpace, automatic, "The moved window shows in its new space at once: " + shown(app))
        try await TestSupport.eventually(diagnostic: "automatic=\(automatic?.uuidString.prefix(4) ?? "-") " + shown(app)) { app.workspace.selectedSpace != automatic && app.workspace.activeSurfaceID == tab.id }
        let manual = app.workspace.selectedSpace
        TerminalTestSupport.send("exit", to: view)
        try await app.wait { app.workspace.hosts.terminals[tab.id] == nil }
        XCTAssertEqual(app.workspace.selectedSpace, manual)
        TerminalTestSupport.send(command, to: view)
        try await TestSupport.eventually(timeout: .seconds(20)) { app.workspace.hosts.terminals[tab.id]?.authenticated == true }
        XCTAssertEqual(app.workspace.selectedSpace, manual)
        TerminalTestSupport.send("exit", to: view)
        try await app.wait { app.workspace.hosts.terminals[tab.id] == nil }
        XCTAssertEqual(app.workspace.current?.hostID, .local)
    }

    func testChangedAndMissingTmuxOriginsKeepTheLivePaneSeparate() async throws {
        for removeOrigin in [false, true] {
            let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
            let server = try await SSHTestServer(); defer { server.stop() }
            _ = try app.server(["new-window", "-t", "edge", "/bin/sh"])
            try await app.attach(); try await app.ready()
            let original = try XCTUnwrap(app.workspace.current), tab = try XCTUnwrap(app.workspace.activeTab)
            let view = try XCTUnwrap(app.runtime.views[tab.id]), pane = try XCTUnwrap(app.target(tab))
            let process = pid(app, pane)
            TerminalTestSupport.send((["/usr/bin/ssh"] + server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: view)
            try await TestSupport.eventually(timeout: .seconds(15)) {
                app.workspace.current?.id != original.id && app.workspace.hosts.terminals[tab.id] != nil
            }
            let extracted = app.workspace.selectedSpace
            let window = try XCTUnwrap(app.target(try XCTUnwrap(original.windows.first { $0.id != original.activeWindow?.id })))
            if removeOrigin { _ = try app.server(["kill-window", "-t", window]) }
            else { _ = try app.server(["split-window", "-h", "-t", window, "/bin/sh"]) }
            try await app.wait {
                let remaining = app.workspace.spaces.first { $0.id == original.id }
                return removeOrigin ? remaining == nil : remaining?.tabs.count == 2
            }
            TerminalTestSupport.send("exit", to: view)
            try await TestSupport.eventually(timeout: .seconds(15)) {
                app.workspace.hosts.terminals[tab.id] == nil
            }
            XCTAssertEqual(app.workspace.selectedSpace, extracted)
            XCTAssertEqual(app.workspace.current?.hostID, .local)
            XCTAssertEqual(pid(app, pane), process)
            XCTAssertTrue(app.runtime.views[tab.id] === view)
            app.workspace.closeTab(tab.id, policy: .terminate)
            try await TestSupport.eventually(diagnostic: shown(app)) { self.pid(app, pane) == nil }
        }
    }

    func testSSHInsideInactiveTmuxPaneUsesItsActualPTYAndPreservesServerSplit() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try app.server(["split-window", "-h", "-t", "edge", "/bin/sh"])
        _ = try app.server(["split-window", "-v", "-t", "edge", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let original = try XCTUnwrap(app.workspace.current), tab = try XCTUnwrap(app.workspace.activeTab)
        let view = try XCTUnwrap(app.runtime.views[tab.id]), surface = view.surface
        let pane = try XCTUnwrap(app.target(tab))
        let process = try XCTUnwrap(pid(app, pane))
        let membership = try app.server(["list-panes", "-s", "-F", "#{window_id}:#{pane_id}:#{pane_pid}"])
        let draft = app.runtime.chat.session(for: tab.id); draft.draft = "keep my tmux draft"
        let enabled = app.runtime.chat.enabled; app.runtime.chat.setEnabled(false)
        defer { app.runtime.chat.setEnabled(enabled) }
        // Deliberately inherit the gateway capability. Attribution must replace
        // that ID with the native pane whose real shell owns the new process.
        let environment = app.runtime.herdrLaunch.environment(for: app.origin!.id)
        let command = (["env"] + environment.map { $0.key + "=" + $0.value } + [Bundle.main.executablePath!, "--ssh-launch"]
                       + server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ")
        TerminalTestSupport.send(command, to: view)
        app.workspace.newLocalSpace()
        let selected = app.workspace.selectedSpace, focus = app.workspace.focusRequest
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Native tmux SSH attribution inside an existing split") {
            app.workspace.hosts.terminals[tab.id]?.authenticated == true
        }
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{window_id}:#{pane_id}:#{pane_pid}"]), membership)
        XCTAssertEqual(app.workspace.spaces.first { $0.id == original.id }?.windows.count, 1)
        XCTAssertEqual(app.workspace.spaces.first { $0.id == original.id }?.panes.count, 3)
        XCTAssertEqual(app.workspace.selectedSpace, selected)
        XCTAssertEqual(app.workspace.focusRequest, focus)
        XCTAssertTrue(app.runtime.ssh.links.values.contains { $0.launch.tabID == tab.id })
        XCTAssertFalse(app.runtime.ssh.links.values.contains { $0.launch.tabID == app.origin?.id })
        XCTAssertEqual(pid(app, pane), process)
        XCTAssertTrue(app.runtime.views[tab.id] === view); XCTAssertTrue(view.surface === surface)
        XCTAssertEqual(draft.draft, "keep my tmux draft")
        app.workspace.selectTab(tab.id); try await app.ready()
        XCTAssertTrue(app.workspace.followsDetectedSSH)
        XCTAssertEqual(app.workspace.owningMachine, .local)
        TerminalTestSupport.send("exit", to: view)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Return tmux pane: \(app.runtime.helpers[.local]?.error ?? "no error")") {
            app.workspace.hosts.terminals[tab.id] == nil && app.workspace.spaces.first(where: { $0.id == original.id })?.tabs.contains(where: { $0.id == tab.id }) == true
        }
        XCTAssertEqual(app.workspace.activeSurfaceID, tab.id)
        XCTAssertEqual(pid(app, pane), process)
        XCTAssertEqual(Set(app.workspace.spaces.first(where: { $0.id == original.id })!.tabs.map(\.id)), Set(original.tabs.map(\.id)))
        XCTAssertTrue(app.runtime.views[tab.id] === view); XCTAssertTrue(view.surface === surface)
        XCTAssertEqual(draft.draft, "keep my tmux draft")
    }

    func testSSHInsideHerdrSplitPreservesStableTerminalAndRestoresGeometry() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { _ = try? HerdrSocket(path: socket).request("server.stop") }
        let launcher = try XCTUnwrap(app.workspace.activeTab).id
        try await app.wait { app.runtime.views[launcher]?.surface != nil }
        let launchView = app.runtime.views[launcher]!
        TerminalTestSupport.send("export PATH=\(TestSupport.path):/usr/bin:/bin:$PATH; export XDG_CONFIG_HOME=\(HerdrLaunch.quote(server.root.path)); export XDG_STATE_HOME=\(HerdrLaunch.quote(server.root.path)); export HERDR_SOCKET_PATH=\(HerdrLaunch.quote(socket)); herdr", to: launchView)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        let original = try XCTUnwrap(app.workspace.current)
        // The first pane: its app tab and herdr's ids (terminal id = helper node key, pane id from the server).
        let first = try XCTUnwrap(HerdrTestSupport.panes(app.workspace, socket: socket).first)
        let terminalID = try XCTUnwrap(app.workspace.spaces.flatMap(\.tabs).first { $0.id == first.id }.flatMap(app.workspace.key(of:)))
        func api(_ method: String, _ params: [String: Any]) throws -> Data {
            try HerdrSocket(path: socket).request(method, params: JSONSerialization.data(withJSONObject: params))
        }
        _ = try api("pane.split", ["target_pane_id": first.pane, "direction": "right", "ratio": 0.62])
        try await TestSupport.eventually { app.workspace.spaces.first { $0.id == original.id }?.tabs.count == 2 }
        app.workspace.selectSurface(first.id)
        try await TestSupport.eventually { app.runtime.views[first.id]?.surface != nil }
        let view = app.runtime.views[first.id]!, surface = view.surface
        let before = try HerdrTestSupport.snapshot(socket), originalIDs = Set(before.panes.map(\.terminal_id))
        let draft = app.runtime.chat.session(for: first.id); draft.draft = "keep my herdr draft"
        let enabled = app.runtime.chat.enabled; app.runtime.chat.setEnabled(false)
        defer { app.runtime.chat.setEnabled(enabled) }
        // An existing backend shell bypasses the wrapper, so its destination is
        // known while authenticated identity and OS honestly remain unavailable.
        TerminalTestSupport.send((["/usr/bin/ssh"] + server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: view)
        app.workspace.newLocalSpace(); let selected = app.workspace.selectedSpace
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Herdr native SSH extraction") {
            app.workspace.spaces.contains { $0.hostID != .local && $0.tabs.flatMap(\.surfaceIDs) == [first.id] }
        }
        XCTAssertEqual(app.workspace.selectedSpace, selected)
        XCTAssertEqual(app.workspace.hosts.terminals[first.id]?.state, .unverified)
        let moved = try HerdrTestSupport.snapshot(socket)
        XCTAssertEqual(Set(moved.panes.map(\.terminal_id)), originalIDs)
        XCTAssertNotEqual(moved.panes.first(where: { $0.terminal_id == terminalID })?.pane_id, first.pane)
        XCTAssertTrue(app.runtime.views[first.id] === view); XCTAssertTrue(view.surface === surface)
        app.workspace.selectSurface(first.id)
        TerminalTestSupport.send("exit", to: view)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Herdr native SSH restoration") {
            app.workspace.hosts.terminals[first.id] == nil && app.workspace.spaces.first(where: { $0.id == original.id })?.tabs.flatMap(\.surfaceIDs).contains(first.id) == true
        }
        let after = try HerdrTestSupport.snapshot(socket)
        XCTAssertEqual(Set(after.panes.map(\.terminal_id)), originalIDs)
        XCTAssertEqual(after.layouts.first?.splits?.map(\.direction), before.layouts.first?.splits?.map(\.direction))
        XCTAssertEqual(after.layouts.first?.splits?.map(\.ratio), before.layouts.first?.splits?.map(\.ratio))
        XCTAssertTrue(app.runtime.views[first.id] === view); XCTAssertTrue(view.surface === surface)
        XCTAssertEqual(draft.draft, "keep my herdr draft")
        app.workspace.selectSurface(first.id)
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: view)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "New local herdr shells have the private SSH wrapper") {
            app.workspace.hosts.terminals[first.id]?.authenticated == true
        }
        XCTAssertTrue(app.runtime.ssh.links.values.contains { $0.launch.tabID == first.id })
        TerminalTestSupport.send("exit", to: view)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            app.workspace.hosts.terminals[first.id] == nil
        }
        // An external layout change during SSH must survive the return attempt.
        app.workspace.selectSurface(first.id)
        TerminalTestSupport.send("/usr/bin/ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: view)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            app.workspace.current?.id != original.id && app.workspace.hosts.terminals[first.id] != nil
        }
        let separate = app.workspace.selectedSpace
        let remaining = try XCTUnwrap(app.workspace.spaces.first { $0.id == original.id }?.tabs.first)
        let remainingPane = try XCTUnwrap(HerdrTestSupport.pane(of: remaining.id, in: app.workspace, socket: socket))
        _ = try api("pane.split", ["target_pane_id": remainingPane, "direction": "down", "ratio": 0.7])
        try await TestSupport.eventually { app.workspace.spaces.first { $0.id == original.id }?.tabs.flatMap(\.surfaceIDs).count == 2 }
        let changed = try HerdrTestSupport.snapshot(socket), ids = Set(changed.panes.map(\.terminal_id))
        TerminalTestSupport.send("exit", to: view)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            app.workspace.hosts.terminals[first.id] == nil
        }
        XCTAssertEqual(app.workspace.selectedSpace, separate)
        XCTAssertEqual(app.workspace.current?.hostID, .local)
        let final = try HerdrTestSupport.snapshot(socket)
        XCTAssertEqual(Set(final.panes.map(\.terminal_id)), ids)
        XCTAssertTrue(app.runtime.views[first.id] === view)
        XCTAssertEqual(draft.draft, "keep my herdr draft")
        let closing = try XCTUnwrap(app.workspace.spaces.first { $0.id == original.id })
        let closingIDs = Set(closing.tabs.flatMap(\.surfaceIDs))
        let closingTerminal = try XCTUnwrap(closingIDs.first)
        app.workspace.hosts.begin(closingTerminal, generation: UUID(), destination: "test-remote")
        app.workspace.placeHostTerminal(closingTerminal)
        app.workspace.closeSpace(closing.id)
        try await TestSupport.eventually(timeout: .seconds(12)) { closingIDs.isDisjoint(with: app.workspace.allSurfaceIDs) }
        XCTAssertTrue(app.workspace.allSurfaceIDs.contains(first.id), "Closing the origin during a move preserves unrelated spaces")
    }
}
