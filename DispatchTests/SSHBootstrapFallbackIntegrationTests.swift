import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class SSHBootstrapFallbackIntegrationTests: XCTestCase {
    func testUnsupportedPlatformPreservesShellTmuxAndCommandStatus() async throws { try await fallback("probe") }
    func testFailedUploadPreservesShellTmuxAndCommandStatus() async throws { try await fallback("upload") }
    func testInvalidGreetingPreservesShellTmuxAndCommandStatus() async throws { try await fallback("greeting") }

    private func fallback(_ stage: String) async throws {
        let app = try TmuxWalkthrough(autoClose: false); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let executable = server.root.appendingPathComponent("ssh-fixture")
        let reached = server.root.appendingPathComponent("failure-reached")
        // Only the app's no-dial auxiliary channel fails. Authentication and
        // both foreground PTYs still run the real OpenSSH client and server.
        let script = """
        #!/bin/sh
        auxiliary=no
        for argument do
          test "$argument" != ControlMaster=no || auxiliary=yes
          command=$argument
        done
        if test "$auxiliary" = yes; then
          case \(HerdrLaunch.quote(stage)) in
            probe) case "$command" in *DISPATCH_PLATFORM*) printf reached > \(HerdrLaunch.quote(reached.path)); printf 'DISPATCH_PLATFORM=Unknown:mips\\n'; exit 0;; esac ;;
            upload)
              case "$command" in
                *'cat >'*) printf reached > \(HerdrLaunch.quote(reached.path)); exit 1 ;;
                *'safe_file dispatch-helper && test -x dispatch-helper'*) exit 1 ;;
              esac ;;
            greeting) case "$command" in *'dispatch-helper --remote --capabilities'*) printf reached > \(HerdrLaunch.quote(reached.path)); printf invalid-greeting; exit 0;; esac ;;
          esac
        fi
        exec /usr/bin/ssh "$@"
        """
        // Force the real bootstrap's cache probe to miss even on a warm VM.
        // Otherwise an already verified helper skips upload and this fixture
        // would exercise a successful connection instead of upload fallback.
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(app.runtime.views[source])
        let arguments = server.options + [server.destination]
        let command = "printf 'FALLBACK_COMMAND_%s\\n' OK; exit 23"
        try await SSHTestServer.authorize(arguments: ["-tt"] + arguments + [command], executable: executable.path)
        try await SSHTestServer.authorize(arguments: arguments, executable: executable.path)
        TerminalTestSupport.send("export DISPATCH_SSH_EXECUTABLE=" + HerdrLaunch.quote(executable.path) +
            "; ssh -tt " + (arguments + [command]).map(HerdrLaunch.quote).joined(separator: " ") +
            "; printf 'FALLBACK_STATUS_%s\\n' \"$?\"", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("FALLBACK_STATUS_23")
        }
        XCTAssertEqual(try String(contentsOf: reached, encoding: .utf8), "reached")
        XCTAssertTrue(TerminalTestSupport.screen(terminal: terminal).contains("FALLBACK_COMMAND_OK"))
        try await app.wait { app.runtime.ssh.machine(for: source) == nil }
        XCTAssertTrue(app.runtime.ssh.links.isEmpty)

        TerminalTestSupport.send("ssh " + arguments.map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        // Count a second diagnostic so the prior explicit-command fallback
        // cannot satisfy readiness for this new interactive shell.
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).components(separatedBy: "Dispatch SSH integration unavailable").count >= 3
        }
        TerminalTestSupport.send("printf 'FALLBACK_SHELL_%s\\n' ALIVE", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("FALLBACK_SHELL_ALIVE") }
        XCTAssertTrue(app.runtime.ssh.links.isEmpty)
        try await app.attach()
        XCTAssertEqual(app.workspace.current?.shows("tmux"), true, "Ordinary tmux control mode still renders when auxiliary setup fails")
        app.workspace.detachSpace(try XCTUnwrap(app.workspace.current?.id))
        try await app.wait { app.workspace.spaces.allSatisfy { !$0.shows("tmux") } }
        app.workspace.selectTab(source)
        try await app.wait { terminal.isPresented && terminal.window === app.window }
        // Space removal is synchronous, while detach-client completes on the
        // control channel. Confirm input reaches the restored SSH shell before
        // asking it to exit.
        TerminalTestSupport.send("printf 'FALLBACK_AFTER_DETACH_%s\\n' READY", to: terminal)
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("FALLBACK_AFTER_DETACH_READY")
        }
        TerminalTestSupport.send("exit", to: terminal)
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: terminal)) { app.runtime.ssh.machine(for: source) == nil }
    }
}
