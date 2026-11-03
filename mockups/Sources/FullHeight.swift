import SwiftUI

// iPhone on its side, every point of height to the content (L9–L13). No header row, no composer row, no tab bar: the
// chrome stands in two rails beside the content, just inside the safe area (the Dynamic Island sits mid-height in the
// side margin the phone turns it to, so nothing goes in the margins). The leading rail is the tab's: Back with the
// needs-you count at the top, the five modes stacked in the middle, the menu disc at the bottom. The trailing rail is
// the mode's: Chat's composer while empty is a button there, Terminal's keys, Review's Create review. What the header
// said (the title, host · folder) moves into the content: the thread's first lines, the list's header, or a chip that
// shows for a moment as the tab opens and on a tap of the menu disc's rail.

enum FullHeight {
    /// A rail's width: a 44-point control and its glass inset.
    static let rail: CGFloat = 52
    static let control: CGFloat = 44
}

/// The leading rail: Back on top, the modes in the middle, the menu disc at the bottom. Above a keyboard (`compact`)
/// only Back and the disc: the modes wait for the keyboard to go. With the mode's `primary` action (L12, L13: Reply,
/// Create review) the disc goes up under Back and the action takes the bottom, where the thumb rests, and the
/// trailing rail is gone.
struct TabRail: View {
    var mode: PadMode
    var count = 2
    var compact = false
    var primary: AnyView? = nil
    var body: some View {
        VStack(spacing: 0) {
            BackPill(count: count)
            if primary != nil {
                TabMenuDisc().padding(.top, 8)
            }
            Spacer(minLength: 10)
            if !compact {
            VStack(spacing: 2) {
                ForEach(PadMode.allCases) { m in
                    let on = m == mode
                    Image(systemName: m.symbol).font(.system(size: 16, weight: .medium))
                        .foregroundStyle(on ? Color.dispatchPink : .primary)
                        .frame(width: FullHeight.control - 4, height: primary == nil ? 38 : 35)
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
            if let primary {
                if !compact { primary }
            } else {
                TabMenuDisc()
            }
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

/// The tab's name in a glass chip at the content's top, for a moment as the tab opens (and while the menu disc is
/// held): the terminal has no first line of its own to carry it.
struct TitleChip: View {
    var title = "dev"
    var shell: String? = "pnpm"
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            TabSubtitle(shell: shell)
        }
        .padding(.horizontal, 14).frame(height: 32)
        .glassEffect(.regular, in: Capsule())
    }
}

/// The full-height frame: leading rail, content, trailing rail, the content from the window's top to its bottom.
struct FullHeightShell<Content: View, Trailing: View>: View {
    var mode: PadMode
    var dark = false
    var compact = false
    var primary: AnyView? = nil
    /// L15: the window's width too. iOS keeps a 62-point inset on both sides of a phone on its side, for the Dynamic
    /// Island, which is on one side only (the one the phone's top points to). The rail stands on the island's side,
    /// just clear of it (50 points in, against the inset's 62), and the content runs into the other side's inset to
    /// 12 points from the glass, where only the rounded corners are.
    var edgeToEdge = false
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing
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
                trailing
            }
            .background((dark ? Color.black : Color.canvas).ignoresSafeArea())
        }
    }
}

// MARK: - Chat

/// The thread from the window's top to its bottom: the title its first lines, the turn's corner in the last bubble.
struct FullHeightThread: View {
    var bottom: CGFloat = 16
    /// The thread's widest: the phone's measure, or none (L15: the bubbles' own 60-point gap is the only limit).
    var measure: CGFloat? = 600
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                InlineTitle().padding(.top, 14).padding(.bottom, 6)
                Bubble(text: "Add a theme toggle to the sidebar and make the unread rows stand out.", user: true)
                MetaBubble(text: "Added ThemeToggle in the sidebar footer and a useTheme hook that follows the system preference. Unread rows now carry an unread class on the item.",
                           summary: "4 files +61 −9 · 10:17")
                Bubble(text: "Put the class on the link, not the item.", user: true)
                MetaBubble(text: "Moving it. I'll also drop the `end` prop since it breaks nested routes.",
                           summary: "Editing Sidebar.tsx · 48s", working: true)
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

/// Chat's rail: the composer while empty is a pink button at the bottom (a tap brings the field and the keyboard),
/// dictation above it, "+" (attach, the send options) above that; Jump to latest takes the top when the thread is
/// scrolled up.
struct ChatRail: View {
    var draft = false
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "plus").font(.body.weight(.semibold))
                .frame(width: FullHeight.control, height: FullHeight.control)
                .glassEffect(.regular.interactive(), in: Circle())
            Image(systemName: "mic").font(.body.weight(.medium))
                .frame(width: FullHeight.control, height: FullHeight.control)
                .glassEffect(.regular.interactive(), in: Circle())
            Image(systemName: draft ? "text.bubble.fill" : "square.and.pencil").font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.onAccent)
                .frame(width: FullHeight.control + 6, height: FullHeight.control + 6)
                .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Circle())
                .overlay(alignment: .topTrailing) {
                    // A draft kept while the keyboard is down: its first words on hold.
                    if draft { Circle().fill(Color.stateUnread).frame(width: 12, height: 12).overlay(Circle().stroke(Color.canvas, lineWidth: 2)) }
                }
        }
        .frame(width: FullHeight.rail)
        .padding(.vertical, 10)
    }
}

/// L9: Chat with 100% of the height: no header, no composer row.
struct FullHeightChatScreen: View {
    var body: some View {
        FullHeightShell(mode: .chat) {
            FullHeightThread()
        } trailing: {
            ChatRail()
        }
    }
}

/// L9b: writing. The button opened the field over the thread's bottom, above the keyboard; the rails stay, their lower
/// half under the keyboard. Send is the field's own arrow; dismissing the keyboard with words left turns the field back
/// into the button, marked (L9c).
struct FullHeightChatTypingScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            FullHeightShell(mode: .chat, compact: true) {
                FullHeightThread(bottom: 6)
                    .safeAreaBar(edge: .bottom) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus").font(.body.weight(.semibold))
                                .frame(width: 38, height: 38).glassEffect(.regular.interactive(), in: Circle())
                            HStack {
                                Text("Also keep the hover state on the link").lineLimit(1)
                                Spacer()
                                Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(Color.onAccent)
                                    .frame(width: 30, height: 30).background(Color.dispatchPink, in: Circle())
                            }
                            .padding(.leading, 14).padding(.trailing, 4).frame(height: 38)
                            .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .frame(maxWidth: 600).frame(maxWidth: .infinity)
                        .padding(.horizontal, 8).padding(.bottom, 4)
                    }
            } trailing: {
                Color.clear.frame(width: FullHeight.rail)
            }
            LandscapeKeyboard().ignoresSafeArea()
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// L9c: the keyboard down with a draft: the button is marked, the thread keeps the full height.
struct FullHeightChatDraftScreen: View {
    var body: some View {
        FullHeightShell(mode: .chat) {
            FullHeightThread()
        } trailing: {
            ChatRail(draft: true)
        }
    }
}

// MARK: - Terminal

private let fullTerminalLines: [String] = [
    "~/src/web $ git status --short",
    " M src/components/Sidebar.tsx",
    " M src/styles/tokens.css",
    "?? tests/theme.test.ts",
] + [
    "~/src/web $ pnpm test --filter web -- --reporter=dot",
    "",
    " RUN  v3.2.4 /Users/alex/src/web",
    "",
    " ✓ src/theme.test.ts (12 tests) 38ms",
    " ✓ src/components/Sidebar.test.tsx (9 tests) 211ms",
    " ✓ src/components/ThemeToggle.test.tsx (6 tests) 96ms",
    " ✗ src/routes/settings.test.tsx > Settings > keeps the theme across a reload",
    "   AssertionError: expected 'light' to be 'dark' // Object.is equality",
    "    ❯ src/routes/settings.test.tsx:48:31",
    "",
    " Test Files  1 failed | 23 passed (24)",
    "      Tests  1 failed | 187 passed (188)",
    "   Duration  4.12s (transform 612ms, setup 0ms, collect 2.31s, tests 1.48s)",
    "",
    "~/src/web $ ▯",
]

/// L10: the terminal from the window's top to its bottom (20 rows of 80 columns, against 16 under L1's header and 10
/// in today's landscape); the keys are the trailing rail.
struct FullHeightTerminalScreen: View {
    var chip = false
    var body: some View {
        FullHeightShell(mode: .terminal, dark: true) {
            WideTerminal(lines: fullTerminalLines)
                .padding(.bottom, 8)
                .overlay(alignment: .top) { if chip { TitleChip().padding(.top, 10) } }
        } trailing: {
            KeyRail().padding(.vertical, 10)
        }
        .colorScheme(.dark)
    }
}

// MARK: - Review

/// L11: Review's list and diff both full height. The context row (branch, counts) is the list's first lines; Create
/// review is the trailing rail's pink button with the comment count, search above it.
struct FullHeightReviewScreen: View {
    var body: some View {
        FullHeightShell(mode: .review) {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            InlineTitle(centered: false)
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(MockGit.branch).font(.subheadline.weight(.semibold))
                                Counts(add: MockGit.additions, del: MockGit.deletions, font: .system(.caption, design: .monospaced))
                            }
                        }
                        .padding(.horizontal, 12).padding(.top, 14)
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
                .frame(width: 280)
                Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5)
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text("Sidebar.tsx").font(.headline)
                        Text("M").font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(Color.caution)
                        Counts(add: 14, del: 6, font: .system(.caption, design: .monospaced))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                    GlassDiffScreen(mode: .comments).pane(bottomBar: false, cardWidth: 380)
                }
            }
        } trailing: {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.body.weight(.semibold))
                    .frame(width: FullHeight.control, height: FullHeight.control)
                    .glassEffect(.regular.interactive(), in: Circle())
                Image(systemName: "plus.bubble").font(.body.weight(.semibold))
                    .frame(width: FullHeight.control, height: FullHeight.control)
                    .glassEffect(.regular.interactive(), in: Circle())
                Spacer()
                Image(systemName: "paperplane.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.onAccent)
                    .frame(width: FullHeight.control + 6, height: FullHeight.control + 6)
                    .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        Text("3").font(.caption2.weight(.bold)).foregroundStyle(Color.dispatchPink)
                            .frame(minWidth: 18, minHeight: 18).background(Color.onAccent, in: Capsule())
                            .offset(x: 3, y: -3)
                    }
            }
            .frame(width: FullHeight.rail)
            .padding(.vertical, 10)
        }
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
        } trailing: {
            Color.clear.frame(width: 0)
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
            } trailing: {
                Color.clear.frame(width: 0)
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
                                    Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
        } trailing: {
            Color.clear.frame(width: 0)
        }
    }
}

// MARK: - Terminal on one rail (L14)

/// The terminal's keys as one slim row riding the keyboard (L2's), the arrows inline.
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

/// L14: the terminal on one rail: the window's full height and everything right of the rail (22 columns more than
/// L10's). The keyboard is the rail's foot: a tap raises it with the key row riding it (L14b), held it offers the keys
/// a program at rest needs (L14c). Esc without the keyboard is two taps, not one.
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
        } trailing: {
            Color.clear.frame(width: 0)
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
            } trailing: {
                Color.clear.frame(width: 0)
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
