import AppKit
import SwiftUI
import XCTest
import Observation
@testable import DispatchApp

@MainActor
final class SSHReconnectTests: XCTestCase {
    func testLoginSheetReceivesPasswordKeysAndRestoresWorkspaceFocus() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let workspace = Workspace()
        runtime.workspace = workspace
        runtime.start(preferences: Preferences())
        runtime.chat.stop()
        workspace.newLocalSpace()
        let active = try XCTUnwrap(workspace.activeSurfaceID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(editor)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(editor))
        defer {
            window.orderOut(nil); window.close(); runtime.stop(); runtime.workspace = previous
        }

        let fixture = try AppReplay.query(kind: "fixture.ssh.login", input: Data()) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("reconnect-login-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("ssh-fixture"), control = root.appendingPathComponent("control")
            // Exercise the production sheet and PTY with an echo-disabled password
            // prompt; the control check succeeds only after correct keyboard input.
            let script = """
            #!/bin/sh
            for argument do
              if [ "$argument" = check ]; then exit 0; fi
            done
            stty -echo
            printf 'Password: '
            IFS= read -r password
            stty echo
            [ "$password" = abC ] || exit 1
            touch \(HerdrLaunch.quote(control.path))
            exec /bin/sleep 30
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return try JSONEncoder().encode(root.path)
        }
        let root = URL(fileURLWithPath: try JSONDecoder().decode(String.self, from: fixture))
        defer { if !AppReplay.replaying { try? FileManager.default.removeItem(at: root) } }
        let executable = root.appendingPathComponent("ssh-fixture"), control = root.appendingPathComponent("control")
        if AppReplay.replaying { XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path)) }
        let task = Task {
            try await SSHReconnectLogin.authenticate(shell: .init(destination: "fixture", executable: executable.path),
                master: .init(executable: executable.path, controlPath: control.path, destination: "fixture"), window: window)
        }
        do {
            try await TestSupport.eventually { window.attachedSheet != nil }
            let sheet = try XCTUnwrap(window.attachedSheet)
            let terminal = try XCTUnwrap(sheet.contentView?.subviews.compactMap { $0 as? TerminalView }.first)
            try await TestSupport.eventually { TerminalTestSupport.screen(terminal: terminal).contains("Password:") }
            XCTAssertFalse(workspace.isSurfacePresented(terminal.id))
            XCTAssertTrue(sheet.firstResponder === terminal, "The login prompt must receive focus when the sheet opens")
            XCTAssertTrue(terminal.acceptsFirstResponder)
            for (code, text, modifiers): (UInt16, String, NSEvent.ModifierFlags) in [
                (0, "a", []), (7, "x", []), (51, "\u{7f}", []), (11, "b", []), (8, "C", .shift), (36, "\r", [])
            ] {
                NSApp.sendEvent(TerminalTestSupport.keyEvent(code, text, in: sheet, modifiers: modifiers))
            }
            try await TestSupport.eventually { window.attachedSheet == nil }
            try await task.value
            XCTAssertNil(terminal.surface)
            XCTAssertEqual(workspace.activeSurfaceID, active)
            XCTAssertTrue(window.firstResponder === editor)
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }

    func testNormalSSHExitIsDistinctFromTransportLossAndLegacyNotices() throws {
        for status: Int32 in [0, 1, 17, 137, 254] {
            let notice = SSHCloseNotice(credential: "fixture", status: status, recoverable: true, transportExitedNormally: true)
            XCTAssertEqual(notice.remoteExitStatus, status)
            XCTAssertEqual(try JSONDecoder().decode(SSHCloseNotice.self, from: JSONEncoder().encode(notice)).remoteExitStatus, status)
        }
        XCTAssertNil(SSHCloseNotice(credential: "fixture", status: 255, recoverable: true, transportExitedNormally: true).remoteExitStatus)
        XCTAssertNil(SSHCloseNotice(credential: "fixture", status: 143, recoverable: true, transportExitedNormally: false).remoteExitStatus)
        XCTAssertNil(SSHCloseNotice(credential: "fixture", status: 0, recoverable: true).remoteExitStatus)
    }

    private func fixture(_ count: Int = 2) throws -> (Workspace, SSHReconnectController, [SSHReconnectController.Recipe]) {
        let runtime = TerminalRuntime.shared, workspace = Workspace()
        runtime.workspace = workspace
        let controller = SSHReconnectController(runtime: runtime)
        let scope = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "fixture", configuration: "hostname fixture\nuser test\nport 22"))
        var recipes: [SSHReconnectController.Recipe] = []
        for _ in 0..<count {
            workspace.newLocalSpace()
            let surface = try XCTUnwrap(workspace.activeSurfaceID), id = SSHConnectionID()
            workspace.hosts.associate(surface, context: .init(host: .authenticated("fixture"), generation: id.rawValue, state: .disconnected, authenticated: true))
            let recipe = SSHReconnectController.Recipe(connection: id, host: .authenticated("fixture"), shell: .init(destination: "fixture"), scope: scope,
                origin: surface, launcher: nil, surfaces: [surface])
            recipes.append(recipe); controller.retain(recipe)
        }
        return (workspace, controller, recipes)
    }
    func testHostRetryCoalescesClicksAndKeepsHealthyConnectionsUntouched() async throws {
        let previous = TerminalRuntime.shared.workspace
        defer { TerminalRuntime.shared.workspace = previous }
        let (workspace, controller, recipes) = try fixture(3)
        defer { controller.stop() }
        let healthy = recipes[2]
        controller.forget(healthy.connection)
        workspace.hosts.setState(.connected, generation: healthy.connection.rawValue)
        XCTAssertEqual(workspace.hosts.state(healthy.host), .connected)
        XCTAssertNotNil(controller.state(for: recipes[0].origin), "A healthy connection cannot hide a disconnected tab's control")
        var attempted: [SSHConnectionID] = []
        controller.attempt = { recipe in
            attempted.append(recipe.connection)
            try await Task.sleep(for: .milliseconds(40))
        }
        let ids = workspace.allSurfaceIDs, selected = workspace.selectedSpace
        for _ in 0..<8 { controller.reconnect(hostID: recipes[0].host, sourceSurfaceID: recipes[0].origin) }
        try await TestSupport.eventually { controller.states.isEmpty }
        XCTAssertEqual(Set(attempted), Set(recipes.prefix(2).map(\.connection)))
        XCTAssertEqual(attempted.count, 2)
        XCTAssertEqual(workspace.allSurfaceIDs, ids)
        XCTAssertEqual(workspace.selectedSpace, selected)
        XCTAssertTrue(workspace.hostMoveMotion.connecting.isEmpty)
    }
    func testReplacementKeepsOnlyItsConsumersPendingUntilRestored() throws {
        let previous = TerminalRuntime.shared.workspace
        defer { TerminalRuntime.shared.workspace = previous }
        let (workspace, controller, recipes) = try fixture()
        defer { controller.stop() }
        let recipe = recipes[0], replacement = SSHConnectionID()
        let expected = try XCTUnwrap(controller.state(for: recipe.origin))
        let other = try XCTUnwrap(controller.state(for: recipes[1].origin))
        let location = try XCTUnwrap(workspace.location(ofTab: recipe.origin))
        workspace.spaces[location.space].panes[location.pane].tabs[location.tab].terminal = 1
        workspace.spaces[location.space].panes[location.pane].tabs[location.tab].isConnecting = true
        controller.shellStarting(replacement, replacing: recipe.connection)
        workspace.hosts.associate(recipe.origin, context: .init(host: recipe.host,
            generation: replacement.rawValue, state: .connected, authenticated: true))
        XCTAssertEqual(controller.state(for: recipe.origin), expected)
        XCTAssertEqual(controller.state(for: recipes[1].origin), other)
        workspace.hosts.associate(recipes[1].origin, context: .init(host: recipe.host,
            generation: replacement.rawValue, state: .connected, authenticated: true))
        XCTAssertNil(controller.state(for: recipes[1].origin), "A replacement does not own another connection's consumer")
        controller.forget(recipe.connection)
        XCTAssertNil(controller.state(for: recipe.origin))
        XCTAssertFalse(workspace.spaces[location.space].panes[location.pane].tabs[location.tab].isConnecting)
        XCTAssertEqual(Set(controller.recipes.keys), [recipes[1].connection])
    }
    func testPartialRecoveryRetainsOnlyFailuresForRetry() async throws {
        let previous = TerminalRuntime.shared.workspace
        defer { TerminalRuntime.shared.workspace = previous }
        let (workspace, controller, recipes) = try fixture()
        defer { _ = workspace.spaces }
        defer { controller.stop() }
        controller.attempt = { recipe in
            if recipe.connection == recipes[1].connection { throw HerdrFailure("Missing native session") }
        }
        controller.reconnect(hostID: recipes[0].host, sourceSurfaceID: recipes[0].origin)
        try await TestSupport.eventually { controller.states.values.allSatisfy { !$0.reconnecting } }
        XCTAssertNil(controller.states[recipes[0].connection])
        XCTAssertEqual(controller.states[recipes[1].connection]?.error, "Missing native session")
        var retried: [SSHConnectionID] = []
        controller.attempt = { retried.append($0.connection) }
        controller.reconnect(hostID: recipes[1].host, sourceSurfaceID: recipes[1].origin)
        try await TestSupport.eventually { controller.states.isEmpty }
        XCTAssertEqual(retried, [recipes[1].connection])
    }
    func testHostDisconnectCancelsReconnectWithoutCancellingAnotherHost() async throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        defer { runtime.workspace = previous }
        let (workspace, fixtureController, recipes) = try fixture(2)
        defer { fixtureController.stop() }
        let controller = runtime.hosts.reconnect, oldAttempt = controller.attempt
        defer { controller.stop(); controller.attempt = oldAttempt }
        let target = recipes[0]
        let other = SSHReconnectController.Recipe(connection: recipes[1].connection, host: .authenticated("other"),
            shell: recipes[1].shell, scope: recipes[1].scope, origin: recipes[1].origin, surfaces: recipes[1].surfaces)
        workspace.hosts.associate(other.origin, context: .init(host: other.host, generation: other.connection.rawValue, state: .disconnected, authenticated: true))
        controller.retain(target); controller.retain(other)
        var completion: CheckedContinuation<Void, Never>?
        controller.attempt = { recipe in
            if recipe.host == target.host { await withCheckedContinuation { completion = $0 } }
        }
        controller.reconnect(hostID: target.host, sourceSurfaceID: target.origin)
        try await TestSupport.eventually { completion != nil }
        controller.reconnect(hostID: other.host, sourceSurfaceID: other.origin)
        XCTAssertTrue(runtime.hosts.canDisconnect(target.host))
        runtime.hosts.disconnect(target.host)
        XCTAssertEqual(controller.states[target.connection]?.reconnecting, false)
        completion?.resume(); completion = nil
        try await TestSupport.eventually { controller.states[other.connection] == nil }
        XCTAssertNotNil(controller.recipes[target.connection])
        XCTAssertNil(controller.completed[target.origin])
        XCTAssertTrue(workspace.hostMoveMotion.connecting.isEmpty)
    }

    func testCancellationAndClosedTabsRejectLateCompletion() async throws {
        let previous = TerminalRuntime.shared.workspace
        defer { TerminalRuntime.shared.workspace = previous }
        let (workspace, controller, recipes) = try fixture(1)
        defer { controller.stop() }
        var completion: CheckedContinuation<Void, Never>?
        controller.attempt = { _ in await withCheckedContinuation { completion = $0 } }
        controller.reconnect(hostID: recipes[0].host, sourceSurfaceID: recipes[0].origin)
        try await TestSupport.eventually { completion != nil }
        controller.cancel(hostID: recipes[0].host)
        completion?.resume(); completion = nil
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.states[recipes[0].connection]?.reconnecting, false)
        XCTAssertEqual(controller.states[recipes[0].connection]?.attempted, true)
        XCTAssertEqual(controller.states[recipes[0].connection]?.attempts, 1)
        XCTAssertTrue(controller.completed.isEmpty)
        XCTAssertTrue(workspace.hostMoveMotion.connecting.isEmpty)
        controller.reconnect(hostID: recipes[0].host, sourceSurfaceID: recipes[0].origin)
        try await TestSupport.eventually { completion != nil }
        controller.close(recipes[0].origin)
        workspace.closeTab(recipes[0].origin)
        completion?.resume()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(controller.states.isEmpty)
        XCTAssertTrue(workspace.allSurfaceIDs.isEmpty)
    }
    func testSuccessfulGenerationReplacementShowsConnectedThenClears() async throws {
        let previous = TerminalRuntime.shared.workspace
        defer { TerminalRuntime.shared.workspace = previous }
        let (workspace, controller, recipes) = try fixture(1)
        defer { controller.stop() }
        let recipe = recipes[0]
        controller.attempt = { recipe in
            workspace.hosts.associate(recipe.origin, context: .init(host: recipe.host, generation: UUID(), state: .connected, authenticated: true))
            // Production recovery retires the old recipe before returning.
            controller.forget(recipe.connection)
        }
        controller.reconnect(hostID: recipe.host, sourceSurfaceID: recipe.origin)
        try await TestSupport.eventually { controller.presentationState(for: recipe.origin)?.connected == true }
        XCTAssertNil(controller.state(for: recipe.origin), "Success must release input before the banner folds")
        try await TestSupport.eventually { controller.presentationState(for: recipe.origin) == nil }
    }

    func testOfflineTimestampAndAttemptCountSurviveFailure() async throws {
        let previous = TerminalRuntime.shared.workspace
        defer { TerminalRuntime.shared.workspace = previous }
        let (workspace, controller, recipes) = try fixture(1)
        defer { _ = workspace.spaces }
        defer { controller.stop() }
        let recipe = recipes[0]
        let disconnectedAt = controller.states[recipe.connection]?.disconnectedAt
        XCTAssertNotNil(disconnectedAt)
        controller.attempt = { _ in throw HerdrFailure("Connection reset by peer") }
        controller.reconnect(hostID: recipe.host, sourceSurfaceID: recipe.origin)
        try await TestSupport.eventually { controller.states[recipe.connection]?.error != nil }
        XCTAssertEqual(controller.states[recipe.connection]?.attempts, 1)
        XCTAssertEqual(controller.states[recipe.connection]?.disconnectedAt, disconnectedAt)
        XCTAssertTrue(controller.completed.isEmpty)
    }

    /// Automatic reconnect retries a dropped host only while it is unreachable; OpenSSH refusing the login ends it.
    func testAutomaticReconnectRetriesUnreachableHostUntilRefused() async throws {
        let previous = TerminalRuntime.shared.workspace
        defer { TerminalRuntime.shared.workspace = previous }
        let (workspace, controller, recipes) = try fixture(1)
        defer { _ = workspace.spaces }
        defer { controller.stop() }
        let id = recipes[0].connection
        var outcomes: [SSHAutomaticFailure] = [.unreachable("Connection refused"), .refused("Permission denied (publickey).")]
        controller.attempt = { _ in if !outcomes.isEmpty { throw outcomes.removeFirst() } }
        controller.lost(id)
        XCTAssertNil(controller.states[id]?.retryAt, "Off by default: a drop waits for Reconnect")
        controller.automatic = true
        XCTAssertNotNil(controller.states[id]?.retryAt, "Turning it on retries a drop that is still pending")
        controller.retryNow()
        try await TestSupport.eventually { outcomes.count == 1 && controller.states[id]?.retryAt != nil }
        XCTAssertEqual(controller.states[id]?.error, "Connection refused")
        controller.retryNow()
        try await TestSupport.eventually { outcomes.isEmpty && controller.states[id]?.reconnecting == false }
        XCTAssertNil(controller.states[id]?.retryAt)
        XCTAssertEqual(controller.states[id]?.error, "Permission denied (publickey).")
        XCTAssertEqual(controller.states[id]?.attempts, 2)
        XCTAssertNotNil(controller.recipes[id], "A refused login keeps its Reconnect bar")
    }

    /// An automatic login never prompts: BatchMode holds over the connection's own options, and only
    /// OpenSSH refusing the login, not an unreachable host, stops the retries.
    func testSilentLoginNeverPromptsAndTellsRefusalFromUnreachable() async throws {
        let fixture = try AppReplay.query(kind: "fixture.ssh.silent", input: Data()) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("reconnect-silent-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("ssh-fixture")
            // OpenSSH's exits per destination; a login that could prompt (BatchMode not yes first) fails instead.
            let script = """
            #!/bin/sh
            batch=
            for argument do
              case "$argument" in
                check) exit 0 ;;
                BatchMode=*) [ -n "$batch" ] || batch=$argument ;;
              esac
              destination=$argument
            done
            [ "$batch" = BatchMode=yes ] || { echo 'Password:' >&2; exit 3; }
            case "$destination" in
              refused) echo 'Warning: Permanently added refused (ED25519) to the list of known hosts.' >&2
                       echo 'test@refused: Permission denied (publickey,password).' >&2; exit 255 ;;
              unreachable) echo 'ssh: connect to host unreachable port 22: Connection refused' >&2; exit 255 ;;
            esac
            exit 0
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return try JSONEncoder().encode(root.path)
        }
        let root = URL(fileURLWithPath: try JSONDecoder().decode(String.self, from: fixture))
        defer { if !AppReplay.replaying { try? FileManager.default.removeItem(at: root) } }
        let executable = root.appendingPathComponent("ssh-fixture").path
        func login(_ destination: String) async -> (any Error)? {
            do {
                try await SSHReconnectLogin.authenticateSilently(
                    shell: .init(destination: destination, options: ["-o", "BatchMode=no"], executable: executable),
                    master: .init(executable: executable, controlPath: root.appendingPathComponent("master").path, destination: destination))
                return nil
            } catch { return error }
        }
        let ready = await login("ready")
        XCTAssertNil(ready)
        guard case .refused(let refusal)? = await login("refused") as? SSHAutomaticFailure else {
            return XCTFail("OpenSSH refusing the login must stop automatic retries")
        }
        XCTAssertEqual(refusal, "test@refused: Permission denied (publickey,password).")
        guard case .unreachable(let failure)? = await login("unreachable") as? SSHAutomaticFailure else {
            return XCTFail("An unreachable host must be retried")
        }
        XCTAssertEqual(failure, "ssh: connect to host unreachable port 22: Connection refused")
    }

    func testOfflineTerminalDiscardsCompositionAndReturnReconnects() async throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        defer { runtime.workspace = previous }
        let (workspace, fixtureController, recipes) = try fixture(1)
        defer { _ = workspace.spaces }
        defer { fixtureController.stop() }
        let recipe = recipes[0], controller = runtime.hosts.reconnect
        let previousAttempt = controller.attempt
        defer { controller.close(recipe.origin); controller.attempt = previousAttempt }
        controller.retain(recipe)
        let terminal = TerminalView(id: recipe.origin, directory: "/tmp")
        XCTAssertTrue(terminal.inputParked)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        terminal.currentKeyEvent = enter
        terminal.insertText("NEVER_REPLAY", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(terminal.keyTextAccumulator.isEmpty)
        terminal.currentKeyEvent = nil
        var attempted = false
        controller.attempt = { _ in attempted = true }
        terminal.keyDown(with: enter)
        try await TestSupport.eventually { attempted && !terminal.inputParked }
        XCTAssertTrue(terminal.keyTextAccumulator.isEmpty)
    }

    func testReconnectBarActionsAndReducedMotion() throws {
        let control = SSHReconnectControl.Control(frame: NSRect(x: 0, y: 0, width: 820, height: 34))
        var connects = 0, closes = 0, cancels = 0
        control.update(state: .init(), reconnect: { connects += 1 }, cancel: { cancels += 1 }, wheel: { _ in }, hostName: "homelab", close: { closes += 1 })
        control.layoutSubtreeIfNeeded()
        let buttons = control.subviews.compactMap { $0 as? NSButton }
        try XCTUnwrap(buttons.first { $0.title.hasPrefix("Reconnect") }).performClick(nil)
        try XCTUnwrap(buttons.first { $0.title == "Close tab" }).performClick(nil)
        XCTAssertEqual(connects, 1); XCTAssertEqual(closes, 1)
        control.update(state: .init(reconnecting: true), reconnect: {}, cancel: { cancels += 1 }, wheel: { _ in }, reduceMotion: true)
        let arcs = control.subviews.flatMap { $0.layer?.sublayers ?? [] }.compactMap { $0 as? CAShapeLayer }
        XCTAssertEqual(arcs.count, 1)
        XCTAssertTrue(arcs.allSatisfy { $0.animation(forKey: "sweep") == nil })
        try XCTUnwrap(buttons.first { $0.title == "Cancel" }).performClick(nil)
        XCTAssertEqual(cancels, 1)
        control.update(state: .init(connected: true), reconnect: {}, cancel: {}, wheel: { _ in })
        XCTAssertTrue(buttons.allSatisfy(\.isHidden))
    }

    func testOfflineBarFullWidthPresentation() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 34), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let control = SSHReconnectControl.Control(frame: NSRect(x: 0, y: 0, width: 820, height: 34))
        window.contentView = control; window.makeKeyAndOrderFront(nil)
        for (name, value) in [("offline", SSHReconnectController.State(error: "connection reset by peer", disconnectedAt: Date(), attempts: 3)),
                              ("reconnecting", .init(reconnecting: true)), ("connected", .init(connected: true))] {
            control.update(state: value, reconnect: {}, cancel: {}, wheel: { _ in }, hostName: "homelab", reduceMotion: true)
            control.appearance(theme: .standard, font: AppFont.native(size: 11.5))
            control.layoutSubtreeIfNeeded()
            _ = try await PresentationTestSupport.capture(window, named: "host-bar-" + name)
            let buttons = control.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            for button in buttons { XCTAssertTrue(control.bounds.contains(button.frame)) }
        }
    }

    func testReconnectControlKeepsViewportAndForwardsWheel() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let previousTheme = ChatThemeStore.shared.current
        defer { ChatThemeStore.shared.current = previousTheme }
        for (width, dark) in [(CGFloat(240), true), (CGFloat(240), false), (CGFloat(440), true), (CGFloat(440), false)] {
            var theme = ChatTheme.standard
            theme.isDark = dark; theme.window = dark ? .black : .white; theme.ink = dark ? .white : .black
            ChatThemeStore.shared.current = theme
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            let coordinator = ChatCoordinator(enabled: false)
            defer { coordinator.stop() }
            let session = coordinator.session(for: UUID())
            session.sessionID = "overlay"; session.showChat = true
            session.draft = "Editable offline draft"
            session.turns = (0..<40).map { .init(id: "turn-\($0)", items: [.init(id: "reply-\($0)", kind: .assistant, text: String(repeating: "Loaded history stays in place.\n", count: 8))]) }
            let state = OverlayState()
            let host = NSHostingView(rootView: ReconnectPresentationFixture(session: session, coordinator: coordinator, state: state))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: host).max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
            let editor = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: host).first)
            window.makeFirstResponder(editor)
            let selection = NSRange(location: 2, length: 5)
            editor.setSelectedRange(selection)
            // Let the focused composer's wrapped draft and the lazy transcript
            // finish their initial measurements before recording the viewport.
            try await Task.sleep(for: .milliseconds(100))
            session.scrollPosition.userWillScroll(deltaY: 150)
            session.atBottom = false
            scroll.contentView.scroll(to: .init(x: 0, y: 150))
            try await Task.sleep(for: .milliseconds(150))
            let geometry = scroll.frame.size, anchor = scroll.contentView.bounds.origin
            for value in [SSHReconnectController.State(), .init(reconnecting: true, attempted: true), .init(error: "Authentication failed", attempted: true)] {
                state.value = value
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(scroll.frame.size, geometry)
                XCTAssertEqual(scroll.contentView.bounds.origin.y, anchor.y, accuracy: 2)
                XCTAssertTrue(window.firstResponder === editor)
                XCTAssertEqual(editor.selectedRange(), selection)
                XCTAssertTrue(editor.isEditable)
            }
            _ = try await PresentationTestSupport.capture(window, named: "host-offline-\(Int(width))-\(dark ? "dark" : "light")")
            let control = try XCTUnwrap(PresentationTestSupport.views(of: SSHReconnectControl.Control.self, in: host).first)
            var forwarded = false
            control.update(state: .init(), reconnect: {}, cancel: {}, wheel: { _ in forwarded = true })
            let event = try XCTUnwrap(NSEvent(cgEvent: try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 24, wheel2: 0, wheel3: 0))))
            let button = try XCTUnwrap(control.subviews.compactMap { $0 as? NSButton }.first)
            let responder = window.firstResponder
            button.scrollWheel(with: event)
            XCTAssertTrue(forwarded)
            XCTAssertTrue(button.refusesFirstResponder)
            XCTAssertTrue(window.firstResponder === responder)
            XCTAssertNil(control.hitTest(NSPoint(x: control.frame.minX + 1, y: control.frame.minY + 1)))
        }
    }
}

@MainActor @Observable
private final class OverlayState { var value: SSHReconnectController.State? = .init() }

private struct ReconnectPresentationFixture: View {
    let session: ChatSession
    let coordinator: ChatCoordinator
    @Bindable var state: OverlayState
    var body: some View {
        let value = state.value
        VStack(spacing: 0) {
            if let value {
                SSHReconnectControl(state: value, reconnect: {}, cancel: {}, wheel: { session.scrollPosition.forwardWheel($0) })
                    .frame(height: 34)
            }
            ChatView(session: session, coordinator: coordinator, focused: true, floatingSwitch: false)
        }
    }
}
