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
        let bytes = try TestSupport.live(process).output
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
    func testRemovedPreferencesAreIgnoredWithoutResettingCurrentChoices() throws {
        let removed = ["autoCloseNativeSpace", "sidebarTheme", "appearance", "largeSidebarItems", "optionAsAlt",
                       "improveTextContrast", "enableTmuxIntegration", "enableHerdrIntegration", "autoCloseTmuxNativeSpace",
                       "autoCloseHerdrNativeSpace", "dictationRightCommand", "prefixKeys", "backendPrefixKeys", "closeLaunching"]
        var expected = Preferences()
        expected.fontSize = 16; expected.allowClipboardWrites = false; expected.newHostPolicy = .plain
        expected.spaces = ["tmux": false]; expected.dictationKey = .off; expected.prefixKeys = .off
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        for value: Any in [false, true, "herdr", ["tmux": false], ["unexpected": [1, 2]]] {
            var fields = current
            for key in removed { fields[key] = value }
            let restored = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: fields))
            XCTAssertEqual(restored, expected, "Removed values must not affect current preferences, even if malformed")
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
            XCTAssertTrue(removed.allSatisfy { saved[$0] == nil })
        }
    }

    func testIntegrationPreferencesRoundTrip() throws {
        let defaults = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(defaults.spaces[on: "herdr"])
        XCTAssertTrue(defaults.spaces[on: "tmux"])
        XCTAssertFalse(defaults.enableKittyGraphics)
        XCTAssertFalse(defaults.autoReconnectSSH)
        XCTAssertEqual(defaults.spaces, [:])
        var changed = defaults
        changed.spaces[on: "herdr"] = false; changed.spaces[on: "tmux"] = false
        changed.enableKittyGraphics = true
        changed.autoReconnectSSH = true
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed)), changed)
    }

    /// A connection the app launched carries the options `arguments` puts first; a clone of it parses back to the same
    /// shell, so cloning a clone never repeats them (its command was different with whichever connection it cloned).
    func testCloningALaunchedConnectionKeepsItsArguments() throws {
        let original = try XCTUnwrap(SSHShell.parse(executable: "/usr/bin/ssh", arguments: ["ssh", "-p", "2222", "user@host"]))
        let clone = try XCTUnwrap(SSHShell.parse(executable: "/usr/bin/ssh", arguments: ["ssh"] + original.arguments))
        XCTAssertEqual(clone.arguments, original.arguments)
        XCTAssertEqual(original.arguments.filter { $0 == "RemoteCommand=none" }.count, 1)
        // As the launcher builds it, from its own invocation's options.
        let launched = SSHShell(destination: "user@host", options: Array(original.arguments.dropLast(3)))
        XCTAssertEqual(launched.arguments, original.arguments)
    }
}
