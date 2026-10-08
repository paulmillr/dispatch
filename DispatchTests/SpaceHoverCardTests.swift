import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class SpaceHoverCardTests: XCTestCase {
    func testBottomEdgeTabHoverOpensAboveAndStaysAboveOnRefresh() throws {
        try DesktopTestSupport.requireUnlocked()
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let window = NSWindow(contentRect: NSRect(x: screen.midX, y: screen.minY + 12, width: 240, height: 28),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tab = UUID()
        let row = ReorderTrackingView(configuration: LocalReorder(item: .tab(tab), edge: .horizontal,
            spaceHover: .init(remote: false, route: "", backend: "terminal", directory: nil, title: "Bottom tab"),
            accepts: { _ in false }, drop: { _, _ in }))
        window.contentView = row; window.orderFront(nil)
        defer { row.hover.dismiss(); window.close(); window.contentView = nil }
        row.hover.present(from: row)
        let panel = try XCTUnwrap(row.hover.panel)
        let frame = window.convertToScreen(row.convert(row.bounds, to: nil))
        XCTAssertGreaterThanOrEqual(panel.frame.minY, frame.maxY)
        row.configuration.spaceHover?.activity = "Running tests"
        row.hover.refresh(from: row)
        XCTAssertGreaterThanOrEqual(panel.frame.minY, frame.maxY)
        XCTAssertTrue(screen.contains(panel.frame))
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    func testRouteUsesTheSpacesAccountAndNeverItsLocalSSHLaunchDirectory() {
        let runtime = TerminalRuntime()
        var space = Space(name: "nightly", directory: NSHomeDirectory() + "/src/nightly")
        let host = HostRecord(id: .authenticated("fixture"), name: "homelab", destinations: ["wrong@other", "ops@10.0.0.12"], order: 0)
        space.hostID = host.id
        space.panes[0].tabs[0].machine = .ssh(SSHShell(destination: "ops@10.0.0.12"))
        let plain = SpaceHoverDetails.make(space: space, host: host, runtime: runtime)
        XCTAssertEqual(plain.route, "ops@10.0.0.12")
        XCTAssertTrue(plain.remote)
        XCTAssertNil(plain.directory)
        var pane = space.panes[0].tabs[0]; pane.directory = "/home/ops/src/nightly"
        space.structure([pane], selected: 0)
        let remote = SpaceHoverDetails.make(space: space, host: host, runtime: runtime)
        XCTAssertNil(remote.directory)
        for remoteHost in [false, true] {
            for backend in ["tmux", "herdr"] {
                var multiplexed = Space(name: backend, directory: "/stale/launch/path")
                multiplexed.hostID = remoteHost ? host.id : .local
                if remoteHost { multiplexed.panes[0].tabs[0].machine = .ssh(SSHShell(destination: "ops@10.0.0.12")) }
                // Either multiplexer's session: a structured space of its helper backend.
                multiplexed.structure([multiplexed.panes[0].tabs[0]], selected: 0, backend: backend == "tmux" ? 1 : 2)
                let details = SpaceHoverDetails.make(space: multiplexed, host: remoteHost ? host : .local,
                    runtime: runtime)
                XCTAssertNil(details.directory, "\(remoteHost ? "SSH" : "local") \(backend) must omit cached cwd")
                XCTAssertFalse(details.summary.contains("/stale/launch/path"))
            }
        }
        let local = Space(name: "scratch", directory: NSHomeDirectory() + "/src")
        XCTAssertEqual(SpaceHoverDetails.make(space: local, host: .local, runtime: runtime).directory, "~/src")
        let sibling = Space(name: "other", directory: NSHomeDirectory() + "-other/src")
        XCTAssertEqual(SpaceHoverDetails.make(space: sibling, host: .local, runtime: runtime).directory, NSHomeDirectory() + "-other/src")
    }

    func testSpaceHoverCountsTabsTmuxWindowsAndAgentStates() {
        let runtime = TerminalRuntime(), workspace = Workspace()
        workspace.newLocalSpace(); workspace.newTab(); workspace.newTab()
        let tabs = workspace.spaces[0].tabs
        func agents() -> String? { SpaceHoverDetails.make(space: workspace.spaces[0], host: .local, runtime: runtime).agents }
        runtime.chat.session(for: tabs[0].id).active = true
        XCTAssertNil(agents(), "Idle agents don't count")
        runtime.chat.session(for: tabs[2].id).hasNewMessages = true
        XCTAssertEqual(agents(), "1 unread")
        for tab in tabs.prefix(2) { let session = runtime.chat.session(for: tab.id); session.active = true; session.busy = true }
        let native = SpaceHoverDetails.make(space: workspace.spaces[0], host: .local, runtime: runtime)
        XCTAssertEqual(native.tabCount, "3 tabs")
        XCTAssertTrue(native.summary.hasSuffix(" · 3 tabs · 2 agents (1 unread)"), native.summary)
        // One window split into two panes is one tab.
        var window = ContainerTab(id: UUID(), node: 1, name: "zsh",
                                   arrangement: PaneArrangement(tab: TerminalTab(directory: "/tmp")))
        window.arrangement.panes.append(Pane(tabs: [TerminalTab(directory: "/tmp")]))
        var tmux = Space(name: "tmux", directory: "/tmp")
        tmux.backend = 1; tmux.containers = [window]
        XCTAssertEqual(tmux.tabs.count, 2)
        XCTAssertEqual(SpaceHoverDetails.make(space: tmux, host: .local, runtime: runtime).tabCount, "1 tab")
        XCTAssertNil(SpaceHoverDetails.make(tab: tmux.tabs[0], host: .local, runtime: runtime).tabCount, "A tab's hover has no count")
    }

    func testTabHoverShowsReportedActivityBelowTabWithoutTakingFocus() async throws {
        try DesktopTestSupport.requireUnlocked()
        // A real tmux pane: the helper names its multiplexer. Flat, because the card's text is read from offscreen
        // captures, which cannot draw Liquid Glass.
        let app = try TmuxWalkthrough(liquidGlass: false); defer { app.close() }
        try await app.attach(); try await app.ready()
        let runtime = app.runtime
        var tab = try XCTUnwrap(app.workspace.activeTab)
        tab.title = "Build logs"
        // The multiplexer's name is the tooltip's, never the sidebar row's text.
        XCTAssertEqual(SpaceHoverDetails.make(space: try XCTUnwrap(app.workspace.current), host: .local, runtime: runtime).backend, "tmux")
        let space = try XCTUnwrap(app.workspace.current)
        let sidebar = try XCTUnwrap(PresentationTestSupport.views(of: ReorderTrackingView.self, in: try XCTUnwrap(app.window.contentView))
            .first { $0.configuration.item == .space(space.id) && !$0.isHiddenOrHasHiddenAncestor })
        try await TestSupport.eventually { sidebar.visibleRect.contains(sidebar.bounds) }
        let visible = try await PresentationTestSupport.capture(sidebar).text()
        XCTAssertFalse(visible.contains("tmux"), "Backend type belongs in the tooltip: \(visible)")
        let session = runtime.chat.session(for: tab.id)
        session.active = true; session.busy = true; session.nativeActivity = "Running tests"
        let details = SpaceHoverDetails.make(tab: tab, host: .local, runtime: runtime)
        XCTAssertEqual(details.title, "Build logs")
        XCTAssertEqual(details.backend, "tmux")
        XCTAssertNil(details.directory)
        XCTAssertTrue(details.activity?.contains("Running tests") == true)
        let window = NSWindow(contentRect: NSRect(x: 300, y: 400, width: 280, height: 32),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let row = ReorderTrackingView(configuration: LocalReorder(item: .tab(tab.id), edge: .horizontal,
            spaceHover: details, accepts: { _ in false }, drop: { _, _ in }))
        window.contentView = row; window.makeKeyAndOrderFront(nil)
        defer { row.hover.dismiss(); window.close(); window.contentView = nil; runtime.chat.close(tab.id) }
        let key = NSApp.keyWindow
        row.hover.present(from: row)
        let panel = try XCTUnwrap(row.hover.panel)
        XCTAssertTrue(NSApp.keyWindow === key)
        XCTAssertTrue(panel.ignoresMouseEvents)
        let tabFrame = window.convertToScreen(row.convert(row.bounds, to: nil))
        XCTAssertLessThan(panel.frame.maxY, tabFrame.minY)
        let snapshot = try await PresentationTestSupport.capture(panel, named: "tab-hover")
        let text = try snapshot.text()
        XCTAssertTrue(text.contains("Build logs"), text)
        XCTAssertTrue(text.contains("Running tests"), text)
        XCTAssertTrue(text.contains("tmux"), text)
        session.busy = false
        row.configuration.spaceHover = SpaceHoverDetails.make(tab: tab, host: .local, runtime: runtime)
        row.hover.refresh(from: row)
        XCTAssertTrue(row.configuration.spaceHover?.activity?.contains("Idle") == true)
        // Updating AppKit's panel geometry does not synchronously publish its new compositor pixels.
        func rendered(_ accepts: (String) -> Bool) async throws -> String {
            var text = ""
            try await TestSupport.eventually(diagnostic: text) {
                text = try await PresentationTestSupport.capture(panel).text()
                return accepts(text)
            }
            return text
        }
        let idle = try await rendered { $0.contains("Idle") && !$0.contains("Running tests") }
        XCTAssertTrue(idle.contains("Idle"), idle)
        XCTAssertFalse(idle.contains("Running tests"), idle)
        // A session can end while the pointer remains on the same tab. The
        // mounted panel must lose the activity row and reclaim its height.
        let activeHeight = panel.frame.height
        session.active = false
        row.configuration.spaceHover = SpaceHoverDetails.make(tab: tab, host: .local, runtime: runtime)
        row.hover.refresh(from: row)
        XCTAssertLessThan(panel.frame.height, activeHeight)
        let ended = try await rendered { $0.contains("Build logs") && !$0.contains("Idle") }
        XCTAssertFalse(ended.contains("Idle"), ended)
        XCTAssertTrue(ended.contains("Build logs"), ended)
        session.active = true; session.busy = true
        row.configuration.spaceHover = SpaceHoverDetails.make(tab: tab, host: .local, runtime: runtime)
        row.hover.refresh(from: row)
        XCTAssertEqual(panel.frame.height, activeHeight, accuracy: 0.5)
        let working = try await rendered { $0.contains("Running tests") }
        XCTAssertTrue(working.contains("Running tests"))
        XCTAssertTrue(NSApp.keyWindow === key)
        row.configuration.spaceHover = .init(remote: true, route: "ops@example.net", backend: "herdr",
            directory: nil, title: "Remote workspace", activity: "Disconnected")
        row.configuration.hoverFontSize = 18
        row.hover.refresh(from: row)
        XCTAssertTrue(row.hover.panel === panel)
        let changed = try await PresentationTestSupport.capture(panel).text()
        XCTAssertTrue(changed.contains("Remote workspace"), changed)
        XCTAssertTrue(changed.contains("ops@example.net"), changed)
        XCTAssertTrue(changed.contains("herdr"), changed)
        XCTAssertTrue(changed.contains("Disconnected"), changed)
        XCTAssertFalse(changed.contains("Build logs"), changed)
        XCTAssertFalse(changed.contains("Running tests"), changed)
        XCTAssertTrue(try XCTUnwrap(window.screen).visibleFrame.contains(panel.frame))
        XCTAssertTrue(NSApp.keyWindow === key)
        row.mouseExited(with: try PresentationTestSupport.mouseEvent(.mouseMoved, in: window, at: .zero))
        XCTAssertNil(row.hover.panel)
    }

    func testHoverPanelPreservesFocusAndDismissesBeforeSelecting() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 264, height: 80),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var selections = 0
        let details = SpaceHoverDetails(remote: true, route: "ops@10.0.0.12", backend: "tmux", directory: "~/src/nightly", tabs: 3)
        let row = ReorderTrackingView(configuration: LocalReorder(item: .space(UUID()), edge: .vertical,
            spaceHover: details, select: { selections += 1 }, accepts: { _ in false }, drop: { _, _ in }))
        window.contentView = row
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { row.hover.dismiss(); window.close(); window.contentView = nil }
        let point = NSPoint(x: 80, y: 40)
        // Exercise presentation directly: the hover timer requires foreground
        // activation, which macOS may withhold from a background test runner.
        let previousKey = NSApp.keyWindow
        row.hover.present(from: row)
        let panel = try XCTUnwrap(row.hover.panel)
        XCTAssertTrue(NSApp.keyWindow === previousKey)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.parent === window)
        XCTAssertGreaterThan(panel.frame.minX, window.frame.maxX)
        XCTAssertLessThan(panel.frame.height, 45)
        let snapshot = try await PresentationTestSupport.capture(panel, named: "space-hover-1p")
        for label in ["ssh", "ops", "10.0.0.12", "tmux", "~/src/nightly", "3 tabs"] {
            try PresentationTestSupport.assertText(label, in: snapshot, rendered: panel.contentView)
        }
        let down = try PresentationTestSupport.mouseEvent(.leftMouseDown, in: window, at: point)
        var events = [try PresentationTestSupport.mouseEvent(.leftMouseUp, in: window, at: point)]
        row.trackMouse(with: down) { events.isEmpty ? nil : events.removeFirst() }
        XCTAssertNil(row.hover.panel)
        XCTAssertEqual(selections, 1)
        // A synthetic exit alone leaves the physical pointer in the row, so
        // AppKit can immediately send another entered event and reopen it.
        let pointer = NSEvent.mouseLocation
        let desktop = try XCTUnwrap(NSScreen.screens.first).frame
        defer { CGWarpMouseCursorPosition(CGPoint(x: pointer.x, y: desktop.maxY - pointer.y)) }
        XCTAssertEqual(CGWarpMouseCursorPosition(CGPoint(x: window.frame.maxX + 20,
            y: desktop.maxY - window.frame.midY)), .success)
        row.hover.schedule(from: row)
        row.mouseExited(with: try PresentationTestSupport.mouseEvent(.mouseMoved, in: window, at: point))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(row.hover.panel)
    }
}
