import SwiftUI

/// How an approval's chip draws (the phone's chips: the affirmative one in the app tint, the others grey; on the watch
/// Deny reads red, as a destructive list row does).
enum ApprovalButtonStyle: Equatable {
    case prominent, secondary, destructive

    static func of(_ choice: WatchChoice) -> ApprovalButtonStyle {
        switch choice.role {
        case .allow: .prominent
        case .deny: .destructive
        case .session, .unknown: .secondary
        }
    }
}

/// M4b at watch size: the agent's request in its bubble with the command block (three lines), "Waiting · 2m" under it.
/// The chips follow as their own list rows (`ApprovalChoiceButton`), in the phone's order.
struct ApprovalCard: View {
    let approval: WatchApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ThreadBubble(side: .agent) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(approval.title)
                    if let detail = approval.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .lineLimit(3)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AgentsColor.code, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
            TimelineView(.everyMinute) { context in
                Text(Self.waiting(since: approval.arrived, now: context.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Waiting · 2m", the phone's caption to the minute (the watch redraws it once a minute).
    static func waiting(since arrived: Date, now: Date) -> String {
        let time = WatchTime.relative(arrived, now: now)
        return time == "now" ? "Waiting" : "Waiting · " + time
    }

    /// The chips' titles in the order they show: the phone's order, as the reply lists them.
    static func titles(_ approval: WatchApproval) -> [String] { approval.choices.map(\.label) }
}

/// One approval chip as a full-width watch button (44 pt and more).
struct ApprovalChoiceButton: View {
    let choice: WatchChoice
    let busy: Bool
    let action: () -> Void

    var body: some View {
        let style = ApprovalButtonStyle.of(choice)
        Button(role: style == .destructive ? .destructive : nil, action: action) {
            Text(choice.label)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(style == .prominent ? AgentsColor.onPink : style == .destructive ? AgentsColor.destructive : .primary)
        }
        .disabled(busy)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(style == .prominent ? AgentsColor.pink : Color.white.opacity(0.14)))
        .accessibilityHint("Answers the agent’s request")
    }
}

/// A pending question in the agent's bubble: its header and text (the first part's, with how many more follow).
/// "Answer" opens the form.
struct QuestionCard: View {
    let question: WatchQuestion

    var body: some View {
        ThreadBubble(side: .agent) {
            VStack(alignment: .leading, spacing: 3) {
                if let part = question.parts.first {
                    if !part.header.isEmpty {
                        Text(part.header).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(part.text)
                }
                if question.parts.count > 1 {
                    Text("\(question.parts.count - 1) more question\(question.parts.count == 2 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !question.answerable {
                    Text("Answer on your iPhone").font(.caption2).foregroundStyle(AgentsColor.working)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The question form's state: per part the chosen options or a typed answer, never both (the phone sends one or the
/// other per part).
struct QuestionDraft: Equatable {
    var options: [String: [Int]] = [:]
    var texts: [String: String] = [:]

    /// A tap on an option: several when the part allows it, else that one alone.
    mutating func toggle(_ option: WatchOption, in part: WatchQuestion.Part) {
        texts[part.id] = nil
        var chosen = options[part.id] ?? []
        if part.multiple {
            if let index = chosen.firstIndex(of: option.index) { chosen.remove(at: index) } else { chosen.append(option.index) }
        } else {
            chosen = chosen == [option.index] ? [] : [option.index]
        }
        options[part.id] = chosen.isEmpty ? nil : chosen.sorted()
    }

    /// A dictated or typed answer replaces the part's options.
    mutating func type(_ text: String, in part: WatchQuestion.Part) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        options[part.id] = nil
        texts[part.id] = text.isEmpty ? nil : text
    }

    func isSelected(_ option: WatchOption, in part: WatchQuestion.Part) -> Bool {
        options[part.id]?.contains(option.index) == true
    }

    var answer: WatchAnswer { WatchAnswer(options: options, texts: texts) }

    /// Send is offered once every part is answered and none is secret.
    func canSend(_ question: WatchQuestion) -> Bool { question.answerable && answer.completes(question) }
}

/// The question form, a sheet: each part's header and text, its options (checkmarks; several when `multiple`),
/// dictation or the keyboard when a typed answer is allowed, "Answer on your iPhone" for a secret one; Send once every
/// part is answered, and Skip.
struct QuestionSheet: View {
    let question: WatchQuestion
    let submit: (WatchAnswer) -> Void

    @State private var draft = QuestionDraft()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(question.parts) { part in
                    Section {
                        Text(part.text).font(.footnote).listRowBackground(Color.clear)
                        if part.secret {
                            Text("Answer on your iPhone")
                                .font(.footnote)
                                .foregroundStyle(AgentsColor.working)
                                .listRowBackground(Color.clear)
                        } else {
                            ForEach(part.options) { option in
                                optionRow(option, part: part)
                            }
                            if part.custom {
                                TextFieldLink(prompt: Text("Answer")) {
                                    Label(draft.texts[part.id] ?? "Dictate or type", systemImage: "mic")
                                        .lineLimit(2)
                                } onSubmit: { draft.type($0, in: part) }
                                .accessibilityHint("Answers in your own words")
                            }
                        }
                    } header: {
                        if !part.header.isEmpty { Text(part.header) }
                    }
                }
                Section {
                    Button("Send") {
                        submit(draft.answer)
                        dismiss()
                    }
                    .font(.headline)
                    .foregroundStyle(draft.canSend(question) ? AgentsColor.onPink : .secondary)
                    .listRowBackground(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(draft.canSend(question) ? AgentsColor.pink : Color.white.opacity(0.08)))
                    .disabled(!draft.canSend(question))
                    Button("Skip") {
                        submit(.skipped)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Question")
        }
    }

    private func optionRow(_ option: WatchOption, part: WatchQuestion.Part) -> some View {
        let selected = draft.isSelected(option, in: part)
        return Button {
            draft.toggle(option, in: part)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : part.multiple ? "square" : "circle")
                    .foregroundStyle(selected ? AgentsColor.pink : .secondary)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Selects this answer")
    }
}
