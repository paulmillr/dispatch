import Foundation

/// Recognizes literal, single-file reads for display only. Never runs a shell
/// or loads the file: the preview must show the output captured by the tool.
struct ToolReadCommand: Sendable, Equatable {
    enum Selection: Sendable, Equatable {
        case all, lines(Int, Int), first(Int), last(Int)
    }
    let path: String
    let selection: Selection

    init(path: String, selection: Selection) {
        self.path = path
        self.selection = selection
    }

    var firstLine: Int? {
        switch selection {
        case .all, .first: 1
        case .lines(let start, _): start
        case .last: nil // The captured output does not tell us the file's length.
        }
    }

    func summary(in directory: String) -> String {
        let file = ToolDocument(path: path, diff: "").stepLabel(in: directory)
        switch selection {
        case .all: return file
        case .lines(let start, let end): return file + (start == end ? " · line \(start)" : " · lines \(start)–\(end)")
        case .first(let count): return file + " · first \(count) \(count == 1 ? "line" : "lines")"
        case .last(let count): return file + " · last \(count) \(count == 1 ? "line" : "lines")"
        }
    }

    init?(_ command: String) {
        guard var words = ToolCommandWords.parse(command), !words.isEmpty else { return nil }
        let executable = (words.removeFirst() as NSString).lastPathComponent
        let selection: Selection
        switch executable {
        case "cat": selection = .all
        case "sed":
            guard words.first == "-n" else { return nil }
            words.removeFirst()
            if words.first == "-e" { words.removeFirst() }
            guard !words.isEmpty else { return nil }
            let expression = words.removeFirst()
            guard expression.last == "p" else { return nil }
            let range = expression.dropLast().split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(range.count), let start = Self.number(String(range[0])),
                  let end = Self.number(String(range.last!)), end >= start else { return nil }
            selection = .lines(start, end)
        case "head", "tail":
            var count = 10
            if let option = words.first, option != "--", option.hasPrefix("-") {
                words.removeFirst()
                let number: String
                if option == "-n" || option == "--lines" {
                    guard !words.isEmpty else { return nil }
                    number = words.removeFirst()
                } else if option.hasPrefix("--lines=") { number = String(option.dropFirst(8)) }
                else if option.hasPrefix("-n") { number = String(option.dropFirst(2)) }
                else { number = String(option.dropFirst()) }
                guard let value = Self.number(number) else { return nil }
                count = value
            }
            selection = executable == "head" ? .first(count) : .last(count)
        default: return nil
        }
        let terminated = words.first == "--"
        if terminated { words.removeFirst() }
        guard words.count == 1, let path = words.first, !path.isEmpty, path != "-",
              terminated || !path.hasPrefix("-") else { return nil }
        self.path = path; self.selection = selection
    }

    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), value > 0, value <= Int.max - 32_768 else { return nil }
        return value
    }

}
