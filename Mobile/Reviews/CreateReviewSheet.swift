import SwiftUI

/// R5: Create review, a full-height sheet over Review's list. The To row names where the review goes (the tab's own
/// agent, another agent of the space, or the clipboard: its menu), then the comments (a tap opens the diff at one, a
/// swipe left deletes it: R5b), the overall comment with dictation, a footnote, and the actions pinned at the bottom as
/// glass over the content: Copy and Preview beside the pink Send. Without an agent in the tab (R5c) Copy is the action
/// and the To row says so. Send and Copy find the comments' lines again first ("Checking the lines…"), then close the
/// sheet; the list's accessory offers Undo for a minute (S4).
struct CreateReviewSheet: View {
    let context: ReviewContext

    /// Where the review goes, as the To row's menu chose it; nil: the tab's own agent, else the clipboard.
    @State private var chosen: Destination?
    @State private var summary: String
    @State private var previewing = false
    /// The comment swiped open (R5b), at most one.
    @State private var opened: UUID?
    @FocusState private var summaryFocused: Bool
    @Environment(\.dismiss) private var dismiss

    enum Destination: Hashable {
        case agent(ChatConversationKey)
        case copy
    }

    init(context: ReviewContext) {
        self.context = context
        _summary = State(initialValue: context.review.repository.review(context.place.scope).summary)
    }

    /// The agent the review goes to now; nil: the clipboard.
    static func target(_ chosen: Destination?, in targets: [ReviewTarget]) -> ReviewTarget? {
        switch chosen {
        case .agent(let key)?: targets.first { $0.key == key }
        case .copy?: nil
        case nil: targets.first(where: \.here)
        }
    }

    /// "this tab · app · fable-5.1", "claude · app · fable-5.1" for another tab.
    static func caption(_ target: ReviewTarget) -> String {
        ([target.here ? "this tab" : target.tab, target.space] + [target.model].compactMap { $0 }).joined(separator: " · ")
    }

    /// The To row without an agent: what else there is.
    static func noAgentCaption(_ targets: [ReviewTarget]) -> String {
        guard let other = targets.first else { return "Copy the review to paste it into any agent" }
        return "Copy the review, or send it to \(other.agent) · \(other.space)"
    }

    /// "3 comments · 2 files".
    static func header(_ review: Review) -> String {
        let files = Set(review.comments.map(\.path)).count
        return "\(ReviewText.count(review.comments.count)) · \(FilesFormatting.count(files)) \(files == 1 ? "file" : "files")"
    }

    var body: some View {
        let review = context.review
        let stored = review.repository.review(context.place.scope)
        let targets = review.targets(context.tab)
        let target = Self.target(chosen, in: targets)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    destinationRow(target: target, targets: targets)
                    comments(stored)
                    MobileCountedSectionHeader(title: "Overall")
                    ReviewSummaryField(text: $summary, focus: $summaryFocused,
                                       placeholder: target.map { "Anything else for \($0.agent)?" } ?? "Anything else?")
                        .padding(.horizontal, 12)
                    if let failure = review.failures[context.place] {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.destructive)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .accessibilityIdentifier("review-send-failure")
                    }
                    Text(target == nil
                         ? "Copied as markdown for pasting into any agent. The comments clear afterwards; Undo brings them back for a minute."
                         : "Sent as one message. The comments clear afterwards; Undo brings them back for a minute.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) { actions(target: target, empty: stored.isEmpty) }
            .background(Color.canvas)
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { close() } label: { Image(systemName: "xmark") }
                        .tint(Color.dispatchPink)
                        .accessibilityLabel("Close")
                }
            }
            .sheet(isPresented: $previewing) {
                ReviewPreviewScreen(context: context)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: summary) { _, text in review.repository.setSummary(text, in: context.place.scope) }
        .onAppear {
            // Debug (`-DispatchReviewSheet swipe`, R5b): the second comment swiped open.
            if review.demo?.sheet == "swipe", opened == nil, stored.files.flatMap(\.comments).count > 1 {
                opened = stored.files.flatMap(\.comments)[1].id
            }
        }
        // The overall comment waits 300 ms before it is written; a closed sheet writes it now.
        .onDisappear { review.repository.flush() }
    }

    // MARK: To

    @ViewBuilder
    private func destinationRow(target: ReviewTarget?, targets: [ReviewTarget]) -> some View {
        Menu {
            ForEach(targets) { option in
                Button {
                    chosen = .agent(option.key)
                } label: {
                    Label("\(option.agent) · \(option.here ? "this tab" : option.tab)",
                          systemImage: option.key == target?.key ? "checkmark" : "bubble.left")
                }
            }
            Divider()
            Button {
                chosen = .copy
            } label: {
                Label("Copy only", systemImage: target == nil ? "checkmark" : "doc.on.doc")
            }
        } label: {
            HStack(spacing: 12) {
                if let target {
                    AgentGlyph(agent: target.agent, size: 18)
                        .frame(width: 40, height: 40)
                        .background(Color.dispatchPink.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text("To").foregroundStyle(.secondary)
                            Text(verbatim: target.agent).fontWeight(.semibold).foregroundStyle(.primary)
                        }
                        .font(.body)
                        Text(verbatim: Self.caption(target)).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: chosen == .copy ? "doc.on.doc" : "text.bubble")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .background(Color.faintFill, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chosen == .copy ? "Copy only" : "No agent in this tab")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(verbatim: chosen == .copy ? "Copied as markdown, sent to no agent" : Self.noAgentCaption(targets))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.raisedRow, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .accessibilityLabel(target.map { "To \($0.agent)" } ?? (chosen == .copy ? "Copy only" : "No agent in this tab"))
        .accessibilityValue(target.map(Self.caption) ?? (chosen == .copy ? "" : Self.noAgentCaption(targets)))
        .accessibilityHint("Chooses where the review goes")
    }

    // MARK: Comments

    @ViewBuilder
    private func comments(_ review: Review) -> some View {
        let comments = review.files.flatMap(\.comments)
        MobileCountedSectionHeader(title: comments.isEmpty ? "No comments" : Self.header(review))
        if !comments.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                    ReviewSheetCommentRow(comment: comment, opened: $opened, open: { open(comment) },
                                          delete: { delete(comment) })
                    if index < comments.count - 1 { MobileHairline().background(Color.raisedRow) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12)
        }
    }

    /// A comment's row: the sheet closes and its change's diff opens at it.
    private func open(_ comment: ReviewComment) {
        let review = context.review
        let route: FilesRoute
        if let status = review.changes(context.place).status, let change = ReviewNavigation.change(for: comment, in: status) {
            route = .review(change)
        } else {
            route = FilesRoute(mode: .review, path: comment.path, detail: comment.area?.rawValue)
        }
        review.reveal[context.place] = comment.id
        close()
        context.push(route)
    }

    private func delete(_ comment: ReviewComment) {
        if opened == comment.id { opened = nil }
        withAnimation(.snappy) { context.review.repository.remove(comment.id, from: context.place.scope) }
    }

    // MARK: Actions

    private func actions(target: ReviewTarget?, empty: Bool) -> some View {
        let sending = context.review.sending.contains(context.place)
        let checking = context.review.checking.contains(context.place) || sending
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if target != nil {
                    circle("doc.on.doc", label: "Copy review") { copy() }
                }
                circle("eye", label: "Preview") { previewing = true }
                Button { if let target { send(target) } else { copy() } } label: {
                    HStack(spacing: 8) {
                        if checking {
                            ProgressView().tint(Color.onAccent)
                            Text(sending ? "Sending…" : "Checking the lines…")
                        } else {
                            Image(systemName: target == nil ? "doc.on.doc.fill" : "paperplane.fill")
                            Text(verbatim: target.map { "Send to \($0.agent)" } ?? "Copy review")
                        }
                    }
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(Color.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
                .accessibilityLabel(sending ? "Sending" : checking ? "Checking the lines" : target.map { "Send to \($0.agent)" } ?? "Copy review")
                .accessibilityIdentifier("review-send")
            }
            .disabled(empty || checking)
            .opacity(empty ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func circle(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }

    private func send(_ target: ReviewTarget) {
        summaryFocused = false
        Task { await context.review.send(to: target, context: context) }
    }

    private func copy() {
        summaryFocused = false
        Task { await context.review.copy(context: context) }
    }

    private func close() {
        if context.review.sheet == context.tab { context.review.sheet = nil } else { dismiss() }
    }
}
