import SwiftUI

// Exploration: the updater's changelog. Today a downloaded update asks with a bare NSAlert ("Dispatch 0.1.7 is ready",
// Later · Restart and install) and Settings › General › Updates shows one status line. Here both show what changed:
// the newest release's notes, at most five items, the rest ignored (no scrolling). One change a line, the whole text
// as its tooltip, the area in a gutter in a colour of its own.
//
// The notes are the version commit's body as the GitHub release carries it: everything before the first `---` line;
// items are lines starting `* ` or `- `; `Area: text` gives the tag when Area is one word of up to 12 characters.

enum UpdateScreens {
    static let screens: [Screen] = [
        Screen("U1-ready", group: "updates", "The ready sheet: the first five items of the release notes") {
            over(ReadySheet(style: .gutter))
        },
        Screen("U4a-downloading", group: "updates", "Downloading: the ring and the footer's edge fill, Restart waits") {
            over(ReadySheet(style: .gutter, phase: .downloading(0.42)))
        },
        Screen("U4b-verifying", group: "updates", "Verifying: an arc circles the tile, a light sweeps the edge") {
            over(ReadySheet(style: .gutter, phase: .verifying(0.55)))
        },
        Screen("U1b-short", group: "updates", "Three items, one without an area: the block is as tall as the list") {
            over(ReadySheet(style: .gutter, notes: short))
        },
        Screen("U2-log", group: "updates", "The same as a log in the terminal's colours: `git log --oneline` of the release") {
            over(ReadySheet(style: .log))
        },
        Screen("U3-settings", group: "updates", "Settings › Updates: the block under the version row while an update is ready") {
            SettingsUpdates()
        },
    ]

    // MARK: Data: release notes as written, parsed as the app would

    static let notes = """
    * Chat: Text typed at the agent's prompt in Terminal moves to the Chat draft
    * Files: Markdown opens rendered: a centred column, an outline, folding
    * Commits: One filter for another branch's history and the tagged commits
    - iPhone: Read Aloud for an agent's replies
    - SSH: A reconnect keeps the password prompt in its tab
    - Watch: host · folder on every row
    * Pi: Names the draft it hands to Chat

    ---

    `brew install --cask paulmillr/tap/dispatch` or open `.dmg`.
    """
    static let short = """
    * tmux: Sessions started later attach too
    * Fixed a crash when the Mac wakes with a tab reconnecting
    * Settings: Reset puts back the defaults
    """

    struct Change { let area: String?; let text: String }

    /// The release notes' items: before the first `---` line, bullets only, the first five.
    static func changes(_ notes: String) -> [Change] {
        var items: [Change] = []
        for raw in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" { break }
            guard raw.first == "*" || raw.first == "-", line.hasPrefix("* ") || line.hasPrefix("- ") else { continue }
            let item = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if let colon = item.range(of: ": "), case let area = item[..<colon.lowerBound],
               (1...12).contains(area.count), !area.contains(" ") {
                items.append(Change(area: String(area), text: String(item[colon.upperBound...])))
            } else {
                items.append(Change(area: nil, text: item))
            }
            if items.count == 5 { break }
        }
        return items
    }

    /// Each area keeps a colour from the terminal's palette, so a glance tells what kind of release it is.
    @MainActor static func areaTint(_ area: String) -> Color {
        let palette = TerminalScheme.current.palette
        switch area {
        case "Chat": return Chrome.accent
        case "Files", "Commits": return palette[2]
        case "iPhone", "Watch": return palette[5]
        case "SSH", "tmux", "Pi": return palette[3]
        default: return palette[6]
        }
    }

    // MARK: The window behind the sheet

    @MainActor private static func over(_ sheet: some View) -> some View {
        DispatchWindow(width: 900, height: 560, sidebar: SidebarModel(spaces: Sample.sidebar.spaces, width: 220)) {
            Pane(strip: StripModel(tabs: [TabItem(title: "app", shortcut: 1, selected: true)])) { TerminalScreen(lines: Sample.gitLog) }
        }
        .overlay { Color.black.opacity(Chrome.palette.isDark ? 0.35 : 0.12).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        .overlay(alignment: .top) { sheet.padding(.top, 40) }
    }

    @MainActor static var muted: Color { Onboarding.muted }
    @MainActor static func uiFont(_ size: CGFloat, bold: Bool = false) -> Font { Onboarding.sheetFont(size, bold: bold) }

    // MARK: The changelog block

    enum Style { case gutter, log }

    /// One line an item, as many lines as items (five at most).
    struct Changelog: View {
        var style: Style
        var notes: String = UpdateScreens.notes
        var width: CGFloat = 440
        static let row: CGFloat = 21

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(changes(notes).enumerated()), id: \.offset) { _, change in row(change) }
            }
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 6)
            .background(style == .log ? TerminalScheme.current.background : Chrome.sidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.border))
        }

        @ViewBuilder private func row(_ change: Change) -> some View {
            switch style {
            case .gutter:
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle().fill(change.area.map(areaTint) ?? muted).frame(width: 5, height: 5)
                        if let area = change.area { Text(area).font(uiFont(10.5, bold: true)).foregroundStyle(areaTint(area)) }
                    }
                    .frame(width: 66, alignment: .leading)
                    Text(change.text).font(uiFont(11.5)).foregroundStyle(Chrome.ink.opacity(0.9)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).frame(height: Self.row)
            case .log:
                let scheme = TerminalScheme.current
                HStack(spacing: 0) {
                    Text("* ").foregroundStyle(scheme.palette[2]).bold()
                    if let area = change.area {
                        Text(area.lowercased().padding(toLength: 9, withPad: " ", startingAt: 0)).foregroundStyle(areaTint(area))
                    }
                    Text(change.text).foregroundStyle(scheme.foreground).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(AppFont.sourceCodePro(size: 11)).padding(.horizontal, 12).frame(height: Self.row)
            }
        }
    }

    // MARK: The ready sheet (instead of the NSAlert)

    /// The updater's steps as the sheet shows them (AppUpdater.State): the download's fraction, then verifying, then
    /// ready. The sheet opens on the first and keeps its size through all three; the changelog is there from the start.
    enum Phase: Equatable { case downloading(Double), verifying(Double), ready }

    struct ReadySheet: View {
        var style: Style
        var notes: String = UpdateScreens.notes
        var phase: Phase = .ready
        static let width: CGFloat = 480
        static let total = 12.4

        private var ready: Bool { phase == .ready }
        private var title: String {
            switch phase {
            case .downloading: "Downloading Dispatch 0.1.7"
            case .verifying: "Verifying Dispatch 0.1.7"
            case .ready: "Dispatch 0.1.7 is ready"
            }
        }
        private var detail: String {
            switch phase {
            case .downloading(let fraction): String(format: "from 0.1.6 · %.1f of %.1f MB", fraction * Self.total, Self.total)
            case .verifying: "from 0.1.6 · checking the signature and notarization"
            case .ready: "from 0.1.6 · downloaded and verified"
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Tile(phase: phase)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(uiFont(13, bold: true)).foregroundStyle(Chrome.ink)
                            Text(detail).font(uiFont(11)).monospacedDigit().foregroundStyle(muted)
                        }
                        Spacer(minLength: 0)
                    }
                    Changelog(style: style, notes: notes, width: Self.width - 40)
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("Release notes")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(uiFont(11.5)).foregroundStyle(muted)
                    Spacer(minLength: 8)
                    // Cancel stops the download and removes it; once ready, Later keeps it for the next quit.
                    Text(ready ? "Later" : "Cancel").font(uiFont(12.5)).foregroundStyle(Chrome.ink.opacity(0.8))
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Chrome.ink.opacity(0.07), in: Capsule())
                    Text("Restart and install").font(uiFont(12.5, bold: true))
                        .foregroundStyle(ready ? Chrome.window : Chrome.ink.opacity(0.35))
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(ready ? Chrome.accent : Chrome.ink.opacity(0.07), in: Capsule())
                }
                .padding(.horizontal, 14).frame(height: 54)
                .background(Chrome.sidebar)
                .overlay(alignment: .top) { edge }
            }
            .frame(width: Self.width)
            .background(Chrome.window)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Chrome.border))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
        }

        /// The footer's top edge is the progress line: the download's fraction in the accent; while verifying, full
        /// and dim with a bright segment sweeping along it (`sweep` is where the segment is in this frame); ready, the
        /// hairline again.
        @ViewBuilder private var edge: some View {
            switch phase {
            case .downloading(let fraction):
                ZStack(alignment: .leading) {
                    Rectangle().fill(Chrome.border)
                    Rectangle().fill(Chrome.accent).frame(width: Self.width * fraction)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(LinearGradient(colors: [Chrome.accent.opacity(0), .white.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: 40)
                        }
                }
                .frame(height: 2)
            case .verifying(let sweep):
                ZStack(alignment: .leading) {
                    Rectangle().fill(Chrome.accent.opacity(0.35))
                    Rectangle().fill(LinearGradient(colors: [Chrome.accent.opacity(0), Chrome.accent, Chrome.accent.opacity(0)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 120).offset(x: (Self.width + 120) * sweep - 120)
                }
                .frame(height: 2).clipped()
            case .ready:
                Rectangle().fill(Chrome.border).frame(height: 1)
            }
        }
    }

    /// A rounded square traced clockwise from the top's centre, so a trimmed ring fills as a clock does.
    struct Ring: Shape, Sendable {
        nonisolated init(radius: CGFloat) { self.radius = radius }
        var radius: CGFloat
        nonisolated func path(in rect: CGRect) -> Path {
            let r = radius
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.midX, y: rect.minY), radius: r)
            path.closeSubpath()
            return path
        }
    }

    /// The header's tile: the arrow with a ring filling round the tile as it downloads; the shield with a short arc
    /// circling while it verifies; a check once ready.
    struct Tile: View {
        var phase: Phase
        private static let glyph = Color(.sRGB, red: 126/255, green: 166/255, blue: 201/255)

        var body: some View {
            let shape = Ring(radius: 9)
            ZStack {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(phase == .ready ? Chrome.accent : Self.glyph)
                    .frame(width: 28, height: 28)
                    .background(Color(.sRGB, red: 0.12, green: 0.17, blue: 0.21), in: RoundedRectangle(cornerRadius: 7))
                switch phase {
                case .downloading(let fraction):
                    shape.stroke(Chrome.ink.opacity(0.12), lineWidth: 2)
                    shape.trim(from: 0, to: fraction).stroke(Chrome.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                case .verifying(let sweep):
                    shape.stroke(Chrome.accent.opacity(0.3), lineWidth: 2)
                    shape.trim(from: sweep, to: min(1, sweep + 0.22)).stroke(Chrome.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                case .ready:
                    shape.stroke(Chrome.accent.opacity(0.6), lineWidth: 2)
                }
            }
            .frame(width: 34, height: 34)
        }

        private var symbol: String {
            switch phase {
            case .downloading: "arrow.down"
            case .verifying: "checkmark.shield"
            case .ready: "checkmark"
            }
        }
    }

    // MARK: Settings › General › Updates

    /// The Updates group as Settings lays it out (title above a rounded card, rows split by a hairline), the block
    /// under the version row while an update waits.
    struct SettingsUpdates: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Updates").font(uiFont(12, bold: true)).foregroundStyle(muted).padding(.leading, 4)
                VStack(spacing: 0) {
                    settingsRow("Automatic updates", detail: "downloads new releases; asks before restarting") {
                        Toggle("", isOn: .constant(true)).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    Rectangle().fill(Chrome.border).frame(height: 1).padding(.horizontal, 14)
                    VStack(alignment: .leading, spacing: 10) {
                        settingsRow("Dispatch 0.1.6", detail: "Dispatch 0.1.7 is ready to install.", padded: false) {
                            Button("Restart and install") {}.buttonStyle(.borderedProminent).controlSize(.regular)
                        }
                        Changelog(style: .gutter, width: 512)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                }
                .background(Chrome.sidebar.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Chrome.border))
            }
            .frame(width: 540)
            .padding(24)
            .background(Chrome.window, in: RoundedRectangle(cornerRadius: 14))
        }

        private func settingsRow<Control: View>(_ title: String, detail: String, padded: Bool = true,
                                                @ViewBuilder control: () -> Control) -> some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(uiFont(13)).foregroundStyle(Chrome.ink)
                    Text(detail).font(uiFont(11.5)).foregroundStyle(muted)
                }
                Spacer(minLength: 0)
                control()
            }
            .padding(.horizontal, padded ? 14 : 0).padding(.vertical, padded ? 11 : 0)
        }
    }
}
