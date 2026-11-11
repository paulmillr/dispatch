import SwiftUI

// The mode button (`TabModeButton`), the Mac strip's on the phone: its states, as the header (TitleCapsule.swift)
// draws it, and the terminal and key bar the tab screens show. Chat shown: the Chat capsule filled in the accent. An
// agent's tab in Terminal: the capsule's outline (where the tab would go). A shell's tab in Terminal: the folder's.
// Files shown: the folder filled. A tap opens the modes menu.

enum ModeShown { case terminal, chat, files }

/// What the button draws (`ModeSwitchState.glyph` and `.lit` on the Mac).
struct ModeButtonState {
    let shown: ModeShown
    /// An agent runs or ran in the tab.
    let agent: Bool
    /// On Files, the mode shown: the button's glyph names it (Files' modes are in its menu, `TabModeButton`).
    var filesMode: FilesTabMode = .files
    var symbol: String {
        switch shown {
        case .chat: "dispatch.chat"
        case .files: filesMode.symbol
        case .terminal: agent ? "dispatch.chat" : "folder"
        }
    }
    var lit: Bool { shown != .terminal }
    /// The glyph as drawn: filled when lit, where the symbol has a filled form (`TabModeButton.filled`).
    var drawn: String { lit ? Self.filled(symbol) : symbol }

    static func filled(_ symbol: String) -> String {
        if symbol.hasPrefix("dispatch.") { return symbol + ".fill" }
        return UIImage(systemName: symbol + ".fill") == nil ? symbol : symbol + ".fill"
    }
}

struct KeyBar: View {
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
struct AgentTerminalMock: View {
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

/// The mode button as the app draws it (`TabModeButton`): a bar item, its glyph filled in the accent while Chat or Files
/// shows, the outline in the label colour in Terminal (naming where the tab would go). A tap opens the modes menu.
struct ModeToggle: View {
    let state: ModeButtonState
    var body: some View {
        Button {} label: {
            Image(symbol: state.drawn)
                .foregroundStyle(state.lit ? Color.dispatchPink : Color.primary)
        }
    }
}
