import XCTest

/// A Markdown file rendered as a page (`FileMarkdownReader`), on the Spaces sample's README.md: a tap on a section's
/// heading folds it and another opens it; the "…" menu's Outline folds them all, unfolds them, and scrolls to one.
@MainActor
final class FilesMarkdownUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-DispatchTabsSample", "YES", "-DispatchTabsShow", "tab:herdr:app:1", "-DispatchTabsSegment", "files",
                               "-DispatchFilesPreview", "README.md", "-appearance", "dark"]
        app.launch()
        return app
    }

    private func gone(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    private func outline(_ app: XCUIApplication, _ item: String) {
        app.buttons["More"].tap()
        let outline = app.buttons["Outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 5), "rendered Markdown with headings has an Outline")
        outline.tap()
        let entry = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", item)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), item)
        entry.tap()
    }

    func testHeadingsFoldAndTheOutlineFoldsAndFinds() {
        let app = launch()
        // The headings, in order: Theming (the file's title, alone at its level), Tokens, Dark mode.
        let tokens = app.buttons["file-markdown-heading-1"]
        XCTAssertTrue(tokens.waitForExistence(timeout: 10))
        let cell = app.staticTexts["white"], quote = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The sidebar'")).firstMatch
        XCTAssertTrue(cell.exists, "the Tokens table shows")
        tokens.tap()
        gone(cell)
        XCTAssertEqual(tokens.value as? String, "Folded")
        XCTAssertTrue(quote.exists, "folding Tokens leaves Dark mode's section")
        tokens.tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "another tap opens it")

        outline(app, "Fold All")
        gone(cell)
        gone(quote)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The app follows'")).firstMatch.exists,
                      "the lone title stays open")
        // Going to a heading opens the folded sections around it, not its own.
        outline(app, "Dark mode")
        XCTAssertFalse(quote.exists)
        outline(app, "Unfold All")
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertTrue(quote.waitForExistence(timeout: 5))
    }
}
