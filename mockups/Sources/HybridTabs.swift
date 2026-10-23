import SwiftUI

/// Variant D: Terminal / Chat / Files as the top capsule (glyph + title); inside Files, the system bottom tab bar
/// carries Files / Review / Commits with the badge and the accessory slot. Terminal and Chat keep their bottoms.
struct SegmentCapsule: View {
    let items: [(String, String)] = [("Terminal", "apple.terminal"), ("Chat", "text.bubble"), ("Files", "folder")]
    var selected = 2
    var badge: Int? = nil
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let on = i == selected
                HStack(spacing: 5) {
                    Image(systemName: item.1).font(.subheadline.weight(.medium))
                    Text(item.0).font(.subheadline.weight(on ? .semibold : .medium))
                    if i == 2, let badge {
                        Text("\(badge)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(height: 16).background(Color.stateUnread, in: Capsule())
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background { if on { Capsule().fill(Color.lens) } }
            }
        }
        .padding(2)
        .glassEffect(.regular, in: Capsule())
    }
}

enum FilesTabMode: Int, CaseIterable, Identifiable {
    case files, review, commits
    var id: Int { rawValue }
    var title: String { switch self { case .files: "Files"; case .review: "Review"; case .commits: "Commits" } }
    var symbol: String { switch self { case .files: "folder"; case .review: "pencil.and.list.clipboard"; case .commits: "clock.arrow.circlepath" } }
}

struct HybridShell<Content: View, Context: View, Trailing: View, Accessory: View>: View {
    let mode: FilesTabMode
    var hasAccessory = false
    @ViewBuilder var context: Context
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        if hasAccessory { tabs.tabViewBottomAccessory { accessory } } else { tabs }
    }

    private var tabs: some View {
        TabView(selection: .constant(mode)) {
            ForEach(FilesTabMode.allCases) { m in
                Tab(m.title, systemImage: m.symbol, value: m) {
                    NavigationStack {
                        Group { if m == mode { content } else { Color.canvas } }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.canvas)
                            .safeAreaBar(edge: .top, spacing: 0) {
                                VStack(spacing: 10) {
                                    SegmentCapsule()
                                    if m == mode {
                                        HStack(spacing: 10) { context; Spacer(minLength: 0); trailing }
                                    }
                                }
                                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
                            }
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { TabHeader(title: "Sidebar theme toggle", subtitle: AnyView(HostPath(path: "~/src/web"))) }
                    }
                }
                .badge(m == .review ? 3 : 0)
            }
        }
    }
}

struct HybridFilesScreen: View {
    var body: some View {
        HybridShell(mode: .files) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Breadcrumb(crumbs: ["web", "src"])
            }
        } trailing: {
            BarButton(symbol: "magnifyingglass"); BarButton(symbol: "ellipsis")
        } accessory: { EmptyView() } content: {
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

struct HybridReviewScreen: View {
    var body: some View {
        HybridShell(mode: .review, hasAccessory: true) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(MockGit.branch).font(.subheadline.weight(.semibold))
                Text("· 8 files").font(.subheadline).foregroundStyle(.secondary)
                Counts(add: MockGit.additions, del: MockGit.deletions, font: .system(.subheadline, design: .monospaced))
            }
            .lineLimit(1)
        } trailing: {
            BarButton(symbol: "magnifyingglass")
        } accessory: {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                Text("Create review").font(.body.weight(.semibold))
                Text("3 comments on 2 files").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.dispatchPink)
            .padding(.horizontal, 16)
        } content: {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach([MockChange.Area.staged, .unstaged, .untracked], id: \.rawValue) { area in
                        let rows = MockGit.changes.filter { $0.area == area }
                        SectionHeader(title: area.rawValue, count: rows.count)
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, change in
                                ChangeRow(change: change, last: index == rows.count - 1)
                            }
                        }
                        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 12)
                    }
                    Color.clear.frame(height: 40)
                }
            }
        }
    }
}

struct HybridCommitsScreen: View {
    var rows = MockLog.rows
    var palette = GraphPalette.status
    var body: some View {
        HybridShell(mode: .commits) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(MockGit.branch).font(.subheadline.weight(.semibold))
                Text("· 148 commits").font(.subheadline).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        } trailing: {
            BarButton(symbol: "magnifyingglass"); BarButton(symbol: "line.3.horizontal.decrease")
        } accessory: { EmptyView() } content: {
            ScrollView { CommitGraphList(rows: rows, palette: palette).padding(.top, 4) }
        }
    }
}

/// Terminal under the same top capsule: the key bar keeps the bottom, no tab bar.
struct HybridTerminalScreen: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                ForEach(["~/src/web $ pnpm dev", "", "  vite v6.1.0  ready in 412 ms", "  ➜  Local:   http://localhost:5173/",
                         "  ➜  Network: http://10.0.0.12:5173/", "", "  09:37:40 hmr update src/theme.ts",
                         "  09:37:41 hmr update src/components/Sidebar.tsx", "▯"], id: \.self) { line in
                    Text(line).font(.system(size: 13, design: .monospaced)).foregroundStyle(line.hasPrefix("~") ? Color.added : .primary)
                        .frame(height: 20)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(Color.black)
            .safeAreaBar(edge: .top, spacing: 0) {
                SegmentCapsule(selected: 0, badge: 3).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
            }
            .safeAreaBar(edge: .bottom) {
                HStack(spacing: 0) {
                    ForEach(["Ctrl", "Esc", "Tab", "Alt"], id: \.self) { k in
                        Text(k).font(.system(size: 17, design: .monospaced)).frame(maxWidth: .infinity)
                    }
                    Image(systemName: "dpad").font(.system(size: 20)).frame(maxWidth: .infinity)
                    Image(systemName: "keyboard").font(.system(size: 20)).frame(maxWidth: .infinity)
                }
                .frame(height: 50).padding(.horizontal, 8)
                .glassEffect(.regular, in: Capsule())
                .padding(.horizontal, 12).padding(.bottom, 4)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { TabHeader(title: "dev", subtitle: AnyView(HostPath(path: "~/src/web · pnpm", mono: false))) }
        }
    }
}
