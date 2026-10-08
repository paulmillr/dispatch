import AppKit
import XCTest
@testable import DispatchApp

/// The test host is the app itself (same bundle identifier): whatever its stores persist lands in
/// the user's own defaults. While testing, the app's stores must persist nothing there.
@MainActor
final class AppDefaultsTests: XCTestCase {
    func testStateTracksMainAndVisibleWindowGeometry() {
        for style: NSWindow.StyleMask in [.titled, .borderless, .resizable] {
            for visible in [false, true] {
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                                      styleMask: style, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.orderOut(nil); window.close() }
                if visible { window.orderFront(nil) }
                let frame = window.frame, state = TestState.shared()
                window.setContentSize(NSSize(width: 400, height: 250))
                let keys = state.changes.map { $0.components(separatedBy: "].").last!.components(separatedBy: "=").first! }
                XCTAssertEqual(keys, style == .titled || visible ? ["contentBounds", "frame"] : [])
                window.setFrame(frame, display: false)
                XCTAssertEqual(state.changes, [])
                window.orderOut(nil); window.contentView = nil
                let disposed = TestState.shared()
                window.setContentSize(NSSize(width: 0, height: 0))
                XCTAssertEqual(disposed.changes, [])
                window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                window.setContentSize(NSSize(width: 300, height: 200))
                window.orderFront(nil)
                let shown = disposed.changes.map { $0.components(separatedBy: "].").last!.components(separatedBy: "=").first! }
                XCTAssertEqual(shown, ["appearance", "contentBounds", "contentMinSize", "frame", "visible"])
            }
        }
    }

    func testStateSnapshotsReportChangesAndAcceptRestoration() {
        var value = 0, keys = ["removed": "old", "changed": "before"]
        var state = TestState()
        state.capture("value") { value }
        state.captureKeys("defaults") { keys }
        XCTAssertEqual(state.changes, [])
        value = 1; keys = ["added": "new", "changed": "after"]
        XCTAssertEqual(state.changes, ["defaults leaked added=<redacted> (added)",
            "defaults leaked changed=<redacted> (changed)", "defaults leaked removed=<redacted> (removed)",
            "value leaked (changed)"])
        value = 0; keys = ["removed": "old", "changed": "before"]
        XCTAssertEqual(state.changes, [])
    }

    func testAppStoresLeaveTheUserDefaultsAlone() async throws {
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let defaults = UserDefaults.standard
        let saved = { (defaults.persistentDomain(forName: domain) ?? [:]) as! [String: NSObject] }
        let before = saved()
        // Never exercise these stores against the live defaults if the test isolation contract is
        // missing or regresses. A failure remains read-only instead of trying to repair user data.
        XCTAssertTrue(Home.testing)
        XCTAssertNil(UserDefaults.app)
        guard Home.testing, UserDefaults.app == nil else { return }
        // The stores with their default defaults, through what the tests do with them.
        let scope = try XCTUnwrap(SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "defaults-test", configuration: "hostname machine\nuser alice\n"))
        let permissions = TerminalRuntime.shared.ssh.permissions
        permissions.save(.init(profile: .full, hooks: true), for: scope)
        permissions.saveHooks(true, for: scope, agent: .codex)
        permissions.reset(scope)
        try await TerminalRuntime.shared.resetSSHState()
        let chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        try await TestSupport.integrations(["codex", "claude", "pi"], enabled: false, chat: chat)
        // Only the names of the keys that changed (never the user's values).
        let after = saved()
        let keys = Set(before.keys).union(after.keys)
        XCTAssertEqual(keys.filter { before[$0] != after[$0] }.sorted(), [])
    }
}
