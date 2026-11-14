import SwiftUI

/// The phone's colours for the shared steps (`ChatStep`, Dispatch/Chat/ChatTurnSteps.swift).
extension ChatStep.Kind {
    /// The mockup's badge colours: read blue, think purple, run amber, patch green.
    /// Deeper in light so the 11 pt word reads on its faint tint (asset catalog).
    var tint: Color {
        switch self {
        case .read, .search, .web: Color("StepRead")
        case .think: Color("StepThink")
        case .run: Color("StepRun")
        case .patch: .added
        case .tool: Color("StepTool")
        }
    }
}

extension ChatStep {
    static var added: Color { .added }
    static var removed: Color { .removed }
}

/// M5f's kind badge: its icon (`ChatStep.Kind.symbol`, message details' glyph), then the word in mono caps, on a faint tint; every badge as wide as the widest word
/// ("SEARCH") at any text size, so what follows it starts at one place in every row.
struct ChatStepBadge: View {
    let kind: ChatStep.Kind
    /// Another mark in a badge's place, as wide as every badge (the running agents' count): its symbol, word and tint.
    var custom: (symbol: String, word: String, tint: Color)? = nil
    /// Every badge's word: the widest sets the width, laid out but not drawn.
    private static let words: [ChatStep.Kind] = [.read, .patch, .run, .search, .think, .web, .tool]
    @ScaledMetric(relativeTo: .caption2) private var icon: CGFloat = 12
    @Environment(\.chatPalette) private var palette
    private var tint: Color { palette.monochrome ?? custom?.tint ?? kind.tint }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: custom?.symbol ?? kind.symbol)
                .font(.caption2.weight(.semibold))
                .imageScale(.small)
                .frame(width: icon)
            ZStack(alignment: .leading) {
                ForEach(Self.words, id: \.label) { Self.word($0).hidden() }
                if let custom { Self.word(custom.word) } else { Self.word(kind) }
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(minHeight: 20)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(custom?.word ?? kind.label)
    }

    private static func word(_ kind: ChatStep.Kind) -> some View { word(kind.label) }

    private static func word(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold).monospaced())
            .tracking(0.44)
            .lineLimit(1)
    }
}
