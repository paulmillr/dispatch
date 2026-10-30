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

    /// The reason when the setup's own deadline passed.
    static let timedOut = "setup timed out"

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
    /// A helper the app bundles for one host platform (`SSHBootstrapScript.platform`), and the size and SHA-256 of the
    /// expanded file.
    struct Bundled: Equatable, Sendable {
        let name: String
        let url: URL
        /// The gzipped copy (`SSHHelperArchive`), uploaded where the host can expand it.
        let archive: URL?
        let size: Int
        let digest: String

        var candidate: SSHBootstrapScript.Candidate { .init(name: name, size: size, digest: digest) }
    }

    /// Where helpers start from: the cache under `root` (`~/.dispatch/bin/versions/<sha256>/`, or
    /// `$XDG_RUNTIME_DIR/dispatch/bin/versions/<sha256>/` in `runtimeDirectory`), whichever of `helpers` the host's
    /// platform runs.
    struct Launcher: Sendable {
        let root: SSHBootstrapScript.Root
        let runtimeDirectory: String?
        let helpers: [Bundled]

        /// The helper's command over the master: the platform probe, the cache check and the start in one exec channel
        /// (`SSHBootstrapScript.launch`). `export`: `captureExport`, observed (`ReplayMigrationTests` fingerprints the text
        /// without it).
        func command(_ arguments: String, export: String = captureExport) -> String {
            SSHBootstrapScript.launch(helpers.map(\.candidate), root: root, arguments: arguments, export: export)
        }

        /// Where the helper that greeted with `info` is. `published` is what the login's ready file names
        /// (`.dispatch/bin/versions/…` under `$HOME`, `dispatch/bin/versions/…` under `$XDG_RUNTIME_DIR`); `path` is the host
        /// path the app keeps (home-relative, or absolute in the runtime folder: `hostPath`). Each bundled helper is built
        /// for one platform, so the os and arch its greeting reports name the one the launch picked.
        func installed(_ info: HelperSession.Info) throws -> (published: String, path: String) {
            guard let name = SSHBootstrap.helperName(os: info.os, arch: info.arch),
                  let helper = helpers.first(where: { $0.name == name }) else {
                throw SSHSetupFailure.permanent("Could not identify the SSH host platform.", reason: "unknown helper platform")
            }
            let published = SSHBootstrapScript.relativePath(digest: helper.digest, root: root)
            return (published, runtimeDirectory.map { $0 + "/" + published } ?? published)
        }
    }

    /// The bundled helper a greeting's `os` and `arch` (the Rust names of the platform it was built for) come from.
    static func helperName(os: String, arch: String) -> String? {
        switch (os, arch) {
        case ("macos", "aarch64"): "darwin-arm64"
        case ("linux", "aarch64"): "linux-aarch64"
        case ("linux", "x86_64"): "linux-x86_64"
        default: nil
        }
    }

    /// The host path the app keeps for a helper path `startHelper` returned: absolute as it is, else under `home`.
    static func hostPath(_ path: String, home: String) -> String {
        path.hasPrefix("/") ? path : home + "/" + path
    }

    private struct Payload: Codable, Sendable { let digest: String, size: Int }
    /// Identities this run computed, by file and its stamp (device, inode, size, modification time): each bundled
    /// helper is expanded and hashed once, not on every login.
    private static let identities = OSAllocatedUnfairLock(initialState: [String: (stamp: String, payload: Payload)]())

    /// The helpers bundled under `resource` for every platform. A file's identity is observed (a replay answers the
    /// recorded one, whatever the build bundles now); its bytes are read only to upload it. A gzipped helper
    /// (`SSHHelperArchive`) is observed under its expanded name, as the identity is the expanded file's. A missing or
    /// invalid one is left out: a host of its platform then falls back, saying so.
    static func bundled(resource: String = "helper", resources: URL) throws -> [Bundled] {
        try ["darwin-arm64", "linux-aarch64", "linux-x86_64"].compactMap { name in
            let url = resources.appendingPathComponent(resource + "/" + name)
            let archive = SSHHelperArchive.compressed.contains(name) ? url.appendingPathExtension("gz") : nil
            let payload = try System.observe("payload", url.path) {
                let file = archive ?? url
                var status = stat()
                guard stat(file.path, &status) == 0 else { return Payload(digest: "", size: 0) }
                let stamp = "\(status.st_dev):\(status.st_ino):\(status.st_size):\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)"
                if let known = identities.withLock({ $0[file.path] }), known.stamp == stamp { return known.payload }
                guard let binary = try? archive.map({ try SSHHelperArchive.expand(Data(contentsOf: $0)) }) ?? Data(contentsOf: url)
                else { return Payload(digest: "", size: 0) }
                let payload = Payload(digest: SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined(), size: binary.count)
                identities.withLock { $0[file.path] = (stamp, payload) }
                return payload
            }
            guard payload.size > 0, payload.size <= SSHBootstrapScript.maximumSize else { return nil }
            return Bundled(name: name, url: url, archive: archive, size: payload.size, digest: payload.digest)
        }
    }

    /// A folded launch found no usable helper of its platform in the cache (`SSHBootstrapScript.launch`): `helper` is
    /// uploaded, then started again.
    private struct Miss: Error { let helper: Bundled }

    /// A helper upload fails when ssh takes none of it for this long (`SSHCommand.run`'s `stall`), however long it runs:
    /// ssh takes what it can buffer at once, then at the link's pace. The login waits as long as the file it receives grows
    /// (`SSHLauncherCommand.uploadProgress`).
    static let uploadStall: TimeInterval = 25
    /// Once ssh took the whole upload: what it still buffers (up to its channel window, about 2 MiB) reaching the host at
    /// 4 KiB/s or better, and the host's checks. A link that dies meanwhile ends the master sooner (`SSHKeepalive`).
    static func uploadTail(_ bytes: Int) -> TimeInterval { 30 + Double(bytes) / 4096 }

    /// The helper runs over SSH: started through the probe (`--remote --capabilities '' --stdio`, no grant) whose
    /// greeting the app verifies, the waiting login released through that probe (`login.release`; the login then execs
    /// `<helper> login …`, which makes the session bus), then that bus reached with `connect`, which exists only once
    /// the login runs. Each helper's exec channel also probes the platform and checks the cache
    /// (`SSHBootstrapScript.launch`): a warm login costs the probe's channel, one request on it, and the `connect`
    /// channel, which starts as the release is sent and waits for the bus. A cache that lacks the helper says so instead
    /// of starting one: the helper is uploaded (`resource/<platform>`, into `~/.dispatch/bin/versions/<sha256>/`), then
    /// started again.
    ///
    /// A home folder that cannot run programs (the launch's check prints `DISPATCH_NOEXEC`, or a helper exits with 126
    /// before it greets) moves the helper once to `$XDG_RUNTIME_DIR/dispatch/bin/versions/<sha256>/` when
    /// `runtimeAllowed` (a grant without agent hooks: those, and the login shell's typed launch functions, run
    /// `~/.dispatch/bin/dispatch-helper`) and the runtime folder is usable (`SSHBootstrapScript.runtimeProbe`, only
    /// then); the login then runs it from there. Returns the helper's host path (`hostPath`).
    static func startHelper(master: SSHMaster, resources: URL, sessionID: String, publish: Bool, runtimeAllowed: Bool = false,
                            prepare: (@MainActor (String, HelperSession.Info) throws -> Void)? = nil) async throws
        -> (relativePath: String, session: HelperSession) {
        guard validSessionID(sessionID),
              (try? String(contentsOf: resources.appendingPathComponent("helper/protocol-version"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == String(HelperBinary.version) else {
            throw SSHSetupFailure.permanent("The SSH helper is unavailable.", reason: "the bundled helper is unavailable")
        }
        // The setup's steps share 60 s. An upload is paced by the link instead (`uploadStall`), and the time it took
        // moves the deadline on, so a slow link's upload leaves the other steps their time.
        var deadline = ContinuousClock.now.advanced(by: .seconds(60))
        func timedOut() -> SSHSetupFailure { .permanent("SSH integration setup timed out.", reason: SSHSetupFailure.timedOut) }
        /// Whether a step that failed with `error` may run once more: a reason another attempt can fix (the channel
        /// dropped, the upload broke off: `SSHSetupFailure.transient`) with room left before the deadline.
        func again(_ error: Error) -> Bool {
            SSHSetupFailure.transient(error) && ContinuousClock.now < deadline && !Task.isCancelled
        }
        /// A step once more when it failed for a reason another attempt can fix (`again`); the login waits for the whole
        /// setup.
        func attempt<T>(_ name: String, _ step: () async throws -> T) async throws -> T {
            do { return try await step() } catch {
                guard again(error) else { throw error }
                SSHSetupLog.retried(name, SSHSetupFailure.reason(error))
                return try await step()
            }
        }
        func run(_ command: String, input: Data = Data()) async throws -> SSHCommand.Result {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw timedOut() }
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            guard !input.isEmpty else {
                return try await SSHCommand.run(executable: master.executable, arguments: master.arguments(command: command), timeout: seconds)
            }
            let started = ContinuousClock.now
            defer { deadline = deadline.advanced(by: started.duration(to: .now)) }
            return try await SSHCommand.run(executable: master.executable, arguments: master.arguments(command: command), input: input,
                                            timeout: uploadTail(input.count), stall: uploadStall)
        }
        let helpers = try bundled(resources: resources)
        var launcher = Launcher(root: .home, runtimeDirectory: nil, helpers: helpers)

        /// Places `helper` in `launcher`'s cache. A cache that cannot run programs answers its own upload's final check
        /// with "installed helper does not verify"; one more cache check tells that from a bad upload (`DISPATCH_NOEXEC`:
        /// a permanent failure with status 126, `SSHSetupFailure.cannotRun`), and the upload is not tried again.
        func upload(_ helper: Bundled) async throws {
            let root = launcher.root, runtimeDirectory = launcher.runtimeDirectory
            func send(compressed: Bool) async throws -> SSHCommand.Result {
                // The id site keeps this function's former name: recordings know their staging folders by it.
                let staging = "upload-" + System.uuid(#fileID, "install(resource:resources:run:)").uuidString.lowercased()
                let script = SSHBootstrapScript.upload(digest: helper.digest, size: helper.size, staging: staging, root: root,
                                                       compressed: compressed)
                let bytes = try helper.archive.map { compressed ? try System.read($0) : try SSHHelperArchive.expand(System.read($0)) }
                    ?? System.read(helper.url)
                return try await run(script, input: bytes)
            }
            // Gzipped where the host can expand it (about half the bytes); sent whole where it cannot.
            var installed = try await send(compressed: helper.archive != nil)
            if helper.archive != nil, installed.status != 0,
               let given = SSHBootstrapScript.reason(String(decoding: installed.output, as: UTF8.self)),
               given == SSHBootstrapScript.noGzip || given == SSHBootstrapScript.gzipFailed {
                SSHSetupLog.uncompressed(given)
                installed = try await send(compressed: false)
            }
            guard installed.status == 0 else {
                let given = SSHBootstrapScript.reason(String(decoding: installed.output, as: UTF8.self))
                let check = SSHBootstrapScript.cacheCheck(size: helper.size, digest: helper.digest, root: root)
                // How a folder that cannot run programs answers once the file is in place (`test -x` asks the kernel).
                if given == "installed helper does not verify",
                   SSHBootstrapScript.blocked(String(decoding: try await run(check).output, as: UTF8.self)) {
                    throw SSHSetupFailure.cannotRun(root, runtimeDirectory: runtimeDirectory)
                }
                throw SSHSetupFailure("Could not install the SSH helper in the remote cache.",
                                      reason: given ?? "the upload failed (\(installed.status))", given: given)
            }
        }

        /// A helper process started over the master through the folded launch, its hello sent, not yet greeted.
        struct Launched {
            let name: String
            let started: HelperSession.Started
            let process: Process
            let errors: SSHHelperErrors
        }
        func begin(_ name: String, _ arguments: String, features: [String]) async throws -> Launched {
            let process = Process(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: master.executable)
            process.arguments = master.arguments(command: launcher.command(arguments))
            process.standardError = errors
            let collected = SSHHelperErrors(errors.fileHandleForReading)
            defer { try? errors.fileHandleForWriting.close() }
            let started = try await HelperSession.start(process: process, features: features)
            return Launched(name: name, started: started, process: process, errors: collected)
        }
        /// Why a launch that ended before it greeted started no helper, from its status and stderr: the folder cannot run
        /// programs (`DISPATCH_NOEXEC`), the cache lacks the host's helper (`Miss`) or the host's platform has none, the
        /// cache cannot be used (the script's reason); else the helper's own end (`SSHSetupFailure.exited`).
        func failure(status: Int32, stderr: String) -> Error {
            if SSHBootstrapScript.blocked(stderr) {
                return SSHSetupFailure.cannotRun(launcher.root, runtimeDirectory: launcher.runtimeDirectory)
            }
            switch SSHBootstrapScript.launchPlatform(stderr) {
            case .helper(let name)?:
                guard let helper = helpers.first(where: { $0.name == name }) else {
                    return SSHSetupFailure.permanent("SSH helper is missing or invalid.", reason: "the bundled helper is missing")
                }
                return Miss(helper: helper)
            case .unsupported?:
                return SSHSetupFailure.permanent("SSH integration requires Linux on ARM64 or x86-64, or macOS on Apple silicon.",
                                                 reason: "unsupported host platform")
            case .unidentified?:
                return SSHSetupFailure.permanent("Could not identify the SSH host platform.", reason: "unknown host platform")
            case nil:
                break
            }
            // Only the launch's own script says `dispatch-setup:`: a cache that is unsafe or cannot be made.
            if status == 1, let reason = SSHBootstrapScript.reason(stderr) {
                return SSHSetupFailure("Could not use the SSH helper cache.", reason: reason, given: reason)
            }
            // At home the runtime folder is not known yet (`launch` asks next): no word about it here.
            return SSHSetupFailure.exited(status: status, stderr: stderr, root: launcher.root,
                                          runtimeDirectory: launcher.runtimeDirectory ?? "")
        }
        /// `launched`'s greeting within the setup's deadline. One that ends before it greets says why (`failure`): its
        /// status and stderr, read only then (`exited`).
        func greet(_ launched: Launched) async throws -> HelperSession {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw timedOut() }
            let started = launched.started
            do {
                return try await SSHTimeout.run(remaining, launched.name) { try await HelperSession(started: started) }
            } catch {
                guard let end = await exited(error, process: launched.process, errors: launched.errors, name: launched.name)
                else { throw error }
                throw failure(status: end.status, stderr: end.stderr)
            }
        }
        /// A helper started afresh through the folded launch; when the cache lacks it, uploaded, then started again.
        func start(_ name: String, _ arguments: String, features: [String]) async throws -> HelperSession {
            do { return try await greet(begin(name, arguments, features: features)) }
            catch let miss as Miss {
                try await upload(miss.helper)
                do { return try await greet(begin(name, arguments, features: features)) }
                catch is Miss {
                    // The upload verified it a moment ago; something changed it since (another upload, a cleanup).
                    throw SSHSetupFailure("Could not install the SSH helper in the remote cache.",
                                          reason: "installed helper does not verify", given: "installed helper does not verify")
                }
            }
        }
        /// The runtime folder, once the home folder proved unable to run programs: only a usable one
        /// (`SSHBootstrapScript.runtimeProbe`) that the grant may use, else that failure. Nothing is written there yet.
        func runtimeLauncher() async throws -> Launcher {
            let probe = try await run(SSHBootstrapScript.runtimeProbe)
            guard probe.status == 0 else {
                throw SSHSetupFailure("Could not use the authenticated SSH connection.", reason: "the host refused commands (\(probe.status))",
                                      given: nil)
            }
            guard let directory = SSHBootstrapScript.runtimeDirectory(String(decoding: probe.output, as: UTF8.self)) else {
                throw SSHSetupFailure.cannotRun(.home, runtimeDirectory: nil)
            }
            guard runtimeAllowed else { throw SSHSetupFailure.hooksNeedHome }
            return Launcher(root: .runtimeDirectory, runtimeDirectory: directory, helpers: helpers)
        }
        /// `start`, once more from the runtime folder after a 126 at home; later attempts start there directly.
        func launch(_ name: String, _ arguments: String, features: [String] = HelperSession.features) async throws -> HelperSession {
            do { return try await start(name, arguments, features: features) }
            catch let failure as SSHSetupFailure where failure.exitStatus == 126 && launcher.root == .home {
                launcher = try await runtimeLauncher()
                return try await start(name, arguments, features: features)
            }
        }

        let connect = "connect --session '" + sessionID + "'"
        guard publish || prepare != nil else {
            let session = try await attempt("connect") { try await launch("session", connect) }
            do { return (try launcher.installed(session.info).path, session) } catch { session.close(); throw error }
        }
        // Verify the greeting before releasing the login: after its user command starts, a bad
        // helper channel cannot safely fall back by starting that command again.
        let features = HelperSession.features + (publish ? [HelperSession.loginRelease] : [])
        let probe = try await attempt("probe") { try await launch("probe", "--remote --capabilities '' --stdio", features: features) }
        defer { probe.close() }
        let installed = try launcher.installed(probe.info)
        try Task.checkCancellation()
        try await prepare?(installed.path, probe.info)
        guard publish else {
            return (installed.path, try await attempt("connect") { try await launch("session", connect) })
        }
        /// The release script over an exec channel of its own (`publish`, the same checks in `/bin/sh`): the step's second
        /// attempt when the probe could not answer (its channel dropped).
        func script() async throws {
            let result = try await run(self.publish(sessionID: sessionID, relativePath: installed.published))
            guard result.status == 0 else {
                let given = SSHBootstrapScript.reason(String(decoding: result.output, as: UTF8.self))
                throw SSHSetupFailure("Could not finish setting up the remote shell.",
                                      reason: given ?? "could not release the login (\(result.status))", given: given)
            }
        }
        // Release through the probe whose greeting was just verified: one request on its channel. The first `connect`
        // starts right after the request is sent, so its channel opens while the login takes the release and starts its
        // bus, which `connect` waits for. Neither can run the user's command: only the released login does, once.
        guard probe.info.ops.contains(HelperSession.loginRelease) else {
            try await attempt("publish", script)
            return (installed.path, try await attempt("connect") { try await launch("session", connect) })
        }
        struct Release: Encodable { let session: String; let path: String }
        let release: HelperConnection.Call<HelperClient.Empty> = await probe.connection.submit(
            HelperSession.loginRelease, params: Release(session: sessionID, path: installed.published))
        let early = try? await begin("session", connect, features: HelperSession.features)
        // Whatever ends this setup before `early` greets (a refused or failed release, a cancellation) ends it too: it
        // would only wait for a bus that never comes. Once it became the session (or failed its greeting), a no-op.
        defer { early?.started.close() }
        do {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw timedOut() }
            _ = try await SSHTimeout.run(remaining, "release") { try await release.value }
        } catch let refused as HelperFailure where refused.code == "unavailable" || refused.code == "invalid_input" {
            // The release's own checks refused (the script's reasons): another attempt fails the same way.
            throw SSHSetupFailure("Could not finish setting up the remote shell.", reason: refused.message, given: refused.message)
        } catch {
            guard again(error) else { throw error }
            SSHSetupLog.retried("publish", SSHSetupFailure.reason(error))
            try await script()
        }
        guard let early else { return (installed.path, try await attempt("connect") { try await launch("session", connect) }) }
        do { return (installed.path, try await greet(early)) } catch {
            guard again(error) else { throw error }
            SSHSetupLog.retried("connect", SSHSetupFailure.reason(error))
            return (installed.path, try await launch("session", connect))
        }
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
    /// Why `run` failed when it ended the command itself.
    static let timedOut = "SSH command cancelled or timed out."
    static func stalled(_ seconds: TimeInterval) -> String {
        "The helper upload stalled: ssh took none of it for \(Int(seconds)) s."
    }
    private final class Lifetime: @unchecked Sendable {
        struct State { var process: Process?; var cancelled = false; var stalled = false }
        let state = OSAllocatedUnfairLock(initialState: State())
        func cancel(stalled: Bool = false) {
            let process = state.withLock {
                $0.cancelled = true
                if stalled { $0.stalled = true }
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
    ///
    /// `stall` paces a command by its `input` rather than by the clock: until the child has taken all of it, the command
    /// fails only when it takes none for `stall` seconds (ssh takes what it can buffer at once, then at the link's pace);
    /// `timeout` starts once it has taken the last byte. Neither is part of the recorded request: a replay answers with
    /// what the capture got, timed out or not.
    static func run(executable: String, arguments: [String], input: Data = Data(), timeout: TimeInterval = 15,
                    stall: TimeInterval? = nil, errors: Bool = false) async throws -> Result {
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
                            defer { deadline.cancel() }
                            var watchdog: DispatchSourceTimer?
                            defer { watchdog?.cancel() }
                            if let stall, !input.isEmpty {
                                let pace = SSHInputPace(stall: stall, now: DispatchTime.now().uptimeNanoseconds)
                                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                                timer.schedule(deadline: .now() + 1, repeating: 1)
                                timer.setEventHandler {
                                    if pace.stalled(at: DispatchTime.now().uptimeNanoseconds) { lifetime.cancel(stalled: true) }
                                }
                                timer.resume()
                                watchdog = timer
                                DispatchQueue.global(qos: .utility).async {
                                    // A pipe holds 64 KiB at most until the child reads: each write that returns is progress.
                                    var offset = input.startIndex
                                    while offset < input.endIndex {
                                        let end = min(input.endIndex, offset + 65_536)
                                        do { try stdin.fileHandleForWriting.write(contentsOf: input[offset..<end]) } catch { break }
                                        offset = end
                                        pace.took(at: DispatchTime.now().uptimeNanoseconds)
                                    }
                                    try? stdin.fileHandleForWriting.close()
                                    pace.finish()
                                    timer.cancel()
                                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                                }
                            } else {
                                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                                DispatchQueue.global(qos: .utility).async {
                                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                                    try? stdin.fileHandleForWriting.close()
                                }
                            }
                            var output = Data()
                            while let bytes = try stdout.fileHandleForReading.read(upToCount: 65_536), !bytes.isEmpty {
                                guard output.count + bytes.count <= 1_048_576 else {
                                    lifetime.cancel(); throw HerdrFailure("SSH command output exceeded its limit.")
                                }
                                output.append(bytes)
                            }
                            process.waitUntilExit()
                            let ended = lifetime.state.withLock { ($0.cancelled, $0.stalled) }
                            guard !ended.0 else { throw HerdrFailure(ended.1 ? stalled(stall ?? 0) : timedOut) }
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

/// How far a child has taken its input (`SSHCommand.run`'s `stall`): stalled once it took nothing for `stall` seconds
/// while some is left. Times are `DispatchTime` uptime nanoseconds.
final class SSHInputPace: @unchecked Sendable {
    private struct State { var last: UInt64; var done = false }
    private let state: OSAllocatedUnfairLock<State>
    private let stall: UInt64

    init(stall: TimeInterval, now: UInt64) {
        self.stall = UInt64(max(0, stall) * 1e9)
        state = OSAllocatedUnfairLock(initialState: State(last: now))
    }

    func took(at now: UInt64) { state.withLock { $0.last = max($0.last, now) } }
    func finish() { state.withLock { $0.done = true } }
    func stalled(at now: UInt64) -> Bool {
        state.withLock { !$0.done && now >= $0.last && now - $0.last >= stall }
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
    static let message = "The remote operation timed out. Its outcome may be uncertain; it was not retried."
    /// The timer is the recording's (System.sleep): a replay times out where its capture did, never on its own clock.
    static func run<Value: Sendable>(_ duration: Duration, _ name: String, _ file: String = #fileID,
                                     operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await System.sleep(for: duration, name, file)
                throw HerdrFailure(message)
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

    nonisolated static func uncompressed(_ reason: String) {
        logger.notice("SSH helper upload sent uncompressed: \(reason, privacy: .public)")
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
