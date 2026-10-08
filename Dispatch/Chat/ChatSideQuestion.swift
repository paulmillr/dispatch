import Foundation
import Observation

/// A request belongs to one conversation and turn. Answers are keyed by the
/// protocol's question IDs, so repeated question text cannot mix up replies.
@MainActor @Observable
final class ChatSideQuestion: Identifiable {
    struct Option: Identifiable {
        let label: String
        let description: String
        var id: String { label }
    }
    struct Question: Identifiable {
        let id: String
        let header: String
        let question: String
        let isOther: Bool
        let isSecret: Bool
        let options: [Option]?
        var allowsCustom: Bool { isOther || options?.isEmpty != false }
    }
    let id: String
    let threadID: String
    let questions: [Question]
    let blocking: Bool
    @ObservationIgnored private let interaction: HelperChat.Interaction
    var selections: [String: Set<String>] = [:]
    var index = 0
    var selected: [String: String] = [:]
    var custom: [String: String] = [:]
    var usingCustom: Set<String> = []
    var submitted = false
    var submissionError: String?
    var submissionUncertain = false
    var question: Question { questions[index] }

    init?(interaction: HelperChat.Interaction, session: String) {
        guard !interaction.questions.isEmpty else { return nil }
        self.interaction = interaction
        id = interaction.id
        threadID = session
        blocking = interaction.blocking
        questions = interaction.questions.map {
            Question(id: $0.id, header: $0.header, question: $0.text, isOther: $0.custom,
                     isSecret: $0.secret, options: $0.options.map {
                         Option(label: $0.label, description: $0.detail ?? "")
                     })
        }
    }

    func select(_ label: String) {
        guard !submitted, question.options?.contains(where: { $0.label == label }) == true else { return }
        if interaction.questions.first(where: { $0.id == question.id })?.multiple == true {
            if selections[question.id, default: []].contains(label) {
                selections[question.id]?.remove(label)
            } else { selections[question.id, default: []].insert(label) }
            usingCustom.remove(question.id)
            return
        }
        selected[question.id] = label; usingCustom.remove(question.id)
    }
    func type(_ text: String) {
        guard !submitted, question.allowsCustom else { return }
        custom[question.id] = text; usingCustom.insert(question.id)
    }
    func answer(_ question: Question) -> String? {
        if usingCustom.contains(question.id), question.allowsCustom {
            guard let text = custom[question.id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 16_384 else { return nil }
            return text
        }
        if let labels = selections[question.id], !labels.isEmpty {
            return (question.options ?? []).filter { labels.contains($0.label) }.map(\.label).joined(separator: ", ")
        }
        guard let label = selected[question.id], question.options?.contains(where: { $0.label == label }) == true else { return nil }
        return label
    }
    var answers: [String: HelperChat.Answer]? {
        var result: [String: HelperChat.Answer] = [:]
        for question in interaction.questions {
            if usingCustom.contains(question.id), let form = questions.first(where: { $0.id == question.id }),
               let text = answer(form) {
                result[question.id] = .text(text)
            } else {
                let labels = selections[question.id] ?? selected[question.id].map { Set([$0]) } ?? []
                let indices = question.options.indices.filter { labels.contains(question.options[$0].label) }
                guard !indices.isEmpty else { return nil }
                result[question.id] = .options(indices)
            }
        }
        return result
    }
    var complete: Bool {
        answers != nil
    }
    func summary(skip: Bool) -> String {
        questions.map { question in
            question.question + "\n" + (skip ? "Skipped" : question.isSecret ? "Private answer sent" : answer(question) ?? "")
        }.joined(separator: "\n\n")
    }
    func clearAnswers() {
        selected = [:]; custom = [:]; usingCustom = []
        selections = [:]
    }
}
