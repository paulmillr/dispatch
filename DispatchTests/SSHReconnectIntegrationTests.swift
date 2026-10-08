import AppKit
import SwiftUI
import Term
import XCTest
import Vision
@testable import DispatchApp

@MainActor
final class SSHReconnectIntegrationTests: XCTestCase {
    func testOfflineSpaceGroupingAndNameArePersistedAfterReconnect() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        _ = try await connect(app, server: server, surface: source)
        try await app.attach(); try await app.ready()
        app.workspace.newTab()
        try await app.wait { app.workspace.current?.containers.count == 2 && app.workspace.activeTab?.isConnecting == false }
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let original = try XCTUnwrap(app.workspace.current)
        let window = try XCTUnwrap(original.containers.first { $0.terminals.contains { $0.id == tab.id } })
        let host = try XCTUnwrap(app.workspace.hosts.terminals[tab.id]).host
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: tab.id) != nil }
        app.workspace.moveWindowToNewSpace(window.id)
        let moved = try XCTUnwrap(app.workspace.current)
        XCTAssertNotEqual(moved.id, original.id)
        XCTAssertEqual(moved.containers.map(\.id), [window.id])
        app.workspace.renameSpace(moved.id, to: "Offline research")
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: tab.id)
        try await TestSupport.eventually(timeout: .seconds(30)) { app.runtime.hosts.reconnect.state(for: tab.id) == nil }
        try await TestSupport.eventually {
            app.workspace.spaces.first { $0.id == moved.id }?.name == "Offline research"
                && app.workspace.spaces.first { $0.id == moved.id }?.containers.map(\.id) == [window.id]
        }
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testStoppingDisconnectedTmuxClearsRetainedSessionsWithoutKillingServer() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        _ = try await connect(app, server: server, surface: source)
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[tab.id]).host
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: tab.id) != nil }
        var preferences = app.runtime.preferences
        preferences.spaces[on: "tmux"] = false
        try app.runtime.apply(preferences)
        XCTAssertFalse(app.workspace.spaces.contains(where: \.structured))
        XCTAssertTrue(app.workspace.spaces.allSatisfy { !$0.shows("tmux") })
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testTmuxSuspensionDropsInputAndPreservesBackendState() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab), view = try XCTUnwrap(app.runtime.views[tab.id])
        let host = try XCTUnwrap(app.workspace.hosts.terminals[tab.id]?.host)
        let panes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: tab.id) != nil }
        TerminalTestSupport.send("printf 'NEVER_%s\\n' REPLAY", to: view)
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), panes)
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: tab.id)
        try await TestSupport.eventually(timeout: .seconds(30)) {
            app.runtime.hosts.reconnect.state(for: tab.id) == nil && app.workspace.activeTab?.id == tab.id
        }
        try await app.ready()
        TerminalTestSupport.send("printf 'RESUMED_%s\\n' READY", to: try XCTUnwrap(app.runtime.views[tab.id]))
        try await app.wait { app.runtime.views[tab.id].map { TerminalTestSupport.screen(terminal: $0).contains("RESUMED_READY") } == true }
        let screen = TerminalTestSupport.screen(terminal: try XCTUnwrap(app.runtime.views[tab.id]))
        XCTAssertFalse(screen.contains("NEVER_REPLAY"))
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), panes)
    }
    func testResetSSHInsideLocalTmuxKeepsNativePaneAndReturnsToLocalShell() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attach(); try await app.ready()
        let pane = try XCTUnwrap(app.workspace.activeTab)
        let terminal = try XCTUnwrap(app.runtime.views[pane.id])
        let server = try await SSHTestServer(); defer { server.stop() }
        // The fixture server predates Dispatch; explicitly supply the gateway
        // capability just as the native shell integration does for new servers.
        let environment = app.runtime.herdrLaunch.environment(for: try XCTUnwrap(app.origin?.id))
        let command = (["env"] + environment.map { $0.key + "=" + $0.value } + [Bundle.main.executablePath!, "--ssh-launch"]
            + server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ")
        TerminalTestSupport.send(command + "; printf 'LOCAL_EXIT_%s\\n' \"$?\"", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == pane.id && $0.shellPID != nil }
        }
        try await app.runtime.resetSSHState()
        XCTAssertTrue(app.attached, "Reset keeps the local tmux session")
        XCTAssertTrue(app.workspace.allSurfaceIDs.contains(pane.id))
        XCTAssertTrue(app.runtime.views[pane.id] === terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("LOCAL_EXIT_130") }
        TerminalTestSupport.send("printf 'RESET_TMUX_%s\\n' LOCAL", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("RESET_TMUX_LOCAL") }
        XCTAssertFalse(app.runtime.hasActiveSSHConnections)
    }

    func testResetAllDisconnectsSSHAndForgetsTmuxWithoutKillingRemoteJobs() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await app.attach(); try await app.ready()
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        let preferences = app.runtime.preferences
        XCTAssertTrue(app.runtime.hasActiveSSHConnections)
        try await app.controller.resetSSHState()
        XCTAssertFalse(app.runtime.hasActiveSSHConnections)
        XCTAssertTrue(app.runtime.ssh.links.isEmpty)
        XCTAssertTrue(app.runtime.ssh.permissions.entries.isEmpty)
        XCTAssertTrue(!app.workspace.spaces.contains(where: \.structured))
        XCTAssertTrue(app.workspace.detached.isEmpty)
        XCTAssertTrue(app.runtime.hosts.reconnect.recipes.isEmpty)
        XCTAssertTrue(SSHStatisticsStore.shared.series.isEmpty)
        XCTAssertEqual(Set(app.workspace.hosts.records.keys), [.local])
        XCTAssertTrue(app.workspace.spaces.allSatisfy { $0.hostID == .local && !$0.structured })
        XCTAssertEqual(app.runtime.preferences, preferences)
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(Set(app.workspace.hosts.records.keys), [.local], "Late discovery must not restore reset hosts")
    }

    func testForgettingDisconnectedTmuxHostPreservesRemoteJobs() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[tab.id]?.host)
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        app.runtime.hosts.disconnect(host)
        try await TestSupport.eventually { app.runtime.hosts.canForget(host) }
        app.runtime.hosts.forget(host)
        XCTAssertFalse(app.workspace.liveHosts.contains { $0.id == host })
        XCTAssertFalse(app.workspace.allTabIDs.contains(tab.id))
        XCTAssertFalse(app.workspace.detached.contains { $0.host == host })
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testQuitAndRelaunchKeepsShellOfflineUntilReconnect() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        _ = try await connect(app, server: server, surface: source)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[source]?.host)
        let store = HostSessionStore(url: server.root.appendingPathComponent("host-session.json"))
        try store.save(runtime: app.runtime)
        app.window.contentView = nil
        await app.runtime.stop().value
        app.workspace.spaces = []
        app.runtime.start(preferences: app.controller.settings.values)
        XCTAssertTrue(store.restore(runtime: app.runtime))
        app.window.contentView = NSHostingView(rootView: MainView(workspace: app.workspace, settings: app.controller.settings, controller: app.controller))
        try await app.wait { app.runtime.views[source]?.window != nil }
        XCTAssertNil(app.runtime.views[source]?.surface)
        XCTAssertNil(app.window.attachedSheet)
        XCTAssertTrue(app.runtime.ssh.links.isEmpty)
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: source)
        try await TestSupport.eventually(timeout: .seconds(30)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        XCTAssertEqual(app.workspace.hosts.state(host), .connected)
        let terminal = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("printf 'RELAUNCH_%s\\n' READY", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("RELAUNCH_READY") }
    }

    func testQuitAndRelaunchRetainsTmuxUntilExplicitReconnect() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[tab.id]?.host)
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        let store = HostSessionStore(url: server.root.appendingPathComponent("host-session.json"))
        try store.save(runtime: app.runtime)
        app.window.contentView = nil
        await app.runtime.stop().value
        app.workspace.spaces = []
        app.runtime.start(preferences: app.controller.settings.values)
        XCTAssertTrue(store.restore(runtime: app.runtime))
        app.window.contentView = NSHostingView(rootView: MainView(workspace: app.workspace, settings: app.controller.settings, controller: app.controller))
        try await app.wait { app.runtime.views[tab.id]?.window != nil }
        XCTAssertNil(app.runtime.views[tab.id]?.surface, "Restored tabs must not launch a process on mount")
        XCTAssertNil(app.window.attachedSheet)
        XCTAssertTrue(app.runtime.ssh.links.isEmpty)
        XCTAssertEqual(app.workspace.hosts.state(host), .disconnected)
        XCTAssertEqual(app.workspace.activeTab?.id, tab.id)
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: tab.id)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: "Restored tmux reconnect") {
            app.runtime.hosts.reconnect.state(for: tab.id) == nil && app.attached
        }
        try await app.ready()
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
        XCTAssertEqual(app.workspace.activeTab?.id, tab.id)
    }

    func testRemovingTmuxPermissionRetainsRecovery() async throws {
        try await checkRemovingTmuxPermission(grant: .init(profile: .statistics))
    }

    func testDisablingHelperRetainsNativeTmuxRecovery() async throws {
        try await checkRemovingTmuxPermission(grant: .init(profile: .ordinary))
    }

    private func checkRemovingTmuxPermission(grant: SSHIntegrationGrant) async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let login = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await app.attach(); try await app.ready()
        let surface = try XCTUnwrap(app.workspace.activeSurfaceID)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[surface]?.host)
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        app.runtime.ssh.permissions.save(grant, for: login.scope)
        if grant.profile == .ordinary {
            try await app.wait { app.runtime.ssh.links[login.launch.connectionID] == nil }
        }
        _ = try XCTUnwrap(app.runtime.hosts.reconnect.state(for: surface), "Revoked native integration must remain recoverable")
        app.runtime.ssh.permissions.save(login.grant, for: login.scope)
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: surface)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: "Reconnect after permission change") {
            app.runtime.hosts.reconnect.state(for: surface) == nil && app.attached
        }
        try await app.ready()
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
        XCTAssertEqual(app.workspace.spaces.filter { $0.structured }.count, 1)
    }

    func testDisablingRemoteChatKeepsDraftAndConnectedShell() async throws {
        try await checkDisablingRemoteChat(grant: .init(profile: .statistics))
    }

    func testDisablingHelperKeepsChatDraftAndConnectedShell() async throws {
        try await checkDisablingRemoteChat(grant: .init(profile: .ordinary))
    }

    func testRepeatedHelperDisableAndExitReturnsToLocalShell() async throws {
        for _ in 0..<20 { try await checkDisablingRemoteChat(grant: .init(profile: .ordinary)) }
    }

    func testHelperDisableThenControlDReturnsToLocalShell() async throws {
        try await checkDisablingRemoteChat(grant: .init(profile: .ordinary), controlD: true)
    }

    private func checkDisablingRemoteChat(grant: SSHIntegrationGrant, controlD: Bool = false) async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let login = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        let source = login.launch.tabID, shell = try XCTUnwrap(login.shellPID)
        let chat = app.runtime.chat.session(for: source)
        // A chat bound by the SSH host's helper (the app's state for it; no agent runs).
        chat.helper = HelperChat(terminal: 0, endpoint: .remote(login.launch.connectionID))
        chat.active = true; chat.busy = true
        chat.draft = "Unsent remote draft"
        app.runtime.ssh.permissions.save(grant, for: login.scope)
        if grant.profile == .ordinary {
            try await app.wait { app.runtime.ssh.links[login.launch.connectionID] == nil }
        }
        XCTAssertFalse(chat.active); XCTAssertFalse(chat.busy)
        XCTAssertEqual(chat.draft, "Unsent remote draft")
        XCTAssertEqual(chat.status, "Chat integration is disabled for this SSH configuration. This transcript is read-only.")
        let terminal = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("printf 'STILL_SSH_%s\\n' \"$$\"", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("STILL_SSH_\(shell)") }
        if grant.profile != .ordinary { XCTAssertNotNil(app.runtime.ssh.links[login.launch.connectionID]) }
        XCTAssertEqual(app.workspace.hosts.terminals[source]?.state, .connected)
        XCTAssertNil(app.runtime.hosts.reconnect.state(for: source))
        if controlD { TerminalTestSupport.key(2, "d", terminal, modifiers: .control) }
        else { TerminalTestSupport.send("exit 255", to: terminal) }
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Host: \(String(describing: app.workspace.hosts.terminals[source])); reconnect: \(String(describing: app.runtime.hosts.reconnect.state(for: source))); foreground: \(terminal.foregroundPID); launcher alive: \(login.launch.origin?.alive == true)\n" + TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("LOCAL_EXIT_\(controlD ? 0 : 255)") && app.workspace.hosts.terminals[source] == nil
        }
        XCTAssertNil(app.runtime.hosts.reconnect.state(for: source))
        TerminalTestSupport.send("printf 'LOCAL_AFTER_REDUCTION_%s\\n' OK", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("LOCAL_AFTER_REDUCTION_OK") }
    }

    func testGranularTmuxGrantPublishesShellLifecycle() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(helperEnabled: true, features: [.statistics, .tmux])); defer { server.stop() }
        let login = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        XCTAssertNotNil(login.shellPID)
        XCTAssertEqual(login.grant.selectedFeatures, [.statistics, .tmux])
        let terminal = try XCTUnwrap(app.runtime.views[login.launch.tabID])
        TerminalTestSupport.send("if typeset -f herdr >/dev/null; then printf 'UNEXPECTED_HERDR_%s\\n' WRAPPER; else printf 'NO_HERDR_%s\\n' WRAPPER; fi", to: terminal)
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("NO_HERDR_WRAPPER")
        }
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        try await app.attach(); try await app.ready()
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testIntegrationReconnectIncludesConnectionsStartedWhileSheetWasOpen() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        let first = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        XCTAssertEqual(first.grant.selectedFeatures, [.statistics])
        try await TestSupport.eventually {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
            app.window.makeKeyAndOrderFront(nil)
            return NSApp.keyWindow === app.window
        }
        app.runtime.ssh.editIntegration(first.scope)
        defer { if let sheet = app.window.attachedSheet { sheet.cancelOperation(nil) } }
        try await TestSupport.eventually { app.window.attachedSheet != nil }
        app.workspace.newLocalSpace()
        let second = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        XCTAssertEqual(second.scope, first.scope)
        let sheet = try XCTUnwrap(app.window.attachedSheet)
        let root = try XCTUnwrap(sheet.contentView)
        try XCTUnwrap(PresentationTestSupport.views(of: NSButton.self, in: root).first { $0.title == "Use defaults" }).performClick(nil)
        var attempted: Set<SSHConnectionID> = []
        let reconnect = app.runtime.hosts.reconnect
        let previousAttempt = reconnect.attempt
        reconnect.attempt = { attempted.insert($0.connection) }
        defer { reconnect.attempt = previousAttempt }
        try XCTUnwrap(PresentationTestSupport.views(of: NSButton.self, in: root).first { $0.title == "Save & reconnect" }).performClick(nil)
        try await TestSupport.eventually(diagnostic: "attempted=\(attempted), expected=\([first.launch.connectionID, second.launch.connectionID])") {
            attempted == [first.launch.connectionID, second.launch.connectionID]
        }
    }

    /// A detached remote space restores, detaches again and restores cleanly: same panes, same processes,
    /// no leftover entry or error.
    func testClosingRemoteDetachedRestoreAfterSSHStartsAllowsCleanRetry() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await app.attach(); try await app.ready()
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        let panes = Set(app.visiblePanes)
        for _ in 0..<2 {
            app.workspace.detachSpace(try XCTUnwrap(app.workspace.spaces.first(where: \.structured)).id)
            try await app.wait { !app.workspace.spaces.contains(where: \.structured) && app.workspace.detached.count == 1 }
            app.workspace.restoreDetached([try XCTUnwrap(app.workspace.detached.first).id])
            try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "errors=\(app.runtime.helpers.values.compactMap(\.error))") {
                app.workspace.spaces.contains { $0.structured && $0.tabs.allSatisfy { !$0.isConnecting } }
            }
        }
        XCTAssertEqual(app.runtime.helpers.values.compactMap(\.error), [], "A clean retry reports no failed restore")
        XCTAssertEqual(app.workspace.spaces.filter { $0.structured }.count, 1)
        XCTAssertEqual(Set(app.visiblePanes), panes)
        XCTAssertTrue(app.workspace.detached.isEmpty)
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testDetachedSSHRestoreRejectsMissingAndReplacementServers() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await app.attach(); try await app.ready()
        let original = try XCTUnwrap(Int32(app.server(["display-message", "-p", "#{pid}"]).trimmingCharacters(in: .whitespacesAndNewlines)))
        let socket = try app.socketPath()
        app.workspace.detachSpace(try XCTUnwrap(app.workspace.current).id)
        try await app.wait { !app.workspace.spaces.contains(where: \.structured) }
        let entry = try XCTUnwrap(app.workspace.detached.first)
        _ = try app.server(["kill-server"])
        try await TestSupport.eventually { AgentProcess.capture(original) == nil }
        // tmux may leave its socket file after exiting. Remove this fixture's
        // stale socket so an unexpected replacement is observable below.
        if FileManager.default.fileExists(atPath: socket) { try FileManager.default.removeItem(atPath: socket) }
        func errors() -> [String] { app.runtime.helpers.values.compactMap(\.error) }
        for replacement in [false, true] {
            var processes: String?
            if replacement {
                _ = try app.server(["-f", "/dev/null", "new-session", "-d", "-s", "edge", "/bin/sh"])
                let pid = try app.server(["display-message", "-p", "#{pid}"]).trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertNotEqual(pid, String(original))
                processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
            }
            app.workspace.restoreDetached([entry.id])
            try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Restore of a missing server must fail visibly") { !errors().isEmpty }
            try await TestSupport.eventually {
                // OCR reads monospaced "tmux" as "tux" at times; the banner's leading words identify it.
                try await PresentationTestSupport.capture(app.window).text().contains("Could not restore detached")
            }
            for helper in app.runtime.helpers.values { helper.dismissError() }
            XCTAssertEqual(errors(), [])
            XCTAssertEqual(app.workspace.detached.map(\.id), [entry.id])
            XCTAssertTrue(!app.workspace.spaces.contains(where: \.structured))
            XCTAssertTrue(app.workspace.spaces.allSatisfy { !$0.shows("tmux") })
            if let processes {
                XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: socket), "Restore must never start a replacement server")
            }
        }
    }

    func testFilteredRestoreAllLeavesUnmatchedDetachedSpaceAndProcessesUntouched() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await app.attach(); try await app.ready()
        app.controller.settings.values.hideSingleSpace = false
        var panes: [String: Set<String>] = [:]
        for name in ["Research match", "Unrelated archive"] {
            app.workspace.newSpace()
            try await app.wait { app.workspace.activeTab?.isConnecting == false }
            let space = try XCTUnwrap(app.workspace.current)
            app.workspace.renameSpace(space.id, to: name)
            try await app.wait { app.workspace.current?.name == name }
            panes[name] = Set(space.tabs.compactMap(app.target))
            app.workspace.detachSpace(space.id)
        }
        try await app.wait { app.workspace.detached.count == 2 }
        let unrelated = try XCTUnwrap(app.workspace.detached.first { $0.name == "Unrelated archive" })
        let matching = try XCTUnwrap(app.workspace.detached.first { $0.name == "Research match" })
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        let root = try XCTUnwrap(app.window.contentView)
        let input = try await PresentationTestSupport.openSpaceSearch(app.controller, in: root)
        for mode in [SpaceOrder.flat, .tree] {
            app.controller.settings.values.spaceOrder = mode
            app.window.makeFirstResponder(input)
            input.stringValue = "Research match"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: input)
            try await Task.sleep(for: .milliseconds(250))
            var button: CGRect?
            try await TestSupport.eventually {
                let labels = try await PresentationTestSupport.capture(app.window)
                    .recognizedText(in: CGRect(x: 0, y: 0, width: 264 / root.bounds.width, height: 1))
                guard !labels.contains(where: { $0.topCandidates(1).first?.string.contains("Unrelated archive") == true }) else { return false }
                button = try labels.compactMap { label -> CGRect? in
                    guard let text = label.topCandidates(1).first,
                          let range = text.string.range(of: "Restore all", options: .caseInsensitive) else { return nil }
                    return try text.boundingBox(for: range)?.boundingBox
                }.first
                return button != nil
            }
            let box = try XCTUnwrap(button), y = box.midY * root.bounds.height
            // Vision's substring box is normalized to the requested sidebar ROI.
            let point = root.convert(NSPoint(x: box.midX * 264, y: root.isFlipped ? root.bounds.height - y : y), to: nil)
            _ = try await PresentationTestSupport.capture(app.window, named: "filtered-restore-" + mode.rawValue, in: "sidebar-validation")
            try PresentationTestSupport.click(app.window, at: point)
            try await TestSupport.eventually(diagnostic: "mode=\(mode.rawValue) point=\(point) remaining=\(app.workspace.detached.map(\.name)) visible=\(app.workspace.spaces.map(\.name))") {
                app.workspace.detached.map(\.id) == [unrelated.id]
            }
            let restored = try XCTUnwrap(app.workspace.spaces.first { $0.structured && $0.name == matching.name })
            XCTAssertEqual(Set(restored.tabs.compactMap(app.target)), panes[matching.name])
            XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
            if mode == .flat {
                app.workspace.detachSpace(restored.id)
                try await app.wait { app.workspace.detached.count == 2 }
            }
        }
    }

    func testDetachedRemoteSpaceCanBeFilteredBySSHDestination() async throws {
        // Reads the sidebar through offscreen captures, which cannot draw Liquid Glass.
        let app = try TmuxWalkthrough(liquidGlass: false); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await app.attach(); try await app.ready()
        app.controller.settings.values.hideSingleSpace = false
        app.workspace.renameSpace(try XCTUnwrap(app.workspace.current).id, to: "Research")
        // A tmux space takes its new name when Dispatch reconciles the server's window metadata;
        // detaching earlier would remember the old name.
        try await app.wait { app.workspace.current?.name == "Research" }
        let space = try XCTUnwrap(app.workspace.current)
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        app.workspace.detachSpace(space.id)
        try await app.wait { app.workspace.detached.count == 1 }
        let entry = try XCTUnwrap(app.workspace.detached.first)
        XCTAssertFalse(app.workspace.hosts.record(entry.host).name.localizedStandardContains(server.destination))
        let root = try XCTUnwrap(app.window.contentView)
        // The sidebar column alone; OCR through the shared retries (no language correction, enlarged pixels).
        let sidebar = CGRect(x: 0, y: 0, width: 264 / root.bounds.width, height: 1)
        var seen = ""
        func sidebarReads(_ text: String) async throws -> Bool {
            let snapshot = try await PresentationTestSupport.capture(app.window)
            seen = try snapshot.text(in: sidebar)
            return try snapshot.reads([text], in: sidebar)
        }
        let input = try await PresentationTestSupport.openSpaceSearch(app.controller, in: root)
        for mode in [SpaceOrder.flat, .tree] {
            app.controller.settings.values.spaceOrder = mode
            app.window.makeFirstResponder(input)
            input.stringValue = "no-such-detached-space"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: input)
            try await TestSupport.eventually(diagnostic: "Sidebar OCR: \(seen)") { try await sidebarReads("No matching spaces") }
            input.stringValue = server.destination
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: input)
            try await TestSupport.eventually(diagnostic: "Sidebar OCR: \(seen)") {
                try await sidebarReads("Research") && !seen.contains("No matching spaces")
            }
        }
        XCTAssertEqual(app.workspace.detached.map(\.id), [entry.id])
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testNewLocalTmuxTabFollowsFocusedPaneDirectory() async throws {
        try await newTmuxTabDirectories(remote: false)
    }

    func testNewRemoteTmuxTabFollowsFocusedPaneDirectoryAcrossReconnect() async throws {
        try await newTmuxTabDirectories(remote: true, reconnect: true)
    }

    /// One tmux session covers every directory case in sequence: literal tmux format
    /// and shell characters, Unicode with a backslash, a focused split pane, and
    /// (remote only) that split pane again after a reconnect. Every created tab must
    /// start in the directory of the pane focused when it was created, and no
    /// existing pane process may be replaced along the way.
    private func newTmuxTabDirectories(remote: Bool, reconnect: Bool = false) async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        if remote {
            _ = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        }
        try await app.attach(); try await app.ready()
        let firstTab = try XCTUnwrap(app.workspace.activeTab)
        let first = try XCTUnwrap(app.target(firstTab).flatMap { Int($0.dropFirst()) })
        var expectedPanes = 1

        func directory(named name: String) throws -> String {
            // tmux reports the physical macOS path; URL resolution can retain /tmp.
            let url = URL(fileURLWithPath: "/private/tmp")
                .appendingPathComponent(server.root.lastPathComponent)
                .appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }

        func currentPath(of pane: Int) throws -> String {
            try app.server(["display-message", "-p", "-t", "%\(pane)", "#{pane_current_path}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func changeDirectory(of pane: Int, to name: String) async throws -> String {
            let path = try directory(named: name)
            // The fixture's /bin/sh can start in the C locale and discard Unicode
            // typed through readline. Construct the exact UTF-8 path after parsing.
            let octalPath = path.utf8.map { String(format: "\\%03o", $0) }.joined()
            _ = try app.server(["send-keys", "-t", "%\(pane)", "cd -- \"$(printf '" + octalPath + "')\"", "Enter"])
            try await TestSupport.eventually(diagnostic: "Expected cwd \(path); pane: \((try? app.server(["capture-pane", "-p", "-t", "%\(pane)"])) ?? "unavailable"); cwd: \((try? currentPath(of: pane)) ?? "unavailable")") {
                try currentPath(of: pane) == path
            }
            return path
        }

        func createTab(from pane: Int, expecting path: String) async throws {
            XCTAssertEqual(app.workspace.activeTab.flatMap(app.target), "%\(pane)")
            let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
            app.workspace.newTab()
            try await app.wait { app.workspace.activeTab?.isConnecting == false }
            let created = try XCTUnwrap(app.workspace.activeTab.flatMap(app.target).flatMap { Int($0.dropFirst()) })
            XCTAssertNotEqual(created, pane)
            XCTAssertEqual(try currentPath(of: created), path)
            XCTAssertTrue(Set(processes.split(separator: "\n")).isSubset(of:
                Set(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]).split(separator: "\n"))))
            expectedPanes += 1
            XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}"]).split(separator: "\n").count, expectedPanes)
        }

        // Literal format/shell characters, then Unicode and a backslash, from the first pane.
        var firstPath = try currentPath(of: first)
        for name in ["project #{pane_id} ## $ ' quoted", "café 日本語 \\notes #{pane_id}"] {
            app.workspace.selectSurface(firstTab.id)
            firstPath = try await changeDirectory(of: first, to: name)
            try await createTab(from: first, expecting: firstPath)
        }

        // A focused split pane supplies the directory; the first pane keeps its own.
        let pane = try app.server(["split-window", "-d", "-h", "-t", "%\(first)", "-P", "-F", "#{pane_id}", "/bin/sh"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let split = try XCTUnwrap(Int(pane.dropFirst()))
        expectedPanes += 1
        try await app.wait { app.workspace.current?.tabs.contains { app.target($0) == "%\(split)" } == true }
        let splitTab = try XCTUnwrap(app.workspace.current?.tabs.first { app.target($0) == "%\(split)" })
        app.workspace.selectSurface(splitTab.id)
        let splitPath = try await changeDirectory(of: split, to: "split pane")
        try await createTab(from: split, expecting: splitPath)
        XCTAssertEqual(try currentPath(of: first), firstPath)

        if reconnect {
            app.workspace.selectSurface(splitTab.id)
            let host = try XCTUnwrap(app.workspace.hosts.terminals[splitTab.id]).host
            app.runtime.hosts.disconnect(host)
            try await app.wait { app.runtime.hosts.reconnect.state(for: splitTab.id) != nil }
            app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: splitTab.id)
            try await TestSupport.eventually(timeout: .seconds(30)) {
                app.runtime.hosts.reconnect.state(for: splitTab.id) == nil
            }
            XCTAssertEqual(app.workspace.activeTab.flatMap(app.target), "%\(split)")
            try await createTab(from: split, expecting: splitPath)
        }
    }

    /// SSH recovery keeps a remote multiplexer's tabs: the same tab ids come back under the new link and
    /// no server pane is retired (helper route of the parked SSHConnectionLifetimeTests
    /// .testNativeSurfaceTransferPreservesRelayAndRetiresOnlyOwnedChannels).
    func testRecoveryKeepsRemoteTmuxTabsAndServerPanes() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try app.server(["new-window", "-d", "/bin/sh"])
        _ = try await connect(app, server: server, surface: XCTUnwrap(app.workspace.activeSurfaceID))
        try await app.attach(); try await app.ready()
        let space = try XCTUnwrap(app.workspace.current)
        let tabs = Set(space.tabs.map(\.id)), tab = try XCTUnwrap(space.tabs.first?.id)
        let panes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        let host = try XCTUnwrap(app.workspace.hosts.terminals[tab]?.host)
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: tab) != nil }
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: tab)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: "spaces: \(app.workspace.spaces.map { ($0.structured, $0.tabs.map(\.id)) })") {
            app.runtime.hosts.reconnect.state(for: tab) == nil && app.workspace.spaces.contains { $0.id == space.id && Set($0.tabs.map(\.id)) == tabs }
        }
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), panes, "Recovery retires no server pane")
    }

    func testDisconnectDuringReplacementShellStartupCanRetry() async throws {
        try await replacementShellStartup(interruption: .disconnect)
    }

    func testPermissionRevocationDuringReplacementShellStartupCanRetry() async throws {
        try await replacementShellStartup(interruption: .permissions)
    }

    private enum StartupInterruption { case disconnect, permissions }

    private func replacementShellStartup(interruption: StartupInterruption) async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        let surface = try XCTUnwrap(app.workspace.activeSurfaceID)
        let initial = try await connect(app, server: server, surface: surface)
        let launcher = try XCTUnwrap(initial.launch.origin)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[surface]).host
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: surface) != nil }
        let disconnectedAt = app.runtime.hosts.reconnect.state(for: surface)?.disconnectedAt
        XCTAssertEqual(kill(launcher.pid, SIGSTOP), 0)
        defer { if launcher.alive { kill(launcher.pid, SIGCONT) } }
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: surface)
        try await TestSupport.eventually(timeout: .seconds(30)) {
            app.workspace.hosts.terminals[surface]?.generation != initial.launch.connectionID.rawValue
        }
        let replacement = try XCTUnwrap(app.workspace.hosts.terminals[surface]).generation
        XCTAssertEqual(app.runtime.hosts.reconnect.state(for: surface)?.reconnecting, true)
        XCTAssertEqual(app.runtime.hosts.reconnect.state(for: surface)?.attempts, 1)
        XCTAssertEqual(app.runtime.hosts.reconnect.state(for: surface)?.disconnectedAt, disconnectedAt)
        XCTAssertNil(app.runtime.ssh.links[SSHConnectionID(replacement)]?.shellPID)
        if interruption == .permissions { app.runtime.ssh.permissions.save(.init(profile: .ordinary), for: initial.scope) }
        if interruption != .disconnect {
            try await TestSupport.eventually(timeout: .seconds(20)) {
                app.runtime.hosts.reconnect.state(for: surface)?.error?.contains("shell did not start") == true
            }
        } else { app.runtime.hosts.disconnect(host) }
        try await app.wait { app.runtime.hosts.reconnect.state(for: surface)?.reconnecting == false }
        XCTAssertEqual(app.runtime.hosts.reconnect.state(for: surface)?.attempts, 1)
        XCTAssertEqual(app.runtime.hosts.reconnect.state(for: surface)?.disconnectedAt, disconnectedAt)
        XCTAssertTrue(app.runtime.hosts.reconnect.contains(replacement))
        if interruption == .permissions { app.runtime.ssh.permissions.save(initial.grant, for: initial.scope) }
        // SIGSTOP lets the outer zsh reclaim the PTY. Foreground the test job
        // through the terminal directly; normal app input is correctly blocked here.
        let native = try XCTUnwrap(app.runtime.views[surface]?.surface)
        native.text("fg")
        var enter = TerminalKey(action: .press, keycode: 36, mods: [])
        _ = native.key(enter)
        enter.action = .release
        _ = native.key(enter)
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: surface)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: "Retry after startup cancellation: \(app.runtime.hosts.reconnect.state(for: surface)?.error ?? "pending"); screen=\(app.runtime.views[surface].map { TerminalTestSupport.screen(terminal: $0) } ?? "missing"); launcherAlive=\(launcher.alive)") {
            app.runtime.hosts.reconnect.state(for: surface) == nil
        }
        let receipt = server.root.appendingPathComponent("startup-cancel-retry")
        let recovered = try XCTUnwrap(app.runtime.views[surface])
        TerminalTestSupport.send("printf ready > " + HerdrLaunch.quote(receipt.path), to: recovered)
        try await TestSupport.eventually(diagnostic:
            "Input after startup retry: parked=\(recovered.inputParked) foreground=\(recovered.foregroundPID) currentView=\(app.runtime.views[surface] === recovered) reconnect=\(String(describing: app.runtime.hosts.reconnect.state(for: surface))) shells=\(app.runtime.ssh.links.values.map { "\($0.launch.tabID):\(String(describing: $0.shellPID))" })\n\(TerminalTestSupport.screen(terminal: recovered))") {
            (try? String(contentsOf: receipt, encoding: .utf8)) == "ready"
        }
    }

    func testInputImmediatelyAfterShellRecoveryReachesRemoteShell() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        let surface = try XCTUnwrap(app.workspace.activeSurfaceID)
        _ = try await connect(app, server: server, surface: surface)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[surface]).host
        let terminal = try XCTUnwrap(app.runtime.views[surface])
        for attempt in 0..<5 {
            app.runtime.hosts.disconnect(host)
            try await app.wait { app.runtime.hosts.reconnect.state(for: surface) != nil }
            app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: surface)
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while app.runtime.hosts.reconnect.state(for: surface) != nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertNil(app.runtime.hosts.reconnect.state(for: surface))
            let receipt = server.root.appendingPathComponent("immediate-recovery-\(attempt)")
            TerminalTestSupport.send("printf ready > " + HerdrLaunch.quote(receipt.path), to: terminal)
            try await TestSupport.eventually(timeout: .seconds(5), diagnostic: "Input after reconnect was lost on attempt \(attempt)") {
                (try? String(contentsOf: receipt, encoding: .utf8)) == "ready"
            }
        }
    }

    func testShellRecoveryPreservesSurfacesAndHealthyConnectionsAcrossSpaces() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        let first = try XCTUnwrap(app.workspace.activeSurfaceID)
        let a = try await connect(app, server: server, surface: first)
        app.workspace.newLocalSpace()
        let second = try XCTUnwrap(app.workspace.activeSurfaceID)
        let b = try await connect(app, server: server, surface: second)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[first]).host
        let surfaces = app.workspace.allSurfaceIDs, spaces = app.workspace.spaces.map(\.id)
        let selected = app.workspace.selectedSpace
        let view = try XCTUnwrap(app.runtime.views[first])
        TerminalTestSupport.send("printf 'HISTORY_%s\\n' BEFORE", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("HISTORY_BEFORE") }
        // Drop one private master. The same host still has a healthy login.
        _ = try await SSHCommand.run(executable: a.launch.master.executable, arguments: a.launch.master.controlArguments("exit"))
        try await app.wait { app.runtime.hosts.reconnect.state(for: first) != nil }
        XCTAssertNil(app.runtime.hosts.reconnect.state(for: second))
        XCTAssertNotNil(app.runtime.ssh.links[b.launch.connectionID])
        let recipe = try XCTUnwrap(app.runtime.hosts.reconnect.recipes[a.launch.connectionID])
        var wrongAccount = recipe
        wrongAccount.accountUID = (try XCTUnwrap(recipe.accountUID)) &+ 1
        app.runtime.hosts.reconnect.retain(wrongAccount)
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: first)
        try await TestSupport.eventually(timeout: .seconds(30)) { app.runtime.hosts.reconnect.state(for: first)?.error != nil }
        XCTAssertEqual(app.workspace.hosts.terminals[first]?.generation, a.launch.connectionID.rawValue, "An account mismatch must not transfer any retained surfaces")
        XCTAssertNotNil(app.runtime.ssh.links[b.launch.connectionID])
        app.runtime.hosts.reconnect.retain(recipe)
        for _ in 0..<5 { app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: first) }
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: "Shell retry: \(app.runtime.hosts.reconnect.state(for: first)?.error ?? "pending")") {
            app.runtime.link(of: first)?.launch.connectionID != a.launch.connectionID && app.runtime.ssh.links.values.contains { $0.launch.tabID == first && $0.shellPID != nil }
        }
        XCTAssertEqual(app.workspace.allSurfaceIDs, surfaces)
        XCTAssertEqual(app.workspace.spaces.map(\.id), spaces)
        XCTAssertEqual(app.workspace.selectedSpace, selected)
        XCTAssertTrue(app.runtime.views[first] === view)
        XCTAssertNotNil(app.runtime.ssh.links[b.launch.connectionID])
        XCTAssertTrue(TerminalTestSupport.screen(terminal: view).contains("HISTORY_BEFORE"))
        XCTAssertFalse(TerminalTestSupport.screen(terminal: view).contains("LOCAL_EXIT_255"))
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: first) != nil && app.runtime.hosts.reconnect.state(for: second) != nil }
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: second)
        try await TestSupport.eventually(timeout: .seconds(40)) {
            app.runtime.hosts.reconnect.state(for: first) == nil && app.runtime.hosts.reconnect.state(for: second) == nil
        }
        XCTAssertEqual(app.workspace.allSurfaceIDs, surfaces)
        XCTAssertEqual(app.workspace.selectedSpace, selected)
        for (index, surface) in [first, second].enumerated() {
            try await TestSupport.eventually(timeout: .seconds(15)) {
                app.runtime.ssh.links.values.contains { $0.launch.tabID == surface && $0.shellPID != nil }
            }
            let terminal = try XCTUnwrap(app.runtime.views[surface])
            TerminalTestSupport.send("printf 'RECONNECTED_\(index)_%s\\n' READY", to: terminal)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
                TerminalTestSupport.screen(terminal: terminal).contains("RECONNECTED_\(index)_READY")
            }
            XCTAssertFalse(TerminalTestSupport.screen(terminal: terminal).contains("SSH login origin could not be verified"))
        }
    }
    func testDisconnectedShellClosesWithoutConfirmationButOtherCommandsRemainProtected() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        _ = try await connect(app, server: server, surface: source)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[source]).host
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: source) != nil }
        XCTAssertFalse(app.controller.needsCloseConfirmation([source]))
        XCTAssertFalse(app.controller.needsCloseConfirmation([source], detaching: true))
        app.workspace.newLocalSpace()
        let local = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[local]?.surface != nil }
        let terminal = try XCTUnwrap(app.runtime.views[local])
        TerminalTestSupport.send("sleep 60", to: terminal)
        try await app.wait { app.controller.needsCloseConfirmation([local]) }
        XCTAssertTrue(app.controller.needsCloseConfirmation([source, local], detaching: true))
        app.controller.closeTab(source)
        XCTAssertFalse(app.workspace.allTabIDs.contains(source))
        XCTAssertTrue(app.workspace.allTabIDs.contains(local))
    }

    func testExitAndControlDReturnToAnEditableLocalShell() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        let surface = try XCTUnwrap(app.workspace.activeSurfaceID)
        for controlD in [false, true] {
            _ = try await connect(app, server: server, surface: surface)
            let terminal = try XCTUnwrap(app.runtime.views[surface])
            TerminalTestSupport.send("printf 'REMOTE_READY_%s\\n' \(controlD ? "EOF" : "EXIT")", to: terminal)
            try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("REMOTE_READY_" + (controlD ? "EOF" : "EXIT")) }
            if controlD { TerminalTestSupport.key(2, "d", terminal, modifiers: .control) }
            else { TerminalTestSupport.send("exit", to: terminal) }
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "controlD=\(controlD) " + TerminalTestSupport.screen(terminal: terminal)) { app.workspace.hosts.terminals[surface] == nil }
            XCTAssertNil(app.runtime.hosts.reconnect.state(for: surface))
            XCTAssertTrue(app.runtime.views[surface] === terminal)
            let marker = controlD ? "LOCAL_AFTER_EOF" : "LOCAL_AFTER_EXIT"
            TerminalTestSupport.send("printf '\(marker)_%s\\n' OK", to: terminal)
            try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains(marker + "_OK") }
        }
    }

    func testAuthenticatedExit255ReturnsToLocalShellWithoutReconnect() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        let surface = try XCTUnwrap(app.workspace.activeSurfaceID)
        _ = try await connect(app, server: server, surface: surface)
        let terminal = try XCTUnwrap(app.runtime.views[surface])
        TerminalTestSupport.send("exit 255", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("LOCAL_EXIT_255") && app.workspace.hosts.terminals[surface] == nil
        }
        XCTAssertNil(app.runtime.hosts.reconnect.state(for: surface))
    }
    func testRepeatedDetachFreshSSHAttachAndReconnectKeepDetachedAndVisibleDisjoint() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        for cycle in 0..<3 {
            if cycle > 0 { app.workspace.newLocalSpace() }
            let origin = try XCTUnwrap(app.workspace.activeSurfaceID)
            _ = try await connect(app, server: server, surface: origin)
            let terminal = try XCTUnwrap(app.runtime.views[origin])
            TerminalTestSupport.send("\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge", to: terminal)
            try await app.wait { app.workspace.current?.structured == true && app.workspace.current?.tabs.allSatisfy { !$0.isConnecting } == true }
            let tab = try XCTUnwrap(app.workspace.activeTab)
            let host = try XCTUnwrap(app.workspace.hosts.terminals[tab.id]).host
            XCTAssertTrue(app.workspace.detached.isEmpty, "Fresh attachment must retire the old detached entry (cycle \(cycle))")
            for _ in 0..<2 {
                app.runtime.hosts.disconnect(host)
                try await app.wait { app.runtime.hosts.reconnect.state(for: tab.id) != nil }
                app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: tab.id)
                try await TestSupport.eventually(timeout: .seconds(30)) { app.runtime.hosts.reconnect.state(for: tab.id) == nil }
                XCTAssertEqual(app.workspace.spaces.filter { $0.structured }.count, 1)
                XCTAssertTrue(app.workspace.detached.isEmpty)
            }
            app.workspace.detachSpace(try XCTUnwrap(app.workspace.current).id)
            try await app.wait { !app.workspace.spaces.contains(where: \.structured) }
            XCTAssertEqual(app.workspace.detached.count, 1)
            XCTAssertTrue(app.workspace.spaces.allSatisfy { !$0.shows("tmux") })
            XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
        }
    }

    func testOfflineTmuxPaneClosureAndMissingServerNeverRecreateCommands() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try app.server(["split-window", "-h", "-t", "edge"])
        let origin = try XCTUnwrap(app.workspace.activeSurfaceID)
        _ = try await connect(app, server: server, surface: origin)
        let terminal = try XCTUnwrap(app.runtime.views[origin])
        TerminalTestSupport.send("\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge", to: terminal)
        try await app.wait { app.workspace.current?.structured == true && app.workspace.current?.tabs.count == 2 }
        try await app.wait { app.workspace.current?.tabs.allSatisfy { !$0.isConnecting } == true }
        let tabs = try XCTUnwrap(app.workspace.current).tabs
        let removed = tabs[0], retained = tabs[1]
        let retainedPane = try XCTUnwrap(app.target(retained))
        let host = try XCTUnwrap(app.workspace.hosts.terminals[retained.id]).host
        let serverPanes = try app.server(["list-panes", "-a", "-F", "#{pane_id}"])
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: retained.id) != nil }
        app.workspace.closeTab(removed.id, policy: .terminate)
        XCTAssertFalse(app.workspace.allSurfaceIDs.contains(removed.id))
        XCTAssertNil(app.runtime.views[removed.id])
        let view = try XCTUnwrap(app.runtime.views[retained.id])
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: retained.id)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: app.runtime.hosts.reconnect.state(for: retained.id)?.error ?? "Reconnect pending") {
            app.runtime.hosts.reconnect.state(for: retained.id) == nil
        }
        XCTAssertFalse(app.workspace.allSurfaceIDs.contains(removed.id))
        XCTAssertTrue(app.runtime.views[retained.id] === view)
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}"]), serverPanes, "Offline closure must not replay a kill-pane command")
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: retained.id) != nil }
        _ = try app.server(["kill-pane", "-t", retainedPane])
        for _ in 0..<2 {
            app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: retained.id)
            try await TestSupport.eventually(timeout: .seconds(30)) {
                let state = app.runtime.hosts.reconnect.state(for: retained.id)
                return state?.reconnecting == false && state?.error != nil
            }
            XCTAssertTrue(app.runtime.views[retained.id] === view)
            XCTAssertFalse(app.workspace.allSurfaceIDs.contains(removed.id))
        }
        _ = try app.server(["kill-server"])
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: retained.id)
        try await TestSupport.eventually(timeout: .seconds(30)) { app.runtime.hosts.reconnect.state(for: retained.id)?.error != nil }
        XCTAssertTrue(app.runtime.views[retained.id] === view)
        XCTAssertEqual(app.workspace.hosts.terminals[retained.id]?.state, .disconnected)
        XCTAssertFalse(app.workspace.allSurfaceIDs.contains(removed.id))
    }

    func testBrokerOnlyFailureRetiresOldMasterBeforeResumingLauncher() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        let surface = try XCTUnwrap(app.workspace.activeSurfaceID)
        let old = try await connect(app, server: server, surface: surface)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[surface]).host
        try await SSHChatTestSupport.dropHelper(app.runtime.ssh, old.launch.connectionID, reason: "Broker test: helper channel closed")
        try await app.wait { app.runtime.hosts.reconnect.state(for: surface) != nil }
        let master = try await SSHCommand.run(executable: old.launch.master.executable, arguments: old.launch.master.controlArguments("check"))
        XCTAssertEqual(master.status, 0, "Only the broker has disconnected")
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: surface)
        try await TestSupport.eventually(timeout: .seconds(30)) {
            app.runtime.ssh.links.values.contains { $0.launch.connectionID != old.launch.connectionID && $0.shellPID != nil }
        }
        let terminal = try XCTUnwrap(app.runtime.views[surface])
        try await app.wait { app.runtime.hosts.reconnect.state(for: surface) == nil && !terminal.inputParked }
        TerminalTestSupport.send("printf 'RECOVERED_%s\\n' BROKER", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("RECOVERED_BROKER") }
        XCTAssertNil(app.runtime.hosts.reconnect.state(for: surface))
    }

    private func connect(_ app: TmuxWalkthrough, server: SSHTestServer, surface: UUID) async throws -> SSHCoordinator.Link {
        try await app.login(server, surface: surface)
    }
}
