import XCTest

/// Drives the transitions the frame checks record (docs/ios.md, Testing, Frame checks): each case performs one family
/// of transitions with a pause before and after every step, so a screen recording (`xcrun simctl io <device>
/// recordVideo`) holds each resting state, and `scripts/transition-frames.swift` lists every picture at rest and every
/// frame in motion. Each case also checks that the step reached its state. `TEST_RUNNER_DISPATCH_TRANSITION_PAUSE`
/// changes the pause (seconds, 1.5 by default).
@MainActor
final class TransitionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var pause: TimeInterval {
        ProcessInfo.processInfo.environment["DISPATCH_TRANSITION_PAUSE"].flatMap(Double.init) ?? 1.5
    }

    private func launch(environment: [String: String] = [:], arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = environment
        app.launchArguments = arguments + ["-appearance", "dark"]
        app.launch()
        Thread.sleep(forTimeInterval: 2.5)
        return app
    }

    private func rest() { Thread.sleep(forTimeInterval: pause) }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element)", file: file, line: line)
        element.tap()
        rest()
    }

    private static let sample = ["-DispatchTabsSample", "YES"]

    /// New host, New chat and Settings presented and dismissed.
    func testSheets() {
        let empty = launch(environment: ["DISPATCH_MOBILE_SCRIPTED": "empty"])
        rest()
        tap(empty.buttons["New host"])
        XCTAssertTrue(empty.navigationBars["New host"].exists)
        tap(empty.buttons["Cancel"])
        empty.terminate()

        let app = launch(environment: ["DISPATCH_MOBILE_SCRIPTED": "1"])
        rest()
        tap(app.buttons["Agents"])
        tap(app.buttons["New chat"])
        XCTAssertTrue(app.staticTexts["New chat"].exists)
        tap(app.buttons["Close"])
        tap(app.buttons["Spaces"])
        tap(app.buttons["Edit"])
        tap(app.buttons["Settings"])
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        tap(app.navigationBars["Settings"].buttons["Done"])
    }

    /// New space from the space picker, and dismissed.
    func testNewSpaceSheet() {
        let app = launch(arguments: Self.sample + ["-DispatchTabsShow", "pick"])
        rest()
        // At the end of the picker, under the hosts' spaces.
        let newSpace = app.buttons["New space…"]
        if !newSpace.waitForExistence(timeout: 2) || !newSpace.isHittable {
            app.swipeUp()
            rest()
        }
        tap(newSpace)
        XCTAssertTrue(app.staticTexts["New space"].exists)
        tap(app.buttons["Cancel"])
    }

    /// A tab's Terminal / Chat segments, back and forth.
    func testSegmentSwitch() {
        let app = launch(arguments: Self.sample + ["-DispatchTabsShow", "tab:herdr:app:1"])
        rest()
        for _ in 0..<2 {
            tap(app.buttons["Terminal"])
            tap(app.buttons["Chat"])
        }
    }

    /// M5a's thinking row unfolds into M5f and folds back.
    func testThinkingRow() {
        let app = launch(environment: ["DISPATCH_MOBILE_CHAT_DEMO": "M5a"])
        rest()
        for _ in 0..<2 {
            tap(app.buttons["Show steps"])
            tap(app.buttons["Hide steps"])
        }
    }

    /// M5c's queue card collapses with Done and opens again from its caption.
    func testQueueCard() {
        let app = launch(environment: ["DISPATCH_MOBILE_CHAT_DEMO": "M5c"])
        rest()
        for _ in 0..<2 {
            tap(app.buttons["Done"])
            tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Queued'")).firstMatch)
        }
    }

    /// M4b's Allow chip becomes the user's message.
    func testApprovalChip() {
        let app = launch(environment: ["DISPATCH_MOBILE_CHAT_DEMO": "M4b"])
        rest()
        tap(app.buttons["Allow"])
        rest()
    }

    /// The Agents filter pill (M3a) and Spaces' filter menu (M2a) on and off.
    func testFilters() {
        let agents = launch(environment: ["DISPATCH_MOBILE_CHAT_DEMO": "M3a"])
        rest()
        for _ in 0..<2 { tap(agents.buttons["Unread only"]) }
        agents.terminate()

        let app = launch(arguments: Self.sample)
        rest()
        tap(app.buttons["Sort and filter"])
        tap(app.buttons["Needs you"])
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sort and filter'")).firstMatch)
        tap(app.buttons["All"])
    }
}
