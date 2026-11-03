import SwiftUI

// Agent marks: Codex's angle brackets in the primary colour read as text beside Claude's coral sparkle, so a Codex
// tab looks unmarked. Each style gives every agent a mark of the same weight. The app took Y5 (one secondary text
// bubble for every agent's chat, `AgentGlyph` in Mobile/App/MobileChrome.swift), now every screen's default; Y0 is
// the marks it had before.

enum AgentIconStyle: String, CaseIterable {
    /// The marks before Y5: Claude coral, Codex in the text colour, Pi purple, the shell secondary.
    case today
    /// Every agent its own colour, semibold: Codex in teal.
    case tinted
    /// A filled rounded square per agent with the mark knocked out in white; the shell's tile grey.
    case tiles
    /// A soft disc of the agent's colour behind the mark in that colour, as Reminders' lists draw theirs.
    case soft
    /// One monochrome mark for every agent's chat: the Chat segment's text bubble, secondary as the shell's terminal.
    case chatTextBubble
    /// The same in the text colour, so a chat stands apart from the secondary shells.
    case chatTextBubblePrimary
    /// A plain bubble.
    case chatBubble
    /// Two bubbles, a conversation.
    case chatConversation

    static let marks: [AgentIconStyle] = [.today, .tinted, .tiles, .soft]
    static let chats: [AgentIconStyle] = [.chatTextBubble, .chatTextBubblePrimary, .chatBubble, .chatConversation]

    /// The chat symbol of a single-mark style.
    var chatSymbol: String? {
        switch self {
        case .chatTextBubble, .chatTextBubblePrimary: "text.bubble"
        case .chatBubble: "bubble.left"
        case .chatConversation: "bubble.left.and.text.bubble.right"
        default: nil
        }
    }

    var title: String {
        switch self {
        case .today: "Marks (before)"
        case .tinted: "Tinted marks"
        case .tiles: "Filled tiles"
        case .soft: "Soft discs"
        case .chatTextBubble: "Text bubble, secondary"
        case .chatTextBubblePrimary: "Text bubble, primary"
        case .chatBubble: "Bubble"
        case .chatConversation: "Conversation"
        }
    }
}

extension EnvironmentValues {
    @Entry var agentIconStyle: AgentIconStyle = .chatTextBubble
}

enum AgentMark {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    /// Codex's colour once it has one: a teal, apart from Dispatch pink, Pi's purple and the state dots (the unread
    /// dot is blue, so a blue Codex mark reads as a second dot).
    static let codex = Color(red: 0.13, green: 0.62, blue: 0.62)

    static func color(_ kind: String) -> Color {
        switch kind {
        case "claude": claude
        case "codex": codex
        case "pi": .codeType
        default: .secondary
        }
    }
}

/// One agent's mark in a style, 26 points wide as the rows lay it out.
struct StyledAgentGlyph: View {
    let kind: String
    let style: AgentIconStyle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch style {
            case .today: today
            case .chatTextBubble, .chatTextBubblePrimary, .chatBubble, .chatConversation:
                if kind == "terminal" {
                    today
                } else {
                    Image(systemName: style.chatSymbol!)
                        .font(.system(size: style == .chatConversation ? 15 : 18))
                        .foregroundStyle(style == .chatTextBubblePrimary ? Color.primary : Color.secondary)
                }
            case .tinted: mark(weight: .semibold).foregroundStyle(kind == "terminal" ? Color.secondary : AgentMark.color(kind))
            case .tiles:
                mark(size: 14, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(tileFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            case .soft:
                mark(size: 14, weight: .semibold)
                    .foregroundStyle(kind == "terminal" ? Color.secondary : AgentMark.color(kind))
                    .frame(width: 28, height: 28)
                    .background((kind == "terminal" ? Color.gray : AgentMark.color(kind)).opacity(scheme == .dark ? 0.24 : 0.16), in: Circle())
            }
        }
        .frame(width: 26)
    }

    private var tileFill: Color {
        switch kind {
        case "terminal": Color(uiColor: .systemGray2)
        default: AgentMark.color(kind)
        }
    }

    @ViewBuilder private var today: some View {
        switch kind {
        case "claude": Image(systemName: "sparkle").foregroundStyle(AgentMark.claude).font(.system(size: 18))
        case "codex": Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.primary).font(.system(size: 18))
        case "pi": Text("π").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(Color.codeType)
        default: Image(systemName: "apple.terminal").foregroundStyle(.secondary).font(.system(size: 18))
        }
    }

    @ViewBuilder private func mark(size: CGFloat = 18, weight: Font.Weight) -> some View {
        switch kind {
        case "claude": Image(systemName: "sparkle").font(.system(size: size, weight: weight))
        case "codex": Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: size - 2, weight: weight))
        case "pi": Text("π").font(.system(size: size + 1, weight: .bold, design: .serif))
        default: Image(systemName: "apple.terminal").font(.system(size: size - 1, weight: weight))
        }
    }
}

/// Y0–Y3: the space screen with New tab held, in one style.
struct AgentIconsSpaceScreen: View {
    let style: AgentIconStyle
    var body: some View {
        SpaceScreen(newTabMenu: true).environment(\.agentIconStyle, style)
    }
}

/// Y4: every style side by side: the four marks at row size, a Codex tab row, and the iPad strip's pills.
struct AgentIconsCompareScreen: View {
    var styles = AgentIconStyle.marks
    var title = "Agent icons"
    private let kinds = ["claude", "codex", "pi", "terminal"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(styles, id: \.self) { style in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(style.title).font(.footnote).textCase(.uppercase).foregroundStyle(.secondary).padding(.leading, 16)
                            VStack(spacing: 0) {
                                HStack(spacing: 0) {
                                    ForEach(kinds, id: \.self) { kind in
                                        VStack(spacing: 6) {
                                            StyledAgentGlyph(kind: kind, style: style)
                                            Text(kind == "terminal" ? "Shell" : kind.capitalized).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                                .padding(.vertical, 12)
                                Hairline(inset: 0)
                                row(style, kind: "codex", name: "Rate limiter for the API", line: "Allow cargo test --workspace?", dot: .stateUnread)
                                Hairline(inset: 0)
                                HStack(spacing: 8) {
                                    pill(style, kind: "claude", name: "Sidebar theme")
                                    pill(style, kind: "codex", name: "Rate limiter")
                                    pill(style, kind: "terminal", name: "zsh")
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                            }
                            .background(Color.groupedRow)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .padding(.horizontal, 16)
                        }
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.top, 8)
            }
            .background(Color.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ style: AgentIconStyle, kind: String, name: String, line: String, dot: Color) -> some View {
        HStack(spacing: 12) {
            Circle().fill(dot).frame(width: 10, height: 10).frame(width: 14)
            StyledAgentGlyph(kind: kind, style: style)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).lineLimit(1)
                Text(line).font(.subheadline).foregroundStyle(dot == .stateUnread ? Color.primary : .secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 11)
    }

    private func pill(_ style: AgentIconStyle, kind: String, name: String) -> some View {
        HStack(spacing: 4) {
            StyledAgentGlyph(kind: kind, style: style).scaleEffect(0.75).frame(width: 18)
            Text(name).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(Color.chipFill, in: Capsule())
    }
}
