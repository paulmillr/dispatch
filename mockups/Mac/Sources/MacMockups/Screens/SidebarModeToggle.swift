import SwiftUI

/// A switch in the sidebar's header between spaces and tabs only ("Vertical tabs, no spaces", Preferences.tabsOnly),
/// which today lives in Settings. Four ways to draw it in the traffic lights' row, each in both modes: A a two-icon
/// segmented control before the tree toggle, B one icon lit in tabs mode, C the mode's name after the sidebar toggle,
/// clicked to flip, D the same name as a menu. E0 sets the four headers side by side at twice the size.
enum SidebarModeToggle {
    static let screens: [Screen] = [
        Screen("E0-mode-headers", group: "sidebar-mode", "The four headers, spaces and tabs, at 2×") {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(ModeHeader.Style.allCases, id: \.self) { style in
                    HStack(spacing: 28) {
                        Text(style.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Chrome.palette.muted)
                            .frame(width: 170, alignment: .leading)
                        zoomed(ModeHeader(style: style, tabs: false))
                        zoomed(ModeHeader(style: style, tabs: true))
                    }
                }
            }
        },
        Screen("E6-mode-icon-candidates", group: "sidebar-mode", "B's icon: ten candidates, off (Spaces) and lit (Tabs), at 2×") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(iconCandidates, id: \.symbol) { candidate in
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Chrome.palette.ink)
                            Text(candidate.symbol).font(.system(size: 11, design: .monospaced)).foregroundStyle(Chrome.palette.muted)
                        }
                        .frame(width: 230, alignment: .leading)
                        zoomed(ModeHeader(style: .icon, tabs: false, symbol: candidate.symbol))
                        zoomed(ModeHeader(style: .icon, tabs: true, symbol: candidate.symbol))
                    }
                }
            }
        },
        Screen("E1-mode-segmented", group: "sidebar-mode", "A: two-icon segmented control, Spaces then Tabs") { pair(.segmented) },
        Screen("E2-mode-icon", group: "sidebar-mode", "B: one icon, lit in tabs mode") { pair(.icon) },
        Screen("E3-mode-label", group: "sidebar-mode", "C: the mode's name, clicked to flip") { pair(.label) },
        Screen("E4-mode-menu", group: "sidebar-mode", "D: the mode's name as a menu, open") {
            HStack(alignment: .top, spacing: 28) {
                TreeHostIcon.labelled("Spaces, menu open") {
                    SidebarColumn(model: spaces) { ModeHeader(style: .menu, tabs: false) } list: { SpacesList() }
                }
                // Over the clipped sidebar, as a menu stands over the window: under the name's button.
                .overlay(alignment: .topLeading) {
                    MacMenu(items: [
                        MenuItem(title: "Spaces", checked: true),
                        MenuItem(title: "Tabs", highlighted: true),
                        nil,
                        MenuItem(title: "Group by Host"),
                    ], width: 170)
                    .padding(.leading, 112).padding(.top, 66)
                }
                TreeHostIcon.labelled("Tabs") {
                    SidebarColumn(model: tabs) { ModeHeader(style: .menu, tabs: true) } list: { TabsList() }
                }
            }
        },
        Screen("E5-mode-window", group: "sidebar-mode", "A in the window: tabs mode (no tab strip), then spaces mode") {
            VStack(spacing: 40) {
                DispatchWindow(height: 520) {
                    SidebarColumn(model: tabs) { ModeHeader(style: .segmented, tabs: true) } list: { TabsList() }
                } content: {
                    TerminalScreen(lines: Sample.gitStatus).padding(.top, Mock.typography.expanded(38))
                        .background(TerminalScheme.current.background)
                }
                DispatchWindow(height: 520) {
                    SidebarColumn(model: spaces) { ModeHeader(style: .segmented, tabs: false) } list: { SpacesList() }
                } content: {
                    Pane(strip: StripModel(tabs: [
                        TabItem(title: "app", shortcut: 1, selected: true),
                        TabItem(title: "Fix the invoice rounding", activity: .finished, shortcut: 2),
                        TabItem(title: "tests", shortcut: 3),
                    ])) { TerminalScreen(lines: Sample.gitStatus) }
                }
            }
        },
    ]

    /// B's candidates, each an SF Symbol: what it says about tabs mode.
    static let iconCandidates: [(symbol: String, title: String)] = [
        ("list.bullet", "1  List (drawn so far)"),
        ("list.dash", "2  Plain list"),
        ("sidebar.squares.leading", "3  Sidebar of items"),
        ("list.bullet.rectangle", "4  List in a panel"),
        ("rectangle.grid.1x2", "5  Stacked rows"),
        ("square.fill.text.grid.1x2", "6  Rows led by a mark"),
        ("text.justify.leading", "7  Lines"),
        ("rectangle.on.rectangle", "8  Tabs"),
        ("rectangle.stack.badge.minus", "9  Spaces, minus"),
        ("menucard", "10  Card of entries"),
    ]

    static let spaces = Sample.sidebar
    static let tabs = SidebarModel(spaces: [
        SpaceItem(name: "app", shortcut: 1, keys: "⌘", selected: true),
        SpaceItem(name: "Fix the invoice rounding", activity: .finished, shortcut: 2, keys: "⌘"),
        SpaceItem(name: "tests", shortcut: 3, keys: "⌘"),
        SpaceItem(name: "docs", shortcut: 4, keys: "⌘"),
        SpaceItem(name: "billing", host: Hosts.buildBox, branch: "fix/invoices", activity: .waiting, shortcut: 5, keys: "⌘"),
        SpaceItem(name: "e2e", host: Hosts.buildBox, activity: .working, shortcut: 6, keys: "⌘"),
        SpaceItem(name: "release", host: Hosts.studio, shortcut: 7, keys: "⌘"),
    ])

    /// The variant's two sidebars: spaces mode, then tabs mode.
    static func pair(_ style: ModeHeader.Style) -> some View {
        HStack(alignment: .top, spacing: 28) {
            TreeHostIcon.labelled("Spaces") {
                SidebarColumn(model: spaces) { ModeHeader(style: style, tabs: false) } list: { SpacesList() }
            }
            TreeHostIcon.labelled("Tabs") {
                SidebarColumn(model: tabs) { ModeHeader(style: style, tabs: true) } list: { TabsList() }
            }
        }
    }

    static func zoomed(_ header: ModeHeader) -> some View {
        header.frame(width: 264)
            .background(Mock.glass ? GlassTone.sidebar : Chrome.sidebar)
            .foregroundStyle(Chrome.palette.ink)
            .scaleEffect(2, anchor: .topLeading)
            .frame(width: 528, height: header.height * 2, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct SpacesList: View {
    var body: some View {
        VStack(spacing: 2) {
            ForEach(SidebarModeToggle.spaces.spaces) { SpaceRow(space: $0) }
            NewSpaceRow().padding(.top, 4)
        }
    }
}

private struct TabsList: View {
    var body: some View {
        VStack(spacing: 2) {
            ForEach(SidebarModeToggle.tabs.spaces) { SpaceRow(space: $0) }
            NewSpaceRow(title: "tab", shortcut: "⌘T").padding(.top, 4)
        }
    }
}

/// The header row (SidebarTopRow's layout) with the mode switch drawn one of four ways.
struct ModeHeader: View {
    enum Style: CaseIterable {
        case segmented, icon, label, menu
        var title: String {
            switch self {
            case .segmented: "A  Segmented icons"
            case .icon: "B  One icon"
            case .label: "C  Name, click to flip"
            case .menu: "D  Name as a menu"
            }
        }
    }
    let style: Style
    let tabs: Bool
    var tree = false
    /// B's icon.
    var symbol = "list.bullet"
    var height: CGFloat { Mock.glass ? Mock.typography.expanded(38) : Mock.typography.expanded(30) }

    private var p: SidebarPalette { Chrome.palette }
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(p.ink).frame(width: 22, height: 20)
            if style == .label || style == .menu { name.padding(.leading, 8) }
            Spacer(minLength: 6)
            // C and D give the name room: the tree and keyboard buttons 8 apart instead of 12.
            HStack(spacing: style == .icon ? 12 : 8) {
                if style == .segmented { segmented }
                if style == .icon {
                    Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tabs ? p.ink : p.detail)
                        .frame(width: 24, height: 24)
                        .background(tabs ? p.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
                }
                HostTreeGlyph().frame(width: 13.5, height: 13.5).foregroundStyle(tree ? p.ink : p.detail)
                    .frame(width: 24, height: 24)
                    .background(tree ? p.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
                Image(systemName: "keyboard").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(p.detail)
                    .frame(minWidth: 24, minHeight: 24)
            }
        }
        .padding(.leading, Mock.glass ? 89 : 82).padding(.trailing, Mock.glass ? 16 : 8)
        .frame(height: height)
    }

    /// Spaces (stacked rectangles) and Tabs (a list), the current one on a pill.
    private var segmented: some View {
        HStack(spacing: 0) {
            segment("rectangle.stack", on: !tabs)
            segment("list.bullet", on: tabs)
        }
        .padding(2)
        .background(p.ink.opacity(0.05), in: Capsule())
    }

    private func segment(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(on ? p.ink : p.detail)
            .frame(width: 26, height: 20)
            .background(on ? p.ink.opacity(0.12) : .clear, in: Capsule())
    }

    /// "Spaces" or "Tabs": with ⇄ (C, a click flips it) or ⌄ (D, a menu).
    private var name: some View {
        HStack(spacing: 3) {
            Text(tabs ? "Tabs" : "Spaces").font(.system(size: 12, weight: .semibold)).fixedSize()
            Image(systemName: style == .menu ? "chevron.down" : "arrow.left.arrow.right")
                .font(.system(size: style == .menu ? 8 : 9, weight: .semibold)).foregroundStyle(p.detail)
        }
        .foregroundStyle(p.secondary)
        .padding(.horizontal, 6).frame(height: 22)
        .background(p.ink.opacity(0.05), in: Capsule())
        .fixedSize()
    }
}
