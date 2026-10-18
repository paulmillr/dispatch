import Foundation
import CryptoKit
import os
import Darwin

enum SSHBootstrap {
    /// Identifies the host platform, then places `resource/<platform>` in the digest-addressed private
    /// cache (`~/.dispatch/bin/versions/<sha256>/`) unless an identical copy is already there.
    /// Returns the cache path and its shell checks.
    private static func install(resource: String, resources: URL,
                                run: (String, Data) async throws -> SSHCommand.Result) async throws
        -> (relativePath: String, preamble: String, verify: String) {
        let probe = try await run(SSHBootstrapScript.probe, Data())
        guard probe.status == 0 else { throw HerdrFailure("Could not use the authenticated SSH connection.") }
        let name: String
        switch SSHBootstrapScript.platform(String(decoding: probe.output, as: UTF8.self)) {
        case .helper(let helper): name = helper
        case .unidentified: throw HerdrFailure("Could not identify the SSH host platform.")
        case .unsupported: throw HerdrFailure("SSH integration requires Linux or macOS on ARM64 or x86-64.")
        }
        // The bundled file is read like any other: its identity is observed (a replay answers the recorded one, whatever
        // the build bundles now), its bytes are read only to upload them.
        struct Payload: Codable { let digest: String, size: Int }
        let url = resources.appendingPathComponent(resource + "/" + name)
        let payload = try System.observe("payload", url.path) {
            let binary = try Data(contentsOf: url)
            return Payload(digest: SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined(), size: binary.count)
        }
        guard payload.size > 0, payload.size <= SSHBootstrapScript.maximumSize else { throw HerdrFailure("SSH helper is missing or invalid.") }
        let digest = payload.digest
        let relativePath = SSHBootstrapScript.relativePath(digest: digest)
        let preamble = cachePreamble(digest: digest)
        let verify = SSHBootstrapScript.verify(size: payload.size, digest: digest)
        let existing = try await run(preamble + "\n" + verify, Data())
        if existing.status != 0 {
            let staging = "upload-" + System.uuid().uuidString.lowercased()
            let upload = SSHBootstrapScript.upload(digest: digest, size: payload.size, staging: staging)
            let installed = try await run(upload, try System.read(url))
            guard installed.status == 0 else { throw HerdrFailure("Could not install the SSH helper in the remote cache.") }
        }
        return (relativePath, preamble, verify)
    }

    /// The helper runs over SSH: upload it, release the waiting login (which execs `<helper> login …`),
    /// then reach that login's bus with `connect`; the bus exists only once the login runs.
    static func startHelper(master: SSHMaster, resources: URL, sessionID: String, publish: Bool,
                            prepare: (@MainActor (String, HelperSession.Info) throws -> Void)? = nil) async throws
        -> (relativePath: String, session: HelperSession) {
        guard validSessionID(sessionID),
              (try? String(contentsOf: resources.appendingPathComponent("helper/protocol-version"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == String(HelperBinary.version) else {
            throw HerdrFailure("The SSH helper is unavailable.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        func run(_ command: String, input: Data = Data()) async throws -> SSHCommand.Result {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw HerdrFailure("SSH integration setup timed out.") }
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            return try await SSHCommand.run(executable: master.executable, arguments: master.arguments(command: command), input: input, timeout: seconds)
        }
        let (relativePath, preamble, verify) = try await install(resource: "helper", resources: resources, run: run)
        // Verify the greeting before releasing the login: after its user command starts, a bad
        // helper channel cannot safely fall back by starting that command again.
        if publish || prepare != nil {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: master.executable)
            process.arguments = master.arguments(command: preamble + "\n" + verify + " || exit 1\n" + captureExport + "exec ./dispatch-helper --remote --capabilities '' --stdio")
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw HerdrFailure("SSH integration setup timed out.") }
            let probe = try await SSHTimeout.run(remaining, "probe") { try await HelperSession(process: process) }
            defer { probe.close() }
            try Task.checkCancellation()
            try await prepare?(relativePath, probe.info)
        }
        if publish {
            guard try await run(self.publish(sessionID: sessionID, relativePath: relativePath)).status == 0 else {
                throw HerdrFailure("Could not finish setting up the remote shell.")
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: master.executable)
        process.arguments = master.arguments(command: preamble + "\n" + verify + " || exit 1\n" + captureExport + "exec ./dispatch-helper connect --session '" + sessionID + "'")
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw HerdrFailure("SSH integration setup timed out.") }
        let session = try await SSHTimeout.run(remaining, "session") { try await HelperSession(process: process) }
        return (relativePath, session)
    }

    /// Test runs (DISPATCH_CAPTURE set for this app) trace remote helpers too: the remote login and
    /// `connect` export DISPATCH_CAPTURE=$HOME/<captureDirectory>/<its file name> (helper-%p.rpl.zst: every remote
    /// helper, nested ones included, writes its own file); the tests collect that directory after each case.
    /// Set in capture runs only: replay keeps the recorded value, so the command sent is the recorded one.
    static var capturePath: String? {
        let path: String?
        do { path = try System.observe("environment", "DISPATCH_CAPTURE") { System.environment("DISPATCH_CAPTURE") } }
        catch { AppReplay.fail(error); path = nil }
        return path
    }

    /// The remote folder of a capture path: a digest of its directory (a test case's staging folder), so shared hosts
    /// keep cases apart.
    static func captureDirectory(_ path: String) -> String {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return ".cache/dispatch-capture/" + SHA256.hash(data: Data(directory.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    static var captureExport: String {
        capturePath.map { path in
            let directory = captureDirectory(path), name = URL(fileURLWithPath: path).lastPathComponent
            return "mkdir -p \"$HOME/\(directory)\" && export DISPATCH_CAPTURE=\"$HOME/\(directory)/\(name)\"\n"
        } ?? ""
    }

    static func validSessionID(_ id: String) -> Bool {
        id.utf8.count == 24 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static var privateDirectoryScript: String { SSHBootstrapScript.privateDirectoryScript }

    static func cachePreamble(digest: String) -> String { SSHBootstrapScript.cachePreamble(digest: digest) }

    static func publish(sessionID: String, relativePath: String?) -> String {
        precondition(validSessionID(sessionID))
        let value = relativePath ?? "unavailable"
        return privateDirectoryScript + """

        enter_private sessions || exit 1
        enter_private '\(sessionID)' || exit 1
        test ! -e ready && test ! -L ready || exit 1
        (set -C; printf '%s\\n' \(HerdrLaunch.quote(value)) > ready.pending) || exit 1
        mv -f ready.pending ready
        """
    }
}

/// Bounded, cancellable auxiliary commands. Authentication remains on the
/// original terminal; these commands always use SSHMaster's no-dial fallback,
/// except automatic reconnect's BatchMode login (SSHReconnectLogin.authenticateSilently).
enum SSHCommand {
    struct Result: Codable, Sendable { let status: Int32; let output: Data; var errors: Data? = nil }
    private final class Lifetime: @unchecked Sendable {
        struct State { var process: Process?; var cancelled = false }
        let state = OSAllocatedUnfairLock(initialState: State())
        func cancel() {
            let process = state.withLock {
                $0.cancelled = true
                return $0.process
            }
            if let process, process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
    /// `errors` keeps the first 64 KiB of stderr. It goes to a private file, not a pipe: an `ssh -f`
    /// master the command starts can hold its stderr open long after the command returns.
    static func run(executable: String, arguments: [String], input: Data = Data(), timeout: TimeInterval = 15,
                    errors: Bool = false) async throws -> Result {
        struct Input: Codable { let executable: String; let arguments: [String]; let input: Data; var errors: Bool? }
        let request = Input(executable: executable, arguments: arguments, input: input, errors: errors ? true : nil)
        let data = try await AppReplay.run(kind: "command", input: AppReplay.value(request)) {
            let lifetime = Lifetime()
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        let process = Process(), stdin = Pipe(), stdout = Pipe()
                        let log = errors ? System.temporary.appendingPathComponent("ssh-errors-" + System.uuid().uuidString) : nil
                        defer { if let log { try? FileManager.default.removeItem(at: log) } }
                        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
                        do {
                            guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                            }
                            var stderr: FileHandle?
                            if let log {
                                guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                                    throw POSIXError(.EIO)
                                }
                                stderr = try FileHandle(forWritingTo: log)
                                process.standardError = stderr
                            }
                            try lifetime.state.withLock { state in
                                guard !state.cancelled else { throw CancellationError() }
                                try process.run(); state.process = process
                            }
                            stdin.fileHandleForReading.closeFile(); stdout.fileHandleForWriting.closeFile(); try? stderr?.close()
                            let deadline = DispatchWorkItem { lifetime.cancel() }
                            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                            defer { deadline.cancel() }
                            DispatchQueue.global(qos: .utility).async {
                                try? stdin.fileHandleForWriting.write(contentsOf: input)
                                try? stdin.fileHandleForWriting.close()
                            }
                            var output = Data()
                            while let bytes = try stdout.fileHandleForReading.read(upToCount: 65_536), !bytes.isEmpty {
                                guard output.count + bytes.count <= 1_048_576 else {
                                    lifetime.cancel(); throw HerdrFailure("SSH command output exceeded its limit.")
                                }
                                output.append(bytes)
                            }
                            process.waitUntilExit()
                            guard !lifetime.state.withLock({ $0.cancelled }) else { throw HerdrFailure("SSH command cancelled or timed out.") }
                            var captured: Data?
                            if let log {
                                let reader = try FileHandle(forReadingFrom: log)
                                defer { try? reader.close() }
                                captured = try reader.read(upToCount: 65_536) ?? Data()
                            }
                            continuation.resume(returning: Result(status: process.terminationStatus, output: output, errors: captured))
                        } catch {
                            lifetime.cancel()
                            if process.processIdentifier > 0 { process.waitUntilExit() }
                            continuation.resume(throwing: error)
                        }
                        try? stdout.fileHandleForReading.close()
                    }
                }
            } onCancel: { lifetime.cancel() }
            return try AppReplay.value(result)
        }
        return try AppReplay.decode(Result.self, data)
    }
}

/// Whom a remote helper says it runs as. Remote output: bounded before the app uses it.
struct SSHGreeting: Codable, Sendable {
    let version: Int
    let host: String
    let boot: String
    let uid: UInt32
    let home: String
    let capabilities: [String]
    var hostname: String? = nil
    var os: String? = nil
    var distribution: String? = nil
    var osName: String? = nil
    var profile: SSHIntegrationProfile? = nil
    var hostID: String { host + ":" + String(uid) }

    /// A remembered grant authorizes a connection, never a reported machine name; the identity a
    /// remote helper reports must still be well formed before it names hosts or paths.
    func validate() throws {
        func bounded(_ value: String, limit: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard bounded(host, limit: 1024), bounded(boot, limit: 1024),
              bounded(home, limit: 4096), home.hasPrefix("/"), capabilities.count <= 1024,
              Set(capabilities).count == capabilities.count else {
            throw HerdrFailure("Invalid SSH helper identity.")
        }
    }
}

/// Time limits cancel the owned stream, including a remote process blocked on
/// stdin or a control socket that has stopped replying.
enum SSHTimeout {
    /// The timer is the recording's (System.sleep): a replay times out where its capture did, never on its own clock.
    static func run<Value: Sendable>(_ duration: Duration, _ name: String, _ file: String = #fileID,
                                     operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await System.sleep(for: duration, name, file)
                throw HerdrFailure("The remote operation timed out. Its outcome may be uncertain; it was not retried.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
