import AppKit
import XCTest
@testable import DispatchApp

/// Drops on a terminal and on a files view, on private pasteboards: what is typed, what a dragged row carries and
/// when a drop is taken. No window, no drag session.
@MainActor
final class FilesDropTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []
    private var coordinator = FilesCoordinator { nil }

    override func setUp() async throws {
        coordinator = FilesCoordinator { nil }
    }

    override func tearDown() async throws {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        pasteboards = []
    }

    func testDroppedPathsAreShellQuoted() throws {
        XCTAssertEqual(TerminalDrop.quote("/Users/ivan/notes-2026_10.md"), "/Users/ivan/notes-2026_10.md")
        XCTAssertEqual(TerminalDrop.quote("/srv/a+b,c:d@e%f"), "/srv/a+b,c:d@e%f", "Terminal.app's plain set stays as is")
        XCTAssertEqual(TerminalDrop.quote("/Users/ivan/My Files/a b.txt"), #"/Users/ivan/My\ Files/a\ b.txt"#)
        XCTAssertEqual(TerminalDrop.quote(#"/tmp/Ivan's "quoted".txt"#), #"/tmp/Ivan\'s\ \"quoted\".txt"#)
        XCTAssertEqual(TerminalDrop.quote("/tmp/$HOME `id` (x);&|<>*?[]{}~#!=^"),
                       ##"/tmp/\$HOME\ \`id\`\ \(x\)\;\&\|\<\>\*\?\[\]\{\}\~\#\!\=\^"##)
        XCTAssertEqual(TerminalDrop.quote(#"/tmp/back\slash\\"#), #"/tmp/back\\slash\\\\"#,
                       "A backslash is escaped too: fish reads one inside single quotes as an escape")
        XCTAssertEqual(TerminalDrop.quote("/tmp/café 📁"), "/tmp/caf\\é\\ \\📁")
        XCTAssertTrue(TerminalDrop.typable("/tmp/café 👨‍👩‍👧"), "The joiner inside an emoji is no control character")
        for control in ["\n", "\r", "\u{1B}", "\u{0}", "\u{7F}", "\u{85}", "\u{2028}", "\t"] {
            XCTAssertFalse(TerminalDrop.typable("/tmp/a\(control)b"), control.debugDescription)
        }

        let pasteboard = pasteboard()
        pasteboard.writeObjects([URL(fileURLWithPath: "/Users/ivan/My Files/a b.txt") as NSURL,
                                 URL(fileURLWithPath: "/Users/ivan/evil\n rm -rf ~\n.txt") as NSURL,
                                 URL(fileURLWithPath: "/Users/ivan/it's.log") as NSURL])
        XCTAssertEqual(TerminalDrop.text(pasteboard), #"/Users/ivan/My\ Files/a\ b.txt /Users/ivan/it\'s.log"#,
                       "A name with a control character is left out entirely")
        let typed = try XCTUnwrap(TerminalDrop.text(pasteboard))
        XCTAssertFalse(typed.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F },
                       "Nothing that would need a paste confirmation or end the line")
        let controls = self.pasteboard()
        controls.writeObjects([URL(fileURLWithPath: "/tmp/\u{1B}]0;title\u{7}") as NSURL])
        XCTAssertNil(TerminalDrop.text(controls), "Only unsafe names: no drop at all")
        let empty = self.pasteboard()
        empty.setString("just text", forType: .string)
        XCTAssertNil(TerminalDrop.text(empty), "Plain text is not a file drop")
    }

    func testDraggedRowsRoundTripThroughThePasteboard() throws {
        let remote = FilesEndpoint.remote(SSHConnectionID())
        let tab = System.uuid()
        let payload = FilesDragPayload(endpoint: remote, session: tab, paths: ["/home/ivan/nightly/scheduler/bench.json"])
        XCTAssertEqual(FilesDragPayload(propertyList: payload.propertyList), payload)
        XCTAssertEqual(FilesDragPayload(propertyList: FilesDragPayload(endpoint: .local, session: tab, paths: ["/a"]).propertyList)?.endpoint, .local)
        XCTAssertNil(FilesDragPayload(propertyList: ["endpoint": "remote:nope", "session": tab.uuidString, "paths": ["/a"]]))
        XCTAssertNil(FilesDragPayload(propertyList: ["endpoint": "local", "session": tab.uuidString, "paths": ["relative"]]),
                     "Only absolute paths travel")
        XCTAssertNil(FilesDragPayload(propertyList: ["endpoint": "local", "session": tab.uuidString, "paths": [String]()]))

        // One writer per row, as the outline asks for them.
        let source = FakeFilesSource(endpoint: remote, hostLabel: "homelab")
        let session = coordinator.session(for: tab)
        session.availability = .available(source)
        let controller = controller()
        let rows = ["/home/ivan/nightly/scheduler/bench-2026-10-17.json", "/home/ivan/nightly/scheduler/it's.log"]
        let writers = try rows.map { try XCTUnwrap(controller.pasteboardWriter(for: [$0], in: session)) }
        XCTAssertTrue(writers.allSatisfy { $0 is NSFilePromiseProvider }, "Each row is a file promise")
        let pasteboard = pasteboard()
        pasteboard.writeObjects(writers)
        XCTAssertEqual(FilesDragPayload.read(pasteboard), FilesDragPayload(endpoint: remote, session: tab, paths: rows))
        XCTAssertEqual(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) }, rows)
        XCTAssertEqual(TerminalDrop.text(pasteboard),
                       #"/home/ivan/nightly/scheduler/bench-2026-10-17.json /home/ivan/nightly/scheduler/it\'s.log"#,
                       "A terminal takes the host's paths as they are")
        XCTAssertEqual(FilesDragController.fileURLs(pasteboard), [], "A remote row is no file of this Mac")
    }

    func testLocalRowsAreFileURLs() throws {
        let tab = System.uuid()
        let local = FakeFilesSource(endpoint: .local)
        let session = coordinator.session(for: tab)
        session.availability = .available(local)
        let rows = ["/Users/ivan/src/api/README.md", "/Users/ivan/src/api/src"]
        let writers = try rows.map { try XCTUnwrap(controller().pasteboardWriter(for: [$0], in: session)) }
        XCTAssertFalse(writers.contains { $0 is NSFilePromiseProvider }, "Apps that take no promises take file URLs")
        let pasteboard = pasteboard()
        pasteboard.writeObjects(writers)
        XCTAssertEqual(FilesDragController.fileURLs(pasteboard).map(\.path), rows)
        XCTAssertEqual(FilesDragPayload.read(pasteboard), FilesDragPayload(endpoint: .local, session: tab, paths: rows))
        XCTAssertEqual(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) }, rows)
    }

    func testPasteRefusesWhatADropWould() throws {
        let local = FakeFilesSource(endpoint: .local)
        local.file("/Users/ivan/proj/sub/a.txt", "a")
        local.directory("/Users/ivan/other")
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(local)
        let controller = controller(local: local)
        XCTAssertFalse(controller.copyIn(["/Users/ivan/proj"], into: "/Users/ivan/proj/sub", in: session),
                       "A folder never goes inside itself")
        XCTAssertFalse(controller.copyIn(["/Users/ivan/proj"], into: "/Users/ivan/proj", in: session))
        XCTAssertFalse(controller.copyIn(["/Users/ivan/proj/sub/a.txt"], into: "/Users/ivan/proj/sub", in: session),
                       "Where it already is")
        XCTAssertTrue(session.transfers.isEmpty)
        XCTAssertTrue(controller.copyIn(["/Users/ivan/proj"], into: "/Users/ivan/other", in: session))
        XCTAssertEqual(session.transfers.count, 1)
        let remote = coordinator.session(for: System.uuid())
        remote.availability = .available(FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab"))
        XCTAssertTrue(controller.copyIn(["/Users/ivan/proj"], into: "/Users/ivan/proj/sub", in: remote),
                      "Another host's same path is another folder")
    }

    /// A host whose grant has Files without Copy files in takes no drop and no paste, from Finder or another tab, and
    /// says so: the session names the host while attempts keep coming. Copying out of it still works.
    func testAReadOnlyHostRefusesCopiesVisibly() throws {
        let local = FakeFilesSource(endpoint: .local)
        local.file("/Users/ivan/Downloads/report.pdf", "%PDF")
        let target = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        target.directory("/home/ivan/nightly/fixtures")
        target.file("/home/ivan/nightly/fixtures/a.txt", "a")
        target.readOnly = true
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(target)
        let controller = controller(local: local)
        let finder = pasteboard()
        finder.writeObjects([URL(fileURLWithPath: "/Users/ivan/Downloads/report.pdf") as NSURL])
        XCTAssertNil(session.writeRefusal)
        XCTAssertEqual(controller.validate(finder, onto: "/home/ivan/nightly/fixtures", in: session), [])
        XCTAssertEqual(session.writeRefusal, "homelab", "The drag over it says why")
        let attempts = session.writeRefusals
        XCTAssertFalse(controller.accept(finder, onto: "/home/ivan/nightly/fixtures", in: session))
        XCTAssertGreaterThan(session.writeRefusals, attempts, "Each attempt keeps the notice up")
        XCTAssertFalse(controller.copyIn(dropped: FilesDragController.droppedFiles(finder), into: "/home/ivan/nightly/fixtures",
                                         in: session), "⌘V is refused at once, not after resolving the files")
        XCTAssertFalse(controller.copyIn(["/Users/ivan/Downloads/report.pdf"], into: "/home/ivan/nightly/fixtures", in: session))
        let other = coordinator.session(for: System.uuid())
        other.availability = .available(local)
        let rows = pasteboard()
        let item = NSPasteboardItem()
        item.setPropertyList(FilesDragPayload(endpoint: .local, session: other.id, paths: ["/Users/ivan/Downloads/report.pdf"]).propertyList,
                             forType: .filesPaths)
        rows.writeObjects([item])
        XCTAssertEqual(controller.validate(rows, onto: "/home/ivan/nightly/fixtures", in: session), [], "Nor rows of another tab")
        XCTAssertTrue(session.transfers.isEmpty)
        XCTAssertNil(target.text("/home/ivan/nightly/fixtures/report.pdf"))

        // Out of it is reading: its rows still drop on this Mac.
        let out = pasteboard()
        let row = NSPasteboardItem()
        row.setPropertyList(FilesDragPayload(endpoint: target.endpoint, session: session.id, paths: ["/home/ivan/nightly/fixtures/a.txt"]).propertyList,
                            forType: .filesPaths)
        out.writeObjects([row])
        local.directory("/Users/ivan/Desktop")
        XCTAssertEqual(controller.validate(out, onto: "/Users/ivan/Desktop", in: other), .copy)
        XCTAssertNil(other.writeRefusal)

        // A plain pasteboard over it is no copy, and refuses nothing.
        let text = pasteboard()
        text.setString("just text", forType: .string)
        let fresh = coordinator.session(for: System.uuid())
        fresh.availability = .available(target)
        XCTAssertEqual(controller.validate(text, onto: "/home/ivan", in: fresh), [])
        XCTAssertNil(fresh.writeRefusal)
    }

    func testDropsFollowTheSetting() throws {
        var enabled = true
        let local = FakeFilesSource(endpoint: .local)
        local.file("/Users/ivan/Downloads/report.pdf", "%PDF")
        let target = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        target.directory("/home/ivan/nightly/fixtures")
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(target)
        let controller = controller(local: local, enabled: { enabled })
        let finder = pasteboard()
        finder.writeObjects([URL(fileURLWithPath: "/Users/ivan/Downloads/report.pdf") as NSURL])

        XCTAssertEqual(controller.validate(finder, onto: "/home/ivan/nightly/fixtures", in: session), .copy)
        XCTAssertTrue(controller.dragEnabled)
        XCTAssertEqual(controller.acceptedTypes, [.filesPaths, .fileURL])
        enabled = false
        XCTAssertEqual(controller.validate(finder, onto: "/home/ivan/nightly/fixtures", in: session), [])
        XCTAssertFalse(controller.accept(finder, onto: "/home/ivan/nightly/fixtures", in: session))
        XCTAssertFalse(controller.dragEnabled)
        XCTAssertNil(controller.pasteboardWriter(for: ["/home/ivan/nightly/fixtures"], in: session),
                     "Off removes the drag sources too")
        XCTAssertTrue(session.transfers.isEmpty)
        enabled = true

        let unavailable = coordinator.session(for: System.uuid())
        XCTAssertEqual(controller.validate(finder, onto: "/home/ivan", in: unavailable), [], "No files, no drop")
        XCTAssertEqual(self.controller(local: nil).validate(finder, onto: "/home/ivan/nightly/fixtures", in: session), [],
                       "Finder files need this Mac's source")
    }

    func testRowsDoNotDropIntoThemselves() throws {
        let source = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        source.file("/home/ivan/nightly/fixtures/golden/a.txt", "a")
        source.directory("/home/ivan/nightly/target")
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(source)
        let other = coordinator.session(for: System.uuid())
        other.availability = .available(FakeFilesSource(endpoint: .remote(SSHConnectionID())))
        let controller = controller()
        let pasteboard = pasteboard()
        let payload = FilesDragPayload(endpoint: source.endpoint, session: session.id, paths: ["/home/ivan/nightly/fixtures"])
        let item = NSPasteboardItem()
        item.setPropertyList(payload.propertyList, forType: .filesPaths)
        pasteboard.writeObjects([item])
        XCTAssertEqual(controller.validate(pasteboard, onto: "/home/ivan/nightly/target", in: session), .copy)
        XCTAssertEqual(controller.validate(pasteboard, onto: "/home/ivan/nightly", in: session), [], "Where it already is")
        XCTAssertEqual(controller.validate(pasteboard, onto: "/home/ivan/nightly/fixtures/golden", in: session), [],
                       "A folder never goes inside itself")
        XCTAssertEqual(controller.validate(pasteboard, onto: "/home/ivan/nightly", in: other), .copy,
                       "Another host's same path is another folder")
    }

    func testAFinderDropStartsACopyIntoTheFolder() async throws {
        let local = FakeFilesSource(endpoint: .local)
        local.file("/Users/ivan/Downloads/report.pdf", "%PDF")
        let target = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        target.directory("/home/ivan/nightly/fixtures")
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(target)
        let controller = controller(local: local)
        let finder = pasteboard()
        finder.writeObjects([URL(fileURLWithPath: "/Users/ivan/Downloads/report.pdf") as NSURL])
        XCTAssertTrue(controller.accept(finder, onto: "/home/ivan/nightly/fixtures", in: session))
        XCTAssertTrue(session.transfers.isEmpty, "Nothing starts while the drag is live")
        try await TestSupport.eventually { !session.transfers.isEmpty }
        let transfer = try XCTUnwrap(session.transfers.first)
        XCTAssertEqual(transfer.kind, .copyIn)
        XCTAssertEqual(transfer.targetLabel, "fixtures/")
        try await TestSupport.eventually { transfer.stage == .done }
        XCTAssertEqual(target.text("/home/ivan/nightly/fixtures/report.pdf"), "%PDF")
    }

    func testRowsDraggedBetweenHostsRelayThroughThisMac() async throws {
        let first = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        first.file("/home/ivan/a.txt", "a")
        let second = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "build")
        second.directory("/srv/drop")
        let origin = coordinator.session(for: System.uuid())
        origin.availability = .available(first)
        let destination = coordinator.session(for: System.uuid())
        destination.availability = .available(second)
        let pasteboard = pasteboard()
        let item = NSPasteboardItem()
        item.setPropertyList(FilesDragPayload(endpoint: first.endpoint, session: origin.id, paths: ["/home/ivan/a.txt"]).propertyList,
                             forType: .filesPaths)
        pasteboard.writeObjects([item])
        XCTAssertTrue(controller().accept(pasteboard, onto: "/srv/drop", in: destination))
        XCTAssertEqual(origin.transfers.map(\.kind), [.copyOut])
        XCTAssertEqual(destination.transfers.map(\.kind), [.relay])
        try await TestSupport.eventually { destination.transfers.first?.stage == .done }
        XCTAssertEqual(second.text("/srv/drop/a.txt"), "a")
    }

    func testAFileReferenceIsResolvedOnlyAfterTheDrop() async throws {
        // Finder writes file references: their path is the file system's to tell, and asking it in a protected
        // folder may wait on a consent prompt, which must never happen while Finder's drag is live.
        // Made, moved and removed live: the reference and its lookup are the file system's, in replay too.
        let folder = System.temporary.appendingPathComponent("files-drop-" + System.uuid().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("moved"), withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("report.pdf")
        try Data("%PDF".utf8).write(to: file)
        // Through `perform`: the Swift overlay's `fileReferenceURL()` hands back the path URL it resolves to.
        let reference = try XCTUnwrap(((file as NSURL).perform(NSSelectorFromString("fileReferenceURL"))?
            .takeUnretainedValue() as? NSURL)?.absoluteString)
        XCTAssertTrue(reference.hasPrefix("file:///.file/id="), reference)
        let finder = pasteboard()
        finder.setString(reference, forType: .fileURL)
        // Moved after the drag began: only a lookup on disk finds it, so a path naming the new place proves one.
        try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("moved/report.pdf"))

        let local = FakeFilesSource(endpoint: .local)
        let target = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        target.directory("/home/ivan/nightly/fixtures")
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(target)
        let controller = controller(local: local)
        XCTAssertEqual(FilesDragController.droppedFiles(finder), [reference], "Read as written, nothing resolved")
        XCTAssertNil(FilesDragController.plainPath(reference))
        XCTAssertEqual(controller.validate(finder, onto: "/home/ivan/nightly/fixtures", in: session), .copy)
        XCTAssertTrue(TerminalDrop.accepts(finder), "A terminal takes it too, its name still unknown")
        XCTAssertTrue(controller.accept(finder, onto: "/home/ivan/nightly/fixtures", in: session))
        XCTAssertTrue(session.transfers.isEmpty, "The copy waits for the paths, resolved after the drop returned")

        let resolved = try XCTUnwrap(FilesDragController.resolve([reference]).first)
        XCTAssertTrue(resolved.hasSuffix("/moved/report.pdf"), resolved)
        XCTAssertEqual(FilesDragController.fileURLs(finder).map(\.path), [resolved])
        local.file(resolved, "%PDF")
        try await TestSupport.eventually { session.transfers.first?.stage == .done }
        XCTAssertEqual(target.text("/home/ivan/nightly/fixtures/report.pdf"), "%PDF")
        XCTAssertEqual(local.calls.first, "list " + (resolved as NSString).deletingLastPathComponent,
                       "The copy reads the file where it is now")
    }

    func testADeniedFolderFailsTheDropAndTheNextOneWorks() async throws {
        // macOS refuses Downloads to this Mac's helper once its consent prompt was denied; the helper answers
        // permission_denied (EPERM), and asks no more.
        let local = FakeFilesSource(endpoint: .local)
        local.file("/Users/ivan/Downloads/report.pdf", "%PDF")
        local.failures["list /Users/ivan/Downloads"] = .permissionDenied("/Users/ivan/Downloads")
        local.file("/Users/ivan/Desktop/shots/a.png", "png")
        local.failures["pack /Users/ivan/Desktop"] = .permissionDenied("/Users/ivan/Desktop")
        local.file("/Users/ivan/Documents/report.pdf", "%PDF")
        local.file("/Users/ivan/Documents/shots/b.png", "png")
        let target = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        target.directory("/home/ivan/in")
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(target)
        let controller = controller(local: local)
        func drop(_ path: String) async throws -> FileTransfer {
            let finder = pasteboard()
            finder.writeObjects([URL(fileURLWithPath: path) as NSURL])
            let count = session.transfers.count
            XCTAssertTrue(controller.accept(finder, onto: "/home/ivan/in", in: session))
            try await TestSupport.eventually { session.transfers.count > count }
            let transfer = try XCTUnwrap(session.transfers.last)
            try await TestSupport.eventually { !transfer.isActive }
            return transfer
        }
        let settings = "Allow Dispatch in System Settings › Privacy & Security › Files and Folders"

        let denied = try await drop("/Users/ivan/Downloads/report.pdf")
        XCTAssertEqual(denied.stage, .failed(message: "No permission for Downloads. " + settings, retryable: false))
        XCTAssertNil(denied.retry, "Only the setting gives the folder back")
        let packed = try await drop("/Users/ivan/Desktop/shots")
        XCTAssertEqual(packed.stage, .failed(message: "No permission for Desktop. " + settings, retryable: false))
        XCTAssertTrue(local.calls.contains("pack /Users/ivan/Desktop"), "\(local.calls)")

        // The refused pack let its helper slots go: the next archive from this Mac goes through.
        let folder = try await drop("/Users/ivan/Documents/shots")
        XCTAssertEqual(folder.stage, .done)
        let file = try await drop("/Users/ivan/Documents/report.pdf")
        XCTAssertEqual(file.stage, .done)
        XCTAssertEqual(target.text("/home/ivan/in/shots/b.png"), "png")
        XCTAssertEqual(target.text("/home/ivan/in/report.pdf"), "%PDF")
        XCTAssertNil(target.node("/home/ivan/in/a.png"))
    }

    // MARK: Support

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func controller(local: (any FilesSource)? = FakeFilesSource(endpoint: .local),
                            enabled: @escaping @MainActor () -> Bool = { true }) -> FilesDragController {
        let engine = FileTransferEngine(coordinator: { [unowned self] in coordinator }, asksBeforeReplacing: { true })
        // Finished rows stay to be checked.
        engine.sleep = { _, _ in throw CancellationError() }
        return FilesDragController(engine: engine, coordinator: { [unowned self] in coordinator },
                                   localSource: { local }, enabled: enabled)
    }
}
