import Foundation

/// Byte classification and strict UTF-8 decoding for both Files previews. Read sizes and text presentation limits
/// belong to each platform; a partial window may omit only a valid scalar cut off at its end.
enum FilePreviewContent {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp"]
    static let markdownExtensions: Set<String> = ["md", "markdown"]

    enum Kind: Equatable { case image, binary, markdown, text }

    static func kind(name: String, size: UInt64, head: Data, imageLimit: UInt64) -> Kind {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return size <= imageLimit ? .image : .binary }
        if head.contains(0) || validUTF8PrefixLength(head, allowingIncompleteSuffix: UInt64(head.count) < size) == nil {
            return .binary
        }
        return markdownExtensions.contains(ext) ? .markdown : .text
    }

    /// A leading UTF-8 BOM is metadata, omitted from display. All other bytes must be exact UTF-8.
    static func text(_ data: Data, allowingIncompleteSuffix: Bool = false) -> String? {
        guard let count = validUTF8PrefixLength(data, allowingIncompleteSuffix: allowingIncompleteSuffix) else { return nil }
        let start = data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        return String(decoding: data.dropFirst(start).prefix(max(0, count - start)), as: UTF8.self)
    }

    /// Text in an encoding other than UTF-8 that a preview can still show (read-only): UTF-16 that starts with its
    /// byte-order mark, or 8-bit text with no control characters but whitespace, no C1 controls and nothing that reads as
    /// broken UTF-8 (Latin-1).
    enum OtherEncoding: Equatable, Sendable {
        case utf16
        case latin1

        var title: String {
            switch self {
            case .utf16: "UTF-16"
            case .latin1: "Latin-1"
            }
        }
    }

    /// The encoding `head` (a file's first bytes) reads as when it is not UTF-8; nil for UTF-8 or for bytes that are
    /// not text.
    static func otherEncoding(_ head: Data) -> OtherEncoding? {
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return head.count % 2 == 0 ? .utf16 : nil }
        guard !head.isEmpty, validUTF8PrefixLength(head, allowingIncompleteSuffix: true) == nil else { return nil }
        let allowed: Set<UInt8> = [0x09, 0x0A, 0x0C, 0x0D, 0x1B]
        for byte in head where (byte < 0x20 && !allowed.contains(byte)) || byte == 0x7F || (0x80...0x9F).contains(byte) {
            return nil
        }
        // A lead byte followed by a continuation byte is broken UTF-8 (an overlong form, a cut sequence), not Latin-1,
        // whose letters stand alone: "caf\u{E9} " is E9 then a space.
        for (byte, next) in zip(head, head.dropFirst()) where byte >= 0xC0 && (0x80...0xBF).contains(next) { return nil }
        return .latin1
    }

    /// `data` decoded as `encoding`, a UTF-16 byte-order mark omitted; nil when it does not decode.
    static func text(_ data: Data, encoding: OtherEncoding) -> String? {
        switch encoding {
        case .utf16:
            guard data.count % 2 == 0 else { return nil }
            return String(data: data, encoding: .utf16).map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 }
        case .latin1:
            return String(data: data, encoding: .isoLatin1)
        }
    }

    /// Returns the number of bytes in the valid prefix. With `allowingIncompleteSuffix`, only a well-formed scalar
    /// cut off at the end is accepted; overlong encodings, surrogates and values past U+10FFFF remain invalid.
    static func validUTF8PrefixLength(_ data: Data, allowingIncompleteSuffix: Bool) -> Int? {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            if first < 0x80 { index += 1; continue }
            let length: Int
            let second: ClosedRange<UInt8>
            switch first {
            case 0xC2...0xDF: length = 2; second = 0x80...0xBF
            case 0xE0: length = 3; second = 0xA0...0xBF
            case 0xE1...0xEC, 0xEE...0xEF: length = 3; second = 0x80...0xBF
            case 0xED: length = 3; second = 0x80...0x9F
            case 0xF0: length = 4; second = 0x90...0xBF
            case 0xF1...0xF3: length = 4; second = 0x80...0xBF
            case 0xF4: length = 4; second = 0x80...0x8F
            default: return nil
            }
            let available = min(length, bytes.count - index)
            if available >= 2, !second.contains(bytes[index + 1]) { return nil }
            if available >= 3 {
                for offset in 2..<available where !(0x80...0xBF).contains(bytes[index + offset]) { return nil }
            }
            guard available == length else { return allowingIncompleteSuffix ? index : nil }
            index += length
        }
        return index
    }

}
