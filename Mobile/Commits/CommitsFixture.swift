#if DEBUG
import Foundation

/// A repository answered in process, as `files.git` would print it (Debug: the Spaces sample's Commits mode, H3 and C2,
/// and the tests): its commits, refs, HEAD and whether the work tree has changes. It reads the same argument lists the
/// queries send (`GitCommands`) and prints what git prints for them, so the sample runs the real parsers.
final class CommitsFixture: CommitsGit, @unchecked Sendable {
    struct File: Sendable {
        var path: String
        var oldPath: String? = nil
        /// A, M, D, R.
        var letter: String
        var additions: Int
        var deletions: Int
        /// The file's diff lines after the hunk header (`+`, `-`, ` `); the whole file as the commit left it is its
        /// context and additions.
        var lines: [String] = []
    }

    struct Commit: Sendable {
        var hash: String
        var parents: [String]
        var author: String
        var email: String
        var date: Date
        var subject: String
        var body = ""
        var signature: GitSignatureKind? = nil
        var files: [File] = []
    }

    struct Ref: Sendable {
        var name: String
        var hash: String
        var head = false
    }

    let commits: [Commit]
    let refs: [Ref]
    let head: String?
    var dirty: Bool
    /// The verdict `verify-commit` gives (an allowed SSH signer by default).
    var verdict = "Good \"git\" signature for alex@example.com with ED25519 key SHA256:Q2xhdWRlIGZpeHR1cmUga2V5IGZvciB0ZXN0cw"
    /// A command whose first words are a key here fails with that message (or throws when it starts with `throw:`).
    var failures: [String: String] = [:]

    private let lock = NSLock()
    private var asked: [[String]] = []
    /// Commands (by their first word) that wait for `release`.
    private var holds: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(commits: [Commit], refs: [Ref], head: String?, dirty: Bool = true) {
        self.commits = commits
        self.refs = refs
        self.head = head
        self.dirty = dirty
    }

    var identity: ObjectIdentifier { ObjectIdentifier(self) }

    /// Every command asked so far.
    var calls: [[String]] { lock.withLock { asked } }

    /// `command` (`status`, `log`…) waits for `release` from now on.
    func hold(_ command: String) { lock.withLock { _ = holds.insert(command) } }

    /// Lets the held `command` answer, now and later.
    func release(_ command: String) {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holds.remove(command)
            return waiting.removeValue(forKey: command) ?? []
        }
        for continuation in resumed { continuation.resume() }
    }

    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput {
        lock.withLock { asked.append(args) }
        if let command = args.first {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let held = lock.withLock { () -> Bool in
                    guard holds.contains(command) else { return false }
                    waiting[command, default: []].append(continuation)
                    return true
                }
                if !held { continuation.resume() }
            }
        }
        let line = args.joined(separator: " ")
        for (prefix, message) in failures where line.hasPrefix(prefix) {
            if message.hasPrefix("throw:") { throw HelperFailure(code: String(message.dropFirst(6)), message: "") }
            return GitOutput(status: 128, output: message, truncated: false)
        }
        let output = answer(args)
        let cap = limit == 0 ? 2 << 20 : Int(limit)
        if output.utf8.count > cap {
            return GitOutput(status: 0, output: String(decoding: Data(output.utf8).prefix(cap), as: UTF8.self), truncated: true)
        }
        return GitOutput(status: 0, output: output, truncated: false)
    }

    private func answer(_ args: [String]) -> String {
        switch args.first {
        case "rev-parse": return head.map { $0 + "\n" } ?? ""
        case "for-each-ref":
            return refs.map { "\($0.name)\t\($0.hash)\t\($0.head ? "*" : " ")\t\n" }.joined()
        case "status":
            let branch = refs.first { $0.head }.map { String($0.name.dropFirst("refs/heads/".count)) } ?? "(detached)"
            return "# branch.oid \(head ?? "(initial)")\0# branch.head \(branch)\0" + (dirty ? "? docs/theming.md\0" : "")
        case "log": return log(args)
        case "show": return show(args)
        case "diff":
            // A merge's letters against its first parent.
            guard let hash = args.last, let commit = commit(hash) else { return "" }
            return commit.files.map { "\($0.letter)\0\($0.path)\0" }.joined()
        case "verify-commit":
            return verdict + "\n"
        default: return ""
        }
    }

    private func commit(_ hash: String) -> Commit? { commits.first { $0.hash.hasPrefix(hash) } }

    /// The commits `log` lists for the arguments: reachable from the tip (or HEAD) for a branch, all with `--all`,
    /// newest first, matched, skipped and counted.
    private func log(_ args: [String]) -> String {
        var count = Int.max, skip = 0, all = false, raw = false
        var grep: String?, author: String?, tip: String?
        var index = 1
        while index < args.count {
            let argument = args[index]
            if argument == "-n", index + 1 < args.count { count = Int(args[index + 1]) ?? count; index += 2; continue }
            if argument.hasPrefix("--skip=") { skip = Int(argument.dropFirst(7)) ?? 0 }
            else if argument == "--all" { all = true }
            else if argument == "--pretty=raw" { raw = true }
            else if argument.hasPrefix("--grep=") { grep = String(argument.dropFirst(7)) }
            else if argument.hasPrefix("--author=") { author = String(argument.dropFirst(9)) }
            else if !argument.hasPrefix("-") { tip = argument }
            index += 1
        }
        var listed: [Commit]
        if all {
            listed = commits
        } else {
            var reachable: Set<String> = []
            var queue = [tip.flatMap(commit)?.hash ?? head].compactMap { $0 }
            while let next = queue.popLast() {
                guard reachable.insert(next).inserted, let commit = commit(next) else { continue }
                queue += commit.parents
            }
            listed = commits.filter { reachable.contains($0.hash) }
        }
        listed.sort { $0.date > $1.date }
        if let grep { listed = listed.filter { ($0.subject + "\n" + $0.body).localizedCaseInsensitiveContains(grep) } }
        if let author { listed = listed.filter { ($0.author + " <" + $0.email + ">").localizedCaseInsensitiveContains(author) } }
        let page = listed.dropFirst(skip).prefix(count)
        return page.map { raw ? rawRecord($0) : record($0) }.joined(separator: raw ? "" : "\n") + (raw || page.isEmpty ? "" : "\n")
    }

    private func decorations(_ commit: Commit) -> String {
        refs.filter { $0.hash == commit.hash }.map { ref -> String in
            if ref.name.hasPrefix("refs/heads/") {
                let name = String(ref.name.dropFirst(11))
                return ref.head ? "HEAD -> \(name)" : name
            }
            if ref.name.hasPrefix("refs/tags/") { return "tag: " + ref.name.dropFirst(10) }
            return String(ref.name.dropFirst("refs/remotes/".count))
        }.joined(separator: ", ")
    }

    private func record(_ commit: Commit) -> String {
        [commit.hash, commit.parents.joined(separator: " "), commit.author, commit.email,
         String(Int(commit.date.timeIntervalSince1970)), decorations(commit), commit.subject,
         commit.body.isEmpty ? "" : commit.body + "\n"].joined(separator: "\u{1F}") + "\0"
    }

    private func rawRecord(_ commit: Commit) -> String {
        let person = "\(commit.author) <\(commit.email)> \(Int(commit.date.timeIntervalSince1970)) +0000"
        var text = "commit \(commit.hash)\ntree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n"
        for parent in commit.parents { text += "parent \(parent)\n" }
        text += "author \(person)\ncommitter \(person)\n"
        switch commit.signature {
        case .ssh?: text += "gpgsig -----BEGIN SSH SIGNATURE-----\n U1NIU0lHAAAAAQ==\n -----END SSH SIGNATURE-----\n"
        case .gpg?: text += "gpgsig -----BEGIN PGP SIGNATURE-----\n iQEzBAABCAAdFiEE\n -----END PGP SIGNATURE-----\n"
        case .x509?: text += "gpgsig -----BEGIN SIGNED MESSAGE-----\n MIAGCSqGSIb3DQ==\n -----END SIGNED MESSAGE-----\n"
        case nil: break
        }
        text += "\n    \(commit.subject)\n"
        if !commit.body.isEmpty { text += "\n" + commit.body.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") + "\n" }
        return text + "\n"
    }

    private func show(_ args: [String]) -> String {
        let hashes = args.filter { GitCommands.checked($0) != nil && $0.count >= 7 }
        guard let hash = hashes.last, let commit = commit(hash) else { return "" }
        if args.contains("--numstat") {
            return record(commit) + "\0\n" + commit.files.map { file in
                file.oldPath.map { "\(file.additions)\t\(file.deletions)\t\0\($0)\0\(file.path)\0" }
                    ?? "\(file.additions)\t\(file.deletions)\t\(file.path)\0"
            }.joined()
        }
        if args.contains("--name-status") {
            return record(commit) + "\0\n" + commit.files.map { file in
                file.oldPath.map { "R100\0\($0)\0\(file.path)\0" } ?? "\(file.letter)\0\(file.path)\0"
            }.joined()
        }
        // A patch: of the files after `--`, else every file.
        let paths = args.firstIndex(of: "--").map { Array(args[($0 + 1)...]) }
        let files = commit.files.filter { file in paths.map { $0.contains(file.path) } ?? true }
        return files.map(patch).joined()
    }

    private func patch(_ file: File) -> String {
        let old = file.oldPath ?? file.path
        var text = "diff --git a/\(old) b/\(file.path)\n"
        if file.letter == "A" { text += "new file mode 100644\n" }
        if file.letter == "D" { text += "deleted file mode 100644\n" }
        text += "index 1f2e3d4..5a6b7c8 100644\n"
        text += "--- \(file.letter == "A" ? "/dev/null" : "a/" + old)\n+++ \(file.letter == "D" ? "/dev/null" : "b/" + file.path)\n"
        let oldCount = file.lines.count { !$0.hasPrefix("+") }, newCount = file.lines.count { !$0.hasPrefix("-") }
        text += "@@ -\(oldCount == 0 ? 0 : 1),\(oldCount) +\(newCount == 0 ? 0 : 1),\(newCount) @@\n"
        return text + file.lines.map { $0 + "\n" }.joined()
    }
}

extension CommitsFixture {
    /// A fictional full hash from a short one.
    static func hash(_ short: String) -> String {
        let fill = "9e0b3d5a7c1f2e4b6d8a0c3e5f7a9b1d2c4e6f8a0b"
        return String((short + fill).prefix(40))
    }

    /// The mockup's repository (H3, C2): `dark-mode` with a merged `router-upgrade`, a tag, signed commits by Alex
    /// Rivera, and uncommitted changes. Ages from `now`.
    static func sample(now: Date = Date()) -> CommitsFixture {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let alex = ("Alex Rivera", "alex@example.com"), sam = ("Sam Example", "sam@example.com"),
            priya = ("Priya Example", "priya@example.com")
        func commit(_ short: String, _ parents: [String], _ who: (String, String), _ minutes: Double, _ subject: String,
                    body: String = "", signed: Bool = false, files: [File] = []) -> Commit {
            Commit(hash: hash(short), parents: parents.map(hash), author: who.0, email: who.1, date: ago(minutes),
                   subject: subject, body: body, signature: signed ? .ssh : nil, files: files)
        }
        let day = 24.0 * 60
        let commits = [
            commit("c81a2f4", ["7d04e9b"], alex, 25, "Sidebar theme toggle and unread rows",
                   body: "Moves the theme switch out of Settings into the sidebar footer so it is one tap away.\n\nThe unread state now renders on the row instead of a dot in the link, matching the mobile app.",
                   signed: true, files: sidebarFiles),
            commit("7d04e9b", ["f3e1c02"], alex, 120, "Theme tokens: dark palette and contrast fixes", signed: true,
                   files: [File(path: "src/styles/tokens.css", letter: "M", additions: 88, deletions: 14)]),
            commit("f3e1c02", ["9b7ac11"], alex, 300, "useTheme hook with system preference tracking", signed: true,
                   files: [File(path: "src/theme.ts", letter: "A", additions: 54, deletions: 0)]),
            commit("9b7ac11", ["41f0d9a", "2c9d8e0"], sam, day + 30, "Merge branch 'router-upgrade'",
                   files: [File(path: "src/router.tsx", letter: "M", additions: 231, deletions: 190)]),
            commit("2c9d8e0", ["e5a4b73"], sam, day + 60, "Upgrade react-router to v7",
                   files: [File(path: "src/router.tsx", letter: "M", additions: 231, deletions: 190)]),
            commit("e5a4b73", ["b0c7e26"], sam, 2 * day, "Fix nested route links losing the active class",
                   files: [File(path: "src/components/NavLink.tsx", letter: "M", additions: 9, deletions: 6)]),
            commit("41f0d9a", ["b0c7e26"], alex, 3 * day, "Release 1.4.0", signed: true,
                   files: [File(path: "package.json", letter: "M", additions: 1, deletions: 1)]),
            commit("b0c7e26", ["d7e2f58"], priya, 4 * day, "Docs: deployment notes for the preview environment",
                   files: [File(path: "docs/deploy.md", letter: "A", additions: 37, deletions: 0)]),
            commit("d7e2f58", ["a19c4b3"], alex, 5 * day, "Spaces list: keyboard navigation", signed: true,
                   files: [File(path: "src/components/Spaces.tsx", letter: "M", additions: 73, deletions: 21)]),
            commit("a19c4b3", ["6f8b1d2"], priya, 6 * day, "CI: cache pnpm store between jobs",
                   files: [File(path: ".github/workflows/ci.yml", letter: "M", additions: 14, deletions: 3)]),
            commit("6f8b1d2", ["0e3a7c9"], alex, 8 * day, "Header: collapse search on narrow widths",
                   files: [File(path: "src/components/Header.tsx", letter: "M", additions: 28, deletions: 11)]),
            commit("0e3a7c9", [], alex, 21 * day, "Initial Vite scaffold",
                   files: [File(path: "index.html", letter: "A", additions: 13, deletions: 0)]),
        ]
        let refs = [
            Ref(name: "refs/heads/dark-mode", hash: hash("c81a2f4"), head: true),
            Ref(name: "refs/heads/main", hash: hash("9b7ac11")),
            Ref(name: "refs/remotes/origin/main", hash: hash("9b7ac11")),
            Ref(name: "refs/tags/v1.4.0", hash: hash("41f0d9a")),
        ]
        return CommitsFixture(commits: commits, refs: refs, head: hash("c81a2f4"))
    }

    /// `count` commits in a line on `main`, an hour apart, every `signedEvery`th signed (none for nil; paging tests).
    static func linear(_ count: Int, signedEvery: Int? = 3, now: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> CommitsFixture {
        let hashes = (0..<count).map { String(format: "%040x", $0 + 1) }
        let commits = (0..<count).map { index in
            Commit(hash: hashes[index], parents: index + 1 < count ? [hashes[index + 1]] : [],
                   author: index % 2 == 0 ? "Alex Rivera" : "Sam Example",
                   email: index % 2 == 0 ? "alex@example.com" : "sam@example.com",
                   date: now.addingTimeInterval(Double(-index) * 3600), subject: "Change \(count - index)",
                   signature: signedEvery.map { index % $0 == 0 } == true ? .ssh : nil,
                   files: [File(path: "src/file\(index).ts", letter: "M", additions: 1, deletions: 1, lines: ["-old", "+new"])])
        }
        return CommitsFixture(commits: commits, refs: [Ref(name: "refs/heads/main", hash: hashes[0], head: true)],
                              head: hashes.first, dirty: false)
    }

    /// C2's four files, their diffs as the counts say.
    private static var sidebarFiles: [File] {
        let sidebar = [
            " import { NavLink } from \"react-router\";",
            "-import { useSettings } from \"../settings\";",
            "+import { ThemeToggle } from \"./ThemeToggle\";",
            "+import { useTheme } from \"../theme\";",
            " ",
            " export function Sidebar({ spaces }: SidebarProps) {",
            "-  const { theme } = useSettings();",
            "+  const { theme, setTheme } = useTheme();",
            "   return (",
            "-    <nav className={`sidebar sidebar-${theme}`}>",
            "+    <nav className=\"sidebar\" data-theme={theme}>",
            "       <ul>",
            "         {spaces.map((space) => (",
            "-          <li key={space.id} className={space.unread ? \"unread\" : \"\"}>",
            "-            <NavLink to={space.path} end>",
            "-              {space.unread && <span className=\"dot\" />}",
            "+          <li key={space.id}>",
            "+            <NavLink",
            "+              to={space.path}",
            "+              className={({ isActive }) =>",
            "+                [isActive && \"active\", space.unread && \"unread\"].filter(Boolean).join(\" \")",
            "+              }",
            "+            >",
            "               {space.name}",
            "             </NavLink>",
            "           </li>",
            "         ))}",
            "       </ul>",
            "+      <footer className=\"sidebar-footer\">",
            "+        <ThemeToggle value={theme} onChange={setTheme} />",
            "+      </footer>",
            "     </nav>",
            "   );",
            " }",
        ]
        let toggle = (1...32).map { line -> String in
            let code = [
                "import { Theme } from \"../theme\";", "", "const options: { value: Theme; label: string }[] = [",
                "  { value: \"system\", label: \"System\" },", "  { value: \"light\", label: \"Light\" },",
                "  { value: \"dark\", label: \"Dark\" },", "];", "", "export function ThemeToggle({",
                "  value,", "  onChange,", "}: {", "  value: Theme;", "  onChange: (theme: Theme) => void;", "}) {",
                "  return (", "    <div className=\"theme-toggle\" role=\"radiogroup\" aria-label=\"Theme\">",
                "      {options.map((option) => (", "        <button", "          key={option.value}",
                "          role=\"radio\"", "          aria-checked={value === option.value}",
                "          className={value === option.value ? \"selected\" : \"\"}",
                "          onClick={() => onChange(option.value)}", "        >", "          {option.label}",
                "        </button>", "      ))}", "    </div>", "  );", "}", "",
            ]
            return "+" + code[line - 1]
        }
        let tokens = [
            " :root {", "   --canvas: #f2f2f7;", "-  --ink: #111;", "+  --ink: #1c1c1e;", "+  --row: #ffffff;",
            "+  --accent: #d16ba5;", " }", " ", "-[data-theme=\"dark\"] {", "-  --canvas: #000;",
            "+:root[data-theme=\"dark\"] {", "+  --canvas: #000000;", "+  --ink: #f2f2f7;", "+  --row: #1c1c1e;", " }",
            "+", "+@media (prefers-color-scheme: dark) {",
            "+  :root[data-theme=\"system\"] { --canvas: #000000; --ink: #f2f2f7; --row: #1c1c1e; }",
            "+  .sidebar-footer { border-color: var(--row); }", "+}",
        ]
        let main = [
            " import { createRoot } from \"react-dom/client\";", " import { App } from \"./App\";",
            "+import { applyStoredTheme } from \"./theme\";", "+import \"./styles/tokens.css\";", " ",
            "+applyStoredTheme();", " createRoot(document.getElementById(\"root\")!).render(<App />);",
        ]
        return [
            File(path: "src/components/Sidebar.tsx", letter: "M", additions: 14, deletions: 6, lines: sidebar),
            File(path: "src/components/ThemeToggle.tsx", letter: "A", additions: 32, deletions: 0, lines: toggle),
            File(path: "src/styles/tokens.css", letter: "M", additions: 12, deletions: 3, lines: tokens),
            File(path: "src/main.tsx", letter: "M", additions: 3, deletions: 0, lines: main),
        ]
    }
}
#endif
