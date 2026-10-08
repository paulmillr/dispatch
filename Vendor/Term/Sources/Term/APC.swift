// APC strings (terminal/apc.zig): the first bytes name the protocol (kitty graphics `G`, the glyph
// protocol `25a1;`); its bytes collect up to the protocol's limit (past it: ignored whole) and
// become a command at the end. Other APC strings are ignored.

struct APC {
    enum State { case inactive, ignore, identify([UInt8]), kitty(KittyParser), glyph([UInt8]) }
    /// A finished string.
    enum Command { case kitty(KittyCommand), glyph(GlyphRequest) }

    static let glyphMax = 1024 * 1024, glyphID = Array("25a1".utf8)
    var state = State.inactive
    var kittyEnabled = true

    mutating func start(kitty: Bool = true) { (state, kittyEnabled) = (.identify([]), kitty) }

    mutating func feed<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        var rest = bytes[...]
        while let b = rest.first {
            switch state {
            case .inactive, .ignore: return
            case .identify(var id):
                rest = rest.dropFirst()
                if id.isEmpty, b == 0x47 { state = kittyEnabled ? .kitty(KittyParser()) : .ignore; continue }
                if b == 0x3B { state = id == APC.glyphID ? .glyph([]) : .ignore; continue }
                id.append(b)
                state = id.count > APC.glyphID.count ? .ignore : .identify(id)
            case .glyph(var data):
                state = .ignore
                guard data.count + rest.count <= APC.glyphMax else { return }
                data.append(contentsOf: rest)
                state = .glyph(data)
                return
            case .kitty(var p):
                state = .ignore
                guard p.feed(rest) else { return }
                state = .kitty(p)
                return
            }
        }
    }

    mutating func end() -> Command? {
        defer { state = .inactive }
        switch state {
        case .glyph(var data):
            if data.count == 1 { data.append(0x3B) }
            return GlyphRequest(data).map { .glyph($0) }
        case .kitty(let p): return p.complete().map { .kitty($0) }
        default: return nil
        }
    }
}
