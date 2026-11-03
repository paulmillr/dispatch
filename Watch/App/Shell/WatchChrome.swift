import SwiftUI

/// The redesign's shared pieces (mockups/Watch): the agent's glyph, the glass and accent capsules that replace platter
/// buttons and a platter-less list row. The host's CPU sparkline is in `Watch/Complication` (the Host widget draws it).

/// The agent's mark as the phone's tab rows draw it (`AgentGlyph`): one monochrome speech bubble for every agent, the
/// terminal for none, secondary, in a fixed-width column.
struct AgentGlyph: View {
    let agent: String?
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: AgentsGlyph.symbol(agent))
            .font(.system(size: size))
            .foregroundStyle(.secondary)
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
