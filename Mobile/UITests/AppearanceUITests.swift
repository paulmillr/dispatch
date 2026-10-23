import XCTest

/// Every screen the Debug demo hooks reach, in light and dark (L1a, L2a and the dark M screens), at the largest text
/// sizes, and through Xcode's accessibility audit. Screenshots are attachments in the result bundle
/// (`xcrun xcresulttool export attachments`), named `<screen>-<scheme>`.
@MainActor
final class AppearanceUITests: XCTestCase {
    struct Screen {
        let id: String
        var environment: [String: String] = [:]
        var arguments: [String] = []
        /// What to tap after launch (New host's sheet, a pushed screen).
        var then: (@MainActor (XCUIApplication) -> Void)? = nil
    }

    static let sample = ["-DispatchTabsSample", "YES"]
    static let screens: [Screen] = [
        Screen(id: "M1d", environment: ["DISPATCH_MOBILE_SCRIPTED": "empty"]),
        Screen(id: "M8a", environment: ["DISPATCH_MOBILE_SCRIPTED": "empty"], then: { app in
            app.buttons["Add host"].tap()
            _ = app.navigationBars["New host"].waitForExistence(timeout: 5)
        }),
        Screen(id: "M2a", arguments: sample),
        Screen(id: "M2b", arguments: sample + ["-DispatchTabsFilter", "needsYou"]),
        Screen(id: "M1e", arguments: sample + ["-DispatchTabsShow", "edit"]),
        Screen(id: "M2c", arguments: sample + ["-DispatchTabsShow", "space:herdr:app"]),
        Screen(id: "M4d", arguments: sample + ["-DispatchTabsShow", "switcher:herdr:app:2"]),
        Screen(id: "M7a", arguments: sample + ["-DispatchTabsShow", "new-space"]),
        // A tab on its Terminal segment (the sample has no terminal behind it: M6a itself is AppearanceScreenshotTests').
        Screen(id: "tab", arguments: sample + ["-DispatchTabsShow", "tab:herdr:app:2"]),
    ] + ["M3a", "M3b", "M4a", "M4b", "M4c", "M5a", "M5b", "M5c", "M5f", "M9a",
         // The chat redesign: search, slash list, side conversation, goal and its sheet, conversation mode (listening
         // and reading aloud), Jump to latest, the turn footnote.
         "C1", "C2", "C3", "C4", "C4b", "C5", "C5r", "C6", "S6"].map {
        Screen(id: $0, environment: ["DISPATCH_MOBILE_CHAT_DEMO": $0])
    } + [
        Screen(id: "M5d", environment: ["DISPATCH_MOBILE_CHAT_DEMO": "M5b"], then: { app in
            let patch = app.buttons.matching(NSPredicate(format: "label CONTAINS 'idempotent.ts'")).firstMatch
            if patch.waitForExistence(timeout: 5) { patch.tap() }
            _ = app.staticTexts["Changes"].waitForExistence(timeout: 5)
        }),
    ]

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(_ screen: Screen, scheme: String, size: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = screen.environment
        app.launchArguments = screen.arguments + ["-appearance", scheme]
        if let size { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
        app.launch()
        // The demos load their fixtures and settle; the scripted hosts connect.
        Thread.sleep(forTimeInterval: 2.5)
        screen.then?(app)
        Thread.sleep(forTimeInterval: 1)
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testScreensInLightAndDark() {
        for screen in Self.selected {
            for scheme in ["light", "dark"] {
                let app = launch(screen, scheme: scheme)
                shot("\(screen.id)-\(scheme)")
                app.terminate()
            }
        }
    }

    /// xxxLarge and the largest accessibility size: nothing clips or overlaps (checked by eye in the attachments; the
    /// sizes themselves are unit-tested in DynamicTypeTests).
    func testScreensAtLargeTextSizes() {
        let ids: Set = ["M1d", "M2a", "M2b", "M3a", "M4b", "M4c", "M5a", "M5b", "M5c", "M5f", "tab", "M9a", "M4d", "M8a", "M7a"]
        for screen in Self.selected where ids.contains(screen.id) {
            for (size, label) in [("UICTContentSizeCategoryXXXL", "xxxLarge"), ("UICTContentSizeCategoryAccessibilityXXXL", "AX5")] {
                let app = launch(screen, scheme: "dark", size: size)
                shot("\(screen.id)-\(label)")
                app.terminate()
            }
        }
    }

    /// Xcode's accessibility audit over every screen in both schemes. Each issue fails the test with its element and
    /// description, except the kinds the mockup decides on purpose (`accepted`).
    /// `DISPATCH_APPEARANCE_SCREENS=M5a,M7a` (`TEST_RUNNER_…` through xcodebuild) limits a run to those screens.
    static var selected: [Screen] {
        guard let list = ProcessInfo.processInfo.environment["DISPATCH_APPEARANCE_SCREENS"] else { return screens }
        let ids = Set(list.split(separator: ",").map(String.init))
        return screens.filter { ids.contains($0.id) }
    }

    func testAccessibilityAudit() throws {
        for screen in Self.selected {
            for scheme in ["light", "dark"] {
                let app = launch(screen, scheme: scheme)
                let keyboard = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame : .null
                try app.performAccessibilityAudit { issue in
                    let accepted = Self.accepted(issue, screen: screen.id, keyboard: keyboard)
                    if !accepted {
                        let element = issue.element.map { "\($0.elementType.rawValue) “\($0.label)” \($0.identifier) \($0.frame)" } ?? "no element"
                        XCTFail("\(screen.id) \(scheme): \(issue.auditType) \(element): \(issue.compactDescription)")
                    }
                    return accepted
                }
                app.terminate()
            }
        }
    }

    /// Issues the design takes on purpose, each with its reason (docs/ios.md, Appearance).
    static func accepted(_ issue: XCUIAccessibilityAuditIssue, screen: String, keyboard: CGRect) -> Bool {
        let label = issue.element?.label ?? ""
        let frame = issue.element?.frame ?? .null
        switch issue.auditType {
        case .contrast:
            // The mockup's label colours at their system opacities (secondary 60 %, tertiary 30 %: details, times,
            // captions), the host tints and the pink app tint as text, and disabled controls at half opacity. The pairs
            // the mockup states are checked by MobileColorTests against WCAG instead.
            return true
        case .dynamicType:
            // The navigation bar's pills, titles and buttons grow to xxxLarge and stop (the bar keeps its height; the
            // system's own bar buttons do the same), as do Form buttons; the key capsules stop at accessibility1 with
            // the large content viewer; the terminal's grid and the code are monospace bodies with their own pinch
            // zoom.
            // Edit mode's Add host (M1e) is a list row's button: the check reports its title although it grows with the
            // text (seen in the AX5 screenshots).
            // Spaces' Needs you count is a badge in the chip row, which scrolls sideways instead of wrapping; a host's
            // name in edit mode's header keeps one line beside its controls below the accessibility sizes (M1e). The
            // switcher (M4d) caps its title and path at xxxLarge as a bar's are, in its sheet's bar.
            // Manage goal (C4b) is a medium sheet, the mockup's: its rows run on below the sheet's edge and scroll.
            return screen == "M5d" || screen == "C4b" || frame.maxY <= 120 || issue.element?.elementType == .button
                || (screen == "M1e" && label == "Add host")
                || (["M2a", "M2b"].contains(screen) && Int(label) != nil) || (screen == "M1e" && frame.height <= 30)
                || screen == "M4d"
        case .elementDetection:
            // Behind the switcher's sheet (M4d) the tab's terminal, a drawn grid, is hidden from VoiceOver while the
            // sheet is up.
            return screen == "M4d" && issue.element == nil
        case .sufficientElementDescription:
            // The keyboard's own predictive bar above its keys (its suggestion buttons have no label while empty).
            return label.isEmpty && !keyboard.isNull && frame.minY >= keyboard.minY - 60 && frame.maxY <= keyboard.maxY
        case .textClipped:
            // Row previews clamp to one or two lines as Mail's do (M2a, M3a: the list reports them without an
            // element), and New host's address placeholder is the system field's, truncated by the Form.
            // The space switcher (M4d, P3) is a sheet at its 560-point detent, which iOS draws a little scaled: the
            // check reports every text in it.
            // A space's title with its branch (P2) is one text with the branch glyph in it: the check measures the glyph's
            // spoken name ("branch") as text, wider than the glyph drawn.
            // Manage goal's rows below its medium sheet's edge (C4b), as above. Conversation mode's listening bar (C5,
            // C5r): its live words wrap and keep their end, but the audit measures them against the whole capsule,
            // waveform included, and reports them clipped however short.
            return issue.element == nil || (screen == "M8a" && issue.element?.elementType == .textField) || screen == "M4d"
                || (frame.maxY <= 120 && label.contains("  branch ")) || screen == "C4b"
                || (screen.hasPrefix("C5") && frame.height <= 60 && frame.minY > 600)
        case .elementDetection where screen == "C4b":
            // The thread dimmed behind the medium sheet, which is modal: its text is not reachable while it is up.
            return issue.element == nil
        default:
            return false
        }
    }
}
