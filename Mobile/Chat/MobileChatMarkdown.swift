import Foundation
import SwiftUI

/// Inline Markdown from a remote agent. Formatting is preserved, but only credential-free HTTP(S) links remain
/// active; the environment check is a second boundary in case attributed content reaches the view another way.
enum MobileChatMarkdown {
    static func text(_ text: String) -> AttributedString {
        var value = (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let unsafe = value.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link, !isWebLink(url) else { return nil }
            return run.range
        }
        for range in unsafe { value[range].link = nil }
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
/// (highlighted as the diff viewer highlights it), rules and tables, each block's text inline Markdown.
struct MobileChatMarkdownView: View {
    let text: String
    /// Text on the thread's muted tone (Claude's thinking).
    var muted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                self.block(block)
            }
        }
        .foregroundStyle(muted ? Color.secondary : Color.primary)
    }

    private func inline(_ text: String) -> Text { Text(MobileChatMarkdown.text(text)) }

    @ViewBuilder private func block(_ block: ChatMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            inline(block.text)
        case .heading(let level):
            inline(block.text)
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .callout.weight(.semibold))
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        case .list(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 12, alignment: .trailing)
                inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 12)
        case .quote:
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 2)
                inline(block.text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(CodeSyntax.lines(block.text, language: language).enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
                .font(.footnote.monospaced())
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
                                inline(cell).fontWeight(index == 0 ? .semibold : nil).fixedSize()
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
