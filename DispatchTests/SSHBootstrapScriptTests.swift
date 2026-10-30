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
            "compressed upload": SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123", compressed: true),
            "publish": SSHBootstrap.publish(sessionID: session, relativePath: relative),
            "release": SSHBootstrap.publish(sessionID: session, relativePath: nil, reason: "setup timed out"),
            "login": SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics), command: "exit 3"),
            "runtime cache": SSHBootstrapScript.cachePreamble(digest: digest, root: .runtimeDirectory) + "\n"
                + SSHBootstrapScript.verify(size: helper.count, digest: digest),
            "runtime upload": SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123", root: .runtimeDirectory),
            "runtime probe": SSHBootstrapScript.runtimeProbe,
            "blocked": SSHBootstrapScript.cachePreamble(digest: digest) + "\n" + SSHBootstrapScript.blocked(size: helper.count, digest: digest),
            "launch": launcher(.home).command(probeArguments, export: ""),
            "runtime launch": launcher(.runtimeDirectory).command(probeArguments, export: ""),
        ]
    }

    private let probeArguments = "--remote --capabilities '' --stdio"

    /// The app's launcher for this test's helper, as the bundled one for this Mac (`others`: the bundle's other platforms).
    private func launcher(_ root: SSHBootstrapScript.Root, others: Bool = true, this: Bool = true) -> SSHBootstrap.Launcher {
        let other = { (name: String, fill: Character) in
            SSHBootstrap.Bundled(name: name, url: URL(fileURLWithPath: "/nonexistent/" + name), archive: nil, size: 3,
                                 digest: String(repeating: fill, count: 64))
        }
        return .init(root: root, runtimeDirectory: root == .home ? nil : "/run/user/1000",
                     helpers: (this ? [SSHBootstrap.Bundled(name: "darwin-arm64", url: URL(fileURLWithPath: "/nonexistent"), archive: nil,
                                                            size: helper.count, digest: digest)] : [])
                        + (others ? [other("linux-aarch64", "b"), other("linux-x86_64", "c")] : []))
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
                // The probe's folded launch: the stand-in helper greets by printing its arguments.
                let launch = scripts["launch"]!
                func greeted(_ ran: Ran) -> Bool { ran.status == 0 && ran.output.hasPrefix("--remote\n") }
                /// Why a launch started no helper, as the app reads its stderr (nil: the cache lacks it).
                func refusal(_ ran: Ran) -> String? {
                    if SSHBootstrapScript.blocked(ran.errors) { return "cannot run programs" }
                    switch SSHBootstrapScript.launchPlatform(ran.errors) {
                    case .helper?: return nil
                    case .unsupported?, .unidentified?: return "unsupported host platform"
                    case nil: return SSHBootstrapScript.reason(ran.errors) ?? "the helper stopped before it answered"
                    }
                }
                var probe = try run(launch, home: home, path: path)
                if !greeted(probe) {
                    if let reason = refusal(probe) { failure = reason } else {
                        let upload = try step(SSHBootstrapScript.upload(digest: digest, size: helper.count,
                                                                        staging: "upload-" + System.uuid().uuidString.lowercased()),
                                              input: helper)
                        if upload.status != 0 { failure = SSHBootstrapScript.reason(upload.output) ?? "the upload failed" } else {
                            probe = try run(launch, home: home, path: path)
                            if !greeted(probe) { failure = refusal(probe) ?? "installed helper does not verify" }
                        }
                    }
                }
                // The release: the probe's login.release runs these checks without tools; this script is its fallback.
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

    /// An upload the waiting login sees for 10 s (50 polls) draws one progress line on the terminal, redrawn in place
    /// and erased when the upload ends; a shorter one draws nothing. The stand-in `sleep` returns at once, receives 43 000
    /// bytes a poll and ends the upload after `polls` polls; the stand-in `date` is a 5-poll second, so the speed is
    /// 215 000 bytes a second. The login then times out and runs the user's command, as without a release.
    func testWaitingLoginShowsAnUploadOnlyPastTenSeconds() throws {
        for (polls, shown) in [(40, false), (70, true)] {
            let home = try temporary()
            var folder = home
            for name in [".dispatch", "bin", "versions", digest, "upload-0123"] {
                folder.appendPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try System.write(Data("3145728\n".utf8), to: folder.appendingPathComponent("size"), permissions: 0o600)
            try System.write(Data(), to: folder.appendingPathComponent("dispatch-helper"), permissions: 0o600)
            let bin = home.appendingPathComponent(".shims")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
            let counter = home.appendingPathComponent(".count").path
            try System.write(Data("""
            #!/bin/sh
            n=0; read n < '\(counter)' 2>/dev/null; n=$((n + 1)); printf '%s' "$n" > '\(counter)'
            test "$n" = \(polls) && rm -rf '\(folder.path)'
            test -d '\(folder.path)' && head -c 43000 /dev/zero >> '\(folder.path)/dispatch-helper'
            exit 0

            """.utf8), to: bin.appendingPathComponent("sleep"), permissions: 0o755)
            try System.write(Data("#!/bin/sh\nn=0; read n < '\(counter)' 2>/dev/null; echo $((n / 5))\n".utf8),
                             to: bin.appendingPathComponent("date"), permissions: 0o755)
            let login = try run(SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics), command: "exit 3"),
                                home: home, path: bin.path + ":/usr/bin:/bin")
            XCTAssertEqual(login.status, 3, login.text)
            XCTAssertTrue(login.errors.contains("Dispatch SSH integration unavailable"), login.text)
            let frames = login.errors.components(separatedBy: "Installing Dispatch").count - 1
            guard shown else { XCTAssertEqual(frames, 0, login.text); continue }
            // Polls 50 through 69 drew; the 70th found the upload gone and erased the line.
            XCTAssertEqual(frames, polls - 50, login.text)
            let plain = login.errors.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            // The first line drawn, at poll 50: 2 150 000 of 3 145 728 bytes, 995 728 left at 215 000 a second.
            XCTAssertTrue(plain.contains("Installing Dispatch ━━━━━━━━━━──────  68%  2.0 of 3.0 MB · 209 KB/s · 4 s"), plain)
            let erased = try XCTUnwrap(login.errors.range(of: "\r\u{1b}[K", options: .backwards))
            XCTAssertFalse(login.errors[erased.upperBound...].contains("Installing"), "the last line drawn is erased")
            XCTAssertLessThan(erased.lowerBound, try XCTUnwrap(login.errors.range(of: "Dispatch SSH integration unavailable")).lowerBound)
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

    /// `data` as `gzip -9` writes it; `named` keeps the file name in the header (FNAME), as `gzip` without `-n` does.
    private func gzipped(_ data: Data, named: Bool = false) throws -> Data {
        let folder = try temporary(), file = folder.appendingPathComponent("helper")
        try System.write(data, to: file, permissions: 0o600)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = named ? ["-9", "-c", file.path] : ["-9", "-n", "-c", file.path]
        let ran = try TestSupport.live(process, input: Data(), timeout: 15)
        XCTAssertEqual(ran.status, 0)
        return ran.output
    }

    /// A gzipped upload: expanded by the host's `gzip`, then checked like any other. A host without `gzip` says so before
    /// it reads anything, and one whose `gzip` cannot expand what arrived says that; either way nothing is left behind and
    /// the app's uncompressed upload that follows installs the helper.
    func testCompressedUploadExpandsOrSaysWhyTheFullHelperFollows() throws {
        let compressed = try gzipped(helper)
        let installed = try temporary()
        let upload = try run(SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123", compressed: true),
                             home: installed, input: compressed)
        XCTAssertEqual(upload.status, 0, upload.text)
        XCTAssertEqual(try System.read(installed.appendingPathComponent(relative)), helper)

        // Every tool the scripts use but gzip.
        let home = try temporary(), bin = home.appendingPathComponent(".tools")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        for folder in ["/bin", "/usr/bin"] {
            for tool in try FileManager.default.contentsOfDirectory(atPath: folder) where tool != "gzip"
                && !FileManager.default.fileExists(atPath: bin.appendingPathComponent(tool).path) {
                try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(tool).path, withDestinationPath: folder + "/" + tool)
            }
        }
        let missing = try run(SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123", compressed: true),
                              home: home, input: compressed, path: bin.path)
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertEqual(SSHBootstrapScript.reason(missing.output), SSHBootstrapScript.noGzip, missing.text)
        let full = try run(SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-4567"), home: home,
                           input: helper, path: bin.path)
        XCTAssertEqual(full.status, 0, full.text)

        let broken = try temporary()
        let garbled = try run(SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123", compressed: true),
                              home: broken, input: helper)
        XCTAssertEqual(SSHBootstrapScript.reason(garbled.output), SSHBootstrapScript.gzipFailed, garbled.text)
        let versions = broken.appendingPathComponent(".dispatch/bin/versions/" + digest)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: versions.path), [], "the staging folder is removed")
        XCTAssertFalse(SSHBootstrapScript.transient(SSHBootstrapScript.noGzip))
        XCTAssertFalse(SSHBootstrapScript.transient(SSHBootstrapScript.gzipFailed))
        XCTAssertEqual(SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123", compressed: false),
                       SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123"))
    }

    /// The bundled archive as the app expands it for a host without gzip: what `gzip` wrote, with or without a name in
    /// its header; anything else is refused.
    func testHelperArchiveExpandsWhatGzipWrote() throws {
        let data = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) } + Array(repeating: 7, count: 50_000))
        XCTAssertEqual(try SSHHelperArchive.expand(gzipped(data)), data)
        XCTAssertEqual(try SSHHelperArchive.expand(gzipped(data, named: true)), data)
        XCTAssertThrowsError(try SSHHelperArchive.expand(data))
        var truncated = try gzipped(data)
        truncated.removeSubrange(truncated.count / 2 ..< truncated.count - 8)
        XCTAssertThrowsError(try SSHHelperArchive.expand(truncated))
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
                             again: URL? = nil, sessionID: String? = nil, released: Bool = false,
                             prepare: (@MainActor (String, HelperSession.Info) throws -> Void)? = nil)
        async throws -> (failure: SSHSetupFailure?, home: URL, commands: [String]) {
        let root = try again.map { $0.deletingLastPathComponent() } ?? temporary(), home = root.appendingPathComponent("home")
        let folder = root.appendingPathComponent(".run")
        let session = sessionID ?? self.session
        if again == nil {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            _ = try self.runtime(in: root)
        }
        if released {
            // Another release got there first: the login's session folder already names a helper.
            var sessions = home
            for name in [".dispatch", "sessions", session] {
                sessions.appendPathComponent(name)
                try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try System.write(Data("elsewhere\n".utf8), to: sessions.appendingPathComponent("ready"), permissions: 0o600)
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
        } catch let error as SSHSetupFailure { failure = error } catch is Greeted {
        } catch where released || sessionID != nil {
            // `connect` finds no login here: how it fails is the caller's to check (the commands).
        }
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
        // The first launch finds the cache empty and starts nothing (the upload follows), the second ends, the third greets.
        XCTAssertEqual(launches(retried.commands), 3)
        XCTAssertEqual(uploads(retried.commands).count, 1)
        let twice = try await startHelper(helper: "echo 'the login bus did not appear' >&2\nexit 1\n", refuseTestX: false)
        XCTAssertEqual(twice.failure?.reason, "The helper stopped before it answered: the login bus did not appear")
        XCTAssertEqual(twice.failure?.permanent, false)
        XCTAssertEqual(twice.failure?.exitStatus, 1)
        XCTAssertEqual(launches(twice.commands), 3, "one more attempt after the upload's, as before")
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

extension SSHBootstrapScriptTests {
    /// The Mac's folded launch (`SSHBootstrapScript.launch`): the platform probe and the cache check in the helper's own
    /// exec channel. It starts the cached helper with stdout its own; otherwise it starts nothing, writes nothing on
    /// stdout (the client's frame stream) and says why on stderr: the platform for a cache that lacks the helper (the
    /// app uploads it, then launches again) or for a platform no bundled helper serves, `DISPATCH_NOEXEC` for a folder
    /// that cannot run it, or the private-folder checks' reason.
    func testFoldedLaunchStartsTheCachedHelperOrSaysWhy() throws {
        let home = try temporary()
        let launch = launcher(.home).command(probeArguments, export: "")
        let missing = try run(launch, home: home)
        XCTAssertEqual(missing.status, 3, missing.text)
        XCTAssertEqual(missing.output, "", "nothing on the frame stream")
        XCTAssertEqual(SSHBootstrapScript.launchPlatform(missing.errors), .helper("darwin-arm64"), missing.text)
        XCTAssertFalse(SSHBootstrapScript.blocked(missing.errors))

        XCTAssertEqual(try run(SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123"),
                               home: home, input: helper).status, 0)
        let started = try run(launch, home: home)
        XCTAssertEqual(started.status, 0, started.text)
        XCTAssertEqual(started.output, "--remote\n--capabilities\n\n--stdio\n", "the helper's stdout is the channel's")
        XCTAssertEqual(started.errors, "")
        // A damaged copy of the same size is a miss, never started.
        let file = home.appendingPathComponent(relative)
        try System.write(Data(repeating: 0x23, count: helper.count), to: file, permissions: 0o700)
        let damaged = try run(launch, home: home)
        XCTAssertEqual(SSHBootstrapScript.launchPlatform(damaged.errors), .helper("darwin-arm64"), damaged.text)
        XCTAssertEqual(damaged.output, "")
        try System.write(helper, to: file, permissions: 0o700)

        // This Mac's platform without a bundled helper: its name, which the app reads as the bundled helper missing.
        let unbundled = try run(launcher(.home, this: false).command(probeArguments, export: ""), home: home)
        XCTAssertEqual(unbundled.status, 3)
        XCTAssertEqual(SSHBootstrapScript.launchPlatform(unbundled.errors), .helper("darwin-arm64"), unbundled.text)
        let none = try run(launcher(.home, others: false, this: false).command(probeArguments, export: ""), home: home)
        XCTAssertEqual(SSHBootstrapScript.launchPlatform(none.errors), .helper("darwin-arm64"), none.text)
        XCTAssertEqual(SSHBootstrapScript.launchPlatform("DISPATCH_PLATFORM=Unknown:mips\n"), .unsupported)
        XCTAssertNil(SSHBootstrapScript.launchPlatform("boom\n"))

        // test -x refused, as on a noexec mount.
        let refusing = "test() { if [ \"$1\" = -x ]; then return 1; fi; command test \"$@\"; }\n"
        let blocked = try run(refusing + launch, home: home)
        XCTAssertTrue(SSHBootstrapScript.blocked(blocked.errors), blocked.text)
        XCTAssertEqual(blocked.output, "")

        // An unsafe home: the script's reason, on stderr only.
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: home.path)
        let unsafe = try run(launch, home: home)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        XCTAssertEqual(unsafe.status, 1)
        XCTAssertEqual(unsafe.output, "")
        XCTAssertEqual(SSHBootstrapScript.reason(unsafe.errors), "home folder writable by others")
        XCTAssertNil(SSHBootstrapScript.launchPlatform(unsafe.errors))

        // The runtime folder's launch, from where its upload put the helper.
        let runtime = try self.runtime(in: home)
        let environment = ["XDG_RUNTIME_DIR": runtime.path]
        let runtimeLaunch = launcher(.runtimeDirectory).command(probeArguments, export: "")
        XCTAssertEqual(SSHBootstrapScript.launchPlatform(try run(runtimeLaunch, home: home, environment: environment).errors),
                       .helper("darwin-arm64"))
        XCTAssertEqual(try run(SSHBootstrapScript.upload(digest: digest, size: helper.count, staging: "upload-0123", root: .runtimeDirectory),
                               home: home, input: helper, environment: environment).status, 0)
        XCTAssertEqual(try run(runtimeLaunch, home: home, environment: environment).output, "--remote\n--capabilities\n\n--stdio\n")
        XCTAssertEqual(SSHBootstrap.helperName(os: "macos", arch: "aarch64"), "darwin-arm64")
        XCTAssertEqual(SSHBootstrap.helperName(os: "linux", arch: "x86_64"), "linux-x86_64")
        XCTAssertEqual(SSHBootstrap.helperName(os: "linux", arch: "aarch64"), "linux-aarch64")
        XCTAssertNil(SSHBootstrap.helperName(os: "macos", arch: "x86_64"))
    }

    /// Processes running a helper `connect` for `session` (the stand-in `ssh` execs the helper with these arguments).
    private static func connecting(_ session: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "dispatch-helper connect --session " + session]
        let ran = try TestSupport.live(process, input: Data(), timeout: 15)
        return String(decoding: ran.output, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Within 2.5 s no `connect` for `session` runs (its own wait for a bus would last 5 s).
    @MainActor private static func noneConnecting(_ session: String) async throws {
        try await TestSupport.eventually(timeout: .milliseconds(2500), interval: .milliseconds(200)) {
            (try? connecting(session).isEmpty) == true
        }
    }

    /// Within 2.5 s the stand-in `ssh` at `log` ran a command holding `text`.
    @MainActor private static func logged(_ log: URL, _ text: String) async throws {
        try await TestSupport.eventually(timeout: .milliseconds(2500), interval: .milliseconds(100)) {
            String(decoding: (try? System.read(log)) ?? Data(), as: UTF8.self).contains(text)
        }
    }

    /// The app releases a waiting login through its verified probe (`login.release`), never with the publish script's
    /// exec channel, and `connect` starts as the release is sent. A refused release (the session was released already)
    /// fails the setup with the release's own reason, does not run the script, and leaves no `connect` waiting for a bus.
    func testTheProbeReleasesTheLoginAndARefusedReleaseLeavesNothingRunning() async throws {
        let helper = try XCTUnwrap(HelperApp.executable).path
        let body = "exec \(HerdrLaunch.quote(helper)) \"$@\"\n"
        let released = "00000000000000000000beef"
        let refused = try await startHelper(helper: body, refuseTestX: false, sessionID: released, released: true)
        XCTAssertEqual(refused.failure?.reason, "session already released", "\(refused.commands)")
        XCTAssertEqual(refused.failure?.permanent, false)
        XCTAssertFalse(refused.commands.contains { $0.contains("ready.$$") }, "no publish script: \(refused.commands)")
        XCTAssertEqual(refused.commands.filter { $0.contains("exec ./dispatch-helper --remote") }.count, 2, "a miss, then the probe")
        // The connect started with the release (its stand-in `ssh` logs it moments after the setup returned).
        try await Self.logged(refused.home.deletingLastPathComponent().appendingPathComponent("commands"), "dispatch-helper connect --session")
        // Its own wait for the bus would last 5 s: closed with the setup, it is gone well before.
        try await Self.noneConnecting(released)
        XCTAssertEqual(try System.read(refused.home.appendingPathComponent(".dispatch/sessions/" + released + "/ready")),
                       Data("elsewhere\n".utf8), "nothing written over the other release")

        // Released: `ready` names the cached helper, written by the probe (no script ran); the connect then waits for a
        // login that never comes here, and fails on its own.
        let fresh = "00000000000000000000cafe"
        let warm = try await startHelper(helper: body, refuseTestX: false, sessionID: fresh)
        XCTAssertFalse(warm.commands.contains { $0.contains("ready.$$") }, "no publish script: \(warm.commands)")
        XCTAssertEqual(warm.commands.filter { $0.contains("exec ./dispatch-helper --remote") }.count, 2, "a miss, then the probe")
        let bundled = SHA256.hash(data: Data(("#!/bin/sh\n" + body).utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(String(decoding: try System.read(warm.home.appendingPathComponent(".dispatch/sessions/" + fresh + "/ready")),
                              as: UTF8.self), SSHBootstrapScript.relativePath(digest: bundled) + "\n")
        try await Self.noneConnecting(fresh)
    }
}
