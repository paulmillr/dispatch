import XCTest

/// The Commits mode driven as a user does, on the Spaces sample's repository (`CommitsFixture`): the log, a commit, its
/// file's diff and source, back to the log, the uncommitted row into Review, and the search.
@MainActor
final class CommitsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-DispatchTabsSample", "YES", "-DispatchTabsShow", "tab:herdr:app:1", "-DispatchTabsSegment", "files",
                               "-DispatchTabsFilesMode", "commits", "-appearance", "dark"]
        app.launch()
        return app
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element)", file: file, line: line)
        element.tap()
    }

    private func row(_ app: XCUIApplication, _ subject: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", subject)).firstMatch
    }

    func testACommitItsFileAndBack() {
        let app = launch()
        tap(row(app, "Sidebar theme toggle and unread rows"))
        XCTAssertTrue(app.staticTexts["c81a2f4"].waitForExistence(timeout: 5), "the short hash titles the commit")
        XCTAssertTrue(app.buttons["Branch dark-mode, checked out"].exists || app.staticTexts["Branch dark-mode, checked out"].exists)
        XCTAssertFalse(app.tabBars.buttons["Review"].exists, "the push covers the modes' tab bar")
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'src/components/Sidebar.tsx'")).firstMatch)
        XCTAssertTrue(app.staticTexts["Sidebar.tsx"].waitForExistence(timeout: 5))
        let hunk = app.staticTexts["@@ -1,20 +1,28 @@"]
        XCTAssertTrue(hunk.waitForExistence(timeout: 5), "the diff from its hunk")
        tap(app.buttons["Source"])
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: hunk)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Line 1,'")).firstMatch.exists,
                      "the whole file, numbered")
        tap(app.buttons["Back to c81a2f4"])
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Parent'")).firstMatch)
        XCTAssertTrue(app.staticTexts["7d04e9b"].waitForExistence(timeout: 5), "a parent opens its commit")
        tap(app.buttons["Back to Commits"])
        tap(app.buttons["Back to Commits"])
        XCTAssertTrue(row(app, "Initial Vite scaffold").waitForExistence(timeout: 5))
    }

    func testUncommittedOpensReviewAndSearchNarrows() {
        let app = launch()
        tap(app.buttons["Search commits"])
        let field = app.textFields["Search commits"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("router")
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row(app, "Initial Vite scaffold"))
        waitForExpectations(timeout: 5)
        XCTAssertTrue(row(app, "Upgrade react-router to v7").exists)
        tap(app.buttons["Close search"])
        tap(app.buttons["Uncommitted changes"])
        let review = app.tabBars.buttons["Review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: review)
        waitForExpectations(timeout: 5)
    }
}
