import SwiftUI

/// The files tabs as a segmented control: a well with the shown tab raised, a segment's
/// count in a pill after its title.
struct FilesSegments<ID: Hashable>: View {
    struct Segment: Identifiable {
        let id: ID
        let title: String
        let symbol: String
        var count: Int?
        var enabled = true
        let help: String
        let accessibilityID: String
    }

    let segments: [Segment]
    @Binding var selection: ID
    /// Glyphs and counts without the titles, for a header too narrow for them (the help and labels keep the names).
    var compact = false
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        HStack(spacing: 1) {
            ForEach(segments) { segment in
                let on = segment.id == selection
                Button { selection = segment.id } label: {
                    HStack(spacing: 6) {
                        Image(systemName: segment.symbol).font(.system(size: typography.size(offset: -2)))
                        if !compact { Text(segment.title) }
                        if let count = segment.count {
                            Text("\(count)")
                                .font(AppFont.ui(size: typography.size(offset: -2.5)))
                                .foregroundStyle(on ? palette.sidebarHostLabel : palette.detail)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(palette.ink.opacity(0.06)))
                        }
                    }
                    .foregroundStyle(!segment.enabled ? palette.faint : on ? palette.ink : palette.muted)
                    .padding(.horizontal, compact ? 7 : 10)
                    .frame(height: typography.expanded(22))
                    .glassSegmentPill(on, fallback: palette.selectedControl)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!segment.enabled)
                .help(segment.help)
                // As drawn: "Changes 4".
                .accessibilityLabel(segment.count.map { "\(segment.title) \($0)" } ?? segment.title)
                .accessibilityIdentifier(segment.accessibilityID)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .glassSegmentTrack(fallback: palette.control)
        .font(AppFont.ui(size: typography.size(offset: -1)))
        .fixedSize()
    }
}

/// The 34 pt bar over the tab (F2a, F3a, F4a), laid out the same on every tab: the files tabs, then where you are (the
/// path as crumbs, a right click offering Finder's folder menu, and inside a repository its branch), then the tab's
/// own control (Files: follow the shell; Commits: which branches), the search and the pane's toggle, always last. Counts
/// and totals live in the footers. Changes and Commits show the path to the repository's top folder.
struct FilesHeader: View {
    @Bindable var session: FilesSession
    let root: String?
    @Environment(\.appTypography) private var typography
    @Environment(\.chatTheme) private var theme
    /// Room for the floating mode switch over the header's trailing end.
    @Environment(\.filesHeaderTrailingInset) private var trailingInset
    @FocusState private var filterFocused: Bool
    /// The search shows as its glyph until clicked or ⌘F, and folds back once it is empty and loses focus.
    @State private var searching = false
    private var glass: Bool { LiquidGlassStore.shared.active }

    var body: some View {
        let palette = Chrome.palette
        HStack(spacing: 12) {
            // Three named segments beside a tab's line overflow a narrow pane: there they drop their names, but only
            // once the line has given up what it can (the crumbs folded and the filter narrowed, the git lines' text
            // clipped); the higher priority is offered room first.
            let segments = Self.segments(for: session)
            let selection = Binding(get: { session.tab }, set: { session.select($0) })
            ViewThatFits(in: .horizontal) {
                FilesSegments(segments: segments, selection: selection)
                FilesSegments(segments: segments, selection: selection, compact: true)
            }
            .layoutPriority(2)
            // Where you are: the crumbs fold and clip before the branch shortens; neither pushes the controls out.
            let location = session.tab == .files ? root : session.git.repository?.root ?? root
            HStack(spacing: 10) {
                crumbs(location)
                branchChip.layoutPriority(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            if session.tab == .files, session.source?.readOnly == true { FilesReadOnlyTag() }
            // The tab's control, the search and the pane's toggle: one glass pill with Liquid Glass.
            HStack(spacing: glass ? 2 : 12) {
                switch session.tab {
                case .files: if root != nil { followToggle }
                case .changes: EmptyView()
                case .commits:
                    // Narrow views keep the menu as "All ▾" / "Branch ▾".
                    ViewThatFits(in: .horizontal) {
                        scopeMenu(short: false)
                        scopeMenu(short: true)
                    }
                    .padding(.horizontal, glass ? 8 : 0)
                }
                searchSlot
                paneToggle
            }
            .glassControlGroup()
            .layoutPriority(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12 + trailingInset)
        .frame(height: typography.expanded(34))
        .frame(maxWidth: .infinity)
        .font(AppFont.ui(size: typography.size(offset: -1)))
        .foregroundStyle(palette.muted)
        .background(Chrome.window)
        // Glass controls carry the bar themselves; the flat bar keeps its rule.
        .overlay(alignment: .bottom) { if !glass { palette.separator.frame(height: 1) } }
        .onChange(of: session.findRequest) { _, _ in
            // ⌘F goes to the preview's find while the preview has focus and shows text (that pane answers it); an
            // image, a folder or a notice has nothing to find, so the search takes it. On the git tabs it always does.
            if session.tab != .files || !session.previewFocused || session.preview?.findable != true { openSearch() }
        }
        .onChange(of: filterFocused) { _, focused in
            if !focused, searchText.isEmpty { searching = false }
        }
        .onChange(of: searchText) { _, text in
            if text.isEmpty, !filterFocused { searching = false }
        }
        .onChange(of: session.tab) { _, _ in searching = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-header")
    }

    /// The files tabs as the header shows them (F2a): Files alone outside a repository; inside one Files · Changes, with
    /// the count of changed files once the status is in (none for a clean tree) · Commits.
    static func segments(for session: FilesSession) -> [FilesSegments<FilesTab>.Segment] {
        let files = FilesSegments<FilesTab>.Segment(id: .files, title: "Files", symbol: "folder", help: "Files · ⌃⌘1",
                                                    accessibilityID: "files-segment-files")
        guard session.showsGitTabs else { return [files] }
        let count = session.changedCount.flatMap { $0 > 0 ? $0 : nil }
        return [files,
                .init(id: .changes, title: "Changes", symbol: "doc.badge.plus", count: count, help: "Changes · ⌃⌘2",
                      accessibilityID: "files-segment-changes"),
                .init(id: .commits, title: "Commits", symbol: "arrow.triangle.branch", help: "Commits · ⌃⌘3",
                      accessibilityID: "files-segment-commits")]
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
        .font(AppFont.ui(size: typography.size(offset: -0.5)))
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
                .font(.system(size: typography.size(offset: -1.5)))
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

    /// Inside a repository, its branch and how far it is from its upstream ("main ↑2"); a click opens Commits. The
    /// counts go first when room runs short.
    @ViewBuilder private var branchChip: some View {
        if session.git.repository != nil, let status = session.status {
            let palette = Chrome.palette
            Button { session.select(.commits) } label: {
                ViewThatFits(in: .horizontal) {
                    branchLabel(status, counts: true)
                    branchLabel(status, counts: false)
                }
                .padding(.horizontal, glass ? 9 : 7)
                .frame(height: typography.expanded(glass ? 24 : 20))
                .liquidGlass(in: Capsule(), fallback: palette.ink.opacity(0.06), interactive: true)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(Self.branchHelp(status))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.branchHelp(status))
            .accessibilityIdentifier("files-branch")
        }
    }

    private func branchLabel(_ status: GitStatus, counts: Bool) -> some View {
        let palette = Chrome.palette
        return HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: typography.size(offset: -2.5)))
            Text(verbatim: GitChangesText.branch(status)).foregroundStyle(palette.secondary)
            if counts, status.ahead > 0 { Text(verbatim: "↑\(status.ahead)").foregroundStyle(palette.green) }
            if counts, status.behind > 0 { Text(verbatim: "↓\(status.behind)").foregroundStyle(palette.warning) }
        }
        .font(AppFont.ui(size: typography.size(offset: -1)))
        .lineLimit(1)
        .fixedSize()
    }

    /// "main · 2 ahead of origin/main · Commits ⌃⌘3".
    static func branchHelp(_ status: GitStatus) -> String {
        var parts = [GitChangesText.branch(status)]
        if let upstream = status.upstream {
            let moves = [status.ahead > 0 ? "\(status.ahead) ahead" : nil, status.behind > 0 ? "\(status.behind) behind" : nil]
                .compactMap { $0 }
            parts.append(moves.isEmpty ? "up to date with \(upstream)" : moves.joined(separator: ", ") + " of \(upstream)")
        }
        parts.append("Commits ⌃⌘3")
        return parts.joined(separator: " · ")
    }

    /// Commits: this branch's history or every branch's.
    private func scopeMenu(short: Bool) -> some View {
        let title = session.logScope == .all ? (short ? "All" : "All branches") : (short ? "Branch" : "This branch")
        return Menu {
            Picker("Show", selection: Binding(get: { session.logScope }, set: { scope in
                guard scope != session.logScope else { return }
                session.logScope = scope
                // Another query starts again from one page.
                session.logWanted = GitLoader.page
            })) {
                Text("This branch").tag(GitLogScope.branch)
                Text("All branches").tag(GitLogScope.all)
            }
            .pickerStyle(.inline)
        } label: {
            // One text, so the menu keeps the chevron after the title and draws both in the bar's muted ink.
            (Text(verbatim: title + " ") + Text(Image(systemName: "chevron.down")).font(.system(size: typography.size(offset: -4),
                                                                                               weight: .semibold)))
                .font(AppFont.ui(size: typography.size(offset: -1)))
                .foregroundStyle(Chrome.palette.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show this branch’s history or all branches")
        .accessibilityIdentifier("git-log-scope")
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
    static func menuIcon(_ folder: String, local: Bool, home: String?) -> NSImage {
        let image: NSImage
        if local {
            image = NSWorkspace.shared.icon(forFile: folder)
        } else {
            let symbol = folder == "/" ? "externaldrive" : folder == home.map(FilesPath.normalized) ? "house" : "folder"
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        }
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: 16, height: 16)
        return sized
    }

    // MARK: Search, sort

    /// What the shown tab's search holds: the list's filter, the changed files' or the log's.
    private var searchText: String {
        switch session.tab {
        case .files: session.filter
        case .changes: session.changesFilter
        case .commits: session.logFilter
        }
    }

    /// The same place and the same behaviour on every tab: the glyph, or the field while it is open or holds text.
    @ViewBuilder private var searchSlot: some View {
        if searching || !searchText.isEmpty {
            switch session.tab {
            case .files:
                filterField($session.filter, prompt: "Search", help: "Search the list · ⌘F", identifier: "files-filter")
                    .layoutPriority(1)
            case .changes:
                filterField($session.changesFilter, prompt: "Search changes", help: "Search the changed files · ⌘F",
                            identifier: "git-changes-filter")
                    .layoutPriority(1)
            case .commits:
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
            Image(systemName: "magnifyingglass").font(.system(size: typography.size(offset: -2.5)))
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
                .font(.system(size: typography.size(offset: -1.5)))
                .frame(minWidth: typography.expanded(22), minHeight: typography.expanded(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(FilesHeaderButtonStyle())
        .help(session.tab == .commits ? "Search messages and authors · ⌘F" : "Search · ⌘F")
        .accessibilityLabel("Search")
        .accessibilityIdentifier("files-search")
    }

    /// The field mounts in this turn and takes focus in the next, once it is in the window.
    private func openSearch() {
        searching = true
        DispatchQueue.main.async { filterFocused = true }
    }

    /// ⌥⌘P: lit while the pane is on (the preview, the change's diff, the commit's detail). A view under 600 pt has no
    /// room for it, but the button still says whether it comes back when there is.
    private var paneToggle: some View {
        let showing = !session.previewOff
        let pane = switch session.tab {
        case .files: "preview"
        case .changes: "diff"
        case .commits: "details"
        }
        return Button {
            session.togglePreview()
        } label: {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: typography.size(offset: -1.5)))
                .frame(minWidth: typography.expanded(22), minHeight: typography.expanded(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(FilesHeaderButtonStyle(on: showing))
        .help(showing ? "Hide \(pane) · ⌥⌘P" : "Show \(pane) · ⌥⌘P")
        .accessibilityLabel(showing ? "Hide \(pane)" : "Show \(pane)")
        .accessibilityIdentifier("files-preview-toggle")
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
        HStack(spacing: 0) {
            column("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            column("Modified", .modified).frame(width: FilesColumns.modified(typography), alignment: .trailing)
            column("Size", .size).frame(width: FilesColumns.size(typography), alignment: .trailing)
        }
        .padding(.leading, FilesColumns.leading)
        .padding(.trailing, FilesColumns.trailing)
        .frame(height: typography.expanded(24))
        .font(AppFont.ui(size: typography.size(offset: -2)))
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
