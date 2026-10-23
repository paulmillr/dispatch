import SwiftUI

// The iPad window, after docs/ios.md and MobileSplit.swift: a 320-point sidebar column (the Spaces tree with the
// phone's bottom tab bar, a compact width) beside the tab in a detail column (a regular width). The tab's header
// carries the sidebar button where the stack has its back pill; the Terminal / Chat / Files capsule stays under the
// header, at most 400 points wide and centred. Inside Files, Files / Review / Commits is a segmented glass capsule at
// the leading edge of the context row (no bottom tab bar in the regular column); Review and Commits are a 360-point
// list beside a pane. A hardware keyboard is attached, so the terminal has no key capsule. Sheets are form sheets;
// the host stats are a popover from the host glyph.

enum PadDetail { case terminal, chat, files, review, commits }

/// The full-screen iPad: sidebar + hairline + detail.
struct PadSplitScreen: View {
    var barFilter = 2
    let detail: PadDetail
    var popover = false
    /// Review / Commits before a row is picked: the pane's empty state.
    var empty = false
    var body: some View {
        HStack(spacing: 0) {
            PadSidebarTabs(width: MobileSplitMock.sidebar, popover: popover, barFilter: barFilter)
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5).ignoresSafeArea()
            Group {
                switch detail {
                case .terminal: PadTerminalDetail()
                case .chat: PadChatDetail()
                case .files: PadFilesDetail()
                case .review: PadReviewDetail(empty: empty)
                case .commits: PadCommitsDetail(empty: empty)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.canvas)
        // The stats popover beside mba2's glyph, drawn here: a popover presented from inside the split stayed
        // clipped to its column in the simulator. The glyph sits 34 points in from the sidebar's trailing inset; the
        // arrow's tip is at the glyph's trailing edge, on its centre line.
        .overlay(alignment: .topLeading) {
            if popover {
                PopoverFrame(arrowY: Self.glyphRect.midY - Self.popoverTop) { HostPopover() }
                    .offset(x: Self.glyphRect.maxX + 13, y: Self.popoverTop)
            }
        }
    }

    /// mba2's glyph in the sidebar, in safe-area coordinates (under the status bar): the tree's 16-point inset plus
    /// the host row's 16; 52 points higher than with the large title now that "Spaces" sits inline on the bar's row.
    static let glyphRect = CGRect(x: MobileSplitMock.sidebar - 32 - 34, y: 127, width: 34, height: 34)
    static let popoverTop: CGFloat = 44
}

enum MobileSplitMock {
    static let sidebar: CGFloat = 320
    static let capsule: CGFloat = 400
    static let list: CGFloat = 360
    static let measure: CGFloat = 720
}

/// Split View at half width: the stack, as on the phone, beside another app (dimmed).
struct PadHalfWidth<Content: View>: View {
    var width: CGFloat = 507
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(width: width)
                .environment(\.horizontalSizeClass, .compact)
            Rectangle().fill(Color.black).frame(width: 10).ignoresSafeArea()
            Rectangle().fill(Color(uiColor: .systemGray5).opacity(0.35)).ignoresSafeArea()
                .overlay(Text("Another app").font(.title3).foregroundStyle(.tertiary))
        }
        .background(Color.black)
    }
}

/// The sidebar column: Spaces / Agents with New as the phone's bottom bar (the column is compact), the tree inside.
/// At 320 points the filter chips are glyph-only discs; at Split View widths they stay the phone's chips.
struct PadSidebarTabs: View {
    var width: CGFloat
    var popover = false
    var barFilter = 0
    var body: some View {
        TabView(selection: .constant(0)) {
            Tab("Spaces", systemImage: "square.on.square", value: 0) {
                SpacesRootScreen(selected: "app", popover: popover, compactFilters: width <= MobileSplitMock.sidebar, barFilter: barFilter)
            }
            .badge(2)
            Tab("Agents", systemImage: "text.bubble", value: 1) { Color.canvas }
            Tab("New", systemImage: "plus", value: 2, role: .search) { Color.canvas }
        }
        .frame(width: width)
        .environment(\.horizontalSizeClass, .compact)
    }
}

/// The sidebar button in the tab's header, with the needs-you count where the back pill had it.
struct SidebarPill: View {
    var count: Int? = 2
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sidebar.leading").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.dispatchPink)
            if let count {
                Text("\(count)").font(.subheadline.weight(.semibold)).foregroundStyle(Color.onAccent)
                    .frame(width: 26, height: 26).background(Color.dispatchPink, in: Circle())
            }
        }
        .padding(.leading, 13).padding(.trailing, count == nil ? 13 : 9)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// The detail column's bar: sidebar pill, title + subtitle, host disc.
struct PadTabHeader: ToolbarContent {
    var title = "Sidebar theme toggle"
    var subtitle: AnyView
    var trailing: AnyView = AnyView(HostDisc())
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                SidebarPill()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.leading, 4)
            }
            .fixedSize()
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) { trailing }.sharedBackgroundVisibility(.hidden)
    }
}

/// The capsule at a phone's width, centred in the column.
struct PadCapsule: View {
    var selected = 2
    var badge: Int? = nil
    var body: some View {
        SegmentCapsule(selected: selected, badge: badge)
            .frame(maxWidth: MobileSplitMock.capsule)
            .frame(maxWidth: .infinity)
    }
}

/// Files / Review / Commits as a segmented glass capsule (glyph + title, Review with the comment count), where the
/// phone has its bottom tab bar. Sits at the leading edge of the context row.
struct ModeSegments: View {
    let mode: FilesTabMode
    var reviewBadge: Int? = 3
    var body: some View {
        HStack(spacing: 2) {
            ForEach(FilesTabMode.allCases) { m in
                let on = m == mode
                HStack(spacing: 5) {
                    Image(systemName: m.symbol).font(.subheadline.weight(.medium))
                    Text(m.title).font(.subheadline.weight(on ? .semibold : .medium))
                    if m == .review, let reviewBadge {
                        Text("\(reviewBadge)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(height: 16).background(Color.stateUnread, in: Capsule())
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 12).frame(height: 30)
                .background { if on { Capsule().fill(Color.lens) } }
            }
        }
        .padding(2)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
    }
}

/// Create review as a pink pill at the trailing end of the context row, the comment count on it.
struct CreateReviewPill: View {
    var count = 3
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperplane.fill").font(.caption.weight(.semibold))
            Text("Create review").font(.subheadline.weight(.semibold))
            Text("\(count)").font(.caption2.weight(.bold))
                .padding(.horizontal, 5).frame(height: 16).background(Color.onAccent.opacity(0.25), in: Capsule())
        }
        .foregroundStyle(Color.onAccent)
        .lineLimit(1).fixedSize()
        .padding(.leading, 12).padding(.trailing, 10).frame(height: 34)
        .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
    }
}

/// A one-line banner under the context row, inside the pane, where the phone has its full-width accessory:
/// the host offline, or a sent review with Undo.
struct PaneBanner: View {
    enum Kind { case offline, undo }
    let kind: Kind
    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .offline:
                Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                Text("mba2 is offline · showing the last listing").foregroundStyle(.secondary)
                Spacer()
                Text("Retry").foregroundStyle(Color.dispatchPink)
            case .undo:
                Image(systemName: "paperplane.fill").foregroundStyle(Color.dispatchPink)
                Text("Review sent to claude · 3 comments cleared")
                Spacer()
                Text("Undo").foregroundStyle(Color.dispatchPink)
            }
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 14).frame(height: 36)
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A tab in Files mode in the detail column: the capsule, then the context row with the mode segments at its
/// leading edge, the mode's context after them and the round buttons at the trailing edge; an optional banner under
/// it. No system tab bar: the regular column has the room for the segments in the header.
struct PadFilesShell<Content: View, Context: View, Trailing: View>: View {
    let mode: FilesTabMode
    var banner: PaneBanner.Kind? = nil
    @ViewBuilder var context: Context
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .safeAreaBar(edge: .top, spacing: 0) {
                    VStack(spacing: 10) {
                        PadCapsule()
                        HStack(spacing: 10) {
                            ModeSegments(mode: mode)
                            context
                            Spacer(minLength: 0)
                            trailing
                        }
                        if let banner { PaneBanner(kind: banner) }
                    }
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { PadTabHeader(subtitle: AnyView(HostPath(path: "~/src/web"))) }
        }
    }
}

/// I1: the listing across the column.
struct PadFilesDetail: View {
    var body: some View {
        PadFilesShell(mode: .files) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Breadcrumb(crumbs: ["web", "src"])
            }
            .padding(.leading, 6)
        } trailing: {
            BarButton(symbol: "magnifyingglass"); BarButton(symbol: "ellipsis")
        } content: {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(MockFiles.src.enumerated()), id: \.element.id) { index, file in
                        FileRow(file: file, last: index == MockFiles.src.count - 1)
                    }
                    Text("9 items").font(.footnote).foregroundStyle(.tertiary).padding(.top, 14)
                }
            }
        }
    }
}

/// A pane's own header, where a pushed screen had its bar.
struct PaneHeader<Subtitle: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 8)
    }
}

/// The pane before a row is picked.
struct PaneEmpty: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The list + hairline + pane layout of Review and Commits.
struct ListPane<List: View, Pane: View>: View {
    @ViewBuilder var list: List
    @ViewBuilder var pane: Pane
    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: MobileSplitMock.list)
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5)
            pane.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// I2: the change list at 360 points, the diff with its glass comment card beside it; I2b before a change is picked.
struct PadReviewDetail: View {
    var empty = false
    var body: some View {
        PadFilesShell(mode: .review) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(MockGit.branch).font(.subheadline.weight(.semibold))
                Text("· 8 files").font(.subheadline).foregroundStyle(.secondary)
                Counts(add: MockGit.additions, del: MockGit.deletions, font: .system(.subheadline, design: .monospaced))
            }
            .lineLimit(1)
            .padding(.leading, 6)
        } trailing: {
            CreateReviewPill()
            BarButton(symbol: "magnifyingglass")
        } content: {
            ListPane {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach([MockChange.Area.staged, .unstaged, .untracked], id: \.rawValue) { area in
                            let rows = MockGit.changes.filter { $0.area == area }
                            SectionHeader(title: area.rawValue, count: rows.count)
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, change in
                                    ChangeRow(change: change, last: index == rows.count - 1, selected: !empty && change.name == "Sidebar.tsx")
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 12)
                        }
                        Color.clear.frame(height: 40)
                    }
                }
            } pane: {
                if empty {
                    PaneEmpty(symbol: "pencil.and.list.clipboard", text: "Select a change to see its diff")
                } else {
                    VStack(spacing: 0) {
                        PaneHeader(title: "Sidebar.tsx") {
                            HStack(spacing: 6) {
                                Text("src/components").font(.system(.caption, design: .monospaced))
                                Text("·")
                                Text("M").font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(Color.caution)
                                Counts(add: 14, del: 6, font: .system(.caption, design: .monospaced))
                            }
                        } trailing: {
                            Picker("Show", selection: .constant(0)) {
                                Text("Diff").tag(0); Text("Source").tag(1)
                            }
                            .pickerStyle(.segmented).frame(width: 140)
                            BarButton(symbol: "plus.bubble", tinted: true)
                            BarButton(symbol: "ellipsis")
                        }
                        GlassDiffScreen(mode: .comments).pane(bottomBar: false, cardWidth: 520)
                    }
                }
            }
        }
    }
}

/// I3: the log at 360 points, the commit beside it; I3b before a commit is picked.
struct PadCommitsDetail: View {
    var empty = false
    let commit = MockGit.commits[0]
    var body: some View {
        PadFilesShell(mode: .commits) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(MockGit.branch).font(.subheadline.weight(.semibold))
                Text("· 148 commits").font(.subheadline).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.leading, 6)
        } trailing: {
            BarButton(symbol: "magnifyingglass"); BarButton(symbol: "line.3.horizontal.decrease")
        } content: {
            ListPane {
                ScrollView { CommitGraphList(selected: empty ? nil : 1).padding(.top, 4) }
            } pane: {
                if empty {
                    PaneEmpty(symbol: "clock.arrow.circlepath", text: "Select a commit")
                } else {
                    VStack(spacing: 0) {
                        PaneHeader(title: commit.hash) {
                            Text("\(commit.age) ago · \(commit.author)")
                        } trailing: {
                            BarButton(symbol: "ellipsis")
                        }
                        CommitDetailBody(commit: commit)
                    }
                }
            }
        }
    }
}

/// I4: the thread keeps the Mac's measure in the wide column; the composer with it.
struct PadChatDetail: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    Spacer(minLength: 120)
                    Bubble(text: "Add a theme toggle to the sidebar and make the unread rows stand out.", user: true)
                    Bubble(text: "Added ThemeToggle in the sidebar footer and a useTheme hook that follows the system preference. Unread rows now carry an unread class on the item.", user: false)
                    Text("5 steps in 1m 26s · 4 files +61 −9")
                        .font(.footnote).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 22)
                    Bubble(text: "Put the class on the link, not the item.", user: true)
                    Bubble(text: "Moving it. I'll also drop the `end` prop since it breaks nested routes.", user: false)
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Color.stateWorking).frame(width: 8, height: 8).padding(.top, 6)
                        Text("Editing Sidebar.tsx · 48s").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.leading, 6)
                    Color.clear.frame(height: 8)
                }
                .frame(maxWidth: MobileSplitMock.measure)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            }
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: Circle())
                    HStack {
                        Text("Message").foregroundStyle(.tertiary)
                        Spacer()
                        Image(systemName: "mic").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).frame(height: 44)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
                .frame(maxWidth: MobileSplitMock.measure)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16).padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .safeAreaBar(edge: .top, spacing: 0) {
                PadCapsule(selected: 1, badge: 3).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { PadTabHeader(subtitle: AnyView(HostPath(path: "~/src/web"))) }
        }
    }
}

/// I7: the terminal fills the column under the capsule; a hardware keyboard is attached, so no key capsule.
struct PadTerminalDetail: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                ForEach(["~/src/web $ pnpm dev", "", "> web@1.4.0 dev /Users/alex/src/web", "> vite", "",
                         "  vite v6.1.0  ready in 412 ms", "", "  ➜  Local:   http://localhost:5173/",
                         "  ➜  Network: http://10.0.0.12:5173/", "  ➜  press h + enter to show help", "",
                         "  09:37:40 hmr update src/theme.ts", "  09:37:41 hmr update src/components/Sidebar.tsx",
                         "  09:38:02 hmr update src/components/ThemeToggle.tsx, src/styles/tokens.css", "▯"], id: \.self) { line in
                    Text(line).font(.system(size: 13, design: .monospaced)).foregroundStyle(line.hasPrefix("~") ? Color.added : .primary)
                        .frame(height: 20)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(Color.black)
            .safeAreaBar(edge: .top, spacing: 0) {
                PadCapsule(selected: 0, badge: 3).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { PadTabHeader(title: "dev", subtitle: AnyView(HostPath(path: "~/src/web · pnpm", mono: false))) }
        }
        // The terminal is black in both schemes; its chrome and text stay dark-scheme over it.
        .colorScheme(.dark)
    }
}

/// I5: the stats widget as a popover from the host glyph: the sheet's content at 360 points without the sheet's bar
/// or grabber; the Edit pencil in its header.
struct HostPopover: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "apple.logo").font(.system(size: 17)).foregroundStyle(hostTint)
                        .frame(width: 34, height: 34).background(hostTint.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text("mba2").font(.headline)
                        HStack(spacing: 5) {
                            Circle().fill(Color.stateConnected).frame(width: 6, height: 6)
                            Text("macOS 26.1 · 18 ms").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "pencil").font(.subheadline.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                        .frame(width: 34, height: 34)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .padding(.top, 2)
                StatStripCard()
                Card(title: "Top processes", trailing: "by CPU") {
                    VStack(spacing: 12) {
                        ProcessRow(name: "node", value: "50%", fraction: 1)
                        ProcessRow(name: "cargo", value: "41%", fraction: 0.82)
                        ProcessRow(name: "rust-analyzer", value: "32%", fraction: 0.64)
                    }
                }
                VStack(spacing: 0) {
                    row("Address", "alex@mba2.tail3f.ts.net")
                    Hairline()
                    row("Multiplexer", "herdr 0.9.5")
                    Hairline()
                    row("Helper", "Full features", chevron: true)
                }
                .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 10) {
                    Label("Edit", systemImage: "pencil").font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 44).glassEffect(.regular.interactive(), in: Capsule())
                    Text("Disconnect").font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 44).glassEffect(.regular.interactive(), in: Capsule())
                }
            }
            .padding(16)
        }
        .frame(width: 360, height: 628)
    }

    private func row(_ label: String, _ value: String, chevron: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.body)
            Spacer()
            Text(value).font(.body).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// A popover's frame: the material panel with a leading arrow at `arrowY` from its top.
struct PopoverFrame<Content: View>: View {
    var arrowY: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.chipBorder, lineWidth: 0.5))
            .overlay(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: arrowY))
                    p.addLine(to: CGPoint(x: 14, y: arrowY - 14))
                    p.addLine(to: CGPoint(x: 14, y: arrowY + 14))
                    p.closeSubpath()
                }
                .fill(Color.canvas)
                .overlay {
                    Path { p in
                        p.move(to: CGPoint(x: 14, y: arrowY - 14))
                        p.addLine(to: CGPoint(x: 0, y: arrowY))
                        p.addLine(to: CGPoint(x: 14, y: arrowY + 14))
                    }
                    .stroke(Color.chipBorder, lineWidth: 0.5)
                }
                .offset(x: -13)
            }
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
    }
}


// Bodies shared by the capsule layout and the strip layout.
struct PadReviewBody: View {
    var empty = false
    var body: some View {

            ListPane {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach([MockChange.Area.staged, .unstaged, .untracked], id: \.rawValue) { area in
                            let rows = MockGit.changes.filter { $0.area == area }
                            SectionHeader(title: area.rawValue, count: rows.count)
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, change in
                                    ChangeRow(change: change, last: index == rows.count - 1, selected: !empty && change.name == "Sidebar.tsx")
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 12)
                        }
                        Color.clear.frame(height: 40)
                    }
                }
            } pane: {
                if empty {
                    PaneEmpty(symbol: "pencil.and.list.clipboard", text: "Select a change to see its diff")
                } else {
                    VStack(spacing: 0) {
                        PaneHeader(title: "Sidebar.tsx") {
                            HStack(spacing: 6) {
                                Text("src/components").font(.system(.caption, design: .monospaced))
                                Text("·")
                                Text("M").font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(Color.caution)
                                Counts(add: 14, del: 6, font: .system(.caption, design: .monospaced))
                            }
                        } trailing: {
                            Picker("Show", selection: .constant(0)) {
                                Text("Diff").tag(0); Text("Source").tag(1)
                            }
                            .pickerStyle(.segmented).frame(width: 140)
                            BarButton(symbol: "plus.bubble", tinted: true)
                            BarButton(symbol: "ellipsis")
                        }
                        GlassDiffScreen(mode: .comments).pane(bottomBar: false, cardWidth: 520)
                    }
                }
            }
        
    }
}

struct PadCommitsBody: View {
    var empty = false
    let commit = MockGit.commits[0]
    var body: some View {

            ListPane {
                ScrollView { CommitGraphList(selected: empty ? nil : 1).padding(.top, 4) }
            } pane: {
                if empty {
                    PaneEmpty(symbol: "clock.arrow.circlepath", text: "Select a commit")
                } else {
                    VStack(spacing: 0) {
                        PaneHeader(title: commit.hash) {
                            Text("\(commit.age) ago · \(commit.author)")
                        } trailing: {
                            BarButton(symbol: "ellipsis")
                        }
                        CommitDetailBody(commit: commit)
                    }
                }
            }
        
    }
}

struct PadChatBody: View {
    var body: some View {
        ScrollView {
                VStack(spacing: 10) {
                    Spacer(minLength: 120)
                    Bubble(text: "Add a theme toggle to the sidebar and make the unread rows stand out.", user: true)
                    Bubble(text: "Added ThemeToggle in the sidebar footer and a useTheme hook that follows the system preference. Unread rows now carry an unread class on the item.", user: false)
                    Text("5 steps in 1m 26s · 4 files +61 −9")
                        .font(.footnote).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 22)
                    Bubble(text: "Put the class on the link, not the item.", user: true)
                    Bubble(text: "Moving it. I'll also drop the `end` prop since it breaks nested routes.", user: false)
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Color.stateWorking).frame(width: 8, height: 8).padding(.top, 6)
                        Text("Editing Sidebar.tsx · 48s").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.leading, 6)
                    Color.clear.frame(height: 8)
                }
                .frame(maxWidth: MobileSplitMock.measure)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            }
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: Circle())
                    HStack {
                        Text("Message").foregroundStyle(.tertiary)
                        Spacer()
                        Image(systemName: "mic").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).frame(height: 44)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
                .frame(maxWidth: MobileSplitMock.measure)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16).padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
    }
}

struct PadTerminalBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                Spacer()
                ForEach(["~/src/web $ pnpm dev", "", "> web@1.4.0 dev /Users/alex/src/web", "> vite", "",
                         "  vite v6.1.0  ready in 412 ms", "", "  ➜  Local:   http://localhost:5173/",
                         "  ➜  Network: http://10.0.0.12:5173/", "  ➜  press h + enter to show help", "",
                         "  09:37:40 hmr update src/theme.ts", "  09:37:41 hmr update src/components/Sidebar.tsx",
                         "  09:38:02 hmr update src/components/ThemeToggle.tsx, src/styles/tokens.css", "▯"], id: \.self) { line in
                    Text(line).font(.system(size: 13, design: .monospaced)).foregroundStyle(line.hasPrefix("~") ? Color.added : .primary)
                        .frame(height: 20)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(Color.black)
    }
}
