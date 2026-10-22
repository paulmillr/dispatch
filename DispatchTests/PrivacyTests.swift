import Carbon.HIToolbox
import UserNotifications
import XCTest
@testable import DispatchApp

/// What Dispatch keeps from other apps, the lock screen and other people: keystrokes, banners, a program's clipboard
/// writes and its own files.
@MainActor final class PrivacyTests: XCTestCase {
    /// On by default; engaged only while it is on and Dispatch is the active app, and released when either ends.
    func testSecureKeyboardEntryFollowsTheSettingAndTheActiveApp() throws {
        XCTAssertTrue(Preferences().secureKeyboardEntry)
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).secureKeyboardEntry)
        var off = Preferences(); off.secureKeyboardEntry = false
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(off)).secureKeyboardEntry)

        let (enabled, active) = (SecureKeyboardEntry.enabled, SecureKeyboardEntry.active)
        defer { (SecureKeyboardEntry.enabled, SecureKeyboardEntry.active) = (enabled, active) }
        (SecureKeyboardEntry.enabled, SecureKeyboardEntry.active) = (false, false)
        SecureKeyboardEntry.enabled = true
        XCTAssertFalse(SecureKeyboardEntry.engaged, "Another app is active")
        SecureKeyboardEntry.active = true
        XCTAssertTrue(SecureKeyboardEntry.engaged)
        XCTAssertTrue(IsSecureEventInputEnabled())
        SecureKeyboardEntry.active = false
        XCTAssertFalse(SecureKeyboardEntry.engaged, "Released for the app that became active")
        SecureKeyboardEntry.active = true
        SecureKeyboardEntry.enabled = false
        XCTAssertFalse(SecureKeyboardEntry.engaged)
    }

    /// With previews hidden, a banner says only that an agent needs you: neither the pane, its folder nor the reply.
    func testHiddenNotificationPreviewsShowOnlyAPlaceholder() {
        let category = AttentionCoordinator.category
        XCTAssertEqual(category.hiddenPreviewsBodyPlaceholder, "An agent needs you")
        XCTAssertFalse(category.options.contains(.hiddenPreviewsShowTitle))
        XCTAssertFalse(category.options.contains(.hiddenPreviewsShowSubtitle))
    }

    /// A program's clipboard write is the text, marked concealed for clipboard managers.
    func testProgramClipboardWritesAreConcealed() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dispatch-test-" + System.uuid().uuidString))
        defer { pasteboard.releaseGlobally() }
        TerminalClipboard.concealed("hunter2", on: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "hunter2")
        XCTAssertTrue(pasteboard.types?.contains(TerminalClipboard.concealedType) == true)
    }

    /// Settings name the starting folder and shell: written owner-only, and an older readable file is narrowed on load.
    func testSettingsFileIsOwnerOnly() throws {
        let root = System.temporary.appendingPathComponent(System.uuid().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        func mode() throws -> Int? { (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue }
        try SettingsStore(file: file).save(Preferences())
        XCTAssertEqual(try mode(), 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        var preferences = Preferences(); preferences.cursorBlink = false
        try JSONEncoder().encode(preferences).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertFalse(SettingsStore(file: file).values.cursorBlink)
        XCTAssertEqual(try mode(), 0o600)
    }
}
