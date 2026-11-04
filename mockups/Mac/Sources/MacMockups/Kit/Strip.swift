import SwiftUI

// A pane's tab strip (TabBar.swift, StripTab.swift, ChatModeSwitch.swift, LayoutPicker.swift). Glass, the app's default:
// a 31-point capsule track in a 43-point bar, the selected tab on its own pill with a semibold title, the new-tab circle
// and the mode · layout pill beside it. Flat (`--flat`): a 34-point bar, tabs marked by a 1-point underline.

struct TabItem: Identifiable {
    var id: String { title + (shortcut.map(String.init) ?? "") }
    var title: String
    var activity = Activity.quiet
    /// ⌘1…⌘9 (the legend shows on tabs at least 110 wide).
    var shortcut: Int?
    var selected = false
    var hovered = false
}

enum PaneMode { case terminal, chat, files }

enum PaneLayout {
    case single, columns, rows, grid
    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .rows: "rectangle.split.1x2"
        case .grid: "square.split.2x2"
        case .columns: "rectangle.split.2x1"
        }
    }
}

struct StripModel {
    var tabs: [TabItem]
    var mode = PaneMode.terminal
    /// Whether an agent ran in the selected tab: the terminal's mode button then shows the chat bubble.
    var agent = false
    /// The layout picker, shown on the top-right pane when there is more than one tab to lay out.
    var layout: PaneLayout? = .grid
    /// The pane's ⌘ number on a split strip (accent when focused).
    var paneBadge: Int?
    var focused = true
    var host: MockHost?
}

struct TabStrip: View {
    let model: StripModel
    private var p: SidebarPalette { Chrome.palette }
    private var t: AppTypography { Mock.typography }
    var body: some View {
        if Mock.glass { glass } else { flat }
    }

    // MARK: Glass

    private var glass: some View {
        let track = StripTab.glassTrackHeight(t)
        return HStack(spacing: 4) {
            HStack(spacing: 0) {
                badge
                ForEach(model.tabs) { tab in
                    TabCell(tab: tab, alone: model.tabs.count == 1, glass: true)
                        .background { if tab.selected && model.tabs.count > 1 { Capsule().fill(GlassTone.selected).padding(2) } }
                }
            }
            .frame(height: track)
            .background(Capsule().fill(model.host?.tint?.glassWash ?? .clear))
            .background(Capsule().fill(GlassTone.track))
            .overlay(Capsule().strokeBorder(GlassTone.trackEdge, lineWidth: 0.5))
            .shadow(color: GlassTone.shadow, radius: 2, y: 1)
            Image(systemName: "plus").font(.system(size: 13.5, weight: .medium))
                .frame(width: track, height: track)
                .background(Circle().fill(GlassTone.track)).overlay(Circle().strokeBorder(GlassTone.trackEdge, lineWidth: 0.5))
                .shadow(color: GlassTone.shadow, radius: 2, y: 1)
            HStack(spacing: 0) {
                modeButton
                if let layout = model.layout { layoutButton(layout) }
            }
            .frame(height: track)
            .background(Capsule().fill(GlassTone.track)).overlay(Capsule().strokeBorder(GlassTone.trackEdge, lineWidth: 0.5))
            .shadow(color: GlassTone.shadow, radius: 2, y: 1)
        }
        .foregroundStyle(p.ink)
        .padding(.horizontal, Chrome.stripInset)
        .frame(height: t.expanded(38))
        .frame(maxWidth: .infinity)
        .background(GlassTone.bar)
    }

    // MARK: Flat

    private var flat: some View {
        HStack(spacing: 0) {
            badge
            HStack(spacing: 0) {
                ForEach(model.tabs) { TabCell(tab: $0, alone: model.tabs.count == 1, glass: false) }
            }
            .frame(minWidth: 48, alignment: .leading)
            Image(systemName: "plus").font(.system(size: 13.5)).frame(width: 28, height: t.expanded(26))
            HStack(spacing: 6) {
                modeButton
                if let layout = model.layout { layoutButton(layout) }
            }
            .padding(.leading, 6)
        }
        .foregroundStyle(p.ink)
        .padding(.horizontal, Chrome.stripInset)
        .frame(height: t.expanded(30), alignment: .bottom)
        .frame(maxWidth: .infinity)
        .background(Chrome.window)
        .overlay(alignment: .top) {
            if let tint = model.host?.tint { Rectangle().fill(tint.edge).frame(height: 2) }
        }
        .overlay(alignment: .bottom) { if p.isDark { Rectangle().fill(Chrome.border).frame(height: 1) } }
    }

    // MARK: Pieces

    @ViewBuilder private var badge: some View {
        if let number = model.paneBadge {
            Text("⌘\(number)").font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(model.focused ? p.accent : p.muted)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(p.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 4))
                .padding(.trailing, 4).padding(.leading, Mock.glass ? 4 : 0)
        }
    }

    /// One glyph: the chat bubble or the folder (where a click goes from the terminal; what shows otherwise).
    private var modeButton: some View {
        let chat = model.mode == .chat || (model.mode == .terminal && model.agent)
        let lit = model.mode != .terminal
        return Image(systemName: chat ? "text.bubble" : "folder").font(.system(size: 13.5))
            .foregroundStyle(lit ? ChatColors.current.accent : p.muted)
            .padding(.horizontal, 7).frame(minHeight: t.expanded(22))
    }

    private func layoutButton(_ layout: PaneLayout) -> some View {
        Image(systemName: layout.symbol).font(.system(size: 13.5))
            .foregroundStyle(layout == .single ? p.muted : p.ink)
            .padding(.horizontal, 7).frame(minHeight: t.expanded(22))
    }
}

/// A tab: activity in its 24-point leading slot, the title centred, the ⌘ legend at its end.
struct TabCell: View {
    let tab: TabItem
    let alone: Bool
    let glass: Bool
    var width: CGFloat?
    private var p: SidebarPalette { Chrome.palette }
    var body: some View {
        let semibold = glass && tab.selected && !alone
        ZStack {
            Text(tab.title).lineLimit(1).truncationMode(.middle)
                .font(Font(AppFont.native(size: Mock.typography.tabSize, semibold: semibold)))
                .foregroundStyle(tab.selected ? p.ink : Chrome.muted)
                .padding(.horizontal, 28)
            HStack(spacing: 0) {
                Group {
                    if tab.hovered {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                            .frame(width: 17.92, height: 17.92)
                            .background(p.ink.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else {
                        tab.activity.glyph(frame: 10)
                    }
                }
                .frame(width: 24).padding(.leading, 2)
                Spacer(minLength: 0)
                if let shortcut = tab.shortcut {
                    Text("⌘\(shortcut)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.muted).padding(.trailing, 10)
                }
            }
        }
        .frame(minWidth: Mock.typography.expanded(120), maxWidth: .infinity)
        .frame(height: glass ? StripTab.glassTrackHeight(Mock.typography) : Mock.typography.expanded(30))
        .overlay(alignment: .bottom) {
            if !glass && tab.selected && !alone { Rectangle().fill(p.ink.opacity(0.7)).frame(height: 1) }
        }
    }
}

/// A pane: its strip over its content. In a split the focused pane has a faint accent edge (no badge showing).
struct Pane<Content: View>: View {
    let strip: StripModel
    var focusEdge = false
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: strip)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay { if focusEdge && strip.focused { Rectangle().strokeBorder(Chrome.accent.opacity(0.35), lineWidth: 1) } }
    }
}

/// Panes side by side (`.horizontal`) or stacked, on the split view's 1-point #212121 divider.
struct Split<First: View, Second: View>: View {
    var axis = Axis.horizontal
    /// The first pane's share.
    var fraction: CGFloat = 0.5
    @ViewBuilder let first: First
    @ViewBuilder let second: Second
    var body: some View {
        GeometryReader { geometry in
            let divider = Color(white: 0.13)
            if axis == .horizontal {
                HStack(spacing: 0) {
                    first.frame(width: (geometry.size.width - 1) * fraction)
                    divider.frame(width: 1)
                    second
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(height: (geometry.size.height - 1) * fraction)
                    divider.frame(height: 1)
                    second
                }
            }
        }
    }
}

/// Dispatch's main window: sidebar (nil: hidden), its 1-point divider, then the content (panes). `side:` takes any
/// sidebar view, for a proposal drawn with SidebarColumn.
struct DispatchWindow<Side: View, Content: View>: View {
    var width: CGFloat = 1180
    var height: CGFloat = 740
    let side: Side?
    @ViewBuilder let content: Content
    var body: some View {
        MacWindow(width: width, height: height) {
            HStack(spacing: 0) {
                if let side {
                    side
                    Rectangle().fill(Chrome.palette.sidebarDivider).frame(width: 1)
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Chrome.palette.terminal)
            }
        }
    }
}

extension DispatchWindow where Side == Sidebar {
    init(width: CGFloat = 1180, height: CGFloat = 740, sidebar: SidebarModel?, @ViewBuilder content: () -> Content) {
        self.init(width: width, height: height, side: sidebar.map { Sidebar(model: $0) }, content: content)
    }
}

extension DispatchWindow {
    init(width: CGFloat = 1180, height: CGFloat = 740, @ViewBuilder side: () -> Side, @ViewBuilder content: () -> Content) {
        self.init(width: width, height: height, side: side(), content: content)
    }
}
