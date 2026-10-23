import SwiftUI

/// The phone's named colours (MobileColors, its asset catalog) as the Agents screens use them, in their dark values:
/// the watch is always dark. Kept here, not in an asset catalog, so the phone's catalog stays the one source to compare.
enum AgentsColor {
    /// `StateUnread`: needs you or an unseen result (Mail's blue).
    static let unread = WatchDots.needsYou
    /// `StateWorking`: a running turn.
    static let working = WatchDots.working
    /// `AccentColor`: Allow, the queue's header, the user's bubble in dark.
    static let pink = Color(red: 0xE0 / 255, green: 0x7B / 255, blue: 0xE0 / 255)
    /// `OnAccent`, `BubbleUserText` in dark: text on the pink.
    static let onPink = Color(red: 0x1A / 255, green: 0x12 / 255, blue: 0x18 / 255)
    /// `BubbleAgent` in dark.
    static let agentBubble = Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)
    /// `ApprovalCode` in dark: the approval's command block.
    static let code = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x20 / 255)
    /// `Destructive` in dark: Deny, failed steps.
    static let destructive = Color(red: 0xE0 / 255, green: 0x7B / 255, blue: 0x7B / 255)
    /// `Added` (`StateFinished`) in dark: a step that finished, a turn's added lines.
    static let added = WatchDots.connected
    /// `GroupedRow` in dark: the host card, the review card.
    static let groupedRow = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
    /// `CodeType` in dark: Pi's π.
    static let codeType = Color(red: 0xA9 / 255, green: 0x8A / 255, blue: 0xE0 / 255)
    /// Claude's orange, as the phone's tab rows draw its sparkle.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}

/// The gutter dot of an Agents row (`MobileRowDot`): blue unread, amber working.
enum AgentsDot: Equatable {
    case unread, working

    var color: Color { self == .unread ? AgentsColor.unread : AgentsColor.working }

    /// VoiceOver's word for it, the phone's.
    var accessibilityLabel: String { self == .unread ? "Unread" : "Working" }

    /// The row's dot as the phone draws it: the phone's own, needs you always blue, a muted row only for needs you.
    static func of(_ conversation: WatchConversation) -> AgentsDot? {
        if conversation.needsYou { return .unread }
        if conversation.muted { return nil }
        switch conversation.dot {
        case .unread?: return .unread
        case .working?: return .working
        case .unknown?, nil: return conversation.busy ? .working : nil
        }
    }
}

/// The agent's mark (`AgentGlyph`), as the phone's tab rows draw it: the agent tells rows apart better than the host's
/// disc, which a watch row has no room for (the host's tint goes to the row's "host · space" caption instead).
enum AgentsGlyph {
    /// Claude's sparkle, Codex's angle brackets, Pi's π, a terminal otherwise.
    enum Mark: Equatable {
        case symbol(String)
        case letter(String)
    }

    /// The agent's key ("claude"), or a label naming one ("Claude Code", "Codex"): the thread page names its agent by
    /// label.
    static func key(_ agent: String?) -> String? {
        guard let agent = agent?.lowercased(), !agent.isEmpty else { return nil }
        for known in ["claude", "codex", "pi"] where agent == known || agent.hasPrefix(known + " ") { return known }
        return agent
    }

    static func agent(_ agent: String?) -> Mark {
        switch key(agent) {
        case "claude"?: .symbol("sparkle")
        case "codex"?: .symbol("chevron.left.forwardslash.chevron.right")
        case "pi"?: .letter("π")
        default: .symbol("apple.terminal")
        }
    }

    static func color(_ agent: String?) -> Color {
        switch key(agent) {
        case "claude"?: AgentsColor.claude
        case "codex"?: .primary
        case "pi"?: AgentsColor.codeType
        default: .secondary
        }
    }

    /// The agent's short name for "Codex wants to run": "Claude", "Codex", "Pi", else the label as it is.
    static func shortName(_ agent: String?) -> String? {
        switch key(agent) {
        case "claude"?: "Claude"
        case "codex"?: "Codex"
        case "pi"?: "Pi"
        default: agent
        }
    }
}
