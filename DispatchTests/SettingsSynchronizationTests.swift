import AppKit
import SwiftUI
import Vision
import XCTest
@testable import DispatchApp

@MainActor
final class SettingsSynchronizationTests: XCTestCase {
    func testHostColorChoicesPersistApplyAndDropUnknownColors() throws {
        let tint = HostTint(hostID: "host-color-fixture:501")
        XCTAssertEqual(tint.machine, HostTint(hostID: "host-color-fixture:0").machine, "Every login on a machine shares its color")
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(#"{"fontSize":14,"hostColors":{"a":"blue","b":"chartreuse"}}"#.utf8))
        XCTAssertEqual(decoded.hostColors, ["a": .blue], "An unknown color drops only that choice")
        XCTAssertEqual(decoded.fontSize, 14)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file), colors = HostColorStore.shared, themes = SidebarThemeStore.shared
        let previous = (colors.choices, colors.persist, themes.current)
        defer { colors.choices = previous.0; colors.persist = previous.1; themes.current = previous.2 }
        colors.choices = [:]
        colors.persist = { choices in
            var values = store.values; values.hostColors = choices; try? store.save(values)
        }
        themes.current = .dark
        let automatic = NSColor(tint.color).usingColorSpace(.sRGB)
        colors.choose(.blue, for: tint.machine)
        XCTAssertEqual(SettingsStore(file: file).values.hostColors, [tint.machine: .blue])
        let tone = HostTint.Tone.darkColor
        XCTAssertEqual(NSColor(tint.color).usingColorSpace(.sRGB),
                       NSColor(HostTint.oklch(tone.lightness, tone.chroma, HostColor.blue.hue)).usingColorSpace(.sRGB))
        colors.choose(nil, for: tint.machine)
        XCTAssertEqual(SettingsStore(file: file).values.hostColors, [:])
        XCTAssertEqual(NSColor(tint.color).usingColorSpace(.sRGB), automatic)
    }

    /// Settings › Hosts › Host colors: on by default; off keeps remote chrome but draws it without hue.
    func testHostColorsSettingDefaultsOnAndDrawsNeutralWhenOff() throws {
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).showHostColors)
        var preferences = Preferences(); preferences.showHostColors = false
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertFalse(decoded.showHostColors)
        let colors = HostColorStore.shared, themes = SidebarThemeStore.shared
        let previous = (colors.enabled, themes.current)
        defer { colors.enabled = previous.0; themes.current = previous.1 }
        themes.current = .dark
        let tint = HostTint(hostID: "host-colors-off-fixture").showing(.red)
        colors.enabled = true
        let tone = HostTint.Tone.darkColor
        XCTAssertEqual(NSColor(tint.color).usingColorSpace(.sRGB),
                       NSColor(HostTint.oklch(tone.lightness, tone.chroma, HostColor.red.hue)).usingColorSpace(.sRGB))
        colors.enabled = false
        let neutral = try XCTUnwrap(NSColor(tint.color).usingColorSpace(.sRGB))
        XCTAssertEqual(neutral.redComponent, neutral.greenComponent, accuracy: 0.002)
        XCTAssertEqual(neutral.greenComponent, neutral.blueComponent, accuracy: 0.002)
        XCTAssertEqual(NSColor(tint.showing(.blue).color).usingColorSpace(.sRGB), neutral, "Every host draws the same gray")
    }

    /// Settings › Keys saves modifier names; a file whose groups clash keeps the defaults, not the other settings.
    func testKeyGroupsDefaultsPersistenceAndValidation() throws {
        let defaults = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).keyGroups
        XCTAssertEqual([defaults.spaces, defaults.tabs, defaults.splits], [[.shift, .command], .command, .control])
        // [ and ] step through spaces and tabs with their digits' modifiers, always with ⌘ so they never type into a
        // shell, and never on a chord another step already holds.
        XCTAssertEqual(defaults.steps.spaces, [.shift, .command]); XCTAssertEqual(defaults.steps.tabs, .command)
        var stepping = KeyGroups(); stepping.tabs = .control
        XCTAssertEqual(stepping.steps.tabs, [.control, .command], "⌃[ is Escape")
        stepping.spaces = [.option, .command]
        XCTAssertNil(stepping.steps.spaces, "⌥⌘[ / ⌥⌘] stays with panes")
        let clashing = try JSONDecoder().decode(Preferences.self, from: Data(#"{"fontSize":14,"keyGroups":{"spaces":["command"],"tabs":["command"]}}"#.utf8))
        XCTAssertEqual(clashing.keyGroups, KeyGroups())
        XCTAssertEqual(clashing.fontSize, 14)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        var preferences = Preferences()
        preferences.keyGroups.spaces = [.option, .command]
        preferences.keyGroups.tabs = [.control, .shift]
        try store.save(preferences)
        XCTAssertEqual(SettingsStore(file: file).values, preferences)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(saved?["keyGroups"] as? [String: [String]],
                       ["spaces": ["option", "command"], "tabs": ["control", "shift"], "splits": ["control"]])
        for invalid: NSEvent.ModifierFlags in [.shift, .control] {
            var rejected = preferences
            rejected.keyGroups.spaces = invalid
            XCTAssertThrowsError(try store.save(rejected), "\(invalid)")
        }
        XCTAssertEqual(SettingsStore(file: file).values, preferences)
        // No modifiers unbinds a group, even two at once: it keeps no shortcut, so its digits stay typing.
        var unbound = preferences
        unbound.keyGroups.spaces = []; unbound.keyGroups.tabs = []
        try store.save(unbound)
        XCTAssertEqual(SettingsStore(file: file).values.keyGroups, unbound.keyGroups)
        XCTAssertFalse(ApplicationMenu.claimsShortcut(keyCode: 18, modifiers: [], groups: unbound.keyGroups), "A plain 1 is typing")
        XCTAssertTrue(ApplicationMenu.claimsShortcut(keyCode: 18, modifiers: .control, groups: unbound.keyGroups))
        XCTAssertNil(unbound.keyGroups.steps.spaces); XCTAssertNil(unbound.keyGroups.steps.tabs)
        XCTAssertNil(unbound.keyGroups.shortcut(\.spaces, "1…9"))
    }

    func testHostHighlightModesDrawBorderOrTintNotBoth() async throws {
        try DesktopTestSupport.requireUnlocked()
        let window = NSWindow(contentRect: NSRect(x: 600, y: 0, width: 240, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tint = HostTint(hostID: "remote-highlight-fixture")
        let preview = NSHostingView(rootView: RemoteTabHighlightPreview(highlight: .fade, tint: tint))
        window.contentView = preview; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func pixel(_ bitmap: NSBitmapImageRep, y: CGFloat) throws -> NSColor {
            try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(y * CGFloat(bitmap.pixelsHigh) / 160))?.usingColorSpace(.sRGB))
        }
        func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
        }
        // Liquid Glass's fade and flat chrome's border-only (RemoteTabHighlight.current).
        for style: RemoteTabHighlight in [.fade, .border, .fade] {
            preview.rootView = RemoteTabHighlightPreview(highlight: style, tint: tint)
            try await Task.sleep(for: .milliseconds(150))
            let snapshot = try await PresentationTestSupport.capture(window, named: "remote-tab-highlight-\(style)", in: "remote-highlight-validation")
            let background = try pixel(snapshot.bitmap, y: 140)
            if style == .border { XCTAssertGreaterThan(difference(try pixel(snapshot.bitmap, y: 1), background), 0.05, "Border-only draws the top border") }
            else { XCTAssertLessThan(difference(try pixel(snapshot.bitmap, y: 1), try pixel(snapshot.bitmap, y: 15)), 0.005, "Fade tints without a top border") }
            // On dark palettes the plain strip keeps a neutral hairline at its foot (y = 29.5).
            for y: CGFloat in style == .border && Chrome.palette.isDark ? [15, 40, 70] : [15, 29.5, 40, 70] {
                let delta = difference(try pixel(snapshot.bitmap, y: y), background)
                if style == .border { XCTAssertLessThan(delta, 0.005, "Border-only removes the strip tint, bottom rule and fade at y=\(y)") }
                else { XCTAssertGreaterThan(delta, 0.005, "Fade tints the strip and washes below it at y=\(y)") }
            }
        }
        // With no strip to tint, Liquid Glass falls back to the border alone.
        preview.rootView = RemoteTabHighlightPreview(highlight: .fade, tint: tint, strip: false)
        try await Task.sleep(for: .milliseconds(150))
        let stripless = try await PresentationTestSupport.capture(window, named: "remote-tab-highlight-stripless", in: "remote-highlight-validation")
        let ground = try pixel(stripless.bitmap, y: 140)
        XCTAssertGreaterThan(difference(try pixel(stripless.bitmap, y: 1), ground), 0.05, "A stripless pane keeps the border")
        for y: CGFloat in [15, 40, 70] {
            XCTAssertLessThan(difference(try pixel(stripless.bitmap, y: y), ground), 0.005, "The border replaces the wash at y=\(y)")
        }
        // Border-only: an offline host keeps its border without fill; a local tab draws nothing.
        var offline = tint; offline.offline = true
        for tint in [offline, nil] {
            preview.rootView = RemoteTabHighlightPreview(highlight: .border, tint: tint)
            try await Task.sleep(for: .milliseconds(150))
            let snapshot = try await PresentationTestSupport.capture(window)
            let background = try pixel(snapshot.bitmap, y: 140)
            XCTAssertLessThan(difference(try pixel(snapshot.bitmap, y: 40), background), 0.005)
            if tint == nil { XCTAssertLessThan(difference(try pixel(snapshot.bitmap, y: 1), background), 0.005) }
            else { XCTAssertGreaterThan(difference(try pixel(snapshot.bitmap, y: 1), background), 0.05) }
        }
    }

    /// Every theme draws each role at one lightness and chroma for every host, so hosts differ only in hue: labels
    /// stay readable on the sidebar, the edge visible on the window, and a host keeps its hue across themes. The
    /// listed hues stay far enough apart to tell apart, and automatic hosts get the listed swatches.
    func testHostColorsAreEvenAndReadableInEveryTheme() {
        let store = SidebarThemeStore.shared, original = store.current
        defer { store.current = original }
        func rgb(_ color: Color, over ground: Color) -> [Double] {
            let fill = NSColor(color).usingColorSpace(.sRGB)!, base = NSColor(ground).usingColorSpace(.sRGB)!
            let a = fill.alphaComponent
            return [fill.redComponent * a + base.redComponent * (1 - a), fill.greenComponent * a + base.greenComponent * (1 - a),
                    fill.blueComponent * a + base.blueComponent * (1 - a)]
        }
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        func contrast(_ color: Color, on ground: Color) -> Double {
            let pair = [luminance(rgb(color, over: ground)), luminance(rgb(ground, over: ground))].sorted()
            return (pair[1] + 0.05) / (pair[0] + 0.05)
        }
        // OKLCH lightness, chroma and hue in degrees, measured on the drawn color without its opacity.
        func oklch(_ color: Color) -> (lightness: Double, chroma: Double, hue: Double) {
            let linear = rgb(color, over: color).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            let lms = [0.4122214708 * linear[0] + 0.5363325363 * linear[1] + 0.0514459929 * linear[2],
                       0.2119034982 * linear[0] + 0.6806995451 * linear[1] + 0.1073969566 * linear[2],
                       0.0883024619 * linear[0] + 0.2817188376 * linear[1] + 0.6299787005 * linear[2]].map(cbrt)
            let lightness = 0.2104542553 * lms[0] + 0.7936177850 * lms[1] - 0.0040720468 * lms[2]
            let a = 1.9779984951 * lms[0] - 2.4285922050 * lms[1] + 0.4505937099 * lms[2]
            let b = 0.0259040371 * lms[0] + 0.7827717662 * lms[1] - 0.8086757660 * lms[2]
            return (lightness, hypot(a, b), (atan2(b, a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
        }
        let hues = HostColor.allCases.map { $0.hue * 360 }.sorted()
        let gaps = zip(hues, hues.dropFirst() + [hues[0] + 360]).map { $1 - $0 }
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, 35, "Neighbouring host colors stay far enough apart to tell apart")
        let tints = (0..<72).map { HostTint(hostID: "light-palette-\($0)") }
            + HostColor.allCases.map { HostTint(hostID: "light-palette-0").showing($0) }
        let roles: [(String, (HostTint) -> Color)] = [("color", { $0.color }), ("edge", { $0.edge }), ("border", { $0.border }),
                                                      ("foreground", { $0.foreground }), ("tabForeground", { $0.tabForeground }),
                                                      ("tabControl", { $0.tabControl })]
        store.current = .dark
        let darkHues = tints.map { oklch($0.color).hue }
        for theme in SidebarTheme.allCases {
            store.current = theme
            // No hue is drawn lighter, darker or (clipped to sRGB) duller than the rest.
            for (role, draw) in roles {
                let drawn = tints.map { oklch(draw($0)) }
                for (part, values) in [("lightness", drawn.map(\.lightness)), ("chroma", drawn.map(\.chroma))] {
                    XCTAssertLessThan((values.max() ?? 0) - (values.min() ?? 0), 0.002, "\(theme) \(role) \(part) differs between hosts")
                }
            }
            for (tint, darkHue) in zip(tints, darkHues) {
                let name = (tint.choice ?? tint.automatic).rawValue
                let difference = abs(oklch(tint.color).hue - darkHue)
                XCTAssertLessThan(min(difference, 360 - difference), 3, "\(theme) \(name) changes color family between themes")
                XCTAssertGreaterThanOrEqual(contrast(tint.foreground, on: Chrome.sidebar), 4.5, "\(theme) \(name)")
                XCTAssertGreaterThanOrEqual(contrast(tint.tabForeground, on: Chrome.window), 4.5, "\(theme) \(name)")
                XCTAssertGreaterThanOrEqual(contrast(tint.edge, on: Chrome.window), 3, "\(theme) \(name)")
                // A pastel wash, never a gray band: the strip keeps a light window light.
                if theme != .dark {
                    XCTAssertGreaterThan(luminance(rgb(tint.stripWash, over: Chrome.window)), 0.75, "\(theme) \(name)")
                }
            }
        }
        // Automatic colors are the listed swatches, spread across the list.
        for theme in [SidebarTheme.dark, .light] {
            store.current = theme
            for tint in tints.prefix(72) {
                XCTAssertEqual(NSColor(tint.color).usingColorSpace(.sRGB), NSColor(tint.showing(tint.automatic).color).usingColorSpace(.sRGB))
            }
        }
        XCTAssertGreaterThanOrEqual(Set(tints.prefix(72).map(\.automatic)).count, HostColor.allCases.count * 3 / 4)
    }

    func testLargeSidebarItemsPersistWithoutChangingContentFont() throws {
        let legacy = try JSONDecoder().decode(Preferences.self, from: Data("{\"fontSize\":16}".utf8))
        XCTAssertEqual(legacy.sidebarStyle, .icons, "The host picker's rows are the default")
        XCTAssertEqual(legacy.sidebarFontSize, 15.5, "Icons names follow the content font, half a point smaller")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        var preferences = legacy
        preferences.largeSidebarItems = false
        try store.save(preferences)
        let restored = SettingsStore(file: file).values
        XCTAssertEqual(restored, preferences)
        XCTAssertEqual(restored.sidebarFontSize, 15, "Compact text follows the content font a point smaller")
        XCTAssertEqual(restored.fontSize, 16)
        preferences.largeSidebarItems = true
        try store.save(preferences)
        XCTAssertEqual(SettingsStore(file: file).values.sidebarFontSize, 17.5)
    }

    /// The sidebar style setting replaces the large-items switch: off stays compact, while on, which every save wrote,
    /// takes the new default (icons); a chosen style round-trips, and an unknown one keeps the default.
    func testSidebarStyleMigratesFromLargeItemsAndRoundTrips() throws {
        func decode(_ json: String) throws -> Preferences { try JSONDecoder().decode(Preferences.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode("{}").sidebarStyle, .icons, "The host picker's rows are the default")
        XCTAssertEqual(try decode(#"{"largeSidebarItems":false}"#).sidebarStyle, .compact, "Compact was a choice")
        XCTAssertEqual(try decode(#"{"largeSidebarItems":true}"#).sidebarStyle, .icons, "Large was the old default every save wrote")
        XCTAssertEqual(try decode(#"{"sidebarStyle":"large"}"#).sidebarStyle, .large)
        XCTAssertTrue(try decode(#"{"largeSidebarItems":true}"#).showGitBranches, "Explicit large items kept their branches")
        XCTAssertEqual(try decode(#"{"sidebarStyle":"icons","largeSidebarItems":false}"#).sidebarStyle, .icons)
        XCTAssertEqual(try decode(#"{"sidebarStyle":"unknown"}"#).sidebarStyle, .icons)
        var preferences = try decode("{}")
        preferences.sidebarStyle = .icons
        let json = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        XCTAssertTrue(json.contains(#""sidebarStyle":"icons""#))
        XCTAssertFalse(json.contains("largeSidebarItems"), "One stored choice, not two")
        XCTAssertEqual(try decode(json), preferences)
        // The host picker's rows: the sidebar font, a 22-point icon disc in a 30-point row, rows 2 points apart.
        let metrics = preferences.sidebarMetrics
        XCTAssertTrue(metrics.icons)
        XCTAssertEqual(metrics.nameSize, 12)
        XCTAssertEqual(metrics.discSize, 22)
        XCTAssertEqual(metrics.rowHeight, 30)
        XCTAssertEqual(metrics.rowSpacing, 2)
        preferences.fontSize = 20
        XCTAssertEqual(preferences.sidebarMetrics.discSize, 35, "The disc grows with the font like the large tiles")
        preferences.largeSidebarItems = false
        XCTAssertEqual(preferences.sidebarStyle, .compact)
    }

    /// With Liquid Glass the sidebar is one panel from top to bottom: halfway down, well below the spaces and above
    /// the footer, the panel still covers the column, while the window shows in the inset beside it.
    func testGlassSidebarIsOnePanelFromTopToBottom() async throws {
        let (panel, inset) = try await glassSidebarBrightness(liquidSidebar: true, named: "glass-sidebar")
        XCTAssertGreaterThan(abs(panel - inset), 0.02, "The panel covers the column halfway down (\(panel) vs the inset's \(inset))")
    }

    /// With the Liquid sidebar off, the sidebar is AppKit's own sidebar glass, as in Finder and Mail, in a column flush
    /// with the window's edge: no inset beside it. The Liquid sidebar stays on unless turned off.
    func testLiquidSidebarOffIsFlushWithTheWindowEdge() async throws {
        let defaults = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(defaults.liquidSidebar, "The floating panel stays the default")
        var chosen = defaults
        chosen.liquidSidebar = false
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(chosen)), chosen)
        let migrated = try JSONDecoder().decode(Preferences.self, from: Data(#"{"systemSidebar": true}"#.utf8))
        XCTAssertFalse(migrated.liquidSidebar, "A chosen system sidebar keeps its column")
        let (panel, inset) = try await glassSidebarBrightness(liquidSidebar: false, named: "system-sidebar") { root in
            guard #available(macOS 26, *) else { return }
            XCTAssertFalse(PresentationTestSupport.views(of: NSGlassEffectView.self, in: root, includingNestedMatches: true).isEmpty,
                           "The column draws AppKit's sidebar glass")
        }
        // Tahoe's own sidebar (macOS 26) is itself a floating inset panel; it is flush from macOS 27.
        guard #available(macOS 27, *) else { return }
        XCTAssertEqual(panel, inset, accuracy: 0.02, "The glass reaches the window's edge (\(panel) vs \(inset) at the edge)")
    }

    /// A two-space glass sidebar's brightness halfway down: mid-column, and halfway into the floating panel's inset.
    private func glassSidebarBrightness(liquidSidebar: Bool, named name: String,
                                        inspect: (NSView) throws -> Void = { _ in }) async throws -> (panel: CGFloat, inset: CGFloat) {
        try XCTSkipUnless(LiquidGlassStore.supported, "Liquid Glass needs macOS 26")
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppDelegate(settings: SettingsStore(file: directory.appendingPathComponent("settings.json")))
        let workspace = controller.workspace
        workspace.newLocalSpace()
        workspace.newLocalSpace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let originalGlass = LiquidGlassStore.shared.enabled, originalLiquid = LiquidGlassStore.shared.liquidSidebar
        defer { LiquidGlassStore.shared.enabled = originalGlass; LiquidGlassStore.shared.liquidSidebar = originalLiquid }
        LiquidGlassStore.shared.enabled = true
        LiquidGlassStore.shared.liquidSidebar = liquidSidebar
        let root = NSHostingView(rootView: SpaceSidebar(workspace: workspace, settings: controller.settings, controller: controller))
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        controller.settings.values.spaceOrder = .flat
        try await TestSupport.eventually {
            root.layoutSubtreeIfNeeded()
            return PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
                .filter { if case .space = $0.configuration.item { return true }; return false }.count == 2
        }
        try await Task.sleep(for: .milliseconds(InterfaceMotion.viewDuration * 1000 + 100))
        try inspect(root)
        let bitmap = try await PresentationTestSupport.capture(window, named: name, in: "sidebar-validation").bitmap
        func brightness(x: Int) throws -> CGFloat {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        let scale = CGFloat(bitmap.pixelsWide) / root.bounds.width
        return (try brightness(x: bitmap.pixelsWide / 2), try brightness(x: Int(SpaceSidebar.glassInset / 2 * scale)))
    }

    /// The icons style draws spaces as the host picker does, in both orders, flat and glass alike: 30-point rows 2 points
    /// apart, each led by its host's icon, and tree groups without the indent and rule of the other styles.
    func testIconsSidebarMatchesHostPickerRows() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppDelegate(settings: SettingsStore(file: directory.appendingPathComponent("settings.json")))
        let workspace = controller.workspace
        workspace.newLocalSpace()
        workspace.renameSpace(try XCTUnwrap(workspace.selectedSpace), to: "local")
        workspace.newLocalSpace()
        workspace.renameSpace(try XCTUnwrap(workspace.selectedSpace), to: "notes")
        var remote = Space(name: "remote", directory: "/tmp")
        let shell = SSHShell(destination: "admin@fixture")
        remote.panes[0].tabs[0].machine = .ssh(shell)
        let terminal = remote.tabs[0].id, generation = UUID()
        workspace.hosts.begin(terminal, generation: generation, destination: shell.destination)
        let greeting = SSHGreeting(version: 1, host: "fixture", boot: "test", uid: 501, home: "/tmp", capabilities: [])
        workspace.hosts.update(terminal, generation: generation, destination: shell.destination, greeting: greeting, state: .connected)
        remote.hostID = .authenticated("fixture")
        workspace.spaces.append(remote)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSHostingView(rootView: SpaceSidebar(workspace: workspace, settings: controller.settings, controller: controller))
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let originalGlass = LiquidGlassStore.shared.enabled
        defer { LiquidGlassStore.shared.enabled = originalGlass }
        func rows() -> [CGRect] {
            PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
                .filter { if case .space = $0.configuration.item { return true }; return false }
                .map { $0.convert($0.bounds, to: root) }.sorted { $0.minY < $1.minY }
        }
        for glass in [false] + (LiquidGlassStore.supported ? [true] : []) {
            LiquidGlassStore.shared.enabled = glass
            var flatStart: CGFloat?
            for order: SpaceOrder in [.flat, .tree] {
                controller.settings.values.spaceOrder = order
                controller.settings.values.sidebarStyle = .icons
                var diagnostic = ""
                try await TestSupport.eventually(diagnostic: diagnostic) {
                    root.layoutSubtreeIfNeeded()
                    let frames = rows()
                    diagnostic = "glass=\(glass), order=\(order), rows=\(frames)"
                    return frames.count == 3 && frames.allSatisfy { abs($0.height - 30) < 1 }
                }
                let frames = rows()
                // The two local spaces are neighbours in either order: one row apart, 2 points between them.
                let local = frames.filter { frame in frames.contains { $0 != frame && abs($0.minX - frame.minX) < 1 } }
                XCTAssertTrue(zip(local, local.dropFirst()).contains { abs($1.minY - $0.maxY - 2) < 1 },
                              "Rows 2 points apart: \(diagnostic)")
                if order == .flat { flatStart = frames.first?.minX }
                else if let flatStart {
                    for frame in frames {
                        XCTAssertEqual(frame.minX, flatStart, accuracy: 0.5, "Tree rows keep the flat inset, without a rule: \(diagnostic)")
                    }
                }
                _ = try await PresentationTestSupport.capture(window, named: "icons-sidebar-\(glass ? "glass" : "flat")-\(order.rawValue)",
                                                              in: "sidebar-validation")
            }
        }
        // Host icons grow with the font in every style: captured at a large size for review.
        controller.settings.values.fontSize = 20
        defer { controller.settings.values.fontSize = 12.5 }
        for style in SidebarStyle.allCases {
            controller.settings.values.sidebarStyle = style
            for order: SpaceOrder in [.flat, .tree] {
                controller.settings.values.spaceOrder = order
                let rowHeight = controller.settings.values.sidebarMetrics.rowHeight
                try await TestSupport.eventually {
                    root.layoutSubtreeIfNeeded()
                    let frames = rows()
                    return frames.count == 3 && frames.allSatisfy { $0.height >= rowHeight - 1 }
                }
                _ = try await PresentationTestSupport.capture(window, named: "host-icons-20-\(style.rawValue)-\(order.rawValue)",
                                                              in: "sidebar-validation")
            }
        }
    }

    func testLargeSidebarRowsResizeLiveInBothLayouts() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppDelegate(settings: SettingsStore(file: directory.appendingPathComponent("settings.json")))
        let workspace = controller.workspace
        workspace.newLocalSpace()
        workspace.renameSpace(try XCTUnwrap(workspace.selectedSpace), to: "local")
        var remote = Space(name: "remote", directory: "/tmp")
        let shell = SSHShell(destination: "admin@fixture")
        remote.panes[0].tabs[0].machine = .ssh(shell)
        let terminal = remote.tabs[0].id, generation = UUID()
        workspace.hosts.begin(terminal, generation: generation, destination: shell.destination)
        let greeting = SSHGreeting(version: 1, host: "fixture", boot: "test", uid: 501, home: "/tmp", capabilities: [])
        workspace.hosts.update(terminal, generation: generation, destination: shell.destination, greeting: greeting, state: .connected)
        remote.hostID = .authenticated("fixture")
        workspace.spaces.append(remote)
        let pending = TerminalRuntime.shared.chat.session(for: terminal)
        pending.approvals = [PendingApproval(key: "sidebar-size", operation: "Run tests?") { _ in }]
        defer { TerminalRuntime.shared.chat.close(terminal) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 740),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSHostingView(rootView: SpaceSidebar(workspace: workspace, settings: controller.settings, controller: controller))
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let originalGlass = LiquidGlassStore.shared.enabled
        defer { LiquidGlassStore.shared.enabled = originalGlass }
        for glass in [false] + (LiquidGlassStore.supported ? [true] : []) {
            LiquidGlassStore.shared.enabled = glass
            for order: SpaceOrder in [.flat, .tree] {
                controller.settings.values.spaceOrder = order
                for large in [false, true, false] {
                    controller.settings.values.largeSidebarItems = large
                    // Large's cards are one height in either order: the host sits in their details line.
                    let heights: [CGFloat] = !large ? [21, 21] : [58, 58]
                    var layoutDiagnostic = ""
                    try await TestSupport.eventually(diagnostic: layoutDiagnostic) {
                        let rows = PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
                            .filter { if case .space = $0.configuration.item { return true }; return false }
                        layoutDiagnostic = "glass=\(glass), order=\(order), large=\(large), rows=\(rows.map { $0.bounds.height })"
                            + ", buttons=\(PresentationTestSupport.views(of: NewSpaceNativeButton.self, in: root).map { $0.bounds.height })"
                        guard rows.count == 2 && zip(rows.map { $0.bounds.height }.sorted(), heights).allSatisfy({ abs($0 - $1) < 1 }) else { return false }
                        if large {
                            let buttons = PresentationTestSupport.views(of: NewSpaceNativeButton.self, in: root)
                                .filter { !$0.isHiddenOrHasHiddenAncestor }
                            // Tree: the plus at the end of each 26-point host chip. Flat: "+ local" and "+ space" as tall
                            // as the glass track.
                            let buttonHeight: CGFloat = order == .tree ? 20 : 28
                            guard buttons.count == 2 && buttons.allSatisfy({ abs($0.bounds.height - buttonHeight) < 1 }) else { return false }
                            if order == .tree {
                                let hosts = PresentationTestSupport.views(of: HostSecondaryClickView.self, in: root)
                                    .filter { !$0.isHiddenOrHasHiddenAncestor && abs($0.bounds.height - 26) < 1 }
                                guard hosts.count == 2 else { return false }
                                let headers = hosts.map { $0.convert($0.bounds, to: root) }
                                guard buttons.allSatisfy({ button in
                                    let frame = button.convert(button.bounds, to: root)
                                    return headers.contains { abs($0.midY - frame.midY) < 1 && $0.maxX <= frame.minX }
                                }) else { return false }
                            }
                        }
                        return true
                    }
                    if large {
                        let localTerminal = try XCTUnwrap(workspace.spaces.first?.tabs.first?.surfaceIDs.first)
                        for connecting in [true, false] {
                            if connecting { workspace.hostMoveMotion.connecting.insert(localTerminal) }
                            else { workspace.hostMoveMotion.connecting.remove(localTerminal) }
                            // Let the spinner mount/unmount before checking its layout.
                            try await Task.sleep(for: .milliseconds(100))
                            let rows = PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
                                .filter { if case .space = $0.configuration.item { return true }; return false }
                            XCTAssertEqual(rows.count, 2)
                            XCTAssertTrue(zip(rows.map { $0.bounds.height }.sorted(), heights).allSatisfy { abs($0 - $1) < 1 },
                                          "Loading must use the same status slot without resizing \(order) tiles")
                            if connecting {
                                _ = try await PresentationTestSupport.capture(window, named: "large-sidebar-loading-" + order.rawValue, in: "sidebar-validation")
                            }
                        }
                        let snapshot = try await PresentationTestSupport.capture(window, named: "large-sidebar-\(glass ? "glass" : "flat")-" + order.rawValue, in: "sidebar-validation")
                        if order == .tree { XCTAssertTrue(try snapshot.text().contains("Local"), "The local host's chip") }
                        if order == .flat {
                            XCTAssertTrue(try snapshot.text().lowercased().contains("fixture"), "The remote card names its host")
                            for width: CGFloat in [264, 220, 200] {
                                window.setContentSize(NSSize(width: width, height: 740))
                                var frames: [NSRect] = []
                                try await TestSupport.eventually(diagnostic: "New-space buttons at \(width): \(frames)") {
                                    root.layoutSubtreeIfNeeded()
                                    let buttons = PresentationTestSupport.views(of: NewSpaceNativeButton.self, in: root)
                                        .filter { !$0.isHiddenOrHasHiddenAncestor }
                                    frames = buttons.map { $0.convert($0.bounds, to: root) }.sorted { $0.minX < $1.minX }
                                    let cards = PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
                                        .filter { if case .space = $0.configuration.item { return true }; return false }
                                        .map { $0.convert($0.bounds, to: root) }
                                    guard buttons.count == 2, let card = cards.first else { return false }
                                    // "+ local" and "+ space" on one row, splitting the cards' width between them.
                                    return frames.allSatisfy { abs($0.height - 28) < 1 } && abs(frames[0].midY - frames[1].midY) < 1
                                        && abs(frames[0].width - frames[1].width) < 1
                                        && abs(frames[0].minX - card.minX) < 1 && abs(frames[1].maxX - card.maxX) < 1
                                }
                                _ = try await PresentationTestSupport.capture(window, named: "large-sidebar-flat-\(Int(width))", in: "sidebar-validation")
                            }
                            window.setContentSize(NSSize(width: 300, height: 740))
                        } else {
                            workspace.selectSpace(remote.id)
                            try await Task.sleep(for: .milliseconds(300))
                            _ = try await PresentationTestSupport.capture(window, named: "large-sidebar-\(glass ? "glass" : "flat")-tree-remote-selected", in: "sidebar-validation")
                        }
                    } else {
                        _ = try await PresentationTestSupport.capture(window, named: "small-sidebar-" + order.rawValue, in: "sidebar-validation")
                    }
                }
            }
        }
    }

    func testDiagnosticsDefaultOffAndPersistExplicitChoice() throws {
        XCTAssertFalse(Preferences().enableDiagnostics)
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).enableDiagnostics)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json"), store = SettingsStore(file: root.appendingPathComponent("settings.json"))
        var preferences = Preferences()
        preferences.enableDiagnostics = true
        try store.save(preferences)
        XCTAssertTrue(SettingsStore(file: file).values.enableDiagnostics)
        try store.save(Preferences())
        XCTAssertFalse(SettingsStore(file: file).values.enableDiagnostics)
    }

    func testFullscreenSidebarButtonRefreshesWithoutRecreation() async throws {
        // The flat button's theme fills; on Liquid Glass the button is a glass circle instead.
        let app = try TmuxWalkthrough(liquidGlass: false); defer { app.close() }
        let originalTheme = SidebarThemeStore.shared.current
        defer { SidebarThemeStore.shared.current = originalTheme }
        app.controller.windowState.isFullScreen = true
        let root = try XCTUnwrap(app.window.contentView)
        try await TestSupport.eventually {
            !PresentationTestSupport.views(of: FullScreenSidebarRevealView.self, in: root).isEmpty
        }
        let reveal = try XCTUnwrap(PresentationTestSupport.views(of: FullScreenSidebarRevealView.self, in: root).first)
        let originalGlass = LiquidGlassStore.shared.enabled
        defer { LiquidGlassStore.shared.enabled = originalGlass }
        for glass in [false] + (LiquidGlassStore.supported ? [true] : []) {
            LiquidGlassStore.shared.enabled = glass
            for theme: SidebarTheme in [.dark, .lavender, .light, .graphite, .dark, .lavender] {
                app.controller.settings.values.appTheme = AppTheme(rawValue: theme.rawValue)!
                let palette = SidebarPalette(theme: theme)
                try await TestSupport.eventually {
                    reveal.button.contentTintColor == NSColor(palette.ink) &&
                    reveal.button.layer?.backgroundColor == (reveal.pinned || reveal.glass ? NSColor.clear : NSColor(palette.window).withAlphaComponent(0.95)).cgColor &&
                    reveal.button.layer?.borderColor == (glass ? NSColor.clear : NSColor(palette.border)).cgColor &&
                    reveal.button.appearance?.name == (palette.isDark ? .darkAqua : .aqua)
                }
                XCTAssertTrue(PresentationTestSupport.views(of: FullScreenSidebarRevealView.self, in: root).first === reveal)
            }
        }
    }

    func testSidebarHeaderAlignsWithTabsAndFullscreenToggle() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        app.controller.settings.values = Preferences()
        app.controller.settings.values.hideSingleSpace = false
        let root = try XCTUnwrap(app.window.contentView)
        app.window.delegate = app.controller
        func setFullScreen(_ enabled: Bool) async throws {
            guard app.window.styleMask.contains(.fullScreen) != enabled else { return }
            let finished = expectation(description: enabled ? "Enter full screen" : "Exit full screen")
            let name = enabled ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
            let observer = NotificationCenter.default.addObserver(forName: name, object: app.window, queue: .main) { _ in finished.fulfill() }
            defer { NotificationCenter.default.removeObserver(observer) }
            app.window.collectionBehavior.insert(.fullScreenPrimary)
            NSApp.setActivationPolicy(.regular)
            app.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            app.window.toggleFullScreen(nil)
            await fulfillment(of: [finished], timeout: 10)
            try await TestSupport.eventually { app.controller.windowState.isFullScreen == enabled }
        }
        let originalGlass = LiquidGlassStore.shared.enabled
        defer { LiquidGlassStore.shared.enabled = originalGlass }
        // Full screen hides a lone tab's strip, so every backend has a second tab; splitting moves it beside its pane.
        app.workspace.newTab()
        try await TestSupport.eventually { app.workspace.current?.activePane?.tabs.count == 2 }
        for backend in ["native", "split", "tmux", "tmux-split"] {
            if backend == "split" {
                // Stacked, so the lower pane's strip is outside the title row.
                app.workspace.split(.rows)
                try await TestSupport.eventually { app.workspace.current?.panes.count == 2 }
            }
            if backend == "tmux" {
                try await app.attach(); try await app.ready()
                app.workspace.newTab()
                try await TestSupport.eventually { app.workspace.current?.windows.count == 2 }
                try await app.ready()
                try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration + 0.05))
            }
            if backend == "tmux-split" {
                // Each window group gets its own shorter strip, whose capsule stays level with a lone strip's track.
                XCTAssertTrue(app.workspace.applyLayout(.columns))
                try await TestSupport.eventually { app.workspace.current?.windowPresentation?.groups.count == 2 }
                try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration + 0.05))
            }
            for glass in [false] + (LiquidGlassStore.supported ? [true] : []) {
                LiquidGlassStore.shared.enabled = glass
            for fullScreen in [false, true] {
                try await setFullScreen(fullScreen)
                // Hiding the sidebar must not drop the tabs out of the title row.
                for sidebar in [true, false] {
                    app.controller.windowState.sidebarVisibilityOverride = sidebar
                    for size in [12.5, 20.0] {
                        app.controller.settings.values.fontSize = size
                        for large in [false, true] {
                            app.controller.settings.values.largeSidebarItems = large
                            // Native and tmux share one row: flat chrome's 30-point strip, or glass's 38-point row, in a
                            // window and full screen alike.
                            let height = AppTypography(contentSize: size).expanded(glass ? 38 : 30)
                            try await TestSupport.eventually {
                                root.layoutSubtreeIfNeeded()
                                let reveal = PresentationTestSupport.views(of: FullScreenSidebarRevealView.self, in: root).first
                                return fullScreen ? reveal?.rowHeight == height : reveal == nil
                            }
                            try await Task.sleep(for: .milliseconds(100))
                            let split = try XCTUnwrap(PresentationTestSupport.views(of: TerminalSplitView.self, in: root).first(where: \.sidebar))
                            try await TestSupport.eventually { split.sidebarHidden == (!sidebar || glass) && !split.sidebarAnimating }
                            let frame = root.convert(split.bounds, from: split)
                            let top = root.isFlipped ? frame.minY : root.bounds.height - frame.maxY
                            let tabRow = try XCTUnwrap(PresentationTestSupport.views(of: ReorderTrackingView.self, in: root).first {
                                if backend == "native" { return $0.configuration.item == .tab(app.workspace.activeTab!.id) }
                            if backend == "split" {
                                let space = app.workspace.current!
                                return $0.configuration.item == .tab(space.panes.first { $0.id == space.layout.paneIDs.first }!.selected)
                            }
                                return $0.configuration.item == .window(app.workspace.current!.activeWindow!.id)
                            })
                            let tabFrame = root.convert(tabRow.bounds, from: tabRow)
                            let tabCenter = root.isFlipped ? tabFrame.midY : root.bounds.height - tabFrame.midY
                            let context = "glass=\(glass), \(backend), \(size), large=\(large), fullscreen=\(fullScreen), sidebar=\(sidebar)"
                            XCTAssertEqual(tabCenter, top + height / 2, accuracy: 1, context)
                            if backend == "split" && (fullScreen || sidebar) {
                                // With the sidebar showing, left-column strips share one start. Without it only the top strip
                                // makes room for the full-screen sidebar button; the lower one keeps the full width.
                                let space = try XCTUnwrap(app.workspace.current)
                                let lower = try XCTUnwrap(space.panes.first { $0.id != space.layout.paneIDs.first })
                                let lowerRow = try XCTUnwrap(PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
                                    .first { $0.configuration.item == .tab(lower.selected) })
                                let lowerStart = root.convert(lowerRow.bounds, from: lowerRow).minX
                                if sidebar {
                                    XCTAssertEqual(lowerStart, tabFrame.minX, accuracy: 0.5, "Left-column strips: \(context)")
                                } else {
                                    XCTAssertLessThan(lowerStart, tabFrame.minX - 1, "Lower strip keeps the full width: \(context)")
                                }
                                if size == 12.5 && !large {
                                    _ = try await PresentationTestSupport.capture(root, named: "split-\(fullScreen ? "fullscreen" : "windowed")-\(sidebar ? "sidebar" : "nosidebar")-window",
                                                                           in: "sidebar-header-validation")
                                }
                            }
                            if fullScreen {
                                // Strip tabs fill the bar, so the selected rule sits at its bottom for local and remote tabs alike.
                                XCTAssertEqual(tabFrame.height, glass ? AppTypography(contentSize: size).expanded(28) : height, accuracy: 0.5, "Tab height follows chrome: \(context)")
                            }
                            if fullScreen && sidebar {
                                // Upstream search opens above the footer, independently of the header row.
                                let field = try await PresentationTestSupport.openSpaceSearch(app.controller, in: root)
                                root.layoutSubtreeIfNeeded()
                                let fieldFrame = root.convert(field.bounds, from: field)
                                let fieldCenter = root.isFlipped ? fieldFrame.midY : root.bounds.height - fieldFrame.midY
                                XCTAssertGreaterThan(fieldCenter, tabCenter, "Sidebar search is below the tabs: \(context)")
                                XCTAssertTrue(root.bounds.contains(fieldFrame), "Sidebar search remains visible: \(context)")
                            } else if !fullScreen {
                                // Windowed, the tabs share the title row with the traffic lights.
                                let zoom = try XCTUnwrap(app.window.standardWindowButton(.zoomButton))
                                let zoomFrame = root.convert(zoom.convert(zoom.bounds, to: nil), from: nil)
                                let zoomCenter = root.isFlipped ? zoomFrame.midY : root.bounds.height - zoomFrame.midY
                                XCTAssertEqual(zoomCenter, tabCenter, accuracy: 1, "Traffic lights and tab: \(context)")
                            // Every windowed glass strip uses pills as tall as macOS's tab bar track, in or below the
                            // title row; flat strips fill their bar.
                            for tab in PresentationTestSupport.views(of: ReorderTrackingView.self, in: root) where glass {
                                switch tab.configuration.item {
                                case .tab, .window:
                                    XCTAssertEqual(root.convert(tab.bounds, from: tab).height, AppTypography(contentSize: size).expanded(28),
                                                   accuracy: 0.5, "Pill tab: \(context)")
                                default: break
                                }
                            }
                            }
                            let capture = try await PresentationTestSupport.capture(root)
                            let scale = CGFloat(capture.bitmap.pixelsWide) / root.bounds.width
                            let pixels = try XCTUnwrap(capture.bitmap.cgImage?.cropping(to:
                                CGRect(x: 0, y: top * scale, width: root.bounds.width * scale, height: height * scale)))
                            let snapshot = PresentationTestSupport.Snapshot(bitmap: NSBitmapImageRep(cgImage: pixels))
                            if fullScreen {
                                let reveal = try XCTUnwrap(PresentationTestSupport.views(of: FullScreenSidebarRevealView.self, in: root).first)
                                let button = root.convert(reveal.button.bounds, from: reveal.button)
                                let buttonTop = root.isFlipped ? button.midY : root.bounds.height - button.midY
                                XCTAssertEqual(buttonTop, top + height / 2, accuracy: 1)
                            if !sidebar && backend != "split" && !glass && !reveal.suppressed && !reveal.hosted {
                                // The strip's slot replaces its inset: one 12-point gap after the button, not both. The
                                // gap leads the strip (the selected tab may be a later one); a strip whose host mark
                                // stands in for the button has no button to measure from.
                                let leading = PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
                                    .map { root.convert($0.bounds, from: $0) }
                                    .filter { abs($0.midY - tabFrame.midY) < 1 }
                                    .map(\.minX).min() ?? tabFrame.minX
                                XCTAssertEqual(leading - button.maxX, 12, accuracy: 1, "Sidebar button gap: \(context)")
                            }
                            }
                            try PresentationTestSupport.save(snapshot.bitmap,
                                named: "\(glass ? "glass" : "classic")-\(backend)-\(size)-\(large ? "large" : "normal")-\(fullScreen ? "fullscreen" : "windowed")-\(sidebar ? "sidebar" : "nosidebar")",
                                in: "sidebar-header-validation")
                        }
                    }
                }
            }
            app.controller.windowState.sidebarVisibilityOverride = nil
            try await setFullScreen(false)
            }
        }
    }

    func testSidebarThemeDefaultsAndPersistenceAreIndependentOfTerminalThemes() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{\"theme\":\"Dracula\",\"lightTheme\":\"Solarized Light\"}".utf8))
        XCTAssertEqual(old.appTheme, .automatic)
        for theme in AppTheme.allCases {
            var preferences = old
            preferences.appTheme = theme
            let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(restored, preferences)
            XCTAssertEqual(restored.theme, "Dracula")
            XCTAssertEqual(restored.lightTheme, "Solarized Light")
        }
        for (palette, mode, expected): (String, String, AppTheme) in [
            ("dark", "system", .automatic), ("dark", "dark", .dark), ("dark", "light", .light),
            ("light", "system", .light), ("graphite", "system", .graphite), ("lavender", "dark", .lavender)
        ] {
            let data = Data("{\"sidebarTheme\":\"\(palette)\",\"appearance\":\"\(mode)\",\"theme\":\"Dracula\",\"lightTheme\":\"Solarized Light\"}".utf8)
            let migrated = try JSONDecoder().decode(Preferences.self, from: data)
            XCTAssertEqual(migrated.appTheme, expected)
            XCTAssertEqual(migrated.theme, "Dracula")
            XCTAssertEqual(migrated.lightTheme, "Solarized Light")
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
            XCTAssertNil(saved["sidebarTheme"]); XCTAssertNil(saved["appearance"])
            XCTAssertEqual(saved["appTheme"] as? String, expected.rawValue)
        }
    }

    func testAutomaticThemeUpdatesOpenWindowsAndPreservesTerminalSurface() async throws {
        let app = try TmuxWalkthrough()
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance; app.close() }
        app.controller.settings.values.appTheme = .automatic
        app.controller.settings.values.theme = "Default"
        app.controller.settings.values.lightTheme = "Default"
        try app.runtime.apply(app.controller.settings.values)
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await TestSupport.eventually { app.runtime.views[id]?.surface != nil }
        let surface = try XCTUnwrap(app.runtime.views[id]?.surface)
        for (appearance, palette): (NSAppearance.Name, SidebarTheme) in [(.aqua, .light), (.darkAqua, .dark), (.aqua, .light)] {
            NSApp.appearance = NSAppearance(named: appearance)
            app.runtime.systemAppearanceDidChange()
            try await TestSupport.eventually {
                SidebarThemeStore.shared.current == palette
                    && ChatThemeStore.shared.current.isDark == (palette == .dark)
                    && app.window.appearance?.name == appearance
            }
            XCTAssertTrue(app.runtime.views[id]?.surface === surface)
        }
        app.controller.settings.values.appTheme = .lavender
        try app.runtime.apply(app.controller.settings.values)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        app.runtime.systemAppearanceDidChange()
        XCTAssertEqual(SidebarThemeStore.shared.current, .lavender)
        XCTAssertFalse(ChatThemeStore.shared.current.isDark)
        XCTAssertTrue(app.runtime.views[id]?.surface === surface)
    }

    func testAppThemePickerUpdatesDefaultTerminalAndChatColors() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let runtime = TerminalRuntime.shared
        let original = runtime.preferences, originalSidebar = SidebarThemeStore.shared.current
        runtime.start(preferences: original)
        defer { runtime.stop(); SidebarThemeStore.shared.current = originalSidebar }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
        var defaults = original
        defaults.theme = "Default"; defaults.lightTheme = "Default"
        try runtime.apply(defaults)
        try store.save(defaults)
        let workspace = Workspace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: SettingsView(store: store, workspace: workspace))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await PresentationTestSupport.selectSettingsTab("Appearance", in: window)
        var picker: NSPopUpButton?
        try await TestSupport.eventually {
            picker = PresentationTestSupport.views(of: NSPopUpButton.self, in: host).first { $0.accessibilityIdentifier() == "settings-dropdown-Theme" }
            return picker != nil
        }
        let control = try XCTUnwrap(picker)
        XCTAssertEqual(control.itemTitles, ["Automatic", "Dark", "Light", "Graphite", "Lavender"])
        for theme in AppTheme.allCases {
            control.selectItem(withTitle: theme.label)
            control.sendAction(control.action, to: control.target)
            let palette = theme.sidebarTheme(systemIsDark: SidebarThemeStore.systemIsDark)
            try await TestSupport.eventually { store.values.appTheme == theme && SidebarThemeStore.shared.current == palette }
            XCTAssertEqual(runtime.preferences.theme, "Default")
            XCTAssertEqual(runtime.preferences.lightTheme, "Default")
            XCTAssertEqual(runtime.preferences.appTheme, theme)
            XCTAssertEqual(ChatThemeStore.shared.current.isDark, palette == .dark)
            if palette != .dark {
                for (actual, expected) in [(ChatThemeStore.shared.current.terminal, palette.palette.window),
                                           (ChatThemeStore.shared.current.accent, palette.palette.accent)] {
                    let rgb = try XCTUnwrap(NSColor(actual).usingColorSpace(.sRGB))
                    let target = try XCTUnwrap(NSColor(expected).usingColorSpace(.sRGB))
                    XCTAssertEqual(rgb.redComponent, target.redComponent, accuracy: 0.001)
                    XCTAssertEqual(rgb.greenComponent, target.greenComponent, accuracy: 0.001)
                    XCTAssertEqual(rgb.blueComponent, target.blueComponent, accuracy: 0.001)
                }
            }
            XCTAssertEqual(SettingsStore(file: directory.appendingPathComponent("settings.json")).values.appTheme, theme)
            _ = try await PresentationTestSupport.capture(window, named: "settings-sidebar-" + theme.rawValue)
        }
    }

    func testExplicitColorSchemesRemainIndependentOfAppTheme() throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        let runtime = TerminalRuntime.shared
        let original = runtime.preferences
        runtime.start(preferences: original)
        defer { runtime.stop(); SidebarThemeStore.shared.current = original.resolvedSidebarTheme }
        var preferences = original
        preferences.theme = "dispatch-black"; preferences.lightTheme = "dispatch-black"
        try runtime.apply(preferences)
        let chat = ChatThemeStore.shared.current
        for theme in SidebarTheme.allCases {
            preferences.appTheme = AppTheme(rawValue: theme.rawValue)!
            try runtime.apply(preferences)
            XCTAssertEqual(ChatThemeStore.shared.current, chat)
            XCTAssertFalse(preferences.usesDefaultColorScheme(systemIsDark: true))
            XCTAssertFalse(preferences.usesDefaultColorScheme(systemIsDark: false))
        }
        preferences.theme = "Default"
        preferences.appTheme = .automatic
        XCTAssertTrue(preferences.usesDefaultColorScheme(systemIsDark: true))
        XCTAssertFalse(preferences.usesDefaultColorScheme(systemIsDark: false))
        preferences.appTheme = .dark
        XCTAssertTrue(preferences.usesDefaultColorScheme(systemIsDark: false))
        preferences.appTheme = .light
        XCTAssertFalse(preferences.usesDefaultColorScheme(systemIsDark: true))
    }

    func testThemeSelectorsFollowAppearance() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let runtime = TerminalRuntime.shared
        let original = runtime.preferences, originalSidebar = SidebarThemeStore.shared.current
        runtime.start(preferences: original)
        defer {
            try? runtime.apply(original)
            runtime.stop()
            SidebarThemeStore.shared.current = originalSidebar
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: SettingsView(store: store, workspace: Workspace()))
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil }
        try await PresentationTestSupport.selectSettingsTab("Appearance", in: window)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(PresentationTestSupport.views(of: NSPopUpButton.self, in: content).contains {
            $0.accessibilityIdentifier() == "settings-dropdown-Light color scheme" && !$0.isHiddenOrHasHiddenAncestor
        })
        let snapshot = try await PresentationTestSupport.capture(window)
        let disclosure = try XCTUnwrap(try snapshot.recognizedText().first {
            $0.topCandidates(1).first?.string.contains("Custom terminal") == true
        }).boundingBox
        try PresentationTestSupport.click(window, at: content.convert(NSPoint(x: disclosure.midX * content.bounds.width,
            y: (content.isFlipped ? 1 - disclosure.midY : disclosure.midY) * content.bounds.height), to: nil))
        try await Task.sleep(for: .milliseconds(250))
        _ = try await PresentationTestSupport.capture(window, named: "settings-custom-color-schemes")
        // Make the expanded document visible before asking the compositor for its pixels.
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: content).first { !$0.isHiddenOrHasHiddenAncestor })
        let document = try XCTUnwrap(scroll.documentView)
        window.setContentSize(NSSize(width: content.bounds.width,
            height: content.bounds.height + max(0, document.bounds.height - scroll.contentView.bounds.height)))
        window.center()
        content.layoutSubtreeIfNeeded()
        let expanded = try await PresentationTestSupport.capture(document).text()
        XCTAssertTrue(expanded.contains("Improve text contrast"), expanded)
        for appearance: AppTheme in [.automatic, .light, .dark, .graphite, .lavender, .automatic] {
            var values = store.values
            values.appTheme = appearance
            try store.save(values)
            try await TestSupport.eventually(diagnostic: PresentationTestSupport.views(of: NSPopUpButton.self, in: content).map {
                "\($0.accessibilityIdentifier() ?? ""): \($0.titleOfSelectedItem ?? "") enabled=\($0.isEnabled)"
            }.joined(separator: "\n")) {
                let controls = PresentationTestSupport.views(of: NSPopUpButton.self, in: content)
                guard controls.first(where: { $0.accessibilityIdentifier() == "settings-dropdown-Theme" })?.titleOfSelectedItem == appearance.label else { return false }
                let light = controls.first { $0.accessibilityIdentifier() == "settings-dropdown-Light color scheme" }
                let dark = controls.first { $0.accessibilityIdentifier() == "settings-dropdown-Dark color scheme" }
                let single = controls.first { $0.accessibilityIdentifier() == "settings-dropdown-Color scheme" }
                func label(_ value: String) -> String { value == "Default" ? "Match app theme" : value }
                if appearance == .automatic {
                    return single == nil && light?.isEnabled == true && dark?.isEnabled == true
                        && light?.titleOfSelectedItem == label(values.lightTheme)
                        && dark?.titleOfSelectedItem == label(values.theme)
                }
                return light == nil && dark == nil && single?.isEnabled == true
                    && single?.titleOfSelectedItem == label(appearance == .dark ? values.theme : values.lightTheme)
            }
            XCTAssertEqual(store.values.lightTheme, values.lightTheme)
            XCTAssertEqual(store.values.theme, values.theme)
            if appearance != .automatic {
                let single = try XCTUnwrap(PresentationTestSupport.views(of: NSPopUpButton.self, in: content).first {
                    $0.accessibilityIdentifier() == "settings-dropdown-Color scheme"
                })
                let choice = try XCTUnwrap(single.itemTitles.first { $0 != single.titleOfSelectedItem })
                single.selectItem(withTitle: choice)
                single.sendAction(single.action, to: single.target)
                let saved = choice == "Match app theme" ? "Default" : choice
                try await TestSupport.eventually {
                    store.values.theme == (appearance == .dark ? saved : values.theme)
                        && store.values.lightTheme == (appearance == .dark ? values.lightTheme : saved)
                }
                _ = try await PresentationTestSupport.capture(window, named: "settings-color-scheme-\(appearance.rawValue)")
            }
        }
    }

    func testFontShortcutsSaveAndApplyConfiguredSize() throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-font-shortcuts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        var expected = Preferences()
        expected.spaceOrder = .tree
        try store.save(expected)
        let controller = AppDelegate(settings: store)
        let previousMenu = NSApp.mainMenu
        let runtime = TerminalRuntime.shared
        let previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: false)
        runtime.start(preferences: expected)
        defer {
            NSApp.mainMenu = previousMenu
            runtime.stop()
            runtime.chat = previousChat
        }
        XCTAssertNil(runtime.error)
        controller.buildMenus()

        func shortcut(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = .command,
                      size: Double) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: event) == true)
            expected.fontSize = size
            XCTAssertEqual(store.values, expected)
            XCTAssertEqual(runtime.preferences, expected)
            XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file)), expected)
        }
        try shortcut("+", keyCode: 24, modifiers: [.command, .shift], size: 13.5)
        try shortcut("=", keyCode: 24, size: 14.5)
        try shortcut("+", keyCode: 69, size: 15.5)
        try shortcut("-", keyCode: 27, size: 14.5)
        try shortcut("0", keyCode: 29, size: Preferences().fontSize)
        for (start, key, code, limit) in [(31.5, "+", UInt16(69), 32.0), (8.5, "-", UInt16(27), 8.0)] {
            expected.fontSize = start
            try runtime.apply(expected)
            try store.save(expected)
            try shortcut(key, keyCode: code, size: limit)
            try shortcut(key, keyCode: code, size: limit)
        }
    }

    func testRetainedSettingsReflectExternalChangesAndPreserveThemWhenEditing() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        var initial = Preferences()
        initial.fontSize = 14.5
        try store.save(initial)

        let runtime = TerminalRuntime.shared
        let previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: false)
        runtime.start(preferences: initial)
        defer { runtime.stop(); runtime.chat = previousChat }
        XCTAssertNil(runtime.error)
        XCTAssertNotNil(runtime.engine)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 550),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: SettingsView(store: store, workspace: Workspace()))
        window.contentView = content
        defer { window.close(); window.contentView = nil }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await PresentationTestSupport.selectSettingsTab("Appearance", in: window)
        func fontSizeIsVisible(_ value: Double) async throws -> Bool {
            let text = try await PresentationTestSupport.capture(content).text()
            return text.contains(String(format: "%.1f", value))
        }
        try await TestSupport.eventually(interval: .milliseconds(100), diagnostic: "The settings font size did not appear") {
            try await fontSizeIsVisible(initial.fontSize)
        }

        // AppDelegate retains this same hosting view when Settings closes.
        // Sidebar order changes and other external saves must refresh its draft.
        window.close()
        var external = store.values
        external.spaceOrder = .tree
        external.fontSize = 18.5
        try store.save(external)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.contentView === content)
        try await TestSupport.eventually(interval: .milliseconds(100), diagnostic: "Reopened settings still show the stale font size") {
            try await fontSizeIsVisible(external.fontSize)
        }

        _ = try await PresentationTestSupport.capture(content, named: "settings-sync", in: "ui-audit")
        let slider = try XCTUnwrap(PresentationTestSupport.views(of: NSSlider.self, in: content).first)
        XCTAssertEqual(slider.minValue, 8)
        XCTAssertEqual(slider.maxValue, 22)
        XCTAssertEqual(slider.doubleValue, external.fontSize)
        let dropdowns = PresentationTestSupport.views(of: NSPopUpButton.self, in: content)
        XCTAssertFalse(dropdowns.isEmpty)
        XCTAssertTrue(dropdowns.allSatisfy { $0.font?.pointSize == 12 })
        XCTAssertTrue(window.makeFirstResponder(slider))
        var expected = external
        expected.fontSize += 0.5
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}",
            isARepeat: false, keyCode: 124))
        slider.keyDown(with: right)
        try await TestSupport.eventually(diagnostic: "The native font change was not saved") {
            store.values.fontSize == expected.fontSize
        }
        XCTAssertEqual(store.values, expected, "Editing font size must preserve the external sidebar order")
        XCTAssertEqual(runtime.preferences, expected)
        try await TestSupport.eventually {
            dropdowns.allSatisfy { $0.font?.pointSize == 12 }
        }
        let saved = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved, expected, "The complete settings file must preserve externally updated fields")
    }
}

private struct RemoteTabHighlightPreview: View {
    let highlight: RemoteTabHighlight
    let tint: HostTint?
    var strip = true

    var body: some View {
        VStack(spacing: 0) {
            if strip { Color.clear.frame(height: 30).hostTintStrip(tint) }
            Color.clear
        }
        .frame(width: 240, height: 160)
        .background(Chrome.window)
        .hostTintBorder(tint, surfaceID: nil, stripHeight: strip ? 30 : 0)
        .environment(\.remoteTabHighlight, highlight)
        .id(tint)
    }
}
