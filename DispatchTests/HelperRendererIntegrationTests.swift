import AppKit
import Darwin
import XCTest

@testable import DispatchApp

@MainActor
final class HelperRendererIntegrationTests: XCTestCase {
    func testRendererTransfersDescriptorsResizesDrainsAndCloses() async throws {
        let restore = TestSupport.preserveRuntime()
        defer { restore() }
        try DesktopTestSupport.requireUnlocked()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("HelperClient/Fixtures/renderer.vt")
        let vt = try Data(contentsOf: fixture)
        // Typed text (UTF-8, as a keyboard produces): it reaches the helper's channel byte for byte.
        let input = Data(#"{"method":"hello","params":{}} typed through the renderer λ"#.utf8)
        let runtime = TerminalRuntime.shared
        defer { runtime.stop() }
        var captures: [[String: Any]] = []
        do {
            runtime.start(preferences: Preferences())
            runtime.chat.stop()
            XCTAssertNil(runtime.error)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "r-\(UUID().uuidString.prefix(8))")
            let executable = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent(
                "dispatch-helper")
            let bridge = try HelperRenderer(directory: directory, executable: executable)
            defer { bridge.stop() }
            let code =
                "import os,sys,tty,time; tty.setraw(0); os.write(1,open(sys.argv[1],'rb').read()); time.sleep(300)"
            let command = ["/usr/bin/python3", "-c", code, fixture.path].map(HelperRenderer.quote)
                .joined(separator: " ")
            let baseline = TerminalView(
                id: UUID(), directory: Home.url.path, launchCommand: command,
                presentation: .standalone)
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = baseline
            window.makeKeyAndOrderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            // The capture's last visible text marks completed fixture output, after login banners.
            try await TestSupport.eventually(
                diagnostic: TerminalTestSupport.screen(terminal: baseline)
            ) {
                TerminalTestSupport.screen(terminal: baseline).contains("CASE_READY_main")
            }
            let expected = TerminalTestSupport.screen(terminal: baseline)
            baseline.destroy()

            let id = UUID()
            var channel: HelperTerminal?
            var typed = Data()
            var resized: HelperTopology.Grid?
            var closed = 0
            var exited = 0
            bridge.onConnect = { tab, connection in
                XCTAssertEqual(tab, id)
                channel = connection
                connection.onInput = { typed.append($0) }
                connection.onResize = {
                    print("Renderer resize: grid=\($0)")
                    resized = .init(columns: $0.columns, rows: $0.rows)
                }
                connection.onClose = { closed += 1 }
                connection.write(vt)
            }
            let terminal = TerminalView(
                id: id, directory: Home.url.path, presentation: .standalone, helper: bridge)
            terminal.onProcessExit = { exited += 1 }
            window.contentView = terminal
            try await TestSupport.eventually(diagnostic: "connected=\(channel != nil), expected=\(String(reflecting: expected)), actual=\(String(reflecting: TerminalTestSupport.screen(terminal: terminal)))") {
                channel != nil && TerminalTestSupport.screen(terminal: terminal) == expected
            }
            let surface = try XCTUnwrap(terminal.surface)
            surface.text(String(decoding: input, as: UTF8.self))
            try await TestSupport.eventually { typed == input }
            window.setContentSize(NSSize(width: 1100, height: 750))
            try await TestSupport.eventually(diagnostic: "reported=\(String(describing: resized)), surface=\(surface.grid)") {
                resized
                    == HelperTopology.Grid(
                        columns: UInt16(surface.grid.columns), rows: UInt16(surface.grid.rows))
            }
            weak var released = channel
            let descriptors = try XCTUnwrap(channel).files.map { $0.fileDescriptor }
            func identities() -> [Int32: String] {
                Dictionary(
                    uniqueKeysWithValues: descriptors.compactMap { fd in
                        var value = stat()
                        guard fstat(fd, &value) == 0 else { return nil }
                        return (fd, "\(value.st_dev):\(value.st_ino):\(value.st_rdev)")
                    })
            }
            let before = identities()
            XCTAssertEqual(before.count, 2)
            channel?.finish()
            channel = nil
            try await TestSupport.eventually {
                closed == 1 && exited == 1 && bridge.count == 0 && released == nil
            }
            try await TestSupport.eventually {
                identities().filter { before[$0.key] == $0.value }.isEmpty
            }
            captures.append([
                "screen": expected, "input": typed.base64EncodedString(),
                "columns": resized!.columns, "rows": resized!.rows,
                "closed": closed, "exited": exited, "remaining": bridge.count,
            ])
            terminal.destroy()
            bridge.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            await runtime.stop().value
        }
        let path =
            ProcessInfo.processInfo.environment["DISPATCH_RENDERER_CAPTURE"]
            ?? Home.url.appendingPathComponent("renderer-capture.json").path
        try JSONSerialization.data(
            withJSONObject: captures, options: [.prettyPrinted, .sortedKeys]
        )
        .write(to: URL(fileURLWithPath: path))
    }

    func testRejectedRealChildClosesTransferredDescriptors() async throws {
        let restore = TestSupport.preserveRuntime()
        defer { restore() }
        try DesktopTestSupport.requireUnlocked()
        let runtime = TerminalRuntime.shared
        runtime.start(preferences: Preferences())
        runtime.chat.stop()
        defer { runtime.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "r-\(UUID().uuidString.prefix(8))")
        let executable = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent(
            "dispatch-helper")
        let bridge = try HelperRenderer(directory: directory, executable: executable)
        defer { bridge.stop() }
        let id = UUID()
        let environment = try bridge.environment(id: id)
        bridge.revoke(id)
        let assignments = stride(from: 0, to: environment.count, by: 2).map {
            environment[$0] + "=" + environment[$0 + 1]
        }
        let command = (["/usr/bin/env"] + assignments + [executable.path, "renderer"]).map(
            HelperRenderer.quote
        )
        .joined(separator: " ")
        var attached = 0
        var exited = 0
        bridge.onConnect = { _, _ in attached += 1 }
        let terminal = TerminalView(
            id: UUID(), directory: Home.url.path, launchCommand: command, presentation: .standalone)
        terminal.onProcessExit = { exited += 1 }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = terminal
        window.makeKeyAndOrderFront(nil)
        defer {
            terminal.destroy()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        try await TestSupport.eventually { exited == 1 && bridge.count == 0 }
        XCTAssertEqual(attached, 0)
    }

    /// A retained tab can keep a terminal id an earlier helper process gave another pane. Output
    /// goes to the tab that attached the terminal (its renderer had the snapshot), not the first
    /// tab with that id; a tab that moved on to another terminal falls back to the tab showing it.
    func testOutputGoesToTheTabThatAttachedTheTerminal() {
        let stale = UUID(), attaching = UUID()
        var showing: [UUID: UInt64] = [stale: 5, attaching: 5]
        func receiver(_ connected: Set<UUID>) -> UUID? {
            HelperWorkspace.receiver(of: 5, attached: [5: attaching], connected: connected, shown: stale) { showing[$0] }
        }
        XCTAssertEqual(receiver([stale, attaching]), attaching)
        XCTAssertEqual(receiver([stale]), stale, "Without the attaching renderer, the tab showing it")
        showing[attaching] = 6
        XCTAssertEqual(receiver([stale, attaching]), stale, "The attaching tab shows another terminal now")
        XCTAssertNil(HelperWorkspace.receiver(of: 7, attached: [5: attaching], connected: [attaching], shown: nil) { showing[$0] })
    }
}
