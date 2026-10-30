import AppKit
import SwiftUI

/// How an image shows: fit to the area (never enlarged), or a scale the user picked, 1 being one image pixel per point.
enum FileImageZoom: Equatable {
    case fit
    case scale(CGFloat)

    /// The largest zoom: past it a pixel is already a block a dozen points wide on a Retina screen.
    static let maximum: CGFloat = 8
    /// The scales ⌘+ and ⌘− step through, as Preview's do.
    static let stops: [CGFloat] = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    /// The scale drawn now, given the area's fit scale.
    func scale(fit: CGFloat) -> CGFloat {
        switch self {
        case .fit: fit
        case .scale(let scale): scale
        }
    }

    /// The next stop up (`in`) or down from what shows; down to the fit scale or below is fit again.
    func stepped(in zoomIn: Bool, fit: CGFloat) -> FileImageZoom {
        let current = scale(fit: fit)
        if zoomIn {
            let next = Self.stops.first { $0 > current + 0.001 } ?? Self.maximum
            return .scale(min(Self.maximum, max(next, fit)))
        }
        guard let next = Self.stops.last(where: { $0 < current - 0.001 }), next > fit + 0.001 else { return .fit }
        return .scale(next)
    }

    /// Fit when the scale is down at the fit scale: a pinch back out to it fits again, and follows the area's size.
    static func settled(_ scale: CGFloat, fit: CGFloat) -> FileImageZoom {
        scale <= fit + 0.001 ? .fit : .scale(scale)
    }
}

/// An image on a checker (F2d): fit to the area (never enlarged) or zoomed, one image pixel per point at 100 %,
/// scrolling when larger than the area. A trackpad pinches, ⌘+ ⌘− step and ⌘0 toggles fit and actual size; the
/// footer names the scale and opens the image full screen (`FileImageFullScreen`).
struct FileImagePreview: View {
    @Environment(\.chatTheme) private var theme
    /// The encoded file; decoded off the main actor at the size it draws.
    let data: Data
    /// Tells a reloaded file from the last one: its bytes are not compared.
    let revision: FileRevision?
    let pixelSize: CGSize
    @Binding var zoom: FileImageZoom
    /// The zoom keys are taken only while the preview has focus: elsewhere they stay the menu's font sizes.
    let focused: Bool
    /// The full-screen viewer names the file in its footer; the pane's header already does.
    var title: String?
    /// Shown full screen: the footer's button leaves instead of entering.
    var isFullScreen = false
    /// The footer's full-screen button.
    var toggleFullScreen: (() -> Void)?
    /// A click on the picture, which AppKit gets rather than SwiftUI: the pane takes the keyboard.
    var activate: () -> Void = {}
    /// The last decode; it keeps showing while a new size decodes, so a resize never blanks the picture.
    @State private var decoded: (key: DecodeKey, image: CGImage)?

    private struct DecodeKey: Hashable {
        let revision: FileRevision?
        let bytes: Int
        /// Nil decodes whole; the loader still applies its safety ceiling.
        let maxPixels: Int?
    }

    /// Fit: about twice the area's long side, in 512-pixel steps so a live resize decodes a few times, not every
    /// frame; nil when that reaches the image's own size anyway. Zoomed: nil, whole. The loader applies its hard
    /// decode ceiling either way.
    static func decodeBound(_ pixels: CGSize, area: CGSize, zoomed: Bool) -> Int? {
        let full = Int(max(pixels.width, pixels.height))
        guard !zoomed else { return nil }
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

    /// The margin a fitted image keeps from the area's edges, room for its shadow.
    static let inset: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let area = CGSize(width: geometry.size.width, height: max(0, geometry.size.height - 24))
            let fit = Self.fitScale(pixelSize, in: CGSize(width: area.width - Self.inset * 2,
                                                          height: area.height - Self.inset * 2))
            let key = DecodeKey(revision: revision, bytes: data.count,
                                maxPixels: Self.decodeBound(pixelSize, area: area, zoomed: zoom != .fit))
            // A decode for another revision is another file's picture: nothing shows until this one's arrives.
            let image = decoded.flatMap { $0.key.revision == revision && $0.key.bytes == data.count ? $0.image : nil }
            VStack(spacing: 0) {
                ZStack {
                    FileCheckerboard(dark: theme.window, light: theme.sidebar)
                    FileImageCanvas(image: image, pixelSize: pixelSize, zoom: zoom, fit: fit,
                                    shadowOpacity: theme.isDark ? 0.5 : 0.15,
                                    label: "Image, \(Int(pixelSize.width)) × \(Int(pixelSize.height)) pixels",
                                    changed: { zoom = $0 }, activate: activate)
                }
                .frame(width: area.width, height: area.height)
                .clipped()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("file-preview-image")
                footer(fit: fit)
            }
            .task(id: key) {
                guard decoded?.key != key else { return }
                guard let image = await FilePreviewLoader.decodeImage(data, maxPixels: key.maxPixels),
                      !Task.isCancelled else { return }
                decoded = (key, image)
            }
        }
    }

    private func footer(fit: CGFloat) -> some View {
        let scale = zoom.scale(fit: fit)
        let label = switch zoom {
        case .fit: "fit · \(Self.percent(scale))"
        case .scale(let value) where abs(value - 1) < 0.001: "actual size · 100%"
        case .scale: "zoom · \(Self.percent(scale))"
        }
        return HStack(spacing: 10) {
            Text(verbatim: title.map { TextRendering.visible($0) + " · " + label } ?? label)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier("file-preview-image-scale")
            Spacer(minLength: 8)
            Button { zoom = zoom.stepped(in: false, fit: fit) } label: { Image(systemName: "minus") }
                .disabled(zoom == .fit)
                .keyboardShortcut(focused ? KeyboardShortcut("-", modifiers: .command) : nil)
                .help("Zoom out · ⌘−")
                .accessibilityLabel("Zoom out")
                .accessibilityIdentifier("file-preview-zoom-out")
            Button { zoom = zoom.stepped(in: true, fit: fit) } label: { Image(systemName: "plus") }
                .disabled(scale >= FileImageZoom.maximum - 0.001)
                .keyboardShortcut(focused ? KeyboardShortcut("=", modifiers: .command) : nil)
                .help("Zoom in · ⌘+")
                .accessibilityLabel("Zoom in")
                .accessibilityIdentifier("file-preview-zoom-in")
            Button(zoom == .fit ? "⌘0 actual size" : "⌘0 fit") { zoom = zoom == .fit ? .scale(1) : .fit }
                .keyboardShortcut(focused ? KeyboardShortcut("0", modifiers: .command) : nil)
                .help(zoom == .fit ? "Actual size · ⌘0" : "Fit · ⌘0")
                .accessibilityIdentifier("file-preview-actual-size")
            if let toggleFullScreen {
                Button(action: toggleFullScreen) {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(isFullScreen ? "Exit full screen · esc" : "Full screen")
                .accessibilityLabel(isFullScreen ? "Exit full screen" : "Full screen")
                .accessibilityIdentifier("file-preview-full-screen")
            }
        }
        .buttonStyle(.plain)
        .font(theme.typography.font(offset: -2))
        .foregroundStyle(theme.muted)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

/// The picture in an AppKit scroll view, whose magnification is the zoom: a trackpad pinch scales about the pointer
/// and a two-finger double tap toggles, as in Preview. A drag pans. The zoom it settles on goes back through `changed`.
private struct FileImageCanvas: NSViewRepresentable {
    let image: CGImage?
    let pixelSize: CGSize
    let zoom: FileImageZoom
    let fit: CGFloat
    let shadowOpacity: Float
    let label: String
    let changed: (FileImageZoom) -> Void
    let activate: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        let clip = FileImageClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = FileImageDocumentView(frame: CGRect(origin: .zero, size: pixelSize))
        context.coordinator.attach(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor final class Coordinator {
        private var parent: FileImageCanvas?
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        /// A pinch in progress: the binding follows it, and nothing sets the magnification under the fingers.
        private var live = false
        /// The magnification is being set from the binding: the change it makes is not reported back.
        private var applying = false
        private var shown: CGFloat = 0

        private var document: FileImageDocumentView? { scroll?.documentView as? FileImageDocumentView }

        func attach(_ scroll: NSScrollView) {
            self.scroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.magnified() }
                },
                center.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.live = true }
                },
                center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.live = false
                        self?.magnified()
                    }
                },
            ]
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        func update(_ parent: FileImageCanvas) {
            self.parent = parent
            guard let scroll, let document else { return }
            if document.frame.size != parent.pixelSize { document.setFrameSize(parent.pixelSize) }
            document.image = parent.image
            document.shadowOpacity = parent.shadowOpacity
            document.onActivate = parent.activate
            document.setAccessibilityLabel(parent.label)
            scroll.minMagnification = parent.fit
            scroll.maxMagnification = FileImageZoom.maximum
            let target = parent.zoom.scale(fit: parent.fit)
            if !live, abs(scroll.magnification - target) > 0.0005 {
                applying = true
                let visible = scroll.contentView.documentVisibleRect
                scroll.setMagnification(target, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
                applying = false
            }
            shown = scroll.magnification
            document.magnification = shown
        }

        /// The clip view's bounds moved: a scroll, or a new magnification to style for and (from a pinch) report.
        private func magnified() {
            guard let scroll, let document, abs(scroll.magnification - shown) > 0.0005 else { return }
            shown = scroll.magnification
            document.magnification = shown
            guard !applying, let parent else { return }
            let zoom = FileImageZoom.settled(shown, fit: parent.fit)
            // Out of AppKit's notification, not inside a SwiftUI update that may have caused it.
            if zoom != parent.zoom { Task { @MainActor in parent.changed(zoom) } }
        }
    }
}

/// Centers a document smaller than the visible area instead of pinning it to the corner.
private final class FileImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width { rect.origin.x = (document.width - rect.width) / 2 }
        if rect.height > document.height { rect.origin.y = (document.height - rect.height) / 2 }
        return rect
    }
}

/// The picture as a layer's contents, one point per image pixel before magnification: the GPU scales it, nothing
/// redraws on a pinch or a scroll. Its shadow has a path and keeps one size on screen whatever the zoom.
private final class FileImageDocumentView: NSView {
    var image: CGImage? {
        didSet { if image !== oldValue { needsDisplay = true } }
    }
    var magnification: CGFloat = 1 {
        didSet { if magnification != oldValue { needsDisplay = true } }
    }
    var shadowOpacity: Float = 0.5 {
        didSet { if shadowOpacity != oldValue { needsDisplay = true } }
    }
    var onActivate: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.contentsGravity = .resize
        // Enlarged, pixels stay crisp squares; reduced, they are filtered smooth.
        layer.magnificationFilter = magnification >= 1 ? .nearest : .linear
        layer.minificationFilter = .trilinear
        // In the document's coordinates, which the magnification scales: divided by it, 12 points on screen.
        let scale = max(magnification, 0.01)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = image == nil ? 0 : shadowOpacity
        layer.shadowRadius = 12 / scale
        layer.shadowOffset = CGSize(width: 0, height: (layer.isGeometryFlipped ? 5 : -5) / scale)
        layer.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    /// A drag moves the picture under the pointer, as the hand tool does.
    override func mouseDragged(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let scale = max(scroll.magnification, 0.01)
        var bounds = clip.bounds
        bounds.origin.x -= event.deltaX / scale
        bounds.origin.y -= event.deltaY / scale
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
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

/// An image from Files in a window of its own in macOS full screen, in its own Space: the same zoom as the pane, its
/// own scale. Esc, the footer's button or leaving full screen closes it. One at a time; another image replaces it.
@MainActor enum FileImageFullScreen {
    private static var window: FileImageFullScreenWindow?

    static func show(name: String, data: Data, revision: FileRevision?, pixelSize: CGSize, from source: NSWindow?) {
        window?.close()
        let screen = source?.screen ?? NSScreen.main
        let window = FileImageFullScreenWindow(contentRect: screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800),
                                               styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                               backing: .buffered, defer: false)
        let theme = ChatThemeStore.shared.current
        window.title = name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // Never a tab of the main window's group.
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = NSColor(theme.window)
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.delegate = window
        window.contentView = NSHostingView(rootView: FileImageFullScreenView(
            name: name, data: data, revision: revision, pixelSize: pixelSize,
            close: { [weak window] in window?.leave() })
            .environment(\.chatTheme, theme)
            .environment(\.colorScheme, theme.isDark ? .dark : .light))
        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    fileprivate static func closed(_ closing: FileImageFullScreenWindow) {
        if window === closing { window = nil }
    }
}

private struct FileImageFullScreenView: View {
    @Environment(\.chatTheme) private var theme
    let name: String
    let data: Data
    let revision: FileRevision?
    let pixelSize: CGSize
    let close: () -> Void
    @State private var zoom = FileImageZoom.fit

    var body: some View {
        FileImagePreview(data: data, revision: revision, pixelSize: pixelSize, zoom: $zoom, focused: true, title: name,
                         isFullScreen: true, toggleFullScreen: close)
            .background(theme.window)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("file-image-full-screen")
    }
}

private final class FileImageFullScreenWindow: NSWindow, NSWindowDelegate {
    /// Going into full screen: AppKit ignores a toggle until the transition ends, so leaving waits for it.
    private var entering = false
    private var leaveWhenEntered = false

    /// Out of full screen first (its Space slides away), then closed; a window that never got there closes at once.
    func leave() {
        if entering {
            leaveWhenEntered = true
        } else if styleMask.contains(.fullScreen) {
            toggleFullScreen(nil)
        } else {
            close()
        }
    }

    override func cancelOperation(_ sender: Any?) { leave() }

    func windowWillEnterFullScreen(_ notification: Notification) { entering = true }

    func windowDidEnterFullScreen(_ notification: Notification) {
        entering = false
        // Still inside the transition here, where a toggle is ignored too: the next turn of the main loop.
        if leaveWhenEntered { Task { @MainActor [weak self] in self?.toggleFullScreen(nil) } }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        entering = false
        if leaveWhenEntered { close() }
    }

    func windowDidExitFullScreen(_ notification: Notification) { close() }

    func windowWillClose(_ notification: Notification) {
        FileImageFullScreen.closed(self)
    }
}
