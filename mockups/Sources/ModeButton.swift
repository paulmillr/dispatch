import SwiftUI

// B7: the Mac's one mode button on the phone (2026-11-01, shipped as the phone's only header). The Terminal · Chat ·
// Files capsule goes; Back and the host share one capsule on the left (the host's glyph is the tab's menu), the mode
// toggle stands alone on the right and carries the tab's mode as the Mac strip's `ChatModeSwitch` does. Chat shown:
// the bubble, on (the system's selected toggle). An agent's tab in Terminal: the bubble, off (a tap opens chat). A
// shell's tab in Terminal: the folder, off (a tap opens files). Files shown: the folder, on. A tap from Chat or Files
// returns to Terminal.

enum ModeShown { case terminal, chat, files }

/// What the button draws (`ModeSwitchState.glyph` and `.lit` on the Mac).
struct ModeButtonState {
    let shown: ModeShown
    /// An agent runs or ran in the tab.
    let agent: Bool
    var symbol: String {
        switch shown {
        case .chat: "text.bubble"
        case .files: "folder"
        case .terminal: agent ? "text.bubble" : "folder"
        }
    }
    var lit: Bool { shown != .terminal }
}

/// Back and the host's glyph on the left, the title block beside them, the mode toggle alone on the right.
struct ModeTabHeader: ToolbarContent {
    let title: String
    var subtitle: AnyView = AnyView(TabSubtitle())
    let state: ModeButtonState
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {} label: { Image(systemName: "chevron.left").foregroundStyle(Color.dispatchPink) }
                .overlay(alignment: .topTrailing) { CountBadge(label: "2").offset(x: 16, y: -14) }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {} label: { Image(systemName: "apple.logo").foregroundStyle(hostTint) }
        }
        ToolbarItem(placement: .topBarLeading) { titleBlock.padding(.leading, 4).frame(width: 402 - 32 - 104 - 12 - 72, alignment: .leading) }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) {
            ModeToggle(state: state)
        }
    }

    private var titleBlock: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(title).lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.semibold))
        .frame(minHeight: 40, alignment: .topLeading)
    }
}

private struct KeyBar: View {
    var body: some View {
        HStack(spacing: 0) {
            ForEach(["Ctrl", "Esc", "Tab", "Alt"], id: \.self) { k in
                Text(k).font(.system(size: 17, design: .monospaced)).frame(maxWidth: .infinity)
            }
            Image(systemName: "dpad").font(.system(size: 20)).frame(maxWidth: .infinity)
            Image(systemName: "ellipsis").font(.system(size: 20)).frame(maxWidth: .infinity)
            Image(systemName: "keyboard").font(.system(size: 20)).frame(maxWidth: .infinity)
        }
        .frame(height: 50).padding(.horizontal, 8)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 12).padding(.bottom, 4)
    }
}

/// An agent's TUI in its terminal.
private struct AgentTerminalMock: View {
    let lines: [(String, Color)] = [
        ("> Make billing webhook retries idempotent.", .secondary), ("", .primary),
        ("⏺ Stripe retries the same event with a new attempt", .primary), ("  counter, so a counter-based guard can", .primary),
        ("  double-process. Keying on the event id instead.", .primary), ("", .primary),
        ("⏺ Update(src/routes/webhooks.ts)", .primary), ("  ⎿  Updated with 24 additions and 3 removals", .secondary), ("", .primary),
        ("⏺ Update(src/routes/invoices.ts)", .primary), ("  ⎿  Updated with 14 additions and 1 removal", .secondary), ("", .primary),
        ("✻ Running tests… (38s · ↓ 1.2k tokens)", Color.caution), ("", .primary),
        ("╭──────────────────────────────────────────╮", .secondary), ("│ >                                        │", .secondary),
        ("╰──────────────────────────────────────────╯", .secondary), ("  ⏵⏵ accept edits on (shift+tab to cycle)", .secondary),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.0).font(.system(size: 13, design: .monospaced)).foregroundStyle(line.1).lineLimit(1).frame(height: 20)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(Color.black)
    }
}

/// B7: Chat shown, the bubble on.
struct ModeChatScreen: View {
    var body: some View {
        let state = ModeButtonState(shown: .chat, agent: true)
        NavigationStack {
            Transcript()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom) { Composer() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ModeTabHeader(title: "Billing webhook retries", subtitle: AnyView(TabSubtitle(folder: "app")), state: state) }
        }
    }
}

/// B7b: an agent's tab in Terminal, the bubble off: a tap opens its chat.
struct ModeAgentTerminalScreen: View {
    var body: some View {
        let state = ModeButtonState(shown: .terminal, agent: true)
        NavigationStack {
            AgentTerminalMock()
                .safeAreaBar(edge: .bottom) { KeyBar() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ModeTabHeader(title: "Billing webhook retries", subtitle: AnyView(TabSubtitle(folder: "app", shell: "claude")), state: state) }
        }
        // The terminal is black in either scheme; its bar follows it.
        .environment(\.colorScheme, .dark)
    }
}

/// B7c: the four states as the bar draws them.
struct ModeStatesScreen: View {
    private let states: [(String, String, ModeButtonState)] = [
        ("Chat shown", "tap → Terminal", .init(shown: .chat, agent: true)),
        ("Agent, Terminal shown", "tap → Chat", .init(shown: .terminal, agent: true)),
        ("Shell, Terminal shown", "tap → Files", .init(shown: .terminal, agent: false)),
        ("Files shown", "tap → Terminal", .init(shown: .files, agent: false)),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                Text(state.0 + " · " + state.1).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 14).padding(.leading, 20)
                NavigationStack {
                    Color.canvas
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ModeTabHeader(title: "Billing webhook retries", subtitle: AnyView(TabSubtitle(folder: "app")), state: state.2) }
                }
                .frame(height: 62)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.canvas)
    }
}

/// The system's button-style toggle, its glyph primary when off (the app tint would make every bar glyph pink, and off
/// would differ from on by the selection alone).
struct ModeToggle: View {
    let state: ModeButtonState
    var body: some View {
        Toggle(isOn: .constant(state.lit)) {
            Image(systemName: state.symbol).foregroundStyle(state.lit ? Color.dispatchPink : Color.primary)
        }
        .toggleStyle(.button)
    }
}
