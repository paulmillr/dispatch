import SwiftUI
import UIKit

/// C2: one commit, pushed from the log over the whole tab (no tab bar). Back pill "Commits", the short hash with
/// "25m ago · Alex Rivera", a "…" menu with the copies; the body is `CommitDetailBody`, which an iPad pane can hold alone.
struct CommitDetailScreen: View {
    let log: CommitsLog
    let tab: TabRef
    let hash: String
    let queries: CommitsQueries?
    /// The iPad's pane beside the log (I3): a header of its own instead of the stack's bar and back pill.
    var pane = false
    @State private var patch: CommitsLog.Patch?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tabsColumnWidth) private var column

    var body: some View {
        chrome
            .alert(patch.map(Self.title) ?? "", isPresented: Binding(get: { patch != nil }, set: { if !$0 { patch = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                if let patch { Text(Self.message(patch)) }
            }
            .task {
                if log.queries == nil { log.attach(queries) }
                await log.open(hash)
            }
    }

    @ViewBuilder private var chrome: some View {
        let commit = log.commit(hash)
        let title = String((commit?.hash ?? hash).prefix(7))
        if pane {
            CommitDetailBody(log: log, tab: tab, hash: hash)
                .safeAreaBar(edge: .top, spacing: 0) {
                    PadPaneHeader(title: title) { subtitle(commit) } trailing: {
                        CommitMenu(log: log, commit: commit, hash: hash) { patch = $0 }
                    }
                }
        } else {
            CommitDetailBody(log: log, tab: tab, hash: hash)
                .tabsPushedScreen()
                .toolbar {
                    TabsScreenHeader(title: title, column: column) {
                        TabsBackPill(label: "Commits") { dismiss() }
                    } subtitle: {
                        subtitle(commit)
                    } trailing: {
                        CommitMenu(log: log, commit: commit, hash: hash) { patch = $0 }
                    }
                }
        }
    }

    @ViewBuilder private func subtitle(_ commit: GitCommit?) -> some View {
        if let commit {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                Text(CommitsText.ago(commit.date, now: timeline.date) + " · " + commit.author)
            }
        }
    }
}

extension CommitDetailScreen {
    /// Copy patch's alert: only when the patch was cut or could not be read.
    static func title(_ patch: CommitsLog.Patch) -> String {
        switch patch {
        case .copied: "Copied"
        case .cut: "Patch copied in part"
        case .failed: "Couldn’t copy the patch"
        }
    }

    static func message(_ patch: CommitsLog.Patch) -> String {
        switch patch {
        case .copied: ""
        case .cut(let bytes):
            "The patch is longer than the helper sends at once: its first \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), whole lines, were copied."
        case .failed(let message): message
        }
    }
}

/// The detail's "…": copy the hash, the subject, or the whole patch (read from the host when asked; a merge's against
/// its first parent, as its files are listed). A patch cut short or not read says so.
private struct CommitMenu: View {
    let log: CommitsLog
    let commit: GitCommit?
    let hash: String
    let copied: (CommitsLog.Patch) -> Void

    var body: some View {
        Menu {
            Button("Copy hash", systemImage: "number") { UIPasteboard.general.string = commit?.hash ?? hash }
            Button("Copy subject", systemImage: "text.quote") { UIPasteboard.general.string = commit?.subject }
                .disabled(commit == nil)
            Button("Copy patch", systemImage: "doc.on.doc") {
                let hash = commit?.hash ?? hash
                Task {
                    let result = await log.copyPatch(hash) { UIPasteboard.general.string = $0 }
                    if result != .copied { copied(result) }
                }
            }
            .disabled(log.queries == nil || commit == nil)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .buttonStyle(.plain)
        // The bar shrinks a menu's own label: the glass circle is the item's, at the host disc's 44 points.
        .frame(width: 44, height: 44)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .accessibilityLabel("More")
    }
}

/// The commit's body (C2): the card with subject, message and ref chips; Author (with the signature's badge), Date and
/// the parents (each opens its commit), Author and Date opening popovers with the whole story; CHANGED FILES with the
/// counts and a row per file that opens its diff.
struct CommitDetailBody: View {
    let log: CommitsLog
    let tab: TabRef
    let hash: String

    var body: some View {
        let commit = log.commit(hash)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let commit {
                    CommitCard(commit: commit)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    CommitFacts(commit: commit, tab: tab, check: log.checks[commit.hash],
                                checkAgain: log.unanswered.contains(commit.hash) ? { log.checkAgain(commit.hash) } : nil)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }
                files(commit)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if commit == nil, case .failed(let message)? = log.detail(hash) {
                ContentUnavailableView("Couldn’t read the commit", systemImage: "exclamationmark.triangle", description: Text(message))
            } else if commit == nil {
                ProgressView()
            }
        }
        .background(Color.canvas)
        .accessibilityIdentifier("commit-detail")
    }

    @ViewBuilder private func files(_ commit: GitCommit?) -> some View {
        switch log.detail(hash) {
        case .loaded(let detail)?:
            let added = detail.files.reduce(0) { $0 + ($1.additions ?? 0) }
            let deleted = detail.files.reduce(0) { $0 + ($1.deletions ?? 0) }
            HStack(spacing: 6) {
                Text("Changed files").textCase(.uppercase)
                Text("\(detail.files.count)").foregroundStyle(.tertiary).monospacedDigit()
                MobileCounts(added: added, deleted: deleted, font: .system(.footnote, design: .monospaced))
                    .padding(.leading, 18)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if detail.files.isEmpty {
                Text(detail.commit.parents.count > 1 ? "The merge changed nothing against its first parent." : "No files changed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(detail.files.enumerated()), id: \.element.id) { index, file in
                        NavigationLink(value: TabsRoute.files(tab, FilesRoute(mode: .commits, path: file.path,
                                                                               revision: detail.commit.hash, detail: file.oldPath))) {
                            MobileChangeRow(status: file.kind.rawValue, path: file.oldPath.map { "\($0) → \(file.path)" } ?? file.path,
                                            added: file.additions ?? 0, deleted: file.deletions ?? 0,
                                            last: index == detail.files.count - 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("commit-file-\(file.path)")
                    }
                }
                .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 12)
            }
        case .failed(let message)? where commit != nil:
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.secondary)
                Button("Try again") { Task { await log.open(hash) } }.buttonStyle(.glass)
            }
            .padding(16)
        default:
            if commit != nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading the files…").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(16)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The top card: subject, message and refs (the signature is the Author row's badge).
private struct CommitCard: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(commit.subject)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .textSelection(.enabled)
            if !commit.body.isEmpty {
                Text(commit.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !commit.refs.isEmpty {
                CommitFlow(spacing: 6) {
                    ForEach(CommitRefChip.ordered(commit.refs), id: \.self) { CommitRefChip(ref: $0) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Chips left to right, onto the next line when one does not fit.
struct CommitFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            line = max(line, size.height)
            subview.place(at: CGPoint(x: x, y: y + (line - size.height) / 2), anchor: .topLeading,
                          proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
        }
    }
}

/// A ref on a commit: the checked-out branch filled green, other branches green on a tint, tags amber, remote
/// branches outlined, a detached HEAD filled.
struct CommitRefChip: View {
    let ref: GitRef

    static func ordered(_ refs: [GitRef]) -> [GitRef] {
        func rank(_ ref: GitRef) -> Int {
            if ref.current || ref.kind == .head { return 0 }
            switch ref.kind {
            case .head: return 0
            case .branch: return 1
            case .remote: return 2
            case .tag: return 3
            }
        }
        return refs.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    static func spoken(_ ref: GitRef) -> String {
        switch ref.kind {
        case .head: "Detached HEAD"
        case .branch: ref.current ? "Branch \(ref.name), checked out" : "Branch \(ref.name)"
        case .remote: "Remote branch \(ref.name)"
        case .tag: "Tag \(ref.name)"
        }
    }

    var body: some View {
        let filled = ref.current || ref.kind == .head
        let color: Color = switch ref.kind {
        case .head, .branch: .added
        case .tag: .caution
        case .remote: .secondary
        }
        Text(ref.name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(filled ? Color.onAccent : color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .frame(minHeight: 17)
            .background(filled ? color : color.opacity(ref.kind == .remote ? 0 : 0.14), in: Capsule())
            .overlay { if ref.kind == .remote { Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1) } }
            .accessibilityLabel(Self.spoken(ref))
    }
}

/// The signature's verdict as a badge after the author's name: the verdict's seal in its colour (green when a trusted
/// key signed it; uncertified, unknown, expired, revoked and bad signatures in theirs), a spinner while it is checked.
/// The Author popover says the verdict in the Mac's words (`CommitSignatureText`).
struct CommitSignatureBadge: View {
    let kind: GitSignatureKind
    let check: GitSignatureCheck?

    var body: some View {
        let look = CommitSignatureText.look(kind: kind, check: check)
        Group {
            if check == nil {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: look.symbol)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(look.tone.color)
        .accessibilityLabel(look.text)
        .accessibilityIdentifier("commit-signature")
    }
}

/// The signature's words and look, apart from the views so the tests read them.
enum CommitSignatureText {
    enum Tone: Equatable {
        case good, plain, warning, bad, faint
        var color: Color {
            switch self {
            case .good: .added
            case .plain: .secondary
            case .warning: .caution
            case .bad: .destructive
            case .faint: Color(uiColor: .tertiaryLabel)
            }
        }
    }

    struct Look: Equatable {
        let symbol: String
        let text: String
        let tone: Tone
    }

    static func look(kind: GitSignatureKind?, check: GitSignatureCheck?) -> Look {
        guard let kind else { return Look(symbol: "seal", text: "Not signed", tone: .faint) }
        let name = (check?.kind ?? kind).title
        switch check?.verdict {
        case nil: return Look(symbol: "seal", text: "Signed · \(name) key", tone: .plain)
        case .good(true)?: return Look(symbol: "checkmark.seal.fill", text: "Signed · \(name) key", tone: .good)
        case .good(false)?: return Look(symbol: "checkmark.seal", text: "Signed · \(name) key, not certified", tone: .plain)
        case .bad?: return Look(symbol: "xmark.seal.fill", text: "Bad signature · \(name)", tone: .bad)
        case .revokedKey?: return Look(symbol: "xmark.seal.fill", text: "Revoked key · \(name)", tone: .bad)
        case .unknownKey?: return Look(symbol: "exclamationmark.triangle.fill", text: "Unknown key · \(name)", tone: .warning)
        case .expiredSignature?: return Look(symbol: "exclamationmark.triangle.fill", text: "Expired signature · \(name)", tone: .warning)
        case .expiredKey?: return Look(symbol: "exclamationmark.triangle.fill", text: "Expired key · \(name)", tone: .warning)
        case .unsigned?: return Look(symbol: "seal", text: "Not signed", tone: .faint)
        case .unchecked?: return Look(symbol: "seal", text: "Unverified · \(name) key", tone: .plain)
        }
    }

    /// The signer and the key, the verdict first unless it is a trusted key's good signature (the Mac's
    /// `GitSignatureText.detail`).
    static func detail(_ check: GitSignatureCheck?, kind: GitSignatureKind) -> String {
        guard let check else { return "Checking the \(kind.title) signature…" }
        let kind = check.kind ?? kind
        let name = kind.title
        let verdict: String? = switch check.verdict {
        case .good(true): nil
        case .good(false): "Good \(name) signature, key not certified"
        case .bad: "Bad \(name) signature"
        case .unknownKey: kind == .ssh ? "\(name) signature from a key not in your allowed signers"
                                       : "\(name) signature from a key not in your keyring"
        case .expiredSignature: "Expired \(name) signature"
        case .expiredKey: "\(name) signature from an expired key"
        case .revokedKey: "\(name) signature from a revoked key"
        case .unsigned: "Not signed"
        case .unchecked(let reason): "Signed with \(name) · couldn’t check: \(reason)"
        }
        let key = check.key.map { kind == .ssh ? "SSH key: \($0)" : "\(name) key ID: \($0)" }
        let parts = [verdict, check.signer, key].compactMap { $0 }
        return parts.isEmpty ? "Good \(name) signature" : parts.joined(separator: " · ")
    }
}

/// Author with the signature's badge, Date, and the parents, each opening its commit. Author opens a popover with the
/// author's name and email, the committer when someone else committed it, and the signature; Date one with the author
/// date in its own time zone and the commit date when it differs.
struct CommitFacts: View {
    let commit: GitCommit
    let tab: TabRef
    var check: GitSignatureCheck? = nil
    /// The signature check got no answer: Check again (in the Author popover).
    var checkAgain: (() -> Void)? = nil
    @State private var shown: Row.Popover?

    var body: some View {
        let rows = Self.rows(commit, now: Date())
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if let hash = row.commit {
                    NavigationLink(value: TabsRoute.files(tab, FilesRoute(mode: .commits, revision: hash))) {
                        CommitFactRow(label: row.label, value: row.value, mono: row.mono, link: true)
                    }
                    .buttonStyle(.plain)
                } else if let popover = row.popover {
                    Button { shown = popover } label: {
                        CommitFactRow(label: row.label, value: row.value, mono: row.mono, link: false) {
                            if popover == .author, let kind = commit.signature {
                                CommitSignatureBadge(kind: kind, check: check)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(popover == .author ? "Shows the author, committer and signature" : "Shows the full dates")
                    .popover(isPresented: Binding(get: { shown == popover }, set: { if !$0 { shown = nil } })) {
                        CommitFactPopover(commit: commit, popover: popover, check: check, checkAgain: checkAgain)
                            .presentationCompactAdaptation(.popover)
                    }
                } else {
                    CommitFactRow(label: row.label, value: row.value, mono: row.mono, link: false)
                }
                if index < rows.count - 1 { MobileHairline() }
            }
        }
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    struct Row: Equatable {
        /// What a tap on the row shows.
        enum Popover: Hashable { case author, date }

        var label: String
        var value: String
        var mono = false
        /// A parent: the row opens it.
        var commit: String? = nil
        var popover: Popover? = nil
    }

    static func rows(_ commit: GitCommit, now: Date) -> [Row] {
        var rows = [Row(label: "Author", value: commit.author, popover: .author),
                    Row(label: "Date", value: CommitsText.date(commit.date, now: now), popover: .date)]
        switch commit.parents.count {
        case 0: rows.append(Row(label: "Parent", value: "None, the first commit"))
        case 1: rows.append(Row(label: "Parent", value: String(commit.parents[0].prefix(7)), mono: true, commit: commit.parents[0]))
        default:
            rows.append(Row(label: "First parent", value: String(commit.parents[0].prefix(7)), mono: true, commit: commit.parents[0]))
            for parent in commit.parents.dropFirst() {
                rows.append(Row(label: "Merged", value: String(parent.prefix(7)), mono: true, commit: parent))
            }
        }
        return rows
    }

    /// A popover's lines: a title and the text under it.
    struct Fact: Equatable {
        var title: String
        var text: String
    }

    /// Author's popover: "Sam Example <sam@example.com>", the committer when another person committed it, the
    /// signature's verdict and details. Date's: the author date in its own zone, and the commit date when it differs.
    static func facts(_ popover: Row.Popover, commit: GitCommit, check: GitSignatureCheck?) -> [Fact] {
        switch popover {
        case .author:
            var facts = [Fact(title: "Author", text: person(commit.author, commit.email))]
            if let committer = commit.distinctCommitter, committer.name != commit.author || committer.email != commit.email {
                facts.append(Fact(title: "Committer", text: person(committer.name, committer.email)))
            }
            if let kind = commit.signature {
                facts.append(Fact(title: CommitSignatureText.look(kind: kind, check: check).text,
                                  text: CommitSignatureText.detail(check, kind: kind)))
            } else {
                facts.append(Fact(title: "Not signed", text: ""))
            }
            return facts
        case .date:
            var facts = [Fact(title: "Authored", text: CommitsText.fullTime(commit.date, zone: commit.zone))]
            if let committer = commit.distinctCommitter, committer.date != commit.date {
                facts.append(Fact(title: "Committed", text: CommitsText.fullTime(committer.date, zone: committer.zone)))
            }
            return facts
        }
    }

    private static func person(_ name: String, _ email: String) -> String { email.isEmpty ? name : "\(name) <\(email)>" }
}

/// What a tap on Author or Date shows (`CommitFacts.facts`), selectable; the signature's line in its colour, with
/// Check again when the check got no answer.
private struct CommitFactPopover: View {
    let commit: GitCommit
    let popover: CommitFacts.Row.Popover
    let check: GitSignatureCheck?
    let checkAgain: (() -> Void)?

    var body: some View {
        let facts = CommitFacts.facts(popover, commit: commit, check: check)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                let signature = popover == .author && index == facts.count - 1
                VStack(alignment: .leading, spacing: 3) {
                    if signature {
                        let look = CommitSignatureText.look(kind: commit.signature, check: check)
                        Label(fact.title, systemImage: look.symbol)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(look.tone.color)
                    } else {
                        Text(fact.title).font(.footnote).foregroundStyle(.secondary)
                    }
                    if !fact.text.isEmpty {
                        Text(fact.text)
                            .font(signature ? .footnote : .subheadline)
                            .foregroundStyle(signature ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if popover == .author, commit.signature != nil, let checkAgain {
                Button("Check the signature again", action: checkAgain)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.dispatchPink)
                    .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(minWidth: 240, maxWidth: 340, alignment: .leading)
    }
}

private struct CommitFactRow<Badge: View>: View {
    let label: String
    let value: String
    let mono: Bool
    let link: Bool
    @ViewBuilder var badge: Badge

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            badge
            if link {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(link ? .isButton : [])
    }
}

extension CommitFactRow where Badge == EmptyView {
    init(label: String, value: String, mono: Bool, link: Bool) {
        self.init(label: label, value: value, mono: mono, link: link) { EmptyView() }
    }
}
