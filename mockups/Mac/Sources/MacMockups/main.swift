import AppKit

// Mac mockups: python3 mockups/shoot.py mac … builds this and runs it (mockups/README.md, Mac).
//
//   MacMockups list                              ids, groups and titles
//   MacMockups render [options] [selector…]      shots/mac/<id>-<theme>.png; no selector: every screen
//   MacMockups sheets [options] [group…]         sheets/mac-<group>-<theme>.png from the shots
//
// A selector is an id (M1-main), an id's leading part before its dash (M1), or a group (main).
// Options: --themes dark,light (also graphite, lavender, nautical) · --font system|code (Source Code Pro interface)
//          --size 14 (Settings › Font size) · --flat (no Liquid Glass) · --scale 2 · --out <dir>
//          --scheme "Catppuccin Latte" (a bundled terminal scheme instead of dispatch-black; adds it to the file name)

let usage = """
usage: MacMockups list | render [--themes dark,light] [--font system|code] [--size 14] [--flat] [--scale 2] [--out DIR] [--scheme NAME] [selector…]
                       | sheets [--themes dark,light] [group…]
"""

func parse(_ arguments: ArraySlice<String>) throws -> (RenderOptions, [String]) {
    var options = RenderOptions(), rest: [String] = [], arguments = arguments
    while let argument = arguments.popFirst() {
        func value() throws -> String {
            guard let next = arguments.popFirst() else { throw Failure("\(argument) needs a value") }
            return next
        }
        switch argument {
        case "--themes", "--theme":
            options.themes = try value().split(separator: ",").map {
                guard let theme = SidebarTheme(rawValue: String($0)) else { throw Failure("unknown theme \($0)") }
                return theme
            }
        case "--font": options.interfaceFont = try value() == "code" ? .sourceCodePro : .system
        case "--size": options.contentSize = CGFloat(Double(try value()) ?? 14)
        case "--scale": options.scale = CGFloat(Double(try value()) ?? 2)
        case "--out": options.output = URL(fileURLWithPath: try value())
        case "--flat": options.glass = false
        case "--scheme":
            let name = try value()
            let found = ["../Vendor/Term/Resources/ghostty/themes/", "../extras/ghostty/"].contains {
                FileManager.default.fileExists(atPath: Paths.mockups.appendingPathComponent($0 + name).path)
            }
            if !found { throw Failure("unknown scheme \(name): see Vendor/Term/Resources/ghostty/themes") }
            options.scheme = name
        default:
            if argument.hasPrefix("--") { throw Failure("unknown option \(argument)") }
            rest.append(argument)
        }
    }
    return (options, rest)
}

func select(_ selectors: [String]) throws -> [Screen] {
    let all = Screens.all
    guard !selectors.isEmpty else { return all }
    return try selectors.flatMap { selector in
        let found = all.filter { $0.id == selector || $0.group == selector || $0.id.hasPrefix(selector + "-") }
        if found.isEmpty { throw Failure("no screen or group \(selector); see `list`") }
        return found
    }
}

MainActor.assumeIsolated {
    let app = MockApplication.shared
    app.setActivationPolicy(.prohibited)
    let arguments = CommandLine.arguments.dropFirst()
    do {
        guard let command = arguments.first else { print(usage); exit(2) }
        let (options, rest) = try parse(arguments.dropFirst())
        let ids = Screens.all.map(\.id)
        if let duplicate = ids.first(where: { id in ids.filter { $0 == id }.count > 1 }) { throw Failure("duplicate id \(duplicate)") }
        switch command {
        case "list":
            for screen in Screens.all { print(screen.id.padding(toLength: 28, withPad: " ", startingAt: 0) + screen.group.padding(toLength: 14, withPad: " ", startingAt: 0) + screen.title) }
        case "render":
            for screen in try select(rest) {
                for theme in options.themes {
                    let url = try Renderer.render(screen, theme: theme, options: options)
                    print(url.path)
                }
            }
        case "sheets":
            let groups = rest.isEmpty ? Screens.all.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } : rest
            for group in groups {
                let screens = Screens.all.filter { $0.group == group }
                if screens.isEmpty { throw Failure("no group \(group)") }
                for theme in options.themes {
                    let url = Paths.sheets.appendingPathComponent("mac-\(group)-\(theme.rawValue).png")
                    try ContactSheet.write(screens, theme: theme, from: options.output, to: url)
                    print(url.path)
                }
            }
        default:
            print(usage); exit(2)
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
