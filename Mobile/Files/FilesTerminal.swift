@preconcurrency import Term

extension TerminalPresence {
    /// What Open in Terminal reads of the pane's emulator before it types (`FilesAsk.ready`, `FilesAsk.typing`): whether a
    /// full-screen program holds the screen, and whether the program asked for bracketed paste.
    var filesTypingState: (alternate: Bool, bracketed: Bool) {
        session.locked { (session.surface.terminal.isAlternate, PasteOptions(session.surface.terminal).bracketed) }
    }
}
