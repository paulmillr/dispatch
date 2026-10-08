import AppKit
import Term
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import DispatchApp

@MainActor
final class TerminalContrastTests: XCTestCase {
    func testContrastPreferencePreservesExistingSchemesAndPersists() throws {
        let legacy = try JSONDecoder().decode(Preferences.self, from: Data(
            #"{"theme":"Dracula","lightTheme":"Ayu Light","appearance":"system"}"#.utf8))
        XCTAssertFalse(legacy.improveTextContrast)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        var preferences = legacy
        for enabled in [true, false] {
            preferences.improveTextContrast = enabled
            try store.save(preferences)
            let restored = SettingsStore(file: file)
            XCTAssertNil(restored.error)
            XCTAssertEqual(restored.values, preferences)
            XCTAssertEqual(restored.values.resolvedTheme(systemIsDark: false), "Ayu Light")
            XCTAssertEqual(restored.values.resolvedTheme(systemIsDark: true), "Dracula")
        }
    }

    func testCorrectionRedrawsExistingTextAcrossSchemesAndCanBeDisabled() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        guard #available(macOS 14.4, *) else { throw XCTSkip("Composited terminal capture requires macOS 14.4") }
        let runtime = TerminalRuntime.shared
        let original = runtime.preferences
        var preferences = Preferences()
        preferences.fontSize = 22
        preferences.theme = "Dracula"
        preferences.lightTheme = "Ayu Light"
        preferences.appTheme = .light
        runtime.start(preferences: preferences)
        defer { runtime.stop(); SidebarThemeStore.shared.current = original.resolvedSidebarTheme }
        XCTAssertNil(runtime.error)
        // Explicit application backgrounds must work independently of the theme.
        // The green row already has enough contrast and should retain its color.
        let script = #"printf '\033[2J\033[H\033[?25l\033[48;2;255;255;255m\033[38;2;238;238;0mPALE YELLOW TEXT\033[0m\r\n\033[48;2;0;0;0m\033[38;2;0;0;51mDARK BLUE TEXT\033[0m\r\n\033[48;2;0;0;0m\033[38;2;0;255;0mREADABLE GREEN TEXT\033[0m\r\n'; sleep 120"#
        let terminal = TerminalView(id: UUID(), directory: "/tmp",
            launchCommand: "/bin/sh -c " + HerdrLaunch.quote(script), presentation: .standalone)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = terminal
        window.makeKeyAndOrderFront(nil)
        defer { terminal.destroy(); window.orderOut(nil); window.contentView = nil; window.close() }
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: terminal).contains("READABLE GREEN TEXT") }
        let surface = try XCTUnwrap(terminal.surface)
        let content = try await SCShareableContent.currentProcess
        let ownWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        // The thresholds below are sRGB values; a P3 display would otherwise
        // return its own encoding (sRGB green arrives as P3 117, 251, 76).
        configuration.colorSpaceName = CGColorSpace.sRGB

        for appearance: AppTheme in [.light, .dark] {
            preferences.appTheme = appearance
            var originalGreen = 0
            for (step, enabled) in [false, true, false].enumerated() {
                preferences.improveTextContrast = enabled
                try runtime.apply(preferences)
                // Allow the render thread and window compositor to present the update.
                try await Task.sleep(for: .milliseconds(350))
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let bitmap = NSBitmapImageRep(cgImage: image)
                try PresentationTestSupport.save(bitmap, named: "\(appearance.rawValue)-\(step)-\(enabled ? "on" : "off")",
                    in: "contrast-validation")
                var yellow = 0, blue = 0, green = 0, correctedYellow = 0, correctedBlue = 0
                // Native title-bar buttons can appear after the first frame;
                // measure only terminal content, not window decoration.
                let contentTop = Int((window.frame.height - terminal.bounds.height) * window.backingScaleFactor)
                for y in stride(from: contentTop, to: bitmap.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                        if r > 0.7 && g > 0.7 && b < 0.3 { yellow += 1 }
                        if r < 0.05 && g < 0.05 && b > 0.12 && b < 0.3 { blue += 1 }
                        if r < 0.2 && g > 0.7 && b < 0.2 { green += 1 }
                        if r > b + 0.1 && g > b + 0.1 && r < 0.7 && g < 0.7 { correctedYellow += 1 }
                        if b > r + 0.15 && b > g + 0.15 && b > 0.4 { correctedBlue += 1 }
                    }
                }
                if enabled {
                    XCTAssertEqual(yellow, 0, "Low-contrast yellow must be corrected on white")
                    XCTAssertEqual(blue, 0, "Low-contrast blue must be corrected on black")
                    XCTAssertGreaterThan(correctedYellow, 30, "Pale yellow must stay colored instead of becoming black")
                    XCTAssertGreaterThan(correctedBlue, 30, "Dark blue must stay colored instead of becoming white")
                } else {
                    XCTAssertGreaterThan(yellow, 30, "Disabling correction restores application colors")
                    XCTAssertGreaterThan(blue, 30, "Disabling correction restores application colors")
                }
                if step == 0 { originalGreen = green }
                XCTAssertGreaterThan(green, 30)
                XCTAssertEqual(Double(green), Double(originalGreen), accuracy: Double(originalGreen) * 0.05,
                    "Already-readable colors must be preserved")
                XCTAssertTrue(terminal.surface === surface, "Changing contrast must not recreate the session")
                XCTAssertTrue(TerminalTestSupport.screen(terminal: terminal).contains("PALE YELLOW TEXT"))
            }
        }
    }
}
