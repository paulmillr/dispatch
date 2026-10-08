import AppKit
import Term
import SwiftUI
import os
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import DispatchApp

@MainActor
final class TmuxEdgeCaseTests: XCTestCase {
    func testRestoringDeletedDetachedPaneReportsFailureOnLiveGateway() async throws {
        try await restoreDeletedDetachedPane(partial: false)
    }

    func testPartialDetachedRestoreKeepsOnlyMissingPanesListed() async throws {
        try await restoreDeletedDetachedPane(partial: true)
    }

    func testPartialDetachedRestoreAfterDisconnectKeepsOtherWorkHidden() async throws {
        try await restoreDeletedDetachedPane(partial: true, disconnect: true)
    }

    func testDeletedDetachedRestoreAfterDisconnectKeepsOtherWorkHidden() async throws {
        try await restoreDeletedDetachedPane(partial: false, disconnect: true)
    }

    func testDetachedRestoreRacingServerDeletionRemovesStalePane() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["new-window", "-d", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let (entry, panes) = try await app.detach(try XCTUnwrap(app.workspace.current?.activeWindow))
        let pane = try XCTUnwrap(panes.first)
        _ = try app.server(["kill-pane", "-t", pane])
        // Restore at once, racing the server's deletion.
        app.workspace.restoreDetached([entry.id])
        try await app.wait { !app.workspace.isRestoringDetached(entry.id) && !app.visiblePanes.contains(pane) }
        XCTAssertFalse(app.workspace.isRestoringDetached(entry.id))
        let visible = app.visiblePanes
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(Set(visible).count, 1)
    }

    private func restoreDeletedDetachedPane(partial: Bool, disconnect: Bool = false) async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        if partial { _ = try app.server(["split-window", "-d", "/bin/sh"]) }
        _ = try app.server(["new-window", "-d", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let (entry, panes) = try await app.detach(try XCTUnwrap(app.workspace.current?.activeWindow))
        XCTAssertEqual(panes.count, partial ? 2 : 1)
        if disconnect {
            for window in app.workspace.spaces.flatMap(\.windows) { app.controller.detachWindow(window.id) }
            try await app.wait { !app.attached }
        }
        let pane = try XCTUnwrap(panes.sorted().first)
        _ = try app.server(["kill-pane", "-t", pane])
        let processes = try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"])
        let spaces = app.workspace.spaces.map(\.id)
        app.workspace.restoreDetached([entry.id])
        try await app.wait { !app.workspace.isRestoringDetached(entry.id) && app.error != nil }
        XCTAssertEqual(app.error, "Some detached work no longer exists on the tmux server.")
        if !partial && !disconnect { XCTAssertEqual(app.workspace.spaces.map(\.id), spaces) }
        XCTAssertTrue(app.workspace.detached.contains { $0.id == entry.id })
        let visible = app.visiblePanes
        XCTAssertTrue(panes.subtracting([pane]).isSubset(of: Set(visible)))
        XCTAssertEqual(visible.count, Set(visible).count)
        XCTAssertFalse(visible.contains(pane))
        if disconnect { XCTAssertEqual(Set(visible), panes.subtracting([pane]), "Unrequested detached work must stay hidden") }
        let restoredSpaces = app.workspace.spaces.map(\.id)
        app.workspace.restoreDetached([entry.id])
        XCTAssertEqual(app.workspace.spaces.map(\.id), restoredSpaces, "Retrying missing work must not duplicate its restored siblings")
        XCTAssertFalse(app.workspace.isRestoringDetached(entry.id))
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testReplacementServerDoesNotShareStaleDetachedRestoreLauncher() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        try await app.attach(); try await app.ready()
        app.controller.closeSpace(try XCTUnwrap(app.workspace.current?.id))
        try await app.wait { !app.attached && !app.workspace.detached.isEmpty }
        let stale = try XCTUnwrap(app.workspace.detached.first)
        _ = try app.server(["kill-server"])
        _ = try app.server(["-f", "/dev/null", "new-session", "-d", "-s", "edge", "/bin/sh"])
        app.workspace.newLocalSpace()
        try await app.attach(); try await app.ready()
        app.controller.closeSpace(try XCTUnwrap(app.workspace.current?.id))
        try await app.wait { !app.attached && app.workspace.detached.contains { $0.id != stale.id } }
        let current = try XCTUnwrap(app.workspace.detached.first { $0.id != stale.id })
        // Same socket and session name, a different server incarnation.
        XCTAssertEqual(current.name, stale.name)
        XCTAssertEqual(current.source, stale.source)
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        app.workspace.restoreDetached([stale.id])
        let launchers = app.workspace.allTabIDs
        app.workspace.restoreDetached([current.id])
        XCTAssertEqual(app.workspace.allTabIDs.count, launchers.count + 1, "Different server incarnations require separate restore attempts")
        try await app.wait { app.workspace.spaces.contains { $0.structured } }
        XCTAssertTrue(app.workspace.detached.contains { $0.id == stale.id })
        XCTAssertFalse(app.workspace.detached.contains { $0.id == current.id })
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testRestoreAllKeepsOtherServersPendingEntryWithSamePaneNumber() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let other = "dispatch-other-\(UUID().uuidString)"
        defer { _ = try? app.server(["-L", other, "kill-server"]) }
        _ = try app.server(["new-window", "-d", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let (first, firstPanes) = try await app.detach(try XCTUnwrap(app.workspace.current?.activeWindow))
        _ = try app.server(["-L", other, "-f", "/dev/null", "new-session", "-d", "-s", "edge", "/bin/sh"])
        _ = try app.server(["-L", other, "new-window", "-d", "/bin/sh"])
        app.workspace.newLocalSpace()
        try await app.attach(command: "\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(other) -CC attach -t edge")
        try await app.ready()
        let (second, secondPanes) = try await app.detach(try XCTUnwrap(app.workspace.current?.activeWindow))
        XCTAssertEqual(firstPanes, secondPanes)
        // The other server's control client goes away (a lost connection).
        let client = try XCTUnwrap(try app.server(["-L", other, "list-clients", "-F", "#{client_control_mode} #{client_pid}"])
            .split(separator: "\n").first { $0.hasPrefix("1 ") }.flatMap { pid_t($0.dropFirst(2)) })
        XCTAssertEqual(kill(client, SIGKILL), 0)
        app.workspace.restoreDetached([first.id, second.id])
        XCTAssertTrue(app.workspace.isRestoringDetached(second.id))
        try await app.wait { !app.workspace.detached.contains { $0.id == first.id } }
        XCTAssertTrue(app.workspace.detached.contains { $0.id == second.id }, "Restoring a different server's same-numbered pane must not remove pending work")
    }

    func testPendingLocalTabRenameUsesLatestTitleWhenCreationCompletes() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attach(); try await app.ready()
        let original = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        // A real fault: the stalled server answers the creation only after the renames.
        try app.stall()
        app.workspace.newTab()
        let pending = try XCTUnwrap(app.workspace.current?.activeWindow)
        app.workspace.renameWindow(pending.id, to: "First title")
        app.workspace.renameWindow(pending.id, to: "Latest #{pane_id} ## $ ' title")
        XCTAssertEqual(app.workspace.current?.activeWindow?.name, "Latest #{pane_id} ## $ ' title")
        app.resume()
        try await app.wait { app.workspace.activeTab?.isConnecting == false }
        let window = try XCTUnwrap(app.workspace.current?.activeWindow)
        XCTAssertEqual(window.name, "Latest #{pane_id} ## $ ' title")
        let target = try XCTUnwrap(app.target(window))
        try await TestSupport.eventually { try app.server(["display-message", "-p", "-t", target, "#{window_name}"])
            .trimmingCharacters(in: .whitespacesAndNewlines) == "Latest #{pane_id} ## $ ' title" }
        let processes = Set(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]).split(separator: "\n"))
        XCTAssertEqual(processes.count, 2)
        XCTAssertTrue(Set(original.split(separator: "\n")).isSubset(of: processes))
    }

    func testRestoreDetachedTabAndSpaceKeepsExistingProcesses() async throws {
        // The sidebar geometry below measures the classic NSSplitView.
        let app = try TmuxWalkthrough(autoClose: true, liquidGlass: false)
        defer { app.close() }
        _ = try app.server(["new-window", "-d", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let processes = try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"])
        let tab = try XCTUnwrap(app.workspace.current?.activeWindow)
        let paneID = try XCTUnwrap(tab.terminals.first.flatMap { app.target($0) })
        _ = try app.server(["send-keys", "-t", paneID, "printf 'DETACHED_SCREEN_%s\\n' RESTORED", "Enter"])
        try await app.wait { tab.terminals.contains { app.runtime.views[$0.id].map { TerminalTestSupport.screen(terminal: $0).contains("DETACHED_SCREEN_RESTORED") } == true } }
        let detached = try await app.detach(tab).entry
        XCTAssertEqual(detached.kind, "Tab")
        app.controller.settings.values.spaceOrder = .flat
        if !app.controller.sidebarVisible { app.controller.toggleSidebar() }
        let root = try XCTUnwrap(app.window.contentView)
        let sidebar = try XCTUnwrap(PresentationTestSupport.views(of: TerminalSplitView.self, in: root)
            .first(where: \.sidebar)?.arrangedSubviews.first)
        // Keep terminal pixels out of OCR's text detection and reading order.
        try await TestSupport.eventually { sidebar.bounds.width > 200 && sidebar.bounds.height > 0 }
        try await TestSupport.eventually { try await PresentationTestSupport.capture(sidebar).text().contains("Detached") }
        _ = try await PresentationTestSupport.capture(sidebar, named: "flat-detached-sidebar", in: "sidebar-validation")
        app.controller.settings.values.largeSidebarItems = true
        let search = try await PresentationTestSupport.openSpaceSearch(app.controller, in: root)
        try await Task.sleep(for: .milliseconds(150))
        _ = try await PresentationTestSupport.capture(sidebar, named: "flat-detached-sidebar-large", in: "sidebar-validation")
        for order in [SpaceOrder.flat, .tree] {
            app.controller.settings.values.spaceOrder = order
            app.window.makeFirstResponder(search)
            let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText("no-such-detached-space", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await TestSupport.eventually { try await PresentationTestSupport.capture(sidebar).text().contains("No matching spaces") }
            XCTAssertEqual(app.workspace.detached.count, 1)
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            try await TestSupport.eventually { search.stringValue.isEmpty }
            _ = try await PresentationTestSupport.capture(sidebar, named: "detached-sidebar-large-" + order.rawValue, in: "sidebar-validation")
            editor.insertText(detached.name, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await TestSupport.eventually { try await PresentationTestSupport.capture(sidebar).text().contains(detached.name) }
            _ = try await PresentationTestSupport.capture(sidebar, named: "detached-sidebar-large-expanded-" + order.rawValue, in: "sidebar-validation")
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            try await TestSupport.eventually { search.stringValue.isEmpty }
        }
        app.workspace.restoreDetached([detached.id])
        try await app.wait { app.workspace.current?.windows.count == 2 }
        XCTAssertTrue(app.workspace.detached.isEmpty)
        try await app.wait {
            app.workspace.spaces.flatMap(\.tabs).filter { app.target($0) == paneID }.contains {
                app.runtime.views[$0.id].map { TerminalTestSupport.screen(terminal: $0).contains("DETACHED_SCREEN_RESTORED") } == true
            }
        }
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"]), processes)
        let space = try XCTUnwrap(app.workspace.current)
        app.controller.closeSpace(space.id)
        try await TestSupport.eventually(diagnostic: "After space detach: spaces=\(app.workspace.spaces.map { ($0.id, $0.name, $0.structured) }), detached=\(app.workspace.detached.map(\.name)), error=\(app.error ?? "none")") { !app.attached && !app.workspace.detached.isEmpty }
        let group = try XCTUnwrap(app.workspace.detached.first)
        XCTAssertEqual(group.kind, "Space")
        app.workspace.restoreDetached([group.id])
        try await app.wait { app.workspace.current?.windows.count == 2 }
        try await app.ready()
        XCTAssertTrue(app.workspace.detached.isEmpty)
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"]), processes)
        let windows = try XCTUnwrap(app.workspace.current?.windows)
        for window in windows { app.controller.detachWindow(window.id) }
        try await app.wait { !app.attached && app.workspace.detached.count == 2 }
        let first = try XCTUnwrap(app.workspace.detached.first)
        app.workspace.restoreDetached([first.id])
        try await app.wait { app.workspace.current?.windows.count == 1 }
        XCTAssertEqual(app.workspace.detached.count, 1)
        app.workspace.restoreDetached(Set(app.workspace.detached.map(\.id)))
        try await app.wait { app.workspace.current?.windows.count == 2 }
        XCTAssertTrue(app.workspace.detached.isEmpty)
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testForgetOfflineHostWithOnlyDetachedViewsPreservesServerProcesses() async throws {
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        _ = try app.server(["new-window", "-d", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let processes = try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"])
        let host = HostID.authenticated("detached-only-fixture")
        app.workspace.hosts.restore([HostRecord(id: host, name: "Offline fixture", destinations: [], order: 0)])
        // Use the isolated local server to exercise cached remote presentation
        // without requiring a live SSH connection to the offline host.
        for window in try XCTUnwrap(app.workspace.current?.windows) {
            let index = try XCTUnwrap(app.workspace.spaces.firstIndex { $0.windows.contains { $0.id == window.id } })
            app.workspace.spaces[index].hostID = host
            app.controller.detachWindow(window.id)
        }
        try await app.wait { !app.attached && app.workspace.detached.filter { $0.host == host }.count == 2 }
        XCTAssertFalse(app.workspace.spaces.contains { $0.hostID == host })
        XCTAssertEqual(app.workspace.hosts.state(host), .disconnected)
        XCTAssertTrue(app.runtime.hosts.canForget(host))
        let remaining = app.workspace.spaces.map(\.id)
        app.runtime.hosts.forget(host)
        XCTAssertFalse(app.workspace.detached.contains { $0.host == host })
        XCTAssertNil(app.workspace.hosts.records[host])
        XCTAssertEqual(app.workspace.spaces.map(\.id), remaining)
        XCTAssertFalse(app.runtime.hosts.canForget(host))
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testForgettingUnrequestedDetachedTabDuringRestoreKeepsItHidden() async throws {
        try await changeDetachedSelectionDuringRestore(restoreSecond: false)
    }

    func testAddingDetachedTabToPendingRestoreCoalescesLauncher() async throws {
        try await changeDetachedSelectionDuringRestore(restoreSecond: true)
    }

    func testAddingDetachedTabAfterCancelledRestoreOverridesHiddenState() async throws {
        try await changeDetachedSelectionDuringRestore(restoreSecond: true, cancelAndRetry: true)
    }

    func testForgettingUnrequestedDetachedTabSurvivesCancelledRestore() async throws {
        try await changeDetachedSelectionDuringRestore(restoreSecond: false, cancelAndRetry: true)
    }

    func testForgettingUnrequestedDetachedTabSurvivesFailedRestore() async throws {
        try await changeDetachedSelectionDuringRestore(restoreSecond: false, failAndRetry: true)
    }

    private func changeDetachedSelectionDuringRestore(restoreSecond: Bool, cancelAndRetry: Bool = false, failAndRetry: Bool = false) async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        _ = try app.server(["new-window", "-d", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let processes = try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"])
        let socket = try app.socketPath()
        let windows = try XCTUnwrap(app.workspace.current?.windows)
        var entries: [(entry: DetachedEntry, panes: Set<String>)] = []
        for window in windows { entries.append(try await app.detach(window)) }
        try await app.wait { !app.attached }
        XCTAssertEqual(app.workspace.detached.count, 2)
        let requested = try XCTUnwrap(entries.first), forgotten = try XCTUnwrap(entries.last)
        let unavailableSocket = socket + ".restore-test"
        defer {
            if FileManager.default.fileExists(atPath: unavailableSocket) {
                try? FileManager.default.moveItem(atPath: unavailableSocket, toPath: socket)
            }
        }
        if failAndRetry { try FileManager.default.moveItem(atPath: socket, toPath: unavailableSocket) }
        app.workspace.restoreDetached([requested.entry.id])
        // Both actions occur before the new control client can attach.
        if restoreSecond {
            if cancelAndRetry {
                app.controller.closeSpace(try XCTUnwrap(app.workspace.current?.id))
                app.workspace.restoreDetached([requested.entry.id])
            }
            let launchers = app.workspace.allTabIDs
            for _ in 0..<3 { app.workspace.restoreDetached([forgotten.entry.id, requested.entry.id]) }
            XCTAssertEqual(app.workspace.allTabIDs, launchers, "Repeated restores must share the pending launcher")
        } else {
            app.workspace.forgetDetached(forgotten.entry.id)
        }
        if cancelAndRetry && !restoreSecond {
            app.controller.closeSpace(try XCTUnwrap(app.workspace.current?.id))
            app.workspace.restoreDetached([requested.entry.id])
        }
        if failAndRetry {
            let launcher = try XCTUnwrap(app.workspace.current?.id)
            try await app.wait { !app.workspace.isRestoringDetached(requested.entry.id) && app.error != nil }
            XCTAssertTrue(app.workspace.detached.contains { $0.id == requested.entry.id })
            try FileManager.default.moveItem(atPath: unavailableSocket, toPath: socket)
            app.controller.closeSpace(launcher)
            app.workspace.restoreDetached([requested.entry.id])
        }
        try await app.wait { app.attached && !app.visiblePanes.isEmpty }
        let visible = Set(app.visiblePanes)
        XCTAssertEqual(visible, restoreSecond ? requested.panes.union(forgotten.panes) : requested.panes,
                       "Only requested panes should return, even if the detached list changes during attach")
        if !restoreSecond { XCTAssertTrue(visible.isDisjoint(with: forgotten.panes)) }
        XCTAssertTrue(app.workspace.detached.isEmpty)
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testClosingPendingDetachedRestoreAllowsRetryWithoutDuplicateSpaces() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        _ = try app.server(["new-window", "-d", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let processes = try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"])
        var detached: [(entry: DetachedEntry, panes: Set<String>)] = []
        for window in try XCTUnwrap(app.workspace.current?.windows) { detached.append(try await app.detach(window)) }
        try await app.wait { !app.attached }
        let entries = app.workspace.detached
        XCTAssertEqual(entries.count, 2)
        let requested = try XCTUnwrap(detached.first?.entry), requestedPanes = try XCTUnwrap(detached.first?.panes)
        let remaining = try XCTUnwrap(detached.last?.entry)
        let baseline = Set(app.workspace.spaces.map(\.id))
        for _ in 0..<3 {
            app.workspace.restoreDetached([requested.id])
            let launcher = try XCTUnwrap(app.workspace.current)
            XCTAssertFalse(baseline.contains(launcher.id))
            XCTAssertTrue(app.workspace.isRestoringDetached(requested.id))
            app.controller.closeSpace(launcher.id)
            XCTAssertNil(NSApp.modalWindow)
            XCTAssertEqual(Set(app.workspace.spaces.map(\.id)), baseline)
            XCTAssertFalse(app.workspace.isRestoringDetached(requested.id))
            XCTAssertNil(app.error, "User cancellation must not report a failed restore")
            XCTAssertEqual(Set(app.workspace.detached.map(\.id)), Set(entries.map(\.id)))
        }
        app.workspace.restoreDetached([requested.id])
        try await app.wait { !app.visiblePanes.isEmpty }
        XCTAssertEqual(Set(app.visiblePanes), requestedPanes)
        XCTAssertEqual(app.workspace.detached.map(\.id), [remaining.id])
        app.workspace.restoreDetached([remaining.id])
        try await app.wait { app.workspace.detached.isEmpty }
        XCTAssertEqual(app.visiblePanes.count, 2)
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"]), processes)
    }

    func testExplicitDetachPreservesServerPanesAndWindows() async throws {
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        _ = try app.server(["split-window", "-d", "-t", "edge:0", "/bin/sh"])
        _ = try app.server(["new-window", "-d", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let original = try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"])
        let pane = try XCTUnwrap(app.workspace.spaces.flatMap(\.tabs).first { app.target($0) != nil })
        app.controller.detachTab(pane.id)
        try await app.wait { !app.workspace.allTabIDs.contains(pane.id) }
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"]), original)
        let tab = try XCTUnwrap(app.workspace.current?.activeWindow)
        app.controller.detachWindow(tab.id)
        try await app.wait { !app.workspace.spaces.flatMap(\.windows).contains { $0.id == tab.id } }
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"]), original)
        for space in app.workspace.spaces.filter({ $0.structured }) { app.controller.closeSpace(space.id) }
        try await app.wait { !app.attached }
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}:#{pane_pid}"]), original)
    }

    func testAutomaticHandoffLayoutsPlainSpacesAndGroupDetach() async throws {
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        for _ in 1..<4 { _ = try app.server(["new-window", "-d", "/bin/sh"]) }
        try await app.attach(); try await app.ready()
        let origin = try XCTUnwrap(app.origin)
        let first = try XCTUnwrap(app.workspace.current)
        XCTAssertFalse(app.workspace.allTabIDs.contains(origin.id))
        XCTAssertNotNil(app.runtime.views[origin.id], "The hidden gateway must remain alive for control mode")
        XCTAssertTrue(app.workspace.applyLayout(.columns))
        try await app.wait { app.workspace.current?.layout.paneIDs.count == 2 }
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}"]).split(separator: "\n").count, 4)
        XCTAssertTrue(app.workspace.applyLayout(.rows))
        try await app.wait {
            if case .split(_, .rows, _, _) = app.workspace.current?.layout { return true }; return false
        }
        for preset in [LayoutPreset.grid, .grid, .columns, .grid] { XCTAssertTrue(app.workspace.applyLayout(preset)) }
        try await app.wait { app.workspace.current?.panes.count == 4 }
        _ = try await app.query("#{window_id}")
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{pane_id}"]).split(separator: "\n").count, 4, "Rapid layout selections must not create duplicate shells")
        try await app.ready()
        try await PresentationTestSupport.chooseNewSpace(in: app.workspace)
        try await app.wait { app.workspace.current?.id != first.id }
        let plain = try XCTUnwrap(app.workspace.current)
        XCTAssertFalse(plain.structured); XCTAssertNil(plain.backend)
        XCTAssertEqual(app.workspace.activeTab?.machine, .local)
        app.workspace.selectSpace(first.id)
        try await PresentationTestSupport.chooseNewSpace("New tmux space", in: app.workspace)
        try await app.wait { app.workspace.spaces.filter { $0.structured }.count == 2 && app.workspace.activeTab?.isConnecting == false }
        let second = try XCTUnwrap(app.workspace.current)
        XCTAssertTrue(app.workspace.reorderSpace(plain.id, relativeTo: first.id, after: true))
        XCTAssertEqual(app.workspace.spaces.map(\.id), [first.id, plain.id, second.id])
        app.workspace.renameSpace(second.id, to: "Renamed tmux")
        try await app.wait { app.workspace.current?.name == "Renamed tmux" }
        XCTAssertEqual(app.workspace.spaces.map(\.id), [first.id, plain.id, second.id])
        _ = try await PresentationTestSupport.capture(app.window, named: "mixed-spaces-and-shortcuts", in: "integration-audit")
        let before = try app.server(["list-panes", "-a", "-F", "#{pane_pid}"])
        app.workspace.detachSpace(first.id)
        XCTAssertFalse(app.workspace.spaces.contains { $0.id == first.id })
        _ = try await app.query("#{window_id}")
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_pid}"]), before)
        XCTAssertFalse(app.workspace.spaces.contains { $0.id == first.id })
        app.workspace.detachSpace(second.id)
        try await app.wait { !app.workspace.spaces.contains(where: \.structured) && app.runtime.views[origin.id] == nil }
        XCTAssertEqual(app.workspace.spaces.map(\.id), [plain.id])
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_pid}"]), before)
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    /// The launcher hides in the turn that shows the tmux space: a turn ending with both would draw the
    /// sidebar that one space hides, and hide it again.
    func testHandoffKeepsTheSingleSpaceSidebarHidden() async throws {
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        XCTAssertFalse(app.controller.sidebarVisible)
        let shown = app.sidebarShown()
        try await app.attach(); try await app.ready()
        XCTAssertFalse(app.workspace.allTabIDs.contains(try XCTUnwrap(app.origin).id))
        XCTAssertEqual(app.workspace.spaces.count, 1)
        XCTAssertFalse(shown.withLock { $0 }, "The sidebar must stay hidden while the launcher hands off to tmux")
    }

    func testIntegrationToggleUsesExistingTerminalAndHandoffKeepsSibling() async throws {
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        let sibling = try XCTUnwrap(app.workspace.activeTab?.id)
        app.workspace.newTab()
        let sourceID = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[sourceID].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let source = try XCTUnwrap(app.runtime.views[sourceID])
        try await app.wait { source.foregroundPIDOverride != nil }
        let shellPID = source.foregroundPID
        var preferences = app.runtime.preferences
        preferences.spaces[on: "tmux"] = false
        try app.runtime.apply(preferences)
        TerminalTestSupport.send("\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge", to: source)
        try await TestSupport.eventually { try app.server(["list-clients", "-F", "#{client_control_mode}"]).contains("1") }
        try await app.wait { source.foregroundPID != shellPID }
        XCTAssertTrue(!app.workspace.spaces.contains(where: \.structured))
        _ = try app.server(["detach-client", "-s", "edge"])
        try await app.wait { source.foregroundPID == shellPID }
        TerminalTestSupport.send("printf 'DISABLED_%s\\n' RETURNED", to: source)
        try await app.wait { TerminalTestSupport.screen(terminal: source).contains("DISABLED_RETURNED") }
        preferences.spaces[on: "tmux"] = true
        try app.runtime.apply(preferences)
        try await app.attach(); try await app.ready()
        XCTAssertFalse(app.workspace.allTabIDs.contains(sourceID))
        XCTAssertTrue(app.workspace.allTabIDs.contains(sibling))
        // Detach the session the source terminal attached (its control client leaves).
        app.detachSession()
        try await app.wait { !app.workspace.spaces.contains(where: \.structured) && app.runtime.views[sourceID] == nil }
        XCTAssertEqual(app.workspace.activeTab?.id, sibling)
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    func testWindowTabsOwnLayoutsAndCommandShortcuts() async throws {
        let app = try TmuxWalkthrough()
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu; app.close() }
        let answerer = CloseConfirmationAnswerer(); defer { answerer.stop() }
        app.controller.buildMenus()
        _ = try app.server(["split-window", "-h", "-t", "%0", "/bin/sh"])
        try await app.attach()
        try await app.ready()
        let group = try XCTUnwrap(app.workspace.current)
        let first = try XCTUnwrap(group.activeWindow)
        let firstTerminal = try XCTUnwrap(app.workspace.activeTab)
        let firstView = try XCTUnwrap(app.runtime.views[firstTerminal.id])
        let surface = firstView.surface
        func press(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = .command) {
            XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: TerminalTestSupport.keyEvent(code, text, in: app.window, modifiers: modifiers)) == true)
        }
        press(17, "t")
        try await app.wait { app.workspace.current?.windows.count == 2 && app.workspace.current?.activeWindow.flatMap({ app.target($0) }) == "@1" }
        XCTAssertEqual(app.workspace.current?.id, group.id, "Cmd+T adds a tab in the same space")
        XCTAssertEqual(app.workspace.spaces.filter { $0.structured }.count, 1)
        XCTAssertEqual(app.workspace.current?.panes.count, 1)
        XCTAssertEqual(app.workspace.current?.windows.first { $0.id == first.id }?.arrangement.panes.count, 2)
        try await app.ready()
        app.workspace.split(.rows)
        try await app.wait { app.workspace.current?.panes.count == 3 }
        let second = try XCTUnwrap(app.workspace.current?.activeWindow)
        app.workspace.selectPane(at: 0)
        try await app.ready()
        XCTAssertEqual(app.workspace.current?.activeWindow?.id, first.id)
        XCTAssertTrue(app.runtime.views[firstTerminal.id]?.surface === surface)
        app.workspace.cycleTab(1)
        try await app.ready()
        XCTAssertEqual(app.workspace.current?.activeWindow?.id, first.id, "Tab cycling stays in the current pane")
        app.workspace.selectPane(at: 1)
        try await app.ready()
        XCTAssertEqual(app.workspace.current?.activeWindow?.id, second.id)
        // A hidden window keeps processing output; selecting its tab restores it.
        _ = try app.server(["send-keys", "-t", try XCTUnwrap(app.target(firstTerminal)), "printf 'BACKGROUND_%s\\n' ALIVE", "Enter"])
        app.workspace.selectWindow(first.id)
        try await app.ready()
        try await app.wait { app.visibleText(firstView).contains("BACKGROUND_ALIVE") }
        press(45, "n")
        try await app.wait { app.workspace.spaces.filter { $0.structured }.count == 2 && app.workspace.activeTab?.isConnecting == false }
        XCTAssertNotEqual(app.workspace.current?.id, group.id, "Cmd+N creates a distinct space")
        try await app.ready()
        XCTAssertFalse(app.workspace.canSplit, "Add another tab before splitting a native tmux space")
        app.workspace.split(.columns)
        XCTAssertEqual(app.workspace.current?.panes.count, 1)
        let closedWindow = try XCTUnwrap(app.workspace.current?.activeWindow)
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        press(13, "W", modifiers: [.command, .shift])
        try await app.wait { !app.workspace.spaces.flatMap(\.windows).contains { $0.id == closedWindow.id } && !app.workspace.detached.isEmpty }
        XCTAssertEqual(app.workspace.spaces.filter { $0.structured }.count, 1)
        XCTAssertEqual(app.workspace.current?.windows.count, 2, "Shift+Cmd+W detaches the selected space, preserving other tabs")
        XCTAssertEqual(app.workspace.detached.count, 1)
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes,
                       "The detach shortcut must preserve every server process")
        app.workspace.selectWindow(second.id)
        try await app.ready()
        try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration + 0.05))
        _ = try await PresentationTestSupport.capture(app.window, named: "tmux-window-tabs")
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    func testExternalWindowsJoinTheActiveGroupAndClosingAGroupClosesAllItsTabs() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        let answerer = CloseConfirmationAnswerer(); defer { answerer.stop() }
        try await app.attach()
        let original = try XCTUnwrap(app.workspace.current?.activeWindow)
        app.workspace.newSpace()
        try await app.wait { app.workspace.spaces.filter { $0.structured }.count == 2 && app.workspace.current?.activeWindow.flatMap(app.target) == "@1" }
        let group = try XCTUnwrap(app.workspace.current)
        _ = try app.server(["new-window", "-n", "external", "/bin/sh"])
        try await app.wait { app.workspace.current?.windows.count == 2 && app.workspace.current?.activeWindow?.name == "external" }
        XCTAssertEqual(app.workspace.current?.id, group.id)
        app.controller.closeWindow(original.id)
        try await app.wait { app.workspace.spaces.filter { $0.structured }.count == 1 }
        XCTAssertEqual(app.workspace.current?.id, group.id, "Closing an inactive tab does not select it")
        XCTAssertEqual(app.workspace.current?.activeWindow?.name, "external")
        app.workspace.closeSpace(group.id)
        try await TestSupport.eventually(diagnostic: "spaces: \(app.workspace.spaces.map { ($0.name, $0.windows.map(\.name)) }), server: \((try? app.server(["list-windows", "-a"])) ?? "none")") {
            !app.workspace.spaces.contains { $0.structured }
        }
        XCTAssertEqual(app.workspace.activeTab?.id, app.origin?.id)
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    func testNewerSelectionSupersedesPendingWindowPlacementAndMove() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let workspace = app.workspace
        try await app.attach()
        for count in 2...3 {
            workspace.newSpace()
            try await app.wait {
                workspace.spaces.filter(\.structured).count == count
                    && workspace.spaces.filter(\.structured).flatMap(\.tabs).allSatisfy { !$0.isConnecting }
            }
        }
        try await app.ready()
        let windows = workspace.spaces.filter(\.structured).flatMap(\.windows)
        let first = try XCTUnwrap(windows.first), second = try XCTUnwrap(windows.dropFirst().first),
            third = try XCTUnwrap(windows.dropFirst(2).first)
        let secondTab = try XCTUnwrap(second.terminals.first), thirdTab = try XCTUnwrap(third.terminals.first)
        let secondKey = try XCTUnwrap(app.target(second)), thirdKey = try XCTUnwrap(app.target(third))
        try app.stall()
        workspace.moveWindowToNewSpace(first.id)
        workspace.selectTab(secondTab.id)
        app.resume()
        let secondSelection = try await app.query("#{window_id}")
        XCTAssertEqual(secondSelection, secondKey)
        XCTAssertEqual(workspace.activeTab?.id, secondTab.id)

        try app.stall()
        XCTAssertTrue(workspace.moveWindow(first.id, beside: third.id))
        workspace.selectTab(thirdTab.id)
        app.resume()
        try await app.wait {
            workspace.spaces.contains { Set($0.windows.map(\.id)) == Set([first.id, third.id]) }
        }
        let thirdSelection = try await app.query("#{window_id}")
        XCTAssertEqual(thirdSelection, thirdKey)
        XCTAssertEqual(workspace.activeTab?.id, thirdTab.id)
    }

    func testSuccessivePendingWindowPlacementsKeepTheLatestSpaceIdentity() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attach(); try await app.ready()
        let workspace = app.workspace
        let window = try XCTUnwrap(workspace.current?.activeWindow)
        let terminal = try XCTUnwrap(workspace.activeTab)
        let target = try XCTUnwrap(app.target(window))
        try app.stall()
        workspace.moveWindowToNewSpace(window.id)
        let first = workspace.selectedSpace
        workspace.moveWindowToNewSpace(window.id)
        let latest = try XCTUnwrap(workspace.selectedSpace)
        XCTAssertNotEqual(latest, first)
        app.resume()
        let focused = try await app.query("#{window_id}")
        XCTAssertEqual(focused, target)
        XCTAssertEqual(workspace.selectedSpace, latest)
        XCTAssertEqual(workspace.current?.windows.map(\.id), [window.id])
        XCTAssertEqual(workspace.current?.tabs.map(\.id), [terminal.id])
        XCTAssertEqual(workspace.spaces.flatMap(\.tabs).filter { $0.id == terminal.id }.count, 1)
    }

    func testWindowTabGroupingReordersMovesAndRestoresOnReconnect() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        for name in ["second", "third"] { _ = try app.server(["new-window", "-d", "-n", name, "/bin/sh"]) }
        try await app.attach()
        let initial = try XCTUnwrap(app.workspace.current)
        XCTAssertEqual(initial.windows.map { app.target($0) }, ["@0", "@1", "@2"])
        guard initial.windows.count == 3 else { return } // a failed check above must not crash the batch
        let second = initial.windows[1], third = initial.windows[2]
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}|#{pane_pid}|#{window_id}"])
        app.workspace.moveWindowToNewSpace(second.id)
        try await app.wait { app.workspace.spaces.filter { $0.structured }.count == 2 && app.workspace.current?.activeWindow.flatMap({ app.target($0) }) == "@1" }
        let destination = try XCTUnwrap(app.workspace.current)
        XCTAssertTrue(app.workspace.moveWindow(third.id, beside: second.id))
        try await app.wait { app.workspace.current?.windows.map { app.target($0) } == ["@2", "@1"] }
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}|#{pane_pid}|#{window_id}"]), processes,
                       "Moving tabs changes presentation metadata, never server pane ownership")
        let name = "Research | \"quoted\" $ 雪"
        app.workspace.renameSpace(destination.id, to: name)
        try await app.wait { app.workspace.current?.name == name }
        app.workspace.renameWindow(third.id, to: "Window | 雪")
        try await app.wait { app.workspace.current?.activeWindow?.name == "Window | 雪" }
        // Wait for a command barrier after all metadata writes before detaching.
        _ = try await app.query("#{window_id}")
        app.detachSession()
        try await app.wait { !app.attached }
        try await app.attach()
        try await app.wait { app.workspace.spaces.filter { $0.structured }.count == 2 && app.workspace.activeTab?.isConnecting == false }
        let restored = try XCTUnwrap(app.workspace.spaces.first { $0.name == name })
        XCTAssertEqual(restored.windows.map { app.target($0) }, ["@2", "@1"])
        XCTAssertEqual(restored.windows.first?.name, "Window | 雪")
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}|#{pane_pid}|#{window_id}"]), processes)
        let external = TmuxSpaceAffinity(group: UUID(), name: "External grouping", order: 0, usesDirectoryName: false)
        _ = try app.server(["set-option", "-w", "-t", "@2", TmuxSpaceAffinity.option, external.encoded])
        try await app.wait { app.workspace.spaces.contains { $0.name == external.name && $0.windows.map { app.target($0) } == ["@2"] } }
        _ = try app.server(["kill-window", "-t", "@1"])
        try await app.wait { !app.workspace.spaces.flatMap(\.windows).contains { app.target($0) == "@1" } }
        XCTAssertEqual(app.workspace.spaces.filter { $0.structured }.count, 2)
        // Future or malformed metadata must not make a real window inaccessible.
        _ = try app.server(["set-option", "-w", "-t", "@2", TmuxSpaceAffinity.option, "invalid|metadata"])
        _ = try await app.query("#{window_id}")
        XCTAssertTrue(app.workspace.spaces.flatMap(\.windows).contains { app.target($0) == "@2" })
        XCTAssertEqual(app.workspace.spaces.flatMap(\.windows).first { app.target($0) == "@2" }?.name, "Window | 雪")
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    func testMovingWindowsRetainsExistingSplitsAndClosingOriginDetaches() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        _ = try app.server(["split-window", "-h", "-t", "%0", "/bin/sh"])
        _ = try app.server(["new-window", "-d", "-n", "destination", "/bin/sh"])
        try await app.attach()
        try await app.wait { app.visiblePanes.contains("%0") }
        let source = try XCTUnwrap(app.workspace.spaces.flatMap(\.tabs).first { app.target($0) == "%0" })
        let view = try XCTUnwrap(app.runtime.views[source.id])
        let surface = view.surface
        let pid = try app.server(["display-message", "-p", "-t", "%0", "#{pane_pid}"])
        let destination = try XCTUnwrap(app.workspace.spaces.flatMap(\.windows).first { app.target($0) == "@1" }?.arrangement.focusedPane)
        XCTAssertTrue(app.workspace.splitTab(source.id, beside: destination, edge: .right))
        try await app.wait { app.workspace.current?.panes.count == 3 }
        XCTAssertTrue(app.workspace.moveTab(source.id, to: destination))
        try await app.wait { app.workspace.current?.panes.count == 2 }
        XCTAssertEqual(app.workspace.spaces.flatMap(\.windows).first(where: { app.target($0) == "@0" })?.terminals.count, 2)
        XCTAssertTrue(app.runtime.views[source.id]?.surface === surface)
        XCTAssertEqual(try app.server(["display-message", "-p", "-t", "%0", "#{pane_pid}"]), pid)

        app.workspace.moveTabToNewSpace(source.id)
        try await app.wait { app.workspace.spaces.filter { $0.structured }.count == 2 && app.workspace.current?.activeWindow.flatMap({ app.target($0) }) == "@0" }
        app.workspace.selectTab(source.id)
        try await app.ready()
        TerminalTestSupport.send("printf 'MOVED_%s\\n' ALIVE", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("MOVED_ALIVE") }
        XCTAssertTrue(app.runtime.views[source.id]?.surface === surface)
        app.workspace.closeTab(source.id)
        try await app.wait { !app.workspace.allTabIDs.contains(source.id) && app.runtime.helpers.values.allSatisfy { $0.operations == 0 } }
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}"]).split(separator: "\n").count, 2)

        let survivors = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        app.workspace.closeTab(try XCTUnwrap(app.origin?.id))
        try await app.wait { !app.attached }
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), survivors)
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    func testLinkedWindowAliasesShareOneNativeSpace() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        _ = try app.server(["link-window", "-s", "edge:0", "-t", "edge:2"])
        try await app.attach(); try await app.ready()
        XCTAssertEqual(app.workspace.spaces.filter { $0.structured }.count, 1)
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let view = try XCTUnwrap(app.runtime.views[tab.id])
        let surface = view.surface
        _ = try app.server(["unlink-window", "-k", "-t", "edge:2"])
        TerminalTestSupport.send("printf 'LINKED_%s\\n' SURVIVOR", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("LINKED_SURVIVOR") }
        XCTAssertTrue(app.runtime.views[tab.id]?.surface === surface)
        XCTAssertEqual(app.workspace.spaces.filter { $0.structured }.count, 1)
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    func testInitialFocusNativeWindowSelectionAndSessionSwitch() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        _ = try app.server(["split-window", "-h", "-t", "%0", "/bin/sh"])
        _ = try app.server(["new-window", "-d", "-n", "second", "/bin/sh"])
        try await app.attach(); try await app.ready()
        XCTAssertEqual(app.workspace.activeTab.flatMap(app.target), "%1", "Attach restores the active pane, even when it is not first")
        let windows = app.workspace.spaces.flatMap(\.windows)
        let first = try XCTUnwrap(windows.first { app.target($0) == "@0" })
        let second = try XCTUnwrap(windows.first { app.target($0) == "@1" })
        app.workspace.selectTab(try XCTUnwrap(first.terminals.first { app.target($0) == "%0" }?.id))
        let selectedPane = try await app.query("#{pane_id}")
        XCTAssertEqual(selectedPane, "%0")
        _ = try app.server(["select-pane", "-t", "%0"])
        _ = try app.server(["select-pane", "-t", "%1"])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(app.workspace.activeTab.flatMap(app.target), "%0", "Other clients do not steal this client's pane focus")
        app.workspace.selectWindow(second.id)
        let selectedWindow = try await app.query("#{window_id}")
        XCTAssertEqual(selectedWindow, "@1", "Native space changes select the server window")
        try await TestSupport.eventually { try app.server(["display-message", "-p", "-t", "edge", "#{window_id}"]).hasPrefix("@1") }

        _ = try app.server(["select-window", "-t", "@0"])
        try await app.wait { app.workspace.current?.activeWindow.flatMap(app.target) == "@0" }
        XCTAssertEqual(app.workspace.current?.activeWindow.flatMap(app.target), "@0", "Server window changes select the native space")
        for index in 0..<12 { app.workspace.selectWindow(index.isMultiple(of: 2) ? first.id : second.id) }
        let lastWindow = try await app.query("#{window_id}")
        XCTAssertEqual(lastWindow, "@1")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(app.workspace.current?.activeWindow.flatMap(app.target), "@1", "Old notifications must not undo rapid navigation")

        _ = try app.server(["new-session", "-d", "-s", "other", "-n", "other-first", "/bin/sh"])
        _ = try app.server(["new-window", "-t", "other:", "-n", "other-active", "/bin/sh"])
        // The app's control client switches like any client the user switches from the server.
        let control = try XCTUnwrap(try app.server(["list-clients", "-F", "#{client_control_mode} #{client_name}"])
            .split(separator: "\n").first { $0.hasPrefix("1 ") }?.dropFirst(2))
        _ = try app.server(["switch-client", "-c", String(control), "-t", "other"])
        try await app.wait { app.workspace.current?.activeWindow?.name == "other-active" }
        XCTAssertEqual(app.workspace.current?.activeWindow?.name, "other-active", "Switching sessions restores its active window")
        XCTAssertNil(app.runtime.helpers[.local]?.error)
        try await app.ready()
        let switched = try XCTUnwrap(app.runtime.views[app.workspace.activeTab!.id])
        TerminalTestSupport.send("printf 'SWITCHED_%s\\n' SESSION_READY", to: switched)
        try await app.wait { app.visibleText(switched).contains("SWITCHED_SESSION_READY") }
        for size in [NSSize(width: 960, height: 620), NSSize(width: 1240, height: 820), NSSize(width: 1120, height: 740)] {
            let pane = try XCTUnwrap(app.target(app.workspace.activeTab!))
            let measure = { try app.server(["display-message", "-p", "-t", pane, "#{pane_width}x#{pane_height}"]) }
            let previous = try measure()
            app.window.setContentSize(size)
            try await TestSupport.eventually { try measure() != previous }
            try await app.ready()
            XCTAssertTrue(app.visibleText(switched).contains("SWITCHED_SESSION_READY"), "Restoration stays in the viewport after resize")
        }
        try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration))
        if #available(macOS 14.4, *) {
            let content = try await SCShareableContent.currentProcess
            let window = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(app.window.windowNumber) })
            let config = SCStreamConfiguration()
            config.width = Int(app.window.frame.width * app.window.backingScaleFactor)
            config.height = Int(app.window.frame.height * app.window.backingScaleFactor)
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            let bitmap = NSBitmapImageRep(cgImage: image)
            try PresentationTestSupport.save(bitmap, named: "tmux-session-switch", in: "ui-audit")
            // Exact terminal text was checked above (visibleText); here prove the restored line is visible in
            // the rendered window. Vision splits the marker at underscores or merges the next prompt into it
            // (macOS 27: "SWITCHED sh-3.2$ SESSION_READY", macOS 26: "SWITCHED. _SESSION_READY").
            try PresentationTestSupport.assertText("SWITCHED_SESSION_READY", ["SWITCHED SESSION_READY", "SWITCHED_ SESSION_READY",
                "SWITCHED sh-3.2$ SESSION_READY", "SWITCHED. _SESSION_READY"], in: PresentationTestSupport.Snapshot(bitmap: bitmap))
        }
    }

    func testPaneBorderRowsAndRestoredTitles() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        _ = try app.server(["set-option", "-g", "pane-border-status", "top"])
        _ = try app.server(["select-pane", "-t", "%0", "-T", "Saved title | 雪"])
        _ = try app.server(["send-keys", "-t", "%0", "printf 'BORDER_%s\\n' READY", "Enter"])
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let view = try XCTUnwrap(app.runtime.views[tab.id])
        XCTAssertEqual(tab.title, "Saved title | 雪", "Attach restores the pane title without waiting for new OSC output")
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("BORDER_READY") }
        for status in ["bottom", "off", "top"] {
            _ = try app.server(["set-option", "-g", "pane-border-status", status])
            try await TestSupport.eventually(timeout: .seconds(5), diagnostic: "Grid with border \(status)") {
                let height = try XCTUnwrap(Int(try app.server(["display-message", "-p", "-t", "%0", "#{pane_height}"]).trimmingCharacters(in: .whitespacesAndNewlines)))
                return view.surface.map { $0.grid.rows == height } == true
            }
        }
        _ = try app.server(["split-window", "-v", "-t", "%0", "/bin/sh"])
        try await app.wait { app.workspace.current?.panes.count == 2
            && app.workspace.current!.tabs.allSatisfy { app.runtime.views[$0.id]?.surface != nil } }
        for tab in app.workspace.current!.tabs {
            let pane = try XCTUnwrap(app.target(tab))
            try await TestSupport.eventually {
                let height = try XCTUnwrap(Int(try app.server(["display-message", "-p", "-t", pane, "#{pane_height}"]).trimmingCharacters(in: .whitespacesAndNewlines)))
                return app.runtime.views[tab.id]?.surface.map { $0.grid.rows == height } == true
            }
        }
        try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration))
        _ = try await PresentationTestSupport.capture(app.window, named: "tmux-border-rows")
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    func testInterruptedTitleSequenceDoesNotHideLaterOutput() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        try await app.attach(); try await app.ready()
        let view = try XCTUnwrap(app.runtime.views[app.workspace.activeTab!.id])
        TerminalTestSupport.send("printf '\\033]2;unfinished\\033[0mAFTER_%s\\n' INTERRUPTED_TITLE", to: view)
        try await TestSupport.eventually(diagnostic: "Native: \(TerminalTestSupport.screen(terminal: view)); server: \((try? app.server(["capture-pane", "-p", "-t", "%0"])) ?? "unavailable")") {
            TerminalTestSupport.screen(terminal: view).contains("AFTER_INTERRUPTED_TITLE")
        }
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }
}

/// Window grouping metadata the helper's tmux module reads (native fixture tooling: tests set it the way
/// another Dispatch or an older version would have left it).
struct TmuxSpaceAffinity: Codable {
    static let option = "@dispatch-window"
    var version = 1
    var group: UUID
    var name: String
    var order: Int
    var usesDirectoryName: Bool? = true

    var encoded: String { (try? JSONEncoder().encode(self).base64EncodedString()) ?? "" }
}

/// A real PTY/control client and native window, isolated from the user's server.
@MainActor
final class TmuxWalkthrough {
    private var cleanup: Task<Void, Never>?
    private let restore = TestSupport.preserveRuntime()
    let socket: String
    let runtime = TerminalRuntime.shared
    let controller = AppDelegate()
    let window: MainWindow
    private(set) var origin: TerminalView?
    var workspace: Workspace { controller.workspace }

    /// `liquidGlass` defaults to the app's own default. Walkthroughs that read the window through offscreen
    /// captures turn it off: those captures cannot draw Liquid Glass.
    init(autoClose: Bool = false, server: Bool = true, liquidGlass: Bool = Preferences().liquidGlass) throws {
        socket = try TestSupport.fixture("tmux.socket", input: Data()) { "dispatch-edge-test-\(UUID().uuidString)" }
        try DesktopTestSupport.requireUnlocked()
        guard FileManager.default.isExecutableFile(atPath: TestSupport.tool("tmux")) else { throw XCTSkip("Requires tmux") }
        window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        if server {
            _ = try self.server(["-f", "/dev/null", "new-session", "-d", "-s", "edge", "-x", "100", "-y", "35", "/bin/sh"])
        }
        runtime.workspace = workspace
        var preferences = Preferences(); preferences.closeLaunching = ["tmux": autoClose, "herdr": autoClose]
        preferences.liquidGlass = liquidGlass
        controller.settings.values = preferences
        runtime.start(preferences: preferences)
        XCTAssertNil(runtime.error)
        workspace.onCloseTabs = { [runtime] in runtime.close($0) }
        workspace.newLocalSpace()
        controller.window = window
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    /// The line a user types to attach the test's session. `login`: the server is first started from that
    /// terminal, so its panes carry that login's environment, as a server on an SSH host does (the test
    /// process's environment, e.g. its capture paths, never reaches an agent behind a "remote" tmux).
    func attachCommand(login: Bool = false) -> String {
        let tmux = "\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(socket)"
        let attach = tmux + " -CC attach -t edge"
        return login ? "\(tmux) -f /dev/null new-session -d -s edge -x 100 -y 35 /bin/sh && \(attach)" : attach
    }

    func server(_ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: TestSupport.tool("tmux"))
        process.arguments = ["-u", "-L", socket] + arguments
        process.standardOutput = output; process.standardError = error
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX"); process.environment = environment
        return String(decoding: try AppReplay.query(kind: "fixture.tmux.command", input: JSONEncoder().encode(AppReplay.Launch(process))) {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "TmuxWalkthrough", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey:
                    arguments.joined(separator: " ") + ": " + String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
            }
            return data
        }, as: UTF8.self)
    }

    /// From now on, whether any turn that changed the sidebar ended with it shown: the state the window draws next.
    func sidebarShown() -> OSAllocatedUnfairLock<Bool> {
        let shown = OSAllocatedUnfairLock(initialState: false)
        Self.record(sidebarOf: controller, into: shown)
        return shown
    }

    private static func record(sidebarOf controller: AppDelegate, into shown: OSAllocatedUnfairLock<Bool>) {
        withObservationTracking { _ = controller.sidebarVisible } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let visible = controller.sidebarVisible
                    shown.withLock { $0 = $0 || visible }
                    record(sidebarOf: controller, into: shown)
                }
            }
        }
    }

    func attach(command: String? = nil) async throws {
        try await wait { self.runtime.helpers.values.allSatisfy { $0.operations == 0 } }
        let id = try XCTUnwrap(workspace.activeTab?.id)
        try await wait { self.runtime.views[id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        origin = try XCTUnwrap(runtime.views[id])
        TerminalTestSupport.send(command ?? "\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(socket) -CC attach -t edge", to: origin!)
        try await TestSupport.eventually(diagnostic: "Attach screen: \(origin.map { TerminalTestSupport.screen(terminal: $0) } ?? "missing"); \(runtime.helpers[.local]?.error ?? "No helper error")") { self.workspace.current?.structured == true }
    }

    /// Real faults instead of hooks into whichever tmux client the app uses: `stall()`
    /// SIGSTOPs this test's server so nothing sent to it is processed until `resume()`; `disconnect()`
    /// kills the control client (a lost connection); `crash()` kills the server.
    private var stalled: (server: pid_t, client: pid_t)?

    func stall() throws {
        let server = try XCTUnwrap(pid_t(try self.server(["display-message", "-p", "#{pid}"]).trimmingCharacters(in: .whitespacesAndNewlines)))
        let client = try XCTUnwrap(try self.server(["list-clients", "-F", "#{client_control_mode} #{client_pid}"])
            .split(separator: "\n").first { $0.hasPrefix("1 ") }.flatMap { pid_t($0.dropFirst(2)) })
        stalled = (server, client)
        XCTAssertEqual(kill(server, SIGSTOP), 0)
    }

    func resume() {
        if let stalled { kill(stalled.server, SIGCONT) }
    }

    /// A lost connection: the SSH client when attached over SSH (the connection that can go offline
    /// and come back), otherwise the control client itself.
    func disconnect() throws {
        guard ssh != nil else {
            XCTAssertEqual(kill(try XCTUnwrap(stalled).client, SIGKILL), 0)
            return
        }
        let pgrep = Process(), output = Pipe()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "^/usr/bin/ssh .*" + socket]
        pgrep.standardOutput = output
        try pgrep.run(); pgrep.waitUntilExit()
        let pids = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { pid_t($0) }
        XCTAssertFalse(pids.isEmpty, "No SSH client for this test's tmux")
        for pid in pids { kill(pid, SIGKILL) }
    }

    private var ssh: SSHTestServer?

    /// Attaches through a real SSH connection to this machine.
    func attachOverSSH() async throws {
        let server = try await SSHTestServer(transportOnly: true)
        ssh = server
        let remote = "\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(socket) -CC attach -t edge"
        try await attach(command: "TERM=xterm-256color /usr/bin/ssh " + (["-tt"] + server.options + [server.destination, remote])
            .map(HerdrLaunch.quote).joined(separator: " "))
    }

    func crash() throws {
        let stalled = try XCTUnwrap(stalled)
        XCTAssertEqual(kill(stalled.server, SIGKILL), 0)
        kill(stalled.server, SIGCONT)
        self.stalled = nil
    }

    /// tmux target of a pane ("%3"), read from the helper's node key.
    func target(_ tab: TerminalTab) -> String? {
        // The helper of the tab's space: this Mac's, or the SSH host's for a remote tmux.
        return tab.terminal.flatMap { workspace.helper(containing: tab.id)?.node($0)?.key }
            .flatMap { $0.split(separator: ":").last.map(String.init) }.flatMap { $0.hasPrefix("%") ? $0 : nil }
    }

    /// tmux target of a window ("@1"), read from the helper's node key.
    func target(_ window: Space.Window) -> String? {
        return workspace.spaces.flatMap(\.containers).first { $0.id == window.id }
            .flatMap { workspace.helper(containing: window.id)?.node($0.node)?.key }
            .flatMap { $0.split(separator: ":").last.map(String.init) }.flatMap { $0.hasPrefix("@") ? $0 : nil }
    }

    /// The server answers in the helper control client's native focus, not the session's global pane.
    func query(_ format: String) async throws -> String {
        try await wait { self.runtime.helpers.values.allSatisfy { $0.operations == 0 } }
        let topology = try XCTUnwrap(workspace.helper(workspace.current)?.snapshots.values.first {
            $0.backend == workspace.current?.backend
        })
        let focus = try XCTUnwrap(topology.focus)
        let node = try XCTUnwrap(topology.nodes.first { $0.id == focus })
        let target = try XCTUnwrap(node.key.split(separator: ":").last.map(String.init))
        let output = try server(["display-message", "-p", "-t", target, format])
        return output.hasSuffix("\n") ? String(output.dropLast()) : output
    }

    /// tmux panes shown in the workspace, as tmux targets ("%3"); a pane shown twice appears twice. Other
    /// terminals (the plain shell the client runs in) are not tmux panes.
    var visiblePanes: [String] { workspace.spaces.flatMap(\.tabs).compactMap { target($0) }.filter { $0.hasPrefix("%") } }

    /// Panes of one window, as tmux targets.
    func panes(_ window: Space.Window) -> Set<String> { Set(window.terminals.compactMap(target)) }

    /// Detaches a window as the user does; returns its new sidebar entry and the window's panes (tmux targets).
    func detach(_ window: Space.Window) async throws -> (entry: DetachedEntry, panes: Set<String>) {
        let panes = panes(window), known = Set(workspace.detached.map(\.id))
        controller.detachWindow(window.id)
        try await wait { self.workspace.detached.contains { !known.contains($0.id) } }
        return (try XCTUnwrap(workspace.detached.first { !known.contains($0.id) }), panes)
    }

    /// The test server's socket path.
    func socketPath() throws -> String { try server(["display-message", "-p", "#{socket_path}"]).trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Detaches the session: every structured space leaves, its work keeps running.
    func detachSession() {
        for space in workspace.spaces where space.structured { workspace.detachSpace(space.id) }
    }

    /// Some multiplexer session is shown (a structured space).
    var attached: Bool { workspace.spaces.contains(where: \.structured) }

    /// The local helper's reported error (what the app shows in its banner).
    var error: String? { runtime.helpers[.local]?.error }

    /// The active pane's helper terminal is bound and rendered in this window.
    func ready() async throws {
        try await wait {
            guard let tab = self.workspace.activeTab, let terminal = tab.terminal, let view = self.runtime.views[tab.id],
                  let helper = self.workspace.helper(containing: tab.id),
                  helper.operations == 0, helper.sized[terminal] != nil else { return false }
            return view.window === self.window && view.surface != nil
        }
    }

    func visibleText(_ view: TerminalView) -> String {
        guard let surface = view.surface else { return "" }
        return surface.readText(.viewport)
    }

    func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async throws {
        try await TestSupport.eventually(timeout: .seconds(5), interval: .milliseconds(25), file: file, line: line,
            diagnostic: "tmux walkthrough: \(runtime.helpers[.local]?.error ?? "No helper error")", condition)
    }

    @discardableResult
    func close() -> Task<Void, Never> {
        if let cleanup { return cleanup }
        window.orderOut(nil); window.contentView = nil
        let cleanup = runtime.stop()
        self.cleanup = cleanup
        resume()
        ssh?.stop()
        _ = try? server(["kill-server"])
        restore()
        return cleanup
    }
}

extension TmuxWalkthrough {
    /// An interactive SSH login to the test server in `surface`'s shell; returns once its link has the remote shell.
    /// The local shell prints LOCAL_EXIT_<status> when ssh ends.
    func login(_ server: SSHTestServer, surface: UUID) async throws -> SSHCoordinator.Link {
        try await wait { self.runtime.views[surface].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(runtime.views[surface])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ") + "; printf 'LOCAL_EXIT_%s\\n' \"$?\"", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "SSH screen: \(TerminalTestSupport.screen(terminal: terminal)); sessions: \(runtime.ssh.links.values.map { ($0.grant.selectedFeatures, $0.shellPID) })") {
            self.runtime.ssh.links.values.contains { $0.launch.tabID == surface && $0.shellPID != nil }
        }
        return try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == surface })
    }
}
