import SwiftUI

struct AttentionBanner: View {
    let controller: AppDelegate
    @Environment(\.appTypography) private var typography
    var body: some View {
        if let entry = controller.attention.banner {
            HStack(spacing: 6) {
                Button { controller.attention.focus(entry.id) } label: {
                    HStack {
                        ActivityMark(entry.urgency).view(size: typography.size(.label))
                        Text(entry.title + " is waiting for input").lineLimit(1)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(entry.place + " · ⌘J")
                    .accessibilityIdentifier("attention-banner")
                // Where ⌘J was shown: hides the banner until this agent waits for something new (⌘J still goes there).
                Button { controller.attention.dismissBanner(entry.id) } label: {
                    Image(systemName: "xmark").font(.system(size: typography.size(.label) - 3, weight: .semibold))
                        .foregroundStyle(Chrome.muted)
                        .frame(width: 18, height: 18)
                        .hoverFill(Circle())
                        .contentShape(Circle())
                }.buttonStyle(.plain)
                    .help("Hide until it waits for something new · ⌘J still goes there")
                    .accessibilityLabel("Dismiss")
                    .accessibilityIdentifier("attention-banner-dismiss")
            }.font(typography, .label).padding(.leading, 14).padding(.trailing, 9).padding(.vertical, 7)
                .foregroundStyle(Chrome.palette.green)
                // On glass a floating capsule inset under the strip; otherwise a full-width sidebar-colored bar.
                .liquidGlass(in: Capsule(), interactive: true)
                .background(LiquidGlassStore.shared.active ? Color.clear : Chrome.sidebar)
                .padding(.horizontal, LiquidGlassStore.shared.active ? 8 : 0).padding(.top, LiquidGlassStore.shared.active ? 4 : 0)
        }
    }
}
