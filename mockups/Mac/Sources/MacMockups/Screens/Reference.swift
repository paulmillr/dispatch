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
                ])) { TerminalScreen(lines: Sample.gitLog) }
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
                    Pane(strip: StripModel(tabs: [TabItem(title: "app", selected: true)], layout: nil, paneBadge: 1, focused: false)) {
                        TerminalScreen(lines: Sample.tests, focused: false)
                    }
                } second: {
                    // With splits ⌘1 and ⌘2 focus the panes: one tab per pane shows no key.
                    Pane(strip: StripModel(tabs: [TabItem(title: "Refactor billing", activity: .working, selected: true)],
                                           mode: .chat, agent: true, layout: .columns, paneBadge: 2), focusEdge: true) {
                        // The live turn: its group shows the step the agent is on; the footer says what it does.
                        ChatPane(items: [Sample.chat[0], Sample.chat[1], .tools(Array(Sample.steps.prefix(3)))],
                                 composer: ComposerModel(working: ("working", "38s")), live: true)
                    }
                }
            }
        },
        Screen("K4-menu-sheet", group: "kit", "A sheet over the window, and a menu") {
            HStack(alignment: .top, spacing: 40) {
                SheetOver {
                    DispatchWindow(width: 760, height: 520, sidebar: SidebarModel(spaces: Array(Sample.sidebar.spaces.prefix(2)), width: 220)) {
                        Pane(strip: StripModel(tabs: [TabItem(title: "app", shortcut: 1, selected: true)])) { TerminalScreen(lines: Sample.tests) }
                    }
                } sheet: {
                    MacWindow(width: 420, height: 220, lights: false) { ControlsSample(compact: true) }.shadow(radius: 0)
                }
                // The app's File menu (AppDelegate+Menus), its items without images.
                MacMenu(items: [
                    MenuItem(title: "New Space", shortcut: "⌘N"),
                    MenuItem(title: "New Local Space", shortcut: "⇧⌘N"),
                    MenuItem(title: "New Tab", shortcut: "⌘T", highlighted: true),
                    nil,
                    MenuItem(title: "Rename Space…"),
                    MenuItem(title: "Rename Tab…"),
                    nil,
                    MenuItem(title: "Close Tab", shortcut: "⌘W"),
                    MenuItem(title: "Close Space", shortcut: "⇧⌘W"),
                    MenuItem(title: "Detach Session"),
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
                            "Last login: Thu Jan  1 00:00:16 on ttys017",
                            "printf 'THEME_%s\\n' READY",
                            "user@test home % printf 'THEME_%s\\n' READY",
                            "THEME_READY",
                            "user@test home % ",
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
    /// At the app's defaults: no branches (Settings › Show git branches is off).
    static let sidebar = SidebarModel(spaces: [
        SpaceItem(name: "app", activity: .finished, shortcut: 1, selected: true),
        SpaceItem(name: "docs", shortcut: 2),
        SpaceItem(name: "billing", host: Hosts.buildBox, activity: .waiting, shortcut: 3),
        SpaceItem(name: "e2e", host: Hosts.buildBox, activity: .working, shortcut: 4),
        SpaceItem(name: "release", host: Hosts.studio, shortcut: 5),
    ])

    /// The branch's history and a test run: git's own colours (yellow hashes, cyan HEAD, green and red branches, a
    /// coloured graph) and a pass, so each theme's palette shows. 50 columns at most, for the narrow theme window.
    static let gitLog: [TermLine] = [
        .prompt("git log --oneline --graph -5"),
        T("* ", c(3, "9f2c1ab "), c(3, "("), c(6, "HEAD -> ", bold: true), c(2, "dark-mode", bold: true), c(3, ")"), " High-contrast rows"),
        T("* ", c(3, "41d7e09"), " Contrast ratios for every palette"),
        T(c(1, "|"), " * ", c(3, "c83a2f4 ("), c(1, "origin/main", bold: true), c(3, ", "), c(2, "main", bold: true), c(3, ")"), " Invoice rounding"),
        T(c(1, "|"), c(2, "/")),
        T("* ", c(3, "07be3d1"), " Host discs in group headings"),
        .prompt("swift test"),
        T(c(2, "✔"), " Test run with 214 tests passed after 3.8 seconds."),
        .prompt(),
    ]

    /// The invoice fix's tests, one still failing: the zero-amount case the agent is asked to cover next. Swift
    /// Testing's output, its symbols coloured.
    static let tests: [TermLine] = [
        .prompt("swift test --filter InvoiceTests"),
        "Building for debugging...",
        T(c(2, "Build complete!"), " (2.31s)"),
        T(c(8, "◇"), " Test run started."),
        T(c(2, "✔"), " Test roundsOncePerInvoice() passed."),
        T(c(2, "✔"), " Test threeLinesOfOneThird() passed."),
        T(c(1, "✘"), " Test zeroAmount() recorded an issue:"),
        T("  Expectation failed: ", c(1, "total → 0.01"), " == 0.00"),
        T(c(1, "✘"), " Test run with 12 tests failed with 1 issue."),
        .prompt(failed: true),
    ]

    /// A tab named "server" (the herdr pair): the app's dev server and its requests, status codes coloured.
    static let server: [TermLine] = [
        .prompt("swift run Server"),
        "Building for debugging...",
        T(c(2, "Build complete!"), " (1.84s)"),
        T(c(8, "[Server]"), " Listening on ", c(4, "http://localhost:8080")),
        T(c(6, "GET "), " /invoices          ", c(2, "200"), c(8, "   12ms")),
        T(c(6, "GET "), " /invoices/1042     ", c(2, "200"), c(8, "    4ms")),
        T(c(5, "POST"), " /invoices/1042     ", c(3, "422"), c(8, "    9ms"), "  rounding mismatch"),
        T(c(6, "GET "), " /invoices/1042     ", c(2, "200"), c(8, "    3ms")),
        T(c(6, "GET "), " /health            ", c(2, "200"), c(8, "    1ms")),
    ]

    /// One turn as the agent ran it: a word before its steps (which join that message's bubble), then the reply.
    static let chat: [ChatItem] = [
        .user("Invoices round each line before summing, so totals drift by a cent. Fix it?"),
        .agent("Looking at where `Invoice` rounds its lines.", time: "10:16"),
        .tools(steps),
        .agent("Totals now sum the exact amounts and round once, half-even, in `Invoice.total`. Line items still show their rounded amounts. `InvoiceTests` passes, with a new case for three lines of 0.333.", time: "10:17"),
    ]

    /// The turn's steps, titled and summarised as ToolPresentation does (Grep → Search "pattern · in path", Read and a
    /// patch the file's name, a command → Shell), with the symbols it gives them.
    static let steps: [ToolStep] = [
        ToolStep(symbol: "magnifyingglass", title: "Search", summary: "round( · in Sources/Billing", seconds: 2),
        ToolStep(symbol: "doc.text", title: "Read", summary: "Invoice.swift", seconds: 1),
        ToolStep(symbol: "pencil.line", title: "Patch", summary: "Invoice.swift", added: 9, removed: 4, seconds: 3, kind: .edit),
        ToolStep(symbol: "terminal", title: "Shell", summary: "swift test --filter InvoiceTests", seconds: 14),
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
