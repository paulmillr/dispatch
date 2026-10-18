import Foundation

// Pure readers of what the bounded git commands print (GitQueries names the exact arguments). Each takes git's text
// and tolerates the helper's bound: output cut short loses its last, incomplete record, never mis-reads it.

/// `git status --porcelain=v2 --branch -z --ignored`, before the per-file counts are folded in.
struct GitPorcelain: Hashable, Sendable {
    var branch: String?
    /// HEAD's full hash; nil before the first commit.
    var head: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    /// Staged, unstaged and untracked changes; an untracked folder git lists whole keeps its trailing slash.
    var changes: [GitChange] = []
    /// Ignored files and folders (folders with a trailing slash): they mark the Files list, never the Changes tab.
    var ignored: [String] = []
    /// The output was cut at the helper's bound (`GitQueries.status` sets it): the entries are the first ones only.
    var truncated = false
}

/// One line of `--numstat -z`; nil counts for a binary file.
struct GitNumstat: Hashable, Sendable {
    var path: String
    var oldPath: String?
    var additions: Int?
    var deletions: Int?

    var binary: Bool { additions == nil || deletions == nil }
}

/// One entry of `--name-status -z`: the letter git gives a file in a commit, and a rename's or copy's old path.
struct GitNameStatus: Hashable, Sendable {
    var path: String
    var oldPath: String?
    var kind: GitChangeKind
}

/// One line of `for-each-ref --format=%(refname)%09%(objectname)%09%(HEAD)%09%(*objectname)`.
struct GitRefRecord: Hashable, Sendable {
    /// The full name, `refs/heads/main`.
    var refname: String
    /// The commit the ref names: an annotated tag's peeled one, not its tag object.
    var hash: String
    /// The checked-out branch.
    var head: Bool

    /// The chip this ref shows as; nil for a remote's symbolic `HEAD`, which only repeats its default branch.
    var ref: GitRef? {
        for (prefix, kind) in [("refs/heads/", GitRefKind.branch), ("refs/remotes/", .remote), ("refs/tags/", .tag)]
        where refname.hasPrefix(prefix) {
            let name = String(refname.dropFirst(prefix.count))
            if kind == .remote, name.hasSuffix("/HEAD") { return nil }
            return GitRef(name: name, kind: kind, current: head && kind == .branch)
        }
        return nil
    }
}

enum GitParsers {
    static let unit = Character("\u{1f}")
    /// A log record's end: NUL, which git refuses in a commit message, an author or a ref name, so no text a commit
    /// carries can end a record early or forge the next one.
    static let record = Character("\u{0}")

    // MARK: Status

    static func porcelain(_ text: String) -> GitPorcelain {
        var fields = text.split(separator: "\0", omittingEmptySubsequences: false)
        // Complete output ends in a NUL, so the last field is empty; anything else there was cut by the bound.
        fields.removeLast()
        var status = GitPorcelain()
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard let tag = field.first else { continue }
            switch tag {
            case "#":
                header(field, into: &status)
            case "1":
                let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                append(xy: parts[1], path: String(parts[8]), oldPath: nil, to: &status)
            case "2":
                // A rename or copy: the old path is the next NUL-separated field.
                let parts = field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10, index < fields.count else { continue }
                let old = String(fields[index])
                index += 1
                append(xy: parts[1], path: String(parts[9]), oldPath: old, to: &status)
            case "u":
                let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                status.changes.append(GitChange(path: String(parts[10]), kind: .conflicted, area: .unstaged))
            case "?":
                guard field.count > 2 else { continue }
                status.changes.append(GitChange(path: String(field.dropFirst(2)), kind: .untracked, area: .untracked))
            case "!":
                guard field.count > 2 else { continue }
                status.ignored.append(String(field.dropFirst(2)))
            default:
                continue
            }
        }
        return status
    }

    private static func header(_ field: Substring, into status: inout GitPorcelain) {
        let parts = field.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid": status.head = value == "(initial)" ? nil : value
        case "branch.head": status.branch = value == "(detached)" ? nil : value
        case "branch.upstream": status.upstream = value
        case "branch.ab":
            let counts = value.split(separator: " ")
            guard counts.count == 2 else { return }
            status.ahead = Int(counts[0].dropFirst()) ?? 0
            status.behind = Int(counts[1].dropFirst()) ?? 0
        default: return
        }
    }

    /// The index side (X) is staged, the work tree side (Y) unstaged; a file changed in both appears twice.
    private static func append(xy: Substring, path: String, oldPath: String?, to status: inout GitPorcelain) {
        let letters = Array(xy)
        guard letters.count == 2 else { return }
        for (letter, area) in [(letters[0], GitChangeArea.staged), (letters[1], .unstaged)] {
            guard let kind = kind(letter) else { continue }
            let moved = kind == .renamed || kind == .copied
            status.changes.append(GitChange(path: path, oldPath: moved ? oldPath : nil, kind: kind, area: area))
        }
    }

    static func kind(_ letter: Character) -> GitChangeKind? {
        switch letter {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .conflicted
        default: nil
        }
    }

    // MARK: Counts

    /// `--numstat -z`: `added\tdeleted\tpath\0`, or `added\tdeleted\t\0old\0new\0` for a rename; `-` counts for a binary.
    static func numstat<S: StringProtocol>(_ text: S) -> [GitNumstat] {
        var fields = text.split(separator: "\0", omittingEmptySubsequences: false)
        fields.removeLast()
        var out: [GitNumstat] = []
        var index = 0
        while index < fields.count {
            // `show` puts a newline (and a merge an extra NUL) between the commit and its counts.
            let field = fields[index].drop { $0 == "\n" }
            index += 1
            let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let additions = Int(parts[0]), deletions = Int(parts[1])
            if parts[2].isEmpty {
                guard index + 1 < fields.count else { break }
                out.append(GitNumstat(path: String(fields[index + 1]), oldPath: String(fields[index]),
                                      additions: additions, deletions: deletions))
                index += 2
            } else {
                out.append(GitNumstat(path: String(parts[2]), additions: additions, deletions: deletions))
            }
        }
        return out
    }

    // MARK: Log

    /// Records of `GitQueries.format` (`%H %P %an %ae %at %D %s %b`, fields split by 0x1f, records ended by NUL). The text
    /// after the last record end is a record the bound cut, or the final newline.
    static func log(_ text: String) -> [GitCommit] {
        var records = text.split(separator: record, omittingEmptySubsequences: false)
        records.removeLast()
        return records.compactMap(commit)
    }

    /// One record, or nil when it is not one git printed whole: a hash or parent that is not hex, or a date that is not
    /// a number, means the fields are not where the format put them (a name or subject holding 0x1f shifted them).
    static func commit(_ record: Substring) -> GitCommit? {
        let fields = record.drop { $0 == "\n" || $0 == "\0" }.split(separator: unit, maxSplits: 7, omittingEmptySubsequences: false)
        guard fields.count == 8, isObjectName(fields[0]), let seconds = Int64(fields[4]) else { return nil }
        let parents = fields[1].split(separator: " ")
        guard parents.allSatisfy({ isObjectName($0) && $0.count == fields[0].count }) else { return nil }
        var body = String(fields[7])
        while body.last?.isNewline == true { body.removeLast() }
        return GitCommit(hash: String(fields[0]), parents: parents.map(String.init),
                         subject: String(fields[6]), body: body, author: String(fields[2]), email: String(fields[3]),
                         date: Date(timeIntervalSince1970: TimeInterval(seconds)), refs: decorations(String(fields[5])))
    }

    /// A full object name: 40 hex digits (SHA-1) or 64 (SHA-256).
    static func isObjectName<S: StringProtocol>(_ text: S) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64) && isHex(text)
    }

    /// ASCII hex digits only (`Character.isHexDigit` takes fullwidth ones too, which git and the helper do not).
    static func isHex<S: StringProtocol>(_ text: S) -> Bool {
        text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }
    }

    /// `%D`: `HEAD -> main, tag: v1, origin/main, feat/x`. A plain name is a branch until `for-each-ref` says it is a
    /// remote one (`GitRefs.merge`); a detached HEAD is a `head` chip of its own. `grafted` and `replaced` describe the
    /// commit, not a ref, and a full name (`refs/stash`, notes) is no branch, tag or remote: none is a chip.
    static func decorations(_ text: String) -> [GitRef] {
        text.components(separatedBy: ", ").compactMap { item in
            if item.isEmpty || item == "grafted" || item == "replaced" || item.hasPrefix("refs/") { return nil }
            if item == "HEAD" { return GitRef(name: "HEAD", kind: .head, current: true) }
            if item.hasPrefix("HEAD -> ") { return GitRef(name: String(item.dropFirst(8)), kind: .branch, current: true) }
            if item.hasPrefix("tag: ") { return GitRef(name: String(item.dropFirst(5)), kind: .tag, current: false) }
            if item.hasSuffix("/HEAD") { return nil }
            return GitRef(name: item, kind: .branch, current: false)
        }
    }

    static func refs(_ text: String) -> [GitRefRecord] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 4, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            let peeled = parts[3]
            return GitRefRecord(refname: String(parts[0]), hash: String(peeled.isEmpty ? parts[1] : peeled), head: parts[2] == "*")
        }
    }

    /// `show --numstat -z --format=<GitQueries.format> <hash>`: the commit's record, then its files' counts. Numstat
    /// does not say whether a file was added or deleted, so each file takes its letter from `letters` (`--name-status`,
    /// which git prints instead of numstat, never beside it); a file they leave out is `R` when git paired it with an old
    /// path and `M` otherwise.
    static func commitDetail(_ text: String, letters: [GitNameStatus] = []) -> GitCommitDetail? {
        guard let end = text.firstIndex(of: record), let commit = commit(text[..<end]) else { return nil }
        let byPath = Dictionary(letters.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let files = numstat(text[text.index(after: end)...]).map { count in
            let letter = byPath[count.path].flatMap { $0.oldPath == count.oldPath ? $0 : nil }
            return GitChange(path: count.path, oldPath: count.oldPath,
                             kind: letter?.kind ?? (count.oldPath == nil ? .modified : .renamed), area: .staged,
                             additions: count.additions, deletions: count.deletions, binary: count.binary)
        }
        return GitCommitDetail(commit: commit, files: files)
    }

    /// `--name-status -z` from `diff`: `M\0path\0`, or `R100\0old\0new\0` for a rename or copy (its score after the
    /// letter). A merge's combined form gives a letter per parent (`MM`): the first parent's is read.
    static func nameStatus<S: StringProtocol>(_ text: S) -> [GitNameStatus] {
        var fields = text.split(separator: "\0", omittingEmptySubsequences: false)
        fields.removeLast()
        var out: [GitNameStatus] = []
        var index = 0
        while index < fields.count {
            // `show` puts a newline (and a merge an extra NUL) between the commit and its files.
            let field = fields[index].drop { $0 == "\n" }
            index += 1
            guard let letter = field.first, let kind = kind(letter) else { continue }
            if kind == .renamed || kind == .copied {
                guard index + 1 < fields.count else { break }
                out.append(GitNameStatus(path: String(fields[index + 1]), oldPath: String(fields[index]), kind: kind))
                index += 2
            } else {
                guard index < fields.count else { break }
                out.append(GitNameStatus(path: String(fields[index]), kind: kind))
                index += 1
            }
        }
        return out
    }

    /// `show --name-status -z --format=<GitQueries.format> <hash>`: the files' letters after the commit's record.
    static func commitNameStatus(_ text: String) -> [GitNameStatus] {
        guard let end = text.firstIndex(of: record) else { return [] }
        return nameStatus(text[text.index(after: end)...])
    }

    // MARK: Diffs

    /// Splits unified diff output (`diff`, `show`) into one `GitDiff` per file: each keeps its text from its
    /// `diff --git` (or `--cc`) line on. The path is the new side's (`+++ b/…`, else `rename to`, else the header), the
    /// old path set when it differs. `truncated` marks the last file when the bound cut the output.
    static func diffs(_ text: String, truncated: Bool = false) -> [GitDiff] {
        var out: [GitDiff] = []
        var section: [Substring] = []
        func flush() {
            guard !section.isEmpty else { return }
            out.append(diff(section))
            section = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                flush()
            }
            if !section.isEmpty || line.hasPrefix("diff ") { section.append(line) }
        }
        flush()
        if truncated, !out.isEmpty { out[out.count - 1].truncated = true }
        return out
    }

    private static func diff(_ lines: [Substring]) -> GitDiff {
        var header: (old: String, new: String)?
        var minus: String?, plus: String?, renameFrom: String?, renameTo: String?
        var binary = false
        let first = lines[0]
        if first.hasPrefix("diff --git ") {
            header = headerPaths(String(first.dropFirst(11)))
        } else if let space = first.firstIndex(of: " ").map({ first[first.index(after: $0)...] }),
                  let name = space.firstIndex(of: " ").map({ space[space.index(after: $0)...] }) {
            // `diff --cc path`: a combined diff names the path once.
            let path = unquote(String(name))
            header = (path, path)
        }
        for line in lines.dropFirst() {
            if line.hasPrefix("@@") { break }
            if line.hasPrefix("--- ") { minus = side(line.dropFirst(4)) }
            else if line.hasPrefix("+++ ") { plus = side(line.dropFirst(4)) }
            else if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
                renameFrom = unquote(String(line.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst()))
            } else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
                renameTo = unquote(String(line.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst()))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                binary = true
            }
        }
        let path = plus ?? renameTo ?? minus ?? header?.new ?? ""
        let old = renameFrom ?? minus ?? header?.old
        // The last file's lines end with the empty string after git's final newline; the others end before the next
        // file's header.
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        return GitDiff(path: path, oldPath: old == path ? nil : old, text: text, binary: binary)
    }

    /// `a/<path>` or `b/<path>` from a `---`/`+++` line; nil for `/dev/null`.
    private static func side(_ value: Substring) -> String? {
        var value = String(value)
        // git ends a name holding spaces with a tab on these lines.
        if value.hasSuffix("\t") { value.removeLast() }
        if value == "/dev/null" { return nil }
        value = unquote(value)
        return value.hasPrefix("a/") || value.hasPrefix("b/") ? String(value.dropFirst(2)) : value
    }

    /// The paths of `diff --git a/<old> b/<new>`: quoted ones parse exactly; unquoted ones split where both halves are
    /// the same path (the usual case) or at the last ` b/`.
    private static func headerPaths(_ rest: String) -> (old: String, new: String)? {
        if rest.hasPrefix("\"") {
            guard let (old, tail) = quoted(rest) else { return nil }
            let next = tail.drop { $0 == " " }
            let new = next.hasPrefix("\"") ? quoted(String(next))?.0 ?? String(next) : String(next)
            return (strip(old), strip(new))
        }
        let characters = Array(rest)
        if characters.count >= 5, (characters.count - 5) % 2 == 0 {
            let half = (characters.count - 5) / 2
            let old = String(characters[2..<(2 + half)]), new = String(characters[(5 + half)...])
            if rest.hasPrefix("a/"), String(characters[(2 + half)..<(5 + half)]) == " b/", old == new { return (old, new) }
        }
        guard let split = rest.range(of: " b/", options: .backwards) else { return nil }
        let new = String(rest[split.upperBound...])
        let tail = rest[..<split.lowerBound]
        let old = String(tail.hasPrefix("a/") ? tail.dropFirst(2) : tail)
        let unquotedNew = new.hasPrefix("\"") ? strip(unquote(new)) : new
        return (old, unquotedNew)
    }

    private static func strip(_ path: String) -> String {
        path.hasPrefix("a/") || path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
    }

    /// git's C-style quoting of a name with control characters, quotes or backslashes (`core.quotepath=false` leaves
    /// other bytes as they are): `"a\tb"`, octal bytes `\303\251`.
    static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), let (inner, _) = quoted(value) else { return value }
        return inner
    }

    /// The first quoted string of `value` and what follows it.
    private static func quoted(_ value: String) -> (String, Substring)? {
        var bytes: [UInt8] = []
        let utf8 = Array(value.utf8)
        guard utf8.first == UInt8(ascii: "\"") else { return nil }
        var index = 1
        while index < utf8.count {
            let byte = utf8[index]
            if byte == UInt8(ascii: "\"") {
                let rest = String(decoding: utf8[(index + 1)...], as: UTF8.self)
                return (String(decoding: bytes, as: UTF8.self), Substring(rest))
            }
            if byte == UInt8(ascii: "\\"), index + 1 < utf8.count {
                let next = utf8[index + 1]
                switch next {
                case UInt8(ascii: "n"): bytes.append(0x0a); index += 2
                case UInt8(ascii: "t"): bytes.append(0x09); index += 2
                case UInt8(ascii: "r"): bytes.append(0x0d); index += 2
                case UInt8(ascii: "a"): bytes.append(0x07); index += 2
                case UInt8(ascii: "b"): bytes.append(0x08); index += 2
                case UInt8(ascii: "f"): bytes.append(0x0c); index += 2
                case UInt8(ascii: "v"): bytes.append(0x0b); index += 2
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var octal = 0, count = 0
                    while count < 3, index + 1 + count < utf8.count,
                          (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(utf8[index + 1 + count]) {
                        octal = octal * 8 + Int(utf8[index + 1 + count] - UInt8(ascii: "0"))
                        count += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: octal))
                    index += 1 + count
                default: bytes.append(next); index += 2
                }
                continue
            }
            bytes.append(byte)
            index += 1
        }
        return nil
    }

    /// A binary file's sizes from `--stat` (`logo.png | Bin 6 -> 11 bytes`), the only place git prints them.
    static func binarySizes(_ stat: String) -> (old: UInt64, new: UInt64)? {
        for line in stat.split(separator: "\n") {
            guard let bin = line.range(of: "| Bin ") else { continue }
            let words = line[bin.upperBound...].split(separator: " ")
            guard words.count >= 4, words[1] == "->", let old = UInt64(words[0]), let new = UInt64(words[2]) else { continue }
            return (old, new)
        }
        return nil
    }
}

/// Refs as chips on commits: `%D` names them, `for-each-ref` says which are remote and which branch is checked out,
/// and adds what a decoration filter left out.
enum GitRefs {
    static func merge(_ commits: [GitCommit], refs records: [GitRefRecord]) -> [GitCommit] {
        guard !records.isEmpty else { return commits }
        var kinds: [String: GitRefKind] = [:]
        var byHash: [String: [GitRef]] = [:]
        var current: String?
        for record in records {
            guard let ref = record.ref else { continue }
            // A local branch wins over a remote one of the same short name.
            if kinds[ref.name] != .branch { kinds[ref.name] = ref.kind }
            if ref.current { current = ref.name }
            byHash[record.hash, default: []].append(ref)
        }
        return commits.map { commit in
            var commit = commit
            commit.refs = refs(of: commit, kinds: kinds, extra: byHash[commit.hash] ?? [], current: current)
            return commit
        }
    }

    static func merge(_ detail: GitCommitDetail, refs records: [GitRefRecord]) -> GitCommitDetail {
        var detail = detail
        detail.commit = merge([detail.commit], refs: records)[0]
        return detail
    }

    private static func refs(of commit: GitCommit, kinds: [String: GitRefKind], extra: [GitRef], current: String?) -> [GitRef] {
        var out: [GitRef] = commit.refs.map { ref in
            guard ref.kind == .branch, let kind = kinds[ref.name] else { return ref }
            return GitRef(name: ref.name, kind: kind, current: kind == .branch && (ref.current || ref.name == current))
        }
        for ref in extra where !out.contains(where: { $0.name == ref.name && $0.kind == ref.kind }) {
            out.append(ref)
        }
        return out
    }
}

/// The Files list's git marks (F2a), from one status: M/A/D/R/C/T (and X for a conflict) on changed files, U on
/// untracked files and on a folder the status lists whole, `!` on ignored entries (the outline dims them). What is
/// inside an untracked or ignored folder takes its folder's mark. Folders holding changes show none.
struct GitMarks: Hashable, Sendable {
    /// Repository-relative paths of files with a mark.
    private(set) var files: [String: String] = [:]
    /// Repository-relative folders (no trailing slash) listed whole.
    private(set) var folders: [String: String] = [:]

    init() {}

    init(_ status: GitPorcelain) {
        var staged: [String: GitChangeKind] = [:], unstaged: [String: GitChangeKind] = [:]
        for change in status.changes {
            switch change.area {
            case .staged: staged[change.path] = change.kind
            case .unstaged: unstaged[change.path] = change.kind
            case .untracked:
                if change.path.hasSuffix("/") { folders[String(change.path.dropLast())] = "U" } else { files[change.path] = "U" }
            }
        }
        for path in Set(staged.keys).union(unstaged.keys) {
            // Against HEAD: a work tree deletion wins (the file is gone), else what the index holds (A, R…), else the
            // work tree's change.
            let kind = unstaged[path] == .deleted ? GitChangeKind.deleted : staged[path] ?? unstaged[path] ?? .modified
            files[path] = kind.rawValue
        }
        for path in status.ignored {
            if path.hasSuffix("/") { folders[String(path.dropLast())] = "!" } else { files[path] = "!" }
        }
    }

    var isEmpty: Bool { files.isEmpty && folders.isEmpty }

    /// The mark of the entry at a repository-relative path.
    func mark(_ path: String, directory: Bool) -> String? {
        if !directory, let mark = files[path] { return mark }
        if let mark = folders[path] { return mark }
        guard !folders.isEmpty else { return nil }
        var parent = path
        while let slash = parent.lastIndex(of: "/") {
            parent = String(parent[..<slash])
            if let mark = folders[parent] { return mark }
        }
        return nil
    }

    /// The listing with its entries' marks set (`folder` relative to the repository, "" at its top); nil `marks` clear them.
    static func apply(_ marks: GitMarks?, folder: String?, to listing: FileListing) -> FileListing {
        var listing = listing
        for index in listing.entries.indices {
            let entry = listing.entries[index]
            var mark: String?
            if let marks, let folder, entry.name != ".git" {
                mark = marks.mark(folder.isEmpty ? entry.name : folder + "/" + entry.name, directory: entry.isDirectory)
            }
            if entry.mark != mark { listing.entries[index].mark = mark }
        }
        return listing
    }
}
