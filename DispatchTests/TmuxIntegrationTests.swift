import AppKit
import SwiftUI
import Term
import XCTest
@testable import DispatchApp

@MainActor
final class TmuxIntegrationTests: XCTestCase {
    func testControlDataBatchesRespectNegotiatedWireLimit() async throws {
        struct Params: Codable, Equatable { let terminal: UInt64; let event: String; var bytes: Data }
        struct Request: Codable, Equatable { let method: String; var params: Params }
        let data = Data(UInt8.min...UInt8.max)
        let expected = Request(method: "terminals.control", params: Params(terminal: UInt64.max, event: "data", bytes: data))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))
        let limit = UInt32(try HelperBinary.encode(HelperBinary.value(object)).count / 2)
        let incoming = Pipe(), outgoing = Pipe()
        let connection = HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        let peer = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        defer { connection.close(); peer.close() }
        var decoder = HelperWire.Decoder(), requests: [Request] = [], ids: [UInt64] = []
        peer.start(receive: { bytes in
            do {
                try decoder.feed(bytes) { frame in
                    XCTAssertLessThanOrEqual(frame.body.count, Int(limit))
                    requests.append(try HelperClientTests.decode(Request.self, frame.body))
                    ids.append(frame.id)
                    let body = try HelperBinary.encode(HelperBinary.value(["result": NSNull()]))
                    peer.send(try HelperWire.encode(.init(kind: .response, id: frame.id, body: body)))
                }
            } catch { XCTFail(String(describing: error)) }
        }, closed: { _ in })
        try await connection.configure(limit: limit)
        _ = try await HelperClient(connection).control(.init(terminal: expected.params.terminal, event: .data, bytes: data))
        XCTAssertGreaterThan(requests.count, 1)
        XCTAssertEqual(ids, Array(1...UInt64(requests.count)))
        XCTAssertEqual(requests.map { Request(method: $0.method, params: Params(terminal: $0.params.terminal, event: $0.params.event, bytes: Data())) },
                       Array(repeating: Request(method: expected.method, params: Params(terminal: expected.params.terminal, event: expected.params.event, bytes: Data())), count: requests.count))
        XCTAssertEqual(requests.reduce(into: Data()) { $0.append($1.params.bytes) }, expected.params.bytes)
    }

    func testLargeHistoryReplyAcrossTransportChunks() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tmux-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let rows = (0..<30_000).map { "history \($0) " + String(repeating: "x", count: 100) }
        let width = try XCTUnwrap(Int(try app.server(["display-message", "-p", "-t", "edge:0", "#{pane_width}"]).trimmingCharacters(in: .whitespacesAndNewlines)))
        let count = rows.reduce(0) { $0 + ($1.count + width - 1) / width }
        _ = try app.server(["set-option", "-g", "history-limit", String(count + 35)])
        _ = try app.server(["new-window", "-n", "history", "/bin/sh"])
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: path)
        _ = try app.server(["send-keys", "-t", "edge:history", "cat " + HerdrLaunch.quote(path.path) + "; printf 'HISTORY_%s\\n' READY", "Enter"])
        try await TestSupport.eventually {
            try app.server(["capture-pane", "-p", "-t", "edge:history"]).contains("HISTORY_READY")
        }
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab), terminal = try XCTUnwrap(tab.terminal)
        let backend = try XCTUnwrap(app.workspace.helper(containing: tab.id)), client = try await backend.client()
        let output = AsyncThrowingStream<Data, Error>.makeStream()
        let observation = try await client.attach(.init(terminal: terminal, size: .init(columns: 100, rows: 35), takeover: true)) { update in
            switch update {
            case .success(.output(let bytes)): output.continuation.yield(bytes.bytes)
            case .failure(let error): output.continuation.finish(throwing: error)
            default: break
            }
        }
        defer { client.connection.cancel(observation); output.continuation.finish() }
        let bytes = try await SSHTimeout.run(.seconds(15)) {
            var result = Data()
            for try await chunk in output.stream {
                result += chunk
                if String(decoding: result, as: UTF8.self).contains("HISTORY_READY") { return result }
            }
            return result
        }
        // Read the common transport's full capture; renderer retention is a separate contract.
        let text = String(decoding: bytes, as: UTF8.self)
        let escapes = try NSRegularExpression(pattern: "\\x1b\\[[0-?]*[ -/]*[@-~]")
        let plain = escapes.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let joined = plain.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let pattern = try NSRegularExpression(pattern: "history [0-9]+ x{100}")
        let actual = pattern.matches(in: joined, range: NSRange(joined.startIndex..., in: joined))
            .compactMap { Range($0.range, in: joined).map { String(joined[$0]) } }
        XCTAssertEqual(actual, rows)
        XCTAssertNil(app.error)
    }

    func testRealServerHistoryLiveOutputLayoutAndDetach() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["send-keys", "-t", "edge:0", "printf 'BEFORE_%s\\n' CAPTURE; i=1; for i in $(seq 1 60); do printf 'row %s\\n' \"$i\"; done; printf 'CAPTURE_%s\\n' READY", "Enter"])
        try await TestSupport.eventually { try app.server(["capture-pane", "-p", "-t", "edge:0"]).contains("CAPTURE_READY") }
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab), view = try XCTUnwrap(app.runtime.views[tab.id])
        try await app.wait { view.surface?.readText(.history).contains("BEFORE_CAPTURE") == true }
        TerminalTestSupport.send("printf 'AFTER_%s\\n' CAPTURE", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("AFTER_CAPTURE") }
        let surface = try XCTUnwrap(view.surface)
        XCTAssertEqual((surface.readText(.history) + surface.readText(.active)).components(separatedBy: "BEFORE_CAPTURE").count - 1, 1)
        _ = try app.server(["split-window", "-h", "-t", "edge:0", "/bin/sh"])
        try await app.wait { app.workspace.current?.activeWindow?.terminals.count == 2 }
        _ = try app.server(["rename-window", "-t", "edge:0", "native space"])
        _ = try app.server(["new-window", "-d", "-n", "second", "/bin/sh"])
        try await app.wait { Set(app.workspace.current?.containers.map(\.name) ?? []) == Set(["native space", "second"]) }
        app.detachSession()
        try await app.wait { !app.attached }
        XCTAssertEqual(Set(try app.server(["list-windows", "-t", "edge", "-F", "#{window_name}"]).split(separator: "\n").map(String.init)), Set(["native space", "second"]))
        XCTAssertNil(app.error)
    }

    func testRenamingWindowAndPanePreservesLiteralCharacters() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab), window = try XCTUnwrap(app.workspace.current?.activeWindow)
        let pane = try XCTUnwrap(app.target(tab))
        let title = "Build #{pane_id} ## $ ' quoted"
        app.workspace.renameWindow(window.id, to: title)
        app.workspace.updateTab(tab.id, customTitle: title)
        try await TestSupport.eventually {
            try app.server(["display-message", "-p", "-t", pane, "#{window_name}|#{pane_title}"])
                .trimmingCharacters(in: .whitespacesAndNewlines) == title + "|" + title
        }
        try await app.wait { app.workspace.current?.activeWindow?.name == title && app.workspace.activeTab?.title == title }
    }

    // Old TmuxProtocolTests/TmuxSessionTests rules, now on the helper route with a real server.

    /// Native names reach the sidebar; executable suffix normalization is covered in the helper
    /// unit test because tmux 3.7 rejects dots in newly created window names.
    func testWindowLabelsMatchNativeNames() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let names = ["claude": "claude", "zsh": "zsh", "my setup": "my setup"]
        for name in names.keys { _ = try app.server(["new-window", "-d", "-n", name, "/bin/sh"]) }
        try await app.attach(); try await app.ready()
        try await app.wait { Set(app.workspace.current?.containers.map(\.name) ?? []).isSuperset(of: Set(names.values)) }
    }

    /// A window split on both axes into several panes shows every server pane.
    func testMixedAxesLayoutShowsEveryPane() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["split-window", "-h", "-t", "edge:0", "/bin/sh"])
        _ = try app.server(["split-window", "-v", "-t", "edge:0.1", "/bin/sh"])
        _ = try app.server(["split-window", "-h", "-t", "edge:0.2", "/bin/sh"])
        let panes = Set(try app.server(["list-panes", "-t", "edge:0", "-F", "#{pane_id}"]).split(separator: "\n").map(String.init))
        XCTAssertEqual(panes.count, 4)
        try await app.attach(); try await app.ready()
        try await app.wait { Set(app.visiblePanes) == panes }
    }

    /// Closing the session's last window ends the session; that is not an error.
    func testClosingTheLastWindowEndsTheSessionWithoutAnError() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attach(); try await app.ready()
        _ = try? app.server(["kill-window", "-t", "edge:0"])
        try await app.wait { !app.attached }
        XCTAssertNil(app.error, "A session that ended is not an error")
    }

    /// A space name with separators, quotes and non-ASCII text survives detach and reattach.
    func testSpaceNameWithSpecialCharactersSurvivesReattach() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attach(); try await app.ready()
        let name = "Research | \"quotes\" $ \\ 雪"
        app.workspace.renameSpace(try XCTUnwrap(app.workspace.current?.id), to: name)
        try await app.wait { app.workspace.current?.name == name }
        app.detachSession()
        try await app.wait { !app.attached }
        try await app.attach(); try await app.ready()
        try await app.wait { app.workspace.current?.name == name }
    }

    func testProgramCopyReachesPasteboardByteForByte() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attach(); try await app.ready()
        // Claude Code copies with `tmux load-buffer -w`; tmux never forwards that clipboard
        // sequence to a control client, only %paste-buffer-changed. show-buffer then prints
        // the bytes raw inside its reply, so text resembling control lines must survive.
        let copied = "copy \(UUID().uuidString)\n%end 1 2 1\n\tlast line\n"
        _ = try app.server(["set-buffer", "-b", "claude copy", copied])
        try await app.wait { NSPasteboard.general.string(forType: .string) == copied }
    }

    func testDisconnectDropsUnconfirmedTmuxNames() async throws {
        try await disconnectedRename(alreadyOffline: false)
    }

    func testOfflineRenameDoesNotReplaceConfirmedTmuxNames() async throws {
        try await disconnectedRename(alreadyOffline: true)
    }

    /// Real faults rather than hooks into the client: the server is stalled so renames never get an answer, and the SSH
    /// connection is dropped; names fall back to what the server confirmed.
    private func disconnectedRename(alreadyOffline: Bool) async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attachOverSSH(); try await app.ready()
        let original = try XCTUnwrap(app.workspace.activeTab), window = try XCTUnwrap(app.workspace.current?.activeWindow)
        try app.stall()
        let renameMenu = NSMenuItem(title: "Rename Tab", action: #selector(AppDelegate.renameTab), keyEquivalent: "")
        XCTAssertTrue(app.controller.validateMenuItem(renameMenu))
        if alreadyOffline {
            try app.disconnect()
            try await app.wait { !app.controller.validateMenuItem(renameMenu) }
        }
        app.workspace.renameWindow(window.id, to: "Never reached server")
        app.workspace.updateTab(original.id, customTitle: "Never reached pane")
        if !alreadyOffline { try app.disconnect() }
        try await app.wait { !app.controller.validateMenuItem(renameMenu) }
        XCTAssertEqual(app.workspace.current?.activeWindow?.name, window.name)
        XCTAssertEqual(app.workspace.activeTab?.title, original.title)
    }

    func testNewTabAndSpaceWhileDisconnectedDoNotCreateUnrecoverablePlaceholders() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attachOverSSH(); try await app.ready()
        let original = try XCTUnwrap(app.workspace.activeTab)
        let spaces = app.workspace.spaces.map(\.id), surfaces = app.workspace.allSurfaceIDs
        try app.stall(); try app.disconnect()
        let renameMenu = NSMenuItem(title: "Rename Tab", action: #selector(AppDelegate.renameTab), keyEquivalent: "")
        try await app.wait { !app.controller.validateMenuItem(renameMenu) }
        app.workspace.newTab()
        app.workspace.newSpace()
        XCTAssertEqual(app.workspace.spaces.map(\.id), spaces)
        XCTAssertEqual(app.workspace.allSurfaceIDs, surfaces)
        XCTAssertEqual(app.workspace.activeTab?.id, original.id)
        XCTAssertFalse(app.workspace.spaces.flatMap(\.tabs).contains { $0.isConnecting })
    }

    func testDisconnectDuringPendingCreationRemovesUnconfirmedPane() async throws {
        try await disconnectedCreation(newSpace: false, detach: false)
    }

    func testDisconnectDuringPendingSpaceCreationRemovesUnconfirmedPane() async throws {
        try await disconnectedCreation(newSpace: true, detach: false)
    }

    func testDisconnectDuringDetachedPendingCreationRemovesUnconfirmedPane() async throws {
        try await disconnectedCreation(newSpace: false, detach: true)
    }

    private func disconnectedCreation(newSpace: Bool, detach: Bool) async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attachOverSSH(); try await app.ready()
        let original = try XCTUnwrap(app.workspace.activeTab)
        // The stalled server never answers the creation; then the connection drops.
        try app.stall()
        if newSpace { app.workspace.newSpace() } else { app.workspace.newTab() }
        let pending = try XCTUnwrap(app.workspace.activeTab)
        XCTAssertTrue(pending.isConnecting)
        if detach { app.controller.closeWindow(try XCTUnwrap(app.workspace.current?.activeWindow).id) }
        try app.disconnect()
        try await app.wait { !app.workspace.allSurfaceIDs.contains(pending.id) }
        XCTAssertFalse(app.workspace.allSurfaceIDs.contains(pending.id),
                       "A cancelled creation must not become a retained pane that recovery requires on the server")
        XCTAssertTrue(app.workspace.allSurfaceIDs.contains(original.id))
        XCTAssertFalse(app.workspace.spaces.flatMap(\.tabs).contains { $0.isConnecting })
        XCTAssertTrue(app.workspace.detached.isEmpty)
        XCTAssertEqual(app.workspace.spaces.flatMap(\.windows).count, 1)
    }

    func testFailedPendingCreationRemovesVisiblePlaceholder() async throws {
        try await rejectedCreation(detach: false)
    }

    func testFailedPendingCreationRemovesDetachedPlaceholder() async throws {
        try await rejectedCreation(detach: true)
    }

    private func rejectedCreation(detach: Bool) async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["new-window", "-d", "-n", "kept", "/bin/sh"])
        try await app.attach(); try await app.ready()
        // A real rejection: the window the creation targets is gone on the server before the app knows
        // (read-only clients do not make tmux reject a control client's commands).
        let target = try app.server(["display-message", "-p", "-t", "edge:0", "#{window_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try app.server(["kill-window", "-t", target])
        app.workspace.newTab()
        let pending = try XCTUnwrap(app.workspace.current?.activeWindow)
        XCTAssertTrue(app.workspace.activeTab?.isConnecting == true)
        if detach { app.controller.closeWindow(pending.id) }
        try await app.wait { (app.runtime.helpers[.local]?.error) != nil }
        try await TestSupport.eventually(diagnostic: "windows=\(app.workspace.current?.windows.map(\.name) ?? []), detached=\(app.workspace.detached.map(\.name))") {
            app.workspace.current?.windows.map(\.name) == ["kept"] && app.workspace.detached.isEmpty
        }
        XCTAssertEqual(try app.server(["list-windows", "-t", "edge"]).split(separator: "\n").count, 1, "The rejected creation made no window")
    }

    func testOptimisticCreationRenameCloseAndDividerReconciliation() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        try await app.attach(); try await app.ready()
        let workspace = app.workspace
        let original = try XCTUnwrap(workspace.current)
        // A real fault: a stalled server holds every command until it resumes.
        func tmux(_ arguments: [String]) throws -> String { try app.server(arguments).trimmingCharacters(in: .whitespacesAndNewlines) }
        try app.stall()
        workspace.newSpace()
        let placeholder = try XCTUnwrap(workspace.current), placeholderTab = try XCTUnwrap(workspace.activeTab)
        XCTAssertNotEqual(placeholder.id, original.id)
        XCTAssertTrue(placeholderTab.isConnecting)
        XCTAssertNil(app.runtime.views[placeholderTab.id], "A placeholder must not start a local shell or terminal adapter")
        app.resume()
        try await app.wait { workspace.spaces.contains { $0.id == placeholder.id && $0.activeTab?.isConnecting == false } }
        XCTAssertEqual(workspace.current?.id, placeholder.id)
        XCTAssertEqual(workspace.activeTab?.id, placeholderTab.id)
        try await app.ready()
        let window = try XCTUnwrap(workspace.current?.activeWindow), target = try XCTUnwrap(app.target(window))
        try app.stall()
        workspace.renameWindow(window.id, to: "First rename")
        workspace.renameWindow(window.id, to: "Latest rename")
        XCTAssertEqual(workspace.current?.activeWindow?.name, "Latest rename")
        workspace.renameSpace(placeholder.id, to: "My space")
        XCTAssertEqual(workspace.current?.name, "My space")
        app.resume()
        try await TestSupport.eventually { try tmux(["display-message", "-p", "-t", target, "#{window_name}"]) == "Latest rename" }
        XCTAssertEqual(workspace.current?.name, "My space")
        _ = try app.server(["split-window", "-h", "-t", target, "/bin/sh"])
        try await app.wait { workspace.current?.panes.count == 2 }
        guard case .split(let split, _, _, _) = workspace.current?.layout else { return XCTFail("Expected split") }
        workspace.resizeDivider(split, in: placeholder.id, fraction: 0.6)
        workspace.resizeDivider(split, in: placeholder.id, fraction: 0.7)
        XCTAssertEqual(workspace.current?.splitFractions[split], 0.7)
        try await TestSupport.eventually {
            let widths = try tmux(["list-panes", "-t", target, "-F", "#{pane_left} #{pane_width} #{window_width}"])
                .split(separator: "\n").map { $0.split(separator: " ").compactMap { Double($0) } }
            guard let left = widths.first(where: { $0.first == 0 }), left.count == 3 else { return false }
            return abs(left[1] / (left[2] - 1) - 0.7) < 0.04
        }
        let pane = try XCTUnwrap(workspace.current?.panes.last?.activeTab), paneTarget = try XCTUnwrap(app.target(pane))
        try app.stall()
        app.controller.closeTab(pane.id)
        XCTAssertEqual(workspace.current?.panes.count, 1)
        app.resume()
        try await TestSupport.eventually { !(try tmux(["list-panes", "-t", target, "-F", "#{pane_id}"]).contains(paneTarget)) }
        try app.stall()
        app.controller.closeWindow(window.id)
        XCTAssertFalse(workspace.spaces.contains { $0.id == placeholder.id })
        app.resume()
        try await TestSupport.eventually { !(try tmux(["list-windows", "-a", "-F", "#{window_id}"]).split(separator: "\n").contains(Substring(target))) }
        XCTAssertNotNil(workspace.spaces.first { $0.id == original.id })
    }

    func testHerdrAndTmuxCoexistWithoutSharingLayoutsOrInput() async throws {
        guard FileManager.default.isExecutableFile(atPath: TestSupport.tool("herdr")) else { throw XCTSkip("Requires herdr") }
        let app = try TmuxWalkthrough()
        defer { app.close() }
        try await app.attach(); try await app.ready()
        let workspace = app.workspace, runtime = app.runtime
        let tmuxTab = try XCTUnwrap(workspace.activeTab), tmuxSpace = try XCTUnwrap(workspace.current)
        let tmuxTerminal = try XCTUnwrap(runtime.views[tmuxTab.id]), tmuxSurface = tmuxTerminal.surface
        let root = URL(fileURLWithPath: "/tmp/hm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let socket = root.appendingPathComponent("herdr.sock").path
        defer {
            _ = try? HerdrSocket(path: socket).request("server.stop")
            try? FileManager.default.removeItem(at: root)
        }
        workspace.newLocalSpace()
        let localID = workspace.activeTab!.id
        try await TestSupport.eventually { runtime.views[localID]?.surface != nil }
        TerminalTestSupport.send("export PATH=\(TestSupport.path):/usr/bin:/bin:$PATH; export XDG_CONFIG_HOME=\(HerdrLaunch.quote(root.path)); export XDG_STATE_HOME=\(HerdrLaunch.quote(root.path)); export HERDR_SOCKET_PATH=\(HerdrLaunch.quote(socket)); herdr", to: runtime.views[localID]!)
        try await TestSupport.eventually(timeout: .seconds(15)) { workspace.current?.structured == true && workspace.current?.id != tmuxSpace.id }
        let herdrSpaceID = workspace.current!.id, herdrTab = workspace.activeTab!, herdrID = herdrTab.focusedSurfaceID
        workspace.newTab()
        try await TestSupport.eventually { workspace.current?.tabs.count == 2 && workspace.activeTab?.isConnecting == false }
        XCTAssertTrue(workspace.applyLayout(.rows))
        let herdrLayout = workspace.current!.layout
        workspace.selectTab(herdrTab.id)
        try await TestSupport.eventually { runtime.views[herdrID]?.surface != nil }
        let herdrTerminal = runtime.views[herdrID]!, herdrSurface = herdrTerminal.surface
        TerminalTestSupport.send("printf 'HERDR_COEXIST_%s\\n' READY", to: herdrTerminal)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: herdrTerminal).contains("HERDR_COEXIST_READY") }
        workspace.selectTab(tmuxTab.id)
        try await app.ready()
        workspace.newTab()
        try await app.wait { workspace.current?.windows.count == 2 && workspace.activeTab?.isConnecting == false }
        XCTAssertEqual(workspace.spaces.first { $0.id == herdrSpaceID }?.layout, herdrLayout)
        workspace.selectTab(tmuxTab.id)
        try await app.ready()
        TerminalTestSupport.send("printf 'TMUX_COEXIST_%s\\n' READY", to: tmuxTerminal)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: tmuxTerminal).contains("TMUX_COEXIST_READY") }
        XCTAssertFalse(TerminalTestSupport.screen(terminal: herdrTerminal).contains("TMUX_COEXIST_READY"))
        XCTAssertTrue(tmuxTerminal.surface === tmuxSurface)
        workspace.selectTab(herdrTab.id)
        try await TestSupport.eventually { herdrTerminal.window === app.window }
        XCTAssertTrue(herdrTerminal.surface === herdrSurface)
        workspace.detachSpace(tmuxSpace.id)
        try await app.wait { !workspace.spaces.contains { $0.id == tmuxSpace.id } }
        XCTAssertEqual(workspace.selectedSpace, herdrSpaceID)
        XCTAssertFalse(workspace.spaces.contains { $0.id == tmuxSpace.id })
        XCTAssertEqual(workspace.current?.layout, herdrLayout)
        TerminalTestSupport.send("printf 'HERDR_AFTER_DETACH_%s\\n' READY", to: herdrTerminal)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: herdrTerminal).contains("HERDR_AFTER_DETACH_READY") }
        XCTAssertNil(runtime.helpers[.local]?.error)
    }

    func testControlModeCreatesNativePanesAndReconnectsToSurvivingShells() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let tmux = TestSupport.tool("tmux")
        guard FileManager.default.isExecutableFile(atPath: tmux) else { throw XCTSkip("Requires tmux") }
        let socket = "dispatch-native-test-\(UUID().uuidString)"
        func server(_ arguments: [String]) throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = ["-L", socket] + arguments
            process.standardOutput = output; process.standardError = Pipe()
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "TMUX")
            process.environment = environment
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
            return String(decoding: data, as: UTF8.self)
        }
        _ = try server(["-f", "/dev/null", "new-session", "-d", "-s", "native", "-x", "100", "-y", "35", "/bin/sh"])
        defer { _ = try? server(["kill-server"]) }
        _ = try server(["send-keys", "-t", "%0", "printf 'SAVED_%s\\n' HISTORY; seq 1 100", "Enter"])

        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let workspace = controller.workspace
        runtime.workspace = workspace
        var preferences = Preferences(); preferences.closeLaunching = ["tmux": false, "herdr": false]
        runtime.start(preferences: preferences)
        XCTAssertNil(runtime.error)
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newSpace()
        let originID = try XCTUnwrap(workspace.activeTab?.id)
        // tmux's own ids for what the app shows (helper node keys end in them) and its current sizes.
        func target(_ tab: TerminalTab) -> String? { workspace.key(of: tab)?.split(separator: ":").last.map(String.init) }
        func windowTarget(_ window: Space.Window) -> String? {
            workspace.spaces.flatMap(\.containers).first { $0.id == window.id }
                .flatMap { runtime.helpers[.local]?.node($0.node)?.key }.flatMap { $0.split(separator: ":").last.map(String.init) }
        }
        func size(_ target: String, _ format: String) throws -> [Int] {
            try server(["display-message", "-p", "-t", target, format]).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        }
        func detachSession() { for space in workspace.spaces where space.structured { workspace.detachSpace(space.id) } }
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        controller.window = window
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil; runtime.stop() }
        try await eventually { runtime.views[originID]?.surface != nil }
        let origin = try XCTUnwrap(runtime.views[originID])
        try await eventually { !TerminalTestSupport.screen(terminal: origin).isEmpty }
        TerminalTestSupport.send("\(tmux) -u -L \(socket) -CC attach -t native", to: origin)
        try await eventually { workspace.current?.structured == true }
        let firstID = try XCTUnwrap(workspace.activeTab?.id)
        try await eventually { workspace.activeTab.flatMap(target) == "%0" && runtime.views[firstID]?.surface != nil }
        let first = try XCTUnwrap(runtime.views[firstID])
        try await eventually { self.history(first).contains("SAVED_HISTORY") }
        XCTAssertFalse(TerminalTestSupport.screen(terminal: first).contains("%begin"))
        XCTAssertEqual(runtime.helpers[.local]?.error, nil)
        TerminalTestSupport.send("printf 'NATIVE_%s\\n' INPUT", to: first)
        try await eventually { TerminalTestSupport.screen(terminal: first).contains("NATIVE_INPUT") }
        let firstSurface = first.surface
        _ = try server(["split-window", "-h", "-t", "%0", "/bin/sh"])
        try await eventually { workspace.current?.panes.count == 2 }
        try await eventually { workspace.current?.tabs.allSatisfy { runtime.views[$0.id]?.surface != nil } == true }
        XCTAssertTrue(first.surface === firstSurface, "Native layout changes retain the pane renderer")
        let panes = workspace.current!.panes
        XCTAssertEqual(panes.compactMap { $0.activeTab.flatMap(target) }.sorted(), ["%0", "%1"])
        _ = try server(["send-keys", "-t", "%1", "printf 'SECOND_%s\\n' PANE", "Enter"])
        let secondTab = try XCTUnwrap(panes.flatMap(\.tabs).first { target($0) == "%1" })
        try await eventually { runtime.views[secondTab.id].map { TerminalTestSupport.screen(terminal: $0).contains("SECOND_PANE") } == true }
        // The server's own prefix table: ⌃B → runs its select-pane -R, and native focus follows.
        workspace.selectSurface(firstID)
        try await eventually { workspace.activeSurfaceID == firstID && window.makeFirstResponder(first) }
        first.keyDown(with: TerminalTestSupport.keyEvent(11, "\u{02}", in: window, modifiers: .control, ignoringModifiers: "b"))
        first.keyDown(with: TerminalTestSupport.keyEvent(124, "\u{F703}", in: window))
        try await eventually { workspace.activeSurfaceID == secondTab.id }
        workspace.selectSurface(firstID)
        try await eventually { workspace.activeSurfaceID == firstID }
        let split = try XCTUnwrap(PresentationTestSupport.views(of: TerminalSplitView.self, in: window.contentView!, includingNestedMatches: true).first { !$0.sidebar })
        split.setPosition(split.bounds.width * 0.35, ofDividerAt: 0)
        split.userDidResize()
        try await eventually {
            guard let sizes = try? size("%0", "#{pane_width} #{window_width}"), sizes.count == 2 else { return false }
            return Double(sizes[0]) / Double(sizes[1]) < 0.45
        }
        // Splitting adds another pane's padding, so the available window grid
        // changes. Let that size reach tmux before testing an external resize.
        try await TestSupport.eventually {
            guard let left = runtime.views[firstID], let right = runtime.views[secondTab.id],
                  let surface = left.surface else { return false }
            let cell = Double(surface.grid.cellWidth)
            guard cell > 0 else { return false }
            let pixels = left.convertToBacking(left.bounds).width + right.convertToBacking(right.bounds).width
            let available = Int((pixels - 40 * window.backingScaleFactor) / cell + 1)
            return (try? size("@0", "#{window_width}")) == [available]
        }
        _ = try server(["resize-pane", "-t", "%0", "-x", "30"])
        try await eventually { (try? size("%0", "#{pane_width}")) == [30] }
        try await eventually { first.surface.map { $0.grid.columns == 30 } == true }
        XCTAssertTrue(first.surface === firstSurface)
        XCTAssertTrue(workspace.applyLayout(.single))
        XCTAssertFalse(workspace.applyLayout(.columns), "An existing server split is one native tab")
        try await eventually { workspace.current?.layout.paneIDs.count == 2 }
        try await Task.sleep(for: .milliseconds(250))
        _ = try await PresentationTestSupport.capture(window, named: "tmux-native-split")

        workspace.newSpace()
        try await eventually { workspace.spaces.filter { $0.structured }.count == 2 }
        try await eventually { workspace.current?.activeWindow.flatMap(windowTarget) != "@0" && workspace.activeTab?.isConnecting == false }
        let auxiliary = try XCTUnwrap(workspace.current)
        workspace.renameSpace(auxiliary.id, to: "Auxiliary")
        try await eventually { workspace.current?.name == "Auxiliary" }
        workspace.closeSpace(auxiliary.id)
        try await eventually { workspace.spaces.filter { $0.structured }.count == 1 }
        workspace.newSpace()
        try await eventually { workspace.spaces.filter { $0.structured }.count == 2 }
        detachSession()
        try await eventually { !workspace.spaces.contains { $0.structured } && runtime.helpers.values.allSatisfy { $0.operations == 0 && !$0.controls(originID) } }
        XCTAssertEqual(workspace.activeTab?.id, originID)
        XCTAssertEqual(try server(["list-panes", "-a", "-F", "#{pane_id}"]).split(separator: "\n").count, 3)
        TerminalTestSupport.send("\(tmux) -u -L \(socket) -CC attach -t native", to: origin)
        try await eventually { workspace.spaces.filter { $0.structured }.count == 2 }
        let restoredSpace = try XCTUnwrap(workspace.spaces.first { $0.windows.contains { windowTarget($0) == "@0" } })
        workspace.selectSpace(restoredSpace.id)
        let restored = try XCTUnwrap(restoredSpace.tabs.first { target($0) == "%0" })
        try await eventually { runtime.views[restored.id].map { self.history($0).contains("NATIVE_INPUT") } == true }
        XCTAssertNil(runtime.helpers[.local]?.error)

        // A full-screen application keeps running while the client detaches.
        // Both its alternate screen and the saved primary history must return.
        let terminal = try XCTUnwrap(runtime.views[restored.id])
        TerminalTestSupport.send("for i in {1..200}; do printf 'TMUX_SCROLL_%03d\\n' $i; done", to: terminal)
        try await eventually { TerminalTestSupport.screen(terminal: terminal).contains("TMUX_SCROLL_200") }
        try await TerminalTestSupport.assertScrollbar(in: terminal, bottomMarker: "TMUX_SCROLL_200")
        let wrapped = "WRAPPED_" + String(repeating: "abcdef", count: 80) + "_END"
        TerminalTestSupport.send("printf '%s\\n' '\(wrapped)'", to: terminal)
        try await eventually { self.history(terminal).contains(wrapped) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tmux-vt.py").path
        TerminalTestSupport.send("/usr/bin/python3 '\(fixture)'", to: terminal)
        try await eventually { TerminalTestSupport.screen(terminal: terminal).contains("ALT_READY") }
        try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration))
        let mouseMetrics = terminal.surface!.grid
        let mousePoint = terminal.convert(NSPoint(x: 10 + Double(mouseMetrics.cellWidth) / window.backingScaleFactor * 11.5,
            y: terminal.bounds.height - 8 - Double(mouseMetrics.cellHeight) / window.backingScaleFactor * 4.5), to: nil)
        try PresentationTestSupport.click(window, at: mousePoint)
        try await TestSupport.eventually(diagnostic: "Mouse report missing: \(TerminalTestSupport.screen(terminal: terminal))") {
            TerminalTestSupport.screen(terminal: terminal).contains("MOUSE_OK_12_5")
        }
        TerminalTestSupport.key(2, "d", terminal)
        try await eventually { TerminalTestSupport.screen(terminal: terminal).contains("QUERY_REPLIES_1") }
        terminal.surface!.text("hello\nworld")
        try await eventually { TerminalTestSupport.screen(terminal: terminal).contains("PASTE_OK_1") }
        XCTAssertEqual(try server(["display-message", "-p", "-t", "%0", "#{alternate_on}|#{bracket_paste_flag}"]).trimmingCharacters(in: .whitespacesAndNewlines), "1|1")
        TerminalTestSupport.key(14, "e", terminal)
        try await TestSupport.eventually { try server(["capture-pane", "-p", "-P", "-C", "-t", "%0"]).contains("PENDING") }
        detachSession()
        try await eventually { !workspace.spaces.contains { $0.structured } && runtime.helpers.values.allSatisfy { $0.operations == 0 && !$0.controls(originID) } }
        TerminalTestSupport.send("\(tmux) -u -L \(socket) -CC attach -t native", to: origin)
        try await eventually { workspace.spaces.contains { $0.windows.contains { windowTarget($0) == "@0" } } }
        let alternateSpace = try XCTUnwrap(workspace.spaces.first { $0.windows.contains { windowTarget($0) == "@0" } })
        workspace.selectSpace(alternateSpace.id)
        let alternateTab = try XCTUnwrap(alternateSpace.tabs.first { target($0) == "%0" })
        try await eventually { runtime.views[alternateTab.id].map { TerminalTestSupport.screen(terminal: $0).contains("ALT_READY") } == true }
        let alternate = try XCTUnwrap(runtime.views[alternateTab.id])
        TerminalTestSupport.key(3, "f", alternate)
        try await eventually { workspace.spaces.flatMap(\.tabs).first { $0.id == alternateTab.id }?.title == "PENDING_TITLE" }
        alternate.surface!.text("hello\nworld")
        try await eventually { TerminalTestSupport.screen(terminal: alternate).contains("PASTE_OK_2") }
        TerminalTestSupport.key(12, "q", alternate)
        try await eventually { self.history(alternate).contains(wrapped) && !TerminalTestSupport.screen(terminal: alternate).contains("ALT_READY") }
        alternate.performBindingAction("select_all")
        let surface = try XCTUnwrap(alternate.surface)
        let selected = try XCTUnwrap(surface.readSelection())
        XCTAssertTrue(selected.contains(wrapped), "Native selection preserves soft-wrapped history after reconnect")

        // A second control client constrains tmux's size without changing our
        // font size or causing native/server resize commands to oscillate.
        _ = try server(["set-option", "-w", "-t", "@0", "window-size", "smallest"])
        let other = Process(), otherInput = Pipe()
        other.executableURL = URL(fileURLWithPath: tmux)
        other.arguments = ["-u", "-L", socket, "-C", "attach", "-t", "native"]
        other.standardInput = otherInput
        other.standardOutput = FileHandle.nullDevice; other.standardError = FileHandle.nullDevice
        try other.run()
        defer { if other.isRunning { other.terminate() } }
        try otherInput.fileHandleForWriting.write(contentsOf: Data("refresh-client -C 60,18\n".utf8))
        try await eventually {
            let value: [Int] = (try? size("@0", "#{window_width} #{window_height}")) ?? []
            return value.count == 2 && value[0] <= 60 && value[1] <= 18
        }
        let cellWidth = surface.grid.cellWidth
        try await eventually { alternate.subviews.first.map { $0.frame.width < alternate.bounds.width } == true }
        XCTAssertEqual(surface.grid.cellWidth, cellWidth)
        try otherInput.fileHandleForWriting.close()
        try await eventually { !other.isRunning }
        _ = try server(["set-option", "-w", "-t", "@0", "window-size", "latest"])
        try await eventually { ((try? size("@0", "#{window_width}"))?.first ?? 0) > 60 }

        // External mutations can create more than the local workspace's four
        // panes. Keep every tmux pane and reconcile their stable native views.
        var temporaryPanes: [String] = []
        for _ in 0..<3 {
            temporaryPanes.append(try server(["split-window", "-d", "-h", "-t", "%0", "-P", "-F", "#{pane_id}", "/bin/sh"]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try await eventually { workspace.current?.panes.count == 5 }
        XCTAssertFalse(workspace.applyLayout(.grid), "Server panes do not count as spare window tabs")
        try await eventually { workspace.current?.tabs.allSatisfy { runtime.views[$0.id]?.surface != nil } == true }
        for pane in temporaryPanes { _ = try server(["kill-pane", "-t", pane]) }
        try await eventually { workspace.current?.panes.count == 2 }
        XCTAssertTrue(alternate.surface === surface)

        let stress = "/usr/bin/python3 -u -c 'import time; [(print(\"STRESS_%04d\" % i), time.sleep(.01)) for i in range(100)]'"
        TerminalTestSupport.send(stress, to: alternate)
        for step in 0..<8 {
            window.setContentSize(NSSize(width: step % 2 == 0 ? 1000 : 1160, height: step % 2 == 0 ? 680 : 760))
            try await Task.sleep(for: .milliseconds(150))
        }
        try await TestSupport.eventually(timeout: .seconds(8), diagnostic: "Native: \(self.history(alternate).suffix(2000)); Server: \((try? server(["capture-pane", "-p", "-t", "%0"])) ?? "unavailable")") { self.history(alternate).contains("STRESS_0099") }
        let history = self.history(alternate)
        // On a mismatch, tmux's own pane history tells whether Dispatch dropped the output or tmux never had it.
        let pane = (try? server(["capture-pane", "-p", "-J", "-S", "-", "-t", "%0"])) ?? "unavailable"
        for index in 0..<100 {
            let marker = String(format: "STRESS_%04d", index)
            let native = history.components(separatedBy: marker).count - 1, server = pane.components(separatedBy: marker).count - 1
            // tmux can itself drop a line while reflowing during rapid resizes;
            // Dispatch must mirror exactly what tmux kept, never lose or repeat it.
            XCTAssertEqual(native, server, "No loss or duplication during resize: \(marker); "
                + "tmux pane history has it \(server)x. Native end: \(history.suffix(600))")
            XCTAssertLessThanOrEqual(server, 1, "\(marker) repeated in tmux's own history")
        }
        XCTAssertNil(runtime.helpers[.local]?.error)
        // A failed local adapter is a disconnect, never a request to kill the
        // server pane. Exercise the actual child-exit callback path.
        let survivors = try server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        alternate.didExit()
        try await eventually { !workspace.spaces.contains { $0.structured } }
        XCTAssertEqual(try server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), survivors)
    }

    private func history(_ view: TerminalView) -> String {
        guard let surface = view.surface else { return "" }
        return surface.readText(.screen)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        try await TestSupport.eventually(timeout: .seconds(8), interval: .milliseconds(30), file: file, line: line, diagnostic: "Timed out waiting for native tmux. \(TerminalRuntime.shared.helpers[.local]?.error ?? "No helper error")", condition)
    }
}
