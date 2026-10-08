import AppKit
import SwiftUI
import XCTest
@preconcurrency import ScreenCaptureKit
@testable import DispatchApp

@MainActor
final class InterfaceMotionTests: XCTestCase {
    func testChatArrivalsExcludeHistoryStreamingAndAcknowledgedPrompts() throws {
        let session = ChatSession(id: UUID())
        session.showChat = true
        // Every row here arrives at once; the burst rule has its own test.
        session.transcriptArrivals.burstInterval = 0
        let opened = ProcessInfo.processInfo.systemUptime
        var reply = ChatItem(id: "reply", kind: .assistant, text: "Hello")
        session.insert(reply, turnID: "live")
        let row = try XCTUnwrap(session.visibleTranscriptRows.first)
        let receipt = try XCTUnwrap(session.transcriptArrivals.receipt(for: row.id))
        XCTAssertTrue(receipt.consume(since: opened))
        reply.text += " again"
        session.insert(reply, turnID: "live")
        XCTAssertTrue(session.transcriptArrivals.receipt(for: row.id) === receipt)
        XCTAssertFalse(receipt.consume(since: opened), "Streaming or remounting must not replay an entrance")

        session.busy = true; session.activeTurnID = "live"
        session.insert(.init(id: "step", kind: .tool, text: "{}", title: "exec_command"), turnID: "live")
        let step = try XCTUnwrap(session.visibleTranscriptRows.first { $0.item?.id == "step" })
        let stepReceipt = try XCTUnwrap(session.transcriptArrivals.receipt(for: step.id))
        XCTAssertFalse(stepReceipt.eligible(since: stepReceipt.time + 0.01), "Opening a chat must show existing rows immediately")
        XCTAssertFalse(stepReceipt.eligible(since: opened, now: stepReceipt.time + 0.6), "Scrolling to a late-mounted row must not animate it")
        XCTAssertTrue(receipt.consumed, "Adding a step must not restart its parent message")
        // Without a message to hold them, a second live step turns the shown step into a group
        // under a new header, which enters with the new step.
        session.activeTurnID = "work"
        session.insert(.init(id: "first", kind: .tool, text: "{}", title: "exec_command"), turnID: "work")
        let first = try XCTUnwrap(session.visibleTranscriptRows.first { $0.item?.id == "first" })
        let firstReceipt = try XCTUnwrap(session.transcriptArrivals.receipt(for: first.id))
        XCTAssertTrue(firstReceipt.consume(since: opened))
        session.insert(.init(id: "second", kind: .tool, text: "{}", title: "exec_command"), turnID: "work")
        let header = try XCTUnwrap(session.visibleTranscriptRows.first { $0.group != nil && $0.item == nil && $0.turnID == "work" })
        XCTAssertTrue(session.transcriptArrivals.receipt(for: header.id)?.eligible(since: opened) == true)
        XCTAssertTrue(session.transcriptArrivals.receipt(for: first.id) === firstReceipt, "The shown step keeps its row and finished entrance")

        session.insert(.init(id: "old", kind: .assistant, text: "Earlier"), turnID: "old", historical: true)
        let old = try XCTUnwrap(session.visibleTranscriptRows.first { $0.item?.id == "old" })
        XCTAssertNil(session.transcriptArrivals.receipt(for: old.id))
        session.atBottom = false
        session.insert(.init(id: "offscreen", kind: .assistant, text: "Later"), turnID: "live")
        let offscreen = try XCTUnwrap(session.visibleTranscriptRows.first { $0.item?.id == "offscreen" })
        XCTAssertNil(session.transcriptArrivals.receipt(for: offscreen.id))

        session.atBottom = true
        session.optimisticPrompt = .init(id: "optimistic", kind: .user, text: "Next question")
        let promptReceipt = try XCTUnwrap(session.transcriptArrivals.receipt(for: "optimistic"))
        XCTAssertTrue(promptReceipt.consume(since: opened))
        session.insert(session.reconcilePrompt(.init(id: "confirmed", kind: .user, text: "Next question")), turnID: "next")
        XCTAssertTrue(session.transcriptArrivals.receipt(for: "optimistic") === promptReceipt)
        XCTAssertFalse(promptReceipt.consume(since: opened))
        session.resetConversation()
        XCTAssertNil(session.transcriptArrivals.receipt(for: "optimistic"))
    }

    func testChatArrivalBurstsMoveOnlyTheirFirstRow() throws {
        let session = ChatSession(id: UUID())
        session.showChat = true
        func receipt(_ id: String) -> ChatTranscriptArrivals.Receipt? {
            session.visibleTranscriptRows.first { $0.item?.id == id }.flatMap { session.transcriptArrivals.receipt(for: $0.id) }
        }
        session.insert(.init(id: "first", kind: .assistant, text: "First"), turnID: "live")
        session.insert(.init(id: "second", kind: .assistant, text: "Second"), turnID: "live")
        XCTAssertNotNil(receipt("first"), "A burst's first row enters")
        XCTAssertNil(receipt("second"), "The rest of the burst appears in place")
        let arrivals = session.transcriptArrivals
        XCTAssertFalse(arrivals.admitsMotion(now: ProcessInfo.processInfo.systemUptime + arrivals.burstInterval / 2))
        XCTAssertTrue(arrivals.admitsMotion(now: ProcessInfo.processInfo.systemUptime + arrivals.burstInterval),
                      "A row after a quiet interval enters again")
        session.resetConversation()
        session.atBottom = true
        session.optimisticPrompt = .init(id: "prompt", kind: .user, text: "Next")
        XCTAssertNotNil(session.transcriptArrivals.receipt(for: "prompt"), "The user's own prompt always enters")
        session.insert(.init(id: "reply", kind: .assistant, text: "Reply"), turnID: "next")
        XCTAssertNil(receipt("reply"), "A reply right after the prompt joins its entrance")
    }

    func testChatArrivalFadesAndMovesWithoutChangingLayoutAndReducedMotionOnlyFades() async throws {
        try DesktopTestSupport.requireUnlocked()
        guard #available(macOS 14.4, *) else { throw XCTSkip("Composited capture requires macOS 14.4") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        window.contentView = NSHostingView(rootView: Color.black)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        let shareable = try await SCShareableContent.currentProcess
        let ownWindow = try XCTUnwrap(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        func screenFrame() async throws -> PresentationTestSupport.Snapshot {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
            return PresentationTestSupport.Snapshot(bitmap: NSBitmapImageRep(cgImage: image))
        }
        for (reduce, diff) in [(false, false), (true, false), (false, true), (true, true)] {
            let receipt = ChatTranscriptArrivals.Receipt(time: ProcessInfo.processInfo.systemUptime)
            let host = NSHostingView(rootView: Color.white.frame(width: 100, height: 20)
                .modifier(ChatArrivalMotion(receipt: receipt, since: receipt.time, reduceMotion: reduce,
                                            distance: diff ? 4 : nil, duration: diff ? 0.25 : nil))
                .frame(width: 200, height: 100).background(Color.black))
            window.contentView = host
            let size = host.fittingSize
            var frames: [PresentationTestSupport.Snapshot] = []
            for _ in 0..<16 {
                try await Task.sleep(for: .milliseconds(20))
                frames.append(try await screenFrame())
            }
            let settled = try await screenFrame()
            try PresentationTestSupport.save(settled.bitmap, named: "chat-arrival-\(reduce)-\(diff)-settled", in: "motion-validation")
            XCTAssertEqual(host.fittingSize, size, "Entrances must not change transcript geometry")
            func pixels(_ snapshot: PresentationTestSupport.Snapshot) -> (brightness: CGFloat, center: CGFloat) {
                let bitmap = snapshot.bitmap
                var brightness: CGFloat = 0, weightedY: CGFloat = 0
                for y in 0..<bitmap.pixelsHigh {
                    let value = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
                    brightness += value; weightedY += CGFloat(y) * value
                }
                return (brightness, weightedY / max(brightness, 0.001))
            }
            let after = pixels(settled)
            let moving = try XCTUnwrap(frames.first {
                let value = pixels($0)
                return value.brightness > 1 && value.brightness < after.brightness - 1
            }, "The entrance must have a visible intermediate fade")
            try PresentationTestSupport.save(moving.bitmap, named: "chat-arrival-\(reduce)-\(diff)-during", in: "motion-validation")
            let before = pixels(moving)
            if reduce {
                XCTAssertEqual(before.center, after.center, accuracy: 0.5, "Reduce Motion must remove translation")
            } else {
                XCTAssertGreaterThan(abs(before.center - after.center), 0.5, "New messages should rise gently into place")
            }
        }
    }

    func testSpaceNavigationDoesNotRetainAnOutgoingBitmap() async throws {
        try DesktopTestSupport.requireUnlocked()
        let first = UUID(), second = UUID(), pane = UUID()
        let view = MotionContentView(content: AnyView(Text("Outgoing chat")), identity: "first", spaceID: first, layout: .pane(pane))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        let host = view.host
        view.update(AnyView(Text("Destination")), identity: "second", spaceID: second, layout: .pane(pane), animated: true)
        XCTAssertTrue(view.host === host)
        XCTAssertFalse(view.subviews.contains { $0 is NSImageView }, "Space selection must mount immediately without capturing or fading the outgoing chat")
        let split = PaneLayout.split(UUID(), .columns, .pane(pane), .pane(UUID()))
        view.update(AnyView(Text("Split layout")), identity: "split", spaceID: second, layout: split, animated: true)
        XCTAssertTrue(view.subviews.contains { $0 is NSImageView }, "Layout changes within the same space retain their transition")
    }

    func testHostNavigationCrossfadesGridWithoutMovingSidebarAndCanBeInterrupted() async throws {
        try DesktopTestSupport.requireUnlocked()
        guard #available(macOS 14.4, *) else { throw XCTSkip("Composited capture requires macOS 14.4") }
        func grid(_ color: Color) -> AnyView {
            AnyView(VStack(spacing: 2) {
                HStack(spacing: 2) { color; color }
                HStack(spacing: 2) { color; color }
            }.background(Color.black))
        }
        let red = Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
        let blue = Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1)
        let green = Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 1)
        let first = UUID(), second = UUID(), pane = UUID()
        let firstHost = HostID.authenticated("fade-first"), secondHost = HostID.authenticated("fade-second")
        let view = MotionContentView(content: grid(red), identity: "first", spaceID: first,
                                     layout: .pane(pane), hostID: firstHost)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.green.cgColor
        view.frame = NSRect(x: 80, y: 0, width: 320, height: 240)
        root.addSubview(view)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let shareable = try await SCShareableContent.currentProcess
        let ownWindow = try XCTUnwrap(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = 400; configuration.height = 240
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        func capture() async throws -> NSBitmapImageRep {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
            return NSBitmapImageRep(cgImage: image)
        }
        let before = try await capture()
        XCTAssertGreaterThan(try XCTUnwrap(before.colorAt(x: 120, y: 60)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        let host = view.host
        view.update(grid(blue), identity: "second", spaceID: second, layout: .pane(pane), animated: true, hostID: secondHost)
        XCTAssertTrue(view.host === host)
        XCTAssertFalse(view.subviews.contains { $0 is NSImageView }, "Host switches must not rasterize the outgoing transcript")
        XCTAssertEqual(try XCTUnwrap(view.layer?.animation(forKey: kCATransition)).duration, 0.1)
        var blended: NSBitmapImageRep?
        for _ in 0..<8 {
            let frame = try await capture()
            let sidebar = try XCTUnwrap(frame.colorAt(x: 40, y: 60)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(sidebar.greenComponent, 0.9)
            for (x, y) in [(120, 60), (280, 60), (120, 180), (280, 180)] {
                let color = try XCTUnwrap(frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.redComponent > 0.05 && color.blueComponent > 0.05 { blended = frame }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try PresentationTestSupport.save(try XCTUnwrap(blended, "The grid must visibly blend between hosts"),
                                         named: "host-grid-crossfade", in: "motion-validation")
        let after = try await capture()
        XCTAssertGreaterThan(try XCTUnwrap(after.colorAt(x: 120, y: 60)?.usingColorSpace(.deviceRGB)).blueComponent, 0.9)
        XCTAssertNil(view.layer?.animation(forKey: kCATransition))
        view.update(grid(red), identity: "first", spaceID: first, layout: .pane(pane), animated: true, hostID: firstHost)
        view.update(grid(blue), identity: "second", spaceID: second, layout: .pane(pane), animated: false, hostID: secondHost)
        XCTAssertNil(view.layer?.animation(forKey: kCATransition), "Reduce Motion cancels an in-flight fade")
        view.update(grid(red), identity: "first", spaceID: first, layout: .pane(pane), animated: true, hostID: firstHost)
        view.update(grid(green), identity: "same-host", spaceID: UUID(), layout: .pane(pane), animated: true, hostID: firstHost)
        XCTAssertNil(view.layer?.animation(forKey: kCATransition), "Same-host navigation cancels an old fade without starting another")
        try await Task.sleep(for: .milliseconds(150))
        let final = try await capture()
        XCTAssertGreaterThan(try XCTUnwrap(final.colorAt(x: 120, y: 60)?.usingColorSpace(.deviceRGB)).greenComponent, 0.9)
    }

    func testTabNavigationSkipsSnapshotsWithSharedPanesAndCancelsLayoutAnimation() async throws {
        try DesktopTestSupport.requireUnlocked()
        let space = UUID(), firstTab = UUID(), secondTab = UUID(), pane = UUID(), shared = UUID(), splitID = UUID()
        let initial = PaneLayout.split(splitID, .columns, .pane(pane), .pane(shared))
        let view = MotionContentView(content: AnyView(Text("First tab")), identity: "first", spaceID: space,
                                     layout: initial, selectedTabID: firstTab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        let replacement = PaneLayout.split(splitID, .columns, .pane(UUID()), .pane(shared))
        view.update(AnyView(Text("Second tab")), identity: "second", spaceID: space,
                    layout: replacement, animated: true, selectedTabID: secondTab)
        XCTAssertFalse(view.subviews.contains { $0 is NSImageView }, "A shared pane does not turn tab navigation into a layout edit")
        view.update(AnyView(Text("Single layout")), identity: "single", spaceID: space,
                    layout: .pane(shared), animated: false, selectedTabID: secondTab)
        view.layoutSubtreeIfNeeded()
        view.update(AnyView(Text("Split layout")), identity: "split", spaceID: space,
                    layout: replacement, animated: true, selectedTabID: secondTab)
        XCTAssertTrue(view.subviews.contains { $0 is NSImageView }, "Editing the current tab's layout keeps its transition")
        view.update(AnyView(Text("First tab again")), identity: "first", spaceID: space,
                    layout: initial, animated: true, selectedTabID: firstTab)
        XCTAssertFalse(view.subviews.contains { $0 is NSImageView }, "Navigation immediately removes an in-flight layout snapshot")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(view.subviews.contains { $0 is NSImageView }, "Deferred animation work must not restore a stale snapshot")
    }

    func testConnectingArcRemainsVisibleAndStillWithReducedMotion() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        window.contentView = NSHostingView(rootView: SSHConnectingIndicator(reduceMotion: true)
            .frame(width: 80, height: 50).background(Color.black))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        let first = try await PresentationTestSupport.capture(window, named: "ssh-connecting-reduced-motion", in: "motion-validation")
        try await Task.sleep(for: .milliseconds(250))
        let second = try await PresentationTestSupport.capture(window)
        XCTAssertEqual(first.bitmap.representation(using: .png, properties: [:]), second.bitmap.representation(using: .png, properties: [:]))
        var visible = 0
        for y in 0..<first.bitmap.pixelsHigh {
            for x in 0..<first.bitmap.pixelsWide {
                if let color = first.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent > 0.5 { visible += 1 }
            }
        }
        XCTAssertGreaterThan(visible, 10, "Reduced motion keeps a visible, stationary connecting arc")
    }

    func testHostMoveOverlaysFinishCancelAndRespectReduceMotion() async throws {
        let motion = HostMoveMotion()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let workspace = Workspace(); workspace.newLocalSpace(); workspace.newTab()
        let original = try XCTUnwrap(workspace.current)
        let terminal = try XCTUnwrap(original.activeTab)
        var remote = original; remote.hostID = .authenticated("motion-fixture")
        let row = HostMoveMotion.Marker(frame: NSRect(x: 8, y: 300, width: 180, height: 26))
        let tab = HostMoveMotion.Marker(frame: NSRect(x: 250, y: 370, width: 120, height: 26))
        root.addSubview(row); root.addSubview(tab)
        motion.register(row, as: .space(original.id)); motion.register(tab, as: .tab(terminal.id))
        motion.reconcile(from: [original], to: [remote], reduceMotion: true)
        XCTAssertTrue(motion.hidden.isEmpty)
        XCTAssertEqual(root.subviews.count, 2)
        motion.reconcile(from: [original], to: [remote], reduceMotion: false)
        XCTAssertTrue(motion.hidden.contains(original.id))
        XCTAssertEqual(root.subviews.count, 3)
        row.frame.origin.y = 180
        try await Task.sleep(for: .milliseconds(950))
        XCTAssertTrue(motion.hidden.isEmpty)
        XCTAssertTrue(motion.arrivals.isEmpty)
        XCTAssertEqual(root.subviews.count, 2)

        var extracted = Space(name: "shell", tab: terminal)
        extracted.hostID = remote.hostID
        motion.register(row, as: .space(extracted.id))
        motion.reconcile(from: [original], to: [original, extracted], reduceMotion: false)
        XCTAssertTrue(motion.pulling.contains(extracted.id))
        XCTAssertEqual(motion.arrivals[extracted.id], remote.hostID)
        try await Task.sleep(for: .milliseconds(950))
        XCTAssertTrue(motion.hidden.isEmpty)
        XCTAssertTrue(motion.pulling.isEmpty)
        XCTAssertEqual(root.subviews.count, 2)

        motion.reconcile(from: [original], to: [original, extracted], reduceMotion: false)
        motion.reconcile(from: [original, extracted], to: [original], reduceMotion: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(motion.hidden.isEmpty)
        XCTAssertTrue(motion.arrivals.isEmpty)
        XCTAssertEqual(root.subviews.count, 2, "Closing a destination removes the in-flight overlay")
        XCTAssertNil(root.hitTest(NSPoint(x: 260, y: 380)) as? HostMoveMotion.Marker)
    }

    func testHostMovesUseRealSidebarAndTabMarkers() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let workspace = controller.workspace
        controller.settings.values = Preferences()
        controller.settings.values.hideSingleSpace = false
        runtime.workspace = workspace; runtime.start(preferences: Preferences())
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newLocalSpace(); workspace.renameSpace(workspace.selectedSpace!, to: "scratch")
        let scratch = try XCTUnwrap(workspace.current), terminal = try XCTUnwrap(workspace.activeTab).id
        workspace.newLocalSpace(); workspace.renameSpace(workspace.selectedSpace!, to: "api-refactor")
        workspace.newLocalSpace(); workspace.renameSpace(workspace.selectedSpace!, to: "deploy")
        let remote = try XCTUnwrap(workspace.activeTab).id
        workspace.hosts.begin(remote, generation: UUID(), destination: "homelab")
        workspace.placeHostTerminal(remote)
        workspace.selectTab(terminal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; runtime.stop(); HostStats.shared.stop() }
        for mode in [SpaceOrder.flat, .tree] {
            controller.settings.values.spaceOrder = mode
            try await Task.sleep(for: .milliseconds(350))
            let surfaces = Set(workspace.allSurfaceIDs)
            let generation = UUID()
            workspace.hosts.begin(terminal, generation: generation, destination: mode == .flat ? "build" : "homelab",
                                  seed: mode == .tree ? workspace.hosts.terminals[remote]?.host : nil)
            workspace.placeHostTerminal(terminal)
            // Grouped by host, the real row supplies the snapshot that flies between groups; in one list the row itself
            // slides to its host's place, never hidden under a stale bitmap.
            XCTAssertEqual(workspace.hostMoveMotion.hidden.contains(scratch.id), mode == .tree,
                           mode == .tree ? "Real sidebar row must supply the source snapshot" : "A flat row moves itself")
            XCTAssertEqual(workspace.hostMoveMotion.moving.contains(scratch.id), mode == .flat, "A flat row never crosses the rows it passes")
            try await Task.sleep(for: .milliseconds(320))
            _ = try await PresentationTestSupport.capture(window, named: "host-move-\(mode.rawValue)-flight", in: "motion-validation")
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(workspace.hostMoveMotion.hidden.isEmpty)
            XCTAssertTrue(workspace.hostMoveMotion.moving.isEmpty)
            XCTAssertEqual(workspace.activeSurfaceID, terminal)
            XCTAssertEqual(Set(workspace.allSurfaceIDs), surfaces)
            let host = try XCTUnwrap(workspace.current).hostID
            XCTAssertEqual(workspace.presentationSpaces.last(where: { $0.hostID == host })?.id, scratch.id)
            _ = try await PresentationTestSupport.capture(window, named: "host-move-\(mode.rawValue)-landed", in: "motion-validation")
            workspace.hosts.remove(terminal, generation: generation)
            workspace.restoreHostTerminal(terminal, generation: generation)
            try await Task.sleep(for: .milliseconds(900))
        }
        workspace.newTab()
        let pulled = try XCTUnwrap(workspace.activeTab).id
        try await Task.sleep(for: .milliseconds(350))
        let surfaces = Set(workspace.allSurfaceIDs)
        workspace.hosts.begin(pulled, generation: UUID(), destination: "homelab", seed: workspace.hosts.terminals[remote]?.host)
        workspace.placeHostTerminal(pulled)
        let destination = try XCTUnwrap(workspace.selectedSpace)
        XCTAssertNotEqual(destination, scratch.id)
        XCTAssertTrue(workspace.hostMoveMotion.pulling.contains(destination), "Real tab strip must supply the pull origin")
        try await Task.sleep(for: .milliseconds(320))
        _ = try await PresentationTestSupport.capture(window, named: "host-tab-pull-flight", in: "motion-validation")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(workspace.activeSurfaceID, pulled)
        XCTAssertEqual(Set(workspace.allSurfaceIDs), surfaces)
        XCTAssertTrue(workspace.hostMoveMotion.hidden.isEmpty)
        _ = try await PresentationTestSupport.capture(window, named: "host-tab-pull-landed", in: "motion-validation")
    }

    func testClosingSecondSpaceLeavesNoSidebarDivider() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        guard #available(macOS 14.4, *) else { throw XCTSkip("Composited capture of the test process requires macOS 14.4") }
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let workspace = controller.workspace
        controller.settings.values = Preferences.flat
        runtime.workspace = workspace; runtime.start(preferences: Preferences.flat)
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newSpace()
        let firstID = workspace.activeTab!.id
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        controller.window = window; window.delegate = controller
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.delegate = nil; window.orderOut(nil); window.contentView = nil; runtime.stop() }
        func capture(_ name: String) async throws -> PresentationTestSupport.Snapshot {
            try await PresentationTestSupport.capture(window, named: name, in: "motion-validation")
        }
        try await Task.sleep(for: .milliseconds(450))
        _ = try await capture("space-initial")
        let firstSurface = try XCTUnwrap(runtime.views[firstID]?.surface)
        workspace.newSpace()
        try await Task.sleep(for: .milliseconds(450))
        _ = try await capture("space-sidebar-shown")
        workspace.closeSpace(workspace.selectedSpace!)
        try await Task.sleep(for: .milliseconds(450))
        let shareable = try await SCShareableContent.currentProcess
        let ownWindow = try XCTUnwrap(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        let screenshot = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
        let after = NSBitmapImageRep(cgImage: screenshot)
        try PresentationTestSupport.save(after, named: "space-sidebar-closed-screen", in: "motion-validation")
        _ = try await capture("space-sidebar-closed")
        XCTAssertTrue(runtime.views[firstID]?.surface === firstSurface)
        // Below the shell prompt, the former divider's entire horizontal
        // neighborhood must return to the same uninterrupted terminal color.
        let scale = CGFloat(after.pixelsWide) / window.contentView!.bounds.width
        let y = after.pixelsHigh / 2
        let baseline = try XCTUnwrap(after.colorAt(x: Int(180 * scale), y: y)?.usingColorSpace(.deviceRGB))
        for x in Int(200 * scale)..<Int(350 * scale) {
            let color = try XCTUnwrap(after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, baseline.redComponent, accuracy: 0.01, "Unexpected divider at pixel \(x)")
            XCTAssertEqual(color.greenComponent, baseline.greenComponent, accuracy: 0.01, "Unexpected divider at pixel \(x)")
            XCTAssertEqual(color.blueComponent, baseline.blueComponent, accuracy: 0.01, "Unexpected divider at pixel \(x)")
        }

        // Reproduce repeated opens with the requested half-second pause, and
        // inspect composited frames during each title/space transition.
        for opened in 0..<3 {
            try await Task.sleep(for: .milliseconds(500))
            workspace.newSpace()
            for sample in 0..<4 {
                let kinds = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                let before = kinds.map { kind in window.standardWindowButton(kind).map { $0.convert($0.bounds, to: nil) } }
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
                let bitmap = NSBitmapImageRep(cgImage: image)
                try PresentationTestSupport.save(bitmap, named: "space-open-\(opened)-frame-\(sample)", in: "motion-validation")
                for (index, kind) in kinds.enumerated() {
                    let button = try XCTUnwrap(window.standardWindowButton(kind))
                    let after = button.convert(button.bounds, to: nil)
                    let frame = try XCTUnwrap(before[index])
                    let stable = frame.intersection(after)
                    XCTAssertFalse(stable.isNull, "Traffic-light frame moved outside the captured interval")
                    let x = Int(stable.midX * scale)
                    var rows: [Int] = []
                    // Colored and inactive controls contrast with their adjacent titlebar.
                    // Compare each row with the background outside the button: glass can itself
                    // exceed the brightness threshold, without the traffic lights moving.
                    for y in Int(2 * scale)..<Int(36 * scale) {
                        guard let background = bitmap.colorAt(x: Int(ceil(frame.union(after).maxX * scale)), y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        // The center column crosses the control, not the glass panel's rounded corner.
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if max(abs(c.redComponent - background.redComponent),
                               abs(c.greenComponent - background.greenComponent),
                               abs(c.blueComponent - background.blueComponent)) > 0.15 { rows.append(y) }
                    }
                    let minY = try XCTUnwrap(rows.min()), maxY = try XCTUnwrap(rows.max())
                    XCTAssertEqual((CGFloat(minY + maxY) / 2 + 0.5) / scale, 15, accuracy: 0.75,
                        "Traffic lights jumped during open \(opened), frame \(sample), kind=\(kind.rawValue), before=\(String(describing: before[index])), after=\(after), pixels=\(minY)...\(maxY), scale=\(scale)")
                }
                if sample == 0 {
                    try PresentationTestSupport.save(bitmap, named: "space-open-\(opened)-controls", in: "motion-validation")
                }
            }
        }
    }

    func testSidebarAnimationCanReverseAndReduceMotionFinishesImmediately() async throws {
        try DesktopTestSupport.requireUnlocked()
        let split = TerminalSplitView()
        split.sidebar = true; split.isVertical = true; split.delegate = split
        let sidebarHost = NSHostingView(rootView: AnyView(HStack { Text("spaces"); Spacer(); Text("flat · tree · urgency") }))
        sidebarHost.sizingOptions = []
        let clip = SidebarClipView(host: sidebarHost)
        split.addArrangedSubview(clip); split.addArrangedSubview(NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        split.resizeSubviews(withOldSize: .zero)
        split.setPosition(300, ofDividerAt: 0)
        let first = split.arrangedSubviews[0], second = split.arrangedSubviews[1]
        split.setSidebarHidden(true, animated: true)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(split.sidebarAnimating)
        XCTAssertGreaterThan(first.frame.width, 0); XCTAssertLessThan(first.frame.width, 300)
        XCTAssertEqual(sidebarHost.frame.width, 300, accuracy: 1, "Collapse slides the sidebar without reflowing its labels")
        XCTAssertEqual(sidebarHost.frame.maxX, clip.bounds.maxX, accuracy: 1)
        split.setSidebarHidden(false, animated: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(split.sidebarAnimating)
        XCTAssertEqual(first.frame.width, 300, accuracy: 1)
        XCTAssertTrue(split.arrangedSubviews[0] === first); XCTAssertTrue(split.arrangedSubviews[1] === second)
        split.setSidebarHidden(true, animated: true)
        split.setSidebarHidden(true, animated: false)
        XCTAssertFalse(split.sidebarAnimating); XCTAssertTrue(first.isHidden)
        XCTAssertEqual(second.frame, split.bounds)
        split.setSidebarHidden(false, animated: true)
        try await Task.sleep(for: .milliseconds(40))
        split.setSidebarHidden(false, animated: false)
        XCTAssertFalse(split.sidebarAnimating)
        XCTAssertEqual(first.frame.width, 300, accuracy: 1)
    }

    func testSwitcherClicksCompactSizingAndApprovalReceipt() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let coordinator = ChatCoordinator(enabled: true)
        let session = coordinator.session(for: UUID())
        session.active = true; session.sessionID = "motion-test"; session.version = "0.153.2"
        session.draft = "Retain this draft"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        func capture(_ name: String) async throws -> PresentationTestSupport.Snapshot {
            try await PresentationTestSupport.capture(window, named: name, in: "motion-validation")
        }
        func click(_ x: CGFloat) throws {
            try PresentationTestSupport.click(window, at: NSPoint(x: x, y: 120))
        }
        window.contentView = NSHostingView(rootView: ChatModeSwitch(session: session, coordinator: coordinator, floating: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Chrome.terminal).preferredColorScheme(.dark))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        let terminal = try await capture("switch-terminal").text(separator: " ")
        XCTAssertFalse(terminal.contains("terminal")); XCTAssertFalse(terminal.contains("chat"), "The switch is an icon in either mode")
        try click(250)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(session.showChat); XCTAssertTrue(session.manualViewChoice)
        let snapshot1 = try await capture("switch-chat").text()
        XCTAssertFalse(snapshot1.contains("chat"))
        try click(250)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(session.showChat); XCTAssertEqual(session.draft, "Retain this draft")
        window.contentView = NSHostingView(rootView: ChatModeSwitch(session: session, coordinator: coordinator)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Chrome.terminal))
        try await Task.sleep(for: .milliseconds(100))
        try click(250); try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(session.showChat)
        _ = try await capture("switch-compact")

        let approval = PendingApproval(key: "motion", operation: "swift build") { _ in }
        window.contentView = NSHostingView(rootView: ChatPermissionCard(approval: approval, openTerminal: {})
            .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity).background(Chrome.terminal).foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        try await Task.sleep(for: .milliseconds(600))
        let snapshot2 = try await capture("approval-pending").text(separator: " ")
        XCTAssertTrue(snapshot2.contains("Allow once"))
        approval.resolve(.deny)
        try await Task.sleep(for: .milliseconds(400))
        let receipt = try await capture("approval-receipt").text(separator: " ")
        XCTAssertTrue(receipt.contains("Denied")); XCTAssertFalse(receipt.contains("Allow once"))
        approval.resolve(.allow)
        XCTAssertEqual(approval.decision, .deny)
    }
}
