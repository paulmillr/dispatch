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

/// K3: the agent's request in its bubble, its glyph and "Codex wants to run" (or the request's own words), the command
/// on one monospaced line (scaled down rather than wrapped), "Waiting · 2m" under it. The chips follow as capsules
/// (`ApprovalChoiceButton`): Allow first, This session where offered, Deny last.
struct ApprovalCard: View {
    let approval: WatchApproval
    /// The agent's key or label ("codex", "Claude Code").
    var agent: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ThreadBubble(side: .agent) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        AgentGlyph(agent: agent, size: 11)
                        Text(Self.headline(approval, agent: agent))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    if let detail = approval.detail, !detail.isEmpty {
                        Text(Self.oneLine(detail))
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .truncationMode(.middle)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([approval.title, Self.headline(approval, agent: agent), approval.detail]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ", "))
    }

    /// "Codex wants to run" when the phone says what the block is; else the request's own words ("Allow Bash?").
    static func headline(_ approval: WatchApproval, agent: String?) -> String {
        guard let verb = approval.verb, verb != .unknown else { return approval.title }
        return (AgentsGlyph.shortName(agent) ?? "The agent") + " wants to " + verb.rawValue
    }

    /// A command's first line, with "…" when more follow.
    static func oneLine(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let first = lines.first else { return text }
        return lines.count > 1 ? first + " …" : String(first)
    }

    /// "Waiting · 2m", the phone's caption to the minute (the watch redraws it once a minute).
    static func waiting(since arrived: Date, now: Date) -> String {
        let time = WatchTime.relative(arrived, now: now)
        return time == "now" ? "Waiting" : "Waiting · " + time
    }

    /// The chips in the order the watch shows them: the affirmative first (Allow, then This session), Deny last.
    static func ordered(_ choices: [WatchChoice]) -> [WatchChoice] {
        func rank(_ role: WatchChoiceRole) -> Int {
            switch role { case .allow: 0; case .session: 1; case .unknown: 2; case .deny: 3 }
        }
        return choices.enumerated().sorted { (rank($0.element.role), $0.offset) < (rank($1.element.role), $1.offset) }.map(\.element)
    }

    /// The chips' titles in the order they show.
    static func titles(_ approval: WatchApproval) -> [String] { ordered(approval.choices).map(\.label) }
}

/// One approval chip as a full-width capsule: Allow in the accent, This session glass, Deny glass with red words.
struct ApprovalChoiceButton: View {
    let choice: WatchChoice
    let busy: Bool
    let action: () -> Void

    var body: some View {
        let style = ApprovalButtonStyle.of(choice)
        CapsuleButton(title: choice.label,
                      style: style == .prominent ? .accent : style == .destructive ? .destructive : .glass,
                      enabled: !busy, hint: "Answers the agent’s request", action: action)
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

    /// Next is offered once this part has an option or a typed answer.
    func answered(_ part: WatchQuestion.Part) -> Bool {
        !part.secret && (!(options[part.id] ?? []).isEmpty || !(texts[part.id] ?? "").isEmpty)
    }
}

/// K4, the question form, a sheet: one part at a time ("1 of 2"), its options as rows with checkmarks (several when
/// `multiple`), "Dictate or type" when a typed answer is allowed, "Answer on your iPhone" for a secret one; Next once the
/// part is answered, Send on the last; Back and Skip.
struct QuestionSheet: View {
    let question: WatchQuestion
    /// An option of the first part chosen when the form opens (Debug's `-DispatchWatchSheet question:<index>`).
    var preselect: Int? = nil
    let submit: (WatchAnswer) -> Void

    @State private var draft = QuestionDraft()
    @State private var index = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if question.parts.indices.contains(index) {
                    part(question.parts[index])
                }
            }
            .environment(\.defaultMinListRowHeight, 0)
            .navigationTitle("Question")
        }
        .onAppear {
            guard let preselect, draft == QuestionDraft(), let part = question.parts.first,
                  let option = part.options.first(where: { $0.index == preselect }) else { return }
            draft.toggle(option, in: part)
        }
    }

    @ViewBuilder private func part(_ part: WatchQuestion.Part) -> some View {
        let last = index == question.parts.count - 1
        VStack(alignment: .leading, spacing: 4) {
            Text(part.text).font(.footnote)
            if let position = Self.position(index, of: question.parts.count) {
                Text(position).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(BareRow(vertical: 4))
        if part.secret {
            Text("Answer on your iPhone")
                .font(.footnote)
                .foregroundStyle(AgentsColor.working)
                .modifier(BareRow())
        } else {
            ForEach(part.options) { option in
                optionRow(option, part: part)
            }
            if part.custom {
                TextFieldLink(prompt: Text("Answer")) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic").foregroundStyle(.secondary)
                        Text(draft.texts[part.id] ?? "Dictate or type")
                            .foregroundStyle(draft.texts[part.id] == nil ? .secondary : .primary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } onSubmit: { draft.type($0, in: part) }
                .accessibilityLabel(draft.texts[part.id] ?? "Dictate or type")
                .accessibilityHint("Answers in your own words")
            }
        }
        if last {
            CapsuleButton(title: "Send", style: .accent, enabled: draft.canSend(question)) {
                submit(draft.answer)
                dismiss()
            }
        } else {
            CapsuleButton(title: "Next", style: .accent, enabled: draft.answered(part)) { index += 1 }
        }
        if index > 0 {
            CapsuleButton(title: "Back", symbol: "chevron.left") { index -= 1 }
        }
        CapsuleButton(title: "Skip", hint: "Declines the question") {
            submit(.skipped)
            dismiss()
        }
    }

    /// "1 of 2"; nothing for a single part.
    static func position(_ index: Int, of count: Int) -> String? {
        count > 1 ? "\(index + 1) of \(count)" : nil
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
            .frame(minHeight: 40)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        // The row's own platter, not the system's button highlight (which tints a chosen row and its words pink).
        .buttonStyle(.plain)
        .listRowBackground(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgentsColor.groupedRow))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Selects this answer")
    }
}
