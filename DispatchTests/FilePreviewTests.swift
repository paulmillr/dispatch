import AppKit
import XCTest
@testable import DispatchApp

/// The preview's decisions without a window: what each file is, how it is read, what is typed into the terminal.
@MainActor
final class FilePreviewTests: XCTestCase {
    private let home = "/Users/ivan"
    private var base: String { home + "/src/api" }
    private let now = Date(timeIntervalSince1970: 1_760_700_000)

    // MARK: Loader

    func testLoaderClassifiesEachKindFromItsNameSizeAndFirstWindow() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.file(base + "/assets/logo@2x.png", try Self.png(width: 4, height: 3))
        source.file(base + "/assets/broken.png", "not an image")
        source.file(base + "/data.bin", Data([0x61, 0x62, 0x00, 0x63]))
        source.file(base + "/big.log", String(repeating: "0123456789abcdef\n", count: 190_000))

        let billing = try await loaded(base + "/src/routes/billing.ts", in: source)
        guard case .text(let text, let language) = billing.kind else { return XCTFail("billing.ts: \(billing.kind)") }
        XCTAssertEqual(language, "typescript")
        XCTAssertTrue(text.hasPrefix("export const billing = 1\n"))
        XCTAssertEqual(billing.revision?.size, UInt64(text.utf8.count))

        let readme = try await loaded(base + "/README.md", in: source)
        guard case .markdown(let markdown) = readme.kind else { return XCTFail("README.md: \(readme.kind)") }
        XCTAssertEqual(markdown, "# api\n\nThe billing service.\n")

        let logo = try await loaded(base + "/assets/logo@2x.png", in: source)
        guard case .image(_, let pixels) = logo.kind else { return XCTFail("logo: \(logo.kind)") }
        XCTAssertEqual(pixels, CGSize(width: 4, height: 3))

        let broken = try await loaded(base + "/assets/broken.png", in: source)
        guard case .binary(let brokenSize, nil) = broken.kind else { return XCTFail("broken.png: \(broken.kind)") }
        XCTAssertEqual(brokenSize, 12)

        let binary = try await loaded(base + "/data.bin", in: source)
        guard case .binary(let size, nil) = binary.kind else { return XCTFail("data.bin: \(binary.kind)") }
        XCTAssertEqual(size, 4)

        let before = source.calls.count
        let large = try await loaded(base + "/big.log", in: source)
        guard case .tooLarge(let largeSize, nil) = large.kind else { return XCTFail("big.log: \(large.kind)") }
        XCTAssertEqual(largeSize, 17 * 190_000)
        XCTAssertEqual(source.calls[before...].filter { $0.hasPrefix("read ") }.count, 1,
                       "Text over 2 MB reads only its first window until asked")

        let folder = try await loaded(base + "/src", in: source)
        guard case .folder(let summary?) = folder.kind else { return XCTFail("src: \(folder.kind)") }
        XCTAssertEqual(summary.files, 5)
        XCTAssertEqual(summary.folders, 2)
        XCTAssertFalse(source.calls.contains("read \(base)/src"), "A folder is summarized, never read")

        // A row without an entry is still recognized as a folder through its summary.
        let unknown = FilePreviewState(path: base + "/tests", entry: nil)
        await FilePreviewLoader.load(unknown, from: source)
        guard case .folder(let tests?) = unknown.kind else { return XCTFail("tests: \(unknown.kind)") }
        XCTAssertEqual(tests.files, 1)

        let fifo = FilePreviewState(path: base + "/socket", entry: FileEntry(name: "socket", kind: .other, size: 0))
        await FilePreviewLoader.load(fifo, from: source)
        guard case .error = fifo.kind else { return XCTFail("socket: \(fifo.kind)") }
        XCTAssertFalse(source.calls.contains("read \(base)/socket"), "A pipe is never read: the read would block")

        let missing = try await loaded(base + "/gone.ts", in: source, entry: FileEntry(name: "gone.ts", kind: .file, size: 1))
        guard case .error(let message) = missing.kind else { return XCTFail("gone.ts: \(missing.kind)") }
        XCTAssertEqual(message, "\(base)/gone.ts does not exist")
    }

    func testDecisionOrderImageThenNulThenSizeThenMarkdown() {
        let text = Data("plain".utf8), nul = Data([0x41, 0x00])
        let limit = FilePreviewLoader.textLimit
        let cases: [(String, UInt64, Data, FilePreviewLoader.Decision)] = [
            ("logo.PNG", 48_000, nul, .image),
            ("photo.jpeg", 10, nul, .image),
            ("scan.tiff", 10, nul, .image),
            ("huge.png", FilePreviewLoader.imageLimit + 1, nul, .binary),
            ("archive.ts", 10, nul, .binary),
            ("bench.json", limit + 1, nul, .binary),
            ("bench.json", limit + 1, text, .tooLarge),
            ("notes.md", limit + 1, text, .tooLarge),
            ("bench.json", limit, text, .text(language: "json")),
            ("NOTES.markdown", 10, text, .markdown),
            ("README.md", 10, text, .markdown),
            ("main.rs", 10, text, .text(language: "code")),
            ("Makefile", 10, text, .text(language: "text")),
        ]
        for (name, size, head, expected) in cases {
            XCTAssertEqual(FilePreviewLoader.decide(name: name, size: size, head: head), expected, name)
        }
    }

    func testFileReadInTwoWindowsPassesTheFirstRevision() async throws {
        let source = FakeFilesSource.mockupAPI()
        let recorder = ScriptedFilesSource(source)
        let lock = try await loaded(base + "/pnpm-lock.yaml", in: recorder)
        guard case .text(let text, let language) = lock.kind else { return XCTFail("lock: \(lock.kind)") }
        XCTAssertEqual(language, "yaml")
        XCTAssertEqual(text.utf8.count, 19 * 10_000)
        XCTAssertEqual(recorder.reads.count, 2)
        XCTAssertEqual(recorder.reads[0].length, FilePreviewLoader.sniffLength)
        XCTAssertNil(recorder.reads[0].revision)
        XCTAssertNil(recorder.reads[1].length)
        XCTAssertEqual(recorder.reads[1].offset, 0)
        XCTAssertEqual(recorder.reads[1].revision?.size, 190_000, "The rest of the file is guarded by the first window")
    }

    func testFileChangedBetweenWindowsIsReadAgainFromTheStart() async throws {
        let source = FakeFilesSource.mockupAPI()
        let path = base + "/pnpm-lock.yaml"
        let scripted = ScriptedFilesSource(source)
        scripted.beforeRead = { index in
            if index == 1 { source.file(path, String(repeating: "lockfileVersion: 10\n", count: 9_000)) }
        }
        let lock = try await loaded(path, in: scripted)
        guard case .text(let text, _) = lock.kind else { return XCTFail("lock: \(lock.kind)") }
        XCTAssertEqual(text, String(repeating: "lockfileVersion: 10\n", count: 9_000), "Never a mix of two versions")
        XCTAssertEqual(scripted.reads.count, 4, "first window, changed rest, then both again")
        XCTAssertEqual(lock.revision?.size, 180_000)
    }

    func testFileThatKeepsChangingRestartsOnceThenSaysSo() async throws {
        let source = FakeFilesSource.mockupAPI()
        let path = base + "/src/index.ts"
        source.failures["read \(path)"] = .changed(path)
        let index = try await loaded(path, in: source)
        guard case .error(let message) = index.kind else { return XCTFail("index.ts: \(index.kind)") }
        XCTAssertEqual(message, "index.ts kept changing while it was read")
        XCTAssertEqual(source.calls.filter { $0 == "read \(path)" }.count, 2)
    }

    func testSelectionChangeCancelsTheReadInFlightWithoutWriting() async throws {
        let source = FakeFilesSource.mockupAPI()
        let gated = ScriptedFilesSource(source)
        let first = base + "/src/index.ts", second = base + "/README.md"
        gated.gate = first
        let old = FilePreviewState(path: first, entry: entry(first, in: source))
        let task = Task { await FilePreviewLoader.load(old, from: gated) }
        try await TestSupport.eventually { gated.waiting }
        // Selecting another row: the pane's task for the old state is cancelled and a new state loads.
        task.cancel()
        let new = FilePreviewState(path: second, entry: entry(second, in: source))
        await FilePreviewLoader.load(new, from: gated)
        gated.release()
        await task.value
        guard case .loading = old.kind else { return XCTFail("A cancelled load wrote \(old.kind)") }
        XCTAssertNil(old.revision)
        guard case .markdown(let text) = new.kind else { return XCTFail("README.md: \(new.kind)") }
        XCTAssertTrue(text.hasPrefix("# api"))
    }

    func testFolderCountsAgainAfterACancelledSummary() async throws {
        let source = FakeFilesSource.mockupAPI()
        let gated = ScriptedFilesSource(source)
        let path = base + "/src"
        gated.gate = path
        let folder = FilePreviewState(path: path, entry: FileEntry(name: "src", kind: .directory, size: 0))
        let task = Task { await FilePreviewLoader.load(folder, from: gated) }
        try await TestSupport.eventually { gated.waiting }
        // Another row selected while the walk runs, then this folder again.
        task.cancel()
        gated.release()
        await task.value
        guard case .folder(nil) = folder.kind else { return XCTFail("A cancelled count wrote \(folder.kind)") }
        await FilePreviewLoader.load(folder, from: gated)
        guard case .folder(let summary?) = folder.kind else { return XCTFail("Still counting: \(folder.kind)") }
        XCTAssertEqual(summary.files, 5)
    }

    func testImagesDecodeBoundedToThePane() async throws {
        let data = try Self.png(width: 1_200, height: 300)
        let pixels = await FilePreviewLoader.imagePixelSize(data)
        XCTAssertEqual(pixels, CGSize(width: 1_200, height: 300))
        let bound = try XCTUnwrap(FileImagePreview.decodeBound(CGSize(width: 1_200, height: 300),
                                                               area: CGSize(width: 200, height: 150), actualSize: false))
        XCTAssertEqual(bound, 512, "about twice the pane, in 512-pixel steps")
        let bounded = await FilePreviewLoader.decodeImage(data, maxPixels: bound)
        let thumbnail = try XCTUnwrap(bounded)
        XCTAssertEqual(thumbnail.width, 512)
        XCTAssertEqual(thumbnail.height, 128)
        XCTAssertNil(FileImagePreview.decodeBound(CGSize(width: 1_200, height: 300), area: CGSize(width: 200, height: 150),
                                                  actualSize: true), "actual size decodes whole")
        XCTAssertNil(FileImagePreview.decodeBound(CGSize(width: 400, height: 300), area: CGSize(width: 560, height: 700),
                                                  actualSize: false), "an image smaller than the bound decodes whole")
        let whole = await FilePreviewLoader.decodeImage(data, maxPixels: nil)
        XCTAssertEqual(whole?.width, 1_200)
        let notImage = await FilePreviewLoader.imagePixelSize(Data("not an image".utf8))
        XCTAssertNil(notImage)
    }

    func testLoadedStateIsNotReloadedWhenThePaneReturns() async throws {
        let source = FakeFilesSource.mockupAPI()
        let health = try await loaded(base + "/src/routes/health.ts", in: source)
        let reads = source.calls.count
        await FilePreviewLoader.load(health, from: source)
        XCTAssertEqual(source.calls.count, reads, "Switching back to files keeps what shows instead of blanking it")
    }

    func testShowFirst64KBOfLargeTextAndBinary() async throws {
        let source = FakeFilesSource.mockupAPI()
        let largePath = base + "/bench.json", binaryPath = base + "/core.bin"
        source.file(largePath, String(repeating: "{\"n\":1}\n", count: 400_000))
        var bytes = Data(repeating: 0x41, count: 200_000)
        bytes[10] = 0
        source.file(binaryPath, bytes)

        let large = try await loaded(largePath, in: source)
        await FilePreviewLoader.loadHead(large, from: source)
        guard case .tooLarge(let size, let head?) = large.kind else { return XCTFail("bench.json: \(large.kind)") }
        XCTAssertEqual(size, 3_200_000)
        XCTAssertEqual(head.utf8.count, 65_536)
        XCTAssertTrue(head.hasPrefix("{\"n\":1}\n"))

        let binary = try await loaded(binaryPath, in: source)
        await FilePreviewLoader.loadHead(binary, from: source)
        guard case .binary(200_000, let data?) = binary.kind else { return XCTFail("core.bin: \(binary.kind)") }
        XCTAssertEqual(data.count, 65_536)
        XCTAssertEqual(data[10], 0)

        // The file was replaced by a small one before the head was asked for: it is classified again.
        let replaced = try await loaded(largePath, in: source)
        source.file(largePath, "{\"small\": true}\n")
        await FilePreviewLoader.loadHead(replaced, from: source)
        guard case .text(let text, "json") = replaced.kind else { return XCTFail("replaced: \(replaced.kind)") }
        XCTAssertEqual(text, "{\"small\": true}\n")
    }

    // MARK: Languages and formatting

    func testLanguageDetectionByExtension() {
        let languages = ["billing.ts": "typescript", "App.TSX": "typescript", "index.mjs": "javascript", "build.sh": "shell",
                         "main.py": "python", "View.swift": "swift", "package.json": "json", "ci.yml": "yaml",
                         "lib.rs": "code", "main.go": "code", "site.css": "css", "page.html": "html", "query.sql": "sql",
                         "fix.patch": "diff", "README.md": "text", "notes.txt": "text", "Makefile": "text"]
        for (name, language) in languages {
            XCTAssertEqual(SyntaxHighlight.language(name), language, name)
        }
        let names = ["billing.ts": "TypeScript", "lib.rs": "Rust", "pnpm-lock.yaml": "YAML", "bench.json": "JSON",
                     "logo@2x.png": "PNG", "photo.JPG": "JPEG", "README.md": "Markdown", "Dockerfile": "Dockerfile"]
        for (name, kind) in names {
            XCTAssertEqual(FilesFormatting.kindName(name), kind, name)
        }
        XCTAssertNil(FilesFormatting.kindName("LICENSE"))
    }

    func testHeaderMetaNamesFolderSizeAgeAndLanguage() async throws {
        let source = FakeFilesSource.mockupAPI()
        let billing = try await loaded(base + "/src/routes/billing.ts", in: source)
        XCTAssertEqual(FilesFormatting.meta(billing, root: base, home: home, now: now),
                       "src/routes · 3.8 KB · modified 6m ago · TypeScript")
        let package = try await loaded(base + "/package.json", in: source)
        XCTAssertEqual(FilesFormatting.meta(package, root: base, home: home, now: now),
                       "api · 20 B · modified 5h ago · JSON")
        XCTAssertEqual(FilesFormatting.meta(package, root: "/srv", home: home, now: now),
                       "~/src/api · 20 B · modified 5h ago · JSON")

        source.file(base + "/assets/logo@2x.png", try Self.png(width: 512, height: 512))
        let logo = try await loaded(base + "/assets/logo@2x.png", in: source)
        XCTAssertTrue(FilesFormatting.meta(logo, root: base, home: home, now: now).hasPrefix("assets · "))
        XCTAssertTrue(FilesFormatting.meta(logo, root: base, home: home, now: now).hasSuffix(" · PNG · 512 × 512"))

        let folder = FilePreviewState(path: base + "/fixtures", entry: FileEntry(name: "fixtures", kind: .directory, size: 0))
        XCTAssertEqual(FilesFormatting.meta(folder, root: base, home: home, now: now), "folder")
        folder.kind = .folder(FolderSummary(files: 5_096, folders: 24, bytes: 48_200_000, truncated: false))
        XCTAssertEqual(FilesFormatting.meta(folder, root: base, home: home, now: now), "folder · 5,120 items · 48 MB")
        // F2d: text too large to show names its folder, size and kind, not when it changed.
        let bench = FilePreviewState(path: base + "/scheduler/bench.json",
                                     entry: FileEntry(name: "bench.json", kind: .file, size: 9_600_000, modified: now.addingTimeInterval(-60)))
        bench.kind = .tooLarge(size: 9_600_000, head: nil)
        XCTAssertEqual(FilesFormatting.meta(bench, root: base, home: home, now: now), "scheduler · 9.6 MB · JSON")
        XCTAssertFalse(bench.findable, "⌘F on the notice goes to the filter")
        bench.kind = .tooLarge(size: 9_600_000, head: "{}")
        XCTAssertTrue(bench.findable)
        XCTAssertFalse(folder.findable)
        XCTAssertFalse(logo.findable)
        XCTAssertTrue(package.findable)

        let summary = FolderSummary(files: 5_120, folders: 24, bytes: 48_200_000, truncated: false)
        XCTAssertEqual(FileFolderPreview.items(summary), "5,120 files · 24 folders")
        XCTAssertEqual(FileFolderPreview.size(summary), "48.2 MB on disk")
        XCTAssertEqual(FileFolderPreview.items(FolderSummary(files: 1, folders: 0, bytes: 0, truncated: true)),
                       "at least 1 file · 0 folders")
    }

    func testSizesAgesAndCounts() {
        let sizes: [UInt64: String] = [0: "0 B", 612: "612 B", 999: "999 B", 1_000: "1.0 KB", 4_100: "4.1 KB",
                                       188_000: "188 KB", 999_999: "1.0 MB", 9_600_000: "9.6 MB", 48_000_000: "48 MB"]
        for (bytes, text) in sizes { XCTAssertEqual(FilesFormatting.size(bytes), text, "\(bytes)") }
        XCTAssertEqual(FilesFormatting.preciseSize(48_200_000), "48.2 MB")
        let ages: [TimeInterval: String] = [6 * 60: "modified 6m ago", 5 * 3_600: "modified 5h ago",
                                            13 * 86_400: "modified 13d ago", 30: "modified just now",
                                            90 * 86_400: "modified 90d ago"]
        for (seconds, text) in ages {
            XCTAssertEqual(FilesFormatting.modified(now.addingTimeInterval(-seconds), at: now), text)
            // The list's column and the header say the same age.
            if seconds >= 60 { XCTAssertTrue(text.contains(FilesFormatting.age(now.addingTimeInterval(-seconds), at: now))) }
        }
        XCTAssertEqual(FilesFormatting.count(5_120), "5,120")
        XCTAssertEqual(FilesFormatting.count(100), "100")
        XCTAssertEqual(FilesFormatting.count(1_234_567), "1,234,567")
        XCTAssertEqual(FilesFormatting.count(0), "0")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = Date(timeIntervalSince1970: 1_760_709_720) // 14:02 UTC
        XCTAssertTrue(FilesFormatting.timestamp(today, now: today.addingTimeInterval(60), calendar: calendar)
            .hasPrefix("today "))
        XCTAssertTrue(FilesFormatting.timestamp(today, now: today.addingTimeInterval(86_400), calendar: calendar)
            .hasPrefix("yesterday "))
    }

    // MARK: Text, find and hex

    func testTextLinesDropTheFinalNewlineAndCarriageReturns() {
        XCTAssertEqual(FileTextLines.split("a\r\nb\r\n\nc"), ["a", "b", "", "c"])
        let lines = FileTextLines()
        let owner = ObjectIdentifier(lines)
        lines.prepare(.init(owner: owner, count: 1, language: "typescript", theme: .standard)) { "const a = 1\nlet b = 'x'\n" }
        XCTAssertEqual(lines.lines, ["const a = 1", "let b = 'x'"])
        XCTAssertEqual(lines.highlighted?.count, 2, "Highlighted under the cap")
        XCTAssertEqual(lines.occurrences(of: "A"), [0], "Case-insensitive: the a of const a")
        XCTAssertEqual(lines.occurrences(of: "l"), [1])
        XCTAssertEqual(FileTextLines.occurrences(of: "ab", in: ["abab", "x", "AB"]), [0, 0, 2])
        lines.prepare(.init(owner: owner, count: 2, language: "swift", theme: .standard)) { "let a = 1\r\nlet b = 2\r\n" }
        XCTAssertEqual(lines.lines, ["let a = 1", "let b = 2"])
        XCTAssertEqual(lines.highlighted?.count, 2, "CRLF text keeps its colours")

        let big = String(repeating: "let value = 1\n", count: 6_000)
        lines.prepare(.init(owner: owner, count: big.utf8.count, language: "swift", theme: .standard)) { big }
        XCTAssertNil(lines.highlighted, "Plain above the highlighter's 65,536-unit cap, as chat is")
        XCTAssertEqual(lines.lines.count, 6_000)

        // A line past the limit is cut once, when prepared, not counted on every redraw.
        let long = String(repeating: "é", count: FileTextLines.lineLimit + 5)
        let exact = String(repeating: "x", count: FileTextLines.lineLimit)
        lines.prepare(.init(owner: owner, count: 3, language: "swift", theme: .standard)) { "let a = 1\n\(long)\n\(exact)" }
        XCTAssertEqual(Array(lines.cut.keys), [1])
        XCTAssertEqual(lines.cut[1], String(repeating: "é", count: FileTextLines.lineLimit) + " …")
        XCTAssertEqual(String(lines.attributed(1, theme: .standard).characters), lines.cut[1])
        XCTAssertEqual(String(lines.attributed(2, theme: .standard).characters), exact, "a line at the limit shows whole")
        XCTAssertEqual(lines.occurrences(of: "é").first, 1, "find searches the whole line")
    }

    func testFindStepsWrapAround() {
        let find = FilePreviewFind()
        find.next()
        XCTAssertEqual(find.current, 0, "Nothing to step through")
        find.total = 3
        find.next(); find.next()
        XCTAssertEqual(find.current, 2)
        find.next()
        XCTAssertEqual(find.current, 0)
        find.previous()
        XCTAssertEqual(find.current, 2)
    }

    func testHexDumpRows() {
        let rows = FileTextLines.hexLines(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x41]))
        XCTAssertEqual(rows, [
            "00000000  89 50 4e 47 0d 0a 1a 0a  00 00 00 0d 49 48 44 52  |.PNG........IHDR|",
            "00000010  41                                                |A|",
        ])
        XCTAssertEqual(FileTextLines.hexLines(Data(count: 65_536)).count, 4_096)
    }

    // MARK: Open in editor and cd here

    func testEditorCommandQuotesEveryPath() {
        let cases: [(String, FilesEditor.Action, String)] = [
            ("/Users/ivan/src/api/src/routes/billing.ts", .edit, "${EDITOR:-vi} '/Users/ivan/src/api/src/routes/billing.ts'"),
            ("/Users/ivan/My Projects/read me.md", .edit, "${EDITOR:-vi} '/Users/ivan/My Projects/read me.md'"),
            ("/Users/ivan/it's here/a'b", .edit, #"${EDITOR:-vi} '/Users/ivan/it'\''s here/a'\''b'"#),
            ("/Users/ivan/Документы/日本語 ✓.txt", .edit, "${EDITOR:-vi} '/Users/ivan/Документы/日本語 ✓.txt'"),
            ("/home/ivan/nightly/$(rm -rf ~)`x`;*", .edit, "${EDITOR:-vi} '/home/ivan/nightly/$(rm -rf ~)`x`;*'"),
            ("/home/ivan/nightly/fixtures", .changeDirectory, "cd '/home/ivan/nightly/fixtures'"),
            ("/home/ivan/it's", .changeDirectory, #"cd '/home/ivan/it'\''s'"#),
        ]
        for (path, action, command) in cases {
            XCTAssertEqual(FilesEditor.command(for: path, action: action), command, path)
        }
        XCTAssertNil(FilesEditor.command(for: "/tmp/a\nrm -rf ~", action: .edit), "A newline would run the rest")
        XCTAssertNil(FilesEditor.command(for: "/tmp/\u{1B}[201~x", action: .edit), "A paste strips escape bytes")
        XCTAssertNil(FilesEditor.command(for: "/tmp/\u{9B}x", action: .changeDirectory))
        XCTAssertNil(FilesEditor.command(for: "", action: .edit))
    }

    func testEditorTypesOnlyAtAPrompt() {
        let path = "/Users/ivan/src/api/README.md"
        XCTAssertNil(FilesEditor.refusal(path: path, action: .edit, hasTerminal: true, busy: false))
        XCTAssertEqual(FilesEditor.refusal(path: path, action: .edit, hasTerminal: true, busy: true), .busy)
        XCTAssertEqual(FilesEditor.refusal(path: path, action: .changeDirectory, hasTerminal: false, busy: true), .noTerminal)
        XCTAssertEqual(FilesEditor.refusal(path: "/tmp/a\nb", action: .edit, hasTerminal: true, busy: false), .unsafePath)
        XCTAssertEqual(FilesEditor.Refusal.busy.message, "The terminal is busy")
    }

    func testEditorRefusalKeepsFilesShowingWithANotice() {
        let path = "/Users/ivan/src/api/README.md"
        // A tab with no terminal view: nothing is typed, the mode stays, and the header has the notice.
        let tab = System.uuid()
        let files = FilesCoordinator { nil }
        files.switchMode(tab, to: .files)
        XCTAssertEqual(files.openInEditor(tab, path: path), .noTerminal)
        XCTAssertEqual(files.mode(for: tab), .files)
        XCTAssertEqual(FilesEditorNotices.shared.notice(for: tab), "The terminal isn’t running")
        FilesEditorNotices.shared.clear(tab)
    }

    // MARK: Support

    private func entry(_ path: String, in source: FakeFilesSource) -> FileEntry? {
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        guard let node = source.node(parent)?.children[name] else { return nil }
        return FileEntry(name: name, kind: node.kind, size: node.kind == .directory ? 0 : UInt64(node.data.count),
                         modified: node.modified)
    }

    private func loaded(_ path: String, in source: any FilesSource, entry given: FileEntry? = nil) async throws -> FilePreviewState {
        let fake = (source as? FakeFilesSource) ?? (source as? ScriptedFilesSource)?.base
        let preview = FilePreviewState(path: path, entry: given ?? fake.flatMap { entry(path, in: $0) })
        await FilePreviewLoader.load(preview, from: source)
        return preview
    }

    static func png(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<width {
            for y in 0..<height {
                bitmap.setColor(NSColor(srgbRed: CGFloat(x) / CGFloat(max(1, width - 1)), green: 0.4,
                                        blue: CGFloat(y) / CGFloat(max(1, height - 1)), alpha: 1), atX: x, y: y)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

/// Wraps the fake host to script reads: run something before the Nth read, or hold one path's reads (and summary) until released,
/// so change and cancellation cases need no timing.
final class ScriptedFilesSource: FilesSource, @unchecked Sendable {
    struct Read {
        let path: String
        let offset: UInt64
        let length: UInt64?
        let revision: FileRevision?
    }

    let base: FakeFilesSource
    var beforeRead: ((Int) -> Void)?
    /// Reads of this path wait for `release()`.
    var gate: String?
    private let lock = NSLock()
    private var recorded: [Read] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(_ base: FakeFilesSource) { self.base = base }

    var reads: [Read] { lock.withLock { recorded } }
    var waiting: Bool { lock.withLock { !held.isEmpty } }

    func release() {
        let continuations = lock.withLock { released = true; defer { held = [] }; return held }
        for continuation in continuations { continuation.resume() }
    }

    var endpoint: FilesEndpoint { base.endpoint }
    var home: String? { base.home }
    var hostLabel: String? { base.hostLabel }

    func list(_ path: String, hidden: Bool) async throws -> FileListing { try await base.list(path, hidden: hidden) }
    func summary(_ path: String) async throws -> FolderSummary {
        if path == gate { await hold() }
        return try await base.summary(path)
    }

    private func hold() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if released { return true }
                held.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func read(_ path: String, offset: UInt64, length: UInt64?, revision: FileRevision?) async throws
        -> (data: Data, revision: FileRevision) {
        let index = lock.withLock {
            recorded.append(Read(path: path, offset: offset, length: length, revision: revision))
            return recorded.count - 1
        }
        beforeRead?(index)
        if path == gate { await hold() }
        return try await base.read(path, offset: offset, length: length, revision: revision)
    }

    func write(_ path: String, data: Data, mode: UInt32?, replace: Bool) async throws -> FileRevision {
        try await base.write(path, data: data, mode: mode, replace: replace)
    }
    func pack(transfer: String, base path: String, paths: [String]) async throws -> PackedArchive {
        try await base.pack(transfer: transfer, base: path, paths: paths)
    }
    func dropArchive(transfer: String) async throws { try await base.dropArchive(transfer: transfer) }
    func openUnpack(transfer: String, target: String, policy: ConflictPolicy, names: [String]) async throws -> UnpackTransfer {
        try await base.openUnpack(transfer: transfer, target: target, policy: policy, names: names)
    }
    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput {
        try await base.git(path, args: args, limit: limit)
    }
    func writeUnpack(transfer: String, data: Data) async throws -> UInt64 {
        try await base.writeUnpack(transfer: transfer, data: data)
    }
    func closeUnpack(transfer: String, commit: Bool) async throws -> UnpackResult {
        try await base.closeUnpack(transfer: transfer, commit: commit)
    }
}
