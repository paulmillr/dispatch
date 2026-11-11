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
        let steps = turn.map { ChatStep.steps($0, directory: directory, reasoning: false, thinking: ChatThinkingFold.folds($0.items, ended: $0.ended)) } ?? []
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
            if !MobileVoiceConversation.shared.active(for: session) {
                ChatReadAloudButton(reader: MobileMessageReader.shared, text: row.item.text, row: row.id)
            }
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

    /// The turn's times (`ChatTurnSummary.span`, shared with the Mac's message info).
    static func span(_ turn: ChatTurn?, duration: TimeInterval?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        ChatTurnSummary.span(turn, duration: duration, now: now, calendar: calendar)
    }

    static func moment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        ChatTurnSummary.moment(date, now: now, calendar: calendar)
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

    static func tokens(_ usage: ChatUsage) -> String? { ChatTurnSummary.tokens(usage) }

    static func compact(_ value: Int) -> String { ChatTurnSummary.compact(value) }

    private func stepsHeader(_ steps: [ChatStep]) -> some View {
        let folds = ChatStepFold.entries(steps).contains { if case .fold = $0 { true } else { false } }
        return HStack(alignment: .lastTextBaseline) {
            HStack(spacing: 6) {
                Text("Steps").textCase(.uppercase).accessibilityAddTraits(.isHeader)
                Text(Self.stepCount(steps)).foregroundStyle(.tertiary)
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

    /// "12", or "4 · 1 thought" with a folded turn's thinking among them.
    static func stepCount(_ steps: [ChatStep]) -> String {
        let thoughts = steps.filter { $0.kind == .think }.count
        guard thoughts > 0 else { return "\(steps.count)" }
        let said = ChatTurnSummary.count(thoughts, "thought")
        return thoughts == steps.count ? said : "\(steps.count - thoughts) · \(said)"
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
                ChatStepOutput(session: session, step: step, directory: directory)
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
        .accessibilityHint(step.kind == .patch ? "Shows the changes" : step.kind == .think ? "Shows the whole thought" : "Shows its full output")
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
    var directory: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChatStepOutput(session: session, step: step, directory: directory)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Color.dispatchPink)
    }
}

/// A step opened (from message details, or the working row's sheet), as the Mac opens one (`ChatToolCard`), from the
/// same `ToolPresentation`: what it did (its title and summary, "Read · ChatWorkingRow.swift · lines 70–175") with its
/// status, its folder, the command when the summary does not already say it, the documents it changed, and its output:
/// a read's captured source highlighted at its own line numbers, else each output block as code, Markdown or a note,
/// with Copy; "Done" or "Failed with no output" when there was none. Tool details opens the raw input and output. The
/// full record is asked for (`chat.tools`) as it opens.
struct ChatStepOutput: View {
    let session: MobileChatSession
    let step: ChatStep
    /// The conversation's folder, which summaries name paths from.
    var directory: String? = nil
    @State private var record: HelperChat.Record?
    @State private var error: String?
    @State private var raw = false

    var body: some View {
        let item = item
        let tool = ToolPresentationCache.shared.cached(for: item) ?? ToolPresentation(item)
        let directory = tool.directory ?? self.directory ?? item.directory ?? ""
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(tool, directory: directory)
                if let folder = tool.directory ?? item.directory, !folder.isEmpty {
                    Label(TextRendering.visible(folder), systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
                if step.kind == .think {
                    MobileChatMarkdownView(text: step.item.text)
                } else {
                    details(tool, item: item, directory: directory)
                }
                if let error { Text(TextRendering.visible(error)).font(.caption).foregroundStyle(.secondary) }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .navigationTitle(step.kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openURL, MobileChatMarkdown.openURL)
        .task {
            guard step.kind != .think else { return }
            do { record = try await session.fullOutput(of: step.item) } catch { self.error = error.localizedDescription }
        }
    }

    private var item: ChatItem {
        guard let record, case .item(let item)? = record.display?.action else { return step.item }
        return item
    }

    private var loading: Bool { record == nil && error == nil && step.kind != .think }

    /// The badge, the title and status, and what it acted on: the Mac card's header.
    private func header(_ tool: ToolPresentation, directory: String) -> some View {
        let summary = step.kind == .think ? "" : TextRendering.visible(TextRendering.prefix(tool.displaySummary(in: directory), scalars: 512).text)
        // The title only where it says more than the badge ("Locate", "Run tests"; not "Read" beside READ).
        let title = TextRendering.visible(step.kind == .think ? "Thinking" : tool.displayTitle)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ChatStepBadge(kind: step.kind)
                if title.lowercased() != step.kind.label.lowercased() {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 8)
                status(tool)
            }
            Text(summary.isEmpty ? TextRendering.visible(step.title) : summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func status(_ tool: ToolPresentation) -> some View {
        HStack(spacing: 6) {
            if tool.additions > 0 { Text("+\(tool.additions)").foregroundStyle(ChatStep.added) }
            if tool.deletions > 0 { Text("−\(tool.deletions)").foregroundStyle(ChatStep.removed) }
            if let result = tool.confirmedResult { Text(result).foregroundStyle(ChatStep.added).lineLimit(1) }
            if step.failed {
                Text(tool.exitCode.map { $0 != 0 ? "exit \($0)" : "Failed" } ?? "Failed").foregroundStyle(Color.caution)
                Image(systemName: "exclamationmark.circle").foregroundStyle(Color.caution)
            } else if step.running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(ChatStep.added)
            }
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func details(_ tool: ToolPresentation, item: ChatItem, directory: String) -> some View {
        if let state = item.patch?.state, [.interrupted, .failed, .declined].contains(state) {
            Text("Patch " + state.rawValue).font(.caption).foregroundStyle(.secondary)
        }
        if let patch = item.patch, !item.completed {
            Text(patch.state == .generating ? "Generating changes…" : "Applying changes…").font(.caption).foregroundStyle(.secondary)
        }
        if !tool.input.isEmpty, item.patch == nil, !tool.usesRawDetails {
            ChatStepCodeBlock(title: tool.language == "shell" ? "Command" : "Input", code: tool.input, language: tool.language)
        }
        ForEach(tool.requests) { request in
            let operation = ToolPresentation(request)
            if let read = operation.readCommand {
                Label(read.summary(in: directory), systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
            } else if let action = operation.commandPresentation {
                let summary = operation.displaySummary(in: directory)
                Label(action.title + (summary.isEmpty ? "" : " · " + summary), systemImage: action.symbol)
                    .font(.caption).foregroundStyle(.secondary)
            } else if !operation.input.isEmpty {
                ChatStepCodeBlock(title: "Requested command", code: operation.input, language: operation.language)
            }
        }
        if tool.isOrchestration, tool.requests.isEmpty, tool.output.isEmpty {
            Text("Agent tool activity").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(tool.documents.enumerated()), id: \.offset) { _, document in
            if !document.diff.isEmpty {
                Text(TextRendering.visible(document.displayPath(in: directory))).font(.footnote.weight(.semibold).monospaced())
                diff(document.diff)
            }
        }
        let shownDiff = tool.documents.contains { !$0.diff.isEmpty } && (tool.output.contains("+++ ") || tool.output.contains("*** Update File:"))
        if !tool.output.isEmpty, !shownDiff {
            output(tool)
        } else if loading {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading output…") }
                .font(.caption).foregroundStyle(.secondary)
        } else if !tool.isPatch, tool.completed, tool.output.isEmpty, item.patch == nil {
            Text(tool.failed ? "Failed with no output" : "Done").font(.caption).foregroundStyle(.secondary)
        }
        rawDetails(tool, item: item)
    }

    /// The output as the Mac shows it: a read's captured source at its own line numbers; else each block (code,
    /// Markdown, a note), bounded together, with Copy for all of it.
    @ViewBuilder private func output(_ tool: ToolPresentation) -> some View {
        if let read = tool.sourceReadPreview {
            ChatStepCodeBlock(title: "Captured output", code: tool.output, language: CodeSyntax.language(read.path),
                              firstLine: read.firstLine, copy: tool.output)
        } else {
            let preview = Self.preview(tool.outputBlocks)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Output").foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") { UIPasteboard.general.string = tool.output }
                        .foregroundStyle(Color.dispatchPink)
                        .accessibilityLabel("Copy full tool output")
                }
                .font(.caption.weight(.semibold))
                ForEach(Array(preview.blocks.enumerated()), id: \.offset) { _, block in
                    switch block.kind {
                    case .code(let language): ChatStepCodeBlock(code: block.text, language: language)
                    case .markdown: MobileChatMarkdownView(text: block.text)
                    case .attachment:
                        Text(TextRendering.visible(block.text)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if preview.truncated {
                    Text("Preview shortened · Copy includes the full output").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The Mac's bound on the whole preview: 40 blocks, 32 K characters together.
    static func preview(_ blocks: [ToolOutput.Block]) -> (blocks: [ToolOutput.Block], truncated: Bool) {
        var remaining = 32_768
        var visible: [ToolOutput.Block] = []
        for block in blocks.prefix(40) {
            let bounded = TextRendering.prefix(block.text, scalars: remaining)
            visible.append(.init(kind: block.kind, text: bounded.text))
            remaining -= bounded.text.unicodeScalars.count
            if bounded.truncated || remaining == 0 { return (visible, true) }
        }
        return (visible, visible.count < blocks.count)
    }

    /// "Tool details" (or "Raw details" where the summary stands for the command): the raw input and output.
    @ViewBuilder private func rawDetails(_ tool: ToolPresentation, item: ChatItem) -> some View {
        Button { withAnimation(.snappy(duration: 0.2)) { raw.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").rotationEffect(.degrees(raw ? 90 : 0))
                Text(tool.usesRawDetails ? "Raw details" : "Tool details")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityValue(raw ? "Expanded" : "Collapsed")
        if raw {
            VStack(alignment: .leading, spacing: 8) {
                Text(TextRendering.visible(item.title)).font(.caption).foregroundStyle(.secondary)
                if !item.text.isEmpty {
                    ChatStepCodeBlock(title: "Raw input", code: item.text,
                                      language: tool.isOrchestration ? "javascript" : ToolPresentation.json(item.text) == nil ? "text" : "json")
                }
                if !item.output.isEmpty {
                    ChatStepCodeBlock(title: "Raw output", code: item.output,
                                      language: ToolPresentation.json(item.output) == nil ? "text" : "json")
                }
            }
        }
    }

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

/// A code block in an opened step (the Mac's `ChatCodeBlock`): an optional title (and Copy), the code highlighted in
/// the terminal's font, line numbers from `firstLine` when it is a file's, scrolling sideways; 32 K characters at most.
struct ChatStepCodeBlock: View {
    var title: String? = nil
    let code: String
    let language: String
    var firstLine: Int? = nil
    /// What Copy puts on the clipboard (the whole text); nil shows no Copy.
    var copy: String? = nil
    @Environment(\.chatTypography) private var typography

    var body: some View {
        let preview = TextRendering.prefix(code, scalars: 32_768)
        let lines = CodeSyntax.lines(preview.text.hasSuffix("\n") ? String(preview.text.dropLast()) : preview.text, language: language)
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || copy != nil {
                HStack {
                    if let title { Text(title).foregroundStyle(.secondary) }
                    Spacer()
                    if let copy {
                        Button("Copy") { UIPasteboard.general.string = copy }
                            .foregroundStyle(Color.dispatchPink)
                            .accessibilityLabel("Copy \(title ?? "code")")
                    }
                }
                .font(.caption.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    if let firstLine {
                        VStack(alignment: .trailing, spacing: 0) {
                            ForEach(lines.indices, id: \.self) { index in Text(String(firstLine + index)) }
                        }
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line) }
                    }
                }
                .font(typography.code)
                .padding(10)
            }
            .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if preview.truncated { Text("Preview truncated").font(.caption).foregroundStyle(.secondary) }
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
                try await session.select(model: model, effort: effort)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
