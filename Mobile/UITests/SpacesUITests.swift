import UIKit
import XCTest

/// The Spaces redesign (P1–P3, W0) on the mockup's sample (`-DispatchSpacesMockup`): the filter chips, the OFFLINE
/// group folding and its held menu, the Detached list, the space screen's menu, swipe, held New tab and Edit tabs, and
/// the switcher from a tab's host disc. `testFidelity` writes each mockup state, light and dark, to
/// `build/mockup-review/<ID>-<scheme>.png` (`TEST_RUNNER_DISPATCH_MOCKUP_DIR` names another folder).
@MainActor
final class SpacesUITests: XCTestCase {
    struct Screen {
        let id: String
        var arguments: [String] = []
        var then: (@MainActor (XCUIApplication) -> Void)? = nil
    }

    static let sample = ["-DispatchTabsSample", "YES", "-DispatchSpacesMockup", "P1"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String], scheme: String = "dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-appearance", scheme]
        app.launch()
        Thread.sleep(forTimeInterval: 2)
        return app
    }

    private func wait(_ element: XCUIElement, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(message) \(element)", file: file, line: line)
    }

    private static func row(_ app: XCUIApplication, _ identifier: String, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", identifier, label)).firstMatch
    }

    /// P1b: Needs you keeps the hosts and spaces with an agent waiting (app on mba2, docs on studio) and hides the
    /// rest and the OFFLINE group; Agents keeps the spaces running one; All brings everything back.
    func testFilterChips() {
        let app = launch(Self.sample)
        let chips = app.descendants(matching: .any)["spaces-filter"]
        wait(Self.row(app, "space-row", "e2e"))
        XCTAssertEqual(chips.buttons["Needs you"].value as? String, "2", "two conversations wait")
        chips.buttons["Needs you"].tap()
        wait(Self.row(app, "space-row", "docs"))
        XCTAssertTrue(Self.row(app, "space-row", "app").exists)
        XCTAssertFalse(Self.row(app, "space-row", "e2e").exists, "nothing waits in e2e")
        XCTAssertFalse(Self.row(app, "space-row", "billing").exists)
        XCTAssertFalse(app.descendants(matching: .any)["spaces-offline"].exists, "no OFFLINE group while filtering")
        chips.buttons["Agents"].tap()
        wait(Self.row(app, "space-row", "billing"))
        XCTAssertFalse(Self.row(app, "space-row", "e2e").exists, "no agent in e2e")
        chips.buttons["All"].tap()
        wait(Self.row(app, "space-row", "e2e"))
        wait(app.descendants(matching: .any)["spaces-offline"])
    }

    /// W0, W0b: tapping the OFFLINE header folds the group to its header and unfolds it; held, it offers "Show
    /// offline hosts", which hides the group (the sample keeps neither across launches; `TabsSpacesTreeTests` checks
    /// that the app does).
    func testOfflineGroup() {
        let app = launch(Self.sample)
        let header = app.descendants(matching: .any)["spaces-offline"]
        wait(header)
        let ai = app.buttons["ai stats"]
        wait(ai, "the offline host's disc")
        header.tap()
        XCTAssertTrue(ai.waitForNonExistence(timeout: 3), "folded")
        header.tap()
        wait(ai, "unfolded")
        header.press(forDuration: 1.2)
        let toggle = app.switches["Show offline hosts"].exists ? app.switches["Show offline hosts"] : app.buttons["Show offline hosts"]
        wait(toggle, "the held menu")
        toggle.tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 3), "hidden")
    }

    /// P1's Detached row opens the host's detached list with Restore and Restore all.
    func testDetachedList() {
        let app = launch(Self.sample)
        let detached = app.buttons["Detached on mba2"]
        wait(detached)
        XCTAssertEqual(detached.value as? String, "2")
        detached.tap()
        wait(app.buttons["Restore playwright"])
        XCTAssertTrue(app.buttons["Restore storybook"].exists)
        XCTAssertTrue(app.buttons["Restore all"].exists)
    }

    /// P2: the space's menu (P2c), a row's swipe (P2b), New tab held (P2e) and Edit tabs (P2d).
    func testSpaceScreen() {
        let app = launch(Self.sample + ["-DispatchTabsShow", "space:herdr:app"])
        let zsh = Self.row(app, "space-tab", "zsh")
        wait(zsh)
        app.buttons["space-menu"].tap()
        wait(app.buttons["Rename…"])
        XCTAssertTrue(app.buttons["Edit tabs"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Detach'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Terminate…'")).firstMatch.exists)
        app.buttons["Edit tabs"].tap()
        wait(app.buttons["Done"], "edit mode")
        XCTAssertFalse(app.buttons["space-new-tab"].exists, "no New tab while editing")
        app.buttons["Done"].tap()
        wait(app.buttons["space-new-tab"])
        zsh.swipeLeft()
        wait(app.buttons["Detach"], "the swipe's Detach")
        XCTAssertTrue(app.buttons["Close"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        app.buttons["space-new-tab"].press(forDuration: 1.2)
        wait(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Shell'")).firstMatch, "the held menu")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Claude'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["In another space…"].exists)
    }

    /// P3: a tab's host disc opens the switcher; a tab row switches the screen to that tab and closes it.
    func testSwitcher() {
        let app = launch(Self.sample + ["-DispatchTabsShow", "tab:herdr:app:2"])
        let disc = app.buttons["space-switcher"]
        wait(disc)
        disc.tap()
        let zsh = app.buttons.matching(NSPredicate(format: "label == 'zsh'")).firstMatch
        wait(zsh, "the space's tabs")
        XCTAssertTrue(app.buttons["Close space"].exists)
        XCTAssertTrue(app.buttons["switcher-host"].exists)
        zsh.tap()
        XCTAssertTrue(app.buttons["Close space"].waitForNonExistence(timeout: 3), "closed")
        wait(app.staticTexts["zsh"], "the zsh tab's screen")
    }

    // MARK: Fidelity

    static let screens: [Screen] = [
        Screen(id: "P1", arguments: sample),
        Screen(id: "P1b", arguments: sample + ["-DispatchTabsFilter", "needsYou"]),
        Screen(id: "W0", arguments: ["-DispatchTabsSample", "YES", "-DispatchSpacesMockup", "W0", "-DispatchTabsCollapse", "studio"]),
        Screen(id: "W0b", arguments: ["-DispatchTabsSample", "YES", "-DispatchSpacesMockup", "W0", "-DispatchTabsCollapse", "studio",
                                      "-DispatchTabsOfflineFolded", "YES"]),
        Screen(id: "W0c", arguments: ["-DispatchTabsSample", "YES", "-DispatchSpacesMockup", "W0", "-DispatchTabsCollapse", "studio"],
               then: { app in app.descendants(matching: .any)["spaces-offline"].press(forDuration: 1.2) }),
        Screen(id: "P2", arguments: sample + ["-DispatchTabsShow", "space:herdr:app"]),
        Screen(id: "P2b", arguments: sample + ["-DispatchTabsShow", "space:herdr:app"], then: { app in
            row(app, "space-tab", "zsh").swipeLeft()
        }),
        Screen(id: "P2c", arguments: sample + ["-DispatchTabsShow", "space:herdr:app"], then: { app in
            app.buttons["space-menu"].tap()
        }),
        Screen(id: "P2d", arguments: sample + ["-DispatchTabsShow", "space-edit:herdr:app"]),
        Screen(id: "P2e", arguments: sample + ["-DispatchTabsShow", "space:herdr:app"], then: { app in
            app.buttons["space-new-tab"].press(forDuration: 1.2)
        }),
        Screen(id: "P3", arguments: sample + ["-DispatchTabsShow", "switcher:herdr:app:2"]),
    ]

    static var output: URL {
        if let folder = ProcessInfo.processInfo.environment["DISPATCH_MOCKUP_DIR"] { return URL(fileURLWithPath: folder) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/mockup-review")
    }

    /// Every Spaces mockup state in dark and light, written beside the other streams' pairs and attached with the
    /// mockup's render (`FidelityUITests.pair`). `TEST_RUNNER_DISPATCH_FIDELITY_SCREENS=P2b,W0c` limits a run.
    func testFidelity() throws {
        continueAfterFailure = true
        let limit = ProcessInfo.processInfo.environment["DISPATCH_FIDELITY_SCREENS"].map { Set($0.split(separator: ",").map(String.init)) }
        try? FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        for screen in Self.screens where limit?.contains(screen.id) ?? true {
            for scheme in ["dark", "light"] {
                let app = launch(screen.arguments, scheme: scheme)
                Thread.sleep(forTimeInterval: 1)
                screen.then?(app)
                Thread.sleep(forTimeInterval: 1.5)
                let shot = XCUIScreen.main.screenshot()
                try shot.pngRepresentation.write(to: Self.output.appendingPathComponent("\(screen.id)-\(scheme).png"))
                let attachment = XCTAttachment(screenshot: shot)
                attachment.name = "\(screen.id)-\(scheme)-app"
                attachment.lifetime = .keepAlways
                add(attachment)
                if let mockup = FidelityUITests.shot(screen.id, scheme: scheme) {
                    let pair = XCTAttachment(data: FidelityUITests.pair(mockup: mockup, app: shot.image, whole: true).pngData() ?? Data(),
                                             uniformTypeIdentifier: "public.png")
                    pair.name = "\(screen.id)-\(scheme)"
                    pair.lifetime = .keepAlways
                    add(pair)
                }
                app.terminate()
            }
        }
    }
}
