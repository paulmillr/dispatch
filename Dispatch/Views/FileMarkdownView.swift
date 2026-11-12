import AppKit
import SwiftUI

/// How Files' rendered Markdown is set: a file is read, not scanned. Its prose is three points over Settings' size,
/// where chat's replies are one over (San Francisco at 16 pt for Settings' 14, two points larger than a reply), in the
/// chat font, or San Francisco where that is the code font. Code keeps the code font, its blocks a point over chat's.
/// The column is at most `ems` of the prose's size wide, about 80 characters a line, and centred in the pane.
@MainActor enum FileMarkdownStyle {
    /// Points the prose, and the code in blocks, gain over Settings' size.
    static let larger = 3.0
    static let largerCode = 1.0
    /// The column's widest, in ems of the prose (`FileMarkdownLayout`, the phone's too).
    static let ems = FileMarkdownLayout.ems
    /// Beside the column: room for a heading's fold chevron (`gutter`), and the least a narrow pane keeps.
    static let margin: CGFloat = 40
    static let gutter: CGFloat = 24

    struct Typography: Equatable {
        let prose: ChatTypography
        /// What the code blocks are set from (`ChatCodeBlock` reads its theme's).
        let code: ChatTypography
    }
    private struct Key: Equatable {
        let size: Double
        let family: String
        let ligatures: Bool
        let font: ChatFont
        let spacing: LineSpacing
    }
    private static var resolved: (key: Key, typography: Typography)?

    static func typography(_ preferences: Preferences) -> Typography {
        var reading = preferences
        if reading.chatFont == .sameAsCode { reading.chatFont = .system }
        let key = Key(size: reading.fontSize, family: reading.fontFamily, ligatures: reading.fontLigatures,
                      font: reading.chatFont, spacing: reading.lineSpacing)
        if let resolved, resolved.key == key { return resolved.typography }
        var prose = reading, code = reading
        prose.fontSize = preferences.fontSize + larger
        code.fontSize = preferences.fontSize + largerCode
        let typography = Typography(prose: ChatTypography(preferences: prose), code: ChatTypography(preferences: code))
        resolved = (key, typography)
        return typography
    }

    static func measure(_ typography: ChatTypography) -> CGFloat { (typography.pointSize() * ems).rounded() }

    /// A heading's font: its level's share of the prose's size, to the half point; the first bold, the rest semibold.
    static func heading(_ level: Int, _ typography: ChatTypography) -> Font {
        typography.font(offset: headingOffset(level, typography), weight: level == 1 ? .bold : .semibold)
    }

    /// The points `ChatTypography.font(offset:)` adds to the prose's size for a heading of `level`.
    static func headingOffset(_ level: Int, _ typography: ChatTypography) -> CGFloat {
        let share = FileMarkdownLayout.headingShare(level)
        return (typography.size * (share - 1) * 2).rounded() / 2
    }

    /// The space above a block (`FileMarkdownLayout.gap`, the phone's too).
    static func gap(before kind: ChatMarkdownBlock.Kind, after previous: ChatMarkdownBlock.Kind?, afterFolded: Bool = false,
                    size: CGFloat) -> CGFloat {
        FileMarkdownLayout.gap(before: kind, after: previous, afterFolded: afterFolded, size: size)
    }
}

/// A heading the rendered Markdown at `path` is to scroll to (the outline's choice); the view clears it once shown.
struct FileMarkdownReveal: Equatable {
    let path: String
    /// `FileMarkdownDocument.Heading.id`.
    let heading: String
    let token: UUID
}

extension FilesSession {
    /// Shows `heading` of the rendered file at `path`: the sections around it open, and the view scrolls to it.
    func reveal(_ heading: FileMarkdownDocument.Heading, of document: FileMarkdownDocument, at path: String) {
        setFolds(document.revealing(heading, in: previewFolds[path] ?? []), at: path)
        previewReveal = FileMarkdownReveal(path: path, heading: heading.id, token: System.uuid())
    }

    func toggleFold(_ heading: FileMarkdownDocument.Heading, at path: String) {
        var folded = previewFolds[path] ?? []
        if folded.remove(heading.id) == nil { folded.insert(heading.id) }
        setFolds(folded, at: path)
    }

    func setFolds(_ folded: Set<String>, at path: String) {
        let folds: Set<String>? = folded.isEmpty ? nil : folded
        if previewFolds[path] != folds { previewFolds[path] = folds }
    }
}

/// A Markdown file rendered for reading (Files' preview with the eye on): a centred column of prose
/// (`FileMarkdownStyle`), six sizes of heading, and sections that fold from the chevron a heading shows beside it
/// under the pointer (or while folded). The header's outline (`FileMarkdownOutlineButton`) lists the headings and
/// scrolls to one. Folds are the tab's, by file (`FilesSession.previewFolds`), and never change the file; a search
/// shows every section, folded or not. Chat's blocks draw as chat draws them (`ChatMarkdown`), which this view leaves
/// alone.
struct FileMarkdownView: View {
    @Environment(\.chatTheme) private var theme
    let session: FilesSession
    let path: String
    let text: String
    /// Keeps the scroll while the view goes and comes back.
    var keeper: FilePreviewScrollKeeper?

    var body: some View {
        let typography = FileMarkdownStyle.typography(TerminalRuntime.shared.preferences)
        let document = FileMarkdownDocuments.document(text)
        var reading = theme, code = theme
        reading.typography = typography.prose
        code.typography = typography.code
        return ScrollViewReader { proxy in
            ScrollView {
                FileMarkdownBlocks(session: session, path: path, text: text, document: document, codeTheme: code)
                    .font(typography.prose.body)
                    .frame(maxWidth: FileMarkdownStyle.measure(typography.prose), alignment: .leading)
                    .padding(.horizontal, FileMarkdownStyle.margin)
                    .padding(.top, 28).padding(.bottom, 48)
                    .frame(maxWidth: .infinity)
                    .background { keeper }
            }
            .onChange(of: session.previewReveal, initial: true) { _, reveal in
                guard let reveal, reveal.path == path else { return }
                session.previewReveal = nil
                guard let heading = document.headings.first(where: { $0.id == reveal.heading }) else { return }
                proxy.scrollTo(heading.block, anchor: .top)
            }
        }
        .environment(\.chatTheme, reading)
    }
}

private struct FileMarkdownBlocks: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatSearchQuery) private var query
    let session: FilesSession
    let path: String
    let text: String
    let document: FileMarkdownDocument
    /// The theme with the code blocks' typography (`FileMarkdownStyle.Typography.code`).
    let codeTheme: ChatTheme
    @State private var fileLink: ChatFileLink?
    @State private var selection = ChatMessageSelection()

    var body: some View {
        let typography = theme.typography, size = typography.pointSize()
        let folded = session.previewFolds[path] ?? []
        let shown = document.shown(folded: folded, searching: !query.isEmpty)
        let headings = Dictionary(uniqueKeysWithValues: document.headings.enumerated().map { ($1.block, (number: $0, heading: $1)) })
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element) { position, index in
                let block = document.blocks[index]
                let before = position > 0 ? shown[position - 1] : nil
                row(block, heading: headings[index], folded: isFolded(headings[index]?.heading, in: folded))
                    .padding(.top, FileMarkdownStyle.gap(before: block.kind, after: before.map { document.blocks[$0].kind },
                                                         afterFolded: isFolded(before.flatMap { headings[$0]?.heading }, in: folded),
                                                         size: size))
                    .id(index)
            }
            if document.truncated {
                Text("The rest is not rendered: the source shows the whole file.")
                    .font(typography.detail).foregroundStyle(theme.muted)
                    .padding(.top, size)
                    .accessibilityIdentifier("file-markdown-truncated")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if let link = ChatFileLink(url) { fileLink = link; return .handled }
            return ChatMarkdownPolicy.isWebLink(url) ? .systemAction : .discarded
        })
        .sheet(item: $fileLink) { ChatFileLinkPreview(link: $0) }
    }

    /// The heading's section is folded and shows so: a search opens every section while it has a query.
    private func isFolded(_ heading: FileMarkdownDocument.Heading?, in folded: Set<String>) -> Bool {
        guard let heading, query.isEmpty else { return false }
        return heading.foldable && folded.contains(heading.id)
    }

    @ViewBuilder private func row(_ block: ChatMarkdownBlock, heading: (number: Int, heading: FileMarkdownDocument.Heading)?,
                                  folded: Bool) -> some View {
        let typography = theme.typography, size = typography.pointSize()
        switch block.kind {
        case .heading(let level):
            let offset = FileMarkdownStyle.headingOffset(level, typography)
            FileMarkdownHeadingRow(number: heading?.number ?? 0, title: heading?.heading.title ?? "",
                                   foldable: heading?.heading.foldable == true, folded: folded,
                                   // Capitals are about 0.7 of a face's size: the chevron sits at their middle.
                                   capHeight: typography.pointSize(offset: offset) * 0.7,
                                   toggle: { if let heading { session.toggleFold(heading.heading, at: path) } }) {
                inline(block.text, color: level >= 6 ? theme.muted : nil)
                    .font(FileMarkdownStyle.heading(level, typography))
                    .accessibilityAddTraits(.isHeader)
            }
        case .paragraph:
            inline(block.text)
        case .list(let marker, let depth):
            // As chat sets an item: the marker on the first baseline, over the text's margin.
            inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                    Text(marker).foregroundStyle(theme.muted).fixedSize()
                        .alignmentGuide(.leading) { $0[.trailing] + (size * 0.5).rounded() }
                }
                .padding(.leading, (CGFloat(depth) * size * 1.25 + size * 1.6).rounded())
        case .quote:
            HStack(spacing: (size * 0.8).rounded()) {
                RoundedRectangle(cornerRadius: 1.5).fill(theme.muted.opacity(0.5)).frame(width: 3)
                inline(block.text, color: theme.muted)
            }.fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, (size * 0.25).rounded())
        case .code(let language):
            ChatCodeBlock(code: block.text, language: language).environment(\.chatTheme, codeTheme)
        case .table(let rows):
            let columns = rows.map(\.count).max() ?? 0
            ChatTableLayout(columns: columns) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    ForEach(0..<columns, id: \.self) { column in
                        inline(column < row.count ? row[column] : "", wordWidth: true)
                            .fontWeight(index == 0 ? .semibold : .regular)
                    }
                    if index < rows.count - 1 { Divider().opacity(index == 0 ? 1 : 0.45) }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.sidebar, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// `wordWidth`: a table cell, whose narrowest width is its longest word (`ChatSelectableText.wordWidth`).
    @ViewBuilder private func inline(_ text: String, color: Color? = nil, wordWidth: Bool = false) -> some View {
        if #available(macOS 26, *) {
            ChatSelectableText(value: attributed(text, color: color), selection: selection, source: self.text, wordWidth: wordWidth)
                .modifier(ChatSelectableBaseline())
        } else {
            Text(attributed(text, color: color))
                .textSelection(.enabled).lineSpacing(theme.typography.naturalLineSpacing).tint(theme.blue)
        }
    }

    private func attributed(_ text: String, color: Color?) -> AttributedString {
        var value = ChatMarkdownCache.inline(text)
        value.foregroundColor = color ?? theme.ink
        for run in value.runs where run.link != nil {
            value[run.range].foregroundColor = theme.blue
            value[run.range].underlineStyle = .single
        }
        for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
            value[run.range].foregroundColor = theme.blue
            value[run.range].backgroundColor = theme.ink.opacity(0.05)
            // Two points under the prose around it: the code font's letters are wider than the prose's at one size.
            value[run.range].font = theme.typography.codeFont(offset: -2)
        }
        return ChatSearchHighlight.text(value, query: query, theme: theme)
    }
}

/// A heading and what folds its section: the chevron in the margin beside it, shown under the pointer or while the
/// section is folded, and then the mark after the title that says there is more. Its hover is its own state, so the
/// pointer crossing a heading draws that row again, not the file.
private struct FileMarkdownHeadingRow<Title: View>: View {
    @Environment(\.chatTheme) private var theme
    let number: Int
    let title: String
    let foldable: Bool
    let folded: Bool
    let capHeight: CGFloat
    let toggle: () -> Void
    @ViewBuilder let content: Title
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Group {
                if foldable {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(folded ? 0 : 90))
                            // Clear rather than absent while the pointer is elsewhere: the button keeps its place and
                            // its click.
                            .foregroundStyle(folded || hovering ? theme.muted : Color.clear)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(folded ? "Unfold this section" : "Fold this section")
                    .accessibilityLabel(folded ? "Unfold \(title)" : "Fold \(title)")
                    .accessibilityIdentifier("file-markdown-fold-\(number)")
                } else {
                    Color.clear.frame(width: 18, height: 18)
                }
            }
            .frame(width: FileMarkdownStyle.gutter, alignment: .leading)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capHeight / 2 }
            content
            if folded {
                Button(action: toggle) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.muted)
                        .frame(width: 24, height: 16)
                        .background(theme.ink.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 10)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capHeight / 2 }
                .help("Unfold this section")
                .accessibilityLabel("Unfold \(title)")
                .accessibilityIdentifier("file-markdown-folded-\(number)")
            }
        }
        // The row is the heading and the margin its chevron is in: the pointer on the chevron is still on the row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .padding(.leading, -FileMarkdownStyle.gutter)
    }
}

/// The header's outline of a rendered Markdown file: its headings, indented under the ones they belong to, each
/// scrolling to its section (opening the folded ones around it), then Fold All and Unfold All.
struct FileMarkdownOutlineButton: View {
    @Environment(\.chatTheme) private var theme
    let session: FilesSession
    let path: String
    let document: FileMarkdownDocument
    @State private var hovering = false

    var body: some View {
        let folded = document.folds(in: session.previewFolds[path] ?? [])
        let all = document.allFolded
        Menu {
            ForEach(document.headings) { heading in
                Button { session.reveal(heading, of: document, at: path) } label: {
                    // Em spaces: a menu keeps them where it trims plain ones.
                    Text(verbatim: String(repeating: "\u{2003}", count: min(heading.depth, 5)) + heading.title)
                }
            }
            Divider()
            Button("Fold All") { session.setFolds(all, at: path) }
                .disabled(all.isEmpty || folded == all)
            Button("Unfold All") { session.setFolds([], at: path) }
                .disabled(folded.isEmpty)
        } label: {
            // Text, as the Commits filter's button: a menu's image label takes the tint instead of its own colour.
            Text(Image(systemName: "list.bullet.indent")).font(.system(size: 11))
                .foregroundStyle(theme.ink.opacity(0.6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(minWidth: 22, minHeight: 22)
        .background {
            let fill = hovering ? theme.ink.opacity(0.08) : Color.clear
            if LiquidGlassStore.shared.active { Capsule().fill(fill) } else { RoundedRectangle(cornerRadius: 4).fill(fill) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("Outline: go to a heading, fold or unfold all")
        .accessibilityLabel("Outline")
        .accessibilityIdentifier("file-preview-outline")
    }
}
