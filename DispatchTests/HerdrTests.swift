import AppKit
import Foundation
import XCTest
import Observation
import os
@testable import DispatchApp

// A real herdr server, shown through the helper, checks what the app shows for user actions: a SIGSTOPped
// server holds replies (a pending command), herdr's own socket API is the external client. herdr's snapshots,
// RPC ordering, retries and identities are tested with the helper's herdr multiplexer.
@MainActor
final class HerdrTests: XCTestCase {

    func testTwoAboveLayoutRecognition() async throws {
        for shape in 0..<3 {
            let herdr = try await HerdrSession(); defer { herdr.close() }
            let first = try XCTUnwrap(herdr.snapshot().panes.first).pane_id
            if shape == 2 {
                _ = try herdr.api("pane.split", ["target_pane_id": first, "direction": "right", "ratio": 0.66])
            } else {
                _ = try herdr.api("pane.split", ["target_pane_id": first, "direction": "down", "ratio": 0.5])
                let target = try (shape == 0 ? first : XCTUnwrap(herdr.snapshot().panes.first { $0.pane_id != first }).pane_id)
                _ = try herdr.api("pane.split", ["target_pane_id": target, "direction": "right", "ratio": 0.5])
            }
            let count = shape == 2 ? 2 : 3
            try await TestSupport.eventually { herdr.app.workspace.current?.activeWindow?.arrangement.panes.count == count }
            XCTAssertEqual(herdr.app.workspace.current?.activeWindow?.arrangement.preset, shape == 0 ? .twoAbove : nil,
                "Only splitting the upper row is 2 above; lower-row and two-pane splits remain custom")
        }
    }

    func testLargeSessionSkipsIdleInvalidationAndPreservesChangedIdentities() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        // 20 workspaces of 22 tabs, the last one labelled "Original": each tab holds a pty, and macOS allows 511
        // (kern.tty.ptmx_max), some of which the rest of the Mac already uses.
        let source = try XCTUnwrap(herdr.snapshot().workspaces.first).workspace_id
        for _ in 1..<20 { _ = try herdr.api("workspace.create", ["source_workspace_id": source, "focus": false]) }
        for space in try herdr.snapshot().workspaces {
            for _ in 1..<22 { _ = try herdr.api("tab.create", ["workspace_id": space.workspace_id, "focus": false]) }
        }
        let last = try XCTUnwrap(herdr.snapshot().workspaces.last).workspace_id
        _ = try herdr.api("workspace.rename", ["workspace_id": last, "label": "Original"])
        try await TestSupport.eventually(timeout: .seconds(60)) {
            herdr.spaces.count == 20 && herdr.spaces.flatMap(\.tabs).count == 440 && herdr.spaces.last?.name == "Original"
        }
        let ids = workspace.allSurfaceIDs
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = workspace.spaces; _ = herdr.app.runtime.helpers[.local]?.error
        } onChange: { changes.withLock { $0 += 1 } }
        // Server events that leave everything the app shows unchanged.
        let start = Date.timeIntervalSinceReferenceDate
        for _ in 0..<100 { _ = try herdr.api("workspace.rename", ["workspace_id": last, "label": "Original"]) }
        try await Task.sleep(for: .milliseconds(500))
        let idleTime = Date.timeIntervalSinceReferenceDate - start
        let invalidations = changes.withLock { $0 }
        var closed: [UUID] = []
        let close = workspace.onCloseTabs
        workspace.onCloseTabs = { closed += $0; close($0) }
        let changedStart = Date.timeIntervalSinceReferenceDate
        for index in 0..<20 {
            let revision = workspace.layoutRevision, label = index.isMultiple(of: 2) ? "Updated" : "Original"
            _ = try herdr.api("workspace.rename", ["workspace_id": last, "label": label])
            try await TestSupport.eventually { herdr.spaces.last?.name == label }
            XCTAssertEqual(workspace.layoutRevision, revision + 1)
        }
        let changedTime = Date.timeIntervalSinceReferenceDate - changedStart
        print(String(format: "HERDR PERFORMANCE: 500 tabs, idle=%.3f ms/event, changed=%.3f ms/event, idle invalidations=%d",
                     idleTime * 10, changedTime * 50, invalidations))
        XCTAssertEqual(invalidations, 0, "Identical server states must not invalidate the native UI")
        XCTAssertEqual(herdr.spaces.last?.name, "Original")
        XCTAssertEqual(workspace.allSurfaceIDs, ids, "Every native tab and terminal keeps its identity")
        XCTAssertTrue(closed.isEmpty)
    }

    func testEndpointAliasesShareNativeIdentity() async throws {
        // Socket path normalization (HerdrEndpoint.localPath) is the herdr multiplexer's (moved).
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let source = try XCTUnwrap(herdr.snapshot().workspaces.first).workspace_id
        _ = try herdr.api("workspace.create", ["source_workspace_id": source, "focus": false])
        try await TestSupport.eventually { herdr.spaces.count == 2 }
        let ids = workspace.allSurfaceIDs
        // Another executable path and session name, through a symlinked directory, reach the same server.
        let alias = herdr.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: herdr.root)
        let bin = herdr.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("herdr").path, withDestinationPath: TestSupport.tool("herdr"))
        workspace.newLocalSpace()
        let launcher = try XCTUnwrap(workspace.activeTab).id
        try await herdr.app.wait { herdr.app.runtime.views[launcher]?.surface != nil }
        TerminalTestSupport.send("export HERDR_SESSION=alias; " + herdr.launch(socket: alias.appendingPathComponent("herdr.sock").path)
            .replacingOccurrences(of: "; herdr", with: "; " + HerdrLaunch.quote(bin.appendingPathComponent("herdr").path)), to: herdr.app.runtime.views[launcher]!)
        try await TestSupport.eventually(timeout: .seconds(15)) { !workspace.allTabIDs.contains(launcher) }
        _ = try herdr.api("workspace.rename", ["workspace_id": source, "label": "Renamed through alias"])
        try await TestSupport.eventually { herdr.spaces.contains { $0.name == "Renamed through alias" } }
        XCTAssertEqual(herdr.spaces.count, 2, "An executable or session alias must not duplicate the same server")
        XCTAssertEqual(workspace.allSurfaceIDs, ids)
    }

    func testCancelledHandoffDoesNotStealSelection() async throws {
        let herdr = try await HerdrSession(launch: false); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let source = try XCTUnwrap(workspace.activeTab).id
        try await herdr.app.wait { herdr.app.runtime.views[source]?.surface != nil }
        workspace.newLocalSpace()
        let selected = workspace.selectedSpace
        // The launch is typed, then its tab closes before the server's session reaches the app.
        TerminalTestSupport.send(herdr.launch(), to: herdr.app.runtime.views[source]!)
        workspace.closeTab(source, policy: .terminate)
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(workspace.selectedSpace, selected, "A late launch response must not focus a cancelled handoff")
    }

    func testCancelledClosePreservesNativeTerminals() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let space = try XCTUnwrap(herdr.spaces.first)
        let helper = try XCTUnwrap(herdr.app.workspace.helper(space))
        let terminal = try XCTUnwrap(space.tabs.first?.terminal)
        let before = try herdr.snapshot().panes.map(\.pane_id)
        let close = helper.close(terminal, policy: .terminate)
        close.cancel()
        await close.value
        XCTAssertEqual(try herdr.snapshot().panes.map(\.pane_id), before)
        XCTAssertNil(helper.error)
    }

    func testCancelledDetachedRestoreCanBeRetriedWithoutReimportingItsPlaceholder() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let original = try XCTUnwrap(herdr.spaces.first)
        let helper = try XCTUnwrap(workspace.helper(original))
        workspace.detachSpace(original.id)
        try await TestSupport.eventually {
            !workspace.spaces.contains { $0.id == original.id }
                && helper.detachedRoutes.contains { $0.presentation.contains { $0.id == original.id } }
                && helper.operations == 0
        }
        try herdr.pause()
        helper.restore([original.id])
        let placeholder = try XCTUnwrap(workspace.spaces.first { $0.tabs.contains(where: \.isConnecting) })
        XCTAssertTrue(helper.dismiss(placeholder.id))
        herdr.resume()
        try await TestSupport.eventually { helper.operations == 0 }
        XCTAssertFalse(workspace.spaces.contains { $0.id == original.id || $0.id == placeholder.id })
        XCTAssertFalse(helper.isRestoring(original.id))
        XCTAssertTrue(helper.detachedRoutes.contains { $0.presentation.contains { $0.id == original.id } })
        helper.restore([original.id])
        try await TestSupport.eventually {
            workspace.spaces.contains { $0.id == original.id && !$0.tabs.contains(where: \.isConnecting) }
                && !helper.isRestoring(original.id)
        }
        XCTAssertEqual(workspace.spaces.first { $0.id == original.id }?.tabs.map(\.id), original.tabs.map(\.id))
    }

    func testCancelledRestoreWhileDetachingDoesNotRemoveRetry() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let original = try XCTUnwrap(herdr.spaces.first)
        let helper = try XCTUnwrap(workspace.helper(original))
        try herdr.pause()
        workspace.detachSpace(original.id)
        XCTAssertTrue(helper.detachedRoutes.contains { $0.presentation.contains { $0.id == original.id } })
        await Task(priority: .high) { @MainActor in helper.restore([original.id]) }.value
        let first = try XCTUnwrap(workspace.spaces.first { $0.tabs.contains(where: \.isConnecting) })
        XCTAssertTrue(helper.dismiss(first.id))
        await Task(priority: .background) { @MainActor in helper.restore([original.id]) }.value
        let retry = try XCTUnwrap(workspace.spaces.first { $0.tabs.contains(where: \.isConnecting) })
        XCTAssertNotEqual(first.id, retry.id)
        herdr.resume()
        try await TestSupport.eventually {
            workspace.spaces.contains { $0.id == original.id && !$0.tabs.contains(where: \.isConnecting) }
                && !helper.isRestoring(original.id)
        }
        XCTAssertEqual(workspace.spaces.first { $0.id == original.id }?.tabs.map(\.id), original.tabs.map(\.id))
        XCTAssertFalse(workspace.spaces.contains { $0.id == first.id || $0.id == retry.id })
        XCTAssertNil(helper.error)
    }

    func testQueuedHerdrFocusPreservesLatestSpaceAndInnerPaneSelection() async throws {
        for ssh in [false, true] {
            let herdr = try await HerdrSession(ssh: ssh); defer { herdr.close() }
            let workspace = herdr.app.workspace
            let w1 = try XCTUnwrap(herdr.snapshot().workspaces.first)
            _ = try herdr.api("workspace.create", ["source_workspace_id": w1.workspace_id, "focus": false])
            let p1 = try XCTUnwrap(herdr.snapshot().panes.first { $0.tab_id == w1.active_tab_id }).pane_id
            _ = try herdr.api("pane.split", ["target_pane_id": p1, "direction": "right", "ratio": 0.5])
            try await TestSupport.eventually(diagnostic: "ssh=\(ssh), spaces=\(workspace.spaces.map { "\($0.key ?? "local") remote=\($0.remote != nil) terminals=\($0.tabs.count)" }), selected=\(String(describing: workspace.selectedSpace))") { herdr.spaces.count == 2 && herdr.spaces.first?.tabs.count == 2 }
            let first = herdr.spaces[0], second = herdr.spaces[1]
            let surface = try XCTUnwrap(first.tabs.last).id
            // Clicks while the server holds every reply: the latest selection wins.
            try herdr.pause()
            workspace.selectSpace(second.id)
            workspace.selectSpace(first.id)
            workspace.selectSurface(surface)
            let focusRequest = workspace.focusRequest
            herdr.resume()
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(workspace.selectedSpace, first.id, "Observer events for older clicks must not change the latest selection")
            XCTAssertEqual(workspace.activeSurfaceID, surface, "Older command responses must not unmount the selected inner pane")
            XCTAssertEqual(workspace.focusRequest, focusRequest)
            _ = try herdr.api("workspace.rename", ["workspace_id": w1.workspace_id, "label": "Latest focus applied"])
            try await TestSupport.eventually { herdr.spaces.first?.name == "Latest focus applied" }
            XCTAssertEqual(workspace.selectedSpace, first.id)
            XCTAssertEqual(workspace.activeSurfaceID, surface)
            // External focus resumes after the latest command completes.
            _ = try herdr.api("workspace.focus", ["workspace_id": try XCTUnwrap(second.key)])
            try await TestSupport.eventually { workspace.selectedSpace == second.id }
        }
    }

    func testFailedHerdrFocusDoesNotSuppressLaterExternalSelection() async throws {
        // A refused focus reply is the herdr multiplexer's (moved); the app half: after its own focus command,
        // a later external selection still applies.
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let w1 = try XCTUnwrap(herdr.snapshot().workspaces.first).workspace_id
        _ = try herdr.api("workspace.create", ["source_workspace_id": w1, "focus": false])
        try await TestSupport.eventually { herdr.spaces.count == 2 }
        let first = herdr.spaces[0].id
        workspace.selectSpace(herdr.spaces[1].id)
        try await TestSupport.eventually { (try? herdr.snapshot().focused_workspace_id) == herdr.spaces[1].key }
        _ = try herdr.api("workspace.focus", ["workspace_id": w1])
        try await TestSupport.eventually { workspace.selectedSpace == first }
    }

    func testDetachingLastHerdrTabReleasesEndpointTransport() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let w1 = try XCTUnwrap(herdr.snapshot().workspaces.first).workspace_id
        _ = try herdr.api("workspace.create", ["source_workspace_id": w1, "focus": false])
        try await TestSupport.eventually { herdr.spaces.count == 2 }
        // The old herdr tab is a window here; closing it from its tab bar detaches it (Detach).
        let windows = herdr.spaces.flatMap(\.windows)
        herdr.app.controller.detachWindow(windows[0].id)
        try await TestSupport.eventually { herdr.spaces.count == 1 }
        XCTAssertTrue(herdr.observed, "Other spaces still need the server's observer")
        herdr.app.controller.detachWindow(windows[1].id)
        try await TestSupport.eventually { herdr.spaces.isEmpty }
        try await TestSupport.eventually { !herdr.observed }
        XCTAssertEqual(try herdr.snapshot().workspaces.count, 2, "Detaching keeps the server's work")
    }

    func testReattachUsesServerSelectionEvenAfterBackgroundUpdates() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let w1 = try XCTUnwrap(herdr.snapshot().workspaces.first).workspace_id
        let tabs = Set(try herdr.snapshot().tabs.map(\.tab_id))
        _ = try herdr.api("tab.create", ["workspace_id": w1, "focus": false])
        let second = try XCTUnwrap(herdr.snapshot().tabs.first { !tabs.contains($0.tab_id) }).tab_id
        try await TestSupport.eventually { herdr.spaces.first?.windows.count == 2 }
        // The server's selection moves while the app shows nothing of it.
        herdr.detachAll()
        try await TestSupport.eventually { herdr.spaces.isEmpty }
        _ = try herdr.api("tab.focus", ["tab_id": second])
        workspace.newLocalSpace()
        let source = try XCTUnwrap(workspace.activeTab).id
        try await herdr.start(in: source)
        try await TestSupport.eventually { workspace.activeWindowKey == second }
    }

    func testOnlyHerdrPositionLabelsYieldToConversationTitles() {
        // Native Graph coverage verifies these flags for the upstream reordered w1:t3,t1,t2,t4 and w2:t1 matrix.
        let tabs = zip(["1", "Mine", "3", "2", "1"], [false, true, false, true, false]).map { name, renamed in
            ContainerTab(id: UUID(), node: 1, name: name, renamed: renamed,
                         arrangement: PaneArrangement(tab: TerminalTab(directory: "/tmp")))
        }
        XCTAssertEqual(tabs.map { $0.displayLabel(automatic: true, conversation: "Fix startup") }, ["Fix startup", "Mine", "Fix startup", "2", "Fix startup"])
        XCTAssertEqual(tabs.map { $0.displayLabel(automatic: true, conversation: nil) }, ["1", "Mine", "3", "2", "1"])
        XCTAssertEqual(tabs.map { $0.displayLabel(automatic: false, conversation: "Fix startup") }, ["1", "Mine", "3", "2", "1"])

        // Numbered tabs fall back to their focused pane: a program's own title, then the folder at a prompt.
        var pane = TerminalTab(directory: "/work/src/project")
        pane.title = "~/work/src/project"
        var numbered = ContainerTab(id: UUID(), node: 1, name: "2", renamed: false, numbered: true, arrangement: PaneArrangement(tab: pane))
        XCTAssertEqual(numbered.displayLabel(automatic: true, conversation: nil), "project")
        XCTAssertEqual(numbered.displayLabel(automatic: true, conversation: "Fix startup"), "Fix startup")
        XCTAssertEqual(numbered.displayLabel(automatic: false, conversation: nil), "2")
        pane.title = "vim notes.md"
        XCTAssertEqual(numbered.displayLabel(automatic: true, conversation: nil, focused: pane), "vim notes.md")
        var blank = TerminalTab(directory: "")
        blank.title = ""
        XCTAssertEqual(numbered.displayLabel(automatic: true, conversation: nil, focused: blank), "2")
        numbered.renamed = true
        XCTAssertEqual(numbered.displayLabel(automatic: true, conversation: nil), "2")
    }

    func testHandoffClosesOnlyLaunchingTabAndRemovesEmptySpace() async throws {
        for count in [1, 2, 3] {
            let herdr = try await HerdrSession(launch: false); defer { herdr.close() }
            let workspace = herdr.app.workspace
            let original = try XCTUnwrap(workspace.selectedSpace)
            for _ in 1..<count {
                workspace.newTab()
                try await herdr.app.wait { workspace.activeTab?.isConnecting == false }
            }
            let source = try XCTUnwrap(workspace.activeTab).id
            var closed: [UUID] = []
            let close = workspace.onCloseTabs
            workspace.onCloseTabs = { closed += $0; close($0) }
            try await herdr.start(in: source)
            _ = try herdr.api("workspace.create", ["source_workspace_id": try XCTUnwrap(herdr.snapshot().workspaces.first).workspace_id, "focus": false])
            try await TestSupport.eventually { herdr.spaces.count == 2 }
            try await TestSupport.eventually { !workspace.allTabIDs.contains(source) }
            XCTAssertEqual(workspace.spaces.first { $0.id == original }?.tabs.count, count == 1 ? nil : count - 1)
            XCTAssertEqual(workspace.current?.shows("herdr"), true)
            XCTAssertEqual(herdr.spaces.count, 2)
            XCTAssertTrue(closed.contains(source))
        }
    }

    /// The launcher stays shown beside herdr's space until herdr releases it: the sidebar that one space hides
    /// must not show for that round trip.
    func testHandoffKeepsTheSingleSpaceSidebarHidden() async throws {
        let herdr = try await HerdrSession(launch: false); defer { herdr.close() }
        XCTAssertFalse(herdr.app.controller.sidebarVisible)
        let shown = herdr.app.sidebarShown()
        try await herdr.start(in: try XCTUnwrap(herdr.app.workspace.activeTab).id)
        XCTAssertEqual(herdr.app.workspace.spaces.count, 1)
        XCTAssertTrue(herdr.app.workspace.retiringLaunchers.isEmpty)
        XCTAssertFalse(shown.withLock { $0 }, "The sidebar must stay hidden while the launcher hands off to herdr")
    }

    func testSnapshotIdentitySelectionNamespaceAndDetach() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let w1 = try XCTUnwrap(herdr.snapshot().workspaces.first).workspace_id
        let w2 = try XCTUnwrap((try herdr.api("workspace.create", ["source_workspace_id": w1, "focus": false])["workspace"] as? [String: Any])?["workspace_id"] as? String)
        try await TestSupport.eventually { herdr.spaces.count == 2 }
        let first = herdr.spaces[0], tab = first.tabs[0]
        _ = try herdr.api("workspace.rename", ["workspace_id": w1, "label": "Renamed"])
        _ = try herdr.api("workspace.focus", ["workspace_id": w2])
        try await TestSupport.eventually { herdr.spaces[0].name == "Renamed" && workspace.current?.key == w2 }
        XCTAssertEqual(herdr.spaces[0].id, first.id)
        XCTAssertEqual(herdr.spaces[0].tabs[0].id, tab.id)
        XCTAssertEqual(herdr.spaces[0].tabs[0].terminal, tab.terminal)
        workspace.selectSpace(first.id)
        try await TestSupport.eventually { (try? herdr.snapshot().focused_workspace_id) == w1 }
        _ = try herdr.api("workspace.focus", ["workspace_id": w2])
        try await TestSupport.eventually { workspace.current?.key == w2 }
        workspace.newLocalSpace()
        let local = workspace.selectedSpace
        _ = try herdr.api("workspace.focus", ["workspace_id": w1])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(workspace.selectedSpace, local, "Remote focus does not steal a local view")
        // The same server reached over SSH is another helper's namespace: its views are its own.
        let remote = try await herdr.attachOverSSH()
        XCTAssertNotEqual(remote.tabs[0].id, tab.id)
        workspace.detachSpace(first.id)
        _ = try herdr.api("workspace.rename", ["workspace_id": w1, "label": "After detach"])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(workspace.spaces.contains { $0.id == first.id }, "Detached views do not reopen on every server change")
        XCTAssertTrue(workspace.spaces.contains { $0.id == remote.id })
    }

    func testMixedSpaceOrderSurvivesSnapshotsAndRemoteFocus() async throws {
        let herdr = try await HerdrSession(autoClose: false); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let w1 = try XCTUnwrap(herdr.snapshot().workspaces.first).workspace_id
        let w2 = try XCTUnwrap((try herdr.api("workspace.create", ["source_workspace_id": w1, "focus": false])["workspace"] as? [String: Any])?["workspace_id"] as? String)
        try await TestSupport.eventually { herdr.spaces.count == 2 }
        let first = herdr.spaces[0].id, second = herdr.spaces[1].id
        workspace.newLocalSpace()
        let local = try XCTUnwrap(workspace.selectedSpace)
        // A tmux session's space between them.
        try await herdr.app.attach(command: "\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(herdr.app.socket) -CC attach -t edge")
        let mux = try XCTUnwrap(workspace.current).id
        XCTAssertTrue(workspace.reorderSpace(local, relativeTo: first, after: true))
        XCTAssertTrue(workspace.reorderSpace(mux, relativeTo: second, after: false))
        let order = [first, local, mux, second]
        XCTAssertEqual(workspace.spaces.map(\.id).filter(order.contains), order)
        for (focus, label) in [(w2, "w2"), (w1, "w1"), (w2, "w2 again")] {
            _ = try herdr.api("workspace.rename", ["workspace_id": focus, "label": label])
            _ = try herdr.api("workspace.focus", ["workspace_id": focus])
            try await TestSupport.eventually { workspace.spaces.contains { $0.name == label } }
            XCTAssertEqual(workspace.spaces.map(\.id).filter(order.contains), order)
        }
        workspace.selectSpace(local)
        XCTAssertEqual(workspace.currentMachine, .local)
    }

    func testRetainedHerdrLauncherReturnsToShellAndButtonsCreatePlainSpace() async throws {
        let herdr = try await HerdrSession(autoClose: false, launch: false); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let source = try XCTUnwrap(workspace.activeTab).id
        try await herdr.start(in: source)
        XCTAssertTrue(workspace.allTabIDs.contains(source))
        // The kept launcher is back at its shell.
        let launcher = try XCTUnwrap(herdr.app.runtime.views[source])
        TerminalTestSupport.send("printf 'LAUNCHER_%s\\n' SHELL", to: launcher)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: launcher).contains("LAUNCHER_SHELL") }
        XCTAssertEqual(workspace.current?.shows("herdr"), true)
        workspace.newNativeSpace()
        XCTAssertNotEqual(workspace.current?.shows("herdr"), true)
        XCTAssertNotEqual(workspace.current?.shows("tmux"), true)
        XCTAssertNil(workspace.activeTab?.launchCommand)
        workspace.machineForTab = { _ in .ssh(.init(destination: "my-host", options: ["-p", "2222"])) }
        workspace.newNativeSpace()
        XCTAssertEqual(workspace.activeTab?.machine, .ssh(.init(destination: "my-host", options: ["-p", "2222"])))
        XCTAssertTrue(workspace.activeTab?.launchCommand?.contains("'my-host'") == true)
    }

    func testOptimisticRenameSurvivesOldRepliesAndRollsBackAfterRead() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let id = try XCTUnwrap(herdr.spaces.first).id, key = try XCTUnwrap(herdr.spaces.first?.key)
        try herdr.pause()
        workspace.renameSpace(id, to: "One")
        workspace.renameSpace(id, to: "Two")
        XCTAssertEqual(workspace.spaces.first { $0.id == id }?.name, "Two", "A rename shows at once")
        herdr.resume()
        try await TestSupport.eventually { (try? herdr.snapshot().workspaces.first { $0.workspace_id == key }?.label) == "Two" }
        XCTAssertEqual(workspace.spaces.first { $0.id == id }?.name, "Two")
        // A refused rename returns to the server's name (herdr refuses an invalid label).
        workspace.renameSpace(id, to: String(repeating: "x", count: 4096))
        try await TestSupport.eventually { herdr.app.runtime.helpers[.local]?.error != nil }
        try await TestSupport.eventually { workspace.spaces.first { $0.id == id }?.name == "Two" }
        XCTAssertEqual(workspace.spaces.first { $0.id == id }?.id, id)
    }

    func testOptimisticCloseRetainsTerminalAndRestoresIdentityOnFailure() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let w1 = try XCTUnwrap(herdr.snapshot().workspaces.first).workspace_id
        _ = try herdr.api("workspace.create", ["source_workspace_id": w1, "focus": false])
        try await TestSupport.eventually { herdr.spaces.count == 2 }
        let original = herdr.spaces[0]
        var closed: [UUID] = []
        let close = workspace.onCloseTabs
        workspace.onCloseTabs = { closed += $0; close($0) }
        try herdr.pause()
        workspace.closeSpace(original.id, policy: .terminate)
        XCTAssertFalse(workspace.spaces.contains { $0.id == original.id }, "A close shows at once")
        XCTAssertTrue(closed.isEmpty)
        // The server never got it: it is gone before it could answer.
        try herdr.crash()
        try await TestSupport.eventually { herdr.app.runtime.helpers[.local]?.error != nil || workspace.spaces.contains { $0.id == original.id } }
        let restored = try XCTUnwrap(workspace.spaces.first { $0.id == original.id })
        XCTAssertEqual(restored.tabs.map(\.id), original.tabs.map(\.id))
        XCTAssertTrue(closed.isEmpty)
    }

    func testDisconnectDuringCreationRetainsOnlyConfirmedTerminals() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let originals = workspace.allSurfaceIDs
        try herdr.pause()
        let before = try herdr.newSpace()
        XCTAssertNotNil(herdr.pending(before), "A new space shows at once as connecting: \(herdr.shown)")
        try herdr.crash()
        try await TestSupport.eventually { !workspace.spaces.contains { $0.activeTab?.isConnecting == true } }
        XCTAssertTrue(workspace.allSurfaceIDs.isSubset(of: originals), "Only confirmed server terminals stay, never pending ones")
        XCTAssertNotNil(herdr.app.runtime.helpers[.local]?.error)
    }

    func testSelectingPendingTabIsSentAfterItsServerIdentityArrives() async throws {
        try await pendingSelection(selectAnotherTab: false)
    }

    func testNewerSelectionSupersedesPendingTabFocus() async throws {
        try await pendingSelection(selectAnotherTab: true)
    }

    private func pendingSelection(selectAnotherTab: Bool) async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let original = try XCTUnwrap(herdr.spaces.first?.activeTab).id
        try herdr.pause()
        let before = try herdr.newSpace()
        let placeholder = try XCTUnwrap(herdr.pending(before), "A new space shows at once as connecting: \(herdr.shown)")
        let selected = try XCTUnwrap(placeholder.activeTab).id
        workspace.selectTab(selected)
        if selectAnotherTab { workspace.selectTab(original) }
        herdr.resume()
        try await TestSupport.eventually { herdr.spaces.count == 2 && !workspace.spaces.contains { $0.activeTab?.isConnecting == true } }
        let expected = selectAnotherTab ? original : selected
        try await TestSupport.eventually { workspace.activeTab?.id == expected }
        let tab = try XCTUnwrap(workspace.spaces.flatMap(\.tabs).first { $0.id == expected })
        let key = try XCTUnwrap(workspace.windowKey(of: tab))
        try await TestSupport.eventually { (try? herdr.snapshot().focused_tab_id) == key }
    }

    func testNewTabStartsInFocusedPaneDirectory() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        // herdr reports the real path (/private/tmp), which Foundation's symlink resolution would undo.
        let directory = "/private" + herdr.root.appendingPathComponent("project").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let view = try XCTUnwrap(workspace.activeTab.flatMap { herdr.app.runtime.views[$0.id] })
        TerminalTestSupport.send("cd " + HerdrLaunch.quote(directory), to: view)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: view)) {
            let snapshot = try herdr.snapshot()
            return snapshot.panes.first { $0.pane_id == snapshot.focused_pane_id }?.cwd == directory
        }
        let known = Set(try herdr.snapshot().panes.map(\.pane_id))
        workspace.newTab()
        try await TestSupport.eventually(timeout: .seconds(10)) { try herdr.snapshot().panes.count == known.count + 1 }
        let created = try XCTUnwrap(try herdr.snapshot().panes.first { !known.contains($0.pane_id) })
        XCTAssertEqual(created.cwd, directory, "A new tab starts where the focused pane is, as in herdr's own UI")
    }

    func testOptimisticCreationReusesPlaceholderAndMoveRetainsTerminal() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let initial = try XCTUnwrap(herdr.spaces.first), terminal = try XCTUnwrap(initial.tabs.first).id
        try herdr.pause()
        let before = try herdr.newSpace()
        let placeholder = try XCTUnwrap(herdr.pending(before), "A new space shows at once as connecting: \(herdr.shown)")
        XCTAssertEqual(workspace.current?.id, placeholder.id)
        let confirmationRevision = workspace.layoutRevision
        herdr.resume()
        try await TestSupport.eventually { workspace.current?.activeTab?.isConnecting == false }
        XCTAssertEqual(workspace.layoutRevision, confirmationRevision + 1,
                       "Pending identities and their confirmed projection must publish together")
        XCTAssertEqual(workspace.current?.id, placeholder.id)
        XCTAssertEqual(workspace.current?.activeTab?.id, placeholder.activeTab?.id)
        var closed: [UUID] = []
        let close = workspace.onCloseTabs
        workspace.onCloseTabs = { closed += $0; close($0) }
        // Moving the first window into a new space shows it there at once and never closes its terminal,
        // whatever the server answers (the old move was refused and rolled back from a fresh read).
        let window = try XCTUnwrap(workspace.spaces.first { $0.id == initial.id }?.windows.first).id
        workspace.moveWindowToNewSpace(window)
        XCTAssertNotEqual(workspace.current?.id, initial.id, "The moved window shows in a new space at once: \(herdr.shown)")
        XCTAssertEqual(workspace.current?.activeTab?.surfaceIDs, [terminal])
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(workspace.spaces.flatMap(\.tabs).filter { $0.id == terminal }.count, 1)
        XCTAssertFalse(closed.contains(terminal))
    }

    func testUncertainMutationIgnoresObserverReadStartedBeforeFailure() async throws {
        // Which observer read may follow a lost reply is the herdr multiplexer's (moved). App half: a mutation
        // whose reply is lost shows the server's state afterwards and is never sent twice.
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let space = try XCTUnwrap(herdr.spaces.first)
        try herdr.pause()
        workspace.renameSpace(space.id, to: "Pending")
        try herdr.crash()
        try await TestSupport.eventually { herdr.app.runtime.helpers[.local]?.error != nil }
        XCTAssertNotEqual(workspace.spaces.first { $0.id == space.id }?.name, "Server result")
        XCTAssertNil(try? HerdrSocket(path: herdr.socket), "Recovery must never restart the server or replay the mutation")
    }

    func testQueuedLayoutPreservesOptimisticCreationIdentityAcrossConfirmation() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let originalSurfaces = Set(workspace.allSurfaceIDs)
        var closed: [UUID] = []
        let close = workspace.onCloseTabs
        workspace.onCloseTabs = { closed += $0; close($0) }
        try herdr.pause()
        let before = try herdr.newSpace()
        let placeholder = try XCTUnwrap(herdr.pending(before), "A new space shows at once as connecting: \(herdr.shown)")
        let placeholderTab = try XCTUnwrap(placeholder.tabs.first(where: \.isConnecting))
        XCTAssertTrue(placeholderTab.isConnecting)
        // A layout change queued behind the creation.
        let first = try XCTUnwrap(herdr.spaces.first { $0.id != placeholder.id })
        workspace.selectSpace(first.id)
        _ = workspace.applyLayout(.columns)
        workspace.selectSpace(placeholder.id)
        herdr.resume()
        try await TestSupport.eventually { workspace.current?.activeTab?.isConnecting == false }
        XCTAssertEqual(workspace.current?.id, placeholder.id)
        XCTAssertEqual(workspace.current?.activeTab?.id, placeholderTab.id)
        XCTAssertEqual(workspace.spaces.flatMap(\.tabs).filter { $0.id == placeholderTab.id }.count, 1)
        XCTAssertTrue(originalSurfaces.isSubset(of: Set(workspace.allSurfaceIDs)))
        XCTAssertTrue(originalSurfaces.isDisjoint(with: closed))
        XCTAssertEqual(try herdr.snapshot().workspaces.count, 2, "Neither creation nor layout is replayed")
        let settledRevision = workspace.layoutRevision
        _ = try herdr.api("workspace.rename", ["workspace_id": try XCTUnwrap(first.key), "label": first.name])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(workspace.layoutRevision, settledRevision, "An unchanged server state must not publish again")
    }

    func testDeferredReattachCannotRestartStoppedCoordinator() async throws {
        let herdr = try await HerdrSession(launch: false); defer { herdr.close() }
        let source = try XCTUnwrap(herdr.app.workspace.activeTab).id
        try await herdr.start(in: source)
        let launcher = try XCTUnwrap(herdr.app.workspace.spaces.flatMap(\.tabs).first?.id)
        workspace(herdr).newLocalSpace()
        let second = try XCTUnwrap(herdr.app.workspace.activeTab).id
        try await herdr.app.wait { herdr.app.runtime.views[second]?.surface != nil }
        let view = try XCTUnwrap(herdr.app.runtime.views[second])
        // A second launch waits on a held server while the app stops.
        try herdr.pause()
        TerminalTestSupport.send(herdr.launch(), to: view)
        try await Task.sleep(for: .milliseconds(500))
        await herdr.app.close().value
        herdr.resume()
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(herdr.app.runtime.helpers.isEmpty, "A stopped app does not reconnect to the server")
        _ = launcher
    }

    func testLaunchClassification() async throws {
        // The typed command decides: a session of this server opens as a space, anything else runs in the terminal.
        let cases: [(String, Bool)] = [
            ("", true), ("--session agents", true), ("--session=agents", true), ("client --session agents", true),
            ("session attach agents", true), ("workspace create", false), ("--version", false), ("--remote host", false),
            ("session attach help", false), ("client --help", true), ("client --unexpected", true)
        ]
        let herdr = try await HerdrSession(autoClose: false, launch: false); defer { herdr.close() }
        let workspace = herdr.app.workspace
        for (arguments, opens) in cases {
            workspace.newLocalSpace()
            let source = try XCTUnwrap(workspace.activeTab).id
            try await herdr.app.wait { herdr.app.runtime.views[source]?.surface != nil }
            let view = try XCTUnwrap(herdr.app.runtime.views[source])
            let before = Set(herdr.spaces.map(\.id))
            TerminalTestSupport.send(herdr.launch() + " " + arguments + "; printf 'LAUNCH_%s\\n' DONE", to: view)
            if opens {
                try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "herdr \(arguments): " + TerminalTestSupport.screen(terminal: view)) {
                    !Set(herdr.spaces.map(\.id)).subtracting(before).isEmpty || herdr.spaces.contains { !before.contains($0.id) || workspace.selectedSpace == $0.id }
                }
            } else {
                try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "herdr \(arguments): " + TerminalTestSupport.screen(terminal: view)) {
                    TerminalTestSupport.screen(terminal: view).contains("LAUNCH_DONE")
                }
                // A command for the server (workspace create) may change what it shows; the launch itself stays here.
                XCTAssertTrue(workspace.allTabIDs.contains(source), "herdr \(arguments) runs in the terminal")
            }
        }
    }

    func testRemoteStreamResetRenegotiatesTheCurrentViewport() async throws {
        // After another client takes the terminal over at its own size and releases it, the app's view gets
        // the terminal back at the app's viewport.
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let tab = try XCTUnwrap(herdr.spaces.first?.tabs.first)
        try await herdr.app.wait { herdr.app.runtime.views[tab.id]?.surface != nil }
        let view = try XCTUnwrap(herdr.app.runtime.views[tab.id]), grid = try XCTUnwrap(view.surface).grid
        let competitor = try herdr.takeover(try XCTUnwrap(herdr.app.workspace.key(of: tab)), columns: grid.columns + 7, rows: grid.rows + 3)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: view).contains("disconnected") }
        competitor.release()
        TerminalTestSupport.send("clear; stty size", to: view)
        try await TestSupport.eventually(diagnostic: "Herdr reattach expected=\(grid.rows)x\(grid.columns) current=\(String(describing: view.surface?.grid)) helper=\(herdr.app.runtime.helpers[.local]?.error ?? "none")\n\(TerminalTestSupport.screen(terminal: view))") { TerminalTestSupport.screen(terminal: view).contains("\(grid.rows) \(grid.columns)") }
    }

    func testNormalTerminalExitDoesNotDisableTakeoverAndRestartRecovery() async throws {
        // A pane whose program exits closes; the other panes keep their terminals, and taking one over and
        // releasing it still reconnects (a takeover is not an exit).
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let p1 = try XCTUnwrap(herdr.snapshot().panes.first).pane_id
        _ = try herdr.api("pane.split", ["target_pane_id": p1, "direction": "right", "ratio": 0.5])
        try await TestSupport.eventually { herdr.spaces.first?.tabs.count == 2 }
        let exiting = try XCTUnwrap(herdr.spaces.first?.tabs.first), staying = try XCTUnwrap(herdr.spaces.first?.tabs.last)
        try await herdr.app.wait { herdr.app.runtime.views[exiting.id]?.surface != nil && herdr.app.runtime.views[staying.id]?.surface != nil }
        TerminalTestSupport.send("exit", to: herdr.app.runtime.views[exiting.id]!)
        try await TestSupport.eventually { !workspace.allTabIDs.contains(exiting.id) }
        let view = try XCTUnwrap(herdr.app.runtime.views[staying.id])
        let competitor = try herdr.takeover(try XCTUnwrap(workspace.key(of: staying)), columns: 80, rows: 24)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: view).contains("disconnected") }
        competitor.release()
        // Input during recovery is deliberately rejected; wait for the replacement full frame.
        try await TestSupport.eventually {
            let screen = TerminalTestSupport.screen(terminal: view)
            return !screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !screen.contains("disconnected")
        }
        TerminalTestSupport.send("printf 'AFTER_%s\\n' TAKEOVER", to: view)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: view).contains("AFTER_TAKEOVER") }
        XCTAssertTrue(workspace.allTabIDs.contains(staying.id))
    }

    private func workspace(_ herdr: HerdrSession) -> Workspace { herdr.app.workspace }
}

/// A real herdr server shown in the app through the helper's herdr multiplexer, started in a terminal's shell
/// (inside an SSH login to this machine's test sshd for the remote route).
@MainActor
final class HerdrSession {
    let app: TmuxWalkthrough
    /// herdr's Unix socket must fit sockaddr_un even on macOS's long TMPDIR.
    let root = URL(fileURLWithPath: "/tmp/hd-" + UUID().uuidString.prefix(8))
    var socket: String { root.appendingPathComponent("herdr.sock").path }
    private var server: SSHTestServer?
    private var paused: pid_t?
    private let ssh: Bool

    init(autoClose: Bool = true, ssh: Bool = false, launch: Bool = true) async throws {
        app = try TmuxWalkthrough(autoClose: autoClose)
        self.ssh = ssh
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if launch { try await start(in: XCTUnwrap(app.workspace.activeTab).id) }
        } catch {
            close()
            await app.close().value
            throw error
        }
    }

    func launch(socket: String? = nil) -> String {
        "export PATH=\(TestSupport.path):/usr/bin:/bin:$PATH; export SHELL=/bin/sh; export XDG_CONFIG_HOME=\(HerdrLaunch.quote(root.path)); "
            + "export XDG_STATE_HOME=\(HerdrLaunch.quote(root.path)); export HERDR_SOCKET_PATH=\(HerdrLaunch.quote(socket ?? self.socket)); herdr"
    }

    /// Starts herdr in a tab's shell (after an SSH login on the remote route) and waits for its space.
    func start(in tab: UUID) async throws {
        // The helper claims herdr clients once it knows its multiplexers and backends.
        try await TestSupport.eventually(timeout: .seconds(10)) {
            self.app.runtime.helpers[.local].map { $0.multiplexers.contains { $0.name == "herdr" } && !$0.backends.isEmpty } == true
        }
        try await app.wait { self.app.runtime.views[tab].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let view = try XCTUnwrap(app.runtime.views[tab])
        if ssh { try await login(view, tab: tab) }
        TerminalTestSupport.send(launch(), to: view)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: view)) {
            self.app.workspace.current?.shows("herdr") == true
        }
        // The handoff closes the launching tab when the app is set to (the walkthrough's autoClose); an SSH
        // login tab stays (it carries the link).
        if !ssh, app.workspace.closeLaunching["herdr"] == true {
            try await TestSupport.eventually { !self.app.workspace.allTabIDs.contains(tab) }
        }
    }

    private func login(_ view: TerminalView, tab: UUID) async throws {
        var server: SSHTestServer! = self.server
        if server == nil { server = try await SSHTestServer() }
        self.server = server
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: view)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            self.app.runtime.ssh.links.values.contains { $0.launch.tabID == tab && $0.shellPID != nil }
        }
    }

    /// The same server shown again through an SSH login's helper; returns its first space.
    func attachOverSSH() async throws -> Space {
        let known = Set(app.workspace.spaces.map(\.id))
        app.workspace.newLocalSpace()
        let tab = try XCTUnwrap(app.workspace.activeTab).id
        try await app.wait { self.app.runtime.views[tab]?.surface != nil }
        let view = try XCTUnwrap(app.runtime.views[tab])
        try await login(view, tab: tab)
        TerminalTestSupport.send(launch(), to: view)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            self.app.workspace.spaces.contains { !known.contains($0.id) && $0.remote != nil && $0.shows("herdr") }
        }
        return try XCTUnwrap(app.workspace.spaces.first { !known.contains($0.id) && $0.remote != nil && $0.shows("herdr") })
    }

    /// The spaces showing this server's workspaces (this Mac's helper).
    var spaces: [Space] { app.workspace.spaces.filter { ($0.remote != nil) == ssh && $0.shows("herdr") } }

    /// A new space of this server, as the New Space command in one of its spaces creates it; returns the
    /// spaces shown before.
    @discardableResult
    func newSpace() throws -> Set<UUID> {
        let before = Set(app.workspace.spaces.map(\.id))
        let first = try XCTUnwrap(spaces.first).id
        // Selecting sends a focus command; only when needed, so the server's reply is not part of the creation.
        if app.workspace.selectedSpace != first { app.workspace.selectSpace(first) }
        app.workspace.newBackendSpace()
        return before
    }

    /// The new space shown while its creation is pending (old app: a connecting space at once).
    func pending(_ before: Set<UUID>) -> Space? {
        app.workspace.spaces.first { !before.contains($0.id) && $0.tabs.contains(where: \.isConnecting) }
    }

    /// What the workspace shows, for failure messages.
    var shown: String {
        app.workspace.spaces.map { space in
            "\(space.name)[\(space.id.uuidString.prefix(4)) windows=\(space.containers.count) tabs=\(space.tabs.count) connecting=\(space.tabs.filter(\.isConnecting).count)]"
        }.joined(separator: " ") + " selected=\(app.workspace.selectedSpace?.uuidString.prefix(4) ?? "none")"
    }

    /// The helper still observes this server (a space of it is shown).
    var observed: Bool { !spaces.isEmpty }

    /// Detaches every space of this server; its work keeps running.
    func detachAll() { for space in spaces { app.workspace.detachSpace(space.id) } }

    @discardableResult
    func api(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let result = try HerdrSocket(path: socket).request(method, params: JSONSerialization.data(withJSONObject: params))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
    }

    func snapshot() throws -> HerdrSnapshot { try HerdrTestSupport.snapshot(socket) }

    /// The server process, from its socket's peer credentials.
    private func pid() throws -> pid_t {
        let connection = try HerdrSocket(path: socket)
        var pid: pid_t = 0, size = socklen_t(MemoryLayout<pid_t>.size)
        XCTAssertEqual(getsockopt(connection.fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size), 0)
        return pid
    }

    /// Holds every reply: the server is stopped (SIGSTOP) until `resume()`.
    func pause() throws {
        let pid = try pid()
        paused = pid
        XCTAssertEqual(kill(pid, SIGSTOP), 0)
    }

    func resume() {
        if let paused { kill(paused, SIGCONT) }
        paused = nil
    }

    /// The held server dies: nothing it was asked answers.
    func crash() throws {
        let pid = try XCTUnwrap(paused)
        XCTAssertEqual(kill(pid, SIGKILL), 0)
        kill(pid, SIGCONT)
        paused = nil
    }

    /// Another writable client takes a terminal over at its own size until released.
    final class Takeover {
        let process = Process(), input = Pipe()
        func release() {
            try? input.fileHandleForWriting.write(contentsOf: Data("{\"type\":\"terminal.release\"}\n".utf8))
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        }
    }

    func takeover(_ terminal: String, columns: Int, rows: Int) throws -> Takeover {
        let takeover = Takeover()
        takeover.process.executableURL = URL(fileURLWithPath: TestSupport.tool("herdr"))
        takeover.process.arguments = ["terminal", "session", "control", terminal, "--takeover", "--cols", String(columns), "--rows", String(rows)]
        takeover.process.environment = ProcessInfo.processInfo.environment.merging(["HERDR_SOCKET_PATH": socket]) { _, new in new }
        takeover.process.standardInput = takeover.input
        takeover.process.standardOutput = FileHandle.nullDevice; takeover.process.standardError = FileHandle.nullDevice
        try takeover.process.run()
        return takeover
    }

    func close() {
        resume()
        _ = try? HerdrSocket(path: socket).request("server.stop")
        server?.stop()
        app.close()
        try? FileManager.default.removeItem(at: root)
    }
}
