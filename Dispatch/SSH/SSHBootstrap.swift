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
    /// The helper's exit status when it ended before it greeted (126: its folder cannot run programs, also when the
    /// install found that out first); nil for every other failure.
    var exitStatus: Int32?

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

    /// `root`'s folder cannot run programs (mounted noexec or blocked by policy): the helper is there and verifies,
    /// but nothing may start it there.
    static func cannotRun(_ root: SSHBootstrapScript.Root, runtimeDirectory: String?) -> Self {
        exited(status: 126, stderr: "", root: root, runtimeDirectory: runtimeDirectory)
    }

    /// A helper that ended before it answered `hello`: the text the iPhone gives too (`SSHBootstrapScript.launchFailure`).
    /// Permanent for 126 (the folder cannot run programs), 127 (it could not be started) and a setup step's own
    /// `dispatch-setup:` reason; any other status (`connect` gave up waiting for the login's bus on a slow host) may pass
    /// on another attempt, and keeps its text for when that fails too.
    static func exited(status: Int32, stderr: String, root: SSHBootstrapScript.Root, runtimeDirectory: String?) -> Self {
        var text = SSHBootstrapScript.launchFailure(status: status, stderr: stderr, root: root, runtimeDirectory: runtimeDirectory)
        // The login prints the reason inside "(…);": no sentence's full stop there.
        if text.hasSuffix("."), !text.hasSuffix("...") { text.removeLast() }
        var failure: Self
        if status == 126 || status == 127 || SSHBootstrapScript.reason(stderr) != nil {
            failure = permanent("The SSH helper could not start.", reason: text)
        } else {
            failure = Self("The SSH helper could not start.", reason: text, given: nil)
        }
        failure.exitStatus = status
        return failure
    }

    /// A home folder that cannot run programs, with a usable runtime folder the grant may not use: agent hooks and the
    /// typed launch functions of the login's shell run `~/.dispatch/bin/dispatch-helper`, which cannot run there.
    static var hooksNeedHome: Self {
        var failure = permanent("The SSH helper could not start.", reason: hooksNeedHomeReason)
        failure.exitStatus = 126
        return failure
    }

    /// Why agent hooks are not installed on a host whose helper runs from the runtime folder.
    static let hooksUnavailable =
        "Agent hooks are unavailable on this host: they run ~/.dispatch/bin/dispatch-helper, and its home folder cannot run programs."

    static let hooksNeedHomeReason =
        "The home folder cannot run programs (noexec mount or policy), and agent hooks need it: turn hooks off for this host to use the helper"

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
    /// Where an install put the helper. `published` is what the login's ready file names (`.dispatch/bin/versions/…`
    /// under `$HOME`, `dispatch/bin/versions/…` under `$XDG_RUNTIME_DIR`); `path` is the host path the app keeps
    /// (home-relative, or absolute in the runtime folder: `hostPath`).
    struct Installed {
        let root: SSHBootstrapScript.Root
        let published: String
        let path: String
        let runtimeDirectory: String?
        let preamble: String
        let verify: String

        /// The helper's command over the master. The home root's text is what every recording holds. The runtime
        /// root's keeps stdout (the helper protocol's stream) for the helper alone: a failed check says why on stderr.
        /// `export`: `captureExport`, observed (`ReplayMigrationTests` fingerprints the text without it).
        func command(_ arguments: String, export: String = captureExport) -> String {
            switch root {
            case .home:
                preamble + "\n" + verify + " || exit 1\n" + export + "exec ./dispatch-helper " + arguments
            case .runtimeDirectory:
                "exec 3>&1 1>&2\n" + preamble + "\n" + verify + " || fail \"installed helper does not verify\"\n" + export
                    + "exec ./dispatch-helper " + arguments + " 1>&3 3>&-"
            }
        }
    }

    /// The host path the app keeps for a helper path `startHelper` returned: absolute as it is, else under `home`.
    static func hostPath(_ path: String, home: String) -> String {
        path.hasPrefix("/") ? path : home + "/" + path
    }

    /// Identifies the host platform, then places `resource/<platform>` in the digest-addressed private cache under `root`
    /// (`~/.dispatch/bin/versions/<sha256>/`, or `$XDG_RUNTIME_DIR/dispatch/bin/versions/<sha256>/`) unless an identical
    /// copy is already there.
    ///
    /// A cached file that verifies but that `test -x` refuses (`SSHBootstrapScript.cacheCheck` prints `DISPATCH_NOEXEC`
    /// and dates the file, so the helpers' cleanup keeps it) is a folder that cannot run programs: a permanent failure
    /// with status 126 (`SSHSetupFailure.cannotRun`), nothing uploaded. A first upload there learns it the same way: it
    /// ends "installed helper does not verify", one more check tells that from a bad upload, and the upload is not tried
    /// again. The runtime root asks `runtimeProbe` first (only then: every connection's first command is `probe`); with no
    /// usable runtime folder, or one `runtimeAllowed` forbids (a grant with agent hooks), it fails before writing anything.
    private static func install(resource: String, resources: URL, root: SSHBootstrapScript.Root, runtimeAllowed: Bool,
                                run: (String, Data) async throws -> SSHCommand.Result) async throws -> Installed {
        let probe = try await run(root == .home ? SSHBootstrapScript.probe : SSHBootstrapScript.runtimeProbe, Data())
        guard probe.status == 0 else {
            throw SSHSetupFailure("Could not use the authenticated SSH connection.", reason: "the host refused commands (\(probe.status))",
                                  given: nil)
        }
        let said = String(decoding: probe.output, as: UTF8.self)
        let name: String
        switch SSHBootstrapScript.platform(said) {
        case .helper(let helper): name = helper
        case .unidentified: throw SSHSetupFailure.permanent("Could not identify the SSH host platform.", reason: "unknown host platform")
        case .unsupported:
            throw SSHSetupFailure.permanent("SSH integration requires Linux on ARM64 or x86-64, or macOS on Apple silicon.", reason: "unsupported host platform")
        }
        var runtimeDirectory: String?
        if root == .runtimeDirectory {
            runtimeDirectory = SSHBootstrapScript.runtimeDirectory(said)
            guard runtimeDirectory != nil else { throw SSHSetupFailure.cannotRun(.home, runtimeDirectory: nil) }
            guard runtimeAllowed else { throw SSHSetupFailure.hooksNeedHome }
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
        let published = SSHBootstrapScript.relativePath(digest: digest, root: root)
        let preamble = SSHBootstrapScript.cachePreamble(digest: digest, root: root)
        let verify = SSHBootstrapScript.verify(size: payload.size, digest: digest)
        let check = SSHBootstrapScript.cacheCheck(size: payload.size, digest: digest, root: root)
        let existing = try await run(check, Data())
        if existing.status != 0 {
            // A cache that is unsafe or cannot be made says why; a helper that is only missing (or another version) does
            // not, and is uploaded.
            if let reason = SSHBootstrapScript.reason(String(decoding: existing.output, as: UTF8.self)) {
                throw SSHSetupFailure("Could not use the SSH helper cache.", reason: reason, given: reason)
            }
            if SSHBootstrapScript.blocked(String(decoding: existing.output, as: UTF8.self)) { throw SSHSetupFailure.cannotRun(root, runtimeDirectory: runtimeDirectory) }
            // The id site keeps this function's former name: recordings know their staging folders by it.
            let staging = "upload-" + System.uuid(#fileID, "install(resource:resources:run:)").uuidString.lowercased()
            let upload = SSHBootstrapScript.upload(digest: digest, size: payload.size, staging: staging, root: root)
            let installed = try await run(upload, try System.read(url))
            guard installed.status == 0 else {
                let given = SSHBootstrapScript.reason(String(decoding: installed.output, as: UTF8.self))
                // How a folder that cannot run programs answers once the file is in place (`test -x` asks the kernel).
                if given == "installed helper does not verify",
                   SSHBootstrapScript.blocked(String(decoding: try await run(check, Data()).output, as: UTF8.self)) {
                    throw SSHSetupFailure.cannotRun(root, runtimeDirectory: runtimeDirectory)
                }
                throw SSHSetupFailure("Could not install the SSH helper in the remote cache.",
                                      reason: given ?? "the upload failed (\(installed.status))", given: given)
            }
        }
        let path = runtimeDirectory.map { $0 + "/" + published } ?? published
        return Installed(root: root, published: published, path: path, runtimeDirectory: runtimeDirectory,
                         preamble: preamble, verify: verify)
    }

    /// The helper runs over SSH: upload it, release the waiting login (which execs `<helper> login …`),
    /// then reach that login's bus with `connect`; the bus exists only once the login runs.
    ///
    /// A home folder that cannot run programs (the install's check, or a helper that exits with 126 before it greets)
    /// moves the helper once to `$XDG_RUNTIME_DIR/dispatch/bin/versions/<sha256>/` when `runtimeAllowed` (a grant without
    /// agent hooks: those, and the login shell's typed launch functions, run `~/.dispatch/bin/dispatch-helper`) and the
    /// runtime folder is usable; the login then runs it from there. Returns the helper's host path (`hostPath`).
    static func startHelper(master: SSHMaster, resources: URL, sessionID: String, publish: Bool, runtimeAllowed: Bool = false,
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
        func install(_ root: SSHBootstrapScript.Root) async throws -> Installed {
            try await Self.install(resource: "helper", resources: resources, root: root, runtimeAllowed: runtimeAllowed, run: run)
        }
        // Once the home folder proved unable to run programs, another attempt goes to the runtime folder directly.
        var homeBlocked = false
        var installed = try await attempt("install") {
            if !homeBlocked {
                do { return try await install(.home) }
                catch let failure as SSHSetupFailure where failure.exitStatus == 126 { homeBlocked = true }
            }
            return try await install(.runtimeDirectory)
        }
        /// A helper process over the master, started afresh for each attempt. One that ends before it greets says why
        /// (`exited`): its status and stderr, read only then.
        func helper(_ name: String, _ arguments: String) async throws -> HelperSession {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw SSHSetupFailure.permanent("SSH integration setup timed out.", reason: "setup timed out") }
            let process = Process(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: master.executable)
            process.arguments = master.arguments(command: installed.command(arguments))
            process.standardError = errors
            let collected = SSHHelperErrors(errors.fileHandleForReading)
            do {
                let session = try await SSHTimeout.run(remaining, name) { try await HelperSession(process: process) }
                try? errors.fileHandleForWriting.close()
                return session
            } catch {
                try? errors.fileHandleForWriting.close()
                guard let end = await exited(error, process: process, errors: collected, name: name) else { throw error }
                // At home the runtime folder is not known yet (`launch` asks next): no word about it here.
                throw SSHSetupFailure.exited(status: end.status, stderr: end.stderr, root: installed.root,
                                             runtimeDirectory: installed.runtimeDirectory ?? "")
            }
        }
        /// `helper`, once more from the runtime folder after a 126 at home.
        func launch(_ name: String, _ arguments: String) async throws -> HelperSession {
            do { return try await helper(name, arguments) }
            catch let failure as SSHSetupFailure where failure.exitStatus == 126 && installed.root == .home {
                installed = try await install(.runtimeDirectory)
                return try await helper(name, arguments)
            }
        }
        // Verify the greeting before releasing the login: after its user command starts, a bad
        // helper channel cannot safely fall back by starting that command again.
        if publish || prepare != nil {
            let probe = try await attempt("probe") { try await launch("probe", "--remote --capabilities '' --stdio") }
            defer { probe.close() }
            try Task.checkCancellation()
            try await prepare?(installed.path, probe.info)
        }
        if publish {
            try await attempt("publish") {
                let result = try await run(self.publish(sessionID: sessionID, relativePath: installed.published))
                guard result.status == 0 else {
                    let given = SSHBootstrapScript.reason(String(decoding: result.output, as: UTF8.self))
                    throw SSHSetupFailure("Could not finish setting up the remote shell.",
                                          reason: given ?? "could not release the login (\(result.status))", given: given)
                }
            }
        }
        let session = try await attempt("connect") { try await launch("session", "connect --session '" + sessionID + "'") }
        return (installed.path, session)
    }

    /// The end of a helper whose `hello` failed because it closed its stdout (`connection_closed`): its exit status and
    /// the first 64 KiB of its stderr, observed (only on this path: a greeting that succeeded reads neither). Nil (the
    /// failure stays what it was, retried as before) when it gave no status, when ssh itself failed (255), or in the
    /// replay of a recording made before this was observed.
    private static func exited(_ error: Error, process: Process, errors: SSHHelperErrors, name: String) async
        -> (status: Int32, stderr: String)? {
        guard (error as? HelperFailure)?.code == "connection_closed" else { return nil }
        struct End: Codable { let status: Int32?; let stderr: String }
        // Its stdout closed: it is ending (HelperSession closed its stdin and terminates it a second later). Waited for
        // on a thread of its own, never the concurrency pool's; a process replay never started has nothing to wait for.
        let live: End = process.processIdentifier == 0 ? End(status: nil, stderr: "") : await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning, Date() < deadline { usleep(10_000) }
                let status: Int32? = process.isRunning || process.terminationReason != .exit ? nil : process.terminationStatus
                done.resume(returning: End(status: status, stderr: errors.text(waiting: 1)))
            }
        }
        guard let end = try? System.observe("helper.end", name, { live }), let status = end.status, status != 255 else { return nil }
        return (status, end.stderr)
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


/// A remote helper's stderr (its ssh's): passed on to the app's own stderr as before, its first 64 KiB kept for the
/// reason a helper that ended before it greeted gives. Read on a thread of its own for the helper's whole life (a helper
/// blocked on a full stderr pipe would stall). The app's stderr may be a pipe nobody reads any more (a launch from a
/// script that ended): writes to it never raise SIGPIPE, and one that fails ends the pass-through.
final class SSHHelperErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let finished = DispatchSemaphore(value: 0)
    private static let quiet: Void = { _ = fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1) }()

    init(_ handle: FileHandle) {
        let thread = Thread { [self] in
            _ = Self.quiet
            var passing = true
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                if passing {
                    passing = chunk.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            let written = Darwin.write(STDERR_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
                            if written < 0, errno == EINTR { continue }
                            guard written > 0 else { return false }
                            offset += written
                        }
                        return true
                    }
                }
                lock.withLock { if data.count < 65_536 { data.append(chunk.prefix(65_536 - data.count)) } }
            }
            try? handle.close()
            finished.signal()
        }
        thread.name = "SSH helper stderr"
        thread.start()
    }

    /// What it kept, once its stream ended (or `seconds` passed).
    func text(waiting seconds: Double) -> String {
        _ = finished.wait(timeout: .now() + seconds)
        return lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
