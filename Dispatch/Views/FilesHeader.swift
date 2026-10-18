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
                    .background { if on { RoundedRectangle(cornerRadius: 4).fill(palette.selectedControl) } }
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
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.control))
        .font(AppFont.ui(size: typography.size(offset: -1)))
        .fixedSize()
    }
}

/// The 34 pt bar over the tab (F2a, F3a, F4a): the files tabs, then the shown tab's own line. On Files the root as
/// crumbs, whether it follows the shell, the filter, hidden files, the sort and the preview's toggle; on Changes the
/// branch, the counts and the totals (`GitChangesHeaderLine`); on Commits the branch, the loaded log and its filter
/// (`GitCommitsHeaderLine`). One row for every tab, so switching tabs never moves the body.
struct FilesHeader: View {
    @Bindable var session: FilesSession
    let root: String?
    let settingHidden: Bool
    @Environment(\.appTypography) private var typography
    @Environment(\.chatTheme) private var theme
    /// Room for the floating mode switch over the header's trailing end.
    @Environment(\.filesHeaderTrailingInset) private var trailingInset
    @FocusState private var filterFocused: Bool

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
            switch session.tab {
            case .files:
                // Narrow views fold the crumbs, then clip them, then narrow the filter: the buttons at the trailing end
                // never push past the header or under the floating switch.
                crumbs
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                if session.source?.readOnly == true { FilesReadOnlyTag() }
                filterField
                    .layoutPriority(1)
                hiddenToggle
                sortMenu
                previewToggle
            case .changes:
                // The totals keep their width at the trailing end; the branch, counts and path clip before them. No
                // outer frame: its minimum would hide the line's (the totals, the filter) from the row, which then
                // gives the segments room the line needs.
                GitChangesHeaderLine(session: session)
            case .commits:
                // The filter sits at the trailing end, where the Files tab has its own.
                GitCommitsHeaderLine(session: session)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12 + trailingInset)
        .frame(height: typography.expanded(34))
        .frame(maxWidth: .infinity)
        .font(AppFont.ui(size: typography.size(offset: -1)))
        .foregroundStyle(palette.muted)
        .background(Chrome.window)
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
        .onChange(of: session.findRequest) { _, _ in
            // ⌘F goes to the preview's find while the preview has focus and shows text (that pane answers it); an
            // image, a folder or a notice has nothing to find, so the filter takes it. The git tabs answer their own.
            guard session.tab == .files else { return }
            if !session.previewFocused || session.preview?.findable != true { filterFocused = true }
        }
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

    private var crumbs: some View {
        let all = root.map { session.crumbs(root: $0) } ?? []
        // Long paths keep their first crumb and as many of the last as fit; the middle folds into "…".
        return ViewThatFits(in: .horizontal) {
            crumbRow(all, keepingLast: nil)
            ForEach([4, 3, 2, 1], id: \.self) { last in
                if all.count > last + 1 { crumbRow(all, keepingLast: last) }
            }
            crumbRow(all, keepingLast: 0)
        }
    }

    private func crumbRow(_ all: [FilesCrumb], keepingLast last: Int?) -> some View {
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
                    .accessibilityIdentifier("files-crumb-\(index)")
                } else {
                    Text("…").foregroundStyle(palette.sidebarDetail)
                }
            }
            if root != nil { follow.padding(.leading, 4) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(root.map { FilesPath.crumbLine(root: $0, home: session.home, host: session.hostLabel) } ?? "")
        .accessibilityIdentifier("files-crumbs")
        .font(AppFont.ui(size: typography.size(offset: -0.5)))
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder private var follow: some View {
        let palette = Chrome.palette
        if session.followsShell {
            HStack(spacing: 5) {
                Image(systemName: "link").font(.system(size: typography.size(offset: -3)))
                Text("follows shell")
            }
            .font(AppFont.ui(size: typography.size(offset: -2)))
            .foregroundStyle(palette.detail)
            .help("The view follows the shell’s cd. Navigating away pins it; ↩ returns")
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("files-follows-shell")
        } else {
            Button { session.followShell() } label: {
                Text("↩").padding(.horizontal, 5).frame(minWidth: typography.expanded(22), minHeight: typography.expanded(22))
                    .contentShape(Rectangle())
            }
            .buttonStyle(FilesHeaderButtonStyle())
            .help("Follow the shell’s directory again")
            .accessibilityLabel("Follow the shell’s directory")
            .accessibilityIdentifier("files-unpin")
        }
    }

    // MARK: Filter, hidden files, sort

    private var filterField: some View {
        let palette = Chrome.palette
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: typography.size(offset: -2.5)))
            TextField("Filter", text: $session.filter, prompt: Text("Filter").foregroundStyle(palette.detail))
                .textFieldStyle(.plain)
                .foregroundStyle(palette.ink)
                .focused($filterFocused)
                .onSubmit { session.focusRequest = System.uuid() }
                .onExitCommand {
                    session.filter = ""
                    session.focusRequest = System.uuid()
                }
                .onKeyPress(.downArrow) {
                    session.focusRequest = System.uuid()
                    return .handled
                }
                .accessibilityIdentifier("files-filter")
            if !session.filter.isEmpty {
                Button { session.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .help("Clear the filter · esc")
                    .accessibilityIdentifier("files-filter-clear")
            } else if !filterFocused {
                Text("⌘F").font(AppFont.shortcut(size: typography.size(offset: -2))).foregroundStyle(palette.detail)
            }
        }
        .foregroundStyle(palette.detail)
        .padding(.horizontal, 8)
        .frame(minWidth: typography.expanded(96), maxWidth: typography.expanded(170), minHeight: typography.expanded(22),
               maxHeight: typography.expanded(22))
        .background(RoundedRectangle(cornerRadius: 5).fill(palette.control))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(palette.controlBorder))
        .help("Filter the list · ⌘F")
    }

    private var hiddenToggle: some View {
        let showing = session.showsHidden(default: settingHidden)
        return Button {
            session.toggleHidden(settingHidden: settingHidden)
        } label: {
            Image(systemName: showing ? "eye" : "eye.slash")
                .font(.system(size: typography.size(offset: -1.5)))
                .frame(minWidth: typography.expanded(22), minHeight: typography.expanded(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(FilesHeaderButtonStyle(on: showing))
        .help(showing ? "Hide hidden files · ⇧⌘." : "Show hidden files · ⇧⌘.")
        .accessibilityLabel(showing ? "Hide hidden files" : "Show hidden files")
        .accessibilityIdentifier("files-hidden-toggle")
    }

    /// ⌥⌘P: lit while the preview is on. A view under 600 pt has no room for the pane, but the button still says
    /// whether it comes back when there is.
    private var previewToggle: some View {
        let showing = !session.previewHidden
        return Button {
            session.togglePreview()
        } label: {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: typography.size(offset: -1.5)))
                .frame(minWidth: typography.expanded(22), minHeight: typography.expanded(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(FilesHeaderButtonStyle(on: showing))
        .help(showing ? "Hide preview · ⌥⌘P" : "Show preview · ⌥⌘P")
        .accessibilityLabel(showing ? "Hide preview" : "Show preview")
        .accessibilityIdentifier("files-preview-toggle")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: Binding(get: { session.sort }, set: { key in
                if key != session.sort { session.chooseSort(key) }
            })) {
                ForEach(FilesSort.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: $session.sortDescending) {
                Text(Self.order(session.sort, descending: false)).tag(false)
                Text(Self.order(session.sort, descending: true)).tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Text(Self.title(session.sort))
                Image(systemName: session.sortDescending ? "chevron.down" : "chevron.up")
                    .font(.system(size: typography.size(offset: -4), weight: .semibold))
            }
            .font(AppFont.ui(size: typography.size(offset: -1.5)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: name, modified, size")
        .accessibilityIdentifier("files-sort")
    }

    static func title(_ sort: FilesSort) -> String {
        switch sort {
        case .name: "Name"
        case .modified: "Modified"
        case .size: "Size"
        }
    }

    static func order(_ sort: FilesSort, descending: Bool) -> String {
        switch sort {
        case .name: descending ? "Z to A" : "A to Z"
        case .modified: descending ? "Newest first" : "Oldest first"
        case .size: descending ? "Largest first" : "Smallest first"
        }
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
            configuration.label
                .foregroundStyle(on ? palette.ink : palette.muted)
                .background(RoundedRectangle(cornerRadius: 4).fill(
                    on || configuration.isPressed ? palette.ink.opacity(0.06) : hovering ? palette.hover : .clear))
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
