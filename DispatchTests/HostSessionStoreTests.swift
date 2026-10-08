import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class HostSessionStoreTests: XCTestCase {
    func testResetOneHostClearsSavedTabsAndRecipesAndKeepsOtherHosts() throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(url: root.appendingPathComponent("host-session.json"))
        let controller = AppDelegate(settings: SettingsStore(file: root.appendingPathComponent("settings.json")), hostSessionStore: store)
        let workspace = controller.workspace; runtime.workspace = workspace
        workspace.onCloseTabs = { runtime.close($0) }
        defer { runtime.hosts.stop(); runtime.workspace = previous; try? FileManager.default.removeItem(at: root) }
        workspace.newLocalSpace()
        let local = try XCTUnwrap(workspace.current)
        let host = HostID.authenticated("reset-one"), other = HostID.authenticated("keep-other")
        for id in [host, host, other] {
            let tab = TerminalTab(directory: "/tmp")
            var space = Space(name: id.rawValue, tab: tab); space.hostID = id
            workspace.spaces.append(space)
            runtime.hosts.restore(.init(connection: SSHConnectionID(), host: id, shell: .init(destination: id.rawValue),
                scope: nil, origin: tab.id, surfaces: [tab.id], restored: true))
        }
        workspace.selectedSpace = local.id
        controller.persistHostSession()
        XCTAssertFalse(runtime.hosts.canReset(.local))
        runtime.hosts.reset(.local)
        XCTAssertEqual(workspace.spaces.count, 4)
        runtime.hosts.reset(host)
        XCTAssertEqual(workspace.spaces.map(\.hostID), [.local, other])
        XCTAssertEqual(workspace.selectedSpace, local.id)
        XCTAssertEqual(workspace.spaces.first, local)
        XCTAssertNil(workspace.hosts.records[host])
        XCTAssertTrue(runtime.hosts.reconnect.recipes.values.allSatisfy { $0.host == other })
        let snapshot = try JSONDecoder().decode(HostSessionStore.Snapshot.self, from: Data(contentsOf: store.url))
        XCTAssertEqual(snapshot.connections.map(\.host), [other])
        XCTAssertEqual(snapshot.spaces.map(\.hostID), [.local, other], "Resetting a host keeps the local space")
        runtime.hosts.reset(host)
        XCTAssertEqual(workspace.spaces.map(\.hostID), [.local, other])
    }

    func testResetReleasesConnectingLauncherBeforeHelperOwnership() async throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let control = root.appendingPathComponent("control")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        let workspace = Workspace(); runtime.workspace = workspace; workspace.newLocalSpace()
        defer { runtime.hosts.stop(); runtime.workspace = previous; try? FileManager.default.removeItem(at: root) }
        let request = SSHLaunchRequest(tabID: try XCTUnwrap(workspace.activeSurfaceID), token: "fixture", connectionID: .init(),
            credential: "reset-credential", master: .init(executable: "/usr/bin/true", controlPath: control.appendingPathComponent("master").path,
                destination: "fixture"), shell: .init(destination: "fixture"))
        runtime.hosts.connecting(request)
        XCTAssertTrue(runtime.ssh.links.isEmpty)
        XCTAssertTrue(runtime.hasActiveSSHConnections, "Connecting SSH needs confirmation even before a host row is visible")
        try await runtime.resetSSHState()
        let reply = root.appendingPathComponent(request.connectionID.rawValue.uuidString + ".sshresume")
        let decision = try JSONDecoder().decode(SSHResumeDecision.self, from: Data(contentsOf: reply))
        XCTAssertEqual(decision.credential, request.credential)
        XCTAssertEqual(decision.exitStatus, 130)
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.path))
        XCTAssertFalse(runtime.hasActiveSSHConnections)
    }

    func testResetClearsOfflineHostsAndSavedSessionWhileKeepingLocalStateAndPreferences() async throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(url: root.appendingPathComponent("host-session.json"))
        let settings = SettingsStore(file: root.appendingPathComponent("settings.json"))
        let controller = AppDelegate(settings: settings, hostSessionStore: store)
        let workspace = controller.workspace
        runtime.workspace = workspace
        defer { runtime.hosts.stop(); runtime.workspace = previous; try? FileManager.default.removeItem(at: root) }
        workspace.newLocalSpace()
        let local = try XCTUnwrap(workspace.current)
        settings.values.fontSize = 19
        let preferences = settings.values, runtimePreferences = runtime.preferences
        let connection = SSHConnectionID(), host = HostID.authenticated("reset-fixture")
        let tab = TerminalTab(directory: "/remote/project")
        var space = Space(name: "Offline", tab: tab); space.hostID = host
        workspace.spaces.append(space)
        runtime.hosts.restore(.init(connection: connection, host: host, shell: .init(destination: "fixture"),
            scope: nil, origin: tab.id, surfaces: [tab.id]))
        try store.save(runtime: runtime)
        XCTAssertFalse(runtime.hasActiveSSHConnections)
        try await controller.resetSSHState()
        XCTAssertEqual(workspace.spaces, [local])
        XCTAssertEqual(Set(workspace.hosts.records.keys), [.local])
        XCTAssertTrue(workspace.hosts.terminals.isEmpty)
        XCTAssertTrue(runtime.hosts.reconnect.recipes.isEmpty)
        XCTAssertTrue(runtime.hosts.reconnect.states.isEmpty)
        XCTAssertEqual(settings.values, preferences)
        XCTAssertEqual(runtime.preferences, runtimePreferences)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        // No visible hosts is still a valid reset, including a stale disk snapshot.
        try store.save(runtime: runtime)
        try await controller.resetSSHState()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertEqual(workspace.spaces, [local])
    }

    func testRoundTripRestoresOfflineTabsWithoutStartingConnectionsAndOverwritesOneFile() async throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(url: root.appendingPathComponent("host-session.json"))
        defer {
            runtime.hosts.stop(); runtime.workspace = previous
            try? FileManager.default.removeItem(at: root)
        }
        let workspace = Workspace(); runtime.workspace = workspace
        workspace.newLocalSpace()
        let local = try XCTUnwrap(workspace.current)
        let localTab = try XCTUnwrap(local.activeTab)
        workspace.updateTab(localTab.id, title: "zsh", directory: "/tmp/local-project", customTitle: "Local work")
        let localSpaceIndex = try XCTUnwrap(workspace.spaces.firstIndex { $0.id == local.id })
        workspace.spaces[localSpaceIndex].panes[0].tabs[0].launchCommand = "LOCAL_MUST_NOT_REPLAY"
        // A local multiplexer's pane: a helper terminal of a structured space.
        let localSplit = TerminalTab(directory: "/tmp/local-other")
        var multiplexed = Space(name: "tmux", directory: "/tmp")
        multiplexed.structure([localSplit], selected: 0)
        workspace.spaces.append(multiplexed)
        var expected: [Space] = []
        for number in 1...2 {
            let connection = SSHConnectionID(), host = HostID.authenticated("host-\(number)")
            let shell = SSHShell(destination: "user@host-\(number)", options: ["-p", "2222"])
            var first = TerminalTab(directory: "/remote/project")
            first.title = "editor"; first.customTitle = "Work \(number)"; first.launchCommand = "MUST_NOT_REPLAY"
            var space = Space(name: "Project \(number)", tab: first); space.hostID = host
            let second = TerminalTab(directory: "/remote/other")
            space.panes[0].tabs.append(second); space.panes[0].selected = second.id
            workspace.spaces.append(space); expected.append(space)
            for tab in space.tabs {
                workspace.hosts.associate(tab.id, context: .init(host: host, generation: connection.rawValue, state: .connected, authenticated: true))
            }
            runtime.hosts.reconnect.retain(.init(connection: connection, host: host, shell: shell, scope: nil,
                origin: first.id, surfaces: Set(space.tabs.map(\.id))))
        }
        workspace.selectedSpace = expected[1].id
        // A tab not shown since its own restore carries its text into the next snapshot.
        runtime.restoredHistory = [localTab.id: "$ make\nok \u{1B}]52;c;x\u{7}\u{9B}2Jdone é\u{A0}\n$ ", expected[0].tabs[0].id: "remote"]
        defer { runtime.restoredHistory = [:] }
        try store.save(runtime: runtime, history: true)
        runtime.restoredHistory = [:]
        let contents = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(contents.contains("make"), "Output is kept apart from the session")
        for url in [store.url, store.terminalHistory.url] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        }
        XCTAssertEqual(try store.terminalHistory.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertFalse(contents.contains("MUST_NOT_REPLAY"))
        XCTAssertTrue(contents.contains(local.id.uuidString), "Plain local spaces are remembered too")
        XCTAssertFalse(contents.contains(localSplit.id.uuidString), "Local tmux panes are not restored as shells")
        runtime.hosts.stop()
        let restored = Workspace(); runtime.workspace = restored
        var attempts = 0
        runtime.hosts.reconnect.attempt = { _ in attempts += 1 }
        defer { runtime.hosts.reconnect.attempt = nil }
        XCTAssertTrue(store.restore(runtime: runtime))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(restored.spaces.map(\.id), [local.id] + expected.map(\.id))
        XCTAssertEqual(restored.spaces.dropFirst().map(\.name), expected.map(\.name))
        XCTAssertEqual(restored.spaces.dropFirst().flatMap(\.tabs).map(\.label), expected.flatMap(\.tabs).map(\.label))
        let restoredLocal = try XCTUnwrap(restored.spaces.first?.tabs)
        XCTAssertEqual(restoredLocal.map(\.id), [localTab.id])
        XCTAssertEqual(restoredLocal.first?.label, "Local work")
        XCTAssertEqual(restoredLocal.first?.directory, "/tmp/local-project")
        XCTAssertEqual(restoredLocal.first?.machine, .local)
        XCTAssertNil(restoredLocal.first?.launchCommand)
        XCTAssertNil(restored.hosts.terminals[localTab.id], "Local shells carry no host context")
        let history = store.terminalHistory.take()
        XCTAssertEqual(Set(history.keys), [localTab.id, expected[0].tabs[0].id], "Plain local and SSH tabs keep their output")
        XCTAssertEqual(history[expected[0].tabs[0].id], "remote")
        XCTAssertTrue(store.terminalHistory.take().isEmpty, "Saved output is read once")
        let replay = String(decoding: TerminalHistoryStore.replay(try XCTUnwrap(history[localTab.id])), as: UTF8.self)
        XCTAssertEqual(replay, "\u{1B}[0;2m$ make\r\nok ]52;c;x2Jdone é\u{A0}\r\n$ \r\n\u{1B}[0m", "Faint text only; saved control characters never reach the terminal")
        XCTAssertEqual(restored.selectedSpace, expected[1].id)
        XCTAssertEqual(restored.activeTab?.id, expected[1].activeTab?.id)
        for surface in restored.allSurfaceIDs where surface != localTab.id {
            XCTAssertEqual(restored.hosts.terminals[surface]?.state, .disconnected)
            XCTAssertNotNil(runtime.hosts.reconnect.state(for: surface))
            XCTAssertTrue(runtime.hosts.reconnect.awaitingRestore(surface))
        }
        // A second quit while still offline must keep the same tabs/recipes.
        try store.save(runtime: runtime)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["host-session.json"])
        runtime.hosts.stop()
        let secondRestore = Workspace(); runtime.workspace = secondRestore
        defer { _ = secondRestore.spaces }
        XCTAssertTrue(store.restore(runtime: runtime))
        XCTAssertEqual(secondRestore.allSurfaceIDs, restored.allSurfaceIDs)
        // Closing all remembered tabs replaces the snapshot, preventing resurrection.
        runtime.workspace?.spaces = []
        try store.save(runtime: runtime)
        runtime.hosts.stop()
        let emptyRestore = Workspace(); runtime.workspace = emptyRestore
        defer { _ = emptyRestore.spaces }
        XCTAssertFalse(store.restore(runtime: runtime))
        XCTAssertTrue(emptyRestore.spaces.isEmpty)
        try FileManager.default.removeItem(at: store.url)
        XCTAssertFalse(store.restore(runtime: runtime))
    }

    func testRemoteBackendPresentationSurvivesSessionSaveAndRestore() throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(url: root.appendingPathComponent("host-session.json"))
        let workspace = Workspace(); runtime.workspace = workspace
        defer { runtime.hosts.stop(); runtime.workspace = previous; try? FileManager.default.removeItem(at: root) }
        let host = HostID.authenticated("retained-server"), connection = SSHConnectionID()
        let origin = TerminalTab(directory: "/remote")
        var login = Space(name: "Login", tab: origin); login.hostID = host
        var backend = Space(name: "Server", directory: "/remote/project")
        backend.structure([TerminalTab(directory: "/remote/project")], selected: 0, backend: 2)
        backend.remote = connection; backend.hostID = host
        workspace.spaces = [login, backend]; workspace.selectedSpace = backend.id
        let surfaces = Set(workspace.allSurfaceIDs)
        for surface in surfaces {
            workspace.hosts.associate(surface, context: .init(host: host, generation: connection.rawValue, state: .connected, authenticated: true))
        }
        let retained = HelperWorkspace.Detached(route: .init(mux: 2, key: "server"), presentation: [backend],
                                               nodes: ["server/terminal": backend.tabs[0].id])
        runtime.hosts.reconnect.retain(.init(connection: connection, host: host, shell: .init(destination: "fixture"),
            scope: nil, origin: origin.id, surfaces: surfaces, backends: [retained]))
        try store.save(runtime: runtime)
        runtime.hosts.stop(); workspace.spaces = []
        XCTAssertTrue(store.restore(runtime: runtime))
        XCTAssertEqual(workspace.spaces.last, backend)
        XCTAssertEqual(runtime.hosts.reconnect.recipes[connection]?.backends, [retained])
        XCTAssertEqual(workspace.selectedSpace, backend.id)
        XCTAssertTrue(backend.tabs.allSatisfy { runtime.hosts.reconnect.awaitingRestore($0.id) })
        try store.save(runtime: runtime)
        let snapshot = try JSONDecoder().decode(HostSessionStore.Snapshot.self, from: Data(contentsOf: store.url))
        XCTAssertEqual(snapshot.spaces.last, backend)
        XCTAssertEqual(snapshot.connections.first?.backends, [retained])
    }

    func testRestoredBackendInheritsAuthenticatedEndpointWithoutAFrontend() {
        let workspace = Workspace(), host = HostID.authenticated("restored")
        let connections = [SSHConnectionID(), SSHConnectionID()]
        var expected: [UUID: TerminalHostContext] = [:]
        var helpers: [HelperWorkspace] = []
        defer { helpers.forEach { $0.stop() } }
        for connection in connections {
            var space = Space(name: "Restored", directory: "/remote")
            space.structure([TerminalTab(directory: "/remote"), TerminalTab(directory: "/inner")], selected: 0, backend: 2)
            space.remote = connection; space.hostID = host
            workspace.spaces.append(space)
            let nested = TerminalHostContext(host: .authenticated("inner"), generation: UUID(), state: .connected, authenticated: true)
            workspace.hosts.associate(space.tabs[1].id, context: nested)
            expected[space.tabs[1].id] = nested
            expected[space.tabs[0].id] = .init(host: host, generation: connection.rawValue, state: .connected, authenticated: true)
            helpers.append(HelperWorkspace(workspace: workspace, renderer: nil, endpoint: .remote(connection), host: host))
        }
        var local = Space(name: "Local", directory: "/local")
        local.structure([TerminalTab(directory: "/local")], selected: 0, backend: 2)
        workspace.spaces.append(local)
        helpers.append(HelperWorkspace(workspace: workspace, renderer: nil))
        for _ in 0..<2 { helpers.forEach { $0.inherit(2) } }
        XCTAssertEqual(workspace.hosts.terminals, expected)
    }

    func testNativeReferencesAndLayoutsSurviveDiskRoundTrip() throws {
        // Multiplexer sessions as the helper presents them: backends, nodes, containers, presentation.
        var herdr = Space(name: "herdr", directory: "/remote/project")
        herdr.structure([TerminalTab(directory: "/remote/project")], selected: 0, backend: 2)
        herdr.remote = SSHConnectionID()
        var tmux = Space(name: "tmux", directory: "/remote/tmux")
        tmux.structure([TerminalTab(directory: "/remote/tmux"), TerminalTab(directory: "/remote/other")], selected: 1, name: "Window")
        tmux.presentation = TabPresentation(windows: tmux.containers.map(\.id), selected: tmux.containers[1].id, preset: .columns)
        let spaces = [herdr, tmux]
        let restored = try JSONDecoder().decode([Space].self, from: JSONEncoder().encode(spaces))
        XCTAssertEqual(restored, spaces)
        XCTAssertEqual(restored[0].tabs[0].terminal, 1)
        XCTAssertEqual(restored[1].containers.map(\.node), [1, 2])
        XCTAssertEqual(restored[1].activeWindow?.name, "Window")
    }

    func testQuitSavesBeforeRuntimeCleanupAndDoesNotOverwriteOnTerminationNotification() async throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(url: root.appendingPathComponent("host-session.json"))
        let settings = SettingsStore(file: root.appendingPathComponent("settings.json"))
        settings.values.restoreTerminalOutput = true
        let controller = AppDelegate(settings: settings, hostSessionStore: store)
        runtime.workspace = controller.workspace
        defer { runtime.workspace = previous; runtime.restoredHistory = [:]; try? FileManager.default.removeItem(at: root) }
        controller.workspace.newLocalSpace()
        let local = try XCTUnwrap(controller.workspace.activeSurfaceID)
        runtime.restoredHistory = [local: "$ make"]
        controller.workspace.newLocalSpace()
        let surface = try XCTUnwrap(controller.workspace.activeSurfaceID)
        let connection = SSHConnectionID(), host = HostID.authenticated("quit-fixture")
        controller.workspace.hosts.associate(surface, context: .init(host: host, generation: connection.rawValue, state: .connected, authenticated: true))
        runtime.hosts.reconnect.retain(.init(connection: connection, host: host, shell: .init(destination: "fixture"),
                                           scope: nil, origin: surface, surfaces: [surface]))
        controller.persistHostSession()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.terminalHistory.url.path), "Output is never saved mid-session")
        var finished = false
        XCTAssertEqual(controller.requestTermination { finished = $0 }, .terminateLater)
        try await TestSupport.eventually { finished }
        XCTAssertEqual(store.terminalHistory.take(), [local: "$ make"])
        let saved = try Data(contentsOf: store.url)
        let snapshot = try JSONDecoder().decode(HostSessionStore.Snapshot.self, from: saved)
        XCTAssertEqual(snapshot.connections.count, 1)
        XCTAssertEqual(snapshot.spaces.flatMap(\.tabs).map(\.id), [local, surface])
        XCTAssertTrue(controller.workspace.hosts.terminals.isEmpty)
        controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(try Data(contentsOf: store.url), saved)
    }

    func testFailedRestoredShellKeepsTabAndReconnectControl() throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let workspace = Workspace(); runtime.workspace = workspace
        workspace.newLocalSpace()
        let tab = try XCTUnwrap(workspace.activeTab)
        defer { runtime.close([tab.id]); runtime.hosts.stop(); runtime.workspace = previous; runtime.restoredHistory = [:] }
        let recipe = SSHReconnectController.Recipe(connection: SSHConnectionID(), host: .authenticated("fixture"),
            shell: .init(destination: "unavailable"), scope: nil, origin: tab.id, surfaces: [tab.id], restored: true)
        runtime.hosts.restore(recipe)
        runtime.restoredHistory[tab.id] = "$ make"
        // Before it reconnects, the tab shows its saved output with nothing running.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.contentView = nil; window.close() }
        window.isReleasedWhenClosed = false
        runtime.start(preferences: Preferences())
        defer { runtime.stop() }
        window.contentView = runtime.view(for: tab)
        let preview = try XCTUnwrap(runtime.views[tab.id]?.surface)
        XCTAssertTrue(preview.readHistory().hasPrefix("$ make"))
        XCTAssertEqual(preview.foregroundPID, 0)
        XCTAssertEqual(runtime.restoredHistory[tab.id], "$ make", "Kept for the next quit until the shell starts")
        runtime.hosts.reconnect.forget(recipe.connection)
        runtime.hosts.reconnect.launchingRestoredShell(tab.id, recipe: recipe)
        // The launching shell takes its saved output once.
        runtime.restoredHistory[tab.id] = nil
        let view = runtime.view(for: tab)
        view.didExit()
        XCTAssertTrue(workspace.allTabIDs.contains(tab.id))
        XCTAssertEqual(runtime.restoredHistory[tab.id], "$ make", "A retry shows the saved output again")
        XCTAssertEqual(workspace.hosts.state(recipe.host), .disconnected)
        XCTAssertTrue(runtime.hosts.reconnect.awaitingRestore(tab.id))
        XCTAssertNotNil(runtime.hosts.reconnect.state(for: tab.id)?.error)
        XCTAssertNil(runtime.views[tab.id])
        // Once authenticated, an intentional shell exit closes normally.
        runtime.hosts.reconnect.launchingRestoredShell(tab.id, recipe: recipe)
        runtime.hosts.reconnect.shellAuthenticated(tab.id)
        XCTAssertFalse(runtime.hosts.reconnect.restoredShellExited(tab.id))
    }

    func testRememberHostsDefaultsAndDisablingClearsSnapshotWithoutClosingTabs() async throws {
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).rememberHosts)
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).restoreTerminalOutput)
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(url: root.appendingPathComponent("host-session.json"))
        let settings = SettingsStore(file: root.appendingPathComponent("settings.json"))
        let controller = AppDelegate(settings: settings, hostSessionStore: store)
        runtime.workspace = controller.workspace
        defer { runtime.hosts.stop(); runtime.workspace = previous; try? FileManager.default.removeItem(at: root) }
        controller.workspace.newLocalSpace()
        let tab = try XCTUnwrap(controller.workspace.activeTab)
        let recipe = SSHReconnectController.Recipe(connection: SSHConnectionID(), host: .authenticated("fixture"),
            shell: .init(destination: "fixture"), scope: nil, origin: tab.id, surfaces: [tab.id], restored: true)
        runtime.hosts.restore(recipe)
        controller.persistHostSession()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        try store.terminalHistory.save([tab.id: "$ make"])
        var preferences = settings.values; preferences.restoreTerminalOutput = false
        try settings.save(preferences)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.terminalHistory.url.path), "Turning output off deletes it")
        preferences.rememberHosts = false
        try settings.save(preferences)
        XCTAssertFalse(SettingsStore(file: root.appendingPathComponent("settings.json")).values.rememberHosts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertTrue(controller.workspace.allTabIDs.contains(tab.id))
        XCTAssertNotNil(runtime.hosts.reconnect.state(for: tab.id))
        // A stale snapshot cannot override the disabled startup preference; saved output is
        // deleted at launch even when unused.
        try store.save(runtime: runtime)
        try store.terminalHistory.save([tab.id: "$ make"])
        XCTAssertFalse(controller.restoreHostSession())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.terminalHistory.url.path))
        preferences.rememberHosts = true
        try settings.save(preferences)
        controller.persistHostSession()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        preferences.rememberHosts = false
        try settings.save(preferences)
        var terminated = false
        _ = controller.requestTermination { terminated = $0 }
        try await TestSupport.eventually { terminated }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testForgetHostRemovesOnlyThatHostAndUpdatesSnapshotImmediately() throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(url: root.appendingPathComponent("host-session.json"))
        let controller = AppDelegate(settings: SettingsStore(file: root.appendingPathComponent("settings.json")), hostSessionStore: store)
        let workspace = controller.workspace; runtime.workspace = workspace
        workspace.onCloseTabs = { runtime.close($0) }
        defer { runtime.hosts.stop(); runtime.workspace = previous; try? FileManager.default.removeItem(at: root) }
        let host = HostID.authenticated("forget"), other = HostID.authenticated("keep")
        var tabs: [UUID] = []
        for id in [host, host, other] {
            let tab = TerminalTab(directory: "/tmp"); tabs.append(tab.id)
            var space = Space(name: id.rawValue, tab: tab); space.hostID = id
            workspace.spaces.append(space)
            runtime.hosts.restore(.init(connection: SSHConnectionID(), host: id, shell: .init(destination: id.rawValue),
                scope: nil, origin: tab.id, surfaces: [tab.id], restored: true))
        }
        // A host tab still sitting in a local space beside a local tab closes too; the local tab stays.
        let local = TerminalTab(directory: "/tmp"), stray = TerminalTab(directory: "/tmp")
        var mixed = Space(name: "local", tab: local); mixed.panes[0].tabs.append(stray)
        workspace.spaces.append(mixed)
        runtime.hosts.restore(.init(connection: SSHConnectionID(), host: host, shell: .init(destination: host.rawValue),
            scope: nil, origin: stray.id, surfaces: [stray.id], restored: true))
        workspace.selectedSpace = workspace.spaces[2].id
        let selected = workspace.selectedSpace
        controller.persistHostSession()
        XCTAssertTrue(runtime.hosts.canForget(host))
        XCTAssertFalse(runtime.hosts.canForget(.local))
        runtime.hosts.forget(host)
        XCTAssertEqual(workspace.allTabIDs, [tabs[2], local.id])
        XCTAssertEqual(workspace.selectedSpace, selected)
        XCTAssertFalse(workspace.liveHosts.contains { $0.id == host })
        XCTAssertNil(workspace.hosts.records[host])
        XCTAssertTrue(runtime.hosts.reconnect.recipes.values.allSatisfy { $0.host == other })
        let snapshot = try JSONDecoder().decode(HostSessionStore.Snapshot.self, from: Data(contentsOf: store.url))
        XCTAssertEqual(snapshot.connections.map(\.host), [other])
        XCTAssertEqual(snapshot.spaces.flatMap(\.tabs).map(\.id), [tabs[2], local.id])
        runtime.hosts.forget(host) // Repeating the action cannot affect another host.
        let generation = try XCTUnwrap(workspace.hosts.terminals[tabs[2]]?.generation)
        workspace.hosts.setState(.connected, generation: generation)
        XCTAssertFalse(runtime.hosts.canForget(other))
        runtime.hosts.forget(other)
        XCTAssertEqual(workspace.allTabIDs, [tabs[2], local.id])
    }

    func testMissingInvalidAndFutureSnapshotsAreIgnored() throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let workspace = Workspace(); runtime.workspace = workspace
        defer { _ = workspace.spaces }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(url: root.appendingPathComponent("host-session.json"))
        defer { runtime.workspace = previous; try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(store.restore(runtime: runtime))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: store.url)
        XCTAssertFalse(store.restore(runtime: runtime))
        let snapshot = HostSessionStore.Snapshot(version: 99, hosts: [], spaces: [], contexts: [:], connections: [])
        try JSONEncoder().encode(snapshot).write(to: store.url)
        XCTAssertFalse(store.restore(runtime: runtime))
        // Saved output older than a week, from another version, shorter than its header says, or
        // left half-written by a killed quit is never shown, and none of it stays on disk.
        let history = store.terminalHistory, tab = UUID()
        let leftover = root.appendingPathComponent(".terminal-history.json.tmp-killed")
        for header in [TerminalHistoryStore.Header(saved: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60), tabs: [.init(id: tab, bytes: 3)]),
                       TerminalHistoryStore.Header(version: 2, saved: Date(), tabs: [.init(id: tab, bytes: 3)]),
                       TerminalHistoryStore.Header(saved: Date(), tabs: [.init(id: tab, bytes: 4)])] {
            try Data("partial".utf8).write(to: leftover)
            try (JSONEncoder().encode(header) + Data("\nold".utf8)).write(to: history.url)
            XCTAssertEqual(history.take(), [:])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("terminal-history") }, [])
        }
        try history.save([tab: "recent", UUID(): ""])
        XCTAssertEqual(history.take(), [tab: "recent"])
    }
}
