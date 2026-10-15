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
            ChatModeSwitchLabel(chat: session.showChat)
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
    /// Which side Nautical's segments mark; nil marks neither (a slot's placeholder).
    var chat: Bool? = nil
    var body: some View {
        if SidebarThemeStore.shared.current == .nautical {
            // Nautical names both sides: the terminal is the deck, chat the radio. On Liquid Glass the strip's glass is
            // its ground and the selected side a capsule nested in the pill; flat, a bordered well with square segments.
            let glass = LiquidGlassStore.shared.active
            HStack(spacing: 2) {
                segment("deck", symbol: "terminal", on: chat == false, glass: glass)
                segment("radio", symbol: "antenna.radiowaves.left.and.right", on: chat == true, glass: glass)
            }
            .padding(.horizontal, glass ? 3 : 2).padding(.vertical, glass ? 0 : 2)
            .background { if !glass { RoundedRectangle(cornerRadius: 5).fill(Chrome.window) } }
            .overlay { if !glass { RoundedRectangle(cornerRadius: 5).strokeBorder(Chrome.border) } }
            .frame(minHeight: typography.expanded(22))
        } else {
            // Same glyph size and height as the layout picker, so the strip's icons scale together.
            Image(systemName: "text.bubble").font(.system(size: typography.tabSize))
                .padding(.horizontal, 7).frame(minHeight: typography.expanded(22))
        }
    }

    private func segment(_ title: String, symbol: String, on: Bool, glass: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: typography.size(offset: -3)))
            Text(title)
        }
        .font(HarbourType.mono(typography.size(offset: -2)))
        .foregroundStyle(on ? Chrome.ink : Chrome.muted)
        .padding(.horizontal, glass ? 9 : 7)
        // On glass, 3 points inside the 28-point track all round, as the selected tab's pill sits in its track.
        .frame(height: glass ? StripTab.glassTrackHeight(typography) - 6 : typography.expanded(18))
        .background {
            if on {
                if glass { Capsule().fill(Chrome.ink.opacity(Chrome.palette.isDark ? 0.14 : 0.09)) }
                else { RoundedRectangle(cornerRadius: 3).fill(Chrome.palette.control) }
            }
        }
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
