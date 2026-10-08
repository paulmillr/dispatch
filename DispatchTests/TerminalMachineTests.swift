import Foundation
import XCTest
@testable import DispatchApp

final class TerminalMachineTests: XCTestCase {
    func testSSHConnectionCloningPreservesHostAuthenticationAndQuoting() throws {
        let args = ["ssh", "-tt", "-p2222", "-J", "jump", "-i", "/tmp/key with ' quote", "-L8080:localhost:80", "user@server", "tmux", "-CC"]
        let shell = try XCTUnwrap(SSHShell.parse(executable: "/usr/bin/ssh", arguments: args))
        XCTAssertEqual(shell.destination, "user@server")
        XCTAssertEqual(shell.options, ["-p", "2222", "-J", "jump", "-i", "/tmp/key with ' quote"])
        XCTAssertFalse(shell.command().contains("tmux"))
        XCTAssertTrue(shell.command().contains("RemoteCommand=none"))
        XCTAssertTrue(shell.command().contains("ClearAllForwardings=yes"))
        // Execute only printf locally: confirm shell metacharacters stay data.
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\n' " + shell.arguments.map(HerdrLaunch.quote).joined(separator: " ")]
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self).split(separator: "\n").map(String.init), shell.arguments)
    }

    func testNonInteractiveAndInvalidSSHProcessesAreNotCloned() {
        for args in [["ssh", "-G", "host"], ["ssh", "-N", "host"], ["ssh", "-T", "host"],
                     ["ssh", "host", "ls"], ["ssh", "-p"], ["ssh", "-W", "host:80", "jump"],
                     ["ssh", "-O", "exit", "host"], ["ssh", "-t", "host", "-l", "alice"]] {
            XCTAssertNil(SSHShell.parse(executable: "/usr/bin/ssh", arguments: args), args.description)
        }
        XCTAssertNil(SSHShell.parse(executable: "/usr/bin/other", arguments: ["ssh", "host"]))
        XCTAssertEqual(SSHShell.parse(executable: "/usr/bin/ssh", arguments: ["ssh", "alias"])?.destination, "alias")
    }

    @MainActor
    func testIndependentAutoClosePreferencesMigrateAndReachWorkspace() throws {
        for value in [false, true] {
            let data = Data("{\"autoCloseNativeSpace\":\(value)}".utf8)
            var preferences = try JSONDecoder().decode(Preferences.self, from: data)
            XCTAssertEqual(preferences.closeLaunching[on: "tmux"], value)
            XCTAssertEqual(preferences.closeLaunching[on: "herdr"], value)
            preferences.closeLaunching[on: "tmux"] = !value
            let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(restored.closeLaunching[on: "tmux"], !value)
            XCTAssertEqual(restored.closeLaunching[on: "herdr"], value)
            let runtime = TerminalRuntime(), workspace = Workspace()
            runtime.preferences = restored
            runtime.workspace = workspace
            XCTAssertEqual(workspace.closeLaunching[on: "tmux"], !value)
            XCTAssertEqual(workspace.closeLaunching[on: "herdr"], value)
        }
    }

    func testIntegrationPreferencesMigrateAndRoundTrip() throws {
        let defaults = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(defaults.spaces[on: "herdr"])
        XCTAssertTrue(defaults.spaces[on: "tmux"])
        XCTAssertFalse(defaults.enableKittyGraphics)
        XCTAssertFalse(defaults.autoReconnectSSH)
        XCTAssertTrue(defaults.closeLaunching[on: "tmux"] && defaults.closeLaunching[on: "herdr"])
        var changed = defaults
        changed.spaces[on: "herdr"] = false; changed.spaces[on: "tmux"] = false
        changed.enableKittyGraphics = true; changed.closeLaunching = ["tmux": false, "herdr": false]
        changed.autoReconnectSSH = true
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed)), changed)
    }
}
