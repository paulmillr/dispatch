// Links under the pointer (Ghostty's Surface.zig linkAtPos, linkAtPin, mouseRefreshLinks,
// processLinks, openUrl): OSC 8 hyperlinks with super held, and the config's regex links (the URL
// regex by default).

extension Surface {
    struct Link { var osc8: Bool, selection: Selection }
    static let maxLinkCells = 16 * 1024

    /// The link under a surface position: an OSC 8 hyperlink when the mods are exactly super, else a regex link.
    func linkAt(_ pos: (x: Float, y: Float)) -> Link? {
        guard let pin = cellAt(pos).pin else { return nil }
        let mods = modsWithCapture(mouse.mods)
        if config.linkOSC8, mods == .super, pin.cellValue.hyperlink { return Link(osc8: true, selection: Selection(pin, pin)) }
        return linkAt(pin, mods: mods)
    }

    /// The regex link containing `pin` (Surface.linkAtPin): matches in the pin's line (soft wraps
    /// joined, up to prompt boundaries), searched like StringMap (each search starts where the
    /// last match ended, so look-behinds don't see before it). mods nil: whatever the link's mods.
    func linkAt(_ pin: Pin, mods: Mods?) -> Link? {
        let active = config.links.filter { link in
            guard let mods, let required = link.mods else { return true }
            return required == mods
        }
        guard !active.isEmpty else { return nil }
        let rows = max(1, Self.maxLinkCells / max(terminal.cols, 1) / 2)
        guard let line = screen.selectLine(at: pin, whitespace: nil, promptBoundary: true, maxRows: rows) else { return nil }
        var pins: [Pin]? = []
        let text = screen.selectionString(line, trim: false, pins: &pins)
        guard text.count <= Self.maxLinkCells * 4 else { return nil }
        let scalars = String(decoding: text, as: UTF8.self).unicodeScalars
        let cps = scalars.map(\.value), bytes = [0] + scalars.map { UTF8.width($0) }.reduce(into: [Int]()) { $0.append(($0.last ?? 0) + $1) }
        for link in active {
            var at = 0
            while at < cps.count, let m = link.regex.search(cps, from: at) {
                guard !m.isEmpty else { at = max(at + 1, m.upperBound + 1); continue }
                let (start, end) = (bytes[m.lowerBound], bytes[m.upperBound])
                at = m.upperBound
                guard end > start, end <= pins!.count else { continue }
                let sel = Selection(pins![start], pins![end - 1])
                if contains(sel, pin) { return Link(osc8: false, selection: sel) }
            }
        }
        return nil
    }

    /// The URL an OSC 8 cell links to.
    func osc8URI(_ pin: Pin) -> [UInt8]? { pin.page.hyperlink(pin.cell).map { pin.page.link(id: $0).uri } }

    /// Surface.mouseRefreshLinks: hovering a link shows a pointer and (link previews) its URL;
    /// leaving one restores the program's shape.
    func refreshLinks(_ pos: (x: Float, y: Float), _ vp: (x: Int, y: Int), overLink: Bool) {
        if pos.x < 0 || pos.y < 0 { return }
        mouse.linkPoint = vp
        var url: [UInt8]?
        // A held left button shows links only in the cell it was pressed in.
        if !(mouse.pressed(.left) && mouse.gesture.anchor(terminal).flatMap { screen.point(.viewport, $0) }.map { $0 != vp } ?? false),
           let link = linkAt(pos) {
            url = link.osc8 ? osc8URI(link.selection.start) : screen.selectionString(link.selection, trim: false)
        }
        if let url {
            hover.point = vp
            mouse.overLink = true
            screen.dirty.hyperlinkHover = true
            _ = host?.perform(.mouseShape(MouseShape("pointer")))
            if config.linkPreviews { _ = host?.perform(.mouseOverLink(url)) }
        } else if overLink {
            _ = host?.perform(.mouseShape(terminal.mouseShape))
            _ = host?.perform(.mouseOverLink([]))
        }
    }

    /// Surface.processLinks: opens the link under the position; false: none, or opening failed.
    func openLink(at pos: (x: Float, y: Float)) -> Bool {
        guard let link = linkAt(pos) else { return false }
        if link.osc8 {
            guard let uri = osc8URI(link.selection.start) else { return false }
            return openURL(.osc8, uri)
        }
        let text = screen.selectionString(link.selection, trim: false)
        return openURL(.unknown, resolvedPath(text) ?? text)
    }

    /// Surface.openUrl: the host's action, else the system opener, which on macOS never opens OSC 8
    /// links (os/open.zig: a program could make them run anything).
    func openURL(_ kind: SurfaceAction.OpenKind, _ url: [UInt8]) -> Bool {
        guard host?.perform(.openURL(kind, url)) != true else { return true }
        guard kind != .osc8 else { return false }
        do { try host?.open(kind, url) } catch { return false }
        return true
    }

    /// Surface.resolvePathForOpening: a relative path against the terminal's working directory,
    /// when that file exists.
    func resolvedPath(_ path: [UInt8]) -> [UInt8]? {
        guard path.first != 0x2F, !terminal.pwd.isEmpty else { return nil }
        var parts: [ArraySlice<UInt8>] = []
        for p in (terminal.pwd + [0x2F] + path).split(separator: 0x2F) where p != [0x2E] {
            if p == [0x2E, 0x2E] { _ = parts.popLast() } else { parts.append(p) }
        }
        let resolved = [0x2F] + Array(parts.joined(separator: [0x2F]))
        return host?.exists(resolved) == true ? resolved : nil
    }
}

extension Surface {
    /// The link cells the renderer underlines (generic.zig updateFrame), as y * cols + x: with super
    /// held over an OSC 8 cell, every viewport cell of that hyperlink (RenderState.linkCells); and
    /// the regex links over the viewport text that the hover activates (link.Set.renderCellMap).
    public func drawLinks() -> Set<Int> {
        var cells = Set<Int>()
        guard let vp = hover.point else { return cells }
        let s = screen, cols = terminal.cols
        let rows = (0..<s.pages.rows).map { s.pages.pin(.viewport, x: 0, y: $0)! }
        let link = { (p: Pin, x: Int) -> Term.Link? in p.page.hyperlink(p.page.cellAt(p.y, x)).map { p.page.link(id: $0) } }
        if hover.mods == .super, vp.x < cols, vp.y < rows.count, let hovered = link(rows[vp.y], vp.x) {
            for (y, r) in rows.enumerated() { for x in 0..<cols where link(r, x) == hovered { cells.insert(y * cols + x) } }
        }
        let active = config.links.filter { $0.mods.map { $0 == hover.mods } ?? true }
        guard !active.isEmpty else { return cells }
        // RenderState.string: every cell's code point (NUL when empty) and graphemes, a newline after unwrapped rows.
        var text: [UInt32] = [], map: [(x: Int, y: Int)] = []
        for (y, r) in rows.enumerated() {
            for x in 0..<cols {
                let c = r.page.cell(r.page.cellAt(r.y, x))
                let cps = [c.codepoint] + (c.tag == .codepointGrapheme ? r.page.grapheme(r.page.cellAt(r.y, x)).map(Array.init) ?? [] : [])
                text += cps
                map += Array(repeating: (x, y), count: cps.count)
            }
            if !r.row.wrap { text.append(0x0A); map.append((cols, y)) }
        }
        for l in active {
            var at = 0
            while at < text.count, let m = l.regex.search(text, from: at) {
                guard !m.isEmpty else { at = max(at + 1, m.upperBound + 1); continue }
                let points = map[m]
                at = m.upperBound
                if points.contains(where: { $0 == vp }) { for p in points { cells.insert(p.y * cols + p.x) } }
            }
        }
        return cells
    }
}
