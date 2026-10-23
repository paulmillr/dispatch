import Foundation

/// One row of a file's diff (M5d): a hunk header, or a line with the number the shared `ToolDocument.lineNumbers`
/// gives it (the new file's, the old file's for a removal; nil while a hunk has no numbers, as Claude's edits).
struct DiffLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case hunk, context, added, removed, note }
    let kind: Kind
    let number: Int?
    /// The line without its `+`, `-` or space.
    let text: String
}

/// The changes of one file across a turn's patches: the shared `ToolDocument` diffs of every patch step that touched
/// it, in order, as one unified diff.
struct DiffFile: Identifiable, Equatable, Sendable {
    /// As the agent recorded it (absolute, or relative to `base`).
    let path: String
    /// Relative to the conversation's directory where it lies inside it (the section's title).
    let title: String
    /// The directory a relative `path` is relative to.
    let base: String?
    let diff: String
    let lines: [DiffLine]
    let additions: Int
    let deletions: Int
    var id: String { path }

    init(path: String, title: String, base: String?, diff: String) {
        self.path = path; self.title = title; self.base = base; self.diff = diff
        lines = Self.parse(diff)
        additions = lines.count { $0.kind == .added }
        deletions = lines.count { $0.kind == .removed }
    }

    /// The absolute path `files.text` reads, or nil when a relative path has no directory to resolve against.
    var absolutePath: String? {
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        guard let base, base.hasPrefix("/") else { return nil }
        return ((base as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    /// Git's metadata between files carries no lines of the file.
    private static let metadata = ["index ", "new file mode", "deleted file mode", "old mode", "new mode", "similarity index",
                                   "dissimilarity index", "rename from", "rename to", "copy from", "copy to", "Binary files"]

    static func parse(_ diff: String) -> [DiffLine] {
        var raw = diff.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        raw.removeAll { line in metadata.contains { line.hasPrefix($0) } }
        let numbers = ToolDocument.lineNumbers(raw)
        return zip(raw, numbers).map { line, number in
            if line.hasPrefix("@@") { return DiffLine(kind: .hunk, number: nil, text: line) }
            if line.hasPrefix("\\") { return DiffLine(kind: .note, number: nil, text: line) }
            if line.hasPrefix("+") { return DiffLine(kind: .added, number: number, text: String(line.dropFirst())) }
            if line.hasPrefix("-") { return DiffLine(kind: .removed, number: number, text: String(line.dropFirst())) }
            if line.hasPrefix(" ") { return DiffLine(kind: .context, number: number, text: String(line.dropFirst())) }
            return DiffLine(kind: .context, number: number, text: line)
        }
    }

    /// The hunks as ranges of `lines` (the header, when there is one, excluded).
    var hunks: [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (index, line) in lines.enumerated() {
            if line.kind == .hunk {
                if let start, start < index { result.append(start..<index) }
                start = index + 1
            } else if start == nil { start = index }
        }
        if let start, start < lines.count { result.append(start..<lines.count) }
        return result
    }

    /// Each line's text in the palette: per hunk the old version (context and removals) and the new one (context and
    /// additions) are coloured as code of their own, so a removed comment or string cannot change how added lines or
    /// the next hunk read (the Mac's `SyntaxHighlight.diffLines`). Hunk headers and notes stay plain.
    func highlighted() -> [AttributedString] {
        var result = lines.map { AttributedString(TextRendering.visible($0.text)) }
        let language = CodeSyntax.language(path)
        guard language != "text", diff.utf16.count <= CodeSyntax.limit else { return result }
        for hunk in hunks {
            let old = hunk.filter { lines[$0].kind == .context || lines[$0].kind == .removed }
            let new = hunk.filter { lines[$0].kind == .context || lines[$0].kind == .added }
            for (version, kinds) in [(old, [DiffLine.Kind.removed]), (new, [.context, .added])] where !version.isEmpty {
                let coloured = CodeSyntax.lines(version.map { lines[$0].text }.joined(separator: "\n"), language: language)
                for (offset, index) in version.enumerated() where kinds.contains(lines[index].kind) {
                    result[index] = coloured[offset]
                }
            }
        }
        return result
    }
}

/// A turn's changes (M5d): the patch steps' documents grouped by file, in the order the files were first touched.
struct DiffChanges: Equatable, Sendable {
    let files: [DiffFile]
    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    init(files: [DiffFile]) { self.files = files }

    /// `directory` is the conversation's (paths in titles are relative to it); a relative document path resolves
    /// against the patch's own working directory, else the directory the agent recorded for the call, else this one.
    init(items: [ChatItem], directory: String?) {
        var order: [String] = []
        var parts: [String: (title: String, base: String?, diffs: [String])] = [:]
        for item in items {
            let presentation = ToolPresentation(item)
            let recorded = presentation.directory ?? item.directory ?? directory
            for document in presentation.documents {
                let base = document.workingDirectory.map { working in
                    working.hasPrefix("/") ? working : recorded.map { ($0 as NSString).appendingPathComponent(working) } ?? working
                } ?? recorded
                let key = document.path.hasPrefix("/") ? document.path
                    : base.map { (($0 as NSString).appendingPathComponent(document.path) as NSString).standardizingPath } ?? document.path
                if parts[key] == nil {
                    order.append(key)
                    parts[key] = (Self.title(key, directories: [directory, recorded, base]), base, [])
                }
                parts[key]?.diffs.append(document.diff)
            }
        }
        files = order.map { key in
            let part = parts[key]!
            let diff = part.diffs.map { $0.hasSuffix("\n") || $0.isEmpty ? $0 : $0 + "\n" }.joined()
            return DiffFile(path: key, title: part.title, base: part.base, diff: diff)
        }
    }

    /// A path relative to the first of `directories` it lies in (the conversation's, then the call's), else as is.
    static func title(_ path: String, directories: [String?]) -> String {
        guard path.hasPrefix("/") else { return path }
        for case let directory? in directories where directory.hasPrefix("/") {
            let base = directory.hasSuffix("/") ? directory : directory + "/"
            if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
        }
        return path
    }

    /// "2 files", "1 file".
    var fileCount: String { files.count == 1 ? "1 file" : "\(files.count) files" }
}

/// The whole file with the diff's hunks marked inside it (M5d's trailing pill): each hunk is found where its new side
/// (context and additions) stands in the file as it is now, near the line its header names, else anywhere after the
/// previous hunk; its removals are shown where they were.
struct WholeFile: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let kind: DiffLine.Kind
        /// The line's number in the file as it is now; nil for removed lines (they are not in it).
        let number: Int?
        let text: AttributedString
    }

    let rows: [Row]
    /// Hunks of the diff that the file no longer contains as the patch left them.
    let missing: Int
    let hunks: Int

    init(file: DiffFile, text: String) {
        var fileLines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { fileLines.removeLast() }
        let language = CodeSyntax.language(file.path)
        let coloured = language != "text" && text.utf16.count <= CodeSyntax.limit
            ? CodeSyntax.lines(fileLines.joined(separator: "\n"), language: language)
            : fileLines.map { AttributedString(TextRendering.visible($0)) }
        let diffText = file.highlighted()
        var placed: [(start: Int, hunk: Range<Int>, length: Int)] = []
        var cursor = 0
        let hunks = file.hunks
        for hunk in hunks {
            let newSide = hunk.filter { file.lines[$0].kind == .context || file.lines[$0].kind == .added }
            let block = newSide.map { file.lines[$0].text }
            guard !block.isEmpty else { continue }
            let hint = newSide.first.flatMap { file.lines[$0].number }.map { $0 - 1 }
            func matches(_ start: Int) -> Bool {
                start >= cursor && start + block.count <= fileLines.count && Array(fileLines[start..<start + block.count]) == block
            }
            let start = hint.flatMap { matches($0) ? $0 : nil }
                ?? (cursor...max(cursor, fileLines.count - block.count)).first(where: matches)
            guard let start else { continue }
            placed.append((start, hunk, block.count))
            cursor = start + block.count
        }
        self.hunks = hunks.count
        missing = hunks.count - placed.count
        var rows: [Row] = []
        var line = 0
        for place in placed {
            while line < place.start {
                rows.append(Row(kind: .context, number: line + 1, text: coloured[line])); line += 1
            }
            for index in place.hunk {
                switch file.lines[index].kind {
                case .removed: rows.append(Row(kind: .removed, number: nil, text: diffText[index]))
                case .added: rows.append(Row(kind: .added, number: line + 1, text: coloured[line])); line += 1
                case .context: rows.append(Row(kind: .context, number: line + 1, text: coloured[line])); line += 1
                case .hunk, .note: break
                }
            }
        }
        while line < fileLines.count {
            rows.append(Row(kind: .context, number: line + 1, text: coloured[line])); line += 1
        }
        self.rows = rows
    }

    /// The note above the file when some changes are no longer in it.
    var note: String? {
        guard missing > 0 else { return nil }
        if missing == hunks { return hunks == 1 ? "This change is no longer in the file." : "These changes are no longer in the file." }
        return "\(missing) of \(hunks) changes are no longer in the file."
    }
}
