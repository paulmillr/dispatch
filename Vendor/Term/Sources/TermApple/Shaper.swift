// Text runs and their glyphs (Ghostty's font/shaper/run.zig RunIterator and shaper/coretext.zig):
// a viewport row splits into runs of one font and style, and CoreText's typesetter shapes each.
#if canImport(CoreText)
import CoreText
import Foundation
import Term

public struct TextRun {
    public var offset: Int, cells: Int, style: FontCollection.Style, font: Int   // font -1: the sprite font
    /// The run's code points (UTF-16 units: the second of a surrogate pair is 0) and their
    /// clusters: a range of the shaper's buffer (valid until its next runs call).
    var codepoints: Range<Int>
    /// Of the code points, clusters, style and font (Ghostty's run hash: the shaping cache key).
    var hash: UInt64 = 0x9E37_79B9_7F4A_7C15
}

/// One step of a 64-bit hash (splitmix's finalizer over the running value and the next word).
func mix(_ h: UInt64, _ v: UInt64) -> UInt64 {
    var x = (h ^ v) &* 0xBF58_476D_1CE4_E5B9
    x ^= x >> 31
    return x
}

/// A shaped glyph: the cell (cluster) it belongs to, the glyph, its offset from the cell in pixels.
public struct ShapedCell: Equatable { public var x: Int, glyph: Int, xOffset: Int, yOffset: Int }

public struct Shaper {
    let collection: FontCollection
    /// liga on (Ghostty's default feature), then the configured ones.
    let features: [(tag: String, value: Int)]
    var fonts: [String: CTFont] = [:]
    /// The code points of the last runs call's runs.
    var codepoints: [(cp: UInt32, cluster: Int)] = []

    public init(_ collection: FontCollection, features: [(tag: String, value: Int)] = []) {
        (self.collection, self.features) = (collection, [("liga", 1)] + features)
    }

    /// RunIterator.next for every run of a row: its cells (graphemes and styles read from the
    /// page), the row's selected columns, the cursor's column when it is on the row. Into `runs`
    /// (emptied first; both buffers keep their capacity).
    public mutating func runs(_ cells: RowCells, selection: ClosedRange<Int>?, cursorX: Int?, into runs: inout [TextRun]) {
        var max = cells.count
        while max > 0, cells[max - 1].isEmpty { max -= 1 }
        runs.removeAll(keepingCapacity: true)
        codepoints.removeAll(keepingCapacity: true)
        var i = 0
        while true {
            while i < max, cells[i].hasStyling, cells.style(i).flags.invisible { i += 1 }
            guard i < max else { return }
            let first = cells.style(i)
            let fontStyle: FontCollection.Style = first.flags.bold ? (first.flags.italic ? .boldItalic : .bold) : first.flags.italic ? .italic : .regular
            // The run's font starts as regular 0 (a run that begins on a spacer keeps it).
            var (run, j, current) = (TextRun(offset: i, cells: 0, style: fontStyle, font: 0, codepoints: codepoints.count..<codepoints.count), i, (style: FontCollection.Style.regular, idx: 0))
            cells: while j < max {
                let cell = cells[j]
                if let s = selection, j > i, s.lowerBound > 0 && j == s.lowerBound || s.upperBound > 0 && j == s.upperBound + 1 { break }
                if cell.wide == .spacerHead || cell.wide == .spacerTail { j += 1; continue }
                if j > i {
                    let prev = cells[j - 1]
                    if prev.tag == .codepoint, cell.tag == .codepoint,
                       prev.codepoint == 0x66 && (cell.codepoint == 0x6C || cell.codepoint == 0x69) || prev.codepoint == 0x73 && cell.codepoint == 0x74 { break }
                    if prev.styleID != cell.styleID {
                        var (a, b) = (first, cells.style(j))
                        (a.bgColor, b.bgColor) = (.none, .none)
                        if a != b { break }
                    }
                }
                let g = cells.grapheme(j)
                let presentation: FontCollection.Presentation? = g.flatMap { $0[0] == 0xFE0E ? .text : $0[0] == 0xFE0F ? .emoji : nil }
                if !cell.hasGrapheme, let c = cursorX, i == c && j == i + 1 || i < c && j == c { break }
                var fallback: UInt32?
                var idx = index(cell, g, fontStyle, presentation)
                if idx == nil { idx = collection.index(0xFFFD, fontStyle, presentation); fallback = 0xFFFD }
                if idx == nil { idx = collection.index(0x20, fontStyle, presentation); fallback = 0x20 }
                if j == i { current = idx! }
                if idx! != current { break }
                let cluster = j - i
                if let f = fallback { add(&run, f, cluster); j += 1; continue }
                add(&run, cell.codepoint == 0 || cell.codepoint == 0x10EEEE ? 0x20 : cell.codepoint, cluster)
                if let g { for cp in g where cp != 0xFE0E && cp != 0xFE0F { add(&run, cp, cluster) } }
                j += 1
            }
            (run.cells, run.style, run.font, run.codepoints) = (j - i, current.style, current.idx, run.codepoints.lowerBound..<codepoints.count)
            run.hash = mix(mix(run.hash, UInt64(current.style.rawValue)), UInt64(current.idx + 1))
            runs.append(run)
            i = j
        }
    }

    /// RunIteratorHook.addCodepoint: UTF-16 units, a surrogate pair's second unit as code point 0.
    mutating func add(_ run: inout TextRun, _ cp: UInt32, _ cluster: Int) {
        codepoints.append((cp, cluster))
        run.hash = mix(run.hash, UInt64(cp) | UInt64(cluster) << 32)
        if cp > 0xFFFF { codepoints.append((0, cluster)); run.hash = mix(run.hash, UInt64(cluster) << 32) }
    }

    /// RunIterator.indexForCell: empty cells take a space's face; a grapheme takes the first candidate
    /// face (the primary's, then each grapheme code point's) that has all of its code points.
    func index(_ cell: Cell, _ grapheme: [UInt32]?, _ style: FontCollection.Style, _ p: FontCollection.Presentation?) -> (style: FontCollection.Style, idx: Int)? {
        if cell.isEmpty || cell.codepoint == 0 || cell.codepoint == 0x10EEEE { return collection.index(0x20, style, p) }
        guard let primary = collection.index(cell.codepoint, style, p) else { return nil }
        guard let g = grapheme else { return primary }
        // (no allocation per grapheme: this runs for every grapheme cell of every rebuilt row)
        let skip = { (cp: UInt32) in cp == 0xFE0E || cp == 0xFE0F || cp == 0x200D }
        let fits = { (idx: (style: FontCollection.Style, idx: Int)) in self.has(idx, cell.codepoint, p) && g.allSatisfy { skip($0) || self.has(idx, $0, nil) } }
        if fits(primary) { return primary }
        for cp in g where !skip(cp) {
            guard let idx = collection.index(cp, style, nil) else { return nil }
            if fits(idx) { return idx }
        }
        return nil
    }

    func has(_ idx: (style: FontCollection.Style, idx: Int), _ cp: UInt32, _ p: FontCollection.Presentation?) -> Bool {
        idx.idx >= 0 && collection.has(collection.faces[idx.style.rawValue][idx.idx].entry, cp, p)
    }

    /// Shaper.shape: the sprite font draws code points itself; other fonts go through a CTTypesetter
    /// (embedding level forced left to right) with the font's features.
    public mutating func shape(_ run: TextRun) -> [ShapedCell] {
        let cps = Array(codepoints[run.codepoints])
        if run.font < 0 { return cps.filter { $0.cp != 0 }.map { ShapedCell(x: $0.cluster, glyph: Int($0.cp), xOffset: 0, yOffset: 0) } }
        let font = runFont(run.style, run.font)
        let units = cps.flatMap { cp -> [UInt16] in
            cp.cp == 0 ? [] : cp.cp > 0xFFFF ? Array(String(UnicodeScalar(cp.cp)!).utf16) : [UInt16(cp.cp)]
        }
        let string = CFStringCreateWithCharacters(nil, units, units.count)!
        let attributed = CFAttributedStringCreate(nil, string, [kCTFontAttributeName: font] as CFDictionary)!
        let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(attributed, [kCTTypesetterOptionForcedEmbeddingLevel: 0] as CFDictionary)!
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 0))
        var (cells, runX, runCluster, cellX, cellCluster, nonLTR) = ([ShapedCell](), 0.0, 0, 0.0, 0, false)
        for ctrun in CTLineGetGlyphRuns(line) as! [CTRun] {
            let status = CTRunGetStatus(ctrun)
            if status.contains(.nonMonotonic) || status.contains(.rightToLeft) { nonLTR = true }
            let n = CTRunGetGlyphCount(ctrun)
            var (glyphs, advances, positions, indices) = ([CGGlyph](repeating: 0, count: n), [CGSize](repeating: .zero, count: n),
                                                          [CGPoint](repeating: .zero, count: n), [CFIndex](repeating: 0, count: n))
            CTRunGetGlyphs(ctrun, CFRange(), &glyphs)
            CTRunGetAdvances(ctrun, CFRange(), &advances)
            CTRunGetPositions(ctrun, CFRange(), &positions)
            CTRunGetStringIndices(ctrun, CFRange(), &indices)
            for k in 0..<n {
                let index = indices[k], cluster = cps[index].cluster
                if cellCluster != cluster {
                    // A new cell starts at its first code point, unless glyphs of it or later clusters came already.
                    let firstInCluster = cps[..<index].last { $0.cp != 0 }.map { $0.cluster != cluster } ?? true
                    if firstInCluster, cluster > runCluster { (cellCluster, cellX) = (cluster, runX) }
                }
                cells.append(ShapedCell(x: cellCluster, glyph: Int(glyphs[k]), xOffset: Int((positions[k].x - cellX).rounded()),
                                        yOffset: Int(positions[k].y.rounded())))
                runX += advances[k].width
                runCluster = Swift.max(runCluster, cluster)
            }
        }
        if nonLTR { cells.sort { $0.x < $1.x } }
        return cells
    }

    /// Shaper.getFont: the face with the OpenType feature settings (cached per face).
    mutating func runFont(_ style: FontCollection.Style, _ idx: Int) -> CTFont {
        let key = "\(style.rawValue):\(idx)"
        if let f = fonts[key] { return f }
        let base = collection.face(collection.faces[style.rawValue][idx].entry)
        let settings = features.map { [kCTFontOpenTypeFeatureTag: $0.tag, kCTFontOpenTypeFeatureValue: $0.value] as CFDictionary }
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
        let f = CTFontCreateCopyWithAttributes(base, 0, nil, desc)
        fonts[key] = f
        return f
    }
}
#endif
