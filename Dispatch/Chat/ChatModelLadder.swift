import Foundation

/// A model list that is nothing but the rungs of one known family, weakest first, and perhaps its security model: the
/// picker draws it as two tracks instead of two lists. These orders and the security names are the only model knowledge
/// in the app; versions, effort levels, descriptions, the current choice and the default still come from the agent.
struct ChatModelLadder: Equatable {
    struct Rung: Equatable, Identifiable {
        let family: String
        /// The model's ID as the footer names it (opus-5.5).
        let label: String
        /// The agent's row to send.
        let choice: AgentModelMenu.Choice
        /// Every row naming this model: the row to send and a default row folded into it.
        let rows: Set<String>
        let isDefault: Bool
        var id: String { family }

        /// The agent's line for it, without the model's name that Claude's rows lead with ("Opus 5.5 · Most capable").
        var description: String {
            guard AgentModelMenu.claudeModelID(choice.detail) != nil, let dot = choice.detail.range(of: " · ") else { return choice.detail }
            return String(choice.detail[dot.upperBound...])
        }
    }

    let rungs: [Rung]
    /// Listed by the agent, never a rung: the user turns it on case by case.
    let security: Rung?

    private static let families = [
        (rungs: ["haiku", "sonnet", "opus", "fable"], security: "mythos", newestOnly: false),
        // Codex lists older generations beside the current one (gpt-6.1-sol, gpt-6-sol, gpt-5.6-sol).
        (rungs: ["luna", "terra", "sol", "astra"], security: "daybreak-blue", newestOnly: true),
    ]

    private init(rungs: [Rung], security: Rung?) {
        self.rungs = rungs
        self.security = security
    }

    /// Nil unless every row maps to a rung or the security model of one family, no two rows to the same one, with at
    /// least two rungs. A default row naming the same model as another row folds into it; in a family that lists older
    /// generations, only each model's newest is a rung.
    init?(_ rows: [AgentModelMenu.Choice]) {
        let named = rows.map { (choice: $0, label: Self.label($0)) }
        var kept = named.filter { row in
            !row.choice.isDefault || !named.contains { !$0.choice.isDefault && $0.label.lowercased() == row.label.lowercased() }
        }
        guard let known = Self.families.first(where: { known in
            kept.allSatisfy { known.rungs.contains(Self.family(of: $0.label)) || Self.family(of: $0.label) == known.security }
        }) else { return nil }
        if known.newestOnly {
            let all = kept
            kept = all.filter { row in
                !all.contains { Self.family(of: $0.label) == Self.family(of: row.label) && Self.newer(Self.version(of: $0.label), than: Self.version(of: row.label)) }
            }
        }
        guard Set(kept.map { Self.family(of: $0.label) }).count == kept.count else { return nil }
        func rung(_ family: String) -> Rung? {
            guard let row = kept.first(where: { Self.family(of: $0.label) == family }) else { return nil }
            let folded = named.filter { $0.choice.isDefault && $0.label.lowercased() == row.label.lowercased() }
            return Rung(family: family, label: row.label, choice: row.choice,
                        rows: Set(folded.map(\.choice.name) + [row.choice.name]),
                        isDefault: row.choice.isDefault || !folded.isEmpty)
        }
        let rungs = known.rungs.compactMap(rung)
        guard rungs.count >= 2 else { return nil }
        self.init(rungs: rungs, security: rung(known.security))
    }

    /// The one stop that can be drawn before the agent's list is known, for a model of a known family.
    static func provisional(model: String) -> ChatModelLadder? {
        let label = AgentModelMenu.label(for: AgentModelMenu.claudeModelID(model) ?? model), family = family(of: label)
        let rung = Rung(family: family, label: label, choice: .init(number: 1, name: model, detail: "", current: true, isDefault: false),
                        rows: [model], isDefault: false)
        if families.contains(where: { $0.security == family }) { return ChatModelLadder(rungs: [], security: rung) }
        return families.contains { $0.rungs.contains(family) } ? ChatModelLadder(rungs: [rung], security: nil) : nil
    }

    /// Whether a model an agent reports is one of the families' security models.
    static func isSecurity(model: String) -> Bool {
        let family = family(of: AgentModelMenu.label(for: AgentModelMenu.claudeModelID(model) ?? model))
        return families.contains { $0.security == family }
    }

    /// A row's ID label: Claude's rows name the model ("Sonnet 5.5") or describe it ("Opus" · "Opus 5.5 · …").
    static func label(_ choice: AgentModelMenu.Choice) -> String {
        AgentModelMenu.label(for: AgentModelMenu.claudeModelID(choice.name) ?? AgentModelMenu.claudeModelID(choice.detail) ?? choice.name)
    }

    /// An ID label without its version and `[suffix]`: opus-5.5[1m] is opus, daybreak-blue is daybreak-blue.
    static func family(of label: String) -> String {
        let name = label.lowercased().split(separator: "[", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return name.replacingOccurrences(of: "-[0-9]+(?:\\.[0-9]+)*$", with: "", options: .regularExpression)
    }

    /// An ID label's version as numbers: sol-6.1 is [6, 1]; empty when it names none.
    private static func version(of label: String) -> [Int] {
        let name = label.split(separator: "[", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let range = name.range(of: "-[0-9]+(?:\\.[0-9]+)*$", options: .regularExpression) else { return [] }
        return name[range].dropFirst().split(separator: ".").compactMap { Int($0) }
    }

    private static func newer(_ version: [Int], than other: [Int]) -> Bool {
        for index in 0..<max(version.count, other.count) {
            let left = index < version.count ? version[index] : 0, right = index < other.count ? other[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    var all: [Rung] { rungs + (security.map { [$0] } ?? []) }

    func rung(family: String) -> Rung? { all.first { $0.family == family } }

    /// The rung of a row, or of a model as the agent reports it (claude-opus-5-5). A named version must be the rung's:
    /// an older generation of the family is off the ladder.
    func rung(reported model: String) -> Rung? {
        if let row = all.first(where: { $0.rows.contains(model) }) { return row }
        let label = AgentModelMenu.label(for: AgentModelMenu.claudeModelID(model) ?? model)
        guard let rung = rung(family: Self.family(of: label)) else { return nil }
        let reported = Self.version(of: label), own = Self.version(of: rung.label)
        return reported.isEmpty || own.isEmpty || reported == own ? rung : nil
    }

    /// The agent's command for its security model's access, for the button beside its switch: Codex's Daybreak is a
    /// setting of its own, which the model does not turn on. It toggles, and also saves the default for new chats.
    var securityCommand: (title: String, text: String)? {
        security?.family == "daybreak-blue" ? ("Daybreak", "/daybreak") : nil
    }

    // MARK: Effort

    static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// A menu's levels. A model without any lists one "default" row, which is not a level.
    static func levels(_ choices: [AgentModelMenu.Choice]) -> [String] {
        choices.compactMap(\.effort).filter { $0 != "default" }
    }

    /// Every level of these lists, weakest first; levels outside the known order follow as the agents list them.
    static func union(_ lists: [[String]]) -> [String] {
        var seen = Set<String>()
        let levels = lists.joined().filter { seen.insert($0).inserted }
        return effortOrder.filter(seen.contains) + levels.filter { !effortOrder.contains($0) }
    }

    /// The level to use on a model with these levels: the same one if it has it, else its highest below that, else its
    /// lowest. Nil when it has none.
    static func broughtDown(_ effort: String, to levels: [String]) -> String? {
        if levels.contains(effort) { return effort }
        let ordered = union([levels, [effort]])
        guard let place = ordered.firstIndex(of: effort) else { return ordered.first }
        return ordered[..<place].last ?? ordered.dropFirst(place + 1).first
    }
}
