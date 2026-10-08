import AppKit
import Term
import XCTest
@testable import DispatchApp

@MainActor
final class TmuxPresentationTests: XCTestCase {
    func testSSHReattachRemapsPresentationWindowsWithoutCrossingAccountOrServer() throws {
        // Reconciliation uses helper-issued window identities; account/server identity admission
        // is the helper's contract, before a window reaches this common presentation consumer.
        let windows = (0..<4).map { _ in UUID() }
        let original = TabPresentation(windows: Array(windows.prefix(3)), selected: windows[1], preset: .columns)
        var restored = original
        restored.reconcile(windows, near: windows[0])
        var expected = original
        expected.groups[0].windows.append(windows[3])
        XCTAssertEqual(restored, expected)
        var removed = original
        removed.reconcile([windows[0], windows[2]], near: windows[0])
        XCTAssertEqual(removed.groups, [original.groups[0]])
        XCTAssertEqual(removed.preset, .single)
        XCTAssertEqual(removed.layout.paneIDs, [original.groups[0].id])
        var replaced = original
        replaced.reconcile([UUID(), UUID()], near: nil)
        XCTAssertEqual(replaced.groups, [])
        XCTAssertEqual(replaced.orderedWindows, [])
    }

    func testChatSwitchMovesBetweenTmuxTabBarPaneHeadersAndHiddenBar() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        guard app.runtime.chat.enabled else { throw XCTSkip("Requires Agent chat") }
        try await app.attach(); try await app.ready()
        let first = try XCTUnwrap(app.workspace.activeTab)
        let firstSession = app.runtime.chat.session(for: first.id)
        firstSession.sessionID = "tmux-header-first"

        /// Visible switches that would enter Chat, centred in window coordinates.
        func chatButtons() async throws -> [NSRect] {
            PresentationTestSupport.accessibilityFrames("chat-mode-switch", label: "Show Chat", in: app.window)
                .filter { !$0.isEmpty }.map { NSRect(origin: NSPoint(x: $0.midX, y: $0.midY), size: .zero) }
        }
        func terminalRect(_ tab: TerminalTab) throws -> NSRect {
            let view = try XCTUnwrap(app.runtime.views[tab.id])
            return view.convert(view.bounds, to: nil)
        }
        func click(_ button: NSRect) throws {
            let rect = button
            try PresentationTestSupport.click(app.window, at: NSPoint(x: rect.midX, y: rect.midY))
        }

        try await app.wait { (try? await chatButtons().count) == 1 }
        let initialButtons = try await chatButtons()
        var button = try XCTUnwrap(initialButtons.first)
        XCTAssertGreaterThan(button.midY, try terminalRect(first).maxY, "The switch belongs above the terminal, in the tab bar")
        try click(button)
        try await app.wait { firstSession.showChat }
        app.runtime.chat.chooseChat(false, session: firstSession)

        // Windowed title-row tabs stay visible; full screen hides a lone window's bar.
        app.window.delegate = app.controller
        do {
            try await setTabTestFullScreen(true, window: app.window)
            try await app.wait {
                guard let button = try? await chatButtons().first, let terminal = try? terminalRect(first) else { return false }
                return (try? await chatButtons().count) == 1 && terminal.contains(button.origin)
            }
        } catch {
            if app.window.styleMask.contains(.fullScreen) { try await setTabTestFullScreen(false, window: app.window) }
            throw error
        }
        try await setTabTestFullScreen(false, window: app.window)
        _ = try app.server(["split-window", "-v", "-t", try XCTUnwrap(app.target(first)), "/bin/sh"])
        try await app.wait { app.workspace.current?.activeWindow?.arrangement.panes.count == 2 }
        let second = try XCTUnwrap(app.workspace.current?.activeWindow?.terminals.first { $0.id != first.id })
        let secondSession = app.runtime.chat.session(for: second.id)
        secondSession.sessionID = "tmux-header-second"
        try await app.ready()
        try await app.wait { (try? await chatButtons().count) == 2 }
        for tab in [first, second] {
            let terminal = try terminalRect(tab)
            let visibleButtons = try await chatButtons()
            button = try XCTUnwrap(visibleButtons.first { abs($0.midY - terminal.maxY - 13) < 8 })
            let session = app.runtime.chat.session(for: tab.id)
            app.workspace.selectTab(tab.id == first.id ? second.id : first.id)
            try click(button)
            try await app.wait { session.showChat && app.workspace.activeTab?.id == tab.id }
            XCTAssertFalse(tab.id == first.id ? secondSession.showChat : firstSession.showChat)
            app.runtime.chat.chooseChat(false, session: session)
            try await app.wait { (try? await chatButtons().count) == 2 }
        }
        try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration + 0.05))
        _ = try await PresentationTestSupport.capture(app.window, named: "tmux-chat-pane-headers")
    }

    func testSplitCreationPreservesTheOriginalWindow() async throws {
        for axis in [SplitAxis.columns, .rows] {
            let app = try TmuxWalkthrough()
            defer { app.close() }
            try await app.attach(); try await app.ready()
            // Keep a non-last tab selected to verify the original pane retains it.
            let original = try XCTUnwrap(app.workspace.current?.activeWindow)
            app.workspace.newTab()
            try await app.wait { app.workspace.current?.windows.count == 2 && app.workspace.activeTab?.isConnecting == false }
            app.workspace.selectWindow(original.id)
            XCTAssertTrue(app.workspace.canToggleSplit(axis))
            app.workspace.toggleSplit(axis)
            let created = try XCTUnwrap(app.workspace.current?.activeWindow?.id)
            XCTAssertNotEqual(created, original.id)
            try await app.wait { app.workspace.current?.windows.count == 3 && app.workspace.activeTab?.isConnecting == false }
            try await app.ready()
            let space = try XCTUnwrap(app.workspace.current)
            let presentation = try XCTUnwrap(space.windowPresentation)
            XCTAssertEqual(presentation.groups.count, 2)
            XCTAssertEqual(presentation.groups.first(where: { $0.id == presentation.layout.paneIDs.first })?.selected, original.id)
            XCTAssertEqual(presentation.groups.first(where: { $0.id == presentation.layout.paneIDs.last })?.windows, [created])
            XCTAssertEqual(space.windows.first(where: { $0.id == original.id })?.terminals.map(\.id), original.terminals.map(\.id))
            app.workspace.toggleSplit(axis)
            XCTAssertEqual(app.workspace.current?.windowPresentation?.groups.count, 1)
            XCTAssertEqual(app.workspace.current?.windows.count, 3)
            XCTAssertEqual(app.workspace.current?.activeWindow?.id, created)
            XCTAssertNil(app.runtime.helpers[.local]?.error)
        }
    }

    func testSSHTabNavigationDoesNotCaptureOutgoingPanes() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        app.window.delegate = app.controller
        let server = try await SSHTestServer(transportOnly: true)
        defer { server.stop() }
        let remote = "\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge"
        let command = "TERM=xterm-256color /usr/bin/ssh " + (["-tt"] + server.options + [server.destination, remote])
            .map(HerdrLaunch.quote).joined(separator: " ")
        try await app.attach(command: command); try await app.ready()
        let first = try XCTUnwrap(app.workspace.current?.activeWindow)
        app.workspace.newTab()
        try await app.wait { app.workspace.current?.windows.count == 2 && app.workspace.activeTab?.isConnecting == false }
        try await app.ready()
        let second = try XCTUnwrap(app.workspace.current?.activeWindow)
        XCTAssertNotEqual(first.id, second.id)
        let firstSurfaceID = try XCTUnwrap(first.terminals.first?.id)
        let firstSurface = try XCTUnwrap(app.runtime.views[firstSurfaceID]?.surface)
        let root = try XCTUnwrap(app.window.contentView)
        var measurements: [[String: Any]] = []
        // Real Retina backing stores. AppKit may constrain the large window's
        // height; record actual bounds rather than claiming an emulated panel.
        let sizes: [NSSize?] = [.init(width: 640, height: 400), .init(width: 2560, height: 1440), nil]
        for size in sizes {
            if let size { app.window.setContentSize(size) }
            else { try await setTabTestFullScreen(true, window: app.window) }
            try await Task.sleep(for: .milliseconds(400))
            for index in 0..<6 {
                let target = index.isMultiple(of: 2) ? first : second
                let start = ContinuousClock.now
                app.workspace.selectWindow(target.id)
                root.layoutSubtreeIfNeeded()
                let duration = start.duration(to: .now).components
                let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
                let motion = try XCTUnwrap(PresentationTestSupport.views(of: MotionContentView.self, in: root).first)
                let snapshots = motion.subviews.compactMap { $0 as? NSImageView }
                let pixels = snapshots.reduce(0) { total, image in
                    total + (image.image?.representations.compactMap { $0 as? NSBitmapImageRep }
                        .reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh } ?? 0)
                }
                measurements.append(["width": root.bounds.width, "height": root.bounds.height,
                    "scale": app.window.backingScaleFactor, "fullScreen": app.window.styleMask.contains(.fullScreen),
                    "switchMs": ms, "snapshotPixels": pixels])
                XCTAssertTrue(snapshots.isEmpty, "Selecting another tmux window must not rasterize outgoing panes")
                try await app.ready()
                XCTAssertTrue(app.runtime.views[firstSurfaceID]?.surface === firstSurface, "Switching retains the existing terminal surface")
                try await Task.sleep(for: .milliseconds(350))
            }
            if size == nil { try await setTabTestFullScreen(false, window: app.window) }
        }
        let directory = CodexTestSupport.root.appendingPathComponent("build/tmux-tab-navigation-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("switches.json"))
        let terminal = try XCTUnwrap(app.runtime.views[try XCTUnwrap(app.workspace.activeTab?.id)])
        TerminalTestSupport.send("printf 'TAB_SWITCH_%s\\n' INPUT_OK", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("TAB_SWITCH_INPUT_OK") }
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    private func setTabTestFullScreen(_ enabled: Bool, window: NSWindow) async throws {
        let finished = expectation(description: enabled ? "Enter full screen" : "Exit full screen")
        let name = enabled ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
        let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in finished.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.collectionBehavior.insert(.fullScreenPrimary)
        if enabled { window.setContentSize(NSSize(width: 1120, height: 740)); window.center() }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.toggleFullScreen(nil)
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(window.styleMask.contains(.fullScreen), enabled)
    }

    func testColumnsGiveEachWindowItsOwnTabBar() async throws {
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        try await app.attach(); try await app.ready()
        let first = try XCTUnwrap(app.workspace.activeTab)
        let firstView = try XCTUnwrap(app.runtime.views[first.id])
        app.workspace.newTab()
        try await app.wait { app.workspace.current?.windows.count == 2 }
        try await app.ready()
        let secondView = try XCTUnwrap(app.runtime.views[try XCTUnwrap(app.workspace.activeTab?.id)])
        let height = secondView.bounds.height
        XCTAssertTrue(app.workspace.applyLayout(.columns))
        // Each column's own strip is shorter than the lone one (level capsules), so the
        // terminals may grow, but neither loses height to a second bar.
        try await app.wait {
            firstView.window === app.window && secondView.window === app.window &&
                abs(firstView.bounds.height - secondView.bounds.height) < 1 && secondView.bounds.height > height - 1
        }
        let left = secondView.convert(secondView.bounds, to: nil)
        let right = firstView.convert(firstView.bounds, to: nil)
        XCTAssertLessThan(left.minX, right.minX, "The active tab stays in the first column")
        XCTAssertEqual(left.minY, right.minY, accuracy: 1)
        XCTAssertEqual(left.height, right.height, accuracy: 1, "Each column has just one tab bar")
        try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration + 0.15))
        _ = try await PresentationTestSupport.capture(app.window, named: "local-two-columns", in: "tmux-presentation-audit")
        XCTAssertTrue(app.workspace.applyLayout(.single))
        try await app.wait { secondView.window === app.window && abs(secondView.bounds.height - height) < 1 }
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    func testLocalAttachAndNewWindowsStartAtAvailableSize() async throws {
        try await walkthrough(remote: false)
    }

    func testTypedSSHAttachAndNewWindowsStartAtAvailableSize() async throws {
        try await walkthrough(remote: true)
    }

    func testInitialAttachRespectsAConstrainedServerGrid() async throws {
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        _ = try app.server(["set-option", "-w", "-t", "@0", "window-size", "manual"])
        _ = try app.server(["resize-window", "-t", "@0", "-x", "60", "-y", "18"])
        try await app.attach(); try await app.ready()
        let view = try XCTUnwrap(app.runtime.views[try XCTUnwrap(app.workspace.activeTab?.id)])
        XCTAssertEqual(view.tmuxGrid, CGSize(width: 60, height: 18))
        let renderer = try XCTUnwrap(view.subviews.first)
        XCTAssertLessThan(renderer.frame.width, view.bounds.width)
        // The top-anchored renderer's frames must cover it, not sit at the view's bottom.
        XCTAssertEqual(renderer.layer?.frame, renderer.frame)
        TerminalTestSupport.send("printf 'CONSTRAINED_%s\\n' READY", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("CONSTRAINED_READY") }
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    private func walkthrough(remote: Bool) async throws {
        let app = try TmuxWalkthrough(autoClose: true, liquidGlass: false)
        defer { app.close() }
        app.controller.settings.values = Preferences.flat // Fixed tab height and initial visibility, independent of local preferences.
        let server = remote ? try await SSHTestServer() : nil
        defer { server?.stop() }
        let gateway = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[gateway].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let origin = try XCTUnwrap(app.runtime.views[gateway])
        if let server {
            TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: origin)
            try await TestSupport.eventually(timeout: .seconds(20)) {
                app.runtime.ssh.links.values.contains { $0.launch.tabID == gateway && $0.shellPID != nil }
            }
        }
        TerminalTestSupport.send("\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge", to: origin)
        // Each new screen (attach, new space, new window tab) gets the available size: tmux's own pane size
        // matches the renderer's grid for the view it shows in.
        var firstScreens: Set<String> = []
        func checkSize() throws {
            guard let tab = app.workspace.activeTab, let pane = app.target(tab), firstScreens.insert(pane).inserted,
                  let view = app.runtime.views[tab.id], let surface = view.surface else { return }
            let metrics = surface.grid, size = view.convertToBacking(view.bounds).size
            let scale = app.window.backingScaleFactor
            let width = Int((size.width - 20 * scale) / Double(metrics.cellWidth))
            let height = Int((size.height - 16 * scale) / Double(metrics.cellHeight))
            let actual = try app.server(["display-message", "-p", "-t", pane, "#{pane_width} #{pane_height}"]).split(whereSeparator: \.isWhitespace)
            XCTAssertEqual(actual.first.flatMap { Int($0) }, width, "The first screen must use the available width")
            XCTAssertEqual(actual.last.flatMap { Int($0) }, height, "The first screen must use the available height")
        }
        func ready() async throws {
            try await app.ready()
            try checkSize()
        }
        try await app.wait { app.workspace.activeTab.flatMap { app.target($0) } != nil && app.runtime.views[app.workspace.activeTab!.id]?.surface != nil }
        _ = try await PresentationTestSupport.capture(app.window, named: remote ? "ssh-before-first-screen" : "local-before-first-screen", in: "tmux-presentation-audit")
        try await ready()
        XCTAssertFalse(app.runtime.views[app.workspace.activeTab!.id]?.subviews.first?.isHidden == true)
        try await Task.sleep(for: .milliseconds(300))
        let first = try XCTUnwrap(app.workspace.activeTab)
        let view = try XCTUnwrap(app.runtime.views[first.id])
        // Upstream reserves windowed title-row tabs; measure hide/show in native full screen.
        app.window.delegate = app.controller
        do {
            try await setTabTestFullScreen(true, window: app.window)
            let hiddenHeight = view.bounds.height
            let tabHeight = StripTab.barHeight(titlebar: nil, style: .current(app.controller.windowState),
                typography: AppTypography(contentSize: app.controller.settings.values.fontSize))
            _ = try await PresentationTestSupport.capture(app.window, named: remote ? "ssh-single-tab" : "local-single-tab", in: "tmux-presentation-audit")

            app.workspace.newSpace()
            try await app.wait { app.workspace.activeTab?.id != first.id }
            try await ready()
            let second = try XCTUnwrap(app.workspace.activeTab)
            let secondView = try XCTUnwrap(app.runtime.views[second.id])
            app.workspace.newTab()
            try await app.wait { app.workspace.current?.windows.count == 2 }
            try await ready()
            let third = try XCTUnwrap(app.workspace.current?.activeWindow)
            let thirdView = try XCTUnwrap(app.runtime.views[try XCTUnwrap(app.workspace.activeTab?.id)])
            XCTAssertEqual(thirdView.bounds.height, hiddenHeight - tabHeight, accuracy: 1, "Multiple window tabs show the bar")
            _ = try await PresentationTestSupport.capture(app.window, named: remote ? "ssh-two-tabs" : "local-two-tabs", in: "tmux-presentation-audit")
            app.controller.closeWindow(third.id)
            try await app.wait { app.workspace.current?.windows.count == 1 && abs(secondView.bounds.height - hiddenHeight) < 1 }
            XCTAssertEqual(firstScreens.count, 3, "Observe attach, a new space, and a new window tab")
            XCTAssertNil(app.runtime.helpers[.local]?.error)
        } catch {
            if app.window.styleMask.contains(.fullScreen) { try await setTabTestFullScreen(false, window: app.window) }
            throw error
        }
        try await setTabTestFullScreen(false, window: app.window)
    }
}
