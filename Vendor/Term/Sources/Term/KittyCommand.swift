// Kitty graphics commands (kitty/graphics_command.zig): `key=value` controls (one-letter keys, a
// number or a single character), then `;` and a base64 payload. A value that isn't a number drops
// the whole command, like Ghostty's parser error.

/// The controls collected from a command's text.
struct KittyKV {
    var values: [UInt8: UInt32] = [:]
    subscript(_ k: Character) -> UInt32? { values[k.asciiValue!] }
    /// A key's value as the character it names (a=t, t=f, ...), nil when absent or wider than a byte.
    func char(_ k: Character) -> UInt8?? { self[k].map { $0 <= 0xFF ? UInt8($0) : nil } }
}

struct KittyParser {
    enum State { case key, keyIgnore, value, valueIgnore, data }
    static let maxBytes = 8 * 1024 * 1024
    var state = State.key, kv = KittyKV(), temp: [UInt8] = [], current: UInt8 = 0, data: [UInt8] = []

    /// False: an error (the command is dropped).
    mutating func feed<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        var rest = bytes[...]
        while let c = rest.first {
            if state == .data {
                guard data.count + rest.count <= KittyParser.maxBytes else { return false }
                data.append(contentsOf: rest)
                return true
            }
            rest = rest.dropFirst()
            switch (state, c) {
            case (.key, 0x3D): if temp.count == 1 { (current, state) = (temp[0], .value) } else { state = .valueIgnore }; temp = []
            case (.key, 0x3B): state = .data
            case (.key, _): accumulate(c, .keyIgnore)
            case (.keyIgnore, 0x3D): state = .valueIgnore
            case (.value, 0x2C): guard finish(.key) else { return false }
            case (.value, 0x3B): guard finish(.data) else { return false }
            case (.value, _): accumulate(c, .valueIgnore)
            case (.valueIgnore, 0x2C): state = .keyIgnore
            case (.valueIgnore, 0x3B): state = .data
            default: break
            }
        }
        return true
    }

    mutating func accumulate(_ c: UInt8, _ overflow: State) {
        if temp.count >= 11 { (state, temp) = (overflow, []) } else { temp.append(c) }
    }

    /// A value ends: one non-digit character is itself; anything else parses as a number (z, H
    /// and V signed).
    mutating func finish(_ next: State) -> Bool {
        state = next
        defer { temp = [] }
        let letter = (0x61...0x7A).contains(current) || (0x41...0x5A).contains(current)
        if temp.count == 1, !(0x30...0x39).contains(temp[0]) {
            if letter { kv.values[current] = UInt32(temp[0]) }
            return true
        }
        let v: UInt32?
        if [0x7A, 0x48, 0x56].contains(current) {
            let neg = temp.first == 0x2D
            let m = zigInt(neg ? temp.dropFirst() : temp[...], base: 10, max: neg ? 1 << 31 : (1 << 31) - 1, signed: !neg)
            v = m.map { UInt32(truncatingIfNeeded: neg ? -Int64($0) : Int64($0)) }
        } else {
            v = zigInt(temp, base: 10, max: UInt64(UInt32.max), signed: true).map(UInt32.init)
        }
        guard let v else { return false }
        if letter { kv.values[current] = v }
        return true
    }

    func complete() -> KittyCommand? {
        var p = self
        switch p.state {
        case .key, .keyIgnore: return nil
        case .value: guard p.finish(.data) else { return nil }
        default: break
        }
        guard let payload = p.data.isEmpty ? [] : Base64.decodeLoose(p.data) else { return nil }
        return KittyCommand(p.kv, data: payload)
    }
}

enum KittyQuiet { case no, ok, failures }

public enum KittyFormat: String {
    case rgb, rgba, png, grayAlpha = "gray_alpha", gray
    var bpp: Int { [.gray: 1, .grayAlpha: 2, .rgb: 3, .rgba: 4][self]! }
}

struct KittyTransmission {
    typealias Format = KittyFormat
    enum Medium { case direct, file, temporaryFile, sharedMemory }
    var format = Format.rgba, formatUnknown = false, medium = Medium.direct
    var width: UInt32 = 0, height: UInt32 = 0, size: UInt32 = 0, offset: UInt32 = 0, imageID: UInt32 = 0, imageNumber: UInt32 = 0, placementID: UInt32 = 0
    var zlib = false, moreChunks = false, transient = false

    init() {}
    init?(_ kv: KittyKV) {
        if let f = kv["f"] { switch f { case 24: format = .rgb; case 0, 32: format = .rgba; case 100: format = .png; default: formatUnknown = true } }
        if let t = kv.char("t") {
            switch t { case 0x64: medium = .direct; case 0x66: medium = .file; case 0x74: medium = .temporaryFile; case 0x73: medium = .sharedMemory; default: return nil }
        }
        (width, height, size, offset) = (kv["s"] ?? 0, kv["v"] ?? 0, kv["S"] ?? 0, kv["O"] ?? 0)
        (imageID, imageNumber, placementID) = (kv["i"] ?? 0, kv["I"] ?? 0, kv["p"] ?? 0)
        if let o = kv.char("o") { guard o == 0x7A else { return nil }; zlib = true }
        if medium == .direct, let m = kv["m"] { moreChunks = m > 0 }
        if let n = kv["N"] { transient = n & 1 != 0 }
    }
}

struct KittyDisplay {
    var imageID: UInt32 = 0, imageNumber: UInt32 = 0, placementID: UInt32 = 0, x: UInt32 = 0, y: UInt32 = 0, width: UInt32 = 0, height: UInt32 = 0
    var xOffset: UInt32 = 0, yOffset: UInt32 = 0, columns: UInt32 = 0, rows: UInt32 = 0, moveCursor = true, virtual = false
    var parentID: UInt32 = 0, parentPlacementID: UInt32 = 0, horizontalOffset: Int32 = 0, verticalOffset: Int32 = 0, z: Int32 = 0

    init(_ kv: KittyKV) {
        (imageID, imageNumber, placementID) = (kv["i"] ?? 0, kv["I"] ?? 0, kv["p"] ?? 0)
        (x, y, width, height, xOffset, yOffset, columns, rows) = (kv["x"] ?? 0, kv["y"] ?? 0, kv["w"] ?? 0, kv["h"] ?? 0, kv["X"] ?? 0, kv["Y"] ?? 0, kv["c"] ?? 0, kv["r"] ?? 0)
        if let c = kv["C"] { moveCursor = c != 1 }
        if let u = kv["U"] { virtual = u != 0 }
        z = Int32(bitPattern: kv["z"] ?? 0)
        (parentID, parentPlacementID) = (kv["P"] ?? 0, kv["Q"] ?? 0)
        (horizontalOffset, verticalOffset) = (Int32(bitPattern: kv["H"] ?? 0), Int32(bitPattern: kv["V"] ?? 0))
    }
}

struct KittyFrameLoad {
    var transmission: KittyTransmission, x: UInt32, y: UInt32, createFrame: UInt32, editFrame: UInt32, gap: Int32, overwrite: Bool
    /// Y: the background color, 0xRRGGBBAA.
    var background: UInt32
}

struct KittyCompose {
    var imageID: UInt32, imageNumber: UInt32, placementID: UInt32, destFrame: UInt32, sourceFrame: UInt32
    var x: UInt32, y: UInt32, width: UInt32, height: UInt32, leftEdge: UInt32, topEdge: UInt32, overwrite: Bool
}

struct KittyAnimationControl {
    enum Action { case invalid, stop, runWait, run }
    var imageID: UInt32, imageNumber: UInt32, placementID: UInt32, action: Action, frame: UInt32, gap: Int32, currentFrame: UInt32, loops: UInt32
}

struct KittyDelete {
    /// The `d` letter lowered, and whether it was uppercase (delete the images too).
    var what: UInt8, images: Bool
    var imageID: UInt32, imageNumber: UInt32, placementID: UInt32, x: UInt32, y: UInt32, z: Int32, frame: UInt32
}

struct KittyCommand {
    enum Control {
        case query(KittyTransmission), transmit(KittyTransmission), transmitAndDisplay(KittyTransmission, KittyDisplay), display(KittyDisplay)
        case delete(KittyDelete), frame(KittyFrameLoad), control(KittyAnimationControl), compose(KittyCompose)
    }
    var control: Control, quiet: KittyQuiet, data: [UInt8]

    init?(_ kv: KittyKV, data: [UInt8]) {
        guard let action = kv.char("a") ?? 0x74 else { return nil }
        func t() -> KittyTransmission? { KittyTransmission(kv) }
        switch action {
        case 0x71: guard let t = t() else { return nil }; control = .query(t)
        case 0x74: guard let t = t() else { return nil }; control = .transmit(t)
        case 0x54: guard let t = t() else { return nil }; control = .transmitAndDisplay(t, KittyDisplay(kv))
        case 0x70: control = .display(KittyDisplay(kv))
        case 0x64:
            guard let d = kv.char("d") ?? 0x61, let lower = Optional(d | 0x20), Array("aicnfpqrxyz".utf8).contains(lower), (0x41...0x5A).contains(d) || (0x61...0x7A).contains(d)
            else { return nil }
            control = .delete(KittyDelete(what: lower, images: d < 0x61, imageID: kv["i"] ?? 0, imageNumber: kv["I"] ?? 0, placementID: kv["p"] ?? 0,
                                          x: kv["x"] ?? 0, y: kv["y"] ?? 0, z: Int32(bitPattern: kv["z"] ?? 0), frame: kv["r"] ?? 0))
        case 0x66:
            guard let t = t() else { return nil }
            control = .frame(KittyFrameLoad(transmission: t, x: kv["x"] ?? 0, y: kv["y"] ?? 0, createFrame: kv["c"] ?? 0, editFrame: kv["r"] ?? 0,
                                            gap: Int32(bitPattern: kv["z"] ?? 0), overwrite: kv["X"] == 1, background: kv["Y"] ?? 0))
        case 0x61:
            let s: [UInt32: KittyAnimationControl.Action] = [1: .stop, 2: .runWait, 3: .run]
            control = .control(KittyAnimationControl(imageID: kv["i"] ?? 0, imageNumber: kv["I"] ?? 0, placementID: kv["p"] ?? 0, action: kv["s"].map { s[$0] ?? .invalid } ?? .invalid,
                                                     frame: kv["r"] ?? 0, gap: Int32(bitPattern: kv["z"] ?? 0), currentFrame: kv["c"] ?? 0, loops: kv["v"] ?? 0))
        case 0x63:
            control = .compose(KittyCompose(imageID: kv["i"] ?? 0, imageNumber: kv["I"] ?? 0, placementID: kv["p"] ?? 0, destFrame: kv["c"] ?? 0, sourceFrame: kv["r"] ?? 0,
                                            x: kv["x"] ?? 0, y: kv["y"] ?? 0, width: kv["w"] ?? 0, height: kv["h"] ?? 0, leftEdge: kv["X"] ?? 0, topEdge: kv["Y"] ?? 0,
                                            overwrite: kv["C"].map { $0 != 0 } ?? false))
        default: return nil
        }
        quiet = kv["q"].map { $0 == 0 ? .no : $0 == 1 ? .ok : .failures } ?? .no
        self.data = data
    }

    /// The image id, number and placement id the command names.
    var identifiers: (id: UInt32, number: UInt32, placement: UInt32) {
        switch control {
        case .query(let t), .transmit(let t), .transmitAndDisplay(let t, _): (t.imageID, t.imageNumber, t.placementID)
        case .frame(let f): (f.transmission.imageID, f.transmission.imageNumber, f.transmission.placementID)
        case .display(let d): (d.imageID, d.imageNumber, d.placementID)
        case .delete(let d): (d.imageID, d.imageNumber, d.placementID)
        case .control(let a): (a.imageID, a.imageNumber, a.placementID)
        case .compose(let c): (c.imageID, c.imageNumber, c.placementID)
        }
    }

    var transmission: KittyTransmission? {
        switch control {
        case .query(let t), .transmit(let t), .transmitAndDisplay(let t, _): t
        case .frame(let f): f.transmission
        default: nil
        }
    }
}

/// A reply (graphics_command.zig Response): none without an image id or number.
struct KittyResponse {
    var id: UInt32 = 0, number: UInt32 = 0, placement: UInt32 = 0, frame: UInt32 = 0, message = "OK"
    var ok: Bool { message == "OK" }
    var empty: Bool { id == 0 && number == 0 }
    var encoded: [UInt8] {
        if empty { return [] }
        let keys = [("i", id), ("I", number), ("p", placement), ("r", frame)].filter { $0.1 > 0 }
        return Array("\u{1B}_G\(keys.map { "\($0.0)=\($0.1)" }.joined(separator: ","));\(message)\u{1B}\\".utf8)
    }
}

extension Base64 {
    /// simdutf's base64_to_binary (Ghostty's simd.base64.decode): ASCII whitespace skipped,
    /// padding optional but at most two `=` and only at the end (then whole groups), a lone
    /// trailing character invalid, trailing bits ignored.
    static func decodeLoose(_ s: [UInt8]) -> [UInt8]? {
        let chars = s.filter { ![0x20, 0x09, 0x0A, 0x0C, 0x0D].contains($0) }
        let pad = chars.reversed().prefix { $0 == 0x3D }.count
        let body = chars.dropLast(pad)
        guard pad <= 2, !body.contains(0x3D), pad == 0 || chars.count % 4 == 0, body.count % 4 != 1 else { return nil }
        var (out, acc, bits) = ([UInt8](), UInt32(0), 0)
        out.reserveCapacity(body.count / 4 * 3 + 2)
        for c in body {
            guard let v = value(c) else { return nil }
            (acc, bits) = (acc << 6 | v, bits + 6)
            if bits >= 8 { bits -= 8; out.append(UInt8(truncatingIfNeeded: acc >> UInt32(bits))) }
        }
        return out
    }
}
