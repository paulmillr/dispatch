import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// WCAG 2 contrast over the asset catalog's colours, resolved in each scheme: an independent oracle for what the
/// mockup states (L1a, L2a: white on the light user bubble clears 4.5:1, labels read on the canvas, the dots show on
/// both canvases), in the spirit of the Mac's `test/contrast.swift`.
@MainActor
final class MobileColorTests: XCTestCase {
    enum Scheme: CaseIterable { case light, dark }

    struct RGBA { var r, g, b, a: Double }

    static func resolve(_ color: UIColor, _ scheme: Scheme) -> RGBA {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(r: r, g: g, b: b, a: a)
    }

    static func named(_ name: String) -> UIColor {
        guard let color = UIColor(named: name, in: .main, compatibleWith: nil) else {
            XCTFail("No colour \(name) in the asset catalog"); return .clear
        }
        return color
    }

    /// `top` over `bottom` (opaque).
    static func over(_ top: RGBA, _ bottom: RGBA) -> RGBA {
        RGBA(r: top.r * top.a + bottom.r * (1 - top.a), g: top.g * top.a + bottom.g * (1 - top.a),
             b: top.b * top.a + bottom.b * (1 - top.a), a: 1)
    }

    static func luminance(_ color: RGBA) -> Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
    }

    static func ratio(_ a: RGBA, _ b: RGBA) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The contrast of `text` drawn on `background` (itself over `base` when translucent), in `scheme`.
    static func contrast(_ text: UIColor, on background: UIColor, base: UIColor = named("Canvas"), _ scheme: Scheme) -> Double {
        let ground = over(resolve(background, scheme), resolve(base, scheme))
        return ratio(over(resolve(text, scheme), ground), ground)
    }

    private func check(_ text: UIColor, on background: UIColor, base: UIColor? = nil, atLeast minimum: Double, _ what: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        for scheme in Scheme.allCases {
            let value = Self.contrast(text, on: background, base: base ?? Self.named("Canvas"), scheme)
            XCTAssertGreaterThanOrEqual(value, minimum, "\(what) in \(scheme): \(String(format: "%.2f", value)):1", file: file, line: line)
        }
    }

    /// L2a: your text on your bubble, the agent's on its grey (16 pt body text: 4.5:1).
    func testBubblesCarryBodyText() {
        check(Self.named("BubbleUserText"), on: Self.named("BubbleUser"), atLeast: 4.5, "your bubble's text")
        check(.label, on: Self.named("BubbleAgent"), atLeast: 4.5, "the agent's bubble text")
        check(.label, on: Self.named("ApprovalCode"), base: Self.named("BubbleAgent"), atLeast: 4.5, "the approval's command")
        check(Self.named("OnAccent"), on: Self.named("AccentColor"), atLeast: 4.5, "Allow, the call to action")
    }

    /// The light user bubble is the mockup's deeper pink, darkened only as far as white text needs.
    func testUserBubbleIsTheDeeperPinkInLight() {
        let light = Self.resolve(Self.named("BubbleUser"), .light), dark = Self.resolve(Self.named("BubbleUser"), .dark)
        XCTAssertEqual(light.r, light.b, accuracy: 0.01, "The pink's hue")
        XCTAssertLessThan(light.g, dark.g, "Deeper than the desktop pink")
        XCTAssertLessThan(Self.contrast(Self.named("BubbleUserText"), on: Self.named("BubbleUser"), .light), 4.8, "No darker than needed")
    }

    /// L1a: the label colours at their opacities on the canvas and on grouped rows.
    func testLabelsReadOnTheCanvasAndRows() {
        for background in ["Canvas", "GroupedRow", "RaisedRow"] {
            check(.label, on: Self.named(background), atLeast: 7, "the primary label on \(background)")
            check(.secondaryLabel, on: Self.named(background), atLeast: 3, "the secondary label on \(background)")
        }
    }

    /// Text in the state colours: the banner's amber (M4c), failures and diffs, the step badges on their faint tint.
    func testColouredTextReads() {
        check(Self.named("Caution"), on: Self.named("StateWorking").withAlphaComponent(0.14), atLeast: 4.5, "M4c's banner")
        check(Self.named("Caution"), on: Self.named("Canvas"), atLeast: 4.5, "the tmux warning")
        for name in ["Destructive", "Added"] { check(Self.named(name), on: Self.named("Canvas"), atLeast: 4.5, name) }
        for name in ["StepRead", "StepThink", "StepRun", "Added", "StepTool"] {
            // M5f's live log sits on the canvas, under the thinking row.
            let color = Self.named(name)
            check(color, on: color.dynamic(alpha: 0.13), atLeast: 4.5, "the \(name) badge")
        }
    }

    /// M5d, M5e: the syntax colours on the canvas and in the composer's panel (comments are quieter: 3:1).
    func testCodePaletteReads() {
        let roles: [(String, UIColor, Double)] = [("ink", CodePalette.ink, 4.5), ("keyword", CodePalette.keyword, 4.5),
                                                  ("call", CodePalette.call, 4.5), ("string", CodePalette.string, 4.5),
                                                  ("type", CodePalette.type, 4.5), ("number", CodePalette.number, 4.5),
                                                  ("comment", CodePalette.comment, 3)]
        for (name, color, minimum) in roles {
            check(color, on: Self.named("Canvas"), atLeast: minimum, "\(name) on the canvas")
            check(color, on: CodePalette.panel, atLeast: minimum, "\(name) in the panel")
            check(color, on: CodePalette.addedRow, atLeast: minimum, "\(name) on an added row")
            check(color, on: CodePalette.removedRow, atLeast: minimum, "\(name) on a removed row")
        }
    }

    /// The gutter dots stay the same in both schemes (L1a) and show on both canvases and on grouped rows.
    func testDotsShowOnBothCanvases() {
        for name in ["StateUnread", "StateWorking", "StateFinished"] {
            let light = Self.resolve(Self.named(name), .light), dark = Self.resolve(Self.named(name), .dark)
            XCTAssertEqual(light.r, dark.r, accuracy: 0.001); XCTAssertEqual(light.g, dark.g, accuracy: 0.001)
            for background in ["Canvas", "GroupedRow"] {
                // Distinct from the ground (a colour field, not text); the blue unread dot reads as a control would.
                check(Self.named(name), on: Self.named(background), atLeast: name == "StateUnread" ? 3 : 1.5, "\(name) on \(background)")
            }
        }
    }

    /// The canvas and the grouped greys are the system's (L1a: #F2F2F7 and white rows; black and #1C1C1E in dark).
    func testCanvasIsTheSystemGroupedGrey() {
        for scheme in Scheme.allCases {
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            for (name, system) in [("Canvas", UIColor.systemGroupedBackground), ("GroupedRow", .secondarySystemGroupedBackground)] {
                let ours = Self.resolve(Self.named(name), scheme)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                system.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
                XCTAssertEqual(ours.r, r, accuracy: 0.01, "\(name) in \(scheme)")
                XCTAssertEqual(ours.b, b, accuracy: 0.01, "\(name) in \(scheme)")
            }
        }
    }
}

/// The `appearance` default (Settings writes it): dark unless it says otherwise, applied live at the root.
@MainActor
final class MobileAppearanceTests: XCTestCase {
    func testTheStoredValueChoosesTheScheme() {
        XCTAssertEqual(MobileAppearance(stored: nil), .dark, "Dark by default, as the mockup draws the app")
        XCTAssertEqual(MobileAppearance(stored: "light").colorScheme, .light)
        XCTAssertEqual(MobileAppearance(stored: "dark").colorScheme, .dark)
        XCTAssertNil(MobileAppearance(stored: "system").colorScheme, "System follows the phone")
        XCTAssertEqual(MobileAppearance(stored: "sepia"), .dark, "An unknown value is the default")
        XCTAssertEqual(MobileAppearance.key, "appearance")
    }

    /// Changing the default restyles the shown window at once, and System clears the override.
    func testTheRootFollowsTheDefaultLive() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: MobileAppearance.key)
        defer { defaults.set(saved, forKey: MobileAppearance.key) }
        defaults.removeObject(forKey: MobileAppearance.key)
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.rootViewController = UIHostingController(rootView: Color.canvas.mobileAppearance())
        window.isHidden = false
        defer { window.isHidden = true }
        try await TestSupport.eventually { window.traitCollection.userInterfaceStyle == .dark }
        defaults.set("light", forKey: MobileAppearance.key)
        try await TestSupport.eventually { window.traitCollection.userInterfaceStyle == .light }
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
        defaults.set("system", forKey: MobileAppearance.key)
        try await TestSupport.eventually { window.overrideUserInterfaceStyle == .unspecified }
        defaults.set("dark", forKey: MobileAppearance.key)
        try await TestSupport.eventually { window.traitCollection.userInterfaceStyle == .dark }
    }
}
