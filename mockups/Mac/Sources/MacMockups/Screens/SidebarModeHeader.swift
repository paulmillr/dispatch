import SwiftUI

/// Spaces / Tabs in the traffic lights' row, after the sidebar toggle, as F3's pill: both words, the current one on a
/// capsule (a click on the other switches). Tight, the keyboard button goes first, then the pill becomes one icon,
/// "spaces, minus", lit in tabs mode (a click flips it). G1 draws the sidebar at its narrowest (224), its default (264) and wider, in both modes; G2 the
/// window in tabs mode.
enum SidebarModeHeader {
    static let widths: [CGFloat] = [224, 250, 264, 300]

    static let screens: [Screen] = [
        Screen("G1-mode-header-widths", group: "sidebar-mode-header", "Spaces / Tabs in the header row, by sidebar width") {
            VStack(alignment: .leading, spacing: 26) {
                ForEach([false, true], id: \.self) { tabs in
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(widths, id: \.self) { width in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(Int(width)) wide\(width == 264 ? " (default)" : width == 224 ? " (narrowest)" : "")")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Chrome.palette.muted)
                                sidebar(tabs: tabs, width: width)
                            }
                        }
                    }
                }
            }
        },
        Screen("G3-mode-menu-widths", group: "sidebar-mode-header", "F2's menu in the header row, by sidebar width") {
            VStack(alignment: .leading, spacing: 26) {
                ForEach([false, true], id: \.self) { tabs in
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(widths, id: \.self) { width in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(Int(width)) wide\(width == 264 ? " (default)" : width == 224 ? " (narrowest)" : "")")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Chrome.palette.muted)
                                sidebar(tabs: tabs, width: width, menu: true)
                            }
                        }
                    }
                }
            }
        },
        Screen("G4-mode-menu-window", group: "sidebar-mode-header", "F2 in the window: the menu open over spaces, then tabs mode") {
            VStack(spacing: 40) {
                DispatchWindow(height: 460) {
                    SidebarColumn(model: Sample.sidebar) { ModeWordsHeader(tabs: false, menu: true) } list: { Rows(tabs: false) }
                } content: {
                    Pane(strip: StripModel(tabs: [
                        TabItem(title: "app", shortcut: 1, selected: true),
                        TabItem(title: "Fix the invoice rounding", activity: .finished, shortcut: 2),
                    ])) { TerminalScreen(lines: Sample.gitStatus) }
                }
                .overlay(alignment: .topLeading) {
                    MacMenu(items: [MenuItem(title: "Spaces", checked: true), MenuItem(title: "Tabs", highlighted: true)], width: 150)
                        .padding(.leading, 120).padding(.top, 44)
                }
                DispatchWindow(height: 460) {
                    SidebarColumn(model: SidebarModeToggle.tabs) { ModeWordsHeader(tabs: true, menu: true) } list: { Rows(tabs: true) }
                } content: {
                    TerminalScreen(lines: Sample.gitStatus).padding(.top, Mock.typography.expanded(38))
                        .background(TerminalScheme.current.background)
                }
            }
        },
        Screen("G2-mode-header-window", group: "sidebar-mode-header", "In the window: tabs mode, then grouped by host") {
            VStack(spacing: 40) {
                DispatchWindow(height: 460) {
                    SidebarColumn(model: SidebarModeToggle.tabs) { ModeWordsHeader(tabs: true) } list: { Rows(tabs: true) }
                } content: {
                    TerminalScreen(lines: Sample.gitStatus).padding(.top, Mock.typography.expanded(38))
                        .background(TerminalScheme.current.background)
                }
                DispatchWindow(height: 460) {
                    SidebarColumn(model: SidebarModeText.tree) { ModeWordsHeader(tabs: false, tree: true) } list: { Sidebar.treeList(SidebarModeText.tree) }
                } content: {
                    Pane(strip: StripModel(tabs: [
                        TabItem(title: "app", shortcut: 1, selected: true),
                        TabItem(title: "Fix the invoice rounding", activity: .finished, shortcut: 2),
                    ])) { TerminalScreen(lines: Sample.gitStatus) }
                }
            }
        },
    ]

    static func sidebar(tabs: Bool, width: CGFloat, menu: Bool = false) -> some View {
        var model = tabs ? SidebarModeToggle.tabs : Sample.sidebar
        model.width = width
        return SidebarColumn(model: model) { ModeWordsHeader(tabs: tabs, menu: menu) } list: { Rows(tabs: tabs, count: 3) }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Chrome.border, lineWidth: 1))
    }
}

private struct Rows: View {
    let tabs: Bool
    var count = 20
    var body: some View {
        VStack(spacing: 2) {
            ForEach((tabs ? SidebarModeToggle.tabs : Sample.sidebar).spaces.prefix(count)) { SpaceRow(space: $0) }
            if count > 5 {
                if tabs { NewSpaceRow(title: "tab", shortcut: "⌘T").padding(.top, 4) } else { NewSpaceRow().padding(.top, 4) }
            }
        }
    }
}

/// SidebarTopRow with the mode after the sidebar toggle as F3's pill (both words, the current one on a capsule).
/// Where the row is tight the keyboard-shortcuts button goes first (Help › Keyboard Shortcuts, ⌘/, still opens the
/// sheet), then the pill gives way to the "spaces, minus" icon, lit in tabs mode, among the buttons at the row's end.
struct ModeWordsHeader: View {
    let tabs: Bool
    var tree = false
    /// F3's pill, or F2's menu: the current word and ⌄.
    var menu = false
    private var p: SidebarPalette { Chrome.palette }
    var body: some View {
        let glass = Mock.glass
        HStack(spacing: 0) {
            Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(p.ink).frame(width: 22, height: 20)
            ViewThatFits(in: .horizontal) {
                row(mode, keyboard: true)
                row(mode, keyboard: false)
                row(icon, keyboard: true, trailing: true)
            }
        }
        .padding(.leading, glass ? 89 : 82).padding(.trailing, glass ? 16 : 8)
        .frame(height: glass ? Mock.typography.expanded(38) : Mock.typography.expanded(30))
    }

    /// `trailing`: the mode joins the buttons at the row's end (the icon), instead of following the sidebar toggle.
    private func row(_ mode: some View, keyboard: Bool, trailing: Bool = false) -> some View {
        HStack(spacing: 0) {
            if !trailing { mode.padding(.leading, 8) }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                if trailing { mode }
                HostTreeGlyph().frame(width: 13.5, height: 13.5).foregroundStyle(tree ? p.ink : p.detail)
                    .frame(width: 24, height: 24)
                    .background(tree ? p.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
                if keyboard {
                    Image(systemName: "keyboard").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(p.detail)
                        .frame(minWidth: 24, minHeight: 24)
                }
            }
        }
    }

    @ViewBuilder private var mode: some View {
        if menu { menuLabel } else { pill }
    }

    /// F2: the current mode's name and ⌄, on a faint capsule; a click opens Spaces · Tabs.
    private var menuLabel: some View {
        HStack(spacing: 4) {
            // As wide as "Spaces" in both modes (the app's ReservedText), so switching never moves the row's buttons.
            ZStack(alignment: .leading) {
                Text("Spaces").hidden()
                Text(tabs ? "Tabs" : "Spaces")
            }
            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.ink)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(p.detail)
        }
        .padding(.horizontal, 7).frame(height: 22)
        .background(p.ink.opacity(0.05), in: Capsule())
        .fixedSize()
    }

    private var pill: some View {
        HStack(spacing: 0) {
            segment("Spaces", on: !tabs)
            segment("Tabs", on: tabs)
        }
        .padding(2)
        .background(p.ink.opacity(0.05), in: Capsule())
        .fixedSize()
    }

    private func segment(_ title: String, on: Bool) -> some View {
        Text(title).font(.system(size: 11.5, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? p.ink : p.detail)
            .padding(.horizontal, 6).frame(height: 20)
            .background(on ? p.ink.opacity(0.12) : .clear, in: Capsule())
    }

    private var icon: some View {
        Image(systemName: "rectangle.stack.badge.minus").font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(tabs ? p.ink : p.detail)
            .frame(width: 24, height: 24)
            .background(tabs ? p.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}
