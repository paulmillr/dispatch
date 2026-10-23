import SwiftUI
import UIKit

/// R2–R4, S5: a change's diff with its review comments, pushed from Review (or a pane beside the list on an iPad: it
/// keeps its own state and goes back through `dismiss`, never through the stack's path).
///
/// The diff runs unbroken (numbers, markers, the file's colours, added and removed tints, hunk headers, "N unmodified
/// lines" folds and gaps that open in place); each comment tints its lines with a floating glass chip on the first,
/// whose tap opens the comment's glass card under the lines. Comments on the file, and comments not among the rows,
/// show as cards above the diff; one whose quoted lines left the file is S5's outdated card. A tap selects a line, a
/// second tap or the handles extend the selection (R3), and the pink pill morphs into the composer (R4). The bottom
/// bar otherwise holds Diff / Source and Comment. Read-only: nothing here stages or changes the file.
struct ReviewDiffScreen: View {
    let context: ReviewContext
    let path: String
    let area: GitChangeArea?
    /// The back pill; an iPad pane beside the list has none.
    var showsBack = true

    @State private var model: ReviewDiffModel
    @Namespace private var glass
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.tabsColumnWidth) private var column
    @ReduceMotion private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 12.5
    @ScaledMetric(relativeTo: .footnote) private var rowHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var foldHeight: CGFloat = 26
    @ScaledMetric(relativeTo: .footnote) private var numberWidth: CGFloat = 30
    @ScaledMetric(relativeTo: .footnote) private var markerWidth: CGFloat = 16

    init(context: ReviewContext, path: String, area: GitChangeArea?, showsBack: Bool = true) {
        self.context = context
        self.path = path
        self.area = area
        self.showsBack = showsBack
        _model = State(initialValue: ReviewDiffModel(path: path, area: area))
    }

    private var metrics: ReviewDiffMetrics {
        ReviewDiffMetrics(code: codeSize, row: rowHeight, fold: foldHeight, number: numberWidth, marker: markerWidth)
    }

    private var changes: ReviewChanges { context.review.changes(context.place) }
    private var comments: ReviewDiffComments {
        ReviewDiffComments(repository: context.review.repository, scope: context.place.scope, path: path,
                           area: area ?? model.change.area)
    }
    /// The comments this diff shows, as the review holds them now.
    private var shown: [ReviewComment] {
        model.comments(context.review.repository.review(context.place.scope), status: changes.status)
    }

    var body: some View {
        chrome
            .task {
                await model.reload(context)
                applyDemo()
                reveal()
            }
            .onChange(of: context.review.reveal[context.place]) { _, _ in reveal() }
            // The list's triggers: an agent's turn ended on the host, or the app came back.
            .onChange(of: context.review.turns[context.place.host]) { _, _ in
                Task { await model.reload(context, refresh: true) }
            }
            .onChange(of: phase) { _, phase in
                if phase == .active { Task { await model.reload(context, refresh: true) } }
            }
            .onChange(of: model.mode) { _, _ in
                model.selection = nil
                model.open = nil
                model.hinting = false
            }
    }

    // MARK: Header

    /// Pushed: the stack's bar with the back pill. In the iPad's pane (I2, `showsBack` false): a header of its own over
    /// the diff, with Diff / Source and Comment in it, where the pushed screen has them at the bottom.
    @ViewBuilder private var chrome: some View {
        if showsBack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabsPushedScreen()
                .toolbar { header }
        } else {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .safeAreaBar(edge: .top, spacing: 0) { paneHeader }
        }
    }

    private var paneHeader: some View {
        PadPaneHeader(title: fileName) {
            subtitle
        } trailing: {
            Picker("Show", selection: $model.mode) {
                ForEach(ReviewDiffMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            Button { withMorph { model.open = nil; model.hinting = true } } label: {
                Image(systemName: "text.bubble")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.onAccent)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Circle())
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.highlight)
            .disabled(model.document == nil)
            .accessibilityLabel("Comment")
            menu
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var fileName: String { FilesPath.name(path) }

    @ToolbarContentBuilder private var header: some ToolbarContent {
        TabsScreenHeader(title: fileName, column: column, showsBack: showsBack, atTrailingEdge: column == nil) {
            TabsBackPill(label: "Review") { dismiss() }
        } subtitle: {
            subtitle
        } trailing: {
            menu
        }
    }

    private var subtitle: some View {
        let change = model.change
        let letter = ReviewDiffText.letter(change.kind)
        let presentation = model.document?.presentation
        let added = change.additions ?? presentation?.additions ?? 0
        let deleted = change.deletions ?? presentation?.deletions ?? 0
        return HStack(spacing: 6) {
            if let folder = ReviewDiffText.folder(path) {
                Text(folder).font(.system(.caption, design: .monospaced)).truncationMode(.head)
                Text("·")
            }
            Text(letter)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(GitStatusBadge.color(letter))
            MobileCounts(added: added, deleted: deleted, font: .system(.caption, design: .monospaced))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([ReviewDiffText.folder(path), GitStatusBadge.spoken(letter),
                             MobileCounts.spoken(added: added, deleted: deleted)].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", "))
    }

    private var menu: some View {
        Menu {
            Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
            Button("Copy diff", systemImage: "doc.on.clipboard") { UIPasteboard.general.string = model.document?.diff.text }
                .disabled(model.document == nil)
            Button("Open file", systemImage: "doc.text") {
                // Files' preview (F2), its back pill naming Review.
                context.push(.preview(FilesPath.join(context.place.root, path)))
            }
            .disabled(model.change.kind == .deleted)
            Button("Comment on file", systemImage: "text.bubble") { withMorph { model.composeOnFile() } }
                .disabled(model.document == nil)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("More")
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        switch model.load {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading \(fileName)…").font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            ContentUnavailableView {
                Label("The diff could not be read", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.reload(context) } }
            }
        case .unavailable(let message):
            ContentUnavailableView("No diff now", systemImage: "wifi.slash", description: Text(message))
        case .loaded(let document):
            if let placed = model.layout(shown) {
                diff(document, layout: placed.layout, outdated: placed.outdated)
            }
        }
    }

    private func diff(_ document: ReviewDiffDocument, layout: ReviewDiffLayout, outdated: Set<UUID>) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    topCards(layout, outdated: outdated)
                    if document.binary || (document.empty && model.mode == .diff) || layout.rows.isEmpty {
                        note(document)
                    }
                    rows(document, layout: layout)
                    Color.clear.frame(height: 24)
                }
                .padding(.top, 2)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .refreshable { await model.reload(context) }
            .safeAreaBar(edge: .bottom) { bottomBar(layout) }
            .onChange(of: model.scroll) { _, target in
                guard let target else { return }
                model.scroll = nil
                withAnimation(reduceMotion ? nil : .snappy) { scroll(proxy, to: target, layout: layout) }
            }
            .onAppear {
                if let target = model.scroll {
                    model.scroll = nil
                    scroll(proxy, to: target, layout: layout)
                }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to target: ReviewDiffScroll, layout: ReviewDiffLayout) {
        switch target {
        case .comment(let id):
            if let range = layout.ranges[id] { proxy.scrollTo(layout.rows[range.lowerBound].id, anchor: UnitPoint(x: 0, y: 0.2)) }
            else { proxy.scrollTo(id, anchor: .top) }
        case .row(let id):
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// What stands in for lines: binary, no hunks, an empty or deleted file.
    private func note(_ document: ReviewDiffDocument) -> some View {
        let text: String
        if document.binary {
            text = GitChangesText.binary(old: document.diff.oldSize, new: document.diff.newSize, kind: model.change.kind)
        } else {
            text = GitChangesText.emptySource(document.presentation, kind: model.change.kind,
                                              read: model.mode == .source && document.fileLines != nil)
        }
        return Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 20)
    }

    // MARK: Cards above the diff

    @ViewBuilder private func topCards(_ layout: ReviewDiffLayout, outdated: Set<UUID>) -> some View {
        let cards = layout.top.filter { !model.dismissed.contains($0.id) }
        if !cards.isEmpty {
            VStack(spacing: 8) {
                ForEach(cards) { comment in
                    Group {
                        if outdated.contains(comment.id) {
                            ReviewOutdatedCard(comment: comment, close: { model.dismissed.insert(comment.id) },
                                               keep: { comments.keepForFile(comment.id) },
                                               delete: { remove(comment.id) })
                        } else {
                            card(comment, layout: layout, close: { model.dismissed.insert(comment.id) })
                        }
                    }
                    .id(comment.id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }

    private func card(_ comment: ReviewComment, layout: ReviewDiffLayout, close: @escaping () -> Void) -> some View {
        let position = (layout.order.firstIndex(of: comment.id) ?? 0) + 1
        return ReviewCommentCard(comment: comment, now: context.review.clock(), position: position, count: layout.order.count,
                                 close: close, edit: { withMorph { model.edit(comment) } },
                                 delete: { remove(comment.id) },
                                 step: { delta in withAnimation(reduceMotion ? nil : .snappy) { model.step(delta, order: layout.order) } })
    }

    private func remove(_ id: UUID) {
        withAnimation(reduceMotion ? nil : .snappy) {
            if model.open == id { model.open = nil }
            if model.draft?.editing == id { model.draft = nil }
            comments.delete(id)
        }
    }

    // MARK: Rows

    private static let rowsSpace = "review-diff-rows"

    private func rows(_ document: ReviewDiffDocument, layout: ReviewDiffLayout) -> some View {
        let selected = model.selection?.rows
        let source = model.mode == .source
        let openRow = model.open.flatMap { layout.ranges[$0]?.upperBound }
        return LazyVStack(spacing: 0) {
            ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, row in
                VStack(spacing: 0) {
                    line(row, index: index, document: document, layout: layout, selected: selected, source: source)
                    if index == openRow, let id = model.open, let comment = layout.comments[id] {
                        card(comment, layout: layout, close: { withAnimation(reduceMotion ? nil : .snappy) { model.open = nil } })
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                            .padding(.bottom, 10)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
                // A chip overhangs its row; it stays above the next one.
                .zIndex(layout.chips[index] != nil || index == openRow ? 1 : 0)
            }
        }
        .overlay(alignment: .topLeading) {
            if let selected, model.draft == nil, openRow == nil { handles(selected, rows: layout.rows) }
        }
        .coordinateSpace(.named(Self.rowsSpace))
    }

    @ViewBuilder
    private func line(_ row: ReviewDiffRow, index: Int, document: ReviewDiffDocument, layout: ReviewDiffLayout,
                      selected: ClosedRange<Int>?, source: Bool) -> some View {
        switch row.content {
        case .fold(let count):
            ReviewDiffFoldRow(count: count, enabled: true, metrics: metrics) {
                withAnimation(reduceMotion ? nil : .snappy) { model.expand(row) }
            }
        case .gap(let count):
            ReviewDiffFoldRow(count: count, enabled: document.fileLines != nil, metrics: metrics) {
                withAnimation(reduceMotion ? nil : .snappy) { model.expand(row) }
            }
        default:
            let isSelected = selected?.contains(index) == true && row.commentable
            let tint: ReviewDiffTint = isSelected ? .selected : layout.commented(index) ? .commented : .none
            ReviewDiffLineView(row: row, text: document.attributed(row), source: source, tint: tint, metrics: metrics)
                .contentShape(Rectangle())
                .onTapGesture { tap(index, rows: layout.rows) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ReviewDiffLineView.spoken(row))
                .accessibilityAddTraits(row.commentable ? (isSelected ? [.isButton, .isSelected] : .isButton) : [])
                .accessibilityAction { tap(index, rows: layout.rows) }
                .overlay(alignment: .trailing) {
                    if let ids = layout.chips[index], let first = ids.first, let comment = layout.comments[first] {
                        ReviewCommentChip(count: ids.count, open: model.open.map(ids.contains) == true,
                                          location: ReviewText.location(comment).lowercased()) {
                            withAnimation(reduceMotion ? nil : .snappy) {
                                if let open = model.open, ids.contains(open) { model.open = nil } else { model.toggle(first) }
                                model.selection = nil
                                model.hinting = false
                            }
                        }
                        .padding(.trailing, 6)
                    }
                }
        }
    }

    private func tap(_ index: Int, rows: [ReviewDiffRow]) {
        withMorph { model.tap(index, rows: rows) }
    }

    /// R3's handles at the selection's top-left and bottom-right; dragging one moves that end.
    private func handles(_ selected: ClosedRange<Int>, rows: [ReviewDiffRow]) -> some View {
        let offsets = metrics.offsets(rows)
        let top = offsets[selected.lowerBound], bottom = offsets[selected.upperBound + 1]
        // Each handle sits in a 44 point target: the dot's centre where the mockup draws it.
        return ZStack(alignment: .topLeading) {
            handle(bottom: false, rows: rows, offsets: offsets)
                .offset(x: 4 - 16, y: top - 6 - 5)
            handle(bottom: true, rows: rows, offsets: offsets)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: -4 + 16, y: bottom - ReviewSelectionHandle.height + 6 - 5)
        }
    }

    private func handle(bottom: Bool, rows: [ReviewDiffRow], offsets: [CGFloat]) -> some View {
        ReviewSelectionHandle(bottom: bottom)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.rowsSpace)).onChanged { value in
                guard let selection = model.selection else { return }
                let row = ReviewDiffMetrics.row(at: value.location.y, offsets: offsets)
                let next = selection.moving(top: !bottom, to: row, in: rows)
                if next != selection { model.selection = next }
            })
            .accessibilityElement()
            .accessibilityLabel(bottom ? "Selection end" : "Selection start")
            .accessibilityAdjustableAction { direction in
                guard let selection = model.selection else { return }
                let edge = bottom ? selection.rows.upperBound : selection.rows.lowerBound
                let step = direction == .increment ? 1 : -1
                var row = edge + step
                while rows.indices.contains(row), !rows[row].commentable { row += step }
                guard rows.indices.contains(row) else { return }
                model.selection = selection.moving(top: !bottom, to: row, in: rows)
            }
    }

    // MARK: Bottom bar

    private func withMorph(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3), change)
    }

    private func bottomBar(_ layout: ReviewDiffLayout) -> some View {
        GlassEffectContainer(spacing: 12) {
            if let draft = model.draft {
                ReviewDiffComposer(text: Binding(get: { model.draft?.text ?? "" }, set: { model.draft?.text = $0 }),
                                   location: draft.location, quote: draft.quote.first?.text, editing: draft.editing != nil,
                                   focusOnAppear: model.focusDraft, namespace: glass,
                                   cancel: { withMorph { model.cancelDraft() } },
                                   send: { withMorph { model.send(comments) } })
            } else if let selection = model.selection, let picked = selection.draft(in: layout.rows) {
                HStack(spacing: 10) {
                    Button { withMorph { model.compose(rows: layout.rows) } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "text.bubble.fill")
                            Text(ReviewDiffText.pill(start: picked.start, end: picked.end)).lineLimit(1)
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.onAccent)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 50)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
                    .glassEffectID("composer", in: glass)
                    closeButton("Clear selection") { withMorph { model.clearSelection() } }
                }
                .padding(.bottom, 8)
            } else if model.hinting {
                HStack(spacing: 10) {
                    Text("Tap a line to comment on it")
                        .font(.subheadline)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .glassEffect(.regular, in: Capsule())
                        .glassEffectID("composer", in: glass)
                    Button { withMorph { model.composeOnFile() } } label: {
                        Label("File", systemImage: "doc.text")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .accessibilityLabel("Comment on file")
                    closeButton("Stop commenting") { withMorph { model.hinting = false } }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            } else if showsBack {
                HStack(spacing: 10) {
                    Picker("Show", selection: $model.mode) {
                        ForEach(ReviewDiffMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    Spacer(minLength: 8)
                    Button { withMorph { model.open = nil; model.hinting = true } } label: {
                        Label("Comment", systemImage: "plus.bubble")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .glassEffectID("composer", in: glass)
                    .disabled(layout.rows.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func closeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .glassEffectID("close", in: glass)
        .accessibilityLabel(label)
    }

    // MARK: Reveal and the demo

    /// Create review's row asked for a comment (`MobileReview.reveal`): its card opens and the diff scrolls to it.
    private func reveal() {
        guard model.document != nil, let id = context.review.reveal[context.place],
              shown.contains(where: { $0.id == id }) else { return }
        context.review.reveal[context.place] = nil
        model.dismissed.remove(id)
        model.open = id
        model.scroll = .comment(id)
    }

    /// Debug (`-DispatchReviewDiff <name>[:select|compose|outdated]`): the mockup's state, once per launch.
    private func applyDemo() {
        #if DEBUG
        guard let demo = context.review.demo, demo.diff == fileName, !Self.demoApplied,
              let placed = model.layout(shown) else { return }
        Self.demoApplied = true
        let rows = placed.layout.rows
        switch demo.diffState {
        case nil:
            model.open = placed.layout.order.first { placed.layout.ranges[$0] != nil }
        case "select", "compose":
            guard let first = rows.firstIndex(where: { $0.line == ReviewLine(side: .new, number: 45) }),
                  let last = rows.firstIndex(where: { $0.line == ReviewLine(side: .new, number: 48) }) else { return }
            model.selection = ReviewDiffSelection(anchor: first, head: last)
            if demo.diffState == "compose" {
                model.focusDraft = false
                model.compose(rows: rows)
                model.draft?.text = "Keep the old markup. The unread class belongs on the link, not the item, and `end` breaks nested routes."
            }
        default:
            break
        }
        #endif
    }

    #if DEBUG
    @MainActor private static var demoApplied = false
    #endif
}
