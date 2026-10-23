import Foundation
import SwiftUI

/// Inline Markdown from a remote agent. Formatting is preserved, but only credential-free HTTP(S) links remain
/// active; the environment check is a second boundary in case attributed content reaches the view another way.
enum MobileChatMarkdown {
    /// `code`: the font of inline code (paths, commands), the terminal's (`ChatTypography.code`); nil keeps the
    /// system's monospaced one.
    static func text(_ text: String, code: Font? = nil) -> AttributedString {
        let visible = TextRendering.visible(text)
        var value = (try? AttributedString(
            markdown: visible, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(visible)
        let unsafe = value.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link, !isWebLink(url) else { return nil }
            return run.range
        }
        for range in unsafe { value[range].link = nil }
        if let code {
            let spans = value.runs.compactMap { run in run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil }
            for range in spans { value[range].font = code }
        }
        return value
    }

    static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased()) && url.host != nil
            && url.user == nil && url.password == nil
    }

    static var openURL: OpenURLAction {
        OpenURLAction { isWebLink($0) ? .systemAction : .discarded }
    }
}

/// An agent message as blocks, by the Mac's rules (`ChatMarkdownBlock`): paragraphs, headings, lists, quotes, code
/// (highlighted as the diff viewer highlights it), rules and tables, each block's text inline Markdown. An open search
/// (`chatSearchMarks`) highlights its matches in the text as drawn (`ChatSearchMarker`).
struct MobileChatMarkdownView: View {
    let text: String
    /// Text on the thread's muted tone (Claude's thinking).
    var muted = false
    /// Settings' chat font: inline code and code blocks in the terminal's font.
    @Environment(\.chatTypography) private var typography
    @Environment(\.chatSearchMarks) private var marks
    @Environment(\.chatSearchCurrent) private var current

    /// One block's runs of text, as drawn.
    enum Content {
        case text(ChatMarkdownBlock.Kind, AttributedString)
        case code(lines: [AttributedString], truncated: Bool)
        case table([[AttributedString]])
        case rule
    }

    /// The blocks' runs of text in drawing order, each passed through `marker` (which counts and highlights matches);
    /// `code` is inline code's font (`MobileChatMarkdown.text`).
    static func contents(_ text: String, code: Font? = nil, marker: inout ChatSearchMarker) -> (blocks: [Content], truncated: Bool) {
        let rendered = TextRendering.rich(text)
        let blocks = ChatMarkdownBlock.parse(rendered.text).map { block -> Content in
            switch block.kind {
            case .code(let language):
                let preview = TextRendering.prefix(block.text, scalars: 32_768)
                return .code(lines: CodeSyntax.lines(preview.text, language: language).map { marker.mark($0) },
                             truncated: preview.truncated)
            case .rule:
                return .rule
            case .table(let rows):
                return .table(rows.map { row in row.map { marker.mark(MobileChatMarkdown.text($0, code: code)) } })
            default:
                return .text(block.kind, marker.mark(MobileChatMarkdown.text(block.text, code: code)))
            }
        }
        return (blocks, rendered.truncated)
    }

    var body: some View {
        var marker = ChatSearchMarker(marks, current: current) ?? ChatSearchMarker(query: "", current: nil)
        let contents = Self.contents(text, code: typography.inlineCode, marker: &marker)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(contents.blocks.enumerated()), id: \.offset) { _, block in
                self.block(block)
            }
            if contents.truncated {
                Text("Rendered preview truncated for safety").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(muted ? Color.secondary : Color.primary)
    }

    @ViewBuilder private func block(_ content: Content) -> some View {
        switch content {
        case .text(.heading(let level), let text):
            Text(text)
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : typography.body.weight(.semibold))
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        case .text(.list(let marker, let depth), let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 12, alignment: .trailing)
                Text(text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 12)
        case .text(.quote, let text):
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 2)
                Text(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .text(_, let text):
            Text(text)
        case .code(let lines, let truncated):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                    if truncated { Text("Preview truncated").foregroundStyle(.secondary) }
                }
                .font(typography.code)
                .padding(10)
            }
            .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .rule:
            Rectangle().fill(Color.hairline).frame(height: 1)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).fontWeight(index == 0 ? .semibold : nil).fixedSize()
                            }
                        }
                        if index == 0 { Rectangle().fill(Color.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .font(.footnote)
            }
        }
    }
}
