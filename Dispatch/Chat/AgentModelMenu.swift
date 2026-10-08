import Foundation

enum AgentMenuKey: String, Sendable {
    case up = "Up", down = "Down", enter = "Enter", escape = "Escape"
    case end = "C-e", clearLine = "C-u", interrupt = "C-c"
    case left = "Left", right = "Right", thisSession = "s"
}

/// A structural adapter for the Codex TUI's live model menu. Choices
/// and descriptions come from the running agent, including custom providers.
struct AgentModelMenu: Equatable {
    struct Selection: Equatable {
        let model: String
        let effort: String?
    }
    static func selection(_ screen: String) -> Selection? {
        guard let line = screen.components(separatedBy: .newlines).last(where: { $0.contains("Model changed to ") }),
              let range = line.range(of: "Model changed to ") else { return nil }
        var value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        for suffix in [" for this conversation", " for this session only", " for Plan mode.", " for Default mode."] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        let parts = value.split(separator: " ")
        guard (1...2).contains(parts.count) else { return nil }
        let effort = parts.count == 2 ? String(parts[1]) : ""
        guard ["", "default", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(effort) else { return nil }
        return Selection(model: String(parts[0]), effort: effort.isEmpty || effort == "default" ? nil : effort)
    }
    static func isFooter(_ line: String) -> Bool {
        line.contains("esc to go back") || (line.hasPrefix("enter ") && line.hasSuffix(" · esc back"))
    }
    enum Kind: Equatable {
        case quickModels, models, effort(String), advanced, scope
        var isModelList: Bool { self == .models || self == .quickModels }
    }
    struct Choice: Identifiable, Equatable {
        let number: Int
        let name: String
        let detail: String
        let current: Bool
        let isDefault: Bool
        var effortValue: String? = nil
        var id: String { name }
        var effort: String? {
            if let effortValue { return effortValue }
            return switch name.lowercased() {
            case "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "ultracode": name.lowercased()
            case "extra high": "xhigh"
            default: nil
            }
        }
    }
    let kind: Kind
    let choices: [Choice]
    let selected: String
    private static let rowPattern = try! NSRegularExpression(pattern: #"^(›\s*)?(\d{1,3})\.\s+(.+)$"#)
    private static let columns = try! NSRegularExpression(pattern: #"\s{2,}"#)

    init?(_ screen: String) {
        guard screen.utf8.count <= 65_536 else { return nil }
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.lastIndex(where: {
            $0 == "Select Model" || $0 == "Select Model and Effort" || $0.hasPrefix("Select Reasoning Level for ")
                || $0 == "Advanced Reasoning" || $0 == "Apply reasoning change"
        }), lines[(start + 1)...].contains(where: Self.isFooter) else { return nil }
        let title = lines[start]
        if title.hasPrefix("Select Reasoning Level for ") { kind = .effort(String(title.dropFirst(27))) }
        else if title == "Advanced Reasoning" { kind = .advanced }
        else if title == "Apply reasoning change" { kind = .scope }
        else { kind = title == "Select Model" ? .quickModels : .models }
        var choices: [Choice] = [], selected: String?
        for line in lines.dropFirst(start + 1).prefix(160) {
            guard let match = Self.rowPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let numberRange = Range(match.range(at: 2), in: line), let number = Int(line[numberRange]),
                  let contentRange = Range(match.range(at: 3), in: line) else { continue }
            let content = String(line[contentRange])
            let parts = content.components(separatedBy: Self.columns)
            let label = parts[0]
            let name = label.replacingOccurrences(of: " (current)", with: "").replacingOccurrences(of: " (default)", with: "")
            guard !name.isEmpty, name.count < 150 else { return nil }
            choices.append(Choice(number: number, name: name, detail: parts.dropFirst().joined(separator: " "),
                                  current: label.contains("(current)"), isDefault: label.contains("(default)")))
            if match.range(at: 1).location != NSNotFound { selected = name }
        }
        guard !choices.isEmpty, choices.count <= 100, Set(choices.map(\.id)).count == choices.count, let selected else { return nil }
        self.choices = choices; self.selected = selected
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        var parts: [String] = [], offset = startIndex
        for match in regex.matches(in: self, range: NSRange(startIndex..., in: self)) {
            guard let range = Range(match.range, in: self) else { continue }
            parts.append(String(self[offset..<range.lowerBound])); offset = range.upperBound
        }
        parts.append(String(self[offset...])); return parts
    }
}
