import SwiftUI

/// The kit's own screens: what the shared pieces draw, to check them against the app (K9 against its capture) and to
/// copy from when starting a topic.
enum Reference {
    static let screens: [Screen] = [
        Screen("K0-controls", group: "kit", "Real AppKit controls in a window") {
            MacWindow(width: 520, height: 330) { ControlsSample() }
        },
        Screen("K1-main-terminal", group: "kit", "Main window: sidebar, strip, terminal") {
            DispatchWindow(sidebar: Sample.sidebar) {
                Pane(strip: StripModel(tabs: [
                    TabItem(title: "app", shortcut: 1, selected: true),
                    TabItem(title: "tests", activity: .working, shortcut: 2),
                    TabItem(title: "~", shortcut: 3),
                ])) { TerminalScreen(lines: Sample.gitStatus) }
            }
        },
        Screen("K2-main-chat", group: "kit", "Main window: an agent's chat") {
            DispatchWindow(sidebar: Sample.sidebar) {
                Pane(strip: StripModel(tabs: [
                    TabItem(title: "Fix the invoice rounding", activity: .finished, shortcut: 1, selected: true),
                    TabItem(title: "tests", shortcut: 2),
                ], mode: .chat, agent: true)) {
                    ChatPane(items: Sample.chat, composer: ComposerModel(draft: "Also cover the zero-amount case"))
                }
            }
        },
        Screen("K3-split", group: "kit", "Two panes: terminal and a working agent, tree sidebar") {
            DispatchWindow(sidebar: SidebarModel(spaces: Sample.sidebar.spaces, tree: true)) {
                Split(fraction: 0.5) {
                    Pane(strip: StripModel(tabs: [TabItem(title: "app", shortcut: 1, selected: true)], layout: nil, paneBadge: 1, focused: false)) {
                        TerminalScreen(lines: Sample.gitStatus, cursor: false)
                    }
                } second: {
                    Pane(strip: StripModel(tabs: [TabItem(title: "Refactor billing", activity: .working, shortcut: 2, selected: true)],
                                           mode: .chat, agent: true, layout: .columns, paneBadge: 2), focusEdge: true) {
                        ChatPane(items: Array(Sample.chat.prefix(2)) + [.working("editing invoice.ts", time: "38s")],
                                 composer: ComposerModel(working: ("editing", "38s")))
                    }
                }
            }
        },
        Screen("K4-menu-sheet", group: "kit", "A sheet over the window, and a menu") {
            HStack(alignment: .top, spacing: 40) {
                SheetOver {
                    DispatchWindow(width: 760, height: 520, sidebar: SidebarModel(spaces: Array(Sample.sidebar.spaces.prefix(2)), width: 220)) {
                        Pane(strip: StripModel(tabs: [TabItem(title: "app", shortcut: 1, selected: true)])) { TerminalScreen(lines: Sample.gitStatus) }
                    }
                } sheet: {
                    MacWindow(width: 420, height: 220, lights: false) { ControlsSample(compact: true) }.shadow(radius: 0)
                }
                MacMenu(items: [
                    MenuItem(title: "New Tab", symbol: "plus", shortcut: "⌘T"),
                    MenuItem(title: "New Chat", symbol: "text.bubble", shortcut: "⌥⌘T", highlighted: true),
                    nil,
                    MenuItem(title: "Layout", symbol: "square.split.2x2", submenu: true),
                    MenuItem(title: "Show Files", symbol: "folder", checked: true),
                    nil,
                    MenuItem(title: "Close Tab", symbol: "xmark", shortcut: "⌘W", enabled: false),
                ])
                .padding(.top, 80)
            }
        },
        // The app's own capture (DispatchTests/MainMockupPresentationTests → build/ui-audit/main-sidebar-*.png), redrawn:
        // compare the two at the same size to check the kit.
        Screen("K9-calibrate-main", group: "kit", "The app's main-sidebar capture, redrawn", staged: false) {
            MacWindow(width: 1180, height: 740, lights: false) {
                HStack(spacing: 0) {
                    Sidebar(model: SidebarModel(spaces: [SpaceItem(name: "api-refactor", shortcut: 1, selected: true)]))
                    Rectangle().fill(Chrome.palette.sidebarDivider).frame(width: 1)
                    Pane(strip: StripModel(tabs: [TabItem(title: "~", shortcut: 1), TabItem(title: "home", shortcut: 2, selected: true)])) {
                        TerminalScreen(lines: [
                            "printf 'THEME_%s\\n' READY",
                            "Last login: Mon Nov  2 21:09:48 on ttys017",
                            "printf 'THEME_%s\\n' READY",
                            "user@mini home % printf 'THEME_%s\\n' READY",
                            "THEME_READY",
                            "user@mini home % ",
                        ])
                    }
                    .background(Chrome.palette.terminal)
                }
            }
            .shadow(radius: 0)
        },
    ]
}

/// Sample content the screens share: fictional hosts, spaces and work.
enum Sample {
    static let sidebar = SidebarModel(spaces: [
        SpaceItem(name: "app", branch: "dark-mode", activity: .finished, shortcut: 1, selected: true),
        SpaceItem(name: "docs", shortcut: 2),
        SpaceItem(name: "billing", host: Hosts.buildBox, branch: "fix/invoices", activity: .waiting, shortcut: 3),
        SpaceItem(name: "e2e", host: Hosts.buildBox, activity: .working, shortcut: 4),
        SpaceItem(name: "release", host: Hosts.studio, shortcut: 5),
    ])

    static let gitStatus: [TermLine] = [
        .prompt("git status"),
        T("On branch ", c(2, "dark-mode")),
        "Your branch is up to date with 'origin/dark-mode'.",
        "",
        "Changes not staged for commit:",
        T("        ", c(1, "modified:   Sources/Theme/Palette.swift")),
        T("        ", c(1, "modified:   Sources/Views/Sidebar.swift")),
        "",
        "Untracked files:",
        T("        ", c(1, "Sources/Theme/Contrast.swift")),
        "",
        .prompt(),
    ]

    static let chat: [ChatItem] = [
        .user("Invoices round each line before summing, so totals drift by a cent. Fix it?"),
        .tools([
            ToolStep(symbol: "magnifyingglass", title: "Search", summary: "round( in Sources/Billing", time: "0.4s"),
            ToolStep(symbol: "doc.text", title: "Read", summary: "Sources/Billing/Invoice.swift", time: "0.1s"),
            ToolStep(symbol: "pencil", title: "Edit", summary: "Sources/Billing/Invoice.swift", added: 9, removed: 4, time: "1.2s"),
            ToolStep(symbol: "terminal", title: "Run", summary: "swift test --filter InvoiceTests", time: "14s"),
        ]),
        .agent("Totals now sum the exact amounts and round once, half-even, in `Invoice.total`. Line items still show their rounded amounts. `InvoiceTests` passes, with a new case for three lines of 0.333.", time: "10:17"),
        .worked("worked for 1m 12s"),
    ]
}

private struct ControlsSample: View {
    var compact = false
    @State private var on = true
    @State private var host = "alex@build-box"
    @State private var mode = 1
    var body: some View {
        Form {
            Toggle("Connect at launch", isOn: $on)
            if !compact {
                Toggle("Color-code remote hosts", isOn: $on).toggleStyle(.switch)
            }
            TextField("Destination", text: $host)
            if !compact {
                Picker("Open in", selection: $mode) { Text("Terminal").tag(0); Text("Chat").tag(1); Text("Files").tag(2) }
                    .pickerStyle(.segmented)
                Picker("Shell", selection: $mode) { Text("zsh").tag(0); Text("bash").tag(1); Text("fish").tag(2) }
            }
            HStack { Spacer(); Button("Cancel") {}; Button("Connect") {}.keyboardShortcut(.defaultAction) }
        }
        .formStyle(.grouped)
        .padding(.top, compact ? 0 : 36)
    }
}
