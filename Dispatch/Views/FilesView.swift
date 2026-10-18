import SwiftUI

/// A tab in files mode: under the strip a 34 pt header, then the files tab it shows. The
/// Files tab is the outline with the transfer rows and footer under it and the preview on the right; Changes (F3a) and
/// Commits (F4a) are their own views. Header, outline, transfer rows, footer and preview are separate views.
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
            FilesHeader(session: session, root: root, settingHidden: Self.hiddenSetting)
            if let offline { FilesOfflineBar(session: session, host: offline.host, since: offline.since) }
            // The tabs change as the modes do: the old body fades down and out, the new one in. The animation is this
            // body's alone; the header (its segments included) and the strip never animate with it.
            ZStack {
                switch session.tab {
                case .files:
                    // The list is built here, where the preview's width is not read: a divider drag re-renders the split
                    // only, and the equatable column keeps its outline from updating on every move.
                    FilesSplit(session: session,
                               list: FilesListColumn(session: session, root: root, focused: focused, dimmed: offline != nil,
                                                     builder: builder).equatable(),
                               detail: FilePreviewPane(session: session))
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
        }
    }

    private var tabTransition: AnyTransition { reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)) }

    /// The list and the preview's widths in a view `width` wide, from the user's `preference` (nil: the default) and
    /// whether the preview is `hidden`. By default the preview takes 560 pt from 1,000 pt up and half below that; a
    /// chosen width holds wherever it fits. Either way the list keeps 320 pt and the preview 240 pt, and under
    /// 600 pt the preview gives way and the list takes the view (the preference is kept for when there is room).
    /// `preview` includes the 1 pt divider line at its leading edge.
    static func layout(width: CGFloat, preference: CGFloat?, hidden: Bool) -> FilesSplitColumns {
        guard !hidden, width >= collapseWidth else { return FilesSplitColumns(list: width, preview: nil) }
        let preview = clampedPreview(preference ?? (width >= 1_000 ? 560 : width / 2), width: width)
        return FilesSplitColumns(list: width - preview, preview: preview)
    }

    /// The narrowest view that shows the preview beside the list.
    static let collapseWidth: CGFloat = 600
    static let minimumList: CGFloat = 320
    static let minimumPreview: CGFloat = 240

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

/// The list beside the preview, split where the tab's width (or the last one chosen) puts the divider. Only this view
/// reads the widths and the hidden flag, so dragging the divider or hiding the pane redraws the split and nothing above it.
/// The Changes tab puts its diff in the preview's place (`detail`), so both tabs share the divider and ⌥⌘P.
struct FilesSplit<List: View, Detail: View>: View {
    let session: FilesSession
    let list: List
    let detail: Detail

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let preference = TerminalRuntime.shared.files.previewPreference(for: session)
            let columns = FilesView.layout(width: width, preference: preference, hidden: session.previewHidden)
            // The list stays the HStack's first child whatever the preview does, so its outline keeps its identity
            // (and its scroll and selection) when the pane hides, shows or collapses.
            HStack(spacing: 0) {
                list.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let preview = columns.preview {
                    Chrome.border.frame(width: 1)
                    // Not mounted while hidden or collapsed: the pane's task is what loads the selection.
                    detail
                        .frame(width: preview - 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .overlay(alignment: .leading) {
                if let preview = columns.preview {
                    // Over the line and the edges of both columns, above the outline's and the preview's own views.
                    FilesPreviewDivider(session: session, preview: preview, width: width)
                        .frame(width: FilesPreviewDividerView.hitWidth)
                        .frame(maxHeight: .infinity)
                        .padding(.leading, columns.list + 0.5 - FilesPreviewDividerView.hitWidth / 2)
                }
            }
        }
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
    /// pane hidden by ⌥⌘P mid-drag, the view narrowed under 600 pt), so the cursor never stays a resize arrow.
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
            Image(systemName: "exclamationmark.triangle").font(.system(size: typography.size(offset: -3)))
            Text(verbatim: message).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(AppFont.ui(size: typography.size(offset: -2)))
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
            .font(AppFont.ui(size: typography.size(offset: -1)))
            .foregroundStyle(Chrome.palette.detail)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(identifier)
    }
}
