import AppKit
import SwiftUI

/// The comments on the file a `GitDiffView` shows (an uncommitted change's in Review, a commit's in Commits), and what its
/// lines and cards do with them. The comments are the repository's (`ReviewRepository` by `scope`), one review for both
/// tabs; the one being written is the tab's (`FilesSession.reviewDraft`).
@MainActor struct GitDiffReview {
    let session: FilesSession
    let scope: String
    /// Repository-relative.
    let path: String
    /// The uncommitted change shown: its area, and the status it is in. Nil on a commit's diff.
    let area: GitChangeArea?
    let status: GitStatus?
    /// The commit whose diff shows (its full hash), in Commits; nil for the uncommitted changes.
    var commit: String? = nil

    init(session: FilesSession, scope: String, path: String, area: GitChangeArea, status: GitStatus) {
        self.session = session
        self.scope = scope
        self.path = path
        self.area = area
        self.status = status
    }

    /// A commit's file in Commits.
    init(session: FilesSession, scope: String, path: String, commit: String) {
        self.session = session
        self.scope = scope
        self.path = path
        area = nil
        status = nil
        self.commit = commit
    }

    /// The file's comments this diff shows. Uncommitted: all of them, but while the file is also changed in another
    /// area, those written on that area's diff. A commit's: those written on its diff.
    var comments: [ReviewComment] {
        let all = ReviewRepository.shared.review(scope).comments(on: path)
        if let commit { return all.filter { $0.commit == commit } }
        guard let area, let status else { return [] }
        let areas = Set(status.changes.lazy.filter { $0.path == path }.map(\.area))
        return all.filter { $0.shows(in: area, areas: areas) }
    }

    var draft: ReviewDraft? {
        guard let draft = session.reviewDraft, draft.scope == scope, draft.path == path, draft.commit == commit else {
            return nil
        }
        return draft
    }

    /// A new comment on `start`…`end` (nil: the file). A new comment not yet saved on this file moves there with its
    /// text; one on another file (or commit) stays where it was written, so its text never lands on lines it was not
    /// meant for, and this one starts empty (Create review lists the other as not saved). An edit is left unsaved.
    func begin(start: ReviewLine?, end: ReviewLine?, quote: [ReviewQuote], before: [ReviewQuote]? = nil,
               after: [ReviewQuote]? = nil) {
        let current = session.reviewDraft
        let moving = current?.editing == nil && current?.scope == scope && current?.path == path
            && current?.commit == commit
        if !moving {
            if let current, current.editing == nil, !Self.blank(session.reviewDraftText) {
                session.reviewSetAside.removeAll { $0.draft.id == current.id }
                session.reviewSetAside.append(ReviewSetAside(draft: current, text: session.reviewDraftText))
            }
            session.reviewDraftText = ""
        }
        session.reviewDraft = ReviewDraft(id: moving ? current?.id ?? System.uuid() : System.uuid(), focus: System.uuid(),
                                          scope: scope, path: path, start: start, end: end, quote: quote, editing: nil,
                                          area: area, before: before, after: after, commit: commit)
    }

    func beginOnFile() { begin(start: nil, end: nil, quote: []) }

    func edit(_ comment: ReviewComment) {
        session.reviewDraftText = comment.text
        session.reviewDraft = ReviewDraft(id: System.uuid(), focus: System.uuid(), scope: scope, path: path,
                                          start: comment.start, end: comment.end, quote: comment.quote, editing: comment.id,
                                          area: comment.area, commit: comment.commit)
    }

    static func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The diff says how to comment until the review holds something or a comment is being written.
    var showsHint: Bool {
        ReviewRepository.shared.review(scope).comments.isEmpty && session.reviewDraft == nil && session.reviewSetAside.isEmpty
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

    /// Esc or Cancel would throw away text the user wrote: a new comment that is not blank. An edit's text goes back
    /// to the saved comment's, so it never asks.
    var cancelLosesText: Bool { draft?.editing == nil && !Self.blank(session.reviewDraftText) }

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
                                         quote: draft.quote, text: text, created: System.date(), area: draft.area,
                                         before: draft.before, after: draft.after, commit: draft.commit),
                           to: draft.scope)
        }
        session.reviewDraft = nil
        session.reviewDraftText = ""
        return true
    }

    /// ⌥↓ / ⌥↑: the next or previous comment, on whichever file it is (of the commit, on a commit's diff); false at
    /// either end.
    func step(by delta: Int) -> Bool {
        if let commit { return Self.step(session, commit: commit, by: delta) }
        guard let status else { return false }
        return Self.step(session, status: status, by: delta)
    }

    /// ⌥↓ / ⌥↑ on a commit's diff: the commit's next or previous comment, its file picked in the commit's files.
    static func step(_ session: FilesSession, commit: String, by delta: Int) -> Bool {
        guard let scope = session.reviewScope, let detail = session.commitDetail, detail.commit.hash == commit else {
            return false
        }
        let ordered = ReviewNavigation.ordered(ReviewRepository.shared.review(scope), commit: commit,
                                               files: detail.files.map(\.path))
        guard let next = ReviewNavigation.step(from: session.reviewPosition, by: delta, in: ordered,
                                               selectedPath: session.commitFile) else { return false }
        if session.commitFile != next.path { session.commitFile = next.path }
        session.reviewPosition = next.id
        session.reviewReveal = ReviewReveal(comment: next.id, request: System.uuid())
        return true
    }

    static func step(_ session: FilesSession, status: GitStatus, by delta: Int) -> Bool {
        guard let scope = session.reviewScope else { return false }
        let ordered = ReviewNavigation.ordered(ReviewRepository.shared.review(scope), status: status)
        let selected = status.changes.first { $0.id == session.changesSelection }?.path
        guard let next = ReviewNavigation.step(from: session.reviewPosition, by: delta, in: ordered, selectedPath: selected)
        else { return false }
        return reveal(next, session: session, status: status)
    }

    /// Selects the change whose diff shows `comment` and has the diff scroll to it; a comment on a commit opens that
    /// commit's file in Commits.
    @discardableResult static func reveal(_ comment: ReviewComment, session: FilesSession, status: GitStatus) -> Bool {
        if let commit = comment.commit {
            session.select(.commits)
            if session.selectedCommit != commit {
                session.commitFileRequest = comment.path
                session.selectedCommit = commit
            } else if session.commitFile != comment.path {
                session.commitFile = comment.path
            }
            session.reviewPosition = comment.id
            session.reviewReveal = ReviewReveal(comment: comment.id, request: System.uuid())
            return true
        }
        guard let change = ReviewNavigation.change(for: comment, in: status) else { return false }
        // From Commits' Create Review the change shows in Review.
        session.select(.changes)
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

/// A line that takes a comment: a + over its gutter on hover (⇧-click stretches the comment being written to it), a faint
/// one on the keyboard's row (⏎ comments there), and a tint while that comment spans it. Its own hover state, so moving
/// over the diff re-renders one row at a time.
struct ReviewLineAction: ViewModifier {
    let highlighted: Bool
    /// The keyboard's row: its + shows faintly, as ⏎ comments on it.
    var cursor = false
    let identifier: String
    let action: (_ extend: Bool) -> Void
    @Environment(\.chatTheme) private var theme
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(highlighted ? theme.blue.opacity(0.14) : .clear)
            .overlay(alignment: .leading) {
                if hovering || cursor {
                    Button { action(NSEvent.modifierFlags.contains(.shift)) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 16, height: 16)
                            .background(theme.blue, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0.45)
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
    @Environment(\.appTypography) private var typography
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
            .font(typography, .body)
            .lineLimit(1)
            if detached, let last = comment.quote.last {
                Text(verbatim: TextRendering.visible(last.text))
                    .font(theme.typography.codeFont(offset: -1.5))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Text(verbatim: comment.text)
                .font(typography, .label)
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

/// The comment being written: what it is on, the editor (⏎ saves, ⌥⏎ or ⇧⏎ a new line, esc cancels), Cancel and Comment.
/// Cancelling a new comment that holds text asks first, as GitHub does, so esc never throws away a long comment.
struct ReviewComposer: View {
    @Environment(\.appTypography) private var typography
    let review: GitDiffReview
    let draft: ReviewDraft
    @Environment(\.chatTheme) private var theme
    @State private var height: CGFloat = 0
    @State private var empty = true
    @State private var discarding = false

    var body: some View {
        let editing = draft.editing != nil
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: (editing ? "Edit the comment on " : "Comment on ")
                 + ReviewText.target(start: draft.start, end: draft.end))
                .font(typography, .body)
                .foregroundStyle(theme.muted)
            ReviewTextEditor(text: review.session.reviewDraftText, focus: draft.focus,
                             placeholder: "What should the agent change?", label: "Review comment",
                             identifier: "review-composer-text",
                             changed: { text in
                                 review.session.reviewDraftText = text
                                 let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 if blank != empty { empty = blank }
                             },
                             submit: review.save, cancel: cancel, height: $height)
                .frame(height: min(max(height, 30), 220))
                .background(theme.terminal, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
            HStack(spacing: 8) {
                Text("⏎ \(editing ? "saves" : "comments") · ⌥⏎ / ⇧⏎ new line · esc cancels")
                    .font(typography, .caption)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel", action: cancel)
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
        .confirmationDialog("Discard this comment?", isPresented: $discarding) {
            Button("Discard", role: .destructive, action: review.cancel)
            Button("Keep Editing", role: .cancel) { review.session.reviewDraft?.focus = System.uuid() }
        } message: {
            Text("The text you wrote is not saved.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-composer")
    }

    private func cancel() {
        if review.cancelLosesText { discarding = true } else { review.cancel() }
    }
}

// MARK: Create review

/// Create Review in the Review and Commits tabs' header: a blue capsule with the comments' count (a glyph alone when the
/// header is narrow) opening `ReviewFinish`, ⇧⌘⏎ while the tab has the keyboard; before the first comment a quiet one
/// whose help and popover say how to comment. After Copy it offers Clear Comments; after Send or Clear it says what
/// happened for a few seconds (counted from then, not from when it is seen), with Restore Comments or Undo. A review that
/// cannot be saved or read says so beside it.
struct ReviewHeaderButton: View {
    let session: FilesSession
    let focused: Bool
    @Environment(\.appTypography) private var typography
    @Environment(\.chatTheme) private var theme
    @MotionReduced private var reduceMotion
    @State private var finishing = false
    /// The view is under 900 pt, where list and detail stack or show one at a time (`FilesView.shape`): the header has
    /// no room to spare, and the quiet button gives way.
    private var narrow: Bool { session.splitNarrow || session.stackedViews }
    /// Copy Review left the comments in place: the bar offers to clear them for a few seconds.
    @State private var copied: Date?

    /// How long the note after Create review stays.
    static let noteDuration: Duration = .seconds(6)

    var body: some View {
        if let scope = session.reviewScope, let repository = session.git.repository, let status = session.status {
            let reviews = ReviewRepository.shared
            HStack(spacing: 8) {
                Group {
                    if let taken = reviews.copied[scope] {
                        note(taken, sentTo: reviews.sentTo[scope], scope: scope, at: reviews.takenAt[scope])
                    } else {
                        // After Copy the button stays: the review can still be sent.
                        if let copied, !reviews.review(scope).isEmpty { copiedNote(scope: scope, at: copied) }
                        createButton(scope: scope, repository: repository, status: status,
                                     count: reviews.review(scope).comments.count)
                    }
                }
                if let error = reviews.error {
                    Label("Not saved", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(typography, .body)
                        .foregroundStyle(theme.yellow)
                        .lineLimit(1)
                        .fixedSize()
                        .help(error + " · comments written now are gone at the next launch")
                        .accessibilityIdentifier("review-error")
                }
            }
            .font(typography, .label)
            // The button and the note crossfade: copying, Undo and the note's timeout change the repository outside
            // any animation.
            .animation(InterfaceMotion.animation(reduce: reduceMotion), value: reviews.copied[scope] != nil)
            .animation(InterfaceMotion.animation(reduce: reduceMotion), value: copied)
        } else if session.git.repository != nil, let source = session.source, !source.endpoint.isLocal {
            // A remote host's comments are kept by the host's own id (`ReviewScope`): without one, none are taken.
            Label("No comments", systemImage: "text.bubble")
                .labelStyle(.titleAndIcon)
                .font(typography, .body)
                .foregroundStyle(.secondary)
                .help("Comments are kept per host, and \(source.hostLabel ?? "this host") isn’t identified yet. "
                      + "They can be written once its connection is.")
                .accessibilityIdentifier("review-unidentified")
        }
    }

    private func createButton(scope: String, repository: GitRepository, status: GitStatus, count: Int) -> some View {
        let empty = count == 0
        return Button { finishing = true } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Label("Create Review", systemImage: empty ? "text.bubble" : "text.bubble.fill")
                    if !empty { countPill(count) }
                }
                HStack(spacing: 5) {
                    Image(systemName: empty ? "text.bubble" : "text.bubble.fill")
                    if !empty { countPill(count) }
                }
            }
        }
        .buttonStyle(ReviewCreateButtonStyle(quiet: empty))
        // Before the first comment it gives way in a narrow header, which keeps its search and views toggle.
        .opacity(empty && narrow ? 0 : 1)
        .frame(width: empty && narrow ? 0 : nil)
        .allowsHitTesting(!(empty && narrow))
        .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: [.command, .shift]) : nil)
        .help(empty ? "Click + beside a line of a diff (or press ⏎ on it) to comment; Create Review then sends or copies "
                      + "the comments to an agent as one review · ⇧⌘⏎"
                    : "Send or copy the comments as one review for an agent · ⇧⌘⏎")
        .accessibilityLabel("Create Review")
        .accessibilityValue(ReviewText.count(count))
        .accessibilityIdentifier("review-create")
        .popover(isPresented: $finishing, arrowEdge: .bottom) {
            ReviewFinish(session: session, scope: scope, status: status, repository: repository,
                         copied: { copied = System.date() }) {
                finishing = false
            }
        }
    }

    /// How many comments the review holds, in the button's blue on white.
    private func countPill(_ count: Int) -> some View {
        Text(verbatim: FilesFormatting.count(count))
            .font(typography, .caption)
            .foregroundStyle(theme.blue)
            .monospacedDigit()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(0.92)))
            .accessibilityIdentifier("review-create-count")
    }

    /// After Copy Review: the comments are still here; Clear Comments takes them (with Undo).
    private func copiedNote(scope: String, at date: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.green)
            Text("Copied")
                .foregroundStyle(Chrome.palette.ink)
                .lineLimit(1)
                .accessibilityIdentifier("review-copied")
            Button("Clear Comments") {
                copied = nil
                ReviewRepository.shared.take(scope)
            }
            .buttonStyle(FilePreviewButtonStyle(prominent: false))
            .help("The review is on the clipboard: clear its comments here")
            .accessibilityIdentifier("review-clear")
        }
        .transition(.opacity)
        .task(id: date) {
            guard let left = Self.left(since: date) else { copied = nil; return }
            do { try await System.sleep(for: left, "review-copied-note") } catch { return }
            if copied == date { copied = nil }
        }
    }

    /// After Send (the comments went to the agent) or Clear Comments: what happened, and the way back.
    private func note(_ taken: Review, sentTo agent: String?, scope: String, at date: Date?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.green)
            Text(verbatim: agent.map { "Sent to \($0)" } ?? "Cleared")
                .foregroundStyle(Chrome.palette.ink)
                .lineLimit(1)
                .help(ReviewText.count(taken.comments.count))
                .accessibilityIdentifier("review-copied")
            // A sent review cannot be unsent: the comments come back here, the agent keeps what it got.
            Button(agent == nil ? "Undo" : "Restore Comments") { ReviewRepository.shared.restore(scope) }
                .buttonStyle(FilePreviewButtonStyle(prominent: false))
                .help(agent == nil ? "Bring the comments back"
                      : "Bring the comments back here; \(agent ?? "the agent") keeps the review it was sent")
                .accessibilityIdentifier("review-undo")
        }
        .transition(.opacity)
        .task(id: taken) {
            guard let left = date.flatMap(Self.left(since:)) ?? (date == nil ? Self.noteDuration : nil) else {
                ReviewRepository.shared.forgetCopied(scope)
                return
            }
            do { try await System.sleep(for: left, "review-note") } catch { return }
            ReviewRepository.shared.forgetCopied(scope)
        }
    }

    /// What is left of the note's time since `date` (by the clock, so a note first seen minutes later is gone); nil
    /// when nothing is.
    static func left(since date: Date) -> Duration? {
        let left = noteDuration - .milliseconds(Int(System.date().timeIntervalSince(date) * 1000))
        return left > .zero ? left : nil
    }
}

/// The header's one coloured control: a blue capsule, white text; quiet (an outline in the muted ink) before the
/// review holds a comment.
private struct ReviewCreateButtonStyle: ButtonStyle {
    var quiet = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, quiet: quiet)
    }

    private struct Styled: View {
        @Environment(\.chatTheme) private var theme
        @Environment(\.appTypography) private var typography
        let configuration: Configuration
        let quiet: Bool

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .foregroundStyle(quiet ? theme.muted : Color.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: typography.expanded(22))
                .hoverFill(Capsule(), color: quiet ? nil : Color.white.opacity(0.14))
                .background {
                    if quiet {
                        Capsule().strokeBorder(theme.border).background(Capsule().fill(theme.ink.opacity(configuration.isPressed ? 0.08 : 0)))
                    } else {
                        Capsule().fill(theme.blue.opacity(configuration.isPressed ? 0.75 : 0.9))
                    }
                }
                .contentShape(Capsule())
        }
    }
}

/// A comment written but not saved: the tab's open one, or one set aside when a comment was started on another file
/// (`FilesSession.reviewSetAside`). Create Review lists it and sends it only once kept.
struct ReviewUnsaved: Identifiable {
    let draft: ReviewDraft
    let text: String
    /// The composer that is open now, rather than one set aside.
    let open: Bool
    var id: UUID { draft.id }

    /// The scope's unsaved new comments in `session`, the open one first.
    @MainActor static func all(_ session: FilesSession, scope: String) -> [ReviewUnsaved] {
        var result: [ReviewUnsaved] = []
        if let draft = session.reviewDraft, draft.scope == scope, draft.editing == nil,
           !GitDiffReview.blank(session.reviewDraftText) {
            result.append(ReviewUnsaved(draft: draft, text: session.reviewDraftText, open: true))
        }
        for aside in session.reviewSetAside where aside.draft.scope == scope {
            result.append(ReviewUnsaved(draft: aside.draft, text: aside.text, open: false))
        }
        return result
    }

    /// Keep: it becomes a comment like the others.
    @MainActor func keep(in session: FilesSession) {
        if open {
            GitDiffReview.save(session)
        } else {
            ReviewRepository.shared.add(ReviewComment(id: System.uuid(), path: draft.path, start: draft.start, end: draft.end,
                                                      quote: draft.quote, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      created: System.date(), area: draft.area, before: draft.before,
                                                      after: draft.after, commit: draft.commit),
                                        to: draft.scope)
            session.reviewSetAside.removeAll { $0.draft.id == draft.id }
        }
    }

    @MainActor func discard(in session: FilesSession) {
        if open {
            session.reviewDraft = nil
            session.reviewDraftText = ""
        } else {
            session.reviewSetAside.removeAll { $0.draft.id == draft.id }
        }
    }
}

/// Create Review's popover: the comments (a click shows one), comments written but not saved (Keep or Discard), the
/// overall comment (⏎ a new line, ⌘⏎ sends), then Copy Review, or Send to an agent Chat can talk to (this tab's, or
/// another's). Either finds every comment's line again in the files as they are now (`ReviewRefresh`) and hands over
/// the review's text. Copy leaves the comments (the bar then offers Clear Comments); Send clears them (the bar's
/// Restore Comments brings them back). A comment not saved never goes out unless kept.
private struct ReviewFinish: View {
    @Environment(\.appTypography) private var typography
    let session: FilesSession
    let scope: String
    let status: GitStatus
    let repository: GitRepository
    /// Copy Review finished: the header offers Clear Comments.
    let copied: () -> Void
    let done: () -> Void
    @Environment(\.chatTheme) private var theme
    @State private var height: CGFloat = 0
    @State private var focus = System.uuid()
    /// Reading the commented files again before the review goes out.
    @State private var checking: Task<Void, Never>?

    var body: some View {
        let review = ReviewRepository.shared.review(scope)
        let files = Set(review.comments.map(\.path)).count
        let unsaved = ReviewUnsaved.all(session, scope: scope)
        let targets = ReviewAgent.targets(from: session.id)
        // This tab's own agent is the button; every agent tab (this one first) is in the menu beside it.
        let agent = targets.first { $0.tab == session.id }
        VStack(alignment: .leading, spacing: 10) {
            Text("Finish your review").font(typography, .content, weight: .semibold).foregroundStyle(theme.ink)
            Text(verbatim: Self.summary(comments: review.comments.count, files: files, unsaved: unsaved.count))
                .font(typography, .body)
                .foregroundStyle(theme.muted)
            if review.comments.isEmpty && unsaved.isEmpty {
                Text("Click + beside a line of a diff in Review or Commits (or press ⏎ on it) to comment on it for the "
                     + "agent. The comments stay until you send them.")
                    .font(typography, .body)
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("review-finish-hint")
            }
            if !review.comments.isEmpty { overview(review) }
            if !unsaved.isEmpty { unsavedList(unsaved) }
            ReviewTextEditor(text: review.summary, focus: focus, placeholder: "Overall comment (optional)",
                             label: "Overall comment", identifier: "review-summary",
                             changed: { ReviewRepository.shared.setSummary($0, in: scope) },
                             submit: { if let agent { send(to: agent) } else { copy() } }, cancel: done, height: $height,
                             returnInsertsNewline: true)
                .frame(height: min(max(height, 54), 200))
                .background(theme.terminal, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
            HStack(spacing: 8) {
                if checking != nil {
                    ProgressView().controlSize(.small)
                    Text(verbatim: Self.checking(review))
                        .font(typography, .caption)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                } else {
                    Text(agent != nil ? "⌘⏎ sends · Send clears the comments" : "⌘⏎ copies · Copy keeps the comments")
                        .font(typography, .caption)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                // Cancel stays live while the lines are read: it stops the read (as closing the popover does).
                Button("Cancel", action: done)
                    .buttonStyle(FilePreviewButtonStyle(prominent: false))
                    .help(checking != nil ? "Stop checking the lines; nothing is sent" : "Close · esc")
                    .accessibilityIdentifier("review-cancel")
                Group {
                    Button("Copy Review", action: copy)
                        .buttonStyle(FilePreviewButtonStyle(prominent: agent == nil))
                        .help("Copy the review’s text; the comments stay")
                        .accessibilityIdentifier("review-copy")
                    if let agent {
                        Button("Send to \(agent.session.agentTitle)") { send(to: agent) }
                            .buttonStyle(FilePreviewButtonStyle())
                            .help("Send the review to the agent in this tab, as its chat would, and clear the comments")
                            .accessibilityIdentifier("review-send")
                    }
                    if targets.contains(where: { $0.tab != session.id }) {
                        Menu {
                            ForEach(targets) { target in
                                Button(target.title(current: session.id)) { send(to: target) }
                            }
                        } label: {
                            Text(agent == nil ? "Send to…" : "Other Agent…")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(typography, .body)
                        .help("Send the review to the agent in another tab; that tab shows its chat")
                        .accessibilityIdentifier("review-send-menu")
                    }
                }
                .disabled(checking != nil || review.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 520)
        .onDisappear { checking?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-finish")
    }

    /// "3 comments on 2 files · 1 not saved", "No comments on lines yet".
    static func summary(comments: Int, files: Int, unsaved: Int) -> String {
        var text = comments == 0 ? "No comments on lines yet"
            : "\(ReviewText.count(comments)) on \(FilesFormatting.count(files)) \(files == 1 ? "file" : "files")"
        if unsaved > 0 { text += " · \(FilesFormatting.count(unsaved)) not saved" }
        return text
    }

    /// "Checking the lines in 3 files…": every file a comment on lines is on is read again.
    static func checking(_ review: Review) -> String {
        let files = Set(review.comments.filter { !$0.onFile }.map(\.path)).count
        return files == 0 ? "Checking the lines…"
            : "Checking the lines in \(FilesFormatting.count(files)) \(files == 1 ? "file" : "files")…"
    }

    /// Every comment in the review's order, the file and line beside the start of its text: a click shows it.
    private func overview(_ review: Review) -> some View {
        let comments = review.files.flatMap(\.comments)
        let listed = Set(status.changes.map(\.path))
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(comments) { comment in
                    let shown = comment.commit != nil || listed.contains(comment.path)
                    Button {
                        if GitDiffReview.reveal(comment, session: session, status: status) { done() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: FilesPath.name(comment.path)).foregroundStyle(theme.ink)
                            Text(verbatim: ReviewText.place(comment)).foregroundStyle(theme.blue)
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
                    .disabled(!shown)
                    .help(shown ? comment.path : "\(comment.path) has no changes now; the review still sends this comment")
                    .accessibilityIdentifier("review-overview-comment")
                }
            }
        }
        .font(typography, .body)
        .frame(maxHeight: min(CGFloat(comments.count) * 22, 176))
        .accessibilityIdentifier("review-overview")
    }

    /// Comments written but not saved: each goes out only once kept.
    private func unsavedList(_ unsaved: [ReviewUnsaved]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(unsaved) { item in
                HStack(spacing: 6) {
                    Image(systemName: "pencil.circle").foregroundStyle(theme.yellow)
                    Text("Not saved:").foregroundStyle(theme.muted)
                    Text(verbatim: FilesPath.name(item.draft.path)).foregroundStyle(theme.ink)
                    Text(verbatim: ReviewText.location(start: item.draft.start, end: item.draft.end)
                         + (item.draft.commit.map { " in commit " + ReviewText.short($0) } ?? ""))
                        .foregroundStyle(theme.blue)
                    Text(verbatim: item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                        .foregroundStyle(theme.muted)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button("Keep") { item.keep(in: session) }
                        .buttonStyle(FilePreviewButtonStyle(prominent: false))
                        .help("Save it as a comment of this review")
                        .accessibilityIdentifier("review-unsaved-keep")
                    Button("Discard") { item.discard(in: session) }
                        .buttonStyle(FilePreviewButtonStyle(prominent: false))
                        .help("Throw this comment away")
                        .accessibilityIdentifier("review-unsaved-discard")
                }
                .lineLimit(1)
                .frame(height: 24)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("review-unsaved")
            }
        }
        .font(typography, .body)
    }

    /// Copies the review's text; the comments stay (the header then offers Clear Comments).
    private func copy() {
        finish(take: nil) { text in
            GitPasteboard.copy(text)
            copied()
        }
    }

    private func send(to target: ReviewAgent.Target) {
        finish(take: target.session.agentTitle) { ReviewAgent.send($0, to: target, from: session.id) }
    }

    /// Finds every comment's line again in the files as they are now, then hands the review's text to `deliver`;
    /// with `take` (the agent it goes to), the review leaves the repository too. A comment not saved is not in it.
    /// Nothing happens with nothing to hand over, or once the popover closed.
    private func finish(take agent: String?, _ deliver: @escaping @MainActor (String) -> Void) {
        guard checking == nil else { return }
        let reviews = ReviewRepository.shared
        guard !reviews.review(scope).isEmpty else { return }
        let queries = session.source.map { GitQueries(source: $0, root: repository.root) }
        let scope = scope, status = status, root = repository.root, host = session.hostLabel
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
            if let agent { reviews.take(scope, sentTo: agent) }
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

/// A comment's editor: the chat composer's text view (its own caret, ⏎ submits, ⌥⏎ or ⇧⏎ a new line, esc cancels), growing
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
    /// ⏎ adds a line and ⌘⏎ submits, as a form's long text field (the review's overall comment); else ⏎ submits.
    var returnInsertsNewline = false

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
        // A field where ⏎ adds a line stays out of the composer's multiline mode, where esc would not cancel.
        view.multiline = !returnInsertsNewline && text.contains("\n")
        view.returnInsertsNewline = returnInsertsNewline
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
        var returnInsertsNewline = false
        override func didMeasure(_ height: CGFloat) { onHeight?(height) }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if returnInsertsNewline, event.keyCode == 36 || event.keyCode == 76, flags.isEmpty, !hasMarkedText() {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            super.keyDown(with: event)
        }
    }
}
