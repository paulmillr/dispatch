import XCTest

/// The shell on an iPad (`MobileSplit`): the split in both orientations, the stack in iPadOS's narrow windows (a half
/// upright, Slide Over) through the system's own window controls, live resizing across the split's threshold, and the
/// sheets over the split. Screenshots are attached to the result bundle and, when `DISPATCH_UI_SHOTS` names a folder
/// (`TEST_RUNNER_DISPATCH_UI_SHOTS` through xcodebuild), written there. Needs an iPad simulator with iPadOS's windowed
/// apps (the default on iOS 27); skips on an iPhone.
@MainActor
final class IPadLayoutUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .portrait
    }

    /// The sample hosts with a chat tab open (in the split, the detail column).
    private func launch(_ arguments: [String] = ["-DispatchTabsShow", "tab:herdr:app:1"]) {
        app = XCUIApplication()
        app.launchArguments = ["-DispatchTabsSample", "YES", "-appearance", "dark", "-DispatchHardwareKeyboard", "NO"] + arguments
        app.launchEnvironment["DISPATCH_MOBILE_STORE"] = "memory"
        app.launch()
        // The window's size and place outlive the app: every case starts full screen and leaves it so, upright.
        arrange("Fill")
        addTeardownBlock { @MainActor [self] in
            XCUIDevice.shared.orientation = .portrait
            if app.state == .runningForeground { arrange("Fill") }
        }
        // A launch that opens a tab waits for it.
        if arguments.contains(where: { $0.hasPrefix("tab:") }) {
            XCTAssertTrue(app.buttons["Space details"].waitForExistence(timeout: 10))
        }
    }

    private var window: CGRect { app.windows.firstMatch.frame }

    private func rotate(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        sleep(2)
    }

    /// iPadOS's window controls: hold Zoom, then a Move & Resize or Fill & Arrange entry ("Fill", "Left", "Top",
    /// "Enter Slide Over"). A full-screen window shows its controls only once it is a window, so it shrinks first.
    private func arrange(_ entry: String) {
        let screen = springboard.windows.firstMatch.frame.size
        let full = window.size == screen || window.size == CGSize(width: screen.height, height: screen.width)
        if entry == "Fill", full { return }
        if full { drag(by: CGVector(dx: -150, dy: -150)) }
        let controls = springboard.descendants(matching: .any)["window-controls:yachts.dispatch.mobile"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5), "window controls")
        controls.tap()
        let zoom = springboard.buttons["Zoom-button"].firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 5), "Zoom")
        zoom.press(forDuration: 1.2)
        let item = springboard.buttons[entry].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), entry)
        item.tap()
        sleep(2)
    }

    /// Drags the window's resize grabber (its bottom right corner) by `offset`, in the app's coordinates: SpringBoard
    /// reports its elements upright whatever the orientation.
    private func drag(by offset: CGVector, duration: TimeInterval = 0.5) {
        let corner = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -6, dy: -6))
        corner.press(forDuration: duration, thenDragTo: corner.withOffset(offset))
        sleep(1)
    }

    private let backPill = NSPredicate(format: "label BEGINSWITH 'Back'")

    /// The split: the sidebar's tab bar across the system's sidebar width from the window's leading edge, the tab's
    /// header beside it with no back pill. In Spaces, Edit stays in the sidebar's bar beside the window controls, not
    /// in an overflow menu.
    private func assertSplit(sidebar: CGFloat, spaces: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        if spaces {
            XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5), "Edit in the sidebar's bar", file: file, line: line)
            XCTAssertLessThan(app.buttons["Edit"].frame.maxX - window.minX, sidebar, file: file, line: line)
        }
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the sidebar's tab bar", file: file, line: line)
        XCTAssertEqual(bar.frame.minX - window.minX, 0, accuracy: 1, "\(bar.frame) in \(window)", file: file, line: line)
        XCTAssertEqual(bar.frame.width, sidebar, accuracy: 1, "the sidebar's width: \(bar.frame) in \(window)", file: file, line: line)
        let details = app.buttons["Space details"]
        XCTAssertTrue(details.exists, "the tab beside it", file: file, line: line)
        XCTAssertGreaterThan(details.frame.minX - window.minX, sidebar, file: file, line: line)
        XCTAssertFalse(app.buttons.matching(backPill).firstMatch.exists, "no back pill beside the sidebar", file: file, line: line)
    }

    /// The stack: the tab on top with its back pill, nothing beside it.
    private func assertStackedTab(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.buttons.matching(backPill).firstMatch.waitForExistence(timeout: 5), "the back pill", file: file, line: line)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no sidebar", file: file, line: line)
        XCTAssertTrue(app.buttons["Space details"].exists, file: file, line: line)
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["DISPATCH_UI_SHOTS"] {
            let model = UIDevice.current.name.replacingOccurrences(of: " ", with: "-")
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(model)-\(name).png"))
        }
    }

    /// Full screen either way up: the system's sidebar width beside the tab; a row opens its tab in place, the sidebar
    /// stays.
    func testTheSplitInBothOrientations() {
        launch()
        let portrait = window.width
        assertSplit(sidebar: Self.sidebar(portrait))
        shot("split-portrait")
        rotate(.landscapeLeft)
        assertSplit(sidebar: Self.sidebar(window.width))
        shot("split-landscape")
        let row = app.staticTexts["claude"].firstMatch
        XCTAssertTrue(row.exists)
        row.tap()
        sleep(1)
        assertSplit(sidebar: Self.sidebar(window.width))
        XCTAssertGreaterThan(app.staticTexts.matching(identifier: "claude").count, 1, "the row and the tab's title")
        shot("split-landscape-claude")
        rotate(.portrait)
        assertSplit(sidebar: Self.sidebar(portrait))
    }

    /// Launched upright and turned on its side (and back), with the terminal focused and the software keyboard up, the
    /// window splits in each orientation and never shows the stack: the split follows the window's live size by its
    /// width alone, so the keyboard taking half a landscape window's height does not fold it. Then the other way, a
    /// launch on its side turned upright.
    func testRotationKeepsTheSplit() {
        for start in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = start
            sleep(1)
            launch(["-DispatchTabsShow", "tab:herdr:app:2", "-terminal.keysShown", "NO"])
            let terminal = app.textViews["Terminal"]
            XCTAssertTrue(terminal.waitForExistence(timeout: 10), "the dev tab's terminal")
            terminal.tap()
            sleep(1)
            let keyboard = app.keyboards.firstMatch.exists
            assertSplit(sidebar: Self.sidebar(window.width))
            shot("rotate-\(start == .portrait ? "upright" : "side")-start-keyboard-\(keyboard)")
            for next in start == .portrait ? [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight]
                                           : [.portrait, .landscapeLeft] {
                rotate(next)
                assertSplit(sidebar: Self.sidebar(window.width))
                shot("rotate-\(start == .portrait ? "upright" : "side")-to-\(next.rawValue)")
            }
            app.terminate()
        }
    }

    /// New is one tap away in the sidebar's tab bar (the phone's bottom bar, New its own circle: iPadOS's top bar
    /// folded it behind a "Next Page" chevron upright) at every sidebar width: full screen either way up, a top half on
    /// its side and the window dragged down to the split's narrowest. In Agents it opens New chat.
    func testNewIsOneTapAwayAtEverySidebarWidth() {
        launch()
        app.tabBars.buttons["Agents"].tap()
        func check(_ name: String) {
            let new = app.tabBars.buttons["New chat"]
            XCTAssertTrue(new.waitForExistence(timeout: 5), name)
            XCTAssertTrue(new.isHittable, "\(name): New in the bar, not behind a chevron")
            XCTAssertLessThanOrEqual(new.frame.maxX - window.minX, Self.sidebar(window.width) + 1, "\(name): in the sidebar")
            XCTAssertFalse(app.buttons["Next Page"].exists, name)
            shot("new-\(name)")
            new.tap()
            XCTAssertTrue(app.staticTexts["New chat"].waitForExistence(timeout: 5), "\(name): New chat")
            app.buttons["Close"].tap()
            XCTAssertTrue(new.waitForExistence(timeout: 5))
        }
        check("portrait")
        rotate(.landscapeLeft)
        check("landscape")
        rotate(.portrait)
        arrange("Top")
        while Self.splits(window.width - 60) { drag(by: CGVector(dx: -60, dy: 0)) }
        XCTAssertTrue(Self.splits(window.width), "\(window.width)")
        check("narrowest-\(Int(Self.sidebar(window.width)))")
    }

    /// The tab header's sidebar button hides the sidebar, so the tab spans the window either way up, and brings it
    /// back where it was.
    func testTheSidebarHidesAndComesBack() {
        launch()
        let hide = app.buttons["Hide sidebar"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()
        let show = app.buttons["Show sidebar"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "the sidebar is out of the window")
        XCTAssertEqual(show.frame.minX - window.minX, 16, accuracy: 6, "the button at the window's leading edge")
        shot("sidebar-hidden-portrait")
        rotate(.landscapeLeft)
        XCTAssertTrue(show.exists)
        shot("sidebar-hidden-landscape")
        show.tap()
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        assertSplit(sidebar: Self.sidebar(window.width))
    }

    /// The next launch comes back as the window was left: the tab beside the sidebar, the sidebar hidden, with no
    /// launch argument naming the tab (`-DispatchSplitMemory YES` lets the sample keep it, as the app does).
    func testALaunchRestoresTheTabAndTheHiddenSidebar() {
        launch(["-DispatchSplitMemory", "YES", "-DispatchTabsShow", "tab:herdr:app:2"])
        app.buttons["Hide sidebar"].tap()
        XCTAssertTrue(app.buttons["Show sidebar"].waitForExistence(timeout: 5))
        app.terminate()
        launch(["-DispatchSplitMemory", "YES"])
        XCTAssertTrue(app.buttons["Show sidebar"].waitForExistence(timeout: 10), "the tab, the sidebar hidden")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        shot("restored-hidden-sidebar")
        app.buttons["Show sidebar"].tap()
        XCTAssertTrue(app.buttons["Hide sidebar"].waitForExistence(timeout: 5))
        app.terminate()
        launch(["-DispatchSplitMemory", "YES"])
        XCTAssertTrue(app.buttons["Hide sidebar"].waitForExistence(timeout: 10), "the tab beside the sidebar")
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)
    }

    /// A half upright and Slide Over are the iPhone's stack, the open tab on top with its back pill; Back shows Spaces
    /// with its tab bar, a row pushes; filling the screen again splits the same path, the tab beside the sidebar.
    func testNarrowWindowsStack() {
        launch()
        arrange("Left")
        XCTAssertLessThan(window.width, 655.5)
        assertStackedTab()
        shot("half-portrait-tab")
        app.buttons.matching(backPill).firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Spaces"].exists, "the tab bar")
        shot("half-portrait-spaces")
        app.staticTexts["claude"].firstMatch.tap()
        assertStackedTab()

        arrange("Enter Slide Over")
        XCTAssertLessThan(window.width, 400)
        assertStackedTab()
        shot("slide-over-tab")

        arrange("Fill")
        assertSplit(sidebar: Self.sidebar(window.width))
        XCTAssertGreaterThan(app.staticTexts.matching(identifier: "claude").count, 1, "the pushed tab beside the sidebar, and its row")
        shot("fill-after-stack")
    }

    /// Dragging the window narrower stacks once it is under the split's 655.5 points, and wider splits again, with the
    /// tab on top either way; the columns follow every size between.
    func testLiveResizingAcrossTheThreshold() {
        launch()
        arrange("Top")
        var widths: [CGFloat] = []
        for _ in 0..<6 {
            drag(by: CGVector(dx: -80, dy: 0))
            widths.append(window.width)
            shot("resize-\(Int(window.width))")
            if Self.splits(window.width) { assertSplit(sidebar: Self.sidebar(window.width)) } else { assertStackedTab() }
        }
        XCTAssertTrue(widths.contains { $0 < 655.5 } && widths.contains { $0 >= 655.5 }, "\(widths)")
        shot("resized-narrow")
        for _ in 0..<6 {
            drag(by: CGVector(dx: 80, dy: 0))
            if Self.splits(window.width) { assertSplit(sidebar: Self.sidebar(window.width)) } else { assertStackedTab() }
        }
        shot("resized-wide")
    }

    /// Settings, New host and New chat over the split: system form sheets in the middle of the window, not the
    /// window's width; the split stays underneath.
    func testSheetsOverTheSplit() {
        launch()
        rotate(.landscapeLeft)
        app.buttons["Edit"].tap()
        app.buttons["Settings"].tap()
        let settings = app.navigationBars["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        assertFormSheet(settings)
        shot("sheet-settings")
        settings.buttons["Done"].tap()

        app.buttons["Add host"].tap()
        let newHost = app.navigationBars["New host"]
        XCTAssertTrue(newHost.waitForExistence(timeout: 5))
        assertFormSheet(newHost)
        shot("sheet-new-host")
        app.buttons["Cancel"].tap()
        app.buttons["Done"].firstMatch.tap()

        app.buttons["Agents"].tap()
        app.buttons["New chat"].tap()
        XCTAssertTrue(app.staticTexts["New chat"].waitForExistence(timeout: 5))
        assertFormSheet(app.staticTexts["New chat"])
        shot("sheet-new-chat")
        app.buttons["Close"].tap()
        assertSplit(sidebar: Self.sidebar(window.width), spaces: false)
    }

    /// New tab's space picker is a form sheet in the middle of the window, as the other sheets, either way up: not
    /// the phone's half-height card at the window's bottom (its detents), whose list the screen's edge cut.
    func testTheSpacePickerIsAFormSheet() {
        launch(["-DispatchTabsShow", "pick"])
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(orientation)
            let bar = app.navigationBars["New tab"]
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            assertFormSheet(bar)
            XCTAssertLessThan(bar.frame.minY - window.minY, window.height * 0.25, "\(bar.frame) in \(window): not a bottom card")
            let newSpace = app.buttons["New space…"]
            XCTAssertTrue(newSpace.waitForExistence(timeout: 5))
            XCTAssertLessThan(newSpace.frame.maxY, window.maxY - 20, "the list's end is in the sheet")
            shot("space-picker-" + (orientation == .portrait ? "portrait" : "landscape"))
        }
    }

    /// The pointer over a row, the sidebar's tree toggle, Edit and the tab's host disc: each shows the system's
    /// highlight (plain buttons and interactive glass get none of their own). Screenshots only: the effect is drawn
    /// by the system outside the app's hierarchy.
    func testPointerHover() {
        launch()
        let targets: [(String, XCUIElement)] = [
            ("row", app.staticTexts["codex"].firstMatch), ("tree", app.navigationBars.buttons["Spaces"].firstMatch),
            ("edit", app.buttons["Edit"]), ("details", app.buttons["Space details"])]
        for (name, element) in targets {
            XCTAssertTrue(element.waitForExistence(timeout: 5), name)
            element.hover()
            sleep(1)
            shot("hover-\(name)")
        }
    }

    /// Rotation, the stack and the split exchanging as the system re-tiles the window, the sidebar hidden and shown,
    /// and live resizing across the
    /// threshold, with a rest before and after each: for a screen recording judged frame by frame
    /// (`scripts/transition-frames.swift`). Each step also checks the state it reached.
    func testTransitions() {
        let pause: UInt32 = 2
        launch()
        sleep(pause)
        rotate(.landscapeLeft)
        sleep(pause)
        assertSplit(sidebar: Self.sidebar(window.width))
        rotate(.portrait)
        sleep(pause)
        arrange("Left")
        sleep(pause)
        assertStackedTab()
        arrange("Fill")
        sleep(pause)
        assertSplit(sidebar: Self.sidebar(window.width))
        app.buttons["Hide sidebar"].tap()
        sleep(pause)
        app.buttons["Show sidebar"].tap()
        sleep(pause)
        arrange("Top")
        sleep(pause)
        for step in [-100, -100, 100, 100] as [CGFloat] {
            drag(by: CGVector(dx: step, dy: 0), duration: 0.3)
            sleep(pause)
        }
    }

    /// A sheet's bar narrower than the window and away from its leading edge: the system's form sheet.
    private func assertFormSheet(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let frame = element.frame
        XCTAssertLessThan(frame.width, window.width * 0.8, "\(frame) in \(window)", file: file, line: line)
        XCTAssertGreaterThan(frame.minX - window.minX, 100, "\(frame) in \(window)", file: file, line: line)
    }

    /// `MobileSplit`'s iPad rules, restated (the UI tests do not link the app): the sidebar for a window `width` wide,
    /// and whether it splits.
    static func sidebar(_ width: CGFloat) -> CGFloat { min(320, max(280, (width - 448).rounded(.down))) }
    static func splits(_ width: CGFloat) -> Bool { width >= 655.5 }
}
