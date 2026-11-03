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
