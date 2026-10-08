import AppKit
import SwiftUI

enum ReorderItem: Equatable {
    case space(UUID)
    case tab(UUID)
    case window(UUID)
    case host(HostID)
    case queued(UUID)
}

/// Reordering is entirely local, with a lightweight tab label and destination
/// preview instead of a pasteboard transfer or drop animation. The model changes synchronously on mouse-up.
struct LocalReorder: NSViewRepresentable {
    enum Edge: Equatable { case vertical, horizontal, pane, split(PaneEdge) }
    var item: ReorderItem?
    var edge: Edge
    var reorderGroup: String?
    var leadingButtonWidth: CGFloat = 0
    var help: String?
    var spaceHover: SpaceHoverDetails?
    var hoverFontSize: CGFloat = 12
    var dragLabel: String?
    var select: () -> Void = {}
    var accepts: (ReorderItem) -> Bool
    var drop: (ReorderItem, Bool) -> Void

    func makeNSView(context: Context) -> ReorderTrackingView { ReorderTrackingView(configuration: self) }
    func updateNSView(_ view: ReorderTrackingView, context: Context) {
        let hoverChanged = view.configuration.spaceHover != spaceHover || view.configuration.hoverFontSize != hoverFontSize
        view.configuration = self
        view.toolTip = spaceHover == nil ? help : nil
        if hoverChanged { view.hover.refresh(from: view) }
    }
}

final class ReorderTrackingView: NSView {
    private static let targets = NSHashTable<ReorderTrackingView>.weakObjects()
    let hover = SpaceHoverPresenter()
    private var hoverTracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }
    var configuration: LocalReorder
    private(set) var insertionAfter: Bool? { didSet { needsDisplay = true } }

    init(configuration: LocalReorder) {
        self.configuration = configuration
        super.init(frame: .zero)
        Self.targets.add(self)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        if configuration.spaceHover != nil { hover.schedule(from: self) }
    }
    override func mouseExited(with event: NSEvent) { hovered = false; hover.dismiss() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        hover.dismiss()
        super.viewWillMove(toWindow: newWindow)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard configuration.item != nil, let event = NSApp.currentEvent,
              event.type != .rightMouseDown, !event.modifierFlags.contains(.control) else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.x >= configuration.leadingButtonWidth else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered, configuration.spaceHover != nil {
            NSColor.white.withAlphaComponent(0.04).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        guard let after = insertionAfter else { return }
        NSColor(white: 0.8, alpha: 1).setFill()
        switch configuration.edge {
        case .vertical:
            NSRect(x: 0, y: after ? bounds.height - 2 : 0, width: bounds.width, height: 2).fill()
        case .horizontal:
            NSRect(x: after ? bounds.width - 2 : 0, y: 0, width: 2, height: bounds.height).fill()
        case .split(let edge):
            NSColor(white: 0.8, alpha: 0.08).setFill()
            bounds.fill()
            NSColor(white: 0.8, alpha: 0.65).setStroke()
            NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).stroke()
            let text = "drop to split \(edge.rawValue)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: AppFont.native(size: 11), .foregroundColor: NSColor.lightGray]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: max(4, (bounds.width - size.width) / 2), y: bounds.midY), withAttributes: attributes)
        case .pane:
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        trackMouse(with: event) { window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) }
    }

    func trackMouse(with event: NSEvent, nextEvent: () -> NSEvent?) {
        hover.dismiss()
        guard let window, let item = configuration.item else { return }
        let origin = event.locationInWindow
        var dragging = false
        var target: ReorderTrackingView?
        var badge: NSTextField?
        defer { target?.insertionAfter = nil; badge?.removeFromSuperview() }

        while let next = nextEvent() {
            if next.type == .keyDown {
                if next.keyCode == 53 { return } // Escape cancels without changing the order.
                continue
            }
            let point = next.locationInWindow
            if hypot(point.x - origin.x, point.y - origin.y) >= 4 { dragging = true }
            if dragging {
                if badge == nil, let label = configuration.dragLabel, let content = window.contentView {
                    let view = NSTextField(labelWithString: "  " + label + "  ")
                    view.font = AppFont.native(size: 11)
                    view.textColor = .white; view.backgroundColor = NSColor(white: 0.16, alpha: 0.95)
                    view.drawsBackground = true; view.wantsLayer = true; view.layer?.cornerRadius = 5
                    view.frame.size = NSSize(width: min(200, view.intrinsicContentSize.width), height: 24)
                    content.addSubview(view); badge = view
                }
                if let badge, let content = window.contentView {
                    let position = content.convert(point, from: nil)
                    badge.setFrameOrigin(NSPoint(x: position.x + 12, y: position.y + (content.isFlipped ? 12 : -36)))
                    badge.displayIfNeeded()
                }
                target?.insertionAfter = nil
                target?.displayIfNeeded()
                let destination = Self.target(for: item, at: point, in: window)
                target = destination?.view
                if let target {
                    target.insertionAfter = destination?.after
                    target.displayIfNeeded()
                    if next.type == .leftMouseDragged { target.enclosingScrollView?.autoscroll(with: next) }
                }
            }
            if next.type == .leftMouseUp {
                if dragging {
                    if let target, let after = target.insertionAfter { target.configuration.drop(item, after) }
                } else if bounds.intersection(visibleRect).contains(convert(point, from: nil)) {
                    configuration.select()
                }
                return
            }
        }
    }

    private static func target(for item: ReorderItem, at point: NSPoint, in window: NSWindow) -> (view: ReorderTrackingView, after: Bool)? {
        let visible = targets.allObjects.filter {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        }
        let candidates = visible.filter {
            $0.bounds.intersection($0.visibleRect).contains($0.convert(point, from: nil))
        }
        func destination(_ view: ReorderTrackingView) -> (view: ReorderTrackingView, after: Bool) {
            let local = view.convert(point, from: nil)
            return (view, view.configuration.edge == .vertical ? local.y >= view.bounds.midY : local.x >= view.bounds.midX)
        }
        // Each space boundary belongs to the following row. Both halves of
        // the neighboring rows and the gap between them use that same line.
        if case .space = item {
            let rows = visible.filter {
                guard case .space = $0.configuration.item else { return false }
                let frame = $0.convert($0.bounds.intersection($0.visibleRect), to: nil)
                return $0.configuration.edge == .vertical && point.x >= frame.minX && point.x < frame.maxX
            }.sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
            if let index = rows.firstIndex(where: { candidates.contains($0) }) {
                let row = rows[index]
                guard row.configuration.item != item, row.configuration.accepts(item) else { return nil }
                let proposed = destination(row)
                if proposed.after, index + 1 < rows.count,
                   rows[index + 1].configuration.reorderGroup == row.configuration.reorderGroup {
                    let next = rows[index + 1]
                    guard next.configuration.item != item, next.configuration.accepts(item) else { return nil }
                    return (next, false)
                }
                return proposed
            }
            for (upper, lower) in zip(rows, rows.dropFirst()) {
                let upperFrame = upper.convert(upper.bounds, to: nil)
                let lowerFrame = lower.convert(lower.bounds, to: nil)
                if point.y <= upperFrame.minY, point.y >= lowerFrame.maxY,
                   upper.configuration.reorderGroup == lower.configuration.reorderGroup {
                    guard lower.configuration.item != item, lower.configuration.accepts(item),
                          upper.configuration.accepts(item) else { return nil }
                    return (lower, false)
                }
            }
        }
        // A tab cell takes precedence over the pane behind it, including when
        // hovering the source tab (where dropping should simply do nothing).
        if let cell = candidates.first(where: { $0.configuration.item != nil }) {
            return cell.configuration.item != item && cell.configuration.accepts(item) ? destination(cell) : nil
        }
        return candidates.filter { $0.configuration.accepts(item) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }.map(destination)
    }
}
