import SwiftUI

// Exploration: Claude's subscription limits in the popover the composer's activity ("thinking") already opens
// (ChatComposerActivity). Nothing is read until that click: Claude Code hands `rate_limits` only to its status line
// command, so opening the popover sets one for a moment, takes one reading and puts the setting back. A reading is
// kept in memory for a minute, per host and Claude config folder: a popover opened within it reads nothing.

enum ClaudeLimits {
    static let screens: [Screen] = [
        Screen("D1-limits", group: "limits", "Limits in the activity popover, opened by clicking thinking") {
            inWindow(Card(look: .rows, state: .shown(usual), arrow: 171))
        },
        Screen("D2-limits-looks", group: "limits", "Three ways to draw the two windows") {
            board {
                HStack(alignment: .top, spacing: 32) {
                    tile("A · Rows", "Each window on its own line, with when it resets.") { Card(look: .rows, state: .shown(usual)) }
                    tile("B · One line", "The context meter's language; the smallest change to the popover.") { Card(look: .line, state: .shown(usual)) }
                    tile("C · Rings", "Reads at a glance; takes the most room.") { Card(look: .rings, state: .shown(usual)) }
                }
            }
        },
        Screen("D3-limits-states", group: "limits", "The first click, reading, near the limit, and when there is nothing to show") {
            board {
                HStack(alignment: .top, spacing: 32) {
                    tile("Before consent", "Show Limits once; from then on every popover has them.") { Card(look: .rows, state: .consent) }
                    tile("Reading", "A popover opened with no reading from the last minute.") { Card(look: .rows, state: .reading) }
                    tile("Opened again within a minute", "The last reading, from memory. Claude Code isn't asked.") { Card(look: .rows, state: .shown(usual), read: "read 40s ago") }
                    tile("Near the limit", "Yellow from 80%, red from 95%.") { Card(look: .rows, state: .shown(near)) }
                }
                HStack(alignment: .top, spacing: 32) {
                    tile("One window reported", "Only what Claude Code reports gets a row; a missing window is never 0%.") { Card(look: .rows, state: .shown(weekOnly)) }
                    tile("No limits to report", "An API key or a cloud provider. Never drawn as 0%.") { Card(look: .rows, state: .none) }
                    tile("Claude Code didn't answer", "Its status line didn't run, or another setting overrides it.") { Card(look: .rows, state: .failed) }
                }
            }
        },
        Screen("D4-limits-plugins", group: "limits", "Limits from a Pi extension the user installed: OpenCode Go and OpenRouter") {
            board {
                HStack(alignment: .top, spacing: 32) {
                    tile("Before consent", "Names the extension. Dispatch itself contacts nobody.") {
                        Card(look: .rows, state: .pluginConsent("opencode-go-limits", "OpenCode"))
                    }
                    tile("OpenCode Go", "Real windows: the same rows as Claude and Codex.") {
                        Card(look: .rows, state: .plugin("opencode-go-limits", [
                            PluginRow(name: "5-hour", detail: "resets in 3h 12m", value: "34%", used: 34),
                            PluginRow(name: "Weekly", detail: "resets Mon 8:00am", value: "61%", used: 61),
                            PluginRow(name: "Monthly", detail: "resets Dec 3", value: "22%", used: 22),
                        ]))
                    }
                    tile("OpenRouter, key with a budget", "Dollars, with a bar because there is a limit.") {
                        Card(look: .rows, state: .plugin("openrouter-limits", [
                            PluginRow(name: "Key budget", detail: "resets Dec 1", value: "$7.40 left of $20", used: 63),
                        ]))
                    }
                }
                HStack(alignment: .top, spacing: 32) {
                    tile("OpenRouter, no budget", "Spend only: no limit, so no bar and no percent.") {
                        Card(look: .rows, state: .plugin("openrouter-limits", [
                            PluginRow(name: "Today", detail: "", value: "$1.20", used: nil),
                            PluginRow(name: "This week", detail: "", value: "$6.10", used: nil),
                            PluginRow(name: "This month", detail: "", value: "$18.35", used: nil),
                        ]))
                    }
                    tile("OpenRouter, free models", "A count, near its limit.") {
                        Card(look: .rows, state: .plugin("openrouter-limits", [
                            PluginRow(name: "Free requests", detail: "resets 12:00am UTC", value: "6 of 50 left", used: 88),
                        ]))
                    }
                    tile("No extension installed", "The popover as it is today, with no limits section.") {
                        Card(look: .rows, state: .hidden)
                    }
                }
            }
        },
    ]

    /// One row a limits extension reports; without `used` there is nothing to measure against, so no bar.
    struct PluginRow {
        let name: String
        let detail: String
        let value: String
        let used: Int?
    }

    // MARK: Data

    struct Limit {
        let name: String
        let short: String
        let used: Int?
        var resets = ""
    }

    static let usual = [Limit(name: "5-hour", short: "5h", used: 42, resets: "resets in 2h 18m"),
                        Limit(name: "Weekly", short: "week", used: 18, resets: "resets Thu 9:40am")]
    static let near = [Limit(name: "5-hour", short: "5h", used: 96, resets: "resets in 24m"),
                       Limit(name: "Weekly", short: "week", used: 83, resets: "resets Thu 9:40am")]
    static let weekOnly = [Limit(name: "Weekly", short: "week", used: 18, resets: "resets Thu 9:40am")]

    enum Look { case rows, line, rings }
    enum State { case consent, reading, shown([Limit]), none, failed, plugin(String, [PluginRow]), pluginConsent(String, String), hidden }

    @MainActor static func tone(_ used: Int) -> Color {
        let colors = ChatColors.current
        return used >= 95 ? colors.red : used >= 80 ? colors.yellow : colors.ink.opacity(0.62)
    }

    // MARK: Stages

    @MainActor private static func inWindow(_ card: some View) -> some View {
        DispatchWindow(sidebar: Sample.sidebar) {
            Pane(strip: StripModel(tabs: [
                TabItem(title: "Fix the invoice rounding", activity: .working, shortcut: 1, selected: true),
                TabItem(title: "tests", shortcut: 2),
            ], mode: .chat, agent: true)) {
                ChatPane(items: [Sample.chat[0], Sample.chat[1], .tools(Array(Sample.steps.prefix(3)))],
                         composer: ComposerModel(working: ("thinking", "38s")), live: true)
                    .overlay(alignment: .bottomLeading) {
                        card.padding(.leading, Chrome.paneContentInset).padding(.bottom, 46)
                    }
            }
        }
    }

    @MainActor private static func board(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 36) { content() }
            .padding(32)
            .background(ChatColors.current.terminal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @MainActor private static func tile(_ title: String, _ note: String, @ViewBuilder _ content: () -> some View) -> some View {
        let colors = ChatColors.current
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.ink)
                Text(note).font(.system(size: 11.5)).foregroundStyle(colors.muted)
                    .lineLimit(2, reservesSpace: true).frame(maxWidth: Card.width, alignment: .leading)
            }
            content()
        }
        .fixedSize()
    }

    // MARK: The popover

    /// The app's popover (its label, then ChatSessionStats, 320 wide and 14 in), with the limits under a rule.
    struct Card: View {
        var look: Look
        var state: State
        var read = "read just now"
        var arrow: CGFloat?
        static let width: CGFloat = 320

        var body: some View {
            let colors = ChatColors.current
            VStack(alignment: .leading, spacing: 12) {
                Text("thinking").foregroundStyle(colors.ink)
                stats
                if case .hidden = state {} else {
                    Rectangle().fill(colors.ink.opacity(0.09)).frame(height: 1)
                    limits
                }
            }
            .font(ChatType.detail).foregroundStyle(colors.muted)
            .padding(14).frame(width: Self.width, alignment: .leading)
            .background(ModelLadder.PopoverCard(arrow: arrow))
        }

        /// ChatSessionStats: the context left, then the session's tokens.
        private var stats: some View {
            let colors = ChatColors.current
            return HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(colors.border)
                        Capsule().fill(colors.yellow).frame(width: 36 * 0.62)
                    }
                    .frame(width: 36, height: 4)
                    Text("62%").foregroundStyle(colors.yellow)
                }
                Text("(48.2K in, 3.1K out)")
            }
        }

        @ViewBuilder private var limits: some View {
            let colors = ChatColors.current
            switch state {
            case .consent:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Show Claude limits here?").foregroundStyle(colors.ink)
                    Text("Dispatch asks Claude Code only when you open this popover, at most once a minute. It sets Claude Code's status line for a moment, then puts it back.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Not Now") {}.controlSize(.small)
                        Button("Show Limits") {}.controlSize(.small).keyboardShortcut(.defaultAction)
                    }
                }
            case .reading:
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(["5-hour", "Weekly"], id: \.self) { name in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(name).foregroundStyle(colors.ink)
                            Capsule().fill(colors.border).frame(height: 4)
                        }
                    }
                    HStack(spacing: 6) { Orbit(); Text("Asking Claude Code…") }
                }
            case .shown(let windows):
                VStack(alignment: .leading, spacing: 8) {
                    switch look {
                    case .rows: VStack(alignment: .leading, spacing: 10) { ForEach(windows, id: \.name) { Row(limit: $0) } }
                    case .line: Line(windows: windows)
                    case .rings: HStack(spacing: 0) { ForEach(windows, id: \.name) { Ring(limit: $0).frame(maxWidth: .infinity) } }
                    }
                    Text("Your Claude plan · \(read)").font(ChatType.font(11)).foregroundStyle(colors.muted.opacity(0.75))
                }
            case .plugin(let name, let rows):
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 10) { ForEach(rows, id: \.name) { PluginRowView(row: $0) } }
                    Text("From \(name) · read just now").font(ChatType.font(11)).foregroundStyle(colors.muted.opacity(0.75))
                }
            case .pluginConsent(let name, let provider):
                VStack(alignment: .leading, spacing: 10) {
                    Text("Show limits from \(name)?").foregroundStyle(colors.ink)
                    Text("This Pi extension, which you installed, asks \(provider) when you open this popover, at most once a minute. Dispatch only shows what it reports.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Not Now") {}.controlSize(.small)
                        Button("Show Limits") {}.controlSize(.small).keyboardShortcut(.defaultAction)
                    }
                }
            case .hidden:
                EmptyView()
            case .none:
                Text("No limits to show. Claude Code reports them for Pro, Max and Ultra plans.")
                    .fixedSize(horizontal: false, vertical: true)
            case .failed:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Couldn't read limits.").foregroundStyle(colors.ink)
                    Spacer(minLength: 0)
                    Button("Try Again") {}.controlSize(.small)
                }
            }
        }
    }

    private struct PluginRowView: View {
        let row: PluginRow
        var body: some View {
            let colors = ChatColors.current
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.name).foregroundStyle(colors.ink)
                    if !row.detail.isEmpty { Text(row.detail) }
                    Spacer(minLength: 8)
                    Text(row.value).foregroundStyle((row.used ?? 0) >= 80 ? tone(row.used ?? 0) : colors.ink)
                }
                if let used = row.used {
                    GeometryReader { box in
                        ZStack(alignment: .leading) {
                            Capsule().fill(colors.border)
                            Capsule().fill(tone(used)).frame(width: box.size.width * CGFloat(used) / 100)
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    private struct Row: View {
        let limit: Limit
        var body: some View {
            let colors = ChatColors.current
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(limit.name).foregroundStyle(colors.ink)
                    Text(limit.resets)
                    Spacer(minLength: 8)
                    if let used = limit.used { Text("\(used)%").foregroundStyle(used >= 80 ? tone(used) : colors.ink) } else { Text("—") }
                }
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Capsule().fill(colors.border)
                        if let used = limit.used { Capsule().fill(tone(used)).frame(width: box.size.width * CGFloat(used) / 100) }
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private struct Line: View {
        let windows: [Limit]
        var body: some View {
            let colors = ChatColors.current
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    ForEach(windows, id: \.name) { limit in
                        HStack(spacing: 6) {
                            Text(limit.short).foregroundStyle(colors.ink)
                            ZStack(alignment: .leading) {
                                Capsule().fill(colors.border)
                                if let used = limit.used { Capsule().fill(tone(used)).frame(width: 36 * CGFloat(used) / 100) }
                            }
                            .frame(width: 36, height: 4)
                            Text(limit.used.map { "\($0)%" } ?? "—")
                        }
                    }
                }
                Text(windows.map { "\($0.short) \($0.resets)" }.joined(separator: " · "))
                    .font(ChatType.font(11)).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
    }

    private struct Ring: View {
        let limit: Limit
        var body: some View {
            let colors = ChatColors.current
            VStack(spacing: 6) {
                ZStack {
                    Circle().stroke(colors.border, lineWidth: 5)
                    if let used = limit.used {
                        Circle().trim(from: 0, to: CGFloat(used) / 100)
                            .stroke(tone(used), style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                    Text(limit.used.map { "\($0)%" } ?? "—").foregroundStyle(colors.ink)
                }
                .frame(width: 62, height: 62)
                Text(limit.name).foregroundStyle(colors.ink)
                Text(limit.resets).font(ChatType.font(11))
            }
        }
    }
}
