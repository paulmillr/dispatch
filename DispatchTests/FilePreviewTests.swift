import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// The preview's decisions without a window: what each file is, how it is read, what is typed into the terminal.
@MainActor
final class FilePreviewTests: XCTestCase {
    private let home = "/Users/ivan"
    private var base: String { home + "/src/api" }
    private let now = Date(timeIntervalSince1970: 1_760_700_000)

    // MARK: Loader

    /// The places whose first read raises a macOS consent prompt, and which of them a walk of a folder would read:
    /// the one it lies in, or every one below it.
    func testProtectedPlacesAWalkWouldRead() {
        let home = "/Users/ivan"
        func places(_ path: String) -> [ProtectedFolders.Place] { ProtectedFolders.places(walking: path, home: home) }
        XCTAssertEqual(places("/Users/ivan/Documents"), [.folder("/Users/ivan/Documents")])
        XCTAssertEqual(places("/Users/ivan/Downloads/old/zip"), [.folder("/Users/ivan/Downloads")])
        XCTAssertEqual(places("/System/Volumes/Data/Users/ivan/Desktop"), [.folder("/Users/ivan/Desktop")], "the data volume's path")
        XCTAssertEqual(places("/Users/ivan/Library/CloudStorage/Sync-ivan/a"), [.folder("/Users/ivan/Library/CloudStorage/Sync-ivan")])
        XCTAssertEqual(places("/Users/ivan/Library/Containers/com.example.notes"), [.folder("/Users/ivan/Library/Containers/com.example.notes")])
        XCTAssertEqual(places("/Volumes/Backup/photos"), [.folder("/Volumes/Backup")])
        // An ancestor reads every place below it.
        let folders: [ProtectedFolders.Place] = ProtectedFolders.homeFolders.map { .folder(home + "/" + $0) }
        let parents: [ProtectedFolders.Place] = ProtectedFolders.homeParents.map { .eachChild(home + "/" + $0) }
        XCTAssertEqual(Set(places("/Users/ivan")), Set(folders + parents))
        let library: [ProtectedFolders.Place] = [.folder(home + "/Library/Mobile Documents")] + parents
        XCTAssertEqual(Set(places("/Users/ivan/Library")), Set(library))
        XCTAssertTrue(places("/").contains(.eachChild("/Volumes")))
        XCTAssertTrue(places("/System").contains(.folder(home + "/Documents")), "/System holds the data volume")
        XCTAssertTrue(places("/Users").contains(.folder(home + "/Desktop")))
        // The Photos library asks too (checked on macOS 27.2.1): counting ~/Pictures would read it.
        XCTAssertEqual(places("/Users/ivan/Pictures"), [.folder(home + "/Pictures/Photos Library.photoslibrary")])
        // Elsewhere, none.
        for path in ["/Users/ivan/src/api", "/Users/ivan/DesktopNotes", "/Users/ivan/Library/Preferences", "/usr/local", "/tmp"] {
            XCTAssertEqual(places(path), [], path)
        }
    }

    /// Counting a folder's size waits for Count size on this Mac until the session has listed inside the place it
    /// reads; a child-by-child place (a container) never counts as allowed, and a remote host never asks.
    func testCountingWaitsForConsentUntilThePlaceWasListed() {
        let session = FilesSession(id: System.uuid())
        session.availability = .available(FakeFilesSource())
        session.home = "/Users/ivan"
        XCTAssertTrue(session.countNeedsConsent("/Users/ivan/Documents"))
        XCTAssertTrue(session.countNeedsConsent("/Users/ivan/Documents/q3"))
        XCTAssertFalse(session.countNeedsConsent("/Users/ivan/src"))
        // A failed listing proves nothing; a listed one, that macOS allowed it.
        session.listings["/Users/ivan/Documents"] = FileListingState(listing: nil, error: .privacyBlocked("/Users/ivan/Documents", host: nil))
        XCTAssertTrue(session.countNeedsConsent("/Users/ivan/Documents/q3"))
        session.listings["/Users/ivan/Documents/q3"] = FileListingState(listing: FileListing(path: "/Users/ivan/Documents/q3", entries: [], truncated: false))
        XCTAssertFalse(session.countNeedsConsent("/Users/ivan/Documents"))
        XCTAssertFalse(session.countNeedsConsent("/Users/ivan/Documents/q3/drafts"))
        XCTAssertTrue(session.countNeedsConsent("/Users/ivan"), "the home also reads Desktop, Downloads, the containers…")
        session.listings["/Users/ivan/Library/Containers"] = FileListingState(listing: FileListing(path: "/Users/ivan/Library/Containers", entries: [], truncated: false))
        XCTAssertTrue(session.countNeedsConsent("/Users/ivan/Library/Containers"), "each container asks on its own")
        session.availability = .available(FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "build-box"))
        XCTAssertFalse(session.countNeedsConsent("/Users/ivan/Desktop"), "over SSH nothing can ask")
    }

    /// The helper passes the system's words on: "Operation not permitted" (EPERM) is the system refusing, which a Mac
    /// does for the places it guards; "Permission denied" (EACCES) is the file's own modes.
    func testTheSystemRefusingIsToldApartFromTheFilesModes() {
        let blocked = FilesSourceFailure(code: "permission_denied", message: "Operation not permitted (os error 1)")
        let modes = FilesSourceFailure(code: "permission_denied", message: "Permission denied (os error 13)")
        let path = "/Users/ivan/Documents"
        XCTAssertEqual(blocked.error(path: path, context: .desktop(host: nil)), .privacyBlocked(path, host: nil))
        XCTAssertEqual(blocked.error(path: path, context: .desktop(host: "build-box")), .privacyBlocked(path, host: "build-box"))
        XCTAssertEqual(modes.error(path: path, context: .desktop(host: "build-box")), .permissionDenied(path))
        XCTAssertTrue(FilesSourceError.privacyBlocked(path, host: "build-box").message.contains("Allow full disk access for remote users"))
        XCTAssertTrue(FilesSourceError.privacyBlocked(path, host: nil).message.contains("Privacy & Security"))
    }

    func testLoaderClassifiesEachKindFromItsNameSizeAndFirstWindow() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.file(base + "/assets/logo@2x.png", try Self.png(width: 4, height: 3))
        source.file(base + "/assets/broken.png", "not an image")
        source.file(base + "/data.bin", Data([0x61, 0x62, 0x00, 0x63]))
        source.file(base + "/malformed.txt", Data([0x61, 0xC0, 0xAF, 0x62]))
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
        guard case .binary(let brokenSize, let brokenHead, nil) = broken.kind else { return XCTFail("broken.png: \(broken.kind)") }
        XCTAssertEqual(brokenSize, 12)
        XCTAssertEqual(brokenHead, Data("not an image".utf8), "What was read shows as hex at once")

        let binary = try await loaded(base + "/data.bin", in: source)
        guard case .binary(let size, let head, nil) = binary.kind else { return XCTFail("data.bin: \(binary.kind)") }
        XCTAssertEqual(size, 4)
        XCTAssertEqual(head, Data([0x61, 0x62, 0x00, 0x63]))

        let malformed = try await loaded(base + "/malformed.txt", in: source)
        guard case .binary(let malformedSize, _, _) = malformed.kind else {
            return XCTFail("malformed.txt: \(malformed.kind)")
        }
        XCTAssertEqual(malformedSize, 4, "Malformed UTF-8 is not shown as lossy replacement text")

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
            ("malformed.txt", 2, Data([0xC0, 0xAF]), .binary),
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
        XCTAssertEqual(recorder.reads[1].length, 190_000, "The second read is bounded by the size already verified")
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
                                                               area: CGSize(width: 200, height: 150), zoomed: false))
        XCTAssertEqual(bound, 512, "about twice the pane, in 512-pixel steps")
        let bounded = await FilePreviewLoader.decodeImage(data, maxPixels: bound)
        let thumbnail = try XCTUnwrap(bounded)
        XCTAssertEqual(thumbnail.width, 512)
        XCTAssertEqual(thumbnail.height, 128)
        XCTAssertNil(FileImagePreview.decodeBound(CGSize(width: 1_200, height: 300), area: CGSize(width: 200, height: 150),
                                                  zoomed: true), "a zoomed image decodes whole")
        XCTAssertNil(FileImagePreview.decodeBound(CGSize(width: 400, height: 300), area: CGSize(width: 560, height: 700),
                                                  zoomed: false), "an image smaller than the bound decodes whole")
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

    /// The previewed file changed on disk (the listing shows another size or time): it is read again and shown in
    /// place, in the same state, so the pane keeps its view; an unchanged listing reads nothing.
    func testAPreviewReadsTheFileAgainWhenTheListingSaysItChanged() async throws {
        let source = FakeFilesSource.mockupAPI()
        let path = base + "/src/routes/health.ts"
        let preview = try await loaded(path, in: source)
        let folder = base + "/src/routes"
        func listings() async throws -> [String: FileListingState] {
            [folder: FileListingState(listing: try await source.list(folder, hidden: false), loadedAt: nil, error: nil, loading: false)]
        }
        let unchanged = try await listings()
        XCTAssertNil(FilePreviewLoader.changedEntry(of: preview, in: unchanged), "the same version")
        source.file(path, "export const health = 'edited by the agent'\n", modified: Date(timeIntervalSince1970: 1_760_000_600))
        let changed = try await listings()
        let entry = try XCTUnwrap(FilePreviewLoader.changedEntry(of: preview, in: changed))
        await FilePreviewLoader.refresh(preview, entry: entry, from: source) { true }
        guard case .text(let text, _) = preview.kind else { return XCTFail("\(preview.kind)") }
        XCTAssertTrue(text.contains("edited by the agent"))
        let reread = try await listings()
        XCTAssertNil(FilePreviewLoader.changedEntry(of: preview, in: reread), "the header's size and time are the new ones")
    }

    /// Text that is not UTF-8 reads as text when its encoding can be told (a UTF-16 byte-order mark, 8-bit text with no
    /// controls); other bytes with no NUL say they are not UTF-8 rather than pass for a program.
    func testOtherEncodingsPreviewAsTextAndSaySo() async throws {
        let source = FakeFilesSource.mockupAPI()
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("\"Save\" = \"Sichern\";\n".data(using: .utf16LittleEndian)!)
        source.file(base + "/Localizable.strings", utf16)
        source.file(base + "/legacy.conf", Data("name = caf\u{E9}\n".data(using: .isoLatin1)!))
        source.file(base + "/odd.bin", Data([0x41, 0x42, 0x80, 0x81, 0x01, 0x43]))
        let strings = try await loaded(base + "/Localizable.strings", in: source)
        guard case .text(let text, _) = strings.kind else { return XCTFail("\(strings.kind)") }
        XCTAssertEqual(text, "\"Save\" = \"Sichern\";\n")
        XCTAssertEqual(strings.encoding, "UTF-16")
        XCTAssertTrue(FilesFormatting.meta(strings, now: Date(timeIntervalSince1970: 1_760_000_000)).contains("UTF-16"))
        let conf = try await loaded(base + "/legacy.conf", in: source)
        guard case .text(let latin, _) = conf.kind else { return XCTFail("\(conf.kind)") }
        XCTAssertEqual(latin, "name = caf\u{E9}\n")
        XCTAssertEqual(conf.encoding, "Latin-1")
        let odd = try await loaded(base + "/odd.bin", in: source)
        guard case .binary(_, _, let format) = odd.kind else { return XCTFail("\(odd.kind)") }
        XCTAssertEqual(format, "Not UTF-8 text")
        XCTAssertNil(FilePreviewContent.otherEncoding(Data("plain ascii".utf8)), "UTF-8 is not another encoding")
    }

    func testShowFirst64KBOfLargeText() async throws {
        let source = FakeFilesSource.mockupAPI()
        let largePath = base + "/bench.json", binaryPath = base + "/core.bin"
        source.file(largePath, String(repeating: "{\"n\":1}\n", count: 400_000))
        let malformedPath = base + "/malformed.log"
        var malformedBytes = Data(repeating: 0x61, count: Int(FilePreviewLoader.textLimit + 1))
        malformedBytes[9_000] = 0xFF
        source.file(malformedPath, malformedBytes)
        var bytes = Data(repeating: 0x41, count: 200_000)
        bytes[10] = 0
        source.file(binaryPath, bytes)

        let large = try await loaded(largePath, in: source)
        await FilePreviewLoader.loadHead(large, from: source)
        guard case .tooLarge(let size, let head?) = large.kind else { return XCTFail("bench.json: \(large.kind)") }
        XCTAssertEqual(size, 3_200_000)
        XCTAssertEqual(head.utf8.count, 65_536)
        XCTAssertTrue(head.hasPrefix("{\"n\":1}\n"))

        let malformed = try await loaded(malformedPath, in: source)
        guard case .tooLarge = malformed.kind else { return XCTFail("malformed head: \(malformed.kind)") }
        await FilePreviewLoader.loadHead(malformed, from: source)
        guard case .binary(let malformedSize, let malformedHead, _) = malformed.kind else {
            return XCTFail("malformed head: \(malformed.kind)")
        }
        XCTAssertEqual(malformedSize, FilePreviewLoader.textLimit + 1)
        XCTAssertEqual(malformedHead.count, 65_536, "Bytes that were not text after all show as hex from what was read")
        XCTAssertEqual(malformedHead[9_000], 0xFF)

        // A binary has its first window from the start; there is no head to ask for.
        let binary = try await loaded(binaryPath, in: source)
        guard case .binary(200_000, let data, _) = binary.kind else { return XCTFail("core.bin: \(binary.kind)") }
        XCTAssertEqual(UInt64(data.count), FilePreviewLoader.sniffLength)
        XCTAssertEqual(data[10], 0)
        let reads = source.calls.count
        await FilePreviewLoader.loadHead(binary, from: source)
        XCTAssertEqual(source.calls.count, reads)

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
                         "fix.patch": "diff", "README.md": "markdown", "notes.txt": "text", "Makefile": "text"]
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

    func testMarkdownSourceHighlightsStructureButNotCodeOrWords() {
        let theme = ChatTheme.standard
        let source = "# Title\nSome *em* and **bold** with `# code` and [a link](https://x.y) in snake_case_name.\n"
            + "- item\n1. first\n> quote\n<!-- note -->\n```swift\nlet x = \"# not a heading\"\n```\n"
        let tokens = SyntaxHighlight.tokens(source, language: "README.md", theme: theme).map {
            ((source as NSString).substring(with: $0.range), $0.color)
        }
        let expected: [(String, Color)] = [
            ("# Title", theme.keyword), ("*em*", theme.number), ("**bold**", theme.number), ("`# code`", theme.string),
            ("[a link](https://x.y)", theme.blue), ("-", theme.number), ("1.", theme.number), ("> ", theme.number),
            ("<!-- note -->", theme.comment), ("```swift\nlet x = \"# not a heading\"\n```", theme.string)]
        XCTAssertEqual(tokens.map(\.0), expected.map(\.0))
        XCTAssertEqual(tokens.map(\.1), expected.map(\.1))
    }

    func testHeaderMetaNamesSizeAndAge() async throws {
        let source = FakeFilesSource.mockupAPI()
        let billing = try await loaded(base + "/src/routes/billing.ts", in: source)
        XCTAssertEqual(FilesFormatting.meta(billing, now: now), "3.8 KB · modified 6m ago", "no folder, no language")
        let package = try await loaded(base + "/package.json", in: source)
        XCTAssertEqual(FilesFormatting.meta(package, now: now), "20 B · modified 5h ago")

        source.file(base + "/assets/logo@2x.png", try Self.png(width: 512, height: 512))
        let logo = try await loaded(base + "/assets/logo@2x.png", in: source)
        XCTAssertTrue(FilesFormatting.meta(logo, now: now).hasSuffix(" · PNG · 512 × 512"))
        XCTAssertFalse(FilesFormatting.meta(logo, now: now).contains("assets"))

        let folder = FilePreviewState(path: base + "/fixtures", entry: FileEntry(name: "fixtures", kind: .directory, size: 0))
        XCTAssertEqual(FilesFormatting.meta(folder, now: now), "folder")
        folder.kind = .folder(FolderSummary(files: 5_096, folders: 24, bytes: 48_200_000, truncated: false))
        XCTAssertEqual(FilesFormatting.meta(folder, now: now), "folder · 5,120 items · 48 MB")
        // F2d: text too large to show names its size, not when it changed.
        let bench = FilePreviewState(path: base + "/scheduler/bench.json",
                                     entry: FileEntry(name: "bench.json", kind: .file, size: 9_600_000, modified: now.addingTimeInterval(-60)))
        bench.kind = .tooLarge(size: 9_600_000, head: nil)
        XCTAssertEqual(FilesFormatting.meta(bench, now: now), "9.6 MB")
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
        let manyLines = String(repeating: "x\n", count: FileTextLines.linesLimit + 1)
        let boundedLines = FileTextLines.split(manyLines)
        XCTAssertEqual(boundedLines.count, FileTextLines.linesLimit)
        XCTAssertEqual(boundedLines.last, FileTextLines.truncatedLine)
        let manyMatches = FileTextLines.occurrences(
            of: "x", in: [String(repeating: "x", count: FileTextLines.occurrencesLimit + 1)])
        XCTAssertEqual(manyMatches.count, FileTextLines.occurrencesLimit)
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

        lines.prepare(.init(owner: owner, count: 4, language: "text", theme: .standard)) {
            "safe\u{202E}txt\u{200D}\u{1B}"
        }
        XCTAssertEqual(lines.lines, ["safe⟦RLO⟧txt⟦ZWJ⟧⟦ESC⟧"])
    }

    func testImageZoomStepsThroughStopsAndFitsAtTheFitScale() {
        // A large image fits at 30 %: + goes to the next stop, − back to fit once it reaches the fit scale.
        XCTAssertEqual(FileImageZoom.fit.stepped(in: true, fit: 0.3), .scale(0.5))
        XCTAssertEqual(FileImageZoom.scale(0.5).stepped(in: false, fit: 0.3), .fit)
        XCTAssertEqual(FileImageZoom.scale(1).stepped(in: false, fit: 0.3), .scale(0.75))
        XCTAssertEqual(FileImageZoom.scale(1.2).stepped(in: true, fit: 0.3), .scale(1.5), "a pinched scale steps to the next stop")
        XCTAssertEqual(FileImageZoom.scale(8).stepped(in: true, fit: 0.3), .scale(8), "8× is the most")
        // A small image fits at 100 %: it zooms in, and never out past fit.
        XCTAssertEqual(FileImageZoom.fit.stepped(in: true, fit: 1), .scale(1.5))
        XCTAssertEqual(FileImageZoom.fit.stepped(in: false, fit: 1), .fit)
        XCTAssertEqual(FileImageZoom.settled(0.3, fit: 0.3), .fit)
        XCTAssertEqual(FileImageZoom.settled(0.31, fit: 0.3), .scale(0.31))
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

    func testImagePreviewRejectsDecodeAmplification() {
        XCTAssertTrue(FilePreviewLoader.isSafeImageSize(CGSize(width: 8_000, height: 8_000)))
        XCTAssertFalse(FilePreviewLoader.isSafeImageSize(CGSize(width: 8_001, height: 8_000)))
        XCTAssertFalse(FilePreviewLoader.isSafeImageSize(CGSize(width: 32_769, height: 1)))
        XCTAssertFalse(FilePreviewLoader.isSafeImageSize(CGSize(width: CGFloat.infinity, height: 1)))
    }

    // MARK: cd Here

    func testChangeDirectoryCommandQuotesEveryPath() {
        let cases: [(String, String)] = [
            ("/home/ivan/nightly/fixtures", "cd '/home/ivan/nightly/fixtures'"),
            ("/Users/ivan/My Projects/docs", "cd '/Users/ivan/My Projects/docs'"),
            ("/home/ivan/it's", #"cd '/home/ivan/it'\''s'"#),
            ("/Users/ivan/Документы/日本語 ✓", "cd '/Users/ivan/Документы/日本語 ✓'"),
            ("/home/ivan/nightly/$(rm -rf ~)`x`;*", "cd '/home/ivan/nightly/$(rm -rf ~)`x`;*'"),
        ]
        for (path, command) in cases {
            XCTAssertEqual(FilesTerminalCommand.command(changingTo: path), command, path)
        }
        XCTAssertNil(FilesTerminalCommand.command(changingTo: "/tmp/a\nrm -rf ~"), "A newline would run the rest")
        XCTAssertNil(FilesTerminalCommand.command(changingTo: "/tmp/\u{1B}[201~x"), "A paste strips escape bytes")
        XCTAssertNil(FilesTerminalCommand.command(changingTo: "/tmp/\u{9B}x"))
        XCTAssertNil(FilesTerminalCommand.command(changingTo: ""))
    }

    func testChangeDirectoryTypesOnlyAtAPrompt() {
        let path = "/Users/ivan/src/api"
        XCTAssertNil(FilesTerminalCommand.refusal(path: path, hasTerminal: true, busy: false))
        XCTAssertEqual(FilesTerminalCommand.refusal(path: path, hasTerminal: true, busy: true), .busy)
        XCTAssertEqual(FilesTerminalCommand.refusal(path: path, hasTerminal: false, busy: true), .noTerminal)
        XCTAssertEqual(FilesTerminalCommand.refusal(path: "/tmp/a\nb", hasTerminal: true, busy: false), .unsafePath)
        XCTAssertEqual(FilesTerminalCommand.Refusal.busy.message, "The terminal is busy")
    }

    func testChangeDirectoryRefusalKeepsFilesShowingWithANotice() {
        let path = "/Users/ivan/src/api"
        // A tab with no terminal view: nothing is typed, the mode stays, and the files header has the notice.
        let tab = System.uuid()
        let files = FilesCoordinator { nil }
        files.switchMode(tab, to: .files)
        XCTAssertEqual(files.changeDirectory(tab, to: path), .noTerminal)
        XCTAssertEqual(files.mode(for: tab), .files)
        XCTAssertEqual(FilesTerminalNotices.shared.notice(for: tab), "The terminal isn’t running")
        FilesTerminalNotices.shared.clear(tab)
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

    func write(_ path: String, data: Data, mode: UInt32?, replace: Bool, parent: FileIdentity,
               replaced: FileIdentity?) async throws -> FileRevision {
        try await base.write(path, data: data, mode: mode, replace: replace, parent: parent, replaced: replaced)
    }
    func pack(transfer: String, base path: String, paths: [String]) async throws -> PackedArchive {
        try await base.pack(transfer: transfer, base: path, paths: paths)
    }
    func dropArchive(transfer: String) async throws { try await base.dropArchive(transfer: transfer) }
    func openUnpack(transfer: String, target: String, policy: ConflictPolicy, names: [String], parent: FileIdentity,
                    replacements: [String: FileIdentity]) async throws -> UnpackTransfer {
        try await base.openUnpack(transfer: transfer, target: target, policy: policy, names: names,
                                  parent: parent, replacements: replacements)
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

extension FilePreviewTests {
    /// Moving from one image to another keeps the last picture until the new one is decoded, but only from the
    /// selection it replaced: never across another file in between, nor after the selection clears.
    func testImageHandoffComesOnlyFromTheReplacedPreview() throws {
        let session = FilesSession(id: System.uuid())
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let picture = try XCTUnwrap(context.makeImage())
        session.showPreview("/tmp/before.png", entry: nil)
        let before = try XCTUnwrap(session.preview)
        XCTAssertNil(session.imageHandoff)
        session.drawnImage = FileImageHandoff(owner: ObjectIdentifier(before), image: picture,
                                              pixelSize: CGSize(width: 2, height: 2))

        session.showPreview("/tmp/after.png", entry: nil)
        XCTAssertTrue(session.imageHandoff?.image === picture)
        XCTAssertEqual(session.imageHandoff?.pixelSize, CGSize(width: 2, height: 2))

        session.showPreview("/tmp/notes.txt", entry: nil)
        XCTAssertNil(session.imageHandoff, "the picture belonged to the selection before the last")
        XCTAssertNil(session.drawnImage)

        session.showPreview("/tmp/before.png", entry: nil)
        session.drawnImage = FileImageHandoff(owner: ObjectIdentifier(try XCTUnwrap(session.preview)), image: picture,
                                              pixelSize: CGSize(width: 2, height: 2))
        session.selectionChanged(to: [], anchor: nil)
        XCTAssertNil(session.preview)
        XCTAssertNil(session.drawnImage, "a cleared selection keeps no picture")
    }
}
