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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    Text("Requeue").hidden().accessibilityHidden(true)
                    Text(optionHeld ? "Steer" : editingQueued ? "Requeue" : busy ? "Queue" : "Send")
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
