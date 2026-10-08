import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class SSHConsentPresentationTests: XCTestCase {
    private var lastAgents: [SSHHookAgent: Bool]?

    func testClosingParentWindowFinishesPresenterAndStopsPolling() async throws {
        try await closeParentWithPresenters(count: 1)
    }

    func testClosingParentWindowFinishesQueuedPresenters() async throws {
        try await closeParentWithPresenters(count: 2)
    }

    func testCancellingQueuedPresenterPreservesVisibleDraft() async throws {
        let result = try await prompt(current: .init(profile: .full, hooks: true)) { active, buttons in
            try click("Stats", buttons)
            let parent = try XCTUnwrap(active.sheetParent)
            let scope = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "other", configuration: "user alice\n"))
            var reads = 0, finished = false
            let queued = Task {
                let grant = await SSHIntegrationConsent.present(scope, window: parent,
                    connectionState: { reads += 1; return .init() })
                finished = true
                return grant
            }
            defer { queued.cancel() }
            try await TestSupport.eventually { reads > 0 }
            XCTAssertTrue(parent.attachedSheet === active)
            queued.cancel()
            try await TestSupport.eventually(diagnostic: "Cancelling a queued presenter must finish it independently") { finished }
            let grant = await queued.value
            XCTAssertNil(grant)
            XCTAssertTrue(parent.attachedSheet === active)
            XCTAssertEqual(buttons.first { $0.title == "Stats" }?.state, .off)
            let finalReads = reads
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(reads, finalReads)
            try click("Save", buttons)
        }
        XCTAssertEqual(result?.selectedFeatures, Set(SSHIntegrationFeature.allCases).subtracting([.statistics]))
    }

    private func closeParentWithPresenters(count: Int) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let scope = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "fixture", configuration: "user alice\n"))
        var finished = 0, reads = 0
        var started = Set<Int>()
        let choices = (0..<count).map { index in Task {
            let grant = await SSHIntegrationConsent.present(scope, current: .init(profile: .statistics), window: window,
                connectionState: { started.insert(index); reads += 1; return .init() })
            finished += 1
            return grant
        } }
        defer {
            for choice in choices { choice.cancel() }
            for sheet in window.sheets { sheet.cancelOperation(nil) }
        }
        try await TestSupport.eventually { window.attachedSheet != nil && started.count == count }
        window.close()
        try await TestSupport.eventually(diagnostic: "Closing the parent must finish every consent presenter: \(finished)/\(count)") { finished == count }
        for choice in choices {
            let grant = await choice.value
            XCTAssertNil(grant)
        }
        XCTAssertNil(window.attachedSheet)
        let finalReads = reads
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(reads, finalReads)
    }

    private func prompt(current: SSHIntegrationGrant? = nil, destination: String = "ops@127.0.0.1",
                        reconnect: (() -> Void)? = nil,
                        reconnectRequirements: Set<SSHIntegrationFeature> = [],
                        activeGrants: [SSHIntegrationGrant]? = nil,
                        connectionState: (() -> SSHIntegrationConsent.ConnectionState)? = nil,
                        action: @MainActor (NSWindow, [NSButton]) async throws -> Void) async throws -> SSHIntegrationGrant? {
        AppFont.register()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let scope = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: destination,
                                                     configuration: "user ops\nhostname 127.0.0.1\n"))
        let task = Task { await SSHIntegrationConsent.present(scope, current: current, window: window,
                                                             status: current == nil ? nil : "Connected · helper running · 4 features on", reconnect: reconnect, reconnectRequirements: reconnectRequirements, activeGrants: activeGrants, connectionState: connectionState) }
        defer { task.cancel() }
        try await TestSupport.eventually { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let root = try XCTUnwrap(sheet.contentView)
        root.layoutSubtreeIfNeeded()
        let buttons = PresentationTestSupport.views(of: NSButton.self, in: root)
        XCTAssertEqual(Array(buttons.prefix(6).map(\.title)), ["Upload the Dispatch helper", "Stats", "File access", "Codex", "Claude", "Pi"])
        XCTAssertEqual(sheet.frame.width, 460, accuracy: 1)
        for button in buttons {
            XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)), button.title)
        }
        _ = try await PresentationTestSupport.capture(sheet, named: current == nil ? "ssh-consent-tree" : "ssh-consent-tree-edit")
        try await action(sheet, buttons)
        let selection = await task.value
        lastAgents = selection?.agents
        return selection?.grant
    }

    private func click(_ title: String, _ buttons: [NSButton]) throws {
        try XCTUnwrap(buttons.first { $0.title == title }).performClick(nil)
    }

    func testFeatureSelectionsWaitForConnectAndParentPreservesChildren() async throws {
        let result = try await prompt { sheet, buttons in
            try click("File access", buttons)
            XCTAssertNotNil(sheet.sheetParent)
            try click("Upload the Dispatch helper", buttons)
            XCTAssertTrue(buttons.dropFirst().prefix(5).allSatisfy { !$0.isEnabled })
            try click("Upload the Dispatch helper", buttons)
            XCTAssertEqual(buttons.first { $0.title == "File access" }?.state, .off)
            try click("Connect", buttons)
        }
        XCTAssertEqual(result?.selectedFeatures, Set(SSHIntegrationFeature.allCases).subtracting([.files, .git]))
        XCTAssertTrue(result?.isCurrent == true)
        XCTAssertEqual(lastAgents, [.codex: true, .claude: true, .pi: true])
    }

    func testAgentChoicesAnswerHookSetupInTheSameSheet() async throws {
        let some = try await prompt { _, buttons in
            try click("Claude", buttons)
            try click("Connect", buttons)
        }
        XCTAssertEqual(lastAgents, [.codex: true, .claude: false, .pi: true])
        XCTAssertTrue(some?.hooks == true)
        let none = try await prompt { _, buttons in
            for title in ["Codex", "Claude", "Pi"] { try click(title, buttons) }
            try click("Connect", buttons)
        }
        XCTAssertEqual(lastAgents, [.codex: false, .claude: false, .pi: false])
        XCTAssertFalse(none?.selectedFeatures.contains(.hooks) ?? true, "No agent means no hook permission")
        XCTAssertTrue(none?.selectedFeatures.isSuperset(of: [.chat, .tmux, .herdr]) == true, "Chat, tmux and herdr come with the helper")
        let ordinary = try await prompt { _, buttons in
            try click("Upload the Dispatch helper", buttons)
            try click("Connect", buttons)
        }
        XCTAssertEqual(ordinary?.profile, .ordinary)
        XCTAssertEqual(lastAgents, [:], "Plain SSH records no agent answers")
    }

    func testStoredAgentAnswersPreloadAndSkipLaterPrompts() async throws {
        let store = SSHIntegrationPermissions(defaults: nil)
        let target = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "fixture", configuration: "user alice\n"))
        store.save(SSHIntegrationSelection(grant: .init(helperEnabled: true, features: Set(SSHIntegrationFeature.allCases)),
                                           agents: [.codex: false, .claude: true, .pi: true]), for: target)
        XCTAssertEqual(store.agentHooks(target), [.codex: false, .claude: true, .pi: true])
        for agent in SSHHookAgent.allCases {
            let answer = await store.chooseHooks(target, agent: agent) { XCTFail("Answered in the consent sheet"); return nil }
            XCTAssertEqual(answer, agent != .codex)
        }
    }

    func testPlainSSHAndCancellation() async throws {
        let ordinary = try await prompt { _, buttons in
            try click("Upload the Dispatch helper", buttons)
            try click("Connect", buttons)
        }
        XCTAssertEqual(ordinary?.profile, .ordinary)
        let cancelled = try await prompt { _, buttons in try click("Don't connect", buttons) }
        XCTAssertNil(cancelled)
    }

    func testReturnSavesAllFeaturesAndEscapeDiscardsEdits() async throws {
        let allFeatures = try await prompt { sheet, buttons in
            XCTAssertTrue(buttons.prefix(6).allSatisfy { $0.state == .on })
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertTrue(sheet.performKeyEquivalent(with: event))
        }
        XCTAssertEqual(allFeatures?.selectedFeatures, Set(SSHIntegrationFeature.allCases))
        let cancelled = try await prompt(current: .init(profile: .full, hooks: true),
                                         destination: String(repeating: "long-host-", count: 20)) { sheet, buttons in
            try click("Stats", buttons)
            sheet.cancelOperation(nil)
        }
        XCTAssertNil(cancelled)
    }

    func testModifiedReturnDoesNotSaveIntegrationDraft() async throws {
        let result = try await prompt(current: .init(profile: .full, hooks: true)) { sheet, buttons in
            try click("Stats", buttons)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            sheet.keyDown(with: event)
            XCTAssertNotNil(sheet.sheetParent, "Modified Return must not commit the integration draft")
            sheet.cancelOperation(nil)
        }
        XCTAssertNil(result)
    }

    func testModifiedKeysDoNotChangeOrDismissIntegrationDraft() async throws {
        let result = try await prompt(current: .init(profile: .full, hooks: true)) { sheet, buttons in
            let helper = try XCTUnwrap(buttons.first { $0.title == "Upload the Dispatch helper" })
            XCTAssertTrue(sheet.makeFirstResponder(helper))
            for (code, character): (UInt16, String) in [(36, "\r"), (53, "\u{1b}"), (49, " ")] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
                    windowNumber: sheet.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
                if !sheet.performKeyEquivalent(with: event) { sheet.sendEvent(event) }
                XCTAssertNotNil(sheet.sheetParent, "Modified key \(code) must leave the draft open")
                XCTAssertEqual(helper.state, .on, "Modified key \(code) must not toggle helper permission")
            }
            let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            sheet.sendEvent(space)
            XCTAssertEqual(helper.state, .off, "Unmodified Space must still toggle the focused choice")
            sheet.cancelOperation(nil)
        }
        XCTAssertNil(result)
    }

    func testDisablingHelperMovesFocusOutOfDisabledFeature() async throws {
        let result = try await prompt(current: .init(profile: .full, hooks: true)) { sheet, buttons in
            let helper = try XCTUnwrap(buttons.first { $0.title == "Upload the Dispatch helper" })
            let stats = try XCTUnwrap(buttons.first { $0.title == "Stats" })
            XCTAssertTrue(sheet.makeFirstResponder(stats))
            helper.performClick(nil)
            XCTAssertFalse(stats.isEnabled)
            XCTAssertTrue(sheet.firstResponder === helper, "Focus must move to an enabled control when its feature is disabled")
            let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            sheet.sendEvent(space)
            XCTAssertEqual(helper.state, .on)
            XCTAssertTrue(stats.isEnabled)
            XCTAssertEqual(stats.state, .on)
            try click("Save", buttons)
        }
        XCTAssertEqual(result?.selectedFeatures, Set(SSHIntegrationFeature.allCases))
    }

    func testConnectionChangeMovesFocusOutOfHiddenReconnectButton() async throws {
        var live = SSHIntegrationConsent.ConnectionState(grants: [.init(profile: .statistics)])
        var reconnects = 0
        let result = try await prompt(current: .init(profile: .full, hooks: true),
            reconnect: { reconnects += 1 }, activeGrants: live.grants, connectionState: { live }) { sheet, buttons in
            let reconnect = try XCTUnwrap(buttons.first { $0.title == "Save & reconnect" })
            XCTAssertTrue(sheet.makeFirstResponder(reconnect))
            live.grants = []
            try await TestSupport.eventually { reconnect.isHidden }
            let focused = try XCTUnwrap(sheet.firstResponder as? NSButton, "Focus should remain on a usable control")
            XCTAssertTrue(focused.isEnabled)
            XCTAssertFalse(focused.isHidden)
            XCTAssertTrue(focused.window === sheet)
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertTrue(sheet.performKeyEquivalent(with: enter))
        }
        XCTAssertEqual(result?.selectedFeatures, Set(SSHIntegrationFeature.allCases))
        XCTAssertEqual(reconnects, 0)
    }

    func testReconnectIsHiddenForUnchangedSettingsReductionsAndRevertedEdits() async throws {
        var reconnects = 0
        _ = try await prompt(current: .init(profile: .statistics), reconnect: { reconnects += 1 }) { sheet, buttons in
            @MainActor func reconnectButton() -> NSButton? {
                let root = sheet.contentView!
                let stacks = PresentationTestSupport.views(of: NSStackView.self, in: root)
                let all = PresentationTestSupport.views(of: NSButton.self, in: root)
                    + stacks.flatMap { $0.detachedViews.compactMap { $0 as? NSButton } }
                return all.first { $0.title == "Save & reconnect" }
            }
            // A stats-only grant lacks the helper's implied features; opening
            // it must not present them as pending additions.
            XCTAssertTrue(reconnectButton()?.isHidden ?? true)
            try click("Stats", buttons)
            XCTAssertTrue(reconnectButton()?.isHidden ?? true)
            try click("File access", buttons)
            XCTAssertEqual(reconnectButton()?.isHidden, false)
            XCTAssertEqual(reconnectButton()?.isEnabled, true)
            try click("Upload the Dispatch helper", buttons)
            XCTAssertTrue(reconnectButton()?.isHidden ?? true)
            try click("Save", buttons)
        }
        XCTAssertEqual(reconnects, 0)
    }

    func testReconnectRequiresFeaturesForExistingNativeSessions() async throws {
        let result = try await prompt(current: .init(profile: .full, hooks: true), reconnect: {}, reconnectRequirements: [.tmux],
            activeGrants: [.init(helperEnabled: true, features: [.tmux])]) { _, buttons in
            let reconnect = try XCTUnwrap(buttons.first { $0.title == "Save & reconnect" })
            XCTAssertTrue(reconnect.isEnabled, "tmux comes with the helper, so native sessions can reconnect")
            try click("Upload the Dispatch helper", buttons)
            XCTAssertTrue(reconnect.isHidden)
            try click("Upload the Dispatch helper", buttons)
            XCTAssertTrue(reconnect.isEnabled)
            try click("Save", buttons)
        }
        XCTAssertTrue(result?.selectedFeatures.contains(.tmux) ?? false)
    }

    func testDefaultsAreDraftUntilSaveAndReconnectIsExplicit() async throws {
        var reconnects = 0
        let result = try await prompt(current: .init(profile: .full, hooks: true), reconnect: { reconnects += 1 },
            activeGrants: [.init(profile: .statistics)]) { sheet, buttons in
            let defaults = try XCTUnwrap(buttons.first { $0.title == "Use defaults" })
            XCTAssertFalse(defaults.isEnabled)
            XCTAssertEqual(defaults.toolTip, "Already using defaults")
            try click("Stats", buttons)
            XCTAssertTrue(defaults.isEnabled)
            XCTAssertNotEqual(defaults.toolTip, "Already using defaults")
            try click("Use defaults", buttons)
            XCTAssertFalse(defaults.isEnabled)
            XCTAssertEqual(defaults.toolTip, "Already using defaults")
            try click("Upload the Dispatch helper", buttons)
            XCTAssertTrue(defaults.isEnabled)
            try click("Use defaults", buttons)
            XCTAssertFalse(defaults.isEnabled)
            XCTAssertNotNil(sheet.sheetParent)
            XCTAssertEqual(reconnects, 0)
            XCTAssertEqual(buttons.first { $0.title == "Stats" }?.state, .on)
            XCTAssertTrue(buttons.prefix(6).allSatisfy { $0.state == .on })
            try click("Save & reconnect", buttons)
        }
        XCTAssertEqual(result?.selectedFeatures, Set(SSHIntegrationFeature.allCases))
        XCTAssertEqual(reconnects, 1)
    }

    func testMixedConnectionsRequireEveryNativeFeatureBeforeReconnect() async throws {
        for requirements: Set<SSHIntegrationFeature> in [[.herdr], [.tmux, .herdr]] {
            var reconnects = 0
            // An older saved grant without the native features cannot reconnect
            // those sessions until the helper's implied features are restored.
            let saved = SSHIntegrationGrant(helperEnabled: true, features: Set(SSHIntegrationFeature.allCases).subtracting([.tmux, .herdr]))
            let result = try await prompt(current: saved,
                reconnect: { reconnects += 1 }, reconnectRequirements: requirements,
                activeGrants: [.init(helperEnabled: true, features: Set(SSHIntegrationFeature.allCases)),
                               .init(helperEnabled: true, features: requirements)]) { _, buttons in
                let reconnect = try XCTUnwrap(buttons.first { $0.title == "Save & reconnect" })
                XCTAssertFalse(reconnect.isHidden, "An upgrade needed by one connection must not be hidden by another's full grant")
                XCTAssertFalse(reconnect.isEnabled)
                reconnect.performClick(nil)
                XCTAssertEqual(reconnects, 0)
                try click("Use defaults", buttons)
                XCTAssertTrue(reconnect.isEnabled)
                try click("Save & reconnect", buttons)
            }
            XCTAssertEqual(reconnects, 1)
            XCTAssertEqual(result?.selectedFeatures, Set(SSHIntegrationFeature.allCases))
        }
    }

    func testReconnectRevalidatesNativeRequirementsAtActivation() async throws {
        var live = SSHIntegrationConsent.ConnectionState(grants: [.init(profile: .statistics)])
        var reconnects = 0
        let result = try await prompt(current: .init(helperEnabled: true, features: Set(SSHIntegrationFeature.allCases).subtracting([.tmux])),
            reconnect: { reconnects += 1 }, activeGrants: live.grants, connectionState: { live }) { sheet, buttons in
            let reconnect = try XCTUnwrap(buttons.first { $0.title == "Save & reconnect" })
            XCTAssertTrue(reconnect.isEnabled)
            // No suspension: the periodic refresh cannot run between this
            // state change and activation of the still-enabled button.
            live.requirements = [.tmux]
            reconnect.performClick(nil)
            XCTAssertFalse(reconnect.isEnabled)
            XCTAssertNotNil(sheet.sheetParent, "Stale reconnect activation must keep the draft open")
            sheet.cancelOperation(nil)
        }
        XCTAssertNil(result)
        XCTAssertEqual(reconnects, 0)
    }

    func testDefaultsRemainAccurateAcrossLiveConnectionChanges() async throws {
        var live = SSHIntegrationConsent.ConnectionState(grants: [.init(profile: .statistics)])
        var reconnects = 0
        let result = try await prompt(current: .init(profile: .full, hooks: true),
            reconnect: { reconnects += 1 }, activeGrants: live.grants, connectionState: { live }) { sheet, buttons in
            let defaults = try XCTUnwrap(buttons.first { $0.title == "Use defaults" })
            let reconnect = try XCTUnwrap(buttons.first { $0.title == "Save & reconnect" })
            try click("Upload the Dispatch helper", buttons)
            XCTAssertTrue(defaults.isEnabled)
            live.grants = []
            try await TestSupport.eventually {
                PresentationTestSupport.views(of: NSTextField.self, in: try! XCTUnwrap(sheet.contentView))
                    .contains { $0.stringValue.hasPrefix("Disconnected ·") }
            }
            XCTAssertTrue(defaults.isEnabled, "Disconnect must preserve the helper-disabled draft")
            try click("Use defaults", buttons)
            XCTAssertFalse(defaults.isEnabled)
            XCTAssertEqual(defaults.toolTip, "Already using defaults")
            XCTAssertTrue(reconnect.isHidden)
            live.grants = [.init(profile: .statistics)]
            try await TestSupport.eventually { !reconnect.isHidden }
            XCTAssertFalse(defaults.isEnabled)
            XCTAssertTrue(reconnect.isEnabled)
            live.grants = [.init(profile: .full, hooks: true)]
            try await TestSupport.eventually { reconnect.isHidden }
            XCTAssertFalse(defaults.isEnabled)
            XCTAssertEqual(defaults.toolTip, "Already using defaults")
            try click("Save", buttons)
        }
        XCTAssertEqual(result?.selectedFeatures, Set(SSHIntegrationFeature.allCases))
        XCTAssertEqual(reconnects, 0)
    }

    func testConnectionTransitionsPreserveDraftAndStopRefreshingAfterClose() async throws {
        for save in [false, true] {
            var live = SSHIntegrationConsent.ConnectionState()
            var reads = 0, reconnects = 0
            let result = try await prompt(current: .init(profile: .full, hooks: true),
                reconnect: { reconnects += 1 }, activeGrants: [], connectionState: { reads += 1; return live }) { sheet, buttons in
                let root = try XCTUnwrap(sheet.contentView)
                @MainActor func reconnectButton() -> NSButton? {
                    let stacks = PresentationTestSupport.views(of: NSStackView.self, in: root)
                    return (PresentationTestSupport.views(of: NSButton.self, in: root)
                        + stacks.flatMap { $0.detachedViews.compactMap { $0 as? NSButton } })
                        .first { $0.title == "Save & reconnect" }
                }
                try click(SSHIntegrationFeature.files.title, buttons)
                let files = try XCTUnwrap(buttons.first { $0.title == SSHIntegrationFeature.files.title })
                for connected in [false, true, false, true] {
                    live.grants = connected ? [.init(profile: .statistics)] : []
                    try await TestSupport.eventually {
                        let labels = PresentationTestSupport.views(of: NSTextField.self, in: root)
                        let status = connected ? "Connected ·" : "Disconnected ·"
                        return labels.contains { $0.stringValue.hasPrefix(status) }
                            && (reconnectButton()?.isHidden ?? true) == !connected
                    }
                    XCTAssertEqual(files.state, .off, "Connection updates must preserve unsaved feature edits")
                    if connected { XCTAssertEqual(reconnectButton()?.isEnabled, true) }
                }
                if save { try click("Save", buttons) }
                else { sheet.cancelOperation(nil) }
            }
            XCTAssertEqual(result?.selectedFeatures, save ? Set(SSHIntegrationFeature.allCases).subtracting([.files, .git]) : nil)
            XCTAssertEqual(reconnects, 0)
            let finalReads = reads
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(reads, finalReads, "Closing the sheet must stop its connection refresh task")
        }
    }
}
