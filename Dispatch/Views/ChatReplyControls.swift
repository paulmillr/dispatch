import SwiftUI

struct ChatReplyButton: View {
    @Environment(\.chatTheme) private var theme
    let canSubmit: Bool
    var alternateSendHeld = false
    var busy = false
    /// Return steers while the agent works (`ChatCoordinator.returnSteers`): ⌥⌘ then queues.
    var steers = false
    var editingQueued = false
    var multiline = false
    var command = false
    var identifier = "chat-send"
    /// Without it, a tight footer drops the keycap (the help keeps it).
    var showsKey = true
    let action: () -> Void

    private var title: String {
        steers ? (alternateSendHeld ? "Queue" : "Steer")
            : alternateSendHeld ? "Steer" : editingQueued ? "Requeue" : busy ? "Queue" : "Send"
    }
    private var label: String {
        switch title {
        case "Requeue": "Requeue message"
        case "Queue": "Queue message"
        case "Send": command ? "Send command" : "Send message"
        default: title
        }
    }
    private var key: String { alternateSendHeld ? "⌥⌘⏎" : multiline ? "⌘⏎" : "⏎" }

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
                if showsKey {
                    Text(key)
                        .font(AppFont.shortcut(size: theme.typography.codeDetailSize)).foregroundStyle(theme.muted)
                }
            }.padding(.horizontal, 10)
                .frame(height: max(24, theme.typography.detailLineHeight + 10))
                .foregroundStyle(canSubmit ? theme.ink : theme.muted)
                .background(Chrome.palette.control, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(canSubmit ? theme.accent.opacity(0.5) : Chrome.palette.controlBorder) }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).disabled(!canSubmit).fixedSize()
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
    }

    private var standardBody: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    Text("Requeue").hidden().accessibilityHidden(true)
                    Text(title)
                }
                if showsKey {
                    ZStack {
                        Text("⌥⌘⏎").hidden().accessibilityHidden(true)
                        Text("⌘⏎").hidden().accessibilityHidden(true)
                        Text(key)
                    }.font(AppFont.shortcut(size: theme.typography.codeDetailSize)).opacity(0.7)
                }
            }.padding(.horizontal, 9)
                .frame(height: max(24, theme.typography.detailLineHeight + 10))
                .foregroundStyle(canSubmit ? theme.terminal : theme.muted)
                .modifier(ReplyButtonSurface(enabled: canSubmit))
        }.font(theme.typography.detail).buttonStyle(.plain).disabled(!canSubmit).fixedSize()
            .help("\(title) · \(key)")
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
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
