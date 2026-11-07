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

/// M5f's kind badge: the word in mono caps on a faint tint, 50 points wide whatever the word, so the log's paths line up.
struct ChatStepBadge: View {
    let kind: ChatStep.Kind
    @ScaledMetric(relativeTo: .caption2) private var width: CGFloat = 50
    var body: some View {
        Text(kind.label.uppercased())
            .font(.caption2.weight(.bold).monospaced())
            .tracking(0.44)
            .foregroundStyle(kind.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: width, minHeight: 20, alignment: .leading)
            .background(kind.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(kind.label)
    }
}
