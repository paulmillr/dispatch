import SwiftUI
import UIKit

/// A commit's file, pushed from C2's CHANGED FILES (read-only): its diff in the commit (a merge's against its first
/// parent) with old and new line numbers' gutter, tinted rows and the code palette, or (Source, the bottom bar's other
/// half) the whole file as the commit left it with the commit's changes marked. Pinch zooms the code, as the turn's
/// diff viewer does (`CodeFontSize`).
struct CommitFileScreen: View {
    let log: CommitsLog
    let hash: String
    let path: String
    let oldPath: String?
    let queries: CommitsQueries?
    @State private var source = false
    @State private var fontSize = CodeFontSize.stored(.standard)
    @State private var pinchBase: Double?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tabsColumnWidth) private var column

    private var change: GitChange? {
        guard case .loaded(let detail)? = log.detail(hash) else { return nil }
        return detail.files.first { $0.path == path }
    }

    var body: some View {
        let commit = log.commit(hash)
        let text = log.text(commit?.hash ?? hash, path: path, source: source)
        content(text)
            .simultaneousGesture(pinch)
            .tabsPushedScreen()
            .safeAreaBar(edge: .bottom, spacing: 0) { bottomBar }
            .toolbar {
                TabsScreenHeader(title: (path as NSString).lastPathComponent, column: column) {
                    TabsBackPill(label: String((commit?.hash ?? hash).prefix(7))) { dismiss() }
                } subtitle: {
                    subtitle
                } trailing: {
                    menu
                }
            }
            .task(id: TaskKey(commit: commit?.hash, source: source)) {
                if log.queries == nil { log.attach(queries) }
                guard let commit else { return await log.open(hash) }
                // Source marks the commit's changes in the file: it reads the diff too.
                await log.read(commit, path: path, oldPath: oldPath, source: false)
                if source { await log.read(commit, path: path, oldPath: oldPath, source: true) }
            }
            .accessibilityIdentifier("commit-file")
    }

    private struct TaskKey: Equatable {
        let commit: String?
        let source: Bool
    }

    private var subtitle: Text {
        let folder = (path as NSString).deletingLastPathComponent
        var parts = [folder.isEmpty ? "/" : folder]
        if let change {
            parts.append(change.kind.rawValue)
            let counts = [change.additions.flatMap { $0 > 0 ? "+\($0)" : nil }, change.deletions.flatMap { $0 > 0 ? "−\($0)" : nil }]
                .compactMap { $0 }.joined(separator: " ")
            if !counts.isEmpty { parts.append(counts) }
        }
        return Text(parts.joined(separator: " · "))
    }

    private var menu: some View {
        Menu {
            Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
            if case .diff(let diff)? = log.text(log.commit(hash)?.hash ?? hash, path: path, source: false), !diff.text.isEmpty {
                Button("Copy diff", systemImage: "plus.forwardslash.minus") { UIPasteboard.general.string = diff.text }
            }
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

    /// Diff / Source, as Review's diff bar has them; a file the commit deleted has no source.
    private var bottomBar: some View {
        HStack {
            Picker("Show", selection: $source) {
                Text("Diff").tag(false)
                Text("Source").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .disabled(change?.kind == .deleted || change?.binary == true)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder private func content(_ text: CommitsLog.Text?) -> some View {
        switch text {
        case .diff(let diff)?:
            CommitCodeList(rows: CommitFileRows.diff(diff, path: path), metrics: DiffMetrics(size: fontSize))
        case .source(let whole)?:
            if case .diff(let diff)? = log.text(log.commit(hash)?.hash ?? hash, path: path, source: false) {
                CommitCodeList(rows: CommitFileRows.source(whole, diff: diff, path: path), metrics: DiffMetrics(size: fontSize))
            } else {
                CommitCodeList(rows: CommitFileRows.plain(whole, path: path), metrics: DiffMetrics(size: fontSize))
            }
        case .failed(let message)?:
            ContentUnavailableView("Couldn’t read \((path as NSString).lastPathComponent)", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loading?, nil:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? fontSize
                if pinchBase == nil { pinchBase = base }
                let size = CodeFontSize.pinched(base: base, scale: value.magnification)
                if size != fontSize { fontSize = size }
            }
            .onEnded { _ in
                pinchBase = nil
                CodeFontStore.standard.save(fontSize)
            }
    }
}

/// The rows the file screen draws, from a commit's diff or source, apart from the view so the tests read them.
enum CommitFileRows {
    enum Row: Equatable {
        case note(String)
        case hunk(String)
        case line(kind: DiffLine.Kind, number: Int?, text: AttributedString)
    }

    static func diff(_ diff: GitDiff, path: String) -> [Row] {
        var rows: [Row] = []
        if diff.binary {
            let sizes = [diff.oldSize, diff.newSize].map { $0.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } }
            let detail = switch (sizes[0], sizes[1]) {
            case let (old?, new?): " · \(old) → \(new)"
            case let (nil, new?): " · \(new)"
            case let (old?, nil): " · was \(old)"
            default: ""
            }
            return [.note("Binary file" + detail)]
        }
        let file = DiffFile(path: path, title: path, base: nil, diff: hunks(diff.text))
        if file.lines.isEmpty { rows.append(.note(diff.oldPath != nil ? "Renamed without changes." : "No lines changed (its mode or type did).")) }
        let text = file.highlighted()
        for (index, line) in file.lines.enumerated() {
            if line.kind == .hunk { rows.append(.hunk(line.text)) } else { rows.append(.line(kind: line.kind, number: line.number, text: text[index])) }
        }
        if diff.truncated { rows.append(.note("The diff is cut at the helper’s limit.")) }
        return rows
    }

    /// The file as the commit left it, the commit's additions tinted and its removals shown where they were.
    static func source(_ text: String, diff: GitDiff, path: String) -> [Row] {
        let whole = WholeFile(file: DiffFile(path: path, title: path, base: nil, diff: hunks(diff.text)), text: text)
        var rows: [Row] = whole.rows.map { .line(kind: $0.kind, number: $0.number, text: $0.text) }
        if whole.rows.isEmpty { rows.append(.note("The file is empty.")) }
        return rows
    }

    /// The patch from its first hunk on: git's header (`diff --git`, `index`, `---`, `+++`) names the file the screen
    /// already names, and `---`/`+++` would read as a removed and an added line.
    static func hunks(_ patch: String) -> String {
        guard let start = patch.range(of: "\n@@")?.lowerBound else { return patch.hasPrefix("@@") ? patch : "" }
        return String(patch[patch.index(after: start)...])
    }

    static func plain(_ text: String, path: String) -> [Row] {
        source(text, diff: GitDiff(path: path, text: ""), path: path)
    }
}

/// The code rows: numbers, sign, the line in the palette on its tint; hunk headers and notes between them.
private struct CommitCodeList: View {
    let rows: [CommitFileRows.Row]
    let metrics: DiffMetrics

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    switch row {
                    case .note(let text):
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .hunk(let text):
                        Text(TextRendering.visible(text))
                            .font(.system(size: metrics.hunk, design: .monospaced))
                            .foregroundStyle(Color(uiColor: CodePalette.hunk))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: metrics.hunkHeight, alignment: .leading)
                            .background(Color(uiColor: CodePalette.hunkRow))
                    case .line(let kind, let number, let text):
                        line(kind: kind, number: number, text: text)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color.canvas)
    }

    private func line(kind: DiffLine.Kind, number: Int?, text: AttributedString) -> some View {
        let sign = kind == .added ? "+" : kind == .removed ? "-" : ""
        let tint: Color = kind == .added ? Color(uiColor: CodePalette.added) : Color(uiColor: CodePalette.removed)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: metrics.number, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color(uiColor: CodePalette.gutter))
                .frame(minWidth: metrics.numberWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
            Text(sign)
                .font(.system(size: metrics.code, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: metrics.sign, alignment: .leading)
            Text(text.characters.isEmpty ? AttributedString(" ") : text)
                .font(.system(size: metrics.code, design: .monospaced))
                .foregroundStyle(Color(uiColor: CodePalette.ink))
                .lineSpacing(metrics.spacing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, metrics.spacing / 2)
        .frame(minHeight: metrics.line)
        .background(kind == .added ? Color(uiColor: CodePalette.addedRow) : kind == .removed ? Color(uiColor: CodePalette.removedRow) : .clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([number.map { "Line \($0)" }, kind == .added ? "added" : kind == .removed ? "removed" : nil,
                             String(text.characters)].compactMap { $0 }.joined(separator: ", "))
    }
}
