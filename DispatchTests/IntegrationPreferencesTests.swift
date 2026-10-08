import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class IntegrationPreferencesTests: XCTestCase {
    func testHerdrToggleRetainedLauncherEOFDetachAndClose() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        let root = URL(fileURLWithPath: "/tmp/hi-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let socket = root.appendingPathComponent("herdr.sock").path
        defer {
            _ = try? HerdrSocket(path: socket).request("server.stop")
            try? FileManager.default.removeItem(at: root)
        }
        func snapshot() throws -> HerdrSnapshot {
            struct Reply: Decodable { let snapshot: HerdrSnapshot }
            return try JSONDecoder().decode(Reply.self, from: HerdrSocket(path: socket).request("session.snapshot")).snapshot
        }
        let sourceID = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[sourceID].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let source = try XCTUnwrap(app.runtime.views[sourceID])
        let stub = root.appendingPathComponent("herdr")
        try """
        #!/bin/sh
        if test "$#" -gt 0; then
          printf 'HERDR_REMOTE_ARG_<%s>\\n' "$@"
          exit 23
        fi
        printf 'HERDR_PASSTHROUGH_READY\\n'
        IFS= read -r reply
        printf 'HERDR_PASSTHROUGH_%s\\n' "$reply"
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        var preferences = app.runtime.preferences
        preferences.spaces[on: "herdr"] = false
        try app.runtime.apply(preferences)
        TerminalTestSupport.send("export PATH=\(HerdrLaunch.quote(root.path)):\(TestSupport.path):/usr/bin:/bin; herdr", to: source)
        try await app.wait { TerminalTestSupport.screen(terminal: source).contains("HERDR_PASSTHROUGH_READY") }
        TerminalTestSupport.send("OK", to: source)
        try await app.wait { TerminalTestSupport.screen(terminal: source).contains("HERDR_PASSTHROUGH_OK") }
        XCTAssertNotEqual(app.workspace.current?.shows("herdr"), true)
        preferences.spaces[on: "herdr"] = true
        try app.runtime.apply(preferences)
        for (index, arguments) in [["--remote", "target with spaces", "--session", "agents"],
                                   ["--remote=other", "--session=agents"],
                                   ["client", "--remote", "another target"]].enumerated() {
            TerminalTestSupport.send("herdr " + arguments.map(HerdrLaunch.quote).joined(separator: " ") +
                "; printf 'HERDR_REMOTE_STATUS_%s_\(index)\\n' \"$?\"", to: source)
            try await app.wait { TerminalTestSupport.screen(terminal: source).contains("HERDR_REMOTE_STATUS_23_\(index)") }
            for argument in arguments {
                XCTAssertTrue(TerminalTestSupport.screen(terminal: source).contains("HERDR_REMOTE_ARG_<\(argument)>"))
            }
            XCTAssertNotEqual(app.workspace.current?.shows("herdr"), true, "Upstream remote commands remain terminal-rendered with integration enabled")
            XCTAssertEqual(app.workspace.activeTab?.id, sourceID)
        }
        TerminalTestSupport.send("export PATH=\(TestSupport.path):/usr/bin:/bin; export XDG_CONFIG_HOME=\(HerdrLaunch.quote(root.path)); export XDG_STATE_HOME=\(HerdrLaunch.quote(root.path)); export HERDR_SOCKET_PATH=\(HerdrLaunch.quote(socket)); herdr; printf 'LAUNCHER_%s\\n' RETURNED", to: source)
        try await app.wait { app.workspace.current?.shows("herdr") == true }
        XCTAssertTrue(app.workspace.allTabIDs.contains(sourceID))
        try await app.wait { TerminalTestSupport.screen(terminal: source).contains("LAUNCHER_RETURNED") }
        let original = try XCTUnwrap(app.workspace.current)
        app.workspace.newTab()
        try await app.wait {
            app.workspace.current?.windowCount == 2 && app.workspace.current?.shows("herdr") == true
                && app.workspace.activeTab?.isConnecting == false
        }
        let tab = try XCTUnwrap(app.workspace.activeTab), surfaceID = tab.focusedSurfaceID
        try await app.wait { app.runtime.views[surfaceID].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(app.runtime.views[surfaceID])
        TerminalTestSupport.send("printf 'EOF_%s\\n' READY", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("EOF_READY") }
        let started = ContinuousClock.now
        TerminalTestSupport.key(2, "d", terminal, modifiers: .control)
        var sawDisconnect = false
        try await TestSupport.eventually(timeout: .seconds(2), interval: .milliseconds(5), diagnostic: "EOF screen: \(TerminalTestSupport.screen(terminal: terminal)); errors: \(app.runtime.helpers.values.compactMap(\.error))") {
            sawDisconnect = sawDisconnect || TerminalTestSupport.screen(terminal: terminal).contains("Herdr disconnected")
            return !app.workspace.allTabIDs.contains(tab.id)
        }
        XCTAssertFalse(sawDisconnect)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(700), "EOF should not wait for the one-second reconnect loop")
        XCTAssertEqual(app.workspace.current?.id, original.id)
        XCTAssertEqual(app.workspace.current?.windowCount, 1)
        app.workspace.newSpace()
        try await app.wait {
            app.workspace.spaces.filter { $0.shows("herdr") }.count == 2 &&
                app.workspace.current?.id != original.id && app.workspace.activeTab?.isConnecting == false
        }
        let closed = try XCTUnwrap(app.workspace.current)
        app.workspace.closeSpace(closed.id)
        try await TestSupport.eventually {
            let remoteClosed = try !snapshot().workspaces.contains { $0.workspace_id == closed.key }
            return !app.workspace.spaces.contains { $0.id == closed.id } && remoteClosed
        }
        let before = try snapshot().panes.map(\.terminal_id)
        app.workspace.detachSpace(original.id)
        XCTAssertFalse(app.workspace.spaces.contains { $0.id == original.id })
        XCTAssertEqual(try snapshot().panes.map(\.terminal_id), before, "Detach leaves server terminals alive")
    }
}
