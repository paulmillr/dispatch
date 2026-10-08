import Foundation

/// Structural view of Claude's pending model/effort selection. No model catalog
/// is baked into Dispatch, and Enter (which changes defaults) is never used.
struct ClaudeModelMenu: Equatable {
    let choices: [AgentModelMenu.Choice]
    let selected: String
    let effort: String?
    let count: Int?
    private static let row = try! NSRegularExpression(pattern: #"^(?:(❯)|[↑↓])?\s*(\d{1,3})\.\s+(.+)$"#)
    private static let gap = try! NSRegularExpression(pattern: #"\s{2,}"#)
    private static let overflow = try! NSRegularExpression(pattern: #"^… \+(\d{1,3}) models?$"#)
    private static let effortPattern = try! NSRegularExpression(pattern: #"(?:^|\s)([a-zA-Z][a-zA-Z0-9-]*) effort\b"#)

    init?(_ screen: String) {
        guard screen.utf8.count <= 65_536 else { return nil }
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.lastIndex(of: "Select model"),
              let footer = lines.lastIndex(where: { $0.contains("s to use this session only") && $0.contains("Esc to cancel") }), footer > start,
              lines.dropFirst(footer + 1).allSatisfy({ $0.isEmpty || $0.allSatisfy { "─▔".contains($0) } }) else { return nil }
        var choices: [AgentModelMenu.Choice] = [], selected: String?, effort: String?
        var hidden: Int?
        for line in lines[(start + 1)..<footer] {
            let range = NSRange(line.startIndex..., in: line)
            if let match = Self.row.firstMatch(in: line, range: range),
               let numberRange = Range(match.range(at: 2), in: line), let number = Int(line[numberRange]),
               let contentRange = Range(match.range(at: 3), in: line) {
                let content = String(line[contentRange])
                let gap = Self.gap.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)).flatMap { Range($0.range, in: content) }
                let label = gap.map { String(content[..<$0.lowerBound]) } ?? content
                let name = label.replacingOccurrences(of: "✔", with: "").replacingOccurrences(of: " (recommended)", with: "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name.count < 150 else { return nil }
                choices.append(.init(number: number, name: name, detail: gap.map { String(content[$0.upperBound...]) } ?? "",
                                     current: label.contains("✔"), isDefault: label.contains("(recommended)")))
                if match.range(at: 1).location != NSNotFound { selected = name }
            } else if let match = Self.effortPattern.firstMatch(in: line, range: range), let value = Range(match.range(at: 1), in: line) {
                effort = String(line[value]).lowercased()
            } else if let match = Self.overflow.firstMatch(in: line, range: range), let value = Range(match.range(at: 1), in: line) {
                hidden = Int(line[value])
            }
        }
        let clipped = lines[(start + 1)..<footer].contains { $0.hasPrefix("↑") || $0.hasPrefix("↓") }
        let total = choices.count + (hidden ?? 0)
        count = (hidden != nil || !clipped) && total <= 100 && choices.allSatisfy({ (1...max(1, total)).contains($0.number) }) ? total : nil
        guard !choices.isEmpty, choices.count <= 100, Set(choices.map(\.name)).count == choices.count,
              Set(choices.map(\.number)).count == choices.count, let selected,
              choices.filter(\.current).count <= 1,
              count != choices.count || choices.contains(where: \.current) else { return nil }
        self.choices = choices; self.selected = selected; self.effort = effort
    }

    /// Rows name aliases ("Opus"); the detail names the model ("Opus 5.5 · …").
    /// Returns Claude's undated model ID for it, e.g. claude-opus-5-5.
    static func modelID(detail: String) -> String? {
        let pattern = #"^([A-Za-z]+) ([0-9]+(?:\.[0-9]+)*)(?:\s+·|$)"#
        guard let match = detail.range(of: pattern, options: .regularExpression) else { return nil }
        let words = detail[match].split(separator: " ")
        guard words.count >= 2 else { return nil }
        return "claude-" + words[0].lowercased() + "-" + words[1].replacingOccurrences(of: ".", with: "-")
    }

    /// Stronger efforts first; unknown values keep Claude's order after them.
    static func sortedEfforts(_ values: [String]) -> [String] {
        let rank = ["ultracode", "ultra", "max", "xhigh", "high", "medium", "low", "minimal", "none"]
        return values.enumerated().sorted { lhs, rhs in
            let l = rank.firstIndex(of: lhs.element.lowercased()) ?? rank.count
            let r = rank.firstIndex(of: rhs.element.lowercased()) ?? rank.count
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    /// The composer's top border. A named session (/rename) labels it, as in "──── design ─".
    static func isComposerTopBorder(_ line: String) -> Bool {
        guard line.first == "─", line.last == "─" else { return false }
        let label = line.trimmingCharacters(in: CharacterSet(charactersIn: "─"))
        return label.isEmpty || (label.hasPrefix(" ") && label.hasSuffix(" ") && !label.contains("─"))
    }

    static func isEmptyComposer(_ screen: String, allowWorking: Bool = false) -> Bool {
        guard screen.utf8.count <= 65_536 else { return false }
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        func rule(_ line: String) -> Bool { !line.isEmpty && line.allSatisfy { $0 == "─" } }
        // Menus, dialogs, and multiline drafts replace the bordered composer.
        guard let prompt = lines.lastIndex(where: { $0.hasPrefix("❯") }), prompt >= 1, prompt + 1 < lines.count,
              lines[prompt] == "❯", isComposerTopBorder(lines[prompt - 1]), rule(lines[prompt + 1]) else { return false }
        // Below it Claude draws a configured status line, the mode footer, and
        // notices whose text and wrapping vary by release and width. Only the
        // footer is required; another prompt or box below is not a composer.
        let below = lines.dropFirst(prompt + 2)
        return !below.contains(where: rule) && below.contains { line in
            // A working footer also lists agents; it counts only when steering.
            if line.contains("esc to interrupt") { return allowWorking }
            // Claude retains this paste hint after accepting a multiline paste.
            return line.contains("for shortcuts") || line.contains("for agents") || line == "paste again to expand"
                || line.range(of: #"← [0-9]+ agents?(\s|$)"#, options: .regularExpression) != nil
        }
    }

    static func removingPlaceholder(_ screen: String, column: Int, row: Int, faint: Bool) -> String {
        guard faint else { return screen }
        var lines = screen.components(separatedBy: .newlines)
        guard lines.indices.contains(row) else { return screen }
        let line = lines[row], prefix = String(line.prefix(column))
        // Generated suggestions have the same faint style as static placeholders.
        guard prefix.trimmingCharacters(in: .whitespaces) == "❯" else { return screen }
        lines[row] = prefix
        let result = lines.joined(separator: "\n")
        return isEmptyComposer(result) ? result : screen
    }
}

/// Claude writes no model to its transcript before the first reply. Its startup
/// banner ("Opus 5.5 with high effort · …") and live footer ("● high · /effort")
/// are the only pre-reply source. The banner is trusted only before any input
/// echo, since a terminal /model does not redraw it.
struct ClaudeStartupConfiguration: Equatable {
    let model: String?
    let effort: String?
    private static let version = try! NSRegularExpression(pattern: #"^[^A-Za-z]*Claude Code v[0-9]"#)
    private static let banner = try! NSRegularExpression(pattern: #"^[^A-Za-z]*([A-Za-z]+ [0-9]+(?:\.[0-9]+)*)(?: \([^)]*\))?(?: with ([a-z]+) effort)? · "#)
    private static let footer = try! NSRegularExpression(pattern: #"(?:^|\s)\S ([a-z]+) · /effort$"#)

    init?(_ screen: String) {
        guard screen.utf8.count <= 65_536 else { return nil }
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        func match(_ pattern: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
            pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        }
        func group(_ result: NSTextCheckingResult, _ index: Int, _ line: String) -> String? {
            Range(result.range(at: index), in: line).map { String(line[$0]) }
        }
        guard let start = lines.firstIndex(where: { match(Self.version, $0) != nil }),
              let prompt = lines.lastIndex(where: { $0.hasPrefix("❯") }), prompt > start + 2,
              ClaudeModelMenu.isComposerTopBorder(lines[prompt - 1]),
              !lines[(start + 2)..<prompt - 1].contains(where: { $0.hasPrefix("❯") }) else { return nil }
        let line = lines[start + 1]
        let banner = match(Self.banner, line)
        model = banner.flatMap { group($0, 1, line) }.flatMap(ClaudeModelMenu.modelID(detail:))
        let live = lines[(prompt + 1)...].reversed().lazy.compactMap { line in match(Self.footer, line).flatMap { group($0, 1, line) } }.first
        effort = live ?? banner.flatMap { group($0, 2, line) }
        if model == nil && effort == nil { return nil }
    }
}

struct ClaudeModelConfirmation: Equatable {
    let title: String
    let choices: [AgentModelMenu.Choice]
    let selected: String
    let detail: String
    init?(_ screen: String) {
        guard screen.utf8.count <= 65_536 else { return nil }
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.lastIndex(where: { ["Switch model?", "Change effort level?"].contains($0) }),
              lines.dropFirst(start + 1).contains(where: { ["Your next response will be slower and use more tokens", "A PreModelSwitch hook asked you to confirm"].contains($0) }) else { return nil }
        let rows = lines.dropFirst(start + 1).filter { $0.hasPrefix("❯ ") || $0.hasPrefix("1. ") || $0.hasPrefix("2. ") }
        guard rows.count == 2, let yes = rows.first, let no = rows.last,
              yes.replacingOccurrences(of: "❯ ", with: "").hasPrefix("1. Yes, switch to "),
              no.replacingOccurrences(of: "❯ ", with: "") == "2. No, go back",
              lines.last(where: { !$0.isEmpty }) == no,
              rows.filter({ $0.hasPrefix("❯ ") }).count == 1 else { return nil }
        choices = rows.enumerated().map { index, row in
            .init(number: index + 1, name: String(row.replacingOccurrences(of: "❯ ", with: "").dropFirst(3)), detail: "", current: false, isDefault: false)
        }
        selected = choices[yes.hasPrefix("❯ ") ? 0 : 1].name
        title = lines[start]
        detail = lines.dropFirst(start + 1).prefix(while: { $0 != yes }).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
