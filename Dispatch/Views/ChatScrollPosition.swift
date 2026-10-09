import AppKit
import SwiftUI
import CryptoKit

/// SwiftUI's item ID gets us to a row; this bridge retains the position *within*
/// that row when earlier history is inserted or a chat view is recreated.
@MainActor
final class ChatScrollPosition {
    struct Anchor: Equatable { let id: String; let offset: CGFloat }
    private final class WeakMarker {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
    private var markers: [String: WeakMarker] = [:]
    private let diagnosticID = UUID()
    private let diagnosticStarted = ProcessInfo.processInfo.systemUptime
    private lazy var diagnosticKey = SymmetricKey(size: .bits256)
    private var diagnosticEvents: [String: Int] = [:]
    private var lastDiagnostic = -Double.infinity
    private var diagnosticWasVisible: Bool?
    private var diagnosticCorrection: ChatViewportTrace.Correction?
    var diagnosticState: (() -> ChatViewportTrace.Transcript?)?
    /// Tests can inject a private sink; production checks the setting at each
    /// sample so already-mounted conversations respond to the checkbox live.
    var diagnosticSink: ((ChatViewportTrace.Sample) -> Void)?
    /// Row positions and categories for sampled marker IDs; set by the view.
    var diagnosticRows: ((Set<String>) -> [String: ChatViewportTrace.RowInfo])?
    /// Latest SwiftUI scroll geometry, reported only while diagnostics record.
    var swiftUIScroll: ChatViewportTrace.SwiftUIScroll?
    private var attachedAt: TimeInterval?
    private var mountCheckGeneration = UUID()
    private var mountBlank = false
    private var firstScrollPending = false
    private weak var scroll: NSScrollView?
    private(set) var scrollbar: ChatScrollbar?
    var scrollbarColor = NSColor(Chrome.muted) { didSet { scrollbar?.thumb.color = scrollbarColor } }
    private var observation: NSObjectProtocol?
    private var documentObservation: NSObjectProtocol?
    private var frameObservation: NSObjectProtocol?
    private var liveScrollObservations: [NSObjectProtocol] = []
    private var wheelMonitor: Any?
    private var viewportTimer: Timer?
    private var visibilityObservations: [NSObjectProtocol] = []
    private var wakeObservation: NSObjectProtocol?
    private var emptyViewportChecks = 0
    private var emptyViewportSince: TimeInterval?
    private var lastEmptyViewportCheck = -Double.infinity
    private var lastViewportRebuild = -Double.infinity
    private var lastGeometryChange = ProcessInfo.processInfo.systemUptime
    /// A live row arriving at the followed bottom glides there with its fade instead of jumping.
    static let arrivalGlide: TimeInterval = 0.22
    private var arrivalExpectedAt = -Double.infinity
    private var glide: (from: CGFloat, start: TimeInterval, link: CADisplayLink)?
    /// SwiftUI's item scroll would land before the glide starts; hold it while one is pending or running.
    var glidesToBottom: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return glide != nil || now - arrivalExpectedAt < 0.3 || now - rowExpectedAt < 0.3
    }
    private var rowExpectedAt = -Double.infinity
    var hasContent: (() -> Bool)?
    var recoverViewport: ((Anchor?, Bool) -> Void)?
    private var pending: Anchor?
    private var previousDocumentY: CGFloat?
    private var prependGeometry: (height: CGFloat, y: CGFloat)?
    private var prependFallbacks: [(anchor: Anchor, documentY: CGFloat)] = []
    private var restoredPending = false
    private var realizationAttempts = 0
    private var adjustmentScheduled = false
    private var settlingRevision = 0
    private var adjusting = false
    private var layingOutPrepend = false
    private(set) var interactionRevision = 0
    private(set) var isTrackingScroller = false
    private var isLiveScrolling = false
    private var lastWheelTime = -Double.infinity
    private var afterTracking: [() -> Void] = []
    var userScrolled: (() -> Void)?
    var realizeAnchor: ((String) -> Void)?
    var followsBottom: (() -> Bool)?
    private(set) var saved: Anchor?
    /// Returns true only when the coordinator actually starts a request.
    var loadEarlier: ((Bool) -> Bool)?
    private var automaticHistoryLoadsRemaining = 0
    var positionChanged: ((Anchor) -> Void)?
    var isRestoring: Bool { pending != nil }
    private var earlierVelocity: CGFloat = 0
    private var earlierReadLatency: TimeInterval = 0.1
    private var velocityTime: TimeInterval?
    var earlierPrefetchDistance: CGFloat {
        let height = max(400, scroll?.contentView.bounds.height ?? 0)
        let recent = velocityTime.map { ProcessInfo.processInfo.systemUptime - $0 < 0.3 } ?? false
        let lead = recent ? earlierVelocity * max(0.35, earlierReadLatency * 3) : 0
        // Start loading six screens ahead without increasing insertion size.
        return max(height * 6, min(height * 12, lead))
    }
    func observedHistoryRead(seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        earlierReadLatency = earlierReadLatency * 0.7 + min(seconds, 2) * 0.3
    }
    func beginOpeningHistoryPreload() {
        // Build a scroll reserve after the latest messages are displayed. Even
        // tool-only history must not turn opening a view into an unlimited read.
        automaticHistoryLoadsRemaining = 4
        geometryChanged()
    }
    func historyLoadFinished(madeProgress: Bool) {
        if !madeProgress { automaticHistoryLoadsRemaining = 0 }
        geometryChanged()
    }
    func prefetchEarlier() {
        guard automaticHistoryLoadsRemaining > 0, !isRestoring, !adjusting,
              let scroll, scroll.window?.isVisible == true,
              scroll.contentView.bounds.minY < earlierPrefetchDistance,
              let loadEarlier else { return }
        // Reserve before calling out: publishing loading state can cause layout
        // callbacks. Readiness/restoration guards do not spend the allowance.
        automaticHistoryLoadsRemaining -= 1
        if !loadEarlier(false) { automaticHistoryLoadsRemaining += 1 }
    }
    private var needsAnchorRealized: Bool {
        guard let pending else { return false }
        return markers[pending.id]?.view?.window == nil
    }

    func forwardWheel(_ event: NSEvent) { scroll?.scrollWheel(with: event) }

    func isAtBottom(tolerance: CGFloat) -> Bool? {
        guard let scroll, let document = scroll.documentView else { return nil }
        return document.bounds.maxY - scroll.contentView.bounds.maxY <= tolerance
    }

    func register(_ view: NSView, id: String) {
        if markers[id]?.view !== view { markers[id] = WeakMarker(view) }
        if let scroll = view.enclosingScrollView { attach(scroll); scroll.contentView.postsBoundsChangedNotifications = true }
        geometryChanged()
    }
    func registerViewport(_ view: NSView) {
        if let scroll = view.enclosingScrollView { attach(scroll) }
    }
    func unregister(_ view: NSView, id: String) {
        if markers[id]?.view === view { markers.removeValue(forKey: id) }
        if pending?.id == id { geometryChanged() }
    }
    private func attach(_ value: NSScrollView) {
        guard scroll !== value else { return }
        if let observation { NotificationCenter.default.removeObserver(observation) }
        if let documentObservation { NotificationCenter.default.removeObserver(documentObservation) }
        if let frameObservation { NotificationCenter.default.removeObserver(frameObservation) }
        liveScrollObservations.forEach { NotificationCenter.default.removeObserver($0) }
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        stopViewportChecks()
        scroll = value
        recordDiagnostic(.attached, force: true)
        scrollbar?.removeFromSuperview()
        // A separate overlay owns visibility. AppKit's automatic overlay would
        // reveal itself on programmatic scrolling as well as user input.
        value.hasVerticalScroller = false
        let bar = ChatScrollbar()
        scrollbar = bar
        bar.thumb.color = scrollbarColor
        // SwiftUI manages the scroll view's subview layout, so neither springs
        // nor constraints reliably place an added overlay. Track its actual
        // viewport explicitly, including resize events without new messages.
        value.addSubview(bar)
        value.postsFrameChangedNotifications = true
        frameObservation = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: value, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScrollbar() }
        }
        bar.beganDragging = { [weak self] in
            self?.isTrackingScroller = true
            self?.beginUserScroll()
        }
        bar.endedDragging = { [weak self] in self?.finishScrollerTracking() }
        bar.moved = { [weak self] fraction in
            guard let self, let scroll = self.scroll, let document = scroll.documentView else { return }
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: fraction * maximum))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        bar.wheel = { [weak value] event in value?.scrollWheel(with: event) }
        updateScrollbar()
        value.contentView.postsBoundsChangedNotifications = true
        observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: value.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
        if let document = value.documentView {
            document.postsFrameChangedNotifications = true
            documentObservation = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.geometryChanged() }
            }
        }
        liveScrollObservations = [
            NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: value, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveScrolling = true
                    self?.beginUserScroll()
                }
            },
            NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: value, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveScrolling = false
                    self?.finishScrollerTracking()
                }
            }
        ]
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            self?.handleScrollEvent(event)
            return event
        }
        viewportTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.checkViewport() }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSApplication.didBecomeActiveNotification] {
            visibilityObservations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Visibility notifications can arrive during AppKit layout.
                DispatchQueue.main.async { self?.checkViewport(redraw: true) }
            })
        }
        wakeObservation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.checkViewport(redraw: true) }
        }
        scheduleMountChecks()
    }

    /// Check whether rows are visible soon after mounting. The watchdog needs
    /// two intervals before it reports a blank; a reader often scrolls sooner.
    private func scheduleMountChecks() {
        attachedAt = ProcessInfo.processInfo.systemUptime
        mountBlank = false; firstScrollPending = true
        let generation = UUID()
        mountCheckGeneration = generation
        let interaction = interactionRevision
        for delay in [0.15, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.mountCheckGeneration == generation else { return }
                self.mountCheck(rebuild: delay == 0.4 && self.interactionRevision == interaction)
            }
        }
    }
    private func mountCheck(rebuild: Bool) {
        guard let scroll, scroll.window?.isVisible == true, !scroll.isHiddenOrHasHiddenAncestor,
              hasContent?() == true else { return }
        if visibleAnchor() == nil {
            mountBlank = true
            recordDiagnostic(.mountBlank, force: true)
            // A remounted lazy stack can scroll to its destination yet keep only
            // hidden rows from its first layout until the next wheel event. An
            // item scroll to where it already is changes nothing; rebuilding
            // the stack does. Don't leave the reader on a blank tab meanwhile.
            // A pending restoration first realizes its row through the watchdog.
            guard rebuild, pending == nil, !isLiveScrolling, !isTrackingScroller, !adjusting else { return }
            lastViewportRebuild = ProcessInfo.processInfo.systemUptime
            recordDiagnostic(.rebuildRequested, force: true)
            recoverViewport?(saved, true)
        } else {
            noteMountRecovery()
            recordDiagnostic(.mountCheck, force: true)
        }
    }
    /// The first visible row after a post-mount blank, whatever restored it;
    /// the sample's wheel age and interaction tell whether it was the reader.
    private func noteMountRecovery() {
        guard mountBlank, visibleAnchor() != nil else { return }
        mountBlank = false
        recordDiagnostic(.mountRecovered, force: true)
    }

    /// Validate the mounted viewport independently of new messages. A lazy
    /// stack can retain its document height after discarding every visible row.
    /// First ask it to realize the saved row; rebuild only if that stays empty.
    func checkViewport(redraw: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        recordDiagnostic(.watchdog, force: true, now: now)
        guard let scroll, let document = scroll.documentView,
              scroll.window?.isVisible == true, scroll.window?.isMiniaturized == false,
              !scroll.isHiddenOrHasHiddenAncestor, scroll.contentView.bounds.width > 1,
              scroll.contentView.bounds.height > 1, hasContent?() == true,
              !isLiveScrolling, !isTrackingScroller, now - lastWheelTime > 0.3,
              !adjusting else {
            emptyViewportSince = nil; emptyViewportChecks = 0
            return
        }
        if let anchor = visibleAnchor() {
            if emptyViewportSince != nil { recordDiagnostic(.recovered, force: true, now: now) }
            noteMountRecovery()
            emptyViewportSince = nil; emptyViewportChecks = 0; lastEmptyViewportCheck = -Double.infinity
            saved = anchor
            // Invalidate only the visible pixels, not the full history. This
            // also refreshes stale backing layers after an idle or occluded gap.
            if redraw || now - lastGeometryChange > 1 { redrawViewport(scroll, document: document) }
            return
        }
        if emptyViewportSince == nil {
            emptyViewportSince = now
            recordDiagnostic(.blank, force: true, now: now)
        }
        // Streaming and marker updates can keep layout busy indefinitely even
        // when no rows are realized. Bound the grace period by blank duration,
        // rather than restarting it on every geometry notification.
        let stalled = now - (emptyViewportSince ?? now) >= 2
        guard stalled || (!adjustmentScheduled && now - lastGeometryChange > 0.75
                          && (pending == nil || realizationAttempts >= 3 || now - lastGeometryChange > 2)),
              now - lastEmptyViewportCheck > 0.75 else { return }
        lastEmptyViewportCheck = now
        emptyViewportChecks += 1
        redrawViewport(scroll, document: document)
        guard emptyViewportChecks >= 2 else { return }
        let rebuild = emptyViewportChecks >= 3 && now - lastViewportRebuild > 30
        if rebuild { lastViewportRebuild = now; emptyViewportChecks = 0 }
        recordDiagnostic(rebuild ? .rebuildRequested : .recoveryRequested, force: true, now: now)
        recoverViewport?(pending ?? saved, rebuild)
    }

    private func redrawViewport(_ scroll: NSScrollView, document: NSView) {
        recordDiagnostic(.redraw)
        scroll.contentView.needsDisplay = true
        document.setNeedsDisplay(document.convert(scroll.contentView.bounds, from: scroll.contentView))
    }

    private func stopViewportChecks() {
        viewportTimer?.invalidate(); viewportTimer = nil
        visibilityObservations.forEach { NotificationCenter.default.removeObserver($0) }
        visibilityObservations = []
        if let wakeObservation { NSWorkspace.shared.notificationCenter.removeObserver(wakeObservation) }
        wakeObservation = nil; emptyViewportSince = nil; emptyViewportChecks = 0; lastEmptyViewportCheck = -Double.infinity
    }
    func handleScrollEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp { finishScrollerTracking(); return }
        guard let scroll, event.window === scroll.window else { return }
        if event.type == .keyDown {
            // Keyboard navigation needs the same fresh reserve as wheel/drag
            // input. Editing the composer or a nested output must not preload
            // or cancel transcript following.
            guard let responder = scroll.window?.firstResponder as? NSView,
                  responder === scroll || responder.enclosingScrollView === scroll else { return }
            switch event.specialKey {
            case .upArrow, .pageUp, .home:
                beginUserScroll()
                if scroll.contentView.bounds.minY < earlierPrefetchDistance { _ = loadEarlier?(true) }
            case .downArrow, .pageDown, .end:
                beginUserScroll()
            default: break
            }
            return
        }
        let point = scroll.convert(event.locationInWindow, from: nil)
        guard scroll.bounds.contains(point) else { return }
        if event.type == .leftMouseDown {
            if let bar = scrollbar, bar.canScroll, bar.frame.contains(point) {
                isTrackingScroller = true; beginUserScroll()
            }
        } else if event.type == .scrollWheel && event.scrollingDeltaY != 0 {
            // A tool's nested code/output scroller does not move the transcript.
            if let hit = scroll.contentView.hitTest(point), hit.enclosingScrollView !== scroll { return }
            userWillScroll(deltaY: event.scrollingDeltaY)
        }
    }
    func userWillScroll(deltaY: CGFloat) {
        guard deltaY != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = velocityTime.map { now - $0 } ?? 1.0 / 60
        let speed = max(0, deltaY) / max(1.0 / 240, interval)
        earlierVelocity = interval > 0.3 ? speed : max(speed, earlierVelocity * 0.8)
        velocityTime = now
        lastWheelTime = now
        beginUserScroll()
        if deltaY > 0 {
            if let scroll, scroll.contentView.bounds.minY < earlierPrefetchDistance { _ = loadEarlier?(true) }
        }
    }
    private func beginUserScroll() {
        // The first scroll after mounting shows what the reader was looking at.
        recordDiagnostic(.userScroll, force: firstScrollPending || mountBlank)
        firstScrollPending = false
        emptyViewportChecks = 0; lastEmptyViewportCheck = -Double.infinity
        scrollbar?.reveal()
        interactionRevision &+= 1
        automaticHistoryLoadsRemaining = 4
        // Finish any correction that layout already made possible, then give
        // subsequent movement to the reader. No queued item scroll may undo it.
        restorePending()
        cancelPreservation()
        cancelGlide()
        userScrolled?()
    }
    func performAfterScrolling(_ action: @escaping () -> Void) {
        // Thumb dragging uses a fraction of document height, so changing that
        // height changes its destination. Wheel scrolling can keep its visible
        // pixel anchor while history is prepended, without waiting for release.
        if isTrackingScroller { afterTracking.append(action) }
        else { action() }
    }
    private func finishScrollerTracking() {
        isTrackingScroller = false
        applyDeferredHistory()
    }
    private func applyDeferredHistory() {
        guard !isTrackingScroller else { return }
        let actions = afterTracking; afterTracking = []
        actions.forEach { $0() }
    }
    func visibleAnchor(retaining ids: Set<String>? = nil) -> Anchor? {
        guard let scroll, let document = scroll.documentView else { return nil }
        let viewport = scroll.contentView.bounds
        var first: Anchor?
        for (id, marker) in markers {
            if let ids, !ids.contains(id) { continue }
            guard let view = marker.view, view.window != nil, view.enclosingScrollView === scroll else { continue }
            let frame = view.convert(view.bounds, to: document)
            guard frame.width > 1, frame.height > 1, !view.isHiddenOrHasHiddenAncestor else { continue }
            guard frame.maxY > viewport.minY + 1, frame.minY < viewport.maxY else { continue }
            let offset = frame.minY - viewport.minY
            if first == nil || offset < first!.offset { first = Anchor(id: id, offset: offset) }
        }
        return first
    }
    func preserveForPrepend(retaining ids: Set<String>? = nil) {
        pending = visibleAnchor(retaining: ids)
        prependFallbacks = []
        realizationAttempts = 0
        restoredPending = false
        if let pending, let scroll, let document = scroll.documentView, let marker = markers[pending.id]?.view {
            saved = pending; previousDocumentY = marker.convert(marker.bounds, to: document).minY
            prependGeometry = isLiveScrolling || ProcessInfo.processInfo.systemUptime - lastWheelTime < 0.2
                ? (document.bounds.height, scroll.contentView.bounds.minY) : nil
            if prependGeometry != nil {
                let viewport = scroll.contentView.bounds
                prependFallbacks = markers.compactMap { id, marker -> (anchor: Anchor, documentY: CGFloat)? in
                    guard id != pending.id, ids?.contains(id) != false,
                          let view = marker.view, view.window != nil, view.enclosingScrollView === scroll,
                          !view.isHiddenOrHasHiddenAncestor else { return nil }
                    let frame = view.convert(view.bounds, to: document)
                    guard frame.width > 1, frame.height > 1, frame.maxY > viewport.minY + 1,
                          frame.minY < viewport.maxY else { return nil }
                    return (Anchor(id: id, offset: frame.minY - viewport.minY), frame.minY)
                }.sorted { $0.anchor.offset < $1.anchor.offset }
            }
        }
    }
    func restoreOnAppearance() { pending = saved; realizationAttempts = 0; previousDocumentY = nil; prependGeometry = nil; prependFallbacks = []; restoredPending = false; geometryChanged() }
    func restoreAfterPrepend() {
        if #available(macOS 15, *), prependGeometry == nil {
            // The transcript disables SwiftUI's automatic offset adjustment.
            // Restore from marker geometry as lazy layout settles; forcing the
            // window to lay out here blocks scrolling during history insertion.
            requestRealization()
            geometryChanged()
            return
        }
        // During a gesture, realize and correct native geometry in this layout
        // pass. A deferred SwiftUI item scroll can otherwise land after the next
        // wheel step and erase it. Older systems also require this path because
        // automatic offset adjustment cannot be disabled there.
        guard !layingOutPrepend else { return }
        layingOutPrepend = true
        defer { layingOutPrepend = false }
        if prependGeometry == nil {
            requestRealization()
            geometryChanged()
            return
        }
        scroll?.window?.contentView?.layoutSubtreeIfNeeded()
        // Decide after layout: a marker may be mounted before the prepend but
        // discarded when the lazy stack replaces its indices. Avoid queuing an
        // item scroll when the pixel anchor can already be restored directly.
        for _ in 0..<3 where needsAnchorRealized {
            requestRealization()
            scroll?.window?.contentView?.layoutSubtreeIfNeeded()
        }
        geometryChanged()
    }
    private func requestRealization() {
        // Lazy layout can discard the first item lookup while replacing its
        // indices. Retry only while the retained row is absent, with a fixed
        // limit so a removed row cannot cause an endless layout cycle.
        guard let id = pending?.id, realizationAttempts < 3 else { return }
        realizationAttempts += 1
        recordDiagnostic(.restoreRequested)
        // The native estimate treats the whole height change as prepended rows,
        // but lazy layout also re-estimates unrealized rows, so the document can
        // even shrink. If two estimates leave the retained row unrealized, the
        // final attempt realizes it by identity instead of leaving the clamped
        // estimate (often the bottom) in place; restorePending then refines it.
        if let prependGeometry, realizationAttempts < 3, let scroll, let document = scroll.documentView {
            // Realize the retained area with a native offset, then let its
            // marker refine the estimate. Queuing a SwiftUI item scroll here
            // can snap to the row's top after the next wheel event has arrived.
            let y = prependGeometry.y + document.bounds.height - prependGeometry.height
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let destination = min(max(0, y), maximum)
            recordCorrection(from: scroll.contentView.bounds.minY, to: destination)
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: destination))
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        realizeAnchor?(id)
    }
    func restore(_ anchor: Anchor?) { saved = anchor; restoreOnAppearance() }
    func clear() { saved = nil; automaticHistoryLoadsRemaining = 0; cancelPreservation() }
    func cancelPreservation() { pending = nil; realizationAttempts = 0; previousDocumentY = nil; prependGeometry = nil; prependFallbacks = []; restoredPending = false }
    func disconnect() {
        recordDiagnostic(.disconnected, force: true)
        cancelGlide(); arrivalExpectedAt = -Double.infinity; rowExpectedAt = -Double.infinity
        diagnosticState = nil; diagnosticRows = nil; swiftUIScroll = nil
        mountCheckGeneration = UUID(); mountBlank = false; firstScrollPending = false; attachedAt = nil
        stopViewportChecks(); hasContent = nil; recoverViewport = nil
        automaticHistoryLoadsRemaining = 0; loadEarlier = nil
        saved = visibleAnchor() ?? saved
        if let observation { NotificationCenter.default.removeObserver(observation) }
        if let documentObservation { NotificationCenter.default.removeObserver(documentObservation) }
        if let frameObservation { NotificationCenter.default.removeObserver(frameObservation) }
        liveScrollObservations.forEach { NotificationCenter.default.removeObserver($0) }
        liveScrollObservations = []
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        scrollbar?.removeFromSuperview(); scrollbar = nil
        observation = nil; wheelMonitor = nil; scroll = nil; markers.removeAll()
        documentObservation = nil; frameObservation = nil; realizeAnchor = nil; followsBottom = nil
        isLiveScrolling = false; lastWheelTime = -Double.infinity
        finishScrollerTracking()
    }
    func jumpToLatest() {
        cancelPreservation(); cancelGlide(); saved = nil
        pinToBottom()
    }
    /// A live row without an entrance (in a burst): layout pins it at once, as a glide would, so no later item
    /// scroll adds another pass. Reduce Motion keeps the item scroll, as for any arrival.
    func expectRow() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        rowExpectedAt = ProcessInfo.processInfo.systemUptime
    }
    /// The session is inserting a live row while the reader follows the bottom.
    func expectArrival() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        arrivalExpectedAt = ProcessInfo.processInfo.systemUptime
    }
    /// The document's padding below its "bottom" marker. Item scrolling to that marker leaves the padding under the
    /// viewport, so following stops there too: aiming at the document's end put a streamed reply that many points
    /// too high for a frame, until the next item scroll brought it back down.
    var bottomPadding: CGFloat = 0
    /// The scroll offset that shows the "bottom" marker's edge at the viewport's, as item scrolling to it does.
    private func bottomOffset(_ scroll: NSScrollView, _ document: NSView) -> CGFloat {
        max(0, document.bounds.maxY - bottomPadding - scroll.contentView.bounds.height)
    }
    private func pinToBottom() {
        guard !adjusting else { return }
        guard let scroll, let document = scroll.documentView else { return }
        let destination = bottomOffset(scroll, document)
        guard abs(destination - scroll.contentView.bounds.minY) > 0.25 else { return }
        // Each glide frame re-reads the bottom, so later growth joins the running glide.
        if glide != nil { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - arrivalExpectedAt < 0.3, destination > scroll.contentView.bounds.minY, scroll.window?.isVisible == true {
            arrivalExpectedAt = -Double.infinity
            // One step per displayed frame, in the display cycle that SwiftUI's arrival fade updates in. A timer
            // out of phase with it, or faster than the display, scrolls and lays out the transcript again.
            let link = scroll.displayLink(target: GlideStep { [weak self] in self?.glideFrame() }, selector: #selector(GlideStep.step))
            link.add(to: .main, forMode: .common)
            glide = (scroll.contentView.bounds.minY, now, link)
            return
        }
        adjusting = true
        defer { adjusting = false }
        recordCorrection(from: scroll.contentView.bounds.minY, to: destination)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: destination))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func glideFrame() {
        guard let glide, let scroll, let document = scroll.documentView, pending == nil, followsBottom?() == true else {
            cancelGlide(); return
        }
        let progress = min(1, (ProcessInfo.processInfo.systemUptime - glide.start) / Self.arrivalGlide)
        let eased = 1 - pow(1 - progress, 3)
        let destination = bottomOffset(scroll, document)
        let y = glide.from + (destination - glide.from) * eased
        if abs(y - scroll.contentView.bounds.minY) > 0.25 {
            adjusting = true
            recordCorrection(from: scroll.contentView.bounds.minY, to: y)
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            adjusting = false
        }
        if progress >= 1 { cancelGlide() }
    }
    private func cancelGlide() {
        glide?.link.invalidate(); glide = nil
    }
    private func updateScrollbar() {
        guard let scroll, let document = scroll.documentView else { return }
        if let bar = scrollbar {
            let frame = NSRect(x: scroll.bounds.maxX - 14, y: scroll.bounds.minY, width: 14, height: scroll.bounds.height)
            if bar.frame != frame { bar.frame = frame }
            if bar.thumb.frame != bar.bounds { bar.thumb.frame = bar.bounds }
            bar.update(total: document.bounds.height, visible: scroll.contentView.bounds.height,
                       offset: scroll.contentView.bounds.minY)
        }
    }
    private func scrolled() {
        recordDiagnostic(.scrolled)
        updateScrollbar()
        guard scroll != nil else { return }
        noteMountRecovery()
        if pending != nil {
            if !adjusting { geometryChanged() }
            return
        }
        saved = visibleAnchor() ?? saved
        if let saved { positionChanged?(saved) }
        prefetchEarlier()
    }
    func geometryChanged() {
        recordDiagnostic(.geometry)
        lastGeometryChange = ProcessInfo.processInfo.systemUptime
        updateScrollbar()
        // Item scrolling can precede a streamed row's final measured height.
        // Follow the document's actual bottom through subsequent layout passes.
        if pending == nil && followsBottom?() == true { pinToBottom() }
        // Correct during layout/bounds notifications, before painting. SwiftUI
        // may subsequently finish its item scroll; retain the anchor through a
        // quiet layout cycle so that final adjustment cannot erase the offset.
        settlingRevision += 1
        restorePending()
        guard !adjustmentScheduled else { return }
        adjustmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restorePending()
            if self.needsAnchorRealized { self.requestRealization() }
            let revision = self.settlingRevision
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.adjustmentScheduled = false
                if self.settlingRevision != revision { self.geometryChanged(); return }
                if self.pending != nil && self.restoredPending {
                    self.saved = self.visibleAnchor() ?? self.saved
                    self.pending = nil
                } else if self.pending == nil { self.saved = self.visibleAnchor() ?? self.saved }
                if let saved = self.saved { self.positionChanged?(saved) }
                // Requests suppressed during restoration need a fresh check,
                // including when no new wheel event follows the insertion.
                self.prefetchEarlier()
            }
        }
    }
    private func restorePending() {
        // Estimated lazy-stack heights can temporarily put the first retained
        // row just outside the realized range. Another row from that same
        // viewport provides an equally exact pixel anchor without an item jump.
        if let pending, markers[pending.id]?.view?.window == nil,
           let fallback = prependFallbacks.first(where: { markers[$0.anchor.id]?.view?.window != nil }) {
            self.pending = fallback.anchor
            previousDocumentY = fallback.documentY
            restoredPending = false
        }
        guard let pending, let scroll, let document = scroll.documentView,
              let marker = markers[pending.id]?.view, marker.window != nil, marker.bounds.height > 1 else { return }
        let documentY = marker.convert(marker.bounds, to: document).minY
        // Once the prepend has been restored, a late SwiftUI item scroll can
        // still change the clip offset without changing this marker's position.
        // Correct that too, until the next user input cancels preservation.
        if let previousDocumentY, abs(documentY - previousDocumentY) < 1, !restoredPending { return }
        // Keep a remounted expanded row visible until its loading placeholder
        // has grown enough to contain the saved position inside the row.
        guard marker.bounds.height > max(1, -pending.offset) else { return }
        let y = documentY - pending.offset
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let destination = min(max(0, y), maximum)
        restoredPending = abs(y - destination) <= 0.25
        guard abs(destination - scroll.contentView.bounds.minY) > 0.25 else { return }
        adjusting = true
        defer { adjusting = false }
        recordCorrection(from: scroll.contentView.bounds.minY, to: destination)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: destination))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func recordCorrection(from: CGFloat, to: CGFloat) {
        guard diagnosticSink != nil || ChatViewportTrace.enabled else { return }
        diagnosticCorrection = .init(from: from, to: to)
        recordDiagnostic(.correction)
    }

    /// Coalesce high-frequency layout notifications before inspecting markers.
    /// Milestones bypass the throttle so recovery decisions remain ordered.
    func recordDiagnostic(_ event: ChatViewportTrace.Event, force: Bool = false,
                          now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let diagnosticSink = diagnosticSink ?? (ChatViewportTrace.enabled
            ? { ChatViewportTrace.shared.record($0) } : nil) else {
            diagnosticEvents.removeAll(keepingCapacity: true)
            diagnosticCorrection = nil
            return
        }
        let isVisible = scroll?.window?.isVisible == true && scroll?.window?.isMiniaturized == false
            && scroll?.isHiddenOrHasHiddenAncestor == false
        // Keep one transition sample for hidden chats, not a periodic scan of
        // every retained conversation in a large workspace.
        if !isVisible, diagnosticWasVisible == false,
           event != .attached && event != .connected && event != .disconnected { return }
        diagnosticEvents[event.rawValue, default: 0] += 1
        guard force || now - lastDiagnostic >= 0.25 else { return }
        lastDiagnostic = now
        diagnosticWasVisible = isVisible
        let clip = scroll?.contentView.bounds, document = scroll?.documentView
        var summary = ChatViewportTrace.Markers()
        summary.registered = markers.count
        // Every mounted row, hidden ones included: where the lazy stack placed
        // rows relative to the clip explains an empty viewport.
        var mounted: [(id: String, frame: NSRect, alpha: Double, hidden: Bool, visible: Bool)] = []
        for (id, marker) in markers {
            guard let view = marker.view, view.window != nil,
                  view.enclosingScrollView === scroll, let document, let clip else { continue }
            summary.mounted += 1
            let frame = view.convert(view.bounds, to: document)
            var alpha = 1.0, ancestor: NSView? = view
            while let node = ancestor { alpha *= node.alphaValue; ancestor = node.superview }
            let hidden = view.isHiddenOrHasHiddenAncestor
            var visible = false
            if hidden { summary.hidden += 1 }
            else if frame.width <= 1 || frame.height <= 1 { summary.empty += 1 }
            else if frame.intersects(clip) {
                if alpha <= 0.01 { summary.transparent += 1 }
                summary.visible += 1; visible = true
            }
            mounted.append((id, frame, alpha, hidden, visible))
        }
        // The random key never leaves memory. Unlike a public salt, it cannot
        // be used to guess a path or identifier from a shared trace.
        func token(_ id: String) -> String {
            HMAC<SHA256>.authenticationCode(for: Data(id.utf8), using: diagnosticKey).prefix(8)
                .map { String(format: "%02x", $0) }.joined()
        }
        func anchor(_ value: Anchor?) -> ChatViewportTrace.Anchor? {
            value.map { .init(token: token($0.id), offset: $0.offset) }
        }
        // Visible rows first, then the nearest others, in a bounded record.
        let center = clip.map { $0.midY } ?? 0
        let sampled = mounted.sorted { lhs, rhs in
            lhs.visible != rhs.visible ? lhs.visible : abs(lhs.frame.midY - center) < abs(rhs.frame.midY - center)
        }.prefix(16).sorted { $0.frame.minY < $1.frame.minY }
        let info = diagnosticRows?(Set(sampled.map(\.id))) ?? [:]
        summary.rows = sampled.map {
            .init(token: token($0.id), frame: .init($0.frame), alpha: $0.alpha, hidden: $0.hidden,
                  index: info[$0.id]?.index, kind: info[$0.id]?.kind)
        }
        let window = scroll?.window
        diagnosticSink(.init(date: Date(), elapsed: max(0, now - diagnosticStarted), viewport: diagnosticID, event: event,
            events: diagnosticEvents, transcript: diagnosticState?(), clip: clip.map(ChatViewportTrace.Rect.init),
            document: document.map { .init($0.bounds) }, documentNeedsLayout: document?.needsLayout ?? false,
            documentNeedsDisplay: document?.needsDisplay ?? false, clipNeedsDisplay: scroll?.contentView.needsDisplay ?? false,
            windowVisible: window?.isVisible == true,
            windowOccluded: window.map { !$0.occlusionState.contains(.visible) } ?? false,
            scrollHidden: scroll?.isHiddenOrHasHiddenAncestor ?? true, markers: summary,
            saved: anchor(saved), pending: anchor(pending), correction: diagnosticCorrection,
            interaction: interactionRevision, adjusting: adjusting, adjustmentScheduled: adjustmentScheduled,
            tracking: isTrackingScroller, liveScrolling: isLiveScrolling, realizationAttempts: realizationAttempts,
            emptyChecks: emptyViewportChecks, blankDuration: emptyViewportSince.map { max(0, now - $0) },
            geometryAge: max(0, now - lastGeometryChange), wheelAge: lastWheelTime.isFinite ? max(0, now - lastWheelTime) : nil,
            sinceAttach: attachedAt.map { max(0, now - $0) }, swiftUI: swiftUIScroll))
        diagnosticEvents.removeAll(keepingCapacity: true)
        diagnosticCorrection = nil
    }
}

/// The scroll bridge must outlive lazy rows, including an empty realized range.
struct ChatScrollViewport: NSViewRepresentable {
    let position: ChatScrollPosition
    func makeNSView(context: Context) -> Probe { Probe(position: position) }
    func updateNSView(_ view: Probe, context: Context) { view.position = position; position.registerViewport(view) }
    final class Probe: NSView {
        var position: ChatScrollPosition
        init(position: ChatScrollPosition) { self.position = position; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { position.registerViewport(self) }
        }
        override func layout() { super.layout(); position.registerViewport(self) }
    }
}

/// An always-mounted hit region with a fading native thumb. Keeping the region
/// transparent (rather than hiding it) lets pointer entry reveal the thumb.
@MainActor
final class ChatScrollbar: NSView {
    final class Thumb: NSScroller {
        var color = NSColor(Chrome.muted) { didSet { needsDisplay = true } }
        var began: (() -> Void)?
        var ended: (() -> Void)?
        override var isOpaque: Bool { false }
        override var acceptsFirstResponder: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            guard isEnabled else { return }
            color.withAlphaComponent(0.65).setFill()
            let knob = rect(for: .knob).insetBy(dx: 4, dy: 1)
            NSBezierPath(roundedRect: knob, xRadius: 3, yRadius: 3).fill()
        }
        override func mouseDown(with event: NSEvent) {
            began?()
            defer { ended?() }
            super.mouseDown(with: event)
        }
        override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }
    }
    let thumb = Thumb(frame: NSRect(x: 0, y: 0, width: 14, height: 100))
    var beganDragging: (() -> Void)?
    var endedDragging: (() -> Void)?
    var moved: ((CGFloat) -> Void)?
    var wheel: ((NSEvent) -> Void)?
    private var hideTask: DispatchWorkItem?
    private var pointerInside = false
    private var dragging = false
    private var hoverArea: NSTrackingArea?
    private(set) var canScroll = false
    private(set) var revealed = false

    init() {
        super.init(frame: thumb.frame)
        thumb.scrollerStyle = .legacy
        thumb.autoresizingMask = [.width, .height]
        thumb.target = self; thumb.action = #selector(scrolled)
        thumb.isContinuous = true; thumb.alphaValue = 0
        thumb.setAccessibilityLabel("Chat history")
        thumb.setAccessibilityIdentifier("chat-scrollbar")
        addSubview(thumb)
        thumb.began = { [weak self] in
            guard let self else { return }
            dragging = true; reveal(); beganDragging?()
        }
        thumb.ended = { [weak self] in
            guard let self else { return }
            dragging = false; endedDragging?(); scheduleHide()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isOpaque: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp,
            .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        hoverArea = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; reveal() }
    override func mouseExited(with event: NSEvent) { pointerInside = false; scheduleHide() }
    override func mouseDown(with event: NSEvent) {
        guard canScroll else { return }
        reveal(); thumb.mouseDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) { reveal(); wheel?(event) }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { hideTask?.cancel(); hideTask = nil }
        super.viewWillMove(toSuperview: newSuperview)
    }
    func update(total: CGFloat, visible: CGFloat, offset: CGFloat) {
        canScroll = total > visible + 1
        if thumb.isEnabled != canScroll { thumb.isEnabled = canScroll }
        let proportion = total > 0 ? min(1, visible / total) : 1
        if thumb.knobProportion != proportion { thumb.knobProportion = proportion }
        let fraction = Double(max(0, min(1, offset / max(1, total - visible))))
        if !dragging && thumb.doubleValue != fraction { thumb.doubleValue = fraction }
        if !canScroll {
            hideTask?.cancel(); hideTask = nil
            revealed = false; thumb.alphaValue = 0
        }
        thumb.needsDisplay = true
    }
    func reveal() {
        guard canScroll else { return }
        hideTask?.cancel(); hideTask = nil
        revealed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            thumb.animator().alphaValue = 1
        }
        scheduleHide()
    }
    private func scheduleHide() {
        hideTask?.cancel(); hideTask = nil
        guard !pointerInside && !dragging else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, !pointerInside, !dragging else { return }
            revealed = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
                thumb.animator().alphaValue = 0
            }
            hideTask = nil
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: task)
    }
    @objc private func scrolled() {
        guard canScroll else { return }
        reveal()
        var fraction = CGFloat(thumb.doubleValue)
        let page = thumb.knobProportion / max(0.001, 1 - thumb.knobProportion)
        switch thumb.hitPart {
        case .decrementPage: fraction -= page
        case .incrementPage: fraction += page
        case .decrementLine: fraction -= page / 10
        case .incrementLine: fraction += page / 10
        default: break
        }
        moved?(min(1, max(0, fraction)))
    }
}

struct ChatScrollMarker: NSViewRepresentable {
    let id: String
    let position: ChatScrollPosition
    func makeNSView(context: Context) -> Marker { Marker(id: id, position: position) }
    func updateNSView(_ view: Marker, context: Context) { view.update(id: id, position: position) }
    static func dismantleNSView(_ view: Marker, coordinator: ()) { view.position.unregister(view, id: view.id) }
    final class Marker: NSView {
        private(set) var id: String
        private(set) var position: ChatScrollPosition
        init(id: String, position: ChatScrollPosition) { self.id = id; self.position = position; super.init(frame: .zero) }
        func update(id: String, position: ChatScrollPosition) {
            if self.id != id || self.position !== position {
                self.position.unregister(self, id: self.id)
                self.id = id; self.position = position
            }
            position.register(self, id: id)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { position.register(self, id: id) } }
        override func setFrameOrigin(_ origin: NSPoint) {
            guard origin != frame.origin else { return }
            super.setFrameOrigin(origin); position.geometryChanged()
        }
        override func setFrameSize(_ size: NSSize) {
            guard size != frame.size else { return }
            super.setFrameSize(size); position.geometryChanged()
        }
        override func layout() { super.layout(); position.geometryChanged() }
    }
}

/// A display link's target; the link retains it, and it holds its owner weakly.
@MainActor private final class GlideStep: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func step(_ link: CADisplayLink) { action() }
}
