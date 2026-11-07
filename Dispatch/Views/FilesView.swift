import SwiftUI

/// A tab in files mode: under the strip a 34 pt header, then the files tab it shows. The
/// Files tab is the outline with the transfer rows and footer under it and the preview on the right; Review (F3a's
/// Changes, with comments) and Commits (F4a) are views of their own. Header, outline, transfer rows, footer and preview are separate views.
struct FilesView: View {
    let session: FilesSession
    /// The tab's pane has the focus (as for `ChatView`): the list takes the keyboard only then.
    var focused = true
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Sorted levels kept between renders: the loading code replaces listings every 2 s.
    @State private var builder = FilesRowBuilder()

    /// Settings › Files › Show hidden files; ⇧⌘. overrides it per tab (`FilesSession.showHidden`).
    static var hiddenSetting: Bool { TerminalRuntime.shared.preferences.filesShowHidden }

    var body: some View {
        let theme = ChatThemeStore.shared.current
        let directory = TerminalRuntime.shared.workspace?.liveTab(session.id)?.directory
        let root = session.root(tabDirectory: directory).map(FilesPath.normalized)
        content(root)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.terminal)
            .foregroundStyle(Chrome.ink)
            .environment(\.chatTheme, theme)
            .environment(\.appTypography, typography)
            .environment(\.colorScheme, Chrome.colorScheme)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("files-view")
    }

    @ViewBuilder private func content(_ root: String?) -> some View {
        switch session.availability {
        case .plainSSH, .notGranted, .unavailable:
            FilesUnavailableView(session: session)
        case .loading:
            FilesLoadingView()
        case .available:
            browser(root, offline: nil)
        case .offline(let host, let since):
            browser(root, offline: (host, since))
        }
    }

    private func browser(_ root: String?, offline: (host: String, since: Date?)?) -> some View {
        VStack(spacing: 0) {
            // One column with a file previewed in the list's place: the preview's header is the only row (the way back,
            // the file and its controls); search and the pane's toggle have nothing to act on there.
            if !(session.drilled && session.tab == .files) {
                FilesHeader(session: session, root: root, focused: focused)
            }
            if let offline { FilesOfflineBar(session: session, host: offline.host, since: offline.since) }
            // The tabs change as the modes do: the old body fades down and out, the new one in. The animation is this
            // body's alone; the header and the strip never animate with it.
            ZStack {
                switch session.tab {
                case .files:
                    // The list is built here, where the preview's width is not read: a divider drag re-renders the split
                    // only, and the equatable column keeps its outline from updating on every move.
                    FilesSplit(session: session,
                               list: FilesListColumn(session: session, root: root, focused: focused, dimmed: offline != nil,
                                                     builder: builder).equatable(),
                               detail: FilePreviewPane(session: session, root: root))
                        .overlay { FilesWriteRefusal(session: session) }
                        .transition(tabTransition)
                case .changes:
                    GitChangesView(session: session, focused: focused).transition(tabTransition)
                case .commits:
                    GitCommitsView(session: session, focused: focused).transition(tabTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: InterfaceMotion.modeSwitchDuration),
                       value: session.tab)
            // Review, Commits and the preview leave files on double ⌃D as the list does (its outline takes the pair
            // itself); a text field or editor with the keyboard keeps ⌃D for itself.
            .filesExitPair(session)
        }
    }

    private var tabTransition: AnyTransition { reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)) }

    /// The list and the preview's widths in a view `width` wide, from the user's `preference` (nil: the default) and
    /// whether the preview is `hidden`. By default the preview takes 560 pt from 1,000 pt up and half below that; a
    /// chosen width holds wherever it fits. Either way the list keeps 320 pt and the preview 240 pt, and under
    /// `columnsWidth` there is no room beside the list (`shape` stacks them or keeps one column; the preference is kept
    /// for when there is room). `preview` includes the 1 pt divider line at its leading edge.
    static func layout(width: CGFloat, preference: CGFloat?, hidden: Bool) -> FilesSplitColumns {
        guard !hidden, width >= columnsWidth else { return FilesSplitColumns(list: width, preview: nil) }
        let preview = clampedPreview(preference ?? (width >= 1_000 ? 560 : width / 2), width: width)
        return FilesSplitColumns(list: width - preview, preview: preview)
    }

    /// How a split `width` × `height` shows its list and its detail. With no pane (`off`: Files with previews off in
    /// Settings), the list alone. Where the two do not fit (`fitsBoth`), one view: a row chosen shows its detail in the
    /// list's place (`FilesSession.narrowDetail`). Otherwise as the tab chose (`oneView`, the views button and ⌥⌘P), or
    /// by default one view in a space of `oneAtATimePanes` panes or more (`oneAtATime`: the layout decides, the same on
    /// every display) or where the view is narrower than `columnsWidth` and shorter than `stackHeight`. Two views: from
    /// `columnsWidth` side by side (`layout`); narrower, the list over the detail where it is `minimumStack` tall, each
    /// the view's width, the list at its own height (`listIdeal`) up to 40% of the view's, else at 40%; shorter still,
    /// side by side at the minima.
    static func shape(width: CGFloat, height: CGFloat, preference: CGFloat?, oneView: Bool? = nil, off: Bool = false,
                      listIdeal: CGFloat? = nil, oneAtATime: Bool = false) -> FilesSplitShape {
        if off { return .columns(FilesSplitColumns(list: width, preview: nil)) }
        guard fitsBoth(width: width, height: height) else { return .single }
        if oneView ?? (oneAtATime || (width < columnsWidth && height < stackHeight)) { return .single }
        if width >= columnsWidth { return .columns(layout(width: width, preference: preference, hidden: false)) }
        if height >= minimumStack {
            let cap = (height * 0.4).rounded()
            return .stacked(list: min(listIdeal.map { $0.rounded(.up) } ?? cap, cap))
        }
        let preview = clampedPreview(preference ?? width / 2, width: width)
        return .columns(FilesSplitColumns(list: width - preview, preview: preview))
    }

    /// Whether the list and its detail fit together at all: side by side at their minima, or stacked with the detail
    /// 240 pt tall under the list's 40%. Smaller, one view whatever the tab chose, and the views button goes.
    static func fitsBoth(width: CGFloat, height: CGFloat) -> Bool {
        width >= minimumList + minimumPreview || height >= minimumStack
    }

    /// A space with this many panes or more (2 × 2, 3 × 2, 4 × 2) shows Files, Review and Commits one view at a time.
    static let oneAtATimePanes = 4
    /// The narrowest view that shows the preview beside the list: half a MacBook's window (about 600 pt) gives a diff
    /// too little room beside a 320 pt list.
    static let columnsWidth: CGFloat = 900
    /// The shortest view that stacks the list over the detail; a quarter of a laptop's window has one column.
    static let stackHeight: CGFloat = 560
    static let minimumList: CGFloat = 320
    static let minimumPreview: CGFloat = 240
    /// The shortest view that stacks the two when the tab asks for both: the list's 40% (160 pt) over 240 pt of detail.
    static let minimumStack: CGFloat = 400

    /// `preview` within the minima of a view `width` wide, on whole points so the divider sits on pixels.
    static func clampedPreview(_ preview: CGFloat, width: CGFloat) -> CGFloat {
        min(max(preview, minimumPreview), max(minimumPreview, width - minimumList)).rounded()
    }
}

/// The list's and the preview's widths (`FilesView.layout`); no preview when it is hidden or there is no room.
struct FilesSplitColumns: Equatable {
    var list: CGFloat
    var preview: CGFloat?
}

/// How a split shows its list and detail (`FilesView.shape`): side by side, the list `list` points tall over the
/// detail, or one column.
enum FilesSplitShape: Equatable {
    case columns(FilesSplitColumns)
    case stacked(list: CGFloat)
    case single

    /// The detail shows with the list: beside it or under it.
    var showsPane: Bool {
        switch self {
        case .columns(let columns): columns.preview != nil
        case .stacked: true
        case .single: false
        }
    }
}

/// The list with the preview beside or under it, as the view's size and the last width chosen put them
/// (`FilesView.shape`). Only this view reads the sizes and the hidden flag, so dragging the divider or hiding the pane
/// redraws the split and nothing above it. The git tabs put their detail in the preview's place (`detail`), so all tabs
/// share the divider and ⌥⌘P. On one column the detail shows in the list's place once a row is chosen
/// (`FilesSession.narrowDetail`); the header goes back from it (its tab name turned into a back button) and esc does.
struct FilesSplit<List: View, Detail: View>: View {
    let session: FilesSession
    let list: List
    let detail: Detail
    /// The list's own height, which a stacked split gives it and no more (Review's few changes); nil: 40% of the view.
    var listIdeal: CGFloat?
    /// One column opens on the detail rather than the list (Review, on the selected change's diff).
    var opensOnDetail = false
    /// The space has many panes: one column whatever the size (`FilesView.shape`).
    @Environment(\.filesOneAtATime) private var oneAtATime

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let preference = TerminalRuntime.shared.files.previewPreference(for: session)
            let shape = FilesView.shape(width: size.width, height: size.height, preference: preference,
                                        oneView: session.oneView, off: session.previewOff, listIdeal: listIdeal,
                                        oneAtATime: oneAtATime)
            let fits = !session.previewOff && FilesView.fitsBoth(width: size.width, height: size.height)
            let single = shape == .single
            let drilled = single && session.narrowDetail
            // The list stays the layout's first child whatever the pane does, so its outline keeps its identity (and its
            // scroll and selection) when the pane hides, shows, moves under it or collapses, or the detail covers it.
            FilesSplitLayout(shape: shape) {
                list.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(drilled ? 0 : 1)
                    .allowsHitTesting(!drilled)
                    .accessibilityHidden(drilled)
                if shape.showsPane {
                    Chrome.border
                    // Not mounted while hidden or on one column: the pane's task is what loads the selection.
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay {
                if drilled {
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ChatThemeStore.shared.current.terminal)
                        // Esc the detail did not take itself (a find field, a diff's own) goes back to the list.
                        .onExitCommand { session.goBack() }
                }
            }
            .environment(\.filesSplitNarrow, single)
            .environment(\.filesCompact, size.width < FilesView.columnsWidth)
            // The header's toggle and ⌥⌘P act on what this layout shows.
            .onChange(of: fits, initial: true) { _, fits in
                if session.canShowBoth != fits { session.canShowBoth = fits }
            }
            .onChange(of: { if case .stacked = shape { true } else { false } }(), initial: true) { _, stacked in
                if session.stackedViews != stacked { session.stackedViews = stacked }
            }
            .onChange(of: single, initial: true) { _, single in
                if session.splitNarrow != single { session.splitNarrow = single }
                if single, opensOnDetail, !session.narrowDetail { session.narrowDetail = true }
            }
            .overlay(alignment: .leading) {
                if case .columns(let columns) = shape, let preview = columns.preview {
                    // Over the line and the edges of both columns, above the outline's and the preview's own views.
                    FilesPreviewDivider(session: session, preview: preview, width: size.width)
                        .frame(width: FilesPreviewDividerView.hitWidth)
                        .frame(maxHeight: .infinity)
                        .padding(.leading, columns.list + 0.5 - FilesPreviewDividerView.hitWidth / 2)
                }
            }
        }
    }
}

/// Places the split's children: the list, then (with the pane) the 1 pt line and the detail, beside or under it.
private struct FilesSplitLayout: Layout {
    let shape: FilesSplitShape

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        func put(_ index: Int, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            guard subviews.indices.contains(index) else { return }
            subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                                  proposal: ProposedViewSize(width: max(0, width), height: max(0, height)))
        }
        let width = bounds.width, height = bounds.height
        switch shape {
        case .columns(let columns):
            guard let preview = columns.preview, subviews.count == 3 else { return put(0, 0, 0, width, height) }
            let list = width - preview
            put(0, 0, 0, list, height)
            put(1, list, 0, 1, height)
            put(2, list + 1, 0, preview - 1, height)
        case .stacked(let list):
            guard subviews.count == 3 else { return put(0, 0, 0, width, height) }
            put(0, 0, 0, width, list)
            put(1, 0, list, width, 1)
            put(2, 0, list + 1, width, height - list - 1)
        case .single:
            put(0, 0, 0, width, height)
        }
    }
}

/// Double ⌃D: the second press within a second of the first, with no other key between, completes the pair; holding the
/// key never does.
@MainActor final class FilesExitPair {
    private var armedAt: Date?

    /// A ⌃D at `time`: true when it completes a pair (which disarms), else it arms.
    func press(at time: Date) -> Bool {
        if let first = armedAt, time >= first, time.timeIntervalSince(first) <= 1 {
            armedAt = nil
            return true
        }
        armedAt = time
        return false
    }

    /// Another key: the next ⌃D starts a new pair.
    func reset() { armedAt = nil }
}

private struct FilesExitPairModifier: ViewModifier {
    let session: FilesSession
    @State private var pair = FilesExitPair()

    func body(content: Content) -> some View {
        content.onKeyPress(phases: [.down, .repeat]) { press in
            let control = press.modifiers.intersection([.command, .option, .control, .shift]) == .control
            guard control, press.key == KeyEquivalent("d") || press.characters == "\u{4}" else {
                pair.reset()
                return .ignored
            }
            // Holding the key never confirms; the hidden terminal never gets the ^D.
            guard press.phase == .down else { return .handled }
            if pair.press(at: System.date()) { TerminalRuntime.shared.files.exitFromFiles(session.id) }
            return .handled
        }
    }
}

extension View {
    /// Double ⌃D leaves files (`FilesCoordinator.exitFromFiles`) from whatever in this view has the keyboard.
    func filesExitPair(_ session: FilesSession) -> some View { modifier(FilesExitPairModifier(session: session)) }
}

private struct FilesSplitNarrowKey: EnvironmentKey {
    static let defaultValue = false
}

private struct FilesCompactKey: EnvironmentKey {
    static let defaultValue = false
}

private struct FilesOneAtATimeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The split is a single column (`FilesSplit`): choosing a row shows its detail in the list's place.
    var filesSplitNarrow: Bool {
        get { self[FilesSplitNarrowKey.self] }
        set { self[FilesSplitNarrowKey.self] = newValue }
    }

    /// The tab's space has `FilesView.oneAtATimePanes` panes or more (TerminalContentView): the split is one column
    /// whatever its size (`FilesView.shape`).
    var filesOneAtATime: Bool {
        get { self[FilesOneAtATimeKey.self] }
        set { self[FilesOneAtATimeKey.self] = newValue }
    }

    /// The split is narrower than `FilesView.columnsWidth` (stacked or one column): diffs keep one gutter and wrap,
    /// Diff | Source are glyphs and a commit's summary takes three lines.
    var filesCompact: Bool {
        get { self[FilesCompactKey.self] }
        set { self[FilesCompactKey.self] = newValue }
    }
}

/// The column under the header: the outline, the transfer rows and the footer. Equatable on its inputs, so the
/// split's re-renders during a divider drag do not rebuild 10,000 rows; what it reads from the session redraws it.
private struct FilesListColumn: View, Equatable {
    let session: FilesSession
    let root: String?
    let focused: Bool
    let dimmed: Bool
    let builder: FilesRowBuilder

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.session === b.session && a.root == b.root && a.focused == b.focused && a.dimmed == b.dimmed
            && a.builder === b.builder
    }

    var body: some View {
        // The Modified column's ages move on by the minute with nothing listed again: the loader keeps an unchanged
        // folder's listing, and with it the time it was taken. A new minute changes those texts only; the outline
        // redraws the rows whose age changed and keeps its items, selection and expansion.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            column(now: FilesRowBuilder.minute(System.date()))
        }
    }

    private func column(now: Date) -> some View {
        let hidden = session.showsHidden(default: FilesView.hiddenSetting)
        let result = root.map { builder.rows(for: session, root: $0, hidden: hidden, now: now) } ?? FilesRowBuilder.Result()
        return VStack(spacing: 0) {
            FilesColumnHeader(session: session)
            ZStack {
                if let root {
                    FilesOutline(session: session, rows: result.rows, root: root, settingHidden: FilesView.hiddenSetting,
                                 focused: focused, rebuild: { [builder, session] in
                                     builder.rows(for: session, root: root,
                                                  hidden: session.showsHidden(default: FilesView.hiddenSetting),
                                                  now: FilesRowBuilder.minute(System.date())).rows
                                 })
                }
                FilesListState(session: session, root: root, empty: result.rows.isEmpty)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            if let error = result.rootError { FilesRootErrorLine(message: error) }
            FileTransferRows(session: session)
            FilesFooter(session: session, itemCount: result.itemCount, shown: result.ids)
        }
        .opacity(dimmed ? 0.45 : 1)
    }
}

/// The divider's hit area: the resize cursor over it, a drag moves it, a double-click puts the default width back.
private struct FilesPreviewDivider: NSViewRepresentable {
    let session: FilesSession
    let preview: CGFloat
    let width: CGFloat

    func makeNSView(context: Context) -> FilesPreviewDividerView {
        let view = FilesPreviewDividerView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FilesPreviewDividerView, context: Context) {
        view.preview = preview
        view.width = width
        view.choose = { [session] width in
            // Each move lands where the pointer is: an animation would trail it.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { TerminalRuntime.shared.files.choosePreviewWidth(width, for: session) }
        }
    }

    static func dismantleNSView(_ view: FilesPreviewDividerView, coordinator: ()) {
        view.endDrag()
    }
}

/// An invisible strip over the 1 pt line between the list and the preview. AppKit rather than a SwiftUI gesture: a
/// cursor rect shows the resize cursor without hover bookkeeping that could leave it stale, and the drag gets its
/// events even where the pointer leaves the strip.
final class FilesPreviewDividerView: NSView {
    static let hitWidth: CGFloat = 8
    /// The preview's width as laid out, and the view's: a drag moves from the former within the latter.
    var preview: CGFloat = 0
    var width: CGFloat = 0
    var choose: (CGFloat?) -> Void = { _ in }
    /// Where the drag in flight began: the pointer's x in the window and the preview's width then.
    private var drag: (origin: CGFloat, preview: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Preview width")
        setAccessibilityIdentifier("files-preview-divider")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            endDrag()
            choose(nil)
            return
        }
        endDrag()
        drag = (event.locationInWindow.x, preview)
        // The cursor rect stops applying once the pointer leaves the strip; the drag keeps the cursor until it ends.
        NSCursor.resizeLeftRight.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, width > 0 else { return }
        // The divider follows the pointer: moving right widens the list and narrows the preview.
        choose(FilesView.clampedPreview(drag.preview - (event.locationInWindow.x - drag.origin), width: width))
    }

    override func mouseUp(with event: NSEvent) { endDrag() }

    /// Ends a drag in flight and pops its cursor: on mouse up, and when the strip goes away under the pointer (the
    /// pane hidden by ⌥⌘P mid-drag, the view narrowed under `FilesView.columnsWidth`), so the cursor never stays a resize arrow.
    func endDrag() {
        guard drag != nil else { return }
        drag = nil
        NSCursor.pop()
        window?.invalidateCursorRects(for: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// A refresh of the root that failed after a good listing: the rows stay, and this line says they are no longer live
/// (F2e: never a stale list shown as if it were live).
private struct FilesRootErrorLine: View {
    let message: String
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(typography.symbol(.micro))
            Text(verbatim: message).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(typography, .body)
        .foregroundStyle(palette.detail)
        .padding(.leading, FilesColumns.leading)
        .padding(.trailing, FilesColumns.trailing)
        .frame(height: typography.expanded(24))
        .overlay(alignment: .top) { palette.separator.frame(height: 1) }
        .help(message)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("files-root-error")
    }
}

/// What shows over the list instead of rows: loading, why the root could not be listed, an empty folder, or a filter
/// that matches nothing. The outline stays mounted beneath, so focus and drops survive the change.
private struct FilesListState: View {
    let session: FilesSession
    let root: String?
    let empty: Bool
    @Environment(\.appTypography) private var typography

    var body: some View {
        let state = root.flatMap { session.listings[$0] }
        if root == nil || state?.listing == nil {
            if let error = state?.error {
                centred(error.message, identifier: "files-error")
            } else {
                FilesLoadingView()
            }
        } else if empty {
            if session.filter.isEmpty {
                centred("Empty folder", identifier: "files-empty")
            } else {
                centred("No names contain “\(session.filter)”", identifier: "files-no-matches")
            }
        }
    }

    private func centred(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(typography, .body)
            .foregroundStyle(Chrome.palette.detail)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(identifier)
    }
}
