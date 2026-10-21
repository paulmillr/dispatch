import SwiftUI

/// M5b: tapping an agent message (or its steps caption) pushes its details. The message quoted at the top, the steps the
/// agent took in that turn (each opens its full output), then the facts. Back returns to the thread; the back pill
/// names the space, as Messages names the conversation.
struct ChatMessageDetails: View {
    let session: MobileChatSession
    let row: ChatThreadRow
    let space: String
    /// The conversation's tab, when the caller knows it.
    var tab: String? = nil
    let directory: String?
    let open: (ChatStep) -> Void
    @Environment(\.dismiss) private var dismiss

    private var turn: ChatTurn? { session.transcript.turns.first { $0.id == row.turnID } }

    var body: some View {
        let summary = turn.map(ChatTurnSummary.init)
        let steps = turn.map { ChatStep.steps($0, directory: directory, reasoning: false) } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MobileChatMarkdownView(text: row.item.text)
                    .environment(\.openURL, MobileChatMarkdown.openURL)
                    .font(.subheadline)
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.bubbleAgent, in: UnevenRoundedRectangle(
                        cornerRadii: .init(topLeading: 20, bottomLeading: 6, bottomTrailing: 20, topTrailing: 20), style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 28)
                    .textSelection(.enabled)
                if !steps.isEmpty {
                    section(summary?.caption ?? "\(steps.count) steps") {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            if step.kind == .patch {
                                // M5d: a patch pushes the turn's changes (Code stream).
                                NavigationLink { DiffView(session: session, steps: steps, opening: step, directory: directory) } label: { stepRow(step) }
                                    .buttonStyle(.plain)
                            } else {
                                Button { open(step) } label: { stepRow(step) }
                                    .buttonStyle(.plain)
                            }
                            if index < steps.count - 1 {
                                Rectangle().fill(Color.hairline).frame(height: 0.5).padding(.leading, 70)
                            }
                        }
                    }
                }
                // M5b's order: where it ran (host, space, tab), then the model and when it was sent.
                section("Details") {
                    fact("Host", session.hostName)
                    divider
                    fact("Space", space)
                    if let tab {
                        divider
                        fact("Tab", tab)
                    }
                    divider
                    fact("Model", [session.modelLabel ?? session.model, session.effort].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "Unknown")
                    divider
                    fact("Sent", row.time.map { Self.sent($0) } ?? "Unknown")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .background(Color.canvas)
        .navigationTitle("Message")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        Text(space).font(.body).lineLimit(1)
                    }
                    .foregroundStyle(Color.dispatchPink)
                }
                .accessibilityLabel("Back to \(space)")
            }
        }
    }

    private var divider: some View { Rectangle().fill(Color.hairline).frame(height: 0.5).padding(.leading, 16) }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.footnote)
                .tracking(0.52)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .background(Color.raisedRow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func stepRow(_ step: ChatStep) -> some View {
        HStack(spacing: 10) {
            Text(step.kind.label)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(minWidth: kindWidth, alignment: .leading)
            Text(step.title)
                .scaledFont(14, design: .monospaced, relativeTo: .subheadline)
                .fittingLine()
                .frame(maxWidth: .infinity, alignment: .leading)
            if step.kind == .patch, step.additions + step.deletions > 0 {
                Text("+\(step.additions)").foregroundStyle(ChatStep.added)
                Text("−\(step.deletions)").foregroundStyle(ChatStep.removed)
            } else if step.failed {
                Text("failed").foregroundStyle(ChatStep.removed)
            }
            Text("›").font(.body).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .scaledFont(14, design: .monospaced, relativeTo: .subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(step.kind == .patch ? "Shows the changes" : "Shows its full output")
    }

    @ScaledMetric(relativeTo: .footnote) private var kindWidth: CGFloat = 44
    @Environment(\.dynamicTypeSize) private var typeSize

    private func fact(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(typeSize > .large ? 3 : 1).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// "Today 9:38", "Yesterday 9:38", else the date and time.
    static func sent(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today " + time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday " + time
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A step's full output (`chat.tools`), or its diff for a patch: monospaced, selectable.
struct ChatStepOutputSheet: View {
    let session: MobileChatSession
    let step: ChatStep
    @State private var record: HelperChat.Record?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if step.kind == .patch, !documents.isEmpty {
                        ForEach(Array(documents.enumerated()), id: \.offset) { _, document in
                            Text(document.path).font(.footnote.weight(.semibold).monospaced())
                            diff(document.diff)
                        }
                    } else {
                        let input = ToolPresentation(step.item).input
                        if !input.isEmpty, step.kind == .run {
                            Text("$ " + input).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Text(output.isEmpty ? (record == nil && error == nil ? "Loading…" : "No output.") : output)
                            .font(.system(size: 13, design: .monospaced))
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Color.dispatchPink)
        .task {
            guard step.kind != .think else { return }
            do { record = try await session.fullOutput(of: step.item) } catch { self.error = error.localizedDescription }
        }
    }

    private var item: ChatItem {
        guard let record, case .item(let item)? = record.display?.action else { return step.item }
        return item
    }

    private var output: String {
        step.kind == .think ? step.item.text : ToolPresentation(item).output
    }

    private var documents: [ToolDocument] { ToolPresentation(item).documents }

    private func diff(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(line.hasPrefix("+") ? ChatStep.added : line.hasPrefix("-") ? ChatStep.removed : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.hasPrefix("+") ? ChatStep.added.opacity(0.08) : line.hasPrefix("-") ? ChatStep.removed.opacity(0.08) : .clear)
            }
        }
    }
}

/// The Effort section's choices and the model they belong to. After another model is picked, the previous model's
/// efforts stay on screen (no section jumping away and back) but are not choosable, and Done waits, until the new
/// model's efforts have loaded.
struct ChatEffortChoices: Equatable {
    var choices: [AgentModelMenu.Choice] = []
    /// Whose efforts `choices` are (nil before the first load).
    var model: String?

    /// The efforts of `selected` are still loading.
    func loading(for selected: String?) -> Bool { selected != nil && selected != model }
    /// The section shows: efforts to show, or a load in progress.
    func shown(for selected: String?) -> Bool { !choices.isEmpty || loading(for: selected) }
}

/// M3b's pickers: the agent's models and the chosen model's efforts, from the helper's verified menus.
struct ChatSettingsSheet: View {
    let session: MobileChatSession
    var memory: ChatModelMemory?
    @State private var models: [AgentModelMenu.Choice] = []
    @State private var efforts = ChatEffortChoices()
    @State private var model: String?
    @State private var effort: String?
    @State private var error: String?
    @State private var applying = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    if models.isEmpty && error == nil { ProgressView() }
                    ForEach(models) { choice in
                        Button {
                            model = choice.name
                        } label: {
                            HStack {
                                Text(choice.detail.isEmpty ? choice.name : choice.detail).foregroundStyle(.primary)
                                Spacer()
                                if choice.name == model { Image(systemName: "checkmark").foregroundStyle(Color.dispatchPink) }
                            }
                        }
                    }
                }
                if efforts.shown(for: model) {
                    let loading = efforts.loading(for: model)
                    Section {
                        if efforts.choices.isEmpty {
                            ProgressView()
                        } else {
                            Picker("Effort", selection: Binding(get: { effort ?? "" }, set: { effort = $0 })) {
                                ForEach(efforts.choices) { Text($0.detail.isEmpty ? $0.name : $0.detail).tag($0.name) }
                            }
                            .pickerStyle(.segmented)
                            .disabled(loading)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text("Effort")
                            if loading, !efforts.choices.isEmpty { ProgressView().controlSize(.mini) }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.secondary) } }
            }
            .navigationTitle(session.agentName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply() }.disabled(model == nil || applying || efforts.loading(for: model))
                }
            }
        }
        .tint(Color.dispatchPink)
        .task {
            do {
                models = try await session.models()
                if let agent = session.agentKey { memory?.remember(agent: agent, models: models) }
                // The agent reports the model's ID (claude-opus-5-5); the picker takes its menu row ("Opus 5.5").
                model = session.model.flatMap { AgentModelMenu.row(for: $0, in: models)?.name } ?? models.first { $0.current }?.name
            } catch { self.error = error.localizedDescription }
        }
        .task(id: model) {
            guard let model else { return }
            let loaded = (try? await session.efforts(for: model)) ?? []
            guard !Task.isCancelled else { return }
            if let agent = session.agentKey, !loaded.isEmpty { memory?.remember(agent: agent, efforts: loaded, for: model) }
            // The choices and the selection change in the same update: no frame pairs a model with another's effort.
            efforts = ChatEffortChoices(choices: loaded, model: model)
            if effort == nil || !loaded.contains(where: { $0.name == effort }) {
                effort = loaded.first { $0.current }?.name ?? (loaded.contains { $0.name == session.effort } ? session.effort : loaded.first?.name)
            }
        }
    }

    private func apply() {
        guard let model else { return }
        applying = true
        Task {
            defer { applying = false }
            do {
                let chosen = try await session.select(model: model, effort: effort)
                // New chats offer the remembered model among the menu's rows, so remember the row the report names.
                let row = AgentModelMenu.row(for: chosen.model, in: models)?.name ?? chosen.model
                if let agent = session.agentKey { memory?.remember(agent: agent, model: row, effort: chosen.effort) }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
