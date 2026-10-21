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

/// How chat names a model, on the Mac and the iPhone alike.
extension AgentModelMenu {
    /// Family, then version: claude-opus-5-5[1m] → opus-5.5[1m], gpt-6.1-sol → sol-6.1. Also covers dated, legacy
    /// (claude-3-5-sonnet), Bedrock (us.anthropic.claude-…-v1:0), Vertex (…@20250805) and provider/model IDs; other
    /// models keep their ID, without the provider.
    static func label(for model: String) -> String {
        let plain = model.split(separator: "/").last.map(String.init) ?? model
        guard let vendor = model.range(of: "(?:^|[./])(?:claude|gpt)-", options: .regularExpression) else { return plain }
        var id = String(model[vendor.upperBound...]), suffix = ""
        if let bracket = id.firstIndex(of: "[") { suffix = String(id[bracket...]); id = String(id[..<bracket]) }
        id = id.replacingOccurrences(of: "(?:-latest|[-@][0-9]{8})?(?:-v[0-9]+(?::[0-9]+)?)?$", with: "", options: .regularExpression)
        let parts = id.split(separator: "-").map(String.init)
        let isVersion = { (part: String) in part.range(of: "^[0-9]+(?:\\.[0-9]+)*$", options: .regularExpression) != nil }
        let family = parts.filter { !isVersion($0) }, version = parts.filter(isVersion)
        // GPT IDs lead with the version (gpt-6.1-sol); without a name after one (gpt-5.5, gpt-4o) the ID stays.
        let gpt = model[vendor].hasSuffix("gpt-")
        guard !family.isEmpty, !gpt || parts.first.map(isVersion) == true else { return plain }
        return (family + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: "-") + suffix
    }

    /// Claude's undated model ID for a name ("Opus 5.5", Claude 2.1.302's rows) or a description that leads with one
    /// ("Opus 5.5 · …", older rows that name an alias), e.g. claude-opus-5-5.
    static func claudeModelID(_ text: String) -> String? {
        let pattern = #"^([A-Za-z]+) ([0-9]+(?:\.[0-9]+)*)(?:\s+·|$)"#
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        let words = text[match].split(separator: " ")
        guard words.count >= 2 else { return nil }
        return "claude-" + words[0].lowercased() + "-" + words[1].replacingOccurrences(of: ".", with: "-")
    }

    /// The menu row of a model the agent reports: the row with its name, else the one Claude row naming that model
    /// ("Sonnet 5.5" for claude-sonnet-5-5), else the one non-default row describing it ("Opus" · "Opus 5.5 · …").
    static func row(for model: String, in rows: [Choice]) -> Choice? {
        if let row = rows.first(where: { $0.name == model }) { return row }
        let named = rows.filter { claudeModelID($0.name) == model }
        if named.count == 1 { return named[0] }
        let described = rows.filter { !$0.isDefault && claudeModelID($0.detail) == model }
        return named.isEmpty && described.count == 1 ? described[0] : nil
    }
}
