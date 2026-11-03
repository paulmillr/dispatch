import Foundation
import XCTest
@testable import DispatchApp

/// Copies whose names differ only in case, into a target that folds case (a default APFS volume) and one that does
/// not (Linux): what is asked, what Replace, Keep Both, Skip and Cancel leave, and that the few-and-small path and
/// the archive path leave the same. The matrix runs against in-memory hosts here, this Mac's helper in
/// `FileTransferCaseEndToEndTests`, and a Linux host's helper over SSH in `SSHLinuxFileTransferTests`.
@MainActor
final class FileTransferCaseTests: XCTestCase {
    func testCaseVariantsAgreeOnBothPathsWhereTheTargetTellsThemApart() async throws {
        for resolution in TransferCaseMatrix.resolutions {
            for archive in [false, true] {
                let (source, target) = Self.hosts(folds: false, existing: TransferCaseMatrix.existing,
                                                  dragged: TransferCaseMatrix.dragged)
                try await TransferCaseMatrix.run(resolution, archive: archive, folds: false, from: source, to: target,
                                                 sources: "/src", directory: "/dst")
                // One probe asked the target whether readme.md finds README.md: it does not.
                XCTAssertTrue(target.calls.contains("list /dst/readme.md"), "\(target.calls)")
                // The probe looks the file up without opening it: the only read of it is the check of what arrived.
                let planning = target.calls.prefix { !$0.hasPrefix("write") && !$0.hasPrefix("unpack") }
                XCTAssertFalse(planning.contains("read /dst/readme.md"), "\(target.calls)")
            }
        }
    }

    func testCaseVariantsAgreeOnBothPathsWhereTheTargetFoldsThem() async throws {
        for resolution in TransferCaseMatrix.resolutions {
            for archive in [false, true] {
                let (source, target) = Self.hosts(folds: true, existing: TransferCaseMatrix.existing,
                                                  dragged: TransferCaseMatrix.dragged)
                try await TransferCaseMatrix.run(resolution, archive: archive, folds: true, from: source, to: target,
                                                 sources: "/src", directory: "/dst")
            }
        }
    }

    func testReplacingACaseVariantLeavesTheDraggedSpelling() async throws {
        for folds in [false, true] {
            for archive in [false, true] {
                let (source, target) = Self.hosts(folds: folds, existing: [("README.md", "old README")],
                                                  dragged: [("readme.md", "new readme")])
                try await TransferCaseMatrix.respell(archive: archive, folds: folds, from: source, to: target,
                                                     sources: "/src", directory: "/dst")
            }
        }
    }

    func testNamesWithoutVariantsAskTheTargetNothingMore() async throws {
        let (source, target) = Self.hosts(folds: false)
        source.file("/src/a.txt", "new a")
        target.file("/dst/a.txt", "old a")
        let coordinator = FilesCoordinator { nil }
        let transfer = TransferCaseMatrix.engine(coordinator).copy(items: ["/src/a.txt"], from: source, to: target,
                                                                   directory: "/dst", in: TransferCaseMatrix.session(coordinator, target),
                                                                   kind: .copyIn)
        try await TestSupport.eventually { transfer.stage == .conflict(existing: ["a.txt"]) }
        XCTAssertEqual(target.calls, ["list /dst"], "No probe: nothing in the copy depends on the target's rule")
        transfer.resolveConflict?(.cancel)
        try await TransferCaseMatrix.settle(transfer)
    }

    func testAListingHoldingTwoVariantsProvesAnExactTarget() async throws {
        let (source, target) = Self.hosts(folds: false)
        source.file("/src/readme.md", "new readme")
        target.file("/dst/README.md", "old README")
        target.file("/dst/Readme.md", "old Readme")
        let coordinator = FilesCoordinator { nil }
        let transfer = TransferCaseMatrix.engine(coordinator).copy(items: ["/src/readme.md"], from: source, to: target,
                                                                   directory: "/dst", in: TransferCaseMatrix.session(coordinator, target),
                                                                   kind: .copyIn)
        try await TransferCaseMatrix.settle(transfer)
        XCTAssertEqual(transfer.stage, .done)
        XCTAssertFalse(target.calls.contains { $0.hasPrefix("read ") }, "No probe needed: \(target.calls)")
        XCTAssertEqual(target.paths(below: "/dst"), ["README.md", "Readme.md", "readme.md"])
    }

    func testCaseVariantsOnlyAmongTheDraggedItemsProbeTheTarget() async throws {
        // Nothing listed is alike: the probe flips a listed entry's case, then the folder's own name.
        for (folds, listed) in [(false, true), (true, true), (false, false), (true, false)] {
            let (source, target) = Self.hosts(folds: folds)
            source.file("/src/one/Guide.md", "one Guide")
            source.file("/src/two/guide.md", "two guide")
            if listed { target.file("/dst/notes.txt", "old notes") }
            let coordinator = FilesCoordinator { nil }
            let transfer = TransferCaseMatrix.engine(coordinator).copy(
                items: ["/src/one/Guide.md", "/src/two/guide.md"], from: source, to: target, directory: "/dst",
                in: TransferCaseMatrix.session(coordinator, target), kind: .copyIn)
            try await TransferCaseMatrix.settle(transfer)
            XCTAssertEqual(transfer.stage, .done)
            XCTAssertTrue(target.calls.contains(listed ? "list /dst/NOTES.TXT" : "list /DST"), "\(target.calls)")
            let expected = folds ? ["Guide.md": "one Guide", "guide 2.md": "two guide"] : ["Guide.md": "one Guide", "guide.md": "two guide"]
            let contents = try await TransferCaseMatrix.contents(target, "/dst").filter { $0.key != "notes.txt" }
            XCTAssertEqual(contents, expected, "folds \(folds), listed \(listed)")
        }
    }

    /// A source holding `dragged` below /src and a target holding `existing` in /dst.
    private static func hosts(folds: Bool, existing: [(String, String)] = [], dragged: [(String, String)] = [])
        -> (FakeFilesSource, FakeFilesSource) {
        let source = FakeFilesSource(endpoint: .local)
        let target = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        target.foldsCase = folds
        source.directory("/src")
        target.directory("/dst")
        for (path, text) in dragged { source.file("/src/" + path, text) }
        for (path, text) in existing { target.file("/dst/" + path, text) }
        return (source, target)
    }
}

/// The case matrix against this Mac's helper, in a folder on the test's temporary volume (APFS, case folded).
@MainActor
final class FileTransferCaseEndToEndTests: XCTestCase {
    private var session: HelperSession!
    private var root: URL!
    private var source: HelperFilesSource!

    override func setUp() async throws {
        let process = Process()
        process.executableURL = try XCTUnwrap(HelperApp.executable)
        process.arguments = ["--stdio"]
        process.standardError = FileHandle.nullDevice
        session = try await HelperSession(process: process)
        addTeardownBlock { [session] in session?.close() }
        root = URL(fileURLWithPath: try XCTUnwrap(System.environment("TMPDIR")))
            .appendingPathComponent("c" + System.uuid().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        source = HelperFilesSource(endpoint: .local, connection: session.connection, home: root.path, hostLabel: nil)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Whether the volume holding the test's folder folds case; observed, so a replay answers what the capture saw.
    private func folds() throws -> Bool {
        try System.observe("volume.case-sensitive", root.path) {
            try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false
        }
    }

    /// A fresh source tree and target folder for one run.
    private func prepare(_ name: String, existing: [(String, String)], dragged: [(String, String)]) throws -> (String, String) {
        let base = root.appendingPathComponent(name)
        for (path, text) in dragged {
            let url = base.appendingPathComponent("src/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try System.write(Data(text.utf8), to: url)
        }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("dst"), withIntermediateDirectories: true)
        for (path, text) in existing { try System.write(Data(text.utf8), to: base.appendingPathComponent("dst/" + path)) }
        return (base.appendingPathComponent("src").path, base.appendingPathComponent("dst").path)
    }

    func testCaseVariantsAgreeOnBothPathsOnThisMac() async throws {
        let folds = try folds()
        for resolution in TransferCaseMatrix.resolutions {
            for archive in [false, true] {
                let (sources, directory) = try prepare("\(resolution)-\(archive)", existing: TransferCaseMatrix.existing,
                                                       dragged: TransferCaseMatrix.dragged)
                try await TransferCaseMatrix.run(resolution, archive: archive, folds: folds, from: source, to: source,
                                                 sources: sources, directory: directory)
            }
        }
        for archive in [false, true] {
            let (sources, directory) = try prepare("respell-\(archive)", existing: [("README.md", "old README")],
                                                   dragged: [("readme.md", "new readme")])
            try await TransferCaseMatrix.respell(archive: archive, folds: folds, from: source, to: source,
                                                 sources: sources, directory: directory)
        }
    }
}

/// The matrix the three classes share: one batch, its expected outcome per resolution and target rule.
@MainActor
enum TransferCaseMatrix {
    static let resolutions: [FileTransfer.ConflictResolution] = [.replace, .keepBoth, .skip, .cancel]
    /// An exact conflict and its case variant, a new name and its case variant, from two folders (a folding source
    /// cannot hold a name and its variant side by side).
    static let dragged = [("one/README.md", "one README"), ("two/readme.md", "two readme"),
                          ("one/Guide.md", "one Guide"), ("two/guide.md", "two guide")]
    static let existing = [("README.md", "old README"), ("notes.txt", "old notes")]

    /// What the target holds after the copy, by name.
    static func expected(_ resolution: FileTransfer.ConflictResolution, folds: Bool) -> [String: String] {
        let before = Dictionary(uniqueKeysWithValues: existing)
        switch (resolution, folds) {
        case (.cancel, _): return before
        // Linux: readme.md and guide.md are free names; only README.md conflicts.
        case (.replace, false):
            return before.merging(["README.md": "one README", "readme.md": "two readme", "Guide.md": "one Guide",
                                   "guide.md": "two guide"]) { $1 }
        case (.keepBoth, false):
            return before.merging(["README 2.md": "one README", "readme.md": "two readme", "Guide.md": "one Guide",
                                   "guide.md": "two guide"]) { $1 }
        case (.skip, false):
            return before.merging(["readme.md": "two readme", "Guide.md": "one Guide", "guide.md": "two guide"]) { $1 }
        // A folding volume: readme.md is README.md, guide.md is Guide.md; the later of each pair keeps both.
        case (.replace, true):
            return before.merging(["README.md": "one README", "readme 2.md": "two readme", "Guide.md": "one Guide",
                                   "guide 2.md": "two guide"]) { $1 }
        case (.keepBoth, true):
            return before.merging(["README 2.md": "one README", "readme 3.md": "two readme", "Guide.md": "one Guide",
                                   "guide 2.md": "two guide"]) { $1 }
        case (.skip, true):
            return before.merging(["Guide.md": "one Guide", "guide 2.md": "two guide"]) { $1 }
        }
    }

    /// Copies the batch from `sources` into `directory` under `resolution`, on the archive path or the few-and-small
    /// one, and checks the prompt, the row and what the target holds.
    static func run(_ resolution: FileTransfer.ConflictResolution, archive: Bool, folds: Bool,
                    from source: any FilesSource, to target: any FilesSource, sources: String, directory: String,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let label = "\(resolution), \(archive ? "archive" : "files"), \(folds ? "folding" : "exact") target"
        let coordinator = FilesCoordinator { nil }
        let engine = engine(coordinator)
        if archive { engine.limits.files = 0 }
        let transfer = engine.copy(items: dragged.map { sources + "/" + $0.0 }, from: source, to: target,
                                   directory: directory, in: session(coordinator, target), kind: .copyIn)
        try await TestSupport.eventually(timeout: .seconds(20), file: file, line: line, diagnostic: "\(label): \(transfer.stage)") {
            transfer.resolveConflict != nil
        }
        XCTAssertEqual(transfer.stage, .conflict(existing: ["README.md"]), label, file: file, line: line)
        transfer.resolveConflict?(resolution)
        try await settle(transfer, file: file, line: line)
        XCTAssertEqual(transfer.stage, resolution == .cancel ? .cancelled : .done, label, file: file, line: line)
        if resolution != .cancel {
            XCTAssertEqual(transfer.archived, archive, label, file: file, line: line)
            XCTAssertEqual(transfer.skipped, resolution == .skip ? (folds ? 2 : 1) : 0, label, file: file, line: line)
        }
        let contents = try await contents(target, directory)
        XCTAssertEqual(contents, expected(resolution, folds: folds), label, file: file, line: line)
    }

    /// readme.md dragged onto README.md. A folding target asks and, under Replace, leaves only readme.md (Finder's
    /// result) on either path; an exact one asks nothing and keeps both names.
    static func respell(archive: Bool, folds: Bool, from source: any FilesSource, to target: any FilesSource,
                        sources: String, directory: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let label = "\(archive ? "archive" : "files"), \(folds ? "folding" : "exact") target"
        let coordinator = FilesCoordinator { nil }
        let engine = engine(coordinator)
        if archive { engine.limits.files = 0 }
        let transfer = engine.copy(items: [sources + "/readme.md"], from: source, to: target, directory: directory,
                                   in: session(coordinator, target), kind: .copyIn)
        if folds {
            try await TestSupport.eventually(timeout: .seconds(20), file: file, line: line, diagnostic: "\(label): \(transfer.stage)") {
                transfer.resolveConflict != nil
            }
            XCTAssertEqual(transfer.stage, .conflict(existing: ["readme.md"]), label, file: file, line: line)
            transfer.resolveConflict?(.replace)
        }
        try await settle(transfer, file: file, line: line)
        XCTAssertEqual(transfer.stage, .done, label, file: file, line: line)
        XCTAssertTrue(transfer.archived || !folds, "A respelling Replace takes the archive path: \(label)", file: file, line: line)
        let contents = try await contents(target, directory)
        XCTAssertEqual(contents, folds ? ["readme.md": "new readme"] : ["README.md": "old README", "readme.md": "new readme"],
                       label, file: file, line: line)
    }

    /// Every name in the folder (hidden ones too, so leftovers show) and a file's text; a folder reads as "/".
    static func contents(_ source: any FilesSource, _ directory: String) async throws -> [String: String] {
        var out: [String: String] = [:]
        for entry in try await source.list(directory, hidden: true).entries {
            guard entry.kind == .file else {
                out[entry.name] = "/"
                continue
            }
            let data = try await source.read(directory + "/" + entry.name, offset: 0, length: nil, revision: nil).data
            out[entry.name] = String(decoding: data, as: UTF8.self)
        }
        return out
    }

    /// An engine that asks, and whose dismissals never wake: the rows stay to be checked.
    static func engine(_ coordinator: FilesCoordinator) -> FileTransferEngine {
        let engine = FileTransferEngine(coordinator: { coordinator }, asksBeforeReplacing: { true })
        engine.sleep = { _, _ in throw CancellationError() }
        return engine
    }

    static func session(_ coordinator: FilesCoordinator, _ source: any FilesSource) -> FilesSession {
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(source)
        return session
    }

    static func settle(_ transfer: FileTransfer, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await TestSupport.eventually(timeout: .seconds(30), file: file, line: line, diagnostic: "Transfer still \(transfer.stage)") {
            switch transfer.stage {
            case .done, .failed, .cancelled: true
            default: false
            }
        }
    }
}

/// The case matrix from this Mac into a Linux host's folder over SSH: a target that tells case variants apart.
/// Configure the host with `python3 test/vm.py linux` (see SSHLinuxIntegrationTests).
@MainActor
final class SSHLinuxFileTransferTests: XCTestCase {
    func testCaseVariantsAgreeOnBothPathsOnALinuxHost() async throws {
        let profile = try SSHLinuxTestProfile.load()
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        @discardableResult
        func remote(_ arguments: [String]) async throws -> String {
            let result = try await SSHCommand.run(executable: "/usr/bin/ssh", arguments:
                profile.options + [profile.destination, arguments.map(HerdrLaunch.quote).joined(separator: " ")])
            guard result.status == 0 else { throw HerdrFailure(String(decoding: result.output, as: UTF8.self)) }
            return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let root = try await remote(["mktemp", "-d", "/tmp/dispatch-case-XXXXXXXX"])
        do {
            try await matrix(app: app, profile: profile, root: root, remote: remote)
        } catch {
            _ = try? await remote(["rm", "-rf", "--", root])
            throw error
        }
        _ = try await remote(["rm", "-rf", "--", root])
    }

    private func matrix(app: TmuxWalkthrough, profile: SSHLinuxTestProfile, root: String,
                        remote: ([String]) async throws -> String) async throws {
        let local = System.temporary.appendingPathComponent("lc-" + System.uuid().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: local) }
        let process = Process()
        process.executableURL = try XCTUnwrap(HelperApp.executable)
        process.arguments = ["--stdio"]
        process.standardError = FileHandle.nullDevice
        let helper = try await HelperSession(process: process)
        addTeardownBlock { helper.close() }
        let source = HelperFilesSource(endpoint: .local, connection: helper.connection, home: local.path, hostLabel: nil)

        let tab = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[tab].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(app.runtime.views[tab])
        try await SSHTestServer.authorize(arguments: profile.options + [profile.destination], grant: .init(profile: .full))
        TerminalTestSupport.send("ssh " + (profile.options + [profile.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(25), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == tab && $0.shellPID != nil }
        }
        let (id, link) = try XCTUnwrap(app.runtime.ssh.links.first { $0.value.launch.tabID == tab })
        let system = try await remote(["uname", "-s"])
        XCTAssertEqual(system, "Linux")
        let target = HelperFilesSource(endpoint: .remote(id), home: link.greeting.home, hostLabel: "linux")

        /// A fresh source tree on this Mac and target folder on the host for one run.
        func prepare(_ name: String, existing: [(String, String)], dragged: [(String, String)]) async throws -> (String, String) {
            let base = local.appendingPathComponent(name)
            for (path, text) in dragged {
                let url = base.appendingPathComponent("src/" + path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try System.write(Data(text.utf8), to: url)
            }
            let directory = root + "/" + name
            var script = "mkdir -p " + HerdrLaunch.quote(directory)
            for (path, text) in existing {
                script += " && printf %s " + HerdrLaunch.quote(text) + " > " + HerdrLaunch.quote(directory + "/" + path)
            }
            _ = try await remote(["/bin/sh", "-c", script])
            return (base.appendingPathComponent("src").path, directory)
        }
        for resolution in TransferCaseMatrix.resolutions {
            for archive in [false, true] {
                let (sources, directory) = try await prepare("\(resolution)-\(archive)", existing: TransferCaseMatrix.existing,
                                                             dragged: TransferCaseMatrix.dragged)
                try await TransferCaseMatrix.run(resolution, archive: archive, folds: false, from: source, to: target,
                                                 sources: sources, directory: directory)
            }
        }
        for archive in [false, true] {
            let (sources, directory) = try await prepare("respell-\(archive)", existing: [("README.md", "old README")],
                                                         dragged: [("readme.md", "new readme")])
            try await TransferCaseMatrix.respell(archive: archive, folds: false, from: source, to: target,
                                                 sources: sources, directory: directory)
        }
    }
}

/// Case and normalization are separate rules: one never settles the other, and a probe that cannot answer passes on.
extension FileTransferCaseTests {
    private static let composed = "Caf\u{E9}.txt", decomposed = "cafe\u{301}.txt"

    private static func fake(case folds: Bool, normalization: Bool) -> (FakeFilesSource, FakeFilesSource) {
        let source = FakeFilesSource(endpoint: .local)
        let target = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        target.foldsCase = folds
        target.foldsNormalization = normalization
        source.directory("/src")
        target.directory("/dst")
        return (source, target)
    }

    private func copy(_ items: [String], from source: FakeFilesSource, to target: FakeFilesSource,
                      archive: Bool = false) -> FileTransfer {
        let coordinator = FilesCoordinator { nil }
        let engine = TransferCaseMatrix.engine(coordinator)
        if archive { engine.limits.files = 0 }
        return engine.copy(items: items, from: source, to: target, directory: "/dst",
                           in: TransferCaseMatrix.session(coordinator, target), kind: .copyIn)
    }

    /// Case-sensitive APFS folds normalization only: an NFC name beside a listed NFD one says nothing about case, and
    /// Guide.md and guide.md stay two names on both paths.
    func testNormalizationEvidenceNeverSettlesCase() async throws {
        for archive in [false, true] {
            let (source, target) = Self.fake(case: false, normalization: true)
            source.file("/src/one/" + Self.composed, "new cafe")
            source.file("/src/one/Guide.md", "one Guide")
            source.file("/src/two/guide.md", "two guide")
            target.file("/dst/" + Self.decomposed, "old cafe")
            let transfer = copy(["/src/one/" + Self.composed, "/src/one/Guide.md", "/src/two/guide.md"],
                                from: source, to: target, archive: archive)
            try await TransferCaseMatrix.settle(transfer)
            XCTAssertEqual(transfer.stage, .done, "No conflict was asked: \(transfer.stage)")
            let contents = try await TransferCaseMatrix.contents(target, "/dst")
            XCTAssertEqual(contents.count, 4, "\(contents.keys.map { Array($0.unicodeScalars) })")
            XCTAssertEqual(contents["Guide.md"], "one Guide")
            XCTAssertEqual(contents["guide.md"], "two guide")
            XCTAssertNil(contents["guide 2.md"], "archive \(archive)")
            XCTAssertTrue(target.calls.contains("list /dst/CAFE\u{301}.TXT"), "Case was probed by case alone: \(target.calls)")
        }
    }

    /// SMB, NTFS and exFAT fold case only: a listing holding NFC and NFD forms of one name still lets case be probed,
    /// and README.md is asked about.
    func testTwoNormalizationsInTheListingLeaveCaseOpen() async throws {
        let (source, target) = Self.fake(case: true, normalization: false)
        source.file("/src/readme.md", "new readme")
        target.file("/dst/README.md", "old README")
        target.file("/dst/\u{E9}.txt", "composed")
        target.file("/dst/e\u{301}.txt", "decomposed")
        let transfer = copy(["/src/readme.md"], from: source, to: target)
        try await TestSupport.eventually { transfer.stage == .conflict(existing: ["readme.md"]) }
        transfer.resolveConflict?(.cancel)
        try await TransferCaseMatrix.settle(transfer)
    }

    /// Byte for byte (Linux): an NFC name beside a listed NFD one is a second file, on both paths.
    func testNormalizationsAreTwoNamesWhereTheTargetKeepsBytes() async throws {
        for archive in [false, true] {
            let (source, target) = Self.fake(case: false, normalization: false)
            source.file("/src/" + Self.composed, "new cafe")
            target.file("/dst/" + Self.composed.decomposedStringWithCanonicalMapping, "old cafe")
            let transfer = copy(["/src/" + Self.composed], from: source, to: target, archive: archive)
            try await TransferCaseMatrix.settle(transfer)
            XCTAssertEqual(transfer.stage, .done)
            // Read entry by entry: Swift's string keys would take the two names for one.
            var texts: [String] = []
            for entry in try await target.list("/dst", hidden: true).entries {
                texts.append(String(decoding: try await target.read("/dst/" + entry.name, offset: 0, length: nil, revision: nil).data,
                                    as: UTF8.self))
            }
            XCTAssertEqual(texts.sorted(), ["new cafe", "old cafe"], "archive \(archive)")
        }
    }

    /// A probe the target refuses (no permission) passes to the next one.
    func testARefusedProbeTriesTheNextOne() async throws {
        let (source, target) = Self.fake(case: true, normalization: true)
        source.file("/src/readme.md", "new readme")
        target.file("/dst/README.md", "old README")
        target.fail("list /dst/readme.md", with: [.permissionDenied("/dst/readme.md")])
        let transfer = copy(["/src/readme.md"], from: source, to: target)
        try await TestSupport.eventually { transfer.stage == .conflict(existing: ["readme.md"]) }
        XCTAssertEqual(Array(target.calls.prefix(3)), ["list /dst", "list /dst/readme.md", "list /dst/readme.MD"])
        transfer.resolveConflict?(.cancel)
        try await TransferCaseMatrix.settle(transfer)
    }

    /// A Replace of a case variant whose commit fails says the original may carry the dragged spelling now.
    func testAFailedRespellingReplaceSaysWhatItMayHaveRenamed() async throws {
        let (source, target) = Self.fake(case: true, normalization: true)
        source.file("/src/readme.md", "new readme")
        target.file("/dst/README.md", "old README")
        target.fail("unpack.close", with: [.changed("/dst/README.md")])
        let transfer = copy(["/src/readme.md"], from: source, to: target)
        try await TestSupport.eventually { transfer.stage == .conflict(existing: ["readme.md"]) }
        transfer.resolveConflict?(.replace)
        try await TransferCaseMatrix.settle(transfer)
        guard case .failed(let message, _) = transfer.stage else { return XCTFail("\(transfer.stage)") }
        XCTAssertTrue(message.hasSuffix(". README.md may now be named readme.md"), message)
    }
}
