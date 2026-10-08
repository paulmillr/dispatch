import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ChatFormattingTests: XCTestCase {
    private var opened: [(chat: ChatCoordinator, root: URL)] = []
    override func tearDown() async throws {
        for (chat, root) in opened { chat.stop(); try? FileManager.default.removeItem(at: root) }
        opened = []
    }
    /// A codex rollout opened as an archived conversation: the helper parses it (chat.page).
    private func archived(_ data: Data) async throws -> ChatSession {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        let meta = lines.lazy.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .first { $0["type"] as? String == "session_meta" }?["payload"] as? [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-formatting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        opened.append((chat, root))
        return try await chat.archived(lines, agent: "codex", session: try XCTUnwrap(meta?["id"] as? String), in: root)
    }
    func testSearchHighlightsRenderedTextWithoutLosingFormatting() throws {
        let original = ChatMarkdown.safeInlineMarkdown("🙂 [Alpha](https://example.com) **alpha**\n`ALPHA`")
        let theme = ChatTheme.standard
        let cases: [(String, [NSRange])] = [
            ("alpha", [.init(location: 3, length: 5), .init(location: 9, length: 5), .init(location: 15, length: 5)]),
            ("ALPHA\nalpha", [.init(location: 9, length: 11)]),
            ("🙂", [.init(location: 0, length: 2)]), ("", []), ("missing", [])
        ]
        for (query, ranges) in cases {
            var expected = original
            let plain = String(original.characters)
            for range in ranges {
                let indices = try XCTUnwrap(Range(range, in: plain))
                let span = try XCTUnwrap(Range(indices, in: expected))
                expected[span].backgroundColor = theme.yellow
                expected[span].foregroundColor = theme.terminal
            }
            XCTAssertEqual(ChatSearchHighlight.text(original, query: query, theme: theme), expected, query)
        }
    }

    func testChatSearchFindsFullTextAndInvalidatesChangedDocuments() async throws {
        let index = ChatSearch()
        let first = ChatSearch.Document(id: "a:text", row: "a", label: "Message", text: "🙂 Alpha alpha")
        let output = ChatSearch.Document(id: "b:output", row: "b", label: "Tool output", text: String(repeating: "x", count: 40_000) + "ALPHA")
        let expected = [ChatSearch.Match(document: first, range: NSRange(location: 3, length: 5)),
                        .init(document: first, range: NSRange(location: 9, length: 5)),
                        .init(document: output, range: NSRange(location: 40_000, length: 5))]
        let found = try await index.matches([first, output], query: "alpha")
        XCTAssertEqual(found, expected)
        XCTAssertEqual(found[0].excerpt.text, "🙂 Alpha alpha")
        XCTAssertEqual(found[0].excerpt.range, NSRange(location: 3, length: 5))
        XCTAssertEqual((found[2].excerpt.text as NSString).substring(with: found[2].excerpt.range), "ALPHA")
        let earlier = ChatSearch.Document(id: "earlier:text", row: "earlier", label: "Message", text: "alpha")
        let prepended = try await index.matches([earlier, first, output], query: "alpha")
        XCTAssertEqual(prepended, [.init(document: earlier, range: NSRange(location: 0, length: 5))] + expected)
        let changed = ChatSearch.Document(id: first.id, row: first.row, label: first.label, text: "changed")
        let replaced = try await index.matches([changed, output], query: "alpha")
        XCTAssertEqual(replaced, [expected[2]])
        let next = try await index.matches([changed, output], query: "changed")
        XCTAssertEqual(next, [.init(document: changed, range: NSRange(location: 0, length: 7))])
        let empty = try await index.matches([changed, output], query: "")
        XCTAssertEqual(empty, [])
    }

    func testNativeToolsShareReadablePresentationAndKeepResults() {
        let cases: [(String, String, [String])] = [
            ("Read", #"{"file_path":"/work/file.swift","offset":3,"limit":2}"#,
             ["Read", "doc.text", "file.swift · lines 3–4", "", "text"]),
            ("Grep", #"{"pattern":"needle","path":"/work/src","glob":"*.swift","output_mode":"content"}"#,
             ["Search", "magnifyingglass", "needle · in src · *.swift", "needle", "text"]),
            ("Glob", #"{"pattern":"**/*.swift","path":"/work"}"#,
             ["Find files", "magnifyingglass", "**/*.swift · in .", "**/*.swift", "text"]),
            ("WebSearch", #"{"query":"Swift actors","allowed_domains":["swift.org"]}"#,
             ["Search web", "magnifyingglass", "Swift actors", "Swift actors", "text"]),
            ("WebFetch", #"{"url":"https://example.com","prompt":"Summarize the page"}"#,
             ["Open page", "globe", "https://example.com", "Summarize the page", "text"]),
            ("Agent", #"{"description":"Review sources","prompt":"Find correctness issues","subagent_type":"Explore"}"#,
             ["Agent", "person.2", "Review sources", "Find correctness issues", "text"]),
            ("Task", #"{"description":"Review sources","prompt":"Find correctness issues"}"#,
             ["Agent", "person.2", "Review sources", "Find correctness issues", "text"]),
            ("TaskCreate", #"{"subject":"Fix bug","description":"Preserve behavior"}"#,
             ["Create task", "checklist", "Fix bug", "Preserve behavior", "text"]),
            ("TaskUpdate", #"{"taskId":"42","status":"completed"}"#,
             ["Update task", "checklist", "42 · completed", "", "text"]),
            ("TaskGet", #"{"taskId":"42"}"#, ["Read task", "checklist", "42", "", "text"]),
            ("TaskList", "{}", ["List tasks", "checklist", "", "", "text"]),
            ("TaskOutput", #"{"task_id":"42"}"#, ["Task output", "checklist", "42", "", "text"]),
            ("TaskStop", #"{"task_id":"42"}"#, ["Stop task", "stop.circle", "42", "", "text"]),
            ("TodoWrite", #"{"todos":[{"content":"Review","status":"completed"},{"content":"Verify","status":"in_progress"}]}"#,
             ["Tasks", "checklist", "2 tasks", "[completed] Review\n[in_progress] Verify", "text"]),
            ("Skill", #"{"skill":"review","args":"src"}"#, ["Skill", "book", "review", "src", "text"]),
            ("EnterPlanMode", "{}", ["Enter plan mode", "list.bullet", "", "", "text"]),
            ("ExitPlanMode", #"{"plan":"Review then test"}"#, ["Review plan", "list.bullet", "", "Review then test", "markdown"]),
            ("AskUserQuestion", #"{"questions":[{"question":"Which?","header":"Choice","options":[{"label":"A","description":"First"},{"label":"B","description":"Second"}]}]}"#,
             ["Questions", "questionmark.bubble", "Choice", "Which?\n• A — First\n• B — Second", "text"]),
            ("NotebookEdit", #"{"notebook_path":"/work/demo.ipynb","cell_id":"abc","edit_mode":"replace","cell_type":"code","new_source":"print(1)"}"#,
             ["Edit notebook", "pencil.line", "demo.ipynb · cell abc · replace", "print(1)", "text"])
        ]
        for (name, input, expected) in cases {
            let item = ChatItem(id: name, kind: .tool, text: input, title: name, output: "Captured result", completed: true)
            let tool = ToolPresentation(item)
            XCTAssertEqual([tool.title, tool.symbol, tool.displaySummary(in: "/work"), tool.input, tool.language], expected, name)
            XCTAssertEqual(tool.documents, [], "Search scopes and captured reads must not become live source previews")
            XCTAssertEqual(tool.output, "Captured result", name)
            XCTAssertEqual([tool.completed, tool.failed, tool.isPatch], [true, false, false], name)
            XCTAssertEqual(item.text, input)
        }
        let bash = ToolPresentation(ChatItem(id: "bash", kind: .tool, text: #"{"command":"printf hello","description":"Greeting"}"#, title: "Bash"))
        XCTAssertEqual([bash.title, bash.input, bash.language], ["Shell", "printf hello", "shell"])
    }

    func testNativeMutationsPreviewOnlyKnownContentsAndRetainFailure() {
        let cases: [(String, String, String, String)] = [
            ("Edit", #"{"file_path":"/work/file.swift","old_string":"old\nline\n","new_string":"new\nline\n","replace_all":true}"#,
             "@@ Replace all occurrences @@\n-old\n-line\n+new\n+line", "file.swift · replace all"),
            ("Edit", #"{"file_path":"/work/file.swift","old_string":"old","new_string":""}"#,
             "@@ Replacement @@\n-old", "file.swift"),
            ("Edit", #"{"file_path":"/work/file.swift","old_string":"","new_string":"new\n"}"#,
             "@@ Replacement @@\n+new", "file.swift"),
            ("Write", #"{"file_path":"/work/file.swift","content":"new\n\n"}"#,
             "@@ Written content @@\n+new\n+", "file.swift"),
            ("Write", #"{"file_path":"/work/file.swift","content":""}"#,
             "@@ Written content (empty) @@", "file.swift"),
            ("MultiEdit", #"{"file_path":"/work/file.swift","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}"#,
             "@@ Replacement @@\n-a\n+b\n@@ Replacement @@\n-c\n+d", "file.swift")
        ]
        for (name, input, diff, summary) in cases {
            let item = ChatItem(id: "edit", kind: .tool, text: input, title: name, output: "Permission denied by hook", completed: true, exitCode: 1)
            let tool = ToolPresentation(item)
            XCTAssertEqual(tool.documents, [ToolDocument(path: "/work/file.swift", diff: diff)], name)
            XCTAssertEqual([tool.title, tool.displaySummary(in: "/work"), tool.input, tool.output],
                           ["Patch", summary, "", "Permission denied by hook"], name)
            XCTAssertEqual([tool.isPatch, tool.failed, tool.completed], [true, true, true], name)
            XCTAssertEqual(ToolDocument.lineNumbers(diff.components(separatedBy: "\n")), diff.components(separatedBy: "\n").map { _ in nil })
            XCTAssertEqual(ChatToolGroupHeader.category(item), "Patch")
        }
    }

    func testUnknownOrMalformedNativeToolsKeepRawInput() {
        for (name, input) in [("FutureTool", #"{"nested":{"value":"keep"}}"#), ("Edit", #"{"file_path":"file","old_string":"old"}"#),
                              ("Grep", #"{"pattern":42}"#), ("TodoWrite", #"{"todos":[{"status":"future"}]}"#)] {
            let tool = ToolPresentation(ChatItem(id: "unknown", kind: .tool, text: input, title: name))
            XCTAssertEqual(ToolPresentation.json(tool.input) as? NSDictionary, ToolPresentation.json(input) as? NSDictionary, name)
        }
    }

    func testWebStepsHaveActionLabelsAndReadableTargets() {
        let cases: [(String, String, String)] = [
            (#"{"search_query":[{"q":"Swift actor isolation"}]}"#, "Search web", "Swift actor isolation"),
            (#"{"image_query":[{"q":"waterfalls"}]}"#, "Search images", "waterfalls"),
            (#"{"open":[{"ref_id":"https://example.com/docs","lineno":40}]}"#, "Open page", "https://example.com/docs · line 40"),
            (#"{"find":[{"ref_id":"turn0search0","pattern":"Installation"}]}"#, "Find on page", "“Installation” · Search result"),
            (#"{"click":[{"ref_id":"turn1view0","id":7}]}"#, "Follow link", "Search result · link 7"),
            (#"{"screenshot":[{"ref_id":"turn1view0","pageno":0}]}"#, "View screenshot", "Search result · page 1"),
            (#"{"weather":[{"location":"Rome, Italy"}]}"#, "Check weather", "Rome, Italy"),
            (#"{"finance":[{"ticker":"AAPL","type":"equity"}]}"#, "Look up prices", "AAPL"),
            (#"{"sports":[{"league":"nba","team":"GSW","fn":"schedule"}]}"#, "Look up sports", "NBA · GSW · schedule"),
            (#"{"time":[{"utc_offset":"+02:00"}]}"#, "Check time", "UTC+02:00")
        ]
        for name in ["web__run", "web.run", "functions.web__run"] {
            for (input, title, summary) in cases {
                let item = ChatItem(id: "web", kind: .tool, text: input, title: name, output: "Result", completed: true)
                let tool = ToolPresentation(item)
                XCTAssertEqual(tool.title, title)
                XCTAssertEqual(tool.summary, summary)
                XCTAssertEqual(tool.symbol, title.hasPrefix("Search") ? "magnifyingglass" : "globe")
                XCTAssertEqual(tool.language, "json")
                XCTAssertNotNil(ToolPresentation.json(tool.input))
                XCTAssertEqual(tool.output, "Result")
                XCTAssertTrue(tool.completed)
            }
        }
        XCTAssertFalse(WebToolPresentation.matches("other.run"))
    }

    func testBatchedWebStepsAndUnknownArgumentsPreserveDetails() {
        let input = #"{"search_query":[{"q":"one"},{"q":"two"}],"open":[{"ref_id":"https://example.com"}],"weather":[{"location":"Rome"}],"response_length":"short"}"#
        let item = ChatItem(id: "batch", kind: .tool, text: input, title: "web__run", output: #"{"content":[{"type":"text","text":"Unavailable"}],"isError":true}"#, completed: true)
        let tool = ToolPresentation(item)
        XCTAssertEqual(tool.title, "Web")
        XCTAssertEqual(tool.summary, "Search web: one · Search web: two · Open page: https://example.com · +1 more")
        XCTAssertTrue(tool.input.contains("Rome"))
        XCTAssertTrue(tool.input.contains("response_length"))
        XCTAssertTrue(tool.failed)
        XCTAssertTrue(tool.output.contains("Unavailable"))
        for input in ["{unfinished", #"{"future_action":[{"target":"keep me"}]}"#, #"{"search_query":"malformed"}"#] {
            let tool = ToolPresentation(ChatItem(id: "unknown", kind: .tool, text: input, title: "web__run"))
            XCTAssertEqual(tool.title, "Web")
            XCTAssertEqual(tool.summary, "Web request")
            XCTAssertFalse(tool.input.isEmpty)
        }
    }

    func testCodexDirectAndWrappedWebCallsBecomeFormattedSteps() async throws {
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "web-fixture"]],
            ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn"]],
            ["type": "response_item", "payload": ["type": "function_call", "call_id": "direct", "name": "web.run", "arguments": #"{"open":[{"ref_id":"https://example.com/docs"}]}"#]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "direct", "output": "Page content"]],
            ["type": "response_item", "payload": ["type": "custom_tool_call", "call_id": "wrapped", "name": "functions.exec", "input": #"text(await tools.web__run({search_query:[{q:"Swift concurrency"}]}));"#]],
            ["type": "response_item", "payload": ["type": "custom_tool_call_output", "call_id": "wrapped", "output": "Search results"]]
        ]
        let session = try await archived(try records.reduce(Data()) { $0 + (try JSONSerialization.data(withJSONObject: $1)) + Data([10]) })
        let group = try XCTUnwrap(session.transcriptRows.first?.group)
        let items = group.children.compactMap(\.item)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map { ToolPresentation($0).title }, ["Open page", "Search web"])
        XCTAssertEqual(items.map { ToolPresentation($0).summary }, ["https://example.com/docs", "Swift concurrency"])
        XCTAssertEqual(items.map { ToolPresentation($0).output }, ["Page content", "Search results"])
        XCTAssertEqual(ChatToolGroupHeader.summarize(items), "Browse web ×2")
    }

    func testDiffRetainsSyntaxColorsAndSeparatesOldAndNewLexicalState() throws {
        let theme = ChatTheme.standard
        let diff = "@@ -1,2 +1,2 @@\n-/* removed\n-old comment */\n+let answer = 42\n+print(\"hello\")\n@@ -10 +10 @@\n+return answer\n"
        let colored = SyntaxHighlight.diffLines(diff, path: "file.swift")
        XCTAssertEqual(colored.map { String($0.characters) }, diff.components(separatedBy: "\n"))
        func color(_ token: String, in row: Int) throws -> Color? {
            let text = String(colored[row].characters)
            let range = try XCTUnwrap(text.range(of: token))
            let lower = try XCTUnwrap(AttributedString.Index(range.lowerBound, within: colored[row]))
            let upper = try XCTUnwrap(AttributedString.Index(range.upperBound, within: colored[row]))
            return colored[row][lower..<upper].foregroundColor
        }
        XCTAssertEqual(try color("+", in: 3), theme.green)
        XCTAssertEqual(try color("-", in: 2), theme.red)
        XCTAssertEqual(try color("old comment */", in: 2), theme.comment)
        XCTAssertEqual(try color("let", in: 3), theme.keyword)
        XCTAssertEqual(try color("42", in: 3), theme.number)
        XCTAssertEqual(try color("\"hello\"", in: 4), theme.string)
        XCTAssertEqual(try color("return", in: 6), theme.keyword)
        XCTAssertEqual(SyntaxHighlight.diffLines("+plain", path: "file.unknown")[0].foregroundColor, theme.green)
    }

    private func contentItemFixture() async throws -> ChatItem {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/codex-content-items.jsonl")
        let session = try await archived(try Data(contentsOf: path))
        return try XCTUnwrap(session.turns.flatMap(\.items).first)
    }
    func testCodexContentItemsDecodeIndividuallyAndPreserveRawDetails() async throws {
        let item = try await contentItemFixture()
        let tool = ToolPresentation(item)
        XCTAssertEqual(tool.summary, "Tool output")
        XCTAssertEqual(tool.outputBlocks.count, 3)
        XCTAssertEqual(tool.output, "## Search results\n\nFound **two files**.\n\n```swift\nlet count = 2\n```\n\nNested tool result\n\nShell output\n")
        if case .markdown = tool.outputBlocks[0].kind {} else { XCTFail("Structured prose should render Markdown") }
        if case .code("text") = tool.outputBlocks[2].kind {} else { XCTFail("Shell output must preserve monospace whitespace") }
        XCTAssertEqual(tool.exitCode, 0); XCTAssertFalse(tool.failed)
        XCTAssertTrue(item.output.contains("input_text")); XCTAssertTrue(item.output.contains("Script completed"))
        XCTAssertFalse(tool.output.contains("input_text")); XCTAssertFalse(tool.output.contains("Wall time"))
    }
    func testMixedContentAndFailureEnvelopesRetainMeaning() {
        let output = #"[{"type":"input_text","text":"Wall time: 1.2500 seconds\nOutput:"},{"type":"input_text","text":"Caption"},{"type":"input_image","image_url":"data:image/png;base64,private-image"},{"type":"input_audio","audio_url":"data:audio/wav;base64,private-audio"},{"type":"future","payload":"Keep me"},{"type":"encrypted_content","encrypted_content":"opaque"}]"#
        let result = ToolOutput.decode(output)
        XCTAssertEqual(result.blocks.count, 5)
        XCTAssertTrue(result.text.contains("Caption")); XCTAssertTrue(result.text.contains("Image")); XCTAssertTrue(result.text.contains("Audio"))
        XCTAssertTrue(result.text.contains("Keep me")); XCTAssertTrue(result.text.contains("Encrypted content"))
        XCTAssertFalse(result.text.contains("base64")); XCTAssertFalse(result.text.contains("opaque"))
        let mcp = ToolPresentation(ChatItem(id: "mcp", kind: .tool, text: "{}", title: "search", output: #"{"content":[{"type":"text","text":"No permission"}],"isError":true,"structuredContent":{"retry":false}}"#))
        XCTAssertTrue(mcp.failed); XCTAssertNil(mcp.exitCode, "MCP failure must not invent a shell exit status")
        XCTAssertTrue(mcp.output.contains("No permission")); XCTAssertTrue(mcp.output.contains("retry"))
        let settled = ToolOutput.decode(#"[{"status":"fulfilled","value":{"output":"ok","exit_code":0}},{"status":"rejected","reason":"Disconnected"}]"#)
        XCTAssertTrue(settled.failed); XCTAssertTrue(settled.text.contains("ok")); XCTAssertTrue(settled.text.contains("Request failed: Disconnected"))
        let failed = ToolOutput.decode(#"[{"type":"input_text","text":"Script failed\nWall time 0.1 seconds\nOutput:\n"},{"type":"input_text","text":"Script error:\nReferenceError: missing"}]"#)
        XCTAssertTrue(failed.failed); XCTAssertTrue(failed.text.contains("ReferenceError"))
        let running = ToolOutput.decode(#"[{"type":"input_text","text":"Script running with cell ID cell-123\nWall time 0.1 seconds\nOutput:\n"}]"#)
        XCTAssertTrue(running.text.contains("still running")); XCTAssertFalse(running.failed)
        for raw in ["Program output\nOutput:\nkeep this", "Script completed\nthis is a log", #"{"output":"data"}"#, #"[{"type":"input_text","text":42}]"#, #"{"content":[],"application":"data"}"#, #"[{"type":"future","data":42}]"#] {
            XCTAssertEqual(ToolOutput.decode(raw).text, raw, "Unknown or malformed envelopes must remain unchanged")
        }
        let nested = (0..<12).reduce("deep content") { value, _ in
            TranscriptParser.printable([["type": "input_text", "text": value]])
        }
        XCTAssertTrue(ToolOutput.decode(nested).text.contains("deep content"), "Recursion must stop without losing raw content")
    }
    func testContentValidationPreservesMalformedMediaBesideValidText() {
        for (type, field, label) in [
            ("input_image", "image_url", "Image"), ("image", "data", "Image"),
            ("input_audio", "audio_url", "Audio"), ("audio", "data", "Audio"),
            ("encrypted_content", "encrypted_content", "Encrypted content")
        ] {
            let valid = TranscriptParser.printable([["type": type, field: "opaque"]])
            let rendered = ToolOutput.decode(valid)
            XCTAssertEqual(rendered.blocks.count, 1)
            XCTAssertTrue(rendered.text.contains(label))
            XCTAssertFalse(rendered.text.contains("opaque"))

            let malformed: [String: Any] = ["type": type, field: 42]
            let raw = TranscriptParser.printable([malformed])
            XCTAssertEqual(ToolOutput.decode(raw).text, raw)
            let mixed = TranscriptParser.printable([["type": "text", "text": "Caption"], malformed])
            let result = ToolOutput.decode(mixed)
            XCTAssertEqual(result.blocks.count, 2)
            XCTAssertEqual(result.blocks.first?.text, "Caption")
            XCTAssertEqual(result.blocks.last?.text, TranscriptParser.printable(malformed))
        }
    }
    func testNativeContentItemsShowReadableOutput() async throws {
        AppFont.register()
        let item = try await contentItemFixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatToolCard(item: item, expanded: .constant(true), directory: "/tmp")
            .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Chrome.terminal).foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        let text = try await PresentationTestSupport.capture(window, named: "content-items", in: "chat-formatting-validation").text()
        for shown in ["Search results", "two files", "let count", "Nested tool result", "Shell output", "Tool details"] { XCTAssertTrue(text.contains(shown), text) }
        for hidden in ["input_text", "Script completed", "Agent activity", "isError", "exit_code", "text(result)"] { XCTAssertFalse(text.contains(hidden), text) }
    }
    func testObservedCodex1534FormattingAndFailure() async throws {
        try await assertObservedFormatting(version: "0.153.4")
    }
    func testObservedCodex1540FormattingAndFailure() async throws {
        try await assertObservedFormatting(version: "0.154.0")
    }
    private func assertObservedFormatting(version: String) async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/codex-formatting-\(version).jsonl")
        let bytes = try Data(contentsOf: path)
        let session = try await archived(bytes)
        let items = session.turns.flatMap(\.items)
        XCTAssertEqual(items.filter { $0.kind == .user }.map(\.text), ["formatting preview"])
        XCTAssertEqual(items.filter { $0.kind == .assistant }.count, 1)
        XCTAssertEqual(items.filter { $0.kind == .tool }.count, 1)
        let tool = ToolPresentation(try XCTUnwrap(items.first { $0.kind == .tool }))
        XCTAssertEqual(tool.title, "Shell")
        XCTAssertEqual(tool.exitCode, 7)
        XCTAssertEqual(tool.output, "Formatting fixture: intentional failure\n")
        XCTAssertTrue(tool.completed)
        let assistant = try XCTUnwrap(items.first { $0.kind == .assistant })
        XCTAssertTrue(ChatMarkdownBlock.parse(assistant.text).contains { $0.kind == .heading(2) })
        XCTAssertTrue(ChatMarkdownBlock.parse(assistant.text).contains { $0.kind == .code("swift") })
        let future = try await archived(Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: version, with: "99.0.0").utf8))
        XCTAssertEqual(future.turns.flatMap(\.items).map(\.text), items.map(\.text), "Recognized record shapes remain readable across CLI versions")
    }
    func testObservedCodexCommandBecomesReadableShellCard() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/codex-observed-0.153.2.jsonl")
        let session = try await archived(try Data(contentsOf: path))
        let items = session.turns.flatMap(\.items)
        XCTAssertEqual(items.filter { $0.kind == .user }.map(\.text), ["tool check"])
        XCTAssertEqual(items.filter { $0.kind == .assistant }.count, 1)
        XCTAssertEqual(items.filter { $0.kind == .tool }.count, 1)
        let tool = ToolPresentation(try XCTUnwrap(items.first { $0.kind == .tool }))
        XCTAssertEqual(tool.title, "Shell")
        XCTAssertEqual(tool.input, "printf 'DISPATCH_LOCAL_TOOL_OK\\n'")
        XCTAssertEqual(tool.summary, tool.input)
        XCTAssertEqual(tool.output, "DISPATCH_LOCAL_TOOL_OK\n")
        XCTAssertEqual(tool.exitCode, 0)
        XCTAssertTrue(tool.completed)
    }
    func testArgumentArraysPreserveQuotingAndShellPositionalArguments() {
        XCTAssertEqual(ToolPresentation.command(["/bin/zsh", "-lc", "printf '%s' \"a b\""]), "printf '%s' \"a b\"")
        XCTAssertEqual(ToolPresentation.command(["printf", "%s", "", "a b", "it's", "$(touch x)"]), "printf %s '' 'a b' 'it'\\''s' '$(touch x)'")
        XCTAssertEqual(ToolPresentation.command(["bash", "-c", "echo $0", "name"]), "bash -c 'echo $0' name")
        let search = ToolPresentation(ChatItem(id: "search", kind: .tool, text: #"{"cmd":"rg --files src","workdir":"/tmp/project"}"#, title: "functions.exec_command"))
        XCTAssertEqual(search.title, "Find files")
        XCTAssertEqual(search.summary, "in src")
        XCTAssertEqual(search.directory, "/tmp/project")
        let exec = ToolPresentation(ChatItem(id: "exec", kind: .tool, text: "const results = await Promise.allSettled([]);", title: "functions.exec"))
        XCTAssertEqual(exec.title, "Tools"); XCTAssertTrue(exec.input.isEmpty)
        XCTAssertEqual(exec.summary, "Agent activity")
    }
    func testOrchestrationIsRawOnlyAndLiteralRequestsAreReadable() {
        let code = #"text(await tools.exec_command({"cmd":"rg --files src","workdir":"/tmp"}));"#
        let item = ChatItem(id: "exec", kind: .tool, text: code, title: "functions.exec", output: #"{"output":"src/main.swift","exit_code":0}"#)
        let tool = ToolPresentation(item)
        XCTAssertTrue(tool.isOrchestration)
        XCTAssertTrue(tool.input.isEmpty)
        XCTAssertEqual(tool.summary, "in src")
        XCTAssertEqual(tool.output, "src/main.swift")
        XCTAssertEqual(tool.requests.count, 1)
        XCTAssertEqual(ToolPresentation(tool.requests[0]).input, "rg --files src")
        XCTAssertFalse(tool.requests[0].completed, "A parent result cannot prove a nested call completed")
        XCTAssertEqual(item.text, code, "Raw details must retain the exact original payload")
        let multiple = #"const results = await Promise.allSettled([tools.exec_command({"cmd":"echo one"}), tools.shell_command({"command":"echo two"})]); results.forEach(text);"#
        XCTAssertEqual(ToolOrchestration.requests(in: multiple).map { ToolPresentation($0).input }, ["echo one", "echo two"])
        let patch = #"text(await tools.apply_patch("*** Begin Patch\n*** Add File: hello.swift\n+let hello = true\n*** End Patch"));"#
        XCTAssertEqual(ToolOrchestration.requests(in: patch).flatMap(ToolDocument.parse).first?.path, "hello.swift")
    }
    func testOrchestrationDoesNotGuessComputedArgumentsOrCallsInsideText() {
        let examples = [
            #"text(await tools.exec_command(arguments));"#,
            #"text(await tools.exec_command({"cmd": prefix + command}));"#,
            #"const example = 'tools.exec_command({"cmd":"not a call"})';"#,
            #"// tools.exec_command({"cmd":"comment"})"#,
            #"/* tools.exec_command({"cmd":"comment"}) */"#,
            #"const pattern = /tools.exec_command({"cmd":"regex"})/;"#,
            #"const code = `tools.exec_command({"cmd":"template"})`;"#,
            #"other.tools.exec_command({"cmd":"different object"});"#,
            #"text(await tools.exec_command({"cmd":"partial""#
        ]
        for code in examples {
            let tool = ToolPresentation(ChatItem(id: "exec", kind: .tool, text: code, title: "functions.exec"))
            XCTAssertTrue(tool.requests.isEmpty, code)
            XCTAssertTrue(tool.input.isEmpty, code)
            XCTAssertEqual(tool.summary, "Agent activity", code)
        }
    }
    func testNativeExpandedOrchestrationHidesCode() async throws {
        AppFont.register()
        let item = ChatItem(id: "exec", kind: .tool,
            text: #"text(await tools.exec_command({"cmd":"swift build","workdir":"/tmp"}));"#,
            title: "functions.exec", output: #"{"output":"Build complete","exit_code":0}"#)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatToolCard(item: item, expanded: .constant(true), directory: "/tmp")
            .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Chrome.terminal).foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        let text = try await PresentationTestSupport.capture(window, named: "orchestration", in: "chat-formatting-validation").text()
        XCTAssertTrue(text.contains("Build"), text)
        XCTAssertTrue(text.contains("Swift"), text)
        XCTAssertFalse(text.contains("swift build"), text)
        XCTAssertTrue(text.contains("Build complete"), text)
        XCTAssertTrue(text.contains("Tool details"), text)
        for hidden in ["text(await", "exec_command", "functions.exec", "workdir", "Raw input", "JavaScript"] {
            XCTAssertFalse(text.contains(hidden), text)
        }
    }
    func testOutputEnvelopesAndFailuresDoNotObscureProgramOutput() {
        let raw = #"[{"status":"fulfilled","value":{"output":"first\n","exit_code":0}},{"status":"fulfilled","value":{"output":"second\n","exit_code":7}}]"#
        let tool = ToolPresentation(ChatItem(id: "x", kind: .tool, text: #"{"cmd":"exit 7"}"#, title: "exec_command", output: raw))
        XCTAssertEqual(tool.output, "first\n\n\nsecond\n")
        XCTAssertTrue(tool.failed); XCTAssertEqual(tool.exitCode, 7)
        for text in [#"{"output":"Application data"}"#, "My program\nOutput:\nkeep this", "[1,2,3]", "not JSON {", ""] {
            XCTAssertEqual(ToolPresentation.result(text).text, text)
        }
        let empty = ToolPresentation(ChatItem(id: "empty", kind: .tool, text: "true", title: "Shell", completed: true, exitCode: 0))
        XCTAssertTrue(empty.completed); XCTAssertEqual(empty.output, "")
    }
    func testPatchSummaryShowsFilesAndCounts() {
        let item = ChatItem(id: "patch", kind: .tool, text: "*** Begin Patch\n*** Update File: src/a.swift\n@@\n-old\n+new\n+more\n*** End Patch", title: "apply_patch", output: "Success")
        let tool = ToolPresentation(item)
        XCTAssertEqual(tool.title, "Patch"); XCTAssertEqual(tool.summary, "src/a.swift")
        XCTAssertEqual(tool.additions, 2); XCTAssertEqual(tool.deletions, 1)
        XCTAssertTrue(tool.input.isEmpty)
    }
    func testSyntaxTokensRespectStringsCommentsUnicodeAndUnknownLanguages() {
        let code = "/* let 42\nreturn */\nlet greeting = \"hello 🦊 return 5\"\nlet count = 42"
        let value = SyntaxHighlight.text(code, language: "example.swift")
        XCTAssertEqual(String(value.characters), code)
        func color(_ substring: String) -> Color? {
            let range = value.range(of: substring)!
            return value[range].foregroundColor
        }
        XCTAssertEqual(color("/* let 42\nreturn */"), SyntaxHighlight.comment)
        XCTAssertEqual(color("\"hello 🦊 return 5\""), SyntaxHighlight.string)
        XCTAssertEqual(color("count"), Chrome.ink)
        XCTAssertEqual(SyntaxHighlight.text("let", language: "swift").foregroundColor, SyntaxHighlight.keyword)
        XCTAssertEqual(SyntaxHighlight.text("42", language: "json").foregroundColor, SyntaxHighlight.number)
        XCTAssertEqual(SyntaxHighlight.text("let 42", language: "unknown").foregroundColor, Chrome.ink)
        XCTAssertEqual(SyntaxHighlight.lines("/* hello\nworld */", language: "swift")[1].foregroundColor, SyntaxHighlight.comment)
        let large = String(repeating: "a", count: 70_000)
        XCTAssertEqual(String(SyntaxHighlight.text(large, language: "swift").characters), large)
    }
    func testMarkdownFencesListsAndTablesPreserveContent() {
        let source = "## Heading\n\nUse `inline` code.\n\n- [x] Done\n  1. Nested\n\n> Quote\n\n| Name | Value |\n| --- | --- |\n| `a|b` | x\\|y |\n\n````swift\nlet fence = \"```\"\n````\n\n~~~python\nprint('unfinished')"
        let blocks = ChatMarkdownBlock.parse(source)
        XCTAssertEqual(blocks[0], .init(kind: .heading(2), text: "Heading"))
        XCTAssertTrue(blocks.contains(.init(kind: .list("☑", 0), text: "Done")))
        XCTAssertTrue(blocks.contains(.init(kind: .list("1.", 1), text: "Nested")))
        XCTAssertTrue(blocks.contains(.init(kind: .table([["Name", "Value"], ["`a|b`", "x\\|y"]]), text: "")))
        XCTAssertTrue(blocks.contains(.init(kind: .code("swift"), text: "let fence = \"```\"")))
        XCTAssertEqual(blocks.last, .init(kind: .code("python"), text: "print('unfinished')"))
    }
    func testSelectableMarkdownPreservesFormattingAndWrapping() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Native selection bridge requires macOS 26") }
        AppFont.register()
        let theme = ChatTheme.standard
        let source = "# Heading\n\n**Bold** *italic* ~~strike~~ `code` [link](https://example.com) café 日本語\n\n> Muted quote\n\n| Column | Value |\n| --- | --- |\n| Row | Cell |"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatMarkdown(text: source).font(theme.typography.body).padding(20))
        window.makeKeyAndOrderFront(nil)
        let root = try XCTUnwrap(window.contentView)
        try await TestSupport.eventually { !PresentationTestSupport.views(of: NSTextView.self, in: root).isEmpty }
        root.layoutSubtreeIfNeeded()
        let views = PresentationTestSupport.views(of: NSTextView.self, in: root)
        let body = try XCTUnwrap(views.first { $0.string.hasPrefix("Bold") })
        let text = body.attributedString()
        let plain = text.string as NSString
        func font(_ word: String) throws -> NSFont {
            try XCTUnwrap(text.attribute(.font, at: plain.range(of: word).location, effectiveRange: nil) as? NSFont)
        }
        XCTAssertEqual(body.string, "Bold italic strike code link café 日本語")
        XCTAssertEqual([body.isEditable, body.isSelectable, body.acceptsFirstMouse(for: nil)], [false, true, true])
        XCTAssertTrue(try font("Bold").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try font("italic").fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertEqual(try font("code").fontName, theme.typography.codeFontName)
        XCTAssertEqual(text.attribute(.strikethroughStyle, at: plain.range(of: "strike").location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        let link = plain.range(of: "link").location
        XCTAssertEqual(text.attribute(.link, at: link, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        XCTAssertEqual(text.attribute(.underlineStyle, at: link, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        let quote = try XCTUnwrap(views.first { $0.string == "Muted quote" })
        XCTAssertEqual(quote.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor(theme.muted))
        let heading = try XCTUnwrap(views.first { $0.string == "Heading" })
        XCTAssertEqual((heading.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, theme.typography.pointSize(offset: 7.5))
        let column = try XCTUnwrap(views.first { $0.string == "Column" })
        let columnFont = try XCTUnwrap(column.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertNotEqual(columnFont.fontName, try font("café").fontName)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        body.setSelectedRange(NSRange(location: 0, length: text.length))
        XCTAssertEqual(body.selectedRange(), NSRange(location: 0, length: text.length))
        XCTAssertTrue(body.writeSelection(to: board, types: body.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), body.string)
        let height = body.bounds.height
        window.setContentSize(NSSize(width: 240, height: 480))
        try await TestSupport.eventually { body.bounds.height > height }
        let container = try XCTUnwrap(body.textContainer), layout = try XCTUnwrap(body.layoutManager)
        layout.ensureLayout(for: container)
        XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxY, body.bounds.height)
        XCTAssertEqual(body.attributedString(), text)
    }

    func testMarkdownAllowsWebAndSourceLinks() {
        let value = ChatMarkdown.safeInlineMarkdown(
            "[secure](https://example.com/docs) [web](http://example.com) [file](file:///etc/passwd) " +
            "[shell](ssh://host.test) [script](javascript:alert%281%29) [credential](https://user:pass@example.com)")
        let links = value.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(links, ["https://example.com/docs", "http://example.com", "file:///etc/passwd"])
        let rendered = String(value.characters)
        for label in ["secure", "web", "file", "shell", "script", "credential"] {
            XCTAssertTrue(rendered.contains(label))
        }
    }
    func testMarkdownSourceCitationsPreserveLabelsAndLineNumbers() throws {
        let value = ChatMarkdown.safeInlineMarkdown(
            "[Code](/tmp/project/Sources/Example.swift:1305) " +
            "[`My File.swift`](</tmp/My File.swift:42:3>) [fragment](/tmp/a.swift#L15C2) " +
            "[remote](//example.com/a.swift) [relative](src/a.swift)")
        XCTAssertEqual(String(value.characters), "Code My File.swift fragment remote relative")
        let links = value.runs.compactMap { $0.link }.compactMap(ChatFileLink.init)
        XCTAssertEqual(links.map(\.path), ["/tmp/project/Sources/Example.swift", "/tmp/My File.swift", "/tmp/a.swift"])
        XCTAssertEqual(links.map(\.line), [1305, 42, 15])
        for url in ["ssh://host/tmp/a", "file://host/tmp/a", "//host/tmp/a", "/tmp/a?run=1", "/tmp/a%00.swift"] {
            XCTAssertNil(ChatFileLink(try XCTUnwrap(URL(string: url))), url)
        }
        let link = try XCTUnwrap(links.first)
        let source = (1...1500).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        let excerpt = link.excerpt(source)
        XCTAssertEqual(excerpt.firstLine, 1265)
        XCTAssertTrue(excerpt.text.contains("let line1305 = 1305"))
        XCTAssertLessThan(excerpt.text.count, 10_000)
    }

    func testSourceCitationPreviewShowsCitedLineBeyondNormalPreviewLimit() async throws {
        AppFont.register()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift")
        try (1...1500).map { "let line\($0) = \"source citation preview fixture\"" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatMarkdown(text: "[Code](\(file.path):1305)").padding(20))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        let content = try XCTUnwrap(window.contentView)
        let source = try await PresentationTestSupport.capture(window, named: "source-link", in: "chat-formatting-validation")
        let label = try XCTUnwrap([source, source.enlarged].lazy.compactMap { snapshot in
            try? snapshot.recognizedText().first { $0.topCandidates(1).first?.string == "Code" }
        }.first)
        let point = NSPoint(x: label.boundingBox.midX * content.bounds.width,
                            y: (content.isFlipped ? 1 - label.boundingBox.midY : label.boundingBox.midY) * content.bounds.height)
        try PresentationTestSupport.click(window, at: content.convert(point, to: nil))
        try await Task.sleep(for: .milliseconds(700))
        let sheet = try XCTUnwrap(window.attachedSheet, "Clicking a source citation must open its preview")
        let snapshot = try await PresentationTestSupport.capture(sheet, named: "source-citation", in: "chat-formatting-validation")
        let text = try snapshot.text()
        XCTAssertTrue(text.contains("line1305"), text)
        let header = try snapshot.text(in: CGRect(x: 0, y: 0.86, width: 1, height: 0.14))
        // macOS 27 OCR reads this small dim header as "current" (drawn "Current").
        XCTAssertTrue(["Current file on disk", "current file on disk"].contains { header.contains($0) }, header)
    }
    func testCompletionSurvivesOverlappingTranscriptAndHooks() {
        let session = ChatSession(id: UUID())
        session.insert(ChatItem(id: "tool", kind: .tool, text: "false", title: "Shell", completed: true, exitCode: 1), turnID: "turn")
        session.insert(ChatItem(id: "tool", kind: .tool, text: "", output: ""), turnID: "turn")
        let tool = ToolPresentation(session.turns[0].items[0])
        XCTAssertTrue(tool.failed); XCTAssertTrue(tool.completed)
    }
    func testNativeFormattedCardsAndMarkdown() async throws {
        AppFont.register()
        let shell = ChatItem(id: "shell", kind: .tool, text: #"["/bin/zsh","-lc","printf 'Formatting fixture\\n'; exit 7"]"#, title: "Shell", output: "Formatting fixture\n", completed: true, exitCode: 7)
        let search = ChatItem(id: "read", kind: .tool, text: #"{"cmd":"rg --files src"}"#, title: "exec_command", output: "src/billing.swift")
        let patch = ChatItem(id: "patch", kind: .tool, text: "*** Begin Patch\n*** Update File: src/billing.swift\n@@\n-let key = attempt.id\n+let key = event.id\n*** End Patch", title: "apply_patch", output: "Success")
        let markdown = "## Idempotent retries\n\nRetries now use the **event ID**, stored as `event.id`.\n\n- Read the billing handler\n- [x] Apply the retry guard\n\n```swift\n// Stable across retries\nlet key = event.id\nlet message = \"Ready\"\n```\n\n| Check | Result |\n| --- | --- |\n| Formatting | Ready |"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 880), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        for expanded in [false, true] {
            window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
                ChatToolCard(item: search, expanded: .constant(false), directory: "/tmp")
                ChatToolCard(item: patch, expanded: .constant(false), directory: "/tmp")
                ChatToolCard(item: shell, expanded: .constant(expanded), directory: "/tmp")
                ChatMarkdown(text: markdown)
                Spacer(minLength: 0)
            }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Chrome.terminal).foregroundStyle(Chrome.ink).font(AppFont.ui(size: 12.5)).preferredColorScheme(.dark))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            let snapshot = try await PresentationTestSupport.capture(window, named: expanded ? "expanded" : "collapsed", in: "chat-formatting-validation")
            let rows = try snapshot.recognizedText()
            let text = try snapshot.text()
            XCTAssertTrue(text.contains("Shell"), text)
            XCTAssertTrue(text.contains("Find files"), text)
            XCTAssertTrue(text.contains("Patch"), text)
            XCTAssertTrue(text.contains("exit 7"), text)
            XCTAssertTrue(text.contains("Idempotent retries"), text)
            XCTAssertFalse(text.contains("/bin/zsh"), text)
            XCTAssertFalse(text.contains("exec_command"), text)
            let codeLine = try XCTUnwrap(rows.first { $0.topCandidates(1).first?.string.contains("let key") == true })
            XCTAssertLessThan(codeLine.boundingBox.minX, 0.2, "Code must align with the left inset, even in a wide window")
            if expanded { XCTAssertTrue(text.contains("Command"), text); XCTAssertTrue(text.contains("Tool details"), text) }
        }
    }
}
