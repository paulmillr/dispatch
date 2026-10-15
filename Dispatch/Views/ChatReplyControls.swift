import SwiftUI

struct ChatReplyButton: View {
    @Environment(\.chatTheme) private var theme
    let canSubmit: Bool
    var optionHeld = false
    var busy = false
    var editingQueued = false
    var multiline = false
    var command = false
    var identifier = "chat-send"
    let action: () -> Void

    private var title: String { optionHeld ? "Steer" : editingQueued ? "Requeue" : busy ? "Queue" : "Send" }

    var body: some View {
        if theme.radioLog { radioBody } else { standardBody }
    }

    /// Nautical's push-to-talk key: a microphone and the action in capitals, Send as TRANSMIT.
    private var radioBody: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "mic").font(.system(size: theme.typography.detailSize, weight: .medium))
                    .foregroundStyle(canSubmit ? theme.accent : theme.muted)
                ZStack {
                    Text("TRANSMIT").hidden().accessibilityHidden(true)
                    Text(title == "Send" ? "TRANSMIT" : title.uppercased())
                }.font(HarbourType.heading(theme.typography.detailSize + 0.5)).tracking(1.8)
                Text(optionHeld ? "⌥⏎" : multiline ? "⌘⏎" : "⏎")
                    .font(AppFont.shortcut(size: theme.typography.codeDetailSize)).foregroundStyle(theme.muted)
            }.padding(.horizontal, 10)
                .frame(height: max(24, theme.typography.detailLineHeight + 10))
                .foregroundStyle(canSubmit ? theme.ink : theme.muted)
                .background(Chrome.palette.control, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(canSubmit ? theme.accent.opacity(0.5) : Chrome.palette.controlBorder) }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).disabled(!canSubmit).fixedSize()
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(optionHeld ? "Steer" : editingQueued ? "Requeue message" : busy ? "Queue message" : command ? "Send command" : "Send message")
    }

    private var standardBody: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    Text("Requeue").hidden().accessibilityHidden(true)
                    Text(title)
                }
                ZStack {
                    Text("⌥⏎").hidden().accessibilityHidden(true)
                    Text("⌘⏎").hidden().accessibilityHidden(true)
                    Text(optionHeld ? "⌥⏎" : multiline ? "⌘⏎" : "⏎")
                }.font(AppFont.shortcut(size: theme.typography.codeDetailSize)).opacity(0.7)
            }.padding(.horizontal, 9)
                .frame(height: max(24, theme.typography.detailLineHeight + 10))
                .foregroundStyle(canSubmit ? theme.terminal : theme.muted)
                .modifier(ReplyButtonSurface(enabled: canSubmit))
        }.font(theme.typography.detail).buttonStyle(.plain).disabled(!canSubmit).fixedSize()
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(optionHeld ? "Steer" : editingQueued ? "Requeue message" : busy ? "Queue message" : command ? "Send command" : "Send message")
    }
}

/// With Liquid Glass, an accent-tinted interactive glass capsule (clear glass while it can't submit), like the
/// transcript's new-messages button; otherwise a flat accent fill.
private struct ReplyButtonSurface: ViewModifier {
    @Environment(\.chatTheme) private var theme
    let enabled: Bool

    func body(content: Content) -> some View {
        if LiquidGlassStore.shared.active {
            content.liquidGlass(in: Capsule(), interactive: enabled, tint: enabled ? theme.accent : nil)
                .contentShape(Capsule())
        } else {
            content.background(enabled ? theme.accent : theme.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
