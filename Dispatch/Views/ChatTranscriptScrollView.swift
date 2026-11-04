import AppKit
import SwiftUI

#if DISPATCH_BENCHMARK
/// Diagnostic totals; excluded from normal app builds. Times overlap (measurement includes creation).
@MainActor enum ChatTranscriptMetrics {
    static var values: [String: Double] = [:]
    static func count(_ name: String, _ amount: Double = 1) { values[name, default: 0] += amount }
    static func peak(_ name: String, _ value: Double) { values[name] = max(values[name] ?? 0, value) }
}
#endif

/// What a hosted transcript row's root captures by value, as tokens that are cheap to compare (revision IDs, flags,
/// short strings; never text or row models). An unchanged revision keeps the row's root and its SwiftUI graph:
/// everything a row reads through observation (expansion, approvals, typing reveals) updates in place without one.
struct ChatTranscriptRowRevision: Equatable {
    /// Inputs every row's root shares. A change replaces each root once, when its row is next measured.
    struct Context: Equatable {
        var theme: ChatTheme
        var query: String
        var directory: String
        var openedAt: TimeInterval
        var reduceMotion: Bool
        var source: SSHConnectionID?
    }
    private struct Step: Equatable {
        let step: ChatToolStep
        let first: Bool, last: Bool, current: Bool, running: Bool
        let replaced: UUID?
        let replacedStep: ChatToolStep?
    }
    private let item: UUID?
    private let approval: UUID?
    private let group: UUID?
    private let toolGroupID: String?
    private let turnID: String?
    private let bubbleStart: Bool, bubbleEnd: Bool, signsOff: Bool, placeholder: Bool
    private let workedFor: TimeInterval?
    private let replyTime: Date?
    private let time: Date?
    private let timeline: Step?
    private let watchDay: String?, watch: String?
    private let match: String?
    private let handoff: ObjectIdentifier?
    private let receipt: ObjectIdentifier?
    private let streaming: ChatTypedMarkdown.Streaming?

    /// `match` is the selected search match; only a match in this row counts. `handoff` and `receipt` are the row's
    /// arrival receipts (`ChatTranscriptArrivals`), compared by identity.
    init(_ row: ChatTranscriptRow, watch: (day: String?, watch: String)? = nil, match: ChatSearch.Match? = nil,
         handoff: AnyObject? = nil, receipt: AnyObject? = nil, streaming: ChatTypedMarkdown.Streaming? = nil) {
        item = row.item?.presentationID
        approval = row.approval?.id
        group = row.group?.presentationID
        toolGroupID = row.toolGroupID; turnID = row.turnID
        bubbleStart = row.bubbleStart; bubbleEnd = row.bubbleEnd; signsOff = row.signsOff; placeholder = row.placeholder
        workedFor = row.workedFor; replyTime = row.replyTime; time = row.time
        timeline = row.timeline.map {
            Step(step: $0.step, first: $0.first, last: $0.last, current: $0.current, running: $0.running,
                 replaced: $0.replaced?.item.presentationID, replacedStep: $0.replaced?.step)
        }
        watchDay = watch?.day; self.watch = watch?.watch
        self.match = match.flatMap { $0.document.row == row.id ? "\($0.id)/\($0.range.length)" : nil }
        self.handoff = handoff.map(ObjectIdentifier.init)
        self.receipt = receipt.map(ObjectIdentifier.init)
        self.streaming = streaming
    }
}

/// The transcript has one layout owner. Estimates locate offscreen rows, but every visible row has a measured
/// frame before the clip is presented. Changing an estimate retains the reader's message and pixel offset.
struct ChatTranscriptScrollView: NSViewRepresentable {
    let ids: [String]
    let position: ChatScrollPosition
    let initiallyAtBottom: Bool
    let topInset: CGFloat
    let bottomInset: CGFloat
    /// Inputs shared by every row's root (`ChatTranscriptRowRevision.Context`).
    var context: ChatTranscriptRowRevision.Context? = nil
    /// A row's revision: its host keeps its root while this is unchanged. Without one (nil, or nil for a row) the
    /// root is replaced on every update.
    var revision: ((String) -> ChatTranscriptRowRevision?)? = nil
    /// The reply halo (ChatReplyHaloView), on a bubble at most `haloMaxWidth` wide.
    var halo: ChatReplyHalo? = nil
    var haloMaxWidth: CGFloat = .infinity
    var haloAccent: Color = .accentColor
    let row: (String, CGFloat) -> AnyView

    func makeNSView(context: Context) -> TranscriptScrollView {
        let scroll = TranscriptScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        let document = ChatTranscriptDocument(position: position, initiallyAtBottom: initiallyAtBottom)
        scroll.documentView = document
        document.update(ids: ids, topInset: topInset, bottomInset: bottomInset, context: self.context,
                        revision: revision, row: row)
        document.setHalo(halo, maxWidth: haloMaxWidth, accent: haloAccent)
        return scroll
    }

    /// The transcript fills whatever it is offered. Without this, SwiftUI derives the view's layout traits from
    /// AppKit's `fittingSize`, which builds a temporary constraint engine over the whole document, every hosted row
    /// included, on each layout of the enclosing view: once per scrolled frame.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ scroll: TranscriptScrollView, context: Context) {
        let document = scroll.documentView as? ChatTranscriptDocument
        document?.update(ids: ids, topInset: topInset, bottomInset: bottomInset, context: self.context, revision: revision, row: row)
        document?.setHalo(halo, maxWidth: haloMaxWidth, accent: haloAccent)
    }

    final class TranscriptScrollView: NSScrollView {
        override func layout() {
            super.layout()
            // A no-op unless the clip changed size or position, or something invalidated the document.
            (documentView as? ChatTranscriptDocument)?.layoutTranscript()
        }
    }
}

/// Rows intersecting the clip (and a pending destination) are built and measured synchronously in the layout pass
/// that shows them. Rows within the lookahead (a viewport in the direction of travel, more while it moves fast, a
/// quarter behind) are built in run-loop turns of their own, after the turn that scrolled. Hosts that leave the
/// lookahead are hidden and kept, within a bound, so reversing direction does not rebuild them; they are dropped
/// when idle, when their row leaves the transcript, or when the width changes.
@MainActor
final class ChatTranscriptDocument: NSView {
    typealias Anchor = ChatScrollPosition.Anchor
    /// Lookahead, in viewports beyond the clip: ahead in the direction of travel, and behind it.
    static let lookaheadAhead: CGFloat = 1
    static let lookaheadBehind: CGFloat = 0.25
    /// Deferred construction stops after this much time in one turn; a row costs about 3-6 ms, so this is one row.
    static let lookaheadBudget: CFTimeInterval = 0.003
    /// While the clip moves fast, the lookahead ahead also covers this much travel time (at most `lookaheadMaximum`
    /// viewports): rows must be built and their asynchronous content settled before they enter the clip.
    static let lookaheadLead: CFTimeInterval = 0.25
    static let lookaheadMaximum: CGFloat = 3
    /// After Core Animation's before-waiting commit observer (2,000,000) where it has one; on macOS 27 the commit runs
    /// in the display cycle instead, so this only ends a turn.
    private static let lookaheadOrder: CFIndex = 2_100_000
    /// Hidden hosts kept for a reversal: at most this many viewports of total height, this many hosts, and this many
    /// viewports from the clip. Memory scales with hosted area, so this bounds it to the lookahead's size again.
    static let cacheHeight: CGFloat = 1.5
    static let cacheCount = 16
    static let cacheDistance: CGFloat = 3
    /// A followed clip below the follow offset stays where AppKit put it for this long after AppKit last moved it (a
    /// bounce's frames are this close).
    static let appKitClipInterval: CFTimeInterval = 0.5
    /// Hidden hosts are released after this long without the clip moving.
    static let idleRetirement: TimeInterval = 1.5
    /// A document that just entered a window builds no lookahead until it has shown this long or its clip moves: a
    /// reader switching through tabs passes it in a moment, and it was a third of each switch's work.
    static let lookaheadAfterMount: CFTimeInterval = 0.3

    override var isFlipped: Bool { true }
    let position: ChatScrollPosition
    private let initiallyAtBottom: Bool
    private var didLayout = false
    private(set) var layingOut = false
    private var ids: [String] = []
    private var indices: [String: Int] = [:]
    private var heights: [String: CGFloat] = [:]
    private var starts: [CGFloat] = [0]
    private var startsDirty = true
    private var hosts: [String: RowHost] = [:]
    private var row: ((String, CGFloat) -> AnyView)?
    private var revision: ((String) -> ChatTranscriptRowRevision?)?
    private var context: ChatTranscriptRowRevision.Context?
    private var contextGeneration = 0
    private var updateGeneration = 0
    private var topInset: CGFloat = 22
    private var bottomInset: CGFloat = 23
    private var measuredWidth: CGFloat = 0
    private var requestedAnchor: Anchor?
    private var requestedBottom = false
    /// Something changed frames, rows or positioning. Without it, a pass with the same clip and controller inputs
    /// as the last one is a no-op: no measurement, no placement, no completion callbacks.
    private var dirty = true
    private struct Pass: Equatable {
        let clip: NSRect
        let restoration: Anchor?
        let follow: Bool
        let bottomPadding: CGFloat
    }
    private var lastPass: Pass?
    private var lastClipY: CGFloat?
    /// +1 while the clip moves down the document, -1 while it moves up (and while following the bottom).
    private var travel: CGFloat = -1
    private var lastMovement = -CFTimeInterval.infinity
    /// Smoothed clip speed (points per second) of recent user movement.
    private var speed: CGFloat = 0
    private var buildingLookahead = false
    private var mountedAt = -CFTimeInterval.infinity
    private var mountWaitScheduled = false
    private var lookaheadObserver: CFRunLoopObserver?
    private var lookaheadQueued = false
    private var retirementScheduled = false
    /// Inside this view's own `layout()`, where AppKit drops a `needsLayout` the view sets on itself.
    private var inOwnLayout = false
    /// Effective layout passes (no-op passes excluded) and constructed row hosts, for tests.
    private(set) var layoutPasses = 0
    private(set) var createdHosts = 0
    /// Tests observe each row host's layout and the size it was laid out at.
    var hostLaidOut: ((String, NSSize) -> Void)?
    private var halo: ChatReplyHalo?
    private var haloMaxWidth: CGFloat = .infinity
    private(set) var haloView: ChatReplyHaloView?

    init(position: ChatScrollPosition, initiallyAtBottom: Bool) {
        self.position = position
        self.initiallyAtBottom = initiallyAtBottom
        super.init(frame: .zero)
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if DISPATCH_BENCHMARK
    // Optional Objective-C hooks let the identical benchmark harness run against the old SwiftUI renderer.
    @objc func resetTranscriptBenchmarkMetrics() { ChatTranscriptMetrics.values = [:] }
    @objc var transcriptBenchmarkMetrics: NSDictionary { ChatTranscriptMetrics.values as NSDictionary }
    #endif

    func update(ids: [String], topInset: CGFloat, bottomInset: CGFloat,
                context: ChatTranscriptRowRevision.Context? = nil,
                revision: ((String) -> ChatTranscriptRowRevision?)? = nil,
                row: @escaping (String, CGFloat) -> AnyView) {
        #if DISPATCH_BENCHMARK
        ChatTranscriptMetrics.count("updates")
        #endif
        let changedIDs = self.ids != ids
        let anchor = keptAnchor(retaining: changedIDs ? Set(ids) : nil) ?? position.saved
        if changedIDs {
            self.ids = ids
            indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            heights = heights.filter { indices[$0.key] != nil }
            startsDirty = true
        }
        if self.topInset != topInset { startsDirty = true }
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.row = row
        self.revision = revision
        if context != self.context { contextGeneration &+= 1; self.context = context }
        // Roots are compared lazily, when their row is next measured: hidden and lookahead hosts cost nothing here.
        updateGeneration &+= 1
        if requestedAnchor == nil { requestedAnchor = anchor }
        invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { stopLookahead(); return }
        mountedAt = CACurrentMediaTime()
        // Where the clip was before is no movement: placing it here would otherwise count as one and start the
        // lookahead at once.
        lastClipY = nil
        position.registerViewport(self)
        dirty = true
        layoutTranscript()
    }
    override func layout() {
        super.layout()
        inOwnLayout = true
        layoutTranscript()
        inOwnLayout = false
    }

    func scroll(to anchor: Anchor) {
        requestedAnchor = anchor
        requestedBottom = false
        invalidate()
    }
    func scrollToBottom() {
        requestedBottom = true
        requestedAnchor = nil
        invalidate()
    }

    func cancelPositioning() { requestedAnchor = nil; requestedBottom = false }
    /// Shown, not merely cached: a hidden host does not realize its row.
    func hasMounted(_ id: String) -> Bool {
        guard indices[id] != nil, let host = hosts[id] else { return false }
        return !host.isHidden && host.window != nil
    }

    func invalidateMeasurements() {
        hosts.values.forEach { $0.needsMeasurement = true }
        invalidate()
    }

    func invalidateMeasurement(for id: String) {
        guard !layingOut, let host = hosts[id] else { return }
        // A row's own layout reports its content's sizes (markers included): verified once it finishes.
        if host.inLayout { host.invalidatedInLayout = true } else { rowChanged(host) }
    }

    func visibleAnchor(retaining retained: Set<String>? = nil) -> Anchor? {
        visibleRows(retaining: retained).min { $0.anchor.offset < $1.anchor.offset }?.anchor
    }

    private func visibleRows(retaining retained: Set<String>?) -> [(anchor: Anchor, host: RowHost)] {
        guard let scroll = enclosingScrollView else { return [] }
        let clip = scroll.contentView.bounds
        return hosts.compactMap { id, host -> (Anchor, RowHost)? in
            guard !host.isHidden, indices[id] != nil, retained?.contains(id) != false,
                  host.frame.maxY > clip.minY + 1, host.frame.minY < clip.maxY else { return nil }
            return (.init(id: id, offset: host.frame.minY - clip.minY), host)
        }
    }

    /// The visible row a pass keeps in place: the topmost one, unless the reader is scrolling and it is cut off by the
    /// clip's top and its content changed size since it was measured (asynchronous tool output, typically while it was
    /// still above the clip). Then the next measured row is kept, so that row grows above the reader instead of pushing
    /// the content the reader sees down the screen. At rest the top row keeps its offset and grows downward: it may be
    /// what the reader just clicked (a disclosure).
    private func keptAnchor(retaining retained: Set<String>? = nil) -> Anchor? {
        let rows = visibleRows(retaining: retained).sorted { $0.anchor.offset < $1.anchor.offset }
        guard let top = rows.first else { return nil }
        if top.host.needsMeasurement, top.anchor.offset < 0, CACurrentMediaTime() - lastMovement < 0.2,
           let measured = rows.first(where: { !$0.host.needsMeasurement }) {
            return measured.anchor
        }
        return top.anchor
    }

    /// The row hosts the document shows, by row ID (frame = the row's frame in document coordinates): placed in the
    /// document and not cached. Diagnostics, `ChatScrollPosition.showsRows()` and tests read rows through this.
    var mountedRows: [String: NSView] {
        hosts.reduce(into: [:]) { rows, entry in
            if !entry.value.isHidden, entry.value.superview === self, indices[entry.key] != nil { rows[entry.key] = entry.value }
        }
    }

    /// Hidden hosts kept for a reversal, for tests and diagnostics.
    var cachedHostCount: Int { hosts.values.filter(\.isHidden).count }
    func isCached(_ id: String) -> Bool { hosts[id]?.isHidden == true }
    /// Whether rows within the lookahead still wait for deferred construction.
    var lookaheadPending: Bool { nextLookaheadRow() != nil }

    /// Whether this pass places the clip at the bottom. An explicit request always does; following waits while AppKit
    /// owns the clip (`ChatScrollPosition.ownsClip`), and its live scroll's end lays out again.
    private var following: Bool {
        requestedBottom || (!position.ownsClip && (position.followsBottom?() ?? (!didLayout && initiallyAtBottom)))
    }

    /// The single layout entry point: scroll view and document layout, clip bounds changes and the controller all
    /// call this, and it does nothing unless the clip moved or something was invalidated since the last pass.
    func layoutTranscript() {
        guard !layingOut, window != nil, let scroll = enclosingScrollView, let row,
              scroll.contentView.bounds.width > 1, scroll.contentView.bounds.height > 1 else { return }
        let clip = scroll.contentView.bounds
        let follow = following
        let pass = Pass(clip: clip, restoration: position.restorationAnchor, follow: follow,
                        bottomPadding: position.bottomPadding)
        guard dirty || pass != lastPass else {
            #if DISPATCH_BENCHMARK
            ChatTranscriptMetrics.count("skippedLayouts")
            #endif
            return
        }
        #if DISPATCH_BENCHMARK
        let layoutStart = CACurrentMediaTime()
        ChatTranscriptMetrics.count("layouts")
        defer { ChatTranscriptMetrics.count("layoutSeconds", CACurrentMediaTime() - layoutStart) }
        #endif
        layingOut = true
        dirty = false
        layoutPasses += 1
        var animateArrival = false
        defer {
            layingOut = false
            position.nativeLayoutCompleted(animateArrival: animateArrival)
            lastPass = Pass(clip: scroll.contentView.bounds, restoration: position.restorationAnchor,
                            follow: following,
                            bottomPadding: position.bottomPadding)
        }
        let width = max(1, clip.width - 44)
        let viewportHeight = clip.height
        let originalY = clip.minY
        if let lastClipY, abs(originalY - lastClipY) > 0.5 {
            travel = originalY > lastClipY ? 1 : -1
            let now = CACurrentMediaTime(), interval = now - lastMovement
            let current = interval > 0 && interval < 0.2 ? abs(originalY - lastClipY) / CGFloat(interval) : 0
            speed = speed * 0.7 + current * 0.3
            lastMovement = now
        }
        if follow { travel = -1 }
        let visibleAnchor = position.restorationAnchor ?? requestedAnchor ?? keptAnchor()
        if abs(measuredWidth - width) > 0.5 {
            measuredWidth = width
            heights.removeAll(keepingCapacity: true)
            startsDirty = true
            // Hidden hosts were laid out for the old width; shown ones are measured again where they are needed.
            for (id, host) in hosts where host.isHidden { retire(id) }
            hosts.values.forEach { $0.needsMeasurement = true }
        }
        rebuildStarts()
        // A clip beyond the document as it was is AppKit's elastic overscroll; AppKit returns it. Keep that much
        // past either edge instead of snapping it back on every bounds change. A changed viewport is not a bounce.
        let bouncing = didLayout && lastPass?.clip.size == clip.size
        let overscrollTop = bouncing ? min(0, originalY) : 0
        let overscrollBottom = bouncing ? max(0, originalY - max(0, frame.height - viewportHeight)) : 0
        let estimatedAnchor: Anchor? = ids.isEmpty ? nil
            : .init(id: ids[index(at: originalY)], offset: starts[index(at: originalY)] - originalY)
        let anchor = visibleAnchor ?? (didLayout ? estimatedAnchor : position.saved)
        // An estimate only locates the clip (with no row in it, an overscroll past the last row): never pull it back.
        let estimated = visibleAnchor == nil && didLayout
        if let anchor, indices[anchor.id] != nil, measure(anchor.id, width: width, row: row) { rebuildStarts() }

        func destination() -> CGFloat {
            let maximum = max(0, starts.last! + bottomInset - viewportHeight)
            let lower = overscrollTop, upper = maximum + overscrollBottom
            if follow {
                // Following settles `bottomPadding` above AppKit's own edge (`maximum`). A clip below that, within the
                // document or past it, is AppKit's: a momentum scroll, or a bounce returning to its edge. Pulling it
                // back to `bottom` on every bounds change fights that animation, which then never ends and flings the
                // clip thousands of points past the document. Following there only moves further down, for new content.
                // Only a clip something else moved lately is AppKit's: one where the passes left it is below the new
                // `bottom` because rows above it measured shorter (the lookahead after a tab switch), and keeping it
                // there showed the text `bottomPadding` lower until a later pass.
                let bottom = max(0, maximum - position.bottomPadding)
                let appKits = CACurrentMediaTime() - lastMovement < Self.appKitClipInterval
                guard !requestedBottom, bouncing, appKits, overscrollTop < 0 || originalY > bottom else { return bottom }
                return overscrollTop < 0 ? originalY : min(upper, originalY)
            }
            if let anchor, let index = indices[anchor.id] {
                let offset = estimated ? anchor.offset : max(anchor.offset, 1 - (heights[anchor.id] ?? 100))
                return min(upper, max(lower, starts[index] - offset))
            }
            return min(upper, max(lower, originalY))
        }
        func glides(to y: CGFloat) -> Bool {
            follow && didLayout && position.wantsArrivalGlide && y > originalY + 0.25
                && y - originalY <= viewportHeight * 2
        }

        // Measure every row the presented clip intersects, synchronously and without a painted estimate. Their real
        // heights may add or remove a neighbour from that clip; repeat until it is stable. The lookahead is deferred.
        var shown = 0..<0
        while true {
            let y = destination()
            // Cover a short animation's path, but pin large arrivals directly: hosting intervening history
            // turns a burst into unbounded construction work before its first frame.
            let near = glides(to: y) ? originalY : y
            let first = index(at: max(0, min(near, y)))
            let last = index(at: y + viewportHeight)
            let range = first..<min(ids.count, last + 1)
            shown = range
            var changed = false
            // A tall row can fill the entire viewport. Recompute the range as soon as its estimate changes,
            // before constructing neighbours that are already outside it. Following measures from the end.
            for offset in 0..<range.count {
                let index = follow ? range.upperBound - 1 - offset : range.lowerBound + offset
                if measure(ids[index], width: width, row: row) { changed = true; break }
            }
            if !changed { break }
            rebuildStarts()
        }
        let documentHeight = max(viewportHeight, starts.last! + bottomInset)
        if frame.size != NSSize(width: width + 44, height: documentHeight) {
            setFrameSize(NSSize(width: width + 44, height: documentHeight))
        }
        let finalY = destination()
        animateArrival = glides(to: finalY)
        if follow && !animateArrival { position.cancelGlide() }
        let target = NSPoint(x: scroll.contentView.bounds.minX, y: animateArrival ? originalY : finalY)
        if abs(scroll.contentView.bounds.minY - target.y) > 0.25 {
            scroll.contentView.scroll(to: target)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        place(clipY: target.y, viewportHeight: viewportHeight, width: width, shown: shown)
        let first = !didLayout
        didLayout = true
        lastClipY = scroll.contentView.bounds.minY
        requestedAnchor = nil; requestedBottom = false
        position.recordDiagnostic(first ? .mountCheck : .geometry, force: first)
        scheduleLookahead()
        scheduleRetirement()
    }

    /// Frames shown hosts (the presented rows and the measured lookahead), hides the rest and keeps the nearest of
    /// those within the cache's bounds.
    private func place(clipY: CGFloat, viewportHeight: CGFloat, width: CGFloat, shown: Range<Int>) {
        let window = lookahead(clipY: clipY, viewportHeight: viewportHeight)
        var hidden: [(id: String, host: RowHost, distance: CGFloat)] = []
        for (id, host) in Array(hosts) {
            guard let index = indices[id] else { retire(id); continue }
            let top = starts[index], bottom = starts[index + 1]
            // A host not measured at this width (the width changed) is only worth keeping where it is shown.
            guard heights[id] != nil, host.rootWidth == width else { retire(id); continue }
            if shown.contains(index) || (bottom > window.lower && top < window.upper) {
                let frame = NSRect(x: 22, y: top, width: width, height: bottom - top)
                if host.frame != frame { host.frame = frame }
                if host.isHidden {
                    host.isHidden = false
                    #if DISPATCH_BENCHMARK
                    if host.wasShown { ChatTranscriptMetrics.count("cacheHits") }
                    #endif
                    host.wasShown = true
                }
            } else {
                hidden.append((id, host, max(0, clipY - bottom, top - (clipY + viewportHeight))))
            }
        }
        var height: CGFloat = 0, kept = 0
        for entry in hidden.sorted(by: { $0.distance < $1.distance }) {
            height += entry.host.frame.height
            guard kept < Self.cacheCount, height <= viewportHeight * Self.cacheHeight,
                  entry.distance <= viewportHeight * Self.cacheDistance else { retire(entry.id); continue }
            kept += 1
            if !entry.host.isHidden { entry.host.isHidden = true }
            // Kept at its row, so a cached host never overlaps the rows shown in front of it.
            if let index = indices[entry.id], entry.host.frame.minY != starts[index] {
                entry.host.setFrameOrigin(NSPoint(x: 22, y: starts[index]))
            }
        }
        positionHalo()
        #if DISPATCH_BENCHMARK
        ChatTranscriptMetrics.peak("cachedHostsPeak", Double(kept))
        ChatTranscriptMetrics.peak("hostsPeak", Double(hosts.count))
        #endif
    }

    func setHalo(_ halo: ChatReplyHalo?, maxWidth: CGFloat, accent: Color) {
        self.halo = halo; haloMaxWidth = maxWidth
        haloView?.accent = accent
        if halo != nil, haloView == nil {
            let view = ChatReplyHaloView(accent: accent)
            view.isHidden = true
            addSubview(view, positioned: .above, relativeTo: nil)
            haloView = view
        }
        // Rows changing with it are placed by the pass `update` asked for, which places the halo too.
        if !dirty, !startsDirty { positionHalo() }
    }

    /// Frames the halo on its bubble: the rows from `first` to `last`, less the last row's 12 points below its bubble.
    private func positionHalo() {
        guard let haloView else { return }
        guard let halo, let first = indices[halo.first], let last = indices[halo.last], first <= last,
              last + 1 < starts.count, hosts[halo.first]?.isHidden == false, hosts[halo.last]?.isHidden == false else {
            if !haloView.isHidden { haloView.isHidden = true; haloView.reset() }
            return
        }
        let frame = NSRect(x: 22, y: starts[first], width: min(measuredWidth, haloMaxWidth),
                           height: max(0, starts[last + 1] - starts[first] - 12))
        if haloView.frame != frame { haloView.frame = frame }
        if haloView.isHidden { haloView.isHidden = false }
        haloView.apply(halo.phase)
    }

    private func lookahead(clipY: CGFloat, viewportHeight: CGFloat) -> (lower: CGFloat, upper: CGFloat) {
        let moving = CACurrentMediaTime() - lastMovement < 0.2 ? speed * CGFloat(Self.lookaheadLead) : 0
        let ahead = min(viewportHeight * Self.lookaheadMaximum, max(viewportHeight * Self.lookaheadAhead, moving))
        let behind = viewportHeight * Self.lookaheadBehind
        return travel > 0 ? (clipY - behind, clipY + viewportHeight + ahead)
            : (clipY - ahead, clipY + viewportHeight + behind)
    }

    private func retire(_ id: String) {
        guard let host = hosts.removeValue(forKey: id) else { return }
        #if DISPATCH_BENCHMARK
        ChatTranscriptMetrics.count("retiredHosts")
        #endif
        host.removeFromSuperview()
    }

    // MARK: Deferred lookahead

    /// The next lookahead row without a host measured at this width, or whose content changed size since it was
    /// measured: nearest the clip's leading edge first, then behind its trailing edge. Retargeted from the current
    /// clip on every call.
    private func nextLookaheadRow() -> Int? {
        guard !startsDirty, !dirty, measuredWidth > 0, !ids.isEmpty, let scroll = enclosingScrollView else { return nil }
        let clip = scroll.contentView.bounds
        let window = lookahead(clipY: clip.minY, viewportHeight: clip.height)
        let first = index(at: max(0, window.lower)), last = index(at: window.upper)
        let top = index(at: max(0, clip.minY)), bottom = index(at: clip.maxY)
        func needed(_ index: Int) -> Bool {
            guard let host = hosts[ids[index]] else { return true }
            return heights[ids[index]] == nil || host.needsMeasurement
        }
        if travel > 0 {
            if let index = (bottom...last).first(where: needed) { return index }
            return (first...top).reversed().first(where: needed)
        }
        if let index = (first...top).reversed().first(where: needed) { return index }
        return (bottom...last).first(where: needed)
    }

    private func scheduleLookahead() {
        guard lookaheadObserver == nil, window != nil, nextLookaheadRow() != nil else { return }
        let wait = mountedAt + Self.lookaheadAfterMount - CACurrentMediaTime()
        if wait > 0, lastMovement < mountedAt {
            guard !mountWaitScheduled else { return }
            mountWaitScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    self?.mountWaitScheduled = false
                    self?.scheduleLookahead()
                }
            }
            return
        }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true,
                                                          Self.lookaheadOrder) { [weak self] observer, _ in
            MainActor.assumeIsolated {
                guard let self else { CFRunLoopObserverInvalidate(observer); return }
                self.lookaheadOpportunity()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        lookaheadObserver = observer
    }

    private func stopLookahead() {
        lookaheadObserver.map(CFRunLoopObserverInvalidate)
        lookaheadObserver = nil
    }

    /// Runs as a turn ends, after its layout. Construction happens in a turn of its own, so it never runs inside the
    /// input or layout callback that scrolled; input arriving meanwhile is handled before the next build.
    private func lookaheadOpportunity() {
        guard !lookaheadQueued, !layingOut else { return }
        guard window != nil, nextLookaheadRow() != nil else { stopLookahead(); return }
        lookaheadQueued = true
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated {
                self?.lookaheadQueued = false
                self?.buildLookahead()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Builds lookahead rows until the time budget is spent (at least one), then lays out once: a measured row above
    /// the clip changes the document above the reader, and the pass keeps the reader's message where it was.
    private func buildLookahead() {
        guard !layingOut, window != nil, let row, nextLookaheadRow() != nil else { return }
        let start = CACurrentMediaTime()
        layingOut = true
        buildingLookahead = true
        while let index = nextLookaheadRow() {
            _ = measure(ids[index], width: measuredWidth, row: row)
            #if DISPATCH_BENCHMARK
            ChatTranscriptMetrics.count("deferredBuilds")
            #endif
            if CACurrentMediaTime() - start >= Self.lookaheadBudget { break }
        }
        buildingLookahead = false
        layingOut = false
        #if DISPATCH_BENCHMARK
        ChatTranscriptMetrics.count("deferredSeconds", CACurrentMediaTime() - start)
        #endif
        invalidate()
        layoutTranscript()
    }

    /// Releases hidden hosts once the clip has rested, so a reader at rest holds only the lookahead.
    private func scheduleRetirement() {
        guard !retirementScheduled, hosts.values.contains(where: \.isHidden) else { return }
        retirementScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleRetirement) { [weak self] in
            MainActor.assumeIsolated { self?.retireIfIdle() }
        }
    }
    private func retireIfIdle() {
        retirementScheduled = false
        if layingOut || (window != nil && CACurrentMediaTime() - lastMovement < Self.idleRetirement) {
            scheduleRetirement()
            return
        }
        for (id, host) in hosts where host.isHidden { retire(id) }
        #if DISPATCH_BENCHMARK
        ChatTranscriptMetrics.count("idleRetirements")
        #endif
    }

    // MARK: Rows

    private func root(_ id: String, _ width: CGFloat, _ row: (String, CGFloat) -> AnyView) -> AnyView {
        AnyView(row(id, width).frame(width: width, alignment: .topLeading).fixedSize(horizontal: false, vertical: true))
    }

    /// Ensures the row has a host with an up-to-date root and a measured height; returns whether its height changed.
    private func measure(_ id: String, width: CGFloat, row: (String, CGFloat) -> AnyView) -> Bool {
        #if DISPATCH_BENCHMARK
        let measureStart = CACurrentMediaTime()
        defer { ChatTranscriptMetrics.count("measureSeconds", CACurrentMediaTime() - measureStart) }
        #endif
        var changed = false
        let host: RowHost
        if let existing = hosts[id] {
            host = existing
            if host.rootWidth != width || host.rootUpdate != updateGeneration {
                let current = revision?(id)
                if host.rootWidth != width || host.rootContext != contextGeneration || current == nil
                    || current != host.revision {
                    #if DISPATCH_BENCHMARK
                    let updateStart = CACurrentMediaTime()
                    ChatTranscriptMetrics.count("rootUpdates")
                    defer { ChatTranscriptMetrics.count("rootUpdateSeconds", CACurrentMediaTime() - updateStart) }
                    #endif
                    host.rootView = root(id, width, row)
                    host.revision = current
                    host.rootWidth = width
                    host.rootContext = contextGeneration
                    host.needsMeasurement = true
                } else {
                    #if DISPATCH_BENCHMARK
                    ChatTranscriptMetrics.count("keptRoots")
                    #endif
                }
                host.rootUpdate = updateGeneration
            }
        } else {
            #if DISPATCH_BENCHMARK
            let creationStart = CACurrentMediaTime()
            ChatTranscriptMetrics.count("createdHosts")
            ChatTranscriptMetrics.count(buildingLookahead ? "deferredHosts" : "synchronousHosts")
            defer { ChatTranscriptMetrics.count("creationSeconds", CACurrentMediaTime() - creationStart) }
            #endif
            let current = revision?(id)
            host = RowHost(rootView: root(id, width, row))
            // The document supplies the width and height. Only intrinsic changes need notification;
            // asking SwiftUI for minimum and maximum sizes repeats row layout during every scroll.
            host.sizingOptions = [.intrinsicContentSize]
            host.safeAreaRegions = []
            host.owner = self
            host.id = id
            host.autoresizingMask = []
            host.revision = current
            host.rootWidth = width
            host.rootContext = contextGeneration
            host.rootUpdate = updateGeneration
            // Hidden until placed: an unplaced host must not count as visible, take hits or be laid out.
            host.isHidden = true
            host.frame = NSRect(x: 22, y: indices[id].map { starts[min($0, starts.count - 1)] } ?? 0, width: width, height: 0)
            hosts[id] = host
            createdHosts += 1
            if let haloView { addSubview(host, positioned: .below, relativeTo: haloView) } else { addSubview(host) }
        }
        if host.needsMeasurement {
            #if DISPATCH_BENCHMARK
            let sizingStart = CACurrentMediaTime()
            ChatTranscriptMetrics.count("sizings")
            defer { ChatTranscriptMetrics.count("sizingSeconds", CACurrentMediaTime() - sizingStart) }
            #endif
            host.needsMeasurement = false
            let height = host.fittedHeight(width: width)
            if heights[id] != height { heights[id] = height; startsDirty = true; changed = true }
            // Size once, at the measured height: the host is never laid out at an estimate.
            let size = NSSize(width: width, height: height)
            if host.frame.size != size { host.setFrameSize(size) }
        }
        return changed
    }

    private func rebuildStarts() {
        guard startsDirty else { return }
        starts = [topInset]
        starts.reserveCapacity(ids.count + 1)
        for id in ids { starts.append(starts.last! + (heights[id] ?? 100)) }
        startsDirty = false
    }
    private func index(at y: CGFloat) -> Int {
        guard !ids.isEmpty else { return 0 }
        var low = 0, high = ids.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle + 1] <= y { low = middle + 1 } else { high = middle }
        }
        return min(ids.count - 1, low)
    }
    private func invalidate() {
        dirty = true
        needsLayout = true
        // Invalidated from inside the document's own layout (the completion callbacks): AppKit clears the document's
        // flag after `layout()` returns, but lays out an ancestor marked meanwhile, and the scroll view's pass runs
        // this one again.
        if inOwnLayout { enclosingScrollView?.needsLayout = true }
    }
    /// A host's content changed size. Only a shown row inside the clip needs a pass now. A row in the lookahead is
    /// measured again by the deferred builder, before it enters the clip; any other when it is next shown.
    private func rowChanged(_ host: RowHost) {
        guard !layingOut, host.superview === self else { return }
        host.needsMeasurement = true
        #if DISPATCH_BENCHMARK
        ChatTranscriptMetrics.count("rowInvalidations")
        #endif
        guard !host.isHidden, let clip = enclosingScrollView?.contentView.bounds else { return }
        guard host.frame.maxY > clip.minY, host.frame.minY < clip.maxY else { scheduleLookahead(); return }
        invalidate()
    }
    /// After each of a host's own layouts: SwiftUI lays a host out whenever its content changes, but does not always
    /// report content that grows on its own (formatted tool output arriving, a disclosure) through
    /// `invalidateIntrinsicContentSize`, and reports intrinsic sizes during the first layout at the measured size.
    /// Only an ideal height that differs from the measurement is a change. `reported`: an invalidation arrived during
    /// the layout.
    private func rowLaidOut(_ host: RowHost, reported: Bool) {
        guard !layingOut, host.superview === self, !host.needsMeasurement, let height = heights[host.id],
              host.rootWidth == measuredWidth else { return }
        let ideal = host.intrinsicContentSize.height
        // No ideal height yet: the next measurement falls back to a layout; never lay out again from here.
        guard ideal > 0, ideal.isFinite else { return }
        guard max(1, ceil(ideal)) == height else { rowChanged(host); return }
        #if DISPATCH_BENCHMARK
        if reported { ChatTranscriptMetrics.count("settledInvalidations") }
        #endif
    }

    private final class RowHost: NSHostingView<AnyView> {
        weak var owner: ChatTranscriptDocument?
        var id = ""
        var revision: ChatTranscriptRowRevision?
        var rootWidth: CGFloat = 0
        var rootContext = 0
        var rootUpdate = 0
        var needsMeasurement = true
        /// Placed at least once: showing it again is a cache hit.
        var wasShown = false
        private(set) var inLayout = false
        var invalidatedInLayout = false

        /// The root's ideal height. The root fixes its width and its vertical size, so this does not depend on the
        /// host's frame and needs no layout flush. (`NSHostingView` has no public `sizeThatFits(in:)`; only
        /// `NSHostingController` does.) A host that cannot report one yet is laid out once at its frame instead.
        func fittedHeight(width: CGFloat) -> CGFloat {
            var height = intrinsicContentSize.height
            if !(height > 0 && height.isFinite) {
                #if DISPATCH_BENCHMARK
                ChatTranscriptMetrics.count("sizingFallbacks")
                #endif
                layoutSubtreeIfNeeded()
                height = intrinsicContentSize.height
                if !(height > 0 && height.isFinite) { height = fittingSize.height }
            }
            return max(1, ceil(height))
        }
        override func layout() {
            inLayout = true
            super.layout()
            inLayout = false
            owner?.hostLaidOut?(id, bounds.size)
            let reported = invalidatedInLayout
            invalidatedInLayout = false
            owner?.rowLaidOut(self, reported: reported)
        }
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            if inLayout { invalidatedInLayout = true } else { owner?.rowChanged(self) }
        }
    }
}
