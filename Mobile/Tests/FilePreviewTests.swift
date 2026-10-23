import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// F2 (docs/ios.md, Files): what a file is from its name and first bytes, text read whole or its head with Load all, a
/// file changing between reads, folders, Find, Ask and Open in Terminal's words, and the screen's controls.
@MainActor
final class FilePreviewTests: XCTestCase {
    /// Files in memory, with the reads asked for.
    final class Files: MobileFilesSource, @unchecked Sendable {
        var files: [String: Data]
        var folders: Set<String>
        /// Changes a file's revision after this many reads (a file written meanwhile).
        var changeAfter: [String: Int] = [:]
        private(set) var reads: [(path: String, offset: UInt64, length: UInt64)] = []

        init(_ files: [String: Data], folders: Set<String> = []) {
            self.files = files
            self.folders = folders
        }

        func list(_ path: String, hidden: Bool) async throws -> FileListing {
            guard folders.contains(path) else { throw FilesSourceError.notDirectory(path) }
            return FileListing(path: path, entries: [], truncated: false)
        }

        func read(_ path: String, offset: UInt64, length: UInt64, revision: FileRevision?) async throws -> (data: Data, revision: FileRevision) {
            reads.append((path, offset, length))
            if folders.contains(path) { throw FilesSourceError.unsupported("Is a folder") }
            guard let data = files[path] else { throw FilesSourceError.notFound(path) }
            let generation = changeAfter[path].map { reads.filter { $0.path == path }.count > $0 ? 2 : 1 } ?? 1
            let current = FileRevision(kind: .file, size: UInt64(data.count), device: 1, inode: 7,
                                       modifiedNs: "1800000000000000000", changedNs: String(generation))
            if let revision, revision != current { throw FilesSourceError.changed(path) }
            let start = Int(min(offset, UInt64(data.count))), end = Int(min(UInt64(data.count), offset + length))
            return (data.subdata(in: start..<end), current)
        }

        func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput {
            GitOutput(status: 128, output: "", truncated: false)
        }
    }

    private func preview(_ path: String, _ files: Files) -> FilePreview {
        FilePreview(path: path, host: "mba2") { files }
    }

    // MARK: Kinds

    func testKindsFromNameSizeAndFirstBytes() {
        let text = Data("let a = 1\n".utf8)
        XCTAssertEqual(FilePreview.decide(name: "theme.ts", size: 10, head: text), .text(language: "typescript"))
        XCTAssertEqual(FilePreview.decide(name: "README.md", size: 10, head: text), .markdown)
        XCTAssertEqual(FilePreview.decide(name: "logo.png", size: 10, head: Data([0x89, 0x50])), .image)
        XCTAssertEqual(FilePreview.decide(name: "huge.png", size: FilePreview.imageLimit + 1, head: Data()), .binary)
        XCTAssertEqual(FilePreview.decide(name: "app.bin", size: 4, head: Data([0x41, 0x00, 0x42, 0x43])), .binary, "A NUL")
        XCTAssertEqual(FilePreview.decide(name: "latin1.txt", size: 2, head: Data([0xE9, 0x41])), .binary, "Not UTF-8")
        let cut = Data("café".utf8).dropLast()
        XCTAssertEqual(FilePreview.decide(name: "notes.txt", size: 100, head: Data(cut)), .text(language: "text"),
                       "A character cut at the window's end is still text")
        XCTAssertEqual(FilePreview.decode(Data(cut), partial: true), "caf")
        XCTAssertNil(FilePreview.decode(Data(cut), partial: false))
    }

    // MARK: Reading

    /// A small text is read in one window and drawn in lines with the syntax palette; the final newline starts no line.
    func testSmallTextReadsWhole() async throws {
        let files = Files(["/w/theme.ts": Data(FilesSample.themeSource.utf8)])
        let preview = preview("/w/theme.ts", files)
        await preview.load()
        guard case .text(_, let language, let truncated) = preview.content else { return XCTFail("\(preview.content)") }
        XCTAssertEqual(language, "typescript")
        XCTAssertFalse(truncated)
        XCTAssertEqual(preview.lines.count, 25)
        XCTAssertEqual(String(preview.lines[0].characters), "import { useEffect, useState } from \"react\";")
        XCTAssertEqual(files.reads.count, 1)
        XCTAssertEqual(files.reads.first?.length, FilePreview.headLimit)
        XCTAssertEqual(preview.size, UInt64(FilesSample.themeSource.utf8.count))
        let keyword = preview.lines[0].runs.first { String(preview.lines[0][$0.range].characters) == "import" }
        XCTAssertEqual(keyword?.foregroundColor, CodeSyntax.Role.keyword.color, "Coloured as the diff viewer colours")
        XCTAssertGreaterThan(preview.longest, 80)
    }

    /// A long text shows its first 256 KB with Load all, which reads the rest at the same revision.
    func testLongTextShowsItsHeadThenLoadsAll() async throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let text = String(repeating: line, count: 5_000) // 500 KB
        let files = Files(["/w/big.log": Data(text.utf8)])
        let preview = preview("/w/big.log", files)
        await preview.load()
        XCTAssertTrue(preview.truncated)
        XCTAssertTrue(preview.canLoadAll)
        XCTAssertEqual(preview.text?.utf8.count, Int(FilePreview.headLimit))
        await preview.loadAll()
        XCTAssertFalse(preview.truncated)
        XCTAssertEqual(preview.lines.count, 5_000)
        XCTAssertEqual(files.reads.last?.length, UInt64(text.utf8.count))
    }

    /// Past the whole limit there is no Load all.
    func testAHugeTextOffersNoLoadAll() async throws {
        let files = Files(["/w/huge.log": Data(count: 1)])
        files.files["/w/huge.log"] = Data(repeating: 0x61, count: Int(FilePreview.wholeLimit) + 1)
        let preview = preview("/w/huge.log", files)
        await preview.load()
        XCTAssertTrue(preview.truncated)
        XCTAssertFalse(preview.canLoadAll)
    }

    /// A file that changes between its head and Load all is read again from the start.
    func testAFileChangingBeforeLoadAllIsReadAgain() async throws {
        let text = String(repeating: String(repeating: "y", count: 99) + "\n", count: 3_000)
        let files = Files(["/w/app.log": Data(text.utf8)])
        files.changeAfter["/w/app.log"] = 1
        let preview = preview("/w/app.log", files)
        await preview.load()
        XCTAssertTrue(preview.truncated)
        await preview.loadAll()
        XCTAssertEqual(files.reads.count, 3, "The head, Load all refused as changed, the head again")
        XCTAssertEqual(preview.revision?.changedNs, "2", "The new revision")
        XCTAssertTrue(preview.truncated, "The new version's head, with Load all")
    }

    /// A path that is a folder shows its listing; a missing one says it is gone; offline says so.
    func testFoldersMissingFilesAndOffline() async throws {
        let files = Files([:], folders: ["/w/src"])
        let folder = preview("/w/src", files)
        await folder.load()
        XCTAssertEqual(folder.content, .folder)
        let gone = preview("/w/nope.ts", files)
        await gone.load()
        XCTAssertEqual(gone.content, .failed("nope.ts is not on mba2 any more."))
        let offline = FilePreview(path: "/w/a.ts", host: "mba2") { nil }
        await offline.load()
        XCTAssertEqual(offline.content, .failed("mba2 is offline."))
    }

    /// Markdown stays Markdown (rendered, with its source a toggle away); a binary has no text.
    func testMarkdownAndBinary() async throws {
        let files = Files(["/w/README.md": Data(FilesSample.themingDoc.utf8), "/w/app.bin": Data([0, 1, 2, 3])])
        let markdown = preview("/w/README.md", files)
        await markdown.load()
        XCTAssertEqual(markdown.content, .markdown(FilesSample.themingDoc, truncated: false))
        XCTAssertFalse(markdown.lines.isEmpty, "The source's lines, for Show source")
        let binary = preview("/w/app.bin", files)
        await binary.load()
        XCTAssertEqual(binary.content, .binary)
        let bytes = try await binary.bytes()
        XCTAssertEqual(bytes, Data([0, 1, 2, 3]), "Share reads the whole file")
    }

    /// An image past the pixel cap is drawn from a smaller copy (its header read first), and Share reads the file again;
    /// one past the dimension limit is not decoded at all.
    func testLargeImagesAreDownsampled() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .pngData { context in UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 200)) }
        XCTAssertEqual(FilesImage.pixelSize(png), CGSize(width: 300, height: 200))
        XCTAssertEqual(FilesImage.shown(png), .image(png, smaller: false))
        guard case .image(let small, true)? = FilesImage.shown(png, cap: 10_000, edge: 60) else { return XCTFail("not downsampled") }
        let size = try XCTUnwrap(FilesImage.pixelSize(small))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 60)
        XCTAssertNil(FilesImage.shown(Data("not an image".utf8)))
    }

    /// Text past Load all is laid out off the main actor; `version` moves with the lines; Markdown past chat's
    /// rendering bound says so.
    func testLinesVersionAndMarkdownCap() async throws {
        let (lines, longest) = FilePreview.layout("a\tb\nlonger line\n", language: "text")
        XCTAssertEqual(lines.map { String($0.characters) }, ["a    b", "longer line"])
        XCTAssertEqual(longest, 11)
        let doc = String(repeating: "- item\n", count: TextRendering.richLineLimit + 5)
        let files = Files(["/w/long.md": Data(doc.utf8)])
        let markdown = preview("/w/long.md", files)
        await markdown.load()
        XCTAssertTrue(markdown.markdownCapped)
        XCTAssertEqual(markdown.version, 1)
        XCTAssertEqual(markdown.lines.count, TextRendering.richLineLimit + 5, "Show source has all of it")
    }

    /// Share's copies go when the sheet closes, and at launch.
    func testShareCopiesAreRemoved() throws {
        let item = try FilesShareItem.write(Data("x".utf8), name: "theme.ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertTrue(item.url.path.hasPrefix(FilesShareItem.folder.path))
        item.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.deletingLastPathComponent().path))
        let left = try FilesShareItem.write(Data("y".utf8), name: "a.bin")
        FilesShareItem.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.url.path))
    }

    // MARK: Find

    func testFindCountsStepsAndMarks() {
        let lines = CodeSyntax.lines("const theme = readTheme();\nlet x = 1\nTHEME and theme\n", language: "ts")
        var find = FileFind()
        find.query = "theme"
        find.search(lines)
        XCTAssertEqual(find.matches.count, 4, "Any case: theme, Theme, THEME, theme")
        XCTAssertEqual(find.position, "1 of 4")
        find.previous()
        XCTAssertEqual(find.currentMatch, FileFind.Match(line: 2, occurrence: 1))
        find.next()
        XCTAssertEqual(find.position, "1 of 4", "Wraps around")
        let marked = find.highlighted(lines[0], index: 0)
        let backgrounds = marked.runs.compactMap(\.backgroundColor)
        XCTAssertEqual(backgrounds, [Color.findCurrent, Color.findOther])
        find.query = "nothing"
        find.search(lines)
        XCTAssertEqual(find.position, "No matches")
    }

    // MARK: Ask and Open in Terminal

    func testAskAndTerminalWords() {
        XCTAssertEqual(FilesAsk.agentName(key: "claude", program: "node", executable: nil), "claude")
        XCTAssertEqual(FilesAsk.agentName(key: nil, program: "codex", executable: nil), "codex")
        XCTAssertEqual(FilesAsk.agentName(key: nil, program: "zsh", executable: "/opt/bin/pi"), "pi")
        XCTAssertEqual(FilesAsk.agentName(key: nil, program: nil, executable: nil), "agent")
        XCTAssertEqual(FilesAsk.typing("/Users/sam/src/web", bracketed: false), Data("\u{15}cd '/Users/sam/src/web'\r".utf8),
                       "The line cleared, the cd, Return")
        XCTAssertEqual(FilesAsk.typing("/tmp/it's here", bracketed: false), Data("\u{15}cd '/tmp/it'\\''s here'\r".utf8))
        XCTAssertEqual(FilesAsk.typing("/w", bracketed: true), Data("\u{15}\u{1B}[200~cd '/w'\u{1B}[201~\r".utf8),
                       "A bracketed paste when the shell asked for one")
    }

    /// A folder name with control characters is never typed: a ^C and a Return in it would run a command through the
    /// shell's line editor, quotes or not.
    func testOpenInTerminalRefusesControlCharacters() {
        let injected = "/tmp/x\u{03}echo INJECTED\rz"
        XCTAssertFalse(FilesAsk.typable(injected))
        XCTAssertNil(FilesAsk.typing(injected, bracketed: true), "Not even bracketed")
        for name in ["/tmp/a\nb", "/tmp/\u{1B}[201~", "/tmp/\u{9B}x", "/tmp/del\u{7F}", "/tmp/tab\tb", "/tmp/\u{2028}"] {
            XCTAssertFalse(FilesAsk.typable(name), name.debugDescription)
        }
        XCTAssertTrue(FilesAsk.typable("/tmp/plain folder/it's ünïcode ✓"))
    }

    /// Typing goes only into a shell at its prompt: not into an agent's pane, another program, or a full-screen one.
    func testOpenInTerminalTypesOnlyAtAShell() {
        XCTAssertTrue(FilesAsk.ready(program: "zsh", agent: false, alternate: false))
        XCTAssertTrue(FilesAsk.ready(program: "-bash", agent: false, alternate: false))
        XCTAssertFalse(FilesAsk.ready(program: "vim", agent: false, alternate: false), "Another program")
        XCTAssertFalse(FilesAsk.ready(program: "zsh", agent: true, alternate: false), "An agent's pane")
        XCTAssertFalse(FilesAsk.ready(program: "zsh", agent: false, alternate: true), "A full-screen program")
        XCTAssertFalse(FilesAsk.ready(program: nil, agent: false, alternate: false), "A renamed window says nothing")
    }

    /// Ask that the conversation never takes says so in the composer's strip.
    func testAskThatCannotAttachSaysSo() async throws {
        let chat = MobileChatSession(key: ChatConversationKey(host: UUID(), node: "tmux:s:$0:%0"), hostName: "mba2",
                                     drafts: ChatDraftRepository(store: ChatDraftMemoryStore()),
                                     outbox: ChatOutbox(store: ChatOutboxMemoryStore()))
        XCTAssertFalse(chat.canAttach)
        FilesAsk.attach(MobileAttachmentSource.data(Data("x".utf8), name: "theme.ts", kind: .file), to: chat, attempts: 1, pause: .zero)
        try await TestSupport.eventually { chat.attachmentError != nil }
        XCTAssertEqual(chat.attachmentError, FilesAsk.notReady("theme.ts"))
    }

    /// Ask switches the tab to Chat and takes the Files screens off the stack, back to the tab.
    func testAskReturnsToTheTabsChat() async throws {
        let model = MobileTabs(activity: TabActivityStore(url: nil), defaults: UserDefaults(suiteName: "files-ask-tests")!)
        let navigator = SpacesNavigator(model: model)
        let ref = FilesListingTests.ref
        navigator.path = [.tab(ref), .files(ref, .preview("/w", directory: true)), .files(ref, .preview("/w/theme.ts"))]
        var switched: TabSegment?
        let observer = NotificationCenter.default.addObserver(forName: TabSegment.switchRequested, object: nil, queue: nil) { note in
            if TabSegment.switchRequest(note) == ref { switched = TabSegment.switchTarget(note) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        TabSegment.requestSwitch(ref, to: .chat)
        FilesAsk.popToTab(ref, navigator: navigator)
        XCTAssertEqual(switched, .chat)
        XCTAssertEqual(navigator.path, [.tab(ref)])
        XCTAssertNil(TabSegment.switchTarget(Notification(name: TabSegment.switchRequested, userInfo: ["tab": ref])),
                     "⇧⌘C names none: it toggles")
    }

    // MARK: Screen

    /// The header names the file with its folder, size, age and kind; Ask names the tab's agent and shows only with
    /// one; Find counts the matches.
    func testTheScreensControls() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let files = Files(["/Users/sam/src/web/src/theme.ts": Data(FilesSample.themeSource.utf8)])
        let host = TabsHost(id: FilesListingTests.ref.host, name: "mba2", tint: .blue, system: nil, home: "/Users/sam", order: 0)
        var asked = 0
        let screen = NavigationStack {
            FilePreviewScreen(preview: preview("/Users/sam/src/web/src/theme.ts", files), host: host, root: "/Users/sam/src/web",
                              actions: FilesPreviewActions(agent: "claude", ask: { _ in asked += 1 }), fonts: .memory())
        }
        let (window, view) = try show(screen)
        defer { window.isHidden = true }
        try await TestSupport.eventually { labels(view.view).contains("Ask claude") }
        let all = labels(view.view)
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        let revision = FileRevision(kind: .file, size: 1_800, device: 1, inode: 1, modifiedNs: "1800000000000000000", changedNs: "1")
        XCTAssertEqual(FilePreviewScreen.subtitle(path: "/Users/sam/src/web/src/theme.ts", root: "/Users/sam/src/web", home: "/Users/sam",
                                                  revision: revision, now: modified.addingTimeInterval(25 * 60)),
                       "src · 1.8 KB · 25m ago · TypeScript")
        XCTAssertEqual(FilePreviewScreen.subtitle(path: "/Users/sam/notes/todo", root: nil, home: "/Users/sam", revision: nil, now: modified),
                       "~/notes", "Outside the root: the folder with ~")
        XCTAssertTrue(all.contains("Line 1, import { useEffect, useState } from \"react\";"), "\(all)")
        try tap("Ask claude", in: view.view)
        XCTAssertEqual(asked, 1)
        try tap("Find in file", in: view.view)
        try await TestSupport.eventually { labels(view.view).contains("Next match") }

        let bare = NavigationStack {
            FilePreviewScreen(preview: preview("/Users/sam/src/web/src/theme.ts", files), host: host, root: nil,
                              actions: FilesPreviewActions(agent: nil, ask: nil), fonts: .memory())
        }
        let (other, otherView) = try show(bare)
        defer { other.isHidden = true }
        try await TestSupport.eventually { labels(otherView.view).contains("Find in file") }
        XCTAssertFalse(labels(otherView.view).contains { $0.hasPrefix("Ask") }, "No agent, no Ask")
    }

    /// The code's metrics: the mockup's 19 point rows at the standard size, a wider gutter for longer files, and a
    /// width that holds the longest line.
    func testCodeMetrics() {
        let metrics = FileCodeView.Metrics(size: CodeFontSize.standard)
        XCTAssertEqual(metrics.size, 12.5)
        XCTAssertEqual(metrics.row, 19)
        XCTAssertEqual(metrics.gutter(lines: 25), 28)
        XCTAssertGreaterThan(metrics.gutter(lines: 100_000), 28)
        XCTAssertEqual(metrics.width(lines: 9, longest: 10), 12 + 28 + 12 + 10 * metrics.character + 24, accuracy: 0.01)
        XCTAssertEqual(FileCodeView.Metrics(size: 24).row, (19 * 24 / 12).rounded())
    }

    // MARK: Helpers

    private func show(_ view: some View, size: CGSize = CGSize(width: 402, height: 874)) throws -> (UIWindow, UIViewController) {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        return (window, host)
    }

    private func labels(_ view: UIView) -> [String] {
        var found: [String] = []
        func walk(_ element: NSObject) {
            if element.isAccessibilityElement, let label = element.accessibilityLabel { found.append(label) }
            for child in (element.accessibilityElements as? [NSObject]) ?? [] { walk(child) }
            if let view = element as? UIView { for sub in view.subviews { walk(sub) } }
        }
        walk(view)
        return found
    }

    private func tap(_ label: String, in view: UIView) throws {
        var found: NSObject?
        func walk(_ element: NSObject) {
            if found == nil, element.isAccessibilityElement, element.accessibilityLabel == label { found = element }
            for child in (element.accessibilityElements as? [NSObject]) ?? [] { walk(child) }
            if let view = element as? UIView { for sub in view.subviews { walk(sub) } }
        }
        walk(view)
        let element = try XCTUnwrap(found, "no \(label)")
        XCTAssertTrue(element.accessibilityActivate(), "\(label) did not activate")
    }
}
