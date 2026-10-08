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
    @State private var viewportGeneration = UUID()
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
        let request = SearchRequest(query: query, revision: session.revision, history: session.historyRevision,
                                    approvals: session.approvals.count, generation: session.historyGeneration)
        return GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView(.vertical, showsIndicators: false) {
                    // A fixed scroll target inside the lazy rows can make
                    // accessibility prefetch alternate their visibility forever.
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if session.hasEarlier || session.loadingEarlier {
                                earlierMessages
                            }
                            ForEach(session.visibleTranscriptRows) { row in
                                // One layout child per ID, regardless of row kind or
                                // disclosure state, keeps the outer stack lazy.
                                VStack(alignment: .leading, spacing: 0) {
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
                                    ChatTranscriptRowView(row: row, session: session, coordinator: coordinator, directory: directory,
                                        contentWidth: max(0, geometry.size.width - 44))
                                        .modifier(ChatArrivalMotion(receipt: session.transcriptArrivals.receipt(for: row.id),
                                                                    since: openedAt, reduceMotion: reduceMotion))
                                }.background(ChatScrollMarker(id: row.id, position: session.scrollPosition)).id(row.id)
                            }
                        }
                        // Scrolling to the bottom aligns this marker's bottom edge, so it spans a floating input.
                        Color.clear.frame(height: 1 + bottomContentInset).id("bottom")
                    }
                    .padding(22).frame(maxWidth: .infinity)
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
                                Text("new messages")
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
                .onAppear { openedAt = ProcessInfo.processInfo.systemUptime; connectScrollPosition(scroll); updateScrollbarTheme() }
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
                .onDisappear { openedAt = .infinity; session.scrollPosition.disconnect() }
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
                .onChange(of: session.revision) { _, revision in
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
        }.environment(\.chatSearchQuery, query)
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
                Text(session.earlierError ?? (session.loadingEarlier ? "Loading earlier messages…" : "Earlier messages"))
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(theme.border).frame(height: 1)
            }.font(theme.typography.detail).foregroundStyle(theme.muted)
                .frame(minHeight: 28).frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(session.loadingEarlier).id("earlier")
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ChatTopPreference.self, value: proxy.frame(in: .named("chatScroll")).maxY)
            })
    }

    private func connectScrollPosition(_ scroll: ScrollViewProxy) {
        session.scrollPosition.diagnosticState = { [weak session] in
            guard let session else { return nil }
            return .init(revision: session.revision, historyRevision: session.historyRevision,
                rows: session.visibleTranscriptRows.count, turns: session.turns.count, busy: session.busy,
                atBottom: session.atBottom, following: session.followRevision != nil,
                loadingHistory: session.loadingHistory, loadingEarlier: session.loadingEarlier)
        }
        session.scrollPosition.diagnosticRows = { [weak session] ids in
            guard let session else { return [:] }
            var rows: [String: ChatViewportTrace.RowInfo] = [:]
            for (index, row) in session.visibleTranscriptRows.enumerated() where ids.contains(row.id) {
                rows[row.id] = .init(index: index, kind: Self.diagnosticKind(row, session: session))
            }
            return rows
        }
        session.scrollPosition.recordDiagnostic(.connected, force: true)
        // Keep initial follow intent while lazy rows replace estimated heights.
        // Actual user scrolling clears this through userScrolled below.
        if session.atBottom { session.followRevision = session.revision }
        session.scrollPosition.realizeAnchor = { id in scroll.scrollTo(id, anchor: .top) }
        session.scrollPosition.hasContent = { [weak session] in session?.visibleTranscriptRows.isEmpty == false }
        session.scrollPosition.recoverViewport = { [weak session] anchor, rebuild in
            guard let session, session.showChat, !session.visibleTranscriptRows.isEmpty else { return }
            let interaction = session.scrollPosition.interactionRevision
            let following = session.atBottom
            let target = anchor.flatMap { saved in session.visibleTranscriptRows.contains(where: { $0.id == saved.id }) ? saved : nil }
                ?? session.visibleTranscriptRows.first.map { ChatScrollPosition.Anchor(id: $0.id, offset: 0) }
            if rebuild { openedAt = ProcessInfo.processInfo.systemUptime; viewportGeneration = UUID() }
            let generation = viewportGeneration
            DispatchQueue.main.async {
                guard viewportGeneration == generation, session.showChat,
                      session.scrollPosition.interactionRevision == interaction else { return }
                if following {
                    scroll.scrollTo("bottom", anchor: .bottom)
                    session.scrollPosition.jumpToLatest()
                } else if let target {
                    scroll.scrollTo(target.id, anchor: .top)
                    session.scrollPosition.restore(target)
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
            // Include the 22-point padding and 40-point follow margin.
            if let atBottom = session.scrollPosition.isAtBottom(tolerance: 62), session.atBottom != atBottom {
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
        TerminalRuntime.shared.workspace?.directory(forSurface: session.id) ?? NSHomeDirectory()
    }
}

/// Fade and translate the new row's pixels without animating its measured height
/// or passing an animation into streamed markdown, tool output, or scrolling.
struct ChatArrivalMotion: ViewModifier {
    let reduceMotion: Bool
    let receipt: ChatTranscriptArrivals.Receipt?
    let openedAt: TimeInterval
    let distance: CGFloat
    let duration: Double
    @State private var visible: Bool

    init(receipt: ChatTranscriptArrivals.Receipt?, since openedAt: TimeInterval, reduceMotion: Bool,
         distance: CGFloat? = nil, duration: Double? = nil) {
        self.receipt = receipt; self.openedAt = openedAt; self.reduceMotion = reduceMotion
        self.distance = distance ?? 6
        self.duration = duration ?? ChatScrollPosition.arrivalGlide
        _visible = State(initialValue: receipt?.eligible(since: openedAt) != true)
    }

    func body(content: Content) -> some View {
        content.transaction { $0.animation = nil }
            .modifier(ChatArrivalEffect(progress: visible ? 1 : 0,
                                        distance: reduceMotion ? 0 : distance))
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

private struct ChatArrivalEffect: AnimatableModifier {
    nonisolated var progress: Double
    let distance: CGFloat
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        content.opacity(progress).offset(y: distance * (1 - progress))
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
    private var bubbleWidth: CGFloat { min(contentWidth, theme.typography.characterWidth * 80) }
    private var isBubble: Bool { row.group != nil || row.item?.kind == .assistant || row.item?.kind == .tool || row.item?.isNarration == true }
    var body: some View {
        Group {
            if let duration = row.workedFor {
                HStack(spacing: 12) {
                    Rectangle().fill(theme.border).frame(height: 1)
                    Text("worked for \(AgentWorkingAnimation.elapsedText(duration))").fixedSize()
                    Rectangle().fill(theme.border).frame(height: 1)
                }.font(theme.typography.detail).foregroundStyle(theme.muted).padding(.vertical, 4)
            } else if isBubble {
                VStack(alignment: .leading, spacing: 6) {
                    if let item = row.item { itemView(item) }
                    if let group = row.group {
                        ChatToolGroupHeader(group: group, replyTime: row.replyTime, expanded: Binding(
                            get: { session.groupIsExpanded(group, turnID: row.turnID) },
                            set: { session.setGroupExpanded(group, $0) }
                        ))
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
                ChatPermissionCard(approval: approval, directory: directory, agent: session.agentTitle) { coordinator.chooseChat(false, session: session) }
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
    @ViewBuilder private func itemView(_ item: ChatItem) -> some View {
        switch item.kind {
        case .user:
            ChatUserMessage(text: item.text, contentWidth: contentWidth)
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
                         layouts: session.toolLayouts, layoutWidth: max(0, bubbleWidth - 32),
                         live: session.busy && row.turnID == session.activeTurnID)
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

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ChatMarkdown(text: text, fillWidth: false)
                .font(theme.typography.body)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(theme.ink.opacity(0.08), in: UnevenRoundedRectangle(
                    topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 3, topTrailingRadius: 10))
                .frame(maxWidth: min(contentWidth * 0.6, theme.typography.characterWidth * 80), alignment: .trailing)
        }
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
