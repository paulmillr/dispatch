import SwiftUI

// A pane's tab strip (TabBar.swift, StripTab.swift, ChatModeSwitch.swift, LayoutPicker.swift). Glass, the app's default:
// a lone strip's tabs on a 31-point capsule track in a 43-point bar, the selected tab on its own pill with a semibold
// title, the new-tab circle and the mode · layout pill beside it; a split pane's strip one capsule holding its badge,
// tabs and buttons, in a bar of (38 + 28) / 2. Flat (`--flat`): a 34-point bar, tabs marked by a 1-point underline.

struct TabItem: Identifiable {
    var id: String { title + (shortcut.map(String.init) ?? "") }
    var title: String
    var activity = Activity.quiet
    /// ⌘1…⌘9 (the legend shows on tabs at least 110 wide). With splits the numbers focus panes, and tabs show none
    /// (only the focused pane's neighbours of its selection show ⌘] and ⌘[: Space.tabShortcut).
    var shortcut: Int?
    var selected = false
    var hovered = false
}

enum PaneMode { case terminal, chat, files }

/// The space's layout, as the layout picker shows it: `single` is one pane (the picker then offers the grid, muted).
enum PaneLayout {
    case single, columns, rows, grid
    var symbol: String {
        switch self {
        case .single, .grid: "square.split.2x2"
        case .rows: "rectangle.split.1x2"
        case .columns: "rectangle.split.2x1"
        }
    }
}

struct StripModel {
    var tabs: [TabItem]
    var mode = PaneMode.terminal
    /// Whether an agent ran in the selected tab: the terminal's mode button then shows the chat bubble.
    var agent = false
    /// The layout picker, on the top-right pane only (nil elsewhere).
    var layout: PaneLayout? = .single
    /// The pane's ⌘ number on a split strip (accent when focused); hidden in a strip narrower than 260.
    var paneBadge: Int?
    /// The space has more than one pane: on glass the strip is one capsule. Defaults to having a badge.
    var split: Bool?
    var focused = true
    var host: MockHost?
    /// The strip leads the window with the sidebar hidden (TitlebarPlacement.leading): it starts after the traffic
    /// lights (`Mock.controlsInset`). Its host mark replaces the sidebar toggle when there are other spaces to switch to
    /// or the tab is remote (TabBarPlacement.markReplacesSidebarToggle); otherwise the toggle leads.
    var titleRow = false
    /// Other spaces to switch to (Workspace.lastingSpaceCount > 1): a local strip leading the window shows its mark.
    var otherSpaces = false

    var isSplit: Bool { split ?? (paneBadge != nil) }
    /// The host mark (TabBar.mark): only where the strip leads the window here.
    var mark: MockHost? { titleRow ? (host ?? (otherSpaces ? Hosts.local : nil)) : nil }
}

struct TabStrip: View {
    let model: StripModel
    private var p: SidebarPalette { Chrome.palette }
    private var t: AppTypography { Mock.typography }
    /// Tabs take the host colour on glass (RemoteTabHighlight.fade); flat keeps the pane's top edge.
    private var tint: HostTint? { Mock.glass ? model.host?.tint : nil }
    var body: some View {
        if Mock.glass { glass } else { flat }
    }

    // MARK: Glass

    private var glass: some View {
        let track = StripTab.glassTrackHeight(t)
        let capsule = model.isSplit
        // A window's title row with a lone strip of one tab: just the title, without the track (TabBar.bareTitle).
        let bare = !capsule && model.titleRow && model.tabs.count == 1
        let bar = capsule ? (t.expanded(38) + track) / 2 : t.expanded(38)
        return HStack(spacing: 0) {
            leading
            if capsule {
                HStack(spacing: 0) {
                    if let mark = model.mark { markView(mark) }
                    badge(glass: true)
                    tabs(glass: true)
                    plus.frame(width: track, height: track)
                    modeButton
                    if let layout = model.layout { layoutButton(layout) }
                }
                .frame(height: track)
                .background(Capsule().fill(tint?.glassWash ?? .clear))
                .background(Capsule().fill(GlassTone.track))
                .overlay(Capsule().strokeBorder(GlassTone.trackEdge, lineWidth: 0.5))
                .shadow(color: GlassTone.shadow, radius: 2, y: 1)
            } else {
                if let mark = model.mark { markView(mark) }
                tabs(glass: true)
                    .frame(height: track)
                    .background { if !bare { glassShape(Capsule()) } }
                // Its own glass circle, as tall as the track and 4 points after it.
                plus.frame(width: track, height: track).background(glassShape(Circle())).padding(.leading, 4)
                // The mode switch and layout share a pill after it.
                HStack(spacing: 0) {
                    modeButton
                    if let layout = model.layout { layoutButton(layout) }
                }
                .frame(height: track)
                .background(glassShape(Capsule()))
                .padding(.leading, 4)
            }
        }
        .foregroundStyle(tint?.tabControl ?? p.ink)
        .padding(.trailing, Chrome.stripInset)
        .frame(height: bar, alignment: .bottom)
        .frame(maxWidth: .infinity)
        .background(GlassTone.bar)
    }

    private func glassShape<S: Shape>(_ shape: S) -> some View {
        shape.fill(tint?.glassWash ?? .clear)
            .background(shape.fill(GlassTone.track))
            .overlay(shape.stroke(GlassTone.trackEdge, lineWidth: 0.5))
            .shadow(color: GlassTone.shadow, radius: 2, y: 1)
    }

    // MARK: Flat

    private var flat: some View {
        HStack(spacing: 0) {
            leading
            if let mark = model.mark { markView(mark) }
            badge(glass: false)
            tabs(glass: false).frame(minWidth: 48, alignment: .leading)
            plus.frame(width: 28, height: t.expanded(26))
            HStack(spacing: 6) {
                modeButton
                if let layout = model.layout { layoutButton(layout) }
            }
            .padding(.leading, 6)
        }
        .foregroundStyle(p.ink)
        .padding(.trailing, Chrome.stripInset)
        .frame(height: t.expanded(30), alignment: .bottom)
        .frame(maxWidth: .infinity)
        .background(Chrome.window)
        .overlay(alignment: .top) {
            if let tint = model.host?.tint { Rectangle().fill(tint.edge).frame(height: 2) }
        }
        .overlay(alignment: .bottom) { if p.isDark { Rectangle().fill(Chrome.border).frame(height: 1) } }
    }

    // MARK: Pieces

    /// The traffic lights' inset and, with no mark to stand in for it, the sidebar toggle (TitleRowLeading); otherwise
    /// the strip inset.
    @ViewBuilder private var leading: some View {
        if model.titleRow {
            Color.clear.frame(width: Mock.controlsInset)
            if model.mark == nil {
                Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(Chrome.muted)
                    .frame(width: 22, height: 20).padding(.trailing, 14)
            }
        } else {
            Color.clear.frame(width: Chrome.stripInset)
        }
    }

    /// StripHostMark: the host's glyph, its colour or muted for local, on a glass circle as tall as the track (on a split
    /// capsule, no circle of its own); flat, no circle until hovered.
    private func markView(_ host: MockHost) -> some View {
        let side = Mock.glass ? StripTab.glassTrackHeight(t) : t.expanded(26)
        return MockHostGlyph(system: host.system, size: t.hostIconSize)
            .foregroundStyle(host.tint?.foreground ?? Chrome.muted)
            .frame(width: side, height: side)
            .background { if Mock.glass && !model.isSplit { glassShape(Circle()) } }
            .padding(.trailing, 4)
    }

    private var plus: some View {
        Image(systemName: "plus").font(t.font(.label))
    }

    /// PaneShortcutBadge: none in the title row; on glass the key alone on the capsule, flat on a faint box.
    @ViewBuilder private func badge(glass: Bool) -> some View {
        if let number = model.paneBadge, !model.titleRow {
            let key = Text("⌘\(number)").font(t.shortcut(offset: -2)).foregroundStyle(model.focused ? p.accent : p.muted)
            if glass {
                key.padding(.horizontal, 7)
                    .frame(minWidth: StripTab.glassTrackHeight(t), minHeight: StripTab.glassTrackHeight(t))
                    .padding(.trailing, 2)
            } else {
                key.padding(.horizontal, 7).padding(.vertical, 3)
                    .background(p.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.trailing, 2)
            }
        }
    }

    private func tabs(glass: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                let next = index + 1 < model.tabs.count ? model.tabs[index + 1] : nil
                TabCell(tab: tab, alone: model.tabs.count == 1, glass: glass, tint: model.host?.tint,
                        divider: next != nil && !tab.selected && next?.selected == false)
                    .background { if glass && tab.selected && model.tabs.count > 1 { Capsule().fill(GlassTone.selected).padding(2) } }
            }
        }
    }

    /// ChatModeSwitch: one glyph, the chat bubble or the folder (where a click goes from the terminal; what shows
    /// otherwise), in the chat theme's accent when lit and its muted otherwise.
    private var modeButton: some View {
        let chat = model.mode == .chat || (model.mode == .terminal && model.agent)
        let lit = model.mode != .terminal
        return Image(systemName: chat ? "text.bubble" : "folder").font(.system(size: 13.5))
            .foregroundStyle(lit ? ChatColors.current.accent : ChatColors.current.muted)
            .padding(.horizontal, 7).frame(minHeight: t.expanded(22))
    }

    /// LayoutPicker: with one pane the grid, muted; with more the layout, in the chat theme's accent.
    private func layoutButton(_ layout: PaneLayout) -> some View {
        Image(systemName: layout.symbol).font(.system(size: t.tabSize))
            .foregroundStyle(layout == .single ? Chrome.muted : ChatColors.current.accent)
            .padding(.horizontal, 7).frame(minHeight: t.expanded(22))
    }
}

/// A tab (StripTab): activity in its leading slot (the close cross while hovered), the title centred, the ⌘ legend at
/// its end, a hairline after it between two unselected tabs.
struct TabCell: View {
    let tab: TabItem
    let alone: Bool
    let glass: Bool
    var tint: HostTint?
    var divider = false
    private var p: SidebarPalette { Chrome.palette }
    private var t: AppTypography { Mock.typography }
    var body: some View {
        let semibold = glass && tab.selected && !alone
        ZStack {
            Text(tab.title).lineLimit(1).truncationMode(.middle)
                .font(Font(AppFont.native(size: t.tabSize, semibold: semibold)))
                .padding(.horizontal, 28)
            HStack(spacing: 0) {
                Group {
                    if tab.hovered {
                        // CloseGlyph: its square shows only under the pointer itself.
                        Image(systemName: "xmark").font(AppFont.ui(size: 8)).frame(width: t.expanded(16), height: t.expanded(16))
                    } else {
                        tab.activity.glyph(frame: 10)
                    }
                }
                .frame(width: 24).padding(.leading, 2)
                Spacer(minLength: 0)
                if let shortcut = tab.shortcut {
                    Text("⌘\(shortcut)").font(t.shortcut(offset: -2.5)).foregroundStyle(Chrome.muted).padding(.trailing, 10)
                }
            }
        }
        .foregroundStyle(tab.selected ? p.ink : (glass ? tint?.tabForeground : nil) ?? Chrome.muted)
        .frame(minWidth: t.expanded(120), maxWidth: .infinity)
        .frame(height: glass ? StripTab.glassTrackHeight(t) : t.expanded(30))
        .overlay(alignment: .bottom) {
            if !glass && tab.selected && !alone {
                Rectangle().fill(tint == nil ? p.ink.opacity(0.7) : HostTint.selectedTabRule).frame(height: 1)
            }
        }
        .overlay(alignment: .trailing) {
            if divider {
                Rectangle().fill(Chrome.border).frame(width: 1, height: t.expanded(glass ? 16 : 14)).offset(x: 0.5)
            }
        }
    }
}

/// A pane: its strip over its content. In a split the focused pane has a faint accent edge, unless its badge shows
/// (the badge marks focus then: PaneView's overlay).
struct Pane<Content: View>: View {
    let strip: StripModel
    var focusEdge = false
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: strip)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(Mock.typography.font(.label))
        .overlay {
            if focusEdge && strip.focused && (strip.paneBadge == nil || strip.titleRow) {
                Rectangle().strokeBorder(Chrome.accent.opacity(0.35), lineWidth: 1)
            }
        }
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
/// sidebar view.
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
