import Foundation
import XCTest
@testable import DispatchApp

/// The transfer engine against two in-memory hosts: what it plans, what reaches the target, what a cancel or a
/// failure leaves behind (nothing), and what the rows say. No helper, no window, no wall-clock sleeps.
@MainActor
final class FileTransferEngineTests: XCTestCase {
    private var coordinator = FilesCoordinator { nil }
    /// The dismissal sleeps the engine asked for, by name.
    private var sleeps: [(duration: Duration, name: String)] = []

    override func setUp() async throws {
        coordinator = FilesCoordinator { nil }
        sleeps = []
    }

    // MARK: Planning

    func testAFewSmallFilesAreWrittenOneByOne() async throws {
        let (source, target) = hosts()
        for name in ["a.txt", "b.txt", "c.txt"] { source.file("/src/\(name)", "contents of \(name)") }
        let session = session(target)
        let transfer = engine().copy(items: ["/src/a.txt", "/src/b.txt", "/src/c.txt"], from: source, to: target,
                                     directory: "/dst", in: session, kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
        XCTAssertEqual(target.text("/dst/b.txt"), "contents of b.txt")
        XCTAssertEqual(target.paths(below: "/dst"), ["a.txt", "b.txt", "c.txt"])
        XCTAssertFalse(source.calls.contains { $0.hasPrefix("pack") }, "\(source.calls)")
        XCTAssertEqual(target.calls.filter { $0.hasPrefix("write") }, ["write /dst/a.txt", "write /dst/b.txt", "write /dst/c.txt"])
        XCTAssertEqual(transfer.entriesDone, 3)
        XCTAssertEqual(transfer.bytesDone, transfer.bytesTotal)
        XCTAssertEqual(session.transfers.map(\.id), [transfer.id])
        XCTAssertFalse(transfer.archived, "Neither packed nor unpacked: the row shows the send dot alone")
        XCTAssertEqual(FileTransferRow.cancelHelp(transfer), "Cancel · stops after the file being written; files already copied stay")
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("read") }.count, 3)
    }

    func testFoldersManyFilesAndLargeFilesTravelAsAnArchive() async throws {
        func packs(_ build: (FakeFilesSource) -> [String]) async throws -> Bool {
            let (source, target) = hosts()
            let items = build(source)
            let transfer = engine().copy(items: items, from: source, to: target, directory: "/dst", in: session(target),
                                         kind: .copyIn)
            try await settle(transfer)
            XCTAssertEqual(transfer.stage, .done)
            return source.calls.contains("pack /src") && !target.calls.contains { $0.hasPrefix("write") }
        }
        let folder = try await packs { source in
            source.file("/src/tree/a.txt", "a")
            return ["/src/tree"]
        }
        XCTAssertTrue(folder, "A folder needs the archive")
        let many = try await packs { source in
            (1...21).map { index in
                source.file("/src/f\(index).txt", "\(index)")
                return "/src/f\(index).txt"
            }
        }
        XCTAssertTrue(many, "21 files are more than a few")
        let large = try await packs { source in
            source.file("/src/big.bin", Data(count: 4 << 20 + 1))
            return ["/src/big.bin"]
        }
        XCTAssertTrue(large, "Over 4 MiB in all needs the archive")
        let link = try await packs { source in
            source.file("/src/real.txt", "real")
            source.symlink("/src/link.txt", to: "real.txt")
            return ["/src/link.txt"]
        }
        XCTAssertTrue(link, "A symlink travels as a link, in the archive")
    }

    func testTwentySmallFilesStillTakeTheFilePath() async throws {
        let (source, target) = hosts()
        let items = (1...20).map { index in
            source.file("/src/f\(index).txt", "\(index)")
            return "/src/f\(index).txt"
        }
        let transfer = engine().copy(items: items, from: source, to: target, directory: "/dst", in: session(target),
                                     kind: .copyIn)
        try await settle(transfer)
        XCTAssertFalse(source.calls.contains { $0.hasPrefix("pack") })
        XCTAssertEqual(target.paths(below: "/dst").count, 20)
    }

    // MARK: The archive path

    func testArchiveRoundTripsATree() async throws {
        let (source, target) = hosts()
        source.file("/src/project/README.md", "# project\n")
        source.file("/src/project/src/main.swift", "print(1)\n", mode: 0o755)
        source.file("/src/project/src/lib/util.swift", "let x = 1\n")
        source.directory("/src/project/empty")
        source.symlink("/src/project/latest", to: "src/main.swift")
        source.file("/src/notes.txt", "notes")
        let session = session(target)
        let transfer = engine().copy(items: ["/src/project", "/src/notes.txt"], from: source, to: target,
                                     directory: "/dst", in: session, kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
        XCTAssertEqual(target.paths(below: "/dst"), source.paths(below: "/src"))
        XCTAssertEqual(target.text("/dst/project/src/lib/util.swift"), "let x = 1\n")
        XCTAssertEqual(target.node("/dst/project/src/main.swift")?.mode, 0o755)
        XCTAssertEqual(target.node("/dst/project/latest")?.target, "src/main.swift")
        XCTAssertEqual(transfer.entries, 9)
        XCTAssertEqual(transfer.entriesDone, 9)
        let id = transfer.id.uuidString
        XCTAssertEqual(target.calls.filter { !$0.hasPrefix("unpack.write") },
                       ["list /dst", "unpack.open /dst", "unpack.close \(id)"])
        XCTAssertEqual(target.unpackNames, [["project", "notes.txt"]], "The helper is told the archive's top-level names")
        XCTAssertTrue(transfer.archived)
        XCTAssertEqual(FileTransferRow.cancelHelp(transfer), "Cancel · nothing is written until unpacking starts")
        XCTAssertTrue(source.calls.contains("pack.drop \(id)"), "The archive is dropped after a copy too")
        XCTAssertNil(source.node("/tmp/dispatch-pack-\(id).tar.zst"))
        XCTAssertFalse(target.paths(below: "/dst").contains { $0.contains(".dispatch-copy-") })
    }

    func testTheArchiveTravelsInWindows() async throws {
        let (source, target) = hosts()
        source.file("/src/tree/data.txt", String(repeating: "0123456789", count: 200))
        let engine = engine()
        engine.limits.window = 256
        let transfer = engine.copy(items: ["/src/tree"], from: source, to: target, directory: "/dst",
                                   in: session(target), kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
        let size = try XCTUnwrap(transfer.bytesTotal)
        let windows = Int((size + 255) / 256)
        XCTAssertGreaterThan(windows, 4)
        XCTAssertEqual(target.calls.filter { $0.hasPrefix("unpack.write") }.count, windows)
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("read /tmp/dispatch-pack-") }.count, windows)
        XCTAssertEqual(transfer.bytesDone, size)
        XCTAssertEqual(target.text("/dst/tree/data.txt"), source.text("/src/tree/data.txt"))
    }

    func testRowsFromSeveralFoldersArriveSideBySide() async throws {
        let (source, target) = hosts()
        source.file("/src/a/one.txt", "1")
        source.file("/src/b/two.txt", "2")
        source.directory("/src/b/three")
        let transfer = engine().copy(items: ["/src/a/one.txt", "/src/b/two.txt", "/src/b/three"], from: source,
                                     to: target, directory: "/dst", in: session(target), kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
        XCTAssertEqual(target.paths(below: "/dst"), ["one.txt", "three", "two.txt"])
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("pack ") }, ["pack /src/a", "pack /src/b"])
    }

    // MARK: Conflicts

    func testConflictsAreAskedBeforeAnythingIsWritten() async throws {
        for resolution in [FileTransfer.ConflictResolution.replace, .keepBoth, .skip, .cancel] {
            let (source, target) = hosts()
            source.file("/src/a.txt", "new a")
            source.file("/src/b.txt", "new b")
            target.file("/dst/a.txt", "old a")
            let transfer = engine().copy(items: ["/src/a.txt", "/src/b.txt"], from: source, to: target,
                                         directory: "/dst", in: session(target), kind: .copyIn)
            try await TestSupport.eventually { transfer.stage == .conflict(existing: ["a.txt"]) }
            XCTAssertEqual(target.calls, ["list /dst"], "Nothing is written before the answer")
            XCTAssertEqual(FileTransferText(transfer, host: "homelab").title, "dst/ already has 1 of these")
            transfer.resolveConflict?(resolution)
            try await settle(transfer)
            switch resolution {
            case .replace:
                XCTAssertEqual(transfer.stage, .done)
                XCTAssertEqual(target.text("/dst/a.txt"), "new a")
                XCTAssertEqual(target.paths(below: "/dst"), ["a.txt", "b.txt"])
            case .keepBoth:
                XCTAssertEqual(target.text("/dst/a.txt"), "old a")
                XCTAssertEqual(target.text("/dst/a 2.txt"), "new a")
                XCTAssertEqual(target.paths(below: "/dst"), ["a 2.txt", "a.txt", "b.txt"])
            case .skip:
                XCTAssertEqual(target.text("/dst/a.txt"), "old a")
                XCTAssertEqual(target.paths(below: "/dst"), ["a.txt", "b.txt"])
                XCTAssertFalse(target.calls.contains("write /dst/a.txt"))
                XCTAssertFalse(source.calls.contains("read /src/a.txt"), "A skipped item is not even read")
            case .cancel:
                XCTAssertEqual(transfer.stage, .cancelled)
                XCTAssertEqual(target.calls, ["list /dst"])
                XCTAssertEqual(target.paths(below: "/dst"), ["a.txt"])
            }
        }
    }

    func testArchiveConflictsUseTheChosenPolicy() async throws {
        for (resolution, expected) in [(FileTransfer.ConflictResolution.replace, ["tree", "tree/new.txt"]),
                                       (.keepBoth, ["tree", "tree/old.txt", "tree 2", "tree 2/new.txt"]),
                                       (.skip, ["tree", "tree/old.txt"])] {
            let (source, target) = hosts()
            source.file("/src/tree/new.txt", "new")
            source.file("/src/other/x.txt", "x")
            target.file("/dst/tree/old.txt", "old")
            let transfer = engine().copy(items: ["/src/tree"], from: source, to: target, directory: "/dst",
                                         in: session(target), kind: .copyIn)
            try await TestSupport.eventually { transfer.stage == .conflict(existing: ["tree"]) }
            transfer.resolveConflict?(resolution)
            try await settle(transfer)
            XCTAssertEqual(transfer.stage, .done)
            XCTAssertEqual(target.paths(below: "/dst"), expected, "\(resolution)")
        }
    }

    func testKeepsBothWithoutAskingWhenAskingIsOff() async throws {
        let (source, target) = hosts()
        source.file("/src/a.txt", "new a")
        target.file("/dst/a.txt", "old a")
        target.file("/dst/a 2.txt", "older a")
        let transfer = engine(asks: false).copy(items: ["/src/a.txt"], from: source, to: target, directory: "/dst",
                                                in: session(target), kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
        XCTAssertEqual(target.text("/dst/a 3.txt"), "new a")
        XCTAssertEqual(target.text("/dst/a.txt"), "old a")
    }

    func testConflictsFoldCaseAndAskOnlyAboutListedNames() async throws {
        // A case variant is a conflict: on this Mac's volumes it is the same name.
        let (source, target) = hosts()
        source.file("/src/readme.md", "new readme")
        source.file("/src/new.txt", "new")
        target.file("/dst/README.md", "old readme")
        let transfer = engine().copy(items: ["/src/readme.md", "/src/new.txt"], from: source, to: target, directory: "/dst",
                                     in: session(target), kind: .copyIn)
        try await TestSupport.eventually { transfer.stage == .conflict(existing: ["readme.md"]) }
        transfer.resolveConflict?(.cancel)
        try await settle(transfer)

        // Past a truncated listing a name may exist unseen: Replace never reaches it, it is kept beside.
        let (tree, folder) = hosts()
        tree.file("/src/a/new.txt", "new a")
        tree.file("/src/c/new.txt", "new c")
        folder.file("/dst/a/old.txt", "old a")
        folder.file("/dst/c/old.txt", "old c")
        folder.listLimit = 1
        let replace = engine().copy(items: ["/src/a", "/src/c"], from: tree, to: folder, directory: "/dst",
                                    in: session(folder), kind: .copyIn)
        try await TestSupport.eventually { replace.stage == .conflict(existing: ["a"]) }
        replace.resolveConflict?(.replace)
        try await settle(replace)
        XCTAssertEqual(replace.stage, .done)
        XCTAssertEqual(folder.paths(below: "/dst"), ["a", "a/new.txt", "c", "c/old.txt", "c 2", "c 2/new.txt"])
        XCTAssertEqual(folder.unpackNames, [["a"], ["c"]], "Agreed and unagreed names travel in separate archives")
    }

    func testRepeatedNamesInOneDragKeepBoth() async throws {
        // Files: the later one keeps both, even under Replace.
        let (source, target) = hosts()
        source.file("/src/one/a.txt", "one")
        source.file("/src/two/a.txt", "two")
        target.file("/dst/a.txt", "old")
        let files = engine().copy(items: ["/src/one/a.txt", "/src/two/a.txt"], from: source, to: target, directory: "/dst",
                                  in: session(target), kind: .copyIn)
        try await TestSupport.eventually { files.stage == .conflict(existing: ["a.txt"]) }
        files.resolveConflict?(.replace)
        try await settle(files)
        XCTAssertEqual(files.stage, .done)
        XCTAssertEqual(target.text("/dst/a.txt"), "one")
        XCTAssertEqual(target.text("/dst/a 2.txt"), "two")
        XCTAssertEqual(target.paths(below: "/dst"), ["a 2.txt", "a.txt"])

        // Folders: the second archive unpacks after the first took the name.
        let (tree, folder) = hosts()
        tree.file("/src/one/tree/x.txt", "one")
        tree.file("/src/two/Tree/y.txt", "two")
        let folders = engine().copy(items: ["/src/one/tree", "/src/two/Tree"], from: tree, to: folder, directory: "/dst",
                                    in: session(folder), kind: .copyIn)
        try await settle(folders)
        XCTAssertEqual(folders.stage, .done)
        XCTAssertEqual(folder.paths(below: "/dst"), ["Tree", "Tree/y.txt", "tree", "tree/x.txt"],
                       "The fake is case-sensitive: both names were free there, and neither replaced the other")
        XCTAssertEqual(folder.unpackNames, [["tree"], ["Tree"]])
        XCTAssertEqual(tree.calls.filter { $0.hasPrefix("pack ") }, ["pack /src/one", "pack /src/two"])
    }

    func testKeptNamesNumberBeforeAFilesExtensionAndAfterAFolder() {
        let taken: Set<String> = ["a.txt", "a 2.txt", "Makefile", "archive.tar.gz", ".env", "Photos.app"]
        XCTAssertEqual(FileTransferEngine.keptName("a.txt", taken: taken), "a 3.txt")
        XCTAssertEqual(FileTransferEngine.keptName("Makefile", taken: taken), "Makefile 2")
        XCTAssertEqual(FileTransferEngine.keptName("archive.tar.gz", taken: taken), "archive.tar 2.gz")
        XCTAssertEqual(FileTransferEngine.keptName(".env", taken: taken), ".env 2")
        XCTAssertEqual(FileTransferEngine.keptName("notes.", taken: taken), "notes. 2")
        XCTAssertEqual(FileTransferEngine.keptName("Photos.app", folder: true, taken: taken), "Photos.app 2")
    }

    func testEverythingSkippedSaysNothingToCopy() async throws {
        let (source, target) = hosts()
        source.file("/src/a.txt", "new a")
        target.file("/dst/a.txt", "old a")
        let transfer = engine().copy(items: ["/src/a.txt"], from: source, to: target, directory: "/dst",
                                     in: session(target), kind: .copyIn)
        try await TestSupport.eventually { transfer.resolveConflict != nil }
        transfer.resolveConflict?(.skip)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
        let text = FileTransferText(transfer, host: "homelab")
        XCTAssertEqual(text.title, "Nothing to copy")
        XCTAssertEqual(text.detail, "1 skipped")
        XCTAssertEqual(text.spoken, "Nothing to copy, 1 skipped")
        XCTAssertEqual(target.text("/dst/a.txt"), "old a")
    }

    func testNamesThatAreNotOnePlainNameAreRefused() async throws {
        // A remote listing named an entry "..": the row's path would write into the target's parent.
        let (source, target) = hosts(remote: true)
        source.directory("/src").children[".."] = FakeFilesSource.Node(kind: .file, data: Data("x".utf8),
                                                                       modified: Date(timeIntervalSince1970: 0), inode: 99)
        let listing = try await source.list("/src", hidden: true)
        XCTAssertEqual(listing.entries.map(\.name), [".."])
        for path in ["/src/" + listing.entries[0].name, "/src/a\u{0}b", "/src/.", "/"] {
            let transfer = engine().copy(items: [path], from: source, to: target, directory: "/dst",
                                         in: session(target), kind: .copyIn)
            try await settle(transfer)
            guard case .failed(let message, false) = transfer.stage else { return XCTFail("\(path): \(transfer.stage)") }
            XCTAssertTrue(message.hasSuffix("is not a name a copy can take"), message)
        }
        XCTAssertEqual(target.calls, [], "Refused before anything is listed or written")
        XCTAssertEqual(target.paths(below: "/"), ["dst"])
    }

    // MARK: Cancel and failures

    func testCancelWhileSendingRemovesTheStagingAndDropsTheArchive() async throws {
        let (source, fake) = hosts()
        source.file("/src/tree/data.txt", String(repeating: "x", count: 4_000))
        let target = GatedFilesSource(fake, holding: "unpack.write")
        let engine = engine()
        engine.limits.window = 512
        let transfer = engine.copy(items: ["/src/tree"], from: source, to: target, directory: "/dst",
                                   in: session(target), kind: .copyIn)
        try await TestSupport.eventually { target.held }
        XCTAssertEqual(transfer.stage, .sending)
        XCTAssertTrue(transfer.cancellable)
        XCTAssertTrue(fake.paths(below: "/dst").contains { $0.hasPrefix(".dispatch-copy-") }, "The staging folder is open")
        transfer.cancel?()
        XCTAssertEqual(transfer.stage, .cancelled, "The row says so at once")
        target.release()
        let id = transfer.id.uuidString
        try await TestSupport.eventually { source.calls.contains("pack.drop \(id)") }
        XCTAssertEqual(transfer.stage, .cancelled)
        XCTAssertTrue(fake.calls.contains("unpack.close \(id)"))
        XCTAssertEqual(fake.paths(below: "/dst"), [], "No staging folder and no entries are left")
        XCTAssertNil(source.node("/tmp/dispatch-pack-\(id).tar.zst"))
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("unpack.write") }.count, 1, "Nothing is sent after the cancel")
        XCTAssertEqual(FileTransferText(transfer, host: "homelab").detail, "nothing was written to dst/")
    }

    func testCancelWhilePackingDropsTheArchiveAndOpensNothing() async throws {
        let (fake, target) = hosts()
        fake.file("/src/tree/a.txt", "a")
        let source = GatedFilesSource(fake, holding: "pack")
        let transfer = engine().copy(items: ["/src/tree"], from: source, to: target, directory: "/dst",
                                     in: session(target), kind: .copyIn)
        try await TestSupport.eventually { source.held }
        XCTAssertEqual(transfer.stage, .packing)
        transfer.cancel?()
        source.release()
        let id = transfer.id.uuidString
        try await TestSupport.eventually { fake.calls.contains("pack.drop \(id)") }
        XCTAssertEqual(transfer.stage, .cancelled)
        XCTAssertFalse(target.calls.contains { $0.hasPrefix("unpack") }, "\(target.calls)")
        XCTAssertNil(fake.node("/tmp/dispatch-pack-\(id).tar.zst"))
    }

    func testAChangedArchiveFailsCleanly() async throws {
        let (source, target) = hosts()
        source.file("/src/tree/a.txt", "a")
        source.failures["read"] = .changed("/tmp/dispatch-pack-changed.tar.zst")
        let transfer = engine().copy(items: ["/src/tree"], from: source, to: target, directory: "/dst",
                                     in: session(target), kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .failed(message: "The archive changed while sending", retryable: false))
        XCTAssertNil(transfer.retry)
        let id = transfer.id.uuidString
        XCTAssertTrue(target.calls.contains("unpack.close \(id)"))
        XCTAssertTrue(source.calls.contains("pack.drop \(id)"))
        XCTAssertEqual(target.paths(below: "/dst"), [])
        XCTAssertNil(FileTransferText(transfer, host: "homelab").note)
    }

    func testADroppedConnectionCanBeRetried() async throws {
        let (source, target) = hosts(remote: true)
        source.file("/src/tree/a.txt", "a")
        target.directory("/dst/fixtures")
        target.failures["unpack.write"] = .offline("homelab")
        let session = session(target)
        // The engine owns its runs, as the app's shared one does; a row's Retry reaches the run through it.
        let engine = engine()
        let transfer = engine.copy(items: ["/src/tree"], from: source, to: target, directory: "/dst/fixtures",
                                   in: session, kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .failed(message: "Connection dropped while sending", retryable: true))
        let text = FileTransferText(transfer, host: "homelab")
        XCTAssertEqual(text.title, "Connection dropped while sending")
        XCTAssertEqual(text.note, "Nothing was written to fixtures/")
        XCTAssertEqual(target.paths(below: "/dst/fixtures"), [])
        let retry = try XCTUnwrap(transfer.retry)
        XCTAssertTrue(sleeps.isEmpty, "A failed row stays until acted on")
        target.failures = [:]
        retry()
        XCTAssertEqual(transfer.stage, .preparing)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
        XCTAssertEqual(target.paths(below: "/dst/fixtures"), ["tree", "tree/a.txt"])
        XCTAssertEqual(session.transfers.map(\.id), [transfer.id], "The retry reuses its row")
    }

    func testAFileFailureIsNotRetried() async throws {
        let (source, target) = hosts()
        source.file("/src/a.txt", "a")
        source.failures["read /src/a.txt"] = .permissionDenied("/src/a.txt")
        let transfer = engine().copy(items: ["/src/a.txt"], from: source, to: target, directory: "/dst",
                                     in: session(target), kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .failed(message: "No permission for a.txt. Allow Dispatch in System Settings › Privacy & Security › Files and Folders",
                                               retryable: false), "This Mac's file: macOS may have refused it")
        XCTAssertNil(transfer.retry)
    }

    func testARetryAfterAReconnectGoesThroughTheNewConnection() async throws {
        let (fake, target) = hosts()
        fake.file("/src/tree/a.txt", "a")
        let source = GatedFilesSource(fake, holding: "pack")
        let session = session(target)
        // Kept, as the app's shared engine is: a row's Retry reaches its run through the engine.
        let engine = engine()
        let transfer = engine.copy(items: ["/src/tree"], from: source, to: target, directory: "/dst",
                                   in: session, kind: .copyIn)
        try await TestSupport.eventually { source.held }
        // The tab reconnected: a new connection (a new id) to the same host.
        let again = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        again.directory("/dst")
        session.availability = .available(again)
        source.release()
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .failed(message: "The connection changed", retryable: true))
        XCTAssertTrue(fake.calls.contains("pack.drop \(transfer.id.uuidString)"))
        XCTAssertFalse(target.calls.contains { $0.hasPrefix("unpack") })
        try XCTUnwrap(transfer.retry)()
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
        XCTAssertEqual(again.paths(below: "/dst"), ["tree", "tree/a.txt"])
        XCTAssertEqual(target.paths(below: "/dst"), [])

        // Another host's connection is not the copy's to take.
        let (third, host) = hosts()
        third.file("/src/c.txt", "c")
        host.failures["list"] = .offline("homelab")
        let elsewhere = self.session(host)
        let failed = engine.copy(items: ["/src/c.txt"], from: third, to: host, directory: "/dst", in: elsewhere, kind: .copyIn)
        try await settle(failed)
        elsewhere.availability = .available(FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "nas"))
        try XCTUnwrap(failed.retry)()
        XCTAssertEqual(failed.stage, .failed(message: "homelab is not connected", retryable: true))
    }

    func testAFailureAfterAFileWasWrittenOffersNoRetry() async throws {
        let (source, target) = hosts()
        for name in ["a.txt", "b.txt", "c.txt"] { source.file("/src/\(name)", name) }
        source.failures["read /src/b.txt"] = .offline("build")
        let transfer = engine().copy(items: ["/src/a.txt", "/src/b.txt", "/src/c.txt"], from: source, to: target,
                                     directory: "/dst", in: session(target), kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .failed(message: "Connection dropped while sending", retryable: false),
                       "Starting over would copy a.txt twice")
        XCTAssertNil(transfer.retry)
        XCTAssertEqual(FileTransferText(transfer, host: "homelab").note, "1 item copied to dst/ before")
        XCTAssertEqual(target.paths(below: "/dst"), ["a.txt"])
    }

    func testAnUnansweredWriteMayHaveWritten() async throws {
        let (source, target) = hosts()
        source.file("/src/a.txt", "a")
        target.failures["write"] = .other(code: "uncertain", message: "The remote operation timed out.")
        let transfer = engine().copy(items: ["/src/a.txt"], from: source, to: target, directory: "/dst",
                                     in: session(target), kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .failed(message: "No answer while sending", retryable: false))
        XCTAssertTrue(transfer.uncertain)
        XCTAssertEqual(FileTransferText(transfer, host: "homelab").note, "Some items may have been written to dst/")

        // A refusal is an answer: nothing was written, and Retry stays.
        let (other, busy) = hosts()
        other.file("/src/a.txt", "a")
        busy.failures["write"] = .busy("The helper on homelab is busy with another copy")
        let refused = engine().copy(items: ["/src/a.txt"], from: other, to: busy, directory: "/dst",
                                    in: session(busy), kind: .copyIn)
        try await settle(refused)
        XCTAssertFalse(refused.uncertain)
        XCTAssertNotNil(refused.retry)
        XCTAssertEqual(FileTransferText(refused, host: "homelab").note, "Nothing was written to dst/")
    }

    func testAnUnansweredCommitIsNeverAborted() async throws {
        let (source, target) = hosts()
        source.file("/src/tree/a.txt", "a")
        target.failures["unpack.close"] = .other(code: "uncertain", message: "The remote operation timed out.")
        let transfer = engine().copy(items: ["/src/tree"], from: source, to: target, directory: "/dst",
                                     in: session(target), kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .failed(message: "No answer while unpacking", retryable: false))
        XCTAssertEqual(target.calls.filter { $0.hasPrefix("unpack.close") }.count, 1,
                       "The commit may still be moving entries in: no abort races it")
        XCTAssertEqual(FileTransferText(transfer, host: "homelab").note, "Some items may have been written to dst/")
        XCTAssertTrue(source.calls.contains("pack.drop \(transfer.id.uuidString)"))
    }

    func testARefusedOpenSendsNoAbort() async throws {
        let (source, target) = hosts()
        source.file("/src/tree/a.txt", "a")
        target.failures["unpack.open"] = .permissionDenied("/dst")
        let transfer = engine().copy(items: ["/src/tree"], from: source, to: target, directory: "/dst",
                                     in: session(target), kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .failed(message: "No permission for dst", retryable: false))
        XCTAssertFalse(target.calls.contains { $0.hasPrefix("unpack.close") }, "\(target.calls)")
        XCTAssertTrue(source.calls.contains("pack.drop \(transfer.id.uuidString)"))
    }

    func testABrokenHelperStreamMidWindowCanBeRetried() async throws {
        let (source, target) = hosts()
        source.file("/src/tree/a.txt", "a")
        source.thrown["read"] = HelperWire.Failure.truncated
        let engine = engine()
        let transfer = engine.copy(items: ["/src/tree"], from: source, to: target, directory: "/dst",
                                   in: session(target), kind: .copyIn)
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .failed(message: "Connection dropped while sending", retryable: true))
        XCTAssertEqual(FileTransferText(transfer, host: "homelab").note, "Nothing was written to dst/")
        XCTAssertEqual(target.paths(below: "/dst"), [])
        source.thrown = [:]
        try XCTUnwrap(transfer.retry)()
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
        XCTAssertEqual(target.paths(below: "/dst"), ["tree", "tree/a.txt"])
    }

    func testABusyHelperIsAskedAgainAfterAPause() async throws {
        // The pack a cancel dropped may still be finishing on the helper: the next copy waits it out.
        let (fake, target) = hosts()
        fake.file("/src/tree/a.txt", "a")
        let gated = GatedFilesSource(fake, holding: "pack")
        var pauses: [String] = []
        let engine = engine()
        engine.pause = { _, name in pauses.append(name) }
        let cancelled = engine.copy(items: ["/src/tree"], from: gated, to: target, directory: "/dst",
                                    in: session(target), kind: .copyIn)
        try await TestSupport.eventually { gated.held }
        cancelled.cancel?()
        gated.release()
        try await TestSupport.eventually { fake.calls.contains("pack.drop \(cancelled.id.uuidString)") }
        fake.fail("pack", with: [.busy("busy"), .busy("busy")])
        let next = engine.copy(items: ["/src/tree"], from: fake, to: target, directory: "/dst", in: session(target),
                               kind: .copyIn)
        try await settle(next)
        XCTAssertEqual(next.stage, .done)
        XCTAssertEqual(pauses, ["files.transfer.busy", "files.transfer.busy"])
        XCTAssertEqual(target.paths(below: "/dst"), ["tree", "tree/a.txt"])

        // A helper that stays busy fails the copy as busy, and Retry may try again later.
        engine.limits.busyWaits = [.milliseconds(1)]
        fake.failures["pack"] = .busy("The helper on build is busy with another copy")
        target.directory("/other")
        let stuck = engine.copy(items: ["/src/tree"], from: fake, to: target, directory: "/other", in: session(target),
                                kind: .copyIn)
        try await settle(stuck)
        XCTAssertEqual(stuck.stage, .failed(message: "The helper on build is busy with another copy", retryable: true))
    }

    func testAFileThatGrewPastTheBoundTravelsAsAnArchive() async throws {
        let (fake, target) = hosts()
        fake.file("/src/a.txt", String(repeating: "a", count: 40))
        fake.file("/src/b.txt", String(repeating: "b", count: 40))
        let source = GatedFilesSource(fake, holding: "read")
        let engine = engine()
        engine.limits.bytes = 100
        let transfer = engine.copy(items: ["/src/a.txt", "/src/b.txt"], from: source, to: target, directory: "/dst",
                                   in: session(target), kind: .copyIn)
        try await TestSupport.eventually { source.held }
        fake.file("/src/b.txt", String(repeating: "b", count: 400))
        source.release()
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
        XCTAssertEqual(target.text("/dst/a.txt")?.count, 40)
        XCTAssertEqual(target.text("/dst/b.txt")?.count, 400, "Read whole through the archive, not cut at the bound")
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("pack ") }, ["pack /src"])
        XCTAssertEqual(target.unpackNames, [["b.txt"]])
        XCTAssertEqual(target.calls.filter { $0.hasPrefix("write") }, ["write /dst/a.txt"])
        XCTAssertEqual(transfer.entriesDone, 2)
    }

    func testAnArchiveHoldingAnotherTopLevelNameIsRefused() async throws {
        let (source, target) = hosts(remote: true)
        source.file("/src/tree/a.txt", "a")
        source.planted = ["authorized_keys": "ssh-ed25519 AAAA intruder"]
        let transfer = engine().copy(items: ["/src/tree"], from: source, to: target, directory: "/dst",
                                     in: session(target), kind: .copyIn)
        try await settle(transfer)
        guard case .failed(_, false) = transfer.stage else { return XCTFail("\(transfer.stage)") }
        XCTAssertEqual(target.unpackNames, [["tree"]])
        XCTAssertEqual(target.paths(below: "/dst"), [], "Nothing moved in, and the staging folder is gone")
    }

    func testUnpackingShowsForTheWholeCommitAndCannotBeCancelled() async throws {
        let (source, fake) = hosts()
        source.file("/src/tree/a.txt", "a")
        let target = GatedFilesSource(fake, holding: "unpack.close")
        let transfer = engine().copy(items: ["/src/tree"], from: source, to: target, directory: "/dst",
                                     in: session(target), kind: .copyIn)
        try await TestSupport.eventually { target.held }
        XCTAssertEqual(transfer.stage, .unpacking)
        XCTAssertTrue(transfer.isActive)
        XCTAssertFalse(transfer.cancellable)
        XCTAssertEqual(FileTransferText(transfer, host: "homelab").title, "Unpacking on homelab")
        XCTAssertEqual(FileTransferText(transfer, host: "homelab").detail, "2 items")
        transfer.cancel?()
        XCTAssertEqual(transfer.stage, .unpacking, "Cancel is gone while entries move in")
        target.release()
        try await settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
    }

    func testRowsOfClosedTabsAreLetGo() async throws {
        let (source, target) = hosts()
        source.file("/src/a.txt", "a")
        target.file("/dst/a.txt", "old")
        let engine = engine()
        let asking = session(target)
        let asked = engine.copy(items: ["/src/a.txt"], from: source, to: target, directory: "/dst", in: asking,
                                kind: .copyIn)
        try await TestSupport.eventually { asked.resolveConflict != nil }
        let failing = session(target)
        target.failures["write"] = .permissionDenied("/dst/b.txt")
        source.file("/src/b.txt", "b")
        let failed = engine.copy(items: ["/src/b.txt"], from: source, to: target, directory: "/dst", in: failing,
                                 kind: .copyIn)
        try await settle(failed)
        XCTAssertEqual(engine.runCount, 2)
        coordinator.forget(asking.id)
        try await TestSupport.eventually { asked.stage == .cancelled && engine.runCount == 1 }
        XCTAssertTrue(asking.transfers.isEmpty)
        coordinator.forget(failing.id)
        try await TestSupport.eventually { engine.runCount == 0 }
        XCTAssertEqual(target.text("/dst/a.txt"), "old")
    }

    // MARK: Rows

    func testRemoteToRemoteShowsTwoRows() async throws {
        let (source, target) = hosts(remote: true)
        source.file("/src/a.txt", "a")
        source.file("/src/tree/b.txt", "b")
        let origin = session(source), destination = session(target)
        let transfer = engine().copy(items: ["/src/a.txt", "/src/tree"], from: source, to: target, directory: "/dst",
                                     in: origin, kind: .copyOut, relay: destination)
        XCTAssertEqual(origin.transfers.map(\.kind), [.copyOut])
        XCTAssertEqual(destination.transfers.map(\.kind), [.relay])
        try await settle(transfer)
        let relay = try XCTUnwrap(destination.transfers.first)
        XCTAssertEqual(transfer.stage, .done)
        XCTAssertEqual(relay.stage, .done)
        XCTAssertEqual(relay.entriesDone, transfer.entriesDone)
        XCTAssertEqual(target.paths(below: "/dst"), ["a.txt", "tree", "tree/b.txt"])
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("pack ") }.count, 1, "One run feeds both rows")
    }

    func testFinishedRowsLeaveAfterFourSeconds() async throws {
        let (source, target) = hosts()
        source.file("/src/a.txt", "a")
        let session = session(target)
        let engine = engine()
        engine.sleep = { [unowned self] duration, name in sleeps.append((duration, name)) }
        let transfer = engine.copy(items: ["/src/a.txt"], from: source, to: target, directory: "/dst", in: session,
                                   kind: .copyIn)
        try await TestSupport.eventually { session.transfers.isEmpty }
        XCTAssertEqual(transfer.stage, .done)
        XCTAssertEqual(sleeps.map(\.name), ["files.transfer.dismiss"])
        XCTAssertEqual(sleeps.first?.duration, .seconds(4))
    }

    func testCancelledRowsLeaveAndFailedRowsStay() async throws {
        let (source, target) = hosts()
        source.file("/src/a.txt", "a")
        target.failures["write"] = .permissionDenied("/dst/a.txt")
        let session = session(target)
        let engine = engine()
        engine.sleep = { [unowned self] duration, name in sleeps.append((duration, name)) }
        let failed = engine.copy(items: ["/src/a.txt"], from: source, to: target, directory: "/dst", in: session,
                                 kind: .copyIn)
        try await settle(failed)
        target.file("/dst/a.txt", "old")
        target.failures = [:]
        let asked = engine.copy(items: ["/src/a.txt"], from: source, to: target, directory: "/dst", in: session,
                                kind: .copyIn)
        try await TestSupport.eventually { asked.resolveConflict != nil }
        asked.resolveConflict?(.cancel)
        try await TestSupport.eventually { session.transfers.map(\.id) == [failed.id] }
        XCTAssertEqual(sleeps.map(\.name), ["files.transfer.dismiss"], "Only the cancelled row was dismissed")
        failed.cancel?()
        XCTAssertTrue(session.transfers.isEmpty, "✕ dismisses a failed row")
    }

    func testRowTextPerState() {
        let transfer = FileTransfer(kind: .copyIn, items: 5_120, targetPath: "/home/ivan/nightly/fixtures",
                                    targetLabel: "fixtures/", startedAt: Date(timeIntervalSince1970: 100))
        func text() -> FileTransferText { FileTransferText(transfer, host: "homelab") }
        XCTAssertEqual(text().title + (text().emphasis ?? ""), "Copying 5,120 items to fixtures/")
        transfer.stage = .packing
        XCTAssertEqual(text().detail, "packing…")
        XCTAssertTrue(text().separated)
        transfer.stage = .sending
        transfer.bytesTotal = 48_000_000
        transfer.bytesDone = 31_000_000
        transfer.rate = 12_000_000
        XCTAssertEqual(text().title, "Sending")
        XCTAssertEqual(text().detail, "31 of 48 MB · 12 MB/s")
        transfer.entries = 5_120
        transfer.stage = .unpacking
        XCTAssertEqual(text().title, "Unpacking on homelab")
        XCTAssertEqual(text().detail, "5,120 items")
        transfer.stage = .done
        transfer.entriesDone = 5_120
        transfer.finishedAt = Date(timeIntervalSince1970: 106.2)
        XCTAssertEqual(text().title, "5,120 items copied")
        XCTAssertEqual(text().detail, "48 MB · 6.2 s")
        transfer.stage = .conflict(existing: (1...12).map { "f\($0)" })
        XCTAssertEqual(text().title, "fixtures/ already has 12 of these")
        transfer.entriesDone = 0
        transfer.stage = .failed(message: "Connection dropped while sending", retryable: true)
        XCTAssertEqual(text().note, "Nothing was written to fixtures/")
        transfer.stage = .cancelled
        XCTAssertEqual(text().detail, "nothing was written to fixtures/")
        transfer.uncertain = true
        XCTAssertEqual(text().detail, "some items may have been written to fixtures/")
        transfer.stage = .failed(message: "No answer while unpacking", retryable: false)
        XCTAssertEqual(text().note, "Some items may have been written to fixtures/")
        transfer.uncertain = false
        transfer.entriesDone = 3
        XCTAssertEqual(text().note, "3 items copied to fixtures/ before")
        transfer.stage = .done
        transfer.skipped = 2
        XCTAssertEqual(text().detail, "48 MB · 6.2 s · 2 skipped")
        let out = FileTransfer(kind: .copyOut, items: 2, targetPath: "/tmp/x", targetLabel: "Downloads")
        out.stage = .unpacking
        XCTAssertEqual(FileTransferText(out, host: "this Mac").title, "Unpacking into Downloads")
    }

    func testFormatting() {
        XCTAssertEqual(FileTransferFormatting.progress(31_000_000, of: 48_000_000), "31 of 48 MB")
        XCTAssertEqual(FileTransferFormatting.progress(5_700_000, of: 11_800_000), "5.7 of 11.8 MB")
        XCTAssertEqual(FileTransferFormatting.progress(900, of: 2_400_000), "0 of 2.4 MB")
        XCTAssertEqual(FileTransferFormatting.rate(12_000_000), "12 MB/s")
        XCTAssertEqual(FileTransferFormatting.rate(812), "812 B/s")
        XCTAssertEqual(FileTransferFormatting.bytes(812), "812 B")
        XCTAssertEqual(FileTransferFormatting.bytes(4_100), "4.1 KB")
        XCTAssertEqual(FileTransferFormatting.bytes(188_000), "188 KB")
        XCTAssertEqual(FileTransferFormatting.bytes(1_500_000_000), "1.5 GB")
        XCTAssertEqual(FileTransferFormatting.duration(6.2), "6.2 s")
        XCTAssertEqual(FileTransferFormatting.duration(42.4), "42 s")
        XCTAssertEqual(FileTransferFormatting.duration(192), "3 min 12 s")
        XCTAssertEqual(FileTransferFormatting.count(5_120), "5,120")
        XCTAssertEqual(FileTransferFormatting.count(1_234_567), "1,234,567")
        XCTAssertEqual(FileTransferFormatting.items(1), "1 item")
        XCTAssertEqual(FileTransferFormatting.folderLabel("/home/ivan/nightly/fixtures"), "fixtures/")
        XCTAssertEqual(FileTransferFormatting.folderLabel("/"), "/")
    }

    // MARK: Support

    private func hosts(remote: Bool = false) -> (FakeFilesSource, FakeFilesSource) {
        let source = FakeFilesSource(endpoint: remote ? .remote(SSHConnectionID()) : .local)
        let target = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        source.directory("/src")
        target.directory("/dst")
        return (source, target)
    }

    private func session(_ source: any FilesSource) -> FilesSession {
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(source)
        return session
    }

    /// Dismissals are recorded and never wake, so rows stay to be checked unless a test lets them go.
    private func engine(asks: Bool = true) -> FileTransferEngine {
        let engine = FileTransferEngine(coordinator: { [unowned self] in coordinator }, asksBeforeReplacing: { asks })
        engine.sleep = { [unowned self] duration, name in
            sleeps.append((duration, name))
            throw CancellationError()
        }
        return engine
    }

    private func settle(_ transfer: FileTransfer, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await TestSupport.eventually(file: file, line: line, diagnostic: "Transfer still \(transfer.stage)") {
            switch transfer.stage {
            case .done, .failed, .cancelled: true
            default: false
            }
        }
    }
}

/// Forwards to a fake host and holds one method's next call until the test releases it: a copy caught mid-stage
/// without sleeping.
final class GatedFilesSource: FilesSource, @unchecked Sendable {
    let inner: FakeFilesSource
    private let method: String
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    private var arrived = false

    init(_ inner: FakeFilesSource, holding method: String) {
        self.inner = inner
        self.method = method
    }

    /// The held call arrived and waits.
    var held: Bool { lock.withLock { arrived && !released } }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }

    private func gate(_ name: String) async {
        guard name == method else { return }
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if released || arrived { return true }
                arrived = true
                waiting = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    var endpoint: FilesEndpoint { inner.endpoint }
    var home: String? { inner.home }
    var hostLabel: String? { inner.hostLabel }

    func list(_ path: String, hidden: Bool) async throws -> FileListing {
        await gate("list")
        return try await inner.list(path, hidden: hidden)
    }

    func summary(_ path: String) async throws -> FolderSummary {
        await gate("summary")
        return try await inner.summary(path)
    }

    func read(_ path: String, offset: UInt64, length: UInt64?, revision: FileRevision?) async throws
        -> (data: Data, revision: FileRevision) {
        await gate("read")
        return try await inner.read(path, offset: offset, length: length, revision: revision)
    }

    func write(_ path: String, data: Data, mode: UInt32?, replace: Bool) async throws -> FileRevision {
        await gate("write")
        return try await inner.write(path, data: data, mode: mode, replace: replace)
    }

    func pack(transfer: String, base: String, paths: [String]) async throws -> PackedArchive {
        await gate("pack")
        return try await inner.pack(transfer: transfer, base: base, paths: paths)
    }

    func dropArchive(transfer: String) async throws {
        await gate("pack.drop")
        try await inner.dropArchive(transfer: transfer)
    }

    func openUnpack(transfer: String, target: String, policy: ConflictPolicy, names: [String]) async throws -> UnpackTransfer {
        await gate("unpack.open")
        return try await inner.openUnpack(transfer: transfer, target: target, policy: policy, names: names)
    }
    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput {
        try await inner.git(path, args: args, limit: limit)
    }

    func writeUnpack(transfer: String, data: Data) async throws -> UInt64 {
        await gate("unpack.write")
        return try await inner.writeUnpack(transfer: transfer, data: data)
    }

    func closeUnpack(transfer: String, commit: Bool) async throws -> UnpackResult {
        await gate("unpack.close")
        return try await inner.closeUnpack(transfer: transfer, commit: commit)
    }
}
