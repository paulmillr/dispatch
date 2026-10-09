import Darwin
import Metal
import XCTest
@_spi(Test) import Term
@_spi(Test) import TermApple
@testable import DispatchApp

/// The Swift terminal's session and process lifecycle below Dispatch's views.
@MainActor
final class SwiftTerminalSessionTests: XCTestCase {
    func testTerminalLinksConfirmNonWebSchemes() {
        XCTAssertNil(TerminalLinkPolicy.confirmationScheme(for: "https://example.com"))
        XCTAssertNil(TerminalLinkPolicy.confirmationScheme(for: "/tmp/report.txt"))
        XCTAssertEqual(TerminalLinkPolicy.confirmationScheme(for: "file:///Applications/App.app"), "file")
        XCTAssertEqual(TerminalLinkPolicy.confirmationScheme(for: "ssh://host"), "ssh")
    }

    /// New fonts (size, family, padding, scale) replace the glyph atlases while earlier frames keep
    /// their textures: a reconfigured session must draw exactly like a fresh one, in every in-flight frame.
    func testReconfiguredSessionDrawsLikeAFreshOne() throws {
        let text = Array("Hello, terminal: ABC xyz 0123 ->\r\nsecond line with the same glyphs".utf8)
        func session(_ size: Int) throws -> Session {
            let session = try Session(config: SwiftEngine.parse("font-size = \(size)", dark: true), scale: 2)
            session.setSize(width: 640, height: 240)
            session.locked { text.withUnsafeBufferPointer { session.surface.feed($0) } }
            return session
        }
        func pixels(_ session: Session) -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 240, mipmapped: false)
            (descriptor.usage, descriptor.storageMode) = ([.renderTarget, .shaderRead], .shared)
            let target = session.device.makeTexture(descriptor: descriptor)!
            guard let commands = session.render(into: target) else { XCTFail("Metal frame was not submitted"); return [] }
            commands.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: 640 * 240 * 4)
            target.getBytes(&bytes, bytesPerRow: 640 * 4, from: MTLRegionMake2D(0, 0, 640, 240), mipmapLevel: 0)
            return bytes
        }
        let reconfigured = try session(13)
        for _ in 0..<3 { _ = pixels(reconfigured) }  // every in-flight frame has uploaded the old atlases
        reconfigured.configure(SwiftEngine.parse("font-size = 14", dark: true))
        let expected = pixels(try session(14))
        for frame in 0..<3 { XCTAssertTrue(pixels(reconfigured) == expected, "frame \(frame) differs from a fresh session") }
    }

    /// ⌘K's clear_screen: at a prompt the screen and scrollback empty; under running output the rows
    /// above the cursor go and its row moves to the top; the alternate screen is left to its program.
    func testClearScreenErasesHistoryAndKeepsTheAlternateScreen() throws {
        func session(_ bytes: String) throws -> Session {
            let session = try Session(config: SwiftEngine.parse("", dark: true), scale: 1)
            session.setSize(width: 400, height: 120)
            let history = (1...40).map { "old \($0)" }.joined(separator: "\r\n") + "\r\n"
            session.locked { Array((history + bytes).utf8).withUnsafeBufferPointer { session.surface.feed($0) } }
            return session
        }
        func lines(_ session: Session, _ tag: PointTag) -> [String] {
            session.locked { String(decoding: session.surface.readText(tag), as: UTF8.self) }
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let clear = Array("clear_screen".utf8)
        let prompt = try session("\u{1B}]133;A\u{07}$ ")
        XCTAssertTrue(prompt.locked { prompt.surface.bindingAction(clear) })
        XCTAssertEqual(lines(prompt, .screen), [], "Nothing stays in the screen or its history at a prompt")
        let running = try session("first\r\nsecond\r\ncurrent")
        XCTAssertTrue(running.locked { running.surface.bindingAction(clear) })
        XCTAssertEqual(lines(running, .screen), ["current"])
        XCTAssertEqual(lines(running, .history), [])
        let alternate = try session("\u{1B}[?1049hfull screen")
        XCTAssertFalse(alternate.locked { alternate.surface.bindingAction(clear) })
        XCTAssertEqual(lines(alternate, .active), ["full screen"])
    }

    /// What a tab showed before an SSH session (Surface.markRows) never reaches that session's helper
    /// (readUnmarkedText): the session's own rows read normally, each on its row's line, and the earlier
    /// text stays blank wherever the session's output moves it, until a clear erases it.
    func testMarkedRowsStayHiddenWhereverLaterOutputMovesThem() {
        func surface(_ before: String = "local secret one\r\nlocal secret two\r\n$ ssh host\r\n") -> Surface {
            let surface = Surface(terminal: Terminal(TerminalOptions(cols: 20, rows: 6)), options: HandlerOptions(),
                                  size: RenderSize(screen: (200, 120), cell: (10, 20)), now: { 0 }, entropy: { [UInt8](repeating: 0, count: $0) })
            feed(surface, before)
            surface.markRows()
            feed(surface, "remote 1\r\nremote 2")
            return surface
        }
        func feed(_ surface: Surface, _ text: String) { Array(text.utf8).withUnsafeBufferPointer { surface.feed($0) } }
        func resize(_ surface: Surface, cols: Int, rows: Int) {
            surface.resize(cols: cols, rows: rows)
            surface.drain(reply: { _ in }, event: { _ in })
        }
        func unmarked(_ surface: Surface) -> String { String(decoding: surface.readUnmarkedText(), as: UTF8.self) }
        func assertHidden(_ surface: Surface, _ step: String, remote: Bool = true, line: UInt = #line) {
            let text = unmarked(surface), all = String(decoding: surface.readText(.active), as: UTF8.self)
            XCTAssertTrue(all.contains("secret") || all.contains("ssh host"), "\(step): the earlier text is still on screen", line: line)
            XCTAssertFalse(text.contains("secret") || text.contains("ssh") || text.contains("local"), "\(step): \(text.debugDescription)", line: line)
            if remote { XCTAssertTrue(text.contains("remote"), "\(step): the session's rows stay readable", line: line) }
        }

        XCTAssertEqual(unmarked(surface()), "\n\n\nremote 1\nremote 2", "One blank line per earlier row keeps rows on their lines")
        // A remote program pulling the earlier rows back into view: inserted lines, reverse index and scroll
        // down push them below its cursor, left/right margins move their cells, and a top-anchored region
        // scrolls above its cursor while the rows below keep their place.
        for (step, bytes) in [("insert lines", "\u{1B}[1;6r\u{1B}[1;1H\u{1B}[3L"), ("reverse index", "\u{1B}[1;1H\u{1B}M\u{1B}M\u{1B}M"),
                              ("scroll down", "\u{1B}[3T"), ("margins", "\u{1B}[?69h\u{1B}[1;10s\u{1B}[3L"),
                              ("scroll above", "\u{1B}[1;2r\u{1B}[2;1H\n\n\n")] {
            let shuffled = surface()
            feed(shuffled, bytes)
            // Only the region scrolling above its cursor keeps the session's rows on screen.
            assertHidden(shuffled, step, remote: step == "scroll above")
        }
        // Reflow on a narrower and a wider grid, and history coming back into view on a taller one.
        let resized = surface()
        resize(resized, cols: 7, rows: 6)
        assertHidden(resized, "narrower")
        resize(resized, cols: 30, rows: 12)
        assertHidden(resized, "wider and taller")
        // A clear erases the earlier text: what the session draws afterwards reads at once.
        let cleared = surface()
        feed(cleared, "\u{1B}[H\u{1B}[2Jafter clear")
        XCTAssertEqual(unmarked(cleared), "after clear")
        // A full screen showing when the session starts is earlier text too; a new one is the session's.
        let alternate = surface("local primary\r\n\u{1B}[?1049hlocal full screen")
        XCTAssertFalse(unmarked(alternate).contains("local"))
        feed(alternate, "\u{1B}[?1049l")
        XCTAssertFalse(unmarked(alternate).contains("local"))
        feed(alternate, "\u{1B}[?1049hremote full screen")
        XCTAssertEqual(unmarked(alternate), String(decoding: alternate.readText(.active), as: UTF8.self))
        XCTAssertTrue(unmarked(alternate).contains("remote full screen"))
        // Without a mark the text is exactly readText(.active), soft wraps included.
        let plain = Surface(terminal: Terminal(TerminalOptions(cols: 20, rows: 6)), options: HandlerOptions(),
                            size: RenderSize(screen: (200, 120), cell: (10, 20)), now: { 0 }, entropy: { [UInt8](repeating: 0, count: $0) })
        feed(plain, "a line long enough to wrap twice over\r\n\r\nlast")
        XCTAssertEqual(plain.readUnmarkedText(), plain.readText(.active))
    }

    /// A process writing far more than one pty read: every byte arrives, in order, including the
    /// output written right before it exits.
    func testFloodArrivesCompleteAndInOrder() async throws {
        let session = try Session(config: SwiftEngine.parse("", dark: true), scale: 1)
        session.setSize(width: 800, height: 600)
        let exited = expectation(description: "child exited")
        session.onExit = { _ in exited.fulfill() }
        try session.start(Launch(command: "/usr/bin/seq 1 200000", directory: NSHomeDirectory(), overrides: [], config: Config(),
                                 environment: ProcessInfo.processInfo.environment, resources: nil, id: 1))
        await fulfillment(of: [exited], timeout: 30)
        // The screen: the last numbers, then the cursor's empty row.
        let rows = session.locked { session.surface.terminal.grid.rows }
        let expected = (200002 - rows...200000).map(String.init)
        try await TestSupport.eventually(timeout: .seconds(10)) {
            let text = session.locked { String(decoding: session.surface.readText(.active), as: UTF8.self) }
            return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } == expected
        }
        session.close()
    }

    /// A relaunched tab: its saved text is on screen, faint, before the new process's first
    /// output, which is not; the text saved next is the shell's screen even under a full-screen program.
    /// A restored SSH tab shows the text with no process until it reconnects.
    func testRestoredHistoryPrecedesTheProcessDimmedAndIsReadFromThePrimaryScreen() async throws {
        let view = TerminalView(id: UUID(), directory: "/tmp"), config = SwiftEngine.parse("", dark: true)
        let backend = try XCTUnwrap(SwiftBackend(config: config, view: view, renderer: NSView(), scale: 1,
                                                 allowHostMedia: false, history: TerminalHistoryStore.replay("old one\nold two")))
        defer { backend.close() }
        XCTAssertTrue(backend.readText(.screen).hasPrefix("old one\nold two"))
        XCTAssertEqual(backend.foregroundPID, 0)
        XCTAssertFalse(backend.needsConfirmQuit, "Nothing runs before the process starts")
        XCTAssertTrue(backend.start(config: config, command: "/bin/sh -c 'echo NEW; exec sleep 30'", environment: [], directory: "/tmp"))
        XCTAssertFalse(backend.start(config: config, command: "/usr/bin/true", environment: [], directory: "/tmp"), "A terminal runs one process")
        try await TestSupport.eventually(timeout: .seconds(10)) { backend.readText(.screen).contains("NEW") }
        // The launcher's login banner may come before the command's output.
        let lines = backend.readText(.screen).split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.prefix(2), ["old one", "old two"])
        let new = try XCTUnwrap(lines.firstIndex(of: "NEW"))
        func rowIsFaint(_ row: Int) -> Bool {
            backend.session.locked { Array("\u{1B}[\(row);1H".utf8).withUnsafeBufferPointer { backend.session.surface.feed($0) } }
            return backend.cursorFaintTail().faint
        }
        XCTAssertTrue(rowIsFaint(1))
        XCTAssertFalse(rowIsFaint(new + 1))
        backend.session.locked { Array("\u{1B}[?1049hALT".utf8).withUnsafeBufferPointer { backend.session.surface.feed($0) } }
        XCTAssertTrue(backend.readText(.screen).contains("ALT"))
        XCTAssertFalse(backend.readHistory().contains("ALT"))
        XCTAssertTrue(backend.readHistory().hasPrefix("old one\nold two\n"))
        XCTAssertTrue(backend.readHistory().contains("NEW"))
    }

    /// scrollback-limit-bytes as Ghostty reads it (a byte count, `unlimited`, else a diagnostic)
    /// sets how much output a new terminal keeps.
    func testScrollbackLimitSetsWhatANewTerminalKeeps() throws {
        let line = Array((String(repeating: "x", count: 70) + "\r\n").utf8)
        let output = Array([[UInt8]](repeating: line, count: 200_000).joined())
        func kept(_ limit: String) throws -> Int {
            let session = try Session(config: SwiftEngine.parse("scrollback-limit-bytes = \(limit)", dark: true), scale: 1)
            session.setSize(width: 800, height: 600)
            return session.locked {
                output.withUnsafeBufferPointer { session.surface.feed($0) }
                return session.surface.readPrimaryText().count
            }
        }
        let small = try kept("2_000_000"), unlimited = try kept("unlimited")
        XCTAssertLessThan(small, output.count / 10)
        XCTAssertEqual(unlimited, 200_000 * 71 - 1, "Every line, joined by newlines")
        XCTAssertEqual(SwiftEngine.parse("scrollback-limit-bytes = lots", dark: true).diagnostics.map(\.key), ["scrollback-limit-bytes"])
    }

    /// Once the child is reaped its PID can belong to another process: the pty must forget it, so
    /// closing never signals or waits for a process group that is no longer ours.
    func testReapedChildIsForgotten() async throws {
        let launch = try Launch(command: "/usr/bin/true", directory: NSHomeDirectory(), overrides: [], config: Config(),
                                environment: ProcessInfo.processInfo.environment, resources: nil, id: 1)
        let exited = expectation(description: "child exited")
        let pty = try Pty(size: winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0), launch: launch,
                          onRead: { _, _ in }, onExit: { _ in exited.fulfill() })
        XCTAssertNotNil(pty.pid)
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertNil(pty.pid)
        pty.close()
    }

    /// A child can ignore SIGHUP. Closing must return promptly, escalate to SIGKILL, and reap it
    /// without blocking the main actor.
    func testClosingKillsAChildThatIgnoresHangup() async throws {
        let launch = try Launch(
            command: #"/bin/sh -c 'trap "" HUP; printf ready; while :; do sleep 1; done'"#,
            directory: NSHomeDirectory(),
            overrides: [],
            config: Config(),
            environment: ProcessInfo.processInfo.environment,
            resources: nil,
            id: 1
        )
        let ready = expectation(description: "child installed its SIGHUP handler")
        ready.assertForOverFulfill = false
        let pty = try Pty(
            size: winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0),
            launch: launch,
            onRead: { _, bytes in
                if String(decoding: bytes, as: UTF8.self).contains("ready") { ready.fulfill() }
            },
            onExit: { _ in }
        )
        await fulfillment(of: [ready], timeout: 10)
        let child = try XCTUnwrap(pty.pid)
        let clock = ContinuousClock(), started = clock.now
        pty.close()
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
        try await TestSupport.eventually {
            kill(child, 0) == -1 && errno == ESRCH
        }
    }

    /// Writes still queued when the terminal closes (the child never reads: they wait for room) run
    /// out after the terminal let go of the pty: every descriptor the pty opened must still close,
    /// wherever the pty's last reference goes away.
    func testClosingWithQueuedWritesReleasesThePty() async throws {
        // Descriptors by file identity: other threads may reuse a closed descriptor's number for another file.
        func open() -> [Int32: String] {
            Dictionary(uniqueKeysWithValues: (0..<getdtablesize()).compactMap { fd -> (Int32, String)? in
                var info = stat()
                return fstat(fd, &info) == 0 ? (fd, "\(info.st_dev):\(info.st_ino):\(info.st_rdev)") : nil
            })
        }
        let before = open()
        let launch = try Launch(command: "/bin/sleep 60", directory: NSHomeDirectory(), overrides: [], config: Config(),
                                environment: ProcessInfo.processInfo.environment, resources: nil, id: 1)
        var pty: Pty? = try Pty(size: winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0), launch: launch,
                                onRead: { _, _ in }, onExit: { _ in })
        let descriptors = open().filter { before[$0.key] != $0.value }
        XCTAssertFalse(descriptors.isEmpty)
        var rejected = 0
        for _ in 0..<100_000 where pty?.write(Array("0123456789abcde\n".utf8)) == false { rejected += 1 }
        XCTAssertGreaterThan(rejected, 0, "A child that never reads must exert bounded backpressure")
        pty?.close()
        pty = nil
        func remaining() -> [Int32: String] { let now = open(); return descriptors.filter { now[$0.key] == $0.value } }
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "Still open (fd: device:inode:rdev): \(remaining())") {
            remaining().isEmpty
        }
    }

    /// Output asking nothing of the host (no title, bell, clipboard...) never wakes the main queue:
    /// a hidden, unfocused session parses a whole flood without one main-queue post.
    func testHiddenOutputDoesNotWakeTheMainQueue() async throws {
        let session = try Session(config: SwiftEngine.parse("", dark: true), scale: 1)
        session.setSize(width: 800, height: 600)
        session.setVisible(false)
        session.setFocus(false)
        let exited = expectation(description: "child exited")
        session.onExit = { _ in exited.fulfill() }
        try session.start(Launch(command: "/usr/bin/seq 1 200000", directory: NSHomeDirectory(), overrides: [], config: Config(),
                                 environment: ProcessInfo.processInfo.environment, resources: nil, id: 1))
        await fulfillment(of: [exited], timeout: 30)
        let rows = session.locked { session.surface.terminal.grid.rows }
        try await TestSupport.eventually(timeout: .seconds(10)) {
            session.locked { String(decoding: session.surface.readText(.active), as: UTF8.self) }.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.last == "200000"
        }
        XCTAssertEqual(session.locked { session.wakes }, 0, "\(rows) rows")
        session.close()
    }

    /// A closed session is freed once its host lets go: nothing it started (pty threads, frame
    /// pacing) keeps it alive.
    func testClosedSessionIsReleased() async throws {
        weak var released: Session?
        do {
            let session = try Session(config: SwiftEngine.parse("", dark: true), scale: 1)
            released = session
            try session.start(Launch(command: "/bin/sleep 60", directory: NSHomeDirectory(), overrides: [], config: Config(),
                                     environment: ProcessInfo.processInfo.environment, resources: nil, id: 1))
            session.close()
        }
        try await TestSupport.eventually(timeout: .seconds(10)) { released == nil }
    }

    /// A closed terminal's scrollback warms the next one: the next terminal's pages all come from
    /// the blocks the first one left (the first one pays for its memory, the next ones don't). Its
    /// own blocks: the process's shared ones also serve the host app's terminals.
    func testClosedTerminalWarmsTheNext() async throws {
        let blocks = SharedPageBlocks()
        func flood() async throws -> Session {
            let session = try Session(config: SwiftEngine.parse("", dark: true), scale: 1, blocks: blocks)
            session.setSize(width: 800, height: 600)
            let exited = expectation(description: "child exited")
            session.onExit = { _ in exited.fulfill() }
            try session.start(Launch(command: "/usr/bin/seq 1 200000", directory: NSHomeDirectory(), overrides: [], config: Config(),
                                     environment: ProcessInfo.processInfo.environment, resources: nil, id: 1))
            await fulfillment(of: [exited], timeout: 30)
            try await TestSupport.eventually(timeout: .seconds(10)) {
                session.locked { String(decoding: session.surface.readText(.active), as: UTF8.self) }.contains("200000")
            }
            return session
        }
        do { try await flood().close() }
        try await TestSupport.eventually(timeout: .seconds(10)) { blocks.held > 0 }
        let (held, taken, missed) = (blocks.held, blocks.taken, blocks.missed)
        try await flood().close()
        XCTAssertEqual(blocks.missed, missed, "held \(held) after the first, the next took \(blocks.taken - taken)")
    }

    /// Blocks that end give back what they hold: a host's own blocks (like the test above) must not
    /// keep a whole scrollback's memory once it lets them go.
    func testDroppedBlocksFreeTheirMemory() {
        func inUse() -> Int { var s = malloc_statistics_t(); malloc_zone_statistics(nil, &s); return s.size_in_use }
        let count = pageBlocks(scrollbackBytes: TerminalOptions(cols: 1, rows: 1).maxScrollbackBytes ?? 0)
        let before = inUse()
        do {
            let blocks = SharedPageBlocks(cap: count)
            for _ in 0..<count { XCTAssertTrue(blocks.give(.allocate(byteCount: pageBlockBytes, alignment: 16))) }
        }
        XCTAssertLessThan(inUse() - before, count * pageBlockBytes / 2)
    }

    /// Kitty images drawn like Ghostty (renderer/image.zig): at their cells, in the three layers
    /// (below cell backgrounds, below text, above text), the current animation frame, gone when
    /// deleted, moved with the text. Probes are cell centers; where no image may show, the pixel is
    /// the one a session draws from the same input without the kitty commands.
    func testKittyImagesDrawInGhosttysLayers() throws {
        let (width, height) = (480, 320)
        func pixels(_ session: Session) -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            (descriptor.usage, descriptor.storageMode) = ([.renderTarget, .shaderRead], .shared)
            let target = session.device.makeTexture(descriptor: descriptor)!
            guard let commands = session.render(into: target) else { XCTFail("Metal frame was not submitted"); return [] }
            commands.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }
        let sessions = try (0..<2).map { _ in
            let session = try Session(config: SwiftEngine.parse("", dark: true), scale: 1)
            session.setSize(width: width, height: height)
            return session
        }
        func image(_ id: Int, _ rgb: [UInt8], z: Int) -> String {
            "\u{1b}_Ga=T,f=32,s=1,v=1,i=\(id),c=2,r=1,C=1,z=\(z),q=2;" + Data(rgb + [255]).base64EncodedString() + "\u{1b}\\"
        }
        let (red, green, blue, yellow, cyan): ([UInt8], [UInt8], [UInt8], [UInt8], [UInt8]) = ([255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [0, 255, 255])
        let block = "\u{1b}[38;2;0;0;255m\u{2588}\u{1b}[m"
        // Each step's input, then (column, row, the image color there or nil: as without graphics).
        let steps: [(String, [(Int, Int, [UInt8]?)])] = [
            ("\u{1b}[H" + image(1, red, z: 0), [(0, 0, red), (1, 0, red), (2, 0, nil)]),
            ("\u{1b}[2;1H" + block + "\u{1b}[2;1H" + image(2, green, z: -1), [(0, 1, nil), (1, 1, green)]),
            ("\u{1b}[3;1H\u{1b}[41m \u{1b}[m\u{1b}[3;1H" + image(3, blue, z: Int(Int32.min / 2) - 1), [(0, 2, nil), (1, 2, blue)]),
            ("\u{1b}[4;1H" + block + "\u{1b}[4;1H" + image(4, yellow, z: 1), [(0, 3, yellow), (1, 3, yellow)]),
            ("\u{1b}_Ga=f,i=1,f=32,s=1,v=1,q=2;" + Data(cyan + [255]).base64EncodedString() + "\u{1b}\\\u{1b}_Ga=a,i=1,c=2,q=2\u{1b}\\", [(0, 0, cyan), (1, 1, green)]),
            ("\u{1b}_Ga=d,d=I,i=4,q=2\u{1b}\\", [(0, 3, nil), (1, 3, nil)]),
            ("\u{1b}[999;1H\n", [(1, 0, green), (1, 1, blue), (0, 2, nil)]),
        ]
        let size = sessions[0].locked { sessions[0].surface.size }
        for (i, (input, probes)) in steps.enumerated() {
            let stripped = input.replacingOccurrences(of: #"\x{1b}_G[^\x{1b}]*\x{1b}\\"#, with: "", options: .regularExpression)
            for (session, bytes) in zip(sessions, [input, stripped]) { session.locked { Array(bytes.utf8).withUnsafeBufferPointer { session.surface.feed($0) } } }
            let (drawn, plain) = (pixels(sessions[0]), pixels(sessions[1]))
            for (col, row, color) in probes {
                let x = size.padding.left + col * size.cell.width + size.cell.width / 2, y = size.padding.top + row * size.cell.height + size.cell.height / 2
                let at = (y * width + x) * 4, got = [drawn[at + 2], drawn[at + 1], drawn[at]]
                XCTAssertEqual(got, color ?? [plain[at + 2], plain[at + 1], plain[at]], "step \(i), cell \(col),\(row)")
            }
        }
    }

    /// A remote-backed session keeps inline graphics but cannot make Kitty file or shared-memory
    /// requests against the Mac running Dispatch.
    func testKittyHostMediaCanBeDisabled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-kitty-media-\(UUID())")
        try Data([255, 0, 0, 255]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = "\u{1b}_Ga=q,t=f,f=32,s=1,v=1,S=4,i=7;"
            + Data(url.path.utf8).base64EncodedString() + "\u{1b}\\"

        func response(allowHostMedia: Bool) throws -> String {
            let session = try Session(config: SwiftEngine.parse("", dark: true), scale: 1, allowHostMedia: allowHostMedia)
            return session.locked {
                Array(request.utf8).withUnsafeBufferPointer { session.surface.feed($0) }
                var replies: [UInt8] = []
                session.surface.drain(reply: { replies += $0 }, event: { _ in })
                return String(decoding: replies, as: UTF8.self)
            }
        }

        XCTAssertTrue(try response(allowHostMedia: true).contains("OK"))
        XCTAssertTrue(try response(allowHostMedia: false).contains("EINVAL: unsupported medium"))
    }

    /// Kitty is ignored before payload buffering when its storage limit is zero. When enabled,
    /// placement metadata is bounded and reports backpressure instead of making rendering quadratic.
    func testKittyGraphicsOptInAndPlacementLimit() throws {
        func feed(_ text: String, to session: Session) -> String {
            session.locked {
                Array(text.utf8).withUnsafeBufferPointer { session.surface.feed($0) }
                var replies: [UInt8] = []
                session.surface.drain(reply: { replies += $0 }, event: { _ in })
                return String(decoding: replies, as: UTF8.self)
            }
        }

        let disabled = try Session(config: SwiftEngine.parse("image-storage-limit = 0", dark: true), scale: 1)
        let transmit = "\u{1b}_Ga=t,f=32,s=1,v=1,i=1;" + Data([255, 0, 0, 255]).base64EncodedString() + "\u{1b}\\"
        XCTAssertEqual(feed(transmit, to: disabled), "")
        XCTAssertTrue(disabled.surface.terminal.view.primary.images.images.isEmpty)

        let enabled = try Session(config: SwiftEngine.parse("", dark: true), scale: 1)
        var commands = "\u{1b}_Ga=t,f=32,s=1,v=1,i=1,q=2;" + Data([255, 0, 0, 255]).base64EncodedString() + "\u{1b}\\"
        for placement in 1...ImageStorage.maxPlacements + 1 {
            commands += "\u{1b}_Ga=p,i=1,p=\(placement),C=1,q=1;\u{1b}\\"
        }
        let replies = feed(commands, to: enabled)
        XCTAssertEqual(enabled.surface.terminal.view.primary.images.placements.count, ImageStorage.maxPlacements)
        XCTAssertTrue(replies.contains("p=\(ImageStorage.maxPlacements + 1);ENOMEM"), replies)
    }

    /// Workspace SSH/remote Herdr tabs and generic remote-output views such as the SSH login sheet
    /// all fail closed, while an ordinary local terminal retains host media support.
    func testTerminalViewSelectsHostMediaOnlyForTrustedLocalOutput() {
        XCTAssertTrue(TerminalView(id: UUID(), directory: "/tmp").allowHostMedia)
        XCTAssertFalse(TerminalView(id: UUID(), directory: "/tmp", machine: .ssh(SSHShell(destination: "host"))).allowHostMedia)
        // A remote helper's multiplexer tab (its space lives on an SSH link) and a space whose host is elsewhere.
        let runtime = TerminalRuntime(), workspace = Workspace()
        runtime.workspace = workspace
        var remote = Space(name: "remote", directory: "/tmp"); remote.remote = SSHConnectionID()
        var moved = Space(name: "moved", directory: "/tmp"); moved.hostID = .authenticated("host")
        workspace.spaces = [remote, moved]
        XCTAssertFalse(runtime.view(for: remote.tabs[0]).allowHostMedia)
        XCTAssertFalse(runtime.view(for: moved.tabs[0]).allowHostMedia)
        XCTAssertFalse(TerminalView(id: UUID(), directory: "/tmp", launchCommand: "/usr/bin/ssh host", allowHostMedia: false).allowHostMedia)
    }

    /// Oversized PNG dimensions are rejected from IHDR, before ImageIO is allowed to construct a
    /// decoded image whose backing allocation is controlled by terminal output.
    func testKittyPNGDimensionsAreBoundedBeforeDecode() {
        func pngHeader(width: UInt32, height: UInt32) -> [UInt8] {
            func bytes(_ value: UInt32) -> [UInt8] {
                [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
            }
            return [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13] + Array("IHDR".utf8) + bytes(width) + bytes(height)
        }

        let valid = KittySystem.pngDimensions(pngHeader(width: 1, height: 1))
        XCTAssertEqual(valid?.width, 1)
        XCTAssertEqual(valid?.height, 1)
        XCTAssertNil(KittySystem.pngDimensions(pngHeader(width: 0, height: 1)))
        XCTAssertNil(KittySystem.pngDimensions(pngHeader(width: KittyError.maxDimension + 1, height: 1)))
        XCTAssertNil(KittySystem.pngDimensions(pngHeader(width: KittyError.maxDimension, height: KittyError.maxDimension + 1)))
        XCTAssertNil(KittySystem.pngDimensions(pngHeader(width: 3_000, height: 3_000)), "Decoded RGBA bytes have their own lower ceiling")
        let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let decoded = KittySystem.decodePNG(Array(tinyPNG))
        XCTAssertEqual(decoded?.width, 1)
        XCTAssertEqual(decoded?.height, 1)
        XCTAssertEqual(decoded?.rgba.count, 4)
    }

    /// Link matching shares one retry budget across every start position, so an attacker cannot
    /// force exponential backtracking by printing a pathological URL-shaped line.
    func testLinkRegexStopsAtItsRetryBudget() throws {
        let regex = try XCTUnwrap(Regex(urlRegex))
        let input = Array(("http://" + String(repeating: ",", count: 24) + " ").unicodeScalars.map(\.value))
        let result = regex.searchForTest(input, retryLimit: 1_000)
        XCTAssertNil(result.match)
        XCTAssertTrue(result.exhausted)
    }

    /// Nullable custom link expressions must make progress and must not create an invalid
    /// end-before-start selection while the pointer moves on the main actor.
    func testNullableLinkRegexDoesNotHangOrCrashHover() throws {
        let session = try Session(config: SwiftEngine.parse("", dark: true), scale: 1)
        session.surface.config.links = [(try XCTUnwrap(Regex("a*")), nil)]
        session.locked { Array("abc".utf8).withUnsafeBufferPointer { session.surface.feed($0) } }
        let size = session.surface.size
        session.surface.mousePos(x: Double(size.padding.left + 2 * size.cell.width + 1),
                                 y: Double(size.padding.top + 1), mods: [])
        XCTAssertTrue(session.surface.drawLinks().isEmpty)
    }

    /// Terminal-controlled history can contain millions of overlapping occurrences; search keeps
    /// a useful recent result set without retaining one Match (and byte map) for every occurrence.
    func testSearchCapsOverlappingMatches() throws {
        let session = try Session(config: SwiftEngine.parse("", dark: true), scale: 1)
        session.locked { Array(String(repeating: "a", count: 20_000).utf8).withUnsafeBufferPointer { session.surface.feed($0) } }
        var search = TerminalSearch(Array("a".utf8))
        search.feed(session.surface.terminal, dirty: true)
        search.run(session.surface.terminal)
        XCTAssertEqual(search.total, 10_000)
        search.free(session.surface.terminal)
    }

    /// The reusable AppKit view may approve a local paste, but it must never silently approve a
    /// clipboard read initiated by terminal output.
    func testTerminalViewDoesNotAutomaticallyConfirmProgramClipboardRequests() {
        XCTAssertTrue(TerminalView.automaticallyConfirmsClipboard(.paste(.standard)))
        XCTAssertFalse(TerminalView.automaticallyConfirmsClipboard(.list(.standard)))
        XCTAssertFalse(TerminalView.automaticallyConfirmsClipboard(.osc52Read(.standard)))
    }

    /// A terminal's frames get a new display link when its view moves to another display and when
    /// the displays wake (a link whose display went away can stay silent); not for the same display.
    func testDisplayChangesAndWakeRelinkTheFrames() throws {
        let backend = try XCTUnwrap(SwiftBackend(config: SwiftEngine.parse("", dark: true), view: TerminalView(id: UUID(), directory: "/tmp"),
                                                 renderer: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)), scale: 1, allowHostMedia: false))
        defer { backend.close() }
        backend.setDisplayID(1)
        backend.setDisplayID(1)
        XCTAssertEqual(backend.session.relinks, 0, "The first display, and the same one again, keep the link")
        backend.setDisplayID(2)
        XCTAssertEqual(backend.session.relinks, 1, "Another display relinks")
        backend.displaysWoke()
        XCTAssertEqual(backend.session.relinks, 2, "Woken displays relink, even on the same display")
    }

    /// A display link that fell silent while its frames believed it ran (its display went away)
    /// draws nothing for later changes, so the tab freezes until a resize; relink() draws again.
    func testRelinkRevivesASilentDisplayLink() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let scale = window.backingScaleFactor
        let session = try Session(config: SwiftEngine.parse("", dark: true), scale: scale)
        defer { session.close() }
        session.host(in: view)
        session.setSize(width: Int(400 * scale), height: Int(200 * scale))
        func draws() async throws -> Bool {
            let before = session.drawnFrames
            session.refresh()
            let deadline = ContinuousClock.now + .milliseconds(500)
            while ContinuousClock.now < deadline {
                if session.drawnFrames > before { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        guard try await draws() else { throw XCTSkip("No display link fires here (no awake display)") }
        session.stallFrames()
        try await Task.sleep(for: .milliseconds(100))
        let stalled = try await draws()
        XCTAssertFalse(stalled, "A silent link draws nothing, however often frames are requested")
        session.relink()
        let relinked = try await draws()
        XCTAssertTrue(relinked, "The relinked frames draw again")
    }

    /// The terminal libraries are compiled optimized in every configuration, Debug too:
    /// unoptimized they drain output 18-80x slower.
    func testTerminalLibrariesAreOptimized() {
        XCTAssertEqual([Term.optimized, TermApple.optimized], [true, true])
    }
}
