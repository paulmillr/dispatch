import AppKit
import SwiftUI

/// A previewed file's text as one read-only text view: selectable across lines with the mouse, ⌘A and ⌘C, its line
/// numbers in a gutter it draws itself. What it holds is what `FileTextLines` prepared, so a rogue file stays defused
/// here too: invisible and control characters are spelled out (`TextRendering.visible`), lines past `lineLimit` are
/// cut, the file past `linesLimit` lines too. A copy or a drag takes that shown text as plain text only, never the
/// file's hidden characters and never styles. TextKit 1 with non-contiguous layout lays out only what is near the
/// visible part.
struct FileTextDocument: NSViewRepresentable {
    let document: FileTextLines.Document
    let theme: ChatTheme
    let metrics: FilePreviewMetrics.Metrics
    let wrap: Bool
    let lineNumbers: Bool
    /// The find field's query while it highlights, else empty.
    let query: String
    /// The match find has selected, by its order in the text.
    let current: Int
    /// Bumped by find's next and previous, so the same match scrolls into view again.
    let step: Int
    var keeper: FilePreviewScrollKeeper?
    /// The text view has the keyboard: the preview pane counts as focused (⌘F, esc).
    var focusChanged: (Bool) -> Void = { _ in }
    /// The pane asks for the keyboard (an arrow from the list, find closing): the text view takes it.
    var wantsFocus = false
    /// Esc in the text: true when something took it (find closing); otherwise it goes on up the responder chain.
    var escape: () -> Bool = { false }
    /// How many matches `query` has in the text, as find counts them.
    var matched: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The space it is offered, never a size of its own: the scroll view's fitting size would shift the pane's rows.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 100, height: 100))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let text = FileTextView(usingTextLayoutManager: false)
        text.layoutManager?.allowsNonContiguousLayout = true
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.allowsUndo = false
        text.usesFindBar = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.smartInsertDeleteEnabled = false
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false
        text.textContainerInset = NSSize(width: 14, height: 10)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.setAccessibilityIdentifier("file-preview-document")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? FileTextView else { return }
        let coordinator = context.coordinator
        text.focusChanged = focusChanged
        text.escape = escape
        if coordinator.document !== document.text {
            coordinator.document = document.text
            text.textStorage?.setAttributedString(document.text)
            text.lineStarts = document.lineStarts
            text.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.highlighted = nil
        }
        if coordinator.theme != theme {
            coordinator.theme = theme
            text.selectedTextAttributes = [.backgroundColor: NSColor(theme.selection), .foregroundColor: NSColor(theme.selectedText)]
            text.numberColor = NSColor(theme.muted)
            text.separatorColor = NSColor(theme.border)
            text.numberFont = FileTextLines.font(theme.typography)
            coordinator.highlighted = nil
        }
        // The gutter as the rows had it: 14 in, the widest number, 10 to the rule, then the text's own 14.
        let digits = CGFloat(max(2, String(document.lineStarts.count).count)) * metrics.digitWidth
        text.configure(digits: lineNumbers ? digits : nil, rowHeight: metrics.rowHeight, lineHeight: metrics.lineHeight,
                       wrap: wrap)
        scroll.hasHorizontalScroller = !wrap
        if coordinator.keeper == nil, keeper != nil {
            // In the document, so it finds this scroll view as the rows' keeper did.
            let probe = FilePreviewScrollKeeper.Probe()
            text.addSubview(probe)
            coordinator.keeper = probe
        }
        if let keeper, let probe = coordinator.keeper {
            probe.preview = keeper.preview
            probe.key = keeper.key
        }
        matched(coordinator.highlight(query, current: current, in: text, theme: theme))
        if coordinator.scrolledStep != step || coordinator.scrolledQuery != query {
            coordinator.scrolledStep = step
            coordinator.scrolledQuery = query
            coordinator.reveal(current, in: text)
        }
        if wantsFocus, text.window != nil, text.window?.firstResponder !== text {
            DispatchQueue.main.async { [weak text] in
                if let text, let window = text.window, window.firstResponder !== text { window.makeFirstResponder(text) }
            }
        }
    }

    final class Coordinator {
        var document: NSAttributedString?
        var theme: ChatTheme?
        var keeper: FilePreviewScrollKeeper.Probe?
        var scrolledStep = -1
        var scrolledQuery = ""
        /// The query and current match the text is highlighted for.
        var highlighted: (query: String, current: Int)?
        private(set) var matches: [NSRange] = []

        /// Marks `query`'s matches (as `ChatSearchHighlight` does, the current one at full strength) on the layout only:
        /// the text, and so a copy, is never touched. Returns how many there are.
        @MainActor func highlight(_ query: String, current: Int, in text: FileTextView, theme: ChatTheme) -> Int {
            if let highlighted, highlighted.query == query, highlighted.current == current { return matches.count }
            guard let layout = text.layoutManager else { return 0 }
            let whole = NSRange(location: 0, length: (text.string as NSString).length)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            if highlighted?.query != query { matches = FileTextLines.matches(of: query, in: text.string) }
            highlighted = (query, current)
            let yellow = NSColor(theme.yellow)
            for (index, range) in matches.enumerated() {
                let strong = index == current
                layout.addTemporaryAttributes([.backgroundColor: strong ? yellow : yellow.withAlphaComponent(0.35),
                                               .foregroundColor: strong ? NSColor(theme.terminal) : NSColor(theme.ink)],
                                              forCharacterRange: range)
            }
            return matches.count
        }

        /// Puts match `current` in the middle of the view, as the rows' `scrollTo(anchor: .center)` did.
        @MainActor func reveal(_ current: Int, in text: FileTextView) {
            guard matches.indices.contains(current), let layout = text.layoutManager, let container = text.textContainer,
                  let clip = text.enclosingScrollView?.contentView else { return }
            let glyphs = layout.glyphRange(forCharacterRange: matches[current], actualCharacterRange: nil)
            layout.ensureLayout(forGlyphRange: glyphs)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += text.textContainerOrigin.x; rect.origin.y += text.textContainerOrigin.y
            let size = clip.bounds.size
            var origin = NSPoint(x: clip.bounds.minX, y: rect.midY - size.height / 2)
            if rect.minX < clip.bounds.minX || rect.maxX > clip.bounds.maxX { origin.x = max(0, rect.midX - size.width / 2) }
            origin.y = min(max(0, origin.y), max(0, text.frame.height - size.height))
            clip.scroll(to: origin)
            text.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }
}

/// The preview's text view: read-only, selectable, copying plain text, its line numbers in a gutter before the text.
final class FileTextView: NSTextView {
    /// Where each line starts in the text (UTF-16), for the numbers and `lineRect`.
    var lineStarts: [Int] = [0]
    var focusChanged: (Bool) -> Void = { _ in }
    var escape: () -> Bool = { false }
    var numberColor = NSColor.secondaryLabelColor
    var separatorColor = NSColor.separatorColor
    var numberFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// The numbers' column width; nil without line numbers.
    private var digits: CGFloat?
    private(set) var rowHeight: CGFloat = 20
    private(set) var lineHeight: CGFloat = 15
    private var wrap = true

    /// What the gutter takes before the text's own inset: 14 in, the numbers, 10 to the rule.
    private var gutter: CGFloat { digits.map { 14 + $0 + 10 } ?? 0 }

    func configure(digits: CGFloat?, rowHeight: CGFloat, lineHeight: CGFloat, wrap: Bool) {
        guard digits != self.digits || rowHeight != self.rowHeight || lineHeight != self.lineHeight || wrap != self.wrap
        else { return }
        self.digits = digits; self.rowHeight = rowHeight; self.lineHeight = lineHeight; self.wrap = wrap
        isHorizontallyResizable = !wrap
        invalidateTextContainerOrigin()
        fitContainer()
        if !wrap { sizeToFit() }
        needsDisplay = true
    }

    /// Wrapped, the text fits what the gutter and both insets leave of the view; unwrapped, its lines run on.
    private func fitContainer() {
        let width = wrap ? max(1, (enclosingScrollView?.contentSize.width ?? frame.width) - gutter - 2 * textContainerInset.width)
            : CGFloat.greatestFiniteMagnitude
        if textContainer?.containerSize.width != width {
            textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
    }

    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x + gutter, y: origin.y)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if wrap { fitContainer() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        fitContainer()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusChanged(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusChanged(false) }
        return resigned
    }

    override func cancelOperation(_ sender: Any?) {
        if escape() { return }
        // Not ours: the files pane's esc (back to the list) is further up.
        nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
    }

    /// Plain text only, as the text shows it: a copy never carries styles (the preview's colours) or anything hidden.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return false }
        let string = string as NSString
        pboard.clearContents()
        return pboard.setString(ranges.map { string.substring(with: $0) }.joined(separator: "\n"), forType: .string)
    }

    // MARK: Gutter

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let digits, let layout = layoutManager, let container = textContainer else { return }
        separatorColor.setFill()
        NSRect(x: 14 + digits + 10, y: rect.minY, width: 1, height: rect.height).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: numberColor]
        let string = string as NSString
        let origin = textContainerOrigin
        func draw(_ number: Int, top: CGFloat) {
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: 14 + digits - size.width, y: top + origin.y + (rowHeight - size.height) / 2),
                       withAttributes: attributes)
        }
        let area = NSRect(x: 0, y: rect.minY - origin.y, width: .greatestFiniteMagnitude, height: rect.height)
        let glyphs = layout.glyphRange(forBoundingRect: area, in: container)
        var index = glyphs.location
        while index < NSMaxRange(glyphs) {
            var effective = NSRange()
            let fragment = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            let character = layout.characterIndexForGlyph(at: index)
            // A wrapped line's later rows get no number.
            if character == 0 || string.character(at: character - 1) == 0x0A {
                draw(Self.line(of: character, in: lineStarts), top: fragment.minY)
            }
            index = NSMaxRange(effective)
        }
        // An empty last line (or an empty file) is the layout's extra fragment.
        let extra = layout.extraLineFragmentRect
        if extra.height > 0, area.intersects(extra) { draw(lineStarts.count, top: extra.minY) }
    }

    /// The 1-based line holding `character`: the last line start at or before it.
    static func line(of character: Int, in starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= character { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    /// Line `number` (from 1) in window coordinates: its text's box, the row's height less its inset above and below,
    /// across every row it wraps onto. Nil past the last line.
    func lineRect(_ number: Int) -> NSRect? {
        guard number >= 1, number <= lineStarts.count, let layout = layoutManager else { return nil }
        let length = (string as NSString).length
        let start = lineStarts[number - 1]
        let end = number < lineStarts.count ? lineStarts[number] - 1 : length
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: start, length: max(0, end - start)), actualCharacterRange: nil)
        var rect: NSRect?
        if glyphs.length == 0 {
            if start >= length, length > 0 || layout.numberOfGlyphs == 0 {
                layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
                rect = layout.extraLineFragmentRect
            } else {
                layout.ensureLayout(forCharacterRange: NSRange(location: start, length: 1))
                rect = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            }
            rect?.size.width = 0
        } else {
            layout.ensureLayout(forGlyphRange: glyphs)
            var index = glyphs.location
            while index < NSMaxRange(glyphs) {
                var effective = NSRange()
                let used = layout.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: &effective)
                rect = rect.map { $0.union(used) } ?? used
                index = NSMaxRange(effective)
            }
        }
        guard var box = rect, box.height > 0 else { return nil }
        let inset = (rowHeight - lineHeight) / 2
        let origin = textContainerOrigin
        box.origin.x += origin.x; box.origin.y += origin.y + inset
        box.size.height = max(0, box.height - 2 * inset)
        return convert(box, to: nil)
    }
}
