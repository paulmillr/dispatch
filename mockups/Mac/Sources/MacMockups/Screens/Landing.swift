import SwiftUI

// Screens for the landing page (dispatch.yachts, the gh-pages branch): the terminal with the sidebar hidden, for the
// theme picker (render with `--scheme`), and herdr in a plain terminal beside the same session in Dispatch.

enum Landing {
    static let screens: [Screen] = [
        // Just around its content, so it shows whole on a phone: Sample.gitLog's longest line (50 columns) and 9 rows.
        Screen("L1-terminal", group: "landing", "The terminal, sidebar hidden, phone-sized") {
            DispatchWindow(width: 480, height: 240, sidebar: nil) {
                Pane(strip: StripModel(tabs: [
                    TabItem(title: "app", shortcut: 1, selected: true),
                    TabItem(title: "~", shortcut: 2),
                ], layout: nil, titleRow: true, otherSpaces: true)) { TerminalScreen(lines: Sample.gitLog) }
            }
        },
        Screen("L2-herdr", group: "landing", "herdr 0.9.5 in a plain terminal: its workspaces and tabs drawn in text") {
            PlainTerminalWindow(width: size.width, height: size.height, title: "app — herdr — 100×24") {
                CapturedScreen(rows: HerdrCapture.rows)
            }
        },
        Screen("L3-herdr-dispatch", group: "landing", "The same herdr session in Dispatch: workspaces as spaces, tabs as tabs") {
            // Settings › Show git branches on (off by default), so the spaces show the branches herdr's list does.
            DispatchWindow(width: size.width, height: size.height, sidebar: SidebarModel(spaces: [
                SpaceItem(name: "app", branch: "dark-mode", shortcut: 1, selected: true),
                SpaceItem(name: "billing", branch: "fix/invoices", shortcut: 2),
                SpaceItem(name: "docs", branch: "main", shortcut: 3),
            ])) {
                Pane(strip: StripModel(tabs: [
                    TabItem(title: "server", shortcut: 1, selected: true),
                    TabItem(title: "tests", shortcut: 2),
                    TabItem(title: "claude", shortcut: 3),
                ], layout: nil)) {
                    // The server still running: no prompt after it.
                    TerminalScreen(lines: Sample.server, cursor: false)
                }
            }
        },
        Screen("L4-claude-terminal", group: "landing", "Claude Code in the terminal, as it draws itself") {
            claude(.terminal) { TerminalScreen(lines: claudeScreen, cursor: false) }
        },
        Screen("L5-claude-chat", group: "landing", "The same Claude Code session in chat mode") {
            claude(.chat) {
                // The steps opened (a click on the group's header), to set beside L4's tool calls.
                ChatPane(items: Sample.chat.map { item in
                    if case .tools(let steps, _) = item { return .tools(steps, shown: .all) } else { return item }
                }, composer: ComposerModel(draft: "Also cover the zero-amount case"))
            }
        },
        // The app's own ThemeMakerView (linked, App/), as Settings › Theme's New color scheme sheet shows it.
        Screen("L6-theme-creator", group: "landing", "The theme creator: a scheme grown from one color") {
            MacWindow(width: 620, height: 586, lights: false) {
                // The default recipe with the triadic harmony: three hues a third of the wheel apart.
                ThemeMakerView(initial: { var recipe = ThemeRecipe.standard; recipe.harmony = .triadic; return recipe }(),
                               save: { _, _ in }, cancel: {})
            }
        },
    ]

    /// L4 and L5: one tab with Claude Code, sidebar hidden, in the terminal or in chat.
    @MainActor static func claude<Content: View>(_ mode: PaneMode, @ViewBuilder content: () -> Content) -> some View {
        DispatchWindow(width: 760, height: 540, sidebar: nil) {
            Pane(strip: StripModel(tabs: [TabItem(title: "Fix the invoice rounding", activity: .finished, shortcut: 1, selected: true)],
                                   mode: mode, agent: true, layout: nil, titleRow: true, otherSpaces: true)) { content() }
        }
    }

    /// Claude Code's own screen for Sample.chat's turn: tool calls under ⏺, results under ⎿, the reply, the prompt.
    static let claudeScreen: [TermLine] = [
        T(c(8, "> "), c(8, "Invoices round each line before summing, so totals drift by a cent. Fix it?")),
        "",
        T(c(2, "⏺ "), c(nil, "Search", bold: true), "(pattern: \"round(\", path: \"Sources/Billing\")"),
        T(c(8, "  ⎿  "), "Found 2 files"),
        "",
        T(c(2, "⏺ "), c(nil, "Read", bold: true), "(Sources/Billing/Invoice.swift)"),
        T(c(8, "  ⎿  "), "Read 84 lines"),
        "",
        T(c(2, "⏺ "), c(nil, "Update", bold: true), "(Sources/Billing/Invoice.swift)"),
        T(c(8, "  ⎿  "), "Updated with ", c(2, "9 additions"), " and ", c(1, "4 removals")),
        "",
        T(c(2, "⏺ "), c(nil, "Bash", bold: true), "(swift test --filter InvoiceTests)"),
        T(c(8, "  ⎿  "), "Test Suite 'InvoiceTests' passed (12 tests)"),
        "",
        T("⏺ Totals now sum the exact amounts and round once, half-even, in"),
        T("  Invoice.total. Line items still show their rounded amounts."),
        T("  InvoiceTests passes, with a new case for three lines of 0.333."),
        "",
        T(c(8, String(repeating: "─", count: 85))),
        T("> Also cover the zero-amount case", c(nil, "█")),
        T(c(8, String(repeating: "─", count: 85))),
        T(c(8, "  ? for shortcuts")),
    ]

    /// L2 and L3 share a size: herdr's 100 × 24 cells and the title bar.
    static let size = CGSize(width: 860, height: 480)
}

/// A plain terminal app's window: traffic lights and a centred title over the screen.
struct PlainTerminalWindow<Content: View>: View {
    var width: CGFloat
    var height: CGFloat
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        MacWindow(width: width, height: height, lights: false) {
            VStack(spacing: 0) {
                ZStack {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Chrome.palette.secondary)
                    TrafficLights().padding(.leading, 9).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 30)
                .background(Chrome.window)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// A terminal screen captured with `tmux capture-pane -e`: cells in Source Code Pro 14 (the terminal default), colours as the program set
/// them (RGB, or ANSI indices in the theme's scheme), box-drawing lines drawn across the cell as terminals draw them.
struct CapturedScreen: View {
    let rows: [[R]]
    var fontSize: CGFloat = 14
    var lineHeight: CGFloat = 17.7
    var body: some View {
        let scheme = TerminalScheme.current
        let cell = CGSize(width: fontSize * 0.6, height: lineHeight)
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                var x = 0
                // Edges on whole pixels, so neighbouring backgrounds meet without seams.
                func edge(_ column: Int) -> CGFloat { (CGFloat(column) * cell.width * 2).rounded() / 2 }
                let top = CGFloat(y) * cell.height
                for run in row {
                    let fg = run.fg.map { $0.color(scheme) } ?? scheme.foreground
                    if let bg = run.bg {
                        let rect = CGRect(x: edge(x), y: (top * 2).rounded() / 2, width: edge(x + run.text.count) - edge(x),
                                          height: ((top + cell.height) * 2).rounded() / 2 - (top * 2).rounded() / 2)
                        context.fill(Path(rect), with: .color(bg.color(scheme)))
                    }
                    for char in run.text {
                        let box = CGRect(x: CGFloat(x) * cell.width, y: top, width: cell.width, height: cell.height)
                        switch char {
                        case "│": context.fill(Path(CGRect(x: (box.midX * 2).rounded() / 2 - 0.5, y: box.minY, width: 1, height: box.height)), with: .color(fg))
                        case "─": context.fill(Path(CGRect(x: box.minX, y: (box.midY * 2).rounded() / 2 - 0.5, width: box.width, height: 1)), with: .color(fg))
                        case " ": break
                        default:
                            let text = Text(String(char)).font(.custom(run.bold ? "SourceCodePro-Semibold" : "SourceCodePro-Regular", size: fontSize))
                                .foregroundStyle(fg)
                            context.draw(text, at: CGPoint(x: box.midX, y: box.midY))
                        }
                        x += 1
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(scheme.background)
    }
}

/// A captured run: text in one style.
struct R {
    enum Tone {
        case ansi(Int), rgb(UInt32)
        @MainActor func color(_ scheme: TerminalScheme) -> Color {
            switch self {
            case .ansi(let index): scheme.palette[index]
            case .rgb(let value): Color(hex: value)
            }
        }
    }
    var text: String
    var fg: Tone?
    var bg: Tone?
    var bold = false
    init(_ text: String, fg: Tone? = nil, bg: Tone? = nil, bold: Bool = false) {
        self.text = text; self.fg = fg; self.bg = bg; self.bold = bold
    }
}

/// herdr 0.9.5 at 100 × 24, its default theme, captured from `tmux capture-pane -e`: workspaces app, billing and docs
/// (fictional repositories), the app workspace's tabs server, tests and claude, and in server the dotfiles prompt and a
/// fictional dev server's output (Sample.server).
enum HerdrCapture {
    static let rows: [[R]] = [
        [R(" spaces", fg: .rgb(0x6c7086), bold: true), R("                  "), R("│", fg: .rgb(0x1e1e2e)), R("  server  ", fg: .rgb(0x181825), bg: .rgb(0x89b4fa), bold: true), R(" ", bg: .rgb(0x181825)), R("  tests  ", fg: .rgb(0x7f849c), bg: .rgb(0x313244)), R(" ", bg: .rgb(0x181825)), R("  claude  ", fg: .rgb(0x7f849c), bg: .rgb(0x313244)), R(" ", bg: .rgb(0x181825)), R(" + ", fg: .rgb(0x7f849c), bg: .rgb(0x181825))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e)), R("app", fg: .ansi(12)), R(" dark-mode*"), R(" ", bold: true), R("❯", fg: .ansi(2), bold: true), R(" swift run Server")],
        [R(" ", bg: .rgb(0x1e1e2e)), R("· ", fg: .rgb(0x6c7086), bg: .rgb(0x1e1e2e)), R("app", fg: .rgb(0xcdd6f4), bg: .rgb(0x1e1e2e), bold: true), R("                   ", bg: .rgb(0x1e1e2e)), R("│", fg: .rgb(0x1e1e2e)), R("Building for debugging...")],
        [R("   ", bg: .rgb(0x1e1e2e)), R("dark-mode", fg: .rgb(0xcba6f7), bg: .rgb(0x1e1e2e)), R("             ", bg: .rgb(0x1e1e2e)), R("│", fg: .rgb(0x1e1e2e)), R("Build complete!", fg: .ansi(2)), R(" (1.84s)")],
        [R(" "), R("· ", fg: .rgb(0x6c7086)), R("billing", fg: .rgb(0xa6adc8)), R("               "), R("│", fg: .rgb(0x1e1e2e)), R("[Server]", fg: .ansi(8)), R(" Listening on "), R("http://localhost:8080", fg: .ansi(4))],
        [R("   "), R("fix/invoices", fg: .rgb(0x6c7086)), R("          "), R("│", fg: .rgb(0x1e1e2e)), R("GET ", fg: .ansi(6)), R(" /invoices          "), R("200", fg: .ansi(2)), R("   12ms", fg: .ansi(8))],
        [R(" "), R("· ", fg: .rgb(0x6c7086)), R("docs", fg: .rgb(0xa6adc8)), R("                  "), R("│", fg: .rgb(0x1e1e2e)), R("GET ", fg: .ansi(6)), R(" /invoices/1042     "), R("200", fg: .ansi(2)), R("    4ms", fg: .ansi(8))],
        [R("   "), R("main", fg: .rgb(0x6c7086)), R("                  "), R("│", fg: .rgb(0x1e1e2e)), R("POST", fg: .ansi(5)), R(" /invoices/1042     "), R("422", fg: .ansi(3)), R("    9ms", fg: .ansi(8)), R("  rounding mismatch")],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e)), R("GET ", fg: .ansi(6)), R(" /invoices/1042     "), R("200", fg: .ansi(2)), R("    3ms", fg: .ansi(8))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e)), R("GET ", fg: .ansi(6)), R(" /health            "), R("200", fg: .ansi(2)), R("    1ms", fg: .ansi(8))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e))],
        [R(" new", fg: .rgb(0x6c7086)), R("                 "), R("menu", fg: .rgb(0x6c7086)), R("│", fg: .rgb(0x1e1e2e))],
        [R("─────────────────────────│", fg: .rgb(0x1e1e2e))],
        [R(" agents", fg: .rgb(0x6c7086), bold: true), R("           "), R("grouped", fg: .rgb(0x6c7086), bold: true), R("│", fg: .rgb(0x1e1e2e))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e))],
        [R("                         "), R("│", fg: .rgb(0x1e1e2e))],
        [R("                        "), R("«", fg: .rgb(0x6c7086)), R("│", fg: .rgb(0x1e1e2e))],
    ]
}
