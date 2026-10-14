import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class HerdrLaunchLifecycleTests: XCTestCase {

    func testRestartIsolatesLateWritersAndWaitsForRetiredControlCleanup() async throws {
        let launch = HerdrLaunch()
        try launch.start()
        let old = launch.directory, tab = System.uuid()
        let files = ["bin/ssh", "native/zsh/.zshrc"]
        let wrappers = try files.map { try System.read(old.appendingPathComponent($0)) }
        let oldToken = try XCTUnwrap(launch.environment(for: tab)["DISPATCH_HERDR_TOKEN"])
        let gate = AsyncStream<Void>.makeStream()
        let cleanup = Task { for await _ in gate.stream { break } }
        defer { gate.continuation.finish(); launch.stop() }
        launch.stop(after: cleanup)
        XCTAssertTrue(System.exists(old), "Pending SSH cleanup still needs the retired generation's control sockets")
        let repeated = launch.stop()
        var repeatFinished = false
        let completion = Task { await repeated.value; repeatFinished = true }

        try launch.start()
        let current = launch.directory
        XCTAssertNotEqual(current, old)
        XCTAssertEqual(try files.map { try System.read(current.appendingPathComponent($0)) }, wrappers)
        XCTAssertTrue(System.exists(old))
        let token = try XCTUnwrap(launch.environment(for: tab)["DISPATCH_HERDR_TOKEN"])
        XCTAssertNotEqual(token, oldToken)
        var received: [SSHConnectionID] = [], closed: [SSHConnectionID] = []
        launch.sshHandler = { received.append($0.connectionID) }
        launch.sshClosed = { id, _ in closed.append(id) }
        func request(_ id: SSHConnectionID, token: String, at directory: URL) throws {
            let request = SSHLaunchRequest(tabID: tab, token: token, connectionID: id, credential: System.uuid().uuidString,
                master: .init(executable: "/usr/bin/ssh", controlPath: directory.path + "/s-" + id.rawValue.uuidString + "/master", destination: "unused"),
                shell: .init(destination: "unused"))
            try System.write(JSONEncoder().encode(request), to: directory.appendingPathComponent(id.rawValue.uuidString + ".sshrequest"))
        }
        // Complete the atomic writes used by retired launcher processes after restart.
        try request(SSHConnectionID(System.uuid()), token: oldToken, at: old)
        let notice = SSHCloseNotice(credential: System.uuid().uuidString, status: 0, recoverable: false)
        try System.write(JSONEncoder().encode(notice), to: old.appendingPathComponent(System.uuid().uuidString + ".sshclosed"))
        try request(SSHConnectionID(System.uuid()), token: oldToken, at: current)
        let fresh = SSHConnectionID(System.uuid())
        try request(fresh, token: token, at: current)
        try await TestSupport.eventually { received == [fresh] }
        XCTAssertTrue(closed.isEmpty)
        XCTAssertFalse(repeatFinished, "A second stop must still wait for earlier retired generations")
        gate.continuation.yield(()); gate.continuation.finish()
        await completion.value
        XCTAssertTrue(repeatFinished)
        XCTAssertFalse(System.exists(old))
        XCTAssertTrue(System.exists(current), "Retired cleanup must never delete the restarted mailbox")
        XCTAssertThrowsError(try System.write(Data("late".utf8), to: old.appendingPathComponent("late.sshclosed")))
    }

    func testFailedStartupCleansPartialGenerationAndCanRetry() throws {
        let launch = HerdrLaunch()
        let helper = System.environment("DISPATCH_HELPER_EXECUTABLE")
        func restore() {
            if let helper { setenv("DISPATCH_HELPER_EXECUTABLE", helper, 1) }
            else { unsetenv("DISPATCH_HELPER_EXECUTABLE") }
        }
        defer { restore(); launch.stop() }
        try launch.start()
        try launch.install([.helper(program: "codex", key: "codex")])
        let missing = launch.directory.appendingPathComponent("missing-helper")
        launch.stop()
        setenv("DISPATCH_HELPER_EXECUTABLE", missing.path, 1)
        XCTAssertThrowsError(try launch.start(), "Missing shell integration dependencies must fail startup")
        let failed = launch.directory
        XCTAssertFalse(System.exists(failed))
        restore()
        try launch.start()
        XCTAssertNotEqual(launch.directory, failed)
        XCTAssertTrue(System.exists(launch.directory))
    }

    func testRuntimeRetryClearsErrorAndRealSSHUsesEachRestartedMailbox() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let runtime = TerminalRuntime.shared
        runtime.stop(); defer { runtime.stop() }
        var invalid = Preferences(); invalid.fontSize = 0
        runtime.start(preferences: invalid)
        XCTAssertNotNil(runtime.error)
        XCTAssertNil(runtime.engine)
        var previous = runtime.herdrLaunch.directory
        let server = try await SSHTestServer(); defer { server.stop() }
        for index in 0..<2 {
            let app = try TmuxWalkthrough(); defer { app.close() }
            let directory = runtime.herdrLaunch.directory
            XCTAssertNotEqual(directory, previous); previous = directory
            XCTAssertNil(runtime.error); XCTAssertNotNil(runtime.engine)
            let source = try XCTUnwrap(app.workspace.activeTab?.id)
            try await app.wait { runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
            let terminal = try XCTUnwrap(runtime.views[source])
            TerminalTestSupport.send("printf 'RESTART_MAILBOX_%s\\n' \"$DISPATCH_HERDR_DIRECTORY\"", to: terminal)
            try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("RESTART_MAILBOX_" + directory.path) }
            let command = "printf 'RESTART_INTEGRATION_%s_\(index)\\n' \"${DISPATCH_SSH_HELPER:+yes}\"; exit 23"
            TerminalTestSupport.send("ssh " + (["-tt"] + server.options + [server.destination, command]).map(HerdrLaunch.quote).joined(separator: " ") +
                "; printf 'RESTART_STATUS_%s_\(index)\\n' \"$?\"", to: terminal)
            try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
                let screen = TerminalTestSupport.screen(terminal: terminal)
                return screen.contains("RESTART_INTEGRATION_yes_\(index)") && screen.contains("RESTART_STATUS_23_\(index)")
            }
            app.close()
            try await TestSupport.eventually { !System.exists(directory) }
        }
    }
}
