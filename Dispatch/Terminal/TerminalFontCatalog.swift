import Foundation

/// The terminal fonts shipped by both apps. Discovery of installed fonts and registration stay with each app.
enum TerminalFontCatalog {
    struct Entry: Sendable {
        let family: String
        /// Some bundled faces do not advertise fixed pitch, but still belong in the Mac's terminal picker.
        var listedExplicitly = false
    }

    static let defaultFamily = "Source Code Pro"
    static let fallbackFamily = "JetBrains Mono"
    static let bundled: [Entry] = [
        Entry(family: "0xProto"),
        Entry(family: "Cascadia Code", listedExplicitly: true),
        Entry(family: "CommitMono", listedExplicitly: true),
        Entry(family: "Departure Mono"),
        Entry(family: "Fira Code"),
        Entry(family: "Geist Mono", listedExplicitly: true),
        Entry(family: "Hack", listedExplicitly: true),
        Entry(family: "Hasklig", listedExplicitly: true),
        Entry(family: "IBM Plex Mono", listedExplicitly: true),
        Entry(family: "Inconsolata", listedExplicitly: true),
        Entry(family: "Intel One Mono", listedExplicitly: true),
        Entry(family: "Ioskeley Mono Term"),
        Entry(family: fallbackFamily),
        Entry(family: "Latin Modern Mono", listedExplicitly: true),
        Entry(family: "Maple Mono", listedExplicitly: true),
        Entry(family: "Rec Mono Casual", listedExplicitly: true),
        Entry(family: defaultFamily),
        Entry(family: "Victor Mono", listedExplicitly: true),
    ]
}
