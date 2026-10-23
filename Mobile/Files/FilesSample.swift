#if DEBUG
import Foundation

/// The Spaces sample's files (`-DispatchTabsSample`; H1, F2, I6): a fictional web app under every sample tab's folder,
/// answered in process with the mockup's names, sizes and ages, and git's status of its changes. `-DispatchFilesFolder
/// src` opens the listing in that folder below the tab's, `-DispatchFilesPreview src/theme.ts` pushes that file.
final class FilesSample: MobileFilesSource, @unchecked Sendable {
    struct Node {
        var name: String
        var size: UInt64 = 0
        /// Minutes before now.
        var age: Double
        var children: [Node]? = nil
        var text: String? = nil
    }

    private let now: Date
    private let tree: Node

    init(now: Date = Date()) {
        self.now = now
        tree = Self.app
    }

    static let shared = FilesSample()

    func list(_ path: String, hidden: Bool) async throws -> FileListing {
        guard let node = node(path) else { throw FilesSourceError.notFound(path) }
        guard let children = node.children else { throw FilesSourceError.notDirectory(path) }
        let entries = children.filter { hidden || !$0.name.hasPrefix(".") }.map { child in
            FileEntry(name: child.name, kind: child.children == nil ? .file : .directory, size: child.children == nil ? size(child) : 0,
                      modified: now.addingTimeInterval(-child.age * 60), targetKind: nil)
        }
        return FileListing(path: path, entries: entries.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }, truncated: false)
    }

    func read(_ path: String, offset: UInt64, length: UInt64, revision: FileRevision?) async throws -> (data: Data, revision: FileRevision) {
        guard let node = node(path) else { throw FilesSourceError.notFound(path) }
        guard node.children == nil else { throw FilesSourceError.unsupported("A folder has no bytes to read") }
        let data = bytes(node)
        let stamp = String(Int64(now.addingTimeInterval(-node.age * 60).timeIntervalSince1970) * 1_000_000_000)
        let current = FileRevision(kind: .file, size: UInt64(data.count), device: 1, inode: UInt64(abs(path.hashValue) % 100_000),
                                   modifiedNs: stamp, changedNs: stamp)
        let start = Int(min(offset, UInt64(data.count)))
        let end = Int(min(UInt64(data.count), offset + length))
        return (data.subdata(in: start..<end), current)
    }

    func git(_ path: String, args: [String], limit: UInt64) async throws -> GitOutput {
        guard args.first == "status" else { return GitOutput(status: 128, output: "fatal: not supported here", truncated: false) }
        // The mockup's review: theme.ts and ThemeToggle.tsx added, Sidebar, Header, tokens.css and main.tsx changed, two untracked.
        let records = [
            "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 src/theme.ts",
            "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 2222222222222222222222222222222222222222 src/components/ThemeToggle.tsx",
            "1 .M N... 100644 100644 100644 3333333333333333333333333333333333333333 3333333333333333333333333333333333333333 src/components/Sidebar.tsx",
            "1 .M N... 100644 100644 100644 4444444444444444444444444444444444444444 4444444444444444444444444444444444444444 src/main.tsx",
            "? tests/theme.test.ts",
            "? docs/theming.md",
        ]
        return GitOutput(status: 0, output: records.joined(separator: "\0") + "\0", truncated: false)
    }

    private func node(_ path: String) -> Node? {
        // Every sample folder holds the same app: the path below the tab's folder decides.
        let parts = path.split(separator: "/").map(String.init)
        guard let start = parts.firstIndex(where: { ["app", "web", "e2e", "docs", "billing", "curves"].contains($0) }) else {
            return parts.isEmpty ? Node(name: "/", age: 0, children: [tree]) : nil
        }
        var node = tree
        for part in parts[(start + 1)...] {
            guard let child = node.children?.first(where: { $0.name == part }) else { return nil }
            node = child
        }
        return node
    }

    private func bytes(_ node: Node) -> Data {
        if let text = node.text { return Data(text.utf8) }
        let line = "// \(node.name): fictional sample content\n"
        return Data(String(repeating: line, count: max(1, Int(node.size) / line.utf8.count)).utf8.prefix(Int(node.size)))
    }

    private func size(_ node: Node) -> UInt64 { node.text.map { UInt64($0.utf8.count) } ?? node.size }

    private static func file(_ name: String, _ size: UInt64, _ age: Double, text: String? = nil) -> Node {
        Node(name: name, size: size, age: age, text: text)
    }

    private static func folder(_ name: String, _ age: Double, _ children: [Node]) -> Node {
        Node(name: name, age: age, children: children)
    }

    private static let app = folder("app", 4, [
        folder("src", 4, [
            folder("components", 4, [
                file("Sidebar.tsx", 3_400, 4), file("ThemeToggle.tsx", 1_500, 4), file("Header.tsx", 2_100, 25),
            ]),
            folder("hooks", 25, [file("useMedia.ts", 640, 25), file("useStorage.ts", 880, 2_880)]),
            folder("routes", 2_880, [
                file("index.tsx", 1_200, 2_880), file("settings.tsx", 2_600, 2_880), file("billing.ts", 3_900, 2_880),
                file("invoices.ts", 2_200, 2_880), file("account.tsx", 1_700, 2_880), file("login.tsx", 1_100, 2_880),
            ]),
            folder("styles", 25, [file("tokens.css", 2_300, 25), file("global.css", 1_100, 8_640)]),
            file("app.tsx", 2_400, 2_880),
            file("main.tsx", 912, 2_880),
            file("theme.ts", 1_800, 25, text: themeSource),
            file("types.d.ts", 3_100, 8_640),
            file("vite-env.d.ts", 38, 30_240, text: "/// <reference types=\"vite/client\" />\n"),
        ]),
        folder("docs", 60, [file("theming.md", 1_400, 60, text: themingDoc)]),
        folder("public", 20_160, [file("logo.png", 18_400, 20_160)]),
        folder("tests", 30, [file("theme.test.ts", 1_100, 30)]),
        file(".gitignore", 64, 40_320),
        file("README.md", 2_200, 10_080, text: themingDoc),
        file("package.json", 1_300, 2_880, text: "{\n  \"name\": \"web\",\n  \"private\": true,\n  \"type\": \"module\"\n}\n"),
        file("vite.config.ts", 420, 30_240),
    ])

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

    static let themingDoc = """
        # Theming

        The app follows the **system** appearance unless the user picks *light* or *dark* in the sidebar.

        - `useTheme()` keeps the choice in `localStorage`.
        - The `dark` class on the root switches the tokens in `styles/tokens.css`.

        ```ts
        const [theme, setTheme] = useTheme();
        ```

        """
}
#endif
