import SwiftUI

// iPhone on its side (874 × 402 points on an iPhone 18 Pro, 956 × 440 on a Pro Max): height is the scarce axis, so
// every bar folds into one row at the top, the key bar turns into a rail down the trailing edge, and the width the
// portrait stack cannot use goes to a second column (list beside pane, chat beside diff, tree beside tab). Shot on an
// iPhone simulator turned by `shoot.py rotate landscape`.

enum LandscapeMock {
    /// The bar row's controls: 38 points, against 44 upright.
    static let control: CGFloat = 38
    /// The list column of the list-and-pane screens: a portrait row's width less its margins.
    static let list: CGFloat = 300
    /// The chat's measure at full width: the iPhone Air's column, so a line reads as on the phone.
    static let measure: CGFloat = 560
}

/// One row for the whole tab chrome: back pill, title with host · path beside it, the five modes as glyphs (Files,
/// Review and Commits join Terminal and Chat, so the bottom tab bar goes), the host disc. 46 points where the
/// portrait header, capsule and context row take 116.
struct LandscapeBar<Leading: View>: View {
    var title = "Sidebar theme toggle"
    var path = "~/src/web"
    var mode: PadMode = .chat
    /// A second mode open beside the first (L4).
    var also: PadMode? = nil
    @ViewBuilder var leading: Leading
    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                HostPath(path: path)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            LandscapeModes(mode: mode, also: also)
            Image(systemName: "apple.logo").font(.system(size: 18)).foregroundStyle(hostTint)
                .frame(width: LandscapeMock.control, height: LandscapeMock.control)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 4)
    }
}

extension LandscapeBar where Leading == BackPillCompact {
    init(title: String = "Sidebar theme toggle", path: String = "~/src/web", mode: PadMode = .chat, also: PadMode? = nil) {
        self.init(title: title, path: path, mode: mode, also: also) { BackPillCompact() }
    }
}

/// The back pill at the bar row's height.
struct BackPillCompact: View {
    var count = 2
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.dispatchPink)
            Text("\(count)").font(.caption.weight(.bold)).foregroundStyle(Color.onAccent)
                .frame(width: 22, height: 22).background(Color.dispatchPink, in: Circle())
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: LandscapeMock.control)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// Terminal · Chat · Files · Review · Commits as glyphs in one capsule, the selected one in the lens, Review's count.
struct LandscapeModes: View {
    var mode: PadMode
    var also: PadMode? = nil
    var reviewBadge: Int? = 3
    var body: some View {
        HStack(spacing: 2) {
            ForEach(PadMode.allCases) { m in
                let on = m == mode || m == also
                Image(systemName: m.symbol).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(on ? Color.dispatchPink : .primary)
                    .frame(width: 42, height: LandscapeMock.control - 6)
                    .background { if on { Capsule().fill(Color.lens) } }
                    .overlay(alignment: .topTrailing) {
                        if m == .review, let reviewBadge {
                            Text("\(reviewBadge)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).frame(height: 14).background(Color.stateUnread, in: Capsule())
                                .offset(x: 2, y: -2)
                        }
                    }
                    .accessibilityLabel(m.title)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
    }
}

// MARK: - Terminal

/// A terminal at landscape's 88 columns: a test run whose lines wrapped at 44 upright.
private let wideLines: [String] = [
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

struct WideTerminal: View {
    var lines: [String] = wideLines
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(color(line))
                    .lineLimit(1)
                    .frame(height: 20)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
    private func color(_ line: String) -> Color {
        if line.hasPrefix("~") { return .added }
        if line.contains("✗") || line.contains("AssertionError") || line.contains("failed") { return .destructive }
        if line.contains("✓") { return .added.opacity(0.85) }
        if line.contains("❯") { return .secondary }
        return .primary
    }
}

/// The key bar as a rail down the trailing edge: rows are what landscape lacks, columns it has spare.
struct KeyRail: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(["Ctrl", "Esc", "Tab", "Alt"], id: \.self) { k in
                Text(k).font(.system(size: 14, design: .monospaced)).frame(maxHeight: .infinity)
            }
            Image(systemName: "dpad").font(.system(size: 18)).frame(maxHeight: .infinity)
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).frame(maxHeight: .infinity)
            Image(systemName: "keyboard").font(.system(size: 16)).foregroundStyle(Color.dispatchPink).frame(maxHeight: .infinity)
        }
        .frame(width: 50)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
    }
}

/// L1: the one-row bar over the terminal, the keys as a rail. 16 rows of 88 columns, against 10 of 44 upright and
/// 10 of 44 in today's landscape (the key capsule along the bottom, the capsule and header along the top).
struct LandscapeTerminalScreen: View {
    var body: some View {
        HStack(spacing: 8) {
            WideTerminal()
            KeyRail().padding(.bottom, 4)
        }
        .background(Color.black)
        .safeAreaBar(edge: .top, spacing: 0) {
            LandscapeBar(title: "dev", path: "~/src/web · pnpm", mode: .terminal)
        }
        .colorScheme(.dark)
    }
}

/// A software keyboard as the system draws it on its side, for scale (the simulator shows none over a mockup).
struct LandscapeKeyboard: View {
    private let rows: [[String]] = [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
                                    ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
                                    ["⇧", "z", "x", "c", "v", "b", "n", "m", "⌫"]]
    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                HStack(spacing: 6) {
                    if r == 1 { Spacer().frame(width: 22) }
                    ForEach(row, id: \.self) { key in
                        Text(key).font(.system(size: 20))
                            .frame(maxWidth: key == "⇧" || key == "⌫" ? 70 : .infinity).frame(height: 36)
                            .background(Color.white.opacity(key == "⇧" || key == "⌫" ? 0.12 : 0.28), in: RoundedRectangle(cornerRadius: 7))
                    }
                    if r == 1 { Spacer().frame(width: 22) }
                }
            }
            HStack(spacing: 6) {
                Text("123").font(.system(size: 16)).frame(width: 90, height: 36).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                Image(systemName: "face.smiling").frame(width: 60, height: 36).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                Text("space").font(.system(size: 16)).frame(maxWidth: .infinity).frame(height: 36).background(Color.white.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                Text("return").font(.system(size: 16)).frame(width: 120, height: 36).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 70).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.17))
    }
}

/// L2: typing on its side. The bar row goes (a glass chip with the title stays, a tap brings the row back) and the
/// keys ride on the keyboard as one slim row with the arrows inline. 7 rows stay above the keyboard; today about one
/// does: the header and capsule (116 points) and the key capsule (58) leave ~30 of the 230 the keyboard spares.
struct LandscapeTerminalKeyboardScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            WideTerminal(lines: Array(wideLines.suffix(8)))
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.caption.weight(.bold)).foregroundStyle(Color.dispatchPink)
                        Text("dev").font(.caption.weight(.semibold))
                        Text("mba2").font(.caption).foregroundStyle(hostTint)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .padding(.top, 4).padding(.trailing, 4)
                }
            HStack(spacing: 0) {
                ForEach(["Ctrl", "Esc", "Tab", "Alt", "|", "~", "/"], id: \.self) { k in
                    Text(k).font(.system(size: 15, design: .monospaced)).frame(maxWidth: .infinity)
                }
                ForEach(["arrow.left", "arrow.up", "arrow.down", "arrow.right"], id: \.self) { s in
                    Image(systemName: s).font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity)
                }
                Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 15)).foregroundStyle(Color.dispatchPink).frame(maxWidth: .infinity)
            }
            .frame(height: 34)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 8).padding(.bottom, 4)
            LandscapeKeyboard().ignoresSafeArea()
        }
        .background(Color.black)
        .colorScheme(.dark)
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

// MARK: - Chat

/// The thread at a measure: bubbles keep the phone's line length instead of running 750 points.
struct LandscapeThread: View {
    var measure: CGFloat = LandscapeMock.measure
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Spacer(minLength: 60)
                Bubble(text: "Add a theme toggle to the sidebar and make the unread rows stand out.", user: true)
                MetaBubble(text: "Added ThemeToggle in the sidebar footer and a useTheme hook that follows the system preference. Unread rows now carry an unread class on the item.",
                           summary: "4 files +61 −9 · 10:17")
                Bubble(text: "Put the class on the link, not the item.", user: true)
                MetaBubble(text: "Moving it. I'll also drop the `end` prop since it breaks nested routes.", summary: nil, working: true)
                Color.clear.frame(height: 4)
            }
            .frame(maxWidth: measure)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .bottom) {
            LandscapeComposer().frame(maxWidth: measure).frame(maxWidth: .infinity).padding(.horizontal, 12)
        }
    }
}

struct LandscapeComposer: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: LandscapeMock.control, height: LandscapeMock.control)
                .glassEffect(.regular.interactive(), in: Circle())
            HStack {
                Text("Message").foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "mic").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).frame(height: LandscapeMock.control)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .padding(.bottom, 2)
    }
}

/// L3: the thread under the one-row bar, at the phone's measure.
struct LandscapeChatScreen: View {
    var body: some View {
        LandscapeThread()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .safeAreaBar(edge: .top, spacing: 0) { LandscapeBar(mode: .chat) }
    }
}

/// L4: Chat beside Review, each at a phone's width: read the diff the agent is writing and answer it in one view.
/// A long-press on a second mode opens it beside the first (both lit in the capsule); the split's handle drags.
struct LandscapeChatReviewScreen: View {
    var body: some View {
        HStack(spacing: 0) {
            LandscapeThread(measure: 400)
                .frame(width: 380)
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5)
                .overlay { Capsule().fill(Color.secondary.opacity(0.6)).frame(width: 4, height: 36) }
            VStack(spacing: 0) {
                PaneHeader(title: "Sidebar.tsx") {
                    HStack(spacing: 6) {
                        Text("M").font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(Color.caution)
                        Counts(add: 14, del: 6, font: .system(.caption, design: .monospaced))
                        Text("· 2 of 8").foregroundStyle(.secondary)
                    }
                } trailing: {
                    HStack(spacing: 0) {
                        Image(systemName: "chevron.up").frame(width: 32, height: 32)
                        Image(systemName: "chevron.down").frame(width: 32, height: 32)
                    }
                    .font(.caption.weight(.bold))
                    .glassEffect(.regular.interactive(), in: Capsule())
                    BarButton(symbol: "plus.bubble", tinted: true)
                }
                .padding(.top, 2)
                GlassDiffScreen(mode: .comments).pane(bottomBar: false, cardWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .safeAreaBar(edge: .top, spacing: 0) { LandscapeBar(mode: .chat, also: .review) }
    }
}

// MARK: - Review and Commits

/// L5: Review as the iPad lays it out: the change list beside the diff, Create review in the context row instead of
/// the floating accessory, no bottom tab bar (the modes are in the bar row).
struct LandscapeReviewScreen: View {
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(MockGit.branch).font(.subheadline.weight(.semibold))
                    Counts(add: MockGit.additions, del: MockGit.deletions, font: .system(.caption, design: .monospaced))
                    Spacer(minLength: 4)
                }
                .lineLimit(1)
                .padding(.horizontal, 16).padding(.bottom, 4)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach([MockChange.Area.staged, .unstaged, .untracked], id: \.rawValue) { area in
                            let rows = MockGit.changes.filter { $0.area == area }
                            SectionHeader(title: area.rawValue, count: rows.count).padding(.top, -8)
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, change in
                                    ChangeRow(change: change, last: index == rows.count - 1, selected: change.name == "Sidebar.tsx")
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 8)
                        }
                        Color.clear.frame(height: 56)
                    }
                }
                .safeAreaBar(edge: .bottom) {
                    CreateReviewPill().padding(.bottom, 2)
                }
            }
            .frame(width: LandscapeMock.list)
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5)
            VStack(spacing: 0) {
                PaneHeader(title: "Sidebar.tsx") {
                    HStack(spacing: 6) {
                        Text("src/components").font(.system(.caption, design: .monospaced))
                        Text("M").font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(Color.caution)
                        Counts(add: 14, del: 6, font: .system(.caption, design: .monospaced))
                    }
                } trailing: {
                    BarButton(symbol: "plus.bubble", tinted: true)
                    BarButton(symbol: "ellipsis")
                }
                GlassDiffScreen(mode: .comments).pane(bottomBar: false, cardWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .safeAreaBar(edge: .top, spacing: 0) { LandscapeBar(mode: .review) }
    }
}

/// L6: the log beside the commit.
struct LandscapeCommitsScreen: View {
    let commit = MockGit.commits[0]
    var body: some View {
        HStack(spacing: 0) {
            ScrollView { CommitGraphList(selected: 1).padding(.top, 2) }
                .frame(width: LandscapeMock.list + 40)
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5)
            VStack(spacing: 0) {
                PaneHeader(title: commit.hash) {
                    Text("\(commit.age) ago · \(commit.author)")
                } trailing: {
                    BarButton(symbol: "ellipsis")
                }
                CommitDetailBody(commit: commit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .safeAreaBar(edge: .top, spacing: 0) { LandscapeBar(mode: .commits) }
    }
}

// MARK: - Spaces and Agents

/// L7: the tree beside the open tab, as on the unfolded Duo and the iPad, at a phone's sizes: a 280-point tree and a
/// 470-point tab (wider than an upright iPhone Air). Back becomes the sidebar toggle.
struct LandscapeSpacesSplitScreen: View {
    var body: some View {
        HStack(spacing: 0) {
            SpacesRootScreen(selected: "app", compactFilters: true, barFilter: 2)
                .frame(width: 280)
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5).ignoresSafeArea()
            LandscapeThread(measure: 460)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .safeAreaBar(edge: .top, spacing: 0) {
                    // The host disc stays with the tree's host header; the modes keep the row.
                    HStack(spacing: 10) {
                        Image(systemName: "sidebar.left").font(.system(size: 16, weight: .medium))
                            .frame(width: LandscapeMock.control, height: LandscapeMock.control)
                            .glassEffect(.regular.interactive(), in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Sidebar theme toggle").font(.subheadline.weight(.semibold)).lineLimit(1)
                            HostPath(path: "~/src/web")
                        }
                        Spacer(minLength: 6)
                        LandscapeModes(mode: .chat)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 4)
                }
        }
        .background(Color.canvas)
    }
}

private struct AgentCardData: Identifiable {
    let title: String
    let kind: String
    let place: String
    let line: String
    let time: String
    var dot: Color? = nil
    var approval = false
    var id: String { title }
}

private let agentCards: [AgentCardData] = [
    .init(title: "Rate limiter for the API", kind: "codex", place: "studio · billing", line: "Allow cargo test --workspace?",
          time: "2m", dot: .stateUnread, approval: true),
    .init(title: "Sidebar theme toggle", kind: "claude", place: "mba2 · app", line: "Editing Sidebar.tsx · 48s", time: "now", dot: .stateWorking),
    .init(title: "Invoice retries", kind: "claude", place: "studio · billing", line: "Keyed the guard on the event id; 2 files +4 −4.",
          time: "12m", dot: .stateConnected),
    .init(title: "Flaky settings test", kind: "pi", place: "mba2 · e2e", line: "Running pnpm test settings · 1m 02s", time: "now", dot: .stateWorking),
    .init(title: "Docs site migration", kind: "claude", place: "studio · docs", line: "Moved the docs to Starlight; the old MkDocs config is gone.", time: "1h"),
    .init(title: "Release notes 0.4", kind: "codex", place: "mba2 · app", line: "Drafted the notes from 31 commits.", time: "3h"),
]

/// L8: Agents as a board: three columns of cards, the waiting ones first with their buttons on the card, so a phone
/// propped on its side watches every agent at once and answers without opening a thread.
struct LandscapeAgentsBoardScreen: View {
    var body: some View {
        TabView(selection: .constant(1)) {
            Tab("Spaces", systemImage: "square.on.square", value: 0) { Color.canvas }
            Tab("Agents", systemImage: "text.bubble", value: 1) {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 10) {
                        ForEach(agentCards) { card($0) }
                    }
                    .padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 60)
                }
                .background(Color.canvas)
                .safeAreaBar(edge: .top, spacing: 0) {
                    HStack(spacing: 10) {
                        Text("Agents").font(.title3.weight(.bold))
                        FilterDiscs(selected: 0, spacing: 6).scaleEffect(0.85, anchor: .leading)
                        Spacer()
                        Image(systemName: "plus").font(.body.weight(.semibold))
                            .frame(width: LandscapeMock.control, height: LandscapeMock.control)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .padding(.horizontal, 4).padding(.vertical, 4)
                }
            }
        }
    }

    private func card(_ c: AgentCardData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentGlyph(kind: c.kind).scaleEffect(0.85).frame(width: 22)
                Text(c.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let dot = c.dot { Circle().fill(dot).frame(width: 8, height: 8) }
            }
            HStack(spacing: 0) {
                Text(c.place).foregroundStyle(hostTint)
                Text(" · \(c.time)").foregroundStyle(.tertiary)
            }
            .font(.caption).lineLimit(1)
            Text(c.line).font(.footnote).foregroundStyle(c.approval ? .primary : .secondary)
                .lineLimit(2, reservesSpace: true)
            if c.approval {
                HStack(spacing: 6) {
                    Text("Allow").font(.footnote.weight(.semibold)).foregroundStyle(Color.onAccent)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(Color.dispatchPink, in: Capsule())
                    Text("Deny").font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(Color.chipFill, in: Capsule())
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            if c.approval { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.stateUnread.opacity(0.6), lineWidth: 1) }
        }
    }
}
