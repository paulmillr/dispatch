import AppKit
import Darwin
import XCTest
@testable import DispatchApp

@MainActor
final class SSHConnectionStateTests: XCTestCase {
    func testRecoveryEndsWhenItsTerminalClosesBeforeTheAppReplies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for parked in [false, true] {
            var master: Int32 = -1, slave: Int32 = -1
            XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
            guard master >= 0, slave >= 0 else { return }
            defer { Darwin.close(slave) }
            Darwin.close(master)
            let id = SSHConnectionID(), credential = UUID().uuidString
            let reply = root.appendingPathComponent(id.rawValue.uuidString + ".sshresume")
            if parked {
                try JSONEncoder().encode(SSHResumeDecision(credential: credential, waiting: true)).write(to: reply, options: .atomic)
            }
            let finished = expectation(description: "Closed terminal ends recovery")
            let input = slave
            let task = Task.detached {
                let status = SSHLauncherCommand.awaitRecovery(directory: root.path, id: id, credential: credential,
                    status: 255, recoverable: true, exitedNormally: true, input: input)
                finished.fulfill()
                return status
            }
            await fulfillment(of: [finished], timeout: 2)
            // Release a broken waiter too, so a failed regression cannot leak a worker.
            try JSONEncoder().encode(SSHResumeDecision(credential: credential, exitStatus: 130)).write(to: reply, options: .atomic)
            let status = await task.value
            XCTAssertEqual(status, 255)
        }
    }

    func testRetirementCancelsOnlyItsOwnWorkAndKeepsCleanupAwaitable() async throws {
        let origin = UUID()
        func owner() -> SSHConnectionState {
            let id = SSHConnectionID()
            return SSHConnectionState(request: .init(tabID: origin, token: "fixture", connectionID: id,
                credential: UUID().uuidString,
                master: .init(executable: "/usr/bin/ssh", controlPath: "/unused/" + id.rawValue.uuidString, destination: "fixture"),
                shell: .init(destination: "fixture")))
        }
        let retired = owner(), replacement = owner()
        let launch = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let replacementLaunch = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let cleanup = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        defer { launch.cancel(); replacementLaunch.cancel(); cleanup.cancel() }
        retired.launchTask = launch
        retired.cleanupTask = cleanup
        replacement.launchTask = replacementLaunch

        XCTAssertTrue(retired.beginFinishing())
        XCTAssertFalse(retired.beginFinishing(), "Repeated close must not schedule another master cleanup")
        retired.retireOrigin()
        XCTAssertTrue(launch.isCancelled)
        XCTAssertFalse(replacementLaunch.isCancelled, "A reused origin keeps its own work")
        XCTAssertFalse(replacement.isFinishing)
        XCTAssertFalse(cleanup.isCancelled, "Shutdown must await master cleanup instead of cancelling it")
        XCTAssertNotNil(retired.cleanupTask)
        await launch.value
    }
}

@MainActor
final class SSHConnectionLifetimeTests: XCTestCase {
    func testRemoteHerdrSurvivesOriginShellExitUntilLastDetach() async throws {
        try await retainedHerdr(closeOrigin: false)
    }

    func testRemoteHerdrSurvivesOriginTabCloseUntilLastDetach() async throws {
        try await retainedHerdr(closeOrigin: true)
    }

    func testRetainedHerdrDoesNotOwnReusedOriginSSHOrTmux() async throws {
        try await retainedHerdr(closeOrigin: false, reuseOrigin: true)
    }

    func testOriginShellExitWithoutNativeConsumersReleasesMaster() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let connection = try await connect(app, server: server, source: source)
        let terminal = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("exit 17", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            app.runtime.ssh.machine(for: source) == nil && TerminalTestSupport.screen(terminal: terminal).contains("LIFETIME_STATUS_17")
        }
        try await assertReleased(connection, app: app)
    }

    private func retainedHerdr(closeOrigin: Bool, reuseOrigin: Bool = false) async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        // The origin shell is exited, closed or reused below (tmux keeps auto-close); only herdr keeps it.
        app.workspace.closeLaunching["herdr"] = false
        let server = try await SSHTestServer(); defer { server.stop() }
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { if let api = try? HerdrSocket(path: socket) { try? api.request("server.stop") } }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let connection = try await connect(app, server: server, source: source)
        let original = try XCTUnwrap(app.runtime.views[source])
        let launch = "export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path) +
            "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr"
        TerminalTestSupport.send(launch, to: original)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        let space = try XCTUnwrap(app.workspace.current), endpoint = try XCTUnwrap(space.remote)
        let nativeID = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[nativeID]?.surface != nil }
        let native = try XCTUnwrap(app.runtime.views[nativeID])
        let surface = try XCTUnwrap(native.surface)
        let processFile = server.root.appendingPathComponent("native-pid")
        TerminalTestSupport.send("printf '%s\\n' $$ > " + HerdrLaunch.quote(processFile.path) + "; printf 'NATIVE_%s\\n' BEFORE", to: native)
        try await app.wait { TerminalTestSupport.screen(terminal: native).contains("NATIVE_BEFORE") }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: processFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let process = try XCTUnwrap(AgentProcess.capture(pid))

        if closeOrigin {
            app.workspace.closeTab(source)
            try await app.wait { !app.workspace.allTabIDs.contains(source) }
        } else {
            app.workspace.selectTab(source)
            TerminalTestSupport.send("exit 17", to: original)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: original)) {
                app.runtime.ssh.machine(for: source) == nil && TerminalTestSupport.screen(terminal: original).contains("LIFETIME_STATUS_17")
            }
            XCTAssertTrue(app.workspace.allTabIDs.contains(source))
            if !reuseOrigin {
                app.workspace.closeTab(source)
                try await app.wait { !app.workspace.allTabIDs.contains(source) }
            }
        }
        app.workspace.selectSurface(nativeID)
        XCTAssertTrue(app.runtime.views[nativeID]?.surface === surface,
                      "Origin exit and reuse must preserve the retained connection's exact renderer surface")
        XCTAssertEqual(app.runtime.link(of: nativeID)?.launch.connectionID, connection.launch.connectionID)
        XCTAssertNotNil(app.runtime.ssh.links[connection.launch.connectionID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: connection.launch.master.controlPath))
        XCTAssertEqual(app.workspace.current?.remote, endpoint)
        TerminalTestSupport.send("printf 'NATIVE_%s\\n' AFTER", to: native)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: native)) {
            TerminalTestSupport.screen(terminal: native).contains("NATIVE_AFTER")
        }
        XCTAssertTrue(process.alive)
        var reused: SSHCoordinator.Link?
        var tmuxID: UUID?
        if reuseOrigin {
            app.workspace.selectTab(source)
            let next = try await connect(app, server: server, source: source)
            reused = next
            XCTAssertNotEqual(next.launch.connectionID, connection.launch.connectionID)
            XCTAssertEqual(app.runtime.link(of: source)?.launch.connectionID, next.launch.connectionID,
                           "The closed origin must not claim a new SSH shell in the same tab")
            try await app.attach()
            tmuxID = try XCTUnwrap(app.workspace.activeSurfaceID)
            XCTAssertEqual(app.runtime.link(of: try XCTUnwrap(tmuxID))?.launch.connectionID, next.launch.connectionID)
        }
        app.workspace.detachSpace(space.id)
        try await app.wait { !app.workspace.spaces.contains { $0.remote == endpoint && $0.shows("herdr") } }
        XCTAssertNil(app.runtime.views[nativeID], "Last-consumer detach releases the remote terminal")
        try await assertReleased(connection, app: app)
        XCTAssertTrue(process.alive, "Releasing the final client must retain native server jobs")
        struct Snapshot: Decodable { let snapshot: HerdrSnapshot }
        let remaining = try JSONDecoder().decode(Snapshot.self, from: HerdrSocket(path: socket).request("session.snapshot"))
        XCTAssertFalse(remaining.snapshot.workspaces.isEmpty, "Detach must not close the remote workspace")
        if let reused, let tmuxID {
            // Late notices from the retired generation and an old credential
            // cannot close the new login that reuses this terminal UUID.
            app.runtime.ssh.closed(connection.launch.connectionID, credential: connection.launch.credential)
            app.runtime.ssh.channelClosed(connection.launch.connectionID,
                notice: .init(credential: connection.launch.credential, status: 17, recoverable: false, transportExitedNormally: true))
            app.runtime.ssh.closed(reused.launch.connectionID, credential: connection.launch.credential)
            app.runtime.ssh.channelClosed(reused.launch.connectionID,
                notice: .init(credential: connection.launch.credential, status: 17, recoverable: false, transportExitedNormally: true))
            XCTAssertEqual(app.workspace.current?.shows("tmux"), true)
            XCTAssertEqual(app.runtime.link(of: tmuxID)?.launch.connectionID, reused.launch.connectionID,
                           "Releasing the old herdr master must not disconnect the new tmux gateway")
            try await app.wait { app.runtime.views[tmuxID]?.surface != nil }
            let tmux = try XCTUnwrap(app.runtime.views[tmuxID])
            TerminalTestSupport.send("printf 'TMUX_%s\\n' SURVIVED", to: tmux)
            try await app.wait { TerminalTestSupport.screen(terminal: tmux).contains("TMUX_SURVIVED") }
            app.workspace.detachSpace(try XCTUnwrap(app.workspace.current?.id))
            try await assertReleased(reused, app: app)
        }
    }

    private func connect(_ app: TmuxWalkthrough, server: SSHTestServer, source: UUID) async throws -> SSHCoordinator.Link {
        try await app.wait { app.runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ") +
            "; printf 'LIFETIME_STATUS_%s\\n' \"$?\"", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.link(of: source) != nil
        }
        // A retained herdr connection may share the source tab ID. Resolve the
        // new shell through its active context instead of dictionary ordering.
        return try XCTUnwrap(app.runtime.link(of: source))
    }

    private func assertReleased(_ connection: SSHCoordinator.Link, app: TmuxWalkthrough) async throws {
        let folder = URL(fileURLWithPath: connection.launch.master.controlPath).deletingLastPathComponent().path
        try await TestSupport.eventually(timeout: .seconds(15)) {
            app.runtime.ssh.links[connection.launch.connectionID] == nil &&
                !FileManager.default.fileExists(atPath: connection.launch.master.controlPath) &&
                !FileManager.default.fileExists(atPath: folder)
        }
    }
}
