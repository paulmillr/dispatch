import AppKit
import Term
import XCTest
@testable import DispatchApp

@MainActor
enum CodexTestSupport {
    static let scripts = ["codex_fixture.py", "fixture_barriers.py", "codex_pty.py"]
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func requireBinary() throws -> String {
        let path = TestSupport.tool("codex")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Install supported Codex for local integration tests")
        }
        return path
    }

    static func command(_ mode: String = "launch", state: URL, binary: String, resume: String? = nil, hookDriver: Bool = false) -> String {
        var arguments = ["python3", root.appendingPathComponent("scripts/codex_fixture.py").path,
                         mode, "--state", state.path, "--codex", binary]
        if let resume { arguments += ["--resume", resume] }
        if hookDriver { arguments += ["--hook-driver"] }
        return arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    /// Remove a directory that hosted Codex fixtures once no process uses it.
    /// An exiting Codex writes codex-home/thread-writer-locks; removing the
    /// fixture first lets that write recreate codex-home without its ownership
    /// marker, which the suite's fixture audit rejects.
    nonisolated static func removeFixture(_ directory: URL) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !holders(directory, ["-t"]).isEmpty && ContinuousClock.now < deadline { usleep(50_000) }
        // Who still holds it at the deadline (the wait is the cost; the holder is the evidence).
        let left = holders(directory, [])
        if !left.isEmpty {
            print("Fixture still in use after 10 s:\n" + left)
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// lsof's report of processes with a file or their working directory inside the directory.
    nonisolated private static func holders(_ directory: URL, _ options: [String]) -> String {
        guard FileManager.default.fileExists(atPath: directory.path) else { return "" }
        let lsof = Process(), output = Pipe()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = options + ["+D", directory.resolvingSymlinksInPath().path]
        lsof.standardOutput = output; lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return "" }
        let report = output.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        return String(decoding: report, as: UTF8.self)
    }

    static func process(_ terminal: TerminalView) -> CodexProcess? {
        guard terminal.surface != nil, terminal.foregroundPID > 1 else { return nil }
        let matches = AgentProcess.members(of: pid_t(terminal.foregroundPID)).filter(interactive)
        return matches.count == 1 ? matches[0] : nil
    }

    /// The Codex TUI itself, not one of its service or noninteractive children.
    private static func interactive(_ process: AgentProcess) -> Bool {
        guard URL(fileURLWithPath: process.executable).lastPathComponent == "codex", let arguments = process.arguments else { return false }
        let services: Set<String> = ["exec", "e", "review", "app-server", "mcp-server", "login", "logout", "debug", "sandbox", "completion", "--version", "-V", "--help", "-h"]
        return !arguments.dropFirst().contains { services.contains($0) }
    }

    static func conversationRequests(in state: URL) throws -> [[String: Any]] {
        try String(contentsOf: state.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }.filter { $0["kind"] as? String == "conversation" }
    }

    /// A real native catalog for focused delivery checks. Full catalog browsing
    /// remains in the detailed picker walkthroughs; no application cache is seeded.
    static func transportModelCatalog() throws -> Data {
        let source = root.appendingPathComponent("DispatchTests/Fixtures/codex-command-models.json")
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        var original = try XCTUnwrap((catalog["models"] as? [[String: Any]])?.first)
        let efforts = try XCTUnwrap(original["supported_reasoning_levels"] as? [[String: Any]])
        original["supported_reasoning_levels"] = efforts.filter { ["low", "medium"].contains($0["effort"] as? String ?? "") }
        var alternative = original
        alternative["slug"] = "gpt-5.6-sol"
        alternative["display_name"] = "GPT-5.6 Sol"
        alternative["priority"] = 2
        catalog["models"] = [original, alternative]
        return try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
    }

}

/// Owns the local HTTP endpoint and any daemon in its isolated Codex home.
/// TerminalRuntime still owns each real CLI process.
@MainActor
final class CodexEndpointFixture {
    let binary: String
    let state: URL
    private let process = Process()
    private let hooks: Bool

    init(prefix: String, delay: Double, hooks: Bool = true, state: URL? = nil) throws {
        binary = try TestSupport.fixture("codex.binary", input: TestSupport.tool("codex")) {
            try CodexTestSupport.requireBinary()
        }
        self.state = try TestSupport.fixture("codex.directory", input: [prefix, state?.path ?? ""]) {
            if let state { return state }
            else {
                // Codex's control-socket suffix cannot fit below macOS's long per-user temp path.
                var template = Array(("/private/tmp/" + prefix + "XXXXXX").utf8CString)
                return try template.withUnsafeMutableBufferPointer {
                    guard let path = mkdtemp($0.baseAddress!) else { throw POSIXError(.EIO) }
                    return URL(fileURLWithPath: String(cString: path))
                }
            }
        }
        self.hooks = hooks
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/codex_fixture.py").path,
            "serve", "--state", self.state.path, "--delay", String(delay), "--codex", binary] + (hooks ? [] : ["--no-hooks"])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func start(timeout: Duration, file: StaticString = #filePath, line: UInt = #line) async throws {
        let socket = state.appendingPathComponent("codex-home/app-server-control/app-server-control.sock").resolvingSymlinksInPath().path
        XCTAssertLessThan(socket.utf8.count, MemoryLayout.size(ofValue: sockaddr_un().sun_path),
                          "Codex's control socket exceeds the native path limit: " + socket, file: file, line: line)
        _ = try await AppReplay.run(kind: "fixture.codex.start", input: JSONEncoder().encode(AppReplay.Launch(process))) {
            try self.process.run()
            try await TestSupport.eventually(timeout: timeout, file: file, line: line,
                                             diagnostic: "Local Codex endpoint did not start: " + self.state.path) {
                guard self.process.isRunning else {
                    throw NSError(domain: "CodexEndpointFixture", code: Int(self.process.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: "Local Codex endpoint exited: " + self.state.path])
                }
                guard let data = try? Data(contentsOf: self.state.appendingPathComponent("endpoint.json")),
                      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let port = metadata["port"] as? Int, port > 1 else { return false }
                // prepare() first writes port 1, then rewrites the final config and
                // removes hooks when requested. File existence alone is not readiness.
                return self.hooks || !FileManager.default.fileExists(atPath: self.state.appendingPathComponent("codex-home/hooks.json").path)
            }
            return Data()
        }
    }

    /// Loopback SSH agents share this disposable fixture filesystem. Reading
    /// it here observes CLI consumption independently of the revoked app reader.
    func waitForTurnCompletion(path: String, sessionID: String, turn: String) async throws {
        let root = state.resolvingSymlinksInPath().standardizedFileURL.path
        let transcript = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        _ = try XCTUnwrap(transcript.hasPrefix(root + "/") ? true : nil,
                          "Transcript is outside this fixture: " + transcript)
        let completed = try JSONDecoder().decode(Bool.self, from: await AppReplay.run(kind: "fixture.codex.completed",
            input: JSONEncoder().encode([path, sessionID, turn])) {
            // Codex's rollout: an event_msg task_complete or turn_aborted carrying the turn's id ends it.
            func ended(_ line: Substring) -> Bool {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      record["type"] as? String == "event_msg", let payload = record["payload"] as? [String: Any],
                      ["task_complete", "turn_aborted"].contains(payload["type"] as? String) else { return false }
                return (payload["root_turn_id"] ?? payload["turn_id"]) as? String == turn
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while ContinuousClock.now < deadline {
                let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                if text.split(separator: "\n").contains(where: ended) { return try JSONEncoder().encode(true) }
                try await Task.sleep(for: .milliseconds(25))
            }
            return try JSONEncoder().encode(false)
        })
        if !completed { XCTFail("The real agent did not record completion for turn " + turn) }
    }

    /// Send a synthetic native hook from a real child of the selected fixture TUI.
    func hook(pid: pid_t, payload: Data) async throws -> Data {
        try await AppReplay.run(kind: "fixture.codex.hook", input: JSONEncoder().encode([String(pid), String(decoding: payload, as: UTF8.self)])) {
            let directory = self.state.appendingPathComponent("hook-\(pid)")
            try await TestSupport.eventually { FileManager.default.fileExists(atPath: directory.path) }
            let request = directory.appendingPathComponent("request.json")
            let reply = directory.appendingPathComponent("reply.json")
            try payload.write(to: request, options: .atomic)
            try await TestSupport.eventually(timeout: .seconds(60)) { FileManager.default.fileExists(atPath: reply.path) }
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reply)) as? [String: Any])
            XCTAssertEqual(value["status"] as? Int, 0, "Hook fixture failed: \(value)")
            return Data((try XCTUnwrap(value["output"] as? String)).utf8)
        }
    }

    func stop(removeState: Bool) {
        do {
            let failed = try TestSupport.fixture("codex.stop", input: [state.path, String(removeState)]) {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                let failed = process.processIdentifier > 0 && process.terminationStatus != 0
                if removeState && !failed { CodexTestSupport.removeFixture(state) }
                else { print("Codex fixture retained at " + state.path) }
                return failed
            }
            XCTAssertFalse(failed, "Codex fixture shutdown failed; retained at " + state.path)
        } catch { AppReplay.fail(error); XCTFail("Codex fixture shutdown failed: " + error.localizedDescription) }
    }
}
