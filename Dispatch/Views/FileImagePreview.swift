import AppKit
import SwiftUI

/// An image on a checker (F2d): fit to the pane (never enlarged) or at actual size, one image pixel per point,
/// scrolling when larger than the pane. The footer names the scale; ⌘0 toggles.
struct FileImagePreview: View {
    @Environment(\.chatTheme) private var theme
    /// The encoded file; decoded off the main actor at the size it draws.
    let data: Data
    /// Tells a reloaded file from the last one: its bytes are not compared.
    let revision: FileRevision?
    let pixelSize: CGSize
    @Binding var actualSize: Bool
    /// ⌘0 is taken only while the preview has focus: elsewhere it stays the menu's Reset Font Size.
    let focused: Bool
    /// The last decode; it keeps showing while a new size decodes, so a resize never blanks the picture.
    @State private var decoded: (key: DecodeKey, image: NSImage)?

    private struct DecodeKey: Hashable {
        let revision: FileRevision?
        let bytes: Int
        /// Nil decodes the whole image.
        let maxPixels: Int?
    }

    /// About twice the area's long side, in 512-pixel steps so a live resize decodes a few times, not every frame;
    /// nil (whole) when that reaches the image's own size anyway.
    static func decodeBound(_ pixels: CGSize, area: CGSize, actualSize: Bool) -> Int? {
        let full = Int(max(pixels.width, pixels.height))
        guard !actualSize else { return nil }
        let wanted = Int((2 * max(area.width, area.height)).rounded(.up))
        let bound = max(512, (wanted + 511) / 512 * 512)
        return bound >= full ? nil : bound
    }

    static func fitScale(_ pixels: CGSize, in available: CGSize) -> CGFloat {
        guard pixels.width > 0, pixels.height > 0, available.width > 0, available.height > 0 else { return 1 }
        return min(1, available.width / pixels.width, available.height / pixels.height)
    }

    static func percent(_ scale: CGFloat) -> String {
        "\(max(1, Int((scale * 100).rounded())))%"
    }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 16
            let area = CGSize(width: geometry.size.width, height: max(0, geometry.size.height - 24))
            let scale = actualSize ? 1 : Self.fitScale(pixelSize, in: CGSize(width: area.width - inset * 2,
                                                                              height: area.height - inset * 2))
            let key = DecodeKey(revision: revision, bytes: data.count,
                                maxPixels: Self.decodeBound(pixelSize, area: area, actualSize: actualSize))
            VStack(spacing: 0) {
                ZStack {
                    FileCheckerboard(dark: theme.window, light: theme.sidebar)
                    if actualSize {
                        ScrollView([.horizontal, .vertical]) {
                            picture(scale: 1)
                                .padding(inset)
                                .frame(minWidth: area.width, minHeight: area.height)
                        }
                    } else {
                        picture(scale: scale)
                    }
                }
                .frame(width: area.width, height: area.height)
                .clipped()
                .accessibilityIdentifier("file-preview-image")
                footer(scale: scale)
            }
            .task(id: key) {
                guard decoded?.key != key else { return }
                guard let image = await FilePreviewLoader.decodeImage(data, maxPixels: key.maxPixels),
                      !Task.isCancelled else { return }
                decoded = (key, NSImage(cgImage: image, size: pixelSize))
            }
        }
    }

    @ViewBuilder private func picture(scale: CGFloat) -> some View {
        let frame = CGSize(width: max(1, pixelSize.width * scale), height: max(1, pixelSize.height * scale))
        // A decode for another revision is another file's picture: nothing shows until this one's arrives.
        if let decoded, decoded.key.revision == revision, decoded.key.bytes == data.count {
            Image(nsImage: decoded.image)
                .resizable()
                .interpolation(scale >= 1 ? .none : .high)
                .frame(width: frame.width, height: frame.height)
                .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.15), radius: 12, y: 5)
                .accessibilityLabel("Image, \(Int(pixelSize.width)) × \(Int(pixelSize.height)) pixels")
        } else {
            Color.clear.frame(width: frame.width, height: frame.height)
        }
    }

    private func footer(scale: CGFloat) -> some View {
        HStack {
            Text(actualSize ? "actual size · 100%" : "fit · \(Self.percent(scale))")
                .accessibilityIdentifier("file-preview-image-scale")
            Spacer(minLength: 8)
            Button(actualSize ? "⌘0 fit" : "⌘0 actual size") { actualSize.toggle() }
                .buttonStyle(.plain)
                .keyboardShortcut(focused ? KeyboardShortcut("0", modifiers: .command) : nil)
                .help(actualSize ? "Fit · ⌘0" : "Actual size · ⌘0")
                .accessibilityIdentifier("file-preview-actual-size")
        }
        .font(theme.typography.font(offset: -2))
        .foregroundStyle(theme.muted)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

/// The transparency checker behind images, in two tones of the theme's panels.
struct FileCheckerboard: View {
    let dark: Color
    let light: Color
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dark))
            var squares = Path()
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : square
                while x < size.width {
                    squares.addRect(CGRect(x: x, y: y, width: square, height: square))
                    x += square * 2
                }
                y += square
                row += 1
            }
            context.fill(squares, with: .color(light))
        }
        .accessibilityHidden(true)
    }
}
