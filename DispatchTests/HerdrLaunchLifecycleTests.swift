import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class HerdrLaunchLifecycleTests: XCTestCase {

    func testRestartIsolatesLateWritersAndWaitsForRetiredControlCleanup() async throws {
        let launch = HerdrLaunch()
        try launch.start()
        let old = launch.directory, tab = UUID()
        let files = ["bin/ssh", "native/zsh/.zshrc"]
        let wrappers = try files.map { try Data(contentsOf: old.appendingPathComponent($0)) }
        let oldToken = try XCTUnwrap(launch.environment(for: tab)["DISPATCH_HERDR_TOKEN"])
        let gate = AsyncStream<Void>.makeStream()
        let cleanup = Task { for await _ in gate.stream { break } }
        defer { gate.continuation.finish(); launch.stop() }
        launch.stop(after: cleanup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "Pending SSH cleanup still needs the retired generation's control sockets")
        let repeated = launch.stop()
        var repeatFinished = false
        let completion = Task { await repeated.value; repeatFinished = true }

        try launch.start()
        let current = launch.directory
        XCTAssertNotEqual(current, old)
        XCTAssertEqual(try files.map { try Data(contentsOf: current.appendingPathComponent($0)) }, wrappers)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        let token = try XCTUnwrap(launch.environment(for: tab)["DISPATCH_HERDR_TOKEN"])
        XCTAssertNotEqual(token, oldToken)
        var received: [SSHConnectionID] = [], closed: [SSHConnectionID] = []
        launch.sshHandler = { received.append($0.connectionID) }
        launch.sshClosed = { id, _ in closed.append(id) }
        func request(_ id: SSHConnectionID, token: String, at directory: URL) throws {
            let request = SSHLaunchRequest(tabID: tab, token: token, connectionID: id, credential: UUID().uuidString,
                master: .init(executable: "/usr/bin/ssh", controlPath: directory.path + "/s-" + id.rawValue.uuidString + "/master", destination: "unused"),
                shell: .init(destination: "unused"))
            try JSONEncoder().encode(request).write(to: directory.appendingPathComponent(id.rawValue.uuidString + ".sshrequest"), options: .atomic)
        }
        // Complete the atomic writes used by retired launcher processes after restart.
        try request(SSHConnectionID(), token: oldToken, at: old)
        let notice = SSHCloseNotice(credential: UUID().uuidString, status: 0, recoverable: false)
        try JSONEncoder().encode(notice).write(to: old.appendingPathComponent(UUID().uuidString + ".sshclosed"), options: .atomic)
        try request(SSHConnectionID(), token: oldToken, at: current)
        let fresh = SSHConnectionID()
        try request(fresh, token: token, at: current)
        try await TestSupport.eventually { received == [fresh] }
        XCTAssertTrue(closed.isEmpty)
        XCTAssertFalse(repeatFinished, "A second stop must still wait for earlier retired generations")
        gate.continuation.yield(()); gate.continuation.finish()
        await completion.value
        XCTAssertTrue(repeatFinished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path), "Retired cleanup must never delete the restarted mailbox")
        XCTAssertThrowsError(try Data("late".utf8).write(to: old.appendingPathComponent("late.sshclosed"), options: .atomic))
    }

    func testFailedStartupCleansPartialGenerationAndCanRetry() throws {
        let launch = HerdrLaunch()
        let helper = ProcessInfo.processInfo.environment["DISPATCH_HELPER_EXECUTABLE"]
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        restore()
        try launch.start()
        XCTAssertNotEqual(launch.directory, failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: launch.directory.path))
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
            try await TestSupport.eventually { !FileManager.default.fileExists(atPath: directory.path) }
        }
    }
}
