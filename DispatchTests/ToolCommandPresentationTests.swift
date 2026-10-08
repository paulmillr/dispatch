import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ToolCommandPresentationTests: XCTestCase {
    func testActionLabelsPreserveExactCommands() throws {
        let examples = [
            ("rg -n 'reconnect' Dispatch/", "Search", "reconnect · in Dispatch/", "Searching…"),
            ("rg -n 'a|b' 'My Sources'", "Search", "a|b · in My Sources", "Searching…"),
            ("rg --files src", "Find files", "in src", "Finding files…"),
            ("rg --files", "Find files", "in current directory", "Finding files…"),
            ("grep -n 'reconnect' file.swift", "Search", "reconnect · in file.swift", "Searching…"),
            ("grep 'reconnect'", "Search", "reconnect · in standard input", "Searching…"),
            ("git status --short", "Check working-tree changes", "", "Checking changes…"),
            ("git diff -- file.swift", "Review changes", "file.swift", "Reviewing changes…"),
            ("git diff --cached -- file.swift", "Review changes", "Staged · file.swift", "Reviewing changes…"),
            ("git diff", "Review changes", "", "Reviewing changes…"),
            ("swift test", "Run tests", "Swift", "Running tests…"),
            ("swift build", "Build", "Swift", "Building…"),
            ("cargo test", "Run tests", "Rust", "Running tests…")
        ]
        for (command, title, summary, running) in examples {
            let tool = presentation(command)
            XCTAssertEqual(tool.title, title, command)
            XCTAssertEqual(tool.summary, summary, command)
            XCTAssertEqual(tool.displayTitle, running, command)
            XCTAssertEqual(tool.input, command)
            XCTAssertTrue(tool.usesRawDetails)
            let finished = presentation(command, output: "", exitCode: 0)
            XCTAssertEqual(finished.displayTitle, title, command)
            XCTAssertTrue(finished.completed)
        }
    }

    func testLabelsSkipCdIntoTheRecordedDirectoryButDetailsKeepIt() async throws {
        // Claude's Bash input has no directory; the transcript record's cwd supplies it.
        let command = "cd /repo/app; sed -n 1,40p Sources/Main.swift"
        let record = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "uuid": "a1", "sessionId": "00000000-0000-4000-8000-000000000103", "cwd": "/repo/app",
            "timestamp": "2000-01-01T10:00:00.000Z", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": command, "description": "Read"]]]]
        ]) + Data([10])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-tool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop(); try? FileManager.default.removeItem(at: root) }
        let state = try await chat.archived(String(decoding: record, as: UTF8.self).split(separator: "\n").map(String.init),
                                            agent: "claude", session: "00000000-0000-4000-8000-000000000103", in: root)
        let item = try XCTUnwrap(state.turns.flatMap(\.items).first { $0.kind == .tool })
        let read = ToolPresentation(item)
        XCTAssertEqual(read.title, "Read")
        XCTAssertEqual(read.displaySummary(in: "/repo/app"), "Main.swift · lines 1–40")
        XCTAssertEqual(read.input, command)

        for (command, directory, summary) in [
            ("cd /repo && git status --short", "/repo/", ""),
            ("cd '/my repo' && make build", "/my repo", "make build"),
            // Another directory, a relative one, or a non-sequential operator still shows.
            ("cd /other && make build", "/repo", "cd /other && make build"),
            ("cd sub && make build", "/repo", "cd sub && make build"),
            ("cd /repo || make build", "/repo", "cd /repo || make build"),
            ("cd /repo & make build", "/repo", "cd /repo & make build"),
            ("cd /repo;", "/repo", "cd /repo;"),
        ] {
            let tool = ToolPresentation(ChatItem(id: UUID().uuidString, kind: .tool, text: json(["cmd": command, "workdir": directory]),
                                                 title: "exec_command"))
            XCTAssertEqual(tool.displaySummary(in: directory), summary, command)
            XCTAssertEqual(tool.input, command)
        }
    }

    func testCompoundCommandsAndUnrecognizedFlagsStayVisible() {
        for command in ["rg foo src | head", "rg -v foo src", "rg --replace bar foo src", "rg -n \"$QUERY\" src",
                        "git status; git diff", "git diff --no-index a b", "git diff HEAD~1", "git diff -- ':!vendor'",
                        "swift test && swift build", "swift test --filter Foo", "cargo test --help", "env swift build"] {
            let tool = presentation(command)
            XCTAssertNil(tool.commandPresentation, command)
            XCTAssertFalse(tool.usesRawDetails, command)
            XCTAssertEqual(tool.summary, command)
            XCTAssertEqual(tool.input, command)
        }
    }

    func testMultilineReadAndStatusStepsUseReadableSummaries() {
        let reads = "sed -n '55,100p' Dispatch/Settings.swift\nsed -n '113,128p' Dispatch/Settings.swift"
        let read = presentation(reads, output: "captured lines", exitCode: 0)
        XCTAssertEqual(read.title, "Read files")
        XCTAssertEqual(read.summary, "Settings.swift · lines 55–100 · Settings.swift · lines 113–128")
        XCTAssertEqual(read.input, reads)
        XCTAssertNil(read.sourceReadPreview, "Combined output must not be numbered as a single file excerpt")
        XCTAssertTrue(read.usesRawDetails)

        let status = "git status --short\nrg -n 'Session stats' Dispatch\nsed -n '188,230p' Dispatch/Views/ChatView.swift"
        let batch = presentation(status)
        XCTAssertEqual(batch.title, "Run commands")
        XCTAssertTrue(batch.summary.contains("Check working-tree changes"))
        XCTAssertTrue(batch.summary.contains("Search · Session stats"))
        XCTAssertTrue(batch.summary.contains("Read ChatView.swift · lines 188–230"))
        let absolute = presentation("cat /repo/A/B/file.swift\nsed -n '2p' /repo/C/other.swift")
        XCTAssertEqual(absolute.displaySummary(in: "/repo"), "file.swift · other.swift · line 2")
        XCTAssertEqual(batch.input, status)
        XCTAssertFalse(batch.summary.contains("git status"))
        XCTAssertFalse(batch.summary.contains("sed -n"))

        let complex = "git status --short\npython3 - <<'PY'\nswift test\nPY"
        let partial = presentation(complex)
        XCTAssertEqual(partial.summary, "Check working-tree changes · additional commands")
        XCTAssertEqual(partial.input, complex)
        XCTAssertNil(partial.confirmedResult)
        XCTAssertNil(presentation("printf 'first\ngit status --short\nlast'").commandPresentation)
        XCTAssertNil(presentation("git status --short\\\nswift test").commandPresentation)
    }

    func testReadingDiffsDoesNotClaimToApplyPatches() {
        let diff = "diff --git a/file.swift b/file.swift\n--- a/file.swift\n+++ b/file.swift\n@@ -1 +1 @@\n-old\n+new\n"
        for command in ["git diff -- file.swift", "git diff -- file.swift; rg -n pattern Sources", "git diff HEAD~1"] {
            let item = ChatItem(id: "review", kind: .tool, text: json(["cmd": command]), title: "exec_command", output: diff, completed: true)
            let tool = ToolPresentation(item)
            XCTAssertEqual(tool.title, "Review changes", command)
            XCTAssertFalse(tool.isPatch, command)
            XCTAssertEqual(tool.documents.first?.path, "file.swift")
            XCTAssertTrue(tool.documents.first?.diff.contains("+new") == true)
            XCTAssertEqual(tool.input, command)
            XCTAssertEqual(ChatToolGroupHeader.summarize([item]), "")
        }
        let item = ChatItem(id: "edit", kind: .tool,
                            text: "*** Begin Patch\n*** Update File: file.swift\n@@\n-old\n+new\n*** End Patch",
                            title: "functions.apply_patch", completed: true)
        XCTAssertEqual(ToolPresentation(item).title, "Patch")
        XCTAssertTrue(ToolPresentation(item).isPatch)
        XCTAssertEqual(ChatToolGroupHeader.summarize([item]), "Patch")
    }

    func testRunningOutputAndTerminalPollingDoNotLookFinished() {
        let running = #"{"output":"Building tests…","session_id":123,"wall_time_seconds":0.1}"#
        let tool = presentation("swift test", envelope: running, completed: true)
        XCTAssertFalse(tool.completed)
        XCTAssertEqual(tool.displayTitle, "Running tests…")
        XCTAssertNil(tool.confirmedResult)
        let legacy = "Chunk ID: abc\nWall time: 0.1 seconds\nProcess running with session ID 123\nOutput:\nBuilding…"
        XCTAssertFalse(presentation("swift build", envelope: legacy).completed)
        var streaming = ChatItem(id: "stream", kind: .tool, text: "swift test", title: "shell", output: "Compiling…")
        streaming.processID = "123"
        XCTAssertEqual(ToolPresentation(streaming).displayTitle, "Running tests…")
        XCTAssertFalse(ToolPresentation(streaming).completed)
        for chars in [nil, ""] as [String?] {
            var input: [String: Any] = ["session_id": 123]
            if let chars { input["chars"] = chars }
            let item = ChatItem(id: "poll", kind: .tool, text: json(input), title: "write_stdin", output: running, completed: true)
            let wait = ToolPresentation(item)
            XCTAssertEqual(wait.displayTitle, "Waiting for the command…")
            XCTAssertTrue(wait.usesRawDetails)
            XCTAssertEqual(wait.input, item.text)
        }
        let input = ToolPresentation(ChatItem(id: "input", kind: .tool, text: #"{"session_id":123,"chars":"yes\n"}"#, title: "write_stdin"))
        XCTAssertEqual(input.title, "Terminal input")
        XCTAssertFalse(input.usesRawDetails)
        let batch = #"[{"status":"fulfilled","value":{"output":"one","exit_code":0}},{"status":"fulfilled","value":{"output":"two","session_id":123}}]"#
        XCTAssertTrue(ToolOutput.decode(batch).running)
        let script = "Script running with cell ID abc\nWall time 0.1 seconds\nOutput:\n"
        XCTAssertTrue(ToolOutput.decode(script).running)
        XCTAssertFalse(ToolOutput.decode(#"{"session_id":123,"app_data":true}"#).running)
    }

    func testOnlyConfirmedOverallTestTotalsBecomeResults() {
        let total = "Test Suite 'All tests' passed at 2026-09-16 21:00:00.\n\t Executed 12 tests, with 0 failures (0 unexpected) in 0.5 (0.6) seconds\n"
        let modern = "✔ Test run with 8 tests in 2 suites passed after 0.3 seconds.\n"
        XCTAssertEqual(presentation("swift test", output: total, exitCode: 0).confirmedResult, "12 tests passed")
        XCTAssertEqual(presentation("swift test", output: modern, exitCode: 0).confirmedResult, "8 tests passed")
        for output in ["12 tests passed", total.replacingOccurrences(of: "All tests", with: "OneSuite"),
                       total.replacingOccurrences(of: "0 failures", with: "1 failure"), total + modern,
                       total + "... tokens truncated ...", "✔ Test run with 0 tests passed after 0.1 seconds."] {
            XCTAssertNil(presentation("swift test", output: output, exitCode: 0).confirmedResult, output)
        }
        XCTAssertNil(presentation("swift test", output: total, exitCode: 1).confirmedResult)
        XCTAssertNil(presentation("swift build", output: total, exitCode: 0).confirmedResult)
        XCTAssertNil(presentation("swift test", envelope: json(["output": total, "session_id": 123])).confirmedResult)
    }

    func testHumanizedCardsKeepCommandsInDetails() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let commands = ["rg -n 'reconnect' Dispatch/", "git status --short", "git diff -- file.swift", "swift test", "swift build",
                        "sed -n '55,100p' Settings.swift\nsed -n '113,128p' Settings.swift",
                        "git status --short\nrg -n 'Session stats' Dispatch"]
        let items = commands.enumerated().map { index, command in
            ChatItem(id: "action-\(index)", kind: .tool, text: json(["cmd": command]), title: "exec_command",
                     completed: index < 3, exitCode: index < 3 ? 0 : nil)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        var theme = ChatTheme.standard; theme.typography.size = 17
        window.contentView = NSHostingView(rootView: VStack(spacing: 10) {
            ForEach(items) { item in ChatToolCard(item: item, expanded: .constant(item.id == "action-1"), directory: "/repo") }
        }.environment(\.chatTheme, theme).padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.terminal).foregroundStyle(theme.ink).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        let text = try await PresentationTestSupport.capture(window, named: "humanized-commands", in: "chat-formatting-validation").text()
        for shown in ["Search", "reconnect", "Check working-tree changes", "Review changes", "Running tests", "Building", "Done", "Raw details", "Reading files", "Settings.swift", "Running commands"] {
            XCTAssertTrue(text.contains(shown), text)
        }
        for hidden in ["rg -n", "git status", "sed -n", "swift test", "swift build", "Completed with no output"] {
            XCTAssertFalse(text.contains(hidden), text)
        }
    }

    private func presentation(_ command: String, output: String = "", exitCode: Int? = nil,
                              envelope: String? = nil, completed: Bool = false) -> ToolPresentation {
        var result: [String: Any] = ["output": output]
        if let exitCode { result["exit_code"] = exitCode }
        return ToolPresentation(ChatItem(id: UUID().uuidString, kind: .tool, text: json(["cmd": command]), title: "exec_command",
                                         output: envelope ?? (exitCode != nil ? json(result) : output), completed: completed))
    }
    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
