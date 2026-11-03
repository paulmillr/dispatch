import SwiftUI

// Agent marks: the app took Y5, one secondary text bubble for every agent's chat (`AgentGlyph` in
// Mobile/App/MobileChrome.swift), every screen's default. A shell keeps the terminal glyph.

enum AgentIconStyle: String, CaseIterable {
    /// One monochrome mark for every agent's chat: the Chat segment's text bubble, secondary as the shell's terminal.
    case chatTextBubble
    /// N1's capsule with a tail (`NewModeGlyph.pill`), secondary as the shell's terminal.
    case chatPill
}

extension EnvironmentValues {
    @Entry var agentIconStyle: AgentIconStyle = .chatTextBubble
}

/// One agent's mark in a style, 26 points wide as the rows lay it out.
struct StyledAgentGlyph: View {
    let kind: String
    let style: AgentIconStyle

    var body: some View {
        Group {
            if kind == "terminal" {
                Image(systemName: "apple.terminal").foregroundStyle(.secondary).font(.system(size: 18))
            } else {
                switch style {
                case .chatTextBubble: Image(systemName: "text.bubble").font(.system(size: 18)).foregroundStyle(.secondary)
                case .chatPill: NewModeGlyphView(glyph: .pill, lit: false, size: 22, tint: .secondary)
                }
            }
        }
        .frame(width: 26)
    }
}

/// Y5 and N6: the space screen in one style, with New tab held.
struct AgentIconsSpaceScreen: View {
    let style: AgentIconStyle
    var menu = true
    var body: some View {
        SpaceScreen(newTabMenu: menu).environment(\.agentIconStyle, style)
    }
}
