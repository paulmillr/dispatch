import AppKit
import XCTest
@testable import DispatchApp

/// These tests run on the dedicated unlocked macOS VM and operate the actual
/// AppKit sheet. The first also launches two real terminal SSH wrappers.
@MainActor
final class SSHConsentIntegrationTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @discardableResult
    private func controls(_ window: NSWindow) throws -> [NSButton] {
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        content.layoutSubtreeIfNeeded()
        let views = descendants(content)
        let buttons = views.compactMap { $0 as? NSButton }
        XCTAssertEqual(Array(buttons.prefix(6).map(\.title)), ["Upload the Dispatch helper", "Stats", "File access", "Codex", "Claude", "Pi"])
        for button in buttons {
            XCTAssertTrue(content.bounds.contains(button.convert(button.bounds, to: content)))
        }
        return buttons
    }

    private func key(_ character: String, code: UInt16, in window: NSWindow) throws {
        let sheet = try XCTUnwrap(window.attachedSheet)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber,
            context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: code))
        if !sheet.performKeyEquivalent(with: event) { sheet.sendEvent(event) }
    }

    private func click(_ title: String, in window: NSWindow) throws {
        let sheet = try XCTUnwrap(window.attachedSheet)
        let button = try XCTUnwrap(descendants(try XCTUnwrap(sheet.contentView))
            .compactMap { $0 as? NSButton }.first { $0.title == title })
        button.performClick(nil)
    }

    private func dismiss(_ window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    }

    private func cacheSnapshot() throws -> [String: String] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dispatch/bin")
        guard let entries = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in entries {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            result[url.path] = "\(attributes.fileSize ?? 0):\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return result
    }

    func testConcurrentCancelAbortsBothSSHCommandsWithoutInstallingHelpers() async throws {
        try await checkConcurrentFirstUse(cancel: true)
    }

    func testConcurrentDontInstallRunsOrdinarySSHAndRemembersTheChoice() async throws {
        try await checkConcurrentFirstUse(cancel: false)
    }

    private func checkConcurrentFirstUse(cancel: Bool) async throws {
        let app = try TmuxWalkthrough(); defer { dismiss(app.window); app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let spy = server.root.appendingPathComponent("ssh-spy"), invocations = server.root.appendingPathComponent("ssh-started")
        try ("#!/bin/sh\nif [ \"$1\" != -G ]; then printf '%s\\n' started >> " + HerdrLaunch.quote(invocations.path) +
             "; fi\nexec /usr/bin/ssh \"$@\"\n").write(to: spy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: spy.path)
        let previous = app.runtime.ssh.presentIntegrationConsent
        var scopes: [SSHIntegrationScope] = []
        app.runtime.ssh.presentIntegrationConsent = { scope, window in
            scopes.append(scope)
            XCTAssertTrue(window === app.window, "The actual launcher must attach consent to its terminal window")
            return await SSHIntegrationConsent.present(scope, window: window)
        }
        defer { app.runtime.ssh.presentIntegrationConsent = previous }
        let firstID = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[firstID].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let first = try XCTUnwrap(app.runtime.views[firstID])
        app.workspace.newTab()
        let secondID = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[secondID].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let second = try XCTUnwrap(app.runtime.views[secondID])
        let hooks = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
        let hooksBefore = try? Data(contentsOf: hooks)
        let cacheBefore = try cacheSnapshot()
        let command = "DISPATCH_SSH_EXECUTABLE=" + HerdrLaunch.quote(spy.path) + " ssh -tt " +
            (server.options + [server.destination, "printf 'CONSENT_%s\\n' ORDINARY; exit 23"]).map(HerdrLaunch.quote).joined(separator: " ")
        let trackedCommand = command + "; printf 'LOCAL_%s:%s\\n' DONE \"$?\""
        TerminalTestSupport.send(trackedCommand, to: first)
        TerminalTestSupport.send(trackedCommand, to: second)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic:
            "Consent presentations=\(scopes.count), key=\(NSApp.keyWindow === app.window), sheet=\(app.window.attachedSheet != nil), SSH starts=\((try? String(contentsOf: invocations, encoding: .utf8)) ?? "none"); first=\(TerminalTestSupport.screen(terminal: first)); second=\(TerminalTestSupport.screen(terminal: second))") {
            app.window.attachedSheet != nil && scopes.count == 1
        }
        try controls(app.window)
        // Give both local permission mailboxes a chance to reach the same sheet.
        try await Task.sleep(for: .milliseconds(150))
        let sheet = try XCTUnwrap(app.window.attachedSheet)
        _ = try await PresentationTestSupport.capture(sheet, named: "ssh-integration-consent", in: "ssh-consent-layout-validation")
        let heading = try XCTUnwrap(descendants(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("Connect to ") })
        XCTAssertEqual(heading.stringValue, "Connect to 127.0.0.1")
        XCTAssertEqual(scopes.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocations.path), "Only ssh -G may run before a choice")
        XCTAssertTrue(app.runtime.ssh.links.isEmpty)
        XCTAssertEqual(try cacheSnapshot(), cacheBefore, "No helper upload before consent")
        XCTAssertTrue((try? Data(contentsOf: hooks)) == hooksBefore, "No hook mutation before consent")
        let scope = try XCTUnwrap(scopes.first)
        XCTAssertNil(app.runtime.ssh.permissions.remembered(scope))
        if cancel { try key("\u{1b}", code: 53, in: app.window) }
        else {
            try click("Upload the Dispatch helper", in: app.window)
            try click("Connect", in: app.window)
        }
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: TerminalTestSupport.screen(terminal: first) + TerminalTestSupport.screen(terminal: second)) {
            [first, second].allSatisfy { TerminalTestSupport.screen(terminal: $0).contains(cancel ? "LOCAL_DONE:130" : "LOCAL_DONE:23") }
        }
        XCTAssertEqual(scopes.count, 1)
        if cancel {
            XCTAssertNil(app.runtime.ssh.permissions.remembered(scope), "Cancel must not persist a choice")
            XCTAssertFalse(FileManager.default.fileExists(atPath: invocations.path), "Cancel must never start SSH")
            for terminal in [first, second] {
                XCTAssertFalse(TerminalTestSupport.screen(terminal: terminal).contains("CONSENT_ORDINARY"))
            }
        } else {
            XCTAssertEqual(app.runtime.ssh.permissions.remembered(scope)?.profile, .ordinary)
            XCTAssertEqual(try String(contentsOf: invocations, encoding: .utf8).split(separator: "\n").count, 2,
                           "Don't install runs each ordinary SSH command once, without a helper connection")
        }
        XCTAssertTrue(app.runtime.ssh.links.isEmpty)
        XCTAssertEqual(try cacheSnapshot(), cacheBefore)
        XCTAssertTrue((try? Data(contentsOf: hooks)) == hooksBefore)
    }

    func testRememberedChoiceAndChangedConfigurationUseTheNativeSheet() async throws {
        let app = try TmuxWalkthrough(); defer { dismiss(app.window); app.close() }
        let store = SSHIntegrationPermissions(defaults: nil)
        let target = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "fixture", configuration: "user alice\nhostname fixture\n"))
        let changed = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "fixture", configuration: "user alice\nhostname fixture\nidentityfile changed\n"))
        var presentations = 0
        let present: @MainActor (SSHIntegrationScope) async -> SSHIntegrationSelection? = { scope in
            presentations += 1; return await SSHIntegrationConsent.present(scope, window: app.window)
        }
        let first = Task { await store.choose(target, present: present) }
        defer { first.cancel() }
        try await TestSupport.eventually { app.window.attachedSheet != nil }
        try controls(app.window)
        try click("Upload the Dispatch helper", in: app.window)
        try click("Connect", in: app.window)
        let ordinary = await first.value
        XCTAssertEqual(ordinary?.profile, .ordinary)
        XCTAssertEqual(store.remembered(target), ordinary)
        let reused = await store.choose(target, present: present)
        XCTAssertEqual(reused, ordinary)
        XCTAssertEqual(presentations, 1)
        try await TestSupport.eventually { app.window.attachedSheet == nil }
        let next = Task { await store.choose(changed, present: present) }
        defer { next.cancel() }
        try await TestSupport.eventually { app.window.attachedSheet != nil }
        XCTAssertEqual(presentations, 2)
        try controls(app.window)
        try click("Connect", in: app.window)
        let updated = await next.value
        XCTAssertEqual(updated?.selectedFeatures, Set(SSHIntegrationFeature.allCases))
        XCTAssertEqual(store.remembered(target)?.profile, .ordinary)
        XCTAssertEqual(store.remembered(changed), updated)
    }

    func testCapabilityUpgradeRequiresAnotherExplicitNativeChoice() async throws {
        let app = try TmuxWalkthrough(); defer { dismiss(app.window); app.close() }
        let target = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "fixture", configuration: "user alice\nhostname fixture\n"))
        let suite = "dispatch-consent-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let full = SSHIntegrationGrant(profile: .full)
        let entry = SSHIntegrationPermissions.Entry(scope: target, grant: full)
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        var grant = try XCTUnwrap(stored["grant"] as? [String: Any])
        grant["capabilities"] = full.capabilities.subtracting(["agent.events"]).sorted()
        stored["grant"] = grant
        defaults.set(try JSONSerialization.data(withJSONObject: [stored]), forKey: "SSHIntegrationPermissions.v2")
        let store = SSHIntegrationPermissions(defaults: defaults)
        XCTAssertNil(store.remembered(target))
        let choice = Task { await store.choose(target, present: { await SSHIntegrationConsent.present($0, window: app.window) }) }
        defer { choice.cancel() }
        try await TestSupport.eventually { app.window.attachedSheet != nil }
        let choices = try controls(app.window)
        for title in ["Stats", "File access", "Codex", "Claude", "Pi"] {
            let button = try XCTUnwrap(choices.first { $0.title == title })
            if button.state != .on { try click(title, in: app.window) }
        }
        try click("Connect", in: app.window)
        let result = await choice.value
        let selected = try XCTUnwrap(result)
        XCTAssertEqual(selected.profile, .full)
        XCTAssertTrue(selected.hooks, "Full integration includes hook installation")
        XCTAssertTrue(selected.capabilities.contains("hooks.configure"))
        XCTAssertTrue(selected.capabilities.contains("agent.events"))
        XCTAssertEqual(store.remembered(target), selected)
    }

    func testLongDestinationAndSettingsCancellation() async throws {
        let app = try TmuxWalkthrough(); defer { dismiss(app.window); app.close() }
        let target = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh",
            destination: String(repeating: "long-host-name-", count: 12), configuration: "user alice\nhostname fixture\n"))
        let current = SSHIntegrationGrant(profile: .full, hooks: true)
        let choice = Task { await SSHIntegrationConsent.present(target, current: current, window: app.window) }
        try await TestSupport.eventually { app.window.attachedSheet != nil }
        try controls(app.window)
        let sheet = try XCTUnwrap(app.window.attachedSheet)
        _ = try await PresentationTestSupport.capture(sheet, named: "ssh-full-integration", in: "ssh-consent")
        try key("\u{1b}", code: 53, in: app.window)
        let result = await choice.value
        XCTAssertNil(result, "Escape leaves settings unchanged")
    }

    func testCancelledPresenterClosesItsSheetWithoutAGrant() async throws {
        let app = try TmuxWalkthrough(); defer { dismiss(app.window); app.close() }
        let target = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "fixture", configuration: "user alice\n"))
        let choice = Task { await SSHIntegrationConsent.present(target, window: app.window) }
        try await TestSupport.eventually { app.window.attachedSheet != nil }
        choice.cancel()
        let result = await choice.value
        XCTAssertNil(result)
        try await TestSupport.eventually { app.window.attachedSheet == nil }
    }

    func testPresenterCancellationWinsOverQueuedReconnectActivation() async throws {
        let app = try TmuxWalkthrough(); defer { dismiss(app.window); app.close() }
        let target = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "fixture", configuration: "user alice\n"))
        var reads = 0, reconnects = 0
        let choice = Task {
            await SSHIntegrationConsent.present(target, current: .init(profile: .full, hooks: true), window: app.window,
                reconnect: { reconnects += 1 }, activeGrants: [.init(profile: .statistics)], connectionState: {
                    reads += 1
                    return .init(grants: [.init(profile: .statistics)])
                })
        }
        defer { choice.cancel() }
        try await TestSupport.eventually { app.window.attachedSheet != nil && reads > 0 }
        let buttons = try controls(app.window)
        let reconnect = try XCTUnwrap(buttons.first { $0.title == "Save & reconnect" })
        XCTAssertTrue(reconnect.isEnabled)
        // Keep the actor occupied so the cancellation callback cannot dismiss
        // the sheet before an already-queued activation reaches the button.
        choice.cancel()
        reconnect.performClick(nil)
        let result = await choice.value
        XCTAssertNil(result)
        XCTAssertEqual(reconnects, 0)
        try await TestSupport.eventually { app.window.attachedSheet == nil }
        let finalReads = reads
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(reads, finalReads, "Cancellation must stop the live-state polling task")
    }

}
