import Foundation

/// Source offsets use NSTextView's UTF-16 coordinate system, including unfinished fences.
struct ComposerFence: Equatable {
    let opening: NSRange
    let body: NSRange
    let closing: NSRange?
    let language: String
    var range: NSRange { NSRange(location: opening.location, length: NSMaxRange(closing ?? body) - opening.location) }
    func contains(_ selection: NSRange) -> Bool {
        selection.location >= body.location && NSMaxRange(selection) <= NSMaxRange(body)
            && (closing == nil || selection.location < closing!.location)
    }
    static func scan(_ text: String) -> [ComposerFence] {
        let lines = text.components(separatedBy: "\n")
        var result: [ComposerFence] = [], offset = 0
        var open: (range: NSRange, marker: Character, count: Int, language: String)?
        for (index, line) in lines.enumerated() {
            let range = NSRange(location: offset, length: line.utf16.count + (index < lines.count - 1 ? 1 : 0))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = open {
                if trimmed.prefix(while: { $0 == active.marker }).count >= active.count && trimmed.allSatisfy({ $0 == active.marker }) {
                    result.append(Self(opening: active.range, body: NSRange(location: NSMaxRange(active.range), length: offset - NSMaxRange(active.range)), closing: range, language: active.language))
                    open = nil
                }
            } else if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix(while: { $0 == marker }).count
                if count >= 3 {
                    let language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
                    open = (range, marker, count, language.isEmpty ? "text" : language)
                }
            }
            offset += range.length
        }
        if let active = open {
            result.append(Self(opening: active.range, body: NSRange(location: NSMaxRange(active.range), length: offset - NSMaxRange(active.range)), closing: nil, language: active.language))
        }
        return result
    }
}
