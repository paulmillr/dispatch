import SwiftUI

/// The Commits mode's texts, apart from the views so the tests read them.
enum CommitsText {
    /// The list's age: "now", "25m", "2h", "1d", "1w", "4mo", "2y".
    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        case ..<(30 * 86_400): return "\(Int(seconds / (7 * 86_400)))w"
        case ..<(365 * 86_400): return "\(Int(seconds / (30 * 86_400)))mo"
        default: return "\(Int(seconds / (365 * 86_400)))y"
        }
    }

    /// The age as the detail's subtitle says it: "25m ago", "just now".
    static func ago(_ date: Date, now: Date) -> String {
        let age = age(date, now: now)
        return age == "now" ? "just now" : age + " ago"
    }

    /// The age spoken: "25 minutes ago".
    static func spokenAge(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    /// The bar's count: "148 commits", "200+ commits" while more pages remain, "12 matching" under a filter.
    static func count(shown: Int, exhausted: Bool, filtered: Bool) -> String {
        let number = "\(shown)\(exhausted ? "" : "+")"
        if filtered { return "\(number) matching" }
        return "\(number) \(shown == 1 && exhausted ? "commit" : "commits")"
    }

    /// The detail's date: "Today, 1:43 AM", "Yesterday, 9:05 PM", "Oct 18, 2026, 3:12 PM".
    static func date(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                                    timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return "Today, " + time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, " + time
        }
        let day = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone))
        return day + ", " + time
    }
}

/// H3: the log under the capsule. A hollow "Uncommitted changes" row on top (it opens Review), then one line per
/// commit, its subject and its age in mono, over a continuous graph in the gutter: the current branch green, merged
/// branches amber, rows inside a merged span indented past its lane. No separators. Pages load as the end comes into
/// sight; pull to refresh reads the refs again.
struct CommitsListView: View {
    let log: CommitsLog
    let context: FilesModeContext
    let queries: CommitsQueries?
    @State private var width: CGFloat = 402
    /// The list's end is on screen.
    @State private var footerVisible = false
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44
    /// The iPad's pane shows this commit: its row is marked.
    @Environment(\.filesPaneSelection) private var selection

    /// What the list is read for: a new repository, connection or branch reads the refs again.
    private struct Reading: Equatable {
        let root: String?
        let host: String?
        let generation: ObjectIdentifier?
        let branch: String?
    }

    var body: some View {
        let shown = log.shown
        let graph = log.graph(maxLanes: CommitGraphCell.maxLanes(width: width))
        Group {
            // Nothing to show yet, and no page left that could hold some: the state says why. While pages remain the
            // list stays, its end asking for them ("Looking further…").
            if shown.isEmpty, !(log.uncommitted && !log.filtered), log.phase != .loaded || log.exhausted {
                state
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let top = graph.top {
                            CommitsUncommittedRow(row: top, lanes: graph.lanes, height: rowHeight) { context.select(.review) }
                        }
                        ForEach(Array(zip(shown.indices, shown)), id: \.1.hash) { index, commit in
                            CommitRow(commit: commit, row: index < graph.rows.count ? graph.rows[index] : nil, lanes: graph.lanes,
                                      height: rowHeight, selected: selection?.revision == commit.hash && selection?.path == nil) {
                                context.push(FilesRoute(mode: .commits, revision: commit.hash))
                            }
                        }
                        footer
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .refreshable { await log.refresh() }
        .task(id: Reading(root: queries?.root, host: queries?.host, generation: queries?.git.identity,
                          branch: context.git?.branch)) {
            log.attach(queries)
            await log.refresh()
        }
        .accessibilityIdentifier("commits-list")
    }

    @ViewBuilder private var footer: some View {
        if !log.exhausted, log.phase == .loaded {
            CommitsMore(log: log, empty: log.shown.isEmpty, height: rowHeight)
                .onScrollVisibilityChange(threshold: 0.01) { footerVisible = $0 }
                // The next page once the end is in sight and stays so after the last rows went in (a short settle, which a
                // scroll away or new rows cancel); a filter applied here stops after `CommitsLog.automaticPages`.
                .task(id: Paging(visible: footerVisible, count: log.commits.count, loading: log.loadingMore)) {
                    guard footerVisible, !log.loadingMore else { return }
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, footerVisible else { return }
                    log.more()
                }
        } else if let stale = log.stale {
            Label(stale, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct Paging: Equatable {
        let visible: Bool
        let count: Int
        let loading: Bool
    }

    @ViewBuilder private var state: some View {
        switch log.phase {
        case .idle where queries == nil:
            // No helper to ask yet (connecting, offline, the repository not read): S3's accessory says why when it is down.
            ContentUnavailableView("Waiting for \(context.host.name)", systemImage: FilesMode.commits.symbol,
                                   description: Text("The log shows once \(context.host.name)’s helper answers."))
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading the log…").font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t read the log", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await log.refresh() } }
                    .buttonStyle(.glass)
            }
        case .loaded:
            if log.filtered {
                ContentUnavailableView {
                    Label("No matching commits", systemImage: "magnifyingglass")
                } description: {
                    Text(log.search.isEmpty ? "No commit in this log passes the filter." : "No commit’s subject or author holds “\(log.search)”.")
                } actions: {
                    Button("Clear filters") {
                        log.signedOnly = false
                        log.author = nil
                        log.endSearch()
                    }
                    .buttonStyle(.glass)
                }
            } else {
                ContentUnavailableView {
                    Label("No commits yet", systemImage: FilesMode.commits.symbol)
                } description: {
                    Text(log.scope == .all ? "This repository has no commits." : "Nothing is committed on this branch yet.")
                }
            }
        }
    }
}

/// The list's end while pages remain: a spinner ("Looking further…" while nothing matched yet), or, once a filter
/// applied here has read its automatic pages, how far it read and Load more.
struct CommitsMore: View {
    let log: CommitsLog
    let empty: Bool
    let height: CGFloat

    var body: some View {
        Group {
            if log.paused && !log.loadingMore {
                VStack(spacing: 8) {
                    Text(empty ? "No matches in the \(log.commits.count) commits read so far" : "\(log.commits.count) commits read")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Load more") { log.more(automatic: false) }
                        .buttonStyle(.glass)
                }
                .padding(16)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    if empty { Text("Looking further…").font(.subheadline).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(empty ? "Looking further" : "Loading more commits")
            }
        }
        .frame(maxWidth: .infinity, minHeight: height)
        .padding(.top, empty ? 24 : 0)
    }
}

/// The row under the capsule (H3): the branch and the count, then Search and the filter menu. While searching, the
/// field takes the row.
struct CommitsBar: View {
    let log: CommitsLog
    let context: FilesModeContext
    @FocusState private var focused: Bool

    var body: some View {
        if log.searching {
            searchField
        } else {
            HStack(spacing: 10) {
                summary
                Spacer(minLength: 8)
                MobileBarButton(symbol: "magnifyingglass", label: "Search commits") {
                    log.searching = true
                }
                filterMenu
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 4) {
            Image(systemName: log.scope == .all ? "point.3.connected.trianglepath.dotted" : "arrow.triangle.branch")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if log.phase == .loaded {
                Text("· " + CommitsText.count(shown: log.shown.count, exhausted: log.exhausted, filtered: log.filtered))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if log.scope == .all { return "All branches" }
        if let author = log.author { return author }
        if let branch = context.git?.branch { return branch }
        return log.head.map { "HEAD " + String($0.prefix(7)) } ?? "HEAD"
    }

    private var filterMenu: some View {
        Menu {
            Picker("History", selection: Binding(get: { log.scope }, set: { log.scope = $0 })) {
                Label("Current branch", systemImage: "arrow.triangle.branch").tag(GitLogScope.branch)
                Label("All branches", systemImage: "point.3.connected.trianglepath.dotted").tag(GitLogScope.all)
            }
            Menu {
                Picker("Author", selection: Binding(get: { log.author }, set: { log.author = $0 })) {
                    Text("Anyone").tag(String?.none)
                    ForEach(log.authors(), id: \.self) { Text($0).tag(String?.some($0)) }
                }
            } label: {
                Label(log.author.map { "Author: \($0)" } ?? "Author", systemImage: "person")
            }
            Toggle(isOn: Binding(get: { log.signedOnly }, set: { log.signedOnly = $0 })) {
                Label("Signed only", systemImage: "checkmark.seal")
            }
        } label: {
            MobileBarGlyph(symbol: "line.3.horizontal.decrease", tinted: log.scope == .all || log.author != nil || log.signedOnly)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .glassEffect(log.scope == .all || log.author != nil || log.signedOnly ? .regular.tint(.dispatchPink).interactive()
                                                                              : .regular.interactive(), in: Circle())
        .accessibilityLabel("Filter commits")
        .accessibilityValue(filterSummary)
    }

    private var filterSummary: String {
        [log.scope == .all ? "All branches" : "Current branch", log.author.map { "by \($0)" }, log.signedOnly ? "signed only" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Subject or author", text: Binding(get: { log.draft }, set: { log.draft = $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit { log.apply(log.draft) }
                    .accessibilityLabel("Search commits")
                if !log.draft.isEmpty {
                    Button {
                        log.draft = ""
                        log.apply("")
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(minHeight: MobileBarButton.size)
            .glassEffect(.regular.interactive(), in: Capsule())
            MobileBarButton(symbol: "xmark", label: "Close search") { log.endSearch() }
        }
        .onAppear { focused = true }
        // What is typed applies after a pause, as the Mac's search does: each search is two git runs on the host.
        .task(id: log.draft) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            log.apply(log.draft)
        }
    }
}

/// One commit (H3): the graph's cell, the subject, the age in mono at the trailing edge.
struct CommitRow: View {
    let commit: GitCommit
    let row: GitGraph.Row?
    let lanes: Int
    let height: CGFloat
    /// The iPad's pane shows it.
    var selected = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 0) {
                CommitGraphCell(row: row, lanes: lanes, hollow: false, height: height)
                Text(commit.subject)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(CommitsText.age(commit.date, now: timeline.date))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.trailing, 20)
            .frame(minHeight: height)
            .contentShape(Rectangle())
            .background { if selected { Color.lens } }
        }
        .buttonStyle(CommitRowStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(Self.spoken(commit, now: Date()))
        .accessibilityIdentifier("commit-\(commit.short)")
    }

    static func spoken(_ commit: GitCommit, now: Date) -> String {
        var parts = [commit.subject, commit.author, CommitsText.spokenAge(commit.date, now: now)]
        if commit.parents.count > 1 { parts.append("merge") }
        if commit.signature != nil { parts.append("signed") }
        let refs = commit.refs.map(\.name)
        if !refs.isEmpty { parts.append(refs.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

/// The lens behind a row while it is pressed, as a list cell's highlight.
private struct CommitRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { if configuration.isPressed { Color.lens } }
            .hoverEffect(.highlight)
    }
}

/// The hollow ring on top: the work tree's changes, which Review shows.
struct CommitsUncommittedRow: View {
    let row: GitGraph.Row
    let lanes: Int
    let height: CGFloat
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 0) {
                CommitGraphCell(row: row, lanes: lanes, hollow: true, height: height)
                Text("Uncommitted changes")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.trailing, 20)
            .frame(minHeight: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(CommitRowStyle())
        .accessibilityLabel("Uncommitted changes")
        .accessibilityHint("Opens Review")
        .accessibilityIdentifier("commits-uncommitted")
    }
}

/// One row's lanes (H3's graph): the first lane 26 points in and 20 between lanes, lines 2.5 wide, a 6.5-point dot
/// (a ring for the uncommitted changes) on the current branch's green or a merged branch's amber; the row's text starts
/// 22 points past the last lane it uses, so a merged span indents. Deeper lanes than drawn are a count at the left edge.
struct CommitGraphCell: View {
    let row: GitGraph.Row?
    let lanes: Int
    let hollow: Bool
    let height: CGFloat

    static let first: CGFloat = 26
    static let spacing: CGFloat = 20
    static let gap: CGFloat = 22

    static func x(_ lane: Int) -> CGFloat { first + spacing * CGFloat(lane) }

    /// The lanes a list `width` wide draws: a quarter of it at most, two at least, never more than `GitGraph.maxLanes`.
    static func maxLanes(width: CGFloat) -> Int {
        guard width > 0 else { return GitGraph.maxLanes }
        let room = Int(((width * 0.25 - first) / spacing).rounded(.down)) + 1
        return min(max(room, 2), GitGraph.maxLanes)
    }

    /// The last lane the row draws in: its dot's, or a line's.
    static func used(_ row: GitGraph.Row?, lanes: Int) -> Int {
        guard let row else { return 0 }
        var last = row.lane < lanes ? row.lane : 0
        for line in row.lines { last = max(last, line.from, line.to) }
        return min(last, max(lanes - 1, 0))
    }

    static func width(_ row: GitGraph.Row?, lanes: Int) -> CGFloat { x(used(row, lanes: lanes)) + gap }

    var body: some View {
        let green = Color.added, amber = Color.caution, canvas = Color.canvas
        Canvas { context, size in
            guard let row else { return }
            let middle = size.height / 2
            let stroke = StrokeStyle(lineWidth: 2.5, lineCap: .butt)
            for line in row.lines {
                let from = Self.x(line.from), to = Self.x(line.to)
                var path = Path()
                switch line.kind {
                case .pass:
                    path.move(to: CGPoint(x: from, y: 0))
                    path.addLine(to: CGPoint(x: from, y: size.height))
                case .into:
                    path.move(to: CGPoint(x: from, y: 0))
                    if from == to { path.addLine(to: CGPoint(x: to, y: middle)) } else {
                        path.addQuadCurve(to: CGPoint(x: to, y: middle), control: CGPoint(x: from, y: middle))
                    }
                case .out:
                    path.move(to: CGPoint(x: from, y: middle))
                    if from == to { path.addLine(to: CGPoint(x: to, y: size.height)) } else {
                        path.addQuadCurve(to: CGPoint(x: to, y: size.height), control: CGPoint(x: to, y: middle))
                    }
                }
                context.stroke(path, with: .color(line.current ? green : amber), style: stroke)
            }
            let color = row.current ? green : amber
            if row.lane < lanes {
                let radius: CGFloat = hollow ? 6 : 6.5
                let dot = Path(ellipseIn: CGRect(x: Self.x(row.lane) - radius, y: middle - radius, width: radius * 2, height: radius * 2))
                if hollow {
                    context.fill(dot, with: .color(canvas))
                    context.stroke(dot, with: .color(color), lineWidth: 2.5)
                } else {
                    context.fill(dot, with: .color(color))
                }
            }
            if row.hidden > 0 {
                let count = Text(verbatim: "+\(row.hidden)").font(.caption2.monospacedDigit())
                    .foregroundStyle(row.lane >= lanes ? color : Color.secondary)
                context.draw(count, at: CGPoint(x: 2, y: middle), anchor: .leading)
            }
        }
        .frame(width: Self.width(row, lanes: lanes), height: height)
        .accessibilityHidden(true)
    }
}
