import Foundation

/// Choice state is kept separately from the display answer, whose labels may themselves contain commas.
enum ChatQuestionPolicy {
    static func isSelected(_ label: String, selected: Set<String>, usingCustom: Bool) -> Bool {
        !usingCustom && selected.contains(label)
    }

    static func selecting(_ label: String, in selected: Set<String>, multiple: Bool) -> Set<String> {
        guard multiple else { return [label] }
        var result = selected
        if !result.insert(label).inserted { result.remove(label) }
        return result
    }

    static func customAnswer(_ text: String?, byteLimit: Int) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= byteLimit, !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return text
    }

    struct Actions {
        let index: Int
        let count: Int
        let answered: Bool
        let complete: Bool
        var submitted = false
        var uncertain = false

        var canEdit: Bool { !submitted && !uncertain }
        var canGoBack: Bool { canEdit && index > 0 }
        var canGoNext: Bool { canEdit && answered && index + 1 < count }
        var canSubmit: Bool { canEdit && complete }
        var canSkip: Bool { canEdit }
    }
}
