import SwiftUI
import UIKit

/// Find in a conversation (C1): the query, its matches in thread order and the one shown. A match is one occurrence of
/// the query in a bubble's text as the bubble draws it (Markdown's marks gone, `ChatSearchMarker`), case and diacritics
/// ignored. While a query is typed, earlier history pages in until there is none (the Mac's rule,
/// `ChatTranscriptView`'s SearchHistory), so a search covers the whole conversation; `status` says so meanwhile.
@MainActor @Observable
final class ChatThreadSearch {
    struct Match: Equatable {
        let row: String
        /// The occurrence within its row, from 0, in the order the row draws its text.
        let occurrence: Int
    }

    private(set) var visible = false
    var query = "" {
        didSet { if query != oldValue { selected = nil; followNewest = true } }
    }
    private(set) var matches: [Match] = []
    /// Index into `matches` of the one shown (scrolled to, drawn stronger).
    private(set) var selected: Int?
    /// "Searching earlier messages…", or why the search is incomplete.
    var status: String?
    /// Bumped by `move`, so the thread scrolls to the selected match even when it is the same one again.
    private(set) var navigation = 0
    /// Until the user steps, a new result selects the newest match (the end of the thread is where they are).
    @ObservationIgnored private var followNewest = true
    /// Each row's runs of text as drawn, for the text they were made from.
    private struct Runs { let text: String; let runs: [String] }
    @ObservationIgnored private var runs: [String: Runs] = [:]

    var current: Match? { selected.flatMap { matches.indices.contains($0) ? matches[$0] : nil } }
    var active: Bool { visible && !trimmed.isEmpty }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// "2 of 2", "No results"; empty without a query.
    var label: String {
        guard active else { return "" }
        if matches.isEmpty { return status == nil ? "No results" : "" }
        return "\((selected ?? matches.count - 1) + 1) of \(matches.count)"
    }

    func open() { visible = true }

    func close() {
        visible = false
        query = ""
        matches = []
        selected = nil
        status = nil
        runs = [:]
    }

    /// The previous (-1) or next (1) match, wrapping.
    func move(_ direction: Int) {
        guard !matches.isEmpty else { return }
        followNewest = false
        let from = selected ?? (direction > 0 ? -1 : matches.count)
        selected = (from + direction + matches.count) % matches.count
        navigation += 1
    }

    /// While a query is typed, earlier pages of `session` load until it has none left (the Mac's rule): the search
    /// covers the whole conversation. A failed page says the search is incomplete. Ends when cancelled.
    func searchEarlier(in session: MobileChatSession) async {
        guard active else { status = nil; return }
        while !Task.isCancelled, active {
            if let error = session.earlierError { status = "Search incomplete: " + error; return }
            // Stop when no more can load: an unverified conversation keeps its cursor but pages nothing.
            guard session.canLoadEarlier || session.loadingEarlier || session.loadingHistory else { break }
            status = "Searching earlier messages…"
            if !session.loadingEarlier, !session.loadingHistory { session.loadEarlier() }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !Task.isCancelled { status = nil }
    }

    /// Recounts the matches in `rows`; the shown match stays when it is still there (rows paged in above it move it).
    func update(rows: [ChatThreadRow]) {
        guard active else {
            if !matches.isEmpty { matches = [] }
            selected = nil
            return
        }
        let query = trimmed
        var found: [Match] = []
        var kept: [String: Runs] = [:]
        for row in rows {
            // A row's text as drawn is parsed once while it stays the same (pages and steps reuse it).
            let runs = self.runs[row.id].flatMap { $0.text == row.item.text ? $0 : nil }
                ?? Runs(text: row.item.text, runs: ChatSearchMarker.runs(of: row))
            kept[row.id] = runs
            let count = runs.runs.reduce(0) { $0 + ChatSearchMarker.count(query, in: $1) }
            for occurrence in 0..<count { found.append(Match(row: row.id, occurrence: occurrence)) }
        }
        self.runs = kept
        let shown = current
        let changed = found != matches
        matches = found
        if followNewest || shown == nil {
            let newest = found.isEmpty ? nil : found.count - 1
            if selected != newest { selected = newest; if newest != nil { navigation += 1 } }
        } else if let shown {
            selected = found.firstIndex(of: shown) ?? (found.isEmpty ? nil : min(selected ?? 0, found.count - 1))
        }
        if changed, found.isEmpty { selected = nil }
    }
}

/// What every bubble highlights while a search is open: the query. The shown match goes to its row alone
/// (`chatSearchCurrent`), so stepping redraws only the two bubbles it leaves and reaches.
struct ChatSearchMarks: Equatable {
    let query: String
}

extension EnvironmentValues {
    /// The open search's marks (nil: no search).
    @Entry var chatSearchMarks: ChatSearchMarks? = nil
    /// This row's occurrence to draw strongest: the shown match is in it (nil: none).
    @Entry var chatSearchCurrent: Int? = nil
}

/// Highlights the query's occurrences in the runs of text a bubble draws, counting them in drawing order so the thread's
/// count and the highlights agree (`ChatThreadSearch.update` counts with the same pass, without marks). The shown match is
/// amber with black text, the others a fainter amber, as Messages and the mockup (C1) draw them.
struct ChatSearchMarker {
    let query: String
    /// The occurrence to draw strongest in this row; nil: none of this row's.
    let current: Int?
    private(set) var count = 0

    init(query: String, current: Int?) {
        self.query = query
        self.current = current
    }

    init?(_ marks: ChatSearchMarks?, current: Int?) {
        guard let marks, !marks.query.isEmpty else { return nil }
        self.init(query: marks.query, current: current)
    }

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// `text` with its occurrences marked.
    mutating func mark(_ text: AttributedString) -> AttributedString {
        guard !query.isEmpty else { return text }
        var text = text
        var search = text.startIndex..<text.endIndex
        while let range = text[search].range(of: query, options: Self.options) {
            let strong = count == current
            text[range].backgroundColor = strong ? Color.caution : Color.caution.opacity(0.35)
            if strong { text[range].foregroundColor = Color.black }
            count += 1
            search = range.upperBound..<text.endIndex
        }
        return text
    }

    mutating func mark(_ text: String) -> AttributedString { mark(AttributedString(text)) }

    /// How many times `query` occurs in `text` (as `mark` counts them).
    static func count(_ query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var count = 0, search = text.startIndex..<text.endIndex
        while let range = text.range(of: query, options: options, range: search) {
            count += 1
            search = range.upperBound..<text.endIndex
        }
        return count
    }

    /// The runs of text `row` draws, in order (Markdown's marks gone for the agent's text and thinking).
    @MainActor static func runs(of row: ChatThreadRow) -> [String] {
        switch row.kind {
        case .user, .notice:
            return [row.item.text]
        case .agent, .thinking:
            var none = ChatSearchMarker(query: "", current: nil)
            return MobileChatMarkdownView.contents(row.item.text, marker: &none).blocks.flatMap { block -> [String] in
                switch block {
                case .text(_, let text): [String(text.characters)]
                case .code(let lines, _): lines.map { String($0.characters) }
                case .table(let rows): rows.flatMap { $0.map { String($0.characters) } }
                case .rule: []
                }
            }
        }
    }

    /// How many times `query` occurs in what `row` draws.
    @MainActor static func count(_ query: String, in row: ChatThreadRow) -> Int {
        runs(of: row).reduce(0) { $0 + count(query, in: $1) }
    }
}

/// C1: the search capsule in the composer's place (field, "2 of 2", clear), the up and down pair and Done, and under them
/// "Searching earlier messages…" while older history pages in.
struct ChatSearchBar: View {
    @Bindable var search: ChatThreadSearch
    var focus: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search", text: $search.query)
                        .focused(focus)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { search.move(-1) }
                        .accessibilityLabel("Search in conversation")
                    if !search.label.isEmpty {
                        Text(search.label)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityIdentifier("chat-search-count")
                    }
                    if !search.query.isEmpty {
                        Button { search.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                .frame(width: 30, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .frame(minHeight: 44)
                .glassEffect(.regular.interactive(), in: Capsule())
                HStack(spacing: 0) {
                    Button { search.move(-1) } label: {
                        Image(systemName: "chevron.up").frame(width: 40, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Previous match")
                    Button { search.move(1) } label: {
                        Image(systemName: "chevron.down").frame(width: 40, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Next match")
                }
                .buttonStyle(.plain)
                .font(.body.weight(.semibold))
                .disabled(search.matches.isEmpty)
                .glassEffect(.regular.interactive(), in: Capsule())
                Button { search.close() } label: {
                    Text("Done")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.dispatchPink)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .keyboardShortcut(.cancelAction)
            }
            if let status = search.status, search.active {
                HStack(spacing: 6) {
                    if status.hasPrefix("Searching") { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        // The bar's own height whatever the thread does above it (the composer's rule).
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Edit › Find… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G on the Chat segment (`MobileCommands`): the chat on screen
    /// opens its search, or steps through its matches.
    static let requested = Notification.Name("DispatchMobileChatFindRequested")

    /// 0 opens the search, 1 and -1 step (opening it when closed).
    @MainActor static func request(_ direction: Int) {
        NotificationCenter.default.post(name: requested, object: nil, userInfo: ["direction": direction])
    }

    static func direction(_ note: Notification) -> Int { note.userInfo?["direction"] as? Int ?? 0 }
}
