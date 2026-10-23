import XCTest

/// Chat, Agents and Code on an iPad: the composer's hardware keys (sent with `typeKey`, which delivers hardware key
/// events), focus when a tab opens in the split's detail column, and the wide layouts in both orientations. Every case
/// pins the keyboard with `-DispatchHardwareKeyboard` so it does not depend on the simulator's setting, and skips on an
/// iPhone. Screenshots are attached to the result; with `DISPATCH_UI_SHOTS` (`TEST_RUNNER_DISPATCH_UI_SHOTS` through
/// xcodebuild) set to a folder they are also written there, for review.
@MainActor
final class ChatIPadUITests: XCTestCase {
    private static let sample = ["-DispatchTabsSample", "YES"]
    /// The sample's first agent tab, on its Chat segment (the Chat demo's M4a thread).
    private static let chatTab = sample + ["-DispatchTabsShow", "tab:herdr:app:1"]

    override func setUp() async throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ arguments: [String] = [], keyboard: Bool, environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-DispatchHardwareKeyboard", keyboard ? "YES" : "NO"]
        app.launchEnvironment = environment.merging(["DISPATCH_MOBILE_STORE": "memory"]) { new, _ in new }
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["DISPATCH_UI_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    /// A screenshot in each orientation, settled.
    private func shots(_ name: String) {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1.5)
            shot(name + (orientation == .portrait ? "-portrait" : "-landscape"))
        }
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1)
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement { app.textViews["Message"] }

    private func focused(_ element: XCUIElement) -> Bool { element.value(forKey: "hasKeyboardFocus") as? Bool ?? false }

    /// Waits up to `timeout` for `condition`.
    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// The thread in the detail column, with the composer focused (a hardware keyboard).
    private func openChat() -> (XCUIApplication, XCUIElement) {
        let app = launch(Self.chatTab, keyboard: true)
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(eventually { focused(field) }, "the composer takes focus as the tab opens")
        return (app, field)
    }

    func testAHardwareKeyboardFocusesTheComposerInTheDetailColumn() {
        let (app, field) = openChat()
        field.typeText("Typed at once")
        XCTAssertEqual(app.keyboards.count, 0, "no software keyboard with a hardware one")
        XCTAssertEqual(field.value as? String, "Typed at once")
        XCTAssertFalse(app.buttons["Backtick"].exists, "no key row without a software keyboard")
        shot("focus-hardware")
    }

    func testATouchIPadOpensTheTabWithoutRaisingTheKeyboard() {
        let app = launch(Self.chatTab, keyboard: false)
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(focused(field))
        XCTAssertEqual(app.keyboards.count, 0)
    }

    /// ⌘E puts the draft in editor mode (where Return starts a line) and the composer says what sends; again, back.
    /// Return and Esc themselves are `ChatIPadTests`': XCUITest's `typeKey` cannot deliver them on the iOS 27.0
    /// simulator (docs/ios.md, Testing).
    func testCommandETogglesEditorMode() {
        let (app, field) = openChat()
        let hint = app.staticTexts["composer-editor-mode"]
        field.typeText("Draft")
        XCTAssertFalse(hint.exists)
        field.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(hint.waitForExistence(timeout: 3), "⌘E enters editor mode")
        XCTAssertTrue(focused(field))
        shot("editor-mode")
        field.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(eventually { !hint.exists }, "and leaves it")
        XCTAssertEqual(field.value as? String, "Draft", "the draft kept")
    }

    /// Docks (or floats) the shown software keyboard (`setKeyboardFloating`): a keyboard another run left floating
    /// must not decide a case about the docked one.
    private func setFloating(_ float: Bool, _ app: XCUIApplication) {
        XCTAssertTrue(app.setKeyboardFloating(float), float ? "the keyboard floats" : "the keyboard is docked")
    }

    /// On a touch iPad the docked software keyboard raises the composer above it, in both orientations, with the
    /// key row riding on it.
    func testTheSoftwareKeyboardNeverCoversTheComposer() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = launch(Self.chatTab, keyboard: false)
            let field = composer(app)
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            setFloating(false, app)
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY + 0.5, "\(orientation.rawValue)")
            XCTAssertTrue(app.buttons["Backtick"].exists, "the key row shows on a touch iPad")
            shot("software-keyboard-" + (orientation == .portrait ? "portrait" : "landscape"))
            app.terminate()
        }
    }

    /// Rotating with the keyboard up keeps the composer focused and the keyboard up, as the standalone thread does: the
    /// split stays a split while the keyboard takes the window's height (`MobileWindowReader`).
    func testRotatingKeepsTheComposerFocused() {
        let app = launch(Self.chatTab, keyboard: false)
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        XCTAssertTrue(eventually { focused(field) })
        setFloating(false, app)
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(focused(field), "the composer keeps focus across rotation")
        XCTAssertEqual(app.keyboards.count, 1)
        XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 0.5)
    }

    /// A floating keyboard leaves the composer where it rests, at the bottom (the user moves the keyboard), as the
    /// terminal's capsule stays: SwiftUI's inset for it had lifted the composer part of the way, under the keyboard.
    /// Docked again, the keyboard raises it.
    func testAFloatingKeyboardLeavesTheComposerAtTheBottom() {
        let app = launch(Self.chatTab, keyboard: false)
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        let resting = field.frame
        field.tap()
        setFloating(true, app)
        addTeardownBlock { @MainActor [self] in if app.state == .runningForeground { setFloating(false, app) } }
        Thread.sleep(forTimeInterval: 1)
        shot("floating-keyboard")
        // The key row shows under the field while it edits (it rides on a docked keyboard): the two end where the
        // composer rests.
        let keys = app.buttons["Backtick"].frame
        XCTAssertEqual(keys.maxY, resting.maxY, accuracy: 2, "the key row at the bottom under a floating keyboard")
        XCTAssertEqual(field.frame.maxY, keys.minY - 8, accuracy: 12, "the field just above it")
        setFloating(false, app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 0.5, "raised by the docked one")
    }

    /// A message's details push in the detail column, its own stack, and Back returns to the thread there; the
    /// sidebar stays.
    func testMessageDetailsPushInTheDetailColumn() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = launch(Self.chatTab, keyboard: true)
            let message = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Stripe retries'")).firstMatch
            XCTAssertTrue(message.waitForExistence(timeout: 10))
            let column = message.frame.minX - 40
            message.tap()
            let title = app.staticTexts["Message"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(title.frame.minX, column, "the details are in the detail column")
            XCTAssertTrue(app.staticTexts["Spaces"].exists, "beside the sidebar")
            shot("details-" + (orientation == .portrait ? "portrait" : "landscape"))
            app.buttons.matching(NSPredicate(format: "label == 'app' OR label CONTAINS 'Back'")).firstMatch.tap()
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    /// The Agents list as a split's sidebar: the narrowest (263 points, the unfolded Duo's) and an iPad's.
    func testAgentsListAtSidebarWidths() {
        for width in [263, 320, 375] {
            let app = launch(keyboard: true, environment: ["DISPATCH_MOBILE_CHAT_DEMO": "M3a",
                                                         "DISPATCH_MOBILE_CHAT_DEMO_WIDTH": "\(width)"])
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'billing'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertLessThanOrEqual(row.frame.maxX, CGFloat(width) + 1, "the row stays in its column")
            shots("agents-\(width)")
            app.terminate()
        }
    }

    /// The pointer over an Agents row lights it as Spaces' rows light (`tabsRowHover`). Screenshot only: the system
    /// draws the effect outside the app's hierarchy.
    func testAgentsRowsLightUnderThePointer() {
        let app = launch(keyboard: true, environment: ["DISPATCH_MOBILE_CHAT_DEMO": "M3a", "DISPATCH_MOBILE_CHAT_DEMO_WIDTH": "320"])
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'billing'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.hover()
        Thread.sleep(forTimeInterval: 1)
        shot("agents-row-hover")
        XCTAssertTrue(row.isHittable)
    }

    /// The screens of this stream at iPad widths, both orientations, for review (attached; written with
    /// `DISPATCH_UI_SHOTS`).
    func testWideScreens() throws {
        var app = launch(Self.chatTab, keyboard: true)
        XCTAssertTrue(app.staticTexts["Make billing webhook retries idempotent."].waitForExistence(timeout: 10))
        shots("split-chat")
        app.terminate()
        app = launch(Self.sample, keyboard: true)
        // The iPad's sidebar has no tab bar: Agents is its filter.
        app.buttons["Filter"].firstMatch.tap()
        app.buttons["Agents"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        shots("split-agents")
        app.terminate()
        demos(["M4a", "M4b", "M5c"])
    }

    /// The rest of the demo screens, both orientations (a case of its own: launches are slow).
    func testWideDemoScreens() throws {
        demos(["M5f", "M5b", "M5d", "M3b"])
    }

    private func demos(_ screens: [String]) {
        for screen in screens {
            let app = launch(keyboard: true, environment: ["DISPATCH_MOBILE_CHAT_DEMO": screen == "M5d" ? "M5b" : screen])
            Thread.sleep(forTimeInterval: 2.5)
            if screen == "M5d" {
                let patch = app.buttons.matching(NSPredicate(format: "label CONTAINS 'idempotent.ts'")).firstMatch
                if patch.waitForExistence(timeout: 5) { patch.tap() }
                Thread.sleep(forTimeInterval: 1)
            }
            shots("demo-" + screen)
            app.terminate()
        }
    }
}
