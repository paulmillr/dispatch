import Foundation

/// Friendly labels for a small set of unambiguous commands. The original
/// command and output remain available; this never interprets or runs a shell.
struct ToolCommandPresentation: Sendable {
    let title: String
    let summary: String
    let symbol: String
    let runningTitle: String
    var swiftTests = false

    static let waiting = Self(title: "Wait for command", summary: "", symbol: "hourglass",
                              runningTitle: "Waiting for the command…")

    static func parse(_ command: String, directory: String = "") -> Self? {
        guard command.utf8.count <= 8_192 else { return nil }
        if command.contains(where: \.isNewline) { return multiline(command, directory: directory) }
        guard var words = ToolCommandWords.parse(command), !words.isEmpty else { return nil }
        let executable = (words.removeFirst() as NSString).lastPathComponent
        if ["rg", "grep"].contains(executable) {
            if executable == "rg", words.first == "--files" {
                words.removeFirst()
                guard words.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else { return nil }
                return Self(title: "Find files", summary: location(words), symbol: "doc.text.magnifyingglass", runningTitle: "Finding files…")
            }
            while words.first == "-n" || words.first == "--line-number" { words.removeFirst() }
            let terminated = words.first == "--"
            if terminated { words.removeFirst() }
            guard !words.isEmpty else { return nil }
            let pattern = words.removeFirst()
            guard !pattern.isEmpty, terminated || !pattern.hasPrefix("-"),
                  words.allSatisfy({ !$0.isEmpty && $0 != "-" && (terminated || !$0.hasPrefix("-")) }) else { return nil }
            // Bare grep reads standard input rather than the current directory.
            let target = executable == "grep" && words.isEmpty ? "in standard input" : location(words)
            return Self(title: "Search", summary: pattern + " · " + target, symbol: "magnifyingglass", runningTitle: "Searching…")
        }
        if executable == "git", !words.isEmpty {
            let operation = words.removeFirst()
            if operation == "status", words.allSatisfy({ ["--short", "-s", "--porcelain", "--porcelain=v1"].contains($0) }) {
                return Self(title: "Check working-tree changes", summary: "", symbol: "list.bullet", runningTitle: "Checking changes…")
            }
            if operation == "diff" {
                let staged = words.first == "--cached" || words.first == "--staged"
                if staged { words.removeFirst() }
                if !words.isEmpty {
                    guard words.removeFirst() == "--", !words.isEmpty,
                          words.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]:")) == nil }) else { return nil }
                }
                let files = words.joined(separator: ", ")
                return Self(title: "Review changes", summary: staged ? (files.isEmpty ? "Staged changes" : "Staged · " + files) : files,
                            symbol: "doc.text.magnifyingglass", runningTitle: "Reviewing changes…")
            }
        }
        if ["swift", "cargo"].contains(executable), words == ["test"] || words == ["build"] {
            let test = words[0] == "test"
            return Self(title: test ? "Run tests" : "Build", summary: executable == "swift" ? "Swift" : "Rust",
                        symbol: test ? "checkmark.circle" : "hammer", runningTitle: test ? "Running tests…" : "Building…",
                        swiftTests: test && executable == "swift")
        }
        return nil
    }

    private static func multiline(_ command: String, directory: String) -> Self? {
        let lines = command.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > 1 else { return lines.first.flatMap { parse($0, directory: directory) } }
        var descriptions: [String] = [], reads: [String] = []
        for line in lines.prefix(3) {
            if let read = ToolReadCommand(line) {
                let summary = read.summary(in: directory)
                reads.append(summary)
                descriptions.append("Read " + summary)
            } else if let operation = parse(line, directory: directory) {
                descriptions.append(operation.title + (operation.summary.isEmpty ? "" : " · " + operation.summary))
            } else {
                // Stop at the first unsupported statement. Later lines could
                // be quoted data, a heredoc, or a nested shell block.
                break
            }
        }
        guard !descriptions.isEmpty else { return nil }
        if reads.count == lines.count {
            return Self(title: "Read files", summary: reads.joined(separator: " · "), symbol: "doc.text",
                        runningTitle: "Reading files…")
        }
        if descriptions.count < lines.count { descriptions.append("additional commands") }
        // Mixed output is not a single source excerpt or an overall test result.
        return Self(title: "Run commands", summary: descriptions.joined(separator: " · "), symbol: "terminal",
                    runningTitle: "Running commands…")
    }

    private static func location(_ paths: [String]) -> String {
        paths.isEmpty ? "in current directory" : "in " + paths.joined(separator: ", ")
    }

    func confirmedTestResult(_ output: String) -> String? {
        guard swiftTests, output.utf8.count <= 1_000_000, !output.contains("tokens truncated") else { return nil }
        // Only top-level totals. Per-suite totals and mixed XCTest/Swift Testing
        // runs cannot safely be turned into one overall count by adding lines.
        let patterns = [
            #"(?m)^Test Suite 'All tests' passed at [^\n]+\n[ \t]*Executed ([0-9]+) tests?, with 0 failures \(0 unexpected\) in [^\n]+$"#,
            #"(?m)^[✔✓] Test run with ([0-9]+) tests?(?: in [0-9]+ suites?)? passed after [0-9.]+ seconds\.?$"#
        ]
        let counts = patterns.flatMap { pattern -> [Int] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap {
                Range($0.range(at: 1), in: output).flatMap { Int(output[$0]) }
            }
        }.filter { $0 > 0 }
        guard counts.count == 1, let count = counts.first else { return nil }
        return "\(count) \(count == 1 ? "test" : "tests") passed"
    }
}
