import XCTest

/// Settings (G1 to G5) driven as a user does: each pushed screen opens from its row, a choice there shows on the row
/// when coming back, and the theme recolours the app at once. The choices are put back at the end.
@MainActor
final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["DISPATCH_MOBILE_SCRIPTED": "1"]
        app.launchArguments = ["-appearance", "dark"]
        app.launch()
        return app
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element)", file: file, line: line)
        element.tap()
    }

    /// The back button of the pushed screen titled `title`: Spaces' bar behind the sheet holds buttons too (Done).
    private func back(_ app: XCUIApplication, from title: String) {
        tap(app.navigationBars[title].buttons.element(boundBy: 0))
    }

    private func openSettings(_ app: XCUIApplication) {
        tap(app.buttons["Edit"])
        tap(app.buttons["Settings"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    /// An earlier run that stopped half way left its choices: back to the defaults first.
    private func reset(_ app: XCUIApplication) {
        if app.buttons["Theme, Nautical"].waitForExistence(timeout: 2) {
            tap(app.buttons["Theme, Nautical"])
            tap(app.buttons["Automatic"])
            back(app, from: "Theme")
        }
        if app.buttons["Font, Fira Code"].exists {
            tap(app.buttons["Font, Fira Code"])
            tap(app.buttons["Source Code Pro"])
            back(app, from: "Terminal font")
        }
    }

    /// Scrolls Settings until `element` is on screen.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    func testChoicesShowOnTheirRows() throws {
        let app = launch()
        openSettings(app)
        reset(app)

        tap(app.buttons["Font, Source Code Pro"])
        XCTAssertTrue(app.navigationBars["Terminal font"].waitForExistence(timeout: 5))
        tap(app.buttons["Fira Code"])
        XCTAssertTrue(app.buttons["Fira Code"].isSelected)
        back(app, from: "Terminal font")
        XCTAssertTrue(app.buttons["Font, Fira Code"].waitForExistence(timeout: 5))

        tap(app.buttons["Theme, Automatic"])
        tap(app.buttons["Nautical"])
        back(app, from: "Theme")
        XCTAssertTrue(app.buttons["Theme, Nautical"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Light"].isEnabled, "Nautical brings its scheme: Appearance waits for Automatic")
        // The live switch, for a look at the recoloured sheet (the trait reaches SwiftUI's catalog colours).
        let shot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/mockup-review/live-nautical.png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shot)

        reveal(app.buttons["Notifications, Sound, text"], in: app)
        tap(app.buttons["Notifications, Sound, text"])
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        // The screen asks iOS for permission (the first run only): allow it.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let text = app.switches["Show message text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.switches.firstMatch.tap()
        back(app, from: "Notifications")
        XCTAssertTrue(app.buttons["Notifications, Sound"].waitForExistence(timeout: 5))

        // Put everything back for the next run.
        reveal(app.buttons["Notifications, Sound"], in: app)
        tap(app.buttons["Notifications, Sound"])
        app.switches["Show message text"].switches.firstMatch.tap()
        back(app, from: "Notifications")
        app.swipeDown()
        app.swipeDown()
        tap(app.buttons["Theme, Nautical"])
        tap(app.buttons["Automatic"])
        back(app, from: "Theme")
        tap(app.buttons["Font, Fira Code"])
        tap(app.buttons["Source Code Pro"])
        back(app, from: "Terminal font")
        XCTAssertTrue(app.buttons["Theme, Automatic"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Font, Source Code Pro"].exists)
        tap(app.navigationBars["Settings"].buttons["Done"])
    }
}
