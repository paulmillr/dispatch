import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class HerdrLocalLayoutTests: XCTestCase {
    func testPreciseWheelDeltasAccumulateAndReverseWithoutLeakingIntoKeys() {
        var scroll = HerdrScrollAccumulator()
        for _ in 0..<3 { XCTAssertEqual(scroll.consume(delta: 4, precise: true, lineHeight: 16), 0) }
        XCTAssertEqual(scroll.consume(delta: 4, precise: true, lineHeight: 16), 1)
        XCTAssertEqual(scroll.consume(delta: -32, precise: true, lineHeight: 16), -2)
        XCTAssertEqual(scroll.consume(delta: 1, precise: false, lineHeight: 16), 3)
        XCTAssertEqual(scroll.consume(delta: .nan, precise: true, lineHeight: 16), 0)
    }

    func testSavedLayoutsUseServerIDsAndPruneClosedTabs() throws {
        // A multiplexer session's windows as the helper projects them: window ids follow the server's ids,
        // so a refresh with the same windows keeps the client layout and closed windows leave it.
        let workspace = Workspace()
        var space = Space(name: "herdr", tab: TerminalTab(directory: "/tmp"))
        space.structure((0..<4).map { _ in TerminalTab(directory: "/tmp") }, selected: 0)
        workspace.spaces = [space]; workspace.selectSpace(space.id)
        XCTAssertTrue(workspace.applyLayout(.grid))
        let divider = try XCTUnwrap(workspace.current?.layout.splitIDs.first)
        workspace.resizeSplit(divider, in: space.id, fraction: 0.65)
        let windows = space.containers.map(\.id), before = try XCTUnwrap(workspace.current?.presentation)
        var refreshed = before
        refreshed.reconcile(windows, near: windows[0])
        XCTAssertEqual(refreshed, before)
        XCTAssertEqual(workspace.current?.splitRatios, [divider: 0.65])
        refreshed.reconcile(Array(windows.prefix(2)), near: windows[0])
        XCTAssertEqual(refreshed.layout.paneIDs.count, 2)
        XCTAssertEqual(refreshed.groups.count, 2)
        XCTAssertEqual(Set(refreshed.orderedWindows), Set(windows.prefix(2)))
        XCTAssertTrue(workspace.applyLayout(.single))
        workspace.resizeSplit(divider, in: space.id, fraction: 0.75)
        XCTAssertTrue(workspace.current!.splitRatios.isEmpty, "Queued divider callbacks must not revive a removed split")
    }

    func testRealLocalLayoutsPreserveHerdrTabsAndWheelScrollsServerHistory() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        guard FileManager.default.isExecutableFile(atPath: TestSupport.tool("herdr")) else { throw XCTSkip("Install herdr for integration tests") }
        let root = URL(fileURLWithPath: "/tmp/hv-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let socket = root.appendingPathComponent("herdr.sock").path
        let runtime = TerminalRuntime.shared, controller = AppDelegate(), workspace = controller.workspace
        runtime.workspace = workspace; runtime.start(preferences: Preferences())
        workspace.onCloseTabs = { runtime.close($0) }; workspace.newLocalSpace()
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentView = nil; runtime.stop()
            _ = try? HerdrSocket(path: socket).request("server.stop")
            try? FileManager.default.removeItem(at: root)
        }
        func api(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try HerdrSocket(path: socket).request(method, params: JSONSerialization.data(withJSONObject: params))
        }
        func terminal(_ id: UUID) async throws -> TerminalView {
            try await TestSupport.eventually { runtime.views[id]?.surface != nil }
            return runtime.views[id]!
        }
        let source = try await terminal(workspace.activeTab!.id)
        TerminalTestSupport.send("export PATH=\(TestSupport.path):/usr/bin:/bin:$PATH; export XDG_CONFIG_HOME=\(HerdrLaunch.quote(root.path)); export XDG_STATE_HOME=\(HerdrLaunch.quote(root.path)); export HERDR_SOCKET_PATH=\(HerdrLaunch.quote(socket)); herdr", to: source)
        try await TestSupport.eventually(timeout: .seconds(15)) { workspace.current?.shows("herdr") == true }
        // herdr tabs are the space's windows (client panes group them); herdr panes are terminal tabs.
        let original = workspace.activeTab!, first = original
        let originalWindow = try XCTUnwrap(workspace.current?.selectedContainer), originalKey = try XCTUnwrap(workspace.windowKey(of: original))
        let view = try await terminal(first.id), pty = view.surface
        _ = try api("pane.split", ["target_pane_id": try XCTUnwrap(HerdrTestSupport.pane(of: first.id, in: workspace, socket: socket)), "direction": "right"])
        try await TestSupport.eventually { workspace.current?.activeWindow?.terminals.count == 2 }
        func groups() -> [[UUID]] { workspace.current?.presentation?.groups.map(\.windows) ?? [workspace.current?.containers.map(\.id) ?? []] }
        func windowCount() -> Int { workspace.current?.windows.count ?? 0 }
        for axis in [SplitAxis.columns, .rows] {
            workspace.selectTab(original.id)
            workspace.toggleSplit(axis)
            try await TestSupport.eventually {
                windowCount() == (axis == .columns ? 2 : 3) && workspace.current?.tabs.allSatisfy { !$0.isConnecting } == true
            }
            let createdInSplit = try XCTUnwrap(workspace.current?.selectedContainer)
            XCTAssertNotEqual(createdInSplit, originalWindow)
            XCTAssertEqual(groups().count, 2, "Confirming the new tab must retain its new split")
            XCTAssertEqual(workspace.current?.presentation?.groups.first?.selected, originalWindow)
            XCTAssertEqual(groups().first { $0.contains(createdInSplit) }, [createdInSplit])
            XCTAssertTrue(runtime.views[first.id] === view); XCTAssertTrue(view.surface === pty)
            workspace.toggleSplit(axis)
            XCTAssertEqual(groups().count, 1)
            XCTAssertEqual(windowCount(), axis == .columns ? 2 : 3)
        }
        workspace.newTab()
        try await TestSupport.eventually {
            windowCount() == 4 && workspace.current?.tabs.allSatisfy { !$0.isConnecting } == true
        }
        workspace.selectTab(original.id)
        // The inner (server) divider follows the app; a stale write is the herdr mux's to refuse.
        let before = try HerdrTestSupport.snapshot(socket), ids = workspace.allSurfaceIDs
        for preset in [LayoutPreset.grid, .rows, .columns, .twoAbove, .single, .grid] {
            XCTAssertTrue(workspace.applyLayout(preset))
            XCTAssertEqual(groups().count, preset.count)
            _ = try api("tab.rename", ["tab_id": originalKey, "label": "Local layout \(preset.rawValue)"])
            try await TestSupport.eventually { workspace.current?.windows.first { $0.id == originalWindow }?.name == "Local layout \(preset.rawValue)" }
            XCTAssertEqual(groups().count, preset.count, "Server refresh must preserve the client layout")
            XCTAssertEqual(workspace.allSurfaceIDs, ids)
        }
        let after = try HerdrTestSupport.snapshot(socket)
        XCTAssertEqual(after.tabs.map(\.tab_id), before.tabs.map(\.tab_id))
        XCTAssertEqual(after.panes.map(\.terminal_id), before.panes.map(\.terminal_id))
        XCTAssertEqual(after.layouts.map { $0.splits?.map(\.direction) }, before.layouts.map { $0.splits?.map(\.direction) })
        XCTAssertEqual(after.layouts.map { $0.splits?.map(\.ratio) }, before.layouts.map { $0.splits?.map(\.ratio) })
        XCTAssertTrue(runtime.views[first.id] === view); XCTAssertTrue(view.surface === pty)
        try await TestSupport.eventually { workspace.current!.panes.allSatisfy { pane in pane.activeTab!.surfaceIDs.allSatisfy { runtime.views[$0]?.window === window } } }
        let outer = try XCTUnwrap(PresentationTestSupport.views(of: TerminalSplitView.self, in: window.contentView!, includingNestedMatches: true).first { !$0.sidebar })
        guard case .split(let outerID, _, _, _) = workspace.current!.layout else { return XCTFail("Expected a native grid") }
        outer.setPosition((outer.bounds.height - outer.dividerThickness) * 0.6, ofDividerAt: 0)
        try await TestSupport.eventually { abs((workspace.current?.splitRatios[outerID] ?? 0) - 0.6) < 0.01 }
        let activePane = workspace.current!.focusedPane
        workspace.cyclePane(1)
        XCTAssertNotEqual(workspace.current?.focusedPane, activePane)
        workspace.cyclePane(-1)
        XCTAssertEqual(workspace.current?.focusedPane, activePane)
        workspace.newTab()
        try await TestSupport.eventually {
            windowCount() == 5 && workspace.current?.tabs.allSatisfy { !$0.isConnecting } == true
        }
        let created = workspace.activeTab!, createdWindow = try XCTUnwrap(workspace.current?.selectedContainer)
        try await TestSupport.eventually { groups().first { $0.contains(createdWindow) }?.count == 2 }
        let other = try XCTUnwrap(groups().first { !$0.contains(createdWindow) }?.first)
        XCTAssertTrue(workspace.moveWindow(createdWindow, beside: other))
        XCTAssertTrue(workspace.applyLayout(.rows))
        let target = try XCTUnwrap(groups().first { !$0.contains(createdWindow) }?.first)
        XCTAssertTrue(workspace.moveContainer(createdWindow, beside: target, edge: .right))
        XCTAssertEqual(groups().count, 3)
        _ = try api("tab.rename", ["tab_id": try XCTUnwrap(workspace.windowKey(of: created)), "label": "Still grouped"])
        try await TestSupport.eventually { workspace.current?.windows.first { $0.id == createdWindow }?.name == "Still grouped" }
        XCTAssertEqual(groups().count, 3)
        workspace.selectSurface(first.id)
        TerminalTestSupport.send("for i in {1..200}; do printf 'SCROLL_%03d\\n' $i; done", to: view)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: view).contains("SCROLL_200") }
        func wheel(_ amount: Int32, pixels: Bool = false, target: TerminalView) throws {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: pixels ? .pixel : .line, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0))
            target.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        }
        try wheel(20, target: view)
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: view)) {
            let text = TerminalTestSupport.screen(terminal: view)
            return text.contains("SCROLL_") && !text.contains("SCROLL_200")
        }
        let scrolled = TerminalTestSupport.screen(terminal: view)
        try wheel(-80, pixels: true, target: view)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: view) != scrolled }
        try wheel(-100, target: view)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: view).contains("SCROLL_200") }
        TerminalTestSupport.key(116, "\u{f72c}", view, modifiers: [.function, .numericPad])
        try await TestSupport.eventually { !TerminalTestSupport.screen(terminal: view).contains("SCROLL_200") }
        TerminalTestSupport.key(121, "\u{f72d}", view, modifiers: [.function, .numericPad])
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: view).contains("SCROLL_200") }
        try await TerminalTestSupport.assertScrollbar(in: view, bottomMarker: "SCROLL_200")
        let probe = "import os,tty,termios; old=termios.tcgetattr(0); tty.setraw(0); os.write(1,b'\\x1b[?1000h\\x1b[?1006hMOUSE_'+b'READY\\r\\n'); data=os.read(0,128); os.write(1,b'\\x1b[?1000l\\x1b[?1006lWHEEL_'+data.hex().encode()+b'\\r\\n'); termios.tcsetattr(0,termios.TCSANOW,old)"
        TerminalTestSupport.send("python3 -c " + HerdrLaunch.quote(probe), to: view)
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: view)) { TerminalTestSupport.screen(terminal: view).contains("MOUSE_READY") }
        try wheel(1, target: view)
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: view)) { TerminalTestSupport.screen(terminal: view).contains("WHEEL_1b5b3c") }
        _ = try await PresentationTestSupport.capture(window, named: "local-layouts", in: "herdr-local-layouts")
        workspace.newLocalSpace()
        XCTAssertNotEqual(workspace.current?.shows("herdr"), true)
        let local = try await terminal(workspace.activeTab!.id)
        TerminalTestSupport.send("printf 'LOCAL_%s\\n' READY", to: local)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: local).contains("LOCAL_READY") }
        let final = try HerdrTestSupport.snapshot(socket)
        XCTAssertEqual(final.panes.count, after.panes.count + 1, "One herdr pane per new window; a local space adds none")
    }
}
