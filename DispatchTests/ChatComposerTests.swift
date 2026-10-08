import AppKit
import SwiftUI
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import DispatchApp

@MainActor
final class ChatComposerTests: XCTestCase {
    func testWorkingBorderHighlightMovesClockwiseAcrossAllEdges() async throws {
        try DesktopTestSupport.requireUnlocked()
        @MainActor func border() -> some View {
            ChatComposerAnimatedBorder(accent: .white, moving: true).frame(width: 240, height: 120)
                .padding(12).background(Color.black)
        }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 264, height: 144),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: border())
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        var native: ChatComposerAnimatedBorder.BorderView?
        try await TestSupport.eventually {
            native = PresentationTestSupport.views(of: ChatComposerAnimatedBorder.BorderView.self, in: host).first
            return native?.bands.first?.animation(forKey: ChatComposerAnimatedBorder.BorderView.animationKey) != nil
        }
        let view = try XCTUnwrap(native)
        let animations = try view.bands.map {
            try XCTUnwrap($0.animation(forKey: ChatComposerAnimatedBorder.BorderView.animationKey) as? CABasicAnimation)
        }
        view.moving = false
        let points = [CGPoint(x: 132, y: 12.5), CGPoint(x: 251.5, y: 72),
                      CGPoint(x: 132, y: 131.5), CGPoint(x: 12.5, y: 72)]
        func brightness(_ bitmap: NSBitmapImageRep, at point: CGPoint) -> CGFloat {
            let x = Int(point.x * CGFloat(bitmap.pixelsWide) / 264)
            let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / 144)
            var brightest: CGFloat = 0
            for row in (y - 2)...(y + 2) {
                for column in (x - 2)...(x + 2) {
                    brightest = max(brightest, bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0)
                }
            }
            return brightest
        }
        var first: Data?
        for (index, phase) in [0.0, 0.25, 0.5, 0.75, 1.0].enumerated() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (band, animation) in zip(view.bands, animations) {
                let start = try XCTUnwrap(animation.fromValue as? CGFloat)
                let end = try XCTUnwrap(animation.toValue as? CGFloat)
                band.lineDashPhase = start + (end - start) * phase
            }
            CATransaction.commit()
            try await Task.sleep(for: .milliseconds(80))
            let snapshot = try await PresentationTestSupport.capture(window, named: "border-clockwise-\(index)", in: "chat-motion-validation")
            for (edge, point) in points.enumerated() {
                if edge == index % 4 {
                    XCTAssertGreaterThan(brightness(snapshot.bitmap, at: point), 0.35, "Highlight must move top → right → bottom → left")
                    let center = (-6...6).map { offset in
                        brightness(snapshot.bitmap, at: CGPoint(x: point.x + (edge.isMultiple(of: 2) ? CGFloat(offset) : 0),
                                                                y: point.y + (edge.isMultiple(of: 2) ? 0 : CGFloat(offset))))
                    }
                    XCTAssertLessThan(try XCTUnwrap(center.max()) - XCTUnwrap(center.min()), 0.06,
                                      "The center of the highlight must be smooth, without bright segment seams")
                } else {
                    XCTAssertLessThan(brightness(snapshot.bitmap, at: point), 0.1)
                }
            }
            let png = snapshot.bitmap.representation(using: .png, properties: [:])
            if index == 0 { first = png }
            if index == 4 { XCTAssertEqual(png, first, "The loop must wrap without a visible seam") }
        }
    }

    func testWorkingBorderAnimatesInCompositorAndStopsWhenDetached() async throws {
        try DesktopTestSupport.requireUnlocked()
        guard #available(macOS 14.4, *) else { throw XCTSkip("Composited capture requires macOS 14.4") }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 240, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = ChatComposerAnimatedBorder.BorderView(accent: .white)
        let key = ChatComposerAnimatedBorder.BorderView.animationKey
        window.backgroundColor = .black
        view.moving = true
        XCTAssertTrue(view.bands.allSatisfy { $0.animation(forKey: key) == nil })
        window.contentView = view; window.orderFront(nil)
        defer { view.stop(); window.orderOut(nil); window.contentView = nil; window.close() }
        try await TestSupport.eventually { view.bands.first?.animation(forKey: key) != nil }
        let band = try XCTUnwrap(view.bands.first)
        let animation = try XCTUnwrap(band.animation(forKey: key) as? CABasicAnimation)
        let fps = Float(max(1, window.screen?.maximumFramesPerSecond ?? 60))
        XCTAssertEqual(animation.preferredFrameRateRange.minimum, fps)
        XCTAssertEqual(animation.preferredFrameRateRange.maximum, fps)
        XCTAssertEqual(animation.preferredFrameRateRange.preferred, fps)
        XCTAssertEqual(animation.duration, 4)
        XCTAssertEqual(animation.timingFunction, CAMediaTimingFunction(name: .linear))
        XCTAssertNil(view.hitTest(.zero), "The animated border must not intercept composer input")
        CATransaction.flush()
        let shareable = try await SCShareableContent.currentProcess
        let ownWindow = try XCTUnwrap(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = 480; configuration.height = 240
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        try await Task.sleep(for: .milliseconds(120))
        // Capture WindowServer's actual frames while keeping the main run loop
        // blocked. CALayer.presentation() is cached until the next app transaction
        // and cannot establish whether the compositor continued delivering frames.
        let before = NSBitmapImageRep(cgImage: try BorderCompositorCapture.capture(filter, configuration))
        func occupyMainThread() { Thread.sleep(forTimeInterval: 0.2) }
        occupyMainThread()
        let after = NSBitmapImageRep(cgImage: try BorderCompositorCapture.capture(filter, configuration))
        var changed = 0
        for y in 0..<before.pixelsHigh {
            for x in 0..<before.pixelsWide {
                let a = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
                let b = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
                if abs(a - b) > 0.05 { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, 20, "The onscreen highlight must move while the main run loop is blocked")
        try PresentationTestSupport.save(before, named: "compositor-busy-main-before", in: "chat-motion-validation")
        try PresentationTestSupport.save(after, named: "compositor-busy-main-after", in: "chat-motion-validation")
        XCTAssertEqual(band.lineDashPhase, try XCTUnwrap(animation.fromValue as? CGFloat),
                       "Animation must not require per-frame model mutations")

        window.setContentSize(NSSize(width: 480, height: 120))
        view.layoutSubtreeIfNeeded()
        let resized = try XCTUnwrap(band.animation(forKey: key) as? CABasicAnimation)
        XCTAssertEqual(resized.duration, 4)
        XCTAssertNotEqual(resized.toValue as? CGFloat, animation.toValue as? CGFloat)
        view.moving = false
        XCTAssertTrue(view.bands.allSatisfy { $0.animation(forKey: key) == nil })
        view.moving = true
        XCTAssertNotNil(band.animation(forKey: key))
        window.orderOut(nil)
        try await TestSupport.eventually { band.animation(forKey: key) == nil }
        window.orderFront(nil)
        try await TestSupport.eventually { band.animation(forKey: key) != nil }
        window.contentView = nil
        XCTAssertTrue(view.bands.allSatisfy { $0.animation(forKey: key) == nil })
    }

    // In the app the chat sits inside nested hosting views, where each SwiftUI update
    // re-lays out the whole window: per-frame SwiftUI motion there exceeded AppKit's
    // Update Constraints pass limit while an agent worked on a long transcript.
    func testWorkingChatMovesInCompositorWithoutPerFrameSwiftUIUpdates() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let coordinator = ChatCoordinator(enabled: false)
        let session = coordinator.session(for: UUID())
        session.sessionID = UUID().uuidString; session.active = true; session.showChat = true; session.busy = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 916, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        let host = UpdateCountingHost(rootView: AnyView(ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false)
            .foregroundStyle(Chrome.ink).preferredColorScheme(.dark)))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        host.updates = 0
        try await Task.sleep(for: .seconds(1))
        let fps = window.screen?.maximumFramesPerSecond ?? 60
        XCTAssertLessThan(host.updates, fps / 4, "A working chat must not update SwiftUI every display frame")
        let key = CompositorView.animationKey
        let orbit = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposerOrbit.OrbitView.self, in: host).first)
        let shimmer = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposerShimmer.ShimmerView.self, in: host).first)
        let loops = [orbit.diamond, orbit.orbit, shimmer.band].map { $0.animation(forKey: key) }
        XCTAssertEqual(loops.map { $0?.duration }, [1.6, 1.4, 2.4], "Pulse, orbit and sweep keep their periods")
        XCTAssertEqual(loops.map { $0?.preferredFrameRateRange.preferred }, Array(repeating: Float(fps), count: 3))
        XCTAssertNil(orbit.hitTest(.zero)); XCTAssertNil(shimmer.hitTest(.zero))
        session.busy = false
        try await TestSupport.eventually { [orbit.diamond, orbit.orbit, shimmer.band].allSatisfy { $0.animation(forKey: key) == nil } }
    }

    func testPlaceholderStaysStableAcrossReasoningAndToolActivity() async throws {
        try DesktopTestSupport.requireUnlocked()
        let coordinator = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = coordinator.session(for: UUID())
        session.active = true; session.showChat = true; session.busy = true
        session.activeTurnID = "working-placeholder"
        let draftRevision = session.drafts.current.revision
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil; coordinator.stop() }
        NSApp.activate(ignoringOtherApps: true)
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually { window.firstResponder is ChatComposer.ComposerTextView }
        let editor = try XCTUnwrap(window.firstResponder as? ChatComposer.ComposerTextView)
        let activity: [ChatItem] = [
            .init(id: "thought", kind: .reasoning, text: "Checking whether the commit should include the lockfile"),
            .init(id: "exec", kind: .tool, text: "text(await tools.exec_command({cmd: 'git status'}));", title: "exec"),
            .init(id: "sleep", kind: .tool, text: #"{"duration_ms":1000}"#, title: "sleep"),
            .init(id: "shell", kind: .tool, text: #"{"cmd":"git status"}"#, title: "exec_command"),
            .init(id: "unknown", kind: .tool, text: "{}", title: "another_tool")
        ]
        for item in activity {
            session.turns = [.init(id: "working-placeholder", items: [item])]
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(editor.displayedPlaceholder, "Reply…", item.title)
            XCTAssertEqual(editor.string, ""); XCTAssertEqual(session.draft, "")
            XCTAssertEqual(session.drafts.current.revision, draftRevision)
            XCTAssertFalse(editor.undoManager?.canUndo == true)
        }
        editor.insertText("My draft", replacementRange: editor.selectedRange())
        let selection = editor.selectedRange()
        session.insert(.init(id: "new-thought", kind: .reasoning, text: "A later reasoning summary"), turnID: "working-placeholder")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(editor.string, "My draft"); XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(session.draft, "My draft")
        XCTAssertTrue(window.firstResponder === editor)
        session.draft = ""
        try await TestSupport.eventually { editor.string.isEmpty }
        editor.setMarkedText("未確定", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.insertText("Confirmed", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(session.draft, "Confirmed")
        session.busy = false; session.draft = ""
        try await TestSupport.eventually { editor.string.isEmpty && editor.displayedPlaceholder == "Reply…" }
        let snapshot = try await PresentationTestSupport.capture(window, named: "stable-reply-placeholder", in: "chat-motion-validation")
        XCTAssertFalse(try snapshot.text().contains("A later reasoning summary"))
        XCTAssertTrue(try snapshot.text().contains("Reasoning summary"))
    }

    func testLocalCaretTracksNativeGeometryEditingAndFocus() async throws {
        try DesktopTestSupport.requireUnlocked()
        let coordinator = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = coordinator.session(for: UUID())
        session.active = true; session.showChat = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil; coordinator.stop() }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually { window.isKeyWindow && window.firstResponder is ChatComposer.ComposerTextView }
        let editor = try XCTUnwrap(window.firstResponder as? ChatComposer.ComposerTextView)
        XCTAssertFalse(editor.shouldDrawInsertionPoint)

        func checkGeometry(line: UInt = #line) async throws {
            try await TestSupport.eventually(line: line,
                diagnostic: "Caret: timer=\(editor.caretTimer != nil), on=\(editor.caretOn), key=\(window.isKeyWindow), focused=\(window.firstResponder === editor), selection=\(editor.selectedRange()), marked=\(editor.hasMarkedText()), rect=\(editor.caretRect), native=\(editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)), visible=\(editor.visibleRect)") {
                editor.caretTimer != nil && editor.caretOn
            }
            window.contentView?.layoutSubtreeIfNeeded()
            editor.displayIfNeeded()
            let native = editor.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)), from: nil)
            XCTAssertEqual(editor.caretRect.minX, native.minX, accuracy: 1 / window.backingScaleFactor)
            XCTAssertEqual(editor.caretRect.minY, native.minY, accuracy: 1 / window.backingScaleFactor)
            XCTAssertEqual(editor.caretRect.height, native.height, accuracy: 1 / window.backingScaleFactor)
            XCTAssertEqual(editor.caretRect.width, 1)
            XCTAssertGreaterThan(editor.caretRect.height, 5)
        }

        try await checkGeometry() // Empty editor and placeholder.
        try await TestSupport.eventually { !editor.caretOn }
        try await TestSupport.eventually { editor.caretOn } // Actually blinks, not a stuck painted caret.
        for value in ["Reply", "First line\n", "Emoji 👩🏽‍💻 e\u{301} 日本語", "עברית العربية", String(repeating: "Wrapped text ", count: 30)] {
            editor.selectAll(nil)
            editor.insertText(value, replacementRange: editor.selectedRange())
            editor.scrollRangeToVisible(editor.selectedRange())
            try await checkGeometry()
            XCTAssertEqual(session.draft, value)
        }
        window.setContentSize(NSSize(width: 390, height: 480))
        try await Task.sleep(for: .milliseconds(150))
        try await checkGeometry()
        editor.setSelectedRange(NSRange(location: 2, length: 5))
        try await TestSupport.eventually { editor.caretTimer == nil && !editor.caretOn }
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        // This location is above the scrolled viewport after narrowing. AppKit
        // returns a zero input-client rect until it is brought into view.
        editor.scrollRangeToVisible(editor.selectedRange())
        try await checkGeometry()

        editor.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        try await checkGeometry()
        editor.insertText("入力", replacementRange: editor.markedRange())
        XCTAssertFalse(editor.hasMarkedText())
        try await checkGeometry()
        _ = try await PresentationTestSupport.capture(window, named: "composer-local-caret", in: "chat-validation")

        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually { !window.isKeyWindow && editor.caretTimer == nil && !editor.caretOn }
        window.makeKeyAndOrderFront(nil)
        try await checkGeometry()
        window.makeFirstResponder(nil)
        XCTAssertNil(editor.caretTimer); XCTAssertFalse(editor.caretOn)
        window.makeFirstResponder(editor)
        try await checkGeometry()
        let timer = try XCTUnwrap(editor.caretTimer)
        window.contentView = nil
        XCTAssertNil(editor.caretTimer); XCTAssertFalse(timer.isValid)
    }

    func testUnreadActivityFollowsMountedTabsAndSpaces() async throws {
        try DesktopTestSupport.requireUnlocked()
        let restore = TestSupport.preserveRuntime()
        defer { restore() }
        let runtime = TerminalRuntime.shared, originalChat = runtime.chat
        let coordinator = ChatCoordinator(enabled: false)
        runtime.chat = coordinator
        let controller = AppDelegate(), workspace = controller.workspace
        runtime.workspace = workspace
        runtime.start(preferences: Preferences())
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newSpace()
        let firstSpace = try XCTUnwrap(workspace.selectedSpace), firstTab = try XCTUnwrap(workspace.activeTab?.id)
        let session = coordinator.session(for: firstTab)
        session.sessionID = UUID().uuidString; session.showChat = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close(); window.contentView = nil
            runtime.stop(); runtime.chat = originalChat
        }
        try await TestSupport.eventually { session.isPresented && session.atBottom }
        workspace.newTab()
        try await TestSupport.eventually { !session.isPresented }
        session.insert(ChatItem(id: "tab", kind: .assistant, text: "Finished in the other tab"), turnID: "turn")
        XCTAssertTrue(session.hasNewMessages)
        workspace.selectTab(firstTab)
        try await TestSupport.eventually { session.isPresented && !session.hasNewMessages }

        workspace.newSpace()
        try await TestSupport.eventually { !session.isPresented }
        session.insert(ChatItem(id: "space", kind: .assistant, text: "Finished in the other space"), turnID: "turn")
        XCTAssertTrue(session.hasNewMessages)
        workspace.selectSpace(firstSpace)
        try await TestSupport.eventually { session.isPresented && !session.hasNewMessages }

        coordinator.chooseChat(false, session: session)
        session.insert(ChatItem(id: "terminal", kind: .assistant, text: "Visible in terminal mode"), turnID: "turn")
        XCTAssertFalse(session.hasNewMessages)
    }

    func testComposerFocusSurvivesMountingAfterItsFirstUpdate() async throws {
        try DesktopTestSupport.requireUnlocked()
        let coordinator = ChatCoordinator(enabled: true)
        let session = coordinator.session(for: UUID())
        session.active = true; session.showChat = true
        let host = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        let container = NSView(frame: host.frame), placeholder = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        container.addSubview(placeholder); window.contentView = container
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(placeholder)
        container.addSubview(host)
        try await TestSupport.eventually { window.firstResponder is ChatComposer.ComposerTextView }
        let editor = try XCTUnwrap(window.firstResponder as? ChatComposer.ComposerTextView)
        session.sessionID = "main"
        // An optional (non-blocking) question, as the helper delivers it.
        let optional = try ChatSideQuestion.helper(["id": "optional", "approval": false, "blocking": false, "questions": [
            ["id": "details", "header": "Details", "text": "Any details?", "secret": false, "multiple": false, "custom": true, "options": []]]], session: "main")
        session.questions = [optional]
        XCTAssertEqual(session.questions.count, 1)
        window.makeFirstResponder(placeholder)
        window.makeFirstResponder(editor)
        XCTAssertTrue(window.firstResponder === editor, "Optional questions must leave the composer editable")
        editor.insertText("Independent draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(session.draft, "Independent draft")
        let blocking = try ChatSideQuestion.helper(["id": "blocking", "approval": false, "blocking": true, "questions": [
            ["id": "details", "header": "Details", "text": "Required details?", "secret": false, "multiple": false, "custom": true, "options": []]]], session: "main")
        session.questions = [blocking]
        window.makeFirstResponder(placeholder)
        window.makeFirstResponder(editor)
        XCTAssertFalse(window.firstResponder === editor, "Blocking question focus remains with its form")
    }

    func testNativePlaceholderMatchesTypedTextAndCompactComposer() async throws {
        let glass = LiquidGlassStore.shared.enabled
        defer { LiquidGlassStore.shared.enabled = glass }
        // Glyph brightness bounds require the classic uniform background, not reflective glass.
        LiquidGlassStore.shared.enabled = false
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let coordinator = ChatCoordinator(enabled: false)
        let session = coordinator.session(for: UUID())
        session.sessionID = UUID().uuidString; session.active = true; session.showChat = true
        session.model = "gpt-6-astra"; session.effort = "high"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 916, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false)
            .foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        func capture(_ name: String) async throws -> PresentationTestSupport.Snapshot {
            try await Task.sleep(for: .milliseconds(250))
            return try await PresentationTestSupport.capture(window, named: name, in: "chat-validation")
        }
        try await TestSupport.eventually { window.firstResponder is ChatComposer.ComposerTextView }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        // The current theme may give the caret the same color as typed text.
        // Remove it from both captures rather than treating its pixels as ink.
        let caretColor = editor.insertionPointColor
        editor.insertionPointColor = .clear
        defer { editor.insertionPointColor = caretColor }
        let empty = try await capture("composer-empty")
        let view = try XCTUnwrap(window.contentView), scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertEqual(scroll.frame.height, 28, accuracy: 1)
        let scrollFrame = scroll.convert(scroll.bounds, to: view)
        XCTAssertEqual(scrollFrame.minX, 22, accuracy: 1,
            "The editor spans the field; text uses its native inset")
        XCTAssertEqual(scrollFrame.maxX, view.bounds.maxX - 22, accuracy: 1,
            "The action row sits below the full-width editor")
        let footer = try empty.text()
        XCTAssertFalse(footer.contains("codex")); XCTAssertFalse(footer.contains("gpt-6-astra"))
        XCTAssertTrue(footer.contains("astra")); XCTAssertTrue(footer.contains("high"), "Effort uses text when the footer has room")
        let editorFrame = editor.convert(editor.visibleRect, to: view)
        let insertion = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        session.draft = "Reply…"
        let typed = try await capture("composer-typed")
        let typedInsertion = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        XCTAssertEqual(insertion.minX, typedInsertion.minX, accuracy: 0.5)
        XCTAssertEqual(insertion.minY, typedInsertion.minY, accuracy: 0.5)
        // OCR's whole-line bounds vary with the placeholder's lower contrast.
        // Inspect actual glyph pixels in the editor, normalizing the threshold
        // to each foreground color. The insertion caret is transparent above.
        let placeholder = try glyphBounds(empty.bitmap, editorFrame: editorFrame, in: view)
        let glyphs = try glyphBounds(typed.bitmap, editorFrame: editorFrame, in: view)
        XCTAssertEqual(placeholder.minX, glyphs.minX, accuracy: 1, "Placeholder and typed glyphs align within one physical pixel")
        XCTAssertEqual(placeholder.minY, glyphs.minY, accuracy: 1, "Placeholder and typed glyphs share the same top")
        XCTAssertEqual(placeholder.maxY, glyphs.maxY, accuracy: 1, "Placeholder and typed glyphs share the same baseline")
        session.draft = "First line\nSecond line"
        _ = try await capture("composer-multiline")
        XCTAssertEqual(editor.enclosingScrollView?.frame.height ?? 0, session.composerHeight, accuracy: 1)
    }

    // A font with its own leading laid out a typed line taller than the
    // empty editor's line: the composer grew 1 pt and the caret jumped on the first character.
    func testFirstCharacterKeepsCaretAndComposerHeightForEveryChatFont() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let previousTheme = ChatThemeStore.shared.current
        defer { ChatThemeStore.shared.current = previousTheme }
        for font in ChatFont.allCases {
            var preferences = Preferences()
            preferences.chatFont = font
            ChatThemeStore.shared.current.typography = ChatTypography(preferences: preferences)
            let coordinator = ChatCoordinator(enabled: false)
            let session = coordinator.session(for: UUID())
            session.sessionID = UUID().uuidString; session.active = true; session.showChat = true
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 916, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close(); window.contentView = nil }
            window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false))
            window.makeKeyAndOrderFront(nil)
            try await TestSupport.eventually { window.firstResponder is ChatComposer.ComposerTextView }
            let editor = try XCTUnwrap(window.firstResponder as? ChatComposer.ComposerTextView)
            func settled() async throws -> (caret: NSRect, height: CGFloat) {
                try await Task.sleep(for: .milliseconds(250))
                return (editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil),
                        try XCTUnwrap(editor.enclosingScrollView).frame.height)
            }
            let empty = try await settled()
            session.draft = "Reply…"
            let typed = try await settled()
            XCTAssertEqual(empty.caret, typed.caret, "\(font): the caret stays where the placeholder was")
            XCTAssertEqual(empty.height, typed.height, "\(font): the composer keeps its height")
        }
    }

    private func glyphBounds(_ bitmap: NSBitmapImageRep, editorFrame: NSRect, in view: NSView) throws -> NSRect {
        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let top = view.isFlipped ? editorFrame.minY : view.bounds.height - editorFrame.maxY
        let minX = max(0, Int(editorFrame.minX * scaleX))
        let maxX = min(bitmap.pixelsWide, Int((editorFrame.minX + 100) * scaleX))
        let minY = max(0, Int(top * scaleY))
        let maxY = min(bitmap.pixelsHigh, Int((top + editorFrame.height) * scaleY))
        var pixels: [(x: Int, y: Int, brightness: CGFloat)] = []
        for y in minY..<maxY {
            for x in minX..<maxX {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                if channels.max()! - channels.min()! < 0.12 {
                    pixels.append((x, y, channels.reduce(0, +) / 3))
                }
            }
        }
        let background = try XCTUnwrap(pixels.map(\.brightness).min())
        let foreground = try XCTUnwrap(pixels.map(\.brightness).max())
        XCTAssertGreaterThan(foreground - background, 0.25, "The capture must contain visible text")
        let ink = pixels.filter { $0.brightness > background + (foreground - background) * 0.35 }
        let left = try XCTUnwrap(ink.map(\.x).min()), right = try XCTUnwrap(ink.map(\.x).max())
        let first = try XCTUnwrap(ink.map(\.y).min()), last = try XCTUnwrap(ink.map(\.y).max())
        return NSRect(x: left, y: first, width: right - left + 1, height: last - first + 1)
    }

    func testRecordedModelEffortLoadsOutsideRecentPageAndHistoryCannotRevertIt() async throws {
        let id = UUID().uuidString
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-effort-\(id).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        func line(_ type: String, _ payload: [String: Any]) throws -> Data {
            var bytes = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2000-01-01T00:00:00.000Z", "payload": payload])
            bytes.append(10); return bytes
        }
        var data = try line("session_meta", ["id": id, "cli_version": "0.153.4"])
        data += try line("turn_context", ["turn_id": "old", "model": "old-model", "effort": "medium"])
        data += try line("turn_context", ["turn_id": "current", "model": "gpt-6-astra", "effort": "high"])
        // More records than the harness's first history page (400).
        for index in 0..<450 { data += try line("event_msg", ["type": "agent_message", "turn_id": "current", "message": "Message \(index)"]) }
        try data.write(to: path)
        let coordinator = ChatCoordinator(enabled: false)
        let session = coordinator.session(for: UUID())
        session.sessionID = id; session.transcriptPath = path.path
        coordinator.start(); defer { coordinator.stop() }
        try await TestSupport.eventually(timeout: .seconds(3), diagnostic: "Composer state timed out") { session.effort == "high" }
        XCTAssertEqual(session.model, "gpt-6-astra"); XCTAssertTrue(session.hasEarlier)
        let writer = try FileHandle(forWritingTo: path)
        try writer.seekToEnd()
        try writer.write(contentsOf: line("turn_context", ["turn_id": "next", "model": "gpt-6-astra", "effort": "low"]))
        try await TestSupport.eventually(timeout: .seconds(3), diagnostic: "Composer state timed out") { session.effort == "low" }
        coordinator.loadEarlier(session)
        try await TestSupport.eventually(timeout: .seconds(3), diagnostic: "Composer state timed out") { !session.loadingEarlier }
        XCTAssertEqual(session.effort, "low"); XCTAssertEqual(session.model, "gpt-6-astra")
        try writer.write(contentsOf: line("turn_context", ["turn_id": "unknown", "model": "different-model"]))
        try writer.close()
        try await TestSupport.eventually(timeout: .seconds(3), diagnostic: "Composer state timed out") { session.model == "different-model" }
        XCTAssertNil(session.effort, "Missing effort must clear the previous model's value")
        session.effort = "high"; session.resetConversation(); XCTAssertNil(session.effort)
    }
}

extension ChatComposerTests {
    func testComposer4aNarrowWrappingScrollingThemesAndEditorIdentity() async throws {
        try DesktopTestSupport.requireUnlocked()
        let previousTheme = ChatThemeStore.shared.current
        defer { ChatThemeStore.shared.current = previousTheme }
        let chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID()); session.sessionID = "composer-4a"; session.showChat = true; session.active = true
        for index in 1...8 { session.draft = "Draft \(index)"; session.drafts.keep() }
        session.draft = "Guard on the event id:\n```ts\nconst seen = await redis.set(event.id, true);\nif (seen) return;\n```\nThen add a regression test."
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; chat.stop() }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: chat, focused: true, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually { window.firstResponder is ChatComposer.ComposerTextView }
        let editor = try XCTUnwrap(window.firstResponder as? ChatComposer.ComposerTextView)
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        let snapshot = try await PresentationTestSupport.capture(window, named: "composer-4a-dark", in: "chat-validation")
        let text = try snapshot.text()
        XCTAssertFalse(text.contains("commands"), text)
        XCTAssertTrue(text.contains("drafts"), text)
        XCTAssertTrue(text.contains("Send"), text)
        for light in [true, false] {
            var theme = ChatTheme.standard
            if light {
                theme.isDark = false; theme.terminal = Color(white: 0.92); theme.window = .white; theme.sidebar = .white
                theme.selection = .blue.opacity(0.25); theme.selectedText = .black
                theme.ink = .black; theme.muted = Color(white: 0.4); theme.keyword = .purple
            }
            ChatThemeStore.shared.current = theme
            window.setContentSize(NSSize(width: light ? 390 : 720, height: light ? 420 : 650))
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))
            XCTAssertTrue(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: try XCTUnwrap(window.contentView)).first === editor)
            _ = try await PresentationTestSupport.capture(window, named: light ? "composer-4a-narrow-light" : "composer-4a-wide-dark", in: "chat-validation")
            XCTAssertLessThanOrEqual(try XCTUnwrap(editor.enclosingScrollView).frame.height, min(320, (light ? 420 : 650) * 0.4) + 1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(window.contentView).frame.width, light ? 391 : 721)
        }
        session.draft = String(repeating: "Long wrapped input needs scrolling. ", count: 150)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(session.composerHeight, 320)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertGreaterThan(editor.frame.height, scroll.contentSize.height)
        XCTAssertTrue(window.firstResponder === editor)
        editor.undoManager?.beginUndoGrouping()
        editor.insertText("next", replacementRange: NSRange(location: 0, length: 0))
        editor.undoManager?.endUndoGrouping()
        window.setContentSize(NSSize(width: 420, height: 420))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        XCTAssertFalse(editor.string.hasPrefix("next"))
        editor.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        window.setContentSize(NSSize(width: 500, height: 500))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(editor.hasMarkedText()); XCTAssertTrue(window.firstResponder === editor)
        editor.unmarkText()
    }
}

/// The completion runs off the main thread. Waiting here intentionally prevents
/// the app from producing animation frames; only WindowServer can animate them.
private final class BorderCompositorCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<CGImage, Error>?

    static func capture(_ filter: SCContentFilter, _ configuration: SCStreamConfiguration) throws -> CGImage {
        let capture = BorderCompositorCapture()
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
            capture.lock.withLock {
                if let image { capture.result = .success(image) }
                else { capture.result = .failure(error ?? NSError(domain: "BorderCompositorCapture", code: 1)) }
            }
            capture.ready.signal()
        }
        guard capture.ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "BorderCompositorCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Timed out capturing the compositor while the main thread was blocked"])
        }
        return try capture.lock.withLock { try XCTUnwrap(capture.result).get() }
    }
}

/// Counts SwiftUI's update work in its host: each update schedules constraints and layout.
private final class UpdateCountingHost: NSHostingView<AnyView> {
    var updates = 0
    override func updateConstraints() { updates += 1; super.updateConstraints() }
    override func layout() { updates += 1; super.layout() }
}
