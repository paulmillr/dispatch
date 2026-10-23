import Foundation
import CryptoKit
import XCTest
@testable import DispatchApp

/// The remote setup's shell as the host runs it, beyond its steps one at a time: what no script may contain, every
/// step against the others at the same moment, every external tool failing at each of its first calls, and each login
/// shell sshd may hand the command to. The invariant throughout: the helper starts, or the user's own command runs
/// exactly once after a line that says why; never a hang, never an unverified helper.
final class SSHBootstrapScriptTests: XCTestCase {
    private let session = "0123456789abcdef01234567"
    /// Prints its arguments: what a started login shows.
    private let helper = Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8)
    private var digest: String { SHA256.hash(data: helper).map { String(format: "%02x", $0) }.joined() }
    private var relative: String { SSHBootstrapScript.relativePath(digest: digest) }

    private struct Ran {
        let status: Int32
        let output: String
        let errors: String
        var text: String { output + errors }
    }

    private func temporary() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("dsb-" + String(System.uuid().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// `script` as sshd runs a remote command: the login `shell -c`, which execs `/bin/sh -c` (the master's arguments
    /// and the login's own command both start that way). A plain process: these cases have nothing to record.
    private func run(_ script: String, home: URL, input: Data = Data(), path: String = "/usr/bin:/bin",
                     shell: String = "/bin/sh", timeout: TimeInterval = 15, environment: [String: String] = [:]) throws -> Ran {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        let command = script.hasPrefix("exec /bin/sh -c ") ? script : "exec /bin/sh -c " + HerdrLaunch.quote(script)
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": path, "SHELL": "/bin/sh", "LC_ALL": "C"].merging(environment) { $1 }
        let ran = try TestSupport.live(process, input: input, timeout: timeout)
        XCTAssertFalse(ran.timedOut, "hung past \(timeout) s: \(script.prefix(80))")
        return Ran(status: ran.status, output: String(decoding: ran.output, as: UTF8.self),
                   errors: String(decoding: ran.errors, as: UTF8.self))
    }

    /// `shell` `arguments`, run to its end: its status and standard error.
    private func check(_ shell: String, _ arguments: [String], input: Data = Data()) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        let ran = try TestSupport.live(process, input: input, timeout: 15)
        return (ran.status, String(decoding: ran.output + ran.errors, as: UTF8.self))
    }

    private var scripts: [String: String] {
        [
            "preamble": SSHBootstrapScript.privateDirectoryScript,
            "cache": SSHBootstrapScript.cacheCheck(size: helper.count, digest: digest),
            "upload": SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123"),
            "publish": SSHBootstrap.publish(sessionID: session, relativePath: relative),
            "release": SSHBootstrap.publish(sessionID: session, relativePath: nil, reason: "setup timed out"),
            "login": SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics), command: "exit 3"),
            "runtime cache": SSHBootstrapScript.cachePreamble(digest: digest, root: .runtimeDirectory) + "\n"
                + SSHBootstrapScript.verify(size: helper.count, digest: digest),
            "runtime upload": SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123", root: .runtimeDirectory),
            "runtime probe": SSHBootstrapScript.runtimeProbe,
            "blocked": SSHBootstrapScript.cachePreamble(digest: digest) + "\n" + SSHBootstrapScript.blocked(size: helper.count, digest: digest),
            "runtime launch": runtimeInstalled.command("--remote --capabilities '' --stdio"),
        ]
    }

    private var runtimeInstalled: SSHBootstrap.Installed {
        .init(root: .runtimeDirectory, published: SSHBootstrapScript.relativePath(digest: digest, root: .runtimeDirectory),
              path: "/run/user/1000/" + SSHBootstrapScript.relativePath(digest: digest, root: .runtimeDirectory),
              runtimeDirectory: "/run/user/1000", preamble: SSHBootstrapScript.cachePreamble(digest: digest, root: .runtimeDirectory),
              verify: SSHBootstrapScript.verify(size: helper.count, digest: digest))
    }

    // MARK: What no script may contain

    /// "Check, then create" loses to another Dispatch command creating the same thing at the same moment (the race
    /// behind "mkdir: … File exists" and a plain shell). Folders are created, then checked; files are written under a
    /// unique name and renamed. Every failure in a setup script names its reason.
    func testScriptsNeverCheckThenCreateAndEveryFailureSaysWhy() throws {
        let checkThenCreate = try NSRegularExpression(pattern: #"test\s+(!\s+)?-[eLdf]\s+\S+[^\n]*\|\|[^\n]*\b(mkdir|ln|touch)\b"#)
        for (name, script) in scripts {
            let whole = NSRange(script.startIndex..., in: script)
            XCTAssertNil(checkThenCreate.firstMatch(in: script, range: whole), "\(name) checks, then creates")
            for line in script.split(separator: "\n") where line.contains("mkdir") {
                let creates = line.trimmingCharacters(in: .whitespaces)
                XCTAssertTrue(creates == #"mkdir "$1" 2>/dev/null"# || creates.hasPrefix("mkdir 'upload-") || creates.contains("mkdir -p \"$HOME/"),
                              "\(name): a folder made another way than create, then check: \(creates)")
            }
            if name != "login" {
                XCTAssertFalse(script.contains("|| exit 1"), "\(name): a failure without a reason")
            }
        }
        // The login's own steps run inside `prepare`, which says why; only its outer `cd "$HOME"` may still plainly fail.
        let login = try XCTUnwrap(scripts["login"])
        XCTAssertEqual(login.components(separatedBy: "|| exit 1").count - 1, 1, login)
    }

    /// Every script parses in every POSIX shell a host may have as /bin/sh.
    func testScriptsParseInEveryPosixShell() throws {
        let shells = [["/bin/sh", "-n"], ["/bin/dash", "-n"], ["/bin/bash", "--posix", "-n"], ["/bin/ksh", "-n"]]
            .filter { FileManager.default.isExecutableFile(atPath: $0[0]) }
        XCTAssertFalse(shells.isEmpty)
        for shell in shells {
            for (name, script) in scripts {
                let (status, said) = try check(shell[0], Array(shell.dropFirst()) + ["-c", script])
                XCTAssertEqual(status, 0, "\(name) under \(shell.joined(separator: " ")): \(said)")
            }
        }
        if let shellcheck = ["/opt/homebrew/bin/shellcheck", "/usr/local/bin/shellcheck", "/usr/bin/shellcheck"]
            .first(where: FileManager.default.isExecutableFile) {
            for (name, script) in scripts where name != "login" {
                // SC2046/SC2086: `set -- $(metadata …)` splits on purpose. SC2015: `a && b || fail` is the idiom.
                let (status, said) = try check(shellcheck, ["-s", "sh", "-S", "warning", "-e", "SC2046,SC2086,SC2015", "-"],
                                               input: Data(script.utf8))
                XCTAssertEqual(status, 0, "\(name): \(said)")
            }
        }
    }

    // MARK: At the same moment

    /// Two first connections installing the helper together, and each login racing the publish that releases it, on
    /// fresh homes where no folder exists yet: every one succeeds, many rounds over.
    /// Runs `a` and `b` at the same moment, each on its own thread.
    private func together(_ a: @escaping () throws -> Ran, _ b: @escaping () throws -> Ran) throws -> (Ran, Ran) {
        var results: [Result<Ran, Error>?] = [nil, nil]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let result = Result { try (index == 0 ? a : b)() }
            lock.lock(); results[index] = result; lock.unlock()
        }
        return (try results[0]!.get(), try results[1]!.get())
    }

    func testConcurrentSetupStepsNeverLoseARace() throws {
        let root = try temporary()
        for round in 0..<25 {
            let home = root.appendingPathComponent("h\(round)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            let upload = { (staging: String) in SSHBootstrapScript.upload(digest: self.digest, size: self.helper.count, staging: staging) }
            let (a, b) = try together({ try self.run(upload("upload-a\(round)"), home: home, input: self.helper) },
                                      { try self.run(upload("upload-b\(round)"), home: home, input: self.helper) })
            XCTAssertEqual(a.status, 0, "round \(round): \(a.text)")
            XCTAssertEqual(b.status, 0, "round \(round): \(b.text)")

            // `sessions` does not exist yet: the login and the publish both create it, and the session folder.
            let session = String(format: "%024x", round + 1)
            let login = SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics), command: nil)
            let publish = SSHBootstrap.publish(sessionID: session, relativePath: relative)
            let (shell, release) = try together({ try self.run(login, home: home) }, { try self.run(publish, home: home) })
            XCTAssertEqual(release.status, 0, "round \(round): \(release.text)")
            XCTAssertEqual(shell.output.split(separator: "\n").map(String.init), ["login", "statistics", "--session", session],
                           "round \(round): \(shell.text)")
        }
    }

    // MARK: Every tool failing

    /// The setup as the app runs it, with one external tool failing at its first, second or third call (and `sleep`
    /// instant, so a login nobody releases gives up at once). Each case ends with the helper started, or with the user's
    /// command run once after a line naming a reason; a retry passes what another attempt can fix.
    func testEveryToolFailingFallsBackOnceWithAReason() throws {
        let tools = ["mkdir", "mv", "cat", "chmod", "stat", "wc", "id", "shasum", "sha256sum", "cut", "rm", "tr", "uname"]
            .compactMap { tool in ["/bin/" + tool, "/usr/bin/" + tool].first(where: FileManager.default.isExecutableFile).map { (tool, $0) } }
        XCTAssertGreaterThan(tools.count, 8)
        var outcomes: [String: Int] = [:]
        for (tool, real) in [("none", "")] + tools {
            for call in tool == "none" ? [0] : [1, 2, 3] {
                let home = try temporary()
                let bin = home.appendingPathComponent(".shims")
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
                try System.write(Data("#!/bin/sh\nexit 0\n".utf8), to: bin.appendingPathComponent("sleep"), permissions: 0o755)
                if tool != "none" {
                    let counter = home.appendingPathComponent(".count").path
                    try System.write(Data("""
                    #!/bin/sh
                    n=0; read n < '\(counter)' 2>/dev/null; n=$((n + 1)); printf '%s' "$n" > '\(counter)'
                    test "$n" = \(call) && exit 1
                    exec \(real) "$@"

                    """.utf8), to: bin.appendingPathComponent(tool), permissions: 0o755)
                }
                let path = bin.path + ":/usr/bin:/bin"
                let label = "\(tool) failing at call \(call)"
                // The app's steps (SSHBootstrap.startHelper): a step that failed for a transient reason runs again.
                func step(_ script: String, input: Data = Data()) throws -> Ran {
                    let first = try run(script, home: home, input: input, path: path)
                    guard first.status != 0, SSHBootstrapScript.transient(SSHBootstrapScript.reason(first.output)) else { return first }
                    return try run(script, home: home, input: input, path: path)
                }
                var failure: String?
                let check = try step(scripts["cache"]!)
                if check.status != 0 {
                    if let reason = SSHBootstrapScript.reason(check.output) { failure = reason } else {
                        let upload = try step(SSHBootstrapScript.upload(digest: digest, size: helper.count,
                                                                        staging: "upload-" + System.uuid().uuidString.lowercased()),
                                              input: helper)
                        if upload.status != 0 { failure = SSHBootstrapScript.reason(upload.output) ?? "the upload failed" }
                    }
                }
                if failure == nil {
                    let publish = try step(SSHBootstrap.publish(sessionID: session, relativePath: relative))
                    if publish.status != 0 { failure = SSHBootstrapScript.reason(publish.output) ?? "could not release the login" }
                }
                if let failure { _ = try run(SSHBootstrap.publish(sessionID: session, relativePath: nil, reason: failure), home: home, path: path) }

                let login = try run(SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics),
                                                                     command: "printf 'user command ran\\n'"),
                                    home: home, path: path)
                let started = login.output == "login\nstatistics\n--session\n\(session)\nprintf 'user command ran\\n'\n"
                let ran = login.output.components(separatedBy: "user command ran").count - 1
                let fellBack = login.errors.range(of: #"Dispatch SSH integration unavailable \((.+)\); opening the remote shell"#,
                                                  options: .regularExpression)
                if started {
                    XCTAssertNil(fellBack, "\(label): started and fell back: \(login.text)")
                    outcomes["started", default: 0] += 1
                } else {
                    XCTAssertEqual(ran, 1, "\(label): the user's command must run exactly once: \(login.text)")
                    XCTAssertNotNil(fellBack, "\(label): a fallback without its line: \(login.text)")
                    XCTAssertFalse(login.errors.contains("(unknown reason)"), "\(label): a fallback without a reason: \(login.text)")
                    outcomes["fell back", default: 0] += 1
                }
                if tool == "none" { XCTAssertTrue(started, "nothing failed: \(login.text)") }
            }
        }
        XCTAssertGreaterThan(outcomes["fell back"] ?? 0, 0, "\(outcomes)")
    }

    // MARK: Login shells

    /// sshd hands every remote command to the account's own login shell: bash, zsh, dash and fish where installed all
    /// pass the setup through to /bin/sh unchanged.
    func testEveryLoginShellRunsTheSetup() throws {
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish",
                      "/usr/bin/fish"].filter { FileManager.default.isExecutableFile(atPath: $0) }
        XCTAssertGreaterThan(shells.count, 2)
        for shell in shells {
            let home = try temporary()
            let upload = try run(SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123"),
                                 home: home, input: helper, shell: shell)
            XCTAssertEqual(upload.status, 0, "\(shell): \(upload.text)")
            XCTAssertEqual(try run(SSHBootstrap.publish(sessionID: session, relativePath: relative), home: home, shell: shell).status, 0, shell)
            let login = try run(SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics),
                                                                 command: "printf '%s\\n' \"quoted 'value'\""),
                                home: home, shell: shell)
            XCTAssertEqual(login.output, "login\nstatistics\n--session\n\(session)\nprintf '%s\\n' \"quoted 'value'\"\n", "\(shell): \(login.text)")
            // A release that says why reaches the terminal as it was sent.
            let other = "76543210fedcba9876543210"
            _ = try run(SSHBootstrap.publish(sessionID: other, relativePath: nil, reason: "unsafe folder sessions"), home: home, shell: shell)
            let fallback = try run(SSHLauncherCommand.remoteCommand(sessionID: other, grant: .init(profile: .statistics), command: "exit 7"),
                                   home: home, shell: shell)
            XCTAssertEqual(fallback.status, 7, shell)
            XCTAssertTrue(fallback.errors.contains("Dispatch SSH integration unavailable (unsafe folder sessions); opening the remote shell."),
                          "\(shell): \(fallback.text)")
        }
    }

    // MARK: The runtime folder

    /// A private runtime folder for `home`'s account, as systemd makes `$XDG_RUNTIME_DIR`.
    private func runtime(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(".run")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// The login hand-off accepts a helper the app placed in `$XDG_RUNTIME_DIR/dispatch/bin/versions/<sha256>/` with the
    /// home cache's checks, and execs it by its physical path; without a runtime folder, or with one that is not private,
    /// it falls back with a reason and runs the user's command once. A home path still execs `$HOME/<path>`.
    func testLoginRunsTheHelperFromTheRuntimeFolder() throws {
        let home = try temporary(), runtime = try runtime(in: home)
        let published = SSHBootstrapScript.relativePath(digest: digest, root: .runtimeDirectory)
        XCTAssertEqual(try run(SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123", root: .runtimeDirectory),
                               home: home, input: helper, environment: ["XDG_RUNTIME_DIR": runtime.path]).status, 0)
        XCTAssertFalse(System.exists(home.appendingPathComponent(".dispatch/bin")), "nothing of the helper in the home folder")
        let command = "printf 'user command ran\\n'"
        func login(_ id: String, environment: [String: String]) throws -> Ran {
            XCTAssertEqual(try run(SSHBootstrap.publish(sessionID: id, relativePath: published), home: home).status, 0)
            return try run(SSHLauncherCommand.remoteCommand(sessionID: id, grant: .init(profile: .statistics), command: command),
                           home: home, environment: environment)
        }
        let started = try login(session, environment: ["XDG_RUNTIME_DIR": runtime.path])
        XCTAssertEqual(started.output, "login\nstatistics\n--session\n\(session)\n\(command)\n", started.text)
        for (id, environment, reason) in [("000000000000000000000001", [String: String](), "no runtime folder (XDG_RUNTIME_DIR)"),
                                          ("000000000000000000000002", ["XDG_RUNTIME_DIR": home.appendingPathComponent("none").path],
                                           "cannot enter the runtime folder")] {
            let fallback = try login(id, environment: environment)
            XCTAssertEqual(fallback.output.components(separatedBy: "user command ran").count - 1, 1, fallback.text)
            XCTAssertTrue(fallback.errors.contains("Dispatch SSH integration unavailable (\(reason)); opening the remote shell."), fallback.text)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        let open = try login("000000000000000000000003", environment: ["XDG_RUNTIME_DIR": runtime.path])
        XCTAssertTrue(open.errors.contains("(runtime folder not private)"), open.text)
        // A ready file naming the runtime folder never reaches outside it.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        XCTAssertEqual(try run(SSHBootstrap.publish(sessionID: "000000000000000000000004", relativePath: "dispatch/bin/versions/../../x/dispatch-helper"),
                               home: home).status, 0)
        let escaped = try run(SSHLauncherCommand.remoteCommand(sessionID: "000000000000000000000004", grant: .init(profile: .statistics),
                                                               command: command), home: home, environment: ["XDG_RUNTIME_DIR": runtime.path])
        XCTAssertTrue(escaped.errors.contains("(malformed helper path)"), escaped.text)
    }

    /// `blocked` names only a right 0700 file that `test -x` refuses (this Mac's folders run programs: a shell function
    /// stands in for the kernel's answer on a noexec mount).
    func testBlockedNamesOnlyAFolderThatCannotRunTheHelper() throws {
        let home = try temporary()
        let check = SSHBootstrapScript.cachePreamble(digest: digest) + "\n" + SSHBootstrapScript.blocked(size: helper.count, digest: digest)
        XCTAssertFalse(try run(check, home: home).output.contains("DISPATCH_NOEXEC"), "missing")
        let file = home.appendingPathComponent(relative)
        try System.write(helper, to: file, permissions: 0o600)
        XCTAssertFalse(try run(check, home: home).output.contains("DISPATCH_NOEXEC"), "mode 0600")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertFalse(try run(check, home: home).output.contains("DISPATCH_NOEXEC"), "runs here")
        let refusing = "test() { if [ \"$1\" = -x ]; then return 1; fi; command test \"$@\"; }\n"
        // Dated as it answers: no helper runs from that folder to keep the version from the helpers' cleanup.
        let old = Date(timeIntervalSinceNow: -3 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        XCTAssertTrue(try run(refusing + check, home: home).output.contains("DISPATCH_NOEXEC"), "test -x refuses it")
        let dated = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(dated, Date(timeIntervalSinceNow: -60))
    }

    /// An upload into the runtime folder (which no helper's cleanup visits) removes other versions' folders there that
    /// nothing changed for a day; a recent one stays, and the home root's upload prunes nothing.
    func testRuntimeUploadPrunesOtherOldVersions() throws {
        let home = try temporary(), runtime = try runtime(in: home)
        let versions = runtime.appendingPathComponent("dispatch/bin/versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for folder in [runtime.appendingPathComponent("dispatch"), runtime.appendingPathComponent("dispatch/bin"), versions] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
        let stale = versions.appendingPathComponent(String(repeating: "b", count: 64))
        let recent = versions.appendingPathComponent(String(repeating: "c", count: 64))
        for folder in [stale, recent] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try System.write(Data("old".utf8), to: folder.appendingPathComponent("dispatch-helper"), permissions: 0o700)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 24 * 60 * 60)], ofItemAtPath: stale.path)
        XCTAssertFalse(SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123").contains("find .."))
        let upload = try run(SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123", root: .runtimeDirectory),
                             home: home, input: helper, environment: ["XDG_RUNTIME_DIR": runtime.path])
        XCTAssertEqual(upload.status, 0, upload.text)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: versions.path)), [digest, recent.lastPathComponent])
    }

    /// What a helper that ended before it greeted says, on the Mac's login line and the iPhone alike: whole through
    /// `printable` and within its 160 characters (but what stderr adds).
    func testLaunchFailureTextSurvivesTheLoginLine() {
        var texts = [SSHSetupFailure.hooksNeedHomeReason]
        for root in [SSHBootstrapScript.Root.home, .runtimeDirectory] {
            for runtime in [nil, "/run/user/1000"] {
                for status: Int32? in [nil, 1, 3, 126, 127] {
                    texts.append(SSHBootstrapScript.launchFailure(status: status, stderr: "", root: root, runtimeDirectory: runtime))
                }
            }
        }
        texts.append(SSHBootstrapScript.launchFailure(status: 1, stderr: "dispatch-setup: unsafe folder dispatch\n", root: .home,
                                                      runtimeDirectory: nil))
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            XCTAssertEqual(SSHBootstrapScript.printable(text), text)
        }
        XCTAssertEqual(SSHBootstrapScript.launchFailure(status: 126, stderr: "", root: .home, runtimeDirectory: nil),
                       "The home folder cannot run programs (noexec mount or policy), so the helper cannot start there. "
                       + "No private runtime folder (XDG_RUNTIME_DIR) to use instead.")
        XCTAssertEqual(SSHBootstrapScript.launchFailure(status: 1, stderr: "dispatch-setup: unsafe folder dispatch\n", root: .home,
                                                        runtimeDirectory: nil), "Could not start the helper: unsafe folder dispatch.")
        XCTAssertEqual(SSHBootstrapScript.launchFailure(status: 3, stderr: "\nboom\n", root: .home, runtimeDirectory: nil),
                       "The helper stopped before it answered: boom")
        XCTAssertEqual(SSHBootstrap.hostPath(".dispatch/bin/x", home: "/home/sam"), "/home/sam/.dispatch/bin/x")
        XCTAssertEqual(SSHBootstrap.hostPath("/run/user/1000/dispatch/bin/x", home: "/home/sam"), "/run/user/1000/dispatch/bin/x")
    }

    // MARK: The app's setup against a home folder that cannot run programs

    /// `SSHBootstrap.startHelper` over a stand-in `ssh` that runs each command here with a private home and runtime folder.
    /// `refuseTestX` makes the shell's `test -x` refuse files under ~/.dispatch (as bash and current dash do on a noexec
    /// mount); `helper` is the bundled "helper", a script.
    /// `again`: the same host as an earlier call (its home and runtime folder as that call left them).
    /// `prepare` runs once a probe helper greeted (as the app's reconnect does); a stand-in that never greets fails first.
    private func startHelper(helper body: String, refuseTestX: Bool, runtime: Bool = true, runtimeAllowed: Bool = true,
                             again: URL? = nil, prepare: (@MainActor (String, HelperSession.Info) throws -> Void)? = nil)
        async throws -> (failure: SSHSetupFailure?, home: URL, commands: [String]) {
        let root = try again.map { $0.deletingLastPathComponent() } ?? temporary(), home = root.appendingPathComponent("home")
        let folder = root.appendingPathComponent(".run")
        if again == nil {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            _ = try self.runtime(in: root)
        }
        let log = root.appendingPathComponent("commands")
        try System.write(Data(), to: log)
        let prelude = refuseTestX ? "test() { if [ \"$1\" = -x ]; then case \"$(pwd -P)\" in */.dispatch/*) return 1;; esac; fi; command test \"$@\"; }" : ":"
        let ssh = root.appendingPathComponent("ssh")
        try System.write(Data("""
        #!/bin/sh
        for last; do :; done
        printf '%s\\n--\\n' "$last" >> \(HerdrLaunch.quote(log.path))
        eval "set -- ${last#exec /bin/sh -c }"
        export HOME=\(HerdrLaunch.quote(home.path)) PATH=/usr/bin:/bin\(runtime ? " XDG_RUNTIME_DIR=" + HerdrLaunch.quote(folder.path) : "")
        exec /bin/sh -c \(HerdrLaunch.quote(prelude))"
        $1"

        """.utf8), to: ssh, permissions: 0o700)
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("helper"), withIntermediateDirectories: true)
        try System.write(Data((String(HelperBinary.version) + "\n").utf8), to: resources.appendingPathComponent("helper/protocol-version"),
                         permissions: 0o600)
        try System.write(Data(("#!/bin/sh\n" + body).utf8), to: resources.appendingPathComponent("helper/darwin-arm64"), permissions: 0o700)
        let master = SSHMaster(executable: ssh.path, controlPath: root.appendingPathComponent("control").path, destination: "test")
        var failure: SSHSetupFailure?
        do {
            _ = try await SSHBootstrap.startHelper(master: master, resources: resources, sessionID: session, publish: prepare == nil,
                                                   runtimeAllowed: runtimeAllowed, prepare: prepare)
            XCTFail("the stand-in helper never greets")
        } catch let error as SSHSetupFailure { failure = error } catch is Greeted {}
        let commands = String(decoding: try System.read(log), as: UTF8.self).components(separatedBy: "\n--\n").filter { !$0.isEmpty }
        return (failure, home, commands)
    }

    private struct Greeted: Error {}

    private func launches(_ commands: [String]) -> Int {
        commands.filter { $0.contains("exec ./dispatch-helper --remote") }.count
    }

    /// A helper that ends before it greets with another status than 126 or 127 and no setup reason (`connect` that gave
    /// up waiting for the login's bus on a slow host) is tried once more, as before: the second start greets and the
    /// setup goes on; one that ends so twice falls back with its own words.
    func testHelperEndingOnceForAnotherReasonIsTriedAgain() async throws {
        let helper = try XCTUnwrap(HelperApp.executable).path
        let marker = try temporary().appendingPathComponent("ended")
        let body = "if [ -e \(HerdrLaunch.quote(marker.path)) ]; then exec \(HerdrLaunch.quote(helper)) \"$@\"; fi\n"
            + ": > \(HerdrLaunch.quote(marker.path))\necho 'the login bus did not appear' >&2\nexit 1\n"
        final class Flag: @unchecked Sendable { var raised = false }
        let greeted = Flag()
        let retried = try await startHelper(helper: body, refuseTestX: false) { _, _ in greeted.raised = true; throw Greeted() }
        XCTAssertNil(retried.failure, "\(retried.commands)")
        XCTAssertTrue(greeted.raised)
        XCTAssertEqual(launches(retried.commands), 2)
        let twice = try await startHelper(helper: "echo 'the login bus did not appear' >&2\nexit 1\n", refuseTestX: false)
        XCTAssertEqual(twice.failure?.reason, "The helper stopped before it answered: the login bus did not appear")
        XCTAssertEqual(twice.failure?.permanent, false)
        XCTAssertEqual(twice.failure?.exitStatus, 1)
        XCTAssertEqual(launches(twice.commands), 2, "one more attempt, as before")
    }

    private func uploads(_ commands: [String]) -> [String] {
        commands.filter { $0.contains("mkdir '\\''upload-") || $0.contains("mkdir '\"'\"'upload-") || $0.contains("(set -C; cat >") }
    }

    /// `test -x` refusing the helper at home. A first connection uploads once there (nothing tells a folder that cannot
    /// run programs before its file is there), checks again, then uses the runtime folder (one upload) and starts the
    /// helper from there, whose own failure is the reason. Every later connection: the first check answers
    /// `DISPATCH_NOEXEC`, nothing is uploaded at home, and the runtime folder's copy is reused.
    func testHomeThatCannotRunProgramsUploadsOnceThenUsesTheRuntimeFolder() async throws {
        let (failure, home, commands) = try await startHelper(helper: "echo boom >&2\nexit 3\n", refuseTestX: true)
        XCTAssertEqual(failure?.reason, "The helper stopped before it answered: boom", "\(commands)")
        XCTAssertEqual(failure?.exitStatus, 3)
        XCTAssertEqual(failure?.permanent, false, "an exit for another reason: tried once more")
        XCTAssertEqual(uploads(commands).count, 2, "one upload at home, one in the runtime folder: \(commands)")
        XCTAssertEqual(commands.filter { $0.contains("DISPATCH_RUNTIME=") }.count, 1, "the runtime probe, only after that")
        XCTAssertTrue(System.exists(home.deletingLastPathComponent().appendingPathComponent(".run/dispatch/bin/versions")))
        let again = try await startHelper(helper: "echo boom >&2\nexit 3\n", refuseTestX: true, again: home)
        XCTAssertEqual(again.failure?.reason, "The helper stopped before it answered: boom", "\(again.commands)")
        XCTAssertEqual(uploads(again.commands).count, 0, "\(again.commands)")
        XCTAssertEqual(again.commands.filter { $0.contains("DISPATCH_RUNTIME=") }.count, 1)
    }

    /// The exec refused (126) at home while `test -x` passes: the runtime folder next, once, with the same file.
    func testHelperExitingWith126AtHomeMovesToTheRuntimeFolder() async throws {
        let body = "case \"$(pwd -P)\" in */.dispatch/*) echo 'sh: exec: ./dispatch-helper: Permission denied' >&2; exit 126;; esac\necho boom >&2\nexit 3\n"
        let moved = try await startHelper(helper: body, refuseTestX: false)
        XCTAssertEqual(moved.failure?.reason, "The helper stopped before it answered: boom", "\(moved.commands)")
        XCTAssertEqual(uploads(moved.commands).count, 2)
        // From the runtime folder too: that folder's words.
        let refused = try await startHelper(helper: "echo 'Permission denied' >&2\nexit 126\n", refuseTestX: false)
        XCTAssertEqual(refused.failure?.reason, String(SSHBootstrapScript.folderCannotRunPrograms(.runtimeDirectory).dropLast()))
        XCTAssertEqual(refused.failure?.exitStatus, 126)
    }

    /// No usable runtime folder, or a grant with agent hooks: the plain shell, saying why, with nothing written there.
    func testHomeThatCannotRunProgramsWithoutARuntimeFolderSaysWhy() async throws {
        let none = try await startHelper(helper: "exit 0\n", refuseTestX: true, runtime: false)
        XCTAssertEqual(none.failure?.reason,
                       String(SSHBootstrapScript.launchFailure(status: 126, stderr: "", root: .home, runtimeDirectory: nil).dropLast()),
                       "the login prints it inside parentheses: no full stop")
        XCTAssertEqual(uploads(none.commands).count, 1, "\(none.commands)")
        let again = try await startHelper(helper: "exit 0\n", refuseTestX: true, runtime: false, again: none.home)
        XCTAssertEqual(again.failure?.reason, none.failure?.reason)
        XCTAssertEqual(uploads(again.commands).count, 0, "\(again.commands)")
        let hooks = try await startHelper(helper: "exit 0\n", refuseTestX: true, runtimeAllowed: false)
        XCTAssertEqual(hooks.failure?.reason, SSHSetupFailure.hooksNeedHomeReason)
        XCTAssertEqual(uploads(hooks.commands).count, 1)
        XCTAssertFalse(System.exists(hooks.home.deletingLastPathComponent().appendingPathComponent(".run/dispatch")))
    }

}
