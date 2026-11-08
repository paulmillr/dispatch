import AppKit
import CryptoKit
import SwiftUI

/// One chat's scroll controller. It attaches to the transcript's `NSScrollView` and keeps a single positioning
/// intent that the native document (`ChatTranscriptDocument`) realizes on every layout. It never computes row
/// geometry, and it moves the clip itself only for the arrival glide's frames.
@MainActor
final class ChatScrollPosition {
    struct Anchor: Equatable { let id: String; let offset: CGFloat }
    /// What the next layout does with the clip beyond keeping the reader's message where it is.
    enum Intent: Equatable {
        /// Nothing requested: the document keeps the visible message, or the bottom while the view follows it.
        case free
        /// The latest output, until a layout lands there (a jump the reader asked for, or opening at the bottom).
        case bottom
        /// A message at a pixel offset (a reopened view, a find, a prepend), until a layout has it mounted.
        case hold(Anchor)
    }
    private(set) var intent = Intent.free
    /// The last position a layout reported; a view that mounts again restores it.
    private(set) var saved: Anchor?
    var restorationAnchor: Anchor? {
        guard case .hold(let anchor) = intent else { return nil }
        return anchor
    }
    var isRestoring: Bool { intent != .free }

    // The view's side: set by `ChatTranscriptView` when it connects, cleared when the last view leaves.
    /// Whether the reader follows the latest output (the session's `atBottom` and follow revision).
    var followsBottom: (() -> Bool)?
    var userScrolled: (() -> Void)?
    var positionChanged: ((Anchor) -> Void)?
    /// Whether the transcript has rows: an empty page has no latest row for a jump to wait for.
    var hasContent: (() -> Bool)?
    /// Whether a row still exists: a restoration whose row is gone for good has nothing to wait for.
    var rowExists: ((String) -> Bool)?
    /// Called with true while the window is off screen (`ChatSession.holdTranscript`), false before it shows again.
    var holdChanged: ((Bool) -> Void)?
    /// Starts an earlier-history read (true when the reader asked for it); returns whether one started.
    var loadEarlier: ((Bool) -> Bool)?
    /// Room the followed bottom leaves below the last row, outside the floating composer's inset.
    var bottomPadding: CGFloat = 0
    var scrollbarColor = NSColor(Chrome.muted) { didSet { scrollbar?.thumb.color = scrollbarColor } }

    private weak var scroll: NSScrollView?
    /// Scroll views documents registered, newest last: when the newest view leaves, the one still showing takes over.
    private var viewports: [WeakScroll] = []
    private var document: ChatTranscriptDocument? { scroll?.documentView as? ChatTranscriptDocument }
    private(set) var scrollbar: ChatScrollbar?
    private var observations: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var eventMonitor: Any?
    /// The views showing this chat, oldest first, each with how it connects again. The last one owns the
    /// callbacks: an earlier view's disconnect leaves them (a moved tab mounts its new view before the old one
    /// disappears), and the last one's hands them back to the view still showing.
    private var connections: [(token: UUID, reconnect: (UUID) -> Void)] = []

    // MARK: Attaching

    /// The document calls this when it enters a window; a new scroll view replaces every observation.
    func registerViewport(_ view: NSView) {
        guard let value = view.enclosingScrollView, value !== scroll else { return }
        viewports.removeAll { $0.value == nil || $0.value === value }
        viewports.append(WeakScroll(value))
        attach(value)
    }

    private func attach(_ value: NSScrollView) {
        stopObserving()
        scroll = value
        attachedAt = ProcessInfo.processInfo.systemUptime
        firstScrollPending = true
        recordDiagnostic(.attached, force: true)
        installScrollbar(in: value)
        value.contentView.postsBoundsChangedNotifications = true
        value.postsFrameChangedNotifications = true
        observe(NSView.boundsDidChangeNotification, value.contentView) { position, _ in position.clipMoved() }
        observe(NSView.frameDidChangeNotification, value) { position, _ in position.updateScrollbar() }
        observe(NSScrollView.willStartLiveScrollNotification, value) { position, _ in
            position.isLiveScrolling = true
            position.liveScrollMoved = ProcessInfo.processInfo.systemUptime
            position.beginUserScroll()
        }
        observe(NSScrollView.didEndLiveScrollNotification, value) { position, _ in
            position.isLiveScrolling = false
            position.finishScrollerTracking()
            // Following waited for AppKit's live scroll to end (`ownsClip`): settle now.
            position.document?.layoutTranscript()
        }
        // Visibility can change during AppKit layout: check on the next turn, for this window only.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            observe(name) { position, sender in
                guard position.isOwnWindow(sender) else { return }
                DispatchQueue.main.async { [weak position] in position?.checkViewport(redraw: true) }
            }
        }
        observe(NSApplication.didBecomeActiveNotification) { position, _ in
            DispatchQueue.main.async { [weak position] in position?.checkViewport(redraw: true) }
        }
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { position, _ in
            DispatchQueue.main.async { [weak position] in position?.checkViewport(redraw: true) }
        }
        observeScreen()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            self?.handleScrollEvent(event)
            return event
        }
    }

    /// `queue` nil delivers synchronously, for the window's own show and hide notifications.
    private func observe(_ name: Notification.Name, _ object: AnyObject? = nil, center: NotificationCenter = .default,
                         queue: OperationQueue? = .main,
                         _ handler: @escaping @Sendable @MainActor (ChatScrollPosition, ObjectIdentifier?) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: queue) { [weak self] note in
            let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated { if let self { handler(self, sender) } }
        }
        observations.append((center, token))
    }

    private func isOwnWindow(_ sender: ObjectIdentifier?) -> Bool {
        guard let window = scroll?.window else { return false }
        return sender == ObjectIdentifier(window)
    }

    private func stopObserving() {
        observations.forEach { $0.center.removeObserver($0.token) }
        observations = []
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    /// A view connecting takes over the session's callbacks; the token is what it disconnects with, and
    /// `reconnect` wires that view again (with its token) if it outlasts a later one.
    func connect(reusing token: UUID? = nil, reconnect: @escaping (UUID) -> Void = { _ in }) -> UUID {
        let token = token ?? System.uuid()
        connections.removeAll { $0.token == token }
        connections.append((token, reconnect))
        return token
    }

    /// An earlier view's token only forgets that view; the last view's disconnect detaches the session, then
    /// connects the view still showing, if any.
    func disconnect(_ token: UUID? = nil) {
        if let token {
            guard connections.last?.token == token else {
                connections.removeAll { $0.token == token }
                return
            }
            connections.removeLast()
        } else {
            connections = []
        }
        let leaving = scroll
        detach()
        guard let previous = connections.last else { return }
        if let showing = viewports.last(where: { $0.value !== leaving && $0.value?.window != nil })?.value { attach(showing) }
        previous.reconnect(previous.token)
    }

    private func detach() {
        recordDiagnostic(.disconnected, force: true)
        cancelGlide(); arrivalExpectedAt = -.infinity
        saved = visibleAnchor() ?? saved
        if intent == .bottom { intent = .free }
        diagnosticState = nil; diagnosticRows = nil
        firstScrollPending = false; attachedAt = nil
        hasContent = nil; rowExists = nil; followsBottom = nil
        automaticHistoryLoadsRemaining = 0; loadEarlier = nil
        stopObserving()
        scrollbar?.removeFromSuperview(); scrollbar = nil
        scroll = nil
        isLiveScrolling = false; lastWheelTime = -.infinity
        finishScrollerTracking()
        // The next view of this chat shows its current rows (callbacks are gone: no rebuild from here).
        setHolding(false)
    }

    // MARK: Intent

    func restore(_ anchor: Anchor?) { saved = anchor; restoreOnAppearance() }

    /// A view mounting again shows what the last one reported (or what `restore` set).
    func restoreOnAppearance() { setIntent(saved.map(Intent.hold) ?? .free) }

    /// Before rows are inserted above the reader: hold the first visible row that survives the change.
    func preserveForPrepend(retaining ids: Set<String>? = nil) {
        guard let anchor = visibleAnchor(retaining: ids) else { return }
        saved = anchor
        setIntent(.hold(anchor))
    }

    /// After the model published the prepend: the document's next layout realizes the held row.
    func restoreAfterPrepend() { setIntent(intent) }

    func cancelPreservation() {
        if case .hold = intent { intent = .free }
    }

    func jumpToLatest() {
        cancelGlide(); arrivalExpectedAt = -.infinity
        saved = nil
        setIntent(hasContent?() == false ? .free : .bottom)
        if intent == .free { document?.scrollToBottom() }
    }

    /// Keeps the latest output in view after a change outside the rows (an approval, a taller composer).
    func followLatest() {
        // During AppKit's live scroll its end lays out and settles a followed bottom instead.
        guard restorationAnchor == nil, followsBottom?() == true, !ownsClip, document?.layingOut == false else { return }
        document?.scrollToBottom()
    }

    func clear() {
        saved = nil; intent = .free
        automaticHistoryLoadsRemaining = 0
    }

    /// Records the intent and asks the document for a layout that realizes it.
    private func setIntent(_ value: Intent) {
        intent = value
        guard let document, !document.layingOut else { return }
        switch value {
        case .hold(let anchor): recordDiagnostic(.restoreRequested); document.scroll(to: anchor)
        case .bottom: recordDiagnostic(.followRequested); document.scrollToBottom()
        case .free: break
        }
    }

    /// The document calls this after it has set every visible frame and the final clip offset.
    func nativeLayoutCompleted(animateArrival: Bool = false) {
        if let anchor = restorationAnchor, document?.hasMounted(anchor.id) != true {
            // A row the model no longer has can never be realized; anything else waits for the update that adds it,
            // reporting nothing meanwhile: the viewport is not yet where the restoration is going.
            guard rowExists?(anchor.id) == false else { updateScrollbar(); return }
            intent = .free
            if saved?.id == anchor.id { saved = nil }
        }
        if animateArrival { startGlide() }
        if let actual = visibleAnchor() {
            saved = actual
            intent = .free
            positionChanged?(actual)
        } else if intent == .bottom {
            intent = .free
        }
        updateScrollbar()
        prefetchEarlier()
    }

    /// Something outside the rows changed (history state, a cancelled page): measure the rows again and lay out.
    func geometryChanged() {
        guard let document, !document.layingOut else { return }
        document.invalidateMeasurements()
        updateScrollbar()
        recordDiagnostic(.geometry)
    }

    func visibleAnchor(retaining ids: Set<String>? = nil) -> Anchor? { document?.visibleAnchor(retaining: ids) }

    /// Measured from the offset following settles at, which leaves `bottomPadding` below the viewport.
    func isAtBottom(tolerance: CGFloat) -> Bool? {
        guard let scroll, let document = scroll.documentView else { return nil }
        return bottomOffset(scroll, document) - scroll.contentView.bounds.minY <= tolerance
    }

    private func bottomOffset(_ scroll: NSScrollView, _ document: NSView) -> CGFloat {
        max(0, document.bounds.maxY - bottomPadding - scroll.contentView.bounds.height)
    }

    /// Whether the end of the transcript, where records land, is out of the reader's view and its lookahead: the
    /// clip is more than two of its heights above the bottom. False without a viewport.
    func endOutOfView() -> Bool {
        guard let scroll, let document = scroll.documentView else { return false }
        return bottomOffset(scroll, document) - scroll.contentView.bounds.minY > 2 * scroll.contentView.bounds.height
    }

    /// Whether the viewport shows rows, not a sliver of one: visible rows cover a tenth of the clip, or one row lies
    /// wholly inside it (a short transcript).
    func showsRows() -> Bool {
        guard let scroll, let document else { return false }
        let viewport = scroll.contentView.bounds
        var covered: CGFloat = 0
        for view in document.mountedRows.values where view.window != nil && !view.isHiddenOrHasHiddenAncestor {
            let frame = view.convert(view.bounds, to: document)
            guard frame.width > 1, frame.height > 1 else { continue }
            let overlap = min(frame.maxY, viewport.maxY) - max(frame.minY, viewport.minY)
            guard overlap > 1 else { continue }
            if frame.minY >= viewport.minY - 0.5 && frame.maxY <= viewport.maxY + 0.5 { return true }
            covered += overlap
            if covered >= viewport.height * 0.1 { return true }
        }
        return false
    }

    /// The clip moved (input, a glide frame, the document's own correction): mount what came into view.
    private func clipMoved() {
        if isLiveScrolling { liveScrollMoved = ProcessInfo.processInfo.systemUptime }
        guard let document, !document.layingOut else { return }
        document.layoutTranscript()
        recordDiagnostic(.scrolled)
    }

    /// Visibility changed or the Mac woke: lay out, and repaint text views that keep their own layers.
    func checkViewport(redraw: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let scroll, let document else { return }
        document.layoutTranscript()
        if redraw {
            recordDiagnostic(.redraw)
            let clip = document.convert(scroll.contentView.bounds, from: scroll.contentView)
            scroll.contentView.needsDisplay = true
            document.setNeedsDisplay(clip)
            func invalidate(_ view: NSView) {
                for child in view.subviews where !child.isHidden && child.convert(child.bounds, to: document).intersects(clip) {
                    if child is NSTextView { child.needsDisplay = true } else { invalidate(child) }
                }
            }
            invalidate(document)
        }
        recordDiagnostic(.mountCheck, force: true, now: now)
    }

    // MARK: User input

    private(set) var interactionRevision = 0
    private(set) var isTrackingScroller = false
    private var isLiveScrolling = false
    private var liveScrollMoved = -Double.infinity
    private var lastWheelTime = -Double.infinity

    /// AppKit is moving the clip itself, between its live-scroll notifications: a gesture, its momentum or an elastic
    /// bounce. Following leaves the clip to it until the live scroll ends. AppKit's concurrent scrolling applies its
    /// own origin again on every frame, so a pass that moved the clip during one (momentum re-arms following as it
    /// nears the bottom) started a fight: the live scroll never ended and the clip was flung thousands of points past
    /// the document. A live scroll whose clip has not moved for a second no longer counts, in case AppKit never
    /// reports its end.
    var ownsClip: Bool {
        isLiveScrolling && ProcessInfo.processInfo.systemUptime - liveScrollMoved < 1
    }
    /// History waiting for a scrollbar drag to end: the thumb maps a fraction of the height it would change.
    private var afterTracking: [() -> Void] = []

    func forwardWheel(_ event: NSEvent) { scroll?.scrollWheel(with: event) }

    func handleScrollEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp { finishScrollerTracking(); return }
        guard let scroll, event.window === scroll.window else { return }
        if event.type == .keyDown {
            // Only navigation inside the transcript: editing the composer or a nested output keeps following.
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
            if let bar = scrollbar, bar.canScroll, bar.frame.contains(point) { isTrackingScroller = true; beginUserScroll() }
        } else if event.type == .scrollWheel && event.scrollingDeltaY != 0 {
            // A tool's nested code or output scroller does not move the transcript.
            if let hit = scroll.contentView.hitTest(point), hit.enclosingScrollView !== scroll { return }
            userWillScroll(deltaY: event.scrollingDeltaY)
        }
    }

    /// Wheel input about to move the transcript (positive is towards earlier history).
    func userWillScroll(deltaY: CGFloat) {
        guard deltaY != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = velocityTime.map { now - $0 } ?? 1.0 / 60
        let speed = max(0, deltaY) / max(1.0 / 240, interval)
        earlierVelocity = interval > 0.3 ? speed : max(speed, earlierVelocity * 0.8)
        velocityTime = now
        lastWheelTime = now
        beginUserScroll()
        if deltaY > 0, let scroll, scroll.contentView.bounds.minY < earlierPrefetchDistance { _ = loadEarlier?(true) }
    }

    /// The reader takes over: every programmatic position and the follow intent give way.
    private func beginUserScroll() {
        // The first scroll after mounting shows what the reader was looking at.
        recordDiagnostic(.userScroll, force: firstScrollPending)
        firstScrollPending = false
        scrollbar?.reveal()
        interactionRevision &+= 1
        automaticHistoryLoadsRemaining = 4
        intent = .free
        document?.cancelPositioning()
        cancelGlide(); arrivalExpectedAt = -.infinity
        userScrolled?()
    }

    /// Runs history changes after a scrollbar drag; wheel scrolling keeps its pixel anchor, so it never waits.
    func performAfterScrolling(_ action: @escaping () -> Void) {
        if isTrackingScroller { afterTracking.append(action) } else { action() }
    }

    private func finishScrollerTracking() {
        isTrackingScroller = false
        let actions = afterTracking
        afterTracking = []
        actions.forEach { $0() }
    }

    // MARK: Arrival glide

    /// A live row arriving at the followed bottom glides there with its fade instead of jumping.
    static let arrivalGlide: TimeInterval = 0.22
    private var arrivalExpectedAt = -Double.infinity
    private var glide: (from: CGFloat, start: TimeInterval, link: CADisplayLink)?
    var wantsArrivalGlide: Bool { glide != nil || ProcessInfo.processInfo.systemUptime - arrivalExpectedAt < 0.3 }

    /// The session is inserting a live row while the reader follows the bottom.
    func expectArrival() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        arrivalExpectedAt = ProcessInfo.processInfo.systemUptime
    }

    private func startGlide() {
        guard glide == nil, let scroll else { return }
        arrivalExpectedAt = -.infinity
        // One step per displayed frame, in the display cycle the arrival fade updates in: a timer out of phase with
        // it, or faster than the display, scrolls and lays out the transcript again. At the motion policy's rate: the
        // screen's own on the adapter, 60 on battery or behind another app, 30 in Low Power Mode.
        let link = scroll.displayLink(target: GlideStep { [weak self] in self?.glideFrame() }, selector: #selector(GlideStep.step))
        link.preferredFrameRateRange = MotionRate.range(on: scroll.window?.screen)
        link.add(to: .main, forMode: .common)
        glide = (scroll.contentView.bounds.minY, ProcessInfo.processInfo.systemUptime, link)
    }

    /// Each frame re-reads the bottom, so growth during the glide joins it.
    private func glideFrame() {
        guard let glide, let scroll, let document = scroll.documentView, restorationAnchor == nil,
              followsBottom?() == true else { cancelGlide(); return }
        let progress = min(1, (ProcessInfo.processInfo.systemUptime - glide.start) / Self.arrivalGlide)
        let y = glide.from + (bottomOffset(scroll, document) - glide.from) * (1 - pow(1 - progress, 3))
        if abs(y - scroll.contentView.bounds.minY) > 0.25 {
            recordCorrection(from: scroll.contentView.bounds.minY, to: y)
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if progress >= 1 { cancelGlide() }
    }

    func cancelGlide() { glide?.link.invalidate(); glide = nil }

    // MARK: Off screen

    /// Whether the transcript holds what it shows: its window is off screen (`MainWindow.isOffScreen`).
    private var holding = false

    /// Hold while the transcript's main window is off screen, and release synchronously when it is about to show
    /// (`MainWindow.willShow`), so it lays out and draws what arrived before its first frame. Only a `MainWindow` says
    /// when it is about to show; elsewhere the transcript never holds.
    private func observeScreen() {
        setHolding(false)
        observe(MainWindow.willShow, queue: nil) { position, sender in
            if position.isOwnWindow(sender) { position.setHolding(false) }
        }
        observe(MainWindow.didLeaveScreen, queue: nil) { position, sender in
            guard position.isOwnWindow(sender), let window = position.scroll?.window as? MainWindow else { return }
            position.setHolding(window.isOffScreen)
        }
        // Back on screen some other way (it should not happen): show what arrived at once.
        observe(NSWindow.didChangeOcclusionStateNotification, queue: nil) { position, sender in
            guard position.holding, position.isOwnWindow(sender), let window = position.scroll?.window,
                  window.isVisible, !NSApp.isHidden else { return }
            position.setHolding(false)
        }
    }

    private func setHolding(_ value: Bool) {
        guard holding != value else { return }
        holding = value
        if value { cancelGlide(); arrivalExpectedAt = -.infinity }
        holdChanged?(value)
        // SwiftUI applies the released rows when its hosting views lay out: have the window's layout before it shows
        // reach them (MainWindow.prepareToShow).
        if !value {
            var view: NSView? = scroll
            while let current = view { current.needsLayout = true; view = current.superview }
            (scroll?.window as? MainWindow)?.releasedHeldContent = true
        }
    }

    // MARK: Earlier history

    /// Explicit paging and search hosts own their requests; viewport-triggered loads would race them.
    var automaticHistoryPrefetch = true
    private var automaticHistoryLoadsRemaining = 0
    private var earlierVelocity: CGFloat = 0
    private var earlierReadLatency: TimeInterval = 0.1
    private var velocityTime: TimeInterval?

    /// How close to the top a load starts: six screens, more while scrolling up fast against a slow read.
    var earlierPrefetchDistance: CGFloat {
        let height = max(400, scroll?.contentView.bounds.height ?? 0)
        let recent = velocityTime.map { ProcessInfo.processInfo.systemUptime - $0 < 0.3 } ?? false
        let lead = recent ? earlierVelocity * max(0.35, earlierReadLatency * 3) : 0
        return max(height * 6, min(height * 12, lead))
    }

    func observedHistoryRead(seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        earlierReadLatency = earlierReadLatency * 0.7 + min(seconds, 2) * 0.3
    }

    /// Build a scroll reserve once the latest messages show; even tool-only history must not make opening a view an
    /// unlimited read.
    func beginOpeningHistoryPreload() {
        automaticHistoryLoadsRemaining = 4
        geometryChanged()
    }

    func historyLoadFinished(madeProgress: Bool) {
        if !madeProgress { automaticHistoryLoadsRemaining = 0 }
        geometryChanged()
    }

    private func prefetchEarlier() {
        guard automaticHistoryPrefetch, automaticHistoryLoadsRemaining > 0, !isRestoring,
              let scroll, scroll.window?.isVisible == true,
              scroll.contentView.bounds.minY < earlierPrefetchDistance, let loadEarlier else { return }
        // Spend before calling out: publishing the loading state can lay out (and prefetch) again. A request that
        // does not start gives it back.
        automaticHistoryLoadsRemaining -= 1
        if !loadEarlier(false) { automaticHistoryLoadsRemaining += 1 }
    }

    // MARK: Scrollbar

    private func installScrollbar(in scroll: NSScrollView) {
        scrollbar?.removeFromSuperview()
        // A separate overlay owns visibility: AppKit's overlay scroller would show for programmatic scrolling too.
        scroll.hasVerticalScroller = false
        let bar = ChatScrollbar()
        bar.thumb.color = scrollbarColor
        bar.beganDragging = { [weak self] in self?.isTrackingScroller = true; self?.beginUserScroll() }
        bar.endedDragging = { [weak self] in self?.finishScrollerTracking() }
        bar.moved = { [weak self] fraction in
            guard let scroll = self?.scroll, let document = scroll.documentView else { return }
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: fraction * maximum))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        bar.wheel = { [weak scroll] event in scroll?.scrollWheel(with: event) }
        // SwiftUI lays out the scroll view's subviews, so the overlay is placed by hand on every resize.
        scroll.addSubview(bar)
        scrollbar = bar
        updateScrollbar()
    }

    private func updateScrollbar() {
        guard let scroll, let document = scroll.documentView, let bar = scrollbar else { return }
        let frame = NSRect(x: scroll.bounds.maxX - 14, y: scroll.bounds.minY, width: 14, height: scroll.bounds.height)
        if bar.frame != frame { bar.frame = frame }
        if bar.thumb.frame != bar.bounds { bar.thumb.frame = bar.bounds }
        bar.update(total: document.bounds.height, visible: scroll.contentView.bounds.height,
                   offset: scroll.contentView.bounds.minY)
    }

    // MARK: Diagnostics

    var diagnosticState: (() -> ChatViewportTrace.Transcript?)?
    /// Tests can inject a private sink; production checks the setting at each sample, so mounted conversations
    /// follow the checkbox live.
    var diagnosticSink: ((ChatViewportTrace.Sample) -> Void)?
    /// Transcript positions and categories for sampled row IDs; set by the view.
    var diagnosticRows: ((Set<String>) -> [String: ChatViewportTrace.RowInfo])?
    private let diagnosticID = System.uuid()
    private let diagnosticStarted = ProcessInfo.processInfo.systemUptime
    private lazy var diagnosticKey = SymmetricKey(size: .bits256)
    private var diagnosticEvents: [String: Int] = [:]
    private var lastDiagnostic = -Double.infinity
    private var lastGeometryChange = ProcessInfo.processInfo.systemUptime
    private var diagnosticWasVisible: Bool?
    private var diagnosticCorrection: ChatViewportTrace.Correction?
    private var attachedAt: TimeInterval?
    private var firstScrollPending = false

    private func recordCorrection(from: CGFloat, to: CGFloat) {
        guard diagnosticSink != nil || ChatViewportTrace.enabled else { return }
        diagnosticCorrection = .init(from: from, to: to)
        recordDiagnostic(.correction)
    }

    /// Coalesces layout events to four samples a second; milestones (`force`) bypass that, so their order survives.
    func recordDiagnostic(_ event: ChatViewportTrace.Event, force: Bool = false,
                          now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let sink = diagnosticSink ?? (ChatViewportTrace.enabled ? { ChatViewportTrace.shared.record($0) } : nil) else {
            diagnosticEvents.removeAll(keepingCapacity: true)
            diagnosticCorrection = nil
            return
        }
        if event == .geometry { lastGeometryChange = now }
        let window = scroll?.window
        let isVisible = window?.isVisible == true && window?.isMiniaturized == false && scroll?.isHiddenOrHasHiddenAncestor == false
        // One transition sample for a hidden chat, not a scan of every retained conversation in a large workspace.
        if !isVisible, diagnosticWasVisible == false, ![.attached, .connected, .disconnected].contains(event) { return }
        diagnosticEvents[event.rawValue, default: 0] += 1
        guard force || now - lastDiagnostic >= 0.25 else { return }
        lastDiagnostic = now
        diagnosticWasVisible = isVisible
        let clip = scroll?.contentView.bounds, documentView = scroll?.documentView
        // The random key never leaves memory: unlike a public salt, it cannot confirm a guessed path or ID.
        func token(_ id: String) -> String {
            HMAC<SHA256>.authenticationCode(for: Data(id.utf8), using: diagnosticKey).prefix(8)
                .map { String(format: "%02x", $0) }.joined()
        }
        func anchor(_ value: Anchor?) -> ChatViewportTrace.Anchor? { value.map { .init(token: token($0.id), offset: $0.offset) } }
        var summary = ChatViewportTrace.Markers()
        if let documentView, let clip {
            summary = .init(rows: document?.mountedRows ?? [:], in: documentView, clip: clip, token: token) {
                self.diagnosticRows?($0) ?? [:]
            }
        }
        sink(.init(date: Date(), elapsed: max(0, now - diagnosticStarted), viewport: diagnosticID, event: event,
            events: diagnosticEvents, transcript: diagnosticState?(), clip: clip.map(ChatViewportTrace.Rect.init),
            document: documentView.map { .init($0.bounds) }, documentNeedsLayout: documentView?.needsLayout ?? false,
            documentNeedsDisplay: documentView?.needsDisplay ?? false, clipNeedsDisplay: scroll?.contentView.needsDisplay ?? false,
            windowVisible: window?.isVisible == true,
            windowOccluded: window.map { !$0.occlusionState.contains(.visible) } ?? false,
            scrollHidden: scroll?.isHiddenOrHasHiddenAncestor ?? true, markers: summary,
            saved: anchor(saved), pending: anchor(restorationAnchor), correction: diagnosticCorrection,
            interaction: interactionRevision, adjusting: glide != nil, adjustmentScheduled: false,
            tracking: isTrackingScroller, liveScrolling: isLiveScrolling, realizationAttempts: 0,
            emptyChecks: 0, blankDuration: nil,
            geometryAge: max(0, now - lastGeometryChange), wheelAge: lastWheelTime.isFinite ? max(0, now - lastWheelTime) : nil,
            sinceAttach: attachedAt.map { max(0, now - $0) }, swiftUI: nil))
        diagnosticEvents.removeAll(keepingCapacity: true)
        diagnosticCorrection = nil
    }
}

private struct WeakScroll {
    weak var value: NSScrollView?
    init(_ value: NSScrollView) { self.value = value }
}

/// A display link's target; the link retains it, and it holds its owner weakly.
@MainActor private final class GlideStep: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func step(_ link: CADisplayLink) { action() }
}
