import SwiftUI

/// A section's first-run state (M1d): a glyph in a faint disc, a title, one sentence and the pink call to action.
struct MobileEmptyState: View {
    let section: MobileSection
    let add: () -> Void

    var title: String {
        switch section {
        case .spaces: "No hosts yet"
        case .agents: "No agents yet"
        }
    }

    /// M1d's copy for Spaces, verbatim. The mockup has no copy for Agents ("Agents shows its own empty copy until a
    /// host exists"); its sentence is in the same voice.
    var message: String {
        switch section {
        case .spaces: "Add a Mac or Linux machine you can reach over SSH. Dispatch keeps the session alive over mosh as you move between networks."
        case .agents: "Add a host and the coding agents running on it show up here as conversations you can pick up on the go."
        }
    }

    /// M1d shows a host (a display) in the disc: the thing that is missing.
    var symbol: String {
        switch section {
        case .spaces: "display"
        case .agents: section.symbol
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 84, height: 84)
                .background(Color.faintFill, in: Circle())
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: add) {
                // M1d: a plus before the label, 20 pt in and 24 pt out.
                Label("Add host", systemImage: "plus")
                    .font(.headline)
                    .padding(.leading, 20)
                    .padding(.trailing, 24)
                    .padding(.vertical, 8)
                    .frame(minHeight: 50)
            }
            .buttonStyle(MobileCallToAction())
            .padding(.top, 10)
        }
        .padding(.horizontal, typeSize.isAccessibilitySize ? 20 : 44)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity)
        .scrollCentred()
    }

    @Environment(\.dynamicTypeSize) private var typeSize
}

private extension View {
    /// Centred while it fits; at the largest text sizes it scrolls instead of running under the bars.
    func scrollCentred() -> some View {
        GeometryReader { geometry in
            ScrollView { frame(minHeight: geometry.size.height) }
                .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// M1d's pink capsule: dark text on the app tint with a soft pink glow.
struct MobileCallToAction: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.onAccent)
            .background(Color.dispatchPink, in: Capsule())
            .shadow(color: Color.dispatchPink.opacity(0.3), radius: 9, y: 6)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
