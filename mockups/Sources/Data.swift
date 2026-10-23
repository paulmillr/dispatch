import SwiftUI

// Fictional data for the mockups: host "mba2", space "web", repo /Users/alex/src/web on branch dark-mode.

struct MockFile: Identifiable {
    let name: String
    let dir: Bool
    let size: String
    let age: String
    var hidden = false
    var depth = 0
    var open = false
    var id: String { "\(depth)/\(name)" }
}

enum MockFiles {
    static let root: [MockFile] = [
        .init(name: ".github", dir: true, size: "", age: "3w", hidden: true),
        .init(name: "docs", dir: true, size: "", age: "2d"),
        .init(name: "public", dir: true, size: "", age: "6d"),
        .init(name: "src", dir: true, size: "", age: "4m", open: true),
        .init(name: "components", dir: true, size: "", age: "4m", depth: 1, open: true),
        .init(name: "ThemeToggle.tsx", dir: false, size: "2.1 KB", age: "4m", depth: 2),
        .init(name: "Sidebar.tsx", dir: false, size: "6.4 KB", age: "12m", depth: 2),
        .init(name: "Header.tsx", dir: false, size: "3.0 KB", age: "2d", depth: 2),
        .init(name: "hooks", dir: true, size: "", age: "25m", depth: 1),
        .init(name: "styles", dir: true, size: "", age: "25m", depth: 1),
        .init(name: "theme.ts", dir: false, size: "1.8 KB", age: "25m", depth: 1),
        .init(name: "main.tsx", dir: false, size: "912 B", age: "2d", depth: 1),
        .init(name: "tests", dir: true, size: "", age: "1h"),
        .init(name: "package.json", dir: false, size: "1.4 KB", age: "2d"),
        .init(name: "pnpm-lock.yaml", dir: false, size: "184 KB", age: "2d"),
        .init(name: "README.md", dir: false, size: "5.6 KB", age: "3w"),
        .init(name: "tsconfig.json", dir: false, size: "620 B", age: "3w"),
        .init(name: "vite.config.ts", dir: false, size: "1.1 KB", age: "6d"),
    ]

    static let themeSource = """
    import { useEffect, useState } from "react";

    export type Theme = "light" | "dark" | "system";

    const KEY = "web.theme";

    export function readTheme(): Theme {
      const saved = localStorage.getItem(KEY);
      return saved === "light" || saved === "dark" ? saved : "system";
    }

    export function useTheme() {
      const [theme, setTheme] = useState<Theme>(readTheme);
      useEffect(() => {
        const media = window.matchMedia("(prefers-color-scheme: dark)");
        const apply = () => {
          const dark = theme === "dark" || (theme === "system" && media.matches);
          document.documentElement.classList.toggle("dark", dark);
        };
        apply();
        media.addEventListener("change", apply);
        return () => media.removeEventListener("change", apply);
      }, [theme]);
      return [theme, (next: Theme) => { localStorage.setItem(KEY, next); setTheme(next); }] as const;
    }
    """
}

struct MockChange: Identifiable {
    enum Area: String { case staged = "Staged", unstaged = "Unstaged", untracked = "Untracked" }
    let path: String
    let status: String
    let area: Area
    let add: Int
    let del: Int
    var comments = 0
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { let d = (path as NSString).deletingLastPathComponent; return d.isEmpty ? "" : d + "/" }
}

enum MockGit {
    static let repo = "web"
    static let branch = "dark-mode"
    static let changes: [MockChange] = [
        .init(path: "src/theme.ts", status: "A", area: .staged, add: 31, del: 0),
        .init(path: "src/components/ThemeToggle.tsx", status: "A", area: .staged, add: 48, del: 0, comments: 1),
        .init(path: "src/components/Sidebar.tsx", status: "M", area: .unstaged, add: 14, del: 6, comments: 2),
        .init(path: "src/components/Header.tsx", status: "M", area: .unstaged, add: 5, del: 2),
        .init(path: "src/styles/tokens.css", status: "M", area: .unstaged, add: 22, del: 9),
        .init(path: "src/main.tsx", status: "M", area: .unstaged, add: 3, del: 1),
        .init(path: "tests/theme.test.ts", status: "?", area: .untracked, add: 27, del: 0),
        .init(path: "docs/theming.md", status: "?", area: .untracked, add: 40, del: 0),
    ]
    static var additions: Int { changes.reduce(0) { $0 + $1.add } }
    static var deletions: Int { changes.reduce(0) { $0 + $1.del } }
    static var commentCount: Int { changes.reduce(0) { $0 + $1.comments } }

    struct Line: Identifiable {
        enum Kind { case hunk, context, added, removed }
        let kind: Kind
        let old: Int?
        let new: Int?
        let text: String
        let id = UUID()
    }

    /// Sidebar.tsx's diff: two hunks.
    static let sidebarDiff: [Line] = {
        var out: [Line] = []
        func hunk(_ t: String) { out.append(.init(kind: .hunk, old: nil, new: nil, text: t)) }
        func ctx(_ o: Int, _ n: Int, _ t: String) { out.append(.init(kind: .context, old: o, new: n, text: t)) }
        func add(_ n: Int, _ t: String) { out.append(.init(kind: .added, old: nil, new: n, text: t)) }
        func del(_ o: Int, _ t: String) { out.append(.init(kind: .removed, old: o, new: nil, text: t)) }
        hunk("@@ -1,6 +1,8 @@")
        ctx(1, 1, "import { NavLink } from \"react-router-dom\";")
        ctx(2, 2, "import { useSpaces } from \"../hooks/useSpaces\";")
        add(3, "import { useTheme } from \"../theme\";")
        add(4, "import { ThemeToggle } from \"./ThemeToggle\";")
        ctx(3, 5, "")
        ctx(4, 6, "export function Sidebar() {")
        ctx(5, 7, "  const spaces = useSpaces();")
        add(8, "  const [theme] = useTheme();")
        ctx(6, 9, "")
        hunk("@@ -38,12 +41,18 @@ export function Sidebar() {")
        ctx(38, 41, "  return (")
        del(39, "    <nav className=\"sidebar\">")
        add(42, "    <nav className={`sidebar sidebar--${theme}`}>")
        ctx(40, 43, "      <ul>")
        ctx(41, 44, "        {spaces.map((space) => (")
        del(42, "          <li key={space.id}>")
        del(43, "            <NavLink to={`/s/${space.id}`}>{space.name}</NavLink>")
        add(45, "          <li key={space.id} className={space.unread ? \"unread\" : \"\"}>")
        add(46, "            <NavLink to={`/s/${space.id}`} end>")
        add(47, "              {space.name}")
        add(48, "            </NavLink>")
        ctx(44, 49, "          </li>")
        ctx(45, 50, "        ))}")
        ctx(46, 51, "      </ul>")
        add(52, "      <footer className=\"sidebar__footer\">")
        add(53, "        <ThemeToggle />")
        add(54, "      </footer>")
        ctx(47, 55, "    </nav>")
        ctx(48, 56, "  );")
        ctx(49, 57, "}")
        return out
    }()

    struct Comment: Identifiable {
        let path: String
        let line: Int
        let lineEnd: Int?
        let text: String
        var id: String { "\(path):\(line)" }
    }
    static let comments: [Comment] = [
        .init(path: "src/components/Sidebar.tsx", line: 42, lineEnd: nil,
              text: "Use a data-theme attribute instead of a class per theme, the CSS tokens key off it already."),
        .init(path: "src/components/Sidebar.tsx", line: 45, lineEnd: 48,
              text: "Keep the old markup. The unread class belongs on the link, not the item, and `end` breaks nested routes."),
        .init(path: "src/components/ThemeToggle.tsx", line: 12, lineEnd: nil,
              text: "The system option should be first."),
    ]

    struct Commit: Identifiable {
        let hash: String
        let subject: String
        let author: String
        let age: String
        var refs: [(String, Kind)] = []
        var signed = false
        var lane = 0
        var merge = false
        var files = 0
        var add = 0
        var del = 0
        var body = ""
        var id: String { hash }
        enum Kind { case current, branch, remote, tag }
    }
    static let commits: [Commit] = [
        .init(hash: "c81a2f4", subject: "Sidebar theme toggle and unread rows", author: "Alex Rivera", age: "25m",
              refs: [("dark-mode", .current)], signed: true, files: 4, add: 61, del: 9,
              body: "Moves the theme switch out of Settings into the sidebar footer so it is one tap away.\n\nThe unread state now renders on the row instead of a dot in the link, matching the mobile app."),
        .init(hash: "7d04e9b", subject: "Theme tokens: dark palette and contrast fixes", author: "Alex Rivera", age: "2h",
              signed: true, files: 2, add: 88, del: 14),
        .init(hash: "f3e1c02", subject: "useTheme hook with system preference tracking", author: "Alex Rivera", age: "5h",
              signed: true, files: 3, add: 54, del: 0),
        .init(hash: "9b7ac11", subject: "Merge pull request #212 from web/router-upgrade", author: "Sam Example", age: "1d",
              refs: [("main", .branch), ("origin/main", .remote)], merge: true, files: 11, add: 240, del: 196),
        .init(hash: "2c9d8e0", subject: "Upgrade react-router to v7", author: "Sam Example", age: "1d", lane: 1, files: 9, add: 231, del: 190),
        .init(hash: "e5a4b73", subject: "Fix nested route links losing the active class", author: "Sam Example", age: "2d", lane: 1, files: 2, add: 9, del: 6),
        .init(hash: "41f0d9a", subject: "Release 1.4.0", author: "Alex Rivera", age: "3d", refs: [("v1.4.0", .tag)], signed: true, files: 3, add: 12, del: 4),
        .init(hash: "b0c7e26", subject: "Docs: deployment notes for the preview environment", author: "Priya Example", age: "4d", files: 1, add: 37, del: 2),
        .init(hash: "d7e2f58", subject: "Spaces list: keyboard navigation", author: "Alex Rivera", age: "5d", signed: true, files: 4, add: 73, del: 21),
        .init(hash: "a19c4b3", subject: "CI: cache pnpm store between jobs", author: "Priya Example", age: "6d", files: 1, add: 14, del: 3),
        .init(hash: "6f8b1d2", subject: "Header: collapse search on narrow widths", author: "Alex Rivera", age: "1w", files: 2, add: 28, del: 11),
        .init(hash: "0e3a7c9", subject: "Initial Vite scaffold", author: "Alex Rivera", age: "3w", files: 18, add: 1203, del: 0),
    ]
    static let commitFiles: [MockChange] = [
        .init(path: "src/components/Sidebar.tsx", status: "M", area: .unstaged, add: 14, del: 6),
        .init(path: "src/components/ThemeToggle.tsx", status: "A", area: .unstaged, add: 32, del: 0),
        .init(path: "src/styles/tokens.css", status: "M", area: .unstaged, add: 12, del: 3),
        .init(path: "src/main.tsx", status: "M", area: .unstaged, add: 3, del: 0),
    ]
}
