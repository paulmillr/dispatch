import SwiftUI

// B: the Mac's one mode button on the phone (2026-11-01). The Terminal · Chat · Files capsule goes; a bar toggle left
// of the host, sharing its glass, carries the tab's mode as the Mac strip's `ChatModeSwitch` does. Chat shown: the
// bubble, on (the system's selected toggle). An agent's tab in Terminal: the bubble, unlit (a tap opens chat). A shell's tab in Terminal: the folder, unlit
// (a tap opens files). Files shown: the folder, on. A tap from Chat or Files returns to Terminal; a long press lists
// every mode: Terminal, Chat, then Files, Review, Commits, the shown one checked.

enum ModeShown { case terminal, chat, files }

/// What the button draws (`ModeSwitchState.glyph` and `.lit` on the Mac).
struct ModeButtonState {
    let shown: ModeShown
    /// An agent runs or ran in the tab.
    let agent: Bool
    var symbol: String {
        switch shown {
        case .chat: "text.bubble"
        case .files: "folder"
        case .terminal: agent ? "text.bubble" : "folder"
        }
    }
    var lit: Bool { shown != .terminal }
}

/// The mode disc: lit, the pink glass with the glyph filled; unlit, plain glass with the outline glyph in primary.
struct ModeDisc: View {
    let state: ModeButtonState
    var pressed = false
    var body: some View {
        Image(systemName: state.lit ? state.symbol + ".fill" : state.symbol)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(state.lit ? Color.onAccent : Color.primary)
            .frame(width: 44, height: 44)
            .glassEffect(state.lit ? .regular.tint(.dispatchPink).interactive() : .regular.interactive(), in: Circle())
            .scaleEffect(pressed ? 1.12 : 1)
    }
}

/// How the mode button is drawn. `disc`: B1's first try, the lit state as pink glass (rejected: the prominent style is a
/// primary action's, not a toggle's). `glyph`: its own glass circle, lit as a pink glyph. `grouped`: the system's bar
/// items, the mode and the host sharing one glass capsule, lit as a pink glyph. `toggle`: SwiftUI's button-style Toggle,
/// as the bar draws it.
enum ModeButtonStyle { case disc, glyph, grouped, toggle }

/// Where the host goes. `hostTrailing` (B1–B6): the host shares the mode toggle's capsule on the right. `hostLeading`
/// (B7): the host shares Back's capsule on the left, the mode toggle alone on the right; `hostLeadingApart` (B7d) the
/// same with Back and the host as two discs. `info` (B8): B1's layout with the host glyph replaced by a plain bar glyph
/// (the tab's menu), the host left to the subtitle.
enum ModeHeaderLayout: Equatable { case hostTrailing, hostLeading, hostLeadingApart, info(String) }

/// X9b with the mode button before the tab's menu disc; the title loses its width and the gap.
struct ModeTabHeader: ToolbarContent {
    let title: String
    var subtitle: AnyView = AnyView(TabSubtitle())
    let state: ModeButtonState
    var pressed = false
    var style: ModeButtonStyle = .toggle
    var layout: ModeHeaderLayout = .hostTrailing
    var body: some ToolbarContent {
        switch layout {
        case .hostTrailing: hostTrailing
        case .hostLeading:
            ToolbarItem(placement: .topBarLeading) {
                Button {} label: { Image(systemName: "chevron.left").foregroundStyle(Color.dispatchPink) }
                    .overlay(alignment: .topTrailing) { CountBadge(label: "2").offset(x: 16, y: -14) }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {} label: { Image(systemName: "apple.logo").foregroundStyle(hostTint) }
            }
            ToolbarItem(placement: .topBarLeading) { titleBlock.padding(.leading, 4).frame(width: 402 - 32 - 104 - 12 - 72, alignment: .leading) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                ModeToggle(state: state)
            }
        case .hostLeadingApart:
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 8) {
                    BackPill()
                    HostDisc().overlay(alignment: .bottomTrailing) { MenuBadge() }
                    titleBlock.padding(.leading, 4)
                }
                .frame(width: 402 - 32 - 12 - 72, alignment: .leading)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                ModeToggle(state: state)
            }
        case .info(let symbol):
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 12) { BackPill(); titleBlock.padding(.leading, 4) }
                    .frame(width: 402 - 52 - 44 - 84, alignment: .leading)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .topBarTrailing) {
                ModeToggle(state: state)
                Button {} label: { Image(systemName: symbol).foregroundStyle(Color.primary) }
            }
        }
    }

    private var titleBlock: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(title).lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.semibold))
        .frame(minHeight: 40, alignment: .topLeading)
    }

    @ToolbarContentBuilder private var hostTrailing: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                BackPill()
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).lineLimit(1)
                        subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(title).lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 40, alignment: .topLeading)
                .padding(.leading, 4)
            }
            .frame(width: 402 - 52 - 44 - (style == .disc || style == .glyph ? 52 : style == .toggle ? 84 : 64), alignment: .leading)
        }
        .sharedBackgroundVisibility(.hidden)
        switch style {
        case .disc:
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) { ModeDisc(state: state, pressed: pressed); TabMenuDisc() }
            }
            .sharedBackgroundVisibility(.hidden)
        case .glyph:
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    Image(systemName: state.symbol).font(.system(size: 19))
                        .foregroundStyle(state.lit ? Color.dispatchPink : Color.primary)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: Circle())
                    TabMenuDisc()
                }
            }
            .sharedBackgroundVisibility(.hidden)
        case .grouped:
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {} label: { Image(systemName: state.symbol) }
                    .tint(state.lit ? Color.dispatchPink : Color.primary)
                    .foregroundStyle(state.lit ? Color.dispatchPink : Color.primary)
                Button {} label: { Image(systemName: "apple.logo").foregroundStyle(hostTint) }
            }
        case .toggle:
            ToolbarItemGroup(placement: .topBarTrailing) {
                ModeToggle(state: state)
                Button {} label: { Image(systemName: "apple.logo").foregroundStyle(hostTint) }
            }
        }
    }
}

/// B6: the styles over the three states, each row a bar of its own.
struct ModeStylesScreen: View {
    private let styles: [(String, ModeButtonStyle)] = [("Pink glass (B1)", .disc), ("Pink glyph, own circle", .glyph),
                                                       ("Pink glyph, shared with the host", .grouped), ("System toggle, shared with the host", .toggle)]
    private let states: [(String, ModeButtonState)] = [("Chat", .init(shown: .chat, agent: true)),
                                                       ("Agent in Terminal", .init(shown: .terminal, agent: true)),
                                                       ("Shell", .init(shown: .terminal, agent: false))]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(styles.enumerated()), id: \.offset) { _, style in
                    Text(style.0).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 10).padding(.leading, 20)
                    ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                        NavigationStack {
                            Color.canvas
                                .overlay(alignment: .bottomLeading) {
                                    Text(state.0).font(.caption2).foregroundStyle(.tertiary).padding(.leading, 20)
                                }
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar { ModeTabHeader(title: "Billing webhook retries", subtitle: AnyView(TabSubtitle(folder: "app")), state: state.1, style: style.1) }
                        }
                        .frame(height: 62)
                    }
                }
            }
        }
        .background(Color.canvas)
    }
}

/// The long press: the modes as the Mac's right-click menu lists them, glass from the button's corner. Review carries
/// the comment count the capsule's Files segment used to.
struct ModeMenu: View {
    let state: ModeButtonState
    var filesTab: FilesTabMode = .files
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Terminal", "apple.terminal", checked: state.shown == .terminal)
            row("Chat", "text.bubble", checked: state.shown == .chat, enabled: state.agent)
            Divider().padding(.vertical, 4)
            row("Files", "folder", checked: state.shown == .files && filesTab == .files)
            row("Review", "pencil.and.list.clipboard", checked: state.shown == .files && filesTab == .review, count: 3)
            row("Commits", "clock.arrow.circlepath", checked: state.shown == .files && filesTab == .commits)
        }
        .padding(.vertical, 6)
        .frame(width: 236)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    private func row(_ title: String, _ symbol: String, checked: Bool, enabled: Bool = true, count: Int? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).opacity(checked ? 1 : 0).frame(width: 18)
            Text(title).font(.body)
            if let count {
                Text("\(count)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16).background(Color.stateUnread, in: Capsule())
            }
            Spacer()
            Image(systemName: symbol).font(.body).frame(width: 24)
        }
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
        .padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 11)
    }
}

/// The menu over a screen: under the mode disc, its trailing edge on the menu disc's, the screen faintly dimmed.
private struct ModeMenuOverlay: ViewModifier {
    let state: ModeButtonState?
    var filesTab: FilesTabMode = .files
    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if let state {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    ModeMenu(state: state, filesTab: filesTab).padding(.trailing, 16).padding(.top, 54)
                }
            }
        }
    }
}

private struct KeyBar: View {
    var body: some View {
        HStack(spacing: 0) {
            ForEach(["Ctrl", "Esc", "Tab", "Alt"], id: \.self) { k in
                Text(k).font(.system(size: 17, design: .monospaced)).frame(maxWidth: .infinity)
            }
            Image(systemName: "dpad").font(.system(size: 20)).frame(maxWidth: .infinity)
            Image(systemName: "ellipsis").font(.system(size: 20)).frame(maxWidth: .infinity)
            Image(systemName: "keyboard").font(.system(size: 20)).frame(maxWidth: .infinity)
        }
        .frame(height: 50).padding(.horizontal, 8)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 12).padding(.bottom, 4)
    }
}

/// An agent's TUI in its terminal.
private struct AgentTerminalMock: View {
    let lines: [(String, Color)] = [
        ("> Make billing webhook retries idempotent.", .secondary), ("", .primary),
        ("⏺ Stripe retries the same event with a new attempt", .primary), ("  counter, so a counter-based guard can", .primary),
        ("  double-process. Keying on the event id instead.", .primary), ("", .primary),
        ("⏺ Update(src/routes/webhooks.ts)", .primary), ("  ⎿  Updated with 24 additions and 3 removals", .secondary), ("", .primary),
        ("⏺ Update(src/routes/invoices.ts)", .primary), ("  ⎿  Updated with 14 additions and 1 removal", .secondary), ("", .primary),
        ("✻ Running tests… (38s · ↓ 1.2k tokens)", Color.caution), ("", .primary),
        ("╭──────────────────────────────────────────╮", .secondary), ("│ >                                        │", .secondary),
        ("╰──────────────────────────────────────────╯", .secondary), ("  ⏵⏵ accept edits on (shift+tab to cycle)", .secondary),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.0).font(.system(size: 13, design: .monospaced)).foregroundStyle(line.1).lineLimit(1).frame(height: 20)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(Color.black)
    }
}

/// B1 / B1b: Chat shown, the bubble lit.
struct ModeChatScreen: View {
    var menu = false
    var layout: ModeHeaderLayout = .hostTrailing
    var body: some View {
        let state = ModeButtonState(shown: .chat, agent: true)
        NavigationStack {
            Transcript()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom) { Composer() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ModeTabHeader(title: "Billing webhook retries", subtitle: AnyView(TabSubtitle(folder: "app")), state: state, pressed: menu, layout: layout) }
        }
        .modifier(ModeMenuOverlay(state: menu ? state : nil))
    }
}

/// B2 / B2b: an agent's tab in Terminal, the bubble unlit: a tap opens its chat.
struct ModeAgentTerminalScreen: View {
    var menu = false
    var layout: ModeHeaderLayout = .hostTrailing
    var body: some View {
        let state = ModeButtonState(shown: .terminal, agent: true)
        NavigationStack {
            AgentTerminalMock()
                .safeAreaBar(edge: .bottom) { KeyBar() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ModeTabHeader(title: "Billing webhook retries", subtitle: AnyView(TabSubtitle(folder: "app", shell: "claude")), state: state, pressed: menu, layout: layout) }
        }
        .modifier(ModeMenuOverlay(state: menu ? state : nil))
        // The terminal is black in either scheme; its bar and menu follow it.
        .environment(\.colorScheme, .dark)
    }
}

/// B3 / B3b: a shell's tab in Terminal, the folder unlit: no chat, a tap opens files; held, Chat is listed but faint.
struct ModeShellTerminalScreen: View {
    var menu = false
    var layout: ModeHeaderLayout = .hostTrailing
    var body: some View {
        let state = ModeButtonState(shown: .terminal, agent: false)
        NavigationStack {
            TerminalMock()
                .safeAreaBar(edge: .bottom) { KeyBar() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ModeTabHeader(title: "dev", subtitle: AnyView(TabSubtitle(shell: "pnpm")), state: state, pressed: menu, layout: layout) }
        }
        .modifier(ModeMenuOverlay(state: menu ? state : nil))
        .environment(\.colorScheme, .dark)
    }
}

/// B4 / B4b: Files shown (from a shell's tab, or held from an agent's), the folder lit; the bottom bar keeps Files ·
/// Review · Commits, the context row keeps the top on its own, and a tap on the folder returns to Terminal.
struct ModeFilesScreen: View {
    var agent = false
    var tab: FilesTabMode = .files
    var body: some View {
        let state = ModeButtonState(shown: .files, agent: agent)
        TabView(selection: .constant(tab)) {
            ForEach(FilesTabMode.allCases) { m in
                Tab(m.title, systemImage: m.symbol, value: m) {
                    NavigationStack {
                        Group { if m == tab { content } else { Color.canvas } }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.canvas)
                            .safeAreaBar(edge: .top, spacing: 0) {
                                if m == tab { context.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10) }
                            }
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ModeTabHeader(title: agent ? "Billing webhook retries" : "Sidebar theme toggle",
                                              subtitle: AnyView(TabSubtitle(folder: agent ? "app" : "web")), state: state)
                            }
                    }
                }
                .badge(m == .review ? 3 : 0)
            }
        }
    }

    @ViewBuilder private var context: some View {
        HStack(spacing: 10) {
            switch tab {
            case .files:
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Breadcrumb(crumbs: ["web", "src"])
                }
                Spacer(minLength: 0)
                BarButton(symbol: "magnifyingglass"); BarButton(symbol: "ellipsis")
            case .review, .commits:
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(MockGit.branch).font(.subheadline.weight(.semibold))
                    Text(tab == .review ? "· 8 files" : "· 148 commits").font(.subheadline).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                BarButton(symbol: "magnifyingglass")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .files:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(MockFiles.src.enumerated()), id: \.element.id) { index, file in
                        FileRow(file: file, last: index == MockFiles.src.count - 1)
                    }
                    Text("9 items").font(.footnote).foregroundStyle(.tertiary).padding(.top, 14)
                }
            }
        case .review:
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
                }
            }
        case .commits:
            ScrollView { CommitGraphList().padding(.top, 4) }
        }
    }
}

/// B5: the four states as the bar draws them (the system toggle, shared with the host).
struct ModeStatesScreen: View {
    var layout: ModeHeaderLayout = .hostTrailing
    private let states: [(String, String, ModeButtonState)] = [
        ("Chat shown", "tap → Terminal", .init(shown: .chat, agent: true)),
        ("Agent, Terminal shown", "tap → Chat", .init(shown: .terminal, agent: true)),
        ("Shell, Terminal shown", "tap → Files", .init(shown: .terminal, agent: false)),
        ("Files shown", "tap → Terminal", .init(shown: .files, agent: false)),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                Text(state.0 + " · " + state.1).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 14).padding(.leading, 20)
                NavigationStack {
                    Color.canvas
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ModeTabHeader(title: "Billing webhook retries", subtitle: AnyView(TabSubtitle(folder: "app")), state: state.2, layout: layout) }
                }
                .frame(height: 62)
            }
            Text("Hold for Terminal · Chat · Files · Review · Commits").font(.footnote).foregroundStyle(.secondary)
                .padding(.top, 18).padding(.leading, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.canvas)
    }
}

/// The ⋯ badge of X9b's menu disc, for a host disc that is the tab's menu.
private struct MenuBadge: View {
    var body: some View {
        Image(systemName: "ellipsis").font(.system(size: 8, weight: .heavy)).foregroundStyle(.primary)
            .frame(width: 17, height: 17)
            .background(Color(uiColor: .systemGray4), in: Circle())
            .overlay { Circle().stroke(Color.canvas, lineWidth: 2) }
            .offset(x: 2, y: 2)
    }
}

/// The system's button-style toggle, its glyph primary when off (the app tint would make every bar glyph pink, and off
/// would differ from on by the selection alone).
struct ModeToggle: View {
    let state: ModeButtonState
    var body: some View {
        Toggle(isOn: .constant(state.lit)) {
            Image(systemName: state.symbol).foregroundStyle(state.lit ? Color.dispatchPink : Color.primary)
        }
        .toggleStyle(.button)
    }
}
