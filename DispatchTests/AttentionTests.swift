import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class AttentionTests: XCTestCase {
    func testDisabledHostDetectionUsesOrdinarySSHWithoutChangingSavedGrant() throws {
        let runtime = TerminalRuntime.shared
        let preferences = runtime.preferences
        runtime.preferences.enableHostDetection = false
        let reply = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { runtime.preferences = preferences; try? FileManager.default.removeItem(at: reply) }
        let scope = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "attention-test", configuration: "hostname attention-test\nuser test\n"))
        let coordinator = SSHCoordinator()
        let saved = coordinator.permissions.remembered(scope)
        let request = SSHConsentRequest(id: UUID(), tabID: UUID(), token: "test", scope: scope, origin: try XCTUnwrap(AgentProcess.capture(getpid())))
        coordinator.consent(request, reply: reply)
        let response = try JSONDecoder().decode(SSHConsentResponse.self, from: Data(contentsOf: reply))
        XCTAssertEqual(response.grant?.profile, .ordinary)
        XCTAssertEqual(coordinator.permissions.remembered(scope), saved)
    }

    func testFullFeaturesPolicyAnswersNewHostsWithoutTheSheet() async throws {
        let runtime = TerminalRuntime.shared
        let preferences = runtime.preferences
        runtime.preferences.newHostPolicy = .full
        let reply = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { runtime.preferences = preferences; try? FileManager.default.removeItem(at: reply) }
        let scope = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "full-\(UUID().uuidString)",
                                                     configuration: "hostname full-policy\nuser test\n"))
        let coordinator = SSHCoordinator()
        defer { coordinator.permissions.reset(scope) }
        coordinator.presentIntegrationConsent = { _, _ in XCTFail("Full features must not show the sheet"); return nil }
        let request = SSHConsentRequest(id: UUID(), tabID: UUID(), token: "test", scope: scope, origin: try XCTUnwrap(AgentProcess.capture(getpid())))
        coordinator.consent(request, reply: reply)
        try await TestSupport.eventually { FileManager.default.fileExists(atPath: reply.path) }
        let response = try JSONDecoder().decode(SSHConsentResponse.self, from: Data(contentsOf: reply))
        XCTAssertEqual(response.grant?.selectedFeatures, Set(SSHIntegrationFeature.allCases))
        XCTAssertEqual(coordinator.permissions.remembered(scope), response.grant)
        XCTAssertEqual(coordinator.permissions.agentHooks(scope), [.codex: true, .claude: true, .pi: false], "Pi's remote extension stays opt-in")
    }

    func testPreferencesMigrateAndRoundTrip() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(old.attentionNotifications, "Notify is on by default")
        XCTAssertTrue(old.attentionDockBadge)
        XCTAssertTrue(old.attentionSound)
        XCTAssertTrue(old.enableHostDetection)
        XCTAssertTrue(old.allowRemoteClipboardWrites, "Programs on helper hosts can set the clipboard by default")
        XCTAssertFalse(old.showGitBranches)
        let large = try JSONDecoder().decode(Preferences.self, from: Data(#"{"largeSidebarItems":true}"#.utf8))
        XCTAssertTrue(large.showGitBranches, "Large sidebar items used to show branches")
        var separate = large; separate.showGitBranches = false
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(separate)).showGitBranches)
        XCTAssertEqual(old.newHostPolicy, .ask, "Existing settings keep asking")
        let plain = try JSONDecoder().decode(Preferences.self, from: Data(#"{"enableHostDetection":false}"#.utf8))
        XCTAssertEqual(plain.newHostPolicy, .plain, "The old SSH helper switch off means Plain SSH")
        for policy in NewHostPolicy.allCases {
            var preferences = old; preferences.newHostPolicy = policy
            XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)).newHostPolicy, policy)
        }
        var updated = old
        updated.attentionNotifications = true
        updated.attentionDockBadge = false
        updated.attentionSound = false
        updated.enableHostDetection = false
        updated.allowRemoteClipboardWrites = false
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(updated)), updated)
    }

    func testAttentionNavigationAndDeduplicationPreserveApprovals() async throws {
        let controller = AppDelegate(), runtime = TerminalRuntime.shared
        let previousWorkspace = runtime.workspace
        controller.settings.values = Preferences()
        // Navigation and the Dock badge only: no macOS notification permission prompt.
        controller.settings.values.attentionNotifications = false
        runtime.workspace = controller.workspace
        controller.workspace.newLocalSpace()
        let waiting = controller.workspace.activeSurfaceID!
        controller.workspace.updateTab(waiting, customTitle: "billing")
        controller.workspace.newTab()
        let unread = controller.workspace.activeSurfaceID!
        let pending = runtime.chat.session(for: waiting), done = runtime.chat.session(for: unread)
        pending.approvals = [PendingApproval(key: "approval", operation: "Run tests?") { _ in }]
        done.active = true
        done.insert(ChatItem(id: "response", kind: .assistant, text: "Done."), turnID: "turn")
        done.turns[0].ended = .now
        done.hasNewMessages = true
        let attention = controller.attention
        defer {
            attention.stop()
            runtime.chat.close(waiting); runtime.chat.close(unread)
            runtime.workspace = previousWorkspace
        }
        XCTAssertEqual(attention.waitingCount, 1)
        XCTAssertEqual(attention.unreadCount, 1)
        XCTAssertEqual(attention.banner?.id, waiting)
        XCTAssertEqual(attention.transitions(attention.entries).count, 2)
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty)
        pending.approvals = [PendingApproval(key: "another", operation: "Run build?") { _ in }]
        XCTAssertEqual(attention.transitions(attention.entries).map(\.id), [waiting])
        attention.navigate(1)
        XCTAssertEqual(controller.workspace.activeSurfaceID, waiting)
        XCTAssertTrue(pending.approvals[0].pending, "Navigation must not decide an approval")
        attention.navigate(-1)
        XCTAssertEqual(controller.workspace.activeSurfaceID, unread, "Attention navigation includes completed responses")
        XCTAssertFalse(done.hasNewMessages, "Navigating to a response reveals and marks it read")
        controller.workspace.selectSurface(unread)
        XCTAssertEqual(controller.workspace.activeSurfaceID, unread)
        XCTAssertEqual(attention.unreadCount, 0)
        attention.start()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
        controller.settings.values.attentionDockBadge = false
        try await TestSupport.eventually { NSApp.dockTile.badgeLabel == nil }
        controller.settings.values.attentionDockBadge = true
        try await TestSupport.eventually { NSApp.dockTile.badgeLabel == "1" }
        pending.approvals = []
        try await TestSupport.eventually { NSApp.dockTile.badgeLabel == nil }
        XCTAssertTrue(attention.entries.isEmpty)
        done.hasNewMessages = true
        XCTAssertEqual(attention.readyResponses.count, 1)
        attention.navigate(1)
        XCTAssertEqual(controller.workspace.activeSurfaceID, unread)
        XCTAssertEqual(attention.waitingCount, 0)
        XCTAssertTrue(attention.readyResponses.isEmpty)
        XCTAssertNil(attention.banner)
    }

    func testCompletionAlertsRequireAnEndedResponseAndDoNotRepeatAfterActivityChanges() {
        let controller = AppDelegate(), runtime = TerminalRuntime.shared
        controller.workspace.newLocalSpace()
        let id = controller.workspace.activeSurfaceID!
        let session = runtime.chat.session(for: id), attention = controller.attention
        defer { runtime.chat.close(id) }
        session.active = true
        session.activeTurnID = "first"
        session.insert(ChatItem(id: "tool", kind: .tool, text: "Checking files", completed: true), turnID: "first")
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty, "Tool output while apparently idle is not a finished response")
        session.insert(ChatItem(id: "progress", kind: .assistant, text: "I am checking the files."), turnID: "first")
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty, "Progress messages do not finish a turn")
        session.busy = true
        session.insert(ChatItem(id: "response", kind: .assistant, text: "The change is complete."), turnID: "first")
        session.turns[0].ended = .now
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty, "A stop hook may arrive before live activity ends")
        session.busy = false
        XCTAssertEqual(attention.transitions(attention.entries).map(\.id), [id])
        session.busy = true
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty)
        session.busy = false
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty, "An activity gap must not repeat the same completion")
        session.approvals = [PendingApproval(key: "approval", operation: "Continue?") { _ in }]
        XCTAssertEqual(attention.transitions(attention.entries).map(\.id), [id])
        session.approvals = []
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty, "Resolving an approval must not replay an old completion")
        session.activeTurnID = "second"
        session.insert(ChatItem(id: "next", kind: .assistant, text: "The next response."), turnID: "second")
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty)
        session.turns[1].ended = .now
        XCTAssertEqual(attention.transitions(attention.entries).map(\.id), [id], "A new completed response still alerts")
    }

    func testCompletionAlertsWaitForReliableActivityAndDoNotTreatInterruptedToolsAsResponses() {
        let controller = AppDelegate(), runtime = TerminalRuntime.shared
        controller.workspace.newLocalSpace()
        let id = controller.workspace.activeSurfaceID!
        let session = runtime.chat.session(for: id), attention = controller.attention
        defer { runtime.chat.close(id) }
        session.insert(ChatItem(id: "response", kind: .assistant, text: "A response."), turnID: "turn")
        session.turns[0].ended = .now
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty, "Disconnecting does not mean the response completed")
        session.active = true
        session.loadingHistory = true
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty)
        session.loadingHistory = false
        session.activityCheck = UUID()
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty)
        session.activityCheck = nil
        session.awaitingPromptAck = true
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty)
        session.awaitingPromptAck = false
        session.discoveryBlocked = true
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty)
        session.discoveryBlocked = false
        session.insert(ChatItem(id: "interrupted-tool", kind: .tool, text: "Still running"), turnID: "turn")
        XCTAssertTrue(attention.transitions(attention.entries).isEmpty, "An ended or aborted turn with tool output is not a completed response")
        session.insert(ChatItem(id: "final", kind: .assistant, text: "Final response."), turnID: "turn")
        XCTAssertEqual(attention.transitions(attention.entries).map(\.id), [id])
    }

    func testNotificationPreviewsStripMarkdownAndBoundLongUnicodeText() {
        XCTAssertEqual(AttentionCoordinator.preview("## Fixed\n\n**Duplicate processing** is fixed. All `12` tests pass.\n\n[Details](https://example.com)."),
                       "Fixed Duplicate processing is fixed. All 12 tests pass. Details.")
        XCTAssertEqual(AttentionCoordinator.preview("- [x] Tested\n> Ready\n\n```sh\nnpm test\n```\n---"), "Tested Ready npm test")
        let preview = AttentionCoordinator.preview(String(repeating: "👩🏽‍💻", count: 200))
        XCTAssertEqual(preview.count, 160)
        XCTAssertEqual(preview, String(repeating: "👩🏽‍💻", count: 159) + "…")
    }

    func testNotificationsPreviewResponsesAndQuestionsAndReplaceTheSamePane() throws {
        let controller = AppDelegate(), runtime = TerminalRuntime.shared
        controller.workspace.newLocalSpace()
        let id = controller.workspace.activeSurfaceID!
        controller.workspace.updateTab(id, customTitle: "billing")
        let session = runtime.chat.session(for: id), attention = controller.attention
        defer { runtime.chat.close(id) }
        session.active = true; session.sessionID = "notification-preview"
        session.insert(ChatItem(id: "response", kind: .assistant, text: "Fixed **duplicate webhook processing**. All `12` tests pass."), turnID: "turn")
        session.turns[0].ended = .now
        let entry = try XCTUnwrap(attention.entries.first)
        let response = try XCTUnwrap(attention.notificationRequest(for: entry))
        XCTAssertEqual(response.content.title, "billing · Response ready")
        XCTAssertEqual(response.content.subtitle, entry.path)
        XCTAssertEqual(response.content.body, "Fixed duplicate webhook processing. All 12 tests pass.")
        XCTAssertEqual(response.content.userInfo["row"] as? String, session.transcriptRows.first?.id)
        session.busy = true
        XCTAssertNil(attention.notificationRequest(for: entry), "Resuming work invalidates the previous alert")
        session.approvals = [PendingApproval(key: "permission", operation: "Run `npm test` to verify the webhook changes?", turnID: "turn") { _ in }]
        let permission = try XCTUnwrap(attention.notificationRequest(for: XCTUnwrap(attention.entries.first)))
        XCTAssertEqual(permission.identifier, response.identifier)
        XCTAssertEqual(permission.content.threadIdentifier, response.content.threadIdentifier)
        XCTAssertEqual(permission.content.title, "billing · Permission needed")
        XCTAssertEqual(permission.content.body, "Run npm test to verify the webhook changes?")
        let questions = ClaudeQuestions.choices([("Which **environment** should I use?", ["Staging", "Production"])])
        session.approvals = [PendingApproval(key: "question", operation: "AskUserQuestion", turnID: "turn", questions: questions) { _ in }]
        let questionEntry = try XCTUnwrap(attention.entries.first)
        let question = try XCTUnwrap(attention.notificationRequest(for: questionEntry))
        XCTAssertEqual(question.identifier, response.identifier)
        XCTAssertEqual(question.content.title, "billing · Question for you")
        XCTAssertEqual(question.content.body, "Which environment should I use?")
        XCTAssertEqual(question.content.userInfo["row"] as? String, "approval-\(session.approvals[0].id)")
        attention.openNotification(question.content.userInfo)
        XCTAssertEqual(session.scrollAnchor, "approval-\(session.approvals[0].id)")
        XCTAssertTrue(session.approvals[0].pending, "Opening a question never answers it")
        session.approvals[0].resolve(.deny)
        XCTAssertNil(attention.notificationRequest(for: questionEntry), "Resolved requests cannot produce another alert")
    }

    func testNotificationClickRevealsTheResponseAndDoesNotJumpIntoAnotherConversation() throws {
        let controller = AppDelegate(), runtime = TerminalRuntime.shared
        controller.workspace.newLocalSpace()
        let id = controller.workspace.activeSurfaceID!
        let session = runtime.chat.session(for: id), attention = controller.attention
        defer { runtime.chat.close(id) }
        session.active = true; session.sessionID = "original"
        session.insert(ChatItem(id: "response", kind: .assistant, text: "Done."), turnID: "turn")
        session.turns[0].ended = .now
        let request = try XCTUnwrap(attention.notificationRequest(for: XCTUnwrap(attention.entries.first)))
        let rowID = try XCTUnwrap(request.content.userInfo["row"] as? String)
        session.scrollAnchor = "older-row"; session.followRevision = session.revision
        var revealed: String?
        session.scrollPosition.realizeAnchor = { revealed = $0 }
        attention.openNotification(request.content.userInfo)
        XCTAssertTrue(session.showChat)
        XCTAssertEqual(session.scrollAnchor, rowID)
        XCTAssertEqual(session.scrollPosition.saved?.id, rowID)
        XCTAssertEqual(revealed, rowID)
        XCTAssertNil(session.followRevision)
        XCTAssertFalse(session.hasNewMessages)
        session.sessionID = "replacement"
        session.scrollAnchor = "new-conversation-row"; revealed = nil
        attention.openNotification(request.content.userInfo)
        XCTAssertEqual(session.scrollAnchor, "new-conversation-row")
        XCTAssertNil(revealed, "Old notifications must not scroll a replacement conversation")
    }

    func testAttentionAndSettingsPresentation() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let controller = AppDelegate(), runtime = TerminalRuntime.shared
        let previousWorkspace = runtime.workspace
        controller.settings.values = Preferences()
        runtime.workspace = controller.workspace
        controller.workspace.newLocalSpace()
        let waiting = controller.workspace.activeSurfaceID!
        controller.workspace.updateTab(waiting, customTitle: "billing")
        controller.workspace.newLocalSpace()
        let active = controller.workspace.activeSurfaceID!
        runtime.chat.session(for: waiting).approvals = [PendingApproval(key: "approval", operation: "Run tests?") { _ in }]
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: controller.workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil; window.close()
            runtime.close([waiting, active])
            runtime.workspace = previousWorkspace
        }
        try await Task.sleep(for: .milliseconds(400))
        let snapshot = try await PresentationTestSupport.capture(window, named: "attention-1e", in: "attention-validation")
        let text = try snapshot.text()
        XCTAssertTrue(text.contains("billing is waiting for input"), text)
        window.setContentSize(NSSize(width: 850, height: 1000))
        window.contentView = NSHostingView(rootView: SettingsView(store: controller.settings, workspace: controller.workspace))
        try await Task.sleep(for: .milliseconds(150))
        let root = try XCTUnwrap(window.contentView)
        let tabs = try await PresentationTestSupport.capture(window)
        // Notifications is a group on the Extra page.
        let extra = try XCTUnwrap(tabs.recognizedText().first { $0.topCandidates(1).first?.string == "Extra" })
        let point = NSPoint(x: extra.boundingBox.midX * root.bounds.width,
                            y: (root.isFlipped ? 1 - extra.boundingBox.midY : extra.boundingBox.midY) * root.bounds.height)
        try PresentationTestSupport.click(window, at: root.convert(point, to: nil))
        try await Task.sleep(for: .milliseconds(150))
        _ = try await PresentationTestSupport.capture(window, named: "settings-1o", in: "attention-validation")
        // AppKit fits the window to a 1280×832 desktop, which can clip the page:
        // read its whole scroll document rather than the visible part.
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: window.contentView!).first)
        let settingsText = try await PresentationTestSupport.capture(XCTUnwrap(scroll.documentView)).text()
        for title in ["Notify", "Dock badge", "Sound"] { XCTAssertTrue(settingsText.contains(title), settingsText) }
    }
}
