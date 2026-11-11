import XCTest

/// A phone tab's header (B7), on the Spaces sample's claude tab: the title capsule beside Back opens the tab's menu
/// (`TabMenuItems`), the host's Stats last; a pick acts (Search opens the thread's search bar).
@MainActor
final class TabMenuUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ segment: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-DispatchTabsSample", "YES", "-DispatchTabsShow", "tab:herdr:app:1", "-DispatchTabsSegment", segment,
                               "-appearance", "dark"]
        app.launch()
        return app
    }

    private func capsule(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tab-title-capsule").firstMatch
    }

    func testTheTitleCapsuleOpensTheTabsMenu() {
        let app = launch("chat")
        let capsule = capsule(app)
        XCTAssertTrue(capsule.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back'")).firstMatch.exists, "Back in its own circle")
        capsule.tap()
        let search = app.buttons["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "on Chat, the conversation's items")
        XCTAssertTrue(app.buttons["Stats"].exists, "the host's Stats")
        search.tap()
        XCTAssertTrue(app.textFields["Search"].waitForExistence(timeout: 5), "the search bar opens")
    }

    func testTheMenuOffersTheTabsActionsOnTerminal() {
        let app = launch("terminal")
        let capsule = capsule(app)
        XCTAssertTrue(capsule.waitForExistence(timeout: 10))
        capsule.tap()
        XCTAssertTrue(app.buttons["Rename…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Search"].exists, "no conversation's items off Chat")
        XCTAssertTrue(app.buttons["Close Tab"].exists)
        XCTAssertTrue(app.buttons["Detach"].exists)
        XCTAssertTrue(app.buttons["Stats"].exists)
    }
}
