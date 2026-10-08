import SwiftUI

struct AttentionBanner: View {
    let controller: AppDelegate
    @Environment(\.appTypography) private var typography
    var body: some View {
        if let entry = controller.attention.banner {
            Button { controller.attention.focus(entry.id) } label: {
                HStack {
                    Text(entry.urgency.symbol)
                    Text(entry.title + " is waiting for input").lineLimit(1)
                    Spacer()
                    Text("⌘J").foregroundStyle(Chrome.muted)
                }.font(typography.font(offset: -1)).padding(.horizontal, 14).padding(.vertical, 7)
                    .foregroundStyle(Chrome.palette.green)
                    // On glass a floating capsule inset under the strip; otherwise a full-width sidebar-colored bar.
                    .liquidGlass(in: Capsule(), interactive: true)
                    .background(LiquidGlassStore.shared.active ? Color.clear : Chrome.sidebar).contentShape(Rectangle())
            }.buttonStyle(.plain).help(entry.path)
                .padding(.horizontal, LiquidGlassStore.shared.active ? 8 : 0).padding(.top, LiquidGlassStore.shared.active ? 4 : 0)
                .accessibilityIdentifier("attention-banner")
        }
    }
}
