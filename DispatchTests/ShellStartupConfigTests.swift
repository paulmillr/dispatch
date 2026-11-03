import TermApple
import XCTest
@testable import DispatchApp

/// Custom shell configurations the 2026-10-31 audit found broken (test/shell-config-audit.py runs the same cases
/// against real Bash, Zsh and Fish binaries).
@MainActor
final class ShellStartupConfigTests: XCTestCase {
    private func launch(_ command: String, resources: String? = System.resources.appendingPathComponent("ghostty").path) throws -> Launch {
        try Launch(command: command, directory: nil, overrides: [], config: SwiftEngine.parse("", dark: true),
                   environment: ["HOME": "/tmp/shell-config-home", "PATH": "/usr/bin:/bin"], machine: System.machine.launch,
                   resources: resources, id: 1)
    }

    /// S1: Apple's /bin/bash gets no Ghostty integration, so the helper must not be told its startup files are covered.
    func testLaunchReportsIntegrationOnlyWhenGhosttyInjectsIt() throws {
        XCTAssertTrue(try launch("/bin/zsh").integrated)
        XCTAssertTrue(try launch("/opt/example/bin/bash -il").integrated)
        XCTAssertFalse(try launch("/bin/bash").integrated)
        XCTAssertFalse(try launch("/bin/sh").integrated)
        XCTAssertFalse(try launch("/opt/example/bin/bash -c true").integrated)
        XCTAssertFalse(try launch("/bin/zsh", resources: nil).integrated)
    }

    /// S5: the bash command integration rebuilds keeps each word's own text: a quoted path stays one word, and `$VAR`,
    /// `~` and globs still expand in the shell that runs it, as in Ghostty's unquoted join.
    func testLaunchKeepsTheTextOfTheArgumentsItRebuilds() throws {
        XCTAssertEqual(try launch("/opt/example/bin/bash -il").command, "/opt/example/bin/bash --posix -il")
        XCTAssertEqual(try launch(#""/opt/some directory/bash" -il"#).command, #""/opt/some directory/bash" --posix -il"#)
        XCTAssertEqual(try launch(#"/opt/example/bin/bash -i -- "it's two""#).command, #"/opt/example/bin/bash --posix -i -- "it's two""#)
        XCTAssertEqual(try launch("$HOME/bin/bash -l").command, "$HOME/bin/bash --posix -l")
        XCTAssertEqual(try launch("~/bin/bash").command, "~/bin/bash --posix")
        XCTAssertEqual(Launch.words(#""/opt/some directory/bash" -il"#).first, "/opt/some directory/bash")
    }

    /// S5: SHELL for a Settings shell command is its shell, past `env` and assignments; a program is not a shell.
    func testSettingsShellCommandNamesItsShell() {
        XCTAssertEqual(HelperWorkspace.shellExecutable(#""/opt/some directory/bash" -il"#), "/opt/some directory/bash")
        XCTAssertEqual(HelperWorkspace.shellExecutable("env FOO=1 -u BAR /opt/example/bin/zsh -l"), "/opt/example/bin/zsh")
        XCTAssertEqual(HelperWorkspace.shellExecutable("LANG=C fish"), "fish")
        XCTAssertNil(HelperWorkspace.shellExecutable("htop"))
        XCTAssertNil(HelperWorkspace.shellExecutable("env"))
        XCTAssertNil(HelperWorkspace.shellExecutable(""))
        XCTAssertNil(HelperWorkspace.shellExecutable("   "))
    }

    /// S2, S6: fish wrappers are autoload files, read only when nothing the user set up defines the name; nothing is
    /// defined from vendor_conf.d, which runs before config.fish.
    func testFishWrappersAreAutoloadFiles() throws {
        let root = URL(fileURLWithPath: "/tmp/fish-wrappers-\(System.uuid())")
        defer { try? FileManager.default.removeItem(at: root) }
        try NativeSSHEnvironment.install(in: root, functions: [.ssh, .helper(program: "codex", key: "codex")])
        let functions = root.appendingPathComponent("native/share/fish/vendor_functions.d")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: functions.path).sorted(), ["codex.fish", "ssh.fish", "tmux.fish"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("native/share/fish/vendor_conf.d").path))
        let ssh = try String(contentsOf: functions.appendingPathComponent("ssh.fish"), encoding: .utf8)
        XCTAssertEqual(ssh, "function ssh\n command $DISPATCH_EXECUTABLE '--ssh-launch' $argv\nend\n")
        let tmux = try String(contentsOf: functions.appendingPathComponent("tmux.fish"), encoding: .utf8)
        XCTAssertTrue(tmux.contains("(string join : -- $XDG_DATA_DIRS)"), tmux)
    }

    /// S4: a user file that unsets ZDOTDIR under nounset still gets the wrappers, and later files come from HOME.
    func testNativeZshSurvivesAnUnsetZdotdirUnderNounset() async throws {
        for name in [".zshenv", ".zshrc", ".zlogin"] {
            let root = URL(fileURLWithPath: "/tmp/native-nounset-\(System.uuid())"), home = root.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
                let setup = file == name ? "unset ZDOTDIR\nsetopt nounset\n" : ""
                try (setup + "print -r -- USER\(file)\n").write(to: home.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
            try NativeSSHEnvironment.install(in: root)
            var environment = System.inherited
            environment["HOME"] = home.path
            environment.merge(NativeSSHEnvironment.variables(directory: root, inheriting: ["ZDOTDIR": home.path]), uniquingKeysWith: { _, new in new })
            let output = try await zsh(["-l", "-i", "-c", "functions ssh"], environment)
            // The system's /etc/zshrc may trip over nounset itself (an unset terminfo key); the wrappers must not.
            XCTAssertFalse(output.contains("ZDOTDIR: parameter not set"), "\(name): \(output)")
            for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] { XCTAssertTrue(output.contains("USER" + file), "\(name): \(output)") }
            XCTAssertTrue(output.contains("--ssh-launch"), "\(name): \(output)")
        }
    }

    /// Real zsh, in replay too (TestSupport.live).
    private func zsh(_ arguments: [String], _ environment: [String: String]) async throws -> String {
        try await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = arguments; process.environment = environment
            process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
            let exit = try TestSupport.live(process)
            return String(decoding: exit.output, as: UTF8.self)
        }.value
    }
}
