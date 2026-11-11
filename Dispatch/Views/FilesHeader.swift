import SwiftUI
import UniformTypeIdentifiers

/// The 34 pt bar over the tab (F2a, F4a), laid out the same on every tab: the tab's name, where you are, then (on
/// Review and Commits) Create Review with the comments' count; at the trailing end the search, on Commits the
/// filter (`GitLogFilterButton`), and the Single view toggle (where two views fit: one view or both). The mode's label keeps its width drilled or not (`FilesBackButton.label`).
/// Where you are is the path as crumbs on Files (a right click offering Finder's folder menu, the follow-the-shell link
/// after it, the host first), and on Review and Commits the repository and its branch. The Files tab shows nothing of
/// git. The files tabs are not here: the strip's mode button names the one shown and its menu switches (and ⌃⌘1–3).
/// On one column with a row's detail in the list's place (`FilesSession.drilled`) the name is a button back to the list,
/// what is open follows it (the file; the change, a menu of the others; the commit's subject), and on the git tabs ↑ ↓
/// step to the next change or commit.
struct FilesHeader: View {
    @Bindable var session: FilesSession
    let root: String?
    /// The tab's pane has the keyboard: ⇧⌘⏎ is Create review's.
    var focused = true
    @Environment(\.appTypography) private var typography
    @Environment(\.chatTheme) private var theme
    /// Room for the floating mode switch over the header's trailing end.
    @Environment(\.filesHeaderAccessory) private var accessory
    @FocusState private var filterFocused: Bool
    /// The search shows as its glyph until clicked or ⌘F, and folds back once it is empty and loses focus.
    @State private var searching = false
    /// The one-column Review's list of changes is open under the change's name.
    @State private var choosingChange = false
    private var glass: Bool { LiquidGlassStore.shared.active }
    /// The bar's height.
    static func height(_ typography: AppTypography) -> CGFloat { typography.expanded(34) }

    var body: some View {
        let palette = Chrome.palette
        HStack(spacing: 12) {
            tabName.layoutPriority(1)
            // Where you are: the crumbs fold and clip rather than push the controls out.
            Group {
                if session.drilled {
                    opened
                } else if session.tab == .files {
                    HStack(spacing: 6) {
                        crumbs(root)
                        // The link belongs to the folder it follows: right after the path, the crumbs folding before it.
                        if root != nil { followToggle.layoutPriority(1) }
                    }
                } else {
                    repositoryLine
                }
            }
            .frame(minWidth: 0, alignment: .leading)
            .clipped()
            .layoutPriority(0.5)
            if session.tab == .files, session.source?.readOnly == true { FilesReadOnlyTag() }
            // One review for both git tabs: a commit's lines take comments too.
            if session.tab != .files, session.gitUnavailable == nil {
                ReviewHeaderButton(session: session, focused: focused).layoutPriority(1)
            }
            // Why cd Here typed nothing: here, so it shows whichever pane is shown or hidden.
            if let notice = FilesTerminalNotices.shared.notice(for: session.id) {
                Text(verbatim: notice)
                    .font(typography, .body)
                    .foregroundStyle(theme.yellow)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
                    .accessibilityIdentifier("files-notice")
            }
            Spacer(minLength: 0)
            if session.drilled, session.tab != .files {
                HStack(spacing: glass ? 2 : 12) {
                    stepButton(-1)
                    stepButton(1)
                }
                .glassControlGroup()
                .layoutPriority(1)
            }
            // The search and the pane's toggle: one glass pill with Liquid Glass.
            HStack(spacing: glass ? 2 : 12) {
                searchSlot
                if session.tab == .commits { GitLogFilterButton(session: session) }
                // Nothing to switch where two views do not fit.
                if session.canShowBoth { viewsToggle }
            }
            .glassControlGroup()
            .layoutPriority(1)
            if let accessory { accessory.fixedSize().layoutPriority(1) }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(height: Self.height(typography))
        .frame(maxWidth: .infinity)
        .font(typography, .label)
        .foregroundStyle(palette.muted)
        .background(Chrome.window)
        // Glass controls carry the bar themselves; the flat bar keeps its rule.
        .overlay(alignment: .bottom) { if !glass { palette.separator.frame(height: 1) } }
        .onChange(of: session.findRequest) { _, _ in
            // ⌘F goes to the preview's find while the preview has focus and shows text (that pane answers it); an
            // image, a folder or a notice has nothing to find, so the search takes it. On the git tabs it goes to the
            // diff's find while the diff has the keyboard (`GitDiffView` answers it), else to the search.
            let paneFinds = session.tab == .files ? session.previewFocused && session.preview?.findable == true
                : session.diffFocused
            if !paneFinds { openSearch() }
        }
        .onChange(of: filterFocused) { _, focused in
            if !focused, searchText.isEmpty { searching = false }
        }
        .onChange(of: searchText) { _, text in
            if text.isEmpty, !filterFocused { searching = false }
        }
        // Moving between Commits' rows keeps its search open.
        .onChange(of: session.tab == .files ? 0 : session.showsLog ? 1 : 2) { _, _ in searching = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-header")
    }

    /// The files tab's name as the header leads with it.
    static func title(_ tab: FilesTab) -> String {
        switch tab {
        case .files: "Files"
        case .changes: "Review"
        case .commits: "Commits"
        }
    }

    // MARK: Tab, back, opened

    /// The tab's name; on one column with a detail shown, a button back to the list: "‹", the tab's glyph, its name.
    /// The mode's label (its glyph and name), the way back once drilled: as wide either way (`FilesBackButton.label`).
    @ViewBuilder private var tabName: some View {
        if session.drilled {
            FilesBackButton(session: session)
        } else {
            FilesBackButton.label(session.tab, typography: typography, back: false)
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.title(session.tab))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("files-tab-title")
        }
    }

    /// What one column shows in the list's place: the file previewed, the change (its name a menu of the others, then
    /// where it is among them), the commit's subject.
    @ViewBuilder private var opened: some View {
        let palette = Chrome.palette
        switch session.tab {
        case .files:
            let path = session.preview?.path
            Text(verbatim: path.map(FilesPath.name) ?? "")
                .font(typography, .label, weight: .semibold)
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path ?? "")
                .accessibilityIdentifier("files-opened")
        case .changes:
            let changes = session.orderedChanges
            if let index = changes.firstIndex(where: { $0.id == session.changesSelection }) {
                let change = changes[index]
                HStack(spacing: 8) {
                    changesMenu(change, changes)
                    if changes.count > 1 {
                        Text(verbatim: "\(index + 1) of \(changes.count)")
                            .font(typography, .caption)
                            .foregroundStyle(palette.detail)
                            .fixedSize()
                            .accessibilityIdentifier("files-opened-position")
                    }
                }
            }
        case .commits where session.drilledFile:
            // A commit's file: its name (the path in its tooltip), then where it is among the commit's files.
            let files = session.commitDetail?.files ?? []
            if let path = session.commitFile {
                HStack(spacing: 8) {
                    Text(verbatim: FilesPath.name(path))
                        .font(typography, .label, weight: .semibold)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                        .accessibilityIdentifier("files-opened")
                    if files.count > 1, let index = files.firstIndex(where: { $0.path == path }) {
                        Text(verbatim: "\(index + 1) of \(files.count)")
                            .font(typography, .caption)
                            .foregroundStyle(palette.detail)
                            .fixedSize()
                            .accessibilityIdentifier("files-opened-position")
                    }
                }
            }
        case .commits:
            if let commit = GitCommitsText.selected(session) {
                Text(verbatim: commit.subject)
                    .font(typography, .label, weight: .semibold)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .help(commit.subject)
                    .accessibilityIdentifier("files-opened")
            }
        }
    }

    /// The change shown; a click lists every change (by area, the shown one checked) to show another.
    private func changesMenu(_ change: GitChange, _ changes: [GitChange]) -> some View {
        let palette = Chrome.palette
        return Button { choosingChange = true } label: {
            HStack(spacing: 6) {
                GitChangeBadge(kind: change.kind, side: 14, plain: true)
                Text(verbatim: change.name)
                    .font(typography, .label, weight: .semibold)
                    .foregroundStyle(palette.ink)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(typography.symbol(.micro, weight: .semibold))
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(change.path)
        .accessibilityLabel(change.path)
        .accessibilityIdentifier("files-opened")
        .popover(isPresented: $choosingChange, arrowEdge: .bottom) {
            FilesChangeChooser(changes: changes, selection: session.changesSelection) { id in
                session.changesSelection = id
                choosingChange = false
            }
        }
    }

    /// ↑ or ↓ on one column: the previous or next change or commit, in the list's order.
    private func stepButton(_ delta: Int) -> some View {
        let noun = session.drilledFile ? "file" : session.tab == .commits ? "commit" : "change"
        return Button { session.step(by: delta) } label: {
            Image(systemName: delta < 0 ? "chevron.up" : "chevron.down")
                .font(typography.symbol(.body))
                .frame(minWidth: typography.expanded(22), minHeight: typography.expanded(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(FilesHeaderButtonStyle())
        .help(delta < 0 ? "Previous \(noun)" : "Next \(noun)")
        .accessibilityLabel(delta < 0 ? "Previous \(noun)" : "Next \(noun)")
        .accessibilityIdentifier(delta < 0 ? "files-step-previous" : "files-step-next")
    }

    // MARK: Crumbs

    private func crumbs(_ root: String?) -> some View {
        let all = root.map { session.crumbs(root: $0) } ?? []
        // Long paths keep their first crumb and as many of the last as fit; the middle folds into "…".
        return ViewThatFits(in: .horizontal) {
            crumbRow(all, root: root, keepingLast: nil)
            ForEach([4, 3, 2, 1], id: \.self) { last in
                if all.count > last + 1 { crumbRow(all, root: root, keepingLast: last) }
            }
            crumbRow(all, root: root, keepingLast: 0)
            // Too narrow even for "… / api": the folder's name alone, else nothing, rather than a row clipped to a dot.
            if let last = all.last {
                Text(verbatim: last.title)
                    .font(typography, .label)
                    .foregroundStyle(Chrome.palette.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(last.path)
                    .accessibilityLabel(root.map { FilesPath.crumbLine(root: $0, home: session.home, host: session.hostLabel) } ?? "")
                    .accessibilityIdentifier("files-crumbs")
            }
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func crumbRow(_ all: [FilesCrumb], root: String?, keepingLast last: Int?) -> some View {
        let palette = Chrome.palette
        // (index in `all`, crumb); nil marks the fold.
        var shown: [(Int, FilesCrumb)?] = Array(all.enumerated()).map { $0 }
        if let last, all.count > last + 1 {
            shown = last == 0 ? [nil, (all.count - 1, all[all.count - 1])]
                : [(0, all[0]), nil] + all.indices.suffix(last).map { ($0, all[$0]) }
        }
        return HStack(spacing: 6) {
            if let host = session.hostLabel {
                Text(host).foregroundStyle(theme.blue)
                Text(":").foregroundStyle(palette.faint)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { position, item in
                // No separator after the file system root's own "/".
                if position > 0, shown[position - 1]?.1.title != "/" {
                    Text("/").foregroundStyle(palette.faint)
                }
                if let item {
                    let index = item.0, crumb = item.1
                    let current = index == all.count - 1
                    Button { session.pin(crumb.path) } label: {
                        Text(crumb.title).foregroundStyle(current ? palette.secondary : palette.sidebarDetail)
                    }
                    .buttonStyle(.plain)
                    .help(current ? "\(crumb.path) · shown" : "Show \(crumb.path)")
                    .contextMenu { crumbMenu(crumb.path, root: all.last?.path ?? crumb.path) }
                    .accessibilityIdentifier("files-crumb-\(index)")
                } else {
                    // The folded folders, as Finder's title menu lists a window's enclosing folders.
                    let folded = all.filter { crumb in !shown.contains { $0?.1.path == crumb.path } }
                    Menu {
                        ForEach(folded.reversed(), id: \.path) { crumb in
                            Button(crumb.title) { session.pin(crumb.path) }
                        }
                    } label: {
                        Text("…").foregroundStyle(palette.sidebarDetail)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Folders in between")
                    .accessibilityIdentifier("files-crumb-folded")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(root.map { FilesPath.crumbLine(root: $0, home: session.home, host: session.hostLabel) } ?? "")
        .accessibilityIdentifier("files-crumbs")
        .font(typography, .label)
        .lineLimit(1)
        .fixedSize()
    }

    /// Lit while the view follows the shell's cd; a click pins the folder shown, or follows the shell again.
    private var followToggle: some View {
        let following = session.followsShell
        return Button {
            if following { root.map { session.pin($0) } } else { session.followShell() }
        } label: {
            Image(systemName: "link")
                .font(typography.symbol(.body))
                .frame(minWidth: typography.expanded(22), minHeight: typography.expanded(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(FilesHeaderButtonStyle(on: following))
        .help(following ? "Following the shell’s directory · click to stay in this folder"
                        : "Follow the shell’s directory")
        .accessibilityLabel("Follow the shell’s directory")
        .accessibilityValue(following ? "On" : "Off")
        .accessibilityIdentifier("files-follow-shell")
    }

    /// "main · 2 ahead of origin/main · 4 files uncommitted · Commits ⌃⌘3".
    /// Review's and Commits' place: the repository's name, its branch and how far it is from its upstream. No host and
    /// no path: on these tabs neither changes what they show, and the crumbs' clicks are the Files tab's.
    private var repositoryLine: some View {
        let palette = Chrome.palette
        let name = session.git.repository.map { FilesPath.name($0.root) } ?? ""
        let status = session.git.repository == nil ? nil : session.status
        return HStack(spacing: 6) {
            Text(verbatim: name).foregroundStyle(palette.secondary)
            if let status {
                Image(systemName: "arrow.triangle.branch")
                    .font(typography.symbol(.caption))
                    .foregroundStyle(palette.faint)
                Text(verbatim: GitChangesText.branch(status)).truncationMode(.middle)
                if status.ahead > 0 { Text(verbatim: "↑\(status.ahead)").foregroundStyle(palette.green) }
                if status.behind > 0 { Text(verbatim: "↓\(status.behind)").foregroundStyle(palette.warning) }
            }
        }
        .font(typography, .label)
        .lineLimit(1)
        .help(session.git.repository?.root ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.repositoryLabel(name: name, status: status))
        .accessibilityIdentifier("files-location")
    }

    /// "api · main · 2 ahead of origin/main", as VoiceOver reads the repository line.
    static func repositoryLabel(name: String, status: GitStatus?) -> String {
        ([name] + (status.map { [branchHelp($0)] } ?? [])).joined(separator: " · ")
    }

    static func branchHelp(_ status: GitStatus) -> String {
        var parts = [GitChangesText.branch(status)]
        if let upstream = status.upstream {
            let moves = [status.ahead > 0 ? "\(status.ahead) ahead" : nil, status.behind > 0 ? "\(status.behind) behind" : nil]
                .compactMap { $0 }
            parts.append(moves.isEmpty ? "up to date with \(upstream)" : moves.joined(separator: ", ") + " of \(upstream)")
        }
        return parts.joined(separator: " · ")
    }

    /// A crumb's right click, as Finder's title menu: the shown folder, then each one enclosing it down to "/", each
    /// with its icon (choosing one shows it); then copy, reveal in Finder (this Mac) and cd for the crumb clicked.
    @ViewBuilder private func crumbMenu(_ path: String, root: String) -> some View {
        let local = session.source?.endpoint.isLocal == true
        ForEach(FilesPath.ancestors(root), id: \.self) { folder in
            Button {
                if folder != root { session.pin(folder) }
            } label: {
                Label { Text(Self.menuTitle(folder, local: local, host: session.hostLabel)) } icon: {
                    Image(nsImage: Self.menuIcon(folder, local: local, home: session.home))
                }
            }
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        if local {
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
        }
        Button("cd Here") { _ = TerminalRuntime.shared.files.changeDirectory(session.id, to: path) }
    }

    /// A folder's name in the title menu; "/" is this Mac's startup disk, or the host.
    static func menuTitle(_ folder: String, local: Bool, host: String?) -> String {
        guard folder == "/" else { return FilesPath.name(folder) }
        return local ? FileManager.default.displayName(atPath: "/") : host ?? "/"
    }

    /// Finder's own icon on this Mac; on a host, a folder, the home folder or the disk drawn as Finder does.
    /// Generic icons only, on this Mac as on a host: SwiftUI builds a context menu's items with the view, so every
    /// header update would otherwise ask the file system about each folder above the shown one, once per crumb
    /// (`NSWorkspace.icon(forFile:)` reads the folder and can trip the privacy prompts of protected ones).
    static func menuIcon(_ folder: String, local: Bool, home: String?) -> NSImage {
        let image: NSImage
        if local, folder != "/", folder != home.map(FilesPath.normalized) {
            image = NSWorkspace.shared.icon(for: .folder)
        } else {
            let symbol = folder == "/" ? (local ? "internaldrive" : "externaldrive") : folder == home.map(FilesPath.normalized) ? "house" : "folder"
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        }
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: 16, height: 16)
        return sized
    }

    // MARK: Search, sort

    /// What the shown tab's search holds: the list's filter, the Review tab's or the log's.
    private var searchText: String {
        if session.tab == .files { return session.filter }
        return session.showsLog ? session.logFilter : session.changesFilter
    }

    /// The same place and the same behaviour on every tab: the glyph, or the field while it is open or holds text.
    @ViewBuilder private var searchSlot: some View {
        if searching || !searchText.isEmpty {
            if session.tab == .files {
                filterField($session.filter, prompt: "Filter", help: "Filter this folder’s list by name · ⌘F",
                            identifier: "files-filter")
                    .layoutPriority(1)
            } else if !session.showsLog {
                filterField($session.changesFilter, prompt: "Search changes", help: "Search the changed files · ⌘F",
                            identifier: "git-changes-filter")
                    .layoutPriority(1)
            } else {
                GitCommitsFilterField(session: session, focusOnAppear: searching, fold: { searching = false })
                    .layoutPriority(1)
            }
        } else {
            searchButton
        }
    }

    private func filterField(_ text: Binding<String>, prompt: String, help: String, identifier: String) -> some View {
        let palette = Chrome.palette
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(typography.symbol(.caption))
            TextField(prompt, text: text, prompt: Text(prompt).foregroundStyle(palette.detail))
                .textFieldStyle(.plain)
                .foregroundStyle(palette.ink)
                .focused($filterFocused)
                .onSubmit { session.focusRequest = System.uuid() }
                .onExitCommand {
                    text.wrappedValue = ""
                    searching = false
                    session.focusRequest = System.uuid()
                }
                .onKeyPress(.downArrow) {
                    session.focusRequest = System.uuid()
                    return .handled
                }
                .accessibilityIdentifier(identifier)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .help("Clear the search · esc")
                    .accessibilityIdentifier(identifier + "-clear")
            }
        }
        .foregroundStyle(palette.detail)
        .padding(.horizontal, 8)
        .frame(minWidth: typography.expanded(96), maxWidth: typography.expanded(170), minHeight: typography.expanded(22),
               maxHeight: typography.expanded(22))
        // On the glass pill the field is the pill's; flat, it is its own well.
        .background(RoundedRectangle(cornerRadius: 5).fill(glass ? .clear : palette.control))
        .overlay { if !glass { RoundedRectangle(cornerRadius: 5).strokeBorder(palette.controlBorder) } }
        .help(help)
    }

    private var searchButton: some View {
        Button(action: openSearch) {
            Image(systemName: "magnifyingglass")
                .font(typography.symbol(.body))
                .frame(minWidth: typography.expanded(22), minHeight: typography.expanded(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(FilesHeaderButtonStyle())
        .help(session.showsLog ? "Search messages and authors · ⌘F"
              : session.tab == .files ? "Filter by name · ⌘F" : "Filter the changed files by path · ⌘F")
        .accessibilityLabel(session.tab == .files ? "Filter" : "Search")
        .accessibilityIdentifier("files-search")
    }

    /// The field mounts in this turn and takes focus in the next, once it is in the window.
    private func openSearch() {
        searching = true
        DispatchQueue.main.async { filterFocused = true }
    }

    /// ⌥⌘P: Single view, one view at a time, or the list with its detail (the preview, the change's diff, the commit's
    /// detail) beside or under it. Arrows drawn in while one view shows (lit), drawn out while both do, on every tab.
    private var viewsToggle: some View {
        let single = session.splitNarrow
        let both = !single
        let pane = session.tab == .files ? "preview" : session.showsLog ? "details" : "diff"
        return Button {
            session.toggleViews()
        } label: {
            Image(systemName: single ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(typography.symbol(.body))
                .frame(minWidth: typography.expanded(22), minHeight: typography.expanded(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(FilesHeaderButtonStyle(on: single))
        .help("Single view · ⌥⌘P")
        .accessibilityLabel(both ? "Show one view" : "Show list and \(pane)")
        .accessibilityValue(single ? "on" : "off")
        .accessibilityIdentifier("files-views-toggle")
    }
}

/// One column with a detail in the list's place: back to the list ("‹" and the tab's name on a pill), as esc. It leads
/// the files header on Review and Commits, and the preview's own header on Files, which then stands for both.
struct FilesBackButton: View {
    let session: FilesSession
    @Environment(\.appTypography) private var typography

    var body: some View {
        let title = FilesHeader.title(session.tab)
        Button {
            session.goBack()
            session.focusRequest = System.uuid()
        } label: {
            Self.label(session.tab, typography: typography, back: true)
                .glassSegmentPill(true, fallback: Chrome.palette.selectedControl)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Back to \(title) · esc")
        .accessibilityLabel("Back to \(title)")
        .accessibilityIdentifier("files-split-back")
    }

    /// The mode's label: on the list its glyph and name; drilled (`back`), "‹" in the glyph's slot, on the pill. The
    /// slot is one width and the padding the same either way, so the label never changes width and what follows it
    /// never moves; nothing is reserved that isn't drawn. The pill shows only where the label is a button.
    @MainActor static func label(_ tab: FilesTab, typography: AppTypography, back: Bool) -> some View {
        HStack(spacing: 5) {
            Group {
                if back { Image(systemName: "chevron.left").font(typography.symbol(.caption, weight: .bold)) }
                else { Image(systemName: ModeSwitchState.glyph(tab)).font(typography.symbol(.caption)) }
            }
            .frame(width: typography.expanded(14))
            Text(verbatim: FilesHeader.title(tab)).foregroundStyle(Chrome.palette.ink)
        }
        .font(typography, .label, weight: .semibold)
        .foregroundStyle(Chrome.palette.accent)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(height: typography.expanded(22))
    }
}

/// The one-column Review's changes under the shown one's name, as the list groups them: each with its letter, name
/// and folder, the shown one checked; a click shows it.
private struct FilesChangeChooser: View {
    let changes: [GitChange]
    let selection: String?
    let choose: (String) -> Void
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(GitChangeArea.allCases, id: \.self) { area in
                    let inArea = changes.filter { $0.area == area }
                    if !inArea.isEmpty {
                        Text(GitChangesText.title(area))
                            .font(typography, .caption, weight: .semibold)
                            .foregroundStyle(palette.detail)
                            .padding(.leading, 30).padding(.top, 6).padding(.bottom, 2)
                        ForEach(inArea) { change in
                            Button { choose(change.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark").font(typography.symbol(.caption, weight: .semibold))
                                        .opacity(change.id == selection ? 1 : 0)
                                        .frame(width: 14)
                                    GitChangeBadge(kind: change.kind, side: 14, plain: true)
                                    Text(verbatim: change.name).foregroundStyle(palette.ink)
                                    Text(verbatim: GitChangesText.folder(change)).foregroundStyle(palette.detail)
                                        .truncationMode(.head)
                                    Spacer(minLength: 0)
                                }
                                .font(typography, .body)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .frame(height: typography.expanded(24))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("files-change-choice-\(change.id)")
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: typography.expanded(320))
        .frame(maxHeight: typography.expanded(360))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The header's small buttons (`.hb`): muted, lit with a faint wash while on or hovered.
struct FilesHeaderButtonStyle: ButtonStyle {
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        FilesHeaderButton(configuration: configuration, on: on)
    }

    private struct FilesHeaderButton: View {
        let configuration: Configuration
        let on: Bool
        @State private var hovering = false

        var body: some View {
            let palette = Chrome.palette
            // Capsules on a glass pill, as a strip's buttons; rounded squares on the flat bar.
            let fill = on || configuration.isPressed ? palette.ink.opacity(0.06) : hovering ? palette.hover : .clear
            configuration.label
                .foregroundStyle(on ? palette.ink : palette.muted)
                .background {
                    if LiquidGlassStore.shared.active { Capsule().fill(fill) } else { RoundedRectangle(cornerRadius: 4).fill(fill) }
                }
                .onHover { hovering = $0 }
        }
    }
}

/// The column names over the list (`.cols`); a click sorts by that column, again flips the order.
struct FilesColumnHeader: View {
    let session: FilesSession
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        // The outline hides the same columns at the same widths (`FilesColumns.shown`).
        GeometryReader { geometry in
            let shown = FilesColumns.shown(width: geometry.size.width, typography: typography)
            HStack(spacing: 0) {
                column("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
                if shown.modified {
                    column("Modified", .modified).frame(width: FilesColumns.modified(typography), alignment: .trailing)
                }
                if shown.size { column("Size", .size).frame(width: FilesColumns.size(typography), alignment: .trailing) }
            }
            .padding(.leading, FilesColumns.leading)
            .padding(.trailing, FilesColumns.trailing)
            .frame(maxHeight: .infinity)
        }
        // As tall as the preview's header beside it, its rule included.
        .frame(height: FilesColumns.headerHeight(typography) + 1)
        .font(typography, .caption)
        .foregroundStyle(palette.detail)
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-columns")
    }

    private func column(_ title: String, _ key: FilesSort) -> some View {
        // The default order (names A to Z) carries no arrow, as in the mockup.
        let marked = session.sort == key && (key != .name || session.sortDescending)
        return Button { session.chooseSort(key) } label: {
            HStack(spacing: 3) {
                Text(title)
                if marked {
                    Image(systemName: session.sortDescending ? "chevron.down" : "chevron.up")
                        .font(.system(size: typography.size(offset: -5), weight: .semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
    }
}
