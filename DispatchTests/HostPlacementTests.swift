import XCTest
@testable import DispatchApp

@MainActor
final class HostPlacementTests: XCTestCase {
    func testSynchronizationInheritsBackendHostsBeforeRegrouping() {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let workspace = Workspace()
        runtime.workspace = workspace
        let coordinator = HostCoordinator(runtime: runtime)
        defer {
            workspace.helpers.values.forEach { $0.stop() }
            coordinator.stop(); runtime.workspace = previous
        }
        var expected: [UUID: TerminalHostContext] = [:]
        for name in ["first", "second"] {
            let host = HostID.authenticated(name), connection = SSHConnectionID()
            var space = Space(name: name, directory: "/remote")
            space.structure([TerminalTab(directory: "/remote")], selected: 0, backend: 2)
            space.remote = connection
            workspace.spaces.append(space)
            workspace.helpers[.remote(connection)] = HelperWorkspace(
                workspace: workspace, renderer: nil, endpoint: .remote(connection), host: host)
            expected[space.tabs[0].id] = .init(host: host, generation: connection.rawValue,
                                             state: .connected, authenticated: true)
        }
        var local = Space(name: "Local", directory: "/local")
        local.structure([TerminalTab(directory: "/local")], selected: 0, backend: 2)
        workspace.spaces.append(local)
        workspace.helpers[.local] = HelperWorkspace(workspace: workspace, renderer: nil)
        let nested = TerminalHostContext(host: .authenticated("nested"), generation: UUID(),
                                         state: .connected, authenticated: true)
        let terminal = workspace.spaces[1].tabs[0].id
        workspace.hosts.associate(terminal, context: nested)
        expected[terminal] = nested
        for _ in 0..<2 { coordinator.synchronize() }
        XCTAssertEqual(workspace.hosts.terminals, expected)
        XCTAssertEqual(workspace.spaces.map(\.hostID), [.authenticated("first"), nested.host, .local])
    }

    func testSSHIdentityGraceSkipsProvisionalHostButKeepsRoutingAndSlowFallback() async throws {
        let runtime = TerminalRuntime.shared, previousWorkspace = runtime.workspace
        let workspace = Workspace()
        runtime.workspace = workspace
        let coordinator = HostCoordinator(runtime: runtime, identityGracePeriod: .milliseconds(80))
        defer { coordinator.stop(); runtime.workspace = previousWorkspace }
        workspace.newLocalSpace()
        let terminal = try XCTUnwrap(workspace.activeTab).id
        func request() -> SSHLaunchRequest {
            SSHLaunchRequest(tabID: terminal, token: "test", connectionID: SSHConnectionID(), credential: "test",
                master: SSHMaster(executable: "/usr/bin/ssh", controlPath: "/tmp/unused", destination: "fixture"),
                shell: SSHShell(destination: "fixture"))
        }
        let greeting = SSHGreeting(version: 1, host: "fixture", boot: "test", uid: 501, home: "/tmp",
                                   capabilities: [], os: "Darwin")
        let fast = request()
        coordinator.connecting(fast)
        XCTAssertTrue(workspace.hostMoveMotion.connecting.contains(terminal))
        coordinator.began(fast)
        XCTAssertTrue(workspace.hostMoveMotion.connecting.contains(terminal))
        XCTAssertEqual(coordinator.machine(for: terminal), .ssh(fast.shell), "Routing must not wait for presentation")
        coordinator.synchronize()
        XCTAssertNil(workspace.hosts.terminals[terminal])
        XCTAssertEqual(workspace.current?.hostID, .local)
        coordinator.authenticated(fast, greeting: greeting)
        XCTAssertFalse(workspace.hostMoveMotion.connecting.contains(terminal))
        coordinator.connecting(fast)
        XCTAssertFalse(workspace.hostMoveMotion.connecting.contains(terminal), "Late progress cannot restart an authenticated connection")
        XCTAssertEqual(workspace.current?.hostID, .authenticated("fixture"))
        XCTAssertEqual(workspace.hosts.record(.authenticated("fixture")).system?.os, "Darwin")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(workspace.hosts.terminals[terminal]?.authenticated, true, "The old timer must not replace the detected host")
        coordinator.exited(fast)
        XCTAssertEqual(workspace.current?.hostID, .local)

        let slow = request()
        coordinator.began(slow)
        coordinator.failed(slow.connectionID)
        XCTAssertFalse(workspace.hostMoveMotion.connecting.contains(terminal))
        XCTAssertNil(workspace.hosts.terminals[terminal])
        try await TestSupport.eventually(timeout: .seconds(1)) { workspace.hosts.terminals[terminal] != nil }
        XCTAssertEqual(workspace.current?.hostID, .provisional(slow.connectionID.rawValue))
        XCTAssertEqual(workspace.hosts.terminals[terminal]?.state, .disconnected)
        coordinator.authenticated(slow, greeting: greeting)
        XCTAssertEqual(workspace.current?.hostID, .authenticated("fixture"))
        coordinator.exited(slow)

        let cancelled = request()
        coordinator.began(cancelled)
        coordinator.exited(cancelled)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(workspace.hosts.terminals[terminal], "An exited SSH command must not publish a delayed host")
        XCTAssertEqual(workspace.current?.hostID, .local)

        let old = request(), replacement = request()
        coordinator.began(old)
        coordinator.began(replacement)
        coordinator.authenticated(old, greeting: greeting)
        coordinator.exited(old)
        XCTAssertNil(workspace.hosts.terminals[terminal], "Stale identification and exit cannot affect a replacement")
        coordinator.authenticated(replacement, greeting: greeting)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(workspace.hosts.terminals[terminal]?.generation, replacement.connectionID.rawValue)
        XCTAssertEqual(workspace.hosts.terminals[terminal]?.authenticated, true)
        coordinator.exited(replacement)

        workspace.hosts.seed(terminal, from: .authenticated("fixture"), generation: UUID())
        var seeded = request()
        seeded.presentationScope = SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "fixture",
                                                        configuration: "hostname fixture\nuser test\nport 22\n")
        coordinator.began(seeded)
        XCTAssertEqual(workspace.hosts.terminals[terminal]?.host, .authenticated("fixture"))
        XCTAssertEqual(workspace.hosts.terminals[terminal]?.generation, seeded.connectionID.rawValue)
        XCTAssertEqual(workspace.hosts.terminals[terminal]?.authenticated, false)
        coordinator.authenticated(seeded, greeting: greeting)
        XCTAssertEqual(workspace.hosts.terminals[terminal]?.host, .authenticated("fixture"))
        XCTAssertEqual(workspace.hosts.terminals[terminal]?.authenticated, true)
        coordinator.exited(seeded)

        coordinator.began(request())
        coordinator.stop()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(workspace.hosts.terminals[terminal], "Stopping tracking must cancel pending presentation")
    }

    private func enter(_ terminal: UUID, in workspace: Workspace, destination: String = "server", generation: UUID = UUID()) -> UUID {
        workspace.hosts.begin(terminal, generation: generation, destination: destination)
        workspace.placeHostTerminal(terminal)
        return generation
    }
    private func leave(_ terminal: UUID, in workspace: Workspace, generation: UUID) {
        workspace.hosts.remove(terminal, generation: generation)
        workspace.restoreHostTerminal(terminal, generation: generation)
        workspace.regroupHosts()
    }

    func testPlacementRestoreAndRegroupEachCommitOnce() throws {
        for count in [1, 3] {
            let workspace = Workspace()
            workspace.newLocalSpace()
            for _ in 1..<count { workspace.newTab() }
            let original = try XCTUnwrap(workspace.current), terminal = try XCTUnwrap(workspace.activeTab).id
            workspace.onCloseTabs = { _ in XCTFail("A host move must not close a terminal") }
            let revision = workspace.layoutRevision, focus = workspace.focusRequest
            let generation = enter(terminal, in: workspace)
            XCTAssertEqual(workspace.layoutRevision, revision + 1)
            XCTAssertEqual(workspace.activeSurfaceID, terminal)
            if count > 1 { XCTAssertNotEqual(workspace.focusRequest, focus) }
            else { XCTAssertEqual(workspace.focusRequest, focus) }
            let movedFocus = workspace.focusRequest
            leave(terminal, in: workspace, generation: generation)
            XCTAssertEqual(workspace.layoutRevision, revision + 2)
            XCTAssertEqual(workspace.current, original)
            if count > 1 { XCTAssertNotEqual(workspace.focusRequest, movedFocus) }
            else { XCTAssertEqual(workspace.focusRequest, movedFocus) }
            workspace.regroupHosts()
            XCTAssertEqual(workspace.layoutRevision, revision + 2, "An unchanged regroup does not publish")
        }

        let workspace = Workspace()
        for _ in 0..<3 { workspace.newLocalSpace() }
        let greeting = SSHGreeting(version: 1, host: "shared", boot: "test", uid: 501, home: "/tmp", capabilities: [])
        for space in workspace.spaces {
            let terminal = space.tabs[0].id, generation = UUID()
            workspace.hosts.begin(terminal, generation: generation, destination: "shared")
            workspace.hosts.update(terminal, generation: generation, destination: "shared", greeting: greeting, state: .connected)
        }
        let revision = workspace.layoutRevision
        workspace.regroupHosts()
        XCTAssertEqual(workspace.layoutRevision, revision + 1, "All host changes publish together")
        XCTAssertTrue(workspace.spaces.allSatisfy { $0.hostID == .authenticated("shared") })
    }

    func testSingleTerminalRegroupsInPlaceAndRejectsStaleExit() throws {
        let workspace = Workspace(); workspace.newSpace()
        let original = try XCTUnwrap(workspace.current), terminal = try XCTUnwrap(workspace.activeTab).id
        workspace.onCloseTabs = { _ in XCTFail("Reassignment must preserve the terminal") }
        let first = enter(terminal, in: workspace), second = enter(terminal, in: workspace, destination: "next")
        leave(terminal, in: workspace, generation: first)
        XCTAssertEqual(workspace.spaces.count, 1)
        XCTAssertEqual(workspace.current?.id, original.id)
        XCTAssertEqual(workspace.current?.hostID, .provisional(second))
        leave(terminal, in: workspace, generation: second)
        XCTAssertEqual(workspace.current, original)
    }

    func testExtractMiddleTabAndRestoreItsIndexWithoutClosingOrStealingFocus() throws {
        let workspace = Workspace(); workspace.newSpace(); workspace.newTab(); workspace.newTab()
        let original = try XCTUnwrap(workspace.current), ids = workspace.currentTabs.map(\.id)
        let focused = workspace.activeSurfaceID, focusRequest = workspace.focusRequest
        workspace.onCloseTabs = { _ in XCTFail("Extraction must preserve the terminal and its chat session") }
        let revision = workspace.layoutRevision
        let generation = enter(ids[1], in: workspace)
        XCTAssertEqual(workspace.layoutRevision, revision + 1)
        XCTAssertEqual(workspace.spaces.count, 2)
        XCTAssertEqual(workspace.activeSurfaceID, focused)
        XCTAssertEqual(workspace.focusRequest, focusRequest)
        XCTAssertEqual(workspace.spaces[0].tabs.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(workspace.spaces[1].tabs.map(\.id), [ids[1]])
        leave(ids[1], in: workspace, generation: generation)
        XCTAssertEqual(workspace.layoutRevision, revision + 2)
        XCTAssertEqual(workspace.current, original)
        XCTAssertEqual(workspace.spaces.count, 1)
        XCTAssertEqual(workspace.focusRequest, focusRequest)
    }

    func testSplitRestoresGeometryAndKeepsSelectedTerminal() throws {
        let workspace = Workspace(); workspace.newSpace()
        for _ in 0..<3 { workspace.newTab() }
        XCTAssertTrue(workspace.applyLayout(.grid))
        let split = try XCTUnwrap(workspace.current?.layout.splitIDs.first)
        workspace.resizeSplit(split, in: workspace.selectedSpace!, fraction: 0.61)
        let original = try XCTUnwrap(workspace.current), terminal = try XCTUnwrap(workspace.activeTab).id
        let generation = enter(terminal, in: workspace)
        XCTAssertEqual(workspace.activeSurfaceID, terminal)
        XCTAssertNotEqual(workspace.selectedSpace, original.id)
        leave(terminal, in: workspace, generation: generation)
        XCTAssertEqual(workspace.current, original)
        XCTAssertEqual(workspace.activeSurfaceID, terminal)
    }

    func testMissingOriginAndManualMovesKeepSeparateSpace() throws {
        let workspace = Workspace(); workspace.newSpace(); workspace.newTab()
        let original = try XCTUnwrap(workspace.current), terminal = try XCTUnwrap(workspace.activeTab).id
        let generation = enter(terminal, in: workspace)
        workspace.closeSpace(original.id)
        leave(terminal, in: workspace, generation: generation)
        XCTAssertEqual(workspace.spaces.count, 1)
        XCTAssertEqual(workspace.activeSurfaceID, terminal)
        XCTAssertEqual(workspace.current?.hostID, .local)

        workspace.newTab()
        let moved = try XCTUnwrap(workspace.activeTab).id
        let next = enter(moved, in: workspace)
        workspace.moveTabToNewSpace(moved)
        let manual = workspace.selectedSpace
        leave(moved, in: workspace, generation: next)
        XCTAssertEqual(workspace.spaces.count, 2)
        XCTAssertEqual(workspace.selectedSpace, manual)
        XCTAssertEqual(workspace.current?.hostID, .local)
    }

    func testChangedOriginDoesNotOverwriteLayoutOrNewTabs() throws {
        let workspace = Workspace(); workspace.newSpace(); workspace.newTab(); workspace.newTab()
        let original = try XCTUnwrap(workspace.current), terminal = try XCTUnwrap(workspace.activeTab).id
        let generation = enter(terminal, in: workspace)
        workspace.selectSpace(original.id); workspace.newTab(); workspace.applyLayout(.columns)
        let changed = try XCTUnwrap(workspace.current)
        leave(terminal, in: workspace, generation: generation)
        XCTAssertEqual(workspace.current, changed)
        XCTAssertEqual(workspace.spaces.count, 2)
        XCTAssertEqual(workspace.spaces.last?.hostID, .local)
    }

    func testConcurrentSSHInOriginPreventsAMixedHostReturn() throws {
        let workspace = Workspace(); workspace.newSpace(); workspace.newTab()
        let original = try XCTUnwrap(workspace.current), first = original.tabs[0].id, second = original.tabs[1].id
        let a = enter(first, in: workspace, destination: "one")
        _ = enter(second, in: workspace, destination: "two")
        leave(first, in: workspace, generation: a)
        XCTAssertEqual(workspace.spaces.count, 2)
        XCTAssertEqual(workspace.spaces.first { $0.tabs.contains { $0.id == first } }?.hostID, .local)
        XCTAssertNotEqual(workspace.spaces.first { $0.id == original.id }?.hostID, .local)
    }

    func testHostOrderingShortcutsCyclingAndMixedHostDrops() throws {
        let workspace = Workspace(); workspace.newSpace(); workspace.newSpace(); workspace.newSpace()
        let ids = workspace.spaces.map(\.id), terminals = workspace.spaces.map { $0.tabs[0].id }
        _ = enter(terminals[2], in: workspace, destination: "first")
        _ = enter(terminals[0], in: workspace, destination: "second")
        XCTAssertEqual(workspace.presentationSpaces.map(\.id), [ids[1], ids[2], ids[0]])
        workspace.selectSpace(at: 0)
        XCTAssertEqual(workspace.selectedSpace, ids[1])
        workspace.cycleSpace(1)
        XCTAssertEqual(workspace.selectedSpace, ids[2])
        workspace.selectSpace(at: 8)
        XCTAssertEqual(workspace.selectedSpace, ids[0])
        XCTAssertFalse(workspace.reorderSpace(ids[0], relativeTo: ids[1], after: false))
        XCTAssertFalse(workspace.canMoveTab(terminals[0], to: workspace.spaces[1].focusedPane))
        XCTAssertFalse(workspace.moveTab(terminals[0], to: workspace.spaces[1].focusedPane))
        workspace.spaceOrder = .flat
        XCTAssertEqual(workspace.presentationSpaces.map(\.id), [ids[1], ids[2], ids[0]])
        XCTAssertTrue(workspace.reorderSpace(ids[0], relativeTo: ids[2], after: false))
        XCTAssertEqual(workspace.presentationSpaces.map(\.id), [ids[1], ids[0], ids[2]])
    }

    func testFilterFindsHostAliasesAndMixedRowsAndUnknownHostsRemainReachable() throws {
        let workspace = Workspace(); workspace.newSpace(); workspace.newTab()
        let original = try XCTUnwrap(workspace.current), terminal = original.tabs[0].id
        workspace.hosts.begin(terminal, generation: UUID(), destination: "alice@build-server")
        XCTAssertEqual(workspace.spaces(matching: "BUILD-SERVER").map(\.id), [original.id])
        XCTAssertEqual(workspace.spaces(matching: "alice@").map(\.id), [original.id])
        XCTAssertEqual(workspace.spaces(matching: original.name).map(\.id), [original.id])
        XCTAssertTrue(workspace.spaces(matching: "absent").isEmpty)
        workspace.spaces[0].name = "Manual name"
        XCTAssertEqual(workspace.spaces(matching: "manual").map(\.id), [original.id])
        workspace.spaces[0].hostID = .authenticated("missing-metadata")
        XCTAssertEqual(workspace.presentationSpaces.map(\.id), [original.id])
        workspace.selectSpace(at: 0)
        XCTAssertEqual(workspace.selectedSpace, original.id)
    }
}
