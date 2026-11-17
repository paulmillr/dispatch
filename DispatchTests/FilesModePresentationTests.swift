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
        // a: a shell tab's muted folder opens files (its click lists the files tabs); an agent tab's muted bubble opens
        // chat.
        try await settle(["Show Chat", "Show Files"], "terminal")
        // The trackers left to right, the agent's then the shell's.
        func trackers() -> [ModeSwitchPressTracker.TrackerView] {
            guard let root = window.contentView else { return [] }
            root.layoutSubtreeIfNeeded()
            return PresentationTestSupport.views(of: ModeSwitchPressTracker.TrackerView.self, in: root)
                .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        }
        try await TestSupport.eventually(diagnostic: "trackers: \(trackers().count)") { trackers().count == 2 }
        // b: chat lit; the click returns to the terminal, while the shell tab still offers files.
        files.cycle(agent.id)
        try await settle(["Show Terminal", "Show Files"], "chat")
        // c: files lit on both (⇧⌘F on the agent tab, a click on the shell's); the click returns to the terminal.
        files.toggleFiles(agent.id); files.cycle(shell.id)
        XCTAssertEqual(files.mode(for: agent.id), .files); XCTAssertFalse(agent.showChat)
        try await settle(["Show Terminal", "Show Terminal"], "files")

        // A click on either button opens the modes menu, in chat, files or the terminal alike; nothing switches until a
        // mode is picked from it.
        var shown: [[String]] = []
        for tracker in trackers() { tracker.presentMenu = { menu, _, _ in shown.append(menu.items.map(\.title)) } }
        let frame = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("chat-mode-switch", label: "Show Terminal", in: window)
            .min { $0.minX < $1.minX })
        try PresentationTestSupport.click(window, at: NSPoint(x: frame.midX, y: frame.midY))
        try await TestSupport.eventually(diagnostic: "menus: \(shown)") { shown.count == 1 }
        XCTAssertEqual(shown.first?.prefix(2), ["Terminal", "Chat"])
        XCTAssertEqual(files.mode(for: agent.id), .files, "a click alone switches nothing")
    }

    /// The mode button's press tracker lies over it and takes the pointer from SwiftUI: it reports it, so the button
    /// still lights under the pointer and goes back as it leaves. Flat: a window capture cannot draw Liquid Glass.
    func testModeButtonLightsUnderThePointerThroughItsTracker() async throws {
        try DesktopTestSupport.requireUnlocked()
        let glass = LiquidGlassStore.shared.enabled
        LiquidGlassStore.shared.enabled = false
        defer { LiquidGlassStore.shared.enabled = glass }
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()), defaults: nil)
        // Paired with Files, as the app is: a shell tab's switch offers Files, so it is not dimmed (a dimmed one never lights).
        let files = FilesCoordinator { [weak chat] in chat }
        chat.pairedFiles = files
        let shell = chat.session(for: System.uuid())
        defer { chat.close(shell.id) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatModeSwitch(session: shell, coordinator: chat).fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Chrome.window).preferredColorScheme(.dark))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        let root = try XCTUnwrap(window.contentView)
        var tracker: ModeSwitchPressTracker.TrackerView?
        try await TestSupport.eventually {
            root.layoutSubtreeIfNeeded()
            tracker = PresentationTestSupport.views(of: ModeSwitchPressTracker.TrackerView.self, in: root).first
            return tracker != nil
        }
        let button = try XCTUnwrap(tracker).convert(try XCTUnwrap(tracker).bounds, to: nil)
        // Inside the button, clear of its glyph.
        let point = NSPoint(x: button.minX + 3, y: button.midY)
        func pixel(_ name: String) async throws -> NSColor {
            try await System.sleep(for: .seconds(0.2), "mode.switch.hover")
            let bitmap = try await PresentationTestSupport.capture(window, named: name, in: "mode-switch-hover").bitmap
            let scale = CGFloat(bitmap.pixelsWide) / root.bounds.width
            return try XCTUnwrap(bitmap.colorAt(x: Int(point.x * scale), y: Int((root.bounds.height - point.y) * scale))?
                .usingColorSpace(.sRGB))
        }
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
        }
        let idle = try await pixel("idle")
        let event = try PresentationTestSupport.mouseEvent(.mouseMoved, in: window, at: point)
        try XCTUnwrap(tracker).mouseEntered(with: event)
        let hovered = try await pixel("hovered")
        XCTAssertGreaterThan(distance(idle, hovered), 0.005, "the button lights under the pointer")
        try XCTUnwrap(tracker).mouseExited(with: event)
        let left = try await pixel("left")
        XCTAssertLessThan(distance(idle, left), 0.005, "and goes back as it leaves")
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
        // Each item carries the glyph the button shows for it.
        XCTAssertTrue(tracker.modesMenu().items.allSatisfy { $0.image != nil })
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
