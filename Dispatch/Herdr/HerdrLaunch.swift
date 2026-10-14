import Foundation
import Darwin

/// A private per-app mailbox also contains the shell command shim. Requests are
/// atomic files, authenticated by a per-terminal capability, and consumed once.
@MainActor
final class HerdrLaunch {
    private(set) var directory = URL(fileURLWithPath: "/tmp/dispatch-herdr-\(System.uuid().uuidString)")
    private var activeDirectory: URL?
    private var retirements: [URL: Task<Void, Never>] = [:]
    /// Launch capabilities by terminal: the tab id its processes see (exported identity) and its token.
    private var tokens: [UUID: (tab: UUID, token: String)] = [:]
    /// Wakes on the mailbox directory's changes; requests arrive as renames, so each is complete when seen.
    private var watcher: DispatchSourceFileSystemObject?
    /// The journal's view of the mailbox: capture records each request as it is read, replay hands it back.
    private var mailbox: AppReplay.Ticket?
    private struct File: Codable { let path: String; let data: Data? }
    /// Commands wrapped in this app's terminals: ssh plus the helper's listed programs (see install(_:)).
    private(set) var functions: [ShellCommandWrapper] = [.ssh, .helper(program: "herdr", key: "herdr")]
    private var shims: [ShellCommandWrapper] { functions }
    /// The programs behind the wrappers' variables; the helper's only where its launches are wrapped.
    private var executables: [String: String] {
        var programs = ["DISPATCH_EXECUTABLE": System.executable.path]
        programs["DISPATCH_HELPER_EXECUTABLE"] = HelperApp.executable?.path ?? ""
        return programs
    }
    var sshHandler: ((SSHLaunchRequest) -> Void)?
    var sshConnecting: ((SSHLaunchRequest) -> Void)?
    var sshConsent: ((SSHConsentRequest, URL) -> Void)?
    var sshClosed: ((SSHConnectionID, SSHCloseNotice) -> Void)?

    func start() throws {
        stop()
        // Named outside the recorded start: a failed start's directory is still the recorded one.
        directory = URL(fileURLWithPath: "/tmp/dispatch-herdr-\(System.uuid().uuidString)")
        let data = try AppReplay.query(kind: "launch.start", input: .null) {
            let directory = directory
            activeDirectory = directory
            var ready = false
            defer { if !ready { stop() } }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let bin = directory.appendingPathComponent("bin")
            try fm.createDirectory(at: bin, withIntermediateDirectories: false)
            try install(functions)
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { throw HerdrFailure("The launch mailbox could not be watched.") }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            watcher.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard self?.activeDirectory?.path == directory.path else { return }
                    self?.consume()
                }
            }
            watcher.setCancelHandler { Darwin.close(descriptor) }
            watcher.resume()
            self.watcher = watcher
            ready = true
            return .string(directory.path)
        }
        directory = URL(fileURLWithPath: try AppReplay.decode(String.self, data))
        activeDirectory = directory
        mailbox = try AppReplay.open(kind: "launch.mailbox", input: .string(directory.path))
        if let mailbox, mailbox.replaying {
            // The app's own sockets (an SSH login's renderer) go here in replay too.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try mailbox.listen({ [weak self] event in
                guard event.kind == "in.file", let file = try? AppReplay.decode(File.self, event.value) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(URL(fileURLWithPath: file.path), file.data) } }
            }, failed: { _ in })
        }
    }

    func environment(for id: UUID) -> [String: String] {
        do {
            let identity = try AppReplay.identity(kind: "terminal", value: id)
            // A value the app makes for this terminal, like its ids.
            let token = tokens[id]?.token ?? System.uuid(for: identity.uuidString).uuidString
            tokens[id] = (identity, token)
            var environment = ["DISPATCH_HERDR_DIRECTORY": directory.path, "DISPATCH_HERDR_TAB": identity.uuidString,
                    "DISPATCH_HERDR_TOKEN": token,
                    "PATH": directory.appendingPathComponent("bin").path + ":" + System.path]
            environment.merge(executables, uniquingKeysWith: { _, new in new })
            environment.merge(NativeSSHEnvironment.bashFunctions(inheriting: System.inherited, functions: functions), uniquingKeysWith: { _, new in new })
            return environment
        } catch { AppReplay.fail(error); return [:] }
    }
    func close(_ id: UUID) { tokens[id] = nil }

    /// Writes the PATH shims and native shell functions for ssh plus these programs.
    func install(_ programs: [ShellCommandWrapper]) throws {
        functions = [.ssh, .helper(program: "herdr", key: "herdr")] + programs.filter { $0 != .ssh && $0 != .helper(program: "herdr", key: "herdr") }
        let input = try HelperBinary.value(functions.map { ["name": $0.name, "arguments": $0.arguments, "variable": $0.variable] as [String: Any] })
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
            return .null
        }
    }
    func nativeEnvironment(for scope: UUID, inheriting environment: [String: String] = System.inherited) -> [String: String] {
        var result = self.environment(for: scope)
        result["PATH"] = directory.appendingPathComponent("bin").path + ":" + (environment["PATH"] ?? "/opt/homebrew/bin:/usr/bin:/bin")
        result.merge(NativeSSHEnvironment.variables(directory: directory, inheriting: environment, functions: functions), uniquingKeysWith: { _, new in new })
        return result
    }
    @discardableResult
    func stop(after cleanup: Task<Void, Never>? = nil) -> Task<Void, Never> {
        watcher?.cancel(); watcher = nil; tokens.removeAll()
        if let mailbox, !mailbox.replaying { do { try mailbox.emit(kind: "exit") } catch { AppReplay.fail(error) } }
        mailbox = nil
        if let retired = activeDirectory {
            activeDirectory = nil
            if let cleanup {
                retirements[retired] = Task { [weak self] in
                    await cleanup.value
                    do {
                        _ = try await AppReplay.run(kind: "launch.retire", input: .string(retired.path)) {
                            // OpenSSH keeps a ControlPersist master running after its socket
                            // is deleted, unreachable. A launch the app has not taken over yet
                            // (its mailbox request unread at stop) still has one listening
                            // here. -O needs a destination; -S alone names the master.
                            if let ssh = ShellCommandWrapper.ssh.executable(in: System.inherited) {
                                for folder in (try? FileManager.default.contentsOfDirectory(atPath: retired.path)) ?? [] where folder.hasPrefix("s-") {
                                    let master = SSHMaster(executable: ssh, controlPath: retired.path + "/" + folder + "/master", destination: folder)
                                    await master.exit().value
                                }
                            }
                            Self.remove(retired)
                            return .null
                        }
                    } catch { AppReplay.fail(error) }
                    self?.retirements[retired] = nil
                }
            } else {
                do { _ = try AppReplay.query(kind: "launch.retire", input: .string(retired.path)) { Self.remove(retired); return .null } }
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
        let retired = directory.appendingPathExtension("retired-" + System.uuid().uuidString)
        let path = rename(directory.path, retired.path) == 0 ? retired : directory
        try? FileManager.default.removeItem(at: path)
    }
    private func consume() {
        guard !AppReplay.replaying else { return }
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where ["sshconsent", "sshclosed", "sshrequest", "sshconnecting"].contains(url.pathExtension) {
            defer { try? FileManager.default.removeItem(at: url) }
            let data = try? Data(contentsOf: url)
            do { try mailbox?.emit(kind: "file", value: AppReplay.value(File(path: url.path, data: data))) }
            catch { AppReplay.fail(error) }
            receive(url, data)
        }
    }
    private func receive(_ url: URL, _ data: Data?) {
        if url.pathExtension == "sshconsent" {
            guard let data, data.count < 16_384,
                  let request = try? JSONDecoder().decode(SSHConsentRequest.self, from: data),
                  request.id.uuidString == url.deletingPathExtension().lastPathComponent else { return }
            guard tokens.values.contains(where: { $0 == (request.tabID, request.token) }) else {
                print("SSH consent rejected: inactive launcher scope=\(request.tabID)")
                return
            }
            guard request.origin.alive,
                  request.origin.executable == System.resolve(System.executable).path else {
                print("SSH consent rejected: origin identity changed, scope=\(request.tabID)")
                return
            }
            sshConsent?(request, url.deletingPathExtension().appendingPathExtension("sshchoice"))
            return
        }
        if url.pathExtension == "sshclosed" {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
               let data, data.count < 1024,
               let notice = try? JSONDecoder().decode(SSHCloseNotice.self, from: data) {
                sshClosed?(SSHConnectionID(id), notice)
            }
            return
        }
        if url.pathExtension == "sshrequest" || url.pathExtension == "sshconnecting" {
            guard let data, data.count < 262144,
                  let request = try? JSONDecoder().decode(SSHLaunchRequest.self, from: data),
                  tokens.values.contains(where: { $0 == (request.tabID, request.token) }),
                  UUID(uuidString: request.credential) != nil,
                  request.master.controlPath.hasPrefix(directory.path + "/s-") else { return }
            if url.pathExtension == "sshconnecting" { sshConnecting?(request) }
            else { sshHandler?(request) }
        }
    }
    nonisolated static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}
