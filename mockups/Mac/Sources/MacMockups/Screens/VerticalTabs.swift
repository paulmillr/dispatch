import SwiftUI

// Vertical tabs (exploration, 2026-11-07). Replaces tabs only ("Vertical tabs, no spaces"), which goes entirely: no
// list of every tab, no Spaces ⌄ / Tabs ⌄ menu (the kit's top row is icons only). The sidebar has two levels, as the
// iPhone's Spaces and a space's tabs: clicking a space opens it (its tab shows) and the sidebar moves into it, listing
// that space's tabs. The glass bar has the sidebar toggle and New Tab; under it the space's heading (Back as a glass
// circle with the needs-you count of the other spaces, the name, which is the space menu, the dimmed folder, the layout
// picker under New Tab, a rule), then the tabs. No strip: the content leads with a title row naming the tab, with the mode and layout buttons.
// Hosts and work are fictional.

enum VerticalTabs {
    static let screens: [Screen] = [
        Screen("U1-inside-space", group: "vtabs", "Inside a space: its tabs are the sidebar") {
            DispatchWindow(side: { InsideSpace(space: app, tabs: appTabs) }) {
                VStack(spacing: 0) {
                    FloatingControls(mode: .chat, agent: true)
                    ChatPane(items: Sample.chat, composer: ComposerModel(draft: "Also cover the zero-amount case"))
                }
            }
            .overlay(alignment: .topLeading) {
                notes([(1, CGPoint(x: 6, y: 40)), (2, CGPoint(x: 240, y: 52)), (3, CGPoint(x: 240, y: 300)),
                       (4, CGPoint(x: 1066, y: 14))], legend: [
                    "Back: a glass circle, as iOS 26's, its badge the other spaces that need you; New tab on the bar",
                    "The space: its name (the space menu: Rename, Detach, Terminate), the folder; the layout picker under New tab",
                    "A long title wraps to a second line; the ⌘ key stays on the first",
                    "No strip: the content's full height, its mode and layout buttons floating at its corner",
                ], at: CGPoint(x: 300, y: 80))
            }
        },
        Screen("U2-spaces", group: "vtabs", "Back: the spaces, the current one marked") {
            DispatchWindow(side: { SpacesLevel() }) {
                VStack(spacing: 0) {
                    FloatingControls(mode: .chat, agent: true)
                    ChatPane(items: Sample.chat, composer: ComposerModel(draft: "Also cover the zero-amount case"))
                }
            }
            .overlay(alignment: .topLeading) {
                notes([(1, CGPoint(x: 240, y: 186)), (2, CGPoint(x: 600, y: 14))], legend: [
                    "A click shows the space and goes into it; ⇧⌘1…9 do the same",
                    "The shown tab stays until you pick",
                ], at: CGPoint(x: 300, y: 80))
            }
        },
        Screen("U3-split", group: "vtabs", "A space with two panes: its tabs grouped by pane") {
            DispatchWindow(side: { InsideSpace(space: app, tabs: [], panes: splitPanes) }) {
                Split(fraction: 0.5) {
                    VStack(spacing: 0) {
                        FloatingControls(mode: .terminal, agent: false, layout: nil)
                        TerminalScreen(lines: Sample.tests, focused: false)
                    }
                } second: {
                    VStack(spacing: 0) {
                        FloatingControls(mode: .chat, agent: true)
                        ChatPane(items: [Sample.chat[0], Sample.chat[1], .tools(Array(Sample.steps.prefix(3)))],
                                 composer: ComposerModel(working: ("working", "38s")), live: true)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                notes([(1, CGPoint(x: 240, y: 132)), (2, CGPoint(x: 240, y: 252))], legend: [
                    "A pane per heading; ⌘1 / ⌘2 focus a pane, as today",
                    "Drag a row under the other heading to move it there",
                ], at: CGPoint(x: 640, y: 80))
            }
        },
        Screen("U6-sidebar-hidden", group: "vtabs", "Sidebar hidden: the toggle floats beside the traffic lights") {
            DispatchWindow(sidebar: nil) {
                VStack(spacing: 0) {
                    FloatingControls(mode: .chat, agent: true, layout: .single, sidebarHidden: true)
                    ChatPane(items: Sample.chat, composer: ComposerModel(draft: "Also cover the zero-amount case"))
                }
            }
            .overlay(alignment: .topLeading) {
                notes([(1, CGPoint(x: 126, y: 6)), (2, CGPoint(x: 1066, y: 14))], legend: [
                    "The sidebar toggle floats beside the traffic lights; ⌘\\ shows the sidebar",
                    "The content keeps the window's full height; its mode and layout buttons float at its corner",
                ], at: CGPoint(x: 300, y: 80))
            }
        },
        Screen("U9-tmux", group: "vtabs", "A tmux space: a window per row, its panes a line each") {
            DispatchWindow(side: { InsideSpace(space: api, tabs: tmuxWindows, detail: "ai · main") }) {
                VStack(spacing: 0) {
                    FloatingControls(mode: .terminal)
                    Split(fraction: 0.5) {
                        TerminalScreen(lines: tmuxLeft).frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading).clipped()
                    } second: {
                        TerminalScreen(lines: tmuxRight, focused: false).frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading).clipped()
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                notes([(1, CGPoint(x: 240, y: 52)), (2, CGPoint(x: 240, y: 132)), (3, CGPoint(x: 240, y: 186))], legend: [
                    "A tmux session's space: its host's disc, its git branch after the host",
                    "A window per row, ⌘1…9; with two panes or more, a line per pane, its place in the layout",
                    "A line's click focuses its pane; the focused pane's line is bright",
                ], at: CGPoint(x: 640, y: 300))
            }
        },
        Screen("U10-large-inside", group: "vtabs", "Large spaces on: inside a space, its tabs as cards") {
            DispatchWindow(side: { InsideSpace(space: billing, tabs: appTabs, large: true) }) {
                VStack(spacing: 0) {
                    FloatingControls(mode: .chat, agent: true)
                    ChatPane(items: Sample.chat, composer: ComposerModel(draft: "Also cover the zero-amount case"))
                }
            }
            .overlay(alignment: .topLeading) {
                notes([(1, CGPoint(x: 240, y: 40)), (2, CGPoint(x: 240, y: 150))], legend: [
                    "The space: the host's orb, as on its card at the spaces; name, folder dimmed, a rule",
                    "A tab per card: its kind on a neutral orb (its status's glyph there for news other than work), the title, its key, the status's word",
                ], at: CGPoint(x: 300, y: 80))
            }
        },
        Screen("U10b-large-spaces", group: "vtabs", "Large spaces on: the spaces, as cards today") {
            DispatchWindow(side: { LargeSpacesLevel() }) {
                VStack(spacing: 0) {
                    FloatingControls(mode: .chat, agent: true)
                    ChatPane(items: Sample.chat, composer: ComposerModel(draft: "Also cover the zero-amount case"))
                }
            }
            .overlay(alignment: .topLeading) {
                notes([(1, CGPoint(x: 240, y: 98))], legend: [
                    "A click on a card shows the space and goes into it",
                ], at: CGPoint(x: 300, y: 80))
            }
        },
        Screen("U8-glass-back", group: "vtabs", "A remote space and a local one: the host's disc and the folder line") {
            HStack(alignment: .top, spacing: 28) {
                compare("A remote space") { InsideSpace(space: billing, tabs: appTabs) }
                compare("A local space") { InsideSpace(space: app, tabs: appTabs) }
            }
        },
    ]


    private static let tmuxLeft: [TermLine] = [
        .prompt("cargo run --bin api", folder: "api", branch: "main", dirty: false),
        T(c(2, "   Compiling", bold: true), " api v0.4.2 (~/src/api)"),
        T(c(2, "    Finished", bold: true), " dev profile in 6.1s"),
        T(c(2, "     Running", bold: true), " target/debug/api"),
        T(c(8, "INFO"), " listening on 0.0.0.0:7070"),
        T(c(8, "INFO"), " retry queue: 3 workers"),
    ]
    private static let tmuxRight: [TermLine] = [
        .prompt("tail -f log/requests.log", folder: "api", branch: "main", dirty: false),
        T(c(6, "GET "), " /v1/jobs     ", c(2, "200"), c(8, "  8ms")),
        T(c(5, "POST"), " /v1/jobs     ", c(2, "201"), c(8, " 14ms")),
        T(c(6, "GET "), " /v1/jobs/77  ", c(3, "404"), c(8, "  2ms")),
        T(c(5, "POST"), " /v1/retry    ", c(2, "202"), c(8, "  5ms")),
        T(c(6, "GET "), " /health      ", c(2, "200"), c(8, "  1ms")),
    ]

    private static func compare(_ title: String, @ViewBuilder _ sidebar: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Chrome.palette.secondary)
            MacWindow(width: 264, height: 480) { sidebar() }
        }
    }

    /// Numbered markers by what they mark, and their notes together in an empty part of the content.
    private static func notes(_ markers: [(Int, CGPoint)], legend: [String], at origin: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(markers, id: \.0) { Callout(number: $0.0).offset(x: $0.1.x, y: $0.1.y) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(legend.enumerated()), id: \.offset) { Callout(number: $0.offset + 1, note: $0.element) }
            }
            .offset(x: origin.x, y: origin.y)
        }
    }

    // MARK: Data

    static let app = SpaceItem(name: "app", activity: .finished, shortcut: 1, selected: true)
    static let api = SpaceItem(name: "api", host: Hosts.ai, activity: .working, shortcut: 4, selected: true)
    static let tmuxWindows: [VTab] = [
        VTab(title: "editor", shortcut: 1, panes: ["nvim src/retry.rs", "zsh"], paneAxis: .vertical),
        VTab(title: "server", shortcut: 2, selected: true, panes: ["cargo run --bin api", "tail -f log/requests.log"], focusedPane: 0),
        VTab(title: "Fix the flaky retry test", kind: .agent, activity: .working, shortcut: 3),
        VTab(title: "~", shortcut: 4),
    ]
    static let billing = SpaceItem(name: "billing", host: Hosts.buildBox, activity: .waiting, shortcut: 3, selected: true)

    static let appTabs: [VTab] = [
        VTab(title: "Fix the invoice rounding", kind: .agent, activity: .finished, shortcut: 1, selected: true),
        VTab(title: "Refactor billing", kind: .agent, activity: .working, shortcut: 2),
        VTab(title: "Rate limiter for the API", kind: .agent, activity: .waiting, shortcut: 3, place: (nil, "api")),
        VTab(title: "tests", shortcut: 4, hovered: true),
        VTab(title: "server", shortcut: 5),
        VTab(title: "Move the docs site to Starlight, with redirects for every old page", kind: .agent,
             activity: .finished, shortcut: 6, place: (nil, "docs")),
        VTab(title: "~", shortcut: 7),
    ]

    static let splitPanes: [(PanePosition, [VTab])] = [
        (.left, [
            VTab(title: "tests", selected: true),
            VTab(title: "~"),
        ]),
        (.right, [
            VTab(title: "Refactor billing", kind: .agent, activity: .working, selected: true),
            VTab(title: "Fix the invoice rounding", kind: .agent, activity: .finished),
            VTab(title: "server"),
        ]),
    ]
}

struct VTab: Identifiable {
    var id: String { title }
    var title: String
    var kind = Kind.shell
    var activity = Activity.none
    var shortcut: Int?
    var selected = false
    var hovered = false
    /// A tmux or herdr window's panes, a line each under its title when there are two or more; side by side
    /// (`.horizontal`) or stacked.
    var panes: [String] = []
    var paneAxis = Axis.horizontal
    /// The pane focused in the shown window: its line is bright.
    var focusedPane: Int?
    /// A line under the title saying where the tab is: the host (in its colour) when given, then the folder's name.
    var place: (host: MockHost?, folder: String)?
    enum Kind { case shell, agent }

    var paneSymbols: [String] {
        paneAxis == .horizontal ? ["rectangle.lefthalf.filled", "rectangle.righthalf.filled"]
            : ["rectangle.tophalf.filled", "rectangle.bottomhalf.filled"]
    }
}

enum PanePosition {
    case left, right
    var symbol: String { self == .left ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled" }
}

// MARK: Sidebar, inside a space

/// The sidebar inside a space: the glass bar (GlassBackRow), the space's heading (SpaceTitle), its tabs (a heading per
/// pane in a split), "+ tab" at the foot as "+ space" is at the spaces.
struct InsideSpace: View {
    let space: SpaceItem
    let tabs: [VTab]
    var panes: [(PanePosition, [VTab])] = []
    /// The heading's second line in place of host · folder (a tmux session's).
    var detail: String?
    /// Settings › Large spaces: the heading with the host's orb, a card per tab (Large).
    var large = false
    /// The heading's second line as the app draws it (SpaceTabsHeading): host · folder's name; false, a session's
    /// `detail` in its place.
    var place = true
    var body: some View {
        SidebarColumn(model: Sample.sidebar) {
            GlassBackRow(trailing: large ? 27 : 20)
        } list: {
            if large {
                VStack(spacing: Large.spacing) {
                    LargeSpaceTitle(space: space, layout: panes.isEmpty ? .single : .columns)
                    ForEach(tabs) { LargeTabCard(tab: $0, host: space.host) }
                }
            } else {
            VStack(spacing: 2) {
                SpaceTitle(space: space, detail: detail, layout: panes.isEmpty ? .single : .columns, place: place)
                if panes.isEmpty {
                    ForEach(tabs) { VTabRow(tab: $0) }
                } else {
                    ForEach(Array(panes.enumerated()), id: \.offset) { index, pane in
                        PaneHeading(position: pane.0, number: index + 1, focused: index == 1).padding(.top, index == 0 ? 0 : 8)
                        ForEach(pane.1) { VTabRow(tab: $0, paneFocused: index == 1) }
                    }
                }
            }
            }
        }
    }
}

/// A pane's heading in a split: the layout with its pane filled, the side, its ⌘ number (accent when focused).
struct PaneHeading: View {
    let position: PanePosition
    let number: Int
    var focused = false
    var body: some View {
        let p = Chrome.palette
        // One step out from the tabs: the layout in their activity column, the side where their glyphs start
        // (VTabRow: 6 + 14 + 7 = 27).
        HStack(spacing: 7) {
            Image(systemName: position.symbol).font(.system(size: 12)).foregroundStyle(focused ? p.accent : p.muted)
                .frame(width: 14)
            Text(position == .left ? "Left" : "Right").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.secondary)
            Spacer()
            Text("⌘\(number)").font(.system(size: 12.5).monospacedDigit()).tracking(0.75)
                .foregroundStyle(focused ? p.accent : p.secondary.opacity(0.7))
        }
        .padding(.leading, 6).padding(.trailing, 10).frame(height: 28)
    }
}

/// A tab's row, one line tall unless its title needs two: activity (the close cross while hovered), the kind's glyph (the chat
/// bubble for an agent, the terminal for a shell), the title on up to two lines (the second its continuation, "…" past
/// it), the ⌘ number on the first. No status line: the activity glyph and the title say enough; a tab whose folder is not
/// its space's says where it is under its title (`place`).
struct VTabRow: View {
    let tab: VTab
    /// In a split, the selected tab of an unfocused pane shows on a fainter fill.
    var paneFocused = true
    private var p: SidebarPalette { Chrome.palette }
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Group {
                if tab.hovered {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(p.muted)
                } else {
                    tab.activity.glyph()
                }
            }
            .frame(width: 14, height: 18)
            Image(systemName: tab.kind == .agent ? "text.bubble" : "terminal")
                .font(.system(size: 12.5)).foregroundStyle(p.muted).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title).lineLimit(2).truncationMode(.tail)
                    .interfaceFont(size: 13.5, weight: tab.selected && paneFocused ? .semibold : .regular)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
                if let place = tab.place {
                    PlaceText(host: place.host, folder: place.folder, size: 12)
                }
                if tab.panes.count > 1 {
                    ForEach(Array(tab.panes.enumerated()), id: \.offset) { index, pane in
                        let bright = tab.selected && tab.focusedPane == index
                        HStack(spacing: 6) {
                            Image(systemName: tab.paneSymbols[min(index, 1)]).font(.system(size: 10.5))
                                .foregroundStyle(bright ? p.accent : p.muted)
                            Text(pane).interfaceFont(size: 12).lineLimit(1).truncationMode(.tail)
                                .foregroundStyle(bright ? p.ink : p.sidebarDetail)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing.frame(height: 18)
        }
        .foregroundStyle(tab.selected ? p.ink : p.secondary)
        // A space's row is 33 tall (SpaceRow): one line here is the same, 18 + 2 × 7.5.
        .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 7.5)
        .frame(minHeight: 33)
        .background(RoundedRectangle(cornerRadius: Mock.glass ? 6 : 13).fill(fill))
    }

    @ViewBuilder private var trailing: some View {
        if let shortcut = tab.shortcut {
            Text("⌘\(shortcut)").font(.system(size: 12.5).monospacedDigit()).tracking(0.75).foregroundStyle(p.secondary.opacity(0.7))
        }
    }

    private var fill: Color {
        if tab.selected { return paneFocused ? p.selection : p.hover }
        return tab.hovered ? p.hover : .clear
    }
}

// MARK: Sidebar, the spaces

/// Back at the spaces: the app's Spaces list (tree order here), the space shown marked; a click shows that space and
/// goes into it.
struct SpacesLevel: View {
    var body: some View {
        let model = SidebarModel(spaces: Sample.sidebar.spaces.map { space in
            var space = space
            if space.name == "billing" { space.hovered = true }
            return space
        }, tree: true)
        SidebarColumn(model: model) {
            Sidebar.treeList(model)
        }
    }
}

// MARK: Content

/// No strip: the content takes the window's full height. Its mode button (and on the top-right pane the layout
/// picker beside it) floats at its top-right corner (TerminalContentView.floatingLayout); with the sidebar hidden, the
/// sidebar toggle floats beside the traffic lights (MainView.floatingSidebarToggle). Laid in a stack before the
/// content, it takes no height and draws over it.
struct FloatingControls: View {
    var mode = PaneMode.terminal
    var agent = false
    /// The layout picker floats only with the sidebar hidden; its bar holds it otherwise.
    var layout: PaneLayout? = nil
    var sidebarHidden = false
    private var p: SidebarPalette { Chrome.palette }
    private var t: AppTypography { Mock.typography }
    var body: some View {
        let track = StripTab.glassTrackHeight(t)
        Color.clear.frame(height: 0).frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    modeButton
                    if let layout { layoutButton(layout) }
                }
                .frame(height: track)
                .background {
                    let shape = Capsule()
                    if Mock.glass {
                        shape.fill(GlassTone.track).overlay(shape.stroke(GlassTone.trackEdge, lineWidth: 0.5))
                            .shadow(color: GlassTone.shadow, radius: 2, y: 1)
                    } else {
                        shape.fill(ChatColors.current.ink.opacity(0.06))
                    }
                }
                .fixedSize()
                .padding(.top, 10).padding(.trailing, 12)
            }
            .overlay(alignment: .topLeading) {
                if sidebarHidden {
                    Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(Chrome.muted)
                        .frame(width: track, height: track)
                        .background {
                            if Mock.glass {
                                Circle().fill(GlassTone.track).overlay(Circle().stroke(GlassTone.trackEdge, lineWidth: 0.5))
                                    .shadow(color: GlassTone.shadow, radius: 2, y: 1)
                            }
                        }
                        .fixedSize()
                        .padding(.leading, Mock.controlsInset)
                        .padding(.top, (t.expanded(Mock.glass ? 38 : 30) - track) / 2)
                }
            }
            .zIndex(1)
    }

    private var modeButton: some View {
        let chat = mode == .chat || (mode == .terminal && agent)
        let lit = mode != .terminal
        return Image(systemName: chat ? "text.bubble" : "folder").font(.system(size: 13.5))
            .foregroundStyle(lit ? ChatColors.current.accent : ChatColors.current.muted)
            .padding(.horizontal, 7).frame(minHeight: t.expanded(22))
    }

    private func layoutButton(_ layout: PaneLayout) -> some View {
        Image(systemName: layout.symbol).font(.system(size: t.tabSize))
            .foregroundStyle(layout == .single ? Chrome.muted : ChatColors.current.accent)
            .padding(.horizontal, 7).frame(minHeight: t.expanded(22))
    }
}

// MARK: The bar and the heading

/// The bar inside a space, icons only: the sidebar toggle, then at the end New Tab, ending where the rows' shortcuts
/// do. The heading under it has Back, the space menu (its name) and the layout picker (SpaceTitle).
struct GlassBackRow: View {
    /// Where New Tab ends from the sidebar's edge: the rows' shortcuts' end (the list's 10, a row's 10; Large's 17).
    var trailing: CGFloat = 20
    private var p: SidebarPalette { Chrome.palette }
    private var t: AppTypography { Mock.typography }
    var body: some View {
        let side = Mock.glass ? StripTab.glassTrackHeight(t) : 24
        HStack(spacing: 4) {
            Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(p.detail).frame(width: side, height: side)
            Spacer(minLength: 6)
            MockGlassCircle { Image(systemName: "plus").font(.system(size: 13, weight: .medium)) }
        }
        .padding(.leading, Mock.controlsInset).padding(.trailing, trailing)
        .frame(height: t.expanded(Mock.glass ? 38 : 30))
    }
}

/// SidebarGlassCircle: a glass circle as tall as the strip's track, as the strip's +; flat, the sidebar's action fill.
struct MockGlassCircle<Label: View>: View {
    @ViewBuilder let label: Label
    var body: some View {
        let p = Chrome.palette, side = Mock.glass ? StripTab.glassTrackHeight(Mock.typography) : 24
        label.foregroundStyle(p.secondary).frame(width: side, height: side).background {
            if Mock.glass {
                Circle().fill(GlassTone.track).overlay(Circle().stroke(GlassTone.trackEdge, lineWidth: 0.5))
                    .shadow(color: GlassTone.shadow, radius: 2, y: 1)
            } else {
                Circle().fill(p.sidebarAction)
            }
        }
    }
}

/// The heading's layout picker (two tabs or more, as a strip shows it): the layout's glyph, lit while split.
struct MockLayoutCircle: View {
    let layout: PaneLayout
    var body: some View {
        MockGlassCircle {
            Image(systemName: layout.symbol).font(.system(size: Mock.typography.tabSize))
                .foregroundStyle(layout == .single ? Chrome.muted : ChatColors.current.accent)
        }
    }
}

/// The space under the glass bar: Back, its name (larger than a tab's, the space menu) and, dimmed under it, where it
/// is as the phone says it (a remote one's host in its colour, then the folder's name; a local one named for its folder
/// says nothing more), then the layout picker under the bar's New Tab; a hairline under the heading sets
/// it apart from the tabs. The name starts where the tabs' titles do (VTabRow: 52).
struct SpaceTitle: View {
    let space: SpaceItem
    var detail: String?
    var layout: PaneLayout? = .single
    var place = true
    var body: some View {
        let p = Chrome.palette
        HStack(spacing: 5) {
            // Back, centered in the free space before the name, which starts where the tab titles do (52).
            BackCircle().frame(width: 47)
            VStack(alignment: .leading, spacing: 1) {
                // The name is the space menu: Rename, Detach and Terminate.
                HStack(spacing: 5) {
                    Text(space.name).interfaceFont(size: 17, weight: .semibold).foregroundStyle(p.ink).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(p.detail)
                }
                if place && detail == nil {
                    // Named for its folder: a remote space's line says its host alone, a local one's goes (SpaceTabsHeading).
                    if !space.host.local { PlaceText(host: space.host, folder: nil, size: 12.5) }
                } else {
                    Text(detail ?? (space.host.local ? "~/src/\(space.name)" : "\(space.host.name) · ~/src/\(space.name)"))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.sidebarDetail)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            // The layout picker, centered under the bar's New Tab (20 from the edge, the list's 10 in).
            if let layout { MockLayoutCircle(layout: layout).padding(.trailing, 10) }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Chrome.border).frame(height: 1).offset(y: 6) }
        .padding(.bottom, 12)
    }
}

// MARK: Large (Settings › Large spaces)

/// SidebarMetrics.large at content size 14 (scale 14 / 12.5): names 15.5, details 12.5, cards 65 tall and 7 apart,
/// 16-point corners, 36-point orbs (SidebarSpaceCard).
enum Large {
    static let scale: CGFloat = 14 / 12.5
    static let name: CGFloat = 15.5
    static let detail: CGFloat = 12.5
    static let height: CGFloat = (58 * scale).rounded()
    static let spacing: CGFloat = (6 * scale).rounded()
    static let corner: CGFloat = (14 * scale).rounded()
    static let orb: CGFloat = (32 * scale).rounded()
    /// Where a card's text starts: its padding, the orb, the gap.
    static let textInset: CGFloat = 9 + orb + 11
}

/// SidebarSpaceCard's pieces, as the app draws them: the orb, the keycap, the status pill, the card's surface and edge.
@MainActor enum LargeCard {
    static func orb(_ glyph: some View, hue: Color?, selected: Bool = false) -> some View {
        let dark = Chrome.palette.isDark
        return glyph.foregroundStyle(hue ?? Chrome.palette.secondary)
            .frame(width: Large.orb, height: Large.orb)
            .background {
                Circle().fill(RadialGradient(colors: [(hue ?? Chrome.ink).opacity(dark ? 0.26 : 0.18),
                                                      (hue ?? Chrome.ink).opacity(dark ? 0.08 : 0.05)],
                                             center: .topLeading, startRadius: 0, endRadius: Large.orb))
            }
            .overlay { Circle().strokeBorder((hue ?? Chrome.ink).opacity(selected ? 0.45 : 0.2), lineWidth: 1) }
    }

    static func keycap(_ text: String, selected: Bool) -> some View {
        let dark = Chrome.palette.isDark
        return Text(text).font(.system(size: Large.detail).monospacedDigit()).tracking(Large.detail * 0.04)
            .foregroundStyle(Chrome.palette.secondary.opacity(selected ? 0.95 : 0.7))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Chrome.ink.opacity(dark ? 0.07 : 0.05), in: Capsule())
            .overlay { Capsule().strokeBorder(Chrome.ink.opacity(dark ? 0.1 : 0.08), lineWidth: 0.5) }
            .fixedSize()
    }

    /// AgentActivity.label's word on a pill of its colour, with the glyph; nil for no news.
    @ViewBuilder static func status(_ activity: Activity, word showsWord: Bool = true, glyph showsGlyph: Bool = true) -> some View {
        let p = Chrome.palette
        let word: String? = switch activity {
        case .working: "Working"
        case .waiting: "Needs approval"
        case .finished: "Unread"
        case .failed: "Failed"
        case .offline: "Offline"
        default: nil
        }
        if let word {
            let color = activity == .waiting || activity == .failed ? p.warning : activity == .finished ? Chrome.accent
                : activity == .offline ? Chrome.muted : Chrome.ink
            HStack(spacing: 4) {
                if showsGlyph { activity.glyph(size: Large.detail + 1.5, frame: 10) }
                if showsWord { Text(word).foregroundStyle(color).lineLimit(1) }
            }
            .interfaceFont(size: Large.detail)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(color.opacity(p.isDark ? 0.14 : 0.1), in: Capsule())
            .fixedSize()
        }
    }

    static func surface(selected: Bool, hue: Color?) -> some View {
        let dark = Chrome.palette.isDark
        let shape = RoundedRectangle(cornerRadius: Large.corner, style: .continuous)
        let wash = hue.map { $0.opacity(dark ? 0.16 : 0.1) } ?? Chrome.ink.opacity(dark ? 0.09 : 0.06)
        return ZStack {
            shape.fill(Mock.glass ? GlassTone.track : Chrome.ink.opacity(dark ? 0.035 : 0.025))
            if selected { shape.fill(wash) }
        }
        .shadow(color: selected ? (hue?.opacity(dark ? 0.3 : 0.18) ?? .clear) : .clear, radius: 12, y: 4)
    }

    static func edge(selected: Bool, hue: Color?) -> some View {
        let dark = Chrome.palette.isDark
        let accent = selected ? hue : nil
        let top = accent.map { $0.opacity(0.55) } ?? Color.white.opacity(dark ? (selected ? 0.18 : 0.1) : 0.5)
        let bottom = accent.map { $0.opacity(0.2) } ?? Color.white.opacity(dark ? 0.03 : 0.15)
        return RoundedRectangle(cornerRadius: Large.corner, style: .continuous)
            .strokeBorder(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom), lineWidth: 1)
    }
}

/// A space's card at the spaces (SidebarSpaceCard): the host's orb, the name (semibold while shown) and keycap, then
/// the host's name, the tab count and the status pill.
struct LargeSpaceCard: View {
    let space: SpaceItem
    let tabs: Int
    var body: some View {
        let p = Chrome.palette
        let hue = space.host.tint?.foreground
        let detail = p.secondary.opacity(space.selected ? 0.8 : 0.62)
        HStack(spacing: 11) {
            LargeCard.orb(MockHostGlyph(system: space.host.system, size: Mock.typography.hostIconSize), hue: hue, selected: space.selected)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(space.name).font(Font(AppFont.native(size: Large.name, semibold: space.selected)))
                        .foregroundStyle(space.selected ? Chrome.ink : p.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let key = space.shortcut { LargeCard.keycap("⇧⌘\(key)", selected: space.selected) }
                }
                // The fullest line that fits, as the app's: the tab count goes first, then the status's word.
                ViewThatFits(in: .horizontal) {
                    details(hue: hue, detail: detail, count: true, word: true)
                    details(hue: hue, detail: detail, count: false, word: true)
                    details(hue: hue, detail: detail, count: false, word: false)
                }
            }
        }
        .padding(.leading, 9).padding(.trailing, 11)
        .frame(height: Large.height)
        .background { LargeCard.surface(selected: space.selected, hue: hue) }
        .overlay { LargeCard.edge(selected: space.selected, hue: hue) }
    }
}

extension LargeSpaceCard {
    fileprivate func details(hue: Color?, detail: Color, count: Bool, word: Bool) -> some View {
        HStack(spacing: 5) {
            if !space.host.local {
                Text(space.host.name).foregroundStyle(hue ?? detail).fixedSize()
                if count { Text("·").foregroundStyle(detail.opacity(0.6)) }
            }
            if count { Text(tabs == 1 ? "1 tab" : "\(tabs) tabs").foregroundStyle(detail).fixedSize() }
            Spacer(minLength: 6)
            LargeCard.status(space.activity, word: word)
        }
        .interfaceFont(size: Large.detail).lineLimit(1)
    }
}

/// A tab's card inside a space, Large's card at a tab's measure: the tab's kind (the chat bubble for an agent, the
/// terminal for a shell) on a neutral orb, the title on up to two lines with its ⌘ key, and under it the
/// status pill when the tab has news. As tall as a space's card, taller when the title wraps.
struct LargeTabCard: View {
    let tab: VTab
    let host: MockHost
    /// Unread, needs you, failed: the status takes the orb. Working keeps the kind's glyph and its pill's.
    private var statusInOrb: Bool { [.finished, .waiting, .failed].contains(tab.activity) }
    var body: some View {
        let p = Chrome.palette
        let hue = host.tint?.foreground
        HStack(alignment: .center, spacing: 11) {
            // On a neutral orb (the host's colour is the heading's and the selection's): the status's glyph while the
            // tab has news other than work, the pill keeping its word; otherwise the kind's glyph.
            LargeCard.orb(Group {
                if statusInOrb { tab.activity.glyph(size: 15, frame: 15) }
                else { Image(systemName: tab.kind == .agent ? "text.bubble" : "terminal").font(.system(size: 14)) }
            }, hue: nil, selected: tab.selected)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(tab.title).font(Font(AppFont.native(size: Large.name, semibold: tab.selected)))
                        .foregroundStyle(tab.selected ? Chrome.ink : p.secondary)
                        .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let key = tab.shortcut { LargeCard.keycap("⌘\(key)", selected: tab.selected) }
                }
                LargeCard.status(tab.activity, glyph: !statusInOrb)
            }
        }
        .padding(.leading, 9).padding(.trailing, 11).padding(.vertical, 10)
        .frame(minHeight: Large.height)
        .background { LargeCard.surface(selected: tab.selected, hue: hue) }
        .overlay { LargeCard.edge(selected: tab.selected, hue: hue) }
    }
}

/// The space's heading in Large: Back over the cards' orbs, the name over their titles, the folder dimmed, the layout
/// picker under the bar's New Tab, a rule under it.
struct LargeSpaceTitle: View {
    let space: SpaceItem
    var layout: PaneLayout? = .single
    var body: some View {
        let p = Chrome.palette
        HStack(spacing: 11) {
            BackCircle().frame(width: 9 + Large.orb)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(space.name).interfaceFont(size: 18, weight: .semibold).foregroundStyle(p.ink).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(p.detail)
                }
                Text(space.host.local ? "~/src/\(space.name)" : "\(space.host.name) · ~/src/\(space.name)")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.sidebarDetail)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            // The layout picker, centered under the bar's New Tab (27 from the edge, the list's 10 in).
            if let layout { MockLayoutCircle(layout: layout).padding(.trailing, 17) }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Chrome.border).frame(height: 1).offset(y: 8) }
        .padding(.bottom, 10)
    }
}

/// Back at the spaces with Large on: a card per space (flat order), the shown one selected, "+ space" at the foot.
struct LargeSpacesLevel: View {
    var body: some View {
        let spaces = Sample.sidebar.spaces.map { space -> SpaceItem in
            var space = space
            space.selected = space.name == "billing"
            return space
        }
        let counts = ["app": 4, "docs": 2, "billing": 7, "e2e": 3, "release": 1]
        SidebarColumn(model: Sample.sidebar) {
            VStack(spacing: Large.spacing) {
                ForEach(spaces) { LargeSpaceCard(space: $0, tabs: counts[$0.name] ?? 1) }
                NewSpaceRow(local: true).padding(.top, 4)
            }
        }
    }
}

/// Back to the spaces: a glass circle with the count of other spaces that need you.
struct BackCircle: View {
    var body: some View {
        let p = Chrome.palette
        let side = Mock.glass ? StripTab.glassTrackHeight(Mock.typography) : 24
        Image(systemName: "chevron.left").font(.system(size: 13, weight: .medium)).foregroundStyle(p.secondary)
            .frame(width: side, height: side)
            .background {
                if Mock.glass {
                    Circle().fill(GlassTone.track).overlay(Circle().stroke(GlassTone.trackEdge, lineWidth: 0.5))
                        .shadow(color: GlassTone.shadow, radius: 2, y: 1)
                } else {
                    Circle().fill(p.sidebarAction)
                }
            }
            .overlay(alignment: .topTrailing) {
                Text("1").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Chrome.window)
                    .frame(minWidth: 14, minHeight: 14).background(p.green, in: Circle()).offset(x: 4, y: -3)
            }
    }
}

/// "build-box · app", as the phone's headers and the hover card's place line say where a tab is: the host's name in
/// its colour (none given: the folder alone), then the folder's name, dimmed.
struct PlaceText: View {
    let host: MockHost?
    let folder: String?
    let size: CGFloat
    var body: some View {
        let p = Chrome.palette
        HStack(spacing: 0) {
            if let host {
                Text(host.name).foregroundStyle(host.local ? p.secondary : host.foreground)
                if folder != nil { Text(" · ").foregroundStyle(p.sidebarDetail) }
            }
            if let folder { Text(folder).foregroundStyle(p.sidebarDetail) }
        }
        .interfaceFont(size: size).lineLimit(1).truncationMode(.middle)
    }
}
