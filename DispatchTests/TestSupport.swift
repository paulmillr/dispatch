import AppKit
import XCTest
@testable import DispatchApp

@MainActor
enum TestSupport {
    /// Observe a fixture effect once; replay restores its result without touching the recorded path or process.
    static func fixture<Input: Encodable, Output: Codable>(_ operation: String, input: Input,
                                                          _ body: () throws -> Output) throws -> Output {
        try JSONDecoder().decode(Output.self, from: AppReplay.query(kind: "fixture." + operation,
            input: JSONEncoder().encode(input)) { try JSONEncoder().encode(body()) })
    }

    /// Claude asks whether to trust a workspace it has not seen; a configuration shared by several
    /// fixtures (the test home's) gets each fixture's work directory trusted, its other choices kept.
    static func trustClaudeWorkspace(_ work: URL, config: URL) throws {
        let file = config.appendingPathComponent(".claude.json")
        // A missing profile is the fixture's to create (onboarding done, its work directory trusted); creating
        // it here first would leave Claude at its online welcome tour.
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var profile = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]) ?? [:]
        var projects = profile["projects"] as? [String: Any] ?? [:]
        // Claude names the directory as it resolves it (/private/var for /var on macOS); trust both spellings.
        let resolved = try XCTUnwrap(work.path.withCString { realpath($0, nil) })
        defer { free(resolved) }
        for path in Set([work.path, String(cString: resolved)]) {
            var project = projects[path] as? [String: Any] ?? [:]
            project["hasTrustDialogAccepted"] = true
            projects[path] = project
        }
        profile["projects"] = projects
        try JSONSerialization.data(withJSONObject: profile).write(to: file)
    }

    static let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/test-tools/bin").path
    static let path = HerdrLaunch.quote(tools + ":/Users/admin/dispatch-tests/test-tools:/opt/homebrew/bin")

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
            return try await condition()
        }
        while true {
            if try await check() { return }
            guard clock.now < deadline else { break }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: interval)))
        }
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

    /// Case boundaries next to the helper captures (DISPATCH_CAPTURE=<dir>/helper-%p.jsonl, inherited
    /// by every helper), so the captures can be cut per case.
    private static let cases = ProcessInfo.processInfo.environment["DISPATCH_CAPTURE"].map {
        URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("cases.jsonl")
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
    /// <captures>/remote/<Class.test>/<host>/helper-<pid>-<start ns>.jsonl; per case, so remote clocks never matter.
    private static func collectRemote(_ testCase: XCTestCase) {
        defer { SSHLinuxTestProfile.used.removeAll() }
        guard let cases, let directory = SSHBootstrap.captureDirectory else { return }
        let name = identifier(testCase).replacingOccurrences(of: "DispatchTests/", with: "").replacingOccurrences(of: "/", with: ".")
        let target = cases.deletingLastPathComponent().appendingPathComponent("remote").appendingPathComponent(name)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("test/capture.py").path
        var sources: [(String, URL, [String])] = []
        // The loopback sshd runs as this account: the remote HOME is the account's, not this test's HOME.
        if let account = getpwuid(getuid())?.pointee.pw_dir {
            let source = URL(fileURLWithPath: String(cString: account)).appendingPathComponent(directory)
            let local = target.appendingPathComponent("127.0.0.1")
            sources.append((source.path, local, ["/bin/sh", "-c"]))
        }
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
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 { XCTFail("Capture collection failed; unacknowledged sources retained at \(source)") }
            } catch { XCTFail("Capture collection could not start: \(error)") }
        }
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        if Thread.isMainThread { MainActor.assumeIsolated { TestSupport.reset(.shared) } }
        else { DispatchQueue.main.sync { MainActor.assumeIsolated { TestSupport.reset(.shared) } } }
        ModalGuard.current = testCase
        Self.log(testCase, "start")
        if let directory = ProcessInfo.processInfo.environment["DISPATCH_APP_CAPTURE"] {
            let name = Self.identifier(testCase).split(separator: "/").dropFirst().joined(separator: ".")
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).appendingPathComponent(UUID().uuidString + ".jsonl")
            do {
                guard !Replay.enabled else { throw HelperFailure(code: "replay", message: "App capture and replay cannot run together") }
                try AppReplay.begin(url: path, replaying: false)
                Self.journals[Self.identifier(testCase)] = path.path
            } catch { XCTFail("App journal setup failed: \(error)") }
            testCase.addTeardownBlock {
                let cleanup = await MainActor.run { TerminalRuntime.shared.stop() }
                await cleanup.value
                for _ in 0..<500 where !AppReplay.settled { try? await Task.sleep(for: .milliseconds(10)) }
                do { try AppReplay.finish() }
                catch { XCTFail("App journal incomplete: \(error)") }
            }
        }
        if ProcessInfo.processInfo.environment["DISPATCH_TEST_CAPTURE"] == "1" {
            if Replay.enabled { XCTFail("Whole capture and app replay cannot run together") }
            else if let previous = ProcessInfo.processInfo.environment["DISPATCH_CAPTURE"] {
                let name = Self.identifier(testCase).split(separator: "/").dropFirst().joined(separator: ".")
                let directory = URL(fileURLWithPath: previous).deletingLastPathComponent()
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    let pattern = directory.appendingPathComponent("\(name)-%p.jsonl").path
                    setenv("DISPATCH_CAPTURE", pattern, 1)
                    // Registered first: all case cleanup and shared-state checks finish before the helper exits.
                    testCase.addTeardownBlock {
                        // The app journal owns whole-runtime shutdown, including renderer generations.
                        if !AppReplay.enabled { await HelperApp.shared.stop() }
                        setenv("DISPATCH_CAPTURE", previous, 1)
                    }
                } catch { XCTFail("Whole capture setup failed: \(error)") }
            } else { XCTFail("Whole capture requires DISPATCH_CAPTURE") }
        } else { Replay.start(testCase, name: Self.identifier(testCase)) }
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

/// Replay runs (DISPATCH_TEST_REPLAY=1, TEST_RUNNER_DISPATCH_TEST_REPLAY for xcodebuild): each case's helper is
/// scripts/replay-helper.py playing DispatchTests/Replay/<Class.test>.json, a real exchange of that case
/// (scripts/capture-helper-wire.py). The case fails on a request the recording lacks or a recorded request
/// the app never made; its own assertions run as in the end-to-end run. Missing recordings fail closed.
enum Replay {
    static let enabled = ProcessInfo.processInfo.environment["DISPATCH_TEST_REPLAY"] == "1"
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    static func start(_ testCase: XCTestCase, name: String) {
        guard enabled else { return }
        if ProcessInfo.processInfo.environment["DISPATCH_APP_REPLAY"] != nil {
            do {
                guard let index = ProcessInfo.processInfo.environment["DISPATCH_APP_REPLAY_INDEX"],
                      let source = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: index)))[name] else {
                    throw HelperFailure(code: "replay", message: "No app recording selected for \(name); live execution is disabled")
                }
                try AppReplay.begin(url: URL(fileURLWithPath: source), replaying: true)
                try AppReplay.listen { event in
                    let receive: @MainActor @Sendable () -> Void = {
                        do {
                            guard try TerminalRuntime.shared.hosts.replay(event) else {
                                throw HelperFailure(code: "replay", message: "Unknown app journal input: " + event.kind)
                            }
                        } catch { AppReplay.fail(error) }
                    }
                    if Thread.isMainThread { MainActor.assumeIsolated { receive() } }
                    else { DispatchQueue.main.sync { MainActor.assumeIsolated { receive() } } }
                }
            } catch { XCTFail("App replay setup failed: \(error)") }
            testCase.addTeardownBlock {
                let cleanup = await MainActor.run { TerminalRuntime.shared.stop() }
                await cleanup.value
                for _ in 0..<500 where !AppReplay.settled { try? await Task.sleep(for: .milliseconds(10)) }
                do {
                    try AppReplay.finish()
                    print("App replay verified: \(name)")
                } catch { XCTFail("App replay incomplete: \(error)") }
            }
            return
        }
        let directory = ProcessInfo.processInfo.environment["DISPATCH_REPLAY_DIRECTORY"]
            .map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Replay")
        let fixture = directory.appendingPathComponent("\(name.split(separator: "/").dropFirst().joined(separator: ".")).json")
        let environment = ["DISPATCH_HELPER_EXECUTABLE", "DISPATCH_REPLAY_FIXTURE", "DISPATCH_REPLAY_REPORT"].map {
            ($0, ProcessInfo.processInfo.environment[$0])
        }
        let report = directory.appendingPathComponent("replay-\(UUID().uuidString).json")
        // HelperApp starts the helper on first use, from DISPATCH_HELPER_EXECUTABLE (its test override).
        setenv("DISPATCH_HELPER_EXECUTABLE", root.deletingLastPathComponent().appendingPathComponent("scripts/replay-helper.py").path, 1)
        setenv("DISPATCH_REPLAY_FIXTURE", fixture.path, 1)
        setenv("DISPATCH_REPLAY_REPORT", report.path, 1)
        if !FileManager.default.fileExists(atPath: fixture.path) {
            XCTFail("Replay: missing recording \(fixture.path); live helper is disabled")
        }
        testCase.addTeardownBlock {
            await HelperApp.shared.stop()
            defer {
                for (name, value) in environment {
                    if let value { setenv(name, value, 1) }
                    else { unsetenv(name) }
                }
            }
            // The player writes it when its stdin ends (stop closes it); up to 5 s.
            for _ in 0..<500 where !FileManager.default.fileExists(atPath: report.path) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let data = try? Data(contentsOf: report),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: [Any]] else {
                return XCTFail("Replay: no report from the player for \(fixture.lastPathComponent)")
            }
            for (kind, values) in result where !values.isEmpty {
                XCTFail("Replay \(kind): " + String(decoding: (try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self))
            }
            let fields = Set(["unexpected", "missing", "undelivered", "errors"])
            XCTAssertEqual(Set(result.keys), fields, "Replay: incomplete player report at \(report.path)")
            if Set(result.keys) == fields && result.values.allSatisfy(\.isEmpty) {
                print("Replay verified: \(fixture.lastPathComponent); report=\(report.path)")
            }
        }
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

@MainActor final class ChatDraftMemoryStore: ChatDraftPersistence {
    var buckets: [String: ChatDraftBucket] = [:]
    func load() throws -> [String: ChatDraftBucket] { buckets }
    func save(_ buckets: [String: ChatDraftBucket]) throws { self.buckets = buckets }
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
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() { timer.invalidate() }

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
        let session = session(for: UUID())
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
            return ContainerTab(id: UUID(), node: UInt64(index + 1), name: name ?? "\(index)", arrangement: PaneArrangement(tab: tab))
        }
        selectedContainer = containers[selected].id
    }
}

extension ChatSideQuestion {
    /// The form for a helper interaction (its chat.interaction JSON) in conversation `session`.
    static func helper(_ interaction: [String: Any], session: String) throws -> ChatSideQuestion {
        let value = try JSONDecoder().decode(HelperChat.Interaction.self, from: JSONSerialization.data(withJSONObject: interaction))
        return try XCTUnwrap(ChatSideQuestion(interaction: value, session: session))
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
