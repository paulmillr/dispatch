import SwiftUI

enum ChatSearchHighlight: EnvironmentKey {
    static let defaultValue = ""
    static func text(_ value: AttributedString, query: String, theme: ChatTheme) -> AttributedString {
        guard !query.isEmpty else { return value }
        var result = value
        let plain = String(value.characters)
        var start = plain.startIndex
        while start < plain.endIndex,
              let range = plain.range(of: query, options: .caseInsensitive, range: start..<plain.endIndex) {
            if let span = Range(range, in: result) {
                result[span].backgroundColor = theme.yellow
                result[span].foregroundColor = theme.terminal
            }
            start = range.upperBound
        }
        return result
    }
}

extension EnvironmentValues {
    var chatSearchQuery: String {
        get { self[ChatSearchHighlight.self] }
        set { self[ChatSearchHighlight.self] = newValue }
    }
}

struct ChatMarkdown: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatSearchQuery) private var query
    let text: String
    var fillWidth = true
    /// Default text color; selectable text on macOS 26 ignores foregroundStyle.
    var color: Color?
    /// A live reply typing out (`ChatTypingReveal`): its safe part shows, cut where the reveal is, with the caret.
    var typing: ChatTypingReveal?
    @State private var fileLink: ChatFileLink?
    @State private var selection = ChatMessageSelection()
    var body: some View {
        // Typing: the part of the text that can show, parsed as the whole will be, and how far it has typed.
        let layout = typing?.layout
        let frame = typing?.current
        let rendered = ChatMarkdownCache.document(layout?.source ?? text)
        let count = frame.map { layout?.visibleBlocks($0.shown) ?? 0 } ?? rendered.blocks.count
        VStack(alignment: .leading, spacing: 10) {
            if let frame, frame.shown == 0 {
                ChatTypingCaretLine(caret: frame.caret, color: theme.accent).font(theme.typography.body)
            }
            ForEach(Array(rendered.blocks.prefix(count).enumerated()), id: \.offset) { index, block in
                let cut = layout.flatMap { layout in frame.flatMap { layout.cut(block: index, frame: $0) } }
                switch block.kind {
                case .code(let language):
                    ChatCodeBlock(code: cut.map { ChatTypingLayout.lines(block.text).prefix($0.shown).joined(separator: "\n") } ?? block.text,
                                  language: language)
                case .heading(let level):
                    inline(block.text, cut: cut).font(theme.typography.font(offset: level == 1 ? 7.5 : (level == 2 ? 3.5 : 1), weight: .semibold))
                        .padding(.top, 6).accessibilityAddTraits(.isHeader)
                case .list(let marker, let depth):
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker).foregroundStyle(theme.muted).frame(minWidth: 14, alignment: .trailing)
                        inline(block.text, cut: cut).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.leading, CGFloat(depth) * 14)
                case .quote:
                    HStack(spacing: 10) {
                        Rectangle().fill(theme.muted.opacity(0.5)).frame(width: 2)
                        inline(block.text, color: theme.muted, cut: cut)
                    }.fixedSize(horizontal: false, vertical: true)
                case .rule: Divider().padding(.vertical, 4)
                case .table(let all):
                    let rows = cut.map { Array(all.prefix($0.shown)) } ?? all
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                GridRow {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        inline(cell).fontWeight(index == 0 ? .semibold : .regular)
                                    }
                                }
                                if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }.padding(12)
                    }.background(theme.sidebar, in: RoundedRectangle(cornerRadius: 6))
                case .paragraph: inline(block.text, cut: cut)
                }
            }
            if rendered.truncated {
                Text("Rendered preview truncated for safety")
                    .font(theme.typography.detail).foregroundStyle(theme.muted)
            }
        }.frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if let link = ChatFileLink(url) { fileLink = link; return .handled }
                return ChatMarkdownPolicy.isWebLink(url) ? .systemAction : .discarded
            })
            .sheet(item: $fileLink) { ChatFileLinkPreview(link: $0) }
    }
    @ViewBuilder private func inline(_ text: String, color: Color? = nil, cut: ChatTypingCut? = nil) -> some View {
        if #available(macOS 26, *) {
            let value = attributed(text, color: color)
            let typed = cut.map { $0.apply(to: value, color: theme.accent) }
            ChatSelectableText(value: typed?.value ?? value, selection: selection, source: self.text, caret: typed?.caret)
                .modifier(ChatSelectableBaseline())
        } else {
            Text(cut.map { $0.apply(to: attributed(text, color: color), color: theme.accent).value } ?? attributed(text, color: color))
                .textSelection(.enabled).lineSpacing(theme.typography.lineSpacing).tint(theme.blue)
        }
    }

    private func attributed(_ text: String, color: Color?) -> AttributedString {
        var value = ChatMarkdownCache.inline(text)
        if let color = color ?? self.color { value.foregroundColor = color }
        for run in value.runs where run.link != nil {
            value[run.range].foregroundColor = theme.blue
            value[run.range].underlineStyle = .single
        }
        for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
            value[run.range].foregroundColor = theme.blue
            value[run.range].backgroundColor = theme.ink.opacity(0.05)
            value[run.range].font = theme.typography.codeFont()
        }
        return ChatSearchHighlight.text(value, query: query, theme: theme)
    }

    static func safeInlineMarkdown(_ text: String) -> AttributedString {
        ChatMarkdownPolicy.inline(text, allowingAdditionalLink: { ChatFileLink($0) != nil })
    }
}

/// A message's parsed blocks and each block's inline markdown, by text. A message's view parses again whenever it
/// mounts (a lazy row scrolled back into view, a pane switched back to Chat) and whenever its body runs; Foundation's
/// markdown parser per block was most of that. Pure functions of the text, so bounded and dropped wholesale when full.
@MainActor enum ChatMarkdownCache {
    struct Document {
        let blocks: [ChatMarkdownBlock]
        let truncated: Bool
    }
    private static var documents = ChatTextCache<String, Document>(limit: .init(count: documentLimit.count, bytes: documentLimit.bytes))
    private static var inlines = ChatTextCache<String, AttributedString>(limit: .init(count: inlineLimit.count, bytes: inlineLimit.bytes))
    /// Parses done, for tests.
    private(set) static var documentParses = 0
    private(set) static var inlineParses = 0
    /// Longer texts are parsed each time rather than kept: at most about 8 MB of messages and 8 MB of blocks.
    static let documentLimit = ChatMarkdownCacheBounds.document
    static let inlineLimit = ChatMarkdownCacheBounds.inline

    static func document(_ text: String) -> Document {
        if let cached = documents[text] { return cached }
        documentParses += 1
        let rendered = TextRendering.rich(text)
        let document = Document(blocks: ChatMarkdownBlock.parse(rendered.text), truncated: rendered.truncated)
        documents.insert(document, for: text, source: text)
        return document
    }

    static func inline(_ text: String) -> AttributedString {
        if let cached = inlines[text] { return cached }
        inlineParses += 1
        let value = ChatMarkdown.safeInlineMarkdown(text)
        inlines.insert(value, for: text, source: text)
        return value
    }
}

@MainActor enum ChatTextStorageEdit {
    /// Edits only what follows the characters the shown text shares with the new one, when those keep their
    /// attributes too (a streamed block growing at its end); otherwise replaces it all. One comparison of the shared
    /// part in Foundation: walking its runs bridged every run's attributes to Swift, which cost more than the edit.
    static func replace(_ storage: NSTextStorage, with text: NSAttributedString) {
        let old = storage.string as NSString, new = text.string as NSString
        let shared = min(old.length, new.length)
        var prefix = 0
        while prefix < shared, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var start = 0
        if prefix > 0 {
            let range = NSRange(location: 0, length: prefix)
            if storage.attributedSubstring(from: range).isEqual(to: text.attributedSubstring(from: range)) { start = prefix }
        }
        guard start < old.length || start < new.length else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: start, length: old.length - start),
                                  with: text.attributedSubstring(from: NSRange(location: start, length: new.length - start)))
        storage.endEditing()
    }
}

/// What message text views cost, for tests: views made, texts built, sizes measured.
@MainActor enum ChatTextMetrics {
    static var views = 0
    static var builds = 0
    static var measures = 0
}

/// One message text view's own builds and measures, so a test counts its window's views rather than every transcript
/// alive in the process.
@MainActor protocol ChatTextCounting: AnyObject {
    var builds: Int { get }
    var measures: Int { get }
}

/// The native text view reports no text baselines, so baseline-aligned stacks (the radio log's columns) would fall back
/// to its bottom edge. Its first line sits at the top with no inset, so TextKit 1 draws the first baseline at the font's
/// ascent rounded to a whole point.
@available(macOS 26, *)
private struct ChatSelectableBaseline: ViewModifier {
    // The keys it reads, not the whole environment: any environment change would run it again for every block.
    @Environment(\.font) private var font
    @Environment(\.chatTheme) private var theme
    @Environment(\.fontResolutionContext) private var fontContext
    func body(content: Content) -> some View {
        let font = (font ?? theme.typography.body).resolve(in: fontContext).ctFont
        let ascent = CTFontGetAscent(font).rounded()
        content.alignmentGuide(.firstTextBaseline) { _ in ascent }
    }
}

// macOS 26's SwiftUI selection overlay can loop between clipping and wrapping
// when accessibility inspects an offscreen LazyVStack row. Keep native selection
// without that overlay; Font.resolve preserves the inherited SwiftUI typography.
@available(macOS 26, *)
private struct ChatSelectableText: NSViewRepresentable {
    // The keys the text is built from, not the whole environment (`\.self`): with that, every environment change
    // anywhere above a transcript rebuilt and measured every block of every mounted message.
    @Environment(\.chatTheme) private var theme
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.openURL) private var openURL
    let value: AttributedString
    let selection: ChatMessageSelection
    /// The whole message's markdown, copied after Select All.
    let source: String
    /// A typing reply's caret, after the text's last character shown (`ChatTypingCut`).
    var caret: ChatTypingCaret? = nil
    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1: TextKit 2 adds and moves a view per text fragment during layout, and each one
        // asks the hosting views for another constraint pass. In a long transcript inside the
        // window's nested hosting views, AppKit stopped with "repeated Update Constraints passes".
        let view = SelectableTextView(usingTextLayoutManager: false)
        ChatTextMetrics.views += 1
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.linkTextAttributes = [:]
        // No frame or bounds notifications: a container tracking its view's width observes them, and every text
        // view's observer made each frame change in the window search a longer list (and each text view's release
        // remove its own). SwiftUI places the view; its container follows its width in setFrameSize instead.
        view.textContainer?.widthTracksTextView = false
        view.postsFrameChangedNotifications = false
        view.postsBoundsChangedNotifications = false
        view.delegate = context.coordinator
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.open = openURL
        if let view = view as? SelectableTextView {
            view.source = source
            if view.selection !== selection { view.selection = selection; selection.views.add(view) }
            view.caret = caret
        }
        let base = font ?? theme.typography.body
        let key = Coordinator.Key(value: value, lineSpacing: theme.typography.lineSpacing, ink: theme.ink, font: base, context: fontContext)
        // Built, set and measured again only when what it is built from changed.
        guard key != coordinator.key else { return }
        coordinator.key = key
        coordinator.sizes.removeAll(keepingCapacity: true)
        ChatTextMetrics.builds += 1
        (view as? SelectableTextView)?.builds += 1
        let text = NSMutableAttributedString(attributedString: NSAttributedString(value))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = theme.typography.lineSpacing
        text.addAttributes([.paragraphStyle: paragraph, .foregroundColor: coordinator.color(theme.ink)],
                           range: NSRange(location: 0, length: text.length))
        var offset = 0
        // One slice over the five attributes read here: each `run.attribute` instantiates its key path again, and
        // that cost most of a streamed block's update.
        let fontKey: KeyPath<AttributeDynamicLookup, AttributeScopes.SwiftUIAttributes.FontAttribute> = \.font
        let intentKey: KeyPath<AttributeDynamicLookup, AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute> = \.inlinePresentationIntent
        let foregroundKey: KeyPath<AttributeDynamicLookup, AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute> = \.foregroundColor
        let backgroundKey: KeyPath<AttributeDynamicLookup, AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute> = \.backgroundColor
        let linkKey: KeyPath<AttributeDynamicLookup, AttributeScopes.FoundationAttributes.LinkAttribute> = \.link
        for (runFont, intent, foreground, background, link, runRange) in value.runs[fontKey, intentKey, foregroundKey, backgroundKey, linkKey] {
            let count = String(value[runRange].characters).utf16.count
            let range = NSRange(location: offset, length: count)
            var font = runFont ?? base
            if intent?.contains(.stronglyEmphasized) == true { font = font.bold() }
            if intent?.contains(.emphasized) == true { font = font.italic() }
            var resolved = font.resolve(in: fontContext).ctFont
            if intent?.contains(.emphasized) == true, let italic = ChatFont.italic(for: resolved) { resolved = italic }
            if intent?.contains(.stronglyEmphasized) == true,
               let bold = ChatFont.boldPostScriptName(CTFontCopyPostScriptName(resolved) as String) {
                resolved = CTFontCreateWithName(bold as CFString, CTFontGetSize(resolved), nil)
            }
            text.addAttribute(.font, value: resolved, range: range)
            if let foreground { text.addAttribute(.foregroundColor, value: coordinator.color(foreground), range: range) }
            if let background { text.addAttribute(.backgroundColor, value: coordinator.color(background), range: range) }
            if link != nil { text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            if intent?.contains(.strikethrough) == true { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            offset += count
        }
        // Its fonts are set above. Left in, TextKit's attribute fixing derives a font from each intent again on every
        // edit, the largest part of a streamed block's update.
        text.removeAttribute(.inlinePresentationIntent, range: NSRange(location: 0, length: text.length))
        if let storage = view.textStorage { ChatTextStorageEdit.replace(storage, with: text) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        // SwiftUI asks several times per layout pass, and again on every pass; the text only changes in updateNSView.
        if let size = context.coordinator.sizes[width] { return size }
        ChatTextMetrics.measures += 1
        (view as? SelectableTextView)?.measures += 1
        let size = (view.textStorage ?? view.attributedString()).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let fitted = CGSize(width: min(width, ceil(size.width)), height: ceil(size.height))
        if context.coordinator.sizes.count >= 8 { context.coordinator.sizes.removeAll(keepingCapacity: true) }
        context.coordinator.sizes[width] = fitted
        return fitted
    }
    func makeCoordinator() -> Coordinator { Coordinator(open: openURL) }
    final class SelectableTextView: NSTextView, ChatTextCounting, ChatTypingCaretDrawing {
        weak var selection: ChatMessageSelection?
        var source = ""
        var builds = 0, measures = 0
        var caret: ChatTypingCaret? {
            didSet { if caret != oldValue { needsDisplay = true } }
        }
        var typingCaret: ChatTypingCaret? { caret }
        /// VoiceOver reads what shows, not the rest of the word laid out after it.
        override func accessibilityValue() -> String? {
            guard let caret else { return super.accessibilityValue() }
            let string = self.string as NSString
            return string.substring(to: min(caret.offset, string.length))
        }
        func typingCaretRect(after offset: Int) -> NSRect? { caretRect(after: offset) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let caret, caret.alpha > 0, let rect = caretRect(after: caret.offset) else { return }
            caret.color.withAlphaComponent(caret.alpha).setFill()
            rect.fill()
        }
        /// The caret's bar: 2 points wide, one cell after the character ending at UTF-16 `offset` (the start of the
        /// next line after a line break), from that line's ascender to its descender. Its trailing edge in
        /// left-to-right text: right-to-left text gets it on the same side.
        func caretRect(after offset: Int) -> NSRect? {
            guard offset > 0, let layout = layoutManager, let container = textContainer, let storage = textStorage,
                  offset <= storage.length else { return nil }
            let string = storage.string as NSString
            let last = string.rangeOfComposedCharacterSequence(at: offset - 1)
            let glyphs = layout.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return nil }
            let font = storage.attribute(.font, at: last.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
            var line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            var baseline = layout.location(forGlyphAt: glyphs.location).y
            var x = layout.boundingRect(forGlyphRange: glyphs, in: container).maxX
            if string.character(at: last.location) == 0x0A {
                if offset < storage.length {
                    let next = layout.glyphIndexForCharacter(at: offset)
                    line = layout.lineFragmentRect(forGlyphAt: next, effectiveRange: nil)
                    baseline = layout.location(forGlyphAt: next).y
                } else {
                    line = layout.extraLineFragmentRect
                }
                x = line.minX
            }
            let origin = textContainerOrigin
            return NSRect(x: (origin.x + x).rounded(), y: origin.y + line.minY + baseline - font.ascender,
                          width: 2, height: font.ascender - font.descender)
        }
        /// SwiftUI's host view around each block moves with every row above it: nothing observes its frame either.
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            superview?.postsFrameChangedNotifications = false
        }
        /// Its container follows its width here, as `widthTracksTextView` would through frame notifications.
        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            guard let container = textContainer else { return }
            let width = max(0, size.width - textContainerInset.width * 2)
            if container.size.width != width { container.size = NSSize(width: width, height: container.size.height) }
        }
        /// Select All spans every block of the message, not just this paragraph.
        override func selectAll(_ sender: Any?) {
            guard let selection else { return super.selectAll(sender) }
            selection.selectAll()
        }
        override func copy(_ sender: Any?) {
            guard selection?.isWhole == true else { return super.copy(sender) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(source, forType: .string)
        }
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { selection?.clear(except: nil) }
            return resigned
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// What the shown text was built from.
        struct Key: Equatable {
            let value: AttributedString
            let lineSpacing: CGFloat
            let ink: Color
            let font: Font
            let context: Font.Context
        }
        var open: OpenURLAction
        var key: Key?
        /// Measured sizes by proposed width, for the shown text.
        var sizes: [CGFloat: CGSize] = [:]
        /// The same color object for the same color, build after build: a dynamic color made again compares unequal,
        /// and `replace` would then edit the whole text.
        private var colors: [Color: NSColor] = [:]
        func color(_ color: Color) -> NSColor {
            if let made = colors[color] { return made }
            if colors.count >= 16 { colors.removeAll(keepingCapacity: true) }
            let made = NSColor(color)
            colors[color] = made
            return made
        }
        init(open: OpenURLAction) { self.open = open }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? SelectableTextView,
                  let selection = view.selection, selection.isWhole, !selection.applying else { return }
            selection.clear(except: view)
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { open(url) }
            return true
        }
    }
}

/// Ties the separate text views of one rendered message together so Select All
/// covers the whole message and Copy then yields its markdown source.
@MainActor final class ChatMessageSelection {
    let views = NSHashTable<NSTextView>.weakObjects()
    private(set) var isWhole = false
    private(set) var applying = false

    func selectAll() {
        applying = true; defer { applying = false }
        for view in views.allObjects { view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count)) }
        isWhole = true
    }
    /// Drops the message-wide selection; `kept` retains the user's new selection.
    func clear(except kept: NSTextView?) {
        guard isWhole else { return }
        isWhole = false
        applying = true; defer { applying = false }
        for view in views.allObjects where view !== kept { view.setSelectedRange(NSRange(location: 0, length: 0)) }
    }
}

extension ChatTypingCut {
    /// `value` cut: the shown characters as they are, the hidden ones clear (`ChatTypingLayout.hidden`), and the caret
    /// (in `color`) at the UTF-16 offset after the shown ones.
    func apply(to value: AttributedString, color: Color) -> (value: AttributedString, caret: ChatTypingCaret?) {
        let parts = ChatTypingLayout.split(value, shown: shown, hidden: hidden)
        var result = parts.shown
        result.append(ChatTypingLayout.hidden(parts.tail))
        // Without a caret (another block has it) the view still knows where its shown text ends.
        return (result, ChatTypingCaret(offset: String(parts.shown.characters).utf16.count, alpha: caret ?? 0, color: NSColor(color)))
    }
}

/// The caret a typing reply's text view draws (`ChatSelectableText`): after UTF-16 `offset`, at `alpha` (0: none, the
/// text after `offset` is still laid out undrawn).
struct ChatTypingCaret: Equatable {
    let offset: Int
    let alpha: Double
    let color: NSColor
}

/// A message text view that draws a typing reply's caret, for tests: the caret and where it draws.
@MainActor protocol ChatTypingCaretDrawing: NSTextView {
    var typingCaret: ChatTypingCaret? { get }
    func typingCaretRect(after offset: Int) -> NSRect?
}
