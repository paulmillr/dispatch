import UIKit

/// How the code composer draws a Markdown draft (M5e), applied in place to the editor's text storage: prose in the
/// system font; an inline span as a mono chip whose backticks become its padding; a fenced block as a mono panel whose
/// opening line is the header with the language tag, its body in the syntax palette, its closing line the panel's
/// bottom padding. Only attributes change: the characters, and so the draft, stay plain Markdown.
struct CodeComposerStyle {
    let prose: UIFont
    let chip: UIFont
    let code: UIFont
    let tag: UIFont
    let proseLine: CGFloat
    let codeLine: CGFloat
    let headerLine: CGFloat
    /// The fence's inner padding (left and top/bottom) and the panel's distance from the trailing edge.
    let inset: CGFloat = 10
    let padding: CGFloat = 8
    let trailing: CGFloat = 6
    /// The gap between prose and a panel.
    let gap: CGFloat = 6
    /// Each backtick of a chip takes this much room: the chip's padding.
    let chipPadding: CGFloat = 6
    static let hidden = UIFont.systemFont(ofSize: 1)

    init(traits: UITraitCollection? = nil) {
        let metrics = UIFontMetrics(forTextStyle: .body)
        func scaled(_ font: UIFont) -> UIFont { metrics.scaledFont(for: font, compatibleWith: traits) }
        prose = scaled(.systemFont(ofSize: 17))
        chip = scaled(.monospacedSystemFont(ofSize: 14, weight: .regular))
        // 12 rather than the mockup's 12.5: SF Mono runs wider than the mockup's font, and 12 keeps its line breaks.
        code = scaled(.monospacedSystemFont(ofSize: 12, weight: .regular))
        tag = scaled(.monospacedSystemFont(ofSize: 10.5, weight: .regular))
        proseLine = metrics.scaledValue(for: 22, compatibleWith: traits).rounded()
        codeLine = metrics.scaledValue(for: 18, compatibleWith: traits).rounded()
        headerLine = metrics.scaledValue(for: 24, compatibleWith: traits).rounded()
    }

    private func paragraph(line: CGFloat, head: CGFloat = 0, tail: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = line
        style.maximumLineHeight = line
        style.firstLineHeadIndent = head
        style.headIndent = head
        style.tailIndent = tail
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        return style
    }

    /// Glyphs sit at the bottom of a line taller than the font; this centres them.
    private func offset(_ font: UIFont, line: CGFloat) -> CGFloat { max(0, (line - font.lineHeight) / 2) }

    /// What prose typed at the caret looks like.
    var proseAttributes: [NSAttributedString.Key: Any] {
        [.font: prose, .foregroundColor: UIColor.label, .paragraphStyle: paragraph(line: proseLine),
         .baselineOffset: offset(prose, line: proseLine)]
    }

    /// What code typed in a fence's body looks like.
    var codeAttributes: [NSAttributedString.Key: Any] {
        [.font: code, .foregroundColor: CodePalette.ink, .paragraphStyle: paragraph(line: codeLine, head: inset, tail: -(inset + trailing)),
         .baselineOffset: offset(code, line: codeLine)]
    }

    /// Styles all of `storage` for `markdown` (its scan of the same text).
    func apply(to storage: NSTextStorage, markdown: ComposerMarkdown) {
        let text = storage.string as NSString
        let all = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.setAttributes(proseAttributes, range: all)
        for chip in markdown.chips {
            storage.addAttributes([.font: self.chip, .foregroundColor: CodePalette.call], range: chip.code)
            let tick = ("`" as NSString).size(withAttributes: [.font: self.chip]).width
            let kern = chipPadding / CGFloat(chip.ticks) - tick
            for ticks in [NSRange(location: chip.range.location, length: chip.ticks),
                          NSRange(location: NSMaxRange(chip.code), length: chip.ticks)] {
                storage.addAttributes([.font: self.chip, .foregroundColor: UIColor.clear, .kern: kern], range: ticks)
            }
        }
        for fence in markdown.fences {
            let leadsText = fence.opening.location > 0
            let closesText = fence.closing.map { NSMaxRange($0) < text.length } ?? false
            // The opening line: the header with the language tag; its backticks take no room.
            storage.setAttributes([.font: tag, .foregroundColor: CodePalette.gutter,
                                   .paragraphStyle: paragraph(line: headerLine, head: inset, tail: -(inset + trailing),
                                                              before: leadsText ? gap : 0, after: padding),
                                   .baselineOffset: offset(tag, line: headerLine)], range: fence.opening)
            let line = text.substring(with: fence.opening)
            let leading = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
            let marker = line.dropFirst(leading).prefix { $0 == "`" || $0 == "~" }.utf16.count
            storage.addAttributes([.font: Self.hidden, .foregroundColor: UIColor.clear],
                                  range: NSRange(location: fence.opening.location, length: leading + marker))
            // The body: code in the palette; an unclosed block keeps its bottom padding after its last line.
            if fence.body.length > 0 {
                var attributes = codeAttributes
                storage.setAttributes(attributes, range: fence.body)
                if fence.closing == nil {
                    let last = text.lineRange(for: NSRange(location: NSMaxRange(fence.body) - 1, length: 0))
                    attributes[.paragraphStyle] = paragraph(line: codeLine, head: inset, tail: -(inset + trailing), after: padding)
                    storage.addAttributes([.paragraphStyle: attributes[.paragraphStyle]!], range: last)
                }
                let body = text.substring(with: fence.body)
                for token in CodeSyntax.tokens(body, language: fence.language) {
                    storage.addAttribute(.foregroundColor, value: token.role.uiColor,
                                         range: NSRange(location: fence.body.location + token.range.location, length: token.range.length))
                }
            }
            // The closing line: the panel's bottom padding, then the gap to prose.
            if let closing = fence.closing {
                storage.setAttributes([.font: Self.hidden, .foregroundColor: UIColor.clear,
                                       .paragraphStyle: paragraph(line: padding, after: closesText ? gap : 0)], range: closing)
            }
        }
        storage.endEditing()
    }
}

/// Draws the chips and panels behind the text (TextKit 1).
final class CodeLayoutManager: NSLayoutManager {
    var markdown = ComposerMarkdown("")
    var style = CodeComposerStyle()
    /// The text ends inside an unclosed fence on an empty line (the extra line fragment belongs to the panel).
    var trailingLineInFence = false

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        for rect in panels(in: container) {
            let panel = rect.panel.offsetBy(dx: origin.x, dy: origin.y)
            let path = UIBezierPath(roundedRect: panel, cornerRadius: 12)
            CodePalette.panel.setFill()
            path.fill()
            CodePalette.panelBorder.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            CodePalette.panelRule.setFill()
            UIRectFill(CGRect(x: panel.minX, y: rect.rule + origin.y, width: panel.width, height: 0.5))
        }
        CodePalette.chip.setFill()
        for rect in chips(in: container) {
            UIBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), cornerRadius: 6).fill()
        }
    }

    /// Each fence's panel and the y of the rule under its header, in container coordinates.
    func panels(in container: NSTextContainer) -> [(panel: CGRect, rule: CGFloat)] {
        markdown.fences.compactMap { fence in
            let glyphs = glyphRange(forCharacterRange: fence.range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return nil }
            var used = CGRect.null
            var header: CGRect?
            enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, range, _ in
                if header == nil { header = usedRect }
                used = used.union(usedRect)
            }
            guard let header, !used.isNull else { return nil }
            var bottom = used.maxY
            if fence.closing == nil {
                if trailingLineInFence, !extraLineFragmentUsedRect.isEmpty { bottom = max(bottom, extraLineFragmentUsedRect.maxY) }
                bottom += style.padding
            }
            let width = container.size.width - style.trailing
            return (CGRect(x: 0, y: used.minY, width: max(0, width), height: bottom - used.minY), header.maxY)
        }
    }

    /// The chips' rounded rects in container coordinates (one per line a chip spans).
    func chips(in container: NSTextContainer) -> [CGRect] {
        var result: [CGRect] = []
        for chip in markdown.chips {
            let glyphs = glyphRange(forCharacterRange: chip.code, actualCharacterRange: nil)
            var rects: [CGRect] = []
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in rects.append(rect) }
            for (index, rect) in rects.enumerated() {
                var chipRect = rect
                if index == 0 { chipRect.origin.x -= style.chipPadding; chipRect.size.width += style.chipPadding }
                if index == rects.count - 1 { chipRect.size.width += style.chipPadding }
                chipRect = chipRect.insetBy(dx: 0, dy: 1)
                result.append(chipRect)
            }
        }
        return result
    }
}
