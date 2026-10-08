import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class SSHConsumerCleanupTests: XCTestCase {
    private var supervisors: [AgentProcess] = []
    func testResetAllDetachesHerdrAndPreservesRemoteServer() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let connection = try await connect(app, server: server, source: source)
        let owned = try await processes(connection)
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { _ = try? HerdrSocket(path: socket).request("server.stop") }
        TerminalTestSupport.send(launch(server: server, socket: socket), to: try XCTUnwrap(app.runtime.views[source]))
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        try await app.controller.resetSSHState()
        try await assertReleased(connection, processes: owned, app: app)
        XCTAssertEqual(Array(app.runtime.helpers.keys), [.local], "Reset leaves no remote helper workspace")
        XCTAssertTrue(app.runtime.helpers.values.allSatisfy { $0.error == nil })
        XCTAssertTrue(app.workspace.spaces.allSatisfy { !$0.shows("herdr") && $0.hostID == .local })
        let snapshot = try HerdrRPC.snapshot(from: HerdrSocket(path: socket).request("session.snapshot"))
        XCTAssertFalse(snapshot.panes.isEmpty, "Reset detaches the client and preserves the remote terminal")
    }

    func testResetAllAwaitsMasterAndHelperCleanupAndKeepsLocalShell() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let connection = try await connect(app, server: server, source: source)
        let processes = try await processes(connection)
        app.workspace.newLocalSpace()
        let local = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[local]?.surface != nil }
        let terminal = try XCTUnwrap(app.runtime.views[local])
        let surface = terminal.surface
        try await app.controller.resetSSHState()
        try await assertReleased(connection, processes: processes, app: app)
        XCTAssertTrue(app.workspace.allTabIDs.contains(local))
        XCTAssertFalse(app.workspace.allTabIDs.contains(source))
        XCTAssertTrue(app.runtime.views[local] === terminal)
        XCTAssertTrue(terminal.surface === surface)
        TerminalTestSupport.send("printf 'RESET_LOCAL_%s\\n' READY", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("RESET_LOCAL_READY") }
    }

    func testApplicationQuitRepliesAfterMasterHelperAndMailboxCleanup() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let connection = try await connect(app, server: server, source: source)
        let processes = try await processes(connection)
        let mailbox = app.runtime.herdrLaunch.directory
        let answerer = CloseConfirmationAnswerer(); defer { answerer.stop() }
        var replies = 0
        // Exercise the delegate's real shutdown path with a captured AppKit
        // reply, so the test host itself is never asked to terminate.
        let response = app.controller.requestTermination { allowed in
            XCTAssertTrue(allowed)
            XCTAssertNil(app.runtime.ssh.links[connection.launch.connectionID])
            XCTAssertFalse(FileManager.default.fileExists(atPath: mailbox.path))
            XCTAssertTrue(processes.allSatisfy { !$0.alive }, "Quit must finish private master/helper cleanup before replying")
            XCTAssertTrue(self.supervisors.allSatisfy { !$0.alive }, "Quit must finish login supervisor cleanup before replying")
            replies += 1
        }
        XCTAssertEqual(response, .terminateLater)
        XCTAssertEqual(replies, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mailbox.path))
        XCTAssertEqual(app.controller.requestTermination { _ in XCTFail("Repeated Quit must share the pending termination") }, .terminateLater)
        try await TestSupport.eventually(timeout: .seconds(15)) { replies == 1 }
        try await assertReleased(connection, processes: processes, app: app)
    }

    func testRuntimeStopReleasesActiveMasterAndHelperBeforeRemovingMailbox() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let connection = try await connect(app, server: server, source: source)
        let processes = try await processes(connection)
        let mailbox = app.runtime.herdrLaunch.directory
        app.window.orderOut(nil); app.window.contentView = nil
        app.runtime.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: mailbox.path),
                      "The retired mailbox must retain the control path while asynchronous master cleanup is pending")
        try await assertReleased(connection, processes: processes, app: app)
        try await TestSupport.eventually { !FileManager.default.fileExists(atPath: mailbox.path) }
    }

    func testFailedHerdrLaunchDoesNotRetainMasterAfterOriginExit() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let connection = try await connect(app, server: server, source: source)
        let processes = try await processes(connection)
        let original = try XCTUnwrap(app.runtime.views[source])
        // A regular file cannot contain a Unix socket. Exercise a real herdr
        // server-start failure after the endpoint has already been registered.
        let blocked = server.root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blocked)
        let socket = blocked.appendingPathComponent("herdr.sock").path
        TerminalTestSupport.send(launch(server: server, socket: socket) + "; printf 'FAILED_HERDR_%s\\n' \"$?\"", to: original)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: original)) {
            TerminalTestSupport.screen(terminal: original).contains("FAILED_HERDR_1")
        }
        XCTAssertTrue(app.workspace.spaces.allSatisfy { !$0.shows("herdr") })
        XCTAssertTrue(app.runtime.helpers.values.contains { $0.error?.contains("remote herdr server") == true })
        try await exitOrigin(app, source: source, terminal: original)
        try await assertReleased(connection, processes: processes, app: app)
    }

    func testUpstreamFinalWorkspaceCloseReleasesRetainedMasterAndHelper() async throws {
        let app = try TmuxWalkthrough(autoClose: false); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let connection = try await connect(app, server: server, source: source)
        let processes = try await processes(connection)
        let original = try XCTUnwrap(app.runtime.views[source])
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { _ = try? HerdrSocket(path: socket).request("server.stop") }
        TerminalTestSupport.send(launch(server: server, socket: socket), to: original)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        let space = try XCTUnwrap(app.workspace.current), workspaceID = try XCTUnwrap(space.key)
        let nativeID = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[nativeID]?.surface != nil }
        let native = try XCTUnwrap(app.runtime.views[nativeID])
        TerminalTestSupport.send("printf 'CLEANUP_NATIVE_%s\\n' READY", to: native)
        try await app.wait { TerminalTestSupport.screen(terminal: native).contains("CLEANUP_NATIVE_READY") }
        app.workspace.selectTab(source)
        try await app.wait { original.isPresented && original.window === app.window }
        try await exitOrigin(app, source: source, terminal: original)
        XCTAssertNotNil(app.runtime.ssh.links[connection.launch.connectionID])
        XCTAssertTrue(processes.allSatisfy(\.alive), "Native views must retain both the helper and master")
        // Close directly through the real server API, without the app's explicit
        // detach path, so observer reconciliation must release the final client.
        let params = try JSONSerialization.data(withJSONObject: ["workspace_id": workspaceID])
        _ = try HerdrSocket(path: socket).request("workspace.close", params: params)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !app.workspace.spaces.contains { $0.hostID == space.hostID && $0.shows("herdr") }
        }
        try await assertReleased(connection, processes: processes, app: app)
    }

    private func launch(server: SSHTestServer, socket: String) -> String {
        "export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path) +
            "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr"
    }

    private func connect(_ app: TmuxWalkthrough, server: SSHTestServer, source: UUID) async throws -> SSHCoordinator.Link {
        try await app.wait { app.runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ") +
            "; printf 'CLEANUP_STATUS_%s\\n' \"$?\"", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        return try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == source })
    }

    private func exitOrigin(_ app: TmuxWalkthrough, source: UUID, terminal: TerminalView) async throws {
        TerminalTestSupport.send("exit 19", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            app.runtime.ssh.machine(for: source) == nil && TerminalTestSupport.screen(terminal: terminal).contains("CLEANUP_STATUS_19")
        }
    }

    private func processes(_ connection: SSHCoordinator.Link) async throws -> [AgentProcess] {
        // Loopback fixture: inspect the real helper process from the test's
        // ordinary SSH channel. The random public session ID scopes the match;
        // the local process record also captures start time for cleanup checks.
        let list = try await SSHTestCommand.run(master: connection.launch.master, argv: ["/bin/ps", "-axww", "-o", "pid=,command="])
        XCTAssertEqual(list.status, 0)
        let logins = String(decoding: list.output, as: UTF8.self).split(separator: "\n").compactMap { line -> (pid: Int32, worker: Bool)? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            // The remote login (`dsptch login <profile> --session S …`) runs the session's helper bus.
            guard fields.count >= 5, fields[1].hasSuffix("/dsptch"), fields[2] == "login",
                  fields.contains(Substring(connection.launch.sessionID)) else { return nil }
            guard let pid = Int32(fields[0]) else { return nil }
            return (pid, fields[fields.count - 2] == "--login-worker")
        }
        // The frontend returns the origin shell's status; the worker owns the shared bus.
        // Retention checks follow the worker, while full teardown checks both processes.
        let helpers = logins.filter(\.worker).map(\.pid)
        supervisors = try logins.filter { !$0.worker }.map { try XCTUnwrap(AgentProcess.capture($0.pid)) }
        XCTAssertEqual(supervisors.count, 1, "The loopback session must have one login supervisor")
        XCTAssertEqual(helpers.count, 1, "The loopback session must have one helper login")
        let helperPID = try XCTUnwrap(helpers.first)
        let master = connection.launch.master
        let command = ([master.executable] + master.controlArguments("check")).map(HerdrLaunch.quote).joined(separator: " ") + " 2>&1"
        let checked = try await SSHCommand.run(executable: "/bin/sh", arguments: ["-c", command])
        XCTAssertEqual(checked.status, 0)
        let output = String(decoding: checked.output, as: UTF8.self)
        let range = try XCTUnwrap(output.range(of: "pid="))
        let masterPID = try XCTUnwrap(Int32(output[range.upperBound...].prefix { $0.isNumber }))
        return [try XCTUnwrap(AgentProcess.capture(helperPID)), try XCTUnwrap(AgentProcess.capture(masterPID))]
    }

    private func assertReleased(_ connection: SSHCoordinator.Link, processes: [AgentProcess], app: TmuxWalkthrough) async throws {
        let folder = URL(fileURLWithPath: connection.launch.master.controlPath).deletingLastPathComponent().path
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Master/helper processes or private control directory survived the final consumer") {
            app.runtime.ssh.links[connection.launch.connectionID] == nil &&
                !FileManager.default.fileExists(atPath: folder) && processes.allSatisfy { !$0.alive } &&
                self.supervisors.allSatisfy { !$0.alive }
        }
    }
}
