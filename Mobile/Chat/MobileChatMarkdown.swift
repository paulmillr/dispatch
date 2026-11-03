import Foundation
import SwiftUI

/// Inline Markdown from a remote agent. Formatting is preserved, but only credential-free HTTP(S) links remain
/// active; the environment check is a second boundary in case attributed content reaches the view another way.
enum MobileChatMarkdown {
    /// `code`: the font of inline code (paths, commands), the terminal's (`ChatTypography.code`); nil keeps the
    /// system's monospaced one. `emphasis`: emphasized text's font where the text's own has no italic
    /// (`ChatTypography.emphasis`); nil lets the text's font italicize.
    static func text(_ text: String, code: Font? = nil, emphasis: Font? = nil) -> AttributedString {
        let visible = TextRendering.visible(text)
        var value = (try? AttributedString(
            markdown: visible, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(visible)
        let unsafe = value.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link, !isWebLink(url) else { return nil }
            return run.range
        }
        for range in unsafe { value[range].link = nil }
        if let emphasis {
            let spans = value.runs.compactMap { run -> (Range<AttributedString.Index>, Bool)? in
                guard let intent = run.inlinePresentationIntent, intent.contains(.emphasized), !intent.contains(.code) else { return nil }
                return (run.range, intent.contains(.stronglyEmphasized))
            }
            for (range, strong) in spans { value[range].font = strong ? emphasis.bold() : emphasis }
        }
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
    /// What the bubble says in its bottom-right corner (S6d). When the last block is text running the layout's
    /// way and the corner fits one line, the text keeps its room (`ChatTurnCorner.room`, after the search has marked
    /// the text, never read aloud) and the corner lies over it: on the last line when it leaves room, else on a short
    /// line of its own. Otherwise (code, a table, a rule, a cut preview, text running the other way, a corner too
    /// wide for one line) the corner takes trailing lines of its own below.
    /// An undrawn corner (`ChatCorner.spokenOnly`) is the last text's VoiceOver value alone.
    var corner: ChatCorner? = nil
    /// Settings' chat font: inline code and code blocks in the terminal's font.
    @Environment(\.chatTypography) private var typography
    @Environment(\.chatSearchMarks) private var marks
    @Environment(\.chatSearchCurrent) private var current
    @Environment(\.layoutDirection) private var layoutDirection

    /// One block's runs of text, as drawn.
    enum Content {
        case text(ChatMarkdownBlock.Kind, AttributedString)
        case code(lines: [AttributedString], truncated: Bool)
        case table([[AttributedString]])
        case rule
    }

    /// The blocks' runs of text in drawing order, each passed through `marker` (which counts and highlights matches);
    /// `code` is inline code's font and `emphasis` emphasized text's in the chat font (`MobileChatMarkdown.text`); tables
    /// and the first two heading levels draw in system styles, which italicize themselves.
    static func contents(_ text: String, code: Font? = nil, emphasis: Font? = nil,
                         marker: inout ChatSearchMarker) -> (blocks: [Content], truncated: Bool) {
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
            case .heading(let level):
                let emphasis = level > 2 ? emphasis?.weight(.semibold) : nil
                return .text(block.kind, marker.mark(MobileChatMarkdown.text(block.text, code: code, emphasis: emphasis)))
            default:
                return .text(block.kind, marker.mark(MobileChatMarkdown.text(block.text, code: code, emphasis: emphasis)))
            }
        }
        return (blocks, rendered.truncated)
    }

    /// `contents` with nothing marked, kept by text and fonts: a thread draws every bubble when it opens and again as
    /// the rows around it change, and parsing, the link checks and highlighting were most of what a bubble cost.
    static func contents(_ text: String, code: Font?, emphasis: Font?) -> (blocks: [Content], truncated: Bool) {
        let key = Parsed(text: text, code: code, emphasis: emphasis)
        if let parsed = parsed[key] { return parsed }
        var none = ChatSearchMarker(query: "", current: nil)
        let contents = contents(text, code: code, emphasis: emphasis, marker: &none)
        // A streamed message leaves a parse per update behind: the cache starts over rather than tracking use.
        if parsed.count >= 512 { parsed.removeAll(keepingCapacity: true) }
        parsed[key] = contents
        return contents
    }

    private struct Parsed: Hashable {
        let text: String
        let code: Font?
        let emphasis: Font?
    }
    private static var parsed: [Parsed: (blocks: [Content], truncated: Bool)] = [:]

    /// The blocks as drawn: marked by an open search, else from the cache.
    private var shownContents: (blocks: [Content], truncated: Bool) {
        guard var marker = ChatSearchMarker(marks, current: current) else {
            return Self.contents(text, code: typography.inlineCode, emphasis: typography.emphasis)
        }
        return Self.contents(text, code: typography.inlineCode, emphasis: typography.emphasis, marker: &marker)
    }

    var body: some View {
        let contents = shownContents
        let last = contents.blocks.indices.last
        let inline = corner.map { Self.sharesLine($0, blocks: contents.blocks, truncated: contents.truncated, layout: layoutDirection) } ?? false
        let room = inline ? corner?.room : nil
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(contents.blocks.enumerated()), id: \.offset) { index, block in
                self.block(block, room: index == last ? room : nil)
            }
            if contents.truncated {
                Text("Rendered preview truncated for safety").font(.footnote).foregroundStyle(.secondary)
            }
            if let corner, !inline, corner.drawn {
                // Trailing lines of the corner's own.
                corner.view(true)
                    .padding(.top, -4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(corner.spoken ?? "")
                    .accessibilityHint(corner.hint ?? "")
                    .accessibilityHidden(corner.spoken?.isEmpty != false)
            }
        }
        .foregroundStyle(muted ? Color.secondary : Color.primary)
        .overlay(alignment: .bottomTrailing) {
            if inline, let corner {
                // 12 points in from the bubble's edge and 7 up (its padding is 14 and 9).
                corner.view(false)
                    .padding(.trailing, -2)
                    .padding(.bottom, -2)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Whether `corner` lies over room kept in the last line: the last block is text that runs the layout's way (the
    /// room follows the text's end, the corner the layout's trailing edge) and the corner fits one line.
    static func sharesLine(_ corner: ChatCorner, blocks: [Content], truncated: Bool, layout: LayoutDirection) -> Bool {
        guard corner.fits, !truncated, case .text(_, let text)? = blocks.last else { return false }
        return (direction(of: String(text.characters)) ?? layout) == layout
    }

    /// A paragraph's direction as its first strong letter sets it; nil without one.
    static func direction(of text: String) -> LayoutDirection? {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, Arabic Extended, the presentation forms.
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                if scalar.properties.isAlphabetic { return .rightToLeft }
            default:
                if scalar.properties.isAlphabetic { return .leftToRight }
            }
        }
        return nil
    }

    /// A text block's runs with the corner's room after them (`ChatTurnCorner.room`): the text as the search marked it,
    /// the room unmarked.
    static func joined(_ text: AttributedString, room: String) -> AttributedString { text + ChatTurnCorner.room(room) }

    /// A text block's runs, with the room after them: VoiceOver reads the text without it, and the corner as the value.
    private func runs(_ text: AttributedString, room: String?) -> some View {
        Group {
            if let room {
                let spoken = corner?.spoken ?? ""
                Text(room.isEmpty ? text : Self.joined(text, room: room))
                    .accessibilityLabel(Text(text))
                    .accessibilityValue(spoken)
                    .accessibilityHint(spoken.isEmpty ? "" : corner?.hint ?? "")
            } else {
                Text(text)
            }
        }
    }

    @ViewBuilder private func block(_ content: Content, room: String? = nil) -> some View {
        switch content {
        case .text(.heading(let level), let text):
            runs(text, room: room)
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : typography.body.weight(.semibold))
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        case .text(.list(let marker, let depth), let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 12, alignment: .trailing)
                runs(text, room: room).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 12)
        case .text(.quote, let text):
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 2)
                runs(text, room: room).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .text(_, let text):
            runs(text, room: room)
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
