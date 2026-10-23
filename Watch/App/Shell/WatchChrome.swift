import SwiftUI

/// The redesign's shared pieces (mockups/Watch): the agent's glyph, the glass and accent capsules that replace platter
/// buttons, a platter-less list row and the host's CPU sparkline.

/// The agent's mark as the phone's tab rows draw it: Claude's sparkle in orange, Codex's angle brackets, Pi's π in the
/// code purple, a terminal otherwise. A fixed-width column, so rows line up whatever the agent.
struct AgentGlyph: View {
    let agent: String?
    var size: CGFloat = 13

    var body: some View {
        Group {
            switch AgentsGlyph.agent(agent) {
            case .symbol(let name): Image(systemName: name)
            case .letter(let letter): Text(letter).font(.system(size: size, weight: .semibold, design: .serif))
            }
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(AgentsGlyph.color(agent))
        .frame(width: size + 4)
        .accessibilityHidden(true)
    }
}

/// A full-width capsule button as watchOS 26 draws them: glass, or the accent for the one affirmative action, or glass
/// with red words for a destructive one. Used as a `Button`'s label (`CapsuleLabel`) so the list row stays bare.
struct CapsuleLabel: View {
    enum Style: Equatable { case accent, glass, destructive }

    let title: String
    var symbol: String? = nil
    var style: Style = .glass
    var enabled = true

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.headline)
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, minHeight: 44)
        .modifier(CapsuleFill(accent: style == .accent && enabled))
        .contentShape(Capsule())
    }

    private var foreground: Color {
        guard enabled else { return .secondary }
        switch style {
        case .accent: return AgentsColor.onPink
        case .destructive: return AgentsColor.destructive
        case .glass: return .primary
        }
    }
}

/// A capsule button in a list: no platter of its own, the capsule draws it.
struct CapsuleButton: View {
    let title: String
    var symbol: String? = nil
    var style: CapsuleLabel.Style = .glass
    var enabled = true
    var hint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CapsuleLabel(title: title, symbol: symbol, style: style, enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .modifier(BareRow(vertical: 3))
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
    }
}

/// Liquid Glass in a capsule; tinted with the accent for the affirmative action.
struct CapsuleFill: ViewModifier {
    var accent = false

    func body(content: Content) -> some View {
        content.glassEffect(accent ? .regular.tint(AgentsColor.pink).interactive() : .regular.interactive(), in: Capsule())
    }
}

/// A row with no platter and tight insets: cards, bubbles and capsules draw their own.
struct BareRow: ViewModifier {
    var vertical: CGFloat = 3

    func body(content: Content) -> some View {
        content
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: vertical, leading: 2, bottom: vertical, trailing: 2))
    }
}

/// The phone's 15-minute CPU sparkline, reduced: a filled line in the host's tint with the last sample marked; gaps
/// (nil buckets) are skipped.
struct Sparkline: View {
    let values: [Double?]
    var color: Color = .gray
    /// The value of the top edge.
    var ceiling: Double = 100

    var body: some View {
        Canvas { context, size in
            guard let path = Self.points(values, in: size, ceiling: ceiling), path.count > 1 else { return }
            var line = Path()
            line.move(to: path[0])
            for point in path.dropFirst() { line.addLine(to: point) }
            var area = line
            area.addLine(to: CGPoint(x: path[path.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: path[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let last = path[path.count - 1]
            context.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(color))
        }
        .accessibilityHidden(true)
    }

    /// Each sample's point (x by its bucket, y by its value); nil for fewer than two buckets.
    static func points(_ values: [Double?], in size: CGSize, ceiling: Double) -> [CGPoint]? {
        guard values.count > 1, ceiling > 0 else { return nil }
        return values.enumerated().compactMap { index, value in
            guard let value else { return nil }
            let clamped = min(max(value, 0), ceiling)
            return CGPoint(x: size.width * Double(index) / Double(values.count - 1),
                           y: size.height - 3 - (size.height - 6) * clamped / ceiling)
        }
    }
}
