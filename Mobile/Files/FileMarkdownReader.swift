import SwiftUI

/// A Markdown file rendered for reading (F2; the Mac's `FileMarkdownView`): the Mac's document (`FileMarkdownDocument`:
/// paragraphs flowed as their editor wrapped them, front matter as a YAML block, `===` and indented code read as
/// Markdown reads them), set as a page rather than a bubble. The prose is two points over chat's text in chat's font (San
/// Francisco where that is the code font), scaling with Dynamic Type, in a column at most 36 em wide (an iPad's, centred);
/// six sizes of heading, the space between blocks as the Mac sets it (`FileMarkdownLayout`). A tap on a heading with a
/// section folds it, a folded one showing "…" after its title, and another tap opens it; the "…" menu's Outline
/// (`FilePreviewScreen`) lists the headings, scrolls to one (`reveal`), and folds or unfolds them all. Folds are the
/// screen's: they go with it and never change the file.
struct FileMarkdownReader: View {
    let document: FileMarkdownDocument
    @Binding var folded: Set<String>
    /// A heading the page is to scroll to (`FileMarkdownDocument.Heading.id`); cleared once shown.
    @Binding var reveal: String?
    /// Under the last block: what the screen adds (the truncation's notice and Show source).
    var footer: AnyView?
    @Environment(\.chatTypography) private var typography
    /// Dynamic Type's scale at the body style: the page's sizes are Settings' chat size times it.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let page = FileMarkdownPage(typography: typography, scale: scale)
        let shown = document.shown(folded: folded, searching: false)
        let headings = Dictionary(uniqueKeysWithValues: document.headings.enumerated().map { ($1.block, (number: $0, heading: $1)) })
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element) { position, index in
                        let block = document.blocks[index]
                        let before = position > 0 ? shown[position - 1] : nil
                        row(block, heading: headings[index], page: page)
                            .padding(.top, FileMarkdownLayout.gap(before: block.kind, after: before.map { document.blocks[$0].kind },
                                                                  afterFolded: isFolded(before.flatMap { headings[$0]?.heading }),
                                                                  size: page.size))
                            .id(index)
                    }
                    if let footer { footer.padding(.top, page.size) }
                }
                .font(page.body)
                .lineSpacing(page.lineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: page.measure, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: reveal, initial: true) { _, id in
                guard let id else { return }
                reveal = nil
                guard let heading = document.headings.first(where: { $0.id == id }) else { return }
                // After the folds around it opened, so the heading has its place.
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(heading.block, anchor: .top) } }
            }
        }
        .environment(\.openURL, MobileChatMarkdown.openURL)
    }

    private func isFolded(_ heading: FileMarkdownDocument.Heading?) -> Bool {
        guard let heading else { return false }
        return heading.foldable && folded.contains(heading.id)
    }

    private func toggle(_ heading: FileMarkdownDocument.Heading) {
        if folded.remove(heading.id) == nil { folded.insert(heading.id) }
    }

    @ViewBuilder private func row(_ block: ChatMarkdownBlock, heading: (number: Int, heading: FileMarkdownDocument.Heading)?,
                                  page: FileMarkdownPage) -> some View {
        let size = page.size
        switch block.kind {
        case .heading(let level):
            let title = Text(page.inline(block.text, emphasis: page.headingEmphasis(level)))
                .font(page.heading(level))
                .foregroundStyle(level >= 6 ? Color.secondary : Color.primary)
            if let heading, heading.heading.foldable {
                let folded = isFolded(heading.heading)
                Button { withAnimation(.snappy(duration: 0.2)) { toggle(heading.heading) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title.multilineTextAlignment(.leading)
                        if folded {
                            Image(systemName: "ellipsis")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 18)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(folded ? "Folded" : "")
                .accessibilityHint(folded ? "Unfolds its section" : "Folds its section")
                .accessibilityIdentifier("file-markdown-heading-\(heading.number)")
            } else {
                title.accessibilityAddTraits(.isHeader)
            }
        case .paragraph:
            Text(page.inline(block.text))
        case .list(let marker, let depth):
            // As the Mac sets an item: the marker hanging in the margin, the item's lines aligned after it.
            HStack(alignment: .firstTextBaseline, spacing: (size * 0.5).rounded()) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: (size * 1.1).rounded(), alignment: .trailing)
                Text(page.inline(block.text)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, (CGFloat(depth) * size * 1.25).rounded())
        case .quote:
            HStack(spacing: (size * 0.8).rounded()) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Text(page.inline(block.text)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(Color.hairline).frame(height: 1).padding(.vertical, (size * 0.25).rounded())
        case .code(let language):
            let preview = TextRendering.prefix(block.text, scalars: 32_768)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(CodeSyntax.lines(preview.text, language: language).enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                    if preview.truncated { Text("Preview truncated").foregroundStyle(.secondary) }
                }
                .font(page.code)
                .lineSpacing(2)
                .padding(12)
            }
            .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .table(let rows):
            let columns = rows.map(\.count).max() ?? 0
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(0..<columns, id: \.self) { column in
                                Text(page.inline(column < row.count ? row[column] : ""))
                                    .fontWeight(index == 0 ? .semibold : nil)
                                    .fixedSize()
                            }
                        }
                        if index == 0 { Rectangle().fill(Color.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .font(page.small)
                .padding(12)
            }
            .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// The page's type: Settings' chat font and size (`ChatTypography`) set for reading, as the Mac's `FileMarkdownStyle`
/// sets its own. `scale` is Dynamic Type's at the body style.
struct FileMarkdownPage {
    let typography: ChatTypography
    /// The prose's points: two over chat's text (18 at the default size), times Dynamic Type's scale.
    let size: CGFloat
    /// The prose's font: chat's, or San Francisco where chat is set in the code font.
    let face: ChatFontChoice

    init(typography: ChatTypography, scale: CGFloat) {
        self.typography = typography
        size = ((typography.size.points + 2) * scale).rounded()
        face = typography.font == .sameAsCode ? .system : typography.font
    }

    /// The column's widest (`FileMarkdownLayout.ems`).
    var measure: CGFloat { (size * FileMarkdownLayout.ems).rounded() }
    var lineSpacing: CGFloat { typography.lineSpacing.chatSpacing(normal: (size * 0.25).rounded(), size: size) }

    func font(_ points: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let family = typography.family(face) else { return .system(size: points, weight: weight, design: face.systemDesign ?? .default) }
        MobileFonts.register()
        return .custom(family, fixedSize: points * face.sizeScale).weight(weight)
    }

    var body: Font { font(size) }
    /// Tables' text, a little under the prose.
    var small: Font { font(size - 2) }
    /// A heading's points: its level's share of the prose's, to the half point.
    func headingPoints(_ level: Int) -> CGFloat { (size * FileMarkdownLayout.headingShare(level) * 2).rounded() / 2 }
    private func headingWeight(_ level: Int) -> Font.Weight { level == 1 ? .bold : .semibold }
    /// A heading's font: the first bold, the rest semibold.
    func heading(_ level: Int) -> Font { font(headingPoints(level), weight: headingWeight(level)) }
    /// Code blocks: the terminal's font three points under the prose (15 at the default size).
    var code: Font {
        MobileFonts.register()
        return .custom(typography.terminalFont.name, fixedSize: size - 3)
    }
    /// Inline code: the terminal's font two points under the prose, as monospaced letters set wider.
    var inlineCode: Font {
        MobileFonts.register()
        return .custom(typography.terminalFont.name, fixedSize: size - 2)
    }
    /// Emphasis where the prose is SF Rounded, which has no italic: San Francisco's (`ChatTypography.emphasis`).
    var emphasis: Font? { face.systemDesign == .rounded ? .system(size: size, design: .default).italic() : nil }
    func headingEmphasis(_ level: Int) -> Font? {
        emphasis == nil ? nil : .system(size: headingPoints(level), weight: headingWeight(level), design: .default).italic()
    }

    /// A block's inline Markdown (`MobileChatMarkdown.text`: only credential-free web links stay links).
    func inline(_ text: String) -> AttributedString { inline(text, emphasis: emphasis) }
    func inline(_ text: String, emphasis: Font?) -> AttributedString {
        MobileChatMarkdown.text(text, code: inlineCode, emphasis: emphasis)
    }
}
