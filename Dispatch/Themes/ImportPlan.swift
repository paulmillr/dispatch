import Foundation

/// What importing another terminal's settings would change, shown in Settings › Extra before anything is applied.
/// The importers only read and describe; the Extra tab saves the themes, then applies the chosen changes.
struct ImportPlan {
    /// One setting the import would set, e.g. "Terminal font" → "JetBrains Mono".
    struct Change: Identifiable {
        let id = System.uuid()
        /// The Settings label it changes ("Terminal font", "Cursor", "Shell"…).
        let setting: String
        /// The new value as Settings shows it.
        let value: String
        let apply: (inout Preferences) -> Void
    }

    /// A color scheme the import brings, saved as a custom theme.
    struct Theme {
        /// The name it is saved under (made unique when saved).
        var name: String
        var theme: TerminalTheme
        /// Which of Settings' schemes it becomes: the light one, the dark one, both (the app theme isn't automatic,
        /// or the source had one scheme for both), or none (saved only).
        var role: Role
        /// Saved under exactly `name`, replacing a theme of that name (a Dispatch export, whose settings name it).
        var keepsName = false
        enum Role { case light, dark, both, none }
    }

    /// Where it came from, e.g. "Ghostty", "iTerm2 · Default", "Terminal · Clear Dark".
    var source: String
    var changes: [Change] = []
    var themes: [Theme] = []
    /// What the source sets that Dispatch can't take, said briefly: "background-blur (terminal opacity only)".
    var skipped: [String] = []

    var isEmpty: Bool { changes.isEmpty && themes.isEmpty }
}

