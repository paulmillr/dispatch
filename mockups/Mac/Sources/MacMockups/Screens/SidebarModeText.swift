import SwiftUI

/// The sidebar's mode as text, on a line of its own under the traffic lights' row, starting where the sidebar's
/// content does (a host heading's name, 20 in): F1 the two words, the current one bright (a click on the other
/// switches); F2 the current word as a menu; F3 the two words on a segmented pill. F4 puts F1 in the window, grouped
/// by host and in tabs mode.
enum SidebarModeText {
    static let screens: [Screen] = [
        Screen("F1-mode-text-variants", group: "sidebar-mode-text", "Spaces / Tabs as text under the header: three ways, both modes") {
            HStack(alignment: .top, spacing: 24) {
                ForEach(ModeTextRow.Style.allCases, id: \.self) { style in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(style.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Chrome.palette.ink)
                        HStack(alignment: .top, spacing: 16) {
                            sidebar(style, tabs: false, height: 400)
                            sidebar(style, tabs: true, height: 400)
                        }
                    }
                }
            }
        },
        Screen("F4-mode-text-window", group: "sidebar-mode-text", "F1 in the window: grouped by host, then tabs mode") {
            VStack(spacing: 40) {
                DispatchWindow(height: 500) {
                    SidebarColumn(model: tree) { header(.words, tabs: false, tree: true) } list: { Sidebar.treeList(tree) }
                } content: {
                    Pane(strip: StripModel(tabs: [
                        TabItem(title: "app", shortcut: 1, selected: true),
                        TabItem(title: "Fix the invoice rounding", activity: .finished, shortcut: 2),
                        TabItem(title: "tests", shortcut: 3),
                    ])) { TerminalScreen(lines: Sample.gitStatus) }
                }
                DispatchWindow(height: 500) {
                    SidebarColumn(model: SidebarModeToggle.tabs) { header(.words, tabs: true) } list: { TabsRows() }
                } content: {
                    TerminalScreen(lines: Sample.gitStatus).padding(.top, Mock.typography.expanded(38))
                        .background(TerminalScheme.current.background)
                }
            }
        },
    ]

    static let tree = SidebarModel(spaces: Sample.sidebar.spaces, tree: true)

    static func header(_ style: ModeTextRow.Style, tabs: Bool, tree: Bool = false) -> some View {
        VStack(spacing: 0) {
            SidebarTopRow(tree: tree)
            ModeTextRow(style: style, tabs: tabs)
        }
    }

    static func sidebar(_ style: ModeTextRow.Style, tabs: Bool, height: CGFloat) -> some View {
        let model = tabs ? SidebarModeToggle.tabs : Sample.sidebar
        return SidebarColumn(model: model) { header(style, tabs: tabs) } list: {
            if tabs { TabsRows() } else { SpacesRows() }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Chrome.border, lineWidth: 1))
    }
}

private struct SpacesRows: View {
    var body: some View {
        VStack(spacing: 2) {
            ForEach(Sample.sidebar.spaces) { SpaceRow(space: $0) }
            NewSpaceRow().padding(.top, 4)
        }
    }
}

private struct TabsRows: View {
    var body: some View {
        VStack(spacing: 2) {
            ForEach(SidebarModeToggle.tabs.spaces) { SpaceRow(space: $0) }
            NewSpaceRow(title: "tab", shortcut: "⌘T").padding(.top, 4)
        }
    }
}

/// The mode line: 20 in, as tall as a host heading's text row (26), above the list.
struct ModeTextRow: View {
    enum Style: CaseIterable {
        case words, menu, pill
        var title: String {
            switch self {
            case .words: "F1  Both words, the current one bright"
            case .menu: "F2  The current word as a menu"
            case .pill: "F3  Both words on a pill"
            }
        }
    }
    let style: Style
    let tabs: Bool
    private var p: SidebarPalette { Chrome.palette }

    var body: some View {
        HStack(spacing: 0) {
            switch style {
            case .words:
                HStack(spacing: 14) {
                    word("Spaces", on: !tabs)
                    word("Tabs", on: tabs)
                }
            case .menu:
                HStack(spacing: 4) {
                    Text(tabs ? "Tabs" : "Spaces").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
                    Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(p.detail)
                }
            case .pill:
                HStack(spacing: 0) {
                    segment("Spaces", on: !tabs)
                    segment("Tabs", on: tabs)
                }
                .padding(2)
                .background(p.ink.opacity(0.05), in: Capsule())
                // The pill's words, not its edge, start at the content's edge.
                .padding(.leading, -10)
            }
            Spacer()
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .frame(height: 26)
        .padding(.bottom, 4)
    }

    private func word(_ title: String, on: Bool) -> some View {
        Text(title).font(.system(size: 13, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? p.ink : p.detail)
    }

    private func segment(_ title: String, on: Bool) -> some View {
        Text(title).font(.system(size: 12, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? p.ink : p.detail)
            .padding(.horizontal, 8).frame(height: 20)
            .background(on ? p.ink.opacity(0.12) : .clear, in: Capsule())
    }
}
