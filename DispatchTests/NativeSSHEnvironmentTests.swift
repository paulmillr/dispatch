import XCTest
@testable import DispatchApp

@MainActor
final class NativeSSHEnvironmentTests: XCTestCase {
    func testNativeZshRetainsUserStartupAndWrapsSSH() async throws {
        let root = URL(fileURLWithPath: "/tmp/native-ssh-\(System.uuid())")
        let first = root.appendingPathComponent("home"), second = root.appendingPathComponent("user-config")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "ZDOTDIR=$DISPATCH_TEST_CONFIG\n".write(to: first.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "export DISPATCH_TEST_PROFILE=profile\n".write(to: second.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try "export DISPATCH_TEST_RC=rc\n".write(to: second.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "export DISPATCH_TEST_LOGIN=login\n".write(to: second.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)
        try NativeSSHEnvironment.install(in: root)
        var environment = System.inherited
        environment.merge(NativeSSHEnvironment.variables(directory: root, inheriting: ["ZDOTDIR": first.path]), uniquingKeysWith: { _, new in new })
        environment["DISPATCH_TEST_CONFIG"] = second.path
        let output = try await command("/bin/zsh", ["-l", "-i", "-c", "print -r -- $DISPATCH_TEST_PROFILE/$DISPATCH_TEST_RC/$DISPATCH_TEST_LOGIN; print -r -- $ZDOTDIR; functions ssh"], environment)
        XCTAssertTrue(output.contains("profile/rc/login"), output)
        XCTAssertTrue(output.contains(second.path), output)
        XCTAssertTrue(output.contains("--ssh-launch"), output)
    }

    /// The up arrow finds earlier commands: history goes to the user's file, not to this launch's startup folder
    /// (macOS's /etc/zshrc names `${ZDOTDIR:-$HOME}/.zsh_history` while ZDOTDIR is still that folder).
    func testNativeZshKeepsHistoryInTheUsersFolder() async throws {
        let root = URL(fileURLWithPath: "/tmp/native-history-\(System.uuid())"), home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try NativeSSHEnvironment.install(in: root)
        var environment = System.inherited
        environment.merge(NativeSSHEnvironment.variables(directory: root, inheriting: ["ZDOTDIR": home.path]), uniquingKeysWith: { _, new in new })
        let history = { try await self.command("/bin/zsh", ["-l", "-i", "-c", "print -r -- HISTFILE=$HISTFILE"], environment) }
        try "".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var output = try await history()
        XCTAssertTrue(output.contains("HISTFILE=" + home.path + "/.zsh_history"), output)
        try "HISTFILE=\(root.path)/chosen\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        output = try await history()
        XCTAssertTrue(output.contains("HISTFILE=" + root.path + "/chosen"), "A HISTFILE the user sets wins: \(output)")
    }

    func testNativeBashImportsPrivateSSHFunction() async throws {
        let environment = System.inherited.merging(NativeSSHEnvironment.variables(directory: URL(fileURLWithPath: "/tmp/native-test"), inheriting: [:]), uniquingKeysWith: { _, new in new })
        let output = try await command("/bin/bash", ["--noprofile", "--norc", "-i", "-c", "type ssh"], environment)
        XCTAssertTrue(output.contains("--ssh-launch"), output)
    }

    func testCommandWrappersPreserveArgumentsInShimsAndInteractiveFunctions() async throws {
        let root = URL(fileURLWithPath: "/tmp/wrappers-\(System.uuid())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("capture ' arguments")
        try "#!/bin/sh\nprintf '%s\\000' \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let arguments = ["", "two words", "single'quote", "$HOME", "$(printf unexpected)", "`printf unexpected`", "line\nbreak", ";"]
        let environment = System.inherited.merging(["DISPATCH_EXECUTABLE": executable.path], uniquingKeysWith: { _, new in new })
        for wrapper in ShellCommandWrapper.allCases {
            let expected = (["--\(wrapper.rawValue)-launch"] + arguments).joined(separator: "\0") + "\0"
            let shim = root.appendingPathComponent(wrapper.rawValue)
            try wrapper.shim(executable: executable.path).write(to: shim, atomically: true, encoding: .utf8)
            let output = try await command("/bin/sh", [shim.path] + arguments, environment)
            XCTAssertEqual(output, expected)
            let script = wrapper.definition() + wrapper.rawValue + " " + arguments.map(HerdrLaunch.quote).joined(separator: " ")
            for shell in ["/bin/bash", "/bin/zsh"] {
                let output = try await command(shell, ["-c", script], environment)
                XCTAssertEqual(output, expected, shell)
            }
        }
    }

    func testWrappersPreserveUserFunctionsAndAliases() async throws {
        for shell in ["/bin/bash", "/bin/zsh"] {
            for name in ["ssh", "codex", "herdr", "tmux"] {
                let definition = ShellCommandWrapper(rawValue: name)?.definition() ?? NativeSSHEnvironment.tmuxFunction(fish: false)
                for setup in ["function \(name) { printf custom; }",
                              "alias \(name)='printf custom'"] {
                    let script = (shell == "/bin/bash" ? "shopt -s expand_aliases\n" : "")
                        + setup + "\n" + definition + "\neval " + name + "\n"
                    let output = try await command(shell, ["-c", script], System.inherited)
                    XCTAssertEqual(output, "custom", "\(shell) \(setup)")
                }
            }
        }
    }

    func testNativeBashRetainsExportedUserFunctionsThroughTmux() async throws {
        let root = URL(fileURLWithPath: "/tmp/exported-functions-\(System.uuid())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A fake tmux observes exactly the environment a new server receives.
        let tmux = root.appendingPathComponent("tmux")
        try "#!/bin/bash\nssh; codex\n".write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmux.path)
        var inherited = System.inherited
        inherited["BASH_FUNC_ssh%%"] = "() { printf custom-ssh; }"
        inherited["BASH_FUNC_codex%%"] = "() { printf custom-codex; }"
        inherited["PATH"] = root.path + ":/usr/bin:/bin"
        inherited["DISPATCH_HERDR_DIRECTORY"] = root.path
        inherited.merge(NativeSSHEnvironment.variables(directory: root, inheriting: inherited), uniquingKeysWith: { _, new in new })
        let script = ShellCommandWrapper.ssh.definition() + ShellCommandWrapper.helper(program: "codex", key: "codex").definition()
            + NativeSSHEnvironment.tmuxFunction(fish: false) + "\ntmux\n"
        let output = try await command("/bin/bash", ["--noprofile", "--norc", "-c", script], inherited)
        XCTAssertEqual(output, "custom-sshcustom-codex")
    }

    func testExecutableLookupHonorsPATHAndSkipsCurrentAndRetiredShims() throws {
        let root = URL(fileURLWithPath: "/tmp/executable-lookup-\(System.uuid())")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["current/bin", "retired/bin", "user/bin", "last/bin"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for wrapper in ShellCommandWrapper.allCases {
            for folder in ["current/bin", "retired/bin", "user/bin", "last/bin"] {
                let path = root.appendingPathComponent(folder + "/" + wrapper.rawValue)
                let shim = folder.hasPrefix("current") || folder.hasPrefix("retired")
                try (shim ? wrapper.shim(executable: "/tmp/Dispatch") : "#!/bin/sh\nexit 0\n")
                    .write(to: path, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
            let environment = ["DISPATCH_HERDR_DIRECTORY": root.appendingPathComponent("current").path,
                               "PATH": ["current/bin", "retired/bin", "user/bin", "last/bin"].map { root.appendingPathComponent($0).path }.joined(separator: ":")]
            XCTAssertEqual(wrapper.executable(in: environment), root.appendingPathComponent("user/bin/" + wrapper.rawValue).path)
            XCTAssertNil(wrapper.executable(in: ["PATH": root.appendingPathComponent("retired/bin").path]))
        }
    }

    func testNativeTerminalLeavesSudoUnwrapped() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(app.runtime.views[id])
        TerminalTestSupport.send("whence -w sudo", to: terminal)
        try await app.wait { terminal.agentMenuScreen.contains("sudo: command") }
        XCTAssertFalse(terminal.agentMenuScreen.contains("sudo: function"))
    }

    func testSSHLauncherUsesPATHAndRetainsExplicitExecutable() async throws {
        let root = URL(fileURLWithPath: "/tmp/ssh-path-\(System.uuid())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ssh = root.appendingPathComponent("ssh"), override = root.appendingPathComponent("other-ssh")
        try "#!/bin/sh\nprintf '%s\\000' \"$@\"\n".write(to: ssh, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf override\n".write(to: override, atomically: true, encoding: .utf8)
        for file in [ssh, override] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        var environment = System.inherited
        environment.removeValue(forKey: "DISPATCH_SSH_EXECUTABLE")
        environment["PATH"] = root.path + ":/usr/bin:/bin"
        let executable = System.executable.path
        let arguments = ["-V", "two words", "$HOME", ""]
        let output = try await command(executable, ["--ssh-launch"] + arguments, environment)
        XCTAssertEqual(output, arguments.joined(separator: "\0") + "\0")
        environment["DISPATCH_SSH_EXECUTABLE"] = override.path
        let explicit = try await command(executable, ["--ssh-launch", "-V"], environment)
        XCTAssertEqual(explicit, "override")
    }

    /// Real shells, in replay too (TestSupport.live).
    private func command(_ executable: String, _ arguments: [String], _ environment: [String: String]) async throws -> String {
        try await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.environment = environment
            process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
            let exit = try TestSupport.live(process), text = String(decoding: exit.output, as: UTF8.self)
            guard exit.status == 0 else { throw HerdrFailure(text) }
            return text
        }.value
    }
}
