import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// Settings' look (G1 to G4): the terminal's font, scheme, contrast, cursor and bold colours reaching the terminals,
/// chat's font and size, the app's theme, and the screens that set them.
@MainActor
final class SettingsStyleTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "settings-style-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    // MARK: Persistence

    func testDefaultsAreTheMockupsAndTheMacs() {
        let settings = MobileSettings(defaults: defaults())
        XCTAssertEqual(settings.theme, .automatic)
        XCTAssertEqual(settings.terminalFont, "JetBrains Mono")
        XCTAssertEqual(settings.terminalScheme, "dispatch-black")
        XCTAssertFalse(settings.improveTextContrast, "off, as the Mac's")
        XCTAssertFalse(settings.boldIsBright)
        XCTAssertEqual(settings.cursor, .block)
        XCTAssertTrue(settings.cursorBlink)
        XCTAssertEqual(settings.chatFont, .system)
        XCTAssertEqual(settings.chatTextSize, .standard)
        XCTAssertTrue(settings.notifyNeedsYou && settings.notifyFinished && settings.notifyFailed)
        XCTAssertEqual(settings.notificationSound, .standard)
        XCTAssertTrue(settings.notificationText && settings.notificationBadge)
        XCTAssertEqual(settings.notificationSummary, "Sound, text", "G1's Notifications row")
    }

    func testEveryChoiceIsSavedAndReadBack() {
        let store = defaults()
        let settings = MobileSettings(defaults: store)
        settings.theme = .nautical
        settings.terminalFont = "Fira Code"
        settings.terminalScheme = "Nord"
        settings.improveTextContrast = true
        settings.boldIsBright = true
        settings.cursor = .underline
        settings.cursorBlink = false
        settings.chatFont = .comicSans
        settings.chatTextSize = .larger
        settings.notifyNeedsYou = false
        settings.notifyFinished = false
        settings.notifyFailed = false
        settings.notificationSound = .shipsBell
        settings.notificationText = false
        settings.notificationBadge = false
        XCTAssertEqual(store.string(forKey: "theme"), "nautical", "the key the root reads")
        XCTAssertEqual(store.string(forKey: "chat.font"), "Comic Sans", "the Mac's names")

        let read = MobileSettings(defaults: store)
        XCTAssertEqual(read.theme, .nautical)
        XCTAssertEqual(read.terminalFont, "Fira Code")
        XCTAssertEqual(read.terminalScheme, "Nord")
        XCTAssertTrue(read.improveTextContrast && read.boldIsBright)
        XCTAssertEqual(read.cursor, .underline)
        XCTAssertFalse(read.cursorBlink)
        XCTAssertEqual(read.chatFont, .comicSans)
        XCTAssertEqual(read.chatTextSize, .larger)
        XCTAssertFalse(read.notifyNeedsYou || read.notifyFinished || read.notifyFailed || read.notificationText || read.notificationBadge)
        XCTAssertEqual(read.notificationSound, .shipsBell)
        XCTAssertEqual(read.notificationSummary, "Ship's bell")
        XCTAssertEqual(read.alertPolicy, AgentAlerts.Policy(needsYou: false, finished: false, failed: false, sound: .shipsBell,
                                                             text: false, badge: false))
        read.notificationSound = .none
        XCTAssertEqual(read.notificationSummary, "Silent")
    }

    /// A font, scheme or value no longer offered falls back without losing the rest.
    func testUnknownStoredValuesFallBack() {
        let store = defaults()
        store.set("Comic Mono", forKey: MobileSettings.terminalFontKey)
        store.set("no-such-scheme", forKey: MobileSettings.terminalSchemeKey)
        store.set("../ghostty/dispatch", forKey: MobileSettings.terminalSchemeKey)
        store.set("blinking", forKey: MobileSettings.cursorKey)
        store.set("sepia", forKey: MobileSettings.themeKey)
        store.set("Papyrus", forKey: MobileSettings.chatFontKey)
        store.set(true, forKey: MobileSettings.boldIsBrightKey)
        let settings = MobileSettings(defaults: store)
        XCTAssertEqual(settings.terminalFont, "JetBrains Mono")
        XCTAssertEqual(settings.terminalScheme, "dispatch-black", "only a bundled scheme's file name, never a path")
        XCTAssertEqual(settings.cursor, .block)
        XCTAssertEqual(settings.theme, .automatic)
        XCTAssertEqual(settings.chatFont, .system)
        XCTAssertTrue(settings.boldIsBright, "the rest stays")
    }

    // MARK: Terminal

    func testTheStyleReachesTheConfiguration() throws {
        let store = defaults()
        let settings = MobileSettings(defaults: store)
        settings.terminalFont = "Fira Code"
        settings.terminalScheme = "Nord"
        settings.improveTextContrast = true
        settings.boldIsBright = true
        settings.cursor = .bar
        settings.cursorBlink = false
        store.set(15.5, forKey: TerminalController.fontSizeKey)
        let configuration = TerminalController.storedConfiguration(store)
        XCTAssertEqual(configuration.fontSize, 15.5)
        XCTAssertEqual(configuration.fontFamily, "Fira Code")
        XCTAssertTrue(configuration.boldIsBright)
        let text = configuration.text
        XCTAssertTrue(text.contains("font-family = Fira Code"))
        XCTAssertTrue(text.contains("cursor-style = bar"))
        XCTAssertTrue(text.contains("cursor-style-blink = false"))
        XCTAssertTrue(text.contains("minimum-contrast = 4.5"))
        XCTAssertTrue(text.contains("/themes/Nord"), "Ghostty's themes folder: \(text)")
        let config = configuration.config()
        XCTAssertEqual(config.fontFamily, ["Fira Code"])
        XCTAssertEqual(config.cursorStyle, .bar)
        XCTAssertEqual(config.cursorBlink, false)
        XCTAssertEqual(config.minimumContrast, 4.5)

        // JetBrains Mono is TermApple's own face: no family, and blinking leaves the program's choice.
        let plain = TerminalStyle().applied(to: TerminalConfiguration()).text
        XCTAssertFalse(plain.contains("font-family"))
        XCTAssertFalse(plain.contains("cursor-style-blink"))
        XCTAssertTrue(plain.contains("ghostty/dispatch-black"))
        XCTAssertNil(TerminalConfiguration().config().cursorBlink)
    }

    /// Settings' change reaches an open terminal at once; its own (pinched) size and pasteboard access stay.
    func testAnOpenTerminalRestylesAndKeepsItsSize() async throws {
        let store = defaults()
        var start = TerminalConfiguration()
        start.fontSize = 17
        let presence = TerminalPresence(feed: ScriptedTerminalFeed(output: Data("$ ".utf8)), configuration: start)
        XCTAssertFalse(presence.session.drawsBoldBright)
        let settings = MobileSettings(defaults: store)
        settings.boldIsBright = true
        settings.cursor = .underline
        settings.terminalFont = "Source Code Pro"
        try await TestSupport.eventually { presence.configuration.fontFamily == "Source Code Pro" }
        XCTAssertEqual(presence.configuration.fontSize, 17, "the terminal's own size")
        XCTAssertTrue(presence.configuration.boldIsBright)
        XCTAssertEqual(presence.configuration.cursor, .underline)
        XCTAssertEqual(presence.configuration.fontFamily, "Source Code Pro")
        XCTAssertEqual(presence.session.config.cursorStyle, .underline)
        XCTAssertEqual(presence.session.config.fontFamily, ["Source Code Pro"])
        XCTAssertTrue(presence.session.drawsBoldBright, "bold draws bright at once")
        XCTAssertFalse(presence.configuration.clipboardWrite, "a helper feed's writes stay denied")
    }

    /// A colour scheme from Settings reaches the open terminal's view: the background around the grid follows at once.
    func testASchemeChangeRepaintsTheViewsBackground() throws {
        let store = defaults()
        let presence = TerminalPresence(feed: ScriptedTerminalFeed(output: Data("$ ".utf8)), configuration: TerminalConfiguration())
        let view = TerminalHostView(presence: presence)
        func rgb(_ color: UIColor?) -> [Int] {
            var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            color?.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b].map { Int(($0 * 255).rounded()) }
        }
        XCTAssertEqual(rgb(view.backgroundColor), [0, 0, 0], "dispatch-black")
        let light = try XCTUnwrap(TerminalSchemes.all().first { !$0.isDark })
        presence.restyle({ var style = TerminalStyle(store); style.scheme = light.file; return style }())
        let bg = presence.session.background
        XCTAssertNotEqual([Int(bg.r), Int(bg.g), Int(bg.b)], [0, 0, 0])
        XCTAssertEqual(rgb(view.backgroundColor), [Int(bg.r), Int(bg.g), Int(bg.b)], "\(light.file)'s background")
    }

    func testTheOfferedFontsAreBundledAndRegistered() {
        MobileFonts.register()
        XCTAssertEqual(TerminalFont.all.first?.name, "JetBrains Mono", "the default first")
        XCTAssertEqual(TerminalFont.all.filter(\.system).map(\.name), ["Menlo"])
        XCTAssertEqual(TerminalFont.all.filter(\.ligatures).map(\.name), ["JetBrains Mono", "Fira Code", "0xProto"])
        for font in TerminalFont.all {
            XCTAssertFalse(UIFont.fontNames(forFamilyName: font.name).isEmpty, "\(font.name) is registered")
        }
        XCTAssertEqual(TerminalFont.named("Comic Mono"), .jetBrainsMono)
    }

    func testSchemesAreDispatchsThenGhosttysWithSwatches() throws {
        let schemes = TerminalSchemes.all()
        XCTAssertEqual(schemes.prefix(2).map(\.title), ["Dispatch Black", "Dispatch"])
        XCTAssertGreaterThan(schemes.count, 100, "Ghostty's bundled themes")
        let nord = try XCTUnwrap(schemes.first { $0.file == "Nord" })
        XCTAssertTrue(nord.isDark)
        XCTAssertEqual(nord.accents.count, 6)
        XCTAssertTrue(schemes.contains { !$0.isDark }, "light schemes too")
        XCTAssertNil(TerminalSchemes.url("../Info.plist"), "file names only")

        let parsed = TerminalSchemes.parse("background = #102030\nforeground=#ffffff\npalette = 1=#ff0000\npalette = 9=#00ff00\n# x = y\n",
                                           file: "Test")
        XCTAssertEqual(parsed.background, .init(16, 32, 48))
        XCTAssertEqual(parsed.accents, [.init(255, 0, 0)], "red to cyan: 1 to 6 only")
        XCTAssertEqual(parsed.title, "Test")
    }

    // MARK: Theme

    /// The themes are the Mac's palettes; each themed token resolves by the trait, Automatic to the catalog's.
    func testThemesColourTheTokensByTrait() {
        func resolved(_ color: UIColor, _ theme: MobileTheme, _ style: UIUserInterfaceStyle = .dark) -> UIColor {
            color.resolvedColor(with: UITraitCollection { $0.userInterfaceStyle = style; $0[MobileThemeTrait.self] = theme })
        }
        let accent = UIColor.themed("AccentColor", \.accent)
        XCTAssertEqual(resolved(accent, .automatic), UIColor.dispatch("AccentColor").resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
        XCTAssertEqual(resolved(accent, .nautical), UIColor(SidebarTheme.nautical.palette.accent))
        XCTAssertEqual(resolved(accent, .lavender), UIColor(SidebarTheme.lavender.palette.accent))
        let canvas = UIColor.themed("Canvas", \.canvas)
        XCTAssertEqual(resolved(canvas, .graphite), UIColor(SidebarTheme.graphite.palette.window))
        XCTAssertEqual(resolved(canvas, .automatic, .light), UIColor.dispatch("Canvas").resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        XCTAssertNil(MobileTheme.automatic.colorScheme, "Automatic follows Appearance")
        XCTAssertEqual(MobileTheme.nautical.colorScheme, .dark)
        XCTAssertEqual(MobileTheme.graphite.colorScheme, .light)
        XCTAssertEqual(MobileTheme.lavender.colorScheme, .light)
        XCTAssertEqual(MobileTheme.allCases.map(\.subtitle), ["Follows Appearance", "Neutral greys", "Purple accent", "Radar green, engine room"])
    }

    /// The root applies the theme live: its scheme on the window and its trait for UIKit and SwiftUI.
    func testTheRootAppliesTheTheme() async throws {
        let store = defaults()
        store.set("system", forKey: MobileAppearance.key)
        let found = await TestSupport.windowScene()
        let window = UIWindow(windowScene: try XCTUnwrap(found))
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.rootViewController = UIHostingController(rootView: Color.canvas.mobileAppearance(defaults: store))
        window.isHidden = false
        defer { window.isHidden = true }
        try await TestSupport.eventually { window.overrideUserInterfaceStyle == .unspecified }
        XCTAssertEqual(window.traitCollection[MobileThemeTrait.self], .automatic)
        store.set("nautical", forKey: MobileSettings.themeKey)
        try await TestSupport.eventually { window.traitCollection[MobileThemeTrait.self] == .nautical }
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark, "Nautical is dark whatever Appearance says")
        XCTAssertEqual(window.tintColor.resolvedColor(with: window.traitCollection), UIColor(SidebarTheme.nautical.palette.accent),
                       "UIKit's tint is the theme's accent")
        store.set("graphite", forKey: MobileSettings.themeKey)
        try await TestSupport.eventually { window.overrideUserInterfaceStyle == .light }
        store.set("automatic", forKey: MobileSettings.themeKey)
        try await TestSupport.eventually { window.overrideUserInterfaceStyle == .unspecified && window.traitCollection[MobileThemeTrait.self] == .automatic }
    }

    // MARK: Chat

    func testChatTypographyFollowsTheSettings() {
        let store = defaults()
        XCTAssertEqual(ChatTypography(store), ChatTypography())
        store.set("Same as code", forKey: MobileSettings.chatFontKey)
        store.set("smaller", forKey: MobileSettings.chatTextSizeKey)
        store.set("Fira Code", forKey: MobileSettings.terminalFontKey)
        let typography = ChatTypography(store)
        XCTAssertEqual(typography.font, .sameAsCode)
        XCTAssertEqual(typography.size, .smaller)
        XCTAssertEqual(typography.family(.sameAsCode), "Fira Code", "the terminal's font")
        XCTAssertNil(typography.family(.system))
        XCTAssertEqual(typography.family(.comicSans), "Chalkboard SE", "iOS's stand-in")
        XCTAssertEqual(ChatTextSize.allCases.map(\.points), [15, 16, 17])
        XCTAssertEqual(MobileChatFont.sameAsCode.sample(terminalFont: "Fira Code", size: 15), "Fira Code 15, as the terminal.")
    }

    /// A bubble draws in the environment's size: Larger is taller than Default, Default than Smaller.
    func testBubblesFollowTheChatTextSize() {
        func height(_ size: ChatTextSize, _ font: MobileChatFont = .system) -> CGFloat {
            let text = "The migration plan is ready: run it on staging first, then production, and watch the logs."
            let bubble = ChatBubble(side: .agent) { Text(text) }
                .environment(\.chatTypography, ChatTypography(font: font, size: size))
                .environment(\.chatColumnWidth, 300)
            return UIHostingController(rootView: bubble).sizeThatFits(in: CGSize(width: 300, height: 2000)).height
        }
        XCTAssertLessThan(height(.smaller), height(.standard))
        XCTAssertLessThan(height(.standard), height(.larger))
        XCTAssertNotEqual(height(.standard, .sameAsCode), height(.standard), "a monospaced font sets the text differently")
    }

    /// Code follows the chat's text size: three points under it in blocks, a little under it inline.
    func testCodeScalesWithTheChatTextSize() {
        let standard = ChatTypography(size: .standard), larger = ChatTypography(size: .larger)
        XCTAssertEqual(standard.code, Font.custom("JetBrains Mono", size: 13, relativeTo: .callout))
        XCTAssertEqual(larger.code, Font.custom("JetBrains Mono", size: 14, relativeTo: .body))
        XCTAssertEqual(standard.inlineCode, Font.custom("JetBrains Mono", size: 15, relativeTo: .callout))
        XCTAssertNotEqual(ChatTypography(size: .smaller).inlineCode, standard.inlineCode)
    }

    /// Inline code (paths, commands) takes the terminal's font; other runs keep the bubble's.
    func testInlineCodeUsesTheTerminalFont() {
        let code = Font.custom("Fira Code", size: 13)
        let text = MobileChatMarkdown.text("Open `src/app.swift` now", code: code)
        let runs = text.runs.map { (String(text[$0.range].characters), $0.font) }
        XCTAssertEqual(runs.first { $0.0 == "src/app.swift" }?.1, code)
        XCTAssertNil(runs.first { $0.0.hasPrefix("Open") }?.1)
    }

    // MARK: Screens

    /// The labels `view` exposes once all of `expected` show (an XCTAssert on the result names a missing one).
    private func labels<V: View>(_ view: V, height: CGFloat = 1400, expected: [String]) async throws -> [String] {
        AccessibilityLabelTests.enableAccessibility()
        let found = await TestSupport.windowScene()
        let window = UIWindow(windowScene: try XCTUnwrap(found))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        defer { window.isHidden = true }
        var labels: [String] = []
        try await TestSupport.eventually(diagnostic: "Elements: \(labels)") {
            labels = AccessibilityLabelTests.elements(in: window).compactMap { $0.accessibilityLabel }
            return Set(expected).isSubset(of: labels)
        }
        return labels
    }

    /// G1: the rows the mockup draws, with the values they show.
    func testSettingsShowsTheNewRows() async throws {
        let composition = ResilienceFixture.composition(ResilienceFixture.sessions([ResilienceFixture.host("studio")]))
        composition.settings.terminalFont = "Fira Code"
        composition.settings.chatFont = .comicSans
        let expected = ["Theme, Automatic", "Font, Fira Code", "Color scheme, Dispatch Black", "Improve text contrast",
                        "Font, Comic Sans", "Dictation, Apple", "Notifications, Sound, text", "Background refresh", "studio, Chat on",
                        "Remove all data"]
        _ = try await labels(SettingsView(composition: composition).environment(composition.hosts), height: 2400, expected: expected)
    }

    /// G2: every font by name, the selected one marked; a tap chooses.
    func testTerminalFontScreen() async throws {
        let settings = MobileSettings(defaults: defaults())
        _ = try await labels(NavigationStack { TerminalFontSettingsView(settings: settings) },
                             expected: TerminalFont.all.map(\.name) + ["Bold text as bright colors", "Cursor, Block", "Blinking cursor"])
    }

    /// G3 and G4: the three fonts and the four themes by name.
    func testChatFontAndThemeScreens() async throws {
        let settings = MobileSettings(defaults: defaults())
        _ = try await labels(NavigationStack { ChatFontSettingsView(settings: settings) },
                             expected: MobileChatFont.allCases.map(\.rawValue) + ["Larger"])
        _ = try await labels(NavigationStack { ThemeSettingsView(settings: settings) }, expected: MobileTheme.allCases.map(\.title))
    }

    /// G5: the three events, the sound, the text and the badge.
    func testNotificationsScreen() async throws {
        let composition = ResilienceFixture.composition(ResilienceFixture.sessions([]))
        _ = try await labels(NavigationStack { NotificationSettingsView(composition: composition) },
                             expected: ["Needs you", "Finished", "Failed or disconnected", "Sound, Default", "Show message text", "Badge app icon"])
    }
}
