import AppKit
import SwiftUI

/// Explicit initial geometry avoids SwiftUI split views giving a new sibling
/// the leftover width of the previously full-size terminal host.
struct NativeSplit: NSViewRepresentable {
    @Environment(\.appTypography) private var typography
    private var styledFirst: AnyView { AnyView(first.environment(\.appTypography, typography)) }
    private var styledSecond: AnyView { AnyView(second.environment(\.appTypography, typography)) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let first: AnyView
    let second: AnyView
    let axis: SplitAxis
    var sidebar = false
    var firstHidden = false
    /// The sidebar column's width while shown; a divider drag writes it back.
    var sidebarWidth: Binding<CGFloat>?
    var initialFraction: CGFloat = 0.5
    var controlledFraction: CGFloat?
    var onDividerChange: ((CGFloat) -> Void)?
    var firstMinimumSize = PaneLayout.minimumPaneSize
    var secondMinimumSize = PaneLayout.minimumPaneSize
    var fractionChanged: ((Double) -> Void)?

    func makeNSView(context: Context) -> TerminalSplitView {
        let split = TerminalSplitView()
        split.isVertical = axis == .columns
        split.sidebar = sidebar
        if sidebar { split.dividerTint = NSColor(Chrome.palette.sidebarDivider) }
        split.initialFraction = initialFraction
        split.onDividerChange = onDividerChange
        split.applyControlledFraction(controlledFraction)
        split.firstMinimumSize = firstMinimumSize
        split.secondMinimumSize = secondMinimumSize
        split.dividerStyle = .thin
        split.delegate = split
        split.fractionChanged = fractionChanged
        let first = NSHostingView(rootView: styledFirst)
        let second = NSHostingView(rootView: styledSecond)
        first.sizingOptions = []
        second.sizingOptions = []
        // Titlebar tabs place the first pane under the traffic lights; the window already lays out around them.
        first.safeAreaRegions = []
        second.safeAreaRegions = []
        split.addArrangedSubview(sidebar ? SidebarClipView(host: first) : first)
        split.addArrangedSubview(second)
        split.onSidebarResize = sidebarWidth.map { width in { width.wrappedValue = $0 } }
        if let sidebarWidth { split.applySidebarWidth(sidebarWidth.wrappedValue) }
        split.setSidebarHidden(firstHidden)
        return split
    }

    func updateNSView(_ split: TerminalSplitView, context: Context) {
        if sidebar { split.dividerTint = NSColor(Chrome.palette.sidebarDivider) }
        split.fractionChanged = fractionChanged
        split.onDividerChange = onDividerChange
        split.onSidebarResize = sidebarWidth.map { width in { width.wrappedValue = $0 } }
        if let sidebarWidth { split.applySidebarWidth(sidebarWidth.wrappedValue) }
        if let clip = split.arrangedSubviews[0] as? SidebarClipView { clip.host.rootView = styledFirst }
        else { (split.arrangedSubviews[0] as? NSHostingView<AnyView>)?.rootView = styledFirst }
        (split.arrangedSubviews[1] as? NSHostingView<AnyView>)?.rootView = styledSecond
        if split.firstMinimumSize != firstMinimumSize || split.secondMinimumSize != secondMinimumSize {
            split.firstMinimumSize = firstMinimumSize
            split.secondMinimumSize = secondMinimumSize
            split.resizeSubviews(withOldSize: split.bounds.size)
        }
        split.setSidebarHidden(firstHidden, animated: !reduceMotion)
        split.applyControlledFraction(controlledFraction)
    }
}

final class TerminalSplitView: NSSplitView, NSSplitViewDelegate {
    // The window and split delegate supply the viewport and pane minima.
    // The default "no intrinsic metric" makes SwiftUI repeatedly fit the
    // entire hosted subtree with Auto Layout while its chat content scrolls.
    override var intrinsicContentSize: NSSize { .zero }
    var sidebar = false
    var initialFraction: CGFloat = 0.5
    var onDividerChange: ((CGFloat) -> Void)?
    /// A divider drag's new sidebar width.
    var onSidebarResize: ((CGFloat) -> Void)?
    private var controlledFraction: CGFloat?
    private var draggingDivider = false
    var firstMinimumSize = PaneLayout.minimumPaneSize
    var secondMinimumSize = PaneLayout.minimumPaneSize
    var fractionChanged: ((Double) -> Void)?
    private var positioned = false
    private(set) var sidebarHidden = false
    private var sidebarWidth: CGFloat = 264
    private var sidebarAnimation: Task<Void, Never>?
    private var animatedWidth: CGFloat?
    var sidebarAnimating: Bool { animatedWidth != nil }
    override var dividerThickness: CGFloat { sidebarHidden ? 0 : super.dividerThickness }
    var dividerTint = NSColor(white: 0.13, alpha: 1) {
        didSet { if dividerTint != oldValue { needsDisplay = true } }
    }
    override var dividerColor: NSColor { dividerTint }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if sidebar, draggingDivider {
            userDidResize()
            if !sidebarHidden, !sidebarAnimating, arrangedSubviews.count == 2, let onSidebarResize {
                sidebarWidth = arrangedSubviews[0].frame.width
                let width = sidebarWidth
                DispatchQueue.main.async { onSidebarResize(width) }
            }
        }
        guard !sidebar, positioned, arrangedSubviews.count == 2, let fractionChanged else { return }
        let length = (isVertical ? bounds.width : bounds.height) - dividerThickness
        guard length > 0 else { return }
        let fraction = (isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height) / length
        DispatchQueue.main.async { fractionChanged(fraction) }
    }

    /// Takes the sidebar width chosen elsewhere (the floating panel's); a shown column moves to it at once.
    func applySidebarWidth(_ width: CGFloat) {
        guard sidebar, !draggingDivider, width != sidebarWidth else { return }
        sidebarWidth = width
        guard positioned, !sidebarHidden, !sidebarAnimating, arrangedSubviews.count == 2 else { return }
        setPosition(clamped(width, length: bounds.width - dividerThickness), ofDividerAt: 0)
    }

    func applyControlledFraction(_ fraction: CGFloat?) {
        guard !draggingDivider, let fraction, fraction != controlledFraction else { return }
        controlledFraction = fraction
        initialFraction = fraction
        let length = (isVertical ? bounds.width : bounds.height) - dividerThickness
        if length > 0, arrangedSubviews.count == 2 { setPosition(clamped(length * fraction, length: length), ofDividerAt: 0) }
    }

    override func mouseDown(with event: NSEvent) {
        if !sidebar, arrangedSubviews.count == 2, let window {
            let first = arrangedSubviews[0].frame, second = arrangedSubviews[1].frame
            let length = (isVertical ? bounds.width : bounds.height) - dividerThickness
            let direction: CGFloat = isVertical || first.minY < second.minY ? 1 : -1
            let start = isVertical ? first.width : first.height
            let boundary = isVertical ? first.maxX : (direction > 0 ? first.maxY : first.minY)
            let point = convert(event.locationInWindow, from: nil)
            let origin = isVertical ? point.x : point.y
            if length > 0, (origin - boundary) * direction >= 0,
                (origin - boundary) * direction <= dividerThickness {
                draggingDivider = true
                defer { draggingDivider = false }
                if event.clickCount == 2 {
                    setPosition(clamped(length / 2, length: length), ofDividerAt: 0)
                    userDidResize()
                    return
                }
                for next in sequence(state: (), next: { _ in
                    window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown])
                }) {
                    if next.type == .keyDown {
                        if next.keyCode == 53 {
                            setPosition(start, ofDividerAt: 0)
                            return
                        }
                        continue
                    }
                    let point = convert(next.locationInWindow, from: nil)
                    let position = start + direction * ((isVertical ? point.x : point.y) - origin)
                    setPosition(clamped(position, length: length), ofDividerAt: 0)
                    if next.type == .leftMouseUp { userDidResize(); return }
                }
                return
            }
        }
        draggingDivider = true
        super.mouseDown(with: event)
        draggingDivider = false
        userDidResize()
    }

    func userDidResize() {
        guard arrangedSubviews.count == 2 else { return }
        let length = (isVertical ? bounds.width : bounds.height) - dividerThickness
        guard length > 0 else { return }
        let first = arrangedSubviews[0].frame.size
        onDividerChange?((isVertical ? first.width : first.height) / length)
    }

    func setSidebarHidden(_ hidden: Bool, animated: Bool = false) {
        guard sidebar, arrangedSubviews.count == 2 else { return }
        if hidden == sidebarHidden {
            if !animated, sidebarAnimating {
                sidebarAnimation?.cancel(); animatedWidth = nil
                if !hidden { arrangedSubviews[0].setFrameSize(NSSize(width: sidebarWidth, height: bounds.height)) }
                arrangedSubviews[0].isHidden = hidden
                resizeSubviews(withOldSize: bounds.size)
            }
            return
        }
        let start = arrangedSubviews[0].frame.width
        if hidden, !sidebarAnimating, start > 0 { sidebarWidth = start }
        sidebarAnimation?.cancel()
        sidebarHidden = hidden
        // Divider layers have their own AppKit layout; resizing our two hosts
        // alone leaves the old divider composited over the expanded terminal.
        needsLayout = true
        let target = hidden ? 0 : clamped(sidebarWidth, length: bounds.width - super.dividerThickness)
        guard animated, window != nil, bounds.width > 0 else {
            animatedWidth = nil
            arrangedSubviews[0].isHidden = hidden
            resizeSubviews(withOldSize: bounds.size)
            return
        }
        arrangedSubviews[0].isHidden = false
        animatedWidth = start
        sidebarAnimation = Task { @MainActor [weak self] in
            let began = ProcessInfo.processInfo.systemUptime
            while let self, !Task.isCancelled {
                let fraction = min(1, (ProcessInfo.processInfo.systemUptime - began) / InterfaceMotion.sidebarDuration)
                self.animatedWidth = start + (target - start) * (1 - pow(1 - fraction, 3))
                self.resizeSubviews(withOldSize: self.bounds.size)
                if fraction >= 1 {
                    self.animatedWidth = nil
                    self.arrangedSubviews[0].isHidden = hidden
                    self.resizeSubviews(withOldSize: self.bounds.size)
                    break
                }
                do { try await Task.sleep(for: .milliseconds(8)) } catch { break }
            }
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard arrangedSubviews.count == 2 else { super.resizeSubviews(withOldSize: oldSize); return }
        // Manual child-frame changes leave NSSplitView's cached divider on
        // screen unless its own backing store is invalidated as well.
        needsDisplay = true
        if let clip = arrangedSubviews[0] as? SidebarClipView {
            clip.pinnedWidth = sidebarHidden || sidebarAnimating ? clamped(sidebarWidth, length: bounds.width - super.dividerThickness) : nil
        }
        if let width = animatedWidth {
            let position = min(max(0, width), bounds.width)
            arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: position, height: bounds.height)
            arrangedSubviews[1].frame = NSRect(x: position + dividerThickness, y: 0,
                width: max(0, bounds.width - position - dividerThickness), height: bounds.height)
            return
        }
        if sidebarHidden {
            arrangedSubviews[0].frame = .zero
            arrangedSubviews[1].frame = bounds
            return
        }
        let oldLength = (isVertical ? oldSize.width : oldSize.height) - dividerThickness
        let oldFirst = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
        let length = (isVertical ? bounds.width : bounds.height) - dividerThickness
        guard length > 0 else { return }
        let fraction = positioned && oldLength > 0 ? oldFirst / oldLength : initialFraction
        let position = sidebar ? (positioned && oldFirst > 0 ? oldFirst : sidebarWidth) : length * fraction
        super.resizeSubviews(withOldSize: oldSize)
        setPosition(clamped(position, length: length), ofDividerAt: 0)
        positioned = true
    }

    private func clamped(_ value: CGFloat, length: CGFloat) -> CGFloat {
        guard length > 0 else { return 0 }
        let minimum = sidebar ? max(200, firstMinimumSize.width) : (isVertical ? firstMinimumSize.width : firstMinimumSize.height)
        let secondMinimum = sidebar ? max(min(420, length / 2), secondMinimumSize.width)
            : (isVertical ? secondMinimumSize.width : secondMinimumSize.height)
        // Layout can update before the window grows to its new minimum size.
        // Keep temporary frames valid until that resize reaches this subtree.
        guard length >= minimum + secondMinimum else { return length * minimum / (minimum + secondMinimum) }
        let maximum = sidebar ? min(max(340, minimum * 1.7), length - secondMinimum) : length - secondMinimum
        return min(maximum, max(minimum, value))
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        clamped(proposedPosition, length: (isVertical ? bounds.width : bounds.height) - dividerThickness)
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { sidebarHidden }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}

/// Animate the visible viewport, keeping the sidebar's text layout at its full
/// width. Real divider drags still resize the content normally.
final class SidebarClipView: NSView {
    let host: NSHostingView<AnyView>
    var pinnedWidth: CGFloat?
    init(host: NSHostingView<AnyView>) {
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionContent()
    }
    override func layout() { super.layout(); positionContent() }
    private func positionContent() {
        let width = pinnedWidth ?? bounds.width
        host.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }
}
