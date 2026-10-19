import SwiftUI

/// A form section's header as the mockup draws them (M1f's CONNECTION, M8a's NAME, HOST, USERNAME, AUTHENTICATION):
/// 13-point secondary capitals, the same as the app's own sheets (M7a, M9a) and message details (M5b). iOS 26's
/// inset grouped lists default to a larger title-case header.
struct MobileSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
