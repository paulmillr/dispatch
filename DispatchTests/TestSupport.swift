import AppKit
import TermApple
import XCTest
@testable import DispatchApp

@MainActor
enum TestSupport {
    /// Observe a fixture effect once; replay restores its result without touching the recorded path or process.
    static func fixture<Input: Encodable, Output: Codable>(_ operation: String, input: Input,
                                                          _ body: () throws -> Output) throws -> Output {
        try AppReplay.decode(Output.self, AppReplay.query(kind: "fixture." + operation,
            input: AppReplay.value(input)) { try AppReplay.value(body()) })
    }

    /// A process a test runs to its end live on purpose, in replay too (real shells, scripts, lsof): its status and
    /// standard output (from the caller's Pipe when it set one). The journal does not see it, so it runs inside
    /// AppReplay.live: replay's watchdog waits for it instead of calling the app idle. One whose result the recording
    /// depends on is recorded instead (System.run, TestSupport.fixture). test/xcode.py refuses other process runs here.
    nonisolated static func live(_ process: Process) throws -> System.Exit {
        try AppReplay.live {
            let output = process.standardOutput as? Pipe ?? Pipe()
            process.standardOutput = output
            try process.run()
            output.fileHandleForWriting.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.wait()
            return System.Exit(status: process.terminationStatus, output: data)
        }
    }

    /// `live` for a process fed `input`, its standard error kept apart, and stopped past `timeout` (`timedOut`).
    nonisolated static func live(_ process: Process, input: Data, timeout: TimeInterval)
        throws -> (status: Int32, output: Data, errors: Data, timedOut: Bool) {
        try AppReplay.live {
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            try process.run()
            stdout.fileHandleForWriting.closeFile(); stderr.fileHandleForWriting.closeFile()
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            // Both pipes drain at once, so a chatty child never blocks on a full one before the deadline.
            final class Drained: @unchecked Sendable { var data = Data() }
            let output = Drained(), errors = Drained(), collected = DispatchGroup()
            for (pipe, into) in [(stdout, output), (stderr, errors)] {
                collected.enter()
                DispatchQueue.global().async { into.data = pipe.fileHandleForReading.readDataToEndOfFile(); collected.leave() }
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            let timedOut = process.isRunning
            if timedOut { process.terminate() }
            process.wait()
            collected.wait()
            return (process.terminationStatus, output.data, errors.data, timedOut)
        }
    }

    /// A process a test starts beside itself (a fixture server, a profiler). One the app's recording depends on starts
    /// inside a recorded body (TestSupport.fixture, AppReplay.query), so replay starts nothing; else only in capture.
    nonisolated static func start(_ process: Process) throws { try process.run() }

    /// Claude asks whether to trust a workspace it has not seen; a configuration shared by several
    /// fixtures (the test home's) gets each fixture's work directory trusted, its other choices kept.
    static func trustClaudeWorkspace(_ work: URL, config: URL) throws {
        let file = config.appendingPathComponent(".claude.json")
        // A missing profile is the fixture's to create (onboarding done, its work directory trusted); creating
        // it here first would leave Claude at its online welcome tour.
        guard System.exists(file) else { return }
        var profile = (try? JSONSerialization.jsonObject(with: System.read(file)) as? [String: Any]) ?? [:]
        var projects = profile["projects"] as? [String: Any] ?? [:]
        // Claude names the directory as it resolves it (/private/var for /var on macOS); trust both spellings.
        // Resolving reads the disk: the fixture made that directory, which a replay never does.
        let resolved = try System.observe("realpath", work.path) { () -> String in
            guard let pointer = realpath(work.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        for path in Set([work.path, resolved]) {
            var project = projects[path] as? [String: Any] ?? [:]
            project["hasTrustDialogAccepted"] = true
            projects[path] = project
        }
        profile["projects"] = projects
        try System.write(JSONSerialization.data(withJSONObject: profile), to: file)
    }

    static let tools = System.checkout.appendingPathComponent("build/test-tools/bin").path
    static let path = HerdrLaunch.quote(tools + ":/Users/admin/dispatch-tests/test-tools:/opt/homebrew/bin")

    /// Every case starts from the same process state, so its recording replays whatever ran before it: hosts discovered
    /// anew, the chat's helper facts (launches, installations) asked anew, and every integration turned off until the
    /// case turns it on (`integrations`); installed hooks stay on disk between cases, so "not turned off" would mean on.
    /// The app is active: cases activate it and never undo that, and a fresh process starts inactive, while the app polls
    /// branches, reports terminal focus and holds attention back only while active. What a case changes beyond that it
    /// restores (TestState reports it otherwise).
    static func isolate() {
        reset(.shared)
        let chat = TerminalRuntime.shared.chat
        chat.helperLaunches = nil
        chat.helperInstalls = [:]
        chat.disabledIntegrations = launches
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(2)
        while !NSApp.isActive, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if !NSApp.isActive { print("Fixture activation: the app did not become active within 2 s") }
    }

    /// The helper's launch keys (helper/harnesses).
    static let launches: Set<String> = ["claude", "codex", "nanocodex", "pi"]

    /// Independent cases discover their own hosts; cache reuse remains scoped to each case.
    static func reset(_ cache: HostBackendCache) {
        cache.reset(.local)
        cache.resetRemote()
    }

    /// A fixture that configures the shared runtime must restore it after closing its own UI.
    static func preserveRuntime() -> () -> Void {
        let runtime = TerminalRuntime.shared, preferences = runtime.preferences, workspace = runtime.workspace
        let theme = ChatThemeStore.shared.current, sidebar = SidebarThemeStore.shared.current, chat = runtime.chat
        let installed = Set(chat.helperInstalls.keys.filter { chat.hookStatus($0) != .off })
        let menu = NSApp.mainMenu, appearance = NSApp.appearance, glass = LiquidGlassStore.shared.enabled
        return {
            runtime.preferences = preferences; runtime.workspace = workspace
            // Applying preferences switches Liquid Glass for every view in the process.
            LiquidGlassStore.shared.enabled = glass
            runtime.chat = chat
            // Restore after queued toggles, even when their last reported state still matches.
            for key in chat.helperInstalls.keys {
                print("Fixture integration restore: agent=\(key), installed=\(installed.contains(key))")
                chat.setHelperIntegration(key, enabled: installed.contains(key))
            }
            ChatThemeStore.shared.current = theme; SidebarThemeStore.shared.current = sidebar
            NSApp.mainMenu = menu; NSApp.appearance = appearance
        }
    }

    /// Turns agent integrations (helper launch keys, e.g. "codex") on or off through the helper
    /// (installation.install) and waits until its installation facts agree. Connected SSH hosts that
    /// granted hooks follow, as in the app.
    static func integrations(_ keys: [String], enabled: Bool, chat: ChatCoordinator) async throws {
        chat.loadLaunches()
        try await eventually(timeout: .seconds(10), diagnostic: "launches: \((chat.helperLaunches ?? []).map(\.key))") {
            keys.allSatisfy { key in chat.helperLaunches?.contains { $0.key == key } == true }
        }
        for key in keys { chat.setHelperIntegration(key, enabled: enabled) }
        try await eventually(timeout: .seconds(10), diagnostic: chat.error ?? "no error") {
            keys.allSatisfy { (chat.hookStatus($0) != .off) == enabled }
        }
        // A case that turns some on turns them off again, in its own journal (case teardowns run before the shared one):
        // the ones it left on, after the runtime stop it began (if any) ended, so the turn-off never races the helper's
        // stop (it reached the stopping helper or started a new one, by timing).
        if enabled {
            ModalGuard.current?.addTeardownBlock { @MainActor in
                await TerminalRuntime.shared.shutdown?.value
                for key in keys where chat.hookStatus(key) != .off { chat.setHelperIntegration(key, enabled: false) }
                await chat.integrationChanges?.value
            }
        }
    }

    static func tool(_ name: String) -> String {
        let local = tools + "/" + name
        // Keep separately provisioned test VMs working; explicit --test prepares
        // the pinned checkout-local tools, which always take precedence.
        var candidates = [local, "/Users/admin/dispatch-tests/test-tools/" + name]
        if name == "codex" {
            candidates.append("/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex")
        }
        candidates.append("/opt/homebrew/bin/" + name)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? local
    }

    /// Condition checks count toward the deadline instead of extending a fixed
    /// sleep count. Evaluate expensive diagnostics only on failure.
    /// A test's own pause (the app's timers run meanwhile): capture waits and records where the test went on; replay
    /// goes on there without waiting.
    static func pause(for duration: Duration, file: StaticString = #filePath, line: UInt = #line) async throws {
        if !AppReplay.replaying { try await Task.sleep(for: duration) }
        await AppReplay.settle()
        try await System.step(at: URL(fileURLWithPath: "\(file)").lastPathComponent + ":\(line)")
    }

    /// What a wait's end needs besides its condition. A sidebar slide runs on wall time: what a test reads or does next
    /// while one runs (pane widths, the terminal grids they give) would depend on how far it came. A move shows before
    /// its server answers and goes back when refused: a wait that ended on it would pass whatever the server answers.
    static var settled: Bool {
        !TerminalRuntime.shared.helpers.values.contains(where: \.moving) && !NSApp.windows.contains { window in
            window.isVisible && window.contentView.map { PresentationTestSupport.views(of: TerminalSplitView.self, in: $0).contains(where: \.sidebarAnimating) } == true
        }
    }

    static func eventually(timeout: Duration = .seconds(5), interval: Duration = .milliseconds(25),
                           file: StaticString = #filePath, line: UInt = #line,
                           diagnostic: @autoclosure () -> String = "Condition timed out",
                           _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: timeout)
        var checks = 0
        var checking = Duration.zero
        defer {
            let elapsed = started.duration(to: clock.now)
            if elapsed >= .milliseconds(250) {
                func seconds(_ duration: Duration) -> Double {
                    let value = duration.components
                    return Double(value.seconds) + Double(value.attoseconds) / 1e18
                }
                // Separate expensive synchronous checks (for example OCR) from
                // time spent awaiting application progress. The caller and the
                // surrounding XCTest case identify the wait in retained logs.
                let name = URL(fileURLWithPath: String(describing: file)).lastPathComponent
                print(String(format: "Fixture wait %@:%llu elapsed=%.3f checking=%.3f checks=%d",
                             name, UInt64(line), seconds(elapsed), seconds(checking), checks))
            }
        }
        func check() async throws -> Bool {
            let began = clock.now
            checks += 1
            defer { checking += began.duration(to: clock.now) }
            guard try await AppReplay.checking({ try await System.$polling.withValue(true) { try await condition() } }) else { return false }
            return settled
        }
        // The test continues where the recording saw it continue: replay delivers nothing recorded later first. The
        // condition holds once the app handled what it already read (capture records input when read, replay delivers
        // it before the step either way). Capture reads on while the test checks: the step records where the first of
        // its two checks began and returned, and replay holds what came after it began while the test waits; a check that
        // keeps failing frees what was read while that check ran (it may have seen it), first one input at a time.
        var mark = 0, end = 0
        let held = try await AppReplay.waiting { () async throws -> Bool in
            while true {
                mark = AppReplay.mark
                if try await check() {
                    end = AppReplay.mark
                    await AppReplay.settle()
                    if try await check() { return true }
                } else { await AppReplay.advance(mark) }
                if let failure = AppReplay.failed {
                    // A stalled replay ends the wait before its timeout: the diagnostic still says what the test saw.
                    print("Fixture wait \(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line) ended by the replay: \(diagnostic())")
                    throw failure
                }
                guard clock.now < deadline else { return false }
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: interval)))
            }
        }
        if held { return try await System.step(at: URL(fileURLWithPath: "\(file)").lastPathComponent + ":\(line)", mark: mark..<end) }
        // XCTest's unwrap error stops the test without adding a second,
        // unrelated "unexpected error" to the failure at the caller's line.
        let satisfied: Bool? = nil
        _ = try XCTUnwrap(satisfied, diagnostic(), file: file, line: line)
    }
}

/// Value snapshots do not retain windows or repair leaks before they can be reported.
@MainActor
struct TestState {
    private var checks: [() -> [String]] = []

    mutating func capture<Value: Equatable>(_ name: String, _ read: @escaping () -> Value) {
        let before = read()
        checks.append {
            let after = read()
            return before == after ? [] : ["\(name) leaked (changed)"]
        }
    }

    mutating func captureKeys<Value: Equatable>(_ name: String, _ read: @escaping () -> [String: Value]) {
        let before = read()
        checks.append {
            let after = read()
            return Set(before.keys).union(after.keys).sorted().compactMap { key in
                guard before[key] != after[key] else { return nil }
                let change = before[key] == nil ? "added" : after[key] == nil ? "removed" : "changed"
                return "\(name) leaked \(key)=<redacted> (\(change))"
            }
        }
    }

    var changes: [String] { checks.flatMap { $0() }.sorted() }

    static func shared() -> TestState {
        var state = TestState()
        let runtime = TerminalRuntime.shared
        state.capture("ChatThemeStore.current") { ChatThemeStore.shared.current }
        state.capture("SidebarThemeStore.current") { SidebarThemeStore.shared.current }
        state.captureKeys("TerminalRuntime.preferences") {
            let data = try! JSONEncoder().encode(runtime.preferences)
            return try! JSONSerialization.jsonObject(with: data) as! [String: NSObject]
        }
        state.capture("TerminalRuntime.chat") { ObjectIdentifier(runtime.chat) }
        state.capture("LiquidGlassStore.enabled") { LiquidGlassStore.shared.enabled }
        state.captureKeys("TerminalRuntime.chat") {
            ["enabled": runtime.chat.enabled, "queueTipShown": runtime.chat.queueTipShown]
        }
        // Which integrations are installed (preserveRuntime's notion); the cache filling in is no change.
        state.captureKeys("TerminalRuntime.chat.helperInstalls") {
            runtime.chat.helperInstalls.filter { runtime.chat.hookStatus($0.key) != .off }.mapValues { _ in "installed" }
        }
        state.capture("TerminalRuntime.workspace") { runtime.workspace.map(ObjectIdentifier.init) }
        state.capture("TerminalRuntime.views") { Set(runtime.views.keys) }
        state.capture("TerminalRuntime.engine") { runtime.engine != nil }
        state.capture("NSApp.appearance") { NSApp.appearance?.name }
        state.capture("NSApp.mainMenu") { NSApp.mainMenu.map(ObjectIdentifier.init) }
        state.capture("NSApp.activationPolicy") { NSApp.activationPolicy() }
        for domain in Set([Bundle.main.bundleIdentifier, Bundle(for: DispatchTestObserver.self).bundleIdentifier].compactMap { $0 }) {
            state.captureKeys("UserDefaults.\(domain)") {
                (UserDefaults.standard.persistentDomain(forName: domain) ?? [:]) as! [String: NSObject]
            }
        }
        // Hidden platform scratch windows (for example text input) are not app layout.
        // Keep hidden titled windows checked, but ignore already-closed empty windows.
        let captured = NSApp.windows.filter {
            $0.isVisible || ($0.contentView != nil && $0.styleMask.contains(.titled))
        }
        let identifiers = Set(captured.map(ObjectIdentifier.init))
        let windows = captured.map { window -> () -> [String: NSObject] in
            let before = Self.window(window), visible = window.isVisible
            return { [weak window] in
                // AppKit may autorelease a previously closed window in a later test.
                guard let window else { return visible ? [:] : before }
                return Self.window(window)
            }
        }
        state.captureKeys("NSApp.windows") {
            var values: [String: NSObject] = [:]
            for window in windows { values.merge(window()) { _, new in new } }
            for window in NSApp.windows where !identifiers.contains(ObjectIdentifier(window)) && window.isVisible {
                values.merge(Self.window(window)) { _, new in new }
            }
            return values
        }
        return state
    }

    private static func window(_ window: NSWindow) -> [String: NSObject] {
        let key = "\(type(of: window))[\(ObjectIdentifier(window))]"
        var values: [String: NSObject] = [
            key + ".frame": NSValue(rect: window.frame),
            key + ".contentMinSize": NSValue(size: window.contentMinSize),
            key + ".visible": NSNumber(value: window.isVisible),
            key + ".appearance": (window.appearance?.name.rawValue ?? "system") as NSString]
        if let content = window.contentView { values[key + ".contentBounds"] = NSValue(rect: content.bounds) }
        return values
    }
}

extension Preferences {
    /// The defaults with flat chrome, for tests of the flat design and tests that read the window through offscreen
    /// captures, which cannot draw Liquid Glass.
    static var flat: Preferences {
        var preferences = Preferences(); preferences.liquidGlass = false
        return preferences
    }
}

/// XCTest instantiates the test bundle's principal class before running any cases.
@objc(DispatchTestObserver)
final class DispatchTestObserver: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
        // The default Automatic theme follows NSApp.effectiveAppearance, and the
        // presentation checks expect its dark resolution. Pin it here instead of
        // requiring Dark in System Settings. Tests of Light and Automatic set
        // NSApp.appearance themselves, and TestState rejects any leaked change.
        // Scroll bars follow the Mac's pointing devices by default: with a mouse they
        // take 17 pt from scrolled content, without one they overlay it. Pin the
        // mouse layout for this process; the argument domain overrides System Settings.
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(arguments.merging(["AppleShowScrollBars": "Always"]) { _, pinned in pinned },
                                                forName: UserDefaults.argumentDomain)
        let pin = { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if Thread.isMainThread { MainActor.assumeIsolated(pin) } else { DispatchQueue.main.sync(execute: pin) }
        if Thread.isMainThread { MainActor.assumeIsolated { ModalGuard.shared.start() } }
        else { DispatchQueue.main.sync { ModalGuard.shared.start() } }
    }

    /// "-[DispatchTests.Class test]" -> "DispatchTests/Class/test", the runner's case identifier.
    private static func identifier(_ testCase: XCTestCase) -> String {
        let parts = testCase.name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]"))
            .replacingOccurrences(of: ".", with: "/").replacingOccurrences(of: " ", with: "/")
            .split(separator: "/")
        // XCTest also supplies "-[Class test]" without the module; callers always use runner ids.
        return (["DispatchTests"] + parts.suffix(2).map(String.init)).joined(separator: "/")
    }

    /// A capture's staging root (the runner's DISPATCH_CAPTURE=<root>/helper-%p.rpl.zst, inherited by every helper): each
    /// case writes <TestFile>/<test>/ in it, as in replays/ (tests.json there names each test class's file), and its
    /// boundaries in cases.jsonl.
    private static let staging = System.environment("DISPATCH_CAPTURE").map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    private static let cases = staging?.appendingPathComponent("cases.jsonl")
    private static let files = staging.flatMap {
        try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: $0.appendingPathComponent("tests.json")))
    } ?? [:]

    /// Where a capture stages `testCase`: <root>/<TestFile>/<test>/.
    private static func staged(_ testCase: XCTestCase) throws -> URL {
        let parts = identifier(testCase).split(separator: "/").map(String.init)
        guard let staging, let file = files[parts[1]] else { throw HelperFailure(code: "capture", message: "No test file declares \(parts[1]) (tests.json)") }
        return staging.appendingPathComponent(file).appendingPathComponent(parts[2])
    }

    nonisolated(unsafe) private static var journals: [String: String] = [:]

    private static func log(_ testCase: XCTestCase, _ event: String) {
        var value: [String: Any] = ["case": identifier(testCase), "event": event, "time": Date().timeIntervalSince1970]
        if event == "end", let journal = journals.removeValue(forKey: identifier(testCase)) {
            value["journal"] = journal
            value["outcome"] = testCase.testRun?.hasSucceeded == true
                ? ((testCase.testRun?.skipCount ?? 0) > 0 ? "skipped" : "passed") : "failed"
        }
        guard let cases, var line = try? JSONSerialization.data(withJSONObject: value) else { return }
        line.append(0x0a)
        if !FileManager.default.fileExists(atPath: cases.path) { FileManager.default.createFile(atPath: cases.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: cases) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: line)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        Self.collectRemote(testCase)
        Self.log(testCase, "end")
    }

    /// The case's remote helper captures (SSHBootstrap.captureDirectory on each host it used) move to
    /// <root>/<TestFile>/<test>/<host>/helper-<pid>-<start ns>.rpl.zst; per case, so remote clocks never matter.
    private static func collectRemote(_ testCase: XCTestCase) {
        defer { SSHLinuxTestProfile.used.removeAll() }
        guard cases != nil else { return }
        let target: URL
        do { target = try staged(testCase) } catch { XCTFail("\(error)"); return }
        // Where the case's remote helpers wrote: the folder of the case's own capture path (DISPATCH_CAPTURE during it).
        let directory = SSHBootstrap.captureDirectory(target.appendingPathComponent("helper-%p.rpl.zst").path)
        let script = System.checkout.appendingPathComponent("test/capture.py").path
        var sources: [(String, URL, [String])] = []
        // The loopback sshd runs as this account: the remote HOME is the account's, not this test's HOME.
        sources.append((System.machine.home.appendingPathComponent(directory).path, target.appendingPathComponent("127.0.0.1"),
                        ["/bin/sh", "-c"]))
        for url in SSHLinuxTestProfile.used {
            guard let profile = try? JSONDecoder().decode(SSHLinuxTestProfile.self, from: Data(contentsOf: url)) else { continue }
            let host = target.appendingPathComponent(profile.destination)
            sources.append((directory, host, ["/usr/bin/ssh"] + profile.options
                            + ["-o", "ConnectTimeout=5", profile.destination]))
        }
        for (source, target, command) in sources {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script, "collect", "--directory", source, "--target", target.path, "--"] + command
            do {
                let exit = try TestSupport.live(process)
                print(String(decoding: exit.output, as: UTF8.self), terminator: "")
                if exit.status != 0 { XCTFail("Capture collection failed; unacknowledged sources retained at \(source)") }
            } catch { XCTFail("Capture collection could not start: \(error)") }
        }
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        if Thread.isMainThread { MainActor.assumeIsolated { TestSupport.isolate() } }
        else { DispatchQueue.main.sync { MainActor.assumeIsolated { TestSupport.isolate() } } }
        ModalGuard.current = testCase
        Self.log(testCase, "start")
        Pty.journal = System.pty
        let journal: URL?
        do { journal = try Corpus.journal(Self.identifier(testCase)) } catch { XCTFail("\(error)"); journal = nil }
        if let journal {
            // The case replays its app journal: no I/O; it fails where the app does something the journal lacks.
            do { try AppReplay.begin(url: journal, replaying: true) } catch { XCTFail("App replay setup failed: \(error)") }
        } else if System.environment("DISPATCH_TEST_CAPTURE") == "1" {
            do {
                let path = try Self.staged(testCase).appendingPathComponent(System.uuid().uuidString + ".rpl.zst")
                try AppReplay.begin(url: path, replaying: false)
                Self.journals[Self.identifier(testCase)] = path.path
            } catch { XCTFail("App journal setup failed: \(error)") }
        }
        // Every case ends the same way, replayed, recorded or live: what the app started stops within the case, never
        // in the next one's journal (a live case before a replayed one left its launch mailbox running).
        let identifier = Self.identifier(testCase)
        testCase.addTeardownBlock {
            // Teardown starts where the recording's did: what the app did before it (its timers' rounds) comes first.
            await AppReplay.settle(); try? await System.step(at: "teardown")
            let cleanup = await MainActor.run { TerminalRuntime.shared.stop() }
            await cleanup.value
            for _ in 0..<500 where !AppReplay.settled { try? await Task.sleep(for: .milliseconds(10)) }
            do {
                let longest = AppReplay.longest
                try AppReplay.finish()
                if journal != nil { print("App replay verified: \(identifier) (longest wait \(longest.idle), capture \(longest.gap))") }
            } catch { XCTFail("App journal incomplete: \(error)") }
        }
        if journal == nil, System.environment("DISPATCH_TEST_CAPTURE") == "1" {
            if let previous = System.environment("DISPATCH_CAPTURE") {
                do {
                    let directory = try Self.staged(testCase)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    let pattern = directory.appendingPathComponent("helper-%p.rpl.zst").path
                    setenv("DISPATCH_CAPTURE", pattern, 1)
                    // Registered first: all case cleanup and shared-state checks finish before the helper exits.
                    testCase.addTeardownBlock {
                        // The app journal owns whole-runtime shutdown, including renderer generations.
                        if !AppReplay.enabled { await HelperApp.shared.stop() }
                        setenv("DISPATCH_CAPTURE", previous, 1)
                    }
                } catch { XCTFail("Whole capture setup failed: \(error)") }
            } else { XCTFail("Whole capture requires DISPATCH_CAPTURE") }
        }
        let state = Thread.isMainThread ? MainActor.assumeIsolated { TestState.shared() }
            : DispatchQueue.main.sync { TestState.shared() }
        // Teardown blocks run in reverse registration order: test-owned cleanup goes first.
        testCase.addTeardownBlock { @MainActor in
            // Installation work a test started (its restore included) ends before the next test, not in it.
            await TerminalRuntime.shared.chat.integrationChanges?.value
            for change in state.changes { XCTFail(change) }
        }
    }
}

/// The replay corpus, `replays/<TestFile>/<test>/<key>.rpl.zst` (DISPATCH_REPLAYS: another root): a test with an app
/// journal there replays it, one without runs live (recorded when the runner captures). DISPATCH_LIVE=1 runs every test
/// live; DISPATCH_REPLAY_REQUIRED=1 fails a test without one. A journal of another protocol version is a wrong
/// capture: the test fails (`capture prune` drops it).
enum Corpus {
    static let sources = System.checkout.appendingPathComponent("DispatchTests")
    static let root = System.environment("DISPATCH_REPLAYS").map { URL(fileURLWithPath: $0) }
        ?? System.checkout.appendingPathComponent("replays")
    /// The file declaring each class: `class Name:` in the test sources.
    static let files: [String: String] = {
        var files: [String: String] = [:]
        let urls = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for url in urls where url.pathExtension == "swift" {
            for line in (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n") ?? [] {
                guard let range = line.range(of: "class "), range.lowerBound == line.startIndex || line[line.index(before: range.lowerBound)] == " " else { continue }
                let name = line[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if line[range.upperBound...].dropFirst(name.count).drop(while: { $0 == " " }).first == ":" {
                    files[String(name)] = url.deletingPathExtension().lastPathComponent
                }
            }
        }
        return files
    }()

    /// The test's journal (`DispatchTests/Class/test`), nil: it runs live. The corpus holds one per test (variants
    /// come with deduplication).
    static func journal(_ name: String) throws -> URL? {
        let parts = name.split(separator: "/").map(String.init)
        guard System.environment("DISPATCH_LIVE") != "1", parts.count == 3,
              let file = files[parts[1]] else { return nil }
        let directory = root.appendingPathComponent(file).appendingPathComponent(parts[2])
        let urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".rpl.zst") }.sorted { $0.path < $1.path }
        for url in urls {
            switch try AppReplay.journal(url) {
            case true?: return url
            case false?: throw HelperFailure(code: "replay", message: url.path + " was recorded by another protocol version: capture prune")
            case nil: continue
            }
        }
        // Replaying a run (the runner's --replay): a test without its journal cannot run live.
        if System.environment("DISPATCH_REPLAY_REQUIRED") == "1" {
            throw HelperFailure(code: "replay", message: "No journal for \(name) in \(directory.path)")
        }
        return nil
    }
}

extension AgentModelMenu {
    /// Whether terminal text names a model by its slug or display name as a whole word.
    static func containsModel(_ text: String, slug: String, name: String? = nil) -> Bool {
        [slug, name].compactMap { $0 }.filter { !$0.isEmpty }.contains { value in
            text.range(of: #"(?<![\p{L}\p{N}._/-])"# + NSRegularExpression.escapedPattern(for: value)
                + #"(?![\p{L}\p{N}._/-])"#, options: .regularExpression) != nil
        }
    }
}

/// A modal alert nobody answers blocks the whole run (runs 135 and 136 hung on one). A test that
/// expects one answers it at once (CloseConfirmationAnswerer); any other fails its test with the
/// alert's text and is aborted, which the app reads as Cancel.
@MainActor final class ModalGuard {
    static let shared = ModalGuard()
    /// Set by XCTest's observer as each case starts (XCTest runs cases and observers on the main thread).
    nonisolated(unsafe) static var current: XCTestCase?
    private var since: Date?

    func start() {
        RunLoop.main.add(Timer(timeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { ModalGuard.shared.check() } },
                         forMode: .common)
    }

    private func check() {
        guard let window = NSApp.modalWindow else { since = nil; return }
        let first = since ?? Date(); since = first
        guard Date().timeIntervalSince(first) >= 1 else { return }
        func texts(_ view: NSView?) -> [String] {
            guard let view else { return [] }
            return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
        }
        let message = "Unanswered modal alert in \(Self.current?.name ?? "no test"): "
            + texts(window.contentView).filter { !$0.isEmpty }.joined(separator: " | ")
        print(message)
        Self.current?.record(XCTIssue(type: .assertionFailure, compactDescription: message))
        since = nil
        NSApp.abortModal()
    }
}

/// Close confirmation is always on. Tests that close or quit running work answer the real
/// alert as a user would ("Close"), from a timer that also fires inside its modal loop.
@MainActor final class CloseConfirmationAnswerer {
    private let timer: Timer

    init() {
        timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow, Self.shows("Close running processes?", in: window.contentView) else { return }
                NSApp.stopModal(withCode: .alertSecondButtonReturn); Self.wake() // from a timer, stopModal ends the loop only at its next event
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() { timer.invalidate() }
    private static func wake() { NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0).map { NSApp.postEvent($0, atStart: true) } }
    private static func shows(_ text: String, in view: NSView?) -> Bool {
        guard let view else { return false }
        if (view as? NSTextField)?.stringValue == text { return true }
        return view.subviews.contains { shows(text, in: $0) }
    }
}

extension TerminalRuntime {
    /// The SSH link a tab runs over: the one its ssh started (origin tab), or the one whose remote helper
    /// serves its space.
    func link(of tab: UUID) -> SSHCoordinator.Link? {
        if let id = ssh.connectionForOrigin(tab) { return ssh.links[id] }
        guard let space = workspace?.spaces.first(where: { $0.tabs.contains { $0.id == tab } }),
              workspace?.helper(space)?.offline(space) != true else { return nil }
        return space.remote.flatMap { ssh.links[$0] }
    }
}

extension ChatCoordinator {
    /// Opens a transcript as an archived conversation through the helper (chat.page reads the file), as
    /// the app does for a conversation without a live terminal; returns once its first page arrived.
    /// `opens`: false when the reader must refuse the whole transcript (its error is the status, nothing is shown).
    func archived(_ lines: [String], agent: String, session id: String, in directory: URL, opens: Bool = true) async throws -> ChatSession {
        let url = directory.appendingPathComponent(id + ".jsonl")
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        return try await archived(url, agent: agent, session: id, opens: opens)
    }

    /// An existing transcript file opened as an archived conversation.
    func archived(_ url: URL, agent: String, session id: String, opens: Bool = true, timeout: Duration = .seconds(10)) async throws -> ChatSession {
        let session = session(for: System.uuid())
        session.agentID = agent; session.sessionID = id; session.transcriptPath = url.path
        start()
        try await TestSupport.eventually(timeout: timeout, diagnostic: "archived \(agent) transcript: \(session.status ?? "loading")") {
            session.helper != nil && (!session.loadingHistory || session.status != nil)
        }
        if opens && !session.loadingHistory { XCTAssertNil(session.status, "archived \(agent) transcript did not open") }
        else if !opens { XCTAssertNotNil(session.status, "archived \(agent) transcript must be refused") }
        return session
    }

    /// Loads the next earlier page of a chat and waits for it; the page's time as the app sees it (ms).
    func earlier(_ session: ChatSession, timeout: Duration = .seconds(30)) async throws -> Double {
        let start = ContinuousClock.now
        guard loadEarlier(session) else { return 0 }
        try await TestSupport.eventually(timeout: timeout) { !session.loadingEarlier }
        XCTAssertNil(session.earlierError)
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
}

extension ChatSession {
    /// The remote agent a chat targets: a helper chat on a remote endpoint (its SSH link's host and boot,
    /// the binding's process).
    struct RemoteAgent: Equatable {
        let connection: SSHConnectionID, host: String, boot: String, pid: Int32, executable: String, key: String

        // A fresh SSH connection can reach the same host/boot/process identity.
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    }

    @MainActor var remoteAgent: RemoteAgent? {
        guard let id = helper?.endpoint.connection, let link = TerminalRuntime.shared.ssh.links[id], let process = binding?.process else { return nil }
        let host = link.greeting.hostID, boot = link.greeting.boot
        let key = [host, boot, String(process.pid), "\(process.startedSeconds).\(process.startedMicroseconds)", process.executable]
        return RemoteAgent(connection: id, host: host, boot: boot, pid: process.pid, executable: process.executable,
                           key: key.joined(separator: ":"))
    }
}

extension Space {
    /// Its windows: a structured space's windows, otherwise its tabs.
    var windowCount: Int { structured ? windows.count : tabs.count }

    /// The space's own id in its multiplexer (e.g. a herdr workspace id): the helper node key of the space.
    @MainActor var key: String? { node.flatMap { TerminalRuntime.shared.workspace?.helper(self)?.node($0)?.key } }

    /// The space shows that multiplexer's session: a space of the helper backend that multiplexer serves.
    @MainActor func shows(_ name: String) -> Bool {
        return backend.flatMap { TerminalRuntime.shared.workspace?.helper(self)?.multiplexer(of: $0) } == name
    }
}

extension Workspace {
    /// A terminal tab's own id in its multiplexer (e.g. a herdr terminal id): its helper node key.
    @MainActor func key(of tab: TerminalTab) -> String? {
        tab.terminal.flatMap { helper(containing: tab.id)?.node($0)?.key }
    }

    /// The active window's own id in its multiplexer (e.g. a herdr tab id): the helper node key of the
    /// active window's container.
    @MainActor var activeWindowKey: String? { activeTab.flatMap(windowKey(of:)) }

    /// The multiplexer's own id of the window holding this terminal tab (e.g. a herdr tab id).
    @MainActor func windowKey(of tab: TerminalTab) -> String? {
        guard let container = spaces.flatMap(\.containers).first(where: { $0.arrangement.panes.contains { $0.tabs.contains { $0.id == tab.id } } })
        else { return nil }
        return helper(containing: tab.id)?.node(container.node)?.key
    }
}

/// A herdr pane: the app's id for it (view, chat) and herdr's own pane id.
struct HerdrPane: Equatable {
    let id: UUID
    let pane: String
}

enum HerdrTestSupport {
    /// Panes of the active window: the helper window's terminal tabs, whose node keys (herdr terminal
    /// ids) map to pane ids through the server's own snapshot.
    @MainActor static func panes(_ workspace: Workspace, socket: String) throws -> [HerdrPane] {
        let snapshot = try snapshot(socket)
        return (workspace.current?.activeWindow?.terminals ?? []).compactMap { tab in
            guard let key = tab.terminal.flatMap({ workspace.helper(workspace.current)?.node($0)?.key }),
                  let pane = snapshot.panes.first(where: { $0.terminal_id == key }) else { return nil }
            return HerdrPane(id: tab.id, pane: pane.pane_id)
        }
    }

    /// herdr's pane id of an app terminal tab (any space), through the server's snapshot.
    @MainActor static func pane(of tab: UUID, in workspace: Workspace, socket: String) throws -> String? {
        guard let tab = workspace.spaces.flatMap(\.tabs).first(where: { $0.id == tab }), let key = workspace.key(of: tab) else { return nil }
        return try snapshot(socket).panes.first { $0.terminal_id == key }?.pane_id
    }

    static func snapshot(_ socket: String) throws -> HerdrSnapshot {
        struct Result: Decodable { let snapshot: HerdrSnapshot }
        return try JSONDecoder().decode(Result.self, from: HerdrSocket(path: socket).request("session.snapshot")).snapshot
    }
}

extension Space {
    /// The space as the helper presents a multiplexer session: one container (window) per tab, the tabs
    /// as helper terminals (node and terminal ids from 1).
    mutating func structure(_ tabs: [TerminalTab], selected: Int, name: String? = nil, backend: UInt64 = 1) {
        self.backend = backend; node = 1_000
        containers = tabs.enumerated().map { index, original in
            var tab = original; tab.terminal = UInt64(index + 1)
            return ContainerTab(id: System.uuid(), node: UInt64(index + 1), name: name ?? "\(index)", arrangement: PaneArrangement(tab: tab))
        }
        selectedContainer = containers[selected].id
    }
}

extension HelperChat {
    /// The harness's view of the native agent (chat.state): busy, its editor draft, tree leaf, effort, a pending dialog.
    struct Native: Decodable {
        let busy: Bool
        let draft: String?
        let leaf: String?
        let effort: String?
        let dialog: String?
        var editor: String { draft ?? "" }
        var leafID: String? { leaf }
    }

    /// chat.state replies {binding, state}; the harness's view is the state.
    func native() async throws -> Native {
        struct Reply: Decodable { let state: Native }
        let reply: Reply = try await call("chat.state", input: Input(route))
        return reply.state
    }

    /// Input addressed to `conversation` through this chat's helper is refused (an old conversation,
    /// an exited or revoked agent, a disconnected generation).
    func refuses(_ text: String, conversation: String) async -> Bool {
        var input = Input(.init(terminal: route.terminal, session: conversation)); input.text = text
        do {
            let sent: Sent = try await call("chat.send", input: input)
            try sent.confirmed()
            return false
        } catch { return true }
    }
}

/// Claude's own TUI states, read from a terminal's screen (live Claude E2Es); moved from the app's former
/// ClaudeQuestions, which the claude harness replaced.
enum ClaudeScreen {
    /// Claude's native question menu.
    static func question(_ screen: String) -> Bool {
        guard screen.utf8.count <= 65_536 else { return false }
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let footer = lines.last(where: { !$0.isEmpty }), footer.hasPrefix("Enter to select ·"),
              footer.contains("Esc to cancel") else { return false }
        return lines.contains { $0.contains("Type something.") } && lines.contains { $0.contains("Chat about this") }
    }

    /// A lost or unhandled hook leaves Claude's own permission menu active.
    /// This only reveals Terminal; native screen text never supplies a decision.
    static func permission(_ screen: String) -> Bool {
        guard screen.utf8.count <= 65_536 else { return false }
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let footer = lines.last(where: { !$0.isEmpty }), footer.hasPrefix("Esc to cancel"),
              let question = lines.lastIndex(of: "Do you want to proceed?") else { return false }
        let choices = lines.suffix(from: question + 1)
        return choices.contains { $0.range(of: #"^(?:❯ )?[1-9]\. Yes(?:$|,)"#, options: .regularExpression) != nil }
            && choices.contains { $0.range(of: #"^(?:❯ )?[1-9]\. No$"#, options: .regularExpression) != nil }
            && choices.contains { $0.hasPrefix("❯ ") }
    }
}

extension ClaudeQuestions {
    /// One choice question per (text, options).
    static func choices(_ questions: [(String, [String])]) -> ClaudeQuestions {
        ClaudeQuestions(questions.map { text, labels in
            Question(text: text, header: "Question", options: labels.map { Option(label: $0, description: "", preview: nil) }, multiple: false)
        })
    }
}

/// A bounded wait that records no replay step, for fixtures that read nothing and whose recordings hold no waits: a
/// fixed sleep before an assertion about deferred main-queue or SwiftUI layout work fails on a loaded machine, and an
/// `eventually` there would add a step the recording lacks. Returns whether `condition` held; the caller asserts.
extension TestSupport {
    @discardableResult
    static func poll(timeout: Duration = .seconds(5), _ condition: () throws -> Bool) async throws -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: timeout)
        while try !condition() {
            guard clock.now < deadline else { return false }
            try await clock.sleep(for: .milliseconds(10))
        }
        return true
    }
}
