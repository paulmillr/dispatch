import SwiftUI

/// H2: the repository's uncommitted changes, STAGED / UNSTAGED / UNTRACKED, each a card of `ReviewChangeRow`s that push
/// the change's diff. The status is `ReviewChanges`' (read on appear, every 2 s while shown, on foregrounding, on pull
/// and when an agent's turn ends); a failed read keeps the last list, and while the host is offline (S3) the shell dims
/// it and nothing is read.
struct ReviewChangesScreen: View {
    let context: ReviewContext
    @Environment(\.scenePhase) private var phase

    var body: some View {
        let changes = context.review.changes(context.place)
        ReviewChangesList(context: context, changes: changes)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error = context.review.repository.error { ReviewStoreBanner(error: error) }
            }
            .task(id: context.place) { await changes.watch() }
            .onChange(of: phase) { _, phase in
                if phase == .active { Task { await changes.refresh(fresh: true) } }
            }
            #if DEBUG
            .onChange(of: changes.status != nil, initial: true) { _, loaded in
                // `-DispatchReviewDiff <name>`: the screenshots' route into the diff, once.
                guard loaded, !Self.demoPushed, let name = context.review.demo?.diff,
                      let change = changes.status?.changes.first(where: { $0.name == name || $0.path == name }) else { return }
                Self.demoPushed = true
                context.push(.review(change))
            }
            #endif
    }

    #if DEBUG
    @MainActor private static var demoPushed = false
    #endif
}

/// `reviews.json` could not be read or written: the comments are kept in memory only, and the list says so.
struct ReviewStoreBanner: View {
    let error: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.caution)
                .accessibilityHidden(true)
            Text("\(error) Comments are kept until Dispatch quits.")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("review-store-error")
    }
}

/// The list itself, or its empty, loading and error states in the same place.
private struct ReviewChangesList: View {
    let context: ReviewContext
    let changes: ReviewChanges
    /// The iPad's pane shows this change: its row is marked.
    @Environment(\.filesPaneSelection) private var selection

    var body: some View {
        if let status = changes.status {
            let shown = status.matching(changes.searching ? changes.query : "")
            if status.changes.isEmpty {
                state(ReviewListState(symbol: "checkmark.circle", title: "No changes",
                                      message: "The working tree matches \(GitChangesText.branch(status)). Changes the agent makes show here."))
            } else if shown.changes.isEmpty {
                state(ReviewListState(symbol: "magnifyingglass", title: "No matches",
                                      message: "No changed file’s path holds “\(changes.query)”."))
            } else {
                list(shown, all: status)
            }
        } else if let failure = changes.failure, !context.offline {
            state(ReviewListState(symbol: "exclamationmark.triangle", title: Self.title(failure), message: failure.message))
        } else if context.offline {
            state(ReviewListState(symbol: "wifi.slash", title: "\(context.host) is offline",
                                  message: "The changes show once it is back."))
        } else {
            ReviewLoadingState()
        }
    }

    static func title(_ failure: ReviewGitError) -> String {
        switch failure {
        case .notRepository: "Not a repository"
        case .unavailable: "Git isn’t available"
        case .failed, .source: "Couldn’t read the changes"
        }
    }

    private func list(_ shown: GitStatus, all status: GitStatus) -> some View {
        let review = context.review.repository.review(context.place.scope)
        // A file changed in two areas: each diff shows the comments written on it (`ReviewComment.shows`).
        let areas = Dictionary(grouping: status.changes, by: \.path).mapValues { Set($0.map(\.area)) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(GitChangeArea.allCases, id: \.self) { area in
                    let rows = shown.changes(in: area)
                    if !rows.isEmpty {
                        MobileCountedSectionHeader(title: GitChangesText.title(area), count: rows.count)
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, change in
                                let comments = review.comments(on: change.path)
                                    .filter { $0.shows(in: change.area, areas: areas[change.path] ?? [change.area]) }.count
                                let selected = selection == FilesRoute.review(change)
                                Button { context.push(.review(change)) } label: {
                                    ReviewChangeRow(change: change, comments: comments, last: index == rows.count - 1)
                                        .background { if selected { Color.lens } }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(ReviewChangeRow.accessibilityLabel(change, comments: comments))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 12)
                    }
                }
                if status.truncated {
                    note("Too many changes: \(GitChangesText.truncated(status))")
                }
                if let failure = changes.failure, !context.offline, !failure.transient {
                    note(failure.message)
                }
                Color.clear.frame(height: 40)
            }
        }
        .refreshable { await changes.refresh(fresh: true) }
        .accessibilityIdentifier("review-changes")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .frame(maxWidth: .infinity)
    }

    /// A state in the list's place, still pulled to refresh.
    private func state(_ state: ReviewListState) -> some View {
        GeometryReader { geometry in
            ScrollView {
                state
                    .padding(.horizontal, 32)
                    .padding(.bottom, geometry.size.height * 0.2)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .refreshable { await changes.refresh(fresh: true) }
        }
    }
}

/// An empty, error or offline state: the glyph, the title and a line, centred (the Files states' grammar).
private struct ReviewListState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The first read on its way: nothing for a moment (a quick answer draws the list at once, no spinner flashes), then a
/// spinner.
private struct ReviewLoadingState: View {
    @State private var visible = false

    var body: some View {
        ZStack {
            if visible { ProgressView().accessibilityLabel("Loading changes") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            visible = true
        }
    }
}

/// A change's row (H2): the porcelain letter, the folder dimmed (a rename's old path and an arrow before it) and the
/// name, the file's comments in this area, "+n −m" or a binary's sizes, a chevron. The caller puts it in a card.
struct ReviewChangeRow: View {
    let change: GitChange
    var comments = 0
    var last = false

    /// The letter `git status` gives the change: A, M, D, R, C, T, U for a conflict, ? untracked.
    static func letter(_ kind: GitChangeKind) -> String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .conflicted: "U"
        case .untracked: "?"
        case .ignored: "!"
        }
    }

    /// What dims before the name: the folder, or for a rename or copy "src/old.ts → src/".
    static func lead(_ change: GitChange) -> String {
        let folder = MobileChangeRow.split(change.path).folder
        guard let old = change.oldPath, change.kind == .renamed || change.kind == .copied else { return folder }
        return "\(old) → \(folder)"
    }

    /// "binary · 48 KB → 51 KB" for a binary, nil otherwise.
    static func binary(_ change: GitChange) -> String? {
        change.binary ? GitChangesText.binary(old: change.oldSize, new: change.newSize, kind: change.kind) : nil
    }

    static func accessibilityLabel(_ change: GitChange, comments: Int) -> String {
        let moved = change.oldPath.map { change.kind == .copied ? "copied from \($0)" : "renamed from \($0)" }
        let counts = binary(change) ?? MobileCounts.spoken(added: change.additions ?? 0, deleted: change.deletions ?? 0)
        let notes = comments > 0 ? ReviewText.count(comments) : ""
        return [change.path, GitStatusBadge.spoken(letter(change.kind)), moved ?? "", counts, notes]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var body: some View {
        let name = MobileChangeRow.split(change.path).name
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                GitStatusBadge(status: Self.letter(change.kind))
                HStack(spacing: 0) {
                    Text(verbatim: Self.lead(change)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    Text(verbatim: name).lineLimit(1).layoutPriority(1)
                }
                .font(.subheadline)
                Spacer(minLength: 8)
                if comments > 0 { MobileCommentBadge(count: comments) }
                if let binary = Self.binary(change) {
                    Text(binary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    MobileCounts(added: change.additions ?? 0, deleted: change.deletions ?? 0,
                                 font: .system(.caption, design: .monospaced))
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            if !last { MobileHairline(inset: 48) }
        }
        .accessibilityElement(children: .ignore)
    }
}

/// The row under the capsule: "⑂ dark-mode · 8 files +190 −18" and search; while searching, the search field in its
/// place (the list filters by path, `GitStatus.matching`).
struct ReviewBar: View {
    let context: ReviewContext
    /// The iPad's row (I2): Create review is a pink pill here, where the phone has the tab bar's accessory.
    @Environment(\.tabsPadStrip) private var strip

    var body: some View {
        let changes = context.review.changes(context.place)
        let review = context.review
        HStack(spacing: 10) {
            if changes.searching {
                ReviewSearchField(changes: changes)
                MobileBarButton(symbol: "xmark", label: "Close search") {
                    changes.query = ""
                    changes.searching = false
                }
            } else {
                summary(changes.status)
                Spacer(minLength: 0)
                if strip, review.sent[context.place] == nil, review.notices[context.place] == nil {
                    let count = review.count(context.place)
                    if count > 0 { ReviewCreatePill(count: count) { review.sheet = context.tab } }
                }
                MobileBarButton(symbol: "magnifyingglass", label: "Search changes") { changes.searching = true }
            }
        }
    }

    /// The branch, the changed files and their counts (none while the host is offline: they may be stale).
    @ViewBuilder private func summary(_ status: GitStatus?) -> some View {
        let branch = context.branch ?? status.map(GitChangesText.branch)
        HStack(spacing: 4) {
            if let branch {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: branch).font(.subheadline.weight(.semibold))
            }
            if let status {
                let files = Self.files(status)
                Text("\(branch == nil ? "" : "· ")\(files) \(files == 1 ? "file" : "files")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !context.offline {
                    MobileCounts(added: status.additions, deleted: status.deletions, font: .system(.subheadline, design: .monospaced))
                }
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("review-summary")
    }

    /// Changed files: a file in two areas counts once.
    static func files(_ status: GitStatus) -> Int { Set(status.changes.map(\.path)).count }
}

/// The iPad's Create review (I2): a pink glass pill with the comment count, which opens Create review's sheet.
struct ReviewCreatePill: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "paperplane.fill").font(.caption.weight(.semibold)).accessibilityHidden(true)
                Text("Create review").font(.subheadline.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.onAccent.opacity(0.25), in: Capsule())
            }
            .foregroundStyle(Color.onAccent)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(minHeight: MobileBarButton.size)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("Create review")
        .accessibilityValue(ReviewText.count(count))
    }
}

/// The bar's search field: a glass capsule with the query, focused when it opens.
private struct ReviewSearchField: View {
    let changes: ReviewChanges
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search changes", text: Binding(get: { changes.query }, set: { changes.query = $0 }))
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
            if !changes.query.isEmpty {
                Button { changes.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: MobileBarButton.size)
        .glassEffect(.regular.interactive(), in: Capsule())
        .onAppear { focused = true }
    }
}

/// The tab bar's accessory: Create review while comments exist ("Create review · 3 comments on 2 files ›", opens the
/// sheet), or for a review just sent (S4) "Sent to claude · 3 comments" (or "Copied") with Undo.
struct ReviewAccessory: View {
    let context: ReviewContext

    /// Whether Review has an accessory now.
    @MainActor static func shows(_ context: ReviewContext) -> Bool {
        context.review.count(context.place) > 0 || context.review.sent[context.place] != nil
            || context.review.notices[context.place] != nil
    }

    /// "3 comments on 2 files".
    static func summary(_ comments: [ReviewComment]) -> String {
        let files = Set(comments.map(\.path)).count
        return "\(ReviewText.count(comments.count)) on \(FilesFormatting.count(files)) \(files == 1 ? "file" : "files")"
    }

    var body: some View {
        let review = context.review
        if let sent = review.sent[context.place] {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.added)
                    .accessibilityHidden(true)
                Text(sent.agent.map { "Sent to \($0)" } ?? "Copied")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(ReviewText.count(sent.comments))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Undo") { Task { await review.undo(context.place) } }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.dispatchPink)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review-sent")
        } else if let notice = review.notices[context.place] {
            // An Undo that could not take the message back, or a Send that failed with the sheet closed.
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(Color.caution)
                    .accessibilityHidden(true)
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("review-notice")
        } else {
            let comments = review.repository.review(context.place.scope).comments
            Button { review.sheet = context.tab } label: {
                HStack(spacing: 10) {
                    Image(systemName: "paperplane.fill").accessibilityHidden(true)
                    Text("Create review")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(Self.summary(comments))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.dispatchPink)
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Create review")
            .accessibilityValue(Self.summary(comments))
        }
    }
}
