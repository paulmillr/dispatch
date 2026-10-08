import SwiftUI

struct ChatModeSwitch: View {
    private var theme: ChatTheme { ChatThemeStore.shared.current }
    @Bindable var session: ChatSession
    let coordinator: ChatCoordinator
    var floating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var typing = false
    var body: some View {
        Button {
            TerminalRuntime.shared.workspace?.selectSurface(session.id)
            coordinator.chooseChat(!session.showChat, session: session)
        } label: {
            ChatModeSwitchLabel()
                .foregroundStyle(session.showChat ? theme.accent : theme.muted)
                .background {
                    // Borderless in a strip; floating over terminal text it keeps a ground to stay legible.
                    // On glass the capsule below is the ground and answers the pointer itself.
                    if LiquidGlassStore.shared.active {
                    } else if floating && !session.showChat {
                        RoundedRectangle(cornerRadius: 5).fill(theme.ink.opacity(0.06))
                    } else if hovering {
                        RoundedRectangle(cornerRadius: 5).fill(Chrome.palette.hover)
                    }
                }
                .stripGlassButton()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.showChat ? "Show Terminal" : "Show Chat")
        .accessibilityValue(session.showChat ? "Chat selected" : "Terminal selected")
        .disabled(!session.showChat && !coordinator.canEnterChat(session))
        .help(session.showChat ? "Show terminal" : coordinator.chatAvailabilityHint(session))
        .opacity(floating && typing && !hovering ? 0.4 : 1)
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: InterfaceMotion.modeSwitchDuration), value: session.showChat)
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.15), value: typing && !hovering)
        .onHover { hovering = $0 }
        // Only a floating switch dims while typing; a strip's must not re-render on every keystroke.
        .task(id: floating ? session.lastInputAt : nil) {
            guard floating, let date = session.lastInputAt, Date().timeIntervalSince(date) < 1.2 else { typing = false; return }
            typing = true
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            typing = false
        }
        .accessibilityIdentifier("chat-mode-switch")
    }
}

private struct ChatModeSwitchLabel: View {
    @Environment(\.appTypography) private var typography
    var body: some View {
        // Same glyph size and height as the layout picker, so the strip's icons scale together.
        Image(systemName: "text.bubble").font(.system(size: typography.tabSize))
            .padding(.horizontal, 7).frame(minHeight: typography.expanded(22))
    }
}

/// Holds a tab strip's switch position on tabs without Chat, as wide as the
/// switch, so switching tabs does not shift the strip.
struct ChatModeSwitchSlot: View {
    /// In a lone glass strip's button pill an empty slot would leave a hole: the switch shows dimmed and inert instead.
    var dimmed = false
    var body: some View {
        if TerminalRuntime.shared.chat.enabled {
            if dimmed {
                ChatModeSwitchLabel().opacity(0.35).foregroundStyle(Chrome.muted)
                    .stripGlassButton().fixedSize()
                    .help("Chat is not available for this tab").accessibilityLabel("Chat unavailable")
            } else {
                ChatModeSwitchLabel().stripGlassButton().fixedSize().hidden().accessibilityHidden(true)
            }
        }
    }
}
