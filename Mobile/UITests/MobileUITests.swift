import XCTest

/// Taps the app running scripted demo hosts (`DISPATCH_MOBILE_SCRIPTED`): no network, no saved state.
@MainActor
final class MobileUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scripted: String = "1") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DISPATCH_MOBILE_SCRIPTED"] = scripted
        app.launch()
        return app
    }

    /// A screenshot attached to the result bundle.
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// New opens the section's sheet and the section stays selected underneath; the other tab still switches. With no
    /// host yet New in Spaces is New host (M1d). With `DISPATCH_UI_NEW_PAUSE` set, waits that many seconds around the
    /// tap so a screen recording brackets it.
    func testNewOpensTheSectionsSheet() throws {
        let app = launch("empty")
        XCTAssertTrue(app.staticTexts["No hosts yet"].waitForExistence(timeout: 10))
        let pause = ProcessInfo.processInfo.environment["DISPATCH_UI_NEW_PAUSE"].flatMap(Double.init) ?? 0
        if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        app.buttons["New host"].tap()
        XCTAssertTrue(app.navigationBars["New host"].waitForExistence(timeout: 5))
        if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Spaces"].isSelected)

        app.buttons["Agents"].tap()
        XCTAssertTrue(app.staticTexts["No agents yet"].waitForExistence(timeout: 5))
        app.buttons["New chat"].tap()
        XCTAssertTrue(app.staticTexts["New chat"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Agents"].isSelected)
    }

    /// M1d's Add host opens M8a; Create connects once, asks about the host key inside the sheet, and saves only
    /// once connected.
    func testCreateVerifiesThenSaves() throws {
        let app = launch("empty")
        XCTAssertTrue(app.staticTexts["No hosts yet"].waitForExistence(timeout: 10))
        shot("M1d")
        app.buttons["Add host"].tap()
        XCTAssertTrue(app.navigationBars["New host"].waitForExistence(timeout: 5))
        shot("M8a")
        let fields = app.textFields
        fields["studio"].tap()
        fields["studio"].typeText("box")
        fields["studio.tail3f.ts.net"].tap()
        fields["studio.tail3f.ts.net"].typeText("box.local")
        fields["alex"].tap()
        fields["alex"].typeText("alex")
        app.buttons["Password"].tap()
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("pw")
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["Trust this host?"].waitForExistence(timeout: 5))
        shot("TOFU-in-M8a")
        app.buttons["Trust"].tap()
        let sheet = app.navigationBars["New host"]
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: sheet)
        waitForExpectations(timeout: 5)
    }

    func testTrustOnFirstUse() throws {
        let app = launch("trust")
        XCTAssertTrue(app.staticTexts["Trust this host?"].waitForExistence(timeout: 10))
        shot("TOFU")
        app.buttons["Trust"].tap()
        XCTAssertFalse(app.staticTexts["Trust this host?"].waitForExistence(timeout: 2))
    }

    func testHostKeyMismatch() throws {
        let app = launch("mismatch")
        XCTAssertTrue(app.staticTexts["Host key changed"].waitForExistence(timeout: 10))
        shot("TOFU-mismatch")
        app.buttons["Remove and retry"].tap()
        XCTAssertTrue(app.staticTexts["Trust this host?"].waitForExistence(timeout: 5))
    }
}
