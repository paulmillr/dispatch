import AppKit
import CryptoKit
import XCTest
@testable import DispatchApp

@MainActor
final class SSHHostIsolationIntegrationTests: XCTestCase {
    func testDistinctAuthenticatedHostsIsolateCollidingHerdrAndCodexIdentities() async throws {
        let profile = try JSONDecoder().decode(SSHLinuxTestProfile.self, from: Data(contentsOf:
            SSHLinuxTestProfile.configurationURL()))
        let root = URL(fileURLWithPath: "/private/tmp/hhi-" + UUID().uuidString.prefix(8)), state = root.appendingPathComponent("state")
        let fixture = try CodexEndpointFixture(prefix: "unused", delay: 0.01, hooks: false, state: state)
        var passed = false
        defer {
            fixture.stop(removeState: passed)
            if passed { try? FileManager.default.removeItem(at: root) }
        }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        try await TestSupport.integrations(["codex"], enabled: true, chat: runtime.chat)
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let sshd = try await SSHTestServer(); defer { sshd.stop() }
        let socket = root.appendingPathComponent("herdr.sock").path
        defer { if let api = try? HerdrSocket(path: socket) { try? api.request("server.stop") } }

        func connect(_ destination: String, options: [String]) async throws -> SSHCoordinator.Link {
            app.workspace.newLocalSpace()
            let id = try XCTUnwrap(app.workspace.activeTab?.id)
            try await app.wait { runtime.views[id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
            let terminal = try XCTUnwrap(runtime.views[id])
            try await SSHTestServer.authorize(arguments: options + [destination])
            TerminalTestSupport.send("ssh " + (options + [destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
            try await TestSupport.eventually(timeout: .seconds(25), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
                runtime.ssh.links.values.contains { $0.launch.tabID == id && $0.shellPID != nil }
            }
            return try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == id })
        }
        func attach(_ connection: SSHCoordinator.Link) async throws -> (TerminalView, ChatSession, Space) {
            let origin = try XCTUnwrap(runtime.views[connection.launch.tabID])
            TerminalTestSupport.send("export PATH=\(TestSupport.path):\(HerdrLaunch.quote(profile.path)); export XDG_CONFIG_HOME=" + HerdrLaunch.quote(root.path) +
                "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: origin)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: origin)) {
                app.workspace.current?.shows("herdr") == true && app.workspace.current?.remote == connection.launch.connectionID
            }
            let id = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await app.wait { runtime.views[id]?.surface != nil }
            return (try XCTUnwrap(runtime.views[id]), runtime.chat.session(for: id), try XCTUnwrap(app.workspace.current))
        }
        let mac = try await connect(sshd.destination, options: sshd.options)
        let (macTerminal, macSession, macSpace) = try await attach(mac)
        let command = CodexTestSupport.command(state: state, binary: fixture.binary)
        TerminalTestSupport.send(command, to: macTerminal)
        try await SSHChatTestSupport.trustHooks(state: state, command: command, session: macSession, terminal: macTerminal)
        runtime.chat.chooseChat(true, session: macSession)
        macSession.draft = "common seed on both hosts"
        runtime.chat.submit(macSession)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: macSession.status ?? "No seed conversation") {
            !macSession.busy && macSession.sessionID != nil && macSession.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: common seed on both hosts" }
        }
        let conversation = try XCTUnwrap(macSession.sessionID), transcript = try XCTUnwrap(macSession.transcriptPath)
        runtime.chat.chooseChat(false, session: macSession)
        try await SSHChatTestSupport.sendToAgent("/quit", terminal: macTerminal)
        try await TestSupport.eventually { !macSession.active }

        let linux = try await connect(profile.destination, options: profile.options)
        XCTAssertNotEqual(mac.greeting.hostID, linux.greeting.hostID, "The identities must come from genuinely different authenticated hosts")
        XCTAssertNotEqual(mac.greeting.boot, linux.greeting.boot)
        @discardableResult func remote(_ argv: [String], input: Data = Data()) async throws -> Data {
            do {
                let result = try await SSHTestCommand.run(master: linux.launch.master, argv: argv, input: input)
                guard result.status == 0 else {
                    throw HerdrFailure("Remote fixture command \(argv) exited \(result.status): " + String(decoding: result.output, as: UTF8.self))
                }
                return result.output
            } catch {
                print("Host isolation remote command \(argv), input bytes \(input.count): \(String(reflecting: type(of: error))) \(String(reflecting: error))")
                throw error
            }
        }
        var remoteFixture: SSHTestDaemon?, linuxAttached = false
        func cleanup() async {
            if linuxAttached {
                do { try await SSHTestCommand.stopHerdr(master: linux.launch.master, socket: socket) }
                catch { XCTFail("Cannot stop the Linux herdr fixture: " + error.localizedDescription) }
            }
            await remoteFixture?.stop()
            if passed { _ = try? await remote(["/bin/rm", "-rf", "--", root.path]) }
            else { print("Host isolation Linux fixture retained at " + root.path) }
        }
        var stage = "probe Linux platform"
        do {
            let platform = try await remote(["/usr/bin/uname", "-s"])
            XCTAssertEqual(String(decoding: platform, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "Linux")
            // Match macOS's canonical temporary path, not its /tmp symlink.
            // The private VM permits creating this empty fixture parent.
            try await remote(["/bin/sh", "-c", "if [ ! -d /private/tmp ]; then sudo -n mkdir -p /private/tmp && sudo -n chmod 1777 /private/tmp; fi"])
            try await remote(["/bin/mkdir", "-p", state.path])
            stage = "archive macOS seed conversation"
            let archive = root.appendingPathComponent("seed.tar")
            let packed = try await SSHCommand.run(executable: "/usr/bin/tar", arguments: ["-cf", archive.path, "-C", state.path, "."])
            XCTAssertEqual(packed.status, 0)
            stage = "copy seed conversation to Linux"
            try await remote(["/bin/tar", "-xf", "-", "-C", state.path], input: Data(contentsOf: archive))
            stage = "copy and start Linux model fixture"
            let script = root.appendingPathComponent("codex_fixture.py").path
            for name in CodexTestSupport.scripts {
                try await remote(["/usr/bin/tee", root.appendingPathComponent(name).path],
                    input: Data(contentsOf: CodexTestSupport.root.appendingPathComponent("scripts/" + name)))
            }
            let daemon = try SSHTestDaemon(master: linux.launch.master,
                argv: ["/usr/bin/python3", script, "serve", "--state", state.path, "--delay", "0.01", "--no-hooks"], pidFile: root.appendingPathComponent("model.pid").path)
            remoteFixture = daemon
            try await daemon.waitUntilReady()
            stage = "attach Linux herdr and resume colliding conversation"
            let (linuxTerminal, linuxSession, linuxSpace) = try await attach(linux)
            linuxAttached = true
            // Both servers use the same socket path and colliding ids; each space belongs to its own host's helper.
            XCTAssertNotEqual(linuxSpace.remote, macSpace.remote)
            XCTAssertNotEqual(linuxSpace.id, macSpace.id)
            let linuxTab = try XCTUnwrap(app.workspace.activeTab), macTab = try XCTUnwrap(app.workspace.spaces.flatMap(\.tabs).first { $0.surfaceIDs.contains(macSession.id) })
            XCTAssertEqual(app.workspace.windowKey(of: linuxTab), app.workspace.windowKey(of: macTab), "The fresh servers deliberately use colliding tab IDs")
            XCTAssertNotEqual(linuxTab.surfaceIDs, macTab.surfaceIDs)
            let linuxCommand = ["python3", script, "launch", "--state", state.path, "--codex", profile.codexPath, "--resume", conversation].map(HerdrLaunch.quote).joined(separator: " ")
            TerminalTestSupport.send(linuxCommand, to: linuxTerminal)
            try await SSHChatTestSupport.trustHooks(state: state, command: linuxCommand, session: linuxSession, terminal: linuxTerminal) { path in
                String(decoding: try await remote(["/bin/cat", path]), as: UTF8.self)
            }
            app.workspace.selectSurface(macSession.id)
            let resumed = CodexTestSupport.command(state: state, binary: fixture.binary, resume: conversation)
            TerminalTestSupport.send(resumed, to: macTerminal)
            try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "mac=\(macSession.status ?? "nil") linux=\(linuxSession.status ?? "nil")") {
                macSession.active && linuxSession.active && macSession.sessionID == conversation && linuxSession.sessionID == conversation &&
                    !macSession.loadingHistory && !linuxSession.loadingHistory && !macSession.busy && !linuxSession.busy
            }
            XCTAssertEqual(macSession.transcriptPath, transcript)
            XCTAssertEqual(linuxSession.transcriptPath, transcript, "Identical paths must still resolve through each host's connection")
            XCTAssertNotEqual(macSession.remoteAgent?.key, linuxSession.remoteAgent?.key)
            stage = "verify independent histories and source previews"
            let macMarker = "MAC_ONLY_" + UUID().uuidString, linuxMarker = "LINUX_ONLY_" + UUID().uuidString
            for (session, prompt) in [(macSession, macMarker), (linuxSession, linuxMarker)] {
                app.workspace.selectSurface(session.id); runtime.chat.chooseChat(true, session: session)
                session.draft = prompt; runtime.chat.submit(session)
                try await TestSupport.eventually(timeout: .seconds(20), diagnostic: session.status ?? "No isolated reply") {
                    !session.busy && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: " + prompt }
                }
            }
            XCTAssertFalse(macSession.turns.flatMap(\.items).contains { $0.text.contains(linuxMarker) })
            XCTAssertFalse(linuxSession.turns.flatMap(\.items).contains { $0.text.contains(macMarker) })
            let macHelper = try XCTUnwrap(macSession.helper), linuxHelper = try XCTUnwrap(linuxSession.helper)
            let source = state.appendingPathComponent("work/collision.txt")
            try macMarker.write(to: source, atomically: true, encoding: .utf8)
            try await remote(["/usr/bin/tee", source.path], input: Data(linuxMarker.utf8))
            let preview = ToolDocument(path: "collision.txt", diff: ""), directory = source.deletingLastPathComponent().path
            let localPreview = try await preview.source(in: directory, endpoint: macHelper.endpoint)
            let remotePreview = try await preview.source(in: directory, endpoint: linuxHelper.endpoint)
            XCTAssertEqual(localPreview, macMarker); XCTAssertEqual(remotePreview, linuxMarker)
            // Cross-host input has no address: each chat is a terminal of its own host's helper connection.
            XCTAssertNotEqual(macHelper.endpoint, linuxHelper.endpoint)

            stage = "verify independent hook decisions"
            for session in [macSession, linuxSession] {
                app.workspace.selectSurface(session.id)
                session.draft = "same approval on both hosts"; runtime.chat.submit(session)
                try await TestSupport.eventually(timeout: .seconds(20), diagnostic: session.status ?? "No isolated hook") { session.approvals.contains(where: \.pending) }
            }
            let macApproval = try XCTUnwrap(macSession.approvals.first(where: \.pending)), linuxApproval = try XCTUnwrap(linuxSession.approvals.first(where: \.pending))
            XCTAssertEqual(macApproval.operation, linuxApproval.operation)
            macApproval.resolve(.allow)
            try await TestSupport.eventually(timeout: .seconds(20)) {
                !macSession.busy && macSession.turns.flatMap(\.items).contains { $0.kind == .tool && $0.output.contains("DISPATCH_LOCAL_TOOL_OK") }
            }
            XCTAssertTrue(linuxApproval.pending, "Granting the same tool on one host must not resolve the other host's hook")
            XCTAssertFalse(linuxSession.turns.flatMap(\.items).contains { $0.kind == .tool && $0.output.contains("DISPATCH_LOCAL_TOOL_OK") })
            linuxApproval.resolve(.deny)
            try await TestSupport.eventually(timeout: .seconds(20)) { !linuxSession.busy && !linuxApproval.pending }
            XCTAssertFalse(linuxSession.turns.flatMap(\.items).contains { $0.kind == .tool && $0.output.contains("DISPATCH_LOCAL_TOOL_OK") })
            _ = try await PresentationTestSupport.capture(app.window, named: "two-host-collisions", in: "ssh-recovery-validation")
            passed = testRun?.failureCount == 0
            await cleanup()
        } catch {
            print("Host isolation failed during \(stage): \(String(reflecting: type(of: error))) \(String(reflecting: error))")
            await cleanup(); throw error
        }
    }
}
