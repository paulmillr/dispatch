import AppKit
import SwiftUI
import XCTest
import Term
@testable import DispatchApp

@MainActor
final class HerdrIntegrationTests: XCTestCase {
    func testLaunchFailuresAliasesServerRestartAndEmptySession() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        guard FileManager.default.isExecutableFile(atPath: TestSupport.tool("herdr")) else { throw XCTSkip("Install herdr 0.9.3 to run local integration tests.") }
        let root = URL(fileURLWithPath: "/tmp/he-\(UUID().uuidString.prefix(8))")
        let bin = root.appendingPathComponent("bin alias")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("herdr").path, withDestinationPath: TestSupport.tool("herdr"))
        let socket = root.appendingPathComponent("herdr.sock").path
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let workspace = controller.workspace
        runtime.workspace = workspace; runtime.start(preferences: Preferences())
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newLocalSpace()
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentView = nil; runtime.stop()
            if let connection = try? HerdrSocket(path: socket) { try? connection.request("server.stop") }
            try? FileManager.default.removeItem(at: root)
        }
        func localTerminal() async throws -> TerminalView {
            let id = try XCTUnwrap(workspace.activeTab?.id)
            try await TestSupport.eventually { runtime.views[id]?.surface != nil }
            let terminal = runtime.views[id]!
            try await TestSupport.eventually { !TerminalTestSupport.screen(terminal: terminal).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return terminal
        }
        let source = try await localTerminal()
        TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; herdr --session bad/name", to: source)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: source).contains("Invalid herdr session name") }
        XCTAssertEqual(workspace.activeTab?.id, source.id, "Rejected launches leave the original terminal intact")

        // Paths are resolved in the launching shell, which need not share the
        // app's working directory. A directory name with spaces also tests quoting.
        let launch = "cd \(HerdrLaunch.quote(root.path)); export PATH='bin alias':\(TestSupport.path):/usr/bin:/bin; export XDG_CONFIG_HOME=\(HerdrLaunch.quote(root.path)); export XDG_STATE_HOME=\(HerdrLaunch.quote(root.path)); export HERDR_SOCKET_PATH=herdr.sock; herdr"
        TerminalTestSupport.send(launch, to: source)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: source)) { workspace.current?.shows("herdr") == true }
        let space = workspace.current!, first = workspace.activeTab!
        let ids = workspace.allSurfaceIDs
        workspace.newLocalSpace()
        let alias = try await localTerminal()
        TerminalTestSupport.send("export HERDR_SESSION=alias; " + launch.replacingOccurrences(of: "HERDR_SOCKET_PATH=herdr.sock", with: "HERDR_SOCKET_PATH=\(HerdrLaunch.quote(root.resolvingSymlinksInPath().appendingPathComponent("herdr.sock").path))") + " client --help", to: alias)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: alias)) { !workspace.allTabIDs.contains(alias.id) }
        XCTAssertEqual(workspace.spaces.count, 1, "Aliases attach to the existing native server views: \(workspace.spaces.compactMap(\.key))")
        XCTAssertEqual(workspace.allSurfaceIDs, ids)
        XCTAssertEqual(workspace.activeTab?.id, first.id)

        // A second writable client can explicitly take over this test terminal.
        // Dispatch must wait, drop input while disconnected, and recover on release.
        // The first pane: its app tab, herdr's terminal id (node key) and pane id (server snapshot).
        let paneID = try XCTUnwrap(HerdrTestSupport.pane(of: first.id, in: workspace, socket: socket)), terminalID = try XCTUnwrap(workspace.key(of: first))
        try await TestSupport.eventually { runtime.views[first.id]?.surface != nil }
        let native = runtime.views[first.id]!
        TerminalTestSupport.send("printf 'OWNER_%s\\n' NATIVE", to: native)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: native).contains("OWNER_NATIVE") }
        let competitor = Process(), competitorInput = Pipe()
        competitor.executableURL = URL(fileURLWithPath: TestSupport.tool("herdr"))
        competitor.arguments = ["terminal", "session", "control", terminalID, "--takeover", "--cols", "80", "--rows", "24"]
        competitor.environment = ProcessInfo.processInfo.environment.merging(["HERDR_SOCKET_PATH": socket]) { _, new in new }
        competitor.standardInput = competitorInput
        competitor.standardOutput = FileHandle.nullDevice; competitor.standardError = FileHandle.nullDevice
        try competitor.run()
        defer {
            competitorInput.fileHandleForWriting.closeFile()
            if competitor.isRunning { competitor.terminate() }
            competitor.waitUntilExit()
        }
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: native).contains("disconnected") }
        XCTAssertTrue(competitor.isRunning, "Automatic reconnect must not take over another controller")
        TerminalTestSupport.send("printf 'SHOULD_%s\\n' NOT_RUN", to: native)
        var input = try JSONSerialization.data(withJSONObject: ["type": "terminal.input", "text": "printf 'OWNER_%s\\n' EXTERNAL\r"])
        input.append(10); try competitorInput.fileHandleForWriting.write(contentsOf: input)
        try await TestSupport.eventually {
            let read = try self.api(socket, "pane.read", ["pane_id": paneID, "source": "visible", "format": "text"])
            return ((read["read"] as? [String: Any])?["text"] as? String)?.contains("OWNER_EXTERNAL") == true
        }
        _ = try await PresentationTestSupport.capture(window, named: "herdr-controller-busy", in: "herdr-audit")
        try competitorInput.fileHandleForWriting.write(contentsOf: Data("{\"type\":\"terminal.release\"}\n".utf8))
        try await TestSupport.eventually { !competitor.isRunning }
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: native).contains("OWNER_EXTERNAL") }
        TerminalTestSupport.send("printf 'RECLAIM_%s · caffè 漢字\\n' NATIVE", to: native)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: native).contains("RECLAIM_NATIVE · caffè 漢字") }
        XCTAssertFalse(TerminalTestSupport.screen(terminal: native).contains("SHOULD_NOT_RUN"), "Disconnected input is never replayed after another client's turn")

        // A disconnect does not restart anything by itself. Explicitly typing
        // herdr again is allowed to bootstrap a server that the user stopped.
        _ = try api(socket, "server.stop")
        try await TestSupport.eventually { (try? HerdrSocket(path: socket)) == nil }
        try await TestSupport.eventually { runtime.views[first.id].map { TerminalTestSupport.screen(terminal: $0).contains("disconnected") } == true }
        XCTAssertEqual(workspace.spaces.first { $0.id == space.id }?.shows("herdr"), true, "A stopped server's space stays until the user acts")
        _ = try await PresentationTestSupport.capture(window, named: "herdr-disconnected", in: "herdr-audit")
        XCTAssertNil(try? HerdrSocket(path: socket), "Background reconnect must not restart a stopped server")
        workspace.newLocalSpace()
        let restart = try await localTerminal()
        TerminalTestSupport.send(launch, to: restart)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: restart)) { !workspace.allTabIDs.contains(restart.id) }
        let restarted = try XCTUnwrap(workspace.activeTab)
        try await TestSupport.eventually { runtime.views[restarted.id]?.surface != nil }
        let terminal = runtime.views[restarted.id]!
        TerminalTestSupport.send("printf 'RESTART_%s\\n' READY", to: terminal)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: terminal).contains("RESTART_READY") }

        // Server-side closure repairs native selection and releases old surfaces.
        workspace.newTab()
        try await TestSupport.eventually { workspace.currentTabs.count == 2 && workspace.activeTab?.isConnecting == false }
        let closing = workspace.activeTab!
        _ = try api(socket, "tab.close", ["tab_id": try XCTUnwrap(workspace.windowKey(of: closing))])
        try await TestSupport.eventually { workspace.currentTabs.count == 1 && workspace.activeTab?.id != closing.id }
        XCTAssertNil(runtime.views[closing.id])
        let closingSpace = workspace.current!
        _ = try api(socket, "workspace.close", ["workspace_id": try XCTUnwrap(closingSpace.key)])
        try await TestSupport.eventually { workspace.spaces.isEmpty }
        workspace.newLocalSpace()
        let empty = try await localTerminal()
        TerminalTestSupport.send(launch, to: empty)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: empty)) { workspace.current?.shows("herdr") == true }
        XCTAssertEqual(workspace.spaces.count, 1)
        XCTAssertEqual(workspace.currentTabs.count, 1)
        XCTAssertFalse(workspace.allTabIDs.contains(empty.id))
        let recoveredID = workspace.activeTab!.id
        try await TestSupport.eventually { runtime.views[recoveredID]?.surface != nil }
        let recovered = runtime.views[recoveredID]!
        try await TerminalTestSupport.assertPhysicalTyping(in: window, terminal: recovered)
        TerminalTestSupport.send("printf 'RECOVERED_%s\\n' READY", to: recovered)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: recovered).contains("RECOVERED_READY") }
        try await Task.sleep(for: .milliseconds(200))
        _ = try await PresentationTestSupport.capture(window, named: "herdr-recovered", in: "herdr-audit")
    }

    func testRealHerdrHandoffNativeControlsAndPersistentTerminals() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        guard FileManager.default.isExecutableFile(atPath: TestSupport.tool("herdr")) else { throw XCTSkip("Install herdr 0.9.3 to run local integration tests.") }
        let root = URL(fileURLWithPath: "/tmp/hh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let socket = root.appendingPathComponent("herdr.sock").path
        let namedSocket = root.appendingPathComponent("herdr/sessions/other.session/herdr.sock").path
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let workspace = controller.workspace
        runtime.workspace = workspace; runtime.start(preferences: Preferences())
        XCTAssertNil(runtime.error)
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newSpace(); workspace.newTab()
        let originalSpace = workspace.selectedSpace!, sourceID = workspace.activeTab!.id
        let siblingID = workspace.currentTabs[0].id
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentView = nil; runtime.stop()
            for path in [socket, namedSocket] {
                if let connection = try? HerdrSocket(path: path) { try? connection.request("server.stop") }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try await TestSupport.eventually(diagnostic: "source=\(sourceID), views=\(runtime.views.keys), key=\(window.isKeyWindow), error=\(String(describing: runtime.error))") { runtime.views[sourceID]?.surface != nil }
        let source = try XCTUnwrap(runtime.views[sourceID])
        try await TestSupport.eventually { !TerminalTestSupport.screen(terminal: source).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let launch = "export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=\(HerdrLaunch.quote(root.path)); export XDG_STATE_HOME=\(HerdrLaunch.quote(root.path)); export HERDR_SOCKET_PATH=\(HerdrLaunch.quote(socket)); cd \(HerdrLaunch.quote(root.path)); herdr"
        TerminalTestSupport.send(launch, to: source)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: source)) { workspace.current?.shows("herdr") == true }
        // The handoff closes the launching tab once the server's space is shown.
        try await TestSupport.eventually { !workspace.allTabIDs.contains(sourceID) }
        XCTAssertEqual(workspace.spaces.first { $0.id == originalSpace }?.tabs.map(\.id), [siblingID])
        let herdrSpace = try XCTUnwrap(workspace.current)
        // The server: the space's helper backend; app tabs are herdr panes, windows herdr tabs.
        let server = try XCTUnwrap(herdrSpace.backend), spaceKey = try XCTUnwrap(herdrSpace.key)
        let firstContainer = try XCTUnwrap(workspace.current?.activeWindow)
        let firstTab = try XCTUnwrap(workspace.activeTab)
        let firstPane = try XCTUnwrap(HerdrTestSupport.pane(of: firstTab.id, in: workspace, socket: socket))
        let firstWindow = try XCTUnwrap(workspace.windowKey(of: firstTab))
        XCTAssertEqual(URL(fileURLWithPath: firstTab.directory).resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        try await TestSupport.eventually(timeout: .seconds(10)) { runtime.views[firstTab.id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[firstTab.id])
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            let text = TerminalTestSupport.screen(terminal: terminal)
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.contains("disconnected")
        }
        TerminalTestSupport.send("printf 'HERDR_%s\\n' NATIVE", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: terminal)) { TerminalTestSupport.screen(terminal: terminal).contains("HERDR_NATIVE") }
        let process = try api(socket, "pane.process_info", ["pane_id": firstPane])
        let shellPID = try XCTUnwrap((process["process_info"] as? [String: Any])?["shell_pid"] as? Int)

        TerminalTestSupport.send("herdr tab rename \(firstWindow) 'Shell renamed'", to: terminal)
        try await TestSupport.eventually { workspace.current?.activeWindow?.name == "Shell renamed" }

        workspace.renameSpace(herdrSpace.id, to: "Native space")
        workspace.renameWindow(firstContainer.id, to: "Native tab")
        try await TestSupport.eventually { workspace.current?.name == "Native space" && workspace.current?.activeWindow?.name == "Native tab" }
        try await TestSupport.eventually {
            let state = try self.api(socket, "session.snapshot")
            return String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self).contains("Native tab")
        }
        let state = try api(socket, "session.snapshot")
        XCTAssertTrue(String(data: try JSONSerialization.data(withJSONObject: state), encoding: .utf8)!.contains("Native tab"))
        workspace.newTab()
        try await TestSupport.eventually { workspace.current?.windows.count == 2 && workspace.current?.activeWindow?.id != firstContainer.id && workspace.activeTab?.isConnecting == false }
        let secondContainer = try XCTUnwrap(workspace.current?.activeWindow)
        let second = workspace.activeTab!
        workspace.selectWindow(firstContainer.id)
        try await TestSupport.eventually { try self.focusedTab(socket) == firstWindow }
        let secondWindow = try XCTUnwrap(workspace.windowKey(of: second))
        _ = try api(socket, "tab.focus", ["tab_id": secondWindow])
        try await TestSupport.eventually { workspace.current?.activeWindow?.id == secondContainer.id }
        _ = try api(socket, "tab.rename", ["tab_id": secondWindow, "label": "CLI tab"])
        _ = try api(socket, "workspace.rename", ["workspace_id": spaceKey, "label": "CLI space"])
        try await TestSupport.eventually { workspace.current?.activeWindow?.name == "CLI tab" && workspace.current?.name == "CLI space" }

        try await PresentationTestSupport.chooseNewSpace("New herdr space", in: workspace)
        try await TestSupport.eventually { workspace.spaces.filter { $0.shows("herdr") }.count == 2 && workspace.current?.id != herdrSpace.id && workspace.activeTab?.isConnecting == false }
        let otherSpace = workspace.current!
        workspace.selectSpace(herdrSpace.id)
        try await TestSupport.eventually { try self.focusedWorkspace(socket) == spaceKey }
        workspace.selectSpace(otherSpace.id)
        try await TestSupport.eventually { try self.focusedWorkspace(socket) == otherSpace.key }
        XCTAssertTrue(workspace.reorderSpace(otherSpace.id, relativeTo: herdrSpace.id, after: false))
        try await TestSupport.eventually { workspace.spaces.first { $0.shows("herdr") }?.id == otherSpace.id }
        _ = try api(socket, "workspace.focus", ["workspace_id": spaceKey])
        try await TestSupport.eventually(diagnostic: "Selected \(workspace.current?.key ?? "nil"), expected \(spaceKey); error \(runtime.helpers[.local]?.error.map { String(describing: $0) } ?? "none")") { workspace.selectedSpace == herdrSpace.id }
        _ = try api(socket, "tab.create", ["workspace_id": spaceKey, "label": "CLI created", "focus": true])
        try await TestSupport.eventually { workspace.current?.windows.count == 3 && workspace.current?.activeWindow?.name == "CLI created" }
        XCTAssertTrue(workspace.moveContainer(secondContainer.id, beside: firstContainer.id, edge: nil))
        try await TestSupport.eventually { workspace.current?.windows.first?.id == secondContainer.id }
        workspace.selectWindow(firstContainer.id)
        try await TestSupport.eventually { runtime.views[firstTab.id]?.window != nil }
        XCTAssertTrue(TerminalTestSupport.screen(terminal: terminal).contains("HERDR_NATIVE"))
        XCTAssertFalse(TerminalTestSupport.screen(terminal: terminal).contains("CLI space"), "Herdr chrome must never enter pane frames")
        window.setContentSize(NSSize(width: 900, height: 600))
        try await Task.sleep(for: .milliseconds(300))
        TerminalTestSupport.send("printf 'RESIZED_%s\\n' OK", to: terminal)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: terminal).contains("RESIZED_OK") }

        _ = try api(socket, "pane.split", ["target_pane_id": firstPane, "direction": "right", "focus": true])
        try await TestSupport.eventually { workspace.current?.activeWindow?.terminals.count == 2 }
        XCTAssertEqual(workspace.current?.windows.count, 3, "Herdr panes remain inside their native tab")
        let splitSurface = try XCTUnwrap(workspace.current?.activeWindow?.terminals.first { $0.id != firstTab.id })
        try await TestSupport.eventually { runtime.views[splitSurface.id]?.surface != nil }
        let splitTerminal = runtime.views[splitSurface.id]!
        TerminalTestSupport.send("printf 'SPLIT_%s\\n' NATIVE", to: splitTerminal)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: splitTerminal).contains("SPLIT_NATIVE") }
        _ = try api(socket, "pane.focus", ["pane_id": firstPane])
        try await TestSupport.eventually { workspace.activeTab?.id == firstTab.id }
        let point = splitTerminal.convert(NSPoint(x: splitTerminal.bounds.midX, y: splitTerminal.bounds.midY), to: nil)
        let hit = window.contentView.flatMap { $0.hitTest($0.convert(point, from: nil)) }
        print("Herdr split click: point=\(point), frame=\(splitTerminal.frame), bounds=\(splitTerminal.bounds), window=\(splitTerminal.window === window), presented=\(splitTerminal.isPresented), hit=\(String(describing: hit)), expected=\(splitTerminal), selected=\(String(describing: workspace.activeTab?.id))")
        try PresentationTestSupport.click(window, at: point)
        try await TestSupport.eventually { workspace.activeTab?.id == splitSurface.id }
        try await TestSupport.eventually {
            let read = try self.api(socket, "pane.read", ["pane_id": firstPane, "source": "visible", "format": "text"])
            let text = (read["read"] as? [String: Any])?["text"] as? String ?? ""
            return self.normalized(text) == self.normalized(TerminalTestSupport.screen(terminal: terminal))
        }
        try await Task.sleep(for: .milliseconds(200))
        for tab in workspace.current?.tabs ?? [] {
            let view = runtime.views[tab.id]
            print("Herdr render: tab=\(tab.id), terminal=\(String(describing: tab.terminal)), presented=\(view?.isPresented == true), frame=\(String(describing: view?.frame)), screen=\(view.map { TerminalTestSupport.screen(terminal: $0) } ?? "missing")")
        }
        let image = try await PresentationTestSupport.capture(window, named: "herdr-native", in: "herdr-audit")
        XCTAssertTrue(try image.text().replacingOccurrences(of: " ", with: "").contains("SPLIT_NATIVE"), "The second pane must be rendered, not just present in the terminal model")

        controller.detachWindow(firstContainer.id)
        try await TestSupport.eventually { try self.focusedTab(socket) == workspace.activeWindowKey }
        XCTAssertFalse(workspace.allTabIDs.contains(firstTab.id))
        workspace.detachSpace(herdrSpace.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(workspace.spaces.contains { $0.id == herdrSpace.id })
        let after = try api(socket, "pane.process_info", ["pane_id": firstPane])
        XCTAssertEqual((after["process_info"] as? [String: Any])?["shell_pid"] as? Int, shellPID)
        let snapshot = try api(socket, "session.snapshot")
        XCTAssertTrue(String(data: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)!.contains("CLI space"))

        // Repeat through the real launch command from a single-tab local space.
        workspace.newLocalSpace()
        let single = workspace.selectedSpace!, singleTab = workspace.activeTab!.id
        try await TestSupport.eventually { runtime.views[singleTab]?.surface != nil }
        let next = runtime.views[singleTab]!
        try await TestSupport.eventually { !TerminalTestSupport.screen(terminal: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        TerminalTestSupport.send(launch, to: next)
        try await TestSupport.eventually(timeout: .seconds(10)) { !workspace.spaces.contains { $0.id == single } }
        XCTAssertEqual(workspace.current?.backend, server, "The same server attaches again")
        XCTAssertEqual(workspace.spaces.filter { $0.shows("herdr") }.count, 2)

        workspace.newLocalSpace()
        let namedSource = workspace.activeTab!.id
        try await TestSupport.eventually { runtime.views[namedSource]?.surface != nil }
        let namedTerminal = runtime.views[namedSource]!
        try await TestSupport.eventually { !TerminalTestSupport.screen(terminal: namedTerminal).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        TerminalTestSupport.send(launch + " --session other.session", to: namedTerminal)
        try await TestSupport.eventually(timeout: .seconds(10)) { workspace.current?.shows("herdr") == true && workspace.current?.backend != server }
        XCTAssertEqual(Set(workspace.spaces.filter { $0.shows("herdr") }.compactMap(\.backend)).count, 2)
        XCTAssertEqual(workspace.current?.key, spaceKey, "Servers can reuse workspace IDs")
        XCTAssertNotEqual(workspace.current?.id, herdrSpace.id)
        XCTAssertFalse(workspace.allTabIDs.contains(namedSource))
    }

    private func api(_ path: String, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        do {
            let result = try HerdrSocket(path: path).request(method, params: JSONSerialization.data(withJSONObject: params))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        } catch {
            print("Herdr API failed: socket=\(path), method=\(method), params=\(params), error=\(error)")
            throw error
        }
    }
    private func focusedTab(_ socket: String) throws -> String? {
        (try api(socket, "session.snapshot")["snapshot"] as? [String: Any])?["focused_tab_id"] as? String
    }
    private func focusedWorkspace(_ socket: String) throws -> String? {
        (try api(socket, "session.snapshot")["snapshot"] as? [String: Any])?["focused_workspace_id"] as? String
    }
    private func normalized(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
