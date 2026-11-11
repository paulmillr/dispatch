import SwiftUI

// iPhone on its side, every point of height to the content (L12–L15, as the app ships it). No header row, no composer
// row, no tab bar: the chrome stands in one rail beside the content, just inside the safe area (the Dynamic Island
// sits mid-height in the side margin the phone turns it to, so nothing goes in the margins). The rail is the tab's:
// Back with the needs-you count and the menu disc at the top, the five modes stacked in the middle, the mode's action
// at its foot (Chat's Reply, Review's Create review, Terminal's keyboard). What the header said (the title, host ·
// folder) moves into the content: the thread's first lines or the list's header.

enum FullHeight {
    /// A rail's width: a 44-point control and its glass inset.
    static let rail: CGFloat = 52
    static let control: CGFloat = 44
}

/// The rail: Back and the menu disc on top, the modes in the middle, the mode's `primary` action at the bottom, where
/// the thumb rests. Above a keyboard (`compact`) only Back and the disc: the modes and the action wait for the
/// keyboard to go.
struct TabRail: View {
    var mode: PadMode
    var count = 2
    var compact = false
    var primary: AnyView
    var body: some View {
        VStack(spacing: 0) {
            BackPill(count: count)
            TabMenuDisc().padding(.top, 8)
            Spacer(minLength: 10)
            if !compact {
            VStack(spacing: 2) {
                ForEach(PadMode.allCases) { m in
                    let on = m == mode
                    Image(symbol: m.symbol).font(.system(size: 16, weight: .medium))
                        .foregroundStyle(on ? Color.dispatchPink : .primary)
                        .frame(width: FullHeight.control - 4, height: 35)
                        .background { if on { Capsule().fill(Color.lens) } }
                        .overlay(alignment: .topTrailing) {
                            if m == .review {
                                Text("3").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).frame(height: 14).background(Color.stateUnread, in: Capsule())
                                    .offset(x: 3, y: 0)
                            }
                        }
                }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
            Spacer(minLength: 10)
            }
            if !compact { primary }
        }
        .frame(width: FullHeight.rail)
        .padding(.vertical, 10)
    }
}

/// The tab's name where the header said it, as a thread's or a list's first lines (scrolls away with them).
struct InlineTitle: View {
    var title = "Sidebar theme toggle"
    var shell: String? = nil
    var centered = true
    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 2) {
            Text(title).font(.headline)
            TabSubtitle(shell: shell)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

/// The full-height frame: the rail and the content, the content from the window's top to its bottom.
struct FullHeightShell<Content: View>: View {
    var mode: PadMode
    var dark = false
    var compact = false
    var primary: AnyView
    /// L15: the window's width too. iOS keeps a 62-point inset on both sides of a phone on its side, for the Dynamic
    /// Island, which is on one side only (the one the phone's top points to). The rail stands on the island's side,
    /// just clear of it (50 points in, against the inset's 62), and the content runs into the other side's inset to
    /// 12 points from the glass, where only the rounded corners are.
    var edgeToEdge = false
    @ViewBuilder var content: Content
    var body: some View {
        if edgeToEdge {
            HStack(spacing: 6) {
                TabRail(mode: mode, compact: compact, primary: primary)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .vertical)
            }
            .padding(.leading, 50)
            .padding(.trailing, 12)
            .ignoresSafeArea(edges: .horizontal)
            .background((dark ? Color.black : Color.canvas).ignoresSafeArea())
        } else {
            HStack(spacing: 6) {
                TabRail(mode: mode, compact: compact, primary: primary)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .vertical)
            }
            .padding(.trailing, 6)
            .background((dark ? Color.black : Color.canvas).ignoresSafeArea())
        }
    }
}

// MARK: - Chat

/// The thread from the window's top to its bottom: the title capsule as the tab opens, the turn's corner in the last
/// bubble.
struct FullHeightThread: View {
    var bottom: CGFloat = 16
    /// The thread's widest: the phone's measure, or none (L15: the bubbles' own 60-point gap is the only limit).
    var measure: CGFloat? = 600
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                // The upright header's title capsule, shown for a moment as the tab opens (`TabTitleChip`).
                TitleCapsuleMock(title: "Sidebar theme toggle").padding(.top, 8).padding(.bottom, 6)
                Bubble(text: "Add a theme toggle to the sidebar and make the unread rows stand out.", user: true)
                BubbleH(text: "Added ThemeToggle in the sidebar footer and a useTheme hook that follows the system preference. Unread rows now carry an unread class on the item.")
                Bubble(text: "Put the class on the link, not the item.", user: true)
                BubbleH(text: "Moving it. I'll also drop the `end` prop since it breaks nested routes.")
                Color.clear.frame(height: bottom)
            }
            .frame(maxWidth: measure ?? .infinity)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

// MARK: - One rail (L12, L13)

/// The mode's action at the rail's foot: a pink 50-point disc, a mark or a count on its corner.
struct PrimaryRailButton: View {
    let symbol: String
    var count: Int? = nil
    var marked = false
    var body: some View {
        Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
            .foregroundStyle(Color.onAccent)
            .frame(width: FullHeight.control + 6, height: FullHeight.control + 6)
            .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Circle())
            .overlay(alignment: .topTrailing) {
                if let count {
                    Text("\(count)").font(.caption2.weight(.bold)).foregroundStyle(Color.dispatchPink)
                        .frame(minWidth: 18, minHeight: 18).background(Color.onAccent, in: Capsule())
                        .offset(x: 3, y: -3)
                } else if marked {
                    Circle().fill(Color.stateUnread).frame(width: 12, height: 12).overlay(Circle().stroke(Color.canvas, lineWidth: 2))
                }
            }
    }
}

/// L12: Chat on one rail. Reply is the rail's foot (attach and the send options in the menu disc, dictation on the
/// keyboard's own mic); the thread has the window's full height and everything right of the rail.
struct OneRailChatScreen: View {
    var draft = false
    var edgeToEdge = false
    var body: some View {
        FullHeightShell(mode: .chat, primary: AnyView(PrimaryRailButton(symbol: draft ? "text.bubble.fill" : "arrowshape.turn.up.left.fill", marked: draft)),
                        edgeToEdge: edgeToEdge) {
            FullHeightThread(measure: edgeToEdge ? nil : 600)
        }
    }
}

/// L12b: writing on one rail: the field alone (text and Send) over the thread's bottom, the rail down to Back and the
/// disc above the keyboard.
struct OneRailChatTypingScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            FullHeightShell(mode: .chat, compact: true, primary: AnyView(PrimaryRailButton(symbol: "arrowshape.turn.up.left.fill"))) {
                FullHeightThread(bottom: 6)
                    .safeAreaBar(edge: .bottom) {
                        HStack {
                            Text("Also keep the hover state on the link").lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(Color.onAccent)
                                .frame(width: 30, height: 30).background(Color.dispatchPink, in: Circle())
                        }
                        .padding(.leading, 14).padding(.trailing, 4).frame(height: 38)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .frame(maxWidth: 600).frame(maxWidth: .infinity)
                        .padding(.horizontal, 8).padding(.bottom, 4)
                    }
            }
            LandscapeKeyboard().ignoresSafeArea()
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// L13: Review on one rail: Create review is the rail's foot with the comment count; search heads the list, Comment
/// the diff's pane.
struct OneRailReviewScreen: View {
    var body: some View {
        FullHeightShell(mode: .review, primary: AnyView(PrimaryRailButton(symbol: "paperplane.fill", count: 3))) {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                InlineTitle(centered: false)
                                HStack(spacing: 4) {
                                    Text(MockGit.branch).font(.subheadline.weight(.semibold))
                                    Counts(add: MockGit.additions, del: MockGit.deletions, font: .system(.caption, design: .monospaced))
                                }
                            }
                            Spacer(minLength: 4)
                            BarButton(symbol: "magnifyingglass")
                        }
                        .padding(.leading, 12).padding(.trailing, 4).padding(.top, 14)
                        ForEach([MockChange.Area.staged, .unstaged, .untracked], id: \.rawValue) { area in
                            let rows = MockGit.changes.filter { $0.area == area }
                            SectionHeader(title: area.rawValue, count: rows.count).padding(.leading, -4)
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, change in
                                    ChangeRow(change: change, last: index == rows.count - 1, selected: change.name == "Sidebar.tsx")
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Color.clear.frame(height: 20)
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .all)
                .frame(width: 290)
                Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5)
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text("Sidebar.tsx").font(.headline)
                        Text("M").font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(Color.caution)
                        Counts(add: 14, del: 6, font: .system(.caption, design: .monospaced))
                        Spacer()
                        BarButton(symbol: "plus.bubble", tinted: true)
                    }
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                    GlassDiffScreen(mode: .comments).pane(bottomBar: false, cardWidth: 420)
                }
            }
        }
    }
}

// MARK: - Terminal on one rail (L14)

/// The terminal's keys as one slim row riding the keyboard, the arrows inline.
struct KeyboardKeyRow: View {
    var body: some View {
        HStack(spacing: 0) {
            ForEach(["Ctrl", "Esc", "Tab", "Alt", "|", "~", "/"], id: \.self) { k in
                Text(k).font(.system(size: 15, design: .monospaced)).frame(maxWidth: .infinity)
            }
            ForEach(["arrow.left", "arrow.up", "arrow.down", "arrow.right"], id: \.self) { symbol in
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity)
            }
            Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 15)).foregroundStyle(Color.dispatchPink)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 34)
        .glassEffect(.regular, in: Capsule())
    }
}

/// The keys the keyboard button holds (L14c): what a stopped program or a prompt needs without typing.
struct TerminalKeysMenu: View {
    private let rows: [(String, String, String?)] = [
        ("Esc", "escape", nil), ("Ctrl-C", "xmark.octagon", "interrupt"), ("Ctrl-D", "eject", "end of input"),
        ("Tab", "arrow.right.to.line", nil), ("Previous command", "arrow.up", nil), ("Paste", "doc.on.clipboard", nil),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i == 4 { Divider().padding(.vertical, 3) }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.0).font(.body)
                        if let note = row.2 { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Image(systemName: row.1).font(.body)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 250)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// L14: the terminal on one rail: the window's full height and everything right of the rail. The keyboard is the
/// rail's foot: a tap raises it with the key row riding it (L14b), held it offers the keys a program at rest needs
/// (L14c). Esc without the keyboard is two taps, not one.
struct OneRailTerminalScreen: View {
    var menu = false
    var edgeToEdge = false
    var body: some View {
        FullHeightShell(mode: .terminal, dark: true, primary: AnyView(PrimaryRailButton(symbol: "keyboard")), edgeToEdge: edgeToEdge) {
            WideTerminal(lines: oneRailTerminalLines)
                .padding(.bottom, 8)
                .overlay(alignment: .bottomLeading) {
                    if menu { TerminalKeysMenu().padding(.leading, 4).padding(.bottom, 14) }
                }
        }
        .colorScheme(.dark)
    }
}

/// L14b: typing: the rail down to Back and the disc, the key row on the keyboard, the rows above it.
struct OneRailTerminalTypingScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            FullHeightShell(mode: .terminal, dark: true, compact: true, primary: AnyView(PrimaryRailButton(symbol: "keyboard"))) {
                WideTerminal(lines: Array(oneRailTerminalLines.suffix(8)))
            }
            KeyboardKeyRow().padding(.horizontal, 8).padding(.bottom, 4).background(Color.black)
            LandscapeKeyboard().ignoresSafeArea()
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .colorScheme(.dark)
    }
}

private let oneRailTerminalLines: [String] = [
    "~/src/web $ git status --short",
    " M src/components/Sidebar.tsx",
    " M src/styles/tokens.css",
    "?? tests/theme.test.ts",
    "~/src/web $ pnpm test --filter web -- --reporter=dot",
    "",
    " RUN  v3.2.4 /Users/alex/src/web",
    "",
    " ✓ src/theme.test.ts (12 tests) 38ms",
    " ✓ src/components/Sidebar.test.tsx (9 tests) 211ms",
    " ✓ src/components/ThemeToggle.test.tsx (6 tests) 96ms",
    " ✗ src/routes/settings.test.tsx > Settings > keeps the theme across a reload (light → dark after reload)",
    "   AssertionError: expected 'light' to be 'dark' // Object.is equality",
    "    ❯ src/routes/settings.test.tsx:48:31",
    "",
    " Test Files  1 failed | 23 passed (24)",
    "      Tests  1 failed | 187 passed (188)",
    "   Duration  4.12s (transform 612ms, setup 0ms, collect 2.31s, tests 1.48s, environment 0ms, prepare 88ms)",
    "",
    "~/src/web $ ▯",
]
