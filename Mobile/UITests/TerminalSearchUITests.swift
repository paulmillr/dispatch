import XCTest

/// The terminal's search (T1) and the key bar's menu (T2) on the Spaces sample's dev tab showing the terminal mockups'
/// screen (`-DispatchTerminalSample theme`: three lines name src/theme.ts). The menu opens from a long press on the
/// keyboard key, or a tap on the ellipsis that replaces it while the software keyboard is up; ⌘F opens the search with a
/// hardware keyboard.
@MainActor
final class TerminalSearchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    static func arguments(hardwareKeyboard: Bool, scheme: String = "dark") -> [String] {
        ["-DispatchTabsSample", "YES", "-DispatchTabsShow", "tab:herdr:app:2", "-DispatchTerminalSample", "theme",
         "-DispatchHardwareKeyboard", hardwareKeyboard ? "YES" : "NO", "-terminal.keysShown", "NO", "-appearance", scheme]
    }

    private func launch(hardwareKeyboard: Bool, echo: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = Self.arguments(hardwareKeyboard: hardwareKeyboard) + (echo ? ["-DispatchTerminalEcho", "keys"] : [])
        app.launch()
        XCTAssertTrue(app.textViews["Terminal"].waitForExistence(timeout: 10), "the dev tab's terminal")
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func count(_ app: XCUIApplication) -> String {
        app.staticTexts["search-count"].label.replacingOccurrences(of: " matches", with: "")
    }

    private func expectCount(_ app: XCUIApplication, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, count(app) != expected { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(count(app), expected, file: file, line: line)
    }

    /// Opens the key bar's menu with a tap on its "…" key.
    static func openMenu(_ app: XCUIApplication) {
        let key = app.buttons["Terminal menu"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "the menu key")
        key.tap()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 5), "the menu's Search")
    }

    /// The "…" key opens the menu (Search, Paste, Select all, Clear screen, Reset terminal); its
    /// Search swaps the key capsule for the search capsule: typing counts the matches newest first, the up arrow steps
    /// to the older one, Done brings the keys back.
    func testSearchFromTheKeyBarMenu() {
        let app = launch(hardwareKeyboard: true)
        Self.openMenu(app)
        for item in ["Paste", "Select all", "Clear screen", "Reset terminal"] {
            // Clear screen's label carries its note ("⌘K on a keyboard").
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch.exists, item)
        }
        attach(app, "Menu")
        app.buttons["Search"].tap()
        let field = app.textFields["Search terminal"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Control"].exists, "the search capsule replaces the keys")
        XCTAssertTrue(field.hasFocus(), "the field takes the focus")
        field.typeText("theme.ts")
        expectCount(app, "1 of 3")
        app.buttons["Older match"].tap()
        expectCount(app, "2 of 3")
        app.buttons["Newer match"].tap()
        app.buttons["Newer match"].tap()
        expectCount(app, "3 of 3")
        attach(app, "Searching")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Control"].waitForExistence(timeout: 5))
        XCTAssertFalse(field.exists)
    }

    /// While the software keyboard is up the keyboard key hides it, and the "…" key still opens the menu, which has no
    /// Hide keyboard.
    func testTheKeyboardKeyHidesTheKeyboard() {
        let app = launch(hardwareKeyboard: false)
        app.textViews["Terminal"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the software keyboard")
        let menu = app.buttons["Terminal menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the menu key beside the keyboard key")
        menu.tap()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Hide keyboard'")).count, 1,
                       "the keyboard key alone: the menu has no Hide keyboard")
        app.buttons["Search"].tap()
        app.buttons["Done"].tap()
        let hide = app.buttons["Hide keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "the keyboard key while the keyboard is up")
        hide.tap()
        XCTAssertTrue(app.buttons["Show keyboard"].waitForExistence(timeout: 5), "the keyboard key again")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard went down")
    }

    /// ⌘F with a hardware keyboard opens the search; ⌘G and ⇧⌘G step it from the field.
    func testFindChords() {
        let app = launch(hardwareKeyboard: true, echo: true)
        let terminal = app.textViews["Terminal"]
        terminal.tap()
        // A key that lands first: the first hardware event after the tap can go to switching input modes
        // (TerminalKeyboardUITests.testCommandCopyAndPaste); the sample echoes it.
        terminal.typeKey("l", modifierFlags: [])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !((terminal.value as? String) ?? "").hasSuffix("l") {
            Thread.sleep(forTimeInterval: 0.1)
        }
        terminal.typeKey("f", modifierFlags: .command)
        let field = app.textFields["Search terminal"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F opens the search")
        field.typeText("theme.ts")
        expectCount(app, "1 of 3")
        field.typeKey("g", modifierFlags: .command)
        expectCount(app, "2 of 3")
        field.typeKey("g", modifierFlags: [.command, .shift])
        expectCount(app, "1 of 3")
    }
}

extension XCUIElement {
    func hasFocus() -> Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
