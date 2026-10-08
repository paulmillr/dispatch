import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class HostDisconnectTests: XCTestCase {
    func testResetHostDisconnectsAndClearsItsStateWhileKeepingLocalShell() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        let session = try await connect(app, server: server, terminal: source)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[source]).host
        app.workspace.newLocalSpace()
        let local = try XCTUnwrap(app.workspace.activeSurfaceID)
        let view = try await terminal(local, in: app)
        let selected = app.workspace.selectedSpace
        XCTAssertTrue(app.runtime.hosts.canReset(host))
        app.controller.showSettings()
        var settings: NSWindow?
        try await TestSupport.eventually {
            settings = NSApp.windows.first { $0.title == "Settings" && $0.isVisible }
            return settings != nil
        }
        let settingsWindow = try XCTUnwrap(settings)
        defer { settingsWindow.close() }
        try await clickText("Hosts", in: settingsWindow)
        // The remote hosts list ends the Hosts tab: scroll it into view, expand the
        // host's row, choose Forget host… and confirm inline.
        let settingsRoot = try XCTUnwrap(settingsWindow.contentView)
        @MainActor func scrollToBottom() -> Bool {
            guard let scroll = PresentationTestSupport.views(of: NSScrollView.self, in: settingsRoot).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
                  let document = scroll.documentView else { return false }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            return true
        }
        let name = try XCTUnwrap(app.workspace.hosts.records[host]?.name)
        var page = ""
        try await TestSupport.eventually(diagnostic: "Host \(name) not in settings: \(page)") {
            guard scrollToBottom() else { return false }
            page = try await PresentationTestSupport.capture(settingsWindow).text()
            return page.contains(name)
        }
        try await clickText(name, in: settingsWindow)
        // The expanded row grows the page below the visible area.
        var actions = ""
        try await TestSupport.eventually(diagnostic: "Host actions: \(actions)") {
            guard scrollToBottom() else { return false }
            actions = try await PresentationTestSupport.capture(settingsWindow).text()
            return actions.contains("Forget host")
        }
        _ = try await PresentationTestSupport.capture(settingsWindow, named: "settings-reset-host", in: "host-disconnect-validation")
        try await clickText("Forget host", in: settingsWindow)
        try await TestSupport.eventually {
            guard scrollToBottom() else { return false }
            return try await PresentationTestSupport.capture(settingsWindow).text().contains("Forget \(name)?")
        }
        // Vision reads the confirmation's buttons as one line, "Cancel Forget":
        // click the last word only.
        let rows = try await PresentationTestSupport.capture(settingsWindow).recognizedText().compactMap { $0.topCandidates(1).first }
        let buttons = try XCTUnwrap(rows.first { $0.string == "Forget" || $0.string.hasSuffix(" Forget") }, "\(rows.map(\.string))")
        let box = try XCTUnwrap(buttons.boundingBox(for: XCTUnwrap(buttons.string.range(of: "Forget", options: .backwards)))).boundingBox
        try await PresentationTestSupport.hoverAndClick(settingsWindow, at: settingsRoot.convert(NSPoint(x: box.midX * settingsRoot.bounds.width,
            y: (settingsRoot.isFlipped ? 1 - box.midY : box.midY) * settingsRoot.bounds.height), to: nil))
        try await released([session], in: app)
        XCTAssertNil(app.workspace.hosts.records[host])
        XCTAssertFalse(app.workspace.spaces.contains { $0.hostID == host })
        XCTAssertFalse(app.runtime.hosts.reconnect.recipes.values.contains { $0.host == host })
        XCTAssertTrue(app.runtime.ssh.integrationEntries(for: host).isEmpty)
        XCTAssertNil(app.runtime.ssh.permissions.remembered(session.scope))
        XCTAssertTrue(SSHStatisticsStore.shared.keys(for: host).isEmpty)
        XCTAssertNil(HostBackendCache.shared.cached(for: host))
        XCTAssertEqual(app.workspace.selectedSpace, selected)
        XCTAssertTrue(app.runtime.views[local] === view)
        TerminalTestSupport.send("printf 'LOCAL_%s\\n' SURVIVED", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("LOCAL_SURVIVED") }
    }

    func testHostHeadingShowsInformationAndDisconnectsAllVerifiedConnectionsOnly() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        app.controller.settings.values.spaceOrder = .tree
        let first = try XCTUnwrap(app.workspace.activeSurfaceID)
        let a = try await connect(app, server: server, terminal: first)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[first]).host
        app.workspace.newLocalSpace()
        let second = try XCTUnwrap(app.workspace.activeSurfaceID)
        let b = try await connect(app, server: server, terminal: second)
        XCTAssertEqual(app.workspace.hosts.terminals[second]?.host, host)
        app.workspace.newLocalSpace()
        let unrelated = try XCTUnwrap(app.workspace.activeSurfaceID)
        let other = try await terminal(unrelated, in: app)
        let otherServer = try await SSHTestServer(); defer { otherServer.stop() }
        TerminalTestSupport.send(command(otherServer, integrated: false), to: other)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.hosts.terminals[unrelated]?.state == .unverified }
        let otherHost = try XCTUnwrap(app.workspace.hosts.terminals[unrelated]).host
        XCTAssertNotEqual(otherHost, host, "The same login address on a different port must remain a separate host")
        app.workspace.newLocalSpace()
        let local = try XCTUnwrap(app.workspace.activeSurfaceID), selected = app.workspace.selectedSpace
        let localView = try await terminal(local, in: app)
        app.runtime.hosts.disconnect(.local)
        XCTAssertNotNil(app.runtime.ssh.links[a.launch.connectionID])
        if !app.controller.sidebarVisible { app.controller.toggleSidebar() }
        try await openHostInformation(host, in: app.window)
        var popover: NSWindow?
        var visible = [String]()
        try await TestSupport.eventually(diagnostic: visible.joined(separator: "\n")) {
            visible = []
            popover = nil
            for window in NSApp.windows {
                guard window !== app.window, window.isVisible else { continue }
                let text = try await PresentationTestSupport.capture(window).text()
                visible.append("\(type(of: window)) \(window.frame): " + text)
                if text.contains("Disconnect") { popover = window; break }
            }
            return popover != nil
        }
        let popup = try XCTUnwrap(popover)
        // Backend discovery and the statistics subscription resize this card
        // after it first opens. Click the settled footer, not its opening frame.
        try await Task.sleep(for: .milliseconds(500))
        let info = try await PresentationTestSupport.capture(popup, named: "host-information", in: "host-disconnect-validation").text()
        XCTAssertTrue(info.localizedCaseInsensitiveContains("macOS"), info)
        for component in server.destination.split(separator: "@") {
            XCTAssertTrue(info.contains(String(component)), info)
        }
        XCTAssertEqual(app.workspace.hosts.state(host), .connected)
        XCTAssertTrue(info.contains("Disconnect"), info)
        XCTAssertEqual(app.workspace.selectedSpace, selected, "Opening host information must not navigate away from the current space")
        try await clickText("Disconnect", in: popup)
        try await released([a, b], in: app)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            app.workspace.hosts.terminals[first]?.state == .disconnected && app.workspace.hosts.terminals[second]?.state == .disconnected
        }
        XCTAssertEqual(app.workspace.selectedSpace, selected)
        XCTAssertTrue(app.runtime.views[local] === localView)
        XCTAssertEqual(app.workspace.hosts.terminals[unrelated]?.host, otherHost)
        app.workspace.selectSurface(unrelated)
        TerminalTestSupport.send("printf 'OTHER_%s\\n' SURVIVED", to: other)
        try await app.wait { TerminalTestSupport.screen(terminal: other).contains("OTHER_SURVIVED") }
        app.runtime.hosts.disconnect(host) // Repeating a completed action cannot affect the alias.
        XCTAssertEqual(app.workspace.hosts.terminals[unrelated]?.host, otherHost)
        app.runtime.hosts.disconnect(otherHost)
        try await TestSupport.eventually { app.workspace.hosts.terminals[unrelated] == nil }
    }

    func testDisconnectReleasesRetainedHerdrAndReusedOriginWithoutKillingJobs() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        // The origin shell is exited and reused below; only herdr keeps it.
        app.workspace.closeLaunching["herdr"] = false
        let server = try await SSHTestServer(); defer { server.stop() }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        let first = try await connect(app, server: server, terminal: source)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[source]).host
        let origin = try XCTUnwrap(app.runtime.views[source])
        let socket = server.root.appendingPathComponent("herdr.sock").path
        defer { _ = try? HerdrSocket(path: socket).request("server.stop") }
        TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(server.root.path)
            + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: origin)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        let nativeID = try XCTUnwrap(app.workspace.activeSurfaceID)
        let native = try await terminal(nativeID, in: app)
        let processFile = server.root.appendingPathComponent("native-pid")
        TerminalTestSupport.send("printf '%s\\n' $$ > " + HerdrLaunch.quote(processFile.path) + "; printf 'NATIVE_%s\\n' READY", to: native)
        try await app.wait { TerminalTestSupport.screen(terminal: native).contains("NATIVE_READY") }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: processFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let process = try XCTUnwrap(AgentProcess.capture(pid))
        app.workspace.selectSurface(source)
        TerminalTestSupport.send("exit", to: origin)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.runtime.ssh.machine(for: source) == nil }
        XCTAssertNotNil(app.runtime.ssh.links[first.launch.connectionID])
        let next = try await connect(app, server: server, terminal: source)
        XCTAssertNotEqual(next.launch.connectionID, first.launch.connectionID)
        XCTAssertEqual(app.workspace.hosts.terminals[nativeID]?.generation, first.launch.connectionID.rawValue,
                       "A reused origin must not reassign the retained native connection")
        app.runtime.hosts.disconnect(host)
        try await released([first, next], in: app)
        try await TestSupport.eventually { app.workspace.hosts.terminals[source]?.state == .disconnected }
        XCTAssertTrue(process.alive, "Disconnect preserves remote herdr jobs")
        XCTAssertEqual(app.workspace.hosts.terminals[nativeID]?.state, .disconnected)
        XCTAssertFalse(app.runtime.hosts.canDisconnect(host))
        struct Snapshot: Decodable { let snapshot: HerdrSnapshot }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: HerdrSocket(path: socket).request("session.snapshot"))
        XCTAssertFalse(snapshot.snapshot.workspaces.isEmpty)
        app.runtime.hosts.reset(host)
        XCTAssertTrue(process.alive, "Reset only clears client state; the remote herdr shell keeps running")
        XCTAssertFalse(app.workspace.spaces.contains { $0.hostID == host })
        XCTAssertNil(app.workspace.hosts.records[host])
    }

    func testHostPopoverDisconnectsEveryDirectSSHTmuxSpaceAndPreservesServer() async throws {
        // Reads the sidebar through offscreen captures, which cannot draw Liquid Glass.
        let app = try TmuxWalkthrough(liquidGlass: false); defer { app.close() }
        // This frozen rename fixture used the compact default before upstream made large rows the default.
        app.controller.settings.values.largeSidebarItems = false
        let server = try await SSHTestServer(); defer { server.stop() }
        app.controller.settings.values.spaceOrder = .tree
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        let command = (["/usr/bin/ssh"] + server.options + ["-tt", server.destination,
            "\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge"]).map(HerdrLaunch.quote).joined(separator: " ")
        try await app.attach(command: "TERM=xterm-256color " + command); try await app.ready()
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.hosts.terminals[source] != nil }
        let host = try XCTUnwrap(app.workspace.hosts.terminals[source]).host
        let backend = try XCTUnwrap(app.workspace.current?.backend)
        app.workspace.newSpace()
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "New backend space: host=\(host) backend=\(backend) selected=\(String(describing: app.workspace.selectedSpace)) spaces=\(app.workspace.spaces.map { ($0.id, $0.backend, $0.hostID, $0.tabs.map(\.isConnecting)) }) helper=\(app.runtime.helpers[.local]?.error ?? "none")") {
            let spaces = app.workspace.spaces.filter { $0.backend == backend }
            return spaces.count == 2 && spaces.allSatisfy { $0.tabs.allSatisfy { !$0.isConnecting } } && app.workspace.current?.hostID == host
        }
        let pids = try app.server(["list-panes", "-a", "-F", "#{pane_pid}"]).split(separator: "\n")
            .compactMap { Int32($0) }.compactMap(AgentProcess.capture)
        XCTAssertGreaterThanOrEqual(pids.count, 2)
        let space = try XCTUnwrap(app.workspace.current)
        let label = "Departing" // Short enough for a tree-mode sidebar row with its shortcut.
        app.workspace.renameSpace(space.id, to: label)
        var renamed = ""
        var snapshot: PresentationTestSupport.Snapshot?
        do {
            try await TestSupport.eventually(diagnostic: {
                let root = app.window.contentView
                let rows = root.map { PresentationTestSupport.views(of: ReorderTrackingView.self, in: $0) }?.filter { $0.configuration.item == .space(space.id) } ?? []
                let scrolls = root.map { PresentationTestSupport.views(of: NSScrollView.self, in: $0) } ?? []
                return "Renamed space: \(renamed), model=\(String(describing: app.workspace.spaces.first { $0.id == space.id }?.name)), sidebar=\(app.controller.sidebarVisible), rows=\(rows.map { "frame=\($0.convert($0.bounds, to: root)) visible=\($0.visibleRect) hidden=\($0.isHiddenOrHasHiddenAncestor)" }), scrolls=\(scrolls.map { "viewport=\($0.contentView.bounds) document=\(String(describing: $0.documentView?.bounds))" })"
            }()) {
                let captured = try await PresentationTestSupport.capture(app.window)
                snapshot = captured
                renamed = try captured.text()
                return renamed.contains(label)
            }
        } catch {
            if let snapshot { try PresentationTestSupport.save(snapshot.bitmap, named: "renamed-space-failure", in: "host-disconnect-validation") }
            if let root = app.window.contentView {
                let cached = try PresentationTestSupport.render(root, named: "renamed-space-appkit", in: "host-disconnect-validation")
                print("Renamed space AppKit cache: \(try cached.text())")
            }
            throw error
        }
        try await Task.sleep(for: .milliseconds(200))
        // The host's sidebar header, by identifier: text recognition misreads the host's dotted address.
        let card = try XCTUnwrap(PresentationTestSupport.views(of: HostSecondaryClickView.self, in: try XCTUnwrap(app.window.contentView)).first {
            $0.accessibilityIdentifier() == "host-card-" + host.rawValue && !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty
        })
        try await PresentationTestSupport.hoverAndClick(app.window, at: card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil))
        var popover: NSWindow?
        try await TestSupport.eventually {
            popover = nil
            for window in NSApp.windows {
                guard window !== app.window, window.isVisible else { continue }
                if try await PresentationTestSupport.capture(window).text().contains("Disconnect") { popover = window; break }
            }
            return popover != nil
        }
        try await clickText("Disconnect", in: try XCTUnwrap(popover))
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !app.workspace.spaces.contains { $0.backend == backend } && app.workspace.hosts.terminals[source] == nil
        }
        XCTAssertTrue(app.workspace.spaces.allSatisfy { $0.backend != backend })
        XCTAssertTrue(pids.allSatisfy(\.alive), "Disconnect must detach the control client without killing tmux panes")
        XCTAssertFalse(app.runtime.hosts.canDisconnect(host))
        XCTAssertNil(app.runtime.helpers[.local]?.error, "An explicit disconnect is not a transport failure")
    }

    func testDisconnectInsideLocalTmuxRestoresTheSameShellAndBackend() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab), view = try XCTUnwrap(app.runtime.views[tab.id])
        let pane = try XCTUnwrap(app.target(tab))
        let pid = try XCTUnwrap(Int32(try app.server(["display-message", "-p", "-t", pane, "#{pane_pid}"]).trimmingCharacters(in: .whitespacesAndNewlines)))
        let process = try XCTUnwrap(AgentProcess.capture(pid))
        TerminalTestSupport.send(command(server, integrated: false), to: view)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.hosts.terminals[tab.id]?.state == .unverified }
        app.runtime.hosts.disconnect(try XCTUnwrap(app.workspace.hosts.terminals[tab.id]).host)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.hosts.terminals[tab.id] == nil }
        XCTAssertTrue(app.attached, "The local tmux session stays attached")
        XCTAssertTrue(process.alive)
        XCTAssertTrue(app.runtime.views[tab.id] === view)
        TerminalTestSupport.send("printf 'LOCAL_TMUX_%s\\n' SURVIVED", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("LOCAL_TMUX_SURVIVED") }
    }

    func testNewOrdinarySSHTabsReuseTheSidebarHost() async throws { try await repeatedTabs(.ordinary) }
    func testNewStatisticsSSHTabsReuseTheSidebarHost() async throws { try await repeatedTabs(.statistics) }

    private func repeatedTabs(_ profile: SSHIntegrationProfile) async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let grant = SSHIntegrationGrant(profile: profile)
        let server = try await SSHTestServer(grant: grant); defer { server.stop() }
        let previous = app.runtime.ssh.presentIntegrationConsent
        app.runtime.ssh.presentIntegrationConsent = { _, _ in .init(grant: grant) }
        defer { app.runtime.ssh.presentIntegrationConsent = previous }
        let first = try XCTUnwrap(app.workspace.activeSurfaceID)
        let firstView = try await terminal(first, in: app)
        TerminalTestSupport.send(command(server), to: firstView)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            guard let context = app.workspace.hosts.terminals[first] else { return false }
            return profile == .ordinary ? context.state == .unverified : context.authenticated
        }
        let host = try XCTUnwrap(app.workspace.hosts.terminals[first]).host
        for _ in 0..<2 {
            app.workspace.selectSurface(first)
            app.workspace.newTab() // Copies SSH with different TTY/forwarding options.
            let second = try XCTUnwrap(app.workspace.activeSurfaceID)
            XCTAssertNotEqual(first, second)
            let view = try await terminal(second, in: app)
            try await TestSupport.eventually(timeout: .seconds(20), diagnostic:
                "Second tab context: \(String(describing: app.workspace.hosts.terminals[second])); first context: \(String(describing: app.workspace.hosts.terminals[first])); terminal: \(TerminalTestSupport.screen(terminal: view)); chat error: \(app.runtime.chat.error ?? "none")") {
                guard let context = app.workspace.hosts.terminals[second] else { return false }
                return profile == .ordinary ? context.state == .unverified : context.authenticated
            }
            XCTAssertEqual(app.workspace.hosts.terminals[second]?.host, host)
            XCTAssertEqual(app.workspace.liveHosts.filter { $0.id != .local }.map(\.id), [host])
            XCTAssertNotEqual(app.workspace.hosts.terminals[first]?.generation, app.workspace.hosts.terminals[second]?.generation)
            TerminalTestSupport.send("printf 'SAME_HOST_%s\\n' READY", to: view)
            try await app.wait { TerminalTestSupport.screen(terminal: view).contains("SAME_HOST_READY") }
            app.workspace.closeTab(second)
            try await TestSupport.eventually { app.workspace.hosts.terminals[second] == nil }
            XCTAssertEqual(app.workspace.hosts.terminals[first]?.host, host)
        }
        app.runtime.hosts.disconnect(host)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            profile == .ordinary ? app.workspace.hosts.terminals[first] == nil : app.workspace.hosts.terminals[first]?.state == .disconnected
        }
    }

    func testHostPopupResetsPermissionsAndNextLoginShowsChooser() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        app.controller.settings.values.spaceOrder = .tree
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        let session = try await connect(app, server: server, terminal: id)
        let host = try XCTUnwrap(app.workspace.hosts.terminals[id]).host
        let view = try await terminal(id, in: app)
        if !app.controller.sidebarVisible { app.controller.toggleSidebar() }
        try await openHostInformation(host, in: app.window)
        var popup: NSWindow?
        try await TestSupport.eventually {
            popup = nil
            for window in NSApp.windows {
                guard window !== app.window, window.isVisible else { continue }
                if try await PresentationTestSupport.capture(window).text().contains("features") { popup = window; break }
            }
            return popup != nil
        }
        let menu = try XCTUnwrap(popup)
        try await activate(menu)
        var previousFrame = menu.frame, stableSince = ContinuousClock.now
        try await TestSupport.eventually {
            let loading = try await PresentationTestSupport.capture(menu).text().contains("Loading stats")
            if menu.frame != previousFrame || loading {
                previousFrame = menu.frame; stableSince = .now
                return false
            }
            return stableSince.duration(to: .now) >= .milliseconds(500)
        }
        _ = try await PresentationTestSupport.capture(menu, named: "reset-permissions", in: "host-disconnect-validation")
        let reset = DisconnectMenuSelection(title: "Reset integration")
        NotificationCenter.default.addObserver(reset, selector: #selector(DisconnectMenuSelection.opened), name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(reset) }
        let index = try XCTUnwrap(app.runtime.ssh.integrationEntries(for: host).firstIndex { $0.scope == session.scope })
        let integrations = try await PresentationTestSupport.capture(menu).recognizedText().filter {
            $0.topCandidates(1).first?.string.contains("features") == true
        }.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        XCTAssertLessThan(index, integrations.count)
        let content = try XCTUnwrap(menu.contentView), box = integrations[index].boundingBox
        let point = content.convert(NSPoint(x: box.midX * content.bounds.width,
            y: (content.isFlipped ? 1 - box.midY : box.midY) * content.bounds.height), to: nil)
        // SwiftUI context menus need the complete sequence through the app's
        // event loop, including the pointer location used by gesture tracking.
        let previousPointer = CGEvent(source: nil)?.location
        defer { if let previousPointer { CGWarpMouseCursorPosition(previousPointer) } }
        let screen = menu.convertPoint(toScreen: point), desktop = try XCTUnwrap(NSScreen.screens.first)
        let position = CGPoint(x: screen.x, y: desktop.frame.maxY - screen.y)
        XCTAssertEqual(CGWarpMouseCursorPosition(position), .success)
        let move = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: position, mouseButton: .right))
        move.postToPid(getpid())
        menu.sendEvent(try PresentationTestSupport.mouseEvent(.mouseMoved, in: menu, at: point))
        try await Task.sleep(for: .milliseconds(150))
        func secondaryEvent(_ type: NSEvent.EventType) throws -> NSEvent {
            let event = try PresentationTestSupport.mouseEvent(type, in: menu, at: point)
            let native = try XCTUnwrap(event.cgEvent)
            // SwiftUI's context-menu recognizer also checks the button metadata.
            // This conversion uses the pointer positioned above; direct handler
            // tests retain NSEvent's explicit window-relative coordinates.
            native.setIntegerValueField(.mouseEventButtonNumber, value: 1)
            return try XCTUnwrap(NSEvent(cgEvent: native))
        }
        NSApp.postEvent(try secondaryEvent(.rightMouseUp), atStart: true)
        NSApp.sendEvent(try secondaryEvent(.rightMouseDown))
        try await TestSupport.eventually(diagnostic: "Reset menu actions: \(reset.observed)") { reset.selected }
        try await TestSupport.eventually { app.runtime.ssh.permissions.remembered(session.scope) == nil }
        XCTAssertNil(app.runtime.ssh.permissions.remembered(session.scope))
        XCTAssertTrue(app.runtime.ssh.integrationEntries(for: host).allSatisfy { $0.scope != session.scope })
        XCTAssertTrue(app.runtime.ssh.links[session.launch.connectionID]?.grant.capabilities.isEmpty ?? true)
        try PresentationTestSupport.click(app.window, at: NSPoint(x: 500, y: 200))
        TerminalTestSupport.send("printf 'RESET_SHELL_%s\\n' ALIVE", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("RESET_SHELL_ALIVE") }
        TerminalTestSupport.send("exit", to: view)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.hosts.terminals[id] == nil }
        TerminalTestSupport.send(command(server), to: view)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.window.attachedSheet != nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let sheet = try XCTUnwrap(app.window.attachedSheet)
        let buttons = descendants(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }
        let helper = try XCTUnwrap(buttons.first { $0.title == "Upload the Dispatch helper" })
        XCTAssertEqual(helper.state, .on)
        helper.performClick(nil)
        let connect = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "ssh-consent-save" })
        connect.performClick(nil)
        try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.hosts.terminals[id]?.state == .unverified }
        XCTAssertEqual(app.runtime.ssh.permissions.remembered(session.scope)?.profile, .ordinary)
        app.runtime.hosts.disconnect(try XCTUnwrap(app.workspace.hosts.terminals[id]).host)
        try await TestSupport.eventually { app.workspace.hosts.terminals[id] == nil }
    }

    private func command(_ server: SSHTestServer, integrated: Bool = true) -> String {
        ([integrated ? "ssh" : "/usr/bin/ssh"] + server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " ")
    }

    private func terminal(_ id: UUID, in app: TmuxWalkthrough) async throws -> TerminalView {
        try await app.wait { app.runtime.views[id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        return try XCTUnwrap(app.runtime.views[id])
    }

    private func connect(_ app: TmuxWalkthrough, server: SSHTestServer, terminal id: UUID) async throws -> SSHCoordinator.Link {
        TerminalTestSupport.send(command(server), to: try await terminal(id, in: app))
        try await TestSupport.eventually(timeout: .seconds(20)) { app.runtime.link(of: id) != nil }
        return try XCTUnwrap(app.runtime.link(of: id))
    }

    private func released(_ sessions: [SSHCoordinator.Link], in app: TmuxWalkthrough) async throws {
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: sessions.map { session in
            "session=\(app.runtime.ssh.links[session.launch.connectionID] != nil) control=\(FileManager.default.fileExists(atPath: session.launch.master.controlPath))"
        }.joined(separator: ", ")) {
            sessions.allSatisfy { session in
                app.runtime.ssh.links[session.launch.connectionID] == nil &&
                !FileManager.default.fileExists(atPath: session.launch.master.controlPath)
            }
        }
    }

    private func clickText(_ text: String, in window: NSWindow, sidebarOnly: Bool = false) async throws {
        let view = try XCTUnwrap(window.contentView)
        var point: NSPoint?
        try await TestSupport.eventually(diagnostic: "Missing positioned text for click: \(text)") {
            let snapshot = try await PresentationTestSupport.capture(window)
            guard snapshot.positioned, let box = try snapshot.box(of: text),
                  !sidebarOnly || box.midX * view.bounds.width < 240 else { return false }
            point = view.convert(NSPoint(x: box.midX * view.bounds.width,
                                         y: (view.isFlipped ? 1 - box.midY : box.midY) * view.bounds.height), to: nil)
            return true
        }
        try await PresentationTestSupport.hoverAndClick(window, at: XCTUnwrap(point))
    }

    private func openHostInformation(_ host: HostID, in window: NSWindow) async throws {
        try await activate(window)
        let content = try XCTUnwrap(window.contentView)
        var button: HostSecondaryClickView?
        try await TestSupport.eventually {
            button = PresentationTestSupport.views(of: HostSecondaryClickView.self, in: content).first {
                $0.accessibilityIdentifier() == "host-card-" + host.rawValue &&
                    $0.window === window && !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty
            }
            return button != nil
        }
        let target = try XCTUnwrap(button)
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        target.rightMouseDown(with: try PresentationTestSupport.mouseEvent(.rightMouseDown, in: window, at: point))
    }

    private func activate(_ window: NSWindow) async throws {
        try await TestSupport.eventually {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            return window.isKeyWindow
        }
    }
}

@MainActor
private final class DisconnectMenuSelection: NSObject {
    var selected = false
    var observed: [[String]] = []
    let title: String
    init(title: String = "Disconnect") { self.title = title }

    @objc func opened(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        // AppKit tracks menus in a nested run loop; the main dispatch queue
        // cannot reenter the currently executing XCTest action there.
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(selectItem), userInfo: menu, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func selectItem(_ timer: Timer) {
        guard let menu = timer.userInfo as? NSMenu else { return }
        observed.append(menu.items.map(\.title))
        if let item = menu.items.first(where: { $0.title == title || (title == "Disconnect" && $0.title.hasPrefix("Disconnect from ")) }) {
            XCTAssertTrue(item.isEnabled)
            menu.performActionForItem(at: menu.index(of: item)); selected = true
        }
        menu.cancelTracking()
    }
}
