import UIKit
import XCTest

/// The Spaces redesign (P1–P3, W0) on the mockup's sample (`-DispatchSpacesMockup`): the filter chips, the OFFLINE
/// group folding and its held menu, the Detached list, the space screen's menu, swipe, held New tab and Edit, and
/// a tab's menu from its host disc (X9b). `testFidelity` writes each mockup state, light and dark, to
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

    /// A screenshot attached to the result, and written to `DISPATCH_UI_SHOTS` when set (for review).
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["DISPATCH_UI_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    private func wait(_ element: XCUIElement, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(message) \(element)", file: file, line: line)
    }

    private static func row(_ app: XCUIApplication, _ identifier: String, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", identifier, label)).firstMatch
    }

    /// A short, slow drag to the left that shows a row's swipe actions: `swipeLeft` goes far and fast enough to be a full
    /// swipe, which closes a tab.
    private static func revealSwipe(_ row: XCUIElement) {
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
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

    /// Agents' filter chips as Spaces': All with one bubble, as tall and about as wide as Spaces' All.
    func testAgentsChipsMatchSpaces() {
        // The demo hosts: Spaces and Agents both filled.
        let app = XCUIApplication()
        app.launchEnvironment = ["DISPATCH_MOBILE_DEMO": "1"]
        app.launchArguments = ["-appearance", "dark"]
        app.launch()
        let spaces = app.descendants(matching: .any)["spaces-filter"].buttons["All"]
        XCTAssertTrue(spaces.waitForExistence(timeout: 15), "Spaces' chips")
        let size = spaces.frame.size
        shot("spaces-chips")
        app.tabBars.buttons["Agents"].tap()
        let agents = app.descendants(matching: .any)["agents-filter"].buttons["All"]
        XCTAssertTrue(agents.waitForExistence(timeout: 15), "Agents' chips")
        Thread.sleep(forTimeInterval: 0.5)
        shot("agents-chips")
        XCTAssertEqual(agents.frame.height, size.height, accuracy: 0.5, "as tall")
        XCTAssertEqual(agents.frame.width, size.width, accuracy: 3, "as wide")
    }

    /// M1e: a host's header folds from anywhere but its disc; a space row's long press offers Edit (no Rename…), whose
    /// spaces' names are fields, each with a delete that asks first, and a drag's order stays after Done.
    func testSpacesEdit() {
        let app = launch(Self.sample)
        let first = Self.row(app, "space-row", "app"), second = Self.row(app, "space-row", "e2e")
        wait(first)
        XCTAssertLessThan(first.frame.minY, second.frame.minY, "the sample's order")
        // The host's header folds from the room between its name and its disc, not only from the name.
        let header = app.buttons["mba2"].firstMatch
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 3), "folded")
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        wait(first, "unfolded")
        first.press(forDuration: 1.2)
        wait(app.buttons["Edit"], "the row's Edit")
        XCTAssertFalse(app.buttons["Rename…"].exists, "renaming is Edit's")
        XCTAssertFalse(app.buttons["Edit Spaces"].exists)
        shot("spaces-row-menu")
        // The menu's Edit, below the row (the title's Edit is above it).
        let edits = app.buttons.matching(NSPredicate(format: "label == 'Edit'")).allElementsBoundByIndex
        edits.max { $0.frame.minY < $1.frame.minY }?.tap()
        wait(app.textFields["Rename app"], "the space's name field")
        shot("spaces-edit")
        // The delete control (the red minus before the name) asks as Terminate… does; Cancel leaves every row.
        app.buttons["Delete app"].tap()
        let terminate = app.alerts.firstMatch
        wait(terminate, "Terminate's question")
        XCTAssertTrue(terminate.label.contains("app"), terminate.label)
        terminate.buttons["Cancel"].tap()
        XCTAssertTrue(terminate.waitForNonExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        shot("spaces-edit-cancelled")
        XCTAssertTrue(app.textFields["Rename e2e"].exists, "Cancel leaves every row")
        let handle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'app'")).firstMatch
        let below = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'e2e'")).firstMatch
        wait(handle, "app's handle")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.6, thenDragTo: below.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.6)),
                     withVelocity: .slow, thenHoldForDuration: 0.6)
        Thread.sleep(forTimeInterval: 1)
        shot("spaces-edit-dragged")
        // Dropped past the host's last space, in the gap before the next host's: it goes last, not back.
        XCTAssertGreaterThan(app.textFields["Rename app"].frame.minY, app.textFields["Rename e2e"].frame.minY, "moved in Edit")
        // A host's header is a handle too: mba2 dropped under studio's spaces goes after studio, its spaces with it.
        let host = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'mba2'")).firstMatch
        let billing = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'billing'")).firstMatch
        wait(host, "mba2's handle")
        host.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.6,
            thenDragTo: billing.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)), withVelocity: .slow, thenHoldForDuration: 0.6)
        Thread.sleep(forTimeInterval: 1)
        shot("spaces-edit-host-dragged")
        XCTAssertGreaterThan(app.buttons["mba2 details"].frame.minY, app.buttons["studio details"].frame.minY, "mba2 after studio")
        XCTAssertGreaterThan(app.textFields["Rename e2e"].frame.minY, app.buttons["mba2 details"].frame.minY, "its spaces with it")
        // Back, so the rest of the test finds mba2 first.
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'mba2'")).firstMatch
        let studio = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'studio'")).firstMatch
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.6,
            thenDragTo: studio.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)), withVelocity: .slow, thenHoldForDuration: 0.6)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThan(app.buttons["mba2 details"].frame.minY, app.buttons["studio details"].frame.minY, "mba2 first again")
        app.buttons["Done"].tap()
        wait(first)
        Thread.sleep(forTimeInterval: 1)
        shot("spaces-edit-done")
        XCTAssertGreaterThan(first.frame.minY, second.frame.minY, "the order stays after Done")
    }

    /// P2: the space's menu behind its title capsule (P2c), the sort menu, a row's swipe (P2b) and Move to, New tab held
    /// (P2e), New chat, and Edit (P2d) with its name fields.
    func testSpaceScreen() {
        let app = launch(Self.sample + ["-DispatchTabsShow", "space:herdr:app"])
        let zsh = Self.row(app, "space-tab", "zsh")
        wait(zsh)
        XCTAssertTrue(app.buttons["space-new-chat"].exists, "New chat beside New tab")
        app.buttons["space-sort"].tap()
        wait(app.buttons["Manual"], "the sort menu")
        XCTAssertTrue(app.buttons["By time"].exists)
        app.buttons["Manual"].tap()
        XCTAssertEqual(app.buttons["space-sort"].value as? String, "Manual")
        // Back to the default: the choice is the device's, kept for the next launch.
        app.buttons["space-sort"].tap()
        wait(app.buttons["By time"])
        app.buttons["By time"].tap()
        zsh.press(forDuration: 1.2)
        wait(app.buttons["Move to"], "the row's Move to")
        // Edit in Rename…'s place, Move to under it, then Detach and Close Tab.
        XCTAssertFalse(app.buttons["Rename…"].exists, "renaming is Edit's")
        XCTAssertLessThan(app.buttons["Edit"].frame.minY, app.buttons["Move to"].frame.minY)
        XCTAssertLessThan(app.buttons["Move to"].frame.minY, app.buttons["Detach"].frame.minY)
        XCTAssertLessThan(app.buttons["Detach"].frame.minY, app.buttons["Close Tab"].frame.minY)
        shot("space-row-menu")
        app.buttons["Move to"].tap()
        wait(app.buttons["e2e"], "the host's other spaces")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        app.descendants(matching: .any)["space-menu"].firstMatch.tap()
        wait(app.buttons["Edit"])
        XCTAssertFalse(app.buttons["Rename…"].exists, "renaming is Edit's")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Detach'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Terminate…'")).firstMatch.exists)
        app.buttons["Edit"].tap()
        wait(app.buttons["Done"], "edit mode")
        XCTAssertTrue(app.textFields["space-name-field"].exists, "the space's name field")
        XCTAssertTrue(app.textFields["Rename zsh"].exists, "each tab's name field")
        XCTAssertFalse(app.buttons["space-new-tab"].exists, "no New tab while editing")
        app.buttons["Done"].tap()
        wait(app.buttons["space-new-tab"])
        Self.revealSwipe(zsh)
        wait(app.buttons["Close"], "the swipe's Close")
        XCTAssertFalse(app.buttons["Detach"].exists, "Detach is the tab menu's")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        app.buttons["space-new-tab"].press(forDuration: 1.2)
        wait(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Shell'")).firstMatch, "the held menu")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Claude'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["In another space…"].exists)
    }

    /// B7: a tab's title capsule is its menu: the conversation's items on Chat, the tab's (Rename… opens the rename
    /// dialog), the host's Stats. No space switcher on the phone: Back returns to the space.
    func testTabMenu() {
        let app = launch(Self.sample + ["-DispatchTabsShow", "tab:herdr:app:1"])
        let disc = app.descendants(matching: .any).matching(identifier: "tab-title-capsule").firstMatch
        wait(disc)
        XCTAssertFalse(app.buttons["space-switcher"].exists, "no switcher on a phone's tab")
        disc.tap()
        wait(app.buttons["Search"], "the conversation's items")
        XCTAssertTrue(app.buttons["Side Conversation"].exists)
        XCTAssertFalse(app.buttons["Side Conversation with Changes"].exists, "a side conversation with changes is /side's")
        shot("tab-header-menu")
        // Search, then Stats, then the side conversation; Rename…, Move to, then Close Tab; Detach is the rows'.
        XCTAssertLessThan(app.buttons["Search"].frame.minY, app.buttons["Stats"].frame.minY)
        XCTAssertLessThan(app.buttons["Stats"].frame.minY, app.buttons["Side Conversation"].frame.minY)
        XCTAssertLessThan(app.buttons["Rename…"].frame.minY, app.buttons["Move to"].frame.minY)
        XCTAssertLessThan(app.buttons["Move to"].frame.minY, app.buttons["Close Tab"].frame.minY)
        XCTAssertFalse(app.buttons["Conversation Mode"].exists, "conversation mode is the composer's")
        XCTAssertFalse(app.buttons["Detach"].exists, "Detach is the rows'")
        XCTAssertFalse(app.buttons["Terminate…"].exists, "Close Tab asks while work runs")
        XCTAssertTrue(app.buttons["Stats"].exists)
        app.buttons["Rename…"].tap()
        wait(app.alerts["Rename tab"], "the rename dialog")
        app.alerts["Rename tab"].buttons["Cancel"].tap()
        XCTAssertTrue(app.alerts["Rename tab"].waitForNonExistence(timeout: 3))
        app.buttons["tab-mode-button"].tap()
        wait(app.buttons["Terminal"], "the mode menu")
        app.buttons["Terminal"].tap()
        disc.tap()
        wait(app.buttons["Rename…"], "Terminal's menu")
        XCTAssertFalse(app.buttons["Search"].exists, "the conversation's items only on Chat")
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
            revealSwipe(row(app, "space-tab", "zsh"))
        }),
        Screen(id: "P2c", arguments: sample + ["-DispatchTabsShow", "space:herdr:app"], then: { app in
            app.descendants(matching: .any)["space-menu"].firstMatch.tap()
        }),
        Screen(id: "P2d", arguments: sample + ["-DispatchTabsShow", "space-edit:herdr:app"]),
        Screen(id: "P2e", arguments: sample + ["-DispatchTabsShow", "space:herdr:app"], then: { app in
            app.buttons["space-new-tab"].press(forDuration: 1.2)
        }),
        Screen(id: "X9b", arguments: sample + ["-DispatchTabsShow", "tab:herdr:app:1"]),
        Screen(id: "X9b-menu", arguments: sample + ["-DispatchTabsShow", "tab:herdr:app:1"], then: { app in
            app.descendants(matching: .any).matching(identifier: "tab-title-capsule").firstMatch.tap()
        }),
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
