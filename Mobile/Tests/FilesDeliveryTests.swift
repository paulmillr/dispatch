import Foundation
import XCTest
@testable import DispatchMobile

/// Files' reads and writes that must not go wrong quietly (docs/ios.md, Files): Share takes only the whole revision the
/// preview read, a folder read is the helper's `is_directory` (listed instead), Open in Terminal types only into a
/// terminal whose screen is the server's now and awaits the helper's answer, and folder rows' counts come back after a
/// reconnect.
@MainActor
final class FilesDeliveryTests: XCTestCase {
    /// Files in memory whose reads can come back short, or answer another revision than the one asked for.
    final class Files: MobileFilesSource, @unchecked Sendable {
        var files: [String: Data]
        var folders: Set<String>
        /// Reads of a path after this many come back with their last byte missing (a cut stream).
        var shortAfter: [String: Int] = [:]
        /// Reads of a path after this many see the file rewritten (a new revision).
        var changeAfter: [String: Int] = [:]
        /// The source answers whatever revision it finds, ignoring the guard (as a broken one would).
        var ignoresGuard = false
        private(set) var reads: [(path: String, offset: UInt64, length: UInt64)] = []
        private(set) var lists: [String] = []

        init(_ files: [String: Data], folders: Set<String> = []) {
            self.files = files
            self.folders = folders
        }

        func list(_ path: String, hidden: Bool) async throws -> FileListing {
            lists.append(path)
            guard folders.contains(path) else { throw FilesSourceError.notDirectory(path) }
            return FileListing(path: path, entries: [], truncated: false)
        }

        func read(_ path: String, offset: UInt64, length: UInt64, revision: FileRevision?) async throws -> (data: Data, revision: FileRevision) {
            reads.append((path, offset, length))
            let count = reads.filter { $0.path == path }.count
            if folders.contains(path) { throw FilesSourceError.isDirectory(path) }
            guard let data = files[path] else { throw FilesSourceError.notFound(path) }
            let generation = changeAfter[path].map { count > $0 ? 2 : 1 } ?? 1
            let current = FileRevision(kind: .file, size: UInt64(data.count), device: 1, inode: 7,
                                       modifiedNs: "1800000000000000000", changedNs: String(generation))
            if let revision, revision != current, !ignoresGuard { throw FilesSourceError.changed(path) }
            let start = Int(min(offset, UInt64(data.count))), end = Int(min(UInt64(data.count), offset + length))
            var window = data.subdata(in: start..<end)
            if let after = shortAfter[path], count > after, !window.isEmpty { window = window.dropLast() }
            return (window, current)
        }

        func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput {
            GitOutput(status: 128, output: "", truncated: false)
        }
    }

    private func preview(_ path: String, _ files: Files?) -> FilePreview {
        FilePreview(path: path, host: "mba2") { files }
    }

    private func refused(_ preview: FilePreview, limit: UInt64 = FilePreview.shareLimit) async -> FilesSourceError? {
        do {
            let data = try await preview.bytes(limit: limit)
            XCTFail("Shared \(data.count) bytes")
            return nil
        } catch {
            return error as? FilesSourceError
        }
    }

    // MARK: Share (item 10)

    /// A file one byte past the limit is refused before anything is read for it: its first bytes are never shared.
    func testShareRefusesAFileJustOverTheLimit() async throws {
        let files = Files(["/w/app.bin": Data([0] + Array(repeating: 1, count: 1_024))])
        let binary = preview("/w/app.bin", files)
        await binary.load()
        XCTAssertEqual(binary.content, .binary)
        XCTAssertTrue(binary.canShare)
        let reads = files.reads.count
        guard case .limit? = await refused(binary, limit: 1_024) else { return XCTFail("not refused for its size") }
        XCTAssertEqual(files.reads.count, reads, "Nothing read past the head")
        let whole = try await binary.bytes(limit: 1_025)
        XCTAssertEqual(whole.count, 1_025, "At the limit it is shared whole")
    }

    /// A preview that failed or loaded offline has no revision: Share is off, and asking anyway reads nothing, even once
    /// the host is back; loading again (Try again) brings it.
    func testFailedAndOfflinePreviewsShareNothingAfterAReconnect() async throws {
        var online = false
        let files = Files(["/w/app.bin": Data([0, 1, 2, 3])])
        let offline = FilePreview(path: "/w/app.bin", host: "mba2") { online ? files : nil }
        await offline.load()
        XCTAssertEqual(offline.content, .failed("mba2 is offline."))
        XCTAssertFalse(offline.canShare)
        online = true
        guard case .other(code: "not_loaded", _)? = await refused(offline) else { return XCTFail("shared without a revision") }
        XCTAssertTrue(files.reads.isEmpty, "No read of a size nobody gave")
        await offline.load()
        XCTAssertTrue(offline.canShare)
        let bytes = try await offline.bytes()
        XCTAssertEqual(bytes, Data([0, 1, 2, 3]))

        let missing = preview("/w/later.bin", files)
        await missing.load()
        XCTAssertEqual(missing.content, .failed("later.bin is not on mba2 any more."))
        files.files["/w/later.bin"] = Data([9, 9])
        XCTAssertFalse(missing.canShare)
        let before = files.reads.count
        guard case .other? = await refused(missing) else { return XCTFail("a failed preview shared") }
        XCTAssertEqual(files.reads.count, before)
    }

    /// The read Share makes must be the revision's whole length: a short one fails closed.
    func testShareFailsClosedOnAShortRead() async throws {
        let files = Files(["/w/app.bin": Data([0] + Array(repeating: 7, count: 99))])
        files.shortAfter["/w/app.bin"] = 1
        let binary = preview("/w/app.bin", files)
        await binary.load()
        XCTAssertEqual(binary.content, .binary)
        let short = await refused(binary)
        XCTAssertEqual(short, .changed("/w/app.bin"))
        XCTAssertEqual(files.reads.last?.length, 100, "Asked for the revision's size")
    }

    /// The file rewritten between the preview's read and Share's: refused, whether the source honours the revision guard
    /// (`changed`) or answers the new revision anyway.
    func testShareFailsClosedWhenTheRevisionChanges() async throws {
        let files = Files(["/w/app.bin": Data([0, 1, 2, 3])])
        files.changeAfter["/w/app.bin"] = 1
        let binary = preview("/w/app.bin", files)
        await binary.load()
        let guarded = await refused(binary)
        XCTAssertEqual(guarded, .changed("/w/app.bin"))
        files.ignoresGuard = true
        let unguarded = await refused(binary)
        XCTAssertEqual(unguarded, .changed("/w/app.bin"), "Another revision's bytes are not this file's")
    }

    /// A whole text shares what loaded, without a read; a truncated one is read whole at its revision.
    func testShareOfTextIsTheWholeRevision() async throws {
        let small = Data("let a = 1\n".utf8)
        let long = Data(String(repeating: String(repeating: "z", count: 99) + "\n", count: 3_000).utf8)
        let files = Files(["/w/a.ts": small, "/w/big.log": long])
        let text = preview("/w/a.ts", files)
        await text.load()
        let reads = files.reads.count
        let bytes = try await text.bytes()
        XCTAssertEqual(bytes, small)
        XCTAssertEqual(files.reads.count, reads)
        let head = preview("/w/big.log", files)
        await head.load()
        XCTAssertTrue(head.truncated)
        let whole = try await head.bytes()
        XCTAssertEqual(whole, long)
        XCTAssertEqual(files.reads.last?.length, UInt64(long.count))
    }

    // MARK: Folders (item 13)

    /// The helper's `is_directory` is the folder's own error on both sides; a folder read shows its listing without
    /// another request, and a genuine refusal (`invalid_request`, a socket) stays an error, never a folder.
    func testAFolderReadIsTheHelpersIsDirectory() async throws {
        XCTAssertEqual(HelperMobileFilesSource.map(HelperFailure(code: "is_directory", message: "is a directory"), path: "/w/src", host: "mba2"),
                       .isDirectory("/w/src"))
        XCTAssertEqual(HelperMobileFilesSource.map(HelperFailure(code: "invalid_request", message: "x"), path: "/w/s", host: "mba2"),
                       .other(code: "invalid_request", message: "x"))
        let files = Files([:], folders: ["/w/src"])
        let folder = preview("/w/src", files)
        await folder.load()
        XCTAssertEqual(folder.content, .folder)
        XCTAssertTrue(files.lists.isEmpty, "The helper said so: nothing to probe")
        XCTAssertFalse(folder.canShare)

        final class Socket: MobileFilesSource, @unchecked Sendable {
            func list(_ path: String, hidden: Bool) async throws -> FileListing { FileListing(path: path, entries: [], truncated: false) }
            func read(_ path: String, offset: UInt64, length: UInt64, revision: FileRevision?) async throws -> (data: Data, revision: FileRevision) {
                throw HelperMobileFilesSource.map(HelperFailure(code: "invalid_request", message: "invalid input parameter"), path: path, host: "mba2")
            }
            func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput { GitOutput(status: 0, output: "", truncated: false) }
        }
        let socket = Socket()
        let refused = FilePreview(path: "/w/s.sock", host: "mba2") { socket }
        await refused.load()
        XCTAssertEqual(refused.content, .failed("invalid input parameter"), "Not shown as a folder")

        do {
            _ = try await FilesSample.shared.read("/Users/sam/src/web/src", offset: 0, length: 16, revision: nil)
            XCTFail("The sample read a folder")
        } catch let error as FilesSourceError {
            XCTAssertEqual(error, .isDirectory("/Users/sam/src/web/src"))
        }
    }

    // MARK: Folder counts (item 15)

    /// A helper answering `files.list` for any folder with two files, or leaving the listing open (`slow`).
    nonisolated private static func counting(slow: Bool = false) -> ScriptedHelper {
        ScriptedHelper.scripted { @Sendable request in
            guard request.method == "files.list" else { return .result(["status": 0, "output": "", "truncated": false]) }
            if slow { return nil }
            let path = request.params["path"] as? String ?? ""
            return .result(["path": path, "entries": [FilesListingTests.entry("a", kind: "file", minutes: 1),
                                                      FilesListingTests.entry("b", kind: "file", minutes: 1)], "truncated": false])
        }
    }

    private final class Link {
        var source: HelperMobileFilesSource?
        func connect(_ helper: ScriptedHelper?) { source = helper.map { HelperMobileFilesSource(client: $0.client, host: "mba2") } }
    }

    private func browser(_ link: Link) -> FilesBrowser {
        FilesBrowser(tab: FilesListingTests.ref, host: "mba2", pause: { _ in }) { link.source }
    }

    private func listed(_ helper: ScriptedHelper, _ path: String) -> Int {
        helper.requests("files.list").filter { $0.params["path"] as? String == path }.count
    }

    /// Launched offline: the rows on screen wait for the connection and are counted once it comes.
    func testCountsAskedOfflineComeWithTheConnection() async throws {
        let link = Link(), browser = browser(link)
        for name in ["a", "b", "c"] { browser.needCount("/w/\(name)") }
        XCTAssertEqual(browser.countsPending, 3, "Waiting, not dropped")
        let helper = Self.counting()
        link.connect(helper)
        await browser.reconnected()
        try await TestSupport.eventually { ["a", "b", "c"].allSatisfy { browser.count("/w/\($0)")?.count == 2 } }
        XCTAssertEqual(["a", "b", "c"].map { listed(helper, "/w/\($0)") }, [1, 1, 1])
    }

    /// The link drops with counts running and waiting: none is remembered as failed, and the reconnect asks every row
    /// still on screen again, on the new connection, without navigating.
    func testADropDuringCountsAsksThemAgainAfterTheReconnect() async throws {
        let link = Link(), browser = browser(link)
        let first = Self.counting(slow: true)
        link.connect(first)
        let rows = (0..<6).map { "/w/d\($0)" }
        for row in rows { browser.needCount(row) }
        _ = try await first.wait(for: "files.list", count: FilesBrowser.countConcurrency)
        link.connect(nil)
        first.close()
        try await TestSupport.eventually { browser.countsPending == rows.count - FilesBrowser.countConcurrency }
        XCTAssertTrue(rows.allSatisfy { browser.count($0) == nil })
        let second = Self.counting()
        link.connect(second)
        await browser.reconnected()
        try await TestSupport.eventually { rows.allSatisfy { browser.count($0)?.count == 2 } }
        XCTAssertEqual(rows.map { listed(second, $0) }, Array(repeating: 1, count: rows.count))
    }

    /// Reconnects one after another ask each row once; a read still on the old connection when the new one came asks
    /// again on the new one when it fails.
    func testRapidReconnectsAskEachRowOnce() async throws {
        let link = Link(), browser = browser(link)
        let old = Self.counting(slow: true)
        link.connect(old)
        browser.needCount("/w/running")
        _ = try await old.wait(for: "files.list")
        link.connect(nil)
        browser.needCount("/w/queued")
        let helper = Self.counting()
        link.connect(helper)
        async let one: Void = browser.reconnected()
        async let two: Void = browser.reconnected()
        _ = await (one, two)
        await browser.reconnected()
        try await TestSupport.eventually { browser.count("/w/queued") != nil }
        XCTAssertEqual(listed(helper, "/w/queued"), 1)
        XCTAssertEqual(listed(helper, "/w/running"), 0, "Still running on the old connection")
        old.close()
        try await TestSupport.eventually { browser.count("/w/running") != nil }
        XCTAssertEqual(listed(helper, "/w/running"), 1)
        XCTAssertEqual(listed(helper, "/w/queued"), 1)
    }

    /// A row that left the screen is not counted after the reconnect; leaving the listing forgets every row.
    func testRowsOffScreenAreNotCountedAfterAReconnect() async throws {
        let link = Link(), browser = browser(link)
        browser.needCount("/w/kept")
        browser.needCount("/w/gone")
        browser.dropCount("/w/gone")
        let helper = Self.counting()
        link.connect(helper)
        await browser.reconnected()
        try await TestSupport.eventually { browser.count("/w/kept") != nil }
        XCTAssertEqual(listed(helper, "/w/gone"), 0)
        link.connect(nil)
        browser.needCount("/w/later")
        browser.cancelCounts()
        link.connect(helper)
        await browser.reconnected()
        XCTAssertEqual(browser.countsPending, 0, "Nothing queued or running for it")
    }
}

extension FilesDeliveryTests {
    /// More folder rows on screen than the queue holds, asked offline: after the reconnect every one is counted, once,
    /// in the rows' order as capacity frees (none dropped for the queue's bound).
    func testEveryRowOnScreenIsCountedAfterAReconnect() async throws {
        let link = Link(), browser = browser(link)
        let rows = (0..<(FilesBrowser.countQueueLimit + 8)).map { "/w/r\($0)" }
        for row in rows { browser.needCount(row) }
        XCTAssertEqual(browser.countsPending, FilesBrowser.countQueueLimit, "The queue keeps its bound")
        let helper = Self.counting()
        link.connect(helper)
        await browser.reconnected()
        try await TestSupport.eventually { rows.allSatisfy { browser.count($0) != nil } }
        XCTAssertEqual(rows.map { listed(helper, $0) }, Array(repeating: 1, count: rows.count))
        let order = helper.requests("files.list").compactMap { $0.params["path"] as? String }
        XCTAssertEqual(Set(order.prefix(4)), Set(rows.prefix(4)), "The rows' order")

        // Online, a burst of rows past the queue's bound: the ones the queue let go are asked after the rest.
        let more = (0..<(FilesBrowser.countQueueLimit + 8)).map { "/w/m\($0)" }
        for row in more { browser.needCount(row) }
        try await TestSupport.eventually { more.allSatisfy { browser.count($0) != nil } }
        XCTAssertEqual(more.map { listed(helper, $0) }, Array(repeating: 1, count: more.count))
    }
}
