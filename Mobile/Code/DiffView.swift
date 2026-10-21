import SwiftUI

/// M5d: a turn's changes, pushed from a Patch step in message details (M5b). Files stack as collapsible sections with
/// their +/− counts; an open one shows its unified hunks with line numbers, tinted added and removed rows and the
/// desktop syntax palette. Pinch zooms the code (kept like the terminal's size); the trailing pill switches the open
/// files to the whole file (`files.text`) with the hunks marked inside it. Revert under a long press on a hunk is
/// left out: the helper has no operation to reverse a patch (docs/ios.md, Code).
struct DiffView: View {
    @State private var model: DiffViewModel
    private let back: String
    private let fetch: (@MainActor (ChatItem) async throws -> ChatItem?)?
    @State private var pinchBase: Double?
    @Environment(\.dismiss) private var dismiss
    @ReduceMotion private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var titleSize = 17
    @ScaledMetric(relativeTo: .caption) private var subtitleSize = 12
    @ScaledMetric(relativeTo: .subheadline) private var pathSize = 13
    @ScaledMetric(relativeTo: .subheadline) private var headerHeight = 44

    init(model: DiffViewModel, back: String = "Message", fetch: (@MainActor (ChatItem) async throws -> ChatItem?)? = nil) {
        _model = State(initialValue: model)
        self.back = back
        self.fetch = fetch
    }

    /// From message details: the turn's patch steps, with the files of the tapped one open.
    init(session: MobileChatSession, steps: [ChatStep], opening: ChatStep, directory: String?) {
        let patches = steps.filter { $0.kind == .patch }.map(\.item)
        self.init(model: DiffViewModel(items: patches.isEmpty ? [opening.item] : patches, opening: opening.item,
                                       directory: directory, host: session.hostName, load: { try await session.fileText($0) }),
                  fetch: { try await session.fullItem($0) })
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    row(entry)
                }
                if model.changes.files.isEmpty {
                    Text(model.completing ? "Loading changes…" : "No changes recorded.")
                        .font(.system(size: pathSize))
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
        .simultaneousGesture(pinch)
        .background(Color.canvas)
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { if let fetch { await model.complete(fetch) } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                    Text(back).font(.body).lineLimit(1)
                }
                .foregroundStyle(Color.dispatchPink)
            }
            .accessibilityLabel("Back to \(back)")
        }
        ToolbarItem(placement: .topBarLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Changes").font(.system(size: titleSize, weight: .semibold))
                Text("\(model.changes.fileCount) · \(Text("+\(model.changes.additions)").foregroundStyle(Color(uiColor: CodePalette.added))) \(Text("−\(model.changes.deletions)").foregroundStyle(Color(uiColor: CodePalette.removed)))")
                    .font(.system(size: subtitleSize))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            // The bar's height is fixed: its title grows to xxxLarge, as the system's inline titles do.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Changes, \(model.changes.fileCount), \(model.changes.additions) added, \(model.changes.deletions) removed")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) {
            Button { model.toggleWhole() } label: {
                Image(systemName: model.whole ? "plus.forwardslash.minus" : "doc.text")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            // M5d's pill is white like the other trailing pills; the bar would tint the glyph pink.
            .tint(.primary)
            .accessibilityLabel(model.whole ? "Show changes" : "Show whole file")
            .disabled(model.changes.files.isEmpty)
        }
    }

    private enum Entry: Identifiable {
        case header(DiffFile)
        case hunk(file: String, index: Int, text: String)
        case line(file: String, index: Int, kind: DiffLine.Kind, number: Int?, text: AttributedString)
        case status(file: String, text: String, loading: Bool)
        var id: String {
            switch self {
            case .header(let file): "h:" + file.id
            case .hunk(let file, let index, _), .line(let file, let index, _, _, _): "\(index):" + file
            case .status(let file, _, _): "s:" + file
            }
        }
    }

    private var entries: [Entry] {
        var result: [Entry] = []
        for file in model.changes.files {
            result.append(.header(file))
            guard model.open.contains(file.id) else { continue }
            if model.whole {
                switch model.states[file.id] {
                case .loaded(let whole)?:
                    if let note = whole.note { result.append(.status(file: file.id, text: note, loading: false)) }
                    if whole.rows.isEmpty { result.append(.status(file: file.id, text: "The file is empty.", loading: false)) }
                    for (index, row) in whole.rows.enumerated() {
                        result.append(.line(file: "w:" + file.id, index: index, kind: row.kind, number: row.number, text: row.text))
                    }
                case .failed(let message)?: result.append(.status(file: file.id, text: message, loading: false))
                case .loading?, nil: result.append(.status(file: file.id, text: "Reading \(file.title)…", loading: true))
                }
            } else {
                let text = model.highlighted(file)
                if file.lines.isEmpty { result.append(.status(file: file.id, text: "No changes recorded.", loading: false)) }
                for (index, line) in file.lines.enumerated() {
                    if line.kind == .hunk { result.append(.hunk(file: file.id, index: index, text: line.text)) }
                    else { result.append(.line(file: file.id, index: index, kind: line.kind, number: line.number, text: text[index])) }
                }
            }
        }
        return result
    }

    @ViewBuilder private func row(_ entry: Entry) -> some View {
        switch entry {
        case .header(let file): header(file)
        case .hunk(_, _, let text):
            Text(TextRendering.visible(text))
                .font(.system(size: metrics.hunk, design: .monospaced))
                .foregroundStyle(Color(uiColor: CodePalette.hunk))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: metrics.hunkHeight, alignment: .leading)
                .background(Color(uiColor: CodePalette.hunkRow))
        case .line(_, _, let kind, let number, let text): line(kind: kind, number: number, text: text)
        case .status(_, let text, let loading):
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(text).font(.system(size: pathSize)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: headerHeight, alignment: .leading)
        }
    }

    private func header(_ file: DiffFile) -> some View {
        let open = model.open.contains(file.id)
        return Button { model.toggle(file) } label: {
            HStack(spacing: 8) {
                Text("▸")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(uiColor: CodePalette.gutter))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: open)
                    .frame(width: 10)
                Text(TextRendering.visible(file.title))
                    .font(.system(size: pathSize, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fittingLine()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("+\(file.additions)").foregroundStyle(Color(uiColor: CodePalette.added))
                Text("−\(file.deletions)").foregroundStyle(Color(uiColor: CodePalette.removed))
            }
            .font(.system(size: pathSize - 1, design: .monospaced))
            .padding(.horizontal, 14)
            .frame(minHeight: headerHeight)
            .contentShape(Rectangle())
            // A pointer lights the row it would open, as lists do.
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(Color(uiColor: CodePalette.hairline)).frame(height: 0.5) }
        .accessibilityLabel("\(TextRendering.visible(file.title)), \(file.additions) added, \(file.deletions) removed")
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityHint(open ? "Hides the changes" : "Shows the changes")
    }

    private func line(kind: DiffLine.Kind, number: Int?, text: AttributedString) -> some View {
        let sign = kind == .added ? "+" : kind == .removed ? "-" : ""
        let tint: Color = kind == .added ? Color(uiColor: CodePalette.added) : Color(uiColor: CodePalette.removed)
        let metrics = metrics
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

    /// The mockup's code metrics at 12 points (20 pt rows, 10.5 pt numbers in a 34 pt column, 14 pt sign column, 11 pt
    /// hunk headers in 24 pt rows), scaled with the pinch.
    private var metrics: DiffMetrics { DiffMetrics(size: model.fontSize) }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? model.fontSize
                if pinchBase == nil { pinchBase = base }
                let size = CodeFontSize.pinched(base: base, scale: value.magnification)
                if size != model.fontSize { model.fontSize = size }
            }
            .onEnded { _ in
                pinchBase = nil
                model.commitFontSize()
            }
    }
}

/// The diff's code metrics for a text size.
struct DiffMetrics: Equatable {
    let size: Double
    var scale: Double { size / CodeFontSize.standard }
    var code: Double { size }
    var number: Double { size * 0.875 }
    var hunk: Double { size * 11 / 12 }
    var line: Double { (size * 20 / 12).rounded() }
    var hunkHeight: Double { (size * 2).rounded() }
    var sign: Double { (14 * scale).rounded() }
    var numberWidth: Double { (34 * scale).rounded() }
    /// The space between wrapped lines of one row, so each line takes `line` points.
    var spacing: Double { max(0, line - UIFont.monospacedSystemFont(ofSize: size, weight: .regular).lineHeight) }
}
