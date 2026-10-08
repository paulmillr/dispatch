import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class SSHSubmissionIntegrationTests: XCTestCase {
    func testPlainExitAfterPastePreservesDraftAndDoesNotSendReturnToShell() async throws { try await exitAfterPaste("plain") }
    func testTmuxExitAfterPastePreservesDraftAndDoesNotSendReturnToShell() async throws { try await exitAfterPaste("tmux") }
    func testTmuxExitCommandRechecksOwnershipBeforeReturn() async throws { try await exitAfterPaste("tmux", draft: "/exit") }
    func testTmuxQuitCommandRechecksOwnershipBeforeReturn() async throws { try await exitAfterPaste("tmux", draft: "/quit") }
    func testHerdrExitAfterPastePreservesDraftAndDoesNotSendReturnToShell() async throws { try await exitAfterPaste("herdr") }
    func testLocalHerdrExitAfterPastePreservesDraftAndDoesNotSendReturnToShell() async throws { try await exitAfterPaste("local-herdr") }

    private func exitAfterPaste(_ backend: String, draft: String = "DO_NOT_RUN_THIS_IN_A_SHELL\nsecond line · λ") async throws {
        let server = try await SSHTestServer(); defer { server.stop() }
        let binary = server.root.appendingPathComponent("codex")
        let state = server.root.appendingPathComponent("exit-boundary")
        let compiled = try await SSHCommand.run(executable: "/usr/bin/xcrun", arguments: ["clang", "-Wall", "-Wextra", "-Werror",
            CodexTestSupport.root.appendingPathComponent("scripts/fixtures/exit-after-paste.c").path, "-o", binary.path])
        XCTAssertEqual(compiled.status, 0, String(decoding: compiled.output, as: UTF8.self))
        let runtime = TerminalRuntime.shared, previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previousChat }
        let app = try TmuxWalkthrough(autoClose: false); defer { app.close() }
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { _ = try? HerdrSocket(path: socket).request("server.stop") }
        let origin = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { runtime.views[origin].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let original = try XCTUnwrap(runtime.views[origin])
        let remote = backend != "local-herdr"
        if remote {
            TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: original)
            try await TestSupport.eventually(timeout: .seconds(20)) {
                runtime.ssh.links.values.contains { $0.launch.tabID == origin && $0.shellPID != nil }
            }
        }
        if backend == "tmux" {
            TerminalTestSupport.send("\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge", to: original)
            try await app.wait { app.workspace.current?.structured == true }
        } else if backend == "herdr" || backend == "local-herdr" {
            TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path) +
                "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: original)
            try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        }
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id])
        let command = ["/usr/bin/python3", CodexTestSupport.root.appendingPathComponent("scripts/submission_fixture.py").path,
                       "--binary", binary.path, "--state", state.path].map(HerdrLaunch.quote).joined(separator: " ")
        TerminalTestSupport.send(command, to: terminal)
        let session = runtime.chat.session(for: id)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "\(session.status ?? "No submission fixture")\n\(TerminalTestSupport.screen(terminal: terminal))") {
            session.active && (remote ? session.remoteAgent != nil : session.process != nil) &&
                TerminalTestSupport.screen(terminal: terminal).contains("DISPATCH_EXIT_FIXTURE_READY")
        }
        let identity = session.remoteAgent
        XCTAssertEqual(session.version, "99.0.0-test", "An unfamiliar version must attach through the verified transport")
        runtime.chat.chooseChat(true, session: session)
        session.draft = draft
        runtime.chat.submit(session)
        if AgentInput.isCommand(draft) {
            XCTAssertEqual(session.draft, draft, "Commands retain their draft until delivery succeeds")
        } else {
            XCTAssertTrue(session.draft.isEmpty, "The pending bubble owns the submitted draft during delivery")
        }
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "\(session.status ?? "No boundary result")\n\(TerminalTestSupport.screen(terminal: terminal))") {
            FileManager.default.fileExists(atPath: state.appendingPathComponent("shell.bin").path)
        }
        try await TestSupport.eventually { session.submissionID == nil && !session.busy }
        XCTAssertEqual(try String(contentsOf: state.appendingPathComponent("exit-status"), encoding: .utf8), "0")
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("paste.bin")), Data(("\u{1b}[200~" + draft + "\u{1b}[201~").utf8),
                       "The verified live agent received the complete paste before it exited")
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("shell.bin")), Data(),
                       "Neither Return nor a retried paste may reach the resumed shell")
        XCTAssertEqual(session.draft, draft, "An incomplete checked submission must retain the draft")
        XCTAssertFalse(session.active)
        if remote { XCTAssertEqual(session.remoteAgent?.key, try XCTUnwrap(identity).key) }
    }
}
