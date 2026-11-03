import AppKit
import XCTest
@testable import DispatchApp

/// ssh_config features over the loopback test server, typed in a terminal: rules that depend on the command or session
/// type, SendEnv and agent forwarding on the login's, helper and resumed channels, and relative paths across reconnect.
@MainActor
final class SSHConfigurationIntegrationTests: XCTestCase {
    /// A Match on the session type gives Dispatch's login master (an exec session) another port: the helper stays off,
    /// the terminal says why, and plain ssh logs in to the approved server.
    func testMatchOnTheSessionTypeKeepsTheLoginPlainAndSaysWhy() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        let arguments = try configure(server, "dispatch-test-match", before: "Match sessiontype exec\n  Port 1\n")
        try await server.authorize(.init(profile: .statistics), arguments: arguments)
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let terminal = try await origin(app, id: source)
        TerminalTestSupport.send(command(arguments) + "; printf 'LOCAL_EXIT_%s\\n' \"$?\"", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("opening plain SSH.")
        }
        XCTAssertTrue(TerminalTestSupport.screen(terminal: terminal).contains("Dispatch SSH integration unavailable"))
        XCTAssertTrue(TerminalTestSupport.screen(terminal: terminal).contains("(port)"), TerminalTestSupport.screen(terminal: terminal))
        TerminalTestSupport.send("printf 'PLAIN_%s_%s\\n' \"${SSH_CONNECTION##* }\" \"${DISPATCH_SSH_HELPER:-none}\"", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("PLAIN_\(server.port)_none") }
        XCTAssertFalse(app.runtime.ssh.links.values.contains { $0.launch.tabID == source }, "No helper over a connection consent did not cover")
        TerminalTestSupport.send("exit", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("LOCAL_EXIT_0") }
    }

    /// A Match on `sessiontype none` leaves the login alone but would send the reconnect's `-N` master to another port:
    /// the reconnect stops before logging in, saying why.
    func testMatchOnTheSessionTypeStopsAReconnectBeforeItLogsIn() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        let arguments = try configure(server, "dispatch-test-transport", before: "Match sessiontype none\n  Port 1\n")
        try await server.authorize(.init(profile: .statistics), arguments: arguments)
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let terminal = try await origin(app, id: source)
        TerminalTestSupport.send(command(arguments), to: terminal)
        try await connected(app, source: source)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[source]).host
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: source) != nil }
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: source)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: String(describing: app.runtime.hosts.reconnect.state(for: source))) {
            app.runtime.hosts.reconnect.state(for: source)?.error != nil
        }
        let error = try XCTUnwrap(app.runtime.hosts.reconnect.state(for: source)?.error)
        XCTAssertTrue(error.contains("cannot reconnect") && error.contains("port"), error)
        XCTAssertFalse(app.runtime.ssh.links.values.contains { $0.launch.tabID == source })
    }

    func testSendEnvAndRequestedAgentForwardingReachHelperAndResumedChannels() async throws {
        try await checkSessionOptions(forwardAgent: true)
    }

    func testResumedShellForwardsNoAgentTheConnectionDidNotRequest() async throws {
        try await checkSessionOptions(forwardAgent: false)
    }

    /// The login sends `SAMPLE_SENT` (SendEnv, accepted by the server) and, when asked, forwards a disposable agent.
    /// Helper channels over its master carry the same variable and no forwarding of their own; after a reconnect the
    /// shell resumed over the fresh master carries the variable and forwards the agent exactly when the login did.
    private func checkSessionOptions(forwardAgent: Bool) async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics), accepting: ["SAMPLE_SENT"]); defer { server.stop() }
        let agent = try SSHAgentFixture(root: server.root, key: server.root.appendingPathComponent("key")); defer { agent.stop() }
        let arguments = try configure(server, "dispatch-test-session",
                                      after: "  SendEnv SAMPLE_SENT\n" + (forwardAgent ? "  ForwardAgent " + agent.socket + "\n" : ""))
        try await server.authorize(.init(profile: .statistics), arguments: arguments)
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let terminal = try await origin(app, id: source)
        TerminalTestSupport.send("export SAMPLE_SENT=sent-by-sam; " + command(arguments), to: terminal)
        try await connected(app, source: source)
        let first = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == source })
        XCTAssertEqual(first.launch.master.environment.map { Array($0.keys) }, ["SAMPLE_SENT"])
        // A capture journal keeps the names only (values masked), so replay compares values only live.
        if !AppReplay.replaying { XCTAssertEqual(first.launch.master.environment, ["SAMPLE_SENT": "sent-by-sam"]) }

        func session(_ label: String) async throws -> String {
            let terminal = try XCTUnwrap(app.runtime.views[source])
            TerminalTestSupport.send("clear; printf '\(label)_%s\\n' \"$SAMPLE_SENT\"; ssh-add -l; printf '%s_LISTED\\n' \(label)", to: terminal)
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
                TerminalTestSupport.screen(terminal: terminal).contains("\(label)_LISTED")
            }
            return TerminalTestSupport.screen(terminal: terminal)
        }
        func helper(_ link: SSHCoordinator.Link, _ label: String) async throws {
            let channel = try await SSHTestCommand.run(master: link.launch.master, argv: ["/bin/sh", "-c",
                "printf '%s|%s' \"$SAMPLE_SENT\" \"${SSH_AUTH_SOCK:+agent}\""])
            XCTAssertEqual(channel.status, 0)
            XCTAssertEqual(String(decoding: channel.output, as: UTF8.self).split(separator: "|").first.map(String.init), "sent-by-sam", label)
            // The helper Dispatch itself started over a channel of this master (its `connect`) has it too.
            let started = try await SSHTestCommand.run(master: link.launch.master, argv: ["/bin/sh", "-c",
                "for p in $(pgrep -f -- \"connect --session $1\"); do ps -E -ww -o command= -p \"$p\"; done", "sh", link.launch.sessionID])
            XCTAssertTrue(String(decoding: started.output, as: UTF8.self).contains("SAMPLE_SENT=sent-by-sam"),
                          label + ": " + String(decoding: started.output, as: UTF8.self))
        }

        let original = try await session("ORIGINAL")
        XCTAssertTrue(original.contains("ORIGINAL_sent-by-sam"), original)
        XCTAssertEqual(original.contains(agent.fingerprint), forwardAgent, original)
        try await helper(first, "login's master")

        let host = try XCTUnwrap(app.workspace.hosts.terminals[source]).host
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: source) != nil }
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: source)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: String(describing: app.runtime.hosts.reconnect.state(for: source))) {
            app.runtime.hosts.reconnect.state(for: source) == nil && app.runtime.views[source]?.inputParked == false
                && app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.launch.connectionID != first.launch.connectionID && $0.shellPID != nil }
        }
        let second = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == source && $0.launch.connectionID != first.launch.connectionID })
        XCTAssertEqual(second.launch.master.environment.map { Array($0.keys) }, ["SAMPLE_SENT"], "The fresh master's channels send what the login sent")
        if !AppReplay.replaying { XCTAssertEqual(second.launch.master.environment, ["SAMPLE_SENT": "sent-by-sam"]) }
        let resumed = try await session("RESUMED")
        XCTAssertTrue(resumed.contains("RESUMED_sent-by-sam"), resumed)
        XCTAssertEqual(resumed.contains(agent.fingerprint), forwardAgent, "The resumed shell forwards the agent exactly when the login did: " + resumed)
        try await helper(second, "reconnect's master")
    }

    /// `cd folder; ssh -F ./config host`, with the configuration's identity and known hosts relative too: the reconnect's
    /// configuration check and login run from that folder, and so does an automatic reconnect's silent login.
    func testRelativeConfigurationReconnectsFromTheFolderSSHWasTypedIn() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .statistics)); defer { server.stop() }
        let folder = server.root.appendingPathComponent("relative")
        _ = try TestSupport.fixture("ssh.relative.folder", input: folder.path) { () -> Bool in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return true
        }
        try System.write(Data("""
            Host dispatch-test-relative
              HostName 127.0.0.1
              Port \(server.port)
              User \(System.machine.name)
              IdentityFile ../key
              UserKnownHostsFile ../known_hosts
              StrictHostKeyChecking yes
              IdentitiesOnly yes
              BatchMode yes
              LogLevel ERROR

            """.utf8), to: folder.appendingPathComponent("config"))
        let arguments = ["-F", "./config", "dispatch-test-relative"]
        try await server.authorize(.init(profile: .statistics), arguments: arguments, directory: folder.path)
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        let terminal = try await origin(app, id: source)
        TerminalTestSupport.send("cd " + HerdrLaunch.quote(folder.path) + " && " + command(arguments), to: terminal)
        try await connected(app, source: source)
        let first = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == source })
        XCTAssertTrue(first.launch.shell.directory?.hasSuffix("/relative") == true, first.launch.shell.directory ?? "no folder")

        let host = try XCTUnwrap(app.workspace.hosts.terminals[source]).host
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: source) != nil }
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: source)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: String(describing: app.runtime.hosts.reconnect.state(for: source))) {
            app.runtime.hosts.reconnect.state(for: source) == nil && app.runtime.views[source]?.inputParked == false
        }
        let recovered = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("printf 'RELATIVE_%s\\n' RECOVERED", to: recovered)
        try await app.wait { TerminalTestSupport.screen(terminal: recovered).contains("RELATIVE_RECOVERED") }

        // A new tab on that host clones the connection from the same folder (DISPATCH_SSH_DIRECTORY).
        app.workspace.selectTab(source)
        app.workspace.newTab()
        let clone = try XCTUnwrap(app.workspace.activeSurfaceID)
        XCTAssertNotEqual(clone, source)
        try await connected(app, source: clone)
        let cloned = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == clone })
        XCTAssertEqual(cloned.launch.shell.directory, first.launch.shell.directory)

        let master = SSHMaster(executable: first.launch.shell.executable, controlPath: server.root.appendingPathComponent("silent").path,
                               destination: first.launch.shell.destination)
        try await SSHReconnectLogin.authenticateSilently(shell: first.launch.shell, master: master)
        await master.exit().value
    }

    // MARK: - Fixture

    /// A configuration for `name` on `server` in its root, with `before` ahead of the host's block (a Match there wins:
    /// OpenSSH keeps the first value) and `after` inside it. Returns the ssh arguments.
    private func configure(_ server: SSHTestServer, _ name: String, before: String = "", after: String = "") throws -> [String] {
        let configuration = server.root.appendingPathComponent(name + ".config")
        try System.write(Data((before + """
            Host \(name)
              HostName 127.0.0.1
              Port \(server.port)
              User \(System.machine.name)
              IdentityFile \(server.root.appendingPathComponent("key").path)
              UserKnownHostsFile \(server.root.appendingPathComponent("known_hosts").path)
              StrictHostKeyChecking yes
              IdentitiesOnly yes
              BatchMode yes
              LogLevel ERROR

            """ + after).utf8), to: configuration)
        return ["-F", configuration.path, name]
    }
    private func command(_ arguments: [String]) -> String { "ssh " + arguments.map(HerdrLaunch.quote).joined(separator: " ") }
    private func origin(_ app: TmuxWalkthrough, id: UUID) async throws -> TerminalView {
        try await app.wait { app.runtime.views[id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        return try XCTUnwrap(app.runtime.views[id])
    }
    private func connected(_ app: TmuxWalkthrough, source: UUID) async throws {
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: app.runtime.views[source].map { TerminalTestSupport.screen(terminal: $0) } ?? "") {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
    }
}

/// A disposable ssh-agent holding the test server's key, at a socket in the server's root.
@MainActor
private final class SSHAgentFixture {
    let socket: String
    /// The key's SHA256 fingerprint, as `ssh-add -l` lists it.
    let fingerprint: String
    private let process = Process()

    init(root: URL, key: URL) throws {
        let socket = root.appendingPathComponent("agent.sock").path, process = self.process
        self.socket = socket
        fingerprint = try TestSupport.fixture("ssh.agent.start", input: [socket, key.path]) { () -> String in
            func run(_ path: String, _ arguments: [String]) throws -> String {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: path); child.arguments = arguments
                child.environment = ["SSH_AUTH_SOCK": socket, "PATH": "/usr/bin:/bin"]
                child.standardInput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                let exit = try TestSupport.live(child)
                guard exit.status == 0 else { throw HerdrFailure(path + " failed with \(exit.status)") }
                return String(decoding: exit.output, as: UTF8.self)
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
            process.arguments = ["-D", "-a", socket]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try TestSupport.start(process)
            for _ in 0..<500 where !FileManager.default.fileExists(atPath: socket) { usleep(10_000) }
            _ = try run("/usr/bin/ssh-add", [key.path])
            let listed = try run("/usr/bin/ssh-keygen", ["-l", "-f", key.path + ".pub"])
            guard let fingerprint = listed.split(separator: " ").dropFirst().first else { throw HerdrFailure("No fingerprint: " + listed) }
            return String(fingerprint)
        }
    }

    func stop() {
        _ = try? TestSupport.fixture("ssh.agent.stop", input: socket) { () -> Bool in
            if process.isRunning { process.terminate(); process.wait() }
            try? FileManager.default.removeItem(atPath: socket)
            return true
        }
    }
}
