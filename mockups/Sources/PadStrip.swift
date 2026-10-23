import SwiftUI

// iPad, third pass: the Mac's layout. The sidebar is the Spaces tree alone (no bottom bar; New and Edit in its bar
// row). The detail column opens with the space's tab strip: one glass track of tab pills (state dot, agent or
// terminal glyph, title, ⌘n), "+" after them, and the mode switch at the trailing end: Terminal · Chat · Files ·
// Review · Commits as glyphs, the git two only inside a repository. No title header, no capsule.

enum PadMode: Int, CaseIterable, Identifiable {
    case terminal, chat, files, review, commits
    var id: Int { rawValue }
    var symbol: String {
        switch self {
        case .terminal: "apple.terminal"; case .chat: "text.bubble"; case .files: "folder"
        case .review: "pencil.and.list.clipboard"; case .commits: "clock.arrow.circlepath"
        }
    }
    var title: String {
        switch self { case .terminal: "Terminal"; case .chat: "Chat"; case .files: "Files"; case .review: "Review"; case .commits: "Commits" }
    }
}

/// The strip: the space's tabs as pills in one glass track, "+" and the mode switch after it.
struct PadStrip: View {
    var mode: PadMode = .files
    var selectedTab = 0
    var reviewBadge: Int? = 3
    /// The sidebar hidden: its toggle with the needs-you count leads the strip, then the space's name.
    var sidebarHidden = false
    var body: some View {
        HStack(spacing: 10) {
            if sidebarHidden {
                SidebarPill()
                HStack(spacing: 6) {
                    Image(systemName: "apple.logo").font(.caption).foregroundStyle(hostTint)
                    Text("app").font(.subheadline.weight(.semibold))
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.caption2.weight(.semibold))
                        Text("dark-mode").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12).frame(height: 38)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            HStack(spacing: 2) {
                ForEach(Array(MockSpaces.appTabs.prefix(4).enumerated()), id: \.element.id) { i, tab in
                    let on = i == selectedTab
                    HStack(spacing: 7) {
                        if let dot = tab.dot { Circle().fill(dot).frame(width: 7, height: 7) }
                        AgentGlyph(kind: tab.kind).scaleEffect(0.75).frame(width: 18)
                        Text(tab.name).font(.subheadline.weight(on ? .semibold : .medium)).lineLimit(1).truncationMode(.tail)
                        if on {
                            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary).padding(.leading, 2)
                        }
                    }
                    .padding(.horizontal, 12).frame(height: 32)
                    .frame(maxWidth: on ? 260 : 200)
                    .background { if on { Capsule().fill(Color.lens) } }
                }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
            .layoutPriority(1)
            Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 38, height: 38)
                .glassEffect(.regular.interactive(), in: Circle())
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(PadMode.allCases) { m in
                    let on = m == mode
                    Image(systemName: m.symbol).font(.system(size: 15, weight: .medium))
                        .foregroundStyle(on ? Color.dispatchPink : .primary)
                        .frame(width: 40, height: 32)
                        .background { if on { Capsule().fill(Color.lens) } }
                        .overlay(alignment: .topTrailing) {
                            if m == .review, let reviewBadge {
                                Text("\(reviewBadge)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).frame(height: 14).background(Color.stateUnread, in: Capsule())
                                    .offset(x: 2, y: -2)
                            }
                        }
                        .accessibilityLabel(m.title)
                }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
            .fixedSize()
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 4)
    }
}

/// The detail column under the strip: the mode's context row (Files, Review, Commits), an optional banner, the content.
struct PadStripShell<Content: View, Context: View, Trailing: View>: View {
    let mode: PadMode
    var selectedTab = 0
    var banner: PaneBanner.Kind? = nil
    var contextRow = true
    var sidebarHidden = false
    @ViewBuilder var context: Context
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 6) {
                    PadStrip(mode: mode, selectedTab: selectedTab, sidebarHidden: sidebarHidden)
                    if contextRow {
                        HStack(spacing: 10) {
                            context
                            Spacer(minLength: 0)
                            trailing
                        }
                        .padding(.horizontal, 16)
                    }
                    if let banner { PaneBanner(kind: banner).padding(.horizontal, 16) }
                }
                .padding(.bottom, 8)
            }
    }
}

/// The sidebar without the bottom bar: the tree alone; "Spaces", filter, New and Edit on the bar's row.
struct PadSidebar: View {
    var popover = false
    var body: some View {
        SpacesRootScreen(selected: "app", popover: popover, compactFilters: true, barFilter: 2, newInBar: true)
            .frame(width: MobileSplitMock.sidebar)
    }
}

/// The split with the strip: sidebar + detail.
struct PadStripScreen: View {
    let detail: PadDetail
    var popover = false
    var empty = false
    var sidebarHidden = false
    var body: some View {
        HStack(spacing: 0) {
            if !sidebarHidden {
                PadSidebar(popover: popover)
                Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5).ignoresSafeArea()
            }
            Group {
                switch detail {
                case .terminal: PadStripTerminal(sidebarHidden: sidebarHidden)
                case .chat: PadStripChat(sidebarHidden: sidebarHidden)
                case .files: PadStripFiles(sidebarHidden: sidebarHidden)
                case .review: PadStripReview(empty: empty)
                case .commits: PadStripCommits(empty: empty)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.canvas)
        .overlay(alignment: .topLeading) {
            if popover {
                PopoverFrame(arrowY: PadSplitScreen.glyphRect.midY - PadSplitScreen.popoverTop) { HostPopover() }
                    .offset(x: PadSplitScreen.glyphRect.maxX + 13, y: PadSplitScreen.popoverTop)
            }
        }
    }
}

struct PadStripFiles: View {
    var sidebarHidden = false
    var body: some View {
        PadStripShell(mode: .files, selectedTab: 1, sidebarHidden: sidebarHidden) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Breadcrumb(crumbs: ["web", "src"])
            }
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

struct PadStripReview: View {
    var empty = false
    var body: some View {
        PadStripShell(mode: .review, selectedTab: 1) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(MockGit.branch).font(.subheadline.weight(.semibold))
                Text("· 8 files").font(.subheadline).foregroundStyle(.secondary)
                Counts(add: MockGit.additions, del: MockGit.deletions, font: .system(.subheadline, design: .monospaced))
            }
            .lineLimit(1)
        } trailing: {
            CreateReviewPill()
            BarButton(symbol: "magnifyingglass")
        } content: {
            PadReviewBody(empty: empty)
        }
    }
}

struct PadStripCommits: View {
    var empty = false
    var body: some View {
        PadStripShell(mode: .commits, selectedTab: 1) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(MockGit.branch).font(.subheadline.weight(.semibold))
                Text("· 148 commits").font(.subheadline).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        } trailing: {
            BarButton(symbol: "magnifyingglass"); BarButton(symbol: "line.3.horizontal.decrease")
        } content: {
            PadCommitsBody(empty: empty)
        }
    }
}

struct PadStripChat: View {
    var sidebarHidden = false
    var body: some View {
        PadStripShell(mode: .chat, selectedTab: 0, contextRow: false, sidebarHidden: sidebarHidden) { EmptyView() } trailing: { EmptyView() } content: {
            PadChatBody()
        }
    }
}

struct PadStripTerminal: View {
    var sidebarHidden = false
    var body: some View {
        PadStripShell(mode: .terminal, selectedTab: 1, contextRow: false, sidebarHidden: sidebarHidden) { EmptyView() } trailing: { EmptyView() } content: {
            PadTerminalBody()
        }
        .colorScheme(.dark)
    }
}
