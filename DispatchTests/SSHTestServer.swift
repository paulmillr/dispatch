import Foundation
import Darwin
import XCTest
@testable import DispatchApp

struct SSHLinuxTestProfile: Decodable {
    /// Profiles the running case loaded: its remote helper captures are collected from those hosts.
    nonisolated(unsafe) static var used: Set<URL> = []

    static func configurationURL(hostOnly: Bool = false) -> URL {
        let name = hostOnly ? "host-linux-ssh.json" : "linux-ssh.json"
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/" + name)
        let url = FileManager.default.fileExists(atPath: local.path) ? local : URL(fileURLWithPath: "/Users/admin/dispatch-tests/" + name)
        used.insert(url)
        return url
    }

    let destination: String
    let options: [String]
    let claude: String?
    let codex: String?
    let pi: String?
    let supportedTmux: String?
    let distribution: String?
    let label: String?
    /// herdr on the Linux host (a user install such as ~/.local/bin/herdr is outside the fixture's PATH).
    /// The shell runs the helper's `herdr` function, and the helper finds the real one on PATH. The link
    /// and the file it resolves to are both named herdr: the helper only trusts a server executable named herdr.
    let herdr: String?
    var codexPath: String { codex ?? "/usr/local/bin/codex" }
    /// The fixture shell's PATH: herdr's directory first when configured.
    var path: String { (herdr.map { ($0 as NSString).deletingLastPathComponent + ":" } ?? "") + "/usr/local/bin:/usr/bin:/bin" }
    var supportedTmuxPath: String { supportedTmux ?? "/opt/dispatch-test-tools/tmux/bin/tmux" }
}

/// A private loopback SSH daemon with disposable keys.
@MainActor
final class SSHTestServer {
    let root: URL
    let port: UInt16
    let daemon: Process
    let options: [String]
    let destination = NSUserName() + "@127.0.0.1"
    /// Where agents of this server's sessions keep their configuration (and the remote helper installs its
    /// integrations): inside the server's root, never the account's own (as the local helper's test home).
    var agents: URL { root.appendingPathComponent("agents") }
    private let transportOnly: Bool
    /// Started through sudo only when DISPATCH_UNPRIVILEGED_SSHD=0 (the VM runner).
    /// test/xcode.py defaults to 1: a user-owned sshd and a Debug helper that accepts it.
    private let privileged: Bool
    private static var permissionsByRoot: [String: Set<SSHIntegrationScope>] = [:]

    init(grant: SSHIntegrationGrant = .init(profile: .full, hooks: true), transportOnly: Bool = false) async throws {
        self.transportOnly = transportOnly
        privileged = !transportOnly && ProcessInfo.processInfo.environment["DISPATCH_UNPRIVILEGED_SSHD"] != "1"
        struct Created: Codable { let root: URL; let port: UInt16; let options: [String] }
        let daemon = Process()
        self.daemon = daemon
        let privileged = self.privileged
        // Loopback sessions and retained local servers share this run's private helper
        // registry. Never make test hook senders fall back to the real account registry.
        let environment = ["DISPATCH_TEST_ROOT"].compactMap { name in
            ProcessInfo.processInfo.environment[name].map { name + "=" + $0 }
        }
        let created = try JSONDecoder().decode(Created.self, from: await AppReplay.run(kind: "fixture.ssh.start",
            input: JSONEncoder().encode(["privileged": String(privileged), "tools": TestSupport.tools, "environment": environment.joined(separator: "\n")])) {
            let root = URL(fileURLWithPath: "/tmp/hs-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let key = root.appendingPathComponent("key").path
            let generated = try await SSHCommand.run(executable: "/usr/bin/ssh-keygen", arguments: ["-q", "-t", "ed25519", "-N", "", "-f", key])
            guard generated.status == 0 else { throw HerdrFailure("Could not generate test SSH keys.") }
            let port = try Self.availablePort()
            let config = root.appendingPathComponent("sshd_config")
            let path = "PATH=" + TestSupport.tools + ":/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            let homes = [("CODEX_HOME", "codex"), ("CLAUDE_CONFIG_DIR", "claude"), ("PI_CODING_AGENT_DIR", "pi")].map { name, directory in
                name + "=" + root.appendingPathComponent("agents/" + directory).path
            }
            for directory in ["codex", "claude", "pi"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("agents/" + directory), withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
            }
            try """
            ListenAddress 127.0.0.1
            Port \(port)
            HostKey \(key)
            AuthorizedKeysFile \(key).pub
            PidFile \(root.path)/pid
            StrictModes no
            UsePAM no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            PubkeyAuthentication yes
            SetEnv \(([path] + homes + environment).map(HerdrLaunch.quote).joined(separator: " "))
            LogLevel ERROR
            """.write(to: config, atomically: true, encoding: .utf8)
            let knownHosts = root.appendingPathComponent("known_hosts")
            let publicKey = try String(contentsOfFile: key + ".pub", encoding: .utf8)
            try ("[127.0.0.1]:\(port) " + publicKey).write(to: knownHosts, atomically: true, encoding: .utf8)
            let options = ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(knownHosts.path)",
                       "-o", "LogLevel=ERROR", "-o", "IdentitiesOnly=yes", "-i", key, "-p", String(port)]
            // Production requires an SSH session backed by a privileged monitor.
            // The dedicated test VM provides sudo; no authentication bypass is
            // compiled into the app's packaged helper for this fixture.
            // Raw SSH/tmux transport tests need no privileged helper integration
            // and can run as the current user on a physical developer Mac.
            daemon.executableURL = URL(fileURLWithPath: privileged ? "/usr/bin/sudo" : "/usr/sbin/sshd")
            daemon.arguments = (privileged ? ["-n", "/usr/sbin/sshd"] : []) + ["-D", "-e", "-f", config.path]
            daemon.standardInput = FileHandle.nullDevice; daemon.standardOutput = FileHandle.nullDevice; daemon.standardError = FileHandle.nullDevice
            try daemon.run()
            return try JSONEncoder().encode(Created(root: root, port: port, options: options))
        })
        self.root = created.root
        self.port = created.port
        self.options = created.options
        let root = created.root
        Self.permissionsByRoot[root.path] = []
        do {
            _ = try await AppReplay.run(kind: "fixture.ssh.ready", input: JSONEncoder().encode(root)) {
                try await TestSupport.eventually(diagnostic: "Test SSH server unavailable; DISPATCH_UNPRIVILEGED_SSHD=0 requires passwordless sudo") {
                    Self.acceptingConnections(port: self.port)
                }
                return Data()
            }
            if !transportOnly { try await authorize(grant) }
        }
        catch { stop(); throw error }
    }

    /// Test permission is explicit and bound to this daemon's complete resolved
    /// configuration, including its ephemeral key/known-hosts files and port.
    /// Production's ordinary-SSH default and consent presenter remain untouched.
    @discardableResult
    func authorize(_ grant: SSHIntegrationGrant = .init(profile: .full, hooks: true),
                   arguments: [String]? = nil) async throws -> SSHIntegrationScope {
        try await Self.authorize(arguments: arguments ?? options + [destination], grant: grant)
    }

    @discardableResult
    static func authorize(arguments: [String], executable: String = "/usr/bin/ssh",
                          grant: SSHIntegrationGrant = .init(profile: .full, hooks: true)) async throws -> SSHIntegrationScope {
        let invocation = try XCTUnwrap(SSHInvocation.parse(arguments, isTerminal: true), "The test must use an enhanced SSH invocation")
        let result = try await SSHCommand.run(executable: executable,
            arguments: ["-G", "-o", "ClearAllForwardings=no"] + invocation.options + ["--", invocation.destination] + (invocation.command.map { [$0] } ?? []))
        XCTAssertEqual(result.status, 0)
        let configuration = String(decoding: result.output, as: UTF8.self)
        let scope = try XCTUnwrap(SSHIntegrationScope(executable: executable, destination: invocation.destination, configuration: configuration))
        // Static authorization is also used for aliases and altered options.
        // Track only configurations referring to a live fixture's private files.
        for root in Array(permissionsByRoot.keys) where configuration.contains(root + "/") {
            permissionsByRoot[root, default: []].insert(scope)
        }
        TerminalRuntime.shared.ssh.permissions.save(grant, for: scope)
        // These fixtures preauthorize integration. Agent setup has its own
        // remembered decisions now; consent tests exercise the actual prompts.
        if grant.hooks {
            for agent in SSHHookAgent.allCases { TerminalRuntime.shared.ssh.permissions.saveHooks(true, for: scope, agent: agent) }
        }
        return scope
    }

    func stop(herdr: String? = nil) {
        defer {
            for scope in Self.permissionsByRoot.removeValue(forKey: root.path) ?? [] {
                TerminalRuntime.shared.ssh.permissions.reset(scope)
            }
        }
        do {
            if let herdr {
                _ = try TestSupport.fixture("herdr.stop", input: herdr) {
                    if let api = try? HerdrSocket(path: herdr) { try? api.request("server.stop") }
                    return true
                }
            }
            _ = try AppReplay.query(kind: "fixture.ssh.stop", input: JSONEncoder().encode(root)) {
                if daemon.isRunning {
                    if !privileged {
                        daemon.terminate()
                        daemon.waitUntilExit()
                        try? FileManager.default.removeItem(at: root)
                        return Data()
                    }
                    // Signal only the sudo/sshd process this fixture created. Sudo
                    // forwards termination to its owned daemon and waits for it.
                    let stop = Process(); stop.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                    stop.arguments = ["-n", "/bin/kill", "-TERM", String(daemon.processIdentifier)]
                    stop.standardOutput = FileHandle.nullDevice; stop.standardError = FileHandle.nullDevice
                    try stop.run(); stop.waitUntilExit()
                    guard stop.terminationStatus == 0 || !daemon.isRunning else { throw HerdrFailure("Cannot stop test SSH daemon") }
                }
                daemon.waitUntilExit()
                try? FileManager.default.removeItem(at: root)
                return Data()
            }
        } catch { AppReplay.fail(error); XCTFail("Cannot stop test SSH daemon: " + error.localizedDescription) }
    }

    private static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                guard Darwin.bind(fd, address, length) == 0, getsockname(fd, address, &length) == 0 else { throw POSIXError(.EIO) }
                return UInt16(bigEndian: pointer.pointee.sin_port)
            }
        }
    }

    private static func acceptingConnections(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }; defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = port.bigEndian
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

/// The app's helper4 bundle as the SSH bootstrap uploads it (resources/helper4/<platform> plus its
/// protocol-version), copied for fixtures that alter the cache or count uploads.
enum SSHHelperTestResources {
    static func prepare(under directory: URL) throws -> URL {
        let source = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("helper4")
        let resources = directory.appendingPathComponent("helper-resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: source, to: resources.appendingPathComponent("helper4"))
        return resources
    }
}
