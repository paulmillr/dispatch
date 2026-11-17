import Foundation
import SwiftUI

/// Inline Markdown from a remote agent. Formatting is preserved, but only credential-free HTTP(S) links remain
/// active; the environment check is a second boundary in case attributed content reaches the view another way.
enum MobileChatMarkdown {
    /// `code`: the font of inline code (paths, commands), the terminal's (`ChatTypography.code`); nil keeps the
    /// system's monospaced one. `emphasis`: emphasized text's font where the text's own has no italic
    /// (`ChatTypography.emphasis`); nil lets the text's font italicize.
    static func text(_ text: String, code: Font? = nil, emphasis: Font? = nil) -> AttributedString {
        var value = ChatMarkdownPolicy.inline(text)
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
        ChatMarkdownPolicy.isWebLink(url)
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
    /// A live reply typing out (`ChatTypingReveal`): its safe part shows, cut where the reveal is, with the caret.
    var typing: ChatTypingReveal? = nil
    /// Settings' chat font: inline code and code blocks in the terminal's font.
    @Environment(\.chatTypography) private var typography
    @Environment(\.chatSearchMarks) private var marks
    @Environment(\.chatSearchCurrent) private var current
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.chatPalette) private var palette

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
    static func contents(_ text: String, code: Font? = nil, emphasis: Font? = nil, syntax: CodeSyntax.Colors = .standard,
                         marker: inout ChatSearchMarker) -> (blocks: [Content], truncated: Bool) {
        let rendered = TextRendering.rich(text)
        let blocks = ChatMarkdownBlock.parse(rendered.text).map { block -> Content in
            switch block.kind {
            case .code(let language):
                let preview = TextRendering.prefix(block.text, scalars: 32_768)
                return .code(lines: CodeSyntax.lines(preview.text, language: language, colors: syntax).map { marker.mark($0) },
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
    static func contents(_ text: String, code: Font?, emphasis: Font?, syntax: CodeSyntax.Colors = .standard)
        -> (blocks: [Content], truncated: Bool) {
        let key = Parsed(text: text, code: code, emphasis: emphasis, syntax: syntax.id)
        if let parsed = parsed[key] { return parsed }
        var none = ChatSearchMarker(query: "", current: nil)
        let contents = contents(text, code: code, emphasis: emphasis, syntax: syntax, marker: &none)
        // A streamed message leaves a parse per update behind: the cache starts over rather than tracking use.
        parsed.insert(contents, for: key, source: text)
        return contents
    }

    private struct Parsed: Hashable {
        let text: String
        let code: Font?
        let emphasis: Font?
        /// The code's colours (`CodeSyntax.Colors.id`): they are baked into the lines.
        let syntax: String
    }
    private static var parsed = ChatTextCache<Parsed, (blocks: [Content], truncated: Bool)>(
        limit: .init(count: ChatMarkdownCacheBounds.document.count, bytes: ChatMarkdownCacheBounds.document.bytes))

    /// The blocks as drawn: marked by an open search, else from the cache. A typing reply's are its safe part's.
    private var shownContents: (blocks: [Content], truncated: Bool) {
        let text = typing?.layout.source ?? text
        guard var marker = ChatSearchMarker(marks, current: current) else {
            return Self.contents(text, code: typography.inlineCode, emphasis: typography.emphasis, syntax: palette.syntax)
        }
        return Self.contents(text, code: typography.inlineCode, emphasis: typography.emphasis, syntax: palette.syntax,
                             marker: &marker)
    }

    var body: some View {
        let contents = shownContents
        // Typing: only the stage is read here, so a frame draws the typing block (`MobileTypingTail`) and nothing else.
        let stage = typing?.stage
        let count = min(stage?.count ?? contents.blocks.count, contents.blocks.count)
        let whole = min(stage?.live ?? count, count)
        let last = contents.blocks.indices.last
        let inline = corner.map { Self.sharesLine($0, blocks: contents.blocks, truncated: contents.truncated, layout: layoutDirection) } ?? false
        let room = inline ? corner?.room : nil
        ZStack(alignment: .topLeading) {
            if typing != nil {
                // The shown blocks whole, laid out but not drawn and of no height: a bubble that hugs its text is as wide
                // as what has arrived from the start, and only grows a line at a time as it types.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(contents.blocks.prefix(count).enumerated()), id: \.offset) { _, block in
                        MobileMarkdownBlock(content: block)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 0, alignment: .top)
                .hidden()
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(contents.blocks.prefix(whole).enumerated()), id: \.offset) { index, block in
                    MobileMarkdownBlock(content: block, room: index == last ? room : nil, corner: corner)
                }
                if let typing {
                    MobileTypingTail(reveal: typing, blocks: Array(contents.blocks[whole..<count]), first: whole, last: last,
                                     room: room, corner: corner, caretAlone: count == 0)
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
        }
        .foregroundStyle(muted ? palette.muted : palette.ink)
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

    /// A block cut for typing: code to its shown lines, a table to its shown rows (text is cut as it is drawn).
    static func cut(_ content: Content, _ cut: ChatTypingCut) -> Content {
        switch content {
        case .code(let lines, let truncated): .code(lines: Array(lines.prefix(cut.shown)), truncated: truncated && cut.shown >= lines.count)
        case .table(let rows): .table(Array(rows.prefix(cut.shown)))
        case .text, .rule: content
        }
    }

    /// A text block's runs while typing: the shown characters, the rest of the word laid out but not drawn, the caret.
    /// Joined with `+`, not interpolated: an interpolated `Text` is a format string SwiftUI scans again on every frame.
    static func typed(_ text: AttributedString, _ cut: ChatTypingCut) -> some View {
        let parts = ChatTypingLayout.split(text, shown: cut.shown, hidden: cut.hidden)
        return (Text(parts.shown) + Text(ChatTypingLayout.hidden(parts.tail)).customAttribute(ChatTypingHidden()))
            .textRenderer(ChatTypingRenderer(caret: cut.caret ?? 0, color: .dispatchPink))
            .accessibilityLabel(Text(parts.shown))
    }
}

/// The blocks of a typing reply that a frame can change (`ChatTypingStage.live` on), and the caret alone on a line
/// before any shows: the blocks before them are not evaluated, compared or laid out again as it types. The first is the
/// one typing; those after it show whole (`ChatTypingStage`). A text block types as a `ChatTypingParagraph`, which draws
/// the frames itself, so no SwiftUI view updates as it types; a code block or table (by line or row) and the caret
/// alone read the frames here.
private struct MobileTypingTail: View {
    let reveal: ChatTypingReveal
    let blocks: [MobileChatMarkdownView.Content]
    /// The index of the first of `blocks` in the reply.
    let first: Int
    /// The reply's last block, which keeps the corner's room once it shows whole.
    let last: Int?
    let room: String?
    let corner: ChatCorner?
    /// Nothing shows yet: the caret alone on a line.
    let caretAlone: Bool
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        if caretAlone { MobileTypingCaret(reveal: reveal) }
        ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
            let index = first + offset
            if offset > 0 {
                MobileMarkdownBlock(content: block, room: index == last ? room : nil, corner: corner)
            } else if case .text(_, let text) = block, reveal.layout.blocks.indices.contains(index),
                      reveal.layout.blocks[index].isText, ChatTypingParagraph.supports(text, direction: direction) {
                MobileMarkdownBlock(content: block, paragraph: (reveal, index))
            } else {
                MobileTypingFrameBlock(reveal: reveal, index: index, block: block, room: index == last ? room : nil,
                                       corner: corner)
            }
        }
    }
}

/// The caret alone on a line, before any of a typing reply shows.
private struct MobileTypingCaret: View {
    let reveal: ChatTypingReveal
    var body: some View { ChatTypingCaretLine(caret: reveal.current.caret, color: .dispatchPink) }
}

/// A typing block SwiftUI cuts on every frame: a code block by line, a table by row, text a typing paragraph does not
/// draw (right to left).
private struct MobileTypingFrameBlock: View {
    let reveal: ChatTypingReveal
    let index: Int
    let block: MobileChatMarkdownView.Content
    let room: String?
    let corner: ChatCorner?
    var body: some View {
        if let cut = reveal.layout.cut(block: index, frame: reveal.current) {
            MobileMarkdownBlock(content: MobileChatMarkdownView.cut(block, cut), typing: cut)
        } else {
            MobileMarkdownBlock(content: block, room: room, corner: corner)
        }
    }
}

/// One block of an agent message as `MobileChatMarkdownView` draws it: `room` keeps the corner's room after a text
/// block's runs (`ChatTurnCorner.room`), `typing` cuts it as it types, `paragraph` types a text block's runs as a
/// `ChatTypingParagraph` (the reveal, and the block's index in its layout).
struct MobileMarkdownBlock: View {
    typealias Content = MobileChatMarkdownView.Content
    let content: Content
    var room: String? = nil
    var corner: ChatCorner? = nil
    var typing: ChatTypingCut? = nil
    var paragraph: (reveal: ChatTypingReveal, index: Int)? = nil
    @Environment(\.chatTypography) private var typography
    @Environment(\.chatPalette) private var palette

    var body: some View { block(content, room: room, typing: typing) }

    /// A text block's runs, with the room after them: VoiceOver reads the text without it, and the corner as the value.
    private func runs(_ text: AttributedString, room: String?, typing: ChatTypingCut? = nil) -> some View {
        Group {
            if let paragraph {
                ChatTypingParagraph(text: text, reveal: paragraph.reveal, block: paragraph.index)
            } else if let typing {
                MobileChatMarkdownView.typed(text, typing)
            } else if let room {
                let spoken = corner?.spoken ?? ""
                Text(room.isEmpty ? text : MobileChatMarkdownView.joined(text, room: room))
                    .accessibilityLabel(Text(text))
                    .accessibilityValue(spoken)
                    .accessibilityHint(spoken.isEmpty ? "" : corner?.hint ?? "")
            } else {
                Text(text)
            }
        }
    }

    @ViewBuilder private func block(_ content: Content, room: String? = nil, typing: ChatTypingCut? = nil) -> some View {
        switch content {
        case .text(.heading(let level), let text):
            runs(text, room: room, typing: typing)
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : typography.body.weight(.semibold))
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        case .text(.list(let marker, let depth), let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 12, alignment: .trailing)
                runs(text, room: room, typing: typing).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 12)
        case .text(.quote, let text):
            HStack(spacing: 8) {
                Rectangle().fill(palette.muted.opacity(0.5)).frame(width: 2)
                runs(text, room: room, typing: typing).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .text(_, let text):
            runs(text, room: room, typing: typing)
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
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if let fill = palette.codeFill { shape.fill(fill) }
                if let border = palette.codeBorder { shape.strokeBorder(border, lineWidth: 1) }
            }
        case .rule:
            Rectangle().fill(palette.hairline).frame(height: 1)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).fontWeight(index == 0 ? .semibold : nil).fixedSize()
                            }
                        }
                        if index == 0 { Rectangle().fill(palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .font(.footnote)
            }
        }
    }
}

/// Characters of a typing reply laid out but not drawn (`MobileChatMarkdownView.typed`).
struct ChatTypingHidden: TextAttribute {}

/// Draws a typing reply's text without its hidden characters, and the caret: a 2-point bar one cell after the last
/// character shown, at `caret` opacity.
struct ChatTypingRenderer: TextRenderer {
    let caret: Double
    let color: Color
    var displayPadding: EdgeInsets { EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 2) }
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var bar: CGRect?
        for line in layout {
            for run in line where run[ChatTypingHidden.self] == nil {
                context.draw(run)
                let bounds = run.typographicBounds.rect
                bar = CGRect(x: bounds.maxX.rounded(), y: bounds.minY, width: 2, height: bounds.height)
            }
        }
        if caret > 0, let bar { context.fill(Path(bar), with: .color(color.opacity(caret))) }
    }
}

/// An agent's reply in the thread, typing out while it streams in the live turn (`ChatTypingReveals`); otherwise, and
/// with Reduce Motion, as `MobileChatMarkdownView` draws it at once. Only the typing block reads the reveal's frames
/// (`MobileTypingTail`): a step draws that block again, nothing around it. The reveal counts as shown only while the
/// row is within the thread's visible bounds: the thread's stack is not lazy, so a row scrolled away is still in the
/// view tree, and its reveal would type for no one. Scrolled back, it shows what arrived and types on from there.
struct MobileTypedMarkdown: View {
    @ReduceMotion private var reduceMotion
    let text: String
    var corner: ChatCorner?
    let rowID: String
    let reveals: ChatTypingReveals
    let live: Bool
    let ended: Bool
    /// Its agent posts whole messages (`ChatTypingReveals.posts`): nothing streams into the row.
    var posts = false
    /// The reveal this view counts as shown (its clock runs only while one does).
    @State private var shown: ChatTypingReveal?
    @State private var appeared = false
    @State private var onScreen = true
    var body: some View {
        let typing = reveals.reveal(rowID, text: text, live: live, ended: ended, posts: posts, reduceMotion: reduceMotion)
        MobileChatMarkdownView(text: text, corner: corner, typing: typing)
            .onScreen($onScreen)
            .onAppear { appeared = true; show(onScreen ? typing : nil) }
            .onDisappear { appeared = false; show(nil) }
            .onChange(of: typing.map(ObjectIdentifier.init)) { _, _ in if appeared { show(onScreen ? typing : nil) } }
            .onChange(of: onScreen) { _, visible in if appeared { show(visible ? typing : nil) } }
    }
    private func show(_ reveal: ChatTypingReveal?) {
        guard shown !== reveal else { return }
        if let shown { reveals.disappeared(shown) }
        if let reveal { reveals.appeared(reveal) }
        shown = reveal
    }
}
