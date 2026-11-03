import SwiftUI

/// M5b: tapping an agent message (or its steps caption) pushes its details (redesigned as the mockups' M1). The agent
/// and when it wrote are the title, the message's actions the ⋯ menu. The whole message raw (as the agent wrote it, one
/// selection across all of it), how the turn went and when, the conversation's facts (the turn's changes, tokens so far,
/// its model now), then the turn's steps, folded past `ChatStepFold.threshold` (each step pushes its output, a patch
/// its diff). Where it ran is the caption at the end. Back returns to the thread; the back pill names the space, as
/// Messages names the conversation.
struct ChatMessageDetails: View {
    let session: MobileChatSession
    let row: ChatThreadRow
    let space: String
    /// The conversation's tab, when the caller knows it.
    var tab: String? = nil
    let directory: String?
    /// Quotes the message into the composer (the bubble menu's Reply); nil: no Reply.
    var reply: (() -> Void)? = nil
    /// Switches the tab to Terminal; nil where the tab has none.
    var showTerminal: (() -> Void)? = nil
    @State private var unfolded: Set<String> = []
    @State private var showingAll = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .callout) private var measure = ChatMeasure.standard
    @ScaledMetric(relativeTo: .subheadline) private var glyphWidth: CGFloat = 22

    private var turn: ChatTurn? { session.transcript.turns.first { $0.id == row.turnID } }

    var body: some View {
        let summary = turn.map(ChatTurnSummary.init)
        let steps = turn.map { ChatStep.steps($0, directory: directory, reasoning: false) } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                quote
                outcome(summary)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 14)
                card { facts(summary, steps: steps) }
                if !steps.isEmpty {
                    stepsHeader(steps)
                    card { stepList(steps) }
                }
                Text(([session.hostName, space] + (tab.map { [$0] } ?? [])).joined(separator: " › "))
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.top, 18)
            }
            .frame(maxWidth: measure + 32)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .background(Color.canvas)
        .navigationTitle(session.agentName)
        .navigationSubtitle(row.time.map { Self.moment($0) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        TabsCappedWidth(max: TabsBackPill.labelWidth) { Text(space).font(.body).lineLimit(1) }
                    }
                    .foregroundStyle(Color.dispatchPink)
                }
                .accessibilityLabel("Back to \(space)")
            }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
    }

    /// The message as a block quote: a bar on its leading edge and no fill, so it never reads as one of the cards.
    private var quote: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule().fill(Color.dispatchPink.opacity(0.55)).frame(width: 3)
            ChatRawText(text: row.item.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var menu: some View {
        Menu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.item.text }
            if let reply {
                Button("Reply", systemImage: "arrowshape.turn.up.left") { reply() }
            }
            ShareLink(item: row.item.text) { Label("Share…", systemImage: "square.and.arrow.up") }
            if let showTerminal {
                Divider()
                Button("Show in Terminal", systemImage: "apple.terminal") { showTerminal() }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Message actions")
    }

    /// "✓ Finished · 10:28 – 10:32 · 4m 12s": how the turn went, then when, as far as the transcript says.
    private func outcome(_ summary: ChatTurnSummary?) -> some View {
        let working = turn != nil && turn?.id == session.transcript.openTurn?.id
        let when = Self.span(turn, duration: summary?.duration)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if working {
                Label("Working", systemImage: "circle.dotted").foregroundStyle(.secondary)
            } else {
                Label("Finished", systemImage: "checkmark.circle.fill").foregroundStyle(ChatStep.added)
            }
            if let when {
                Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(when).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.subheadline)
        .labelStyle(ChatDetailsLabelStyle())
        .accessibilityElement(children: .combine)
    }

    /// "10:28 – 10:32 · 4m 12s" (the end with its day when the day changed, "Yesterday 23:58 – 00:03"); the start alone
    /// while working; nil for a turn read without times.
    static func span(_ turn: ChatTurn?, duration: TimeInterval?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let turn, turn.started.timeIntervalSince1970 > 0 else { return nil }
        let start = moment(turn.started, now: now, calendar: calendar)
        guard let ended = turn.ended, ended.timeIntervalSince1970 > 0, ended >= turn.started else { return start }
        let end = calendar.isDate(ended, inSameDayAs: turn.started)
            ? clock(ended, calendar: calendar) : moment(ended, now: now, calendar: calendar)
        return [start + " – " + end, duration.map(ChatTurnSummary.elapsed)].compactMap { $0 }.joined(separator: " · ")
    }

    /// A time as the thread's corners say it ("10:32", "Yesterday 10:32", "Thu 10:32"), with its time of day past a
    /// week too ("Oct 12, 10:32"), where the corner says the date alone.
    static func moment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = ChatTurnSummary.time(date, now: now, calendar: calendar)
        let time = clock(date, calendar: calendar)
        return day.contains(time) ? day : day + ", " + time
    }

    private static func clock(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
                                        timeZone: calendar.timeZone).hour().minute())
    }

    @ViewBuilder private func facts(_ summary: ChatTurnSummary?, steps: [ChatStep]) -> some View {
        if let summary, !summary.files.isEmpty, let opening = steps.first(where: { $0.kind == .patch }) {
            NavigationLink { DiffView(session: session, steps: steps, opening: opening, directory: directory, back: session.agentName) } label: {
                fact("Changes", chevron: true) {
                    HStack(spacing: 8) {
                        Text(ChatTurnSummary.count(summary.files.count, "file"))
                        Text("+\(summary.additions)").foregroundStyle(ChatStep.added)
                        Text("−\(summary.deletions)").foregroundStyle(ChatStep.removed)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the changes")
            divider
        }
        if let usage = session.usage, usage.input != nil || usage.output != nil || usage.contextRemaining != nil {
            // The conversation's counts (the agent reports no turn's own), hence "so far".
            fact("Tokens so far") {
                VStack(alignment: .trailing, spacing: 5) {
                    if let tokens = Self.tokens(usage) { Text(tokens).monospacedDigit() }
                    if let remaining = usage.contextRemaining, let window = usage.contextWindow {
                        HStack(spacing: 8) {
                            ProgressView(value: 1 - remaining)
                                .tint(remaining < 0.2 ? Color.orange : Color.secondary)
                                .frame(width: 72)
                                .accessibilityHidden(true)
                            Text("\(Int(((1 - remaining) * 100).rounded()))% of \(Self.compact(window)) context")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            divider
        }
        // The conversation's model now: a turn before a switch may have used another.
        fact("Model") {
            Text([session.modelLabel ?? session.model, session.effort].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "Unknown")
        }
    }

    /// "48.2K in · 3.1K out".
    static func tokens(_ usage: ChatUsage) -> String? {
        [usage.input.map { compact($0) + " in" }, usage.output.map { compact($0) + " out" }].compactMap { $0 }
            .joined(separator: " · ").nilIfEmpty
    }

    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private func stepsHeader(_ steps: [ChatStep]) -> some View {
        let folds = ChatStepFold.entries(steps).contains { if case .fold = $0 { true } else { false } }
        return HStack(alignment: .lastTextBaseline) {
            HStack(spacing: 6) {
                Text("Steps").textCase(.uppercase).accessibilityAddTraits(.isHeader)
                Text("\(steps.count)").foregroundStyle(.tertiary)
            }
            .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            if folds {
                Button(showingAll ? "Show fewer" : "Show all") {
                    showingAll.toggle()
                    unfolded = []
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.dispatchPink)
            }
        }
        .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 7)
    }

    @ViewBuilder private func stepList(_ steps: [ChatStep]) -> some View {
        let entries = showingAll ? steps.indices.map { ChatStepFold.Entry.step($0) } : ChatStepFold.entries(steps)
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { divider.padding(.leading, glyphWidth + 12) }
            switch entry {
            case .step(let at):
                stepLink(steps[at], steps: steps, nested: false)
            case .fold(let range, let summary):
                let key = steps[range.lowerBound].id
                let open = unfolded.contains(key)
                foldRow(summary, count: range.count, open: open) {
                    if open { unfolded.remove(key) } else { unfolded.insert(key) }
                }
                if open {
                    ForEach(steps[range]) { step in
                        divider.padding(.leading, glyphWidth + 36)
                        stepLink(step, steps: steps, nested: true)
                    }
                }
            }
        }
    }

    private func stepLink(_ step: ChatStep, steps: [ChatStep], nested: Bool) -> some View {
        NavigationLink {
            if step.kind == .patch {
                // M5d: a patch pushes the turn's changes (Code stream).
                DiffView(session: session, steps: steps, opening: step, directory: directory, back: session.agentName)
            } else {
                ChatStepOutput(session: session, step: step)
            }
        } label: { stepRow(step, nested: nested) }
        .buttonStyle(.plain)
    }

    private func stepRow(_ step: ChatStep, nested: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: step.failed ? "xmark.octagon" : step.kind.symbol)
                .font(.subheadline)
                .foregroundStyle(step.failed ? AnyShapeStyle(ChatStep.removed) : AnyShapeStyle(.secondary))
                .frame(width: glyphWidth)
                .accessibilityLabel(step.kind.label)
            Text(step.title)
                .scaledFont(14, design: .monospaced, relativeTo: .subheadline)
                .fittingLine()
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if step.running {
                    ProgressView().controlSize(.mini)
                } else if step.kind == .patch, step.additions + step.deletions > 0 {
                    Text("+\(step.additions)").foregroundStyle(ChatStep.added)
                    Text("−\(step.deletions)").foregroundStyle(ChatStep.removed)
                } else if step.failed {
                    Text("failed").foregroundStyle(ChatStep.removed)
                }
            }
            .scaledFont(14, design: .monospaced, relativeTo: .subheadline)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.leading, nested ? 40 : 16).padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(step.kind == .patch ? "Shows the changes" : "Shows its full output")
    }

    /// The steps between two shown ones, folded: what they did in words, and a disclosure that opens them in place.
    private func foldRow(_ summary: String, count: Int, open: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: "ellipsis")
                    .font(.subheadline).foregroundStyle(.tertiary)
                    .frame(width: glyphWidth)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    .fittingLine()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary), \(ChatTurnSummary.count(count, "step"))")
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(Color.raisedRow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
    }

    private var divider: some View { Rectangle().fill(Color.hairline).frame(height: 0.5).padding(.leading, 16) }

    private func fact<Value: View>(_ name: String, chevron: Bool = false, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value().multilineTextAlignment(.trailing).lineLimit(typeSize > .large ? 3 : 1)
            if chevron {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct ChatDetailsLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// Message details' step list, folded (M1): up to `threshold` steps show as they are; past it the patches, the failed
/// steps and the last step stay, and each run of two or more steps between them folds into one row that says what they
/// did ("Read 5 files, searched 3 times"). A run of one shows: a fold would hide no room.
enum ChatStepFold {
    static let threshold = 8

    enum Entry: Equatable, Identifiable {
        case step(Int)
        case fold(Range<Int>, String)

        var id: String {
            switch self {
            case .step(let index): "step-\(index)"
            case .fold(let range, _): "fold-\(range.lowerBound)"
            }
        }
    }

    static func entries(_ steps: [ChatStep]) -> [Entry] {
        guard steps.count > threshold else { return steps.indices.map(Entry.step) }
        var entries: [Entry] = [], run: [Int] = []
        func flush() {
            if run.count == 1 { entries.append(.step(run[0])) }
            else if let first = run.first, let last = run.last {
                entries.append(.fold(first..<last + 1, summary(steps[first...last])))
            }
            run = []
        }
        for index in steps.indices {
            let step = steps[index]
            if step.kind == .patch || step.failed || index == steps.count - 1 {
                flush()
                entries.append(.step(index))
            } else { run.append(index) }
        }
        flush()
        return entries
    }

    /// What a run of steps did, by kind in the order each first appears: "Read 5 files, searched 3 times, ran 2 commands".
    static func summary(_ steps: ArraySlice<ChatStep>) -> String {
        var order: [ChatStep.Kind] = [], counts: [ChatStep.Kind: Int] = [:]
        for step in steps {
            if counts[step.kind] == nil { order.append(step.kind) }
            counts[step.kind, default: 0] += 1
        }
        func times(_ count: Int) -> String { count == 1 ? "once" : count == 2 ? "twice" : "\(count) times" }
        let parts = order.map { kind -> String in
            let count = counts[kind] ?? 0
            switch kind {
            case .read: return "read " + ChatTurnSummary.count(count, "file")
            case .search: return "searched " + times(count)
            case .run: return "ran " + ChatTurnSummary.count(count, "command")
            case .patch: return "patched " + ChatTurnSummary.count(count, "file")
            case .think: return "thought " + times(count)
            case .web: return "used the web " + times(count)
            case .tool: return "used " + ChatTurnSummary.count(count, "tool")
            }
        }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension ChatStep.Kind {
    /// Message details' glyph for the kind (its word is the glyph's VoiceOver label).
    var symbol: String {
        switch self {
        case .read: "doc.text"
        case .patch: "pencil.line"
        case .run: "apple.terminal"
        case .search: "magnifyingglass"
        case .think: "brain"
        case .web: "globe"
        case .tool: "wrench.and.screwdriver"
        }
    }
}

/// A message's raw text in a read-only `UITextView`: SwiftUI's `textSelection` selects within one `Text` (a paragraph of
/// the rendered Markdown), this selects across the whole text, Select All included. As wide as its longest line, up to
/// the width offered.
struct ChatRawText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let shown = TextRendering.visible(text)
        // Same text, same storage: an update (the transcript refreshing) keeps the selection.
        guard view.text != shown else { return }
        view.attributedText = Self.attributed(shown)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let offered = proposal.width, offered.isFinite else { return nil }
        let used = uiView.attributedText.boundingRect(with: CGSize(width: offered, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let width = min(offered, ceil(used.width))
        return CGSize(width: width, height: ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }

    static func attributed(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .subheadline),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ])
    }
}

/// A step's full output in a sheet (the working row's log, M5f).
struct ChatStepOutputSheet: View {
    let session: MobileChatSession
    let step: ChatStep
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChatStepOutput(session: session, step: step)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Color.dispatchPink)
    }
}

/// A step's full output (`chat.tools`), or its diff for a patch: monospaced, selectable. Pushed from message details,
/// in a sheet from the working row.
struct ChatStepOutput: View {
    let session: MobileChatSession
    let step: ChatStep
    @State private var record: HelperChat.Record?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if step.kind == .patch, !documents.isEmpty {
                    ForEach(Array(documents.enumerated()), id: \.offset) { _, document in
                        Text(TextRendering.visible(document.path)).font(.footnote.weight(.semibold).monospaced())
                        diff(document.diff)
                    }
                } else {
                    let input = ToolPresentation(step.item).input
                    if !input.isEmpty, step.kind == .run {
                        let shown = TextRendering.rich("$ " + input)
                        Text(shown.text).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        if shown.truncated { Text("Input preview truncated").font(.caption).foregroundStyle(.secondary) }
                    }
                    let shown = TextRendering.rich(output.isEmpty ? (record == nil && error == nil ? "Loading…" : "No output.") : output)
                    Text(shown.text)
                        .font(.system(size: 13, design: .monospaced))
                    if shown.truncated { Text("Output preview truncated").font(.caption).foregroundStyle(.secondary) }
                }
                if let error { Text(TextRendering.visible(error)).font(.caption).foregroundStyle(.secondary) }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .navigationTitle(TextRendering.visible(step.title))
        .navigationBarTitleDisplayMode(.inline)
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
        let shown = TextRendering.rich(text)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(line.hasPrefix("+") ? ChatStep.added : line.hasPrefix("-") ? ChatStep.removed : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.hasPrefix("+") ? ChatStep.added.opacity(0.08) : line.hasPrefix("-") ? ChatStep.removed.opacity(0.08) : .clear)
            }
            if shown.truncated { Text("Diff preview truncated").font(.caption).foregroundStyle(.secondary) }
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
