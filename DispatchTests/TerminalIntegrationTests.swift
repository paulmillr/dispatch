import AppKit
import SwiftUI
import XCTest
import Term
@testable import DispatchApp

@MainActor
final class TerminalIntegrationTests: XCTestCase {
    func testControlCReachesForegroundCommandThroughApplicationEvents() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let runtime = TerminalRuntime.shared
        let controller = AppDelegate(), workspace = controller.workspace
        runtime.workspace = workspace
        runtime.start(preferences: Preferences())
        runtime.chat.stop()
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newLocalSpace()
        let probe = #"""
        import os, signal, time
        count = 0
        def interrupted(*_):
            global count
            count += 1
            os.write(1, f'CONTROL_C_RECEIVED_{count}\r\n'.encode())
        signal.signal(signal.SIGINT, interrupted)
        os.write(1, b'CONTROL_C_READY\r\n')
        while True:
            time.sleep(1)
        """#
        workspace.spaces[0].panes[0].tabs[0].launchCommand = "/usr/bin/python3 -u -c " + HerdrLaunch.quote(probe)
        let id = try XCTUnwrap(workspace.activeSurfaceID)
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        controller.window = window; window.isReleasedWhenClosed = false
        let previousMenu = NSApp.mainMenu
        controller.buildMenus()
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { NSApp.mainMenu = previousMenu; window.orderOut(nil); window.contentView = nil; window.close(); runtime.stop() }
        try await TestSupport.eventually { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id])
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: terminal).contains("CONTROL_C_READY") }
        XCTAssertTrue(window.makeFirstResponder(terminal))
        NSApp.sendEvent(TerminalTestSupport.keyEvent(8, "\u{03}", in: window, modifiers: .control, ignoringModifiers: "c"))
        try await TestSupport.eventually(timeout: .seconds(5), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("CONTROL_C_RECEIVED_1")
        }
        let queued = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{03}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        NSApp.postEvent(queued, atStart: false)
        try await TestSupport.eventually(timeout: .seconds(5), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("CONTROL_C_RECEIVED_2")
        }
        let hardware = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        hardware.flags = .maskControl
        let native = try XCTUnwrap(NSEvent(cgEvent: hardware))
        terminal.keyDown(with: native)
        try await TestSupport.eventually(timeout: .seconds(5), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("CONTROL_C_RECEIVED_3")
        }
        XCTAssertTrue(terminal.performKeyEquivalent(with: queued), "The focused terminal must claim Control chords before AppKit interprets them as text commands")
        try await TestSupport.eventually(timeout: .seconds(5), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("CONTROL_C_RECEIVED_4")
        }
        try runtime.apply(Preferences())
        XCTAssertTrue(terminal.performKeyEquivalent(with: queued))
        try await TestSupport.eventually(timeout: .seconds(5), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("CONTROL_C_RECEIVED_5")
        }
        XCTAssertFalse(terminal.performKeyEquivalent(with: TerminalTestSupport.keyEvent(8, "c", in: window, modifiers: .command)))
        for (code, text, modifiers): (UInt16, String, NSEvent.ModifierFlags) in [(18, "1", .control), (48, "\t", .control), (48, "\u{19}", [.control, .shift])] {
            XCTAssertFalse(terminal.performKeyEquivalent(with: TerminalTestSupport.keyEvent(code, text, in: window, modifiers: modifiers)),
                           "Space and tab navigation must reach the application menu")
        }
        // tmux-style prefix keys: ⌃B twice leaves Control chords reaching the program, and ⌃B c
        // runs New Tab instead of typing.
        controller.settings.values.prefixKeys = .tmux
        let prefix = TerminalTestSupport.keyEvent(11, "\u{02}", in: window, modifiers: .control, ignoringModifiers: "b")
        XCTAssertTrue(terminal.performKeyEquivalent(with: prefix))
        XCTAssertEqual(workspace.prefixKeys.armed, id)
        XCTAssertTrue(terminal.performKeyEquivalent(with: prefix))
        XCTAssertNil(workspace.prefixKeys.armed)
        XCTAssertTrue(terminal.performKeyEquivalent(with: queued))
        try await TestSupport.eventually(timeout: .seconds(5), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("CONTROL_C_RECEIVED_6")
        }
        XCTAssertTrue(terminal.performKeyEquivalent(with: prefix))
        terminal.keyDown(with: TerminalTestSupport.keyEvent(8, "c", in: window))
        XCTAssertEqual(workspace.currentTabs.count, 2)
        XCTAssertNil(workspace.prefixKeys.armed)
        window.makeFirstResponder(nil)
        XCTAssertFalse(terminal.performKeyEquivalent(with: queued), "Unfocused terminals must not consume another view's shortcuts")

        // Chat mode answers the same prefix keys from its composer, the only view it can focus;
        // ⌃B twice is the editor's own ⌃B.
        workspace.selectTab(id)
        let session = runtime.chat.session(for: id)
        session.active = true; session.sessionID = "prefix-keys-test"; session.draft = "draft"; session.showChat = true
        let root = try XCTUnwrap(window.contentView)
        try await TestSupport.eventually { PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: root).contains { $0.session === session } }
        let composer = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: root).first { $0.session === session })
        XCTAssertTrue(window.makeFirstResponder(composer))
        composer.setSelectedRange(NSRange(location: 5, length: 0))
        NSApp.sendEvent(prefix)
        XCTAssertEqual(workspace.prefixKeys.armed, id)
        NSApp.sendEvent(prefix)
        XCTAssertNil(workspace.prefixKeys.armed)
        XCTAssertEqual(composer.selectedRange().location, 4, "⌃B twice moves back one character")
        NSApp.sendEvent(prefix)
        NSApp.sendEvent(TerminalTestSupport.keyEvent(8, "c", in: window))
        XCTAssertEqual(workspace.currentTabs.count, 3)
        XCTAssertNil(workspace.prefixKeys.armed)
        XCTAssertEqual(session.draft, "draft", "A completed sequence types nothing")
    }

    func testTerminalVisibilityTracksChatWindowAndTabWithoutStoppingSession() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let runtime = TerminalRuntime.shared
        let controller = AppDelegate(), workspace = controller.workspace
        runtime.workspace = workspace
        runtime.start(preferences: Preferences())
        XCTAssertNil(runtime.error)
        // This probe is not an agent; keep discovery from clearing its
        // synthetic chat presentation while exercising the real view tree.
        runtime.chat.stop()
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newSpace()
        // Ask the real terminal for its visibility, rather than inspecting a
        // Swift mirror of the state. Replies also prove hidden IO stays alive.
        let probe = #"""
        import os, tty
        tty.setraw(0)
        os.write(1, b'VISIBILITY_READY\r\n')
        sequence = 0
        while os.read(0, 1):
            sequence += 1
            os.write(1, b'\x1b[?998n')
            response = b''
            while not response.endswith(b'n'):
                response += os.read(0, 1)
            state = response.decode().split(';')[-1].rstrip('n')
            os.write(1, f'STATE_{sequence}_{state}\r\n'.encode())
        """#
        workspace.spaces[0].panes[0].tabs[0].launchCommand = "/usr/bin/python3 -u -c " + HerdrLaunch.quote(probe)
        let id = try XCTUnwrap(workspace.activeTab?.id)
        let session = runtime.chat.session(for: id)
        session.active = true; session.sessionID = "visibility-test"; session.showChat = true
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        controller.window = window
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close(); runtime.stop() }
        try await eventually { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), surface = try XCTUnwrap(terminal.surface)
        try await eventually { self.text(surface).contains("VISIBILITY_READY") && window.occlusionState.contains(.visible) }
        let pid = surface.foregroundPID
        var sequence = 0
        try await eventually { !terminal.isPresented }
        try await expectVisibility(false, terminal: terminal, surface: surface, pid: pid, sequence: &sequence)
        session.draft = "full-screen draft"
        session.turns = (0..<30).map { index in
            ChatTurn(id: "turn-\(index)", items: [ChatItem(id: "message-\(index)", kind: .assistant,
                text: String(repeating: "Real chat content to scroll. ", count: 25))])
        }
        window.collectionBehavior.insert(.fullScreenPrimary)
        try await setFullScreen(true, window: window)
        let root = try XCTUnwrap(window.contentView)
        try await eventually { !PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: root).isEmpty }
        let composer = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: root).first)
        XCTAssertTrue(composer.session === session)
        XCTAssertEqual(composer.string, "full-screen draft")
        window.makeFirstResponder(composer)
        try await eventually { composer.caretTimer != nil && composer.caretOn }
        XCTAssertFalse(composer.shouldDrawInsertionPoint)
        XCTAssertTrue(terminal.window === window)
        XCTAssertTrue(runtime.views[id] === terminal)
        XCTAssertTrue(terminal.surface === surface)
        try await expectVisibility(false, terminal: terminal, surface: surface, pid: pid, sequence: &sequence)
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: root)
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
        try await eventually { scroll.contentView.bounds.minY > 200 }
        let previous = scroll.contentView.bounds.minY
        session.scrollPosition.userWillScroll(deltaY: 200)
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: 200, wheel2: 0, wheel3: 0))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThan(scroll.contentView.bounds.minY, previous - 100)
        XCTAssertTrue(window.firstResponder === composer)
        composer.insertText(" typed in full screen", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(session.draft.contains("typed in full screen"))
        XCTAssertNotNil(composer.caretTimer)
        try await setFullScreen(false, window: window)
        try await eventually { window.occlusionState.contains(.visible) && window.isOnActiveSpace }
        for visible in [true, false, true] {
            session.showChat = !visible
            try await eventually { terminal.isPresented == visible }
            XCTAssertTrue(terminal.window === window, "Chat keeps the terminal mounted")
            try await expectVisibility(visible, terminal: terminal, surface: surface, pid: pid, sequence: &sequence)
        }
        window.orderOut(nil)
        try await eventually { !window.occlusionState.contains(.visible) }
        try await expectVisibility(false, terminal: terminal, surface: surface, pid: pid, sequence: &sequence)
        window.makeKeyAndOrderFront(nil)
        try await eventually { window.occlusionState.contains(.visible) }
        try await expectVisibility(true, terminal: terminal, surface: surface, pid: pid, sequence: &sequence)
        workspace.newTab()
        try await eventually { terminal.window == nil }
        try await expectVisibility(false, terminal: terminal, surface: surface, pid: pid, sequence: &sequence)
        workspace.selectTab(id)
        try await eventually { terminal.window === window && terminal.isPresented }
        try await expectVisibility(true, terminal: terminal, surface: surface, pid: pid, sequence: &sequence)
    }

    func testRealShellSurvivesTabsSpacesSplitsAndSettings() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let glass = LiquidGlassStore.shared.enabled
        defer { LiquidGlassStore.shared.enabled = glass }
        let runtime = TerminalRuntime.shared
        let controller = AppDelegate()
        // This test measures the classic NSSplitView sidebar, not the Glass overlay.
        controller.settings.values = Preferences.flat
        let workspace = controller.workspace
        runtime.workspace = workspace
        runtime.start(preferences: controller.settings.values)
        XCTAssertNil(runtime.error)
        XCTAssertNotNil(runtime.engine)
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newSpace()
        let firstSpace = workspace.selectedSpace!
        let firstID = workspace.activeTab!.id
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        controller.window = window
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = controller
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let oldMenu = NSApp.mainMenu
        controller.buildMenus()
        defer {
            NSApp.mainMenu = oldMenu
            window.delegate = nil
            window.orderOut(nil)
            window.contentView = nil
            runtime.stop()
        }
        try await eventually { runtime.views[firstID]?.surface != nil }
        try await eventually { window.isKeyWindow }
        let first = try XCTUnwrap(runtime.views[firstID])
        let surface = try XCTUnwrap(first.surface)
        try await eventually { !surface.needsConfirmQuit && !self.text(surface).isEmpty }
        try await TerminalTestSupport.assertPhysicalTyping(in: window, terminal: first)
        TerminalTestSupport.send("for i in {1..200}; do printf 'LOCAL_SCROLL_%03d\\n' $i; done", to: first)
        try await eventually { TerminalTestSupport.screen(terminal: first).contains("LOCAL_SCROLL_200") }
        try await TerminalTestSupport.assertScrollbar(in: first, bottomMarker: "LOCAL_SCROLL_200")
        first.scrollbar.doubleValue = 0
        XCTAssertTrue(first.scrollbar.sendAction(first.scrollbar.action, to: first.scrollbar.target))
        try await eventually { !TerminalTestSupport.viewport(terminal: first).contains("LOCAL_SCROLL_200") }
        workspace.newTab()
        let freshID = workspace.activeTab!.id
        try await eventually { runtime.views[freshID]?.surface != nil }
        XCTAssertTrue(try XCTUnwrap(runtime.views[freshID]).scrollbar.isHidden)
        workspace.selectTab(firstID)
        try await eventually { first.isPresented }
        XCTAssertEqual(first.scrollbar.state.offset, 0, "Tab switches preserve that terminal's history position")
        workspace.closeTab(freshID)
        first.scrollbar.doubleValue = 1
        XCTAssertTrue(first.scrollbar.sendAction(first.scrollbar.action, to: first.scrollbar.target))
        try await eventually { TerminalTestSupport.viewport(terminal: first).contains("LOCAL_SCROLL_200") }
        send("printf '\\nDISPATCH_%s\\n' LIVE\n", to: surface)
        try await eventually { self.text(surface).contains("DISPATCH_LIVE") }
        let pid = surface.foregroundPID
        XCTAssertGreaterThan(pid, 0)
        let initialSize = surface.grid
        controller.toggleChat()
        XCTAssertFalse(runtime.chat.session(for: firstID).showChat, "Plain shells cannot enter agent chat")
        XCTAssertTrue(first.surface === surface)

        func splits(_ view: NSView) -> [TerminalSplitView] {
            PresentationTestSupport.views(of: TerminalSplitView.self, in: view, includingNestedMatches: true)
        }
        let sidebarSplit = try XCTUnwrap(splits(try XCTUnwrap(window.contentView)).first(where: \.sidebar))
        XCTAssertTrue(sidebarSplit.sidebarHidden)
        // Reproduce single space → show → hide → second space. Hiding in the
        // automatic single-space state must not pin a future sidebar closed.
        controller.toggleSidebar()
        try await eventually { !sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        controller.toggleSidebar()
        try await eventually { sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        workspace.newSpace()
        try await eventually { !sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        workspace.closeSpace(workspace.selectedSpace!)
        try await eventually { sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        XCTAssertTrue(runtime.views[firstID]?.surface === surface)
        try await shortcut("\\", keyCode: 42, modifiers: .command, window: window)
        try await eventually { !sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating && sidebarSplit.arrangedSubviews[0].frame.width > 200 }
        sidebarSplit.setPosition(300, ofDividerAt: 0)
        try await shortcut("\\", keyCode: 42, modifiers: .command, window: window)
        try await eventually { sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating && surface.grid.columns == initialSize.columns }
        // Use the actual title-bar button to reopen it.
        let zoomButton = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let zoomFrame = zoomButton.convert(zoomButton.bounds, to: nil)
        func assertWindowControlAlignment() throws {
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(kind))
                XCTAssertEqual(window.frame.height - button.convert(button.bounds, to: nil).midY, 19, accuracy: 0.5,
                    "Native controls stay centered in the original 38-point title row")
            }
        }
        try assertWindowControlAlignment()
        // Include native controls in the capture so row alignment can be
        // reviewed alongside the SwiftUI title and action buttons.
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let titlebarRect = frameView.convert(NSRect(x: 0, y: window.frame.height - 38, width: window.frame.width, height: 38), from: nil)
        let titlebarBitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: titlebarRect))
        frameView.cacheDisplay(in: titlebarRect, to: titlebarBitmap)
        try PresentationTestSupport.save(titlebarBitmap, named: "titlebar-aligned", in: "ui-audit")
        // Same vertical center as native traffic lights, with the mockup's
        // 16-point gap followed by half of the 22-point toggle target.
        let sidebarPoint = NSPoint(x: zoomFrame.maxX + 16 + 11, y: zoomFrame.midY)
        try PresentationTestSupport.click(window, at: sidebarPoint)
        try await eventually { !sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        XCTAssertEqual(sidebarSplit.arrangedSubviews[0].frame.width, 300, accuracy: 1)
        workspace.newSpace(); workspace.closeSpace(workspace.selectedSpace!)
        XCTAssertTrue(controller.sidebarVisible, "Manual pin survives returning to a single space")
        controller.settings.values.hideSingleSpace = false
        try await eventually { controller.windowState.sidebarVisibilityOverride == nil }
        controller.settings.values.hideSingleSpace = true
        try await eventually { sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        XCTAssertTrue(runtime.views[firstID]?.surface === surface)
        XCTAssertEqual(surface.foregroundPID, pid)

        try await setFullScreen(true, window: window)
        XCTAssertTrue(controller.windowState.isFullScreen)
        let reveal = try XCTUnwrap(PresentationTestSupport.views(of: FullScreenSidebarRevealView.self,
            in: try XCTUnwrap(window.contentView)).first)
        // Full-screen transitions may leave the VM's pointer at the edge.
        // Start the hover sequence from a known outside position.
        reveal.updatePointer(at: NSPoint(x: 100, y: 100))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(reveal.button.isHidden)
        let beforeReveal = surface.grid
        let responder = window.firstResponder
        reveal.mouseEntered(with: try PresentationTestSupport.mouseEvent(.mouseMoved, in: window,
            at: reveal.convert(NSPoint(x: 4, y: 100), to: nil)))
        XCTAssertFalse(reveal.button.isHidden)
        XCTAssertTrue(sidebarSplit.sidebarHidden, "Hover reveals only the button")
        XCTAssertEqual(surface.grid.columns, beforeReveal.columns)
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertNil(reveal.hitTest(reveal.convert(NSPoint(x: 4, y: 100), to: reveal.superview)),
                     "The edge region must not intercept terminal clicks")
        _ = try await PresentationTestSupport.capture(window, named: "fullscreen-sidebar-reveal", in: "sidebar-reveal-validation")
        let revealPoint = reveal.convert(NSPoint(x: reveal.button.frame.midX, y: reveal.button.frame.midY), to: nil)
        try PresentationTestSupport.click(window, at: revealPoint)
        try await eventually { !sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        XCTAssertTrue(PresentationTestSupport.views(of: FullScreenSidebarRevealView.self,
            in: try XCTUnwrap(window.contentView)).first === reveal, "Keep one control mounted across sidebar transitions")
        XCTAssertTrue(reveal.pinned)
        XCTAssertEqual(reveal.convert(NSPoint(x: reveal.button.frame.midX, y: reveal.button.frame.midY), to: nil), revealPoint)
        reveal.updatePointer(at: NSPoint(x: 100, y: 100))
        XCTAssertFalse(reveal.button.isHidden, "The sidebar header keeps its toggle visible")
        _ = try await PresentationTestSupport.capture(window, named: "fullscreen-sidebar-open", in: "sidebar-reveal-validation")
        // The integrated header control occupies the same target as the reveal.
        try PresentationTestSupport.click(window, at: revealPoint)
        try await eventually { sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        reveal.updatePointer(at: NSPoint(x: 100, y: 100))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(reveal.button.isHidden)
        // A second tab shows the strip, whose leading slot pins the button.
        workspace.newTab()
        let slotTab = try XCTUnwrap(workspace.activeTab).id
        try await eventually { reveal.pinned && !reveal.button.isHidden }
        XCTAssertEqual(reveal.convert(NSPoint(x: reveal.button.frame.midX, y: reveal.button.frame.midY), to: nil), revealPoint)
        _ = try await PresentationTestSupport.capture(window, named: "fullscreen-sidebar-tab-slot", in: "sidebar-reveal-validation")
        workspace.closeTab(slotTab)
        try await eventually { !reveal.pinned && workspace.activeTab?.id == firstID }
        try await shortcut("\\", keyCode: 42, modifiers: .command, window: window)
        try await eventually { !sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        try await shortcut("\\", keyCode: 42, modifiers: .command, window: window)
        try await eventually { sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        controller.windowState.sidebarVisibilityOverride = nil
        _ = try await PresentationTestSupport.capture(window, named: "main-full-screen")
        try await eventually { surface.grid.rows > initialSize.rows }
        XCTAssertTrue(runtime.views[firstID]?.surface === surface)
        try await setFullScreen(false, window: window)
        XCTAssertFalse(controller.windowState.isFullScreen)
        try await eventually {
            guard let content = window.contentView else { return false }
            return PresentationTestSupport.views(of: FullScreenSidebarRevealView.self, in: content).isEmpty
        }
        try assertWindowControlAlignment()
        try await eventually { surface.grid.rows == initialSize.rows }

        try await shortcut("t", keyCode: 17, modifiers: [.command], window: window)
        XCTAssertEqual(workspace.spaces.count, 1)
        XCTAssertEqual(workspace.currentTabs.count, 2)
        let secondID = workspace.activeTab!.id
        try await eventually { runtime.views[secondID]?.surface != nil && first.window == nil }
        XCTAssertTrue(first.surface === surface)
        try await shortcut("1", keyCode: 18, modifiers: [.command], window: window)
        XCTAssertEqual(workspace.activeTab?.id, firstID)
        try await eventually { first.window === window }
        XCTAssertTrue(text(surface).contains("DISPATCH_LIVE"))
        try await shortcut("]", keyCode: 30, modifiers: [.command], window: window)
        XCTAssertEqual(workspace.activeTab?.id, secondID)
        try await shortcut("[", keyCode: 33, modifiers: [.command], window: window)
        XCTAssertEqual(workspace.activeTab?.id, firstID)

        let firstPane = workspace.current!.focusedPane
        XCTAssertTrue(workspace.moveTab(secondID, to: firstPane, relativeTo: firstID))
        XCTAssertEqual(workspace.activeTab?.id, firstID)
        try await shortcut("1", keyCode: 18, modifiers: [.command], window: window)
        XCTAssertEqual(workspace.activeTab?.id, secondID)
        workspace.selectTab(firstID)
        try await eventually { first.window === window }
        XCTAssertTrue(first.surface === surface)
        XCTAssertTrue(text(surface).contains("DISPATCH_LIVE"))

        workspace.newTab()
        workspace.split(.columns)
        let splitID = workspace.activeTab!.id
        try await eventually { runtime.views[splitID]?.surface != nil && surface.grid.columns < initialSize.columns }
        let fraction = Double(surface.grid.columns) / Double(initialSize.columns)
        XCTAssertGreaterThan(fraction, 0.35)
        XCTAssertLessThan(fraction, 0.65)
        let paneSplit = try XCTUnwrap(splits(try XCTUnwrap(window.contentView)).first { !$0.sidebar })
        paneSplit.setPosition(paneSplit.bounds.width * 0.35, ofDividerAt: 0)
        try await shortcut("\\", keyCode: 42, modifiers: .command, window: window)
        try await eventually { !sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        try await shortcut("\\", keyCode: 42, modifiers: .command, window: window)
        try await eventually { sidebarSplit.sidebarHidden && !sidebarSplit.sidebarAnimating }
        XCTAssertTrue(splits(window.contentView!).contains { $0 === paneSplit }, "Toggle retains the native pane layout")
        XCTAssertEqual(paneSplit.arrangedSubviews[0].frame.width / paneSplit.bounds.width, 0.35, accuracy: 0.02)
        controller.windowState.sidebarVisibilityOverride = nil
        workspace.moveTab(secondID, to: workspace.current!.focusedPane)
        workspace.selectTab(firstID)
        XCTAssertTrue(runtime.views[firstID]?.surface === surface)

        workspace.newSpace()
        try await eventually { first.window == nil }
        // Hidden shells continue receiving output and retain their scrollback.
        send("printf '\\nBACKGROUND_%s\\n' ALIVE\n", to: surface)
        try await eventually { self.text(surface).contains("BACKGROUND_ALIVE") }
        try await shortcut("1", keyCode: 18, modifiers: [.shift, .command], window: window)
        XCTAssertEqual(workspace.selectedSpace, firstSpace)
        try await eventually { first.window === window }
        let otherSpace = workspace.spaces.first { $0.id != firstSpace }!.id
        XCTAssertTrue(workspace.reorderSpace(firstSpace, relativeTo: otherSpace, after: true))
        XCTAssertEqual(workspace.selectedSpace, firstSpace)
        try await eventually { first.window === window }
        XCTAssertTrue(first.surface === surface)
        XCTAssertTrue(text(surface).contains("BACKGROUND_ALIVE"))

        // Settings › Keys moves the number keys: ⌥⌘N then chooses a space, and ⌃N a tab in this space.
        controller.settings.values.keyGroups.spaces = [.option, .command]
        controller.settings.values.keyGroups.tabs = .control
        controller.settings.values.keyGroups.splits = [.control, .command]
        try await shortcut("1", keyCode: 18, modifiers: [.option, .command], window: window)
        XCTAssertEqual(workspace.selectedSpace, otherSpace)
        try await shortcut("9", keyCode: 25, modifiers: [.option, .command], window: window)
        XCTAssertEqual(workspace.selectedSpace, firstSpace, "The reordered first space is now the last")
        XCTAssertEqual(workspace.activeTab?.id, firstID)
        try await shortcut("2", keyCode: 19, modifiers: [.control], window: window)
        XCTAssertEqual(workspace.selectedSpace, firstSpace, "⌃2 chooses a tab, not a space")
        XCTAssertNotEqual(workspace.activeTab?.id, firstID)
        try await shortcut("1", keyCode: 18, modifiers: [.control], window: window)
        XCTAssertEqual(workspace.activeTab?.id, firstID)
        controller.settings.values.keyGroups = KeyGroups()

        var preferences = Preferences.flat
        preferences.fontSize = 17
        preferences.theme = "Catppuccin Mocha"
        preferences.lightTheme = "Builtin Light"
        preferences.appTheme = .light
        try runtime.apply(preferences)
        XCTAssertTrue(runtime.views[firstID]?.surface === surface)
        send("printf '\\nCONFIG_%s\\n' ALIVE\n", to: surface)
        try await eventually { self.text(surface).contains("CONFIG_ALIVE") }
        preferences.appTheme = .dark
        try runtime.apply(preferences)
        XCTAssertTrue(runtime.views[firstID]?.surface === surface)

        send("cd /tmp; printf '\\nDIRECTORY_%s\\n' READY\n", to: surface)
        try await eventually { workspace.activeTab?.directory == "/private/tmp" || workspace.activeTab?.directory == "/tmp" }
        workspace.newTab()
        XCTAssertTrue(["/tmp", "/private/tmp"].contains(workspace.activeTab!.directory))
        XCTAssertEqual(workspace.activeTab?.label, "tmp")

        workspace.selectTab(firstID)
        try await eventually { first.window === window }
        send("exit\n", to: surface)
        try await eventually { !workspace.allTabIDs.contains(firstID) && runtime.views[firstID] == nil }
        XCTAssertNil(first.surface)
        XCTAssertFalse(workspace.allTabIDs.isEmpty)

        try await setFullScreen(true, window: window)
        controller.showSettings()
        let settingsWindow = try XCTUnwrap(NSApp.windows.first { $0.title == "Settings" })
        XCTAssertFalse(settingsWindow.styleMask.contains(.miniaturizable))
        XCTAssertTrue(settingsWindow.styleMask.contains(.resizable))
        XCTAssertEqual(settingsWindow.minSize.width, settingsWindow.maxSize.width)
        XCTAssertTrue(settingsWindow.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(settingsWindow.standardWindowButton(.miniaturizeButton)?.isEnabled ?? false)
        XCTAssertFalse(settingsWindow.standardWindowButton(.zoomButton)?.isEnabled ?? false)
        try await eventually { settingsWindow.isKeyWindow && settingsWindow.isOnActiveSpace }
        XCTAssertTrue(window.styleMask.contains(.fullScreen), "Settings must stay in the full-screen Space")
        let spacesBeforeClosingSettings = workspace.spaces.map(\.id)
        try await shortcut("w", keyCode: 13, modifiers: [.command], window: settingsWindow)
        XCTAssertFalse(settingsWindow.isVisible)
        XCTAssertEqual(workspace.spaces.map(\.id), spacesBeforeClosingSettings)
        try await setFullScreen(false, window: window)
    }

    private func setFullScreen(_ enabled: Bool, window: NSWindow) async throws {
        let finished = expectation(description: enabled ? "Enter full screen" : "Exit full screen")
        let name = enabled ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
        let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in finished.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await eventually { window.isKeyWindow && NSApp.isActive && window.isOnActiveSpace }
        window.toggleFullScreen(nil)
        await fulfillment(of: [finished], timeout: 10)
    }

    private func shortcut(_ characters: String, ignoringModifiers: String? = nil, keyCode: UInt16,
                          modifiers: NSEvent.ModifierFlags, window: NSWindow, file: StaticString = #filePath, line: UInt = #line) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await eventually { NSApp.keyWindow === window }
        let event = TerminalTestSupport.keyEvent(keyCode, characters, in: window, modifiers: modifiers, ignoringModifiers: ignoringModifiers)
        XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: event) == true, "Shortcut was not handled by the menu", file: file, line: line)
    }

    private func send(_ value: String, to surface: any TerminalBackend) {
        let view = TerminalRuntime.shared.views.values.first { $0.surface === surface }!
        TerminalTestSupport.send(String(value.dropLast()), to: view)
    }

    // Keep the pointer and assertions on the test class's actor in optimized builds.
    private func expectVisibility(_ visible: Bool, terminal: TerminalView, surface: any TerminalBackend,
                                  pid: UInt64, sequence: inout Int,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        sequence += 1
        surface.text("q")
        let marker = "STATE_\(sequence)_\(visible ? 1 : 2)"
        try await TestSupport.eventually(file: file, line: line, diagnostic: self.text(surface)) {
            self.text(surface).contains(marker)
        }
        XCTAssertTrue(terminal.surface === surface, file: file, line: line)
        XCTAssertEqual(surface.foregroundPID, pid, file: file, line: line)
    }

    private func text(_ surface: any TerminalBackend) -> String {
        TerminalTestSupport.screen(surface: surface)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        try await TestSupport.eventually(timeout: .seconds(10), interval: .milliseconds(50), file: file, line: line,
                                         diagnostic: "Timed out waiting for terminal state", condition)
    }

    /// Stopping the runtime while a terminal floods output must not reach the stopped engine
    /// afterwards (queued wakeups, frames): stopped and started again repeatedly.
    func testEngineStopsCleanlyWhileTerminalsProduceOutput() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let runtime = TerminalRuntime.shared
        for _ in 0..<5 {
            runtime.start(preferences: Preferences())
            XCTAssertNil(runtime.error)
            let terminal = TerminalView(id: UUID(), directory: NSHomeDirectory(), launchCommand: "/usr/bin/yes", presentation: .standalone)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = terminal
            window.makeKeyAndOrderFront(nil)
            try await TestSupport.eventually { TerminalTestSupport.screen(terminal: terminal).contains("y\ny") }
            terminal.destroy()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            await runtime.stop().value
        }
    }
}
