import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class SSHHerdrIntegrationTests: XCTestCase {
    func testQuitAndRelaunchRetainsHerdrUntilExplicitReconnect() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { _ = try? HerdrSocket(path: socket).request("server.stop") }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[source]?.surface != nil }
        let origin = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: origin)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path)
            + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: origin)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        let surface = try XCTUnwrap(app.workspace.activeTab)
        let host = try XCTUnwrap(app.workspace.current?.hostID)
        try await app.wait { app.runtime.views[surface.id]?.surface != nil }
        let terminalKey = try XCTUnwrap(app.workspace.key(of: surface))
        let native = try XCTUnwrap(app.runtime.views[surface.id])
        TerminalTestSupport.send("RESTORE_COOKIE=still_here; printf 'BEFORE_%s\\n' READY", to: native)
        try await app.wait { TerminalTestSupport.screen(terminal: native).contains("BEFORE_READY") }
        let store = HostSessionStore(url: server.root.appendingPathComponent("host-session.json"))
        try store.save(runtime: app.runtime)
        app.window.contentView = nil
        await app.runtime.stop().value
        app.workspace.spaces = []
        app.runtime.start(preferences: app.controller.settings.values)
        XCTAssertTrue(store.restore(runtime: app.runtime))
        app.window.contentView = NSHostingView(rootView: MainView(workspace: app.workspace, settings: app.controller.settings, controller: app.controller))
        try await app.wait { app.runtime.views[surface.id]?.window != nil }
        XCTAssertNil(app.runtime.views[surface.id]?.surface)
        XCTAssertNil(app.window.attachedSheet)
        XCTAssertEqual(app.workspace.hosts.state(host), .disconnected)
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: surface.id)
        try await TestSupport.eventually(timeout: .seconds(30)) {
            app.runtime.hosts.reconnect.state(for: surface.id) == nil && app.runtime.views[surface.id]?.surface != nil
        }
        let restored = try XCTUnwrap(app.runtime.views[surface.id])
        TerminalTestSupport.send("printf 'RESTORED_%s\\n' \"$RESTORE_COOKIE\"", to: restored)
        try await app.wait { TerminalTestSupport.screen(terminal: restored).contains("RESTORED_still_here") }
        XCTAssertEqual(app.workspace.activeTab.flatMap { app.workspace.key(of: $0) }, terminalKey)
    }

    func testRemovingHerdrPermissionRetainsRecovery() async throws {
        try await checkPermissionRecovery(grant: .init(profile: .statistics))
    }

    func testDisablingHelperRetainsHerdrRecovery() async throws {
        try await checkPermissionRecovery(grant: .init(profile: .ordinary))
    }

    func testRemovingOnlyHerdrPermissionRetainsRecovery() async throws {
        try await checkPermissionRecovery(grant: .init(helperEnabled: true,
            features: Set(SSHIntegrationFeature.allCases).subtracting([.herdr])))
    }

    func testHerdrThenTmuxRevocationRetainsBothSessions() async throws {
        try await checkPermissionRecovery(grant: .init(profile: .statistics), tmuxFirst: false)
    }

    func testTmuxThenHerdrRevocationRetainsBothSessions() async throws {
        try await checkPermissionRecovery(grant: .init(profile: .statistics), tmuxFirst: true)
    }

    private func checkPermissionRecovery(grant: SSHIntegrationGrant, tmuxFirst: Bool? = nil) async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        // The origin shell later carries its own Chat context and launches tmux; only herdr keeps it.
        app.workspace.closeLaunching["herdr"] = false
        let server = try await SSHTestServer(); defer { server.stop() }
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { _ = try? HerdrSocket(path: socket).request("server.stop") }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[source]?.surface != nil }
        let origin = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: origin)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        let login = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == source })
        TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path)
            + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: origin)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        let surface = try XCTUnwrap(app.workspace.activeTab)
        let endpoint = try XCTUnwrap(app.workspace.current?.hostID)
        let host = try XCTUnwrap(app.workspace.current?.hostID)
        try await app.wait { app.runtime.views[surface.id]?.surface != nil }
        let native = try XCTUnwrap(app.runtime.views[surface.id])
        TerminalTestSupport.send("HERDR_RECOVERY_COOKIE=$$; printf 'BEFORE_PERMISSION_%s\\n' READY", to: native)
        try await app.wait { TerminalTestSupport.screen(terminal: native).contains("BEFORE_PERMISSION_READY") }
        // Bind synthetic chat state to the remote helper's terminal without launching an agent; busy
        // state with a queue operation in flight keeps the queued message in the app.
        let remote = HelperWorkspace.Endpoint.remote(login.launch.connectionID)
        let chat = app.runtime.chat.session(for: surface.id)
        chat.helper = HelperChat(terminal: try XCTUnwrap(surface.terminal), endpoint: remote)
        chat.process = AgentProcess(executable: "/bin/codex", pid: 4242, startedSeconds: 0, startedMicroseconds: 0)
        chat.active = true; chat.busy = true; chat.discoveryBlocked = false; chat.terminalAttention = nil
        XCTAssertTrue(app.runtime.chat.enabled)
        XCTAssertTrue(chat.supportsQueue)
        chat.queueBusy = true; chat.draft = "Queued before revocation"; app.runtime.chat.queue(chat); chat.queueBusy = false
        XCTAssertEqual(chat.queuedMessages.count, 1)
        chat.draft = "Unsent draft"
        var decision: PendingApproval.Decision?
        let approval = PendingApproval(key: "native-permission-test", operation: "test operation") { decision = $0.decision }
        chat.approvals.append(approval)
        let originChat = app.runtime.chat.session(for: source)
        originChat.helper = HelperChat(terminal: try XCTUnwrap(app.runtime.ssh.helper4(for: source)?.terminal), endpoint: remote)
        originChat.active = true
        var tmuxSurface: UUID?
        var tmuxProcesses: String?
        if let tmuxFirst {
            app.workspace.selectTab(source)
            try await app.attach(); try await app.ready()
            let id = try XCTUnwrap(app.workspace.activeSurfaceID)
            tmuxSurface = id
            tmuxProcesses = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
            let tmuxView = try XCTUnwrap(app.runtime.views[id])
            app.runtime.ssh.permissions.save(.init(helperEnabled: true,
                features: Set(SSHIntegrationFeature.allCases).subtracting([tmuxFirst ? .tmux : .herdr])), for: login.scope)
            let affected = tmuxFirst ? tmuxView : native
            let healthy = tmuxFirst ? native : tmuxView
            XCTAssertTrue(affected.inputParked)
            XCTAssertFalse(healthy.inputParked)
            XCTAssertNil(app.runtime.link(of: affected.id))
            XCTAssertNotNil(app.runtime.link(of: healthy.id))
            TerminalTestSupport.send("printf 'HEALTHY_NATIVE_%s\\n' READY", to: healthy)
            try await app.wait { TerminalTestSupport.screen(terminal: healthy).contains("HEALTHY_NATIVE_READY") }
        }
        app.runtime.ssh.permissions.save(grant, for: login.scope)
        if grant.profile == .ordinary {
            try await app.wait { app.runtime.ssh.links[login.launch.connectionID] == nil }
        }
        _ = try XCTUnwrap(app.runtime.hosts.reconnect.state(for: surface.id), "Revoked herdr integration must remain recoverable")
        XCTAssertFalse(chat.active)
        XCTAssertFalse(chat.busy)
        XCTAssertEqual(chat.draft, "Unsent draft")
        XCTAssertEqual(chat.queuedMessages.map(\.text), ["Queued before revocation"])
        XCTAssertNotNil(chat.queuePaused)
        XCTAssertFalse(approval.pending)
        XCTAssertEqual(decision, .terminal, "The pending approval returns to the terminal")
        XCTAssertNil(app.runtime.link(of: surface.id))
        XCTAssertNil(app.runtime.ssh.statisticsConnection(for: surface.id))
        if grant.selectedFeatures.contains(.chat) {
            XCTAssertNotNil(app.runtime.link(of: source))
            XCTAssertTrue(originChat.active, "Revoking herdr must not end chat on the original SSH prompt")
            XCTAssertEqual(chat.status, "The terminal's integration is disabled. This transcript is read-only.")
        }
        if let tmuxSurface {
            _ = try XCTUnwrap(app.runtime.hosts.reconnect.state(for: tmuxSurface))
        } else {
            XCTAssertFalse(origin.inputParked, "Revoking native integration must leave the original SSH prompt usable")
            TerminalTestSupport.send("printf 'ORIGIN_AFTER_PERMISSION_%s\\n' READY", to: origin)
            try await app.wait { TerminalTestSupport.screen(terminal: origin).contains("ORIGIN_AFTER_PERMISSION_READY") }
        }
        app.runtime.ssh.permissions.save(login.grant, for: login.scope)
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: surface.id)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: app.runtime.hosts.reconnect.state(for: surface.id)?.error ?? "") {
            app.runtime.hosts.reconnect.state(for: surface.id) == nil
        }
        XCTAssertTrue(app.runtime.views[surface.id] === native)
        XCTAssertEqual(app.workspace.spaces.filter { $0.hostID == endpoint && $0.shows("herdr") }.count, 1)
        app.workspace.selectSurface(surface.id)
        try await app.wait { native.surface != nil && native.window === app.window }
        TerminalTestSupport.send("if [ \"$HERDR_RECOVERY_COOKIE\" = \"$$\" ]; then printf 'AFTER_PERMISSION_%s\\n' SAME_SHELL; fi", to: native)
        try await TestSupport.eventually(diagnostic: "parked=\(native.inputParked), context=\(app.runtime.link(of: surface.id) != nil), screen=\(TerminalTestSupport.screen(terminal: native))") {
            TerminalTestSupport.screen(terminal: native).contains("AFTER_PERMISSION_SAME_SHELL")
        }
        if let tmuxSurface {
            XCTAssertNil(app.runtime.hosts.reconnect.state(for: tmuxSurface))
            app.workspace.selectSurface(tmuxSurface)
            try await app.ready()
            XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), tmuxProcesses)
            XCTAssertEqual(app.workspace.spaces.filter { $0.shows("tmux") }.count, 1)
        }
    }

    func testDisconnectDuringCreationRecoversConfirmedHerdrTerminals() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { _ = try? HerdrSocket(path: socket).request("server.stop") }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[source]?.surface != nil }
        let origin = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: origin)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path)
            + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: origin)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        let original = try XCTUnwrap(app.workspace.activeTab), surface = original
        let endpoint = try XCTUnwrap(app.workspace.current?.hostID)
        let host = try XCTUnwrap(app.workspace.current?.hostID)
        try await app.wait { app.runtime.views[surface.id]?.surface != nil }
        let native = try XCTUnwrap(app.runtime.views[surface.id])
        TerminalTestSupport.send("printf 'HERDR_BEFORE_%s\\n' READY", to: native)
        try await app.wait { TerminalTestSupport.screen(terminal: native).contains("HERDR_BEFORE_READY") }
        for attempt in 0..<3 {
            app.workspace.newTab()
            XCTAssertTrue(app.workspace.activeTab?.isConnecting == true)
            app.runtime.hosts.disconnect(host)
            try await app.wait { app.runtime.hosts.reconnect.state(for: surface.id) != nil }
            XCTAssertFalse(app.workspace.spaces.filter { $0.hostID == endpoint && $0.shows("herdr") }.flatMap(\.tabs).contains { $0.isConnecting })
            app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: surface.id)
            try await TestSupport.eventually(timeout: .seconds(30), diagnostic: app.runtime.hosts.reconnect.state(for: surface.id)?.error ?? "") {
                app.runtime.hosts.reconnect.state(for: surface.id) == nil
            }
            XCTAssertTrue(app.runtime.views[surface.id] === native)
            XCTAssertTrue(app.workspace.allSurfaceIDs.contains(surface.id))
            app.workspace.selectTab(original.id)
            let receipt = server.root.appendingPathComponent("recovered-input-\(attempt)")
            TerminalTestSupport.send("printf READY > " + HerdrLaunch.quote(receipt.path) + "; printf 'HERDR_AFTER_\(attempt)_%s\\n' READY", to: native)
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "attempt=\(attempt), delivered=\(FileManager.default.fileExists(atPath: receipt.path)), screen=\(TerminalTestSupport.screen(terminal: native))") {
                TerminalTestSupport.screen(terminal: native).contains("HERDR_AFTER_\(attempt)_READY")
            }
        }
    }

    func testRemoteHerdrHandoffLayoutsScrollAndDetachKeepRemoteShell() async throws {
        let app = try TmuxWalkthrough(autoClose: false); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { if let api = try? HerdrSocket(path: socket) { try? api.request("server.stop") } }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let original = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: original)
        try await TestSupport.eventually(timeout: .seconds(20)) { app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil } }
        let tint = try XCTUnwrap(app.runtime.ssh.tint(for: try XCTUnwrap(app.workspace.activeTab)))
        let launch = "export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path) + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr"
        TerminalTestSupport.send(launch, to: original)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: original)) { app.workspace.current?.shows("herdr") == true }
        let space = try XCTUnwrap(app.workspace.current)
        let endpoint = space.hostID
        XCTAssertNotEqual(endpoint, .local)
        XCTAssertEqual(app.runtime.ssh.tint(for: try XCTUnwrap(space.activeTab)), tint)
        XCTAssertTrue(app.workspace.allTabIDs.contains(source), "With auto-close off, remote herdr keeps its original SSH shell")
        guard case .ssh(let shell) = app.workspace.currentMachine else { return XCTFail("Remote herdr lost its machine") }
        XCTAssertEqual(shell.destination, server.destination)
        let surface = try XCTUnwrap(app.workspace.activeTab)
        try await app.wait { app.runtime.views[surface.id]?.surface != nil }
        let native = try XCTUnwrap(app.runtime.views[surface.id])
        TerminalTestSupport.send("printf 'SSH_HERDR_%s · caffè 漢字\\n' READY", to: native)
        try await TestSupport.eventually(timeout: .seconds(8), diagnostic: TerminalTestSupport.screen(terminal: native)) {
            TerminalTestSupport.screen(terminal: native).contains("SSH_HERDR_READY · caffè 漢字")
        }
        TerminalTestSupport.send("for i in {1..200}; do printf 'REMOTE_SCROLL_%s\\n' $i; done", to: native)
        try await app.wait { TerminalTestSupport.screen(terminal: native).contains("REMOTE_SCROLL_200") }
        try await TestSupport.eventually { native.scrollbar.state.canScroll }
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 30, wheel2: 0, wheel3: 0))
        native.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        try await TestSupport.eventually { !TerminalTestSupport.screen(terminal: native).contains("REMOTE_SCROLL_200") }
        app.workspace.newTab()
        try await app.wait { app.workspace.currentTabs.count == 2 && app.workspace.activeTab?.isConnecting == false }
        XCTAssertTrue(app.workspace.applyLayout(.columns))
        XCTAssertEqual(app.workspace.current?.panes.count, 2)
        XCTAssertTrue(app.workspace.current!.panes.allSatisfy { $0.activeTab.map { app.runtime.ssh.tint(for: $0) == tint } == true })
        try await Task.sleep(for: .milliseconds(300))
        _ = try await PresentationTestSupport.capture(app.window, named: "tint-herdr-splits", in: "host-tint-validation")
        app.workspace.renameSpace(space.id, to: "Remote workspace")
        try await app.wait { app.workspace.current?.name == "Remote workspace" }
        app.workspace.detachSpace(space.id)
        try await app.wait { !app.workspace.spaces.contains { $0.hostID == endpoint && $0.shows("herdr") } }
        XCTAssertTrue(app.workspace.allTabIDs.contains(source))
        // The remote server survives a native detach and can be reattached from
        // the same SSH prompt with the same stable backend identities.
        app.workspace.selectTab(source)
        TerminalTestSupport.send("herdr", to: original)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: original)) { app.workspace.current?.hostID == endpoint && app.workspace.current?.shows("herdr") == true }
        XCTAssertEqual(app.workspace.current?.name, "Remote workspace")
        XCTAssertEqual(app.runtime.ssh.tint(for: try XCTUnwrap(app.workspace.activeTab)), tint)
        let restored = try XCTUnwrap(app.workspace.activeTab)
        try await app.wait { app.runtime.views[restored.id]?.surface != nil }
        let view = try XCTUnwrap(app.runtime.views[restored.id])
        TerminalTestSupport.send("printf 'REMOTE_%s\\n' REATTACHED", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("REMOTE_REATTACHED") }
        let originalWorkspace = try XCTUnwrap(app.workspace.current?.id)
        app.workspace.newSpace(on: space.hostID, backend: .herdr)
        try await TestSupport.eventually(diagnostic: "New Herdr space: host=\(endpoint) original=\(originalWorkspace) selected=\(String(describing: app.workspace.selectedSpace)) spaces=\(app.workspace.spaces.map { ($0.id, $0.backend, $0.hostID, $0.tabs.map(\.isConnecting)) }) helper=\(app.runtime.helpers[.local]?.error ?? "none")") { app.workspace.current?.id != originalWorkspace && app.workspace.current?.hostID == endpoint && app.workspace.current?.shows("herdr") == true && app.workspace.activeTab?.isConnecting == false }
        XCTAssertEqual(app.workspace.spaces.filter { $0.hostID == endpoint && $0.shows("herdr") }.count, 2)
        guard case .ssh = app.workspace.currentMachine else { return XCTFail("New herdr workspace lost its SSH host") }
        app.workspace.closeSpace(try XCTUnwrap(app.workspace.current?.id))
        try await app.wait { app.workspace.spaces.filter { $0.hostID == endpoint && $0.shows("herdr") }.count == 1 }
        app.workspace.selectSpace(originalWorkspace)
        app.workspace.closeSpace(try XCTUnwrap(app.workspace.current?.id))
        try await app.wait { !app.workspace.spaces.contains { $0.hostID == endpoint && $0.shows("herdr") } }
        struct Snapshot: Decodable { let snapshot: HerdrSnapshot }
        try await TestSupport.eventually {
            let remaining = try JSONDecoder().decode(Snapshot.self, from: HerdrSocket(path: socket).request("session.snapshot"))
            return remaining.snapshot.workspaces.isEmpty
        }
    }

    /// Like tmux -CC: the launching tab closes, and the herdr views keep its SSH connection until the last one detaches.
    func testRemoteHerdrAutoCloseKeepsConnectionUntilLastViewDetaches() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let sidebar = app.sidebarShown()
        let server = try await SSHTestServer(); defer { server.stop() }
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { if let api = try? HerdrSocket(path: socket) { try? api.request("server.stop") } }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let original = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: original)
        try await TestSupport.eventually(timeout: .seconds(20)) { app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil } }
        let connection = try XCTUnwrap(app.runtime.ssh.links.first { $0.value.launch.tabID == source }?.key)
        TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path)
            + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: original)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: original)) {
            app.workspace.current?.shows("herdr") == true && !app.workspace.allTabIDs.contains(source)
        }
        XCTAssertEqual(app.workspace.spaces.count, 1)
        XCTAssertFalse(sidebar.withLock { $0 }, "One space throughout: the SSH login's handoff to herdr must not show the sidebar")
        let space = try XCTUnwrap(app.workspace.current)
        let endpoint = space.hostID
        XCTAssertNotEqual(endpoint, .local)
        // The launching shell's channel closing must not take the helper connection with it.
        try await Task.sleep(for: .seconds(2))
        XCTAssertNotNil(app.runtime.helpers[.remote(connection)])
        XCTAssertNil(app.runtime.helpers[.remote(connection)]?.error)
        XCTAssertNotNil(app.runtime.ssh.links[connection])
        let surface = try XCTUnwrap(app.workspace.activeTab)
        try await app.wait { app.runtime.views[surface.id]?.surface != nil }
        let native = try XCTUnwrap(app.runtime.views[surface.id])
        TerminalTestSupport.send("printf 'AFTER_%s\\n' CLOSE", to: native)
        try await TestSupport.eventually(timeout: .seconds(8), diagnostic: TerminalTestSupport.screen(terminal: native)) {
            TerminalTestSupport.screen(terminal: native).contains("AFTER_CLOSE")
        }
        app.workspace.detachSpace(space.id)
        try await app.wait { !app.workspace.spaces.contains { $0.hostID == endpoint && $0.shows("herdr") } }
        try await TestSupport.eventually(timeout: .seconds(10)) { app.runtime.ssh.links[connection] == nil }
    }
}
