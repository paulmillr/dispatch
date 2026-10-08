import AppKit
import TermApple
import XCTest
@testable import DispatchApp

/// The test host is the app itself: what its stores and agent setups write (Dispatch's own files,
/// the hooks that Codex, Claude and Pi load) must stay away from the user's files while testing.
@MainActor
final class AppFilesTests: XCTestCase {
    func testExplicitTerminalHomeOverridesRemainLiteral() throws {
        func launch(_ overrides: [(String, String)]) throws -> Launch {
            try Launch(command: "/bin/zsh", directory: nil, overrides: overrides, config: SwiftEngine.parse("", dark: true),
                       environment: ["HOME": "/inherited"], resources: nil, id: 1)
        }
        let base = try launch([])
        XCTAssertFalse(base.argv.contains("/usr/bin/env"))
        let position = try XCTUnwrap(base.argv.firstIndex(of: "/bin/bash"))
        for home in ["", "/a home/it's literal/$value", "/unicode/λ", "/last"] {
            let actual = try launch([("HOME", "/ignored"), ("HOME", home)])
            var argv = base.argv, environment = base.env
            argv.insert(contentsOf: ["/usr/bin/env", "HOME=" + home], at: position)
            environment["HOME"] = home
            XCTAssertEqual(actual.argv, argv)
            XCTAssertEqual(actual.env, environment)
            XCTAssertEqual(actual.directory, base.directory)
        }
    }

    /// Resources live under /tmp, where a TERMINFO beside them could be planted by any user: only
    /// Ghostty's own entry looks there. Dispatch's xterm-256color uses the system database.
    func testTerminfoBesideResourcesServesOnlyGhosttysEntry() throws {
        func launch(_ term: String) throws -> Launch {
            try Launch(command: "/bin/zsh", directory: nil, overrides: [], config: SwiftEngine.parse("term = " + term, dark: true),
                       environment: ["HOME": "/inherited", "TERMINFO": "/inherited/terminfo"], resources: "/tmp/dispatch-resources/ghostty", id: 1)
        }
        XCTAssertEqual(try launch("xterm-ghostty").env["TERMINFO"], "/tmp/dispatch-resources/terminfo")
        let system = try launch("xterm-256color")
        XCTAssertEqual(system.env["TERM"], "xterm-256color")
        XCTAssertNil(system.env["TERMINFO"])
    }

    /// zsh's integration takes over ZDOTDIR; its bundled .zshenv must hand the user's startup
    /// files back, or local terminals start with zsh's bare prompt.
    func testBundledZshIntegrationSourcesTheUsersStartupFiles() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("ghostty")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let user = directory.appendingPathComponent("zdotdir"), output = directory.appendingPathComponent("seen")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "DISPATCH_ZSHRC=sourced\n".write(to: user.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let launch = try Launch(command: "/bin/zsh", directory: nil, overrides: [], config: SwiftEngine.parse("", dark: true),
                                environment: ["HOME": directory.path, "ZDOTDIR": user.path, "PATH": "/usr/bin:/bin"], resources: resources.path, id: 1)
        XCTAssertEqual(launch.env["ZDOTDIR"], resources.path + "/shell-integration/zsh")
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = ["-i", "-c", #"print -r -- "$DISPATCH_ZSHRC $ZDOTDIR" > "$1""#, "zsh", output.path]
        zsh.environment = launch.env
        zsh.standardInput = FileHandle.nullDevice
        zsh.standardOutput = FileHandle.nullDevice
        zsh.standardError = FileHandle.nullDevice
        try zsh.run()
        zsh.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "sourced \(user.path)\n")
    }

    func testTerminalChildrenLiveInTheTestHome() async throws {
        try DesktopTestSupport.requireUnlocked()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("home.json")
        let probe = #"import json, os, sys; seen = {k: v for k, v in os.environ.items() if k in ['HOME', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'PI_CODING_AGENT_DIR', 'ZDOTDIR', 'GHOSTTY_ZSH_ZDOTDIR']}; seen['argv0'] = sys.argv[2]; f = open(sys.argv[1] + '.part', 'w'); json.dump(seen, f); f.close(); os.rename(sys.argv[1] + '.part', sys.argv[1])"#
        let script = ["/usr/bin/python3", "-c", probe, output.path].map(HerdrLaunch.quote).joined(separator: " ") + " \"$0\""
        let command = "/bin/zsh -c " + HerdrLaunch.quote(script)
        let runtime = TerminalRuntime.shared
        let restore = TestSupport.preserveRuntime(), chat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: false)
        defer { runtime.chat = chat; restore() }
        runtime.start(preferences: Preferences())
        runtime.chat.stop()
        do {
            XCTAssertNil(runtime.error)
            let terminal = TerminalView(id: UUID(), directory: directory.path, launchCommand: command, presentation: .standalone)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = terminal
            window.makeKeyAndOrderFront(nil)
            defer { terminal.destroy(); window.orderOut(nil); window.contentView = nil; window.close() }
            try await TestSupport.eventually { FileManager.default.fileExists(atPath: output.path) }
            let seen = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: output))
            XCTAssertEqual(seen, ["HOME": Home.url.path, "argv0": "-/bin/zsh", "ZDOTDIR": "/var/empty"])
        } catch { await runtime.stop().value; throw error }
        await runtime.stop().value
    }

    func testStoresAndAgentSetupsLeaveTheUserFilesAlone() throws {
        let home = NSHomeDirectory(), environment = ProcessInfo.processInfo.environment
        func agent(_ variable: String, _ path: String) -> String { environment[variable].flatMap { $0.isEmpty ? nil : $0 } ?? home + path }
        let codex = agent("CODEX_HOME", "/.codex"), claude = agent("CLAUDE_CONFIG_DIR", "/.claude"), pi = agent("PI_CODING_AGENT_DIR", "/.pi/agent")
        // What Dispatch writes there: its own files, and in each agent's home what its setups manage.
        let watched = [home + "/Library/Application Support/Dispatch", codex + "/hooks.json", claude + "/settings.json", pi + "/extensions", pi + "/dispatch"]
        // Names with size, modification time and file number: any write shows, no file is read.
        func snapshot() -> [String: String] {
            var files: [String: String] = [:]
            for root in watched {
                let below = FileManager.default.enumerator(atPath: root)?.compactMap { ($0 as? String).map { root + "/" + $0 } } ?? []
                for path in [root] + below {
                    guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
                    files[path] = "\(a[.size] ?? 0) \((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(a[.systemFileNumber] ?? 0)"
                }
            }
            return files
        }
        let before = snapshot()
        // The default stores the tests use: nowhere near the user's files, or nothing runs. Agent hook
        // installation is the helper's (installation.install), checked by its own tests.
        let drafts = ChatDraftFileStore(), hosts = HostSessionStore.standard
        let targets = [drafts.url, hosts.url]
        let users = targets.map(\.path).filter { path in [home, codex, claude, pi].contains { path == $0 || path.hasPrefix($0 + "/") } }
        XCTAssertEqual(users, [], "the defaults are the user's files")
        guard users.isEmpty else { return }
        let settings = SettingsStore()
        try settings.save(settings.values)
        try drafts.save([:])
        try hosts.save(runtime: TerminalRuntime.shared)
        let after = snapshot()
        XCTAssertEqual(Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted(), [])
    }

    /// Whatever the app starts while testing (terminals, agents, launchers) lives in the test home.
    func testChildProcessesLiveInTheTestHome() throws {
        func run(_ script: String) throws -> [String] {
            let child = Process(), output = Pipe()
            (child.executableURL, child.arguments, child.standardOutput) = (URL(fileURLWithPath: "/bin/sh"), ["-c", script], output)
            try child.run()
            child.waitUntilExit()
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).components(separatedBy: "\n")
        }
        // Its home, and the names of the variables that would move an agent's home that are set.
        let seen = try run(#"printf '%s\n' "$HOME" ${CODEX_HOME+CODEX_HOME} ${CLAUDE_CONFIG_DIR+CLAUDE_CONFIG_DIR} ${PI_CODING_AGENT_DIR+PI_CODING_AGENT_DIR}"#)
        let moved = (seen.first == Home.url.path ? [] : ["HOME"]) + seen.dropFirst().filter { !$0.isEmpty }
        XCTAssertEqual(moved, [], "children see the user's home")
        guard moved.isEmpty else { return }
        // What agents write there lands in the test home, never in the user's.
        let probes = [".codex", ".claude", ".pi/agent"].map { $0 + "/dispatch-test-probe" }
        _ = try run(probes.map { #"mkdir -p "$HOME/$(dirname \#($0))" && touch "$HOME/\#($0)""# }.joined(separator: " && "))
        XCTAssertEqual(probes.filter { FileManager.default.fileExists(atPath: NSHomeDirectory() + "/" + $0) }, [])
        XCTAssertEqual(probes.filter { !FileManager.default.fileExists(atPath: Home.url.path + "/" + $0) }, [])
    }
}
