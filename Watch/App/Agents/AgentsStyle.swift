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
    /// `Added` (`StateFinished`) in dark: a step that finished.
    static let added = WatchDots.connected
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

/// The agent's mark on an Agents row, in its host's tint (the phone's rows draw the host's glyph in a disc,
/// `WatchHostMark`; a watch row has no room for the disc, and the agent tells rows apart better).
enum AgentsGlyph {
    /// Claude's asterisk, Codex's braces, Pi's π, a terminal otherwise.
    enum Mark: Equatable {
        case symbol(String)
        case letter(String)
    }

    static func agent(_ agent: String?) -> Mark {
        switch agent?.lowercased() {
        case "claude"?: .symbol("asterisk")
        case "codex"?: .symbol("curlybraces")
        case "pi"?: .letter("π")
        default: .symbol("terminal")
        }
    }
}
