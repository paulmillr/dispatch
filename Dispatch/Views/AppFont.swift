import AppKit
import SwiftUI
import CoreText

enum AppFont {
    @MainActor private static var registered = false
    @MainActor static func register() {
        guard !registered else { return }
        registered = true
        for ext in ["ttf", "otf"] {
            for url in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
    static func ui(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .monospaced) -> Font {
        .custom("SourceCodePro-Regular", size: size).weight(weight)
    }
    static func shortcut(size: CGFloat = 11) -> Font { Font(nativeShortcut(size: size)) }
    /// SF Mono keeps keyboard legends monospaced with a full-width Shift glyph.
    static func nativeShortcut(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    @MainActor static func native(size: CGFloat, semibold: Bool = false) -> NSFont {
        register()
        return NSFont(name: semibold ? "SourceCodePro-SemiBold" : "SourceCodePro-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: semibold ? .semibold : .regular)
    }
}

/// UI sizes are offsets from the content size; compact labels retain an 8 pt floor.
struct AppTypography: Equatable {
    var contentSize: CGFloat = 12.5
    func size(offset: CGFloat = 0) -> CGFloat { max(8, contentSize + offset) }
    func font(offset: CGFloat = 0, weight: Font.Weight = .regular, design: Font.Design = .monospaced) -> Font {
        AppFont.ui(size: size(offset: offset), weight: weight, design: design)
    }
    func shortcut(offset: CGFloat = -1.5) -> Font { AppFont.shortcut(size: size(offset: offset)) }
    var sidebarFont: Font { AppFont.ui(size: contentSize - 0.5) }
    var sidebarShortcut: Font { AppFont.shortcut(size: contentSize - 0.5) }
    /// Grow text containers with larger fonts without shrinking their default hit areas.
    func expanded(_ dimension: CGFloat) -> CGFloat { dimension * max(1, contentSize / 12.5) }
    /// Every host icon in the app (HostGlyph): about the text's size, growing with it.
    var hostIconSize: CGFloat { expanded(15) }
    @MainActor func popoverHeight(_ dimension: CGFloat) -> CGFloat {
        min(expanded(dimension), max(200, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
    }
    /// At the default size, Source Code Pro's x-height matches macOS's 11-point tab titles.
    var tabSize: CGFloat { size(offset: -0.5) }
}

private struct AppTypographyKey: EnvironmentKey {
    static let defaultValue = AppTypography()
}

extension EnvironmentValues {
    var appTypography: AppTypography {
        get { self[AppTypographyKey.self] }
        set { self[AppTypographyKey.self] = newValue }
    }
}
