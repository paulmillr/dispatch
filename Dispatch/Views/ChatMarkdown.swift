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
    @State private var fileLink: ChatFileLink?
    @State private var selection = ChatMessageSelection()
    var body: some View {
        let rendered = ChatMarkdownCache.document(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rendered.blocks.enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .code(let language): ChatCodeBlock(code: block.text, language: language)
                case .heading(let level):
                    inline(block.text).font(theme.typography.font(offset: level == 1 ? 7.5 : (level == 2 ? 3.5 : 1), weight: .semibold))
                        .padding(.top, 6).accessibilityAddTraits(.isHeader)
                case .list(let marker, let depth):
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker).foregroundStyle(theme.muted).frame(minWidth: 14, alignment: .trailing)
                        inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.leading, CGFloat(depth) * 14)
                case .quote:
                    HStack(spacing: 10) {
                        Rectangle().fill(theme.muted.opacity(0.5)).frame(width: 2)
                        inline(block.text, color: theme.muted)
                    }.fixedSize(horizontal: false, vertical: true)
                case .rule: Divider().padding(.vertical, 4)
                case .table(let rows):
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
                case .paragraph: inline(block.text)
                }
            }
            if rendered.truncated {
                Text("Rendered preview truncated for safety")
                    .font(theme.typography.detail).foregroundStyle(theme.muted)
            }
        }.frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if let link = ChatFileLink(url) { fileLink = link; return .handled }
                return Self.isWebLink(url) ? .systemAction : .discarded
            })
            .sheet(item: $fileLink) { ChatFileLinkPreview(link: $0) }
    }
    @ViewBuilder private func inline(_ text: String, color: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            ChatSelectableText(value: attributed(text, color: color), selection: selection, source: self.text)
                .modifier(ChatSelectableBaseline())
        } else {
            Text(attributed(text, color: color)).textSelection(.enabled).lineSpacing(theme.typography.lineSpacing).tint(theme.blue)
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
        let visible = TextRendering.visible(text)
        var value = (try? AttributedString(markdown: visible, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(visible)
        let unsafe = value.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            guard isWebLink(url) || ChatFileLink(url) != nil else { return run.range }
            return nil
        }
        for range in unsafe { value[range].link = nil }
        return value
    }
    private static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased()) && url.host != nil
            && url.user == nil && url.password == nil
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
    private static var documents: [String: Document] = [:]
    private static var inlines: [String: AttributedString] = [:]
    /// Parses done, for tests.
    private(set) static var documentParses = 0
    private(set) static var inlineParses = 0
    /// Longer texts are parsed each time rather than kept: at most about 8 MB of messages and 8 MB of blocks.
    static let documentLimit = (count: 128, bytes: 64 * 1024)
    static let inlineLimit = (count: 1024, bytes: 8 * 1024)

    static func document(_ text: String) -> Document {
        if let cached = documents[text] { return cached }
        documentParses += 1
        let rendered = TextRendering.rich(text)
        let document = Document(blocks: ChatMarkdownBlock.parse(rendered.text), truncated: rendered.truncated)
        guard text.utf8.count <= documentLimit.bytes else { return document }
        if documents.count >= documentLimit.count { documents.removeAll(keepingCapacity: true) }
        documents[text] = document
        return document
    }

    static func inline(_ text: String) -> AttributedString {
        if let cached = inlines[text] { return cached }
        inlineParses += 1
        let value = ChatMarkdown.safeInlineMarkdown(text)
        guard text.utf8.count <= inlineLimit.bytes else { return value }
        if inlines.count >= inlineLimit.count { inlines.removeAll(keepingCapacity: true) }
        inlines[text] = value
        return value
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
        text.addAttributes([.paragraphStyle: paragraph, .foregroundColor: NSColor(theme.ink)],
                           range: NSRange(location: 0, length: text.length))
        var offset = 0
        for run in value.runs {
            let count = String(value[run.range].characters).utf16.count
            let range = NSRange(location: offset, length: count)
            var font = run.font ?? base
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { font = font.bold() }
            if run.inlinePresentationIntent?.contains(.emphasized) == true { font = font.italic() }
            var resolved = font.resolve(in: fontContext).ctFont
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true,
               let bold = ChatFont.boldPostScriptName(CTFontCopyPostScriptName(resolved) as String) {
                resolved = CTFontCreateWithName(bold as CFString, CTFontGetSize(resolved), nil)
            }
            text.addAttribute(.font, value: resolved, range: range)
            if let color = run.foregroundColor { text.addAttribute(.foregroundColor, value: NSColor(color), range: range) }
            if let color = run.backgroundColor { text.addAttribute(.backgroundColor, value: NSColor(color), range: range) }
            if run.link != nil { text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            offset += count
        }
        if view.attributedString() != text { view.textStorage?.setAttributedString(text) }
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
    final class SelectableTextView: NSTextView, ChatTextCounting {
        weak var selection: ChatMessageSelection?
        var source = ""
        var builds = 0, measures = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
