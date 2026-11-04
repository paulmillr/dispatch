import Foundation

/// What a binary file is, from its first bytes (and, for a zip, its last): "ELF 64-bit LSB pie executable, x86-64",
/// "Mach-O universal (x86_64, arm64)", "SQLite 3 database, 4,096-byte pages", "zip archive, 12 entries". Both Files
/// previews show it beside the size. Pure: every read is bounds-checked, so a truncated or hostile header names less,
/// never traps. Nil when nothing matches.
enum FileFormat {
    /// The tail `describe` looks in for a zip's end-of-central-directory record: the record and its longest comment.
    static let tailLength: UInt64 = 22 + 65_535

    /// The format reads its entry count from the end of the file: worth a read of `tailLength` there.
    static func wantsTail(_ head: Data) -> Bool {
        Bytes(head).starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    static func describe(_ head: Data, tail: Data? = nil) -> String? {
        let b = Bytes(head)
        for describe in [executable, archive, media, data] {
            if let found = describe(b, tail.map(Bytes.init)) { return found }
        }
        return nil
    }

    // MARK: Executables

    private static func executable(_ b: Bytes, _ tail: Bytes?) -> String? {
        if b.starts(with: [0x7F, 0x45, 0x4C, 0x46]) { return elf(b) }
        if let thin = machO(b) { return thin }
        if b.starts(with: [0xCA, 0xFE, 0xBA, 0xBE]) || b.starts(with: [0xCA, 0xFE, 0xBA, 0xBF]) { return fat(b) }
        if b.starts(with: [0x4D, 0x5A]) { return pe(b) }
        if b.starts(with: [0x00, 0x61, 0x73, 0x6D]), let version = b.u32(4, big: false) {
            return "WebAssembly module, version \(version)"
        }
        if b.starts(with: [0x42, 0x43, 0xC0, 0xDE]) || b.starts(with: [0xDE, 0xC0, 0x17, 0x0B]) { return "LLVM bitcode" }
        if b.starts(with: Array("dex\n".utf8)), let version = b.ascii(4, 3) { return "Android Dalvik executable, version \(version)" }
        return nil
    }

    private static func elf(_ b: Bytes) -> String {
        guard let width = b[4], let order = b[5], width == 1 || width == 2, order == 1 || order == 2 else { return "ELF" }
        let wide = width == 2, big = order == 2
        var parts = ["ELF \(wide ? 64 : 32)-bit \(big ? "MSB" : "LSB")"]
        switch b.u16(16, big: big) {
        case 1: parts.append("relocatable")
        case 2: parts.append("executable")
        case 3: parts.append(elfInterpreted(b, wide: wide, big: big) ? "pie executable" : "shared object")
        case 4: parts.append("core file")
        default: break
        }
        var text = parts.joined(separator: " ")
        if let machine = b.u16(18, big: big).flatMap({ elfMachines[$0] }) { text += ", " + machine }
        return text
    }

    /// An ET_DYN with a program interpreter is a position-independent executable, as `file` tells them apart.
    private static func elfInterpreted(_ b: Bytes, wide: Bool, big: Bool) -> Bool {
        let table = wide ? b.u64(32, big: big) : b.u32(28, big: big).map(UInt64.init)
        guard let table, let size = b.u16(wide ? 54 : 42, big: big), let count = b.u16(wide ? 56 : 44, big: big),
              size >= 4, table < UInt64(b.count) else { return false }
        for index in 0..<Int(min(count, 256)) {
            let entry = Int(table) + index * Int(size)
            guard let type = b.u32(entry, big: big) else { return false }
            if type == 3 { return true }
        }
        return false
    }

    private static let elfMachines: [UInt16: String] = [
        2: "SPARC", 3: "x86", 8: "MIPS", 20: "PowerPC", 21: "PowerPC64", 22: "S/390", 40: "ARM", 43: "SPARC V9",
        62: "x86-64", 183: "arm64", 243: "RISC-V", 247: "BPF", 258: "LoongArch",
    ]

    private static func machO(_ b: Bytes) -> String? {
        let header: (wide: Bool, big: Bool)
        switch b.u32(0, big: true) {
        case 0xCEFA_EDFE: header = (false, false)
        case 0xCFFA_EDFE: header = (true, false)
        case 0xFEED_FACE: header = (false, true)
        case 0xFEED_FACF: header = (true, true)
        default: return nil
        }
        var text = "Mach-O \(header.wide ? 64 : 32)-bit"
        switch b.u32(12, big: header.big) {
        case 1: text += " object"
        case 2: text += " executable"
        case 4: text += " core"
        case 6: text += " dynamic library"
        case 7: text += " dynamic linker"
        case 8: text += " bundle"
        case 10: text += " debug symbols"
        case 11: text += " kernel extension"
        default: break
        }
        if let cpu = b.u32(4, big: header.big), let name = cpuName(cpu, sub: b.u32(8, big: header.big) ?? 0) {
            text += ", " + name
        }
        return text
    }

    /// A universal binary, or a Java class (the same magic): `file`'s rule, a count under 20 is architectures.
    private static func fat(_ b: Bytes) -> String? {
        guard let count = b.u32(4, big: true) else { return nil }
        if count == 0 || count >= 20 {
            guard let major = b.u16(6, big: true), major >= 45 else { return nil }
            return "Java class, Java " + (major >= 49 ? "\(major - 44)" : "1.\(major - 44)")
        }
        let stride = b[3] == 0xBF ? 32 : 20
        let names = (0..<Int(count)).compactMap { index -> String? in
            let entry = 8 + index * stride
            guard let cpu = b.u32(entry, big: true) else { return nil }
            return cpuName(cpu, sub: b.u32(entry + 4, big: true) ?? 0) ?? String(format: "cpu 0x%x", cpu)
        }
        return names.isEmpty ? "Mach-O universal" : "Mach-O universal (\(names.joined(separator: ", ")))"
    }

    private static func cpuName(_ cpu: UInt32, sub: UInt32) -> String? {
        switch cpu {
        case 7: "i386"
        case 0x0100_0007: "x86_64"
        case 12: "arm"
        case 0x0100_000C: sub & 0xFF == 2 ? "arm64e" : "arm64"
        case 0x0200_000C: "arm64_32"
        case 18: "ppc"
        case 0x0100_0012: "ppc64"
        default: nil
        }
    }

    private static func pe(_ b: Bytes) -> String {
        guard let header = b.u32(0x3C, big: false).map(Int.init), header < b.count,
              b.starts(with: [0x50, 0x45, 0, 0], at: header) else { return "DOS executable" }
        let flags = b.u16(header + 22, big: false) ?? 0
        let optional = header + 24
        var text = switch b.u16(optional, big: false) {
        case 0x20B: "PE32+"
        case 0x10B: "PE32"
        default: "PE"
        }
        text += flags & 0x2000 != 0 ? " DLL" : " executable"
        if let subsystem = b.u16(optional + 68, big: false) {
            switch subsystem {
            case 2: text += " (GUI)"
            case 3: text += " (console)"
            case 10, 11, 12: text += " (EFI)"
            default: break
            }
        }
        let machines: [UInt16: String] = [0x14C: "x86", 0x8664: "x86-64", 0xAA64: "arm64", 0x1C0: "ARM", 0x1C4: "ARM Thumb-2"]
        if let machine = b.u16(header + 4, big: false).flatMap({ machines[$0] }) { text += ", " + machine }
        return text
    }

    // MARK: Archives and compression

    private static func archive(_ b: Bytes, _ tail: Bytes?) -> String? {
        if b.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return zip(b, tail) }
        if b.starts(with: [0x50, 0x4B, 0x05, 0x06]) { return "zip archive, empty" }
        if b.starts(with: [0x1F, 0x8B]) { return gzip(b) }
        if b.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return "xz compressed data" }
        if b.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { return "Zstandard compressed data" }
        if b.starts(with: [0x42, 0x5A, 0x68]), let level = b[3], (0x31...0x39).contains(level) { return "bzip2 compressed data" }
        if b.starts(with: [0x04, 0x22, 0x4D, 0x18]) { return "LZ4 compressed data" }
        if b.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return "7-zip archive" }
        if b.starts(with: Array("Rar!\u{1A}\u{07}".utf8)) { return "RAR archive" }
        if b.starts(with: Array("xar!".utf8)) { return "xar archive" }
        if b.starts(with: Array("MSCF".utf8)) { return "Microsoft Cabinet archive" }
        if b.starts(with: Array("!<arch>\n".utf8)) {
            return b.ascii(8, 13) == "debian-binary" ? "Debian package" : "ar archive"
        }
        if b.starts(with: Array("ustar".utf8), at: 257) { return "tar archive" }
        if b.starts(with: Array("PACK".utf8)), let version = b.u32(4, big: true), let objects = b.u32(8, big: true) {
            return "git pack, version \(version), \(grouped(objects)) objects"
        }
        if b.starts(with: Array("DIRC".utf8)), let version = b.u32(4, big: true), let entries = b.u32(8, big: true) {
            return "git index, version \(version), \(grouped(entries)) entries"
        }
        return nil
    }

    private static func zip(_ b: Bytes, _ tail: Bytes?) -> String {
        // The first entry's name says what the zip is for.
        var kind = "zip archive"
        if let length = b.u16(26, big: false), let name = b.ascii(30, Int(length)) {
            if name == "[Content_Types].xml" { kind = "Office Open XML document (zip)" }
            else if name == "mimetype", let extra = b.u16(28, big: false), let stored = b.u32(18, big: false),
                    stored > 0, stored <= 64, let type = b.ascii(30 + Int(length) + Int(extra), Int(stored)) {
                kind = "zip archive (\(type))"
            }
            else if name.hasPrefix("META-INF/") { kind = "Java archive (zip)" }
            else if name == "AndroidManifest.xml" { kind = "Android package (zip)" }
        }
        // The end-of-central-directory record: the last "PK\5\6" whose comment length reaches the end exactly.
        guard let tail, tail.count >= 22 else { return kind }
        var index = tail.count - 22
        while index >= 0 {
            if tail.starts(with: [0x50, 0x4B, 0x05, 0x06], at: index),
               let comment = tail.u16(index + 20, big: false), index + 22 + Int(comment) == tail.count,
               let entries = tail.u16(index + 10, big: false) {
                return entries == 0xFFFF ? kind + ", zip64" : kind + ", \(grouped(UInt32(entries))) \(entries == 1 ? "entry" : "entries")"
            }
            index -= 1
        }
        return kind
    }

    private static func gzip(_ b: Bytes) -> String {
        guard let flags = b[3] else { return "gzip compressed data" }
        var index = 10
        if flags & 0x04 != 0 {
            guard let extra = b.u16(10, big: false) else { return "gzip compressed data" }
            index += 2 + Int(extra)
        }
        guard flags & 0x08 != 0 else { return "gzip compressed data" }
        // The original name, NUL-terminated, in Latin-1 per RFC 1952; at most 100 characters shown.
        var name = ""
        while let byte = b[index], byte != 0, name.count < 100 {
            name.unicodeScalars.append(UnicodeScalar(byte))
            index += 1
        }
        return name.isEmpty ? "gzip compressed data" : "gzip compressed data, was \u{201C}\(name)\u{201D}"
    }

    // MARK: Media

    private static func media(_ b: Bytes, _ tail: Bytes?) -> String? {
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            guard let width = b.u32(16, big: true), let height = b.u32(20, big: true), let depth = b[24],
                  let type = b[25] else { return "PNG image" }
            let colours: [UInt8: String] = [0: "grayscale", 2: "RGB", 3: "indexed", 4: "grayscale + alpha", 6: "RGBA"]
            return "PNG image, \(width) × \(height), \(depth)-bit \(colours[type] ?? "colour")"
        }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) {
            return jpegSize(b).map { "JPEG image, \($0.width) × \($0.height)" } ?? "JPEG image"
        }
        if b.starts(with: Array("GIF8".utf8)), let width = b.u16(6, big: false), let height = b.u16(8, big: false) {
            return "GIF image, \(width) × \(height)"
        }
        if b.starts(with: Array("RIFF".utf8)) {
            switch b.ascii(8, 4) {
            case "WEBP": return "WebP image"
            case "WAVE": return "WAVE audio"
            case "AVI ": return "AVI video"
            default: return "RIFF data"
            }
        }
        if b.starts(with: Array("ftyp".utf8), at: 4), let brand = b.ascii(8, 4) {
            let brands: [String: String] = [
                "qt  ": "QuickTime movie", "M4A ": "MPEG-4 audio", "M4V ": "MPEG-4 video", "heic": "HEIF image",
                "heix": "HEIF image", "mif1": "HEIF image", "avif": "AVIF image", "crx ": "Canon raw image",
            ]
            return brands[brand] ?? "MPEG-4 (\(brand.trimmingCharacters(in: .whitespaces)))"
        }
        if b.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "Matroska/WebM video" }
        if b.starts(with: Array("ID3".utf8)), let major = b[3] { return "MP3 audio (ID3v2.\(major))" }
        if b.starts(with: Array("fLaC".utf8)) { return "FLAC audio" }
        if b.starts(with: Array("OggS".utf8)) { return "Ogg data" }
        if b.starts(with: Array("%PDF-".utf8)) {
            let version = b.ascii(5, 8)?.prefix { $0.isNumber || $0 == "." } ?? ""
            return version.isEmpty ? "PDF document" : "PDF document, version \(version)"
        }
        if b.starts(with: Array("OTTO".utf8)) { return "OpenType font" }
        if b.starts(with: Array("wOFF".utf8)) { return "WOFF font" }
        if b.starts(with: Array("wOF2".utf8)) { return "WOFF2 font" }
        if b.starts(with: Array("ttcf".utf8)) { return "TrueType font collection" }
        return nil
    }

    /// The first start-of-frame's size, walking the segments the head holds.
    private static func jpegSize(_ b: Bytes) -> (width: UInt16, height: UInt16)? {
        var index = 2
        while index + 4 <= b.count, b[index] == 0xFF {
            guard let marker = b[index + 1], let length = b.u16(index + 2, big: true), length >= 2 else { return nil }
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard let height = b.u16(index + 5, big: true), let width = b.u16(index + 7, big: true) else { return nil }
                return (width, height)
            }
            index += 2 + Int(length)
        }
        return nil
    }

    // MARK: Data

    private static func data(_ b: Bytes, _ tail: Bytes?) -> String? {
        if b.starts(with: Array("SQLite format 3\0".utf8)) {
            guard let raw = b.u16(16, big: true) else { return "SQLite 3 database" }
            let page = raw == 1 ? 65_536 : UInt32(raw)
            return "SQLite 3 database, \(grouped(page))-byte pages"
        }
        if b.starts(with: Array("bplist0".utf8)) { return "binary property list" }
        if b.starts(with: [0, 0, 0, 1]), b.starts(with: Array("Bud1".utf8), at: 4) { return "Finder .DS_Store" }
        if b.starts(with: Array("GGUF".utf8)), let version = b.u32(4, big: false) { return "GGUF model, version \(version)" }
        if b.starts(with: Array("PAR1".utf8)) { return "Parquet data" }
        if b.starts(with: Array("ARROW1".utf8)) { return "Arrow data" }
        if b.starts(with: [0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]) { return "HDF5 data" }
        if b.starts(with: [0x93] + Array("NUMPY".utf8)), let major = b[6] { return "NumPy array, format \(major)" }
        // safetensors: a little-endian header length, then that much JSON.
        if let length = b.u64(0, big: false), length > 1, length < 100_000_000, b[8] == UInt8(ascii: "{"),
           b[9] == UInt8(ascii: "\"") { return "safetensors" }
        return nil
    }

    private static func grouped(_ value: UInt32) -> String { FilesFormatting.count(value) }
}

/// Bounds-checked reads from a header: every accessor returns nil past the end.
private struct Bytes {
    let bytes: [UInt8]

    init(_ data: Data) { bytes = [UInt8](data) }

    var count: Int { bytes.count }

    subscript(_ index: Int) -> UInt8? { index >= 0 && index < bytes.count ? bytes[index] : nil }

    func starts(with prefix: [UInt8], at offset: Int = 0) -> Bool {
        guard offset >= 0, offset + prefix.count <= bytes.count else { return false }
        return bytes[offset..<offset + prefix.count].elementsEqual(prefix)
    }

    func u16(_ offset: Int, big: Bool) -> UInt16? { int(offset, 2, big: big).map(UInt16.init) }
    func u32(_ offset: Int, big: Bool) -> UInt32? { int(offset, 4, big: big).map(UInt32.init) }
    func u64(_ offset: Int, big: Bool) -> UInt64? { int(offset, 8, big: big) }

    /// The printable ASCII at `offset`, up to `length` bytes and the first other byte; nil when there is none.
    func ascii(_ offset: Int, _ length: Int) -> String? {
        guard offset >= 0, length > 0, offset < bytes.count else { return nil }
        let slice = bytes[offset..<min(offset + length, bytes.count)].prefix { (0x20...0x7E).contains($0) }
        return slice.isEmpty ? nil : String(decoding: slice, as: UTF8.self)
    }

    private func int(_ offset: Int, _ width: Int, big: Bool) -> UInt64? {
        guard offset >= 0, offset + width <= bytes.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<width {
            let byte = UInt64(bytes[big ? offset + index : offset + width - 1 - index])
            value = value << 8 | byte
        }
        return value
    }
}
