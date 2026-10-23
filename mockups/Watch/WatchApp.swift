import SwiftUI

@main
struct MockupsWatchApp: App {
    var body: some Scene {
        WindowGroup { Root() }
    }
}

/// `-screen <id>` picks the screen. The watch has one scheme (dark).
struct Root: View {
    private let screen = UserDefaults.standard.string(forKey: "screen") ?? "K1-list"
    var body: some View {
        Screens.view(screen).tint(.dispatchPink)
    }
}

enum Screens {
    @ViewBuilder static func view(_ id: String) -> some View {
        switch id {
        case "K1-list": AgentsListScreen()
        case "K1b-list-scrolled": AgentsListScreen(scrolled: true)
        case "K2-thread": ThreadScreen()
        case "K3-approval": ApprovalScreen()
        case "K4-question": QuestionScreen()
        case "K5-reply": ReplyScreen()
        case "K6-host": HostScreen(offline: false)
        case "K6b-host-offline": HostScreen(offline: true)
        case "K7-complication": ComplicationNoteScreen()
        case "K8-review": ReviewSentScreen()
        default: Text("screen \(id)").font(.title3)
        }
    }
}

// The phone's named colours (Mobile/App/Assets.xcassets) in their dark values: the watch target rejects the phone's
// catalog (its iOS-only AppIcon set fails actool), and the watch is always dark.
extension Color {
    static let dispatchPink = Color(hex: 0xE07BE0)
    static let onAccent = Color(hex: 0x1A1218)
    static let groupedRow = Color(hex: 0x1C1C1E)
    static let bubbleAgent = Color(hex: 0x2C2C2E)
    static let approvalCode = Color(hex: 0x1F1F20)
    static let added = Color(hex: 0x7FD3A1)
    static let destructive = Color(hex: 0xE07B7B)
    static let stateUnread = Color(hex: 0x0A84FF)
    static let stateWorking = Color(hex: 0xD9B36A)
    static let stateConnected = Color(hex: 0x7FD3A1)
    static let codeType = Color(hex: 0xA98AE0)
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    /// The phone mockups' host tint for mba2.
    static let hostTint = Color(red: 0x7E / 255, green: 0xA6 / 255, blue: 0xC9 / 255)
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
}

// MARK: Fictional data

struct MockConversation: Identifiable {
    let title: String
    let agent: String          // claude, codex, pi
    let line: String           // the state line: step while working, question while waiting, last message when done
    let time: String
    var dot: Color? = nil
    var id: String { title }
}

enum Mock {
    static let host = "mba2", space = "app"
    static let conversations: [MockConversation] = [
        .init(title: "Sidebar theme toggle", agent: "claude", line: "Editing Sidebar.tsx · 48s", time: "now", dot: .stateWorking),
        .init(title: "Rate limiter for the API", agent: "codex", line: "Allow cargo test --workspace?", time: "2m", dot: .stateUnread),
        .init(title: "Docs site migration", agent: "claude", line: "Moved the docs to Starlight; the old MkDocs config is gone.", time: "1h"),
    ]
    /// 60 × 15 s buckets of CPU, peak per bucket; nil is a gap (the phone mockups' series).
    static let history: [Double?] = {
        var seed: UInt64 = 11
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        var out: [Double?] = []
        var v = 28.0
        for i in 0..<60 {
            v = max(4, min(96, v + (rnd() - 0.5) * 18))
            if (12...15).contains(i) { out.append(nil); continue }
            if i == 41 { v = 82 }
            out.append(v)
        }
        out[59] = 34
        return out
    }()
}

// MARK: Shared pieces

/// The agent's mark as the phone's new tab rows draw it: Claude's sparkle in orange, Codex's angle brackets, Pi's π.
struct AgentGlyph: View {
    let kind: String
    var size: CGFloat = 15
    var body: some View {
        Group {
            switch kind {
            case "claude": Image(systemName: "sparkle").foregroundStyle(Color.claudeOrange)
            case "codex": Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.primary)
            case "pi": Text("π").font(.system(size: size, weight: .semibold, design: .serif)).foregroundStyle(Color.codeType)
            default: Image(systemName: "apple.terminal").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: size, weight: .semibold))
        .frame(width: size + 4)
        .accessibilityHidden(true)
    }
}

/// The gutter dot: blue needs you, amber working, clear otherwise (fixed width so rows line up).
struct Dot: View {
    let color: Color?
    var size: CGFloat = 8
    var body: some View { Circle().fill(color ?? .clear).frame(width: size, height: size) }
}

/// A full-width capsule button as watchOS 26 draws them: glass, or the accent for the one affirmative action.
struct CapsuleButton: View {
    enum Style { case accent, glass, destructive }
    let title: String
    var symbol: String? = nil
    var style: Style = .glass
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(.headline)
        .foregroundStyle(style == .accent ? Color.onAccent : style == .destructive ? Color.destructive : .primary)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .modifier(CapsuleFill(accent: style == .accent))
    }
}

/// Glass on watchOS 26; a material capsule where the modifier is unavailable.
struct CapsuleFill: ViewModifier {
    var accent = false
    func body(content: Content) -> some View {
        if #available(watchOS 26.0, *) {
            content.glassEffect(accent ? .regular.tint(.dispatchPink).interactive() : .regular.interactive(), in: Capsule())
        } else {
            content.background(accent ? AnyShapeStyle(Color.dispatchPink) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        }
    }
}

/// A row with no platter: cards and bubbles draw their own.
struct BareRow: ViewModifier {
    var vertical: CGFloat = 3
    func body(content: Content) -> some View {
        content.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: vertical, leading: 0, bottom: vertical, trailing: 0))
    }
}

/// The agent's bubble (the phone's ChatBubble at watch size).
struct AgentBubble<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .font(.footnote)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bubbleAgent, in: UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 14, bottomLeading: 4, bottomTrailing: 14, topTrailing: 14), style: .continuous))
    }
}

/// The phone's 15-minute sparkline, reduced: a filled line in the host's tint with the last sample marked.
struct Sparkline: View {
    let bars: [Double?]
    var color: Color = .hostTint
    var body: some View {
        Canvas { ctx, size in
            let pts: [CGPoint] = bars.enumerated().compactMap { i, v in
                guard let v else { return nil }
                return CGPoint(x: size.width * Double(i) / Double(bars.count - 1), y: size.height - 3 - (size.height - 6) * v / 100)
            }
            guard pts.count > 1 else { return }
            var line = Path(); line.move(to: pts[0])
            for p in pts.dropFirst() { line.addLine(to: p) }
            var area = line
            area.addLine(to: CGPoint(x: pts.last!.x, y: size.height)); area.addLine(to: CGPoint(x: pts[0].x, y: size.height)); area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let last = pts.last!
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(color))
        }
    }
}
