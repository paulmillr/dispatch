// OSC: a number prefix, then the payload after ';', parsed when the string
// ends. Follows Ghostty's osc.zig and osc/parsers/*.

public enum ColorOp: String {
    case osc4 = "osc_4", osc5 = "osc_5", osc10 = "osc_10", osc11 = "osc_11", osc12 = "osc_12", osc13 = "osc_13"
    case osc14 = "osc_14", osc15 = "osc_15", osc16 = "osc_16", osc17 = "osc_17", osc18 = "osc_18", osc19 = "osc_19"
    case osc104 = "osc_104", osc110 = "osc_110", osc111 = "osc_111", osc112 = "osc_112", osc113 = "osc_113"
    case osc114 = "osc_114", osc115 = "osc_115", osc116 = "osc_116", osc117 = "osc_117", osc118 = "osc_118", osc119 = "osc_119"
}
public enum SpecialColor: UInt16 { case bold, underline, blink, reverse, italic }
public enum DynamicColor: UInt16 {
    case foreground = 10, background, cursor, pointerForeground, pointerBackground, tektronixForeground
    case tektronixBackground, highlightBackground, tektronixCursor, highlightForeground
}
public enum ColorTarget { case palette(UInt8), special(SpecialColor), dynamic(DynamicColor) }
public struct ColoredTarget { public var target: ColorTarget, color: RGB }
public enum ColorRequest { case set(ColoredTarget), query(ColorTarget), reset(ColorTarget), resetPalette, resetSpecial }
public struct ColorOperation { public var op: ColorOp, requests: [ColorRequest], terminator: Terminator }

public enum KittySpecial { case foreground, background, selectionForeground, selectionBackground, cursor, cursorText, visualBell, secondTransparentBackground }
public enum KittyKind { case palette(UInt8), special(KittySpecial) }
public struct KittySet { public var key: KittyKind, color: RGB }
public enum KittyRequest { case query(KittyKind), set(KittySet), reset(KittyKind) }
public struct KittyColor { public var list: [KittyRequest], terminator: Terminator }

public enum SemanticAction: Character {
    case freshLine = "L", freshLineNewPrompt = "A", newCommand = "N", promptStart = "P"
    case endPromptStartInput = "B", endPromptStartInputTerminateEol = "I", endInputStartOutput = "C", endCommand = "D"
}
public struct SemanticPrompt { public var action: SemanticAction, optionsUnvalidated: [UInt8] }

struct OSCParser {
    var number: [UInt8] = [], payload: [UInt8]? = nil, invalid = false

    /// Every prefix Ghostty's state machine knows, with its capture limit
    /// (0 = no payload allowed; 8 MiB numbers use an allocating capture).
    static let limits: [String: Int] = {
        var m: [String: Int] = ["3": 0, "30": 0, "300": 0, "6": 0, "55": 0, "552": 0, "77": 0]
        for n in ["0", "1", "2", "4", "5", "7", "8", "9", "21", "22", "104", "133", "777", "1337", "3008"] { m[n] = 2048 }
        for n in 10...19 { m[String(n)] = 2048 }
        for n in 110...119 { m[String(n)] = 2048 }
        for n in ["52", "66", "72", "99", "5522"] { m[n] = 8 << 20 }
        // Program status (not Ghostty's): its prefixes, and the whole sequence is at most 4096 bytes (ESC ] 7501 ; body BEL).
        (m["75"], m["750"], m["7501"]) = (0, 0, ProgramStatusCommand.sequenceLimit - 8)
        return m
    }()

    var key: String { String(decoding: number, as: UTF8.self) }

    mutating func reset() { number.removeAll(keepingCapacity: true); payload = nil; invalid = false }

    mutating func next(_ c: UInt8) {
        if invalid { return }
        if payload != nil {
            if payload!.count >= OSCParser.limits[key]! { invalid = true } else { payload!.append(c) }
            return
        }
        if c == 0x3B, (OSCParser.limits[key] ?? 0) > 0 { payload = []; return }
        number.append(c)
        if !(0x30...0x39).contains(c) || OSCParser.limits[key] == nil { invalid = true }
    }

    /// Parsers that NUL-terminate their capture fail when it is full.
    var terminated: [UInt8]? {
        guard let p = payload, p.count < OSCParser.limits[key]! else { return nil }
        return p
    }

    mutating func end(_ c: UInt8) -> Action? {
        if invalid || number.isEmpty { return nil }
        let t: Terminator = c == 0x07 ? .bel : .st
        let k = key
        if let op = ColorOp(rawValue: "osc_" + k) { return .colorOperation(ColorOperation(op: op, requests: colors(op, payload ?? []), terminator: t)) }
        switch k {
        case "0", "2": return terminated.flatMap { Decoder.decode($0) != nil ? .windowTitle(Title(title: $0)) : nil }
        case "7": return terminated.map { .reportPwd(Pwd(url: $0)) }
        case "8": return terminated.flatMap(hyperlink)
        case "9": return payload.flatMap { osc9($0) }
        case "21": return payload.flatMap { kittyColor($0, t) }
        case "22": return terminated.flatMap { s in mouseShapeStrings.first { Array($0.0.utf8) == s }.map { .mouseShape(MouseShape(index: $0.1)) } }
        case "52": return terminated.flatMap { clipboard($0, t) }
        case "133": return payload.flatMap(semanticPrompt)
        case "777": return terminated.flatMap(notify)
        case "1337": return terminated.flatMap(iterm2)
        case "7501": return ProgramStatusCommand.parse(payload ?? [], t).map { .programStatus($0) }
        case "5522", "72":
            guard let p = payload else { return nil }
            let i = p.firstIndex(of: 0x3B)
            let s = KittyString(metadata: Array(p[..<(i ?? p.endIndex)]), payload: i.map { Array(p[($0 + 1)...]) }, terminator: t)
            return k == "72" ? .kittyDnd(s) : .kittyClipboard(s)
        default: return nil
        }
    }

    // osc/parsers/hyperlink.zig: "params;uri", params are ':'-separated k=v.
    func hyperlink(_ d: [UInt8]) -> Action? {
        guard let s = d.firstIndex(of: 0x3B) else { return nil }
        let uri = Array(d[(s + 1)...])
        var id: [UInt8]? = nil
        let kvs = d[..<s].map { $0 == 0x3A ? 0 : $0 } + [0]
        var start = 0
        while start < kvs.count, let end = kvs[(start + 1)...].firstIndex(of: 0) {
            let kv = kvs[start..<end]
            guard let v = kv.firstIndex(of: 0x3D) else { break }
            if Array(kv[..<v]) == Array("id".utf8), v + 1 < end { id = Array(kv[(v + 1)...]) }
            start = end + 1
        }
        if uri.isEmpty { return id == nil ? .endHyperlink : nil }
        return .startHyperlink(Hyperlink(uri: uri, id: id))
    }

    // osc/parsers/osc9.zig: ConEmu commands (dropped by the stream), progress,
    // pwd, else a desktop notification with the whole payload as body.
    func osc9(_ d: [UInt8]) -> Action? {
        let semi = d.count > 1 && d[1] == 0x3B
        switch d.first {
        case 0x31 where d.count >= 2:
            switch d[1] {
            case 0x3B: return nil
            case 0x30 where d.count == 2 || (d.count >= 4 && d[2] == 0x3B && (0x30...0x33).contains(d[3])): return nil
            case 0x31 where d.count >= 3 && d[2] == 0x3B: return nil
            case 0x32: return .semanticPrompt(SemanticPrompt(action: .freshLineNewPrompt, optionsUnvalidated: []))
            default: break
            }
        case 0x32, 0x33, 0x36, 0x37, 0x38: if semi { return nil }
        case 0x35: return nil
        case 0x34 where semi && d.count >= 3 && (0x30...0x34).contains(d[2]):
            let states: [Progress.State] = [.remove, .set, .error, .indeterminate, .pause]
            let state = states[Int(d[2] - 0x30)]
            var progress: UInt8? = state == .set ? 0 : nil
            if state != .remove && state != .indeterminate, d.count >= 4, d[3] == 0x3B {
                progress = zigInt(d[4...], base: 10, max: UInt64.max).map { UInt8(min($0, 100)) }
            }
            return .progressReport(Progress(state: state, progress: progress))
        case 0x39 where semi: return terminated.map { .reportPwd(Pwd(url: Array($0[2...]))) }
        default: break
        }
        return terminated.map { .showDesktopNotification(Notification(title: [], body: $0)) }
    }

    // osc/parsers/rxvt_extension.zig: "notify;title;body".
    func notify(_ d: [UInt8]) -> Action? {
        guard let k = d.firstIndex(of: 0x3B), Array(d[..<k]) == Array("notify".utf8),
              let t = d[(k + 1)...].firstIndex(of: 0x3B) else { return nil }
        return .showDesktopNotification(Notification(title: Array(d[(k + 1)..<t]), body: Array(d[(t + 1)...])))
    }

    // osc/parsers/clipboard_operation.zig: "kind;data" or ";data".
    func clipboard(_ d: [UInt8], _ t: Terminator) -> Action? {
        if d.first == 0x3B { return .clipboardContents(Clipboard(kind: 0x63, data: Array(d[1...]), terminator: t)) }
        guard d.count >= 2, d[1] == 0x3B else { return nil }
        return .clipboardContents(Clipboard(kind: d[0], data: Array(d[2...]), terminator: t))
    }

    // osc/parsers/iterm2.zig: only Copy and CurrentDir reach the terminal.
    func iterm2(_ d: [UInt8]) -> Action? {
        let e = d.firstIndex(of: 0x3D)
        let key = String(decoding: d[..<(e ?? d.endIndex)], as: UTF8.self)
        guard let e else { return nil }
        let v = Array(d[(e + 1)...])
        if key == "Copy", v.first == 0x3A, v.count > 1, v != [0x3A, 0x3F] { return .clipboardContents(Clipboard(kind: 0x63, data: Array(v[1...]), terminator: .st)) }
        if key == "CurrentDir", !v.isEmpty { return .reportPwd(Pwd(url: v)) }
        return nil
    }

    // osc/parsers/semantic_prompt.zig: one letter, then optional ";options".
    func semanticPrompt(_ d: [UInt8]) -> Action? {
        guard let first = d.first, let action = SemanticAction(rawValue: Character(UnicodeScalar(first))) else { return nil }
        if d.count == 1 { return .semanticPrompt(SemanticPrompt(action: action, optionsUnvalidated: [])) }
        guard action != .freshLine, d[1] == 0x3B else { return nil }
        return .semanticPrompt(SemanticPrompt(action: action, optionsUnvalidated: Array(d[2...])))
    }

    // kitty/color.zig + osc/parsers/kitty_color.zig: "key=value;..." requests.
    func kittyColor(_ d: [UInt8], _ t: Terminator) -> Action? {
        let names: [String: KittySpecial] = ["foreground": .foreground, "background": .background, "selection_foreground": .selectionForeground,
            "selection_background": .selectionBackground, "cursor": .cursor, "cursor_text": .cursorText, "visual_bell": .visualBell,
            "second_transparent_background": .secondTransparentBackground]
        var list: [KittyRequest] = []
        for kv in d.split(separator: 0x3B, omittingEmptySubsequences: false) {
            if list.count >= (255 + 8) * 2 { return nil }
            let eq = kv.firstIndex(of: 0x3D)
            let k = kv[..<(eq ?? kv.endIndex)]
            guard !k.isEmpty else { continue }
            let key: KittyKind
            if let s = names[String(decoding: k, as: UTF8.self)] { key = .special(s) }
            else if let n = zigInt(k, base: 10, max: 255) { key = .palette(UInt8(n)) } else { continue }
            let value = trim(eq.map { kv[($0 + 1)...] } ?? [], " ")
            if value.isEmpty { list.append(.reset(key)) }
            else if value.elementsEqual([0x3F]) { list.append(.query(key)) }
            else if let c = parseRGB(value) { list.append(.set(KittySet(key: key, color: c))) }
        }
        return .kittyColorReport(KittyColor(list: list, terminator: t))
    }

    // osc/parsers/color.zig: palette/special/dynamic get, set and reset.
    func colors(_ op: ColorOp, _ d: [UInt8]) -> [ColorRequest] {
        var it = d.split(separator: 0x3B).makeIterator()
        var out: [ColorRequest] = []
        func target(_ n: UInt64, special: Bool) -> ColorTarget? {
            if !special && n < 256 { return .palette(UInt8(n)) }
            let s = special ? n : n - 256
            return s < 8 ? SpecialColor(rawValue: UInt16(s)).map { .special($0) } : nil
        }
        switch op {
        case .osc4, .osc5:
            while let n = it.next(), let spec = it.next() {
                guard let v = zigInt(n, base: 10, max: 511, signed: true), let t = target(v, special: op == .osc5) else { break }
                if spec.elementsEqual([0x3F]) { out.append(.query(t)) } else if let c = parseRGB(spec) { out.append(.set(ColoredTarget(target: t, color: c))) } else { break }
            }
        case .osc104:
            while let n = it.next() {
                if let v = zigInt(n, base: 10, max: 511, signed: true), let t = target(v, special: false) { out.append(.reset(t)) }
            }
            if out.isEmpty { out.append(.resetPalette) }
        default:
            let first = UInt16(op.rawValue.dropFirst(4))!
            if first >= 110 { return it.next() == nil ? [.reset(.dynamic(DynamicColor(rawValue: first - 100)!))] : [] }
            var color = DynamicColor(rawValue: first)
            while let c = color, let spec = it.next() {
                if spec.elementsEqual([0x3F]) { out.append(.query(.dynamic(c))) } else if let v = parseRGB(spec) { out.append(.set(ColoredTarget(target: .dynamic(c), color: v))) } else { break }
                color = DynamicColor(rawValue: c.rawValue + 1)
            }
        }
        return out
    }
}

/// Zig's std.fmt.parseUnsigned: digits of `base` with `_` separators
/// allowed except first and last; nil on empty input or overflow past `max`.
/// `signed` is Zig's parseInt into an unsigned type: '+' is allowed, and
/// '-' only for a zero value.
func zigInt<S: Collection>(_ s: S, base: UInt64, max: UInt64, signed: Bool = false) -> UInt64? where S.Element == UInt8 {
    if signed, let sign = s.first, sign == 0x2B || sign == 0x2D {
        let v = zigInt(s.dropFirst(), base: base, max: max)
        return sign == 0x2D && v != 0 ? nil : v
    }
    guard let first = s.first, first != 0x5F, s.reversed().first != 0x5F else { return nil }
    var v: UInt64 = 0
    for c in s where c != 0x5F {
        let d: UInt64
        switch c {
        case 0x30...0x39: d = UInt64(c - 0x30)
        case 0x61...0x7A: d = UInt64(c - 0x61 + 10)
        case 0x41...0x5A: d = UInt64(c - 0x41 + 10)
        default: return nil
        }
        guard d < base else { return nil }
        let (m, o1) = v.multipliedReportingOverflow(by: base)
        let (a, o2) = m.addingReportingOverflow(d)
        guard !o1, !o2, a <= max else { return nil }
        v = a
    }
    return v
}

func trim<S: Collection>(_ s: S, _ chars: String) -> ArraySlice<UInt8> where S.Element == UInt8 {
    let a = Array(s), set = Set(chars.utf8)
    guard let lo = a.firstIndex(where: { !set.contains($0) }) else { return [] }
    return a[lo...a.lastIndex(where: { !set.contains($0) })!]
}

/// ASCII letters lowered (X11 names match ignoring ASCII case).
func asciiLowercased<S: Sequence>(_ s: S) -> String where S.Element == UInt8 {
    String(decoding: s.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
}

/// X11 color names by lowercase name, read from rgb.txt at first use as x11_color.zig does
/// (\r trimmed, fixed columns for the numbers, the name trimmed of spaces and tabs).
@_spi(Test) public let x11Colors: [String: (UInt8, UInt8, UInt8)] = x11Text.utf8.split(separator: 0x0A).reduce(into: [:]) { colors, raw in
    let line = raw.last == 0x0D ? raw.dropLast() : raw
    let n = { (i: Int) in line.dropFirst(i).prefix(3).reduce(UInt8(0)) { $1 == 0x20 ? $0 : $0 &* 10 &+ ($1 &- 0x30) } }
    colors[asciiLowercased(trim(line.dropFirst(12), " \t"))] = (n(0), n(4), n(8))
}

/// color.zig RGB.parse: #rgb forms, X11 names (case-insensitive), bare hex, rgb:/rgbi:.
func parseRGB<S: Collection>(_ value: S) -> RGB? where S.Element == UInt8 {
    let s = trim(value, " \t")
    guard !s.isEmpty else { return nil }
    /// color.zig fromHex: 1-4 hex digits scaled to 0-255.
    func hex(_ h: ArraySlice<UInt8>) -> UInt8? {
        guard (1...4).contains(h.count), let v = zigInt(h, base: 16, max: 0xFFFF) else { return nil }
        return UInt8(v * 255 / ((1 << (4 * UInt64(h.count))) - 1))
    }
    func split(_ at: [Int]) -> RGB? {
        let b = s.startIndex
        guard let r = hex(s[(b + at[0])..<(b + at[1])]), let g = hex(s[(b + at[1])..<(b + at[2])]), let bl = hex(s[(b + at[2])..<(b + at[3])]) else { return nil }
        return RGB(r: r, g: g, b: bl)
    }
    if s.first == 0x23 {
        let n = (s.count - 1) / 3
        guard [4, 7, 10, 13].contains(s.count) else { return nil }
        return split([1, 1 + n, 1 + 2 * n, 1 + 3 * n])
    }
    if let c = x11Colors[asciiLowercased(s)] { return RGB(r: c.0, g: c.1, b: c.2) }
    if s.count == 3 { return split([0, 1, 2, 3]) }
    if s.count == 6 { return split([0, 2, 4, 6]) }
    guard s.count >= 9, s.prefix(3).elementsEqual("rgb".utf8) else { return nil }
    var rest = s.dropFirst(3)
    let intensity = rest.first == 0x69
    if intensity { rest = rest.dropFirst() }
    guard rest.first == 0x3A else { return nil }
    let parts = rest.dropFirst().split(separator: 0x2F, maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    let v = parts.map { intensity ? fraction($0).map { UInt8($0 * 255) } : hex(ArraySlice($0)) }
    guard let r = v[0], let g = v[1], let b = v[2] else { return nil }
    return RGB(r: r, g: g, b: b)
}

/// fraction.zig parse: optional sign, digits, optional '.digits'; must be 0...1.
func fraction<S: Collection>(_ s: S) -> Double? where S.Element == UInt8 {
    var v = Array(s), negative = false
    if v.first == 0x2B { v.removeFirst() } else if v.first == 0x2D { negative = true; v.removeFirst() }
    let dot = v.firstIndex(of: 0x2E) ?? v.count
    var int = 0.0, frac: UInt64 = 0, scale: UInt64 = 1
    for d in v[..<dot] { guard (0x30...0x39).contains(d) else { return nil }; int = int * 10 + Double(d - 0x30) }
    for d in v[min(dot + 1, v.count)...] {
        guard (0x30...0x39).contains(d) else { return nil }
        if scale < 1_000_000_000_000_000_000 / 1000 { frac = frac * 10 + UInt64(d - 0x30); scale *= 10 }
    }
    guard v.count - (dot < v.count ? 1 : 0) > 0 else { return nil }
    let r = (int + Double(frac) / Double(scale)) * (negative ? -1 : 1)
    return r >= 0 && r <= 1 ? r : nil
}

extension Decoder {
    /// Zig's Utf8View: the code points, or nil when a byte needs replacement (utf8ValidateSlice).
    static func decode(_ bytes: [UInt8]) -> [UInt32]? {
        var (d, cps) = (Decoder(), [UInt32]())
        for b in bytes { let (a, c) = d.next(b); cps += [a, c].compactMap { $0 } }
        return d.rejected || d.pending > 0 ? nil : cps
    }
}
