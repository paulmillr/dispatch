import Foundation

/// A release's notes as the updater shows them (the sheet and Settings › Updates; mockups U1–U4): the GitHub release's
/// text before its first `---` line (what follows is how to install and check it), its `- ` or `* ` items, the first
/// five. `area: text` tags an item when the area is one word of at most 12 characters; the tag shows in a spelling of
/// its own (`display`). Read from GitHub's API for that release's tag, once a newer release is found.
struct UpdateNotes: Equatable, Sendable {
    struct Change: Equatable, Sendable {
        /// The tag as shown ("Chat", "SSH"), or nil for an item without one.
        let area: String?
        let text: String
    }

    let version: String
    let changes: [Change]

    static let limit = 5
    /// The API's answer for one release: its notes are at most 125,000 characters.
    static let sizeLimit: Int64 = 512 * 1024

    init(version: String, changes: [Change]) {
        self.version = version
        self.changes = changes
    }

    /// The items of `body` (the release's notes as written; GitHub keeps them with CRLF line ends).
    init(version: String, body: String) {
        var items: [Change] = []
        for raw in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" { break }
            guard line.hasPrefix("* ") || line.hasPrefix("- ") else { continue }
            let item = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            if let colon = item.range(of: ": "), case let area = item[..<colon.lowerBound],
               (1...12).contains(area.count), area.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                let text = item[colon.upperBound...].trimmingCharacters(in: .whitespaces)
                items.append(Change(area: Self.display(String(area)), text: text.isEmpty ? item : text))
            } else {
                items.append(Change(area: nil, text: item))
            }
            if items.count == Self.limit { break }
        }
        self.init(version: version, changes: items)
    }

    /// The release's JSON from GitHub's API: its notes, once it is that version's published release.
    init(version: String, release json: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              object["tag_name"] as? String == version, object["draft"] as? Bool != true else {
            throw UpdateFailure("The release notes have an unsupported format.")
        }
        self.init(version: version, body: object["body"] as? String ?? "")
    }

    /// Areas written in lower case ("ssh: …") as they are spelled; any other word with its first letter raised.
    static func display(_ area: String) -> String {
        let known = ["ssh": "SSH", "ux": "UX", "ui": "UI", "ios": "iOS", "iphone": "iPhone", "ipad": "iPad", "macos": "macOS",
                     "mac": "Mac", "tmux": "tmux", "herdr": "herdr", "git": "Git", "pi": "Pi", "ai": "AI", "api": "API"]
        if let spelled = known[area.lowercased()] { return spelled }
        return area.prefix(1).uppercased() + area.dropFirst()
    }

    /// GitHub's API for the release tagged `version` (the tag is the version, `scripts/release-publish.sh`).
    static func api(_ version: String) -> URL {
        URL(string: "https://api.github.com/repos/paulmillr/dispatch/releases/tags/\(version)")!
    }

    /// The release's page, which the sheet's Release notes opens.
    static func page(_ version: String) -> URL {
        URL(string: "https://github.com/paulmillr/dispatch/releases/tag/\(version)")!
    }
}
