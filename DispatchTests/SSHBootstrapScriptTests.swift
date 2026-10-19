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
                     shell: String = "/bin/sh", timeout: TimeInterval = 15) throws -> Ran {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        let command = script.hasPrefix("exec /bin/sh -c ") ? script : "exec /bin/sh -c " + HerdrLaunch.quote(script)
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": path, "SHELL": "/bin/sh", "LC_ALL": "C"]
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
            "cache": SSHBootstrapScript.cachePreamble(digest: digest) + "\n" + SSHBootstrapScript.verify(size: helper.count, digest: digest),
            "upload": SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123"),
            "publish": SSHBootstrap.publish(sessionID: session, relativePath: relative),
            "release": SSHBootstrap.publish(sessionID: session, relativePath: nil, reason: "setup timed out"),
            "login": SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics), command: "exit 3"),
        ]
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
}
