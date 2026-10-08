import Foundation
import Observation

/// A helper interaction's choice questions, answered in the inline card (answers go back through the helper).
struct ClaudeQuestions: Equatable {
    struct Option: Identifiable, Equatable {
        let label: String
        let description: String
        let preview: String?
        var id: String { label }
    }
    struct Question: Identifiable, Equatable {
        let text: String
        let header: String
        let options: [Option]
        let multiple: Bool
        var id: String { text }
    }
    let questions: [Question]

    /// Common helper questions; their answers go back through the helper, never as hook JSON.
    init(_ questions: [Question]) { self.questions = questions }

    func accepts(_ answers: [String: String]) -> Bool {
        Set(answers.keys) == Set(questions.map(\.text))
            && answers.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                $0.utf8.count <= 8192 && !$0.unicodeScalars.contains(where: { $0.value == 0 }) }
    }
}

/// The pending request owns the draft so transcript refreshes, scrolling and
/// view reconstruction cannot erase partially answered questions.
@MainActor @Observable
final class ClaudeQuestionDraft {
    let questionnaire: ClaudeQuestions
    private(set) var index = 0
    private(set) var selected: [String: Set<String>] = [:]
    private(set) var custom: [String: String] = [:]
    private(set) var usingCustom: Set<String> = []
    init(_ questionnaire: ClaudeQuestions) { self.questionnaire = questionnaire }
    var question: ClaudeQuestions.Question { questionnaire.questions[index] }
    func clearAnswers() { selected = [:]; custom = [:]; usingCustom = [] }
    func back() { if index > 0 { index -= 1 } }
    func next() { if answer(question) != nil && index + 1 < questionnaire.questions.count { index += 1 } }
    func select(_ label: String) {
        guard question.options.contains(where: { $0.label == label }) else { return }
        let id = question.id
        usingCustom.remove(id)
        if question.multiple {
            if selected[id, default: []].contains(label) { selected[id]?.remove(label) }
            else { selected[id, default: []].insert(label) }
        } else { selected[id] = [label] }
    }
    func type(_ text: String) { custom[question.id] = text; usingCustom.insert(question.id) }
    func answer(_ question: ClaudeQuestions.Question) -> String? {
        if usingCustom.contains(question.id) {
            guard let value = custom[question.id], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 8192, !value.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
            return value
        }
        let labels = question.options.filter { selected[question.id, default: []].contains($0.label) }.map(\.label)
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }
    var answers: [String: String] {
        Dictionary(uniqueKeysWithValues: questionnaire.questions.compactMap { question in answer(question).map { (question.text, $0) } })
    }
}
