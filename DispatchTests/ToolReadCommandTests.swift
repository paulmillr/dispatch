import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ToolReadCommandTests: XCTestCase {
    func testLiteralReadSummariesAndLineOrigins() throws {
        let examples: [(String, String, Int?)] = [
            ("sed -n '40,51p' file.swift", "file.swift · lines 40–51", 40),
            ("/usr/bin/sed -n -e \"9p\" '/repo/My File.swift'", "My File.swift · line 9", 9),
            ("cat /repo/file.swift", "file.swift", 1),
            ("cat A/B/C/D/file.swift", "file.swift", 1),
            ("cat /repo/A/B/C/D/file.swift", "file.swift", 1),
            ("cat ./A/../B/file.swift", "file.swift", 1),
            ("cat ../outside/file.swift", "../outside/file.swift", 1),
            ("cat A/../../outside/file.swift", "A/../../outside/file.swift", 1),
            ("cat /repo-other/file.swift", "../repo-other/file.swift", 1),
            ("cat My\\ File.swift", "My File.swift", 1),
            ("cat -- '-file.swift'", "-file.swift", 1),
            ("cat 'literal$[name].swift'", "literal$[name].swift", 1),
            ("head -n 40 file.swift", "file.swift · first 40 lines", 1),
            ("head -n40 file.swift", "file.swift · first 40 lines", 1),
            ("head -40 file.swift", "file.swift · first 40 lines", 1),
            ("head --lines=1 file.swift", "file.swift · first 1 line", 1),
            ("tail -n 20 file.swift", "file.swift · last 20 lines", nil),
            ("tail --lines 1 file.swift", "file.swift · last 1 line", nil),
            ("tail file.swift", "file.swift · last 10 lines", nil)
        ]
        for (command, summary, firstLine) in examples {
            let read = try XCTUnwrap(ToolReadCommand(command), command)
            XCTAssertEqual(read.summary(in: "/repo"), summary, command)
            XCTAssertEqual(read.firstLine, firstLine, command)
        }
    }

    func testComplexCommandsKeepTheirOriginalPresentation() {
        for command in [
            "sed -n '40,51p' file.swift | head", "cat file.swift; echo done", "cat a && cat b",
            "cat $(pwd)/file.swift", "cat $FILE", "cat \"$FILE\"", "cat `pwd`/file.swift",
            "cat *.swift", "cat ~/file.swift", "cat {a,b}.swift", "cat file.swift > copy.swift",
            "cat < file.swift", "cat file.swift # comment", "cat a.swift b.swift", "cat -", "cat -n file.swift",
            "sed -i 's/a/b/' file.swift", "sed -n '40,51p;70p' file.swift", "sed -n '/foo/p' file.swift",
            "sed -n '51,40p' file.swift", "sed -n '0,5p' file.swift", "sed -n '1,,5p' file.swift",
            "head -c 40 file.swift", "tail -f file.swift", "head -n -5 file.swift", "tail -n +20 file.swift",
            "head -n 999999999999999999999999 file.swift", "cat 'unclosed", "cat file\\",
            "cat \"\"", "cat", "env cat file.swift"
        ] {
            XCTAssertNil(ToolReadCommand(command), command)
            let tool = presentation(command)
            XCTAssertNil(tool.readCommand, command)
            XCTAssertEqual(tool.input, command)
            XCTAssertEqual(tool.summary, command.components(separatedBy: "\n").first)
        }
    }

    func testCapturedReadOutputPreservesCommandAndDoesNotBecomeAPatch() throws {
        let command = "sed -n '40,51p' /repo/file.swift"
        let tool = presentation(command, output: "let answer = 42\nprint(answer)\n")
        XCTAssertEqual(tool.title, "Read")
        XCTAssertEqual(tool.displaySummary(in: "/repo"), "file.swift · lines 40–51")
        XCTAssertEqual(tool.input, command)
        XCTAssertEqual(tool.output, "let answer = 42\nprint(answer)\n")
        XCTAssertEqual(tool.sourceReadPreview?.firstLine, 40)
        XCTAssertTrue(tool.documents.isEmpty, "Captured reads must not fetch the current file")
        XCTAssertFalse(SyntaxHighlight.tokens(tool.output, language: try XCTUnwrap(tool.readCommand).path).isEmpty)
        let patchText = "*** Begin Patch\n*** Update File: other.swift\n-old\n+new\n*** End Patch\n"
        let patchRead = presentation("cat example.patch", output: patchText)
        XCTAssertFalse(patchRead.isPatch)
        XCTAssertTrue(patchRead.documents.isEmpty)
        XCTAssertEqual(patchRead.output, patchText)
        XCTAssertNil(presentation(command, output: "sed: file.swift: No such file", exitCode: 1).sourceReadPreview)
        XCTAssertNil(presentation(command, output: "Warning: truncated output (original token count: 100)\n... code").sourceReadPreview)
        XCTAssertNil(presentation(command, output: "before\n... 100 tokens truncated ...\nafter").sourceReadPreview)
        let raw = ToolPresentation(ChatItem(id: "raw", kind: .tool, text: command, title: "shell"))
        XCTAssertEqual(raw.readCommand?.firstLine, 40)
        XCTAssertEqual(raw.input, command)
        let array = ToolPresentation(ChatItem(id: "array", kind: .tool,
            text: #"{"command":["zsh","-lc","head -n 40 file.swift"]}"#, title: "shell"))
        XCTAssertEqual(array.readCommand?.selection, .first(40))
    }

    func testReadCardShowsCapturedCodeWithoutShellSyntax() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let item = item("sed -n '40,51p' file.swift", output: "let answer = 42\nprint(answer)\n")
        var theme = ChatTheme.standard
        theme.typography.size = 18
        theme.typography.codeDetailLineHeight = 22
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView:
            ChatToolCard(item: item, expanded: .constant(true), directory: "/no-such-read-preview-directory")
                .environment(\.chatTheme, theme).padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(theme.terminal).foregroundStyle(theme.ink).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        let text = try await PresentationTestSupport.capture(window, named: "read-lines", in: "chat-formatting-validation").text()
        // Exact filenames are checked above; OCR can confuse f/t in the code font.
        for shown in ["Read", "lines", "40", "41", "Captured output", "answer", "Raw details"] {
            XCTAssertTrue(text.contains(shown), text)
        }
        for hidden in ["sed -n", "Command", "Current file"] {
            XCTAssertFalse(text.contains(hidden), text)
        }
    }

    private func item(_ command: String, output: String = "", exitCode: Int = 0) -> ChatItem {
        let input = try! JSONSerialization.data(withJSONObject: ["cmd": command])
        let result = try! JSONSerialization.data(withJSONObject: ["output": output, "exit_code": exitCode])
        return ChatItem(id: UUID().uuidString, kind: .tool, text: String(decoding: input, as: UTF8.self),
                        title: "exec_command", output: String(decoding: result, as: UTF8.self), completed: true)
    }
    private func presentation(_ command: String, output: String = "", exitCode: Int = 0) -> ToolPresentation {
        ToolPresentation(item(command, output: output, exitCode: exitCode))
    }
}
