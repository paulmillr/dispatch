import Foundation

/// The mockup's repository (`mockups/Sources/Data.swift`, MockGit): `dark-mode` with eight changes, Sidebar.tsx's two
/// hunks and the three comments, for the Spaces sample's screenshots (`-DispatchTabsSample`), previews and view tests.
/// Fictional code only.
enum ReviewSample {
    static let branch = "dark-mode"

    /// The changes as `git status` and `--numstat` give them, in the mockup's order.
    static let changes: [GitChange] = [
        GitChange(path: "src/theme.ts", kind: .added, area: .staged, additions: 31, deletions: 0),
        GitChange(path: "src/components/ThemeToggle.tsx", kind: .added, area: .staged, additions: 48, deletions: 0),
        GitChange(path: "src/components/Sidebar.tsx", kind: .modified, area: .unstaged, additions: 14, deletions: 6),
        GitChange(path: "src/components/Header.tsx", kind: .modified, area: .unstaged, additions: 5, deletions: 2),
        GitChange(path: "src/styles/tokens.css", kind: .modified, area: .unstaged, additions: 22, deletions: 9),
        GitChange(path: "src/main.tsx", kind: .modified, area: .unstaged, additions: 3, deletions: 1),
        GitChange(path: "tests/theme.test.ts", kind: .untracked, area: .untracked, additions: 27, deletions: 0),
        GitChange(path: "docs/theming.md", kind: .untracked, area: .untracked, additions: 40, deletions: 0),
    ]

    static func status(now: Date = Date()) -> GitStatus {
        GitStatus(branch: branch, head: "3f2c1a0", upstream: "origin/dark-mode", changes: changes, loadedAt: now)
    }

    // MARK: Files

    /// Sidebar.tsx as it is now (57 lines): the mockup's hunks with the lines between them.
    static let sidebar: [String] = {
        var lines = [
            "import { NavLink } from \"react-router-dom\";",
            "import { useSpaces } from \"../hooks/useSpaces\";",
            "import { useTheme } from \"../theme\";",
            "import { ThemeToggle } from \"./ThemeToggle\";",
            "",
            "export function Sidebar() {",
            "  const spaces = useSpaces();",
            "  const [theme] = useTheme();",
            "",
        ]
        lines += [
            "  const pinned = spaces.filter((space) => space.pinned);",
            "  const others = spaces.filter((space) => !space.pinned);",
            "",
            "  function label(space: { name: string; unread: number }) {",
            "    if (space.unread === 0) return space.name;",
            "    return `${space.name} (${space.unread})`;",
            "  }",
            "",
            "  function onKeyDown(event: React.KeyboardEvent<HTMLElement>) {",
            "    if (event.key !== \"ArrowDown\" && event.key !== \"ArrowUp\") return;",
            "    event.preventDefault();",
            "    const links = Array.from(",
            "      event.currentTarget.querySelectorAll<HTMLAnchorElement>(\"a\"),",
            "    );",
            "    const index = links.indexOf(document.activeElement as HTMLAnchorElement);",
            "    const step = event.key === \"ArrowDown\" ? 1 : -1;",
            "    links[(index + step + links.length) % links.length]?.focus();",
            "  }",
            "",
            "  if (spaces.length === 0) {",
            "    return (",
            "      <nav className=\"sidebar sidebar--empty\">",
            "        <p>No spaces yet.</p>",
            "      </nav>",
            "    );",
            "  }",
            "",
            "  const ordered = [...pinned, ...others];",
            "  void label;",
            "  void onKeyDown;",
            "",
        ]
        lines += [
            "  return (",
            "    <nav className={`sidebar sidebar--${theme}`}>",
            "      <ul>",
            "        {spaces.map((space) => (",
            "          <li key={space.id} className={space.unread ? \"unread\" : \"\"}>",
            "            <NavLink to={`/s/${space.id}`} end>",
            "              {space.name}",
            "            </NavLink>",
            "          </li>",
            "        ))}",
            "      </ul>",
            "      <footer className=\"sidebar__footer\">",
            "        <ThemeToggle />",
            "      </footer>",
            "    </nav>",
            "  );",
            "}",
        ]
        return lines
    }()

    /// Sidebar.tsx's unstaged diff: the mockup's two hunks (their counts as git would print them).
    static let sidebarDiff = """
    diff --git a/src/components/Sidebar.tsx b/src/components/Sidebar.tsx
    index 4b1c2d0..9e8f7a6 100644
    --- a/src/components/Sidebar.tsx
    +++ b/src/components/Sidebar.tsx
    @@ -1,6 +1,9 @@
     import { NavLink } from "react-router-dom";
     import { useSpaces } from "../hooks/useSpaces";
    +import { useTheme } from "../theme";
    +import { ThemeToggle } from "./ThemeToggle";

     export function Sidebar() {
       const spaces = useSpaces();
    +  const [theme] = useTheme();

    @@ -38,12 +41,17 @@ export function Sidebar() {
       return (
    -    <nav className="sidebar">
    +    <nav className={`sidebar sidebar--${theme}`}>
           <ul>
             {spaces.map((space) => (
    -          <li key={space.id}>
    -            <NavLink to={`/s/${space.id}`}>{space.name}</NavLink>
    +          <li key={space.id} className={space.unread ? "unread" : ""}>
    +            <NavLink to={`/s/${space.id}`} end>
    +              {space.name}
    +            </NavLink>
               </li>
             ))}
           </ul>
    +      <footer className="sidebar__footer">
    +        <ThemeToggle />
    +      </footer>
         </nav>
       );
     }

    """

    static let themeToggle: [String] = [
        "import { useTheme, type Theme } from \"../theme\";",
        "",
        "const labels: Record<Theme, string> = {",
        "  light: \"Light\",",
        "  dark: \"Dark\",",
        "  system: \"System\",",
        "};",
        "",
        "/** The sidebar footer's switch: light, dark, or the system's choice. */",
        "type Props = { compact?: boolean };",
        "",
        "const options = [\"light\", \"dark\", \"system\"];",
        "",
        "export function ThemeToggle({ compact = false }: Props) {",
        "  const [theme, setTheme] = useTheme();",
        "  return (",
        "    <div className=\"theme-toggle\" role=\"radiogroup\" aria-label=\"Theme\">",
        "      {options.map((option) => (",
        "        <button",
        "          key={option}",
        "          type=\"button\"",
        "          role=\"radio\"",
        "          aria-checked={theme === option}",
        "          className={theme === option ? \"selected\" : \"\"}",
        "          onClick={() => setTheme(option as Theme)}",
        "        >",
        "          {compact ? labels[option as Theme][0] : labels[option as Theme]}",
        "        </button>",
        "      ))}",
        "    </div>",
        "  );",
        "}",
        "",
        "export function ThemeBadge() {",
        "  const [theme] = useTheme();",
        "  return <span className=\"theme-badge\">{labels[theme]}</span>;",
        "}",
        "",
        "export function useDarkClass(element: HTMLElement | null) {",
        "  const [theme] = useTheme();",
        "  if (!element) return;",
        "  element.classList.toggle(\"dark\", theme === \"dark\");",
        "}",
        "",
        "export function nextTheme(theme: Theme): Theme {",
        "  return theme === \"light\" ? \"dark\" : theme === \"dark\" ? \"system\" : \"light\";",
        "}",
    ]

    static let theme: [String] = [
        "import { useEffect, useState } from \"react\";",
        "",
        "export type Theme = \"light\" | \"dark\" | \"system\";",
        "",
        "const KEY = \"web.theme\";",
        "",
        "export function readTheme(): Theme {",
        "  const saved = localStorage.getItem(KEY);",
        "  return saved === \"light\" || saved === \"dark\" ? saved : \"system\";",
        "}",
        "",
        "export function useTheme() {",
        "  const [theme, setTheme] = useState<Theme>(readTheme);",
        "  useEffect(() => {",
        "    const media = window.matchMedia(\"(prefers-color-scheme: dark)\");",
        "    const apply = () => {",
        "      const dark = theme === \"dark\" || (theme === \"system\" && media.matches);",
        "      document.documentElement.classList.toggle(\"dark\", dark);",
        "    };",
        "    apply();",
        "    media.addEventListener(\"change\", apply);",
        "    return () => media.removeEventListener(\"change\", apply);",
        "  }, [theme]);",
        "  return [theme, (next: Theme) => { localStorage.setItem(KEY, next); setTheme(next); }] as const;",
        "}",
        "",
        "export function isDark(theme: Theme, media: MediaQueryList): boolean {",
        "  return theme === \"dark\" || (theme === \"system\" && media.matches);",
        "}",
        "",
        "export const themes: Theme[] = [\"light\", \"dark\", \"system\"];",
    ]

    /// A file's text as it is now (absolute paths under any root; matched by the repository-relative end).
    static func text(_ path: String) -> String? {
        let lines: [String]
        if path.hasSuffix("src/components/Sidebar.tsx") { lines = sidebar }
        else if path.hasSuffix("src/components/ThemeToggle.tsx") { lines = themeToggle }
        else if path.hasSuffix("src/theme.ts") { lines = theme }
        else if let change = changes.first(where: { path.hasSuffix($0.path) }) { lines = filler(change) }
        else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Lines for a change the mockup does not draw, as many as it adds.
    private static func filler(_ change: GitChange) -> [String] {
        let name = change.name
        if name.hasSuffix(".md") {
            return ["# Theming", ""] + (0..<38).map { "Line \($0 + 1) of the theming notes: tokens, the dark class and the toggle." }
        }
        if name.hasSuffix(".css") {
            return [":root {"] + (0..<30).map { "  --token-\($0 + 1): var(--base-\($0 % 6 + 1));" } + ["}"]
        }
        return (0..<max(6, change.additions ?? 6)).map { "export const value\($0 + 1) = \($0 + 1);" }
    }

    /// A change's diff: Sidebar.tsx's hunks; an added or untracked file as all additions; the rest a small hunk.
    static func diff(_ change: GitChange) -> GitDiff {
        if change.path == "src/components/Sidebar.tsx", change.area == .unstaged {
            return GitDiff(path: change.path, text: sidebarDiff)
        }
        let lines = text(change.path).map { ReviewRefresh.lines($0) } ?? []
        if change.kind == .added || change.area == .untracked {
            var text = "diff --git a/\(change.path) b/\(change.path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(change.path)\n"
            text += "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 + "\n" }.joined()
            return GitDiff(path: change.path, text: text)
        }
        let removed = change.deletions ?? 1, added = change.additions ?? 1
        var text = "diff --git a/\(change.path) b/\(change.path)\n--- a/\(change.path)\n+++ b/\(change.path)\n"
        text += "@@ -1,\(removed + 1) +1,\(added + 1) @@\n"
        text += (0..<removed).map { "-old line \($0 + 1)\n" }.joined()
        text += lines.prefix(added).map { "+" + $0 + "\n" }.joined()
        text += " " + (lines.dropFirst(added).first ?? "") + "\n"
        return GitDiff(path: change.path, text: text)
    }

    // MARK: Comments

    /// The mockup's three comments (MockGit.comments), written minutes before `now`.
    static func comments(now: Date = Date()) -> [ReviewComment] {
        func line(_ number: Int) -> ReviewLine { ReviewLine(side: .new, number: number) }
        let sidebarPath = "src/components/Sidebar.tsx"
        return [
            ReviewComment(id: UUID(uuidString: "00000000-0000-0000-0000-0000000C0001")!, path: sidebarPath,
                          start: line(42), end: line(42), quote: [ReviewQuote(kind: .added, text: sidebar[41])],
                          text: "Use a data-theme attribute instead of a class per theme, the CSS tokens key off it already.",
                          created: now.addingTimeInterval(-120), area: .unstaged),
            ReviewComment(id: UUID(uuidString: "00000000-0000-0000-0000-0000000C0002")!, path: sidebarPath,
                          start: line(45), end: line(48), quote: sidebar[44...47].map { ReviewQuote(kind: .added, text: $0) },
                          text: "Keep the old markup. The unread class belongs on the link, not the item, and `end` breaks nested routes.",
                          created: now.addingTimeInterval(-90), area: .unstaged),
            ReviewComment(id: UUID(uuidString: "00000000-0000-0000-0000-0000000C0003")!, path: "src/components/ThemeToggle.tsx",
                          start: line(12), end: line(12), quote: [ReviewQuote(kind: .added, text: themeToggle[11])],
                          text: "The system option should be first.", created: now.addingTimeInterval(-60), area: .staged),
        ]
    }

    /// S5's comment whose lines left the file: written on Sidebar.tsx's lines 12–14 before they changed.
    static func outdated(now: Date = Date()) -> ReviewComment {
        ReviewComment(id: UUID(uuidString: "00000000-0000-0000-0000-0000000C0004")!, path: "src/components/Sidebar.tsx",
                      start: ReviewLine(side: .new, number: 12), end: ReviewLine(side: .new, number: 14),
                      quote: [ReviewQuote(kind: .added, text: "  const media = window.matchMedia(\"(prefers-color-scheme: dark)\");"),
                              ReviewQuote(kind: .added, text: "  const [dark, setDark] = useState(media.matches);"),
                              ReviewQuote(kind: .added, text: "  useEffect(() => setDark(media.matches), [media]);")],
                      text: "Listen for the media change too; the toggle shows stale state after a system switch.",
                      created: now.addingTimeInterval(-600), area: .unstaged)
    }

    /// A reader answering with this repository, whatever the host and root.
    static var reader: ReviewGitReader {
        ReviewGitReader(status: { _ in status() }, diff: { _, change in diff(change) }, text: { text($0) })
    }
}
