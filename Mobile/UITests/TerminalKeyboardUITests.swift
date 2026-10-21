import XCTest

/// The terminal with a hardware keyboard and without (docs/ios.md, Terminal): the Spaces sample's dev tab, whose
/// scripted terminal echoes every byte it receives in caret notation on a line of its own
/// (`-DispatchTerminalEcho keys`), so a key's encoding is the screen's last line. `typeKey` sends hardware key events,
/// and `-DispatchHardwareKeyboard` pins what the app believes is attached. The capsule's collapsed form is iPad only:
/// the capsule cases skip on an iPhone.
@MainActor
final class TerminalKeyboardUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(hardwareKeyboard: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-DispatchTabsSample", "YES", "-DispatchTabsShow", "tab:herdr:app:2",
                               "-DispatchHardwareKeyboard", hardwareKeyboard ? "YES" : "NO",
                               "-DispatchTerminalEcho", "keys", "-terminal.keysShown", "NO", "-appearance", "dark"]
        app.launch()
        return app
    }

    private func terminal(_ app: XCUIApplication) -> XCUIElement {
        let terminal = app.textViews["Terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "the dev tab's terminal")
        return terminal
    }

    /// The terminal's last non-empty line: the caret notation of the last input it received.
    private func lastLine(_ terminal: XCUIElement) -> String {
        let text = terminal.value as? String ?? ""
        return text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private func expect(_ terminal: XCUIElement, _ expected: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if lastLine(terminal) == expected { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("\(what): expected \(expected), the terminal shows \(lastLine(terminal))", file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Hardware keys reach the program with the Mac's encoding: text, Tab and Shift-Tab, arrows with modifiers, Ctrl
    /// and Alt (Option) chords, Ctrl-Space (which iPadOS keeps from key commands), and a Ctrl chord with Caps Lock
    /// on. XCUITest's key synthesizer on the iOS 27.0 simulator delivers no event at all for Esc, Return, Backspace,
    /// Home, End, Page Up and Down and forward delete, and shifts F-keys down by one (F2 arrives as F1):
    /// `TerminalIPadTests.testEveryHardwareKeyHasAnEnabledCommand` covers those through the commands themselves.
    func testHardwareKeysReachTheProgram() {
        continueAfterFailure = true
        let app = launch(hardwareKeyboard: true)
        let terminal = terminal(app)
        terminal.tap()
        let cases: [(String, XCUIElement.KeyModifierFlags, String, String)] = [
            ("l", [], "l", "a letter"),
            (XCUIKeyboardKey.tab.rawValue, [], "^I", "Tab"),
            (XCUIKeyboardKey.tab.rawValue, .shift, "^[[Z", "Shift-Tab"),
            (XCUIKeyboardKey.upArrow.rawValue, [], "^[[A", "Up"),
            (XCUIKeyboardKey.leftArrow.rawValue, .option, "^[[1;3D", "Alt-Left"),
            (XCUIKeyboardKey.rightArrow.rawValue, .shift, "^[[1;2C", "Shift-Right"),
            (XCUIKeyboardKey.downArrow.rawValue, .control, "^[[1;5B", "Ctrl-Down"),
            (XCUIKeyboardKey.upArrow.rawValue, [.control, .shift, .option], "^[[1;8A", "Ctrl-Alt-Shift-Up"),
            ("c", .control, "^C", "Ctrl-C"),
            // Ghostty's (and so the Mac's) encoding: Ctrl-[ is not Esc's byte.
            ("[", .control, "^[[91;5u", "Ctrl-["),
            (" ", .control, "^@", "Ctrl-Space"),
            ("b", .option, "^[b", "Alt-B"),
            ("a", [.option, .shift], "^[A", "Alt-Shift-A"),
            ("d", [.control, .capsLock], "^D", "Ctrl-D with Caps Lock on"),
        ]
        for (key, flags, expected, what) in cases {
            terminal.typeKey(key, modifierFlags: flags)
            expect(terminal, expected, what)
        }
        attach(app, "Hardware keys")
    }

    /// ⌘A selects the screen, ⌘C copies it and ⌘V pastes it back (the standard responder actions, as the Mac's
    /// Edit menu): the program gets the screen's text.
    func testCommandCopyAndPaste() {
        let app = launch(hardwareKeyboard: true)
        let terminal = terminal(app)
        terminal.tap()
        // The screen's text first, and a key that lands (the first hardware event after the software keyboard can
        // go to switching input modes), then each chord once the last one landed.
        XCTAssertTrue(terminal.waitForValue(containing: "invoices.ts"))
        terminal.typeKey("l", modifierFlags: [])
        expect(terminal, "l", "a key before the chords")
        for key in ["a", "c", "v"] {
            terminal.typeKey(key, modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.5)
        }
        // "stripe" shows twice on the dev server's screen; the paste echoes it twice more.
        let count = { (terminal.value as? String ?? "").components(separatedBy: "stripe").count - 1 }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, count() < 4 { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThanOrEqual(count(), 4, "the pasted screen: \(terminal.value as? String ?? "")")
    }

    /// Holding ⌘ lists the app's shortcuts, never the terminal's hundreds of Ctrl and Alt chords (they have no titles).
    func testCommandHoldListsNoTerminalChords() {
        let app = launch(hardwareKeyboard: true)
        let terminal = terminal(app)
        terminal.tap()
        XCUIElement.perform(withKeyModifiers: .command) {
            Thread.sleep(forTimeInterval: 2)
            self.attach(app, "Command held")
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'keyCommand'")).count, 0)
        }
    }

    /// With a hardware keyboard on an iPad the capsule collapses to a small button that gives the terminal its rows;
    /// the button brings the full capsule back and its last key collapses it again.
    func testCapsuleCollapsesWithAHardwareKeyboard() throws {
        try XCTSkipUnless(isPad, "the collapsed capsule is iPad only")
        let app = launch(hardwareKeyboard: true)
        let terminal = terminal(app)
        terminal.tap()
        let show = app.buttons["Show terminal keys"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Control"].exists, "no full capsule with a hardware keyboard")
        attach(app, "Collapsed capsule")
        show.tap()
        XCTAssertTrue(app.buttons["Control"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Escape"].exists)
        attach(app, "Expanded capsule")
        app.buttons["Escape"].tap()
        expect(terminal, "^[", "the capsule's Esc")
        app.buttons["Hide terminal keys"].tap()
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Control"].exists)
    }

    /// Without a hardware keyboard the full capsule shows; it rides above the docked software keyboard (whose
    /// shortcut bar is gone) and stays at the bottom under a floating one (an iPad: a pinch floats and docks it).
    func testCapsuleWithTheSoftwareKeyboard() {
        let app = launch(hardwareKeyboard: false)
        let terminal = terminal(app)
        XCTAssertTrue(app.buttons["Control"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Show terminal keys"].exists)
        let resting = app.buttons["Control"].frame
        terminal.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "the software keyboard")
        let window = app.windows.firstMatch.frame
        var floating = false
        // Docked again even when a step fails: iPadOS keeps a floating keyboard for the next launches.
        addTeardownBlock { @MainActor in
            if app.state == .runningForeground, app.keyboardFloats { app.setKeyboardFloating(false) }
        }
        for step in 0..<(isPad ? 3 : 1) {
            if step > 0 {
                keyboard.pinch(withScale: floating ? 2.5 : 0.4, velocity: floating ? 2 : -2)
            }
            Thread.sleep(forTimeInterval: 1.5)
            floating = keyboard.frame.width < window.width - 1
            attach(app, floating ? "Floating keyboard" : "Docked keyboard")
            let capsule = app.buttons["Control"].frame
            if floating {
                XCTAssertEqual(capsule.minY, resting.minY, accuracy: 1, "at the bottom under a floating keyboard")
            } else {
                XCTAssertLessThanOrEqual(capsule.maxY, keyboard.frame.minY + 1, "above the docked keyboard")
                XCTAssertGreaterThan(capsule.maxY, keyboard.frame.minY - 30, "riding on it: no shortcut bar between")
            }
        }
        // iPadOS keeps a floating keyboard across launches: the next run (Chat's docked-keyboard cases) must find it
        // docked.
        if floating {
            XCTAssertTrue(app.setKeyboardFloating(false),
                          "docked again: \(app.keyboards.firstMatch.frame) in \(app.windows.firstMatch.frame)")
            // The capsule rides up with the docking keyboard: tapped while it moves, the tap missed the latch.
            Thread.sleep(forTimeInterval: 1)
        }
        app.buttons["Control"].tap()
        terminal.typeKey("c", modifierFlags: [])
        expect(terminal, "^C", "the capsule's Ctrl latch")
    }
}

private extension XCUIElement {
    func waitForValue(containing text: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (value as? String)?.contains(text) == true { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
