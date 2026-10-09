import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class SSHShellIntegrationTests: XCTestCase {
    func testHostBorderWithoutSSH() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let controller = AppDelegate(), runtime = TerminalRuntime.shared
        let workspace = controller.workspace
        let previousWorkspace = runtime.workspace
        runtime.workspace = workspace
        controller.settings.values = Preferences()
        controller.settings.values.hideSingleSpace = false
        workspace.newLocalSpace()
        let tab = try XCTUnwrap(workspace.activeTab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil; runtime.close(Array(workspace.allSurfaceIDs)); runtime.workspace = previousWorkspace }
        let x: CGFloat = 940
        let originalGlass = LiquidGlassStore.shared.enabled
        defer { LiquidGlassStore.shared.enabled = originalGlass }
        for glass in [false] + (LiquidGlassStore.supported ? [true] : []) {
            LiquidGlassStore.shared.enabled = glass
            let local = try await capture(window, "border-local-\(glass)")
            let generation = UUID()
            workspace.hosts.begin(tab.id, generation: generation, destination: "fixture")
            workspace.hosts.update(tab.id, generation: generation, destination: "fixture",
                greeting: SSHGreeting(version: 1, host: "border-fixture", boot: "test", uid: 501, home: "/tmp", capabilities: []), state: .connected)
            // Upstream chrome has two exclusive cues: a classic edge or a glass wash.
            try await Task.sleep(for: .milliseconds(1100))
            let remote = try await capture(window, "border-remote-\(glass)")
            // The tab strip is the title row: the edge runs along the window top.
            for column: CGFloat in [500, 700, 940] {
                let border = try (0...2).map { try distance(local, remote, x: column, y: CGFloat($0)) }.max() ?? 0
                if glass { XCTAssertLessThan(border, 0.015, "Glass tints without a solid top edge") }
                else { XCTAssertGreaterThan(border, 0.2, "The connected host has a solid top edge") }
            }
            let root = try XCTUnwrap(window.contentView)
            let row = try XCTUnwrap(PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
                .first { $0.configuration.item == .tab(tab.id) && !$0.isHiddenOrHasHiddenAncestor })
            let frame = row.convert(row.bounds, to: root)
            let barHeight = StripTab.barHeight(titlebar: nil, style: .current(controller.windowState),
                typography: AppTypography(contentSize: controller.settings.values.fontSize))
            let below = (root.isFlipped ? frame.midY : root.bounds.height - frame.midY) + barHeight / 2 + 4
            if glass {
                XCTAssertGreaterThan(try distance(local, remote, x: x, y: below), 0.02,
                                     "The host tint remains visible below the strip")
            } else {
                XCTAssertLessThan(try distance(local, remote, x: x, y: 4), 0.015,
                                  "Classic chrome keeps the strip untinted")
            }
            for y: CGFloat in [200, 400] {
                XCTAssertLessThan(try distance(local, remote, x: x, y: y), 0.015,
                                  "Content beyond the 80-point wash stays neutral")
            }
            workspace.hosts.remove(tab.id)
            try await Task.sleep(for: .milliseconds(1100))
            let exited = try await capture(window, "border-exited-\(glass)")
            for y: CGFloat in [1, 20, 60, 95, 200] {
                XCTAssertLessThan(try distance(local, exited, x: x, y: y), 0.015,
                                  "Returning local removes the host edge, strip tint, and wash")
            }
        }
    }

    func testHostTintFollowsSSHAcrossMixedPanesAndReconnect() async throws {
        let app = try TmuxWalkthrough(liquidGlass: false); defer { app.close() }
        // Flat chrome: remote tabs show only the border. Window captures cannot render Liquid Glass, so its tint
        // is covered by SettingsSynchronizationTests.testHostHighlightModesDrawBorderOrTintNotBoth.
        app.controller.settings.values.hideSingleSpace = false
        let server = try await SSHTestServer(); defer { server.stop() }
        let tab = try XCTUnwrap(app.workspace.activeTab)
        try await app.wait { app.runtime.views[tab.id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        var terminal = try XCTUnwrap(app.runtime.views[tab.id])
        let local = try await capture(app.window, "tint-local")
        XCTAssertNil(app.runtime.ssh.tint(for: tab))
        let command = "ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ")
        TerminalTestSupport.send(command, to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == tab.id && $0.shellPID != nil }
        }
        let connection = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == tab.id })
        // Keep the echoed SSH command out of the background pixel samples.
        TerminalTestSupport.key(37, "l", terminal, modifiers: .control)
        let tint = try XCTUnwrap(app.runtime.ssh.tint(for: tab))
        // A tab on this host without a live transport (e.g. a multiplexer surface) keeps the host's tint;
        // the host is the verified machine (accounts are grouped), another machine has its own color.
        let host = try XCTUnwrap(app.workspace.hosts.terminals[tab.id]).host
        let native = TerminalTab(directory: "/tmp"), elsewhere = TerminalTab(directory: "/tmp")
        app.workspace.hosts.seed(native.id, from: host, generation: UUID())
        XCTAssertEqual(app.runtime.ssh.tint(for: native), tint, "A tab on the host retains its tint without a live transport")
        app.workspace.hosts.seed(elsewhere.id, from: .authenticated("another-machine"), generation: UUID())
        XCTAssertNotEqual(app.runtime.ssh.tint(for: elsewhere), tint, "Tabs on different hosts retain distinct colors")
        try await Task.sleep(for: .milliseconds(1100))
        let remote = try await capture(app.window, "tint-remote")
        // Sample empty pixels near the right of the pane, away from text and controls.
        let x = app.window.contentView!.bounds.width - 180
        // Flat chrome: the host edge at the window top, and nothing else. Strip samples sit above the 26-point tab,
        // which spans the strip with a centred title when it is alone.
        XCTAssertGreaterThan(try distance(local, remote, x: x, y: 1), 0.04, "The SSH callback must repaint the border without selecting another tab")
        XCTAssertLessThan(try distance(local, remote, x: x, y: 4), 0.015, "Without Liquid Glass the tab strip stays untinted")
        XCTAssertLessThan(try distance(local, remote, x: x, y: 100), 0.015, "Without Liquid Glass no fade covers the terminal")
        XCTAssertLessThan(try distance(local, remote, x: x, y: 400), 0.015, "The terminal stays neutral below the border")
        let root = try XCTUnwrap(app.window.contentView)
        let point = root.convert(NSPoint(x: terminal.bounds.midX, y: terminal.isFlipped ? 10 : terminal.bounds.height - 10), from: terminal)
        let hit = try XCTUnwrap(root.hitTest(point))
        XCTAssertTrue(hit === terminal || hit.isDescendant(of: terminal), "The decorative border must let mouse events reach the terminal")

        let remotePane = try XCTUnwrap(app.workspace.current?.focusedPane)
        app.workspace.newLocalSpace()
        let localTab = try XCTUnwrap(app.workspace.activeTab)
        XCTAssertFalse(app.workspace.moveTab(localTab.id, to: remotePane), "A tab drop must not recreate a mixed-host space")
        XCTAssertEqual(app.runtime.ssh.tint(for: tab), tint)
        XCTAssertNil(app.runtime.ssh.tint(for: localTab))
        app.workspace.selectTab(localTab.id)
        let switched = try await capture(app.window, "tint-local-tab")
        XCTAssertLessThan(try distance(local, switched, x: x, y: 1), 0.015, "Selecting a local tab resets its entire strip")
        XCTAssertLessThan(try distance(local, switched, x: x, y: 4), 0.015)
        app.workspace.selectTab(tab.id)

        try await SSHChatTestSupport.dropHelper(app.runtime.ssh, connection.launch.connectionID, reason: "Tint test: auxiliary channel closed")
        try await app.wait { app.runtime.ssh.links[connection.launch.connectionID] == nil }
        XCTAssertEqual(app.runtime.ssh.tint(for: tab)?.hue, tint.hue, "Disconnect preserves the host color identity")
        XCTAssertTrue(app.runtime.ssh.tint(for: tab)?.offline == true, "A lost helper presents the disconnected host state")
        let offline = try XCTUnwrap(app.workspace.hosts.terminals[tab.id]).host
        app.runtime.hosts.reconnect.reconnect(hostID: offline, sourceSurfaceID: tab.id)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains {
                $0.launch.tabID == tab.id && $0.launch.connectionID != connection.launch.connectionID && $0.shellPID != nil
            } && app.runtime.views[tab.id]?.inputParked == false
        }
        terminal = try XCTUnwrap(app.runtime.views[tab.id])
        XCTAssertEqual(app.runtime.ssh.tint(for: tab), tint)
        TerminalTestSupport.send("exit", to: terminal)
        try await app.wait { app.runtime.ssh.machine(for: tab.id) == nil }
        XCTAssertNil(app.runtime.ssh.tint(for: tab), "Returning to the local shell clears the remote tint")
        try await Task.sleep(for: .milliseconds(1100))
        let exited = try await capture(app.window, "tint-after-exit")
        XCTAssertLessThan(try distance(local, exited, x: x, y: 40), 0.015)
        XCTAssertFalse(TerminalTestSupport.screen(terminal: terminal).contains("locking failed"), "Integration loss must preserve the live shell's startup and history paths")

        let aliasArguments = server.options + ["-o", "HostName=127.0.0.1", "-o", "HostKeyAlias=[127.0.0.1]:\(server.port)", NSUserName() + "@tint-test-alias"]
        try await SSHTestServer.authorize(arguments: aliasArguments)
        let alias = "ssh " + aliasArguments.map(HerdrLaunch.quote).joined(separator: " ")
        TerminalTestSupport.send(alias, to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == tab.id && $0.shellPID != nil }
        }
        XCTAssertEqual(app.runtime.ssh.tint(for: tab), tint, "Aliases and new connection generations share the machine's color")
    }

    private func capture(_ window: NSWindow, _ name: String) async throws -> NSBitmapImageRep {
        try await Task.sleep(for: .milliseconds(300))
        return try await PresentationTestSupport.capture(window, named: name, in: "host-tint-validation").bitmap
    }

    private func distance(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> CGFloat {
        // The walkthrough window has a fixed 1120-point content width.
        func color(_ image: NSBitmapImageRep) throws -> NSColor {
            let scale = CGFloat(image.pixelsWide) / 1120
            return try XCTUnwrap(image.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        }
        let a = try color(a), b = try color(b)
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
    }

    func testProgramClipboardWritesFollowSettingOnlyOverHelperConnections() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let helper = try await SSHTestServer(); defer { helper.stop() }
        let plain = try await SSHTestServer(grant: .init(profile: .ordinary)); defer { plain.stop() }
        let pasteboard = NSPasteboard.general
        func activeTerminal() async throws -> TerminalView {
            let id = try XCTUnwrap(app.workspace.activeTab?.id)
            try await app.wait { app.runtime.views[id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
            return try XCTUnwrap(app.runtime.views[id])
        }
        func ssh(_ server: SSHTestServer, from terminal: TerminalView, helper: Bool) async throws {
            TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
            // Ordinary SSH runs without a launch request; only the remote shell can answer.
            if helper {
                try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
                    app.runtime.ssh.links.values.contains { $0.launch.tabID == terminal.id && $0.shellPID != nil }
                }
            }
            let expected = "REMOTE_READY_ssh_" + (helper ? "yes" : "no")
            TerminalTestSupport.send("printf 'REMOTE_%s_%s_%s\\n' READY \"${SSH_CONNECTION:+ssh}\" \"$([ -n \"$DISPATCH_SSH_HELPER\" ] && echo yes || echo no)\"", to: terminal)
            try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
                TerminalTestSupport.screen(terminal: terminal).contains(expected)
            }
        }
        /// OSC 52 from the remote shell, then a marker proving the terminal processed it.
        func copy(_ text: String, in terminal: TerminalView) async throws {
            let marker = "COPIED_" + UUID().uuidString.prefix(8)
            TerminalTestSupport.send("printf '\\033]52;c;%s\\007%s_%s\\n' \(Data(text.utf8).base64EncodedString()) \(marker) DONE", to: terminal)
            try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains(marker + "_DONE") }
        }
        /// A refusal is only meaningful beside an allowed write on the same path.
        func assertRefused(_ description: String) async throws {
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(pasteboard.string(forType: .string), "untouched", description)
        }
        pasteboard.clearContents(); pasteboard.setString("untouched", forType: .string)
        let remote = try await activeTerminal()
        try await ssh(helper, from: remote, helper: true)
        XCTAssertTrue(app.runtime.preferences.allowRemoteClipboardWrites, "Programs on helper hosts can copy by default")
        app.runtime.preferences.allowRemoteClipboardWrites = false
        try await copy("helper-off", in: remote)
        try await assertRefused("Programs on helper hosts cannot copy with the setting off")
        app.runtime.preferences.allowRemoteClipboardWrites = true
        try await copy("helper-on", in: remote)
        try await app.wait { pasteboard.string(forType: .string) == "helper-on" }
        app.runtime.preferences.allowRemoteClipboardWrites = false

        app.workspace.newLocalSpace()
        let ordinary = try await activeTerminal()
        try await ssh(plain, from: ordinary, helper: false)
        try await copy("plain", in: ordinary)
        try await app.wait { pasteboard.string(forType: .string) == "plain" }

        // tmux reached over the helper connection: buffers follow the same setting.
        pasteboard.clearContents(); pasteboard.setString("untouched", forType: .string)
        TerminalTestSupport.send("\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge", to: remote)
        try await TestSupport.eventually(timeout: .seconds(10)) { app.workspace.spaces.contains { $0.structured && $0.remote != nil && $0.remote == app.runtime.link(of: remote.id)?.launch.connectionID } }
        _ = try app.server(["set-buffer", "-b", "remote", "tmux-off"])
        try await assertRefused("tmux over the helper cannot copy with the setting off")
        app.runtime.preferences.allowRemoteClipboardWrites = true
        _ = try app.server(["set-buffer", "-b", "remote", "tmux-on"])
        try await app.wait { pasteboard.string(forType: .string) == "tmux-on" }
    }

    func testTypedSSHAndNewSpaceInstallRemoteIntegrationAndRetainTmuxGateway() async throws {
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(app.runtime.views[source])
        let command = "ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ")
        TerminalTestSupport.send(command, to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        TerminalTestSupport.send("printf 'SSH_READY_%s\\n' \"${DISPATCH_SSH_HELPER:+yes}\"", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("SSH_READY_yes") }
        guard case .ssh(let shell) = app.workspace.currentMachine else { return XCTFail("Expected remote machine context") }
        XCTAssertEqual(shell.destination, server.destination)
        let tint = try XCTUnwrap(app.runtime.ssh.tint(for: try XCTUnwrap(app.workspace.activeTab)))
        try await SSHTestServer.authorize(arguments: shell.arguments, executable: shell.executable)
        try await PresentationTestSupport.chooseNewSpace("New space", in: app.workspace, host: try XCTUnwrap(app.workspace.current?.hostID))
        let newID = try XCTUnwrap(app.workspace.activeTab?.id)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == newID && $0.shellPID != nil }
        }
        let fresh = try XCTUnwrap(app.runtime.views[newID])
        XCTAssertEqual(app.runtime.ssh.tint(for: try XCTUnwrap(app.workspace.activeTab)), tint)
        TerminalTestSupport.send("printf 'SSH_NEW_%s_%s_%s\\n' \"${TMUX-unset}\" \"${HERDR_ENV-unset}\" \"${DISPATCH_SSH_HELPER:+yes}\"", to: fresh)
        try await app.wait { TerminalTestSupport.screen(terminal: fresh).contains("SSH_NEW_unset_unset_yes") }
        TerminalTestSupport.send("\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge", to: fresh)
        try await app.wait { app.workspace.current?.structured == true && !app.workspace.allTabIDs.contains(newID) }
        XCTAssertNotNil(app.runtime.views[newID], "Hidden gateway retains the authenticated SSH master")
        XCTAssertTrue(app.runtime.ssh.links.values.contains { $0.launch.tabID == newID })
        guard case .ssh = app.workspace.currentMachine else { return XCTFail("Native tmux must retain remote host context") }
        XCTAssertEqual(app.runtime.ssh.tint(for: try XCTUnwrap(app.workspace.activeTab)), tint, "Native tmux inherits the hidden SSH gateway's tint")
        _ = try await capture(app.window, "tint-tmux")
    }
}
