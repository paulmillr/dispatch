import XCTest

/// An iPhone on its side (docs/ios.md, Landscape; `MobileLandscape`): no navigation bar, the chrome in one rail on the
/// Dynamic Island's side (Back, the menu disc, the five modes, the mode's action) and the content the window's height
/// and the rest of its width; the terminal's keys only on the keyboard, raised by the rail; Chat's empty composer
/// folded into Reply; Create review at the rail's foot; the mode kept across a turn. The Spaces sample; screenshots
/// attached to the result bundle. iPhone only: an iPad's window splits instead.
@MainActor
final class PhoneLandscapeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone only") }
        // On its side before the launch, so a launch's route opens as it would there (Review's diff in its pane).
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
    }

    private func launch(_ arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-DispatchTabsSample", "YES", "-DispatchTabsTree", "NO", "-DispatchHardwareKeyboard", "NO",
                               "-terminal.keysShown", "NO", "-appearance", "dark"] + arguments
        app.launchEnvironment["DISPATCH_MOBILE_STORE"] = "memory"
        app.launch()
        XCTAssertTrue(rail.waitForExistence(timeout: 10), "the tab's rail")
        XCTAssertGreaterThan(window.width, window.height, "on its side")
    }

    private var rail: XCUIElement { app.otherElements["tab-rail"] }
    /// The mode switch, stood on end in the rail.
    private var modes: XCUIElement { app.otherElements["tab-segments"] }
    private var window: CGRect { app.windows.firstMatch.frame }
    private var back: XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back'")).firstMatch }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The rail at one side edge holding Back and the five modes stacked; no navigation bar; `content` from the
    /// window's top to its bottom, across the rest of its width.
    private func assertRail(content: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let side = rail.frame
        XCTAssertTrue(side.minX < 70 || side.maxX > window.maxX - 70, "the rail at an edge: \(side)", file: file, line: line)
        XCTAssertTrue(side.contains(back.frame), "Back in the rail", file: file, line: line)
        for mode in ["Terminal", "Chat", "Files", "Review", "Commits"] {
            XCTAssertTrue(modes.buttons[mode].exists, "\(mode) in the rail", file: file, line: line)
        }
        let first = modes.buttons["Terminal"].frame, second = modes.buttons["Chat"].frame
        XCTAssertEqual(first.midX, second.midX, accuracy: 1, "the modes stacked", file: file, line: line)
        XCTAssertEqual(app.navigationBars.count, 0, "no navigation bar", file: file, line: line)
        XCTAssertEqual(app.tabBars.count, 0, "no Files tab bar", file: file, line: line)
        XCTAssertGreaterThan(content.frame.height, window.height - 40, "the window's height", file: file, line: line)
        XCTAssertGreaterThan(content.frame.width, window.width - side.width - 130, "the rest of its width", file: file, line: line)
    }

    /// L14, L15: the terminal takes the window; the rail's keyboard button raises the keyboard with the key row on
    /// it, the rail folds to Back and the disc; a second tap lowers it.
    func testTerminalTakesTheWindowAndTheRailRaisesTheKeys() {
        launch(["-DispatchTabsShow", "tab:herdr:app:2"])
        let terminal = app.textViews["Terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        assertRail(content: terminal)
        XCTAssertFalse(app.buttons["Control"].exists, "no key capsule at rest")
        attach("Terminal on its side")

        let keyboardButton = app.buttons["rail-keyboard"]
        XCTAssertTrue(keyboardButton.exists)
        keyboardButton.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "the software keyboard")
        // A simulator that saw hardware key events minimizes the software keyboard: its frame stays below the window
        // (`simctl spawn <udid> defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool NO`).
        let control = app.buttons["Control"], escape = app.buttons["Escape"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), "the key row on the keyboard")
        Thread.sleep(forTimeInterval: 1)
        attach("Typing on its side")
        XCTAssertEqual(control.frame.midY, escape.frame.midY, accuracy: 1, "one row")
        XCTAssertLessThanOrEqual(control.frame.maxY, keyboard.frame.minY + 1, "riding the keyboard")
        XCTAssertFalse(modes.exists, "the rail folded above the keyboard")
        XCTAssertTrue(back.isHittable, "Back stays")

        app.buttons["Hide keyboard"].firstMatch.tap()
        XCTAssertTrue(modes.waitForExistence(timeout: 5), "the rail again")
        XCTAssertFalse(app.buttons["Control"].exists, "the key row went with the keyboard")
    }

    /// The rail follows the island: turned the other way, it moves to the other edge; either way it stands clear of the
    /// island, which reaches further in on the Air (`MobileLandscape.railInset`).
    func testTheRailFollowsTheIsland() {
        launch(["-DispatchTabsShow", "tab:herdr:app:2"])
        let first = rail.frame.midX > window.midX
        assertClearOfTheIsland()
        XCUIDevice.shared.orientation = .landscapeRight
        Thread.sleep(forTimeInterval: 2)
        XCTAssertNotEqual(rail.frame.midX > window.midX, first, "the other edge: \(rail.frame) in \(window)")
        assertClearOfTheIsland()
        attach("Turned the other way")
    }

    /// L19: the host sheet on its side is a chart screen: no navigation bar, its rail at the island's edge (Close, the
    /// host's disc with its facts, Edit), CPU and memory across the rest; ⓘ shows the facts and the action; Close closes.
    func testTheHostSheetIsAChartScreenOnItsSide() {
        app = XCUIApplication()
        app.launchArguments = ["-DispatchHostStats", "mba2", "-appearance", "dark"]
        app.launchEnvironment["DISPATCH_MOBILE_DEMO"] = "1"
        app.launch()
        let chart = app.descendants(matching: .any)["host-stats-chart"]
        XCTAssertTrue(chart.waitForExistence(timeout: 15), "the chart screen")
        XCTAssertGreaterThan(window.width, window.height, "on its side")
        let side = app.descendants(matching: .any)["host-stats-rail"].frame
        XCTAssertTrue(side.minX < 70 || side.maxX > window.maxX - 70, "the rail at an edge: \(side)")
        XCTAssertGreaterThan(chart.frame.width, window.width * 0.8, "the chart across the rest: \(chart.frame)")
        XCTAssertLessThan(chart.frame.minY, 80, "no header row: only the legend above the chart: \(chart.frame)")
        XCTAssertTrue(app.descendants(matching: .any)["host-stats-rail"].buttons["Edit"].exists, "Edit on the rail")
        Thread.sleep(forTimeInterval: 3)
        attach("Host stats on its side")

        app.buttons["host-stats-facts"].tap()
        XCTAssertTrue(app.staticTexts["Address"].waitForExistence(timeout: 5), "the facts")
        XCTAssertTrue(app.buttons["Disconnect"].exists, "the action with them")
        attach("Its facts")
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Address"].waitForNonExistence(timeout: 5))
        app.descendants(matching: .any)["host-stats-rail"].buttons["Close"].tap()
        XCTAssertTrue(chart.waitForNonExistence(timeout: 5), "closed")
    }

    /// The rail's outer edge is at least 2 points past where the phone's island (or notch) ends, from the window's edge.
    private func assertClearOfTheIsland(file: StaticString = #filePath, line: UInt = #line) {
        let model = UIDevice.current.name
        let island: CGFloat = model.hasPrefix("iPhone Air") ? 54 : model.hasPrefix("iPhone 17e") ? 33 : 48
        let side = rail.frame
        let gap = side.midX < window.midX ? side.minX - window.minX : window.maxX - side.maxX
        XCTAssertGreaterThanOrEqual(gap, island + 2, "\(model): the rail \(gap) points in, the island to \(island)", file: file, line: line)
    }

    /// L12: Chat's empty composer is the rail's Reply; Reply unfolds it with the keyboard.
    func testChatsEmptyComposerIsReply() {
        launch(["-DispatchTabsShow", "tab:herdr:app:1", "-DispatchTabsSegment", "chat"])
        let composer = app.textViews.matching(NSPredicate(format: "label != 'Terminal'")).firstMatch
        let reply = app.buttons["Reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "Reply at the rail's foot")
        XCTAssertTrue(rail.frame.contains(reply.frame))
        XCTAssertFalse(composer.exists, "no composer row")
        attach("Chat on its side")

        reply.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "the composer")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "with the keyboard")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThan(keyboard.frame.minY, window.maxY - 100, "on screen: \(keyboard.frame)")
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY + 1, "the composer above it")
        XCTAssertFalse(reply.exists, "Reply gone while writing")
        attach("Replying on its side")
    }

    /// L13: Review lists the changes with the diff beside them, both the window's height; Create review is the rail's
    /// foot with the comment count and opens the review.
    func testReviewBesideItsDiffAndCreateReviewOnTheRail() {
        launch(["-DispatchTabsShow", "tab:herdr:app:1", "-DispatchTabsSegment", "files", "-DispatchTabsFilesMode", "review",
                "-DispatchReviewDiff", "Sidebar.tsx"])
        XCTAssertTrue(modes.buttons["Review"].isSelected)
        let title = app.staticTexts["Sidebar.tsx"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the diff's pane")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'theme.ts'")).firstMatch
        XCTAssertTrue(row.exists, "the change list")
        XCTAssertTrue(title.frame.minX > row.frame.maxX - 1 || title.frame.maxX < row.frame.minX + 1, "the pane beside the list")
        let create = app.buttons["Create review"]
        XCTAssertTrue(create.exists, "Create review on the rail")
        XCTAssertTrue(rail.frame.contains(create.frame))
        XCTAssertEqual(create.value as? String, "3")
        attach("Review on its side")
        create.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Send to'")).firstMatch
            .waitForExistence(timeout: 5), "the review's sheet")
    }

    /// The modes hold still from mode to mode: the rail keeps the foot's place whether the mode has an action there
    /// (Chat's Reply, Review's Create review) or not (Files, Commits), and fills the window's height in every mode.
    func testTheModesHoldStillAcrossModes() {
        launch(["-DispatchTabsShow", "tab:herdr:app:1", "-DispatchTabsSegment", "chat"])
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 10), "Chat's Reply")
        let start = modes.frame
        for mode in ["Commits", "Files", "Review", "Chat"] {
            modes.buttons[mode].tap()
            expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: modes.buttons[mode])
            waitForExpectations(timeout: 5)
            XCTAssertEqual(modes.frame.minY, start.minY, accuracy: 0.5, "\(mode): the modes in place")
        }
        // Back on Chat, the rail's menu disc holds the conversation's items.
        rail.buttons["tab-menu"].tap()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 5), "the conversation's Search in the disc's menu")
    }

    /// A mode chosen on its side is the one the upright screen shows: the mode button names Review.
    func testTurningUprightKeepsTheMode() {
        launch(["-DispatchTabsShow", "tab:herdr:app:1", "-DispatchTabsSegment", "chat"])
        modes.buttons["Review"].tap()
        XCTAssertTrue(app.buttons["Create review"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["tab-mode-button"].waitForExistence(timeout: 5), "the mode button upright")
        XCTAssertTrue(app.buttons["Create review"].waitForExistence(timeout: 5), "Review still shown")
        attach("Upright again")
    }

    /// A file's preview on its side: no navigation bar; Back, "…" and ⓘ in a rail on the island's side, ⓘ's popover
    /// naming the file, and the content's action at the rail's foot: Outline for a Markdown page, Find for code.
    /// Turned upright, the header is back.
    func testAFilePreviewKeepsItsTitleBesideThePage() {
        func open(_ file: String) {
            app = XCUIApplication()
            app.launchArguments = ["-DispatchTabsSample", "YES", "-DispatchTabsTree", "NO", "-DispatchTabsShow", "tab:herdr:app:1",
                                   "-DispatchTabsSegment", "files", "-DispatchFilesPreview", file, "-appearance", "dark"]
            app.launchEnvironment["DISPATCH_MOBILE_STORE"] = "memory"
            app.launch()
            XCTAssertTrue(app.otherElements["preview-rail"].waitForExistence(timeout: 10), "the preview's rail")
            XCTAssertGreaterThan(window.width, window.height, "on its side")
            XCTAssertEqual(app.navigationBars.count, 0, "no navigation bar")
            let side = app.otherElements["preview-rail"].frame
            XCTAssertTrue(side.minX < 70 || side.maxX > window.maxX - 70, "the rail at an edge: \(side)")
            XCTAssertTrue(side.contains(back.frame), "Back in the rail")
            XCTAssertTrue(app.buttons["More"].exists, "… in the rail")
            XCTAssertTrue(app.buttons["preview-info"].exists, "ⓘ in the rail")
        }

        open("README.md")
        XCTAssertTrue(app.buttons["file-markdown-heading-1"].waitForExistence(timeout: 10), "the page")
        let rail = app.otherElements["preview-rail"].frame
        let outline = app.buttons["preview-outline"]
        XCTAssertTrue(outline.exists, "Outline on the rail")
        XCTAssertGreaterThan(outline.frame.minY, rail.midY, "at its foot")
        attach("Markdown on its side")
        app.buttons["preview-info"].tap()
        XCTAssertTrue(app.staticTexts["README.md"].waitForExistence(timeout: 5), "the popover names the file")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()

        open("src/theme.ts")
        let find = app.buttons["preview-find"]
        XCTAssertTrue(find.waitForExistence(timeout: 5), "Find on the rail")
        XCTAssertTrue(app.otherElements["preview-rail"].frame.contains(find.frame), "in the rail, not at the bottom")
        let info = app.buttons["preview-info"]
        info.tap()
        XCTAssertTrue(app.staticTexts["theme.ts"].waitForExistence(timeout: 5), "the popover names the file")
        XCTAssertTrue(app.staticTexts["TypeScript"].exists, "and its kind")
        attach("Code on its side, info")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()

        // Turned upright and back a few times: the header comes back every time.
        for _ in 0..<3 {
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5), "the header upright")
            XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5) && app.buttons["More"].isHittable, "… in the header")
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.otherElements["preview-rail"].waitForExistence(timeout: 5), "the rail on its side")
        }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5), "the header upright at the end")
        attach("Upright again")
    }
}

