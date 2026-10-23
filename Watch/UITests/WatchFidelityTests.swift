import XCTest

/// The redesign's screens (mockups/Watch, K1 to K8 but K7, which is a widget: `WatchComplicationTests`) on the scripted
/// mockup phone (`-DispatchWatchScripted mockup`, docs/watch.md, Fidelity). Each case opens its screen with the debug
/// hooks, checks what must show and, with `TEST_RUNNER_DISPATCH_WATCH_FIDELITY` naming a directory, saves the screen
/// there as `<ID>.png` (46 mm, 416 × 496), the pair of `mockups/shots/<ID>-*.png`.
@MainActor
final class WatchFidelityTests: XCTestCase {
    private let mba2 = "5E1D1A5C-57D1-4C0A-8000-000000000011"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Saves the screen as `<id>.png` when the directory is set; always attached to the result.
    private func save(_ id: String) throws {
        // The screen settles (a sheet's or a push's animation, the list's scroll).
        Thread.sleep(forTimeInterval: 1.5)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = id
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["DISPATCH_WATCH_FIDELITY"], !directory.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent(id + ".png"))
    }

    func testK1AgentsList() throws {
        let app = launch(["-DispatchWatchScripted", "mockup"])
        XCTAssertTrue(element(app, labelContaining: "Editing Sidebar.tsx").waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(element(app, labelContaining: "Allow cargo test --workspace?").exists)
        try save("K1")
    }

    /// Scrolled to its end with the Digital Crown, as a wrist does.
    func testK1bAgentsListScrolled() throws {
        let app = launch(["-DispatchWatchScripted", "mockup"])
        let last = element(app, labelContaining: "Docs site migration")
        XCTAssertTrue(element(app, labelContaining: "Editing Sidebar.tsx").waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<3 { XCUIDevice.shared.rotateDigitalCrown(delta: 0.5) }
        XCTAssertTrue(last.waitForExistence(timeout: 5) && last.isHittable, app.debugDescription)
        try save("K1b")
    }

    func testK2Thread() throws {
        let app = launch(["-DispatchWatchScripted", "mockup", "-DispatchWatchOpen", "\(mba2)/term_1"])
        XCTAssertTrue(element(app, labelContaining: "Added a ThemeToggle").waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["Reply"].exists)
        try save("K2")
    }

    func testK3Approval() throws {
        let app = launch(["-DispatchWatchScripted", "mockup", "-DispatchWatchOpen", "\(mba2)/term_2"])
        XCTAssertTrue(element(app, labelContaining: "Codex wants to run").waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["Allow"].exists)
        try save("K3")
    }

    func testK4Question() throws {
        let app = launch(["-DispatchWatchScripted", "mockup", "-DispatchWatchOpen", "\(mba2)/term_2", "-DispatchWatchSheet", "question:0"])
        XCTAssertTrue(element(app, labelContaining: "1 of 2").waitForExistence(timeout: 15), app.debugDescription)
        try save("K4")
    }

    func testK5ReplyConfirm() throws {
        let app = launch(["-DispatchWatchScripted", "mockup", "-DispatchWatchOpen", "\(mba2)/term_1",
                          "-DispatchWatchSheet", "reply:Use the sidebar header, and keep the setting in local storage"])
        XCTAssertTrue(element(app, labelContaining: "Your reply").waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["Send"].exists && app.buttons["Cancel"].exists)
        try save("K5")
    }

    func testK6Host() throws {
        let app = launch(["-DispatchWatchScripted", "mockup", "-DispatchWatchShow", "host:\(mba2)"])
        XCTAssertTrue(element(app, labelContaining: "CPU 34 percent").waitForExistence(timeout: 15), app.debugDescription)
        try save("K6")
    }

    func testK6bHostOffline() throws {
        let app = launch(["-DispatchWatchScripted", "mockup-offline", "-DispatchWatchShow", "host:\(mba2)"])
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(element(app, labelContaining: "Offline since").exists)
        try save("K6b")
        // Connect brings the scripted host back: the strip comes alive with its sparkline's peak.
        app.buttons["Connect"].tap()
        XCTAssertTrue(element(app, labelContaining: "peak 82 percent").waitForExistence(timeout: 10), app.debugDescription)
    }

    func testK8ReviewSent() throws {
        let app = launch(["-DispatchWatchScripted", "mockup-review"])
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(element(app, labelContaining: "Undo for 8 s").exists)
        try save("K8")
        app.buttons["Undo"].tap()
        XCTAssertTrue(element(app, labelContaining: "Editing Sidebar.tsx").waitForExistence(timeout: 10), "the card closes after Undo")
    }
}
