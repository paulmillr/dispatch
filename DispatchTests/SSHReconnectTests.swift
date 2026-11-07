import AppKit
import SwiftUI
import XCTest
import Observation
@testable import DispatchApp

@MainActor
final class SSHReconnectTests: XCTestCase {
    /// A reconnect logs in in a private terminal: no sheet, tab or space. ssh asks through askpass and the strip
    /// answers (a wrong password, asked again as a retry, then the right one); its output goes to the host's log.
    func testLoginAsksThroughTheStripWithoutSheetOrSpace() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let workspace = Workspace()
        runtime.workspace = workspace
        runtime.start(preferences: Preferences())
        runtime.chat.stop()
        defer { runtime.stop(); runtime.workspace = previous }
        workspace.newLocalSpace()
        let surface = try XCTUnwrap(workspace.activeSurfaceID)
        let fixture = try AppReplay.query(kind: "fixture.ssh.login", input: .null) {
            let root = System.temporary.appendingPathComponent("reconnect-login-" + System.uuid().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("ssh-fixture"), control = root.appendingPathComponent("control")
            // As OpenSSH with SSH_ASKPASS_REQUIRE=force: every prompt through the askpass program, a refusal on stderr
            // and the same prompt again; the master answers its check once the right password came.
            let script = """
            #!/bin/sh
            for argument do
              if [ "$argument" = check ]; then [ -e \(HerdrLaunch.quote(control.path)) ]; exit; fi
            done
            [ "$SSH_ASKPASS_REQUIRE" = force ] || exit 2
            printf 'Welcome to the fixture host\\n'
            password=$("$SSH_ASKPASS" "dev@fixture's password: ") || exit 1
            if [ "$password" != abC ]; then
              printf 'Permission denied, please try again.\\n' >&2
              password=$("$SSH_ASKPASS" "dev@fixture's password: ") || exit 1
            fi
            [ "$password" = abC ] || exit 1
            touch \(HerdrLaunch.quote(control.path))
            exec /bin/sleep 30
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return .string(root.path)
        }
        let root = URL(fileURLWithPath: try AppReplay.decode(String.self, fixture))
        defer { if !AppReplay.replaying { try? FileManager.default.removeItem(at: root) } }
        let executable = root.appendingPathComponent("ssh-fixture"), control = root.appendingPathComponent("control")
        let host = HostID.authenticated("fixture"), id = SSHConnectionID()
        workspace.hosts.associate(surface, context: .init(host: host, generation: id.rawValue, state: .disconnected, authenticated: true))
        let controller = runtime.hosts.reconnect
        let previousAttempt = controller.attempt
        defer { controller.attempt = previousAttempt; controller.close(surface) }
        let shell = SSHShell(destination: "fixture", executable: executable.path)
        controller.retain(.init(connection: id, host: host, shell: shell, scope: nil, origin: surface, launcher: nil, surfaces: [surface]))
        controller.attempt = { recipe in
            try await SSHReconnectLogin.authenticate(shell: shell, master: .init(executable: executable.path, controlPath: control.path,
                                                                                destination: "fixture"), host: recipe.host)
        }
        let spaces = workspace.spaces.map(\.id), selected = workspace.selectedSpace
        controller.reconnect(hostID: host, sourceSurfaceID: surface)
        try await TestSupport.eventually(diagnostic: "log: \(controller.logs[host] ?? [])") { controller.prompts[host] != nil }
        let first = try XCTUnwrap(controller.prompts[host])
        XCTAssertEqual(first.kind, .secret)
        XCTAssertEqual(first.text, "dev@fixture's password: ")
        XCTAssertFalse(first.retry)
        XCTAssertEqual(controller.sources[host], surface, "the field takes the keyboard where Reconnect was asked")
        XCTAssertTrue(controller.loginsRunning.contains(host))
        controller.answer(host, "abX")
        try await TestSupport.eventually { controller.prompts[host].map { $0.request.id != first.request.id } == true }
        XCTAssertEqual(controller.prompts[host]?.retry, true, "the same question after an answer is a retry")
        controller.answer(host, "abC")
        try await TestSupport.eventually { controller.states.isEmpty }
        XCTAssertNil(controller.prompts[host])
        XCTAssertFalse(controller.loginsRunning.contains(host))
        XCTAssertEqual(workspace.spaces.map(\.id), spaces, "a login adds no space")
        XCTAssertEqual(workspace.selectedSpace, selected)
        XCTAssertEqual(workspace.activeSurfaceID, surface)
    }

    func testAskpassPromptKinds() {
        func request(_ prompt: String, _ hint: String? = nil) -> SSHAskpassRequest {
            .init(id: System.uuid(), tabID: System.uuid(), token: "token", prompt: prompt, hint: hint)
        }
        XCTAssertEqual(request("dev@fixture's password: ").kind, .secret)
        XCTAssertEqual(request("Enter passphrase for key '/home/dev/.ssh/id_ed25519': ").kind, .secret)
        XCTAssertEqual(request("Allow use of key id_ecdsa_sk?", "confirm").kind, .confirm)
        XCTAssertEqual(request("Are you sure you want to continue connecting (yes/no/[fingerprint])? ").kind, .confirm)
        XCTAssertEqual(request("Confirm user presence for key ED25519-SK SHA256:abc", "none").kind, .notice)
    }

    /// The login's terminal output becomes log lines: escape sequences dropped, a carriage return redrawing the line;
    /// an unfinished line asking a question is ssh asking on its terminal (an ssh without SSH_ASKPASS_REQUIRE).
    func testLoginOutputBecomesLogLinesAndTellsATerminalPrompt() {
        let controller = SSHReconnectController(runtime: TerminalRuntime.shared)
        let host = HostID.authenticated("fixture")
        controller.loginOutput(host, Data("\u{1B}[1mWelcome\u{1B}[0m to fixture\r\nprogress 10%\rprogress 99%\n".utf8))
        controller.loginOutput(host, Data("\u{1B}]0;title\u{07}dev@fixture's pass".utf8))
        XCTAssertEqual(controller.logs[host]?.map(\.text), ["Welcome to fixture", "progress 99%"])
        XCTAssertFalse(controller.awaitingTerminal.contains(host))
        controller.loginOutput(host, Data("word: ".utf8))
        XCTAssertTrue(controller.awaitingTerminal.contains(host))
        controller.loginOutput(host, Data("\r\nPermission denied (publickey,password).\r\n".utf8))
        XCTAssertFalse(controller.awaitingTerminal.contains(host))
        XCTAssertEqual(controller.logs[host]?.suffix(2).map(\.text), ["dev@fixture's password: ", "Permission denied (publickey,password)."])
        XCTAssertEqual(SSHReconnectController.plain("a\u{1B}[31mb\u{1B}[0m\u{1B}]8;;x\u{1B}\\c\u{08}"), "abc")
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
            workspace.hosts.associate(recipe.origin, context: .init(host: recipe.host, generation: System.uuid(), state: .connected, authenticated: true))
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
        let fixture = try AppReplay.query(kind: "fixture.ssh.silent", input: .null) {
            let root = System.temporary.appendingPathComponent("reconnect-silent-" + System.uuid().uuidString)
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
            return .string(root.path)
        }
        let root = URL(fileURLWithPath: try AppReplay.decode(String.self, fixture))
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
        var logs = 0
        control.update(state: .init(), reconnect: {}, cancel: {}, wheel: { _ in }, hostName: "homelab", logShown: false, toggleLog: { logs += 1 })
        control.layoutSubtreeIfNeeded()
        let log = try XCTUnwrap(buttons.first { $0.title.hasPrefix("Log") })
        XCTAssertEqual(log.title, "Log ▾")
        XCTAssertTrue(control.bounds.contains(log.frame))
        XCTAssertFalse(log.frame.intersects(try XCTUnwrap(buttons.first { $0.title.hasPrefix("Reconnect") }).frame))
        log.performClick(nil)
        XCTAssertEqual(logs, 1)
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

    /// The strip while ssh asks, glass and flat: a password (and a retry), a confirmation, a security key's touch, an ssh
    /// asking on its terminal; and the log under it.
    func testPromptRowsAndLogPresentation() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let controller = TerminalRuntime.shared.hosts.reconnect
        let host = HostID.authenticated("homelab")
        defer { controller.stop() }
        controller.log(host, "disconnected", kind: .step)
        controller.log(host, "reconnecting", kind: .step)
        controller.log(host, "checking the SSH configuration", kind: .step)
        controller.log(host, "dev@homelab's password: ", kind: .prompt)
        controller.log(host, "Permission denied, please try again.", kind: .output)
        controller.log(host, "Dispatch cannot reconnect this connection.", kind: .problem)
        func request(_ prompt: String, _ hint: String? = nil) -> SSHAskpassRequest {
            .init(id: System.uuid(), tabID: System.uuid(), token: "token", prompt: prompt, hint: hint)
        }
        let logins: [SSHReconnectLoginPresentation] = [
            .init(prompt: .init(request: request("dev@homelab's password: ")), focused: true),
            .init(prompt: .init(request: request("dev@homelab's password: "), retry: true), focused: true),
            .init(prompt: .init(request: request("Allow use of key /Users/dev/.ssh/id_ecdsa_sk?", "confirm"))),
            .init(prompt: .init(request: request("Confirm user presence for key ED25519-SK SHA256:3kF9q2", "none"))),
            .init(asking: true, logShown: true),
        ]
        let state = SSHReconnectController.State(reconnecting: true, attempted: true)
        for glass in [true, false] {
            let previous = LiquidGlassStore.shared.enabled
            LiquidGlassStore.shared.enabled = glass
            defer { LiquidGlassStore.shared.enabled = previous }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 470), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            let rows = VStack(spacing: 8) {
                ForEach(Array(logins.enumerated()), id: \.offset) { _, login in
                    if glass {
                        SSHReconnectGlassRow(state: state, hostName: "homelab", login: login, reconnect: {}, cancel: {}, close: {})
                            .frame(height: StripTab.glassTrackHeight(AppTypography()))
                    } else {
                        SSHReconnectFlatPromptRow(state: state, login: login, cancel: {}).frame(height: 34)
                    }
                }
                SSHReconnectLogPanel(host: host, hostName: "homelab")
            }
            .padding(12)
            .frame(width: 860, height: 470, alignment: .top)
            .background(ChatThemeStore.shared.current.terminal)
            window.contentView = NSHostingView(rootView: rows)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            _ = try await PresentationTestSupport.capture(window, named: "host-bar-prompts-" + (glass ? "glass" : "flat"))
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
            let session = coordinator.session(for: System.uuid())
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

extension SSHReconnectTests {
    /// What automatic reconnect tries again: an unreachable host, and a login whose later steps ran out of time (a slow
    /// link). Not a refusal, a cancellation, a permanent setup failure or a changed host.
    func testAutomaticRetryClassesTellSlowLinksFromRefusals() {
        XCTAssertTrue(SSHAutomaticFailure.retries(after: SSHAutomaticFailure.unreachable("Connection refused")))
        XCTAssertTrue(SSHAutomaticFailure.retries(after: SSHAutomaticFailure.interrupted("setup timed out")))
        XCTAssertFalse(SSHAutomaticFailure.retries(after: SSHAutomaticFailure.refused("Permission denied (publickey).")))
        XCTAssertFalse(SSHAutomaticFailure.retries(after: CancellationError()))
        XCTAssertFalse(SSHAutomaticFailure.retries(after: HerdrFailure("The SSH launcher has closed.")))

        for error: any Error in [
            SSHRecoveryIncomplete("The SSH shell reconnected, but its retained terminal spaces did not restore."),
            SSHRecoveryIncomplete("The replacement SSH shell did not start. Retry to reconnect."),
            SSHSetupFailure.permanent("SSH integration setup timed out.", reason: SSHSetupFailure.timedOut),
            SSHSetupFailure("Could not install the SSH helper in the remote cache.", reason: "the upload failed (255)", given: nil),
            HerdrFailure(SSHTimeout.message), HerdrFailure(SSHCommand.timedOut),
            HerdrFailure(SSHCommand.stalled(SSHBootstrap.uploadStall)),
        ] {
            XCTAssertTrue(SSHAutomaticFailure.transient(error), "\(error)")
        }
        for error: any Error in [
            CancellationError(),
            SSHSetupFailure.permanent("Could not identify the SSH host platform.", reason: "unknown host platform"),
            SSHSetupFailure.hooksNeedHome,
            HerdrFailure("The authenticated host changed or the retained tabs were closed."),
            HerdrFailure("The SSH account or configuration changed. Open a new connection for the changed identity."),
            SSHAutomaticFailure.refused("Its SSH login tab is closed. Reconnect to log in again."),
        ] {
            XCTAssertFalse(SSHAutomaticFailure.transient(error), "\(error)")
        }
    }

    /// A login that worked but whose later step timed out keeps retrying, with the backoff; a refusal still ends it.
    func testAutomaticReconnectKeepsRetryingALoginThatDidNotFinishInTime() async throws {
        let previous = TerminalRuntime.shared.workspace
        defer { TerminalRuntime.shared.workspace = previous }
        let (workspace, controller, recipes) = try fixture(1)
        defer { _ = workspace.spaces }
        defer { controller.stop() }
        let id = recipes[0].connection
        let slow = "The SSH shell reconnected, but its retained terminal spaces did not restore."
        var outcomes: [SSHAutomaticFailure] = [.interrupted(slow), .interrupted(slow), .refused("Permission denied (publickey).")]
        controller.attempt = { _ in if !outcomes.isEmpty { throw outcomes.removeFirst() } }
        controller.automatic = true
        controller.lost(id)
        controller.retryNow()
        try await TestSupport.eventually { outcomes.count == 2 && controller.states[id]?.retryAt != nil }
        XCTAssertEqual(controller.states[id]?.error, slow)
        controller.retryNow()
        try await TestSupport.eventually { outcomes.count == 1 && controller.states[id]?.retryAt != nil }
        controller.retryNow()
        try await TestSupport.eventually { outcomes.isEmpty && controller.states[id]?.reconnecting == false }
        XCTAssertNil(controller.states[id]?.retryAt)
        XCTAssertEqual(controller.states[id]?.attempts, 3)
        XCTAssertNotNil(controller.recipes[id], "A refused login keeps its Reconnect bar")
    }
}
