import SwiftUI

// Agent marks, as the app draws them (`AgentGlyph` in Mobile/App/MobileChrome.swift): every agent's chat the Chat
// capsule (`dispatch.chat`, the app's own symbol in the shared asset catalog), a shell the terminal glyph, both
// secondary.

/// One tab's mark, 26 points wide as the rows lay it out.
struct AgentMark: View {
    let kind: String

    var body: some View {
        Image(symbol: kind == "terminal" ? "apple.terminal" : "dispatch.chat")
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
            .frame(width: 26)
    }
}
