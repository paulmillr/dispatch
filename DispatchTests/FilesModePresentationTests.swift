import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// The strip's mode button in each of its states, hosted as a strip hosts it: what
/// VoiceOver reads, where a click goes, and a capture of each for review.
@MainActor
final class FilesModePresentationTests: XCTestCase {
    func testModeButtonNamesTheNextStepInEveryMode() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()), defaults: nil)
        let files = FilesCoordinator { [weak chat] in chat }
        chat.pairedFiles = files
        let agent = chat.session(for: System.uuid()), shell = chat.session(for: System.uuid())
        agent.sessionID = "files-presentation"; agent.active = true
        defer { chat.close(agent.id); chat.close(shell.id) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: HStack(spacing: 12) {
            ChatModeSwitch(session: agent, coordinator: chat).fixedSize()
            ChatModeSwitch(session: shell, coordinator: chat).fixedSize()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Chrome.window).preferredColorScheme(.dark))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)

        func labels() -> [String] {
            ["Show Chat", "Show Files", "Show Terminal"].flatMap { label in
                PresentationTestSupport.accessibilityFrames("chat-mode-switch", label: label, in: window).filter { !$0.isEmpty }.map { _ in label }
            }
        }
        func settle(_ expected: [String], _ name: String) async throws {
            try await TestSupport.eventually(diagnostic: "labels: \(labels())") { labels().sorted() == expected.sorted() }
            try await System.sleep(for: .seconds(InterfaceMotion.modeSwitchDuration + 0.1), "files.mode.switch")
            _ = try await PresentationTestSupport.capture(window, named: name, in: "files-mode")
        }
        // a: a shell tab's muted folder opens files; an agent tab's muted bubble opens chat.
        try await settle(["Show Chat", "Show Files"], "terminal")
        // b: chat lit; the click returns to the terminal, while the shell tab still offers files.
        files.cycle(agent.id)
        try await settle(["Show Terminal", "Show Files"], "chat")
        // c: files lit on both (⇧⌘F on the agent tab, a click on the shell's); the click returns to the terminal.
        files.toggleFiles(agent.id); files.cycle(shell.id)
        XCTAssertEqual(files.mode(for: agent.id), .files); XCTAssertFalse(agent.showChat)
        try await settle(["Show Terminal", "Show Terminal"], "files")

        // A click on the button itself takes one step.
        let frame = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("chat-mode-switch", label: "Show Terminal", in: window).first)
        try PresentationTestSupport.click(window, at: NSPoint(x: frame.midX, y: frame.midY))
        try await TestSupport.eventually { files.mode(for: agent.id) == .terminal || files.mode(for: shell.id) == .terminal }
    }

    /// The menu a hold (or a right-click) opens lists the modes and the three files tabs, the shown one checked; Changes
    /// and Commits are enabled only where the View menu's ⇧⌘U and ⇧⌘L are (F1a).
    func testModeMenuListsTheFilesTabsInsideARepository() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()), defaults: nil)
        let files = FilesCoordinator { [weak chat] in chat }
        chat.pairedFiles = files
        let agent = chat.session(for: System.uuid())
        agent.sessionID = "files-presentation"; agent.active = true
        defer { chat.close(agent.id) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatModeSwitch(session: agent, coordinator: chat).fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Chrome.window).preferredColorScheme(.dark))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)

        let root = try XCTUnwrap(window.contentView)
        try await TestSupport.eventually(diagnostic: "no press tracker under the switch") {
            root.layoutSubtreeIfNeeded()
            return !PresentationTestSupport.views(of: ModeSwitchPressTracker.TrackerView.self, in: root).isEmpty
        }
        let tracker = try XCTUnwrap(PresentationTestSupport.views(of: ModeSwitchPressTracker.TrackerView.self, in: root).first)
        func menu() -> [(title: String, on: Bool, enabled: Bool)] {
            tracker.modesMenu().items.map { ($0.title, $0.state == .on, $0.isEnabled) }
        }
        func titles() -> [String] { menu().map(\.title) }
        func checked() -> [String] { menu().filter(\.on).map(\.title) }
        func enabled() -> [String] { menu().filter(\.enabled).map(\.title) }
        let all = ["Terminal", "Chat", "Files", "Review", "Commits"]
        // The tracker's menu reads the switch's state as SwiftUI last drew it, so a change shows after the next update.
        func expect(_ on: [String], enabled expected: [String] = all, file: StaticString = #filePath,
                    line: UInt = #line) async throws {
            try await TestSupport.eventually(file: file, line: line, diagnostic: "menu: \(menu())") {
                titles() == all && checked() == on && enabled() == expected
            }
        }
        func choose(_ title: String) throws {
            let menu = tracker.modesMenu()
            menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == title }, "no \(title) in the menu"))
        }

        // Not resolved yet: every tab may open. Outside a repository the git tabs are listed but disabled.
        try await expect(["Terminal"])
        let session = files.session(for: agent.id)
        session.git = .none
        try await expect(["Terminal"], enabled: ["Terminal", "Chat", "Files"])

        session.git = .repository(GitRepository(root: "/Users/ivan/src/api"))
        try await expect(["Terminal"])
        // Choosing from the menu: Review opens files on its tab from the terminal; the button lights.
        try choose("Review")
        XCTAssertEqual(files.mode(for: agent.id), .files)
        XCTAssertEqual(session.tab, .changes)
        try await expect(["Review"])
        try await TestSupport.eventually(diagnostic: "the switch does not offer the terminal") {
            !PresentationTestSupport.accessibilityFrames("chat-mode-switch", label: "Show Terminal", in: window).isEmpty
        }
        session.select(.commits)
        try await expect(["Commits"])
        try choose("Files")
        XCTAssertEqual(session.tab, .files)
        try await expect(["Files"])
        _ = try await PresentationTestSupport.capture(window, named: "files-tabs-menu", in: "files-mode")
        try choose("Chat")
        try await expect(["Chat"])
        try choose("Commits")
        XCTAssertEqual(files.mode(for: agent.id), .files, "from chat as well")
        try await expect(["Commits"])

        // The shell left the repository while Commits showed: the tab falls back and the git items disable.
        session.git = .none
        XCTAssertEqual(session.tab, .files)
        try await expect(["Files"], enabled: ["Terminal", "Chat", "Files"])
    }
}
