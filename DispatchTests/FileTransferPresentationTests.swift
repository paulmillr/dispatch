import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// The transfer rows as F2b draws them, one hosted window per state, read back through OCR.
@MainActor
final class FileTransferPresentationTests: XCTestCase {
    func testTransferRowStatesRead() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let started = Date(timeIntervalSince1970: 1_760_700_000)
        func row(_ stage: FileTransfer.Stage, _ configure: (FileTransfer) -> Void = { _ in }) -> FileTransfer {
            let transfer = FileTransfer(kind: .copyIn, items: 5_120, targetPath: "/home/ivan/nightly/fixtures",
                                        targetLabel: "fixtures/", startedAt: started)
            transfer.stage = stage
            transfer.cancel = {}
            configure(transfer)
            return transfer
        }
        let cases: [(name: String, transfer: FileTransfer, reads: [String])] = [
            ("packing", row(.packing), ["Copying 5,120 items to fixtures/", "packing"]),
            ("sending", row(.sending) {
                $0.bytesTotal = 48_000_000; $0.bytesDone = 31_000_000; $0.rate = 12_000_000; $0.entries = 5_120
            }, ["Sending", "31 of 48 MB", "12 MB/s"]),
            ("unpacking", row(.unpacking) { $0.entries = 5_120; $0.bytesTotal = 48_000_000 }, ["Unpacking on homelab"]),
            ("done", row(.done) {
                $0.entriesDone = 5_120; $0.bytesTotal = 48_000_000; $0.finishedAt = started.addingTimeInterval(6.2)
            }, ["5,120 items copied", "48 MB", "6.2 s"]),
            ("conflict", row(.conflict(existing: (1...12).map { "f\($0)" })) { $0.resolveConflict = { _ in } },
             ["fixtures/ already has 12 of these", "Replace", "Keep both", "Skip them", "Cancel"]),
            ("failed", row(.failed(message: "Connection dropped while sending", retryable: true)) { $0.retry = {} },
             ["Connection dropped while sending", "Retry", "Nothing was written to fixtures/"]),
        ]
        for (name, transfer, reads) in cases {
            let session = FilesSession(id: System.uuid())
            session.hostLabel = "homelab"
            session.transfers = [transfer]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 80), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close(); window.contentView = nil }
            window.contentView = NSHostingView(rootView: VStack(spacing: 0) {
                Spacer(minLength: 0)
                FileTransferRows(session: session)
            }.background(Chrome.window))
            window.makeKeyAndOrderFront(nil)
            try await TestSupport.eventually {
                !PresentationTestSupport.accessibilityFrames("file-transfer-\(transfer.id.uuidString)", in: window).isEmpty
            }
            let snapshot = try await PresentationTestSupport.capture(window, named: "file-transfer-\(name)", in: "files")
            // OCR drops a button title's capital now and then ("skip them"); the lowercase variant is still the row.
            // Vision on macOS 27 also reads "Keep" in Cyrillic look-alikes ("\u{41A}\u{435}\u{435}\u{440}").
            for text in reads {
                let cyrillic = text.replacingOccurrences(of: "Keep", with: "\u{41A}\u{435}\u{435}\u{440}")
                try PresentationTestSupport.assertText(text, [text.lowercased(), cyrillic], in: snapshot)
            }
        }
    }
}
