import XCTest

/// Dispatch on an iPad with a hardware keyboard (docs/ios.md, iPad), against the scripted hosts
/// (`DISPATCH_MOBILE_SCRIPTED`): the split in both orientations (the sidebar's tree, the strip's pills and modes), the
/// menu bar's chords sent with `typeKey`, New host and New chat, and the sheets as form sheets. `-DispatchHardwareKeyboard YES` pins the keyboard, so the run does not
/// depend on the simulator's keyboard setting. Skipped on an iPhone. Screenshots are attached to the result bundle,
/// and written to `DISPATCH_IPAD_SHOTS` (`TEST_RUNNER_DISPATCH_IPAD_SHOTS` through xcodebuild) when it names a folder.
/// Slide Over and Split View are not scriptable (XCUITest cannot resize the app's window): the narrow window's stack
/// is the iPhone's, covered by the iPhone suites.
@MainActor
final class IPadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ scripted: String = "1", arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DISPATCH_MOBILE_SCRIPTED"] = scripted
        app.launchArguments = ["-DispatchHardwareKeyboard", "YES", "-appearance", "dark"]
            + arguments
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        // The rotation's and the push's animations end first.
        Thread.sleep(forTimeInterval: 1)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["DISPATCH_IPAD_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    private func wait(_ element: XCUIElement, gone: Bool = false, timeout: TimeInterval = 5,
                      file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: gone ? "exists == false" : "exists == true")
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element) \(gone ? "still shows" : "never showed")", file: file, line: line)
    }

    /// The "dispatch" space's row in the sidebar's tree (the scripted ai host's).
    private func dispatchRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "dispatch")).firstMatch
    }

    /// The strip's selected pill's identifier (`pad-tab-<key>`): a narrow strip holds only it and the overflow menu.
    private func selectedPill(_ app: XCUIApplication) -> String? {
        let pill = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pad-tab-' AND selected == true")).firstMatch
        return pill.waitForExistence(timeout: 5) ? pill.identifier : nil
    }

    /// Waits for the selected pill to be `identifier` (or, with `not`, anything else).
    private func waitForSelectedPill(_ app: XCUIApplication, _ identifier: String?, not: Bool = false) -> Bool {
        for _ in 0..<50 {
            let shown = selectedPill(app)
            if not ? shown != identifier && shown != nil : shown == identifier { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// The sidebar's filter menu (`PadFilterMenu`): its value starts with the filter's name.
    private func filter(_ app: XCUIApplication) -> XCUIElement { app.buttons["Filter"].firstMatch }

    /// The strip's mode switch (`PadModeSwitch`): a container of buttons labelled Terminal, Chat, Files, Review, Commits.
    private func segment(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.otherElements["tab-segments"].buttons[title]
    }

    /// The window splits upright and on its side: the tree beside the empty detail column, then beside the space's tab
    /// a row opened, with the strip over it; the sidebar marks the space and keeps a sidebar's width.
    func testTheSplitInBothOrientations() throws {
        let app = launch()
        let empty = app.staticTexts["No tab open"]
        wait(empty)
        let row = dispatchRow(app)
        wait(row)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The sidebar is the tree alone")
        shot("split-portrait-empty")
        row.tap()
        wait(segment(app, "Terminal"))
        XCTAssertNotNil(selectedPill(app), "Its first tab, selected in the strip")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any)["pad-tabs"].buttons.count, 2,
                                    "The other tab beside it, or in the overflow menu")
        XCTAssertTrue(row.isHittable, "The sidebar stays beside the tab")
        XCTAssertTrue(row.waitForSelection(), "The sidebar marks the shown space")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(row.frame.maxX, window.width * 0.6, "A sidebar, not half the window or more")
        shot("split-portrait-tab")
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            wait(segment(app, "Terminal"))
            XCTAssertTrue(row.isHittable, "Split on its side too")
            XCTAssertTrue(row.waitForSelection())
            shot(orientation == .landscapeLeft ? "split-landscape-left-tab" : "split-landscape-right-tab")
        }
        XCUIDevice.shared.orientation = .portrait
        wait(segment(app, "Terminal"))
        XCTAssertTrue(row.waitForSelection(), "Rotating back keeps the tab")
    }

    /// ⌘1 and ⌘2 set the sidebar's filter (All, Agents); ⌘, opens Settings and ⌘/ Keyboard Shortcuts as form sheets;
    /// nothing opens over a sheet; ⌥⌘N opens New chat.
    func testSectionAndSheetShortcuts() throws {
        let app = launch()
        wait(dispatchRow(app))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(filter(app).waitForValue(prefix: "Agents"), "⌘2: Agents")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(filter(app).waitForValue(prefix: "All"), "⌘1: All")

        app.typeKey(",", modifierFlags: .command)
        let settings = app.navigationBars["Settings"]
        wait(settings)
        XCTAssertLessThan(settings.frame.width, app.windows.firstMatch.frame.width * 0.9, "Settings is a form sheet")
        shot("settings-form-sheet")
        app.typeKey("/", modifierFlags: .command)
        XCTAssertFalse(app.navigationBars["Keyboard Shortcuts"].waitForExistence(timeout: 1), "The chord waits for the sheet")
        settings.buttons["Done"].tap()
        wait(settings, gone: true)

        app.typeKey("/", modifierFlags: .command)
        let shortcuts = app.navigationBars["Keyboard Shortcuts"]
        wait(shortcuts)
        XCTAssertTrue(app.staticTexts["Close Tab, ⌘W"].exists)
        shot("keyboard-shortcuts")
        shortcuts.buttons["Done"].tap()
        wait(shortcuts, gone: true)

        app.typeKey("n", modifierFlags: [.command, .option])
        wait(app.staticTexts["New chat"])
        shot("new-chat-shortcut")
        app.buttons["Close"].tap()
        wait(app.staticTexts["New chat"], gone: true)
    }

    /// A tab's chords in the split: ⇧⌘C switches its mode, ⇧⌘F shows Files and back, ⌘] and ⌘[ step along the strip
    /// (round the end); without a tab shown they do not apply.
    func testTabShortcuts() throws {
        let app = launch()
        wait(dispatchRow(app))
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["No tab open"].waitForExistence(timeout: 1), "No tab: Next Tab does not apply")

        dispatchRow(app).tap()
        let chat = segment(app, "Chat"), terminal = segment(app, "Terminal")
        wait(terminal)
        let first = selectedPill(app)
        XCTAssertNotNil(first)
        let before = chat.isSelected
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue((before ? terminal : chat).waitForSelection(), "⇧⌘C switches the segment")
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue((before ? chat : terminal).waitForSelection(), "and back")
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(segment(app, "Files").waitForSelection(), "⇧⌘F: Files")
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(terminal.waitForSelection(), "and back to Terminal")

        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(waitForSelectedPill(app, first, not: true), "⌘]: the next tab, selected in the strip")
        let second = selectedPill(app)
        shot("split-next-tab")
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(waitForSelectedPill(app, first), "⌘[: back to the first")
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(waitForSelectedPill(app, second), "⌘[ round the end")
    }

    /// Toggle Sidebar (⌃⌘S, and the Mac's hidden ⌘\\) hides the sidebar beside a tab and brings it back; with it
    /// hidden ⌘] steps to the next tab, which keeps the window, and ⌘1 and ⌘2 bring the sidebar back on their section.
    /// Without a tab it does not apply.
    func testToggleSidebarShortcuts() throws {
        let app = launch()
        let row = dispatchRow(app)
        wait(row)
        let hide = app.buttons["Hide sidebar"], show = app.buttons["Show sidebar"]
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(row.isHittable, "No tab: the sidebar is all there is")

        row.tap()
        wait(segment(app, "Terminal"))
        let first = selectedPill(app)
        app.typeKey("s", modifierFlags: [.command, .control])
        wait(show)
        XCTAssertFalse(row.isHittable, "⌃⌘S: the sidebar is out of the window")
        XCTAssertTrue(app.buttons["Space switcher"].exists, "The strip leads with the space's capsule")
        shot("toggle-sidebar-hidden")
        app.typeKey("]", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(show.exists, "⌘]: the next tab keeps the window")
        XCTAssertTrue(waitForSelectedPill(app, first, not: true))
        let next = selectedPill(app)
        app.typeKey("\\", modifierFlags: .command)
        XCTAssertTrue(row.waitForHittable(), "⌘\\: back")
        XCTAssertEqual(selectedPill(app), next, "the tab ⌘] showed")

        app.typeKey("s", modifierFlags: [.command, .control])
        wait(show)
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(filter(app).waitForValue(prefix: "Agents"), "⌘2 brings the sidebar back on Agents")
        XCTAssertTrue(hide.isHittable)
        app.typeKey("s", modifierFlags: [.command, .control])
        wait(show)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(filter(app).waitForValue(prefix: "All"), "⌘1 on All")
        XCTAssertTrue(row.waitForHittable())
    }

    /// The host key questions fit an iPad either way up: a page sheet, every row above the buttons (a form sheet cut
    /// the trusted key's row and the footnote under them), and the text names the iPad.
    func testHostKeySheetsFitAnIPad() throws {
        for (scripted, title, button, last) in [("trust", "Trust this host?", "Trust", "ssh-keygen"),
                                                 ("mismatch", "Host key changed", "Remove and retry", "Trusted on")] {
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                let app = launch(scripted)
                wait(app.staticTexts[title], timeout: 10)
                let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", last)).firstMatch
                wait(row)
                XCTAssertLessThanOrEqual(row.frame.maxY, app.buttons[button].frame.minY + 1, "\(scripted) \(orientation.rawValue)")
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'iPhone'")).firstMatch.exists)
                if scripted == "trust" {
                    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'from this iPad'")).firstMatch.exists)
                }
                shot("\(scripted)-" + (orientation == .portrait ? "portrait" : "landscape"))
                app.terminate()
            }
        }
    }

    /// ⌘= and ⌘+, ⌘- and ⌘0 go to the focused terminal's responder actions: a point at a time and back to the
    /// default, saved where Settings shows it; the open terminal redraws at the new size.
    func testFontSizeShortcuts() throws {
        let app = launch()
        let row = dispatchRow(app)
        wait(row)
        row.tap()
        let terminal = segment(app, "Terminal")
        wait(terminal)
        if !terminal.isSelected { terminal.tap() }
        app.typeKey("0", modifierFlags: .command)
        let base = try fontSize(app)
        shot("font-default")
        app.typeKey("=", modifierFlags: .command)
        app.typeKey("+", modifierFlags: .command)
        XCTAssertEqual(try fontSize(app), base + 2, "⌘= and ⌘+ each add a point")
        shot("font-larger")
        app.typeKey("-", modifierFlags: .command)
        XCTAssertEqual(try fontSize(app), base + 1)
        app.typeKey("0", modifierFlags: .command)
        XCTAssertEqual(try fontSize(app), base, "⌘0 resets")
    }

    /// The terminal font size Settings shows ("12 pt"), read through ⌘, and closed again.
    private func fontSize(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.navigationBars["Settings"]
        wait(settings, file: file, line: line)
        let label = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' pt'")).firstMatch
        wait(label, file: file, line: line)
        // "Font size, 12 pt" (the row reads as one element).
        let number = label.label.split(separator: " ").dropLast().last.map(String.init) ?? ""
        let size = try XCTUnwrap(Double(number), label.label)
        settings.buttons["Done"].tap()
        wait(settings, gone: true, file: file, line: line)
        return size
    }

    /// New host from the sidebar's empty state and New chat (⌥⌘N), each a form sheet over the split.
    func testNewInBothSections() throws {
        let app = launch("empty")
        wait(app.staticTexts["No hosts yet"], timeout: 10)
        app.buttons["Add host"].tap()
        let newHost = app.navigationBars["New host"]
        wait(newHost)
        XCTAssertLessThan(newHost.frame.width, app.windows.firstMatch.frame.width * 0.9, "New host is a form sheet")
        shot("new-host")
        app.buttons["Cancel"].tap()
        wait(newHost, gone: true)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "No tab bar beside the split")

        app.typeKey("n", modifierFlags: [.command, .option])
        wait(app.staticTexts["New chat"])
        shot("new-chat")
        app.buttons["Close"].tap()
        wait(app.staticTexts["New chat"], gone: true)
    }
}

private extension XCUIElement {
    /// Waits for the element to be selected (a segment, a tab bar item, a marked row).
    func waitForSelection(timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the element's value to start with `prefix` (the filter menu's "Agents, 2 need you").
    func waitForValue(prefix: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value BEGINSWITH %@", prefix)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }

    /// Waits for the element to be hittable (the sidebar's slide back).
    func waitForHittable(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "hittable == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
