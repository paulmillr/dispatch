import XCTest
@testable import DispatchMobile

/// M5d's model: a turn's patches as files with counts and numbered lines (the shared `ToolDocument` parsing), the whole
/// file with the hunks inside it, and the states of reading it.
@MainActor
final class CodeDiffTests: XCTestCase {
    /// The recorded Claude thread (the real helper's `chat.page` replies): turn 2 edits two files.
    private func claudeTurns() throws -> [ChatTurn] {
        var transcript = MobileTranscript()
        transcript.apply(try JSONDecoder().decode([HelperChat.Record].self, from: JSONSerialization.data(
            withJSONObject: try ChatFixture.records("claude-thread"))), historical: true)
        return transcript.turns
    }

    func testRecordedClaudeEditsBecomeFilesWithCounts() throws {
        let turns = try claudeTurns()
        let steps = ChatStep.steps(turns[1], directory: "/work/app", reasoning: false).filter { $0.kind == .patch }
        let changes = DiffChanges(items: steps.map(\.item), directory: "/work/app")
        XCTAssertEqual(changes.files.map(\.title), ["src/lib/idempotent.ts", "src/routes/invoices.ts"])
        XCTAssertEqual(changes.files.map(\.additions), [2, 2])
        XCTAssertEqual(changes.files.map(\.deletions), [1, 3])
        XCTAssertEqual(changes.fileCount, "2 files")
        XCTAssertEqual(changes.additions, 4)
        XCTAssertEqual(changes.deletions, 4)
        // Each file's counts agree with the step's own (the helper's tool record, ChatStep's +/−).
        XCTAssertEqual(steps.map(\.additions), changes.files.map(\.additions))
        XCTAssertEqual(steps.map(\.deletions), changes.files.map(\.deletions))
        let lines = changes.files[1].lines
        XCTAssertEqual(lines.map(\.kind), [.hunk, .removed, .removed, .removed, .added, .added])
        XCTAssertEqual(lines.map(\.text), ["@@ Replacement @@", "x", "y", "z", "w", "v"])
        XCTAssertTrue(lines.allSatisfy { $0.number == nil }, "Claude's edits carry no line numbers")
        XCTAssertEqual(changes.files[0].absolutePath, "/work/app/src/lib/idempotent.ts")
        // In a conversation elsewhere, titles fall back to the directory the agent recorded.
        XCTAssertEqual(DiffChanges(items: steps.map(\.item), directory: "/Users/me/elsewhere").files.first?.title, "src/lib/idempotent.ts")
    }

    func testTheSameFileAcrossTwoPatchesIsOneSection() throws {
        let turns = try claudeTurns()
        let patches = turns.flatMap { ChatStep.steps($0, directory: "/work/app", reasoning: false) }.filter { $0.kind == .patch }
        let changes = DiffChanges(items: patches.map(\.item), directory: "/work/app")
        XCTAssertEqual(changes.files.map(\.title), ["src/lib/idempotent.ts", "src/routes/invoices.ts"])
        XCTAssertEqual(changes.files[0].hunks.count, 2, "Both edits of idempotent.ts, in order")
        XCTAssertEqual(changes.files[0].additions, 4)
        XCTAssertEqual(changes.files[0].deletions, 2)
    }

    func testCodexChangesKeepTheirNumbers() {
        let changes = DiffChanges(items: CodeDemo.items, directory: CodeDemo.directory)
        XCTAssertEqual(changes.files.map(\.title), ["src/lib/idempotent.ts", "src/routes/invoices.ts"])
        XCTAssertEqual(changes.files.map(\.additions), [4, 2])
        XCTAssertEqual(changes.files.map(\.deletions), [1, 3])
        let file = changes.files[0]
        XCTAssertEqual(file.lines.first, DiffLine(kind: .hunk, number: nil, text: "@@ -12,8 +12,11 @@ export async function seen("))
        // M5d's gutter: 12, 13 − (old), 13 14 15 +, 16 17 18 19, 20 +.
        XCTAssertEqual(file.lines.dropFirst().map(\.number), [12, 13, 13, 14, 15, 16, 17, 18, 19, 20])
        XCTAssertEqual(file.lines.dropFirst().map(\.kind), [.context, .removed, .added, .added, .added, .context, .context, .context, .context, .added])
        XCTAssertEqual(file.absolutePath, "/Users/paul/src/app/src/lib/idempotent.ts")
        // Syntax per version: the removed template string does not leak into the added lines.
        let text = file.highlighted()
        XCTAssertEqual(text.count, file.lines.count)
        let added = text[3]
        XCTAssertEqual(added.runs.first { String(added[$0.range].characters) == "const" }?.foregroundColor, CodeSyntax.Role.keyword.color)
    }

    func testUnifiedAndCodexPatchTextParseIntoSections() {
        let git = ChatItem(id: "git", kind: .tool, text: """
            diff --git a/a.py b/a.py
            index 1111111..2222222 100644
            --- a/a.py
            +++ b/a.py
            @@ -1,2 +1,2 @@
             def f():
            -    return 1
            +    return 2
            diff --git a/b.py b/b.py
            new file mode 100644
            --- /dev/null
            +++ b/b.py
            @@ -0,0 +1,2 @@
            +x = 1
            +y = 2
            """, title: "apply_patch", output: "", completed: true)
        let changes = DiffChanges(items: [git], directory: "/repo")
        XCTAssertEqual(changes.files.map(\.title), ["a.py", "b.py"])
        XCTAssertEqual(changes.files.map(\.additions), [1, 2])
        XCTAssertEqual(changes.files.map(\.deletions), [1, 0])
        XCTAssertFalse(changes.files[0].lines.contains { $0.text.hasPrefix("index ") || $0.text.hasPrefix("new file") }, "Git metadata is not a line")
        XCTAssertEqual(changes.files[1].lines.compactMap(\.number), [1, 2])
        let codex = ChatItem(id: "codex", kind: .tool, text: """
            *** Begin Patch
            *** Update File: src/app.ts
            @@ function main
            -  run()
            +  await run()
            *** End Patch
            """, title: "apply_patch", output: "", completed: true)
        let patch = DiffChanges(items: [codex], directory: "/repo")
        XCTAssertEqual(patch.files.map(\.title), ["src/app.ts"])
        XCTAssertEqual(patch.files[0].absolutePath, "/repo/src/app.ts")
        XCTAssertEqual(patch.files[0].lines.map(\.kind), [.hunk, .removed, .added])
    }

    func testTheWholeFileMarksTheHunksWhereTheyAre() throws {
        let file = DiffChanges(items: CodeDemo.items, directory: CodeDemo.directory).files[0]
        let whole = WholeFile(file: file, text: CodeDemo.idempotentFile)
        XCTAssertEqual(whole.missing, 0)
        XCTAssertNil(whole.note)
        XCTAssertEqual(whole.rows.count, 20 + 1, "Every line of the file and the removed one")
        XCTAssertEqual(whole.rows.filter { $0.kind == .added }.map(\.number), [13, 14, 15, 20])
        let removed = try XCTUnwrap(whole.rows.firstIndex { $0.kind == .removed })
        XCTAssertNil(whole.rows[removed].number, "A removed line is not in the file")
        XCTAssertEqual(whole.rows[removed - 1].number, 12)
        XCTAssertEqual(whole.rows.compactMap(\.number), Array(1...20))
        // Without numbers (Claude), the hunk is found by its text.
        let claude = DiffFile(path: "/w/a.ts", title: "a.ts", base: nil, diff: "@@ Replacement @@\n-old\n+const key = `evt:${eventId}`;\n")
        let found = WholeFile(file: claude, text: "one\n  const key = `evt:${eventId}`;\nconst key = `evt:${eventId}`;\n")
        XCTAssertEqual(found.rows.map(\.kind), [.context, .context, .removed, .added])
        XCTAssertEqual(found.rows.last?.number, 3)
        // The file moved on: shown as it is, with a note.
        let gone = WholeFile(file: claude, text: "something else\n")
        XCTAssertEqual(gone.missing, 1)
        XCTAssertEqual(gone.note, "This change is no longer in the file.")
        XCTAssertEqual(gone.rows.map(\.kind), [.context])
    }

    func testReadingTheWholeFileShowsLoadingThenTheFileOrWhyNot() async throws {
        let model = CodeDemo.model()
        let files = model.changes.files
        XCTAssertEqual(model.open, [files[0].id], "The tapped step's file starts open")
        XCTAssertNil(model.states[files[0].id], "Nothing is read until the whole file is asked for")
        model.toggleWhole()
        XCTAssertEqual(model.states[files[0].id], .loading, "Loading shows at once")
        XCTAssertNil(model.states[files[1].id], "Closed files are not read")
        try await TestSupport.eventually { if case .loaded? = model.states[files[0].id] { true } else { false } }
        model.toggle(files[1])
        try await TestSupport.eventually { if case .failed? = model.states[files[1].id] { true } else { false } }
        XCTAssertEqual(model.states[files[1].id], .failed("src/routes/invoices.ts is no longer on mba2."))
        model.toggleWhole()
        XCTAssertFalse(model.whole)
    }

    func testTheSessionReadsFilesThroughItsHelper() async throws {
        let helper = ScriptedHelper()
        helper.script { request in
            switch request.method {
            case "chat.open": .open
            case "files.text":
                request.params["path"] as? String == "/work/app/a.ts" ? .result("let a = 1\n") : .error(code: "not_found", message: "")
            default: .result([Any]())
            }
        }
        let session = MobileChatSession.scripted(helper)
        let text = try await session.fileText("/work/app/a.ts")
        XCTAssertEqual(text, "let a = 1\n")
        XCTAssertEqual(helper.requests("files.text").first?.params["plugin"] as? String, "files")
        do {
            _ = try await session.fileText("/work/app/gone.ts")
            XCTFail("A missing file fails")
        } catch let failure as HelperFailure {
            XCTAssertEqual(failure.code, "not_found")
        }
        let offline = MobileChatSession.scripted(helper, connected: false)
        do {
            _ = try await offline.fileText("/work/app/a.ts")
            XCTFail("No helper, no file")
        } catch {
            let file = DiffFile(path: "/work/app/a.ts", title: "a.ts", base: nil, diff: "")
            XCTAssertEqual(DiffViewModel.explain(error, file: file, host: "mba2"), "mba2 is not connected.")
        }
    }

    func testPinchSizesStepByHalfPointsWithinBoundsAndPersist() {
        XCTAssertEqual(CodeFontSize.pinched(base: 12, scale: 1.3), 15.5)
        XCTAssertEqual(CodeFontSize.pinched(base: 12, scale: 0.1), 8)
        XCTAssertEqual(CodeFontSize.pinched(base: 12, scale: 5), 24)
        let store = CodeFontStore.memory()
        XCTAssertEqual(CodeDemo.model(fonts: store).fontSize, 12)
        let model = CodeDemo.model(fonts: store)
        model.fontSize = 15.5
        model.commitFontSize()
        XCTAssertEqual(CodeDemo.model(fonts: store).fontSize, 15.5, "The next diff opens at the pinched size")
        store.save(99)
        XCTAssertEqual(CodeDemo.model(fonts: store).fontSize, 12, "A size out of bounds is not used")
        XCTAssertEqual(DiffMetrics(size: 12).line, 20)
        XCTAssertEqual(DiffMetrics(size: 12).numberWidth, 34)
        XCTAssertEqual(DiffMetrics(size: 24).line, 40)
    }
}
