import AppKit
import SwiftUI

/// The Review tab's comments on the file a `GitDiffView` shows, and what its lines and cards do with them. The comments
/// are the repository's (`ReviewRepository` by `scope`); the one being written is the tab's (`FilesSession.reviewDraft`).
@MainActor struct GitDiffReview {
    let session: FilesSession
    let scope: String
    /// Repository-relative.
    let path: String
    /// The diff shown: the change's area, and the status it is in.
    let area: GitChangeArea
    let status: GitStatus

    /// The file's comments this diff shows: all of them, but while the file is also changed in another area, those
    /// written on that area's diff.
    var comments: [ReviewComment] {
        let areas = Set(status.changes.lazy.filter { $0.path == path }.map(\.area))
        return ReviewRepository.shared.review(scope).comments(on: path).filter { $0.shows(in: area, areas: areas) }
    }

    var draft: ReviewDraft? {
        guard let draft = session.reviewDraft, draft.scope == scope, draft.path == path else { return nil }
        return draft
    }

    /// A new comment on `start`…`end` (nil: the file). A new comment not yet saved moves there with its text; an edit
    /// is left unsaved.
    func begin(start: ReviewLine?, end: ReviewLine?, quote: [ReviewQuote]) {
        let current = session.reviewDraft
        let moving = current?.editing == nil && current != nil
        if !moving { session.reviewDraftText = "" }
        session.reviewDraft = ReviewDraft(id: moving ? current?.id ?? System.uuid() : System.uuid(), focus: System.uuid(),
                                          scope: scope, path: path, start: start, end: end, quote: quote, editing: nil,
                                          area: area)
    }

    func beginOnFile() { begin(start: nil, end: nil, quote: []) }

    func edit(_ comment: ReviewComment) {
        session.reviewDraftText = comment.text
        session.reviewDraft = ReviewDraft(id: System.uuid(), focus: System.uuid(), scope: scope, path: path,
                                          start: comment.start, end: comment.end, quote: comment.quote, editing: comment.id,
                                          area: comment.area)
    }

    func delete(_ comment: ReviewComment) {
        if session.reviewDraft?.editing == comment.id { cancel() }
        ReviewRepository.shared.remove(comment.id, from: scope)
    }

    /// ⏎ or Comment: the draft becomes a comment (or the edited one takes its text). An empty draft stays open.
    func save() { Self.save(session) }

    func cancel() {
        session.reviewDraft = nil
        session.reviewDraftText = ""
    }

    /// Saves the tab's draft into its review, wherever it is; false when there is nothing to save.
    @discardableResult static func save(_ session: FilesSession) -> Bool {
        guard let draft = session.reviewDraft else { return false }
        let text = session.reviewDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let repository = ReviewRepository.shared
        if let id = draft.editing {
            repository.update(id, text: text, in: draft.scope)
        } else {
            repository.add(ReviewComment(id: System.uuid(), path: draft.path, start: draft.start, end: draft.end,
                                         quote: draft.quote, text: text, created: System.date(), area: draft.area),
                           to: draft.scope)
        }
        session.reviewDraft = nil
        session.reviewDraftText = ""
        return true
    }

    /// ⌥↓ / ⌥↑: the next or previous comment, on whichever file it is; false at either end.
    func step(by delta: Int) -> Bool { Self.step(session, status: status, by: delta) }

    static func step(_ session: FilesSession, status: GitStatus, by delta: Int) -> Bool {
        guard let scope = session.reviewScope else { return false }
        let ordered = ReviewNavigation.ordered(ReviewRepository.shared.review(scope), status: status)
        let selected = status.changes.first { $0.id == session.changesSelection }?.path
        guard let next = ReviewNavigation.step(from: session.reviewPosition, by: delta, in: ordered, selectedPath: selected)
        else { return false }
        return reveal(next, session: session, status: status)
    }

    /// Selects the change whose diff shows `comment` and has the diff scroll to it.
    @discardableResult static func reveal(_ comment: ReviewComment, session: FilesSession, status: GitStatus) -> Bool {
        guard let change = ReviewNavigation.change(for: comment, in: status) else { return false }
        if session.changesSelection != change.id { session.changesSelection = change.id }
        session.reviewPosition = comment.id
        session.reviewReveal = ReviewReveal(comment: comment.id, request: System.uuid())
        return true
    }
}

extension ReviewText {
    /// What the composer says it comments on: "line 12", "removed lines 9–10", "the file".
    static func target(start: ReviewLine?, end: ReviewLine?) -> String {
        guard end != nil else { return "the file" }
        let location = location(start: start, end: end)
        return location.prefix(1).lowercased() + location.dropFirst()
    }
}

// MARK: Lines

/// A line that takes a comment: a + over its gutter on hover (⇧-click stretches the comment being written to it), and a
/// tint while that comment spans it. Its own hover state, so moving over the diff re-renders one row at a time.
struct ReviewLineAction: ViewModifier {
    let highlighted: Bool
    let identifier: String
    let action: (_ extend: Bool) -> Void
    @Environment(\.chatTheme) private var theme
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(highlighted ? theme.blue.opacity(0.14) : .clear)
            .overlay(alignment: .leading) {
                if hovering {
                    Button { action(NSEvent.modifierFlags.contains(.shift)) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 16, height: 16)
                            .background(theme.blue, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 3)
                    .help("Comment on this line · ⇧-click stretches the comment being written to here")
                    .accessibilityIdentifier(identifier)
                }
            }
            .onHover { hovering = $0 }
            .accessibilityAction(named: "Comment") { action(false) }
    }
}

// MARK: Cards

/// A saved comment under its line: where it is, its text, Edit and Delete. One whose line is not among the rows (on the
/// file's top) quotes the line it was written on.
struct ReviewCommentCard: View {
    let review: GitDiffReview
    let comment: ReviewComment
    /// Its line is not among the rows: the file changed there, or the view does not show it.
    let detached: Bool
    /// ⌥↓ / ⌥↑ last went to it.
    var revealed = false
    @Environment(\.chatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").foregroundStyle(theme.blue)
                Text(verbatim: ReviewText.location(comment)).foregroundStyle(theme.ink)
                if detached {
                    Text("· not in this view").foregroundStyle(theme.muted)
                        .help("The line changed since, or this view does not show it; the review quotes it as it was")
                }
                Spacer(minLength: 8)
                Button("Edit") { review.edit(comment) }
                    .buttonStyle(FilePreviewButtonStyle(prominent: false))
                    .accessibilityIdentifier("review-comment-edit")
                Button("Delete") { review.delete(comment) }
                    .buttonStyle(FilePreviewButtonStyle(prominent: false))
                    .accessibilityIdentifier("review-comment-delete")
            }
            .font(theme.typography.font(offset: -1.5))
            .lineLimit(1)
            if detached, let last = comment.quote.last {
                Text(verbatim: TextRendering.visible(last.text))
                    .font(theme.typography.codeFont(offset: -1.5))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Text(verbatim: comment.text)
                .font(theme.typography.font(offset: -0.5))
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("review-comment-text")
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 8))
        .background(Chrome.window, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(revealed ? theme.blue : theme.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-comment")
    }
}

/// The comment being written: what it is on, the editor (⏎ saves, ⇧⏎ a new line, esc cancels), Cancel and Comment.
struct ReviewComposer: View {
    let review: GitDiffReview
    let draft: ReviewDraft
    @Environment(\.chatTheme) private var theme
    @State private var height: CGFloat = 0
    @State private var empty = true

    var body: some View {
        let editing = draft.editing != nil
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: (editing ? "Edit the comment on " : "Comment on ")
                 + ReviewText.target(start: draft.start, end: draft.end))
                .font(theme.typography.font(offset: -1.5))
                .foregroundStyle(theme.muted)
            ReviewTextEditor(text: review.session.reviewDraftText, focus: draft.focus,
                             placeholder: "What should the agent change?", label: "Review comment",
                             identifier: "review-composer-text",
                             changed: { text in
                                 review.session.reviewDraftText = text
                                 let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 if blank != empty { empty = blank }
                             },
                             submit: review.save, cancel: review.cancel, height: $height)
                .frame(height: min(max(height, 30), 220))
                .background(theme.terminal, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
            HStack(spacing: 8) {
                Text("⏎ \(editing ? "saves" : "comments") · ⇧⏎ new line · esc cancels")
                    .font(theme.typography.font(offset: -2))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel", action: review.cancel)
                    .buttonStyle(FilePreviewButtonStyle(prominent: false))
                    .accessibilityIdentifier("review-composer-cancel")
                Button(editing ? "Save" : "Comment", action: review.save)
                    .buttonStyle(FilePreviewButtonStyle())
                    .disabled(empty)
                    .accessibilityIdentifier("review-composer-save")
            }
        }
        .padding(10)
        .background(Chrome.window, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.blue.opacity(0.5)))
        .onAppear { empty = review.session.reviewDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-composer")
    }
}

// MARK: Create review

/// Create review in the Review tab's header, once the review holds something: a blue capsule (a glyph alone when the
/// header is narrow) opening `ReviewFinish`, ⇧⌘⏎ while the tab has the keyboard. After the review went out it says
/// where for a few seconds, with Undo, then leaves with the comments.
struct ReviewHeaderButton: View {
    let session: FilesSession
    let focused: Bool
    @Environment(\.appTypography) private var typography
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finishing = false

    /// How long the note after Create review stays.
    static let noteDuration: Duration = .seconds(6)

    var body: some View {
        if let scope = session.reviewScope, let repository = session.git.repository, let status = session.status {
            let reviews = ReviewRepository.shared
            Group {
                if let copied = reviews.copied[scope] {
                    note(copied, sentTo: reviews.sentTo[scope], scope: scope)
                } else if !reviews.review(scope).isEmpty {
                    Button { finishing = true } label: {
                        ViewThatFits(in: .horizontal) {
                            Label("Create review", systemImage: "text.bubble.fill")
                            Image(systemName: "text.bubble.fill")
                        }
                    }
                    .buttonStyle(ReviewCreateButtonStyle())
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: [.command, .shift]) : nil)
                    .help("Send or copy the comments as one review for an agent · ⇧⌘⏎")
                    .accessibilityLabel("Create review")
                    .accessibilityIdentifier("review-create")
                    .popover(isPresented: $finishing, arrowEdge: .bottom) {
                        ReviewFinish(session: session, scope: scope, status: status, repository: repository) {
                            finishing = false
                        }
                    }
                }
            }
            .font(AppFont.ui(size: typography.size(offset: -1)))
            // The button and the note crossfade: copying, Undo and the note's timeout change the repository outside
            // any animation.
            .animation(InterfaceMotion.animation(reduce: reduceMotion), value: reviews.copied[scope] != nil)
        }
    }

    private func note(_ copied: Review, sentTo agent: String?, scope: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.green)
            Text(verbatim: agent.map { "Sent to \($0)" } ?? "Copied")
                .foregroundStyle(Chrome.palette.ink)
                .lineLimit(1)
                .help(ReviewText.count(copied.comments.count))
                .accessibilityIdentifier("review-copied")
            Button("Undo") { ReviewRepository.shared.restore(scope) }
                .buttonStyle(FilePreviewButtonStyle(prominent: false))
                .help("Bring the comments back")
                .accessibilityIdentifier("review-undo")
        }
        .transition(.opacity)
        .task(id: copied) {
            do { try await System.sleep(for: Self.noteDuration, "review-note") } catch { return }
            ReviewRepository.shared.forgetCopied(scope)
        }
    }

}

/// The header's one coloured control: a blue capsule, white text.
private struct ReviewCreateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        @Environment(\.chatTheme) private var theme
        @Environment(\.appTypography) private var typography
        let configuration: Configuration

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: typography.expanded(22))
                .background(Capsule().fill(theme.blue.opacity(configuration.isPressed ? 0.75 : 0.9)))
                .contentShape(Capsule())
        }
    }
}

/// Create review's popover: the comments (a click shows one), the overall comment, then Copy review, or Send to an agent
/// Chat can talk to (this tab's, or another's). Either saves a comment still being written, finds every comment's line
/// again in the files as they are now (`ReviewRefresh`), hands over the review's text and clears the comments (the bar's
/// Undo brings them back).
private struct ReviewFinish: View {
    let session: FilesSession
    let scope: String
    let status: GitStatus
    let repository: GitRepository
    let done: () -> Void
    @Environment(\.chatTheme) private var theme
    @State private var height: CGFloat = 0
    @State private var focus = System.uuid()
    /// Reading the commented files again before the review goes out.
    @State private var checking: Task<Void, Never>?

    var body: some View {
        let review = ReviewRepository.shared.review(scope)
        let files = Set(review.comments.map(\.path)).count
        let targets = ReviewAgent.targets(from: session.id)
        // This tab's own agent is the button; every agent tab (this one first) is in the menu beside it.
        let agent = targets.first { $0.tab == session.id }
        VStack(alignment: .leading, spacing: 10) {
            Text("Finish your review").font(theme.typography.font(weight: .semibold)).foregroundStyle(theme.ink)
            Text(verbatim: review.comments.isEmpty ? "No comments on lines yet"
                 : "\(ReviewText.count(review.comments.count)) on \(FilesFormatting.count(files)) \(files == 1 ? "file" : "files")")
                .font(theme.typography.font(offset: -1.5))
                .foregroundStyle(theme.muted)
            if !review.comments.isEmpty { overview(review) }
            ReviewTextEditor(text: review.summary, focus: focus, placeholder: "Overall comment (optional)",
                             label: "Overall comment", identifier: "review-summary",
                             changed: { ReviewRepository.shared.setSummary($0, in: scope) },
                             submit: { if let agent { send(to: agent) } else { copy() } }, cancel: done, height: $height)
                .frame(height: min(max(height, 54), 200))
                .background(theme.terminal, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
            HStack(spacing: 8) {
                if checking != nil {
                    ProgressView().controlSize(.small)
                    Text("Checking the lines…")
                        .font(theme.typography.font(offset: -2))
                        .foregroundStyle(theme.muted)
                } else {
                    Text(targets.isEmpty ? "Copies the review and clears the comments" : "Then clears the comments")
                        .font(theme.typography.font(offset: -2))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Cancel", action: done)
                    .buttonStyle(FilePreviewButtonStyle(prominent: false))
                Button("Copy review", action: copy)
                    .buttonStyle(FilePreviewButtonStyle(prominent: agent == nil))
                    .accessibilityIdentifier("review-copy")
                if let agent {
                    Button("Send to \(agent.session.agentTitle)") { send(to: agent) }
                        .buttonStyle(FilePreviewButtonStyle())
                        .help("Send the review to the agent in this tab, as its chat would")
                        .accessibilityIdentifier("review-send")
                }
                if targets.contains(where: { $0.tab != session.id }) {
                    Menu {
                        ForEach(targets) { target in
                            Button(target.title(current: session.id)) { send(to: target) }
                        }
                    } label: {
                        Text(agent == nil ? "Send to…" : "Other agent…")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(theme.typography.font(offset: -1.5))
                    .help("Send the review to the agent in another tab; that tab shows its chat")
                    .accessibilityIdentifier("review-send-menu")
                }
            }
            .disabled(checking != nil)
        }
        .padding(14)
        .frame(width: 520)
        .onDisappear { checking?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-finish")
    }

    /// Every comment in the review's order, the file and line beside the start of its text: a click shows it.
    private func overview(_ review: Review) -> some View {
        let comments = review.files.flatMap(\.comments)
        let listed = Set(status.changes.map(\.path))
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(comments) { comment in
                    Button {
                        if GitDiffReview.reveal(comment, session: session, status: status) { done() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: FilesPath.name(comment.path)).foregroundStyle(theme.ink)
                            Text(verbatim: ReviewText.location(comment)).foregroundStyle(theme.blue)
                            Text(verbatim: comment.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                                .foregroundStyle(theme.muted)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .lineLimit(1)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!listed.contains(comment.path))
                    .help(listed.contains(comment.path) ? comment.path : "\(comment.path) has no changes now")
                    .accessibilityIdentifier("review-overview-comment")
                }
            }
        }
        .font(theme.typography.font(offset: -1.5))
        .frame(maxHeight: min(CGFloat(comments.count) * 22, 176))
        .accessibilityIdentifier("review-overview")
    }

    private func copy() { finish(sentTo: nil) { GitPasteboard.copy($0) } }

    private func send(to target: ReviewAgent.Target) {
        finish(sentTo: target.session.agentTitle) { ReviewAgent.send($0, to: target, from: session.id) }
    }

    /// Saves a comment still being written, finds every comment's line again in the files as they are now, then takes
    /// the review from the repository and hands its text to `deliver`. Nothing happens with nothing to hand over, or
    /// once the popover closed.
    private func finish(sentTo agent: String?, _ deliver: @escaping @MainActor (String) -> Void) {
        guard checking == nil else { return }
        if session.reviewDraft?.scope == scope { GitDiffReview.save(session) }
        let reviews = ReviewRepository.shared
        guard !reviews.review(scope).isEmpty else { return }
        let queries = session.source.map { GitQueries(source: $0, root: repository.root) }
        let scope = scope, status = status, root = repository.root, host = session.hostLabel, session = session
        let done = done
        checking = Task { @MainActor in
            var review = reviews.review(scope)
            var refreshed = review
            // A comment edited meanwhile (the summary typed on) is read again with the rest.
            for _ in 0..<3 {
                if let queries { refreshed = await ReviewRefresh.refresh(review, status: status, queries: queries) }
                guard !Task.isCancelled else { return }
                let now = reviews.review(scope)
                if now == review { break }
                review = now
                refreshed = now
            }
            checking = nil
            guard reviews.review(scope) == review, !review.isEmpty else { return }
            let text = ReviewText.render(refreshed, context: .init(root: root, host: host, branch: status.branch,
                                                                   head: status.head))
            reviews.take(scope, sentTo: agent)
            if session.reviewDraft?.scope == scope {
                session.reviewDraft = nil
                session.reviewDraftText = ""
            }
            done()
            deliver(text)
        }
    }
}

/// Send to an agent: one Chat found in a tab's terminal (this tab's, or any other's), verified through a helper. The
/// review goes out the way that chat's own Send would: it becomes the chat's draft (a draft already there is kept among
/// the saved ones), its tab is selected and shows its chat, and the composer's Send sends it, or queues it while the
/// agent is busy. Anything that stops that leaves the review in the draft, as for a typed message.
@MainActor enum ReviewAgent {
    struct Target: Identifiable {
        let tab: UUID
        let session: ChatSession
        /// The agent's name and its space's host as the sidebar names it (nil: this Mac), read when the list is made.
        let agent: String
        let host: String?
        /// The tab's name and its space's: "api — Billing".
        let place: String
        var id: UUID { tab }

        /// "Claude Code · api — Billing (this tab)", with the host a remote agent runs on.
        func title(current: UUID) -> String {
            var title = agent + " · " + place
            if let host { title += " on " + host }
            return title + (tab == current ? " (this tab)" : "")
        }
    }

    /// Every tab whose agent can be sent to, in the sidebar's order, the review's own tab first.
    static func targets(from current: UUID) -> [Target] {
        let runtime = TerminalRuntime.shared
        guard let chat = runtime.files.chat, let workspace = runtime.workspace else { return [] }
        var targets: [Target] = []
        for space in workspace.spaces {
            for tab in space.tabs {
                guard let session = chat.sessions[tab.id], session.helper != nil, runtime.files.chatAvailable(tab.id)
                else { continue }
                // Not `session.host`: that is the machine's identity (a drafts key), not a name to show.
                let host = space.hostID == .local ? nil : workspace.hosts.record(space.hostID).name
                targets.append(Target(tab: tab.id, session: session, agent: session.agentTitle, host: host,
                                      place: tab.label + " — " + workspace.liveName(space)))
            }
        }
        return targets.filter { $0.tab == current } + targets.filter { $0.tab != current }
    }

    static func send(_ text: String, to target: Target, from current: UUID) {
        let runtime = TerminalRuntime.shared
        guard let chat = runtime.files.chat else { return }
        let session = target.session
        if !session.drafts.current.isEmpty { session.drafts.keep() }
        session.draft = text
        runtime.files.switchMode(target.tab, to: .chat)
        if target.tab != current { runtime.workspace?.selectTab(target.tab) }
        chat.sendFromComposer(session)
    }
}

// MARK: Editor

/// A comment's editor: the chat composer's text view (its own caret, ⏎ submits, ⇧⏎ a new line, esc cancels), growing
/// with its text. `text` is read when it is made; a new `focus` gives it the keyboard.
struct ReviewTextEditor: NSViewRepresentable {
    @Environment(\.chatTheme) private var theme
    let text: String
    let focus: UUID
    let placeholder: String
    let label: String
    let identifier: String
    let changed: (String) -> Void
    let submit: () -> Void
    let cancel: () -> Void
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        // TextKit 1 without the font's leading, as the chat composers.
        let view = EditorView(usingTextLayoutManager: false)
        view.layoutManager?.usesFontLeading = false
        view.delegate = context.coordinator
        view.allowsUndo = true
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 8, height: 6)
        view.textContainer?.lineFragmentPadding = 0
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.placeholder = placeholder
        view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier(identifier)
        view.applyingState = true
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        view.multiline = text.contains("\n")
        view.applyingState = false
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? EditorView else { return }
        context.coordinator.changed = changed
        if view.appliedTheme?.typography != theme.typography { view.font = theme.typography.reply }
        if view.appliedTheme != theme {
            view.textColor = NSColor(theme.ink)
            view.insertionPointColor = NSColor(theme.ink)
            view.placeholderColor = NSColor(theme.muted)
            view.selectedTextAttributes = [.backgroundColor: NSColor(theme.selection), .foregroundColor: NSColor(theme.selectedText)]
            view.appliedTheme = theme
        }
        view.submit = submit
        view.sendNow = submit
        view.cancel = cancel
        let binding = $height
        view.onHeight = { measured in
            guard abs(binding.wrappedValue - measured) > 0.5 else { return }
            DispatchQueue.main.async { if abs(binding.wrappedValue - measured) > 0.5 { binding.wrappedValue = measured } }
        }
        view.highlight()
        view.measure()
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            view.pendingFocus = true
            DispatchQueue.main.async { [weak view] in view?.fulfillFocusRequest() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(changed) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var changed: (String) -> Void
        var focus: UUID?
        init(_ changed: @escaping (String) -> Void) { self.changed = changed }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? EditorView, !view.applyingState else { return }
            changed(view.string)
            if !view.hasMarkedText() { view.highlight() }
            view.measure()
        }
    }

    final class EditorView: ChatEditorTextView {
        var onHeight: ((CGFloat) -> Void)?
        override func didMeasure(_ height: CGFloat) { onHeight?(height) }
    }
}
