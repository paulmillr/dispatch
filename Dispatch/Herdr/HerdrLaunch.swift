import Foundation
import Darwin

/// A private per-app mailbox also contains the shell command shim. Requests are
/// atomic files, authenticated by a per-terminal capability, and consumed once.
@MainActor
final class HerdrLaunch {
    private(set) var directory = URL(fileURLWithPath: "/tmp/dispatch-herdr-\(UUID().uuidString)")
    private var activeDirectory: URL?
    private var retirements: [URL: Task<Void, Never>] = [:]
    private var tokens: [UUID: String] = [:]
    private var timer: Timer?
    /// Commands wrapped in this app's terminals: ssh plus the helper's listed programs (see install(_:)).
    private(set) var functions: [ShellCommandWrapper] = [.ssh, .helper(program: "herdr", key: "herdr")]
    private var shims: [ShellCommandWrapper] { functions }
    /// The programs behind the wrappers' variables; the helper's only where its launches are wrapped.
    private var executables: [String: String] {
        var programs = ["DISPATCH_EXECUTABLE": Bundle.main.executablePath ?? ""]
        programs["DISPATCH_HELPER_EXECUTABLE"] = HelperApp.executable?.path ?? ""
        return programs
    }
    var sshHandler: ((SSHLaunchRequest) -> Void)?
    var sshConnecting: ((SSHLaunchRequest) -> Void)?
    var sshConsent: ((SSHConsentRequest, URL) -> Void)?
    var sshClosed: ((SSHConnectionID, SSHCloseNotice) -> Void)?

    func start() throws {
        stop()
        let data = try AppReplay.query(kind: "launch.start", input: Data()) {
            directory = URL(fileURLWithPath: "/tmp/dispatch-herdr-\(UUID().uuidString)")
            let directory = directory
            activeDirectory = directory
            var ready = false
            defer { if !ready { stop() } }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let bin = directory.appendingPathComponent("bin")
            try fm.createDirectory(at: bin, withIntermediateDirectories: false)
            try install(functions)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.activeDirectory?.path == directory.path else { return }
                    self?.consume()
                }
            }
            ready = true
            return try JSONEncoder().encode(directory.path)
        }
        directory = URL(fileURLWithPath: try JSONDecoder().decode(String.self, from: data))
        activeDirectory = directory
    }

    func environment(for id: UUID) -> [String: String] {
        do {
            let identity = try AppReplay.identity(kind: "terminal", value: id)
            let token = try tokens[id] ?? JSONDecoder().decode(String.self, from: AppReplay.query(kind: "launch.token", input: JSONEncoder().encode(identity)) {
                try JSONEncoder().encode(UUID().uuidString)
            })
            tokens[id] = token
            var environment = ["DISPATCH_HERDR_DIRECTORY": directory.path, "DISPATCH_HERDR_TAB": identity.uuidString,
                    "DISPATCH_HERDR_TOKEN": token,
                    "PATH": directory.appendingPathComponent("bin").path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/opt/homebrew/bin")]
            environment.merge(executables, uniquingKeysWith: { _, new in new })
            environment.merge(NativeSSHEnvironment.bashFunctions(inheriting: ProcessInfo.processInfo.environment, functions: functions), uniquingKeysWith: { _, new in new })
            return environment
        } catch { AppReplay.fail(error); return [:] }
    }
    func close(_ id: UUID) { tokens[id] = nil }

    /// Writes the PATH shims and native shell functions for ssh plus these programs.
    func install(_ programs: [ShellCommandWrapper]) throws {
        functions = [.ssh, .helper(program: "herdr", key: "herdr")] + programs.filter { $0 != .ssh && $0 != .helper(program: "herdr", key: "herdr") }
        let input = try JSONSerialization.data(withJSONObject: functions.map { ["name": $0.name, "arguments": $0.arguments, "variable": $0.variable] as [String: Any] })
        _ = try AppReplay.query(kind: "launch.install", input: input) {
            let bin = directory.appendingPathComponent("bin")
            for command in shims {
                guard let executable = executables[command.variable], FileManager.default.isExecutableFile(atPath: executable) else {
                    throw HerdrFailure("The \(command.name) launcher is missing.")
                }
                let path = bin.appendingPathComponent(command.name)
                try command.shim(executable: executable).write(to: path, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
            try NativeSSHEnvironment.install(in: directory, functions: functions)
            return Data()
        }
    }
    func nativeEnvironment(for scope: UUID, inheriting environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = self.environment(for: scope)
        result["PATH"] = directory.appendingPathComponent("bin").path + ":" + (environment["PATH"] ?? "/opt/homebrew/bin:/usr/bin:/bin")
        result.merge(NativeSSHEnvironment.variables(directory: directory, inheriting: environment, functions: functions), uniquingKeysWith: { _, new in new })
        return result
    }
    @discardableResult
    func stop(after cleanup: Task<Void, Never>? = nil) -> Task<Void, Never> {
        timer?.invalidate(); timer = nil; tokens.removeAll()
        if let retired = activeDirectory {
            activeDirectory = nil
            if let cleanup {
                retirements[retired] = Task { [weak self] in
                    await cleanup.value
                    do {
                        _ = try await AppReplay.run(kind: "launch.retire", input: Data(retired.path.utf8)) {
                            // OpenSSH keeps a ControlPersist master running after its socket
                            // is deleted, unreachable. A launch the app has not taken over yet
                            // (its mailbox request unread at stop) still has one listening
                            // here. -O needs a destination; -S alone names the master.
                            if let ssh = ShellCommandWrapper.ssh.executable(in: ProcessInfo.processInfo.environment) {
                                for folder in (try? FileManager.default.contentsOfDirectory(atPath: retired.path)) ?? [] where folder.hasPrefix("s-") {
                                    let master = SSHMaster(executable: ssh, controlPath: retired.path + "/" + folder + "/master", destination: folder)
                                    _ = try? await SSHCommand.run(executable: ssh, arguments: master.controlArguments("exit"), timeout: 3)
                                }
                            }
                            Self.remove(retired)
                            return Data()
                        }
                    } catch { AppReplay.fail(error) }
                    self?.retirements[retired] = nil
                }
            } else {
                do { _ = try AppReplay.query(kind: "launch.retire", input: Data(retired.path.utf8)) { Self.remove(retired); return Data() } }
                catch { AppReplay.fail(error) }
            }
        }
        let pending = Array(retirements.values)
        return Task { for retirement in pending { await retirement.value } }
    }
    private static func remove(_ directory: URL) {
        // Retire the pathname only after SSH has used its control sockets.
        // Late atomic writers still hold the old pathname, so they cannot add
        // files while we recursively remove the renamed generation.
        let retired = directory.appendingPathExtension("retired-" + UUID().uuidString)
        let path = rename(directory.path, retired.path) == 0 ? retired : directory
        try? FileManager.default.removeItem(at: path)
    }
    private func consume() {
        guard !AppReplay.replaying else { return }
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if url.pathExtension == "sshconsent" {
                defer { try? FileManager.default.removeItem(at: url) }
                guard let data = try? Data(contentsOf: url), data.count < 16_384,
                      let request = try? JSONDecoder().decode(SSHConsentRequest.self, from: data),
                      request.id.uuidString == url.deletingPathExtension().lastPathComponent else { continue }
                guard tokens[request.tabID] == request.token else {
                    print("SSH consent rejected: inactive launcher scope=\(request.tabID)")
                    continue
                }
                guard request.origin.alive,
                      request.origin.executable == Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
                    print("SSH consent rejected: origin identity changed, scope=\(request.tabID)")
                    continue
                }
                sshConsent?(request, url.deletingPathExtension().appendingPathExtension("sshchoice"))
                continue
            }
            if url.pathExtension == "sshclosed" {
                defer { try? FileManager.default.removeItem(at: url) }
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                   let data = try? Data(contentsOf: url), data.count < 1024,
                   let notice = try? JSONDecoder().decode(SSHCloseNotice.self, from: data) {
                    sshClosed?(SSHConnectionID(id), notice)
                }
                continue
            }
            if url.pathExtension == "sshrequest" || url.pathExtension == "sshconnecting" {
                defer { try? FileManager.default.removeItem(at: url) }
                guard let data = try? Data(contentsOf: url), data.count < 262144,
                      let request = try? JSONDecoder().decode(SSHLaunchRequest.self, from: data),
                      tokens[request.tabID] == request.token,
                      UUID(uuidString: request.credential) != nil,
                      request.master.controlPath.hasPrefix(directory.path + "/s-") else { continue }
                if url.pathExtension == "sshconnecting" { sshConnecting?(request) }
                else { sshHandler?(request) }
            }
        }
    }
    nonisolated static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}
