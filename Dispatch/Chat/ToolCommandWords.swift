import Foundation

/// Literal command words shared by display-only command formatters.
enum ToolCommandWords {
    /// A deliberately small shell subset: literal words with quotes/escapes.
    /// Operators, expansions, globs and multiline scripts keep their raw display.
    static func parse(_ command: String) -> [String]? {
        guard command.utf8.count <= 8_192, !command.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        var words: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for char in command {
            if escaped { word.append(char); escaped = false; continue }
            if let current = quote {
                if char == current { quote = nil }
                else {
                    if current == "\"", "$`\\".contains(char) { return nil }
                    word.append(char)
                }
            } else if char == "\\" { escaped = true; started = true }
            else if char == "'" || char == "\"" { quote = char; started = true }
            else if char == " " || char == "\t" {
                if started { words.append(word); word = ""; started = false }
            } else {
                guard !"$`|&;<>()[]{}*?~#!".contains(char) else { return nil }
                word.append(char); started = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if started { words.append(word) }
        return words
    }

    /// The command after a leading `cd <dir> &&` or `cd <dir>;` that changes
    /// into the directory it already runs in, or nil when there is none.
    static func droppingRedundantCd(_ command: String, directory: String?) -> String? {
        guard let directory, directory.hasPrefix("/") else { return nil }
        let text = command.drop(while: { $0 == " " || $0 == "\t" })
        guard text.hasPrefix("cd ") || text.hasPrefix("cd\t") else { return nil }
        // Find the first separator outside quotes on the first line.
        var quote: Character?, escaped = false, index = text.startIndex
        var separator: (Substring.Index, Int)?
        while index < text.endIndex, separator == nil {
            let char = text[index]
            if escaped { escaped = false }
            else if let current = quote { if char == current { quote = nil } else if current == "\"", char == "\\" { escaped = true } }
            else if char.isNewline { return nil }
            else if char == "\\" { escaped = true }
            else if char == "'" || char == "\"" { quote = char }
            else if char == ";" { separator = (index, 1) }
            else if char == "&" {
                let next = text.index(after: index)
                guard next < text.endIndex, text[next] == "&" else { return nil }
                separator = (index, 2)
            }
            if separator == nil { index = text.index(after: index) }
        }
        guard let (start, length) = separator, let words = parse(String(text[..<start])),
              words.count == 2, standardized(words[1]) == standardized(directory) else { return nil }
        let rest = text[text.index(start, offsetBy: length)...].drop(while: { $0 == " " || $0 == "\t" })
        guard !rest.isEmpty, !rest.hasPrefix(";"), !rest.hasPrefix("&"), !rest.hasPrefix("|") else { return nil }
        return String(rest)
    }

    private static func standardized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
