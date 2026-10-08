// Glyph rasterization (Ghostty's SharedGrid.renderGlyph and font/face/coretext.zig renderGlyph):
// the glyph's box is fitted into its cells (emoji always cover them), then CoreGraphics draws it
// into an 8-bit alpha bitmap (or BGRA for color).
#if canImport(CoreText)
import CoreGraphics
import CoreText
import Term

extension FontCollection {
    /// The glyph `glyph` of a face, fitted by `constraint` over `constraintWidth` cells of `cell`
    /// (cell metrics), drawn thicker with `thicken` at gray level `strength`.
    public func raster(_ style: Style, _ idx: Int, glyph: CGGlyph, cell: CellMetrics, constraint: GlyphConstraint,
                       constraintWidth: Int, thicken: Bool = false, strength: UInt8 = 255) -> RasterGlyph {
        let entry = faces[style.rawValue][idx].entry, font = face(entry)
        var glyphs = [glyph]
        var rect = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, 1)
        let color = Face.isColorGlyph(font, glyph)
        var constraint = constraint
        if color {
            // SharedGrid.renderGlyph: emoji always cover their cells, centered, a little padding at the sides.
            constraint = GlyphConstraint()
            (constraint.size, constraint.alignHorizontal, constraint.alignVertical, constraint.padLeft, constraint.padRight) = (.cover, .center, .center, 0.025, 0.025)
        }
        let sbix = color && !(Face.table(font, "sbix")?.isEmpty ?? true)
        if !sbix, let w = entry.syntheticBold {
            (rect.size.width, rect.size.height) = (rect.size.width + w, rect.size.height + w)
            (rect.origin.x, rect.origin.y) = (rect.origin.x - w / 2, rect.origin.y - w / 2)
        }
        if rect.size.width < 0.25 || rect.size.height < 0.25 { return .empty }
        let (cw, ch) = (Double(cell.cellWidth), Double(cell.cellHeight))
        let m = GlyphConstraint.Cell(cellWidth: Int(cell.cellWidth), cellHeight: Int(cell.cellHeight), faceWidth: cell.faceWidth, faceHeight: cell.faceHeight,
                                     faceY: cell.faceY, iconHeight: cell.iconHeight, iconHeightSingle: cell.iconHeightSingle)
        let box = constraint.constrain(.init(width: rect.size.width, height: rect.size.height, x: rect.origin.x, y: rect.origin.y + Double(cell.cellBaseline)),
                                       m, constraintWidth)
        var (x, y, width, height) = (box.x, box.y, box.width, box.height)
        if constraint.size != .stretch {
            // Centered in the cell when the face is narrower or wider than it.
            let dx = (cw - cell.faceWidth) / 2
            x += dx
            if dx < 0 { x -= dx.rounded(.towardZero) }
        }
        if sbix {
            width = cw - (cw - width - x).rounded() - x.rounded()
            height = ch - (ch - height - y).rounded() - y.rounded()
            (x, y) = (x.rounded(), y.rounded())
        }
        let pad = thicken && !sbix ? 1 : 0
        let (pxX, pxY) = (Int(x.rounded(.down)) - pad, Int(y.rounded(.down)) - pad)
        let (fracX, fracY) = (x - x.rounded(.down), y - y.rounded(.down))
        let (pxW, pxH) = (Int((width + fracX).rounded(.up)) + 2 * pad, Int((height + fracY).rounded(.up)) + 2 * pad)
        let depth = color ? 4 : 1
        guard pxW >= 0, pxH >= 0, pxW <= Atlas.maxSize - 2, pxH <= Atlas.maxSize - 2,
              let bytes = [pxW, pxH, depth].reduce(Optional(1), { total, value in total.flatMap { $0.multipliedReportingOverflow(by: value).overflow ? nil : $0 * value } }) else {
            return .empty
        }
        guard let colorSpace = color ? CGColorSpace(name: CGColorSpace.displayP3) : CGColorSpace(name: CGColorSpace.linearGray) else { return .empty }
        var pixels = [UInt8](repeating: 0, count: bytes)
        var rendered = false
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: pxW * depth,
                                      space: colorSpace,
                                      bitmapInfo: color ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                                                        : CGImageAlphaInfo.alphaOnly.rawValue) else { return }
            rendered = true
            ctx.setAllowsFontSmoothing(true)
            ctx.setShouldSmoothFonts(thicken)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.setShouldSubpixelPositionFonts(true)
            ctx.setAllowsFontSubpixelQuantization(false)
            ctx.setShouldSubpixelQuantizeFonts(false)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            if color {
                ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
            } else {
                ctx.setFillColor(gray: Double(strength) / 255, alpha: 1)
                ctx.setStrokeColor(gray: Double(strength) / 255, alpha: 1)
            }
            if let w = entry.syntheticBold {
                ctx.setTextDrawingMode(.fillStroke)
                ctx.setLineWidth(w)
            }
            ctx.translateBy(x: fracX + Double(pad), y: fracY + Double(pad))
            ctx.scaleBy(x: width / rect.size.width, y: height / rect.size.height)
            CTFontDrawGlyphs(font, glyphs, [CGPoint(x: -rect.origin.x, y: -rect.origin.y)], 1, ctx)
        }
        guard rendered else { return .empty }
        return RasterGlyph(width: pxW, height: pxH, offsetX: pxX, offsetY: pxY + pxH, color: color, pixels: pixels)
    }
}
#endif
