import AppKit
import os
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

    /// Copy (⌘C) puts the files themselves on the pasteboard, which Finder pastes: a local row's file URL at once; a
    /// remote row's path at once (a terminal here types it), then its file fetched into the app's private folder. A
    /// copy of something else meanwhile wins: the fetched file is not put over it.
    func testCopyPutsTheFilesThemselvesOnThePasteboard() async throws {
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(FakeFilesSource(endpoint: .local))
        let local = pasteboard()
        let rows = ["/Users/ivan/src/api/README.md", "/Users/ivan/src/api/src"]
        controller().copyToClipboard(rows, in: session, pasteboard: local)
        XCTAssertEqual(FilesDragController.fileURLs(local).map(\.path), rows)
        XCTAssertEqual(FilesDragPayload.read(local)?.paths, rows)
        XCTAssertEqual(local.string(forType: .string), rows.joined(separator: "\n"))

        let host = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        host.file("/home/ivan/nightly/bench.json", "{}")
        host.file("/home/ivan/nightly/run.log", "ok")
        let fetched = FakeFilesSource(endpoint: .local)
        let remoteSession = coordinator.session(for: System.uuid())
        remoteSession.availability = .available(host)
        let remote = pasteboard()
        controller(local: fetched).copyToClipboard(["/home/ivan/nightly/bench.json"], in: remoteSession, pasteboard: remote)
        // The private folder is made on this Mac's disk; the fake local side learns of it before the copy runs.
        fetched.directory(try XCTUnwrap(remoteSession.transfers.first?.targetPath))
        XCTAssertEqual(remote.string(forType: .string), "/home/ivan/nightly/bench.json")
        XCTAssertEqual(FilesDragController.fileURLs(remote), [], "Not on this Mac yet")
        XCTAssertEqual(remoteSession.transfers.first?.targetLabel, "Clipboard")
        try await TestSupport.eventually(diagnostic: "\(String(describing: remoteSession.transfers.first?.stage))") {
            !FilesDragController.fileURLs(remote).isEmpty
        }
        let url = try XCTUnwrap(FilesDragController.fileURLs(remote).first)
        XCTAssertEqual(url.lastPathComponent, "bench.json")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.hasPrefix(FilesClipboardFolder.prefix), url.path)
        XCTAssertEqual(fetched.text(url.path), "{}")
        XCTAssertEqual(remote.string(forType: .string), "/home/ivan/nightly/bench.json", "Still the host's path as text")
        XCTAssertEqual(FilesDragPayload.read(remote)?.endpoint, host.endpoint)

        controller(local: fetched).copyToClipboard(["/home/ivan/nightly/run.log"], in: remoteSession, pasteboard: remote)
        fetched.directory(try XCTUnwrap(remoteSession.transfers.last?.targetPath))
        remote.clearContents()
        remote.setString("copied elsewhere", forType: .string)
        try await TestSupport.eventually { remoteSession.transfers.last?.stage == .done }
        XCTAssertEqual(remote.string(forType: .string), "copied elsewhere")
        XCTAssertEqual(FilesDragController.fileURLs(remote), [])
    }

    /// Download… into a folder: each item under its own name, or Finder's "name 2" beside one there or picked for an
    /// earlier item; a download whose file cannot be moved where asked says why.
    func testDownloadNamesBesideWhatIsThereAndReportsAFailedMove() async throws {
        let folder = URL(fileURLWithPath: "/Users/ivan/Downloads")
        let there: Set<String> = ["/Users/ivan/Downloads/report.pdf", "/Users/ivan/Downloads/logs"]
        let urls = FilesDragController.destinations(for: ["report.pdf", "logs", "report.pdf", "notes"],
                                                    folders: [false, true, false, false], in: folder,
                                                    exists: { there.contains($0.path) })
        XCTAssertEqual(urls.map(\.lastPathComponent), ["report 2.pdf", "logs 2", "report 3.pdf", "notes"])

        // The fake fetches into its own memory, not the folder on disk, so the move finds nothing: the reason comes back.
        let fetched = FakeFilesSource(endpoint: .local)
        let host = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        host.file("/home/ivan/nightly/bench.json", "{}")
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(host)
        var failure: (any Error)?, settled = false
        controller(local: fetched).download(["/home/ivan/nightly/bench.json"],
                                            to: [System.temporary.appendingPathComponent("bench-\(System.uuid()).json")],
                                            in: session) { failure = $0; settled = true }
        XCTAssertEqual(session.transfers.first?.kind, .copyOut)
        fetched.directory(try XCTUnwrap(session.transfers.first?.targetPath))
        try await TestSupport.eventually { settled }
        XCTAssertNotNil(failure)
    }

    /// Copy scp Command: the destination the tab's ssh started with, its port as `-P`, `-r` for folders, every path in
    /// single quotes for the shell it is pasted into.
    func testScpCommandsQuotePathsAndCarryThePort() {
        XCTAssertEqual(FilesScpCommand.make(destination: "dev@build-box", paths: ["/srv/app/release notes.md"], folders: false),
                       "scp dev@build-box:'/srv/app/release notes.md' .")
        XCTAssertEqual(FilesScpCommand.make(destination: "ssh://dev@build-box:2222", paths: ["/srv/logs", "/srv/it's.txt"], folders: true),
                       #"scp -r -P 2222 dev@build-box:'/srv/logs' dev@build-box:'/srv/it'\''s.txt' ."#)
        XCTAssertEqual(FilesScpCommand.make(destination: "ssh://[fd00::12]:2200/", paths: ["/x"], folders: false),
                       "scp -P 2200 [fd00::12]:'/x' .")
        XCTAssertEqual(FilesScpCommand.make(destination: "build box", paths: ["/x"], folders: false), "scp 'build box':'/x' .")
        XCTAssertNil(FilesScpCommand.make(destination: "ssh://", paths: ["/x"], folders: false))
        XCTAssertNil(FilesScpCommand.make(destination: "dev@build-box", paths: [], folders: false))
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

    /// Every drag out of the list starts over it, so the list is told when it ends. NSTableView has no
    /// `draggingEnded:` of its own: a call to `super` threw, AppKit never finished the drag, and its image stayed on
    /// top of every window. Before the fix this test crashed with an unrecognized selector.
    func testTheListEndsADragWithoutCallingAMissingSuper() {
        let outline = FilesOutlineView()
        outline.draggingEnded(EndedDrag())
        outline.draggingExited(EndedDrag())
        outline.concludeDragOperation(EndedDrag())
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
        XCTAssertEqual(local.calls.first { $0.hasPrefix("list ") }, "list " + (resolved as NSString).deletingLastPathComponent,
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

    func testAFileInAProtectedFolderIsCopiedThroughTheAppsOwnCopyUntried() async throws {
        // The helper's read of a Desktop file would be the folder's first access, and raise macOS's consent prompt
        // when the app has no answer for Desktop yet: the app, which may read what was dropped, copies it first.
        let local = FakeFilesSource(endpoint: .local)
        local.file("/Users/ivan/Desktop/report.pdf", "%PDF")
        local.file("/Users/ivan/src/notes.txt", "notes")
        let target = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        target.directory("/home/ivan/in")
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(target)
        let (stage, asked, folder) = try stagingFake(local)
        let controller = controller(local: local, stage: stage, home: "/Users/ivan")
        let finder = pasteboard()
        finder.writeObjects([URL(fileURLWithPath: "/Users/ivan/Desktop/report.pdf") as NSURL,
                             URL(fileURLWithPath: "/Users/ivan/src/notes.txt") as NSURL])
        XCTAssertTrue(controller.accept(finder, onto: "/home/ivan/in", in: session))
        try await TestSupport.eventually { session.transfers.first?.stage == .done }
        XCTAssertEqual(asked.withLock { $0 }, [["/Users/ivan/Desktop/report.pdf"]], "Only what is in a protected folder")
        XCTAssertFalse(local.calls.contains { $0.hasSuffix(" /Users/ivan/Desktop/report.pdf") }, "The helper never tries it")
        XCTAssertTrue(local.calls.contains("read /Users/ivan/src/notes.txt"), "It tries the others")
        XCTAssertEqual(target.text("/home/ivan/in/report.pdf"), "%PDF")
        XCTAssertEqual(target.text("/home/ivan/in/notes.txt"), "notes")
        XCTAssertFalse(System.exists(folder), "The app's copy goes once the copy is done")
    }

    func testAFileTheHelperIsRefusedElsewhereIsCopiedThroughTheAppsOwnCopy() async throws {
        // A removable volume denied to this app: the helper it started is refused even what the user dropped, which
        // macOS lets the app itself read.
        let local = FakeFilesSource(endpoint: .local)
        local.file("/Volumes/Backup/report.pdf", "%PDF")
        local.failures["read /Volumes/Backup/report.pdf"] = .permissionDenied("/Volumes/Backup/report.pdf")
        local.file("/Volumes/Backup/notes.txt", "notes")
        let target = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        target.directory("/home/ivan/in")
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(target)
        let (stage, asked, folder) = try stagingFake(local)
        let controller = controller(local: local, stage: stage, home: "/Users/ivan")
        let finder = pasteboard()
        finder.writeObjects([URL(fileURLWithPath: "/Volumes/Backup/report.pdf") as NSURL,
                             URL(fileURLWithPath: "/Volumes/Backup/notes.txt") as NSURL])
        XCTAssertTrue(controller.accept(finder, onto: "/home/ivan/in", in: session))
        try await TestSupport.eventually { session.transfers.first?.stage == .done }
        XCTAssertEqual(asked.withLock { $0 }, [["/Volumes/Backup/report.pdf"]], "Only what the helper is refused")
        XCTAssertEqual(target.text("/home/ivan/in/report.pdf"), "%PDF")
        XCTAssertEqual(target.text("/home/ivan/in/notes.txt"), "notes")
        XCTAssertFalse(System.exists(folder), "The app's copy goes once the copy is done")
    }

    func testProtectedFoldersAreTheHomesOwn() {
        for path in ["/Users/ivan/Desktop", "/Users/ivan/Documents/q3/report.pdf", "/Users/ivan/Downloads/a.zip",
                     "/Users/ivan/Library/Mobile Documents/com~apple~CloudDocs/Documents/report.pdf",
                     "/Users/ivan/Library/CloudStorage/Sync-ivan/a.txt"] {
            XCTAssertTrue(FilesDragController.isProtected(path, home: "/Users/ivan"), path)
        }
        for path in ["/Users/ivan/DesktopNotes/a.txt", "/Users/ivan/src/Documents/a.txt", "/Users/maria/Desktop/a.txt",
                     "/Volumes/Backup/Desktop/a.txt", "/Users/ivan/Library/Preferences/a.plist"] {
            XCTAssertFalse(FilesDragController.isProtected(path, home: "/Users/ivan"), path)
        }
    }

    func testStagingKeepsNamesAndRemovesItsFolder() throws {
        let first = System.temporary.appendingPathComponent("drop-a-" + System.uuid().uuidString)
        let second = System.temporary.appendingPathComponent("drop-b-" + System.uuid().uuidString)
        try System.directory(first.appendingPathComponent("shots"))
        try System.directory(second)
        try System.write(Data("one".utf8), to: first.appendingPathComponent("report.txt"))
        try System.write(Data("png".utf8), to: first.appendingPathComponent("shots/a.png"))
        try System.write(Data("two".utf8), to: second.appendingPathComponent("report.txt"))
        defer { try? System.remove(first); try? System.remove(second) }
        let items = [first.appendingPathComponent("report.txt").path, first.appendingPathComponent("shots").path,
                     second.appendingPathComponent("report.txt").path]
        let staging = try FilesDropStaging.make(items)
        let copies = items.compactMap { staging.paths[$0] }
        XCTAssertEqual(copies.count, 3)
        XCTAssertEqual(Set(copies).count, 3, "Two report.txt stay apart")
        XCTAssertEqual(copies.map { ($0 as NSString).lastPathComponent }, ["report.txt", "shots", "report.txt"])
        XCTAssertEqual(try System.read(URL(fileURLWithPath: copies[0])), Data("one".utf8))
        XCTAssertEqual(try System.read(URL(fileURLWithPath: copies[1] + "/a.png")), Data("png".utf8))
        XCTAssertEqual(try System.read(URL(fileURLWithPath: copies[2])), Data("two".utf8))
        staging.remove()
        XCTAssertFalse(System.exists(staging.folder))
    }

    // MARK: Support

    /// Staging that puts the one item it is asked for into `local` as `report.pdf` of a real staging folder, and
    /// records what it was asked.
    private func stagingFake(_ local: FakeFilesSource) throws
        -> (@Sendable ([String]) throws -> FilesDropStaging, OSAllocatedUnfairLock<[[String]]>, URL) {
        let folder = System.temporary.appendingPathComponent(FilesDropStaging.prefix + System.uuid().uuidString)
        try System.directory(folder)
        let staged = folder.appendingPathComponent("report.pdf").path
        let asked = OSAllocatedUnfairLock(initialState: [[String]]())
        let stage: @Sendable ([String]) throws -> FilesDropStaging = { paths in
            asked.withLock { $0.append(paths) }
            local.file(staged, "%PDF")
            return FilesDropStaging(folder: folder, paths: [paths[0]: staged])
        }
        return (stage, asked, folder)
    }

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func controller(local: (any FilesSource)? = FakeFilesSource(endpoint: .local),
                            enabled: @escaping @MainActor () -> Bool = { true },
                            stage: @escaping @Sendable ([String]) throws -> FilesDropStaging = FilesDropStaging.make,
                            home: String = System.home.path)
        -> FilesDragController {
        let engine = FileTransferEngine(coordinator: { [unowned self] in coordinator }, asksBeforeReplacing: { true })
        // Finished rows stay to be checked.
        engine.sleep = { _, _ in throw CancellationError() }
        return FilesDragController(engine: engine, coordinator: { [unowned self] in coordinator },
                                   localSource: { local }, enabled: enabled, stage: stage, home: home)
    }
}

/// The least a drag can be for the list's end-of-drag calls.
private final class EndedDrag: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    deinit { draggingPasteboard.releaseGlobally() }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
