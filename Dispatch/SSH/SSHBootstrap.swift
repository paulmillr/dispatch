import Foundation
import CryptoKit
import os
import Darwin

/// A setup step that failed: what the app says, and the short reason the login prints as it falls back (and the
/// setup log records). `given` is the reason a remote script gave; a failure without one (the channel dropped) may
/// pass on another attempt.
struct SSHSetupFailure: LocalizedError, Sendable {
    let message: String
    let reason: String
    let given: String?
    /// Fails the same way again whatever is retried.
    var permanent = false

    init(_ message: String, reason: String, given: String?) {
        self.message = message
        self.reason = SSHBootstrapScript.printable(reason)
        self.given = given
    }

    static func permanent(_ message: String, reason: String) -> Self {
        var failure = Self(message, reason: reason, given: reason)
        failure.permanent = true
        return failure
    }

    var errorDescription: String? { message + " (" + reason + ")" }

    /// The reason any error gives the login: a setup step's own, else the error's words.
    static func reason(_ error: Error) -> String {
        if let failure = error as? SSHSetupFailure { return failure.reason }
        if error is CancellationError { return "setup was cancelled" }
        return SSHBootstrapScript.printable((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }

    /// Whether one more attempt may pass: a script's transient reason, a failure that gave none, or an error from the
    /// channel itself; never a cancellation or a permanent failure.
    static func transient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let failure = error as? SSHSetupFailure else { return true }
        return !failure.permanent && SSHBootstrapScript.transient(failure.given)
    }
}

enum SSHBootstrap {
    /// Identifies the host platform, then places `resource/<platform>` in the digest-addressed private
    /// cache (`~/.dispatch/bin/versions/<sha256>/`) unless an identical copy is already there.
    /// Returns the cache path and its shell checks.
    private static func install(resource: String, resources: URL,
                                run: (String, Data) async throws -> SSHCommand.Result) async throws
        -> (relativePath: String, preamble: String, verify: String) {
        let probe = try await run(SSHBootstrapScript.probe, Data())
        guard probe.status == 0 else {
            throw SSHSetupFailure("Could not use the authenticated SSH connection.", reason: "the host refused commands (\(probe.status))",
                                  given: nil)
        }
        let name: String
        switch SSHBootstrapScript.platform(String(decoding: probe.output, as: UTF8.self)) {
        case .helper(let helper): name = helper
        case .unidentified: throw SSHSetupFailure.permanent("Could not identify the SSH host platform.", reason: "unknown host platform")
        case .unsupported:
            throw SSHSetupFailure.permanent("SSH integration requires Linux or macOS on ARM64 or x86-64.", reason: "unsupported host platform")
        }
        // The bundled file is read like any other: its identity is observed (a replay answers the recorded one, whatever
        // the build bundles now), its bytes are read only to upload them.
        struct Payload: Codable { let digest: String, size: Int }
        let url = resources.appendingPathComponent(resource + "/" + name)
        let payload = try System.observe("payload", url.path) {
            let binary = try Data(contentsOf: url)
            return Payload(digest: SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined(), size: binary.count)
        }
        guard payload.size > 0, payload.size <= SSHBootstrapScript.maximumSize else {
            throw SSHSetupFailure.permanent("SSH helper is missing or invalid.", reason: "the bundled helper is missing")
        }
        let digest = payload.digest
        let relativePath = SSHBootstrapScript.relativePath(digest: digest)
        let preamble = cachePreamble(digest: digest)
        let verify = SSHBootstrapScript.verify(size: payload.size, digest: digest)
        let existing = try await run(preamble + "\n" + verify, Data())
        if existing.status != 0 {
            // A cache that is unsafe or cannot be made says why; a helper that is only missing (or another version) does
            // not, and is uploaded.
            if let reason = SSHBootstrapScript.reason(String(decoding: existing.output, as: UTF8.self)) {
                throw SSHSetupFailure("Could not use the SSH helper cache.", reason: reason, given: reason)
            }
            let staging = "upload-" + System.uuid().uuidString.lowercased()
            let upload = SSHBootstrapScript.upload(digest: digest, size: payload.size, staging: staging)
            let installed = try await run(upload, try System.read(url))
            guard installed.status == 0 else {
                let given = SSHBootstrapScript.reason(String(decoding: installed.output, as: UTF8.self))
                throw SSHSetupFailure("Could not install the SSH helper in the remote cache.",
                                      reason: given ?? "the upload failed (\(installed.status))", given: given)
            }
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
            throw SSHSetupFailure.permanent("The SSH helper is unavailable.", reason: "the bundled helper is unavailable")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        /// A step once more when it failed for a reason another attempt can fix (the channel dropped, the upload broke
        /// off: `SSHSetupFailure.transient`) and the deadline leaves room; the login waits for the whole setup.
        func attempt<T>(_ name: String, _ step: () async throws -> T) async throws -> T {
            do { return try await step() } catch {
                guard SSHSetupFailure.transient(error), ContinuousClock.now < deadline, !Task.isCancelled else { throw error }
                SSHSetupLog.retried(name, SSHSetupFailure.reason(error))
                return try await step()
            }
        }
        func run(_ command: String, input: Data = Data()) async throws -> SSHCommand.Result {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw SSHSetupFailure.permanent("SSH integration setup timed out.", reason: "setup timed out")
            }
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            return try await SSHCommand.run(executable: master.executable, arguments: master.arguments(command: command), input: input, timeout: seconds)
        }
        let (relativePath, preamble, verify) = try await attempt("install") {
            try await install(resource: "helper", resources: resources, run: run)
        }
        /// A helper process over the master, started afresh for each attempt.
        func helper(_ name: String, _ arguments: String) async throws -> HelperSession {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: master.executable)
            process.arguments = master.arguments(command: preamble + "\n" + verify + " || exit 1\n" + captureExport + "exec ./dispatch-helper " + arguments)
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw SSHSetupFailure.permanent("SSH integration setup timed out.", reason: "setup timed out") }
            return try await SSHTimeout.run(remaining, name) { try await HelperSession(process: process) }
        }
        // Verify the greeting before releasing the login: after its user command starts, a bad
        // helper channel cannot safely fall back by starting that command again.
        if publish || prepare != nil {
            let probe = try await attempt("probe") { try await helper("probe", "--remote --capabilities '' --stdio") }
            defer { probe.close() }
            try Task.checkCancellation()
            try await prepare?(relativePath, probe.info)
        }
        if publish {
            try await attempt("publish") {
                let result = try await run(self.publish(sessionID: sessionID, relativePath: relativePath))
                guard result.status == 0 else {
                    let given = SSHBootstrapScript.reason(String(decoding: result.output, as: UTF8.self))
                    throw SSHSetupFailure("Could not finish setting up the remote shell.",
                                          reason: given ?? "could not release the login (\(result.status))", given: given)
                }
            }
        }
        let session = try await attempt("connect") { try await helper("session", "connect --session '" + sessionID + "'") }
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

    /// Releases the waiting login: the helper's path, or (`relativePath` nil) why the app's setup failed, which the
    /// login shows as it falls back. A per-process pending name: a retry never trips over an earlier attempt's file.
    static func publish(sessionID: String, relativePath: String?, reason: String? = nil) -> String {
        precondition(validSessionID(sessionID))
        let value = relativePath ?? "unavailable: " + SSHBootstrapScript.printable(reason ?? "setup did not finish")
        return privateDirectoryScript + """

        enter_private sessions
        enter_private '\(sessionID)'
        test ! -e ready && test ! -L ready || fail "session already released"
        (set -C; printf '%s\\n' \(HerdrLaunch.quote(value)) > "ready.$$") || fail "cannot write the ready file"
        mv -f "ready.$$" ready || fail "cannot release the session"
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

/// Why SSH integration fell back to a plain shell, and which setup steps needed a second attempt: counted for
/// Settings › Troubleshooting, and written to the system log (subsystem yachts.dispatch.app, category SSHSetup).
/// Reasons only, as the scripts and the app word them; never a host or an account.
@MainActor @Observable final class SSHSetupLog {
    static let shared = SSHSetupLog()
    /// This run's fallbacks by reason.
    private(set) var fallbacks: [String: Int] = [:]
    private(set) var retries = 0
    nonisolated private static let logger = Logger(subsystem: "yachts.dispatch.app", category: "SSHSetup")

    func fellBack(_ reason: String) {
        fallbacks[reason, default: 0] += 1
        Self.logger.error("SSH integration fell back to a plain shell: \(reason, privacy: .public)")
    }

    nonisolated static func retried(_ step: String, _ reason: String) {
        logger.notice("SSH integration setup step \(step, privacy: .public) failed once (\(reason, privacy: .public)); trying again")
        Task { @MainActor in shared.retries += 1 }
    }
}

