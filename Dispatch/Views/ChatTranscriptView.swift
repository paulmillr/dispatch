import SwiftUI

struct ChatTranscriptView: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var session: ChatSession
    let coordinator: ChatCoordinator
    var topContentInset: CGFloat = 0
    /// Room for an input floating over the transcript's bottom edge (Liquid Glass).
    var bottomContentInset: CGFloat = 0
    /// A glass strip over the top edge: content fades out under it, like macOS 26's soft scroll edge, so text
    /// stays faint behind the glass but never shows through the strip's bare controls.
    var fadeTopInset: CGFloat = 0
    @State private var openedAt = ProcessInfo.processInfo.systemUptime
    @State private var viewportGeneration = System.uuid()
    @State private var scrollConnection: UUID?
    private struct SearchRequest: Equatable {
        let query: String
        let revision: Int
        let history: Int
        let approvals: Int
        let generation: UUID?
    }
    private struct SearchHistory: Equatable {
        let query: String
        let conversation: String?
        let generation: UUID?
    }

    var body: some View {
        let directory = directory
        let query = session.search.visible ? session.search.query : ""
        // Without a query the transcript's changes can't change the (empty) results: don't restart per record.
        let searching = !query.isEmpty
        let request = SearchRequest(query: query, revision: searching ? session.revision : 0,
                                    history: searching ? session.historyRevision : 0,
                                    approvals: searching ? session.approvals.count : 0, generation: session.historyGeneration)
        return GeometryReader { geometry in
            ScrollViewReader { scroll in
                // Helpers split this chain: as one expression it took seconds to type-check.
                followingLatest(searchAndLifecycle(transcript(geometry, directory: directory), query: query,
                                                   request: request, scroll: scroll), scroll: scroll)
            }
        }.environment(\.chatSearchQuery, query)
    }

    private func transcript(_ geometry: GeometryProxy, directory: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            // A fixed scroll target inside the lazy rows can make
            // accessibility prefetch alternate their visibility forever.
            VStack(alignment: .leading, spacing: 0) {
                if theme.radioLog { ChatRadioLogHeader(surface: session.id) }
                // While its window is off screen, the rows it showed then (`presentedTranscriptRows`).
                let rows = session.presentedTranscriptRows
                let watches = theme.radioLog ? ChatRadioLog.watches(rows) : [:]
                LazyVStack(alignment: .leading, spacing: 0) {
                    if session.hasEarlier || session.loadingEarlier {
                        earlierMessages
                    }
                    ForEach(rows) { row in
                        // One layout child per ID, regardless of row kind or
                        // disclosure state, keeps the outer stack lazy.
                        VStack(alignment: .leading, spacing: 0) {
                            if let watch = watches[row.id] { ChatRadioWatchDivider(day: watch.day, watch: watch.watch) }
                            if let match = session.searchMatch, match.document.row == row.id {
                                let excerpt = match.excerpt
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(match.document.label).font(theme.typography.detail).foregroundStyle(theme.muted)
                                    Text(searchExcerpt(excerpt)).textSelection(.enabled).font(theme.typography.body)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(theme.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(theme.yellow, lineWidth: 1) }
                                    .padding(.bottom, 8).accessibilityIdentifier("chat-find-match")
                            }
                            // A step taking over its group's shown step hands off in place instead of entering.
                            let handoff = row.timeline?.replaced == nil ? nil : session.transcriptArrivals.handoff(for: row.id)
                            ChatTranscriptRowView(row: row, session: session, coordinator: coordinator, directory: directory,
                                contentWidth: max(0, geometry.size.width - 44), handoff: handoff, openedAt: openedAt)
                                .modifier(ChatArrivalMotion(receipt: handoff == nil ? session.transcriptArrivals.receipt(for: row.id) : nil,
                                                            since: openedAt, reduceMotion: reduceMotion, grouped: true))
                        }.background(ChatScrollMarker(id: row.id, position: session.scrollPosition)).id(row.id)
                    }
                }
                // Scrolling to the bottom aligns this marker's bottom edge, so it spans a floating input.
                Color.clear.frame(height: 1 + bottomContentInset).id("bottom")
            }
            .padding(Self.padding).frame(maxWidth: .infinity)
            .padding(.top, topContentInset)
            .id(viewportGeneration)
            .background(ChatScrollViewport(position: session.scrollPosition))
        }
        .modifier(ChatInitialScrollAnchor(atBottom: session.atBottom))
        .modifier(ChatScrollGeometryTrace(position: session.scrollPosition,
            enabled: ChatViewportTrace.enabled || session.scrollPosition.diagnosticSink != nil))
        .coordinateSpace(name: "chatScroll")
        .mask {
            VStack(spacing: 0) {
                if fadeTopInset > 0 {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.5),
                                           .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: fadeTopInset + 8)
                }
                Color.black
            }
        }
        .onPreferenceChange(ChatTopPreference.self) { top in
            if top > -session.scrollPosition.earlierPrefetchDistance && top < geometry.size.height {
                session.scrollPosition.prefetchEarlier()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if session.hasNewMessages && !session.atBottom {
                Button { session.revealLatestMessages() } label: {
                    HStack(spacing: 6) {
                        Text(theme.radioLog ? "new traffic" : "new messages")
                        Image(systemName: "arrow.down").font(.system(size: theme.typography.detailSize - 0.5))
                    }
                    .font(theme.typography.detail)
                    .foregroundStyle(Color(red: 26/255, green: 18/255, blue: 24/255))
                    .padding(.horizontal, 10)
                    .frame(minHeight: max(22, theme.typography.detailLineHeight + 8))
                    // Accent-tinted interactive glass; glass carries its own depth, so no drop shadow.
                    .liquidGlass(in: Capsule(), interactive: true, tint: theme.accent)
                    .background(LiquidGlassStore.shared.active ? Color.clear : theme.accent, in: Capsule())
                    .shadow(color: .black.opacity(LiquidGlassStore.shared.active ? 0 : 0.5), radius: 8, y: 6)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Jump to latest · ⏎ with an empty draft")
                .accessibilityLabel("New messages. Jump to latest")
                .accessibilityIdentifier("chat-new-messages")
                .padding(.trailing, Chrome.paneContentInset).padding(.bottom, 2 + bottomContentInset)
            }
        }
    }

    private func searchAndLifecycle(_ content: some View, query: String, request: SearchRequest,
                                    scroll: ScrollViewProxy) -> some View {
        content
            .onAppear {
                openedAt = ProcessInfo.processInfo.systemUptime
                scrollConnection = connectScrollPosition(scroll)
                updateScrollbarTheme()
            }
            .task(id: request) {
                do {
                    let matches = try await session.searchIndex.matches(query.isEmpty ? [] : session.searchDocuments, query: query)
                    try Task.checkCancellation()
                    guard query == (session.search.visible ? session.search.query : "") else { return }
                    let selected = session.searchMatch?.id
                    session.searchMatches = matches
                    session.search.total = matches.count
                    session.search.selected = selected.flatMap { id in matches.firstIndex { $0.id == id } }
                } catch is CancellationError { } catch { session.search.status = error.localizedDescription }
            }
            .task(id: SearchHistory(query: query, conversation: session.sessionID, generation: session.historyGeneration)) {
                guard !query.isEmpty else { session.search.status = nil; return }
                do {
                    while true {
                        try Task.checkCancellation()
                        if let error = session.earlierError { session.search.status = "Search incomplete: " + error; return }
                        guard session.hasEarlier || session.loadingHistory || session.loadingEarlier else { break }
                        session.search.status = "Searching earlier messages…"
                        if !session.loadingHistory, !session.loadingEarlier, !session.scrollPosition.isRestoring,
                           !coordinator.loadEarlier(session, preservingBottom: true) {
                            session.search.status = "Search incomplete: earlier messages are unavailable."; return
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    session.search.status = nil
                } catch { }
            }
            .onChange(of: session.search.navigation) { _, _ in
                let count = session.searchMatches.count
                guard !query.isEmpty, session.search.total != nil, count > 0 else { return }
                let selected = session.search.selected ?? (session.search.direction > 0 ? -1 : 0)
                session.search.selected = (selected + session.search.direction + count) % count
            }
            .onChange(of: session.searchMatch?.id) { _, id in
                guard let id, let match = session.searchMatch else { return }
                for row in session.transcriptRows {
                    if let group = row.group, group.children.contains(where: { $0.id == match.document.row }) {
                        session.setGroupExpanded(group, true)
                    }
                }
                session.atBottom = false; session.followRevision = nil
                session.scrollPosition.restore(.init(id: match.document.row, offset: 0))
                DispatchQueue.main.async {
                    guard session.searchMatch?.id == id else { return }
                    scroll.scrollTo(match.document.row, anchor: .top)
                }
            }
            .onChange(of: theme) { _, _ in updateScrollbarTheme() }
            .onChange(of: session.scrollToLatestRequest) { _, _ in
                scroll.scrollTo("bottom", anchor: .bottom)
            }
            .onDisappear {
                openedAt = .infinity
                // A view of this chat that appeared since (a moved tab mounts it first) keeps the connection.
                if let scrollConnection { session.scrollPosition.disconnect(scrollConnection) }
                scrollConnection = nil
            }
    }

    private func followingLatest(_ content: some View, scroll: ScrollViewProxy) -> some View {
        content
            .onChange(of: session.historyGeneration) { _, _ in
                session.scrollPosition.beginOpeningHistoryPreload()
            }
            .onChange(of: session.hasEarlier) { _, _ in
                session.scrollPosition.geometryChanged()
            }
            .onChange(of: session.historyRevision) { _, _ in
                session.scrollPosition.recordDiagnostic(.history)
                session.scrollPosition.restoreAfterPrepend()
            }
            .onChange(of: session.approvals.count) { _, _ in
                if session.atBottom { scroll.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: bottomContentInset) { _, _ in
                // A floating input that grows on focus would otherwise cover the latest message.
                if session.atBottom { scroll.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.presentedRevision) { _, revision in
                session.scrollPosition.recordDiagnostic(.transcript)
                // Capture intent when the item arrives. New row geometry can
                // move the bottom outside the viewport before this callback.
                if session.atBottom || session.followRevision == revision {
                    let interaction = session.scrollPosition.interactionRevision
                    DispatchQueue.main.async {
                        guard session.scrollPosition.interactionRevision == interaction,
                              session.atBottom || session.followRevision == revision,
                              !session.scrollPosition.glidesToBottom else { return }
                        session.scrollPosition.recordDiagnostic(.followRequested)
                        scroll.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
    }
    private func updateScrollbarTheme() { session.scrollPosition.scrollbarColor = NSColor(theme.muted) }

    private func searchExcerpt(_ excerpt: (text: String, range: NSRange)) -> AttributedString {
        var text = AttributedString(excerpt.text)
        if let range = Range(excerpt.range, in: excerpt.text), let converted = Range(range, in: text) {
            text[converted].backgroundColor = theme.yellow
            text[converted].foregroundColor = theme.terminal
        }
        return text
    }

    private var earlierMessages: some View {
        Button { coordinator.loadEarlier(session) } label: {
            HStack(spacing: 8) {
                Rectangle().fill(theme.border).frame(height: 1)
                if session.loadingEarlier { ProgressView().controlSize(.mini) }
                Text(session.earlierError ?? (session.loadingEarlier ? "Loading earlier \(earlierNoun)…" : "Earlier \(earlierNoun)"))
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(theme.border).frame(height: 1)
            }.font(theme.typography.detail).foregroundStyle(theme.muted)
                .frame(minHeight: 28).frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(session.loadingEarlier).id("earlier")
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ChatTopPreference.self, value: proxy.frame(in: .named("chatScroll")).maxY)
            })
    }

    /// The transcript's padding, around its rows and below the "bottom" marker.
    static let padding: CGFloat = 22

    private func connectScrollPosition(_ scroll: ScrollViewProxy, reusing token: UUID? = nil) -> UUID {
        let connection = session.scrollPosition.connect(reusing: token) { token in
            _ = connectScrollPosition(scroll, reusing: token)
        }
        session.scrollPosition.bottomPadding = Self.padding
        session.scrollPosition.diagnosticState = { [weak session] in
            guard let session else { return nil }
            return .init(revision: session.revision, historyRevision: session.historyRevision,
                rows: session.presentedTranscriptRows.count, turns: session.turns.count, busy: session.busy,
                atBottom: session.atBottom, following: session.followRevision != nil,
                loadingHistory: session.loadingHistory, loadingEarlier: session.loadingEarlier)
        }
        session.scrollPosition.diagnosticRows = { [weak session] ids in
            guard let session else { return [:] }
            var rows: [String: ChatViewportTrace.RowInfo] = [:]
            for (index, row) in session.presentedTranscriptRows.enumerated() where ids.contains(row.id) {
                rows[row.id] = .init(index: index, kind: Self.diagnosticKind(row, session: session))
            }
            return rows
        }
        session.scrollPosition.recordDiagnostic(.connected, force: true)
        // Keep initial follow intent while lazy rows replace estimated heights.
        // Actual user scrolling clears this through userScrolled below.
        if session.atBottom { session.followRevision = session.revision }
        session.scrollPosition.realizeAnchor = { id in scroll.scrollTo(id, anchor: .top) }
        session.scrollPosition.hasContent = { [weak session] in session?.presentedTranscriptRows.isEmpty == false }
        session.scrollPosition.holdChanged = { [weak session] hold in
            if hold { session?.holdTranscript() } else { session?.releaseTranscript() }
        }
        // Gone for good, not just not loaded yet: a restored anchor waits for the transcript it names.
        session.scrollPosition.rowExists = { [weak session] id in
            guard let session, !session.loadingHistory, !session.presentedTranscriptRows.isEmpty else { return true }
            return session.presentedTranscriptRows.contains { $0.id == id }
        }
        session.scrollPosition.recoverViewport = { [weak session] anchor, rebuild in
            guard let session, session.showChat, !session.visibleTranscriptRows.isEmpty else { return }
            let interaction = session.scrollPosition.interactionRevision
            let following = session.atBottom
            // A row that left (a collapsed group's step) gives way to the nearest one shown; with none, the latest
            // messages, never the first loaded row.
            let target = anchor.flatMap { saved in
                session.nearestVisibleRow(to: saved.id).map { $0 == saved.id ? saved : .init(id: $0, offset: 0) }
            }
            if rebuild { openedAt = ProcessInfo.processInfo.systemUptime; viewportGeneration = System.uuid() }
            let generation = viewportGeneration
            DispatchQueue.main.async {
                guard viewportGeneration == generation, session.showChat,
                      session.scrollPosition.interactionRevision == interaction else { return }
                if let target, !following {
                    scroll.scrollTo(target.id, anchor: .top)
                    session.scrollPosition.restore(target)
                } else {
                    scroll.scrollTo("bottom", anchor: .bottom)
                    session.scrollPosition.jumpToLatest()
                }
            }
        }
        session.scrollPosition.followsBottom = { [weak session] in
            session?.atBottom == true && session?.followRevision != nil
        }
        session.scrollPosition.userScrolled = { [weak session] in
            // Cancel queued following without changing measured proximity.
            // During bottom bounce, positionChanged still reports the bottom;
            // forcing false here would invalidate SwiftUI twice per wheel event.
            session?.followRevision = nil
        }
        session.scrollPosition.positionChanged = { [weak session] anchor in
            guard let session else { return }
            if session.scrollAnchor != anchor.id { session.scrollAnchor = anchor.id }
            // Observe the native viewport for both wheel and programmatic
            // scrolling. A second SwiftUI geometry preference would invalidate
            // the hosted layout on every pixel, just to calculate this again.
            // Include the 40-point follow margin.
            if let atBottom = session.scrollPosition.isAtBottom(tolerance: 40), session.atBottom != atBottom {
                // A growing reply briefly puts the bottom outside the viewport
                // before SwiftUI applies its scroll. Preserve the captured
                // follow intent through that layout; userScrolled cancels it
                // when the reader actually moves away.
                if !atBottom && session.followRevision != nil { return }
                session.atBottom = atBottom
                if atBottom { session.followRevision = session.revision }
            }
        }
        session.scrollPosition.loadEarlier = { [weak session, weak coordinator] userInitiated in
            guard let session, userInitiated || session.earlierError == nil else { return false }
            return coordinator?.loadEarlier(session, preservingBottom: !userInitiated) ?? false
        }
        if session.atBottom { scroll.scrollTo("bottom", anchor: .bottom) }
        else if let anchor = session.scrollPosition.saved?.id ?? session.scrollAnchor {
            scroll.scrollTo(anchor, anchor: .top)
            session.scrollPosition.restoreOnAppearance()
        }
        session.scrollPosition.beginOpeningHistoryPreload()
        return connection
    }

    /// A content-free category: what kind of row, and whether it is expanded.
    static func diagnosticKind(_ row: ChatTranscriptRow, session: ChatSession) -> String {
        if row.workedFor != nil { return "worked" }
        if let group = row.group { return session.groupIsExpanded(group, turnID: row.turnID) ? "group-expanded" : "group" }
        if row.approval != nil { return "approval" }
        guard let item = row.item else { return "other" }
        if item.kind == .tool { return session.toolIsExpanded(row) ? "tool-expanded" : "tool" }
        if item.kind == .reasoning { return session.expanded.contains(row.id) ? "reasoning-expanded" : "reasoning" }
        return item.kind.rawValue
    }

    private var directory: String {
        TerminalRuntime.shared.workspace?.directory(forSurface: session.id) ?? System.home.path
    }
    private var earlierNoun: String { theme.radioLog ? "transmissions" : "messages" }
}

/// Fade and translate the new row's pixels without animating its measured height
/// or passing an animation into streamed markdown, tool output, or scrolling.
struct ChatArrivalMotion: ViewModifier {
    let reduceMotion: Bool
    let receipt: ChatTranscriptArrivals.Receipt?
    let openedAt: TimeInterval
    let distance: CGFloat
    let duration: Double
    /// Moves the content as one view (`ChatArrivalEffect`): for content with native views (a transcript row's text).
    let grouped: Bool
    @State private var visible: Bool

    init(receipt: ChatTranscriptArrivals.Receipt?, since openedAt: TimeInterval, reduceMotion: Bool,
         distance: CGFloat? = nil, duration: Double? = nil, grouped: Bool = false) {
        self.receipt = receipt; self.openedAt = openedAt; self.reduceMotion = reduceMotion
        self.grouped = grouped
        self.distance = distance ?? 6
        self.duration = duration ?? ChatScrollPosition.arrivalGlide
        _visible = State(initialValue: receipt?.eligible(since: openedAt) != true)
    }

    func body(content: Content) -> some View {
        // Only the entrance's own transaction: a blanket override would also stop the row's own animations (its live
        // step chart, a step's status).
        content.transaction(value: visible) { $0.animation = nil }
            .modifier(ChatArrivalEffect(progress: visible ? 1 : 0,
                                        distance: reduceMotion ? 0 : distance, grouped: grouped))
            .task {
                guard receipt?.consume(since: openedAt) == true else { visible = true; return }
                // Cubic ease-out, the curve the followed bottom glides on.
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .timingCurve(0.33, 1, 0.68, 1, duration: duration)) {
                    visible = true
                }
            }
            .onDisappear { visible = true }
    }
}

/// A live step taking over its group's one shown step, like an odometer: the step it replaced rolls up and out of the
/// slot as the new one rolls in from below, the two a line apart. Pixels only, as an entrance: the row is laid out at its final size
/// from the first frame, and the replaced step is drawn over it only while it leaves.
struct ChatStepHandoff<Replaced: View>: ViewModifier {
    let receipt: ChatTranscriptArrivals.Receipt?
    let openedAt: TimeInterval
    let reduceMotion: Bool
    let distance: CGFloat
    let replaced: () -> Replaced?
    @State private var progress: Double

    init(receipt: ChatTranscriptArrivals.Receipt?, since openedAt: TimeInterval, reduceMotion: Bool, distance: CGFloat,
         replaced: @escaping () -> Replaced?) {
        self.receipt = receipt; self.openedAt = openedAt; self.reduceMotion = reduceMotion
        self.distance = distance; self.replaced = replaced
        _progress = State(initialValue: receipt?.eligible(since: openedAt) == true ? 0 : 1)
    }

    func body(content: Content) -> some View {
        // The replaced step goes to the effect even once the state reaches 1: the effect draws it while its own,
        // interpolated progress is short of that.
        content.transaction(value: progress) { $0.animation = nil }
            .modifier(ChatStepHandoffEffect(progress: progress, distance: reduceMotion ? 0 : distance,
                                            replaced: replaced()))
            .onAppear {
                guard receipt?.consume(since: openedAt) == true else { progress = 1; return }
                // Linear in time: the effect eases each part on its own clock.
                withAnimation(.linear(duration: reduceMotion ? 0.15 : ChatStepHandoffEffect<Replaced>.duration)) { progress = 1 }
            }
            .onDisappear { progress = 1 }
    }
}

private struct ChatStepHandoffEffect<Replaced: View>: AnimatableModifier {
    static var duration: Double { 0.34 }
    nonisolated var progress: Double
    let distance: CGFloat
    let replaced: Replaced?
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // One roll, so the slot is never empty; each line fades as it crosses the slot's edge.
        let roll = Self.easeOut(progress)
        content
            .opacity(min(1, 0.15 + 1.4 * roll))
            .offset(y: distance * (1 - roll))
            .overlay(alignment: .topLeading) {
                if let replaced, progress < 1 {
                    replaced.opacity(max(0, 1 - 1.4 * roll)).offset(y: -distance * roll)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .clipShape(ChatStepHandoffClip(active: progress < 1 && distance > 0))
    }

    nonisolated static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}

/// A live group's shown step as the group closes (its turn ends, or a newer group takes over). The step's own row goes
/// at once, so this draws the step again under the header, a row's height in all (the spacing above it included), and
/// folds it away: the bubble shrinks instead of jumping, and the rows below follow it.
struct ChatClosingStep<Step: View>: View {
    let group: ChatToolGroup
    let disclosure: ChatToolGroupDisclosure
    let reduceMotion: Bool
    @ViewBuilder let step: (ChatTranscriptRow.Replaced) -> Step
    @State private var closing: ChatTranscriptRow.Replaced?
    @State private var shown: Double = 1

    var body: some View {
        ChatFoldLayout(shown: shown) {
            if let closing { step(closing).opacity(shown).allowsHitTesting(false).accessibilityHidden(true) }
        }
        .clipped()
        .onChange(of: disclosure) { old, new in
            guard old == .current, new == .collapsed, !reduceMotion,
                  let item = group.children.last?.item, let last = group.steps.last else { return }
            closing = .init(item: item, step: last); shown = 1
            // The step's full height for the frame that removes its row, then the fold.
            Task { @MainActor in
                withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.32)) { shown = 0 } completion: { closing = nil }
            }
        }
    }
}

/// Its content's height times `shown`, the content pinned to the top (clip it).
struct ChatFoldLayout: Layout {
    var shown: Double
    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * shown)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// The slot's edges while steps roll through it; no clip otherwise, so a timeline rail can reach its neighbours.
private struct ChatStepHandoffClip: Shape {
    let active: Bool
    nonisolated func path(in rect: CGRect) -> Path {
        Path(active ? rect : rect.insetBy(dx: -10_000, dy: -10_000))
    }
}

private struct ChatArrivalEffect: AnimatableModifier {
    nonisolated var progress: Double
    let distance: CGFloat
    let grouped: Bool
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    @ViewBuilder func body(content: Content) -> some View {
        if grouped {
            // The geometry group moves the row as one view: without it each frame of the entrance moved every one of
            // the row's text views on its own (a long reply's eighty, each with its layer, cursor rect and frame
            // change). Its opacity stays inside, per view, as before.
            content.opacity(progress).geometryGroup().offset(y: distance * (1 - progress))
        } else {
            content.opacity(progress).offset(y: distance * (1 - progress))
        }
    }
}

private struct ChatTopPreference: PreferenceKey {
    static let defaultValue: CGFloat = -.greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatTranscriptRowView: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatSearchQuery) private var query
    let row: ChatTranscriptRow
    @Bindable var session: ChatSession
    let coordinator: ChatCoordinator
    let directory: String
    let contentWidth: CGFloat
    var handoff: ChatTranscriptArrivals.Receipt? = nil
    var openedAt: TimeInterval = .infinity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var bubbleWidth: CGFloat {
        theme.radioLog ? ChatRadioLog.messageWidth(contentWidth, theme: theme) + 32 - (row.item?.kind == .tool ? 10 : 0)
            : min(contentWidth, theme.typography.characterWidth * 80)
    }
    private var isBubble: Bool { row.group != nil || row.item?.kind == .assistant || row.item?.kind == .tool || row.item?.isNarration == true }
    var body: some View {
        if theme.radioLog { radioBody } else { standardBody }
    }

    /// Nautical: one log line per transmission, its time and call sign in columns beside the message. A bubble's
    /// rows share the line, so only its first names the station and only its last draws the rule below.
    @ViewBuilder private var radioBody: some View {
        if let duration = row.workedFor {
            ChatRadioLog.line(time: nil, station: nil, theme: theme) {
                Text("moored · \(AgentWorkingAnimation.elapsedText(duration)) on passage").font(theme.typography.detail).foregroundStyle(theme.muted)
            }.padding(.vertical, 6).overlay(alignment: .bottom) { ChatRadioLog.rule(theme) }
        } else if let approval = row.approval {
            ChatPermissionCard(approval: approval, directory: directory, agent: session.agentTitle) { coordinator.showTerminal(session) }
                .padding(.vertical, 8)
        } else if row.item?.kind == .user, let item = row.item {
            ChatRadioLog.line(time: row.time, station: HarbourRadio.ownStation, own: true, theme: theme) {
                radioUserMessage(item)
            }
            .padding(.vertical, 9)
            .background(LinearGradient(colors: [.clear, theme.ink.opacity(0.04)], startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .bottom) { ChatRadioLog.rule(theme) }
        } else if let item = row.item, item.kind == .notice {
            ChatRadioLog.line(time: row.time, station: nil, theme: theme) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if HarbourDistress.isFailure(item.text) { ChatRadioLog.tag("MAYDAY", color: theme.red, theme: theme) }
                    itemView(item)
                }
            }
            .padding(.vertical, 6).overlay(alignment: .bottom) { ChatRadioLog.rule(theme) }
        } else {
            ChatRadioLog.line(time: row.bubbleStart ? row.time : nil,
                              station: row.bubbleStart ? HarbourRadio.callSign(for: session.id) : nil, theme: theme) {
                VStack(alignment: .leading, spacing: 4) {
                    if let item = row.item, item.kind == .tool {
                        // A manoeuvre logs under its message on a rule down its leading edge.
                        itemView(item).padding(.leading, 8)
                            .overlay(alignment: .leading) { Rectangle().fill(theme.border).frame(width: 2) }
                    } else if let item = row.item { itemView(item) }
                    if let group = row.group { groupHeader(group) }
                    // Procedure words: a finished turn's last message ends its transmission.
                    if row.signsOff {
                        Text("out").font(theme.typography.detail).foregroundStyle(theme.muted)
                            .accessibilityIdentifier("chat-radio-out")
                    }
                }
            }
            .padding(.top, row.bubbleStart ? 9 : 2)
            .padding(.bottom, row.bubbleEnd ? 9 : 2)
            .overlay(alignment: .bottom) { if row.bubbleEnd { ChatRadioLog.rule(theme) } }
            .accessibilityIdentifier("chat-message-\(row.id)")
        }
    }

    private var standardBody: some View {
        Group {
            if let duration = row.workedFor {
                HStack(spacing: 12) {
                    Rectangle().fill(theme.border).frame(height: 1)
                    Text("worked for \(AgentWorkingAnimation.elapsedText(duration))").fixedSize()
                    Rectangle().fill(theme.border).frame(height: 1)
                }.font(theme.typography.detail).foregroundStyle(theme.muted).padding(.vertical, 4)
            } else if isBubble {
                VStack(alignment: .leading, spacing: 6) {
                    if let item = row.item, let timeline = row.timeline {
                        itemView(item).padding(.leading, ChatStepRail.width + Self.railSpacing)
                            .overlay(alignment: .leading) { ChatStepRail(timeline: timeline) }
                            .modifier(ChatStepHandoff(receipt: handoff, since: openedAt, reduceMotion: reduceMotion,
                                                      distance: theme.typography.detailLineHeight + 8) {
                                timeline.replaced.map(replacedStep)
                            })
                    } else if let item = row.item { itemView(item) }
                    if let group = row.group {
                        VStack(alignment: .leading, spacing: 0) {
                            groupHeader(group, replyTime: row.replyTime)
                            // Its live step's row goes as the group closes; this folds the step away under the header.
                            ChatClosingStep(group: group, disclosure: session.groupDisclosure(group, turnID: row.turnID),
                                            reduceMotion: reduceMotion) { replacedStep($0).padding(.top, 6) }
                        }
                        .padding(.top, row.item == nil ? 0 : 4)
                    } else if let replyTime = row.replyTime {
                        ChatReplyTime(date: replyTime)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, row.bubbleStart ? 12 : 3)
                .padding(.bottom, row.bubbleEnd ? 12 : 3)
                .frame(maxWidth: bubbleWidth, alignment: .leading)
                .background(theme.sidebar, in: bubbleShape)
                .overlay { ChatBubbleOutline(start: row.bubbleStart, end: row.bubbleEnd).stroke(theme.border, lineWidth: 1) }
                .accessibilityIdentifier("chat-message-\(row.id)")
            } else if let item = row.item { itemView(item) }
            else if let approval = row.approval {
                ChatPermissionCard(approval: approval, directory: directory, agent: session.agentTitle) { coordinator.showTerminal(session) }
            }
        }.padding(.bottom, row.bubbleEnd ? 12 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: row.bubbleStart ? 10 : 0,
                               bottomLeadingRadius: row.bubbleEnd ? 3 : 0,
                               bottomTrailingRadius: row.bubbleEnd ? 10 : 0,
                               topTrailingRadius: row.bubbleStart ? 10 : 0)
    }
    private static let railSpacing: CGFloat = 8
    /// The width a standard bubble's timeline rail takes beside its step (the radio log keeps its own rule).
    private var railWidth: CGFloat { row.timeline != nil && !theme.radioLog ? ChatStepRail.width + Self.railSpacing : 0 }

    /// Clicking a closed group, or a live one showing just its current step, shows every step; clicking again closes it.
    private func groupHeader(_ group: ChatToolGroup, replyTime: Date? = nil) -> some View {
        let disclosure = session.groupDisclosure(group, turnID: row.turnID)
        let live = disclosure == .current || (disclosure == .all && session.groupIsLive(group, turnID: row.turnID))
        return ChatToolGroupHeader(group: group, replyTime: replyTime, disclosure: disclosure, live: live) {
            session.setGroupExpanded(group, disclosure != .all)
        }
    }

    /// The step the current one replaced, as it was shown: its header line on its own dot, and as the live step, no
    /// time.
    private func replacedStep(_ replaced: ChatTranscriptRow.Replaced) -> some View {
        ChatToolCard(item: replaced.item, expanded: .constant(false), directory: directory, embedded: true,
                     titleColumn: theme.typography.stepTitleWidth)
            .padding(.leading, ChatStepRail.width + Self.railSpacing)
            .overlay(alignment: .leading) {
                ChatStepRail(timeline: .init(step: replaced.step, first: true, last: true, current: true))
            }
    }

    @ViewBuilder private func itemView(_ item: ChatItem) -> some View {
        switch item.kind {
        case .user where theme.radioLog:
            radioUserMessage(item)
        case .user:
            // The pending prompt's bubble is where a sent message flies to.
            ChatUserMessage(text: item.text, contentWidth: contentWidth, attachments: item.attachments, endpoint: session.helper?.endpoint,
                            flight: row.id == session.optimisticPrompt?.id ? (session.flightFrames, .prompt(row.id)) : nil,
                            hidden: session.sendFlight?.to == .prompt(row.id))
        case .assistant:
            ChatMarkdown(text: item.text).foregroundStyle(theme.ink)
        case .notice:
            Text(ChatSearchHighlight.text(AttributedString(item.text), query: query, theme: theme)).font(theme.typography.detail).foregroundStyle(theme.muted)
        case .reasoning where item.isNarration:
            ChatMarkdown(text: item.text, color: theme.muted).foregroundStyle(theme.muted)
        case .reasoning:
            VStack(alignment: .leading, spacing: 6) {
                Button { expansion.wrappedValue.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: session.expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                            .frame(width: 8)
                        Text("Reasoning summary")
                        Spacer(minLength: 0)
                    }.font(theme.typography.detail).foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Reasoning summary")
                    .accessibilityValue(session.expanded.contains(row.id) ? "Expanded" : "Collapsed")
                if session.expanded.contains(row.id) { ChatMarkdown(text: item.text) }
            }
        case .tool:
            ChatToolCard(item: item, expanded: toolExpansion(item), directory: directory, embedded: true,
                         layouts: session.toolLayouts, layoutWidth: max(0, bubbleWidth - 32 - railWidth),
                         live: row.turnID != nil && row.turnID == session.liveTurnID,
                         elapsed: theme.radioLog || row.timeline?.running == true ? nil : row.timeline?.step.seconds,
                         titleColumn: row.timeline == nil || theme.radioLog ? nil : theme.typography.stepTitleWidth)
        }
    }
    /// The log's own transmission: its attachments, then what was typed.
    @ViewBuilder private func radioUserMessage(_ item: ChatItem) -> some View {
        if item.attachments.isEmpty {
            ChatMarkdown(text: item.text).foregroundStyle(theme.ink)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ChatMessageAttachments(attachments: item.attachments, endpoint: session.helper?.endpoint,
                                       maxWidth: ChatRadioLog.messageWidth(contentWidth, theme: theme), alignment: .leading)
                if !item.text.isEmpty { ChatMarkdown(text: item.text).foregroundStyle(theme.ink) }
            }
        }
    }
    private func toolExpansion(_ item: ChatItem) -> Binding<Bool> {
        return Binding(get: {
            session.toolIsExpanded(row)
        }, set: { value in
            session.atBottom = false; session.followRevision = nil
            if value { session.expanded.insert(row.id); session.collapsedLiveTools.remove(row.id) }
            else { session.expanded.remove(row.id); session.collapsedLiveTools.insert(row.id) }
        })
    }
    private var expansion: Binding<Bool> {
        Binding(get: { session.expanded.contains(row.id) }, set: {
            if $0 { session.expanded.insert(row.id) } else { session.expanded.remove(row.id) }
        })
    }
}

struct ChatUserMessage: View {
    @Environment(\.chatTheme) private var theme
    let text: String
    let contentWidth: CGFloat
    /// Shown above the text, on the bubble's side; a message of attachments alone has no text bubble.
    var attachments: [ChatAttachment] = []
    var endpoint: HelperWorkspace.Endpoint?
    /// A message a flight lands on: where its bubble is laid out goes to `flight`, and it stays hidden until it lands.
    var flight: (frames: ChatFlightFrames, place: ChatSendFlight.Place)? = nil
    var hidden = false

    /// A user bubble keeps to 60 percent of a wide pane and 80 characters, but a narrow pane's gives it room for 40
    /// characters (up to 85 percent) rather than stacking a short message word by word.
    static func maxWidth(_ contentWidth: CGFloat, characterWidth: CGFloat) -> CGFloat {
        min(max(contentWidth * 0.6, min(contentWidth * 0.85, characterWidth * 40)), characterWidth * 80)
    }

    var body: some View {
        let width = Self.maxWidth(contentWidth, characterWidth: theme.typography.characterWidth)
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if attachments.isEmpty {
                bubble.frame(maxWidth: width, alignment: .trailing)
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    ChatMessageAttachments(attachments: attachments, endpoint: endpoint, maxWidth: width)
                    if !text.isEmpty { bubble }
                }
                .frame(maxWidth: width, alignment: .trailing)
            }
        }
    }

    private var bubble: some View {
        ChatUserBubble(text: text)
            .background { if let flight { ChatFlightAnchor(place: flight.place, frames: flight.frames) } }
            .opacity(hidden ? 0 : 1)
    }
}

/// Diagnostics only: SwiftUI's own scroll geometry beside the native clip. While
/// disabled the transform returns nil, so no action runs as the reader scrolls.
private struct ChatScrollGeometryTrace: ViewModifier {
    let position: ChatScrollPosition
    let enabled: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: ChatViewportTrace.SwiftUIScroll?.self) { [enabled] geometry in
                guard enabled else { return nil }
                return .init(offsetY: geometry.contentOffset.y.rounded(), contentHeight: geometry.contentSize.height.rounded(),
                             containerHeight: geometry.containerSize.height.rounded(),
                             visibleY: geometry.visibleRect.minY.rounded(), visibleHeight: geometry.visibleRect.height.rounded())
            } action: { _, value in
                position.swiftUIScroll = value
            }
        } else {
            content
        }
    }
}

/// Apply the initial position during layout. An onAppear scrollTo can run before
/// a large lazy stack has established the destination's geometry.
private struct ChatInitialScrollAnchor: ViewModifier {
    let atBottom: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.defaultScrollAnchor(atBottom ? .bottom : nil, for: .initialOffset)
                .defaultScrollAnchor(atBottom ? .bottom : nil, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(atBottom ? .bottom : nil)
        }
    }
}

/// Open edges join adjacent lazy rows into one bubble without mounting all tools.
private struct ChatBubbleOutline: Shape {
    let start: Bool
    let end: Bool
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        var path = Path()
        if start {
            path.move(to: CGPoint(x: r.minX, y: r.minY + 10))
            path.addQuadCurve(to: CGPoint(x: r.minX + 10, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX - 10, y: r.minY))
            path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + 10), control: CGPoint(x: r.maxX, y: r.minY))
        } else { path.move(to: CGPoint(x: r.maxX, y: rect.minY)) }
        path.addLine(to: CGPoint(x: r.maxX, y: end ? r.maxY - 10 : rect.maxY))
        if end {
            path.addQuadCurve(to: CGPoint(x: r.maxX - 10, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX + 3, y: r.maxY))
            path.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 3), control: CGPoint(x: r.minX, y: r.maxY))
        } else { path.move(to: CGPoint(x: r.minX, y: rect.maxY)) }
        path.addLine(to: CGPoint(x: r.minX, y: start ? r.minY + 10 : rect.minY))
        return path
    }
}

/// Nautical's radio log columns: time, station and message.
enum ChatRadioLog {
    static func timeWidth(_ theme: ChatTheme) -> CGFloat { theme.typography.characterWidth * 6 }
    static func stationWidth(_ theme: ChatTheme) -> CGFloat { theme.typography.characterWidth * 15 }
    static let spacing: CGFloat = 14
    /// What the message column leaves for text: the row less both columns, at most 80 characters.
    static func messageWidth(_ contentWidth: CGFloat, theme: ChatTheme) -> CGFloat {
        max(0, min(contentWidth - timeWidth(theme) - stationWidth(theme) - spacing * 2, theme.typography.characterWidth * 80))
    }

    @MainActor static func line<Message: View>(time: Date?, station: String?, own: Bool = false, theme: ChatTheme,
                                              @ViewBuilder message: () -> Message) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            Group {
                if let time {
                    Text(time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        .help(ShipsTime.bellsText(time))
                } else { Text(" ") }
            }
            .font(theme.typography.detail).monospacedDigit().foregroundStyle(theme.muted.opacity(0.6))
            .frame(width: timeWidth(theme), alignment: .leading)
            Text(station ?? " ").font(theme.typography.detail)
                .foregroundStyle(own ? theme.ink : theme.accent)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: stationWidth(theme), alignment: .leading)
                .accessibilityHidden(station == nil)
            message().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func rule(_ theme: ChatTheme) -> some View {
        Rectangle().fill(theme.border.opacity(0.5)).frame(height: 1)
    }

    /// A distress or urgency word: MAYDAY, PAN-PAN.
    static func tag(_ word: String, color: Color, theme: ChatTheme) -> some View {
        Text(word).font(HarbourType.heading(theme.typography.detailSize)).tracking(1.6)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.6)) }
            .fixedSize()
    }

    /// Where the log turns over a watch: each row that opens a new watch, with the day's header when the date
    /// changes too. Only timed rows count; untimed ones stay in the watch above them.
    static func watches(_ rows: [ChatTranscriptRow]) -> [String: (day: String?, watch: String)] {
        var result: [String: (day: String?, watch: String)] = [:]
        var lastDay: DateComponents?, lastWatch: String?
        let calendar = Calendar.current
        for row in rows {
            guard let time = row.time else { continue }
            let day = calendar.dateComponents([.year, .month, .day], from: time)
            let watch = ShipsTime.watch(time, calendar: calendar)
            if day != lastDay || watch != lastWatch {
                result[row.id] = (day != lastDay ? ShipsTime.dayText(time) : nil, watch)
                lastDay = day; lastWatch = watch
            }
        }
        return result
    }
}

/// A new watch in the radio log: its name, and the day's header above it when the date turns.
struct ChatRadioWatchDivider: View {
    @Environment(\.chatTheme) private var theme
    let day: String?
    let watch: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let day {
                Text(day).font(HarbourType.heading(theme.typography.detailSize + 0.5)).tracking(2)
                    .foregroundStyle(theme.accent)
            }
            HStack(spacing: 10) {
                Text(watch.uppercased()).font(HarbourType.heading(theme.typography.detailSize - 0.5)).tracking(1.6)
                    .foregroundStyle(theme.muted.opacity(0.75)).fixedSize()
                Rectangle().fill(theme.border).frame(height: 1)
            }
        }
        .padding(.top, 12).padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-radio-watch")
    }
}

/// The log's column headings: time, station, and the channel the terminal is on.
struct ChatRadioLogHeader: View {
    @Environment(\.chatTheme) private var theme
    let surface: UUID

    var body: some View {
        HStack(spacing: ChatRadioLog.spacing) {
            Text("TIME").frame(width: ChatRadioLog.timeWidth(theme), alignment: .leading)
            Text("STATION").frame(width: ChatRadioLog.stationWidth(theme), alignment: .leading)
            Text("RADIO LOG · \(HarbourRadio.channel(for: surface))").lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(theme.typography.font(offset: -2.5, weight: .semibold)).tracking(1.6)
        .foregroundStyle(theme.muted.opacity(0.6))
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-radio-log-header")
    }
}
