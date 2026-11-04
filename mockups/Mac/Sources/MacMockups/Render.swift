import AppKit
import SwiftUI

/// Draws screens offscreen with AppKit's real controls in their active look, without activating the app or taking
/// focus: an application that reports itself active and a borderless window, placed off every screen, that reports
/// itself key and main. `cacheDisplay` then draws toggles, buttons, fields and pickers as a focused window shows them.
/// It does not draw materials or Liquid Glass (they come out as flat fills); draw those by hand.
final class MockApplication: NSApplication {
    override var isActive: Bool { true }
}

final class MockWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    // AppKit's controls ask these (private) to choose their active look; without them a checkbox draws gray and the
    // default button has no accent.
    @objc var hasKeyAppearance: Bool { true }
    @objc var hasMainAppearance: Bool { true }
    @objc var _hasKeyAppearance: Bool { true }
    @objc var _hasMainAppearance: Bool { true }
    @objc var _hasActiveAppearance: Bool { true }
    @objc var _hasActiveAppearanceIgnoringKeyFocus: Bool { true }
    @objc var _hasActiveControls: Bool { true }
}

struct RenderOptions {
    var themes: [SidebarTheme] = [.dark, .light]
    var interfaceFont = InterfaceFont.system
    var contentSize: CGFloat = 14
    /// Liquid Glass (the app's default) or flat chrome (`--flat`).
    var glass = true
    var scale: CGFloat = 2
    var output = Paths.shots
}

enum Paths {
    static let mockups = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..")
        .standardizedFileURL
    static let shots = mockups.appendingPathComponent("shots/mac")
    static let sheets = mockups.appendingPathComponent("sheets")
    static func shot(_ id: String, _ theme: SidebarTheme, in directory: URL = shots) -> URL {
        directory.appendingPathComponent("\(id)-\(theme.rawValue).png")
    }
}

@MainActor enum Renderer {
    /// The screen in `theme`, as a PNG at `options.scale`.
    static func render(_ screen: Screen, theme: SidebarTheme, options: RenderOptions) throws -> URL {
        AppFont.register()
        SidebarThemeStore.shared.current = theme
        InterfaceFontStore.shared.current = options.interfaceFont
        LiquidGlassStore.shared.active = options.glass
        Mock.contentSize = options.contentSize
        let typography = AppTypography(contentSize: options.contentSize)
        let content = screen.make()
        let root = Group {
            if screen.staged { Stage { content } } else { content }
        }
        .environment(\.appTypography, typography)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .tint(theme.palette.accent)

        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { throw Failure("\(screen.id) has no size: give its root a frame") }
        host.frame = NSRect(origin: .zero, size: size)
        let window = MockWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        host.layoutSubtreeIfNeeded()
        // Lets SwiftUI finish its first passes (fonts, images, onAppear state).
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * options.scale).rounded()),
                                            pixelsHigh: Int((size.height * options.scale).rounded()), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { throw Failure("no bitmap for \(screen.id)") }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure("no PNG for \(screen.id)") }
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        let url = Paths.shot(screen.id, theme, in: options.output)
        try png.write(to: url)
        return url
    }
}

/// A contact sheet: the group's shots in a grid, each scaled to the column's width, labelled with id and title.
@MainActor enum ContactSheet {
    static func write(_ screens: [Screen], theme: SidebarTheme, from directory: URL, to url: URL, columns: Int = 3,
                      columnWidth: CGFloat = 900) throws {
        let items = screens.compactMap { screen in
            NSImage(contentsOf: Paths.shot(screen.id, theme, in: directory)).map { (screen, $0) }
        }
        guard !items.isEmpty else { throw Failure("no shots for \(url.lastPathComponent): render first") }
        let pad: CGFloat = 32, label: CGFloat = 34
        let columns = min(columns, items.count)
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        func height(_ image: NSImage) -> CGFloat { image.size.height * columnWidth / image.size.width }
        let rowHeights = rows.map { $0.map { height($0.1) }.max()! + label }
        let width = pad + CGFloat(columns) * (columnWidth + pad)
        let total = pad + rowHeights.reduce(0) { $0 + $1 + pad }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(total), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw Failure("no bitmap for sheet") }
        rep.size = NSSize(width: width, height: total)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: theme.isDark ? 0.1 : 0.86, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: total).fill()
        var top = total - pad
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: theme.isDark ? NSColor.white : NSColor.black,
        ]
        for (row, rowHeight) in zip(rows, rowHeights) {
            for (column, (screen, image)) in row.enumerated() {
                let x = pad + CGFloat(column) * (columnWidth + pad)
                NSAttributedString(string: "\(screen.id)  \(screen.title)", attributes: attributes)
                    .draw(with: NSRect(x: x, y: top - 22, width: columnWidth, height: 22), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
                let h = height(image)
                image.draw(in: NSRect(x: x, y: top - label - h, width: columnWidth, height: h))
            }
            top -= rowHeight + pad
        }
        NSGraphicsContext.restoreGraphicsState()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
