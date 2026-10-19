import AppKit
import SwiftUI

/// The Commits tab: the log as a graph with the selected commit beside it, read-only (F4a). `FilesHeader` carries its
/// branch, scope menu and search. The git data layer fills `log`,
/// `commitDetail` and `commitDiff`; this view asks through `logWanted`, `logScope`, `logFilter`, `selectedCommit` and
/// `commitFile`.
struct GitCommitsView: View {
    @Bindable var session: FilesSession
    let focused: Bool
    @FocusState private var focus: GitCommitsFocus?
    @State private var graph = GitGraphCache()
    /// The detail pane is mounted: the split leaves it out under 600 pt and while ⌥⌘P hides it, and then ⏎ has nowhere
    /// to take the keyboard.
    @State private var detailShown = false

    var body: some View {
        Group {
            if session.gitResolving {
                // Another folder's repository is being resolved: the last log is not this folder's.
                GitDelayedSpinner().accessibilityIdentifier("git-commits-resolving")
            } else {
                // The Files tab's split: the same divider, widths and ⌥⌘P as its preview and the Changes tab's diff.
                FilesSplit(session: session,
                           list: GitCommitsList(session: session, graph: graph, focus: $focus, detailShown: detailShown),
                           detail: GitCommitDetailPane(session: session, focus: $focus)
                               .onAppear { detailShown = true }
                               .onDisappear { detailShown = false })
            }
        }
        // ⌘C while the list or the commit's files have the keyboard: the selected commit's hash.
        .gitCopyShortcut(active: focus != nil) { session.selectedCommit }
        .onAppear {
            pickFirstFile()
            if focused { focus = .list }
        }
        .onChange(of: session.focusRequest) { _, _ in if focused { focus = .list } }
        .onChange(of: session.gitResolving) { _, resolving in if !resolving && focused { focus = .list } }
        .onChange(of: session.selectedCommit) { _, _ in
            // Another commit's files arrive with its detail; its first file is picked then.
            session.commitFile = nil
            pickFirstFile()
        }
        .onChange(of: session.commitDetail) { _, _ in pickFirstFile() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-commits")
    }

    /// The mockup opens the selected commit on its first file's diff; a file already picked in it stays.
    private func pickFirstFile() {
        guard let detail = session.commitDetail, detail.commit.hash == session.selectedCommit else { return }
        if let file = session.commitFile, detail.files.contains(where: { $0.path == file }) { return }
        session.commitFile = detail.files.first?.path
    }
}

enum GitCommitsFocus: Hashable {
    case list, files
}

/// The graph of the shown log, laid out again only when the log, HEAD or the uncommitted row change: the list reads
/// it on every render.
@MainActor final class GitGraphCache {
    private struct Key: Equatable {
        var loadedAt: Date?
        var count: Int
        var first: String?
        var last: String?
        var head: String?
        var uncommitted: Bool
        var linked: Bool
    }

    private var key: Key?
    private var value = GitGraph.empty

    func graph(for session: FilesSession) -> GitGraph {
        let commits = session.log?.commits ?? []
        let head = GitGraph.head(in: commits, status: session.status, scope: session.log?.scope ?? session.logScope)
        let key = Key(loadedAt: session.log?.loadedAt, count: commits.count, first: commits.first?.hash,
                      last: commits.last?.hash, head: head, uncommitted: (session.status?.changedFiles ?? 0) > 0,
                      linked: (session.log?.filter ?? session.logFilter).isEmpty)
        if key != self.key {
            self.key = key
            value = GitGraph.layout(commits, head: head, uncommitted: key.uncommitted, linked: key.linked)
        }
        return value
    }
}

/// The tab's texts, apart from the views so the fast tests read them.
enum GitCommitsText {
    /// The footer's "200 loaded · scroll for more", "148 loaded · all".
    static func footer(_ log: GitLog?) -> String {
        guard let log else { return "Loading the log…" }
        let count = FilesFormatting.count(log.commits.count)
        return log.exhausted ? "\(count) loaded · all" : "\(count) loaded · scroll for more"
    }

    static func files(_ count: Int) -> String {
        "\(FilesFormatting.count(count)) \(count == 1 ? "file" : "files")"
    }

    /// The detail's "35 min ago", "3 hours ago", "2 days ago", "just now".
    static func ago(_ date: Date, at reference: Date) -> String {
        let seconds = reference.timeIntervalSince(date)
        guard seconds >= 60 else { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = hours / 24
        if days < 365 { return days == 1 ? "1 day ago" : "\(days) days ago" }
        let years = days / 365
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }

    /// How the data layer keys a commit file's diff (`GitDiffState.key`).
    static func diffKey(hash: String, path: String) -> String { "\(hash):\(path)" }

    /// The commit the detail shows: the loaded detail's, else the log's row while the detail loads.
    @MainActor static func selected(_ session: FilesSession) -> GitCommit? {
        guard let hash = session.selectedCommit else { return nil }
        if let detail = session.commitDetail, detail.commit.hash == hash { return detail.commit }
        return session.log?.commits.first { $0.hash == hash }
    }
}

// MARK: Search

/// The header's search on Commits: the git data layer runs it as `--grep` and `--author` on the tab's host, so what is
/// typed applies after a 300 ms pause rather than on every key. Opened from the search glyph it takes the keyboard;
/// empty and left, it folds back (`fold`).
struct GitCommitsFilterField: View {
    @Bindable var session: FilesSession
    var focusOnAppear = false
    var fold: () -> Void = {}
    @Environment(\.appTypography) private var typography
    /// What is typed, as typed; nil shows the session's filter. Applying it trims it into `logFilter` and leaves the
    /// draft alone, so a space typed before the next word stays in the field.
    @State private var draft: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let palette = Chrome.palette
        let text = Binding(get: { draft ?? session.logFilter }, set: { draft = $0 })
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: typography.size(offset: -2.5)))
            TextField("Search commits", text: text, prompt: Text("Search commits").foregroundStyle(palette.detail))
                .textFieldStyle(.plain)
                .foregroundStyle(palette.ink)
                .focused($fieldFocused)
                .onSubmit {
                    finish(text.wrappedValue)
                    session.focusRequest = System.uuid()
                }
                .onExitCommand {
                    finish("")
                    session.focusRequest = System.uuid()
                }
                .onKeyPress(.downArrow) {
                    session.focusRequest = System.uuid()
                    return .handled
                }
                .accessibilityIdentifier("git-commits-filter")
            if !text.wrappedValue.isEmpty {
                Button { finish("") } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .help("Clear the search · esc")
                    .accessibilityIdentifier("git-commits-filter-clear")
            }
        }
        .foregroundStyle(palette.detail)
        .padding(.horizontal, 8)
        .frame(minWidth: typography.expanded(110), maxWidth: typography.expanded(170), minHeight: typography.expanded(22),
               maxHeight: typography.expanded(22))
        // On the header's glass pill the field is the pill's; flat, it is its own well.
        .background(RoundedRectangle(cornerRadius: 5).fill(LiquidGlassStore.shared.active ? .clear : palette.control))
        .overlay { if !LiquidGlassStore.shared.active { RoundedRectangle(cornerRadius: 5).strokeBorder(palette.controlBorder) } }
        .help("Search messages and authors · ⌘F")
        .task(id: draft) {
            // A key typed within the pause cancels this task and starts the next.
            guard GitCommitsFilter.applied(draft, filter: session.logFilter) != nil else { return }
            do { try await System.sleep(for: .milliseconds(300), "git.log-filter") } catch { return }
            if let value = GitCommitsFilter.applied(draft, filter: session.logFilter) { apply(value) }
        }
        .onChange(of: fieldFocused) { _, focused in
            settle()
            if !focused, text.wrappedValue.isEmpty { fold() }
        }
        .onChange(of: session.logFilter) { _, filter in
            settle()
            if filter.isEmpty, !fieldFocused, draft?.isEmpty ?? true { fold() }
        }
        .onChange(of: session.findRequest) { _, _ in fieldFocused = true }
        // Mounted by a click on the glyph or ⌘F: the keyboard comes once the field is in the window.
        .onAppear { if focusOnAppear { DispatchQueue.main.async { fieldFocused = true } } }
    }

    /// ⏎, esc and the clear button: `value` applies now and the field shows the filter again.
    private func finish(_ value: String) {
        if let value = GitCommitsFilter.applied(value, filter: session.logFilter) { apply(value) }
        draft = nil
    }

    /// The field left with nothing pending: the draft gives way to the filter it equals.
    private func settle() {
        if GitCommitsFilter.settled(draft, filter: session.logFilter, editing: fieldFocused) { draft = nil }
    }

    private func apply(_ value: String) {
        session.logFilter = value
        // Another query starts again from one page.
        session.logWanted = GitLoader.page
    }
}

/// The filter field's rule, apart from the view so the fast tests read it.
enum GitCommitsFilter {
    /// What a draft applies as the filter: its trimmed text, nil when that is the filter already.
    static func applied(_ draft: String?, filter: String) -> String? {
        guard let draft else { return nil }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == filter ? nil : value
    }

    /// Whether the draft can go: the field is not being edited and the draft says what the filter does. While it is
    /// edited the draft stays as typed, a trailing space included.
    static func settled(_ draft: String?, filter: String, editing: Bool) -> Bool {
        draft != nil && !editing && applied(draft, filter: filter) == nil
    }
}

// MARK: List

/// The log's rows under the hollow uncommitted-changes row, and the footer with the scope menu.
private struct GitCommitsList: View {
    @Bindable var session: FilesSession
    let graph: GitGraphCache
    var focus: FocusState<GitCommitsFocus?>.Binding
    let detailShown: Bool
    @Environment(\.appTypography) private var typography

    var body: some View {
        let commits = session.log?.commits ?? []
        let layout = graph.graph(for: session)
        let rowHeight = typography.expanded(28)
        let graphWidth = GitGraphCell.width(lanes: layout.lanes, scale: typography.expanded(1))
        let uncommitted = session.status?.changedFiles ?? 0
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        if uncommitted > 0 {
                            GitUncommittedButton(session: session, files: uncommitted, row: layout.top,
                                                 graphWidth: graphWidth, height: rowHeight)
                        }
                        ForEach(Array(commits.enumerated()), id: \.element.hash) { index, commit in
                            // A button, not a tap gesture: in the focusable scroll view a tap gesture never saw the
                            // click (as in the Changes list).
                            Button { select(commit.hash) } label: {
                                GitCommitRow(commit: commit, check: session.signatureChecks[commit.hash], row: index < layout.rows.count ? layout.rows[index] : nil,
                                             selected: commit.hash == session.selectedCommit, graphWidth: graphWidth,
                                             height: rowHeight)
                            }
                            .buttonStyle(.plain)
                            .id(commit.hash)
                            .onAppear { askForMore(seen: index, count: commits.count) }
                        }
                    }
                }
                // Over the rows' scroll view, so it lets clicks and scrolls through.
                .overlay { state(empty: commits.isEmpty && uncommitted == 0).allowsHitTesting(false) }
                .focusable()
                .focusEffectDisabled()
                .focused(focus, equals: .list)
                .onKeyPress(.upArrow) { move(-1, proxy: proxy) }
                .onKeyPress(.downArrow) { move(1, proxy: proxy) }
                .onKeyPress(.return) {
                    // Without the detail pane (narrow, or hidden by ⌥⌘P) the list keeps the keyboard.
                    guard session.selectedCommit != nil, detailShown else { return .ignored }
                    focus.wrappedValue = .files
                    return .handled
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("git-commits-list")
            }
            GitCommitsFooter(session: session)
        }
    }

    private func select(_ hash: String) {
        if session.selectedCommit != hash { session.selectedCommit = hash }
        focus.wrappedValue = .list
    }

    /// A row within 20 of the end raises the wanted count by a page, once a page: until the data layer has loaded
    /// what was asked, more rows appearing ask for nothing.
    private func askForMore(seen index: Int, count: Int) {
        guard let log = session.log, !log.exhausted, index >= count - 20, session.logWanted <= count else { return }
        session.logWanted += GitLoader.page
    }

    private func move(_ step: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let commits = session.log?.commits ?? []
        guard !commits.isEmpty else { return .ignored }
        let current = session.selectedCommit.flatMap { hash in commits.firstIndex { $0.hash == hash } }
        let next = current.map { min(max($0 + step, 0), commits.count - 1) } ?? (step > 0 ? 0 : commits.count - 1)
        let hash = commits[next].hash
        if session.selectedCommit != hash { session.selectedCommit = hash }
        proxy.scrollTo(hash)
        return .handled
    }

    @ViewBuilder private func state(empty: Bool) -> some View {
        if session.log == nil {
            GitCentredNote(text: "Loading the log…", identifier: "git-commits-loading")
        } else if empty {
            GitCentredNote(text: session.logFilter.isEmpty ? "No commits yet" : "No commits match “\(session.logFilter)”",
                           identifier: "git-commits-empty")
        }
    }
}

/// The hollow dot on top: the working tree's changes, which the Changes tab shows.
private struct GitUncommittedRow: View {
    let files: Int
    let row: GitGraph.Row?
    let graphWidth: CGFloat
    let height: CGFloat
    @Environment(\.appTypography) private var typography
    @State private var hovering = false

    var body: some View {
        let palette = Chrome.palette
        HStack(spacing: 0) {
            GitGraphCell(row: row, hollow: true, width: graphWidth, height: height)
            HStack(spacing: 8) {
                Text("Uncommitted changes")
                    .font(AppFont.ui(size: typography.size()))
                    .foregroundStyle(palette.sidebarHostLabel)
                Spacer(minLength: 8)
                Text(verbatim: GitCommitsText.files(files))
                    .font(AppFont.ui(size: typography.size(offset: -2)))
                    .foregroundStyle(palette.detail)
            }
            .lineLimit(1)
            .padding(.trailing, 12)
        }
        .frame(height: height)
        .background(hovering ? palette.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The uncommitted row as a button: a click opens the Changes tab, which takes the keyboard.
private struct GitUncommittedButton: View {
    let session: FilesSession
    let files: Int
    let row: GitGraph.Row?
    let graphWidth: CGFloat
    let height: CGFloat

    var body: some View {
        Button { session.select(.changes) } label: {
            GitUncommittedRow(files: files, row: row, graphWidth: graphWidth, height: height)
        }
        .buttonStyle(.plain)
        .help("Open the Changes tab · ⌃⌘2")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git-commits-uncommitted")
    }
}

/// One commit: the graph, the subject, its refs, its age at the right.
private struct GitCommitRow: View {
    let commit: GitCommit
    /// The signature's check, once the commit was selected and checked.
    var check: GitSignatureCheck?
    let row: GitGraph.Row?
    let selected: Bool
    let graphWidth: CGFloat
    let height: CGFloat
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        HStack(spacing: 0) {
            GitGraphCell(row: row, hollow: false, width: graphWidth, height: height)
            HStack(spacing: 8) {
                // The subject gives way first: the chips and the age keep their width.
                Text(verbatim: commit.subject)
                    .font(AppFont.ui(size: typography.size()))
                    .foregroundStyle(selected ? palette.ink : palette.secondary)
                    .truncationMode(.tail)
                ForEach(GitRefChip.ordered(commit.refs), id: \.self) { ref in
                    GitRefChip(ref: ref).fixedSize()
                }
                if let kind = commit.signature {
                    GitSignatureSeal(kind: kind, check: check)
                }
                Spacer(minLength: 8)
                // The age moves on by the minute with nothing reloaded.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(verbatim: FilesFormatting.age(commit.date, at: System.date()))
                        .font(AppFont.ui(size: typography.size(offset: -2)))
                        .foregroundStyle(selected ? palette.muted : palette.detail)
                        .fixedSize()
                }
            }
            .lineLimit(1)
            .padding(.trailing, 12)
        }
        .frame(height: height)
        .background(selected ? palette.ink.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .help(commit.subject)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("git-commit-\(commit.short)")
    }
}

/// The lanes of one row on a 14 pt grid with the first lane 22 pt in (F4a's svg): the lines, the dot over them, and
/// a count of deeper lanes at the left edge.
struct GitGraphCell: View {
    let row: GitGraph.Row?
    let hollow: Bool
    let width: CGFloat
    let height: CGFloat
    @Environment(\.appTypography) private var typography
    @Environment(\.chatTheme) private var theme

    /// Two lanes' room at least, so a short log's subjects line up with a longer one's.
    static func width(lanes: Int, scale: CGFloat) -> CGFloat {
        max(56, 42 + 14 * CGFloat(max(lanes, 1) - 1)) * scale
    }

    static func x(_ lane: Int, scale: CGFloat) -> CGFloat { (22 + 14 * CGFloat(lane)) * scale }

    var body: some View {
        let palette = Chrome.palette
        let green = palette.green, amber = palette.warning, background = theme.terminal, faint = palette.detail
        let scale = typography.expanded(1)
        let countFont = AppFont.ui(size: max(8, typography.size(offset: -4)))
        Canvas { context, size in
            guard let row else { return }
            let middle = size.height / 2
            for line in row.lines {
                let from = Self.x(line.from, scale: scale), to = Self.x(line.to, scale: scale)
                var path = Path()
                switch line.kind {
                case .pass:
                    path.move(to: CGPoint(x: from, y: 0))
                    path.addLine(to: CGPoint(x: from, y: size.height))
                case .into:
                    // Down its own lane, then across into the dot.
                    path.move(to: CGPoint(x: from, y: 0))
                    let end = CGPoint(x: to, y: middle)
                    if from == to {
                        path.addLine(to: end)
                    } else {
                        path.addCurve(to: end, control1: CGPoint(x: from, y: middle), control2: CGPoint(x: from, y: middle))
                    }
                case .out:
                    // Across from the dot, then down the parent's lane.
                    path.move(to: CGPoint(x: from, y: middle))
                    let end = CGPoint(x: to, y: size.height)
                    if from == to {
                        path.addLine(to: end)
                    } else {
                        path.addCurve(to: end, control1: CGPoint(x: to, y: middle), control2: CGPoint(x: to, y: middle))
                    }
                }
                context.stroke(path, with: .color(line.current ? green : amber), lineWidth: 2 * scale)
            }
            let color = row.current ? green : amber
            if row.lane < GitGraph.maxLanes {
                let radius = 4.5 * scale
                let dot = Path(ellipseIn: CGRect(x: Self.x(row.lane, scale: scale) - radius, y: middle - radius,
                                                 width: radius * 2, height: radius * 2))
                if hollow {
                    context.fill(dot, with: .color(background))
                    context.stroke(dot, with: .color(color), lineWidth: 2 * scale)
                } else {
                    context.fill(dot, with: .color(color))
                }
            }
            if row.hidden > 0 {
                // The commit's own lane among the hidden ones: the count takes its dot's colour.
                let count = Text(verbatim: "+\(row.hidden)").font(countFont)
                    .foregroundStyle(row.lane >= GitGraph.maxLanes ? color : faint)
                context.draw(count, at: CGPoint(x: 1, y: middle), anchor: .leading)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// A ref on a commit (F4a): the checked-out branch filled green, a tag amber text, other branches and remotes
/// outlined.
struct GitRefChip: View {
    let ref: GitRef
    @Environment(\.appTypography) private var typography

    /// The checked-out branch first, then local branches, remotes and tags, each kind in git's order.
    static func ordered(_ refs: [GitRef]) -> [GitRef] {
        func rank(_ ref: GitRef) -> Int {
            if ref.current { return 0 }
            switch ref.kind {
            case .head: return 0
            case .branch: return 1
            case .remote: return 2
            case .tag: return 3
            }
        }
        return refs.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    static func filled(_ ref: GitRef) -> Bool { ref.current || ref.kind == .head }

    var body: some View {
        let palette = Chrome.palette
        let filled = Self.filled(ref)
        Text(verbatim: ref.name)
            .font(AppFont.ui(size: typography.size(offset: -2.5)))
            .foregroundStyle(filled ? palette.green : ref.kind == .tag ? palette.warning : palette.muted)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: typography.expanded(16))
            .background { if filled { Capsule().fill(palette.green.opacity(0.18)) } }
            .overlay { if !filled { Capsule().strokeBorder(palette.selectedControl) } }
            .help(Self.help(ref))
    }

    static func help(_ ref: GitRef) -> String {
        switch ref.kind {
        case .head: "HEAD"
        case .branch: ref.current ? "\(ref.name) · checked out" : "Branch \(ref.name)"
        case .remote: "Remote branch \(ref.name)"
        case .tag: "Tag \(ref.name)"
        }
    }
}

/// The 24 pt line under the list: how much of the log is loaded, and the scope.
private struct GitCommitsFooter: View {
    @Bindable var session: FilesSession
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        HStack(spacing: 0) {
            Text(verbatim: GitCommitsText.footer(session.log))
                .accessibilityIdentifier("git-commits-footer-summary")
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: typography.expanded(24))
        .font(AppFont.ui(size: typography.size(offset: -2)))
        .foregroundStyle(palette.detail)
        .background(Chrome.window)
        .overlay(alignment: .top) { palette.separator.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-commits-footer")
    }
}

// MARK: Detail

/// The selected commit (F4a's right pane): subject, hash, author, date, refs, body, its files, and under them the
/// picked file's diff.
private struct GitCommitDetailPane: View {
    @Bindable var session: FilesSession
    var focus: FocusState<GitCommitsFocus?>.Binding

    var body: some View {
        if let commit = GitCommitsText.selected(session) {
            GitCommitDetailStack {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        GitCommitSummary(session: session, commit: commit)
                        GitCommitFiles(session: session, commit: commit, focus: focus)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                GitCommitDiff(session: session)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("git-commit-detail")
        } else {
            GitCentredNote(text: "Select a commit to see its files", identifier: "git-commit-detail-empty")
        }
    }
}

/// The detail's summary over its diff: the summary at its own height up to half the pane (160 pt at least), where it
/// scrolls instead, and the diff in the rest. A layout rather than a measured height, so no frame shows the summary
/// at a stale size.
private struct GitCommitDetailStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let natural = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        let top = min(natural, max(bounds.height * 0.5, 160), bounds.height).rounded()
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: top))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top),
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height - top))
    }
}

private struct GitCommitSummary: View {
    let session: FilesSession
    let commit: GitCommit
    @Environment(\.appTypography) private var typography
    /// The hash just copied: its button shows a check for a moment.
    @State private var copied: String?

    var body: some View {
        let palette = Chrome.palette
        let notice = FilesEditorNotices.shared.notice(for: session.id)
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: commit.subject)
                // Prose in the system face, as the mockup sets the subject and body; the rest stays in the UI font.
                .font(.system(size: typography.size(offset: 1.5), weight: .semibold))
                .foregroundStyle(palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("git-commit-subject")
            HStack(spacing: 10) {
                Button(action: copyHash) {
                    HStack(spacing: 5) {
                        Text(verbatim: commit.short)
                        Image(systemName: copied == commit.hash ? "checkmark" : "doc.on.doc")
                            .font(.system(size: typography.size(offset: -2)))
                    }
                    .foregroundStyle(palette.green)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy \(commit.hash) · ⌘C")
                .accessibilityLabel(commit.short)
                .accessibilityIdentifier("git-commit-hash")
                Text("·").foregroundStyle(palette.faint)
                Text(verbatim: commit.author)
                    .help(commit.email)
                Text("·").foregroundStyle(palette.faint)
                // The age moves on by the minute with nothing reloaded.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    let now = System.date()
                    Text(verbatim: GitCommitsText.ago(commit.date, at: now))
                        .help(FilesFormatting.timestamp(commit.date, now: now))
                }
                if !commit.refs.isEmpty {
                    Text("·").foregroundStyle(palette.faint)
                    ForEach(GitRefChip.ordered(commit.refs), id: \.self) { GitRefChip(ref: $0).fixedSize() }
                }
                Spacer(minLength: 0)
                if let notice {
                    Text(verbatim: notice)
                        .foregroundStyle(palette.warning)
                        .fixedSize()
                        .accessibilityIdentifier("git-commit-notice")
                }
                Button("git show ›") {
                    // Typed into the tab's shell, with -C when that shell is outside the repository.
                    guard let root = session.git.repository?.root else { return }
                    FilesEditor.runGit("show \(commit.hash)", repository: root, tab: session.id,
                                       files: TerminalRuntime.shared.files)
                }
                .buttonStyle(FilePreviewButtonStyle())
                .help("Switches to the terminal and types git show \(commit.short)")
                .accessibilityIdentifier("git-commit-show")
            }
            .font(AppFont.ui(size: typography.size(offset: -1)))
            .foregroundStyle(palette.muted)
            .lineLimit(1)
            // The log read which commits are signed; the detail's own copy of the commit does not say.
            if let kind = session.log?.commits.first(where: { $0.hash == commit.hash })?.signature {
                GitSignatureLine(kind: kind, check: session.signatureChecks[commit.hash])
            }
            if !commit.body.isEmpty {
                Text(verbatim: commit.body)
                    .font(.system(size: typography.size(offset: -0.5)))
                    .lineSpacing(3)
                    .foregroundStyle(palette.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: typography.expanded(480), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("git-commit-body")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
    }

    private func copyHash() {
        GitPasteboard.copy(commit.hash)
        let hash = commit.hash
        copied = hash
        Task { @MainActor in
            try? await System.sleep(for: .seconds(1.5), "git.copied-hash")
            if copied == hash { copied = nil }
        }
    }
}

/// "CHANGED FILES 3  +12 −5" and the commit's files; a click (or ↑↓ once ⏎ moved focus here) picks the diff below.
private struct GitCommitFiles: View {
    @Bindable var session: FilesSession
    let commit: GitCommit
    var focus: FocusState<GitCommitsFocus?>.Binding
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        let detail = session.commitDetail.flatMap { $0.commit.hash == commit.hash ? $0 : nil }
        let files = detail?.files ?? []
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("CHANGED FILES").tracking(0.4)
                if detail != nil {
                    Text(verbatim: " \(FilesFormatting.count(files.count))").foregroundStyle(palette.muted)
                }
                Spacer(minLength: 8)
                if detail != nil {
                    GitCounts(additions: files.reduce(0) { $0 + ($1.additions ?? 0) },
                              deletions: files.reduce(0) { $0 + ($1.deletions ?? 0) })
                        .font(AppFont.ui(size: typography.size(offset: -1.5)))
                }
            }
            .font(AppFont.ui(size: typography.size(offset: -2)))
            .foregroundStyle(palette.detail)
            .padding(.horizontal, 16)
            .frame(height: typography.expanded(28))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("git-commit-files-header")
            if detail == nil, let error = session.commitDetailError {
                HStack(spacing: 10) {
                    Text(verbatim: error)
                        .foregroundStyle(palette.warning)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("git-commit-files-error")
                    Button("Try again") { TerminalRuntime.shared.files.refresh(session.id) }
                        .buttonStyle(FilePreviewButtonStyle())
                        .help("Read the commit again · ⌘R")
                        .accessibilityIdentifier("git-commit-files-retry")
                    Spacer(minLength: 0)
                }
                .font(AppFont.ui(size: typography.size(offset: -1.5)))
                .padding(.horizontal, 16)
                .frame(minHeight: typography.expanded(32))
            } else if detail == nil {
                Text("Loading files…")
                    .font(AppFont.ui(size: typography.size(offset: -1.5)))
                    .foregroundStyle(palette.detail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: typography.expanded(32))
                    .accessibilityIdentifier("git-commit-files-loading")
            } else {
                VStack(spacing: 0) {
                    ForEach(files) { file in
                        // A button, not a tap gesture, as for the log's rows.
                        Button {
                            session.commitFile = file.path
                            focus.wrappedValue = .files
                        } label: {
                            GitCommitFileRow(file: file, selected: file.path == session.commitFile,
                                             diff: file.path == session.commitFile ? GitCommitDiff.shown(session)?.diff : nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused(focus, equals: .files)
                .onKeyPress(.upArrow) { move(-1, in: files) }
                .onKeyPress(.downArrow) { move(1, in: files) }
                .onKeyPress(.leftArrow) { focus.wrappedValue = .list; return .handled }
                .onKeyPress(.escape) { focus.wrappedValue = .list; return .handled }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("git-commit-files")
            }
        }
        .padding(.bottom, 6)
    }

    private func move(_ step: Int, in files: [GitChange]) -> KeyPress.Result {
        guard !files.isEmpty else { return .ignored }
        let current = session.commitFile.flatMap { path in files.firstIndex { $0.path == path } }
        let next = current.map { min(max($0 + step, 0), files.count - 1) } ?? 0
        session.commitFile = files[next].path
        return .handled
    }
}

private struct GitCommitFileRow: View {
    let file: GitChange
    let selected: Bool
    /// The file's loaded diff while it is picked: it carries a binary's sizes when the detail did not.
    let diff: GitDiff?
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        HStack(spacing: 10) {
            GitChangeBadge(kind: file.kind)
            Text(verbatim: file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(AppFont.ui(size: typography.size()))
                .foregroundStyle(palette.ink)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            GitCounts(additions: file.additions, deletions: file.deletions,
                      binary: file.binary ? GitChangesText.binary(old: file.oldSize ?? diff?.oldSize,
                                                                  new: file.newSize ?? diff?.newSize, kind: file.kind) : nil)
                .font(AppFont.ui(size: typography.size(offset: -1.5)))
        }
        .lineLimit(1)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: typography.expanded(32))
        .background(selected ? palette.ink.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .help(file.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("git-commit-file-\(file.path)")
    }
}

/// The picked file's diff in the shared view, or why there is none yet.
private struct GitCommitDiff: View {
    @Bindable var session: FilesSession

    /// The loaded diff when it is the picked file's in the selected commit: the data layer keys it "<hash>:<path>", so
    /// the same path in another commit, or a diff left from the file picked before, is never shown as this one.
    @MainActor static func shown(_ session: FilesSession) -> GitDiffState? {
        guard let hash = session.selectedCommit, let path = session.commitFile, let state = session.commitDiff,
              state.key == GitCommitsText.diffKey(hash: hash, path: path) else { return nil }
        return state
    }

    /// Source and the lines between hunks read the file as the commit left it; a file the commit deleted has none.
    private func reader(_ diff: GitDiff) -> (@Sendable () async throws -> String)? {
        guard let source = session.source, let root = session.git.repository?.root,
              let detail = session.commitDetail, detail.commit.hash == session.selectedCommit,
              let file = detail.files.first(where: { $0.path == diff.path }), file.kind != .deleted else { return nil }
        let queries = GitQueries(source: source, root: root), commit = detail.commit, oldPath = file.oldPath
        return {
            do throws(GitError) {
                return try await queries.commitSource(commit, path: diff.path, oldPath: oldPath)
            } catch {
                throw GitSourceError(message: error.message)
            }
        }
    }

    var body: some View {
        let palette = Chrome.palette
        let state = Self.shown(session)
        VStack(spacing: 0) {
            palette.separator.frame(height: 1)
            if session.commitFile == nil {
                Color.clear
            } else if let state, let diff = state.diff {
                GitDiffView(diff: diff, mode: $session.diffMode, source: reader(diff))
                    // Each commit's file gets its own folds, scroll and cursor.
                    .id(state.key)
            } else if let error = state?.error {
                GitCentredNote(text: error, identifier: "git-commit-diff-error")
            } else {
                GitDelayedSpinner().accessibilityIdentifier("git-commit-diff-loading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-commit-diff")
    }
}

// MARK: Signatures

/// A signed commit's seal in the log: the kind of signature until it is checked (selecting the commit checks it), then
/// the verdict's glyph and color.
struct GitSignatureSeal: View {
    let kind: GitSignatureKind
    let check: GitSignatureCheck?
    @Environment(\.appTypography) private var typography

    var body: some View {
        let look = GitSignatureText.look(check)
        Image(systemName: look.symbol)
            .font(.system(size: typography.size(offset: -1.5)))
            .foregroundStyle(look.color)
            .help(check.map { GitSignatureText.line($0, kind: kind) } ?? "Signed with \(kind.title) · select to verify")
            .accessibilityLabel(check.map { GitSignatureText.line($0, kind: kind) } ?? "Signed with \(kind.title)")
            .accessibilityIdentifier("git-commit-seal")
    }
}

/// The selected commit's signature under its hash and author: checking, then the verdict, the signer and the key.
struct GitSignatureLine: View {
    let kind: GitSignatureKind
    let check: GitSignatureCheck?
    @Environment(\.appTypography) private var typography

    var body: some View {
        let look = GitSignatureText.look(check)
        HStack(spacing: 6) {
            if check == nil {
                ProgressView().controlSize(.mini)
                Text(verbatim: "Checking the \(kind.title) signature…").foregroundStyle(Chrome.palette.detail)
            } else if let check {
                Image(systemName: look.symbol).foregroundStyle(look.color)
                Text(verbatim: GitSignatureText.line(check, kind: kind)).foregroundStyle(look.color)
                    .textSelection(.enabled)
            }
        }
        .font(AppFont.ui(size: typography.size(offset: -1)))
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git-commit-signature")
    }
}

/// The signature's words and look, apart from the views so the fast tests read them.
enum GitSignatureText {
    struct Look {
        let symbol: String
        let color: Color
    }

    @MainActor static func look(_ check: GitSignatureCheck?) -> Look {
        let palette = Chrome.palette
        switch check?.verdict {
        case nil, .unsigned?, .unchecked?: return Look(symbol: "seal", color: palette.detail)
        case .good(let certified)?: return Look(symbol: "checkmark.seal.fill", color: certified ? palette.green : palette.secondary)
        case .bad?, .revokedKey?: return Look(symbol: "xmark.seal.fill", color: ChatThemeStore.shared.current.red)
        case .unknownKey?, .expiredSignature?, .expiredKey?: return Look(symbol: "exclamationmark.triangle.fill", color: palette.warning)
        }
    }

    /// "Good GPG signature · Paul Miller <paul@example.com> · 697079DA6878B89B".
    static func line(_ check: GitSignatureCheck, kind: GitSignatureKind) -> String {
        let name = (check.kind ?? kind).title
        let verdict = switch check.verdict {
        case .good(true): "Good \(name) signature"
        case .good(false): "Good \(name) signature, key not certified"
        case .bad: "Bad \(name) signature"
        case .unknownKey: (check.kind ?? kind) == .ssh ? "\(name) signature from a key not in your allowed signers"
                                                       : "\(name) signature from a key not in your keyring"
        case .expiredSignature: "Expired \(name) signature"
        case .expiredKey: "\(name) signature from an expired key"
        case .revokedKey: "\(name) signature from a revoked key"
        case .unsigned: "Not signed"
        case .unchecked(let reason): "Signed with \(name) · couldn’t check: \(reason)"
        }
        return ([verdict] + [check.signer, check.key].compactMap { $0 }).joined(separator: " · ")
    }
}

