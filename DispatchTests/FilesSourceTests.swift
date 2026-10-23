import Foundation
import XCTest
@testable import DispatchApp

/// `HelperFilesSource` against this Mac's helper in a temporary tree: the request shapes, the decoding into
/// the files models, and the error mapping. Listing (W1) and copying (W2) land in the helper separately; until
/// they do, the helper answers `unsupported` and these cases check exactly that, then their real assertions
/// take over by themselves.
final class FilesSourceTests: XCTestCase {
    private var session: HelperSession!
    private var root: URL!
    private var source: HelperFilesSource!

    override func setUp() async throws {
        let process = Process()
        process.executableURL = try XCTUnwrap(HelperApp.executable)
        process.arguments = ["--stdio"]
        process.standardError = FileHandle.nullDevice
        session = try await HelperSession(process: process)
        // Closed in a teardown block, not tearDown(): those run first, so the helper ends inside the case's app
        // journal (TestSupport's block finishes it), as a `defer { session.close() }` would.
        addTeardownBlock { [session] in session?.close() }
        root = URL(fileURLWithPath: try XCTUnwrap(System.environment("TMPDIR")))
            .appendingPathComponent("f" + System.uuid().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        source = HelperFilesSource(endpoint: .local, connection: session.connection, home: root.path, hostLabel: nil)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// What the file system says of a path the helper made or changed: observed, so a replay answers what the capture
    /// saw (the helper's work is replayed too, so the path is not there).
    private struct Attributes: Codable { let inode: UInt64; let modified: Double; let permissions: Int }
    private func attributes(_ path: String) throws -> Attributes {
        try System.observe("file.attributes", path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return Attributes(inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                              modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                              permissions: attributes[.posixPermissions] as? Int ?? 0)
        }
    }

    private func pattern(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    /// The operation's result, or nil after checking that the helper does not implement it yet.
    private func once<T>(_ operation: String, file: StaticString = #filePath, line: UInt = #line,
                         _ body: () async throws -> T) async throws -> T? {
        do { return try await body() } catch FilesSourceError.unsupported(let detail) {
            XCTAssertEqual(detail, "This Mac’s helper can’t do this yet", operation, file: file, line: line)
            return nil
        }
    }

    func testReadsWholeFilesAndRevisionGuardedWindows() async throws {
        let file = root.appendingPathComponent("rollout.bin"), bytes = pattern(300_000)
        try System.write(bytes, to: file)

        let whole = try await source.read(file.path, offset: 0, length: nil, revision: nil)
        XCTAssertEqual(whole.data, bytes, "No length reads to the end, across the helper's chunks")
        XCTAssertEqual(whole.revision.kind, .file)
        XCTAssertEqual(whole.revision.size, UInt64(bytes.count))
        let attributes = try attributes(file.path)
        XCTAssertEqual(whole.revision.inode, attributes.inode)
        XCTAssertNotNil(Int64(whole.revision.modifiedNs), "Stamps stay the wire's decimal strings")
        let modified = try XCTUnwrap(whole.revision.modified)
        XCTAssertEqual(modified.timeIntervalSince1970, attributes.modified, accuracy: 0.001)

        let first = try await source.read(file.path, offset: 0, length: 4096, revision: nil)
        XCTAssertEqual(first.data, bytes.prefix(4096))
        let second = try await source.read(file.path, offset: 4096, length: 4096, revision: first.revision)
        XCTAssertEqual(second.data, bytes.subdata(in: 4096..<8192))
        XCTAssertEqual(second.revision, first.revision)
        let tail = try await source.read(file.path, offset: UInt64(bytes.count - 10), length: 4096, revision: first.revision)
        XCTAssertEqual(tail.data, bytes.suffix(10), "A window past the end stops at it")

        // Rewritten (a new inode): a window guarded by the first revision refuses to mix versions.
        try System.write(pattern(300_001), to: file)
        do {
            _ = try await source.read(file.path, offset: 8192, length: 4096, revision: first.revision)
            XCTFail("A changed file answered a window of its old revision")
        } catch let error as FilesSourceError {
            XCTAssertEqual(error, .changed(file.path))
        }

        let missing = root.appendingPathComponent("missing").path
        do {
            _ = try await source.read(missing, offset: 0, length: nil, revision: nil)
            XCTFail("A missing file was read")
        } catch let error as FilesSourceError {
            XCTAssertEqual(error, .notFound(missing))
        }
    }

    func testListsAndSummarizesOnceTheHelperDoes() async throws {
        try System.write(Data("hello".utf8), to: root.appendingPathComponent("a.txt"))
        try System.write(Data("secret".utf8), to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: false)
        try System.write(Data("12345678".utf8), to: root.appendingPathComponent("dir/b.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "gone")

        guard let listing = try await once("files.list", { try await source.list(root.path, hidden: false) }) else { return }
        XCTAssertEqual(listing.path, root.path)
        XCTAssertFalse(listing.truncated)
        XCTAssertEqual(listing.entries.map(\.name), ["a.txt", "dangling", "dir", "link"])
        let entries = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        XCTAssertEqual(entries["a.txt"]?.kind, .file)
        XCTAssertEqual(entries["a.txt"]?.size, 5)
        XCTAssertNotNil(entries["a.txt"]?.modified)
        XCTAssertEqual(entries["dir"]?.kind, .directory)
        XCTAssertEqual(entries["link"]?.kind, .symlink)
        XCTAssertEqual(entries["link"]?.targetKind, .file)
        XCTAssertNil(entries["dangling"]?.targetKind)
        let hidden = try await source.list(root.path, hidden: true)
        XCTAssertEqual(hidden.entries.map(\.name), [".hidden", "a.txt", "dangling", "dir", "link"])

        let file = root.appendingPathComponent("a.txt").path, missing = root.appendingPathComponent("missing").path
        do { _ = try await source.list(file, hidden: false); XCTFail("A file was listed") }
        catch let error as FilesSourceError { XCTAssertEqual(error, .notDirectory(file)) }
        do { _ = try await source.list(missing, hidden: false); XCTFail("A missing folder was listed") }
        catch let error as FilesSourceError { XCTAssertEqual(error, .notFound(missing)) }

        guard let summary = try await once("files.summary", { try await source.summary(root.path) }) else { return }
        XCTAssertEqual(summary.folders, 1)
        XCTAssertEqual(summary.files, 5, "a.txt, .hidden, dir/b.txt and both symlinks: anything not a folder counts")
        XCTAssertEqual(summary.bytes, 5 + 6 + 8, "Regular-file sizes only")
        XCTAssertFalse(summary.truncated)
    }

    func testWritesAndCopiesATreeOnceTheHelperDoes() async throws {
        let written = root.appendingPathComponent("new.txt").path
        let rootListing = try await source.list(root.path, hidden: true)
        let rootIdentity = try XCTUnwrap(rootListing.identity)
        guard let revision = try await once("files.write", {
            try await source.write(written, data: Data("hello".utf8), mode: nil, replace: false,
                                   parent: rootIdentity, replaced: nil)
        }) else { return }
        XCTAssertEqual(revision.kind, .file)
        XCTAssertEqual(revision.size, 5)
        XCTAssertEqual(try System.read(URL(fileURLWithPath: written)), Data("hello".utf8))
        do {
            _ = try await source.write(written, data: Data("again".utf8), mode: nil, replace: false,
                                       parent: rootIdentity, replaced: nil)
            XCTFail("An existing file was replaced without replace")
        } catch let error as FilesSourceError {
            XCTAssertEqual(error, .exists(written))
        }
        let currentListing = try await source.list(root.path, hidden: true)
        let existing = try XCTUnwrap(currentListing.entries.first { $0.name == "new.txt" }?.identity)
        let replaced = try await source.write(written, data: Data("bye".utf8), mode: 0o600, replace: true,
                                              parent: rootIdentity, replaced: existing)
        XCTAssertEqual(replaced.size, 3)
        XCTAssertEqual(try attributes(written).permissions, 0o600)

        // Pack two items, stream the archive in windows, unpack it into another folder.
        let tree = root.appendingPathComponent("tree"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try System.write(pattern(10_000), to: tree.appendingPathComponent("docs/data.bin"))
        try System.write(Data("readme".utf8), to: tree.appendingPathComponent("README.md"))
        let transfer = System.uuid().uuidString
        guard let packed = try await once("files.pack", {
            try await source.pack(transfer: transfer, base: tree.path,
                                  paths: [tree.appendingPathComponent("docs").path, tree.appendingPathComponent("README.md").path])
        }) else { return }
        XCTAssertEqual(packed.files, 2)
        XCTAssertEqual(packed.folders, 1)
        XCTAssertEqual(packed.bytes, 10_006)
        XCTAssertTrue(System.exists(URL(fileURLWithPath: packed.archive)))
        var archive = Data(), first: FileRevision?
        while UInt64(archive.count) < packed.size {
            let window = try await source.read(packed.archive, offset: UInt64(archive.count), length: 4096, revision: first)
            XCTAssertFalse(window.data.isEmpty)
            archive.append(window.data)
            first = first ?? window.revision
        }
        XCTAssertEqual(UInt64(archive.count), packed.size)

        let unpack = System.uuid().uuidString
        let targetListing = try await source.list(target.path, hidden: true)
        let targetIdentity = try XCTUnwrap(targetListing.identity)
        let opened = try await source.openUnpack(transfer: unpack, target: target.path, policy: .keep,
                                                 names: ["docs", "README.md"], parent: targetIdentity, replacements: [:])
        XCTAssertTrue(opened.staging.hasPrefix(target.path + "/.dispatch-copy-"))
        let staged = try await source.writeUnpack(transfer: unpack, data: archive)
        XCTAssertEqual(staged, UInt64(archive.count))
        let result = try await source.closeUnpack(transfer: unpack, commit: true)
        XCTAssertEqual(result.entries, 3)
        XCTAssertEqual(result.bytes, 10_006)
        XCTAssertEqual(try System.read(target.appendingPathComponent("docs/data.bin")), pattern(10_000))
        XCTAssertEqual(try System.read(target.appendingPathComponent("README.md")), Data("readme".utf8))
        XCTAssertFalse(System.exists(URL(fileURLWithPath: opened.staging)), "Staging is removed after the move")

        try await source.dropArchive(transfer: transfer)
        XCTAssertFalse(System.exists(URL(fileURLWithPath: packed.archive)))
    }

    func testKeepBothNamesMatchTheHelpers() async throws {
        let tree = root.appendingPathComponent("tree"), target = root.appendingPathComponent("target")
        let files = ["a.txt", "Makefile", "archive.tar.gz", ".env", "notes."], folders = ["Photos.app", "build"]
        for name in files {
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try System.write(Data("new".utf8), to: tree.appendingPathComponent(name))
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try System.write(Data("old".utf8), to: target.appendingPathComponent(name))
        }
        for name in folders {
            try FileManager.default.createDirectory(at: tree.appendingPathComponent(name), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        // "a 2.txt" is taken already: the helper goes on to "a 3.txt".
        try System.write(Data("older".utf8), to: target.appendingPathComponent("a 2.txt"))
        let before = Set(try System.list(target))

        let names = files + folders, transfer = System.uuid().uuidString
        guard let packed = try await once("files.pack", {
            try await source.pack(transfer: transfer, base: tree.path, paths: names.map { tree.appendingPathComponent($0).path })
        }) else { return }
        var archive = Data()
        while UInt64(archive.count) < packed.size {
            archive.append(try await source.read(packed.archive, offset: UInt64(archive.count), length: 1 << 20, revision: nil).data)
        }
        try await source.dropArchive(transfer: transfer)
        let unpack = System.uuid().uuidString
        let targetListing = try await source.list(target.path, hidden: true)
        let targetIdentity = try XCTUnwrap(targetListing.identity)
        _ = try await source.openUnpack(transfer: unpack, target: target.path, policy: .keep, names: names,
                                        parent: targetIdentity, replacements: [:])
        _ = try await source.writeUnpack(transfer: unpack, data: archive)
        let result = try await source.closeUnpack(transfer: unpack, commit: true)
        XCTAssertEqual(result.kept, UInt64(names.count))

        let arrived = Set(try System.list(target)).subtracting(before)
        var taken = before, expected = Set<String>()
        for name in names {
            let kept = FileTransferEngine.keptName(name, folder: folders.contains(name), taken: taken)
            taken.insert(kept)
            expected.insert(kept)
        }
        XCTAssertEqual(arrived, expected)
        XCTAssertTrue(arrived.contains("a 3.txt"))
        XCTAssertTrue(arrived.contains("Photos.app 2"), "A folder's name is numbered whole")
    }
}
