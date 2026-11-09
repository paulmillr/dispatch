import Carbon.HIToolbox
import TermApple
import UserNotifications
import XCTest
@testable import DispatchApp

/// What Dispatch keeps from other apps, the lock screen and other people: keystrokes, banners, a program's clipboard
/// writes and its own files.
@MainActor final class PrivacyTests: XCTestCase {
    /// Off by default, so other apps keep their Option-only hotkeys; a choice already saved stays. On, engaged only
    /// while Dispatch is the active app, and released when either ends.
    func testSecureKeyboardEntryFollowsTheSettingAndTheActiveApp() throws {
        XCTAssertFalse(Preferences().secureKeyboardEntry)
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).secureKeyboardEntry)
        var on = Preferences(); on.secureKeyboardEntry = true
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(on)).secureKeyboardEntry)

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

    /// With the setting off, a password prompt in the focused terminal still engages it, for as long as the prompt
    /// lasts and only while Dispatch is active; another terminal losing focus changes nothing.
    func testSecureKeyboardEntryEngagesAtAPasswordPromptWithTheSettingOff() async throws {
        let (enabled, active) = (SecureKeyboardEntry.enabled, SecureKeyboardEntry.active)
        final class Owner {}
        let (terminal, other) = (Owner(), Owner())
        defer {
            SecureKeyboardEntry.blur(terminal)
            (SecureKeyboardEntry.enabled, SecureKeyboardEntry.active) = (enabled, active)
        }
        (SecureKeyboardEntry.enabled, SecureKeyboardEntry.active) = (false, true)
        var prompt = false
        SecureKeyboardEntry.focus(terminal) { prompt }
        XCTAssertFalse(SecureKeyboardEntry.engaged, "No password is being asked for")
        prompt = true
        try await TestSupport.eventually { SecureKeyboardEntry.engaged }
        XCTAssertTrue(IsSecureEventInputEnabled())
        SecureKeyboardEntry.blur(other)
        XCTAssertTrue(SecureKeyboardEntry.engaged, "Focus left a terminal that did not have it")
        SecureKeyboardEntry.active = false
        XCTAssertFalse(SecureKeyboardEntry.engaged, "Released for the app that became active")
        SecureKeyboardEntry.active = true
        XCTAssertTrue(SecureKeyboardEntry.engaged)
        prompt = false
        try await TestSupport.eventually { !SecureKeyboardEntry.engaged }
        prompt = true
        SecureKeyboardEntry.blur(terminal)
        XCTAssertFalse(SecureKeyboardEntry.engaged, "The prompt's terminal lost the keyboard")
    }

    /// A password prompt is what `getpass` leaves on the tty: lines collected, nothing echoed. A raw TUI is not one.
    func testPasswordInputIsCanonicalModeWithoutEcho() throws {
        var (master, slave) = (Int32(-1), Int32(-1))
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { close(master); close(slave) }
        var modes = termios()
        XCTAssertEqual(tcgetattr(slave, &modes), 0)
        XCTAssertFalse(Pty.passwordInput(master), "A new tty echoes")
        modes.c_lflag &= ~tcflag_t(ECHO)
        XCTAssertEqual(tcsetattr(slave, TCSANOW, &modes), 0)
        XCTAssertTrue(Pty.passwordInput(master))
        var device = stat()
        XCTAssertEqual(fstat(slave, &device), 0)
        XCTAssertTrue(System.passwordPrompt(device: UInt32(bitPattern: device.st_rdev)), "A helper's terminal, by its tty")
        XCTAssertFalse(System.passwordPrompt(device: UInt32.max))
        modes.c_lflag &= ~tcflag_t(ICANON)
        XCTAssertEqual(tcsetattr(slave, TCSANOW, &modes), 0)
        XCTAssertFalse(Pty.passwordInput(master), "Raw mode: a full-screen program")
        XCTAssertFalse(Pty.passwordInput(-1))
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
